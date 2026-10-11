//! TLS 1.3 client — the 1-RTT handshake driver and the application record
//! path (RFC 8446). Transport-agnostic: the caller supplies a read/write vtable
//! so the same client drives the guest's TCP seam and, in the host test
//! harness, a real socket.
//!
//! The handshake is a state machine, not straight-line code: `state` is
//! advanced one message at a time by `processHandshakeMessage`, and every
//! unrecognised ordering is rejected. Application data is only readable or
//! writable in `State.connected`.
//!
//! Scope: TLS_AES_128_GCM_SHA256, x25519 key share, full certificate
//! verification against a configured trust store. No PSK, no 0-RTT, no
//! client certificates, no HelloRetryRequest (a server that sends one is
//! rejected with a clear error rather than mishandled).

const std = @import("std");
const crypto = @import("crypto");
const hs = @import("handshake.zig");
const ks = @import("keyschedule.zig");
const record = @import("record.zig");
const x509 = @import("x509.zig");
const identity = @import("identity.zig");
const trust_store = @import("trust_store.zig");
const validate = @import("validate.zig");
const rsa = @import("rsa.zig");
const der = @import("der.zig");
const ecdsa = @import("ecdsa.zig");

pub const key_len = 16;
pub const iv_len = 12;

pub const Error = error{
    TransportError,
    RecordTooLarge,
    HandshakeTooLarge,
    UnexpectedMessage,
    UnexpectedState,
    AlertReceived,
    ServerRejected,
    UnsupportedCipherSuite,
    UnsupportedGroup,
    NoTrustAnchor,
    CertificateInvalid,
    CertificateVerifyFailed,
    FinishedMismatch,
    HelloRetryRequestUnsupported,
    NotConnected,
    RecordDecryptFailed,
    ChainValidationFailed,
    CertificateParseFailed,
};

/// A byte-stream transport. `ctx` is opaque to this module.
pub const Transport = struct {
    ctx: ?*anyopaque,
    readFn: *const fn (ctx: ?*anyopaque, buf: []u8) anyerror!usize,
    writeFn: *const fn (ctx: ?*anyopaque, buf: []const u8) anyerror!usize,

    pub fn readSome(self: Transport, buf: []u8) anyerror!usize {
        return self.readFn(self.ctx, buf);
    }

    pub fn readAll(self: Transport, buf: []u8) anyerror!void {
        var off: usize = 0;
        while (off < buf.len) {
            const n = try self.readFn(self.ctx, buf[off..]);
            if (n == 0) return error.TransportError;
            off += n;
        }
    }

    pub fn writeAll(self: Transport, buf: []const u8) anyerror!void {
        var off: usize = 0;
        while (off < buf.len) {
            const n = try self.writeFn(self.ctx, buf[off..]);
            if (n == 0) return error.TransportError;
            off += n;
        }
    }
};

const Keys = struct {
    key: [key_len]u8 = undefined,
    iv: [iv_len]u8 = undefined,
};

/// The client is generic over the trust-store type so the guest can use a
/// small store and the host harness a large one without a shared capacity.
pub fn Client(comptime S: type) type {
    return struct {
        pub const Config = struct {
            host: []const u8,
            store: *const S,
            now: i64,
            /// Caller-supplied entropy (the guest's CSPRNG; the host uses std.crypto).
            entropy: *const fn (out: []u8) void,
            verify_certificate: bool = true,
        };

        t: Transport,
        cfg: Config,
        state: hs.State = .idle,

        transcript: hs.Transcript = .{},

        // handshake-message reassembly across records
        hs_buf: [hs.max_handshake_msg]u8 = undefined,
        hs_len: usize = 0,

        // record scratch
        rec_buf: [record.max_ciphertext + record.header_len]u8 = undefined,
        plain_buf: [record.max_plaintext]u8 = undefined,

        read_keys: Keys = .{},
        write_keys: Keys = .{},
        read_seq: u64 = 0,
        write_seq: u64 = 0,
        read_encrypted: bool = false,
        write_keys_ready: bool = false,

        // handshake secrets, kept for the application-key derivation
        handshake_secret: [32]u8 = undefined,
        client_hs_secret: [32]u8 = undefined,
        server_hs_secret: [32]u8 = undefined,
        client_finished_key: [32]u8 = undefined,
        server_finished_key: [32]u8 = undefined,

        // negotiated
        server_cert: x509.Cert = .{},
        peer_intermediates: [8][]const u8 = undefined,
        peer_intermediate_len: usize = 0,
        peer_cert_storage: [8][4096]u8 = undefined,
        /// The leaf DER is copied here: the parse is a view, and the handshake
        /// reassembly buffer it came from is compacted and reused.
        leaf_storage: [4096]u8 = undefined,
        /// Set when the server sent a CertificateRequest: we answer with an empty
        /// Certificate before our Finished (RFC 8446 section 4.4.2).
        pending_client_cert: bool = false,
        last_cert_error: ?anyerror = null,

        negotiated_suite: u16 = 0,
        /// The chain-validation verdict, for troubleshooting.
        last_validation: validate.Result = .valid,

        pub fn init(t: Transport, cfg: Config) @This() {
            return .{ .t = t, .cfg = cfg };
        }

        // -- record layer -----------------------------------------------------

        fn sendRecord(self: *@This(), payload: []const u8, inner: hs.ContentType) !void {
            if (!self.read_encrypted and inner == .handshake and self.write_keys_ready == false) {
                // Plaintext handshake record (ClientHello).
                var buf: [5 + record.max_plaintext]u8 = undefined;
                buf[0] = @intFromEnum(hs.ContentType.handshake);
                buf[1] = 0x03;
                buf[2] = 0x03;
                std.mem.writeInt(u16, buf[3..5], @intCast(payload.len), .big);
                @memcpy(buf[5..][0..payload.len], payload);
                try self.t.writeAll(buf[0 .. 5 + payload.len]);
                return;
            }
            const rec_inner: record.ContentType = @enumFromInt(@intFromEnum(inner));
            const n = record.sealRecord(&self.rec_buf, payload, rec_inner, &self.write_keys.key, &self.write_keys.iv, self.write_seq);
            self.write_seq += 1;
            try self.t.writeAll(self.rec_buf[0..n]);
        }

        /// Read one record, decrypting if the read side has keys. Returns the
        /// plaintext length and its inner content type. A change_cipher_spec is
        /// consumed and reported as length 0.
        fn readRecord(self: *@This()) !struct { len: usize, inner: hs.ContentType } {
            var hdr: [record.header_len]u8 = undefined;
            try self.t.readAll(&hdr);
            const ct: hs.ContentType = @enumFromInt(hdr[0]);
            const len = std.mem.readInt(u16, hdr[3..5], .big);
            if (len > record.max_ciphertext) return Error.RecordTooLarge;

            @memcpy(self.rec_buf[0..record.header_len], &hdr);
            try self.t.readAll(self.rec_buf[record.header_len..][0..len]);
            const full = self.rec_buf[0 .. record.header_len + len];

            if (ct == .change_cipher_spec) return .{ .len = 0, .inner = .change_cipher_spec };
            if (ct == .alert) {
                // Alerts are also AEAD-protected once keys are installed.
                if (self.read_encrypted) {
                    var out: [record.max_plaintext]u8 = undefined;
                    var inner_rec: record.ContentType = .alert;
                    const n = record.openRecord(&out, &inner_rec, full, &self.read_keys.key, &self.read_keys.iv, self.read_seq) catch {
                        return Error.AlertReceived;
                    };
                    self.read_seq += 1;
                    const desc = hs.parseAlert(out[0..n]) catch 0;
                    std.log.debug("tls: received alert {d}", .{desc});
                    return Error.AlertReceived;
                }
                return Error.AlertReceived;
            }
            if (!self.read_encrypted) {
                @memcpy(self.plain_buf[0..len], full[record.header_len..][0..len]);
                return .{ .len = len, .inner = ct };
            }

            var inner_rec: record.ContentType = .handshake;
            const n = record.openRecord(&self.plain_buf, &inner_rec, full, &self.read_keys.key, &self.read_keys.iv, self.read_seq) catch {
                return Error.RecordDecryptFailed; // AEAD failure: fail closed
            };
            self.read_seq += 1;
            return .{ .len = n, .inner = @enumFromInt(@intFromEnum(inner_rec)) };
        }

        // -- handshake --------------------------------------------------------

        pub fn handshake(self: *@This()) !void {
            var hello: [1024]u8 = undefined;
            var random: [hs.random_len]u8 = undefined;
            var session_id: [hs.session_id_len]u8 = undefined;
            var priv: [32]u8 = undefined;
            var pub_key: [32]u8 = undefined;
            self.cfg.entropy(&random);
            self.cfg.entropy(&session_id);
            self.cfg.entropy(&priv);
            crypto.x25519.scalarmultBase(&pub_key, &priv);

            const ch = try hs.buildClientHello(&hello, .{
                .host = self.cfg.host,
                .random = random,
                .session_id = session_id,
                .x25519_pub = pub_key,
            });
            self.transcript.add(ch);
            try self.sendRecord(ch, .handshake);
            self.state = .sent_client_hello;

            var server_pub: [32]u8 = undefined;
            var got_server_hello = false;

            while (true) {
                const r = try self.readRecord();
                if (r.inner == .change_cipher_spec) continue;

                if (r.inner == .application_data or r.inner == .handshake) {
                    // Decrypted handshake bytes (application_data is the AEAD outer type).
                    try self.feedHandshake(self.plain_buf[0..r.len], &server_pub, &got_server_hello, priv);
                    if (self.state == .received_finished) {
                        try self.finishHandshake();
                        return;
                    }
                    continue;
                }
                if (r.inner == .alert) return Error.AlertReceived;
            }
        }

        /// Feed a chunk of (decrypted) handshake bytes; process every complete
        /// message in it. Handles ServerHello specially because it is what installs
        /// the handshake keys.
        fn feedHandshake(self: *@This(), chunk: []const u8, server_pub: *[32]u8, got_sh: *bool, priv: [32]u8) !void {
            if (self.hs_len + chunk.len > self.hs_buf.len) return Error.HandshakeTooLarge;
            @memcpy(self.hs_buf[self.hs_len..][0..chunk.len], chunk);
            self.hs_len += chunk.len;

            var off: usize = 0;
            while (self.hs_len - off >= 4) {
                const hdr = try hs.MessageHeader.decode(self.hs_buf[off..][0..4]);
                const total = 4 + hdr.length;
                if (self.hs_len - off < total) break;
                const msg = self.hs_buf[off..][0..total];
                try self.processMessage(msg, server_pub, got_sh, priv);
                off += total;
            }
            // Compact the unprocessed remainder.
            if (off > 0) {
                std.mem.copyForwards(u8, self.hs_buf[0..], self.hs_buf[off..self.hs_len]);
                self.hs_len -= off;
            }
        }

        fn processMessage(self: *@This(), msg: []const u8, server_pub: *[32]u8, got_sh: *bool, priv: [32]u8) !void {
            const hdr = try hs.MessageHeader.decode(msg[0..4]);
            const body = msg[4..];
            const t: hs.HandshakeType = @enumFromInt(hdr.msg_type);

            switch (t) {
                .server_hello => {
                    if (self.state != .sent_client_hello) return Error.UnexpectedState;
                    const sh = hs.parseServerHello(body) catch |e| return e;
                    if (sh.cipher_suite != hs.offered_suite) return Error.UnsupportedCipherSuite;
                    const pk = sh.peer_x25519 orelse return Error.UnsupportedGroup;
                    self.negotiated_suite = sh.cipher_suite;
                    server_pub.* = pk;
                    got_sh.* = true;

                    self.transcript.add(msg);
                    try self.deriveHandshakeKeys(pk, priv);
                    self.state = .received_server_hello;
                },
                .encrypted_extensions => {
                    if (self.state != .received_server_hello) return Error.UnexpectedState;
                    try hs.parseEncryptedExtensions(body);
                    self.transcript.add(msg);
                    self.state = .received_encrypted_extensions;
                },
                .certificate => {
                    if (self.state != .received_encrypted_extensions) return Error.UnexpectedState;
                    try self.captureCertificate(body);
                    self.transcript.add(msg);
                    self.state = .received_certificate;
                },
                .certificate_verify => {
                    if (self.state != .received_certificate) return Error.UnexpectedState;
                    const cv = try hs.parseCertificateVerify(body);
                    // The signature is over the transcript through Certificate, so
                    // hash *before* adding this message.
                    if (!try self.verifyCertificateVerify(cv)) return Error.CertificateVerifyFailed;
                    self.transcript.add(msg);
                    self.state = .received_certificate_verify;
                },
                .finished => {
                    if (self.state != .received_certificate_verify) return Error.UnexpectedState;
                    var th: [32]u8 = undefined;
                    self.transcript.hash(&th);
                    var expect: [32]u8 = undefined;
                    crypto.hmac.hmacSha256(&expect, &self.server_finished_key, &th);
                    const fin = try hs.parseFinished(body);
                    if (!crypto.ct.ctEq(&expect, fin.verify_data)) return Error.FinishedMismatch;
                    self.transcript.add(msg);
                    self.state = .received_finished;
                },
                .certificate_request => {
                    // A server may ask for a client certificate. We have none, so
                    // the answer is an empty Certificate, sent after the server's
                    // Finished (before ours). Recorded here in receive order.
                    self.transcript.add(msg);
                    self.pending_client_cert = true;
                },
                .new_session_ticket => {
                    // Legal to ignore for a client that did not offer a PSK.
                    self.transcript.add(msg);
                },
                else => return Error.UnexpectedMessage,
            }
        }

        fn deriveHandshakeKeys(self: *@This(), server_pub: [32]u8, priv: [32]u8) !void {
            var shared: [32]u8 = undefined;
            crypto.x25519.scalarmult(&shared, &priv, &server_pub);
            if (crypto.ct.ctEq(&shared, &(@as([32]u8, @splat(@as(u8, 0)))))) return Error.CertificateInvalid;

            var zero: [32]u8 = @as([32]u8, @splat(@as(u8, 0)));
            var early: [32]u8 = undefined;
            crypto.hkdf.Sha256.extract(&early, &zero, &zero);
            var empty_hash: [32]u8 = undefined;
            crypto.sha256.sha256(&empty_hash, "");
            var derived: [32]u8 = undefined;
            ks.Sha256.deriveSecret(&derived, &early, "derived", &empty_hash);

            var hs_secret: [32]u8 = undefined;
            crypto.hkdf.Sha256.extract(&hs_secret, &derived, &shared);
            self.handshake_secret = hs_secret;

            var th: [32]u8 = undefined;
            self.transcript.hash(&th);

            ks.Sha256.deriveSecret(&self.client_hs_secret, &hs_secret, "c hs traffic", &th);
            ks.Sha256.deriveSecret(&self.server_hs_secret, &hs_secret, "s hs traffic", &th);

            ks.Sha256.trafficKey(&self.write_keys.key, &self.client_hs_secret);
            ks.Sha256.trafficIv(&self.write_keys.iv, &self.client_hs_secret);
            ks.Sha256.trafficKey(&self.read_keys.key, &self.server_hs_secret);
            ks.Sha256.trafficIv(&self.read_keys.iv, &self.server_hs_secret);
            ks.Sha256.finishedKey(&self.client_finished_key, &self.client_hs_secret);
            ks.Sha256.finishedKey(&self.server_finished_key, &self.server_hs_secret);

            self.write_keys_ready = true;
            self.read_encrypted = true;
            self.read_seq = 0;
            self.write_seq = 0;
        }

        fn captureCertificate(self: *@This(), body: []const u8) !void {
            // Parse the entries; keep the leaf in `server_cert` and any further
            // entries as intermediates for chain building.
            var r = hs.Reader.init(body);
            _ = try r.vec8();
            const list = try r.vec24();
            var lr = hs.Reader.init(list);
            var idx: usize = 0;
            while (!lr.atEnd()) : (idx += 1) {
                const cert_data = try lr.vec24();
                if (!lr.atEnd()) _ = try lr.vec16();
                if (idx == 0) {
                    if (cert_data.len > self.leaf_storage.len) return Error.CertificateParseFailed;
                    @memcpy(self.leaf_storage[0..cert_data.len], cert_data);
                    x509.Cert.parse(self.leaf_storage[0..cert_data.len], &self.server_cert) catch |e| {
                        self.last_cert_error = e;
                        return Error.CertificateParseFailed;
                    };
                } else if (self.peer_intermediate_len < self.peer_intermediates.len) {
                    if (cert_data.len > self.peer_cert_storage[self.peer_intermediate_len].len) return Error.CertificateParseFailed;
                    const slot = &self.peer_cert_storage[self.peer_intermediate_len];
                    @memcpy(slot[0..cert_data.len], cert_data);
                    self.peer_intermediates[self.peer_intermediate_len] = slot[0..cert_data.len];
                    self.peer_intermediate_len += 1;
                }
            }
            if (self.peer_intermediate_len == 0) return; // root may be implied
        }

        fn verifyCertificateVerify(self: *@This(), cv: hs.CertificateVerify) !bool {
            var th: [32]u8 = undefined;
            self.transcript.hash(&th);
            var blob: [256]u8 = undefined;
            const signed = hs.certificateVerifyInput(&blob, hs.server_cv_context, &th);

            const key = &self.server_cert.key;
            switch (cv.scheme) {
                hs.sig_scheme.ecdsa_secp256r1_sha256, hs.sig_scheme.ecdsa_secp384r1_sha384 => {
                    if (key.kind != .ec) return false;
                    // Parse the DER ECDSA-Sig-Value with the strict DER reader.
                    var dr = der.Reader.init(cv.signature);
                    const seq = dr.expect(der.tag.sequence) catch return false;
                    if (!dr.atEnd()) return false;
                    var ir = der.Reader.init(seq.content);
                    const ri = der.integer(ir.expect(der.tag.integer) catch return false) catch return false;
                    const si = der.integer(ir.expect(der.tag.integer) catch return false) catch return false;
                    var z: [64]u8 = undefined;
                    var curve: ecdsa.Curve = undefined;
                    if (cv.scheme == hs.sig_scheme.ecdsa_secp256r1_sha256) {
                        crypto.sha256.sha256(z[0..32], signed);
                        curve = ecdsa.curveP256();
                    } else {
                        crypto.sha384.sha384(z[0..48], signed);
                        curve = ecdsa.curveP384();
                    }
                    const flen = (key.point.len - 1) / 2;
                    const zlen: usize = if (cv.scheme == hs.sig_scheme.ecdsa_secp256r1_sha256) 32 else 48;
                    return curve.verify(key.point[1 .. 1 + flen], key.point[1 + flen ..], ri, si, z[0..zlen]);
                },
                hs.sig_scheme.rsa_pss_rsae_sha256, hs.sig_scheme.rsa_pss_rsae_sha384, hs.sig_scheme.rsa_pss_rsae_sha512 => {
                    if (key.kind != .rsa) return false;
                    const h: rsa.Hash = if (cv.scheme == hs.sig_scheme.rsa_pss_rsae_sha256) .sha256 else if (cv.scheme == hs.sig_scheme.rsa_pss_rsae_sha384) .sha384 else .sha512;
                    return rsa.verifyPss(key.rsa_modulus, key.rsa_exponent, h, signed, cv.signature);
                },
                hs.sig_scheme.rsa_pkcs1_sha256, hs.sig_scheme.rsa_pkcs1_sha384, hs.sig_scheme.rsa_pkcs1_sha512 => {
                    if (key.kind != .rsa) return false;
                    const h: rsa.Hash = if (cv.scheme == hs.sig_scheme.rsa_pkcs1_sha256) .sha256 else if (cv.scheme == hs.sig_scheme.rsa_pkcs1_sha384) .sha384 else .sha512;
                    return rsa.verifyPkcs1(key.rsa_modulus, key.rsa_exponent, h, signed, cv.signature);
                },
                hs.sig_scheme.ed25519 => {
                    if (key.kind != .ed25519 or cv.signature.len != 64 or key.point.len != 32) return false;
                    const sig: *const [64]u8 = @ptrCast(cv.signature.ptr);
                    const pk: *const [32]u8 = @ptrCast(key.point.ptr);
                    return crypto.ed25519.verify(sig, signed, pk);
                },
                else => return false,
            }
        }

        fn finishHandshake(self: *@This()) !void {
            // Verify the server's chain before trusting anything it said.
            if (self.cfg.verify_certificate) {
                var inter: [8][]const u8 = undefined;
                var n: usize = 0;
                while (n < self.peer_intermediate_len and n < inter.len) : (n += 1) inter[n] = self.peer_intermediates[n];
                const res = validate.validate(self.server_cert.der, inter[0..n], self.cfg.store, self.cfg.host, self.cfg.now);
                self.last_validation = res;
                if (res != .valid) return Error.ChainValidationFailed;
            }

            // Application secrets come from the transcript through the server's
            // Finished, *before* any client Certificate is appended.
            var empty_hash: [32]u8 = undefined;
            crypto.sha256.sha256(&empty_hash, "");
            var derived: [32]u8 = undefined;
            ks.Sha256.deriveSecret(&derived, &self.handshake_secret, "derived", &empty_hash);
            var zero: [32]u8 = @as([32]u8, @splat(@as(u8, 0)));
            var master: [32]u8 = undefined;
            crypto.hkdf.Sha256.extract(&master, &derived, &zero);

            var th_ap: [32]u8 = undefined;
            self.transcript.hash(&th_ap);
            var c_ap: [32]u8 = undefined;
            var s_ap: [32]u8 = undefined;
            ks.Sha256.deriveSecret(&c_ap, &master, "c ap traffic", &th_ap);
            ks.Sha256.deriveSecret(&s_ap, &master, "s ap traffic", &th_ap);

            // If the server asked for a client certificate, send the empty one now.
            if (self.pending_client_cert) {
                var empty_cert = [_]u8{ 0x0b, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00 }; // Certificate with an empty list
                try self.sendRecord(&empty_cert, .handshake);
                self.transcript.add(&empty_cert);
            }

            // Client Finished over the transcript as it now stands.
            var th: [32]u8 = undefined;
            self.transcript.hash(&th);
            var expect: [32]u8 = undefined;
            crypto.hmac.hmacSha256(&expect, &self.client_finished_key, &th);
            var fin: [4 + 32]u8 = undefined;
            fin[0] = @intFromEnum(hs.HandshakeType.finished);
            std.mem.writeInt(u24, fin[1..4], 32, .big);
            @memcpy(fin[4..][0..32], &expect);
            try self.sendRecord(&fin, .handshake);
            self.transcript.add(&fin);

            // Switch to application keys.
            ks.Sha256.trafficKey(&self.write_keys.key, &c_ap);
            ks.Sha256.trafficIv(&self.write_keys.iv, &c_ap);
            ks.Sha256.trafficKey(&self.read_keys.key, &s_ap);
            ks.Sha256.trafficIv(&self.read_keys.iv, &s_ap);
            self.read_seq = 0;
            self.write_seq = 0;
            self.state = .connected;
        }

        // -- application data --------------------------------------------------

        pub fn write(self: *@This(), data: []const u8) !void {
            if (!hs.allowsApplicationData(self.state)) return Error.NotConnected;
            try self.sendRecord(data, .application_data);
        }

        /// Read application data (and transparently absorb handshake messages such
        /// as NewSessionTicket or KeyUpdate). Returns the number of bytes copied.
        pub fn read(self: *@This(), out: []u8) !usize {
            if (!hs.allowsApplicationData(self.state)) return Error.NotConnected;
            while (true) {
                const r = try self.readRecord();
                switch (r.inner) {
                    .change_cipher_spec => continue,
                    .application_data => {
                        const n = @min(out.len, r.len);
                        @memcpy(out[0..n], self.plain_buf[0..n]);
                        return n;
                    },
                    .handshake => {
                        // Post-handshake messages: absorb silently (tickets, etc.).
                        continue;
                    },
                    .alert => return Error.AlertReceived,
                }
            }
        }
    };
}
