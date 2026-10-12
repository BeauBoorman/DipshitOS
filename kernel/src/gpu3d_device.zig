//! VirelaiOS experimental GPU3D render channel — guest transport and
//! context lifecycle (M102b1, issue #2162 — card of the M102 index,
//! issue #2160).
//!
//! The device is the owner-approved second custom-virtio channel:
//! virtio device ID 0x43 (PCI VID 0x1af4, DID 0x1083 = 0x1040 + 0x43 —
//! the sibling of the 0x42 host channel), PCI class 0x00/0x00, found
//! through the MCFG ECAM base exactly like the console/blk/custom
//! devices. It speaks virtio-gpu CONTROL-queue envelopes carrying the
//! private VIR1 capability profile (gpu3d_wire.zig) — it is NOT a second
//! virtio-gpu: the native 1af4:1050 2D device keeps its own BAR, rings
//! and scanout path and is never touched here.
//!
//! Two phases, split by the ExitBootServices boundary (the claim-0013
//! discipline):
//!
//!   1. DISCOVERY (PRE-EXIT, `probe`): config-space reads only — find
//!      DID 0x1083 and resolve the common/notify capability addresses +
//!      the transport BAR base. Absent means UNSUPPORTED, not a boot
//!      failure: `probe` returns false and every gate is byte-identical.
//!   2. PROGRAMMING (POST-MMU, `init`): enable memory space (the firmware
//!      leaves custom devices at command=0x10, claim 0828) -> reset ->
//!      ACKNOWLEDGE|DRIVER -> negotiate VERSION_1 (+ VIRGL/CONTEXT_INIT
//!      when offered, the stream envelope's feature bits) -> FEATURES_OK
//!      -> arm queue 0 (a split ring SEPARATE from every native ring)
//!      -> DRIVER_OK.
//!
//! The exchange interface (c1's seam, #2160 §10): `exchange` takes the
//! wire-encoded request bytes, posts them with a bounded reply descriptor
//! on the control queue, polls for completion, and returns validated
//! metadata. One request outstanding at a time (#2160 §3); request and
//! response backing stay kernel-owned and pinned for the whole exchange.
//! Completion is NEVER reply-type-only: the used descriptor id AND
//! length, the response type, the echoed ctx_id and the full u64 fence id
//! all have to match before a request counts as done — a delayed old
//! completion cannot satisfy a later request. A timed-out chain is
//! PARKED, not recycled (the claim-#899 parked-chain discipline), so its
//! head can never be reallocated under a late reply.
//!
//! The transport itself is an injected ops table (`transport`): the
//! device init wires the real ring path; host tests substitute a fake
//! device transcript that records every request byte and synthesizes the
//! contract replies — that is the class-A evidence this card owes (the
//! VZ guest render is f2's evidence, not invented here).
//!
//! Contexts: at most `max_contexts` (2, pinned by the VIR1 profile) live
//! system-wide. `ctx_create` refuses by name: device absent, caps not
//! yet validated, ctx_id 0, an already-live ctx_id, or an id beyond the
//! profile's bound — each refusal happens BEFORE anything is submitted
//! and leaks no slot. `ctx_destroy` validates a generation-bearing
//! handle: a stale or replayed handle can never retire a live context.
//!
//! No libc, no POSIX, no allocation, no interrupts.

const std = @import("std");
const builtin = @import("builtin");
const mmio = @import("mmio.zig");
const mmu = @import("mmu.zig");
const pci = @import("pci.zig");
const evidence = @import("evidence.zig");
const wire = @import("gpu3d_wire.zig");

// ---------------------------------------------------------------------------
// Device identity + bounds (owner-approved, issue #2160 §1/§3)
// ---------------------------------------------------------------------------

/// The render channel's PCI device ID (0x1040 + deviceID 0x43).
pub const g3_did: u32 = 0x1083;
/// Virtio device ID (the DID's low byte).
pub const g3_device_id: u32 = 0x43;
/// Split-ring size for the ONE control queue: 8 (power of two, Virtio 1.3
/// §4.1.4.3). Two descriptors per element -> four in flight; parked
/// chains after timeouts have headroom under the one-outstanding rule.
pub const queue_size: u16 = 8;
/// The only virtqueue: the control queue.
pub const ctrl_qidx: u16 = 0;
/// Request staging: the contract's SUBMIT_3D bound (#2160 §3: a 32-byte
/// envelope plus a ≤ 4096-byte word-aligned stream). b1's four commands
/// are ≤ 96 bytes; the staging is sized for the whole milestone so a
/// later card's stream never needs a new buffer.
pub const req_staging_len: usize = 4128;
/// Reply buffer capacity (capset replies are 40/56 bytes; nodata is 24).
pub const resp_cap_max: usize = 512;
/// Two contexts system-wide (#2160 §3) — the VIR1 profile's `contexts`.
pub const max_contexts: usize = 2;
/// One logical completion deadline for a control exchange (the 2 s
/// contract's control-path analog; the render deadline itself belongs to
/// the stream card). Polls are bounded spins, never a syscall wait. A
/// var so host tests can shorten the timeout path.
pub var exchange_budget: usize = 16_000_000;
/// The transport BAR window mapped into the identity map (VZ exposes
/// 64 KiB BARs — the console/custom precedent).
pub const bar_window_len: u64 = 0x10000;

// ---------------------------------------------------------------------------
// Discovery state (PRE-EXIT; read by main.zig for the identity-map window)
// ---------------------------------------------------------------------------

/// Render device PCI device number, or 32 (sentinel) when absent.
pub var g3_dev: u32 = 32;
/// Common-config struct address (BAR + cap offset), pre-exit resolved.
pub var g3_common: u64 = 0;
/// Notify region base (BAR + cap offset), pre-exit resolved.
pub var g3_notify: u64 = 0;
/// notify_off_multiplier (0 when the cap lacks it).
pub var g3_notify_mult: u32 = 0;
/// Transport BAR base holding the common cfg (the identity-map window).
pub var g3_bar: u64 = 0;
/// Transport armed (DRIVER_OK set, queue 0 live).
pub var g3_ready: bool = false;
/// The OBSERVED PCI class (recorded, not assumed — the custom family's
/// 0x00/0x00 is the expected value).
pub var g3_class: u32 = 0;
/// The OBSERVED device-features word (offered) and the accepted mask.
pub var g3_dev_feats: u64 = 0;
pub var g3_feats: u64 = 0;
/// Honest failure reason (reported by main.zig when not ready).
pub var g3_fail: []const u8 = "";
/// Exchange counters (the report): commands submitted, non-OK/invalid
/// responses, completion timeouts.
pub var g3_cmds: u64 = 0;
pub var g3_errors: u64 = 0;
pub var g3_timeouts: u64 = 0;

/// Feature bits this device may offer (#2160 §2): the custom device MAY
/// offer VIRTIO_GPU_F_VIRGL (bit 0) for its stream envelope — accepted
/// when offered — and VIRTIO_GPU_F_CONTEXT_INIT (bit 4); VERSION_1 is
/// mandatory. The private capability match is additionally mandatory
/// (`probe_caps`), so an offer here is never sufficient on its own.
const vf_version_1: u64 = @as(u64, 1) << 32;
const vf_gpu_virgl: u64 = @as(u64, 1) << 0;
const vf_gpu_context_init: u64 = @as(u64, 1) << 4;

/// PRE-EXIT probe (config-space reads only): find DID 0x1083 on bus 0
/// and resolve the common/notify capability addresses + the transport BAR
/// base. Returns true when the device is present; main.zig then maps
/// `device_window()` into the identity map. Absent -> false -> the
/// feature is unsupported, never a boot failure.
pub fn probe() bool {
    if (pci.pci_ecam == 0) return false;

    var found_dev: u32 = 32;
    var dev: u32 = 0;
    while (dev < 32) : (dev += 1) {
        const id = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0);
        if ((id & 0xffff) == 0xffff) continue;
        const did = id >> 16;
        if (did != g3_did) continue;
        // The custom-virtio family identity (the 0x42 channel's class).
        const cls = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 8) >> 8;
        g3_class = cls;
        if (cls != 0x000000) continue;
        found_dev = dev;
        break;
    }
    if (found_dev == 32) return false;
    g3_dev = found_dev;

    var bar_base: [6]u64 = @splat(0);
    var bi: usize = 0;
    while (bi < 6) : (bi += 1) {
        const low = pci.pci_read32(pci.pci_ecam, 0, found_dev, 0, 0x10 + @as(u32, @intCast(bi)) * 4);
        if ((low & 1) != 0) continue;
        const base: u64 = low & ~@as(u32, 0xf);
        bar_base[bi] = base;
        if (((low >> 1) & 0x3) == 2 and bi + 1 < 6) {
            const high = pci.pci_read32(pci.pci_ecam, 0, found_dev, 0, 0x10 + @as(u32, @intCast(bi + 1)) * 4);
            bar_base[bi] |= @as(u64, high) << 32;
            bi += 1;
        }
    }

    // Walk the vendor-specific capability list (aligned u32 reads only —
    // the claim-0013 quirk). cfg_type 1 = common, 2 = notify (+mult).
    const cap_ptr = pci.pci_read32(pci.pci_ecam, 0, found_dev, 0, 0x34) & 0xff;
    evidence.dump_str("G3PROBE dev=");
    evidence.dump_hex(found_dev);
    evidence.dump_str(" cp=");
    evidence.dump_hex(cap_ptr);
    evidence.dump_str("\n");
    var common_bar: u32 = 0;
    var common_off: u32 = 0;
    var notify_bar: u32 = 0;
    var notify_off: u32 = 0;
    var notify_mult: u32 = 0;
    var found_common = false;
    var found_notify = false;
    var c: u32 = cap_ptr;
    var cap_count: usize = 0;
    while (c != 0 and c < 0x100 and (c & 3) == 0 and cap_count < 16) : (cap_count += 1) {
        const head = pci.pci_read32(pci.pci_ecam, 0, found_dev, 0, c);
        const id = head & 0xff;
        const next = (head >> 8) & 0xff;
        if (id == 0x09) {
            const cfg_type = (head >> 24) & 0xff;
            const bar = pci.pci_read32(pci.pci_ecam, 0, found_dev, 0, c + 4) & 0xff;
            const off = pci.pci_read32(pci.pci_ecam, 0, found_dev, 0, c + 8);
            switch (cfg_type) {
                1 => {
                    common_bar = bar;
                    common_off = off;
                    found_common = true;
                },
                2 => {
                    notify_bar = bar;
                    notify_off = off;
                    notify_mult = pci.pci_read32(pci.pci_ecam, 0, found_dev, 0, c + 16);
                    found_notify = true;
                },
                else => {},
            }
        }
        c = next;
    }
    if (!found_common or !found_notify or common_bar >= 6 or notify_bar >= 6) return false;
    g3_common = bar_base[common_bar] + common_off;
    g3_notify = bar_base[notify_bar] + notify_off;
    g3_notify_mult = notify_mult;
    g3_bar = bar_base[common_bar];
    return true;
}

/// The identity-map Device window covering the transport BAR (added by
/// main.zig next to the other transport windows).
pub fn device_window() mmu.DeviceWindow {
    return .{ .base = g3_bar, .len = bar_window_len };
}

// ---------------------------------------------------------------------------
// The control-queue ring (SEPARATE from every native-GPU ring)
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
    used_event: u16,
};
const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};
const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
    ring: [queue_size]VirtqUsedElem,
    avail_event: u16,
};

const vq_next: u16 = 0x1; // VIRTQ_DESC_F_NEXT
const vq_write: u16 = 0x2; // VIRTQ_DESC_F_WRITE

/// The one armed split virtqueue (control): descriptor table, avail/used
/// rings, free-list allocator, notify offset.
pub const Ring = struct {
    desc: [queue_size]VirtqDesc align(16) = undefined,
    avail: VirtqAvail align(2) = undefined,
    used: VirtqUsed align(4) = undefined,
    free: [queue_size]u16 = undefined,
    free_count: u16 = 0,
    last_used: u16 = 0,
    notify_off: u16 = 0,
    armed: bool = false,
};
pub var g3_ring: Ring = undefined;

/// Pinned request staging + reply buffer (BSS, stable physical addresses;
/// alive for the whole exchange — never caller memory the device reads
/// asynchronously).
var g3_req_staging: [req_staging_len]u8 align(16) = undefined;
var g3_resp_buf: [resp_cap_max]u8 align(16) = undefined;
/// The reply slice the outstanding element posted (stashed for the
/// completion-path invalidate).
var pending_resp: []u8 = g3_resp_buf[0..0];

/// Initialize the ring's tables + free list. BSS is not trusted zeroed,
/// so the used ring's init write is cleaned to RAM (the claim-0016
/// lesson). The free list is reversed so the LIFO hands out LOW indices
/// first (the claim-0828-proven VZ queue-parser pattern).
pub fn ring_init(r: *Ring) void {
    r.avail = .{ .flags = 0, .idx = 0, .ring = @as([queue_size]u16, @splat(@as(u16, 0))), .used_event = 0 };
    r.used = .{ .flags = 0, .idx = 0, .ring = @as([queue_size]VirtqUsedElem, @splat(@as(VirtqUsedElem, .{ .id = 0, .len = 0 }))), .avail_event = 0 };
    for (&r.free, 0..) |*f, i| f.* = @intCast(queue_size - 1 - i);
    r.free_count = queue_size;
    r.last_used = 0;
    r.armed = false;
    mmu.clean_dcache_range(@intFromPtr(&r.used), @sizeOf(VirtqUsed));
}

/// Pop `count` descriptors off the free list, linked head -> ... -> tail
/// (NEXT on all but the tail). Null when the list cannot satisfy it.
fn alloc_chain(r: *Ring, count: u16) ?u16 {
    if (count == 0 or count > r.free_count) return null;
    var head: ?u16 = null;
    var prev: ?u16 = null;
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        r.free_count -= 1;
        const idx = r.free[r.free_count];
        if (head == null) head = idx;
        if (prev) |p| r.desc[p].next = idx;
        r.desc[idx] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
        prev = idx;
    }
    var cur = head.?;
    var remaining = count;
    while (remaining > 1) : (remaining -= 1) {
        r.desc[cur].flags |= vq_next;
        cur = r.desc[cur].next;
    }
    return head;
}

/// Return a chain's descriptors to the free list (tail-first push, so a
/// freed chain hands the same head out again — the claim-4374
/// deterministic recycle shape).
fn free_chain(r: *Ring, head: u16) void {
    var chain: [queue_size]u16 = undefined;
    var n: usize = 0;
    var cur = head;
    while (true) {
        chain[n] = cur;
        n += 1;
        const flags = r.desc[cur].flags;
        const next = r.desc[cur].next;
        r.desc[cur] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
        if ((flags & vq_next) == 0) break;
        cur = next;
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        r.free[r.free_count] = chain[i];
        r.free_count += 1;
    }
}

// ---------------------------------------------------------------------------
// Parked-chain discipline (claim #899 — mirrored from virtio_custom)
// ---------------------------------------------------------------------------

/// A timed-out chain is PARKED — never returned to the free list — until
/// its used-ring entry is observed (its late reply is then known to have
/// arrived). A parked head can never be misattributed to a later request.
pub var parked_heads: [queue_size / 2]u16 = undefined;
pub var parked_count: u16 = 0;

fn park_chain(head: u16) void {
    if (parked_count < parked_heads.len) {
        parked_heads[parked_count] = head;
        parked_count += 1;
    }
}

/// A consumed used entry carrying a parked id frees the parked chain; any
/// other unmatched id is a device fabrication — consumed, never freed.
fn reap_parked_id(id: u32) void {
    for (&parked_heads, 0..) |*h, idx| {
        if (h.* == id) {
            free_chain(&g3_ring, @intCast(id));
            parked_count -= 1;
            parked_heads[idx] = parked_heads[parked_count];
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// Common-cfg register access (natural size, the console's exact pattern)
// ---------------------------------------------------------------------------

fn vp_read8(off: u32) u8 {
    return mmio.mmio_read8(g3_common + off);
}

fn vp_write8(off: u32, value: u8) void {
    mmio.mmio_write8(g3_common + off, value);
}

fn vp_read16(off: u32) u16 {
    return mmio.mmio_read16(g3_common + off);
}

fn vp_write16(off: u32, value: u16) void {
    mmio.mmio_write16(g3_common + off, value);
}

fn vp_read32(off: u32) u32 {
    return mmio.mmio_read32(g3_common + off);
}

fn vp_write32(off: u32, value: u32) void {
    mmio.mmio_write32(g3_common + off, value);
}

/// Current device status (0xff when the transport was never discovered).
pub fn g3_status() u8 {
    if (g3_common == 0) return 0xff;
    return vp_read8(0x14);
}

/// Enable memory space + bus master + MWI on the PCI command register —
/// the firmware leaves custom devices at command = 0x10 (claim 0828), so
/// this driver performs the enumeration step it skips.
fn enable_memory_space() void {
    if (g3_dev >= 32) return;
    if (pci.pci_ecam == 0) return;
    pci.pci_write32(pci.pci_ecam, 0, g3_dev, 0, 0x04, 0x16);
}

/// POST-MMU transport init on the pre-exit-resolved addresses: enable
/// memory space -> reset -> ACKNOWLEDGE|DRIVER -> negotiate (VERSION_1
/// always; VIRGL/CONTEXT_INIT when offered) -> FEATURES_OK -> arm the
/// control queue -> DRIVER_OK. Unconditional and idempotent (the
/// claim-6420 re-arm shape). False -> `g3_fail` names the stage; the
/// feature is then unsupported, never a boot failure.
pub fn init() bool {
    if (g3_common == 0) return false;
    enable_memory_space();
    vp_write8(0x14, 0); // reset
    var reset_spins: usize = 0;
    while (vp_read8(0x14) != 0) : (reset_spins += 1) {
        if (reset_spins >= 1_000_000) {
            g3_fail = "reset timeout";
            return false;
        }
    }
    vp_write8(0x14, 1 | 2); // ACKNOWLEDGE | DRIVER

    vp_write32(0x00, 0);
    const feat_lo = vp_read32(0x04);
    vp_write32(0x00, 1);
    const feat_hi = vp_read32(0x04);
    vp_write32(0x00, 0);
    g3_dev_feats = (@as(u64, feat_hi) << 32) | feat_lo;
    if ((g3_dev_feats & vf_version_1) == 0) {
        g3_fail = "no VIRTIO_F_VERSION_1";
        return false;
    }
    // The stream-envelope bits are accepted when offered; the private
    // capability match (probe_caps) is what actually admits the device.
    g3_feats = vf_version_1 | (g3_dev_feats & (vf_gpu_virgl | vf_gpu_context_init));
    vp_write32(0x08, 0);
    vp_write32(0x0c, @truncate(g3_feats));
    vp_write32(0x08, 1);
    vp_write32(0x0c, @truncate(g3_feats >> 32));
    vp_write8(0x14, 1 | 2 | 8); // FEATURES_OK
    if ((vp_read8(0x14) & 8) == 0) {
        g3_fail = "FEATURES_OK failed";
        return false;
    }

    vp_write16(0x16, ctrl_qidx);
    const qsz = vp_read16(0x18);
    if (qsz == 0) {
        g3_fail = "no control queue";
        return false;
    }
    if (qsz < queue_size) {
        g3_fail = "control queue too small";
        return false;
    }
    vp_write16(0x18, queue_size);
    const r = &g3_ring;
    ring_init(r);
    // Queue GPAs are guest PHYSICAL (claim 5804) — translate kernel VAs.
    const qd = mmu.to_phys(@intFromPtr(&r.desc));
    mmio.mmio_write32(g3_common + 0x20, @truncate(qd));
    mmio.mmio_write32(g3_common + 0x24, @truncate(qd >> 32));
    const qa = mmu.to_phys(@intFromPtr(&r.avail));
    mmio.mmio_write32(g3_common + 0x28, @truncate(qa));
    mmio.mmio_write32(g3_common + 0x2c, @truncate(qa >> 32));
    const qu = mmu.to_phys(@intFromPtr(&r.used));
    mmio.mmio_write32(g3_common + 0x30, @truncate(qu));
    mmio.mmio_write32(g3_common + 0x34, @truncate(qu >> 32));
    vp_write16(0x1c, 1); // queue_enable
    r.notify_off = vp_read16(0x1e);
    r.armed = true;
    vp_write8(0x14, 1 | 2 | 8 | 4); // DRIVER_OK
    if ((vp_read8(0x14) & 4) == 0) {
        g3_fail = "DRIVER_OK failed";
        return false;
    }
    g3_fail = "";
    g3_ready = true;
    return true;
}

// ---------------------------------------------------------------------------
// The transport seam (injectable) — one request outstanding at a time
// ---------------------------------------------------------------------------

/// The transport ops: post one element (request bytes device-read + the
/// reply descriptor device-write), poll for ITS completion by used-ring
/// id, and release the chain (`completed=false` parks it). `init` wires
/// the real ring; host tests inject a fake device transcript.
pub const Transport = struct {
    submit: *const fn (req: []const u8, resp: []u8) ?u32,
    wait: *const fn (handle: u32, budget: usize) ?u32,
    release: *const fn (handle: u32, completed: bool) void,
};

fn ring_submit(req: []const u8, resp: []u8) ?u32 {
    const r = &g3_ring;
    if (!r.armed) return null;
    const head = alloc_chain(r, 2) orelse return null;
    // Descriptor 0: the request (device READ, chained). Descriptor 1: the
    // reply (device WRITE, tail next=0 — VZ walks the field, claim-time
    // observation on the gpu path).
    r.desc[head].addr = mmu.to_phys(@intFromPtr(req.ptr));
    r.desc[head].len = @intCast(req.len);
    r.desc[head].flags = vq_next;
    const tail = r.desc[head].next;
    r.desc[tail].addr = mmu.to_phys(@intFromPtr(resp.ptr));
    r.desc[tail].len = @intCast(resp.len);
    r.desc[tail].flags = vq_write;
    r.desc[tail].next = 0;
    pending_resp = resp;
    r.avail.ring[r.avail.idx % queue_size] = head;
    r.avail.idx +%= 1;
    if (comptime !builtin.is_test) {
        mmu.clean_dcache_range(@intFromPtr(req.ptr), req.len);
        mmu.clean_dcache_range(@intFromPtr(&r.desc), @sizeOf(VirtqDesc) * queue_size);
        mmu.clean_dcache_range(@intFromPtr(&r.avail), @sizeOf(VirtqAvail));
    }
    mmio.mmio_write16(g3_notify + @as(u64, r.notify_off) * g3_notify_mult, ctrl_qidx);
    return head;
}

fn ring_wait(handle: u32, budget: usize) ?u32 {
    const r = &g3_ring;
    if (!r.armed) return null;
    var i: usize = 0;
    while (i < budget) : (i += 1) {
        if (comptime !builtin.is_test) {
            mmu.invalidate_dcache_range(@intFromPtr(&r.used), @sizeOf(VirtqUsed));
        }
        if (r.used.idx != r.last_used) {
            const elem = r.used.ring[r.last_used % queue_size];
            r.last_used +%= 1;
            if (elem.id == handle) {
                // The device wrote the reply before publishing the used
                // entry — invalidate it for reading (EL0-illegal on host
                // tests, which stage memory directly).
                if (comptime !builtin.is_test) {
                    const n: usize = @min(@as(usize, elem.len), pending_resp.len);
                    mmu.invalidate_dcache_range(@intFromPtr(pending_resp.ptr), n);
                }
                return elem.len;
            }
            // Not our element: a stale completion. A parked head's reply
            // finally arrived -> reclaim it; anything else is fabricated
            // -> consumed, never attributed, never freed twice.
            reap_parked_id(elem.id);
        }
    }
    return null;
}

fn ring_release(handle: u32, completed: bool) void {
    if (!g3_ring.armed) return;
    if (completed) {
        free_chain(&g3_ring, @intCast(handle));
    } else {
        park_chain(@intCast(handle));
    }
}

/// The active transport (the real ring once `init` armed it; a test
/// injects the fake-device transcript instead).
pub var transport: Transport = .{
    .submit = ring_submit,
    .wait = ring_wait,
    .release = ring_release,
};

/// The one-outstanding-request record: which element is in flight and
/// which fence/context its reply must echo.
const Pending = struct {
    handle: u32,
    fence_id: u64,
    ctx_id: u32,
};
var pending: ?Pending = null;

/// Monotonic fence allocator — starts at 1 (0 means "no fence", which is
/// never a valid completion).
pub var fence_counter: u64 = 0;

fn next_fence() u64 {
    fence_counter += 1;
    return fence_counter;
}

/// Validated completion metadata for one exchange — what a caller is
/// allowed to trust: the reply descriptor's used length, the response
/// type, and the echoed context + full fence id.
pub const Completion = struct {
    used_len: u32,
    resp_type: u32,
    ctx_id: u32,
    fence_id: u64,
};

/// The named refusals — every failure path is one of these, never a bare
/// false and never an unmapped success.
pub const Error = error{
    /// Device absent or transport not armed — the feature is unsupported.
    Unsupported,
    /// Context op before a successful private-capability probe.
    CapsNotReady,
    /// Empty, unaligned, over-staging or unparseable request bytes.
    BadRequest,
    /// A request is already outstanding (one at a time, #2160 §3).
    Busy,
    /// The ring could not take the element.
    SubmitFailed,
    /// Completion deadline hit; the chain is parked, never recycled.
    Timeout,
    /// used length below the 24-byte response header.
    ResponseTruncated,
    /// used length beyond the posted reply capacity — never read past it.
    ResponseOversized,
    /// Response type / ctx echo / fence echo mismatched the request.
    BadResponse,
    /// GET_CAPSET_INFO reported a capset id that is not VIR1.
    CapsetProfile,
    /// GET_CAPSET_INFO reported a capset_max_version that is not 1.
    CapsetVersion,
    /// GET_CAPSET_INFO reported a capset_max_size that is not 32.
    CapsetSize,
    /// A reply is shorter than its pinned wire shape.
    CapsetTruncated,
    /// A fixed VIR1 bound word mismatched (or ready not in 0|1).
    CapsetBounds,
    /// ctx_id 0 — the zero context is never valid.
    ZeroContext,
    /// The requested ctx_id already owns a live context.
    DuplicateHandle,
    /// ctx_id beyond the profile's context bound (a "third context").
    ContextExhausted,
    /// A handle naming a ctx_id outside the pool or a dead slot.
    BadHandle,
    /// A handle whose generation no longer matches the slot.
    StaleHandle,
};

/// Post one control-queue element and validate its completion end to
/// end: used descriptor id + length, response type, echoed ctx_id, full
/// fence id. `req` is copied into pinned staging before submit; `resp_cap`
/// bounds the reply descriptor (≤ `resp_cap_max`). The reply bytes sit in
/// `g3_resp_buf[0..used_len]` on success.
pub fn exchange(req: []const u8, want_type: u32, resp_cap: usize) Error!Completion {
    if (!g3_ready) return error.Unsupported;
    if (req.len < wire.hdr_len or req.len > req_staging_len or (req.len & 3) != 0) return error.BadRequest;
    if (resp_cap < wire.hdr_len or resp_cap > resp_cap_max) return error.BadRequest;
    const req_hdr = wire.parse_hdr(req) orelse return error.BadRequest;
    // The private contract pins a fence on every command: a request
    // without one can never produce a verifiable completion.
    if ((req_hdr.flags & wire.flag_fence) == 0 or req_hdr.fence_id == 0) return error.BadRequest;
    if (pending != null) return error.Busy;

    @memcpy(g3_req_staging[0..req.len], req);
    const resp = g3_resp_buf[0..resp_cap];
    const handle = transport.submit(g3_req_staging[0..req.len], resp) orelse return error.SubmitFailed;
    pending = .{ .handle = handle, .fence_id = req_hdr.fence_id, .ctx_id = req_hdr.ctx_id };
    const used_len = transport.wait(handle, exchange_budget) orelse {
        transport.release(handle, false); // park — the head is never reused
        pending = null;
        g3_timeouts += 1;
        return error.Timeout;
    };
    transport.release(handle, true);
    pending = null;
    g3_cmds += 1;
    if (used_len > resp_cap) {
        g3_errors += 1;
        return error.ResponseOversized;
    }
    if (used_len < wire.hdr_len) {
        g3_errors += 1;
        return error.ResponseTruncated;
    }
    const resp_hdr = wire.parse_hdr(resp[0..used_len]) orelse {
        g3_errors += 1;
        return error.ResponseTruncated;
    };
    if (resp_hdr.type != want_type or resp_hdr.ctx_id != req_hdr.ctx_id or resp_hdr.fence_id != req_hdr.fence_id) {
        g3_errors += 1;
        return error.BadResponse;
    }
    return .{ .used_len = used_len, .resp_type = resp_hdr.type, .ctx_id = resp_hdr.ctx_id, .fence_id = resp_hdr.fence_id };
}

/// The reply bytes of the last successful exchange (device-written).
pub fn resp_bytes(n: usize) []const u8 {
    return g3_resp_buf[0..@min(n, resp_cap_max)];
}

// ---------------------------------------------------------------------------
// Private capability probe (the mandatory VIR1 profile match, #2160 §2)
// ---------------------------------------------------------------------------

/// The validated profile (valid only when `caps_valid`).
pub var caps: wire.Vir1Caps = .{ .version = 0, .max_width = 0, .max_height = 0, .contexts = 0, .resources_per_context = 0, .max_submit_bytes = 0, .shader_pair = 0, .ready = 0 };
pub var caps_valid: bool = false;

/// GET_CAPSET_INFO index 0 -> GET_CAPSET VIR1 v1. The profile id, version
/// and payload size are pinned; so is every bound word except `ready`
/// (0|1). Any deviation is a named refusal — a different profile is not
/// a degraded profile.
pub fn probe_caps() Error!wire.Vir1Caps {
    var req: [wire.ctx_create_req_len]u8 = undefined;
    const n1 = wire.encode_get_capset_info(&req, wire.capset_index, next_fence());
    const c1 = try exchange(req[0..n1], wire.resp_ok_capset_info, wire.get_capset_info_resp_len);
    const info = wire.parse_capset_info(resp_bytes(c1.used_len)) orelse return error.CapsetTruncated;
    if (info.capset_id != wire.capset_vir1) return error.CapsetProfile;
    if (info.max_version != wire.vir1_version) return error.CapsetVersion;
    if (info.max_size != wire.vir1_payload_len) return error.CapsetSize;

    const n2 = wire.encode_get_capset(&req, wire.capset_vir1, wire.vir1_version, next_fence());
    const c2 = try exchange(req[0..n2], wire.resp_ok_capset, wire.capset_resp_hdr_len + wire.vir1_payload_len);
    if (c2.used_len != wire.capset_resp_hdr_len + wire.vir1_payload_len) return error.CapsetTruncated;
    const found = wire.parse_vir1(resp_bytes(c2.used_len)[wire.capset_resp_hdr_len..]) orelse return error.CapsetTruncated;
    if (found.version != wire.vir1_version or
        found.max_width != wire.vir1_max_width or
        found.max_height != wire.vir1_max_height or
        found.contexts != wire.vir1_contexts or
        found.resources_per_context != wire.vir1_resources_per_context or
        found.max_submit_bytes != wire.vir1_max_submit_bytes or
        found.shader_pair != wire.vir1_shader_pair or
        found.ready > 1) return error.CapsetBounds;
    caps = found;
    caps_valid = true;
    return caps;
}

// ---------------------------------------------------------------------------
// The bounded context lifecycle
// ---------------------------------------------------------------------------

/// A generation-bearing context handle. `ctx_id` is the wire id (1..2);
/// `generation` counts the slot's successful creates, so a handle issued
/// for a retired context can never satisfy a later one (the "delayed old
/// completion" rule applied to the lifecycle itself). A valid handle is
/// always nonzero.
pub const Handle = struct {
    ctx_id: u32,
    generation: u32,
};

const Slot = struct {
    live: bool,
    generation: u32,
};
var slots: [max_contexts]Slot = @splat(.{ .live = false, .generation = 0 });

/// Context-dispatch switch: when false, CTX_CREATE/CTX_DESTROY refuse
/// with `Unsupported` BEFORE any submit while discovery and capability
/// probes keep working. Always true in production; the seam exists so
/// context dispatch is behaviorally disable-able (the revert-fails
/// proof flips it and watches the lifecycle go red).
pub const ctx_dispatch_enabled: bool = true;

/// Live contexts right now (≤ `max_contexts`).
pub fn live_count() usize {
    var n: usize = 0;
    for (slots) |s| {
        if (s.live) n += 1;
    }
    return n;
}

fn ctx_name(ctx_id: u32, buf: *[6]u8) []const u8 {
    buf.* = "vir1c0".*;
    buf[5] = @intCast('0' + ctx_id);
    return buf;
}

/// CTX_CREATE: take one of the two bounded contexts. All refusals are
/// named and happen BEFORE any submit — a refused create posts nothing
/// and leaks no slot.
pub fn ctx_create(ctx_id: u32) Error!Handle {
    if (!g3_ready) return error.Unsupported;
    if (!ctx_dispatch_enabled) return error.Unsupported;
    if (!caps_valid) return error.CapsNotReady;
    if (ctx_id == 0) return error.ZeroContext;
    if (ctx_id > caps.contexts) return error.ContextExhausted;
    const idx = ctx_id - 1;
    if (slots[idx].live) return error.DuplicateHandle;
    var name_buf: [6]u8 = undefined;
    var req: [wire.ctx_create_req_len]u8 = undefined;
    const n = wire.encode_ctx_create(&req, ctx_id, 0, ctx_name(ctx_id, &name_buf), next_fence());
    _ = try exchange(req[0..n], wire.resp_ok_nodata, wire.nodata_resp_len);
    slots[idx].live = true;
    slots[idx].generation += 1;
    return .{ .ctx_id = ctx_id, .generation = slots[idx].generation };
}

/// CTX_DESTROY: retire a live context through its generation-bearing
/// handle. Validation is identical in shape: named refusals, no submit
/// on a bad handle, no slot freed twice.
pub fn ctx_destroy(h: Handle) Error!void {
    if (!g3_ready) return error.Unsupported;
    if (!ctx_dispatch_enabled) return error.Unsupported;
    if (h.ctx_id == 0) return error.ZeroContext;
    if (h.ctx_id > max_contexts) return error.BadHandle;
    const idx = h.ctx_id - 1;
    const s = &slots[idx];
    if (s.generation == 0) return error.BadHandle; // never issued
    if (s.generation != h.generation) return error.StaleHandle; // replayed old
    if (!s.live) return error.BadHandle; // retired in this generation
    var req: [wire.ctx_destroy_req_len]u8 = undefined;
    const n = wire.encode_ctx_destroy(&req, h.ctx_id, next_fence());
    _ = try exchange(req[0..n], wire.resp_ok_nodata, wire.nodata_resp_len);
    slots[idx].live = false;
}

/// Reset every piece of lifecycle/exchange state (host tests; the boot
/// path's state is built once and never reset).
pub fn reset_state() void {
    pending = null;
    parked_count = 0;
    fence_counter = 0;
    caps_valid = false;
    caps = .{ .version = 0, .max_width = 0, .max_height = 0, .contexts = 0, .resources_per_context = 0, .max_submit_bytes = 0, .shader_pair = 0, .ready = 0 };
    slots = @splat(.{ .live = false, .generation = 0 });
    g3_cmds = 0;
    g3_errors = 0;
    g3_timeouts = 0;
    g3_fail = "";
    g3_ready = false;
    exchange_budget = 16_000_000;
}

// ---------------------------------------------------------------------------
// Host tests — a fake device transcript drives the REAL exchange path
// (submit -> wait -> validate) exactly the way virtio_file's M97d suite
// drives its queue: the fake records every request byte and synthesizes
// the contract replies, including programmable lies.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The fake device: records the request transcript verbatim and builds
/// the contract reply per request type (echo ctx + fence). Every lie a
/// negative test needs is a named field.
const FakeDevice = struct {
    req_count: usize = 0,
    req_lens: [16]usize = @splat(0),
    reqs: [16][128]u8 = undefined,
    resp_stash: []u8 = &.{},
    live: [3]bool = .{ false, false, false },
    last_release_completed: bool = true,
    release_count: usize = 0,
    // Contract fields the negative tests steer.
    capset_id: u32 = wire.capset_vir1,
    capset_max_version: u32 = wire.vir1_version,
    capset_max_size: u32 = wire.vir1_payload_len,
    caps_ready: u32 = 1,
    caps_corrupt_idx: usize = 8, // index 8 = no overwrite
    caps_corrupt_val: u32 = 0,
    reply_type_override: ?u32 = null,
    reply_ctx_override: ?u32 = null,
    reply_fence_override: ?u64 = null,
    reply_used_override: ?u32 = null,
    never_complete: bool = false,
};

var fake: FakeDevice = .{};

fn fake_reset() void {
    fake = .{};
}

fn fake_submit(req: []const u8, resp: []u8) ?u32 {
    // Ring-buffer transcript: the first 16 requests are byte-compared
    // against the goldens; the pool-churn tests only count.
    const slot = fake.req_count % fake.reqs.len;
    const n = @min(req.len, fake.reqs[slot].len);
    @memcpy(fake.reqs[slot][0..n], req[0..n]);
    fake.req_lens[slot] = n;
    fake.req_count += 1;
    fake.resp_stash = resp;
    return @intCast(0x100 + fake.req_count - 1);
}

/// Build the contract reply for the LAST recorded request into the
/// stashed reply buffer; returns the used length (or the override).
fn fake_wait(handle: u32, budget: usize) ?u32 {
    _ = handle;
    _ = budget;
    if (fake.never_complete) return null;
    if (fake.req_count == 0) return null;
    const last = (fake.req_count - 1) % fake.reqs.len;
    const req = fake.reqs[last][0..fake.req_lens[last]];
    const req_hdr = wire.parse_hdr(req).?;
    const resp = fake.resp_stash;
    var len: usize = 0;
    switch (req_hdr.type) {
        wire.cmd_get_capset_info => {
            len = wire.get_capset_info_resp_len;
            write_resp_hdr(resp, wire.resp_ok_capset_info, req_hdr);
            std.mem.writeInt(u32, resp[24..28], fake.capset_id, .little);
            std.mem.writeInt(u32, resp[28..32], fake.capset_max_version, .little);
            std.mem.writeInt(u32, resp[32..36], fake.capset_max_size, .little);
            std.mem.writeInt(u32, resp[36..40], 0, .little);
        },
        wire.cmd_get_capset => {
            len = wire.capset_resp_hdr_len + wire.vir1_payload_len;
            write_resp_hdr(resp, wire.resp_ok_capset, req_hdr);
            wire.encode_vir1_caps(resp[24..][0..wire.vir1_payload_len], fake.caps_ready);
            if (fake.caps_corrupt_idx < 8) {
                std.mem.writeInt(u32, resp[24 + fake.caps_corrupt_idx * 4 ..][0..4], fake.caps_corrupt_val, .little);
            }
        },
        wire.cmd_ctx_create => {
            len = wire.nodata_resp_len;
            write_resp_hdr(resp, wire.resp_ok_nodata, req_hdr);
            if (req_hdr.ctx_id >= 1 and req_hdr.ctx_id <= 2) fake.live[req_hdr.ctx_id] = true;
        },
        wire.cmd_ctx_destroy => {
            len = wire.nodata_resp_len;
            write_resp_hdr(resp, wire.resp_ok_nodata, req_hdr);
            if (req_hdr.ctx_id >= 1 and req_hdr.ctx_id <= 2) fake.live[req_hdr.ctx_id] = false;
        },
        else => {
            len = wire.nodata_resp_len;
            write_resp_hdr(resp, wire.resp_err_unspec, req_hdr);
        },
    }
    if (fake.reply_type_override) |t| std.mem.writeInt(u32, resp[0..4], t, .little);
    if (fake.reply_ctx_override) |ctx| std.mem.writeInt(u32, resp[16..20], ctx, .little);
    if (fake.reply_fence_override) |f| std.mem.writeInt(u64, resp[8..16], f, .little);
    return if (fake.reply_used_override) |u| u else @intCast(len);
}

fn write_resp_hdr(resp: []u8, resp_type: u32, req_hdr: wire.Hdr) void {
    std.mem.writeInt(u32, resp[0..4], resp_type, .little);
    std.mem.writeInt(u32, resp[4..8], 0, .little);
    std.mem.writeInt(u64, resp[8..16], req_hdr.fence_id, .little);
    std.mem.writeInt(u32, resp[16..20], req_hdr.ctx_id, .little);
    std.mem.writeInt(u32, resp[20..24], 0, .little);
}

fn fake_release(handle: u32, completed: bool) void {
    _ = handle;
    fake.last_release_completed = completed;
    fake.release_count += 1;
}

fn attach_fake() void {
    transport = .{ .submit = fake_submit, .wait = fake_wait, .release = fake_release };
    g3_ready = true;
}

test "gpu3d_device: the lifecycle transcript is byte-exact and the pool returns to baseline" {
    reset_state();
    fake_reset();
    attach_fake();
    defer reset_state();

    // The capability probe: GET_CAPSET_INFO fence 1, GET_CAPSET fence 2.
    const found = try probe_caps();
    try testing.expect(found.ready == 1);
    try testing.expectEqualSlices(u8, &wire.golden_get_capset_info, fake.reqs[0][0..fake.req_lens[0]]);
    try testing.expectEqualSlices(u8, &wire.golden_get_capset, fake.reqs[1][0..fake.req_lens[1]]);

    // CTX_CREATE ctx 1 -> a nonzero generation-bearing handle; the exact
    // golden request went on the wire.
    const h1 = try ctx_create(1);
    try testing.expect(h1.ctx_id == 1 and h1.generation == 1);
    try testing.expectEqual(@as(usize, 1), live_count());
    try testing.expectEqualSlices(u8, &wire.golden_ctx_create, fake.reqs[2][0..fake.req_lens[2]]);
    try testing.expect(fake.live[1]);

    // CTX_DESTROY through the handle -> pool back to baseline.
    try ctx_destroy(h1);
    try testing.expectEqual(@as(usize, 0), live_count());
    try testing.expectEqualSlices(u8, &wire.golden_ctx_destroy, fake.reqs[3][0..fake.req_lens[3]]);
    try testing.expect(!fake.live[1]);

    // 100 create/destroy cycles: the pool returns to baseline every time,
    // generations keep advancing so old handles stay dead.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const a = try ctx_create(1);
        const b = try ctx_create(2);
        try testing.expectEqual(@as(usize, 2), live_count());
        try ctx_destroy(a);
        try ctx_destroy(b);
        try testing.expectEqual(@as(usize, 0), live_count());
    }
    try testing.expect(slots[0].generation == 101 and slots[1].generation == 100);

    // A handle from a retired generation cannot destroy the new context.
    try testing.expectError(error.StaleHandle, ctx_destroy(h1));
}

test "gpu3d_device: feature absent is unsupported, never a submit" {
    reset_state();
    fake_reset();
    transport = .{ .submit = fake_submit, .wait = fake_wait, .release = fake_release };
    defer reset_state();
    try testing.expectError(error.Unsupported, ctx_create(1));
    try testing.expectError(error.Unsupported, ctx_destroy(.{ .ctx_id = 1, .generation = 1 }));
    try testing.expectError(error.Unsupported, probe_caps());
    try testing.expectError(error.Unsupported, exchange(&wire.golden_ctx_destroy, wire.resp_ok_nodata, wire.nodata_resp_len));
    try testing.expectEqual(@as(usize, 0), fake.req_count);
    try testing.expectEqual(@as(usize, 0), live_count());
}

test "gpu3d_device: caps-gated context ops and the named refusals never submit" {
    reset_state();
    fake_reset();
    attach_fake();
    defer reset_state();

    // Context op before a validated profile.
    try testing.expectError(error.CapsNotReady, ctx_create(1));
    try testing.expectEqual(@as(usize, 0), fake.req_count);

    _ = try probe_caps();
    const submitted = fake.req_count;

    // Zero context / third context / duplicate handle — all pre-submit.
    try testing.expectError(error.ZeroContext, ctx_create(0));
    try testing.expectError(error.ContextExhausted, ctx_create(3));
    const h1 = try ctx_create(1);
    const submitted_after_create = fake.req_count;
    try testing.expectError(error.DuplicateHandle, ctx_create(1));
    try testing.expectError(error.ContextExhausted, ctx_create(3));
    try testing.expectEqual(submitted_after_create, fake.req_count); // refusals posted nothing

    // Bad/stale handles on destroy — same discipline.
    try testing.expectError(error.ZeroContext, ctx_destroy(.{ .ctx_id = 0, .generation = 0 }));
    try testing.expectError(error.BadHandle, ctx_destroy(.{ .ctx_id = 3, .generation = 1 }));
    try testing.expectError(error.BadHandle, ctx_destroy(.{ .ctx_id = 2, .generation = 1 }));
    try testing.expectError(error.StaleHandle, ctx_destroy(.{ .ctx_id = 1, .generation = 99 }));
    try testing.expectEqual(submitted_after_create, fake.req_count);
    try testing.expectEqual(@as(usize, 1), live_count()); // no slot leaked either way

    try ctx_destroy(h1);
    try testing.expectEqual(@as(usize, 0), live_count());
    try testing.expectEqual(@as(usize, 2), submitted); // the two capability queries
}

test "gpu3d_device: wrong profile, version and size are named refusals" {
    reset_state();
    fake_reset();
    attach_fake();
    defer reset_state();

    // Profile id wrong -> CapsetProfile; only the info query ever posted.
    fake.capset_id = 0x4d455341; // "MESA"
    try testing.expectError(error.CapsetProfile, probe_caps());
    try testing.expectEqual(@as(usize, 1), fake.req_count);
    try testing.expect(!caps_valid);

    // Version wrong -> CapsetVersion.
    fake_reset();
    fake.capset_max_version = 2;
    try testing.expectError(error.CapsetVersion, probe_caps());
    try testing.expectEqual(@as(usize, 1), fake.req_count);

    // Payload size wrong -> CapsetSize.
    fake_reset();
    fake.capset_max_size = 64;
    try testing.expectError(error.CapsetSize, probe_caps());
    try testing.expectEqual(@as(usize, 1), fake.req_count);

    // A fixed VIR1 bound word off -> CapsetBounds (contexts = 3 here).
    fake_reset();
    fake.caps_corrupt_idx = 3;
    fake.caps_corrupt_val = 3;
    try testing.expectError(error.CapsetBounds, probe_caps());
    try testing.expectEqual(@as(usize, 2), fake.req_count);
    try testing.expect(!caps_valid);

    // ready outside 0|1 -> CapsetBounds.
    fake_reset();
    fake.caps_ready = 7;
    try testing.expectError(error.CapsetBounds, probe_caps());

    // ready=0 is a valid "present but renderer unarmed" profile.
    fake_reset();
    fake.caps_ready = 0;
    const c = try probe_caps();
    try testing.expectEqual(@as(u32, 0), c.ready);
    try testing.expect(caps_valid);
}

test "gpu3d_device: truncated, oversized and malformed replies can never be success" {
    reset_state();
    fake_reset();
    attach_fake();
    defer reset_state();

    // Truncated capset reply (40 B instead of the pinned 56).
    fake.reply_used_override = 40;
    try testing.expectError(error.CapsetTruncated, probe_caps());
    try testing.expect(!caps_valid);

    // Used length below the response header -> ResponseTruncated.
    fake_reset();
    fake.reply_used_override = 20;
    try testing.expectError(error.ResponseTruncated, probe_caps());

    // A device reporting MORE than the posted reply descriptor lies:
    // nothing past the descriptor is ever read.
    fake_reset();
    fake.reply_used_override = 4096;
    try testing.expectError(error.ResponseOversized, probe_caps());

    // Wrong response type for the query.
    fake_reset();
    fake.reply_type_override = wire.resp_ok_nodata;
    try testing.expectError(error.BadResponse, probe_caps());

    // Wrong context echo.
    fake_reset();
    fake.reply_ctx_override = 7;
    try testing.expectError(error.BadResponse, probe_caps());

    // A delayed OLD completion echoing an earlier fence cannot satisfy
    // the current request (the park story's reply-level half).
    fake_reset();
    fake.reply_fence_override = 0xaaaa;
    try testing.expectError(error.BadResponse, probe_caps());
    try testing.expect(!caps_valid);
}

test "gpu3d_device: a timeout parks the chain and one outstanding is the bound" {
    reset_state();
    fake_reset();
    attach_fake();
    defer reset_state();

    // Busy: a pending record makes the next exchange refuse by name.
    pending = .{ .handle = 0x999, .fence_id = 1, .ctx_id = 0 };
    try testing.expectError(error.Busy, exchange(&wire.golden_ctx_destroy, wire.resp_ok_nodata, wire.nodata_resp_len));
    pending = null;

    // Timeout: the fake never completes -> named refusal, chain parked.
    fake.never_complete = true;
    exchange_budget = 100;
    var req: [wire.ctx_destroy_req_len]u8 = undefined;
    const n = wire.encode_ctx_destroy(&req, 1, next_fence());
    try testing.expectError(error.Timeout, exchange(req[0..n], wire.resp_ok_nodata, wire.nodata_resp_len));
    try testing.expect(!fake.last_release_completed); // released as a PARK
    try testing.expectEqual(@as(u64, 1), g3_timeouts);
}

// --- the real ring path, exercised against an in-memory used ring -------

var test_notify_slot: u16 align(4) = 0;

/// Arm the real control ring for host tests (the virtio_file
/// arm_test_transport shape): rings initialized, notify target a scratch
/// word, transport back on the real ops.
fn arm_real_ring() void {
    ring_init(&g3_ring);
    g3_ring.notify_off = 0;
    g3_ring.armed = true;
    g3_notify = @intFromPtr(&test_notify_slot);
    g3_notify_mult = 0;
    transport = .{ .submit = ring_submit, .wait = ring_wait, .release = ring_release };
    g3_ready = true;
}

test "gpu3d_device: the real ring posts the golden request and completes by used id" {
    reset_state();
    arm_real_ring();
    defer reset_state();
    defer g3_ring.armed = false;

    // Skip the capability probe by pinning caps directly; fence_counter
    // staged so the create carries fence 3 — the pinned golden request.
    fence_counter = 2;
    caps_valid = true;
    caps = .{ .version = 1, .max_width = 256, .max_height = 192, .contexts = 2, .resources_per_context = 2, .max_submit_bytes = 4096, .shader_pair = 1, .ready = 1 };

    // The device completes chain head 0 (the first pop off the fresh
    // free list) with a 24-byte OK_NODATA echoing ctx 1 / fence 3.
    var resp: [wire.nodata_resp_len]u8 = @splat(0);
    std.mem.writeInt(u32, resp[0..4], wire.resp_ok_nodata, .little);
    std.mem.writeInt(u64, resp[8..16], 3, .little);
    std.mem.writeInt(u32, resp[16..20], 1, .little);
    @memcpy(g3_resp_buf[0..wire.nodata_resp_len], &resp);
    g3_ring.used.ring[0] = .{ .id = 0, .len = wire.nodata_resp_len };
    g3_ring.used.idx = 1;

    const h = try ctx_create(1);
    try testing.expect(h.ctx_id == 1 and h.generation == 1);
    try testing.expectEqualSlices(u8, &wire.golden_ctx_create, g3_req_staging[0..wire.ctx_create_req_len]);
    try testing.expectEqual(@as(u16, queue_size), g3_ring.free_count); // chain freed
}

test "gpu3d_device: an unmatched used id is consumed, a parked chain is reaped" {
    reset_state();
    arm_real_ring();
    defer reset_state();
    defer g3_ring.armed = false;
    fence_counter = 2;
    caps_valid = true;
    caps = .{ .version = 1, .max_width = 256, .max_height = 192, .contexts = 2, .resources_per_context = 2, .max_submit_bytes = 4096, .shader_pair = 1, .ready = 1 };

    // First request times out: no used entry at all -> Timeout, head 0 parked.
    exchange_budget = 100;
    var req: [wire.ctx_destroy_req_len]u8 = undefined;
    var n = wire.encode_ctx_destroy(&req, 1, next_fence());
    try testing.expectError(error.Timeout, exchange(req[0..n], wire.resp_ok_nodata, wire.nodata_resp_len));
    try testing.expectEqual(@as(u16, 1), parked_count);
    try testing.expectEqual(@as(u16, queue_size - 2), g3_ring.free_count);

    // The parked head's LATE reply arrives alongside the next request's
    // completion: entry id 0 is reaped (chain freed), entry id 2 (the new
    // request's head) completes the second exchange.
    var resp: [wire.nodata_resp_len]u8 = @splat(0);
    std.mem.writeInt(u32, resp[0..4], wire.resp_ok_nodata, .little);
    std.mem.writeInt(u64, resp[8..16], 4, .little);
    std.mem.writeInt(u32, resp[16..20], 1, .little);
    @memcpy(g3_resp_buf[0..wire.nodata_resp_len], &resp);
    g3_ring.used.ring[0] = .{ .id = 0, .len = wire.nodata_resp_len }; // the stale parked reply
    g3_ring.used.ring[1] = .{ .id = 2, .len = wire.nodata_resp_len }; // the live request
    g3_ring.used.idx = 2;
    n = wire.encode_ctx_destroy(&req, 1, next_fence());
    const done = try exchange(req[0..n], wire.resp_ok_nodata, wire.nodata_resp_len);
    try testing.expectEqual(@as(u64, 4), done.fence_id);
    try testing.expectEqual(@as(u16, 0), parked_count);
    // Both chains are home: head 0 reaped, head 2 freed.
    try testing.expectEqual(@as(u16, queue_size), g3_ring.free_count);

    // A fabricated used id (no chain ever posted it) is consumed and
    // discarded — the pending request still fails honestly.
    g3_ring.used.ring[2] = .{ .id = 7, .len = wire.nodata_resp_len };
    g3_ring.used.idx = 3;
    n = wire.encode_ctx_destroy(&req, 1, next_fence());
    try testing.expectError(error.Timeout, exchange(req[0..n], wire.resp_ok_nodata, wire.nodata_resp_len));
    try testing.expectEqual(@as(u16, 1), parked_count); // the live chain parked again
}
