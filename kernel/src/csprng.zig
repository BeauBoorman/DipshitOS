//! VirelaiOS CSPRNG (milestone four, card 1 — claim 2665).
//!
//! A freestanding, no-libc, no-heap ChaCha20 stream cipher (RFC 7539) used
//! as the kernel's cryptographically secure pseudo-random number generator.
//! The kernel has no randomness source until the virtio entropy device
//! (`kernel/src/virtio_entropy.zig`) seeds this module with 64 bytes of
//! REAL entropy at boot (post-MMU, after the allocator arms); a failed
//! device read falls back to a fixed deterministic key and the module
//! reports `seeded() == false` honestly (the live gate proves the real
//! path — `entropy: seeded n=64`).
//!
//! `std.crypto` is deliberately not used: this module stays dependency-free
//! so the RFC 7539 known-answer test vectors are pinned directly in
//! `zig test` — the §2.2.1 quarter-round state vector, the §2.3.2
//! block-function vector, and the §2.4.2 114-byte ciphertext vector — and
//! there is no hidden allocation or host-test surface.
//!
//! The seed layout (64 bytes, all used): key = bytes[0..32] with
//! bytes[48..64] folded in (XOR into key bytes 16..31), nonce =
//! bytes[32..44], and the initial block counter = `1 |
//! (le32(bytes[44..48]) & 0x7fffffff)` (the `| 1` guarantees a nonzero
//! counter so a zero-heavy device read still yields a fresh stream).
//!
//! M47 (ADR 0023 D2): the userland crypto library
//! (`user/src/lib/crypto/chacha20.zig`) carries the same RFC 7539 cipher
//! for the AEAD. Zig forbids a relative import across the `kernel/`-`user/`
//! module boundary and several class-A gates run `zig test` directly on
//! kernel modules with no build-provided imports, so the two files stay
//! separate; they are held together by the SAME RFC 7539 vectors pinned in
//! both test roots (a drift guard), not by a shared translation unit.
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");
const spinlock = @import("spinlock.zig"); // claim 9498 follow-on: cross-core random_bytes/seed
const userspace = @import("userspace.zig");

pub const key_len: usize = 32;
pub const nonce_len: usize = 12;
pub const block_len: usize = 64;
pub const seed_len: usize = 64;

// RFC 7539 §2.3 constants: "expa" "nd 3" "2-by" "te k".
const c0: u32 = 0x61707865;
const c1: u32 = 0x3320646e;
const c2: u32 = 0x79622d32;
const c3: u32 = 0x6b206574;

// The claim-5804 fixed user stack VA — the unseeded ASLR default (the
// boot-time static EL0 payload's root is built before the seed, so it
// keeps exactly this placement). Bound to userspace.stack_va, NOT a copy:
// M129a (#2610) moved it above the 4 GiB blanket because VZ anchors guest
// RAM at phys 0x7000_0000 growing upward, so a fixed VA at 0x8000_0000
// lands on kernel-live RAM once the guest exceeds 256 MiB.
pub const default_stack_va: u64 = userspace.stack_va;

fn rotl(x: u32, n: u5) u32 {
    return (x << n) | (x >> @intCast(32 - @as(u6, n)));
}

/// RFC 7539 §2.1 quarter round over four state words addressed by index.
/// Exposed (pub) for the §2.2.1 state test vector.
pub fn quarter_round(state: *[16]u32, a: usize, b: usize, c: usize, d: usize) void {
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

/// RFC 7539 §2.3.1/§2.3.2: one 64-byte ChaCha20 block. `key` is 32 bytes,
/// `counter` the 32-bit block count (word 12), `nonce` 12 bytes (words
/// 13–15); `out` receives the serialized keystream block.
pub fn chacha20_block(key: *const [key_len]u8, counter: u32, nonce: *const [nonce_len]u8, out: *[block_len]u8) void {
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

// ---------------------------------------------------------------------------
// Stream state (module-level BSS — one global CSPRNG, no allocation)
// ---------------------------------------------------------------------------

/// Serializes stream mutation across cores: exec's ASLR stack placement,
/// DNS/connect transaction ids, and the monitor `random` command can all
/// run on secondary cores under the per-domain lock regime, so the
/// keystream state is no longer behind one coarse gate.
var stream_lock = spinlock.IrqSaveSpinlock{};

var stream_key: [key_len]u8 = undefined;
var stream_nonce: [nonce_len]u8 = undefined;
var stream_counter: u32 = 0;
var keystream: [block_len]u8 = undefined;
var keystream_pos: usize = block_len; // >= block_len forces a refill
var seeded_flag: bool = false;

/// True once the CSPRNG was keyed from REAL entropy (a successful
/// `seed`); a deterministic fallback leaves this false so consumers (and
/// the monitor `random` command) can report the truth.
pub fn seeded() bool {
    return seeded_flag;
}

fn init_state(seed_bytes: *const [seed_len]u8) void {
    @memcpy(stream_key[0..32], seed_bytes[0..32]);
    var k: usize = 0;
    while (k < 16) : (k += 1) stream_key[16 + k] ^= seed_bytes[48 + k];
    @memcpy(stream_nonce[0..12], seed_bytes[32..44]);
    // Initial block counter: 1 (RFC 7539's conventional start) OR-ed with
    // a seed-derived odd value so a 64-byte read always yields a fresh
    // stream even if the device returned zero-heavy bytes.
    stream_counter = 1 | (std.mem.readInt(u32, seed_bytes[44..48], .little) & 0x7fffffff);
    keystream_pos = block_len; // refill on the next read
}

/// Key the CSPRNG from 64 bytes of entropy (the virtio device seed). Marks
/// the module as genuinely seeded.
pub fn seed(seed_bytes: *const [seed_len]u8) void {
    const daif = stream_lock.lock();
    defer stream_lock.unlock(daif);
    init_state(seed_bytes);
    seeded_flag = true;
}

/// Deterministic fallback for a failed device read: fixed key/nonce so
/// unseeded builds behave identically across boots. `seeded()` stays
/// false — this is honest, not a substitute for the real path.
pub fn seed_fallback() void {
    const daif = stream_lock.lock();
    defer stream_lock.unlock(daif);
    var fb: [seed_len]u8 = @as([seed_len]u8, @splat(@as(u8, 0)));
    const tag = "VIRELAIOS-ENTROPY-FALLBACK";
    @memcpy(fb[0..tag.len], tag);
    init_state(&fb);
    seeded_flag = false;
}

/// Fill `out` with keystream bytes from the seeded stream. Never blocks,
/// never allocates. Safe to call while unseeded (the fallback key is
/// deterministic); consumers should check `seeded()` for honesty.
pub fn random_bytes(out: []u8) void {
    const daif = stream_lock.lock();
    defer stream_lock.unlock(daif);
    stream_bytes(out);
}

fn stream_bytes(out: []u8) void {
    var done: usize = 0;
    while (done < out.len) {
        if (keystream_pos >= block_len) {
            chacha20_block(&stream_key, stream_counter, &stream_nonce, &keystream);
            stream_counter +%= 1;
            keystream_pos = 0;
        }
        const take = @min(block_len - keystream_pos, out.len - done);
        @memcpy(out[done .. done + take], keystream[keystream_pos .. keystream_pos + take]);
        keystream_pos += take;
        done += take;
    }
}

/// One 64-bit random value.
pub fn random_u64() u64 {
    var b: [8]u8 = undefined;
    random_bytes(&b);
    return std.mem.readInt(u64, &b, .little);
}

// ---------------------------------------------------------------------------
// ASLR helper (the seed's real consumer — claim 2665)
// ---------------------------------------------------------------------------

/// Pure placement function: map a 64-bit random value to a user stack VA in
/// the ASLR band [0x1_0000_0000, 0x2_0000_0000) with 64 KiB placement
/// granularity (page-aligned). The band sits ABOVE the identity-mapped RAM,
/// the exec image apertures, and — since issue #1214 — the GOOS=virelai
/// sbrk heap: the gc runtime reserves its heap contiguously upward from the
/// image end (a hello-world already spans ~1.2 GiB of reservation), and a
/// stack inside that span gets wiped by the runtime's own heap trims
/// (memclrNoHeapPointers over a freed arena range). The old band
/// [0x1000_0000, 0x8000_0000) overlapped that span for ~54% of placements —
/// the go-args boot flake. handle_mmap's collision refusal (syscall.zig)
/// makes any residual overlap an honest EINVAL instead of silent aliasing.
pub fn stack_va_from_random(r: u64) u64 {
    const band_base: u64 = 0x1_0000_0000;
    const band_end: u64 = 0x2_0000_0000;
    const granularity: u64 = 0x1_0000;
    const slots = (band_end - band_base) / granularity;
    return band_base + (r % slots) * granularity;
}

/// The EL0 user stack VA for the next user-root rebuild (the exec path):
/// the fixed claim-5804 default while unseeded (boot-time behavior is
/// unchanged — the static payload's root is built pre-seed), otherwise a
/// per-boot random placement. THIS is the real ASLR use of the seed.
pub fn random_stack_va() u64 {
    if (!seeded_flag) return default_stack_va;
    return stack_va_from_random(random_u64());
}

// ---------------------------------------------------------------------------
// Host tests — RFC 7539 known-answer vectors + stream/ASLR properties
// ---------------------------------------------------------------------------

test "csprng: RFC 7539 §2.2.1 quarter-round state vector" {
    var state = [16]u32{
        0x879531e0, 0xc5ecf37d, 0x516461b1, 0xc9a62f8a,
        0x44c20ef3, 0x3390af7f, 0xd9fc690b, 0x2a5f714c,
        0x53372767, 0xb00a5631, 0x974c541a, 0x359e9963,
        0x5c971061, 0x3d631689, 0x2098d9d6, 0x91dbd320,
    };
    quarter_round(&state, 2, 7, 8, 13);
    const expected = [16]u32{
        0x879531e0, 0xc5ecf37d, 0xbdb886dc, 0xc9a62f8a,
        0x44c20ef3, 0x3390af7f, 0xd9fc690b, 0xcfacafd2,
        0xe46bea80, 0xb00a5631, 0x974c541a, 0x359e9963,
        0x5c971061, 0xccc07c79, 0x2098d9d6, 0x91dbd320,
    };
    try std.testing.expectEqual(expected, state);
}

test "csprng: RFC 7539 §2.3.2 block-function vector" {
    var key: [key_len]u8 = undefined;
    var i: usize = 0;
    while (i < key_len) : (i += 1) key[i] = @intCast(i);
    const nonce = [nonce_len]u8{ 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x00, 0x00, 0x00 };
    var out: [block_len]u8 = undefined;
    chacha20_block(&key, 1, &nonce, &out);
    const expected = [block_len]u8{
        0x10, 0xf1, 0xe7, 0xe4, 0xd1, 0x3b, 0x59, 0x15,
        0x50, 0x0f, 0xdd, 0x1f, 0xa3, 0x20, 0x71, 0xc4,
        0xc7, 0xd1, 0xf4, 0xc7, 0x33, 0xc0, 0x68, 0x03,
        0x04, 0x22, 0xaa, 0x9a, 0xc3, 0xd4, 0x6c, 0x4e,
        0xd2, 0x82, 0x64, 0x46, 0x07, 0x9f, 0xaa, 0x09,
        0x14, 0xc2, 0xd7, 0x05, 0xd9, 0x8b, 0x02, 0xa2,
        0xb5, 0x12, 0x9c, 0xd1, 0xde, 0x16, 0x4e, 0xb9,
        0xcb, 0xd0, 0x83, 0xe8, 0xa2, 0x50, 0x3c, 0x4e,
    };
    try std.testing.expectEqual(expected, out);
}

test "csprng: RFC 7539 §2.4.2 114-byte ciphertext vector" {
    var key: [key_len]u8 = undefined;
    var i: usize = 0;
    while (i < key_len) : (i += 1) key[i] = @intCast(i);
    const nonce = [nonce_len]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x00, 0x00, 0x00 };
    const plaintext =
        "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
    var out: [114]u8 = undefined;
    @memcpy(&out, plaintext);
    var off: usize = 0;
    var block: [block_len]u8 = undefined;
    while (off < out.len) : (off += block_len) {
        chacha20_block(&key, 1 + @as(u32, @intCast(off / block_len)), &nonce, &block);
        const take = @min(block_len, out.len - off);
        var k: usize = 0;
        while (k < take) : (k += 1) out[off + k] ^= block[k];
    }
    const expected = [114]u8{
        0x6e, 0x2e, 0x35, 0x9a, 0x25, 0x68, 0xf9, 0x80, 0x41, 0xba, 0x07, 0x28, 0xdd, 0x0d, 0x69, 0x81,
        0xe9, 0x7e, 0x7a, 0xec, 0x1d, 0x43, 0x60, 0xc2, 0x0a, 0x27, 0xaf, 0xcc, 0xfd, 0x9f, 0xae, 0x0b,
        0xf9, 0x1b, 0x65, 0xc5, 0x52, 0x47, 0x33, 0xab, 0x8f, 0x59, 0x3d, 0xab, 0xcd, 0x62, 0xb3, 0x57,
        0x16, 0x39, 0xd6, 0x24, 0xe6, 0x51, 0x52, 0xab, 0x8f, 0x53, 0x0c, 0x35, 0x9f, 0x08, 0x61, 0xd8,
        0x07, 0xca, 0x0d, 0xbf, 0x50, 0x0d, 0x6a, 0x61, 0x56, 0xa3, 0x8e, 0x08, 0x8a, 0x22, 0xb6, 0x5e,
        0x52, 0xbc, 0x51, 0x4d, 0x16, 0xcc, 0xf8, 0x06, 0x81, 0x8c, 0xe9, 0x1a, 0xb7, 0x79, 0x37, 0x36,
        0x5a, 0xf9, 0x0b, 0xbf, 0x74, 0xa3, 0x5b, 0xe6, 0xb4, 0x0b, 0x8e, 0xed, 0xf2, 0x78, 0x5e, 0x42,
        0x87, 0x4d,
    };
    try std.testing.expectEqual(expected, out);
}

test "csprng: stream is continuous across block boundaries and seed-deterministic" {
    var s: [seed_len]u8 = undefined;
    var i: usize = 0;
    while (i < seed_len) : (i += 1) s[i] = @truncate(i * 7 + 3);
    // 200 bytes (spans 4 blocks) split across two calls must equal one call.
    seed(&s);
    var a: [200]u8 = undefined;
    random_bytes(&a);
    seed(&s);
    var b: [200]u8 = undefined;
    random_bytes(b[0..100]);
    random_bytes(b[100..]);
    try std.testing.expectEqual(a, b);
    // Same seed → same stream (determinism).
    seed(&s);
    var c: [32]u8 = undefined;
    random_bytes(&c);
    seed(&s);
    var d: [32]u8 = undefined;
    random_bytes(&d);
    try std.testing.expectEqual(c, d);
    // The 64 seed bytes all contribute: a different byte 48..63 changes the
    // stream even though the key/nonce/counter are identical.
    var s2 = s;
    s2[48] ^= 0xff;
    seed(&s2);
    var e: [32]u8 = undefined;
    random_bytes(&e);
    try std.testing.expect(!std.mem.eql(u8, &c, &e));
}

test "csprng: fallback leaves the module honestly unseeded" {
    seed_fallback();
    try std.testing.expect(!seeded());
    var buf: [16]u8 = undefined;
    random_bytes(&buf);
    // Deterministic: two fallback keyings produce identical output.
    var buf2: [16]u8 = undefined;
    seed_fallback();
    random_bytes(&buf2);
    try std.testing.expectEqual(buf, buf2);
}

test "csprng: ASLR stack placement stays in band, aligned, clear of text_va" {
    // Pure placement function: every input maps into the band, 64 KiB
    // aligned, never text_va (4 MiB).
    var r: u64 = 0;
    while (r < 997) : (r += 1) {
        const va = stack_va_from_random(r *% 0x9e3779b97f4a7c15);
        try std.testing.expect(va >= 0x1_0000_0000);
        try std.testing.expect(va < 0x2_0000_0000);
        try std.testing.expect(va % 0x1_0000 == 0);
        try std.testing.expect(va != 0x0040_0000);
    }
    // Seeded path: a real call also lands in the band.
    seed(&@as([seed_len]u8, @splat(@as(u8, 0x5a))));
    const va = random_stack_va();
    try std.testing.expect(va >= 0x1_0000_0000 and va < 0x2_0000_0000);
    try std.testing.expect(va % 0x1_0000 == 0);
}

test "csprng: unseeded ASLR returns the fixed default" {
    const was = seeded_flag;
    defer seeded_flag = was;
    seeded_flag = false;
    try std.testing.expectEqual(default_stack_va, random_stack_va());
}
