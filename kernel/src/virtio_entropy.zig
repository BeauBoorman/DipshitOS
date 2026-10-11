//! VirelaiOS virtio-pci entropy transport (milestone four, card 1 —
//! claim 2665).
//!
//! Drives the device the runner attaches as
//! `VZVirtioEntropyDeviceConfiguration` — to the guest a modern virtio-pci
//! entropy device (VID 0x1af4, DID 0x1044, virtio device ID 4) on bus 0,
//! found via the MCFG ECAM base exactly like the console (DID 0x1043,
//! claim 0013) and the block device (DID 0x1042, claim 6420). The transport
//! mirrors `virtio_blk.zig`'s proven patterns: discovery + capability walk
//! + feature negotiation + split-ring queue setup run PRE-EXIT; post-MMU
//! the transport is RE-ARMED (claim 6420's lesson — VZ resets virtio
//! devices at ExitBootServices, so the block device's status reads 0
//! post-exit and its queue is dead until `blk_rearm`) and the first read
//! happens only after that re-arm. The device has no config space of its
//! own (virtio entropy §5.5); a request is one WRITE descriptor that the
//! device fills with random bytes, naming the length in the used ring.
//!
//! Short reads are handled honestly: the device may return fewer bytes
//! than the descriptor asked for, so `entropy_read` reassembles with a
//! bounded number of attempts, each its own fresh completion poll. A
//! single read is capped at `entropy_read_max` (256 bytes).
//!
//! Cache correctness mirrors the console/blk drivers: clean the
//! driver-written rings before the kick, invalidate the used ring before
//! polling, and invalidate the device-written buffer after completion.
//!
//! No libc, no POSIX, no allocation, no interrupts.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
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
    ring: [4]u16,
};
const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};
const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
    ring: [4]VirtqUsedElem,
};

/// Split-ring size: 4 (power of two, Virtio 1.3 §4.1.4.3). One request
/// outstanding at a time keeps the ring invariant (§2.7) trivially true;
/// a single WRITE descriptor never needs chaining.
const queue_size: u16 = 4;

const virtq_f_write: u16 = 0x2; // VIRTQ_DESC_F_WRITE

/// Completion-poll budget per wait, and how many fresh budgets a stuck
/// device gets before a request is failed honestly (mirrors virtio_blk).
const poll_budget: usize = 16_000_000;
const poll_retries: usize = 3;

/// Cap on a single read (the `random` monitor command's max is 256; the
/// boot seed needs 64). A larger request would be refused honestly.
pub const entropy_read_max: usize = 256;

/// How many short-read reassembly attempts a single `entropy_read` gets
/// before failing honestly (the device may return fewer bytes per
/// completion; each attempt is its own submit + fresh poll).
const short_read_attempts: usize = 8;

pub var ent_desc: [1]VirtqDesc align(16) = undefined;
pub var ent_avail: VirtqAvail align(2) = undefined;
pub var ent_used: VirtqUsed align(4) = undefined;
var ent_last_used: u16 = 0;

/// Transport state. Discovery/setup run pre-exit; the read paths run
/// post-MMU on the pre-exit-captured VAs after `entropy_rearm`.
pub var ent_dev: u32 = 0; // entropy device PCI device number
pub var ent_ready: bool = false; // transport initialized, reads armed
pub var ent_common: u64 = 0; // common-config struct address (BAR + cap offset)
pub var ent_notify: u64 = 0; // notify region base (BAR + cap offset)
pub var ent_notify_mult: u32 = 0; // notify_off_multiplier
pub var ent_queue_notify_off: u16 = 0; // queue 0 notify offset
pub var ent_bar0: u64 = 0; // entropy BAR0 base (the identity-map window)

/// Current device status (device_status register, common cfg + 0x14). The
/// caller prints this pre-re-arm so the host sees whether VZ reset the
/// device at ExitBootServices (0 = reset, the claim-6420 behavior) before
/// the re-arm restores DRIVER_OK. 0xff when the transport was never
/// discovered.
pub fn ent_status() u8 {
    if (ent_common == 0) return 0xff;
    return vp_read8(0x14);
}

/// Re-arm the transport POST-exit (claim 6420's lesson, applied to the
/// entropy device): VZ resets virtio devices at ExitBootServices (the
/// block device's status register reads 0 post-exit and its queue is
/// disabled — claim 6420), so the queue setup runs again after the MMU
/// switch. Common-config MMIO writes work post-exit through the mapped
/// Device window (verified for blk: the device returns DRIVER_OK after
/// this sequence); PCI config-space reads must stay pre-exit (claim 0013).
/// Unconditional and idempotent: whether or not VZ actually reset this
/// device, a fresh reset → re-init sequence leaves the transport in a
/// known armed state.
pub fn entropy_rearm() bool {
    if (ent_common == 0) return false;
    vp_write8(0x14, 0); // reset
    var spins: usize = 0;
    while (vp_read8(0x14) != 0) : (spins += 1) {
        if (spins > 1_000_000) return false;
    }
    vp_write8(0x14, 1 | 2); // ACKNOWLEDGE | DRIVER
    vp_write32(0x08, 1);
    vp_write32(0x0c, 1); // accept VIRTIO_F_VERSION_1
    vp_write8(0x14, 1 | 2 | 8); // FEATURES_OK
    if ((vp_read8(0x14) & 8) == 0) return false;
    vp_write16(0x16, 0); // queue_select = 0
    vp_write16(0x18, queue_size);
    ent_desc[0] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    ent_avail = .{ .flags = 0, .idx = 0, .ring = .{ 0, 0, 0, 0 } };
    ent_used = .{ .flags = 0, .idx = 0, .ring = .{ .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 } } };
    mmu.clean_dcache_range(@intFromPtr(&ent_used), @sizeOf(VirtqUsed));
    ent_last_used = 0;
    // Claim 5804: queue GPAs are guest PHYSICAL addresses — translate the
    // post-jump kernel VAs.
    const qd = mmu.to_phys(@intFromPtr(&ent_desc));
    mmio.mmio_write32(ent_common + 0x20, @truncate(qd));
    mmio.mmio_write32(ent_common + 0x24, @truncate(qd >> 32));
    const qa = mmu.to_phys(@intFromPtr(&ent_avail));
    mmio.mmio_write32(ent_common + 0x28, @truncate(qa));
    mmio.mmio_write32(ent_common + 0x2c, @truncate(qa >> 32));
    const qu = mmu.to_phys(@intFromPtr(&ent_used));
    mmio.mmio_write32(ent_common + 0x30, @truncate(qu));
    mmio.mmio_write32(ent_common + 0x34, @truncate(qu >> 32));
    vp_write16(0x1c, 1); // queue_enable
    ent_queue_notify_off = vp_read16(0x1e);
    vp_write8(0x14, 1 | 2 | 8 | 4); // DRIVER_OK
    if ((vp_read8(0x14) & 4) == 0) return false;
    ent_ready = true;
    evidence.dump_str("VE rearm st=");
    evidence.dump_hex(vp_read8(0x14));
    evidence.dump_str(" qen=");
    evidence.dump_hex(vp_read16(0x1c));
    evidence.dump_str("\n");
    return true;
}

fn vp_read8(off: u32) u8 {
    return mmio.mmio_read8(ent_common + off);
}

fn vp_write8(off: u32, value: u8) void {
    mmio.mmio_write8(ent_common + off, value);
}

fn vp_read16(off: u32) u16 {
    return mmio.mmio_read16(ent_common + off);
}

fn vp_write16(off: u32, value: u16) void {
    mmio.mmio_write16(ent_common + off, value);
}

fn vp_read32(off: u32) u32 {
    return mmio.mmio_read32(ent_common + off);
}

fn vp_write32(off: u32, value: u32) void {
    mmio.mmio_write32(ent_common + off, value);
}

/// Resolve the virtio common/notify capability addresses for `dev` (its
/// BARs + cap walk). Returns the common-config address, or 0 on failure.
fn resolve_dev(dev: u32) u64 {
    var bar_base: [6]u64 = @splat(0);
    var bi: usize = 0;
    while (bi < 6) : (bi += 1) {
        const low = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0x10 + @as(u32, @intCast(bi)) * 4);
        if ((low & 1) != 0) continue; // I/O space — ignored
        const base: u64 = low & ~@as(u32, 0xf);
        bar_base[bi] = base;
        if (((low >> 1) & 0x3) == 2 and bi + 1 < 6) { // 64-bit BAR
            const high = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0x10 + @as(u32, @intCast(bi + 1)) * 4);
            bar_base[bi] |= @as(u64, high) << 32;
            bi += 1;
        }
    }
    const cap_ptr = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0x34) & 0xff;
    var common_bar: u32 = 0;
    var common_off: u32 = 0;
    var notify_bar: u32 = 0;
    var notify_off: u32 = 0;
    var notify_mult: u32 = 0;
    var c: u32 = cap_ptr;
    var caps: usize = 0;
    while (c != 0 and c < 0x100 and (c & 3) == 0 and caps < 16) : (caps += 1) {
        const head = pci.pci_read32(pci.pci_ecam, 0, dev, 0, c);
        const id = head & 0xff;
        const next = (head >> 8) & 0xff;
        if (id == 0x09) {
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
                else => {},
            }
        }
        c = next;
    }
    if (common_bar >= 6 or notify_bar >= 6) return 0;
    ent_notify = bar_base[notify_bar] + notify_off;
    ent_notify_mult = notify_mult;
    ent_bar0 = bar_base[0];
    return bar_base[common_bar] + common_off;
}

/// Initialize the modern virtio-pci entropy transport: locate the entropy
/// device (DID 0x1044, virtio device ID 4) on bus 0, resolve BARs + the
/// virtio capabilities (common/notify), program features
/// (VIRTIO_F_VERSION_1 mandatory), set up queue 0 (split ring, size 4),
/// and reach DRIVER_OK. PRE-EXIT only (the console/blk proven placement —
/// post-exit config-space reads hang on VZ, claim 0013). Evidence is
/// dumped to the probe buffer so the host sees the device + queue state
/// either way.
pub fn virtio_entropy_init() bool {
    if (pci.pci_ecam == 0) {
        evidence.dump_str("VE: no ECAM\n");
        return false;
    }

    // Locate the entropy device: DID 0x1044 (virtio device ID 4 — the VZ
    // host attaches VZVirtioEntropyDeviceConfiguration). Bus 0, function 0.
    var found_dev: u32 = 32; // sentinel: not found
    var dev: u32 = 0;
    while (dev < 32) : (dev += 1) {
        const id = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0);
        if ((id & 0xffff) == 0xffff) continue;
        const did = id >> 16;
        if (did == 0x1044) {
            found_dev = dev;
            break;
        }
    }
    if (found_dev == 32) {
        evidence.dump_str("VE: no virtio-entropy PCI device\n");
        return false;
    }
    ent_dev = found_dev;
    evidence.dump_str("VE dev=");
    evidence.dump_hex(ent_dev);
    evidence.dump_str("\n");

    ent_common = resolve_dev(ent_dev);
    if (ent_common == 0) {
        evidence.dump_str("VE: missing capability structs\n");
        return false;
    }
    evidence.dump_str("VE common=");
    evidence.dump_hex(ent_common);
    evidence.dump_str(" notify=");
    evidence.dump_hex(ent_notify);
    evidence.dump_str(" bar0=");
    evidence.dump_hex(ent_bar0);
    evidence.dump_str("\n");

    // Modern transport init: reset, ACKNOWLEDGE|DRIVER, accept
    // VIRTIO_F_VERSION_1, FEATURES_OK (the console/blk exact sequence).
    vp_write8(0x14, 0); // reset
    var reset_spins: usize = 0;
    while (vp_read8(0x14) != 0) : (reset_spins += 1) {
        if (reset_spins >= 1_000_000) {
            evidence.dump_str("VE: reset timeout\n");
            return false;
        }
    }
    vp_write8(0x14, 1 | 2); // ACKNOWLEDGE | DRIVER
    vp_write32(0x00, 1);
    const features_hi = vp_read32(0x04);
    vp_write32(0x00, 0);
    evidence.dump_str("VE feats=");
    evidence.dump_hex(vp_read32(0x04));
    evidence.dump_str("/");
    evidence.dump_hex(features_hi);
    evidence.dump_str("\n");
    if ((features_hi & 1) == 0) {
        evidence.dump_str("VE: no VIRTIO_F_VERSION_1\n");
        return false;
    }
    vp_write32(0x08, 1);
    vp_write32(0x0c, 1); // accept VIRTIO_F_VERSION_1
    vp_write32(0x08, 0);
    vp_write32(0x0c, 0);
    vp_write8(0x14, 1 | 2 | 8); // FEATURES_OK
    if ((vp_read8(0x14) & 8) == 0) {
        evidence.dump_str("VE: FEATURES_OK failed\n");
        return false;
    }

    // Queue 0 = the entropy request queue (virtio entropy §5.5: one
    // virtqueue; a request is one WRITE buffer the device fills).
    vp_write16(0x16, 0); // queue_select = 0
    const qsz = vp_read16(0x18);
    if (qsz < queue_size) {
        evidence.dump_str("VE: queue 0 too small\n");
        return false;
    }
    vp_write16(0x18, queue_size); // queue_size = 4 (power of 2, §4.1.4.3)
    ent_desc[0] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    ent_avail = .{ .flags = 0, .idx = 0, .ring = .{ 0, 0, 0, 0 } };
    ent_used = .{ .flags = 0, .idx = 0, .ring = .{ .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 } } };
    // Clean the used ring's init write to RAM now (BSS is not trusted
    // zeroed; the poll would otherwise re-read stale RAM garbage — the
    // console's claim-0013 lesson).
    mmu.clean_dcache_range(@intFromPtr(&ent_used), @sizeOf(VirtqUsed));
    ent_last_used = 0;
    // Queue GPA registers are le64; VZ's common-cfg emulation accepts
    // 32-bit accesses (claim 0013), so write each half as a 32-bit store.
    // Claim 5804: queue GPAs are guest PHYSICAL — translate post-jump VAs.
    const qd = mmu.to_phys(@intFromPtr(&ent_desc));
    mmio.mmio_write32(ent_common + 0x20, @truncate(qd));
    mmio.mmio_write32(ent_common + 0x24, @truncate(qd >> 32));
    const qa = mmu.to_phys(@intFromPtr(&ent_avail));
    mmio.mmio_write32(ent_common + 0x28, @truncate(qa));
    mmio.mmio_write32(ent_common + 0x2c, @truncate(qa >> 32));
    const qu = mmu.to_phys(@intFromPtr(&ent_used));
    mmio.mmio_write32(ent_common + 0x30, @truncate(qu));
    mmio.mmio_write32(ent_common + 0x34, @truncate(qu >> 32));
    vp_write16(0x1c, 1); // queue_enable
    ent_queue_notify_off = vp_read16(0x1e);
    vp_write8(0x14, 1 | 2 | 8 | 4); // DRIVER_OK
    if ((vp_read8(0x14) & 4) == 0) {
        evidence.dump_str("VE: DRIVER_OK failed\n");
        return false;
    }
    evidence.dump_str("VE qsz=");
    evidence.dump_hex(vp_read16(0x18));
    evidence.dump_str(" qen=");
    evidence.dump_hex(vp_read16(0x1c));
    evidence.dump_str(" qoff=");
    evidence.dump_hex(ent_queue_notify_off);
    evidence.dump_str(" st=");
    evidence.dump_hex(vp_read8(0x14));
    evidence.dump_str("\n");
    ent_ready = true;
    return true;
}

/// Wait for the device to consume the outstanding request (used.idx to
/// advance past `ent_last_used`). Returns true on completion, false after
/// `poll_retries` fresh `poll_budget` polls. Every wait refreshes the used
/// ring's cache line first, exactly like the blk/console polls.
fn wait_completion() bool {
    var attempt: usize = 0;
    while (attempt < poll_retries) : (attempt += 1) {
        var spins: usize = 0;
        while (spins < poll_budget) : (spins += 1) {
            mmu.invalidate_dcache_range(@intFromPtr(&ent_used), @sizeOf(VirtqUsed));
            if (ent_used.idx != ent_last_used) {
                ent_last_used = ent_used.idx;
                return true;
            }
        }
    }
    return false;
}

/// Host-test seam (issue #2084): an injectable device read so the
/// getrandom lazy-reseed path can be driven unseeded → seeded without a
/// real virtio transport. Never armed in production (test-only builds).
pub var test_read_hook: ?*const fn (out: []u8) bool = null;

/// M97g (#2084/#2086): the shared lazy-reseed primitive — read `out.len`
/// real entropy bytes, re-arming the transport once if VZ reset the
/// device at ExitBootServices (claim 6420's lesson). Returns false when
/// no seed could be obtained; callers then fail closed. The getrandom
/// handler and the trace/profile session mints both consume this.
pub fn read_seed(out: []u8) bool {
    if (entropy_read(out)) return true;
    if (!entropy_rearm()) return false;
    return entropy_read(out);
}

/// Read up to `out.len` real random bytes into `out` (bounded by
/// `entropy_read_max`). The device may return fewer bytes than the
/// descriptor asked for (short read); `entropy_read` reassembles with a
/// bounded number of attempts. Returns true iff `out` was fully filled.
/// A stuck device (completion timeout) fails honestly without touching the
/// rings again.
pub fn entropy_read(out: []u8) bool {
    if (comptime builtin.is_test) {
        if (test_read_hook) |hook| return hook(out);
    }
    if (out.len == 0 or out.len > entropy_read_max) return false;
    if (!ent_ready) return false;
    var got: usize = 0;
    var attempt: usize = 0;
    while (got < out.len and attempt < short_read_attempts) : (attempt += 1) {
        // Drain any previous completion first: a timed-out poll leaves the
        // request outstanding, and its used-ring advance must not be
        // attributed to the next request.
        mmu.invalidate_dcache_range(@intFromPtr(&ent_used), @sizeOf(VirtqUsed));
        if (ent_avail.idx != ent_used.idx) {
            if (!wait_completion()) return false;
        }
        const remaining = out.len - got;
        const desc_len: u32 = @intCast(remaining);
        ent_desc[0] = .{
            .addr = mmu.to_phys(@intFromPtr(out.ptr) + got),
            .len = desc_len,
            .flags = virtq_f_write, // device writes into this buffer
            .next = 0xffff,
        };
        ent_avail.ring[ent_avail.idx % queue_size] = 0; // descriptor 0
        ent_avail.idx +%= 1;
        mmu.clean_dcache_range(@intFromPtr(&ent_desc), @sizeOf(VirtqDesc));
        mmu.clean_dcache_range(@intFromPtr(&ent_avail), @sizeOf(VirtqAvail));
        // Virtio 1.3 §4.1.5.2.1: without VIRTIO_F_NOTIFICATION_DATA the
        // notification is a 16-bit write of the queue index (0).
        mmio.mmio_write16(ent_notify + @as(u64, ent_queue_notify_off) * ent_notify_mult, 0);
        if (!wait_completion()) return false;
        // The used element names the returned buffer at index
        // (used.idx - 1) % queue_size; its len is the bytes the device
        // wrote. Invalidate that range before the CPU reads it.
        const used_slot = (ent_used.idx -% 1) % queue_size;
        const filled: usize = @min(ent_used.ring[used_slot].len, remaining);
        mmu.invalidate_dcache_range(@intFromPtr(out.ptr) + got, filled);
        got += filled;
    }
    return got == out.len;
}

// ---------------------------------------------------------------------------
// Host tests — only the pieces that need no device
// ---------------------------------------------------------------------------

test "virtio_entropy: request shape and bounds are the spec shape" {
    try std.testing.expectEqual(@as(u16, 4), queue_size);
    try std.testing.expectEqual(@as(usize, 256), entropy_read_max);
    // Unarmed transport reports honestly, as does an oversized read.
    ent_ready = false;
    var buf: [32]u8 = undefined;
    try std.testing.expect(!entropy_read(&buf));
    var big: [257]u8 = undefined;
    try std.testing.expect(!entropy_read(&big));
    try std.testing.expect(!entropy_read(&[_]u8{}));
    // A zero-length read is refused, not a hang.
    ent_ready = true;
    try std.testing.expect(!entropy_read(&[_]u8{}));
    // The WRITE descriptor flag is what the device expects on queue 0.
    try std.testing.expectEqual(@as(u16, 0x2), virtq_f_write);
}
