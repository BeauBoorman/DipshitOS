//! djb ChaCha20 for the OpenSSH `chacha20-poly1305@openssh.com` cipher
//! (M51 SSH-P2, ADR 0025 D4; ADR 0023 D8).
//!
//! This is the ORIGINAL ChaCha20 as specified by D. J. Bernstein and used by
//! OpenSSH: state words 12–13 are a **64-bit block counter** and words 14–15
//! an **8-byte nonce** (both little-endian). It is *not* the RFC 8439 variant
//! in `chacha20.zig` (32-bit counter + 96-bit nonce), which SSH cannot use
//! (ADR 0025 D4) and which remains the userland AEAD core, not dead code.
//!
//! The permutation is shared with `chacha20.zig` (`quarterRound`, pinned by
//! the RFC 7539 vectors there) so the two variants cannot drift.
//!
//! KATs (class A): the RFC 8439 Appendix A.1 all-zero block vectors, reached
//! through this variant's 64-bit counter at counters 0–2 and cross-checked
//! against the RFC layout at the 64-bit counter high word and an 8-byte nonce.
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");
const chacha20 = @import("chacha20.zig");

pub const key_len = 32;
pub const nonce_len = 8;
pub const block_len = 64;

// The ChaCha constants "expa" "nd 3" "2-by" "te k".
const c0: u32 = 0x61707865;
const c1: u32 = 0x3320646e;
const c2: u32 = 0x79622d32;
const c3: u32 = 0x6b206574;

/// One 64-byte block. `counter` is the 64-bit block counter (state words
/// 12–13, little-endian) and `nonce` the 8-byte nonce (state words 14–15,
/// little-endian). The permutation is `chacha20.quarterRound`.
pub fn block(key: *const [key_len]u8, counter: u64, nonce: *const [nonce_len]u8, out: *[block_len]u8) void {
    var state: [16]u32 = undefined;
    state[0] = c0;
    state[1] = c1;
    state[2] = c2;
    state[3] = c3;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        state[4 + i] = std.mem.readInt(u32, key[i * 4 ..][0..4], .little);
    }
    state[12] = @truncate(counter);
    state[13] = @truncate(counter >> 32);
    var j: usize = 0;
    while (j < 2) : (j += 1) {
        state[14 + j] = std.mem.readInt(u32, nonce[j * 4 ..][0..4], .little);
    }
    var working = state;
    var round: usize = 0;
    while (round < 10) : (round += 1) {
        chacha20.quarterRound(&working, 0, 4, 8, 12);
        chacha20.quarterRound(&working, 1, 5, 9, 13);
        chacha20.quarterRound(&working, 2, 6, 10, 14);
        chacha20.quarterRound(&working, 3, 7, 11, 15);
        chacha20.quarterRound(&working, 0, 5, 10, 15);
        chacha20.quarterRound(&working, 1, 6, 11, 12);
        chacha20.quarterRound(&working, 2, 7, 8, 13);
        chacha20.quarterRound(&working, 3, 4, 9, 14);
    }
    var k: usize = 0;
    while (k < 16) : (k += 1) {
        std.mem.writeInt(u32, out[k * 4 ..][0..4], working[k] +% state[k], .little);
    }
}

/// XOR `in` with the ChaCha20 keystream starting at block `counter`.
/// `out.len` must equal `in.len`; `out` and `in` may alias. The 64-bit
/// counter continues across block boundaries. No allocation.
pub fn xorStream(out: []u8, in: []const u8, key: *const [key_len]u8, counter: u64, nonce: *const [nonce_len]u8) void {
    std.debug.assert(out.len == in.len);
    var ctr = counter;
    var ks: [block_len]u8 = undefined;
    var off: usize = 0;
    while (off < in.len) {
        block(key, ctr, nonce, &ks);
        ctr +%= 1;
        const take = @min(block_len, in.len - off);
        for (0..take) |i| out[off + i] = in[off + i] ^ ks[i];
        off += take;
    }
}

// ---------------------------------------------------------------------------
// Host tests
// ---------------------------------------------------------------------------

test "chacha20_ssh: RFC 8439 A.1 TV#1 zero block (counter 0)" {
    const key = @as([key_len]u8, @splat(@as(u8, 0)));
    const nonce = @as([nonce_len]u8, @splat(@as(u8, 0)));
    var out: [block_len]u8 = undefined;
    block(&key, 0, &nonce, &out);
    const expected = try hex(
        "76b8e0ada0f13d90405d6ae55386bd28" ++
            "bdd219b8a08ded1aa836efcc8b770dc7" ++
            "da41597c5157488d7724e03fb8d84a37" ++
            "6a43b8f41518a11cc387b669b2ee6586",
    );
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "chacha20_ssh: 64-bit counter advances through RFC 8439 A.1 TV#2/TV#3" {
    const key = @as([key_len]u8, @splat(@as(u8, 0)));
    const nonce = @as([nonce_len]u8, @splat(@as(u8, 0)));
    var out: [block_len]u8 = undefined;
    const exp2 = try hex(
        "9f07e7be5551387a98ba977c732d080d" ++
            "cb0f29a048e3656912c6533e32ee7aed" ++
            "29b721769ce64e43d57133b074d839d5" ++
            "31ed1f28510afb45ace10a1f4b794d6f",
    );
    const exp3 = try hex(
        "2d09a0e663266ce1ae7ed1081968a075" ++
            "8e718e997bd362c6b0c34634a9a0b35d" ++
            "012737681f7b5d0f281e3afde458bc1e" ++
            "73d2d313c9cf94c05ff3716240a248f2",
    );
    block(&key, 1, &nonce, &out);
    try std.testing.expectEqualSlices(u8, &exp2, &out);
    block(&key, 2, &nonce, &out);
    try std.testing.expectEqualSlices(u8, &exp3, &out);
}

test "chacha20_ssh: counter high word and nonce occupy djb state words 13-15" {
    // djb {counter=2^32, nonce=0} puts 1 in state[13]; the RFC layout puts
    // its 96-bit nonce there, so this is the same block as RFC counter 0 with
    // nonce = {01,00,00,00, 00*8}.
    const key = @as([32]u8, @splat(@as(u8, 0)));
    const nonce0 = @as([nonce_len]u8, @splat(@as(u8, 0)));
    var djb_out: [block_len]u8 = undefined;
    var rfc_out: [block_len]u8 = undefined;
    block(&key, 1 << 32, &nonce0, &djb_out);
    chacha20.block(&key, 0, &([_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }), &rfc_out);
    try std.testing.expectEqualSlices(u8, &rfc_out, &djb_out);

    // djb nonce bytes are state words 14-15 little-endian: nonce = 7 (SSH
    // wire big-endian) equals RFC counter 0 with 96-bit nonce 0*4 || nonce.
    const nonce7 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 7 };
    block(&key, 0, &nonce7, &djb_out);
    chacha20.block(&key, 0, &([_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7 }), &rfc_out);
    try std.testing.expectEqualSlices(u8, &rfc_out, &djb_out);
}

test "chacha20_ssh: xorStream is an involution (counter continuity across blocks)" {
    var key: [key_len]u8 = undefined;
    for (0..key_len) |i| key[i] = @truncate(i * 5 + 1);
    const nonce = [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2 };
    var msg: [200]u8 = undefined;
    for (0..msg.len) |i| msg[i] = @truncate(i * 11 + 7);
    var ct: [200]u8 = undefined;
    var back: [200]u8 = undefined;
    xorStream(&ct, &msg, &key, 1, &nonce);
    xorStream(&back, &ct, &key, 1, &nonce);
    try std.testing.expectEqualSlices(u8, &msg, &back);
}

fn hex(comptime s: []const u8) ![s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return error.BadHex;
    return out;
}
