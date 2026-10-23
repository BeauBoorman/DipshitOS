//! census (M188e, #3190): SMPEV.BIN — gate-referenced: live-smp-stress.
//! VirelaiOS four-core stress EV hammer — SMPEV.BIN (claim 907,
//! issue #858). Pinned to CORE 0 by the gate (`exec -c0 SMPEV.BIN` — the
//! explicit core-0 pin, secondary_ok off so no secondary core can steal
//! it); it hammers the EV service domain (slots 40/21 — app timers and
//! event poll) in a tight, bounded loop, so its core-0 traffic runs
//! CONCURRENTLY with the FILE hammer on core 1, the NET hammer on core 2,
//! and the WIN hammer on core 3. The tick's own on_tick work (app timers,
//! WM pacing, CPU limits) needs the SAME ev|kernel domain bits — so this
//! hammer doubles as the #858 probe for the tick's ev+kernel try-take
//! starving under sustained EV traffic: a starved tick delays the very
//! EVENT_TIMER this hammer waits for, and its bounded poll expires.
//!
//! Shape: 6 timer events — per event: `sys_timer_set(1)` arms a 1-tick
//! app timer, then a bounded poll loop (sys_poll_event + sys_yield, up to
//! 2000 tries) waits for the EVENT_TIMER to land in this process's ADR
//! 0009 queue (fired by core-0's on_tick — a real ring/timer round trip).
//! One exact `smpev: ev=<n>` line per event (~1 s apart), then
//! `smpev: done events=6`, then sys_exit(0). A lost timer event, a
//! duplicate staging, a starved tick, or a cross-domain lock hold breaks
//! a marker or the clean reap.
//!
//! Plain freestanding Zig (the calc/notepad _start(.c) shape), no libc.
//! The marker/count constants are `pub const`s pinned by host tests so
//! the live gate's grep targets cannot drift from the payload.

const std = @import("std");
const st = @import("lib/smpst.zig");

/// The number of 1-tick app-timer events this hammer waits for.
pub const events: u32 = 6;
/// The bounded poll budget per event (a starved tick expires it).
pub const poll_budget: u32 = 2000;
/// The exit status.
pub const exit_status: u32 = 0;

/// A REAL writable global — forces a .bss segment (see smpst_file.zig:
/// the DSK3 loader maps it EL0-RW and the per-process uaccess regions
/// carry it across SVCs; hammering it under load exercises that seam).
var done: u32 = 0;

pub export fn _start() callconv(.c) noreturn {
    var ev: st.Event = undefined;
    while (done < events) {
        if (st.timer_set(1) != 0) st.exit_process(141);
        var tries: u32 = 0;
        var fired = false;
        while (tries < poll_budget and !fired) : (tries += 1) {
            const got = st.poll_event(&ev);
            if (got > 0 and ev.kind == st.EVENT_TIMER) {
                fired = true;
            } else {
                st.yield_task();
            }
        }
        if (!fired) st.exit_process(142);
        done += 1;
        st.print("smpev: ", "ev={d}\n", .{done});
    }
    _ = st.timer_cancel();
    st.print("smpev: ", "done events={d}\n", .{done});
    st.exit_process(exit_status);
}

test "user smpev: marker/count/exit constants are pinned (live-gate targets)" {
    try std.testing.expectEqual(@as(u32, 6), events);
    try std.testing.expectEqual(@as(u32, 2000), poll_budget);
    try std.testing.expectEqual(@as(u16, 9), st.EVENT_TIMER);
    try std.testing.expectEqual(@as(u32, 0), exit_status);
}

test "user smpev module compiles on the host" {
    _ = @intFromPtr(&_start);
}
