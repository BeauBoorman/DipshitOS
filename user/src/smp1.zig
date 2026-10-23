//! census (M188e, #3190): SMP1.BIN — gate-referenced: live-smp1.
//! VirelaiOS SMP user task — SMP1.BIN (claim 2369: locked console TX +
//! user tasks on secondary cores).
//!
//! The FIRST user program that runs on a secondary core: `exec -c1 SMP1.BIN`
//! pins its task to core 1, so every syscall below executes on that core
//! (the kernel's per-core scheduler state, claim 8477, plus the now-locked
//! serial TX make that safe). The program's shape exercises every core-1
//! seam end to end:
//!
//!   1. sys_write the hello marker from core 1 (locked console TX — core 0
//!      prints heartbeats/reports concurrently, so the exact-line greps in
//!      the live gate prove no byte interleaving).
//!   2. sys_sleep 2 ticks — the SVC has no eligible successor on core 1,
//!      so the kernel PARKS core 1 back on its WFE loop (the claim-2369
//!      park path); core 0's tick wakes the task and core 1's next tick
//!      resumes it from its saved SVC frame.
//!   3. sys_write the exiting marker from core 1, then sys_exit(0) — the
//!      exit also parks core 1; core 0's reaper frees the zombie.
//!
//! Same naked-asm, fixed-register-ABI shape as every other ESP program (no
//! Zig-generated memory references or calls). The marker bytes, the sleep
//! length, and the exit status are exposed as `pub const`s so the host
//! tests pin the EXACT shapes (the live gate's grep targets) and the
//! payload cannot drift.

const std = @import("std");

/// The exact bytes SMP1.BIN writes on entry (proves the program is running
/// on core 1 before it sleeps). Host-tested so the live gate's grep target
/// cannot drift from the payload's `.ascii`.
pub const hello_marker: []const u8 = "smp1: hello from core-1 userland\n";
/// The exact bytes SMP1.BIN writes after the sleep, right before sys_exit.
pub const exiting_marker: []const u8 = "smp1: exiting from core 1\n";
/// The scheduler-tick sleep: a 2 s window in which core 1 is parked on its
/// WFE loop while the task is blocked (1 tick = 1 s on VZ).
pub const sleep_ticks: u64 = 2;
/// The exit status (0 — a clean exit; the zombie is reaped by core 0).
pub const exit_status: u64 = 0;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// SMP1.BIN: hello from core 1, sleep (park + wake), goodbye, exit.
        \\mov x0, #1
        \\adr x1, 1f
        \\mov x2, #33 // "smp1: hello from core-1 userland\n"
        \\mov x8, #1
        \\svc #0
        \\// Sleep `sleep_ticks` scheduler ticks (slot 4): the kernel parks
        \\// core 1 on its WFE loop (no eligible successor), core 0's tick
        \\// wakes the task, and core 1's next tick resumes it.
        \\mov x0, #2
        \\mov x8, #4
        \\svc #0
        \\cmp x0, #0
        \\b.ne 3f // wrong sleep return: fail-safe park
        \\mov x0, #1
        \\adr x1, 2f
        \\mov x2, #26 // "smp1: exiting from core 1\n"
        \\mov x8, #1
        \\svc #0
        \\mov x0, #0 // clean exit
        \\mov x8, #3
        \\svc #0
        \\3:
        \\b 3b
        \\1:
        \\.ascii "smp1: hello from core-1 userland\n"
        \\2:
        \\.ascii "smp1: exiting from core 1\n"
    );
}

test "user smp1 module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user smp1: the marker shapes, sleep length, and exit status are pinned (live-gate grep targets)" {
    // The exact bytes the payload writes (the `#33` / `#26` lengths in
    // the asm and the `1:` / `2:` `.ascii` must match these consts — a
    // drift breaks the live gate's smp1 assertions, never silently).
    try std.testing.expectEqualStrings("smp1: hello from core-1 userland\n", hello_marker);
    try std.testing.expectEqual(@as(usize, 33), hello_marker.len);
    try std.testing.expectEqualStrings("smp1: exiting from core 1\n", exiting_marker);
    try std.testing.expectEqual(@as(usize, 26), exiting_marker.len);
    // The sleep window (the `#2` immediate in the asm) and the exit status
    // (the `#0` immediate) are the live gate's assertions.
    try std.testing.expectEqual(@as(u64, 2), sleep_ticks);
    try std.testing.expectEqual(@as(u64, 0), exit_status);
}
