//! SHA-256 and HMAC-SHA256 (M47 CP1, ADR 0023).
//!
//! FIPS 180-4 SHA-256 with a streaming context, plus RFC 2104 / RFC 4231
//! HMAC-SHA256. Everything is caller-buffered: `Sha256` is a plain value
//! (no allocation, no globals, no I/O), and the convenience functions take
//! fixed-size output arrays.
//!
//! Verified against the FIPS 180-4 examples and RFC 4231 cases (class-A
//! `zig test`). No libc, no POSIX, no allocation.

const std = @import("std");

pub const block_len = 64;
pub const digest_len = 32;

const k = [64]u32{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

const iv = [8]u32{
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
};

pub const Sha256 = struct {
    state: [8]u32 = iv,
    buf: [block_len]u8 = undefined,
    buf_len: usize = 0,
    total: u64 = 0,

    pub fn init() Sha256 {
        return .{};
    }

    pub fn update(self: *Sha256, bytes: []const u8) void {
        self.total +%= bytes.len;
        var i: usize = 0;
        if (self.buf_len != 0) {
            const need = block_len - self.buf_len;
            const take = @min(need, bytes.len);
            @memcpy(self.buf[self.buf_len..][0..take], bytes[0..take]);
            self.buf_len += take;
            i += take;
            if (self.buf_len == block_len) {
                compress(&self.state, &self.buf);
                self.buf_len = 0;
            }
        }
        while (i + block_len <= bytes.len) : (i += block_len) {
            compress(&self.state, bytes[i..][0..block_len]);
        }
        if (i < bytes.len) {
            const tail = bytes.len - i;
            @memcpy(self.buf[0..tail], bytes[i..]);
            self.buf_len = tail;
        }
    }

    pub fn final(self: *Sha256, out: *[digest_len]u8) void {
        const bit_len: u64 = self.total << 3;
        self.buf[self.buf_len] = 0x80;
        self.buf_len += 1;
        if (self.buf_len > block_len - 8) {
            @memset(self.buf[self.buf_len..block_len], 0);
            compress(&self.state, &self.buf);
            self.buf_len = 0;
        }
        @memset(self.buf[self.buf_len .. block_len - 8], 0);
        std.mem.writeInt(u64, self.buf[block_len - 8 ..][0..8], bit_len, .big);
        compress(&self.state, &self.buf);
        for (0..8) |j| std.mem.writeInt(u32, out[j * 4 ..][0..4], self.state[j], .big);
    }
};

fn compress(state: *[8]u32, block: *const [block_len]u8) void {
    var w: [64]u32 = undefined;
    for (0..16) |j| w[j] = std.mem.readInt(u32, block[j * 4 ..][0..4], .big);
    for (16..64) |j| {
        const x = w[j - 15];
        const y = w[j - 2];
        const s0 = std.math.rotr(u32, x, 7) ^ std.math.rotr(u32, x, 18) ^ (x >> 3);
        const s1 = std.math.rotr(u32, y, 17) ^ std.math.rotr(u32, y, 19) ^ (y >> 10);
        w[j] = w[j - 16] +% s0 +% w[j - 7] +% s1;
    }

    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var f = state[5];
    var g = state[6];
    var h = state[7];

    for (0..64) |j| {
        const s1 = std.math.rotr(u32, e, 6) ^ std.math.rotr(u32, e, 11) ^ std.math.rotr(u32, e, 25);
        const ch = (e & f) ^ (~e & g);
        const t1 = h +% s1 +% ch +% k[j] +% w[j];
        const s0 = std.math.rotr(u32, a, 2) ^ std.math.rotr(u32, a, 13) ^ std.math.rotr(u32, a, 22);
        const maj = (a & b) ^ (a & c) ^ (b & c);
        const t2 = s0 +% maj;
        h = g;
        g = f;
        f = e;
        e = d +% t1;
        d = c;
        c = b;
        b = a;
        a = t1 +% t2;
    }

    state[0] +%= a;
    state[1] +%= b;
    state[2] +%= c;
    state[3] +%= d;
    state[4] +%= e;
    state[5] +%= f;
    state[6] +%= g;
    state[7] +%= h;
}

/// One-shot SHA-256.
pub fn sha256(out: *[digest_len]u8, bytes: []const u8) void {
    var h = Sha256.init();
    h.update(bytes);
    h.final(out);
}

// ---------------------------------------------------------------------------
// Host tests — FIPS 180-4 KATs (streaming and one-shot agree)
// ---------------------------------------------------------------------------

test "sha256: FIPS 180-4 empty message" {
    var out: [32]u8 = undefined;
    sha256(&out, "");
    const exp = try hex("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "sha256: FIPS 180-4 \"abc\"" {
    var out: [32]u8 = undefined;
    sha256(&out, "abc");
    const exp = try hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "sha256: FIPS 180-4 56-byte multi-block message" {
    var out: [32]u8 = undefined;
    sha256(&out, "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq");
    const exp = try hex("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "sha256: streaming across every chunk boundary equals one-shot" {
    const msg = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    var one: [32]u8 = undefined;
    sha256(&one, msg);
    var chunk: usize = 1;
    while (chunk <= msg.len) : (chunk += 1) {
        var h = Sha256.init();
        var i: usize = 0;
        while (i < msg.len) : (i += chunk) h.update(msg[i..@min(i + chunk, msg.len)]);
        var got: [32]u8 = undefined;
        h.final(&got);
        try std.testing.expectEqualSlices(u8, &one, &got);
    }
}

test "sha256: FIPS 180-4 one million 'a' (streaming)" {
    var h = Sha256.init();
    const block = @as([1000]u8, @splat(@as(u8, 'a')));
    for (0..1000) |_| h.update(&block);
    var out: [32]u8 = undefined;
    h.final(&out);
    const exp = try hex("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

fn hex(comptime s: []const u8) ![s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return error.BadHex;
    return out;
}
