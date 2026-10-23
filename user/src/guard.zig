//! census (M188e, #3190): GUARD.BIN — gate-referenced: live-m16-composition, live-m16-guards.
//! VirelaiOS twenty-ninth ESP user program — GUARD.BIN (Milestone 16, Card
//! C2, claim 8403).
//!
//! The hostile-EL0-refused proof: a program that steps OFF its own stack
//! into the guard page below it. The user root maps only text/data/stack, so
//! the page below the stack bottom is UNMAPPED — a store there takes a real
//! EL0 data abort, and the kernel's fault dispatcher REAPS this process
//! (status 139, `reserved_fault_status`) instead of parking the machine. The
//! marker prints BEFORE the fault so the live gate can place it; the
//! unreachable exit-1 branch only fires if the guard gap is ever closed (a
//! gate failure).
//!
//! Naked asm with the fixed register ABI (sys_write = slot 1, sys_exit =
//! slot 3). The exec'd stack is 192 KiB (`scheduler.task_stack_size`, grown
//! from 32 KiB in #1336), sp_el0 starts at
//! `stack_va + 196608` (0x30000); stepping `#0x31000` (196 KiB) lands exactly
//! 4 KiB below the stack bottom — the guard page. (The old `#0x9000` step only
//! cleared 36 KiB of a 192 KiB stack, so the store landed in mapped stack
//! and the exit-1 branch fired — the closed-guard-gap regression behind
//! the m16 live-gate reds.)

const std = @import("std");

/// The exact alive marker the live gate greps for.
pub const alive_line: []const u8 = "guard: stepping off\n";
/// The reserved fault status the kernel reaps this program with.
pub const fault_status: u64 = 139;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// Print the alive marker BEFORE the fault (the gate's anchor).
        \\mov x0, #1
        \\adr x1, 1f
        \\mov x2, #20
        \\mov x8, #1
        \\svc #0
        \\// Step 196 KiB below the stack top: sp_el0 = stack_va + 192 KiB, so
        \\// this lands at stack_va - 4 KiB — the guard page just below the
        \\// stack bottom. The store faults (data abort) and the kernel reaps
        \\// this process with status 139.
        \\sub sp, sp, #0x31000
        \\mov x0, #0xdead
        \\str x0, [sp]
        \\// Unreachable unless the guard page was mistakenly mapped: exit 1
        \\// (a distinct status the gate treats as failure).
        \\mov x0, #1
        \\mov x8, #3
        \\svc #0
        \\1:
        \\.ascii "guard: stepping off\n"
    );
}

test "user guard: module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user guard: the marker shapes are pinned (live-gate grep targets)" {
    try std.testing.expectEqualStrings("guard: stepping off\n", alive_line);
    try std.testing.expectEqual(@as(usize, 20), alive_line.len);
    try std.testing.expectEqual(@as(u64, 139), fault_status);
}
