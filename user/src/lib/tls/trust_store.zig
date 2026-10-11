//! Trust store (card TLS13-C4) — a deterministic, bounded, in-memory set of
//! trust anchors with an injection API and a runtime-reportable version string.
//!
//! Anchors are the caller's DER buffers; the store parses each one once and
//! keeps a `Cert` view, so it adds no copies beyond the fixed entry array.
//! A non-CA certificate is refused at injection rather than discovered
//! mid-validation, and matching is by exact subject-name byte comparison —
//! the fail-closed-safe comparison rather than a lossy CN shortcut.

const std = @import("std");
const x509 = @import("x509.zig");

/// The store is capacity-parameterised because the two callers have opposite
/// constraints: the guest keeps a small vendored root set (every entry is a
/// parsed certificate, so 64 roots is already ~160 KiB of BSS), while the host
/// interop harness loads a full system bundle of a few hundred.
pub fn Store(comptime max_roots: usize) type {
    return struct {
        pub const capacity = max_roots;

        pub const Error = error{ TooManyRoots, BadRoot };

        pub const Entry = struct {
            der: []const u8 = "",
            cert: x509.Cert = .{},
        };

        entries: [max_roots]Entry = @as([max_roots]Entry, @splat(@as(Entry, .{}))),
        len: usize = 0,
        version: []const u8 = "",

        pub fn init() @This() {
            return .{};
        }

        pub fn rootCount(self: *const @This()) usize {
            return self.len;
        }

        pub fn setVersion(self: *@This(), v: []const u8) void {
            self.version = v;
        }

        /// The provenance/version string, for runtime troubleshooting. Caller-owned.
        pub fn versionString(self: *const @This()) []const u8 {
            return self.version;
        }

        /// Add one trust anchor (DER). A certificate that fails to parse, or that
        /// is not a CA when it declares basicConstraints, is refused.
        pub fn addRoot(self: *@This(), der: []const u8) Error!void {
            if (self.len >= max_roots) return Error.TooManyRoots;
            var cert: x509.Cert = .{};
            x509.Cert.parse(der, &cert) catch return Error.BadRoot;
            if (cert.has_basic_constraints and !cert.is_ca) return Error.BadRoot;
            self.entries[self.len] = .{ .der = der, .cert = cert };
            self.len += 1;
        }

        pub fn clear(self: *@This()) void {
            self.len = 0;
            self.version = "";
        }

        /// Remove a root by DER equality; returns false if it was not present.
        pub fn removeRoot(self: *@This(), der: []const u8) bool {
            for (self.entries[0..self.len], 0..) |*e, i| {
                if (std.mem.eql(u8, e.der, der)) {
                    var j = i;
                    while (j + 1 < self.len) : (j += 1) self.entries[j] = self.entries[j + 1];
                    self.len -= 1;
                    return true;
                }
            }
            return false;
        }

        /// Find the anchor whose subject name equals `issuer_raw` (exact bytes).
        pub fn findIssuer(self: *const @This(), issuer_raw: []const u8) ?*const x509.Cert {
            for (self.entries[0..self.len]) |*e| {
                if (std.mem.eql(u8, e.cert.subject_raw, issuer_raw)) return &e.cert;
            }
            return null;
        }
    };
}

/// The guest's default: small enough to live in BSS.
pub const TrustStore = Store(64);
/// The host interop harness: room for a full system root bundle.
pub const SystemStore = Store(512);
