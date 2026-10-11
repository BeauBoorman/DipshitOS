//! ChaCha20-Poly1305 AEAD (RFC 8439 §2.8), M47 CP2, ADR 0023.
//!
//! The AEAD construction: the Poly1305 one-time key is the first 32 bytes
//! of the ChaCha20 block at counter 0; the ciphertext is ChaCha20 with
//! counter 1; the tag authenticates AAD‖pad‖ciphertext‖pad‖len(AAD)‖
//! len(ciphertext) (all little-endian, padded to 16). Streaming MAC, no
//! allocation; `open` uses the constant-time tag compare from `ct.zig`.
//!
//! Verified against the RFC 8439 §2.8.2 vector as class-A `zig test`.

const std = @import("std");
const chacha20 = @import("chacha20.zig");
const poly1305 = @import("poly1305.zig");
const ct = @import("ct.zig");

pub const tag_len = 16;

fn padLen(n: usize) usize {
    return (16 - (n & 15)) & 15;
}

fn mac(tag: *[16]u8, ciphertext: []const u8, aad: []const u8, pkey: *const [32]u8) void {
    var p = poly1305.Poly1305.init(pkey);
    const zeros = @as([16]u8, @splat(@as(u8, 0)));
    p.update(aad);
    p.update(zeros[0..padLen(aad.len)]);
    p.update(ciphertext);
    p.update(zeros[0..padLen(ciphertext.len)]);
    var lens: [16]u8 = undefined;
    std.mem.writeInt(u64, lens[0..8], @intCast(aad.len), .little);
    std.mem.writeInt(u64, lens[8..16], @intCast(ciphertext.len), .little);
    p.update(&lens);
    p.final(tag);
}

/// Encrypt `pt` into `ct` (same length) and produce the 16-byte `tag`.
pub fn seal(ciphertext: []u8, tag: *[16]u8, pt: []const u8, aad: []const u8, nonce: *const [12]u8, key: *const [32]u8) void {
    std.debug.assert(ciphertext.len == pt.len);
    var first: [chacha20.block_len]u8 = undefined;
    chacha20.block(key, 0, nonce, &first);
    var pkey: [32]u8 = undefined;
    @memcpy(pkey[0..32], first[0..32]);
    chacha20.xorStream(ciphertext, pt, key, 1, nonce);
    mac(tag, ciphertext, aad, &pkey);
}

/// Authenticate then decrypt. Returns false (and leaves `pt` untouched) when
/// the tag does not match. Constant-time tag comparison.
pub fn open(pt: []u8, ciphertext: []const u8, tag: *const [16]u8, aad: []const u8, nonce: *const [12]u8, key: *const [32]u8) bool {
    std.debug.assert(pt.len == ciphertext.len);
    var first: [chacha20.block_len]u8 = undefined;
    chacha20.block(key, 0, nonce, &first);
    var pkey: [32]u8 = undefined;
    @memcpy(pkey[0..32], first[0..32]);
    var expected: [16]u8 = undefined;
    mac(&expected, ciphertext, aad, &pkey);
    if (!ct.ctEq(&expected, tag)) return false;
    chacha20.xorStream(pt, ciphertext, key, 1, nonce);
    return true;
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
    var tag: [16]u8 = undefined;
    seal(&ciphertext, &tag, plaintext, &aad, &nonce, &key);
    try std.testing.expectEqualSlices(u8, &exp_ct, &ciphertext);
    try std.testing.expectEqualSlices(u8, &exp_tag, &tag);

    var back: [114]u8 = undefined;
    try std.testing.expect(open(&back, &ciphertext, &tag, &aad, &nonce, &key));
    try std.testing.expectEqualSlices(u8, plaintext, &back);
}

test "aead: tampered tag or ciphertext is rejected" {
    const key = try hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
    const nonce = try hex("070000004041424344454647");
    const aad = try hex("50515253c0c1c2c3c4c5c6c7");
    const plaintext = "attack at dawn";
    var ciphertext: [14]u8 = undefined;
    var tag: [16]u8 = undefined;
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
    var tag: [16]u8 = undefined;
    var ctbuf: [0]u8 = undefined;
    seal(&ctbuf, &tag, "", "", &nonce, &key);
    var out: [0]u8 = undefined;
    try std.testing.expect(open(&out, "", &tag, "", &nonce, &key));
}

fn hex(comptime s: []const u8) ![s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return error.BadHex;
    return out;
}
