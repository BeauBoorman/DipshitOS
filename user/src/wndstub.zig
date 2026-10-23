//! census (M188e, #3190): WNDSTUB.BIN — gate-referenced: live-wm-seat-gate, live-wmctl-register.
//! VirelaiOS M32 WMS2 registrant stub — WNDSTUB.BIN (issue #622, the live
//! `verify-live-wmctl-register.sh` gate payload).
//!
//! The MINIMAL window-manager-server registrant: it registers through the
//! kernel render-server register (slot 65 `sys_wmctl` REGISTER), waits for
//! a `COMPOSITE_TICK` (kind 18) on its process event queue via
//! `sys_wait_event` (slot 22) — the tick the kernel delivers once per
//! scheduler tick while a WM is registered — then issues `REQUEST_PRESENT`
//! (slot 65, cmd 3) and exits. The kernel reports the teardown fallback
//! (`wm: unregistered, shim resumed`) and composite pacing returns to the
//! shell idle shim automatically.
//!
//! Same naked-asm, fixed-register-ABI shape as every other ESP program (no
//! Zig-generated memory references or calls; sys_write for the markers,
//! sys_wait_event for the tick, sys_exit for the status). The marker
//! constants are exposed as `pub const`s so the host tests pin the EXACT
//! shapes and the gate's grep targets cannot drift.

const std = @import("std");

/// Written right after REGISTER returns 0 (proves the registrant is live).
pub const registered_marker: []const u8 = "wndstub: registered\n";
/// Written after a COMPOSITE_TICK (kind 18) is received.
pub const tick_marker: []const u8 = "wndstub: tick\n";
/// Written after REQUEST_PRESENT returns 0 (the present counter advanced).
pub const present_marker: []const u8 = "wndstub: present ok\n";
/// M97g (#2079): written when REGISTER refuses (EACCES from the seat
/// provenance gate when spawned by an ordinary EL0 shell) — the live
/// proof an EL0-spawned process cannot claim the seat.
pub const refused_marker: []const u8 = "wndstub: register refused\n";
/// The exit status (0 — the stub ends cleanly; the fallback report + the
/// `wm` row are the teardown evidence).
pub const exit_status: u64 = 0;
/// The refusal exit status (1 — a refused REGISTER is an honest failure).
pub const refused_status: u64 = 1;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// 1. sys_wmctl(REGISTER) — slot 65, cmd 1. Only succeeds when the
        \\// compositor is armed (the gate boots with --screen); ENXIO
        \\// otherwise. A refused REGISTER prints the refusal marker and
        \\// exits nonzero (M97g #2079: an EL0-spawned caller must be seen
        \\// refused, not silently parked — the seat gate needs the proof).
        \\mov x0, #1
        \\mov x8, #65
        \\svc #0
        \\cmp x0, #0
        \\b.ne 8f
        \\mov x0, #1
        \\adr x1, 1f
        \\mov x2, #20 // "wndstub: registered\n"
        \\mov x8, #1
        \\svc #0
        \\// 2. Block on sys_wait_event(sp) until the kernel delivers
        \\// COMPOSITE_TICK (kind 18) — the pacing tick the register enabled.
        \\sub sp, sp, #32
        \\10:
        \\mov x0, sp
        \\mov x8, #22
        \\svc #0
        \\cmp x0, #1
        \\b.ne 10b // spurious/no event: keep waiting
        \\ldrh w20, [sp, #0] // kind
        \\cmp w20, #18
        \\b.ne 10b // not a composite tick: keep waiting
        \\mov x0, #1
        \\adr x1, 2f
        \\mov x2, #14 // "wndstub: tick\n"
        \\mov x8, #1
        \\svc #0
        \\// 3. sys_wmctl(REQUEST_PRESENT) — slot 65, cmd 3: transfer+flush
        \\// the scanout now; the kernel advances the present counter.
        \\mov x0, #3
        \\mov x8, #65
        \\svc #0
        \\cmp x0, #0
        \\b.ne 9f
        \\mov x0, #1
        \\adr x1, 3f
        \\mov x2, #20 // "wndstub: present ok\n"
        \\mov x8, #1
        \\svc #0
        \\// 4. sys_exit(0) — slot 3. The exit path unregisters the WM and
        \\// the kernel falls back to the shell idle shim.
        \\mov x0, #0
        \\mov x8, #3
        \\svc #0
        \\8:
        \\// REGISTER refused: report it, then sys_exit(1).
        \\mov x0, #1
        \\adr x1, 4f
        \\mov x2, #26 // "wndstub: register refused\n"
        \\mov x8, #1
        \\svc #0
        \\mov x0, #1
        \\mov x8, #3
        \\svc #0
        \\9:
        \\b 9b
        \\1:
        \\.ascii "wndstub: registered\n"
        \\2:
        \\.ascii "wndstub: tick\n"
        \\3:
        \\.ascii "wndstub: present ok\n"
        \\4:
        \\.ascii "wndstub: register refused\n"
    );
}

test "user wndstub module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user wndstub: the marker shapes are pinned (live-gate grep targets)" {
    try std.testing.expectEqualStrings("wndstub: registered\n", registered_marker);
    try std.testing.expectEqual(@as(usize, 20), registered_marker.len);
    try std.testing.expectEqualStrings("wndstub: tick\n", tick_marker);
    try std.testing.expectEqual(@as(usize, 14), tick_marker.len);
    try std.testing.expectEqualStrings("wndstub: present ok\n", present_marker);
    try std.testing.expectEqual(@as(usize, 20), present_marker.len);
    try std.testing.expectEqualStrings("wndstub: register refused\n", refused_marker);
    try std.testing.expectEqual(@as(usize, 26), refused_marker.len);
    try std.testing.expectEqual(@as(u64, 1), refused_status);
}
