//! census (M188e, #3190): KEYTEST.BIN — gate-referenced: live-events.
//! VirelaiOS tenth ESP user program — KEYTEST.BIN (milestone nine, card E6,
//! claim 9328 — interactive EL0 event processing capstone).
//!
//! The FIRST interactive graphics application: this program opens a
//! kernel-owned user window, renders initial content, and blocks on
//! `sys_wait_event` (slot 22). When keyboard, mouse, or window lifecycle
//! events arrive from the kernel's event routing, it updates its on-screen
//! window content in real time via `sys_win_fill` (slot 13) and
//! `sys_win_present` (slot 14), and outputs deterministic serial markers via
//! `sys_write` (slot 1).
//!
//! Lifecycle:
//!   1. `sys_win_open(96, 96, 512, 384)` (slot 12) -> opens window id 2.
//!   2. `sys_win_fill(2, 0, 0, 512, 384, 0x182026)` (slot 13) + `sys_win_present(2)`.
//!   3. `sys_wait_event(sp)` (slot 22) event loop:
//!      - `WIN_FOCUS` (6): paints green focus bar at (8, 8, 240, 6, 0x22c55e) + presents.
//!      - `KEY_DOWN` (1): paints red key indicator at (32, 32, 64, 64, 0xef4444) + presents.
//!      - `MOUSE_DOWN` / `MOUSE_MOVE` (3/5): paints blue mouse indicator at (128, 32, 64, 64, 0x3b82f6) + presents.
//!      - After receiving interactive input (or `WIN_CLOSE`), outputs `keytest: exiting 99`
//!        and exits with status 99 via `sys_exit(99)` (slot 3).

const std = @import("std");

/// The id KEYTEST.BIN's `sys_win_open` returns (the first free user slot).
pub const window_id: u32 = 2;
pub const window_x: u32 = 96;
pub const window_y: u32 = 96;
pub const window_w: u32 = 512;
pub const window_h: u32 = 384;

/// Colors painted by KEYTEST.BIN.
pub const bg_rgb: u32 = 0x182026;
pub const focus_rgb: u32 = 0x22c55e;
pub const key_rgb: u32 = 0xef4444;
pub const mouse_rgb: u32 = 0x3b82f6;

/// The exit status (99 — a distinct grep target for the live gate).
pub const exit_status: u32 = 99;

/// The exact marker lines KEYTEST.BIN writes (the live gate's grep targets).
pub const open_line: []const u8 = "keytest: open id=2\n";
pub const present_line: []const u8 = "keytest: present ok\n";
pub const focus_line: []const u8 = "keytest: win_focus\n";
pub const key_line: []const u8 = "keytest: key_down\n";
pub const mouse_line: []const u8 = "keytest: mouse_event\n";
pub const exit_line: []const u8 = "keytest: exiting 99\n";

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// 1. sys_win_open(96, 96, 512, 384) (slot 12)
        \\mov x0, #96
        \\mov x1, #96
        \\mov x2, #512
        \\mov x3, #384
        \\mov x8, #12
        \\svc #0
        \\cmp x0, #2
        \\b.ne 0f
        \\
        \\// Write open marker
        \\mov x0, #1
        \\adr x1, 1f
        \\mov x2, #19
        \\mov x8, #1
        \\svc #0
        \\
        \\// 2. sys_win_fill(2, 0, 0, 512, 384, 0x182026) (slot 13)
        \\mov x0, #2
        \\mov x1, #0
        \\mov x2, #0
        \\mov x3, #512
        \\mov x4, #384
        \\movz x5, #0x18, lsl #16
        \\movk x5, #0x2026
        \\mov x8, #13
        \\svc #0
        \\
        \\// 3. sys_win_present(2) (slot 14)
        \\mov x0, #2
        \\mov x8, #14
        \\svc #0
        \\
        \\// Write present marker
        \\mov x0, #1
        \\adr x1, 2f
        \\mov x2, #20
        \\mov x8, #1
        \\svc #0
        \\
        \\// 4. Event loop: loop on sys_wait_event(sp) (slot 22)
        \\mov x19, xzr
        \\
        \\10:
        \\sub sp, sp, #32
        \\mov x0, sp
        \\mov x8, #22
        \\svc #0
        \\cmp x0, #1
        \\b.ne 11f
        \\
        \\// Decode Event:
        \\ldrh w20, [sp, #0] // kind
        \\ldrh w21, [sp, #2] // flags
        \\ldr w22, [sp, #8]  // arg0
        \\ldr w23, [sp, #12] // arg1
        \\
        \\// Check kind == 6 (WIN_FOCUS)
        \\cmp w20, #6
        \\b.eq 20f
        \\
        \\// Check kind == 1 (KEY_DOWN)
        \\cmp w20, #1
        \\b.eq 30f
        \\
        \\// Check kind == 3 (MOUSE_DOWN) or 5 (MOUSE_MOVE)
        \\cmp w20, #3
        \\b.eq 40f
        \\cmp w20, #5
        \\b.eq 40f
        \\
        \\// Check kind == 8 (WIN_CLOSE)
        \\cmp w20, #8
        \\b.eq 50f
        \\
        \\b 12f
        \\
        \\// WIN_FOCUS handler:
        \\20:
        \\mov x0, #1
        \\adr x1, 3f
        \\mov x2, #19
        \\mov x8, #1
        \\svc #0
        \\// Paint green bar at top: sys_win_fill(2, 8, 8, 240, 6, 0x22c55e)
        \\mov x0, #2
        \\mov x1, #8
        \\mov x2, #8
        \\mov x3, #240
        \\mov x4, #6
        \\movz x5, #0x22, lsl #16
        \\movk x5, #0xc55e
        \\mov x8, #13
        \\svc #0
        \\mov x0, #2
        \\mov x8, #14
        \\svc #0
        \\b 12f
        \\
        \\// KEY_DOWN handler:
        \\30:
        \\mov x0, #1
        \\adr x1, 4f
        \\mov x2, #18
        \\mov x8, #1
        \\svc #0
        \\// Paint red box: sys_win_fill(2, 32, 32, 64, 64, 0xef4444)
        \\mov x0, #2
        \\mov x1, #32
        \\mov x2, #32
        \\mov x3, #64
        \\mov x4, #64
        \\movz x5, #0xef, lsl #16
        \\movk x5, #0x4444
        \\mov x8, #13
        \\svc #0
        \\mov x0, #2
        \\mov x8, #14
        \\svc #0
        \\add x19, x19, #1
        \\cmp x19, #1
        \\b.ge 50f
        \\b 12f
        \\
        \\// MOUSE_DOWN / MOUSE_MOVE handler:
        \\40:
        \\mov x0, #1
        \\adr x1, 5f
        \\mov x2, #21
        \\mov x8, #1
        \\svc #0
        \\// Paint blue box: sys_win_fill(2, 128, 32, 64, 64, 0x3b82f6)
        \\mov x0, #2
        \\mov x1, #128
        \\mov x2, #32
        \\mov x3, #64
        \\mov x4, #64
        \\movz x5, #0x3b, lsl #16
        \\movk x5, #0x82f6
        \\mov x8, #13
        \\svc #0
        \\mov x0, #2
        \\mov x8, #14
        \\svc #0
        \\add x19, x19, #1
        \\cmp x19, #1
        \\b.ge 50f
        \\b 12f
        \\
        \\11:
        \\mov x8, #2
        \\svc #0
        \\
        \\12:
        \\add sp, sp, #32
        \\b 10b
        \\
        \\// Exit handler:
        \\50:
        \\add sp, sp, #32
        \\mov x0, #1
        \\adr x1, 6f
        \\mov x2, #20
        \\mov x8, #1
        \\svc #0
        \\// sys_exit(99)
        \\mov x0, #99
        \\mov x8, #3
        \\svc #0
        \\
        \\0:
        \\b 0b
        \\
        \\1: .ascii "keytest: open id=2\n"
        \\2: .ascii "keytest: present ok\n"
        \\3: .ascii "keytest: win_focus\n"
        \\4: .ascii "keytest: key_down\n"
        \\5: .ascii "keytest: mouse_event\n"
        \\6: .ascii "keytest: exiting 99\n"
    );
}
