//! VirelaiOS bounded per-process event queue (Milestone 9, card E1 — claim 7670).
//!
//! Provides fixed-capacity in-memory event FIFOs for EL0 processes (ADR 0009):
//! - 64 events per process slot (`max_events = 64`; raised 16 -> 64 for
//!   #2260 — the cv input pump can dispatch a whole 32-completion used-ring
//!   pass in one idle turn, and a 16-deep target queue dropped the head of
//!   every such burst (alt-tab / paste-confirm) while the seat was off the
//!   ring).
//! - Statically allocated in kernel BSS (pure BSS, no heap, no allocation).
//! - Drop-oldest discipline when full (tracks monotonic dropped count).
//! - Monotonic sequence numbering per process slot.
//! - Process lifecycle reset hooks (`init`, `reset`).
//!
//! Event wire layout (16 bytes, C ABI):
//!   kind: u16       - event category (1..8)
//!   flags: u16      - modifiers / button bitmask
//!   seq: u32        - monotonic sequence counter
//!   arg0: u32       - event argument 0 (keycode, local X, win ID)
//!   arg1: u32       - event argument 1 (Unicode key codepoint, local Y, old focus)
//!
//! No allocation, no libc, no POSIX.

const std = @import("std");
const process = @import("process.zig"); // the registry bound (max_processes)

/// Event category discriminator constants (ADR 0009 D2).
pub const KEY_DOWN: u16 = 1;
pub const KEY_UP: u16 = 2;
pub const MOUSE_DOWN: u16 = 3;
pub const MOUSE_UP: u16 = 4;
pub const MOUSE_MOVE: u16 = 5;
pub const WIN_FOCUS: u16 = 6;
pub const WIN_BLUR: u16 = 7;
pub const WIN_CLOSE: u16 = 8;
/// Milestone 14 (claim 7323): the per-process app timer fired (posted by
/// `kernel/src/app_timers.zig` when a `sys_timer_set` countdown reaches 0).
pub const TIMER: u16 = 9;
/// Arc2 W1 (claim 3589, ADR 0013 D2): window resized — `arg0 = new w`, `arg1 = new h`.
pub const WIN_RESIZE: u16 = 10;
/// Arc2 W2 (claim 1757, ADR 0013 D2): right-click — `arg0 = local x`, `arg1 = local y` (kind 12 is MOUSE_SCROLL for #236).
pub const MOUSE_RIGHT_DOWN: u16 = 11;
/// Arc4 #236 (ADR 0013 D2): mouse wheel / scroll event.
/// `arg0` packed: bits 0–13 magnitude (1..8191), bit 14 = horizontal
/// (shift+scroll), bit 15 = sign (1 = down/right, 0 = up/left).
/// `arg1 = 0` (reserved).
pub const MOUSE_SCROLL: u16 = 12;
pub const MOUSE_RIGHT_UP: u16 = 13;
/// Arc4 #237 (ADR 0013 D2): pointer entered a window during active drag.
/// `arg0 = payload size`, `arg1 = source pid`.
pub const DRAG_ENTER: u16 = 14;
/// Arc4 #237: pointer left a window during active drag.
/// `arg0 = 0`, `arg1 = source pid`.
pub const DRAG_LEAVE: u16 = 15;
/// Arc4 #237: drop completed on a window.
/// `arg0 = payload size`, `arg1 = source pid`.
pub const DROP: u16 = 16;
/// Arc4 #242 (ADR 0013 D2): unsaved-changes warning posted by compositor
/// when user clicks close on a dirty window. `arg0` = 0 (save),
/// 1 (don't save), 2 (cancel). App must consume within 5 ticks.
pub const WIN_UNSAVED: u16 = 17;

/// ADR 0015 (M32 WMS1, claim 1484): composite/present cadence tick for the
/// registered WM server. RESERVED — no kernel path pushes it until the WMS2
/// claim lands the render-server register; delivered ONLY to the registered
/// WM (the first routing-restricted kind, ADR 0009 D2 note).
pub const COMPOSITE_TICK: u16 = 18;

/// M32 WMS5 (issue #625, claim 9849): the raw absolute pointer stream for
/// the registered WM — the input-seam handover. `arg0` = x|(y<<16) in
/// framebuffer pixels (top-left origin), `flags` low byte = the raw HID
/// button byte (0x01 = left, 0x02 = right, 0x04 = middle — the same bits
/// the XHCI pointer report carries). Routing-restricted like kind 18:
/// pushed ONLY to the registered WM's queue, once per shell-idle pass when
/// the pointer state changed; never generated in shim mode. The WM — not
/// the kernel — hit-tests and decides geometry from this stream.
pub const WM_POINTER: u16 = 19;

/// M32 WMS5 (issue #625, claim 9849): a registry MIRROR push for the
/// registered WM — the kernel's window data, fanned out so the WM can
/// hit-test (it cannot read the kernel's registry directly). `flags` low
/// byte = window id, bit 8 = visible, bit 9 = focused, bits 10–11 =
/// workspace; `arg0` = x|(y<<16), `arg1` = w|(h<<16) (framebuffer pixels,
/// top-left origin). Pushed on every user-window open/close/move/resize/
/// visibility/focus change while a WM is registered; routing-restricted
/// like kind 18 (never generated in shim mode).
pub const WM_WINDOW: u16 = 20;

/// M32 WMS5 Gate 2 (issue #625, claim 4278): the raw KEYBOARD stream for
/// the registered WM — the keyboard half of the input seam (kind 19 was
/// the pointer half). `arg0` = the raw HID keyboard usage byte, `flags` =
/// the ADR 0009 modifier bits (MOD_SHIFT/CTRL/ALT/CMD). Pushed on key-DOWN
/// edges once per shell-idle pass; routing-restricted like kinds 18/19/20
/// (never generated in shim mode). While a WM is registered the kernel
/// stops consuming keyboard GEOMETRY chords (tile/minimize/maximize/etc. —
/// gated behind `wm_owns_input` in the shell idle) and the WM decides them
/// from this stream instead.
pub const WM_KEY: u16 = 21;

/// Modifier bitmasks (flags bits 0..7).
pub const MOD_SHIFT: u16 = 0x0001;
pub const MOD_CTRL: u16 = 0x0002;
pub const MOD_ALT: u16 = 0x0004;
pub const MOD_CMD: u16 = 0x0008;

/// Mouse button bitmasks (flags bits 8..11).
pub const BTN_LEFT: u16 = 0x0100;
pub const BTN_RIGHT: u16 = 0x0200;
pub const BTN_MIDDLE: u16 = 0x0400;

/// Low-byte mouse button bit aliases for raw report handling.
pub const BTN_LEFT_BIT: u8 = 0x01;
pub const BTN_RIGHT_BIT: u8 = 0x02;
pub const BTN_MIDDLE_BIT: u8 = 0x04;

/// The normative 16-byte event wire format (ADR 0009 D1).
pub const Event = extern struct {
    kind: u16,
    flags: u16,
    seq: u32,
    arg0: u32,
    arg1: u32,
};

pub const max_events: usize = 64;
pub const event_bytes: usize = @sizeOf(Event);

// ---------------------------------------------------------------------------
// Queue storage (pure BSS)
// ---------------------------------------------------------------------------

var storage: [process.max_processes][max_events]Event =
    @as([process.max_processes][max_events]Event, @splat(@as([max_events]Event, @as([max_events]Event, @splat(@as(Event, .{ .kind = 0, .flags = 0, .seq = 0, .arg0 = 0, .arg1 = 0 }))))));
var head: [process.max_processes]usize = @as([process.max_processes]usize, @splat(@as(usize, 0)));
var count: [process.max_processes]usize = @as([process.max_processes]usize, @splat(@as(usize, 0)));
var next_seq: [process.max_processes]u32 = @as([process.max_processes]u32, @splat(@as(u32, 1)));
var pushed_counts: [process.max_processes]u64 = @as([process.max_processes]u64, @splat(@as(u64, 0)));
var popped_counts: [process.max_processes]u64 = @as([process.max_processes]u64, @splat(@as(u64, 0)));
var dropped_counts: [process.max_processes]u64 = @as([process.max_processes]u64, @splat(@as(u64, 0)));

/// Hook for scheduler wakeup (notified whenever an event is pushed).
pub var on_event_pushed: ?*const fn (usize) void = null;

fn in_range(pid: usize) bool {
    return pid < process.max_processes;
}

/// Reset every event queue (called on kernel boot and test setups).
pub fn init() void {
    for (&storage) |*ring| {
        for (ring) |*slot| {
            slot.* = .{ .kind = 0, .flags = 0, .seq = 0, .arg0 = 0, .arg1 = 0 };
        }
    }
    for (&head) |*h| h.* = 0;
    for (&count) |*c| c.* = 0;
    for (&next_seq) |*s| s.* = 1;
    for (&pushed_counts) |*p| p.* = 0;
    for (&popped_counts) |*p| p.* = 0;
    for (&dropped_counts) |*d| d.* = 0;
}

/// Clear ONE process's event queue and reset sequence counter.
/// Called on process creation/exec/reap.
pub fn reset(pid: usize) void {
    if (!in_range(pid)) return;
    for (&storage[pid]) |*slot| {
        slot.* = .{ .kind = 0, .flags = 0, .seq = 0, .arg0 = 0, .arg1 = 0 };
    }
    head[pid] = 0;
    count[pid] = 0;
    next_seq[pid] = 1;
    pushed_counts[pid] = 0;
    popped_counts[pid] = 0;
    dropped_counts[pid] = 0;
}

/// Push an event into process `pid`'s event FIFO.
/// If `event.seq` is 0, stamps with the process's monotonic `next_seq`.
/// If full, applies drop-oldest discipline and increments dropped counter.
///
/// COMPOSITE_TICK coalesces under backlog: while the queue is at least
/// half full AND already holds an unconsumed tick, another heartbeat adds
/// no information — merge its damage mask (arg1) into the pending tick and
/// refresh its present sequence (arg0) instead of enqueuing. Below the
/// floor every tick queues normally (the pinned wm_server behavior — the
/// seat expects one pending event per push when it is keeping up). Without
/// this a stalled consumer accrues a tick per second until the queue is
/// all heartbeats and drop-oldest evicts the real input behind them —
/// observed on go-dogfood boot 08: the seat's stall let ticks evict the
/// pointer burst's head (the press that armed the drag never arrived).
const tick_merge_floor: usize = max_events / 2;

pub fn push(pid: usize, ev_in: Event) void {
    if (!in_range(pid) or ev_in.kind == 0) return;

    var ev = ev_in;
    if (ev.kind == COMPOSITE_TICK and count[pid] >= tick_merge_floor) {
        var i: usize = 0;
        while (i < count[pid]) : (i += 1) {
            const s = (head[pid] + i) % max_events;
            if (storage[pid][s].kind == COMPOSITE_TICK) {
                storage[pid][s].arg0 = ev.arg0;
                storage[pid][s].arg1 |= ev.arg1;
                pushed_counts[pid] +%= 1;
                return;
            }
        }
    }
    if (ev.seq == 0) {
        ev.seq = next_seq[pid];
        next_seq[pid] +%= 1;
    }

    if (count[pid] == max_events) {
        // Drop oldest
        head[pid] = (head[pid] + 1) % max_events;
        count[pid] -= 1;
        dropped_counts[pid] +%= 1;
    }

    const slot = (head[pid] + count[pid]) % max_events;
    storage[pid][slot] = ev;
    count[pid] += 1;
    pushed_counts[pid] +%= 1;

    if (on_event_pushed) |hook| {
        hook(pid);
    }
}

/// Peek at the OLDEST event in process `pid`'s queue without consuming it.
pub fn peek(pid: usize) ?Event {
    if (!in_range(pid) or count[pid] == 0) return null;
    return storage[pid][head[pid]];
}

/// Drop (consume) the OLDEST event in process `pid`'s queue.
pub fn drop(pid: usize) void {
    if (!in_range(pid) or count[pid] == 0) return;
    storage[pid][head[pid]] = .{ .kind = 0, .flags = 0, .seq = 0, .arg0 = 0, .arg1 = 0 };
    head[pid] = (head[pid] + 1) % max_events;
    count[pid] -= 1;
    popped_counts[pid] +%= 1;
}

/// Pop and consume the OLDEST event from process `pid`'s queue.
pub fn pop(pid: usize) ?Event {
    if (!in_range(pid) or count[pid] == 0) return null;
    const ev = storage[pid][head[pid]];
    storage[pid][head[pid]] = .{ .kind = 0, .flags = 0, .seq = 0, .arg0 = 0, .arg1 = 0 };
    head[pid] = (head[pid] + 1) % max_events;
    count[pid] -= 1;
    popped_counts[pid] +%= 1;
    return ev;
}

/// Number of pending events in process `pid`'s queue.
pub fn pending(pid: usize) usize {
    if (!in_range(pid)) return 0;
    return count[pid];
}

/// Number of dropped events for process `pid`.
pub fn dropped(pid: usize) u64 {
    if (!in_range(pid)) return 0;
    return dropped_counts[pid];
}

pub const EventQueueInfo = struct {
    pending: usize,
    pushed: u64,
    popped: u64,
    dropped: u64,
};

pub fn info(pid: usize) EventQueueInfo {
    return .{
        .pending = pending(pid),
        .pushed = if (in_range(pid)) pushed_counts[pid] else 0,
        .popped = if (in_range(pid)) popped_counts[pid] else 0,
        .dropped = if (in_range(pid)) dropped_counts[pid] else 0,
    };
}

// ---------------------------------------------------------------------------
// Tests (Class A unit tests)
// ---------------------------------------------------------------------------

test "events: wire format layout and size is exactly 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Event));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(Event));

    const ev = Event{
        .kind = KEY_DOWN,
        .flags = MOD_SHIFT | MOD_CTRL,
        .seq = 42,
        .arg0 = 0x04,
        .arg1 = 'a',
    };
    try std.testing.expectEqual(KEY_DOWN, ev.kind);
    try std.testing.expectEqual(MOD_SHIFT | MOD_CTRL, ev.flags);
    try std.testing.expectEqual(@as(u32, 42), ev.seq);
    try std.testing.expectEqual(@as(u32, 0x04), ev.arg0);
    try std.testing.expectEqual(@as(u32, 'a'), ev.arg1);
}

test "events: push/peek/pop/drop FIFO sequence and monotonicity" {
    init();
    try std.testing.expectEqual(@as(usize, 0), pending(0));

    push(0, .{ .kind = KEY_DOWN, .flags = 0, .seq = 0, .arg0 = 0x04, .arg1 = 'a' });
    push(0, .{ .kind = KEY_UP, .flags = 0, .seq = 0, .arg0 = 0x04, .arg1 = 'a' });
    try std.testing.expectEqual(@as(usize, 2), pending(0));

    // Peek does not consume
    const p1 = peek(0).?;
    try std.testing.expectEqual(KEY_DOWN, p1.kind);
    try std.testing.expectEqual(@as(u32, 1), p1.seq);
    try std.testing.expectEqual(@as(usize, 2), pending(0));

    // Pop consumes
    const e1 = pop(0).?;
    try std.testing.expectEqual(KEY_DOWN, e1.kind);
    try std.testing.expectEqual(@as(u32, 1), e1.seq);
    try std.testing.expectEqual(@as(usize, 1), pending(0));

    const e2 = pop(0).?;
    try std.testing.expectEqual(KEY_UP, e2.kind);
    try std.testing.expectEqual(@as(u32, 2), e2.seq);
    try std.testing.expectEqual(@as(usize, 0), pending(0));

    try std.testing.expect(pop(0) == null);
}

test "events: drop-oldest overflow discipline and wrap" {
    init();

    // Fill to capacity
    var i: u32 = 0;
    while (i < max_events) : (i += 1) {
        push(0, .{ .kind = MOUSE_MOVE, .flags = 0, .seq = 0, .arg0 = i, .arg1 = i * 2 });
    }
    try std.testing.expectEqual(@as(usize, max_events), pending(0));
    try std.testing.expectEqual(@as(u64, 0), dropped(0));

    // 17th event causes drop-oldest
    push(0, .{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 0, .arg0 = 100, .arg1 = 200 });
    try std.testing.expectEqual(@as(usize, max_events), pending(0));
    try std.testing.expectEqual(@as(u64, 1), dropped(0));

    // Oldest event should now be seq=2 (seq=1 was dropped)
    const oldest = peek(0).?;
    try std.testing.expectEqual(@as(u32, 2), oldest.seq);
    try std.testing.expectEqual(@as(u32, 1), oldest.arg0);

    // Drain all events
    var drained: usize = 0;
    while (pop(0)) |_| {
        drained += 1;
    }
    try std.testing.expectEqual(@as(usize, max_events), drained);
    try std.testing.expectEqual(@as(usize, 0), pending(0));
}

test "events: process isolation and lifecycle reset" {
    init();

    push(0, .{ .kind = WIN_FOCUS, .flags = 0, .seq = 0, .arg0 = 2, .arg1 = 0 });
    push(1, .{ .kind = WIN_FOCUS, .flags = 0, .seq = 0, .arg0 = 3, .arg1 = 0 });

    try std.testing.expectEqual(@as(usize, 1), pending(0));
    try std.testing.expectEqual(@as(usize, 1), pending(1));

    reset(0);
    try std.testing.expectEqual(@as(usize, 0), pending(0));
    try std.testing.expectEqual(@as(usize, 1), pending(1));

    const e1 = pop(1).?;
    try std.testing.expectEqual(WIN_FOCUS, e1.kind);
    try std.testing.expectEqual(@as(u32, 3), e1.arg0);

    // Next push to pid 0 starts at seq 1 again
    push(0, .{ .kind = KEY_DOWN, .flags = 0, .seq = 0, .arg0 = 0x05, .arg1 = 'b' });
    const e0 = pop(0).?;
    try std.testing.expectEqual(@as(u32, 1), e0.seq);
}

test "events: out-of-range PIDs and invalid kinds are defensive no-ops" {
    init();
    push(process.max_processes, .{ .kind = KEY_DOWN, .flags = 0, .seq = 0, .arg0 = 1, .arg1 = 1 });
    try std.testing.expect(pop(process.max_processes) == null);
    try std.testing.expect(peek(process.max_processes) == null);
    drop(process.max_processes);
    reset(process.max_processes);
    try std.testing.expectEqual(@as(usize, 0), pending(process.max_processes));

    // Kind 0 is invalid / no-op
    push(0, .{ .kind = 0, .flags = 0, .seq = 0, .arg0 = 0, .arg1 = 0 });
    try std.testing.expectEqual(@as(usize, 0), pending(0));
}
