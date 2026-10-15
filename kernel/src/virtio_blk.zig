//! VirelaiOS virtio-pci block transport — M100b (issue #2307), clean-slated
//! per ADR 0050 (not resurrected from the FAT-era driver deleted in M34 HF6
//! `0a8104f7`; that history supplied the transport shape only — the ordering
//! contract here is the ADR's).
//!
//! Every boot has ONE virtio-blk function already — the runner's boot image
//! (`config.storageDevices`'s first element, a modern virtio-pci device,
//! VID 0x1af4, DID 0x1042 — claim 6420's observation). The runner's
//! `--data-disk <img>` (ADR 0050 D1/D2) attaches a SECOND function of the
//! same DID whose `blockDeviceIdentifier` is the fixed string
//! `virelai-vlfs`. Identity is therefore wired, never positional: PCI slot
//! order is documented nowhere and the boot ESP must be unwritable by
//! construction.
//!
//! The claim-0013 discipline: PCI config-space reads + capability walks run
//! PRE-EXIT (post-exit ECAM reads hang on VZ). `virtio_blk_init` collects
//! every DID-0x1042 function, resolves each one's common/notify/device-
//! config capability addresses + BAR window, and runs the full modern
//! feature/queue init. Post-MMU `blk_rearm` repeats the device state
//! machine (the claim-6420 lesson: VZ resets virtio devices at
//! ExitBootServices) and `blk_identify` issues VIRTIO_BLK_T_GET_ID to every
//! candidate — the one answering `virelai-vlfs` is the data disk. Every
//! other blk function is refused for writes by name (`not_vlfs_disk`) and
//! gets no requests in normal operation; a failed/absent match is `no_disk`
//! and the boot proceeds share-only.
//!
//! Requests are the three-descriptor chain virtio-blk §5.2.6.2 requires
//! (header device-reads / data device-reads-or-writes / status byte
//! device-writes); VIRTIO_BLK_T_FLUSH (when VIRTIO_F_FLUSH negotiated) is
//! a two-descriptor header+status request. I/O is polled like every in-tree
//! transport (`io_timeout` after `blk_op_budget` polls, never a hang);
//! device status bytes other than VIRTIO_BLK_S_OK refuse `io_error` and
//! UNSUPP on GET_ID is a `no_disk` signal. In-flight is bounded at ONE
//! request by construction (synchronous submit+wait) — inside the ADR's
//! ≤8 driver-descriptor bound — because the D4 journal contract is
//! synchronous anyway: FLUSH is submitted only after the prior request's
//! completion, so a completed flush is a real barrier, not a hint.
//!
//! Cache correctness mirrors the console/entropy drivers: clean the
//! driver-written rings + buffers before the kick, invalidate the used
//! ring before polling, invalidate device-written buffers after.
//!
//! No libc, no POSIX, no allocation, no interrupts.

const std = @import("std");
const builtin = @import("builtin");
const mmio = @import("mmio.zig");
const mmu = @import("mmu.zig");
const pci = @import("pci.zig");
const evidence = @import("evidence.zig");

const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};
const VirtqAvail = extern struct {
    flags: u16,
    idx: u16,
    ring: [queue_size]u16,
};
const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};
const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
    ring: [queue_size]VirtqUsedElem,
};

/// Split-ring size: 8 (power of two, Virtio 1.3 §4.1.4.3) — the ADR 0050 D7
/// "in-flight device requests ≤ 8" descriptor bound. The driver keeps ONE
/// request outstanding (synchronous submit+wait), so the §2.7 ring
/// invariant holds trivially.
pub const queue_size: u16 = 8;
const desc_header: u16 = 0;
const desc_data: u16 = 1;
const desc_status: u16 = 2;

const virtq_f_write: u16 = 0x2; // VIRTQ_DESC_F_WRITE
const virtq_f_next: u16 = 0x1; // VIRTQ_DESC_F_NEXT

/// Completion-poll budget per wait — ADR 0050 D4's `blk_op_budget` (the
/// cv_log_budget precedent): exhaustion refuses `io_timeout`, never a hang.
/// One retry absorbs a host-side latency spike on a still-in-flight request
/// (the old driver's drain-and-reissue lesson); a dead device fails after
/// the second budget.
const blk_op_budget: usize = 16_000_000;
const poll_retries: usize = 2;

// Request type codes (virtio-blk §5.2.6.1).
const req_in: u32 = 0; // VIRTIO_BLK_T_IN
const req_out: u32 = 1; // VIRTIO_BLK_T_OUT
const req_flush: u32 = 4; // VIRTIO_BLK_T_FLUSH
const req_get_id: u32 = 8; // VIRTIO_BLK_T_GET_ID

// Device status bytes (virtio-blk §5.2.6.2).
const s_ok: u8 = 0; // VIRTIO_BLK_S_OK
const s_ioerr: u8 = 1; // VIRTIO_BLK_S_IOERR
const s_unsupp: u8 = 2; // VIRTIO_BLK_S_UNSUPP

// Device feature bits (virtio-blk §5.2.3 + virtio §6 reserved bits).
const f_ro: u64 = 1 << 5; // VIRTIO_BLK_F_RO
const f_flush: u64 = 1 << 9; // VIRTIO_BLK_F_FLUSH
const f_version_1: u64 = @as(u64, 1) << 32; // VIRTIO_F_VERSION_1

/// The fixed `blockDeviceIdentifier` the runner sets on the data disk
/// (ADR 0050 D1; 12 ASCII bytes, inside VZ's 20-byte limit).
pub const vlfs_disk_id = "virelai-vlfs";

/// Sector size the device speaks (VZ raw-image constraint, ADR D3).
pub const sector_len: usize = 512;
/// GET_ID's device-written buffer is 20 bytes (VIRTIO_BLK_ID_BYTES).
pub const id_len_max: usize = 20;

/// How many DID-0x1042 functions the scan keeps: the boot disk plus the
/// data disk is two; four leaves headroom without an unbounded table.
pub const max_functions: usize = 4;

/// Named refusals (ADR 0050's set, plus the two honest driver-level ones):
/// every failure path names its reason — never a hang, never errno soup.
pub const BlkError = error{
    no_disk, // no function identified as the VLFS data disk
    not_vlfs_disk, // request targeted a blk function that is not the VLFS disk
    not_armed, // transport never initialized / re-arm failed
    io_error, // device reported a non-OK status byte
    io_timeout, // completion poll budget exhausted
    bad_lba, // sector number outside the device capacity
    no_capacity, // device-config capability absent or capacity zero
    no_flush, // VIRTIO_F_FLUSH not negotiated — a flush would be a lie
    read_only_partition, // VIRTIO_BLK_F_RO device — the ADR's name for it
};

/// One request's buffers: 16-byte header + 512-byte data + status byte.
/// The three descriptors point into this single aligned block; GET_ID uses
/// the first 20 bytes of `data`, FLUSH uses no data descriptor at all.
const Request = struct {
    header: extern struct {
        type: u32,
        reserved: u32,
        sector: u64,
    },
    data: [sector_len]u8,
    status: u8,
};

/// One DID-0x1042 function's resolved transport state. Discovery fields are
/// filled pre-exit; `armed`/`flush_ok`/`id`/`capacity` are post-rearm.
pub const Function = struct {
    dev: u32 = 0, // PCI device number (bus 0, func 0)
    common: u64 = 0, // common-config address (BAR + cap offset)
    notify: u64 = 0, // notify region base (BAR + cap offset)
    notify_mult: u32 = 0, // notify_off_multiplier
    devcfg: u64 = 0, // device-config address (BAR + cap offset), 0 = absent
    win0: u64 = 0, // BAR bases carrying common/notify/devcfg (deduped by
    win1: u64 = 0, // add_device_windows for the post-MMU identity map)
    win2: u64 = 0,
    queue_notify_off: u16 = 0,
    armed: bool = false, // reached DRIVER_OK in the current device lifetime
    flush_ok: bool = false, // VIRTIO_F_FLUSH negotiated
    read_only: bool = false, // VIRTIO_BLK_F_RO offered
    id_answered: bool = false, // GET_ID completed with S_OK
    id: [id_len_max]u8 = @splat(0), // GET_ID bytes
    id_len: usize = 0, // bytes the device claimed it wrote
    capacity: u64 = 0, // sectors (device-config +0), 0 = unread/absent
    last_used: u16 = 0, // used-ring poll cursor
};

pub var functions: [max_functions]Function = @splat(.{});
pub var function_count: usize = 0;
/// Index into `functions` of the identified VLFS data disk, or null when
/// GET_ID matched nothing (no_disk territory: boot continues share-only).
pub var vlfs_disk: ?usize = null;

// Per-function ring storage (static BSS — no allocation). The descriptor
// table is the full queue_size so the ring invariant is honest, not just
// "the first three entries happened to fit".
var qdesc: [max_functions][queue_size]VirtqDesc align(16) = undefined;
var qavail: [max_functions]VirtqAvail align(2) = undefined;
var qused: [max_functions]VirtqUsed align(4) = undefined;
var qreq: [max_functions]Request align(512) = undefined;

fn cfg_read8(f: *const Function, off: u32) u8 {
    return mmio.mmio_read8(f.common + off);
}
fn cfg_read16(f: *const Function, off: u32) u16 {
    return mmio.mmio_read16(f.common + off);
}
fn cfg_read32(f: *const Function, off: u32) u32 {
    return mmio.mmio_read32(f.common + off);
}
fn cfg_write8(f: *const Function, off: u32, value: u8) void {
    mmio.mmio_write8(f.common + off, value);
}
fn cfg_write16(f: *const Function, off: u32, value: u16) void {
    mmio.mmio_write16(f.common + off, value);
}
fn cfg_write32(f: *const Function, off: u32, value: u32) void {
    mmio.mmio_write32(f.common + off, value);
}

/// Resolve one function's BAR bases + virtio capability addresses
/// (common cfg 1 / notify 2 / device cfg 4). Returns false when the
/// required caps are missing. PRE-EXIT only (claim 0013).
fn resolve_dev(dev: u32, f: *Function) bool {
    var bar_base: [6]u64 = @splat(0);
    var bi: usize = 0;
    while (bi < 6) : (bi += 1) {
        const low = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0x10 + @as(u32, @intCast(bi)) * 4);
        if ((low & 1) != 0) continue; // I/O space — ignored
        bar_base[bi] = low & ~@as(u32, 0xf);
        if (((low >> 1) & 0x3) == 2 and bi + 1 < 6) { // 64-bit BAR
            const high = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0x10 + @as(u32, @intCast(bi + 1)) * 4);
            bar_base[bi] |= @as(u64, high) << 32;
            bi += 1;
        }
    }
    const cap_ptr = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0x34) & 0xff;
    var common_bar: u32 = 6;
    var common_off: u32 = 0;
    var notify_bar: u32 = 6;
    var notify_off: u32 = 0;
    var notify_mult: u32 = 0;
    var devcfg_bar: u32 = 6;
    var devcfg_off: u32 = 0;
    var c: u32 = cap_ptr;
    var caps: usize = 0;
    while (c != 0 and c < 0x100 and (c & 3) == 0 and caps < 16) : (caps += 1) {
        const head = pci.pci_read32(pci.pci_ecam, 0, dev, 0, c);
        const id = head & 0xff;
        const next = (head >> 8) & 0xff;
        if (id == 0x09) { // vendor capability
            const cfg_type = (head >> 24) & 0xff;
            const bar = pci.pci_read32(pci.pci_ecam, 0, dev, 0, c + 4) & 0xff;
            const off = pci.pci_read32(pci.pci_ecam, 0, dev, 0, c + 8);
            switch (cfg_type) {
                1 => {
                    common_bar = bar;
                    common_off = off;
                },
                2 => {
                    notify_bar = bar;
                    notify_off = off;
                    notify_mult = pci.pci_read32(pci.pci_ecam, 0, dev, 0, c + 16);
                },
                4 => {
                    devcfg_bar = bar;
                    devcfg_off = off;
                },
                else => {},
            }
        }
        c = next;
    }
    if (common_bar >= 6 or notify_bar >= 6) return false;
    f.dev = dev;
    f.common = bar_base[common_bar] + common_off;
    f.notify = bar_base[notify_bar] + notify_off;
    f.notify_mult = notify_mult;
    f.devcfg = if (devcfg_bar < 6) bar_base[devcfg_bar] + devcfg_off else 0;
    f.win0 = bar_base[common_bar];
    f.win1 = bar_base[notify_bar];
    f.win2 = if (devcfg_bar < 6) bar_base[devcfg_bar] else 0;
    return true;
}

/// The device windows main.zig hands to the post-MMU identity map:
/// every distinct BAR base carrying a capability, deduped (VZ tends to
/// share BAR0 across all three — the old driver's single window).
pub fn add_device_windows(out: []mmu.DeviceWindow) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < function_count) : (i += 1) {
        const f = &functions[i];
        const bases = [_]u64{ f.win0, f.win1, f.win2 };
        for (bases, 0..) |base, j| {
            if (base == 0) continue;
            var duplicate = false;
            for (bases[0..j]) |prior| {
                if (prior == base) duplicate = true;
            }
            var k: usize = 0;
            while (k < count) : (k += 1) {
                if (out[k].base == base) duplicate = true;
            }
            if (duplicate or count >= out.len) continue;
            out[count] = .{ .base = base, .len = 0x10000 };
            count += 1;
        }
    }
    return count;
}

/// The device-state-machine half of init/rearm: reset → ACKNOWLEDGE|DRIVER
/// → read offered features → accept VERSION_1 plus F_FLUSH only when
/// offered (a flush the device never promised is a lie, so `flush_ok`
/// records the honest answer) → FEATURES_OK → queue 0 setup → queue_enable
/// → DRIVER_OK. Identical pre-exit and post-exit (claim 6420's re-arm).
fn drive_state_machine(idx: usize) bool {
    const f = &functions[idx];
    cfg_write8(f, 0x14, 0); // reset
    var spins: usize = 0;
    while (cfg_read8(f, 0x14) != 0) : (spins += 1) {
        if (spins >= 1_000_000) return false;
    }
    cfg_write8(f, 0x14, 1 | 2); // ACKNOWLEDGE | DRIVER
    cfg_write32(f, 0x00, 0);
    const feats_lo = cfg_read32(f, 0x04);
    cfg_write32(f, 0x00, 1);
    const feats_hi = cfg_read32(f, 0x04);
    const offered = @as(u64, feats_hi) << 32 | feats_lo;
    if ((offered & f_version_1) == 0) return false; // modern-only device
    f.flush_ok = (offered & f_flush) != 0;
    f.read_only = (offered & f_ro) != 0;
    const accept: u64 = f_version_1 | (if (f.flush_ok) f_flush else 0);
    cfg_write32(f, 0x08, 0);
    cfg_write32(f, 0x0c, @truncate(accept));
    cfg_write32(f, 0x08, 1);
    cfg_write32(f, 0x0c, @truncate(accept >> 32));
    cfg_write8(f, 0x14, 1 | 2 | 8); // FEATURES_OK
    if ((cfg_read8(f, 0x14) & 8) == 0) return false;
    cfg_write16(f, 0x16, 0); // queue_select = 0
    if (cfg_read16(f, 0x18) < queue_size) return false;
    cfg_write16(f, 0x18, queue_size);
    const desc = &qdesc[idx];
    const avail = &qavail[idx];
    const used = &qused[idx];
    for (desc) |*d| d.* = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    avail.* = .{ .flags = 0, .idx = 0, .ring = @splat(0) };
    for (&used.ring) |*e| e.* = .{ .id = 0, .len = 0 };
    used.flags = 0;
    used.idx = 0;
    // Clean the used ring's init write to RAM (BSS is not trusted zeroed;
    // the poll would otherwise re-read stale garbage — claim 0013).
    mmu.clean_dcache_range(@intFromPtr(used), @sizeOf(VirtqUsed));
    f.last_used = 0;
    // Queue GPAs are guest PHYSICAL addresses (claim 5804): translate the
    // kernel VAs. VZ's common-cfg emulation takes 32-bit halves (claim 0013).
    const qd = mmu.to_phys(@intFromPtr(desc));
    cfg_write32(f, 0x20, @truncate(qd));
    cfg_write32(f, 0x24, @truncate(qd >> 32));
    const qa = mmu.to_phys(@intFromPtr(avail));
    cfg_write32(f, 0x28, @truncate(qa));
    cfg_write32(f, 0x2c, @truncate(qa >> 32));
    const qu = mmu.to_phys(@intFromPtr(used));
    cfg_write32(f, 0x30, @truncate(qu));
    cfg_write32(f, 0x34, @truncate(qu >> 32));
    cfg_write16(f, 0x1c, 1); // queue_enable
    f.queue_notify_off = cfg_read16(f, 0x1e);
    cfg_write8(f, 0x14, 1 | 2 | 8 | 4); // DRIVER_OK
    if ((cfg_read8(f, 0x14) & 4) == 0) return false;
    f.armed = true;
    return true;
}

/// Pre-exit bring-up: scan bus 0 for every DID-0x1042 function (the boot
/// image always, the --data-disk attach when the runner flag was passed),
/// resolve its capability addresses, and run the full device init. Returns
/// the function count. PCI config-space reads must stay pre-exit (claim
/// 0013) — post-MMU only `blk_rearm`/`blk_identify` touch the devices.
pub fn virtio_blk_init() usize {
    function_count = 0;
    vlfs_disk = null;
    if (pci.pci_ecam == 0) {
        evidence.dump_str("VB: no ECAM\n");
        return 0;
    }
    var dev: u32 = 0;
    while (dev < 32 and function_count < max_functions) : (dev += 1) {
        const id = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0);
        if ((id & 0xffff) == 0xffff) continue;
        if ((id >> 16) != 0x1042) continue;
        const idx = function_count;
        const f = &functions[idx];
        f.* = .{};
        if (!resolve_dev(dev, f)) {
            evidence.dump_str("VB: resolve failed dev=");
            evidence.dump_hex(dev);
            evidence.dump_str("\n");
            continue;
        }
        function_count += 1;
        evidence.dump_str("VB dev=");
        evidence.dump_hex(dev);
        evidence.dump_str(" common=");
        evidence.dump_hex(f.common);
        evidence.dump_str(" notify=");
        evidence.dump_hex(f.notify);
        evidence.dump_str(" devcfg=");
        evidence.dump_hex(f.devcfg);
        evidence.dump_str("\n");
        _ = drive_state_machine(idx);
    }
    return function_count;
}

/// Post-MMU re-arm of every discovered function (claim 6420: VZ resets
/// virtio devices at ExitBootServices — the status register reads 0 and
/// the pre-exit queue is dead until re-programmed). Unconditional and
/// idempotent. Returns the number of functions that reached DRIVER_OK.
pub fn blk_rearm() usize {
    var armed: usize = 0;
    var i: usize = 0;
    while (i < function_count) : (i += 1) {
        functions[i].armed = false;
        if (drive_state_machine(i)) armed += 1;
    }
    return armed;
}

fn wait_completion(f: *Function, used: *VirtqUsed) bool {
    var attempt: usize = 0;
    while (attempt < poll_retries) : (attempt += 1) {
        var spins: usize = 0;
        while (spins < blk_op_budget) : (spins += 1) {
            mmu.invalidate_dcache_range(@intFromPtr(used), @sizeOf(VirtqUsed));
            if (used.idx != f.last_used) {
                f.last_used = used.idx;
                return true;
            }
        }
    }
    return false;
}

/// Fill the descriptor chain for one request — pure over the caller's
/// buffers so the request shapes are host-testable: header (device reads)
/// → data (device writes for read/GET_ID, reads for write; absent for
/// FLUSH) → status byte (device writes).
fn fill_chain(
    req: *Request,
    desc: *[queue_size]VirtqDesc,
    req_type: u32,
    lba: u64,
    write_data: ?*const [sector_len]u8,
    data_len: u32,
) void {
    req.header = .{ .type = req_type, .reserved = 0, .sector = lba };
    req.status = 0xff;
    if (write_data) |src| @memcpy(&req.data, src);
    desc[desc_header] = .{
        .addr = mmu.to_phys(@intFromPtr(&req.header)),
        .len = 16,
        .flags = virtq_f_next,
        .next = if (req_type == req_flush) desc_status else desc_data,
    };
    if (req_type != req_flush) {
        desc[desc_data] = .{
            .addr = mmu.to_phys(@intFromPtr(&req.data)),
            .len = data_len,
            .flags = virtq_f_next | (if (req_type == req_out) 0 else virtq_f_write),
            .next = desc_status,
        };
    }
    desc[desc_status] = .{
        .addr = mmu.to_phys(@intFromPtr(&req.status)),
        .len = 1,
        .flags = virtq_f_write,
        .next = 0xffff,
    };
}

/// Submit one request on function `idx` and wait for its completion.
/// `data_len` bounds the data descriptor (512 for sector I/O, 20 for
/// GET_ID, 0/no-descriptor for FLUSH). Returns the device's status byte;
/// `io_timeout` when the poll budget runs out twice.
fn submit(idx: usize, req_type: u32, lba: u64, write_data: ?*const [sector_len]u8, data_len: u32) BlkError!u8 {
    if (idx >= function_count) return error.no_disk;
    const f = &functions[idx];
    if (!f.armed) return error.not_armed;
    const desc = &qdesc[idx];
    const avail = &qavail[idx];
    const used = &qused[idx];
    const req = &qreq[idx];
    var retry: usize = 0;
    while (true) : (retry += 1) {
        // Drain a previous completion first: a timed-out poll leaves its
        // request outstanding, and its used-ring advance must not be
        // attributed to the next request (the old driver's lesson).
        mmu.invalidate_dcache_range(@intFromPtr(used), @sizeOf(VirtqUsed));
        if (avail.idx != used.idx) {
            if (!wait_completion(f, used)) {
                if (retry == 0 and wait_completion(f, used)) continue;
                return error.io_timeout;
            }
        }
        fill_chain(req, desc, req_type, lba, write_data, data_len);
        avail.ring[avail.idx % queue_size] = desc_header;
        avail.idx +%= 1;
        // Clean the rings + driver-written buffers so the device's DMA
        // reads the real contents (header always; data on writes only).
        mmu.clean_dcache_range(@intFromPtr(desc), @sizeOf(@TypeOf(desc.*)));
        mmu.clean_dcache_range(@intFromPtr(avail), @sizeOf(VirtqAvail));
        mmu.clean_dcache_range(@intFromPtr(&req.header), 16 + @as(u64, if (req_type == req_out) sector_len else 0));
        // Virtio 1.3 §4.1.5.2.1: without VIRTIO_F_NOTIFICATION_DATA the
        // notification is a 16-bit write of the queue index (0).
        mmio.mmio_write16(f.notify + @as(u64, f.queue_notify_off) * f.notify_mult, 0);
        if (!wait_completion(f, used)) {
            if (retry == 0 and wait_completion(f, used)) continue; // late completion; re-issue
            return error.io_timeout;
        }
        // The device wrote the status byte (and the data buffer for
        // read/GET_ID); invalidate before the CPU reads either.
        mmu.invalidate_dcache_range(@intFromPtr(&req.status), 1);
        if (req_type == req_in or req_type == req_get_id) {
            mmu.invalidate_dcache_range(@intFromPtr(&req.data), data_len);
        }
        return req.status;
    }
}

/// The identified VLFS disk's capacity in sectors (`no_disk`/`no_capacity`
/// named refusals when there is no disk or the device-config capability
/// did not answer).
pub fn capacity_sectors() BlkError!u64 {
    const idx = vlfs_disk orelse return error.no_disk;
    const cap = functions[idx].capacity;
    if (cap == 0) return error.no_capacity;
    return cap;
}

/// Read one 512-byte sector of the VLFS disk into `buf`.
pub fn read_sector(lba: u64, buf: *[sector_len]u8) BlkError!void {
    const idx = vlfs_disk orelse return error.no_disk;
    const cap = functions[idx].capacity;
    if (cap == 0) return error.no_capacity;
    if (lba >= cap) return error.bad_lba;
    const st = try submit(idx, req_in, lba, null, sector_len);
    if (st != s_ok) return error.io_error;
    @memcpy(buf, &qreq[idx].data);
}

/// Write one 512-byte sector to the VLFS disk. `bad_lba` bounds by the
/// announced capacity; the request completes only when the device accepted
/// the write — durability past a host-side crash additionally needs
/// `flush()` (ADR 0050 D4's wire contract).
pub fn write_sector(lba: u64, data: *const [sector_len]u8) BlkError!void {
    const idx = vlfs_disk orelse return error.no_disk;
    return write_sector_fn(idx, lba, data);
}

/// The refusal-by-name path: writing a blk function that is not the
/// identified VLFS disk is `not_vlfs_disk` — the boot ESP is unwritable by
/// construction (ADR 0050 D1).
pub fn write_sector_fn(idx: usize, lba: u64, data: *const [sector_len]u8) BlkError!void {
    if (idx >= function_count) return error.no_disk;
    if (vlfs_disk == null) return error.no_disk;
    if (idx != vlfs_disk.?) return error.not_vlfs_disk;
    const cap = functions[idx].capacity;
    if (cap == 0) return error.no_capacity;
    if (lba >= cap) return error.bad_lba;
    if (functions[idx].read_only) return error.read_only_partition;
    const st = try submit(idx, req_out, lba, data, sector_len);
    if (st != s_ok) return error.io_error;
}

/// VIRTIO_BLK_T_FLUSH — a real barrier (ADR 0050 D4): a transaction's
/// writes precede it on the one queue and the flush is waited out, so its
/// completion is the line durability is measured against. `no_flush` when
/// the feature was never negotiated — a silent no-op would be a lie.
pub fn flush() BlkError!void {
    const idx = vlfs_disk orelse return error.no_disk;
    if (!functions[idx].flush_ok) return error.no_flush;
    const st = try submit(idx, req_flush, 0, null, 0);
    if (st != s_ok) return error.io_error;
}

/// The ID bytes a function's GET_ID returned, trimmed to the claimed
/// length and any trailing NULs stripped (VZ pads the 20-byte field).
pub fn function_id(idx: usize) []const u8 {
    if (idx >= function_count) return "";
    const f = &functions[idx];
    var len = @min(f.id_len, id_len_max);
    while (len > 0 and f.id[len - 1] == 0) len -= 1;
    return f.id[0..len];
}

/// Post-rearm identification (ADR 0050 D1): read each armed function's
/// capacity from its device config, then issue VIRTIO_BLK_T_GET_ID. The
/// function whose identifier is `virelai-vlfs` becomes `vlfs_disk`;
/// UNSUPP/failure/none-matching leaves it null (`no_disk` honesty — VZ's
/// GET_ID behavior was claim-time [inferred], so whatever it answers is
/// recorded on serial by the caller).
pub fn blk_identify() void {
    vlfs_disk = null;
    var i: usize = 0;
    while (i < function_count) : (i += 1) {
        const f = &functions[i];
        f.id_answered = false;
        f.id_len = 0;
        if (!f.armed) continue;
        if (f.devcfg != 0) {
            // Capacity is the le64 sector count at device-config +0; read
            // it as two aligned u32 halves (the claim-0013 lesson: only
            // narrow accesses are reliable on VZ's emulated windows).
            const lo = mmio.mmio_read32(f.devcfg);
            const hi = mmio.mmio_read32(f.devcfg + 4);
            f.capacity = @as(u64, hi) << 32 | lo;
        }
        const st = submit(i, req_get_id, 0, null, id_len_max) catch {
            continue;
        };
        if (st != s_ok) continue; // UNSUPP/IOERR — recorded as unanswered
        @memcpy(&f.id, qreq[i].data[0..id_len_max]);
        const used = &qused[i];
        const slot = (f.last_used -% 1) % queue_size;
        f.id_len = @min(used.ring[slot].len, id_len_max);
        f.id_answered = true;
        if (std.mem.eql(u8, function_id(i), vlfs_disk_id)) vlfs_disk = i;
    }
}

// ---------------------------------------------------------------------------
// Host tests — the pure pieces (request shape, identity match, refusals)
// ---------------------------------------------------------------------------

test "virtio_blk: request chains are the spec shape" {
    var req: Request align(512) = undefined;
    var desc: [queue_size]VirtqDesc = undefined;

    // Read: header dev-reads → data dev-writes → status dev-writes.
    fill_chain(&req, &desc, req_in, 7, null, sector_len);
    try std.testing.expectEqual(@as(u32, 0), req.header.type);
    try std.testing.expectEqual(@as(u64, 7), req.header.sector);
    try std.testing.expectEqual(@as(u16, virtq_f_next), desc[desc_header].flags);
    try std.testing.expectEqual(desc_data, desc[desc_header].next);
    try std.testing.expectEqual(@as(u16, virtq_f_next | virtq_f_write), desc[desc_data].flags);
    try std.testing.expectEqual(desc_status, desc[desc_data].next);
    try std.testing.expectEqual(@as(u16, virtq_f_write), desc[desc_status].flags);
    try std.testing.expectEqual(@as(u32, 512), desc[desc_data].len);

    // Write: data is device-read (no WRITE flag), header carries OUT.
    var sector: [sector_len]u8 = @splat(0xa5);
    fill_chain(&req, &desc, req_out, 3, &sector, sector_len);
    try std.testing.expectEqual(@as(u32, 1), req.header.type);
    try std.testing.expectEqual(@as(u16, virtq_f_next), desc[desc_data].flags);
    try std.testing.expectEqual(@as(u8, 0xa5), req.data[511]);

    // FLUSH: header chains straight to the status byte — no data desc.
    fill_chain(&req, &desc, req_flush, 0, null, 0);
    try std.testing.expectEqual(@as(u32, 4), req.header.type);
    try std.testing.expectEqual(desc_status, desc[desc_header].next);

    // GET_ID: 20-byte device-written buffer.
    fill_chain(&req, &desc, req_get_id, 0, null, id_len_max);
    try std.testing.expectEqual(@as(u32, 8), req.header.type);
    try std.testing.expectEqual(@as(u32, 20), desc[desc_data].len);
    try std.testing.expectEqual(@as(u16, virtq_f_next | virtq_f_write), desc[desc_data].flags);
}

test "virtio_blk: vlfs identity match and id trimming" {
    function_count = 1;
    functions[0] = .{};
    // Exact answer.
    @memcpy(functions[0].id[0..vlfs_disk_id.len], vlfs_disk_id);
    functions[0].id_len = vlfs_disk_id.len;
    try std.testing.expectEqualStrings(vlfs_disk_id, function_id(0));
    // VZ may pad the 20-byte field with NULs — same match after trim.
    functions[0].id_len = 20;
    try std.testing.expectEqualStrings(vlfs_disk_id, function_id(0));
    // A different id (e.g. a named boot disk) is not the VLFS disk.
    @memset(&functions[0].id, 0);
    @memcpy(functions[0].id[0.."virelai-boot".len], "virelai-boot");
    functions[0].id_len = 12;
    try std.testing.expect(!std.mem.eql(u8, function_id(0), vlfs_disk_id));
    try std.testing.expectEqualStrings("virelai-boot", function_id(0));
    // Out-of-range index answers empty, never garbage.
    try std.testing.expectEqualStrings("", function_id(7));
    function_count = 0;
}

test "virtio_blk: named refusals hold without a device" {
    functions = @splat(.{});
    function_count = 0;
    vlfs_disk = null;
    var buf: [sector_len]u8 = @splat(0);
    try std.testing.expectError(error.no_disk, read_sector(0, &buf));
    try std.testing.expectError(error.no_disk, write_sector(0, &buf));
    try std.testing.expectError(error.no_disk, flush());
    try std.testing.expectError(error.no_disk, capacity_sectors());
    try std.testing.expectError(error.no_disk, write_sector_fn(0, 0, &buf));

    // An identified disk with unread capacity refuses by name.
    function_count = 2;
    functions[0] = .{ .dev = 1 };
    functions[1] = .{ .dev = 2, .armed = true };
    vlfs_disk = 1;
    try std.testing.expectError(error.no_capacity, read_sector(0, &buf));
    try std.testing.expectError(error.no_capacity, write_sector(0, &buf));
    try std.testing.expectError(error.no_flush, flush());
    try std.testing.expectError(error.no_capacity, capacity_sectors());
    // The non-VLFS function refuses writes by name — the boot-disk rule.
    functions[0].armed = true;
    functions[0].capacity = 100;
    try std.testing.expectError(error.not_vlfs_disk, write_sector_fn(0, 0, &buf));
    // Writes past capacity refuse bad_lba before touching the rings.
    functions[1].capacity = 64;
    try std.testing.expectError(error.bad_lba, read_sector(64, &buf));
    try std.testing.expectError(error.bad_lba, write_sector(64, &buf));
    functions = @splat(.{});
    function_count = 0;
    vlfs_disk = null;
}
