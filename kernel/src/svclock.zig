//! VirelaiOS service-domain locks (claim 9498 follow-on: per-subsystem
//! locking so syscalls on different cores contend only when they touch the
//! SAME subsystem).
//!
//! The claim-9498 coarse gate restored the single-core semantic over ALL
//! shared user-visible service state, which serialized unrelated domains
//! (the in-guest compiler's file I/O starved window/net/event syscalls).
//! This module replaces it with one IRQ-masking, holder-tracked lock per
//! service domain, plus a canonical ACQUISITION ORDER that makes every
//! multi-lock path deadlock-free:
//!
//!     file < net < win < ev < kernel
//!
//! - Domain syscalls hold exactly ONE domain lock: FILE (virtio_file,
//!   file_table, exec loads), NET (virtio_net/udp/tcp/arp/dhcp/dns),
//!   WIN (driving_award, wnd_core chrome, the text/font layer), EV
//!   (events, mailbox, app_timers, wm_server).
//! - The `kernel` lock (the old coarse gate) covers everything else:
//!   the process registry + lifecycle, mmap/shared_mmap, clipboard,
//!   audio, pipes, and monitor commands' kernel-state reads.
//! - Multi-lock paths acquire their domains in canonical order and may
//!   end with `kernel`: the exit/fault teardown takes all five; exec
//!   takes FILE then KERNEL; the IRQ tick's protected work takes EV
//!   then KERNEL (try-only, rotation never waits). A nested path may
//!   also take `kernel` while holding an EARLIER domain — uaccess
//!   write-page resolution inside a socket/file syscall takes KERNEL
//!   under NET/FILE — because `kernel` is last, that is still the
//!   canonical direction.
//! - `kernel` is the LAST service-domain lock, and the scheduler's own
//!   locks nest under all five (scheduler.zig: `sched_lock` is brief,
//!   ring locks innermost). The total order is therefore
//!
//!     file < net < win < ev < kernel < sched_lock < ring locks
//!
//! - A path that would take a LOWER-ranked lock while holding a higher
//!   one may NOT: it releases its held bits, takes the needed set
//!   canonically, and re-acquires its bits so the outer caller's paired
//!   release stays balanced (`sys_thread`'s exit op inside a
//!   KERNEL-holding dispatch, monitor `time`'s nested exec — both do
//!   release_set(held_bits()) / acquire_set(...) around the nested
//!   path), or it defers the work to a lock-free beat (the exit-kill
//!   conversion's non-prefix guard). kernel/tests/lock_order_test.zig
//!   drives the real dispatchers through the acquire-order witness
//!   below to keep this rule enforced.
//!
//! Why IRQ-masking matters (the claim-2369/9498 lesson): a holder whose
//! IRQs stay enabled can be preempted mid-critical-section, and a masked
//! spinner on the same core would wait forever. Masking IRQs for the whole
//! hold means a holder always runs to completion, so any context — SVC
//! (already masked), main, fault/exception (masked) — may spin safely.
//! Cross-core contention is bounded by the holder completing.
//!
//! Locks are NOT reentrant: nested acquisition is caller-managed through
//! `held()`, exactly like the claim-9498 gate. The IRQ tick (core 0/1,
//! compositor/app-timer/CPU-limit work) may not spin on a lock it could
//! never release; it uses the `try_*` paths and skips that work.
//!
//! The core count is a literal and the core id is read host-guarded from
//! MPIDR_EL1, exactly like claim 7339's `resume_cores` — importing smp
//! here would cycle smp -> exceptions -> svclock -> smp (exceptions must
//! lock its demand-paging path).
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");
const builtin = @import("builtin");
const spinlock = @import("spinlock.zig");

/// CPU count (matches smp.max_cores); literal to dodge the smp import cycle.
pub const cores: usize = 4;

pub fn core_id() usize {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return 0;
    var mpidr: u64 = 0;
    asm volatile ("mrs %[v], mpidr_el1"
        : [v] "=r" (mpidr),
    );
    const aff0: usize = @intCast(mpidr & 0xFF);
    return if (aff0 < cores) aff0 else 0;
}

fn mask_irq_save() u64 {
    // Host test binaries run at EL0 (`mrs daif` is illegal there), so
    // exclude tests even on Apple Silicon hosts.
    if (comptime !builtin.is_test and builtin.cpu.arch == .aarch64) {
        var daif: u64 = 0;
        asm volatile ("mrs %[v], daif"
            : [v] "=r" (daif),
        );
        asm volatile ("msr daifset, #2"); // Mask IRQ (bit 1)
        return daif;
    }
    return 0;
}

fn restore_irq(saved: u64) void {
    if (comptime !builtin.is_test and builtin.cpu.arch == .aarch64) {
        asm volatile ("msr daif, %[v]"
            :
            : [v] "r" (saved),
        );
    }
}

/// One service-domain lock: an IRQ-masking spinlock with a holder record
/// (so `held()` detects same-core nesting and `try` paths can refuse a
/// reentrant beat) and a per-core pre-acquire DAIF save. The plain
/// acquire/release pair is NOT reentrant — nested entries must check
/// `held()` and skip, releasing only the outermost hold.
pub const SvcLock = struct {
    gate: spinlock.Spinlock = .{},
    /// The core currently inside this lock (`cores` = nobody).
    holder: usize = cores,
    /// The pre-acquire DAIF per core, restored by the matching release.
    saved_daif: [cores]u64 = @as([cores]u64, @splat(@as(u64, 0))),
    /// This lock's canonical-order bit, so the host-test order witness
    /// can record which domain each acquisition took (0 = untagged).
    tag: u5 = 0,

    /// Enter (spinning). IRQs are masked for the whole hold so the holder
    /// can never be preempted mid-critical-section. Callers that may
    /// already hold this lock on the same core must check `held()` first.
    pub fn acquire(self: *SvcLock) void {
        const c = core_id();
        order_witness.note(held_bits(), self.tag);
        self.saved_daif[c] = mask_irq_save();
        self.gate.lock();
        self.holder = c;
    }

    /// Leave, restoring the pre-acquire IRQ state. Pairs with the matching
    /// `acquire` (or a successful `try_acquire`) on the same core; a
    /// nested (held) caller must NOT call this — the outer pair does.
    pub fn release(self: *SvcLock) void {
        const c = core_id();
        self.holder = cores;
        self.gate.unlock();
        restore_irq(self.saved_daif[c]);
    }

    /// True when the calling core already holds this lock. Nested callers
    /// (e.g. the exit teardown inside a syscall) proceed under the outer
    /// hold and must NOT acquire/release again.
    pub fn held(self: *const SvcLock) bool {
        return self.holder == core_id();
    }

    /// Try to enter without blocking. Returns false — and touches nothing —
    /// when the lock is busy OR when the calling core already holds it: a
    /// same-core hit is refused so a reentrant beat never mutates state a
    /// paused holder is mid-way through. Callers skip their work.
    pub fn try_acquire(self: *SvcLock) bool {
        const c = core_id();
        const held_before = held_bits();
        if (self.holder == c) return false;
        if (!self.gate.try_lock()) return false;
        order_witness.note(held_before, self.tag);
        self.saved_daif[c] = mask_irq_save(); // already masked in IRQ context; the restore is a no-op
        self.holder = c;
        return true;
    }
};

// ---------------------------------------------------------------------------
// The five service domains, in canonical acquisition order.
// ---------------------------------------------------------------------------

pub const Dom = enum(u3) { file, net, win, ev, kernel };

/// Canonical-order bit index of each domain (kernel is last).
pub fn dom_bit(d: Dom) u5 {
    return @as(u5, 1) << @backingInt(d);
}

pub const all_bits: u5 = dom_bit(.file) | dom_bit(.net) | dom_bit(.win) | dom_bit(.ev) | dom_bit(.kernel);

pub var file = SvcLock{ .tag = dom_bit(.file) };
pub var net = SvcLock{ .tag = dom_bit(.net) };
pub var win = SvcLock{ .tag = dom_bit(.win) };
pub var ev = SvcLock{ .tag = dom_bit(.ev) };
pub var kernel = SvcLock{ .tag = dom_bit(.kernel) };

/// NOTE: every multi-lock helper below is UNROLLED per domain on purpose.
/// A runtime switch over the domain enum (a `lock_for(d)` helper) makes
/// Zig emit a pointer TABLE in .rodata whose entries are the lock globals'
/// IMAGE-RELATIVE vaddrs — the kernel is fully PIC and never relocates
/// them, so a table lookup returns a raw 0x5f3xx address that faults
/// under ASLR (observed: ldaxr data abort in acquire_set at boot, the
/// claim-9498 follow-on live flake). Direct `file.acquire()`-style
/// references are adrp-based (PC-relative) and always correct.
inline fn take_bit(d: Dom, bits: u5) bool {
    return (bits & (dom_bit(d))) != 0;
}

/// True when the calling core holds EVERY lock in `bits`.
pub fn held_set(bits: u5) bool {
    if (take_bit(.file, bits) and !file.held()) return false;
    if (take_bit(.net, bits) and !net.held()) return false;
    if (take_bit(.win, bits) and !win.held()) return false;
    if (take_bit(.ev, bits) and !ev.held()) return false;
    if (take_bit(.kernel, bits) and !kernel.held()) return false;
    return true;
}

/// The domain bits the calling core currently holds. Sites that must
/// take a lower-ranked domain under a higher hold use this to drop
/// their entire hold before the nested acquisition and to re-acquire
/// it afterwards (see the module header's total-order rule).
pub fn held_bits() u5 {
    const c = core_id();
    var out: u5 = 0;
    if (file.holder == c) out |= dom_bit(.file);
    if (net.holder == c) out |= dom_bit(.net);
    if (win.holder == c) out |= dom_bit(.win);
    if (ev.holder == c) out |= dom_bit(.ev);
    if (kernel.holder == c) out |= dom_bit(.kernel);
    return out;
}

// ---------------------------------------------------------------------------
// Host-test acquire-order witness. A single-core host cannot observe the
// two-core deadlock the canonical order prevents, so every svclock
// acquisition records its held-mask-before and taken-bit in these bounded
// parallel rings; kernel/tests/lock_order_test.zig drives the REAL
// dispatchers and flags any entry whose taken bit does not exceed every
// bit already held — a held-while-acquiring inversion is then a failing
// assertion, not a hang. Outside test builds `note` is a no-op and the
// rings are never emitted.
// ---------------------------------------------------------------------------
pub const order_witness = struct {
    const cap: usize = 64;
    var held_ring: [cap]u5 = undefined;
    var taken_ring: [cap]u5 = undefined;
    var len: usize = 0;

    fn note(held: u5, taken: u5) void {
        if (comptime !builtin.is_test) return;
        if (len >= cap) return;
        held_ring[len] = held;
        taken_ring[len] = taken;
        len += 1;
    }

    /// Forget every recorded acquisition (call before driving a probe).
    pub fn reset() void {
        len = 0;
    }

    /// Acquisitions recorded since `reset`.
    pub fn count() usize {
        return len;
    }

    /// The held mask acquisition `i` observed just before taking.
    pub fn held_at(i: usize) u5 {
        return held_ring[i];
    }

    /// The domain bit acquisition `i` took.
    pub fn taken_at(i: usize) u5 {
        return taken_ring[i];
    }
};

/// The bits in `bits` the calling core does NOT already hold.
fn missing(bits: u5) u5 {
    const c = core_id();
    var out: u5 = 0;
    if (take_bit(.file, bits) and file.holder != c) out |= dom_bit(.file);
    if (take_bit(.net, bits) and net.holder != c) out |= dom_bit(.net);
    if (take_bit(.win, bits) and win.holder != c) out |= dom_bit(.win);
    if (take_bit(.ev, bits) and ev.holder != c) out |= dom_bit(.ev);
    if (take_bit(.kernel, bits) and kernel.holder != c) out |= dom_bit(.kernel);
    return out;
}

/// Acquire every lock in `bits` in canonical order (spinning). Callers
/// must NOT already hold any bit of `bits` (fresh entry — the syscall/
/// command dispatch). Multi-lock paths that may run under a partial outer
/// hold use `acquire_missing` instead.
pub fn acquire_set(bits: u5) void {
    if (take_bit(.file, bits)) file.acquire();
    if (take_bit(.net, bits)) net.acquire();
    if (take_bit(.win, bits)) win.acquire();
    if (take_bit(.ev, bits)) ev.acquire();
    if (take_bit(.kernel, bits)) kernel.acquire();
}

/// Spin-acquire only the bits of `bits` this core does not already hold
/// (canonical order), returning the mask it freshly took. Pairs with
/// `release_set(taken)`. Used by nested teardown entries that may run
/// under an outer partial hold (exit under a sys_exit dispatch, a fault
/// under the kernel lock).
pub fn acquire_missing(bits: u5) u5 {
    const want = missing(bits);
    acquire_set(want);
    return want;
}

/// Release every lock in `bits` in REVERSE canonical order. Pairs with the
/// matching `acquire_set`/`acquire_missing` on the same core; release only
/// the mask those returned.
pub fn release_set(bits: u5) void {
    if (take_bit(.kernel, bits)) kernel.release();
    if (take_bit(.ev, bits)) ev.release();
    if (take_bit(.win, bits)) win.release();
    if (take_bit(.net, bits)) net.release();
    if (take_bit(.file, bits)) file.release();
}

/// Try to take the bits of `bits` this core does not already hold, in
/// canonical order, without blocking. Returns the freshly-taken mask, or
/// null when any missing bit was contended (partial takes are rolled
/// back) — the caller defers its work. NEVER spins, so it is safe to call
/// while holding the scheduler ring lock (the IRQ tick's conversion
/// path); already-held bits (an outer hold) are never released by the
/// caller's `release_set` of the returned mask.
pub fn try_take(bits: u5) ?u5 {
    const want = missing(bits);
    var taken: u5 = 0;
    if (take_bit(.file, want)) {
        if (!file.try_acquire()) return null;
        taken |= dom_bit(.file);
    }
    if (take_bit(.net, want)) {
        if (!net.try_acquire()) {
            release_set(taken);
            return null;
        }
        taken |= dom_bit(.net);
    }
    if (take_bit(.win, want)) {
        if (!win.try_acquire()) {
            release_set(taken);
            return null;
        }
        taken |= dom_bit(.win);
    }
    if (take_bit(.ev, want)) {
        if (!ev.try_acquire()) {
            release_set(taken);
            return null;
        }
        taken |= dom_bit(.ev);
    }
    if (take_bit(.kernel, want)) {
        if (!kernel.try_acquire()) {
            release_set(taken);
            return null;
        }
        taken |= dom_bit(.kernel);
    }
    return taken;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "svclock: acquire/release round-trips and held() tracks the core" {
    try std.testing.expect(!kernel.held());
    kernel.acquire();
    defer kernel.release();
    try std.testing.expect(kernel.held());
    try std.testing.expect(!file.held());
}

test "svclock: each domain lock is independent" {
    file.acquire();
    defer file.release();
    try std.testing.expect(file.held());
    try std.testing.expect(!net.held());
    try std.testing.expect(!win.held());
    try std.testing.expect(!ev.held());
    try std.testing.expect(!kernel.held());
    // The other domains are acquirable while file is held.
    try std.testing.expect(net.try_acquire());
    net.release();
}

test "svclock: try_acquire refuses a same-core reentry" {
    kernel.acquire();
    defer kernel.release();
    try std.testing.expect(!kernel.try_acquire());
}

test "svclock: acquire_set/release_set take the canonical order" {
    acquire_set(dom_bit(.file) | dom_bit(.ev) | dom_bit(.kernel));
    defer release_set(dom_bit(.file) | dom_bit(.ev) | dom_bit(.kernel));
    try std.testing.expect(held_set(dom_bit(.file) | dom_bit(.ev) | dom_bit(.kernel)));
    try std.testing.expect(!net.held());
}

test "svclock: try_take fails cleanly on contention and releases" {
    // Simulate another core holding `ev`: take its underlying gate without
    // setting the holder record (a host test cannot run two cores).
    ev.gate.lock();
    try std.testing.expect(try_take(dom_bit(.file) | dom_bit(.ev) | dom_bit(.kernel)) == null);
    try std.testing.expect(!file.held()); // partial acquisition rolled back
    try std.testing.expect(!kernel.held());
    // Once the contended lock is free the set acquires fully.
    ev.gate.unlock();
    const taken = try_take(dom_bit(.file) | dom_bit(.ev) | dom_bit(.kernel)).?;
    try std.testing.expectEqual(dom_bit(.file) | dom_bit(.ev) | dom_bit(.kernel), taken);
    release_set(taken);
}

test "svclock: try_take skips bits this core already holds" {
    acquire_set(dom_bit(.win) | dom_bit(.ev));
    // The missing bit is taken; the outer win|ev hold is not returned.
    const taken = try_take(dom_bit(.win) | dom_bit(.ev) | dom_bit(.file)).?;
    try std.testing.expectEqual(dom_bit(.file), taken);
    release_set(taken);
    release_set(dom_bit(.win) | dom_bit(.ev));
    try std.testing.expect(!win.held());
}

test "svclock: acquire_missing leaves an outer hold intact" {
    acquire_set(dom_bit(.kernel));
    const taken = acquire_missing(all_bits);
    try std.testing.expectEqual(all_bits & ~dom_bit(.kernel), taken);
    defer release_set(taken);
    try std.testing.expect(held_set(all_bits));
    try std.testing.expect(kernel.held());
    kernel.release();
}
