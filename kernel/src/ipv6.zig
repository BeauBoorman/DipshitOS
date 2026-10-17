//! IPv6 (RFC 8200) + ICMPv6 echo (RFC 4443) over the card-N3 raw-Ethernet
//! seam — M117b (issue #2474, ADR 0057). PURE protocol logic (header
//! parse/build, the address set, the ICMPv6 pseudo-header checksum,
//! counters) + host tests, the fat.zig pattern; virtio_net.zig wires it
//! to the transport (the RX drain dispatches ethertype 0x86dd here,
//! BESIDE the N3/N4 dispatch, and the N1 `net_send` TX path transmits
//! the replies it builds). ndp.zig carries the NDP half (NS/NA/RS/RA,
//! the neighbor table, DAD) — this module dispatches ICMPv6 types
//! 133/134/135/136/137 into it.
//!
//! Honest bounds (ADR 0057): ONE interface identifier (the modified
//! EUI-64 of the device MAC), at most TWO owned addresses (the
//! link-local + one SLAAC global), terminal next-headers only — no
//! extension-header walk and no reassembly, ever (hop-by-hop, routing,
//! fragment, destination-options, AH/ESP are counted drops), ICMPv6
//! echo + the NDP carry only (every other type counted), no DHCPv6, no
//! forwarding — the guest is a host, not a router.

const std = @import("std");
const ndp = @import("ndp.zig"); // M117b: the NDP half — types 133-137 dispatch into it

pub const ethertype_ipv6: u16 = 0x86dd; // Ethernet II ethertype
pub const eth_hdr_len: usize = 14; // dst MAC (6) + src MAC (6) + ethertype (2)
pub const ipv6_hdr_len: usize = 40; // the fixed header — no options exist
pub const icmpv6_hdr_len: usize = 8; // type + code + checksum + id + seq (echo shape)
pub const nexthdr_icmpv6: u8 = 58;
pub const nexthdr_udp: u8 = 17;
pub const nexthdr_tcp: u8 = 6;
pub const icmpv6_echo_request: u8 = 128;
pub const icmpv6_echo_reply: u8 = 129;
/// Hop limit for echo traffic. NDP/RA messages pin 255 in both
/// directions (D5); echo is transport traffic, not NDP.
pub const hop_default: u8 = 64;

/// The smallest IPv6/ICMPv6 frame: 14 + 40 + 8 (echo, no payload).
pub const ipv6_frame_min: usize = eth_hdr_len + ipv6_hdr_len + icmpv6_hdr_len; // 62

pub const Addr = [16]u8;

pub const addr_unspecified: Addr = @splat(0); // ::
pub const addr_loopback: Addr = blk: {
    var a: Addr = @splat(0);
    a[15] = 0x01;
    break :blk a;
};
pub const all_nodes: Addr = blk: {
    var a: Addr = @splat(0);
    a[0] = 0xff;
    a[1] = 0x02;
    a[15] = 0x01;
    break :blk a;
};
pub const all_routers: Addr = blk: {
    var a: Addr = @splat(0);
    a[0] = 0xff;
    a[1] = 0x02;
    a[15] = 0x02;
    break :blk a;
};

/// The all-nodes Ethernet multicast (ff02::1 — where RAs arrive).
pub const all_nodes_mac = [6]u8{ 0x33, 0x33, 0x00, 0x00, 0x00, 0x01 };
/// The all-routers Ethernet multicast (ff02::2 — where RSs go).
pub const all_routers_mac = [6]u8{ 0x33, 0x33, 0x00, 0x00, 0x00, 0x02 };

// ---------------------------------------------------------------------------
// Counters (the `net` report's v6 lines) — every drop is counted, never
// assumed away.
// ---------------------------------------------------------------------------

pub var received: u64 = 0; // IPv6 frames handed to this layer
pub var dropped_short: u64 = 0; // too short for the fixed header / version != 6
pub var dropped_len: u64 = 0; // jumbogram (payload_len 0), length not covered, hop_limit 0
pub var dropped_nexthdr: u64 = 0; // non-terminal next-header (D7 — no extension walk)
pub var dropped_dst: u64 = 0; // dst not an owned address / all-nodes / our SNM group
pub var dropped_checksum: u64 = 0; // ICMPv6 pseudo-header checksum mismatch
pub var dropped_proto: u64 = 0; // terminal UDP/TCP — transport over v6 is M117c
pub var dropped_type: u64 = 0; // ICMPv6 types outside the pinned dispatch
pub var icmp6_err: u64 = 0; // types 1-4 (errors) — recorded, never acted on (no PMTUD)
pub var replies_sent: u64 = 0; // echo replies to requests for our addresses
pub var requests_sent: u64 = 0; // `net ping6` echo requests transmitted
pub var pongs_observed: u64 = 0; // echo replies received (the ping6's pong)
pub var reply_tx_fail: u64 = 0; // replies we built but could not transmit
/// The last observed reply sequence (the ping6 proof, the v4 `last_seq`
/// shape).
pub var last_seq: u16 = 0;
/// Echo identifier + sequence counters for `net ping6` (deterministic
/// start at 1 — the live gate's byte-exact fixtures pin them).
pub var ping6_id: u16 = 1;
pub var ping6_seq: u16 = 1;

// ---------------------------------------------------------------------------
// The address model (ADR 0057 D3): one IID, at most two addresses
// ---------------------------------------------------------------------------

/// The address state per D3/D5: tentative until its one DAD probe goes
/// unanswered, valid after, conflicted forever on a DAD conflict (the
/// ADR's "never leaves tentative" — a distinct tag so promotion can
/// never resurrect it).
pub const AddrState = enum { none, tentative, valid, conflicted };

/// The ONE interface identifier — the modified EUI-64 of the device MAC.
pub var iid: [8]u8 = @splat(0);
pub var have_iid: bool = false;

/// fe80::/10 + IID — the always-present address, formed when the device
/// MAC is known (feature negotiation), tentative until DAD.
pub var link_local: Addr = @splat(0);
pub var link_local_state: AddrState = .none;

/// The ONE SLAAC global — prefix::IID from the first accepted RA's first
/// autonomous /64 PIO (D4), tentative until DAD.
pub var global: Addr = @splat(0);
pub var global_state: AddrState = .none;

/// The ONE router record (D4): the accepted RA's link-local source +
/// its last-seen router lifetime (0 = recorded but not a router — the
/// honest withdrawal).
pub var router_valid: bool = false;
pub var router_addr: Addr = @splat(0);
pub var router_lifetime: u16 = 0;

/// The on-link prefix (D9): set when the global-forming PIO carried the
/// L flag. Nothing else makes a prefix on-link — a foreign RA's L-flag
/// PIO never reaches here (`ra_foreign`).
pub var onlink_valid: bool = false;
pub var onlink_prefix: Addr = @splat(0);
pub var onlink_len: u8 = 0;

// ---------------------------------------------------------------------------
// Address helpers (pure — the host tests pin them)
// ---------------------------------------------------------------------------

/// D3: the modified EUI-64 IID of a MAC — mac[0] ^ 0x02 (the
/// universal/local bit flip) · mac[1..3] · ff:fe · mac[3..6].
/// Deterministic and gate-assertable: the hermetic guest MAC
/// 02:00:00:00:00:01 yields 0000:00ff:fe00:0001 (link-local
/// fe80::ff:fe00:1).
pub fn iid_from_mac(mac: *const [6]u8) [8]u8 {
    return .{ mac[0] ^ 0x02, mac[1], mac[2], 0xff, 0xfe, mac[3], mac[4], mac[5] };
}

pub fn is_multicast(a: Addr) bool {
    return a[0] == 0xff;
}

/// fe80::/10 — the link-local scope.
pub fn is_link_local(a: Addr) bool {
    return a[0] == 0xfe and (a[1] & 0xc0) == 0x80;
}

pub fn is_unspecified(a: Addr) bool {
    return std.mem.eql(u8, &a, &addr_unspecified);
}

pub fn is_loopback(a: Addr) bool {
    return std.mem.eql(u8, &a, &addr_loopback);
}

/// Destinations the guest never originates (D9): multicast, the
/// unspecified address, loopback — the `bad_dst6` refusal.
pub fn is_bad_dst(a: Addr) bool {
    return is_multicast(a) or is_unspecified(a) or is_loopback(a);
}

/// Whether `addr` matches `prefix` under `len` leading bits (0..128).
pub fn prefix_match(addr: Addr, prefix: Addr, len: u8) bool {
    if (len > 128) return false;
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        const rem = len -| (i * 8);
        if (rem == 0) return true;
        if (rem >= 8) {
            if (addr[i] != prefix[i]) return false;
        } else {
            const mask: u8 = @as(u8, 0xff) << @intCast(8 - rem);
            return (addr[i] & mask) == (prefix[i] & mask);
        }
    }
    return true;
}

/// The solicited-node multicast group of `addr`: ff02::1:ffXX:XXXX —
/// the low 24 bits of the address.
pub fn snm_addr(addr: *const Addr) Addr {
    var a: Addr = @splat(0);
    a[0] = 0xff;
    a[1] = 0x02;
    a[11] = 0x01;
    a[12] = 0xff;
    a[13] = addr[13];
    a[14] = addr[14];
    a[15] = addr[15];
    return a;
}

/// Its Ethernet multicast: 33:33:ff:xx:xx:xx — the low 24 bits.
pub fn snm_mac(addr: *const Addr) [6]u8 {
    return .{ 0x33, 0x33, 0xff, addr[13], addr[14], addr[15] };
}

/// Whether `addr` is our solicited-node group (D2: the SNM of every
/// formed-or-tentative address — they all share the IID, so ONE group
/// covers the address set).
pub fn is_our_snm(addr: *const Addr) bool {
    if (!have_iid) return false;
    const s = snm_addr(&link_local); // the IID's low 24 — shared by every address
    return std.mem.eql(u8, addr, &s);
}

// ---------------------------------------------------------------------------
// Address formation + state (D3/D5)
// ---------------------------------------------------------------------------

/// D3: form the link-local (fe80::/10 + IID) — tentative until its DAD
/// probe goes unanswered. Called once when the device MAC is known
/// (feature negotiation); idempotent — a transport rearm does not
/// re-tentative a live address.
pub fn form_link_local(mac: *const [6]u8) void {
    if (have_iid) return;
    iid = iid_from_mac(mac);
    have_iid = true;
    var a: Addr = @splat(0);
    a[0] = 0xfe;
    a[1] = 0x80;
    @memcpy(a[8..16], &iid);
    link_local = a;
    link_local_state = .tentative;
}

/// D3: form the ONE SLAAC global — `prefix`'s high 8 bytes + the IID.
/// Tentative until DAD (D5). Called by ndp.handle_ra only when the
/// global slot is empty (one global, ever).
pub fn form_global(prefix: *const Addr) void {
    var a = prefix.*;
    @memcpy(a[8..16], &iid);
    global = a;
    global_state = .tentative;
}

/// D5: the one DAD probe went unanswered for its bounded wait — the
/// tentative address becomes usable. Returns false when the address was
/// not tentative (a conflicted address is never resurrected).
pub fn promote(addr: *const Addr) bool {
    if (link_local_state == .tentative and std.mem.eql(u8, &link_local, addr)) {
        link_local_state = .valid;
        return true;
    }
    if (global_state == .tentative and std.mem.eql(u8, &global, addr)) {
        global_state = .valid;
        return true;
    }
    return false;
}

/// D5: a peer's NS/NA claimed the tentative target — mark it conflicted;
/// it never becomes usable and the guest keeps running (a named
/// refusal, not a panic).
pub fn mark_conflicted(addr: *const Addr) void {
    if (link_local_state == .tentative and std.mem.eql(u8, &link_local, addr)) link_local_state = .conflicted;
    if (global_state == .tentative and std.mem.eql(u8, &global, addr)) global_state = .conflicted;
}

/// Whether `addr` is OWNED: formed and past DAD. A tentative or
/// conflicted address is not owned — it cannot source packets and an NS
/// for it is never answered.
pub fn is_owned(addr: *const Addr) bool {
    return (link_local_state == .valid and std.mem.eql(u8, &link_local, addr)) or
        (global_state == .valid and std.mem.eql(u8, &global, addr));
}

/// Whether `addr` is a tentative target we are DAD-probing — a peer's
/// NS or NA for it is a conflict.
pub fn is_tentative(addr: *const Addr) bool {
    return (link_local_state == .tentative and std.mem.eql(u8, &link_local, addr)) or
        (global_state == .tentative and std.mem.eql(u8, &global, addr));
}

/// D3 source selection: NDP and link-local destinations send from the
/// link-local; everything else sends from the global. A non-link-local
/// destination with no valid global refuses `no_src6` — an honest
/// refusal, never a silent link-local leak.
pub fn select_src(dst: *const Addr) ?Addr {
    if (is_link_local(dst.*)) {
        if (link_local_state == .valid) return link_local;
        return null;
    }
    if (global_state == .valid) return global;
    return null;
}

/// D9 on-link test: fe80::/10 is always on-link; otherwise the L-flag
/// PIO prefix D4 recorded.
pub fn on_link(dst: *const Addr) bool {
    if (is_link_local(dst.*)) return true;
    return onlink_valid and prefix_match(dst.*, onlink_prefix, onlink_len);
}

/// D9 next hop: an on-link destination resolves itself; an off-link one
/// resolves the ROUTER's link-local (the ARP next-hop precedent — the
/// wire asks for the next hop, never the literal peer). Off-link with
/// no router is null — the caller refuses `no_route6`.
pub fn next_hop(dst: *const Addr) ?Addr {
    if (on_link(dst)) return dst.*;
    if (router_valid and router_lifetime > 0) return router_addr;
    return null;
}

// ---------------------------------------------------------------------------
// Text form (parse + format — monitor and gate surfaces)
// ---------------------------------------------------------------------------

/// Parse an IPv6 literal — full `x:x:x:x:x:x:x:x` or `::`-compressed
/// (RFC 4291). No zone ids, no embedded v4, 1-4 hex digits per group,
/// `::` at most once. Returns null on any malformed component.
pub fn parse_ip6(text: []const u8) ?Addr {
    var out: Addr = @splat(0);
    if (text.len == 0) return null;
    var left: [16]u8 = @splat(0);
    var right: [16]u8 = @splat(0);
    // Split on "::" once, then parse each side's colon-separated groups.
    var left_text = text;
    var right_text: []const u8 = "";
    const compressed = std.mem.indexOf(u8, text, "::") != null;
    if (compressed) {
        const c = std.mem.indexOf(u8, text, "::").?;
        left_text = text[0..c];
        right_text = text[c + 2 ..];
        if (std.mem.indexOf(u8, right_text, "::") != null) return null; // "::" twice
    }
    const lgroups = parse_groups(left_text, &left) orelse return null;
    const rgroups = parse_groups(right_text, &right) orelse return null;
    const left_n = lgroups * 2;
    const right_n = rgroups * 2;
    if (lgroups + rgroups > 8) return null;
    // Without "::" the literal must carry all 8 groups; with it the
    // elided middle is zero-filled (lgroups + rgroups <= 8).
    if (!compressed and lgroups != 8) return null;
    @memcpy(out[0..left_n], left[0..left_n]);
    @memcpy(out[16 - right_n .. 16], right[0..right_n]);
    return out;
}

/// Parse one side's `g:g:g` group list into consecutive 2-byte groups at
/// `out[0..]`. Empty text parses to 0 groups. Returns the group count or
/// null on a malformed group (empty, >4 digits, non-hex).
fn parse_groups(text: []const u8, out: *[16]u8) ?usize {
    if (text.len == 0) return 0;
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == ':') {
            const glen = i - start;
            if (glen == 0 or glen > 4) return null;
            if (n >= 8) return null;
            var v: u16 = 0;
            var j = start;
            while (j < i) : (j += 1) {
                const c = text[j];
                const d: u16 = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else if (c >= 'A' and c <= 'F') c - 'A' + 10 else return null;
                v = (v << 4) | d;
            }
            out[n * 2] = @truncate(v >> 8);
            out[n * 2 + 1] = @truncate(v);
            n += 1;
            start = i + 1;
        }
    }
    return n;
}

/// Format an IPv6 address into `out` (must hold >= 39 bytes) with
/// RFC 5952-style compression: lowercase hex, no leading zeros, the
/// longest zero run of >= 2 groups elided to `::` (the first run wins
/// ties). Deterministic — the live gate asserts the text.
pub fn format_ip6(addr: Addr, out: *[39]u8) usize {
    var groups: [8]u16 = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) groups[i] = (@as(u16, addr[i * 2]) << 8) | addr[i * 2 + 1];
    // The longest zero run of >= 2 groups (first wins ties).
    var best_start: usize = 8;
    var best_len: usize = 0;
    i = 0;
    while (i < 8) {
        if (groups[i] != 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < 8 and groups[j] == 0) j += 1;
        if (j - i > best_len) {
            best_start = i;
            best_len = j - i;
        }
        i = j;
    }
    if (best_len < 2) best_len = 0; // a single zero group is not elided
    var n: usize = 0;
    const hex = "0123456789abcdef";
    i = 0;
    var first = true;
    while (i < 8) {
        if (best_len > 0 and i == best_start) {
            // "::" carries both separators — the next group prints with
            // no leading ':' (leading, middle and trailing elisions all
            // land correctly).
            out[n] = ':';
            n += 1;
            out[n] = ':';
            n += 1;
            i += best_len;
            first = true;
            continue;
        }
        if (!first) {
            out[n] = ':';
            n += 1;
        }
        var v = groups[i];
        if (v == 0) {
            out[n] = '0';
            n += 1;
        } else {
            var digits: [4]u8 = undefined;
            var dn: usize = 0;
            while (v != 0) {
                digits[dn] = hex[v & 0xf];
                dn += 1;
                v >>= 4;
            }
            while (dn > 0) {
                dn -= 1;
                out[n] = digits[dn];
                n += 1;
            }
        }
        first = false;
        i += 1;
    }
    // A trailing "::" run: the elision already emitted the pair; a
    // run at the very start also emitted "::". Nothing to pad.
    return n;
}

// ---------------------------------------------------------------------------
// The ICMPv6 pseudo-header checksum (RFC 8200 §8.1)
// ---------------------------------------------------------------------------

/// One's-complement checksum over the v6 pseudo-header (16-byte src +
/// dst, the 32-bit upper-layer length, 3 zero bytes + next-header) and
/// `msg`. Always verified inbound and always computed outbound — v6 has
/// no zero escape (the udp.zig always-compute posture).
pub fn icmp6_checksum(src: *const Addr, dst: *const Addr, msg: []const u8, nexthdr: u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < 16) : (i += 2) {
        sum += (@as(u32, src[i]) << 8) | src[i + 1];
        sum += (@as(u32, dst[i]) << 8) | dst[i + 1];
    }
    const len32: u32 = @intCast(msg.len);
    sum += len32 >> 16;
    sum += len32 & 0xffff;
    sum += nexthdr;
    i = 0;
    while (i + 1 < msg.len) : (i += 2) {
        sum += (@as(u32, msg[i]) << 8) | msg[i + 1];
    }
    if (i < msg.len) sum += @as(u32, msg[i]) << 8; // trailing odd byte
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

// ---------------------------------------------------------------------------
// Frame field accessors (the frame starts at the Ethernet header)
// ---------------------------------------------------------------------------

/// The Ethernet II ethertype (0 if too short).
pub fn ethertype(frame: []const u8) u16 {
    if (frame.len < 14) return 0;
    return (@as(u16, frame[12]) << 8) | frame[13];
}

/// The fixed header's payload length field (0 if too short).
pub fn payload_len(frame: []const u8) u16 {
    if (frame.len < eth_hdr_len + ipv6_hdr_len) return 0;
    return std.mem.readInt(u16, frame[18..20], .big);
}

pub fn next_header(frame: []const u8) u8 {
    if (frame.len < eth_hdr_len + ipv6_hdr_len) return 0;
    return frame[20];
}

pub fn hop_limit(frame: []const u8) u8 {
    if (frame.len < eth_hdr_len + ipv6_hdr_len) return 0;
    return frame[21];
}

pub fn src_addr(frame: []const u8) Addr {
    var a: Addr = undefined;
    @memcpy(&a, frame[22..38]);
    return a;
}

pub fn dst_addr(frame: []const u8) Addr {
    var a: Addr = undefined;
    @memcpy(&a, frame[38..54]);
    return a;
}

/// The ICMPv6 type (0xff for a short frame).
pub fn icmp_type(frame: []const u8) u8 {
    if (frame.len < ipv6_frame_min) return 0xff;
    return frame[54];
}

/// The echo identifier (0 for a short frame).
pub fn icmp_id(frame: []const u8) u16 {
    if (frame.len < ipv6_frame_min) return 0;
    return std.mem.readInt(u16, frame[58..60], .big);
}

/// The echo sequence (0 for a short frame).
pub fn icmp_seq(frame: []const u8) u16 {
    if (frame.len < ipv6_frame_min) return 0;
    return std.mem.readInt(u16, frame[60..62], .big);
}

// ---------------------------------------------------------------------------
// Builders (byte-exact, RFC-shaped; the live gate's fixtures pin them)
// ---------------------------------------------------------------------------

/// The shared frame prefix: Ethernet dst/src + the 40-byte fixed header
/// (version 6, TC/flow zero, payload_len, next-header, hop_limit,
/// src, dst). The whole frame is zeroed first — reserved and checksum
/// fields start at 0. The message follows at offset 54.
fn build_hdr(buf: []u8, dst_mac: *const [6]u8, own_mac: *const [6]u8, src: *const Addr, dst: *const Addr, nexthdr: u8, hop: u8, plen: u16) void {
    @memset(buf[0 .. eth_hdr_len + ipv6_hdr_len + plen], 0);
    @memcpy(buf[0..6], dst_mac);
    @memcpy(buf[6..12], own_mac);
    buf[12] = 0x86;
    buf[13] = 0xdd;
    buf[14] = 0x60; // version 6, TC/flow-label zero
    std.mem.writeInt(u16, buf[18..20], plen, .big);
    buf[20] = nexthdr;
    buf[21] = hop;
    @memcpy(buf[22..38], src);
    @memcpy(buf[38..54], dst);
}

/// Build an ICMPv6 ECHO REQUEST to `dst` at `peer_mac` (dst = the peer's
/// MAC — already the next-hop resolution; src = D3's source selection,
/// resolved by the caller; the id/seq from the `net ping6` counters;
/// payload bytes 01 02 03 04 — the ipv4 fixture shape, gate-assertable).
/// `buf` must hold >= `ipv6_frame_min + 4`. Returns the frame length (66).
pub fn build_echo_request(buf: []u8, own_mac: *const [6]u8, src: *const Addr, dst: *const Addr, peer_mac: *const [6]u8) usize {
    const plen: u16 = icmpv6_hdr_len + 4;
    const frame_len = eth_hdr_len + ipv6_hdr_len + plen;
    build_hdr(buf, peer_mac, own_mac, src, dst, nexthdr_icmpv6, hop_default, plen);
    const icmp = buf[54 .. 54 + plen];
    icmp[0] = icmpv6_echo_request;
    std.mem.writeInt(u16, icmp[4..6], ping6_id, .big);
    std.mem.writeInt(u16, icmp[6..8], ping6_seq, .big);
    icmp[8] = 0x01;
    icmp[9] = 0x02;
    icmp[10] = 0x03;
    icmp[11] = 0x04;
    const chk = icmp6_checksum(src, dst, icmp, nexthdr_icmpv6);
    std.mem.writeInt(u16, icmp[2..4], chk, .big);
    return frame_len;
}

/// Build an ICMPv6 ECHO REPLY to the echo request in `req` (the received
/// frame): Ethernet dst/src swapped (dst = the requester's MAC), v6
/// src = `src` (the caller's select_src answer for the request's src),
/// dst = the requester's address, hop 64, the identifier + sequence +
/// payload echoed BYTE-EXACT, the pseudo-header checksum recomputed.
/// `buf` must hold >= the request's frame length. Returns the frame
/// length (same as the request's) or 0 if it would not fit.
pub fn build_echo_reply(buf: []u8, own_mac: *const [6]u8, src: *const Addr, req: []const u8) usize {
    const frame_len = req.len;
    if (frame_len < ipv6_frame_min or frame_len > buf.len) return 0;
    const plen = payload_len(req);
    const req_src = src_addr(req);
    var dst_mac: [6]u8 = undefined;
    @memcpy(&dst_mac, req[6..12]);
    build_hdr(buf, &dst_mac, own_mac, src, &req_src, nexthdr_icmpv6, hop_default, plen);
    const icmp = buf[54 .. 54 + plen];
    icmp[0] = icmpv6_echo_reply;
    @memcpy(icmp[4..plen], req[58 .. 54 + plen]); // id + seq + payload echoed
    const chk = icmp6_checksum(src, &req_src, icmp, nexthdr_icmpv6);
    std.mem.writeInt(u16, icmp[2..4], chk, .big);
    return frame_len;
}

// ---------------------------------------------------------------------------
// RX dispatch (the caller MAC-filtered the frame and passes it WITHOUT the
// RX virtio_net_hdr — the Ethernet header starts at byte 0)
// ---------------------------------------------------------------------------

/// What the drain does with a reply built into `reply_buf`: an echo
/// reply counts `replies_sent`, an NA counts `ndp.na_sent` (and the
/// failure legs mirror them).
pub const RxReply = struct {
    len: usize,
    na: bool = false,
};

/// Process one received Ethernet frame. Returns a reply built into
/// `reply_buf` (an ICMPv6 echo request for an owned address, or an NS
/// for an owned target — the caller transmits it), or null (not IPv6 /
/// observed / a counted drop). Every drop is counted by cause.
pub fn handle_rx(frame: []const u8, own_mac: *const [6]u8, reply_buf: []u8) ?RxReply {
    if (ethertype(frame) != ethertype_ipv6) return null; // not our concern
    received += 1;
    if (frame.len < eth_hdr_len + ipv6_hdr_len) {
        dropped_short += 1;
        return null;
    }
    if (frame[14] >> 4 != 6) {
        dropped_short += 1;
        return null;
    }
    const plen = payload_len(frame);
    // D7: a zero-payload_len jumbogram and a length the bytes present do
    // not cover are counted drops — as is a hop_limit of 0.
    if (plen == 0 or frame.len < eth_hdr_len + ipv6_hdr_len + plen or hop_limit(frame) == 0) {
        dropped_len += 1;
        return null;
    }
    const nh = next_header(frame);
    // D7: terminal next-headers only — no extension-header walk, ever.
    if (nh != nexthdr_icmpv6 and nh != nexthdr_udp and nh != nexthdr_tcp) {
        dropped_nexthdr += 1;
        return null;
    }
    if (nh != nexthdr_icmpv6) {
        dropped_proto += 1; // UDP/TCP over v6 is M117c's surface
        return null;
    }
    const dst = dst_addr(frame);
    // The dst gate (the M97e-F2 shape translated): an owned address,
    // all-nodes, or our solicited-node group — a packet addressed
    // elsewhere never reaches a protocol handler.
    if (!is_owned(&dst) and !std.mem.eql(u8, &dst, &all_nodes) and !is_our_snm(&dst)) {
        dropped_dst += 1;
        return null;
    }
    const src = src_addr(frame);
    const msg = frame[54 .. 54 + plen];
    // The pseudo-header checksum is verified inbound for every ICMPv6
    // message (D6 — no zero escape).
    if (icmp6_checksum(&src, &dst, msg, nh) != 0x0000) {
        dropped_checksum += 1;
        return null;
    }
    const t = icmp_type(frame);
    switch (t) {
        icmpv6_echo_request => {
            // Only an echo for an OWNED address is answered — never a
            // multicast-addressed one (the v4 foreign-dst rule).
            if (!is_owned(&dst)) {
                dropped_dst += 1;
                return null;
            }
            const rsrc = select_src(&src) orelse {
                dropped_dst += 1;
                return null;
            };
            const n = build_echo_reply(reply_buf, own_mac, &rsrc, frame);
            if (n == 0) {
                dropped_dst += 1;
                return null;
            }
            return .{ .len = n };
        },
        icmpv6_echo_reply => {
            pongs_observed += 1; // the ping6's pong — observe, don't forward
            last_seq = icmp_seq(frame);
            return null;
        },
        else => {},
    }
    // The NDP carry (D5/D6): RS/RA/NS/NA/Redirect — every NDP message
    // requires hop_limit == 255 inbound (the standing off-link-forgery
    // check).
    if (t == ndp.icmpv6_rs or t == ndp.icmpv6_ra or t == ndp.icmpv6_ns or t == ndp.icmpv6_na or t == ndp.icmpv6_redirect) {
        if (hop_limit(frame) != 255) {
            ndp.ndp_drop += 1;
            return null;
        }
    }
    switch (t) {
        ndp.icmpv6_rs => {
            ndp.rs_dropped += 1; // the guest is a host — solicitations are never answered
            return null;
        },
        ndp.icmpv6_ra => {
            ndp.handle_ra(frame);
            return null;
        },
        ndp.icmpv6_ns => {
            const n = ndp.handle_ns(frame, own_mac, reply_buf) orelse return null;
            return .{ .len = n, .na = true };
        },
        ndp.icmpv6_na => {
            ndp.handle_na(frame);
            return null;
        },
        ndp.icmpv6_redirect => {
            ndp.redirect_dropped += 1; // the router record is RA-only (D5)
            return null;
        },
        1, 2, 3, 4 => {
            icmp6_err += 1; // recorded, never acted on — no PMTUD machinery (D6)
            return null;
        },
        else => {
            dropped_type += 1;
            return null;
        },
    }
}

// ---------------------------------------------------------------------------
// Host tests — pure logic, byte-exact against the RFC fixtures
// ---------------------------------------------------------------------------

const test_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 }; // the host-set guest MAC
const host_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 }; // the host-side MAC
const test_ll = Addr{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0, 0, 0x01 };
const test_g6 = Addr{ 0x20, 0x01, 0x0d, 0xb8, 0, 0x64, 0, 0, 0, 0, 0, 0xff, 0xfe, 0, 0, 0x01 };
const host_ll = Addr{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0, 0, 0x02 };
const host_g6 = Addr{ 0x20, 0x01, 0x0d, 0xb8, 0, 0x64, 0, 0, 0, 0, 0, 0xff, 0xfe, 0, 0, 0x02 };

fn reset() void {
    // Module state is BSS — reset between tests (the arp.zig convention).
    received = 0;
    dropped_short = 0;
    dropped_len = 0;
    dropped_nexthdr = 0;
    dropped_dst = 0;
    dropped_checksum = 0;
    dropped_proto = 0;
    dropped_type = 0;
    icmp6_err = 0;
    replies_sent = 0;
    requests_sent = 0;
    pongs_observed = 0;
    reply_tx_fail = 0;
    last_seq = 0;
    ping6_id = 1;
    ping6_seq = 1;
    iid = @splat(0);
    have_iid = false;
    link_local = @splat(0);
    link_local_state = .none;
    global = @splat(0);
    global_state = .none;
    router_valid = false;
    router_addr = @splat(0);
    router_lifetime = 0;
    onlink_valid = false;
    onlink_prefix = @splat(0);
    onlink_len = 0;
}

fn form_pair() void {
    // The hermetic fixture: link-local + global both valid past DAD.
    form_link_local(&test_mac);
    _ = promote(&link_local);
    const prefix = Addr{ 0x20, 0x01, 0x0d, 0xb8, 0, 0x64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    form_global(&prefix);
    _ = promote(&global);
}

test "ipv6: modified EUI-64 + link-local + solicited-node derivations" {
    reset();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0xff, 0xfe, 0x00, 0x00, 0x01 }, &iid_from_mac(&test_mac));
    form_link_local(&test_mac);
    try std.testing.expect(have_iid);
    try std.testing.expectEqualSlices(u8, &test_ll, &link_local);
    try std.testing.expect(link_local_state == .tentative);
    try std.testing.expect(!is_owned(&link_local));
    try std.testing.expect(is_tentative(&link_local));
    // The solicited-node group of every address shares the IID's low 24:
    // ff02::1:ff00:0001 -> 33:33:ff:00:00:01.
    const snm = snm_addr(&link_local);
    try std.testing.expectEqual(@as(u8, 0xff), snm[0]);
    try std.testing.expectEqual(@as(u8, 0x02), snm[1]);
    try std.testing.expectEqual(@as(u8, 0x01), snm[11]);
    try std.testing.expectEqual(@as(u8, 0xff), snm[12]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x33, 0x33, 0xff, 0x00, 0x00, 0x01 }, &snm_mac(&link_local));
    try std.testing.expect(is_our_snm(&snm));
    // Forming twice is idempotent.
    form_link_local(&host_mac);
    try std.testing.expectEqualSlices(u8, &test_ll, &link_local);
    // Promote: tentative -> valid; a second promote refuses.
    try std.testing.expect(promote(&link_local));
    try std.testing.expect(is_owned(&link_local));
    try std.testing.expect(!promote(&link_local));
}

test "ipv6: parse + format round-trip (full, compressed, malformed)" {
    reset();
    const cases = [_]struct { text: []const u8, addr: Addr }{
        .{ .text = "fe80::ff:fe00:1", .addr = test_ll },
        .{ .text = "2001:db8:64::ff:fe00:1", .addr = test_g6 },
        .{ .text = "fe80:0:0:0:0:ff:fe00:1", .addr = test_ll },
        .{ .text = "::", .addr = addr_unspecified },
        .{ .text = "::1", .addr = addr_loopback },
        .{ .text = "ff02::1", .addr = all_nodes },
        .{ .text = "2001:0db8:0064:0000:0000:00ff:fe00:0001", .addr = test_g6 },
    };
    var buf: [39]u8 = undefined;
    for (cases) |c| {
        const a = parse_ip6(c.text) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualSlices(u8, &c.addr, &a);
    }
    // Format pins the canonical text.
    var n = format_ip6(test_ll, &buf);
    try std.testing.expectEqualSlices(u8, "fe80::ff:fe00:1", buf[0..n]);
    n = format_ip6(test_g6, &buf);
    try std.testing.expectEqualSlices(u8, "2001:db8:64::ff:fe00:1", buf[0..n]);
    n = format_ip6(addr_unspecified, &buf);
    try std.testing.expectEqualSlices(u8, "::", buf[0..n]);
    n = format_ip6(addr_loopback, &buf);
    try std.testing.expectEqualSlices(u8, "::1", buf[0..n]);
    n = format_ip6(all_nodes, &buf);
    try std.testing.expectEqualSlices(u8, "ff02::1", buf[0..n]);
    // A single zero group is not elided; the first longest run wins ties.
    const one_zero = parse_ip6("2001:db8:0:1:2:3:4:5").?;
    n = format_ip6(one_zero, &buf);
    try std.testing.expectEqualSlices(u8, "2001:db8:0:1:2:3:4:5", buf[0..n]);
    // Malformed inputs refuse.
    try std.testing.expect(parse_ip6("") == null);
    try std.testing.expect(parse_ip6("fe80") == null); // no "::" needs 8 groups
    try std.testing.expect(parse_ip6("fe80::ff::1") == null); // "::" twice
    try std.testing.expect(parse_ip6("fe80::fffff:1") == null); // >4 hex digits
    try std.testing.expect(parse_ip6("fe80::zz:1") == null); // non-hex
    try std.testing.expect(parse_ip6("1:2:3:4:5:6:7:8:9") == null); // too many
    try std.testing.expect(parse_ip6("fe80:::1") == null); // empty group
    try std.testing.expect(parse_ip6(":fe80::1") == null); // leading ':'
}

test "ipv6: prefix_match + classifiers" {
    reset();
    const pfx = parse_ip6("2001:db8:64::").?;
    try std.testing.expect(prefix_match(test_g6, pfx, 64));
    try std.testing.expect(!prefix_match(test_ll, pfx, 64));
    try std.testing.expect(prefix_match(test_g6, pfx, 0)); // /0 matches everything
    try std.testing.expect(!prefix_match(test_g6, pfx, 128));
    const pfx10 = parse_ip6("fe80::").?;
    try std.testing.expect(prefix_match(test_ll, pfx10, 10));
    try std.testing.expect(is_link_local(test_ll));
    try std.testing.expect(is_link_local(parse_ip6("febf::1").?)); // fe80::/10 covers fe80-febf
    try std.testing.expect(!is_link_local(test_g6));
    try std.testing.expect(is_multicast(all_nodes));
    try std.testing.expect(is_unspecified(addr_unspecified));
    try std.testing.expect(is_loopback(addr_loopback));
    try std.testing.expect(is_bad_dst(all_nodes));
    try std.testing.expect(is_bad_dst(addr_unspecified));
    try std.testing.expect(is_bad_dst(addr_loopback));
    try std.testing.expect(!is_bad_dst(test_g6));
}

test "ipv6: select_src + on_link + next_hop (D3/D9)" {
    reset();
    form_pair();
    router_valid = true;
    router_addr = host_ll;
    router_lifetime = 1800;
    onlink_valid = true;
    onlink_prefix = parse_ip6("2001:db8:64::").?;
    onlink_len = 64;
    // Source selection: link-local dst -> ll; global dst -> global.
    try std.testing.expectEqualSlices(u8, &test_ll, &select_src(&host_ll).?);
    try std.testing.expectEqualSlices(u8, &test_g6, &select_src(&host_g6).?);
    // On-link: fe80 always, the L-flag /64 PIO otherwise.
    try std.testing.expect(on_link(&host_ll));
    try std.testing.expect(on_link(&host_g6));
    const off = parse_ip6("2001:db8:99::1").?;
    try std.testing.expect(!on_link(&off));
    // Next hop: on-link resolves itself; off-link the router's ll.
    try std.testing.expectEqualSlices(u8, &host_g6, &next_hop(&host_g6).?);
    try std.testing.expectEqualSlices(u8, &host_ll, &next_hop(&off).?);
    // No router: off-link refuses (null -> no_route6).
    router_lifetime = 0;
    try std.testing.expect(next_hop(&off) == null);
    router_valid = false;
    router_lifetime = 1800;
    try std.testing.expect(next_hop(&off) == null);
    // No global: a non-link-local src refuses (null -> no_src6).
    global_state = .none;
    try std.testing.expect(select_src(&host_g6) == null);
    // Tentative addresses are not sources.
    global_state = .tentative;
    try std.testing.expect(select_src(&host_g6) == null);
    link_local_state = .tentative;
    try std.testing.expect(select_src(&host_ll) == null);
}

test "ipv6: build_echo_request is byte-exact + checksum verifies" {
    reset();
    ping6_id = 1;
    ping6_seq = 1;
    var buf: [ipv6_frame_min + 4]u8 = undefined;
    const n = build_echo_request(&buf, &test_mac, &test_ll, &host_ll, &host_mac);
    try std.testing.expectEqual(@as(usize, 66), n);
    // Ethernet: dst peer, src ours, ethertype 0x86dd.
    try std.testing.expectEqualSlices(u8, &host_mac, buf[0..6]);
    try std.testing.expectEqualSlices(u8, &test_mac, buf[6..12]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x86, 0xdd }, buf[12..14]);
    // v6: version 6, plen 12, nh 58, hop 64, src/dst.
    try std.testing.expectEqual(@as(u8, 0x60), buf[14]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x0c }, buf[18..20]);
    try std.testing.expectEqual(@as(u8, 58), buf[20]);
    try std.testing.expectEqual(@as(u8, 64), buf[21]);
    try std.testing.expectEqualSlices(u8, &test_ll, buf[22..38]);
    try std.testing.expectEqualSlices(u8, &host_ll, buf[38..54]);
    // ICMPv6: type 128, code 0, id 1, seq 1, payload 01 02 03 04.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 128, 0 }, buf[54..56]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 0, 1 }, buf[58..62]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, buf[62..66]);
    // The pseudo-header checksum verifies (a valid checksum folds to 0).
    try std.testing.expectEqual(@as(u16, 0x0000), icmp6_checksum(&test_ll, &host_ll, buf[54..66], nexthdr_icmpv6));
}

test "ipv6: build_echo_reply — swapped, echoed, checksum valid" {
    reset();
    ping6_id = 1;
    ping6_seq = 1;
    var req: [ipv6_frame_min + 4]u8 = undefined;
    _ = build_echo_request(&req, &host_mac, &host_ll, &test_ll, &test_mac);
    var reply: [ipv6_frame_min + 4]u8 = undefined;
    const n = build_echo_reply(&reply, &test_mac, &test_ll, &req);
    try std.testing.expectEqual(@as(usize, 66), n);
    try std.testing.expectEqualSlices(u8, &host_mac, reply[0..6]); // dst = requester
    try std.testing.expectEqualSlices(u8, &test_mac, reply[6..12]);
    try std.testing.expectEqualSlices(u8, &test_ll, reply[22..38]); // src = us
    try std.testing.expectEqualSlices(u8, &host_ll, reply[38..54]); // dst = requester
    try std.testing.expectEqual(@as(u8, 129), reply[54]); // echo reply
    try std.testing.expectEqualSlices(u8, req[58..66], reply[58..66]); // id/seq/payload echoed
    try std.testing.expectEqual(@as(u16, 0x0000), icmp6_checksum(&test_ll, &host_ll, reply[54..66], nexthdr_icmpv6));
}

test "ipv6: classify — bounds, dst gate, echo round trip, dispatch" {
    reset();
    form_pair();
    ping6_id = 1;
    ping6_seq = 1;
    var rbuf: [ipv6_frame_min + 64]u8 = undefined;

    // An echo request for our global is answered.
    var req: [ipv6_frame_min + 4]u8 = undefined;
    _ = build_echo_request(&req, &host_mac, &host_g6, &test_g6, &test_mac);
    const reply = handle_rx(&req, &test_mac, &rbuf).?;
    try std.testing.expectEqual(@as(usize, 66), reply.len);
    try std.testing.expect(!reply.na);
    try std.testing.expectEqual(@as(u64, 1), received);
    try std.testing.expectEqual(@as(u8, 129), rbuf[54]);

    // The reply to our own request is the pong.
    var pong: [ipv6_frame_min + 4]u8 = undefined;
    _ = build_echo_request(&pong, &test_mac, &test_g6, &host_g6, &host_mac);
    var rep2: [ipv6_frame_min + 4]u8 = undefined;
    _ = build_echo_reply(&rep2, &host_mac, &host_g6, &pong);
    try std.testing.expect(handle_rx(&rep2, &test_mac, &rbuf) == null);
    try std.testing.expectEqual(@as(u64, 1), pongs_observed);
    try std.testing.expectEqual(@as(u16, 1), last_seq);

    // An echo for an address we do not own drops counted.
    var foreign = req;
    const not_ours = parse_ip6("2001:db8:64::99").?;
    @memcpy(foreign[38..54], &not_ours);
    // Fix the checksum so the drop cause is the dst gate, not the sum.
    foreign[56] = 0;
    foreign[57] = 0;
    const fsrc = src_addr(&foreign);
    const fchk = icmp6_checksum(&fsrc, &not_ours, foreign[54..66], nexthdr_icmpv6);
    std.mem.writeInt(u16, foreign[56..58], fchk, .big);
    try std.testing.expect(handle_rx(&foreign, &test_mac, &rbuf) == null);
    try std.testing.expectEqual(@as(u64, 1), dropped_dst);

    // A non-v6 ethertype is not our concern (no counter).
    var not6 = req;
    not6[13] = 0x00;
    try std.testing.expect(handle_rx(&not6, &test_mac, &rbuf) == null);
    try std.testing.expectEqual(@as(u64, 3), received);

    // Version != 6 -> dropped_short.
    var badver = req;
    badver[14] = 0x45;
    try std.testing.expect(handle_rx(&badver, &test_mac, &rbuf) == null);
    try std.testing.expectEqual(@as(u64, 1), dropped_short);

    // payload_len 0 (jumbogram) and a covering-fail -> dropped_len.
    var jumbo = req;
    jumbo[18] = 0;
    jumbo[19] = 0;
    try std.testing.expect(handle_rx(&jumbo, &test_mac, &rbuf) == null);
    var short = req;
    short[19] = 0xff; // plen 255 > bytes present
    try std.testing.expect(handle_rx(&short, &test_mac, &rbuf) == null);
    var nohop = req;
    nohop[21] = 0;
    try std.testing.expect(handle_rx(&nohop, &test_mac, &rbuf) == null);
    try std.testing.expectEqual(@as(u64, 3), dropped_len);

    // An extension-header next-header -> dropped_nexthdr (D7).
    var ext = req;
    ext[20] = 0; // hop-by-hop options
    try std.testing.expect(handle_rx(&ext, &test_mac, &rbuf) == null);
    ext[20] = 44; // fragment header — never reassembled
    try std.testing.expect(handle_rx(&ext, &test_mac, &rbuf) == null);
    try std.testing.expectEqual(@as(u64, 2), dropped_nexthdr);

    // Terminal UDP/TCP pass the gate but count as proto (M117c surface).
    var udp6 = req;
    udp6[20] = 17;
    try std.testing.expect(handle_rx(&udp6, &test_mac, &rbuf) == null);
    var tcp6 = req;
    tcp6[20] = 6;
    try std.testing.expect(handle_rx(&tcp6, &test_mac, &rbuf) == null);
    try std.testing.expectEqual(@as(u64, 2), dropped_proto);

    // A corrupted ICMPv6 checksum drops counted.
    var bad = req;
    bad[62] +%= 1;
    try std.testing.expect(handle_rx(&bad, &test_mac, &rbuf) == null);
    try std.testing.expectEqual(@as(u64, 1), dropped_checksum);

    // An unknown ICMPv6 type -> dropped_type; an error type -> icmp6_err.
    var unk = req;
    unk[54] = 200;
    unk[56] = 0;
    unk[57] = 0;
    const usrc = src_addr(&unk);
    const udst = dst_addr(&unk);
    const uchk = icmp6_checksum(&usrc, &udst, unk[54..66], nexthdr_icmpv6);
    std.mem.writeInt(u16, unk[56..58], uchk, .big);
    try std.testing.expect(handle_rx(&unk, &test_mac, &rbuf) == null);
    try std.testing.expectEqual(@as(u64, 1), dropped_type);
    unk[54] = 2; // packet too big — recorded, never acted on
    unk[56] = 0;
    unk[57] = 0;
    const echk = icmp6_checksum(&usrc, &udst, unk[54..66], nexthdr_icmpv6);
    std.mem.writeInt(u16, unk[56..58], echk, .big);
    try std.testing.expect(handle_rx(&unk, &test_mac, &rbuf) == null);
    try std.testing.expectEqual(@as(u64, 1), icmp6_err);
}
