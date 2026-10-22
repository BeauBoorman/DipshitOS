//! Native EL0 execution of injected B6 frames/time, NOT live socket integration.
//! Only unchanged file/console/exit calls are used. No arena, threads or net SVC.
const std = @import("std");
const core = @import("socket_core");
const native = @import("native");
const wire = core.wire;
pub const panic = std.debug.FullPanic(panicImpl);
export var socket_core_fixture_state: u64 = 1;
var c: core.Core = .{};
var frame: [wire.frame_max]u8 = undefined;
var segment: [wire.segment_max]u8 = undefined;
var captured: [wire.segment_max]u8 = undefined;
var captured_len: usize = 0;
var captured_remote: core.Endpoint = remote;
var refuse_tx = false;
var checks: usize = 0;
var checkpoint: []const u8 = "entry";
var initial_sp: usize = 0;
const local: core.Endpoint = .{ .ip = .{ 10, 0, 0, 1 }, .port = 8090 };
const remote: core.Endpoint = .{ .ip = .{ 10, 0, 0, 2 }, .port = 5000 };
const other: core.Endpoint = .{ .ip = .{ 10, 0, 0, 3 }, .port = 5000 };
const mac = [6]u8{ 2, 0, 0, 0, 0, 2 };

comptime {
    @export(&entry, .{ .name = "_start" });
}
fn entry() callconv(.naked) noreturn {
    asm volatile (
        \\mov x9, sp
        \\sub x10, x9, #32, lsl #12
        \\sub x10, x10, #4096
        \\mov w12, #0xa5
        \\1:
        \\strb w12, [x10], #1
        \\cmp x10, x9
        \\b.lo 1b
        \\mov x0, x9
        \\bl socket_fixture_main
        \\2:
        \\wfe
        \\b 2b
    );
}
fn print(bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const take = @min(bytes.len - offset, 256);
        const count = native.consoleChunk(bytes[offset .. offset + take]);
        if (count <= 0 or count > take) native.exit(70);
        offset += @intCast(count);
    }
}
fn panicImpl(_: []const u8, _: ?usize) noreturn {
    print("socket-core: FAIL panic\n");
    native.exit(71);
}
fn check(ok: bool) !void {
    if (!ok) return error.Acceptance;
    checks += 1;
}
fn expected(err: anyerror, result: anytype) !void {
    if (result) |_| {
        return error.Acceptance;
    } else |got| try check(got == err);
}
fn inject(src: core.Endpoint, seq: u32, ack: u32, flags: u8, body: []const u8, now: u64) !void {
    const len = wire.build_segment(&segment, src.ip, local.ip, src.port, local.port, seq, ack, flags, body);
    const flen = wire.build_frame(&frame, &mac, src.ip, mac, local.ip, segment[0..len]);
    try c.receive(frame[0..flen], now, 100);
}
fn transmit(_: ?*anyopaque, out: core.Outbound) bool {
    if (refuse_tx) return false;
    @memcpy(captured[0..out.bytes.len], out.bytes);
    captured_len = out.bytes.len;
    captured_remote = out.remote;
    return true;
}
fn drain() !void {
    for (0..8) |_| {
        switch (c.flush(null, transmit)) {
            .empty => return,
            .refused => return error.Acceptance,
            .sent => {},
        }
    }
    return error.Acceptance;
}
fn hex(label: []const u8, bytes: []const u8) void {
    print(label);
    const digits = "0123456789abcdef";
    var text: [128]u8 = undefined;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = @min(bytes.len - offset, text.len / 2);
        for (bytes[offset .. offset + count], 0..) |b, i| {
            text[i * 2] = digits[b >> 4];
            text[i * 2 + 1] = digits[b & 15];
        }
        print(text[0 .. count * 2]);
        offset += count;
    }
    print("\n");
}
fn number(label: []const u8, value: usize) void {
    var buf: [64]u8 = undefined;
    print(std.fmt.bufPrint(&buf, "{s}{d}\n", .{ label, value }) catch unreachable);
}
fn establish(endpoint: core.Endpoint, listener: core.Handle, now: u64) !core.Handle {
    try inject(endpoint, 10, 0, wire.flag_syn, "", now);
    try drain();
    try inject(endpoint, 11, 101, wire.flag_ack, "", now);
    return c.accept(7, listener);
}
fn reset() core.Handle {
    // Only fixture scenarios replace the whole core. Production keeps generations.
    c = .{};
    return c.listen(7, local, 0) catch unreachable;
}
fn scenarios() !void {
    checkpoint = "intake";
    const path = "/host/SOCKET.IN";
    const fd = native.call(23, .{ @intFromPtr(path.ptr), path.len, 1, 0, 0, 0 });
    try check(fd >= 0);
    var input: [128]u8 = undefined;
    const count = native.call(24, .{ @intCast(fd), @intFromPtr(&input), input.len, 0, 0, 0 });
    try check(count > 0 and count < input.len);
    const length: usize = @intCast(count);
    var extra: [1]u8 = undefined;
    try check(native.call(24, .{ @intCast(fd), @intFromPtr(&extra), 1, 0, 0, 0 }) == 0);
    try check(native.call(26, .{ @intCast(fd), 0, 0, 0, 0, 0 }) == 0);
    hex("socket-core: intake=", input[0..length]);

    checkpoint = "two children";
    var listener = reset();
    try inject(remote, 10, 0, wire.flag_syn, "", 0);
    try drain();
    hex("socket-core: synack=", captured[0..captured_len]);
    try inject(remote, 11, 101, wire.flag_ack, "", 0);
    const first = try c.accept(7, listener);
    const second = try establish(other, listener, 0);
    try check(c.liveChildren() == 2);
    try expected(error.Capacity, c.listen(8, local, 0));
    try expected(error.AccessDenied, c.close(8, listener));
    try expected(error.AccessDenied, c.send(8, first, "", 0));
    try expected(error.InvalidHandle, c.send(7, listener, "x", 0));
    try inject(remote, 11, 101, wire.flag_ack, input[0..length], 0);
    var output: [128]u8 = undefined;
    try check(try c.read(7, first, output[0..1], 0) == 1);
    const rest = try c.read(7, first, output[1..], 0);
    try check(rest == length - 1 and std.mem.eql(u8, input[0..length], output[0..length]));
    hex("socket-core: read=", output[0..length]);
    // Drop the already queued ACK so the next capture is the data packet.
    try drain();
    try check(try c.send(7, first, input[0..length], 0) == length);
    try expected(error.WouldBlock, c.send(7, first, "overwrite", 0));
    refuse_tx = true;
    try check(c.flush(null, transmit) == .refused);
    refuse_tx = false;
    try drain();
    hex("socket-core: data=", captured[0..captured_len]);
    try c.poll(core.rto_ns);
    try drain();
    hex("socket-core: retransmit=", captured[0..captured_len]);
    try check(c.counters.retransmitted == 1);

    checkpoint = "refusal";
    const third: core.Endpoint = .{ .ip = .{ 10, 0, 0, 9 }, .port = 6000 };
    try inject(third, 0xffffffff, 0, wire.flag_syn, "", core.rto_ns);
    try inject(.{ .ip = .{ 10, 0, 0, 8 }, .port = 6001 }, 20, 0, wire.flag_syn, "", core.rto_ns);
    try check(c.counters.capacity_refused == 2 and c.counters.refusal_dropped == 1);
    try drain();
    try check(captured_remote.port == third.port and std.mem.eql(u8, &captured_remote.ip, &third.ip));
    hex("socket-core: refusal=", captured[0..captured_len]);
    // Same source port, different source IP: no data may reach either child.
    try inject(third, 11, 101, wire.flag_ack, "foreign", core.rto_ns);
    try expected(error.WouldBlock, c.read(7, second, &output, core.rto_ns));
    try c.close(7, second);
    try expected(error.InvalidHandle, c.ready(7, second));
    try check(c.liveChildren() == 1);
    c.closeOwner(8);
    try check(c.liveChildren() == 1);
    c.closeOwner(7);
    try check(c.liveChildren() == 0 and c.listener == null and c.refusal == null);
    try expected(error.InvalidHandle, c.close(7, first));
    print("socket-core: ownership capacity refusal cleanup ok\n");

    checkpoint = "owner bound";
    _ = reset();
    // Owner 7 charges listener + three active-open connections —
    // owner_limit sockets with ZERO listener siblings, so only the
    // owner bound (never the per-listener child bound) can refuse a
    // wire-driven SYN.
    var owned: [3]core.Handle = undefined;
    for (0..3) |i| {
        owned[i] = try c.open(7, .{ .ip = .{ 10, 0, 0, 1 }, .port = @intCast(8001 + i) }, .{ .ip = .{ 10, 0, 0, 4 }, .port = @intCast(9001 + i) }, mac, 0, 700);
    }
    try drain();
    try check(c.liveChildren() == 3 and c.ownedSockets(7) == core.owner_limit);
    // The unsaturated listener's SYN is refused by the owner bound:
    // counted by name, answered RST+ACK at the peer's own address, no
    // child minted.
    try inject(other, 40, 0, wire.flag_syn, "", 0);
    try check(c.counters.owner_saturated == 1 and c.counters.listen_saturated == 0);
    try check(c.liveChildren() == 3);
    try drain();
    try check(captured_remote.port == other.port and std.mem.eql(u8, &captured_remote.ip, &other.ip));
    try check(captured[13] == (wire.flag_rst | wire.flag_ack));
    // A freed socket re-opens admission — to exactly the bound, never past.
    try c.close(7, owned[0]);
    try inject(other, 50, 0, wire.flag_syn, "", 0);
    try check(c.liveChildren() == 3 and c.ownedSockets(7) == core.owner_limit);
    try drain(); // the admitted child's SYN-ACK, so the refusal is last
    try inject(remote, 60, 0, wire.flag_syn, "", 0);
    try check(c.counters.owner_saturated == 2 and c.liveChildren() == 3);
    try drain();
    try check(captured[13] == (wire.flag_rst | wire.flag_ack));
    c.closeOwner(7);
    try check(c.liveChildren() == 0 and c.listener == null and c.refusal == null);
    print("socket-core: owner bound refusal ok\n");

    checkpoint = "terminal";
    listener = reset();
    const clean = try establish(remote, listener, 0);
    try inject(remote, 11, 101, wire.flag_ack | wire.flag_fin, "last", 0);
    try check(try c.read(7, clean, &output, 0) == 4);
    try check(std.mem.eql(u8, output[0..4], "last"));
    try check(try c.read(7, clean, &output, 0) == 0);
    try check(!(try c.ready(7, clean)).write);
    try drain();
    try inject(remote, 16, 102, wire.flag_ack, "", 0);
    try check(try c.status(7, clean) == .eof);
    try c.close(7, clean);
    const rst = try establish(remote, listener, 0);
    try inject(remote, 11, 101, wire.flag_rst | wire.flag_ack, "", 0);
    try expected(error.PeerReset, c.read(7, rst, &output, 0));
    try check(c.liveChildren() == 1 and (try c.ready(7, rst)).terminal);
    try c.close(7, rst);
    print("socket-core: partial reads FIN reset terminal charging ok\n");

    checkpoint = "retry and flags";
    listener = reset();
    try inject(remote, 10, 0, wire.flag_syn, "", 0);
    try drain();
    for (0..300) |_| {
        try inject(remote, 10, 0, wire.flag_syn, "", 0);
        try drain();
    }
    try check(c.counters.retransmitted == core.retry_limit);
    const exhausted = try c.accept(7, listener);
    try check(try c.status(7, exhausted) == .timeout and c.liveChildren() == 1);
    try c.close(7, exhausted);
    const pending = try establish(remote, listener, 0);
    _ = try c.send(7, pending, "hold", 0);
    try drain();
    try inject(remote, 11, 105, wire.flag_syn | wire.flag_ack, "", 0);
    try check(c.children[0].?.tx_len == 24 and !(try c.ready(7, pending)).write);
    print("socket-core: retry ceiling unexpected SYN-ACK guards ok\n");

    checkpoint = "deadlines";
    for (0..4) |mode| {
        listener = reset();
        var handle: ?core.Handle = null;
        if (mode == 0) {
            try inject(remote, 10, 0, wire.flag_syn, "", 0);
        } else {
            handle = try establish(remote, listener, 0);
            if (mode == 2) {
                _ = try c.send(7, handle.?, "stall", 0);
                // The read budget extends past write expiry, independently.
                try inject(remote, 11, 101, wire.flag_ack, "r", 1);
                try check(try c.read(7, handle.?, output[0..1], 1) == 1);
            }
            if (mode == 3) try c.shutdown(7, handle.?, 1);
        }
        const expires = core.deadline_ns + @as(u64, if (mode == 3) 1 else 0);
        try c.poll(expires - 1);
        try check(c.children[0].?.state != .terminal);
        try c.poll(expires);
        const timed = handle orelse try c.accept(7, listener);
        try check(try c.status(7, timed) == .timeout);
        try expected(error.TimedOut, c.read(7, timed, &output, expires));
        try check(c.liveChildren() == 1 and c.children[0].?.tx_len == 0 and c.children[0].?.rx_len == 0);
        try c.close(7, timed);
        try check(c.liveChildren() == 0);
    }
    print("socket-core: four deadline boundaries ok\n");
    checkpoint = "death";
    for (0..5) |mode| {
        listener = reset();
        if (mode == 1) try inject(remote, 10, 0, wire.flag_syn, "", 0);
        if (mode >= 2) {
            const h = try establish(remote, listener, 0);
            if (mode == 3) try c.shutdown(7, h, 0);
            if (mode == 4) try inject(remote, 11, 101, wire.flag_rst, "", 0);
        }
        c.closeOwner(7);
        try check(c.liveChildren() == 0 and c.listener == null);
    }
    _ = reset();
    try expected(error.Unsupported, c.lookup("example.test"));
    try expected(error.Unsupported, c.connect(remote));
    c.closeOwner(7);
    print("socket-core: five death states unsupported DNS connect ok\n");
}
export fn socket_fixture_main(sp: usize) void {
    initial_sp = sp;
    scenarios() catch |err| {
        print("socket-core: FAIL ");
        print(checkpoint);
        print(" ");
        print(@errorName(err));
        print("\n");
        native.exit(70);
    };
    const bottom = initial_sp - (128 * 1024 + 4096);
    const paint: [*]const volatile u8 = @ptrFromInt(bottom);
    var untouched: usize = 0;
    while (untouched < 128 * 1024 + 4096 and paint[untouched] == 0xa5) : (untouched += 1) {}
    const used = 128 * 1024 + 4096 - untouched;
    if (used > 128 * 1024) native.exit(70);
    number("socket-core: core+scratch=", @sizeOf(core.Core) + wire.frame_max);
    number("socket-core: stack-high-water=", used);
    number("socket-core: checks=", checks);
    print("socket-core: injected-only done\n");
    native.exit(0);
}
