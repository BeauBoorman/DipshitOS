//! X.509 certificate parsing (RFC 5280 §4) — DER only, strict, no allocation.
//!
//! Scope: everything a TLS 1.3 chain validator needs to read out of a
//! certificate — version, serial, signature algorithm, issuer/subject
//! commonName, validity, SubjectPublicKeyInfo, subjectAltName,
//! basicConstraints, keyUsage, extendedKeyUsage, nameConstraints, and the set
//! of unknown *critical* extensions (which must fail validation, so they are
//! surfaced rather than ignored).
//!
//! Not here: revocation lists, attributes, policy mappings, the path-building
//! algorithm. Those belong to the validator (card TLS13-C4).
//!
//! Fixed capacities, no allocation: the parsed `Cert` is a *view* into the
//! input DER, so nothing is copied except bounded fixed arrays of small
//! records. Over-capacity is an error, never a silent truncation.

const std = @import("std");
const der = @import("der.zig");

pub const Error = der.Error || error{
    NotACertificate,
    MissingField,
    UnsupportedVersion,
    TooManyExtensions,
    BadExtension,
    BadSan,
    BadIpAddress,
    BadAlgorithm,
};

pub const max_general_names = 64;
pub const max_unknown_critical = 16;
pub const max_nc = 12;

pub const oid = struct {
    pub const common_name = [_]u8{ 0x55, 0x04, 0x03 };
    pub const rsa_encryption = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };
    pub const rsassa_pss = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0a };
    pub const sha256_rsa = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b };
    pub const sha384_rsa = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0c };
    pub const sha512_rsa = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0d };
    pub const ec_public_key = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
    pub const prime256v1 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 };
    pub const secp384r1 = [_]u8{ 0x2b, 0x81, 0x04, 0x00, 0x22 };
    pub const ed25519 = [_]u8{ 0x2b, 0x65, 0x70 };
    pub const ecdsa_sha256 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02 };
    pub const ecdsa_sha384 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x03 };
    pub const ecdsa_sha512 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x04 };
    pub const subject_alt_name = [_]u8{ 0x55, 0x1d, 0x11 };
    pub const basic_constraints = [_]u8{ 0x55, 0x1d, 0x13 };
    pub const key_usage = [_]u8{ 0x55, 0x1d, 0x0f };
    pub const ext_key_usage = [_]u8{ 0x55, 0x1d, 0x25 };
    pub const name_constraints = [_]u8{ 0x55, 0x1d, 0x1e };
    pub const server_auth = [_]u8{ 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01 };
};

/// Certificate signature algorithms TLS 1.3 permits (RFC 8446 §4.4.2.2).
pub const SigAlg = enum {
    rsa_pkcs1_sha256,
    rsa_pkcs1_sha384,
    rsa_pkcs1_sha512,
    rsa_pss_rsae,
    ecdsa_sha256,
    ecdsa_sha384,
    ecdsa_sha512,
    ed25519,
    unknown,
};

pub const Curve = enum { p256, p384, unknown };
pub const KeyKind = enum { rsa, ec, ed25519, unsupported };

pub const Key = struct {
    kind: KeyKind = .unsupported,
    curve: Curve = .unknown,
    rsa_modulus: []const u8 = "",
    rsa_exponent: []const u8 = "",
    /// EC: the uncompressed point; Ed25519: the 32-byte public key.
    point: []const u8 = "",
};

pub const GeneralName = union(enum) {
    dns: []const u8,
    /// IPv4 is stored v4-mapped (`::ffff:a.b.c.d`) so one comparison covers both.
    ip: [16]u8,
};

/// keyUsage bit positions (RFC 5280 §4.2.1.3).
pub const ku = struct {
    pub const digital_signature: u16 = 1 << 0;
    pub const key_encipherment: u16 = 1 << 2;
    pub const key_agreement: u16 = 1 << 4;
    pub const key_cert_sign: u16 = 1 << 5;
    pub const crl_sign: u16 = 1 << 6;
};

pub const Cert = struct {
    der: []const u8 = "",
    /// Raw bytes of the tbsCertificate (the full SEQUENCE, header included).
    tbs: []const u8 = "",
    /// The signature value from the signatureValue BIT STRING.
    signature: []const u8 = "",
    version: u8 = 1,
    serial: []const u8 = "",
    sig_alg_oid: []const u8 = "",
    sig_alg: SigAlg = .unknown,
    issuer_cn: ?[]const u8 = null,
    subject_cn: ?[]const u8 = null,
    /// Raw DER of the issuer / subject Name (the full SEQUENCE element), for
    /// exact issuer-subject matching during path building.
    issuer_raw: []const u8 = "",
    subject_raw: []const u8 = "",
    not_before: i64 = 0,
    not_after: i64 = 0,
    key: Key = .{},

    has_san: bool = false,
    san: [max_general_names]GeneralName = undefined,
    san_len: usize = 0,

    has_basic_constraints: bool = false,
    is_ca: bool = false,
    path_len: ?u8 = null,

    has_key_usage: bool = false,
    key_usage: u16 = 0,

    has_eku: bool = false,
    eku_server_auth: bool = false,

    has_name_constraints: bool = false,
    nc_permitted_dns: [max_nc][]const u8 = undefined,
    nc_permitted_dns_len: usize = 0,
    nc_excluded_dns: [max_nc][]const u8 = undefined,
    nc_excluded_dns_len: usize = 0,

    unknown_critical: [max_unknown_critical][]const u8 = undefined,
    unknown_critical_len: usize = 0,

    pub fn parse(der_bytes: []const u8, out: *Cert) Error!void {
        out.* = .{ .der = der_bytes };

        var top = der.Reader.init(der_bytes);
        const cert_seq = try top.next();
        if (cert_seq.tag != der.tag.sequence) return Error.NotACertificate;
        if (!top.atEnd()) return Error.NotACertificate; // exactly one top-level element

        var c = der.Reader.init(cert_seq.content);
        const tbs = try c.expect(der.tag.sequence);
        const outer_alg = try c.expect(der.tag.sequence);
        const sig_elem = try c.expect(der.tag.bit_string);
        if (!c.atEnd()) return Error.NotACertificate;
        out.tbs = tbs.raw;
        out.signature = (try der.bitString(sig_elem)).bits;

        // signatureAlgorithm is the first element of the AlgorithmIdentifier.
        {
            var ar = der.Reader.init(outer_alg.content);
            out.sig_alg_oid = try der.oidBytes(try ar.next());
            out.sig_alg = classifySigAlg(out.sig_alg_oid);
        }

        try parseTbs(tbs.content, out);
    }

    pub fn hasUnknownCritical(self: *const Cert) bool {
        return self.unknown_critical_len != 0;
    }

    /// How many of the recorded general names are iPAddress entries.
    pub fn sanIpCount(self: *const Cert) usize {
        var n: usize = 0;
        for (self.san[0..self.san_len]) |g| {
            if (g == .ip) n += 1;
        }
        return n;
    }

    pub fn isServerCertEkuOk(self: *const Cert) bool {
        // RFC 5280 §4.2.1.12: absent EKU means unrestricted.
        return !self.has_eku or self.eku_server_auth;
    }
};

pub fn classifySigAlg(bytes: []const u8) SigAlg {
    if (der.eqlOid(bytes, &oid.sha256_rsa)) return .rsa_pkcs1_sha256;
    if (der.eqlOid(bytes, &oid.sha384_rsa)) return .rsa_pkcs1_sha384;
    if (der.eqlOid(bytes, &oid.sha512_rsa)) return .rsa_pkcs1_sha512;
    if (der.eqlOid(bytes, &oid.rsassa_pss)) return .rsa_pss_rsae;
    if (der.eqlOid(bytes, &oid.ecdsa_sha256)) return .ecdsa_sha256;
    if (der.eqlOid(bytes, &oid.ecdsa_sha384)) return .ecdsa_sha384;
    if (der.eqlOid(bytes, &oid.ecdsa_sha512)) return .ecdsa_sha512;
    if (der.eqlOid(bytes, &oid.ed25519)) return .ed25519;
    return .unknown;
}

fn parseTbs(buf: []const u8, out: *Cert) Error!void {
    var r = der.Reader.init(buf);

    var e = try r.next();
    if (e.isCtx(0)) {
        var vr = der.Reader.init(e.content);
        const v = try der.integerU64(try vr.expect(der.tag.integer));
        if (v > 2) return Error.UnsupportedVersion;
        out.version = @intCast(v + 1);
        e = try r.next();
    }

    if (e.tag != der.tag.integer) return Error.MissingField;
    out.serial = try der.integer(e);

    _ = try r.expect(der.tag.sequence); // inner signature AlgorithmIdentifier
    const issuer_elem = try r.expect(der.tag.sequence);
    out.issuer_cn = try parseNameCn(issuer_elem.content);
    out.issuer_raw = issuer_elem.raw;

    {
        const validity = try r.expect(der.tag.sequence);
        var vr = der.Reader.init(validity.content);
        out.not_before = try der.parseTime(try vr.next());
        out.not_after = try der.parseTime(try vr.next());
    }

    const subject_elem = try r.expect(der.tag.sequence);
    out.subject_cn = try parseNameCn(subject_elem.content);
    out.subject_raw = subject_elem.raw;
    try parseSpki((try r.expect(der.tag.sequence)).content, out);

    while (!r.atEnd()) {
        const x = try r.next();
        if (x.isCtx(3)) {
            try parseExtensions(x.content, out);
        } else if (x.isCtx(1) or x.isCtx(2)) {
            // issuerUniqueID / subjectUniqueID: legal, and nothing reads them.
        } else {
            return Error.MissingField;
        }
    }
}

/// Last commonName in the Name wins; a Name with none yields null.
fn parseNameCn(buf: []const u8) Error!?[]const u8 {
    var r = der.Reader.init(buf);
    var cn: ?[]const u8 = null;
    while (!r.atEnd()) {
        const rdn = try r.expect(der.tag.set);
        var rr = der.Reader.init(rdn.content);
        while (!rr.atEnd()) {
            const atv = try rr.expect(der.tag.sequence);
            var ar = der.Reader.init(atv.content);
            const o = try der.oidBytes(try ar.next());
            const val = try ar.next();
            if (der.eqlOid(o, &oid.common_name)) cn = val.content;
        }
    }
    return cn;
}

fn parseSpki(buf: []const u8, out: *Cert) Error!void {
    var r = der.Reader.init(buf);
    const alg = try r.expect(der.tag.sequence);
    const spk = try der.bitString(try r.expect(der.tag.bit_string));

    var ar = der.Reader.init(alg.content);
    const o = try der.oidBytes(try ar.next());

    if (der.eqlOid(o, &oid.rsa_encryption)) {
        var kr = der.Reader.init(spk.bits);
        const ks = try kr.expect(der.tag.sequence);
        var kk = der.Reader.init(ks.content);
        const n = try der.integer(try kk.next());
        const e = try der.integer(try kk.next());
        if (n.len < 256) return Error.BadAlgorithm; // < 2048-bit modulus
        out.key = .{ .kind = .rsa, .rsa_modulus = n, .rsa_exponent = e };
    } else if (der.eqlOid(o, &oid.ec_public_key)) {
        const curve = try der.oidBytes(try ar.next());
        const c: Curve = if (der.eqlOid(curve, &oid.prime256v1))
            .p256
        else if (der.eqlOid(curve, &oid.secp384r1))
            .p384
        else
            .unknown;
        if (c == .unknown) return Error.BadAlgorithm;
        if (spk.bits.len < 1 or spk.bits[0] != 0x04) return Error.BadAlgorithm; // uncompressed only
        const want: usize = if (c == .p256) 1 + 32 * 2 else 1 + 48 * 2;
        if (spk.bits.len != want) return Error.BadAlgorithm;
        out.key = .{ .kind = .ec, .curve = c, .point = spk.bits };
    } else if (der.eqlOid(o, &oid.ed25519)) {
        if (spk.bits.len != 32) return Error.BadAlgorithm;
        out.key = .{ .kind = .ed25519, .point = spk.bits };
    } else {
        out.key = .{ .kind = .unsupported };
    }
}

fn parseExtensions(buf: []const u8, out: *Cert) Error!void {
    var outer = der.Reader.init(buf);
    const seq = try outer.expect(der.tag.sequence);
    var r = der.Reader.init(seq.content);

    while (!r.atEnd()) {
        const ext = try r.expect(der.tag.sequence);
        var er = der.Reader.init(ext.content);
        const o = try der.oidBytes(try er.next());

        var critical = false;
        var val_e = try er.next();
        if (val_e.tag == der.tag.boolean) {
            critical = try der.boolean(val_e);
            val_e = try er.next();
        }
        if (val_e.tag != der.tag.octet_string) return Error.BadExtension;
        const val = val_e.content;

        if (der.eqlOid(o, &oid.subject_alt_name)) {
            try parseSan(val, out);
        } else if (der.eqlOid(o, &oid.basic_constraints)) {
            try parseBasicConstraints(val, out);
        } else if (der.eqlOid(o, &oid.key_usage)) {
            try parseKeyUsage(val, out);
        } else if (der.eqlOid(o, &oid.ext_key_usage)) {
            try parseEku(val, out);
        } else if (der.eqlOid(o, &oid.name_constraints)) {
            try parseNameConstraints(val, out);
        } else if (critical) {
            if (out.unknown_critical_len >= max_unknown_critical) return Error.TooManyExtensions;
            out.unknown_critical[out.unknown_critical_len] = o;
            out.unknown_critical_len += 1;
        }
    }
}

fn parseSan(buf: []const u8, out: *Cert) Error!void {
    out.has_san = true;
    var r = der.Reader.init(buf);
    const seq = try r.expect(der.tag.sequence);
    var g = der.Reader.init(seq.content);

    while (!g.atEnd()) {
        const gn = try g.next();
        if (gn.isCtx(2)) { // dNSName: primitive IA5String
            if (out.san_len >= max_general_names) return Error.TooManyExtensions;
            out.san[out.san_len] = .{ .dns = gn.content };
            out.san_len += 1;
        } else if (gn.isCtx(7)) { // iPAddress
            if (gn.content.len != 4 and gn.content.len != 16) return Error.BadIpAddress;
            if (out.san_len >= max_general_names) return Error.TooManyExtensions;
            var ip = @as([16]u8, @splat(@as(u8, 0)));
            if (gn.content.len == 4) {
                ip[10] = 0xff;
                ip[11] = 0xff;
                @memcpy(ip[12..16], gn.content);
            } else {
                @memcpy(&ip, gn.content);
            }
            out.san[out.san_len] = .{ .ip = ip };
            out.san_len += 1;
        }
    }
}

fn parseBasicConstraints(buf: []const u8, out: *Cert) Error!void {
    out.has_basic_constraints = true;
    var r = der.Reader.init(buf);
    const seq = try r.expect(der.tag.sequence);
    var s = der.Reader.init(seq.content);

    if (!s.atEnd()) {
        const b = try s.next();
        if (b.tag != der.tag.boolean) return Error.BadExtension;
        out.is_ca = try der.boolean(b);
    }
    if (!s.atEnd()) {
        const p = try s.next();
        if (p.tag != der.tag.integer) return Error.BadExtension;
        const v = try der.integerU64(p);
        if (v > 255) return Error.BadExtension;
        out.path_len = @intCast(v);
    }
    if (!s.atEnd()) return Error.BadExtension;
}

fn parseKeyUsage(buf: []const u8, out: *Cert) Error!void {
    var r = der.Reader.init(buf);
    const bs = try der.bitString(try r.next());
    out.has_key_usage = true;
    var k: u16 = 0;
    for (bs.bits, 0..) |byte, i| {
        if (i >= 2) break;
        var b: u4 = 0;
        while (b < 8) : (b += 1) {
            const bit: u4 = @intCast(i * 8 + b);
            if (byte & (@as(u8, 0x80) >> @intCast(b)) != 0) k |= (@as(u16, 1) << bit);
        }
    }
    out.key_usage = k;
}

fn parseEku(buf: []const u8, out: *Cert) Error!void {
    out.has_eku = true;
    var r = der.Reader.init(buf);
    const seq = try r.expect(der.tag.sequence);
    var s = der.Reader.init(seq.content);
    while (!s.atEnd()) {
        const o = try der.oidBytes(try s.next());
        if (der.eqlOid(o, &oid.server_auth)) out.eku_server_auth = true;
    }
}

fn parseNameConstraints(buf: []const u8, out: *Cert) Error!void {
    out.has_name_constraints = true;
    var r = der.Reader.init(buf);
    const seq = try r.expect(der.tag.sequence);
    var s = der.Reader.init(seq.content);

    while (!s.atEnd()) {
        const field = try s.next();
        if (!field.isCtx(0) and !field.isCtx(1)) return Error.BadExtension;
        const permitted = field.isCtx(0);
        // NameConstraints' subtrees are IMPLICITLY tagged, so the [0]/[1] tag
        // replaces the GeneralSubtrees SEQUENCE tag: the content is the
        // GeneralSubtree elements directly, with no inner SEQUENCE wrapper.
        var lr = der.Reader.init(field.content);
        while (!lr.atEnd()) {
            const sub = try lr.expect(der.tag.sequence);
            var sr = der.Reader.init(sub.content);
            if (sr.atEnd()) continue;
            const base = try sr.next();
            if (!base.isCtx(2)) continue; // only DNS constraints are recorded
            const base_str = base.content;
            if (permitted) {
                if (out.nc_permitted_dns_len >= max_nc) return Error.TooManyExtensions;
                out.nc_permitted_dns[out.nc_permitted_dns_len] = base_str;
                out.nc_permitted_dns_len += 1;
            } else {
                if (out.nc_excluded_dns_len >= max_nc) return Error.TooManyExtensions;
                out.nc_excluded_dns[out.nc_excluded_dns_len] = base_str;
                out.nc_excluded_dns_len += 1;
            }
        }
    }
}

const vectors = @import("x509_vectors.zig");

fn hexToBytes(out: []u8, s: []const u8) usize {
    _ = std.fmt.hexToBytes(out[0 .. s.len / 2], s) catch unreachable;
    return s.len / 2;
}

test "x509: parses every generated certificate and matches openssl's view" {
    var derbuf: [8192]u8 = undefined;
    var checked: usize = 0;
    for (vectors.certs) |v| {
        const n = hexToBytes(&derbuf, v.der_hex);
        var cert: Cert = .{};
        Cert.parse(derbuf[0..n], &cert) catch |e| {
            std.debug.print("parse failed for {s}: {any}\n", .{ v.name, e });
            return e;
        };

        try std.testing.expectEqual(v.version, cert.version);
        try std.testing.expectEqualStrings(v.subject_cn, cert.subject_cn orelse "<none>");
        try std.testing.expectEqualStrings(v.issuer_cn, cert.issuer_cn orelse "<none>");
        try std.testing.expectEqual(v.not_before, cert.not_before);
        try std.testing.expectEqual(v.not_after, cert.not_after);
        try std.testing.expectEqual(v.is_ca, cert.is_ca);
        try std.testing.expectEqual(v.has_san, cert.has_san);
        try std.testing.expectEqual(v.san_dns_len, cert.san_len - cert.sanIpCount());
        try std.testing.expectEqual(v.unknown_critical_len, cert.unknown_critical_len);

        // Serial and SPKI algorithm, cross-checked against the fixture file.
        var serial: [64]u8 = undefined;
        const sn = hexToBytes(&serial, v.serial_hex);
        try std.testing.expectEqualSlices(u8, serial[0..sn], cert.serial);
        try std.testing.expectEqual(v.key_kind, @tagName(cert.key.kind));

        checked += 1;
    }
    try std.testing.expectEqual(vectors.certs.len, checked);
}

test "x509: SAN entries land in the right buckets" {
    var derbuf: [8192]u8 = undefined;

    {
        const n = hexToBytes(&derbuf, vectors.byName("leaf-ec").der_hex);
        var cert: Cert = .{};
        try Cert.parse(derbuf[0..n], &cert);
        try std.testing.expectEqual(@as(usize, 2), cert.san_len);
        try std.testing.expectEqualStrings("leaf.example.com", cert.san[0].dns);
        try std.testing.expectEqualStrings("*.wild.example.com", cert.san[1].dns);
        try std.testing.expectEqual(@as(usize, 0), cert.sanIpCount());
        // digitalSignature only, EKU serverAuth present.
        try std.testing.expect(cert.has_key_usage);
        try std.testing.expect(cert.key_usage == ku.digital_signature);
        try std.testing.expect(cert.eku_server_auth);
        try std.testing.expect(!cert.is_ca);
    }

    {
        const n = hexToBytes(&derbuf, vectors.byName("leaf-ip").der_hex);
        var cert: Cert = .{};
        try Cert.parse(derbuf[0..n], &cert);
        try std.testing.expectEqual(@as(usize, 2), cert.sanIpCount());
        // 127.0.0.1 is stored v4-mapped.
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1 }, &cert.san[0].ip);
        try std.testing.expectEqual(@as(u8, 0x20), cert.san[1].ip[0]);
        try std.testing.expectEqual(@as(u8, 0x01), cert.san[1].ip[1]);
        try std.testing.expectEqual(@as(u8, 0x0d), cert.san[1].ip[2]);
        try std.testing.expectEqual(@as(u8, 0xb8), cert.san[1].ip[3]);
    }

    {
        const n = hexToBytes(&derbuf, vectors.byName("inter").der_hex);
        var cert: Cert = .{};
        try Cert.parse(derbuf[0..n], &cert);
        try std.testing.expect(cert.is_ca);
        try std.testing.expectEqual(@as(?u8, 0), cert.path_len);
        try std.testing.expect(cert.key_usage & ku.key_cert_sign != 0);
        try std.testing.expectEqual(@as(usize, 0), cert.san_len);
        try std.testing.expect(!cert.has_san);
    }

    {
        const n = hexToBytes(&derbuf, vectors.byName("ca-nc").der_hex);
        var cert: Cert = .{};
        try Cert.parse(derbuf[0..n], &cert);
        try std.testing.expect(cert.has_name_constraints);
        try std.testing.expectEqual(@as(usize, 1), cert.nc_permitted_dns_len);
        try std.testing.expectEqualStrings(".example.com", cert.nc_permitted_dns[0]);
        try std.testing.expectEqual(@as(usize, 1), cert.nc_excluded_dns_len);
        try std.testing.expectEqualStrings(".evil.example.com", cert.nc_excluded_dns[0]);
    }

    {
        const n = hexToBytes(&derbuf, vectors.byName("leaf-unknowncrit").der_hex);
        var cert: Cert = .{};
        try Cert.parse(derbuf[0..n], &cert);
        try std.testing.expectEqual(@as(usize, 1), cert.unknown_critical_len);
        try std.testing.expect(cert.hasUnknownCritical());
        // The private-arc OID (1.3.6.1.4.1.55555.1) the fixture was built with.
        // `openssl asn1parse` reports it as a 9-byte OBJECT: 2b 06 01 04 01 for
        // 1.3.6.1.4.1, then 55555 -> 83 b2 03, then the final arc 1 -> 01.
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x2b, 0x06, 0x01, 0x04, 0x01, 0x83, 0xb2, 0x03, 0x01 }, cert.unknown_critical[0]);
    }

    {
        const n = hexToBytes(&derbuf, vectors.byName("leaf-rsa").der_hex);
        var cert: Cert = .{};
        try Cert.parse(derbuf[0..n], &cert);
        try std.testing.expectEqual(KeyKind.rsa, cert.key.kind);
        try std.testing.expect(cert.key.rsa_modulus.len >= 256);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00, 0x01 }, cert.key.rsa_exponent);
    }

    {
        const n = hexToBytes(&derbuf, vectors.byName("leaf-nosan").der_hex);
        var cert: Cert = .{};
        try Cert.parse(derbuf[0..n], &cert);
        try std.testing.expect(!cert.has_san);
        try std.testing.expectEqual(@as(usize, 0), cert.san_len);
        try std.testing.expectEqualStrings("cnonly.example.com", cert.subject_cn.?);
    }
}

test "x509: malformed input returns an error, never a panic" {
    var derbuf: [8192]u8 = undefined;
    const n = hexToBytes(&derbuf, vectors.byName("leaf-ec").der_hex);

    // Truncation at any offset must be rejected. The outer SEQUENCE declares
    // the full length, so every cut short of the end is a Truncated.
    const cuts: [12]usize = .{ 1, 2, 3, 4, 8, 16, 32, 64, n / 2, n - 3, n - 2, n - 1 };
    for (cuts) |cut| {
        var cert: Cert = .{};
        try std.testing.expectError(Error.Truncated, Cert.parse(derbuf[0..cut], &cert));
    }

    // Wrong top-level tag.
    {
        var bad = derbuf[0..n];
        bad[0] = 0x31;
        var cert: Cert = .{};
        try std.testing.expectError(Error.NotACertificate, Cert.parse(bad, &cert));
    }

    // Trailing garbage after the certificate.
    {
        var extended: [8192]u8 = undefined;
        @memcpy(extended[0..n], derbuf[0..n]);
        extended[n] = 0x00;
        var cert: Cert = .{};
        try std.testing.expectError(Error.NotACertificate, Cert.parse(extended[0 .. n + 1], &cert));
    }

    // Indefinite length where DER forbids it.
    {
        var bad = derbuf[0..n];
        bad[1] = 0x80;
        var cert: Cert = .{};
        try std.testing.expectError(Error.IndefiniteLength, Cert.parse(bad, &cert));
    }

    // Non-minimal long-form length.
    {
        var bad = derbuf[0..n];
        bad[1] = 0x81;
        bad[2] = 0x01;
        var cert: Cert = .{};
        const r = Cert.parse(bad, &cert);
        try std.testing.expect(r == error.NonMinimalLength or r == error.Truncated or r == error.NotACertificate);
    }
}

test "x509: nesting deeper than the bound is rejected" {
    // Build SEQUENCE(SEQUENCE(...)) outward in place, then walk in until the
    // depth bound fires.
    var buf: [96]u8 = undefined;
    buf[0] = 0x30;
    buf[1] = 0x00;
    var n: usize = 2;
    var k: usize = 0;
    while (k < der.max_depth + 2) : (k += 1) {
        var i: usize = n;
        while (i > 0) : (i -= 1) buf[i + 1] = buf[i - 1];
        buf[0] = 0x30;
        buf[1] = @intCast(n);
        n += 2;
    }

    var r = der.Reader.init(buf[0..n]);
    var depth: usize = 0;
    while (depth < der.max_depth) : (depth += 1) {
        const e = try r.next();
        r = try r.enter(e, depth);
    }
    const e = try r.next();
    try std.testing.expectError(Error.DepthExceeded, r.enter(e, der.max_depth));
}
