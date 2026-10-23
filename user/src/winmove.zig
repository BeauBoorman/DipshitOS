//! census (M188e, #3190): WINMOVE.BIN — gate-referenced: live-win-move.
//! VirelaiOS ninth ESP user program — WINMOVE.BIN (milestone six, card G6
//! move/raise follow-on, claim 0487).
//!
//! WIN.BIN proved an EL0 program can OPEN a window, WINLOOP.BIN keeps one
//! alive. This program drives the move/restack surface entirely from EL0:
//! the ADR 0007 slots 16/17 (`sys_win_move` / `sys_win_raise`) reposition
//! and reorder its OWN window (owner-restricted, like fill/present/close):
//!
//!   1. `sys_win_open(64, 64, 512, 384)` (slot 12) opens the first free
//!      user window (id 2) — OWNED by this process -> `winmove: open id=2`.
//!   2. Four `sys_win_fill` calls (slot 13) paint the back-buffer: a dark
//!      blue background (0x1a2b3c) + three 48x48 blocks (red 0xff0000,
//!      cyan 0x00ffff, white 0xffffff) -> `winmove: fill ok`.
//!   3. `sys_win_present(2)` (slot 14) -> `winmove: present ok`.
//!   4. `sys_win_move(2, 800, 400)` (slot 16) repositions the window ->
//!      `winmove: move ok`.
//!   5. `sys_win_present(2)` again, then `sys_win_move(2, 1200, 700)` —
//!      the CLAMP proof: (1200, 700) + 512x384 would fall off the 1280x720
//!      scanout, so it clamps to (768, 336) — the bottom-right corner.
//!   6. `sys_win_raise(2)` (slot 17) raises it to the top ->
//!      `winmove: raise ok`, then a final `sys_win_present(2)`.
//!   7. `sys_win_get(2, sp)` (slot 18) reads the CLAMPED rect back into a
//!      16-byte stack buffer (four u32 LE words) and prints it —
//!      `winmove: get 768,336,512,384` — the EL0-side proof of the
//!      clamp (the move is silent; this reads the result back).
//!   8. `sys_win_query(2, sp)` (slot 19) reads the FULL window state back
//!      into a 32-byte stack buffer (eight u32 LE words) and prints it —
//!      `winmove: query 768,336,512,384 z=2 focused=1 visible=1 dirty=1` —
//!      the EL0-side proof of z-order rank + focus + visible/dirty.
//!   9. `sys_win_set_visible(2, 0)` (slot 20) HIDES the window, then
//!      `sys_sleep(2)` holds it hidden long enough for the gate's
//!      marker-driven capture (`--screenshot-after "winmove: hide ok"`) to
//!      snap the GONE frame, then `sys_win_set_visible(2, 1)` SHOWS it
//!      again — `winmove: hide ok` then `winmove: show ok` — the hide/show
//!      round trip from EL0 (the pixel disappears, then returns).
//!  10. `winmove: loop ok`, then it yield-loops FOREVER (sys_yield, slot 2)
//!      — the moved window persists on the scanout for the gate's
//!      decoded-capture phase (the window's own colors at the NEW position,
//!      terminal glyphs where it USED to be).
//!
//! The geometry/colors are the SAME deterministic gate constants as
//! WIN.BIN/WINLOOP (so the decoded-capture phase reuses its color targets),
//! pinned as `pub const`s so the host tests cannot drift from the payload's
//! asm. A plain EL0 program: naked-asm `_start`, fixed-register syscall
//! ABI, no libc. The fail-safe park (label 0) is only reachable on a wrong
//! syscall result.

const std = @import("std");

/// The id WINMOVE.BIN's `sys_win_open` returns (the first free user slot).
pub const window_id: u32 = 2;
/// The exact marker lines WINMOVE.BIN writes (the live gate's grep targets).
pub const open_line: []const u8 = "winmove: open id=2\n";
pub const fill_line: []const u8 = "winmove: fill ok\n";
pub const present_line: []const u8 = "winmove: present ok\n";
pub const move_line: []const u8 = "winmove: move ok\n";
pub const raise_line: []const u8 = "winmove: raise ok\n";
pub const loop_line: []const u8 = "winmove: loop ok\n";
/// The exact marker WINMOVE.BIN writes after reading its clamped rect back
/// through `sys_win_get` (slot 18) — the live gate's grep target.
pub const get_line: []const u8 = "winmove: get 768,336,512,384\n";
/// The exact marker WINMOVE.BIN writes after reading its FULL window state
/// back through `sys_win_query` (slot 19) — the live gate's grep target.
pub const query_line: []const u8 = "winmove: query 768,336,512,384 z=2 focused=1 visible=1 dirty=1\n";
/// The exact markers WINMOVE.BIN writes around the hide/show round trip
/// through `sys_win_set_visible` (slot 20) — the live gate's grep targets.
pub const hide_line: []const u8 = "winmove: hide ok\n";
pub const show_line: []const u8 = "winmove: show ok\n";

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
        \\// Phase 3 — sys_win_present(2) (slot 14).
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
        \\// Phase 4 — sys_win_move(2, 800, 400) (slot 16): reposition.
        \\mov x0, #2
        \\mov x1, #800
        \\mov x2, #400
        \\mov x8, #16
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\mov x0, #1
        \\adr x1, 4f
        \\mov x2, #17
        \\mov x8, #1
        \\svc #0
        \\mov x0, #2
        \\mov x8, #14
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\// sys_win_move(2, 1200, 700) — the CLAMP proof (slot 16): the
        \\// window would fall off the scanout, so it clamps to (768, 336).
        \\mov x0, #2
        \\mov x1, #1200
        \\mov x2, #700
        \\mov x8, #16
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\// sys_win_raise(2) (slot 17): raise to the top.
        \\mov x0, #2
        \\mov x8, #17
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\mov x0, #1
        \\adr x1, 5f
        \\mov x2, #18
        \\mov x8, #1
        \\svc #0
        \\mov x0, #2
        \\mov x8, #14
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\// Phase 5 — sys_win_get(2, sp) (slot 18): read the CLAMPED rect
        \\// back into a 16-byte stack buffer (four u32 LE words), then print
        \\// it as "winmove: get 768,336,512,384".
        \\sub sp, sp, #64
        \\mov x0, #2
        \\mov x1, sp
        \\mov x8, #18
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\mov x0, #1
        \\adr x1, 8f // "winmove: get " (13 bytes)
        \\mov x2, #13
        \\mov x8, #1
        \\svc #0
        \\ldr w9, [sp] // x
        \\bl 50f
        \\mov x0, #1
        \\adr x1, 9f // ","
        \\mov x2, #1
        \\mov x8, #1
        \\svc #0
        \\ldr w9, [sp, #4] // y
        \\bl 50f
        \\mov x0, #1
        \\adr x1, 9f // ","
        \\mov x2, #1
        \\mov x8, #1
        \\svc #0
        \\ldr w9, [sp, #8] // w
        \\bl 50f
        \\mov x0, #1
        \\adr x1, 9f // ","
        \\mov x2, #1
        \\mov x8, #1
        \\svc #0
        \\ldr w9, [sp, #12] // h
        \\bl 50f
        \\mov x0, #1
        \\adr x1, 10f // newline
        \\mov x2, #1
        \\mov x8, #1
        \\svc #0
        \\add sp, sp, #64
        \\// Phase 6 — sys_win_query(2, sp) (slot 19): read the FULL window
        \\// state back into a 32-byte stack buffer (eight u32 LE words: x, y,
        \\// w, h, z, focused, visible, dirty), then print it as
        \\// "winmove: query 768,336,512,384 z=2 focused=1 visible=1 dirty=1".
        \\sub sp, sp, #64
        \\mov x0, #2
        \\mov x1, sp
        \\mov x8, #19
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\mov x0, #1
        \\adr x1, 11f // "winmove: query " (15 bytes)
        \\mov x2, #15
        \\mov x8, #1
        \\svc #0
        \\ldr w9, [sp] // x
        \\bl 50f
        \\mov x0, #1
        \\adr x1, 9f // ","
        \\mov x2, #1
        \\mov x8, #1
        \\svc #0
        \\ldr w9, [sp, #4] // y
        \\bl 50f
        \\mov x0, #1
        \\adr x1, 9f // ","
        \\mov x2, #1
        \\mov x8, #1
        \\svc #0
        \\ldr w9, [sp, #8] // w
        \\bl 50f
        \\mov x0, #1
        \\adr x1, 9f // ","
        \\mov x2, #1
        \\mov x8, #1
        \\svc #0
        \\ldr w9, [sp, #12] // h
        \\bl 50f
        \\mov x0, #1
        \\adr x1, 12f // " z="
        \\mov x2, #3
        \\mov x8, #1
        \\svc #0
        \\ldr w9, [sp, #16] // z
        \\bl 50f
        \\mov x0, #1
        \\adr x1, 13f // " focused="
        \\mov x2, #9
        \\mov x8, #1
        \\svc #0
        \\ldr w9, [sp, #20] // focused
        \\bl 50f
        \\mov x0, #1
        \\adr x1, 14f // " visible="
        \\mov x2, #9
        \\mov x8, #1
        \\svc #0
        \\ldr w9, [sp, #24] // visible
        \\bl 50f
        \\mov x0, #1
        \\adr x1, 15f // " dirty="
        \\mov x2, #7
        \\mov x8, #1
        \\svc #0
        \\ldr w9, [sp, #28] // dirty
        \\bl 50f
        \\mov x0, #1
        \\adr x1, 10f // newline
        \\mov x2, #1
        \\mov x8, #1
        \\svc #0
        \\add sp, sp, #64
        \\// Phase 7 — sys_win_set_visible(2, 0) (slot 20): HIDE the window,
        \\// then sys_sleep(2) holds it hidden long enough for the gate's
        \\// marker-driven capture (--screenshot-after "winmove: hide ok") to
        \\// snap the GONE frame, then sys_win_set_visible(2, 1) SHOWS it
        \\// again — the hide/show round trip from EL0.
        \\mov x0, #2
        \\mov x1, #0
        \\mov x8, #20
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\mov x0, #1
        \\adr x1, 16f // "winmove: hide ok\n" (17 bytes)
        \\mov x2, #17
        \\mov x8, #1
        \\svc #0
        \\mov x0, #2 // sleep 2 ticks (2 s) — hidden while the gate's marker capture snaps the GONE frame
        \\mov x8, #4
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\mov x0, #2
        \\mov x1, #1
        \\mov x8, #20
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\mov x0, #1
        \\adr x1, 17f // "winmove: show ok\n" (17 bytes)
        \\mov x2, #17
        \\mov x8, #1
        \\svc #0
        \\// The window persists: yield forever (sys_yield, slot 2).
        \\mov x0, #1
        \\adr x1, 6f
        \\mov x2, #17
        \\mov x8, #1
        \\svc #0
        \\7:
        \\mov x0, #0
        \\mov x8, #2
        \\svc #0
        \\b 7b
        \\// Decimal-print subroutine (bl 50f): print the u32 in x9 (the
        \\// caller's w9 was loaded with ldr w, which zero-extends) as
        \\// decimal, no trailing separator. Digits are written backward
        \\// into the caller's reserved scratch (sp+32..sp+62). Clobbers
        \\// x10/x11/x12/x14/x16 (the svc inside preserves x30, so ret
        \\// returns to the bl site).
        \\50:
        \\add x14, sp, #62
        \\mov x10, #10
        \\mov x16, #0 // digit count
        \\cbnz x9, 51f
        \\mov x12, #48 // '0' (the single zero digit)
        \\strb w12, [x14]
        \\mov x16, #1
        \\b 52f
        \\51:
        \\udiv x11, x9, x10
        \\msub x12, x11, x10, x9
        \\add x12, x12, #48 // '0'
        \\strb w12, [x14]
        \\sub x14, x14, #1
        \\mov x9, x11
        \\add x16, x16, #1
        \\cbnz x9, 51b
        \\add x14, x14, #1 // first digit
        \\52:
        \\mov x0, #1
        \\mov x1, x14
        \\mov x2, x16
        \\mov x8, #1
        \\svc #0
        \\ret
        \\0:
        \\b 0b
        \\1:
        \\.ascii "winmove: open id=2"
        \\.byte 10
        \\2:
        \\.ascii "winmove: fill ok"
        \\.byte 10
        \\3:
        \\.ascii "winmove: present ok"
        \\.byte 10
        \\4:
        \\.ascii "winmove: move ok"
        \\.byte 10
        \\5:
        \\.ascii "winmove: raise ok"
        \\.byte 10
        \\6:
        \\.ascii "winmove: loop ok"
        \\.byte 10
        \\8:
        \\.ascii "winmove: get "
        \\9:
        \\.ascii ","
        \\10:
        \\.byte 10
        \\11:
        \\.ascii "winmove: query "
        \\12:
        \\.ascii " z="
        \\13:
        \\.ascii " focused="
        \\14:
        \\.ascii " visible="
        \\15:
        \\.ascii " dirty="
        \\16:
        \\.ascii "winmove: hide ok"
        \\.byte 10
        \\17:
        \\.ascii "winmove: show ok"
        \\.byte 10
    );
}

// A host-side test cannot execute the naked payload, but compiling this
// module on the host (aarch64 test runner) still type-checks the export.
test "user winmove module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user winmove: the marker shapes are pinned (live-gate grep targets)" {
    // The exact bytes the payload writes (the lengths in the asm and the
    // 1:/2:/3:/4:/5:/6: .ascii must match these consts — a drift breaks the
    // live gate's `winmove: ...` assertions, never silently).
    try std.testing.expectEqualStrings("winmove: open id=2\n", open_line);
    try std.testing.expectEqual(@as(usize, 19), open_line.len);
    try std.testing.expectEqualStrings("winmove: fill ok\n", fill_line);
    try std.testing.expectEqual(@as(usize, 17), fill_line.len);
    try std.testing.expectEqualStrings("winmove: present ok\n", present_line);
    try std.testing.expectEqual(@as(usize, 20), present_line.len);
    try std.testing.expectEqualStrings("winmove: move ok\n", move_line);
    try std.testing.expectEqual(@as(usize, 17), move_line.len);
    try std.testing.expectEqualStrings("winmove: raise ok\n", raise_line);
    try std.testing.expectEqual(@as(usize, 18), raise_line.len);
    try std.testing.expectEqualStrings("winmove: loop ok\n", loop_line);
    try std.testing.expectEqual(@as(usize, 17), loop_line.len);
    // The sys_win_get (slot 18) marker — the CLAMPED rect read back from
    // EL0 (a drift breaks the live gate's `winmove: get ...` assertion).
    try std.testing.expectEqualStrings("winmove: get 768,336,512,384\n", get_line);
    try std.testing.expectEqual(@as(usize, 29), get_line.len);
    // The sys_win_query (slot 19) marker — the FULL window state read back
    // from EL0 (a drift breaks the live gate's `winmove: query ...` assertion).
    try std.testing.expectEqualStrings("winmove: query 768,336,512,384 z=2 focused=1 visible=1 dirty=1\n", query_line);
    try std.testing.expectEqual(@as(usize, 63), query_line.len);
    // The sys_win_set_visible (slot 20) markers — the hide/show round trip
    // read back from EL0 (a drift breaks the live gate's `winmove: hide ok`
    // / `winmove: show ok` assertions).
    try std.testing.expectEqualStrings("winmove: hide ok\n", hide_line);
    try std.testing.expectEqual(@as(usize, 17), hide_line.len);
    try std.testing.expectEqualStrings("winmove: show ok\n", show_line);
    try std.testing.expectEqual(@as(usize, 17), show_line.len);
    // The deterministic gate constant (the asm's immediate).
    try std.testing.expectEqual(@as(u32, 2), window_id);
}
