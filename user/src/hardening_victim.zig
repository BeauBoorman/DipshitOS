//! census (M188e, #3190): VICTIM.BIN — gate-referenced: live-hardening.
//! VirelaiOS twenty-fourth ESP user program — VICTIM.BIN (Milestone 14,
//! Card S4, claim 4482).
//!
//! The hostile-consumer proof's VICTIM: opens user window 2 (OWNED by this
//! process — the per-process ownership model), fills it, presents it, and
//! yield-loops FOREVER so the window stays alive on the scanout. A second
//! process (HARDEN.BIN) then attempts cross-process access to window 2 and
//! must be refused with a clean error (EINVAL) — the S4 ownership audit's
//! live proof.
//!
//! Plain EL0 program: `export fn _start`, the ui.zig toolkit, no libc.
//! The window geometry/colors reuse WIN.BIN's deterministic constants so
//! the gate can also pixel-prove the victim's window rendered.

const std = @import("std");
const ui = @import("lib/ui.zig");

/// The id VICTIM.BIN's `sys_win_open` returns (the first free user slot).
pub const window_id: u32 = 2;
/// The exact marker line the live gate greps for.
pub const ready_line: []const u8 = "victim: window=2 ready\n";

export fn _start() callconv(.c) noreturn {
    const win = ui.win_open(64, 64, 512, 384);
    if (win != window_id) {
        ui.write_console("victim: open failed\n");
        ui.exit_process(1);
    }
    ui.win_fill(window_id, 0, 0, 512, 384, 0x1a2b3c);
    ui.win_fill(window_id, 8, 8, 48, 48, 0xff0000);
    ui.win_present(window_id);
    ui.write_console(ready_line);

    // Keep the window alive: the compositor's idle loop blits it; the
    // process only dies when killed or the machine reboots (the real
    // teardown semantic — HARDEN.BIN must NOT be able to close it).
    while (true) {
        ui.yield_task();
    }
}

test "user hardening_victim: module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user hardening_victim: the ready marker shape is pinned" {
    try std.testing.expectEqualStrings("victim: window=2 ready\n", ready_line);
    try std.testing.expectEqual(@as(usize, 25), ready_line.len);
    try std.testing.expectEqual(@as(u32, 2), window_id);
}
