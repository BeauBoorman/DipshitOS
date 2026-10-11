//! `chacha20-poly1305@openssh.com` (M51 SSH-P2, ADR 0025 D4; ADR 0023 D8).
//!
//! The OpenSSH authenticated cipher, implemented to the authoritative
//! `PROTOCOL.chacha20poly1305` file — **not** to the IETF draft:
//!
//! - The 64-byte key from the key exchange is split. The **first 256 bits are
//!   K_2** and key the AEAD: the first 32 bytes of `ChaCha20(K_2, seq, 0)` are
//!   the Poly1305 one-time key, and the payload (everything after the 4-byte
//!   length field) is encrypted with K_2 starting at block counter 1. The
//!   **second 256 bits are K_1** and encrypt only the 4-byte length field, at
//!   block counter 0.
//! - The tag is Encrypt-then-MAC Poly1305 over `enc_length ‖ enc_payload`
//!   (the whole ciphertext). `open` verifies it with `ct.ctEq` — constant
//!   time, no length or content early-exit — before decrypting anything.
//! - The nonce is the SSH packet sequence number as a uint64 in SSH wire
//!   (big-endian) order, decoded into the djb ChaCha20 state little-endian.
//!
//! HAZARD (ADR 0025 D4): `draft-ietf-sshm-chacha20-poly1305` names K_1/K_2
//! **inverted** relative to the OpenSSH file — the draft's K_1 is this file's
//! K_2. Implement by byte position as above. The pinned full vector is the
//! draft's own Appendix A worked example (key `8bbff685…`, seq 7, tag
//! `95349e85…`), which this (OpenSSH) orientation reproduces; the inverted
//! assignment does not.
//!
//! The RFC 8439 `aead.zig`/`chacha20.zig` primitives are not used here and
//! remain live (ADR 0025 D4). No allocation, no I/O, caller-buffered.

const std = @import("std");
const chacha20_ssh = @import("chacha20_ssh.zig");
const poly1305 = @import("poly1305.zig");
const ct = @import("ct.zig");

pub const key_len = 64;
pub const tag_len = 16;
pub const length_len = 4;

/// The SSH packet sequence number as the 8-byte ChaCha20 nonce: SSH wire
/// encoding is big-endian.
fn seqNonce(seq: u64) [chacha20_ssh.nonce_len]u8 {
    var nonce: [chacha20_ssh.nonce_len]u8 = undefined;
    std.mem.writeInt(u64, &nonce, seq, .big);
    return nonce;
}

/// The per-packet Poly1305 key: the first 32 bytes of `ChaCha20(K_2, seq, 0)`,
/// where K_2 is the first half of `key` (OpenSSH `PROTOCOL.chacha20poly1305`).
fn polyKey(out: *[32]u8, seq: u64, key: *const [key_len]u8) void {
    var block: [chacha20_ssh.block_len]u8 = undefined;
    const nonce = seqNonce(seq);
    chacha20_ssh.block(key[0..32], 0, &nonce, &block);
    @memcpy(out, block[0..32]);
    ct.wipe(&block);
}

/// Decrypt just the 4-byte encrypted length field, the OpenSSH "the length
/// must be decrypted first" step, and return the SSH `packet_length` as a
/// big-endian u32. The result is **not authenticated** (the MAC has not been
/// seen yet): the caller must still `open` the full packet, which re-checks
/// the tag before use.
pub fn decryptLength(encrypted: *const [length_len]u8, seq: u64, key: *const [key_len]u8) u32 {
    var plain: [length_len]u8 = undefined;
    const nonce = seqNonce(seq);
    chacha20_ssh.xorStream(&plain, encrypted, key[32..64], 0, &nonce);
    return std.mem.readInt(u32, &plain, .big);
}

/// Encrypt one complete SSH binary packet (`length ‖ rest`, per RFC 4253)
/// from `plaintext` into `ciphertext` (same length) and write the 16-byte
/// `tag` over the encrypted length and payload. `seq` is the sender's packet
/// sequence number.
pub fn seal(ciphertext: []u8, tag: *[tag_len]u8, plaintext: []const u8, seq: u64, key: *const [key_len]u8) void {
    std.debug.assert(ciphertext.len == plaintext.len);
    std.debug.assert(ciphertext.len >= length_len);
    const nonce = seqNonce(seq);
    // Length field under K_1 (second half), block counter 0.
    chacha20_ssh.xorStream(ciphertext[0..length_len], plaintext[0..length_len], key[32..64], 0, &nonce);
    // Payload under K_2 (first half), block counter 1.
    chacha20_ssh.xorStream(ciphertext[length_len..], plaintext[length_len..], key[0..32], 1, &nonce);
    var pkey: [32]u8 = undefined;
    polyKey(&pkey, seq, key);
    poly1305.poly1305(tag, ciphertext, &pkey);
    ct.wipe(&pkey);
}

/// Authenticate then decrypt. Returns false — leaving `plaintext` untouched —
/// when the tag does not match (`ct.ctEq`, constant time). On success
/// `plaintext` receives the full `length ‖ rest` packet.
pub fn open(plaintext: []u8, ciphertext: []const u8, tag: *const [tag_len]u8, seq: u64, key: *const [key_len]u8) bool {
    std.debug.assert(plaintext.len == ciphertext.len);
    std.debug.assert(ciphertext.len >= length_len);
    var pkey: [32]u8 = undefined;
    polyKey(&pkey, seq, key);
    var expected: [tag_len]u8 = undefined;
    poly1305.poly1305(&expected, ciphertext, &pkey);
    ct.wipe(&pkey);
    if (!ct.ctEq(&expected, tag)) return false;
    const nonce = seqNonce(seq);
    // MAC is good: decrypt length under K_1, payload under K_2.
    chacha20_ssh.xorStream(plaintext[0..length_len], ciphertext[0..length_len], key[32..64], 0, &nonce);
    chacha20_ssh.xorStream(plaintext[length_len..], ciphertext[length_len..], key[0..32], 1, &nonce);
    return true;
}

// ---------------------------------------------------------------------------
// Host tests
// ---------------------------------------------------------------------------

test "ssh_cipher: zero-key Poly1305 key is the RFC 8439 A.1 zero block (76b8e0ad…)" {
    // The OpenSSH file derives the Poly key from K_2 = the first 256 bits.
    // With an all-zero 64-byte key and seq 0, that derivation must produce the
    // RFC 8439 Appendix A.1 test vector #1 block, whose first 256 bits are the
    // pinned `76b8e0ad…` Poly1305 key.
    const key = @as([key_len]u8, @splat(@as(u8, 0)));
    var pkey: [32]u8 = undefined;
    polyKey(&pkey, 0, &key);
    const exp_pkey = try hex("76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7");
    try std.testing.expectEqualSlices(u8, &exp_pkey, &pkey);

    const plain = [_]u8{ 0, 0, 0, 4, 1, 0xaa, 0xbb, 0xcc };
    var cipher: [plain.len]u8 = undefined;
    var tag: [tag_len]u8 = undefined;
    seal(&cipher, &tag, &plain, 0, &key);
    const exp_ct = try hex("76b8e0a99ead5c72");
    const exp_tag = try hex("eff46ab54f68eb25915e3dc319448e9c");
    try std.testing.expectEqualSlices(u8, &exp_ct, &cipher);
    try std.testing.expectEqualSlices(u8, &exp_tag, &tag);

    var back: [plain.len]u8 = undefined;
    try std.testing.expect(open(&back, &cipher, &tag, 0, &key));
    try std.testing.expectEqualSlices(u8, &plain, &back);
    try std.testing.expectEqual(@as(u32, 4), decryptLength(cipher[0..length_len], 0, &key));
}

test "ssh_cipher: draft-ietf-sshm-chacha20-poly1305-04 appendix A worked example" {
    // The full OpenSSH-construction vector (the draft's names are inverted,
    // its bytes are not): key from Figure 5, the packet of Figure 4 at
    // sequence number 7, ciphertext Figure 12, tag Figure 17.
    const key = try hex(
        "8bbff6855fc102338c373e73aac0c914" ++
            "f076a905b2444a32eecaffeae22becc5" ++
            "e9b7a7a5825a8249346ec1c28301cf39" ++
            "4543fc7569887d76e168f37562ac0740",
    );
    const plain = try hex(
        "00000048065e00000000000000384c6f" ++
            "72656d20697073756d20646f6c6f7220" ++
            "73697420616d65742c20636f6e736563" ++
            "7465747572206164697069736963696e" ++
            "6720656c69744e43e804dc6c",
    );
    const exp_ct = try hex(
        "2c3ecce4a5bc05895bf07a7ba956b6c6" ++
            "8829ac7c83b780b7000ecde745afc705" ++
            "bbc378ce03a280236b87b53bed583966" ++
            "2302b164b6286a48cd1e097138e3cb90" ++
            "9b8b2b829dd18d2a35ff82d9",
    );
    const exp_tag = try hex("95349e855bf02c298ef775f2d1a7e8b8");

    var cipher: [plain.len]u8 = undefined;
    var tag: [tag_len]u8 = undefined;
    seal(&cipher, &tag, &plain, 7, &key);
    try std.testing.expectEqualSlices(u8, &exp_ct, &cipher);
    try std.testing.expectEqualSlices(u8, &exp_tag, &tag);

    // The 4-byte length decrypts first, before the MAC is available.
    try std.testing.expectEqual(@as(u32, 0x48), decryptLength(cipher[0..length_len], 7, &key));

    var back: [plain.len]u8 = undefined;
    try std.testing.expect(open(&back, &cipher, &tag, 7, &key));
    try std.testing.expectEqualSlices(u8, &plain, &back);
}

test "ssh_cipher: tag and ciphertext tampering are rejected (ct.ctEq), plaintext untouched" {
    const key = try hex(
        "8bbff6855fc102338c373e73aac0c914" ++
            "f076a905b2444a32eecaffeae22becc5" ++
            "e9b7a7a5825a8249346ec1c28301cf39" ++
            "4543fc7569887d76e168f37562ac0740",
    );
    const plain = [_]u8{ 0, 0, 0, 4, 1, 0xaa, 0xbb, 0xcc };
    var cipher: [plain.len]u8 = undefined;
    var tag: [tag_len]u8 = undefined;
    seal(&cipher, &tag, &plain, 3, &key);

    const sentinel = @as([plain.len]u8, @splat(@as(u8, 0x5a)));
    var out: [plain.len]u8 = sentinel;

    var bad_tag = tag;
    bad_tag[0] ^= 0x01;
    try std.testing.expect(!open(&out, &cipher, &bad_tag, 3, &key));
    bad_tag = tag;
    bad_tag[tag_len - 1] ^= 0x80;
    try std.testing.expect(!open(&out, &cipher, &bad_tag, 3, &key));

    var bad_ct = cipher;
    bad_ct[0] ^= 0x01; // encrypted length
    try std.testing.expect(!open(&out, &bad_ct, &tag, 3, &key));
    bad_ct = cipher;
    bad_ct[plain.len - 1] ^= 0x01; // payload tail
    try std.testing.expect(!open(&out, &bad_ct, &tag, 3, &key));
    try std.testing.expectEqualSlices(u8, &sentinel, &out);

    try std.testing.expect(open(&out, &cipher, &tag, 3, &key));
    try std.testing.expectEqualSlices(u8, &plain, &out);
}

test "ssh_cipher: sequence-number nonce advances (wrong seq fails)" {
    const key = @as([key_len]u8, @splat(@as(u8, 0x24)));
    const plain = try hex("0000000801deadbeef010203");
    var cipher0: [plain.len]u8 = undefined;
    var cipher1: [plain.len]u8 = undefined;
    var tag0: [tag_len]u8 = undefined;
    var tag1: [tag_len]u8 = undefined;
    seal(&cipher0, &tag0, &plain, 0, &key);
    seal(&cipher1, &tag1, &plain, 1, &key);
    try std.testing.expect(!std.mem.eql(u8, &cipher0, &cipher1));
    try std.testing.expect(!std.mem.eql(u8, &tag0, &tag1));
    // Deterministic within a sequence number.
    var again: [plain.len]u8 = undefined;
    var tag_again: [tag_len]u8 = undefined;
    seal(&again, &tag_again, &plain, 0, &key);
    try std.testing.expectEqualSlices(u8, &cipher0, &again);
    try std.testing.expectEqualSlices(u8, &tag0, &tag_again);

    var out: [plain.len]u8 = undefined;
    try std.testing.expect(!open(&out, &cipher0, &tag0, 1, &key));
    try std.testing.expect(!open(&out, &cipher1, &tag1, 0, &key));
    try std.testing.expect(open(&out, &cipher1, &tag1, 1, &key));
    try std.testing.expectEqualSlices(u8, &plain, &out);
    // The first-step length decrypt is sequence-bound too.
    try std.testing.expectEqual(@as(u32, 8), decryptLength(cipher0[0..length_len], 0, &key));
    try std.testing.expect(decryptLength(cipher0[0..length_len], 1, &key) != 8);
}

test "ssh_cipher: split-key boundary — K_2 payload/Poly, K_1 length" {
    // key = 00..3f: first half 00..1f (K_2, AEAD), second half 20..3f (K_1,
    // length). Reference values generated with Go x/crypto's djb ChaCha20 +
    // Poly1305 (the primitives behind Go's OpenSSH-compatible ssh), whose
    // generator reproduces the draft worked example above.
    var key: [key_len]u8 = undefined;
    for (0..key_len) |i| key[i] = @intCast(i);
    const plain = try hex("0000000401aabbcc");
    var cipher: [plain.len]u8 = undefined;
    var tag: [tag_len]u8 = undefined;
    seal(&cipher, &tag, &plain, 0, &key);
    const exp_ct = try hex("94450e5d1912f9fd");
    const exp_tag = try hex("330dd5eb4e87ecfdf3d3d467034a83cb");
    try std.testing.expectEqualSlices(u8, &exp_ct, &cipher);
    try std.testing.expectEqualSlices(u8, &exp_tag, &tag);

    // Structural: the length uses K_1 (second half) at counter 0, the payload
    // uses K_2 (first half) at counter 1.
    const nonce = seqNonce(0);
    var ks1: [chacha20_ssh.block_len]u8 = undefined;
    var ks2: [chacha20_ssh.block_len]u8 = undefined;
    chacha20_ssh.block(key[32..64], 0, &nonce, &ks1);
    chacha20_ssh.block(key[0..32], 1, &nonce, &ks2);
    for (0..length_len) |i| try std.testing.expectEqual(plain[i] ^ ks1[i], cipher[i]);
    for (length_len..plain.len) |i| try std.testing.expectEqual(plain[i] ^ ks2[i - length_len], cipher[i]);

    // Swapping the halves changes the packet and does not authenticate.
    var swapped: [key_len]u8 = undefined;
    @memcpy(swapped[0..32], key[32..64]);
    @memcpy(swapped[32..64], key[0..32]);
    var wrong_ct: [plain.len]u8 = undefined;
    var wrong_tag: [tag_len]u8 = undefined;
    seal(&wrong_ct, &wrong_tag, &plain, 0, &swapped);
    try std.testing.expect(!std.mem.eql(u8, &cipher, &wrong_ct));
    try std.testing.expect(!std.mem.eql(u8, &tag, &wrong_tag));
    var out: [plain.len]u8 = undefined;
    try std.testing.expect(!open(&out, &cipher, &tag, 0, &swapped));
    try std.testing.expect(open(&out, &cipher, &tag, 0, &key));
    try std.testing.expectEqualSlices(u8, &plain, &out);
}

fn hex(comptime s: []const u8) ![s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return error.BadHex;
    return out;
}
