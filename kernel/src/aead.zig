//! Kernel ChaCha20-Poly1305 AEAD (RFC 8439 §2.8), M172b, ADR 0023.
//!
//! Kernel-local port of the EL0 library's `user/src/lib/crypto/aead.zig`
//! and its `chacha20.zig` / `poly1305.zig` / `ct.zig` dependencies, merged
//! into this one file. ADR 0023 D2 forbids the kernel importing the
//! userland library (the same rule csprng.zig and measure.zig follow — no
//! shared translation unit across the `kernel/`-`user/` boundary), so the
//! primitives are carried here and drift-guarded by the SAME RFC 8439
//! vectors pinned in both test roots: §2.3.2 block function, §2.5.2
//! Poly1305, and the §2.8.2 AEAD. `csprng.zig` holds a sibling ChaCha20
//! block function for its own stream use; this copy is the AEAD's.
//!
//! The construction: the Poly1305 one-time key is the first 32 bytes of
//! the ChaCha20 block at counter 0; the ciphertext is ChaCha20 with
//! counter 1; the tag authenticates AAD‖pad‖ciphertext‖pad‖len(AAD)‖
//! len(ciphertext) (all little-endian, padded to 16). `open` compares the
//! tag with a no-early-exit scan and refuses before decrypting.
//!
//! LIMIT (ADR 0023 D3): the constant-time compare is cache/branch
//! discipline, not a hardened power/EM defense; lengths are public by
//! contract. No libc, no POSIX, no allocation.

const std = @import("std");

pub const key_len = 32;
pub const nonce_len = 12;
pub const tag_len = 16;

// ---------------------------------------------------------------------------
// ChaCha20 (RFC 8439 §2.3–2.4) — port of user/src/lib/crypto/chacha20.zig
// ---------------------------------------------------------------------------

const chacha_block_len = 64;

// RFC 8439 §2.3 constants: "expa" "nd 3" "2-by" "te k".
const c0: u32 = 0x61707865;
const c1: u32 = 0x3320646e;
const c2: u32 = 0x79622d32;
const c3: u32 = 0x6b206574;

fn rotl(x: u32, n: u5) u32 {
    return (x << n) | (x >> @intCast(32 - @as(u6, n)));
}

/// RFC 8439 §2.1 quarter round over four state words addressed by index.
fn quarter_round(state: *[16]u32, a: usize, b: usize, c: usize, d: usize) void {
    state[a] +%= state[b];
    state[d] ^= state[a];
    state[d] = rotl(state[d], 16);
    state[c] +%= state[d];
    state[b] ^= state[c];
    state[b] = rotl(state[b], 12);
    state[a] +%= state[b];
    state[d] ^= state[a];
    state[d] = rotl(state[d], 8);
    state[c] +%= state[d];
    state[b] ^= state[c];
    state[b] = rotl(state[b], 7);
}

/// RFC 8439 §2.3.1/§2.3.2: one 64-byte ChaCha20 block. `counter` is the
/// 32-bit block count (state word 12); `nonce` is 12 bytes (words 13–15).
fn chacha20_block(key: *const [key_len]u8, counter: u32, nonce: *const [nonce_len]u8, out: *[chacha_block_len]u8) void {
    var state: [16]u32 = undefined;
    state[0] = c0;
    state[1] = c1;
    state[2] = c2;
    state[3] = c3;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        state[4 + i] = std.mem.readInt(u32, key[i * 4 ..][0..4], .little);
    }
    state[12] = counter;
    var j: usize = 0;
    while (j < 3) : (j += 1) {
        state[13 + j] = std.mem.readInt(u32, nonce[j * 4 ..][0..4], .little);
    }
    var working = state;
    var round: usize = 0;
    while (round < 10) : (round += 1) {
        quarter_round(&working, 0, 4, 8, 12);
        quarter_round(&working, 1, 5, 9, 13);
        quarter_round(&working, 2, 6, 10, 14);
        quarter_round(&working, 3, 7, 11, 15);
        quarter_round(&working, 0, 5, 10, 15);
        quarter_round(&working, 1, 6, 11, 12);
        quarter_round(&working, 2, 7, 8, 13);
        quarter_round(&working, 3, 4, 9, 14);
    }
    var k: usize = 0;
    while (k < 16) : (k += 1) {
        std.mem.writeInt(u32, out[k * 4 ..][0..4], working[k] +% state[k], .little);
    }
}

/// XOR `in` with the ChaCha20 keystream starting at block `counter`.
/// `out.len` must equal `in.len`; `out` and `in` may alias. No allocation.
fn chacha20_xor_stream(out: []u8, in: []const u8, key: *const [key_len]u8, counter: u32, nonce: *const [nonce_len]u8) void {
    var ctr = counter;
    var ks: [chacha_block_len]u8 = undefined;
    var off: usize = 0;
    while (off < in.len) {
        chacha20_block(key, ctr, nonce, &ks);
        ctr +%= 1;
        const take = @min(chacha_block_len, in.len - off);
        for (0..take) |i| out[off + i] = in[off + i] ^ ks[i];
        off += take;
    }
}

// ---------------------------------------------------------------------------
// Poly1305 (RFC 8439 §2.5) — port of user/src/lib/crypto/poly1305.zig
// ---------------------------------------------------------------------------

const p130: u256 = (1 << 130) - 5;
const mask130: u512 = (1 << 130) - 1;

fn mul_mod(a: u256, b: u256) u256 {
    var v: u512 = @as(u512, a) * @as(u512, b);
    // Fold the bits above 130 with 2^130 ≡ 5. Three folds take the
    // product (< 2^255) below 2^130.
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const lo = v & mask130;
        const hi = v >> 130;
        v = lo + hi * 5;
    }
    var r: u256 = @truncate(v);
    const ge = r >= p130;
    r = if (ge) r - p130 else r;
    return r;
}

const Poly1305 = struct {
    r: u256,
    s: u128,
    acc: u256 = 0,
    buf: [16]u8 = undefined,
    buf_len: usize = 0,

    fn init(key: *const [32]u8) Poly1305 {
        var rb: [16]u8 = key[0..16].*;
        rb[3] &= 15;
        rb[7] &= 15;
        rb[11] &= 15;
        rb[15] &= 15;
        rb[4] &= 252;
        rb[8] &= 252;
        rb[12] &= 252;
        var r: u256 = 0;
        for (0..16) |i| r |= @as(u256, rb[i]) << @intCast(8 * i);
        var s: u128 = 0;
        for (0..16) |i| s |= @as(u128, key[16 + i]) << @intCast(8 * i);
        return .{ .r = r, .s = s };
    }

    fn update(self: *Poly1305, bytes: []const u8) void {
        var i: usize = 0;
        if (self.buf_len != 0) {
            const need = 16 - self.buf_len;
            const take = @min(need, bytes.len);
            @memcpy(self.buf[self.buf_len..][0..take], bytes[0..take]);
            self.buf_len += take;
            i += take;
            if (self.buf_len == 16) {
                self.absorb(&self.buf, 16);
                self.buf_len = 0;
            }
        }
        while (i + 16 <= bytes.len) : (i += 16) {
            self.absorb(bytes[i..][0..16], 16);
        }
        if (i < bytes.len) {
            const tail = bytes.len - i;
            @memcpy(self.buf[0..tail], bytes[i..]);
            self.buf_len = tail;
        }
    }

    fn final(self: *Poly1305, out: *[16]u8) void {
        if (self.buf_len != 0) {
            self.absorb(&self.buf, self.buf_len);
            self.buf_len = 0;
        }
        const sum = self.acc + self.s;
        for (0..16) |i| out[i] = @truncate(sum >> @intCast(8 * i));
    }

    fn absorb(self: *Poly1305, blk: *const [16]u8, nbytes: usize) void {
        var n: u256 = 0;
        for (0..nbytes) |i| n |= @as(u256, blk[i]) << @intCast(8 * i);
        n += @as(u256, 1) << @intCast(8 * nbytes);
        self.acc = mul_mod(self.acc + n, self.r);
    }
};

// ---------------------------------------------------------------------------
// Constant-time compare — port of user/src/lib/crypto/ct.zig's ctEq
// ---------------------------------------------------------------------------

/// Equal-length comparison with no early exit. If the lengths differ the
/// result is false, but the length is assumed public (ADR 0023 D3).
fn ct_eq(a: []const u8, b: []const u8) bool {
    var diff: u8 = 0;
    const n = @min(a.len, b.len);
    for (0..n) |i| diff |= a[i] ^ b[i];
    diff |= @as(u8, @intFromBool(a.len != b.len));
    return diff == 0;
}

// ---------------------------------------------------------------------------
// The AEAD (RFC 8439 §2.8) — port of user/src/lib/crypto/aead.zig
// ---------------------------------------------------------------------------

fn pad_len(n: usize) usize {
    return (16 - (n & 15)) & 15;
}

fn mac(tag: *[tag_len]u8, ciphertext: []const u8, aad: []const u8, pkey: *const [32]u8) void {
    var p = Poly1305.init(pkey);
    const zeros = @as([16]u8, @splat(@as(u8, 0)));
    p.update(aad);
    p.update(zeros[0..pad_len(aad.len)]);
    p.update(ciphertext);
    p.update(zeros[0..pad_len(ciphertext.len)]);
    var lens: [16]u8 = undefined;
    std.mem.writeInt(u64, lens[0..8], @intCast(aad.len), .little);
    std.mem.writeInt(u64, lens[8..16], @intCast(ciphertext.len), .little);
    p.update(&lens);
    p.final(tag);
}

/// Encrypt `pt` into `ciphertext` (same length) and produce the 16-byte
/// `tag`. RFC 8439 §2.8.
pub fn seal(ciphertext: []u8, tag: *[tag_len]u8, pt: []const u8, aad: []const u8, nonce: *const [nonce_len]u8, key: *const [key_len]u8) void {
    std.debug.assert(ciphertext.len == pt.len);
    var first: [chacha_block_len]u8 = undefined;
    chacha20_block(key, 0, nonce, &first);
    var pkey: [32]u8 = undefined;
    @memcpy(pkey[0..32], first[0..32]);
    chacha20_xor_stream(ciphertext, pt, key, 1, nonce);
    mac(tag, ciphertext, aad, &pkey);
}

/// Authenticate then decrypt. Returns false (and leaves `pt` untouched)
/// when the tag does not match. Constant-time tag comparison.
pub fn open(pt: []u8, ciphertext: []const u8, tag: *const [tag_len]u8, aad: []const u8, nonce: *const [nonce_len]u8, key: *const [key_len]u8) bool {
    std.debug.assert(pt.len == ciphertext.len);
    var first: [chacha_block_len]u8 = undefined;
    chacha20_block(key, 0, nonce, &first);
    var pkey: [32]u8 = undefined;
    @memcpy(pkey[0..32], first[0..32]);
    var expected: [tag_len]u8 = undefined;
    mac(&expected, ciphertext, aad, &pkey);
    if (!ct_eq(&expected, tag)) return false;
    chacha20_xor_stream(pt, ciphertext, key, 1, nonce);
    return true;
}

// ---------------------------------------------------------------------------
// Host tests — the same RFC 8439 vectors the EL0 library pins (drift guard)
// ---------------------------------------------------------------------------

fn hex(comptime s: []const u8) ![s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return error.BadHex;
    return out;
}

test "aead: RFC 8439 §2.3.2 ChaCha20 block-function vector" {
    var key: [key_len]u8 = undefined;
    var i: usize = 0;
    while (i < key_len) : (i += 1) key[i] = @intCast(i);
    const nonce = [nonce_len]u8{ 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x00, 0x00, 0x00 };
    var out: [chacha_block_len]u8 = undefined;
    chacha20_block(&key, 1, &nonce, &out);
    const expected = [chacha_block_len]u8{
        0x10, 0xf1, 0xe7, 0xe4, 0xd1, 0x3b, 0x59, 0x15, 0x50, 0x0f, 0xdd, 0x1f, 0xa3, 0x20, 0x71, 0xc4,
        0xc7, 0xd1, 0xf4, 0xc7, 0x33, 0xc0, 0x68, 0x03, 0x04, 0x22, 0xaa, 0x9a, 0xc3, 0xd4, 0x6c, 0x4e,
        0xd2, 0x82, 0x64, 0x46, 0x07, 0x9f, 0xaa, 0x09, 0x14, 0xc2, 0xd7, 0x05, 0xd9, 0x8b, 0x02, 0xa2,
        0xb5, 0x12, 0x9c, 0xd1, 0xde, 0x16, 0x4e, 0xb9, 0xcb, 0xd0, 0x83, 0xe8, 0xa2, 0x50, 0x3c, 0x4e,
    };
    try std.testing.expectEqual(expected, out);
}

test "aead: RFC 8439 §2.5.2 Poly1305 KAT" {
    const key = try hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b");
    var p = Poly1305.init(&key);
    p.update("Cryptographic Forum Research Group");
    var out: [16]u8 = undefined;
    p.final(&out);
    const exp = try hex("a8061dc1305136c6c22b8baf0c0127a9");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "aead: RFC 8439 §2.8.2 seal + open round trip" {
    const key = try hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
    const nonce = try hex("070000004041424344454647");
    const aad = try hex("50515253c0c1c2c3c4c5c6c7");
    const plaintext =
        "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
    const exp_ct = try hex(
        "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6" ++
            "3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36" ++
            "92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc" ++
            "3ff4def08e4b7a9de576d26586cec64b6116",
    );
    const exp_tag = try hex("1ae10b594f09e26a7e902ecbd0600691");

    var ciphertext: [114]u8 = undefined;
    var tag: [tag_len]u8 = undefined;
    seal(&ciphertext, &tag, plaintext, &aad, &nonce, &key);
    try std.testing.expectEqualSlices(u8, &exp_ct, &ciphertext);
    try std.testing.expectEqualSlices(u8, &exp_tag, &tag);

    var back: [114]u8 = undefined;
    try std.testing.expect(open(&back, &ciphertext, &tag, &aad, &nonce, &key));
    try std.testing.expectEqualSlices(u8, plaintext, &back);
}

test "aead: tampered tag, ciphertext, or AAD is refused" {
    const key = try hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
    const nonce = try hex("070000004041424344454647");
    const aad = try hex("50515253c0c1c2c3c4c5c6c7");
    const plaintext = "attack at dawn";
    var ciphertext: [14]u8 = undefined;
    var tag: [tag_len]u8 = undefined;
    seal(&ciphertext, &tag, plaintext, &aad, &nonce, &key);

    var bad_tag = tag;
    bad_tag[0] ^= 1;
    var out: [14]u8 = undefined;
    try std.testing.expect(!open(&out, &ciphertext, &bad_tag, &aad, &nonce, &key));

    var bad_ct = ciphertext;
    bad_ct[3] ^= 0x80;
    try std.testing.expect(!open(&out, &bad_ct, &tag, &aad, &nonce, &key));

    var bad_aad = aad;
    bad_aad[0] ^= 0x01;
    try std.testing.expect(!open(&out, &ciphertext, &tag, &bad_aad, &nonce, &key));
}

test "aead: empty plaintext and empty AAD authenticate" {
    const key = try hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
    const nonce = try hex("000000000000000000000000");
    var tag: [tag_len]u8 = undefined;
    var ctbuf: [0]u8 = undefined;
    seal(&ctbuf, &tag, "", "", &nonce, &key);
    var out: [0]u8 = undefined;
    try std.testing.expect(open(&out, "", &tag, "", &nonce, &key));
}
