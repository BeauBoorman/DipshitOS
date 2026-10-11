//! ECDSA verification over NIST P-256 and P-384 (FIPS 186-4 §6.4, verify
//! only). Freestanding, fixed capacity, no allocation.
//!
//! Field arithmetic is Montgomery multiplication modulo the curve prime
//! (`bigint.zig`); points use Jacobian coordinates for the scalar multiply and
//! affine for the result. Verification is on public data, so the ladder is
//! plain double-and-add — not constant-time — which is fine here and stated
//! rather than hidden.
//!
//! The curve constants are not typed by hand: they come from
//! `openssl ecparam -param_enc explicit` (see `ecdsa_vectors.zig`), and the
//! verifier is checked against `openssl dgst -sign` signatures.

const std = @import("std");
const bigint = @import("bigint.zig");
const crypto = @import("crypto");

const max_limbs = bigint.max_limbs;
const L = max_limbs;

const Fe = [L]u64;

fn zero() Fe {
    return @as([L]u64, @splat(@as(u64, 0)));
}

pub const Error = error{
    SignatureOutOfRange,
    NotOnCurve,
    PointAtInfinity,
    ValueTooLarge,
};

pub const Curve = struct {
    mont: bigint.Mont, // mod p
    n_mont: bigint.Mont, // mod n
    p: Fe, // plain p, for conditional subtraction
    n_plain: Fe, // plain n
    b: Fe, // b in Montgomery form
    gx: Fe, // in Montgomery form
    gy: Fe, // in Montgomery form
    nbytes: usize,

    pub fn init(p_bytes: []const u8, b_bytes: []const u8, n_bytes: []const u8, gx_bytes: []const u8, gy_bytes: []const u8) (bigint.Error || Error)!Curve {
        const mont = bigint.Mont.init(p_bytes) catch return Error.ValueTooLarge;
        const n_mont = bigint.Mont.init(n_bytes) catch return Error.ValueTooLarge;
        var self = Curve{
            .mont = mont,
            .n_mont = n_mont,
            .p = undefined,
            .n_plain = undefined,
            .b = undefined,
            .gx = undefined,
            .gy = undefined,
            .nbytes = n_bytes.len,
        };
        const pv = try bigint.Int.fromBytesBE(p_bytes);
        const nv = try bigint.Int.fromBytesBE(n_bytes);
        self.p = pv.limbs;
        self.n_plain = nv.limbs;
        self.b = self.toFe(b_bytes) catch unreachable;
        self.gx = self.toFe(gx_bytes) catch unreachable;
        self.gy = self.toFe(gy_bytes) catch unreachable;
        return self;
    }

    fn toFe(self: *const Curve, bytes: []const u8) (bigint.Error || Error)!Fe {
        const v = try bigint.Int.fromBytesBE(bytes);
        if (v.n > self.mont.n) return Error.ValueTooLarge;
        return self.mont.toMont(v.limbs[0..self.mont.n]);
    }

    // --- field arithmetic (Montgomery form) ---

    fn feAdd(self: *const Curve, a: Fe, b: Fe) Fe {
        // a, b < p so a+b < 2p. A carry into limb n means a+b >= 2^(64n), and in
        // that case subtracting p wraps back correctly (r + 2^(64n) - p == r - p
        // mod 2^(64n)), so both cases collapse to one conditional subtraction.
        var r = a;
        const carry = addInto(&r, &b, self.mont.n);
        if (carry != 0 or cmpSlice(r[0..self.mont.n], self.p[0..self.mont.n], self.mont.n) >= 0) {
            _ = subInto(&r, self.p[0..self.mont.n], self.mont.n);
        }
        return r;
    }

    fn feSub(self: *const Curve, a: Fe, b: Fe) Fe {
        var r = a;
        const borrow = subInto(&r, &b, self.mont.n);
        if (borrow != 0) _ = addInto(&r, self.p[0..self.mont.n], self.mont.n);
        return r;
    }

    fn feMul(self: *const Curve, a: Fe, b: Fe) Fe {
        return self.mont.mul(&a, &b);
    }

    fn feSquare(self: *const Curve, a: Fe) Fe {
        return self.mont.mul(&a, &a);
    }

    fn feIsZero(a: Fe, n: usize) bool {
        for (a[0..n]) |limb| if (limb != 0) return false;
        return true;
    }

    fn feCmp(a: Fe, b: Fe, n: usize) i8 {
        return cmpSlice(a[0..n], b[0..n], n);
    }

    fn feInv(self: *const Curve, a: Fe) Fe {
        // a^-1 mod p via Fermat. a is in Montgomery form; convert out, invert
        // with p-2, convert back.
        const plain = self.mont.fromMont(&a);
        var pi = bigint.Int{ .limbs = plain, .n = self.mont.n };
        pi.trim();
        var buf: [bigint.max_bytes]u8 = undefined;
        const bytes = pi.writeBytesBETrim(&buf);
        var e: [bigint.max_bytes]u8 = undefined;
        // exponent = p - 2
        var p_int = bigint.Int{ .limbs = self.p, .n = self.mont.n };
        p_int.trim();
        var exp = p_int.limbs;
        var borrow: u64 = 2;
        var i: usize = 0;
        while (borrow != 0 and i < self.mont.n) : (i += 1) {
            const s = @as(u128, exp[i]) -% @as(u128, borrow);
            exp[i] = @truncate(s);
            borrow = @truncate(s >> 127);
        }
        var eint = bigint.Int{ .limbs = exp, .n = self.mont.n };
        eint.trim();
        const elen = eint.writeBytesBETrim(&e);
        var inv: [max_limbs]u64 = undefined;
        self.mont.expMod(bytes, elen, &inv) catch unreachable;
        // expMod returns the plain inverse; re-enter the Montgomery domain.
        return self.mont.toMont(inv[0..self.mont.n]);
    }

    // --- points ---

    // Jacobian point: (X, Y, Z) plus an explicit infinity flag. Affine
    // results carry x/y with z left zero; only x/y/infinity are read there.
    const Point = struct { x: Fe = zero(), y: Fe = zero(), z: Fe = zero(), infinity: bool = true };

    fn isInfinity(p: Point) bool {
        return p.infinity;
    }

    /// Jacobian doubling (a = -3 optimized).
    fn jDouble(self: *const Curve, p: Point) Point {
        if (p.infinity) return p;
        if (feIsZero(p.y, self.mont.n)) return .{ .infinity = true };

        const a = feSquare(self, p.x);
        const b = feSquare(self, p.y);
        const c = feSquare(self, b);
        // D = 2*((X+B)^2 - A - C)
        var d = feSquare(self, feAdd(self, p.x, b));
        d = feSub(self, d, a);
        d = feSub(self, d, c);
        d = feAdd(self, d, d);
        // E = 3*A - 3*Z^4 (a = -3), with Z4 = Z^2 squared
        const z2 = feSquare(self, p.z);
        const z4 = feSquare(self, z2);
        var e = feAdd(self, a, a);
        e = feAdd(self, e, a); // 3A
        const three_z4 = feAdd(self, z4, feAdd(self, z4, z4));
        e = feSub(self, e, three_z4);
        const f = feSquare(self, e);
        // X3 = F - 2D
        const x3 = feSub(self, f, feAdd(self, d, d));
        // Y3 = E*(D - X3) - 8C
        var y3 = feSub(self, d, x3);
        y3 = feMul(self, e, y3);
        var c8 = feAdd(self, c, c); // 2C
        c8 = feAdd(self, c8, c8); // 4C
        c8 = feAdd(self, c8, c8); // 8C
        y3 = feSub(self, y3, c8);
        // Z3 = 2*Y*Z
        const z3 = feAdd(self, feMul(self, p.y, p.z), feMul(self, p.y, p.z));
        return .{ .x = x3, .y = y3, .z = z3, .infinity = false };
    }

    /// Mixed addition: Jacobian P + affine Q.
    fn jMixedAdd(self: *const Curve, p: Point, qx: Fe, qy: Fe) Point {
        if (p.infinity) return .{ .x = qx, .y = qy, .z = self.mont.one, .infinity = false };
        const z1z1 = feSquare(self, p.z);
        const u2x = feMul(self, qx, z1z1);
        const s2 = feMul(self, feMul(self, qy, p.z), z1z1);
        const h = feSub(self, u2x, p.x);
        const r = feSub(self, s2, p.y);
        if (feIsZero(h, self.mont.n)) {
            if (feIsZero(r, self.mont.n)) return self.jDouble(p);
            return .{ .infinity = true };
        }
        const hh = feSquare(self, h);
        const hhh = feMul(self, h, hh);
        const v = feMul(self, p.x, hh);
        var x3 = feSquare(self, r);
        x3 = feSub(self, x3, hhh);
        x3 = feSub(self, x3, feAdd(self, v, v));
        var y3 = feMul(self, r, feSub(self, v, x3));
        y3 = feSub(self, y3, feMul(self, p.y, hhh));
        const z3 = feMul(self, p.z, h);
        return .{ .x = x3, .y = y3, .z = z3, .infinity = false };
    }

    fn toAffine(self: *const Curve, p: Point) Error!Point {
        if (p.infinity) return error.PointAtInfinity;
        const zinv = self.feInv(p.z);
        const zinv2 = feSquare(self, zinv);
        const x = feMul(self, p.x, zinv2);
        const y = feMul(self, feMul(self, p.y, zinv2), zinv);
        return .{ .x = x, .y = y, .infinity = false };
    }

    /// Affine point addition (handles double and infinity).
    fn affAdd(self: *const Curve, p: Point, q: Point) Error!Point {
        if (p.infinity) return q;
        if (q.infinity) return p;
        if (feCmp(p.x, q.x, self.mont.n) == 0) {
            if (feCmp(p.y, q.y, self.mont.n) == 0) return self.affDouble(p);
            return error.PointAtInfinity;
        }
        const slope = feMul(self, feSub(self, q.y, p.y), self.feInv(feSub(self, q.x, p.x)));
        var x3 = feSquare(self, slope);
        x3 = feSub(self, x3, p.x);
        x3 = feSub(self, x3, q.x);
        var y3 = feMul(self, slope, feSub(self, p.x, x3));
        y3 = feSub(self, y3, p.y);
        return .{ .x = x3, .y = y3, .infinity = false };
    }

    fn affDouble(self: *const Curve, p: Point) Error!Point {
        if (p.infinity) return p;
        if (feIsZero(p.y, self.mont.n)) return error.PointAtInfinity;
        // a = -3: slope = 3(x^2 - 1) / 2y
        const x2 = feSquare(self, p.x);
        const one = self.mont.one;
        var num = feSub(self, x2, one);
        num = feAdd(self, feAdd(self, num, num), num); // 3*(x^2 - 1)
        const den = feAdd(self, p.y, p.y); // 2y
        const slope = feMul(self, num, self.feInv(den));
        var x3 = feSquare(self, slope);
        x3 = feSub(self, x3, feAdd(self, p.x, p.x));
        var y3 = feMul(self, slope, feSub(self, p.x, x3));
        y3 = feSub(self, y3, p.y);
        return .{ .x = x3, .y = y3, .infinity = false };
    }

    fn scalarMult(self: *const Curve, k_bytes: []const u8, px: Fe, py: Fe) (bigint.Error || Error)!Point {
        const k = try bigint.Int.fromBytesBE(k_bytes);
        var acc = Point{ .infinity = true };
        var li = k.n;
        var started = false;
        while (li > 0) {
            li -= 1;
            const limb = k.limbs[li];
            if (!started and limb == 0) continue;
            started = true;
            var bit: usize = 64;
            while (bit > 0) {
                bit -= 1;
                acc = self.jDouble(acc);
                if ((limb >> @intCast(bit)) & 1 != 0) acc = self.jMixedAdd(acc, px, py);
            }
        }
        return self.toAffine(acc);
    }

    fn onCurve(self: *const Curve, x: Fe, y: Fe) bool {
        const lhs = feSquare(self, y);
        const x2 = feSquare(self, x);
        const x3 = feMul(self, x2, x);
        // a = -3
        var rhs = feSub(self, x3, feAdd(self, feAdd(self, x, x), x));
        rhs = feAdd(self, rhs, self.b);
        return feCmp(lhs, rhs, self.mont.n) == 0;
    }

    pub fn verify(self: *const Curve, qx_bytes: []const u8, qy_bytes: []const u8, r_bytes: []const u8, s_bytes: []const u8, z_bytes: []const u8) bool {
        const r = bigint.Int.fromBytesBE(r_bytes) catch return false;
        const s = bigint.Int.fromBytesBE(s_bytes) catch return false;
        if (r.isZero() or s.isZero()) return false;
        const n_int = bigint.Int{ .limbs = self.n_plain, .n = self.n_mont.n };
        if (r.cmp(&n_int) >= 0 or s.cmp(&n_int) >= 0) return false;

        const qx = self.toFe(qx_bytes) catch return false;
        const qy = self.toFe(qy_bytes) catch return false;
        if (!self.onCurve(qx, qy)) return false;

        // w = s^-1 mod n (Fermat).
        var s_int = bigint.Int.fromBytesBE(s_bytes) catch return false;
        s_int.trim();
        var sbuf: [bigint.max_bytes]u8 = undefined;
        const s_trim = s_int.writeBytesBETrim(&sbuf);
        var w: [max_limbs]u64 = undefined;
        self.n_mont.invModPrime(s_trim, &w) catch return false;

        // u1 = z*w, u2 = r*w (mod n).
        const z = bigint.Int.fromBytesBE(z_bytes) catch return false;
        const r_int = bigint.Int.fromBytesBE(r_bytes) catch return false;
        const uu1 = self.nMul(z, w);
        const uu2 = self.nMul(r_int, w);

        var u1b: [bigint.max_bytes]u8 = undefined;
        var u2b: [bigint.max_bytes]u8 = undefined;
        var t1 = bigint.Int{ .limbs = uu1, .n = self.n_mont.n };
        var t2 = bigint.Int{ .limbs = uu2, .n = self.n_mont.n };
        t1.trim();
        t2.trim();
        const u1s = t1.writeBytesBETrim(&u1b);
        const u2s = t2.writeBytesBETrim(&u2b);

        const R1 = self.scalarMult(u1s, self.gx, self.gy) catch return false;
        const R2 = self.scalarMult(u2s, qx, qy) catch return false;
        const R = self.affAdd(R1, R2) catch return false;
        if (R.infinity) return false;

        // r == R.x mod n. R.x < p, and p ~ n, so one subtraction suffices.
        const xp = self.mont.fromMont(&R.x);
        var xr = bigint.Int{ .limbs = xp, .n = self.mont.n };
        xr.trim();
        while (xr.cmp(&n_int) >= 0) {
            _ = subInto(&xr.limbs, self.n_plain[0..self.n_mont.n], self.n_mont.n);
            xr.trim();
        }
        var xrb: [bigint.max_bytes]u8 = undefined;
        const xrs = xr.writeBytesBETrim(&xrb);
        var rbuf: [bigint.max_bytes]u8 = undefined;
        const r_trim = r.writeBytesBETrim(&rbuf);
        return std.mem.eql(u8, xrs, r_trim);
    }

    fn nMul(self: *const Curve, a: bigint.Int, b: [max_limbs]u64) [max_limbs]u64 {
        // (a * b) mod n, plain result. b is already reduced (< n).
        var bb = bigint.Int{ .limbs = b, .n = self.n_mont.n };
        bb.trim();
        const am = self.n_mont.toMont(a.limbs[0..self.n_mont.n]);
        const bm = self.n_mont.toMont(bb.limbs[0..self.n_mont.n]);
        const rm = self.n_mont.mul(&am, &bm);
        return self.n_mont.fromMont(&rm);
    }
};

fn addInto(a: *[L]u64, b: []const u64, n: usize) u64 {
    var carry: u64 = 0;
    for (0..n) |i| {
        const s = @as(u128, a[i]) + b[i] + carry;
        a[i] = @truncate(s);
        carry = @truncate(s >> 64);
    }
    return carry;
}

fn subInto(a: *[L]u64, b: []const u64, n: usize) u64 {
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

const vectors = @import("ecdsa_vectors.zig");

/// Construct the P-256 / P-384 curve contexts. The constants are generated
/// from `openssl ecparam -param_enc explicit` into `ecdsa_vectors.zig`, which
/// is shipped in-tree (not a test-only fixture) precisely so these
/// constructors have an authoritative source rather than typed constants.
/// Decode a comptime hex string into a byte array. The curve constants are hex
/// text (as generated from openssl); the constructor needs bytes.
fn hexBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

pub fn curveP256() Curve {
    const p = hexBytes(vectors.p256.p);
    const b = hexBytes(vectors.p256.b);
    const n = hexBytes(vectors.p256.n);
    const gx = hexBytes(vectors.p256.gx);
    const gy = hexBytes(vectors.p256.gy);
    return Curve.init(&p, &b, &n, &gx, &gy) catch unreachable;
}

pub fn curveP384() Curve {
    const p = hexBytes(vectors.p384.p);
    const b = hexBytes(vectors.p384.b);
    const n = hexBytes(vectors.p384.n);
    const gx = hexBytes(vectors.p384.gx);
    const gy = hexBytes(vectors.p384.gy);
    return Curve.init(&p, &b, &n, &gx, &gy) catch unreachable;
}

fn decode(out: []u8, hexstr: []const u8) usize {
    _ = std.fmt.hexToBytes(out[0 .. hexstr.len / 2], hexstr) catch |e| {
        std.debug.print("decode failed: hexlen={d} outlen={d} err={any}\n", .{ hexstr.len, hexstr.len / 2, e });
        unreachable;
    };
    return hexstr.len / 2;
}

test "ecdsa: verifies every OpenSSL signature and rejects mutations" {
    var p: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    var nn: [128]u8 = undefined;
    var gx: [128]u8 = undefined;
    var gy: [128]u8 = undefined;
    var qx: [128]u8 = undefined;
    var qy: [128]u8 = undefined;
    var r: [128]u8 = undefined;
    var s: [128]u8 = undefined;
    var z: [128]u8 = undefined;

    for (vectors.sigs) |v| {
        const params: vectors.Curves = if (std.mem.eql(u8, v.curve, "prime256v1")) vectors.p256 else vectors.p384;
        const plen = decode(&p, params.p);
        const blen = decode(&b, params.b);
        const nlen = decode(&nn, params.n);
        const glen = decode(&gx, params.gx);
        const gylen = decode(&gy, params.gy);
        var curve = Curve.init(p[0..plen], b[0..blen], nn[0..nlen], gx[0..glen], gy[0..gylen]) catch unreachable;

        const qxl = decode(&qx, v.pubx);
        const qyl = decode(&qy, v.puby);
        const rl = decode(&r, v.r);
        const sl = decode(&s, v.s);

        // z = the message hash, truncated to the curve order length.
        const hlen: usize = if (std.mem.eql(u8, v.hash, "sha256")) 32 else 48;
        if (std.mem.eql(u8, v.hash, "sha256")) {
            crypto.sha256.sha256(z[0..32], v.msg);
        } else {
            crypto.sha384.sha384(z[0..48], v.msg);
        }
        const zlen = if (hlen > nlen) nlen else hlen;

        if (!curve.verify(qx[0..qxl], qy[0..qyl], r[0..rl], s[0..sl], z[0..zlen])) {
            std.debug.print("signature rejected: {s}\n", .{v.label});
            return error.SignatureRejected;
        }

        // Mutated signature bit must fail.
        var bad_s = s;
        bad_s[sl - 1] ^= 0x01;
        if (curve.verify(qx[0..qxl], qy[0..qyl], r[0..rl], bad_s[0..sl], z[0..zlen])) {
            return error.MutatedSignatureAccepted;
        }
        // Mutated message must fail.
        var m2: [128]u8 = undefined;
        @memcpy(m2[0..v.msg.len], v.msg);
        m2[0] ^= 0x01;
        var z2: [128]u8 = undefined;
        if (std.mem.eql(u8, v.hash, "sha256")) {
            crypto.sha256.sha256(z2[0..32], m2[0..v.msg.len]);
        } else {
            crypto.sha384.sha384(z2[0..48], m2[0..v.msg.len]);
        }
        if (curve.verify(qx[0..qxl], qy[0..qyl], r[0..rl], s[0..sl], z2[0..zlen])) {
            return error.MutatedMessageAccepted;
        }
    }
}

test "ecdsa: r=0, s=0, r>=n and an off-curve point are refused" {
    const params = vectors.p256;
    var p: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    var nn: [128]u8 = undefined;
    var gx: [128]u8 = undefined;
    var gy: [128]u8 = undefined;
    const plen = decode(&p, params.p);
    const blen = decode(&b, params.b);
    const nlen = decode(&nn, params.n);
    const glen = decode(&gx, params.gx);
    const gylen = decode(&gy, params.gy);
    var curve = Curve.init(p[0..plen], b[0..blen], nn[0..nlen], gx[0..glen], gy[0..gylen]) catch unreachable;

    const v = vectors.sigs[0];
    var qx: [128]u8 = undefined;
    var qy: [128]u8 = undefined;
    var r: [128]u8 = undefined;
    var s: [128]u8 = undefined;
    var z: [128]u8 = undefined;
    const qxl = decode(&qx, v.pubx);
    const qyl = decode(&qy, v.puby);
    const rl = decode(&r, v.r);
    const sl = decode(&s, v.s);
    crypto.sha256.sha256(z[0..32], v.msg);

    const z0 = [_]u8{0x00};
    try std.testing.expect(!curve.verify(qx[0..qxl], qy[0..qyl], &z0, s[0..sl], z[0..32]));
    try std.testing.expect(!curve.verify(qx[0..qxl], qy[0..qyl], r[0..rl], &z0, z[0..32]));

    // r = n is out of range.
    try std.testing.expect(!curve.verify(qx[0..qxl], qy[0..qyl], nn[0..nlen], s[0..sl], z[0..32]));

    // An off-curve public key (qy + 1) is refused.
    var qy_bad = qy;
    qy_bad[qyl - 1] ^= 0x01;
    try std.testing.expect(!curve.verify(qx[0..qxl], qy_bad[0..qyl], r[0..rl], s[0..sl], z[0..32]));
}
