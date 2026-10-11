//! HMAC (RFC 2104) over SHA-256 and SHA-512 (M47 CP1, ADR 0023).
//!
//! Streaming, caller-buffered, no allocation. The key is normalized to the
//! hash block size (over-long keys are hashed first), then the ipad/opad
//! construction runs over the two hash contexts.
//!
//! Verified against RFC 4231 cases as class-A `zig test`.

const std = @import("std");
const sha256 = @import("sha256.zig");
const sha512 = @import("sha512.zig");
const sha384 = @import("sha384.zig");

pub const HmacSha256 = struct {
    inner: sha256.Sha256,
    opad: [sha256.block_len]u8,

    pub fn init(key: []const u8) HmacSha256 {
        var kblock = @as([sha256.block_len]u8, @splat(@as(u8, 0)));
        if (key.len > sha256.block_len) {
            var d: [sha256.digest_len]u8 = undefined;
            sha256.sha256(&d, key);
            @memcpy(kblock[0..sha256.digest_len], &d);
        } else {
            @memcpy(kblock[0..key.len], key);
        }
        var ipad: [sha256.block_len]u8 = undefined;
        var opad: [sha256.block_len]u8 = undefined;
        for (0..sha256.block_len) |i| {
            ipad[i] = kblock[i] ^ 0x36;
            opad[i] = kblock[i] ^ 0x5c;
        }
        var inner = sha256.Sha256.init();
        inner.update(&ipad);
        return .{ .inner = inner, .opad = opad };
    }

    pub fn update(self: *HmacSha256, bytes: []const u8) void {
        self.inner.update(bytes);
    }

    pub fn final(self: *HmacSha256, out: *[sha256.digest_len]u8) void {
        var inner_digest: [sha256.digest_len]u8 = undefined;
        self.inner.final(&inner_digest);
        var outer = sha256.Sha256.init();
        outer.update(&self.opad);
        outer.update(&inner_digest);
        outer.final(out);
    }
};

pub const HmacSha512 = struct {
    inner: sha512.Sha512,
    opad: [sha512.block_len]u8,

    pub fn init(key: []const u8) HmacSha512 {
        var kblock = @as([sha512.block_len]u8, @splat(@as(u8, 0)));
        if (key.len > sha512.block_len) {
            var d: [sha512.digest_len]u8 = undefined;
            sha512.sha512(&d, key);
            @memcpy(kblock[0..sha512.digest_len], &d);
        } else {
            @memcpy(kblock[0..key.len], key);
        }
        var ipad: [sha512.block_len]u8 = undefined;
        var opad: [sha512.block_len]u8 = undefined;
        for (0..sha512.block_len) |i| {
            ipad[i] = kblock[i] ^ 0x36;
            opad[i] = kblock[i] ^ 0x5c;
        }
        var inner = sha512.Sha512.init();
        inner.update(&ipad);
        return .{ .inner = inner, .opad = opad };
    }

    pub fn update(self: *HmacSha512, bytes: []const u8) void {
        self.inner.update(bytes);
    }

    pub fn final(self: *HmacSha512, out: *[sha512.digest_len]u8) void {
        var inner_digest: [sha512.digest_len]u8 = undefined;
        self.inner.final(&inner_digest);
        var outer = sha512.Sha512.init();
        outer.update(&self.opad);
        outer.update(&inner_digest);
        outer.final(out);
    }
};

/// HMAC-SHA384 (RFC 2104 over FIPS 180-4 SHA-384). TLS 1.3's SHA-384
/// cipher suites (`TLS_AES_256_GCM_SHA384`, `TLS_CHACHA20_POLY1305_SHA256`
/// with a SHA-384 transcript) need it; the block size is SHA-512's.
pub const HmacSha384 = struct {
    inner: sha384.Sha384,
    opad: [sha384.block_len]u8,

    pub fn init(key: []const u8) HmacSha384 {
        var kblock = @as([sha384.block_len]u8, @splat(@as(u8, 0)));
        if (key.len > sha384.block_len) {
            var d: [sha384.digest_len]u8 = undefined;
            sha384.sha384(&d, key);
            @memcpy(kblock[0..sha384.digest_len], &d);
        } else {
            @memcpy(kblock[0..key.len], key);
        }
        var ipad: [sha384.block_len]u8 = undefined;
        var opad: [sha384.block_len]u8 = undefined;
        for (0..sha384.block_len) |i| {
            ipad[i] = kblock[i] ^ 0x36;
            opad[i] = kblock[i] ^ 0x5c;
        }
        var inner = sha384.Sha384.init();
        inner.update(&ipad);
        return .{ .inner = inner, .opad = opad };
    }

    pub fn update(self: *HmacSha384, bytes: []const u8) void {
        self.inner.update(bytes);
    }

    pub fn final(self: *HmacSha384, out: *[sha384.digest_len]u8) void {
        var inner_digest: [sha384.digest_len]u8 = undefined;
        self.inner.final(&inner_digest);
        var outer = sha384.Sha384.init();
        outer.update(&self.opad);
        outer.update(&inner_digest);
        outer.final(out);
    }
};

/// One-shot HMAC-SHA256.
pub fn hmacSha256(out: *[sha256.digest_len]u8, key: []const u8, msg: []const u8) void {
    var h = HmacSha256.init(key);
    h.update(msg);
    h.final(out);
}

/// One-shot HMAC-SHA512.
pub fn hmacSha512(out: *[sha512.digest_len]u8, key: []const u8, msg: []const u8) void {
    var h = HmacSha512.init(key);
    h.update(msg);
    h.final(out);
}

/// One-shot HMAC-SHA384.
pub fn hmacSha384(out: *[sha384.digest_len]u8, key: []const u8, msg: []const u8) void {
    var h = HmacSha384.init(key);
    h.update(msg);
    h.final(out);
}

test "hmac-sha256: RFC 4231 case 1" {
    const key = @as([20]u8, @splat(@as(u8, 0x0b)));
    var out: [32]u8 = undefined;
    hmacSha256(&out, &key, "Hi There");
    const exp = try hex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "hmac-sha256: RFC 4231 case 2" {
    var out: [32]u8 = undefined;
    hmacSha256(&out, "Jefe", "what do ya want for nothing?");
    const exp = try hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "hmac-sha256: RFC 4231 case 3" {
    const key = @as([20]u8, @splat(@as(u8, 0xaa)));
    const data = @as([50]u8, @splat(@as(u8, 0xdd)));
    var out: [32]u8 = undefined;
    hmacSha256(&out, &key, &data);
    const exp = try hex("773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "hmac-sha256: RFC 4231 case 4 (25-byte key, 50-byte data)" {
    var key: [25]u8 = undefined;
    for (0..25) |i| key[i] = @intCast(i + 1);
    const data = @as([50]u8, @splat(@as(u8, 0xcd)));
    var out: [32]u8 = undefined;
    hmacSha256(&out, &key, &data);
    const exp = try hex("82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "hmac-sha256: RFC 4231 case 6 (131-byte key)" {
    const key = @as([131]u8, @splat(@as(u8, 0xaa)));
    var out: [32]u8 = undefined;
    hmacSha256(&out, &key, "Test Using Larger Than Block-Size Key - Hash Key First");
    const exp = try hex("60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "hmac-sha256: RFC 4231 case 7 (131-byte key and data)" {
    const key = @as([131]u8, @splat(@as(u8, 0xaa)));
    const data = "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm.";
    var out: [32]u8 = undefined;
    hmacSha256(&out, &key, data);
    const exp = try hex("9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "hmac-sha256: streaming in chunks equals one-shot" {
    const key = @as([20]u8, @splat(@as(u8, 0x0b)));
    const msg = "Hi There";
    var one: [32]u8 = undefined;
    hmacSha256(&one, &key, msg);
    var h = HmacSha256.init(&key);
    for (msg) |*b| h.update(std.mem.asBytes(b));
    var got: [32]u8 = undefined;
    h.final(&got);
    try std.testing.expectEqualSlices(u8, &one, &got);
}

test "hmac-sha512: RFC 4231 case 1" {
    const key = @as([20]u8, @splat(@as(u8, 0x0b)));
    var out: [64]u8 = undefined;
    hmacSha512(&out, &key, "Hi There");
    const exp = try hex("87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "hmac-sha512: RFC 4231 case 2" {
    var out: [64]u8 = undefined;
    hmacSha512(&out, "Jefe", "what do ya want for nothing?");
    const exp = try hex("164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "hmac-sha512: RFC 4231 case 6 (131-byte key)" {
    const key = @as([131]u8, @splat(@as(u8, 0xaa)));
    var out: [64]u8 = undefined;
    hmacSha512(&out, &key, "Test Using Larger Than Block-Size Key - Hash Key First");
    const exp = try hex("80b24263c7c1a3ebb71493c1dd7be8b49b46d1f41b4aeec1121b013783f8f3526b56d037e05f2598bd0fd2215d6a1e5295e64f73f63f0aec8b915a985d786598");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

fn hex(comptime s: []const u8) ![s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return error.BadHex;
    return out;
}
