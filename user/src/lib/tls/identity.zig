//! Server identity matching (RFC 6125 §6 / RFC 9525 §6, tightened where the
//! TLS 1.3 profile requires it).
//!
//! The rules, in order:
//!   1. If the host is an IP literal, it is compared **only** against
//!      iPAddress SAN entries. The CN is never consulted for an IP, because a
//!      CN is not an address and the old behaviour of matching one was the bug,
//!      not the feature.
//!   2. Otherwise the host is a DNS name. If the certificate carries a
//!      subjectAltName extension at all, **only** the dNSName entries are
//!      consulted — the CN is ignored even when the SANs do not match. This is
//!      the RFC 9525 rule and it removes the "certificate says one thing in
//!      SAN and another in CN" ambiguity entirely.
//!   3. Only if there is no SAN extension at all does the CN fall back into
//!      use. That path is legacy, and it is *reported* in the verdict
//!      (`match_cn_fallback`) so a caller can surface or reject it.
//!   4. Anything that does not match, and anything ambiguous, fails closed.
//!
//! Wildcards: `*` is accepted only as the entire left-most label, only in a
//! pattern of the form `*.` followed by at least two more labels (so `*.com`
//! is refused — without a public-suffix list that is the strongest rule that
//! can be enforced locally), and it matches exactly one label, so
//! `*.example.com` does not match `example.com` nor `a.b.example.com`.

const std = @import("std");
const x509 = @import("x509.zig");

pub const Verdict = enum {
    /// Exact match against a dNSName SAN.
    match_dns,
    /// Wildcard match against a dNSName SAN.
    match_wildcard,
    /// Match against an iPAddress SAN.
    match_ip,
    /// No SAN extension; matched the commonName. Legacy path, surfaced on purpose.
    match_cn_fallback,
    /// The certificate offers nothing this host could match.
    no_match,
    /// More than one distinct wildcard pattern matched the host.
    ambiguous,
    /// The host name itself is not something we will match (empty label, bad
    /// octet, trailing dot).
    malformed_host,
    /// No SAN and no CN: nothing to compare against.
    no_identity,
};

pub fn isLiteralIp(host: []const u8) bool {
    return parseIpLiteral(host) != null;
}

/// Parse an IPv4 or IPv6 literal into the v4-mapped 16-byte form used by
/// iPAddress SANs. Returns null when the text is not a literal.
pub fn parseIpLiteral(host: []const u8) ?[16]u8 {
    if (std.mem.indexOfScalar(u8, host, ':') != null) return parseIpv6(host);
    return parseIpv4(host);
}

fn parseIpv4(s: []const u8) ?[16]u8 {
    var parts: [4]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (n < 4) {
        if (i >= s.len) return null;
        var v: u32 = 0;
        var digits: usize = 0;
        while (i < s.len and s[i] != '.') : (i += 1) {
            if (s[i] < '0' or s[i] > '9') return null;
            v = v * 10 + (s[i] - '0');
            if (v > 255) return null;
            digits += 1;
            if (digits > 3) return null;
        }
        if (digits == 0) return null;
        if (digits > 1 and s[i - digits] == '0') return null; // no leading zeros
        parts[n] = @intCast(v);
        n += 1;
        if (i < s.len) {
            i += 1; // consume the dot
            if (n == 4) return null; // a fifth group
        }
    }
    if (i != s.len) return null;
    var out = @as([16]u8, @splat(@as(u8, 0)));
    out[10] = 0xff;
    out[11] = 0xff;
    @memcpy(out[12..16], &parts);
    return out;
}

fn hexDigit(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

fn parseGroups(out: *[8]u16, str: []const u8) ?usize {
    if (str.len == 0) return 0;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, str, ':');
    while (it.next()) |tok| {
        if (tok.len == 0) return null; // empty group ("::" handled by the caller)
        if (std.mem.indexOfScalar(u8, tok, '.') != null) {
            const v4 = parseIpv4(tok) orelse return null;
            if (n + 2 > 8) return null;
            out[n] = (@as(u16, v4[12]) << 8) | v4[13];
            out[n + 1] = (@as(u16, v4[14]) << 8) | v4[15];
            n += 2;
            continue;
        }
        if (tok.len > 4) return null;
        var v: u16 = 0;
        for (tok) |c| {
            const d = hexDigit(c) orelse return null;
            v = (v << 4) | d;
        }
        if (n >= 8) return null;
        out[n] = v;
        n += 1;
    }
    return n;
}

fn parseIpv6(s: []const u8) ?[16]u8 {
    var head: [8]u16 = undefined;
    var tail: [8]u16 = undefined;

    var has_compression = false;
    var head_str: []const u8 = s;
    var tail_str: []const u8 = "";

    // Split on the first "::", which is the compression marker. A single ':'
    // is just a separator; treating it as compression is how "2001:db8::1"
    // silently becomes a different address.
    if (std.mem.indexOf(u8, s, "::")) |idx| {
        has_compression = true;
        head_str = s[0..idx];
        tail_str = s[idx + 2 ..];
        if (std.mem.indexOf(u8, tail_str, "::") != null) return null; // two "::"
    }

    const head_len = parseGroups(&head, head_str) orelse return null;
    const tail_len = parseGroups(&tail, tail_str) orelse return null;

    // Without "::" the address must be exactly eight groups.
    if (!has_compression and head_len != 8) return null;
    if (head_len + tail_len > 8) return null;

    var out: [16]u8 = undefined;
    for (0..head_len) |k| {
        out[2 * k] = @truncate(head[k] >> 8);
        out[2 * k + 1] = @truncate(head[k]);
    }
    const zeros = 8 - head_len - tail_len;
    for (0..zeros) |k| {
        out[2 * (head_len + k)] = 0;
        out[2 * (head_len + k) + 1] = 0;
    }
    for (0..tail_len) |k| {
        const idx2 = head_len + zeros + k;
        out[2 * idx2] = @truncate(tail[k] >> 8);
        out[2 * idx2 + 1] = @truncate(tail[k]);
    }
    return out;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Does a dNSName SAN entry match `host`? Pattern may contain one wildcard.
pub fn matchDns(pattern: []const u8, host: []const u8) bool {
    if (pattern.len == 0 or host.len == 0) return false;
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) {
        return asciiEqlIgnoreCase(pattern, host);
    }
    return matchWildcard(pattern, host);
}

fn matchWildcard(pattern: []const u8, host: []const u8) bool {
    if (pattern.len < 4 or pattern[0] != '*' or pattern[1] != '.') return false;
    const suffix = pattern[2..];
    if (suffix.len == 0) return false;
    // No second wildcard, and no wildcard anywhere but the first label.
    if (std.mem.indexOfScalar(u8, suffix, '*') != null) return false;
    // Refuse `*.com`-style patterns: without a public-suffix list, "at least
    // two labels after the wildcard" is the strongest local rule.
    if (std.mem.indexOfScalar(u8, suffix, '.') == null) return false;
    // The host must be suffix with exactly one extra, non-empty label.
    if (host.len <= suffix.len + 1) return false;
    const dot = host.len - suffix.len - 1;
    if (host[dot] != '.') return false;
    if (dot == 0) return false; // empty wildcard label
    // And that label must not itself contain a dot (guaranteed by dot's
    // position, but assert the shape explicitly).
    if (std.mem.indexOfScalar(u8, host[0..dot], '.') != null) return false;
    return asciiEqlIgnoreCase(host[dot + 1 ..], suffix);
}

/// A host we are willing to compare. Rejects empty labels, a trailing dot, and
/// anything with a character that cannot appear in a DNS name.
fn hostIsSane(host: []const u8) bool {
    if (host.len == 0 or host.len > 253) return false;
    if (host[host.len - 1] == '.') return false;
    if (host[0] == '.') return false;
    var prev_dot = true; // so a leading dot is caught by the check above
    for (host) |c| {
        const allowed = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        if (!allowed) return false;
        if (c == '.' and prev_dot) return false; // empty label
        prev_dot = c == '.';
    }
    return true;
}

/// Verify `host` against `cert`.
pub fn verify(cert: *const x509.Cert, host: []const u8) Verdict {
    if (host.len == 0) return .malformed_host;

    if (parseIpLiteral(host)) |ip| {
        // IP literals: iPAddress SANs only, never the CN.
        for (cert.san[0..cert.san_len]) |g| {
            switch (g) {
                .ip => |san_ip| if (std.mem.eql(u8, &san_ip, &ip)) return .match_ip,
                .dns => {},
            }
        }
        return .no_match;
    }

    if (!hostIsSane(host)) return .malformed_host;

    if (cert.has_san) {
        var saw_exact = false;
        var wildcard_hits: usize = 0;
        for (cert.san[0..cert.san_len]) |g| {
            const pat = switch (g) {
                .dns => |d| d,
                .ip => continue,
            };
            if (std.mem.indexOfScalar(u8, pat, '*') != null) {
                if (matchWildcard(pat, host)) wildcard_hits += 1;
            } else if (asciiEqlIgnoreCase(pat, host)) {
                saw_exact = true;
            }
        }
        if (saw_exact) return .match_dns;
        if (wildcard_hits == 0) return .no_match;
        if (wildcard_hits > 1) return .ambiguous;
        return .match_wildcard;
    }

    // No SAN extension at all: the legacy CN fallback, reported as such.
    const cn = cert.subject_cn orelse return .no_identity;
    if (asciiEqlIgnoreCase(cn, host)) return .match_cn_fallback;
    return .no_match;
}

/// Convenience: did verification succeed at all?
pub fn ok(v: Verdict) bool {
    return switch (v) {
        .match_dns, .match_wildcard, .match_ip => true,
        // Deliberately excluded from `ok`: a caller who wants to accept the
        // legacy CN path must say so explicitly by comparing the verdict.
        else => false,
    };
}

const vectors = @import("x509_vectors.zig");

fn hexToBytes(out: []u8, s: []const u8) usize {
    _ = std.fmt.hexToBytes(out[0 .. s.len / 2], s) catch unreachable;
    return s.len / 2;
}

const Case = struct {
    pattern: []const u8,
    host: []const u8,
    matches: bool,
};

test "identity: hostname matching table" {
    const cases = [_]Case{
        // exact
        .{ .pattern = "example.com", .host = "example.com", .matches = true },
        .{ .pattern = "example.com", .host = "EXAMPLE.COM", .matches = true },
        .{ .pattern = "example.com", .host = "www.example.com", .matches = false },
        .{ .pattern = "example.com", .host = "example.com.evil.test", .matches = false },
        .{ .pattern = "example.com", .host = "xample.com", .matches = false },
        // wildcard: exactly one label
        .{ .pattern = "*.example.com", .host = "www.example.com", .matches = true },
        .{ .pattern = "*.example.com", .host = "Www.Example.Com", .matches = true },
        .{ .pattern = "*.example.com", .host = "example.com", .matches = false },
        .{ .pattern = "*.example.com", .host = "a.b.example.com", .matches = false },
        .{ .pattern = "*.example.com", .host = ".example.com", .matches = false },
        .{ .pattern = "*.example.com", .host = "wwwexample.com", .matches = false },
        // wildcard not in the left-most label is not a wildcard at all
        .{ .pattern = "www.*.com", .host = "www.example.com", .matches = false },
        .{ .pattern = "www.ex*.com", .host = "www.example.com", .matches = false },
        // wildcard in the public-suffix position is refused
        .{ .pattern = "*.com", .host = "example.com", .matches = false },
        // A one-local-part suffix like `co.uk` is structurally identical to
        // `example.com`, so a wildcard there cannot be refused without a
        // public-suffix list, which this library does not ship. The bound is
        // stated in the file header rather than pretended away.
        .{ .pattern = "*.co.uk", .host = "example.co.uk", .matches = true },
        // a bare "*" matches nothing
        .{ .pattern = "*", .host = "example.com", .matches = false },
        .{ .pattern = "**.example.com", .host = "a.example.com", .matches = false },
    };
    for (cases) |c| {
        if (c.matches != matchDns(c.pattern, c.host)) {
            std.debug.print("matchDns({s}, {s}) != {}\n", .{ c.pattern, c.host, c.matches });
            return error.HostnameTableMismatch;
        }
    }
}

test "identity: IP literal parsing" {
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1 }, &parseIpLiteral("127.0.0.1").?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 255, 255, 255, 255 }, &parseIpLiteral("255.255.255.255").?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, &parseIpLiteral("2001:db8::1").?);
    try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(@as(u8, 0)))), &parseIpLiteral("::").?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 0, 1 }, &parseIpLiteral("::ffff:192.168.0.1").?);

    // Not literals.
    try std.testing.expect(parseIpLiteral("example.com") == null);
    try std.testing.expect(parseIpLiteral("256.0.0.1") == null);
    try std.testing.expect(parseIpLiteral("1.2.3") == null);
    try std.testing.expect(parseIpLiteral("1.2.3.4.5") == null);
    try std.testing.expect(parseIpLiteral("01.2.3.4") == null); // leading zeros are not a literal
    try std.testing.expect(parseIpLiteral("2001:db8::1::2") == null);
    try std.testing.expect(parseIpLiteral("2001:db8:1") == null);
}

test "identity: verify against the generated certificates" {
    var derbuf: [8192]u8 = undefined;

    {
        const n = hexToBytes(&derbuf, vectors.byName("leaf-ec").der_hex);
        var cert: x509.Cert = .{};
        try x509.Cert.parse(derbuf[0..n], &cert);
        try std.testing.expectEqual(Verdict.match_dns, verify(&cert, "leaf.example.com"));
        try std.testing.expectEqual(Verdict.match_dns, verify(&cert, "LEAF.EXAMPLE.COM"));
        try std.testing.expectEqual(Verdict.match_wildcard, verify(&cert, "anything.wild.example.com"));
        try std.testing.expectEqual(Verdict.no_match, verify(&cert, "wild.example.com"));
        try std.testing.expectEqual(Verdict.no_match, verify(&cert, "a.b.wild.example.com"));
        // SAN present, CN does not match: the CN must NOT rescue it.
        try std.testing.expectEqual(Verdict.no_match, verify(&cert, "other.example.com"));
        try std.testing.expect(ok(verify(&cert, "leaf.example.com")));
    }

    {
        const n = hexToBytes(&derbuf, vectors.byName("leaf-ip").der_hex);
        var cert: x509.Cert = .{};
        try x509.Cert.parse(derbuf[0..n], &cert);
        try std.testing.expectEqual(Verdict.match_ip, verify(&cert, "127.0.0.1"));
        try std.testing.expectEqual(Verdict.match_ip, verify(&cert, "2001:db8::1"));
        try std.testing.expectEqual(Verdict.no_match, verify(&cert, "127.0.0.2"));
        // A DNS name must not match an IP-only SAN set, even though the CN is
        // ip.example.com.
        try std.testing.expectEqual(Verdict.no_match, verify(&cert, "ip.example.com"));
        try std.testing.expectEqual(Verdict.no_match, verify(&cert, "::1"));
    }

    {
        const n = hexToBytes(&derbuf, vectors.byName("leaf-nosan").der_hex);
        var cert: x509.Cert = .{};
        try x509.Cert.parse(derbuf[0..n], &cert);
        try std.testing.expectEqual(Verdict.match_cn_fallback, verify(&cert, "cnonly.example.com"));
        try std.testing.expectEqual(Verdict.no_match, verify(&cert, "other.example.com"));
        // The legacy path is deliberately not "ok" by the convenience helper.
        try std.testing.expect(!ok(verify(&cert, "cnonly.example.com")));
    }

    {
        const n = hexToBytes(&derbuf, vectors.byName("leaf-ec").der_hex);
        var cert: x509.Cert = .{};
        try x509.Cert.parse(derbuf[0..n], &cert);
        try std.testing.expectEqual(Verdict.malformed_host, verify(&cert, "bad host.example.com"));
        try std.testing.expectEqual(Verdict.malformed_host, verify(&cert, "trailing.example.com."));
        try std.testing.expectEqual(Verdict.malformed_host, verify(&cert, "double..dot.example.com"));
    }
}
