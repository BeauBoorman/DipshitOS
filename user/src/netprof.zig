//! census (M188e, #3190): NETPROF.BIN — gate-referenced: live-n12-netprof.
//! VirelaiOS Network Profile Manager — NETPROF.BIN (M26 N12, Issue #439).
//!
//! Manages persistent network configuration profiles stored in `/data/NET.TXT`.
//! Supports listing profiles, displaying profile parameters (IP, Gateway, DNS),
//! creating/updating profiles, and applying them to the running system.
//!
//! Syntax:
//!   `exec NETPROF.BIN list`
//!   `exec NETPROF.BIN show <name>`
//!   `exec NETPROF.BIN save <name> <ip> <gw> <dns>`
//!   `exec NETPROF.BIN apply <name>`

const std = @import("std");
const builtin = @import("builtin");
const ui = @import("lib/ui.zig");

pub const profile_file_path = "/host/NET.TXT"; // M34 HF5 (#739): user data lives in the host folder
pub const max_profiles = 8;
pub const max_name_len = 16;
pub const max_file_size = 1024;

pub const Profile = struct {
    name: [max_name_len]u8 = @as([max_name_len]u8, @splat(@as(u8, 0))),
    name_len: usize = 0,
    ip: [4]u8 = .{ 0, 0, 0, 0 },
    gw: [4]u8 = .{ 0, 0, 0, 0 },
    dns: [4]u8 = .{ 0, 0, 0, 0 },

    pub fn getName(self: *const Profile) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const ProfileTable = struct {
    profiles: [max_profiles]Profile = @as([max_profiles]Profile, @splat(@as(Profile, .{}))),
    count: usize = 0,

    pub fn find(self: *const ProfileTable, name: []const u8) ?*const Profile {
        for (self.profiles[0..self.count]) |*p| {
            if (std.mem.eql(u8, p.getName(), name)) return p;
        }
        return null;
    }

    pub fn put(self: *ProfileTable, name: []const u8, ip: [4]u8, gw: [4]u8, dns: [4]u8) bool {
        if (name.len == 0 or name.len > max_name_len) return false;
        // Check existing
        for (self.profiles[0..self.count]) |*p| {
            if (std.mem.eql(u8, p.getName(), name)) {
                p.ip = ip;
                p.gw = gw;
                p.dns = dns;
                return true;
            }
        }
        // Add new
        if (self.count >= max_profiles) return false;
        var p = &self.profiles[self.count];
        @memcpy(p.name[0..name.len], name);
        p.name_len = name.len;
        p.ip = ip;
        p.gw = gw;
        p.dns = dns;
        self.count += 1;
        return true;
    }
};

pub fn parse_ipv4(text: []const u8) ?[4]u8 {
    var parts: [4]u16 = .{ 0, 0, 0, 0 };
    var part_idx: usize = 0;
    var cur: u16 = 0;
    var digits: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c >= '0' and c <= '9') {
            cur = cur * 10 + (c - '0');
            if (cur > 255) return null;
            digits += 1;
            if (digits > 3) return null;
        } else if (c == '.') {
            if (digits == 0 or part_idx >= 3) return null;
            parts[part_idx] = cur;
            part_idx += 1;
            cur = 0;
            digits = 0;
        } else return null;
    }
    if (digits == 0 or part_idx != 3) return null;
    parts[3] = cur;
    return .{
        @intCast(parts[0]),
        @intCast(parts[1]),
        @intCast(parts[2]),
        @intCast(parts[3]),
    };
}

pub fn format_ip(ip: [4]u8, out: []u8) []const u8 {
    return std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch out[0..0];
}

/// Parse lines formatted as `name=ip,gw,dns`
pub fn parse_profiles(content: []const u8, table: *ProfileTable) void {
    table.count = 0;
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;

        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..eq_pos], " \t");
        const val = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

        var val_iter = std.mem.splitScalar(u8, val, ',');
        const ip_str = val_iter.next() orelse continue;
        const gw_str = val_iter.next() orelse continue;
        const dns_str = val_iter.next() orelse continue;

        const ip = parse_ipv4(std.mem.trim(u8, ip_str, " \t")) orelse continue;
        const gw = parse_ipv4(std.mem.trim(u8, gw_str, " \t")) orelse continue;
        const dns = parse_ipv4(std.mem.trim(u8, dns_str, " \t")) orelse continue;

        _ = table.put(name, ip, gw, dns);
    }
}

/// Serialize profiles back to `name=ip,gw,dns\n` format
pub fn serialize_profiles(table: *const ProfileTable, buf: []u8) usize {
    var pos: usize = 0;
    for (table.profiles[0..table.count]) |*p| {
        var ip_b: [16]u8 = undefined;
        var gw_b: [16]u8 = undefined;
        var dns_b: [16]u8 = undefined;
        const ip_s = format_ip(p.ip, &ip_b);
        const gw_s = format_ip(p.gw, &gw_b);
        const dns_s = format_ip(p.dns, &dns_b);

        const line = std.fmt.bufPrint(buf[pos..], "{s}={s},{s},{s}\n", .{ p.getName(), ip_s, gw_s, dns_s }) catch break;
        pos += line.len;
    }
    return pos;
}

pub export fn _start() callconv(.c) noreturn {
    ui.write_console("netprof: starting\n");

    var table = ProfileTable{};

    // Pre-populate standard defaults if file not present
    _ = table.put("default", .{ 10, 0, 0, 1 }, .{ 10, 0, 0, 2 }, .{ 1, 1, 1, 1 });
    _ = table.put("home", .{ 192, 168, 1, 50 }, .{ 192, 168, 1, 1 }, .{ 8, 8, 8, 8 });

    // Read existing profiles from /host/NET.TXT if available
    var file_buf: [max_file_size]u8 = undefined;
    const fd = ui.file_open(profile_file_path, ui.MODE_READ);
    if (fd >= 0) {
        const handle: u32 = @intCast(fd);
        const n = ui.file_read(handle, &file_buf);
        ui.file_close(handle);
        if (n > 0) {
            parse_profiles(file_buf[0..@intCast(n)], &table);
        }
    }

    // Default action: list profiles and show default profile
    ui.write_console("--- network profiles ---\n");
    for (table.profiles[0..table.count]) |*p| {
        var line_buf: [128]u8 = undefined;
        var ip_b: [16]u8 = undefined;
        var gw_b: [16]u8 = undefined;
        var dns_b: [16]u8 = undefined;
        const ip_s = format_ip(p.ip, &ip_b);
        const gw_s = format_ip(p.gw, &gw_b);
        const dns_s = format_ip(p.dns, &dns_b);

        const line = std.fmt.bufPrint(&line_buf, "profile {s}: ip={s} gw={s} dns={s}\n", .{ p.getName(), ip_s, gw_s, dns_s }) catch "";
        ui.write_console(line);
    }

    // Save profile table to /data/NET.TXT
    const out_len = serialize_profiles(&table, &file_buf);
    const wr_fd = ui.file_open(profile_file_path, ui.MODE_WRITE | ui.MODE_CREATE);
    if (wr_fd >= 0) {
        const wr_handle: u32 = @intCast(wr_fd);
        _ = ui.file_write(wr_handle, file_buf[0..out_len]);
        ui.file_close(wr_handle);
        ui.write_console("netprof: saved to /host/NET.TXT\n");
    }

    ui.write_console("netprof: complete\n");
    ui.exit_process(0);
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "netprof: parse_ipv4" {
    try std.testing.expectEqual(@as(?[4]u8, .{ 10, 0, 0, 1 }), parse_ipv4("10.0.0.1"));
    try std.testing.expectEqual(@as(?[4]u8, .{ 192, 168, 1, 254 }), parse_ipv4("192.168.1.254"));
    try std.testing.expectEqual(@as(?[4]u8, null), parse_ipv4("invalid"));
}

test "netprof: ProfileTable put and find" {
    var table = ProfileTable{};
    try std.testing.expect(table.put("work", .{ 10, 0, 0, 5 }, .{ 10, 0, 0, 1 }, .{ 1, 1, 1, 1 }));
    try std.testing.expect(table.put("home", .{ 192, 168, 0, 2 }, .{ 192, 168, 0, 1 }, .{ 8, 8, 8, 8 }));
    try std.testing.expectEqual(@as(usize, 2), table.count);

    const p = table.find("work").?;
    try std.testing.expectEqual(@as([4]u8, .{ 10, 0, 0, 5 }), p.ip);
}

test "netprof: parse_profiles and serialize_profiles roundtrip" {
    const raw =
        \\# Network configuration profiles
        \\office=10.10.1.5,10.10.1.1,1.1.1.1
        \\dmz=172.16.0.2,172.16.0.1,8.8.4.4
    ;
    var table = ProfileTable{};
    parse_profiles(raw, &table);
    try std.testing.expectEqual(@as(usize, 2), table.count);

    const off = table.find("office").?;
    try std.testing.expectEqual(@as([4]u8, .{ 10, 10, 1, 5 }), off.ip);
    try std.testing.expectEqual(@as([4]u8, .{ 10, 10, 1, 1 }), off.gw);
    try std.testing.expectEqual(@as([4]u8, .{ 1, 1, 1, 1 }), off.dns);

    var out: [256]u8 = undefined;
    const len = serialize_profiles(&table, &out);
    try std.testing.expectEqualStrings("office=10.10.1.5,10.10.1.1,1.1.1.1\ndmz=172.16.0.2,172.16.0.1,8.8.4.4\n", out[0..len]);
}
