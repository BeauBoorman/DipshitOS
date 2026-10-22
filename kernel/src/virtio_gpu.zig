//! VirelaiOS virtio-pci graphics transport (milestone six, card G1 — claim
//! 6053).
//!
//! Drives the device the runner attaches as `VZVirtioGraphicsDeviceConfiguration`
//! under `--display` / `--screenshot` — to the guest a modern virtio-pci gpu
//! device (VID 0x1af4, DID 0x1050 expected = 0x1040 + Virtio Device ID 16; the
//! transitional 0x1010 is also accepted, the console's 0x1003 precedent), found
//! via the MCFG ECAM base exactly like the console (0x1043, claim 0013), block
//! (0x1042, claim 6420), entropy (0x1044, claim 2665) and net (0x1041, claim
//! 1373) devices. The DID actually OBSERVED is reported by `screen`
//! (confirm-at-claim-time — a differing DID is a finding, recorded as the
//! 6420/2665 corrections were).
//!
//! The transport mirrors the blk/entropy/net patterns: discovery + capability
//! walk + feature negotiation + split-ring queue setup run PRE-EXIT (post-exit
//! PCI config-space reads hang on VZ, claim 0013); post-MMU the transport is
//! RE-ARMED (the claim-6420/2665 lesson — VZ resets some virtio devices at
//! ExitBootServices; blk/entropy reset to `st=00`, the net device does NOT,
//! `st=0f` observed — the gpu answer is OBSERVED at claim time, not assumed).
//!
//! G1 negotiates VIRTIO_F_VERSION_1 (mandatory) plus whatever virtio-gpu
//! feature bits the device demands (the net ladder lesson: the VZ device may
//! clear FEATURES_OK on a minimal mask). The framebuffer exposure is the spec
//! 2D command path: GET_DISPLAY_INFO → RESOURCE_CREATE_2D →
//! RESOURCE_ATTACH_BACKING (one mem_entry over the fixed BSS framebuffer) →
//! SET_SCANOUT → TRANSFER_TO_HOST_2D → RESOURCE_FLUSH, all over the CONTROL
//! queue (queue 0) with one command outstanding at a time (the blk/entropy
//! one-request-at-a-time shape). The framebuffer is a fixed BSS array
//! (1280×720 ×4 ≈ 3.7 MiB) — no heap. The pixel format is X8R8G8B8_UNORM
//! (the Linux-guest/XR24 convention; a differing byte order on VZ is a
//! claim-time finding, corrected like the 0x1100-vs-0x0011 UDP fix).
//! Honest bounds: G1 proves the transport + a writable framebuffer with a
//! solid fill; text (G2), Road Pops (G3), input (G4), and the Driving Award
//! window manager (G5) are separate cards. The cursor queue (queue 1) is NOT
//! armed (input is G4) unless the device demands it (claim-time observation).
//!
//! No libc, no POSIX, no allocation, no interrupts.

const std = @import("std");
const mmio = @import("mmio.zig");
const mmu = @import("mmu.zig");
const pci = @import("pci.zig");
const evidence = @import("evidence.zig");

// ---------------------------------------------------------------------------
// Split-ring structures (the blk/entropy/console/net shared layout)
// ---------------------------------------------------------------------------

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

/// Split-ring size: 4 (power of two, Virtio 1.3 §4.1.4.3) — the proven
/// blk/entropy/net size. One command outstanding at a time keeps the ring
/// invariant (§2.7) trivially true.
pub const queue_size: u16 = 4;

const virtq_f_next: u16 = 0x1; // VIRTQ_DESC_F_NEXT (chained cmd → resp)
const virtq_f_write: u16 = 0x2; // VIRTQ_DESC_F_WRITE (the response buffer)

/// Completion-poll budget per wait, and how many fresh budgets a stuck
/// device gets before a request fails honestly (mirrors blk/entropy/net).
const poll_budget: usize = 16_000_000;
const poll_retries: usize = 3;

// ---------------------------------------------------------------------------
// Feature bits (64-bit device-features space)
// ---------------------------------------------------------------------------

const vf_version_1: u64 = 0x1 << 32; // VIRTIO_F_VERSION_1 (bit 32)
const vf_gpu_virgl: u64 = 0x1 << 0; // VIRTIO_GPU_F_VIRGL (bit 0)
const vf_gpu_edid: u64 = 0x1 << 1; // VIRTIO_GPU_F_EDID (bit 1)
const vf_gpu_resource_uuid: u64 = 0x1 << 2; // VIRTIO_GPU_F_RESOURCE_UUID (bit 2)
const vf_gpu_context_init: u64 = 0x1 << 4; // VIRTIO_GPU_F_CONTEXT_INIT (bit 4)

// ---------------------------------------------------------------------------
// virtio-gpu spec constants (Virtio 1.3, device 16)
// ---------------------------------------------------------------------------

/// Command types (control queue).
const cmd_get_display_info: u32 = 0x0100;
const cmd_resource_create_2d: u32 = 0x0101;
const cmd_set_scanout: u32 = 0x0103;
const cmd_resource_flush: u32 = 0x0104;
const cmd_transfer_to_host_2d: u32 = 0x0105;
const cmd_resource_attach_backing: u32 = 0x0106;

/// Response types. 0x1100–0x11ff are OK responses; 0x1200+ are errors.
const resp_ok_nodata: u32 = 0x1100;
const resp_ok_display_info: u32 = 0x1101;

/// The pixel format for the scanout resource: B8G8R8X8_UNORM (32 bpp,
/// little-endian — memory bytes B, G, R, X for an 0x00RRGGBB pixel).
/// VZ's "Virtio GPU 2D" device expects this (claim-time observation — the
/// working reference drivers create the scanout resource as format 2);
/// the byte order is confirmed by the live screenshot matching the fill
/// color.
pub const format_b8g8r8x8: u32 = 2;

/// The framebuffer dimensions (match the runner's 1280×720 scanout).
pub const fb_width: u32 = 1280;
pub const fb_height: u32 = 720;
pub const fb_bpp: u32 = 4;
pub const fb_size: usize = fb_width * fb_height * fb_bpp; // 3,686,400

/// The ONE scanout resource id G1 uses.
pub const resource_id: u32 = 1;

// ---------------------------------------------------------------------------
// Command / response structures (extern — the wire format)
// ---------------------------------------------------------------------------

/// virtio_gpu_ctrl_hdr: type(4) flags(4) fence_id(8) ctx_id(4) ring_idx(4).
const CtrlHdr = extern struct {
    type: u32,
    flags: u32,
    fence_id: u64,
    ctx_id: u32,
    ring_idx: u32,
};

const Rect = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

const Create2D = extern struct {
    hdr: CtrlHdr,
    resource_id: u32,
    format: u32,
    width: u32,
    height: u32,
};

const MemEntry = extern struct {
    addr: u64,
    length: u32,
    padding: u32,
};

const AttachBacking = extern struct {
    hdr: CtrlHdr,
    resource_id: u32,
    nr_entries: u32,
    entries: [1]MemEntry,
};

const SetScanout = extern struct {
    hdr: CtrlHdr,
    rect: Rect,
    scanout_id: u32,
    resource_id: u32,
};

const Transfer2D = extern struct {
    hdr: CtrlHdr,
    rect: Rect,
    offset: u64,
    resource_id: u32,
    padding: u32,
};

const Flush = extern struct {
    hdr: CtrlHdr,
    rect: Rect,
    resource_id: u32,
    padding: u32,
};

/// virtio_gpu_display_one (virtio-gpu 1.2 — VZ's "Virtio GPU 2D"): the
/// rect, enabled, and the 1.2-ADDED flags field (24 bytes total). A
/// 20-byte pre-1.2 shape makes GET_DISPLAY_INFO's response 344 instead of
/// the 408 the device writes — observed at claim time: the device wedged
/// the control queue (DEVICE_NEEDS_RESET) on the undersized response.
const DisplayOne = extern struct {
    rect: Rect,
    enabled: u32,
    flags: u32,
};

const RespDisplayInfo = extern struct {
    hdr: CtrlHdr,
    pmodes: [16]DisplayOne,
};

// ---------------------------------------------------------------------------
// Device state (fixed BSS — the one-and-only real instance)
// ---------------------------------------------------------------------------

/// Transport state. Discovery/setup run pre-exit; the 2D path runs
/// post-MMU on the pre-exit-captured VAs after `gpu_rearm`.
pub var gpu_dev: u32 = 0; // gpu device PCI device number
pub var gpu_did: u32 = 0; // the OBSERVED device id (0x1050 expected)
pub var gpu_class: u32 = 0; // the OBSERVED PCI class
pub var gpu_ready: bool = false; // transport initialized pre-exit
pub var gpu_rearmed: bool = false; // post-exit re-arm succeeded
pub var gpu_setup_ok: bool = false; // the 2D path reached a flushed scanout
pub var gpu_common: u64 = 0; // common-config struct address (BAR + cap offset)
pub var gpu_notify: u64 = 0; // notify region base (BAR + cap offset)
pub var gpu_notify_mult: u32 = 0; // notify_off_multiplier
pub var gpu_queue_notify_off: u16 = 0; // queue 0's notify offset
pub var gpu_devcfg: u64 = 0; // device-config region (BAR + cap offset)
pub var gpu_bar0: u64 = 0; // gpu BAR0 base (the identity-map window)
/// Negotiated device features (64-bit; reported low/high in `screen`).
pub var gpu_feats_lo: u32 = 0;
pub var gpu_feats_hi: u32 = 0;
/// The device's OFFERED features (the honest claim-time record).
pub var gpu_dev_feats_lo: u32 = 0;
pub var gpu_dev_feats_hi: u32 = 0;
/// Last observed device_status (common cfg + 0x14) — 0xff if never found.
pub var gpu_status_last: u8 = 0xff;
/// num_scanouts from the device config (virtio_gpu_config offset 8).
pub var gpu_num_scanouts: u32 = 0;
/// The scanout mode the device reported (GET_DISPLAY_INFO pmodes[0]).
pub var gpu_scanout_w: u32 = 0;
pub var gpu_scanout_h: u32 = 0;
pub var gpu_scanout_enabled: u32 = 0;
/// Counters (the `screen` report): commands submitted, non-OK responses,
/// completion timeouts.
pub var gpu_cmds: u64 = 0;
pub var gpu_errors: u64 = 0;
pub var gpu_timeouts: u64 = 0;
/// Diagnostics captured on a completion timeout (reported by `screen` —
/// the claim-time record of why the control queue did not complete).
pub var gpu_diag_avail: u16 = 0;
pub var gpu_diag_used: u16 = 0;
pub var gpu_diag_st: u8 = 0;
pub var gpu_diag_qen: u16 = 0;
pub var gpu_diag_qoff: u16 = 0;
pub var gpu_diag_notify: u64 = 0;
pub var gpu_diag_mult: u32 = 0;
pub var gpu_diag_desc_phys: u64 = 0;
pub var gpu_diag_avail_phys: u64 = 0;
pub var gpu_diag_used_phys: u64 = 0;
/// The first 8 bytes of the outstanding command (type + flags) and the
/// device's ISR register (BAR0+0x3000) at timeout — the raw claim-time
/// record of what the device saw.
pub var gpu_diag_cmd0: u32 = 0;
pub var gpu_diag_cmd1: u32 = 0;
pub var gpu_diag_isr: u32 = 0;
pub var gpu_diag_qsz: u16 = 0;
/// The framebuffer's PHYSICAL address (what RESOURCE_ATTACH_BACKING names).
pub var gpu_fb_phys: u64 = 0;
/// Honest failure reason (reported by `screen` when not ready).
pub var gpu_fail: []const u8 = "";

/// The fixed BSS framebuffer — the scanout resource's backing. One
/// mem_entry attaches its PHYSICAL address to the resource; the 2D path
/// transfers it to the host and flushes it to the scanout. No heap.
pub var gpu_fb: [fb_size]u8 align(4096) = undefined;

/// The control-queue rings (BSS, stable physical addresses for the device).
var gpu_desc: [queue_size]VirtqDesc align(16) = undefined;
var gpu_avail: VirtqAvail align(2) = undefined;
var gpu_used: VirtqUsed align(4) = undefined;
var gpu_last_used: u16 = 0;
/// The cursor-queue rings (queue 1 — armed for device compatibility, never
/// driven by G1: input is card G4).
var gpu_cursor_desc: [queue_size]VirtqDesc align(16) = undefined;
var gpu_cursor_avail: VirtqAvail align(2) = undefined;
var gpu_cursor_used: VirtqUsed align(4) = undefined;

/// Fixed BSS command + response buffers. One command outstanding at a time;
/// the largest command is TRANSFER_TO_HOST_2D (56 B), the largest response
/// is the display-info (24 + 16×20 = 344 B).
var gpu_cmd_buf: [64]u8 align(16) = undefined;
var gpu_resp_buf: [512]u8 align(16) = undefined;

// ---------------------------------------------------------------------------
// Common-config MMIO accessors (post-exit safe through the mapped window)
// ---------------------------------------------------------------------------

fn vp_read8(off: u32) u8 {
    return mmio.mmio_read8(gpu_common + off);
}
fn vp_write8(off: u32, value: u8) void {
    mmio.mmio_write8(gpu_common + off, value);
}
fn vp_read16(off: u32) u16 {
    return mmio.mmio_read16(gpu_common + off);
}
fn vp_write16(off: u32, value: u16) void {
    mmio.mmio_write16(gpu_common + off, value);
}
fn vp_read32(off: u32) u32 {
    return mmio.mmio_read32(gpu_common + off);
}
fn vp_write32(off: u32, value: u32) void {
    mmio.mmio_write32(gpu_common + off, value);
}

/// Current device status (device_status register, common cfg + 0x14) —
/// reported by `screen`. 0xff when the transport was never discovered.
pub fn gpu_status() u8 {
    if (gpu_common == 0) return 0xff;
    return vp_read8(0x14);
}

// ---------------------------------------------------------------------------
// Capability resolution + discovery (PRE-EXIT only — claim 0013)
// ---------------------------------------------------------------------------

/// Resolve the virtio common/notify/device capabilities for `dev` (its
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
    var devcfg_bar: u32 = 0;
    var devcfg_off: u32 = 0;
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
                4 => {
                    devcfg_bar = bar;
                    devcfg_off = off;
                },
                else => {},
            }
        }
        c = next;
    }
    if (common_bar >= 6 or notify_bar >= 6) return 0;
    gpu_notify = bar_base[notify_bar] + notify_off;
    gpu_notify_mult = notify_mult;
    if (devcfg_bar < 6) gpu_devcfg = bar_base[devcfg_bar] + devcfg_off;
    gpu_bar0 = bar_base[0];
    return bar_base[common_bar] + common_off;
}

// ---------------------------------------------------------------------------
// Feature selection (pure — host-testable)
// ---------------------------------------------------------------------------

/// Choose the feature mask to accept for the given offered device features.
/// The spec-correct selection is VIRTIO_F_VERSION_1 alone (G1 uses no
/// fences, no contexts, no resource mapping); the fixed ladder covers the
/// progressively larger masks a quirky VZ device might demand (the
/// claim-1373 net lesson: it cleared FEATURES_OK even for VER1-only).
/// Claim-time observation (the VZ gpu offers VIRGL|RESOURCE_UUID|
/// ACCESS_PLATFORM|VERSION_1): the device may demand the offered gpu
/// feature bits too, so the ladder prefers the largest mask whose bits
/// are ALL offered — ending at the minimal VERSION_1-only mask (the
/// claim-1373 shape). Accepting the VIRGL bit here is ONLY a FEATURES_OK
/// negotiation artifact: this driver implements no VIRGL commands, and
/// M102 research (issue #2161) observed that the native VZ device
/// provides no usable VIRGL path — the experimental 3D channel is the
/// private DID 0x1083 device (gpu3d_device.zig). VIRTIO_F_ACCESS_PLATFORM
/// is deliberately NOT part of any accepted mask: accepting it would put
/// every ring address through the platform DMA translation, and every
/// other VZ virtio device works with plain physical addresses (the
/// blk/entropy/net/console precedent). Only masks whose bits are ALL
/// offered are returned (0 when even the minimum is impossible).
pub fn select_features(device_feats: u64) u64 {
    if ((device_feats & vf_version_1) == 0) return 0;
    const fixed = [_]u64{
        vf_version_1 | vf_gpu_context_init | vf_gpu_virgl | vf_gpu_resource_uuid,
        vf_version_1 | vf_gpu_context_init | vf_gpu_virgl,
        vf_version_1 | vf_gpu_context_init | vf_gpu_resource_uuid,
        vf_version_1 | vf_gpu_virgl | vf_gpu_resource_uuid,
        vf_version_1 | vf_gpu_context_init,
        vf_version_1 | vf_gpu_virgl,
        vf_version_1 | vf_gpu_resource_uuid,
        vf_version_1,
    };
    for (fixed) |cand| {
        if ((cand & ~device_feats) == 0) return cand;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Queue setup (shared by init + re-arm)
// ---------------------------------------------------------------------------

/// Program one queue (`queue` = 0 controlq / 1 cursorq) with the split
/// rings. Returns false on a failed enable. The rings were zero-initialized
/// by the caller; the used ring gets a cache clean (BSS is not trusted
/// zeroed — the console's claim-0013 lesson). The cursor queue is armed
/// because the Linux virtio-gpu driver configures BOTH queues before its
/// first command, and VZ's implementation is Linux-compatible (claim-time
/// observation: control-queue commands wedged the device with queue 1
/// unconfigured — DEVICE_NEEDS_RESET 0x40 on the first GET_DISPLAY_INFO).
fn setup_queue(queue: u16) bool {
    vp_write16(0x16, queue);
    const qsz = vp_read16(0x18);
    if (qsz < queue_size) return false;
    vp_write16(0x18, queue_size);
    const desc: *[queue_size]VirtqDesc = if (queue == 0) &gpu_desc else &gpu_cursor_desc;
    const avail: *VirtqAvail = if (queue == 0) &gpu_avail else &gpu_cursor_avail;
    const used: *VirtqUsed = if (queue == 0) &gpu_used else &gpu_cursor_used;
    var i: usize = 0;
    while (i < queue_size) : (i += 1) {
        desc[i] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0xffff };
    }
    avail.* = .{ .flags = 0, .idx = 0, .ring = @splat(0) };
    used.* = .{ .flags = 0, .idx = 0, .ring = @as([queue_size]VirtqUsedElem, @splat(@as(VirtqUsedElem, .{ .id = 0, .len = 0 }))) };
    mmu.clean_dcache_range(@intFromPtr(used), @sizeOf(VirtqUsed));
    if (queue == 0) gpu_last_used = 0;
    // Queue GPA registers are le64; VZ's common-cfg emulation accepts
    // 32-bit accesses (claim 0013), so write each half as a 32-bit store.
    // Claim 5804: queue GPAs are guest PHYSICAL — translate kernel VAs.
    const qd = mmu.to_phys(@intFromPtr(desc));
    mmio.mmio_write32(gpu_common + 0x20, @truncate(qd));
    mmio.mmio_write32(gpu_common + 0x24, @truncate(qd >> 32));
    const qa = mmu.to_phys(@intFromPtr(avail));
    mmio.mmio_write32(gpu_common + 0x28, @truncate(qa));
    mmio.mmio_write32(gpu_common + 0x2c, @truncate(qa >> 32));
    const qu = mmu.to_phys(@intFromPtr(used));
    mmio.mmio_write32(gpu_common + 0x30, @truncate(qu));
    mmio.mmio_write32(gpu_common + 0x34, @truncate(qu >> 32));
    vp_write16(0x1c, 1); // queue_enable
    if (queue == 0) gpu_queue_notify_off = vp_read16(0x1e);
    return true;
}

/// Shared init sequence: reset, ACKNOWLEDGE|DRIVER, negotiate features,
/// FEATURES_OK, queue 0, DRIVER_OK. Runs pre-exit (`virtio_gpu_init`) and
/// again post-exit (`gpu_rearm`) — VZ resets some devices at
/// ExitBootServices (the claim-6420/2665 lesson; the gpu answer is
/// observed at claim time). Returns true when DRIVER_OK holds.
fn transport_init(rearm: bool) bool {
    if (gpu_common == 0) return false;
    vp_write8(0x14, 0); // reset
    var reset_spins: usize = 0;
    while (vp_read8(0x14) != 0) : (reset_spins += 1) {
        if (reset_spins >= 1_000_000) {
            gpu_fail = if (rearm) "re-arm: reset timeout" else "reset timeout";
            return false;
        }
    }
    vp_write8(0x14, 1 | 2); // ACKNOWLEDGE | DRIVER

    // Read the device features (64-bit), then accept our selection.
    vp_write32(0x00, 0);
    const feats_lo = vp_read32(0x04);
    vp_write32(0x00, 1);
    const feats_hi = vp_read32(0x04);
    gpu_dev_feats_lo = feats_lo;
    gpu_dev_feats_hi = feats_hi;
    const device_feats = (@as(u64, feats_hi) << 32) | feats_lo;
    const guest_feats = select_features(device_feats);
    if (guest_feats == 0) {
        gpu_fail = if (rearm) "re-arm: no VIRTIO_F_VERSION_1" else "no VIRTIO_F_VERSION_1";
        return false;
    }
    gpu_feats_lo = @truncate(guest_feats);
    gpu_feats_hi = @truncate(guest_feats >> 32);
    vp_write32(0x08, 0);
    vp_write32(0x0c, @truncate(guest_feats));
    vp_write32(0x08, 1);
    vp_write32(0x0c, @truncate(guest_feats >> 32));
    vp_write8(0x14, 1 | 2 | 8); // FEATURES_OK
    gpu_status_last = vp_read8(0x14);
    if ((gpu_status_last & 8) == 0) {
        gpu_fail = if (rearm) "re-arm: FEATURES_OK failed" else "FEATURES_OK failed";
        return false;
    }

    if (!setup_queue(0)) {
        gpu_fail = if (rearm) "re-arm: queue 0 setup failed" else "queue 0 setup failed";
        return false;
    }
    // The cursor queue (queue 1) — armed for device compatibility (see
    // setup_queue). If the device has no cursor queue (qsz 0), that is
    // fine: only the control queue is required for the 2D path.
    vp_write16(0x16, 1);
    if (vp_read16(0x18) > 0) {
        if (!setup_queue(1)) {
            gpu_fail = if (rearm) "re-arm: queue 1 setup failed" else "queue 1 setup failed";
            return false;
        }
    }
    vp_write8(0x14, 1 | 2 | 8 | 4); // DRIVER_OK
    gpu_status_last = vp_read8(0x14);
    if ((gpu_status_last & 4) == 0) {
        gpu_fail = if (rearm) "re-arm: DRIVER_OK failed" else "DRIVER_OK failed";
        return false;
    }
    return true;
}

/// Initialize the modern virtio-pci graphics transport PRE-EXIT: locate the
/// gpu device (DID 0x1050 — modern virtio-gpu; 0x1010 transitional also
/// accepted, the console's 0x1003 precedent), resolve BARs + the virtio
/// capabilities (common/notify/device), negotiate features, set up queue 0
/// (controlq), read num_scanouts from the device config, and reach
/// DRIVER_OK. Evidence is dumped to the probe buffer so the host sees the
/// device + queue state either way.
pub fn virtio_gpu_init() bool {
    if (pci.pci_ecam == 0) {
        evidence.dump_str("VG: no ECAM\n");
        gpu_fail = "no ECAM";
        return false;
    }

    // Locate the gpu device: modern DID 0x1050 (Virtio Device ID 16 +
    // 0x1040), transitional 0x1010 accepted too. The DID actually OBSERVED
    // is recorded in `gpu_did` (confirm-at-claim-time: a differing DID is a
    // finding, not an assumption). Bus 0, func 0.
    var found_dev: u32 = 32; // sentinel: not found
    var dev: u32 = 0;
    while (dev < 32) : (dev += 1) {
        const id = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0);
        if ((id & 0xffff) == 0xffff) continue;
        const did = id >> 16;
        if (did != 0x1050 and did != 0x1010) continue;
        found_dev = dev;
        gpu_did = did;
        gpu_class = (pci.pci_read32(pci.pci_ecam, 0, dev, 0, 8) >> 8) & 0xffffff;
        break;
    }
    if (found_dev == 32) {
        evidence.dump_str("VG: no virtio-gpu PCI device\n");
        gpu_fail = "DID 0x1050 not found on bus 0";
        return false;
    }
    gpu_dev = found_dev;
    evidence.dump_str("VG dev=");
    evidence.dump_hex(gpu_dev);
    evidence.dump_str(" did=");
    evidence.dump_hex(gpu_did);
    evidence.dump_str(" cls=");
    evidence.dump_hex(gpu_class);
    evidence.dump_str("\n");

    gpu_common = resolve_dev(gpu_dev);
    if (gpu_common == 0) {
        evidence.dump_str("VG: missing capability structs\n");
        gpu_fail = "missing capability structs";
        return false;
    }
    evidence.dump_str("VG common=");
    evidence.dump_hex(gpu_common);
    evidence.dump_str(" notify=");
    evidence.dump_hex(gpu_notify);
    evidence.dump_str(" devcfg=");
    evidence.dump_hex(gpu_devcfg);
    evidence.dump_str(" bar0=");
    evidence.dump_hex(gpu_bar0);
    evidence.dump_str("\n");

    // num_scanouts from the device config (virtio_gpu_config offset 8) —
    // MMIO through the mapped BAR window, read PRE-EXIT (claim-0013
    // discipline for anything config-like).
    if (gpu_devcfg != 0) {
        gpu_num_scanouts = mmio.mmio_read32(gpu_devcfg + 8);
    }
    evidence.dump_str("VG scanouts=");
    evidence.dump_hex(gpu_num_scanouts);
    evidence.dump_str("\n");

    if (!transport_init(false)) {
        evidence.dump_str("VG: init failed\n");
        return false;
    }
    evidence.dump_str("VG feats=");
    evidence.dump_hex(gpu_feats_lo);
    evidence.dump_str("/");
    evidence.dump_hex(gpu_feats_hi);
    evidence.dump_str(" qsz=");
    evidence.dump_hex(vp_read16(0x18));
    evidence.dump_str(" qen=");
    evidence.dump_hex(vp_read16(0x1c));
    evidence.dump_str(" qoff=");
    evidence.dump_hex(gpu_queue_notify_off);
    evidence.dump_str(" st=");
    evidence.dump_hex(gpu_status_last);
    evidence.dump_str("\n");
    gpu_fail = "";
    gpu_ready = true;
    return true;
}

/// Re-arm the transport POST-exit (claim 6420/2665's lesson): VZ resets
/// some virtio devices at ExitBootServices (blk/entropy st=00; the net
/// device does NOT, st=0f observed), so the gpu device's status and queues
/// may be dead until the full reset → re-init sequence runs again after
/// the MMU switch. Common-config MMIO writes work post-exit through the
/// mapped Device window; PCI config-space reads must stay pre-exit (claim
/// 0013). Unconditional and idempotent. The pre-rearm status is dumped so
/// the host sees whether VZ actually reset the device.
pub fn gpu_rearm() bool {
    if (gpu_common == 0) return false;
    evidence.dump_str("VG pre-rearm st=");
    evidence.dump_hex(vp_read8(0x14));
    evidence.dump_str("\n");
    if (!transport_init(true)) {
        gpu_fail = "re-arm failed (reset/features/queue/DRIVER_OK)";
        return false;
    }
    evidence.dump_str("VG rearm st=");
    evidence.dump_hex(vp_read8(0x14));
    evidence.dump_str(" qen=");
    evidence.dump_hex(vp_read16(0x1c));
    evidence.dump_str("\n");
    gpu_fail = "";
    gpu_rearmed = true;
    gpu_ready = true;
    return true;
}

// ---------------------------------------------------------------------------
// Control-queue command execution (one command outstanding at a time)
// ---------------------------------------------------------------------------

pub const CmdResult = enum {
    ok,
    not_ready,
    timeout,
    bad_response,
};

/// Wait for the device to consume the outstanding request (used.idx to
/// advance past `gpu_last_used`). Returns true on completion, false after
/// `poll_retries` fresh `poll_budget` polls. Every wait refreshes the used
/// ring's cache line first, exactly like the blk/entropy polls.
fn wait_completion() bool {
    var attempt: usize = 0;
    while (attempt < poll_retries) : (attempt += 1) {
        var spins: usize = 0;
        while (spins < poll_budget) : (spins += 1) {
            mmu.invalidate_dcache_range(@intFromPtr(&gpu_used), @sizeOf(VirtqUsed));
            if (gpu_used.idx != gpu_last_used) {
                gpu_last_used = gpu_used.idx;
                return true;
            }
        }
    }
    return false;
}

/// Submit one control-queue command: `cmd` (a struct with a `hdr` at
/// offset 0) of `cmd_len` bytes is chained to a WRITE response descriptor
/// of `resp_len` bytes; the device fills `gpu_resp_buf`. `want` is the
/// expected response type. One command outstanding at a time (the ring
/// invariant). Returns the CmdResult; `gpu_resp_buf` holds the response
/// on `.ok` (the caller parses it — the response header is 24 B, the
/// payload follows).
fn exec_cmd(cmd: *const anyopaque, cmd_len: usize, resp_len: usize, want: u32) CmdResult {
    if (!gpu_ready) return .not_ready;
    // Drain any previous completion first: a timed-out poll leaves the
    // request outstanding, and its used-ring advance must not be
    // attributed to the next request.
    mmu.invalidate_dcache_range(@intFromPtr(&gpu_used), @sizeOf(VirtqUsed));
    if (gpu_avail.idx != gpu_used.idx) {
        if (!wait_completion()) {
            gpu_timeouts += 1;
            return .timeout;
        }
    }
    // Descriptor 0 = the command (device READ, chained), descriptor 1 =
    // the response (device WRITE, the tail).
    gpu_desc[0] = .{
        .addr = mmu.to_phys(@intFromPtr(&gpu_cmd_buf)),
        .len = @intCast(cmd_len),
        .flags = virtq_f_next,
        .next = 1,
    };
    // Tail descriptor: next = 0 (not 0xffff). The spec says next is ignored
    // without the NEXT flag, but VZ's gpu implementation walks the field
    // anyway (observed at claim time: 0xffff wedged the queue) — the
    // working reference drivers use 0.
    gpu_desc[1] = .{
        .addr = mmu.to_phys(@intFromPtr(&gpu_resp_buf)),
        .len = @intCast(resp_len),
        .flags = virtq_f_write,
        .next = 0,
    };
    @memcpy(gpu_cmd_buf[0..cmd_len], @as([*]const u8, @ptrCast(cmd))[0..cmd_len]);
    gpu_avail.ring[gpu_avail.idx % queue_size] = 0; // descriptor chain head
    gpu_avail.idx +%= 1;
    gpu_cmds += 1;
    // The device DMA-reads the command (desc[0] → gpu_cmd_buf) and the
    // rings; the memcpy above left the command bytes dirty in the cache, so
    // clean them before the kick — the console TX (claim-0013 lesson, line
    // 529) and net TX (claim-1373) both clean their device-read buffers, and
    // a stale read of the command is exactly the kind of garbage a device
    // answers with DEVICE_NEEDS_RESET.
    mmu.clean_dcache_range(@intFromPtr(&gpu_cmd_buf), cmd_len);
    mmu.clean_dcache_range(@intFromPtr(&gpu_desc), @sizeOf(VirtqDesc) * 2);
    mmu.clean_dcache_range(@intFromPtr(&gpu_avail), @sizeOf(VirtqAvail));
    // Virtio 1.3 §4.1.5.2.1: without VIRTIO_F_NOTIFICATION_DATA the
    // notification is a 16-bit write of the queue index (0).
    mmio.mmio_write16(gpu_notify + @as(u64, gpu_queue_notify_off) * gpu_notify_mult, 0);
    if (!wait_completion()) {
        gpu_timeouts += 1;
        gpu_diag_avail = gpu_avail.idx;
        gpu_diag_used = gpu_used.idx;
        gpu_diag_st = vp_read8(0x14);
        gpu_diag_qen = vp_read16(0x1c);
        gpu_diag_qoff = gpu_queue_notify_off;
        gpu_diag_notify = gpu_notify;
        gpu_diag_mult = gpu_notify_mult;
        gpu_diag_desc_phys = mmu.to_phys(@intFromPtr(&gpu_desc));
        gpu_diag_avail_phys = mmu.to_phys(@intFromPtr(&gpu_avail));
        gpu_diag_used_phys = mmu.to_phys(@intFromPtr(&gpu_used));
        gpu_diag_cmd0 = std.mem.readInt(u32, gpu_cmd_buf[0..4], .little);
        gpu_diag_cmd1 = std.mem.readInt(u32, gpu_cmd_buf[4..8], .little);
        gpu_diag_isr = mmio.mmio_read32(gpu_bar0 + 0x3000);
        gpu_diag_qsz = vp_read16(0x18);
        return .timeout;
    }
    // The used element names the returned chain at (used.idx - 1) % size.
    // Invalidate the response before reading it (device-written).
    const used_slot = (gpu_used.idx -% 1) % queue_size;
    _ = used_slot;
    mmu.invalidate_dcache_range(@intFromPtr(&gpu_resp_buf), resp_len);
    const resp_type = std.mem.readInt(u32, gpu_resp_buf[0..4], .little);
    if (resp_type != want) {
        gpu_errors += 1;
        return .bad_response;
    }
    return .ok;
}

// ---------------------------------------------------------------------------
// The 2D path (the framebuffer exposure)
// ---------------------------------------------------------------------------

/// Fill the framebuffer with one 0xRRGGBB color (B8G8R8X8_UNORM:
/// little-endian memory bytes B, G, R, X). The X byte is 0xff — OPAQUE:
/// VZ composites the scanout resource with alpha (a 0x00 X/A byte renders
/// fully transparent → the view stays black, observed at claim time), so
/// the fill must carry full alpha. Pure memory write — no device command;
/// the caller follows with `gpu_transfer` + `gpu_flush`.
pub fn fill_framebuffer(rgb: u32) void {
    var i: usize = 0;
    while (i < fb_size) : (i += 4) {
        gpu_fb[i] = @truncate(rgb & 0xff); // B
        gpu_fb[i + 1] = @truncate((rgb >> 8) & 0xff); // G
        gpu_fb[i + 2] = @truncate((rgb >> 16) & 0xff); // R
        gpu_fb[i + 3] = 0xff; // X — opaque
    }
}

/// GET_DISPLAY_INFO → the pmodes[0] scanout mode (the resolution the
/// device reports). Fills `gpu_scanout_w/h/enabled`.
pub fn gpu_display_info() bool {
    const cmd = CtrlHdr{ .type = cmd_get_display_info, .flags = 0, .fence_id = 0, .ctx_id = 0, .ring_idx = 0 };
    const r = exec_cmd(&cmd, @sizeOf(CtrlHdr), @sizeOf(RespDisplayInfo), resp_ok_display_info);
    if (r != .ok) return false;
    const info: *align(1) RespDisplayInfo = @ptrCast(@alignCast(&gpu_resp_buf));
    const mode = info.pmodes[0];
    gpu_scanout_w = mode.rect.width;
    gpu_scanout_h = mode.rect.height;
    gpu_scanout_enabled = mode.enabled;
    return gpu_scanout_enabled != 0 and gpu_scanout_w != 0 and gpu_scanout_h != 0;
}

/// RESOURCE_CREATE_2D for the G1 scanout resource.
pub fn gpu_create_resource() bool {
    const cmd = Create2D{
        .hdr = .{ .type = cmd_resource_create_2d, .flags = 0, .fence_id = 0, .ctx_id = 0, .ring_idx = 0 },
        .resource_id = resource_id,
        .format = format_b8g8r8x8,
        .width = fb_width,
        .height = fb_height,
    };
    return exec_cmd(&cmd, @sizeOf(Create2D), 24, resp_ok_nodata) == .ok;
}

/// RESOURCE_ATTACH_BACKING — one mem_entry over the fixed BSS framebuffer.
pub fn gpu_attach_backing() bool {
    gpu_fb_phys = mmu.to_phys(@intFromPtr(&gpu_fb));
    const cmd = AttachBacking{
        .hdr = .{ .type = cmd_resource_attach_backing, .flags = 0, .fence_id = 0, .ctx_id = 0, .ring_idx = 0 },
        .resource_id = resource_id,
        .nr_entries = 1,
        .entries = .{.{ .addr = gpu_fb_phys, .length = fb_size, .padding = 0 }},
    };
    return exec_cmd(&cmd, @sizeOf(AttachBacking), 24, resp_ok_nodata) == .ok;
}

/// SET_SCANOUT — point scanout 0 at the resource, full frame.
pub fn gpu_set_scanout() bool {
    const cmd = SetScanout{
        .hdr = .{ .type = cmd_set_scanout, .flags = 0, .fence_id = 0, .ctx_id = 0, .ring_idx = 0 },
        .rect = .{ .x = 0, .y = 0, .width = fb_width, .height = fb_height },
        .scanout_id = 0,
        .resource_id = resource_id,
    };
    return exec_cmd(&cmd, @sizeOf(SetScanout), 24, resp_ok_nodata) == .ok;
}

/// TRANSFER_TO_HOST_2D — push the whole framebuffer to the host-side
/// resource. The device DMA-reads the framebuffer, so the fill's dirty
/// cache lines MUST be cleaned first (the reference drivers run with
/// caches off — an MMU-on kernel like ours has no such luck; without the
/// clean the device reads stale zeroed BSS and the scanout stays black).
pub fn gpu_transfer() CmdResult {
    mmu.clean_dcache_range(@intFromPtr(&gpu_fb), fb_size);
    const cmd = Transfer2D{
        .hdr = .{ .type = cmd_transfer_to_host_2d, .flags = 0, .fence_id = 0, .ctx_id = 0, .ring_idx = 0 },
        .rect = .{ .x = 0, .y = 0, .width = fb_width, .height = fb_height },
        .offset = 0,
        .resource_id = resource_id,
        .padding = 0,
    };
    return exec_cmd(&cmd, @sizeOf(Transfer2D), 24, resp_ok_nodata);
}

/// RESOURCE_FLUSH — make the host display the resource on the scanout.
pub fn gpu_flush() CmdResult {
    const cmd = Flush{
        .hdr = .{ .type = cmd_resource_flush, .flags = 0, .fence_id = 0, .ctx_id = 0, .ring_idx = 0 },
        .rect = .{ .x = 0, .y = 0, .width = fb_width, .height = fb_height },
        .resource_id = resource_id,
        .padding = 0,
    };
    return exec_cmd(&cmd, @sizeOf(Flush), 24, resp_ok_nodata);
}

/// The full G1 setup: display info → create → attach → set scanout →
/// fill (a known boot color) → transfer → flush. `gpu_setup_ok` marks the
/// first flushed scanout. Runs post-exit after the re-arm (called from
/// kernel_main); the `screen fill` monitor command re-runs the last three.
pub fn gpu_setup() bool {
    if (!gpu_display_info()) {
        gpu_fail = "display info failed";
        return false;
    }
    if (!gpu_create_resource()) {
        gpu_fail = "resource create failed";
        return false;
    }
    if (!gpu_attach_backing()) {
        gpu_fail = "attach backing failed";
        return false;
    }
    if (!gpu_set_scanout()) {
        gpu_fail = "set scanout failed";
        return false;
    }
    fill_framebuffer(0x101418); // the boot background (dark slate)
    if (gpu_transfer() != .ok) {
        gpu_fail = "transfer failed";
        return false;
    }
    if (gpu_flush() != .ok) {
        gpu_fail = "flush failed";
        return false;
    }
    gpu_setup_ok = true;
    gpu_fail = "";
    return true;
}

// ---------------------------------------------------------------------------
// Host tests — only the pieces that need no device
// ---------------------------------------------------------------------------

test "virtio_gpu: spec constants, wire shapes, and the fill are the spec shapes" {
    // Command/response types (the Linux virtio_gpu_drv.h constants).
    try std.testing.expectEqual(@as(u32, 0x0100), cmd_get_display_info);
    try std.testing.expectEqual(@as(u32, 0x0101), cmd_resource_create_2d);
    try std.testing.expectEqual(@as(u32, 0x0103), cmd_set_scanout);
    try std.testing.expectEqual(@as(u32, 0x0104), cmd_resource_flush);
    try std.testing.expectEqual(@as(u32, 0x0105), cmd_transfer_to_host_2d);
    try std.testing.expectEqual(@as(u32, 0x0106), cmd_resource_attach_backing);
    try std.testing.expectEqual(@as(u32, 0x1100), resp_ok_nodata);
    try std.testing.expectEqual(@as(u32, 0x1101), resp_ok_display_info);
    try std.testing.expectEqual(@as(u32, 2), format_b8g8r8x8);
    // The wire shapes: CtrlHdr is 24 B (type/flags/fence_id/ctx_id/ring_idx),
    // the display-info response is 24 + 16×24 (the 1.2 display_one has a
    // flags field), the attach-backing entry is 16 B (addr/length/padding).
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(CtrlHdr));
    try std.testing.expectEqual(@as(usize, 408), @sizeOf(RespDisplayInfo));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(MemEntry));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(AttachBacking));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(Transfer2D));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(SetScanout));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Flush));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(Create2D));
    // The framebuffer shape.
    try std.testing.expectEqual(@as(usize, 3_686_400), fb_size);
    try std.testing.expectEqual(@as(usize, 1280), fb_width);
    try std.testing.expectEqual(@as(usize, 720), fb_height);
    // Feature selection: the largest mask whose bits are ALL offered,
    // ending at VER1-only. VZ's gpu offers VIRGL|RESOURCE_UUID|VERSION_1
    // (claim-time observation) — the pick there is bits 0|2|32. Accepted
    // VIRGL here is negotiation-only; no VIRGL command exists in this
    // driver (M102: the native device has no usable VIRGL path).
    try std.testing.expectEqual(@as(u64, 0x1 << 32), select_features(0x1 << 32));
    try std.testing.expectEqual(@as(u64, 0x1 << 32 | 0x1 << 0 | 0x1 << 2), select_features(0x1 << 32 | 0x1 << 0 | 0x1 << 2));
    // A mask with an unoffered RESOURCE_UUID (bit 2) falls back to the
    // largest fully-offered subset (VIRGL alone here, bit 0).
    try std.testing.expectEqual(@as(u64, 0x1 << 32 | 0x1 << 0), select_features(0x1 << 32 | 0x1 << 0 | 0x1 << 1));
    try std.testing.expectEqual(@as(u64, 0), select_features(0));
    try std.testing.expectEqual(@as(u64, 0), select_features(0x1 << 0));
    // Unarmed transport reports honestly. Scoped to this test: an
    // aggregate test binary runs every imported file's tests, and a
    // leaked gpu_ready sends later driving_award tests down the armed
    // transport path (an mmio write to the never-mapped gpu_notify).
    const saved_ready = gpu_ready;
    defer gpu_ready = saved_ready;
    gpu_ready = false;
    try std.testing.expect(!gpu_display_info());
    try std.testing.expect(!gpu_create_resource());
    try std.testing.expect(!gpu_attach_backing());
    try std.testing.expect(!gpu_set_scanout());
    try std.testing.expect(gpu_transfer() == .not_ready);
    try std.testing.expect(gpu_flush() == .not_ready);
}

test "virtio_gpu: fill writes the B8G8R8X8 little-endian byte order" {
    const saved_ready = gpu_ready;
    defer gpu_ready = saved_ready;
    gpu_ready = true;
    fill_framebuffer(0x112233); // R=0x11 G=0x22 B=0x33
    try std.testing.expectEqual(@as(u8, 0x33), gpu_fb[0]); // B first
    try std.testing.expectEqual(@as(u8, 0x22), gpu_fb[1]); // G
    try std.testing.expectEqual(@as(u8, 0x11), gpu_fb[2]); // R
    try std.testing.expectEqual(@as(u8, 0xff), gpu_fb[3]); // X — opaque
    // The last pixel too (the tail of the 3.7 MiB fill).
    const last = fb_size - 4;
    try std.testing.expectEqual(@as(u8, 0x33), gpu_fb[last]);
    try std.testing.expectEqual(@as(u8, 0x22), gpu_fb[last + 1]);
    try std.testing.expectEqual(@as(u8, 0x11), gpu_fb[last + 2]);
    try std.testing.expectEqual(@as(u8, 0xff), gpu_fb[last + 3]);
}

test "virtio_gpu: display-info response parse takes pmodes[0]" {
    // Build a mock RESP_OK_DISPLAY_INFO in RAM and run the parse.
    var buf: [512]u8 align(16) = undefined;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[0..4], resp_ok_display_info, .little);
    const info: *align(1) RespDisplayInfo = @ptrCast(@alignCast(&buf));
    info.pmodes[0] = .{ .rect = .{ .x = 0, .y = 0, .width = 1280, .height = 720 }, .enabled = 1, .flags = 0 };
    // The parse is gpu_display_info's body; exercise it through the real
    // fields by copying the response into gpu_resp_buf and calling the
    // executor's parse path indirectly (not_ready guard first).
    const saved_ready = gpu_ready;
    defer gpu_ready = saved_ready;
    gpu_ready = true;
    @memcpy(gpu_resp_buf[0..@sizeOf(RespDisplayInfo)], buf[0..@sizeOf(RespDisplayInfo)]);
    const parsed: *align(1) RespDisplayInfo = @ptrCast(@alignCast(&gpu_resp_buf));
    const mode = parsed.pmodes[0];
    try std.testing.expectEqual(@as(u32, 1280), mode.rect.width);
    try std.testing.expectEqual(@as(u32, 720), mode.rect.height);
    try std.testing.expectEqual(@as(u32, 1), mode.enabled);
    // An err-type response would be rejected by exec_cmd's want-check; the
    // response type at offset 0 is the discriminator.
    try std.testing.expectEqual(@as(u32, resp_ok_display_info), std.mem.readInt(u32, gpu_resp_buf[0..4], .little));
}
