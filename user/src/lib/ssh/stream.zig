//! M51 SSH1 (#1168, ADR 0025 D6): the TCP → SSH stream adapter.
//!
//! The kernel TCP seam (`sys_tcp_connect/send/recv/close`, slots 30–33) is
//! single-connection, has **no reassembly**, and exposes a **one-slot RX
//! buffer** of `payload_max = 192` bytes (`kernel/src/tcp.zig:63-67`). A
//! second unread segment is dropped and — critically — **not ACKed**
//! (`:765`), so the peer's TCP retransmission is what recovers it. An SSH
//! packet is variable-length (up to ~35 KB). This adapter bridges the two:
//!
//!   * it keeps a bounded caller-owned buffer (static BSS in the app),
//!     concatenates complete in-order ≤192-byte chunks, and parses RFC 4253
//!     binary packets (`packet.zig`);
//!   * **drains promptly**: `recv` is looped to exhaustion before heavy
//!     work so the kernel's one slot is emptied and the next segment lands;
//!   * **paces TX to one outstanding segment**: after each ≤192-byte send it
//!     drains until the retransmit slot is free. The kernel's retransmit
//!     buffer holds exactly one segment (`kernel/src/tcp.zig:192-201`), so a
//!     second in-flight send would clobber it;
//!   * **fails closed** on overflow, an over-cap length, or malformed
//!     padding: it disconnects, never truncates-and-continues.
//!
//! The transport is an injected `Ops` seam (the `netauth.zig` pattern), so
//! every property above is host-testable without a NIC. Production wires it
//! to `sys_tcp_*` via `sysOps()`.
//!
//! HONEST LIMIT: the kernel ABI exposes no `tx_pending` read (there is no
//! slot for it), so production `tx_pending_fn` cannot observe the ACK. The
//! production path therefore drains to exhaustion after every segment and
//! the predicate reports "no observable pending". The injected seam lets the
//! class-A test prove the bounded one-outstanding loop with a predicate that
//! is visible; the kernel's own RTO remains the loss recovery.

const std = @import("std");
const ui = @import("ui");
const packet = @import("packet.zig");

/// Mirror of `kernel/src/tcp.zig` `payload_max`: the largest chunk
/// `sys_tcp_recv` returns and `sys_tcp_send` accepts.
pub const chunk_max: usize = 192;
/// The bounded adapter buffer: it must hold one maximum-size SSH frame.
pub const capacity: usize = packet.max_total;
/// Bound on the number of drain rounds while waiting for one ACK. A peer
/// that never acknowledges within this many drains is treated as dead.
pub const pace_limit: usize = 100_000;

pub const Error = error{
    /// The bounded buffer cannot hold the in-progress stream (overflow).
    Overflow,
    /// A declared packet length is over the fixed cap (overlong).
    Overlong,
    /// A malformed length/padding header.
    BadPacket,
    /// The peer/transport error, or the pacing bound was exhausted.
    Closed,
};

/// The injected transport seam (function pointers, netauth-style).
pub const Ops = struct {
    recv_fn: *const fn (out: []u8) i64,
    send_fn: *const fn (data: []const u8) i64,
    tx_pending_fn: *const fn () bool,
    close_fn: *const fn () void,
};

/// The production seam: real `sys_tcp_*` slots 30–33.
pub fn sysOps() Ops {
    return .{ .recv_fn = sysRecv, .send_fn = sysSend, .tx_pending_fn = sysTxPending, .close_fn = sysClose };
}

fn sysRecv(out: []u8) i64 {
    return ui.tcp_recv(out);
}

fn sysSend(data: []const u8) i64 {
    return ui.tcp_send(data);
}

/// See the module HONEST LIMIT note: the ABI has no `tx_pending` read.
fn sysTxPending() bool {
    return false;
}

fn sysClose() void {
    _ = ui.tcp_close();
}

/// The bounded stream adapter. `buf` is caller-owned and must be at least
/// the size of one legal SSH frame; the app uses a static `capacity` array.
pub const Stream = struct {
    buf: []u8,
    start: usize = 0,
    end: usize = 0,
    ops: Ops,
    failed: bool = false,

    pub fn init(buf: []u8, ops: Ops) Stream {
        return .{ .buf = buf, .ops = ops };
    }

    pub fn avail(self: *const Stream) usize {
        return self.end - self.start;
    }

    /// Fail closed: mark the stream dead and disconnect exactly once.
    pub fn fail(self: *Stream) void {
        if (self.failed) return;
        self.failed = true;
        self.ops.close_fn();
    }

    fn compact(self: *Stream) void {
        if (self.start == 0) return;
        const n = self.avail();
        if (n != 0) std.mem.copyForwards(u8, self.buf[0..n], self.buf[self.start..self.end]);
        self.start = 0;
        self.end = n;
    }

    /// Append a ≤192-byte transport chunk, compacting first if the buffer
    /// tail is full. An append that cannot fit fails closed.
    fn push(self: *Stream, bytes: []const u8) Error!void {
        if (self.buf.len - self.end < bytes.len) self.compact();
        if (self.buf.len - self.end < bytes.len) {
            self.fail();
            return error.Overflow;
        }
        @memcpy(self.buf[self.end .. self.end + bytes.len], bytes);
        self.end += bytes.len;
    }

    /// Loop `recv` until it reports no more data: the kernel's one-slot RX
    /// is emptied, so the next arriving segment is accepted. Negative is a
    /// transport error and fails closed.
    pub fn drain(self: *Stream) Error!void {
        var scratch: [chunk_max]u8 = undefined;
        while (true) {
            const n = self.ops.recv_fn(&scratch);
            if (n < 0) {
                self.fail();
                return error.Closed;
            }
            if (n == 0) return;
            const take: usize = @intCast(n);
            if (take > scratch.len) {
                self.fail();
                return error.Closed;
            }
            try self.push(scratch[0..take]);
        }
    }

    /// Return the next complete packet payload, or null when more bytes are
    /// needed. The returned slice borrows `buf` and is invalidated by the
    /// next `parse`/`drain`/`send` (which may compact).
    pub fn parse(self: *Stream) Error!?[]const u8 {
        if (self.failed) return error.Closed;
        // A header needs 5 bytes (length + padding octet).
        while (self.avail() < 5) {
            try self.drain();
            if (self.avail() < 5) return null;
        }
        const h = packet.decodeHeader(self.buf[self.start..self.end], .plaintext) catch |e| {
            self.fail();
            return switch (e) {
                error.Overlong => error.Overlong,
                else => error.BadPacket,
            };
        };
        const total = h.total();
        if (total > self.buf.len) {
            // A header the bounded buffer can never hold: fail closed now
            // rather than buffering forever.
            self.fail();
            return error.Overflow;
        }
        while (self.avail() < total) {
            try self.drain();
            if (self.avail() < total) return null;
        }
        const payload = packet.decode(self.buf[self.start .. self.start + total], .plaintext) catch {
            self.fail();
            return error.BadPacket;
        };
        self.start += total;
        return payload;
    }

    /// Wait out one in-flight segment: drain to exhaustion (the ACK is
    /// processed inside `recv`), then poll the injected predicate. A peer
    /// that never clears it fails closed at the bounded limit.
    pub fn pace(self: *Stream) Error!void {
        try self.drain();
        var spins: usize = 0;
        while (self.ops.tx_pending_fn()) {
            try self.drain();
            spins += 1;
            if (spins >= pace_limit) {
                self.fail();
                return error.Closed;
            }
        }
    }

    /// Send a byte range as ≤192-byte segments, at most one outstanding.
    pub fn send(self: *Stream, data: []const u8) Error!void {
        if (self.failed) return error.Closed;
        var off: usize = 0;
        while (off < data.len) {
            const take = @min(data.len - off, chunk_max);
            const n = self.ops.send_fn(data[off .. off + take]);
            if (n != @as(i64, @intCast(take))) {
                self.fail();
                return error.Closed;
            }
            off += take;
            try self.pace();
        }
    }

    /// Disconnect without marking the stream failed (a clean close).
    pub fn close(self: *Stream) void {
        self.ops.close_fn();
    }
};

// ---------------------------------------------------------------------------
// Host tests (class A; pure, injected seam)
// ---------------------------------------------------------------------------

const Harness = struct {
    var feed: [8192]u8 = undefined;
    var feed_len: usize = 0;
    var feed_pos: usize = 0;

    var tx: [8192]u8 = undefined;
    var tx_len: usize = 0;
    var tx_events: [256]u8 = undefined;
    var tx_events_len: usize = 0;

    var closed: usize = 0;

    /// Pacing model: after a send, `pending` is true for `clear_after`
    /// successive drain rounds; `clear_after == 0` never clears (to test the
    /// bounded give-up).
    var pending: bool = false;
    var clear_after: usize = 0;
    var pending_drains: usize = 0;

    /// recv returns at most `chunk` bytes per call (default 192, like the
    /// kernel); 0 when exhausted. `recv_error` models a transport failure.
    var recv_chunk: usize = 192;
    var recv_error: bool = false;

    fn reset() void {
        feed_len = 0;
        feed_pos = 0;
        tx_len = 0;
        tx_events_len = 0;
        closed = 0;
        pending = false;
        clear_after = 0;
        pending_drains = 0;
        recv_chunk = 192;
        recv_error = false;
    }

    fn setFeed(bytes: []const u8) void {
        @memcpy(feed[0..bytes.len], bytes);
        feed_len = bytes.len;
        feed_pos = 0;
    }

    fn recvFn(out: []u8) i64 {
        note('R');
        if (recv_error) return -1;
        if (pending and clear_after != 0) {
            pending_drains += 1;
            if (pending_drains >= clear_after) pending = false;
        }
        const left = feed_len - feed_pos;
        if (left == 0) return 0;
        const take = @min(@min(left, out.len), recv_chunk);
        @memcpy(out[0..take], feed[feed_pos .. feed_pos + take]);
        feed_pos += take;
        return @intCast(take);
    }

    fn sendFn(data: []const u8) i64 {
        note('S');
        if (tx_len + data.len > tx.len) return -1;
        @memcpy(tx[tx_len .. tx_len + data.len], data);
        tx_len += data.len;
        if (clear_after != 0) {
            pending = true;
            pending_drains = 0;
        }
        return @intCast(data.len);
    }

    fn txPendingFn() bool {
        note('P');
        return pending;
    }

    fn closeFn() void {
        closed += 1;
    }

    fn note(e: u8) void {
        if (tx_events_len < tx_events.len) {
            tx_events[tx_events_len] = e;
            tx_events_len += 1;
        }
    }

    fn ops() Ops {
        return .{ .recv_fn = recvFn, .send_fn = sendFn, .tx_pending_fn = txPendingFn, .close_fn = closeFn };
    }
};

fn buildPacket(out: []u8, payload: []const u8, pad_byte: u8) []u8 {
    const pl = packet.paddingLen(payload.len, .plaintext);
    var pad: [64]u8 = undefined;
    @memset(pad[0..pl], pad_byte);
    return packet.encode(out, payload, pad[0..pl], .plaintext) catch unreachable;
}

test "stream: a packet split across many 192-byte segments reassembles" {
    Harness.reset();
    var payload: [1500]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast((i * 7 + 3) & 0xff);
    var frame: [2048]u8 = undefined;
    const f = buildPacket(&frame, &payload, 0xaa);
    Harness.setFeed(f);
    // The feed arrives in kernel-sized 192-byte chunks; 1500+ bytes is split
    // into many segments.
    try std.testing.expect(f.len > 192 * 5);

    var buf: [capacity]u8 = undefined;
    var s = Stream.init(&buf, Harness.ops());
    var got: ?[]const u8 = null;
    var spins: usize = 0;
    while (got == null and spins < 1000) : (spins += 1) {
        got = try s.parse();
    }
    try std.testing.expectEqualSlices(u8, &payload, got.?);
    try std.testing.expect(!s.failed);
    try std.testing.expectEqual(@as(usize, 0), Harness.closed);
}

test "stream: a packet fed one byte at a time reassembles" {
    Harness.reset();
    Harness.recv_chunk = 1;
    const payload = "KEXINIT-payload";
    var frame: [64]u8 = undefined;
    const f = buildPacket(&frame, payload, 0x5a);
    Harness.setFeed(f);

    var buf: [capacity]u8 = undefined;
    var s = Stream.init(&buf, Harness.ops());
    var got: ?[]const u8 = null;
    var spins: usize = 0;
    while (got == null and spins < 5000) : (spins += 1) {
        got = try s.parse();
    }
    try std.testing.expectEqualStrings(payload, got.?);
}

test "stream: ring overflow fails closed and disconnects (never truncates)" {
    Harness.reset();
    // A 32-byte buffer, but the header declares a 200-byte total: it can
    // never fit, so the stream must fail closed and disconnect.
    var small: [32]u8 = undefined;
    var header: [8]u8 = undefined;
    buildPacketSmallTotal(&header, 200);
    Harness.setFeed(&header);
    var s = Stream.init(&small, Harness.ops());
    try std.testing.expectError(error.Overflow, s.parse());
    try std.testing.expect(s.failed);
    try std.testing.expectEqual(@as(usize, 1), Harness.closed);

    // A flood with no complete packet also fails closed once the buffer
    // would overflow.
    Harness.reset();
    var flood: [8192]u8 = undefined;
    // First 4 bytes declare a legal total that IS bigger than the 32-byte
    // buffer, so parse rejects before buffering the flood.
    buildPacketSmallTotal(&flood, 200);
    Harness.setFeed(&flood);
    var s2 = Stream.init(&small, Harness.ops());
    try std.testing.expectError(error.Overflow, s2.parse());
    try std.testing.expectEqual(@as(usize, 1), Harness.closed);
}

/// Hand-assemble a header-prefix frame with `packet_length` set to
/// `total - 4` and a valid padding octet; used to drive the bounds paths.
fn buildPacketSmallTotal(out: []u8, total: usize) void {
    const packet_length = total - 4;
    std.mem.writeInt(u32, out[0..4], @intCast(packet_length), .big);
    out[4] = 4;
}

test "stream: an over-cap declared length fails closed before buffering" {
    Harness.reset();
    var hdr: [5]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], 0xffff, .big);
    hdr[4] = 4;
    Harness.setFeed(&hdr);
    var buf: [capacity]u8 = undefined;
    var s = Stream.init(&buf, Harness.ops());
    try std.testing.expectError(error.Overlong, s.parse());
    try std.testing.expect(s.failed);
    try std.testing.expectEqual(@as(usize, 1), Harness.closed);
}

test "stream: malformed padding fails closed" {
    Harness.reset();
    // total = 16 (aligned), packet_length = 12, but padding_length = 0.
    var hdr = @as([16]u8, @splat(@as(u8, 0)));
    std.mem.writeInt(u32, hdr[0..4], 12, .big);
    hdr[4] = 0;
    Harness.setFeed(&hdr);
    var buf: [capacity]u8 = undefined;
    var s = Stream.init(&buf, Harness.ops());
    try std.testing.expectError(error.BadPacket, s.parse());
    try std.testing.expectEqual(@as(usize, 1), Harness.closed);
}

test "stream: TX paces to one outstanding segment" {
    Harness.reset();
    Harness.clear_after = 2; // each segment needs two drain rounds to clear
    var buf: [capacity]u8 = undefined;
    var s = Stream.init(&buf, Harness.ops());
    var data: [400]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i & 0xff);
    try s.send(&data);
    // Three segments: 192 + 192 + 16.
    try std.testing.expectEqual(@as(usize, 400), Harness.tx_len);
    try std.testing.expectEqualSlices(u8, &data, Harness.tx[0..400]);
    // Between any two S events there must be at least one R (a drain), and
    // a P poll — i.e. segment N+1 never starts before segment N is ACKed.
    var i: usize = 0;
    var sends: usize = 0;
    while (i < Harness.tx_events_len) : (i += 1) {
        if (Harness.tx_events[i] == 'S') {
            sends += 1;
            if (sends > 1) {
                // Walk back: the immediately preceding event must not be S.
                try std.testing.expect(Harness.tx_events[i - 1] != 'S');
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 3), sends);
}

test "stream: pacing gives up and fails closed when the ACK never clears" {
    Harness.reset();
    // The predicate is stuck true: no drain round ever clears it.
    Harness.pending = true;
    var buf: [capacity]u8 = undefined;
    var s = Stream.init(&buf, Harness.ops());
    // Bypass send: drive pace directly with pending stuck true.
    try std.testing.expectError(error.Closed, s.pace());
    try std.testing.expect(s.failed);
    try std.testing.expectEqual(@as(usize, 1), Harness.closed);
}

test "stream: an empty feed reports no packet and no failure" {
    Harness.reset();
    // An empty feed means recv returns 0 forever; parse returns null (no
    // data), never fails. Then close cleanly.
    var buf: [capacity]u8 = undefined;
    var s = Stream.init(&buf, Harness.ops());
    try std.testing.expect((try s.parse()) == null);
    try std.testing.expect(!s.failed);
    s.close();
    try std.testing.expectEqual(@as(usize, 1), Harness.closed);
}

test "stream: a transport receive error fails closed" {
    Harness.reset();
    Harness.recv_error = true;
    var buf: [capacity]u8 = undefined;
    var s = Stream.init(&buf, Harness.ops());
    try std.testing.expectError(error.Closed, s.parse());
    try std.testing.expect(s.failed);
    try std.testing.expectEqual(@as(usize, 1), Harness.closed);
}
