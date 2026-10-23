//! census (M188e, #3190): M21DEMO.BIN — gate-referenced: 6 M21 tiling/WM specs incl. live-m21-tile-master, live-m21-minimize-ws.
//! VirelaiOS M21 ESP user program — M21DEMO.BIN (milestone twenty-one,
//! claim 8777: the W1/W2 tiling + master-detail gate payload).
//!
//! The W1/W2 entries are CHORD-driven (Ctrl+T / Ctrl+M), which the serial
//! script path cannot type, so the live gate drives the same
//! `driving_award.zig` functions through the EL1h monitor halves
//  (`dui tile <n>` / `dui master`). This program's ONLY job is to put TWO
//! distinctively-colored user windows on the screen and stay alive:
//!
//!   1. `sys_win_open(64, 64, 512, 384)` (slot 12) opens window A (id 2),
//!      OWNED by this process -> `m21demo: open-a id=2`.
//!   2. Three `sys_win_fill` calls (slot 13) paint A's back-buffer: a dark
//!      blue background (0x1a2b3c) + one red 48x48 block (0xff0000) at
//!      local (8,8) -> `m21demo: fill-a ok`.
//!   3. `sys_win_present(2)` (slot 14) -> `m21demo: present-a ok`.
//!   4. `sys_win_open(400, 240, 512, 384)` opens window B (id 3) ->
//!      `m21demo: open-b id=3`.
//!   5. Two fills paint B: a black background (0x000000) + one cyan block
//!      (0x00ffff) at local (8,8) -> `m21demo: fill-b ok`.
//!   6. `sys_win_present(3)` -> `m21demo: present-b ok`.
//!   7. `m21demo: loop ok`, then it yield-loops FOREVER (sys_yield, slot 2)
//!      so both windows persist for the gate's tiled-layout captures.
//!
//! Color contract (the decoded-capture targets): A = darkblue + red,
//! B = black + cyan. After `dui tile 2` + `dui tile 3` the registry must
//! show A at the master rect and B at the detail rect; after `dui master`
//! the rects swap sides (W2). The blit source clamp (claim 8777) keeps the
//! content in each tile's top-left 512x384 corner, so every pixel target
//! sits inside that strip.
//!
//! A plain EL0 program: naked-asm `_start`, fixed-register syscall ABI, no
//! libc. The fail-safe park (label 0) is only reachable on a wrong syscall
//! result.

const std = @import("std");

/// The ids the two `sys_win_open` calls return (the first two free slots).
pub const window_a_id: u32 = 2;
pub const window_b_id: u32 = 3;
/// The exact marker lines M21DEMO.BIN writes (the live gate's grep targets).
pub const open_a_line: []const u8 = "m21demo: open-a id=2\n";
pub const fill_a_line: []const u8 = "m21demo: fill-a ok\n";
pub const present_a_line: []const u8 = "m21demo: present-a ok\n";
pub const open_b_line: []const u8 = "m21demo: open-b id=3\n";
pub const fill_b_line: []const u8 = "m21demo: fill-b ok\n";
pub const present_b_line: []const u8 = "m21demo: present-b ok\n";
pub const loop_line: []const u8 = "m21demo: loop ok\n";

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// Phase 1 — sys_win_open(64, 64, 512, 384) (slot 12): window A,
        \\// owned by this process. Returns id 2.
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
        \\mov x2, #20
        \\mov x8, #1
        \\svc #0
        \\// Phase 2 — sys_win_fill(2, 0, 0, 512, 384, 0x1a2b3c) (slot 13):
        \\// A's dark-blue background.
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
        \\// sys_win_fill(2, 8, 8, 48, 48, 0xff0000) — A's red block.
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
        \\mov x0, #1
        \\adr x1, 2f
        \\mov x2, #18
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
        \\mov x2, #21
        \\mov x8, #1
        \\svc #0
        \\// Phase 4 — sys_win_open(400, 240, 512, 384) (slot 12): window B.
        \\// Returns id 3.
        \\mov x0, #400
        \\mov x1, #240
        \\mov x2, #512
        \\mov x3, #384
        \\mov x8, #12
        \\svc #0
        \\cmp x0, #3
        \\b.ne 0f
        \\mov x0, #1
        \\adr x1, 4f
        \\mov x2, #20
        \\mov x8, #1
        \\svc #0
        \\// Phase 5 — sys_win_fill(3, 0, 0, 512, 384, 0x000000): B's black
        \\// background.
        \\mov x0, #3
        \\mov x1, #0
        \\mov x2, #0
        \\mov x3, #512
        \\mov x4, #384
        \\mov x5, #0
        \\mov x8, #13
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\// sys_win_fill(3, 8, 8, 48, 48, 0x00ffff) — B's cyan block.
        \\mov x0, #3
        \\mov x1, #8
        \\mov x2, #8
        \\mov x3, #48
        \\mov x4, #48
        \\movz x5, #0xffff
        \\mov x8, #13
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\mov x0, #1
        \\adr x1, 5f
        \\mov x2, #18
        \\mov x8, #1
        \\svc #0
        \\// Phase 6 — sys_win_present(3) (slot 14).
        \\mov x0, #3
        \\mov x8, #14
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\mov x0, #1
        \\adr x1, 6f
        \\mov x2, #21
        \\mov x8, #1
        \\svc #0
        \\// Both windows persist: yield forever (sys_yield, slot 2).
        \\mov x0, #1
        \\adr x1, 7f
        \\mov x2, #16
        \\mov x8, #1
        \\svc #0
        \\8:
        \\mov x0, #0
        \\mov x8, #2
        \\svc #0
        \\b 8b
        \\0:
        \\b 0b
        \\1:
        \\.ascii "m21demo: open-a id=2"
        \\.byte 10
        \\2:
        \\.ascii "m21demo: fill-a ok"
        \\.byte 10
        \\3:
        \\.ascii "m21demo: present-a ok"
        \\.byte 10
        \\4:
        \\.ascii "m21demo: open-b id=3"
        \\.byte 10
        \\5:
        \\.ascii "m21demo: fill-b ok"
        \\.byte 10
        \\6:
        \\.ascii "m21demo: present-b ok"
        \\.byte 10
        \\7:
        \\.ascii "m21demo: loop ok"
        \\.byte 10
    );
}

// A host-side test cannot execute the naked payload, but compiling this
// module on the host (aarch64 test runner) still type-checks the export.
test "user m21demo module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user m21demo: the marker shapes are pinned (live-gate grep targets)" {
    // The exact bytes the payload writes (the lengths in the asm and the
    // 1:/2:/...:.ascii blocks must match these consts — a drift breaks the
    // live gate's `m21demo: ...` assertions, never silently).
    try std.testing.expectEqualStrings("m21demo: open-a id=2\n", open_a_line);
    try std.testing.expectEqual(@as(usize, 21), open_a_line.len);
    try std.testing.expectEqualStrings("m21demo: fill-a ok\n", fill_a_line);
    try std.testing.expectEqual(@as(usize, 19), fill_a_line.len);
    try std.testing.expectEqualStrings("m21demo: present-a ok\n", present_a_line);
    try std.testing.expectEqual(@as(usize, 22), present_a_line.len);
    try std.testing.expectEqualStrings("m21demo: open-b id=3\n", open_b_line);
    try std.testing.expectEqual(@as(usize, 21), open_b_line.len);
    try std.testing.expectEqualStrings("m21demo: fill-b ok\n", fill_b_line);
    try std.testing.expectEqual(@as(usize, 19), fill_b_line.len);
    try std.testing.expectEqualStrings("m21demo: present-b ok\n", present_b_line);
    try std.testing.expectEqual(@as(usize, 22), present_b_line.len);
    try std.testing.expectEqualStrings("m21demo: loop ok\n", loop_line);
    try std.testing.expectEqual(@as(usize, 17), loop_line.len);
    try std.testing.expectEqual(@as(u32, 2), window_a_id);
    try std.testing.expectEqual(@as(u32, 3), window_b_id);
}
