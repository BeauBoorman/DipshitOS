//! census (M188e, #3190): GLOBALS.BIN — gate-referenced: live-m16-composition, live-m16-image.
//! VirelaiOS GLOBALS.BIN — milestone sixteen card C1 (claim 3805) proof
//! program: the first SEGMENTED DSK3 user image. Its `.data` global is real
//! writable memory and its `.bss` global is zero-filled — reversing the M15
//! JINGLE finding (a writable global faulted because the flat image had no
//! writable segment, claim 7636) — and its 24 KiB `.rodata` blob pushes the
//! image past the OLD 16 KiB exec bound (now lifted to 256 KiB).
//!
//! The payload is naked asm with the fixed register ABI. It uses ADRP/ADD to
//! reach the `.data`/`.bss` globals (the linker addresses them absolutely;
//! ADRP is PC-relative, so the page offset resolves at runtime exactly as it
//! does at link time — the segmented loader maps data at `text_va + text_size`
//! where the linker placed `.data`). The four checks are:
//!
//!   1. read the `.data` global → matches the initialized value;
//!   2. write a new value → read back → matches (writable data);
//!   3. read the `.bss` global (first + last word) → both zero (zero-filled);
//!   4. write to `.bss` → read back → matches (writable bss);
//!   5. read the `.rodata` blob's first byte → 0x41 (the blob is the thing
//!      that pushes the image past the OLD 16 KiB exec bound).
//!
//! Only when all five pass does it print `globals: data bss ok\n` and exit 42;
//! any failure prints `globals: FAIL\n` and exits 43.

const std = @import("std");

/// A 24 KiB read-only blob (all 'A') that pushes the image past the old
/// 16 KiB load bound. Exported so it is never dead-stripped.
export const big_blob: [24 * 1024]u8 = @as([(24 * 1024)]u8, @splat(@as(u8, 0x41)));
/// An initialized `.data` global — the value the payload verifies on entry.
export var g_data: u64 = 0x1122334455667788;
/// A zero-filled `.bss` global (a 4 KiB buffer). `undefined` → NOBITS, so
/// the segmented loader's zero-fill (not the file) is what backs it.
export var g_bss: [4096]u8 = undefined;

/// The exact success marker (the live gate's grep target, written with `#21`).
pub const ok_marker: []const u8 = "globals: data bss ok\n";
/// The exact failure marker (written with `#14`; the live gate asserts zero).
pub const fail_marker: []const u8 = "globals: FAIL\n";

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// 1. Read the .data global and verify the initialized value.
        \\adrp x9, g_data
        \\add x9, x9, :lo12:g_data
        \\ldr x10, [x9]
        \\movz x11, #0x7788
        \\movk x11, #0x5566, lsl #16
        \\movk x11, #0x3344, lsl #32
        \\movk x11, #0x1122, lsl #48
        \\cmp x10, x11
        \\b.ne 99f
        \\// 2. Write a new value to .data, read it back, verify.
        \\movz x11, #0xdef0
        \\movk x11, #0x9abc, lsl #16
        \\movk x11, #0x5678, lsl #32
        \\movk x11, #0x1234, lsl #48
        \\str x11, [x9]
        \\ldr x10, [x9]
        \\cmp x10, x11
        \\b.ne 99f
        \\// 3. Read the .bss global (first and last word) — both zero.
        \\adrp x9, g_bss
        \\add x9, x9, :lo12:g_bss
        \\ldr x10, [x9]
        \\cbnz x10, 99f
        \\ldr x10, [x9, #4088]
        \\cbnz x10, 99f
        \\// 4. Write to .bss, read back, verify.
        \\movz x10, #0xbeef
        \\str x10, [x9]
        \\ldr x11, [x9]
        \\cmp x10, x11
        \\b.ne 99f
        \\// 5. Read the .rodata blob (24 KiB, keeps the image > 16 KiB) — first byte is 'A'.
        \\adrp x9, big_blob
        \\add x9, x9, :lo12:big_blob
        \\ldrb w10, [x9]
        \\cmp w10, #0x41
        \\b.ne 99f
        \\// All five checks passed: print the marker and exit 42.
        \\mov x0, #1
        \\adr x1, 1f
        \\mov x2, #21
        \\mov x8, #1
        \\svc #0
        \\mov x0, #42
        \\mov x8, #3
        \\svc #0
        \\99:
        \\mov x0, #1
        \\adr x1, 2f
        \\mov x2, #14
        \\mov x8, #1
        \\svc #0
        \\mov x0, #43
        \\mov x8, #3
        \\svc #0
        \\1:
        \\.ascii "globals: data bss ok\n"
        \\2:
        \\.ascii "globals: FAIL\n"
    );
}

test "user globals module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
    _ = &big_blob;
    _ = &g_data;
    _ = &g_bss;
}

test "user globals: the marker shapes are pinned (live-gate grep targets)" {
    // The blob is large enough to exceed the old 16 KiB bound on its own.
    try std.testing.expectEqual(@as(usize, 24 * 1024), big_blob.len);
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), g_data);
    try std.testing.expectEqualStrings("globals: data bss ok\n", ok_marker);
    try std.testing.expectEqual(@as(usize, 21), ok_marker.len);
    try std.testing.expectEqualStrings("globals: FAIL\n", fail_marker);
    try std.testing.expectEqual(@as(usize, 14), fail_marker.len);
}
