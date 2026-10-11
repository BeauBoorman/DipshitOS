//! ARP (RFC 826) over the card-N2 raw-Ethernet seam — milestone five,
//! card N3 (claim 7293). PURE protocol logic (parse / build / classify /
//! bounded table) + host tests, the fat.zig pattern; virtio_net.zig wires
//! it to the transport (the RX drain dispatches ARP frames here, and the
//! N1 `net_send` TX path transmits the replies/requests it builds).
//!
//! Honest bounds: IPv4 ONLY (ptype 0x0800) — no IPv6/other; ONE bounded 4-slot
//! table (fixed BSS, no heap, no allocation); no cache expiry (an entry
//! lives until it is replaced — documented, not assumed); a request for
//! an address we do not own is dropped with a counter (we only answer for
//! our own protocol address).
//!
//! Next-hop (the off-subnet card): `lookup` answers the MAC of the NEXT
//! HOP toward the queried address, not only the peer itself. A peer that
//! shares our subnet (`on_link` under `own_mask`) resolves directly —
//! the ARP-exact-peer behaviour every caller already relied on. An
//! off-subnet destination resolves through the default gateway
//! (`default_gateway`: the explicit `gateway`, else the contract's
//! first-host-of-the-subnet derivation — the observed VZ NAT puts the
//! router at .1 of a /24). With no usable gateway the answer stays the
//! literal peer, so a gateway-less guest keeps the old exact-peer
//! semantics and honestly fails to resolve off-subnet (the NAT does no
//! proxy-ARP). Broadcast/multicast/loopback-shaped destinations never
//! route.

pub const ethertype_arp: u16 = 0x0806; // Ethernet II ethertype
pub const eth_hdr_len: usize = 14; // dst MAC (6) + src MAC (6) + ethertype (2)
pub const arp_pkt_len: usize = 28; // htype 2 + ptype 2 + hlen 1 + plen 1 + op 2 + sha 6 + spa 4 + tha 6 + tpa 4
/// A complete ARP Ethernet frame: 14-byte header + 28-byte ARP payload.
pub const arp_frame_len: usize = eth_hdr_len + arp_pkt_len; // 42

pub const htype_ethernet: u16 = 0x0001;
pub const ptype_ipv4: u16 = 0x0800;
pub const hlen_ethernet: u8 = 6;
pub const plen_ipv4: u8 = 4;
pub const op_request: u16 = 0x0001;
pub const op_reply: u16 = 0x0002;

/// Bounded ARP table capacity (fixed BSS — no heap, no unbounded growth).
pub const table_slots: usize = 4;

pub const ArpEntry = struct {
    valid: bool = false,
    ip: [4]u8 = .{ 0, 0, 0, 0 },
    mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
};

/// Our static protocol (IPv4) address — fixed BSS, zero = unset. Set by
/// `net ip <a.b.c.d>` or overwritten by the DHCP lease on BOUND (THE one
/// copy — dhcp.zig writes it, never a second source).
pub var own_ip: [4]u8 = .{ 0, 0, 0, 0 };

/// Our subnet mask — fixed BSS. The static default is /24: every net the
/// guest has ever observed is a /24 (the VZ NAT 192.168.64.0/24, the
/// --net test net 10.0.0.x, and there is no prefix API to learn another
/// shape). The DHCP lease's option-1 mask overwrites it on BOUND;
/// expire() restores the default. A different static prefix has no
/// source yet — an honest bound, documented not assumed.
pub var own_mask: [4]u8 = .{ 255, 255, 255, 0 };

/// The configured default gateway — fixed BSS, zero = none configured.
/// The DHCP ACK's router option (option 3) lands here on BOUND and is
/// cleared on expiry. A `net gw` command is a later card; until then a
/// static config leaves this zero and `default_gateway` derives the
/// contract's first-host address instead.
pub var gateway: [4]u8 = .{ 0, 0, 0, 0 };

/// The bounded peer table (protocol address -> hardware address).
pub var table: [table_slots]ArpEntry = @as([table_slots]ArpEntry, @splat(@as(ArpEntry, .{})));

/// Round-robin cursor for drop-oldest eviction (no timestamps, no heap).
/// `pub` for the cross-module wiring tests (virtio_net resets it).
pub var table_cursor: usize = 0;

/// The protocol address an ARP request is outstanding for — set by
/// `build_request` (the ONE wire-request funnel: every request we send
/// asks "who has THIS address", so the built tpa is the pending target,
/// already the NEXT-HOP resolution for an off-subnet destination) and
/// cleared when its matching reply is learned. `null` = no request
/// outstanding. M97e-F3 (#2102): a reply is learned ONLY against this —
/// an unsolicited reply can never create or overwrite an entry (an
/// on-link host could otherwise overwrite the gateway mapping and
/// redirect every off-subnet flow). ONE slot: a second request
/// supersedes the first, matching the single-request-at-a-time senders.
pub var pending_reply: ?[4]u8 = null;

/// ARP counters (the `net`/`net arp` reports).
pub var requests_sent: u64 = 0; // ARP requests we transmitted (a resolve miss)
pub var replies_sent: u64 = 0; // replies to requests for OUR protocol address
pub var replies_learned: u64 = 0; // table upserts from incoming replies
pub var dropped: u64 = 0; // malformed / not-for-us / no-IP-set ARP frames
/// Replies we built but could not transmit (the polled TX path timed out
/// honestly — never assumed away).
pub var reply_tx_fail: u64 = 0;

/// Whether a static IP is set (all-zero = unset — a valid 0.0.0.0 is
/// treated as unset; we cannot answer for it and won't send from it).
pub fn ip_set() bool {
    for (own_ip) |b| {
        if (b != 0) return true;
    }
    return false;
}

/// Parse a dotted-quad IPv4 address ("a.b.c.d", each 0..255). Returns
/// null on any malformed component. No heap — the text is scanned in
/// place.
pub fn parse_ip(text: []const u8) ?[4]u8 {
    var out: [4]u8 = .{ 0, 0, 0, 0 };
    var part: u8 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '.') {
            if (part == 4) return null; // more than 4 components
            if (i == start) return null; // empty component
            var v: u32 = 0;
            var j = start;
            while (j < i) : (j += 1) {
                const c = text[j];
                if (c < '0' or c > '9') return null;
                v = v * 10 + (c - '0');
                if (v > 255) return null;
            }
            out[part] = @intCast(v);
            part += 1;
            start = i + 1;
        }
    }
    if (part != 4) return null;
    return out;
}

/// Format an IPv4 address as "a.b.c.d" into `out` (must hold >= 15
/// bytes). Returns the length written (no trailing NUL).
pub fn format_ip(ip: [4]u8, out: *[15]u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (i > 0) {
            out[n] = '.';
            n += 1;
        }
        var d = ip[i];
        if (d >= 100) {
            out[n] = '0' + (d / 100);
            n += 1;
            d %= 100;
        }
        if (d >= 10 or ip[i] >= 100) {
            out[n] = '0' + (d / 10);
            n += 1;
            d %= 10;
        }
        out[n] = '0' + d;
        n += 1;
    }
    return n;
}

/// Whether `ip` is all zeros (unset).
fn ip_zero(ip: [4]u8) bool {
    for (ip) |b| {
        if (b != 0) return false;
    }
    return true;
}

/// Whether `ip` shares our subnet under `own_mask` — requires a
/// configured address (with none there is no link to be on).
pub fn on_link(ip: [4]u8) bool {
    if (!ip_set()) return false;
    for (0..4) |i| {
        if ((ip[i] & own_mask[i]) != (own_ip[i] & own_mask[i])) return false;
    }
    return true;
}

/// The contract's gateway derivation for a static config: the first host
/// of our subnet — `own_ip & own_mask` with 1 in the host bits (the
/// observed VZ NAT puts the router at .1 of a /24; see
/// docs/hardware-contract.md's NAT row). Zero when no IP is set.
pub fn derived_gateway() [4]u8 {
    if (!ip_set()) return .{ 0, 0, 0, 0 };
    var gw: [4]u8 = .{ 0, 0, 0, 0 };
    for (0..4) |i| {
        gw[i] = (own_ip[i] & own_mask[i]) | (~own_mask[i] & @as(u8, if (i == 3) 1 else 0));
    }
    return gw;
}

/// The effective default gateway: the explicit `gateway` when one is
/// configured (the DHCP lease's router option), else the contract
/// derivation — unless the derivation lands on our own address (a host
/// cannot route through itself; the 10.0.0.1 test-net fixture is exactly
/// that case). Zero = no gateway; routing falls back to exact-peer ARP.
pub fn default_gateway() [4]u8 {
    if (!ip_zero(gateway)) return gateway;
    const gw = derived_gateway();
    if (std.mem.eql(u8, &gw, &own_ip)) return .{ 0, 0, 0, 0 };
    return gw;
}

/// The L2 resolution target for a packet addressed to `dst`: an on-link
/// or unroutable destination resolves itself (broadcast 255.255.255.255,
/// multicast 224.0.0.0/4, loopback 127.0.0.0/8 and the 0.0.0.0/8 "this
/// host" block never route); an off-link destination resolves the
/// default gateway — and with no usable gateway it resolves itself, the
/// pre-next-hop exact-peer behaviour (the honest refusal path: no
/// proxy-ARP upstream means the miss stands).
pub fn next_hop(dst: [4]u8) [4]u8 {
    if (dst[0] == 0 or dst[0] == 127 or dst[0] >= 224) return dst;
    if (on_link(dst)) return dst;
    const gw = default_gateway();
    if (ip_zero(gw)) return dst;
    return gw;
}

/// The next-hop hardware address for a protocol address: on-link peers
/// (and every destination when no gateway exists) resolve their own
/// table entry — the original exact-peer semantics; off-link
/// destinations resolve the GATEWAY's entry — the frame's Ethernet dst
/// is the router's MAC while its IPv4 dst stays the remote address.
/// Returns null when the next hop is not learned.
pub fn lookup(ip: [4]u8) ?[6]u8 {
    const target = next_hop(ip);
    for (&table) |*e| {
        if (e.valid and std.mem.eql(u8, &e.ip, &target)) return e.mac;
    }
    return null;
}

/// Upsert (protocol address -> hardware address): update in place on a
/// hit, else fill the first free slot, else drop the oldest entry via a
/// round-robin cursor. No cache expiry (documented honest bound).
pub fn upsert(ip: [4]u8, mac: [6]u8) void {
    for (&table) |*e| {
        if (e.valid and std.mem.eql(u8, &e.ip, &ip)) {
            e.mac = mac;
            return;
        }
    }
    for (&table) |*e| {
        if (!e.valid) {
            e.valid = true;
            e.ip = ip;
            e.mac = mac;
            return;
        }
    }
    const slot = &table[table_cursor];
    table_cursor = (table_cursor + 1) % table_slots;
    slot.valid = true;
    slot.ip = ip;
    slot.mac = mac;
}

// ---------------------------------------------------------------------------
// Frame field accessors (the frame starts at the Ethernet header — dst
// MAC, src MAC, ethertype, then the 28-byte ARP payload).
// ---------------------------------------------------------------------------

/// The Ethernet II ethertype (0 if the frame is too short to carry one).
pub fn ethertype(frame: []const u8) u16 {
    if (frame.len < 14) return 0;
    return (@as(u16, frame[12]) << 8) | frame[13];
}

/// Whether the frame is an ARP frame for OUR medium/protocol (ethernet +
/// IPv4, hlen 6, plen 4) — the shape we can parse. A frame that is not
/// ARP at all returns false too (it is not our concern; the caller's
/// `net recv` seam still observes it).
pub fn is_valid_arp(frame: []const u8) bool {
    if (frame.len < arp_frame_len) return false;
    if (ethertype(frame) != ethertype_arp) return false;
    const htype = (@as(u16, frame[14]) << 8) | frame[15];
    const ptype = (@as(u16, frame[16]) << 8) | frame[17];
    return htype == htype_ethernet and ptype == ptype_ipv4 and frame[18] == hlen_ethernet and frame[19] == plen_ipv4;
}

/// The ARP operation (0 for a non-ARP frame).
pub fn op(frame: []const u8) u16 {
    if (frame.len < 22) return 0;
    return (@as(u16, frame[20]) << 8) | frame[21];
}

pub fn sender_mac(frame: []const u8) [6]u8 {
    var m: [6]u8 = undefined;
    @memcpy(&m, frame[22..28]);
    return m;
}

pub fn sender_ip(frame: []const u8) [4]u8 {
    var ip: [4]u8 = undefined;
    @memcpy(&ip, frame[28..32]);
    return ip;
}

/// Whether the frame is an ARP REQUEST for OUR protocol address (tpa ==
/// own_ip). Requires a static IP to be set — with no IP we cannot answer
/// for any address (honest: dropped by the caller's dispatch).
pub fn is_request_for_us(frame: []const u8) bool {
    if (!is_valid_arp(frame)) return false;
    if (op(frame) != op_request) return false;
    if (!ip_set()) return false;
    if (frame.len < 42) return false;
    return std.mem.eql(u8, frame[38..42], &own_ip);
}

/// Whether the frame is a well-formed ARP REPLY.
pub fn is_reply(frame: []const u8) bool {
    if (!is_valid_arp(frame)) return false;
    return op(frame) == op_reply;
}

/// Build an ARP REQUEST (broadcast dst, our MAC/IP as sender, zeroed
/// target hardware, target protocol = `target_ip`) into `buf` (must hold
/// >= `arp_frame_len` bytes). Returns the frame length (42).
pub fn build_request(buf: []u8, own_mac: *const [6]u8, own_ip_addr: [4]u8, target_ip: [4]u8) usize {
    @memset(buf[0..arp_frame_len], 0);
    @memset(buf[0..6], 0xff); // broadcast dst
    pending_reply = target_ip; // a request for `target_ip` is now outstanding (M97e-F3)
    @memcpy(buf[6..12], own_mac); // src
    buf[12] = 0x08;
    buf[13] = 0x06; // ethertype ARP
    buf[14] = 0x00;
    buf[15] = 0x01; // htype ethernet
    buf[16] = 0x08;
    buf[17] = 0x00; // ptype IPv4
    buf[18] = 0x06; // hlen
    buf[19] = 0x04; // plen
    buf[20] = 0x00;
    buf[21] = 0x01; // op request
    @memcpy(buf[22..28], own_mac); // sha
    @memcpy(buf[28..32], &own_ip_addr); // spa
    // tha stays zero (buf[32..38])
    @memcpy(buf[38..42], &target_ip); // tpa
    return arp_frame_len;
}

/// Build an ARP REPLY (unicast dst = `target_mac`, our MAC/IP as sender,
/// target = the requester's MAC/IP) into `buf` (must hold >=
/// `arp_frame_len` bytes). Returns the frame length (42).
pub fn build_reply(buf: []u8, own_mac: *const [6]u8, own_ip_addr: [4]u8, target_mac: [6]u8, target_ip: [4]u8) usize {
    @memset(buf[0..arp_frame_len], 0);
    @memcpy(buf[0..6], &target_mac); // dst = the requester
    @memcpy(buf[6..12], own_mac); // src
    buf[12] = 0x08;
    buf[13] = 0x06; // ethertype ARP
    buf[14] = 0x00;
    buf[15] = 0x01; // htype ethernet
    buf[16] = 0x08;
    buf[17] = 0x00; // ptype IPv4
    buf[18] = 0x06; // hlen
    buf[19] = 0x04; // plen
    buf[20] = 0x00;
    buf[21] = 0x02; // op reply
    @memcpy(buf[22..28], own_mac); // sha
    @memcpy(buf[28..32], &own_ip_addr); // spa
    @memcpy(buf[32..38], &target_mac); // tha
    @memcpy(buf[38..42], &target_ip); // tpa
    return arp_frame_len;
}

/// Process one received Ethernet frame (the caller has already MAC-
/// filtered it and passes the frame WITHOUT the RX virtio_net_hdr — the
/// Ethernet header starts at byte 0). Returns the length of a reply
/// built into `reply_buf` (a request for our protocol address — the
/// caller transmits it), or null (not ARP / a reply learned / dropped).
pub fn handle_rx(frame: []const u8, own_mac: *const [6]u8, reply_buf: []u8) ?usize {
    if (!is_valid_arp(frame)) {
        if (frame.len >= eth_hdr_len and ethertype(frame) == ethertype_arp) dropped += 1; // malformed ARP
        return null;
    }
    if (is_reply(frame)) {
        // M97e-F3 (#2102): learn ONLY the reply to a request we actually
        // have outstanding — an unsolicited reply (gratuitous or forged,
        // e.g. an on-link host racing to overwrite the gateway entry) is
        // dropped and counted, never upserted.
        const spa = sender_ip(frame);
        if (pending_reply) |p| {
            if (std.mem.eql(u8, &spa, &p)) {
                upsert(spa, sender_mac(frame));
                replies_learned += 1;
                pending_reply = null;
                return null;
            }
        }
        dropped += 1;
        return null;
    }
    if (!is_request_for_us(frame)) {
        dropped += 1; // a request for an address we do not own (or no IP set)
        return null;
    }
    return build_reply(reply_buf, own_mac, own_ip, sender_mac(frame), sender_ip(frame));
}

// ---------------------------------------------------------------------------
// Host tests — pure logic, byte-exact against the RFC fixtures
// ---------------------------------------------------------------------------

const std = @import("std");

const test_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 }; // the host-set guest MAC
const host_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 }; // the host-side MAC (fallback_mac)
const ip_guest = [4]u8{ 10, 0, 0, 1 };
const ip_host = [4]u8{ 10, 0, 0, 2 };

test "arp: dotted-quad parse — valid, malformed, out-of-range" {
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 0, 0, 1 }, &parse_ip("10.0.0.1").?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 255 }, &parse_ip("255.255.255.255").?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &parse_ip("0.0.0.0").?);
    try std.testing.expect(parse_ip("") == null);
    try std.testing.expect(parse_ip("10.0.0") == null);
    try std.testing.expect(parse_ip("10.0.0.1.2") == null);
    try std.testing.expect(parse_ip("10.0.0.256") == null);
    try std.testing.expect(parse_ip("10..0.1") == null);
    try std.testing.expect(parse_ip("10.0.0.x") == null);
    try std.testing.expect(parse_ip("10.0.0.1 ") == null);
    // format_ip round-trips the canonical shape.
    var text: [15]u8 = undefined;
    const n = format_ip(ip_guest, &text);
    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqualSlices(u8, "10.0.0.1", text[0..n]);
    const n2 = format_ip(.{ 255, 255, 255, 255 }, &text);
    try std.testing.expectEqual(@as(usize, 15), n2);
    try std.testing.expectEqualSlices(u8, "255.255.255.255", text[0..n2]);
}

test "arp: build_request is byte-exact against the fixture" {
    var buf: [arp_frame_len]u8 = undefined;
    const n = build_request(&buf, &test_mac, ip_guest, ip_host);
    try std.testing.expectEqual(@as(usize, 42), n);
    // Ethernet: broadcast dst, our MAC src, ethertype 0x0806.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, buf[0..6]);
    try std.testing.expectEqualSlices(u8, &test_mac, buf[6..12]);
    try std.testing.expectEqual(@as(u8, 0x08), buf[12]);
    try std.testing.expectEqual(@as(u8, 0x06), buf[13]);
    // ARP header: htype 1, ptype 0x0800, hlen 6, plen 4, op 1.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01 }, buf[14..16]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x00 }, buf[16..18]);
    try std.testing.expectEqual(@as(u8, 0x06), buf[18]);
    try std.testing.expectEqual(@as(u8, 0x04), buf[19]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01 }, buf[20..22]);
    // sha = ours, spa = ours, tha = zero, tpa = target.
    try std.testing.expectEqualSlices(u8, &test_mac, buf[22..28]);
    try std.testing.expectEqualSlices(u8, &ip_guest, buf[28..32]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0 }, buf[32..38]);
    try std.testing.expectEqualSlices(u8, &ip_host, buf[38..42]);
}

test "arp: build_reply is byte-exact against the fixture" {
    var buf: [arp_frame_len]u8 = undefined;
    const n = build_reply(&buf, &test_mac, ip_guest, host_mac, ip_host);
    try std.testing.expectEqual(@as(usize, 42), n);
    // Ethernet: unicast to the requester, our MAC src, ethertype 0x0806.
    try std.testing.expectEqualSlices(u8, &host_mac, buf[0..6]);
    try std.testing.expectEqualSlices(u8, &test_mac, buf[6..12]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x06 }, buf[12..14]);
    // ARP header: htype 1, ptype 0x0800, hlen 6, plen 4, op 2.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01 }, buf[14..16]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x00 }, buf[16..18]);
    try std.testing.expectEqual(@as(u8, 0x06), buf[18]);
    try std.testing.expectEqual(@as(u8, 0x04), buf[19]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x02 }, buf[20..22]);
    // sha/spa = ours; tha/tpa = the requester's.
    try std.testing.expectEqualSlices(u8, &test_mac, buf[22..28]);
    try std.testing.expectEqualSlices(u8, &ip_guest, buf[28..32]);
    try std.testing.expectEqualSlices(u8, &host_mac, buf[32..38]);
    try std.testing.expectEqualSlices(u8, &ip_host, buf[38..42]);
}

test "arp: classify — request-for-us, not-for-us, reply, non-ARP, malformed" {
    own_ip = ip_guest;
    defer own_ip = .{ 0, 0, 0, 0 };
    var req_for_us: [arp_frame_len]u8 = undefined;
    _ = build_request(&req_for_us, &host_mac, ip_host, ip_guest);
    try std.testing.expect(is_valid_arp(&req_for_us));
    try std.testing.expect(is_request_for_us(&req_for_us));
    try std.testing.expect(!is_reply(&req_for_us));

    // A request for a DIFFERENT address is not for us.
    var req_other: [arp_frame_len]u8 = undefined;
    _ = build_request(&req_other, &host_mac, ip_host, .{ 10, 0, 0, 99 });
    try std.testing.expect(is_valid_arp(&req_other));
    try std.testing.expect(!is_request_for_us(&req_other));

    // A reply is a reply, not a request.
    var rep: [arp_frame_len]u8 = undefined;
    _ = build_reply(&rep, &host_mac, ip_host, test_mac, ip_guest);
    try std.testing.expect(is_valid_arp(&rep));
    try std.testing.expect(is_reply(&rep));
    try std.testing.expect(!is_request_for_us(&rep));

    // Non-ARP: ethertype 0x0800 (the N2 known frame shape).
    var ip_frame: [eth_hdr_len + 20]u8 = @splat(0);
    ip_frame[12] = 0x08;
    ip_frame[13] = 0x00;
    try std.testing.expect(!is_valid_arp(&ip_frame));

    // A short ARP frame is malformed (not valid).
    try std.testing.expect(!is_valid_arp(rep[0..41]));
    // A wrong htype / ptype / hlen / plen is malformed too.
    var bad = rep;
    bad[14] = 0x00;
    bad[15] = 0x02; // htype token-ring
    try std.testing.expect(!is_valid_arp(&bad));
    bad = rep;
    bad[19] = 0x06; // plen 6 (IPv6 — not our shape)
    try std.testing.expect(!is_valid_arp(&bad));

    // No IP set: a request cannot be for us (we cannot answer).
    own_ip = .{ 0, 0, 0, 0 };
    try std.testing.expect(!is_request_for_us(&req_for_us));
}

test "arp: bounded table — lookup, upsert in place, first-free, drop-oldest" {
    // Reset the module table state (BSS is not trusted zeroed).
    table = @as([table_slots]ArpEntry, @splat(@as(ArpEntry, .{})));
    table_cursor = 0;
    try std.testing.expect(lookup(.{ 10, 0, 0, 2 }) == null);

    upsert(.{ 10, 0, 0, 2 }, host_mac);
    try std.testing.expectEqualSlices(u8, &host_mac, &lookup(.{ 10, 0, 0, 2 }).?);

    // Update in place on a hit (same ip, new mac).
    const new_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x09 };
    upsert(.{ 10, 0, 0, 2 }, new_mac);
    try std.testing.expectEqualSlices(u8, &new_mac, &lookup(.{ 10, 0, 0, 2 }).?);
    var count: usize = 0;
    for (&table) |*e| {
        if (e.valid) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count); // no duplicate slot

    // Fill to capacity (first-free slots), then evict the oldest.
    upsert(.{ 10, 0, 0, 3 }, .{ 0x02, 0, 0, 0, 0, 3 });
    upsert(.{ 10, 0, 0, 4 }, .{ 0x02, 0, 0, 0, 0, 4 });
    upsert(.{ 10, 0, 0, 5 }, .{ 0x02, 0, 0, 0, 0, 5 });
    try std.testing.expectEqual(@as(usize, 4), table_slots);
    // A 5th distinct entry evicts one (drop-oldest via the cursor).
    upsert(.{ 10, 0, 0, 6 }, .{ 0x02, 0, 0, 0, 0, 6 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0, 0, 0, 0, 6 }, &lookup(.{ 10, 0, 0, 6 }).?);
    // Exactly one entry was evicted; the rest remain.
    var valid: usize = 0;
    for (&table) |*e| {
        if (e.valid) valid += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), valid);
}

test "arp: handle_rx — answer for us, learn a reply, drop the rest" {
    own_ip = ip_guest;
    table = @as([table_slots]ArpEntry, @splat(@as(ArpEntry, .{})));
    table_cursor = 0;
    requests_sent = 0;
    replies_sent = 0;
    replies_learned = 0;
    dropped = 0;
    reply_tx_fail = 0;
    pending_reply = null;
    defer own_ip = .{ 0, 0, 0, 0 };
    defer pending_reply = null;

    var reply_buf: [arp_frame_len]u8 = undefined;

    // A request for OUR address: a byte-exact reply is built. (The
    // fixture build marks a request outstanding as a side effect — clear
    // it; this frame is the HOST's request, not ours.)
    var req: [arp_frame_len]u8 = undefined;
    _ = build_request(&req, &host_mac, ip_host, ip_guest);
    pending_reply = null;
    const rn = handle_rx(&req, &test_mac, &reply_buf).?;
    try std.testing.expectEqual(@as(usize, 42), rn);
    try std.testing.expectEqualSlices(u8, &host_mac, reply_buf[0..6]); // dst = requester
    try std.testing.expectEqualSlices(u8, &test_mac, reply_buf[6..12]);
    try std.testing.expectEqualSlices(u8, &ip_host, reply_buf[38..42]); // tpa = requester
    try std.testing.expectEqual(@as(u64, 0), replies_sent); // the CALLER sends
    try std.testing.expectEqual(@as(u64, 0), dropped);

    // A request for a DIFFERENT address: dropped, no reply.
    var req_other: [arp_frame_len]u8 = undefined;
    _ = build_request(&req_other, &host_mac, ip_host, .{ 10, 0, 0, 99 });
    pending_reply = null;
    try std.testing.expect(handle_rx(&req_other, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 1), dropped);

    // M97e-F3 (#2102): an UNSOLICITED reply is dropped, never learned —
    // even for the gateway. We then issue OUR request for ip_host and
    // its matching reply IS learned (the request is consumed).
    const attacker_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x66, 0x66 };
    var rep_forge: [arp_frame_len]u8 = undefined;
    _ = build_reply(&rep_forge, &attacker_mac, ip_host, test_mac, ip_guest);
    try std.testing.expect(handle_rx(&rep_forge, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 2), dropped);
    try std.testing.expectEqual(@as(u64, 0), replies_learned);
    try std.testing.expect(lookup(ip_host) == null);

    var our_req: [arp_frame_len]u8 = undefined;
    _ = build_request(&our_req, &test_mac, ip_guest, ip_host);
    try std.testing.expectEqualSlices(u8, &ip_host, &pending_reply.?);

    var rep: [arp_frame_len]u8 = undefined;
    _ = build_reply(&rep, &host_mac, ip_host, test_mac, ip_guest);
    try std.testing.expect(handle_rx(&rep, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 1), replies_learned);
    try std.testing.expect(pending_reply == null); // the outstanding request was consumed
    try std.testing.expectEqualSlices(u8, &host_mac, &lookup(ip_host).?);

    // A reply for an address we did NOT just request is still refused
    // (a second knock after the pending was consumed).
    var rep_other: [arp_frame_len]u8 = undefined;
    _ = build_reply(&rep_other, &.{ 0x02, 0, 0, 0, 0, 7 }, .{ 10, 0, 0, 7 }, test_mac, ip_guest);
    try std.testing.expect(handle_rx(&rep_other, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 3), dropped);
    try std.testing.expect(lookup(.{ 10, 0, 0, 7 }) == null);

    // A non-ARP frame: untouched, not counted as dropped.
    var ip_frame: [eth_hdr_len + 20]u8 = @splat(0);
    ip_frame[12] = 0x08;
    ip_frame[13] = 0x00;
    try std.testing.expect(handle_rx(&ip_frame, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 3), dropped);

    // A malformed ARP (short): dropped.
    try std.testing.expect(handle_rx(rep[0..41], &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 4), dropped);

    // No IP set: a request is not answered (dropped).
    own_ip = .{ 0, 0, 0, 0 };
    try std.testing.expect(handle_rx(&req, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 5), dropped);
}

// ---------------------------------------------------------------------------
// Next-hop routing tests (the off-subnet card)
// ---------------------------------------------------------------------------

fn reset_route_state() void {
    own_ip = .{ 0, 0, 0, 0 };
    own_mask = .{ 255, 255, 255, 0 };
    gateway = .{ 0, 0, 0, 0 };
    table = @as([table_slots]ArpEntry, @splat(@as(ArpEntry, .{})));
    table_cursor = 0;
    pending_reply = null;
}

test "arp: on_link — subnet membership under the /24 bound and a wider mask" {
    reset_route_state();
    defer reset_route_state();

    // No IP configured: nothing is on-link.
    try std.testing.expect(!on_link(.{ 192, 168, 64, 1 }));

    own_ip = .{ 192, 168, 64, 5 };
    try std.testing.expect(on_link(.{ 192, 168, 64, 1 }));
    try std.testing.expect(on_link(.{ 192, 168, 64, 254 }));
    try std.testing.expect(!on_link(.{ 192, 168, 65, 1 }));
    try std.testing.expect(!on_link(.{ 10, 0, 0, 2 }));
    try std.testing.expect(!on_link(.{ 1, 1, 1, 1 }));

    // A DHCP-offered /16 widens the link honestly.
    own_mask = .{ 255, 255, 0, 0 };
    own_ip = .{ 192, 168, 64, 5 };
    try std.testing.expect(on_link(.{ 192, 168, 65, 1 }));
    try std.testing.expect(!on_link(.{ 192, 169, 0, 1 }));
}

test "arp: default_gateway — explicit wins, .1 derives, self is refused" {
    reset_route_state();
    defer reset_route_state();

    // No IP: no gateway at all.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &default_gateway());

    // Static config on the observed VZ NAT shape: the contract's router
    // sits at .1 of the /24 — derived, no configuration needed.
    own_ip = .{ 192, 168, 64, 5 };
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 64, 1 }, &derived_gateway());
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 64, 1 }, &default_gateway());

    // The test-net fixture: own address IS the derived first host — a
    // host cannot route through itself, so there is no gateway.
    own_ip = .{ 10, 0, 0, 1 };
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 1 }, &derived_gateway());
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &default_gateway());

    // An explicit gateway (the DHCP lease's router option) wins over the
    // derivation — and even over the self-derivation case (the lease is
    // the authority).
    own_ip = .{ 192, 168, 64, 5 };
    gateway = .{ 192, 168, 64, 254 };
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 64, 254 }, &default_gateway());
    own_ip = .{ 10, 0, 0, 1 };
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 64, 254 }, &default_gateway());
}

test "arp: next_hop — on-link resolves itself, off-link the gateway, unroutable itself" {
    reset_route_state();
    defer reset_route_state();

    own_ip = .{ 192, 168, 64, 5 };

    // On-link: the peer itself is the resolution target.
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 64, 7 }, &next_hop(.{ 192, 168, 64, 7 }));
    // Off-link: the derived gateway.
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 64, 1 }, &next_hop(.{ 1, 1, 1, 1 }));
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 64, 1 }, &next_hop(.{ 93, 184, 216, 34 }));

    // Unroutable shapes never take the gateway: broadcast, multicast,
    // loopback, the 0/8 this-host block.
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, &next_hop(.{ 255, 255, 255, 255 }));
    try std.testing.expectEqualSlices(u8, &.{ 224, 0, 0, 1 }, &next_hop(.{ 224, 0, 0, 1 }));
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &next_hop(.{ 127, 0, 0, 1 }));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &next_hop(.{ 0, 0, 0, 0 }));

    // No gateway (the derived .1 is our own address — the test-net case):
    // an off-link destination resolves itself — the pre-next-hop
    // exact-peer behaviour, honestly unresolved without proxy-ARP.
    own_ip = .{ 10, 0, 0, 1 };
    try std.testing.expectEqualSlices(u8, &.{ 8, 8, 8, 8 }, &next_hop(.{ 8, 8, 8, 8 }));

    // No IP at all: literal always.
    own_ip = .{ 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, &.{ 8, 8, 8, 8 }, &next_hop(.{ 8, 8, 8, 8 }));
}

test "arp: lookup — off-subnet returns the gateway's MAC, on-subnet stays exact" {
    reset_route_state();
    defer reset_route_state();

    const gw_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x64, 0x01 };
    const peer_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x64, 0x07 };
    own_ip = .{ 192, 168, 64, 5 };

    // Learn the gateway (an ARP reply for 192.168.64.1) and one on-link
    // peer — the off-subnet destination now resolves to the router's MAC.
    upsert(.{ 192, 168, 64, 1 }, gw_mac);
    upsert(.{ 192, 168, 64, 7 }, peer_mac);
    try std.testing.expectEqualSlices(u8, &gw_mac, &lookup(.{ 1, 1, 1, 1 }).?);
    try std.testing.expectEqualSlices(u8, &peer_mac, &lookup(.{ 192, 168, 64, 7 }).?);

    // An explicit gateway re-points the next hop honestly.
    const gw2_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x64, 0xfe };
    gateway = .{ 192, 168, 64, 254 };
    upsert(.{ 192, 168, 64, 254 }, gw2_mac);
    try std.testing.expectEqualSlices(u8, &gw2_mac, &lookup(.{ 1, 1, 1, 1 }).?);
    gateway = .{ 0, 0, 0, 0 };

    // The gateway's own address still resolves exactly (it IS on-link).
    try std.testing.expectEqualSlices(u8, &gw_mac, &lookup(.{ 192, 168, 64, 1 }).?);
}

test "arp: no gateway — lookup keeps the exact-peer behaviour" {
    reset_route_state();
    defer reset_route_state();

    // The test-net shape: our address is the derived first host, so no
    // gateway exists — an off-subnet lookup misses exactly as before.
    own_ip = .{ 10, 0, 0, 1 };
    try std.testing.expect(lookup(.{ 8, 8, 8, 8 }) == null);

    // On-link lookups are unaffected either way.
    const host_mac2 = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 };
    upsert(.{ 10, 0, 0, 2 }, host_mac2);
    try std.testing.expectEqualSlices(u8, &host_mac2, &lookup(.{ 10, 0, 0, 2 }).?);
}
