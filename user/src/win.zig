//! census (M188e, #3190): WIN.BIN — gate-referenced: live-win-syscall.
//! VirelaiOS sixth ESP user program — WIN.BIN (milestone six, card G6,
//! claim 0487 — the draw/window syscall seam).
//!
//! The FIRST graphics syscall user: this program opens a kernel-owned user
//! window and renders into it through the ADR 0007 slots 12/13/14
//! (`sys_win_open` / `sys_win_fill` / `sys_win_present`) end to end,
//! entirely from EL0:
//!
//!   1. `sys_win_open(64, 64, 512, 384)` (slot 12) opens the first free
//!      user window (id 2 — a kernel-owned fixed-BSS back-buffer) -> prints
//!      `win: open id=2`.
//!   2. Four `sys_win_fill` calls (slot 13) paint the back-buffer: a dark
//!      blue background (0x1a2b3c) + three 48x48 blocks (red 0xff0000,
//!      cyan 0x00ffff, white 0xffffff) -> `win: fill ok`.
//!   3. `sys_win_present(2)` (slot 14) marks the window dirty so the
//!      window manager's compositor blits it on the next idle-loop pass ->
//!      `win: present ok`.
//!   4. `sys_exit(87)` — 'W' = 87, the window exit status, a distinct
//!      marker the live gate's `procs WIN.BIN exited status=87` greps.
//!
//! The window is kernel-global: it persists after this program exits (the
//! honest bounded seam — no per-process ownership), so the gate's `win` +
//! decoded-capture phase observes it on the SAME kernel state. The
//! geometry/colors/status are the deterministic gate constants, pinned as
//! `pub const`s below so the host tests cannot drift from the payload's asm
//! (the peer.zig / udp.zig pattern). A plain EL0 program: naked-asm
//! `_start`, fixed-register syscall ABI, no libc.
//!
//! The fail-safe park (label 0) is only reachable on a wrong syscall
//! result — the runner times out (the gate fails) unless the full expected
//! transcript appears.

const std = @import("std");

/// The id WIN.BIN's `sys_win_open` returns (the first free user slot).
pub const window_id: u32 = 2;
/// The window geometry (sys_win_open's x/y/w/h — the gate's decode rect).
pub const window_x: u32 = 64;
pub const window_y: u32 = 64;
pub const window_w: u32 = 512;
pub const window_h: u32 = 384;
/// The exact colors WIN.BIN paints (the gate's decoded-pixel targets).
pub const bg_rgb: u32 = 0x1a2b3c;
pub const red_rgb: u32 = 0xff0000;
pub const cyan_rgb: u32 = 0x00ffff;
pub const white_rgb: u32 = 0xffffff;
/// The exit status ('W' = 87 — a distinct grep target).
pub const exit_status: u32 = 87;
/// The exact marker lines WIN.BIN writes (the live gate's grep targets).
pub const open_line: []const u8 = "win: open id=2\n";
pub const fill_line: []const u8 = "win: fill ok\n";
pub const present_line: []const u8 = "win: present ok\n";

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
        \\// sys_win_fill(2, 8, 8, 48, 48, 0xff0000) — the red block.
        \\mov x0, #2
        \\mov x1, #8
        \\mov x2, #8
        \\mov x3, #48
        \\mov x4, #48
        \\movz x5, #0xff, lsl #16
        \\mov x8, #13
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\// sys_win_fill(2, 64, 8, 48, 48, 0x00ffff) — the cyan block.
        \\mov x0, #2
        \\mov x1, #64
        \\mov x2, #8
        \\mov x3, #48
        \\mov x4, #48
        \\movz x5, #0xffff
        \\mov x8, #13
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\// sys_win_fill(2, 120, 8, 48, 48, 0xffffff) — the white block.
        \\mov x0, #2
        \\mov x1, #120
        \\mov x2, #8
        \\mov x3, #48
        \\mov x4, #48
        \\movz x5, #0xff, lsl #16
        \\movk x5, #0xffff
        \\mov x8, #13
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\mov x0, #1
        \\adr x1, 2f
        \\mov x2, #13
        \\mov x8, #1
        \\svc #0
        \\// Phase 3 — sys_win_present(2) (slot 14): mark the window dirty so
        \\// the compositor blits it on the next idle-loop pass. 0 on success.
        \\mov x0, #2
        \\mov x8, #14
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\mov x0, #1
        \\adr x1, 3f
        \\mov x2, #16
        \\mov x8, #1
        \\svc #0
        \\// sys_exit(87) (slot 3) — 'W' = 87; the kernel never returns to a
        \\// terminated frame (a return here parks).
        \\mov x0, #87
        \\mov x8, #3
        \\svc #0
        \\0:
        \\b 0b
        \\1:
        \\.ascii "win: open id=2"
        \\.byte 10
        \\2:
        \\.ascii "win: fill ok"
        \\.byte 10
        \\3:
        \\.ascii "win: present ok"
        \\.byte 10
    );
}

// A host-side test cannot execute the naked payload, but compiling this
// module on the host (aarch64 test runner) still type-checks the export.
test "user win module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user win: the marker shapes are pinned (live-gate grep targets)" {
    // The exact bytes the payload writes (the #15 / #13 / #16 lengths in
    // the asm and the 1:/2:/3: .ascii must match these consts — a drift
    // breaks the live gate's `win: open id=2` / `win: fill ok` /
    // `win: present ok` assertions, never silently).
    try std.testing.expectEqualStrings("win: open id=2\n", open_line);
    try std.testing.expectEqual(@as(usize, 15), open_line.len);
    try std.testing.expectEqualStrings("win: fill ok\n", fill_line);
    try std.testing.expectEqual(@as(usize, 13), fill_line.len);
    try std.testing.expectEqualStrings("win: present ok\n", present_line);
    try std.testing.expectEqual(@as(usize, 16), present_line.len);
    // The deterministic gate constants (the asm's immediates).
    try std.testing.expectEqual(@as(u32, 2), window_id);
    try std.testing.expectEqual(@as(u32, 64), window_x);
    try std.testing.expectEqual(@as(u32, 64), window_y);
    try std.testing.expectEqual(@as(u32, 256), window_w);
    try std.testing.expectEqual(@as(u32, 192), window_h);
    try std.testing.expectEqual(@as(u32, 0x1a2b3c), bg_rgb);
    try std.testing.expectEqual(@as(u32, 0xff0000), red_rgb);
    try std.testing.expectEqual(@as(u32, 0x00ffff), cyan_rgb);
    try std.testing.expectEqual(@as(u32, 0xffffff), white_rgb);
    try std.testing.expectEqual(@as(u32, 87), exit_status);
}
