//! Native gap-ELF startup bytes. These are not host argv/envp pointers.
const std = @import("std");

pub const arg_count = 8;
pub const arg_bytes = 256;
pub const env_count = 16;
pub const env_bytes = 128;
pub const argv_bytes = arg_count * arg_bytes;
pub const block_bytes = argv_bytes + env_count * env_bytes;
pub const Error = error{ ArgumentLimit, EnvironmentLimit, InvalidStartupBlock };

pub const Startup = struct {
    args: [arg_count][]const u8 = undefined,
    env: [env_count][]const u8 = undefined,
    argc: usize = 0,
    envc: usize = 0,

    pub fn parse(argc: usize, block: []const u8) Error!Startup {
        if (argc == 0 or argc > arg_count or block.len != block_bytes)
            return error.InvalidStartupBlock;
        var result: Startup = .{ .argc = argc };
        for (0..argc) |i| {
            const slot = block[i * arg_bytes ..][0..arg_bytes];
            const end = std.mem.indexOfScalar(u8, slot, 0) orelse
                return error.InvalidStartupBlock;
            if (i == 0 and end == 0) return error.InvalidStartupBlock;
            result.args[i] = slot[0..end];
        }
        for (0..env_count) |i| {
            const slot = block[argv_bytes + i * env_bytes ..][0..env_bytes];
            const end = std.mem.indexOfScalar(u8, slot, 0) orelse
                return error.InvalidStartupBlock;
            if (end == 0) break;
            if (!validEnv(slot[0..end])) return error.InvalidStartupBlock;
            result.env[i] = slot[0..end];
            result.envc += 1;
        }
        return result;
    }

    pub fn getEnv(self: *const Startup, key: []const u8) ?[]const u8 {
        for (self.env[0..self.envc]) |entry| {
            const sep = std.mem.indexOfScalar(u8, entry, '=').?;
            if (std.mem.eql(u8, entry[0..sep], key)) return entry[sep + 1 ..];
        }
        return null;
    }
};

fn validEnv(entry: []const u8) bool {
    const sep = std.mem.indexOfScalar(u8, entry, '=') orelse return false;
    return sep > 0 and std.mem.indexOfScalar(u8, entry, 0) == null;
}

/// Validate ALL inputs before writing anything. argc includes the program name.
/// Slot 28 has no env parameter; this packer does not create env inheritance.
pub fn pack(args: []const []const u8, env: []const []const u8, block: *[block_bytes]u8) Error!void {
    if (args.len == 0 or args.len > arg_count or args[0].len == 0)
        return error.ArgumentLimit;
    for (args) |arg| {
        if (arg.len >= arg_bytes or std.mem.indexOfScalar(u8, arg, 0) != null)
            return error.ArgumentLimit;
    }
    if (env.len > env_count) return error.EnvironmentLimit;
    for (env) |entry| {
        if (entry.len >= env_bytes or !validEnv(entry)) return error.EnvironmentLimit;
    }
    @memset(block, 0);
    for (args, 0..) |arg, i| @memcpy(block[i * arg_bytes ..][0..arg.len], arg);
    for (env, 0..) |entry, i| @memcpy(block[argv_bytes + i * env_bytes ..][0..entry.len], entry);
}

test "startup: exact limits, empty user arg, stable views, and empty env value" {
    const long_arg = @as([255]u8, @splat(@as(u8, 'a')));
    const long_env = "X=" ++ (@as([125]u8, @splat(@as(u8, 'b'))));
    var args = @as([arg_count][]const u8, @splat(@as([]const u8, &long_arg)));
    args[2] = "";
    var block: [block_bytes]u8 = undefined;
    try pack(&args, &(@as([env_count][]const u8, @splat(@as([]const u8, long_env)))), &block);
    const result = try Startup.parse(arg_count, &block);
    try std.testing.expectEqual(arg_count, result.argc);
    try std.testing.expectEqual(env_count, result.envc);
    try std.testing.expectEqualStrings(&long_arg, result.args[7]);
    try std.testing.expectEqualStrings("", result.args[2]);
    try std.testing.expectEqual(@intFromPtr(&block), @intFromPtr(result.args[0].ptr));
    try std.testing.expectEqualStrings(long_env[2..], result.getEnv("X").?);
    try pack(&.{"fixture"}, &.{"EMPTY="}, &block);
    const empty = try Startup.parse(1, &block);
    try std.testing.expectEqualStrings("", empty.getEnv("EMPTY").?);
    try std.testing.expect(empty.getEnv("absent") == null);
}

test "startup: launch refusal does not modify the destination" {
    var block = @as([block_bytes]u8, @splat(@as(u8, 0xa5)));
    try std.testing.expectError(error.ArgumentLimit, pack(&.{}, &.{}, &block));
    try std.testing.expectError(error.ArgumentLimit, pack(&.{""}, &.{}, &block));
    try std.testing.expectError(error.ArgumentLimit, pack(&(@as([9][]const u8, @splat(@as([]const u8, "x")))), &.{}, &block));
    try std.testing.expectError(error.ArgumentLimit, pack(&.{&@as([256:0]u8, @splat("x"[0]))}, &.{}, &block));
    try std.testing.expectError(error.ArgumentLimit, pack(&.{"x\x00y"}, &.{}, &block));
    try std.testing.expectError(error.EnvironmentLimit, pack(&.{"x"}, &(@as([17][]const u8, @splat(@as([]const u8, "X=1")))), &block));
    for ([_][]const u8{ "X=" ++ (&@as([126:0]u8, @splat("a"[0]))), "", "=bad", "missing", "X=\x00" }) |env|
        try std.testing.expectError(error.EnvironmentLimit, pack(&.{"x"}, &.{env}, &block));
    try std.testing.expectEqualSlices(u8, &(@as([block_bytes]u8, @splat(@as(u8, 0xa5)))), &block);
}

test "startup: malformed received blocks and bounded env termination" {
    var block: [block_bytes]u8 = undefined;
    try pack(&.{"fixture"}, &.{"A=B"}, &block);
    for ([_]usize{ 0, 9, std.math.maxInt(usize) }) |argc|
        try std.testing.expectError(error.InvalidStartupBlock, Startup.parse(argc, &block));
    try std.testing.expectError(error.InvalidStartupBlock, Startup.parse(1, block[0 .. block.len - 1]));
    @memset(block[0..arg_bytes], 'x');
    try std.testing.expectError(error.InvalidStartupBlock, Startup.parse(1, &block));
    try pack(&.{"fixture"}, &.{"A=B"}, &block);
    @memset(block[argv_bytes..][0..env_bytes], 'x');
    try std.testing.expectError(error.InvalidStartupBlock, Startup.parse(1, &block));
    block[argv_bytes] = 0;
    // The empty slot terminates the environment; never scan past it.
    @memset(block[argv_bytes + env_bytes ..], 0xff);
    try std.testing.expectEqual(@as(usize, 0), (try Startup.parse(1, &block)).envc);
}
