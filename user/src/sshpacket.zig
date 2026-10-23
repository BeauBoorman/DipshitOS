//! census (M188e, #3190): SSHPACKET.BIN — gate-referenced: live-ssh-packet.
//! SSHPACKET.BIN — M51 SSH1 (#1168) class-B proof program.
//!
//! The guest half of the `live-ssh-packet` gate. It dials the deterministic
//! host responder (slot 30), then uses the SSH1 stream adapter
//! (`user/src/lib/ssh/stream.zig`) to reassemble ONE SSH binary packet that
//! the responder sends **split across many ≤192-byte TCP segments, paced one
//! segment per guest ACK** — the only shape the kernel's one-slot,
//! reassembly-free RX can carry.
//!
//! On success it prints `sshpacket: len=<N> sha256=<hex>` where the digest is
//! SHA-256 over the reassembled payload; the gate's Python computes the same
//! digest from the bytes it handed the responder, so framing + reassembly
//! are proven end to end (not just "some bytes arrived"). It exits 0.
//!
//! DSK3 segmented build (writable .bss): the adapter buffer is a static
//! global, per ADR 0025 D6 ("bounded caller-owned (static BSS) buffer").

const std = @import("std");
const ui = @import("ui");
const stream = @import("lib/ssh/stream.zig");
const sha256 = @import("lib/crypto/sha256.zig");

pub const default_ip: u32 = 0x0a000002; // 10.0.0.2
pub const default_port: u16 = 2222;
pub const exit_ok: u32 = 0;
pub const exit_connect: u32 = 1;
pub const exit_protocol: u32 = 2;
/// Generous poll budget: the responder paces one segment per ACK, so a
/// multi-segment packet takes several yield/retry rounds.
pub const poll_budget: usize = 2_000_000;

/// The bounded adapter buffer (one maximum SSH frame), static BSS.
var rx_buf: [stream.capacity]u8 align(16) = undefined;

const hex_digits = "0123456789abcdef";

fn hexLower(out: []u8, bytes: []const u8) []const u8 {
    var n: usize = 0;
    for (bytes) |b| {
        if (n + 2 > out.len) break;
        out[n] = hex_digits[b >> 4];
        out[n + 1] = hex_digits[b & 0x0f];
        n += 2;
    }
    return out[0..n];
}

fn writeDec(value: usize) void {
    var tmp: [20]u8 = undefined;
    var i: usize = tmp.len;
    var v = value;
    if (v == 0) {
        ui.write_console("0");
        return;
    }
    while (v > 0) {
        i -= 1;
        tmp[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    ui.write_console(tmp[i..]);
}

pub export fn _start() callconv(.c) noreturn {
    ui.write_console("sshpacket: starting\n");

    const rc = ui.tcp_connect(default_ip, default_port);
    if (rc < 0) {
        ui.write_console("sshpacket: connect failed\n");
        ui.exit_process(exit_connect);
    }
    ui.write_console("sshpacket: connected\n");

    var s = stream.Stream.init(&rx_buf, stream.sysOps());

    var payload: ?[]const u8 = null;
    var spins: usize = 0;
    while (payload == null and spins < poll_budget) : (spins += 1) {
        payload = s.parse() catch {
            ui.write_console("sshpacket: protocol fail-closed\n");
            ui.exit_process(exit_protocol);
        };
        if (payload == null) ui.yield_task();
    }
    if (payload == null) {
        ui.write_console("sshpacket: timeout\n");
        ui.exit_process(exit_protocol);
    }

    var digest: [sha256.digest_len]u8 = undefined;
    sha256.sha256(&digest, payload.?);
    var hexbuf: [2 * sha256.digest_len]u8 = undefined;
    const hex = hexLower(&hexbuf, &digest);

    ui.write_console("sshpacket: len=");
    writeDec(payload.?.len);
    ui.write_console(" sha256=");
    ui.write_console(hex);
    ui.write_console("\n");

    s.close();
    ui.exit_process(exit_ok);
}

test "sshpacket: hexLower matches a known digest" {
    const bytes = [_]u8{ 0x00, 0x0f, 0xa5, 0xff };
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("000fa5ff", hexLower(&out, &bytes));
}
