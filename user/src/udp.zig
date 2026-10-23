//! census (M188e, #3190): UDP.BIN — gate-referenced: live-net-udp-syscall.
//! VirelaiOS fifth ESP user program — UDP.BIN (milestone five, card N6,
//! claim 1384 — the UDP syscall seam).
//!
//! The FIRST network syscall user: this program exercises the milestone-
//! five UDP layer through the ADR 0007 slots 9/10/11
//! (`sys_udp_listen` / `sys_udp_send` / `sys_udp_recv`) end to end,
//! entirely from EL0 — the monitor's `net udp` surface is NOT used:
//!
//!   1. `sys_udp_listen(7000)` binds the kernel listen table (slot 9)
//!      -> prints `udp: listen ok`.
//!   2. LOOPBACK from EL0: `sys_udp_send(10.0.0.1, 7000, "ping", 4)`
//!      (slot 10 — OUR OWN IP, the N5 loopback path, no device round
//!      trip) then `sys_udp_recv(7000, buf, 72)` (slot 11) -> the
//!      12-byte datagram (8-byte header + the 4-byte payload); the
//!      program skips the header and prints the payload as text:
//!      `udp: loop ping`.
//!   3. Round trip: `sys_udp_send(10.0.0.2, 9999, "ping", 4)` — the
//!      peer MAC must be in the ARP table (the gate resolves it first
//!      via `net arp 10.0.0.2`; the shell idle loop drains the reply,
//!      so a send refused with EINVAL is RETRIED with a cooperative
//!      yield — bounded) — then poll `sys_udp_recv(7000, buf, 72)`
//!      until the host's `--net-udp-respond 10.0.0.2:9999` answer (the
//!      SAME payload echoed) lands: `udp: got ping`.
//!   4. `sys_exit(17)` — the UDP protocol number, a distinct status the
//!      live gate's `procs UDP.BIN exited status=17` assertion greps.
//!
//! The addresses are the deterministic gate constants (10.0.0.1 own,
//! 10.0.0.2 host, ports 7000/9999, payload "ping") — one gate, one
//! shape, pinned as `pub const`s below so the host tests cannot drift
//! from the payload's asm (the peer.zig pattern). This is a plain EL0
//! program: naked-asm `_start`, fixed-register syscall ABI, no libc.
//!
//! The fail-safe parks (label 0) are only reachable on a wrong syscall
//! result or an exhausted retry budget — the runner times out (the gate
//! fails) unless the full expected transcript appears.

const std = @import("std");

/// The port UDP.BIN binds (slot 9) and sends from/to (slots 10/11).
pub const listen_port: u32 = 7000;
/// The host's UDP port (`--net-udp-respond 10.0.0.2:9999`).
pub const peer_port: u32 = 9999;
/// Our own IP in network byte order (10.0.0.1) — the loopback send
/// target (slot 10's `ip` argument is the 4 octets big-endian).
pub const own_ip: u32 = 0x0a000001;
/// The peer IP in network byte order (10.0.0.2) — the round-trip target.
pub const peer_ip: u32 = 0x0a000002;
/// The exact payload bytes (4) — echoed byte-exact by the loopback and
/// the host's UDP answer; printed as text after the 8-byte header.
pub const payload: []const u8 = "ping";
/// The exit status (the UDP protocol number — a distinct grep target).
pub const exit_status: u32 = 17;
/// The exact marker lines UDP.BIN writes (the live gate's grep targets).
pub const listen_ok_line: []const u8 = "udp: listen ok\n";
pub const loop_prefix: []const u8 = "udp: loop ";
pub const got_prefix: []const u8 = "udp: got ";
/// The EINVAL (-1) marker lines (the negative seam tests).
pub const recv_err_line: []const u8 = "udp: recv err -1\n";
pub const send_err_line: []const u8 = "udp: send err -1\n";

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// Phase 1 — sys_udp_listen(7000) (slot 9): 0 on success.
        \\mov x0, #7000
        \\mov x8, #9
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f // listen refused (duplicate/full/0): park, honest fail
        \\mov x0, #1
        \\adr x1, 1f // "udp: listen ok\n" (15 bytes)
        \\mov x2, #15
        \\mov x8, #1
        \\svc #0
        \\// Phase 2 — LOOPBACK from EL0: sys_udp_send(own_ip 10.0.0.1,
        \\// 7000, "ping", 4) (slot 10). The kernel's net_udp_send sees
        \\// OUR OWN IP and takes the N5 loopback path — no device
        \\// round trip. Returns the sent payload length (4).
        \\movz x0, #0x0a00, lsl #16
        \\movk x0, #0x0001 // 0x0a000001 = 10.0.0.1 (network byte order)
        \\mov x1, #7000
        \\adr x2, 2f // "ping"
        \\mov x3, #4
        \\mov x8, #10
        \\svc #0
        \\cmp x0, #4
        \\b.ne 0f // not sent: park
        \\// sys_udp_recv(7000, sp, 72) (slot 11): the loopbacked
        \\// 12-byte datagram (8-byte header + the 4-byte payload).
        \\sub sp, sp, #96
        \\mov x0, #7000
        \\mov x1, sp
        \\mov x2, #72
        \\mov x8, #11
        \\svc #0
        \\cmp x0, #12
        \\b.ne 0f // not the 12-byte datagram: park
        \\// "udp: loop " (10 bytes) + the payload (sp+8, 4 bytes).
        \\mov x0, #1
        \\adr x1, 3f
        \\mov x2, #10
        \\mov x8, #1
        \\svc #0
        \\mov x0, #1
        \\add x1, sp, #8
        \\mov x2, #4
        \\mov x8, #1
        \\svc #0
        \\mov x0, #1
        \\adr x1, 5f // newline
        \\mov x2, #1
        \\mov x8, #1
        \\svc #0
        \\add sp, sp, #96
        \\// Phase 3 — round trip: sys_udp_send(peer_ip 10.0.0.2, 9999,
        \\// "ping", 4) (slot 10). The peer's MAC must be in the ARP
        \\// table (the gate's `net arp 10.0.0.2` resolves it; the shell
        \\// idle loop drains the reply between quanta). A refusal
        \\// (EINVAL — peer unresolved / transport not yet ready) is
        \\// RETRIED with a cooperative yield, bounded (100).
        \\mov x20, xzr // retry counter
        \\6:
        \\movz x0, #0x0a00, lsl #16
        \\movk x0, #0x0002 // 0x0a000002 = 10.0.0.2 (network byte order)
        \\mov x1, #9999
        \\adr x2, 2f // "ping"
        \\mov x3, #4
        \\mov x8, #10
        \\svc #0
        \\cmp x0, #4
        \\b.eq 7f // sent
        \\add x20, x20, #1
        \\cmp x20, #100
        \\b.hi 0f // exhausted: park, honest fail
        \\mov x8, #2 // cooperative yield (slot 2)
        \\svc #0
        \\b 6b
        \\// Phase 4 — poll sys_udp_recv(7000, sp, 72) until the host's
        \\// answer (--net-udp-respond 10.0.0.2:9999, the SAME payload
        \\// echoed) lands. Bounded (1000).
        \\7:
        \\mov x21, xzr // poll counter
        \\8:
        \\sub sp, sp, #96
        \\mov x0, #7000
        \\mov x1, sp
        \\mov x2, #72
        \\mov x8, #11
        \\svc #0
        \\cmp x0, #12
        \\b.eq 9f // the 12-byte answer
        \\cmp x0, #0
        \\b.ne 0f // wrong result: park, honest fail
        \\add sp, sp, #96
        \\add x21, x21, #1
        \\cmp x21, #1000
        \\b.hi 0f // never arrived: park, honest fail
        \\mov x8, #2 // cooperative yield (slot 2)
        \\svc #0
        \\b 8b
        \\9:
        \\// "udp: got " (9 bytes) + the payload (sp+8, 4 bytes).
        \\mov x0, #1
        \\adr x1, 4f
        \\mov x2, #9
        \\mov x8, #1
        \\svc #0
        \\mov x0, #1
        \\add x1, sp, #8
        \\mov x2, #4
        \\mov x8, #1
        \\svc #0
        \\mov x0, #1
        \\adr x1, 5f // newline
        \\mov x2, #1
        \\mov x8, #1
        \\svc #0
        \\add sp, sp, #96
        \\// Negative tests — the EINVAL (-1) mapping from EL0:
        \\// sys_udp_recv(9998, sp, 72) — a port this program never bound
        \\// (slot 11) -> EINVAL, deterministic (nothing else binds it).
        \\sub sp, sp, #96
        \\mov x0, #9998
        \\mov x1, sp
        \\mov x2, #72
        \\mov x8, #11
        \\svc #0
        \\movn x9, #0 // -1 (EINVAL)
        \\cmp x0, x9
        \\b.ne 0f // wrong result: park
        \\add sp, sp, #96
        \\mov x0, #1
        \\adr x1, 10f // "udp: recv err -1\n" (17 bytes)
        \\mov x2, #17
        \\mov x8, #1
        \\svc #0
        \\// sys_udp_send(10.0.0.99, 9999, "ping", 4) — a peer that is
        \\// NEVER in the ARP table (slot 10) -> .no_peer -> EINVAL (the
        \\// seam does not resolve ARP; nothing is transmitted).
        \\movz x0, #0x0a00, lsl #16
        \\movk x0, #0x0063 // 0x0a000063 = 10.0.0.99 (network byte order)
        \\mov x1, #9999
        \\adr x2, 2f // "ping"
        \\mov x3, #4
        \\mov x8, #10
        \\svc #0
        \\movn x9, #0 // -1 (EINVAL)
        \\cmp x0, x9
        \\b.ne 0f // wrong result: park
        \\mov x0, #1
        \\adr x1, 11f // "udp: send err -1\n" (17 bytes)
        \\mov x2, #17
        \\mov x8, #1
        \\svc #0
        \\// sys_exit(17) (slot 3) — the UDP protocol number; the kernel
        \\// never returns to a terminated frame (a return here parks).
        \\mov x0, #17
        \\mov x8, #3
        \\svc #0
        \\0:
        \\b 0b
        \\1:
        \\.ascii "udp: listen ok"
        \\.byte 10
        \\2:
        \\.ascii "ping"
        \\3:
        \\.ascii "udp: loop "
        \\4:
        \\.ascii "udp: got "
        \\5:
        \\.byte 10
        \\10:
        \\.ascii "udp: recv err -1"
        \\.byte 10
        \\11:
        \\.ascii "udp: send err -1"
        \\.byte 10
    );
}

// A host-side test cannot execute the naked payload, but compiling this
// module on the host (aarch64 test runner) still type-checks the export.
test "user udp module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user udp: the marker shapes are pinned (live-gate grep targets)" {
    // The exact bytes the payload writes (the `#15` / `#10` / `#9`
    // lengths in the asm and the `1:`/`3:`/`4:` `.ascii` must match
    // these consts — a drift breaks the live gate's `udp: listen ok`,
    // `udp: loop`, and `udp: got` assertions, never silently).
    try std.testing.expectEqualStrings("udp: listen ok\n", listen_ok_line);
    try std.testing.expectEqual(@as(usize, 15), listen_ok_line.len);
    try std.testing.expectEqualStrings("udp: loop ", loop_prefix);
    try std.testing.expectEqual(@as(usize, 10), loop_prefix.len);
    try std.testing.expectEqualStrings("udp: got ", got_prefix);
    try std.testing.expectEqual(@as(usize, 9), got_prefix.len);
    // The EINVAL-error markers (the asm's #17 lengths + `10:`/`11:`
    // `.ascii` must match these — a drift breaks the live gate's
    // `udp: recv err -1` / `udp: send err -1` assertions).
    try std.testing.expectEqualStrings("udp: recv err -1\n", recv_err_line);
    try std.testing.expectEqual(@as(usize, 17), recv_err_line.len);
    try std.testing.expectEqualStrings("udp: send err -1\n", send_err_line);
    try std.testing.expectEqual(@as(usize, 17), send_err_line.len);
    try std.testing.expectEqualStrings("ping", payload);
    try std.testing.expectEqual(@as(u32, 4), payload.len);
    // The deterministic gate constants (the asm's immediates).
    try std.testing.expectEqual(@as(u32, 0x0a000001), own_ip);
    try std.testing.expectEqual(@as(u32, 0x0a000002), peer_ip);
    try std.testing.expectEqual(@as(u32, 7000), listen_port);
    try std.testing.expectEqual(@as(u32, 9999), peer_port);
    try std.testing.expectEqual(@as(u32, 17), exit_status);
}
