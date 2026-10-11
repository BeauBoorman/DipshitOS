//! C3 serial-offline subset and unchanged workload bounds.
const std = @import("std");
pub const file_limit = 128 * 1024;
pub const input_limit = 1024 * 1024;
pub const output_limit = 2 * 1024 * 1024;
pub const arena_bytes = 12 * 1024 * 1024;
pub const entry_limit = 256;
pub const artifact_limit = 128;

pub const Command = enum { help, version, probe, inspect, compile, build };
pub fn parse(args: []const []const u8) !Command {
    if (args.len == 0) return error.Usage;
    for (args) |arg| {
        for ([_][]const u8{ "watch", "preview", "serve", "publish", "auth", "login", "keys", "editor", "--watch", "--preview", "--online", "--capture" }) |name|
            if (std.mem.eql(u8, arg, name)) return error.UnsupportedFeature;
        if (std.mem.startsWith(u8, arg, "--jobs")) return error.UnsupportedParallelism;
    }
    inline for (std.meta.tags(Command)) |command| {
        if (std.mem.eql(u8, args[0], @tagName(command))) {
            const count: usize = switch (command) {
                .inspect, .compile => 2,
                .build => 3,
                else => 1,
            };
            if (args.len != count) return error.Usage;
            return command;
        }
    }
    return error.UnsupportedFeature;
}

pub fn path(name: []const u8) !void {
    if (name.len == 0 or name.len + 6 > 512) return error.PathLimit;
    var parts = std.mem.splitScalar(u8, name, '/');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 255 or std.mem.eql(u8, part, ".") or
            std.mem.eql(u8, part, "..") or std.mem.indexOfAny(u8, part, "\x00\\:") != null)
            return error.PathLimit;
        count += 1;
    }
    if (count > 9) return error.TreeLimit; // At most eight directories below root.
}

/// Counts implicit directories and ignored entries, not just page files.
pub fn inputs(files: anytype) !void {
    var total: usize = 0;
    var directories: [entry_limit][]const u8 = undefined;
    var count: usize = 0;
    if (files.len > entry_limit) return error.TreeLimit;
    for (files) |file| {
        try path(file.path);
        if (file.bytes.len > file_limit or file.bytes.len > input_limit - total)
            return error.InputLimit;
        total += file.bytes.len;
        for (file.path, 0..) |byte, i| {
            if (byte != '/') continue;
            const dir = file.path[0..i];
            var found = false;
            for (directories[0..count]) |prior| {
                if (std.mem.eql(u8, prior, dir)) found = true;
            }
            if (!found) {
                if (files.len + count == entry_limit) return error.TreeLimit;
                directories[count] = dir;
                count += 1;
            }
        }
    }
}

pub fn outputs(records: anytype) !void {
    if (records.len > artifact_limit) return error.TreeLimit;
    var total: usize = 0;
    for (records) |record| {
        try path(record.path);
        if (record.bytes.len > output_limit - total) return error.OutputLimit;
        total += record.bytes.len;
    }
}
