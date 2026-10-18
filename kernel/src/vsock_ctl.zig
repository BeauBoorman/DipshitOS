//! The `virelai-ctl/1` guest-side client (M115b, issue #2461, ADR 0056) —
//! the kernel half of the guest→host control channel.
//!
//! Driven by the monitor's `vsock ctl <verb>` command: one command is one
//! connection — connect to the host's `--vsock-ctl-port` listener, read the
//! greeting's challenge, answer `HMAC-SHA256(key, domain || 0x00 ||
//! challenge)` from the `vsock-ctl` SECRETS.TXT row (a uid_system credential
//! the kernel store serves to no EL0 reader), send the request line, print
//! the reply's verdict fields, shut down. The wire grammar is pinned in the
//! ADR; `user/go/vsockctl` is the same protocol for the EL0 binding the
//! ABI-slot follow-up lands.
//!
//! Three exercise modes exist for the gate's auth negatives, and only for
//! that: `badauth` corrupts the MAC, `replay` re-uses a captured auth line
//! on a fresh connection (the new challenge makes it `auth_failed`), and
//! `dup` repeats request id 1 inside one session (`replay`). They are part
//! of the refusal vocabulary's evidence, not extra verbs.
//!
//! Never-logged: the key, the challenge and the MAC never reach serial —
//! markers carry ids, codes and port numbers only. No libc, no allocation.

const std = @import("std");
const console = @import("console.zig");
const measure = @import("measure.zig");
const secret = @import("secret.zig");
const virtio_vsock = @import("virtio_vsock.zig");

/// The runner's default `--vsock-ctl-port`; `vsock ctl` connects there.
/// Distinct from the M115a probe listener (1208) — a ctl session is a
/// whole protocol, not an accept-and-log verdict.
pub const ctl_port: u32 = 1209;

/// The auth domain (ADR 0056 D2) — distinct from VIRELAIOS-AUTH/1 and
/// VIRELAI-AGENT/1 so captures are not portable between services.
pub const auth_domain = "VIRELAI-CTL/1 hmac-sha256";

/// The SECRETS.TXT row both ends read: a `uid_system` (0) credential,
/// app-unbound — the kernel's own client is its only in-guest consumer.
pub const secret_key = "vsock-ctl";
pub const secret_uid: u32 = 0;

/// Line bounds (ADR 0056 D1): the greeting/answer ≤ 256 pre-auth and every
/// later line ≤ 1024 — the client's own lines stay far under both.
pub const pre_auth_max: usize = 256;
pub const line_max: usize = 1024;

/// Encodable request words: `[A-Za-z0-9._-]` only, so a verb or name can
/// never break the JSON line it rides. Grammar refusals belong to the
/// host (`name_rejected` et al.) — the kernel encodes, the host judges.
fn encodable(word: []const u8) bool {
    if (word.len == 0 or word.len > 31) return false;
    for (word) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// RFC 2104 HMAC-SHA256 over the kernel's measure.Sha256. `key` is the
/// secret row's value bytes verbatim (≤ 64 — the row's bound is the HMAC
/// block size, so no key-hashing branch is ever taken).
fn hmacSha256(key: []const u8, msg: []const u8, out: *[measure.digest_len]u8) void {
    var kpad: [64]u8 = @splat(0);
    if (key.len > 64) {
        var kh: [measure.digest_len]u8 = undefined;
        measure.hash(&kh, key);
        @memcpy(kpad[0..measure.digest_len], &kh);
    } else {
        @memcpy(kpad[0..key.len], key);
    }
    var inner = measure.Sha256.init();
    var pad: [64]u8 = undefined;
    for (kpad, 0..) |b, i| pad[i] = b ^ 0x36;
    inner.update(&pad);
    inner.update(msg);
    var ih: [measure.digest_len]u8 = undefined;
    inner.final(&ih);
    var outer = measure.Sha256.init();
    for (kpad, 0..) |b, i| pad[i] = b ^ 0x5c;
    outer.update(&pad);
    outer.update(&ih);
    outer.final(out);
}

/// Look up the `vsock-ctl` uid_system row's value in the kernel secret
/// store. Returns the value bytes (≤ 64, copied to `out`), or null when
/// the row is absent — the fail-closed `no_credential` posture.
fn ctlKey(out: *[64]u8) ?[]const u8 {
    var recs: [secret.max_secret_entries]secret.SecretRecord = undefined;
    const n = secret.records_for(.{ .uid = secret_uid }, &recs);
    for (recs[0..n]) |*r| {
        const k = r.key[0..@as(usize, r.key_len)];
        if (std.mem.eql(u8, k, secret_key)) {
            const v = r.val[0..@as(usize, r.val_len)];
            @memcpy(out[0..v.len], v);
            return out[0..v.len];
        }
    }
    return null;
}

/// Minimal fixed-shape extraction — the ctl grammar's keys are unique,
/// strings carry no escapes, and `id`/`ok` are the only numeric/bool
/// reads. Anything outside the shape reports malformed, never guessed.
/// `{"...","key":"<hex or word>"}` → the value bytes, or null.
fn jsonStr(line: []const u8, key: []const u8) ?[]const u8 {
    var pat: [32]u8 = undefined;
    if (key.len + 3 > pat.len) return null;
    const pat_str = std.fmt.bufPrint(&pat, "\"{s}\":\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, line, pat_str) orelse return null;
    const rest = line[at + pat_str.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

/// `"ok":true|false` → the verdict, or null when absent/malformed.
fn jsonOk(line: []const u8) ?bool {
    const at = std.mem.indexOf(u8, line, "\"ok\":") orelse return null;
    const rest = line[at + 5 ..];
    if (rest.len >= 4 and std.mem.eql(u8, rest[0..4], "true")) return true;
    if (rest.len >= 5 and std.mem.eql(u8, rest[0..5], "false")) return false;
    return null;
}

/// `"id":N` → the decimal id, or null.
fn jsonId(line: []const u8) ?u32 {
    const at = std.mem.indexOf(u8, line, "\"id\":") orelse return null;
    var rest = line[at + 5 ..];
    var v: u32 = 0;
    var digits: usize = 0;
    while (rest.len > 0 and rest[0] >= '0' and rest[0] <= '9' and digits < 10) {
        v = v * 10 + (rest[0] - '0');
        rest = rest[1..];
        digits += 1;
    }
    return if (digits > 0) v else null;
}

fn hexNibble(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

/// The greeting's `"challenge":"<64 hex>"` decoded, or null.
fn challengeFrom(line: []const u8, out: *[32]u8) bool {
    const hex = jsonStr(line, "challenge") orelse return false;
    if (hex.len != 64) return false;
    for (0..32) |i| {
        const hi = hexNibble(hex[i * 2]) orelse return false;
        const lo = hexNibble(hex[i * 2 + 1]) orelse return false;
        out[i] = hi << 4 | lo;
    }
    return true;
}

const RecvLine = union(enum) {
    line: usize, // length of `buf`'s content (LF stripped)
    eof,
    reset,
    timeout,
    too_long,
};

/// Poll the connection until `buf` holds one LF-terminated line. The
/// poll budget is the connect probe's (~1.5–2 s); a response line is a
/// single packet in practice, and the bound keeps a stuck peer honest.
fn recvLine(conn: *virtio_vsock.Conn, buf: []u8) RecvLine {
    var len: usize = 0;
    var spins: usize = 0;
    var packet: [2048]u8 = undefined;
    while (spins < 320_000_000) : (spins += 1) {
        const r = virtio_vsock.recv(conn, &packet);
        switch (r.verdict) {
            .none => continue,
            .reset => return .reset,
            .eof => {
                if (len == 0) return .eof;
                return .{ .line = len };
            },
            .data => {
                var i: usize = 0;
                while (i < r.len) : (i += 1) {
                    if (packet[i] == '\n') return .{ .line = len };
                    if (len >= buf.len) return .too_long;
                    buf[len] = packet[i];
                    len += 1;
                }
            },
        }
    }
    return .timeout;
}

/// Print a reply line's verdict as `vsock-ctl: reply [id=N] ok=<b>
/// [code=<c>]` — the assertable marker; refusal replies may carry no id.
/// A reply without a readable verdict reports itself as malformed.
fn printReply(c: console.Console, line: []const u8) void {
    c.puts("vsock-ctl: reply");
    if (jsonId(line)) |id| {
        c.puts(" id=");
        c.print_u64(id);
    }
    const ok = jsonOk(line) orelse {
        c.print_line(" malformed");
        return;
    };
    c.puts(if (ok) " ok=true" else " ok=false");
    if (jsonStr(line, "code")) |code| {
        c.puts(" code=");
        c.puts(code);
    }
    c.puts("\n");
}

const Mode = enum { normal, badauth, replay, dup };

/// `vsock ctl <verb> [name]` plus the exercise modes. Prints one
/// `vsock-ctl:` verdict line per step the gate needs to see.
pub fn run(c: console.Console, args: []const []const u8) void {
    if (!virtio_vsock.vs_ready) {
        c.print_line("vsock-ctl: refuse no_device");
        return;
    }
    var mode: Mode = .normal;
    var rest = args;
    if (args.len > 0) {
        if (std.mem.eql(u8, args[0], "badauth")) {
            mode = .badauth;
            rest = args[1..];
        } else if (std.mem.eql(u8, args[0], "replay")) {
            mode = .replay;
            rest = args[1..];
        } else if (std.mem.eql(u8, args[0], "dup")) {
            mode = .dup;
            rest = args[1..];
        }
    }
    if (rest.len == 0 or rest.len > 2) {
        c.print_line("vsock-ctl: usage 'vsock ctl [badauth|replay|dup] <verb> [name]'");
        return;
    }
    const verb = rest[0];
    const name: []const u8 = if (rest.len == 2) rest[1] else "";
    if (!encodable(verb) or (rest.len == 2 and !encodable(name))) {
        c.print_line("vsock-ctl: refuse bad_arg");
        return;
    }
    var keybuf: [64]u8 = undefined;
    const key = ctlKey(&keybuf) orelse {
        c.print_line("vsock-ctl: refuse no_credential");
        return;
    };
    // A captured auth line, for the replay mode's second connection.
    var captured: [128]u8 = undefined;
    var captured_len: usize = 0;

    var conn: virtio_vsock.Conn = .{};
    switch (virtio_vsock.open(ctl_port, &conn)) {
        .connected => {},
        .refused => {
            c.print_line("vsock-ctl: connect refused");
            return;
        },
        .timeout => {
            c.print_line("vsock-ctl: connect timeout");
            return;
        },
    }
    c.puts("vsock-ctl: connected port=");
    c.print_u64(ctl_port);
    c.puts("\n");

    // ---- greeting + auth -------------------------------------------------
    var line: [line_max]u8 = undefined;
    var auth_line: [96]u8 = undefined;
    var auth_len: usize = 0;
    switch (recvLine(&conn, &line)) {
        .line => |n| {
            if (n > pre_auth_max) {
                c.print_line("vsock-ctl: greeting too_long");
                virtio_vsock.rst(&conn);
                return;
            }
            var challenge: [32]u8 = undefined;
            if (!challengeFrom(line[0..n], &challenge)) {
                c.print_line("vsock-ctl: refuse bad_greeting");
                virtio_vsock.rst(&conn);
                return;
            }
            var mac: [measure.digest_len]u8 = undefined;
            var msg: [64]u8 = undefined;
            const dn = auth_domain.len;
            @memcpy(msg[0..dn], auth_domain);
            msg[dn] = 0;
            @memcpy(msg[dn + 1 .. dn + 33], &challenge);
            hmacSha256(key, msg[0 .. dn + 33], &mac);
            if (mode == .badauth) mac[0] ^= 0xff;
            var hexbuf: [64]u8 = undefined;
            _ = measure.hex_digest(&hexbuf, &mac);
            auth_len = (std.fmt.bufPrint(&auth_line, "{{\"auth\":\"{s}\"}}\n", .{hexbuf[0..64]}) catch unreachable).len;
        },
        else => {
            c.print_line("vsock-ctl: greeting failed");
            virtio_vsock.rst(&conn);
            return;
        },
    }
    if (virtio_vsock.send(&conn, auth_line[0..auth_len]) != .ok) {
        c.print_line("vsock-ctl: send auth failed");
        virtio_vsock.rst(&conn);
        return;
    }
    @memcpy(captured[0..auth_len], auth_line[0..auth_len]);
    captured_len = auth_len;

    switch (recvLine(&conn, &line)) {
        .line => |n| {
            if (jsonOk(line[0..n]) != true) {
                c.puts("vsock-ctl: auth refused");
                if (jsonStr(line[0..n], "code")) |code| {
                    c.puts(" code=");
                    c.puts(code);
                }
                c.puts("\n");
                virtio_vsock.rst(&conn);
                return;
            }
            c.print_line("vsock-ctl: authed");
        },
        .eof, .reset => {
            c.print_line("vsock-ctl: auth refused code=conn_lost");
            return;
        },
        else => {
            c.print_line("vsock-ctl: auth timeout");
            virtio_vsock.rst(&conn);
            return;
        },
    }

    // ---- replay mode: reconnect and offer the captured auth verbatim -----
    if (mode == .replay) {
        virtio_vsock.shutdown(&conn);
        var conn2: virtio_vsock.Conn = .{};
        // Conn A's close has to settle on the host queue before the next
        // connect lands — a bare retry-into-accept races VZ's teardown,
        // so spin briefly between attempts (the monitor context has no
        // sleep primitive; this is a negative-exercise path).
        var opened = false;
        for (0..4) |_| {
            var settle: usize = 0;
            while (settle < 40_000_000) : (settle += 1) {
                std.mem.doNotOptimizeAway(settle);
            }
            if (virtio_vsock.open(ctl_port, &conn2) == .connected) {
                opened = true;
                break;
            }
        }
        if (!opened) {
            c.print_line("vsock-ctl: replay reconnect failed");
            return;
        }
        // Drain the fresh greeting; the challenge inside differs — that is
        // the whole point of the negative.
        _ = recvLine(&conn2, &line);
        _ = virtio_vsock.send(&conn2, captured[0..captured_len]);
        switch (recvLine(&conn2, &line)) {
            .line => |n| {
                c.puts("vsock-ctl: replay refused");
                if (jsonStr(line[0..n], "code")) |code| {
                    c.puts(" code=");
                    c.puts(code);
                }
                c.puts("\n");
            },
            else => c.print_line("vsock-ctl: replay conn_lost"),
        }
        virtio_vsock.rst(&conn2);
        return;
    }

    // ---- request(s) -------------------------------------------------------
    var req: [128]u8 = undefined;
    const req_len = (if (rest.len == 2)
        std.fmt.bufPrint(&req, "{{\"id\":1,\"verb\":\"{s}\",\"name\":\"{s}\"}}\n", .{ verb, name }) catch unreachable
    else
        std.fmt.bufPrint(&req, "{{\"id\":1,\"verb\":\"{s}\"}}\n", .{verb}) catch unreachable).len;
    if (virtio_vsock.send(&conn, req[0..req_len]) != .ok) {
        c.print_line("vsock-ctl: send request failed");
        virtio_vsock.rst(&conn);
        return;
    }
    switch (recvLine(&conn, &line)) {
        .line => |n| printReply(c, line[0..n]),
        .eof => c.print_line("vsock-ctl: reply eof"),
        .reset => c.print_line("vsock-ctl: reply reset"),
        else => c.print_line("vsock-ctl: reply timeout"),
    }

    // dup: the identical request line again — id still 1, the host's name
    // for it is `replay`.
    if (mode == .dup) {
        _ = virtio_vsock.send(&conn, req[0..req_len]);
        switch (recvLine(&conn, &line)) {
            .line => |n| printReply(c, line[0..n]),
            else => c.print_line("vsock-ctl: dup reply lost"),
        }
    }

    virtio_vsock.shutdown(&conn);
    c.print_line("vsock-ctl: closed");
}

// ---------------------------------------------------------------------------
// Host tests — the wire bytes and the auth math are the ADR-pinned shape
// ---------------------------------------------------------------------------

test "vsock_ctl: auth domain + pinned HMAC vector (ADR 0056 D2)" {
    try std.testing.expectEqualStrings("VIRELAI-CTL/1 hmac-sha256", auth_domain);
    var key: [64]u8 = undefined;
    for (0..32) |i| {
        key[i * 2] = 'a';
        key[i * 2 + 1] = '5';
    } // ASCII 'a5' repeated — the ADR key
    var msg: [64]u8 = undefined;
    @memcpy(msg[0..auth_domain.len], auth_domain);
    msg[auth_domain.len] = 0;
    var challenge: [32]u8 = undefined;
    for (0..32) |i| challenge[i] = @intCast(i);
    @memcpy(msg[auth_domain.len + 1 .. auth_domain.len + 33], &challenge);
    var mac: [measure.digest_len]u8 = undefined;
    hmacSha256(&key, msg[0 .. auth_domain.len + 33], &mac);
    var hexbuf: [64]u8 = undefined;
    _ = measure.hex_digest(&hexbuf, &mac);
    try std.testing.expectEqualStrings(
        "87b459ff70564dd354e1415d16618cc768bf5f2181124a2b495c73b01e274b6c",
        &hexbuf,
    );
}

test "vsock_ctl: fixed-shape reply extraction" {
    const ok_line = "{\"id\":1,\"ok\":true,\"result\":{\"verb\":\"suspend\"}}";
    try std.testing.expectEqual(@as(?u32, 1), jsonId(ok_line));
    try std.testing.expectEqual(@as(?bool, true), jsonOk(ok_line));
    const err_line = "{\"id\":2,\"ok\":false,\"error\":{\"code\":\"replay\",\"message\":\"id must increase\"}}";
    try std.testing.expectEqual(@as(?u32, 2), jsonId(err_line));
    try std.testing.expectEqual(@as(?bool, false), jsonOk(err_line));
    try std.testing.expectEqualStrings("replay", jsonStr(err_line, "code").?);
    const greeting = "{\"proto\":\"virelai-ctl/1\",\"auth\":\"hmac-sha256\",\"challenge\":\"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\"}";
    var ch: [32]u8 = undefined;
    try std.testing.expect(challengeFrom(greeting, &ch));
    for (0..32) |i| try std.testing.expectEqual(@as(u8, @intCast(i)), ch[i]);
    var bad: [32]u8 = undefined;
    try std.testing.expect(!challengeFrom("{\"challenge\":\"xyz\"}", &bad));
}
