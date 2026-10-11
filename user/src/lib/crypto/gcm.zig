//! AES-GCM (NIST SP 800-38D) — plain seal/open over a 96-bit nonce, the AEAD
//! TLS 1.3 uses for `TLS_AES_128_GCM_SHA256` and `TLS_AES_256_GCM_SHA384`
//! (RFC 8446 §5.2/§9.1). Freestanding, caller-buffered, no allocation.
//!
//! Scope, stated rather than implied:
//!   * 96-bit nonces only. That is the one length TLS 1.3 uses (RFC 8446
//!     §5.3 builds the per-record nonce as the static IV XOR the 64-bit
//!     sequence number, which is a 96-bit value), so the GHASH-based
//!     arbitrary-length-IV path is deliberately not implemented.
//!   * `open` verifies the tag with the constant-time compare from `ct.zig`
//!     and writes nothing to the output buffer when the tag does not match.
//!   * No heap, no libc; all buffers are caller-owned and their lengths are
//!     asserted rather than silently truncated.
//!
//! Verification (class A, `zig test`): 15 seal/open vectors from the generated
//! `aes_gcm_vectors.zig`, which includes the published NIST GCM test cases 1
//! and 2 (asserted inside the generator) plus synthetic coverage of empty
//! plaintext, empty AAD, 15/16/17-byte block boundaries, a 1 KiB payload and
//! a 60-byte AAD, plus negative tests for tag/ciphertext/AAD/nonce tampering.

const std = @import("std");
const aes = @import("aes.zig");
const ct = @import("ct.zig");

pub const tag_len = 16;
pub const nonce_len = 12;

/// Reduction polynomial for GF(2^128) with the GCM bit convention.
const R: u128 = 0xe1 << 120;

/// Multiplication in GF(2^128) per NIST SP 800-38D §6.3 (bit 0 = MSB).
fn mul(x: u128, y: u128) u128 {
    var z: u128 = 0;
    var v: u128 = y;
    var mask: u128 = @as(u128, 1) << 127;
    var i: usize = 0;
    while (i < 128) : (i += 1) {
        if (x & mask != 0) z ^= v;
        const lsb = v & 1;
        v >>= 1;
        if (lsb != 0) v ^= R;
        mask >>= 1;
    }
    return z;
}

fn load(b: *const [16]u8) u128 {
    return std.mem.readInt(u128, b, .big);
}

fn store(out: *[16]u8, x: u128) void {
    std.mem.writeInt(u128, out, x, .big);
}

/// Increment the low 32 bits of the counter block (GCM `inc32`).
fn inc32(cb: *[16]u8) void {
    const c = std.mem.readInt(u32, cb[12..16], .big) +% 1;
    std.mem.writeInt(u32, cb[12..16], c, .big);
}

/// GCTR (SP 800-38D §6.5): XOR `input` with the AES keystream starting at
/// `icb`, incrementing the low 32 bits per block.
fn gctr(k: *const aes.Aes, icb: *const [16]u8, input: []const u8, out: []u8) void {
    std.debug.assert(out.len == input.len);
    var cb: [16]u8 = icb.*;
    var block: [16]u8 = undefined;
    var off: usize = 0;
    while (off < input.len) {
        k.encryptBlock(&cb, &block);
        const n = @min(16, input.len - off);
        for (0..n) |i| out[off + i] = input[off + i] ^ block[i];
        inc32(&cb);
        off += n;
    }
}

/// GHASH (SP 800-38D §6.4) over AAD followed by ciphertext, each zero-padded
/// to a block boundary, then the 64-bit big-endian bit lengths of each.
fn ghash(h: u128, aad: []const u8, ciphertext: []const u8) u128 {
    var y: u128 = 0;
    var buf: [16]u8 = undefined;
    for ([2][]const u8{ aad, ciphertext }) |data| {
        var i: usize = 0;
        while (i < data.len) : (i += 16) {
            const n = @min(16, data.len - i);
            @memset(&buf, 0);
            @memcpy(buf[0..n], data[i..][0..n]);
            y = mul(y ^ load(&buf), h);
        }
    }
    var lenblk: [16]u8 = undefined;
    std.mem.writeInt(u64, lenblk[0..8], @as(u64, aad.len) * 8, .big);
    std.mem.writeInt(u64, lenblk[8..16], @as(u64, ciphertext.len) * 8, .big);
    return mul(y ^ load(&lenblk), h);
}

/// Derive the hash subkey H and the initial counter block J0 from `nonce`.
fn setup(k: *const aes.Aes, nonce: *const [12]u8, h: *u128, j0: *[16]u8) void {
    const zero = @as([16]u8, @splat(@as(u8, 0)));
    var hb: [16]u8 = undefined;
    k.encryptBlock(&zero, &hb);
    h.* = load(&hb);
    @memcpy(j0[0..12], nonce);
    std.mem.writeInt(u32, j0[12..16], 1, .big);
}

fn sealWith(
    k: *const aes.Aes,
    ciphertext: []u8,
    tag: *[tag_len]u8,
    pt: []const u8,
    aad: []const u8,
    nonce: *const [12]u8,
) void {
    std.debug.assert(ciphertext.len == pt.len);
    var h: u128 = undefined;
    var j0: [16]u8 = undefined;
    setup(k, nonce, &h, &j0);

    var icb = j0;
    inc32(&icb);
    gctr(k, &icb, pt, ciphertext);

    const s = ghash(h, aad, ciphertext);
    var sb: [16]u8 = undefined;
    store(&sb, s);
    var ek: [16]u8 = undefined;
    k.encryptBlock(&j0, &ek);
    for (0..tag_len) |i| tag[i] = ek[i] ^ sb[i];
}

fn computeTag(
    k: *const aes.Aes,
    h: u128,
    j0: *const [16]u8,
    ciphertext: []const u8,
    aad: []const u8,
) [tag_len]u8 {
    const s = ghash(h, aad, ciphertext);
    var sb: [16]u8 = undefined;
    store(&sb, s);
    var ek: [16]u8 = undefined;
    k.encryptBlock(j0, &ek);
    var out: [tag_len]u8 = undefined;
    for (0..tag_len) |i| out[i] = ek[i] ^ sb[i];
    return out;
}

fn openWith(
    k: *const aes.Aes,
    pt: []u8,
    ciphertext: []const u8,
    tag: *const [tag_len]u8,
    aad: []const u8,
    nonce: *const [12]u8,
) bool {
    std.debug.assert(pt.len == ciphertext.len);
    var h: u128 = undefined;
    var j0: [16]u8 = undefined;
    setup(k, nonce, &h, &j0);

    const expect = computeTag(k, h, &j0, ciphertext, aad);
    if (!ct.ctEq(&expect, tag)) return false;

    var icb = j0;
    inc32(&icb);
    gctr(k, &icb, ciphertext, pt);
    return true;
}

/// AES-128-GCM seal: `ciphertext` must be the same length as `pt`.
pub fn seal128(
    ciphertext: []u8,
    tag: *[tag_len]u8,
    pt: []const u8,
    aad: []const u8,
    nonce: *const [12]u8,
    key: *const [16]u8,
) void {
    const k = aes.Aes.init128(key);
    sealWith(&k, ciphertext, tag, pt, aad, nonce);
}

/// AES-128-GCM open. Returns false (and leaves `pt` untouched) on a bad tag.
pub fn open128(
    pt: []u8,
    ciphertext: []const u8,
    tag: *const [tag_len]u8,
    aad: []const u8,
    nonce: *const [12]u8,
    key: *const [16]u8,
) bool {
    const k = aes.Aes.init128(key);
    return openWith(&k, pt, ciphertext, tag, aad, nonce);
}

/// AES-256-GCM seal.
pub fn seal256(
    ciphertext: []u8,
    tag: *[tag_len]u8,
    pt: []const u8,
    aad: []const u8,
    nonce: *const [12]u8,
    key: *const [32]u8,
) void {
    const k = aes.Aes.init256(key);
    sealWith(&k, ciphertext, tag, pt, aad, nonce);
}

/// AES-256-GCM open. Returns false (and leaves `pt` untouched) on a bad tag.
pub fn open256(
    pt: []u8,
    ciphertext: []const u8,
    tag: *const [tag_len]u8,
    aad: []const u8,
    nonce: *const [12]u8,
    key: *const [32]u8,
) bool {
    const k = aes.Aes.init256(key);
    return openWith(&k, pt, ciphertext, tag, aad, nonce);
}

const vectors = @import("aes_gcm_vectors.zig");

fn decode(out: []u8, s: []const u8) void {
    _ = std.fmt.hexToBytes(out[0 .. s.len / 2], s) catch unreachable;
}

const max_pt = 1024;
const max_aad = 128;

test "gcm: seal matches all 15 generated vectors (incl. NIST GCM tc1/tc2)" {
    var k32: [32]u8 = undefined;
    var k16: [16]u8 = undefined;
    var nonce: [12]u8 = undefined;
    var aad: [max_aad]u8 = undefined;
    var pt: [max_pt]u8 = undefined;
    var expct: [max_pt]u8 = undefined;
    var gotct: [max_pt]u8 = undefined;
    var tag: [16]u8 = undefined;
    var exptag: [16]u8 = undefined;
    var back: [max_pt]u8 = undefined;
    var n: usize = 0;

    for (vectors.gcm) |v| {
        decode(&k32, v.key);
        @memcpy(&k16, k32[0..16]);
        decode(&nonce, v.nonce);
        decode(&aad, v.aad);
        decode(&pt, v.pt);
        decode(&expct, v.ct);
        decode(&exptag, v.tag);
        const ptlen = v.pt.len / 2;
        const ctlen = v.ct.len / 2;
        const aadlen = v.aad.len / 2;
        const is256 = v.key.len == 64;

        if (is256) {
            seal256(gotct[0..ptlen], &tag, pt[0..ptlen], aad[0..aadlen], &nonce, &k32);
        } else {
            seal128(gotct[0..ptlen], &tag, pt[0..ptlen], aad[0..aadlen], &nonce, &k16);
        }

        std.testing.expectEqualSlices(u8, expct[0..ctlen], gotct[0..ctlen]) catch |e| {
            std.debug.print("ciphertext mismatch: {s}\n", .{v.name});
            return e;
        };
        std.testing.expectEqualSlices(u8, &exptag, &tag) catch |e| {
            std.debug.print("tag mismatch: {s}\n", .{v.name});
            return e;
        };

        // Round trip.
        const ok = if (is256)
            open256(back[0..ctlen], gotct[0..ctlen], &tag, aad[0..aadlen], &nonce, &k32)
        else
            open128(back[0..ctlen], gotct[0..ctlen], &tag, aad[0..aadlen], &nonce, &k16);
        try std.testing.expect(ok);
        try std.testing.expectEqualSlices(u8, pt[0..ptlen], back[0..ctlen]);
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 15), n);
}

test "gcm: NIST GCM test case 1 and 2 tags are exactly the published values" {
    // Belt and braces: the generator asserts these too, but a silent change in
    // the vector file should fail here rather than only in the generator.
    const k = @as([16]u8, @splat(@as(u8, 0)));
    const nonce = @as([12]u8, @splat(@as(u8, 0)));
    var tag: [16]u8 = undefined;
    var out0: [0]u8 = undefined;
    var out16: [16]u8 = undefined;

    seal128(&out0, &tag, "", "", &nonce, &k);
    try std.testing.expectEqualSlices(u8, &(try hexLit("58e2fccefa7e3061367f1d57a4e7455a")), &tag);

    seal128(&out16, &tag, &(@as([16]u8, @splat(@as(u8, 0)))), "", &nonce, &k);
    try std.testing.expectEqualSlices(u8, &(try hexLit("ab6e47d42cec13bdf53a67b21257bddf")), &tag);
}

test "gcm: tampering fails closed and never writes plaintext" {
    const key = @as([16]u8, @splat(@as(u8, 0x11)));
    const nonce = @as([12]u8, @splat(@as(u8, 0x22)));
    const msg = "the quick brown fox jumps over the lazy dog";
    const aad = "record-header";

    var ciphertext: [msg.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    seal128(&ciphertext, &tag, msg, aad, &nonce, &key);

    var sentinel = @as([msg.len]u8, @splat(@as(u8, 0xAA)));
    var back: [msg.len]u8 = undefined;
    @memset(&back, 0xAA);

    // Correct input opens.
    try std.testing.expect(open128(&back, &ciphertext, &tag, aad, &nonce, &key));
    try std.testing.expectEqualSlices(u8, msg, &back);

    // Flipped tag bit.
    var bad_tag = tag;
    bad_tag[0] ^= 0x01;
    @memset(&back, 0xAA);
    try std.testing.expect(!open128(&back, &ciphertext, &bad_tag, aad, &nonce, &key));
    try std.testing.expectEqualSlices(u8, &sentinel, &back);

    // Flipped ciphertext bit.
    var bad_ct = ciphertext;
    bad_ct[msg.len - 1] ^= 0x80;
    @memset(&back, 0xAA);
    try std.testing.expect(!open128(&back, &bad_ct, &tag, aad, &nonce, &key));
    try std.testing.expectEqualSlices(u8, &sentinel, &back);

    // Wrong AAD.
    @memset(&back, 0xAA);
    try std.testing.expect(!open128(&back, &ciphertext, &tag, "record-headeR", &nonce, &key));

    // Wrong nonce.
    var bad_nonce = nonce;
    bad_nonce[0] ^= 0x01;
    @memset(&back, 0xAA);
    try std.testing.expect(!open128(&back, &ciphertext, &tag, aad, &bad_nonce, &key));

    // Wrong key.
    const bad_key = @as([16]u8, @splat(@as(u8, 0x12)));
    @memset(&back, 0xAA);
    try std.testing.expect(!open128(&back, &ciphertext, &tag, aad, &nonce, &bad_key));

    // Truncated ciphertext (length change must also fail).
    try std.testing.expect(!open128(back[0 .. msg.len - 1], ciphertext[0 .. msg.len - 1], &tag, aad, &nonce, &key));
}

test "gcm: empty plaintext still authenticates the AAD" {
    const key = @as([16]u8, @splat(@as(u8, 0x33)));
    const nonce = @as([12]u8, @splat(@as(u8, 0x44)));
    var tag: [16]u8 = undefined;
    var empty: [0]u8 = undefined;
    seal128(&empty, &tag, "", "aad-only", &nonce, &key);
    try std.testing.expect(open128(&empty, "", &tag, "aad-only", &nonce, &key));
    try std.testing.expect(!open128(&empty, "", &tag, "aad-onlz", &nonce, &key));
    try std.testing.expect(!open128(&empty, "", &tag, "", &nonce, &key));
}

fn hexLit(comptime s: []const u8) ![s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return error.BadHex;
    return out;
}
