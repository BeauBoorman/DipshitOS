//! Kernel PBKDF2-HMAC-SHA256 (RFC 8018 §5.2), M172b, ADR 0023.
//!
//! Password-based key derivation over the kernel's existing primitives:
//! `measure.zig` carries the kernel-local SHA-256 (ADR 0023 D2 — no
//! `kernel/`→`user/` translation unit, drift-guarded by the shared FIPS
//! 180-4 vectors), and the RFC 2104 HMAC below is the streaming form
//! ported from `user/src/lib/crypto/hmac.zig` over that same context.
//! (`vsock_ctl.zig` holds a file-private one-shot HMAC for its own auth
//! path; this module carries the reusable streaming HMAC.)
//!
//! PBKDF2: DK = T₁‖T₂‖… where Tᵢ = U₁⊕U₂⊕…⊕U꜀, U₁ = PRF(P, S‖INT32_BE(i)),
//! Uⱼ = PRF(P, Uⱼ₋₁). Streaming, caller-buffered, no allocation.
//!
//! Verified against published PBKDF2-HMAC-SHA256 vectors (the
//! password/salt c ∈ {1, 2, 4096} set cross-checked against a reference
//! implementation) and the RFC 4231 test-case-1 HMAC vector as class-A
//! `zig test`. No libc, no POSIX, no allocation.

const std = @import("std");
const measure = @import("measure.zig");

/// Streaming RFC 2104 HMAC-SHA256 over `measure.Sha256`. The key is
/// normalized to the hash block size (over-long keys are hashed first),
/// then the ipad/opad construction runs over the two hash contexts.
pub const HmacSha256 = struct {
    inner: measure.Sha256,
    opad: [measure.block_len]u8,

    pub fn init(key: []const u8) HmacSha256 {
        var kblock = @as([measure.block_len]u8, @splat(@as(u8, 0)));
        if (key.len > measure.block_len) {
            var d: [measure.digest_len]u8 = undefined;
            measure.hash(&d, key);
            @memcpy(kblock[0..measure.digest_len], &d);
        } else {
            @memcpy(kblock[0..key.len], key);
        }
        var ipad: [measure.block_len]u8 = undefined;
        var opad: [measure.block_len]u8 = undefined;
        for (0..measure.block_len) |i| {
            ipad[i] = kblock[i] ^ 0x36;
            opad[i] = kblock[i] ^ 0x5c;
        }
        var inner = measure.Sha256.init();
        inner.update(&ipad);
        return .{ .inner = inner, .opad = opad };
    }

    pub fn update(self: *HmacSha256, bytes: []const u8) void {
        self.inner.update(bytes);
    }

    pub fn final(self: *HmacSha256, out: *[measure.digest_len]u8) void {
        var inner_digest: [measure.digest_len]u8 = undefined;
        self.inner.final(&inner_digest);
        var outer = measure.Sha256.init();
        outer.update(&self.opad);
        outer.update(&inner_digest);
        outer.final(out);
    }
};

/// One-shot HMAC-SHA256.
pub fn hmac_sha256(out: *[measure.digest_len]u8, key: []const u8, msg: []const u8) void {
    var h = HmacSha256.init(key);
    h.update(msg);
    h.final(out);
}

/// PBKDF2-HMAC-SHA256 (RFC 8018 §5.2): derive `out.len` bytes from `pass`
/// and `salt` with `iters` iterations (c ≥ 1 per the RFC). `out` is
/// caller-buffered; no allocation.
pub fn pbkdf2_hmac_sha256(pass: []const u8, salt: []const u8, iters: u32, out: []u8) void {
    std.debug.assert(iters >= 1);
    var block_index: u32 = 1;
    var off: usize = 0;
    while (off < out.len) : (block_index +%= 1) {
        var u: [measure.digest_len]u8 = undefined;
        var h = HmacSha256.init(pass);
        h.update(salt);
        var ctr: [4]u8 = undefined;
        std.mem.writeInt(u32, &ctr, block_index, .big);
        h.update(&ctr);
        h.final(&u);
        var t = u;
        var i: u32 = 1;
        while (i < iters) : (i += 1) {
            var h2 = HmacSha256.init(pass);
            h2.update(&u);
            h2.final(&u);
            for (0..measure.digest_len) |j| t[j] ^= u[j];
        }
        const take = @min(measure.digest_len, out.len - off);
        @memcpy(out[off..][0..take], t[0..take]);
        off += take;
    }
}

// ---------------------------------------------------------------------------
// Host tests — RFC 4231 HMAC + published PBKDF2-HMAC-SHA256 vectors
// ---------------------------------------------------------------------------

fn hex(comptime s: []const u8) ![s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return error.BadHex;
    return out;
}

test "kdf: RFC 4231 test case 1 HMAC-SHA256" {
    const key = @as([20]u8, @splat(0x0b));
    var out: [measure.digest_len]u8 = undefined;
    hmac_sha256(&out, &key, "Hi There");
    const exp = try hex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "kdf: published PBKDF2-HMAC-SHA256 vectors (password/salt)" {
    // The widely published c ∈ {1, 2, 4096} set at dkLen = 32.
    var out: [32]u8 = undefined;

    pbkdf2_hmac_sha256("password", "salt", 1, &out);
    try std.testing.expectEqualSlices(u8, &try hex("120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"), &out);

    pbkdf2_hmac_sha256("password", "salt", 2, &out);
    try std.testing.expectEqualSlices(u8, &try hex("ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"), &out);

    pbkdf2_hmac_sha256("password", "salt", 4096, &out);
    try std.testing.expectEqualSlices(u8, &try hex("c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"), &out);
}

test "kdf: multi-block and partial-block output" {
    // dkLen = 64 spans two Tᵢ blocks; dkLen = 20 truncates T₁.
    var out64: [64]u8 = undefined;
    pbkdf2_hmac_sha256("password", "salt", 2, &out64);
    try std.testing.expectEqualSlices(u8, &try hex(
        "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43" ++
            "830651afcb5c862f0b249bd031f7a67520d136470f5ec271ece91c07773253d9",
    ), &out64);

    var out20: [20]u8 = undefined;
    pbkdf2_hmac_sha256("password", "salt", 1, &out20);
    try std.testing.expectEqualSlices(u8, &try hex("120fb6cffcf8b32c43e7225256c4f837a86548c9"), &out20);
}
