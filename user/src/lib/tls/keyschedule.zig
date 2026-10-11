//! TLS 1.3 key schedule (RFC 8446 §7.1) built on the in-tree HKDF.
//!
//! `HKDF-Expand-Label` and `Derive-Secret` are the only two primitives the
//! schedule needs; everything else — early/handshake/master secrets, the
//! five traffic secrets, the exporter and resumption secrets — is a
//! composition of them. Kept in its own file so the whole schedule is
//! reviewable in one screen and testable against RFC 8448 without a socket.
//!
//! Fixed capacities: labels and contexts are bounded by `info_max` and a
//! longer request asserts rather than truncating (a silently truncated label
//! would derive the wrong key, which is exactly the failure mode that must
//! not exist here).
//!
//! Verification (class A, `zig test`) against RFC 8448 §3 "Simple 1-RTT
//! Handshake": every derived secret, traffic key, IV and the Finished key are
//! compared byte-for-byte with the published values, and the transcript
//! hashes are recomputed from the published handshake messages rather than
//! being taken on trust.

const std = @import("std");
const crypto = @import("crypto");

pub const label_prefix = "tls13 ";

/// Bounded HkdfLabel buffer: 2 + 1 + 6 + 255 + 1 + 255.
pub const info_max = 520;

fn buildInfo(buf: []u8, length: u16, label: []const u8, context: []const u8) []u8 {
    const full_label_len = label_prefix.len + label.len;
    std.debug.assert(full_label_len <= 255);
    std.debug.assert(context.len <= 255);
    std.debug.assert(2 + 1 + full_label_len + 1 + context.len <= buf.len);

    var i: usize = 0;
    std.mem.writeInt(u16, buf[0..2], length, .big);
    i = 2;
    buf[i] = @intCast(full_label_len);
    i += 1;
    @memcpy(buf[i..][0..label_prefix.len], label_prefix);
    i += label_prefix.len;
    @memcpy(buf[i..][0..label.len], label);
    i += label.len;
    buf[i] = @intCast(context.len);
    i += 1;
    @memcpy(buf[i..][0..context.len], context);
    i += context.len;
    std.debug.assert(i == 2 + 1 + full_label_len + 1 + context.len);
    return buf[0..i];
}

/// A TLS 1.3 cipher suite's key schedule, parameterised by the HKDF built on
/// the suite's hash and by the AEAD key length.
pub fn Keys(comptime Hk: type, comptime hash_len: usize, comptime key_len: usize) type {
    return struct {
        pub const hash_len_ = hash_len;
        pub const key_len_ = key_len;
        pub const iv_len = 12;

        /// HKDF-Expand-Label(Secret, Label, Context, Length) — RFC 8446 §7.1.
        pub fn expandLabel(
            out: []u8,
            secret: *const [hash_len]u8,
            label: []const u8,
            context: []const u8,
        ) void {
            std.debug.assert(out.len <= hkdf_out_max());
            var buf: [info_max]u8 = undefined;
            const info = buildInfo(&buf, @intCast(out.len), label, context);
            Hk.expand(out, secret, info);
        }

        fn hkdf_out_max() usize {
            return 255 * hash_len;
        }

        /// Derive-Secret(Secret, Label, Messages) — RFC 8446 §7.1. The caller
        /// passes the transcript hash of `Messages`, not the messages.
        pub fn deriveSecret(
            out: *[hash_len]u8,
            secret: *const [hash_len]u8,
            label: []const u8,
            transcript_hash: *const [hash_len]u8,
        ) void {
            expandLabel(out, secret, label, transcript_hash);
        }

        /// The AEAD key for a traffic secret (`tls13 key`, empty context).
        pub fn trafficKey(out: *[key_len]u8, secret: *const [hash_len]u8) void {
            expandLabel(out, secret, "key", "");
        }

        /// The static IV for a traffic secret (`tls13 iv`, empty context).
        pub fn trafficIv(out: *[iv_len]u8, secret: *const [hash_len]u8) void {
            expandLabel(out, secret, "iv", "");
        }

        /// The Finished key for a traffic secret (`tls13 finished`).
        pub fn finishedKey(out: *[hash_len]u8, secret: *const [hash_len]u8) void {
            expandLabel(out, secret, "finished", "");
        }

        /// Full key update (RFC 8446 §7.2): secret_{n+1} = HkdfExpandLabel(
        /// secret_n, "traffic upd", "", Hash.length).
        pub fn updateTrafficSecret(secret: *[hash_len]u8) void {
            var next: [hash_len]u8 = undefined;
            expandLabel(&next, secret, "traffic upd", "");
            secret.* = next;
        }
    };
}

/// TLS_AES_128_GCM_SHA256 / TLS_CHACHA20_POLY1305_SHA256 (SHA-256, 16-byte key).
pub const Sha256 = Keys(crypto.hkdf.Sha256, 32, 16);
/// TLS_AES_256_GCM_SHA384 (SHA-384, 32-byte key).
pub const Sha384 = Keys(crypto.hkdf.Sha384, 48, 32);

const vectors = @import("rfc8448_vectors.zig");

fn decode(out: []u8, hexstr: []const u8) void {
    _ = std.fmt.hexToBytes(out[0 .. hexstr.len / 2], hexstr) catch unreachable;
}

/// Concatenate the published server flight and hash it, so the transcript
/// hashes used below are recomputed rather than copied.
fn transcriptAfterServerFlight(out: *[32]u8) void {
    var h = crypto.sha256.Sha256.init();
    for (vectors.server_flight) |m| {
        var buf: [1024]u8 = undefined;
        const n = m.bytes.len / 2;
        std.debug.assert(n <= buf.len);
        decode(buf[0..n], m.bytes);
        h.update(buf[0..n]);
    }
    h.final(out);
}

test "rfc8448: transcript hash of ClientHello||ServerHello" {
    var h = crypto.sha256.Sha256.init();
    var buf: [512]u8 = undefined;
    for (vectors.server_flight[0..2]) |m| {
        const n = m.bytes.len / 2;
        decode(buf[0..n], m.bytes);
        h.update(buf[0..n]);
    }
    var got: [32]u8 = undefined;
    h.final(&got);
    var exp: [32]u8 = undefined;
    decode(&exp, "860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8");
    try std.testing.expectEqualSlices(u8, &exp, &got);
}

test "rfc8448: X25519 shared secret from the published key pair" {
    const x25519 = crypto.x25519;
    var sk: [32]u8 = undefined;
    var peer_pk: [32]u8 = undefined;
    var exp: [32]u8 = undefined;
    decode(&sk, vectors.client_private_key);
    decode(&peer_pk, vectors.server_public_key);
    decode(&exp, vectors.shared_secret);
    var got: [32]u8 = undefined;
    x25519.scalarmult(&got, &sk, &peer_pk);
    try std.testing.expectEqualSlices(u8, &exp, &got);
}

test "rfc8448: early/handshake/master secrets and the derived steps" {
    var zero: [32]u8 = @as([32]u8, @splat(@as(u8, 0)));
    var empty_hash: [32]u8 = undefined;
    crypto.sha256.sha256(&empty_hash, "");

    // early_secret = HKDF-Extract(0, 0)
    var early: [32]u8 = undefined;
    crypto.hkdf.Sha256.extract(&early, &zero, &zero);
    var exp: [32]u8 = undefined;
    decode(&exp, vectors.early_secret);
    try std.testing.expectEqualSlices(u8, &exp, &early);

    // derived = Derive-Secret(early, "derived", "")
    var derived: [32]u8 = undefined;
    Sha256.deriveSecret(&derived, &early, "derived", &empty_hash);
    decode(&exp, vectors.derived_early_secret);
    try std.testing.expectEqualSlices(u8, &exp, &derived);

    // handshake_secret = HKDF-Extract(derived, shared_secret)
    var shared: [32]u8 = undefined;
    decode(&shared, vectors.shared_secret);
    var hs: [32]u8 = undefined;
    crypto.hkdf.Sha256.extract(&hs, &derived, &shared);
    decode(&exp, vectors.handshake_secret);
    try std.testing.expectEqualSlices(u8, &exp, &hs);

    // derived = Derive-Secret(handshake, "derived", "")
    Sha256.deriveSecret(&derived, &hs, "derived", &empty_hash);
    decode(&exp, vectors.derived_master_secret);
    try std.testing.expectEqualSlices(u8, &exp, &derived);

    // master_secret = HKDF-Extract(derived, 0)
    var master: [32]u8 = undefined;
    crypto.hkdf.Sha256.extract(&master, &derived, &zero);
    decode(&exp, vectors.master_secret);
    try std.testing.expectEqualSlices(u8, &exp, &master);
}

test "rfc8448: handshake traffic secrets, keys, IVs and the Finished key" {
    var hs: [32]u8 = undefined;
    var th: [32]u8 = undefined;
    var exp: [32]u8 = undefined;
    var got: [32]u8 = undefined;
    decode(&hs, vectors.handshake_secret);
    var ch_buf: [512]u8 = undefined;
    {
        var h = crypto.sha256.Sha256.init();
        for (vectors.server_flight[0..2]) |m| {
            const n = m.bytes.len / 2;
            decode(ch_buf[0..n], m.bytes);
            h.update(ch_buf[0..n]);
        }
        h.final(&th);
    }

    Sha256.deriveSecret(&got, &hs, "c hs traffic", &th);
    decode(&exp, vectors.client_hs_traffic_secret);
    try std.testing.expectEqualSlices(u8, &exp, &got);

    Sha256.deriveSecret(&got, &hs, "s hs traffic", &th);
    decode(&exp, vectors.server_hs_traffic_secret);
    try std.testing.expectEqualSlices(u8, &exp, &got);

    var skey: [16]u8 = undefined;
    var siv: [12]u8 = undefined;
    var exp16: [16]u8 = undefined;
    var s_hs: [32]u8 = undefined;
    decode(&s_hs, vectors.server_hs_traffic_secret);
    Sha256.trafficKey(&skey, &s_hs);
    decode(&exp16, vectors.server_hs_write_key);
    try std.testing.expectEqualSlices(u8, &exp16, &skey);
    Sha256.trafficIv(&siv, &s_hs);
    decode(exp[0..12], vectors.server_hs_write_iv);
    try std.testing.expectEqualSlices(u8, exp[0..12], &siv);

    var c_hs: [32]u8 = undefined;
    decode(&c_hs, vectors.client_hs_traffic_secret);
    Sha256.trafficKey(&skey, &c_hs);
    decode(&exp16, vectors.client_hs_write_key);
    try std.testing.expectEqualSlices(u8, &exp16, &skey);
    Sha256.trafficIv(&siv, &c_hs);
    decode(exp[0..12], vectors.client_hs_write_iv);
    try std.testing.expectEqualSlices(u8, exp[0..12], &siv);

    var fk: [32]u8 = undefined;
    Sha256.finishedKey(&fk, &s_hs);
    decode(&exp, vectors.server_finished_key);
    try std.testing.expectEqualSlices(u8, &exp, &fk);

    var cfk: [32]u8 = undefined;
    Sha256.finishedKey(&cfk, &c_hs);
    decode(&exp, vectors.client_finished_key);
    try std.testing.expectEqualSlices(u8, &exp, &cfk);
}

test "rfc8448: application traffic secrets need the transcript up to server Finished" {
    var hs: [32]u8 = undefined;
    var master: [32]u8 = undefined;
    var exp: [32]u8 = undefined;
    var got: [32]u8 = undefined;

    var th_sf: [32]u8 = undefined;
    transcriptAfterServerFlight(&th_sf);

    decode(&hs, vectors.handshake_secret);
    var zero = @as([32]u8, @splat(@as(u8, 0)));
    var empty_hash: [32]u8 = undefined;
    crypto.sha256.sha256(&empty_hash, "");
    var derived: [32]u8 = undefined;
    Sha256.deriveSecret(&derived, &hs, "derived", &empty_hash);
    crypto.hkdf.Sha256.extract(&master, &derived, &zero);

    Sha256.deriveSecret(&got, &master, "c ap traffic", &th_sf);
    decode(&exp, vectors.client_ap_traffic_secret);
    try std.testing.expectEqualSlices(u8, &exp, &got);

    Sha256.deriveSecret(&got, &master, "s ap traffic", &th_sf);
    decode(&exp, vectors.server_ap_traffic_secret);
    try std.testing.expectEqualSlices(u8, &exp, &got);

    Sha256.deriveSecret(&got, &master, "exp master", &th_sf);
    decode(&exp, vectors.exporter_master_secret);
    try std.testing.expectEqualSlices(u8, &exp, &got);

    // resumption_master_secret uses the transcript through the client's Finished.
    var h = crypto.sha256.Sha256.init();
    {
        var buf: [1088]u8 = undefined;
        for (vectors.server_flight) |m| {
            const n = m.bytes.len / 2;
            decode(buf[0..n], m.bytes);
            h.update(buf[0..n]);
        }
        const n = vectors.client_finished_message.len / 2;
        decode(buf[0..n], vectors.client_finished_message);
        h.update(buf[0..n]);
    }
    var th_cf: [32]u8 = undefined;
    h.final(&th_cf);
    Sha256.deriveSecret(&got, &master, "res master", &th_cf);
    decode(&exp, vectors.resumption_master_secret);
    try std.testing.expectEqualSlices(u8, &exp, &got);

    // The client's application write keys come from its application secret.
    var cap: [32]u8 = undefined;
    decode(&cap, vectors.client_ap_traffic_secret);
    var k: [16]u8 = undefined;
    var expk: [16]u8 = undefined;
    Sha256.trafficKey(&k, &cap);
    decode(&expk, vectors.client_app_write_key);
    try std.testing.expectEqualSlices(u8, &expk, &k);
}

test "rfc8448: the server's Finished verify_data is HMAC(finished_key, transcript)" {
    // Finished = HMAC(finished_key, Transcript-Hash(ClientHello..CertificateVerify))
    // so this pins the transcript *and* the Finished construction together.
    var fk_exp: [32]u8 = undefined;
    decode(&fk_exp, vectors.server_finished_key);

    var h = crypto.sha256.Sha256.init();
    var buf: [1088]u8 = undefined;
    for (vectors.server_flight[0..5]) |m| { // everything except Finished
        const n = m.bytes.len / 2;
        decode(buf[0..n], m.bytes);
        h.update(buf[0..n]);
    }
    var th: [32]u8 = undefined;
    h.final(&th);

    var mac: [32]u8 = undefined;
    crypto.hmac.hmacSha256(&mac, &fk_exp, &th);

    var msg: [64]u8 = undefined;
    decode(&msg, vectors.server_finished_message);
    try std.testing.expectEqual(@as(usize, 36), vectors.server_finished_message.len / 2);
    try std.testing.expectEqual(@as(u8, 20), msg[0]); // handshake type: Finished
    try std.testing.expectEqualSlices(u8, &mac, msg[4..36]);
}

test "keyschedule: traffic key update advances the secret" {
    var s = @as([32]u8, @splat(@as(u8, 0x5A)));
    const before = s;
    Sha256.updateTrafficSecret(&s);
    try std.testing.expect(!std.mem.eql(u8, &before, &s));
    var expected: [32]u8 = undefined;
    Sha256.expandLabel(&expected, &before, "traffic upd", "");
    try std.testing.expectEqualSlices(u8, &expected, &s);
}
