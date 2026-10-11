//! Last-words recorder (claim #1278 — the unblock for #1261).
//!
//! ## Why this is a trace and not a crash handler
//!
//! A boot can end with the VM in `VZVirtualMachine.State.error` and literally
//! nothing else: no `[EXC]` block (so no synchronous exception was taken), no
//! tombstone, and the last serial line an ordinary one (`wnd: present`). #1261
//! spent a full investigation on that, and the reason it could not get further
//! is structural:
//!
//!   * **Guest RAM is not readable post-mortem.** VZ exposes no memory dump, so
//!     a ring of records in BSS dies with the guest. The existing
//!     `serial_ring.zig` is RAM-only and has the same problem.
//!   * **A crash handler needs the guest to run one.** If the death takes no
//!     exception, no handler is entered. There is nothing to hook.
//!
//! Therefore a record only survives if it **reaches serial before the death**.
//! The design follows from that single constraint:
//!
//!   * `note()` is cheap and callable from ANY context, including IRQ: a
//!     per-core counter and one fixed-size BSS slot. No allocation, no lock, no
//!     console, no comparator write.
//!   * `note()` never prints. Emission is deferred to the console write path,
//!     so **the next ordinary line the guest prints carries the pending records
//!     with it**. The kernel's "no console in IRQ context" rule is preserved
//!     exactly: printing still only ever happens on the path that was already
//!     printing, and the recorder just contributes a prefix to it.
//!
//! The consequence for a dying boot: whatever line ends up last in the serial
//! log is immediately preceded by the records of everything the guest did just
//! before it, so the tail names the last instant instead of stopping at an
//! ordinary line.
//!
//! ## Race-freedom without atomics
//!
//! The kernel uses spinlocks and no `@atomicRmw` anywhere, and this path must
//! not take a lock (it runs in IRQ context, where a lock held by the
//! interrupted context on the same core would self-deadlock). So the ring is
//! partitioned instead: each core owns `per_core` private slots and writes only
//! its own, which needs no synchronization at all. A reader can catch a slot
//! mid-write and see a torn record; that is accepted, because a torn record
//! still names a site and a core, which is the whole question being asked.
//!
//! Off by default (`enabled == false`), so a default boot reaches none of this:
//! `note()` returns on its first byte and no hook is installed.

const std = @import("std");
const builtin = @import("builtin");
const smp = @import("smp.zig");
const timer = @import("timer.zig");
const console = @import("console.zig");

/// Where a record came from. Kept small and stable: these strings are grepped
/// out of a serial log by eye at the worst possible moment, so renaming one is
/// a breaking change to somebody's evidence.
pub const Site = enum(u8) {
    irq = 0,
    rotate = 1,
    wake = 2,
    console_line = 3,
    shot = 4,
    /// #1261: exception ENTRY, recorded before `gic.ack()`. The `irq` probe
    /// sits after the ack and the spurious check, so "no irq records" in a
    /// silent tail is ambiguous between "no interrupt was delivered" and "no
    /// interrupt was acked-and-true". `entry` removes the ambiguity: it fires
    /// the instant C code takes control, before any GIC state is consumed.
    /// `arg` carries the exception KIND (the vector class, not an INTID).
    entry = 5,
    /// #1261: the comparator was (re-)programmed. A gap in `rearm` records
    /// means the timer hardware was never given a new deadline — the PPIs
    /// stopped at the SOURCE — while a steady `rearm` cadence with no `entry`
    /// records means the comparator fires but the core never takes the
    /// exception. `arg` is the programmed comparator delta in counter ticks.
    rearm = 6,
    /// #1261: `gic.ack()` returned a spurious INTID. "Signaled but not a real
    /// interrupt" — the record that makes a spurious storm visible instead of
    /// silently collapsing into the same tail as no interrupts at all.
    spur = 7,

    pub fn name(self: Site) []const u8 {
        return switch (self) {
            .irq => "irq",
            .rotate => "rotate",
            .wake => "wake",
            .console_line => "line",
            .shot => "shot",
            .entry => "entry",
            .rearm => "rearm",
            .spur => "spur",
        };
    }
};

/// Records kept per core. Fixed and small: this is a tail, not a log.
pub const per_core: usize = 64;
pub const capacity: usize = smp.max_cores * per_core;

const Record = struct {
    seq: u64 = 0,
    cntpct: u64 = 0,
    arg: u64 = 0,
    site: Site = .irq,
    core: u8 = 0,
    /// Set once the record has been emitted, so a drain is incremental and the
    /// same record is not printed twice.
    drained: bool = false,
    /// Set by `note` on the slot it just wrote. This is the ONLY thing that
    /// distinguishes a recorded event from a never-written slot: inferring it
    /// from the fields being non-zero would silently swallow a legitimate
    /// event whose `seq` and `arg` are both 0 (the first event on a core that
    /// carries no argument), which is exactly the head of a trace.
    live: bool = false,
};

var records: [capacity]Record = @as([capacity]Record, @splat(@as(Record, .{})));
/// Per-core next sequence number. Only that core writes its own entry, which is
/// what makes the ring lock-free (see the header).
var next: [smp.max_cores]u64 = @as([smp.max_cores]u64, @splat(@as(u64, 0)));
/// Records emitted so far, and how many were dropped as unprintable.
pub var emitted: u64 = 0;
pub var truncated: u64 = 0;
/// Off until a `forensics on` asks for it, so default boots are byte-identical.
pub var enabled: bool = false;
/// Reentrancy guard: `drain` prints, printing calls the console write path,
/// which calls `drain`. Without this the second entry would recurse until the
/// stack gave out.
var draining: bool = false;
/// Cap on records emitted by one drain, so a burst cannot stall a console write
/// behind an unbounded flush.
pub const max_per_drain: usize = 24;

/// Record an event. Safe from any context: IRQ, SVC, lock-held, or a host test.
///
/// Deliberately does no I/O and takes no lock — see the module header for why
/// that is not an optimisation but the requirement.
pub fn note(site: Site, arg: u64) void {
    if (!enabled) return;
    const c = if (comptime builtin.is_test) 0 else smp.core_id();
    if (c >= smp.max_cores) return;
    const n = next[c];
    next[c] = n +% 1;
    const idx = c * per_core + @as(usize, @intCast(n % per_core));
    records[idx] = .{
        .seq = n,
        .cntpct = if (comptime builtin.is_test) 0 else timer.cntpct(),
        .arg = arg,
        .site = site,
        .core = @intCast(c),
        .drained = false,
        .live = true,
    };
}

/// Total order over records: by sequence, then by core so two cores' equal
/// sequence numbers still have a defined order (see `format_pending`).
fn isOlder(a: Record, b: Record) bool {
    if (a.seq != b.seq) return a.seq < b.seq;
    return a.core < b.core;
}

/// How many undrained records any core is holding.
pub fn pending() usize {
    var n: usize = 0;
    for (records) |r| {
        if (r.live and !r.drained) n += 1;
    }
    return n;
}

/// Format every undrained record, oldest sequence first per core, as one line
/// each, into `out`. Pure: no console, so a host test can pin the format.
///
/// Returns the number of bytes written. Non-zero only when there was something
/// to say, which is what keeps the hook free on a normal boot even if it is
/// left installed.
pub fn format_pending(out: []u8) usize {
    var pos: usize = 0;
    var budget = max_per_drain;
    // Oldest-first by (seq, core), so the tail of the output is the newest
    // event under any interleaving of cores. O(cores * per_core) per emitted
    // record, which is 256 comparisons — nothing, and far cheaper than sorting
    // in an IRQ-adjacent path.
    //
    // The comparison is a TUPLE, not the bare sequence: `seq` is per-core, so
    // two cores emit seq=1 independently. Keying on `seq` alone would strand
    // one core's record forever behind the other's equal sequence number.
    var pick: ?struct { seq: u64, core: u8 } = null;
    while (budget > 0) {
        var best: ?usize = null;
        for (records, 0..) |r, i| {
            if (!r.live or r.drained) continue;
            if (pick) |p| {
                if (r.seq < p.seq) continue;
                if (r.seq == p.seq and r.core <= p.core) continue;
            }
            if (best == null or isOlder(r, records[best.?])) best = i;
        }
        const i = best orelse break;
        const r = records[i];
        pick = .{ .seq = r.seq, .core = r.core };
        budget -= 1;
        const line = std.fmt.bufPrint(
            out[pos..],
            "fx: site={s} core={d} seq={d} t={d} arg={d}\n",
            .{ r.site.name(), r.core, r.seq, r.cntpct, r.arg },
        ) catch {
            // The buffer could not hold this line. Count it and leave the
            // record UNDRAINED so the next drain tries again — the newest
            // record is the most valuable one in a dying boot, and consuming
            // it here would be the one way this recorder could lose the thing
            // it exists to keep. The caller's buffer is sized for the widest
            // possible line (see `drain`), so this branch cannot fire in the
            // guest; the counter exists to make it loud if it ever does.
            truncated +%= 1;
            break;
        };
        records[i].drained = true;
        emitted +%= 1;
        pos += line.len;
    }
    return pos;
}

/// Emit pending records through `con`, immediately before the caller's own
/// bytes. Installed as the console's drain hook by `main.zig`, which is what
/// keeps `console.zig` free of a dependency on this file.
pub fn drain(con: console.Console) void {
    if (!enabled or draining) return;
    draining = true;
    defer draining = false;
    var buf: [max_per_drain * 64]u8 = undefined;
    const n = format_pending(buf[0..]);
    if (n > 0) con.write(buf[0..n]);
}

/// #1261: a console-FREE liveness sample. The recorder's emission is coupled
/// to console writes, so "the trace stopped" is always confounded with "the
/// console stopped" — on the nudge tree the last 47k serial lines print with
/// no `irq` record, and that alone cannot separate delivery from recording.
///
/// This probe produces a record no console line needs to exist for: it notes
/// the sample, then *drains it inline* through its own `con.write`. It runs
/// from the shell idle loop (main context, the same rules as
/// `maybe_heartbeat`), once per `sample_period_secs` of wall-clock time, so a
/// guest that is still executing keeps appending `fxs:` lines to the serial
/// log no matter what the console traffic looks like.
pub const sample_period_secs: u64 = 4;
var last_sample_secs: ?u64 = null;

/// The clock is the free-running hardware counter (`timer.cntpct()`) divided
/// by the programmed frequency (`timer.freq`) — monotonic by definition and
/// exact in wall-clock seconds. Two clock choices were measured and rejected:
///
/// - `scheduler.tick_count` advances per scheduling quantum, not per second
///   (6,212 records in one gate boot — a trace flood, not a heartbeat).
/// - `timer.irq_ticks` is a SHARED counter, incremented by BOTH cores' 1 Hz
///   PPIs and reset by timer re-init paths: it went 1 -> 0 during early boot
///   and advanced ~2/s, so the `== 0` bypass plus the shared increments
///   produced 5,575 samples in a 119 s boot (~47/s, bursts 50 µs apart).
///
/// `freq == 0` (counter not yet programmed) suppresses the sample rather than
/// guessing a rate. `arg` of the `shot` record is the whole wall-clock second.
pub fn sample(con: console.Console, counter: u64, freq: u64) void {
    if (!enabled or draining) return;
    if (freq == 0) return;
    const secs = counter / freq;
    if (last_sample_secs) |ls| {
        // Saturation, not subtraction: the counter itself is NOT monotonic
        // for the first ~0.9 s of a boot under VZ on this host (observed
        // twice: a ~0.1 s backward step at t≈0.89 s, shell read ≥24M ticks
        // while the recorder's read 54 µs later was 21.5M). A bare `secs -
        // ls` would underflow there — Debug panics, ReleaseFast silently
        // wraps. On a backward step, restart the cadence from the new base.
        const elapsed = if (secs > ls) secs - ls else 0;
        if (elapsed < sample_period_secs) return;
    }
    last_sample_secs = secs;
    note(.shot, secs);
    // Inline drain of JUST what is pending, reentrancy-guarded as `drain` is.
    draining = true;
    defer draining = false;
    var buf: [max_per_drain * 64]u8 = undefined;
    const n = format_pending(buf[0..]);
    if (n > 0) con.write(buf[0..n]);
}

/// Reset for a fresh capture (the `forensics reset` command).
pub fn reset() void {
    records = @as([capacity]Record, @splat(@as(Record, .{})));
    next = @as([smp.max_cores]u64, @splat(@as(u64, 0)));
    emitted = 0;
    truncated = 0;
    last_sample_secs = null;
}

// ---------------------------------------------------------------------------
// Host tests: the ring discipline, without a console and without a guest.
// ---------------------------------------------------------------------------

test "forensics: disabled records nothing" {
    reset();
    enabled = false;
    note(.rotate, 7);
    try std.testing.expectEqual(@as(usize, 0), pending());
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), format_pending(buf[0..]));
}

test "forensics: a note is emitted once, in sequence order, and is not repeated" {
    reset();
    enabled = true;
    note(.irq, 30);
    note(.rotate, 3);
    note(.wake, 9);
    var buf: [1024]u8 = undefined;
    const n = format_pending(buf[0..]);
    try std.testing.expect(n > 0);
    const text = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, text, "site=irq core=0 seq=0 t=0 arg=30") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "site=rotate core=0 seq=1 t=0 arg=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "site=wake core=0 seq=2 t=0 arg=9") != null);
    // Sequence order, so the LAST line is the newest event — that is the
    // property a dying boot is read for.
    const irq_at = std.mem.indexOf(u8, text, "site=irq").?;
    const rot_at = std.mem.indexOf(u8, text, "site=rotate").?;
    const wake_at = std.mem.indexOf(u8, text, "site=wake").?;
    try std.testing.expect(irq_at < rot_at and rot_at < wake_at);
    // A second drain has nothing to add: records are not repeated.
    try std.testing.expectEqual(@as(usize, 0), format_pending(buf[0..]));
    enabled = false;
}

test "forensics: the ring wraps and keeps the newest per_core records" {
    reset();
    enabled = true;
    var i: usize = 0;
    // One more than fits, so slot 0 is overwritten by the newest event.
    while (i < per_core + 1) : (i += 1) note(.shot, i);
    const newest = per_core; // arg of the last note
    var buf: [8192]u8 = undefined;
    const n = format_pending(buf[0..]);
    const text = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, text, "arg=0\n") == null); // overwritten
    const want = std.fmt.bufPrint(buf[0..16], "arg={d}\n", .{newest}) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, text, want) != null);
    enabled = false;
}

test "forensics: an armed ring with nothing recorded emits nothing" {
    // A never-written slot must not be mistaken for an event — otherwise every
    // boot would open with a phantom record at the head of its trace.
    reset();
    enabled = true;
    var buf: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), format_pending(buf[0..]));
    enabled = false;
}

test "forensics: an event at seq=0 whose arg is 0 is still an event" {
    // The other half of the same question, and the half a field heuristic gets
    // WRONG: the first event on a core can legitimately carry seq=0 and arg=0,
    // and it is the first thing a trace should show. It is distinguishable from
    // an empty slot only because `note` marks the slot it wrote.
    reset();
    enabled = true;
    note(.shot, 0);
    try std.testing.expectEqual(@as(usize, 1), pending());
    var buf: [256]u8 = undefined;
    const n = format_pending(buf[0..]);
    const text = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, text, "fx: site=shot core=0 seq=0 t=0 arg=0") != null);
    enabled = false;
}

test "forensics: one drain emits at most max_per_drain records and the rest wait" {
    // The bound that keeps a backlog from stalling the console write it is
    // riding on. The records must not be lost, only deferred.
    reset();
    enabled = true;
    var i: usize = 0;
    while (i < max_per_drain + 5) : (i += 1) note(.irq, i);
    var buf: [8192]u8 = undefined;

    const first = format_pending(buf[0..]);
    try std.testing.expectEqual(max_per_drain, std.mem.count(u8, buf[0..first], "fx: "));
    try std.testing.expectEqual(@as(usize, 5), pending());

    const second = format_pending(buf[0..]);
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, buf[0..second], "fx: "));
    try std.testing.expectEqual(@as(usize, 0), pending());
    enabled = false;
}

test "forensics: a buffer too small to hold a line counts a truncation instead of writing half of one" {
    reset();
    enabled = true;
    note(.rotate, 5);
    const before = truncated;
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), format_pending(tiny[0..]));
    try std.testing.expectEqual(before + 1, truncated);
    // The record is NOT consumed by a failed format: the next drain still has it.
    try std.testing.expectEqual(@as(usize, 1), pending());
    enabled = false;
}

test "forensics: reset drops what was recorded and emits nothing stale" {
    reset();
    enabled = true;
    note(.irq, 11);
    var buf: [256]u8 = undefined;
    try std.testing.expect(format_pending(buf[0..]) > 0);
    note(.irq, 12);
    reset();
    try std.testing.expectEqual(@as(usize, 0), pending());
    try std.testing.expectEqual(@as(usize, 0), emitted);
    try std.testing.expectEqual(@as(usize, 0), truncated);
    // And the ring accepts a new event at seq 0 afterwards, since the per-core
    // counters were reset with it (a boot that restarts a capture must not
    // resume mid-sequence).
    note(.irq, 13);
    const n = format_pending(buf[0..]);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "seq=0 t=0 arg=13") != null);
    enabled = false;
}

test "forensics: the idle sample fires once per period of wall-clock seconds, not per tick" {
    reset();
    enabled = true;
    var mock = console.MockConsole(4096){};
    const con = mock.console();
    const freq: u64 = 24_000_000;
    // The first call at freq=0 (counter not yet programmed) must be suppressed:
    // an unprogrammed clock must not guess a rate.
    sample(con, 1_000_000, 0);
    try std.testing.expectEqual(@as(usize, 0), mock.contents().len);
    try std.testing.expectEqual(@as(usize, 0), pending());
    // First live sample at t=1s fires immediately (no last_sample_secs yet).
    sample(con, freq, freq);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, mock.contents(), "fx: "));
    // Within the period: every call, even thousands of them, adds nothing —
    // the flood regression (5,575 samples in a 119 s boot) is pinned here.
    var t: u64 = freq;
    while (t < (sample_period_secs - 1) * freq) : (t += 1_000) {
        sample(con, t, freq);
    }
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, mock.contents(), "fx: "));
    // Crossing the period boundary fires exactly once more (5 - 1 = 4 >= 4),
    // with arg = the whole wall-clock second.
    sample(con, (sample_period_secs + 1) * freq, freq);
    const text = mock.contents();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "fx: "));
    try std.testing.expect(std.mem.indexOf(u8, text, "site=shot core=0 seq=1 t=0 arg=5") != null);
    enabled = false;
}
