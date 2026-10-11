//! M50 TS4 (#1138, ADR 0024 D6): the shared net-front-end argv parser.
//!
//! Both `SH.BIN` (serial/remote shell) and `TERM.BIN` (windowed shell) accept
//! the same optional front-end argument:
//!
//!     <app>                -> serial by default (SH) / window (TERM)
//!     <app> net [port] [open]
//!
//! `port` defaults to 2323. Without `open` the caller must have a credential
//! in the TS5 store and the session authenticates with the delegated
//! challenge-response handshake (the kernel frames the challenge; the
//! process verifies and votes). With no credential the caller REFUSES to
//! listen unless `open` is passed explicitly — the documented insecure
//! trusted-network mode that reproduces M46's accept-immediately behavior.
//! Fail closed by default. The argv block is the kernel's card-3e
//! packaging (`argc` in x0, block VA in x1): 256-byte slots since M71m.

const std = @import("std");

/// The default TCP port when `net` gives no port (SH7).
pub const default_port: u16 = 2323;

pub const Args = struct {
    port: u16,
    /// The explicit insecure mode: accept without authentication.
    open: bool = false,
};

/// Read one 256-byte NUL-terminated argv slot from the kernel-packaged block.
pub fn argSlot(block: [*]const u8, i: usize) []const u8 {
    const slot = (block + i * 256)[0..256];
    var n: usize = 0;
    while (n < slot.len and slot[n] != 0) n += 1;
    return slot[0..n];
}

/// `net [port] [open]` — null when the first argument is not `net` (the
/// caller then uses its default front-end). A malformed port or an unknown
/// third argument also returns null (the caller rejects the attach).
pub fn parse(argc: u64, argv_va: u64) ?Args {
    if (argc == 0 or argv_va == 0) return null;
    const block: [*]const u8 = @ptrFromInt(argv_va);
    if (!std.mem.eql(u8, argSlot(block, 0), "net")) return null;
    var port: u16 = default_port;
    if (argc >= 2) {
        const arg = argSlot(block, 1);
        if (arg.len > 0) port = std.fmt.parseInt(u16, arg, 10) catch return null;
    }
    var open = false;
    if (argc >= 3) {
        const arg = argSlot(block, 2);
        if (arg.len > 0) {
            if (!std.mem.eql(u8, arg, "open")) return null;
            open = true;
        }
    }
    return .{ .port = port, .open = open };
}

test "netargs: parse defaults, port, and the explicit open mode" {
    var block = @as([(3 * 256)]u8, @splat(@as(u8, 0)));
    const write = struct {
        fn f(b: []u8, i: usize, s: []const u8) void {
            @memcpy(b[i * 256 ..][0..s.len], s);
        }
    }.f;
    // Just `net` -> default port, auth required (fail closed).
    write(&block, 0, "net");
    const a = parse(1, @intFromPtr(&block)).?;
    try std.testing.expectEqual(default_port, a.port);
    try std.testing.expect(!a.open);
    // `net 4444 open`.
    @memset(&block, 0);
    write(&block, 0, "net");
    write(&block, 1, "4444");
    write(&block, 2, "open");
    const b = parse(3, @intFromPtr(&block)).?;
    try std.testing.expectEqual(@as(u16, 4444), b.port);
    try std.testing.expect(b.open);
    // An empty third slot is the default posture, not an error.
    @memset(&block, 0);
    write(&block, 0, "net");
    write(&block, 1, "4444");
    const c = parse(3, @intFromPtr(&block)).?;
    try std.testing.expect(!c.open);
    // A different first arg is not the net front-end.
    @memset(&block, 0);
    write(&block, 0, "exec");
    try std.testing.expect(parse(1, @intFromPtr(&block)) == null);
    // An unknown mode word is rejected (never silently treated as open).
    @memset(&block, 0);
    write(&block, 0, "net");
    write(&block, 1, "4444");
    write(&block, 2, "secret");
    try std.testing.expect(parse(3, @intFromPtr(&block)) == null);
    // A bad port is rejected.
    @memset(&block, 0);
    write(&block, 0, "net");
    write(&block, 1, "99999");
    try std.testing.expect(parse(2, @intFromPtr(&block)) == null);
}
