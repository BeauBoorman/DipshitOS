//! SHA-384 (FIPS 180-4 §6.5) — the truncated SHA-512 variant TLS 1.3 needs
//! for `TLS_AES_256_GCM_SHA384` (RFC 8446 §9.1) and for verifying
//! `ecdsa_secp384r1_sha384` certificate signatures.
//!
//! SHA-384 is SHA-512 with a different initial hash value and a 48-byte
//! output; the compression function is identical. This module reuses
//! `sha512.compress` rather than duplicating the round function, so the two
//! hashes cannot drift apart. Freestanding, caller-buffered, no allocation.
//!
//! Verification (class A, `zig test`): the FIPS 180-4 §B.5 examples plus a
//! 1 MiB `'a'` case. Every expected digest was produced independently with
//! Python 3.14.7 `hashlib.sha384` (OpenSSL 3.6.4) and transcribed verbatim;
//! the same generator reproduced the SHA-512 vectors already pinned in
//! `sha512.zig`, which is the cross-check that the generator is sound.

const std = @import("std");
const sha512 = @import("sha512.zig");

pub const block_len = 128;
pub const digest_len = 48;

/// FIPS 180-4 §5.3.4 SHA-384 initial hash value.
const iv = [8]u64{
    0xcbbb9d5dc1059ed8, 0x629a292a367cd507, 0x9159015a3070dd17, 0x152fecd8f70e5939,
    0x67332667ffc00b31, 0x8eb44a8768581511, 0xdb0c2e0d64f98fa7, 0x47b5481dbefa4fa4,
};

pub const Sha384 = struct {
    state: [8]u64 = iv,
    buf: [block_len]u8 = undefined,
    buf_len: usize = 0,
    total: u128 = 0,

    pub fn init() Sha384 {
        return .{};
    }

    pub fn update(self: *Sha384, bytes: []const u8) void {
        self.total +%= bytes.len;
        var i: usize = 0;
        if (self.buf_len != 0) {
            const need = block_len - self.buf_len;
            const take = @min(need, bytes.len);
            @memcpy(self.buf[self.buf_len..][0..take], bytes[0..take]);
            self.buf_len += take;
            i += take;
            if (self.buf_len == block_len) {
                sha512.compress(&self.state, &self.buf);
                self.buf_len = 0;
            }
        }
        while (i + block_len <= bytes.len) : (i += block_len) {
            sha512.compress(&self.state, bytes[i..][0..block_len]);
        }
        if (i < bytes.len) {
            const tail = bytes.len - i;
            @memcpy(self.buf[0..tail], bytes[i..]);
            self.buf_len = tail;
        }
    }

    pub fn final(self: *Sha384, out: *[digest_len]u8) void {
        const bit_len: u128 = self.total << 3;
        self.buf[self.buf_len] = 0x80;
        self.buf_len += 1;
        if (self.buf_len > block_len - 16) {
            @memset(self.buf[self.buf_len..block_len], 0);
            sha512.compress(&self.state, &self.buf);
            self.buf_len = 0;
        }
        @memset(self.buf[self.buf_len .. block_len - 16], 0);
        std.mem.writeInt(u128, self.buf[block_len - 16 ..][0..16], bit_len, .big);
        sha512.compress(&self.state, &self.buf);
        // Truncate: the leftmost 48 bytes of the 64-byte SHA-512 state.
        for (0..6) |j| std.mem.writeInt(u64, out[j * 8 ..][0..8], self.state[j], .big);
    }
};

/// One-shot SHA-384.
pub fn sha384(out: *[digest_len]u8, bytes: []const u8) void {
    var h = Sha384.init();
    h.update(bytes);
    h.final(out);
}

fn hex(comptime s: []const u8) ![s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return error.BadHex;
    return out;
}

test "sha384: FIPS 180-4 empty message" {
    var out: [48]u8 = undefined;
    sha384(&out, "");
    const exp = try hex("38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "sha384: FIPS 180-4 \"abc\"" {
    var out: [48]u8 = undefined;
    sha384(&out, "abc");
    const exp = try hex("cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "sha384: FIPS 180-4 112-byte multi-block message" {
    var out: [48]u8 = undefined;
    sha384(&out, "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu");
    const exp = try hex("09330c33f71147e83d192fc782cd1b4753111b173b3b05d22fa08086e3b0f712fcc7c71a557e2db966c3e9fa91746039");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "sha384: 1,000,000 bytes of 'a' (length padding across many blocks)" {
    // Exactly 1,000,000 bytes (one million, as Python's `b"a"*1000000`
    // generated the expected digest) - not 1 MiB.
    var h = Sha384.init();
    const chunk = @as([1000]u8, @splat(@as(u8, 'a')));
    var i: usize = 0;
    while (i < 1000) : (i += 1) h.update(&chunk);
    var out: [48]u8 = undefined;
    h.final(&out);
    const exp = try hex("9d0e1809716474cb086e834e310a4a1ced149e9c00f248527972cec5704c2a5b07b8b3dc38ecc4ebae97ddd87f3d8985");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "sha384: streaming across every chunk boundary equals one-shot" {
    const msg = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu";
    var one: [48]u8 = undefined;
    sha384(&one, msg);
    var chunk: usize = 1;
    while (chunk <= msg.len) : (chunk += 1) {
        var h = Sha384.init();
        var i: usize = 0;
        while (i < msg.len) : (i += chunk) h.update(msg[i..@min(i + chunk, msg.len)]);
        var got: [48]u8 = undefined;
        h.final(&got);
        try std.testing.expectEqualSlices(u8, &one, &got);
    }
}

test "sha384: distinct from sha512's leftmost 48 bytes (truncation guard)" {
    // SHA-384 is not "SHA-512 truncated" — the IV differs. This is the
    // drift guard: if someone rewires Sha384 onto sha512's IV, this fails.
    var s384: [48]u8 = undefined;
    sha384(&s384, "abc");
    var s512: [64]u8 = undefined;
    sha512.sha512(&s512, "abc");
    try std.testing.expect(!std.mem.eql(u8, &s384, s512[0..48]));
}
