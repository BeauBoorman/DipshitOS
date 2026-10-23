//! census (M188e, #3190): HARDEN.BIN — gate-referenced: live-hardening.
//! VirelaiOS twenty-fifth ESP user program — HARDEN.BIN (Milestone 14,
//! Card S4, claim 4482).
//!
//! The hostile-consumer proof: a SEPARATE process from VICTIM.BIN attempts
//! cross-process access to the victim's window (id 2) through the ADR 0007
//! window syscalls. Every attempt must be REFUSED with a clean error
//! (EINVAL — the per-process ownership check behind every `sys_win_*`
//! handler), and the program must SURVIVE to report `hardening: refused`
//! and exit. If any attack succeeds (an ownership gap), the program
//! reports it and exits nonzero — the gate fails on the guest's own
//! evidence.
//!
//! Attacks: fill, present, close, move, and query (a pointer-taking
//! attack — the ownership check runs BEFORE the user buffer is touched).
//! The raw `syscallN` wrappers observe the return values the void-returning
//! `ui.win_*` helpers discard.

const std = @import("std");
const ui = @import("lib/ui.zig");

/// The victim's window id (a deterministic gate constant — the SAME id
/// VICTIM.BIN opens).
pub const target_window: u32 = 2;
/// The exit status HARDEN.BIN uses when every attack was refused.
pub const exit_status: u32 = 44;
/// The exact marker lines the live gate greps for.
pub const refused_line: []const u8 = "hardening: refused\n";
pub const survived_line: []const u8 = "hardening: survived\n";

export fn _start() callconv(.c) noreturn {
    var refused: u32 = 0;

    // sys_win_fill(2, ...) — render into the victim's window.
    const rc_fill = ui.syscall6(ui.sys_win_fill_num, target_window, 0, 0, 8, 8, 0xff0000);
    if (rc_fill == 0) {
        ui.write_console("hardening: FILL NOT REFUSED\n");
        ui.exit_process(1);
    }
    if (rc_fill == -1) refused += 1;

    // sys_win_present(2) — force-composite the victim's window.
    const rc_present = ui.syscall1(ui.sys_win_present_num, target_window);
    if (rc_present == 0) {
        ui.write_console("hardening: PRESENT NOT REFUSED\n");
        ui.exit_process(2);
    }
    if (rc_present == -1) refused += 1;

    // sys_win_close(2) — release the victim's window (the teardown attack).
    const rc_close = ui.syscall1(ui.sys_win_close_num, target_window);
    if (rc_close == 0) {
        ui.write_console("hardening: CLOSE NOT REFUSED\n");
        ui.exit_process(3);
    }
    if (rc_close == -1) refused += 1;

    // sys_win_move(2, ...) — reposition the victim's window.
    const rc_move = ui.syscall3(ui.sys_win_move_num, target_window, 100, 100);
    if (rc_move == 0) {
        ui.write_console("hardening: MOVE NOT REFUSED\n");
        ui.exit_process(4);
    }
    if (rc_move == -1) refused += 1;

    // sys_win_query(2, buf) — read the victim's window state through a
    // user buffer (the pointer-taking attack; refused before the buffer
    // is ever touched).
    var buf: [32]u8 = undefined;
    const rc_query = ui.syscall2(ui.sys_win_query_num, target_window, @intFromPtr(&buf));
    if (rc_query == 0) {
        ui.write_console("hardening: QUERY NOT REFUSED\n");
        ui.exit_process(5);
    }
    if (rc_query == -1) refused += 1;

    if (refused < 5) {
        ui.write_console("hardening: SOME ATTACKS SUCCEEDED\n");
        ui.exit_process(6);
    }

    ui.write_console(refused_line);
    ui.write_console(survived_line);
    ui.exit_process(exit_status);
}

test "user harden: module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user harden: the marker shapes are pinned (live-gate grep targets)" {
    try std.testing.expectEqualStrings("hardening: refused\n", refused_line);
    try std.testing.expectEqual(@as(usize, 19), refused_line.len);
    try std.testing.expectEqualStrings("hardening: survived\n", survived_line);
    try std.testing.expectEqual(@as(usize, 20), survived_line.len);
    try std.testing.expectEqual(@as(u32, 2), target_window);
    try std.testing.expectEqual(@as(u32, 44), exit_status);
}
