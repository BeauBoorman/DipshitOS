//! Injected B6 protocol/ownership tests, not syscall or live-network evidence.
const std = @import("std");
const core = @import("socket_core");
const wire = core.wire;
const t = std.testing;
const local: core.Endpoint = .{ .ip = .{ 10, 0, 0, 1 }, .port = 8090 };
const remote: core.Endpoint = .{ .ip = .{ 10, 0, 0, 2 }, .port = 5000 };
const other: core.Endpoint = .{ .ip = .{ 10, 0, 0, 3 }, .port = 5000 };
const guest_mac = [6]u8{ 2, 0, 0, 0, 0, 1 };
const peer_mac = [6]u8{ 2, 0, 0, 0, 0, 2 };

pub const Frame = struct {
    bytes: [wire.frame_max]u8 = undefined,
    len: usize,
    fn init(src: core.Endpoint, seq: u32, ack: u32, flags: u8, body: []const u8) Frame {
        return initTo(local, src, seq, ack, flags, body);
    }
    /// M99f (#2184): a frame addressed to any table endpoint — extra
    /// listeners and active-open connections sit on ports `init` cannot
    /// name.
    fn initTo(dst: core.Endpoint, src: core.Endpoint, seq: u32, ack: u32, flags: u8, body: []const u8) Frame {
        var segment: [wire.segment_max]u8 = undefined;
        const slen = wire.build_segment(&segment, src.ip, dst.ip, src.port, dst.port, seq, ack, flags, body);
        var frame: Frame = .{ .len = 0 };
        frame.len = wire.build_frame(&frame.bytes, &peer_mac, src.ip, guest_mac, dst.ip, segment[0..slen]);
        return frame;
    }
    fn inject(self: *const Frame, c: *core.Core, now: u64) !void {
        try c.receive(self.bytes[0..self.len], now, 100);
    }
    fn window(self: *Frame, value: u16) void {
        std.mem.writeInt(u16, self.bytes[48..50], value, .big);
        @memset(self.bytes[50..52], 0);
        std.mem.writeInt(u16, self.bytes[50..52], wire.checksum_tcp(remote.ip, local.ip, self.bytes[34..self.len]), .big);
    }
};
const Capture = struct {
    bytes: [wire.segment_max]u8 = undefined,
    len: usize = 0,
    endpoint: core.Endpoint = remote,
    mac: [6]u8 = undefined,
    fail: bool = false,
    calls: usize = 0,
    fn transmit(ctx: ?*anyopaque, out: core.Outbound) bool {
        const self: *Capture = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        if (self.fail) return false;
        @memcpy(self.bytes[0..out.bytes.len], out.bytes);
        self.len = out.bytes.len;
        self.endpoint = out.remote;
        self.mac = out.remote_mac;
        // Independent checksum verification uses the emitted endpoints.
        std.debug.assert(wire.checksum_tcp(out.local.ip, out.remote.ip, out.bytes) == 0);
        return true;
    }
    fn drain(self: *Capture, c: *core.Core) void {
        for (0..8) |_| if (c.flush(self, transmit) != .sent) return;
        unreachable;
    }
};
fn establish(c: *core.Core, cap: *Capture, endpoint: core.Endpoint, now: u64) !core.Handle {
    var frame = Frame.init(endpoint, 10, 0, wire.flag_syn, "");
    try frame.inject(c, now);
    cap.drain(c);
    frame = Frame.init(endpoint, 11, 101, wire.flag_ack, "");
    try frame.inject(c, now);
    return c.accept(7, c.listener.?.handle);
}
fn init(c: *core.Core) !core.Handle {
    c.* = .{};
    return c.listen(7, local, 0);
}

test "socket core: size includes owned wire scratch and refuses unsupported surfaces" {
    try t.expect(@sizeOf(core.Core) + wire.frame_max <= core.core_limit);
    var c: core.Core = .{};
    try t.expectError(error.Unsupported, c.lookup("example.test"));
    try t.expectError(error.Unsupported, c.connect(remote));
    try t.expectError(error.InvalidArgument, c.listen(7, .{ .ip = .{ 127, 0, 0, 1 }, .port = 8090 }, 0));
    try t.expectError(error.InvalidArgument, c.listen(7, .{ .ip = local.ip, .port = 0 }, 0));
}
test "socket core: listener admission, ownership, typed and stale tokens" {
    var c: core.Core = .{};
    const listener = try init(&c);
    try t.expectError(error.Capacity, c.listen(8, local, 0));
    try t.expectError(error.AccessDenied, c.accept(8, listener));
    try t.expectError(error.AccessDenied, c.close(8, listener));
    try t.expectError(error.InvalidHandle, c.send(7, listener, "x", 0));
    try t.expectError(error.WouldBlock, c.accept(7, listener));
    try c.close(7, listener);
    const newer = try c.listen(7, local, 0);
    try t.expect(newer.value != listener.value);
    try t.expectError(error.InvalidHandle, c.ready(7, listener));
    c.next_generation = (std.math.maxInt(u64) >> core.slot_bits) + 1;
    try c.close(7, newer);
    try t.expectError(error.Capacity, c.listen(7, local, 0));
}
test "socket core: two children, third refusal uses its own address and counts overflow" {
    var c: core.Core = .{};
    const listener = try init(&c);
    var cap: Capture = .{};
    const one = try establish(&c, &cap, remote, 0);
    const two = try establish(&c, &cap, other, 0);
    try t.expectEqual(@as(usize, 2), c.liveChildren());
    try t.expectError(error.InvalidHandle, c.accept(7, one));
    try t.expectError(error.AccessDenied, c.ready(8, one));
    try t.expectError(error.AccessDenied, c.read(8, one, &.{}, 0));
    try t.expectError(error.AccessDenied, c.send(8, one, "", 0));
    try t.expectError(error.AccessDenied, c.shutdown(8, one, 0));
    try t.expectError(error.AccessDenied, c.close(8, one));
    try t.expectEqual(@as(usize, 4), try c.send(7, one, "hold", 0));
    cap.drain(&c);
    var saved: [wire.segment_max]u8 = undefined;
    const len = c.children[0].?.tx_len;
    @memcpy(saved[0..len], c.children[0].?.tx[0..len]);
    const third: core.Endpoint = .{ .ip = .{ 10, 0, 0, 9 }, .port = 6000 };
    var frame = Frame.init(third, 0xffffffff, 0, wire.flag_syn, "");
    try frame.inject(&c, 0);
    frame = Frame.init(.{ .ip = .{ 10, 0, 0, 8 }, .port = 6001 }, 50, 0, wire.flag_syn, "");
    try frame.inject(&c, 0);
    try t.expectEqual(@as(u64, 2), c.counters.capacity_refused);
    try t.expectEqual(@as(u64, 1), c.counters.refusal_dropped);
    cap.drain(&c);
    try t.expectEqualDeep(third, cap.endpoint);
    try t.expectEqualSlices(u8, &peer_mac, &cap.mac);
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, cap.bytes[8..12], .big));
    try t.expectEqual(@as(u8, wire.flag_rst | wire.flag_ack), cap.bytes[13]);
    try t.expectEqualSlices(u8, saved[0..len], c.children[0].?.tx[0..len]);
    try c.close(7, two);
    frame = Frame.init(third, 30, 0, wire.flag_syn, "");
    try frame.inject(&c, 0);
    try t.expectEqual(@as(usize, 2), c.liveChildren());
    try t.expectError(error.InvalidHandle, c.ready(7, two));
    try c.close(7, listener);
    try t.expectEqual(@as(usize, 0), c.liveChildren());
}
test "socket core: partial reads, zero window and exact sequence prevent duplicate delivery" {
    var c: core.Core = .{};
    _ = try init(&c);
    var cap: Capture = .{};
    const h = try establish(&c, &cap, remote, 0);
    var frame = Frame.init(remote, 11, 101, wire.flag_ack, "abcdef");
    try frame.inject(&c, 1);
    cap.drain(&c);
    try t.expectEqual(@as(u16, 0), std.mem.readInt(u16, cap.bytes[14..16], .big));
    var buf: [8]u8 = undefined;
    try t.expectEqual(@as(usize, 2), try c.read(7, h, buf[0..2], 1));
    try t.expectEqualStrings("ab", buf[0..2]);
    try t.expect((try c.ready(7, h)).read);
    try frame.inject(&c, 1);
    frame = Frame.init(remote, 17, 101, wire.flag_ack, "next");
    try frame.inject(&c, 1);
    try t.expectEqual(@as(u64, 1), c.counters.duplicates);
    try t.expectEqual(@as(u64, 1), c.counters.rx_full);
    try t.expectEqual(@as(usize, 4), try c.read(7, h, &buf, 1));
    try t.expectEqualStrings("cdef", buf[0..4]);
    cap.drain(&c);
    try t.expectEqual(@as(u16, wire.payload_max), std.mem.readInt(u16, cap.bytes[14..16], .big));
    try t.expectError(error.WouldBlock, c.read(7, h, &buf, 1));
    try frame.inject(&c, 1);
    try t.expectEqual(@as(usize, 4), try c.read(7, h, &buf, 1));
    try t.expectEqualStrings("next", buf[0..4]);
}
test "socket core: full IPv4 tuple and malformed packets cannot mutate a child" {
    var c: core.Core = .{};
    _ = try init(&c);
    var cap: Capture = .{};
    const h = try establish(&c, &cap, remote, 0);
    var frame = Frame.init(other, 11, 101, wire.flag_ack, "foreign");
    try frame.inject(&c, 0);
    try t.expect(!(try c.ready(7, h)).read);
    frame = Frame.init(remote, 11, 101, wire.flag_ack, "good");
    for (0..frame.len) |cut| try c.receive(frame.bytes[0..cut], 0, 100);
    try t.expect(!(try c.ready(7, h)).read);
    var bad = frame;
    bad.bytes[50] ^= 1;
    try bad.inject(&c, 0);
    bad = frame;
    bad.bytes[46] = 0x60;
    try bad.inject(&c, 0);
    bad = frame;
    bad.bytes[20] = 0x20;
    try bad.inject(&c, 0);
    bad = frame;
    bad.bytes[14] = 0x46;
    try bad.inject(&c, 0);
    bad = frame;
    bad.bytes[33] = 9;
    try bad.inject(&c, 0);
    try t.expect(!(try c.ready(7, h)).read);
    try frame.inject(&c, 0);
    var buf: [8]u8 = undefined;
    try t.expectEqual(@as(usize, 4), try c.read(7, h, &buf, 0));
}
test "socket core: send enforces backpressure and short counts without replacing pending data" {
    var c: core.Core = .{};
    _ = try init(&c);
    var cap: Capture = .{};
    const h = try establish(&c, &cap, remote, 0);
    const body: [wire.payload_max + 1]u8 = @splat('z');
    try t.expectEqual(@as(usize, wire.payload_max), try c.send(7, h, &body, 0));
    try t.expect(!(try c.ready(7, h)).write);
    try t.expectError(error.WouldBlock, c.send(7, h, "overwrite", 0));
    try t.expectError(error.WouldBlock, c.shutdown(7, h, 0));
    cap.fail = true;
    try t.expectEqual(core.Flush.refused, c.flush(&cap, Capture.transmit));
    try t.expect(!c.children[0].?.tx_started);
    cap.fail = false;
    cap.drain(&c);
    var frame = Frame.init(remote, 11, 101 + wire.payload_max - 1, wire.flag_ack, "");
    try frame.inject(&c, 0);
    try t.expect(!(try c.ready(7, h)).write);
    frame = Frame.init(remote, 11, 101 + wire.payload_max + 1, wire.flag_ack, "");
    try frame.inject(&c, 0);
    try t.expect(!(try c.ready(7, h)).write);
    frame = Frame.init(remote, 11, 101 + wire.payload_max, wire.flag_ack, "");
    try frame.inject(&c, 0);
    try t.expect((try c.ready(7, h)).write);
}
test "socket core: byte-identical retransmission and ACK stop, failed TX retries fairly" {
    var c: core.Core = .{};
    _ = try init(&c);
    var cap: Capture = .{};
    const h = try establish(&c, &cap, remote, 0);
    _ = try establish(&c, &cap, other, 0);
    _ = try c.send(7, h, "hello", 0);
    cap.drain(&c);
    const original = cap.bytes;
    const len = cap.len;
    try c.poll(core.rto_ns - 1);
    try t.expectEqual(core.Flush.empty, c.flush(&cap, Capture.transmit));
    try c.poll(core.rto_ns);
    cap.fail = true;
    try t.expectEqual(core.Flush.refused, c.flush(&cap, Capture.transmit));
    try t.expectEqual(@as(u8, 0), c.children[0].?.retries);
    cap.fail = false;
    cap.drain(&c);
    try t.expectEqualSlices(u8, original[0..len], cap.bytes[0..cap.len]);
    try t.expectEqual(@as(u64, 1), c.counters.retransmitted);
    var frame = Frame.init(remote, 11, 106, wire.flag_ack, "");
    try frame.inject(&c, core.rto_ns);
    try c.poll(core.rto_ns * 2);
    try t.expectEqual(core.Flush.empty, c.flush(&cap, Capture.transmit));
}
test "socket core: half-open deadline boundary retains a charged, acceptable failure" {
    var c: core.Core = .{};
    const listener = try init(&c);
    var frame = Frame.init(remote, 10, 0, wire.flag_syn, "");
    try frame.inject(&c, 0);
    try frame.inject(&c, 0);
    try t.expectEqual(@as(usize, 1), c.liveChildren());
    try c.poll(core.deadline_ns - 1);
    try t.expect(!(try c.ready(7, listener)).accept);
    try c.poll(core.deadline_ns);
    try t.expect((try c.ready(7, listener)).accept);
    const h = try c.accept(7, listener);
    try t.expectEqual(core.Outcome.timeout, try c.status(7, h));
    try t.expectError(error.TimedOut, c.send(7, h, "x", core.deadline_ns));
    var buffer: [1]u8 = undefined;
    try t.expectError(error.TimedOut, c.read(7, h, &buffer, core.deadline_ns));
    try t.expectEqual(@as(usize, 1), c.liveChildren());
    try c.close(7, h);
    try t.expectEqual(@as(usize, 0), c.liveChildren());
}
test "socket core: read/write/close deadlines expire without a transport or scheduler" {
    for (0..3) |mode| {
        var c: core.Core = .{};
        _ = try init(&c);
        var cap: Capture = .{};
        const h = try establish(&c, &cap, remote, 0);
        if (mode == 1) {
            _ = try c.send(7, h, "pending", 0);
            // Isolate the write timeout from the read timeout.
            var frame = Frame.init(remote, 11, 101, wire.flag_ack, "r");
            try frame.inject(&c, 1);
            var byte: [1]u8 = undefined;
            _ = try c.read(7, h, &byte, 1);
        }
        if (mode == 2) try c.shutdown(7, h, 1);
        const expires = core.deadline_ns + @as(u64, if (mode == 2) 1 else 0);
        try c.poll(expires - 1);
        try t.expect(!(try c.ready(7, h)).terminal);
        try c.poll(expires);
        try t.expect((try c.ready(7, h)).terminal);
        try t.expectEqual(core.Outcome.timeout, try c.status(7, h));
        try t.expectEqual(@as(usize, 0), c.children[0].?.tx_len);
        try t.expectEqual(@as(usize, 1), c.liveChildren());
        c.closeOwner(7);
        try t.expectEqual(@as(usize, 0), c.liveChildren());
    }
}
test "socket core: clean FIN drains payload, reset differs from EOF, graceful FIN completes" {
    var c: core.Core = .{};
    _ = try init(&c);
    var cap: Capture = .{};
    const h = try establish(&c, &cap, remote, 0);
    var frame = Frame.init(remote, 11, 101, wire.flag_ack | wire.flag_fin, "last");
    try frame.inject(&c, 0);
    try t.expect(!(try c.ready(7, h)).write);
    var buf: [8]u8 = undefined;
    try t.expectEqual(@as(usize, 4), try c.read(7, h, &buf, 0));
    try t.expectEqualStrings("last", buf[0..4]);
    try t.expectEqual(@as(usize, 0), try c.read(7, h, &buf, 0));
    cap.drain(&c);
    frame = Frame.init(remote, 16, 102, wire.flag_ack, "");
    try frame.inject(&c, 0);
    try t.expectEqual(core.Outcome.eof, try c.status(7, h));
    try c.close(7, h);
    const reset = try establish(&c, &cap, remote, 0);
    frame = Frame.init(remote, 11, 101, wire.flag_rst | wire.flag_ack, "");
    try frame.inject(&c, 0);
    try t.expectError(error.PeerReset, c.read(7, reset, &buf, 0));
    try t.expect((try c.ready(7, reset)).terminal);
    try c.close(7, reset);
    const closing = try establish(&c, &cap, remote, 0);
    try c.shutdown(7, closing, 0);
    cap.drain(&c);
    frame = Frame.init(remote, 11, 102, wire.flag_fin | wire.flag_ack, "");
    try frame.inject(&c, 0);
    try t.expectEqual(core.Outcome.eof, try c.status(7, closing));
}
test "socket core: owner death covers every state and never reuses a stale token" {
    for (0..4) |mode| {
        var c: core.Core = .{};
        const l = try init(&c);
        var cap: Capture = .{};
        if (mode != 0) {
            if (mode == 1) {
                var frame = Frame.init(remote, 10, 0, wire.flag_syn, "");
                try frame.inject(&c, 0);
            } else {
                const h = try establish(&c, &cap, remote, 0);
                if (mode == 3) try c.shutdown(7, h, 0);
            }
        }
        c.closeOwner(8);
        try t.expect(c.listener != null);
        c.closeOwner(7);
        c.closeOwner(7);
        try t.expect(c.listener == null);
        try t.expectEqual(@as(usize, 0), c.liveChildren());
        const next = try c.listen(7, local, 0);
        try t.expect(next.value != l.value);
        try t.expectError(error.InvalidHandle, c.close(7, l));
    }
}
test "socket core: monotonic time and overflowing deadline arithmetic are bounded" {
    var c: core.Core = .{};
    _ = try c.listen(7, local, std.math.maxInt(u64) - 1);
    var frame = Frame.init(remote, 10, 0, wire.flag_syn, "");
    try frame.inject(&c, std.math.maxInt(u64) - 1);
    try t.expectError(error.ClockWentBackwards, c.poll(0));
    try c.poll(std.math.maxInt(u64));
    try t.expectEqual(core.State.terminal, c.children[0].?.state);
}

test "socket core: expired receive and application operations cannot bypass poll deadlines" {
    for (0..3) |mode| {
        var c: core.Core = .{};
        const l = try init(&c);
        var cap: Capture = .{};
        if (mode == 0) {
            var frame = Frame.init(remote, 10, 0, wire.flag_syn, "");
            try frame.inject(&c, 0);
            cap.drain(&c);
            frame = Frame.init(remote, 11, 101, wire.flag_ack, "late");
            try frame.inject(&c, core.deadline_ns);
            const h = try c.accept(7, l);
            try t.expectEqual(core.Outcome.timeout, try c.status(7, h));
        } else {
            const h = try establish(&c, &cap, remote, 0);
            if (mode == 1) {
                try t.expectError(error.TimedOut, c.send(7, h, "late", core.deadline_ns));
            } else {
                var buffer: [8]u8 = undefined;
                try t.expectError(error.TimedOut, c.read(7, h, &buffer, core.deadline_ns));
            }
        }
    }
}
test "socket core: ten retry ceiling is subordinate to the thirty-second outer deadline" {
    var c: core.Core = .{};
    _ = try init(&c);
    var cap: Capture = .{};
    const h = try establish(&c, &cap, remote, 0);
    _ = try c.send(7, h, "dark", 0);
    cap.drain(&c);
    for (1..10) |n| {
        try c.poll(core.rto_ns * n);
        cap.drain(&c);
    }
    try t.expectEqual(@as(u64, 9), c.counters.retransmitted);
    try c.poll(core.deadline_ns);
    try t.expectEqual(core.Flush.empty, c.flush(&cap, Capture.transmit));
    try t.expectEqual(core.Outcome.timeout, try c.status(7, h));
    try t.expect(c.counters.retransmitted <= core.retry_limit);
}
test "socket core: stalled TX does not block other child or refusal progress" {
    var c: core.Core = .{};
    _ = try init(&c);
    var cap: Capture = .{};
    const first = try establish(&c, &cap, remote, 0);
    const second = try establish(&c, &cap, other, 0);
    _ = try c.send(7, first, "stalled", 0);
    _ = try c.send(7, second, "progress", 0);
    cap.fail = true;
    try t.expectEqual(core.Flush.refused, c.flush(&cap, Capture.transmit));
    cap.fail = false;
    try t.expectEqual(core.Flush.sent, c.flush(&cap, Capture.transmit));
    try t.expectEqualDeep(other, cap.endpoint);
    try t.expect(!c.children[0].?.tx_started and c.children[1].?.tx_started);
    var frame = Frame.init(other, 11, 109, wire.flag_ack, "");
    try frame.inject(&c, 0);
    try t.expect((try c.ready(7, second)).write);
    try t.expect(!(try c.ready(7, first)).write);
}
test "socket core: repeated close/death fully recovers bounded capacity without token aliasing" {
    var c: core.Core = .{};
    var previous: ?core.Handle = null;
    var cap: Capture = .{};
    for (0..64) |_| {
        const listener = try c.listen(7, local, 0);
        const h = try establish(&c, &cap, remote, 0);
        if (previous) |stale| try t.expectError(error.InvalidHandle, c.send(7, stale, "stale", 0));
        previous = h;
        try c.close(7, listener);
        try t.expectEqual(@as(usize, 0), c.liveChildren());
        try t.expect(c.listener == null and c.refusal == null);
        c.closeOwner(7);
    }
}
test "socket core: clean FIN retains unread bytes across graceful completion" {
    var c: core.Core = .{};
    _ = try init(&c);
    var cap: Capture = .{};
    const h = try establish(&c, &cap, remote, 0);
    var frame = Frame.init(remote, 11, 101, wire.flag_fin | wire.flag_ack, "tail");
    try frame.inject(&c, 0);
    cap.drain(&c);
    frame = Frame.init(remote, 16, 102, wire.flag_ack, "");
    try frame.inject(&c, 0);
    try t.expectEqual(core.Outcome.eof, try c.status(7, h));
    var output: [8]u8 = undefined;
    try t.expectEqual(@as(usize, 4), try c.read(7, h, &output, 0));
    try t.expectEqualStrings("tail", output[0..4]);
    try t.expectEqual(@as(usize, 0), try c.read(7, h, &output, 0));
}

test "socket core: peer zero-window backpressure and short-window writes are explicit" {
    var c: core.Core = .{};
    _ = try init(&c);
    var cap: Capture = .{};
    const h = try establish(&c, &cap, remote, 0);
    var frame = Frame.init(remote, 11, 101, wire.flag_ack, "");
    frame.window(0);
    try frame.inject(&c, 0);
    try t.expect(!(try c.ready(7, h)).write);
    try t.expectError(error.WouldBlock, c.send(7, h, "hello", 0));
    frame.window(2);
    try frame.inject(&c, 0);
    try t.expect((try c.ready(7, h)).write);
    try t.expectEqual(@as(usize, 2), try c.send(7, h, "hello", 0));
    // An ACK must not retire data before the transport accepted it.
    frame = Frame.init(remote, 11, 103, wire.flag_ack, "");
    try frame.inject(&c, 0);
    try t.expectEqual(@as(usize, 22), c.children[0].?.tx_len);
    cap.drain(&c);
    try frame.inject(&c, 0);
    try t.expect((try c.ready(7, h)).write);
}

test "socket core: repeated SYNs cannot bypass ten retries or overflow the retry counter" {
    var c: core.Core = .{};
    const listener = try init(&c);
    var cap: Capture = .{};
    var frame = Frame.init(remote, 10, 0, wire.flag_syn, "");
    try frame.inject(&c, 0);
    cap.drain(&c);
    for (0..300) |_| {
        try frame.inject(&c, 0);
        cap.drain(&c);
    }
    try t.expectEqual(@as(u64, core.retry_limit), c.counters.retransmitted);
    const h = try c.accept(7, listener);
    try t.expectEqual(core.Outcome.timeout, try c.status(7, h));
    try t.expectEqual(@as(usize, 1), c.liveChildren());
    // A charged terminal tuple must refuse reconnect, not silently replace it.
    const previous = c.children[0].?.handle;
    try frame.inject(&c, 0);
    cap.drain(&c);
    try t.expectEqualDeep(remote, cap.endpoint);
    try t.expectEqual(@as(u8, wire.flag_rst | wire.flag_ack), cap.bytes[13]);
    try t.expectEqual(previous.value, c.children[0].?.handle.value);
}
test "socket core: unexpected SYN-ACK cannot retire established pending data" {
    var c: core.Core = .{};
    _ = try init(&c);
    var cap: Capture = .{};
    const h = try establish(&c, &cap, remote, 0);
    _ = try c.send(7, h, "hold", 0);
    cap.drain(&c);
    var frame = Frame.init(remote, 11, 105, wire.flag_syn | wire.flag_ack, "");
    try frame.inject(&c, 0);
    try t.expectEqual(@as(usize, 24), c.children[0].?.tx_len);
    try t.expect(!(try c.ready(7, h)).write);
}

test "socket core: checksum-valid fragments and reserved IPv4 flags are refused" {
    var c: core.Core = .{};
    _ = try init(&c);
    var cap: Capture = .{};
    const h = try establish(&c, &cap, remote, 0);
    var frame = Frame.init(remote, 11, 101, wire.flag_ack, "valid");
    for ([_]u16{ 0x2000, 1, 0x8000 }) |flags| {
        var bad = frame;
        std.mem.writeInt(u16, bad.bytes[20..22], flags, .big);
        @memset(bad.bytes[24..26], 0);
        std.mem.writeInt(u16, bad.bytes[24..26], wire.fold(wire.sum_words(bad.bytes[14..34])), .big);
        try bad.inject(&c, 0);
        try t.expect(!(try c.ready(7, h)).read);
    }
    try t.expectEqual(@as(u64, 3), c.counters.malformed);
    // DF is the only accepted flag and does not make this packet a fragment.
    std.mem.writeInt(u16, frame.bytes[20..22], 0x4000, .big);
    @memset(frame.bytes[24..26], 0);
    std.mem.writeInt(u16, frame.bytes[24..26], wire.fold(wire.sum_words(frame.bytes[14..34])), .big);
    try frame.inject(&c, 0);
    try t.expect((try c.ready(7, h)).read);
}

// --- M99f (#2184): the real per-process socket table -------------------------

test "socket core: four listeners on distinct ports, fifth is Capacity, ports never shared" {
    var c: core.Core = .{};
    const first = try c.listen(7, local, 0);
    const second = try c.listen(8, .{ .ip = local.ip, .port = 8091 }, 0);
    _ = try c.listen(9, .{ .ip = local.ip, .port = 8092 }, 0);
    _ = try c.listen(10, .{ .ip = local.ip, .port = 8093 }, 0);
    // The system listener bound, the one-listener-per-owner bound and the
    // shared-port refusal are all honest Capacity, not silent sharing.
    try t.expectError(error.Capacity, c.listen(11, .{ .ip = local.ip, .port = 8094 }, 0));
    try t.expectError(error.Capacity, c.listen(8, .{ .ip = local.ip, .port = 8099 }, 0));
    try t.expectError(error.Capacity, c.listen(11, local, 0));
    try t.expect((first.value & core.slot_mask) != (second.value & core.slot_mask));
    // Closing a mid-table listener frees its slot; the stale token is dead
    // even after a new listener lands in it (the generation turns).
    try c.close(8, second);
    const newer = try c.listen(11, .{ .ip = local.ip, .port = 8094 }, 0);
    try t.expectError(error.InvalidHandle, c.ready(8, second));
    try t.expect((newer.value & core.slot_mask) == (second.value & core.slot_mask));
    try t.expect(newer.value != second.value);
    try c.close(7, first);
    try t.expectEqual(@as(usize, 3), c.ownedSockets(9) + c.ownedSockets(10) + c.ownedSockets(11));
}

test "socket core: children across two listeners demux by tuple and close reclaims only siblings" {
    var c: core.Core = .{};
    const first = try c.listen(7, local, 0);
    const second_l: core.Endpoint = .{ .ip = local.ip, .port = 8091 };
    const second = try c.listen(8, second_l, 0);
    var cap: Capture = .{};
    var f = Frame.init(remote, 10, 0, wire.flag_syn, "");
    try f.inject(&c, 0);
    var g = Frame.initTo(second_l, other, 20, 0, wire.flag_syn, "");
    try g.inject(&c, 0);
    try t.expectEqual(@as(usize, 2), c.liveChildren());
    cap.drain(&c);
    f = Frame.init(remote, 11, 101, wire.flag_ack, "");
    try f.inject(&c, 0);
    const child0 = try c.accept(7, first);
    g = Frame.initTo(second_l, other, 21, 101, wire.flag_ack, "");
    try g.inject(&c, 0);
    const child1 = try c.accept(8, second);
    try t.expect((child0.value & core.slot_mask) != (child1.value & core.slot_mask));
    // Payload to listener-1's tuple never reaches listener-0's child.
    g = Frame.initTo(second_l, other, 21, 101, wire.flag_ack, "hi");
    try g.inject(&c, 0);
    var buf: [8]u8 = undefined;
    try t.expectError(error.WouldBlock, c.read(7, child0, &buf, 0));
    try t.expectEqual(@as(usize, 2), try c.read(8, child1, &buf, 0));
    try t.expectEqualStrings("hi", buf[0..2]);
    // Closing one listener reclaims only ITS children — the other
    // listener's connection is untouched.
    try c.close(7, first);
    try t.expectError(error.InvalidHandle, c.status(7, child0));
    try t.expectEqual(core.Outcome.none, try c.status(8, child1));
    try t.expectEqual(@as(usize, 1), c.liveChildren());
    try c.close(8, second);
    try t.expectEqual(@as(usize, 0), c.liveChildren());
}

test "socket core: active open SYN-ACK establishes, stale conn token dies on reuse" {
    var c: core.Core = .{};
    var cap: Capture = .{};
    const isn: u32 = 0x11111111;
    const server: core.Endpoint = .{ .ip = .{ 10, 0, 0, 2 }, .port = 80 };
    const h = try c.open(7, .{ .ip = local.ip, .port = 8000 }, server, peer_mac, 0, isn);
    cap.drain(&c); // the queued SYN goes out to the server tuple
    try t.expectEqualDeep(server, cap.endpoint);
    try t.expectEqual(@as(u8, wire.flag_syn), cap.bytes[13]);
    try t.expectEqual(isn, std.mem.readInt(u32, cap.bytes[4..8], .big));
    try t.expectEqual(@as(usize, 1), c.liveChildren());
    try t.expectEqual(core.no_parent, c.children[0].?.parent);
    // A SYN-ACK covering our SYN completes the handshake and queues the ACK.
    var frame = Frame.initTo(.{ .ip = local.ip, .port = 8000 }, server, 77, isn +% 1, wire.flag_syn | wire.flag_ack, "");
    try frame.inject(&c, 0);
    try t.expectEqual(core.State.established, c.children[0].?.state);
    cap.drain(&c);
    try t.expectEqual(@as(u8, wire.flag_ack), cap.bytes[13]);
    try t.expect((try c.ready(7, h)).write);
    // Data flows both ways on the one table engine.
    try t.expectEqual(@as(usize, 2), try c.send(7, h, "hi", 0));
    cap.drain(&c);
    frame = Frame.initTo(.{ .ip = local.ip, .port = 8000 }, server, 78, isn +% 3, wire.flag_ack, "yo");
    try frame.inject(&c, 0);
    var buf: [8]u8 = undefined;
    try t.expectEqual(@as(usize, 2), try c.read(7, h, &buf, 0));
    try t.expectEqualStrings("yo", buf[0..2]);
    // Close + re-open into the same slot: the old handle is dead.
    try c.close(7, h);
    const again = try c.open(7, .{ .ip = local.ip, .port = 8000 }, server, peer_mac, 0, isn);
    try t.expectError(error.InvalidHandle, c.send(7, h, "x", 0));
    try t.expect((again.value & core.slot_mask) == (h.value & core.slot_mask));
    try c.close(7, again);
    try t.expectEqual(@as(usize, 0), c.liveChildren());
}

test "socket core: owner and system bounds are honest Capacity, owner death reclaims" {
    var c: core.Core = .{};
    var cap: Capture = .{};
    const server: core.Endpoint = .{ .ip = .{ 10, 0, 0, 2 }, .port = 80 };
    _ = try c.listen(7, local, 0);
    // Owner 7: listener + two children = 3 sockets; a fourth fits.
    _ = try establish(&c, &cap, remote, 0);
    _ = try establish(&c, &cap, other, 0);
    _ = try c.open(7, .{ .ip = local.ip, .port = 8000 }, server, peer_mac, 0, 5);
    // The fifth socket for the same owner is refused at the door.
    try t.expectError(error.Capacity, c.open(7, .{ .ip = local.ip, .port = 8001 }, server, peer_mac, 0, 5));
    // No silent port sharing: another owner cannot claim a live local port.
    try t.expectError(error.Capacity, c.open(8, local, server, peer_mac, 0, 5));
    // The system connection bound: one more open fills the table; a SYN to
    // the listener then gets the counted RST, never a silent drop.
    _ = try c.open(8, .{ .ip = local.ip, .port = 8002 }, server, peer_mac, 0, 5);
    try t.expectError(error.Capacity, c.open(9, .{ .ip = local.ip, .port = 8003 }, server, peer_mac, 0, 5));
    var frame = Frame.init(.{ .ip = .{ 10, 0, 0, 9 }, .port = 6000 }, 30, 0, wire.flag_syn, "");
    try frame.inject(&c, 0);
    try t.expectEqual(@as(u64, 1), c.counters.capacity_refused);
    cap.drain(&c);
    try t.expectEqual(@as(u8, wire.flag_rst | wire.flag_ack), cap.bytes[13]);
    // Owner death reclaims all of one owner's sockets and nothing else's.
    c.closeOwner(7);
    try t.expectEqual(@as(usize, 0), c.ownedSockets(7));
    try t.expectEqual(@as(usize, 1), c.liveChildren());
    try t.expectEqual(@as(usize, 1), c.ownedSockets(8));
}
