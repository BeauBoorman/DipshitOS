//! VirelaiOS virtio-vsock transport (M115a, issue #2460) — the probe for a
//! restore-safe guest↔host channel.
//!
//! The VZ device is Apple's standard `VZVirtioSocketDevice` — a modern
//! virtio-pci vsock device (VID 0x1af4, virtio device ID 19, DID 0x1053 per
//! the 0x1040 + device-id scheme shared by console/blk/net/gpu/snd/fs),
//! attached by the runner's `--vsock` flag. Unlike the custom-virtio spike
//! devices, `validateSaveRestoreSupport` accepts it (observed; see
//! docs/hardware-contract.md), so it is the candidate control channel for
//! the M115 suspend/snapshot arc — provided a guest connect still lands on
//! a host listener after `restoreMachineStateFrom`.
//!
//! The card needs ONE measured fact — a guest-initiated stream connect to a
//! host port reaching the host listener — so this driver is deliberately
//! minimal: PCI discovery pre-exit, three split rings (rx/tx/event) armed
//! post-MMU (the claim-6420 discipline: VZ resets virtio devices at
//! ExitBootServices, so the whole status/feature/queue sequence re-runs on
//! the pre-exit-resolved addresses), and a synchronous `connect` that
//! pushes one VIRTIO_VSOCK_OP_REQUEST on the tx queue and polls the rx
//! ring for the peer's OP_RESPONSE (accepted) or OP_RST (refused). No data
//! plane, no credit accounting, no connection table — one outstanding
//! connect at a time is the probe surface.
//!
//! No libc, no POSIX, no allocation, no interrupts.

const std = @import("std");
const mmio = @import("mmio.zig");
const mmu = @import("mmu.zig");
const pci = @import("pci.zig");
const evidence = @import("evidence.zig");

/// Modern virtio-pci DID for virtio device ID 19 (vsock): 0x1040 + 19.
pub const virtio_vsock_did: u32 = 0x1053;

/// The host end of every vsock connect (virtio spec §5.10: VMADDR_CID_HOST).
pub const host_cid: u64 = 2;

/// The runner's default `--vsock-port`; a connect lands only where VZ has
/// a `VZVirtioSocketListener` armed (any other port answers RST).
pub const default_port: u32 = 1208;

// virtio_vsock_hdr field offsets (44 bytes, all little-endian, §5.10.6.2).
const hdr_src_cid: usize = 0;
const hdr_dst_cid: usize = 8;
const hdr_src_port: usize = 16;
const hdr_dst_port: usize = 20;
const hdr_len: usize = 24;
const hdr_type: usize = 28;
const hdr_op: usize = 30;
const hdr_flags: usize = 32;
const hdr_buf_alloc: usize = 36;
const hdr_fwd_cnt: usize = 40;
const hdr_size: usize = 44;

const op_request: u16 = 1;
const op_response: u16 = 2;
const op_rst: u16 = 3;
const type_stream: u16 = 1;

/// rx buffers carry the peer's hdr + payload. The probe exchanges 44-byte
/// control packets only, but a host DATA packet could arrive on an open
/// connection, so the posted buffers stay message-sized.
const rx_buf_size: usize = 2048;
const rx_buf_count: usize = 4;
/// virtio_vsock_event is 8 bytes (§5.10.6.5); the buffers stay larger so a
/// surprising event shape is captured rather than truncated.
const ev_buf_size: usize = 64;
const ev_buf_count: usize = 2;

/// Credit the peer is told it may send (`buf_alloc` in the request header).
/// The probe transfers no payload; the value only needs to be honest.
const rx_credit: u32 = rx_buf_size * rx_buf_count;

/// Poll budget for one connect handshake — the fs channel's ~1.5-2 s
/// budget, so a loaded host's slow accept is not reported as a refusal.
const poll_budget: usize = 320_000_000;

const descriptor_count: usize = 8;
const max_queue: u16 = @intCast(descriptor_count);

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

const flag_write: u16 = 2; // VIRTQ_DESC_F_WRITE (device writes the buffer)

/// Connect verdict — the three honest outcomes of one OP_REQUEST.
pub const ConnectResult = enum {
    /// The peer answered OP_RESPONSE; the host listener accepted.
    connected,
    /// The peer answered OP_RST — no listener on that port (or refused).
    refused,
    /// No response inside the poll budget — the packet never landed (the
    /// post-restore degraded case M115a measures).
    timeout,
};

pub var vs_dev: u32 = 32; // PCI device number (32 = absent)
pub var vs_common: u64 = 0; // common-config address (BAR + cap offset)
pub var vs_notify: u64 = 0; // notify region base
pub var vs_device_cfg: u64 = 0; // device-config address (guest_cid at +0)
pub var vs_notify_mult: u32 = 0;
pub var vs_ready: bool = false; // transport armed, connect usable
pub var vs_guest_cid: u64 = 0;
pub var vs_fail_stage: u8 = 0; // init() failure point, for evidence
pub var vs_last_src_port: u32 = 0; // source port of the last connect()

var vs_common_bar: u64 = 0;
var vs_notify_bar: u64 = 0;
var vs_device_bar: u64 = 0;

var rx_queue: Queue = undefined; // queue 0: device → guest
var tx_queue: Queue = undefined; // queue 1: guest → device
var ev_queue: Queue = undefined; // queue 2: transport events

var rx_bufs: [rx_buf_count][rx_buf_size]u8 align(64) = undefined;
var ev_bufs: [ev_buf_count][ev_buf_size]u8 align(64) = undefined;
var tx_buf: [hdr_size]u8 align(64) = undefined;

/// Ephemeral guest source ports, bumping per connect so consecutive
/// `vsock <port>` commands are distinct connections to the host.
var next_src_port: u32 = 30000;

fn common_read8(offset: u32) u8 {
    return mmio.mmio_read8(vs_common + offset);
}

fn common_write8(offset: u32, value: u8) void {
    mmio.mmio_write8(vs_common + offset, value);
}

fn common_read16(offset: u32) u16 {
    return mmio.mmio_read16(vs_common + offset);
}

fn common_write16(offset: u32, value: u16) void {
    mmio.mmio_write16(vs_common + offset, value);
}

fn common_read32(offset: u32) u32 {
    return mmio.mmio_read32(vs_common + offset);
}

fn common_write32(offset: u32, value: u32) void {
    mmio.mmio_write32(vs_common + offset, value);
}

fn read16(bytes: []const u8, off: usize) u16 {
    return @as(u16, bytes[off]) | @as(u16, bytes[off + 1]) << 8;
}

fn read32(bytes: []const u8, off: usize) u32 {
    return @as(u32, read16(bytes, off)) | @as(u32, read16(bytes, off + 2)) << 16;
}

fn read64(bytes: []const u8, off: usize) u64 {
    return @as(u64, read32(bytes, off)) | @as(u64, read32(bytes, off + 4)) << 32;
}

fn write16(bytes: []u8, off: usize, value: u16) void {
    bytes[off] = @truncate(value);
    bytes[off + 1] = @truncate(value >> 8);
}

fn write32(bytes: []u8, off: usize, value: u32) void {
    write16(bytes, off, @truncate(value));
    write16(bytes, off + 2, @truncate(value >> 16));
}

fn write64(bytes: []u8, off: usize, value: u64) void {
    write32(bytes, off, @truncate(value));
    write32(bytes, off + 4, @truncate(value >> 32));
}

/// Resolve `dev`'s BARs and the virtio common/notify/device-config
/// capabilities. PRE-EXIT only (config-space reads hang post-exit,
/// claim 0013). Mirrors virtio_fs.resolve_device: vsock's device config
/// is the 8-byte guest_cid, so the device cap must cover it.
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
        if (id == 0x09) {
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
    vs_common = bars[common_bar] + common_off;
    vs_notify = bars[notify_bar] + notify_off;
    vs_device_cfg = bars[device_bar] + device_off;
    vs_common_bar = bars[common_bar];
    vs_notify_bar = bars[notify_bar];
    vs_device_bar = bars[device_bar];
    vs_notify_mult = mult;
    return true;
}

/// PRE-EXIT PCI-only discovery. False means no VZVirtioSocketDevice — the
/// default boot attaches none, so nothing is printed and the output stays
/// byte-identical.
pub fn probe() bool {
    vs_ready = false;
    vs_dev = 32;
    if (pci.pci_ecam == 0) return false;
    var dev: u32 = 0;
    while (dev < 32) : (dev += 1) {
        const id = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0);
        if ((id & 0xffff) != 0x1af4 or id >> 16 != virtio_vsock_did) continue;
        vs_dev = dev;
        if (!resolve_device(dev)) {
            vs_dev = 32;
            return false;
        }
        return true;
    }
    return false;
}

/// The device's BAR windows for the post-MMU identity map (deduplicated —
/// VZ may pack several capabilities into one BAR).
pub fn add_device_windows(out: []mmu.DeviceWindow) usize {
    var count: usize = 0;
    const bases = [_]u64{ vs_common_bar, vs_notify_bar, vs_device_bar };
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

/// Device status (common cfg + 0x14); 0xff when never discovered.
pub fn vs_status() u8 {
    if (vs_common == 0) return 0xff;
    return common_read8(0x14);
}

fn highest_power_of_two_at_most(n: u16) u16 {
    var size: u16 = 1;
    while (size <= n / 2 and size < max_queue) size *= 2;
    return size;
}

/// Program one split ring (queue_select → size → GPA triple → enable) and
/// record its notify offset. Returns false on an absent/dead queue.
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
    mmio.mmio_write32(vs_common + 0x20, @truncate(desc));
    mmio.mmio_write32(vs_common + 0x24, @truncate(desc >> 32));
    mmio.mmio_write32(vs_common + 0x28, @truncate(avail));
    mmio.mmio_write32(vs_common + 0x2c, @truncate(avail >> 32));
    mmio.mmio_write32(vs_common + 0x30, @truncate(used));
    mmio.mmio_write32(vs_common + 0x34, @truncate(used >> 32));
    common_write16(0x18, size);
    common_write16(0x1c, 1);
    q.notify_off = common_read16(0x1e);
    return common_read16(0x1c) == 1;
}

/// Offer one WRITE buffer to a device→guest queue (rx or event).
fn post_buffer(q: *Queue, buf: []u8, desc_index: u16) void {
    q.desc[desc_index] = .{
        .addr = mmu.to_phys(@intFromPtr(buf.ptr)),
        .len = @intCast(buf.len),
        .flags = flag_write,
        .next = 0,
    };
    q.avail.ring[q.avail.idx % q.size] = desc_index;
    q.avail.idx +%= 1;
}

fn kick(q: *const Queue, queue_index: u16) void {
    mmu.clean_dcache_range(@intFromPtr(&q.desc), @sizeOf([descriptor_count]VirtqDesc));
    mmu.clean_dcache_range(@intFromPtr(&q.avail), @sizeOf(VirtqAvail));
    mmio.mmio_write16(vs_notify + @as(u64, q.notify_off) * vs_notify_mult, queue_index);
}

/// POST-MMU arm (the claim-6420 discipline: VZ resets virtio devices at
/// ExitBootServices — the block device's status reads 0 post-exit — so the
/// whole reset → features → queues → DRIVER_OK sequence runs again on the
/// pre-exit-resolved capability addresses). Programs rx/tx/event and posts
/// the rx + event buffers the host needs to be able to fill before any
/// connect answer can land.
pub fn init() bool {
    vs_ready = false;
    vs_fail_stage = 1; // reset
    if (vs_dev >= 32 or vs_common == 0) return false;
    common_write8(0x14, 0);
    var spins: usize = 0;
    while (common_read8(0x14) != 0) : (spins += 1) {
        if (spins >= 1_000_000) return false;
    }
    common_write8(0x14, 1 | 2); // ACKNOWLEDGE | DRIVER

    vs_fail_stage = 2; // feature negotiation
    common_write32(0x00, 0);
    const feature_lo = common_read32(0x04);
    common_write32(0x00, 1);
    const feature_hi = common_read32(0x04);
    if ((feature_hi & 1) == 0) return false; // VIRTIO_F_VERSION_1
    // Accept STREAM (bit 0) when offered — the only packet shape this
    // probe sends — plus VERSION_1. SEQPACKET is left unclaimed.
    common_write32(0x08, 0);
    common_write32(0x0c, feature_lo & 1);
    common_write32(0x08, 1);
    common_write32(0x0c, 1);
    common_write8(0x14, 1 | 2 | 8); // FEATURES_OK
    if ((common_read8(0x14) & 8) == 0) return false;

    vs_fail_stage = 3; // queue bring-up (rx, tx, event)
    if (!init_ring(&rx_queue, 0, max_queue)) return false;
    if (!init_ring(&tx_queue, 1, max_queue)) return false;
    if (!init_ring(&ev_queue, 2, max_queue)) return false;
    common_write8(0x14, 1 | 2 | 8 | 4); // DRIVER_OK
    if ((common_read8(0x14) & 4) == 0) return false;

    vs_fail_stage = 4; // device config: the guest's own CID
    vs_guest_cid = @as(u64, mmio.mmio_read32(vs_device_cfg)) |
        @as(u64, mmio.mmio_read32(vs_device_cfg + 4)) << 32;

    // Post the buffers the device fills: every rx buffer plus a couple of
    // event slots. A connect REQUEST has no answer without a posted rx
    // buffer for the RESPONSE to land in.
    for (0..rx_buf_count) |i| {
        post_buffer(&rx_queue, rx_bufs[i][0..], @intCast(i));
    }
    kick(&rx_queue, 0);
    for (0..ev_buf_count) |i| {
        post_buffer(&ev_queue, ev_bufs[i][0..], @intCast(i));
    }
    kick(&ev_queue, 2);

    vs_fail_stage = 5;
    vs_ready = true;
    evidence.dump_str("VSOCK arm cid=");
    evidence.dump_hex(vs_guest_cid);
    evidence.dump_str("\n");
    return true;
}

/// Drain a used ring: returns the next completed (desc, len) pair or null.
/// Consumed rx buffers are reposted by the caller's packet path.
fn pop_used(q: *Queue) ?VirtqUsedElem {
    mmu.invalidate_dcache_range(@intFromPtr(&q.used), @sizeOf(VirtqUsed));
    if (q.used.idx == q.last_used) return null;
    const slot = q.last_used % q.size;
    const used = q.used.ring[slot];
    q.last_used +%= 1;
    return used;
}

/// One guest→host stream connect: OP_REQUEST on the tx queue, then poll
/// the rx ring for the peer's answer. A RESPONSE to this exact
/// (src_port, dst_port) pair is `.connected`, an OP_RST is `.refused`, and
/// an empty rx ring inside the budget is `.timeout` — the degraded verdict
/// the save/restore probe measures. Any rx packet the pair does not match
/// is consumed and its buffer reposted.
pub fn connect(dst_port: u32) ConnectResult {
    if (!vs_ready) return .timeout;
    const src_port = next_src_port;
    next_src_port +%= 1;
    vs_last_src_port = src_port;

    @memset(&tx_buf, 0);
    write64(&tx_buf, hdr_src_cid, vs_guest_cid);
    write64(&tx_buf, hdr_dst_cid, host_cid);
    write32(&tx_buf, hdr_src_port, src_port);
    write32(&tx_buf, hdr_dst_port, dst_port);
    write32(&tx_buf, hdr_len, 0);
    write16(&tx_buf, hdr_type, type_stream);
    write16(&tx_buf, hdr_op, op_request);
    write32(&tx_buf, hdr_flags, 0);
    write32(&tx_buf, hdr_buf_alloc, rx_credit);
    write32(&tx_buf, hdr_fwd_cnt, 0);
    mmu.clean_dcache_range(@intFromPtr(&tx_buf), hdr_size);

    const desc_index: u16 = @intCast(tx_queue.avail.idx % tx_queue.size);
    tx_queue.desc[desc_index] = .{
        .addr = mmu.to_phys(@intFromPtr(&tx_buf)),
        .len = hdr_size,
        .flags = 0, // device reads the request header
        .next = 0,
    };
    tx_queue.avail.ring[tx_queue.avail.idx % tx_queue.size] = desc_index;
    tx_queue.avail.idx +%= 1;
    kick(&tx_queue, 1);

    var spins: usize = 0;
    var result: ConnectResult = .timeout;
    while (result == .timeout and spins < poll_budget) : (spins += 1) {
        while (pop_used(&rx_queue)) |used| {
            if (used.id >= rx_buf_count) continue;
            const buf = rx_bufs[used.id][0..];
            mmu.invalidate_dcache_range(@intFromPtr(buf.ptr), @min(buf.len, used.len));
            // The consumed buffer goes straight back on the avail ring so
            // the peer always has somewhere to put the next packet.
            post_buffer(&rx_queue, buf, @intCast(used.id));
            if (used.len < hdr_size) continue;
            const r_op = read16(buf, hdr_op);
            const r_src_port = read32(buf, hdr_src_port);
            const r_dst_port = read32(buf, hdr_dst_port);
            if (r_dst_port != src_port or r_src_port != dst_port) continue;
            if (r_op == op_response) result = .connected;
            if (r_op == op_rst) result = .refused;
        }
    }
    // Flush the reposted rx buffers before the result is returned.
    kick(&rx_queue, 0);
    return result;
}

// ---------------------------------------------------------------------------
// Host tests — the packet layout + constants are the spec shape
// ---------------------------------------------------------------------------

test "virtio_vsock: header layout and op codes are the virtio shape" {
    try std.testing.expectEqual(@as(usize, 44), hdr_size);
    try std.testing.expectEqual(@as(u16, 1), op_request);
    try std.testing.expectEqual(@as(u16, 2), op_response);
    try std.testing.expectEqual(@as(u16, 3), op_rst);
    try std.testing.expectEqual(@as(u16, 1), type_stream);
    try std.testing.expectEqual(@as(u64, 2), host_cid);
    try std.testing.expectEqual(@as(u32, 0x1053), virtio_vsock_did);

    // The encoded request header lands LE at the spec offsets.
    @memset(&tx_buf, 0);
    write64(&tx_buf, hdr_src_cid, 3);
    write64(&tx_buf, hdr_dst_cid, host_cid);
    write32(&tx_buf, hdr_src_port, 30000);
    write32(&tx_buf, hdr_dst_port, 1208);
    write16(&tx_buf, hdr_type, type_stream);
    write16(&tx_buf, hdr_op, op_request);
    try std.testing.expectEqual(@as(u64, 3), read64(&tx_buf, hdr_src_cid));
    try std.testing.expectEqual(@as(u64, 2), read64(&tx_buf, hdr_dst_cid));
    try std.testing.expectEqual(@as(u32, 30000), read32(&tx_buf, hdr_src_port));
    try std.testing.expectEqual(@as(u32, 1208), read32(&tx_buf, hdr_dst_port));
    try std.testing.expectEqual(@as(u16, op_request), read16(&tx_buf, hdr_op));
    // An unarmed transport reports timeout, never a hang.
    vs_ready = false;
    try std.testing.expectEqual(ConnectResult.timeout, connect(1208));
}
