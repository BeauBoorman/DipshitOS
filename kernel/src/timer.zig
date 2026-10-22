//! VirelaiOS ARM generic timer (claims 7948/9187 — roadmap item 5's
//! remaining half; delivers into claim 9746's EL1 IRQ vector via the GIC).
//!
//! The EL1 *physical* timer (CNTP_*): the comparator CNTP_CVAL_EL0 is
//! armed to CNTPCT_EL0 + one second of ticks (CNTFRQ_EL0 gives the
//! frequency). When the count passes the comparator the timer raises its
//! PPI (group 1, conventionally 30 — the GTDT's Non-Secure EL1 timer GSIV
//! at offset 56 is authoritative), the GIC delivers it as an IRQ, the
//! claim-9746 vector runs, and the kernel's irq_dispatch calls
//! `handle()`: increment the tick counter, re-arm for the next period,
//! and every 5 ticks mark a heartbeat pending.
//!
//! Output is NOT written from IRQ context (printing would re-enter the
//! polled virtio TX path mid-flush, and IRQ-context console writes are not
//! reentrancy-safe). Instead the shell idle loop calls `maybe_heartbeat`
//! in main context. Claim 9187 removed the old production `poll()` call
//! after observing it race working IRQ delivery. Separate IRQ/poll counters
//! make the delivery source observable and prevent a diagnostic poll from
//! being mistaken for an interrupt.
//!
//! Discovery (the GTDT's GSIV) runs PRE-EXIT (ACPI reads hang post-exit on
//! VZ, claim 0013); the GSIV lands in a global. Programming (init/arm)
//! runs POST-MMU, aarch64 only.
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");
const builtin = @import("builtin");
const mmio = @import("mmio.zig");
const console = @import("console.zig");
const forensics = @import("forensics.zig"); // #1261: comparator re-arm probe (inert unless `forensics on`)
const gic = @import("gic.zig");

/// Conventional EL1 physical-timer PPI when the GTDT is absent or silent.
pub const ppi_default: u32 = 30;
/// Heartbeat cadence: every N ticks.
pub const heartbeat_every: u64 = 5;
/// One tick period: 1 second.
pub const period_ns: u64 = 1_000_000_000;

// ---------------------------------------------------------------------------
// State (module globals; read by the monitor `timer` command)
// ---------------------------------------------------------------------------

/// Timer counter frequency (CNTFRQ_EL0), 0 until programmed.
pub var freq: u64 = 0;
/// The EL1 physical-timer PPI/GSIV (GTDT, pre-exit).
pub var ppi: u32 = ppi_default;
/// GTDT trigger mode for the Non-Secure EL1 timer: false=level, true=edge.
pub var interrupt_edge: bool = false;
/// Ticks delivered since the timer was armed.
pub var ticks: u64 = 0;
/// Ticks that entered through the EL1 IRQ vector.
pub var irq_ticks: u64 = 0;
/// Ticks consumed by an explicit diagnostic comparator poll.
pub var poll_ticks: u64 = 0;
var period_ticks: u64 = 0;
var armed_flag: bool = false;
var pending_heartbeat: bool = false;
var pending_irq_report: bool = false;
/// Comparator fires that were NOT the heartbeat boundary (M170a #3033,
/// ADR 0060 D1): each wakes the due sleepers and advances only this
/// counter — never `ticks`/`irq_ticks`, which the heartbeat text and 14
/// spec files pin byte-exact.
pub var deadline_irqs: u64 = 0;
// Snapshots taken when the flags are set (claim 5275): with the scheduler
// preempting the shell between ticks, the shell prints these lines from a
// later idle loop, so the live counters at print time would overstate the
// event. The snapshot describes the event itself (tick 5, irq 5), which is
// also what the live gates assert.
var heartbeat_ticks: u64 = 0;
var heartbeat_irq: u64 = 0;
var heartbeat_poll: u64 = 0;
var irq_report_irq: u64 = 0;

// ---------------------------------------------------------------------------
// Wall clock (#1058)
// ---------------------------------------------------------------------------
/// Boot-time Unix wall-clock seconds, captured from the handoff (EFI
/// RuntimeServices.GetTime in the loader), or `std.math.maxInt(u64)` when
/// the firmware gave no epoch.
pub var boot_epoch_secs: u64 = std.math.maxInt(u64);

/// Record the handoff's boot epoch once at kernel entry.
pub fn set_boot_epoch_secs(v: u64) void {
    boot_epoch_secs = v;
}

/// Current Unix wall-clock seconds: the boot epoch advanced by the elapsed
/// 1 Hz ticks. Null when no firmware epoch was captured (the honest uptime
/// fallback). Reads two module globals; no hardware, so it is host-testable
/// via `on_tick`.
pub fn wall_epoch() ?u64 {
    if (boot_epoch_secs == std.math.maxInt(u64)) return null;
    return boot_epoch_secs + ticks;
}

/// The range `set_wall_epoch` accepts, in Unix seconds: 2025-01-01T00:00:00Z
/// through 2100-01-01T00:00:00Z. Slot 78 is callable by every EL0 process, so
/// the kernel refuses the values a bug or a hostile reply would produce (0,
/// a wrapped NTP era, all-ones) instead of trusting the caller's arithmetic.
pub const wall_epoch_min: u64 = 1_735_689_600;
pub const wall_epoch_max: u64 = 4_102_444_800;

/// Re-anchor the wall clock so `wall_epoch()` reads `epoch` now (M83b
/// #1775). The clock is `boot_epoch_secs + ticks`, so the anchor moves and
/// the tick count does not: uptime and every tick-based deadline are
/// untouched. Works from the no-firmware-epoch state too, which is the point
/// for a boot with no RTC. False (nothing changed) when `epoch` is outside
/// `[wall_epoch_min, wall_epoch_max]`.
///
/// The result is only as fine as the 1 Hz tick: a tick landing between the
/// read and the store is caught by re-reading, but the clock never claims
/// sub-second accuracy.
pub fn set_wall_epoch(epoch: u64) bool {
    if (epoch < wall_epoch_min or epoch > wall_epoch_max) return false;
    var seen = @atomicLoad(u64, &ticks, .monotonic);
    while (true) {
        boot_epoch_secs = epoch - seen;
        const now = @atomicLoad(u64, &ticks, .monotonic);
        if (now == seen) return true;
        seen = now;
    }
}

/// Current LOCAL seconds since midnight: `wall_epoch() % 86400`. Null when
/// there is no firmware epoch.
pub fn local_time_of_day() ?u64 {
    const e = wall_epoch() orelse return null;
    return e % 86_400;
}

/// True once `init` armed the timer on real hardware.
pub fn armed() bool {
    return armed_flag;
}

// ---------------------------------------------------------------------------
// Discovery (PRE-EXIT; called from the pci.zig ACPI walk on the GTDT)
// ---------------------------------------------------------------------------

/// Read the Non-Secure EL1 timer GSIV and flags from the GTDT at offsets
/// 56 and 60. ACPI GTDT flags bit 0 is the trigger mode (0=level, 1=edge).
/// A zero GSIV (or absent table) leaves the conventional PPI 30 in place.
pub fn discover(gtdt_addr: u64) void {
    if (gtdt_addr == 0) return;
    const gsiv = mmio.mmio_read32(gtdt_addr + 56);
    if (gsiv != 0 and gsiv < 1024) ppi = gsiv;
    interrupt_edge = (mmio.mmio_read32(gtdt_addr + 60) & 1) != 0;
}

// ---------------------------------------------------------------------------
// Programming (POST-MMU, aarch64 only)
// ---------------------------------------------------------------------------

fn cntfrq() u64 {
    var v: u64 = 0;
    asm volatile ("mrs %[v], cntfrq_el0"
        : [v] "=r" (v),
    );
    return v;
}

/// Read the physical counter register (CNTPCT_EL0) on AArch64; 0 in host tests or on non-aarch64.
pub fn cntpct() u64 {
    if (comptime builtin.cpu.arch != .aarch64 or builtin.is_test) return 0;
    var v: u64 = 0;
    asm volatile ("mrs %[v], cntpct_el0"
        : [v] "=r" (v),
    );
    return v;
}

// ---------------------------------------------------------------------------
// Deadline overlay (M170a #3033, ADR 0060 D1)
// ---------------------------------------------------------------------------
// The comparator is programmed to the EARLIER of the next heartbeat
// boundary and this core's earliest pending scheduler deadline — never
// earlier than the period edge unless a deadline says so, never later.
// A fire that is not the period edge is a deadline IRQ: it wakes the due
// sleepers (the same blocked->ready flip `wake_expired` performs) and
// counts `deadline_irqs` — it must not increment `ticks`/`irq_ticks`,
// and D3 forbids any forced rotation on it.

/// What the last comparator fire on a core serviced. `scheduler.tick`
/// reads it: only a heartbeat fire runs the quantum/accounting body — a
/// deadline-only fire neither counts nor rotates.
pub const FireKind = enum { none, heartbeat, deadline, both };

/// Next heartbeat boundary per core, in CNTPCT ticks (0 = not yet armed
/// on that core). Secondaries track it for their own comparator cadence;
/// only core 0's boundary records a tick.
var heartbeat_cval: [4]u64 = @as([4]u64, @splat(@as(u64, 0)));
/// Earliest pending deadline per core, ns since boot (0 = none). The
/// scheduler publishes it under sched_lock via `set_deadline`.
var deadline_ns: [4]u64 = @as([4]u64, @splat(@as(u64, 0)));
/// A deadline fire whose wake could not take sched_lock gets a bounded
/// retry (~1 ms, CNTPCT ticks) instead of a tight refire storm on the
/// still-due deadline. Cleared by the next `set_deadline` publish.
var retry_cval: [4]u64 = @as([4]u64, @splat(@as(u64, 0)));
var last_fire: [4]FireKind = @as([4]FireKind, @splat(FireKind.none));

/// The scheduler's blocked->ready wake scan for due entries, registered
/// at scheduler init — a hook keeps this module free of a scheduler
/// dependency (the scheduler already sits above timer for `now_ns`).
pub var deadline_wake_hook: ?*const fn (core: u32) void = null;

/// Injected clock for host tests (the wm_server.zig:236 precedent):
/// production reads CNTPCT and converts by CNTFRQ.
pub var now_ns_hook: ?*const fn () u64 = null;

/// Monotonic nanoseconds since boot: CNTPCT scaled by CNTFRQ. 0 until
/// `init` reads the frequency — and in host tests unless `now_ns_hook`
/// is installed.
pub fn now_ns() u64 {
    if (now_ns_hook) |h| return h();
    if (freq == 0) return 0;
    return @intCast(@as(u128, cntpct()) * 1_000_000_000 / freq);
}

/// CNTPCT ticks at or after `ns` (ceil — the comparator never arms
/// earlier than the deadline it was given). Saturating.
fn ns_to_ticks(ns: u64) u64 {
    if (freq == 0) return 0;
    const t = (@as(u128, ns) * freq + 999_999_999) / 1_000_000_000;
    if (t > std.math.maxInt(u64)) return std.math.maxInt(u64);
    return @intCast(t);
}

/// The comparator choice (pure — host-testable): the earlier of the
/// heartbeat boundary and the pending deadline (`deadline_ticks == 0`
/// means none pending). An exact tie arms the boundary; the fire then
/// services both.
pub fn choose_target(heartbeat_boundary: u64, deadline_ticks: u64) u64 {
    if (deadline_ticks != 0 and deadline_ticks < heartbeat_boundary) return deadline_ticks;
    return heartbeat_boundary;
}

/// What the last fire on `c` was classified as (.none before the first
/// fire — `scheduler.tick` treats it as nothing-to-do).
pub fn fire_kind(c: usize) FireKind {
    return last_fire[c];
}

/// Program this core's comparator to `choose_target` of the stored
/// heartbeat boundary and earliest deadline — the same instruction
/// stream `arm` always wrote; the overlay changes WHAT value lands in
/// CNTP_CVAL, not the mechanism (D1). A boundary already in the past is
/// preserved (target = the boundary) so a pending/masked heartbeat fire
/// is never silently skipped.
fn program() void {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    if (period_ticks == 0) return;
    const c = profile_core();
    const now = cntpct();
    if (heartbeat_cval[c] == 0) heartbeat_cval[c] = now + period_ticks;
    var target = heartbeat_cval[c];
    if (deadline_ns[c] != 0) {
        var d = ns_to_ticks(deadline_ns[c]);
        if (retry_cval[c] != 0 and retry_cval[c] > d) d = retry_cval[c];
        if (d < target) target = d;
    }
    // #1261: record that the hardware was given a deadline, and what it
    // was. A steady `rearm` cadence with no `entry` records says the
    // comparator fires but the exception is never taken; a `rearm` gap
    // says the source itself stopped. The delta is what exposes a
    // clobbered `period_ticks`.
    forensics.note(.rearm, target);
    asm volatile ("msr cntp_cval_el0, %[v]"
        :
        : [v] "r" (target),
    );
    asm volatile ("msr cntp_ctl_el0, %[v]"
        :
        : [v] "r" (@as(u64, 1)), // enable, IMASK=0
    );
    asm volatile ("isb");
}

/// Publish this core's new earliest deadline (ns since boot, 0 = none)
/// and reprogram the comparator when the publisher IS that core. Called
/// by the scheduler under sched_lock after every set mutation; a remote
/// core's comparator self-heals on its next fire (a stale armed deadline
/// costs one early fire classified `.none`, never a wrong tick).
pub fn set_deadline(c: usize, earliest_ns: u64) void {
    if (deadline_ns[c] == earliest_ns) return;
    deadline_ns[c] = earliest_ns;
    retry_cval[c] = 0;
    if (profile_core() == c) program();
}

/// The wake hook could not take sched_lock: hold the comparator ~1 ms
/// out instead of refiring on the still-due deadline in a tight IRQ
/// storm against the preempted holder.
pub fn defer_deadline_retry(c: u32) void {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    if (freq == 0) return;
    retry_cval[c] = cntpct() + freq / 1000;
}

/// Service one comparator fire on core `c` observed at `now_ticks`: the
/// heartbeat boundary crossing records the tick (core 0 only) and slides
/// the boundary forward one period; a due deadline counts
/// `deadline_irqs` and runs the wake hook (which publishes the next
/// earliest through `set_deadline`). Both can land on one fire. Returns
/// what fired so the scheduler's `tick` can skip a non-heartbeat.
fn service(c: usize, now_ticks: u64) FireKind {
    var kind: FireKind = .none;
    if (heartbeat_cval[c] != 0 and now_ticks >= heartbeat_cval[c]) {
        if (c == 0) record_tick(.irq);
        heartbeat_cval[c] = now_ticks + period_ticks;
        kind = .heartbeat;
    }
    if (deadline_ns[c] != 0 and now_ticks >= ns_to_ticks(deadline_ns[c])) {
        deadline_irqs +%= 1;
        kind = if (kind == .heartbeat) .both else .deadline;
        if (deadline_wake_hook) |h| h(@intCast(c));
    }
    last_fire[c] = kind;
    program();
    return kind;
}

/// Host-safe test hook (the `on_tick` precedent): run one fire's
/// classification, counters and wake hook with an injected counter
/// value; the comparator write stays aarch64-only inside `program`.
pub fn fire_for_test(c: usize, now_ticks: u64) FireKind {
    return service(c, now_ticks);
}

/// Arm (or re-arm) the comparator — the init path AND, per main.zig's
/// dispatch, the secondary cores' fire service: classify the fire,
/// service what is due, reprogram to the earlier of boundary/deadline.
pub fn arm() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    _ = service(profile_core(), cntpct());
}

/// Grant EL0 access to the counter registers (CNTPCT_EL0, CNTFRQ_EL0,
/// CNTP_CTL_EL0) so EL0 processes can read time without a syscall slot.
/// M24 K13/K14 (calc/dates.zig `now()`) read CNTPCT_EL0/CNTFRQ_EL0
/// directly — the march card claims "EL0-accessible", which is only true
/// once CNTKCTL_EL1.EL0PCTEN is set. Without it, an EL0 `mrs cntpct_el0`
/// traps as a data abort (far=0, ec=0x18) and the fault dispatcher reaps
/// the process (observed live: CALC's `r` key, verify-live-calc-depth).
/// Set EL0PCTEN|EL0VCTEN|EL0PTEN|EL0VTEN (bits 0-3). No-op on non-aarch64
/// hosts (never meaningful in a host test process).
pub fn allow_el0_counter() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    asm volatile ("msr cntkctl_el1, %[v]"
        :
        : [v] "r" (@as(u64, 0b1111)),
    );
    asm volatile ("isb");
}

/// Issue #1163 (GOOS=virelai phase 0a): guarantee EL0 FP/ASIMD access.
/// The gc Go runtime is NEON-heavy (duffzero, GC bitmaps, string ops) and
/// dies at its first FPU instruction if CPACR_EL1.FPEN denies EL0 — the
/// kernel itself never wrote CPACR, so EL0 state was inherited from
/// firmware/VZ (untested territory until now). Arm FPEN=0b11 (full access
/// at EL0 and EL1); idempotent when already full access. Per-PE config,
/// so both init paths arm it (mirrors allow_el0_counter). No-op on
/// non-aarch64 hosts.
pub fn allow_el0_fpu() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    asm volatile ("msr cpacr_el1, %[v]"
        :
        : [v] "r" (@as(u64, 0b11 << 20)),
    );
    asm volatile ("isb");
}

/// Program the timer: read the frequency, compute the 1 s period, arm.
/// Caller is responsible for the GIC being programmed first (the PPI must
/// be enabled for the tick to be delivered) and for unmasking IRQs after.
pub fn init() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    allow_el0_counter();
    allow_el0_fpu();
    freq = cntfrq();
    if (freq == 0) return;
    period_ticks = freq * period_ns / 1_000_000_000;
    arm();
    armed_flag = true;
}

/// Initialize local physical timer for a secondary CPU core.
pub fn init_secondary() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    allow_el0_counter();
    allow_el0_fpu();
    arm();
    profile_sync_local();
}

// The virtual timer is independent of CNTP and scheduler.tick. Only an
// active profiling session enables it. There is deliberately no poll path.
var profile_enabled = std.atomic.Value(bool).init(false);
var profile_deadline: [4]u64 = @as([4]u64, @splat(@as(u64, 0)));
var profile_window_start: [4]u64 = @as([4]u64, @splat(@as(u64, 0)));
var profile_window_irqs: [4]u64 = @as([4]u64, @splat(@as(u64, 0)));
var profile_window_ticks: [4]u64 = @as([4]u64, @splat(@as(u64, 0)));
pub var profile_irqs: [4]u64 = @as([4]u64, @splat(@as(u64, 0)));
pub const profile_polls: [4]u64 = @as([4]u64, @splat(@as(u64, 0)));
const ProfileReport = struct { irqs: u64 = 0, elapsed: u64 = 0, ticks: u64 = 0 };
var profile_reports: [4]ProfileReport = @as([4]ProfileReport, @splat(@as(ProfileReport, .{})));
var profile_pending: [4]std.atomic.Value(bool) = @as([4]std.atomic.Value(bool), @splat(@as(std.atomic.Value(bool), std.atomic.Value(bool).init(false))));

fn profile_core() usize {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return 0;
    const mpidr = asm volatile ("mrs %[v], mpidr_el1"
        : [v] "=r" (-> u64),
    );
    return @intCast(mpidr & 3);
}

pub fn profile_available() bool {
    return freq >= 100 and gic.armed() and gic.kind == .v3;
}

pub fn profile_set_active(enabled: bool) void {
    profile_enabled.store(enabled, .release);
    profile_sync_local();
    gic.send_profile_update();
}

pub fn profile_sync_local() void {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    const c = profile_core();
    asm volatile ("msr cntv_ctl_el0, %[v]"
        :
        : [v] "r" (@as(u64, 0)),
    );
    gic.configure_local_interrupt(gic.profile_ppi, false);
    profile_deadline[c] = 0;
    if (!profile_enabled.load(.acquire) or !profile_available()) return;
    const now = cntpct();
    profile_window_start[c] = now;
    profile_window_irqs[c] = 0;
    profile_window_ticks[c] = ticks;
    profile_deadline[c] = cntvct() + freq / 100;
    gic.configure_local_interrupt(gic.profile_ppi, true);
    profile_arm_local(c);
}

fn profile_arm_local(c: usize) void {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    asm volatile ("msr cntv_cval_el0, %[v]"
        :
        : [v] "r" (profile_deadline[c]),
    );
    asm volatile ("msr cntv_ctl_el0, %[v]"
        :
        : [v] "r" (@as(u64, 1)),
    );
    asm volatile ("isb");
}

fn cntvct() u64 {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return 0;
    return asm volatile ("mrs %[v], cntvct_el0"
        : [v] "=r" (-> u64),
    );
}

/// Skip missed periods, never flood the interrupt path with catch-up work.
pub fn profile_next_deadline(previous: u64, now: u64, period: u64) u64 {
    if (period == 0) return 0;
    if (previous > now) return previous;
    return previous + ((now - previous) / period + 1) * period;
}

pub fn profile_handle() bool {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return false;
    const c = profile_core();
    if (!profile_enabled.load(.acquire) or profile_deadline[c] == 0) {
        profile_sync_local();
        return false;
    }
    const now = cntpct();
    profile_irqs[c] += 1;
    profile_window_irqs[c] += 1;
    profile_deadline[c] = profile_next_deadline(profile_deadline[c], cntvct(), freq / 100);
    profile_arm_local(c);
    if (now - profile_window_start[c] >= freq * 10) {
        // One pending report per core: never rewrite bytes being printed.
        if (!profile_pending[c].load(.acquire)) {
            profile_reports[c] = .{
                .irqs = profile_window_irqs[c],
                .elapsed = now - profile_window_start[c],
                .ticks = ticks - profile_window_ticks[c],
            };
            profile_pending[c].store(true, .release);
        }
        profile_window_start[c] = now;
        profile_window_irqs[c] = 0;
        profile_window_ticks[c] = ticks;
    }
    return true;
}

const TickSource = enum { test_only, irq, poll };

/// Record a fired comparator and where it was consumed. Host tests use
/// `.test_only`; only the real IRQ and polling paths alter their source
/// counters.
fn record_tick(source: TickSource) void {
    ticks += 1;
    switch (source) {
        .test_only => {},
        .irq => {
            irq_ticks += 1;
            if (irq_ticks == 1) {
                pending_irq_report = true;
                irq_report_irq = irq_ticks;
            }
        },
        .poll => poll_ticks += 1,
    }
    if (ticks % heartbeat_every == 0) {
        pending_heartbeat = true;
        heartbeat_ticks = ticks;
        heartbeat_irq = irq_ticks;
        heartbeat_poll = poll_ticks;
    }
}

/// Host-safe test hook: advances the cadence without claiming an IRQ or
/// poll delivery source.
pub fn on_tick() void {
    record_tick(.test_only);
}

/// IRQ-context tick handler (called by the kernel's irq_dispatch when the
/// acknowledged INTID matches `ppi`). Console-free by design. The fire
/// service classifies it: a heartbeat boundary records the tick, a due
/// deadline counts `deadline_irqs` and wakes its sleepers — the overlay's
/// single comparator covers both reasons to fire (D1).
pub fn handle() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    _ = service(profile_core(), cntpct());
}

/// True when `intid` is this timer's PPI.
pub fn is_ppi(intid: u32) bool {
    return intid == ppi;
}

/// Diagnostic-only comparator poll. Production does not call this: polling
/// a level-signalled comparator can race a pending IRQ and double-consume a
/// period. The separate `poll_ticks` counter makes any deliberate use
/// explicit. Never call from IRQ context; host-testable as a no-op on
/// non-aarch64.
pub fn poll() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (!armed_flag) return;
    var cval: u64 = 0;
    asm volatile ("mrs %[v], cntp_cval_el0"
        : [v] "=r" (cval),
    );
    if (cntpct() >= cval) {
        record_tick(.poll);
        // The poll consumed this fire outright — reprogram without a
        // second classification (a due deadline still refires on its
        // published value and is serviced by the IRQ path).
        program();
    }
}

// ---------------------------------------------------------------------------
// Heartbeat (main context only — the shell idle loop)
// ---------------------------------------------------------------------------

/// Monitor `timer probe` result plumbing (M170a #3033): the deadline-IRQ
/// wake records the armed ms and the CNTPCT-derived lateness here; the
/// drain below prints the line in main context (no printing in IRQ).
var probe_pending: bool = false;
var probe_result_ms: u64 = 0;
var probe_result_late_us: u64 = 0;

/// The deadline fire consumed a probe entry: record the result for the
/// main-context drain.
pub fn probe_done(ms: u64, late_us: u64) void {
    probe_result_ms = ms;
    probe_result_late_us = late_us;
    probe_pending = true;
}

/// Print the periodic heartbeat line if one is pending. Safe to call from
/// the main context; never from an IRQ handler.
pub fn maybe_heartbeat(con: *console.Console) void {
    for (&profile_pending, 0..) |*pending, c| {
        if (!pending.load(.acquire)) continue;
        const report = profile_reports[c];
        // One transport slice: a guest's stdout must not tear this row
        // between its field writes. Formatting remains outside IRQ context.
        var line: [192]u8 = undefined;
        const text = std.fmt.bufPrint(
            &line,
            "prof: timer core={d} irq={d} poll=0 elapsed_cntpct={d} freq={d} physical_ticks={d}\n",
            .{ c, report.irqs, report.elapsed, freq, report.ticks },
        ) catch unreachable;
        con.puts(text);
        pending.store(false, .release);
    }
    if (pending_irq_report) {
        pending_irq_report = false;
        con.puts("timer irq delivered ppi=");
        con.print_hex_min(ppi);
        con.puts(" irq_ticks=");
        con.print_u64(irq_report_irq);
        con.puts("\n");
    }
    if (pending_heartbeat) {
        pending_heartbeat = false;
        con.puts("timer heartbeat ticks=");
        con.print_u64(heartbeat_ticks);
        con.puts(" irq=");
        con.print_u64(heartbeat_irq);
        con.puts(" poll=");
        con.print_u64(heartbeat_poll);
        con.puts("\n");
    }
    if (probe_pending) {
        probe_pending = false;
        con.puts("timer probe ms=");
        con.print_u64(probe_result_ms);
        con.puts(" late_us=");
        con.print_u64(probe_result_late_us);
        con.puts("\n");
    }
}

// ---------------------------------------------------------------------------
// Tests (host-side; fixtures are RAM buffers, asm is aarch64-only)
// ---------------------------------------------------------------------------

test "timer: GTDT fixture yields the EL1 physical timer GSIV" {
    var buf: [96]u8 align(16) = undefined;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[56..60], 30, .little);
    std.mem.writeInt(u32, buf[60..64], 1, .little);
    ppi = 0;
    interrupt_edge = false;
    discover(@intFromPtr(&buf));
    try std.testing.expectEqual(@as(u32, 30), ppi);
    try std.testing.expect(interrupt_edge);
}

test "timer: GTDT with zero GSIV keeps the conventional PPI" {
    var buf: [96]u8 align(16) = undefined;
    @memset(&buf, 0);
    ppi = ppi_default;
    interrupt_edge = true;
    discover(@intFromPtr(&buf));
    try std.testing.expectEqual(ppi_default, ppi);
    try std.testing.expect(!interrupt_edge);
    discover(0);
    try std.testing.expectEqual(ppi_default, ppi);
}

test "timer: heartbeat cadence is every 5 ticks and prints once" {
    var mock = console.MockConsole(1024){};
    var con = mock.console();
    ticks = 0;
    irq_ticks = 0;
    poll_ticks = 0;
    pending_heartbeat = false;
    pending_irq_report = false;
    var tick: u64 = 0;
    while (tick < 11) : (tick += 1) {
        on_tick();
        maybe_heartbeat(&con);
    }
    const out = mock.contents();
    // 11 ticks -> heartbeats at 5 and 10 -> two lines.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "timer heartbeat ticks="));
    try std.testing.expect(std.mem.indexOf(u8, out, "timer heartbeat ticks=5 irq=0 poll=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "timer heartbeat ticks=10 irq=0 poll=0\n") != null);
    // The pending flag is consumed: another call prints nothing.
    mock.reset();
    maybe_heartbeat(&con);
    try std.testing.expectEqual(@as(usize, 0), mock.contents().len);
}

test "timer: first IRQ is reported separately from heartbeat cadence" {
    var mock = console.MockConsole(1024){};
    var con = mock.console();
    ticks = 0;
    irq_ticks = 0;
    poll_ticks = 0;
    ppi = 30;
    pending_heartbeat = false;
    pending_irq_report = false;
    record_tick(.irq);
    maybe_heartbeat(&con);
    try std.testing.expectEqualStrings(
        "timer irq delivered ppi=0x1e irq_ticks=1\n",
        mock.contents(),
    );
}

test "timer: sampling delivery report uses one complete transport write" {
    const Capture = struct {
        mock: console.MockConsole(1024) = .{},
        writes: usize = 0,

        fn write(ctx: *anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.writes += 1;
            self.mock.console().puts(bytes);
        }
        fn flush(_: *anyopaque) void {}
        fn read(_: *anyopaque) ?u8 {
            return null;
        }
        const vtable = console.Console.VTable{ .write = write, .flush = flush, .readByte = read };
    };
    const saved_freq = freq;
    const saved_heartbeat = pending_heartbeat;
    const saved_irq = pending_irq_report;
    const saved_reports = profile_reports;
    var saved_pending: [4]bool = undefined;
    for (&profile_pending, 0..) |*pending, c| {
        saved_pending[c] = pending.load(.acquire);
        pending.store(false, .release);
    }
    defer {
        freq = saved_freq;
        pending_heartbeat = saved_heartbeat;
        pending_irq_report = saved_irq;
        profile_reports = saved_reports;
        for (&profile_pending, saved_pending) |*pending, saved| pending.store(saved, .release);
    }
    freq = 24_000_000;
    pending_heartbeat = false;
    pending_irq_report = false;
    profile_reports[0] = .{ .irqs = 1000, .elapsed = 240_000_000, .ticks = 10 };
    profile_pending[0].store(true, .release);
    var capture = Capture{};
    var con = console.Console{ .ctx = &capture, .vtable = &Capture.vtable };
    maybe_heartbeat(&con);
    try std.testing.expectEqual(@as(usize, 1), capture.writes);
    try std.testing.expectEqualStrings(
        "prof: timer core=0 irq=1000 poll=0 elapsed_cntpct=240000000 freq=24000000 physical_ticks=10\n",
        capture.mock.contents(),
    );
    maybe_heartbeat(&con);
    try std.testing.expectEqual(@as(usize, 1), capture.writes);
}

test "timer: ppi matching is exact" {
    ppi = 30;
    try std.testing.expect(is_ppi(30));
    try std.testing.expect(!is_ppi(29));
    try std.testing.expect(!is_ppi(31));
    try std.testing.expect(!is_ppi(1023));
}

test "timer: period math for a 1 s tick" {
    try std.testing.expectEqual(@as(u64, 24_000_000), 24_000_000 * period_ns / 1_000_000_000);
    try std.testing.expectEqual(@as(u64, 100_000_000), 100_000_000 * period_ns / 1_000_000_000);
}

test "timer: wall_epoch tracks the boot epoch and local_time_of_day wraps (#1058)" {
    const saved = boot_epoch_secs;
    const saved_ticks = ticks;
    defer {
        boot_epoch_secs = saved;
        ticks = saved_ticks;
    }

    // No firmware epoch captured: the honest null (uptime fallback).
    set_boot_epoch_secs(std.math.maxInt(u64));
    ticks = 0;
    try std.testing.expectEqual(@as(?u64, null), wall_epoch());
    try std.testing.expectEqual(@as(?u64, null), local_time_of_day());

    // Boot epoch + elapsed seconds.
    const boot = 1_789_043_696; // 2026-09-10 12:34:56 wall-clock
    set_boot_epoch_secs(boot);
    ticks = 0;
    try std.testing.expectEqual(@as(?u64, boot), wall_epoch());
    try std.testing.expectEqual(@as(?u64, 12 * 3600 + 34 * 60 + 56), local_time_of_day());

    // 20 s later is 12:35:16 the same day.
    ticks = 20;
    try std.testing.expectEqual(@as(?u64, boot + 20), wall_epoch());
    try std.testing.expectEqual(@as(?u64, 12 * 3600 + 35 * 60 + 16), local_time_of_day());

    // A boot at 23:59:50 crosses midnight: 00:00:10 the next day.
    set_boot_epoch_secs(boot - (12 * 3600 + 34 * 60 + 56) + 23 * 3600 + 59 * 60 + 50);
    ticks = 20;
    try std.testing.expectEqual(@as(?u64, 10), local_time_of_day());
}

test "timer: set_wall_epoch re-anchors the clock and refuses out-of-range values (M83b #1775)" {
    const saved = boot_epoch_secs;
    const saved_ticks = ticks;
    defer {
        boot_epoch_secs = saved;
        ticks = saved_ticks;
    }

    // A boot with no firmware epoch has no clock; a set gives it one.
    set_boot_epoch_secs(std.math.maxInt(u64));
    ticks = 7;
    try std.testing.expectEqual(@as(?u64, null), wall_epoch());
    const synced: u64 = 1_789_043_696; // 2026-09-10 12:34:56
    try std.testing.expect(set_wall_epoch(synced));
    try std.testing.expectEqual(@as(?u64, synced), wall_epoch());

    // The tick count is untouched, so the clock keeps advancing from the new
    // anchor and uptime is not rewritten.
    ticks = 10;
    try std.testing.expectEqual(@as(?u64, synced + 3), wall_epoch());
    try std.testing.expectEqual(@as(u64, 10), ticks);

    // A backwards step is allowed: this is a correction, not a monotonic clock.
    try std.testing.expect(set_wall_epoch(synced - 3600));
    try std.testing.expectEqual(@as(?u64, synced - 3600), wall_epoch());

    // The range is inclusive at both ends; one second outside either end,
    // zero, and all-ones change nothing.
    try std.testing.expect(set_wall_epoch(wall_epoch_min));
    try std.testing.expectEqual(@as(?u64, wall_epoch_min), wall_epoch());
    try std.testing.expect(set_wall_epoch(wall_epoch_max));
    try std.testing.expectEqual(@as(?u64, wall_epoch_max), wall_epoch());
    const held = boot_epoch_secs;
    for ([_]u64{ 0, wall_epoch_min - 1, wall_epoch_max + 1, 0xffff_ffff, std.math.maxInt(u64) }) |bad| {
        try std.testing.expect(!set_wall_epoch(bad));
        try std.testing.expectEqual(held, boot_epoch_secs);
    }
}

// M170a (#3033, ADR 0060): deadline overlay — comparator choice, fire
// classification, counter isolation, and the probe drain. `fire_for_test`
// injects the counter value; `program`'s comparator write stays aarch64.
test "timer: comparator target is min(heartbeat boundary, earliest deadline)" {
    // No deadline pending: the heartbeat boundary stands.
    try std.testing.expectEqual(@as(u64, 1_000), choose_target(1_000, 0));
    // Earlier deadline pulls the comparator forward.
    try std.testing.expectEqual(@as(u64, 400), choose_target(1_000, 400));
    // Later deadline never delays the heartbeat.
    try std.testing.expectEqual(@as(u64, 1_000), choose_target(1_000, 4_000));
    // An exact tie arms the boundary; the fire services both.
    try std.testing.expectEqual(@as(u64, 700), choose_target(700, 700));
}

test "timer: ns_to_ticks ceils and saturates" {
    const saved_freq = freq;
    defer freq = saved_freq;
    freq = 24_000_000;
    try std.testing.expectEqual(@as(u64, 0), ns_to_ticks(0));
    try std.testing.expectEqual(@as(u64, 1_200_000), ns_to_ticks(50_000_000)); // 50 ms
    // Sub-tick deadlines arm at the NEXT tick — never early.
    try std.testing.expectEqual(@as(u64, 24_001), ns_to_ticks(1_000_001)); // 1 ms + 1 ns
    freq = 100_000_000_000; // absurd frequency exercises the u64 saturator
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), ns_to_ticks(std.math.maxInt(u64)));
    freq = 0;
    try std.testing.expectEqual(@as(u64, 0), ns_to_ticks(1_000_000));
}

test "timer: fire classification — heartbeat vs deadline vs both vs spurious" {
    const saved_freq = freq;
    const saved_ticks = ticks;
    const saved_irq = irq_ticks;
    const saved_dl = deadline_irqs;
    defer {
        freq = saved_freq;
        ticks = saved_ticks;
        irq_ticks = saved_irq;
        deadline_irqs = saved_dl;
        heartbeat_cval = @splat(0);
        deadline_ns = @splat(0);
        retry_cval = @splat(0);
        last_fire = @splat(.none);
        pending_heartbeat = false;
        pending_irq_report = false;
        deadline_wake_hook = null;
    }
    freq = 1_000_000_000; // 1 tick == 1 ns, for readable deadlines
    period_ticks = 1_000;
    defer period_ticks = 0;
    ticks = 0;
    irq_ticks = 0;
    deadline_irqs = 0;
    heartbeat_cval = @splat(0);
    deadline_ns = @splat(0);
    // The arm is not itself a fire.
    try std.testing.expectEqual(FireKind.none, fire_for_test(0, 0));
    heartbeat_cval[0] = 1_000;
    // A deadline armed before the boundary fires alone: no tick counted.
    deadline_ns[0] = 400;
    try std.testing.expectEqual(FireKind.deadline, fire_for_test(0, 400));
    try std.testing.expectEqual(@as(u64, 1), deadline_irqs);
    try std.testing.expectEqual(@as(u64, 0), ticks);
    try std.testing.expectEqual(@as(u64, 0), irq_ticks);
    try std.testing.expectEqual(FireKind.deadline, fire_kind(0));
    // The wake consumes the entry and republishes — no hook installed in
    // this test, so emulate the publish explicitly.
    deadline_ns[0] = 0;
    // The boundary still lands on schedule and records the tick.
    try std.testing.expectEqual(FireKind.heartbeat, fire_for_test(0, 1_000));
    try std.testing.expectEqual(@as(u64, 1), ticks);
    try std.testing.expectEqual(@as(u64, 1), irq_ticks);
    try std.testing.expectEqual(@as(u64, 1), deadline_irqs);
    try std.testing.expectEqual(@as(u64, 2_000), heartbeat_cval[0]);
    // A fire late enough to cross both counts both reasons.
    deadline_ns[0] = 1_500;
    try std.testing.expectEqual(FireKind.both, fire_for_test(0, 2_100));
    try std.testing.expectEqual(@as(u64, 2), ticks);
    try std.testing.expectEqual(@as(u64, 2), deadline_irqs);
    deadline_ns[0] = 0;
    // A stale armed deadline firing with nothing due is .none — never a tick.
    try std.testing.expectEqual(FireKind.none, fire_for_test(0, 2_500));
    try std.testing.expectEqual(@as(u64, 2), ticks);
    try std.testing.expectEqual(@as(u64, 2), irq_ticks);
    // A deadline beyond the boundary does not disturb either cadence.
    deadline_ns[0] = 99_000;
    try std.testing.expectEqual(FireKind.heartbeat, fire_for_test(0, 3_100));
    try std.testing.expectEqual(@as(u64, 3), ticks);
    try std.testing.expectEqual(@as(u64, 2), deadline_irqs);
}

test "timer: a burst of deadlines leaves the heartbeat counters untouched" {
    const saved_freq = freq;
    const saved_ticks = ticks;
    const saved_irq = irq_ticks;
    const saved_dl = deadline_irqs;
    defer {
        freq = saved_freq;
        ticks = saved_ticks;
        irq_ticks = saved_irq;
        deadline_irqs = saved_dl;
        heartbeat_cval = @splat(0);
        deadline_ns = @splat(0);
        last_fire = @splat(.none);
        pending_heartbeat = false;
        pending_irq_report = false;
        deadline_wake_hook = null;
    }
    freq = 1_000_000_000;
    period_ticks = 10_000;
    defer period_ticks = 0;
    ticks = 0;
    irq_ticks = 0;
    deadline_irqs = 0;
    heartbeat_cval[0] = 10_000;
    // Nine deadline fires inside one period + one heartbeat fire.
    var wakes: u64 = 0;
    const Hook = struct {
        var count: *u64 = undefined;
        fn f(_: u32) void {
            count.* += 1;
        }
    };
    Hook.count = &wakes;
    deadline_wake_hook = &Hook.f;
    var t: u64 = 100;
    while (t <= 900) : (t += 100) {
        deadline_ns[0] = t;
        try std.testing.expectEqual(FireKind.deadline, fire_for_test(0, t));
    }
    deadline_ns[0] = 0;
    try std.testing.expectEqual(@as(u64, 9), wakes);
    try std.testing.expectEqual(@as(u64, 9), deadline_irqs);
    try std.testing.expectEqual(@as(u64, 0), ticks);
    try std.testing.expectEqual(@as(u64, 0), irq_ticks);
    try std.testing.expectEqual(FireKind.heartbeat, fire_for_test(0, 10_000));
    try std.testing.expectEqual(@as(u64, 1), ticks);
    try std.testing.expectEqual(@as(u64, 1), irq_ticks);
}

test "timer: probe_done drains once through maybe_heartbeat" {
    var mock = console.MockConsole(1024){};
    var con = mock.console();
    probe_pending = false;
    defer probe_pending = false;
    probe_done(50, 123);
    maybe_heartbeat(&con);
    try std.testing.expectEqualStrings("timer probe ms=50 late_us=123\n", mock.contents());
    mock.reset();
    maybe_heartbeat(&con);
    try std.testing.expectEqual(@as(usize, 0), mock.contents().len);
}
