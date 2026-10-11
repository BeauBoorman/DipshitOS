//! B1 native facility probe, not an Oliver adapter or a new shipped app.
//! Built offline by live-user-fs with no SDK, libc, POSIX or new syscall.
const std = @import("std");
pub const panic = std.debug.FullPanic(panicImpl);
const base: u64 = 0x100;
const inherit = std.math.maxInt(u64);
const closed = inherit - 1;
const Request = extern struct {
    version: u32 = 1,
    reserved: u32 = 0,
    sources: [3]u64,
};
// Ensure the writable segment exists even with a small optimized fixture.
export var stream_probe_state: u64 = 1;

fn call(number: u64, args: [6]u64) i64 {
    var result: i64 = undefined;
    asm volatile ("svc #0"
        : [result] "={x0}" (result),
        : [number] "{x8}" (number),
          [a0] "{x0}" (args[0]),
          [a1] "{x1}" (args[1]),
          [a2] "{x2}" (args[2]),
          [a3] "{x3}" (args[3]),
          [a4] "{x4}" (args[4]),
          [a5] "{x5}" (args[5]),
        : .{ .memory = true });
    return result;
}

fn exit(status: u64) noreturn {
    _ = call(3, .{ status, 0, 0, 0, 0, 0 });
    unreachable;
}

fn writeAll(fd: u64, bytes: []const u8) bool {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = call(1, .{ fd, @intFromPtr(bytes.ptr) + done, bytes.len - done, 0, 0, 0 });
        if (n <= 0 or n > bytes.len - done) return false;
        done += @intCast(n);
    }
    return true;
}

fn panicImpl(_: []const u8, _: ?usize) noreturn {
    // Allocation-free, bounded, and never falls back to stdout on refusal.
    _ = writeAll(2, "b1: panic\n");
    exit(71);
}

fn require(ok: bool) void {
    if (!ok) {
        _ = writeAll(2, "b1: FAIL\n");
        exit(70);
    }
}

fn open(path: []const u8, flags: u64) u64 {
    const fd = call(23, .{ @intFromPtr(path.ptr), path.len, flags, 0, 0, 0 });
    require(fd >= 0);
    return @intCast(fd);
}

fn spawn(mode: []const u8, request: ?*const Request) u64 {
    const name = "STREAMS.BIN";
    var argv: [256]u8 = @as([256]u8, @splat(@as(u8, 0)));
    @memcpy(argv[0..mode.len], mode);
    const pid = call(28, .{
        @intFromPtr(name.ptr),                               name.len,                               @intFromPtr(&argv),
        if (request != null) (@as(u64, 1) << 63) | 1 else 1, if (request) |r| @intFromPtr(r) else 0, if (request != null) @sizeOf(Request) else 0,
    });
    require(pid >= 0);
    return @intCast(pid);
}

fn render() noreturn {
    _ = call(4, .{ 5, 0, 0, 0, 0, 0 });
    require(writeAll(1, "<html>\n"));
    var buf: [4097]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = call(24, .{ base, @intFromPtr(&buf), buf.len, 0, 0, 0 });
        require(n >= 0 and n <= 2048);
        if (n == 0) break;
        total += @intCast(n);
        require(total <= 128 * 1024);
        require(writeAll(1, buf[0..@intCast(n)]));
    }
    require(total > 2048);
    require(call(24, .{ base, @intFromPtr(&buf), 1, 0, 0, 0 }) == 0);
    require(writeAll(1, "</html>\n"));
    require(writeAll(2, "{\"kind\":\"b1\",\"eof\":true}\n"));
    for (0..3) |i| require(call(26, .{ base + i, 0, 0, 0, 0, 0 }) == 0);
    require(call(1, .{ 2, @intFromPtr(&buf), 1, 0, 0, 0 }) == -2);
    require(call(24, .{ base, @intFromPtr(&buf), 1, 0, 0, 0 }) == -2);
    exit(0);
}

fn bridge() noreturn {
    const child = spawn("render", null); // legacy slot 28 inherits all three
    for (0..3) |i| require(call(26, .{ base + i, 0, 0, 0, 0, 0 }) == 0);
    require(call(8, .{ child, 0, 0, 0, 0, 0 }) == 0);
    exit(0);
}

fn launch(input: []const u8, output: []const u8, diagnostics: []const u8, mode: []const u8) u64 {
    const req = Request{ .sources = .{ open(input, 1), open(output, 6), open(diagnostics, 6) } };
    const child = spawn(mode, &req);
    // Ownership transferred only at successful publication; raw fd 0 is
    // now free, not the child's stdin identity.
    require(call(26, .{ req.sources[0], 0, 0, 0, 0, 0 }) == -2);
    return child;
}

export fn _start(argc: u64, argv: u64) callconv(.c) noreturn {
    stream_probe_state +%= 1;
    if (argc > 1) {
        const block: [*]const u8 = @ptrFromInt(argv);
        const arg = block[256..512];
        const len = std.mem.indexOfScalar(u8, arg, 0) orelse 0;
        if (std.mem.eql(u8, arg[0..len], "render")) render();
        if (std.mem.eql(u8, arg[0..len], "bridge")) bridge();
        if (std.mem.eql(u8, arg[0..len], "panic")) @panic("fixture panic");
        exit(64);
    }
    var buf: [1103]u8 = undefined;
    require(call(24, .{ base, @intFromPtr(&buf), 1, 0, 0, 0 }) == -2);
    @memset(&buf, 'C');
    require(writeAll(1, "b1-console:"));
    require(writeAll(1, &buf));
    require(writeAll(1, "\n"));
    const first = launch("/host/B1.IN.A", "/host/B1.OUT.A", "/host/B1.ERR.A", "render");
    const second = launch("/host/B1.IN.B", "/host/B1.OUT.B", "/host/B1.ERR.B", "bridge");
    require(call(8, .{ first, 0, 0, 0, 0, 0 }) == 0);
    require(call(8, .{ second, 0, 0, 0, 0, 0 }) == 0);
    const panic_request = Request{ .sources = .{ closed, open("/host/B1.PANIC.OUT", 6), open("/host/B1.PANIC.ERR", 6) } };
    const panicking = spawn("panic", &panic_request);
    require(call(8, .{ panicking, 0, 0, 0, 0, 0 }) == 71);
    require(writeAll(1, "b1: streams done\n"));
    exit(0);
}
