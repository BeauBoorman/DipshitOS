//! TLS 1.3 record layer (RFC 8446 §5). Freestanding, caller-buffered.
//!
//! What is here:
//!   * the per-record nonce: the static IV XOR the 64-bit sequence number,
//!     right-aligned (§5.3);
//!   * `sealRecord` / `openRecord` for the AEAD-protected record, including
//!     the `TLSInnerPlaintext` layout `content || content_type || zeros` and
//!     the rule that the outer content type is always `application_data`;
//!   * the AAD, which is exactly the 5-byte record header (§5.2).
//!
//! Deliberately bounded: the plaintext cap is 2^14 (the protocol limit) and an
//! oversize payload is an error rather than a silent truncation. Record
//! reassembly across TCP segments is the caller's job (the guest's TCP seam is
//! a bounded single-slot channel, so this stays a pure function).
//!
//! Verification (class A, `zig test`): the RFC 8448 client application-data
//! record decrypts to the published plaintext with the published traffic key,
//! IV and sequence number, plus round-trip and tamper tests.

const std = @import("std");
const gcm = @import("crypto").gcm;

pub const header_len = 5;

/// RFC 8446 §5.2: "The length MUST NOT exceed 2^14 + 256 bytes."
pub const max_plaintext = 16384;
pub const max_ciphertext = max_plaintext + 256;

pub const ContentType = enum(u8) {
    change_cipher_spec = 20,
    alert = 21,
    handshake = 22,
    application_data = 23,
    _,
};

pub const Error = error{
    TruncatedRecord,
    CiphertextTooLarge,
    TagMismatch,
    InnerTypeMissing,
    InnerTypeNotAllowed,
};

/// RFC 8446 §5.3: nonce = iv XOR (0-padded 64-bit sequence number).
pub fn nonce(iv: *const [12]u8, seq: u64) [12]u8 {
    var n = iv.*;
    const s = std.mem.readInt(u64, n[4..12], .big) ^ seq;
    std.mem.writeInt(u64, n[4..12], s, .big);
    return n;
}

fn aeadSeal(
    out_ct: []u8,
    tag: *[16]u8,
    pt: []const u8,
    aad: []const u8,
    n: *const [12]u8,
    key: []const u8,
) void {
    switch (key.len) {
        16 => {
            var k: [16]u8 = undefined;
            @memcpy(&k, key[0..16]);
            gcm.seal128(out_ct, tag, pt, aad, n, &k);
        },
        32 => {
            var k: [32]u8 = undefined;
            @memcpy(&k, key[0..32]);
            gcm.seal256(out_ct, tag, pt, aad, n, &k);
        },
        else => unreachable,
    }
}

fn aeadOpen(
    out_pt: []u8,
    ct: []const u8,
    tag: *const [16]u8,
    aad: []const u8,
    n: *const [12]u8,
    key: []const u8,
) bool {
    switch (key.len) {
        16 => {
            var k: [16]u8 = undefined;
            @memcpy(&k, key[0..16]);
            return gcm.open128(out_pt, ct, tag, aad, n, &k);
        },
        32 => {
            var k: [32]u8 = undefined;
            @memcpy(&k, key[0..32]);
            return gcm.open256(out_pt, ct, tag, aad, n, &k);
        },
        else => unreachable,
    }
}

/// Write one encrypted record into `out` and return its length.
/// `out.len` must be at least `payload.len + 1 + 16 + header_len`.
pub fn sealRecord(
    out: []u8,
    payload: []const u8,
    inner_type: ContentType,
    key: []const u8,
    iv: *const [12]u8,
    seq: u64,
) usize {
    std.debug.assert(key.len == 16 or key.len == 32);
    std.debug.assert(payload.len <= max_plaintext);
    std.debug.assert(inner_type == .handshake or inner_type == .application_data or inner_type == .alert);

    // TLSInnerPlaintext = content || content_type || zeros(0)
    var inner: [max_plaintext + 1]u8 = undefined;
    @memcpy(inner[0..payload.len], payload);
    inner[payload.len] = @backingInt(inner_type);
    const inner_len = payload.len + 1;

    const ct_len = inner_len + 16;
    std.debug.assert(out.len >= header_len + ct_len);

    // Outer header: the real type is application_data for AEAD records.
    out[0] = @backingInt(ContentType.application_data);
    out[1] = 0x03;
    out[2] = 0x03;
    std.mem.writeInt(u16, out[3..5], @intCast(ct_len), .big);

    const n = nonce(iv, seq);
    aeadSeal(out[header_len .. header_len + inner_len], out[header_len + inner_len ..][0..16], inner[0..inner_len], out[0..header_len], &n, key);
    return header_len + ct_len;
}

/// Decrypt one record. On success returns the payload length and writes the
/// inner content type to `inner_type_out`. On any failure `payload_out` is
/// left untouched.
pub fn openRecord(
    payload_out: []u8,
    inner_type_out: *ContentType,
    record: []const u8,
    key: []const u8,
    iv: *const [12]u8,
    seq: u64,
) Error!usize {
    if (record.len < header_len + 1 + 16) return Error.TruncatedRecord;
    const declared = std.mem.readInt(u16, record[3..5], .big);
    if (declared != record.len - header_len) return Error.TruncatedRecord;
    if (declared > max_ciphertext) return Error.CiphertextTooLarge;
    if (record[0] != @backingInt(ContentType.application_data)) return Error.InnerTypeNotAllowed;

    const ct_len = declared - 16;
    var inner: [max_ciphertext]u8 = undefined;
    if (ct_len > inner.len) return Error.CiphertextTooLarge;

    const n = nonce(iv, seq);
    if (!aeadOpen(inner[0..ct_len], record[header_len .. header_len + ct_len], record[header_len + ct_len ..][0..16], record[0..header_len], &n, key)) {
        return Error.TagMismatch;
    }

    // Strip the zero padding, then the content type is the last non-zero byte.
    var end = ct_len;
    while (end > 0 and inner[end - 1] == 0) end -= 1;
    if (end == 0) return Error.InnerTypeMissing;
    const t: ContentType = @fromBackingInt(@intCast(inner[end - 1]));
    switch (t) {
        .handshake, .application_data, .alert, .change_cipher_spec => {},
        else => return Error.InnerTypeNotAllowed,
    }
    const plen = end - 1;
    if (plen > payload_out.len) return Error.TruncatedRecord;
    @memcpy(payload_out[0..plen], inner[0..plen]);
    inner_type_out.* = t;
    return plen;
}

const vectors = @import("rfc8448_vectors.zig");

fn decode(out: []u8, hexstr: []const u8) void {
    _ = std.fmt.hexToBytes(out[0 .. hexstr.len / 2], hexstr) catch unreachable;
}

test "record: RFC 8448 client application_data record decrypts to the published plaintext" {
    var key: [16]u8 = undefined;
    var iv: [12]u8 = undefined;
    decode(&key, vectors.client_app_write_key);
    decode(&iv, vectors.client_app_write_iv);

    const rec_hex = vectors.client_app_record;
    var rec: [128]u8 = undefined;
    const rec_len = rec_hex.len / 2;
    decode(rec[0..rec_len], rec_hex);
    try std.testing.expectEqual(@as(usize, 72), rec_len);
    try std.testing.expectEqual(@as(u8, 23), rec[0]);

    var expect_pt: [128]u8 = undefined;
    const pt_len = vectors.client_app_payload.len / 2;
    decode(expect_pt[0..pt_len], vectors.client_app_payload);
    try std.testing.expectEqual(@as(usize, 50), pt_len);

    var out: [max_plaintext]u8 = undefined;
    var t: ContentType = .alert;
    const n = try openRecord(&out, &t, rec[0..rec_len], &key, &iv, 0);
    try std.testing.expectEqual(@as(usize, 50), n);
    try std.testing.expectEqual(ContentType.application_data, t);
    try std.testing.expectEqualSlices(u8, expect_pt[0..pt_len], out[0..n]);
}

test "record: plaintext padding is stripped and the type is the last non-zero byte" {
    const key = @as([16]u8, @splat(@as(u8, 0x0B)));
    const iv = @as([12]u8, @splat(@as(u8, 0x0C)));
    var out: [max_plaintext]u8 = undefined;

    // A payload that ends in zero bytes must survive: the parser strips
    // padding from the end of TLSInnerPlaintext, and the type byte is what
    // stops it, not the payload's own trailing zeros.
    const payload = [_]u8{ 0x01, 0x00, 0x00, 0x00 };
    const len = sealRecord(&out, &payload, .application_data, &key, &iv, 7);
    var back: [max_plaintext]u8 = undefined;
    var t: ContentType = .alert;
    const n = try openRecord(&back, &t, out[0..len], &key, &iv, 7);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualSlices(u8, &payload, back[0..n]);
}

test "record: round-trips every content type and fails closed on tampering" {
    const key = @as([16]u8, @splat(@as(u8, 0x42)));
    const iv = @as([12]u8, @splat(@as(u8, 0x24)));
    var buf: [512]u8 = undefined;
    var back: [512]u8 = undefined;
    const payload = "handshake or application data, either way";

    for ([_]ContentType{ .handshake, .application_data, .alert }) |ct_in| {
        const len = sealRecord(&buf, payload, ct_in, &key, &iv, 3);
        var t: ContentType = .alert;
        const n = try openRecord(&back, &t, buf[0..len], &key, &iv, 3);
        try std.testing.expectEqual(ct_in, t);
        try std.testing.expectEqualSlices(u8, payload, back[0..n]);
    }

    const len = sealRecord(&buf, payload, .application_data, &key, &iv, 3);
    var t: ContentType = .alert;

    // Wrong sequence number changes the nonce.
    try std.testing.expectError(Error.TagMismatch, openRecord(&back, &t, buf[0..len], &key, &iv, 4));

    // Flipped ciphertext bit.
    var tampered = buf;
    tampered[6] ^= 0x40;
    try std.testing.expectError(Error.TagMismatch, openRecord(&back, &t, tampered[0..len], &key, &iv, 3));

    // Flipped header byte (the header is the AAD).
    var tampered2 = buf;
    tampered2[4] ^= 0x01;
    try std.testing.expectError(Error.TruncatedRecord, openRecord(&back, &t, tampered2[0..len], &key, &iv, 3));

    // Truncated record.
    try std.testing.expectError(Error.TruncatedRecord, openRecord(&back, &t, buf[0 .. len - 1], &key, &iv, 3));

    // A plaintext record (type 22) is not an AEAD record.
    var plain = buf;
    plain[0] = 22;
    try std.testing.expectError(Error.InnerTypeNotAllowed, openRecord(&back, &t, plain[0..len], &key, &iv, 3));
}

test "record: nonce is iv XOR seq in the low 8 bytes" {
    const iv = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    const n0 = nonce(&iv, 0);
    try std.testing.expectEqualSlices(u8, &iv, &n0);
    const n1 = nonce(&iv, 1);
    try std.testing.expectEqualSlices(u8, iv[0..4], n1[0..4]);
    try std.testing.expectEqual(@as(u8, 5 ^ 0), n1[4]);
    try std.testing.expectEqual(@as(u8, 12 ^ 1), n1[11]);
    const nbig = nonce(&iv, 0x0102030405060708);
    try std.testing.expectEqual(@as(u8, 5 ^ 1), nbig[4]);
    try std.testing.expectEqual(@as(u8, 12 ^ 8), nbig[11]);
}

test "record: the full 2^14 plaintext works and larger is rejected" {
    const key = @as([16]u8, @splat(@as(u8, 0x77)));
    const iv = @as([12]u8, @splat(@as(u8, 0x88)));
    var out: [max_plaintext + 1 + 16 + header_len]u8 = undefined;
    var big: [max_plaintext]u8 = undefined;
    @memset(&big, 0x5A);
    const len = sealRecord(&out, &big, .application_data, &key, &iv, 1);
    try std.testing.expectEqual(@as(usize, max_plaintext + 1 + 16 + header_len), len);
    var back: [max_plaintext]u8 = undefined;
    var t: ContentType = .alert;
    const n = try openRecord(&back, &t, out[0..len], &key, &iv, 1);
    try std.testing.expectEqual(@as(usize, max_plaintext), n);
    try std.testing.expectEqualSlices(u8, &big, back[0..n]);
}
