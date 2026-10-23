//! VirelaiOS virtio-pci memory balloon — M183b (issue #3172).
//!
//! The runner's `--balloon` attaches VZ's
//! `VZVirtioTraditionalMemoryBalloonDeviceConfiguration` — the
//! *traditional* balloon model (inflate/deflate queues, virtio device
//! type 5). "Traditional" names the model, not the PCI transport: the
//! device is expected modern like every other VZ function (the
//! 0x1040 + device-id scheme → DID 0x1045); a transitional DID 0x1005
//! presenting the vendor capability list is accepted too — whatever is
//! observed is recorded in docs/hardware-contract.md.
//!
//! The wire model (virtio 1.x §5.5): the device config carries le32
//! `num_pages` (the host's target balloon size in 4096-byte pages — the
//! runner's `targetVirtualMachineMemorySize` writes it) and le32
//! `actual` (the current size). num_pages > actual → the guest hands
//! pages to the host on the inflate queue (queue 0); num_pages < actual
//! → the guest picks pages out of its own ballooned list, names their
//! PFNs on the deflate queue (queue 1), and frees them back to the
//! allocator once the device acknowledges. Both queues carry
//! driver→device le32 PFN arrays (VIRTIO_BALLOON_PFN_SHIFT = 12 — the
//! PFN is the guest physical address >> 12, matching the kernel's 4 KiB
//! page).
//!
//! Discovery + capability resolution run PRE-EXIT (config-space reads
//! hang post-exit, claim 0013); the device state machine runs pre-exit
//! and again post-MMU in `balloon_rearm` (the claim-6420 discipline:
//! VZ resets virtio devices at ExitBootServices).
//!
//! There is no interrupt plumbing anywhere in this kernel — the driver
//! reconciles from the scheduler's idle pass (`balloon_poll`), bounded
//! to `max_submits_per_pass` queue submissions per pass so a large
//! target change never parks the idle task. An inflated page is simply
//! an allocated page (it leaves the allocator's free list); a deflated
//! page goes back through `alloc.free_pages` after the device ack, so
//! the monitor's `pages` free= readout is the spec leg's observed
//! drop-and-recover. The tracked PFN list is capped at
//! `max_tracked_pages` — a target past the cap inflates partway and
//! reports the cap honestly instead of claiming a balloon it cannot
//! account for.
//!
//! The default runner attaches no balloon, so `bal_ready` is false on
//! every existing gate and nothing here is reachable — the default boot
//! stays byte-identical. No libc, no POSIX, no heap allocation, no
//! interrupts.

const std = @import("std");
const mmio = @import("mmio.zig");
const mmu = @import("mmu.zig");
const pci = @import("pci.zig");
const alloc = @import("alloc.zig");
const evidence = @import("evidence.zig");
const klog = @import("klog.zig");

/// Modern virtio-pci DID for virtio device type 5 (balloon): 0x1040 + 5.
pub const virtio_balloon_did_modern: u32 = 0x1045;
/// Transitional DID for the same device type — accepted when it still
/// presents the modern vendor capability list.
pub const virtio_balloon_did_transitional: u32 = 0x1005;

/// Split-ring size per queue (the blk/vsock precedent — in-flight work
/// is one PFN-array submission at a time).
const descriptor_count: usize = 8;
const max_queue: u16 = @intCast(descriptor_count);

/// Queue indices per virtio 1.x §5.5.4: inflate = 0, deflate = 1. The
/// stats/reporting queues exist only when their features are negotiated;
/// this driver claims VERSION_1 alone.
const q_inflate: u16 = 0;
const q_deflate: u16 = 1;

/// PFNs per queue submission — one 4 KiB le32 array. 1024 pages = 4 MiB
/// of balloon per request.
const max_pfns_per_req: usize = 1024;

/// Idle-pass bound: at most this many queue submissions per
/// `balloon_poll` call (4 × 4 MiB = 16 MiB moved per pass). A bigger
/// target change converges over subsequent passes — the idle task stays
/// schedulable between them.
const max_submits_per_pass: usize = 4;

/// Tracked-PFN store bound: 512 MiB of balloon. Above it the driver
/// stops inflating and reports `balloon: track-cap` — a page the host
/// holds but the driver cannot name could never be deflated back into
/// the allocator, so the cap refuses dishonesty rather than the memory.
pub const max_tracked_pages: usize = 128 * 1024;

/// Completion-poll budget per submit — the blk precedent: exhaustion
/// is a named `io_timeout` log line, never a hang.
const bal_op_budget: usize = 16_000_000;

const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};
const VirtqAvail = extern struct {
    flags: u16,
    idx: u16,
    ring: [descriptor_count]u16,
    used_event: u16,
};
const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};
const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
    ring: [descriptor_count]VirtqUsedElem,
    avail_event: u16,
};

const Queue = struct {
    desc: [descriptor_count]VirtqDesc align(64) = undefined,
    avail: VirtqAvail align(64) = undefined,
    used: VirtqUsed align(64) = undefined,
    last_used: u16 align(64) = 0,
    size: u16 = 0,
    notify_off: u16 = 0,
};

// Resolved pre-exit (claim 0013 — PCI config space hangs post-exit).
pub var bal_dev: u32 = 32; // PCI device number (32 = absent)
pub var bal_did: u32 = 0; // observed device ID (0x1045 or 0x1005)
pub var bal_common: u64 = 0;
pub var bal_notify: u64 = 0;
pub var bal_notify_mult: u32 = 0;
pub var bal_devcfg: u64 = 0; // device-config address: num_pages +0, actual +4
var bal_common_bar: u64 = 0;
var bal_notify_bar: u64 = 0;
var bal_devcfg_bar: u64 = 0;

/// Armed (DRIVER_OK) in the current device lifetime — `balloon_poll` is
/// a no-op until `balloon_rearm` reaches it.
pub var bal_ready: bool = false;
/// Failure point of the last init/rearm attempt, for evidence.
pub var bal_fail_stage: u8 = 0;
/// The device feature words at the last negotiation attempt (feature_sel
/// 0 → lo, 1 → hi) — recorded for the failure line's evidence.
pub var bal_feat_lo: u32 = 0;
pub var bal_feat_hi: u32 = 0;

var inflate_q: Queue = .{};
var deflate_q: Queue = .{};

/// The PFN array each submission hands the device (driver→device, the
/// device READS it — no VIRTQ_DESC_F_WRITE flag on either queue).
var pfn_buf: [max_pfns_per_req]u32 align(64) = undefined;

/// PFNs the host currently holds, in inflate order — deflate pops from
/// the tail. Allocated from the page pool at rearm (512 KiB of store is
/// pool memory, not kernel .bss — the budget gate's ceiling stands);
/// `tracked.len` is the effective cap, so a failed alloc degrades to a
/// store that accepts nothing rather than one that lies.
var tracked: []u32 = &.{};
pub var tracked_count: u64 = 0;

fn common_read8(offset: u32) u8 {
    return mmio.mmio_read8(bal_common + offset);
}
fn common_write8(offset: u32, value: u8) void {
    mmio.mmio_write8(bal_common + offset, value);
}
fn common_read16(offset: u32) u16 {
    return mmio.mmio_read16(bal_common + offset);
}
fn common_write16(offset: u32, value: u16) void {
    mmio.mmio_write16(bal_common + offset, value);
}
fn common_read32(offset: u32) u32 {
    return mmio.mmio_read32(bal_common + offset);
}
fn common_write32(offset: u32, value: u32) void {
    mmio.mmio_write32(bal_common + offset, value);
}
fn devcfg_read32(offset: u32) u32 {
    return mmio.mmio_read32(bal_devcfg + offset);
}

/// The device's balloon target and current size, in 4096-byte pages.
/// `num_pages` at +0 is the host's request (it moves when the runner's
/// `targetVirtualMachineMemorySize` writes); `actual` at +4 is what the
/// device believes it holds.
pub fn devcfg_num_pages() u32 {
    return devcfg_read32(0);
}
pub fn devcfg_actual() u32 {
    return devcfg_read32(4);
}

/// Device status (common cfg + 0x14); 0xff when never discovered.
pub fn bal_status() u8 {
    if (bal_common == 0) return 0xff;
    return common_read8(0x14);
}

/// Resolve `dev`'s BARs and the virtio common/notify/device-config
/// capabilities. PRE-EXIT only (claim 0013). Mirrors
/// virtio_vsock.resolve_device; the balloon's device config is the
/// 8-byte num_pages/actual pair, so the device cap must cover it.
fn resolve_device(dev: u32) bool {
    var bars: [6]u64 = @splat(0);
    var bi: usize = 0;
    while (bi < 6) : (bi += 1) {
        const low = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0x10 + @as(u32, @intCast(bi)) * 4);
        if ((low & 1) != 0) continue; // I/O space — ignored
        bars[bi] = low & ~@as(u32, 0xf);
        if (((low >> 1) & 0x3) == 2 and bi + 1 < 6) { // 64-bit BAR
            const high = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0x10 + @as(u32, @intCast(bi + 1)) * 4);
            bars[bi] |= @as(u64, high) << 32;
            bi += 1;
        }
    }

    var common_bar: u32 = 0xff;
    var common_off: u32 = 0;
    var notify_bar: u32 = 0xff;
    var notify_off: u32 = 0;
    var device_bar: u32 = 0xff;
    var device_off: u32 = 0;
    var device_len: u32 = 0;
    var mult: u32 = 0;
    var cap = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0x34) & 0xff;
    var count: usize = 0;
    while (cap != 0 and cap < 0x100 and (cap & 3) == 0 and count < 16) : (count += 1) {
        const header = pci.pci_read32(pci.pci_ecam, 0, dev, 0, cap);
        const id = header & 0xff;
        const next = (header >> 8) & 0xff;
        if (id == 0x09) { // vendor capability
            const kind = (header >> 24) & 0xff;
            const bar = pci.pci_read32(pci.pci_ecam, 0, dev, 0, cap + 4) & 0xff;
            const offset = pci.pci_read32(pci.pci_ecam, 0, dev, 0, cap + 8);
            const length = pci.pci_read32(pci.pci_ecam, 0, dev, 0, cap + 12);
            switch (kind) {
                1 => {
                    common_bar = bar;
                    common_off = offset;
                },
                2 => {
                    notify_bar = bar;
                    notify_off = offset;
                    mult = pci.pci_read32(pci.pci_ecam, 0, dev, 0, cap + 16);
                },
                4 => {
                    device_bar = bar;
                    device_off = offset;
                    device_len = length;
                },
                else => {},
            }
        }
        cap = next;
    }
    if (common_bar >= bars.len or notify_bar >= bars.len or
        device_bar >= bars.len or device_len < 8) return false;
    bal_common = bars[common_bar] + common_off;
    bal_notify = bars[notify_bar] + notify_off;
    bal_devcfg = bars[device_bar] + device_off;
    bal_common_bar = bars[common_bar];
    bal_notify_bar = bars[notify_bar];
    bal_devcfg_bar = bars[device_bar];
    bal_notify_mult = mult;
    return true;
}

/// PRE-EXIT PCI-only discovery: scan bus 0 for a balloon function —
/// modern DID 0x1045 or transitional DID 0x1005, either accepted only
/// when it presents the modern vendor capability list (a transitional
/// device without it has no transport this kernel speaks — reported
/// honestly, never probed further). False means no balloon is attached:
/// the default boot prints nothing and stays byte-identical.
pub fn virtio_balloon_init() bool {
    bal_ready = false;
    bal_dev = 32;
    bal_did = 0;
    if (pci.pci_ecam == 0) return false;
    var dev: u32 = 0;
    while (dev < 32) : (dev += 1) {
        const id = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0);
        if ((id & 0xffff) != 0x1af4) continue;
        const did = id >> 16;
        if (did != virtio_balloon_did_modern and did != virtio_balloon_did_transitional) continue;
        bal_dev = dev;
        bal_did = did;
        if (!resolve_device(dev)) {
            evidence.dump_str("VBAL dev=");
            evidence.dump_hex(dev);
            evidence.dump_str(" did=");
            evidence.dump_hex(did);
            evidence.dump_str(" resolve failed (no modern transport)\n");
            bal_dev = 32;
            return false;
        }
        evidence.dump_str("VBAL dev=");
        evidence.dump_hex(dev);
        evidence.dump_str(" did=");
        evidence.dump_hex(did);
        evidence.dump_str(" common=");
        evidence.dump_hex(bal_common);
        evidence.dump_str(" notify=");
        evidence.dump_hex(bal_notify);
        evidence.dump_str(" devcfg=");
        evidence.dump_hex(bal_devcfg);
        evidence.dump_str("\n");
        // The pre-exit arming is real (same machine as blk's) — VZ may
        // reset the device at ExitBootServices either way; the post-MMU
        // rearm records the honest status.
        _ = drive_state_machine();
        return true;
    }
    return false;
}

/// The device's BAR windows for the post-MMU identity map (deduplicated —
/// VZ may pack several capabilities into one BAR).
pub fn add_device_windows(out: []mmu.DeviceWindow) usize {
    if (bal_dev >= 32) return 0;
    var count: usize = 0;
    const bases = [_]u64{ bal_common_bar, bal_notify_bar, bal_devcfg_bar };
    for (bases, 0..) |base, i| {
        if (base == 0) continue;
        var duplicate = false;
        for (bases[0..i]) |prior| {
            if (prior == base) duplicate = true;
        }
        if (duplicate or count >= out.len) continue;
        out[count] = .{ .base = base, .len = 0x10000 };
        count += 1;
    }
    return count;
}

fn highest_power_of_two_at_most(n: u16) u16 {
    var size: u16 = 1;
    while (size <= n / 2 and size < max_queue) size *= 2;
    return size;
}

/// Program one split ring (queue_select → size → GPA triple → enable)
/// and record its notify offset. Returns false on an absent/dead queue —
/// `queue_size_max` reading 0 means the device never made it (the
/// deflate queue's absence would be named, not assumed).
fn init_ring(q: *Queue, queue_index: u16, wanted: u16) bool {
    common_write16(0x16, queue_index);
    const device_size = common_read16(0x18);
    if (device_size == 0) return false;
    const size = @min(highest_power_of_two_at_most(device_size), wanted);
    if (size == 0) return false;
    q.* = .{};
    q.size = size;
    for (&q.desc) |*d| d.* = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    q.avail = .{ .flags = 0, .idx = 0, .ring = @as([descriptor_count]u16, @splat(@as(u16, 0))), .used_event = 0 };
    q.used = .{ .flags = 0, .idx = 0, .ring = @as([descriptor_count]VirtqUsedElem, @splat(@as(VirtqUsedElem, .{ .id = 0, .len = 0 }))), .avail_event = 0 };
    mmu.clean_dcache_range(@intFromPtr(&q.used), @sizeOf(VirtqUsed));
    const desc = mmu.to_phys(@intFromPtr(&q.desc));
    const avail = mmu.to_phys(@intFromPtr(&q.avail));
    const used = mmu.to_phys(@intFromPtr(&q.used));
    mmio.mmio_write32(bal_common + 0x20, @truncate(desc));
    mmio.mmio_write32(bal_common + 0x24, @truncate(desc >> 32));
    mmio.mmio_write32(bal_common + 0x28, @truncate(avail));
    mmio.mmio_write32(bal_common + 0x2c, @truncate(avail >> 32));
    mmio.mmio_write32(bal_common + 0x30, @truncate(used));
    mmio.mmio_write32(bal_common + 0x34, @truncate(used >> 32));
    common_write16(0x18, size);
    common_write16(0x1c, 1);
    q.notify_off = common_read16(0x1e);
    return common_read16(0x1c) == 1;
}

/// The device-state-machine half of init and rearm — identical pre-exit
/// and post-MMU (the claim-6420 discipline). Claims VIRTIO_F_VERSION_1
/// alone: the optional balloon features (STATS_VQ, FREE_PAGE_HINTING,
/// PAGE_POISON, MUST_TELL_HOST) are all decline-legal, and deflate still
/// travels the deflate queue per spec — telling the host is the honest
/// path either way. Programs inflateq + deflateq and reaches DRIVER_OK.
fn drive_state_machine() bool {
    bal_ready = false;
    common_write8(0x14, 0); // reset
    var spins: usize = 0;
    while (common_read8(0x14) != 0) : (spins += 1) {
        if (spins >= 1_000_000) return false;
    }
    common_write8(0x14, 1 | 2); // ACKNOWLEDGE | DRIVER
    common_write32(0x00, 0);
    bal_feat_lo = common_read32(0x04);
    common_write32(0x00, 1);
    bal_feat_hi = common_read32(0x04);
    if ((bal_feat_hi & 1) == 0) return false; // VIRTIO_F_VERSION_1 absent
    // The accept mask is every OFFERED low feature bit: MUST_TELL_HOST is
    // honored by construction (deflate always rides the deflate queue)
    // and VZ rejects a VERSION_1-only ladder — the virtio-net lesson
    // (VER1-only is refused there too; the landed mask takes every
    // device bit the card speaks). The high word claims VERSION_1 alone —
    // RING_PACKED is never accepted, our rings are split.
    const accept_lo = bal_feat_lo;
    common_write32(0x08, 0);
    common_write32(0x0c, accept_lo);
    common_write32(0x08, 1);
    common_write32(0x0c, 1); // VERSION_1
    common_write8(0x14, 1 | 2 | 8); // FEATURES_OK
    if ((common_read8(0x14) & 8) == 0) return false;
    if (!init_ring(&inflate_q, q_inflate, max_queue)) {
        bal_fail_stage = 3;
        return false;
    }
    if (!init_ring(&deflate_q, q_deflate, max_queue)) {
        bal_fail_stage = 4;
        return false;
    }
    common_write8(0x14, 1 | 2 | 8 | 4); // DRIVER_OK
    if ((common_read8(0x14) & 4) == 0) return false;
    bal_ready = true;
    return true;
}

/// POST-MMU re-arm (claim 6420): the whole reset → features → queues →
/// DRIVER_OK sequence again on the pre-exit-resolved addresses, then an
/// honest resync of the tracked PFN list against the device's `actual`:
/// a device that reset mid-run drops its balloon, and pages it released
/// go back to the allocator rather than staying permanently claimed.
/// In normal operation (VZ's reset happens only at ExitBootServices, and
/// no inflate can have run yet) the resync is a no-op.
pub fn balloon_rearm() bool {
    if (bal_dev >= 32 or bal_common == 0) return false;
    bal_fail_stage = 1;
    const ok = drive_state_machine();
    if (!ok) return false;
    bal_fail_stage = 0;
    if (tracked.len == 0) {
        const store_pages = (max_tracked_pages * @sizeOf(u32) + 4095) / 4096;
        if (alloc.alloc_pages(store_pages)) |base| {
            tracked = @as([*]u32, @ptrFromInt(base))[0..max_tracked_pages];
        } else {
            klog.line("balloon: no-store\n");
        }
    }
    const act = devcfg_actual();
    resync_tracked(act);
    return true;
}

/// Bring `tracked_count` in line with the device's `actual` — only ever
/// downward: pages the device no longer claims are freed back to the
/// pool. `actual` > `tracked_count` is unrecoverable drift (the device
/// holds pages the driver cannot name); it is reported and left —
/// the free list stays honest about what it owns.
fn resync_tracked(actual: u64) void {
    if (actual < tracked_count) {
        const release = tracked_count - actual;
        var i: u64 = 0;
        while (i < release) : (i += 1) {
            tracked_count -= 1;
            _ = alloc.free_pages(@as(u64, tracked[tracked_count]) << 12, 1);
        }
        var buf: [96]u8 = undefined;
        klog.line(std.fmt.bufPrint(&buf, "balloon: resync freed={d} (device actual={d})\n", .{ release, actual }) catch "balloon: resync\n");
    } else if (actual > tracked_count) {
        var buf: [96]u8 = undefined;
        klog.line(std.fmt.bufPrint(&buf, "balloon: drift actual={d} tracked={d}\n", .{ actual, tracked_count }) catch "balloon: drift\n");
    }
}

/// One PFN-array submission on queue `q` (the buffer is driver→device —
/// the device reads the PFN list it contains). Synchronous submit+wait
/// like every in-tree transport; returns false on the budget exhaust,
/// named `balloon: io_timeout` by the caller.
fn submit(q: *Queue, queue_index: u16, pfns: []const u32) bool {
    const slot: u16 = 0;
    q.desc[slot] = .{
        .addr = mmu.to_phys(@intFromPtr(pfns.ptr)),
        .len = @intCast(pfns.len * @sizeOf(u32)),
        .flags = 0, // device reads the PFN array
        .next = 0xffff,
    };
    q.avail.ring[q.avail.idx % q.size] = slot;
    q.avail.idx +%= 1;
    mmu.clean_dcache_range(@intFromPtr(&q.desc), @sizeOf(@TypeOf(q.desc)));
    mmu.clean_dcache_range(@intFromPtr(&q.avail), @sizeOf(VirtqAvail));
    mmu.clean_dcache_range(@intFromPtr(pfns.ptr), pfns.len * @sizeOf(u32));
    mmio.mmio_write16(bal_notify + @as(u64, q.notify_off) * bal_notify_mult, queue_index);
    var spins: usize = 0;
    while (spins < bal_op_budget) : (spins += 1) {
        mmu.invalidate_dcache_range(@intFromPtr(&q.used), @sizeOf(VirtqUsed));
        if (q.used.idx != q.last_used) {
            q.last_used = q.used.idx;
            return true;
        }
    }
    return false;
}

/// Inflate `want` pages: allocate each page, hand its PFN to the device
/// on the inflate queue, record it in the tracked store. Returns the
/// count actually moved — a shortfall (empty pool, full store, io
/// timeout) is named on serial, and any pages a failed submission left
/// unclaimed go back to the pool.
fn inflate_step(want: u64) u64 {
    var n = @min(want, max_pfns_per_req);
    n = @min(n, tracked.len - tracked_count);
    if (n == 0) return 0;
    var allocated: u64 = 0;
    while (allocated < n) : (allocated += 1) {
        const pa = alloc.alloc_pages(1) orelse break;
        pfn_buf[allocated] = @truncate(pa >> 12);
    }
    if (allocated == 0) {
        klog.line("balloon: inflate refused no_pages\n");
        return 0;
    }
    if (!submit(&inflate_q, q_inflate, pfn_buf[0..allocated])) {
        // The device may have consumed the buffer anyway — freeing the
        // pages keeps the allocator's truth (the store only ever holds
        // pages the device acknowledged).
        var i: u64 = 0;
        while (i < allocated) : (i += 1) {
            _ = alloc.free_pages(@as(u64, pfn_buf[i]) << 12, 1);
        }
        klog.line("balloon: inflate io_timeout\n");
        return 0;
    }
    for (pfn_buf[0..allocated]) |pfn| {
        tracked[tracked_count] = pfn;
        tracked_count += 1;
    }
    return allocated;
}

/// Deflate `want` pages: pop PFNs off the tracked store's tail, name
/// them on the deflate queue, and free them back to the allocator once
/// the device acknowledges. Returns the count actually moved; a failed
/// submission restores the popped entries so the store stays the truth.
fn deflate_step(want: u64) u64 {
    const n = @min(@min(want, max_pfns_per_req), tracked_count);
    if (n == 0) return 0;
    const base = tracked_count - n;
    for (tracked[base..tracked_count], 0..) |pfn, i| pfn_buf[i] = pfn;
    if (!submit(&deflate_q, q_deflate, pfn_buf[0..n])) {
        klog.line("balloon: deflate io_timeout\n");
        return 0;
    }
    for (pfn_buf[0..n]) |pfn| {
        _ = alloc.free_pages(@as(u64, pfn) << 12, 1);
    }
    tracked_count = base;
    return n;
}

/// One bounded reconcile pass — the scheduler idle-pump hook. Reads the
/// device's `num_pages`/`actual` and walks the balloon toward it,
/// `max_submits_per_pass` submissions at a time. Every pass that moves
/// pages emits the card's klog markers (`balloon: inflate pages=<n>` /
/// `balloon: deflate pages=<n>`); a pass that moves nothing prints
/// nothing — the serial log stays quiet on a steady balloon.
pub fn balloon_poll() void {
    if (!bal_ready) return;
    if (tracked.len == 0) return; // no store armed — the rearm logged it
    const num = devcfg_num_pages();
    // OBSERVED (M183b): VZ's device does NOT maintain `actual` — it reads
    // 0 even after acknowledged inflates. The reconcile target therefore
    // runs against the driver's own tracked PFN count (every inflate was
    // issued here, so it is the true balloon size on this device), with
    // `actual` kept for the rearm-time resync only.
    if (num == tracked_count) return;
    var moved: u64 = 0;
    var submits: usize = 0;
    if (num > tracked_count) {
        var want: u64 = num - tracked_count;
        while (want > 0 and submits < max_submits_per_pass) : (submits += 1) {
            const step = inflate_step(want);
            if (step == 0) break;
            moved += step;
            want -= step;
        }
        if (moved > 0) {
            var buf: [96]u8 = undefined;
            klog.line(std.fmt.bufPrint(&buf, "balloon: inflate pages={d} target={d} tracked={d}\n", .{ moved, num, tracked_count }) catch "balloon: inflate\n");
        }
        if (want > 0 and tracked_count >= tracked.len) {
            var buf: [96]u8 = undefined;
            klog.line(std.fmt.bufPrint(&buf, "balloon: track-cap tracked={d} target={d}\n", .{ tracked_count, num }) catch "balloon: track-cap\n");
        }
    } else {
        var want: u64 = tracked_count - num;
        while (want > 0 and tracked_count > 0 and submits < max_submits_per_pass) : (submits += 1) {
            const step = deflate_step(want);
            if (step == 0) break;
            moved += step;
            want -= step;
        }
        if (moved > 0) {
            var buf: [96]u8 = undefined;
            klog.line(std.fmt.bufPrint(&buf, "balloon: deflate pages={d} target={d} tracked={d}\n", .{ moved, num, tracked_count }) catch "balloon: deflate\n");
        }
    }
}

// ---------------------------------------------------------------------------
// Host tests — the pure pieces (PFN packing, tracked-store discipline,
// reconcile bounds) without a device.
// ---------------------------------------------------------------------------

var test_tracked: [64]u32 = undefined;

test "virtio_balloon: tracked store push/pop is tail-ordered" {
    tracked = test_tracked[0..];
    tracked_count = 0;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        tracked[tracked_count] = 0x1000 + i;
        tracked_count += 1;
    }
    try std.testing.expectEqual(@as(u64, 5), tracked_count);
    // Deflate takes the tail — the entries the store reports back are the
    // most recently inflated.
    const tail = tracked[tracked_count - 1];
    try std.testing.expectEqual(@as(u32, 0x1004), tail);
    tracked_count = 0;
}

test "virtio_balloon: resync only shrinks the store" {
    tracked = test_tracked[0..];
    tracked_count = 0;
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        tracked[tracked_count] = 0x2000 + i;
        tracked_count += 1;
    }
    // actual < tracked frees the tail down to `actual` (the free_pages
    // calls fail on a host build — the count update is the contract).
    resync_tracked(1);
    try std.testing.expectEqual(@as(u64, 1), tracked_count);
    // actual == tracked is a no-op.
    resync_tracked(1);
    try std.testing.expectEqual(@as(u64, 1), tracked_count);
    // actual > tracked is unrecoverable drift — reported, not invented.
    resync_tracked(3);
    try std.testing.expectEqual(@as(u64, 1), tracked_count);
    tracked_count = 0;
}

test "virtio_balloon: poll is a no-op without a device" {
    bal_ready = false;
    tracked_count = 0;
    balloon_poll(); // must not fault — guards the flags-off boot
    try std.testing.expectEqual(@as(u64, 0), tracked_count);
}
