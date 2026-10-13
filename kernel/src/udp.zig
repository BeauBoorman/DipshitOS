//! UDP (RFC 768) over the card-N4 IPv4 seam — milestone five, card N5
//! (claim 8552). PURE protocol logic (header parse/build, the IPv4
//! pseudo-header checksum, a bounded LISTEN table, a bounded datagram
//! buffer, LOOPBACK) + host tests, the fat.zig pattern; `ipv4.zig` wires
//! it to ALREADY-VALIDATED IPv4 frames (protocol 17 dispatch — the IPv4
//! checksum/fragment/dst checks stay in ipv4, never duplicated) and
//! `virtio_net.zig`'s `net_udp_send` drives the transmit side (the N1
//! one-request-at-a-time TX path) + the loopback path.
//!
//! Honest bounds: IPv4 only, UDP only (no TCP — later), the checksum is
//! computed ALWAYS (the RFC 768 IPv4 "may be zero" escape is not used —
//! byte-exact gates pin the real value); a datagram whose length is < 8
//! or exceeds the frame, a bad checksum, and a datagram for a port with
//! NO listener are DROPPED, each with its own counter. The N5 guest
//! RECEIVES and SENDS — it does not ANSWER UDP (the host answers,
//! `--net-udp-respond`); a later card can add guest-side responders.

const std = @import("std");
const arp = @import("arp.zig"); // N3: our static IP (`arp.own_ip` — the ONE copy)
const dhcp = @import("dhcp.zig"); // N8 (claim 0351): the DHCP client owns port 68

pub const eth_hdr_len: usize = 14; // the same values as ipv4.zig (constants only — no circular import)
pub const ipv4_hdr_len: usize = 20;
pub const udp_hdr_len: usize = 8; // src port (2) + dst port (2) + length (2) + checksum (2)
pub const protocol_udp: u8 = 17;
/// The fixed source port for `net udp send` (deterministic, gate-assertable).
pub const default_src_port: u16 = 7000;
/// Bounded payload for `net udp send` (the honest bound — the byte-index
/// pattern, gate-assertable). Over-length sends truncate honestly.
/// M99i (#2187): raised 64 -> 512 — a multi-answer DNS reply cannot fit a
/// 64-byte datagram; 512 is the classic RFC 1035 UDP bound (no EDNS0).
pub const payload_max: usize = 512;
/// Datagram storage: 8-byte header + the bounded payload.
pub const datagram_max: usize = udp_hdr_len + payload_max; // 520
/// M99i (#2187): the slot-85 `sys_udp_recv_from` shape prepends the
/// sender's IPv4 address to the datagram — 4 + datagram_max.
pub const recv_from_max: usize = 4 + datagram_max; // 524
/// The smallest full frame: Ethernet + IPv4 + the 8-byte UDP header.
pub const frame_min: usize = eth_hdr_len + ipv4_hdr_len + udp_hdr_len; // 42
/// The largest full frame: Ethernet + IPv4 + header + the bounded payload.
pub const frame_max: usize = eth_hdr_len + ipv4_hdr_len + udp_hdr_len + payload_max; // 554
/// Bounded listen table (the ARP-table pattern: 4 slots, pure BSS).
pub const listen_slots: usize = 4;
/// Bounded datagram buffer PER listener (drop-oldest, the N2 FIFO pattern).
pub const buffer_slots: usize = 4;

// ---------------------------------------------------------------------------
// Counters (the `net` report) — every drop is counted, never assumed away.
// ---------------------------------------------------------------------------

pub var received: u64 = 0; // datagrams delivered into a listener's buffer (incl. loopback)
pub var sent: u64 = 0; // `net udp send` datagrams (device TX + loopback)
pub var loopbacked: u64 = 0; // sends that took the local loopback path (no device)
pub var dropped_badsum: u64 = 0; // UDP checksum mismatch (pseudo-header + datagram)
pub var dropped_closed: u64 = 0; // datagram for a port with NO listener
pub var dropped_len: u64 = 0; // length < 8 or exceeding the frame's remaining bytes
/// M99i (#2187): listen-table seats reclaimed from exited owners by the
/// syscall layer (a program that exits without sys_udp_close).
pub var stale_reclaimed: u64 = 0;

// ---------------------------------------------------------------------------
// State (pure BSS, the fat.zig pattern)
// ---------------------------------------------------------------------------

/// M99i (#2187): the owner a `sys_udp_listen` bind records — the pid that
/// bound the port. Kernel-internal binds (`net udp listen`, the slot-80
/// DNS transaction's ephemeral port) carry `unowned` and are not
/// receivable or releasable from EL0.
pub const unowned: u64 = 0;

pub const ListenEntry = struct {
    port: u16 = 0,
    /// M99i: owner pid of the binding process (`unowned` for kernel binds).
    owner: u64 = unowned,
    valid: bool = false,
};

pub const Datagram = struct {
    len: usize = 0,
    /// M99i: the sender's IPv4 address, kept from the IP header — the
    /// slot-85 recv-from shape prepends it so a resolver can check the
    /// reply came from the server it asked.
    src_ip: [4]u8 = .{ 0, 0, 0, 0 },
    bytes: [datagram_max]u8 = undefined,
};

pub var listen: [listen_slots]ListenEntry = @as([listen_slots]ListenEntry, @splat(@as(ListenEntry, .{})));
/// Per-listener bounded ring (slot index = the listen slot). drop-oldest:
/// when full, the newest write overwrites the oldest and the head advances.
pub var buffers: [listen_slots][buffer_slots]Datagram = @as([listen_slots][buffer_slots]Datagram, @splat(@as([buffer_slots]Datagram, @as([buffer_slots]Datagram, @splat(@as(Datagram, .{}))))));
pub var buf_head: [listen_slots]usize = @splat(0);
pub var buf_count: [listen_slots]usize = @splat(0);

// ---------------------------------------------------------------------------
// RFC 1071 one's-complement checksum (the ipv4.zig machinery, extended for
// the UDP pseudo-header — RFC 768 §2)
// ---------------------------------------------------------------------------

fn sum_words(data: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u32, data[i]) << 8) | data[i + 1];
    }
    if (i < data.len) sum += @as(u32, data[i]) << 8; // trailing odd byte
    return sum;
}

fn fold(sum: u32) u16 {
    var s = sum;
    while (s >> 16 != 0) s = (s & 0xffff) + (s >> 16);
    return ~@as(u16, @truncate(s));
}

/// The 12-byte IPv4 pseudo-header (src IP, dst IP, zero, protocol, UDP
/// length) folded into the checksum. Word 5 is bytes 8-9 = 0x00 0x11
/// (the ZERO byte HIGH, protocol 17 LOW — the RFC 768 layout; a
/// reversed byte order here silently breaks every datagram against
/// standard peers, caught by the live gate's byte-exact fixtures).
fn pseudo_sum(src: [4]u8, dst: [4]u8, udp_len: u16) u32 {
    var s: u32 = 0;
    s += (@as(u32, src[0]) << 8) | src[1];
    s += (@as(u32, src[2]) << 8) | src[3];
    s += (@as(u32, dst[0]) << 8) | dst[1];
    s += (@as(u32, dst[2]) << 8) | dst[3];
    s += protocol_udp; // (0x00 << 8) | 17
    s += udp_len;
    return s;
}

/// The UDP checksum over the pseudo-header + the datagram (`datagram` = the
/// 8-byte header + payload; the checksum field must be ZEROED by the
/// caller when building — the verification path passes the field as read).
pub fn checksum_udp(src: [4]u8, dst: [4]u8, datagram: []const u8) u16 {
    const len: u16 = @intCast(datagram.len);
    return fold(pseudo_sum(src, dst, len) + sum_words(datagram));
}

// ---------------------------------------------------------------------------
// Builders (byte-exact, RFC-shaped; the live gate's fixtures pin them)
// ---------------------------------------------------------------------------

/// Build a UDP datagram (header + payload) into `buf` (must hold >=
/// `udp_hdr_len + payload.len`): src/dst ports, length, checksum computed
/// over the pseudo-header (src_ip/dst_ip) + the datagram (RFC 1071). The
/// payload is truncated honestly at `payload_max`. Returns the datagram
/// length (8 + the written payload).
pub fn build_datagram(buf: []u8, src_ip: [4]u8, dst_ip: [4]u8, src_port: u16, dst_port: u16, payload: []const u8) usize {
    const plen = @min(payload.len, payload_max);
    const total = udp_hdr_len + plen;
    @memset(buf[0..total], 0);
    buf[0] = @truncate(src_port >> 8);
    buf[1] = @truncate(src_port);
    buf[2] = @truncate(dst_port >> 8);
    buf[3] = @truncate(dst_port);
    buf[4] = @truncate(total >> 8);
    buf[5] = @truncate(total);
    // Checksum field at 6..8 — zeroed by the memset during the computation.
    @memcpy(buf[8..total], payload[0..plen]);
    const c = checksum_udp(src_ip, dst_ip, buf[0..total]);
    buf[6] = @truncate(c >> 8);
    buf[7] = @truncate(c);
    return total;
}

// ---------------------------------------------------------------------------
// The listen table + the bounded per-listener datagram buffer
// ---------------------------------------------------------------------------

pub fn listen_port(port: u16) bool {
    return listen_port_owned(port, unowned);
}

/// M99i (#2187): bind `port` recording `owner` (the caller's pid, or
/// `unowned` for kernel callers). Duplicate port or full table → false,
/// the same honest bool `listen_port` always returned.
pub fn listen_port_owned(port: u16, owner: u64) bool {
    for (&listen) |*e| {
        if (e.valid and e.port == port) return false; // duplicate
    }
    for (&listen) |*e| {
        if (!e.valid) {
            e.* = .{ .port = port, .owner = owner, .valid = true };
            return true;
        }
    }
    return false; // table full
}

/// M99i (#2187): release `port` only when `owner` bound it. True on
/// release — the EL0 `sys_udp_close` maps the false cases onto honest
/// errnos (not bound → EINVAL, another owner's → EACCES).
pub fn release_owned(owner: u64, port: u16) bool {
    for (&listen, 0..) |*e, i| {
        if (e.valid and e.port == port and e.owner == owner) {
            e.valid = false;
            buf_head[i] = 0;
            buf_count[i] = 0; // the listener's ring is drained with it
            return true;
        }
    }
    return false;
}

/// M99i (#2187): the owner recorded for `port` — null when the port is
/// not bound (the syscall layer distinguishes EINVAL from EACCES).
pub fn owner_of(port: u16) ?u64 {
    for (listen) |e| {
        if (e.valid and e.port == port) return e.owner;
    }
    return null;
}

/// M99i (#2187): release EVERY port `owner` bound (a dead process's
/// seats are reclaimed by the syscall layer — udp itself cannot see
/// process state without an import cycle). Returns the count freed.
pub fn release_owner(owner: u64) usize {
    var freed: usize = 0;
    for (&listen, 0..) |*e, i| {
        if (e.valid and e.owner == owner) {
            e.valid = false;
            buf_head[i] = 0;
            buf_count[i] = 0;
            freed += 1;
        }
    }
    return freed;
}

pub fn close_port(port: u16) bool {
    for (&listen, 0..) |*e, i| {
        if (e.valid and e.port == port) {
            e.valid = false;
            buf_head[i] = 0; // the listener's ring is drained with it
            buf_count[i] = 0;
            return true;
        }
    }
    return false;
}

fn find_listener(port: u16) ?usize {
    for (listen, 0..) |e, i| {
        if (e.valid and e.port == port) return i;
    }
    return null;
}

/// Reset the listen table + the datagram buffers + the counters (tests
/// only — the live kernel never re-initializes protocol state).
pub fn reset() void {
    listen = @as([listen_slots]ListenEntry, @splat(@as(ListenEntry, .{})));
    buffers = @as([listen_slots][buffer_slots]Datagram, @splat(@as([buffer_slots]Datagram, @as([buffer_slots]Datagram, @splat(@as(Datagram, .{}))))));
    buf_head = @as([listen_slots]usize, @splat(@as(usize, 0)));
    buf_count = @as([listen_slots]usize, @splat(@as(usize, 0)));
    received = 0;
    sent = 0;
    loopbacked = 0;
    dropped_badsum = 0;
    dropped_closed = 0;
    dropped_len = 0;
}

/// Deliver `datagram` (header + payload) from `src_ip` to the listener
/// for `dst_port`: stored in the listener's bounded ring (drop-oldest)
/// and counted. A port with no listener is dropped (`dropped_closed`) —
/// never assumed away. M99i keeps the sender's address so the recv-from
/// shape can hand it to EL0.
pub fn deliver(dst_port: u16, src_ip: [4]u8, datagram: []const u8) void {
    const slot = find_listener(dst_port) orelse {
        dropped_closed += 1;
        return;
    };
    const head = buf_head[slot];
    const count = buf_count[slot];
    const idx = (head + count) % buffer_slots;
    const d = &buffers[slot][idx];
    d.len = @min(datagram.len, datagram_max);
    d.src_ip = src_ip;
    @memcpy(d.bytes[0..d.len], datagram[0..d.len]);
    if (count < buffer_slots) {
        buf_count[slot] = count + 1;
    } else {
        buf_head[slot] = (head + 1) % buffer_slots; // drop-oldest
    }
    received += 1;
}

/// True when the listen table has an entry for `port` (the syscall recv
/// distinguishes "not listening" (EINVAL) from "empty ring" (0) —
/// claim 1384, card N6).
pub fn is_listening(port: u16) bool {
    return find_listener(port) != null;
}

/// Copy the oldest datagram for the listener on `port` WITHOUT consuming
/// it (null when empty or not listening). The syscall recv path uses
/// peek → copy_out → pop so a bad recv buffer (`EFAULT`) leaves the
/// datagram queued — the claim-5965 ipc contract (claim 1384, card N6).
pub fn peek(port: u16) ?Datagram {
    const slot = find_listener(port) orelse return null;
    if (buf_count[slot] == 0) return null;
    return buffers[slot][buf_head[slot]];
}

/// Pop the oldest datagram for the listener on `port` (null when empty).
pub fn pop(port: u16) ?Datagram {
    const slot = find_listener(port) orelse return null;
    if (buf_count[slot] == 0) return null;
    const idx = buf_head[slot];
    buf_head[slot] = (idx + 1) % buffer_slots;
    buf_count[slot] -= 1;
    return buffers[slot][idx];
}

// ---------------------------------------------------------------------------
// RX dispatch (the caller — ipv4.zig — already validated the IPv4 header:
// checksum, fragment, dst address; the frame starts at the Ethernet header)
// ---------------------------------------------------------------------------

/// The IPv4 src address of a validated frame (bytes 26..30).
fn frame_src_ip(frame: []const u8) [4]u8 {
    var ip: [4]u8 = undefined;
    @memcpy(&ip, frame[26..30]);
    return ip;
}

/// The IPv4 dst address of a validated frame (bytes 30..34).
fn frame_dst_ip(frame: []const u8) [4]u8 {
    var ip: [4]u8 = undefined;
    @memcpy(&ip, frame[30..34]);
    return ip;
}

/// Process one validated IPv4 frame with protocol 17. Delivers the
/// datagram to the listener for its dst port (or drops it, counted).
/// Returns nothing — the N5 guest does not answer UDP.
pub fn handle_rx(frame: []const u8) void {
    if (frame.len < eth_hdr_len + ipv4_hdr_len + udp_hdr_len) {
        dropped_len += 1;
        return;
    }
    const udp_len = (@as(u16, frame[38]) << 8) | frame[39];
    const remaining = frame.len - (eth_hdr_len + ipv4_hdr_len);
    if (udp_len < udp_hdr_len or udp_len > remaining) {
        dropped_len += 1;
        return;
    }
    const datagram = frame[eth_hdr_len + ipv4_hdr_len .. eth_hdr_len + ipv4_hdr_len + udp_len];
    const src = frame_src_ip(frame);
    const dst = frame_dst_ip(frame);
    if (checksum_udp(src, dst, datagram) != 0x0000) {
        dropped_badsum += 1; // a valid datagram folds to 0x0000 (RFC 1071)
        return;
    }
    const dst_port = (@as(u16, frame[36]) << 8) | frame[37];
    if (dst_port == dhcp.client_port) {
        // Card N8 (claim 0351): the DHCP client owns port 68 by
        // construction — a reply to the client is handed to the DHCP
        // state machine (the OFFER/ACK/NAK handling), NOT the `net udp
        // listen` table (invisible to `net udp recv`; no listener slot
        // consumed). The datagram was ALREADY checksum-validated above.
        _ = dhcp.handle_rx(datagram);
        return;
    }
    deliver(dst_port, src, datagram);
}

/// Build a FULL Ethernet + IPv4 + UDP frame with EXPLICIT dst/src
/// addresses and ports into `buf` (must hold >= `eth_hdr_len +
/// ipv4_hdr_len + udp_hdr_len + payload.len` — the caller's payload is
/// ALREADY bounded, no truncation here): dst MAC, src MAC, ethertype
/// 0x0800, a 20-byte IPv4 header (version 4 / IHL 5, total length, TTL
/// 64, protocol 17, header checksum), then the UDP datagram (src port,
/// dst port, length, checksum over the pseudo-header src/dst). This is
/// the general builder behind the N5 `build_frame` AND the N8 DHCP
/// broadcast-dst send seam (card N8 — the ONE N5-layer change: a DHCP
/// frame goes out with dst MAC ff:ff:ff:ff:ff:ff + dst IP
/// 255.255.255.255 directly, no ARP, src IP 0.0.0.0). Returns the frame
/// length (42 + the written payload).
pub fn build_frame_ex(buf: []u8, dst_mac: [6]u8, own_mac: *const [6]u8, src_ip: [4]u8, dst_ip: [4]u8, src_port: u16, dst_port: u16, payload: []const u8) usize {
    const total = ipv4_hdr_len + udp_hdr_len + payload.len;
    const frame_len = eth_hdr_len + total;
    @memset(buf[0..frame_len], 0);
    @memcpy(buf[0..6], &dst_mac); // dst
    @memcpy(buf[6..12], own_mac); // src
    buf[12] = 0x08;
    buf[13] = 0x00; // ethertype IPv4
    buf[14] = 0x45; // version 4, IHL 5
    buf[16] = @truncate(total >> 8);
    buf[17] = @truncate(total); // total length
    buf[22] = 64; // TTL
    buf[23] = protocol_udp;
    @memcpy(buf[26..30], &src_ip); // src
    @memcpy(buf[30..34], &dst_ip); // dst
    // IPv4 header checksum (the field at 24..26 is zeroed by the memset).
    const hc = fold(sum_words(buf[14..34]));
    buf[24] = @truncate(hc >> 8);
    buf[25] = @truncate(hc);
    // The UDP datagram (the checksum field is zeroed by the memset).
    const dg = buf[34 .. 34 + udp_hdr_len + payload.len];
    dg[0] = @truncate(src_port >> 8);
    dg[1] = @truncate(src_port);
    dg[2] = @truncate(dst_port >> 8);
    dg[3] = @truncate(dst_port);
    dg[4] = @truncate((udp_hdr_len + payload.len) >> 8);
    dg[5] = @truncate(udp_hdr_len + payload.len);
    @memcpy(dg[8 .. 8 + payload.len], payload);
    const c = checksum_udp(src_ip, dst_ip, dg);
    dg[6] = @truncate(c >> 8);
    dg[7] = @truncate(c);
    return frame_len;
}

/// Build the FULL Ethernet + IPv4 + UDP frame to `peer_ip:dst_port` (the
/// N1/N5 shape): dst = the peer's MAC, src = our MAC, the fixed src port
/// `default_src_port`, the pseudo-header src/dst = own_ip/peer_ip. `buf`
/// must hold >= `frame_max`. The payload is truncated honestly at
/// `payload_max` (the N5 seam's honest bound). Returns the frame length
/// (46 + the written payload). A thin wrapper over `build_frame_ex` — the
/// byte-exact N5 fixtures pin the unchanged output.
pub fn build_frame(buf: []u8, own_mac: *const [6]u8, own_ip: [4]u8, peer_mac: [6]u8, peer_ip: [4]u8, dst_port: u16, payload: []const u8) usize {
    const plen = @min(payload.len, payload_max);
    return build_frame_ex(buf, peer_mac, own_mac, own_ip, peer_ip, default_src_port, dst_port, payload[0..plen]);
}

/// Loopback: deliver a datagram to OUR OWN address — built here (src port
/// `default_src_port`, the pseudo-header with src == dst == own_ip) and
/// delivered DIRECTLY into the local receive path (no device round trip).
/// Returns the datagram length. The caller counts `sent` + `loopbacked`;
/// the local delivery counts `received` (or `dropped_closed` — no
/// listener on `dst_port`).
pub fn loopback(own_ip: [4]u8, dst_port: u16, payload: []const u8) usize {
    var datagram: [datagram_max]u8 = undefined;
    const n = build_datagram(&datagram, own_ip, own_ip, default_src_port, dst_port, payload);
    deliver(dst_port, own_ip, datagram[0..n]);
    return n;
}

// ---------------------------------------------------------------------------
// Host tests — pure logic, byte-exact against the fixtures
// ---------------------------------------------------------------------------

test "udp: RFC 1071 pseudo-header checksum — known vector + fold" {
    // The canonical RFC 768-style vector: src 10.0.0.1, dst 10.0.0.2,
    // proto 17, a 12-byte datagram (8-byte header + 01 02 03 04).
    const src = [4]u8{ 10, 0, 0, 1 };
    const dst = [4]u8{ 10, 0, 0, 2 };
    var dg: [12]u8 = undefined;
    _ = build_datagram(&dg, src, dst, 7000, 9999, &.{ 1, 2, 3, 4 });
    // The built datagram's checksum must VERIFY: folding the pseudo-header
    // + the datagram WITH the checksum field reads 0x0000.
    try std.testing.expectEqual(@as(u16, 0x0000), checksum_udp(src, dst, &dg));
    // And a corrupted payload must NOT verify (the checksum catches it).
    var bad = dg;
    bad[8] ^= 0xff;
    try std.testing.expect(checksum_udp(src, dst, &bad) != 0x0000);
    // The checksum of a DIFFERENT pseudo-header differs (address binding).
    const other_dst = [4]u8{ 10, 0, 0, 99 };
    try std.testing.expect(checksum_udp(src, other_dst, &dg) != 0x0000);
}

test "udp: build_datagram is byte-exact against the fixture" {
    // `net udp send 10.0.0.2 9999 4` (src 10.0.0.1:7000): the 12-byte
    // datagram — ports 0x1b58/0x270f, length 0x000c, checksum, payload
    // 01 02 03 04. This is the EXACT datagram the live gate asserts in
    // the capture (inside the 46-byte IPv4 frame).
    const src = [4]u8{ 10, 0, 0, 1 };
    const dst = [4]u8{ 10, 0, 0, 2 };
    var dg: [12]u8 = undefined;
    const n = build_datagram(&dg, src, dst, 7000, 9999, &.{ 1, 2, 3, 4 });
    try std.testing.expectEqual(@as(usize, 12), n);
    try std.testing.expectEqual(@as(u16, 7000), (@as(u16, dg[0]) << 8) | dg[1]);
    try std.testing.expectEqual(@as(u16, 9999), (@as(u16, dg[2]) << 8) | dg[3]);
    try std.testing.expectEqual(@as(u16, 12), (@as(u16, dg[4]) << 8) | dg[5]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, dg[8..12]);
    // The checksum field is NOT zero (computed always).
    try std.testing.expect(dg[6] != 0 or dg[7] != 0);
}

test "udp: build_frame is byte-exact against the fixture" {
    // `net udp send 10.0.0.2 9999 4`: the full 46-byte frame — dst
    // 02:00:00:00:00:02, src 02:00:00:00:00:01, ethertype 0x0800, IPv4
    // (0x45, total 32, TTL 64, proto 17), UDP (src 7000, dst 9999, len
    // 12, checksum, payload 01 02 03 04). This is the EXACT frame the
    // live gate asserts in the capture.
    const own_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const peer_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 };
    const own = [4]u8{ 10, 0, 0, 1 };
    const peer = [4]u8{ 10, 0, 0, 2 };
    var frame: [frame_max]u8 = undefined;
    const n = build_frame(&frame, &own_mac, own, peer_mac, peer, 9999, &.{ 1, 2, 3, 4 });
    try std.testing.expectEqual(@as(usize, 46), n);
    try std.testing.expectEqualSlices(u8, &peer_mac, frame[0..6]);
    try std.testing.expectEqualSlices(u8, &own_mac, frame[6..12]);
    try std.testing.expectEqual(@as(u8, 0x08), frame[12]);
    try std.testing.expectEqual(@as(u8, 0x00), frame[13]);
    try std.testing.expectEqual(@as(u8, 0x45), frame[14]);
    try std.testing.expectEqual(@as(u8, 32), frame[17]);
    try std.testing.expectEqual(@as(u8, 64), frame[22]);
    try std.testing.expectEqual(@as(u8, 17), frame[23]);
    try std.testing.expectEqual(@as(u16, 7000), (@as(u16, frame[34]) << 8) | frame[35]);
    try std.testing.expectEqual(@as(u16, 9999), (@as(u16, frame[36]) << 8) | frame[37]);
    try std.testing.expectEqual(@as(u16, 12), (@as(u16, frame[38]) << 8) | frame[39]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, frame[42..46]);
    // The IPv4 header checksum verifies (folds to 0x0000).
    try std.testing.expectEqual(@as(u16, 0x0000), fold(sum_words(frame[14..34])));
}

test "udp: listen table — add, duplicate, full, close" {
    reset();
    defer reset();
    try std.testing.expect(listen_port(7000));
    try std.testing.expect(!listen_port(7000)); // duplicate refused
    try std.testing.expect(listen_port(7001));
    try std.testing.expect(listen_port(7002));
    try std.testing.expect(listen_port(7003));
    try std.testing.expect(!listen_port(7004)); // table full
    try std.testing.expect(close_port(7001));
    try std.testing.expect(!close_port(7001)); // already closed
    try std.testing.expect(listen_port(7004)); // the freed slot is reusable
}

test "udp: peek — copies without consuming, is_listening distinguishes" {
    reset();
    defer reset();
    try std.testing.expect(!is_listening(7000));
    try std.testing.expect(listen_port(7000));
    try std.testing.expect(is_listening(7000));
    try std.testing.expect(is_listening(7001) == false);
    // An empty listener peeks null.
    try std.testing.expect(peek(7000) == null);
    // Deliver one datagram (loopback shape, src 7000 -> dst 7000).
    _ = loopback(.{ 10, 0, 0, 1 }, 7000, "ping");
    const d = peek(7000).?;
    try std.testing.expectEqual(@as(usize, 12), d.len);
    // peek does NOT consume: a second peek sees the SAME datagram, and
    // pop then drains it (the claim-1384 syscall recv ordering).
    try std.testing.expectEqual(@as(usize, 12), peek(7000).?.len);
    _ = pop(7000).?;
    try std.testing.expect(peek(7000) == null);
    try std.testing.expectEqual(@as(u64, 1), received);
}

test "udp: handle_rx — deliver to a listener, drop badsum / closed / short" {
    received = 0;
    dropped_badsum = 0;
    dropped_closed = 0;
    dropped_len = 0;
    reset();
    defer reset();
    try std.testing.expect(listen_port(7000));

    // A good datagram 10.0.0.2:9999 -> 10.0.0.1:7000 is delivered.
    var frame: [46]u8 = @splat(0);
    frame[12] = 0x08;
    frame[13] = 0x00; // ethertype IPv4
    frame[14] = 0x45;
    frame[16] = 0x00;
    frame[17] = 32; // total length 20 + 8 + 4
    frame[22] = 64;
    frame[23] = 17; // protocol UDP
    @memcpy(frame[26..30], &[_]u8{ 10, 0, 0, 2 });
    @memcpy(frame[30..34], &[_]u8{ 10, 0, 0, 1 });
    const dg_len = build_datagram(frame[34..46], .{ 10, 0, 0, 2 }, .{ 10, 0, 0, 1 }, 9999, 7000, &.{ 1, 2, 3, 4 });
    try std.testing.expectEqual(@as(usize, 12), dg_len);
    handle_rx(&frame);
    try std.testing.expectEqual(@as(u64, 1), received);
    const d = pop(7000).?;
    try std.testing.expectEqual(@as(usize, 12), d.len);
    try std.testing.expectEqualSlices(u8, frame[34..46], d.bytes[0..d.len]);

    // A datagram for a CLOSED port is dropped (counted).
    const saved = frame[36..38].*;
    frame[36] = 0x27;
    frame[37] = 0x0e; // dst port 9998 — no listener
    // Rebuild the checksum (zero the field first) so the drop lands in
    // the closed counter, not badsum.
    frame[40] = 0;
    frame[41] = 0;
    const src = [4]u8{ 10, 0, 0, 2 };
    const dst = [4]u8{ 10, 0, 0, 1 };
    const c = checksum_udp(src, dst, frame[34..46]);
    frame[40] = @truncate(c >> 8);
    frame[41] = @truncate(c);
    handle_rx(&frame);
    try std.testing.expectEqual(@as(u64, 1), dropped_closed);
    frame[36..38].* = saved;
    frame[40] = 0;
    frame[41] = 0;
    const c2 = checksum_udp(src, dst, frame[34..46]);
    frame[40] = @truncate(c2 >> 8);
    frame[41] = @truncate(c2);

    // A CORRUPTED payload is dropped (badsum) — the checksum catches it.
    frame[45] ^= 0xff;
    handle_rx(&frame);
    try std.testing.expectEqual(@as(u64, 1), dropped_badsum);
    frame[45] ^= 0xff;

    // A SHORT length (UDP length < 8) is dropped (length counter).
    frame[38] = 0x00;
    frame[39] = 0x04;
    handle_rx(&frame);
    try std.testing.expectEqual(@as(u64, 1), dropped_len);
}

test "udp: bounded per-listener buffer — drop-oldest at 4" {
    reset();
    received = 0;
    defer reset();
    try std.testing.expect(listen_port(7000));
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var dg: [9]u8 = undefined;
        const n = build_datagram(&dg, .{ 10, 0, 0, 1 }, .{ 10, 0, 0, 1 }, 7000, 7000, &.{@intCast(i)});
        try std.testing.expectEqual(@as(usize, 9), n);
        deliver(7000, .{ 10, 0, 0, 1 }, &dg);
    }
    try std.testing.expectEqual(@as(u64, 5), received); // all accepted
    // The oldest (payload 0) was dropped; the newest 4 remain.
    const d0 = pop(7000).?;
    try std.testing.expectEqual(@as(u8, 1), d0.bytes[8]);
    const d1 = pop(7000).?;
    try std.testing.expectEqual(@as(u8, 2), d1.bytes[8]);
    const d2 = pop(7000).?;
    try std.testing.expectEqual(@as(u8, 3), d2.bytes[8]);
    const d3 = pop(7000).?;
    try std.testing.expectEqual(@as(u8, 4), d3.bytes[8]);
    try std.testing.expect(pop(7000) == null); // drained
}

test "udp: loopback — send to our own IP delivers locally, no TX" {
    received = 0;
    sent = 0;
    loopbacked = 0;
    dropped_closed = 0;
    reset();
    defer reset();
    try std.testing.expect(listen_port(7000));
    const own = [4]u8{ 10, 0, 0, 1 };
    const n = loopback(own, 7000, &.{ 1, 2, 3, 4 });
    try std.testing.expectEqual(@as(usize, 12), n);
    try std.testing.expectEqual(@as(u64, 1), received);
    // The loopbacked datagram: src port 7000, dst port 7000, the payload.
    const d = pop(7000).?;
    try std.testing.expectEqual(@as(usize, 12), d.len);
    try std.testing.expectEqual(@as(u16, 7000), (@as(u16, d.bytes[0]) << 8) | d.bytes[1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, d.bytes[8..12]);
    // Loopback to a CLOSED port is dropped, counted, never assumed away.
    const m = loopback(own, 9998, &.{9});
    try std.testing.expectEqual(@as(usize, 9), m);
    try std.testing.expectEqual(@as(u64, 1), dropped_closed);
    try std.testing.expectEqual(@as(u64, 1), received); // only the 7000 one
}

test "udp: owned binds — owner_of, release_owned, release_owner, duplicate" {
    reset();
    defer reset();
    // An EL0 process (pid 7) binds an ephemeral port; a kernel caller
    // binds another with no owner.
    try std.testing.expect(listen_port_owned(49152, 7));
    try std.testing.expect(listen_port(7000));
    try std.testing.expectEqual(@as(?u64, 7), owner_of(49152));
    try std.testing.expectEqual(@as(?u64, unowned), owner_of(7000));
    try std.testing.expect(owner_of(9998) == null);
    // The port is claimed whoever asks: a second bind is a duplicate.
    try std.testing.expect(!listen_port_owned(49152, 8));
    try std.testing.expect(!listen_port(49152));
    // Only the owner may release it.
    try std.testing.expect(!release_owned(8, 49152));
    try std.testing.expect(!release_owned(unowned, 49152));
    try std.testing.expect(release_owned(7, 49152));
    try std.testing.expect(owner_of(49152) == null);
    // release_owner frees every seat the pid held, not the kernel's.
    try std.testing.expect(listen_port_owned(49152, 7));
    try std.testing.expect(listen_port_owned(49153, 7));
    try std.testing.expectEqual(@as(usize, 2), release_owner(7));
    try std.testing.expectEqual(@as(usize, 0), release_owner(7));
    try std.testing.expect(is_listening(7000));
    // A freed seat leaves its ring drained: after release + rebind the
    // stale datagram is not replayed.
    try std.testing.expect(listen_port_owned(49154, 9));
    deliver(49154, .{ 10, 0, 0, 2 }, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    try std.testing.expect(release_owned(9, 49154));
    try std.testing.expect(listen_port_owned(49154, 9));
    try std.testing.expect(pop(49154) == null);
}

test "udp: deliver keeps the sender's IPv4 address for the recv-from shape" {
    reset();
    defer reset();
    try std.testing.expect(listen_port_owned(49200, 3));
    deliver(49200, .{ 10, 0, 0, 2 }, &.{ 0, 53, 0, 1, 0, 9, 0xaa, 0xbb, 0x42 });
    const d = pop(49200).?;
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 2 }, &d.src_ip);
    try std.testing.expectEqual(@as(usize, 9), d.len);
    // A large datagram (over the old 64-byte bound) lands whole.
    var big: [300]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @intCast(i & 0xff);
    deliver(49200, .{ 93, 184, 216, 34 }, &big);
    const d2 = pop(49200).?;
    try std.testing.expectEqual(@as(usize, 300), d2.len);
    try std.testing.expectEqualSlices(u8, &.{ 93, 184, 216, 34 }, &d2.src_ip);
    try std.testing.expectEqualSlices(u8, &big, d2.bytes[0..d2.len]);
    // And the 512-byte bound itself is honest: a datagram one byte over
    // datagram_max (udp header + payload) is truncated, not refused.
    var over: [datagram_max + 1]u8 = undefined;
    for (&over, 0..) |*b, i| b.* = @intCast(i & 0xff);
    deliver(49200, .{ 10, 0, 0, 9 }, &over);
    const d3 = pop(49200).?;
    try std.testing.expectEqual(datagram_max, d3.len);
}
