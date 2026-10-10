//! VirelaiOS DNS client (RFC 1035) — milestone twelve, card N2 (claim 7566, Issue #149).
//!
//! Encodes standard RFC 1035 A-record queries targeting DNS port 53 over UDP,
//! parses DNS responses, extracts IPv4 addresses, and handles label decompression.
//!
//! Pure protocol logic and resolution state machine.

const std = @import("std");
const udp = @import("udp.zig");
const virtio_net = @import("virtio_net.zig");
const csprng = @import("csprng.zig");

pub const dns_port: u16 = 53;
pub const type_a: u16 = 1;
pub const class_in: u16 = 1;

pub const flag_response: u16 = 0x8000;
pub const flag_rd: u16 = 0x0100; // Recursion Desired
pub const flag_ra: u16 = 0x0080; // Recursion Available
pub const rcode_mask: u16 = 0x000F;
pub const rcode_ok: u16 = 0;
pub const rcode_nxdomain: u16 = 3;

pub const max_hostname_len: usize = 128;
pub const max_dns_pkt_len: usize = 512;

pub const DnsError = error{
    NameTooLong,
    InvalidName,
    BufferTooSmall,
    MalformedResponse,
    IdMismatch,
    QuestionMismatch,
    NonZeroRCode,
    NoAnswer,
    Timeout,
    TransportNotReady,
    SendFailed,
};

pub const State = enum {
    idle,
    query_sent,
    resolved,
    failed,
};

pub var state: State = .idle;
pub var query_id: u16 = 0;
pub var query_ticks: u64 = 0;
pub var resolved_ip: [4]u8 = .{ 0, 0, 0, 0 };
pub var queries_sent: u64 = 0;
pub var responses_recv: u64 = 0;
pub var responses_err: u64 = 0;
pub var timed_out: u64 = 0;

pub fn reset() void {
    state = .idle;
    query_id = 0;
    query_ticks = 0;
    resolved_ip = .{ 0, 0, 0, 0 };
    queries_sent = 0;
    responses_recv = 0;
    responses_err = 0;
    timed_out = 0;
}

/// Encode a standard RFC 1035 A-record DNS query for `hostname` into `buf`.
/// Returns the number of bytes written.
pub fn encode_query(buf: []u8, id: u16, hostname: []const u8) DnsError!usize {
    if (hostname.len == 0 or hostname.len > max_hostname_len) return DnsError.InvalidName;

    // Calculate required size: 12 (header) + encoded QNAME (hostname.len + 2) + 4 (QTYPE + QCLASS)
    const needed = 12 + hostname.len + 2 + 4;
    if (buf.len < needed) return DnsError.BufferTooSmall;

    // Header (12 bytes)
    std.mem.writeInt(u16, buf[0..2], id, .big);
    std.mem.writeInt(u16, buf[2..4], flag_rd, .big); // Standard query with RD=1
    std.mem.writeInt(u16, buf[4..6], 1, .big); // QDCOUNT = 1
    std.mem.writeInt(u16, buf[6..8], 0, .big); // ANCOUNT = 0
    std.mem.writeInt(u16, buf[8..10], 0, .big); // NSCOUNT = 0
    std.mem.writeInt(u16, buf[10..12], 0, .big); // ARCOUNT = 0

    // Question Section: QNAME
    var off: usize = 12;
    var start: usize = 0;
    while (start < hostname.len) {
        var end = start;
        while (end < hostname.len and hostname[end] != '.') : (end += 1) {}
        const label_len = end - start;
        if (label_len == 0 or label_len > 63) return DnsError.InvalidName;
        buf[off] = @truncate(label_len);
        off += 1;
        @memcpy(buf[off .. off + label_len], hostname[start..end]);
        off += label_len;
        start = if (end < hostname.len and hostname[end] == '.') end + 1 else end;
    }
    buf[off] = 0; // Terminating zero label
    off += 1;

    // QTYPE = 1 (A), QCLASS = 1 (IN)
    std.mem.writeInt(u16, buf[off..][0..2], type_a, .big);
    off += 2;
    std.mem.writeInt(u16, buf[off..][0..2], class_in, .big);
    off += 2;

    return off;
}

/// Skip a domain name in wire format (handling both labels and 0xC0 compression pointers).
/// Returns the offset immediately after the name in the packet.
fn skip_name(packet: []const u8, start_offset: usize) DnsError!usize {
    var off = start_offset;
    var hops: usize = 0;
    while (off < packet.len and hops < 32) : (hops += 1) {
        const len = packet[off];
        if (len == 0) {
            return off + 1;
        } else if ((len & 0xC0) == 0xC0) {
            // 2-byte compression pointer
            if (off + 2 > packet.len) return DnsError.MalformedResponse;
            return off + 2;
        } else if ((len & 0xC0) == 0) {
            // Plain label
            const label_len = @as(usize, len);
            off += 1 + label_len;
        } else {
            return DnsError.MalformedResponse;
        }
    }
    return DnsError.MalformedResponse;
}

/// Parse a raw DNS response packet and extract the IPv4 address from the first A record.
/// `expected_question` (M97e-F5, #2104): when non-null — the question
/// section of the outstanding query (bytes 12.. of the encoded query) —
/// the response's question section must echo it byte-exact. A forged
/// answer carrying the right id but a DIFFERENT name fails
/// `QuestionMismatch` before the answer records are trusted. (RFC 1035
/// servers echo the question verbatim; a case-rewritten or compressed
/// question is the honest bound — one question, always.)
pub fn parse_response(packet: []const u8, expected_id: u16, expected_question: ?[]const u8) DnsError![4]u8 {
    if (packet.len < 12) return DnsError.MalformedResponse;

    const id = std.mem.readInt(u16, packet[0..2], .big);
    if (id != expected_id) return DnsError.IdMismatch;

    const flags = std.mem.readInt(u16, packet[2..4], .big);
    if ((flags & flag_response) == 0) return DnsError.MalformedResponse; // Must be a response
    const rcode = flags & rcode_mask;
    if (rcode != rcode_ok) return DnsError.NonZeroRCode;

    const qdcount = std.mem.readInt(u16, packet[4..6], .big);
    const ancount = std.mem.readInt(u16, packet[6..8], .big);
    if (ancount == 0) return DnsError.NoAnswer;

    if (expected_question) |q| {
        if (qdcount != 1 or packet.len < 12 + q.len or !std.mem.eql(u8, packet[12 .. 12 + q.len], q))
            return DnsError.QuestionMismatch;
    }

    var off: usize = 12;

    // Skip question section(s)
    var q: usize = 0;
    while (q < qdcount) : (q += 1) {
        off = try skip_name(packet, off);
        if (off + 4 > packet.len) return DnsError.MalformedResponse;
        off += 4; // QTYPE + QCLASS
    }

    // Parse answer section
    var a: usize = 0;
    while (a < ancount and off < packet.len) : (a += 1) {
        off = try skip_name(packet, off);
        if (off + 10 > packet.len) return DnsError.MalformedResponse;

        const atype = std.mem.readInt(u16, packet[off..][0..2], .big);
        const aclass = std.mem.readInt(u16, packet[off + 2 ..][0..2], .big);
        // const ttl = std.mem.readInt(u32, packet[off + 4 ..][0..4], .big);
        const rdlength = std.mem.readInt(u16, packet[off + 8 ..][0..2], .big);
        off += 10;

        if (off + rdlength > packet.len) return DnsError.MalformedResponse;

        if (atype == type_a and aclass == class_in and rdlength == 4) {
            var ip: [4]u8 = undefined;
            @memcpy(&ip, packet[off .. off + 4]);
            return ip;
        }

        off += rdlength;
    }

    return DnsError.NoAnswer;
}

/// M97e-F5 (#2104): draw a fresh ephemeral client port from the IANA
/// dynamic range and bind it in the bounded listen table — a fixed port
/// let an off-path attacker spray replies at a known destination; a
/// forged reply must now guess the port as well as the query id. `null`
/// after a bounded number of draws (table full / collisions) — honest.
fn bind_ephemeral() ?u16 {
    var tries: usize = 0;
    while (tries < 8) : (tries += 1) {
        const port: u16 = 49152 + @as(u16, @truncate(csprng.random_u64())) % 16384;
        if (udp.listen_port(port)) return port;
    }
    return null;
}

/// Resolve `hostname` against `server_ip` using the kernel virtio-net transport.
/// The server is explicit — a resolver on a different subnet rides the
/// ARP layer's next-hop rule (the datagram's Ethernet dst is the default
/// gateway's MAC, its IPv4 dst stays `server_ip`); the gateway's own ARP
/// entry must be learned first (`net arp <server|gateway>`), exactly as
/// any other send.
pub fn resolve(hostname: []const u8, server_ip: [4]u8) DnsError![4]u8 {
    if (!virtio_net.net_ready) return DnsError.TransportNotReady;
    if (!virtio_net.arp.ip_set()) return DnsError.TransportNotReady;

    // M97e-F5: a fresh ephemeral client port per query, released on
    // every exit — the bounded listen table holds four seats and would
    // otherwise exhaust after four resolves.
    const client_port = bind_ephemeral() orelse return DnsError.TransportNotReady;
    defer _ = udp.close_port(client_port);

    const id: u16 = @truncate(csprng.random_u64());
    query_id = id;
    state = .query_sent;

    var query_buf: [udp.payload_max]u8 = undefined;
    const query_len = try encode_query(&query_buf, id, hostname);

    virtio_net.net_rx_drain();
    var out_len: usize = 0;
    switch (virtio_net.net_udp_send_from(server_ip, client_port, dns_port, query_buf[0..query_len], &out_len)) {
        .ok => {
            queries_sent += 1;
        },
        else => {
            state = .failed;
            return DnsError.SendFailed;
        },
    }

    var iterations: usize = 0;
    while (iterations < 1000000) : (iterations += 1) {
        virtio_net.net_rx_drain();
        if (udp.peek(client_port)) |d| {
            // M97e-F5: EVERY datagram on the port is consumed — a
            // wrong-ID or malformed datagram left on the ring head
            // permanently shadowed the real reply behind it (the wedge
            // the audit demonstrated).
            _ = udp.pop(client_port);
            if (d.len >= udp.udp_hdr_len) {
                const payload = d.bytes[udp.udp_hdr_len..d.len];
                if (parse_response(payload, id, query_buf[12..query_len])) |ip| {
                    resolved_ip = ip;
                    state = .resolved;
                    responses_recv += 1;
                    return ip;
                } else |err| {
                    if (err != DnsError.IdMismatch and err != DnsError.QuestionMismatch) {
                        responses_err += 1;
                        state = .failed;
                        return err;
                    }
                    // A foreign id/question echo: dropped, keep waiting.
                }
            }
        }
    }

    timed_out += 1;
    state = .failed;
    return DnsError.Timeout;
}

// ---------------------------------------------------------------------------
// Host tests
// ---------------------------------------------------------------------------

test "dns: query encoding for standard hostname" {
    var buf: [128]u8 = undefined;
    const n = try encode_query(&buf, 0x1234, "example.com");
    try std.testing.expectEqual(@as(usize, 29), n);

    // Header checks
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, buf[0..2], .big));
    try std.testing.expectEqual(@as(u16, 0x0100), std.mem.readInt(u16, buf[2..4], .big)); // RD=1
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[4..6], .big)); // QDCOUNT=1
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buf[6..8], .big)); // ANCOUNT=0

    // Question checks: 7 "example" 3 "com" 0
    try std.testing.expectEqual(@as(u8, 7), buf[12]);
    try std.testing.expectEqualStrings("example", buf[13..20]);
    try std.testing.expectEqual(@as(u8, 3), buf[20]);
    try std.testing.expectEqualStrings("com", buf[21..24]);
    try std.testing.expectEqual(@as(u8, 0), buf[24]);

    // QTYPE = 1, QCLASS = 1
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[25..][0..2], .big));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[27..][0..2], .big));
}

test "dns: response parsing with direct question and answer" {
    // Crafted DNS response for example.com -> 93.184.216.34
    const resp = [_]u8{
        // Header (12 bytes): ID 0x1234, Flags 0x8180, QD 1, AN 1, NS 0, AR 0
        0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
        // Question: \x07example\x03com\x00, TYPE A (1), CLASS IN (1)
        0x07, 'e',  'x',  'a',  'm',  'p',  'l',  'e',  0x03, 'c',  'o',  'm',
        0x00, 0x00, 0x01, 0x00, 0x01,
        // Answer: pointer to 0x0C (offset 12), TYPE A (1), CLASS IN (1), TTL 300, RDLENGTH 4, 93.184.216.34
        0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00, 0x01, 0x2C, 0x00, 0x04, 93,   184,  216,  34,
    };

    const ip = try parse_response(&resp, 0x1234, null);
    try std.testing.expectEqual([4]u8{ 93, 184, 216, 34 }, ip);
}

test "dns: M97e-F5 — the question echo must match the outstanding query" {
    // The same example.com response as the positive test — accepted with
    // the matching outstanding question, refused (QuestionMismatch)
    // against any other name before the answer is trusted.
    const resp = [_]u8{
        0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x07, 'e',  'x',  'a',  'm',  'p',  'l',  'e',  0x03, 'c',  'o',  'm',
        0x00, 0x00, 0x01, 0x00, 0x01, 0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00, 0x01, 0x2C, 0x00, 0x04, 93,   184,  216,  34,
    };
    // The question section of an encode_query("example.com"): bytes 12...
    var qbuf: [128]u8 = undefined;
    const qlen = try encode_query(&qbuf, 0x1234, "example.com");
    const ip = try parse_response(&resp, 0x1234, qbuf[12..qlen]);
    try std.testing.expectEqual([4]u8{ 93, 184, 216, 34 }, ip);

    // A different outstanding name: the echo does not match — refused.
    const qlen2 = try encode_query(&qbuf, 0x1234, "attacker.example");
    try std.testing.expectError(DnsError.QuestionMismatch, parse_response(&resp, 0x1234, qbuf[12..qlen2]));

    // And a packet that DROPPED the question (qdcount 0) is refused too.
    var no_q = resp;
    no_q[5] = 0;
    try std.testing.expectError(DnsError.QuestionMismatch, parse_response(&no_q, 0x1234, qbuf[12..qlen]));
}

test "dns: response error conditions" {
    // ID mismatch
    const resp1 = [_]u8{
        0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x03, 'f',  'o',  'o',  0x00, 0x00, 0x01, 0x00, 0x01, 0xC0, 0x0C, 0x00,
        0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04, 10,   0,    0,
        1,
    };
    try std.testing.expectError(DnsError.IdMismatch, parse_response(&resp1, 0x9999, null));

    // NXDOMAIN (RCODE = 3)
    const resp_nx = [_]u8{
        0x12, 0x34, 0x81, 0x83, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 'b',  'a',  'r',  0x00, 0x00, 0x01, 0x00, 0x01,
    };
    try std.testing.expectError(DnsError.NonZeroRCode, parse_response(&resp_nx, 0x1234, null));

    // No answers
    const resp_empty = [_]u8{
        0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 'b',  'a',  'z',  0x00, 0x00, 0x01, 0x00, 0x01,
    };
    try std.testing.expectError(DnsError.NoAnswer, parse_response(&resp_empty, 0x1234, null));
}
