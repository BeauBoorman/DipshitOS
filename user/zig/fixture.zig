//! A2 proof fixture, not a portfolio app or the full A3 std integration.
const std = @import("std");
const sdk = @import("runtime.zig");
pub const os = sdk.os;
pub const std_options = sdk.std_options;
pub const panic = std.debug.FullPanic(sdk.panic);
pub const virelai = sdk.platform;
pub const std_options_debug_io = sdk.std_options_debug_io;
pub const std_options_FilePermissions = sdk.std_options_FilePermissions;
pub const std_options_cwd = sdk.std_options_cwd;
var initialized_data: u64 = 0x1879_1866;

comptime {
    @import("entry.zig").exportEntry(run);
}

fn mode(args: *const sdk.startup.Startup, name: []const u8) bool {
    return args.argc > 1 and std.mem.eql(u8, args.args[1], name);
}

fn run(args: *const sdk.startup.Startup) !void {
    // Prove initialized data and writable BSS, not an RX-only accidental ELF.
    const value: *volatile u64 = &initialized_data;
    if (value.* != 0x1879_1866) return error.InitializedData;
    value.* += 1;
    if (mode(args, "reserve-fail")) {
        // TEST ONLY: fill the native region table with 16 unpopulated pages.
        // No physical-page/record exhaustion, over-budget arena or ABI change.
        // The next *production* SDK reservation must return OutOfMemory.
        for (0..16) |_| {
            if (sdk.native.call(63, .{ 0, 4096, 3, 0x22, 0, 0 }) <= 0)
                return error.FailureSetup;
        }
        sdk.initialize(1024 * 1024) catch |err| {
            if (err != error.OutOfMemory) return err;
            try sdk.print("zig-guest: native reservation refused\n");
            return err;
        };
        return error.ReservationUnexpectedlySucceeded;
    }
    try sdk.initialize(1024 * 1024);
    if (sdk.initialize(4096)) |_| return error.SecondArena else |err| {
        if (err != error.AlreadyInitialized) return err;
    }
    if (mode(args, "panic")) @panic("requested fixture panic");
    if (mode(args, "oom")) {
        const allocation = std.heap.page_allocator.alloc(u8, 1024 * 1024) catch |err| {
            try sdk.print("zig-guest: bounded allocation refused\n");
            return err;
        };
        std.heap.page_allocator.free(allocation);
        return error.AllocationUnexpectedlySucceeded;
    }
    if (mode(args, "launch")) {
        try launchBoundary();
        return;
    }
    if (mode(args, "io")) {
        try @import("io_fixture.zig").run(args);
        return;
    }
    if (mode(args, "unsupported")) {
        _ = std.Io.Clock.real.now(sdk.io);
        return error.UnsupportedReturned;
    }

    // Echo bytes, not just a precomputed success marker. The gate compares
    // these with its independently generated argv/env inputs.
    for (args.args[0..args.argc], 0..) |arg, i| {
        var prefix: [64]u8 = undefined;
        try sdk.print(try std.fmt.bufPrint(&prefix, "zig-guest: arg[{d}]=", .{i}));
        try sdk.print(arg);
        try sdk.print("\n");
    }
    for (args.env[0..args.envc]) |entry| {
        try sdk.print("zig-guest: env=");
        try sdk.print(entry);
        try sdk.print("\n");
    }
    const a = std.heap.page_allocator;
    const base = sdk.currentArena().used();
    for (0..64) |_| {
        const first = try a.alignedAlloc(u8, .fromByteUnits(4096), 32768);
        const second = try a.alloc(u8, 16384);
        @memset(first, 0x5a);
        @memset(second, 0xa5);
        const address = @intFromPtr(first.ptr);
        a.free(first);
        const reused = try a.alignedAlloc(u8, .fromByteUnits(4096), 32768);
        if (@intFromPtr(reused.ptr) != address) return error.ReuseFailed;
        a.free(second);
        a.free(reused);
        if (sdk.currentArena().used() != base) return error.AllocationLeak;
    }
    const high_water = sdk.stackHighWater();
    if (high_water > sdk.stack_budget) return error.StackBudget;
    var report: [128]u8 = undefined;
    try sdk.print(try std.fmt.bufPrint(&report, "zig-guest: reuse=64 arena_peak={d} stack_high_water={d}\n", .{
        sdk.currentArena().peak(), high_water,
    }));
    try sdk.print("zig-guest: done\n");
}

fn launchBoundary() !void {
    const path = "ZGUEST.BIN";
    const long_arg = &@as([255:0]u8, @splat("x"[0]));
    const args = [_][]const u8{ path, "boundary", long_arg, "", "alpha", "beta", "six", "seven" };
    var block: [sdk.startup.block_bytes]u8 = undefined;
    if (sdk.startup.pack(&.{ path, &@as([256:0]u8, @splat("x"[0])) }, &.{}, &block)) |_| {
        return error.ArgumentUnexpectedlyAccepted;
    } else |err| {
        if (err != error.ArgumentLimit) return err;
        try sdk.print("zig-guest: ArgumentLimit (256-byte argument)\n");
    }
    if (sdk.startup.pack(&(@as([9][]const u8, @splat(@as([]const u8, path)))), &.{}, &block)) |_| {
        return error.ArgumentCountUnexpectedlyAccepted;
    } else |err| {
        if (err != error.ArgumentLimit) return err;
        try sdk.print("zig-guest: ArgumentLimit (eight user arguments)\n");
    }
    try sdk.startup.pack(&args, &.{}, &block);
    // Slot 28 supplies USER arguments; the gap loader prepends the name.
    const child = sdk.native.call(28, .{ @intFromPtr(path.ptr), path.len, @intFromPtr(&block) + sdk.startup.arg_bytes, 7, 0, 0 });
    if (child < 0) return error.ChildSpawn;
    if (sdk.native.call(8, .{ @intCast(child), 0, 0, 0, 0, 0 }) != 0) return error.ChildExit;
    try sdk.print("zig-guest: launcher done\n");
}
