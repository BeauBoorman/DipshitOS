//! Native boundary checks use the real guest clock. Policy-only cases are
//! distinguished from evals; no fake elapsed time or harness kill is a refusal.
fn repeat_lit(comptime lit: []const u8, comptime n: usize) *const [n * lit.len:0]u8 {
    if (n == 0) return "";
    return lit ++ repeat_lit(lit, n - 1);
}
const std = @import("std");
const sdk = @import("sdk").runtime;
const qjs = @import("qjs");
const product = @import("product_policy");
pub const os = sdk.os;
pub const std_options = sdk.std_options;
pub const panic = std.debug.FullPanic(sdk.panic);
pub const virelai = sdk.platform;
pub const std_options_debug_io = sdk.std_options_debug_io;
pub const std_options_FilePermissions = sdk.std_options_FilePermissions;
pub const std_options_cwd = sdk.std_options_cwd;
comptime {
    @import("sdk").entry.exportEntry(run);
}
const Sink = struct {
    fn write(_: *anyopaque, bytes: []const u8) !usize {
        const n = sdk.native.consoleChunk(bytes);
        if (n <= 0) return error.WriteFailed;
        return @intCast(n);
    }
    fn diagnostic(_: *anyopaque, bytes: []const u8) !void {
        try sdk.print(bytes);
    }
    fn closedWrite(_: *anyopaque, bytes: []const u8) !usize {
        // Actual native closed-handle error, not a fabricated host write.
        if (sdk.native.call(25, .{ 7, @intFromPtr(bytes.ptr), bytes.len, 0, 0, 0 }) >= 0)
            return error.ClosedHandleAccepted;
        return error.WriteFailed;
    }
};
extern fn printf([*:0]const u8, ...) callconv(.c) c_int;
extern fn fprintf(*anyopaque, [*:0]const u8, ...) callconv(.c) c_int;
extern fn fputc(c_int, *anyopaque) callconv(.c) c_int;
extern fn fwrite(*const anyopaque, usize, usize, *anyopaque) callconv(.c) usize;
extern fn putchar(c_int) callconv(.c) c_int;

fn require(ok: bool) !void {
    if (!ok) return error.BoundaryMismatch;
}
fn run(_: *const sdk.startup.Startup) !void {
    try sdk.initialize(qjs.limits.arena);
    const clock = try qjs.nativeClock();
    try policyChecks(clock);
    const arena = sdk.currentArena();
    const before = arena.used();
    var token: u8 = 0;
    const sink: qjs.Sink = .{ .context = &token, .write = Sink.write, .diagnostic = Sink.diagnostic };
    for (0..3) |_| {
        const runtime = try qjs.Runtime.create(arena, clock);
        var alive = true;
        defer if (alive) runtime.destroy() catch {};
        if (qjs.Runtime.create(arena, clock)) |_| return error.ContextLimitMissing else |err| try require(err == error.ContextLimit);
        try runtime.checkResources(2, 7);
        if (runtime.checkResources(3, 7)) |_| return error.HandleLimitMissing else |err| try require(err == error.HandleLimit);
        if (runtime.checkResources(2, 8)) |_| return error.ResourceLimitMissing else |err| try require(err == error.HandleLimit);
        const buffer = try runtime.allocate(4096);
        @memset(buffer, 0x5a);
        try runtime.reset();
        try require(std.mem.allEqual(u8, buffer, 0x5a));
        runtime.release(buffer);
        const bad_sink: qjs.Sink = .{ .context = &token, .write = Sink.closedWrite, .diagnostic = Sink.diagnostic };
        const bad_write = try runtime.eval("print(42)", "closed", bad_sink, false);
        try require(bad_write.failure != null and bad_write.failure.? == error.WriteFailed and bad_write.context_reset);
        for (0..5) |index| {
            const ptr: *anyopaque = @ptrFromInt(1);
            const text: [*:0]const u8 = @ptrFromInt(1);
            const code: isize = switch (index) {
                0 => printf(text),
                1 => fprintf(ptr, text),
                2 => fputc(1, ptr),
                3 => @intCast(fwrite(ptr, std.math.maxInt(usize), std.math.maxInt(usize), ptr)),
                else => putchar(1),
            };
            try require(code == if (index == 3) @as(isize, 0) else @as(isize, -1));
            const result = try runtime.eval("42", "stub", sink, true);
            try require(result.failure != null and result.failure.? == error.UnsupportedHostedDiagnostic and result.context_reset);
        }
        const good = try runtime.eval("6*7", "recovered", sink, true);
        try require(good.failure == null);
        const stack = sdk.stackHighWater();
        try require(stack > 0 and stack <= qjs.limits.stack);
        var row: [128]u8 = undefined;
        try sdk.print(try std.fmt.bufPrint(&row, "qjs-bounds: cycle={d} arena_peak={d} stack={d} stubs=5\n", .{ @intFromPtr(runtime), arena.peak(), stack }));
        try runtime.destroy();
        alive = false;
        try require(arena.used() == before);
    }
    try sdk.print("qjs-bounds: ContextLimit stubs reuse destroy passed\n");
    try sdk.print("qjs-bounds: done\n");
}

fn policyChecks(clock: qjs.Clock) !void {
    var state = try qjs.policy.Control.init(clock);
    try state.checkLine(4096);
    if (state.checkLine(4097)) |_| return error.LineLimitMissing else |err| try require(err == error.LineLimit);
    for (0..4) |_| {
        try state.begin(qjs.limits.source);
        state.finish();
    }
    if (state.begin(1)) |_| return error.SessionSourceMissing else |err| try require(err == error.SessionLimit);
    state = try qjs.policy.Control.init(clock);
    for (0..256) |_| {
        try state.begin(0);
        state.finish();
    }
    if (state.begin(0)) |_| return error.EvalLimitMissing else |err| try require(err == error.SessionLimit);
    state = try qjs.policy.Control.init(clock);
    for (0..16) |_| {
        try state.begin(0);
        try require(state.chargeOutput(qjs.limits.output));
        state.finish();
    }
    try state.begin(0);
    try require(!state.chargeOutput(1) and state.failure != null and state.failure.? == error.SessionLimit);
    state = try qjs.policy.Control.init(clock);
    try state.chargeDiagnostic(qjs.limits.diagnostics - qjs.limits.terminal_diagnostic);
    if (state.chargeDiagnostic(1)) |_| return error.DiagnosticLimitMissing else |err| try require(err == error.DiagnosticLimit);
    try state.chargeReceipt(qjs.limits.receipt);
    if (state.chargeReceipt(1)) |_| return error.ReceiptLimitMissing else |err| try require(err == error.ReceiptLimit);
    state = try qjs.policy.Control.init(clock);
    try state.begin(0);
    state.work_sites = qjs.limits.work - 1;
    try require(state.site());
    try require(!state.site() and state.failure != null and state.failure.? == error.WorkLimit);
    try product.path("/host/" ++ &@as([31:0]u8, @splat("a"[0])) ++ "/" ++ &@as([26:0]u8, @splat("b"[0])));
    if (product.path("/host/" ++ &@as([31:0]u8, @splat("a"[0])) ++ "/" ++ &@as([27:0]u8, @splat("b"[0])))) |_| return error.PathLimitMissing else |err| try require(err == error.PathLimit);
    _ = try product.parse(&.{ "QJS.BIN", "/host/F" }, &(@as([16][]const u8, @splat(@as([]const u8, "A=" ++ repeat_lit("x", 125))))));
    if (product.parse(&.{ "QJS.BIN", &@as([256:0]u8, @splat("x"[0])) }, &.{})) |_| return error.ArgLimitMissing else |err| try require(err == error.ArgumentLimit);
    if (product.parse(&(@as([9][]const u8, @splat(@as([]const u8, "QJS.BIN")))), &.{})) |_| return error.ArgCountMissing else |err| try require(err == error.ArgumentLimit);
    if (product.parse(&.{ "QJS.BIN", "/host/F" }, &(@as([17][]const u8, @splat(@as([]const u8, "A=B")))))) |_| return error.EnvCountMissing else |err| try require(err == error.EnvironmentLimit);
    if (product.parse(&.{ "QJS.BIN", "/host/F" }, &.{"A=" ++ &@as([126:0]u8, @splat("x"[0]))})) |_| return error.EnvLimitMissing else |err| try require(err == error.EnvironmentLimit);
    var bad_clock = clock;
    bad_clock.frequency = 0;
    if (qjs.policy.Control.init(bad_clock)) |_| return error.ClockRefusalMissing else |err| try require(err == error.ClockUnavailable);
    // No second native file or mapping is created by arithmetic boundary tests.
    try sdk.print("qjs-bounds: policy exact/over source session line diagnostics receipt argv env path clock passed\n");
}
