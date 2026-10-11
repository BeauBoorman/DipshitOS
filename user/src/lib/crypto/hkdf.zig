//! HKDF (RFC 5869) — extract-and-expand, generic over the SHA-2 HMACs in
//! `hmac.zig`. TLS 1.3's key schedule (RFC 8446 §7.1) is HKDF with SHA-256
//! or SHA-384 p; `user/src/lib/tls/keyschedule.zig` adds `HKDF-Expand-Label`
//! and `Derive-Secret` on top of this module.
//!
//! Fixed capacity, no allocation: `expand` accepts at most `255 * HashLen`
//! bytes (RFC 5869 §2.3) and asserts rather than silently truncating. The
//! caller owns every buffer.
//!
//! Verification (class A, `zig test`):
//!   * RFC 5869 Appendix A test cases 1, 2 and 3 (SHA-256), transcribed from
//!     the fetched RFC text (sha256 of the fetched file:
//!     7a40eb3835b35fc947eb12a2ed614db079d43b26e50dbc537c31fba16397089c).
//!   * SHA-384 and SHA-512 cases generated with Python 3.14.7
//!     `hmac`/`hashlib` (OpenSSL 3.6.4) using the same IKMs/salts/infos as
//!     the RFC cases. The generator reproduced the RFC's SHA-256 answers
//!     exactly, which is the check that it is trustworthy.

const std = @import("std");
const hmac = @import("hmac.zig");

pub fn Hkdf(comptime Hmac: type, comptime hash_len: usize) type {
    return struct {
        /// RFC 5869 §2.3: OKM is at most 255 * HashLen octets.
        pub const out_len_max = 255 * hash_len;

        /// HKDF-Extract(salt, IKM) -> PRK (RFC 5869 §2.2).
        /// An empty `salt` is equivalent to HashLen zero octets, which is
        /// exactly what HMAC does with an all-zero key block.
        pub fn extract(prk: *[hash_len]u8, salt: []const u8, ikm: []const u8) void {
            var h = Hmac.init(salt);
            h.update(ikm);
            h.final(prk);
        }

        /// HKDF-Expand(PRK, info, L) -> OKM (RFC 5869 §2.3).
        pub fn expand(okm: []u8, prk: *const [hash_len]u8, info: []const u8) void {
            std.debug.assert(okm.len <= out_len_max);
            var t: [hash_len]u8 = undefined;
            var t_len: usize = 0;
            var counter: u8 = 1;
            var off: usize = 0;
            while (off < okm.len) : (counter += 1) {
                var h = Hmac.init(prk);
                if (t_len != 0) h.update(t[0..t_len]);
                h.update(info);
                h.update(&[1]u8{counter});
                h.final(&t);
                t_len = hash_len;
                const take = @min(hash_len, okm.len - off);
                @memcpy(okm[off..][0..take], t[0..take]);
                off += take;
            }
        }

        /// One-shot extract-then-expand (RFC 5869 §2).
        pub fn extractExpand(okm: []u8, salt: []const u8, ikm: []const u8, info: []const u8) void {
            var prk: [hash_len]u8 = undefined;
            extract(&prk, salt, ikm);
            expand(okm, &prk, info);
        }
    };
}

pub const Sha256 = Hkdf(hmac.HmacSha256, 32);
pub const Sha384 = Hkdf(hmac.HmacSha384, 48);
pub const Sha512 = Hkdf(hmac.HmacSha512, 64);

fn hex(comptime s: []const u8) ![s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return error.BadHex;
    return out;
}

// ---------------------------------------------------------------------------
// RFC 5869 Appendix A cases 1-3 (SHA-256), verbatim from the RFC.
// ---------------------------------------------------------------------------

test "hkdf/256: RFC 5869 A.1 basic" {
    const ikm = try hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
    const salt = try hex("000102030405060708090a0b0c");
    const info = try hex("f0f1f2f3f4f5f6f7f8f9");
    var prk: [32]u8 = undefined;
    Sha256.extract(&prk, &salt, &ikm);
    try std.testing.expectEqualSlices(u8, &(try hex("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")), &prk);
    var okm: [42]u8 = undefined;
    Sha256.expand(&okm, &prk, &info);
    try std.testing.expectEqualSlices(u8, &(try hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")), &okm);
}

test "hkdf/256: RFC 5869 A.2 longer inputs/outputs (L=82, multi-block)" {
    var ikm: [80]u8 = undefined;
    var salt: [80]u8 = undefined;
    var info: [80]u8 = undefined;
    for (0..80) |i| {
        ikm[i] = @intCast(i);
        salt[i] = @intCast(0x60 + i);
        info[i] = @intCast(0xb0 +% i);
    }
    var prk: [32]u8 = undefined;
    Sha256.extract(&prk, &salt, &ikm);
    try std.testing.expectEqualSlices(u8, &(try hex("06a6b88c5853361a06104c9ceb35b45cef760014904671014a193f40c15fc244")), &prk);
    var okm: [82]u8 = undefined;
    Sha256.expand(&okm, &prk, &info);
    try std.testing.expectEqualSlices(u8, &(try hex("b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87")), &okm);
}

test "hkdf/256: RFC 5869 A.3 zero-length salt and info" {
    const ikm = try hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
    var prk: [32]u8 = undefined;
    Sha256.extract(&prk, "", &ikm);
    try std.testing.expectEqualSlices(u8, &(try hex("19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04")), &prk);
    var okm: [42]u8 = undefined;
    Sha256.expand(&okm, &prk, "");
    try std.testing.expectEqualSlices(u8, &(try hex("8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")), &okm);
}

// ---------------------------------------------------------------------------
// SHA-384 / SHA-512 cases (Python hmac+hashlib, OpenSSL 3.6.4).
// ---------------------------------------------------------------------------

test "hkdf/384: basic, long and empty (generated)" {
    const ikm = try hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
    const salt = try hex("000102030405060708090a0b0c");
    const info = try hex("f0f1f2f3f4f5f6f7f8f9");
    var prk: [48]u8 = undefined;
    Sha384.extract(&prk, &salt, &ikm);
    try std.testing.expectEqualSlices(u8, &(try hex("704b39990779ce1dc548052c7dc39f303570dd13fb39f7acc564680bef80e8dec70ee9a7e1f3e293ef68eceb072a5ade")), &prk);
    var okm: [42]u8 = undefined;
    Sha384.expand(&okm, &prk, &info);
    try std.testing.expectEqualSlices(u8, &(try hex("9b5097a86038b805309076a44b3a9f38063e25b516dcbf369f394cfab43685f748b6457763e4f0204fc5")), &okm);

    var ikm2: [80]u8 = undefined;
    var salt2: [80]u8 = undefined;
    var info2: [80]u8 = undefined;
    for (0..80) |i| {
        ikm2[i] = @intCast(i);
        salt2[i] = @intCast(0x60 + i);
        info2[i] = @intCast(0xb0 +% i);
    }
    var prk2: [48]u8 = undefined;
    Sha384.extract(&prk2, &salt2, &ikm2);
    try std.testing.expectEqualSlices(u8, &(try hex("b319f6831dff9314efb643baa29263b30e4a8d779fe31e9c901efd7de737c85b62e676d4dc87b0895c6a7dc97b52cebb")), &prk2);
    var okm2: [82]u8 = undefined;
    Sha384.expand(&okm2, &prk2, &info2);
    try std.testing.expectEqualSlices(u8, &(try hex("484ca052b8cc724fd1c4ec64d57b4e818c7e25a8e0f4569ed72a6a05fe0649eebf69f8d5c832856bf4e4fbc17967d54975324a94987f7f41835817d8994fdbd6f4c09c5500dca24a56222fea53d8967a8b2e")), &okm2);

    var prk3: [48]u8 = undefined;
    Sha384.extract(&prk3, "", &ikm);
    try std.testing.expectEqualSlices(u8, &(try hex("10e40cf072a4c5626e43dd22c1cf727d4bb140975c9ad0cbc8e45b40068f8f0ba57cdb598af9dfa6963a96899af047e5")), &prk3);
    var okm3: [42]u8 = undefined;
    Sha384.expand(&okm3, &prk3, "");
    try std.testing.expectEqualSlices(u8, &(try hex("c8c96e710f89b0d7990bca68bcdec8cf854062e54c73a7abc743fade9b242daacc1cea5670415b52849c")), &okm3);
}

test "hkdf/512: basic, long, empty and a 256-byte output (generated)" {
    const ikm = try hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
    const salt = try hex("000102030405060708090a0b0c");
    const info = try hex("f0f1f2f3f4f5f6f7f8f9");
    var prk: [64]u8 = undefined;
    Sha512.extract(&prk, &salt, &ikm);
    try std.testing.expectEqualSlices(u8, &(try hex("665799823737ded04a88e47e54a5890bb2c3d247c7a4254a8e61350723590a26c36238127d8661b88cf80ef802d57e2f7cebcf1e00e083848be19929c61b4237")), &prk);
    var okm: [42]u8 = undefined;
    Sha512.expand(&okm, &prk, &info);
    try std.testing.expectEqualSlices(u8, &(try hex("832390086cda71fb47625bb5ceb168e4c8e26a1a16ed34d9fc7fe92c1481579338da362cb8d9f925d7cb")), &okm);

    var prk2: [64]u8 = undefined;
    Sha512.extract(&prk2, "", &ikm);
    try std.testing.expectEqualSlices(u8, &(try hex("fd200c4987ac491313bd4a2a13287121247239e11c9ef82802044b66ef357e5b194498d0682611382348572a7b1611de54764094286320578a863f36562b0df6")), &prk2);
    var okm2: [42]u8 = undefined;
    Sha512.expand(&okm2, &prk2, "");
    try std.testing.expectEqualSlices(u8, &(try hex("f5fa02b18298a72a8c23898a8703472c6eb179dc204c03425c970e3b164bf90fff22d04836d0e2343bac")), &okm2);

    // 256 bytes exceeds one hash block: exercises the counter loop end to end.
    const ikm3 = @as([64]u8, @splat(@as(u8, 'a')));
    var prk3: [64]u8 = undefined;
    Sha512.extract(&prk3, "salt", &ikm3);
    try std.testing.expectEqualSlices(u8, &(try hex("1e8649236bc71a06f0166c7a1b253473f0d48e8a43244751f8ad37870d4e47c0b67555dc34dccd3168c4f4ee2c59b9434b8340edd0897cc70a8bc969c88a8308")), &prk3);
    var okm3: [256]u8 = undefined;
    Sha512.expand(&okm3, &prk3, "info");
    try std.testing.expectEqualSlices(u8, &(try hex("3d164754266db438940c43552a63182795af2ad1807403c06f8a704bbf33e9950d2c7e6031ebd367a1594a64dd1b0c3670710d5992a5b50330f59c3da5821b49e4c9ed3f060bcf10bb60cbad50a48a64d801a6cb475623e943cc01613b5cd2e961e9a25fd731f8f76b352ec3b7afbed47d4429cd9e135d79430d664a3b293f0b44a40cfc42d5328249651cb0e9e466cbdae06b6d97c95dc938a48082d0a1c1b01540ca8bca16c647c3caa65e3eebcae031d25307b02d443e802487fbdafb558661bccea747d35ba51029f449a764d8fb3027c09a5f2fe3fd2c921faaae2f11a387106510fc3549bac48ce83c7d23d9c0c18363e890ba7b5af27639524b2d0628")), &okm3);
}

test "hkdf: extract-then-expand equals the two-step form" {
    var a: [64]u8 = undefined;
    Sha256.extractExpand(&a, "salt", "ikm", "info");
    var prk: [32]u8 = undefined;
    Sha256.extract(&prk, "salt", "ikm");
    var b: [64]u8 = undefined;
    Sha256.expand(&b, &prk, "info");
    try std.testing.expectEqualSlices(u8, &a, &b);
}
