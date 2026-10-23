//! census (M188e, #3190): SCHEDRING.BIN — gate-referenced: live-sched-ring.
//! VirelaiOS sched-ring stress task — SCHEDRING.BIN (claim 881, #856
//! slice 4 — the live proof for the per-core ready rings).
//!
//! The gate runs TWO SCHEDRING.BIN processes: one PINNED to core 1
//! (`exec -c1 SCHEDRING.BIN` — home ring 1) and one FLOATING (`exec
//! SCHEDRING.BIN` — home ring 0, stolen onto core 1 by the idle-branch
//! steal view, also claimable by core 0). Each program then:
//!
//!   1. Runs `sleep_count` × sys_sleep(1) — every wake is a ring resume,
//!      so a LOST wakeup hangs the program before the slept marker and
//!      fails the gate; a DUPLICATE staging (two cores on one TCB) would
//!      corrupt the shared frame/counter and fail the exact-count greps
//!      (or crash).
//!   2. Runs `yield_count` × sys_yield in a tight loop — the counter
//!      lives in x19, which the vector frame saves/restores across every
//!      switch, so any save/restore corruption breaks the exact count.
//!   3. Writes its exact-count markers and exits 0 — `slept=4` /
//!      `yielded=32` / `done` must each land EXACTLY TWICE in the gate's
//!      serial log (once per process), together with two exit/reap
//!      reports and the kernel's `smp: secondary runs=N
//!      task=SCHEDRING.BIN` evidence line.
//!
//! Same naked-asm, fixed-register-ABI shape as every other ESP program
//! (no Zig-generated memory references or calls). The marker bytes, the
//! loop counts, and the exit status are exposed as `pub const`s so the
//! host tests pin the EXACT shapes (the live gate's grep targets) and
//! the payload cannot drift.

const std = @import("std");

/// Written after all `sleep_count` sleeps return (each wake = one ring
/// resume — a lost wakeup or a duplicated staging breaks this marker).
pub const slept_marker: []const u8 = "schedring: slept=4\n";
/// Written after all `yield_count` yields return (the loop counter rides
/// in x19 across every switch — a corrupt save/restore breaks this).
pub const yielded_marker: []const u8 = "schedring: yielded=32\n";
/// Written immediately before sys_exit(0) — the completion proof.
pub const done_marker: []const u8 = "schedring: done\n";
/// The scheduler-tick sleeps per program (1 tick = 1 s on VZ): 4 wakes
/// per program, 8 across the gate.
pub const sleep_count: u64 = 4;
/// The tight-loop cooperative yields per program.
pub const yield_count: u64 = 32;
/// The exit status (0 — clean; the gate greps both exit/reap reports).
pub const exit_status: u64 = 0;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// SCHEDRING.BIN: 4 sleeps (exact-count), 32 yields (exact-count),
        \\// markers, clean exit. x19 carries each loop counter across every
        \\// preemption/wake (callee-saved half of the vector frame).
        \\mov x19, #4
        \\1:
        \\mov x0, #1
        \\mov x8, #4 // sys_sleep(1 tick)
        \\svc #0
        \\cmp x0, #0
        \\b.ne 5f // a failed sleep (EINVAL) -> fail-safe park
        \\subs x19, x19, #1
        \\b.ne 1b
        \\mov x0, #1
        \\adr x1, 2f
        \\mov x2, #19 // "schedring: slept=4\n"
        \\mov x8, #1 // sys_write
        \\svc #0
        \\mov x19, #32
        \\3:
        \\mov x0, #0
        \\mov x8, #2 // sys_yield
        \\svc #0
        \\subs x19, x19, #1
        \\b.ne 3b
        \\mov x0, #1
        \\adr x1, 4f
        \\mov x2, #22 // "schedring: yielded=32\n"
        \\mov x8, #1
        \\svc #0
        \\mov x0, #1
        \\adr x1, 6f
        \\mov x2, #16 // "schedring: done\n"
        \\mov x8, #1
        \\svc #0
        \\mov x0, #0
        \\mov x8, #3 // sys_exit(0)
        \\svc #0
        \\5:
        \\b 5b
        \\2:
        \\.ascii "schedring: slept=4\n"
        \\4:
        \\.ascii "schedring: yielded=32\n"
        \\6:
        \\.ascii "schedring: done\n"
    );
}

test "user schedring module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user schedring: the marker shapes, loop counts, and exit status are pinned (live-gate grep targets)" {
    // The exact bytes the payload writes (the `#19` / `#22` / `#16`
    // lengths in the asm and the `2:` / `4:` / `6:` .ascii must match
    // these consts — a drift breaks the live gate's assertions, never
    // silently).
    try std.testing.expectEqualStrings("schedring: slept=4\n", slept_marker);
    try std.testing.expectEqual(@as(usize, 19), slept_marker.len);
    try std.testing.expectEqualStrings("schedring: yielded=32\n", yielded_marker);
    try std.testing.expectEqual(@as(usize, 22), yielded_marker.len);
    try std.testing.expectEqualStrings("schedring: done\n", done_marker);
    try std.testing.expectEqual(@as(usize, 16), done_marker.len);
    // The loop counts (the `#4` / `#32` immediates in the asm) and the
    // exit status (the `#0` immediate) are the gate's assertions.
    try std.testing.expectEqual(@as(u64, 4), sleep_count);
    try std.testing.expectEqual(@as(u64, 32), yield_count);
    try std.testing.expectEqual(@as(u64, 0), exit_status);
}
