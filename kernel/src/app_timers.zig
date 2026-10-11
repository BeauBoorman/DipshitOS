//! VirelaiOS bounded per-process application timer facility (milestone
//! fourteen, card S2 — claim 7323, issue #176).
//!
//! ONE countdown timer per process: `sys_timer_set` (slot 40) arms the
//! calling process's timer to fire exactly ONE `TIMER` event (kind 9) into
//! its ADR 0009 event queue after a delay measured in SCHEDULER ticks (the
//! same tick the `sys_sleep` deadlines count — 1 s on VZ); `sys_timer_cancel`
//! (slot 41) disarms it. The fire is driven from `scheduler.on_tick`, the
//! SAME host-testable seam that wakes sleepers, so the real IRQ tick and
//! host tests share one path.
//!
//! This module is PURE STORAGE — fixed BSS arrays (armed flag, countdown,
//! counters), one slot per process, zero allocation, no libc/POSIX, no
//! policy. The syscall layer owns validation (process-caller check, delay
//! clamping, error codes). Process lifecycle resets the slot on create /
//! exec / exit (alongside `events.reset` / `file_table.reset_process`), so
//! a recycled pid never inherits a stale timer and a dead process's timer
//! never fires.
//!
//! Firing posts an event through `events.push`, which already wakes a task
//! blocked in `sys_wait_event` via the `on_event_pushed` hook — an app that
//! arms a timer and blocks observes the `TIMER` event the moment the
//! countdown reaches zero, with NO spin loop.

const std = @import("std");
const process = @import("process.zig"); // the registry bound (max_processes)
const events = @import("events.zig"); // the ADR 0009 queue the TIMER event lands in

/// Longest countdown a caller may arm, in scheduler ticks (1 s each on VZ):
/// one hour, bounded like every other kernel resource. A longer delay is
/// truncated honestly at the syscall layer (the ipc/udp truncation
/// pattern). Zero is clamped to 1 — the same minimum as `sys_sleep`.
pub const max_delay_ticks: u64 = 3600;

/// The armed flag, countdown, and counters, indexed by PROCESS id (the
/// facility is per-process, like the event queue it fires into).
var armed: [process.max_processes]bool = @as([process.max_processes]bool, @splat(@as(bool, false)));
var remaining: [process.max_processes]u64 = @as([process.max_processes]u64, @splat(@as(u64, 0)));
var set_counts: [process.max_processes]u64 = @as([process.max_processes]u64, @splat(@as(u64, 0)));
var fired_counts: [process.max_processes]u64 = @as([process.max_processes]u64, @splat(@as(u64, 0)));
var cancel_counts: [process.max_processes]u64 = @as([process.max_processes]u64, @splat(@as(u64, 0)));

fn in_range(pid: usize) bool {
    return pid < process.max_processes;
}

/// Reset EVERY process's timer (kernel boot and test setups).
pub fn init() void {
    for (&armed) |*a| a.* = false;
    for (&remaining) |*r| r.* = 0;
    for (&set_counts) |*c| c.* = 0;
    for (&fired_counts) |*c| c.* = 0;
    for (&cancel_counts) |*c| c.* = 0;
}

/// Clear ONE process's timer and its counters. Called on process
/// creation / exec / reap (the same lifecycle reset `events.reset` gets),
/// so a recycled process id never inherits an earlier occupant's timer.
pub fn reset(pid: usize) void {
    if (!in_range(pid)) return;
    armed[pid] = false;
    remaining[pid] = 0;
    set_counts[pid] = 0;
    fired_counts[pid] = 0;
    cancel_counts[pid] = 0;
}

/// Arm (or re-arm — replacing any pending timer) process `pid`'s countdown
/// to fire once after `delay` scheduler ticks. `delay` is clamped into
/// [1, max_delay_ticks] here (0 → 1, over-long → max); the syscall layer
/// validates the process caller. Returns true (always succeeds for an
/// in-range pid).
pub fn set(pid: usize, delay: u64) bool {
    if (!in_range(pid)) return false;
    const d = @min(@max(delay, 1), max_delay_ticks);
    armed[pid] = true;
    remaining[pid] = d;
    set_counts[pid] +%= 1;
    return true;
}

/// Disarm process `pid`'s timer. Returns true if a pending timer was
/// canceled, false if none was armed (the syscall reports this).
pub fn cancel(pid: usize) bool {
    if (!in_range(pid)) return false;
    if (!armed[pid]) return false;
    armed[pid] = false;
    remaining[pid] = 0;
    cancel_counts[pid] +%= 1;
    return true;
}

/// True while process `pid` has an armed countdown.
pub fn armed_pending(pid: usize) bool {
    if (!in_range(pid)) return false;
    return armed[pid];
}

/// Scheduler-tick fire (called from `scheduler.on_tick` AFTER the tick
/// counter advanced, IRQ context on the real tick — pure BSS writes + the
/// event push, no console, no allocation): count every armed timer down one
/// tick; a countdown that reaches zero fires exactly ONE `TIMER` event into
/// that process's queue and disarms (one-shot — periodic apps re-arm in
/// their event handler). `events.push` wakes a blocked `sys_wait_event`
/// caller through the existing hook.
pub fn on_tick() void {
    var pid: usize = 0;
    while (pid < process.max_processes) : (pid += 1) {
        if (!armed[pid]) continue;
        remaining[pid] -%= 1;
        if (remaining[pid] != 0) continue;
        armed[pid] = false;
        fired_counts[pid] +%= 1;
        events.push(pid, .{ .kind = events.TIMER, .flags = 0, .seq = 0, .arg0 = 0, .arg1 = 0 });
    }
}

pub const TimerInfo = struct {
    armed: bool,
    remaining: u64,
    sets: u64,
    fired: u64,
    cancels: u64,
};

pub fn info(pid: usize) TimerInfo {
    return .{
        .armed = if (in_range(pid)) armed[pid] else false,
        .remaining = if (in_range(pid)) remaining[pid] else 0,
        .sets = if (in_range(pid)) set_counts[pid] else 0,
        .fired = if (in_range(pid)) fired_counts[pid] else 0,
        .cancels = if (in_range(pid)) cancel_counts[pid] else 0,
    };
}

// ---------------------------------------------------------------------------
// Tests (host-side; the live EL0 round trip is proven on VZ by
// tools/verify-live-timers.sh, class B)
// ---------------------------------------------------------------------------

test "app_timers: set/cancel/fire countdown round-trips a TIMER event" {
    init();
    events.init();
    try std.testing.expect(!armed_pending(0));

    // A 2-tick countdown fires after TWO on_tick calls.
    try std.testing.expect(set(0, 2));
    try std.testing.expect(armed_pending(0));
    try std.testing.expectEqual(@as(u64, 0), events.pending(0));
    on_tick();
    try std.testing.expect(armed_pending(0));
    try std.testing.expectEqual(@as(u64, 0), events.pending(0));
    on_tick();
    try std.testing.expect(!armed_pending(0));
    try std.testing.expectEqual(@as(usize, 1), events.pending(0));
    const ev = events.peek(0).?;
    try std.testing.expectEqual(events.TIMER, ev.kind);
    try std.testing.expectEqual(@as(u64, 1), info(0).fired);
    try std.testing.expectEqual(@as(u64, 1), info(0).sets);
}

test "app_timers: clamping — 0 clamps to 1 tick, over-long truncates at max" {
    init();
    events.init();

    try std.testing.expect(set(0, 0)); // 0 -> 1
    try std.testing.expectEqual(@as(u64, 1), info(0).remaining);
    on_tick();
    try std.testing.expect(!armed_pending(0));
    try std.testing.expectEqual(@as(usize, 1), events.pending(0));
    _ = events.drop(0);

    try std.testing.expect(set(0, max_delay_ticks + 1000));
    try std.testing.expectEqual(max_delay_ticks, info(0).remaining);
    on_tick();
    try std.testing.expectEqual(max_delay_ticks - 1, info(0).remaining);
    try std.testing.expect(armed_pending(0));
    try std.testing.expect(cancel(0));
}

test "app_timers: cancel disarms; re-arm replaces a pending timer" {
    init();
    events.init();

    // Cancel with nothing pending reports false.
    try std.testing.expect(!cancel(0));
    try std.testing.expectEqual(@as(u64, 0), info(0).cancels);

    try std.testing.expect(set(0, 5));
    // Re-arm replaces the pending countdown (back to 5).
    try std.testing.expect(set(0, 3));
    try std.testing.expectEqual(@as(u64, 3), info(0).remaining);
    try std.testing.expectEqual(@as(u64, 2), info(0).sets);

    // Cancel a pending timer reports true and nothing ever fires.
    try std.testing.expect(cancel(0));
    try std.testing.expect(!armed_pending(0));
    try std.testing.expectEqual(@as(u64, 1), info(0).cancels);
    on_tick();
    on_tick();
    on_tick();
    try std.testing.expectEqual(@as(usize, 0), events.pending(0));
    try std.testing.expectEqual(@as(u64, 0), info(0).fired);
}

test "app_timers: per-process isolation, out-of-range pids, and reset" {
    init();
    events.init();

    try std.testing.expect(set(0, 2));
    try std.testing.expect(set(1, 2));
    try std.testing.expect(!set(process.max_processes, 2)); // out of range
    try std.testing.expect(!cancel(process.max_processes));
    try std.testing.expect(!armed_pending(process.max_processes));

    reset(0);
    try std.testing.expect(!armed_pending(0));
    try std.testing.expect(armed_pending(1));

    on_tick();
    on_tick();
    // Only pid 1 fired (pid 0's reset cleared it).
    try std.testing.expectEqual(@as(usize, 0), events.pending(0));
    try std.testing.expectEqual(@as(usize, 1), events.pending(1));

    init();
    try std.testing.expect(!armed_pending(1));
    try std.testing.expectEqual(@as(u64, 0), info(1).sets);
    try std.testing.expectEqual(@as(u64, 0), info(1).fired);
}

var test_woke: usize = 0;

test "app_timers: a fired event wakes a blocked sys_wait_event task through the hook" {
    init();
    events.init();
    test_woke = 0;
    events.on_event_pushed = struct {
        fn f(pid: usize) void {
            _ = pid;
            test_woke += 1;
        }
    }.f;
    defer events.on_event_pushed = null;

    try std.testing.expect(set(0, 1));
    on_tick();
    try std.testing.expectEqual(@as(usize, 1), test_woke);
    try std.testing.expectEqual(@as(usize, 1), events.pending(0));
    events.on_event_pushed = null;
}
