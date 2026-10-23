//! census (M188e, #3190): STATUS43.BIN — gate-referenced: live-exec, live-jobs, live-wait.
//! VirelaiOS fourth ESP user program — STATUS43.BIN (milestone-four
//! follow-on 4, card 4c — claim 9946).
//!
//! The SHORT third program in the exit-status-propagation gate: the
//! observer (COUNTER.BIN, exec'd with the wait target pid in its argv)
//! blocks in `sys_wait` (slot 8) until THIS program exits, then reads the
//! status back. This program makes the block deterministic: it prints its
//! alive marker, SLEEPS for `sleep_ticks` scheduler ticks (slot 4) — a
//! multi-second window in which the observer execs, issues its wait, and
//! is observed blocked while the target is still alive — then prints its
//! exiting marker and calls sys_exit (slot 3) with status 43. The kernel's
//! exit path records the status AND wakes the waiter, patching 43 into
//! the waiter's saved frame.
//!
//! Same naked-asm, fixed-register-ABI shape as every other ESP program
//! (no Zig-generated memory references or calls; sys_write for the two
//! markers, sys_sleep for the window, sys_exit for the status). The
//! terminal branch is a fail-safe park if the sleep return comes back
//! wrong.
//!
//! The marker bytes, the sleep length, and the exit status are exposed as
//! `pub const`s so the host tests pin the EXACT shapes (the live gate's
//! grep targets and the observed status) and the payload cannot drift.

const std = @import("std");

/// The exact bytes STATUS43.BIN writes on entry (proves the program is
/// running before it sleeps). Host-tested so the live gate's grep target
/// cannot drift from the payload's `.ascii`.
pub const alive_marker: []const u8 = "status43: alive\n";
/// The exact bytes STATUS43.BIN writes right before sys_exit.
pub const exiting_marker: []const u8 = "status43: exiting\n";
/// The scheduler-tick sleep that keeps this program alive long enough for
/// the observer to block on it deterministically (the live gate's blocked
/// snapshot runs inside this window; 1 tick = 1 s on VZ).
pub const sleep_ticks: u64 = 6;
/// The exit status the live gate asserts (0x2b = 43, matching USER.BIN's
/// status so the gates share the number).
pub const exit_status: u64 = 0x2b;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// Card 4c (claim 9946): the third program — alive marker, a
        \\// sleep window the observer's wait provably blocks inside, then
        \\// exit status 43.
        \\mov x0, #1
        \\adr x1, 1f
        \\mov x2, #16 // "status43: alive\n"
        \\mov x8, #1
        \\svc #0
        \\// Sleep `sleep_ticks` scheduler ticks (slot 4): the target stays
        \\// alive (its process state stays `running`) while the observer
        \\// execs, blocks in sys_wait, and is snapshotted blocked.
        \\mov x0, #6
        \\mov x8, #4
        \\svc #0
        \\cmp x0, #0
        \\b.ne 3f // wrong sleep return: fail-safe park
        \\mov x0, #1
        \\adr x1, 2f
        \\mov x2, #18 // "status43: exiting\n"
        \\mov x8, #1
        \\svc #0
        \\mov x0, #0x2b // 43
        \\mov x8, #3
        \\svc #0
        \\3:
        \\b 3b
        \\1:
        \\.ascii "status43: alive\n"
        \\2:
        \\.ascii "status43: exiting\n"
    );
}

test "user status43 module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user status43: the marker shapes and exit status are pinned (live-gate grep targets)" {
    // The exact bytes the payload writes (the `#15` / `#18` lengths in
    // the asm and the `1:` / `2:` `.ascii` must match these consts — a
    // drift breaks the live gate's status43 assertions, never silently).
    try std.testing.expectEqualStrings("status43: alive\n", alive_marker);
    try std.testing.expectEqual(@as(usize, 16), alive_marker.len);
    try std.testing.expectEqualStrings("status43: exiting\n", exiting_marker);
    try std.testing.expectEqual(@as(usize, 18), exiting_marker.len);
    // The sleep window (the `#6` immediate in the asm) and the exit status
    // (the `#0x2b` immediate) are the live gate's assertions.
    try std.testing.expectEqual(@as(u64, 6), sleep_ticks);
    try std.testing.expectEqual(@as(u64, 43), exit_status);
}
