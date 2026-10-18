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
//! retransmission (card N11, claim 5357; M99h #2186 adaptive RTO per
//! RFC 6298 — a SYN/data/FIN with no ACK is retransmitted when the
//! per-connection `rto_current` expires, at most `retx_max` = 10 times,
//! then the connection ABORTS honestly — counted `retx_aborted`; bare
//! ACKs are NEVER retransmitted; the 30 s connect timeout is enforced
//! INDEPENDENTLY of the adaptive RTO — its worst case stays inside
//! (retx_max + 1) x `rto_ceiling_ticks` = 33 s > 30 s, so the N10
//! refusal remains byte-exact; every retransmission is byte-identical —
//! the pending segment copy — and counted `retransmitted`; an ACK
//! covering everything the client sent clears the pending state, so an
//! acknowledged segment is never retransmitted); ONE bounded connect
//! timeout (30 s of guest ticks — the card-N9 timer pattern — a SYN
//! with no SYN-ACK refuses honestly, counted `timed_out`); TCP options
//! are PARSED and SKIPPED (M99h #2186 — NOPs and unknown kinds are
//! walked, a malformed option length fails closed counted
//! `dropped_options`, the peer's MSS option is honored as an outbound
//! clamp; we send no window-scale/SACK/timestamp options, so per RFC
//! 7323 a peer may not use them back — no renegotiation needed); a
//! BOUNDED out-of-order RX queue (M99h — the in-order stream head is
//! `rx_payload[0..rx_len]`, segments ahead of `rcv_nxt` but inside the
//! advertised window are held in `rx_ooo` slots and spliced in order;
//! overflow is counted `rx_overflow`, never corrupt); the window field
//! advertises the queue's REAL free space (the SYN keeps the pinned
//! 4096, which is the honest free space of an empty queue); no
//! segmentation beyond `payload_max`/peer-MSS (truncated honestly on
//! TX); NO TCP loopback (the client connects OUTWARD only — an own-IP
//! connect is refused `.no_peer` like an unresolved peer); no server
//! surface, no port listening, no urgent data, no congestion control
//! (the OS does not generate the bulk traffic that would need it), no
//! keepalive. The close is client-driven (FIN -> FIN-ACK -> final ACK);
//! a clean server FIN+ACK in ESTABLISHED is ACKed and counted
//! (`finack_recv`), and the caller's `net tcp close` then completes
//! the close; an over-cap SYN (a second peer knocking while the ONE
//! connection is taken, in any non-listen state) is refused HONESTLY
//! with RST+ACK (M84f, #1836) — never silently dropped; anything else
//! is counted `dropped_malformed`. The fixed source port is 8000 (the
//! UDP layer's 7000 analog — deterministic, gate-assertable).

const std = @import("std");
pub const arp = @import("arp.zig"); // N3: our static IP (`arp.own_ip` — the ONE copy)
const csprng = @import("csprng.zig"); // the kernel CSPRNG — the server's ISN draw (M97e-F2 rider)
const ipv6 = @import("ipv6.zig"); // M117c (#2475): v6 Addr + the pseudo-header checksum + the frame prefix

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
/// M117c (#2475): the largest v6 frame — Ethernet + the 40-byte fixed
/// header + the same bounded segment (a full payload still fits the
/// 1280-byte v6 minimum MTU envelope).
pub const frame6_max: usize = eth_hdr_len + 40 + segment_max; // 1534
/// The smallest full frame: Ethernet + IPv4 + the 20-byte header.
pub const frame_min: usize = eth_hdr_len + ipv4_hdr_len + tcp_hdr_len; // 54
/// The receive window bound in bytes (M99h #2186): the singleton's RX
/// capacity AND the SYN's advertised bound — 4096 free bytes is honest
/// only while the queue is empty, so data-bearing segments overwrite
/// the field with `free_window()`. No window-scale option is sent, so
/// the peer may not scale its window back (RFC 7323 §2.2).
pub const window: u16 = 4096;
/// The largest legal TCP option area (data offset 15 x 4 - 20).
pub const options_max: usize = 40;
/// Our advertised maximum segment size — the Ethernet MTU's TCP payload
/// bound, sent as a kind-2 option in SYN segments we originate (M99h).
pub const our_mss: u16 = 1460;
/// The pre-formatted MSS option: kind 2, length 4, value `our_mss`.
pub const mss_option: [4]u8 = .{ 2, 4, our_mss >> 8, our_mss & 0xff };
// Option kinds the parser acts on (RFC 793 §3.1 / RFC 9293 §3.2). Every
// other kind is skipped by its declared length — never interpreted.
pub const opt_eol: u8 = 0;
pub const opt_nop: u8 = 1;
pub const opt_mss: u8 = 2;
pub const mss_len: u8 = 4;
/// The peer's advertised MSS (0 = none — the synthetic fleet's shape;
/// outbound payloads keep the `payload_max` bound, the fleet's
/// established contract. A real peer's advertised MSS clamps outbound
/// payloads per RFC 9293 §3.7.1 — see `send_limit`).
pub var peer_mss: u16 = 0;
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
/// The INITIAL retransmission timeout in guest ticks before any RTT
/// sample exists (card N11's 3 s value, kept — RFC 6298 §2.1 allows
/// the initial RTO as long as it is >= 1 s). M99h (#2186): once a clean
/// RTT sample lands, `rto_current` tracks SRTT + 4 x RTTVAR instead.
pub const rto_ticks: u64 = 3;
/// M99h (#2186): the adaptive-RTO floor in ticks — the 1 Hz guest
/// clock's honest minimum (sub-second floors like RFC 6298's suggested
/// 200 ms are not representable; the socket table's nanosecond clock
/// enforces `rto_floor_ns` instead).
pub const rto_floor_ticks: u64 = 1;
/// M99h (#2186): the adaptive-RTO ceiling in ticks — deliberately small,
/// not RFC 6298's 60 s. The guest's bounded black-hole budget requires
/// `retx_max` retransmissions to abort inside a tight, testable window:
/// (retx_max + 1) x 3 = 33 s > the 30 s connect timeout keeps the N10
/// refusal byte-exact, and a black-holed established connection dies in
/// ~33 s instead of minutes. Exponential backoff (RTO x 2 per
/// retransmission) saturates here quickly — that is the point.
pub const rto_ceiling_ticks: u64 = 3;
/// The retransmission bound (card N11): a segment is retransmitted at
/// most `retx_max` times (11 transmissions total), then the connection
/// ABORTS honestly (`retx_aborted`), releasing the state. M99h restates
/// the invariant: with an adaptive RTO the abort is no longer a
/// constant — its WORST case is (retx_max + 1) x rto_ceiling_ticks =
/// 33 s > 30 s, and the connect timeout is enforced on its own clock,
/// so the SYN's outer bound is unchanged.
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
/// M99h (#2186, card h1): a segment whose data offset was parseable but
/// whose option list was malformed (a length of 0, 1, or past the end
/// of the option area) — refused closed, counted separately from
/// `dropped_malformed`.
pub var dropped_options: u64 = 0;
/// M99h (#2186, card h2): the bounded out-of-order queue's counters —
/// a segment held for reassembly (`ooo_held`), bytes/segments that
/// could not be stored inside the window or the slot bound
/// (`rx_overflow`), and fully-duplicate segments re-ACKed (`rx_dup`).
pub var ooo_held: u64 = 0;
pub var rx_overflow: u64 = 0;
pub var rx_dup: u64 = 0;

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
/// The bounded in-order RX buffer (M99h #2186, card h2): it holds the
/// undelivered stream PREFIX only — `rx_payload[0..rx_len]` is always
/// the contiguous bytes [rcv_nxt - rx_len, rcv_nxt) — never out-of-order
/// data (those live in `rx_ooo` slots). Capacity == `window`, the SYN's
/// advertised bound. `rx_len`/`rx_pending`/`take_rx` keep their exact
/// M84-era meaning for the seam's direct readers (syscall partial
/// reads, the monitor's `net tcp recv`, terminal test fixtures).
pub var rx_payload: [@as(usize, window)]u8 = undefined;
pub var rx_len: usize = 0;
pub var rx_pending: bool = false;
/// M99h (#2186): the bounded out-of-order queue — `rx_ooo_max` slots,
/// each one bounded segment. A slot holds bytes ahead of `rcv_nxt`
/// inside the advertised window until the gap before them fills; the
/// stream then splices them into `rx_payload` in order. `len == 0`
/// marks a free slot (a held segment always carries bytes).
pub const rx_ooo_max: usize = 8;
pub const OooSlot = struct {
    seq: u32 = 0,
    len: u16 = 0,
    data: [payload_max]u8 = undefined,
};
pub var rx_ooo: [rx_ooo_max]OooSlot = @splat(.{});
/// M99h (#2186): a FIN received ahead of the stream — the sequence
/// number it consumes — held until the bytes before it arrive.
pub var fin_ooo: u32 = 0;
pub var fin_ooo_set: bool = false;
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
/// M99h (#2186, card h3): the RFC 6298 RTT estimators on the 1 Hz guest
/// tick clock. `rtt_valid` is false until the first clean sample (a
/// sample is an ACK that covers a pending segment which was NEVER
/// retransmitted — Karn's algorithm, RFC 6298 §5.2). `rto_current` is
/// the live timeout: the estimator value after a sample, doubled per
/// retransmission (§5.5 backoff), clamped [rto_floor_ticks,
/// rto_ceiling_ticks].
pub var srtt_ticks: u64 = 0;
pub var rttvar_ticks: u64 = 0;
pub var rtt_valid: bool = false;
pub var rto_current: u64 = rto_ticks;

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
    const total = buildSeg(buf, src_port, dst_port, seq, ack, flags, &.{}, payload);
    const c = checksum_tcp(src_ip, dst_ip, buf[0..total]);
    buf[16] = @truncate(c >> 8);
    buf[17] = @truncate(c);
    return total;
}

/// M99h (#2186, card h1): `build_segment` with a bounded option area —
/// `opts` is the pre-formed option list (0..40 bytes, padded to a
/// 4-byte boundary with EOLs by the caller; the data offset records the
/// padded length). Used by `socket_core` to put MSS 1460 on the
/// active-open SYN; the legacy connection's SYN stays bare (its wire
/// bytes are pinned by the live fleet gates).
pub fn build_segment_opts(buf: []u8, src_ip: [4]u8, dst_ip: [4]u8, src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, opts: []const u8, payload: []const u8) usize {
    const total = buildSeg(buf, src_port, dst_port, seq, ack, flags, opts, payload);
    const c = checksum_tcp(src_ip, dst_ip, buf[0..total]);
    buf[16] = @truncate(c >> 8);
    buf[17] = @truncate(c);
    return total;
}

/// The checksum-free segment body shared by the v4 and v6 builders
/// (M117c — the segment bytes are family-independent; only the
/// pseudo-header differs, filled by the caller's checksum pass). The
/// checksum field is left zeroed by the memset.
fn buildSeg(buf: []u8, src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, opts: []const u8, payload: []const u8) usize {
    const plen = @min(payload.len, payload_max);
    const opad = (opts.len + 3) & ~@as(usize, 3);
    const total = tcp_hdr_len + opad + plen;
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
    buf[12] = @truncate(@as(u8, @intCast(5 + opad / 4)) << 4); // data offset covers the options
    buf[13] = flags;
    buf[14] = @truncate(window >> 8);
    buf[15] = @truncate(window);
    // Checksum field at 16..18 — zeroed by the memset during the computation.
    // Urgent pointer at 18..20 = 0 (no urgent data).
    @memcpy(buf[20 .. 20 + opts.len], opts);
    @memcpy(buf[20 + opad .. total], payload[0..plen]);
    return total;
}

// ---------------------------------------------------------------------------
// M117c (#2475, ADR 0057 D8): TCP over IPv6 — the v6 pseudo-header
// checksum + the family-tagged builders. The v4 paths above are
// untouched; the segment bytes themselves are family-independent.
// ---------------------------------------------------------------------------

/// The TCP checksum over the v6 pseudo-header (16-byte src + dst, the
/// 32-bit upper-layer length, next-header 6) — the
/// `ipv6.icmp6_checksum` machinery parameterized to TCP.
pub fn checksum_tcp6(src: *const ipv6.Addr, dst: *const ipv6.Addr, segment: []const u8) u16 {
    return ipv6.icmp6_checksum(src, dst, segment, ipv6.nexthdr_tcp);
}

/// The v6 half of `build_segment_opts` — identical segment bytes, the
/// v6 pseudo-header checksum.
pub fn build_segment_opts6(buf: []u8, src6: *const ipv6.Addr, dst6: *const ipv6.Addr, src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, opts: []const u8, payload: []const u8) usize {
    const total = buildSeg(buf, src_port, dst_port, seq, ack, flags, opts, payload);
    const c = checksum_tcp6(src6, dst6, buf[0..total]);
    buf[16] = @truncate(c >> 8);
    buf[17] = @truncate(c);
    return total;
}

/// The v6 half of `build_segment` (no option area).
pub fn build_segment6(buf: []u8, src6: *const ipv6.Addr, dst6: *const ipv6.Addr, src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, payload: []const u8) usize {
    return build_segment_opts6(buf, src6, dst6, src_port, dst_port, seq, ack, flags, &.{}, payload);
}

/// Build the FULL Ethernet + IPv6 + TCP frame into `buf` (must hold >=
/// `eth_hdr_len + ipv6.hdr_len + segment.len`): dst MAC (the NEXT HOP —
/// the caller resolved it), src MAC, ethertype 0x86dd, the 40-byte
/// fixed v6 header (version 6, next-header 6, hop 64), then the
/// pre-built segment. Returns the frame length (74 + the segment
/// payload).
pub fn build_frame6(buf: []u8, own_mac: *const [6]u8, src6: *const ipv6.Addr, dst_mac: [6]u8, dst6: *const ipv6.Addr, segment: []const u8) usize {
    const frame_len = eth_hdr_len + ipv6.ipv6_hdr_len + segment.len;
    ipv6.build_hdr(buf, &dst_mac, own_mac, src6, dst6, ipv6.nexthdr_tcp, ipv6.hop_default, @intCast(segment.len));
    @memcpy(buf[eth_hdr_len + ipv6.ipv6_hdr_len .. frame_len], segment);
    return frame_len;
}

/// M99h (#2186, card h1): the bounded option-list scan. Walks the
/// declared option area (segment offset `off`, `opt_len` bytes —
/// already bounds-checked against the segment) skipping EOL and NOPs,
/// refusing a malformed length byte (0, 1, or one that overruns the
/// area) with `error.MalformedOptions`; unknown kinds are skipped by
/// their declared length; an MSS option (`mss_len` bytes — anything
/// else is malformed) records the peer's MSS. Kind/length bytes are
/// only ever read inside the area — a short option can never walk the
/// walk past the segment end.
pub fn scanOptions(seg: []const u8, off: usize, opt_len: usize, mss_out: *u16) error{MalformedOptions}!void {
    var i: usize = off;
    const end = off + opt_len;
    while (i < end) {
        const kind = seg[i];
        if (kind == opt_eol) return; // padding — the rest is zeroed
        if (kind == opt_nop) {
            i += 1;
            continue;
        }
        if (i + 1 >= end) return error.MalformedOptions;
        const olen: usize = seg[i + 1];
        if (olen < 2 or i + olen > end) return error.MalformedOptions;
        if (kind == opt_mss) {
            if (olen != mss_len) return error.MalformedOptions;
            mss_out.* = (@as(u16, seg[i + 2]) << 8) | seg[i + 3];
        }
        i += olen;
    }
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

/// M99f (#2184, ADR 0007): the promoted socket table's RX claim —
/// registered by `socket_native` before any table socket exists.
/// `handle_rx` offers EVERY TCP frame to it first; true means the frame
/// named a table-owned local port and the table consumed it (its own
/// parse and counters — never re-counted here). Frames it declines fall
/// through to this singleton unchanged. The seam keeps the import-free
/// delegate shape (the `Transmit` callback precedent): tcp.zig never
/// imports socket_native.
pub var table_rx: ?*const fn ([]const u8) bool = null;

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
    rx_ooo = @splat(.{});
    fin_ooo = 0;
    fin_ooo_set = false;
    peer_mss = 0;
    peer_fin = false;
    allow_ip = .{ 0, 0, 0, 0 };
    allow_ip_set = false;
    accept_aborted = false;
    accept_ticks = 0;
    tx_pending = false;
    retx_len = 0;
    tx_ticks = 0;
    retx_count = 0;
    srtt_ticks = 0;
    rttvar_ticks = 0;
    rtt_valid = false;
    rto_current = rto_ticks;
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
    dropped_options = 0;
    ooo_held = 0;
    rx_overflow = 0;
    rx_dup = 0;
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
    rx_ooo = @splat(.{});
    fin_ooo = 0;
    fin_ooo_set = false;
    peer_mss = 0;
    peer_fin = false;
    srtt_ticks = 0;
    rttvar_ticks = 0;
    rtt_valid = false;
    rto_current = rto_ticks;
    clear_pending();
}

/// M99h (#2186, card h2): the honest advertised window — the receive
/// queue's real free space: `window` minus every buffered byte (the
/// in-order prefix plus the held out-of-order slots). An empty queue
/// advertises the full 4096 — the SYN's pinned value — so the pin and
/// the honesty agree.
fn free_window() u16 {
    var held: usize = rx_len;
    for (rx_ooo) |s| held += s.len;
    return @intCast(if (held >= window) 0 else window - held);
}

/// Build the next outbound segment into `msg` for THE connection (the
/// fixed src port + the stored peer). M99h: the window field carries
/// the queue's real free space — rewritten after the fixed-window build
/// and re-checksummed.
fn build_msg(seq: u32, ack: u32, flags: u8, payload: []const u8) void {
    const local_port = if (is_server) listen_port else default_src_port;
    msg_len = build_segment(&msg, arp.own_ip, peer_ip, local_port, peer_port, seq, ack, flags, payload);
    std.mem.writeInt(u16, msg[14..16], free_window(), .big);
    msg[16] = 0;
    msg[17] = 0;
    const c = checksum_tcp(arp.own_ip, peer_ip, msg[0..msg_len]);
    std.mem.writeInt(u16, msg[16..18], c, .big);
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
    rx_ooo = @splat(.{});
    fin_ooo = 0;
    fin_ooo_set = false;
    peer_mss = 0;
    srtt_ticks = 0;
    rttvar_ticks = 0;
    rtt_valid = false;
    rto_current = rto_ticks;
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
    rx_ooo = @splat(.{});
    fin_ooo = 0;
    fin_ooo_set = false;
    peer_mss = 0;
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
pub fn seq_ge(a: u32, b: u32) bool {
    return (a -% b) < 0x8000_0000;
}

/// M99h (#2186, card h3): the RFC 6298 RTT update on the guest's tick
/// clock. Called at every ACK-accept site BEFORE `clear_pending` — a
/// sample exists only when the pending segment was never retransmitted
/// (Karn's algorithm, §5.2). First sample: SRTT = R, RTTVAR = R/2;
/// later samples: the §2.3 alpha = 1/8 / beta = 1/4 filters in integer
/// ticks. `rto_current` = SRTT + max(G, 4 x RTTVAR) with G = 1 tick,
/// clamped [rto_floor_ticks, rto_ceiling_ticks]. A retransmitted
/// segment's ACK contributes nothing and keeps the backed-off RTO.
fn note_rtt_sample() void {
    if (!tx_pending or retx_count != 0) return;
    const r = now_ticks -| tx_ticks;
    if (!rtt_valid) {
        srtt_ticks = r;
        rttvar_ticks = r / 2;
        rtt_valid = true;
    } else {
        const d = if (r > srtt_ticks) r - srtt_ticks else srtt_ticks - r;
        rttvar_ticks = (3 * rttvar_ticks + d) / 4;
        srtt_ticks = (7 * srtt_ticks + r) / 8;
    }
    rto_current = @min(rto_ceiling_ticks, @max(rto_floor_ticks, srtt_ticks + @max(rto_floor_ticks, 4 * rttvar_ticks)));
}

/// Card N11 (claim 5357): the bounded retransmission poll — the shell
/// idle loop calls it after the RX drain (an ACK processed by the drain
/// cleared the pending state — a retransmission NEVER follows an
/// acknowledged segment). One step per poll: if the pending segment's
/// RTO (the adaptive `rto_current`, M99h) has expired and the bound is
/// not exhausted, rebuild `msg` from the pending copy (byte-identical —
/// the same seq, flags, payload, checksum), count it, and double the
/// RTO toward the ceiling (RFC 6298 §5.5 backoff); if the bound IS
/// exhausted (10 retransmissions), release the connection honestly
/// (`release_conn` — no RST, no TX) and count the abort. Bare ACKs are
/// never pending.
pub fn poll_rto() RtoEvent {
    if (!tx_pending) return .none;
    if (state == .idle or state == .closed) {
        clear_pending(); // the connection died another way — stop the timer
        return .none;
    }
    if (now_ticks -| tx_ticks < rto_current) return .none;
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
    rto_current = @min(rto_ceiling_ticks, rto_current *| 2); // §5.5 backoff
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
/// honestly at `send_limit`.
/// M99h (#2186, card h1): the honest send bound — the smaller of the
/// local buffer and the peer's advertised MSS. A peer that sent no MSS
/// (the synthetic fleet's option-free shape) keeps the `payload_max`
/// bound — the fleet's established contract — rather than the RFC 793
/// 536-byte default, which would silently truncate existing consumers.
pub fn send_limit() usize {
    return @min(payload_max, if (peer_mss == 0) payload_max else @as(usize, peer_mss));
}

pub fn build_data_msg(payload: []const u8) void {
    build_msg(snd_una, rcv_nxt, flag_ack, payload[0..@min(payload.len, send_limit())]);
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

/// M99h (#2186, card h2): hold one out-of-order segment in a bounded
/// slot. The caller has already trimmed the bytes to the window, so the
/// only bounds left are the slot count (`rx_ooo_max`) and a same-seq
/// duplicate (counted, not double-stored). Returns false when the queue
/// is full.
fn ooo_insert(seq: u32, data: []const u8) bool {
    for (rx_ooo) |s| {
        if (s.len != 0 and s.seq == seq) {
            rx_dup += 1;
            return true; // held already — the stream is unchanged
        }
    }
    for (&rx_ooo) |*s| {
        if (s.len == 0) {
            s.seq = seq;
            s.len = @intCast(data.len);
            @memcpy(s.data[0..data.len], data);
            ooo_held += 1;
            return true;
        }
    }
    return false;
}

/// M99h (#2186, card h2): splice every queued slot now adjacent to
/// `rcv_nxt` into the in-order prefix, oldest-first. A slot's held
/// bytes were already counted against the window at insert, so the
/// splice always fits — `rx_len + sum(slot.len) <= window` is the
/// queue's invariant. Slots entirely below `rcv_nxt` (covered by a
/// later segment) are freed, never copied — the stream cannot go
/// backwards. A queued FIN (`fin_ooo_set`) applies the moment its
/// sequence number becomes contiguous. Returns true when a FIN applied.
fn drain_ooo() bool {
    var fin_applied = false;
    var progress = true;
    while (progress) {
        progress = false;
        for (&rx_ooo) |*s| {
            if (s.len == 0) continue;
            const skip = rcv_nxt -% s.seq;
            if (skip >= s.len) {
                if (!seq_ge(rcv_nxt, s.seq +% s.len)) continue; // entirely ahead — a gap remains
                s.len = 0; // fully covered — freed, never delivered
                progress = true;
                continue;
            }
            const rem: usize = s.len - skip;
            @memcpy(rx_payload[rx_len .. rx_len + rem], s.data[skip..s.len]);
            rx_len += rem;
            rx_pending = true;
            rcv_nxt +%= @intCast(rem);
            s.len = 0;
            progress = true;
        }
    }
    if (fin_ooo_set and fin_ooo == rcv_nxt) {
        fin_ooo_set = false;
        rcv_nxt +%= 1; // the FIN consumes one sequence number
        finack_recv += 1;
        peer_fin = true;
        fin_applied = true;
    }
    return fin_applied;
}

/// M99h (#2186, card h2): the established-state receive path — shared
/// by `.established` and the `.syn_received` handshake ACK that carries
/// payload. RFC 793's acceptability check on the bounded window: a pure
/// ACK must sit exactly at `rcv_nxt`; a data segment must overlap
/// `[rcv_nxt, rcv_nxt + free_window())`; a FIN may sit at or ahead of
/// `rcv_nxt` inside the window (it queues until contiguous). Fully-old
/// bytes are duplicates (`rx_dup`, re-ACKed — the peer resyncs); bytes
/// beyond the window are refused (`dropped_malformed`); bytes that fit
/// only partially are trimmed honestly (`rx_overflow`). An acceptable
/// segment's ACK field is the ONLY thing that clears the retransmission
/// timer — forged and out-of-window segments still never reach it
/// (M97e-F2's property, kept).
fn established_rx(seq: u32, ack: u32, flags: u8, payload: []const u8) Event {
    const fwin: u32 = free_window();
    const plen: u32 = @intCast(payload.len);
    const has_fin = (flags & flag_fin) != 0;
    var d_seq = seq;
    var d_len: usize = payload.len;
    var off: usize = 0;

    if (plen == 0) {
        if (seq != rcv_nxt) {
            if (has_fin and (seq -% rcv_nxt) <= fwin and !seq_ge(rcv_nxt, seq)) {
                fin_ooo = seq; // a FIN ahead of the stream — queue it
                fin_ooo_set = true;
                build_msg(snd_una, rcv_nxt, flag_ack, &.{});
                ack_pending = true;
                return .data_recv;
            }
            dropped_malformed += 1; // a bare segment not at rcv_nxt
            return .none;
        }
    } else {
        if (seq_ge(rcv_nxt, seq)) {
            const skip = rcv_nxt -% seq;
            if (skip >= plen) {
                // Every byte is old news — a retransmit of consumed data.
                rx_dup += 1;
                build_msg(snd_una, rcv_nxt, flag_ack, &.{});
                ack_pending = true;
                return .data_recv;
            }
            off = @intCast(skip); // trim the consumed head
            d_seq = rcv_nxt;
            d_len = payload.len - off;
        } else if (seq != rcv_nxt and (seq -% rcv_nxt) >= fwin) {
            dropped_malformed += 1; // beyond the advertised window — never held
            return .none;
        }
    }

    // The ACK field of an acceptable segment — Karn's rule keeps a
    // retransmitted segment's ACK out of the estimator.
    if (tx_pending and seq_ge(ack, snd_una)) {
        note_rtt_sample();
        clear_pending();
    }

    var result: Event = .none;
    var need_ack = false;
    if (d_len != 0) {
        // The tail cannot exceed the window past the segment's own
        // offset — `d_seq - rcv_nxt` bytes of the free space are
        // upstream of it (0 for an in-order segment).
        const room: usize = @intCast(fwin -% (d_seq -% rcv_nxt));
        if (d_len > room) {
            rx_overflow += d_len - room;
            d_len = room;
        }
        if (d_len != 0) {
            if (d_seq == rcv_nxt) {
                @memcpy(rx_payload[rx_len .. rx_len + d_len], payload[off .. off + d_len]);
                rx_len += d_len;
                rx_pending = true;
                rcv_nxt +%= @intCast(d_len);
                data_recv += 1;
                result = .data_recv;
                if (drain_ooo()) result = .finack_recv;
            } else {
                if (!ooo_insert(d_seq, payload[off .. off + d_len])) {
                    rx_overflow += d_len; // the bounded queue is full — dropped, never misordered
                }
                result = .data_recv; // the ACK still goes out — it resyncs the peer
            }
        }
        need_ack = true;
    }
    if (has_fin) {
        const fin_seq = seq +% plen;
        if (fin_seq == rcv_nxt) {
            if ((flags & flag_ack) == 0) {
                dropped_malformed += 1; // a clean FIN+ACK close only (honest bound)
                return .none;
            }
            rcv_nxt +%= 1; // the FIN consumes one sequence number
            finack_recv += 1;
            peer_fin = true;
            result = .finack_recv;
        } else {
            fin_ooo = fin_seq; // ahead of the stream — applies when contiguous
            fin_ooo_set = true;
            if (result == .none) result = .data_recv;
        }
        need_ack = true;
    }
    if (need_ack) {
        build_msg(snd_una, rcv_nxt, flag_ack, &.{});
        ack_pending = true;
    }
    return result;
}

/// Process one received TCP segment (the frame's IPv4 header was ALREADY
/// validated by ipv4.zig — checksum, fragment, dst address). Runs in the
/// RX drain context; builds the client's answer into `msg` and sets
/// `ack_pending` — the transmission is MONITOR-driven on the next `net
/// tcp` (deterministic, never a transmit from the drain context).
pub fn handle_rx(frame: []const u8) Event {
    // M99f (#2184): the ONE socket table claims its ports first — listeners
    // beyond slot 0 and every connection reach the singleton only through
    // this seam (ipv4's fast path keeps feeding slot 0 directly).
    if (table_rx) |claim| {
        if (claim(frame)) return .none;
    }
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
    // M99h (#2186, card h1): the data offset declares the option area —
    // [tcp_hdr_len, doff x 4) inside the segment. Offset < 5 is
    // malformed; an offset beyond the segment is malformed; a valid
    // offset's option list is scanned (NOPs skipped, unknown kinds
    // skipped by length, MSS recorded) — a malformed option list drops
    // the segment in its OWN counter, distinct from a malformed header.
    const doff: usize = segment[12] >> 4;
    if (doff < 5 or doff * 4 > segment.len) {
        dropped_malformed += 1;
        return .none;
    }
    var seg_mss: u16 = 0;
    scanOptions(segment, tcp_hdr_len, doff * 4 - tcp_hdr_len, &seg_mss) catch {
        dropped_options += 1;
        return .none;
    };
    const seq = be32(segment[4..8]);
    const ack = be32(segment[8..12]);
    const flags = segment[13];
    const payload = segment[doff * 4 ..];
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
                peer_mss = seg_mss; // M99h: the requester's MSS, if it sent one
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
                    note_rtt_sample(); // the ACK covers our SYN-ACK
                    clear_pending();
                    state = .established;
                    if (payload.len != 0 or (flags & flag_fin) != 0) {
                        return established_rx(seq, ack, flags, payload);
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
            peer_mss = seg_mss; // M99h: the peer's advertised MSS, if it sent one
            state = .established;
            note_rtt_sample(); // the SYN-ACK covers our SYN — the first RTT sample
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
            // M99h (#2186, card h2): the in-sequence bound became the
            // bounded receive window — `established_rx` accepts segments
            // overlapping [rcv_nxt, rcv_nxt + free_window()), appends
            // in-order bytes to the contiguous prefix, queues future
            // bytes in the bounded `rx_ooo` slots, counts duplicates and
            // overflow, and applies a queued FIN once its sequence
            // number is contiguous. M97e-F2's property is kept: only an
            // acceptable segment's ACK field may clear the
            // retransmission timer — forged and out-of-window segments
            // never reach it.
            return established_rx(seq, ack, flags, payload);
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
            note_rtt_sample(); // the FIN-ACK covers our FIN — the last sample
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
