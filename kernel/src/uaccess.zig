//! VirelaiOS milestone-three uaccess card (claim 6120), extended by the
//! per-task address-space card (claim 5804).
//!
//! Fault-safe, bounded user-memory transfer primitives over the EL0
//! apertures. Since claim 5804 the EL0 task runs in its own address space:
//! the apertures are USER VAs (`text_va`/`stack_va`) mapped only by the
//! user root, and the kernel reaches them through whichever TTBR0 is live
//! (the user root during the task's syscalls; the monitor diagnostic swaps
//! to it explicitly). Two layers make a bad pointer safe:
//!
//!   1. **Validation before access** — `copy_in`/`copy_out` require the whole
//!      range to sit inside a configured EL0 region (user text is readable,
//!      user stack is read-write) with no wrap-around, before any memory is
//!      touched. Everything else (kernel RAM, MMIO, above the identity
//!      blanket, overflow) returns `EFAULT` without dereferencing.
//!   2. **Fault recovery as a second line** — the copy runs inside a masked
//!      "uaccess window". A synchronous data abort (ESR EC 0x24/0x25) taken
//!      while the window is active is a bad user pointer, not a kernel bug:
//!      the claim-9746 exception path calls `try_recover`, which latches the
//!      fault and advances ELR past the 4-byte faulting instruction so the
//!      copy loop resumes, observes the latch, and returns `EFAULT` instead
//!      of crashing EL1. The window is the only code that dereferences user
//!      memory, so every data abort inside it is attributable to a bad user
//!      pointer. IRQs are masked for the window (they are already masked
//!      inside SVC handlers; the monitor diagnostic masks them explicitly),//! so no unrelated task can fault inside the window.
//!
//! No allocation, no libc, no POSIX. The latch is a plain BSS flag written
//! only by the synchronous handler on the same core; the copy's post-loop
//! check keeps the EFAULT contract correct even if an optimizer hoists the
//! in-loop check.

const std = @import("std");
const builtin = @import("builtin");
const mmu = @import("mmu.zig");

// ---------------------------------------------------------------------------
// Issue #1391: the destination guard for kernel -> user stores
// ---------------------------------------------------------------------------
//
// Under a task's own root, TTBR0 carries the kernel's EL1-only identity
// overlay as well as the process's EL0 leaves. So a user VA whose page has
// not been demand-populated yet still RESOLVES for EL1 — to its own identity
// twin (physical == VA, Device where RAM is not, AP = 0b00). A kernel store
// there succeeds and reaches nothing the process can ever read: the guest's
// first read into a buffer EL0 had never written came back as a correct
// LENGTH of zeros (issue #1391), and the store landed on a physical address
// the guest does not own.
//
// `copy_out` therefore never stores into an unproven page. Proving it needs
// the process registry, the page allocator and the kernel domain lock — none
// of which belong in this leaf module (it is imported BY exceptions) — so the
// kernel arms this seam at boot (`exceptions.init`) and each copy-out asks it
// first. The resolver demand-populates the destination page in the process's
// OWN root (the only mapping EL0 will see) or returns false, and the copy is
// refused with EFAULT having touched no memory.
/// Resolution seam: true when every 4 KiB page of [address, address+len) is
/// backed in the calling process's own root (populating any that are not),
/// false when it cannot be — the caller refuses the copy.
pub const ResolveWritePages = *const fn (address: u64, len: usize) bool;

/// Armed by `exceptions.init`; null pre-boot and on host test binaries
/// (which have no user roots, so there is nothing to resolve).
pub var resolve_write_pages: ?ResolveWritePages = null;

/// Issue #2109: the read-direction twin. The identity overlay swallows a
/// store silently, but it answers a LOAD just the same — a copy_in whose
/// source page is only the EL1-only twin (PA == VA) reads kernel physical
/// memory inside the blanket and hands the bytes to the syscall result.
/// The resolver proves every source page is the process's own EL0-visible
/// page (demand-populating a registered-but-unpopulated one, so the copy
/// reads the zero page EL0 itself would fault in) or the copy is refused.
pub const ResolveReadPages = *const fn (address: u64, len: usize) bool;

/// Armed by `exceptions.init`; null pre-boot and on host test binaries
/// (same contract as `resolve_write_pages`).
pub var resolve_read_pages: ?ResolveReadPages = null;

/// CPU count (matches smp.max_cores / svclock.cores); literal to dodge
/// import cycles — uaccess is imported by exceptions.
const cores: usize = 4;

fn core_index() usize {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return 0;
    var mpidr: u64 = 0;
    asm volatile ("mrs %[v], mpidr_el1"
        : [v] "=r" (mpidr),
    );
    const aff0: usize = @intCast(mpidr & 0xFF);
    return if (aff0 < cores) aff0 else 0;
}

/// Result of a bounded transfer. `ok` means the whole range was copied;
/// `fault` means the pointer was bad (validation or a recovered fault) and
/// the syscall layer returns EFAULT.
pub const Outcome = enum { ok, fault };

pub const Region = struct { base: u64, len: u64 };

/// EFAULT as the frozen syscall ABI returns it (the x0 bit pattern of -3;
/// ADR 0007 row -3).
pub const efault: u64 = @bitCast(@as(i64, -3));

/// Diagnostic probe address for the monitor `uaccess` command: 512 MiB above
/// the identity blanket's 4 GiB end, outside every observed VZ device window
/// (console BAR `0x1_0001_0000`, virtio-blk and custom-virtio BARs), so a
/// read is a guaranteed translation fault at EL1 while the uaccess window is
/// active. Revisit if the blanket or BAR placement ever grows.
pub const diagnostic_unmapped: u64 = 0x1_2000_0000;

// Claim 9498 follow-on: domain syscalls run CONCURRENTLY on different
// cores, and every SVC entry re-arms the apertures from ITS OWN core's
// current task — so all of this per-syscall state is per-core (a shared
// copy would let one core's arming race another's validation, and a
// shared window latch would let one core's fault consume another core's
// window).
/// EL0-readable regions (copy-in sources): user text (RX) + user stack (RW) + dynamic segments.
/// Per-core region-list capacity (issue #1163 A1): re-armed at every SVC
/// entry from the task TCB (text + stack + the extras), so it must hold
/// the TCB worst case: 2 base + scheduler.extra_region_capacity. Sized
/// here so a full TCB re-arms completely — a silent drop here was the
/// mmap'd-memory-invisible-to-copy_in bug class.
var read_regions: [cores][26]Region = @as([cores][26]Region, @splat(@as([26]Region, @as([26]Region, @splat(@as(Region, .{ .base = 0, .len = 0 }))))));
var read_region_count: [cores]usize = @as([cores]usize, @splat(@as(usize, 0)));
/// EL0-writable regions (copy-out destinations): the user stack only — the
/// text aperture is read-only at EL0, so copying into it is a permission
/// fault (rejected at validation).
var write_regions: [cores][26]Region = @as([cores][26]Region, @splat(@as([26]Region, @as([26]Region, @splat(@as(Region, .{ .base = 0, .len = 0 }))))));
var write_region_count: [cores]usize = @as([cores]usize, @splat(@as(usize, 0)));

/// The window state is VOLATILE on purpose. `window_active` has no reader
/// inside the copy loop, so without volatile semantics the optimizer
/// (ReleaseSmall + LTO, with the probe address and BSS addresses as known
/// constants) can legally sink the `window_active = true` store below the
/// first user-memory load — then when that load faults, the exception path
/// reads `window_active` as still false and parks instead of recovering
/// (observed: `[EXC] parking` with far=diagnostic_unmapped on the first
/// live run). Volatile accesses cannot be reordered across the copy's
/// memory operations, so the handler always observes the window open at the
/// moment of the fault; the compiler barrier pins it for good measure.
///
/// True while a bounded copy is executing. The claim-9746 synchronous path
/// checks this before converting a data abort into EFAULT.
var window_active: [cores]bool = @as([cores]bool, @splat(@as(bool, false)));
/// Set by `try_recover` when a data abort inside the window was consumed.
/// The copy loop breaks on it and returns `.fault`.
var fault_latch: [cores]bool = @as([cores]bool, @splat(@as(bool, false)));
/// DAIF to restore when the window closes (main-context monitor diagnostic;
/// SVC context already entered with IRQs masked and restores the same value).
var saved_daif: [cores]u64 = @as([cores]u64, @splat(@as(u64, 0)));

fn window_active_read() bool {
    const c = core_index();
    return @as(*volatile bool, &window_active[c]).*;
}

fn set_window_active(value: bool) void {
    const c = core_index();
    @as(*volatile bool, &window_active[c]).* = value;
}

fn latch_read() bool {
    const c = core_index();
    return @as(*volatile bool, &fault_latch[c]).*;
}

fn set_latch(value: bool) void {
    const c = core_index();
    @as(*volatile bool, &fault_latch[c]).* = value;
}

/// Compiler barrier: no memory operation may move across it. Pins the
/// window-open stores before the copy loop and the copy before the
/// window-close stores.
fn compiler_barrier() void {
    asm volatile ("" ::: .{ .memory = true });
}

var copies_value: [cores]u64 = @as([cores]u64, @splat(@as(u64, 0)));
var validation_faults_value: [cores]u64 = @as([cores]u64, @splat(@as(u64, 0)));
var recoveries_value: [cores]u64 = @as([cores]u64, @splat(@as(u64, 0)));
/// Issue #1391: copy-outs refused because a destination page could not be
/// resolved in the process's own root. Zero is the healthy value — a
/// non-zero one means a store would have been swallowed by the identity
/// overlay (or the caller passed a page it does not own).
var unbacked_value: [cores]u64 = @as([cores]u64, @splat(@as(u64, 0)));

pub const Stats = struct {
    copies: u64,
    validation_faults: u64,
    recoveries: u64,
    unbacked: u64,
};

/// Reset module state (kernel boot / host tests). Regions are re-configured
/// with `set_regions` immediately after.
pub fn init() void {
    const c = core_index();
    read_regions[c] = @as([26]Region, @splat(@as(Region, .{ .base = 0, .len = 0 })));
    write_regions[c] = @as([26]Region, @splat(@as(Region, .{ .base = 0, .len = 0 })));
    read_region_count[c] = 0;
    write_region_count[c] = 0;
    set_window_active(false);
    set_latch(false);
    saved_daif[c] = 0;
    copies_value[c] = 0;
    validation_faults_value[c] = 0;
    recoveries_value[c] = 0;
    unbacked_value[c] = 0;
}

/// Configure the claim-8215 EL0 apertures (text readable, stack read-write).
/// The syscall layer delegates its `set_user_regions` here.
pub fn set_regions(text: Region, stack: Region) void {
    const c = core_index();
    read_regions[c] = @as([26]Region, @splat(@as(Region, .{ .base = 0, .len = 0 })));
    write_regions[c] = @as([26]Region, @splat(@as(Region, .{ .base = 0, .len = 0 })));
    read_regions[c][0] = text;
    read_regions[c][1] = stack;
    read_region_count[c] = 2;
    write_regions[c][0] = stack;
    write_region_count[c] = 1;
}

/// Add an additional readable EL0 aperture (e.g. interpreter text, dynamic segments, shared libs).
/// Returns false when the per-core list is full — callers that register
/// on behalf of a pre-checked TCB can treat false as unreachable, but the
/// return keeps the drop LOUD for new callers (issue #1163 A1).
pub fn add_read_region(reg: Region) bool {
    if (reg.len == 0) return true;
    const c = core_index();
    if (read_region_count[c] < read_regions[c].len) {
        read_regions[c][read_region_count[c]] = reg;
        read_region_count[c] += 1;
        return true;
    }
    return false;
}

/// Add an additional writable EL0 aperture (e.g. data segment, heap).
/// See add_read_region (issue #1163 A1).
pub fn add_write_region(reg: Region) bool {
    if (reg.len == 0) return true;
    const c = core_index();
    if (write_region_count[c] < write_regions[c].len) {
        write_regions[c][write_region_count[c]] = reg;
        write_region_count[c] += 1;
        return true;
    }
    return false;
}

/// Remove a dynamic EL0 aperture by base and len.
pub fn remove_region(base: u64, len: u64) void {
    const c = core_index();
    for (&read_regions[c]) |*r| {
        if (r.base == base and (len == 0 or r.len == len)) {
            r.* = .{ .base = 0, .len = 0 };
        }
    }
    for (&write_regions[c]) |*r| {
        if (r.base == base and (len == 0 or r.len == len)) {
            r.* = .{ .base = 0, .len = 0 };
        }
    }
}

pub fn stats() Stats {
    var copies: u64 = 0;
    var vfaults: u64 = 0;
    var recovers: u64 = 0;
    var unbacked: u64 = 0;
    for (copies_value) |v| copies +%= v;
    for (validation_faults_value) |v| vfaults +%= v;
    for (recoveries_value) |v| recovers +%= v;
    for (unbacked_value) |v| unbacked +%= v;
    return .{
        .copies = copies,
        .validation_faults = vfaults,
        .recoveries = recovers,
        .unbacked = unbacked,
    };
}

/// Range check: `[address, address+len)` must be non-wrapping and covered
/// by the armed regions with no gap — every byte inside SOME region. Zero
/// length is always ok (nothing to access). This is the first line of
/// defense; the fault window is the second.
///
/// Issue #2354: coverage, not single-region containment. The armed list is
/// a SET of adjacent apertures — the Go runtime's heap is a chain of
/// separately-registered sbrk mmap regions, so a valid EL0 buffer can
/// straddle a boundary (observed: a 2048-byte read buffer at 0x4bfffec4
/// crossing 0x4c000000, the seam between two armed heap regions, EFAULT'd
/// ~4.4 MiB into a 12 MiB archive read). Each step takes the region that
/// covers `cur` and reaches furthest; a byte no armed region covers ends
/// the walk as a fault. The read/write split is unchanged: copy_out still
/// walks the WRITE list only, so a straddle through a read-only aperture
/// remains a permission fault.
fn range_ok(regions: []const Region, address: u64, len: u64) bool {
    if (len == 0) return true;
    const end = address +% len;
    if (end < address) return false; // overflow: bad pointer
    var cur = address;
    while (cur < end) {
        var next = cur;
        for (regions) |region| {
            if (region.len == 0) continue;
            const region_end = region.base +% region.len;
            if (region_end < region.base) continue;
            if (cur >= region.base and cur < region_end and region_end > next) next = region_end;
        }
        if (next == cur) return false; // no armed region covers this byte
        cur = next;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Bounded transfers
// ---------------------------------------------------------------------------

/// Copy `len` bytes from user memory at `address` into `dst` (kernel-owned).
/// Returns `.fault` — without touching memory — when the range is not fully
/// inside a readable EL0 region, and `.fault` when a data abort was
/// recovered mid-copy (unmapped/permission case that slipped past range
/// validation).
/// Observability seam (issue #1163 A1 tests): does the CURRENT core's
/// armed read-region view cover [address, address+len)? No memory access.
pub fn read_region_covers(address: u64, len: usize) bool {
    const c = core_index();
    return range_ok(read_regions[c][0..read_region_count[c]], address, @intCast(len));
}

/// Futex words must be ONE acquire load, not four potentially torn byte
/// loads. Keep the same validation and synchronous-abort recovery window.
pub fn load_u32(address: u64) ?u32 {
    if ((address & 3) != 0 or !read_region_covers(address, 4)) return null;
    // Issue #2109: the word must come from a page the process owns, not the
    // identity twin (an armed-but-unpopulated mmap page resolves to PA==VA).
    if (resolve_read_pages) |resolve| {
        if (!resolve(address, 4)) {
            unbacked_value[core_index()] +%= 1;
            return null;
        }
    }
    open_window();
    const value = @atomicLoad(u32, @as(*const u32, @ptrFromInt(address)), .acquire);
    const fault = latch_read();
    close_window();
    return if (fault) null else value;
}

pub fn write_region_covers(address: u64, len: usize) bool {
    const c = core_index();
    return range_ok(write_regions[c][0..write_region_count[c]], address, @intCast(len));
}

pub fn copy_in(dst: []u8, address: u64, len: usize) Outcome {
    if (len == 0) return .ok;
    if (len > dst.len) return .fault; // caller bug: bounded by the buffer
    const c = core_index();
    if (!range_ok(read_regions[c][0..read_region_count[c]], address, @intCast(len))) {
        validation_faults_value[c] +%= 1;
        return .fault;
    }
    // Issue #2109: never read through the EL1-only identity overlay. The
    // check is per 4 KiB page of the source and runs before the window
    // opens, so a refusal reads no memory (the mirror of #1391's copy_out
    // destination guard).
    if (resolve_read_pages) |resolve| {
        if (!resolve(address, len)) {
            unbacked_value[c] +%= 1;
            return .fault;
        }
    }
    open_window();
    const result = copy_in_window(dst[0..len], address, len);
    close_window();
    copies_value[c] +%= 1;
    return result;
}

/// Copy `len` bytes from `src` (kernel-owned) into user memory at `address`.
/// Only the writable EL0 region (user stack) is accepted; the read-only text
/// aperture is a permission fault at validation.
pub fn copy_out(address: u64, src: []const u8, len: usize) Outcome {
    if (len == 0) return .ok;
    if (len > src.len) return .fault; // caller bug: bounded by the buffer
    const c = core_index();
    if (!range_ok(write_regions[c][0..write_region_count[c]], address, @intCast(len))) {
        validation_faults_value[c] +%= 1;
        return .fault;
    }
    // Issue #1391: never store through the EL1-only identity overlay. The
    // check is per 4 KiB page of the destination and runs before the window
    // opens, so a refusal leaves the destination untouched.
    if (resolve_write_pages) |resolve| {
        if (!resolve(address, len)) {
            unbacked_value[c] +%= 1;
            return .fault;
        }
    }
    open_window();
    const result = copy_out_window(address, src[0..len], len);
    close_window();
    copies_value[c] +%= 1;
    return result;
}

/// Diagnostic (monitor `uaccess`): copy from `address` with NO range
/// validation, to prove the fault-recovery path on real hardware — the raw
/// load from an unmapped address above the identity blanket takes a real
/// EL1 data abort that `try_recover` converts to `.fault`. Host test
/// processes have no vectors (the dereference would SIGSEGV the test), so
/// there it returns `.fault` without touching memory; the recovery path
/// itself is proven live by the class-B gate.
pub fn raw_copy_in(dst: []u8, address: u64, len: usize) Outcome {
    if (len == 0) return .ok;
    if (len > dst.len) return .fault;
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return .fault;
    open_window();
    const result = copy_in_window(dst[0..len], address, len);
    close_window();
    copies_value[core_index()] +%= 1;
    return result;
}

/// Copy loop for user -> kernel. The caller has already opened the window
/// (IRQs masked, latch clear); the loop breaks on the latch so a data abort
/// consumed by `try_recover` aborts the copy with `.fault` — the post-loop
/// check keeps the EFAULT contract even if an optimizer hoists the in-loop
/// one (the skipped instruction can only be a 4-byte load/store).
fn copy_in_window(dst: []u8, address: u64, len: usize) Outcome {
    const src: [*]const u8 = @ptrFromInt(address);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (latch_read()) break;
        dst[i] = src[i];
    }
    return if (latch_read()) .fault else .ok;
}

/// Copy loop for kernel -> user (window already open by the caller).
fn copy_out_window(address: u64, src: []const u8, len: usize) Outcome {
    const dst: [*]u8 = @ptrFromInt(address);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (latch_read()) break;
        dst[i] = src[i];
    }
    return if (latch_read()) .fault else .ok;
}

// ---------------------------------------------------------------------------
// The uaccess window
// ---------------------------------------------------------------------------

/// Mask IRQs for the window and return the previous DAIF to restore. In SVC
/// context IRQs are already masked at exception entry (no-op); in main
/// context (the monitor diagnostic) this keeps the window free of scheduler
/// preemption so no unrelated task can fault while `window_active` is set.
fn open_window() void {
    saved_daif[core_index()] = mask_irqs();
    set_window_active(true);
    set_latch(false);
    compiler_barrier();
}

fn close_window() void {
    compiler_barrier();
    set_window_active(false);
    restore_daif(saved_daif[core_index()]);
}

fn mask_irqs() u64 {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return 0;
    var daif: u64 = 0;
    asm volatile ("mrs %[v], daif"
        : [v] "=r" (daif),
    );
    asm volatile ("msr daifset, #2");
    return daif;
}

fn restore_daif(daif: u64) void {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    asm volatile ("msr daif, %[v]"
        :
        : [v] "r" (daif),
    );
}

/// Called by the claim-9746 synchronous path (`exc_dispatch`) before the
/// report-and-park fallback. Consumes a data abort taken while the uaccess
/// window is active: latch the fault, advance ELR past the 4-byte faulting
/// instruction (every AArch64 load/store is 4 bytes), and return true so the
/// vector resumes the copy loop, which aborts with EFAULT. Any other
/// synchronous exception — or a data abort outside a window — is not a user
/// pointer problem: return false and let the normal path report/park.
/// Exception context: no console, no allocation.
pub fn try_recover(esr: u64, elr: u64) bool {
    if (!window_active_read()) return false;
    const ec: u64 = (esr >> 26) & 0x3f;
    if (ec != 0x24 and ec != 0x25) return false; // data-abort-lower / -same
    set_latch(true);
    recoveries_value[core_index()] +%= 1;
    if (comptime !builtin.is_test and builtin.cpu.arch == .aarch64) {
        asm volatile ("msr elr_el1, %[v]"
            :
            : [v] "r" (elr + 4),
        );
        asm volatile ("isb");
    }
    return true;
}

// ---------------------------------------------------------------------------
// Monitor diagnostic
// ---------------------------------------------------------------------------

pub const DiagResult = struct {
    valid_copy: bool,
    fault_copy: bool,
    recoveries: u64,
    copies: u64,
    validation_faults: u64,
    /// Issue #1391: kernel->user copies refused because a destination page
    /// was not the calling process's to write. 0 is the healthy value.
    unbacked: u64,
};

/// Monitor `uaccess` diagnostic: prove both paths on live hardware. The
/// validated copy reads the first readable region (the user text aperture)
/// and must succeed; the raw copy dereferences an unmapped address above the
/// identity blanket and must fault and be recovered (`recoveries >= 1` — a
/// real data abort consumed, not just a range rejection). No console output
/// here; the caller prints the result.
pub fn diag() DiagResult {
    var buf: [8]u8 = undefined;
    // Claim 5804: the regions are USER VAs (`text_va`/`stack_va`), mapped
    // only by the user root. The monitor command runs in the shell task,
    // whose TTBR0 is the kernel (identity) root — a raw dereference of a
    // user VA there would read the wrong page — so swap TTBR0 to the user
    // root for the copies and restore after. The raw fault copy still
    // faults: the user root maps only text+stack, so the unmapped probe
    // address is a real EL1 data abort either way. No-ops on host tests.
    const prev_ttbr0 = mmu.current_ttbr0();
    mmu.set_ttbr0(mmu.user_root_phys());
    defer mmu.set_ttbr0(prev_ttbr0);
    const valid = copy_in(&buf, read_regions[core_index()][0].base, 8) == .ok;
    const fault = raw_copy_in(&buf, diagnostic_unmapped, 8) == .fault;
    const totals = stats();
    return .{
        .valid_copy = valid,
        .fault_copy = fault,
        .recoveries = totals.recoveries,
        .copies = totals.copies,
        .validation_faults = totals.validation_faults,
        .unbacked = totals.unbacked,
    };
}

// ---------------------------------------------------------------------------
// Tests (host-side; the hardware recovery is proven live by the class-B
// gate tools/verify-live-uaccess.sh)
// ---------------------------------------------------------------------------

test "uaccess: copy_in copies exact bytes from a readable region" {
    init();
    const text = "hello, user";
    var dst: [64]u8 = undefined;
    set_regions(
        .{ .base = @intFromPtr(text.ptr), .len = text.len },
        .{ .base = 0, .len = 0 },
    );
    try std.testing.expectEqual(Outcome.ok, copy_in(dst[0..text.len], @intFromPtr(text.ptr), text.len));
    try std.testing.expectEqualStrings(text, dst[0..text.len]);
    const s = stats();
    try std.testing.expectEqual(@as(u64, 1), s.copies);
    try std.testing.expectEqual(@as(u64, 0), s.validation_faults);
    try std.testing.expectEqual(@as(u64, 0), s.recoveries);
}

test "uaccess: copy_out writes exact bytes to a writable region" {
    init();
    const text = "kernel says hi";
    var user: [64]u8 = undefined;
    set_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = @intFromPtr(&user), .len = user.len },
    );
    try std.testing.expectEqual(Outcome.ok, copy_out(@intFromPtr(&user), text, text.len));
    try std.testing.expectEqualStrings(text, user[0..text.len]);
}

test "uaccess: boundary — range ending exactly at the region end is ok, one past faults" {
    init();
    const text = "12345678";
    var dst: [64]u8 = undefined;
    set_regions(
        .{ .base = @intFromPtr(text.ptr), .len = text.len },
        .{ .base = 0, .len = 0 },
    );
    // [ptr, ptr+len) exactly fills the region: ok.
    try std.testing.expectEqual(Outcome.ok, copy_in(dst[0..text.len], @intFromPtr(text.ptr), text.len));
    // One byte past the end: fault, without touching memory.
    try std.testing.expectEqual(Outcome.fault, copy_in(dst[0..1], @intFromPtr(text.ptr) + text.len, 1));
    // Starting one byte before the start: fault.
    try std.testing.expectEqual(Outcome.fault, copy_in(dst[0..1], @intFromPtr(text.ptr) - 1, 1));
    // Spanning across the region end: fault.
    try std.testing.expectEqual(Outcome.fault, copy_in(dst[0..text.len], @intFromPtr(text.ptr) + 1, text.len - 1 + 1));
    const s = stats();
    try std.testing.expectEqual(@as(u64, 1), s.copies);
    try std.testing.expectEqual(@as(u64, 3), s.validation_faults);
}

test "uaccess: a range straddling ADJACENT armed regions is covered (issue #2354)" {
    init();
    var buf: [64]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast(i);
    var dst: [64]u8 = undefined;
    const base = @intFromPtr(&buf);
    // The Go-heap shape behind the ~4.4 MiB EFAULT: two separately armed
    // regions sharing one boundary; no single region holds the range.
    set_regions(.{ .base = 0, .len = 0 }, .{ .base = 0, .len = 0 });
    try std.testing.expect(add_read_region(.{ .base = base, .len = 32 }));
    try std.testing.expect(add_read_region(.{ .base = base + 32, .len = 32 }));
    try std.testing.expect(add_write_region(.{ .base = base, .len = 32 }));
    try std.testing.expect(add_write_region(.{ .base = base + 32, .len = 32 }));
    // Reads and writes crossing the seam are covered byte-for-byte.
    try std.testing.expectEqual(Outcome.ok, copy_in(dst[0..48], base + 8, 48));
    try std.testing.expectEqualSlices(u8, buf[8..56], dst[0..48]);
    try std.testing.expectEqual(Outcome.ok, copy_out(base + 8, "0123456789abcdef", 16));
    try std.testing.expectEqualStrings("0123456789abcdef", buf[8..24]);
    const s = stats();
    try std.testing.expectEqual(@as(u64, 2), s.copies);
    try std.testing.expectEqual(@as(u64, 0), s.validation_faults);
}

test "uaccess: straddling a GAP between armed regions still faults (issue #2354)" {
    init();
    var buf: [64]u8 = undefined;
    @memset(buf[0..], 0);
    var dst: [64]u8 = undefined;
    const base = @intFromPtr(&buf);
    set_regions(.{ .base = 0, .len = 0 }, .{ .base = 0, .len = 0 });
    // [base, base+32) and [base+40, base+64): bytes 32..40 are armed NOWHERE.
    try std.testing.expect(add_read_region(.{ .base = base, .len = 32 }));
    try std.testing.expect(add_read_region(.{ .base = base + 40, .len = 24 }));
    try std.testing.expect(add_write_region(.{ .base = base, .len = 32 }));
    try std.testing.expect(add_write_region(.{ .base = base + 40, .len = 24 }));
    // A range reaching into the gap faults — the walk cannot widen to cover it.
    try std.testing.expectEqual(Outcome.fault, copy_in(dst[0..48], base + 8, 48));
    try std.testing.expectEqual(Outcome.fault, copy_out(base + 24, "0123456789abcdef", 16));
    // A range wholly inside the gap faults too.
    try std.testing.expectEqual(Outcome.fault, copy_in(dst[0..4], base + 34, 4));
    // The covered parts still work on both sides of the gap.
    try std.testing.expectEqual(Outcome.ok, copy_in(dst[0..8], base + 8, 8));
    try std.testing.expectEqual(Outcome.ok, copy_in(dst[0..8], base + 48, 8));
    const s = stats();
    try std.testing.expectEqual(@as(u64, 3), s.validation_faults);
}

test "uaccess: a straddle through a read-ONLY aperture stays a write fault (issue #2354)" {
    init();
    var buf: [64]u8 = undefined;
    @memset(buf[0..], 0);
    const base = @intFromPtr(&buf);
    // Read list covers both halves; the WRITE list only the second — the
    // read/write split the coverage walk must not blur.
    set_regions(.{ .base = base, .len = 32 }, .{ .base = base + 32, .len = 32 });
    var dst: [8]u8 = undefined;
    try std.testing.expectEqual(Outcome.ok, copy_in(dst[0..8], base + 28, 8));
    try std.testing.expectEqual(Outcome.fault, copy_out(base + 28, "12345678", 8));
    try std.testing.expectEqual(Outcome.ok, copy_out(base + 32, "12345678", 8));
}

test "uaccess: overflow and zero length" {
    init();
    var dst: [8]u8 = undefined;
    set_regions(
        .{ .base = 0x1000, .len = 0x1000 },
        .{ .base = 0, .len = 0 },
    );
    // address + len wraps: bad pointer.
    try std.testing.expectEqual(Outcome.fault, copy_in(dst[0..], std.math.maxInt(u64) - 1, 4));
    // Zero length is legal even at a wild address (nothing is accessed).
    try std.testing.expectEqual(Outcome.ok, copy_in(dst[0..0], std.math.maxInt(u64), 0));
    // Caller bug guard: len larger than the destination buffer.
    try std.testing.expectEqual(Outcome.fault, copy_in(dst[0..4], 0x1000, 8));
    const s = stats();
    try std.testing.expectEqual(@as(u64, 1), s.validation_faults);
}

test "uaccess: out-of-region kernel/MMIO/blanket addresses fault" {
    init();
    var dst: [8]u8 = undefined;
    const text = "abcdefgh";
    set_regions(
        .{ .base = @intFromPtr(text.ptr), .len = text.len },
        .{ .base = 0, .len = 0 },
    );
    // A kernel address below the blanket (identity-mapped Normal RAM) is
    // NOT in any user region: rejected before any dereference.
    try std.testing.expectEqual(Outcome.fault, copy_in(dst[0..], 0x0, 8));
    // An address above the 4 GiB identity blanket (unmapped) is rejected by
    // validation here; the hardware recovery for such addresses is proven by
    // the raw diagnostic + live gate.
    try std.testing.expectEqual(Outcome.fault, copy_in(dst[0..], diagnostic_unmapped, 8));
}

fn testResolveRefuse(address: u64, len: usize) bool {
    _ = address;
    _ = len;
    return false;
}

fn testResolveAccept(address: u64, len: usize) bool {
    _ = address;
    _ = len;
    return true;
}

test "uaccess: copy_out consults the destination resolver and refuses with EFAULT when it says no (issue #1391)" {
    init();
    const text = "kernel says hi";
    var user: [64]u8 = undefined;
    @memset(user[0..], 0);
    set_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = @intFromPtr(&user), .len = user.len },
    );
    // Unarmed (host tests, pre-boot host: the pre-#1391 contract — the range
    // check alone) copies as before.
    try std.testing.expectEqual(Outcome.ok, copy_out(@intFromPtr(&user), text, text.len));
    try std.testing.expectEqualStrings(text, user[0..text.len]);

    // Armed and refusing: nothing is stored at all, and the refusal is
    // countable (it is the observable form of "this store would have been
    // swallowed by the EL1-only identity overlay").
    @memset(user[0..], 0);
    resolve_write_pages = &testResolveRefuse;
    defer resolve_write_pages = null;
    const before = stats();
    try std.testing.expectEqual(Outcome.fault, copy_out(@intFromPtr(&user), text, text.len));
    try std.testing.expectEqualStrings("\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", user[0..text.len]);
    const after = stats();
    try std.testing.expectEqual(before.unbacked + 1, after.unbacked);
    try std.testing.expectEqual(before.copies, after.copies); // a refused copy never opens the window

    // Armed and accepting: the same copy lands byte-exactly.
    resolve_write_pages = &testResolveAccept;
    try std.testing.expectEqual(Outcome.ok, copy_out(@intFromPtr(&user), text, text.len));
    try std.testing.expectEqualStrings(text, user[0..text.len]);
    try std.testing.expectEqual(after.copies + 1, stats().copies);
}

test "uaccess: copy_in and load_u32 consult the source resolver and refuse when it says no (issue #2109)" {
    init();
    var src: [16]u8 align(4) = undefined;
    @memcpy(src[0..15], "kernel reads me");
    const text = src[0..15];
    var dst: [16]u8 = undefined;
    set_regions(
        .{ .base = @intFromPtr(text.ptr), .len = text.len },
        .{ .base = 0, .len = 0 },
    );
    // Unarmed (host tests, pre-boot host: the pre-#2109 contract — the range
    // check alone) copies as before.
    try std.testing.expectEqual(Outcome.ok, copy_in(dst[0..text.len], @intFromPtr(text.ptr), text.len));
    try std.testing.expectEqualStrings(text, dst[0..text.len]);

    // Armed and refusing: nothing is read at all, and the refusal is
    // countable (the observable form of "this load would have read the
    // EL1-only identity twin — kernel RAM at PA == VA").
    @memset(dst[0..], 0);
    resolve_read_pages = &testResolveRefuse;
    defer resolve_read_pages = null;
    const before = stats();
    try std.testing.expectEqual(Outcome.fault, copy_in(dst[0..text.len], @intFromPtr(text.ptr), text.len));
    try std.testing.expectEqualStrings("\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", dst[0..text.len]);
    var after = stats();
    try std.testing.expectEqual(before.unbacked + 1, after.unbacked);
    try std.testing.expectEqual(before.copies, after.copies); // a refused copy never opens the window
    // load_u32 refuses the same way (the futex-word oracle).
    try std.testing.expectEqual(@as(?u32, null), load_u32(@intFromPtr(text.ptr)));

    // Armed and accepting: the same copy lands byte-exactly.
    resolve_read_pages = &testResolveAccept;
    try std.testing.expectEqual(Outcome.ok, copy_in(dst[0..text.len], @intFromPtr(text.ptr), text.len));
    try std.testing.expectEqualStrings(text, dst[0..text.len]);
    try std.testing.expectEqual(@as(?u32, std.mem.readInt(u32, src[0..4], .little)), load_u32(@intFromPtr(text.ptr)));
    after = stats();
    try std.testing.expectEqual(before.copies + 1, after.copies);
}

test "uaccess: copy_out to the read-only text aperture is a permission fault" {
    init();
    const text = "abcdefgh";
    var user: [64]u8 = undefined;
    set_regions(
        .{ .base = @intFromPtr(text.ptr), .len = text.len },
        .{ .base = @intFromPtr(&user), .len = user.len },
    );
    // Text is readable but not writable: copy_out rejects it.
    try std.testing.expectEqual(Outcome.fault, copy_out(@intFromPtr(text.ptr), "12345678", 8));
    // The writable stack region is fine.
    try std.testing.expectEqual(Outcome.ok, copy_out(@intFromPtr(&user), "12345678", 8));
}

test "uaccess: a fault inside the window aborts the copy with EFAULT" {
    init();
    const text = "abcdefgh";
    var dst: [8]u8 = undefined;
    set_regions(
        .{ .base = @intFromPtr(text.ptr), .len = text.len },
        .{ .base = 0, .len = 0 },
    );
    // Simulate a data abort consumed by try_recover mid-copy: open the
    // window, set the latch (as the synchronous handler would), and run the
    // copy loop — it must observe the latch and abort before completing,
    // never dereferencing the bad range. The real path is proven live by
    // the class-B gate.
    open_window();
    set_latch(true);
    try std.testing.expectEqual(Outcome.fault, copy_in_window(dst[0..8], @intFromPtr(text.ptr), 8));
    close_window();
    // A clean window completes normally. Only the public entry points count
    // a copy; the direct loop call above (with the window already open) does
    // not.
    try std.testing.expectEqual(Outcome.ok, copy_in(dst[0..8], @intFromPtr(text.ptr), 8));
    try std.testing.expectEqualStrings(text, dst[0..8]);
    const s = stats();
    try std.testing.expectEqual(@as(u64, 1), s.copies);
    try std.testing.expectEqual(@as(u64, 0), s.recoveries);
}

test "uaccess: try_recover consumes only data aborts inside the window" {
    init();
    set_regions(.{ .base = 0, .len = 0 }, .{ .base = 0, .len = 0 });
    open_window();
    // Data abort from the same EL (the copy runs at EL1h): consumed.
    try std.testing.expect(try_recover(0x25 << 26, 0x4000));
    try std.testing.expectEqual(@as(u64, 1), stats().recoveries);
    // Data abort from a lower EL: also consumed while the window is active.
    try std.testing.expect(try_recover(0x24 << 26, 0x4004));
    try std.testing.expectEqual(@as(u64, 2), stats().recoveries);
    // A non-data-abort (SVC) inside the window is NOT ours.
    try std.testing.expect(!try_recover(0x15 << 26, 0x4008));
    close_window();
    // Outside the window nothing is consumed.
    try std.testing.expect(!try_recover(0x25 << 26, 0x400c));
    try std.testing.expectEqual(@as(u64, 2), stats().recoveries);
}

test "uaccess: raw_copy_in is host-gated and diag is honest off-hardware" {
    init();
    const text = "abcdefgh";
    var dst: [8]u8 = undefined;
    set_regions(
        .{ .base = @intFromPtr(text.ptr), .len = text.len },
        .{ .base = 0, .len = 0 },
    );
    // Host: no vectors, so the raw probe returns fault without dereferencing.
    try std.testing.expectEqual(Outcome.fault, raw_copy_in(dst[0..], diagnostic_unmapped, 8));
    const d = diag();
    try std.testing.expect(d.valid_copy);
    try std.testing.expect(d.fault_copy);
    try std.testing.expectEqual(@as(u64, 0), d.recoveries);
}
