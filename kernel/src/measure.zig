//! Measurement primitive + chain receipt format (M113b, ADR 0054 Part I).
//!
//! The verified+measured boot chain is firmware db -> loader -> kernel:
//! the loader hashes KERNEL.BIN and its own Authenticode image digest,
//! passes both through the v4 handoff, and the kernel publishes the chain
//! as `RCPT` receipt lines (serial + the host share). M113c reuses the
//! same primitive and format for per-exec measurements.
//!
//! SHA-256 lives HERE, kernel-local: ADR 0023 D2 forbids the kernel
//! importing the M47 userland library (the same rule csprng.zig follows —
//! no shared translation unit, drift-guarded by the same FIPS 180-4
//! known-answer vectors pinned in this file's tests). The boot loader
//! imports this module as a named build import, so exactly one SHA-256
//! implementation exists in the guest.
//!
//! Receipt format (ADR 0054 D4), one line per measurement:
//!
//!     RCPT stage=<word> sha256=<64-hex> verdict=<word> [name=<image>] [word=<cap>] uid=<n>
//!
//! stage ∈ loader | kernel | exec; sha256 is the digest of the convention
//! the stage pins (Authenticode for loader, raw file for kernel/exec);
//! verdict is `measured`, `refused:<name>` (a D3 named refusal), or
//! `audit:<name>` (Part II's audit-mode would-be denial). `unmeasured` is
//! emitted when a stage's handoff validity bit is clear — a stage that was
//! not measured must never be reported as `measured`. `uid` is always the
//! last field (M173c #3044, ADR 0052 amendment): the principal the receipt
//! records — the spawn uid for exec lines, the denied process's uid on
//! word/scope denials, `uid_system` on the boot chain. Parsers that read
//! fields by key are unaffected; a key-positional parser was never the
//! contract.
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");

pub const block_len = 64;
pub const digest_len = 32;

// FIPS 180-4 §4.2.2 round constants.
const k = [64]u32{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

const iv = [8]u32{
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
};

/// Streaming FIPS 180-4 SHA-256 context. Plain value, caller-buffered.
pub const Sha256 = struct {
    state: [8]u32 = iv,
    buf: [block_len]u8 = undefined,
    buf_len: usize = 0,
    total: u64 = 0,

    pub fn init() Sha256 {
        return .{};
    }

    pub fn update(self: *Sha256, bytes: []const u8) void {
        self.total +%= bytes.len;
        var i: usize = 0;
        if (self.buf_len != 0) {
            const need = block_len - self.buf_len;
            const take = @min(need, bytes.len);
            @memcpy(self.buf[self.buf_len..][0..take], bytes[0..take]);
            self.buf_len += take;
            i += take;
            if (self.buf_len == block_len) {
                compress(&self.state, &self.buf);
                self.buf_len = 0;
            }
        }
        while (i + block_len <= bytes.len) : (i += block_len) {
            compress(&self.state, bytes[i..][0..block_len]);
        }
        if (i < bytes.len) {
            const tail = bytes.len - i;
            @memcpy(self.buf[0..tail], bytes[i..]);
            self.buf_len = tail;
        }
    }

    pub fn final(self: *Sha256, out: *[digest_len]u8) void {
        const bit_len: u64 = self.total << 3;
        self.buf[self.buf_len] = 0x80;
        self.buf_len += 1;
        if (self.buf_len > block_len - 8) {
            @memset(self.buf[self.buf_len..block_len], 0);
            compress(&self.state, &self.buf);
            self.buf_len = 0;
        }
        @memset(self.buf[self.buf_len .. block_len - 8], 0);
        std.mem.writeInt(u64, self.buf[block_len - 8 ..][0..8], bit_len, .big);
        compress(&self.state, &self.buf);
        for (0..8) |j| std.mem.writeInt(u32, out[j * 4 ..][0..4], self.state[j], .big);
    }
};

fn compress(state: *[8]u32, block: *const [block_len]u8) void {
    var w: [64]u32 = undefined;
    for (0..16) |j| w[j] = std.mem.readInt(u32, block[j * 4 ..][0..4], .big);
    for (16..64) |j| {
        const x = w[j - 15];
        const y = w[j - 2];
        const s0 = std.math.rotr(u32, x, 7) ^ std.math.rotr(u32, x, 18) ^ (x >> 3);
        const s1 = std.math.rotr(u32, y, 17) ^ std.math.rotr(u32, y, 19) ^ (y >> 10);
        w[j] = w[j - 16] +% s0 +% w[j - 7] +% s1;
    }

    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var f = state[5];
    var g = state[6];
    var h = state[7];

    for (0..64) |j| {
        const s1 = std.math.rotr(u32, e, 6) ^ std.math.rotr(u32, e, 11) ^ std.math.rotr(u32, e, 25);
        const ch = (e & f) ^ (~e & g);
        const t1 = h +% s1 +% ch +% k[j] +% w[j];
        const s0 = std.math.rotr(u32, a, 2) ^ std.math.rotr(u32, a, 13) ^ std.math.rotr(u32, a, 22);
        const maj = (a & b) ^ (a & c) ^ (b & c);
        const t2 = s0 +% maj;
        h = g;
        g = f;
        f = e;
        e = d +% t1;
        d = c;
        c = b;
        b = a;
        a = t1 +% t2;
    }

    state[0] +%= a;
    state[1] +%= b;
    state[2] +%= c;
    state[3] +%= d;
    state[4] +%= e;
    state[5] +%= f;
    state[6] +%= g;
    state[7] +%= h;
}

/// One-shot SHA-256.
pub fn hash(out: *[digest_len]u8, bytes: []const u8) void {
    var h = Sha256.init();
    h.update(bytes);
    h.final(out);
}

// ---------------------------------------------------------------------------
// The D4 chain receipt
// ---------------------------------------------------------------------------

/// The measured stage names. `exec` reuses the format verbatim for Part
/// II's per-exec measurements (M113c).
pub const Stage = enum {
    loader,
    kernel,
    exec,

    pub fn name(self: Stage) []const u8 {
        return @tagName(self);
    }
};

/// Write the 64 lowercase hex chars of `digest` into `out` (needs 64
/// bytes); returns 64.
pub fn hex_digest(out: []u8, digest: *const [digest_len]u8) usize {
    const digits = "0123456789abcdef";
    var i: usize = 0;
    while (i < digest_len) : (i += 1) {
        out[i * 2] = digits[digest[i] >> 4];
        out[i * 2 + 1] = digits[digest[i] & 0xf];
    }
    return 2 * digest_len;
}

/// Format one receipt line into `out`:
/// `RCPT stage=<stage> sha256=<64-hex> verdict=<verdict>[ name=<name>][ word=<word>] uid=<uid>\n`
///
/// Returns the byte count written (the line is newline-terminated).
/// `verdict` is the raw verdict word — `measured`, `unmeasured`, or a
/// `refused:`/`audit:`-prefixed refusal name — so the formatter does not
/// need to enumerate Part II's refusal names. `uid` is the acting
/// principal (M173c): always the last field, always present. `out` must
/// be at least `receipt_max` bytes (the longest line the format can
/// produce).
pub const receipt_max: usize = 192;

pub fn receipt_line(
    out: []u8,
    stage: Stage,
    digest: *const [digest_len]u8,
    verdict: []const u8,
    name: ?[]const u8,
    word: ?[]const u8,
    uid: u32,
) usize {
    var n: usize = 0;
    n += copy_into(out[n..], "RCPT stage=");
    n += copy_into(out[n..], stage.name());
    n += copy_into(out[n..], " sha256=");
    n += hex_digest(out[n..], digest);
    n += copy_into(out[n..], " verdict=");
    n += copy_into(out[n..], verdict);
    if (name) |v| {
        n += copy_into(out[n..], " name=");
        n += copy_into(out[n..], v);
    }
    if (word) |v| {
        n += copy_into(out[n..], " word=");
        n += copy_into(out[n..], v);
    }
    n += copy_into(out[n..], " uid=");
    var num: [10]u8 = undefined;
    const digits = std.fmt.bufPrint(&num, "{d}", .{uid}) catch unreachable;
    n += copy_into(out[n..], digits);
    out[n] = '\n';
    return n + 1;
}

fn copy_into(dst: []u8, src: []const u8) usize {
    @memcpy(dst[0..src.len], src);
    return src.len;
}

// ---------------------------------------------------------------------------
// Host tests — the FIPS 180-4 KATs the userland library pins (the ADR 0023
// D2 drift guard) plus the D4 receipt shape.
// ---------------------------------------------------------------------------

test "measure: FIPS 180-4 empty message" {
    var out: [32]u8 = undefined;
    hash(&out, "");
    const exp = try hex("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "measure: FIPS 180-4 \"abc\"" {
    var out: [32]u8 = undefined;
    hash(&out, "abc");
    const exp = try hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "measure: FIPS 180-4 56-byte multi-block message" {
    var out: [32]u8 = undefined;
    hash(&out, "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq");
    const exp = try hex("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "measure: streaming across every chunk boundary equals one-shot" {
    const msg = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    var one: [32]u8 = undefined;
    hash(&one, msg);
    var chunk: usize = 1;
    while (chunk <= msg.len) : (chunk += 1) {
        var h = Sha256.init();
        var i: usize = 0;
        while (i < msg.len) : (i += chunk) h.update(msg[i..@min(i + chunk, msg.len)]);
        var got: [32]u8 = undefined;
        h.final(&got);
        try std.testing.expectEqualSlices(u8, &one, &got);
    }
}

test "measure: FIPS 180-4 one million 'a' (streaming)" {
    var h = Sha256.init();
    const block = @as([1000]u8, @splat(@as(u8, 'a')));
    for (0..1000) |_| h.update(&block);
    var out: [32]u8 = undefined;
    h.final(&out);
    const exp = try hex("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "measure: receipt line is the D4 shape" {
    const digest = try hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    var buf: [receipt_max]u8 = undefined;
    const n = receipt_line(&buf, .loader, &digest, "measured", null, null, 0);
    try std.testing.expectEqualStrings(
        "RCPT stage=loader sha256=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad verdict=measured uid=0\n",
        buf[0..n],
    );
}

test "measure: receipt line carries the Part II name/word extras" {
    const digest = try hex("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    var buf: [receipt_max]u8 = undefined;
    const n = receipt_line(&buf, .exec, &digest, "audit:word_denied", "NETCAT.ELF", "net", 2000);
    try std.testing.expectEqualStrings(
        "RCPT stage=exec sha256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 verdict=audit:word_denied name=NETCAT.ELF word=net uid=2000\n",
        buf[0..n],
    );
}

test "measure: uid is the receipt's last field and the widest uid fits" {
    const digest = try hex("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    var buf: [receipt_max]u8 = undefined;
    const n = receipt_line(&buf, .exec, &digest, "measured", null, null, 4294967295);
    try std.testing.expectEqualStrings(
        "RCPT stage=exec sha256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 verdict=measured uid=4294967295\n",
        buf[0..n],
    );
}

test "measure: stage names are the D4 vocabulary" {
    try std.testing.expectEqualStrings("loader", Stage.loader.name());
    try std.testing.expectEqualStrings("kernel", Stage.kernel.name());
    try std.testing.expectEqualStrings("exec", Stage.exec.name());
}

fn hex(comptime s: []const u8) ![s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return error.BadHex;
    return out;
}
