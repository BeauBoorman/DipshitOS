//! TCP client (RFC 793) over the card-N4 IPv4 seam — milestone five,
//! card N10 (claim 7026). PURE protocol logic (segment build/parse, the
//! IPv4 pseudo-header checksum, the bounded client state machine, the
//! four-segment lifecycle SYN -> SYN-ACK -> (data <-> echo) -> FIN ->
//! FIN-ACK -> final ACK, the bounded connect timeout) + host tests, the
//! dhcp.zig/udp.zig fat.zig pattern; `ipv4.zig` wires it to
//! ALREADY-VALIDATED IPv4 frames (protocol 6 dispatch — the IPv4
//! checksum/fragment/dst checks stay in ipv4, never duplicated) and
//! `virtio_net.zig`'s `net_tcp_send` drives the transmit side (the N1
//! one-request-at-a-time TX path).
//!
//! Honest bounds (documented, never assumed away): BOUNDED
//! retransmission (card N11, claim 5357 — a SYN/data/FIN with no ACK
//! is retransmitted on a FIXED 3 s RTO of guest ticks, at most
//! `retx_max` = 10 times, then the connection ABORTS honestly —
//! counted `retx_aborted`; bare ACKs are NEVER retransmitted; the 30 s
//! connect timeout remains the SYN's outer bound — the retransmission
//! abort at 33 s never beats it, so the N10 refusal is byte-exact;
//! every retransmission is byte-identical — the pending segment copy —
//! and counted `retransmitted`; an ACK covering everything the client
//! sent clears the pending state, so an acknowledged segment is never
//! retransmitted); ONE bounded connect timeout (30 s of guest ticks —
//! the card-N9 timer pattern — a SYN with no SYN-ACK refuses honestly,
//! counted `timed_out`); NO TCP options (a bare 20-byte header — no
//! MSS, no window scaling, no SACK, no timestamps — a segment with a
//! data offset != 5 is DROPPED, counted); a FIXED window (4096); no
//! segmentation (payload <= `payload_max`, truncated honestly on TX);
//! no reassembly (ONE bounded RX segment — a second unread segment is
//! DROPPED, counted, never overwritten silently); NO TCP loopback (the
//! client connects OUTWARD only — an own-IP connect is refused
//! `.no_peer` like an unresolved peer); no server surface, no port
//! listening, no urgent data, no congestion control, no adaptive RTO
//! (a fixed timer — no Karn's algorithm, no exponential backoff). The
//! close is client-driven (FIN -> FIN-ACK -> final ACK); a clean
//! server FIN+ACK in ESTABLISHED is ACKed and counted
//! (`finack_recv`), and the caller's `net tcp close` then completes
//! the close; an over-cap SYN (a second peer knocking while the ONE
//! connection is taken, in any non-listen state) is refused HONESTLY
//! with RST+ACK (M84f, #1836) — never silently dropped; anything else
//! is counted `dropped_malformed`. The fixed source port is 8000 (the
//! UDP layer's 7000 analog — deterministic, gate-assertable).

const std = @import("std");
pub const arp = @import("arp.zig"); // N3: our static IP (`arp.own_ip` — the ONE copy)
const csprng = @import("csprng.zig"); // the kernel CSPRNG — the server's ISN draw (M97e-F2 rider)

// ---------------------------------------------------------------------------
// Wire constants (RFC 793)
// ---------------------------------------------------------------------------

/// The IP protocol number for TCP.
pub const protocol_tcp: u8 = 6;
pub const eth_hdr_len: usize = 14; // the same values as ipv4.zig (constants only — no circular import)
pub const ipv4_hdr_len: usize = 20;
/// The TCP header WITHOUT options (the honest bound — offset 5 only).
pub const tcp_hdr_len: usize = 20;
/// The fixed source port for the client (deterministic, gate-assertable —
/// the UDP layer's `default_src_port` 7000 analog).
pub const default_src_port: u16 = 8000;
/// Bounded payload per segment (the N5 `payload_max` bound — honest
/// truncation on TX; a longer RX payload is dropped, counted).
/// M50 TS4 (#1138, ADR 0024 D6): raised 64 -> 192 so one
/// `VIRELAIOS-AUTH/1` challenge line (95 bytes) or one hex reply line
/// (129 bytes) fits a single segment. M84e (#1835): raised to the Ethernet
/// MTU's 1460-byte TCP payload after measuring multi-second ACK round trips
/// on full-screen RFB updates. Still one bounded, reassembly-free segment;
/// no IP fragmentation or TCP options are introduced.
pub const payload_max: usize = 1500 - ipv4_hdr_len - tcp_hdr_len;
/// The segment buffer bound: 20-byte header + the bounded payload.
pub const segment_max: usize = tcp_hdr_len + payload_max; // 1480
/// The largest full frame: Ethernet + IPv4 + the bounded segment.
pub const frame_max: usize = eth_hdr_len + ipv4_hdr_len + segment_max; // 1514
/// The smallest full frame: Ethernet + IPv4 + the 20-byte header.
pub const frame_min: usize = eth_hdr_len + ipv4_hdr_len + tcp_hdr_len; // 54
/// The fixed advertised window (no window scaling — honest bound).
pub const window: u16 = 4096;
/// The connect timeout in guest seconds (the 1 Hz generic timer — the
/// card-N9 lease-clock pattern). A SYN with no SYN-ACK after this long
/// refuses honestly (`timed_out`), releasing the connection state. Card
/// N11 keeps this as the SYN's OUTER bound: the retransmission abort
/// fires at (retx_max + 1) * rto = 33 s > 30 s, so the N10 refusal is
/// byte-exact.
pub const connect_timeout: u64 = 30;
/// Slot 30's optional millisecond budget, measured by the physical counter
/// even while the network service lock masks timer IRQs. Round UP to a
/// counter tick; reject an unavailable clock or an unrepresentable interval.
pub const ConnectDeadline = struct {
    start: u64,
    duration: u64,

    pub fn init(counter: u64, freq: u64, timeout_ms: u32) ?ConnectDeadline {
        if (freq == 0) return null;
        const ms: u64 = if (timeout_ms == 0) connect_timeout * 1000 else timeout_ms;
        const ticks = (@as(u128, freq) * ms + 999) / 1000;
        if (ticks > std.math.maxInt(u64)) return null;
        return .{ .start = counter, .duration = @intCast(ticks) };
    }

    pub fn expired(self: ConnectDeadline, counter: u64) bool {
        return counter -% self.start >= self.duration;
    }
};
/// The fixed retransmission timeout in guest seconds (card N11, claim
/// 5357). A SYN/data/FIN with no ACK is retransmitted when its RTO
/// expires — a fixed timer (no adaptive estimation, no Karn's
/// algorithm, no exponential backoff — the honest bound).
pub const rto_ticks: u64 = 3;
/// The retransmission bound (card N11): a segment is retransmitted at
/// most `retx_max` times (11 transmissions total), then the connection
/// ABORTS honestly (`retx_aborted`), releasing the state. The abort
/// fires at (retx_max + 1) * rto = 33 s of guest ticks — after the 30 s
/// connect timeout, so the SYN's outer bound is unchanged.
pub const retx_max: u64 = 10;

// Flags (RFC 793 §3.1 — the 9-bit flag field; only the ones we use).
pub const flag_fin: u8 = 0x01;
pub const flag_syn: u8 = 0x02;
pub const flag_rst: u8 = 0x04;
pub const flag_ack: u8 = 0x10;

// ---------------------------------------------------------------------------
// Counters (the `net` report's `tcp=` line) — every step counted.
// ---------------------------------------------------------------------------

pub var syn_sent: u64 = 0; // SYN segments transmitted (a connect attempt)
pub var synack_recv: u64 = 0; // the handshake SYN-ACK accepted
pub var ack_sent: u64 = 0; // bare ACK segments transmitted (handshake / echo / final)
pub var data_sent: u64 = 0; // data segments transmitted (`net tcp send`)
pub var data_recv: u64 = 0; // payload segments accepted into the RX buffer
pub var fin_sent: u64 = 0; // FIN segments transmitted (`net tcp close`)
pub var finack_recv: u64 = 0; // FIN-ACK segments received (the close answer / a server FIN)
pub var rst_sent: u64 = 0; // RST segments transmitted (`net tcp reset`)
pub var rst_recv: u64 = 0; // RST segments received (the connection died)
pub var timed_out: u64 = 0; // the bounded connect timeout refused
pub var retransmitted: u64 = 0; // segment retransmissions (card N11 — the `retx=` counter)
pub var retx_aborted: u64 = 0; // the retransmission bound aborted the connection (the `abort=` counter)
pub var dropped_badsum: u64 = 0; // the TCP checksum mismatch (pseudo-header + segment)
pub var dropped_malformed: u64 = 0; // an unparseable / unexpected / out-of-bounds segment

// ---------------------------------------------------------------------------
// State (pure BSS — ONE client connection)
// ---------------------------------------------------------------------------

pub const State = enum {
    idle,
    listen, // passive open — listening for incoming connection
    syn_sent, // the SYN went out — awaiting the SYN-ACK
    syn_received, // incoming SYN received — SYN-ACK sent, awaiting ACK
    established, // the handshake ACK went out — data can flow
    fin_sent, // the FIN went out — awaiting the FIN-ACK
    closed, // the close completed (clean FIN-ACK) or a RST killed the connection
};

pub var state: State = .idle;
pub var listen_port: u16 = 0;
pub var is_server: bool = false;
/// The peer: its IP, port, and MAC (the caller resolved the MAC with
/// `net arp <ip>` — the seam resolves nothing).
pub var peer_ip: [4]u8 = .{ 0, 0, 0, 0 };
pub var peer_port: u16 = 0;
pub var peer_mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
/// The client's initial sequence number (CSPRNG-drawn at connect — real
/// TCP randomizes ISNs; the gate asserts the SYN's seq and the ACK chain
/// structurally, not by value).
pub var isn: u32 = 0;
/// The server's ISN (from the accepted SYN-ACK).
pub var srv_isn: u32 = 0;
/// The next sequence number the client will send (snd_una; the SYN and
/// FIN each consume one sequence number).
pub var snd_una: u32 = 0;
/// The next sequence number the client expects to receive.
pub var rcv_nxt: u32 = 0;
/// The next outbound segment (the ONE fixed buffer — the SYN, the
/// handshake ACK, a data segment, a bare ACK, the FIN, the RST, the
/// final ACK — built by the state machine, transmitted by the monitor).
pub var msg: [segment_max]u8 = undefined;
pub var msg_len: usize = 0;
/// A built ACK segment is waiting to be transmitted (the RX processing
/// builds it; the monitor transmits it on the next `net tcp` — the
/// polled-drain contract, never a transmit from the drain context).
pub var ack_pending: bool = false;
/// M84f (#1836): the over-cap refusal's OWN bounded slot. The refusal
/// NEVER rides `msg`/`record_pending` — the shared build_msg/tx slot
/// must not overwrite an unACKed data segment, and a later build (the
/// peer's next data ACK) must not swallow the queued refusal. The
/// RST+ACK stages here until a TX site flushes it: the syscall seam's
/// TCP TX sites and the shell idle loop send `rst_msg` FIRST, then
/// `msg` as before. `rst_pending` is the queue bit (cleared on
/// transmit; `reset` clears it, a connection transition does not — the
/// refusal answers the knock it saw, whatever the connection does).
pub var rst_msg: [segment_max]u8 = undefined;
pub var rst_len: usize = 0;
pub var rst_pending: bool = false;
/// The bounded RX buffer (ONE segment — no reassembly, honest bound).
pub var rx_payload: [payload_max]u8 = undefined;
pub var rx_len: usize = 0;
pub var rx_pending: bool = false;
/// SH7 (#1083): a clean peer FIN+ACK was received in ESTABLISHED. The
/// connection stays ESTABLISHED (the kernel TCP seam's close discipline),
/// but the net terminal front-end uses this to auto-detach on disconnect
/// (Amendment B, B4). Cleared by `listen`/`release_conn`/`reset`.
pub var peer_fin: bool = false;
/// M46 RC3 (#1111, ADR 0022 D4): the optional source-IP allowlist for the
/// passive-open path. When `allow_ip_set`, a SYN from any other source IP is
/// refused with an RST (`auth_rejected`) and the listener stays up. Cleared
/// by `reset()`; set by the net-front-end attach syscall after `listen()`.
pub var allow_ip: [4]u8 = .{ 0, 0, 0, 0 };
pub var allow_ip_set: bool = false;
/// M46 RC3: server connections refused by the source-IP allowlist.
pub var auth_rejected: u64 = 0;
/// M46 RC3/#1105: set when the retransmission bound aborts a server SYN-ACK
/// (a half-open accept — a client sent SYN and never ACKed). A diagnostic for
/// the monitor/idle-loop RTO poll; the net-front-end pump uses its own
/// dedicated `accept_ticks` clock instead (it never retransmits).
pub var accept_aborted: bool = false;
/// M46 #1105: the half-open accept clock. Stamped when an incoming SYN is
/// accepted (the pump's `now_ticks` at that moment); the net-front-end pump
/// detaches when `now_ticks - accept_ticks >= accept_timeout`.
pub var accept_ticks: u64 = 0;
pub const accept_timeout: u64 = 30;
/// The connect-timeout clock. The caller (the shell idle loop + `net
/// tcp`) stamps `now_ticks` from the 1 Hz generic timer (`timer.ticks`
/// — seconds) each poll; `start` stamps `syn_ticks`, so the elapsed
/// connect time is honest wall-clock seconds.
pub var now_ticks: u64 = 0;
pub var syn_ticks: u64 = 0;
/// Card N11 (claim 5357) — the bounded retransmission state. ONE
/// pending-unacknowledged segment (the polled-drain contract: at most
/// ONE unacked TX in flight — the retransmission buffer is the bounded
/// `segment_max` copy, never a second allocation). `tx_pending` is set
/// by `record_pending` after a sequence-consuming segment (SYN/data/FIN)
/// is transmitted and cleared when an ACK covers it (the `handle_rx`
/// paths) or the connection dies (RST / timeout / abort / reset). Bare
/// ACKs are NEVER recorded — they are never retransmitted (the honest
/// bound).
pub var tx_pending: bool = false;
pub var retx_msg: [segment_max]u8 = undefined;
pub var retx_len: usize = 0;
/// When the pending segment was last transmitted (initial + each
/// retransmission) — the RTO clock, stamped by `record_pending` and the
/// retransmit itself.
pub var tx_ticks: u64 = 0;
pub var retx_count: u64 = 0; // retransmissions of the CURRENT pending segment

/// The RX dispatch's outcome — the caller (the monitor) observes it via
/// `state`; the enum is the honest event for the host tests.
pub const Event = enum {
    none,
    synack_recv, // the handshake SYN-ACK accepted — the ACK is built (ack_pending)
    data_recv, // a payload segment accepted — buffered, the ACK is built
    finack_recv, // a FIN-ACK received — the final ACK (or an echo ACK) is built
    rst_recv, // a RST — the connection died
};

/// The RTO poll's outcome (card N11, claim 5357) — the caller (the
/// shell idle loop) observes it; `.retransmit` means `msg` holds the
/// rebuilt pending segment (transmit it + print), `.abort` means the
/// retransmission bound released the connection (print).
pub const RtoEvent = enum {
    none,
    retransmit,
    abort,
};

// ---------------------------------------------------------------------------
// RFC 1071 one's-complement checksum (the udp.zig machinery, protocol 6 —
// the IPv4 pseudo-header per RFC 793 §3.1)
// ---------------------------------------------------------------------------

pub fn sum_words(data: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u32, data[i]) << 8) | data[i + 1];
    }
    if (i < data.len) sum += @as(u32, data[i]) << 8; // trailing odd byte
    return sum;
}

pub fn fold(sum: u32) u16 {
    var s = sum;
    while (s >> 16 != 0) s = (s & 0xffff) + (s >> 16);
    return ~@as(u16, @truncate(s));
}

/// The TCP checksum over the IPv4 pseudo-header (src IP, dst IP, zero,
/// protocol 6, TCP length) + the segment (`segment` = the 20-byte header
/// + payload; the checksum field must be ZEROED by the caller when
/// building — the verification path passes the field as read). Word 5 is
/// bytes 8-9 = 0x00 0x06 (the ZERO byte HIGH, protocol 6 LOW — the RFC
/// layout; a reversed byte order here silently breaks every segment
/// against standard peers, caught by the live gate's byte-exact
/// fixtures).
pub fn checksum_tcp(src: [4]u8, dst: [4]u8, segment: []const u8) u16 {
    const len: u16 = @intCast(segment.len);
    var s: u32 = 0;
    s += (@as(u32, src[0]) << 8) | src[1];
    s += (@as(u32, src[2]) << 8) | src[3];
    s += (@as(u32, dst[0]) << 8) | dst[1];
    s += (@as(u32, dst[2]) << 8) | dst[3];
    s += protocol_tcp; // (0x00 << 8) | 6
    s += len;
    return fold(s + sum_words(segment));
}

// ---------------------------------------------------------------------------
// Builders (byte-exact, RFC-shaped; the live gate's fixtures pin them)
// ---------------------------------------------------------------------------

/// Build a TCP segment (20-byte header + payload) into `buf` (must hold
/// >= `tcp_hdr_len + payload.len`): src/dst ports, sequence, ack, data
/// offset 5 (NO options — the honest bound), the flags, the FIXED
/// window, checksum computed over the pseudo-header (src_ip/dst_ip) +
/// the segment (RFC 1071), urgent 0. The payload is truncated honestly
/// at `payload_max`. Returns the segment length (20 + the written
/// payload).
pub fn build_segment(buf: []u8, src_ip: [4]u8, dst_ip: [4]u8, src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, payload: []const u8) usize {
    const plen = @min(payload.len, payload_max);
    const total = tcp_hdr_len + plen;
    @memset(buf[0..total], 0);
    buf[0] = @truncate(src_port >> 8);
    buf[1] = @truncate(src_port);
    buf[2] = @truncate(dst_port >> 8);
    buf[3] = @truncate(dst_port);
    buf[4] = @truncate(seq >> 24);
    buf[5] = @truncate(seq >> 16);
    buf[6] = @truncate(seq >> 8);
    buf[7] = @truncate(seq);
    buf[8] = @truncate(ack >> 24);
    buf[9] = @truncate(ack >> 16);
    buf[10] = @truncate(ack >> 8);
    buf[11] = @truncate(ack);
    buf[12] = 0x50; // data offset 5 (no options) — the honest bound
    buf[13] = flags;
    buf[14] = @truncate(window >> 8);
    buf[15] = @truncate(window);
    // Checksum field at 16..18 — zeroed by the memset during the computation.
    // Urgent pointer at 18..20 = 0 (no urgent data).
    @memcpy(buf[20..total], payload[0..plen]);
    const c = checksum_tcp(src_ip, dst_ip, buf[0..total]);
    buf[16] = @truncate(c >> 8);
    buf[17] = @truncate(c);
    return total;
}

/// Build the FULL Ethernet + IPv4 + TCP frame into `buf` (must hold >=
/// `eth_hdr_len + ipv4_hdr_len + segment.len`): dst MAC (the peer — the
/// caller resolved it), src MAC, ethertype 0x0800, a 20-byte IPv4 header
/// (version 4 / IHL 5, identification 0 — deterministic, total length,
/// TTL 64, protocol 6, header checksum), then the pre-built segment.
/// Returns the frame length (54 + the segment payload).
pub fn build_frame(buf: []u8, own_mac: *const [6]u8, own_ip: [4]u8, dst_mac: [6]u8, dst_ip: [4]u8, segment: []const u8) usize {
    const total = ipv4_hdr_len + segment.len;
    const frame_len = eth_hdr_len + total;
    @memset(buf[0..frame_len], 0);
    @memcpy(buf[0..6], &dst_mac); // dst
    @memcpy(buf[6..12], own_mac); // src
    buf[12] = 0x08;
    buf[13] = 0x00; // ethertype IPv4
    buf[14] = 0x45; // version 4, IHL 5
    buf[16] = @truncate(total >> 8);
    buf[17] = @truncate(total); // total length
    // Identification (18..20) = 0 (deterministic, gate-assertable).
    buf[22] = 64; // TTL
    buf[23] = protocol_tcp;
    @memcpy(buf[26..30], &own_ip); // src
    @memcpy(buf[30..34], &dst_ip); // dst
    // IPv4 header checksum (the field at 24..26 is zeroed by the memset).
    const hc = fold(sum_words(buf[14..34]));
    buf[24] = @truncate(hc >> 8);
    buf[25] = @truncate(hc);
    @memcpy(buf[34 .. 34 + segment.len], segment);
    return frame_len;
}

fn be32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

// ---------------------------------------------------------------------------
// The client state machine
// ---------------------------------------------------------------------------

pub var owner_pid: ?u64 = null;

/// Close connection if owned by `pid` (called during process exit).
pub fn close_owner(pid: u64) void {
    if (owner_pid) |p| {
        if (p == pid) {
            if (state == .established or state == .syn_sent or state == .fin_sent) {
                release_conn();
            }
            owner_pid = null;
        }
    }
}

/// Reset socket state without erasing diagnostic counters.
pub fn reset_connection() void {
    state = .idle;
    is_server = false;
    listen_port = 0;
    owner_pid = null;
    peer_ip = .{ 0, 0, 0, 0 };
    peer_port = 0;
    peer_mac = .{ 0, 0, 0, 0, 0, 0 };
    isn = 0;
    srv_isn = 0;
    snd_una = 0;
    rcv_nxt = 0;
    msg_len = 0;
    ack_pending = false;
    rst_len = 0;
    rst_pending = false;
    rx_len = 0;
    rx_pending = false;
    peer_fin = false;
    allow_ip = .{ 0, 0, 0, 0 };
    allow_ip_set = false;
    accept_aborted = false;
    accept_ticks = 0;
    tx_pending = false;
    retx_len = 0;
    tx_ticks = 0;
    retx_count = 0;
    now_ticks = 0;
    syn_ticks = 0;
}

/// Reset socket state and counters (host-test/boot initialization).
pub fn reset() void {
    reset_connection();
    auth_rejected = 0;
    syn_sent = 0;
    synack_recv = 0;
    ack_sent = 0;
    data_sent = 0;
    data_recv = 0;
    fin_sent = 0;
    finack_recv = 0;
    rst_sent = 0;
    rst_recv = 0;
    timed_out = 0;
    retransmitted = 0;
    retx_aborted = 0;
    dropped_badsum = 0;
    dropped_malformed = 0;
}

/// Enter LISTEN state on a local port (passive open).
pub fn listen(port: u16) void {
    state = .listen;
    listen_port = port;
    is_server = true;
    peer_ip = .{ 0, 0, 0, 0 };
    peer_port = 0;
    peer_mac = .{ 0, 0, 0, 0, 0, 0 };
    isn = 0;
    srv_isn = 0;
    snd_una = 0;
    rcv_nxt = 0;
    msg_len = 0;
    ack_pending = false;
    rx_len = 0;
    rx_pending = false;
    peer_fin = false;
    clear_pending();
}

/// Build the next outbound segment into `msg` for THE connection (the
/// fixed src port + the stored peer).
fn build_msg(seq: u32, ack: u32, flags: u8, payload: []const u8) void {
    const local_port = if (is_server) listen_port else default_src_port;
    msg_len = build_segment(&msg, arp.own_ip, peer_ip, local_port, peer_port, seq, ack, flags, payload);
}

/// IDLE -> SYN_SENT: record the peer (the caller resolved the MAC), draw
/// the initial sequence number, and build the SYN into `msg` (seq = the
/// ISN, no ACK — RFC 793 §3.4). The caller transmits `msg[0..msg_len]`,
/// counts `syn_sent`, and advances `snd_una` by 1 (the SYN consumes one
/// sequence number).
pub fn start(peer_ip_in: [4]u8, dst_port: u16, isn_in: u32, peer_mac_in: [6]u8) void {
    is_server = false;
    peer_ip = peer_ip_in;
    peer_port = dst_port;
    peer_mac = peer_mac_in;
    isn = isn_in;
    snd_una = isn_in;
    rcv_nxt = 0;
    srv_isn = 0;
    ack_pending = false;
    rx_pending = false;
    syn_ticks = now_ticks; // the connect clock starts now
    build_msg(isn, 0, flag_syn, &.{});
    state = .syn_sent;
}

/// Seconds since the SYN went out, per the caller-stamped clock.
pub fn elapsed() u64 {
    return now_ticks -| syn_ticks;
}

/// The bounded connect timeout expired (a SYN with no SYN-ACK).
pub fn connect_timed_out() bool {
    return elapsed() >= connect_timeout;
}

/// The honest connect-refuse: release the connection state and fall back
/// to IDLE, counted `timed_out`. The caller (the monitor) prints the
/// refusal; the next `net tcp connect` is a fresh attempt.
pub fn abort_timeout() void {
    if (is_server) release_conn() else reset_connection();
    timed_out += 1;
}

/// Release the connection state honestly (the N10 `abort_timeout` shape
/// — no RST, no TX): IDLE (or LISTEN if server), the peer cleared, the pending buffers
/// cleared. Called by the connect refusal, the retransmission abort
/// (card N11), and any death path.
/// Issue #1163 (phase 2): the readiness mask for the netpoll seam
/// (slot 76). Bit 0 = readable (a segment payload is queued, the
/// connection is closed/fin_sent, or a peer FIN was received — recv
/// drains the queued bytes and then reports 0, so the caller fails
/// closed); bit 1 = writable (established with no pending
/// retransmission). 0 = nothing to report. Level-triggered by design: it
/// is a query, not an edge, so a poller cannot lose readiness.
pub fn ready_mask() u64 {
    var mask: u64 = 0;
    if (rx_pending) mask |= 1;
    if (state == .closed or state == .fin_sent) mask |= 1;
    if (peer_fin) mask |= 1;
    if (state == .established and !tx_pending) mask |= 2;
    return mask;
}

/// Issue #1163 (phase 2): the slot-76 ownership test — only the process
/// that opened the ONE socket may probe or wait on it (the kernel's
/// one-TCP-socket-per-process law).
pub fn owned_by_pid(pid: u64) bool {
    if (owner_pid) |o| return o == pid;
    return false;
}

pub fn release_conn() void {
    state = if (is_server) .listen else .idle;
    peer_ip = .{ 0, 0, 0, 0 };
    peer_port = 0;
    peer_mac = .{ 0, 0, 0, 0, 0, 0 };
    ack_pending = false;
    rx_pending = false;
    peer_fin = false;
    clear_pending();
}

/// Card N11 (claim 5357): record the just-transmitted sequence-consuming
/// segment (SYN/data/FIN) as the ONE pending segment — a copy of `msg`
/// (the retransmission buffer, bounded `segment_max`), the RTO clock
/// re-stamped, the retransmission count reset. The caller (the monitor)
/// calls it AFTER a successful transmit; a bare ACK or a RST never calls
/// it (they are never retransmitted).
pub fn record_pending() void {
    @memcpy(retx_msg[0..msg_len], msg[0..msg_len]);
    retx_len = msg_len;
    tx_ticks = now_ticks;
    retx_count = 0;
    tx_pending = true;
}

/// Card N11: clear the pending state (an ACK covered the pending
/// segment, or the connection died). The retransmission timer stops.
pub fn clear_pending() void {
    tx_pending = false;
    retx_len = 0;
    retx_count = 0;
}

/// RFC 1982-style sequence comparison: `a` is at or past `b` (treating
/// the u32 wrap). Used for the ACK-clears-pending check — the peer's
/// ACK covers everything the client has sent when it reaches `snd_una`.
fn seq_ge(a: u32, b: u32) bool {
    return (a -% b) < 0x8000_0000;
}

/// Card N11 (claim 5357): the bounded retransmission poll — the shell
/// idle loop calls it after the RX drain (an ACK processed by the drain
/// cleared the pending state — a retransmission NEVER follows an
/// acknowledged segment). One step per poll: if the pending segment's
/// RTO (3 s of guest ticks) has expired and the bound is not exhausted,
/// rebuild `msg` from the pending copy (byte-identical — the same seq,
/// flags, payload, checksum) and count it; if the bound IS exhausted
/// (10 retransmissions), release the connection honestly (`release_conn`
/// — no RST, no TX) and count the abort. Bare ACKs are never pending.
pub fn poll_rto() RtoEvent {
    if (!tx_pending) return .none;
    if (state == .idle or state == .closed) {
        clear_pending(); // the connection died another way — stop the timer
        return .none;
    }
    if (now_ticks -| tx_ticks < rto_ticks) return .none;
    if (retx_count >= retx_max) {
        retx_aborted += 1;
        // #1105: a server SYN-ACK that exhausted its retransmissions is a
        // half-open accept — flag it so the terminal pump detaches.
        if (is_server and state == .syn_received) accept_aborted = true;
        release_conn();
        return .abort;
    }
    @memcpy(msg[0..retx_len], retx_msg[0..retx_len]);
    msg_len = retx_len;
    retx_count += 1;
    retransmitted += 1;
    tx_ticks = now_ticks; // the RTO clock restarts at each transmission
    return .retransmit;
}

/// Advance the send sequence by the segment's consumption (1 for the SYN
/// and the FIN, the payload length for data, 0 for a bare ACK). The
/// caller calls it after a successful transmit.
pub fn advance_snd(consumed: usize) void {
    snd_una +%= @intCast(consumed);
}

/// ESTABLISHED: build the data segment for `payload` (seq = snd_una, ack
/// = rcv_nxt — every outbound segment after the handshake carries the
/// client's receive state, RFC 793 §3.5). The payload is truncated
/// honestly at `payload_max`.
pub fn build_data_msg(payload: []const u8) void {
    build_msg(snd_una, rcv_nxt, flag_ack, payload);
}

/// ESTABLISHED: build the FIN (seq = snd_una, ack = rcv_nxt, FIN+ACK —
/// the client-driven close, RFC 793 §3.5).
pub fn build_fin_msg() void {
    build_msg(snd_una, rcv_nxt, flag_ack | flag_fin, &.{});
}

/// ESTABLISHED/SYN_SENT: build the RST (seq = snd_una, ack = rcv_nxt,
/// RST+ACK — the client's abort).
pub fn build_rst_msg() void {
    build_msg(snd_una, rcv_nxt, flag_ack | flag_rst, &.{});
}

/// M84f (#1836): the over-cap refusal — answer a SYN the ONE connection
/// cannot admit with RST+ACK, the RFC 793 §3.4 closed-port form (the
/// listen-state allowlist's honest form: seq 0, ack = the SYN's next
/// sequence number). The refusal stages in its OWN slot (`rst_msg`): it
/// never touches `msg`, `record_pending`'s pending segment, or the
/// retransmit state — the shared build_msg/tx slot cannot overwrite an
/// unACKed data segment and no later build can swallow the refusal.
/// In a live state the peer record is NOT touched either: the segment
/// addresses the requester's PORT, and the frame rides the seam's ONE TX
/// identity (`net_tcp_send` stamps `peer_mac`/`peer_ip`) — an over-cap
/// requester on the peer's host (the second-viewer case) is answered
/// exactly; a different host is refused at the segment level only (the
/// one-connection seam's honest bound). With no live connection
/// (IDLE/CLOSED) nothing live is disturbed, so the peer record — the
/// seam's TX addressing — is pointed at the requester (the allowlist
/// form) and the answer is fully addressed.
fn refuse_overcap_syn(requester_ip: [4]u8, requester_port: u16, seq: u32, requester_mac: []const u8) void {
    if (state == .idle or state == .closed) {
        peer_ip = requester_ip;
        peer_port = requester_port;
        @memcpy(&peer_mac, requester_mac);
    }
    const local_port = if (is_server) listen_port else default_src_port;
    rst_len = build_segment(&rst_msg, arp.own_ip, peer_ip, local_port, requester_port, 0, seq +% 1, flag_rst | flag_ack, &.{});
    rst_pending = true;
    rst_sent += 1;
}

/// Copy the received payload out of the bounded RX buffer and clear it
/// (the caller — `net tcp recv` — prints it). Returns the payload slice.
pub fn take_rx() []const u8 {
    const p = rx_payload[0..rx_len];
    rx_pending = false;
    rx_len = 0;
    return p;
}

/// Process one received TCP segment (the frame's IPv4 header was ALREADY
/// validated by ipv4.zig — checksum, fragment, dst address). Runs in the
/// RX drain context; builds the client's answer into `msg` and sets
/// `ack_pending` — the transmission is MONITOR-driven on the next `net
/// tcp` (deterministic, never a transmit from the drain context).
pub fn handle_rx(frame: []const u8) Event {
    if (frame.len < frame_min) {
        dropped_malformed += 1;
        return .none;
    }
    const total = (@as(u16, frame[16]) << 8) | frame[17];
    if (total < ipv4_hdr_len + tcp_hdr_len) {
        dropped_malformed += 1;
        return .none;
    }
    const seg_len = @as(usize, total) - ipv4_hdr_len;
    const remaining = frame.len - (eth_hdr_len + ipv4_hdr_len);
    if (seg_len > remaining) {
        dropped_malformed += 1;
        return .none;
    }
    const segment = frame[eth_hdr_len + ipv4_hdr_len .. eth_hdr_len + ipv4_hdr_len + seg_len];
    var src: [4]u8 = undefined;
    @memcpy(&src, frame[26..30]);
    var dst: [4]u8 = undefined;
    @memcpy(&dst, frame[30..34]);
    if (checksum_tcp(src, dst, segment) != 0x0000) {
        dropped_badsum += 1; // a valid segment folds to 0x0000 (RFC 1071)
        return .none;
    }
    const src_port = (@as(u16, segment[0]) << 8) | segment[1];
    const dst_port = (@as(u16, segment[2]) << 8) | segment[3];
    const expected_dst = if (is_server) listen_port else default_src_port;
    if (dst_port != expected_dst) {
        dropped_malformed += 1; // a segment for a port we do not own
        return .none;
    }
    if (segment[12] >> 4 != 5) {
        dropped_malformed += 1; // options — the honest bound (offset != 5)
        return .none;
    }
    const seq = be32(segment[4..8]);
    const ack = be32(segment[8..12]);
    const flags = segment[13];
    const payload = segment[tcp_hdr_len..];
    if (payload.len > payload_max) {
        dropped_malformed += 1; // no reassembly — the honest bound
        return .none;
    }
    if (state != .listen and (src_port != peer_port or !std.mem.eql(u8, &src, &peer_ip))) {
        // M84f (#1836): an over-cap SYN (SYN set, ACK clear — a second
        // client knocking while the ONE connection is taken, in any
        // non-listen state) is refused HONESTLY — RST+ACK in the RFC 793
        // §3.4 closed-port form (the listen allowlist's form: seq 0,
        // ack = the SYN's next sequence number) — instead of a silent
        // drop (a server that silently drops looks like a dead host to
        // the caller). Anything else from a port that is not ours to
        // answer is dropped, counted.
        // M97e-F2 (#2101): the check now binds the peer's SOURCE IP too —
        // a forged segment from a third host carrying the peer's port
        // can never move this connection's state (the connection is a
        // 4-tuple, not a port).
        if ((flags & (flag_syn | flag_ack)) == flag_syn) {
            refuse_overcap_syn(src, src_port, seq, frame[6..12]);
            return .none;
        }
        dropped_malformed += 1; // not the peer we connected to
        return .none;
    }
    switch (state) {
        .idle => {
            dropped_malformed += 1; // a segment with no connection
            return .none;
        },
        .listen => {
            if ((flags & flag_syn) != 0 and (flags & flag_ack) == 0) {
                // M46 RC3 (ADR 0022 D4): a SYN from a non-allowlisted source
                // is refused with an RST+ACK (RFC 793 §3.4 closed-port form)
                // and the listener stays in LISTEN for the allowed host.
                if (allow_ip_set and !std.mem.eql(u8, &src, &allow_ip)) {
                    peer_ip = src;
                    peer_port = src_port;
                    @memcpy(&peer_mac, frame[6..12]);
                    build_msg(0, seq +% 1, flag_rst | flag_ack, &.{});
                    ack_pending = true;
                    rst_sent += 1;
                    auth_rejected += 1;
                    return .none;
                }
                // Incoming client SYN on listening port
                peer_ip = src;
                peer_port = src_port;
                @memcpy(&peer_mac, frame[6..12]);
                accept_ticks = now_ticks; // #1105 half-open accept clock
                srv_isn = seq;
                rcv_nxt = srv_isn +% 1;
                isn = @truncate(csprng.random_u64()); // the server ISN — CSPRNG-drawn like the client's (M97e-F2 rider; deterministic under the unseeded fallback)
                snd_una = isn;
                build_msg(isn, rcv_nxt, flag_syn | flag_ack, &.{});
                ack_pending = true;
                syn_sent += 1;
                advance_snd(1); // SYN-ACK consumes 1 sequence number
                record_pending();
                state = .syn_received;
                return .synack_recv;
            }
            dropped_malformed += 1;
            return .none;
        },
        .syn_received => {
            if ((flags & flag_rst) != 0) {
                rst_recv += 1;
                clear_pending();
                state = .listen;
                return .rst_recv;
            }
            if ((flags & flag_ack) != 0) {
                if (ack == snd_una) {
                    clear_pending();
                    state = .established;
                    if (payload.len != 0) {
                        @memcpy(rx_payload[0..payload.len], payload);
                        rx_len = payload.len;
                        rx_pending = true;
                        rcv_nxt = seq +% @as(u32, @intCast(payload.len));
                        data_recv += 1;
                        build_msg(snd_una, rcv_nxt, flag_ack, &.{});
                        ack_pending = true;
                        return .data_recv;
                    }
                    return .none;
                }
            }
            dropped_malformed += 1;
            return .none;
        },
        .syn_sent => {
            if ((flags & flag_rst) != 0) {
                rst_recv += 1; // connection refused — the peer RST our SYN
                clear_pending();
                state = .closed;
                return .rst_recv;
            }
            if ((flags & (flag_syn | flag_ack)) != (flag_syn | flag_ack)) {
                dropped_malformed += 1; // not a SYN-ACK
                return .none;
            }
            if (ack != isn +% 1) {
                dropped_malformed += 1; // it does not acknowledge our SYN
                return .none;
            }
            if (payload.len != 0) {
                dropped_malformed += 1; // a SYN-ACK carries no payload
                return .none;
            }
            srv_isn = seq;
            rcv_nxt = srv_isn +% 1;
            state = .established;
            clear_pending(); // the SYN-ACK acknowledges our SYN — the timer stops
            // The handshake ACK (seq = our ISN+1, ack = the server's
            // ISN+1 — the SND/RCV state after the SYN).
            build_msg(isn +% 1, rcv_nxt, flag_ack, &.{});
            ack_pending = true;
            synack_recv += 1;
            return .synack_recv;
        },
        .established => {
            if ((flags & flag_rst) != 0) {
                rst_recv += 1;
                clear_pending(); // the connection died — the timer stops
                state = .closed; // the connection died — the report shows it
                return .rst_recv;
            }
            // M97e-F2 (#2101): the segment must be the NEXT one the
            // connection expects — `seq == rcv_nxt`. An out-of-sequence
            // segment (a blind inject, or a reordered/duplicated segment
            // the no-reassembly bound cannot place) never clears the
            // retransmission timer on its ACK field, is never FIN-ACKed,
            // and never lands in the ONE-slot RX buffer.
            if (seq != rcv_nxt) {
                dropped_malformed += 1;
                return .none;
            }
            // Card N11 (claim 5357): ANY accepted segment whose ACK
            // covers everything the client has sent acknowledges the
            // pending segment — the retransmission timer stops (the
            // honest check: an acknowledged segment is never
            // retransmitted).
            if (tx_pending and seq_ge(ack, snd_una)) clear_pending();
            if ((flags & flag_fin) != 0) {
                if ((flags & flag_ack) == 0 or payload.len != 0) {
                    dropped_malformed += 1; // a clean FIN+ACK close only (honest bound)
                    return .none;
                }
                // A server FIN+ACK (the close answer, or the server
                // closing first): count it, ACK it, and stay ESTABLISHED
                // — the caller's `net tcp close` completes the close.
                rcv_nxt = seq +% 1; // the FIN consumes one sequence number
                finack_recv += 1;
                peer_fin = true; // SH7: the peer asked to disconnect
                build_msg(snd_una, rcv_nxt, flag_ack, &.{});
                ack_pending = true;
                return .finack_recv;
            }
            if (payload.len != 0) {
                if (rx_pending) {
                    dropped_malformed += 1; // the ONE-slot RX buffer is full (net tcp recv first)
                    return .none;
                }
                @memcpy(rx_payload[0..payload.len], payload);
                rx_len = payload.len;
                rx_pending = true;
                rcv_nxt = seq +% @as(u32, @intCast(payload.len));
                data_recv += 1;
                build_msg(snd_una, rcv_nxt, flag_ack, &.{});
                ack_pending = true;
                return .data_recv;
            }
            // A pure ACK: accepted, ignored (no retransmission machinery).
            return .none;
        },
        .fin_sent => {
            if ((flags & flag_rst) != 0) {
                rst_recv += 1;
                clear_pending();
                state = .closed;
                return .rst_recv;
            }
            if ((flags & (flag_fin | flag_ack)) != (flag_fin | flag_ack)) {
                dropped_malformed += 1; // not the FIN-ACK we are waiting for
                return .none;
            }
            if (payload.len != 0) {
                dropped_malformed += 1;
                return .none;
            }
            if (seq != rcv_nxt) {
                dropped_malformed += 1; // M97e-F2: the FIN-ACK is in-sequence too
                return .none;
            }
            rcv_nxt = seq +% 1; // the FIN consumes one sequence number
            finack_recv += 1;
            clear_pending(); // the FIN-ACK acknowledges our FIN — the timer stops
            state = .closed;
            // The final ACK (seq = snd_una — after our FIN — ack =
            // rcv_nxt — after the server's FIN).
            build_msg(snd_una, rcv_nxt, flag_ack, &.{});
            ack_pending = true;
            return .finack_recv;
        },
        .closed => {
            dropped_malformed += 1; // the connection is done
            return .none;
        },
    }
}
