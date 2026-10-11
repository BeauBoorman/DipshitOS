//! Decoupled TCP protocol unit test suite (M41 TS5, #956).
//!
//! Extracted from kernel/src/tcp.zig.

const std = @import("std");
const syscall = @import("syscall");
const tcp = syscall.tcp;
const arp = tcp.arp;

// Symbols from tcp
const protocol_tcp = tcp.protocol_tcp;
const eth_hdr_len = tcp.eth_hdr_len;
const ipv4_hdr_len = tcp.ipv4_hdr_len;
const tcp_hdr_len = tcp.tcp_hdr_len;
const default_src_port = tcp.default_src_port;
const payload_max = tcp.payload_max;
const segment_max = tcp.segment_max;
const frame_max = tcp.frame_max;
const frame_min = tcp.frame_min;
const window = tcp.window;
const connect_timeout = tcp.connect_timeout;
const rto_ticks = tcp.rto_ticks;
const retx_max = tcp.retx_max;

const flag_fin = tcp.flag_fin;
const flag_syn = tcp.flag_syn;
const flag_rst = tcp.flag_rst;
const flag_ack = tcp.flag_ack;

const State = tcp.State;
const Event = tcp.Event;
const RtoEvent = tcp.RtoEvent;

const checksum_tcp = tcp.checksum_tcp;
const build_segment = tcp.build_segment;
const build_frame = tcp.build_frame;
const handle_rx = tcp.handle_rx;
const reset = tcp.reset;
const start = tcp.start;
const advance_snd = tcp.advance_snd;
const build_fin_msg = tcp.build_fin_msg;
const build_data_msg = tcp.build_data_msg;
const take_rx = tcp.take_rx;
const ready_mask = tcp.ready_mask;
const record_pending = tcp.record_pending;
const poll_rto = tcp.poll_rto;
const listen = tcp.listen;
const release_conn = tcp.release_conn;
const abort_timeout = tcp.abort_timeout;
const elapsed = tcp.elapsed;
const connect_timed_out = tcp.connect_timed_out;
const sum_words = tcp.sum_words;
const fold = tcp.fold;

// ---------------------------------------------------------------------------
// Host tests — pure logic, byte-exact against the fixtures
// ---------------------------------------------------------------------------

const test_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 }; // the host-set guest MAC
const host_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 }; // the host-side MAC
const ip_guest = [4]u8{ 10, 0, 0, 1 };
const ip_host = [4]u8{ 10, 0, 0, 2 };

test "tcp: counter deadline keeps legacy 30 seconds and bounds explicit milliseconds" {
    for ([_]u32{ 0, 1, 5, 5000, 5001, std.math.maxInt(u32) }) |ms| {
        const freq: u64 = 24_000_000;
        const d = tcp.ConnectDeadline.init(123, freq, ms).?;
        const duration = @as(u64, if (ms == 0) 30_000 else ms) * (freq / 1000);
        try std.testing.expectEqual(duration, d.duration);
        try std.testing.expect(!d.expired(123 + duration - 1));
        try std.testing.expect(d.expired(123 + duration));
        try std.testing.expect(d.expired(123 + duration + 1));
    }
}

test "tcp: counter deadline rounds up, survives counter wrap, refuses bad clocks" {
    const d = tcp.ConnectDeadline.init(std.math.maxInt(u64) - 2, 1001, 5).?;
    try std.testing.expectEqual(@as(u64, 6), d.duration);
    try std.testing.expect(!d.expired(2));
    try std.testing.expect(d.expired(3));
    try std.testing.expect(tcp.ConnectDeadline.init(0, 0, 5000) == null);
    try std.testing.expect(tcp.ConnectDeadline.init(0, std.math.maxInt(u64), std.math.maxInt(u32)) == null);
    const wide = tcp.ConnectDeadline.init(0, std.math.maxInt(u64), 1).?;
    try std.testing.expectEqual(@as(u64, 18_446_744_073_709_552), wide.duration);
}

test "tcp: outbound expiry clears singleton state without erasing counters" {
    reset();
    defer reset();
    tcp.now_ticks = 91;
    start(ip_host, 8081, 1234, host_mac);
    tcp.owner_pid = 7;
    advance_snd(1);
    record_pending();
    tcp.syn_sent = 1;
    tcp.retransmitted = 1;
    tcp.rx_pending = true;
    tcp.rx_len = 3;
    tcp.ack_pending = true;
    tcp.rst_pending = true;
    abort_timeout();
    try std.testing.expectEqual(State.idle, tcp.state);
    try std.testing.expect(tcp.owner_pid == null);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, tcp.peer_ip);
    try std.testing.expectEqual(@as(u16, 0), tcp.peer_port);
    try std.testing.expectEqual(@as(usize, 0), tcp.msg_len);
    try std.testing.expectEqual(@as(usize, 0), tcp.rx_len);
    try std.testing.expectEqual(@as(usize, 0), tcp.retx_len);
    try std.testing.expectEqual(@as(u32, 0), tcp.snd_una);
    try std.testing.expectEqual(@as(u64, 0), tcp.syn_ticks);
    try std.testing.expect(!tcp.tx_pending and !tcp.rx_pending and !tcp.ack_pending and !tcp.rst_pending);
    try std.testing.expectEqual(@as(u64, 1), tcp.timed_out);
    try std.testing.expectEqual(@as(u64, 1), tcp.syn_sent);
    try std.testing.expectEqual(@as(u64, 1), tcp.retransmitted);
    try std.testing.expectEqual(@as(u64, 0), ready_mask());
    start(ip_host, 8080, 5678, host_mac);
    try std.testing.expectEqual(State.syn_sent, tcp.state);
    try std.testing.expectEqual(@as(u32, 5678), tcp.isn);
}

const net = syscall.virtio_net;
fn connect_read8(_: u32) u8 {
    return 0;
}
fn connect_read16(_: u32) u16 {
    return 0;
}
fn connect_read32(_: u32) u32 {
    return 0;
}
fn connect_write8(_: u32, _: u8) void {}
fn connect_write16(_: u32, _: u16) void {}
fn connect_write32(_: u32, _: u32) void {}
var connect_saw_net_lock: bool = false;
fn connect_notify(_: u16) void {
    connect_saw_net_lock = syscall.svclock.net.held();
    net.net_dev.tx_used.idx = net.net_dev.tx_avail.idx;
}
fn connect_phys(va: usize) u64 {
    return va;
}
fn connect_cache(_: usize, _: usize) void {}
fn connect_writer(_: []const u8) void {}

test "syscall: slot 30 packed timeout validation and failure release the network lock" {
    syscall.userspace.init();
    syscall.init(connect_writer);
    var frame = std.mem.zeroes(syscall.exceptions.VectorFrame);
    const saved_ops = net.net_ops;
    net.net_ops = .{
        .dev_read32 = connect_read32,
        .cfg_read8 = connect_read8,
        .cfg_read16 = connect_read16,
        .cfg_read32 = connect_read32,
        .cfg_write8 = connect_write8,
        .cfg_write16 = connect_write16,
        .cfg_write32 = connect_write32,
        .notify = connect_notify,
        .to_phys = connect_phys,
        .clean = connect_cache,
        .invalidate = connect_cache,
    };
    net.net_ready = true;
    arp.own_ip = ip_guest;
    arp.upsert(ip_host, host_mac);
    reset();
    defer {
        net.net_ops = saved_ops;
        net.net_ready = false;
        arp.own_ip = .{ 0, 0, 0, 0 };
        reset();
    }
    for ([_]u64{ 0, 0x10000, @as(u64, 1) << 48 | 8081, @as(u64, 1) << 63 | 8081 }) |word| {
        try std.testing.expectEqual(syscall.error_result(.einval), syscall.dispatch(30, .{ 0x0a000002, word, 0, 0, 0, 0 }, &frame));
        try std.testing.expectEqual(@as(u64, 0), tcp.syn_sent);
    }
    try std.testing.expectEqual(syscall.error_result(.einval), syscall.dispatch(30, .{ 0, @as(u64, 5000) << 16 | 8081, 0, 0, 0, 0 }, &frame));
    // Host transport only acknowledges TX completion, never supplies SYN-ACK.
    // Deadline arithmetic is tested above; the host iteration guard tests
    // this handler's error/cleanup/lock return path, not elapsed wall time.
    connect_saw_net_lock = false;
    try std.testing.expectEqual(syscall.error_result(.etimedout), syscall.dispatch(30, .{ 0x0a000002, @as(u64, 5000) << 16 | 8081, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(connect_saw_net_lock);
    try std.testing.expectEqual(State.idle, tcp.state);
    try std.testing.expectEqual(@as(u64, 1), tcp.timed_out);
    try std.testing.expect(tcp.owner_pid == null and !tcp.tx_pending);
    try std.testing.expect(!syscall.svclock.net.held());
    try std.testing.expect(syscall.svclock.net.try_acquire());
    syscall.svclock.net.release();
    try std.testing.expectEqual(@as(u64, 0), syscall.dispatch(33, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(syscall.error_result(.einval), syscall.dispatch(30, .{ 0x0a000002, 8081, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 2), tcp.timed_out);
    try std.testing.expectEqual(@as(u64, 0), syscall.dispatch(30, .{ 0, 8080, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(State.listen, tcp.state);
}

/// Craft a full TCP frame the way the host responder does (the guest's
/// `build_frame` with a pre-built segment — the fixture shape).
fn craft_frame(own: [4]u8, own_m: [6]u8, peer: [4]u8, peer_m: [6]u8, src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, payload: []const u8) [frame_max]u8 {
    var frame: [frame_max]u8 = undefined;
    var seg: [segment_max]u8 = undefined;
    const seg_len = build_segment(&seg, own, peer, src_port, dst_port, seq, ack, flags, payload);
    const flen = build_frame(&frame, &own_m, own, peer_m, peer, seg[0..seg_len]);
    std.debug.assert(flen <= frame_max);
    return frame;
}

test "tcp: build_segment is byte-exact — the SYN fixture (54-byte frame, 20-byte header)" {
    var seg: [segment_max]u8 = undefined;
    const n = build_segment(&seg, ip_guest, ip_host, default_src_port, 9999, 0x12345678, 0, flag_syn, &.{});
    try std.testing.expectEqual(@as(usize, 20), n);
    try std.testing.expectEqual(@as(u16, 8000), (@as(u16, seg[0]) << 8) | seg[1]);
    try std.testing.expectEqual(@as(u16, 9999), (@as(u16, seg[2]) << 8) | seg[3]);
    // seq = the ISN, big-endian (bytes 4..8).
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78 }, seg[4..8]);
    // ack = 0 (no ACK in the SYN).
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, seg[8..12]);
    try std.testing.expectEqual(@as(u8, 0x50), seg[12]); // data offset 5 (no options)
    try std.testing.expectEqual(@as(u8, flag_syn), seg[13]); // flags SYN
    try std.testing.expectEqual(@as(u8, 0x10), seg[14]); // window 4096 high
    try std.testing.expectEqual(@as(u8, 0x00), seg[15]);
    // Urgent pointer (18..20) = 0.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, seg[18..20]);
    // The checksum field is NOT zero (computed always — RFC 1071).
    try std.testing.expect(seg[16] != 0 or seg[17] != 0);
    // The checksum verifies (folds to 0x0000) and binds the pseudo-header
    // (a different dst IP yields a different checksum — the sum is
    // commutative in src/dst, so the swap is NOT the binding test).
    try std.testing.expectEqual(@as(u16, 0x0000), checksum_tcp(ip_guest, ip_host, seg[0..n]));
    try std.testing.expect(checksum_tcp(ip_guest, .{ 10, 0, 0, 99 }, seg[0..n]) != 0x0000);
}

test "tcp: build_frame is byte-exact — the full 54-byte SYN frame" {
    var seg: [segment_max]u8 = undefined;
    const seg_len = build_segment(&seg, ip_guest, ip_host, default_src_port, 9999, 0x12345678, 0, flag_syn, &.{});
    var frame: [frame_max]u8 = undefined;
    const n = build_frame(&frame, &test_mac, ip_guest, host_mac, ip_host, seg[0..seg_len]);
    try std.testing.expectEqual(@as(usize, 54), n);
    try std.testing.expectEqualSlices(u8, &host_mac, frame[0..6]); // dst
    try std.testing.expectEqualSlices(u8, &test_mac, frame[6..12]); // src
    try std.testing.expectEqualSlices(u8, &.{ 0x08, 0x00 }, frame[12..14]); // ethertype IPv4
    try std.testing.expectEqual(@as(u8, 0x45), frame[14]); // version 4, IHL 5
    try std.testing.expectEqual(@as(u8, 40), frame[17]); // total length 20 + 20
    try std.testing.expectEqual(@as(u8, 64), frame[22]); // TTL
    try std.testing.expectEqual(@as(u8, 6), frame[23]); // protocol TCP
    try std.testing.expectEqualSlices(u8, &ip_guest, frame[26..30]);
    try std.testing.expectEqualSlices(u8, &ip_host, frame[30..34]);
    // The IPv4 header checksum verifies (folds to 0x0000).
    try std.testing.expectEqual(@as(u16, 0x0000), fold(sum_words(frame[14..34])));
    // The segment rides at 34..54.
    try std.testing.expectEqualSlices(u8, seg[0..seg_len], frame[34 .. 34 + seg_len]);
}

test "tcp: largest segment fits the Ethernet MTU and truncates longer writes" {
    try std.testing.expectEqual(@as(usize, 1460), payload_max);
    var body: [payload_max + 1]u8 = undefined;
    for (&body, 0..) |*b, i| b.* = @truncate(i);
    var seg: [segment_max]u8 = undefined;
    const n = build_segment(&seg, ip_guest, ip_host, default_src_port, 5900, 42, 0, flag_ack, &body);
    try std.testing.expectEqual(segment_max, n);
    try std.testing.expectEqualSlices(u8, body[0..payload_max], seg[tcp_hdr_len..n]);
    try std.testing.expectEqual(@as(u16, 0), checksum_tcp(ip_guest, ip_host, seg[0..n]));
    var frame: [frame_max]u8 = undefined;
    const len = build_frame(&frame, &test_mac, ip_guest, host_mac, ip_host, seg[0..n]);
    try std.testing.expectEqual(@as(usize, 1514), len);
    try std.testing.expectEqualSlices(u8, seg[0..n], frame[eth_hdr_len + ipv4_hdr_len .. len]);
}

test "tcp: the four-segment lifecycle — SYN -> SYN-ACK -> ACK -> data -> FIN -> FIN-ACK" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();

    // IDLE -> SYN_SENT: the SYN is built into tcp.msg (seq = the ISN).
    start(ip_host, 9999, 0x12345678, host_mac);
    try std.testing.expectEqual(State.syn_sent, tcp.state);
    try std.testing.expectEqual(@as(usize, 20), tcp.msg_len);
    try std.testing.expectEqual(@as(u8, flag_syn), tcp.msg[13]);
    // The caller transmits + advances tcp.snd_una by 1 (the SYN consumes one).
    advance_snd(1);
    try std.testing.expectEqual(@as(u32, 0x12345679), tcp.snd_una);

    // The server's SYN-ACK: seq = its ISN, ack = our ISN+1.
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xabcdef01, 0x12345679, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));
    try std.testing.expectEqual(State.established, tcp.state);
    try std.testing.expectEqual(@as(u32, 0xabcdef01), tcp.srv_isn);
    try std.testing.expectEqual(@as(u32, 0xabcdef02), tcp.rcv_nxt);
    try std.testing.expectEqual(@as(u64, 1), tcp.synack_recv);
    // The handshake ACK is built: seq = our ISN+1, ack = tcp.rcv_nxt, flags ACK.
    try std.testing.expect(tcp.ack_pending);
    try std.testing.expectEqual(@as(u8, flag_ack), tcp.msg[13]);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x79 }, tcp.msg[4..8]); // seq
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd, 0xef, 0x02 }, tcp.msg[8..12]); // ack

    // The server's data echo: seq = its ISN+1, ack = our ISN+2 (it acked
    // our handshake ACK), payload "hi".
    const echo = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xabcdef02, 0x1234567a, flag_ack, "hi");
    try std.testing.expectEqual(Event.data_recv, handle_rx(&echo));
    try std.testing.expectEqual(@as(u64, 1), tcp.data_recv);
    try std.testing.expect(tcp.rx_pending);
    try std.testing.expectEqualSlices(u8, "hi", tcp.rx_payload[0..tcp.rx_len]);
    try std.testing.expectEqual(@as(u32, 0xabcdef04), tcp.rcv_nxt); // +2 for the payload
    // The ACK for the echo is built (ack = tcp.rcv_nxt).
    try std.testing.expect(tcp.ack_pending);
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd, 0xef, 0x04 }, tcp.msg[8..12]);
    // The caller reads it.
    try std.testing.expectEqualSlices(u8, "hi", take_rx());
    try std.testing.expect(!tcp.rx_pending);

    // The client's close: FIN (seq = tcp.snd_una, ack = tcp.rcv_nxt). The
    // monitor transmits it and moves to FIN_SENT (the tcp.state machine
    // only builds).
    build_fin_msg();
    try std.testing.expectEqual(@as(u8, flag_ack | flag_fin), tcp.msg[13]);
    advance_snd(1); // the FIN consumes one sequence number
    tcp.state = .fin_sent;

    // The server's FIN-ACK: seq = tcp.rcv_nxt (its next), ack = our FIN seq+1.
    const fa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xabcdef04, 0x1234567b, flag_ack | flag_fin, &.{});
    try std.testing.expectEqual(Event.finack_recv, handle_rx(&fa));
    try std.testing.expectEqual(State.closed, tcp.state);
    try std.testing.expectEqual(@as(u64, 1), tcp.finack_recv);
    try std.testing.expectEqual(@as(u32, 0xabcdef05), tcp.rcv_nxt); // the FIN consumes one
    // The final ACK is built (ack = tcp.rcv_nxt after the server's FIN).
    try std.testing.expect(tcp.ack_pending);
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd, 0xef, 0x05 }, tcp.msg[8..12]);
}

test "tcp: malformed + unexpected segments are counted, never assumed away" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    start(ip_host, 9999, 0x11111111, host_mac);

    // A bad checksum -> tcp.dropped_badsum.
    var bad = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0x22222222, 0x11111112, flag_syn | flag_ack, &.{});
    bad[40] ^= 0xff; // corrupt the segment (the ack field)
    try std.testing.expectEqual(Event.none, handle_rx(&bad));
    try std.testing.expectEqual(@as(u64, 1), tcp.dropped_badsum);

    // A SYN-ACK that does NOT acknowledge our SYN -> tcp.dropped_malformed.
    const wrong_ack = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0x22222222, 0x99999999, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.none, handle_rx(&wrong_ack));
    try std.testing.expectEqual(@as(u64, 1), tcp.dropped_malformed);

    // A segment from the WRONG src port -> tcp.dropped_malformed.
    const wrong_port = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9998, default_src_port, 0x22222222, 0x11111112, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.none, handle_rx(&wrong_port));
    try std.testing.expectEqual(@as(u64, 2), tcp.dropped_malformed);

    // A segment with options (data offset 6) -> tcp.dropped_malformed.
    var opts = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0x22222222, 0x11111112, flag_syn | flag_ack, &.{});
    opts[46] = 0x60; // data offset 6 — must also fix the checksum to land in malformed
    opts[50] = 0;
    opts[51] = 0; // zero the checksum field during the recompute (RFC 1071)
    {
        const seg = opts[34..54];
        const c = checksum_tcp(ip_host, ip_guest, seg);
        opts[50] = @truncate(c >> 8);
        opts[51] = @truncate(c);
    }
    try std.testing.expectEqual(Event.none, handle_rx(&opts));
    try std.testing.expectEqual(@as(u64, 3), tcp.dropped_malformed);

    // A SYN-ACK carrying payload (not permitted), even at the segment
    // bound, is malformed.
    const big: [payload_max]u8 = @splat(0x41);
    const over = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0x22222222, 0x11111112, flag_syn | flag_ack, &big);
    try std.testing.expectEqual(Event.none, handle_rx(&over));
    try std.testing.expectEqual(@as(u64, 4), tcp.dropped_malformed);
    try std.testing.expectEqual(State.syn_sent, tcp.state); // unchanged

    // A RST kills the connection.
    const rst = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0x22222222, 0x11111112, flag_ack | flag_rst, &.{});
    try std.testing.expectEqual(Event.rst_recv, handle_rx(&rst));
    try std.testing.expectEqual(@as(u64, 1), tcp.rst_recv);
    try std.testing.expectEqual(State.closed, tcp.state);
}

test "tcp: the RX buffer holds ONE segment — a second unread segment is dropped" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    start(ip_host, 9999, 1, host_mac);
    // Fast-forward to ESTABLISHED.
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0000, 2, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));

    const d1 = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0001, 3, flag_ack, "one");
    try std.testing.expectEqual(Event.data_recv, handle_rx(&d1));
    try std.testing.expectEqual(@as(u64, 1), tcp.data_recv);
    // The second segment arrives BEFORE `net tcp recv` — dropped (counted).
    const d2 = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0005, 3, flag_ack, "two");
    try std.testing.expectEqual(Event.none, handle_rx(&d2));
    try std.testing.expectEqual(@as(u64, 1), tcp.dropped_malformed);
    try std.testing.expectEqualSlices(u8, "one", tcp.rx_payload[0..tcp.rx_len]); // unchanged
}

test "tcp: ready_mask reports a peer FIN in ESTABLISHED as readable" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    start(ip_host, 9999, 1, host_mac);
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0000, 2, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));
    try std.testing.expectEqual(@as(u64, 2), ready_mask() & 3); // writable, not readable
    // The server closes first: FIN+ACK — no queued payload, but the
    // connection is terminal, so bit 0 (readable) must be set for a
    // poller to stop waiting (recv drains 0 and the caller fails closed).
    const fin = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0001, 3, flag_ack | flag_fin, &.{});
    try std.testing.expectEqual(Event.finack_recv, handle_rx(&fin));
    try std.testing.expect(!tcp.rx_pending);
    try std.testing.expectEqual(@as(u64, 1), ready_mask() & 1);
}

test "tcp: the bounded connect timeout — 30 s then an honest refuse" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    start(ip_host, 9999, 0x01020304, host_mac);
    try std.testing.expectEqual(State.syn_sent, tcp.state);
    // The clock: tcp.syn_ticks stamped at start; elapsed is wall-clock seconds.
    tcp.syn_ticks = 100;
    tcp.now_ticks = 105;
    try std.testing.expectEqual(@as(u64, 5), elapsed());
    try std.testing.expect(!connect_timed_out());
    tcp.now_ticks = 130;
    try std.testing.expectEqual(@as(u64, 30), elapsed());
    try std.testing.expect(connect_timed_out());
    // The honest refuse: back to IDLE, connection tcp.state released, counted.
    abort_timeout();
    try std.testing.expectEqual(State.idle, tcp.state);
    try std.testing.expectEqual(@as(u64, 1), tcp.timed_out);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &tcp.peer_ip);
    try std.testing.expect(!tcp.ack_pending);
    // The next connect is a fresh attempt.
    start(ip_host, 9999, 0x0a0b0c0d, host_mac);
    try std.testing.expectEqual(State.syn_sent, tcp.state);
}

test "tcp: a server FIN+ACK in ESTABLISHED is ACKed; the caller closes" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    start(ip_host, 9999, 1, host_mac);
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xbbbb0000, 2, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));

    // The server closes first: FIN+ACK, no payload.
    const fin = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xbbbb0001, 3, flag_ack | flag_fin, &.{});
    try std.testing.expectEqual(Event.finack_recv, handle_rx(&fin));
    try std.testing.expectEqual(@as(u64, 1), tcp.finack_recv);
    try std.testing.expectEqual(@as(u32, 0xbbbb0002), tcp.rcv_nxt);
    try std.testing.expectEqual(State.established, tcp.state); // the client still closes
    try std.testing.expect(tcp.ack_pending); // the ACK for the FIN is built
    // The caller's `net tcp close` completes the close.
    build_fin_msg();
    try std.testing.expectEqual(@as(u8, flag_ack | flag_fin), tcp.msg[13]);
}

test "tcp: a bare SYN (no ACK) in SYN_SENT is malformed" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    start(ip_host, 9999, 7, host_mac);
    const syn = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xcccc0000, 0, flag_syn, &.{});
    try std.testing.expectEqual(Event.none, handle_rx(&syn));
    try std.testing.expectEqual(@as(u64, 1), tcp.dropped_malformed);
    try std.testing.expectEqual(State.syn_sent, tcp.state);
}

test "tcp: card N11 — the RTO retransmits the pending SYN byte-exact; the SYN-ACK stops the timer" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    tcp.now_ticks = 100;
    start(ip_host, 9999, 0x12345678, host_mac);
    // The caller transmits the SYN and records it pending.
    record_pending();
    try std.testing.expect(tcp.tx_pending);
    try std.testing.expectEqual(@as(u64, 0), tcp.retx_count);
    const syn0 = tcp.msg[0..tcp.msg_len];
    // The RTO (3 s) has NOT expired.
    tcp.now_ticks = 102;
    try std.testing.expectEqual(RtoEvent.none, poll_rto());
    // At 3 s the RTO fires: the SAME bytes (seq, flags, checksum) rebuild.
    tcp.now_ticks = 103;
    try std.testing.expectEqual(RtoEvent.retransmit, poll_rto());
    try std.testing.expectEqual(@as(u64, 1), tcp.retransmitted);
    try std.testing.expectEqual(@as(u64, 1), tcp.retx_count);
    try std.testing.expectEqualSlices(u8, syn0, tcp.msg[0..tcp.msg_len]);
    // A second retransmission, byte-identical again.
    tcp.now_ticks = 106;
    try std.testing.expectEqual(RtoEvent.retransmit, poll_rto());
    try std.testing.expectEqual(@as(u64, 2), tcp.retransmitted);
    try std.testing.expectEqualSlices(u8, syn0, tcp.msg[0..tcp.msg_len]);
    // The SYN-ACK then lands — it acknowledges our SYN, the timer stops.
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xabcdef01, 0x12345679, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));
    try std.testing.expect(!tcp.tx_pending);
    tcp.now_ticks = 200; // long past the RTO — nothing fires
    try std.testing.expectEqual(RtoEvent.none, poll_rto());
    try std.testing.expectEqual(@as(u64, 2), tcp.retransmitted); // unchanged
}

test "tcp: card N11 — a peer ACK covering snd_una clears the pending data; no retransmission" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    tcp.now_ticks = 100;
    start(ip_host, 9999, 0x11111111, host_mac);
    advance_snd(1); // the SYN was transmitted
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0000, 0x11111112, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));
    // The caller sends 2 data bytes: build + transmit + advance + record.
    build_data_msg("hi");
    advance_snd(2);
    record_pending();
    try std.testing.expect(tcp.tx_pending);
    // The peer's ACK covers tcp.snd_una (0x11111114) — the pending clears.
    const ack = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0001, 0x11111114, flag_ack, &.{});
    try std.testing.expectEqual(Event.none, handle_rx(&ack));
    try std.testing.expect(!tcp.tx_pending);
    tcp.now_ticks = 500; // long past the RTO — no retransmission
    try std.testing.expectEqual(RtoEvent.none, poll_rto());
    try std.testing.expectEqual(@as(u64, 0), tcp.retransmitted);
}

test "tcp: card N11 — an ACK that does NOT cover snd_una leaves the pending data armed" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    tcp.now_ticks = 100;
    start(ip_host, 9999, 0x22222222, host_mac);
    advance_snd(1);
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xbbbb0000, 0x22222223, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));
    build_data_msg("hello");
    advance_snd(5);
    record_pending();
    // The peer ACKs only up to our ISN+1 (it has NOT seen the data).
    const ack = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xbbbb0001, 0x22222223, flag_ack, &.{});
    try std.testing.expectEqual(Event.none, handle_rx(&ack));
    try std.testing.expect(tcp.tx_pending); // still armed
    // The RTO fires — the pending data is tcp.retransmitted byte-exact.
    const data0 = tcp.msg[0..tcp.msg_len];
    tcp.now_ticks = 103;
    try std.testing.expectEqual(RtoEvent.retransmit, poll_rto());
    try std.testing.expectEqualSlices(u8, data0, tcp.msg[0..tcp.msg_len]);
    try std.testing.expectEqual(@as(u64, 1), tcp.retransmitted);
}

test "tcp: card N11 — the retransmission bound aborts the connection honestly" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    tcp.now_ticks = 100;
    start(ip_host, 9999, 0x33333333, host_mac);
    advance_snd(1);
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xcccc0000, 0x33333334, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));
    build_data_msg("x");
    advance_snd(1);
    record_pending();
    // retx_max retransmissions, one per RTO period.
    var i: u64 = 0;
    while (i < retx_max) : (i += 1) {
        tcp.now_ticks += rto_ticks;
        try std.testing.expectEqual(RtoEvent.retransmit, poll_rto());
    }
    try std.testing.expectEqual(@as(u64, retx_max), tcp.retransmitted);
    try std.testing.expectEqual(@as(u64, 0), tcp.retx_aborted);
    try std.testing.expectEqual(State.established, tcp.state); // still alive
    // The NEXT RTO period sees the bound exhausted — the honest abort:
    // the connection is released (no RST, no TX), counted, the peer gone.
    tcp.now_ticks += rto_ticks;
    try std.testing.expectEqual(RtoEvent.abort, poll_rto());
    try std.testing.expectEqual(@as(u64, 1), tcp.retx_aborted);
    try std.testing.expectEqual(State.idle, tcp.state);
    try std.testing.expect(!tcp.tx_pending);
    try std.testing.expect(!tcp.ack_pending);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &tcp.peer_ip);
    try std.testing.expectEqual(@as(u16, 0), tcp.peer_port);
    // The timer stays off.
    tcp.now_ticks += rto_ticks;
    try std.testing.expectEqual(RtoEvent.none, poll_rto());
}

test "tcp: card N11 — the pending FIN is retransmitted in FIN_SENT" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    tcp.now_ticks = 100;
    start(ip_host, 9999, 0x44444444, host_mac);
    advance_snd(1);
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xdddd0000, 0x44444445, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));
    // The caller closes: build the FIN, transmit, advance, record.
    build_fin_msg();
    advance_snd(1);
    tcp.state = .fin_sent;
    record_pending();
    const fin0 = tcp.msg[0..tcp.msg_len];
    try std.testing.expectEqual(@as(u8, flag_ack | flag_fin), tcp.msg[13]);
    // The RTO fires — the FIN is tcp.retransmitted byte-exact.
    tcp.now_ticks = 103;
    try std.testing.expectEqual(RtoEvent.retransmit, poll_rto());
    try std.testing.expectEqual(@as(u64, 1), tcp.retransmitted);
    try std.testing.expectEqualSlices(u8, fin0, tcp.msg[0..tcp.msg_len]);
    // The FIN-ACK then lands — it acknowledges our FIN, the timer stops.
    const fa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xdddd0001, 0x44444446, flag_ack | flag_fin, &.{});
    try std.testing.expectEqual(Event.finack_recv, handle_rx(&fa));
    try std.testing.expect(!tcp.tx_pending);
    tcp.now_ticks = 200;
    try std.testing.expectEqual(RtoEvent.none, poll_rto());
}

test "tcp: passive open and server handshake (listen -> syn_received -> established -> data -> close)" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();

    // 1. Enter LISTEN on port 8080
    listen(8080);
    try std.testing.expectEqual(State.listen, tcp.state);
    try std.testing.expect(tcp.is_server);
    try std.testing.expectEqual(@as(u16, 8080), tcp.listen_port);

    // 2. Incoming client SYN from host 10.0.0.2:54321
    const syn_frame = craft_frame(ip_host, host_mac, ip_guest, test_mac, 54321, 8080, 0x10000000, 0, flag_syn, &.{});
    const ev1 = handle_rx(&syn_frame);
    try std.testing.expectEqual(Event.synack_recv, ev1);
    try std.testing.expectEqual(State.syn_received, tcp.state);
    try std.testing.expect(tcp.ack_pending);
    try std.testing.expectEqualSlices(u8, &ip_host, &tcp.peer_ip);
    try std.testing.expectEqual(@as(u16, 54321), tcp.peer_port);
    try std.testing.expectEqualSlices(u8, &host_mac, &tcp.peer_mac);
    try std.testing.expectEqual(@as(u32, 0x10000001), tcp.rcv_nxt);

    // Verify SYN-ACK outbound segment built
    try std.testing.expectEqual(@as(u8, flag_syn | flag_ack), tcp.msg[13]);
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x00, 0x00, 0x01 }, tcp.msg[8..12]); // ack = client ISN+1

    // 3. Client sends ACK for our SYN-ACK
    const ack_frame = craft_frame(ip_host, host_mac, ip_guest, test_mac, 54321, 8080, 0x10000001, tcp.snd_una, flag_ack, &.{});
    const ev2 = handle_rx(&ack_frame);
    try std.testing.expectEqual(Event.none, ev2);
    try std.testing.expectEqual(State.established, tcp.state);

    // 4. Client sends HTTP GET request payload
    const get_payload = "GET / HTTP/1.1\r\n\r\n";
    const data_frame = craft_frame(ip_host, host_mac, ip_guest, test_mac, 54321, 8080, 0x10000001, tcp.snd_una, flag_ack, get_payload);
    const ev3 = handle_rx(&data_frame);
    try std.testing.expectEqual(Event.data_recv, ev3);
    try std.testing.expect(tcp.rx_pending);
    try std.testing.expectEqualStrings(get_payload, take_rx());

    // 5. Server sends response and releases connection back to LISTEN
    release_conn();
    try std.testing.expectEqual(State.listen, tcp.state);
    try std.testing.expectEqual(@as(u16, 0), tcp.peer_port);
}

test "tcp: M46 RC3 — the allowlist refuses a non-listed SYN with RST and still accepts the listed host" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    listen(8080);
    tcp.allow_ip = .{ 10, 0, 0, 3 };
    tcp.allow_ip_set = true;

    // A SYN from 10.0.0.2 (not allowlisted): RST+ACK, counted, stay LISTEN.
    const bad = craft_frame(ip_host, host_mac, ip_guest, test_mac, 54321, 8080, 0x10000000, 0, flag_syn, &.{});
    try std.testing.expectEqual(Event.none, handle_rx(&bad));
    try std.testing.expectEqual(State.listen, tcp.state);
    try std.testing.expectEqual(@as(u64, 1), tcp.auth_rejected);
    try std.testing.expectEqual(@as(u64, 1), tcp.rst_sent);
    try std.testing.expect(tcp.ack_pending);
    try std.testing.expectEqual(@as(u8, flag_rst | flag_ack), tcp.msg[13]);
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x00, 0x00, 0x01 }, tcp.msg[8..12]); // ack = client ISN+1

    // A SYN from the allowlisted 10.0.0.3 completes the handshake as usual.
    const good = craft_frame([4]u8{ 10, 0, 0, 3 }, host_mac, ip_guest, test_mac, 55555, 8080, 0x20000000, 0, flag_syn, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&good));
    try std.testing.expectEqual(State.syn_received, tcp.state);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 3 }, &tcp.peer_ip);
}

test "tcp: M46 #1105 — a half-open server accept aborts on the SYN-ACK retransmission bound" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    tcp.now_ticks = 0;
    listen(8080);
    const syn = craft_frame(ip_host, host_mac, ip_guest, test_mac, 54321, 8080, 0x10000000, 0, flag_syn, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&syn));
    try std.testing.expectEqual(State.syn_received, tcp.state);
    try std.testing.expect(tcp.tx_pending);
    var i: u64 = 0;
    while (i < retx_max) : (i += 1) {
        tcp.now_ticks += rto_ticks;
        try std.testing.expectEqual(RtoEvent.retransmit, poll_rto());
    }
    try std.testing.expect(!tcp.accept_aborted);
    tcp.now_ticks += rto_ticks;
    try std.testing.expectEqual(RtoEvent.abort, poll_rto());
    try std.testing.expect(tcp.accept_aborted);
    try std.testing.expectEqual(State.listen, tcp.state); // the listener survives
    try std.testing.expectEqual(@as(u64, 1), tcp.retx_aborted);
}

test "tcp: M84f — an over-cap SYN is refused RST+ACK; the established connection is undisturbed" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    tcp.now_ticks = 100;
    start(ip_host, 9999, 0x55555555, host_mac);
    advance_snd(1); // the SYN was transmitted
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0000, 0x55555556, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));
    try std.testing.expectEqual(State.established, tcp.state);
    tcp.ack_pending = false; // the TX side transmitted the handshake ACK

    // ONE unACKed data segment pending (the framebuffer-update shape).
    build_data_msg("frame");
    advance_snd(5);
    record_pending();
    var data0: [segment_max]u8 = undefined;
    @memcpy(data0[0..tcp.retx_len], tcp.retx_msg[0..tcp.retx_len]);
    const data_len = tcp.retx_len;
    const before = ready_mask();

    // The over-cap second viewer: a SYN from a foreign port (9998), no ACK.
    const syn = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9998, default_src_port, 0x77777777, 0, flag_syn, &.{});
    try std.testing.expectEqual(Event.none, handle_rx(&syn));

    // The honest refusal — RST+ACK in the RFC 793 §3.4 closed-port form
    // (the listen allowlist's form): seq 0, ack = the SYN's next sequence
    // number, addressed to the intruder's port. It stages in its OWN slot
    // (`rst_msg`) — never the shared `msg`/pending slot. Counted, never
    // dropped.
    try std.testing.expect(tcp.rst_pending);
    try std.testing.expectEqual(@as(usize, 20), tcp.rst_len);
    try std.testing.expectEqual(@as(u8, flag_rst | flag_ack), tcp.rst_msg[13]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, tcp.rst_msg[4..8]); // seq 0
    try std.testing.expectEqualSlices(u8, &.{ 0x77, 0x77, 0x77, 0x78 }, tcp.rst_msg[8..12]); // ack = seq+1
    try std.testing.expectEqual(@as(u16, default_src_port), (@as(u16, tcp.rst_msg[0]) << 8) | tcp.rst_msg[1]);
    try std.testing.expectEqual(@as(u16, 9998), (@as(u16, tcp.rst_msg[2]) << 8) | tcp.rst_msg[3]); // to the intruder
    try std.testing.expectEqual(@as(u64, 1), tcp.rst_sent);
    try std.testing.expectEqual(@as(u64, 0), tcp.dropped_malformed); // answered — not dropped

    // The established connection is UNDISTURBED: state, peer record, the
    // ONE pending segment byte-exact, and its retransmit state.
    try std.testing.expectEqual(State.established, tcp.state);
    try std.testing.expectEqualSlices(u8, &ip_host, &tcp.peer_ip);
    try std.testing.expectEqual(@as(u16, 9999), tcp.peer_port);
    try std.testing.expectEqualSlices(u8, &host_mac, &tcp.peer_mac);
    try std.testing.expectEqual(@as(u32, 0x5555555b), tcp.snd_una);
    try std.testing.expectEqual(@as(u32, 0xaaaa0001), tcp.rcv_nxt);
    try std.testing.expect(tcp.tx_pending);
    try std.testing.expectEqual(@as(u64, 0), tcp.retx_count);
    try std.testing.expectEqual(@as(u64, 100), tcp.tx_ticks);
    try std.testing.expectEqual(@as(usize, data_len), tcp.retx_len);
    try std.testing.expectEqualSlices(u8, data0[0..data_len], tcp.retx_msg[0..tcp.retx_len]);

    // Readable/writable exactly as before the knock.
    try std.testing.expectEqual(before, ready_mask());

    // The peer's next data segment builds its bare ACK into the SHARED
    // slot — the refusal has its OWN slot and survives it (the observed
    // run-01 failure mode: a later build must not swallow the refusal).
    const d = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0001, 0x5555555a, flag_ack, "ok");
    try std.testing.expectEqual(Event.data_recv, handle_rx(&d));
    try std.testing.expect(tcp.ack_pending); // the bare ACK queued in `msg`
    try std.testing.expectEqual(@as(u8, flag_ack), tcp.msg[13]);
    try std.testing.expect(tcp.rst_pending); // the refusal is UNTOUCHED
    try std.testing.expectEqual(@as(u8, flag_rst | flag_ack), tcp.rst_msg[13]);
    try std.testing.expectEqual(@as(usize, 20), tcp.rst_len);
    try std.testing.expectEqualSlices(u8, "ok", take_rx());

    // The app's next send builds into the shared slot — the refusal is
    // still queued in its own slot.
    build_data_msg("reply");
    try std.testing.expect(tcp.rst_pending);
    try std.testing.expectEqual(@as(u8, flag_rst | flag_ack), tcp.rst_msg[13]);

    // The TX side flushes the refusal and the ACK; the RTO then
    // retransmits the ORIGINAL data segment byte-exact (the retransmit
    // state survived everything).
    tcp.rst_pending = false;
    tcp.ack_pending = false;
    tcp.now_ticks += rto_ticks;
    try std.testing.expectEqual(RtoEvent.retransmit, poll_rto());
    try std.testing.expectEqualSlices(u8, data0[0..data_len], tcp.msg[0..tcp.msg_len]);

    // ...and the real peer's traffic still flows both ways.
    const ack = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0003, 0x5555555b, flag_ack, &.{});
    try std.testing.expectEqual(Event.none, handle_rx(&ack));
    try std.testing.expect(!tcp.tx_pending); // the ACK covered the pending data
    build_data_msg("reply2");
    try std.testing.expectEqual(@as(u16, 9999), (@as(u16, tcp.msg[2]) << 8) | tcp.msg[3]); // to the real peer
    try std.testing.expectEqual(@as(u64, 2), ready_mask() & 2); // writable again
}

test "tcp: M84f — a queued refusal coexists with the RTO: the pending data retransmits while it waits" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    tcp.now_ticks = 100;
    start(ip_host, 9999, 0x88888888, host_mac);
    advance_snd(1);
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0000, 0x88888889, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));
    tcp.ack_pending = false; // the handshake ACK was transmitted
    build_data_msg("hold");
    advance_snd(4);
    record_pending();
    var data0: [segment_max]u8 = undefined;
    @memcpy(data0[0..tcp.msg_len], tcp.msg[0..tcp.msg_len]);
    const data_len = tcp.msg_len;

    // The over-cap SYN queues the refusal into its own slot.
    const syn = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9997, default_src_port, 0x99999999, 0, flag_syn, &.{});
    try std.testing.expectEqual(Event.none, handle_rx(&syn));
    try std.testing.expect(tcp.rst_pending);
    try std.testing.expectEqual(@as(u8, flag_rst | flag_ack), tcp.rst_msg[13]);

    // The refusal does NOT block or disturb the retransmission: the RTO
    // fires and the pending data is rebuilt byte-exact while the refusal
    // keeps waiting in its own slot (both obligations survive).
    tcp.now_ticks += rto_ticks;
    try std.testing.expectEqual(RtoEvent.retransmit, poll_rto());
    try std.testing.expectEqualSlices(u8, data0[0..data_len], tcp.msg[0..tcp.msg_len]);
    try std.testing.expectEqual(@as(u64, 1), tcp.retransmitted);
    try std.testing.expect(tcp.rst_pending); // still queued
    try std.testing.expectEqual(@as(u8, flag_rst | flag_ack), tcp.rst_msg[13]);

    // The refusal flushes independently of the connection's segments.
    tcp.rst_pending = false;
    try std.testing.expect(!tcp.rst_pending);
}

test "tcp: M84f — a SYN with no connection (IDLE) is refused RST+ACK to the requester" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    const syn = craft_frame(ip_host, host_mac, ip_guest, test_mac, 40000, default_src_port, 0x12345678, 0, flag_syn, &.{});
    try std.testing.expectEqual(Event.none, handle_rx(&syn));
    // No connection appears — the refusal is answered to the requester.
    try std.testing.expectEqual(State.idle, tcp.state);
    try std.testing.expect(tcp.rst_pending);
    try std.testing.expectEqual(@as(u8, flag_rst | flag_ack), tcp.rst_msg[13]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, tcp.rst_msg[4..8]); // seq 0
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x79 }, tcp.rst_msg[8..12]); // ack = seq+1
    try std.testing.expectEqual(@as(u16, default_src_port), (@as(u16, tcp.rst_msg[0]) << 8) | tcp.rst_msg[1]);
    try std.testing.expectEqual(@as(u16, 40000), (@as(u16, tcp.rst_msg[2]) << 8) | tcp.rst_msg[3]); // to the requester
    // No live peer exists: the seam's TX identity is the requester's.
    try std.testing.expectEqualSlices(u8, &ip_host, &tcp.peer_ip);
    try std.testing.expectEqual(@as(u16, 40000), tcp.peer_port);
    try std.testing.expectEqualSlices(u8, &host_mac, &tcp.peer_mac);
    try std.testing.expectEqual(@as(u64, 1), tcp.rst_sent);
}
test "tcp: M97e-F2 — a forged source IP and out-of-sequence segments cannot move the connection" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    tcp.now_ticks = 100;
    start(ip_host, 9999, 0x55555555, host_mac);
    advance_snd(1); // the SYN consumed one
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0000, 0x55555556, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));
    try std.testing.expectEqual(State.established, tcp.state);
    tcp.ack_pending = false; // the handshake ACK was transmitted
    try std.testing.expectEqual(@as(u32, 0xaaaa0001), tcp.rcv_nxt);

    // ONE unACKed data segment in flight — the retransmission timer is
    // armed (the forged-ACK-must-not-clear-it proof needs it).
    build_data_msg("frame");
    advance_snd(5);
    record_pending();
    try std.testing.expect(tcp.tx_pending);
    const dropped0 = tcp.dropped_malformed;
    const bad_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x66 };
    const attacker_ip = [4]u8{ 10, 0, 0, 66 };

    // A forged ACK from a THIRD HOST — the peer's port, a covering ACK
    // number, valid checksum: it must never reach the connection, so the
    // retransmission timer keeps running.
    const forged_ack = craft_frame(attacker_ip, bad_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0001, 0x55555560, flag_ack, &.{});
    try std.testing.expectEqual(Event.none, handle_rx(&forged_ack));
    try std.testing.expect(tcp.tx_pending); // NOT cleared by a non-peer
    try std.testing.expectEqual(dropped0 + 1, tcp.dropped_malformed);

    // A forged payload from the third host: never buffered, state intact.
    const forged_data = craft_frame(attacker_ip, bad_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0001, 0x5555555a, flag_ack, "evil");
    try std.testing.expectEqual(Event.none, handle_rx(&forged_data));
    try std.testing.expect(!tcp.rx_pending);
    try std.testing.expectEqual(dropped0 + 2, tcp.dropped_malformed);
    try std.testing.expectEqual(State.established, tcp.state);
    try std.testing.expectEqualSlices(u8, &ip_host, &tcp.peer_ip);

    // An out-of-sequence payload from the REAL peer (seq beyond rcv_nxt —
    // reordered or a blind inject riding the right 4-tuple): dropped, no
    // buffered bytes, the timer stays armed even though its ACK field
    // would have covered the pending segment.
    const oos = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0009, 0x55555560, flag_ack, "late");
    try std.testing.expectEqual(Event.none, handle_rx(&oos));
    try std.testing.expect(!tcp.rx_pending);
    try std.testing.expect(tcp.tx_pending);
    try std.testing.expectEqual(dropped0 + 3, tcp.dropped_malformed);

    // A stale in-window-less ACK from the peer (an old seq, a covering
    // ack): refused the same way — the timer keeps running.
    const stale = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0001 -% 4, 0x55555560, flag_ack, &.{});
    try std.testing.expectEqual(Event.none, handle_rx(&stale));
    try std.testing.expect(tcp.tx_pending);
    try std.testing.expectEqual(dropped0 + 4, tcp.dropped_malformed);

    // The real in-sequence segment still lands (the refusal is not a
    // wedge): the payload is buffered and — its ACK covering the pending
    // send — the retransmission timer stops HONESTLY.
    const ok = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, tcp.rcv_nxt, tcp.snd_una, flag_ack, "ok");
    try std.testing.expectEqual(Event.data_recv, handle_rx(&ok));
    try std.testing.expect(tcp.rx_pending);
    try std.testing.expect(!tcp.tx_pending); // the peer's own ACK covers it
    try std.testing.expectEqualSlices(u8, "ok", take_rx());
}
