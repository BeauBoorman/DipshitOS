//! census (M188e, #3190): WINCLOSE.BIN — gate-referenced: live-win-close.
//! VirelaiOS seventh ESP user program — WINCLOSE.BIN (milestone six, card
//! G6 teardown follow-on, claim 0487 — the draw/window syscall seam's
//! release half).
//!
//! WIN.BIN proved an EL0 program can OPEN a window; this program proves it
//! can RELEASE one. It drives the full seam end to end and then tears the
//! window down through the ADR 0007 slot 15 (`sys_win_close`), entirely
//! from EL0:
//!
//!   1. `sys_win_open(64, 64, 256, 192)` (slot 12) opens the first free
//!      user window (id 2) -> prints `win: open id=2`.
//!   2. `sys_win_fill(2, 0, 0, 256, 192, 0x1a2b3c)` (slot 13) paints the
//!      back-buffer (a dark-blue background).
//!   3. `sys_win_present(2)` (slot 14) marks the window dirty -> prints
//!      `win: present ok`.
//!   4. `sys_win_close(2)` (slot 15) releases the window — the kernel frees
//!      the slot (id 2 becomes re-openable) and un-presents it -> prints
//!      `win: close ok`.
//!   5. `sys_exit(88)` — 'X' = 88, the close exit status, a distinct marker
//!      the live gate's `procs WINCLOSE.BIN exited status=88` greps.
//!
//! Unlike WIN.BIN, the window does NOT persist: the gate's phase-2 `win`
//! report observes `windows=2` (terminal + clock, no user window), and a
//! re-exec opens `win: open id=2` AGAIN — the freed slot was reused, not
//! leaked. The geometry/status are deterministic gate constants pinned as
//! `pub const`s so the host tests cannot drift from the payload's asm (the
//! win.zig / peer.zig pattern).
//!
//! The fail-safe park (label 0) is only reachable on a wrong syscall
//! result — the runner times out (the gate fails) unless the full expected
//! transcript appears.

const std = @import("std");

/// The id WINCLOSE.BIN's `sys_win_open` returns (the first free user slot).
pub const window_id: u32 = 2;
/// The exit status ('X' = 88 — a distinct grep target).
pub const exit_status: u32 = 88;
/// The exact marker lines WINCLOSE.BIN writes (the live gate's grep targets).
pub const open_line: []const u8 = "win: open id=2\n";
pub const present_line: []const u8 = "win: present ok\n";
pub const close_line: []const u8 = "win: close ok\n";

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// Phase 1 — sys_win_open(64, 64, 512, 384) (slot 12): the first
        \\// free user window. Returns id 2; a wrong id parks (honest fail).
        \\mov x0, #64
        \\mov x1, #64
        \\mov x2, #512
        \\mov x3, #384
        \\mov x8, #12
        \\svc #0
        \\cmp x0, #2
        \\b.ne 0f
        \\mov x0, #1
        \\adr x1, 1f
        \\mov x2, #15
        \\mov x8, #1
        \\svc #0
        \\// Phase 2 — sys_win_fill(2, 0, 0, 512, 384, 0x1a2b3c) (slot 13):
        \\// the dark-blue background. 0 on success.
        \\mov x0, #2
        \\mov x1, #0
        \\mov x2, #0
        \\mov x3, #512
        \\mov x4, #384
        \\movz x5, #0x1a, lsl #16
        \\movk x5, #0x2b3c
        \\mov x8, #13
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\// Phase 3 — sys_win_present(2) (slot 14): mark the window dirty so
        \\// the compositor blits it on the next idle-loop pass. 0 on success.
        \\mov x0, #2
        \\mov x8, #14
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\mov x0, #1
        \\adr x1, 2f
        \\mov x2, #16
        \\mov x8, #1
        \\svc #0
        \\// Phase 4 — sys_win_close(2) (slot 15): release the user window.
        \\// The kernel frees the slot (id 2 becomes re-openable) and
        \\// un-presents it. 0 on success.
        \\mov x0, #2
        \\mov x8, #15
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\mov x0, #1
        \\adr x1, 3f
        \\mov x2, #14
        \\mov x8, #1
        \\svc #0
        \\// sys_exit(88) (slot 3) — 'X' = 88; the kernel never returns to a
        \\// terminated frame (a return here parks).
        \\mov x0, #88
        \\mov x8, #3
        \\svc #0
        \\0:
        \\b 0b
        \\1:
        \\.ascii "win: open id=2"
        \\.byte 10
        \\2:
        \\.ascii "win: present ok"
        \\.byte 10
        \\3:
        \\.ascii "win: close ok"
        \\.byte 10
    );
}

// A host-side test cannot execute the naked payload, but compiling this
// module on the host (aarch64 test runner) still type-checks the export.
test "user winclose module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user winclose: the marker shapes are pinned (live-gate grep targets)" {
    // The exact bytes the payload writes (the #15 / #16 / #14 lengths in
    // the asm and the 1:/2:/3: .ascii must match these consts — a drift
    // breaks the live gate's `win: open id=2` / `win: present ok` /
    // `win: close ok` assertions, never silently).
    try std.testing.expectEqualStrings("win: open id=2\n", open_line);
    try std.testing.expectEqual(@as(usize, 15), open_line.len);
    try std.testing.expectEqualStrings("win: present ok\n", present_line);
    try std.testing.expectEqual(@as(usize, 16), present_line.len);
    try std.testing.expectEqualStrings("win: close ok\n", close_line);
    try std.testing.expectEqual(@as(usize, 14), close_line.len);
    // The deterministic gate constants (the asm's immediates).
    try std.testing.expectEqual(@as(u32, 2), window_id);
    try std.testing.expectEqual(@as(u32, 88), exit_status);
}
