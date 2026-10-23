//! census (M188e, #3190): ENTPROBE.BIN — gate-referenced: live-entropy-refusal.
//! VirelaiOS M97g entropy probe — ENTPROBE.BIN (issue #2084, the live
//! slot-72 fail-closed gate payload).
//!
//! The MINIMAL sys_getrandom caller: one svc for a 16-byte fill, then a
//! marker on serial and an exit status that carries the verdict — 0 on a
//! served read, `-errno` on a refusal (EAGAIN -11 → exit status 11). The
//! entropy-absent gate boots the runner with --no-entropy and asserts the
//! refusal marker; the seeded fleet keeps asserting `entprobe: ok`.
//!
//! Same naked-asm, fixed-register-ABI shape as every other ESP program
//! (no Zig-generated memory references or calls; sys_write for the
//! marker, sys_exit for the status).

const std = @import("std");

/// Written when slot 72 served bytes (the seeded path).
pub const ok_marker: []const u8 = "entprobe: ok\n";
/// Written when slot 72 refused — the fail-closed proof.
pub const refused_marker: []const u8 = "entprobe: refused\n";
/// Exit status on a served read.
pub const ok_status: u64 = 0;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// 1. sys_getrandom(sp, 16) — slot 72. The buffer is stack space;
        \\// the result in x0 is the byte count or -errno (EAGAIN -11 while
        \\// the kernel CSPRNG is unseeded — the #2084 fail-closed path).
        \\sub sp, sp, #32
        \\mov x0, sp
        \\mov x1, #16
        \\mov x8, #72
        \\svc #0
        \\mov x19, x0 // preserve the verdict across the report write
        \\cmp x0, #0
        \\b.lt 2f
        \\adr x1, 1f
        \\mov x2, #13 // "entprobe: ok\n"
        \\b 4f
        \\2:
        \\adr x1, 8f
        \\mov x2, #18 // "entprobe: refused\n"
        \\4:
        \\mov x0, #1
        \\mov x8, #1
        \\svc #0
        \\// 2. sys_exit(status) — slot 3: 0 when served, -errno when refused.
        \\mov x0, x19
        \\cmp x0, #0
        \\b.ge 5f
        \\neg x0, x0
        \\5:
        \\mov x8, #3
        \\svc #0
        \\6:
        \\b 6b
        \\1:
        \\.ascii "entprobe: ok\n"
        \\8:
        \\.ascii "entprobe: refused\n"
    );
}

test "user entprobe module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user entprobe: the marker shapes are pinned (live-gate grep targets)" {
    try std.testing.expectEqualStrings("entprobe: ok\n", ok_marker);
    try std.testing.expectEqual(@as(usize, 13), ok_marker.len);
    try std.testing.expectEqualStrings("entprobe: refused\n", refused_marker);
    try std.testing.expectEqual(@as(usize, 18), refused_marker.len);
}
