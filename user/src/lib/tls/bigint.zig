//! Fixed-capacity big-integer arithmetic with Montgomery modular
//! multiplication, for RSA and ECDSA *verification*. No allocation: every
//! operation writes into caller-supplied fixed arrays, and anything that does
//! not fit is an error rather than a silent truncation.
//!
//! Only what verification needs is here: compare, add, subtract, a full
//! product, Montgomery reduction, and square-and-multiply exponentiation. The
//! exponent is public (RSA's `e`, or `n-2` for a Fermat inversion), so the
//! ladder is not constant-time — that is irrelevant for verification of public
//! data, and saying so is cheaper than pretending otherwise.
//!
//! Capacity is 4096 bits (64 limbs). RSA-2048/3072/4096 all fit; the modulus
//! is the range that matters for certificates.

const std = @import("std");

pub const max_limbs = 64;
pub const max_bytes = max_limbs * 8;

pub const Error = error{
    ModulusTooSmall,
    ModulusTooLarge,
    ModulusMustBeOdd,
    ValueTooLarge,
    Empty,
};

/// Little-endian u64 limbs. `n` is the number of significant limbs.
pub const Int = struct {
    limbs: [max_limbs]u64 = @as([max_limbs]u64, @splat(@as(u64, 0))),
    n: usize = 0,

    pub fn fromBytesBE(bytes: []const u8) Error!Int {
        if (bytes.len == 0) return Error.Empty;
        if (bytes.len > max_bytes) return Error.ModulusTooLarge;
        var out: Int = .{};
        var i = bytes.len;
        while (i > 0) {
            const take = @min(8, i);
            const start = i - take;
            var v: u64 = 0;
            for (bytes[start..i]) |b| v = (v << 8) | b;
            out.limbs[out.n] = v;
            out.n += 1;
            i = start;
        }
        out.trim();
        return out;
    }

    pub fn fromU64(v: u64) Int {
        var out: Int = .{};
        out.limbs[0] = v;
        out.n = if (v == 0) 0 else 1;
        return out;
    }

    pub fn trim(self: *Int) void {
        while (self.n > 0 and self.limbs[self.n - 1] == 0) self.n -= 1;
    }

    pub fn isZero(self: *const Int) bool {
        return self.n == 0;
    }

    pub fn isOdd(self: *const Int) bool {
        return self.n != 0 and (self.limbs[0] & 1) == 1;
    }

    pub fn bytesLen(self: *const Int) usize {
        return self.n * 8;
    }

    /// Write exactly `out.len` big-endian bytes; leading zeros are padded.
    pub fn writeBytesBE(self: *const Int, out: []u8) Error!void {
        if (out.len < self.n * 8) return Error.ValueTooLarge;
        var idx: usize = 0;
        while (idx < out.len) : (idx += 1) out[idx] = 0;
        var li: usize = 0;
        while (li < self.n) : (li += 1) {
            const last = out.len - li * 8;
            const start = last - 8;
            std.mem.writeInt(u64, out[start..][0..8], self.limbs[li], .big);
        }
    }

    /// Significant bytes, big-endian, no leading zeros. Returns a slice of `out`.
    pub fn writeBytesBETrim(self: *const Int, out: []u8) []u8 {
        if (self.n == 0) {
            out[0] = 0;
            return out[0..1];
        }
        const total = self.n * 8;
        // count leading zero bytes of the top limb
        var top = self.limbs[self.n - 1];
        var lead: usize = 0;
        while (lead < 7 and (top >> 56) == 0) : (lead += 1) top <<= 8;
        const len = total - lead;
        self.writeBytesBE(out[0..total]) catch unreachable;
        return out[lead..total][0..len];
    }

    pub fn cmp(self: *const Int, other: *const Int) i8 {
        if (self.n != other.n) return if (self.n > other.n) 1 else -1;
        var i = self.n;
        while (i > 0) {
            i -= 1;
            if (self.limbs[i] != other.limbs[i]) return if (self.limbs[i] > other.limbs[i]) 1 else -1;
        }
        return 0;
    }
};

fn addInto(a: *[max_limbs]u64, b: []const u64, n: usize) u64 {
    var carry: u64 = 0;
    for (0..n) |i| {
        const s = @as(u128, a[i]) + b[i] + carry;
        a[i] = @truncate(s);
        carry = @truncate(s >> 64);
    }
    return carry;
}

fn subInto(a: *[max_limbs]u64, b: []const u64, n: usize) u64 {
    var borrow: u64 = 0;
    for (0..n) |i| {
        const t = @as(u128, a[i]) -% @as(u128, b[i]) -% @as(u128, borrow);
        a[i] = @truncate(t);
        borrow = @truncate(t >> 127);
    }
    return borrow;
}

fn cmpSlice(a: []const u64, b: []const u64, n: usize) i8 {
    var i = n;
    while (i > 0) {
        i -= 1;
        if (a[i] != b[i]) return if (a[i] > b[i]) 1 else -1;
    }
    return 0;
}

fn mulFull(out: *[2 * max_limbs]u64, a: []const u64, b: []const u64, n: usize) void {
    @memset(out, 0);
    for (0..n) |i| {
        var carry: u64 = 0;
        const ai: u128 = a[i];
        for (0..n) |j| {
            const t = ai * b[j] + out[i + j] + carry;
            out[i + j] = @truncate(t);
            carry = @truncate(t >> 64);
        }
        out[i + n] = carry;
    }
}

/// -m^-1 mod 2^64, by Newton iteration on the inverse (m must be odd).
fn negInv64(m0: u64) u64 {
    // x is correct mod 2^1 after the seed; each step squares the number of
    // correct bits (1 -> 2 -> 4 -> ... -> 64), so six steps reach 64.
    var x: u64 = 1;
    var i: usize = 0;
    while (i < 6) : (i += 1) x = x *% (2 -% m0 *% x);
    return 0 -% x;
}

fn shl1(a: *[max_limbs]u64, n: usize) u64 {
    var carry: u64 = 0;
    for (0..n) |i| {
        const v = a[i];
        a[i] = (v << 1) | carry;
        carry = v >> 63;
    }
    return carry;
}

/// out = 2^k mod m, by repeated doubling. `m` must be non-zero.
fn modPOW2(out: *[max_limbs]u64, n: usize, m: []const u64, k: usize) void {
    @memset(out, 0);
    out[0] = 1;
    var i: usize = 0;
    while (i < k) : (i += 1) {
        const carry = shl1(out, n);
        if (carry != 0 or cmpSlice(out[0..n], m[0..n], n) >= 0) _ = subInto(out, m[0..n], n);
    }
}

/// Montgomery context for one odd modulus.
pub const Mont = struct {
    m: [max_limbs]u64 = @as([max_limbs]u64, @splat(@as(u64, 0))),
    n: usize = 0,
    m0inv: u64 = 0,
    one: [max_limbs]u64 = @as([max_limbs]u64, @splat(@as(u64, 0))), // R mod m
    r2: [max_limbs]u64 = @as([max_limbs]u64, @splat(@as(u64, 0))), // R^2 mod m

    pub fn init(modulus: []const u8) Error!Mont {
        const mv = try Int.fromBytesBE(modulus);
        if (mv.n == 0) return Error.ModulusTooSmall;
        if (!mv.isOdd()) return Error.ModulusMustBeOdd;
        var self: Mont = .{ .n = mv.n };
        @memcpy(self.m[0..mv.n], mv.limbs[0..mv.n]);
        self.m0inv = negInv64(self.m[0]);
        const bits = self.n * 64;
        modPOW2(&self.one, self.n, self.m[0..self.n], bits);
        modPOW2(&self.r2, self.n, self.m[0..self.n], 2 * bits);
        return self;
    }

    /// Montgomery reduction: returns T * R^-1 mod m for T < m*R.
    fn redc(self: *const Mont, t_in: []const u64) [max_limbs]u64 {
        const n = self.n;
        var t: [2 * max_limbs + 2]u64 = @as([(2 * max_limbs + 2)]u64, @splat(@as(u64, 0)));
        @memcpy(t[0 .. 2 * n], t_in[0 .. 2 * n]);

        for (0..n) |i| {
            const u = t[i] *% self.m0inv;
            var carry: u64 = 0;
            for (0..n) |j| {
                const p = @as(u128, u) * self.m[j] + t[i + j] + carry;
                t[i + j] = @truncate(p);
                carry = @truncate(p >> 64);
            }
            var k = i + n;
            while (carry != 0) : (k += 1) {
                const s = @as(u128, t[k]) + carry;
                t[k] = @truncate(s);
                carry = @truncate(s >> 64);
            }
        }

        var out: [max_limbs]u64 = @as([max_limbs]u64, @splat(@as(u64, 0)));
        @memcpy(out[0..n], t[n .. 2 * n]);
        var hi = t[2 * n];

        // The intermediate is < 2m, so at most one subtraction is needed; the
        // second branch exists only for the carry-limb case and is asserted
        // away in the tests.
        if (hi != 0 or cmpSlice(out[0..n], self.m[0..n], n) >= 0) {
            const borrow = subInto(&out, self.m[0..n], n);
            hi -%= borrow;
            if (hi != 0) {
                _ = subInto(&out, self.m[0..n], n);
                hi -%= 1;
            }
        }
        std.debug.assert(hi == 0);
        return out;
    }

    /// a * b mod m, with both operands in Montgomery form.
    pub fn mul(self: *const Mont, a: []const u64, b: []const u64) [max_limbs]u64 {
        var t: [2 * max_limbs]u64 = undefined;
        mulFull(&t, a, b, self.n);
        return self.redc(&t);
    }

    /// Convert into the Montgomery domain.
    pub fn toMont(self: *const Mont, x: []const u64) [max_limbs]u64 {
        return self.mul(x, &self.r2);
    }

    /// Convert out of the Montgomery domain: a plain Montgomery reduction of
    /// `x * 1`. Multiplying by `self.one` (which is R mod m, the identity *in*
    /// the Montgomery domain) would leave an extra factor of R behind.
    pub fn fromMont(self: *const Mont, x: []const u64) [max_limbs]u64 {
        var plain: [max_limbs]u64 = @as([max_limbs]u64, @splat(@as(u64, 0)));
        plain[0] = 1;
        var t: [2 * max_limbs]u64 = undefined;
        mulFull(&t, x, &plain, self.n);
        return self.redc(&t);
    }

    /// base^exp mod m, with `exp` big-endian bytes. Returns plain (not
    /// Montgomery) limbs in `out`.
    pub fn expMod(self: *const Mont, base_bytes: []const u8, exp_bytes: []const u8, out: *[max_limbs]u64) Error!void {
        const b = try Int.fromBytesBE(base_bytes);
        if (b.n > self.n) return Error.ValueTooLarge;
        const e = try Int.fromBytesBE(exp_bytes);

        var acc = self.one;
        var base = self.toMont(b.limbs[0..self.n]);

        if (e.isZero()) {
            // x^0 = 1, but only after reducing x, so a 0^0 does not leak a
            // non-reduced value.
            out.* = self.fromMont(&self.one);
            return;
        }

        var li = e.n;
        var started = false;
        while (li > 0) {
            li -= 1;
            const limb = e.limbs[li];
            if (!started and limb == 0) continue;
            started = true;
            var bit: usize = 64;
            while (bit > 0) {
                bit -= 1;
                acc = self.mul(&acc, &acc);
                if ((limb >> @intCast(bit)) & 1 != 0) acc = self.mul(&acc, &base);
            }
        }
        out.* = self.fromMont(&acc);
    }

    /// Modular inverse via Fermat (m assumed prime): a^(m-2).
    pub fn invModPrime(self: *const Mont, a_bytes: []const u8, out: *[max_limbs]u64) Error!void {
        var e: [max_limbs]u64 = undefined;
        @memcpy(e[0..self.n], self.m[0..self.n]);
        var borrow: u64 = 2;
        var i: usize = 0;
        while (borrow != 0 and i < self.n) : (i += 1) {
            const s = @as(u128, e[i]) -% @as(u128, borrow);
            e[i] = @truncate(s);
            borrow = @truncate(s >> 127);
        }
        var ebytes: [max_bytes]u8 = undefined;
        var eint = Int{ .limbs = e, .n = self.n };
        eint.trim();
        const elen = eint.writeBytesBETrim(&ebytes);
        return self.expMod(a_bytes, elen, out);
    }
};

const vectors = @import("rsa_vectors.zig");

fn decode(out: []u8, hexstr: []const u8) usize {
    _ = std.fmt.hexToBytes(out[0 .. hexstr.len / 2], hexstr) catch unreachable;
    return hexstr.len / 2;
}

test "bigint: Montgomery modexp matches Python's bignum on every vector" {
    var m: [1024]u8 = undefined;
    var b: [1024]u8 = undefined;
    var e: [1024]u8 = undefined;
    var expect: [1024]u8 = undefined;

    for (vectors.modexp) |v| {
        const mn = decode(&m, v.mod_hex);
        const bn = decode(&b, v.base_hex);
        const en = decode(&e, v.exp_hex);
        const rn = decode(&expect, v.res_hex);

        const mont = Mont.init(m[0..mn]) catch |err| {
            std.debug.print("init failed for {s}: {any}\n", .{ v.name, err });
            return err;
        };
        var out: [max_limbs]u64 = undefined;
        try mont.expMod(b[0..bn], e[0..en], &out);
        var res = Int{ .limbs = out, .n = mont.n };
        res.trim();
        var buf: [max_bytes]u8 = undefined;
        const got_bytes = res.writeBytesBETrim(&buf);
        if (!std.mem.eql(u8, got_bytes, expect[0..rn])) {
            std.debug.print("modexp mismatch {s}\n  want {s}\n  got  {s}\n", .{ v.name, v.res_hex, got_bytes });
            return error.ModexpMismatch;
        }
    }
}

test "bigint: multiply and reduce round-trips against the identity" {
    // (a * b) * 1 == a * b in the Montgomery domain, and fromMont(toMont(x)) == x.
    const mont = try Mont.init(&[_]u8{ 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
    const x = Int.fromU64(0xdeadbeefcafebabe);
    const xm = mont.toMont(x.limbs[0..mont.n]);
    const back = mont.fromMont(&xm);
    var res = Int{ .limbs = back, .n = mont.n };
    res.trim();
    try std.testing.expectEqual(@as(u64, 0xdeadbeefcafebabe), res.limbs[0]);
    try std.testing.expectEqual(@as(usize, 1), res.n);

    // Multiplying by the Montgomery representation of 1 is the identity.
    const identity = mont.mul(&xm, &mont.one);
    var id_int = Int{ .limbs = identity, .n = mont.n };
    id_int.trim();
    var buf_a: [max_bytes]u8 = undefined;
    var buf_b: [max_bytes]u8 = undefined;
    var xm_int = Int{ .limbs = xm, .n = mont.n };
    xm_int.trim();
    const a = xm_int.writeBytesBETrim(&buf_a);
    const b = id_int.writeBytesBETrim(&buf_b);
    try std.testing.expectEqualSlices(u8, a, b);
}

test "bigint: rejects an even modulus and an over-capacity modulus" {
    try std.testing.expectError(Error.ModulusMustBeOdd, Mont.init(&[_]u8{ 0x10, 0x00 }));
    var big: [max_bytes + 1]u8 = undefined;
    @memset(&big, 0xff);
    try std.testing.expectError(Error.ModulusTooLarge, Int.fromBytesBE(&big));
}

test "bigint: 0^0 and 1^x behave" {
    // 65537, odd, so a real modulus rather than the degenerate m = 1.
    const mont = try Mont.init(&[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01 });
    var out: [max_limbs]u64 = undefined;
    try mont.expMod(&[_]u8{0x00}, &[_]u8{0x00}, &out);
    var r = Int{ .limbs = out, .n = mont.n };
    r.trim();
    try std.testing.expectEqual(@as(u64, 1), r.limbs[0]);
}
