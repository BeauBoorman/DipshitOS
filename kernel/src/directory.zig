//! B2: shared, versioned directory rows and bounded immutable snapshots.
const std = @import("std");

pub const path_max: usize = 512;
pub const name_max: usize = 255;
pub const depth_max: usize = 8;
pub const entry_max: usize = 256;
pub const cursor_max: usize = 8;
pub const page_max: usize = 16;
pub const version: u64 = 1 << 63;
pub const open_op: u64 = version | 1;
pub const page_op: u64 = version | 2;
pub const close_op: u64 = version | 3;

pub const Entry = extern struct {
    name: [256]u8 = @splat(0),
    size: u64 = 0,
    name_len: u16 = 0,
    is_dir: u8 = 0,
    reserved: [5]u8 = @splat(0),
};

pub const Header = extern struct {
    next: u64 = 0,
    count: u32 = 0,
    end: u32 = 0,
};

pub const Page = extern struct {
    header: Header = .{},
    entries: [page_max]Entry = undefined,
};

comptime {
    if (@sizeOf(Entry) != 272 or @sizeOf(Header) != 16)
        @compileError("B2 directory wire layout changed");
}

pub fn valid_name(name: []const u8) bool {
    return name.len > 0 and name.len <= name_max and
        std.mem.indexOfScalar(u8, name, 0) == null and
        std.mem.indexOfScalar(u8, name, '/') == null and
        !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");
}

/// Root-relative normalized path. Empty means the share root.
pub fn valid_path(path: []const u8, depth_limit: usize) bool {
    if (path.len > path_max or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (path.len == 0) return true;
    var parts = std.mem.splitScalar(u8, path, '/');
    var depth: usize = 0;
    while (parts.next()) |name| {
        if (!valid_name(name)) return false;
        depth += 1;
        if (depth > depth_limit) return false;
    }
    return true;
}

pub const Snapshot = struct {
    entries: [entry_max]Entry = undefined,
    count: usize = 0,

    pub fn append(self: *Snapshot, name: []const u8, size: u64, is_dir: bool) error{ NameLimit, EntryLimit, InvalidEntry }!void {
        if (name.len > name_max) return error.NameLimit;
        if (!valid_name(name)) return error.InvalidEntry;
        for (self.entries[0..self.count]) |*entry| {
            if (std.mem.eql(u8, entry.name[0..entry.name_len], name)) return error.InvalidEntry;
        }
        if (self.count == entry_max) return error.EntryLimit;
        var entry = Entry{ .size = size, .name_len = @intCast(name.len), .is_dir = @intFromBool(is_dir) };
        @memcpy(entry.name[0..name.len], name);
        self.entries[self.count] = entry;
        self.count += 1;
    }

    fn less(_: void, a: Entry, b: Entry) bool {
        return std.mem.order(u8, a.name[0..a.name_len], b.name[0..b.name_len]) == .lt;
    }

    pub fn sort(self: *Snapshot) void {
        std.mem.sort(Entry, self.entries[0..self.count], {}, less);
    }
};

test "B2: lossless colliding prefixes, name and entry boundaries" {
    var snapshot = Snapshot{};
    const prefix = "abcdefghijklmnopqrstuvwxyzABCDE";
    try snapshot.append(prefix ++ "-one", 1, false);
    try snapshot.append(prefix ++ "-two", 2, true);
    const exact = @as([name_max]u8, @splat(@as(u8, 'x')));
    try snapshot.append(&exact, 3, false);
    const over = @as([(name_max + 1)]u8, @splat(@as(u8, 'x')));
    try std.testing.expectError(error.NameLimit, snapshot.append(&over, 0, false));
    try std.testing.expectError(error.InvalidEntry, snapshot.append(prefix ++ "-one", 0, false));
    var name: [16]u8 = undefined;
    while (snapshot.count < entry_max) {
        const text = try std.fmt.bufPrint(&name, "entry-{d}", .{snapshot.count});
        try snapshot.append(text, 0, false);
    }
    try std.testing.expectError(error.EntryLimit, snapshot.append("overflow", 0, false));
    snapshot.sort();
    try std.testing.expectEqual(entry_max, snapshot.count);
}

test "B2: component, depth, path and traversal boundaries" {
    try std.testing.expect(valid_path("a/b/c/d/e/f/g/h", depth_max));
    try std.testing.expect(!valid_path("a/b/c/d/e/f/g/h/i", depth_max));
    const name = @as([255]u8, @splat(@as(u8, 'a')));
    try std.testing.expect(valid_path(&name, depth_max));
    try std.testing.expect(!valid_path(&(@as([256]u8, @splat(@as(u8, 'a')))), depth_max));
    const exact = name ++ "/" ++ (@as([254]u8, @splat(@as(u8, 'b')))) ++ "/c";
    try std.testing.expectEqual(@as(usize, 512), exact.len);
    try std.testing.expect(valid_path(exact, depth_max));
    try std.testing.expect(!valid_path(exact ++ "d", depth_max));
    for ([_][]const u8{ "../x", "a/../x", "a/./b", "a//b", "a\x00b" }) |bad|
        try std.testing.expect(!valid_path(bad, depth_max));
}
