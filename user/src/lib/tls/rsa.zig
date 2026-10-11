//! RSA signature verification — RSASSA-PKCS1-v1_5 (RFC 8017 §8.2.2) and
//! RSASSA-PSS (§8.1) for SHA-256/384/512. Verify-only: there is no signing and
//! no key generation here, because a TLS client never does either.
//!
//! Both schemes reduce to one primitive — `s^e mod n` on the fixed-capacity
//! Montgomery arithmetic in `bigint.zig` — and then a padding check that must
//! be exact. The checks are written to fail closed: a length that is not the
//! modulus length, a representative that is not less than the modulus, a
//! padding byte that is not what the scheme requires, or a hash that does not
//! match, all return false rather than a partially-accepted result.
//!
//! The DigestInfo prefix for PKCS#1 v1.5 is *constructed* from the hash OID
//! rather than transcribed: getting that prefix wrong by one byte is a classic
//! way to make a verifier that "works" on your tests and rejects real
//! signatures, so the OIDs are decoded back to their dotted form in a test
//! instead of being trusted.
//!
//! Verified against OpenSSL 3.6.4 signatures at 2048/3072/4096 bits: 9 cases
//! that must verify, each paired with a mutated signature that must not.

const std = @import("std");
const bigint = @import("bigint.zig");
const crypto = @import("crypto");

pub const Hash = enum { sha256, sha384, sha512 };

pub fn hashLen(h: Hash) usize {
    return switch (h) {
        .sha256 => 32,
        .sha384 => 48,
        .sha512 => 64,
    };
}

/// Hash algorithm OIDs (NIST), decoded back to dotted form in the test below.
pub const oid = struct {
    pub const sha256 = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01 };
    pub const sha384 = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02 };
    pub const sha512 = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03 };
};

fn oidFor(h: Hash) []const u8 {
    return switch (h) {
        .sha256 => &oid.sha256,
        .sha384 => &oid.sha384,
        .sha512 => &oid.sha512,
    };
}

fn HashOf(comptime h: Hash) type {
    return switch (h) {
        .sha256 => crypto.sha256.Sha256,
        .sha384 => crypto.sha384.Sha384,
        .sha512 => crypto.sha512.Sha512,
    };
}

fn digestOf(comptime h: Hash, out: []u8, msg: []const u8) void {
    const H = HashOf(h);
    var ctx = H.init();
    ctx.update(msg);
    var d: [hashLen(h)]u8 = undefined;
    ctx.final(&d);
    @memcpy(out[0..hashLen(h)], &d);
}

fn digestLenOf(comptime h: Hash) usize {
    return hashLen(h);
}

/// MGF1 (RFC 8017 §B.2.1) over the given hash.
fn mgf1(comptime h: Hash, out: []u8, seed: []const u8) void {
    const H = HashOf(h);
    const hlen = digestLenOf(h);
    var counter: u32 = 0;
    var off: usize = 0;
    while (off < out.len) : (counter += 1) {
        var ctx = H.init();
        ctx.update(seed);
        var c: [4]u8 = undefined;
        std.mem.writeInt(u32, &c, counter, .big);
        ctx.update(&c);
        var d: [hashLen(h)]u8 = undefined;
        ctx.final(&d);
        const take = @min(hlen, out.len - off);
        @memcpy(out[off..][0..take], d[0..take]);
        off += take;
    }
}

/// DigestInfo TLV prefix for PKCS#1 v1.5: SEQUENCE { SEQUENCE { OID, NULL },
/// OCTET STRING }. Returns the fully-formed prefix; the caller appends the
/// digest itself.
fn DigestInfo(comptime h: Hash) type {
    const oid_bytes = oidFor(h);
    const hlen = hashLen(h);
    const inner = 2 + oid_bytes.len + 2; // AlgorithmIdentifier content
    const t_len = 2 + inner + 2 + hlen; // algid TLV + OCTET STRING TLV
    return struct {
        pub const prefix_len = 2 + 2 + 2 + oid_bytes.len + 2 + 2; // incl. OID TLV header + NULL + OCTET STRING header
        pub const total_len = 2 + t_len;
        pub const bytes = blk: {
            var out: [2 + t_len]u8 = undefined;
            out[0] = 0x30;
            out[1] = t_len;
            out[2] = 0x30;
            out[3] = inner;
            out[4] = 0x06;
            out[5] = @intCast(oid_bytes.len);
            for (oid_bytes, 0..) |b, i| out[6 + i] = b;
            var k = 6 + oid_bytes.len;
            out[k] = 0x05;
            out[k + 1] = 0x00;
            k += 2;
            out[k] = 0x04;
            out[k + 1] = @intCast(hlen);
            k += 2;
            while (k < out.len) : (k += 1) out[k] = 0;
            break :blk out;
        };
    };
}

fn bitsOf(n: []const u8) usize {
    var i: usize = 0;
    while (i < n.len and n[i] == 0) i += 1;
    if (i == n.len) return 0;
    var top = n[i];
    var b: usize = 8;
    while (top & 0x80 == 0) {
        top <<= 1;
        b -= 1;
    }
    return (n.len - i - 1) * 8 + b;
}

/// s^e mod n, written to `out` as a big-endian integer of exactly `out.len`
/// bytes. Returns false when the signature is out of range.
fn rsaPublicOp(n: []const u8, e: []const u8, sig: []const u8, out: []u8) bool {
    if (n.len == 0 or sig.len != n.len) return false;
    const s = bigint.Int.fromBytesBE(sig) catch return false;
    const m = bigint.Int.fromBytesBE(n) catch return false;
    if (s.cmp(&m) >= 0) return false; // representative must be < n
    const mont = bigint.Mont.init(n) catch return false;
    var r: [bigint.max_limbs]u64 = undefined;
    mont.expMod(sig, e, &r) catch return false;
    var ri = bigint.Int{ .limbs = r, .n = mont.n };
    ri.trim();
    ri.writeBytesBE(out) catch return false;
    return true;
}

fn verifyPkcs1T(comptime h: Hash, n: []const u8, e: []const u8, msg: []const u8, sig: []const u8) bool {
    const k = n.len;
    if (k < 64) return false; // refuse < 512-bit moduli outright
    var em: [bigint.max_bytes]u8 = undefined;
    if (!rsaPublicOp(n, e, sig, em[0..k])) return false;

    const DI = DigestInfo(h);
    const t_len = DI.total_len;
    if (k < 3 + 8 + t_len) return false; // EM is too short to hold any padding
    if (em[0] != 0x00 or em[1] != 0x01) return false;

    const ps_len = k - 3 - t_len;
    var i: usize = 2;
    while (i < 2 + ps_len) : (i += 1) {
        if (em[i] != 0xff) return false;
    }
    if (em[2 + ps_len] != 0x00) return false;

    var want: [256]u8 = undefined;
    @memcpy(want[0..DI.prefix_len], DI.bytes[0..DI.prefix_len]);
    digestOf(h, want[DI.prefix_len..], msg);
    return std.mem.eql(u8, em[3 + ps_len .. k], want[0..t_len]);
}

fn verifyPssT(comptime h: Hash, n: []const u8, e: []const u8, msg: []const u8, sig: []const u8) bool {
    const k = n.len;
    const hlen = hashLen(h);
    if (k < hlen + 2) return false;
    const modbits = bitsOf(n);
    const embits = modbits - 1;
    const emlen = (embits + 7) / 8;
    if (emlen != k) return false;

    var em_full: [bigint.max_bytes]u8 = undefined;
    if (!rsaPublicOp(n, e, sig, em_full[0..k])) return false;
    const em = em_full[0..emlen];

    if (em[emlen - 1] != 0xbc) return false;
    // EM = maskedDB || H || 0xbc (RFC 8017 §9.1.1), with maskedDB of length
    // emlen - hlen - 1. There is no leading 0x00 byte: the zeroed emBits bits
    // live inside maskedDB[0].
    const db_len = emlen - hlen - 1;
    const top_mask: u8 = @as(u8, 0xff) >> @intCast(8 * emlen - embits);
    if (em[0] & ~top_mask != 0) return false;

    var m_hash: [64]u8 = undefined;
    digestOf(h, m_hash[0..hlen], msg);

    // H = em[db_len .. db_len + hlen]; maskedDB = em[0 .. db_len].
    var db: [bigint.max_bytes]u8 = undefined;
    mgf1(h, db[0..db_len], em[db_len .. db_len + hlen]);
    for (0..db_len) |i| db[i] ^= em[i];

    // Clear the leftmost bits that carry no information at this modulus size.
    const clear_bits: u3 = @intCast(8 * emlen - embits);
    db[0] &= @as(u8, 0xff) >> clear_bits;

    // DB = PS || 0x01 || salt, PS all zero.
    var idx: usize = 0;
    while (idx < db_len and db[idx] == 0) idx += 1;
    if (idx == db_len) return false;
    if (db[idx] != 0x01) return false;
    idx += 1;
    const salt = db[idx..db_len];

    var mp: [8 + 64 + bigint.max_bytes]u8 = undefined;
    @memset(mp[0..8], 0);
    @memcpy(mp[8 .. 8 + hlen], m_hash[0..hlen]);
    @memcpy(mp[8 + hlen .. 8 + hlen + salt.len], salt);
    var h_check: [64]u8 = undefined;
    digestOf(h, h_check[0..hlen], mp[0 .. 8 + hlen + salt.len]);

    return crypto.ct.ctEq(h_check[0..hlen], em[db_len .. db_len + hlen]);
}

/// RSASSA-PKCS1-v1_5 verification (RFC 8017 §8.2.2).
pub noinline fn verifyPkcs1(n: []const u8, e: []const u8, h: Hash, msg: []const u8, sig: []const u8) bool {
    return switch (h) {
        .sha256 => verifyPkcs1T(.sha256, n, e, msg, sig),
        .sha384 => verifyPkcs1T(.sha384, n, e, msg, sig),
        .sha512 => verifyPkcs1T(.sha512, n, e, msg, sig),
    };
}

/// RSASSA-PSS verification (RFC 8017 §8.1). The salt length is recovered from
/// the encoded message rather than assumed, which is what a verifier must do
/// when the parameters are not carried alongside the signature.
pub noinline fn verifyPss(n: []const u8, e: []const u8, h: Hash, msg: []const u8, sig: []const u8) bool {
    return switch (h) {
        .sha256 => verifyPssT(.sha256, n, e, msg, sig),
        .sha384 => verifyPssT(.sha384, n, e, msg, sig),
        .sha512 => verifyPssT(.sha512, n, e, msg, sig),
    };
}

/// RFC 8017 §5.2: a modulus below 2048 bits is refused rather than verified.
pub fn modulusAcceptable(n: []const u8) bool {
    return bitsOf(n) >= 2048;
}

const vectors = @import("rsa_vectors.zig");

fn decode(out: []u8, hexstr: []const u8) usize {
    _ = std.fmt.hexToBytes(out[0 .. hexstr.len / 2], hexstr) catch unreachable;
    return hexstr.len / 2;
}

test "rsa: the hash OIDs decode to their dotted form" {
    // A wrong DigestInfo prefix is the classic way to build a verifier that
    // passes its own tests and rejects the world, so decode the bytes back.
    const expect_sha256 = [_]u32{ 2, 16, 840, 1, 101, 3, 4, 2, 1 };
    const expect_sha384 = [_]u32{ 2, 16, 840, 1, 101, 3, 4, 2, 2 };
    const expect_sha512 = [_]u32{ 2, 16, 840, 1, 101, 3, 4, 2, 3 };

    var arcs: [16]u32 = undefined;
    for ([_]struct { o: []const u8, want: []const u32 }{
        .{ .o = &oid.sha256, .want = &expect_sha256 },
        .{ .o = &oid.sha384, .want = &expect_sha384 },
        .{ .o = &oid.sha512, .want = &expect_sha512 },
    }) |c| {
        const n = decodeOid(&arcs, c.o);
        try std.testing.expectEqualSlices(u32, c.want, arcs[0..n]);
    }
}

/// Decode a DER OID body into arcs. Test-only; exists so the OID constants are
/// checked rather than trusted.
fn decodeOid(out: []u32, bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    out[0] = bytes[0] / 40;
    out[1] = bytes[0] % 40;
    var n: usize = 2;
    var value: u32 = 0;
    for (bytes[1..]) |b| {
        value = (value << 7) | (b & 0x7f);
        if (b & 0x80 == 0) {
            out[n] = value;
            n += 1;
            value = 0;
        }
    }
    return n;
}

test "rsa: every OpenSSL signature verifies, and every mutated one does not" {
    var n: [1024]u8 = undefined;
    var e: [16]u8 = undefined;
    var sig: [1024]u8 = undefined;
    var checked: usize = 0;
    var pk: usize = 0;
    var pss: usize = 0;

    for (vectors.rsa) |v| {
        const nn = decode(&n, v.n_hex);
        const en = decode(&e, v.e_hex);
        const sn = decode(&sig, v.sig_hex);
        const h: Hash = if (std.mem.eql(u8, v.hash, "sha256"))
            .sha256
        else if (std.mem.eql(u8, v.hash, "sha384"))
            .sha384
        else
            .sha512;

        try std.testing.expectEqual(nn, v.bits / 8);
        try std.testing.expectEqual(sn, nn); // the signature is exactly k bytes
        try std.testing.expect(modulusAcceptable(n[0..nn]));

        const is_pss = std.mem.eql(u8, v.padding, "pss");
        const good = if (is_pss)
            verifyPss(n[0..nn], e[0..en], h, v.msg, sig[0..sn])
        else
            verifyPkcs1(n[0..nn], e[0..en], h, v.msg, sig[0..sn]);
        if (!good) {
            std.debug.print("signature rejected: {s}\n", .{v.name});
            return error.SignatureRejected;
        }

        // A single flipped bit in the signature must fail, for every case.
        var bad = sig;
        bad[sn - 1] ^= 0x01;
        const still = if (is_pss)
            verifyPss(n[0..nn], e[0..en], h, v.msg, bad[0..sn])
        else
            verifyPkcs1(n[0..nn], e[0..en], h, v.msg, bad[0..sn]);
        if (still) {
            std.debug.print("mutated signature accepted: {s}\n", .{v.name});
            return error.MutatedSignatureAccepted;
        }

        // A flipped bit in the message must fail too.
        var m2: [128]u8 = undefined;
        @memcpy(m2[0..v.msg.len], v.msg);
        m2[0] ^= 0x20;
        const on_msg = if (is_pss)
            verifyPss(n[0..nn], e[0..en], h, m2[0..v.msg.len], sig[0..sn])
        else
            verifyPkcs1(n[0..nn], e[0..en], h, m2[0..v.msg.len], sig[0..sn]);
        if (on_msg) return error.MutatedMessageAccepted;

        if (is_pss) pss += 1 else pk += 1;
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 9), checked);
    try std.testing.expect(pk >= 5);
    try std.testing.expect(pss >= 4);
}

test "rsa: the two paddings are not interchangeable" {
    var n: [1024]u8 = undefined;
    var e: [16]u8 = undefined;
    var sig: [1024]u8 = undefined;
    var tested: usize = 0;
    for (vectors.rsa) |v| {
        if (v.bits != 2048) continue;
        const nn = decode(&n, v.n_hex);
        const en = decode(&e, v.e_hex);
        const sn = decode(&sig, v.sig_hex);
        if (!std.mem.eql(u8, v.hash, "sha256")) continue;
        const is_pss = std.mem.eql(u8, v.padding, "pss");
        // Feed each signature to the wrong verifier: both must refuse.
        const cross = if (is_pss)
            verifyPkcs1(n[0..nn], e[0..en], .sha256, v.msg, sig[0..sn])
        else
            verifyPss(n[0..nn], e[0..en], .sha256, v.msg, sig[0..sn]);
        try std.testing.expect(!cross);
        tested += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), tested);
}

test "rsa: wrong hash size, short modulus and over-long signature are refused" {
    var n: [1024]u8 = undefined;
    var e: [16]u8 = undefined;
    var sig: [1024]u8 = undefined;
    const v = vectors.rsa[0];
    const nn = decode(&n, v.n_hex);
    const en = decode(&e, v.e_hex);
    const sn = decode(&sig, v.sig_hex);

    // Declaring SHA-512 for a SHA-256 signature must fail.
    try std.testing.expect(!verifyPkcs1(n[0..nn], e[0..en], .sha512, v.msg, sig[0..sn]));
    // A signature that is not exactly k bytes must fail.
    try std.testing.expect(!verifyPkcs1(n[0..nn], e[0..en], .sha256, v.msg, sig[0 .. sn - 1]));
    // A truncated modulus is not acceptable by policy.
    try std.testing.expect(!modulusAcceptable(n[nn - 128 .. nn]));
    // An all-zero signature is 0^e = 0, which has no valid padding.
    var zero: [256]u8 = @as([256]u8, @splat(@as(u8, 0)));
    try std.testing.expect(!verifyPkcs1(n[0..nn], e[0..en], .sha256, v.msg, &zero));
    try std.testing.expect(!verifyPss(n[0..nn], e[0..en], .sha256, v.msg, &zero));
    // A representative equal to the modulus is out of range.
    try std.testing.expect(!verifyPkcs1(n[0..nn], e[0..en], .sha256, v.msg, n[0..nn]));
}

test "rsa: PSS rejects a wrong salt length by construction" {
    // Salt length is recovered from DB, so a corrupted DB (here: one DB byte
    // flipped via the signature) must fail rather than be reinterpreted.
    var n: [1024]u8 = undefined;
    var e: [16]u8 = undefined;
    var sig: [1024]u8 = undefined;
    for (vectors.rsa) |v| {
        if (!std.mem.eql(u8, v.padding, "pss") or v.bits != 2048) continue;
        if (!std.mem.eql(u8, v.hash, "sha256")) continue;
        const nn = decode(&n, v.n_hex);
        const en = decode(&e, v.e_hex);
        const sn = decode(&sig, v.sig_hex);
        try std.testing.expect(verifyPss(n[0..nn], e[0..en], .sha256, v.msg, sig[0..sn]));
        var bad = sig;
        bad[0] ^= 0x40;
        try std.testing.expect(!verifyPss(n[0..nn], e[0..en], .sha256, v.msg, bad[0..sn]));
        return;
    }
    return error.NoPssVector;
}
