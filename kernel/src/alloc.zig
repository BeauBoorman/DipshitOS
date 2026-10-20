//! VirelaiOS physical page allocator over the captured EFI map.
//!
//! Next-card milestone (canonical ordering: `docs/status.md`): a first-fit
//! **bitmap** allocator whose pool is the RAM regions of the map the
//! kernel captured pre-exit — conventional, loader, and boot-services
//! (claim 5162: loader/boot-services pooling with exclusion ranges).
//! ADR 0004 D2: the captured map is the sole authority on memory layout —
//! there is no `GetMemoryMap` after exit, so the pool is built once,
//! post-exit, from `MapView` bytes.
//!
//! Pooled types: conventional, loader_code, loader_data, boot_services_code,
//! boot_services_data. NOT pooled: runtime code/data (the kernel still
//! calls ResetSystem/SetVariable through the runtime services table),
//! persistent, ACPI, reserved, MMIO, and every other type — those bits
//! stay set, so they are never handed out.
//!
//! Pooling loader/boot-services regions requires **exclusion ranges**: the
//! kernel image (loader_code, `handoff.kernel_base/size`), the stack
//! (loader_data, `handoff.stack_base/size`), the handoff struct page, and
//! the captured-map buffer (loader_data) are live after exit and must
//! never be handed out. `init` takes an `Exclusion` list; excluded pages
//! are marked allocated (and counted in `Stats.excluded_pages`) exactly
//! like gaps, so `alloc_pages` can never return them. `free_pages` clears
//! only bits it is given, so a caller must never free a page it did not
//! get from `alloc_pages`/`reserve` — freeing an excluded page would
//! unprotect it (caller contract).
//!
//! The bitmap covers the same 4 GiB span the identity map blankets
//! (`mmu.zig`): one bit per 4 KiB page, 1 = allocated, 0 = free. During
//! init every bit in the span is set and then the pooled regions' bits are
//! cleared, so gaps between conventional regions (reserved/MMIO windows)
//! are never allocatable. The bitmap is fixed BSS (128 KiB) — no
//! allocation during construction, no libc, no POSIX, no MMIO, no
//! interrupts. Conventional regions whose whole pages fall outside the
//! 4 GiB span are honestly untracked.
//!
//! The `State` struct owns its bitmap inline, so host tests build fixture
//! states directly; the module also carries one `state` + thin wrappers
//! (the `machine.zig` pattern) for the kernel and the `pages` monitor
//! command.

const std = @import("std");
const builtin = @import("builtin");
pub const memmap = @import("memmap.zig");
const spinlock = @import("spinlock.zig"); // claim 9498: cross-core alloc/free (user tasks on any core)

pub const page_size: u64 = memmap.page_size; // 4096

/// The bitmap's physical span: 4 GiB — the same blanket the identity map
/// covers (mmu.zig). Conventional pages outside it are not tracked.
pub const span_bytes: u64 = 0x1_0000_0000;
pub const max_span_pages: u64 = span_bytes / page_size; // 1 Mi pages
pub const bitmap_bytes: usize = @intCast(max_span_pages / 8); // 128 KiB

/// Maximum pooled regions recorded for reporting. Maps with more regions
/// pool the first `max_regions` (in map order) and leave the rest
/// untracked (honestly visible via `region_count`).
pub const max_regions: usize = 64;

/// One pooled region (whole pages only).
pub const Region = struct {
    base: u64,
    pages: u64,
};

/// A whole-page physical range that must never be handed out, even though
/// it sits inside a pooled region (live kernel image, stack, handoff
/// struct, captured-map buffer). Pages outside every pooled region are
/// already unallocatable (gaps), so an exclusion only ever bites inside
/// pooled regions.
pub const Exclusion = struct {
    base: u64,
    pages: u64,
};

/// Build an exclusion from a byte range: rounds the base down and the size
/// up to whole pages, so a partially-used page is protected whole. A zero
/// `bytes` produces a zero-page (no-op) exclusion.
pub fn exclusion_from_bytes(base: u64, bytes: u64) Exclusion {
    const aligned = base - (base % page_size);
    const end = std.math.add(u64, base, bytes) catch std.math.maxInt(u64);
    const span = std.math.sub(u64, end, aligned) catch 0;
    return .{ .base = aligned, .pages = (span + page_size - 1) / page_size };
}

pub const Stats = struct {
    armed: bool,
    total_pages: u64,
    free_pages: u64,
    /// Pages pooled but excluded (protected) — `total_pages - free_pages`.
    excluded_pages: u64,
    region_count: usize,
    span_pages: u64,
};

pub const State = struct {
    /// 1 = allocated, 0 = free. Bit `i` is page
    /// `bitmap_base + i * page_size`. All bits start SET (allocated); init
    /// clears exactly the pooled pages, so any page the map does not
    /// declare poolable (or that an exclusion protects) is unallocatable.
    bitmap: [bitmap_bytes]u8 = @as([bitmap_bytes]u8, @splat(@as(u8, 0))),
    regions: [max_regions]Region = undefined,
    region_count: usize = 0,
    bitmap_base: u64 = 0,
    span_pages: u64 = 0,
    total_pages: u64 = 0,
    excluded_pages: u64 = 0,
    free_count: u64 = 0,
    armed: bool = false,

    /// Build the pool from a captured map view and a list of protected
    /// exclusion ranges. Resets any prior state. Returns true iff at least
    /// one page is pooled.
    pub fn init(self: *State, view: memmap.MapView, exclusions: []const Exclusion) bool {
        self.bitmap = @as([bitmap_bytes]u8, @splat(@as(u8, 0)));
        self.region_count = 0;
        self.bitmap_base = 0;
        self.span_pages = 0;
        self.total_pages = 0;
        self.excluded_pages = 0;
        self.free_count = 0;
        self.armed = false;
        self.regions = undefined;

        // Pass 1: the aligned pooled span (min aligned base, max end).
        var min_base: u64 = std.math.maxInt(u64);
        var max_end: u64 = 0;
        var index: usize = 0;
        while (index < view.count) : (index += 1) {
            const d = view.get(index) orelse continue;
            if (!is_poolable(d.type)) continue;
            const start = ceil_page(d.physical_start);
            const end_addr = std.math.add(u64, d.physical_start, std.math.mul(u64, d.number_of_pages, page_size) catch continue) catch continue;
            const end = floor_page(end_addr);
            if (start >= end) continue;
            min_base = @min(min_base, start);
            max_end = @max(max_end, end);
        }
        if (min_base == std.math.maxInt(u64)) return false;

        // Cap the span to the bitmap; anything past the cap is untracked.
        self.bitmap_base = min_base;
        const cap_end = std.math.add(u64, min_base, span_bytes) catch span_bytes;
        const span_end = @min(max_end, cap_end);
        self.span_pages = (span_end - min_base) / page_size;
        if (self.span_pages == 0) return false;
        if (self.span_pages > max_span_pages) self.span_pages = max_span_pages;

        // Mark the whole span allocated, then clear exactly the pooled
        // pages — gaps stay unallocatable.
        const span_bytes_full = @as(usize, @intCast((self.span_pages + 7) / 8));
        @memset(self.bitmap[0..span_bytes_full], 0xff);
        if (span_bytes_full * 8 > self.span_pages) {
            // Tail bits beyond span_pages are never addressed; keep them set.
        }

        // Pass 2: pool each whole-page poolable region inside the span.
        var total: u64 = 0;
        index = 0;
        while (index < view.count and self.region_count < max_regions) : (index += 1) {
            const d = view.get(index) orelse continue;
            if (!is_poolable(d.type)) continue;
            const start = ceil_page(d.physical_start);
            const end_addr = std.math.add(u64, d.physical_start, std.math.mul(u64, d.number_of_pages, page_size) catch continue) catch continue;
            const end = floor_page(end_addr);
            if (start >= end) continue;
            if (start < min_base or end > span_end) continue; // outside the capped span
            const pages = (end - start) / page_size;
            const base_index = (start - min_base) / page_size;
            var i: u64 = 0;
            while (i < pages) : (i += 1) self.bit_clear(base_index + i);
            self.regions[self.region_count] = .{ .base = start, .pages = pages };
            self.region_count += 1;
            total = std.math.add(u64, total, pages) catch std.math.maxInt(u64);
        }

        // Pass 3: exclusions — protect live ranges (kernel image, stack,
        // handoff page, map buffer). Each overlap with a pooled region sets
        // those bits back to allocated; counting only 0→1 transitions keeps
        // the free count exact (gaps are already allocated).
        var excluded: u64 = 0;
        for (exclusions) |ex| {
            if (ex.pages == 0) continue;
            const ex_start = @max(ceil_page(ex.base), min_base);
            const ex_end_addr = std.math.add(u64, ex.base, std.math.mul(u64, ex.pages, page_size) catch continue) catch continue;
            const ex_end = @min(floor_page(ex_end_addr), span_end);
            if (ex_start >= ex_end) continue;
            const ex_idx = (ex_start - min_base) / page_size;
            const ex_pages = (ex_end - ex_start) / page_size;
            var i: u64 = 0;
            while (i < ex_pages) : (i += 1) {
                if (!self.bit_get(ex_idx + i)) {
                    self.bit_set(ex_idx + i);
                    excluded += 1;
                }
            }
        }
        self.excluded_pages = excluded;
        self.total_pages = total;
        self.free_count = total - excluded;
        self.armed = self.free_count > 0;
        return self.armed;
    }

    /// Allocate `n` contiguous pages (first-fit). Returns the physical
    /// address of the first page, or null when unavailable. Never touches
    /// the page contents.
    pub fn alloc_pages(self: *State, n: u64) ?u64 {
        if (!self.armed or n == 0 or n > self.free_count or n > self.span_pages) return null;
        var start: u64 = 0;
        while (start + n <= self.span_pages) {
            if (!self.bit_get(start)) {
                var run: u64 = 1;
                while (run < n and !self.bit_get(start + run)) run += 1;
                if (run == n) {
                    var i: u64 = 0;
                    while (i < n) : (i += 1) self.bit_set(start + i);
                    self.free_count -= n;
                    return self.bitmap_base + start * page_size;
                }
                start += run; // the bit at start+run is allocated; skip past it
            }
            start += 1;
        }
        return null;
    }

    /// Free `n` pages at `base`. Bounds-checked; clears only bits that were
    /// set, so freeing already-free pages frees nothing and reports false
    /// (a double free cannot inflate the free count).
    pub fn free_pages(self: *State, base: u64, n: u64) bool {
        if (!self.armed or n == 0) return false;
        const idx = self.index_of(base) orelse return false;
        if (n > self.span_pages or idx > self.span_pages - n) return false;
        var freed: u64 = 0;
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            if (self.bit_get(idx + i)) {
                self.bit_clear(idx + i);
                freed += 1;
            }
        }
        self.free_count += freed;
        return freed > 0;
    }

    /// Size of the largest contiguous free run (in pages). Useful for
    /// callers deciding whether a chunk fits; a bounded single scan of the
    /// bitmap (≤ 1 Mi bits).
    pub fn largest_free_run(self: *const State) u64 {
        if (!self.armed) return 0;
        var best: u64 = 0;
        var run: u64 = 0;
        var i: u64 = 0;
        while (i < self.span_pages) : (i += 1) {
            if (!self.bit_get(i)) {
                run += 1;
                best = @max(best, run);
            } else {
                run = 0;
            }
        }
        return best;
    }

    /// Atomically mark `n` pages at `base` allocated without returning
    /// them (future exclusions / pinning). Returns false if any of the
    /// pages is already allocated or out of bounds; on false nothing
    /// changes.
    pub fn reserve(self: *State, base: u64, n: u64) bool {
        if (!self.armed or n == 0) return false;
        const idx = self.index_of(base) orelse return false;
        if (n > self.span_pages or idx > self.span_pages - n) return false;
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            if (self.bit_get(idx + i)) return false;
        }
        i = 0;
        while (i < n) : (i += 1) self.bit_set(idx + i);
        self.free_count -= n;
        return true;
    }

    pub fn stats(self: *const State) Stats {
        return .{
            .armed = self.armed,
            .total_pages = self.total_pages,
            .free_pages = self.free_count,
            .excluded_pages = self.excluded_pages,
            .region_count = self.region_count,
            .span_pages = self.span_pages,
        };
    }

    // -- bitmap helpers ----------------------------------------------------

    fn index_of(self: *const State, base: u64) ?u64 {
        if (base % page_size != 0) return null;
        if (base < self.bitmap_base) return null;
        const idx = (base - self.bitmap_base) / page_size;
        if (idx >= self.span_pages) return null;
        return idx;
    }

    fn bit_get(self: *const State, index: u64) bool {
        const byte = self.bitmap[@as(usize, @intCast(index / 8))];
        return (byte >> @as(u3, @intCast(index % 8))) & 1 == 1;
    }

    fn bit_set(self: *State, index: u64) void {
        const i: usize = @intCast(index / 8);
        self.bitmap[i] |= @as(u8, 1) << @as(u3, @intCast(index % 8));
    }

    fn bit_clear(self: *State, index: u64) void {
        const i: usize = @intCast(index / 8);
        self.bitmap[i] &= ~(@as(u8, 1) << @as(u3, @intCast(index % 8)));
    }
};

fn ceil_page(addr: u64) u64 {
    const rem = addr % page_size;
    return if (rem == 0) addr else std.math.add(u64, addr, page_size - rem) catch std.math.maxInt(u64);
}

fn floor_page(addr: u64) u64 {
    return addr - (addr % page_size);
}

/// The map types the pool is built from. Runtime code/data is deliberately
/// excluded (ResetSystem/SetVariable still run through it post-exit),
/// persistent/acpi/reserved/MMIO stay unpooled.
fn is_poolable(kind: memmap.MemoryType) bool {
    return switch (kind) {
        .conventional_memory,
        .loader_code,
        .loader_data,
        .boot_services_code,
        .boot_services_data,
        => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Module state (kernel + `pages` monitor command surface; machine.zig style)
// ---------------------------------------------------------------------------

var state: State = .{};

/// Physical-page allocator lock (claim 9498): with user tasks on any core,
/// exec/mmap syscalls (SVC), reaps (main) and demand-paging faults
/// (exception context) allocate concurrently. IRQ-masking so a holder is
/// never preempted mid-critical-section; every allocation context is
/// IRQ-masked anyway, so spinners always find the holder running. Nested
/// allocs on one core cannot happen (alloc never allocates).
var pool_lock = spinlock.IrqSaveSpinlock{};

pub fn init(view: memmap.MapView, exclusions: []const Exclusion) bool {
    const daif = pool_lock.lock();
    defer pool_lock.unlock(daif);
    return state.init(view, exclusions);
}

/// M133a (#2755): single-shot fault injection, TEST BUILDS ONLY. Arm with
/// `inject_fail_nth(k)` and the k-th subsequent `alloc_pages` call (1-based,
/// counting every call while armed) returns null exactly as if the pool
/// were empty, then the hook disarms. The release kernel carries `u0`
/// fields — no injector exists in the shipped image.
var inject_remaining: if (builtin.is_test) u64 else u0 = 0;

/// Arm the injector: the `n`-th subsequent alloc_pages call fails once.
/// `n == 0` disarms. A no-op outside test builds.
pub fn inject_fail_nth(n: u64) void {
    if (comptime !builtin.is_test) return;
    inject_remaining = n;
}

/// Calls remaining until the armed injection trips (0 = disarmed).
pub fn inject_remaining_calls() u64 {
    if (comptime !builtin.is_test) return 0;
    return inject_remaining;
}

pub fn alloc_pages(n: u64) ?u64 {
    if (comptime builtin.is_test) {
        if (inject_remaining > 0) {
            inject_remaining -= 1;
            if (inject_remaining == 0) return null;
        }
    }
    const daif = pool_lock.lock();
    defer pool_lock.unlock(daif);
    return state.alloc_pages(n);
}

pub fn free_pages(base: u64, n: u64) bool {
    const daif = pool_lock.lock();
    defer pool_lock.unlock(daif);
    return state.free_pages(base, n);
}

pub fn reserve(base: u64, n: u64) bool {
    const daif = pool_lock.lock();
    defer pool_lock.unlock(daif);
    return state.reserve(base, n);
}

pub fn stats() Stats {
    return state.stats();
}

/// End (exclusive) of the tracked physical window — `bitmap_base +
/// span_pages * page_size`, the top of the RAM span the allocator can
/// hand out. VZ anchors guest RAM at 0x7000_0000 growing upward (M129a
/// #2610: 256 MiB tops at 0x8000_0000, 512 MiB at 0x9000_0000), so this
/// is the honest "kernel pointer ceiling" the claim-9094 audit bounds
/// used to hardcode as 0x8000_0000. Returns 0 when the pool is unarmed
/// (host tests, pre-init faults); callers keep a fixed fallback for that.
pub fn tracked_end() u64 {
    return state.bitmap_base + state.span_pages * page_size;
}

pub fn largest_free_run() u64 {
    return state.largest_free_run();
}

// ---------------------------------------------------------------------------
// M29: Physical page reference counting for Copy-on-Write (COW) page sharing
// ---------------------------------------------------------------------------
//
// M97b (#2110): the counts live in per-page metadata indexed by physical
// frame, not a bounded side table. The old 256-entry PageRef table silently
// dropped the 257th ref: a >256-page shared surface then had pages whose
// peer ref was never recorded, so revoke/unmap freed pages a peer still
// mapped (two processes, one physical page) and `page_refcount` answered 1
// for an untracked shared page — the COW handler's cue to promote the WM's
// RO `sw_cow` mirror writable in place. One byte per 4 KiB frame of the
// bitmap's span (every page the allocator can hand out, anchored at
// `bitmap_base` like the bitmap itself) makes every pooled page trackable;
// the only failure `ref_page` can still report is a PA outside that span,
// which it now does loudly instead of dropping the ref and letting the
// caller install an unaccounted leaf.
var shared_counts: [max_span_pages]u8 = @as([max_span_pages]u8, @splat(@as(u8, 0)));

pub fn reset_refcounts() void {
    @memset(&shared_counts, 0);
}

/// Index of `pa`'s refcount slot, or null when the page-aligned PA sits
/// outside the tracked span — the same `bitmap_base`-anchored 4 GiB window
/// the bitmap pools, so a page the allocator can never hand out is also a
/// page this table cannot record.
fn shared_slot(pa: u64) ?usize {
    if ((pa & (page_size - 1)) != 0) return null;
    if (pa < state.bitmap_base) return null;
    const idx = (pa - state.bitmap_base) / page_size;
    if (idx >= max_span_pages) return null;
    return @intCast(idx);
}

/// Increment reference count for a physical page. Returns false — the loud
/// failure the old table hid — when the PA is not trackable (unaligned,
/// zero, or outside the blanket) or the count would overflow; a caller
/// that cannot record the ref must NOT install the leaf that needed it.
pub fn ref_page(pa: u64) bool {
    const page_pa = pa & ~@as(u64, 0xfff);
    if (page_pa == 0) return false;
    const idx = shared_slot(page_pa) orelse return false;
    const entry = &shared_counts[idx];
    if (entry.* == std.math.maxInt(u8)) return false;
    // An untracked page going shared was 1 owner; the ref makes it 2.
    entry.* += if (entry.* == 0) 2 else 1;
    return true;
}

/// Decrement reference count for a physical page. Returns true if the page
/// reached 0 references and was freed back to the physical allocator.
pub fn unref_page(pa: u64) bool {
    const page_pa = pa & ~@as(u64, 0xfff);
    if (page_pa == 0) return false;
    if (shared_slot(page_pa)) |idx| {
        const entry = &shared_counts[idx];
        if (entry.* > 0) {
            entry.* -= 1;
            if (entry.* == 0) return free_pages(page_pa, 1);
            return false;
        }
    }
    // Unshared page (count was 1): free directly
    return free_pages(page_pa, 1);
}

/// Query current reference count of a physical page.
pub fn page_refcount(pa: u64) u16 {
    const page_pa = pa & ~@as(u64, 0xfff);
    if (page_pa == 0) return 0;
    return page_refcount_recorded(page_pa) orelse 1;
}

/// M97b (#2110): the refcount only when one is RECORDED — null for an
/// untracked page. `page_refcount` answering 1 for a page that was never
/// recorded is what told the COW promote branch a shared page was sole
/// property; callers that must distinguish "recorded count 1" from
/// "never tracked" use this.
pub fn page_refcount_recorded(pa: u64) ?u16 {
    const page_pa = pa & ~@as(u64, 0xfff);
    const idx = shared_slot(page_pa) orelse return null;
    const count = shared_counts[idx];
    return if (count == 0) null else count;
}
