//! VirelaiOS MMU (claim 0023 split, extended by claim 5804 — per-task
//! user address spaces).
//!
//! Page-table construction, attributes, table allocation, D-cache
//! maintenance for the walk, and the address-space install
//! (`install_identity_map`). The kernel root maps the low physical space
//! one pass: declared RAM as Normal Write-Back (2 MiB blocks where
//! aligned, 4 KiB pages at region edges), declared MMIO windows and every
//! *undeclared* region as Device nGnRnE, so no post-switch access can
//! fault on an unmapped address and device semantics are preserved. ALL
//! kernel-root leaves are EL1-only: no EL0 permissions anywhere (claim
//! 5804 removed the old claim-8215 overlay — EL0 permission now lives only
//! in each task's own TTBR0 user root). The virtio-pci console transport
//! window above the blanket is passed in by the caller (`extra_device`),
//! so this module does not depend on the virtio transport module.
//!
//! Claim 5804: **per-task TTBR0 user address spaces.** The kernel stays
//! identity-mapped in TTBR0 (the low 4 GiB blanket + device windows, all
//! leaves EL1-only) and TTBR1 is NOT used. The original design put the
//! kernel at a TTBR1 KVA shadow so TTBR0 could be swapped freely per task;
//! live VZ measurements proved TTBR1 translation incompatible with this
//! kernel's tables (documented for the ADR): with 4 KiB-aligned tables the
//! TTBR1 walker faults at the FIRST descent level in every configuration —
//! shared L0 root (level-1 fault), dedicated 48-bit L0 root (level-1),
//! dedicated 39-bit L1-rooted mirror with T1SZ=25 (level-2) — despite
//! provably-valid descriptor chains, the signature of a walker masking
//! table addresses to 64 KiB. With 64 KiB-aligned tables the walk finally
//! resolves (block and page leaves), but a Normal-WB DATA access through
//! TTBR1 then aborts (a TLB conflict abort, then a synchronous external
//! abort DFSC=0x21 after extra invalidations) while Device leaves were
//! readable — so a kernel executing from a KVA shadow cannot work on VZ.
//!
//! The card therefore delivers per-task isolation the other way: every
//! task's TTBR0 root carries an EL1-only overlay of the kernel identity
//! map plus that task's own EL0 leaves, so the kernel stays reachable
//! under EVERY root and TTBR0 can be switched per task without breaking
//! kernel execution. `build_user_root` clones the identity tree into a
//! fresh root and overlays the EL0 task's text+stack leaves at their user
//! VAs; the EL1h shell/worker keep the plain kernel root. Isolation is
//! preserved: EL0 has access ONLY to the text+stack leaves — every other
//! leaf (kernel RAM, firmware, MMIO) is EL1-only (AP=0b00), so an EL0
//! access takes a permission fault, UXN/PXN are enforced on every user
//! leaf (W^X), and MMIO is excluded from EL0 by the same EL1-only AP bits
//! (an EL0 access to any Device window is a permission fault, never a
//! device access). The scheduler switches TTBR0 on every context switch;
//! `with_ttbr0` swaps it around firmware/runtime-services calls and the
//! uaccess diagnostic. `to_kva`/`to_phys` are the identity here (no TTBR1
//! alias exists); they remain so the device-facing conversions the
//! transports call stay correct under either design.
//!
//! No libc, no POSIX, allocator, or firmware service is used after the
//! exit boundary. The table storage is a fixed BSS carve-out.

const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const MemoryMapSlice = uefi.tables.MemoryMapSlice;
const MemoryType = uefi.tables.MemoryType;
const handoff = @import("handoff.zig");
const userspace = @import("userspace.zig"); // claim 5804: user VA layout (text_va/stack_va)
const build_options = if (builtin.is_test) struct {
    pub const t0sz25 = false;
} else @import("build_options");

// Claim 5804: the user root CLONES the identity tree (per-task overlay),
// so the carve-out must hold the identity map AND every LIVE root built over
// the boot. #2116: reaped roots return their whole subtree to `table_free`
// (the clone copies tables, it never shares them), so this is now a
// CONCURRENT-roots budget — exec churn no longer drains the carve-out.
// Milestone sixteen C4 (claim 2714) measured the composition (a 28 KiB
// segmented app + a hostile app + EIGHT concurrent programs = 282 pages)
// and grew the carve-out 256 → 512 pages.
const table_page_count = 512; // 2 MiB fixed BSS carve-out, no allocator.
var table_storage: [table_page_count][512]u64 align(4096) = undefined;
var table_count: usize = 0;
/// #2116: free list of reclaimed carve-out table pages (indices into
/// `table_storage`). `new_table` reuses these before bumping `table_count`,
/// so `table_count - table_free_count` is the live page count.
var table_free: [table_page_count]u16 = undefined;
var table_free_count: usize = 0;

/// Physical address of the root translation table (BSS). Exposed for the
/// claim-0021 firmware-MMU-capture diagnostic (evidence.zig), which prints
/// the kernel's planned TTBR0 value for the host-side diff.
pub fn table_root() u64 {
    return @intFromPtr(&table_storage[0]);
}

/// TCR_EL1.T0SZ that install_identity_map() programs: 16 in production
/// (W=48, the 4 KiB stage-1 walk starts at level 0 — matching the built
/// L0-rooted hierarchy, claim 1517). The legacy 25 (W=39, walk starts at
/// level 1 — the claim-6460/7896 start-level mismatch) is selectable with
/// the class-D option -Dt0sz25 for A/B regression. The kernel-plan capture
/// (evidence.zig) prints this same value so a -Dfw-mmu-capture build
/// reports the true planned TCR.
pub const plan_t0sz: u64 = if (build_options.t0sz25) 25 else 16;
/// The builder always maps this low physical range identity. Higher mappings
/// are explicit device/user windows and are not a general syscall aperture.
pub const identity_blanket_end: u64 = 4 * 1024 * 1024 * 1024;

/// Ceiling for any VA a user leaf may occupy: the built hierarchy is
/// L0-rooted (T0SZ=16, 48-bit TTBR0 space), so a VA at or above 2^48 wraps
/// `indices()` and would silently land on a different address.
pub const user_va_limit: u64 = 1 << 48;

/// M97a #2092 / M97c #2095-#2096: an existing leaf may NOT be overlaid by an
/// EL0 leaf when it is kernel-live. EL1-only leaves (AP=0b00) over pooled
/// RAM (AttrIndex 1, Normal) are kernel text/heap/objects — overlaying them
/// gives EL0 a page the kernel itself dereferences under the task's root.
/// Every leaf ABOVE the blanket is a declared descriptor or an explicit
/// device window (the virtio BARs the kernel MMIOs under task roots), so
/// those are refused wholesale. Below the blanket a Device leaf stays
/// overlayable BY DESIGN: the mmap bump window opens at 0x1000_0000 (the
/// GIC hole — the GIC is driven through ICC system registers at runtime,
/// never MMIO, under user roots) and the LD.SO library aperture sits on the
/// declared-but-dead EFI varstore window at 0x0100_0000. An EL0 leaf (AP!=0)
/// is the caller's own page — remap/COW churn is legal.
fn kernel_live_leaf(desc: u64, va: u64) bool {
    if (desc == 0) return false;
    if (((desc >> 6) & 3) != 0) return false; // EL0 leaf — user-owned slot
    if (((desc >> 2) & 7) == 1) return true; // EL1-only Normal = pooled RAM
    return va >= identity_blanket_end;
}

/// Translate a PHYSICAL address to its kernel VA. Claim 5804 (VZ fallback):
/// the kernel has NO TTBR1 KVA alias — it runs identity-mapped in TTBR0 —
/// so this is the identity. Kept so the mmio accessors and the device-
/// facing conversions (virtio DMA GPAs etc.) stay correct under either
/// design.
pub fn to_kva(x: u64) u64 {
    return x;
}

/// Translate a kernel VA back to PHYSICAL — the inverse of `to_kva` (the
/// identity here, since no TTBR1 alias exists). Used for every address the
/// hardware interprets as a guest physical address (virtio descriptor/ring
/// GPAs, allocator exclusions).
pub fn to_phys(x: u64) u64 {
    return x;
}

/// Physical address of the kernel root (the EL1-only identity map). Set by
/// `build_identity_map` (pre-install, so the value is the physical address
/// of the BSS root). TTBR0 points here for the kernel, the EL1h tasks, and
/// around firmware/runtime-services calls.
var kernel_root_value: u64 = 0;
pub fn kernel_root_phys() u64 {
    return kernel_root_value;
}

/// Physical address of the MOST RECENTLY BUILT user root (the identity-tree
/// clone + user leaves). Claim 0826 (concurrent processes): every
/// `build_user_root` call creates a FRESH per-process root and returns its
/// phys; this global tracks the latest one so the `addrspaces`/`uaccess`
/// diagnostics and the boot-time static payload keep a stable target (every
/// user root maps text at the same `userspace.text_va`, so the diagnostics
/// are valid under any of them).
var user_root_value: u64 = 0;
pub fn user_root_phys() u64 {
    return user_root_value;
}

/// Reset the table allocator + root tracking (boot path and host tests; the
/// boot path's `build_identity_map` calls this instead of duplicating the
/// reset). Clears the allocation cursor, so a fresh build starts from table
/// index zero, and forgets both roots.
pub fn reset() void {
    table_count = 0;
    table_free_count = 0;
    user_root_value = 0;
    roots_ready = false;
}

/// Live table pages in the fixed carve-out (`table_page_count` pages, 2 MiB
/// BSS): allocations minus reclaimed ones. The `addrspaces` command prints
/// `tables=<used>/<cap>` so the concurrent-roots budget is observable on a
/// live boot — N sequential execs return it to baseline (#2116).
pub fn tables_used() usize {
    return table_count - table_free_count;
}

/// Total table pages in the fixed carve-out (2 MiB BSS — see
/// `table_page_count`).
pub fn tables_capacity() usize {
    return table_page_count;
}

/// True once both roots are built (kernel + user). Host tests never build
/// them, so diagnostics can report honestly instead of dereferencing
/// garbage.
var roots_ready: bool = false;
pub fn roots_built() bool {
    return roots_ready;
}

/// Claim 6783: exec rebuilt the user root POST-install (the kernel stays
/// identity-mapped, so `@intFromPtr` is still physical and the table
/// allocator keeps working). The freshly allocated clone tables were
/// written as normal stores and are dirty in the D-cache only; the walker
/// reads memory directly, so the whole carve-out is cleaned before the
/// scheduler's next TTBR0 switch (which ends in a TLBI + fresh walk).
/// Cheap: 2 MiB of cache lines, once per exec.
pub fn clean_table_storage() void {
    clean_dcache_range(@intFromPtr(&table_storage), table_page_count * 4096);
}

/// Clean the D-cache over [start, start+len) to the point of coherence so a
/// subsequent translation walk (which may read memory directly, bypassing a
/// dirty cache) sees the real contents. 64-byte lines (Apple silicon
/// MMU_CLINE = 6); addresses are 64-byte aligned.
pub fn clean_dcache_range(start: u64, len: u64) void {
    var addr = start & ~@as(u64, 63);
    const end = start + len;
    while (addr < end) : (addr += 64) {
        asm volatile ("dc cvac, %[addr]"
            :
            : [addr] "r" (addr),
        );
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
}

/// Invalidate the D-cache over [start, start+len) so the CPU re-reads RAM
/// the device just wrote (the virtio used ring). Pairs with
/// clean_dcache_range for device-visible DMA buffers.
pub fn invalidate_dcache_range(start: u64, len: u64) void {
    var addr = start & ~@as(u64, 63);
    const end = start + len;
    while (addr < end) : (addr += 64) {
        asm volatile ("dc ivac, %[addr]"
            :
            : [addr] "r" (addr),
        );
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
}

/// Optional extra Device windows the identity map must cover above the
/// blanket (the virtio-pci console BAR, discovered pre-exit by
/// virtio_console.zig, and the virtio-pci block BAR, discovered by
/// virtio_blk.zig — claim 6420). The caller passes the windows it needs.
pub const DeviceWindow = struct {
    base: u64,
    len: u64,
};

/// A page-isolated Normal-RAM range that EL0 may access. Executable regions
/// are user-read-only and PXN; writable regions are UXN+PXN. There is no
/// representation for user-accessible Device memory.
pub const UserRegion = struct {
    base: u64,
    len: u64,
    writable: bool,
    executable: bool,
};

pub fn build_identity_map(
    map: MemoryMapSlice,
    map_buffer: []align(8) u8,
    base: u64,
    size: u64,
    handoff_rec: *const handoff.HandoffV2,
    extra_device: []const DeviceWindow,
    user_regions: []const UserRegion,
) bool {
    reset();
    _ = new_table() orelse return false; // root table at index zero
    // Claim 5804: capture the root's PHYSICAL address (pre-jump, so
    // @intFromPtr is the identity). TTBR1 + the EL1h tasks' TTBR0 use it.
    kernel_root_value = @intFromPtr(&table_storage[0]);
    roots_ready = false; // rebuilt below; user root comes after
    // One-pass identity map of the low physical space. Declared RAM maps
    // Normal Write-Back (2 MiB blocks where aligned, 4 KiB pages at region
    // edges); declared MMIO windows and every *undeclared* region map Device
    // nGnRnE, so no post-switch access can fault on an unmapped address and
    // device semantics are preserved. The firmware's runtime SetVariable
    // (the marker ladder's channel) touches its NVRAM controller, which the
    // EFI map does not declare; the firmware's own map covers it as Device —
    // mapping it Normal (a previous iteration) lets a cacheable access to an
    // emulated device hang forever, and leaving it unmapped faults — both
    // present as the observed claim-0009 ladder (M2_MAPD! then nothing).
    // Bounded: 4 GiB at 2 MiB = 2048 blocks = 4 L2 tables + L1 + root
    // (~24 KiB of the 512 KiB carve-out).
    const blanket_end = identity_blanket_end;
    if (!map_low_identity(blanket_end, map)) return false;

    // Regions above the blanket (none observed on VZ) still get mapped.
    var it = map.iterator();
    while (it.next()) |desc| {
        if (desc.number_of_pages == 0 or desc.number_of_pages > std.math.maxInt(u64) / 4096) return false;
        const bytes = desc.number_of_pages * 4096;
        if (desc.physical_start > std.math.maxInt(u64) - bytes) return false;
        if (desc.physical_start + bytes <= blanket_end) continue; // covered by the blanket
        if (is_ram(desc.type)) {
            if (!map_range(desc.physical_start, desc.physical_start + bytes, Attr.normal)) return false;
        } else if (desc.type == .memory_mapped_io or desc.type == .memory_mapped_io_port_space) {
            if (!map_range(desc.physical_start, desc.physical_start + bytes, Attr.device)) return false;
        }
    }

    // Claim 0013 (+ claim 6420): the virtio-pci console and block transport
    // windows (firmware-assigned ABOVE the blanket) must stay reachable
    // post-exit. Map each Device (4 KiB pages; the low blanketed world is
    // untouched). Post-exit config writes cannot move the BARs on VZ
    // (observed: a rebase "completed" but the device never answered at the
    // new base), so the firmware's placement is mapped in place instead.
    // The windows come from the caller, who owns the virtio discovery.
    for (extra_device) |window| {
        if (window.base >= blanket_end) {
            if (!map_range(window.base, window.base + window.len, Attr.device)) return false;
        }
    }

    // Claim 5804: the kernel root carries NO EL0 leaves — user permissions
    // live only in the per-task TTBR0 user root built by `build_user_root`,
    // which clones THIS tree and overlays the user leaves at their user
    // VAs.

    // All adopted fixed regions sit inside declared RAM below the blanket;
    // verify they resolve to Normal mappings as a consistency check.
    if (base > std.math.maxInt(u64) - size) return false;
    if (handoff_rec.stack_base > std.math.maxInt(u64) - handoff_rec.stack_size) return false;
    if (!mapped_normal(base)) return false;
    if (!mapped_normal(handoff_rec.stack_base)) return false;
    if (!mapped_normal(@intFromPtr(handoff_rec))) return false;
    if (!mapped_normal(@intFromPtr(map_buffer.ptr))) return false;
    if (!mapped_normal(@intFromPtr(&table_storage))) return false;

    // Claim 5804: build the EL0 task's per-task TTBR0 user root — a clone
    // of this identity tree (the EL1-only kernel overlay) with the user
    // text+stack leaves overlaid at their user VAs. EL0 can reach ONLY
    // those leaves; everything else (kernel RAM, firmware, MMIO) is
    // EL1-only and takes a permission fault. Must run pre-install (the
    // table allocator stores physical addresses, and `@intFromPtr` is
    // identity here).
    var text_region: ?UserRegion = null;
    var stack_region: ?UserRegion = null;
    for (user_regions) |r| {
        if (r.writable and r.executable) return false; // W^X
        if (r.executable) text_region = r;
        if (r.writable) stack_region = r;
    }
    const text = text_region orelse return false;
    const stack = stack_region orelse return false;
    // Claim 0826: the boot-time user root is the FIRST per-process root.
    // The returned phys is the boot payload's root (the current global);
    // later exec'd processes build (and own) their own roots.
    const root = build_user_root(
        userspace.text_va,
        text.base,
        text.len,
        userspace.stack_va,
        stack.base,
        stack.len,
    ) orelse return false;
    _ = root;
    return true;
}

const Attr = enum { normal, device };
const page_size: u64 = 4096;
const block_size: u64 = 2 * 1024 * 1024;

const RegionKind = enum { ram, mmio };

/// True if any descriptor of the given kind overlaps [start, end).
fn region_overlap(start: u64, end: u64, map: MemoryMapSlice, kind: RegionKind) bool {
    var it = map.iterator();
    while (it.next()) |desc| {
        if (desc.number_of_pages == 0 or desc.number_of_pages > std.math.maxInt(u64) / 4096) continue;
        const bytes = desc.number_of_pages * 4096;
        if (desc.physical_start > std.math.maxInt(u64) - bytes) continue;
        const matches = switch (kind) {
            .ram => is_ram(desc.type),
            .mmio => desc.type == .memory_mapped_io or desc.type == .memory_mapped_io_port_space,
        };
        if (!matches) continue;
        if (start < desc.physical_start + bytes and end > desc.physical_start) return true;
    }
    return false;
}

/// True if a single RAM descriptor fully covers [start, start + block_size).
fn block_covered_by_ram(start: u64, map: MemoryMapSlice) bool {
    const end = start + block_size;
    var it = map.iterator();
    while (it.next()) |desc| {
        if (!is_ram(desc.type)) continue;
        if (desc.number_of_pages == 0) continue;
        const bytes = desc.number_of_pages * 4096;
        if (desc.physical_start <= start and desc.physical_start + bytes >= end) return true;
    }
    return false;
}

/// Identity-map [0, end): 2 MiB blocks of Device nGnRnE by default; blocks
/// fully covered by a RAM descriptor map Normal; blocks with any MMIO or
/// partial RAM coverage are mapped at 4 KiB granularity (RAM pages Normal,
/// everything else Device). No post-switch access can then fault, and nothing
/// the firmware reaches with device semantics is ever cacheable.
fn map_low_identity(end: u64, map: MemoryMapSlice) bool {
    const root = &table_storage[0];
    const l1 = ensure_table(&root[0]) orelse return false;
    var va: u64 = 0;
    while (va < end) : (va += block_size) {
        const ix = indices(va);
        const l2 = ensure_table(&l1[ix.l1]) orelse return false;
        const has_ram = region_overlap(va, va + block_size, map, .ram);
        const has_mmio = region_overlap(va, va + block_size, map, .mmio);
        if (!has_ram and !has_mmio) {
            l2[ix.l2] = va | attr_bits(.device, false);
        } else if (has_ram and !has_mmio and block_covered_by_ram(va, map)) {
            l2[ix.l2] = va | attr_bits(.normal, false);
        } else {
            const pages = new_table() orelse return false;
            l2[ix.l2] = @intFromPtr(pages) | 3;
            var page: u64 = 0;
            while (page < block_size) : (page += page_size) {
                const pa = va + page;
                const attr: Attr = if (region_overlap(pa, pa + page_size, map, .ram)) .normal else .device;
                pages[page >> 12] = pa | attr_bits(attr, true);
            }
        }
    }
    return true;
}

/// Walk VA through the built 4 KB-granule tables (T0SZ=16, L0-rooted) and
/// report whether it resolves to a Normal mapping (MAIR AttrIndex = 0b01,
/// descriptor bit 2).
fn mapped_normal(va: u64) bool {
    const ix = indices(va);
    const root = &table_storage[0];
    const l1 = table_entry(&root[ix.l0]) orelse return false;
    var l2e = l1[ix.l1];
    if ((l2e & 3) == 1) return (l2e & 0x4) != 0;
    if ((l2e & 3) != 3) return false;
    const l2 = table_entry(&l2e) orelse return false;
    var l3e = l2[ix.l2];
    if ((l3e & 3) == 1) return (l3e & 0x4) != 0;
    if ((l3e & 3) != 3) return false;
    const l3 = table_entry(&l3e) orelse return false;
    const e = l3[ix.l3];
    if ((e & 3) == 0) return false;
    return (e & 0x4) != 0;
}

fn is_ram(kind: MemoryType) bool {
    return switch (kind) {
        .loader_code, .loader_data, .boot_services_code, .boot_services_data, .conventional_memory, .persistent_memory => true,
        // EFI runtime services code/data stay mapped (Normal WB, executable
        // this milestone) so SetVariable/ResetSystem remain callable after
        // ExitBootServices — the marker NVRAM channel and the M1.5 machine
        // controls both need them. They are RAM; they are never used as
        // general-purpose memory.
        .runtime_services_code, .runtime_services_data => true,
        else => false,
    };
}

fn attr_bits(attr: Attr, page: bool) u64 {
    const base: u64 = if (page) 0x3 else 0x1;
    const mem_attr: u64 = if (attr == .normal) 1 << 2 else 0;
    const share: u64 = if (attr == .normal) 3 << 8 else 0;
    return base | (1 << 10) | share | mem_attr;
}

fn new_table() ?*align(4096) [512]u64 {
    const table: *align(4096) [512]u64 = if (table_free_count > 0) blk: {
        table_free_count -= 1;
        break :blk @ptrCast(&table_storage[table_free[table_free_count]]);
    } else blk: {
        if (table_count >= table_page_count) return null;
        const t: *align(4096) [512]u64 = @ptrCast(&table_storage[table_count]);
        table_count += 1;
        break :blk t;
    };
    @memset(table, 0);
    return table;
}

/// #2116: return `table_phys` to the carve-out free list. Only pages inside
/// `table_storage` are reclaimable — a malformed or foreign root is ignored
/// rather than corrupting the free list.
fn free_table(table_phys: u64) void {
    const base = @intFromPtr(&table_storage);
    if (table_phys < base or table_phys - base >= table_page_count * 4096) return;
    const idx = (table_phys - base) / 4096;
    if (table_free_count < table_page_count) {
        table_free[table_free_count] = @intCast(idx);
        table_free_count += 1;
    }
}

/// Recursively return every table page reachable from `table_phys` at
/// `level` (0 = L0 root) to the free list — children first, then self.
/// A (e & 3) == 3 entry at levels 0-2 is a table descriptor by the ARM
/// encoding; at L3 every entry is a leaf and nothing descends.
fn free_table_level(table_phys: u64, level: u8, freed: *usize) void {
    const base = @intFromPtr(&table_storage);
    if (table_phys < base or table_phys - base >= table_page_count * 4096) return;
    if ((table_phys - base) & 4095 != 0) return;
    const table: *align(4096) [512]u64 = @ptrFromInt(table_phys);
    if (level < 3) {
        for (table) |entry| {
            if ((entry & 3) == 3) free_table_level(entry & ~@as(u64, 0xfff), level + 1, freed);
        }
    }
    free_table(table_phys);
    freed.* += 1;
}

/// #2116: reclaim a DEAD per-process root's whole table subtree. Per-process
/// roots own every table they reach — `clone_into_user_root_apertures`
/// copies the identity tables into fresh carve-out pages, it never points
/// at the shared tree — so the root and all its descendants return to the
/// free list. Refuses the kernel identity root (kernel_root_phys, whose
/// tree every user root was cloned FROM but does not share), a null root,
/// and any root outside the carve-out (host-test fixture addresses). Call
/// only for a root no task can ever run under again (the lifecycle reap).
/// Returns the number of table pages reclaimed.
pub fn free_table_tree(root_phys: u64) usize {
    if (root_phys == 0 or root_phys == kernel_root_phys()) return 0;
    var freed: usize = 0;
    free_table_level(root_phys, 0, &freed);
    return freed;
}

fn table_entry(entry: *const u64) ?*align(4096) [512]u64 {
    if ((entry.* & 3) != 3) return null;
    return @ptrFromInt(entry.* & ~@as(u64, 0xfff));
}

fn ensure_table(entry: *u64) ?*align(4096) [512]u64 {
    if (entry.* == 0) {
        const table = new_table() orelse return null;
        entry.* = @intFromPtr(table) | 3;
        return table;
    }
    return table_entry(entry);
}

fn map_range(start: u64, end: u64, attr: Attr) bool {
    const va_limit: u64 = 1 << 39;
    if (end <= start) return true;
    if (start >= va_limit or end > va_limit) return false;
    if (end > std.math.maxInt(u64) - 4095) return false;
    var pos = start & ~@as(u64, 0xfff);
    const limit = (end + 4095) & ~@as(u64, 0xfff);
    while (pos < limit) {
        if ((pos & (block_size - 1)) == 0 and limit - pos >= block_size) {
            if (!map_block(pos, attr)) return false;
            pos += block_size;
        } else {
            if (!map_page(pos, attr)) return false;
            pos += page_size;
        }
    }
    return true;
}

fn indices(va: u64) struct { l0: usize, l1: usize, l2: usize, l3: usize } {
    return .{
        .l0 = @intCast((va >> 39) & 0x1ff),
        .l1 = @intCast((va >> 30) & 0x1ff),
        .l2 = @intCast((va >> 21) & 0x1ff),
        .l3 = @intCast((va >> 12) & 0x1ff),
    };
}

fn map_block(va: u64, attr: Attr) bool {
    const ix = indices(va);
    const root = &table_storage[0];
    const l1 = ensure_table(&root[ix.l0]) orelse return false;
    const l2 = ensure_table(&l1[ix.l1]) orelse return false;
    const want = (va & ~@as(u64, block_size - 1)) | attr_bits(attr, false);
    if (l2[ix.l2] == 0) {
        l2[ix.l2] = want;
        return true;
    }
    return l2[ix.l2] == want;
}

fn split_block(entry: *u64) bool {
    if ((entry.* & 3) != 1) return false;
    const old = entry.*;
    const base = old & ~@as(u64, block_size - 1);
    const attr = old & 0xfff;
    const pages = new_table() orelse return false;
    var i: usize = 0;
    while (i < 512) : (i += 1) pages[i] = (base + i * page_size) | attr | 3;
    entry.* = @intFromPtr(pages) | 3;
    return true;
}

fn map_page(va: u64, attr: Attr) bool {
    const ix = indices(va);
    const root = &table_storage[0];
    const l1 = ensure_table(&root[ix.l0]) orelse return false;
    const l2 = ensure_table(&l1[ix.l1]) orelse return false;
    if (l2[ix.l2] != 0 and (l2[ix.l2] & 3) == 1 and !split_block(&l2[ix.l2])) return false;
    const l3 = ensure_table(&l2[ix.l2]) orelse return false;
    const want = (va & ~@as(u64, 0xfff)) | attr_bits(attr, true);
    if (l3[ix.l3] == 0 or l3[ix.l3] == want) {
        l3[ix.l3] = want;
        return true;
    }
    return false;
}

/// One EL0 aperture in the user root: a VA range backed by a physical
/// range (text RO+X, data/stack RW, or runtime-linked shared library aperture).
pub const UserAperture = struct {
    va_start: u64,
    va_end: u64,
    phys: u64,
    writable: bool,
    executable: bool,
};

fn slot_shift(level: u8) u6 {
    return switch (level) {
        0 => 39,
        1 => 30,
        2 => 21,
        else => 12,
    };
}

/// Synthesize a fresh page table from a 2 MiB block leaf (the block's
/// attributes on every page) so a clone can override individual pages
/// inside a block that straddles a user aperture.
fn split_block_view(desc: u64) ?*align(4096) [512]u64 {
    if ((desc & 3) != 1) return null; // must be a block leaf
    const base = desc & ~@as(u64, block_size - 1);
    const attrs = desc & 0xfff;
    const pages = new_table() orelse return null;
    var i: usize = 0;
    while (i < 512) : (i += 1) pages[i] = (base + @as(u64, i) * page_size) | attrs | 3;
    return pages;
}

/// A zero source table for aperture slots the identity tree does not cover
/// (issue #1214 review): user apertures may sit ABOVE the 4 GiB identity
/// blanket, where the source has no entry — the clone still has to build
/// the walk to the page level or the aperture is silently unmapped.
const empty_table: [512]u64 = [_]u64{0} ** 512;

/// Bound on a single aperture's page-rounded span (256 MiB — every
/// production aperture is ≤ 64 MiB: `elf.map_max` for image segments, the
/// stack, and the 512 KiB shared-library pool). A larger request is a bad
/// caller, not a big image — refuse it before the clone burns the whole
/// table carve-out descending empty space.
const max_aperture_bytes: u64 = 256 * 1024 * 1024;

/// M97c #2095/#2096: a user aperture must be a well-formed, non-wrapping
/// window BEFORE the clone walks it — the L3 leaf math is
/// `phys + (slot_va - va_start)`, which silently underflows to the page
/// BELOW the allocation when `va_start` sits mid-page past the slot base
/// (and would have mapped that page EL0). `va_end` is deliberately NOT
/// required to be page-aligned: segment `memsz` is byte-granular and the
/// final page carries the `.bss` tail.
fn aperture_form_ok(ap: UserAperture) bool {
    if (ap.va_start == 0 or (ap.va_start & (page_size - 1)) != 0) return false;
    if ((ap.phys & (page_size - 1)) != 0) return false;
    if (ap.va_end <= ap.va_start) return false;
    if (ap.va_end > user_va_limit) return false;
    const span = ap.va_end - ap.va_start;
    if (span > max_aperture_bytes) return false;
    const page_span = (span + page_size - 1) & ~(page_size - 1);
    if (ap.phys > std.math.maxInt(u64) - page_span) return false;
    return true;
}

/// #2095: two apertures may not share a PAGE — the clone resolves the first
/// match per slot, so a page claimed by two apertures would silently bind
/// the wrong physical page to one of them.
fn apertures_overlap(a: UserAperture, b: UserAperture) bool {
    const a_hi = (a.va_end + page_size - 1) & ~(page_size - 1);
    const b_hi = (b.va_end + page_size - 1) & ~(page_size - 1);
    return a.va_start < b_hi and b.va_start < a_hi;
}

/// Recursively clone the identity tree (rooted at `src`, covering
/// [va_base, va_base + 512 << shift(level))) into a fresh per-task root,
/// overriding the user apertures' pages with EL0 leaves. Every other leaf
/// is copied verbatim — the identity leaves are EL1-only (AP=0b00), so the
/// cloned kernel overlay keeps the kernel reachable under the user root
/// while denying EL0 any access to kernel RAM, firmware, or MMIO. Blocks
/// that straddle a user aperture are split so the override reaches the
/// page level. Aperture slots the SOURCE cannot reach (above the identity
/// blanket) are built from `empty_table` instead of skipped — an
/// unmapped-at-EL0 aperture otherwise reads as demand-filled zeros, the
/// go-args-era boot-payload witness hang. Must run BEFORE
/// `install_identity_map` (the table allocator stores physical addresses;
/// pre-install `@intFromPtr` is identity).
fn clone_into_user_root_apertures(
    src: *const [512]u64,
    level: u8,
    va_base: u64,
    apertures: []const UserAperture,
) ?*align(4096) [512]u64 {
    const dst = new_table() orelse return null;
    // #2116: every failure below discards the partially built subtree —
    // a null return used to strand every table this build had already
    // consumed (unreachable from any live root, so reclaimable only here).
    const shift = slot_shift(level);
    const slot_bytes: u64 = @as(u64, 1) << shift;
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        const desc = src[i];
        const slot_va = va_base + @as(u64, i) * slot_bytes;
        const slot_end = slot_va + slot_bytes;
        var matching_ap: ?UserAperture = null;
        for (apertures) |ap| {
            if (slot_va < ap.va_end and slot_end > ap.va_start) {
                matching_ap = ap;
                break;
            }
        }
        const hits_user = (matching_ap != null);
        if (hits_user and level < 3) {
            // The slot intersects a user aperture: the clone must descend
            // to the page level, splitting a covering block if needed, and
            // building the walk from an empty source when the identity
            // tree has no entry here (above the blanket).
            const child_src: *const [512]u64 = if (desc == 0)
                &empty_table
            else if ((desc & 3) == 3)
                table_entry(&src[i]) orelse {
                    discard_table(dst, level);
                    return null;
                }
            else
                split_block_view(desc) orelse {
                    discard_table(dst, level);
                    return null;
                };
            const child = clone_into_user_root_apertures(child_src, level + 1, slot_va, apertures) orelse {
                discard_table(dst, level);
                return null;
            };
            dst[i] = @intFromPtr(child) | 3;
        } else if (hits_user and level == 3) {
            // Page leaf inside a user aperture: the ONLY place EL0
            // permission is granted in the whole root.
            const ap = matching_ap.?;
            // #2092/#2095: never bind a kernel-live twin (pooled RAM or an
            // above-blanket device window) into an EL0 leaf — a bad
            // aperture stops the whole root build, not just this page.
            if (kernel_live_leaf(desc, slot_va)) {
                discard_table(dst, level);
                return null;
            }
            // #2096: `aperture_form_ok` guarantees a page-aligned
            // `va_start`, so an intersecting slot never sits below it —
            // keep the check anyway because ReleaseSmall arithmetic wraps
            // silently and `phys + (slot_va - va_start)` underflowing is
            // precisely the page-below-the-allocation bug.
            if (slot_va < ap.va_start) {
                discard_table(dst, level);
                return null;
            }
            const pa = std.math.add(u64, ap.phys, slot_va - ap.va_start) catch {
                discard_table(dst, level);
                return null;
            };
            const normal = (pa & ~@as(u64, 0xfff)) | attr_bits(.normal, true);
            dst[i] = user_leaf(normal, ap.writable, ap.executable) orelse {
                discard_table(dst, level);
                return null;
            };
        } else if (desc == 0) {
            continue; // no source entry and no aperture here
        } else if ((desc & 3) == 3 and level < 3) {
            const child = clone_into_user_root_apertures(table_entry(&src[i]) orelse {
                discard_table(dst, level);
                return null;
            }, level + 1, slot_va, apertures) orelse {
                discard_table(dst, level);
                return null;
            };
            dst[i] = @intFromPtr(child) | 3;
        } else {
            dst[i] = desc; // block or page leaf — EL1-only AP=0b00, copy verbatim
        }
    }
    return dst;
}

/// #2116: discard a partially built clone subtree on a build failure. Every
/// table reachable from `table` at `level` was allocated by this build
/// (children are written only as `child | 3` after a successful recursive
/// clone), so the carve-out gets them all back — children first, then self.
fn discard_table(table: *align(4096) [512]u64, level: u8) void {
    if (level < 3) {
        for (table) |entry| {
            if ((entry & 3) == 3) discard_table(@ptrFromInt(entry & ~@as(u64, 0xfff)), level + 1);
        }
    }
    free_table(@intFromPtr(table));
}

/// Build a per-process TTBR0 user root with arbitrary user apertures.
/// M97c #2095/#2096: every aperture is validated BEFORE a single table is
/// consumed — page-aligned `va_start`/`phys`, non-empty non-wrapping range
/// inside the 48-bit VA space, bounded span, and no page shared with
/// another aperture — so a malformed window is an honest null return, not
/// a silently corrupted root.
pub fn build_user_root_apertures(apertures: []const UserAperture) ?u64 {
    for (apertures) |ap| {
        if (!aperture_form_ok(ap)) return null;
    }
    for (apertures, 0..) |a, i| {
        for (apertures[i + 1 ..]) |b| {
            if (apertures_overlap(a, b)) return null;
        }
    }
    const root = clone_into_user_root_apertures(&table_storage[0], 0, 0, apertures) orelse return null;
    const root_phys = @intFromPtr(root);
    user_root_value = root_phys;
    roots_ready = true;
    return root_phys;
}

/// Full multi-aperture user root (milestone sixteen C1, claim 3805): like
/// `build_user_root` but with an optional writable DATA aperture (EL0 RW +
/// UXN) mapped between text and stack — the segmented image's `.data`/`.bss`
/// region. `data_len == 0` (or `data_phys == 0`) omits the data aperture.
pub fn build_user_root_full(
    text_va: u64,
    text_phys: u64,
    text_len: u64,
    data_va: u64,
    data_phys: u64,
    data_len: u64,
    stack_va: u64,
    stack_phys: u64,
    stack_len: u64,
) ?u64 {
    var aps: [3]UserAperture = undefined;
    var count: usize = 0;
    aps[count] = .{
        .va_start = text_va,
        .va_end = text_va + text_len,
        .phys = text_phys,
        .writable = false,
        .executable = true,
    };
    count += 1;
    if (data_len > 0 and data_phys > 0) {
        aps[count] = .{
            .va_start = data_va,
            .va_end = data_va + data_len,
            .phys = data_phys,
            .writable = true,
            .executable = false,
        };
        count += 1;
    }
    aps[count] = .{
        .va_start = stack_va,
        .va_end = stack_va + stack_len,
        .phys = stack_phys,
        .writable = true,
        .executable = false,
    };
    count += 1;
    return build_user_root_apertures(aps[0..count]);
}

pub fn build_user_root(
    text_va: u64,
    text_phys: u64,
    text_len: u64,
    stack_va: u64,
    stack_phys: u64,
    stack_len: u64,
) ?u64 {
    return build_user_root_full(text_va, text_phys, text_len, 0, 0, 0, stack_va, stack_phys, stack_len);
}

/// Pure permission transform pinned by host tests. Existing leaf, AttrIndex
/// 1 (Normal WB) only: Device pages can never be promoted into the user
/// aperture by a bad caller.
fn user_leaf(original: u64, writable: bool, executable: bool) ?u64 {
    if (writable and executable) return null;
    if ((original & 3) != 3 or ((original >> 2) & 7) != 1) return null;
    var entry = original;
    const ap_mask: u64 = 3 << 6;
    const pxn: u64 = 1 << 53;
    const uxn: u64 = 1 << 54;
    entry &= ~(ap_mask | pxn | uxn);
    entry |= if (writable) @as(u64, 1 << 6) else @as(u64, 3 << 6);
    if (executable) {
        entry |= pxn; // EL0 executable, EL1 execute-never.
    } else {
        entry |= pxn | uxn;
    }
    return entry;
}

/// Software-defined bit in Stage 1 leaf descriptor (bit 55) marking Copy-on-Write page.
pub const sw_cow: u64 = @as(u64, 1) << 55;

/// Invalidate TLB entry for a single virtual address across inner shareable domain.
pub fn invalidate_tlb_va(va: u64) void {
    if (builtin.is_test) return;
    asm volatile ("tlbi vaae1is, %[v]\n" ++
            "dsb ish\n" ++
            "isb\n"
        :
        : [v] "r" (va >> 12),
    );
}

/// M97a #2092: does the VA's existing leaf (block or page) under `root`
/// forbid an EL0 overlay? Refusing is what stops a user-supplied mmap hint
/// — or any bad region-table entry — from silently shadowing pooled kernel
/// RAM or a live device window: the kernel dereferences those VAs under
/// the task's root, so an EL0 twin would hand a userspace page to the
/// kernel. Device holes and the declared-but-dead MMIO windows BELOW the
/// blanket stay overlayable (the mmap band and the LD.SO library window
/// live on them by design — see `kernel_live_leaf`).
pub fn user_slot_free(root_phys: u64, va: u64) bool {
    if (root_phys == 0 or va >= user_va_limit) return false;
    const root: *align(4096) [512]u64 = @ptrFromInt(root_phys);
    const ix = indices(va);
    const l1 = table_entry(&root[ix.l0]) orelse return true;
    const l2e = l1[ix.l1];
    if (l2e == 0) return true;
    if ((l2e & 3) == 1) return !kernel_live_leaf(l2e, va); // 1 GiB block leaf
    const l2 = table_entry(&l2e) orelse return true;
    const l3e = l2[ix.l2];
    if (l3e == 0) return true;
    if ((l3e & 3) == 1) return !kernel_live_leaf(l3e, va); // 2 MiB block leaf
    const l3 = table_entry(&l3e) orelse return true;
    return !kernel_live_leaf(l3[ix.l3], va);
}

/// #2092: [va, va+len) is a committable EL0 range under `root` when it is
/// non-empty, non-wrapping, page-aligned, inside the VA space, and every
/// page's slot is free. The mmap-hint check in the syscall layer turns a
/// refusal into EINVAL before a region is registered.
pub fn user_range_free(root_phys: u64, va: u64, len: u64) bool {
    if (len == 0 or (va & (page_size - 1)) != 0 or (len & (page_size - 1)) != 0) return false;
    if (va >= user_va_limit or len > user_va_limit - va) return false;
    var pos = va;
    while (pos < va + len) : (pos += page_size) {
        if (!user_slot_free(root_phys, pos)) return false;
    }
    return true;
}

/// Dynamically map a 4 KiB user page at `va` -> `pa` under the given user root.
/// Intermediate level tables are allocated from table_storage as needed.
/// #2092: refuses to overwrite a kernel-live leaf (see `kernel_live_leaf`)
/// — the LAST-line guard if a hint/region check upstream is bypassed.
pub fn map_user_page(root_phys: u64, va: u64, pa: u64, writable: bool, executable: bool) bool {
    if (root_phys == 0 or va >= user_va_limit or (va & (page_size - 1)) != 0 or (pa & (page_size - 1)) != 0) return false;
    const root: *align(4096) [512]u64 = @ptrFromInt(root_phys);
    const ix = indices(va);
    const l1 = ensure_table(&root[ix.l0]) orelse return false;
    clean_dcache_range(@intFromPtr(&root[ix.l0]), 8);
    const l2 = ensure_table(&l1[ix.l1]) orelse return false;
    clean_dcache_range(@intFromPtr(&l1[ix.l1]), 8);
    if (l2[ix.l2] != 0 and (l2[ix.l2] & 3) == 1) {
        if (!split_block(&l2[ix.l2])) return false;
    }
    const l3 = ensure_table(&l2[ix.l2]) orelse return false;
    clean_dcache_range(@intFromPtr(&l2[ix.l2]), 8);
    if (kernel_live_leaf(l3[ix.l3], va)) return false;
    const normal = (pa & ~@as(u64, 0xfff)) | attr_bits(.normal, true);
    const leaf = user_leaf(normal, writable, executable) orelse return false;
    l3[ix.l3] = leaf;
    clean_dcache_range(@intFromPtr(&l3[ix.l3]), 8);
    invalidate_tlb_va(va);
    return true;
}

/// Map a Copy-on-Write 4 KiB user page (EL0-RO + sw_cow bit) under user root.
/// #2092: same kernel-live-twin refusal as `map_user_page`.
pub fn map_user_cow_page(root_phys: u64, va: u64, pa: u64) bool {
    if (root_phys == 0 or va >= user_va_limit or (va & (page_size - 1)) != 0 or (pa & (page_size - 1)) != 0) return false;
    const root: *align(4096) [512]u64 = @ptrFromInt(root_phys);
    const ix = indices(va);
    const l1 = ensure_table(&root[ix.l0]) orelse return false;
    clean_dcache_range(@intFromPtr(&root[ix.l0]), 8);
    const l2 = ensure_table(&l1[ix.l1]) orelse return false;
    clean_dcache_range(@intFromPtr(&l1[ix.l1]), 8);
    if (l2[ix.l2] != 0 and (l2[ix.l2] & 3) == 1) {
        if (!split_block(&l2[ix.l2])) return false;
    }
    const l3 = ensure_table(&l2[ix.l2]) orelse return false;
    clean_dcache_range(@intFromPtr(&l2[ix.l2]), 8);
    if (kernel_live_leaf(l3[ix.l3], va)) return false;
    const normal = (pa & ~@as(u64, 0xfff)) | attr_bits(.normal, true);
    const leaf = user_leaf(normal, false, false) orelse return false;
    l3[ix.l3] = leaf | sw_cow;
    clean_dcache_range(@intFromPtr(&l3[ix.l3]), 8);
    invalidate_tlb_va(va);
    return true;
}

/// Lookup the L3 descriptor pointer for `va` in the user root (or null if not mapped).
pub fn get_user_leaf(root_phys: u64, va: u64) ?*u64 {
    if (root_phys == 0) return null;
    const root: *align(4096) [512]u64 = @ptrFromInt(root_phys);
    const ix = indices(va);
    const l1 = table_entry(&root[ix.l0]) orelse return null;
    const l2 = table_entry(&l1[ix.l1]) orelse return null;
    if ((l2[ix.l2] & 3) == 1) return null; // block leaf, not page table
    const l3 = table_entry(&l2[ix.l2]) orelse return null;
    return &l3[ix.l3];
}

/// Issue #1391: does `va` resolve, in THIS root, to a page EL0 itself can
/// reach? False for an absent entry, for an L2 block leaf (the identity
/// overlay's blocks are EL1-only by construction — `user_leaf` is only ever
/// applied at the page level), and for an EL1-only page leaf. A kernel store
/// through such a mapping returns success and lands on the identity twin
/// (physical == VA), which no EL0 access can observe, so the kernel->user
/// copy path refuses instead of storing.
pub fn leaf_el0_visible(root_phys: u64, va: u64) bool {
    const leaf = get_user_leaf(root_phys, va) orelse return false;
    if ((leaf.* & 3) != 3) return false;
    return ((leaf.* >> 6) & 3) != 0;
}

/// Unmap a 4 KiB user page at `va`, returning the physical address previously mapped.
/// #2092: refuses to strip an EL1-only leaf — only genuine user pages may
/// be torn down, never a cloned kernel-identity twin.
pub fn unmap_user_page(root_phys: u64, va: u64) ?u64 {
    const leaf = get_user_leaf(root_phys, va) orelse return null;
    if ((leaf.* & 3) != 3) return null;
    if (((leaf.* >> 6) & 3) == 0) return null;
    const pa = leaf.* & 0x0000_ffff_ffff_f000;
    leaf.* = 0;
    clean_dcache_range(@intFromPtr(leaf), 8);
    invalidate_tlb_va(va);
    return pa;
}

/// Promote an existing EL0 leaf descriptor to writable and clear sw_cow.
pub fn set_user_leaf_writable(leaf: *u64, writable: bool) void {
    if ((leaf.* & 3) != 3) return;
    const ap_mask: u64 = 3 << 6;
    leaf.* &= ~(ap_mask | sw_cow);
    leaf.* |= if (writable) @as(u64, 1 << 6) else @as(u64, 3 << 6);
    clean_dcache_range(@intFromPtr(leaf), 8);
}

test "mmu: build_user_root returns a fresh root per call (per-process roots)" {
    reset();
    // Host roots clone the (empty) identity tree — the clone machinery
    // still runs, consumes tables, and returns per-call physical roots, so
    // the multi-root API + budget accounting is pinned without hardware.
    const root1 = build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    try std.testing.expect(root1 != 0);
    const root2 = build_user_root(userspace.text_va, 0x1000, 64, 0x1a400000, 0x3000, 8192).?;
    try std.testing.expect(root2 != 0);
    // Claim 5795 (pool scale): the 7-slot budget holds FOUR concurrent user
    // programs (the capstone's headline), so the kernel root + 3 user roots
    // must fit the carve-out with headroom. Build the third user root and
    // pin the budget: every root is distinct, the global tracks the latest,
    // and the 512-page carve-out bounds the whole multi-root set.
    const root3 = build_user_root(userspace.text_va, 0x1000, 64, 0x1a500000, 0x3000, 8192).?;
    try std.testing.expect(root3 != 0);
    // Distinct per-process roots, and the global tracks the latest.
    try std.testing.expect(root1 != root2);
    try std.testing.expect(root2 != root3);
    try std.testing.expectEqual(root3, user_root_phys());
    // The budget line is observable and bounded by the carve-out: kernel
    // root + 3 user roots stay well inside the 512-page budget.
    try std.testing.expect(tables_used() > 0);
    try std.testing.expect(tables_used() <= tables_capacity());
    try std.testing.expect(tables_used() < tables_capacity() / 2); // headroom for the boot-time static payload
}

test "mmu: an aperture above the identity blanket still gets EL0 leaves (issue #1214 review)" {
    reset();
    // The boot identity tree covers only the low 4 GiB blanket, and the
    // host tree is empty — so an aperture above the blanket has NO source
    // slot to clone. The pre-fix builder skipped those slots silently and
    // EL0 reads fell through to demand-filled zero pages (the boot-payload
    // witness spin never saw a preemption). The aperture must be built
    // from an empty source all the way down to the page level.
    const stack_va: u64 = identity_blanket_end + 0x1000_0000; // above the blanket
    const stack_pa: u64 = 0x0000_0000_0500_0000;
    const root = build_user_root(userspace.text_va, 0x1000, 64, stack_va, stack_pa, 3 * 4096).?;
    const stats = walk_leaves(root);
    // text (1 page) + the full 3-page stack aperture.
    try std.testing.expectEqual(@as(usize, 4), stats.el0_leaves);
    const leaf = get_user_leaf(root, stack_va + 4096).?;
    try std.testing.expectEqual(stack_pa + 4096, leaf.* & 0x0000_ffff_ffff_f000);
    try std.testing.expectEqual(@as(u64, 1), (leaf.* >> 6) & 3); // EL0 RW
}

test "mmu: leaf_el0_visible rejects the EL1-only identity overlay (issue #1391)" {
    reset();
    const text_va = userspace.text_va;
    const stack_va: u64 = 0x1a400000;
    const root = build_user_root(text_va, 0x1000, 64, stack_va, 0x2000, 8192).?;
    // The apertures are EL0 leaves: visible.
    try std.testing.expect(leaf_el0_visible(root, text_va));
    try std.testing.expect(leaf_el0_visible(root, stack_va + 4096));
    // A VA the root does not map at all: not visible (the copy path will
    // demand-populate it or refuse, never store).
    try std.testing.expect(!leaf_el0_visible(root, stack_va + 64 * 4096));
    // An EL1-only leaf — exactly the identity overlay's shape (AP = 0b00,
    // here Device, physical == VA) — is NOT a destination the kernel may
    // store into: EL0 could never observe the store.
    const va = stack_va + 4096;
    const leaf = get_user_leaf(root, va).?;
    leaf.* &= ~(@as(u64, 3) << 6);
    try std.testing.expect(!leaf_el0_visible(root, va));
}

test "mmu: user leaves are page-local W^X and reject Device mappings" {
    const pa: u64 = 0x1234_5000;
    const normal = pa | attr_bits(.normal, true);
    const text = user_leaf(normal, false, true).?;
    try std.testing.expectEqual(@as(u64, 3), (text >> 6) & 3); // EL0 RO
    try std.testing.expectEqual(@as(u64, 1), (text >> 53) & 1); // PXN
    try std.testing.expectEqual(@as(u64, 0), (text >> 54) & 1); // EL0 executable
    try std.testing.expectEqual(pa, text & 0x0000_ffff_ffff_f000);

    const stack = user_leaf(normal, true, false).?;
    try std.testing.expectEqual(@as(u64, 1), (stack >> 6) & 3); // EL0 RW
    try std.testing.expectEqual(@as(u64, 1), (stack >> 53) & 1); // PXN
    try std.testing.expectEqual(@as(u64, 1), (stack >> 54) & 1); // UXN
    try std.testing.expectEqual(pa, stack & 0x0000_ffff_ffff_f000);

    const device = pa | attr_bits(.device, true);
    try std.testing.expect(user_leaf(device, false, true) == null);
    try std.testing.expect(user_leaf(normal, true, true) == null);
}

test "mmu: #2096 — malformed apertures fail the build before any leaf is made" {
    reset();
    const phys: u64 = 0x7000_0000;
    // The M97c underflow trigger: va_start mid-page. The L3 leaf math is
    // `phys + (slot_va - va_start)`; with an unaligned start the first
    // intersecting slot sits BELOW va_start, the subtraction wraps, and
    // ReleaseSmall arithmetic silently binds the page UNDER the
    // allocation — EL0 RW. Refused at the door now.
    const unaligned_start = [1]UserAperture{.{ .va_start = 0x40_1001, .va_end = 0x40_3000, .phys = phys, .writable = true, .executable = false }};
    try std.testing.expect(build_user_root_apertures(&unaligned_start) == null);
    // An unaligned physical base fails the same door.
    const unaligned_phys = [1]UserAperture{.{ .va_start = 0x40_0000, .va_end = 0x40_1000, .phys = phys + 1, .writable = true, .executable = false }};
    try std.testing.expect(build_user_root_apertures(&unaligned_phys) == null);
    // Empty and inverted ranges are refused.
    const empty = [1]UserAperture{.{ .va_start = 0x40_0000, .va_end = 0x40_0000, .phys = phys, .writable = false, .executable = true }};
    try std.testing.expect(build_user_root_apertures(&empty) == null);
    const inverted = [1]UserAperture{.{ .va_start = 0x40_1000, .va_end = 0x40_0000, .phys = phys, .writable = false, .executable = true }};
    try std.testing.expect(build_user_root_apertures(&inverted) == null);
    // VA zero (the nil page) is never an aperture.
    const null_page = [1]UserAperture{.{ .va_start = 0, .va_end = 0x1000, .phys = phys, .writable = true, .executable = false }};
    try std.testing.expect(build_user_root_apertures(&null_page) == null);
    // Past the 48-bit TTBR0 space.
    const past_limit = [1]UserAperture{.{ .va_start = user_va_limit - page_size, .va_end = user_va_limit + page_size, .phys = phys, .writable = true, .executable = false }};
    try std.testing.expect(build_user_root_apertures(&past_limit) == null);
    // Two apertures sharing a page — the clone's first-match rule would
    // bind the page to one physical window and corrupt the other.
    const overlap = [2]UserAperture{
        .{ .va_start = 0x40_0000, .va_end = 0x40_0800, .phys = phys, .writable = false, .executable = true },
        .{ .va_start = 0x40_0000, .va_end = 0x40_1000, .phys = phys + 0x10_0000, .writable = true, .executable = false },
    };
    try std.testing.expect(build_user_root_apertures(&overlap) == null);
    // The aligned production shape still builds: text + stack apertures.
    const good = [2]UserAperture{
        .{ .va_start = userspace.text_va, .va_end = userspace.text_va + 0xa52, .phys = phys, .writable = false, .executable = true },
        .{ .va_start = 0x8000_0000, .va_end = 0x8000_0000 + 8192, .phys = phys + 0x10_0000, .writable = true, .executable = false },
    };
    try std.testing.expect(build_user_root_apertures(&good) != null);
}

test "mmu: #2092 — user leaves may not shadow kernel-live identity twins" {
    reset();
    // Fabricate identity leaves the way map_low_identity does: a pooled-RAM
    // page at the VZ pool base (0x7000_0000), a Device hole page at the GIC
    // VA (the mmap band opens here — it MUST stay overlayable), and an
    // above-blanket Device window (a virtio BAR shape).
    _ = new_table(); // identity root at table index 0
    try std.testing.expect(map_page(0x7000_0000, .normal));
    try std.testing.expect(map_page(0x1000_0000, .device));
    const bar_va: u64 = identity_blanket_end + 0x8000_0000;
    try std.testing.expect(map_page(bar_va, .device));

    const user_root = build_user_root(userspace.text_va, 0x1000, 64, 0x1a40_0000, 0x7800_0000, 8192).?;

    // A mmap-hint VA over pooled kernel RAM: refused at the last line, the
    // slot checker, AND the aperture builder — the EL1-only twin survives.
    try std.testing.expect(!map_user_page(user_root, 0x7000_0000, 0x7400_0000, true, false));
    try std.testing.expect(!map_user_cow_page(user_root, 0x7000_0000, 0x7400_0000));
    try std.testing.expect(!user_slot_free(user_root, 0x7000_0000));
    const evil = [1]UserAperture{.{ .va_start = 0x7000_0000, .va_end = 0x7000_1000, .phys = 0x7500_0000, .writable = true, .executable = false }};
    try std.testing.expect(build_user_root_apertures(&evil) == null);
    // The twin leaf is still the EL1-only identity leaf.
    const twin = get_user_leaf(user_root, 0x7000_0000).?;
    try std.testing.expectEqual(@as(u64, 0), (twin.* >> 6) & 3);
    // Unmapping never strips an identity twin either.
    try std.testing.expect(unmap_user_page(user_root, 0x7000_0000) == null);

    // The mmap band's first page (a Device hole below the blanket) is the
    // intended user window — allowed.
    try std.testing.expect(user_slot_free(user_root, 0x1000_0000));
    try std.testing.expect(map_user_page(user_root, 0x1000_0000, 0x7600_0000, true, false));
    // A fresh EL0 leaf is the caller's own page — teardown works.
    try std.testing.expect(unmap_user_page(user_root, 0x1000_0000) != null);

    // An above-blanket device window is kernel-live: refused both ways.
    try std.testing.expect(!user_slot_free(user_root, bar_va));
    try std.testing.expect(!map_user_page(user_root, bar_va, 0x7700_0000, true, false));
    // A VA above the blanket with NO leaf is free — the stack band's shape.
    try std.testing.expect(user_slot_free(user_root, identity_blanket_end + 0x1000_0000));

    // Range check: a clean span passes, a wrapped or oversized span refuses.
    try std.testing.expect(user_range_free(user_root, 0x1a40_0000, 0x2000));
    try std.testing.expect(!user_range_free(user_root, 0x6fff_f000, 0x2000)); // spans into RAM
    try std.testing.expect(!user_range_free(user_root, std.math.maxInt(u64) - 0xfff, 0x2000)); // wraps
    try std.testing.expect(!user_range_free(user_root, 0x1a40_0000, user_va_limit)); // past the VA space
    try std.testing.expect(!user_range_free(user_root, 0x1a40_0800, 0x1000)); // unaligned hint
}

test "mmu: #2116 — free_table_tree returns a dead root's whole subtree to the carve-out" {
    reset();
    // A kernel root + one user root: the baseline the exec churn must return
    // to. Kernel-root refusal: a null and the kernel root itself free nothing.
    const kroot = new_table();
    kernel_root_value = @intFromPtr(kroot);
    defer kernel_root_value = 0;
    _ = build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const baseline = tables_used();
    try std.testing.expect(baseline > 1);

    try std.testing.expectEqual(@as(usize, 0), free_table_tree(0));
    try std.testing.expectEqual(@as(usize, 0), free_table_tree(kernel_root_phys()));
    try std.testing.expectEqual(baseline, tables_used());

    // Sequential exec churn: build a root, free it, repeat — every cycle
    // returns tables_used() to the baseline, and the allocator reuses the
    // reclaimed pages instead of marching toward the 512-page bound.
    const high_water = table_count;
    var cycle: usize = 0;
    while (cycle < 8) : (cycle += 1) {
        const r = build_user_root(userspace.text_va, 0x1000, 64, 0x1a40_0000 + @as(u64, cycle) * 0x10_0000, 0x3000, 8192).?;
        const grown = tables_used();
        try std.testing.expect(grown > baseline);
        const freed = free_table_tree(r);
        try std.testing.expectEqual(grown - baseline, freed);
        try std.testing.expectEqual(baseline, tables_used());
    }
    try std.testing.expect(table_count < high_water + 8 * 32); // reuse, not unbounded growth

    // A partially-built root strands nothing: drain the carve-out to one
    // free slot, so the next build consumes it then fails deeper in the
    // clone — discard_table must return every page the attempt took.
    while (new_table() != null) {}
    try std.testing.expectEqual(tables_capacity(), tables_used());
    free_table(@intFromPtr(&table_storage[table_page_count - 1])); // exactly one slot
    const drained = tables_used();
    try std.testing.expect(build_user_root(userspace.text_va, 0x1000, 64, 0x2100_0000, 0x4000, 8192) == null);
    try std.testing.expectEqual(drained, tables_used()); // nothing stranded
}

pub fn read_mmfr0() u64 {
    var value: u64 = undefined;
    asm volatile ("mrs %[value], id_aa64mmfr0_el1"
        : [value] "=r" (value),
    );
    return value;
}

/// Install the address-space split (claim 5804, VZ fallback): program
/// MAIR/TCR/TTBR0 and switch. The kernel stays identity-mapped in TTBR0
/// (no TTBR1 KVA shadow — VZ's TTBR1 translation is incompatible, see the
/// module doc); TTBR1 is programmed to 0 with T1SZ=25 so no TTBR1 region
/// exists. Per-task isolation comes from switching TTBR0 between the
/// kernel root (EL1h tasks) and the user root (EL0 task — the identity
/// clone + user leaves), which the scheduler does on every switch.
/// See the no-TLBI safety argument below (ADR 0006 / claim 0010) — the
/// TLBI stays unconditional (claim 1517).
pub fn install_identity_map() void {
    const mmfr0 = read_mmfr0();
    var ips: u64 = mmfr0 & 0xf;
    if (ips > 5) ips = 5;
    // Claim 0010 root cause: the freshly-built tables must be cleaned to
    // memory BEFORE the first walk can read them. The kernel writes them as
    // Normal WB stores (dirty in the D-cache only); the first post-switch
    // access walks them, and any D-cache line invalidation without a clean in
    // between (observed: the firmware runtime SetVariable call between the
    // switch and the TLBI drops the dirty lines) leaves stale RAM for the
    // post-TLBI re-walk to fault on. Clean the whole 2 MiB carve-out so the
    // walker always reads the real tables.
    clean_dcache_range(@intFromPtr(&table_storage), table_page_count * 4096);
    // T0SZ selects the TTBR0 VA space size and therefore the initial lookup
    // level of the walk. Production T0SZ=16 (W=48, 2^48 space) starts the 4
    // KiB stage-1 walk at LEVEL 0 — the level the built L0-rooted hierarchy
    // (root -> L1 -> L2 -> optional L3) actually targets, so every fresh
    // walk resolves (claim 1517). The legacy 25 (W=39) starts the walk at
    // LEVEL 1 over the same L0-rooted tables — the claim-6460/7896
    // start-level mismatch: a fresh walk misparses below 1 GiB and faults
    // at ROOT[1..3]=0 for VAs >= 1 GiB (-Dt0sz25 reproduces it). The map
    // builder's va_limit (1 << 39) still bounds every mapped VA (blanket +
    // extra device window sit far below it) under either T0SZ. TG0 (the TTBR0
    // walker's granule) is left 0b00 = 4 KB in
    // BOTH architectural field positions: ARMv8.0 puts TG0 at bits [9:8]
    // (0b01 = 64 KB), ARMv8.1+ with 16 KB granule support puts it at bits
    // [15:14] with IRGN0/ORGN0/SH0 at [9:8]/[11:10]/[13:12]. The tables are
    // 4 KB-granule, so the walker MUST be programmed for 4 KB under whichever
    // revision the CPU implements. (Claim 0010 measured the firmware's own
    // TCR_EL1 on VZ: TG0 at [15:14] = 0b00 — the guest is the ARMv8.1+
    // layout, and the prior `1 << 8` was IRGN0, not TG0; the death persisted
    // with a 4K-correct value, so the granule is defensive rather than the
    // root cause.) IPS is bits [34:32] in both layouts and is taken from
    // ID_AA64MMFR0_EL1 per ADR 0004 D3.
    // T1SZ=25 (no TTBR1 region — TTBR1 is programmed to 0), TG1 stays 0b00
    // (4 KB granule), EPD1=0.
    const tcr: u64 = plan_t0sz | (25 << 16) | (ips << 32);
    const mair: u64 = 0x000000000000ff00; // Attr0 Device-nGnRnE, Attr1 Normal WB.
    const root0 = kernel_root_phys(); // identity root — TTBR0 for the kernel + EL1h tasks
    asm volatile ("dsb ishst" ::: .{ .memory = true });
    asm volatile ("msr mair_el1, %[value]"
        :
        : [value] "r" (mair),
    );
    asm volatile ("msr tcr_el1, %[value]"
        :
        : [value] "r" (tcr),
    );
    asm volatile ("msr ttbr1_el1, %[value]"
        :
        : [value] "r" (0),
    );
    asm volatile ("msr ttbr0_el1, %[value]"
        :
        : [value] "r" (root0),
    );
    asm volatile ("isb");
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb");
    // Claim 1517 (pays the ADR-0006 debt): execute a FULL TLB invalidation
    // at the switch. The old no-TLBI crutch (claim 0010, ADR 0006) survived
    // only by riding stale firmware TLB entries that were identity-compatible
    // below the blanket — but the first post-MMU read of the virtio-pci BAR
    // window (above the blanket, claim 0013) hit an evicted entry, re-walked
    // the L0-rooted tables under the claim-6460 start-level mismatch
    // (T0SZ=25) and faulted (claims 0018/0020). Claims 6460/7896 proved on
    // real VZ hardware that with the corrected start level (T0SZ=16) a
    // forced re-walk RESOLVES and an empty TLB makes the first post-switch
    // access deterministic (cell B: 9/9 boots complete the whole console
    // path vs ~1/3 with the stale entries). The tables are D-cache-cleaned
    // before the switch and the map never changes descriptors post-switch,
    // so the walk after this invalidation is stable; a later milestone that
    // re-maps regions must revisit the ADR-0006 invalidation list.
    asm volatile ("tlbi vmalle1" ::: .{ .memory = true });
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb");
    // Claim 5804 fallback: NO KVA jump — the kernel continues at its
    // identity addresses under TTBR0. TTBR0 belongs to whichever task is
    // current (the scheduler switches it); the identity root stays
    // reachable as `kernel_root_phys()` for the EL1h tasks, and every
    // per-task root carries the EL1-only kernel overlay so the kernel is
    // reachable even under the user root.
}

/// Setup MMU on a secondary CPU core (Milestone 28 SMP, claim 6438).
pub fn setup_secondary_core() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    const mmfr0 = read_mmfr0();
    const ips: u64 = mmfr0 & 0b111;
    const tcr: u64 = plan_t0sz | (25 << 16) | (ips << 32);
    const mair: u64 = 0x000000000000ff00;
    const root0 = kernel_root_phys();

    asm volatile ("dsb ishst" ::: .{ .memory = true });
    asm volatile ("msr mair_el1, %[value]"
        :
        : [value] "r" (mair),
    );
    asm volatile ("msr tcr_el1, %[value]"
        :
        : [value] "r" (tcr),
    );
    asm volatile ("msr ttbr1_el1, %[value]"
        :
        : [value] "r" (@as(u64, 0)),
    );
    asm volatile ("msr ttbr0_el1, %[value]"
        :
        : [value] "r" (root0),
    );
    asm volatile ("isb");
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb");
    asm volatile ("tlbi vmalle1" ::: .{ .memory = true });
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb");

    // Enable MMU and Caches in SCTLR_EL1
    var sctlr: u64 = 0;
    asm volatile ("mrs %[value], sctlr_el1"
        : [value] "=r" (sctlr),
    );
    sctlr |= (1 << 0); // M: MMU enable
    sctlr |= (1 << 2); // C: Data cache enable
    sctlr |= (1 << 12); // I: Instruction cache enable
    sctlr |= (1 << 3); // SA: Stack alignment check
    asm volatile ("msr sctlr_el1, %[value]"
        :
        : [value] "r" (sctlr),
    );
    asm volatile ("isb");
}

// ---------------------------------------------------------------------------
// Claim 5804: TTBR0 switching (scheduler + firmware/runtime-services calls)
// ---------------------------------------------------------------------------

/// Program TTBR0 (a PHYSICAL root address) and invalidate the TLB so the
/// next access re-walks. The kernel root never changes, so the full
/// invalidation is conservative but correct. No-op on host test processes.
pub fn set_ttbr0(root_phys: u64) void {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    asm volatile ("msr ttbr0_el1, %[v]"
        :
        : [v] "r" (root_phys),
    );
    asm volatile ("isb");
    asm volatile ("tlbi vmalle1" ::: .{ .memory = true });
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb");
}

/// The currently programmed TTBR0 (physical root). 0 on host tests.
pub fn current_ttbr0() u64 {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return 0;
    var v: u64 = 0;
    asm volatile ("mrs %[v], ttbr0_el1"
        : [v] "=r" (v),
    );
    return v;
}

/// The currently programmed TTBR1. The install programs it to 0 (no TTBR1
/// region — claim 5804 VZ fallback); the `addrspaces` diagnostic prints it
/// to prove TTBR1 is unused. 0 on host tests.
pub fn read_ttbr1() u64 {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return 0;
    var v: u64 = 0;
    asm volatile ("mrs %[v], ttbr1_el1"
        : [v] "=r" (v),
    );
    return v;
}

/// The currently programmed TCR_EL1 (for the `addrspaces` diagnostic).
pub fn read_tcr() u64 {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return 0;
    var v: u64 = 0;
    asm volatile ("mrs %[v], tcr_el1"
        : [v] "=r" (v),
    );
    return v;
}

/// Run `f` with TTBR0 = `root_phys`, restoring the caller's TTBR0 after.
/// Used by runtime services (which run against identity pointers — the
/// kernel root) from user-task context, and by the uaccess diagnostic
/// (which must read the user root). No-op passthrough on host tests and
/// before the roots are built.
pub fn with_ttbr0(root_phys: u64, comptime f: fn () void) void {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) {
        f();
        return;
    }
    if (!roots_ready) {
        f();
        return;
    }
    const current = current_ttbr0();
    if (current != root_phys) set_ttbr0(root_phys);
    f();
    if (current != root_phys) set_ttbr0(current);
}

/// Run `f` under the kernel (identity) root — the world runtime services
/// run in.
pub fn with_kernel_root(comptime f: fn () void) void {
    with_ttbr0(kernel_root_phys(), f);
}

/// Run `f` under the EL0 task's user root.
pub fn with_user_root(comptime f: fn () void) void {
    with_ttbr0(user_root_phys(), f);
}

// ---------------------------------------------------------------------------
// Claim 5804: user-root leaf inventory (the `addrspaces` diagnostic)
// ---------------------------------------------------------------------------

pub const LeafStats = struct {
    /// Total valid leaves mapped in the root (blocks at L2 + pages at L3).
    leaves: usize = 0,
    /// Leaves with AttrIndex 0 (Device nGnRnE). For the user root these
    /// are the EL1-only MMIO overlay leaves — allowed, since EL0 cannot
    /// reach them.
    device_leaves: usize = 0,
    /// Leaves whose AP bits [7:6] grant EL0 some access (AP != 0b00). For
    /// the user root this must be EXACTLY the text+stack leaves.
    el0_leaves: usize = 0,
    /// EL0-accessible leaves with AttrIndex 0 (Device) — MUST be 0: MMIO
    /// is excluded from EL0 by the EL1-only AP bits on the overlay's
    /// Device leaves.
    el0_device_leaves: usize = 0,
};

/// Count the leaves reachable from a root's PHYSICAL address by recursing
/// only through present table descriptors (bounded by construction: the
/// user root is a clone of the identity tree, ~30 tables). A leaf's
/// AttrIndex is bits [4:2]; 0 is Device (MAIR Attr0) and 1 is Normal WB
/// (MAIR Attr1). AP bits [7:6] = 0b00 is EL1-only (the kernel overlay);
/// anything else grants EL0 some access (the user leaves). Intended for
/// the user root: el0_leaves must be exactly the text+stack leaves and
/// el0_device_leaves must be 0 (MMIO excluded from EL0). Returns zeros
/// before the roots are built / on host tests.
pub fn walk_leaves(root_phys: u64) LeafStats {
    var stats = LeafStats{};
    if (!roots_ready) return stats;
    walk_level(root_phys, 0, &stats);
    return stats;
}

fn walk_level(table_phys: u64, level: u8, stats: *LeafStats) void {
    const table: *const [512]u64 = @ptrFromInt(to_kva(table_phys));
    for (table.*) |desc| {
        if (desc == 0) continue;
        if ((desc & 3) == 3 and level < 3) {
            walk_level(desc & ~@as(u64, 0xfff), level + 1, stats);
        } else if ((desc & 3) == 1 or level == 3) {
            stats.leaves += 1;
            const attr_idx = (desc >> 2) & 7;
            const ap = (desc >> 6) & 3;
            if (attr_idx == 0) stats.device_leaves += 1;
            if (ap != 0) {
                stats.el0_leaves += 1;
                if (attr_idx == 0) stats.el0_device_leaves += 1;
            }
        }
    }
}

test "mmu: map_user_page and unmap_user_page dynamic lifecycle" {
    reset();
    const root = build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const test_va: u64 = 0x0000_0000_1000_0000;
    const test_pa: u64 = 0x0000_0000_0500_0000;

    // Initially unmapped
    try std.testing.expect(get_user_leaf(root, test_va) == null);

    // Map RW page
    const ok = map_user_page(root, test_va, test_pa, true, false);
    try std.testing.expect(ok);

    const leaf_ptr = get_user_leaf(root, test_va).?;
    const leaf = leaf_ptr.*;
    try std.testing.expectEqual(test_pa, leaf & 0x0000_ffff_ffff_f000);
    try std.testing.expectEqual(@as(u64, 1), (leaf >> 6) & 3); // EL0 RW

    // Unmap page
    const unmapped_pa = unmap_user_page(root, test_va).?;
    try std.testing.expectEqual(test_pa, unmapped_pa);
    try std.testing.expect(leaf_ptr.* == 0);
}

test "mmu: map_user_cow_page and set_user_leaf_writable" {
    reset();
    const root = build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const test_va: u64 = 0x0000_0000_1000_4000;
    const test_pa: u64 = 0x0000_0000_0500_4000;

    const ok = map_user_cow_page(root, test_va, test_pa);
    try std.testing.expect(ok);

    const leaf_ptr = get_user_leaf(root, test_va).?;
    try std.testing.expectEqual(@as(u64, 3), (leaf_ptr.* >> 6) & 3); // EL0 RO
    try std.testing.expect((leaf_ptr.* & sw_cow) != 0); // sw_cow set

    // Promote to writable
    set_user_leaf_writable(leaf_ptr, true);
    try std.testing.expectEqual(@as(u64, 1), (leaf_ptr.* >> 6) & 3); // EL0 RW
    try std.testing.expect((leaf_ptr.* & sw_cow) == 0); // sw_cow cleared
}
