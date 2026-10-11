//! VirelaiOS crypto primitives library (M47, ADR 0023).
//!
//! One freestanding, host-tested, allocation-free crypto library shared by
//! userland apps and the kernel's CSPRNG. Every submodule is pure Zig over
//! `std.mem`/integer ops — no libc, no POSIX, no allocator, no I/O, no
//! randomness. This root re-exports the surface and carries the
//! cross-primitive integration tests; its `test` blocks (and every imported
//! submodule's) run under `zig build test`.
//!
//! Cards: CP1 SHA-256/512 + HMAC (#1115); CP2 ChaCha20-Poly1305 (#1116);
//! CP3 X25519 (#1117); CP4 Ed25519 (#1118); CP5 ct + demo (#1119);
//! SSH-P2 djb ChaCha20 + OpenSSH cipher (#1167, M51).

pub const ct = @import("crypto/ct.zig");
pub const sha256 = @import("crypto/sha256.zig");
pub const sha512 = @import("crypto/sha512.zig");
pub const sha384 = @import("crypto/sha384.zig");
pub const hmac = @import("crypto/hmac.zig");
pub const hkdf = @import("crypto/hkdf.zig");
pub const chacha20 = @import("crypto/chacha20.zig");
pub const chacha20_ssh = @import("crypto/chacha20_ssh.zig");
pub const poly1305 = @import("crypto/poly1305.zig");
pub const aes = @import("crypto/aes.zig");
pub const gcm = @import("crypto/gcm.zig");
pub const aead = @import("crypto/aead.zig");
pub const ssh_cipher = @import("crypto/ssh_cipher.zig");
pub const curve25519 = @import("crypto/curve25519.zig");
pub const x25519 = @import("crypto/x25519.zig");
pub const ed25519 = @import("crypto/ed25519.zig");

const std = @import("std");

test "crypto: HKDF and SHA-384 are reachable from the umbrella (TLS 1.3 keystone)" {
    // Zig analyzes a `pub const x = @import(...)` lazily, so a new submodule's
    // tests only run under `zig build test` once something in this root
    // actually references it. This test is that reference: it also pins the
    // one call shape TLS 1.3's key schedule depends on.
    var prk: [32]u8 = undefined;
    hkdf.Sha256.extract(&prk, "salt", "ikm");
    var okm: [32]u8 = undefined;
    hkdf.Sha256.expand(&okm, &prk, "info");
    try std.testing.expect(!ct.ctEq(&okm, &(@as([32]u8, @splat(@as(u8, 0))))));

    var d: [sha384.digest_len]u8 = undefined;
    sha384.sha384(&d, "abc");
    try std.testing.expect(!ct.ctEq(&d, &(@as([sha384.digest_len]u8, @splat(@as(u8, 0))))));

    // The SHA-384 HMAC must be distinct from the SHA-512 HMAC when both are
    // truncated to 48 bytes (different IV), i.e. HMAC-SHA384 is not
    // "HMAC-SHA512 truncated".
    var m384: [sha384.digest_len]u8 = undefined;
    hmac.hmacSha384(&m384, "key", "msg");
    var m512: [sha512.digest_len]u8 = undefined;
    hmac.hmacSha512(&m512, "key", "msg");
    try std.testing.expect(!std.mem.eql(u8, &m384, m512[0..sha384.digest_len]));

    // AES-GCM is reachable too (TLS_AES_128_GCM_SHA256 is mandatory to
    // implement, so this is the suite that makes SSH-only interop general).
    const n12 = @as([12]u8, @splat(@as(u8, 0)));
    const k16 = @as([16]u8, @splat(@as(u8, 0)));
    var zero_out: [0]u8 = undefined;
    var gt: [gcm.tag_len]u8 = undefined;
    gcm.seal128(&zero_out, &gt, "", "", &n12, &k16);
    try std.testing.expect(!ct.ctEq(&gt, &(@as([gcm.tag_len]u8, @splat(@as(u8, 0))))));
}

test "crypto: HMAC-SHA256 and Ed25519 compose (a signed, authenticated transcript)" {
    // A tiny end-to-end composition: an Ed25519 key signs a transcript whose
    // integrity is also MAC'd. This is an integration smoke, not a protocol.
    const seed = @as([32]u8, @splat(@as(u8, 0x42)));
    var pk: [32]u8 = undefined;
    ed25519.derivePublicKey(&pk, &seed);

    const transcript = "M47 crypto primitives: SHA-256, ChaCha20-Poly1305, X25519, Ed25519";
    var sig: [64]u8 = undefined;
    ed25519.sign(&sig, transcript, &seed);
    try std.testing.expect(ed25519.verify(&sig, transcript, &pk));

    var mac: [32]u8 = undefined;
    hmac.hmacSha256(&mac, &pk, transcript);
    try std.testing.expect(!ct.ctEq(&mac, &(@as([32]u8, @splat(@as(u8, 0))))));
}

test "crypto: AEAD then X25519 shared-secret consistency" {
    // Derive a shared secret each way and use it as an AEAD key.
    const a_sk = @as([32]u8, @splat(@as(u8, 0x11)));
    const b_sk = @as([32]u8, @splat(@as(u8, 0x22)));
    var a_pk: [32]u8 = undefined;
    var b_pk: [32]u8 = undefined;
    x25519.scalarmultBase(&a_pk, &a_sk);
    x25519.scalarmultBase(&b_pk, &b_sk);
    var s1: [32]u8 = undefined;
    var s2: [32]u8 = undefined;
    x25519.scalarmult(&s1, &a_sk, &b_pk);
    x25519.scalarmult(&s2, &b_sk, &a_pk);
    try std.testing.expect(ct.ctEq(&s1, &s2));

    const nonce = @as([12]u8, @splat(@as(u8, 0)));
    var ctbuf: [5]u8 = undefined;
    var tag: [16]u8 = undefined;
    aead.seal(&ctbuf, &tag, "hello", "aad", &nonce, &s1);
    var pt: [5]u8 = undefined;
    try std.testing.expect(aead.open(&pt, &ctbuf, &tag, "aad", &nonce, &s2));
    try std.testing.expectEqualSlices(u8, "hello", &pt);
}

test "crypto: OpenSSH cipher is not the RFC 8439 AEAD (distinct constructions)" {
    // M51: the two constructions take the same primitive inputs but are not
    // interchangeable (ADR 0025 D4) — a drift guard against substituting one
    // for the other. The OpenSSH cipher splits a 64-byte key and uses the
    // sequence number as a 64-bit nonce; the RFC 8439 AEAD uses a 32-byte key
    // and a 96-bit nonce.
    var key: [ssh_cipher.key_len]u8 = undefined;
    for (0..key.len) |i| key[i] = @truncate(i * 3 + 5);
    const packet = "an ssh binary packet (length || padding || payload)";
    const seq: u64 = 9;

    var ssh_ct: [packet.len]u8 = undefined;
    var ssh_tag: [ssh_cipher.tag_len]u8 = undefined;
    ssh_cipher.seal(&ssh_ct, &ssh_tag, packet, seq, &key);
    var back: [packet.len]u8 = undefined;
    try std.testing.expect(ssh_cipher.open(&back, &ssh_ct, &ssh_tag, seq, &key));
    try std.testing.expectEqualSlices(u8, packet, &back);

    const rfc_nonce = @as([12]u8, @splat(@as(u8, 0)));
    var rfc_ct: [packet.len]u8 = undefined;
    var rfc_tag: [16]u8 = undefined;
    aead.seal(&rfc_ct, &rfc_tag, packet, "", &rfc_nonce, key[0..32]);
    try std.testing.expect(!std.mem.eql(u8, &ssh_ct, &rfc_ct));
    try std.testing.expect(!std.mem.eql(u8, &ssh_tag, &rfc_tag));
    // And the RFC construction does not authenticate the SSH tag, nor the
    // SSH construction the RFC tag (the reverse direction).
    try std.testing.expect(!aead.open(&back, &ssh_ct, &ssh_tag, "", &rfc_nonce, key[0..32]));
    try std.testing.expect(!ssh_cipher.open(&back, &rfc_ct, &rfc_tag, seq, &key));
}
