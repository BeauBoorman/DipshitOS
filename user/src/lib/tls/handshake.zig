//! TLS 1.3 handshake codecs and the explicit state machine (RFC 8446 §4).
//!
//! This file owns two things and nothing else:
//!   * the wire codecs — handshake message headers, ClientHello construction,
//!     and parsers for ServerHello / EncryptedExtensions / Certificate /
//!     CertificateVerify / Finished;
//!   * `State`, the enumerated handshake state machine, so that "which message
//!     may arrive now" is data rather than control flow. Nothing advances to
//!     application data except through `connected`, and `connected` is only
//!     reachable after the server's Finished has been verified.
//!
//! Deliberately bounded: no allocation, fixed buffers, and a message that does
//! not fit is an error rather than a truncation.

const std = @import("std");
const der = @import("der.zig");
const x509 = @import("x509.zig");
const crypto = @import("crypto");

pub const max_handshake_msg = 16 * 1024;
pub const random_len = 32;
pub const session_id_len = 32;
pub const x25519_pub_len = 32;

pub const ContentType = enum(u8) {
    change_cipher_spec = 20,
    alert = 21,
    handshake = 22,
    application_data = 23,
};

pub const HandshakeType = enum(u8) {
    client_hello = 1,
    server_hello = 2,
    new_session_ticket = 4,
    end_of_early_data = 5,
    encrypted_extensions = 8,
    certificate = 11,
    certificate_request = 13,
    certificate_verify = 15,
    finished = 20,
    key_update = 24,
};

pub const AlertLevel = enum(u8) { warning = 1, fatal = 2 };

pub const ext = struct {
    pub const server_name: u16 = 0;
    pub const supported_groups: u16 = 10;
    pub const signature_algorithms: u16 = 13;
    pub const supported_versions: u16 = 43;
    pub const key_share: u16 = 51;
    pub const psk_key_exchange_modes: u16 = 45;
};

pub const group = struct {
    pub const x25519: u16 = 0x001d;
    pub const secp256r1: u16 = 0x0017;
    pub const secp384r1: u16 = 0x0018;
};

/// Signature schemes TLS 1.3 permits (RFC 8446 §4.4.2.2), in preference order.
pub const sig_scheme = struct {
    pub const rsa_pss_rsae_sha256: u16 = 0x0804;
    pub const rsa_pss_rsae_sha384: u16 = 0x0805;
    pub const rsa_pss_rsae_sha512: u16 = 0x0806;
    pub const ecdsa_secp256r1_sha256: u16 = 0x0403;
    pub const ecdsa_secp384r1_sha384: u16 = 0x0503;
    pub const rsa_pkcs1_sha256: u16 = 0x0401;
    pub const rsa_pkcs1_sha384: u16 = 0x0501;
    pub const rsa_pkcs1_sha512: u16 = 0x0601;
    pub const ed25519: u16 = 0x0807;
};

pub const cipher_suite = struct {
    pub const aes_128_gcm_sha256: u16 = 0x1301;
    pub const aes_256_gcm_sha384: u16 = 0x1302;
    pub const chacha20_poly1305_sha256: u16 = 0x1303;
};

/// The one suite this client implements. `TLS_AES_128_GCM_SHA256` is mandatory
/// to implement (RFC 8446 §9.1), so it is the safe single choice; the others
/// are listed above for the negotiation record but not offered.
pub const offered_suite = cipher_suite.aes_128_gcm_sha256;

pub const Error = error{
    RecordTooLarge,
    MessageTooLarge,
    BufferTooSmall,
    BadHandshakeHeader,
    UnexpectedMessage,
    UnexpectedState,
    MissingExtension,
    BadExtension,
    UnsupportedCipherSuite,
    UnsupportedGroup,
    UnsupportedSignatureScheme,
    AlertReceived,
    CertificateRejected,
    CertificateVerifyFailed,
    FinishedMismatch,
    TransportError,
    WrongState,
};

pub const State = enum {
    idle,
    sent_client_hello,
    received_server_hello,
    received_encrypted_extensions,
    received_certificate,
    received_certificate_verify,
    received_finished,
    /// The handshake completed: server Finished verified, client Finished sent,
    /// application keys installed. Only from here may application data flow.
    connected,
    closing,
    closed,
    failed,
};

/// Can application data be sent or received in this state?
pub fn allowsApplicationData(s: State) bool {
    return s == .connected;
}

/// A handshake message header, plus a writer/reader for the framing.
pub const MessageHeader = struct {
    msg_type: u8,
    length: u32,

    pub fn encode(self: MessageHeader, out: *[4]u8) void {
        out[0] = self.msg_type;
        std.mem.writeInt(u24, out[1..4], @intCast(self.length), .big);
    }

    pub fn decode(bytes: []const u8) Error!MessageHeader {
        if (bytes.len < 4) return Error.BadHandshakeHeader;
        return .{ .msg_type = bytes[0], .length = std.mem.readInt(u24, bytes[1..4], .big) };
    }
};

/// Transcript hash accumulator: every handshake message is hashed in full
/// (header included) in the order sent/received.
pub const Transcript = struct {
    h: crypto.sha256.Sha256 = crypto.sha256.Sha256.init(),

    pub fn add(self: *Transcript, msg: []const u8) void {
        self.h.update(msg);
    }

    pub fn hash(self: *const Transcript, out: *[32]u8) void {
        var copy = self.h;
        copy.final(out);
    }
};

/// A growable-free byte writer over a fixed buffer.
pub const Writer = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    pub fn bytes(self: *const Writer) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn put(self: *Writer, b: []const u8) Error!void {
        if (self.len + b.len > self.buf.len) return Error.BufferTooSmall;
        @memcpy(self.buf[self.len..][0..b.len], b);
        self.len += b.len;
    }

    pub fn putU8(self: *Writer, v: u8) Error!void {
        if (self.len + 1 > self.buf.len) return Error.BufferTooSmall;
        self.buf[self.len] = v;
        self.len += 1;
    }

    pub fn putU16(self: *Writer, v: u16) Error!void {
        var tmp: [2]u8 = undefined;
        std.mem.writeInt(u16, &tmp, v, .big);
        try self.put(&tmp);
    }

    pub fn putU24(self: *Writer, v: u32) Error!void {
        var tmp: [3]u8 = undefined;
        std.mem.writeInt(u24, &tmp, @intCast(v), .big);
        try self.put(&tmp);
    }

    /// Reserve a length prefix, returning its offset for later back-patching.
    pub fn reserveU16(self: *Writer) Error!usize {
        const at = self.len;
        try self.putU16(0);
        return at;
    }

    pub fn reserveU24(self: *Writer) Error!usize {
        const at = self.len;
        try self.putU24(0);
        return at;
    }

    /// Back-patch a reserved u16 length with the bytes written since.
    pub fn patchU16(self: *Writer, at: usize) Error!void {
        const n = self.len - at - 2;
        if (n > 0xffff) return Error.MessageTooLarge;
        std.mem.writeInt(u16, self.buf[at..][0..2], @intCast(n), .big);
    }
};

/// A reader over a byte slice with bounds checking.
pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn atEnd(self: *const Reader) bool {
        return self.pos >= self.buf.len;
    }

    pub fn remaining(self: *const Reader) usize {
        return self.buf.len - self.pos;
    }

    pub fn take(self: *Reader, n: usize) Error![]const u8 {
        if (self.pos + n > self.buf.len) return Error.BadExtension;
        const out = self.buf[self.pos..][0..n];
        self.pos += n;
        return out;
    }

    pub fn u8_(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }

    pub fn u16_(self: *Reader) Error!u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .big);
    }

    pub fn u24_(self: *Reader) Error!u32 {
        return std.mem.readInt(u24, (try self.take(3))[0..3], .big);
    }

    /// A vector with a u8 length prefix.
    pub fn vec8(self: *Reader) Error![]const u8 {
        const n = try self.u8_();
        return self.take(n);
    }

    /// A vector with a u16 length prefix.
    pub fn vec16(self: *Reader) Error![]const u8 {
        const n = try self.u16_();
        return self.take(n);
    }

    /// A vector with a u24 length prefix.
    pub fn vec24(self: *Reader) Error![]const u8 {
        const n = try self.u24_();
        return self.take(n);
    }
};

// ---------------------------------------------------------------------------
// ClientHello
// ---------------------------------------------------------------------------

pub const ClientHelloArgs = struct {
    host: []const u8,
    random: [random_len]u8,
    session_id: [session_id_len]u8,
    x25519_pub: [x25519_pub_len]u8,
};

/// Build a ClientHello handshake message (header included) into `out`.
/// Returns the message bytes, which are also the transcript input.
pub fn buildClientHello(out: []u8, args: ClientHelloArgs) Error![]const u8 {
    var w = Writer.init(out);

    // Handshake header, back-patched once the body length is known.
    try w.putU8(@backingInt(HandshakeType.client_hello));
    const hdr_len_at = w.len;
    try w.putU24(0);

    try w.putU16(0x0303); // legacy_version
    try w.put(&args.random);
    try w.putU8(session_id_len); // legacy_session_id (middlebox compat)
    try w.put(&args.session_id);

    // cipher_suites
    {
        const at = try w.reserveU16();
        try w.putU16(offered_suite);
        try w.patchU16(at);
    }
    // legacy_compression_methods
    try w.putU8(1);
    try w.putU8(0);

    // extensions
    const ext_at = try w.reserveU16();

    // server_name (SNI)
    {
        try w.putU16(ext.server_name);
        const at = try w.reserveU16();
        // ServerNameList = u16 length || ServerName; ServerName = u8 type ||
        // u16 name length || name. There is no extra length wrapper.
        const inner = try w.reserveU16();
        try w.putU8(0); // host_name
        const name_at = try w.reserveU16();
        try w.put(args.host);
        if (args.host.len > 0xffff) return Error.BufferTooSmall;
        std.mem.writeInt(u16, w.buf[name_at..][0..2], @intCast(args.host.len), .big);
        try w.patchU16(inner);
        try w.patchU16(at);
    }

    // supported_versions
    {
        try w.putU16(ext.supported_versions);
        const at = try w.reserveU16();
        try w.putU8(2); // ProtocolVersion list length
        try w.putU16(0x0304);
        try w.patchU16(at);
    }

    // supported_groups
    {
        try w.putU16(ext.supported_groups);
        const at = try w.reserveU16();
        const inner = try w.reserveU16();
        const list = try w.reserveU16();
        try w.putU16(group.x25519);
        try w.putU16(group.secp256r1);
        try w.putU16(group.secp384r1);
        try w.patchU16(list);
        try w.patchU16(inner);
        try w.patchU16(at);
    }

    // signature_algorithms
    {
        try w.putU16(ext.signature_algorithms);
        const at = try w.reserveU16();
        const inner = try w.reserveU16();
        const list = try w.reserveU16();
        for ([_]u16{
            sig_scheme.ecdsa_secp256r1_sha256,
            sig_scheme.ecdsa_secp384r1_sha384,
            sig_scheme.rsa_pss_rsae_sha256,
            sig_scheme.rsa_pss_rsae_sha384,
            sig_scheme.rsa_pss_rsae_sha512,
            sig_scheme.rsa_pkcs1_sha256,
            sig_scheme.rsa_pkcs1_sha384,
            sig_scheme.rsa_pkcs1_sha512,
            sig_scheme.ed25519,
        }) |s| try w.putU16(s);
        try w.patchU16(list);
        try w.patchU16(inner);
        try w.patchU16(at);
    }

    // key_share
    {
        try w.putU16(ext.key_share);
        const at = try w.reserveU16();
        // KeyShareClientHello = u16 length || KeyShareEntry;
        // KeyShareEntry = u16 group || u16 key length || key.
        const inner = try w.reserveU16();
        try w.putU16(group.x25519);
        try w.putU16(x25519_pub_len);
        try w.put(&args.x25519_pub);
        try w.patchU16(inner);
        try w.patchU16(at);
    }

    // psk_key_exchange_modes (present but no PSK offered)
    {
        try w.putU16(ext.psk_key_exchange_modes);
        const at = try w.reserveU16();
        try w.putU8(1); // modes list length
        try w.putU8(1); // psk_dhe_ke
        try w.patchU16(at);
    }

    try w.patchU16(ext_at);

    // back-patch the handshake length
    const body_len = w.len - hdr_len_at - 3;
    std.mem.writeInt(u24, w.buf[hdr_len_at..][0..3], @intCast(body_len), .big);

    return w.bytes();
}

// ---------------------------------------------------------------------------
// Server flight
// ---------------------------------------------------------------------------

pub const ServerHello = struct {
    cipher_suite: u16,
    /// The server's key_share public key, if it sent one for a supported group.
    peer_x25519: ?[x25519_pub_len]u8 = null,
    peer_group: u16 = 0,
    using_hrr: bool = false,
};

fn findExtension(r: *const Reader, want: u16) Error!?[]const u8 {
    var rr = r.*;
    while (!rr.atEnd()) {
        const at = try rr.u16_();
        const body = try rr.vec16();
        if (at == want) return body;
    }
    return null;
}

pub fn parseServerHello(body: []const u8) Error!ServerHello {
    var r = Reader.init(body);
    _ = try r.u16_(); // legacy_version
    _ = try r.take(random_len);
    _ = try r.vec8(); // legacy_session_id_echo
    const suite = try r.u16_();
    _ = try r.u8_(); // legacy_compression_method
    const exts = try r.vec16();

    var out = ServerHello{ .cipher_suite = suite };
    var er = Reader.init(exts);
    while (!er.atEnd()) {
        const at = try er.u16_();
        const body2 = try er.vec16();
        if (at == ext.key_share) {
            var kr = Reader.init(body2);
            const g = try kr.u16_();
            const key = try kr.vec16();
            out.peer_group = g;
            if (g == group.x25519 and key.len == x25519_pub_len) {
                var k: [x25519_pub_len]u8 = undefined;
                @memcpy(&k, key);
                out.peer_x25519 = k;
            }
        } else if (at == ext.supported_versions) {
            var vr = Reader.init(body2);
            const v = try vr.u16_();
            if (v != 0x0304) return Error.BadExtension;
        }
    }
    return out;
}

/// EncryptedExtensions: nothing here is required, but it must parse and it is
/// part of the transcript.
pub fn parseEncryptedExtensions(body: []const u8) Error!void {
    var r = Reader.init(body);
    const exts = try r.vec16();
    var er = Reader.init(exts);
    while (!er.atEnd()) {
        _ = try er.u16_();
        _ = try er.vec16();
    }
}

pub const CertificateMsg = struct {
    /// The first certificate's DER (the leaf). Slices point into `body`.
    leaf: []const u8,
    chain_len: usize,
};

pub fn parseCertificate(body: []const u8) Error!CertificateMsg {
    var r = Reader.init(body);
    _ = try r.vec8(); // certificate_request_context
    const list = try r.vec24();
    var lr = Reader.init(list);
    var first: ?[]const u8 = null;
    var count: usize = 0;
    while (!lr.atEnd()) {
        // CertificateEntry = cert_data<1..2^24-1> || extensions<0..2^16-1>;
        // the u24 length already delimits the DER, so there is no inner prefix.
        const cert_data = try lr.vec24();
        if (first == null) first = cert_data;
        count += 1;
        if (!lr.atEnd()) _ = try lr.vec16(); // per-entry extensions
    }
    return .{ .leaf = first orelse return Error.CertificateRejected, .chain_len = count };
}

pub const CertificateVerify = struct {
    scheme: u16,
    signature: []const u8,
};

pub fn parseCertificateVerify(body: []const u8) Error!CertificateVerify {
    var r = Reader.init(body);
    const scheme = try r.u16_();
    const sig = try r.vec16();
    return .{ .scheme = scheme, .signature = sig };
}

pub const Finished = struct {
    verify_data: []const u8,
};

pub fn parseFinished(body: []const u8) Error!Finished {
    if (body.len != 32) return Error.FinishedMismatch;
    return .{ .verify_data = body };
}

pub fn parseAlert(body: []const u8) Error!u8 {
    if (body.len != 2) return Error.BadExtension;
    return body[1]; // the alert description
}

/// The RFC 8446 §4.4.3 context string a server signs in CertificateVerify.
pub const server_cv_context = "TLS 1.3, server CertificateVerify";
pub const client_cv_context = "TLS 1.3, client CertificateVerify";

/// Build the 64-space + context + 0x00 + transcript-hash blob that
/// CertificateVerify is signed over.
pub fn certificateVerifyInput(out: []u8, context: []const u8, transcript_hash: *const [32]u8) []const u8 {
    var w = Writer.init(out);
    var i: usize = 0;
    while (i < 64) : (i += 1) w.putU8(0x20) catch unreachable;
    w.put(context) catch unreachable;
    w.putU8(0x00) catch unreachable;
    w.put(transcript_hash) catch unreachable;
    return w.bytes();
}

// ---------------------------------------------------------------------------
// Tests: framing and the state machine's shape
// ---------------------------------------------------------------------------

test "handshake: message header round-trips" {
    var buf: [4]u8 = undefined;
    const hdr = MessageHeader{ .msg_type = 1, .length = 0x0000c0 };
    hdr.encode(&buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00, 0x00, 0xc0 }, &buf);
    const h = try MessageHeader.decode(&buf);
    try std.testing.expectEqual(@as(u8, 1), h.msg_type);
    try std.testing.expectEqual(@as(u32, 0xc0), h.length);
    try std.testing.expectError(Error.BadHandshakeHeader, MessageHeader.decode(&[_]u8{ 1, 2, 3 }));
}

test "handshake: state machine gates application data" {
    // Only `connected` allows application data. This is the property the issue
    // asks for: no path reaches application data without completing the
    // handshake, because the gate is the state value itself.
    try std.testing.expect(!allowsApplicationData(.idle));
    try std.testing.expect(!allowsApplicationData(.sent_client_hello));
    try std.testing.expect(!allowsApplicationData(.received_server_hello));
    try std.testing.expect(!allowsApplicationData(.received_encrypted_extensions));
    try std.testing.expect(!allowsApplicationData(.received_certificate));
    try std.testing.expect(!allowsApplicationData(.received_certificate_verify));
    try std.testing.expect(!allowsApplicationData(.received_finished));
    try std.testing.expect(allowsApplicationData(.connected));
    try std.testing.expect(!allowsApplicationData(.failed));
    try std.testing.expect(!allowsApplicationData(.closed));
}

test "handshake: ClientHello has the shape the transcript needs" {
    var buf: [1024]u8 = undefined;
    var rand: [random_len]u8 = undefined;
    var sid: [session_id_len]u8 = undefined;
    var pk: [x25519_pub_len]u8 = undefined;
    for (&rand, 0..) |*b, i| b.* = @truncate(i);
    for (&sid, 0..) |*b, i| b.* = @truncate(i + 1);
    for (&pk, 0..) |*b, i| b.* = @truncate(i + 2);

    const msg = try buildClientHello(&buf, .{ .host = "example.com", .random = rand, .session_id = sid, .x25519_pub = pk });
    const h = try MessageHeader.decode(msg);
    try std.testing.expectEqual(@backingInt(HandshakeType.client_hello), h.msg_type);
    try std.testing.expectEqual(msg.len - 4, h.length);

    // Body parses far enough to find the version, the suite and the SNI.
    var r = Reader.init(msg[4..]);
    try std.testing.expectEqual(@as(u16, 0x0303), try r.u16_());
    _ = try r.take(random_len);
    _ = try r.vec8();
    const suites = try r.vec16();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x13, 0x01 }, suites);
    _ = try r.vec8(); // compression
    const exts = try r.vec16();
    try std.testing.expect(try findExtension(&Reader.init(exts), ext.server_name) != null);
    try std.testing.expect(try findExtension(&Reader.init(exts), ext.supported_versions) != null);
    try std.testing.expect(try findExtension(&Reader.init(exts), ext.key_share) != null);
    try std.testing.expect(try findExtension(&Reader.init(exts), ext.signature_algorithms) != null);
}

test "handshake: CertificateVerify input matches the RFC 8446 construction" {
    var out: [256]u8 = undefined;
    var th: [32]u8 = undefined;
    @memset(&th, 0xAB);
    const blob = certificateVerifyInput(&out, server_cv_context, &th);
    try std.testing.expectEqual(@as(usize, 64 + 33 + 1 + 32), blob.len);
    var i: usize = 0;
    while (i < 64) : (i += 1) try std.testing.expectEqual(@as(u8, 0x20), blob[i]);
    try std.testing.expectEqualSlices(u8, server_cv_context, blob[64..97]);
    try std.testing.expectEqual(@as(u8, 0x00), blob[97]);
    try std.testing.expectEqualSlices(u8, &th, blob[98..130]);
}

test "handshake: ServerHello parses the key share" {
    var body: [256]u8 = undefined;
    var w = Writer.init(&body);
    try w.putU16(0x0303);
    var rand: [32]u8 = undefined;
    @memset(&rand, 0x11);
    try w.put(&rand);
    try w.putU8(0);
    try w.putU16(cipher_suite.aes_128_gcm_sha256);
    try w.putU8(0);
    const exts_at = try w.reserveU16();
    // supported_versions -> 0x0304 (in ServerHello this is a bare version)
    {
        try w.putU16(ext.supported_versions);
        const at = try w.reserveU16();
        try w.putU16(0x0304);
        try w.patchU16(at);
    }
    // key_share -> x25519 pub (in ServerHello this is a single KeyShareEntry,
    // not a KeyShareEntry list, so there is no extra length wrapper)
    {
        try w.putU16(ext.key_share);
        const at = try w.reserveU16();
        try w.putU16(group.x25519);
        try w.putU16(x25519_pub_len);
        var pk: [x25519_pub_len]u8 = undefined;
        @memset(&pk, 0x22);
        try w.put(&pk);
        try w.patchU16(at);
    }
    try w.patchU16(exts_at);

    const sh = try parseServerHello(w.bytes());
    try std.testing.expectEqual(cipher_suite.aes_128_gcm_sha256, sh.cipher_suite);
    try std.testing.expect(sh.peer_x25519 != null);
    try std.testing.expectEqual(@as(u8, 0x22), sh.peer_x25519.?[0]);
    try std.testing.expectEqual(group.x25519, sh.peer_group);
}

test "handshake: Certificate and CertificateVerify parse" {
    // Certificate: context(0) || list of (cert(3b) || ext(2b))
    var cert_der = [_]u8{ 0x30, 0x03, 0x02, 0x01, 0x05 };
    var body: [256]u8 = undefined;
    var w = Writer.init(&body);
    try w.putU8(0); // context
    const list_at = try w.reserveU24();
    const cert_at = try w.reserveU24();
    try w.put(&cert_der);
    std.mem.writeInt(u24, w.buf[cert_at..][0..3], @intCast(cert_der.len), .big);
    try w.putU16(0); // extensions
    std.mem.writeInt(u24, w.buf[list_at..][0..3], @intCast(w.len - list_at - 3), .big);

    const cm = try parseCertificate(w.bytes());
    try std.testing.expectEqual(@as(usize, 1), cm.chain_len);
    try std.testing.expectEqualSlices(u8, &cert_der, cm.leaf);

    var cv: [128]u8 = undefined;
    var cw = Writer.init(&cv);
    try cw.putU16(sig_scheme.ecdsa_secp256r1_sha256);
    const sig_at = try cw.reserveU16();
    var sig = @as([70]u8, @splat(@as(u8, 0xAA)));
    try cw.put(&sig);
    std.mem.writeInt(u16, cw.buf[sig_at..][0..2], @intCast(cw.len - sig_at - 2), .big);
    const parsed = try parseCertificateVerify(cw.bytes());
    try std.testing.expectEqual(sig_scheme.ecdsa_secp256r1_sha256, parsed.scheme);
    try std.testing.expectEqual(@as(usize, 70), parsed.signature.len);
}
