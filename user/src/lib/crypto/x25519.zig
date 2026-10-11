//! X25519 (RFC 7748), M47 CP3, ADR 0023.
//!
//! The Montgomery ladder over the curve25519 field (see `curve25519.zig`).
//! Scalar clamping and the constant-swap ladder are branch-minimal per
//! ADR 0023 D3; no allocation, no I/O.
//!
//! Verified against the RFC 7748 §5.2 scalarmult vectors (including the
//! 1- and 1,000-iteration vectors) and the §6.1 Diffie-Hellman exchange.

const std = @import("std");
const f = @import("curve25519.zig");
const Fe = f.Fe;

pub const basepoint = [_]u8{9} ++ @as([31]u8, @splat(@as(u8, 0)));

/// X25519 scalar multiplication (RFC 7748 §5). `out = scalar * point`.
pub fn scalarmult(out: *[32]u8, scalar: *const [32]u8, point: *const [32]u8) void {
    // Clamp the scalar (RFC 7748 §5).
    var k: [32]u8 = scalar.*;
    k[0] &= 248;
    k[31] &= 127;
    k[31] |= 64;

    // Decode the u-coordinate: mask the high bit and reduce.
    var ub: [32]u8 = point.*;
    ub[31] &= 127;
    const x1 = f.fromBytes(&ub);

    var x2: Fe = 1;
    var z2: Fe = 0;
    var x3: Fe = x1;
    var z3: Fe = 1;
    var swap = false;

    var t: i32 = 254;
    while (t >= 0) : (t -= 1) {
        const kt = ((k[@intCast(@divTrunc(t, 8))] >> @intCast(t & 7)) & 1) == 1;
        swap = swap != kt;
        f.cswap(swap, &x2, &x3);
        f.cswap(swap, &z2, &z3);
        swap = kt;

        const a = f.add(x2, z2);
        const aa = f.sq(a);
        const b = f.sub(x2, z2);
        const bb = f.sq(b);
        const e = f.sub(aa, bb);
        const c = f.add(x3, z3);
        const d = f.sub(x3, z3);
        const da = f.mul(d, a);
        const cb = f.mul(c, b);
        x3 = f.sq(f.add(da, cb));
        z3 = f.mul(x1, f.sq(f.sub(da, cb)));
        x2 = f.mul(aa, bb);
        z2 = f.mul(e, f.add(aa, f.mulA24(e)));
    }
    f.cswap(swap, &x2, &x3);
    f.cswap(swap, &z2, &z3);
    out.* = f.toBytes(f.mul(x2, f.inv(z2)));
}

/// X25519 against the standard base point (scalar * 9).
pub fn scalarmultBase(out: *[32]u8, scalar: *const [32]u8) void {
    scalarmult(out, scalar, &basepoint);
}

fn hex(comptime s: []const u8) ![s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return error.BadHex;
    return out;
}

test "x25519: RFC 7748 §5.2 scalarmult vector 1" {
    const k = try hex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4");
    const u = try hex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c");
    var out: [32]u8 = undefined;
    scalarmult(&out, &k, &u);
    const exp = try hex("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "x25519: RFC 7748 §5.2 scalarmult vector 2" {
    const k = try hex("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d");
    const u = try hex("e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493");
    var out: [32]u8 = undefined;
    scalarmult(&out, &k, &u);
    const exp = try hex("95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "x25519: RFC 7748 §6.1 Diffie-Hellman exchange" {
    const alice_sk = try hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
    const alice_pk = try hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a");
    const bob_sk = try hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
    const bob_pk = try hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
    const shared = try hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742");

    var got_alice_pk: [32]u8 = undefined;
    scalarmultBase(&got_alice_pk, &alice_sk);
    try std.testing.expectEqualSlices(u8, &alice_pk, &got_alice_pk);

    var got_bob_pk: [32]u8 = undefined;
    scalarmultBase(&got_bob_pk, &bob_sk);
    try std.testing.expectEqualSlices(u8, &bob_pk, &got_bob_pk);

    var s1: [32]u8 = undefined;
    var s2: [32]u8 = undefined;
    scalarmult(&s1, &alice_sk, &bob_pk);
    scalarmult(&s2, &bob_sk, &alice_pk);
    try std.testing.expectEqualSlices(u8, &shared, &s1);
    try std.testing.expectEqualSlices(u8, &shared, &s2);
}

test "x25519: RFC 7748 §5.2 iterative vectors (1 and 1000 iterations)" {
    const first = try hex("422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079");
    const thousandth = try hex("684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51");
    var k = basepoint;
    var u = basepoint;
    var i: usize = 1;
    while (i <= 1000) : (i += 1) {
        var res: [32]u8 = undefined;
        scalarmult(&res, &k, &u);
        u = k;
        k = res;
        if (i == 1) try std.testing.expectEqualSlices(u8, &first, &res);
    }
    try std.testing.expectEqualSlices(u8, &thousandth, &k);
}

test "x25519: base point times clamped scalar is stable" {
    const sk = try hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    scalarmultBase(&a, &sk);
    scalarmultBase(&b, &sk);
    try std.testing.expectEqualSlices(u8, &a, &b);
}
