//! census (M188e, #3190): TIMER.BIN — gate-referenced: live-timers, live-bench (tools/gate/bench/corpus.tsv).
//! VirelaiOS twenty-third ESP user program — TIMER.BIN (Milestone 14, Card
//! S2, claim 7323).
//!
//! Headless class-B proof for the per-process application timer seam (ADR
//! 0007 slots 40–41): arm a timer, BLOCK in `sys_wait_event` (no spin
//! loop — the whole point of the card), observe the `TIMER` event the
//! kernel posts when the countdown reaches zero, then prove the cancel
//! half (nothing pending → 0, a live pending timer → 1). Each step prints
//! a marker for `tools/verify-live-timers.sh`.
//!
//! card #3036 (ADR 0007 X2): the tick legs stay byte-identical. A fifth
//! leg arms the same ONE timer for 100 ms through slot 95 and reports the
//! fire's lateness measured on the EL0 counter (`abi.nanos` — the deadline
//! overlay's own clock): `timertest: armed-ns 100` then
//! `timertest: fired-ns seq=<n> late_us=<m>`. An argv[0] of "jitter" runs
//! only the bench leg — N (default 20) 10 ms arms, each blocked on —
//! printing `timertest: jitter n=<N> max_late_us=<m>` for M170f's sweep.

const ui = @import("lib/ui.zig");
const abi = @import("lib/ui/abi.zig");

/// card #3036: TIMER.BIN links segmented (DSK3) so exec can pack argv for
/// the jitter mode. The writable tail only exists when the image has a
/// real .data word — `export` keeps this one resident.
export var argv_segment_pad: u64 = 1;

fn append_str(buf: []u8, pos: usize, src: []const u8) usize {
    @memcpy(buf[pos .. pos + src.len], src);
    return pos + src.len;
}

fn fmt_u64(buf: []u8, value: u64) []const u8 {
    var v = value;
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
        return buf[i..];
    }
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
    }
    return buf[i..];
}

fn print_seq(prefix: []const u8, seq: u32) void {
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    pos = append_str(&buf, pos, prefix);
    pos = append_str(&buf, pos, " seq=");
    pos = append_str(&buf, pos, fmt_u64(buf[pos..], seq));
    buf[pos] = '\n';
    ui.write_console(buf[0 .. pos + 1]);
}

/// Wait for the NEXT event and report it. Returns true when it is a TIMER
/// event (any other kind is reported honestly and skipped — the event queue
/// starts clean at exec, so this should never happen).
fn wait_for_timer(tag: []const u8) bool {
    var ev: ui.Event = undefined;
    const n = ui.wait_event(&ev);
    if (n <= 0) {
        ui.write_console("timertest: wait failed\n");
        return false;
    }
    if (ev.kind != ui.EVENT_TIMER) {
        ui.write_console("timertest: wrong kind\n");
        return false;
    }
    print_seq(tag, ev.seq);
    return true;
}

/// card #3036: block on one TIMER event armed `ns` in the past tense at
/// `armed_at` (abi.nanos), returning the fire's lateness in microseconds.
/// ~0xffff on failure — the caller exits before reading it.
fn wait_ns_fire(ns: u64, armed_at: u64) u64 {
    var ev: ui.Event = undefined;
    const n = ui.wait_event(&ev);
    const at = abi.nanos();
    if (n <= 0 or ev.kind != ui.EVENT_TIMER) return ~@as(u64, 0);
    // arg0 is the kernel's IRQ-side lateness in microseconds (card #3036);
    // a tick-backstop fire stamps 0 — fall back to the EL0 clock then.
    if (ev.arg0 != 0) return ev.arg0;
    const due = armed_at + ns;
    return (at -| due) / 1_000;
}

/// card #3036: `timertest jitter [n]` — N 10 ms arms, each blocked on;
/// one summary line: `timertest: jitter n=<done> max_late_us=<m>`.
fn jitter_mode(argc: usize, argv: ?[*]const [256]u8) noreturn {
    var n: u64 = 20;
    if (argc >= 2) {
        if (argv) |slots| {
            var v: u64 = 0;
            var i: usize = 0;
            while (i < 255 and slots[1][i] >= '0' and slots[1][i] <= '9') : (i += 1)
                v = v * 10 + (slots[1][i] - '0');
            if (i > 0) n = v;
        }
    }
    var max_late: u64 = 0;
    var done: u64 = 0;
    while (done < n) : (done += 1) {
        const armed_at = abi.nanos();
        if (abi.timer_set_ns(10_000_000) < 0) break;
        const late = wait_ns_fire(10_000_000, armed_at);
        if (late == ~@as(u64, 0)) break;
        if (late > max_late) max_late = late;
    }
    var buf: [80]u8 = undefined;
    var pos: usize = 0;
    pos = append_str(&buf, pos, "timertest: jitter n=");
    pos = append_str(&buf, pos, fmt_u64(buf[pos..], done));
    pos = append_str(&buf, pos, " max_late_us=");
    pos = append_str(&buf, pos, fmt_u64(buf[pos..], max_late));
    buf[pos] = '\n';
    ui.write_console(buf[0 .. pos + 1]);
    ui.exit_process(0);
}

fn arg_is(slot: *const [256]u8, want: []const u8) bool {
    var i: usize = 0;
    while (i < want.len) : (i += 1) {
        if (slot[i] != want[i]) return false;
    }
    return slot[i] == 0;
}

export fn _start(argc: usize, argv: ?[*]const [256]u8) callconv(.c) noreturn {
    argv_segment_pad = argc; // keep the writable segment live
    if (argc >= 1) {
        if (argv) |slots| {
            if (arg_is(&slots[0], "jitter")) jitter_mode(argc, argv);
        }
    }

    // 1. Arm a 2-tick timer; block in wait_event until the TIMER event.
    if (ui.timer_set(2) < 0) {
        ui.write_console("timertest: set1 failed\n");
        ui.exit_process(1);
    }
    ui.write_console("timertest: armed 2\n");
    if (!wait_for_timer("timertest: fired")) {
        ui.exit_process(2);
    }

    // 2. Cancel with nothing pending -> 0 (and the module reports no arms).
    const c0 = ui.timer_cancel();
    if (c0 != 0) {
        ui.write_console("timertest: cancel-none failed\n");
        ui.exit_process(3);
    }
    ui.write_console("timertest: cancel-none\n");

    // 3. Arm a 1-tick timer; the second TIMER event arrives one tick later.
    if (ui.timer_set(1) < 0) {
        ui.write_console("timertest: set2 failed\n");
        ui.exit_process(4);
    }
    ui.write_console("timertest: armed 1\n");
    if (!wait_for_timer("timertest: fired2")) {
        ui.exit_process(5);
    }

    // 4. Arm a 5-tick timer, then cancel it while pending -> 1, and prove
    //    nothing ever fires (the program exits before the countdown ends).
    if (ui.timer_set(5) < 0) {
        ui.write_console("timertest: set3 failed\n");
        ui.exit_process(6);
    }
    const c1 = ui.timer_cancel();
    if (c1 != 1) {
        ui.write_console("timertest: cancel-pending failed\n");
        ui.exit_process(7);
    }
    ui.write_console("timertest: canceled\n");

    // 5. card #3036 (X2): the same ONE timer armed for 100 ms on the
    //    deadline overlay — the TIMER event arrives at the deadline IRQ,
    //    not the 1 Hz heartbeat. `late_us` is measured on abi.nanos, the
    //    overlay's own clock.
    const armed_at = abi.nanos();
    if (abi.timer_set_ns(100_000_000) < 0) {
        ui.write_console("timertest: set-ns failed\n");
        ui.exit_process(8);
    }
    ui.write_console("timertest: armed-ns 100\n");
    {
        var ev: ui.Event = undefined;
        const n = ui.wait_event(&ev);
        const at = abi.nanos();
        if (n <= 0 or ev.kind != ui.EVENT_TIMER) {
            ui.write_console("timertest: wait-ns failed\n");
            ui.exit_process(9);
        }
        // late_us is the IRQ-side stamp (event arg0); the tick backstop
        // stamps 0 and the EL0 clock measures resume latency instead.
        const late_us = if (ev.arg0 != 0) ev.arg0 else (at -| (armed_at + 100_000_000)) / 1_000;
        var buf: [80]u8 = undefined;
        var pos: usize = 0;
        pos = append_str(&buf, pos, "timertest: fired-ns seq=");
        pos = append_str(&buf, pos, fmt_u64(buf[pos..], ev.seq));
        pos = append_str(&buf, pos, " late_us=");
        pos = append_str(&buf, pos, fmt_u64(buf[pos..], late_us));
        buf[pos] = '\n';
        ui.write_console(buf[0 .. pos + 1]);
    }

    ui.write_console("timertest: done\n");
    ui.exit_process(23);
}
