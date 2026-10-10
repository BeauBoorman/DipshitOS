//! DHCP client (RFC 2131/2132) — milestone five, card N8 (claim 0351).
//! PURE protocol logic (message build/parse, the four-message INIT
//! handshake, the bounded client state machine, the lease record) +
//! host tests, the arp.zig/udp.zig fat.zig pattern; `virtio_net.zig`
//! wires it to the broadcast-dst send seam (card N8's ONE N5-layer
//! change: a DHCP frame goes out with dst MAC ff:ff:ff:ff:ff:ff and dst
//! IP 255.255.255.255 DIRECTLY — no ARP lookup, src IP 0.0.0.0) and
//! `udp.zig`'s `handle_rx` dispatches port-68 datagrams to
//! `dhcp.handle_rx` (the client owns port 68 by construction — it is
//! NOT a `net udp listen` entry, invisible to `net udp recv`).
//!
//! Honest bounds (documented, never assumed away): no renewal/rebind/
//! lease expiry (the lease time is RECORDED, not enforced); no
//! hostname/DNS options stored; no DHCPv6; no relay/giaddr; ONE client
//! state machine — a fixed BSS struct + one fixed 256-byte message
//! buffer, no heap. The client's UDP packets use src 68 -> dst 67 with
//! a BROADCAST dst. The message is NOT padded to the RFC 2131 300-octet
//! minimum — the fixed 256-byte buffer is the honest bound (the
//! DISCOVER is 244 bytes, the REQUEST 256); a server that rejects
//! sub-300 messages would be a claim-time observation, never assumed.

const std = @import("std");
pub const arp = @import("arp.zig"); // N3: our static IP (`arp.own_ip` — THE one copy, overwritten on BOUND)

// ---------------------------------------------------------------------------
// Wire constants (RFC 2131/2132)
// ---------------------------------------------------------------------------

/// The client's UDP port (the server answers 67 -> 68).
pub const client_port: u16 = 68;
/// The server's UDP port (the client sends 68 -> 67).
pub const server_port: u16 = 67;
/// The DHCP magic cookie (bytes 236..240 of the message).
pub const magic_cookie: [4]u8 = .{ 0x63, 0x82, 0x53, 0x63 };
/// The fixed BOOTP header: op(1) htype(1) hlen(1) hops(1) xid(4) secs(2)
/// flags(2) ciaddr(4) yiaddr(4) siaddr(4) giaddr(4) chaddr(16) sname(64)
/// file(128) = 236 bytes; the magic cookie follows at 236.
pub const bootp_hdr_len: usize = 236;
/// The fixed message buffer bound (the prompt's ONE fixed 256-byte
/// packet buffer — no heap). DISCOVER = 244 B, REQUEST = 256 B.
pub const msg_max: usize = 256;
/// The full-frame bound: Ethernet(14) + IPv4(20) + UDP(8) + msg_max.
pub const frame_max: usize = 14 + 20 + 8 + msg_max; // 298
/// Bounded DISCOVER retries before an honest refuse.
pub const max_attempts: usize = 3;

// Option codes (RFC 2132).
pub const opt_subnet_mask: u8 = 1;
pub const opt_router: u8 = 3;
pub const opt_msg_type: u8 = 53;
pub const opt_requested_ip: u8 = 50;
pub const opt_lease_time: u8 = 51;
pub const opt_server_id: u8 = 54;
pub const opt_end: u8 = 255;

// Message types (RFC 2131 §3).
pub const msg_type_discover: u8 = 1;
pub const msg_type_offer: u8 = 2;
pub const msg_type_request: u8 = 3;
pub const msg_type_ack: u8 = 5;
pub const msg_type_nack: u8 = 6;

// ---------------------------------------------------------------------------
// Counters (the `net` report's `dhcp=` line) — every step counted.
// ---------------------------------------------------------------------------

pub var discover_sent: u64 = 0;
pub var offer_recv: u64 = 0;
pub var request_sent: u64 = 0;
pub var ack_recv: u64 = 0;
pub var nack_recv: u64 = 0;
pub var timed_out: u64 = 0; // the bounded-retry refuse (max_attempts exhausted)
pub var dropped_malformed: u64 = 0; // an unparseable / unexpected reply
// Card N9 (claim 9489): the lease lifecycle (RFC 2131 §4.4.5).
pub var renew_sent: u64 = 0; // RENEWING unicast REQUESTs transmitted
pub var rebind_sent: u64 = 0; // REBINDING broadcast REQUESTs transmitted
pub var renewed: u64 = 0; // ACKs accepted in RENEWING/REBINDING (the lease restarted)
pub var expired: u64 = 0; // lease expiries enforced (address released, back to INIT)

// ---------------------------------------------------------------------------
// State (pure BSS — ONE client state machine)
// ---------------------------------------------------------------------------

pub const State = enum {
    idle,
    selecting, // DISCOVER sent — waiting for an OFFER
    requesting, // OFFER accepted — the REQUEST is built; awaiting the ACK
    bound, // ACK received — the lease is live (arp.own_ip set)
    renewing, // T1 reached — the REQUEST is built (ciaddr = the lease); unicast to the server, awaiting the renewal ACK
    rebinding, // T2 reached — the REQUEST is built; broadcast, awaiting the renewal ACK
};

pub var state: State = .idle;
/// The current transaction id (echoed by every message of the handshake).
pub var xid: u32 = 0;
/// DISCOVER attempts made (the bounded-retry cap).
pub var attempts: usize = 0;
/// The next outbound message (the ONE fixed buffer): the DISCOVER after
/// `start`, the REQUEST after the OFFER is processed.
pub var msg: [msg_max]u8 = undefined;
pub var msg_len: usize = 0;
/// Whether the built REQUEST was already transmitted (a `net dhcp`
/// invocation in `requesting` with this set is "waiting for the ACK",
/// not a duplicate transmit — honest counters).
pub var request_transmitted: bool = false;
/// The SELECTING-stage offer (pending the REQUEST).
var offered_ip: [4]u8 = .{ 0, 0, 0, 0 };
var offered_server: [4]u8 = .{ 0, 0, 0, 0 };
/// The client's hardware address (captured at `start` — the chaddr every
/// message of the handshake carries; the RX dispatch needs no extra args).
pub var client_mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
/// The BOUND lease (zero = not offered by the server).
pub var lease_ip: [4]u8 = .{ 0, 0, 0, 0 };
pub var lease_mask: [4]u8 = .{ 0, 0, 0, 0 };
pub var lease_gw: [4]u8 = .{ 0, 0, 0, 0 };
pub var lease_server: [4]u8 = .{ 0, 0, 0, 0 };
pub var lease_time: u32 = 0;
// Card N9 (claim 9489): the lease timer. The caller (the shell idle
// loop + `net dhcp`) stamps `now_ticks` from the 1 Hz generic timer
// (`timer.ticks` — seconds) each poll; the ACK processing stamps
// `bound_ticks` from it, so the elapsed lease time is honest wall-clock
// seconds.
pub var now_ticks: u64 = 0;
pub var bound_ticks: u64 = 0;

/// The RX dispatch's outcome — the caller (the monitor) observes it via
/// `state`; the enum is the honest event for the host tests.
pub const Event = enum {
    none,
    request_ready, // an OFFER was accepted — the REQUEST is built in `msg`
    bound, // the ACK was accepted — the lease is live
    renewed, // a renewal ACK was accepted in RENEWING/REBINDING — the lease restarted
    nacked, // a NACK — the client falls back to idle
};

// ---------------------------------------------------------------------------
// Message build (byte-exact, RFC 2131 §4 — the fixtures pin the bytes)
// ---------------------------------------------------------------------------

/// Build a DHCP message into `buf` (must hold >= `msg_max`): the 236-byte
/// BOOTP header (op BOOTREQUEST, htype ethernet, hlen 6, the given xid,
/// the BROADCAST flag 0x8000 — the client asks the server to reply
/// broadcast so the N2 MAC filter admits the answer), our chaddr, the
/// magic cookie, then the options: 53 (message type), for a REQUEST also
/// 50 (the requested IP — the SELECTING-stage offer) + 54 (the server
/// id), and 255 (end). NO option-55 parameter-request list (the honest
/// 256-byte bound — the server's fixed lease provides mask/router/lease
/// unconditionally; a server that withholds them without a request is a
/// claim-time observation). Returns the message length (244 DISCOVER /
/// 256 REQUEST — both within the bound).
pub fn build_message(buf: []u8, chaddr: *const [6]u8, txn_id: u32, mtype: u8, requested_ip: ?[4]u8, server_id: ?[4]u8) usize {
    @memset(buf[0..msg_max], 0);
    buf[0] = 1; // op BOOTREQUEST
    buf[1] = 1; // htype ethernet
    buf[2] = 6; // hlen
    buf[3] = 0; // hops
    buf[4] = @truncate(txn_id >> 24);
    buf[5] = @truncate(txn_id >> 16);
    buf[6] = @truncate(txn_id >> 8);
    buf[7] = @truncate(txn_id);
    // secs (8..10) = 0; flags (10..12) = 0x8000 (broadcast).
    buf[10] = 0x80;
    buf[11] = 0x00;
    // ciaddr/yiaddr/siaddr/giaddr (12..28) = 0.
    @memcpy(buf[28..34], chaddr);
    // sname (44..108) + file (108..236) = 0 (the memset).
    @memcpy(buf[236..240], &magic_cookie);
    var o: usize = 240;
    buf[o] = opt_msg_type;
    buf[o + 1] = 1;
    buf[o + 2] = mtype;
    o += 3;
    if (mtype == msg_type_request) {
        if (requested_ip) |ip| {
            buf[o] = opt_requested_ip;
            buf[o + 1] = 4;
            @memcpy(buf[o + 2 .. o + 6], &ip);
            o += 6;
        }
        if (server_id) |sid| {
            buf[o] = opt_server_id;
            buf[o + 1] = 4;
            @memcpy(buf[o + 2 .. o + 6], &sid);
            o += 6;
        }
    }
    buf[o] = opt_end;
    o += 1;
    return o;
}

/// Build the DISCOVER into `buf` (the INIT step). Returns the length.
pub fn build_discover(buf: []u8, chaddr: *const [6]u8, txn_id: u32) usize {
    return build_message(buf, chaddr, txn_id, msg_type_discover, null, null);
}

/// Build the REQUEST (the SELECTING step — option 50 = the offered IP,
/// option 54 = the offering server). Returns the length.
pub fn build_request(buf: []u8, chaddr: *const [6]u8, txn_id: u32, req_ip: [4]u8, srv_id: [4]u8) usize {
    return build_message(buf, chaddr, txn_id, msg_type_request, req_ip, srv_id);
}

// ---------------------------------------------------------------------------
// Reply parse (RFC 2131 §4.1 — the four-message handshake)
// ---------------------------------------------------------------------------

pub const ParsedReply = struct {
    msg_type: u8,
    yiaddr: [4]u8,
    mask: ?[4]u8 = null,
    router: ?[4]u8 = null,
    server_id: ?[4]u8 = null,
    lease_time: ?u32 = null,
};

/// Parse a BOOTREPLY message: op 2, htype 1 / hlen 6, the magic cookie,
/// the yiaddr, and the options (53 message type — required; 1 mask; 3
/// router; 54 server id; 51 lease time). Malformed replies return null
/// (the caller counts `dropped_malformed` — never assumed away). Option
/// 0 (pad) skips; unknown options skip by their length; the walk stops at
/// 255 (end) or the message end.
pub fn parse_reply(msg_in: []const u8) ?ParsedReply {
    if (msg_in.len < bootp_hdr_len + 4) return null;
    if (msg_in[0] != 2) return null; // BOOTREPLY
    if (msg_in[1] != 1 or msg_in[2] != 6) return null; // ethernet / 6-byte hw
    if (!std.mem.eql(u8, msg_in[236..240], &magic_cookie)) return null;
    var p = ParsedReply{ .msg_type = 0, .yiaddr = .{ 0, 0, 0, 0 } };
    @memcpy(&p.yiaddr, msg_in[16..20]);
    var got_type = false;
    var i: usize = 240;
    while (i < msg_in.len) {
        const code = msg_in[i];
        if (code == opt_end) break;
        if (code == 0) {
            i += 1; // pad
            continue;
        }
        if (i + 1 >= msg_in.len) return null; // truncated length byte
        const len: usize = msg_in[i + 1];
        if (i + 2 + len > msg_in.len) return null; // truncated value
        switch (code) {
            opt_msg_type => {
                if (len != 1) return null;
                p.msg_type = msg_in[i + 2];
                got_type = true;
            },
            opt_subnet_mask => {
                if (len != 4) return null;
                var v: [4]u8 = undefined;
                @memcpy(&v, msg_in[i + 2 .. i + 6]);
                p.mask = v;
            },
            opt_router => {
                if (len != 4) return null;
                var v: [4]u8 = undefined;
                @memcpy(&v, msg_in[i + 2 .. i + 6]);
                p.router = v;
            },
            opt_server_id => {
                if (len != 4) return null;
                var v: [4]u8 = undefined;
                @memcpy(&v, msg_in[i + 2 .. i + 6]);
                p.server_id = v;
            },
            opt_lease_time => {
                if (len != 4) return null;
                p.lease_time = (@as(u32, msg_in[i + 2]) << 24) | (@as(u32, msg_in[i + 3]) << 16) | (@as(u32, msg_in[i + 4]) << 8) | msg_in[i + 5];
            },
            else => {}, // unknown option — skip by length
        }
        i += 2 + len;
    }
    if (!got_type) return null;
    return p;
}

// ---------------------------------------------------------------------------
// The client state machine
// ---------------------------------------------------------------------------

/// Reset the client (tests only — the live kernel never re-initializes).
pub fn reset() void {
    state = .idle;
    xid = 0;
    attempts = 0;
    msg_len = 0;
    request_transmitted = false;
    offered_ip = .{ 0, 0, 0, 0 };
    offered_server = .{ 0, 0, 0, 0 };
    lease_ip = .{ 0, 0, 0, 0 };
    lease_mask = .{ 0, 0, 0, 0 };
    lease_gw = .{ 0, 0, 0, 0 };
    lease_server = .{ 0, 0, 0, 0 };
    lease_time = 0;
    arp.own_mask = .{ 255, 255, 255, 0 };
    arp.gateway = .{ 0, 0, 0, 0 };
    discover_sent = 0;
    offer_recv = 0;
    request_sent = 0;
    ack_recv = 0;
    nack_recv = 0;
    timed_out = 0;
    dropped_malformed = 0;
    renew_sent = 0;
    rebind_sent = 0;
    renewed = 0;
    expired = 0;
    now_ticks = 0;
    bound_ticks = 0;
}

/// INIT -> SELECTING: build the DISCOVER into `msg` with the given
/// transaction id (the caller supplies the CSPRNG draw — or a fixture
/// value in tests) and our chaddr. The caller transmits `msg[0..msg_len]`
/// and counts `discover_sent` + `attempts` on success.
pub fn start(chaddr_in: *const [6]u8, txn_id: u32) void {
    state = .selecting;
    xid = txn_id;
    client_mac = chaddr_in.*;
    request_transmitted = false;
    msg_len = build_discover(&msg, chaddr_in, txn_id);
}

// ---------------------------------------------------------------------------
// Card N9 (claim 9489): the lease lifecycle (RFC 2131 §4.4.5)
// ---------------------------------------------------------------------------

/// The RENEWING threshold T1 = 0.5 × lease (integer seconds).
pub fn t1(lease: u32) u64 {
    return lease / 2;
}

/// The REBINDING threshold T2 = 0.875 × lease (integer seconds). The
/// multiply is done in u64 — a server may offer a lease up to 2^32-1 s
/// and `lease * 7` overflows u32 above ~613 M (audit M97e-F4 rider).
pub fn t2(lease: u32) u64 {
    return (@as(u64, lease) * 7) / 8;
}

/// Seconds since the last (re)bind, per the caller-stamped clock.
pub fn elapsed() u64 {
    return now_ticks -| bound_ticks;
}

/// BOUND -> RENEWING: build the REQUEST for the SAME lease (options 50 +
/// 54, the transaction id unchanged) with `ciaddr` = the leased IP (RFC
/// 2131 §4.4.5 — the renewal REQUEST identifies the address the client
/// already holds). The monitor transmits it UNICAST to the server (the
/// MAC the caller resolved) exactly once, then waits for the renewal
/// ACK. The lease keeps ticking during the wait; at T2 / expiry the
/// monitor advances regardless (honest — a pending renewal never
/// outlives its lease).
pub fn enter_renewing() void {
    msg_len = build_request(&msg, &client_mac, xid, lease_ip, lease_server);
    @memcpy(msg[12..16], &lease_ip); // ciaddr = the leased address
    request_transmitted = false;
    state = .renewing;
}

/// BOUND -> REBINDING: the SAME built REQUEST (ciaddr = the lease), to
/// be transmitted BROADCAST (any server on the link can answer).
pub fn enter_rebinding() void {
    msg_len = build_request(&msg, &client_mac, xid, lease_ip, lease_server);
    @memcpy(msg[12..16], &lease_ip); // ciaddr = the leased address
    request_transmitted = false;
    state = .rebinding;
}

/// Issue #119 (audit follow-up 3): the pure RFC 2131 §4.4.5 lifecycle
/// decision — what ONE step the CURRENT state + elapsed lease time
/// demand. Pure (reads `state` + `lease_time` + `elapsed`; mutates
/// nothing), so the decision is host-testable and the apply/transmit
/// glue (virtio_net's `net_dhcp_poll`) stays transport-side. The order
/// matters: expiry beats T2 beats T1, and RENEWING/REBINDING only ever
/// expire (a pending renewal never outlives its lease).
pub const Step = enum { none, expire, rebind, renew };

pub fn step_lifecycle() Step {
    const lease = lease_time;
    const el = elapsed();
    switch (state) {
        .renewing => {
            // RFC 2131 §4.4.5: at T2 a client STILL in RENEWING (the
            // unicast renewal REQUEST went unanswered) ESCALATES to
            // REBINDING — the broadcast REQUEST any server on the link
            // can answer. Audit follow-up 3 (issue #119): with the
            // autonomous poll this is the ONLY way the client ever
            // reaches REBINDING when the server answers renewals — the
            // old BOUND-only T2 path required a command to land between
            // T1 and T2 (the command-gated behavior the issue flagged).
            if (lease > 0 and el >= t2(lease)) return .rebind;
            if (lease > 0 and el >= lease) return .expire;
            return .none;
        },
        .rebinding => {
            // A pending rebinding never outlives its lease.
            if (lease > 0 and el >= lease) return .expire;
            return .none;
        },
        .bound => {
            if (lease > 0 and el >= lease) return .expire;
            if (lease > 0 and el >= t2(lease)) return .rebind;
            if (lease > 0 and el >= t1(lease)) return .renew;
            return .none;
        },
        else => return .none, // idle/selecting/requesting: the handshake stays command-driven
    }
}

/// The lease expired: release the address honestly (arp.own_ip cleared
/// — the client no longer owns it; the lease-sourced mask/gateway go
/// with it — the default /24 mask returns and the off-subnet card's
/// explicit-gateway input is withdrawn), zero the lease record (the
/// report shows zeros when unbound), fall back to INIT, and reset the
/// bounded-retry attempts (a fresh lease attempt). The next `net dhcp`
/// re-DISCOVERs.
pub fn expire() void {
    arp.own_ip = .{ 0, 0, 0, 0 };
    arp.own_mask = .{ 255, 255, 255, 0 };
    arp.gateway = .{ 0, 0, 0, 0 };
    lease_ip = .{ 0, 0, 0, 0 };
    lease_mask = .{ 0, 0, 0, 0 };
    lease_gw = .{ 0, 0, 0, 0 };
    lease_server = .{ 0, 0, 0, 0 };
    lease_time = 0;
    state = .idle;
    attempts = 0;
    request_transmitted = false;
    expired += 1;
}

/// Process one server reply (the UDP payload of a port-68 datagram —
/// the 8-byte UDP header already skipped by the caller). Runs in the RX
/// drain context: OFFER (SELECTING) accepts the offer, builds the REQUEST
/// into `msg`, and moves to REQUESTING; ACK (REQUESTING) records the
/// lease, sets `arp.own_ip` (THE one copy — DHCP overwrites the static
/// address honestly) and moves to BOUND; ACK in RENEWING/REBINDING
/// (card N9, claim 9489) restarts the lease — `bound_ticks = now_ticks`
/// and `renewed` counts it; NACK falls back to IDLE (the caller may
/// retry — bounded). Anything unexpected is counted
/// `dropped_malformed`. The REQUEST transmission itself is MONITOR-driven
/// (the state machine only builds it — `request_transmitted` gates the
/// one-shot transmit), so the handshake is deterministic and never
/// transmits from the drain context.
pub fn handle_rx(datagram: []const u8) Event {
    if (datagram.len < udp_hdr_len_ + 1) {
        dropped_malformed += 1;
        return .none;
    }
    const msg_in = datagram[udp_hdr_len_..];
    const p = parse_reply(msg_in) orelse {
        dropped_malformed += 1;
        return .none;
    };
    // M97e-F4 (#2103): the reply must belong to OUR transaction before
    // it can move the state machine — `xid` (bytes 4..8, the DISCOVER's
    // echo) and `chaddr` (bytes 28..44, our MAC — hlen is 6, checked by
    // `parse_reply`). Our requests go out broadcast and the replies come
    // back broadcast, so EVERY port-68 host on the link sees them: a
    // foreign client's OFFER/ACK (or a forged NACK) would otherwise
    // claim `offered_ip`, adopt a foreign lease into `arp.own_ip`, or
    // knock the client back to IDLE.
    const xid_in: u32 = (@as(u32, msg_in[4]) << 24) | (@as(u32, msg_in[5]) << 16) | (@as(u32, msg_in[6]) << 8) | msg_in[7];
    if (xid_in != xid or !std.mem.eql(u8, msg_in[28..34], &client_mac)) {
        dropped_malformed += 1; // another client's handshake — not ours
        return .none;
    }
    switch (p.msg_type) {
        msg_type_offer => {
            if (state != .selecting) {
                dropped_malformed += 1; // an OFFER outside SELECTING
                return .none;
            }
            offered_ip = p.yiaddr;
            offered_server = p.server_id orelse p.yiaddr;
            msg_len = build_request(&msg, &client_mac, xid, offered_ip, offered_server);
            request_transmitted = false;
            state = .requesting;
            offer_recv += 1;
            return .request_ready;
        },
        msg_type_ack => {
            const was_renewal = state == .renewing or state == .rebinding;
            if (state != .requesting and !was_renewal) {
                dropped_malformed += 1; // an ACK outside REQUESTING/REnewal
                return .none;
            }
            lease_ip = p.yiaddr;
            lease_mask = p.mask orelse .{ 0, 0, 0, 0 };
            lease_gw = p.router orelse .{ 0, 0, 0, 0 };
            lease_server = p.server_id orelse p.yiaddr;
            lease_time = p.lease_time orelse 0;
            // THE one copy — DHCP overwrites the static address honestly
            // (the report shows the old -> new). The lease's mask/router
            // land beside it (the off-subnet card's routing input: an
            // absent mask keeps the /24 bound, an absent router leaves
            // the .1 derivation as the default route).
            arp.own_ip = lease_ip;
            if (p.mask != null) arp.own_mask = lease_mask;
            arp.gateway = lease_gw;
            state = .bound;
            bound_ticks = now_ticks; // the lease (re)started now
            if (was_renewal) {
                renewed += 1;
                return .renewed;
            }
            ack_recv += 1;
            return .bound;
        },
        msg_type_nack => {
            nack_recv += 1;
            state = .idle; // the caller may retry (bounded attempts)
            return .nacked;
        },
        else => {
            dropped_malformed += 1;
            return .none;
        },
    }
}

// (local) — mirrors udp.udp_hdr_len without the udp import (no circular
// dependency: udp imports dhcp for the port-68 dispatch).
const udp_hdr_len_: usize = 8;
