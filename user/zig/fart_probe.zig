//! C4 test-only native allocation and full-width launch proof, not an app —
//! it drives the real CLI user/zig/fart.zig (FARTSYN.BIN, built by tools/zig/fart.py).
const std = @import("std");
const sdk = @import("runtime.zig");
const port = @import("fart/port.zig");
pub const virelai = sdk.platform;
pub const os = sdk.os;
pub const std_options = sdk.std_options;
pub const std_options_debug_io = sdk.std_options_debug_io;
pub const std_options_FilePermissions = sdk.std_options_FilePermissions;
pub const std_options_cwd = sdk.std_options_cwd;
pub const panic = std.debug.FullPanic(sdk.panic);

comptime {
    @import("entry.zig").exportEntry(run);
}

fn run(_: *const sdk.startup.Startup) !void {
    try sdk.initialize(port.arena_bytes);
    const arena = sdk.currentArena();
    const a = arena.allocator();
    const baseline = arena.used();
    const exhausted = try a.alloc(u8, port.arena_bytes - baseline - 16);
    if (arena.used() != port.arena_bytes) return error.Accounting;
    if (port.render(a, .{ .phrase = "a" })) |wav| {
        a.free(wav);
        return error.ExpectedOutOfMemory;
    } else |err| if (err != error.OutOfMemory) return err;
    a.free(exhausted);
    if (arena.used() != baseline) return error.AllocationLeak;
    try sdk.print("fart-probe: OutOfMemory at arena=4194304, reused\n");

    const path = "FARTSYN.BIN";
    const input = "a" ++ &@as([254:0]u8, @splat(" "[0]));
    var block: [sdk.startup.block_bytes]u8 = undefined;
    try sdk.startup.pack(&.{ path, "--phrase", input, "--wav", "/host/input.wav" }, &.{}, &block);
    const child = sdk.native.call(28, .{ @intFromPtr(path.ptr), path.len, @intFromPtr(&block) + 256, 4, 0, 0 });
    if (child < 0) return error.Spawn;
    if (sdk.native.call(8, .{ @intCast(child), 0, 0, 0, 0, 0 }) != 0) return error.ChildExit;
    if (sdk.startup.pack(&.{ path, "--phrase", input ++ " ", "--wav", "/host/input.wav" }, &.{}, &block)) |_| {
        return error.ExpectedArgumentLimit;
    } else |err| if (err != error.ArgumentLimit) return err;
    // Native B1 stream transfer, independently byte-compared by the host.
    // Proof driver only: two raw files transfer to the child, then close on
    // child death. The actual --stdout workload opens no SDK files.
    const Request = extern struct {
        version: u32 = 1,
        reserved: u32 = 0,
        sources: [3]u64,
    };
    const output = "/host/STDOUT.WAV";
    const diagnostics = "/host/STDERR.TXT";
    const out = sdk.native.call(23, .{ @intFromPtr(output.ptr), output.len, 6, 0, 0, 0 });
    const err = sdk.native.call(23, .{ @intFromPtr(diagnostics.ptr), diagnostics.len, 6, 0, 0, 0 });
    if (out < 0 or err < 0) return error.StreamSetup;
    const request = Request{ .sources = .{ std.math.maxInt(u64) - 1, @intCast(out), @intCast(err) } };
    try sdk.startup.pack(&.{ path, "--seed", "0", "--stdout" }, &.{}, &block);
    const stdout_child = sdk.native.call(28, .{
        @intFromPtr(path.ptr),   path.len,              @intFromPtr(&block) + 256,
        (@as(u64, 1) << 63) | 3, @intFromPtr(&request), @sizeOf(Request),
    });
    if (stdout_child < 0) return error.StreamSpawn;
    if (sdk.native.call(8, .{ @intCast(stdout_child), 0, 0, 0, 0, 0 }) != 0) return error.StdoutChildExit;
    try sdk.print("fart-probe: phrase 255 accepted, 256 refused; done\n");
}
