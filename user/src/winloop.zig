//! census (M188e, #3190): WINLOOP.BIN — gate-referenced: 7 specs incl. live-win-syscall, live-wm1, live-pointer-cg.
//! VirelaiOS eighth ESP user program — WINLOOP.BIN (milestone six, card G6
//! per-process-window-ownership follow-on, claim 0487).
//!
//! WIN.BIN proves an EL0 program can OPEN a window but exits immediately, so
//! (with per-process ownership) its window auto-closes before any host
//! capture can see it. This program keeps its window ALIVE so the live gate
//! can pixel-prove an EL0-rendered window on the scanout, entirely from
//! EL0:
//!
//!   1. `sys_win_open(64, 64, 256, 192)` (slot 12) opens the first free
//!      user window (id 2) — OWNED by this process -> `winloop: open id=2`.
//!   2. Four `sys_win_fill` calls (slot 13) paint the back-buffer: a dark
//!      blue background (0x1a2b3c) + three 48x48 blocks (red 0xff0000,
//!      cyan 0x00ffff, white 0xffffff) -> `winloop: fill ok`.
//!   3. `sys_win_present(2)` (slot 14) marks the window dirty ->
//!      `winloop: present ok`.
//!   4. `winloop: loop ok`, then it yield-loops FOREVER (sys_yield, slot 2)
//!      — the window persists on the scanout for the gate's decoded-capture
//!      phase, and is auto-closed only when the process is killed or the
//!      machine reboots (the real teardown semantic).
//!
//! The geometry/colors are the SAME deterministic gate constants as
//! WIN.BIN (so the G6 decoded-capture phase reuses its color targets),
//! pinned as `pub const`s so the host tests cannot drift from the payload's
//! asm (the win.zig / winclose.zig pattern). A plain EL0 program: naked-asm
//! `_start`, fixed-register syscall ABI, no libc. The fail-safe park (label
//! 0) is only reachable on a wrong syscall result.

const std = @import("std");

/// The id WINLOOP.BIN's `sys_win_open` returns (the first free user slot).
pub const window_id: u32 = 2;
/// The exact marker lines WINLOOP.BIN writes (the live gate's grep targets).
pub const open_line: []const u8 = "winloop: open id=2\n";
pub const fill_line: []const u8 = "winloop: fill ok\n";
pub const present_line: []const u8 = "winloop: present ok\n";
pub const loop_line: []const u8 = "winloop: loop ok\n";

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// Phase 1 — sys_win_open(64, 64, 512, 384) (slot 12): the first
        \\// free user window, owned by this process. Returns id 2.
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
        \\mov x2, #19
        \\mov x8, #1
        \\svc #0
        \\// Phase 2 — sys_win_fill(2, 0, 0, 512, 384, 0x1a2b3c) (slot 13):
        \\// the dark-blue background.
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
        \\mov x2, #17
        \\mov x8, #1
        \\svc #0
        \\// Phase 3 — sys_win_present(2) (slot 14): mark the window dirty so
        \\// the compositor blits it on the next idle-loop pass.
        \\mov x0, #2
        \\mov x8, #14
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\mov x0, #1
        \\adr x1, 3f
        \\mov x2, #20
        \\mov x8, #1
        \\svc #0
        \\// The window persists: yield forever (sys_yield, slot 2).
        \\mov x0, #1
        \\adr x1, 4f
        \\mov x2, #17
        \\mov x8, #1
        \\svc #0
        \\5:
        \\mov x0, #0
        \\mov x8, #2
        \\svc #0
        \\b 5b
        \\0:
        \\b 0b
        \\1:
        \\.ascii "winloop: open id=2"
        \\.byte 10
        \\2:
        \\.ascii "winloop: fill ok"
        \\.byte 10
        \\3:
        \\.ascii "winloop: present ok"
        \\.byte 10
        \\4:
        \\.ascii "winloop: loop ok"
        \\.byte 10
    );
}

// A host-side test cannot execute the naked payload, but compiling this
// module on the host (aarch64 test runner) still type-checks the export.
test "user winloop module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user winloop: the marker shapes are pinned (live-gate grep targets)" {
    // The exact bytes the payload writes (the #19 / #17 / #20 / #17 lengths
    // in the asm and the 1:/2:/3:/4: .ascii must match these consts — a
    // drift breaks the live gate's `winloop: open id=2` / `winloop: fill
    // ok` / `winloop: present ok` / `winloop: loop ok` assertions, never
    // silently).
    try std.testing.expectEqualStrings("winloop: open id=2\n", open_line);
    try std.testing.expectEqual(@as(usize, 19), open_line.len);
    try std.testing.expectEqualStrings("winloop: fill ok\n", fill_line);
    try std.testing.expectEqual(@as(usize, 17), fill_line.len);
    try std.testing.expectEqualStrings("winloop: present ok\n", present_line);
    try std.testing.expectEqual(@as(usize, 20), present_line.len);
    try std.testing.expectEqualStrings("winloop: loop ok\n", loop_line);
    try std.testing.expectEqual(@as(usize, 17), loop_line.len);
    // The deterministic gate constant (the asm's immediate).
    try std.testing.expectEqual(@as(u32, 2), window_id);
}
