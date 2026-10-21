//! IPv4 (RFC 791) + ICMP echo (RFC 792) over the card-N3 raw-Ethernet
//! seam — milestone five, card N4 (claim 0148). PURE protocol logic
//! (header parse/build, RFC 1071 checksums, ICMP echo request/reply,
//! counters) + host tests, the fat.zig pattern; virtio_net.zig wires it
//! to the transport (the RX drain dispatches ethertype 0x0800 here,
//! BESIDE the N3 ARP dispatch, and the N1 `net_send` TX path transmits
//! the replies/requests it builds).
//!
//! Honest bounds: minimal IPv4 ONLY — no fragmentation (MF / a nonzero
//! offset is DROPPED, counted), no reassembly, no options (IHL must be
//! 5), ICMP echo only (protocol 1, types 8/0 — every other protocol is
//! dropped, counted), IPv4-only, no TCP/UDP/DHCP/DNS (later, sketched
//! only). Our source address is the N3 ARP layer's `arp.own_ip` — there
//! is NO second copy of the static IP.

const std = @import("std");
const arp = @import("arp.zig"); // N3: our static IP (`arp.own_ip` — the ONE copy) + the peer table
const udp = @import("udp.zig"); // N5 (claim 8552): UDP datagrams over the validated IPv4 seam
const tcp = @import("tcp.zig"); // N10 (claim 7026): the bounded TCP client over the validated IPv4 seam
const native_socket = @import("socket_native.zig");

pub const ethertype_ipv4: u16 = 0x0800; // Ethernet II ethertype
pub const eth_hdr_len: usize = 14; // dst MAC (6) + src MAC (6) + ethertype (2)
pub const ipv4_hdr_len: usize = 20; // no options (IHL 5)
pub const icmp_hdr_len: usize = 8; // type + code + checksum + id + seq
pub const protocol_icmp: u8 = 1;
pub const icmp_type_request: u8 = 8;
pub const icmp_type_reply: u8 = 0;
pub const ttl_default: u8 = 64;

/// The smallest IPv4/ICMP frame: 14 + 20 + 8 (no payload).
pub const ipv4_frame_min: usize = eth_hdr_len + ipv4_hdr_len + icmp_hdr_len; // 42

// ---------------------------------------------------------------------------
// Counters (the `net` report) — every drop is counted, never assumed away.
// ---------------------------------------------------------------------------

pub var received: u64 = 0; // IPv4 frames handed to this layer
pub var dropped_short: u64 = 0; // too short for a full IPv4/ICMP shape
pub var dropped_frag: u64 = 0; // MF set or a nonzero fragment offset
pub var dropped_checksum: u64 = 0; // header checksum mismatch
pub var dropped_proto: u64 = 0; // protocol != ICMP
pub var dropped_other: u64 = 0; // an ICMP echo for an address we do not own / other ICMP
pub var replies_sent: u64 = 0; // echo replies to requests for our static IP
pub var requests_sent: u64 = 0; // `net ping` echo requests transmitted
pub var pongs_observed: u64 = 0; // echo replies received (the ping's pong)
pub var reply_tx_fail: u64 = 0; // replies we built but could not transmit (the polled TX path)
/// The last observed reply sequence (the `net` report's seq= — the ping
/// proof: the echo reply echoed THIS sequence back).
pub var last_seq: u16 = 0;
/// Echo identifier + sequence counters for `net ping` (deterministic
/// start at 1 — the live gate's byte-exact fixtures pin them).
pub var ping_id: u16 = 1;
pub var ping_seq: u16 = 1;

// ---------------------------------------------------------------------------
// RFC 1071 one's-complement checksum (big-endian 16-bit words, folded)
// ---------------------------------------------------------------------------

/// One's-complement Internet checksum over `data` (RFC 1071). Odd-length
/// data pads the final byte with zero. The field being checksummed must be
/// zeroed by the caller (the header builders do).
pub fn checksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u32, data[i]) << 8) | data[i + 1];
    }
    if (i < data.len) sum += @as(u32, data[i]) << 8; // trailing odd byte
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

/// Whether the frame is IPv4-shaped: ethertype 0x0800, a 20-byte header
/// (IHL exactly 5 — no options), version 4, and a total length that
/// covers the header.
pub fn is_ipv4(frame: []const u8) bool {
    if (frame.len < ipv4_frame_min) return false;
    if (ethertype(frame) != ethertype_ipv4) return false;
    if (frame[14] != 0x45) return false; // version 4, IHL 5
    const total = (@as(u16, frame[16]) << 8) | frame[17];
    return total >= ipv4_hdr_len;
}

/// Whether the IPv4 header is a FRAGMENT (MF set or a nonzero offset) —
/// N4 does NOT reassemble (honest bound, counted).
pub fn is_fragment(frame: []const u8) bool {
    if (frame.len < eth_hdr_len + ipv4_hdr_len) return false;
    const flags_off = (@as(u16, frame[20]) << 8) | frame[21];
    return (flags_off & 0x3fff) != 0; // MF (0x2000) or a nonzero offset
}

/// Whether the IPv4 header checksum is VALID: the sum over the whole
/// 20-byte header (checksum field included) folds to 0xffff — i.e. the
/// one's-complement `checksum()` of it is 0x0000.
pub fn header_checksum_ok(frame: []const u8) bool {
    if (frame.len < eth_hdr_len + ipv4_hdr_len) return false;
    return checksum(frame[14 .. eth_hdr_len + ipv4_hdr_len]) == 0x0000;
}

pub fn src_ip(frame: []const u8) [4]u8 {
    var ip: [4]u8 = undefined;
    @memcpy(&ip, frame[26..30]);
    return ip;
}

pub fn dst_ip(frame: []const u8) [4]u8 {
    var ip: [4]u8 = undefined;
    @memcpy(&ip, frame[30..34]);
    return ip;
}

pub fn protocol(frame: []const u8) u8 {
    if (frame.len < eth_hdr_len + ipv4_hdr_len) return 0;
    return frame[23];
}

/// The ICMP type (0 for a non-ICMP / short frame).
pub fn icmp_type(frame: []const u8) u8 {
    if (frame.len < ipv4_frame_min) return 0xff;
    return frame[34];
}

pub fn icmp_id(frame: []const u8) u16 {
    if (frame.len < ipv4_frame_min) return 0;
    return (@as(u16, frame[38]) << 8) | frame[39];
}

pub fn icmp_seq(frame: []const u8) u16 {
    if (frame.len < ipv4_frame_min) return 0;
    return (@as(u16, frame[40]) << 8) | frame[41];
}

// ---------------------------------------------------------------------------
// Builders (byte-exact, RFC-shaped; the live gate's fixtures pin them)
// ---------------------------------------------------------------------------

/// Build an ICMP ECHO REQUEST to `peer_ip` at `peer_mac` (dst = the peer
/// MAC, src = our MAC; IPv4 src = `own_ip`, dst = `peer_ip`; the ICMP
/// identifier + sequence from the `net ping` counters; payload bytes
/// 01 02 03 04 — deterministic, gate-assertable) into `buf` (must hold >=
/// `ipv4_frame_min + 4`). Returns the frame length (46).
pub fn build_echo_request(buf: []u8, own_mac: *const [6]u8, own_ip: [4]u8, peer_mac: [6]u8, peer_ip: [4]u8) usize {
    const payload_len = 4;
    const total = ipv4_hdr_len + icmp_hdr_len + payload_len;
    const frame_len = eth_hdr_len + total;
    @memset(buf[0..frame_len], 0);
    @memcpy(buf[0..6], &peer_mac); // dst
    @memcpy(buf[6..12], own_mac); // src
    buf[12] = 0x08;
    buf[13] = 0x00; // ethertype IPv4
    buf[14] = 0x45; // version 4, IHL 5
    buf[16] = @truncate(total >> 8);
    buf[17] = @truncate(total); // total length
    buf[18] = @truncate(ping_id >> 8);
    buf[19] = @truncate(ping_id); // identification (the ping's id — deterministic)
    buf[22] = ttl_default;
    buf[23] = protocol_icmp;
    @memcpy(buf[26..30], &own_ip); // src
    @memcpy(buf[30..34], &peer_ip); // dst
    // Header checksum (the field at 24..26 is still zero).
    const hdr_chk = checksum(buf[14..34]);
    buf[24] = @truncate(hdr_chk >> 8);
    buf[25] = @truncate(hdr_chk);
    // ICMP: type 8, code 0, checksum (zeroed during the computation),
    // id/seq from the counters, payload 01 02 03 04.
    buf[34] = icmp_type_request;
    const icmp = buf[34 .. 34 + icmp_hdr_len + payload_len];
    icmp[4] = @truncate(ping_id >> 8);
    icmp[5] = @truncate(ping_id);
    icmp[6] = @truncate(ping_seq >> 8);
    icmp[7] = @truncate(ping_seq);
    icmp[8] = 0x01;
    icmp[9] = 0x02;
    icmp[10] = 0x03;
    icmp[11] = 0x04;
    const icmp_chk = checksum(icmp);
    icmp[2] = @truncate(icmp_chk >> 8);
    icmp[3] = @truncate(icmp_chk);
    return frame_len;
}

/// Build an ICMP ECHO REPLY to the echo request in `req` (the received
/// frame): Ethernet dst/src swapped (dst = the requester's MAC), IPv4
/// src/dst swapped, the IPv4 identification ECHOED (deterministic —
/// documented), TTL 64, protocol 1, and the ICMP type 0 with the
/// identifier + sequence + payload ECHOED BYTE-EXACT; both checksums
/// recomputed. `buf` must hold >= the request's frame length. Returns the
/// frame length (same as the request's) or 0 if the reply would not fit.
pub fn build_echo_reply(buf: []u8, own_mac: *const [6]u8, own_ip: [4]u8, req: []const u8) usize {
    const frame_len = req.len;
    if (frame_len < ipv4_frame_min or frame_len > buf.len) return 0;
    @memset(buf[0..frame_len], 0);
    @memcpy(buf[0..6], req[6..12]); // dst = the requester's MAC
    @memcpy(buf[6..12], own_mac); // src
    buf[12] = 0x08;
    buf[13] = 0x00; // ethertype IPv4
    buf[14] = 0x45; // version 4, IHL 5
    buf[15] = 0x00; // TOS
    // Total length: unchanged (the reply is the same size as the request).
    @memcpy(buf[16..18], req[16..18]);
    // Identification ECHOED (deterministic, gate-assertable).
    @memcpy(buf[18..20], req[18..20]);
    buf[20] = 0x00;
    buf[21] = 0x00; // no fragmentation on the reply
    buf[22] = ttl_default;
    buf[23] = protocol_icmp;
    @memcpy(buf[26..30], &own_ip); // src = OUR address
    @memcpy(buf[30..34], req[26..30]); // dst = the requester's address
    const hdr_chk = checksum(buf[14..34]);
    buf[24] = @truncate(hdr_chk >> 8);
    buf[25] = @truncate(hdr_chk);
    // ICMP: type 0 (reply), code 0, checksum recomputed, id/seq/payload
    // echoed byte-exact from the request's ICMP message.
    buf[34] = icmp_type_reply;
    buf[35] = 0x00;
    const icmp_len = frame_len - eth_hdr_len - ipv4_hdr_len;
    const icmp = buf[34 .. 34 + icmp_len];
    @memcpy(icmp[4..icmp_len], req[38 .. 38 + icmp_len - 4]); // id + seq + payload
    const icmp_chk = checksum(icmp);
    icmp[2] = @truncate(icmp_chk >> 8);
    icmp[3] = @truncate(icmp_chk);
    return frame_len;
}

// ---------------------------------------------------------------------------
// RX dispatch (the caller MAC-filtered the frame and passes it WITHOUT the
// RX virtio_net_hdr — the Ethernet header starts at byte 0)
// ---------------------------------------------------------------------------

/// Process one received Ethernet frame. Returns the length of a reply
/// built into `reply_buf` (an ICMP echo request for our static IP — the
/// caller transmits it), or null (not IPv4 / a reply observed / a drop).
pub fn handle_rx(frame: []const u8, own_mac: *const [6]u8, reply_buf: []u8) ?usize {
    if (ethertype(frame) != ethertype_ipv4) return null; // not our concern
    received += 1;
    if (!is_ipv4(frame)) {
        dropped_short += 1; // too short / wrong version / IHL
        return null;
    }
    if (is_fragment(frame)) {
        dropped_frag += 1; // N4 does NOT reassemble (honest bound)
        return null;
    }
    if (!header_checksum_ok(frame)) {
        dropped_checksum += 1;
        return null;
    }
    // M97e-F2 (#2101): the destination must name US before a protocol
    // handler ever sees the packet — `arp.own_ip`, or the limited
    // broadcast 255.255.255.255 (the DHCP client sets the broadcast
    // flag; its OFFER/ACKs arrive there, server port 67 -> client 68).
    // The MAC filter admits broadcast + multicast frames, so unicast
    // traffic for OTHER addresses on the segment reaches this layer:
    // without this check a UDP listener or a TCP session would ingest a
    // datagram never addressed to this host. Directed broadcast and
    // multicast are NOT admitted (no consumer — the honest bound).
    const dst = dst_ip(frame);
    if (!std.mem.eql(u8, &dst, &arp.own_ip) and !std.mem.eql(u8, &dst, &[4]u8{ 255, 255, 255, 255 })) {
        dropped_other += 1;
        return null;
    }
    if (protocol(frame) == udp.protocol_udp) {
        // Card N5 (claim 8552): UDP datagrams are handed to the UDP layer
        // ALREADY VALIDATED (checksum/fragment/dst checks stayed above —
        // never duplicated). The N5 guest receives + sends; it does not
        // answer UDP (the host answers, --net-udp-respond).
        if (!native_socket.receiveDns(frame)) udp.handle_rx(frame);
        return null;
    }
    if (protocol(frame) == tcp.protocol_tcp) {
        // Card N10 (claim 7026): TCP segments are handed to the bounded
        // TCP client ALREADY VALIDATED (checksum/fragment/dst checks
        // stayed above — never duplicated). The client's RX processing
        // builds its ACKs into its own buffer; nothing is transmitted
        // from the drain context.
        if (native_socket.sockets.listener) |listener| {
            if (frame.len >= tcp.frame_min and std.mem.readInt(u16, frame[36..38], .big) == listener.local.port) {
                native_socket.receiveTcp(frame, listener.local.port);
                return null;
            }
        }
        _ = tcp.handle_rx(frame);
        return null;
    }
    if (protocol(frame) != protocol_icmp) {
        dropped_proto += 1; // other protocols — later cards
        return null;
    }
    if (icmp_type(frame) == icmp_type_reply) {
        pongs_observed += 1; // the ping's pong — observe, don't forward
        last_seq = icmp_seq(frame);
        return null;
    }
    if (icmp_type(frame) != icmp_type_request) {
        dropped_other += 1; // other ICMP types are out of N4's scope
        return null;
    }
    if (!std.mem.eql(u8, frame[30..34], &arp.own_ip)) {
        dropped_other += 1; // an echo for an address we do not own
        return null;
    }
    const n = build_echo_reply(reply_buf, own_mac, arp.own_ip, frame);
    if (n == 0) {
        dropped_other += 1;
        return null;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Host tests — pure logic, byte-exact against the fixtures
// ---------------------------------------------------------------------------

const test_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 }; // the host-set guest MAC
const host_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 }; // the host-side MAC
const ip_guest = [4]u8{ 10, 0, 0, 1 };
const ip_host = [4]u8{ 10, 0, 0, 2 };

// The RFC 1071 classic vector: a real IPv4 header (checksum field
// zeroed) whose one's-complement sum is 0xb1e6.
test "ipv4: RFC 1071 checksum — known vector + odd length" {
    // The classic RFC 1071 example: 45 00 00 3c 1c 46 40 00 40 06 00 00
    // ac 10 0a 63 ac 10 0a 0c -> 0xb1e6.
    const hdr = [_]u8{ 0x45, 0x00, 0x00, 0x3c, 0x1c, 0x46, 0x40, 0x00, 0x40, 0x06, 0x00, 0x00, 0xac, 0x10, 0x0a, 0x63, 0xac, 0x10, 0x0a, 0x0c };
    try std.testing.expectEqual(@as(u16, 0xb1e6), checksum(&hdr));
    // An odd-length buffer pads the trailing byte with zero: 0xff00 +
    // 0xff00 = 0x1fe00, folded 0xfe01, complement 0x01fe.
    try std.testing.expectEqual(@as(u16, 0x01fe), checksum(&[_]u8{ 0xff, 0x00, 0xff }));
    // All zeros: sum 0, complement 0xffff.
    try std.testing.expectEqual(@as(u16, 0xffff), checksum(&[_]u8{0}));
}

test "ipv4: build_echo_request is byte-exact against the fixture" {
    ping_id = 1;
    ping_seq = 1;
    var buf: [ipv4_frame_min + 4]u8 = undefined;
    const n = build_echo_request(&buf, &test_mac, ip_guest, host_mac, ip_host);
    try std.testing.expectEqual(@as(usize, 46), n);
    // Ethernet: dst = the peer MAC, src = ours, ethertype 0x0800.
    try std.testing.expectEqualSlices(u8, &host_mac, buf[0..6]);
    try std.testing.expectEqualSlices(u8, &test_mac, buf[6..12]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x00 }, buf[12..14]);
    // IPv4 header: 45 00 | len 00 20 | id 00 01 | 00 00 | 40 | 01 | chk.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x45, 0x00, 0x00, 0x20, 0x00, 0x01, 0x00, 0x00, 0x40, 0x01 }, buf[14..24]);
    // The header checksum verifies (the field is included in the sum).
    try std.testing.expect(header_checksum_ok(&buf));
    try std.testing.expectEqualSlices(u8, &ip_guest, buf[26..30]);
    try std.testing.expectEqualSlices(u8, &ip_host, buf[30..34]);
    // ICMP: type 8, code 0, checksum, id 00 01, seq 00 01, payload 01 02 03 04.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x00 }, buf[34..36]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01 }, buf[38..40]); // id
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01 }, buf[40..42]); // seq
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04 }, buf[42..46]);
    // The ICMP checksum verifies too (a valid checksum folds to 0x0000
    // under `checksum()`).
    const icmp = buf[34..46];
    try std.testing.expectEqual(@as(u16, 0x0000), checksum(icmp));
}

test "ipv4: build_echo_reply — swapped, echoed, byte-exact, checksums valid" {
    ping_id = 1;
    ping_seq = 1;
    var req: [ipv4_frame_min + 4]u8 = undefined;
    _ = build_echo_request(&req, &host_mac, ip_host, test_mac, ip_guest);
    var reply: [ipv4_frame_min + 4]u8 = undefined;
    const n = build_echo_reply(&reply, &test_mac, ip_guest, &req);
    try std.testing.expectEqual(@as(usize, 46), n);
    // Ethernet: dst = the requester's MAC, src = ours.
    try std.testing.expectEqualSlices(u8, &host_mac, reply[0..6]);
    try std.testing.expectEqualSlices(u8, &test_mac, reply[6..12]);
    // IPv4: type 0, src/dst swapped, identification ECHOED, TTL 64.
    try std.testing.expectEqualSlices(u8, &ip_guest, reply[26..30]); // src = ours
    try std.testing.expectEqualSlices(u8, &ip_host, reply[30..34]); // dst = requester
    try std.testing.expectEqualSlices(u8, req[18..20], reply[18..20]); // echoed id
    try std.testing.expectEqual(@as(u8, 0x40), reply[22]); // TTL 64
    try std.testing.expect(header_checksum_ok(&reply));
    // ICMP: type 0 (reply), id/seq/payload echoed byte-exact, checksum valid.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00 }, reply[34..36]);
    try std.testing.expectEqualSlices(u8, req[38..46], reply[38..46]);
    const icmp = reply[34..46];
    try std.testing.expectEqual(@as(u16, 0x0000), checksum(icmp));
}

test "ipv4: classify — fragments, bad checksums, foreign protocols, foreign dst" {
    ping_id = 1;
    ping_seq = 1;
    var req: [ipv4_frame_min + 4]u8 = undefined;
    _ = build_echo_request(&req, &host_mac, ip_host, test_mac, ip_guest);
    // A well-formed echo request is a request.
    try std.testing.expect(is_ipv4(&req));
    try std.testing.expect(!is_fragment(&req));
    try std.testing.expect(header_checksum_ok(&req));

    // A FRAGMENT (MF set) is detected — N4 drops, never reassembles.
    var frag = req;
    frag[20] = 0x20; // MF set (flags 0x2 in the top 3 bits)
    try std.testing.expect(is_fragment(&frag));
    // A nonzero offset is a fragment too.
    frag = req;
    frag[21] = 0x01; // offset 1
    try std.testing.expect(is_fragment(&frag));
    // Zero flag + zero offset is NOT a fragment.
    frag = req;
    frag[20] = 0x00;
    frag[21] = 0x00;
    try std.testing.expect(!is_fragment(&frag));

    // A corrupted checksum fails verification.
    var bad = req;
    bad[26] +%= 1; // src byte — breaks the checksum
    try std.testing.expect(!header_checksum_ok(&bad));

    // A non-IPv4 ethertype is not IPv4.
    var not_ip = req;
    not_ip[13] = 0x06; // ARP
    try std.testing.expect(!is_ipv4(&not_ip));

    // A short frame is not IPv4.
    try std.testing.expect(!is_ipv4(req[0..41]));
}

test "ipv4: handle_rx — answer an echo for us, observe a reply, drop the rest" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    received = 0;
    dropped_short = 0;
    dropped_frag = 0;
    dropped_checksum = 0;
    dropped_proto = 0;
    dropped_other = 0;
    replies_sent = 0;
    requests_sent = 0;
    pongs_observed = 0;
    last_seq = 0;
    reply_tx_fail = 0;

    var reply_buf: [ipv4_frame_min + 64]u8 = undefined;

    // An echo request for OUR address: a byte-exact reply is built.
    ping_id = 1;
    ping_seq = 1;
    var req: [ipv4_frame_min + 4]u8 = undefined;
    _ = build_echo_request(&req, &host_mac, ip_host, test_mac, ip_guest);
    const rn = handle_rx(&req, &test_mac, &reply_buf).?;
    try std.testing.expectEqual(@as(usize, 46), rn);
    try std.testing.expectEqualSlices(u8, &host_mac, reply_buf[0..6]); // dst = requester
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00 }, reply_buf[34..36]); // type 0
    try std.testing.expectEqual(@as(u64, 1), received);
    try std.testing.expectEqual(@as(u64, 0), replies_sent); // the CALLER sends

    // An echo request for a FOREIGN address: dropped.
    ping_id = 2;
    ping_seq = 2;
    var req_other: [ipv4_frame_min + 4]u8 = undefined;
    _ = build_echo_request(&req_other, &host_mac, ip_host, test_mac, .{ 10, 0, 0, 99 });
    try std.testing.expect(handle_rx(&req_other, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 1), dropped_other);

    // An echo REPLY to OUR outbound ping: observed (pong), not
    // re-answered. (M97e-F2: the reply's dst must be OUR address — the
    // real shape is our request to the host, the host's reply back.)
    ping_id = 3;
    ping_seq = 3;
    var our_req: [ipv4_frame_min + 4]u8 = undefined;
    _ = build_echo_request(&our_req, &test_mac, ip_guest, host_mac, ip_host);
    var rep: [ipv4_frame_min + 4]u8 = undefined;
    _ = build_echo_reply(&rep, &host_mac, ip_host, &our_req);
    try std.testing.expect(handle_rx(&rep, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 1), pongs_observed);
    try std.testing.expectEqual(@as(u16, 3), last_seq);

    // A FRAGMENT: dropped with its own counter, no reply.
    var frag = req;
    frag[20] = 0x20;
    try std.testing.expect(handle_rx(&frag, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 1), dropped_frag);

    // A bad checksum: dropped with its own counter.
    var bad = req;
    bad[26] +%= 1;
    try std.testing.expect(handle_rx(&bad, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 1), dropped_checksum);

    // A non-ICMP/UDP/TCP protocol (GRE 47): dropped with its own counter.
    var tcpf = req;
    tcpf[23] = 47; // GRE — not ICMP/UDP/TCP
    // Fix the checksum so it lands in the protocol counter, not chk.
    tcpf[24] = 0;
    tcpf[25] = 0;
    const tc = checksum(tcpf[14..34]);
    tcpf[24] = @truncate(tc >> 8);
    tcpf[25] = @truncate(tc);
    try std.testing.expect(handle_rx(&tcpf, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 1), dropped_proto);

    // A non-IPv4 frame: untouched, not counted.
    var arp_frame: [42]u8 = @splat(0);
    arp_frame[12] = 0x08;
    arp_frame[13] = 0x06;
    try std.testing.expect(handle_rx(&arp_frame, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 1), dropped_other); // still 1 — non-IPv4 is not counted
}

test "ipv4: protocol dispatch — UDP (17) is handed to udp, TCP (6) to the tcp client" {
    udp.reset();
    udp.received = 0;
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    dropped_proto = 0;
    try std.testing.expect(udp.listen_port(7000));

    // A valid UDP datagram 10.0.0.2:9999 -> 10.0.0.1:7000 is delivered to
    // the UDP layer (not counted as dropped_proto) — the IPv4 validation
    // (checksum, fragment, dst) stays in ipv4.
    var frame: [46]u8 = @splat(0);
    frame[12] = 0x08;
    frame[13] = 0x00;
    frame[14] = 0x45;
    frame[16] = 0x00;
    frame[17] = 32;
    frame[22] = 64;
    frame[23] = 17; // protocol UDP
    @memcpy(frame[26..30], &[_]u8{ 10, 0, 0, 2 });
    @memcpy(frame[30..34], &[_]u8{ 10, 0, 0, 1 });
    // The IPv4 header checksum (the field is zeroed by the memset).
    const hc = checksum(frame[14..34]);
    frame[24] = @truncate(hc >> 8);
    frame[25] = @truncate(hc);
    _ = udp.build_datagram(frame[34..46], .{ 10, 0, 0, 2 }, .{ 10, 0, 0, 1 }, 9999, 7000, &.{ 1, 2, 3, 4 });
    var reply_buf: [ipv4_frame_min + 64]u8 = undefined;
    try std.testing.expect(handle_rx(&frame, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 0), dropped_proto); // NOT counted as a drop
    try std.testing.expectEqual(@as(u64, 1), udp.received); // delivered to the listener
    try std.testing.expect(udp.pop(7000) != null);

    // A TCP frame (protocol 6): card N10 — handed to the bounded TCP
    // client (NOT a protocol drop). The client has no connection (idle)
    // and the 46-byte frame is too short for a TCP header (54 min) — it
    // is counted malformed inside tcp, proving the dispatch happened.
    tcp.reset();
    tcp.dropped_malformed = 0;
    var tcpf: [46]u8 = @splat(0);
    tcpf[12] = 0x08;
    tcpf[13] = 0x00;
    tcpf[14] = 0x45;
    tcpf[16] = 0x00;
    tcpf[17] = 40;
    tcpf[22] = 64;
    tcpf[23] = 6; // TCP
    @memcpy(tcpf[26..30], &[_]u8{ 10, 0, 0, 2 });
    @memcpy(tcpf[30..34], &[_]u8{ 10, 0, 0, 1 });
    const tc2 = checksum(tcpf[14..34]);
    tcpf[24] = @truncate(tc2 >> 8);
    tcpf[25] = @truncate(tc2);
    try std.testing.expect(handle_rx(&tcpf, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 0), dropped_proto); // dispatched, not dropped
    try std.testing.expectEqual(@as(u64, 1), tcp.dropped_malformed); // the client saw it
    udp.reset();
}

test "ipv4: M97e-F2 dst gate — a foreign unicast address is dropped before UDP, broadcast admitted" {
    udp.reset();
    defer udp.reset();
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    dropped_other = 0;
    var reply_buf: [ipv4_frame_min + 64]u8 = undefined;
    try std.testing.expect(udp.listen_port(7000));

    // A well-formed UDP datagram to an address we do NOT own (the MAC
    // filter admitted it — broadcast/multicast frames come through): it
    // must never reach the UDP layer's listener.
    var frame: [udp.frame_max]u8 = undefined;
    var n = udp.build_frame_ex(&frame, test_mac, &host_mac, ip_host, .{ 10, 0, 0, 99 }, 9999, 7000, "hi");
    try std.testing.expect(handle_rx(frame[0..n], &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 1), dropped_other);
    try std.testing.expectEqual(@as(u64, 0), udp.received); // never delivered
    try std.testing.expect(udp.pop(7000) == null);

    // The same datagram to OUR address: delivered (the control — the
    // gate did not wedge the listener).
    n = udp.build_frame_ex(&frame, test_mac, &host_mac, ip_host, ip_guest, 9999, 7000, "hi");
    try std.testing.expect(handle_rx(frame[0..n], &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 1), udp.received);
    try std.testing.expect(udp.pop(7000) != null);

    // The limited broadcast address (the DHCP client's reply shape):
    // admitted through the gate and delivered the same way.
    n = udp.build_frame_ex(&frame, .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, &host_mac, ip_host, .{ 255, 255, 255, 255 }, 9999, 7000, "bc");
    try std.testing.expect(handle_rx(frame[0..n], &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 2), udp.received);
    try std.testing.expect(udp.pop(7000) != null);

    // And a directed broadcast / multicast-shaped address is NOT
    // admitted (no consumer — the honest bound).
    n = udp.build_frame_ex(&frame, .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, &host_mac, ip_host, .{ 10, 0, 0, 255 }, 9999, 7000, "db");
    try std.testing.expect(handle_rx(frame[0..n], &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 2), dropped_other);
    try std.testing.expectEqual(@as(u64, 2), udp.received);
}
