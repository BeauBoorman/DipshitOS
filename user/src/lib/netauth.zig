//! M50 TS4 (#1138, ADR 0024 D6): the delegated net-auth client/verifier.
//!
//! The attached process is the verifier. The kernel net pump (`terminal.zig`)
//! mints a fresh 32-byte challenge, frames it as
//! `VIRELAIOS-AUTH/1 <scheme> <hex-challenge>\n`, buffers the client's
//! one-line reply, and gates every post-challenge byte on this module's
//! verdict (slot 71 `sys_tty_net_auth`). Here:
//!
//!   * op 0 reads the challenge out;
//!   * op 1 reads the buffered reply line (hex) out;
//!   * the module computes HMAC-SHA256 over the domain-separated message
//!     `"VIRELAIOS-AUTH/1 hmac-sha256" || 0x00 || challenge[32]` and compares
//!     with `ct.ctEq` — or verifies an Ed25519 signature over
//!     `"VIRELAIOS-AUTH/1 ed25519" || 0x00 || challenge[32]`;
//!   * op 2 votes accept/reject.
//!
//! Credentials come from the TS5 store (`sys_secret_get`, slot 70) and NEVER
//! from argv: `net-hmac` supplies the HMAC key byte-for-byte as stored, and
//! `net-ed25519` supplies the 64-hex-character Ed25519 public key. Every key
//! buffer is wiped (ct.wipe) after use. The fresh server challenge is what
//! makes a captured handshake unreplayable.
//!
//! Pure policy over injected syscall/secret seams, so it is host-testable.

const std = @import("std");
const abi = @import("ui/abi.zig");
const hmac = @import("crypto/hmac.zig");
const ed25519 = @import("crypto/ed25519.zig");
const ct = @import("crypto/ct.zig");

pub const tag: []const u8 = "VIRELAIOS-AUTH/1";
pub const domain_hmac: []const u8 = "VIRELAIOS-AUTH/1 hmac-sha256";
pub const domain_ed25519: []const u8 = "VIRELAIOS-AUTH/1 ed25519";
pub const challenge_len: usize = abi.net_challenge_len; // 32
pub const line_max: usize = 160;
/// The TS5 store key names (ADR 0024 D6): the HMAC pre-shared key, and the
/// Ed25519 public key as 64 hex characters.
pub const key_hmac: []const u8 = "net-hmac";
pub const key_ed25519: []const u8 = "net-ed25519";

/// The `net <port> [open]` decision: the scheme the store supports.
pub const Scheme = enum(u8) {
    open = 0,
    hmac_sha256 = 1,
    ed25519 = 2,
};

/// The slot-71 syscall seam (injected so `step` is host-testable).
pub const Ops = struct {
    challenge_fn: *const fn (out: []u8) i64,
    response_fn: *const fn (out: []u8) i64,
    verdict_fn: *const fn (accept: bool) i64,
};

/// The production seam: real slot-71 calls.
pub fn sysOps() Ops {
    return .{ .challenge_fn = challengeFn, .response_fn = responseFn, .verdict_fn = verdictFn };
}

fn challengeFn(out: []u8) i64 {
    return abi.tty_net_auth(abi.net_auth_op_challenge, out);
}

fn responseFn(out: []u8) i64 {
    return abi.tty_net_auth(abi.net_auth_op_response, out);
}

fn verdictFn(accept: bool) i64 {
    var b: [1]u8 = .{@intFromBool(accept)};
    return abi.tty_net_auth(abi.net_auth_op_verdict, &b);
}

/// The stored-value seam: write the caller principal's value for `name` into
/// `out` and return its length, or null when absent.
pub const Source = struct {
    get_fn: *const fn (ctx: ?*anyopaque, name: []const u8, out: []u8) ?usize,
    ctx: ?*anyopaque = null,
};

/// The production source: `sys_secret_get` (slot 70), matching the key name
/// byte-exactly. The kernel already scopes records to the calling principal.
pub fn storeSource(ctx: ?*anyopaque, name: []const u8, out: []u8) ?usize {
    return storeSourceImpl(ctx, name, out);
}

fn storeSourceImpl(ctx: ?*anyopaque, name: []const u8, out: []u8) ?usize {
    _ = ctx;
    if (@import("builtin").os.tag != .freestanding) return null;
    var buf: [abi.secret_entries_max * abi.secret_entry_bytes]u8 = undefined;
    defer ct.wipe(&buf);
    const rc = abi.secret_get(&buf);
    if (rc <= 0) return null;
    const n: usize = @intCast(@divTrunc(rc, abi.secret_entry_bytes));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const rec = @as(*align(1) const abi.SecretRecord, @ptrCast(&buf[i * abi.secret_entry_bytes]));
        if (!std.mem.eql(u8, rec.key[0..rec.key_len], name)) continue;
        const v = rec.val[0..rec.val_len];
        const take = @min(v.len, out.len);
        @memcpy(out[0..take], v[0..take]);
        return take;
    }
    return null;
}

/// Which scheme the caller's store supports (hmac preferred, then ed25519,
/// else null = no credential). Reads no secret beyond a length probe.
pub fn selectScheme() ?Scheme {
    return selectSchemeWith(.{ .get_fn = storeSource });
}

pub fn selectSchemeWith(source: Source) ?Scheme {
    var probe: [1]u8 = undefined;
    defer ct.wipe(&probe);
    if (source.get_fn(source.ctx, key_hmac, &probe) != null) return .hmac_sha256;
    if (source.get_fn(source.ctx, key_ed25519, &probe) != null) return .ed25519;
    return null;
}

/// `"<domain>" || 0x00 || challenge[32]` — the signed/MAC'd message.
fn compose(out: []u8, domain: []const u8, challenge: *const [challenge_len]u8) []u8 {
    var n: usize = 0;
    @memcpy(out[n..][0..domain.len], domain);
    n += domain.len;
    out[n] = 0;
    n += 1;
    @memcpy(out[n..][0..challenge_len], challenge);
    n += challenge_len;
    return out[0..n];
}

const hex_digits = "0123456789abcdef";

fn hexLower(out: []u8, bytes: []const u8) []const u8 {
    var n: usize = 0;
    for (bytes) |b| {
        if (n + 2 > out.len) break;
        out[n] = hex_digits[b >> 4];
        out[n + 1] = hex_digits[b & 0xf];
        n += 2;
    }
    return out[0..n];
}

fn hexDecode(out: []u8, hex: []const u8) bool {
    if (hex.len != out.len * 2) return false;
    _ = std.fmt.hexToBytes(out, hex) catch return false;
    return true;
}

/// One net-auth handshake. `step` is non-blocking: call it around the shell
/// read loop; it performs the challenge read, the verdict computation, and
/// the vote exactly once.
pub const Auth = struct {
    scheme: Scheme = .open,
    ops: Ops,
    source: Source,
    challenge: [challenge_len]u8 = @as([challenge_len]u8, @splat(@as(u8, 0))),
    challenge_read: bool = false,
    done: bool = false,
    /// The key staging buffer (the verifier's only copy) — wiped after each
    /// verdict; a host test asserts it is zero.
    key: [abi.secret_max_val_len]u8 = @as([abi.secret_max_val_len]u8, @splat(@as(u8, 0))),
    key_len: usize = 0,

    pub fn init(scheme: Scheme, ops: Ops, source: Source) Auth {
        return .{ .scheme = scheme, .ops = ops, .source = source };
    }

    pub fn step(self: *Auth) void {
        if (self.done or self.scheme == .open) return;
        if (!self.challenge_read) {
            const n = self.ops.challenge_fn(&self.challenge);
            if (n != @as(i64, @intCast(challenge_len))) return;
            self.challenge_read = true;
        }
        var reply: [line_max]u8 = undefined;
        const rn = self.ops.response_fn(reply[0..]);
        if (rn <= 0) return;
        const len: usize = @intCast(rn);
        const accept = self.verify(reply[0..len]);
        _ = self.ops.verdict_fn(accept);
        ct.wipe(&reply);
        ct.wipe(&self.challenge);
        ct.wipe(&self.key);
        self.key_len = 0;
        self.done = true;
    }

    fn verify(self: *Auth, reply: []const u8) bool {
        switch (self.scheme) {
            .hmac_sha256 => {
                if (reply.len != 64) return false;
                const klen = self.source.get_fn(self.source.ctx, key_hmac, &self.key) orelse return false;
                self.key_len = klen;
                var msg: [domain_hmac.len + 1 + challenge_len]u8 = undefined;
                const m = compose(&msg, domain_hmac, &self.challenge);
                var mac: [32]u8 = undefined;
                defer ct.wipe(&mac);
                hmac.hmacSha256(&mac, self.key[0..klen], m);
                var want: [64]u8 = undefined;
                defer ct.wipe(&want);
                const hex = hexLower(&want, &mac);
                return ct.ctEq(hex, reply);
            },
            .ed25519 => {
                if (reply.len != 128) return false;
                const hlen = self.source.get_fn(self.source.ctx, key_ed25519, &self.key) orelse return false;
                self.key_len = hlen;
                if (hlen != 64) return false;
                var pk: [32]u8 = undefined;
                defer ct.wipe(&pk);
                if (!hexDecode(&pk, self.key[0..hlen])) return false;
                var sig: [64]u8 = undefined;
                defer ct.wipe(&sig);
                if (!hexDecode(&sig, reply)) return false;
                var msg: [domain_ed25519.len + 1 + challenge_len]u8 = undefined;
                const m = compose(&msg, domain_ed25519, &self.challenge);
                return ed25519.verify(&sig, m, &pk);
            },
            .open => return true,
        }
    }
};

// ---------------------------------------------------------------------------
// Host tests (pure; injected seams)
// ---------------------------------------------------------------------------

const TestOps = struct {
    var challenge: [challenge_len]u8 = @as([challenge_len]u8, @splat(@as(u8, 0)));
    var reply: [line_max]u8 = undefined;
    var reply_len: usize = 0;
    var verdict: ?bool = null;
    var challenge_reads: usize = 0;

    fn challengeFn(out: []u8) i64 {
        if (out.len < challenge_len) return -1;
        @memcpy(out[0..challenge_len], &challenge);
        challenge_reads += 1;
        return @intCast(challenge_len);
    }
    fn responseFn(out: []u8) i64 {
        if (reply_len == 0) return 0;
        @memcpy(out[0..reply_len], reply[0..reply_len]);
        return @intCast(reply_len);
    }
    fn verdictFn(accept: bool) i64 {
        verdict = accept;
        return 0;
    }
};

fn testOps() Ops {
    return .{ .challenge_fn = TestOps.challengeFn, .response_fn = TestOps.responseFn, .verdict_fn = TestOps.verdictFn };
}

const TestKey = struct {
    var name: []const u8 = "";
    var value: []const u8 = "";
    fn get(ctx: ?*anyopaque, key_name: []const u8, out: []u8) ?usize {
        _ = ctx;
        if (!std.mem.eql(u8, key_name, TestKey.name)) return null;
        const take = @min(TestKey.value.len, out.len);
        @memcpy(out[0..take], TestKey.value[0..take]);
        return take;
    }
};

fn testSource() Source {
    return .{ .get_fn = TestKey.get };
}

fn resetTest(challenge_first: u8) void {
    for (&TestOps.challenge, 0..) |*b, i| b.* = @intCast(challenge_first +% @as(u8, @intCast(i)));
    TestOps.reply_len = 0;
    TestOps.verdict = null;
    TestOps.challenge_reads = 0;
}

test "netauth: HMAC-SHA256 pinned vector accepts and wipes the key" {
    resetTest(0);
    TestKey.name = key_hmac;
    TestKey.value = "s3cret";
    // The pinned MAC over the domain-separated message (computed
    // independently with Python's stdlib hmac/hashlib).
    const mac_hex = "65bcb791094a86de218b38905cb939c6554ae9eb98238c48cd6835a8883f3ecb";
    @memcpy(TestOps.reply[0..mac_hex.len], mac_hex);
    TestOps.reply_len = mac_hex.len;
    var auth = Auth.init(.hmac_sha256, testOps(), testSource());
    auth.step();
    try std.testing.expectEqual(true, TestOps.verdict);
    try std.testing.expect(auth.done);
    // Key zeroize: the staging buffer and the challenge hold no key or
    // challenge material after the verdict.
    try std.testing.expect(std.mem.allEqual(u8, &auth.key, 0));
    try std.testing.expect(std.mem.allEqual(u8, &auth.challenge, 0));
    try std.testing.expectEqual(@as(usize, 0), auth.key_len);
}

test "netauth: a wrong MAC is rejected; a missing key is rejected" {
    resetTest(0);
    TestKey.name = key_hmac;
    TestKey.value = "s3cret";
    const wrong = "00bcb791094a86de218b38905cb939c6554ae9eb98238c48cd6835a8883f3ecb";
    @memcpy(TestOps.reply[0..wrong.len], wrong);
    TestOps.reply_len = wrong.len;
    var auth = Auth.init(.hmac_sha256, testOps(), testSource());
    auth.step();
    try std.testing.expectEqual(false, TestOps.verdict);
    // A store with no net-hmac entry fails closed (no key, reject).
    resetTest(0);
    TestKey.name = "other-key";
    TestOps.reply_len = wrong.len;
    var auth2 = Auth.init(.hmac_sha256, testOps(), testSource());
    auth2.step();
    try std.testing.expectEqual(false, TestOps.verdict);
}

test "netauth: a captured handshake does not verify against a fresh challenge" {
    // Same key, a DIFFERENT fresh challenge: the MAC is stale -> reject.
    // The reply is set AFTER resetTest (which clears the reply buffer).
    resetTest(7);
    const mac_hex = "65bcb791094a86de218b38905cb939c6554ae9eb98238c48cd6835a8883f3ecb";
    @memcpy(TestOps.reply[0..mac_hex.len], mac_hex);
    TestOps.reply_len = mac_hex.len;
    TestKey.name = key_hmac;
    TestKey.value = "s3cret";
    var auth = Auth.init(.hmac_sha256, testOps(), testSource());
    auth.step();
    try std.testing.expectEqual(false, TestOps.verdict);
}

test "netauth: Ed25519 pinned vector (CryptoKit-signed) accepts" {
    // RFC 8032 TEST 1 keypair, signature over
    // "VIRELAIOS-AUTH/1 ed25519" || 0x00 || challenge(0..31) computed
    // independently with CryptoKit (Curve25519.Signing) — the same
    // framework the Stage-0 host bridge uses.
    resetTest(0);
    TestKey.name = key_ed25519;
    TestKey.value = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
    const sig_hex = "1e985fbe650552347f932299cf9e5ac0e6ebc1098e3ca70e6a8c7ce63dd51210" ++
        "d53e7f3706f1371796e93e8508cdc2ae1ee4f190c8a1d16da91d63bdf6678306";
    @memcpy(TestOps.reply[0..sig_hex.len], sig_hex);
    TestOps.reply_len = sig_hex.len;
    var auth = Auth.init(.ed25519, testOps(), testSource());
    auth.step();
    try std.testing.expectEqual(true, TestOps.verdict);
    try std.testing.expect(std.mem.allEqual(u8, &auth.key, 0));

    // A tampered signature is rejected.
    resetTest(0);
    var bad: [128]u8 = undefined;
    @memcpy(&bad, sig_hex);
    bad[0] = 'f';
    TestOps.reply_len = 128;
    @memcpy(TestOps.reply[0..128], &bad);
    var auth2 = Auth.init(.ed25519, testOps(), testSource());
    auth2.step();
    try std.testing.expectEqual(false, TestOps.verdict);
}

test "netauth: selectScheme prefers hmac, falls back to ed25519, else null" {
    TestKey.name = key_hmac;
    TestKey.value = "k";
    try std.testing.expectEqual(Scheme.hmac_sha256, selectSchemeWith(testSource()).?);
    TestKey.name = key_ed25519;
    TestKey.value = "d75a";
    try std.testing.expectEqual(Scheme.ed25519, selectSchemeWith(testSource()).?);
    TestKey.name = "nope";
    try std.testing.expect(selectSchemeWith(testSource()) == null);
}

test "netauth: the open scheme never touches the seams" {
    resetTest(0);
    var auth = Auth.init(.open, testOps(), testSource());
    auth.step();
    try std.testing.expectEqual(@as(?bool, null), TestOps.verdict);
    try std.testing.expect(!auth.done);
    try std.testing.expectEqual(@as(usize, 0), TestOps.challenge_reads);
}
