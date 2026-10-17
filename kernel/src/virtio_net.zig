//! VirelaiOS virtio-pci network transport (milestone five, card N1 —
//! claim 1373).
//!
//! Drives the device the runner attaches as `VZVirtioNetworkDeviceConfiguration`
//! under `--net <capture-file>` — to the guest a modern virtio-pci net
//! device (VID 0x1af4, DID 0x1041, virtio device ID 1) on bus 0, found via
//! the MCFG ECAM base exactly like the console (0x1043, claim 0013), block
//! (0x1042, claim 6420) and entropy (0x1044, claim 2665) devices. The
//! 2026-08-11 DID correction established the modern DID = Virtio Device ID
//! + 0x1040 scheme, so modern virtio-net = **0x1041**; the transitional
//! form 0x1001 is also accepted (the console's 0x1003 precedent) and
//! whatever DID is OBSERVED is recorded in the `net` report (confirm-at-
//! claim-time — a differing DID is a claim-time finding, recorded as the
//! 6420/2665 corrections were).
//!
//! The transport mirrors the blk/entropy patterns: discovery + capability
//! walk + feature negotiation + split-ring queue setup run PRE-EXIT
//! (post-exit config-space reads hang on VZ, claim 0013); post-MMU the
//! transport is RE-ARMED (the claim-6420/2665 lesson — VZ resets virtio
//! devices at ExitBootServices, so status reads 0 and the queues are dead
//! until the re-arm) and TX runs only after that re-arm.
//!
//! N1 negotiates VIRTIO_F_VERSION_1 (mandatory) and VIRTIO_NET_F_MAC when
//! offered (the host-set address — the runner fixes the MAC on the host
//! config so the guest read is deterministic and gate-assertable); NO
//! offload/checksum features are negotiated, so a TX buffer is the RAW
//! ETHERNET FRAME with no virtio_net_hdr prefix (the transitional reading:
//! QEMU's reference device strips a 12-byte header only when checksum
//! offload is negotiated — see `tx_hdr_len`, a confirm-at-claim-time
//! constant). Queue 0 = RX, queue 1 = TX per the virtio-net spec §5.2.
//! N1 (claim 1373) proved the transport + TX; card N2 (claim 6076)
//! adds the RX path: queue 0 is supplied with a fixed BSS buffer
//! (one-request-at-a-time like TX), the used ring is drained POLLED
//! (the proven N1/blk shape — the net device's used-buffer IRQ line is
//! NOT yet observed on this platform; whether the device delivers one,
//! and via what INTID, is a claim-time finding recorded in `net`/the
//! claim, not assumed), accepted frames land in a bounded FIFO (no
//! heap, the card-3d push/drain pattern, drop-oldest overflow), and
//! `net recv` prints them. MAC filtering accepts own + broadcast and
//! drops the rest (a counter in the `net` report). The RX buffer is
//! sized with a 12-byte virtio_net_hdr headroom (N1 observed the device
//! CONSUMES one on TX; whether the device WRITES one into RX buffers is
//! pinned from observation at claim time — `net: rx-obs` records the
//! first frame's device-written length + first bytes, and `rx_hdr_len`
//! is corrected like `tx_hdr_len` was (0→12) if the observation
//! differs). Card N3 (claim 7293) adds the ARP protocol layer
//! (`kernel/src/arp.zig`, pure logic): the RX drain dispatches ARP
//! frames — a request for our static IP is answered (the reply is built
//! in `tx_staging` and transmitted on the N1 TX path), a reply is
//! learned into the bounded table, and `net ip`/`net arp` drive the
//! static address + resolution. Honest bounds: IPv4-only ARP, no DHCP,
//! no IP stack (N4).
//!
//! The logic is host-testable through injectable transport ops (the
//! fat.zig injected-sector-I/O pattern): feature selection, MAC read,
//! frame build, staging bounds and used-ring drain accounting are pure
//! functions over an `Ops` struct the tests mock; the real device binding
//! is a thin layer of fn pointers over the mmio/pci/mmu helpers.
//!
//! No libc, no POSIX, no allocation, no interrupts.

const std = @import("std");
const mmio = @import("mmio.zig");
const mmu = @import("mmu.zig");
const pci = @import("pci.zig");
const evidence = @import("evidence.zig");
/// Milestone five card N3 (claim 7293): the ARP protocol layer (pure
/// logic; the RX drain dispatches frames here and the monitor's
/// `net ip`/`net arp` subcommands drive the static address + resolution).
/// `pub` so monitor.zig can print the IP + counters and issue requests.
pub const arp = @import("arp.zig");
/// Milestone five card N4 (claim 0148): the IPv4/ICMP layer (pure logic;
/// the RX drain dispatches frames here and the monitor's `net ping`
/// subcommand drives echo requests). Reuses `arp.own_ip` as the ONE copy
/// of our static address.
pub const ipv4 = @import("ipv4.zig");
/// Milestone five card N5 (claim 8552): the UDP layer (pure logic; the
/// ipv4 protocol dispatch delivers validated datagrams here and the
/// monitor's `net udp` subcommands drive listen/close/send/recv).
pub const udp = @import("udp.zig");
pub const dhcp = @import("dhcp.zig"); // N8 (claim 0351): the bounded RFC 2131 client (port 68)
pub const tcp = @import("tcp.zig"); // N10 (claim 7026): the bounded RFC 793 client
/// M117b (issue #2474, ADR 0057): the IPv6/ICMPv6 layer (pure logic;
/// the RX drain dispatches ethertype 0x86dd here beside the N3/N4
/// dispatch and the monitor's `net ip6`/`net ping6` subcommands drive
/// the address set + echo requests).
pub const ipv6 = @import("ipv6.zig");
/// M117b (issue #2474, ADR 0057): the NDP layer (pure logic; the
/// ICMPv6 dispatch inside ipv6.zig hands NS/NA/RS/RA here, and
/// `net_ndp_poll` drives its bounded RS train + one-probe DAD on the
/// tick seam).
pub const ndp = @import("ndp.zig");
pub const native_socket = @import("socket_native.zig");
pub const net_log = @import("net_log.zig"); // M26 N15 (issue #442): network event ring buffer

// ---------------------------------------------------------------------------
// Split-ring structures (the blk/entropy/console shared layout)
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

/// Split-ring size: 4 (power of two, Virtio 1.3 §4.1.4.3) — the blk/entropy
/// proven size. One TX request outstanding at a time keeps the ring
/// invariant (§2.7) trivially true.
pub const queue_size: u16 = 4;

const virtq_f_write: u16 = 0x2; // VIRTQ_DESC_F_WRITE

/// Completion-poll budget per wait, and how many fresh budgets a stuck
/// device gets before a request fails honestly (mirrors blk/entropy).
const poll_budget: usize = 16_000_000;
const poll_retries: usize = 3;

// ---------------------------------------------------------------------------
// Feature bits (64-bit device-features space)
// ---------------------------------------------------------------------------

const vf_version_1: u64 = 0x1 << 32; // VIRTIO_F_VERSION_1 (bit 32)
const vf_net_mac: u64 = 0x1 << 5; // VIRTIO_NET_F_MAC (bit 5)
const vf_net_mtu: u64 = 0x1 << 3; // VIRTIO_NET_F_MTU (bit 3)
/// Bit 16: VIRTIO_NET_F_STATUS under the legacy (xnu/Linux) numbering,
/// VIRTIO_NET_F_CTRL_RX under the modern spec numbering — accepted
/// either way, harmless for N1 (no control queue is used).
const vf_net_bit16: u64 = 0x1 << 16;
const vf_ring_packed: u64 = 0x1 << 34; // VIRTIO_F_RING_PACKED (bit 34)

/// Whether the landed mask includes RING_PACKED (the device then expects
/// the PACKED virtqueue layout — see `net_send`/`setup_queue`).
pub var net_packed: bool = false;

// ---------------------------------------------------------------------------
// Ethernet framing constants (raw Ethernet for N1 — no IP/ARP yet)
// ---------------------------------------------------------------------------

pub const eth_type_ipv4: u16 = 0x0800;
/// M117b (issue #2474, ADR 0057 D1): the IPv6 ethertype — one leaf on
/// the existing demux seam.
pub const eth_type_ipv6: u16 = 0x86dd;
pub const eth_hdr_len: usize = 14; // dst MAC (6) + src MAC (6) + ethertype (2)
/// Payload bound = the standard Ethernet MTU (1500) without offload
/// features. `netsend` truncates honestly at this bound.
pub const payload_max: usize = 1500;
/// Largest single TX frame: 14-byte header + 1500-byte payload.
pub const frame_max: usize = eth_hdr_len + payload_max; // 1514

/// TX buffer layout, OBSERVED at claim time (2026-08-11, the live VZ
/// gate): VZ's virtio-net device consumes a 12-byte virtio_net_hdr prefix
/// on EVERY TX buffer, even with no offload/checksum feature negotiated
/// (the initial QEMU-transitional assumption of 0 — raw frame only — was
/// wrong; the host capture stripped exactly 12 bytes: our dst+src MACs
/// became the "header" and the delivered frame was ethertype+payload).
/// The driver therefore prepends a ZEROED virtio_net_hdr (all fields
/// zero = no offloads, raw Ethernet follows) to every TX buffer. Recorded
/// as the claim-1373 correction, the 6420/2665 pattern.
const tx_hdr_len: usize = 12;

/// Broadcast destination for the N1 known frame.
pub const broadcast_mac = [6]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
/// Fixed BSS MAC fallback (used only when VIRTIO_NET_F_MAC is NOT offered —
/// deterministic and gate-assertable; the host-set address is expected).
pub const fallback_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 };

/// Where the reported MAC came from (`net` reports it honestly).
pub const MacSource = enum {
    feature, // VIRTIO_NET_F_MAC negotiated — read from the device config
    fallback, // no MAC feature — fixed BSS address
};

// ---------------------------------------------------------------------------
// Injectable transport ops (the fat.zig injected-sector-I/O pattern)
// ---------------------------------------------------------------------------

/// The device-touching operations, injected so host tests can substitute a
/// mock (in-RAM config + rings) and drive the full submit/drain path. The
/// real implementation binds these to the module globals resolved pre-exit.
pub const Ops = struct {
    /// Read a 32-bit DEVICE-CONFIG register (virtio-net §5.2.2 — the MAC
    /// lives at offset 0; VZ's emulation accepts 32-bit accesses, the
    /// claim-0013 common-cfg lesson).
    dev_read32: *const fn (off: u32) u32,
    cfg_read8: *const fn (off: u32) u8,
    cfg_read16: *const fn (off: u32) u16,
    cfg_read32: *const fn (off: u32) u32,
    cfg_write8: *const fn (off: u32, value: u8) void,
    cfg_write16: *const fn (off: u32, value: u16) void,
    cfg_write32: *const fn (off: u32, value: u32) void,
    /// Kick a queue (the notify MMIO write).
    notify: *const fn (q: u16) void,
    /// Kernel VA -> guest physical (claim 5804: queue GPAs are physical).
    to_phys: *const fn (va: usize) u64,
    clean: *const fn (ptr: usize, len: usize) void,
    invalidate: *const fn (ptr: usize, len: usize) void,
};

// ---------------------------------------------------------------------------
// Device state (fixed BSS — the one-and-only real instance)
// ---------------------------------------------------------------------------

/// Per-queue split rings + TX accounting. Lives in BSS so the queue RAM has
/// stable physical addresses fed to the device (blk/entropy shape).
pub const Device = struct {
    rx_desc: [queue_size]VirtqDesc align(16) = undefined,
    rx_avail: VirtqAvail align(2) = undefined,
    rx_used: VirtqUsed align(4) = undefined,
    tx_desc: [queue_size]VirtqDesc align(16) = undefined,
    tx_avail: VirtqAvail align(2) = undefined,
    tx_used: VirtqUsed align(4) = undefined,
    /// Drain point on the TX used ring (the last consumed index).
    tx_last_used: u16 = 0,
    /// Drain point on the RX used ring (the last consumed index).
    rx_last_used: u16 = 0,
    /// TX counters: completions drained from the used ring and the bytes
    /// submitted (the `net` report's tx=frames,bytes).
    tx_frames: u64 = 0,
    tx_bytes: u64 = 0,
    /// Negotiated device features (64-bit; reported low/high in `net`).
    feats_lo: u32 = 0,
    feats_hi: u32 = 0,
    q0_enabled: bool = false, // RX queue armed
    q1_enabled: bool = false, // TX queue armed
};

/// Fixed BSS staging for ONE TX frame: `netsend` builds the zeroed
/// virtio_net_hdr (12 B, observed contract) followed by the Ethernet frame
/// (dst/src/ethertype/payload) here, submits the whole buffer, drains the
/// used ring, and reports byte counts. No heap — bounded by
/// `tx_hdr_len + frame_max` (1526 B).
pub var tx_staging: [tx_hdr_len + frame_max]u8 = undefined;

// ---------------------------------------------------------------------------
// RX path (milestone five, card N2 — claim 6076)
// ---------------------------------------------------------------------------

/// Whether the device writes a 12-byte virtio_net_hdr into RX buffers
/// (the claim-time question). N1 OBSERVED the device CONSUMES one on
/// every TX buffer; the RX descriptor is device-WRITE, so the device
/// writes the frame — and possibly its own header — into the buffer.
/// OBSERVED at claim time (2026-08-11, the live VZ gate): the device
/// DOES write one — the first received frame's device-written length was
/// 72 for a 60-byte frame, and the first 16 bytes were
/// `00 00 00 00 00 00 00 00 00 00 01 00 ff ff ff ff` — a proper
/// virtio_net_hdr (flags/gso fields zero = no offloads, `num_buffers=1`
/// in bytes 10-11) followed by the raw Ethernet frame. `rx_hdr_len=12`
/// (the same 12 the device consumes on TX) is pinned; the MAC filter's
/// dst read and `net recv`'s frame offset both use it.
pub const rx_hdr_len: usize = 12;

/// Largest single device-written RX buffer: header headroom + the largest
/// Ethernet frame (14 + 1500). OBSERVED at claim time (2026-08-11, the
/// live VZ gate): VZ's device REFUSES an RX buffer smaller than 1530
/// bytes — with `rx_buf_len=1526/1528/1529` the delivery attempt wedged
/// the whole device (no frame written, used ring never advanced, and
/// subsequent TX completions stalled until the buffer was enlarged;
/// 1530 works). The production size is 4096 (page-rounded headroom, far
/// above the observed 1530 minimum).
pub const rx_buf_len: usize = 4096;

/// Fixed BSS RX buffer (ONE buffer, one-request-at-a-time like N1's TX).
/// The device DMA-writes the frame into it; the driver invalidates before
/// reading and re-arms after every drain.
pub var rx_buf: [rx_buf_len]u8 align(16) = undefined;

/// Bounded frame FIFO capacity (fixed slots, no heap — the card-3d
/// push-from-context + shell-idle-drain pattern). Each slot holds one RAW
/// device-written buffer (header headroom included — the header question
/// is pinned by observation, not stripped blindly).
pub const fifo_slots: usize = 4;

pub const FrameSlot = struct {
    len: usize = 0,
    data: [rx_buf_len]u8 = undefined,
};

pub var rx_fifo: [fifo_slots]FrameSlot = @as([fifo_slots]FrameSlot, @splat(@as(FrameSlot, .{})));
pub var rx_fifo_head: usize = 0; // oldest slot (next to pop)
pub var rx_fifo_count: usize = 0;

/// RX counters (the `net` report): frames accepted into the FIFO, bytes
/// accepted (device-written length), frames dropped by the MAC filter,
/// FIFO overflows (drop-oldest), and the last device-written length +
/// first 16 bytes (the claim-time rx-obs record — the header question).
pub var rx_frames: u64 = 0;
pub var rx_bytes: u64 = 0;
pub var rx_filtered: u64 = 0;
pub var rx_overflow: u64 = 0;
pub var rx_last_len: u32 = 0;
pub var rx_first16: [16]u8 = @splat(0);
/// Whether the queue-0 buffer is currently supplied (armed + kicked).
pub var rx_armed: bool = false;

pub var net_dev: Device = .{};
pub var net_ops: Ops = .{
    .dev_read32 = real_dev_read32,
    .cfg_read8 = real_cfg_read8,
    .cfg_read16 = real_cfg_read16,
    .cfg_read32 = real_cfg_read32,
    .cfg_write8 = real_cfg_write8,
    .cfg_write16 = real_cfg_write16,
    .cfg_write32 = real_cfg_write32,
    .notify = real_notify,
    .to_phys = real_to_phys,
    .clean = real_clean,
    .invalidate = real_invalidate,
};

/// Transport state. Discovery/setup run pre-exit; the TX path runs
/// post-MMU on the pre-exit-captured VAs after `net_rearm`.
pub var net_dev_no: u32 = 0; // net device PCI device number
pub var net_ready: bool = false; // transport initialized, TX armed
pub var net_rearmed: bool = false; // post-exit re-arm succeeded
pub var net_common: u64 = 0; // common-config struct address (BAR + cap offset)
pub var net_notify: u64 = 0; // notify region base (BAR + cap offset)
pub var net_notify_mult: u32 = 0; // notify_off_multiplier
pub var net_queue_notify_off: u16 = 0; // queue 1's notify offset (N1's TX kick)
/// Per-queue notify offsets (common cfg 0x1e, read after queue_select —
/// Virtio 1.3 §4.1.5.2.1: the 16-bit kick is a QUEUE-INDEX write at
/// notify_base + queue_notify_off * multiplier, and each queue has its
/// OWN offset). queue 0 (RX) is card N2's kick; queue 1 (TX) is N1's.
pub var net_notify_off: [2]u16 = .{ 0, 0 };
pub var net_devcfg: u64 = 0; // device-config region (MAC read)
pub var net_bar0: u64 = 0; // net BAR0 base (the identity-map window)
pub var net_did: u32 = 0; // OBSERVED device ID (0x1041 expected)
pub var net_class: u32 = 0; // OBSERVED class code (0x020000 expected)
/// Why init/rearm failed (a static slice the `net` report can print — the
/// honest claim-time record; empty when the transport is armed).
pub var net_fail: []const u8 = "";
/// The raw device-config bytes at offset 0..5, captured PRE-EXIT (claim
/// 0013: config-space reads hang post-exit). On VZ this shows whether the
/// host-set MAC is exposed at config offset 0 even when the device does not
/// offer VIRTIO_NET_F_MAC (the claim-1373 observation; `net` prints it
/// for the record).
pub var net_devcfg_mac_obs: [6]u8 = @splat(0);
pub var net_devcfg_mac_seen: bool = false;
/// The device's OFFERED features as observed at init/rearm (low/high), so
/// a failure can name exactly what the device offered (confirm-at-claim-
/// time record).
pub var net_dev_feats_lo: u32 = 0;
pub var net_dev_feats_hi: u32 = 0;
pub var net_mac: [6]u8 = fallback_mac;
pub var net_mac_source: MacSource = .fallback;
/// "02:00:00:00:00:01" — formatted at read time for the `net` report.
pub var net_mac_text: [17]u8 = undefined;
/// device_status observed at the last successful init/re-arm (0xff when
/// the transport was never armed). Stored (not re-read live) so the `net`
/// report is deterministic and host-testable.
pub var net_status_last: u8 = 0xff;

// ---------------------------------------------------------------------------
// Pure logic (host-testable without a device)
// ---------------------------------------------------------------------------

/// Choose the guest feature mask from the device's offered features
/// (64-bit space). N1 negotiates VIRTIO_F_VERSION_1 (mandatory for modern
/// devices) and VIRTIO_NET_F_MAC when offered (the host-set address); NO
/// offload/checksum features — TX frames are raw Ethernet.
pub fn select_features(device_feats: u64) u64 {
    // A device without VIRTIO_F_VERSION_1 is unusable on the modern
    // transport — refuse it (nothing accepted).
    if ((device_feats & vf_version_1) == 0) return 0;
    var guest: u64 = vf_version_1;
    if ((device_feats & vf_net_mac) != 0) guest |= vf_net_mac;
    return guest;
}

/// Read the device MAC: the VIRTIO_NET_F_MAC path reads the 6 bytes at
/// device-config offset 0 via injected 32-bit reads (LE); the fallback
/// path copies the fixed BSS MAC. Returns true when the feature path was
/// used (the caller records the source honestly).
pub fn read_mac(dev_read32: *const fn (u32) u32, have_mac_feature: bool, out: *[6]u8) bool {
    if (have_mac_feature) {
        const lo = dev_read32(0);
        const hi = dev_read32(4);
        out[0] = @truncate(lo);
        out[1] = @truncate(lo >> 8);
        out[2] = @truncate(lo >> 16);
        out[3] = @truncate(lo >> 24);
        out[4] = @truncate(hi);
        out[5] = @truncate(hi >> 8);
        return true;
    }
    @memcpy(out, &fallback_mac);
    return false;
}

/// Format a MAC as "aa:bb:cc:dd:ee:ff" into a fixed 17-byte buffer.
pub fn format_mac(mac: *const [6]u8, out: *[17]u8) void {
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        out[i * 3] = hex[mac[i] >> 4];
        out[i * 3 + 1] = hex[mac[i] & 0xf];
        if (i < 5) out[i * 3 + 2] = ':';
    }
}

/// Build one Ethernet frame in `buf`: dst MAC, src MAC, ethertype, then the
/// payload (bounded by `payload_max` — honest truncation, never a wrap).
/// Returns the frame length (14 + payload bytes).
pub fn build_frame(
    buf: *[frame_max]u8,
    dst: *const [6]u8,
    src: *const [6]u8,
    ethertype: u16,
    payload: []const u8,
) usize {
    @memcpy(buf[0..6], dst);
    @memcpy(buf[6..12], src);
    buf[12] = @truncate(ethertype >> 8);
    buf[13] = @truncate(ethertype);
    const n = @min(payload.len, payload_max);
    @memcpy(buf[eth_hdr_len .. eth_hdr_len + n], payload[0..n]);
    return eth_hdr_len + n;
}

/// Bounded payload: `requested` clamped to `payload_max` (honest
/// truncation — the reply reports how much was dropped).
pub fn truncate_payload(requested: usize) usize {
    return @min(requested, payload_max);
}

/// Build the N1 known frame in `buf` directly (no intermediate payload
/// copy): broadcast dst, `src` MAC, ethertype 0x0800, and `requested`
/// payload bytes of the deterministic byte-index pattern (byte i = i & 0xff,
/// truncated at `payload_max`). Returns the frame length. This exact layout
/// is the byte-exact fixture the class-B gate asserts in the host capture.
pub fn build_known_frame(
    buf: *[frame_max]u8,
    src: *const [6]u8,
    requested: usize,
) usize {
    const n = truncate_payload(requested);
    @memcpy(buf[0..6], &broadcast_mac);
    @memcpy(buf[6..12], src);
    buf[12] = @truncate(eth_type_ipv4 >> 8);
    buf[13] = @truncate(eth_type_ipv4);
    var i: usize = 0;
    while (i < n) : (i += 1) buf[eth_hdr_len + i] = @truncate(i);
    return eth_hdr_len + n;
}

/// Used-ring drain accounting: given the previous drain point and the
/// device's current used.idx, report how many completions and total
/// device-written bytes lie between them (the ring's `len` fields), for a
/// queue with `queue_size` slots. Pure and host-testable.
pub const DrainReport = struct {
    completed: u16,
    bytes: u64,
};

pub fn drain_delta(last_used: u16, used_idx: u16, used_ring: *const [queue_size]VirtqUsedElem) DrainReport {
    // The device advances used.idx by one per completed buffer, so the
    // delta is the (mod queue_size) difference — with at most `queue_size`
    // requests outstanding the true delta is always < queue_size, and the
    // modulo keeps the wrap (last_used near 0xffff) exact.
    const completed: u16 = (used_idx +% queue_size -% last_used) % queue_size;
    var bytes: u64 = 0;
    var i: u16 = 0;
    while (i < completed) : (i += 1) {
        const slot = (last_used +% i) % queue_size;
        bytes += used_ring[slot].len;
    }
    return .{ .completed = completed, .bytes = bytes };
}

// ---------------------------------------------------------------------------
// Real ops (bound to the module globals + mmio/pci/mmu)
// ---------------------------------------------------------------------------

fn real_dev_read32(off: u32) u32 {
    return mmio.mmio_read32(net_devcfg + off);
}
fn real_cfg_read8(off: u32) u8 {
    return mmio.mmio_read8(net_common + off);
}
fn real_cfg_read16(off: u32) u16 {
    return mmio.mmio_read16(net_common + off);
}
fn real_cfg_read32(off: u32) u32 {
    return mmio.mmio_read32(net_common + off);
}
fn real_cfg_write8(off: u32, value: u8) void {
    mmio.mmio_write8(net_common + off, value);
}
fn real_cfg_write16(off: u32, value: u16) void {
    mmio.mmio_write16(net_common + off, value);
}
fn real_cfg_write32(off: u32, value: u32) void {
    mmio.mmio_write32(net_common + off, value);
}
fn real_notify(q: u16) void {
    // Virtio 1.3 §4.1.5.2.1: without VIRTIO_F_NOTIFICATION_DATA the
    // notification is a 16-bit write of the queue index at
    // notify_base + queue_notify_off(q) * multiplier — each queue has
    // its OWN offset (read from common cfg 0x1e after queue_select).
    const off = if (q < 2) net_notify_off[q] else net_queue_notify_off;
    mmio.mmio_write16(net_notify + @as(u64, off) * net_notify_mult, q);
}
fn real_to_phys(va: usize) u64 {
    return mmu.to_phys(va);
}
fn real_clean(ptr: usize, len: usize) void {
    mmu.clean_dcache_range(ptr, len);
}
fn real_invalidate(ptr: usize, len: usize) void {
    mmu.invalidate_dcache_range(ptr, len);
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
    net_notify = bar_base[notify_bar] + notify_off;
    net_notify_mult = notify_mult;
    if (devcfg_bar < 6) net_devcfg = bar_base[devcfg_bar] + devcfg_off;
    net_bar0 = bar_base[0];
    return bar_base[common_bar] + common_off;
}

/// Full queue setup for one virtqueue (the blk/entropy exact sequence):
/// select, size, program the three ring GPAs (claim 5804: physical), read
/// the notify offset, enable. `desc`/`avail`/`used` are the device's ring
/// globals. Returns true when the queue accepted our size and enabled.
fn setup_queue(ops: *const Ops, queue: u16, desc: *[queue_size]VirtqDesc, avail: *VirtqAvail, used: *VirtqUsed) bool {
    ops.cfg_write16(0x16, queue); // queue_select
    const qsz = ops.cfg_read16(0x18);
    if (qsz < queue_size) return false;
    ops.cfg_write16(0x18, queue_size);
    const qd = ops.to_phys(@intFromPtr(desc));
    ops.cfg_write32(0x20, @truncate(qd));
    ops.cfg_write32(0x24, @truncate(qd >> 32));
    const qa = ops.to_phys(@intFromPtr(avail));
    ops.cfg_write32(0x28, @truncate(qa));
    ops.cfg_write32(0x2c, @truncate(qa >> 32));
    const qu = ops.to_phys(@intFromPtr(used));
    ops.cfg_write32(0x30, @truncate(qu));
    ops.cfg_write32(0x34, @truncate(qu >> 32));
    ops.cfg_write16(0x1c, 1); // queue_enable
    return ops.cfg_read16(0x1c) == 1;
}

/// Write the driver feature mask (low word then high word) and check
/// FEATURES_OK. Stores the observed status in `net_status_last` and the
/// accepted mask in `dev.feats_*` (the honest `net` report). Returns true
/// when the device kept FEATURES_OK.
fn accept_features(ops: *const Ops, dev: *Device, guest_feats: u64) bool {
    dev.feats_lo = @truncate(guest_feats);
    dev.feats_hi = @truncate(guest_feats >> 32);
    ops.cfg_write32(0x08, 0);
    ops.cfg_write32(0x0c, @truncate(guest_feats));
    ops.cfg_write32(0x08, 1);
    ops.cfg_write32(0x0c, @truncate(guest_feats >> 32));
    ops.cfg_write8(0x14, 1 | 2 | 8); // FEATURES_OK
    net_status_last = ops.cfg_read8(0x14); // observed status for the record
    return (net_status_last & 8) != 0;
}

/// Shared init sequence: reset, ACKNOWLEDGE|DRIVER, negotiate features,
/// FEATURES_OK, both queues, DRIVER_OK, then the MAC read. Runs pre-exit
/// (`virtio_net_init`) and again post-exit (`net_rearm`) — VZ resets the
/// device at ExitBootServices (the claim-6420/2665 lesson). Returns true
/// when DRIVER_OK holds.
fn transport_init(ops: *const Ops, dev: *Device, rearm: bool) bool {
    if (net_common == 0) return false;
    ops.cfg_write8(0x14, 0); // reset
    var reset_spins: usize = 0;
    while (ops.cfg_read8(0x14) != 0) : (reset_spins += 1) {
        if (reset_spins >= 1_000_000) {
            net_fail = if (rearm) "re-arm: reset timeout" else "reset timeout";
            return false;
        }
    }
    ops.cfg_write8(0x14, 1 | 2); // ACKNOWLEDGE | DRIVER

    // Read the device features (64-bit), then accept our selection. The
    // offered bits are recorded for the honest claim-time report.
    ops.cfg_write32(0x00, 0);
    const feats_lo = ops.cfg_read32(0x04);
    ops.cfg_write32(0x00, 1);
    const feats_hi = ops.cfg_read32(0x04);
    net_dev_feats_lo = feats_lo;
    net_dev_feats_hi = feats_hi;
    const device_feats = (@as(u64, feats_hi) << 32) | feats_lo;

    // Walk the candidate ladder: accept a mask, check FEATURES_OK, and on
    // rejection reset (spec §3.1.1: a failed FEATURES_OK must be followed
    // by a device reset) before the next attempt. The first candidate is
    // the spec-correct selection (select_features); the fixed list covers
    // the progressively reduced / packed-layout masks the quirky VZ device
    // might need (claim-1373: it clears FEATURES_OK even for VER1-only).
    // Only masks whose bits are all OFFERED are tried. The landed mask is
    // reported honestly in `net` (accepted=...); `net_packed` records
    // whether the device forced the packed virtqueue layout.
    var ladder: [10]u64 = undefined;
    var ladder_n: usize = 0;
    {
        const spec = select_features(device_feats); // VER1 (+ MAC when offered)
        // The claim-1373 ladder. The net device's offered bits beyond the
        // custom device's proven-negotiable set (28/29 + VER1 + PACKED) are
        // 3 (MTU), 5 (MAC/GUEST_TSO4) and 16 (STATUS/CTRL_RX) — and it
        // clears FEATURES_OK even for a minimal VER1-only mask, so the
        // "needed" feature (spec §3.1.1) must be among the offered bits.
        // Masks keeping the SPLIT ring layout come first; packed-layout
        // masks are the last resorts.
        const fixed = [_]u64{
            vf_version_1 | vf_net_mtu | vf_net_mac, // split rings, most features
            vf_version_1 | vf_net_mtu | vf_net_mac | vf_net_bit16, // split rings
            vf_version_1 | vf_net_mtu, // split rings
            vf_version_1 | vf_net_mac, // split rings
            vf_version_1 | vf_net_bit16, // split rings
            vf_version_1, // split rings, absolute minimum
            vf_version_1 | vf_net_mtu | vf_net_mac | vf_ring_packed, // packed rings
            vf_version_1 | vf_ring_packed, // packed rings, minimum
        };
        if (spec != 0) {
            ladder[ladder_n] = spec;
            ladder_n += 1;
        }
        for (fixed) |cand| {
            if ((cand & ~device_feats) != 0) continue; // not offered — skip
            var dup = false;
            for (ladder[0..ladder_n]) |seen| {
                if (seen == cand) {
                    dup = true;
                    break;
                }
            }
            if (!dup) {
                ladder[ladder_n] = cand;
                ladder_n += 1;
            }
        }
    }
    var guest_feats: u64 = 0;
    var landed = false;
    for (ladder[0..ladder_n]) |cand| {
        if (!accept_features(ops, dev, cand)) {
            // Reset before the next attempt.
            ops.cfg_write8(0x14, 0);
            reset_spins = 0;
            while (ops.cfg_read8(0x14) != 0) : (reset_spins += 1) {
                if (reset_spins >= 1_000_000) {
                    net_fail = if (rearm) "re-arm: reset timeout" else "reset timeout";
                    return false;
                }
            }
            ops.cfg_write8(0x14, 1 | 2); // ACKNOWLEDGE | DRIVER
            continue;
        }
        guest_feats = cand;
        landed = true;
        break;
    }
    if (!landed) {
        net_fail = if (rearm) "re-arm: FEATURES_OK failed (no ladder mask accepted)" else "FEATURES_OK failed (no ladder mask accepted)";
        return false;
    }
    net_packed = (guest_feats & vf_ring_packed) != 0;

    // Ring init (BSS is not trusted zeroed — the console's claim-0013
    // lesson; the used rings get a clean before the first poll).
    var i: usize = 0;
    while (i < queue_size) : (i += 1) {
        dev.rx_desc[i] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
        dev.tx_desc[i] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    }
    dev.rx_avail = .{ .flags = 0, .idx = 0, .ring = @splat(0) };
    dev.rx_used = .{ .flags = 0, .idx = 0, .ring = @as([queue_size]VirtqUsedElem, @splat(@as(VirtqUsedElem, .{ .id = 0, .len = 0 }))) };
    dev.tx_avail = .{ .flags = 0, .idx = 0, .ring = @splat(0) };
    dev.tx_used = .{ .flags = 0, .idx = 0, .ring = @as([queue_size]VirtqUsedElem, @splat(@as(VirtqUsedElem, .{ .id = 0, .len = 0 }))) };
    ops.clean(@intFromPtr(&dev.rx_used), @sizeOf(VirtqUsed));
    ops.clean(@intFromPtr(&dev.tx_used), @sizeOf(VirtqUsed));
    dev.tx_last_used = 0;
    dev.rx_last_used = 0;
    // Card N2: fresh RX state per init/re-arm (BSS is not trusted zeroed).
    rx_armed = false;
    rx_frames = 0;
    rx_bytes = 0;
    rx_filtered = 0;
    rx_overflow = 0;
    rx_last_len = 0;
    rx_fifo_head = 0;
    rx_fifo_count = 0;

    // Queue 0 = RX (set up per spec; ZERO buffers supplied — RX is N2).
    if (!setup_queue(ops, 0, &dev.rx_desc, &dev.rx_avail, &dev.rx_used)) {
        net_fail = if (rearm) "re-arm: queue 0 (RX) setup failed" else "queue 0 (RX) setup failed";
        return false;
    }
    dev.q0_enabled = true;
    net_notify_off[0] = ops.cfg_read16(0x1e); // queue 0's notify offset (card N2's RX kick)
    // Queue 1 = TX (N1's queue — the used ring drains here).
    if (!setup_queue(ops, 1, &dev.tx_desc, &dev.tx_avail, &dev.tx_used)) {
        net_fail = if (rearm) "re-arm: queue 1 (TX) setup failed" else "queue 1 (TX) setup failed";
        return false;
    }
    dev.q1_enabled = true;
    net_notify_off[1] = ops.cfg_read16(0x1e); // queue 1's notify offset (N1's TX kick)
    net_queue_notify_off = net_notify_off[1];

    ops.cfg_write8(0x14, 1 | 2 | 8 | 4); // DRIVER_OK
    if ((ops.cfg_read8(0x14) & 4) == 0) {
        net_fail = if (rearm) "re-arm: DRIVER_OK failed" else "DRIVER_OK failed";
        return false;
    }
    net_status_last = ops.cfg_read8(0x14);

    // MAC: the feature path (host-set address) or the fixed BSS fallback.
    // On VZ (claim-1373 observation) the device does NOT offer the MAC
    // feature bit (or rejects accepting it), so the feature path is
    // typically unavailable and the fixed BSS MAC is the honest fallback —
    // unless the host-set address is observed in the device config anyway
    // (see `net_devcfg_mac_obs`, read pre-exit), in which case the driver
    // reads it directly (the observed contract).
    const have_mac = (guest_feats & vf_net_mac) != 0;
    if (have_mac and net_devcfg != 0) {
        net_mac_source = if (read_mac(ops.dev_read32, true, &net_mac)) .feature else .fallback;
    } else if (net_devcfg_mac_seen) {
        @memcpy(&net_mac, &net_devcfg_mac_obs);
        net_mac_source = .fallback; // observed contract, not a negotiated feature
    } else {
        @memcpy(&net_mac, &fallback_mac);
        net_mac_source = .fallback;
    }
    format_mac(&net_mac, &net_mac_text);
    // M117b (#2474, ADR 0057 D3): the link-local forms when the device
    // MAC is known — the modified EUI-64 IID is a pure function of it.
    // Idempotent across the post-exit rearm (a live address is not
    // re-tentatived).
    ipv6.form_link_local(&net_mac);

    if (rearm) {
        evidence.dump_str("VN rearm st=");
        evidence.dump_hex(ops.cfg_read8(0x14));
        evidence.dump_str(" qen=");
        evidence.dump_hex(ops.cfg_read16(0x1c));
        evidence.dump_str("\n");
    } else {
        evidence.dump_str("VN qsz=");
        evidence.dump_hex(ops.cfg_read16(0x18));
        evidence.dump_str(" qen=");
        evidence.dump_hex(ops.cfg_read16(0x1c));
        evidence.dump_str(" qoff=");
        evidence.dump_hex(net_queue_notify_off);
        evidence.dump_str(" st=");
        evidence.dump_hex(ops.cfg_read8(0x14));
        evidence.dump_str("\n");
    }
    return true;
}

/// Initialize the modern virtio-pci network transport PRE-EXIT: locate the
/// net device (DID 0x1041 — modern virtio-net; 0x1001 transitional also
/// accepted, the console's 0x1003 precedent), resolve BARs + the virtio
/// capabilities (common/notify/device), negotiate features, set up queue 0
/// (RX) + queue 1 (TX), and reach DRIVER_OK. Evidence is dumped to the
/// probe buffer so the host sees the device + queue state either way.
pub fn virtio_net_init() bool {
    if (pci.pci_ecam == 0) {
        evidence.dump_str("VN: no ECAM\n");
        net_fail = "no ECAM";
        return false;
    }

    // Locate the net device: modern DID 0x1041 (Virtio Device ID 1 + 0x1040,
    // the 2026-08-11 DID correction), transitional 0x1001 accepted too. The
    // DID actually OBSERVED is recorded in `net_did` (confirm-at-claim-
    // time: a differing DID is a finding, not an assumption). Bus 0, func 0.
    var found_dev: u32 = 32; // sentinel: not found
    var dev: u32 = 0;
    while (dev < 32) : (dev += 1) {
        const id = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0);
        if ((id & 0xffff) == 0xffff) continue;
        const did = id >> 16;
        if (did != 0x1041 and did != 0x1001) continue;
        found_dev = dev;
        net_did = did;
        net_class = (pci.pci_read32(pci.pci_ecam, 0, dev, 0, 8) >> 8) & 0xffffff;
        break;
    }
    if (found_dev == 32) {
        evidence.dump_str("VN: no virtio-net PCI device\n");
        net_fail = "DID 0x1041 not found on bus 0";
        return false;
    }
    net_dev_no = found_dev;
    evidence.dump_str("VN dev=");
    evidence.dump_hex(net_dev_no);
    evidence.dump_str(" did=");
    evidence.dump_hex(net_did);
    evidence.dump_str(" cls=");
    evidence.dump_hex(net_class);
    evidence.dump_str("\n");

    net_common = resolve_dev(net_dev_no);
    if (net_common == 0) {
        evidence.dump_str("VN: missing capability structs\n");
        net_fail = "missing capability structs";
        return false;
    }

    // Capture the raw device-config bytes at offset 0..5 PRE-EXIT (claim
    // 0013: config-space reads hang post-exit) — the claim-1373 record of
    // whether the host-set MAC is exposed even without VIRTIO_NET_F_MAC.
    if (net_devcfg != 0) {
        var mi: usize = 0;
        while (mi < 6) : (mi += 1) {
            net_devcfg_mac_obs[mi] = mmio.mmio_read8(net_devcfg + mi);
        }
        net_devcfg_mac_seen = true;
    }
    evidence.dump_str("VN common=");
    evidence.dump_hex(net_common);
    evidence.dump_str(" notify=");
    evidence.dump_hex(net_notify);
    evidence.dump_str(" devcfg=");
    evidence.dump_hex(net_devcfg);
    evidence.dump_str(" bar0=");
    evidence.dump_hex(net_bar0);
    evidence.dump_str("\n");

    if (!transport_init(&net_ops, &net_dev, false)) {
        evidence.dump_str("VN: init failed\n");
        // transport_init sets the granular reason; keep a catch-all only
        // when it failed before naming a step.
        if (net_fail.len == 0) net_fail = "init failed";
        return false;
    }
    evidence.dump_str("VN feats=");
    evidence.dump_hex(net_dev.feats_lo);
    evidence.dump_str("/");
    evidence.dump_hex(net_dev.feats_hi);
    evidence.dump_str("\n");
    net_fail = "";
    net_ready = true;
    return true;
}

/// Re-arm the transport POST-exit (claim 6420/2665's lesson): VZ resets
/// virtio devices at ExitBootServices, so the net device's status reads 0
/// and its queues are dead until the full reset → re-init sequence runs
/// again after the MMU switch. Common-config MMIO writes work post-exit
/// through the mapped Device window (verified for blk: DRIVER_OK after the
/// sequence); PCI config-space reads must stay pre-exit (claim 0013).
/// Unconditional and idempotent. The pre-rearm status is dumped so the
/// host sees whether VZ actually reset the device (the claim-6420
/// observation: status reads 0).
pub fn net_rearm() bool {
    if (net_common == 0) return false;
    evidence.dump_str("VN pre-rearm st=");
    evidence.dump_hex(net_ops.cfg_read8(0x14));
    evidence.dump_str("\n");
    if (!transport_init(&net_ops, &net_dev, true)) {
        net_fail = "re-arm failed (reset/features/queues/DRIVER_OK)";
        return false;
    }
    net_fail = "";
    net_rearmed = true;
    net_ready = true;
    return true;
}

/// Current device status (device_status register, common cfg + 0x14) —
/// reported by `net`. 0xff when the transport was never discovered.
pub fn net_status() u8 {
    if (net_common == 0) return 0xff;
    return net_ops.cfg_read8(0x14);
}

// ---------------------------------------------------------------------------
// TX path (queue 1, polled used-ring completion — claim-6420 shape)
// ---------------------------------------------------------------------------

pub const SendResult = enum {
    ok,
    not_ready,
    timeout,
    /// Card N4 (claim 0148): the peer's MAC is not in the ARP table —
    /// `net arp <ip>` resolves it first (an ICMP echo needs a unicast
    /// dst; unlike ARP it cannot broadcast).
    no_peer,
};

/// Wait for the device to consume the outstanding TX request (used.idx to
/// advance past `tx_last_used`). Returns true on completion, false after
/// `poll_retries` fresh `poll_budget` polls. Every wait refreshes the used
/// ring's cache line first (the console/blk poll pattern).
fn wait_tx_completion(ops: *const Ops, dev: *Device) bool {
    var attempt: usize = 0;
    while (attempt < poll_retries) : (attempt += 1) {
        var spins: usize = 0;
        while (spins < poll_budget) : (spins += 1) {
            ops.invalidate(@intFromPtr(&dev.tx_used), @sizeOf(VirtqUsed));
            if (dev.tx_used.idx != dev.tx_last_used) {
                // Used-ring drain accounting: every advance between the
                // drain point and the device's index is one completion.
                const report = drain_delta(dev.tx_last_used, dev.tx_used.idx, &dev.tx_used.ring);
                dev.tx_last_used = dev.tx_used.idx;
                dev.tx_frames +%= report.completed;
                return true;
            }
        }
    }
    return false;
}

/// Submit one frame on queue 1 (TX) and drain the used ring (polled).
/// `frame` must point at a bounded buffer (≤ `frame_max`; `tx_hdr_len` is
/// accounted by the caller). Returns `.ok` once the device consumed it;
/// `.not_ready` when the transport is unarmed or the frame is out of
/// bounds; `.timeout` when the completion poll budgeted out honestly.
pub fn net_send(ops: *const Ops, dev: *Device, frame: []const u8) SendResult {
    // `frame` is the WHOLE device buffer (the caller — net_send_frame —
    // prepends the zeroed virtio_net_hdr when tx_hdr_len > 0). Bounded by
    // the staging capacity.
    if (frame.len == 0 or frame.len > tx_staging.len) return .not_ready;
    if (!net_ready) return .not_ready;

    // Drain any previous completion first (claim-6420 one-request-at-a-time
    // discipline): a timed-out poll leaves the request outstanding, and its
    // used-ring advance must not be attributed to the next request.
    ops.invalidate(@intFromPtr(&dev.tx_used), @sizeOf(VirtqUsed));
    if (dev.tx_avail.idx != dev.tx_used.idx) {
        if (!wait_tx_completion(ops, dev)) {
            tx_poll_timeouts +%= 1; // #2436: the device stopped consuming
            return .timeout;
        }
    }

    // One device-read descriptor covering the whole frame. The staging
    // buffer (tx_staging) is the frame; with tx_hdr_len == 0 the frame IS
    // the raw Ethernet frame (see the constant's comment).
    dev.tx_desc[0] = .{
        .addr = ops.to_phys(@intFromPtr(frame.ptr)),
        .len = @intCast(frame.len),
        .flags = 0,
        .next = 0xffff,
    };
    dev.tx_avail.ring[dev.tx_avail.idx % queue_size] = 0; // descriptor 0
    dev.tx_avail.idx +%= 1;
    // Clean the rings + the driver-written frame so the device's DMA reads
    // the real contents.
    ops.clean(@intFromPtr(&dev.tx_desc), @sizeOf([queue_size]VirtqDesc));
    ops.clean(@intFromPtr(&dev.tx_avail), @sizeOf(VirtqAvail));
    ops.clean(@intFromPtr(frame.ptr), frame.len);
    ops.notify(1);
    if (!wait_tx_completion(ops, dev)) {
        tx_poll_timeouts +%= 1; // #2436: the device stopped consuming
        return .timeout;
    }
    dev.tx_bytes +%= frame.len;
    return .ok;
}

/// Convenience wrapper over the real transport: build the N1 known frame
/// (broadcast dst, own MAC src, ethertype 0x0800, `requested` payload bytes
/// of the deterministic pattern) in the fixed staging buffer, submit it,
/// and drain. The frame length lands in `out_len` for exact byte reports.
pub fn net_send_frame(requested: usize, out_len: *usize) SendResult {
    // Zeroed virtio_net_hdr prefix (12 B — the claim-1373 observed
    // contract), then the frame. The device strips the header; the host
    // capture carries the raw Ethernet frame byte-exactly.
    @memset(tx_staging[0..tx_hdr_len], 0);
    const frame_buf: *[frame_max]u8 = @ptrCast(&tx_staging[tx_hdr_len]);
    const frame_len = build_known_frame(frame_buf, &net_mac, requested);
    out_len.* = frame_len;
    return net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + frame_len]);
}

// ---------------------------------------------------------------------------
// RX path (queue 0, POLLED used-ring drain — the N1/blk shape)
// ---------------------------------------------------------------------------

/// Supply the queue-0 RX buffer (descriptor 0, device-WRITE) and kick so
/// the device knows a buffer is available. ONE request outstanding at a
/// time keeps the ring invariant trivial (mirror N1's TX). Called after
/// the post-exit re-arm and again after every drain. Returns false when
/// the transport is unarmed.
pub fn net_rx_arm() bool {
    if (!net_ready) return false;
    const ops = &net_ops;
    const dev = &net_dev;
    dev.rx_desc[0] = .{
        .addr = ops.to_phys(@intFromPtr(&rx_buf)),
        .len = rx_buf_len,
        .flags = virtq_f_write,
        .next = 0xffff,
    };
    dev.rx_avail.ring[dev.rx_avail.idx % queue_size] = 0; // descriptor 0
    dev.rx_avail.idx +%= 1;
    ops.clean(@intFromPtr(&dev.rx_desc), @sizeOf([queue_size]VirtqDesc));
    ops.clean(@intFromPtr(&dev.rx_avail), @sizeOf(VirtqAvail));
    ops.notify(0);
    rx_armed = true;
    // M117b (#2474, ADR 0057 D4): arming RX starts the bounded Router
    // Solicitation train — idempotent (the drain re-arms after every
    // completion).
    ndp.rx_armed();
    return true;
}

/// MAC filter: accept own MAC + broadcast (`ff:ff:ff:ff:ff:ff`) + the
/// bounded v6 multicast set (ADR 0057 D2: all-nodes `33:33:00:00:00:01`
/// and the solicited-node group `33:33:ff:xx:xx:xx` of every
/// formed-or-tentative v6 address — they share the IID, so the set is
/// ONE computed group, never stored). Everything else still drops.
/// `off` is the frame start in the buffer (the `rx_hdr_len` constant —
/// pinned from observation at claim time). Pure and host-testable.
pub fn mac_accept(off: usize, buf: []const u8, own: *const [6]u8) bool {
    if (off + 6 > buf.len) return false;
    const dst = buf[off .. off + 6];
    var own_match = true;
    var bcast = true;
    var allnodes = true;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        if (dst[i] != own[i]) own_match = false;
        if (dst[i] != 0xff) bcast = false;
        if (dst[i] != ipv6.all_nodes_mac[i]) allnodes = false;
    }
    if (own_match or bcast or allnodes) return true;
    // The solicited-node group: admitted once an IID exists (the
    // link-local formed-or-tentative — every owned address shares the
    // IID's low 24 bits).
    if (ipv6.have_iid and dst[0] == 0x33 and dst[1] == 0x33 and dst[2] == 0xff and
        dst[3] == ipv6.iid[5] and dst[4] == ipv6.iid[6] and dst[5] == ipv6.iid[7]) return true;
    return false;
}

/// Push `frame` (the RAW device-written buffer bytes) into the bounded
/// FIFO. Drop-oldest on overflow (the newest frame wins — the card-3d
/// contract; `rx_overflow` counts the drops). Returns false only when the
/// frame exceeds a slot (should never happen — buffers are bounded).
pub fn fifo_push(frame: []const u8) bool {
    if (frame.len > rx_buf_len) return false;
    if (rx_fifo_count == fifo_slots) {
        rx_fifo_head = (rx_fifo_head + 1) % fifo_slots; // drop the oldest
        rx_fifo_count -= 1;
        rx_overflow +%= 1;
    }
    const slot = (rx_fifo_head + rx_fifo_count) % fifo_slots;
    @memcpy(rx_fifo[slot].data[0..frame.len], frame);
    rx_fifo[slot].len = frame.len;
    rx_fifo_count += 1;
    return true;
}

/// Peek the oldest FIFO frame (a pointer into the FIFO — valid until the
/// next push/pop). Returns null when empty. `net recv` prints via this
/// (no stack copy of a 1526-byte slot on the kernel stack), then advances
/// with `fifo_pop_advance`.
pub fn fifo_peek() ?[]const u8 {
    if (rx_fifo_count == 0) return null;
    const slot = rx_fifo_head;
    return rx_fifo[slot].data[0..rx_fifo[slot].len];
}

/// Advance past the oldest FIFO frame after it was reported (consume).
pub fn fifo_pop_advance() void {
    if (rx_fifo_count == 0) return;
    rx_fifo_head = (rx_fifo_head + 1) % fifo_slots;
    rx_fifo_count -= 1;
}

/// Current FIFO occupancy (the `net` report's fifo=).
pub fn fifo_occupancy() usize {
    return rx_fifo_count;
}

/// Drain the RX used ring (POLLED — the proven N1/blk shape; the net
/// device's used-buffer IRQ is not yet observed on this platform, so
/// there is no IRQ-context push in N2 — recorded honestly in the claim).
/// On a completion: read the device-written frame out of `rx_buf`
/// (invalidating the cache line first — the device DMA-wrote it), MAC-
/// filter it (own + broadcast), push accepted frames into the bounded
/// FIFO, re-arm the buffer. Idempotent; called from the shell idle loop
/// and before the `net`/`net recv` reports.
pub fn net_rx_drain() void {
    if (!net_ready or !rx_armed) return;
    const ops = &net_ops;
    const dev = &net_dev;
    ops.invalidate(@intFromPtr(&dev.rx_used), @sizeOf(VirtqUsed));
    if (dev.rx_used.idx == dev.rx_last_used) return;
    const report = drain_delta(dev.rx_last_used, dev.rx_used.idx, &dev.rx_used.ring);
    dev.rx_last_used = dev.rx_used.idx;
    if (report.completed == 0) return;

    // The device wrote into rx_buf — invalidate before reading. The RX
    // used-element `len` is the DEVICE-WRITTEN length (N1's TX `len` was
    // ~0); one request outstanding means one completion per drain.
    ops.invalidate(@intFromPtr(&rx_buf), rx_buf_len);
    const dev_len: usize = @intCast(report.bytes);
    if (dev_len > rx_buf_len) {
        // Device overran the bound — honest record, drop, re-arm.
        rx_filtered +%= 1;
        rx_last_len = rx_buf_len;
        _ = net_rx_arm();
        return;
    }
    rx_last_len = @intCast(dev_len);
    // The claim-time rx-obs record: the first 16 device-written bytes pin
    // the RX-header question (12 zero bytes + dst MAC = header present;
    // dst MAC at 0 = none). Recorded even when the filter drops, so a
    // drop is distinguishable from a failed delivery.
    const n16 = @min(dev_len, 16);
    var i: usize = 0;
    while (i < n16) : (i += 1) rx_first16[i] = rx_buf[i];

    // MAC filter: the frame starts at `rx_hdr_len` (the claim-time
    // constant — a wrong guess shows as filtered=1 + a distinctive
    // rx-obs, and is corrected like tx_hdr_len was).
    if (!mac_accept(rx_hdr_len, rx_buf[0..dev_len], &net_mac)) {
        rx_filtered +%= 1;
    } else {
        _ = fifo_push(rx_buf[0..dev_len]);
        rx_frames +%= 1;
        rx_bytes +%= dev_len;
        // Card N3 (claim 7293): ARP dispatch — the frame's Ethernet
        // header starts at `rx_hdr_len` (the observed RX-header
        // contract). A request for our static IP is answered (the reply
        // is built in tx_staging and transmitted on the N1 TX path,
        // one-request-at-a-time); a reply is learned into the bounded
        // table. The raw frame ALSO stays in the FIFO for `net recv`
        // observation — the N2 seam is unchanged.
        rx_arp(rx_buf[rx_hdr_len..dev_len]);
        // Card N4 (claim 0148): IPv4/ICMP dispatch — an echo request
        // for our static IP is answered byte-exact; an echo reply is
        // observed (`pongs_observed`); fragments / bad checksums /
        // foreign addresses are counted and dropped (N4 does NOT
        // reassemble — honest bound). The raw frame stays in the FIFO
        // for `net recv` observation, same seam.
        rx_ipv4(rx_buf[rx_hdr_len..dev_len]);
        // M117b (#2474, ADR 0057 D1): the 0x86dd leaf on the same demux
        // seam — self-filters on ethertype like the ARP/IPv4 handlers;
        // NDP answers (NA) and ICMPv6 echo replies are built into
        // tx_staging and transmitted on the same TX path. The raw frame
        // stays in the FIFO for `net recv` observation.
        rx_ipv6(rx_buf[rx_hdr_len..dev_len]);
    }
    _ = net_rx_arm();
}

/// Card N3 (claim 7293): dispatch one accepted Ethernet frame to the ARP
/// layer. `frame` starts at the Ethernet header (the RX virtio_net_hdr
/// already skipped — the caller passed `rx_buf[rx_hdr_len..]`). A request
/// for our protocol address is answered: the reply is built into
/// `tx_staging` (after the zeroed virtio_net_hdr) and transmitted on the
/// N1 TX path; a reply is learned by `arp.handle_rx`; malformed /
/// not-for-us frames are counted and dropped by the ARP layer. A send
/// failure is counted honestly (`arp.reply_tx_fail`) — the polled TX
/// path can time out, and that is recorded, never assumed away.
fn rx_arp(frame: []const u8) void {
    const reply_len = arp.handle_rx(frame, &net_mac, tx_staging[tx_hdr_len .. tx_hdr_len + arp.arp_frame_len]) orelse return;
    // The zeroed virtio_net_hdr prefix (the observed claim-1373 TX
    // contract — a stale header's flags/gso fields would corrupt the
    // delivered reply).
    @memset(tx_staging[0..tx_hdr_len], 0);
    switch (net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + reply_len])) {
        .ok => arp.replies_sent += 1,
        else => arp.reply_tx_fail += 1,
    }
}

/// Card N4 (claim 0148): dispatch one accepted Ethernet frame to the
/// IPv4/ICMP layer. `frame` starts at the Ethernet header. An echo
/// request for our static IP is answered byte-exact: the reply is built
/// into `tx_staging` (after the zeroed virtio_net_hdr) and transmitted
/// on the N1 TX path; an echo reply is observed (`pongs_observed`,
/// `last_seq`); fragments / bad checksums / foreign addresses are
/// counted and dropped by the IPv4 layer. A send failure is counted
/// honestly (`ipv4.reply_tx_fail`), same as the ARP path.
fn rx_ipv4(frame: []const u8) void {
    const reply_len = ipv4.handle_rx(frame, &net_mac, tx_staging[tx_hdr_len .. tx_hdr_len + ipv4.ipv4_frame_min + 64]) orelse return;
    // The zeroed virtio_net_hdr prefix — the observed claim-1373 TX
    // contract (a stale header's flags/gso fields would corrupt the
    // delivered reply).
    @memset(tx_staging[0..tx_hdr_len], 0);
    switch (net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + reply_len])) {
        .ok => ipv4.replies_sent += 1,
        else => ipv4.reply_tx_fail += 1,
    }
}

/// M117b (#2474, ADR 0057 D1): dispatch one accepted Ethernet frame to
/// the IPv6 layer. `frame` starts at the Ethernet header (the RX
/// virtio_net_hdr already skipped). An NS for an owned address is
/// answered with an NA; an ICMPv6 echo request for an owned address is
/// answered byte-exact; an RA feeds SLAAC (D4); a solicited NA is
/// learned; every drop is counted by cause. A send failure is counted
/// honestly (`reply_tx_fail` on the right counter), same as the v4
/// path.
fn rx_ipv6(frame: []const u8) void {
    const reply = ipv6.handle_rx(frame, &net_mac, tx_staging[tx_hdr_len..]) orelse return;
    // The zeroed virtio_net_hdr prefix — the observed claim-1373 TX
    // contract (a stale header's flags/gso fields would corrupt the
    // delivered reply).
    @memset(tx_staging[0..tx_hdr_len], 0);
    switch (net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + reply.len])) {
        .ok => if (reply.na) {
            ndp.na_sent += 1;
        } else {
            ipv6.replies_sent += 1;
        },
        else => if (reply.na) {
            ndp.reply_tx_fail += 1;
        } else {
            ipv6.reply_tx_fail += 1;
        },
    }
}

/// The v6 send result (M117b, ADR 0057 D3/D9): the v4 `SendResult`
/// plus the named refusals — kept a separate enum so the v4 enum's
/// exhaustive switches are untouched.
pub const Send6Result = enum {
    ok,
    not_ready,
    timeout,
    /// The next-hop MAC is not in the NDP table (`net ndp <addr>`
    /// resolves it first — an echo needs a unicast dst).
    no_peer,
    /// A non-link-local destination with no valid global — never a
    /// silent link-local leak (D3).
    no_src6,
    /// An off-link destination with no recorded router (D9).
    no_route6,
    /// A multicast, unspecified, or loopback destination (D9).
    bad_dst6,
};

/// M117b (#2474, ADR 0057 D4/D5): the tick-seam driver for the bounded
/// RS train + one-probe DAD, on the same polled-drain time engine as
/// `net_dhcp_poll` (the caller stamps `ndp.now_ticks` first). Order per
/// call: promote tentative addresses whose wait elapsed, transmit any
/// pending DAD probes, then pace the ≤3 Router Solicitations one per
/// tick. Returns the transitions so the caller can print them (the
/// `net_dhcp_poll` shape — sends here, print decisions stay with the
/// monitor).
pub const NdpPoll = struct {
    promoted_ll: bool = false,
    promoted_g6: bool = false,
    rs_sent: bool = false, // a Router Solicitation went out this poll
};

pub fn net_ndp_poll() NdpPoll {
    var ev: NdpPoll = .{};
    if (!net_ready) return ev;
    while (ndp.dad_due()) |addr| {
        if (ipv6.promote(&addr)) {
            if (std.mem.eql(u8, &addr, &ipv6.link_local)) {
                ev.promoted_ll = true;
            } else {
                ev.promoted_g6 = true;
            }
        }
    }
    while (ndp.dad_pending()) |p| {
        @memset(tx_staging[0..tx_hdr_len], 0);
        const n = ndp.build_dad_ns(tx_staging[tx_hdr_len .. tx_hdr_len + ndp.frame_len_max], &net_mac, &p.addr);
        switch (net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + n])) {
            .ok => {
                ndp.dad_mark_sent(p.slot);
                ndp.dad_sent += 1;
            },
            else => {
                ndp.reply_tx_fail += 1;
                return ev; // the TX path is wedged — retry next poll
            },
        }
    }
    if (ndp.rs_due()) {
        @memset(tx_staging[0..tx_hdr_len], 0);
        const n = ndp.build_rs(tx_staging[tx_hdr_len .. tx_hdr_len + ndp.frame_len_max], &net_mac, &ipv6.link_local);
        switch (net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + n])) {
            .ok => {
                ndp.rs_note_sent();
                ev.rs_sent = true;
            },
            else => ndp.reply_tx_fail += 1,
        }
    }
    return ev;
}

/// M117b (#2474, ADR 0057 D9): transmit a NEIGHBOR SOLICITATION for the
/// NEXT HOP toward `dst` — the literal address when on-link, the
/// router's link-local when off-link (the `net_arp_request` next-hop
/// precedent). The NA is learned asynchronously by the RX drain.
/// Named refusals: `bad_dst6` (multicast/unspecified/loopback),
/// `no_src6` (no valid link-local to source from), `no_route6`
/// (off-link, no router). The frame length lands in `out_len` (86).
pub fn net_ndp_solicit(dst: ipv6.Addr, out_len: *usize) Send6Result {
    if (!net_ready) return .not_ready;
    if (ipv6.is_bad_dst(dst)) return .bad_dst6;
    if (ipv6.link_local_state != .valid) return .no_src6; // the NS's source
    const target = ipv6.next_hop(&dst) orelse return .no_route6;
    @memset(tx_staging[0..tx_hdr_len], 0);
    const n = ndp.build_ns(tx_staging[tx_hdr_len .. tx_hdr_len + ndp.frame_len_max], &net_mac, &ipv6.link_local, &target);
    out_len.* = n;
    return switch (net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + n])) {
        .ok => .ok,
        .timeout => .timeout,
        else => .not_ready,
    };
}

/// M117b (#2474, ADR 0057 D3/D9): transmit an ICMPv6 ECHO REQUEST to
/// `dst` — the Ethernet dst is the NEXT HOP's learned MAC (the peer
/// itself on-link, the router off-link), the v6 src is D3's source
/// selection, the v6 dst stays the literal peer. The next hop must be
/// resolved first (`net ndp <addr>` — the pending-slot + tick-seam
/// wait is the ARP shape). Named refusals: `bad_dst6` / `no_route6` /
/// `no_src6` / `no_peer`. The frame length lands in `out_len` (66). The
/// reply is observed asynchronously by the RX drain (`pongs_observed`
/// + `last_seq`).
pub fn net_ping6_request(dst: ipv6.Addr, out_len: *usize) Send6Result {
    if (!net_ready) return .not_ready;
    if (ipv6.is_bad_dst(dst)) return .bad_dst6;
    const target = ipv6.next_hop(&dst) orelse return .no_route6;
    const src = ipv6.select_src(&dst) orelse return .no_src6;
    const peer_mac = ndp.lookup(&target) orelse return .no_peer;
    @memset(tx_staging[0..tx_hdr_len], 0);
    const n = ipv6.build_echo_request(tx_staging[tx_hdr_len .. tx_hdr_len + ipv6.ipv6_frame_min + 4], &net_mac, &src, &dst, &peer_mac);
    out_len.* = n;
    return switch (net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + n])) {
        .ok => .ok,
        .timeout => .timeout,
        else => .not_ready,
    };
}

/// Card N3 (claim 7293): transmit an ARP REQUEST for `target_ip`
/// (broadcast dst, our MAC + static IP as sender, zeroed target HW) in
/// the fixed staging buffer, on the N1 TX path. Refuses honestly when the
/// transport is unready or no static IP is set (`net ip <a.b.c.d>`
/// first). The reply is learned asynchronously by the RX drain. The frame
/// length lands in `out_len` (42). The wire request asks for the NEXT
/// HOP toward `target_ip` (`arp.next_hop`): on-link peers resolve
/// themselves; an off-subnet target resolves the default gateway — the
/// learned reply then answers `arp.lookup(target_ip)`'s next-hop query.
pub fn net_arp_request(target_ip: [4]u8, out_len: *usize) SendResult {
    if (!net_ready) return .not_ready;
    if (!arp.ip_set()) return .not_ready;
    @memset(tx_staging[0..tx_hdr_len], 0);
    const n = arp.build_request(tx_staging[tx_hdr_len .. tx_hdr_len + arp.arp_frame_len], &net_mac, arp.own_ip, arp.next_hop(target_ip));
    out_len.* = n;
    return net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + n]);
}

/// Card N5 (claim 8552): transmit a UDP DATAGRAM to
/// `target_ip:dst_port` in the fixed staging buffer, on the N1 TX path.
/// Refuses honestly when the transport is unready, no static IP is set
/// (`net ip <a.b.c.d>` first), or the peer's MAC is not in the ARP table
/// (`net arp <ip>` resolves it first — an echo/udp needs a unicast dst).
/// A send to OUR OWN IP takes the LOOPBACK path (delivered directly into
/// the local receive path — no device round trip). `payload` is the
/// deterministic byte pattern 01 02 03 04… (bounded ≤ 64 — honest
/// truncation). The datagram length lands in `out_len` (8 + payload).
pub fn net_udp_send(target_ip: [4]u8, dst_port: u16, payload: []const u8, out_len: *usize) SendResult {
    if (!arp.ip_set()) return .not_ready;
    if (std.mem.eql(u8, &target_ip, &arp.own_ip)) {
        // Loopback: no device round trip — `udp.loopback` builds the
        // datagram (src port 7000) and delivers it locally; the delivery
        // counts `received` (or `dropped_closed` — no listener).
        out_len.* = udp.loopback(arp.own_ip, dst_port, payload);
        udp.sent += 1;
        udp.loopbacked += 1;
        return .ok;
    }
    if (!net_ready) return .not_ready;
    const peer_mac = arp.lookup(target_ip) orelse return .no_peer;
    @memset(tx_staging[0..tx_hdr_len], 0);
    const n = udp.build_frame(tx_staging[tx_hdr_len .. tx_hdr_len + udp.frame_max], &net_mac, arp.own_ip, peer_mac, target_ip, dst_port, payload);
    out_len.* = n;
    const r = net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + n]);
    if (r == .ok) udp.sent += 1;
    return r;
}

/// M97e-F5 (#2104): `net_udp_send` with an explicit source port — the
/// DNS client's ephemeral-port send (its listener seat is bound to the
/// same port). Same checks, same loopback shortcut (a self-addressed
/// datagram is degenerate — the loopback builder's src port stays the
/// fixed default; the reply path it feeds is the local ring, not the
/// wire, so the port draw is unaffected).
pub fn net_udp_send_from(target_ip: [4]u8, src_port: u16, dst_port: u16, payload: []const u8, out_len: *usize) SendResult {
    if (!arp.ip_set()) return .not_ready;
    if (std.mem.eql(u8, &target_ip, &arp.own_ip)) {
        out_len.* = udp.loopback(arp.own_ip, dst_port, payload);
        udp.sent += 1;
        udp.loopbacked += 1;
        return .ok;
    }
    if (!net_ready) return .not_ready;
    const peer_mac = arp.lookup(target_ip) orelse return .no_peer;
    @memset(tx_staging[0..tx_hdr_len], 0);
    const n = udp.build_frame_ex(tx_staging[tx_hdr_len .. tx_hdr_len + udp.frame_max], peer_mac, &net_mac, arp.own_ip, target_ip, src_port, dst_port, payload);
    out_len.* = n;
    const r = net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + n]);
    if (r == .ok) udp.sent += 1;
    return r;
}

/// Card N8 (claim 0351): transmit the DHCP client's current message (a
/// DISCOVER or a REQUEST — built by `dhcp` into `dhcp.msg`) on the N1 TX
/// path. The card's ONE N5-layer seam change: a DHCP frame goes out with
/// dst MAC ff:ff:ff:ff:ff:ff + dst IP 255.255.255.255 DIRECTLY — no ARP
/// lookup (the N2 MAC filter accepts broadcast on the way back) — and the
/// src IP is 0.0.0.0 (the client in INIT/SELECTING has NO address yet),
/// so this path deliberately does NOT require `arp.ip_set()`. Refuses
/// honestly when the transport is unready. The frame length lands in
/// `out_len` (286 DISCOVER / 298 REQUEST). The reply is processed
/// asynchronously by the RX drain (the udp port-68 dispatch -> dhcp).
pub fn net_dhcp_send(msg: []const u8, out_len: *usize) SendResult {
    if (!net_ready) return .not_ready;
    @memset(tx_staging[0..tx_hdr_len], 0);
    const bcast_mac = [6]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    const bcast_ip = [4]u8{ 255, 255, 255, 255 };
    const src_ip = [4]u8{ 0, 0, 0, 0 }; // the client pre-lease address
    const n = udp.build_frame_ex(tx_staging[tx_hdr_len .. tx_hdr_len + dhcp.frame_max], bcast_mac, &net_mac, src_ip, bcast_ip, dhcp.client_port, dhcp.server_port, msg);
    out_len.* = n;
    return net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + n]);
}

/// Card N9 (claim 9489): transmit the REBINDING REQUEST — the SAME
/// broadcast shape as `net_dhcp_send`, but the client now HOLDS the
/// lease, so the src IP is `dhcp.lease_ip` (RFC 2131 §4.4.5 — a bound
/// client's REQUEST carries its address; the frame's ciaddr is set by
/// `dhcp.enter_rebinding`). Refuses honestly when the transport is
/// unready or no lease is held.
pub fn net_dhcp_send_bound(msg: []const u8, out_len: *usize) SendResult {
    if (!net_ready) return .not_ready;
    if (!dhcp_bound()) return .not_ready;
    @memset(tx_staging[0..tx_hdr_len], 0);
    const bcast_mac = [6]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    const bcast_ip = [4]u8{ 255, 255, 255, 255 };
    const n = udp.build_frame_ex(tx_staging[tx_hdr_len .. tx_hdr_len + dhcp.frame_max], bcast_mac, &net_mac, dhcp.lease_ip, bcast_ip, dhcp.client_port, dhcp.server_port, msg);
    out_len.* = n;
    return net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + n]);
}

/// Card N9 (claim 9489): transmit the RENEWING REQUEST UNICAST to the
/// server — dst = the server's IP + the MAC the caller RESOLVED (the
/// seam resolves nothing; `.no_peer` when the caller has no MAC), src =
/// the leased IP (the bound client). The frame's ciaddr is set by
/// `dhcp.enter_renewing`. Refuses honestly when the transport is
/// unready or no lease is held.
pub fn net_dhcp_send_unicast(dst_ip: [4]u8, dst_mac: [6]u8, msg: []const u8, out_len: *usize) SendResult {
    if (!net_ready) return .not_ready;
    if (!dhcp_bound()) return .not_ready;
    @memset(tx_staging[0..tx_hdr_len], 0);
    const n = udp.build_frame_ex(tx_staging[tx_hdr_len .. tx_hdr_len + dhcp.frame_max], dst_mac, &net_mac, dhcp.lease_ip, dst_ip, dhcp.client_port, dhcp.server_port, msg);
    out_len.* = n;
    return net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + n]);
}

/// Card N10 (claim 7026): transmit the TCP client's current segment
/// (built by `tcp` into `tcp.msg` — a SYN, an ACK, a data segment, the
/// FIN, a RST, or the final ACK) to THE connection's peer on the N1 TX
/// path. The peer's MAC was resolved at connect time (`tcp.peer_mac` —
/// the seam resolves nothing; the bounded client connects OUTWARD only —
/// an own-IP connect was refused by the caller, no TCP loopback).
/// Refuses honestly when the transport is unready or no static IP is set
/// (`net ip <a.b.c.d>` first). The frame length lands in `out_len` (54 +
/// the segment payload). The peer's segments are processed asynchronously
/// by the RX drain (the ipv4 protocol-6 dispatch -> tcp).
pub fn net_tcp_send(segment: []const u8, out_len: *usize) SendResult {
    if (!net_ready) return .not_ready;
    if (!arp.ip_set()) return .not_ready;
    @memset(tx_staging[0..tx_hdr_len], 0);
    const n = tcp.build_frame(tx_staging[tx_hdr_len .. tx_hdr_len + tcp.frame_max], &net_mac, arp.own_ip, tcp.peer_mac, tcp.peer_ip, segment);
    out_len.* = n;
    return net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + n]);
}

fn socket_transmit(_: ?*anyopaque, outbound: native_socket.core.Outbound) bool {
    if (!net_ready or !arp.ip_set()) return false;
    @memset(tx_staging[0..tx_hdr_len], 0);
    const n = tcp.build_frame(tx_staging[tx_hdr_len .. tx_hdr_len + tcp.frame_max], &net_mac, outbound.local.ip, outbound.remote_mac, outbound.remote.ip, outbound.bytes);
    return net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + n]) == .ok;
}

/// #2436 diagnostics: `net_send` completion-poll exhaustions — the device
/// (VZ's attachment write into the capture socketpair) stopped consuming
/// for a whole poll budget. Surfaced by the idle-loop diag line.
pub var tx_poll_timeouts: u64 = 0;

/// #2436 diagnostics (bounded, transition-only): the agentctl-under-flood
/// conn-death evidence. `net_socket_poll` snapshots a child that just
/// turned terminal; the shell idle loop drains the 4-deep queue onto the
/// console — one line per EVENT, never per frame. `socket_core.zig`
/// itself is untouched (claimed by M113c).
pub const ConnTomb = struct {
    slot: usize,
    /// `.none` here means "released live" (releaseAt — the app's close
    /// raced no terminal state); `.eof` is the clean FIN dance and is
    /// NOT tombstoned (every healthy session ends there).
    outcome: native_socket.core.Outcome,
    state: native_socket.core.State,
    local_port: u16,
    remote_port: u16,
    owner: u64,
    retries: u8,
    tx_len: usize,
    rx_len: usize,
    peer_window: u32,
    in_flight: u32,
    rto_ms: u64,
    last_tx_age_ms: u64,
    tx_poll_timeouts: u64,
};
const tomb_max = 4;
var tombs: [tomb_max]ConnTomb = undefined;
var tomb_head: usize = 0;
var tomb_count: usize = 0;
var diag_child_state: [native_socket.core.conn_limit]native_socket.core.State = @splat(.terminal);
var diag_child_tomb: [native_socket.core.conn_limit]ConnTomb = undefined;
var diag_last_counters: native_socket.core.Counters = .{};
var diag_last_tpt: u64 = 0;
var diag_last_rm1: u64 = 0;

fn sock_diag_watch() void {
    const now = native_socket.now();
    for (&native_socket.sockets.children, 0..) |*entry, i| {
        const was = diag_child_state[i];
        if (entry.*) |*c| {
            // Keep a live snapshot so a straight release can still name
            // the conn's last shape (the fields are gone by then).
            diag_child_tomb[i] = .{
                .slot = i,
                .outcome = c.outcome,
                .state = c.state,
                .local_port = c.local.port,
                .remote_port = c.remote.port,
                .owner = c.owner,
                .retries = c.retries,
                .tx_len = c.tx_len,
                .rx_len = c.rx_len,
                .peer_window = c.peer_window,
                .in_flight = c.snd_nxt -% c.snd_una,
                .rto_ms = c.rto_ns_cur / 1_000_000,
                .last_tx_age_ms = (now -| c.last_tx) / 1_000_000,
                .tx_poll_timeouts = tx_poll_timeouts,
            };
            diag_child_state[i] = c.state;
        } else {
            diag_child_state[i] = .terminal;
        }
        if (was == .terminal) continue;
        // A conn that went terminal abnormally, or one released while
        // still half_open/established/closing — the flake's two teardown
        // shapes. The .eof finish is every healthy session's end and
        // stays silent.
        const died = entry.* != null and entry.*.?.state == .terminal and entry.*.?.outcome != .eof;
        const released_live = entry.* == null and was != .terminal;
        if ((died or released_live) and tomb_count < tomb_max) {
            tombs[(tomb_head + tomb_count) % tomb_max] = if (entry.* != null) diag_child_tomb[i] else blk: {
                var t = diag_child_tomb[i];
                t.state = .terminal;
                break :blk t;
            };
            tomb_count += 1;
        }
    }
}

/// Idle-loop drain: pop one connection tombstone; null when empty.
pub fn net_diag_tomb() ?ConnTomb {
    if (tomb_count == 0) return null;
    const t = tombs[tomb_head];
    tomb_head = (tomb_head + 1) % tomb_max;
    tomb_count -= 1;
    return t;
}

/// The socket-table counters plus the transport's own poll timeouts and
/// the bit-0 ready-probe count; `probe` is the last bit-0 probe's shape,
/// non-null only when that count moved — the caller prints one line per
/// change.
pub fn net_diag_counters() ?struct { c: native_socket.core.Counters, tpt: u64, rm1: u64, probe: ?native_socket.ReadyProbe } {
    const cur = native_socket.sockets.counters;
    const tpt = tx_poll_timeouts;
    const rm1 = native_socket.ready_mask1_count;
    if (std.meta.eql(cur, diag_last_counters) and tpt == diag_last_tpt and rm1 == diag_last_rm1) return null;
    const probe: ?native_socket.ReadyProbe = if (rm1 != diag_last_rm1) native_socket.ready_mask1_probe else null;
    diag_last_counters = cur;
    diag_last_tpt = tpt;
    diag_last_rm1 = rm1;
    return .{ .c = cur, .tpt = tpt, .rm1 = rm1, .probe = probe };
}

/// NET lock held. Bounded maintenance even with no application traffic.
pub fn net_socket_poll() void {
    native_socket.poll();
    for (0..native_socket.core.conn_limit * 2 + 1) |_| {
        if (native_socket.sockets.flush(null, socket_transmit) != .sent) break;
    }
    sock_diag_watch();
}

pub fn net_socket_dns_send(server: [4]u8, query: []const u8) SendResult {
    if (!net_ready or !arp.ip_set()) return .not_ready;
    // M97e-F5 (#2104): the query rides the transaction's ephemeral port
    // (beginDns bound it — a send with no transaction open is refused).
    const d = native_socket.dns orelse return .not_ready;
    const mac = arp.lookup(server) orelse return .no_peer;
    @memset(tx_staging[0..tx_hdr_len], 0);
    const n = udp.build_frame_ex(tx_staging[tx_hdr_len..], mac, &net_mac, arp.own_ip, server, d.port, 53, query);
    return net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + n]);
}

/// Card N9 (claim 9489): the client holds a live lease (its address is
/// usable for a renewal).
fn dhcp_bound() bool {
    return dhcp.state == .bound or dhcp.state == .renewing or dhcp.state == .rebinding;
}

/// Issue #119 (audit follow-up 3): the result of one autonomous DHCP
/// lifecycle poll — the step applied plus the elapsed/lease captured at
/// decision time (expire() zeroes the lease record, so the print needs
/// the pre-transition values) and the REQUEST transmit outcome. `none`
/// = no transition demanded; `renew_no_arp` = T1 reached but the server
/// MAC is unresolved (the client honestly stays BOUND, RFC-compliant
/// degradation — the `net dhcp` command surfaces the diagnostic).
pub const DhcpPollStep = enum { none, expired, rebinding, renewing, renew_no_arp };

pub const DhcpPoll = struct {
    step: DhcpPollStep,
    elapsed: u64,
    lease: u32,
    out_len: usize,
    tx_ok: bool,
};

/// Issue #119 (audit follow-up 3): the autonomous DHCP lease lifecycle —
/// advance the RFC 2131 §4.4.5 state machine ONE step as the elapsed
/// lease time demands (T1 -> RENEWING, T2 -> REBINDING, expiry ->
/// release), applying the transition + transmitting the REQUEST exactly
/// as `net dhcp` would. Called from the shell idle loop each iteration
/// (the polled-drain time engine — the same seam as `tcp.poll_rto`)
/// AFTER the RX drain, so a pending renewal ACK has restarted the lease
/// clock first. The re-DISCOVER after expiry stays command-triggered
/// (the bounded handshake; the client honestly drops to idle at expiry
/// and `net dhcp` re-binds). The RENEWING unicast needs the server MAC
/// (`arp.lookup`) — without it the client honestly stays BOUND until T2
/// (RFC-compliant degradation, `.renew_no_arp`). A TX failure leaves
/// `request_transmitted` false for the next `net dhcp` (no per-second
/// spam).
pub fn net_dhcp_poll() DhcpPoll {
    if (!net_ready) return .{ .step = .none, .elapsed = dhcp.elapsed(), .lease = dhcp.lease_time, .out_len = 0, .tx_ok = true };
    const el = dhcp.elapsed();
    const lease = dhcp.lease_time;
    var out_len: usize = 0;
    switch (dhcp.step_lifecycle()) {
        .none => return .{ .step = .none, .elapsed = el, .lease = lease, .out_len = 0, .tx_ok = true },
        .expire => {
            dhcp.expire();
            return .{ .step = .expired, .elapsed = el, .lease = lease, .out_len = 0, .tx_ok = true };
        },
        .rebind => {
            dhcp.enter_rebinding();
            const ok = net_dhcp_send_bound(dhcp.msg[0..dhcp.msg_len], &out_len) == .ok;
            if (ok) {
                dhcp.request_transmitted = true;
                dhcp.rebind_sent += 1;
            }
            return .{ .step = .rebinding, .elapsed = el, .lease = lease, .out_len = out_len, .tx_ok = ok };
        },
        .renew => {
            const srv_mac = arp.lookup(dhcp.lease_server) orelse
                return .{ .step = .renew_no_arp, .elapsed = el, .lease = lease, .out_len = 0, .tx_ok = true };
            dhcp.enter_renewing();
            const ok = net_dhcp_send_unicast(dhcp.lease_server, srv_mac, dhcp.msg[0..dhcp.msg_len], &out_len) == .ok;
            if (ok) {
                dhcp.request_transmitted = true;
                dhcp.renew_sent += 1;
            }
            return .{ .step = .renewing, .elapsed = el, .lease = lease, .out_len = out_len, .tx_ok = ok };
        },
    }
}

/// Card N4 (claim 0148): transmit an ICMP ECHO REQUEST to `target_ip` in
/// the fixed staging buffer, on the N1 TX path. Refuses honestly when the
/// transport is unready, no static IP is set (`net ip <a.b.c.d>` first),
/// or the peer's MAC is not in the ARP table (`net arp <ip>` resolves it
/// first — an echo needs a unicast dst). The frame length lands in
/// `out_len` (46). The reply is observed asynchronously by the RX drain
/// (`pongs_observed` + `last_seq`).
pub fn net_ping_request(target_ip: [4]u8, out_len: *usize) SendResult {
    if (!net_ready) return .not_ready;
    if (!arp.ip_set()) return .not_ready;
    const peer_mac = arp.lookup(target_ip) orelse return .no_peer;
    @memset(tx_staging[0..tx_hdr_len], 0);
    const n = ipv4.build_echo_request(tx_staging[tx_hdr_len .. tx_hdr_len + ipv4.ipv4_frame_min + 4], &net_mac, arp.own_ip, peer_mac, target_ip);
    out_len.* = n;
    return net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + n]);
}

// ---------------------------------------------------------------------------
// Host tests — pure logic + the full submit/drain path over mock ops
// ---------------------------------------------------------------------------

test "virtio_net: feature selection negotiates VER1 + MAC only" {
    // Device offers MAC (bit 5) + VER1 (bit 32) + a checksum offload we
    // must NOT accept (bit 0): the guest mask is exactly VER1|MAC.
    const offered = (@as(u64, 1) << 32) | (@as(u64, 1) << 5) | 0x1;
    try std.testing.expectEqual(@as(u64, 1) << 32 | (@as(u64, 1) << 5), select_features(offered));
    // No MAC feature: only VER1.
    try std.testing.expectEqual(@as(u64, 1) << 32, select_features(@as(u64, 1) << 32));
    // A device without VER1 is unusable (modern transport mandatory).
    try std.testing.expectEqual(@as(u64, 0), select_features(@as(u64, 1) << 5));
}

test "virtio_net: MAC read — feature path vs fixed fallback" {
    var mac: [6]u8 = undefined;
    // Feature path: the host-set address lives at device-config offset 0
    // (6 bytes, LE) — the runner fixes 02:00:00:00:00:01.
    const from_feature = read_mac(fake_dev_read32, true, &mac);
    try std.testing.expect(from_feature);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 }, &mac);
    // Fallback path: fixed BSS MAC, source reported honestly.
    const from_fallback = read_mac(fake_dev_read32, false, &mac);
    try std.testing.expect(!from_fallback);
    try std.testing.expectEqualSlices(u8, &fallback_mac, &mac);
    // Formatting is the gate-assertable "aa:bb:cc:dd:ee:ff" shape.
    var text: [17]u8 = undefined;
    format_mac(&mac, &text);
    try std.testing.expectEqualSlices(u8, "02:00:00:00:00:02", &text);
}

test "virtio_net: known-frame build is byte-exact against the fixture" {
    // netsend 32 -> 14-byte header + 32 payload bytes (byte i = i & 0xff):
    // ff*6, 02:00:00:00:00:01, 08 00, then 00..1f. This is the EXACT frame
    // the class-B gate asserts in the host capture file.
    var frame: [frame_max]u8 = undefined;
    const mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const len = build_known_frame(&frame, &mac, 32);
    try std.testing.expectEqual(@as(usize, 46), len);
    try std.testing.expectEqualSlices(u8, &broadcast_mac, frame[0..6]);
    try std.testing.expectEqualSlices(u8, &mac, frame[6..12]);
    try std.testing.expectEqual(@as(u8, 0x08), frame[12]);
    try std.testing.expectEqual(@as(u8, 0x00), frame[13]);
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        try std.testing.expectEqual(@as(u8, @intCast(i)), frame[14 + i]);
    }
}

test "virtio_net: staging bounds — payload truncation is honest" {
    // Over-limit requests truncate at the payload bound, never wrap.
    try std.testing.expectEqual(@as(usize, 1500), truncate_payload(1500));
    try std.testing.expectEqual(@as(usize, 1500), truncate_payload(4096));
    try std.testing.expectEqual(@as(usize, 0), truncate_payload(0));
    // The frame bound is exactly 14 + 1500.
    try std.testing.expectEqual(@as(usize, 1514), frame_max);
    try std.testing.expectEqual(@as(usize, 14), eth_hdr_len);
    var frame: [frame_max]u8 = undefined;
    const len = build_known_frame(&frame, &fallback_mac, 5000);
    try std.testing.expectEqual(@as(usize, 1514), len);
    // build_frame (the generic builder) truncates its payload the same way.
    const payload = @as([2000]u8, @splat(@as(u8, 0xab)));
    const len2 = build_frame(&frame, &broadcast_mac, &fallback_mac, eth_type_ipv4, &payload);
    try std.testing.expectEqual(@as(usize, 1514), len2);
    try std.testing.expectEqual(@as(u8, 0xab), frame[1513]);
}

test "virtio_net: used-ring drain accounting is exact" {
    const E = VirtqUsedElem;
    // One completion: used.idx advanced by 1 past the drain point.
    var ring: [queue_size]E = .{ .{ .id = 0, .len = 46 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 } };
    var r = drain_delta(0, 1, &ring);
    try std.testing.expectEqual(@as(u16, 1), r.completed);
    try std.testing.expectEqual(@as(u64, 46), r.bytes);
    // Two completions sum both element lengths at slots 0 and 1.
    ring = .{ .{ .id = 0, .len = 46 }, .{ .id = 0, .len = 60 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 } };
    r = drain_delta(0, 2, &ring);
    try std.testing.expectEqual(@as(u16, 2), r.completed);
    try std.testing.expectEqual(@as(u64, 106), r.bytes);
    // A ring wrap: last_used=3, used=1 (2 completions at slots 3 and 0).
    ring = .{ .{ .id = 0, .len = 46 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 60 } };
    r = drain_delta(3, 1, &ring);
    try std.testing.expectEqual(@as(u16, 2), r.completed);
    try std.testing.expectEqual(@as(u64, 106), r.bytes);
    // No advance: zero completions.
    r = drain_delta(4, 4, &ring);
    try std.testing.expectEqual(@as(u16, 0), r.completed);
}

test "virtio_net: full TX submit + drain over a mock transport" {
    // Mock ops: in-RAM config registers + a fake device that advances the
    // used ring on the kick. This drives the SAME net_send path the kernel
    // runs (descriptor, avail, clean, notify, poll, drain accounting).
    const ops = mock_ops();

    // Unarmed transport: honest refusal, no hang, nothing submitted.
    net_ready = false;
    var frame: [frame_max]u8 = undefined;
    const len = build_known_frame(&frame, &fallback_mac, 32);
    var dev = Device{};
    try std.testing.expectEqual(SendResult.not_ready, net_send(&ops, &dev, frame[0..len]));
    try std.testing.expectEqual(@as(u16, 0), dev.tx_avail.idx);
    try std.testing.expectEqual(@as(u64, 0), dev.tx_frames);

    // Armed: the submit lands one descriptor, the fake device completes it
    // on the kick, and the drain accounts the completion.
    net_ready = true;
    mock_used_idx = 0;
    mock_tx_used_idx = 0;
    mock_kicks = 0;
    try std.testing.expectEqual(SendResult.ok, net_send(&ops, &dev, frame[0..len]));
    try std.testing.expectEqual(@as(u16, 1), dev.tx_avail.idx);
    try std.testing.expectEqual(@as(u64, 1), dev.tx_frames);
    try std.testing.expectEqual(@as(u64, 46), dev.tx_bytes);
    try std.testing.expectEqual(@as(u16, 1), mock_kicks);
    try std.testing.expectEqual(@as(u16, 1), dev.tx_last_used);

    // A zero-length frame is refused before any submit.
    try std.testing.expectEqual(SendResult.not_ready, net_send(&ops, &dev, frame[0..0]));

    // The staging wrapper (the monitor's netsend path) reports the exact
    // frame length over the mock transport.
    const saved_ops = net_ops;
    net_ops = mock_ops();
    net_mac = fallback_mac;
    net_ready = true;
    var out_len: usize = 0;
    try std.testing.expectEqual(SendResult.ok, net_send_frame(32, &out_len));
    try std.testing.expectEqual(@as(usize, 46), out_len);
    net_ops = saved_ops;
    net_ready = false; // restore for other modules' tests
}

test "virtio_net: MAC filter — own MAC + broadcast accepted, other dropped" {
    const own = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const bcast = [6]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    const other = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x03 };
    // A bare 6-byte dst at offset 0.
    try std.testing.expect(mac_accept(0, &own, &own));
    try std.testing.expect(mac_accept(0, &bcast, &own));
    try std.testing.expect(!mac_accept(0, &other, &own));
    // With a 12-byte virtio_net_hdr prefix (the RX-header contract): the
    // dst sits at offset 12.
    var buf: [rx_hdr_len + 14]u8 = @splat(0);
    @memcpy(buf[rx_hdr_len .. rx_hdr_len + 6], &own);
    try std.testing.expect(mac_accept(rx_hdr_len, &buf, &own));
    @memcpy(buf[rx_hdr_len .. rx_hdr_len + 6], &other);
    try std.testing.expect(!mac_accept(rx_hdr_len, &buf, &own));
    // A buffer too short for the dst read refuses.
    try std.testing.expect(!mac_accept(rx_hdr_len, buf[0..rx_hdr_len], &own));
}

test "virtio_net: bounded frame FIFO — push, pop, occupancy, drop-oldest" {
    // Reset the module FIFO state (BSS is not trusted zeroed).
    rx_fifo_head = 0;
    rx_fifo_count = 0;
    rx_overflow = 0;
    const a = @as([10]u8, @splat(@as(u8, 0xaa)));
    const b = @as([20]u8, @splat(@as(u8, 0xbb)));
    const c = @as([30]u8, @splat(@as(u8, 0xcc)));
    const d = @as([40]u8, @splat(@as(u8, 0xdd)));
    const e = @as([50]u8, @splat(@as(u8, 0xee))); // the overflow frame (drops `a`)
    try std.testing.expect(fifo_push(&a));
    try std.testing.expect(fifo_push(&b));
    try std.testing.expect(fifo_push(&c));
    try std.testing.expect(fifo_push(&d));
    try std.testing.expectEqual(@as(usize, 4), fifo_occupancy());
    // The 5th push overflows: drop-oldest (`a`), newest wins.
    try std.testing.expect(fifo_push(&e));
    try std.testing.expectEqual(@as(usize, 4), fifo_occupancy());
    try std.testing.expectEqual(@as(u64, 1), rx_overflow);
    // Drain order: b, c, d, e (a was dropped).
    var out: [rx_buf_len]u8 = undefined;
    const lb = fifo_pop_for_test(&out);
    try std.testing.expectEqual(@as(usize, 20), lb);
    try std.testing.expectEqualSlices(u8, &b, out[0..lb]);
    const lc = fifo_pop_for_test(&out);
    try std.testing.expectEqual(@as(usize, 30), lc);
    try std.testing.expectEqualSlices(u8, &c, out[0..lc]);
    const ld = fifo_pop_for_test(&out);
    try std.testing.expectEqual(@as(usize, 40), ld);
    try std.testing.expectEqualSlices(u8, &d, out[0..ld]);
    const le = fifo_pop_for_test(&out);
    try std.testing.expectEqual(@as(usize, 50), le);
    try std.testing.expectEqualSlices(u8, &e, out[0..le]);
    try std.testing.expectEqual(@as(usize, 0), fifo_occupancy());
    // An over-size frame is refused (never stored).
    var big: [rx_buf_len + 1]u8 = undefined;
    try std.testing.expect(!fifo_push(&big));
    try std.testing.expectEqual(@as(usize, 0), fifo_occupancy());
}

test "virtio_net: RX supply + used-ring drain + filter + FIFO over a mock" {
    const saved_ops = net_ops;
    net_ops = mock_ops();
    net_ready = true;
    defer {
        net_ops = saved_ops;
        net_ready = false;
    }
    net_dev = .{}; // fresh rings (the module global the RX path uses)
    net_mac = fallback_mac; // own MAC 02:00:00:00:00:02
    rx_fifo_head = 0;
    rx_fifo_count = 0;
    rx_frames = 0;
    rx_bytes = 0;
    rx_filtered = 0;
    rx_overflow = 0;
    rx_armed = false;
    mock_used_idx = 0;
    mock_tx_used_idx = 0;
    mock_used_len = 0;
    mock_kicks = 0;

    // A delivered frame: the OBSERVED 12-byte virtio_net_hdr (all zero
    // except num_buffers=1 at bytes 10-11 — the claim-time live-gate
    // observation) + a BROADCAST Ethernet frame (dst ff*6, src
    // 02:00:00:00:00:03, ethertype 0x0800, payload bytes 00..1f) — the
    // RX-header + filter contract the class-B gate pins from observation.
    var delivered: [rx_buf_len]u8 = @splat(0);
    delivered[10] = 0x01; // virtio_net_hdr num_buffers = 1 (observed)
    const dst = [6]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    const src = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x03 };
    @memcpy(delivered[rx_hdr_len .. rx_hdr_len + 6], &dst);
    @memcpy(delivered[rx_hdr_len + 6 .. rx_hdr_len + 12], &src);
    delivered[rx_hdr_len + 12] = 0x08;
    delivered[rx_hdr_len + 13] = 0x00;
    var i: usize = 0;
    while (i < 32) : (i += 1) delivered[rx_hdr_len + 14 + i] = @truncate(i);
    mock_rx_frame = delivered[0 .. rx_hdr_len + 46]; // header + 46-byte frame

    // Arm: the kick delivers the pending frame into rx_buf and advances
    // the used ring (device-written len = 58).
    try std.testing.expect(net_rx_arm());
    try std.testing.expect(rx_armed);
    try std.testing.expectEqual(@as(u16, 1), mock_kicks);
    try std.testing.expectEqual(@as(u16, 1), net_dev.rx_avail.idx);

    // Drain: the completion is accounted, the frame passes the broadcast
    // filter, and lands in the FIFO (raw device-written bytes — header
    // included). The drain's re-arm re-delivers the same mock frame, so
    // the FIFO holds one frame and the buffer is re-supplied.
    net_rx_drain();
    try std.testing.expectEqual(@as(u64, 1), rx_frames);
    try std.testing.expectEqual(@as(u64, 58), rx_bytes);
    try std.testing.expectEqual(@as(u64, 0), rx_filtered);
    try std.testing.expectEqual(@as(u64, 0), rx_overflow);
    try std.testing.expectEqual(@as(u32, 58), rx_last_len);
    try std.testing.expectEqual(@as(usize, 1), fifo_occupancy());
    try std.testing.expectEqual(@as(u16, 2), net_dev.rx_avail.idx); // re-armed

    // net recv consumes the FIFO frame: the exact device-written bytes.
    const frame = fifo_peek().?;
    try std.testing.expectEqual(@as(usize, 58), frame.len);
    try std.testing.expectEqualSlices(u8, mock_rx_frame, frame);
    fifo_pop_advance();
    try std.testing.expectEqual(@as(usize, 0), fifo_occupancy());

    // The rx-obs record captured the first 16 device-written bytes — the
    // OBSERVED virtio_net_hdr (12 bytes: all zero except num_buffers=1 at
    // bytes 10-11) + the first 4 broadcast-dst bytes: the claim-time
    // header pin.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x00 }, rx_first16[0..12]);
    try std.testing.expectEqualSlices(u8, dst[0..4], rx_first16[12..16]);
}

test "virtio_net: RX MAC filter drops a foreign frame (counter, not FIFO)" {
    const saved_ops = net_ops;
    net_ops = mock_ops();
    net_ready = true;
    defer {
        net_ops = saved_ops;
        net_ready = false;
    }
    net_dev = .{};
    net_mac = fallback_mac;
    rx_fifo_head = 0;
    rx_fifo_count = 0;
    rx_frames = 0;
    rx_bytes = 0;
    rx_filtered = 0;
    rx_overflow = 0;
    rx_armed = false;
    mock_used_idx = 0;
    mock_tx_used_idx = 0;
    mock_used_len = 0;
    mock_kicks = 0;

    // A frame addressed to ANOTHER host (dst 02:00:00:00:00:04): the
    // filter must drop it — the counter moves, the FIFO stays empty, and
    // the rx-obs record still captures the delivered bytes (so a drop is
    // distinguishable from a failed delivery).
    var delivered: [rx_buf_len]u8 = @splat(0);
    delivered[10] = 0x01; // the OBSERVED virtio_net_hdr num_buffers=1
    const dst = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x04 };
    const src = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x05 };
    @memcpy(delivered[rx_hdr_len .. rx_hdr_len + 6], &dst);
    @memcpy(delivered[rx_hdr_len + 6 .. rx_hdr_len + 12], &src);
    delivered[rx_hdr_len + 12] = 0x08;
    delivered[rx_hdr_len + 13] = 0x00;
    var i: usize = 0;
    while (i < 32) : (i += 1) delivered[rx_hdr_len + 14 + i] = @truncate(i);
    mock_rx_frame = delivered[0 .. rx_hdr_len + 46];

    try std.testing.expect(net_rx_arm());
    net_rx_drain();
    try std.testing.expectEqual(@as(u64, 0), rx_frames);
    try std.testing.expectEqual(@as(u64, 1), rx_filtered);
    try std.testing.expectEqual(@as(usize, 0), fifo_occupancy());
    try std.testing.expectEqual(@as(u32, 58), rx_last_len);
    try std.testing.expectEqualSlices(u8, dst[0..4], rx_first16[12..16]);
}

test "virtio_net: RX ARP request is answered — byte-exact reply on TX over a mock" {
    const saved_ops = net_ops;
    net_ops = mock_ops();
    net_ready = true;
    defer {
        net_ops = saved_ops;
        net_ready = false;
    }
    net_dev = .{};
    net_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 }; // the host-set guest MAC
    arp.own_ip = .{ 10, 0, 0, 1 };
    arp.table = @as([arp.table_slots]arp.ArpEntry, @splat(@as(arp.ArpEntry, .{})));
    arp.table_cursor = 0;
    arp.replies_sent = 0;
    arp.replies_learned = 0;
    arp.dropped = 0;
    arp.reply_tx_fail = 0;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    rx_fifo_head = 0;
    rx_fifo_count = 0;
    rx_frames = 0;
    rx_bytes = 0;
    rx_filtered = 0;
    rx_overflow = 0;
    rx_armed = false;
    mock_used_idx = 0;
    mock_tx_used_idx = 0;
    mock_used_len = 0;
    mock_kicks = 0;

    // The delivered frame: the OBSERVED 12-byte virtio_net_hdr
    // (num_buffers=1 at bytes 10-11) + an ARP REQUEST from the host
    // (02:00:00:00:00:02 / 10.0.0.2) asking who has 10.0.0.1 — broadcast
    // dst, so the MAC filter admits it.
    var request: [arp.arp_frame_len]u8 = undefined;
    const host_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 };
    const host_ip = [4]u8{ 10, 0, 0, 2 };
    _ = arp.build_request(&request, &host_mac, host_ip, arp.own_ip);
    var delivered: [rx_buf_len]u8 = @splat(0);
    delivered[10] = 0x01; // virtio_net_hdr num_buffers = 1 (observed)
    @memcpy(delivered[rx_hdr_len .. rx_hdr_len + request.len], &request);
    mock_rx_frame = delivered[0 .. rx_hdr_len + request.len];
    // Dirty the TX staging header so the reply path's ZEROING is proven
    // (a stale virtio_net_hdr would corrupt the delivered reply).
    @memset(tx_staging[0..tx_hdr_len], 0xab);

    try std.testing.expect(net_rx_arm());
    net_rx_drain();

    // The request was accepted (FIFO holds the raw observed frame) AND
    // answered: the reply went out on the TX queue byte-exact, with a
    // ZEROED virtio_net_hdr prefix (the claim-1373 TX contract).
    try std.testing.expectEqualSlices(u8, &@as([tx_hdr_len]u8, @splat(@as(u8, 0))), tx_staging[0..tx_hdr_len]);
    try std.testing.expectEqual(@as(u64, 1), rx_frames);
    try std.testing.expectEqual(@as(usize, 1), fifo_occupancy());
    try std.testing.expectEqual(@as(u64, 1), arp.replies_sent);
    try std.testing.expectEqual(@as(u64, 0), arp.reply_tx_fail);
    try std.testing.expectEqual(@as(u64, 1), net_dev.tx_frames);
    // tx_staging still holds the submitted buffer (header + frame): the
    // reply is byte-exact against arp.build_reply's own fixture.
    var expected: [arp.arp_frame_len]u8 = undefined;
    _ = arp.build_reply(&expected, &net_mac, arp.own_ip, host_mac, host_ip);
    try std.testing.expectEqualSlices(u8, &expected, tx_staging[tx_hdr_len .. tx_hdr_len + arp.arp_frame_len]);
    try std.testing.expectEqualSlices(u8, &host_mac, tx_staging[tx_hdr_len .. tx_hdr_len + 6]); // dst = requester
}

test "virtio_net: RX ARP reply is learned into the bounded table" {
    const saved_ops = net_ops;
    net_ops = mock_ops();
    net_ready = true;
    defer {
        net_ops = saved_ops;
        net_ready = false;
    }
    net_dev = .{};
    net_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    arp.own_ip = .{ 10, 0, 0, 1 };
    arp.table = @as([arp.table_slots]arp.ArpEntry, @splat(@as(arp.ArpEntry, .{})));
    arp.table_cursor = 0;
    arp.replies_sent = 0;
    arp.replies_learned = 0;
    arp.dropped = 0;
    arp.reply_tx_fail = 0;
    arp.pending_reply = null;
    defer {
        arp.own_ip = .{ 0, 0, 0, 0 };
        arp.pending_reply = null;
    }
    rx_fifo_head = 0;
    rx_fifo_count = 0;
    rx_frames = 0;
    rx_bytes = 0;
    rx_filtered = 0;
    rx_overflow = 0;
    rx_armed = false;
    mock_used_idx = 0;
    mock_tx_used_idx = 0;
    mock_used_len = 0;
    mock_kicks = 0;

    // M97e-F3 (#2102): an UNSOLICITED reply arrives first — dropped, not
    // learned (before this fix it would have populated the table).
    const host_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 };
    const host_ip = [4]u8{ 10, 0, 0, 2 };
    var reply: [arp.arp_frame_len]u8 = undefined;
    _ = arp.build_reply(&reply, &host_mac, host_ip, net_mac, arp.own_ip);
    var delivered: [rx_buf_len]u8 = @splat(0);
    delivered[10] = 0x01;
    @memcpy(delivered[rx_hdr_len .. rx_hdr_len + reply.len], &reply);
    mock_rx_frame = delivered[0 .. rx_hdr_len + reply.len];

    try std.testing.expect(net_rx_arm());
    net_rx_drain();

    try std.testing.expectEqual(@as(u64, 1), rx_frames);
    try std.testing.expectEqual(@as(u64, 0), arp.replies_learned);
    try std.testing.expectEqual(@as(u64, 1), arp.dropped); // the unsolicited reply
    try std.testing.expect(arp.lookup(host_ip) == null);

    // Now WE request the peer (the real resolve path — pending is the
    // wire target) and its matching reply IS learned — no reply is sent.
    var out_len: usize = 0;
    try std.testing.expectEqual(SendResult.ok, net_arp_request(host_ip, &out_len));
    try std.testing.expectEqualSlices(u8, &host_ip, &arp.pending_reply.?);

    try std.testing.expect(net_rx_arm());
    net_rx_drain();

    try std.testing.expectEqual(@as(u64, 2), rx_frames);
    try std.testing.expectEqual(@as(u64, 0), arp.replies_sent); // no reply to a reply
    try std.testing.expectEqual(@as(u64, 1), arp.replies_learned);
    try std.testing.expect(arp.pending_reply == null); // the request was consumed
    try std.testing.expectEqual(@as(u64, 1), net_dev.tx_frames); // our request only
    try std.testing.expectEqualSlices(u8, &host_mac, &arp.lookup(host_ip).?);
}

test "virtio_net: net_arp_request resolves the NEXT HOP for an off-subnet target" {
    const saved_ops = net_ops;
    net_ops = mock_ops();
    net_ready = true;
    defer {
        net_ops = saved_ops;
        net_ready = false;
    }
    net_dev = .{};
    net_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    arp.own_ip = .{ 192, 168, 64, 5 }; // the observed VZ NAT subnet
    arp.own_mask = .{ 255, 255, 255, 0 };
    arp.gateway = .{ 0, 0, 0, 0 };
    defer {
        arp.own_ip = .{ 0, 0, 0, 0 };
        arp.own_mask = .{ 255, 255, 255, 0 };
        arp.gateway = .{ 0, 0, 0, 0 };
    }
    mock_used_idx = 0;
    mock_tx_used_idx = 0;
    mock_used_len = 0;
    mock_kicks = 0;

    // An off-subnet resolve (a public resolver): the wire request asks
    // who-has-the-GATEWAY (the derived .1), not the remote itself —
    // upstream does no proxy-ARP, so asking for the literal peer would
    // go unanswered forever.
    var out_len: usize = 0;
    try std.testing.expectEqual(SendResult.ok, net_arp_request(.{ 1, 1, 1, 1 }, &out_len));
    try std.testing.expectEqual(@as(usize, arp.arp_frame_len), out_len);
    var expected: [arp.arp_frame_len]u8 = undefined;
    _ = arp.build_request(&expected, &net_mac, arp.own_ip, .{ 192, 168, 64, 1 });
    try std.testing.expectEqualSlices(u8, &expected, tx_staging[tx_hdr_len .. tx_hdr_len + arp.arp_frame_len]);
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 64, 1 }, tx_staging[tx_hdr_len + 38 .. tx_hdr_len + 42]); // tpa = the gateway

    // An on-link resolve is byte-for-byte the old exact-peer request.
    try std.testing.expectEqual(SendResult.ok, net_arp_request(.{ 192, 168, 64, 7 }, &out_len));
    _ = arp.build_request(&expected, &net_mac, arp.own_ip, .{ 192, 168, 64, 7 });
    try std.testing.expectEqualSlices(u8, &expected, tx_staging[tx_hdr_len .. tx_hdr_len + arp.arp_frame_len]);

    // No gateway (own address IS the derived first host — the test-net
    // fixture): the request asks for the literal peer, exactly as before
    // this card.
    arp.own_ip = .{ 10, 0, 0, 1 };
    try std.testing.expectEqual(SendResult.ok, net_arp_request(.{ 8, 8, 8, 8 }, &out_len));
    _ = arp.build_request(&expected, &net_mac, arp.own_ip, .{ 8, 8, 8, 8 });
    try std.testing.expectEqualSlices(u8, &expected, tx_staging[tx_hdr_len .. tx_hdr_len + arp.arp_frame_len]);
}

/// Test helper: pop the oldest FIFO frame into `out` (the real path peeks
/// + advances to avoid a stack copy; the tests want a copy to compare).
fn fifo_pop_for_test(out: []u8) usize {
    const frame = fifo_peek() orelse return 0;
    @memcpy(out[0..frame.len], frame);
    fifo_pop_advance();
    return frame.len;
}

// --- test fixtures ----------------------------------------------------------

/// Fake device-config reads: the runner's fixed MAC 02:00:00:00:00:01 sits
/// at device-config offset 0 as 6 LE bytes (lo = bytes 0..3, hi = bytes
/// 4..5 + zero padding).
fn fake_dev_read32(off: u32) u32 {
    if (off == 0) return 0x00000002; // bytes 02 00 00 00
    return 0x00000100; // bytes 00 00 00 01 (the runner's ...:00:01)
}

// Module-global mock transport state (the fat.zig mock-ops shape: plain fn
// pointers close over these; one mock per test binary).
var mock_cfg: [0x40]u8 = @splat(0);
var mock_kicks: u16 = 0;
/// RX used-ring index (the queue-0 completions — the RX side of the mock
/// is per-queue, like the real device; the ARP reply path transmits on
/// queue 1 while the RX ring holds its own index).
var mock_used_idx: u16 = 0;
/// TX used-ring index (queue 1 — the N1 TX completions).
var mock_tx_used_idx: u16 = 0;
/// Device-written length of the last RX completion (RX: the frame length —
/// the TX used-element len was ~0 on VZ; the RX one is the real one).
var mock_used_len: u32 = 0;
/// The pending RX frame the fake device "delivers" into `rx_buf` on the
/// queue-0 kick (host→guest injection over the mock transport).
var mock_rx_frame: []const u8 = &.{};

fn mock_dev_read32(off: u32) u32 {
    _ = off;
    return 0;
}
fn mock_cfg_read8(off: u32) u8 {
    return mock_cfg[off];
}
fn mock_cfg_read16(off: u32) u16 {
    return @as(u16, mock_cfg[off]) | (@as(u16, mock_cfg[off + 1]) << 8);
}
fn mock_cfg_read32(off: u32) u32 {
    return @as(u32, mock_cfg[off]) | (@as(u32, mock_cfg[off + 1]) << 8) | (@as(u32, mock_cfg[off + 2]) << 16) | (@as(u32, mock_cfg[off + 3]) << 24);
}
fn mock_cfg_write8(off: u32, value: u8) void {
    mock_cfg[off] = value;
}
fn mock_cfg_write16(off: u32, value: u16) void {
    mock_cfg[off] = @truncate(value);
    mock_cfg[off + 1] = @truncate(value >> 8);
}
fn mock_cfg_write32(off: u32, value: u32) void {
    mock_cfg[off] = @truncate(value);
    mock_cfg[off + 1] = @truncate(value >> 8);
    mock_cfg[off + 2] = @truncate(value >> 16);
    mock_cfg[off + 3] = @truncate(value >> 24);
}
fn mock_to_phys(va: usize) u64 {
    return va; // host test: identity
}
fn mock_clean(_: usize, _: usize) void {}
/// The fake device's "completion": before every used-ring poll the driver
/// invalidates the used ring; the mock replays the fake device state (used
/// index advanced on the kick, device-written length) into the driver's
/// real BSS ring.
fn mock_invalidate(ptr: usize, len: usize) void {
    _ = len;
    // The driver also invalidates the RX buffer after a device write; the
    // mock has nothing to replay there (mock_notify already copied the
    // frame in) — and must NOT treat the buffer's bytes as a used ring.
    if (ptr == @intFromPtr(&rx_buf)) return;
    const used = @as(*VirtqUsed, @ptrFromInt(ptr));
    // Per-queue used rings, like the real device. The RX ring (the module
    // global — the RX path only ever drains net_dev.rx_used) replays the
    // RX index + written length; every other used ring (net_dev.tx_used,
    // or a LOCAL Device in the pure TX test) replays the TX index — the
    // mock's TX side only ever advances its own index (the ARP reply path
    // transmits while the RX ring holds a completion, so the two rings
    // must not share an index).
    if (ptr == @intFromPtr(&net_dev.rx_used)) {
        if (used.idx != mock_used_idx) {
            used.idx = mock_used_idx;
            if (mock_used_idx != 0) {
                used.ring[(used.idx -% 1) % queue_size].len = mock_used_len;
            }
        }
        return;
    }
    if (used.idx != mock_tx_used_idx) used.idx = mock_tx_used_idx;
}
fn mock_notify(q: u16) void {
    mock_kicks +%= 1;
    if (q == 0) {
        // RX (card N2): the fake device writes the pending frame into the
        // real `rx_buf` and completes the buffer (used.idx advances with
        // the WRITTEN length).
        @memcpy(rx_buf[0..mock_rx_frame.len], mock_rx_frame);
        mock_used_len = @intCast(mock_rx_frame.len);
        mock_used_idx +%= 1;
    } else {
        // TX: the device writes nothing (the N1 observation); the TX used
        // index advances on the kick (the device consumed the request).
        mock_tx_used_idx +%= 1;
    }
}

fn mock_ops() Ops {
    return .{
        .dev_read32 = mock_dev_read32,
        .cfg_read8 = mock_cfg_read8,
        .cfg_read16 = mock_cfg_read16,
        .cfg_read32 = mock_cfg_read32,
        .cfg_write8 = mock_cfg_write8,
        .cfg_write16 = mock_cfg_write16,
        .cfg_write32 = mock_cfg_write32,
        .notify = mock_notify,
        .to_phys = mock_to_phys,
        .clean = mock_clean,
        .invalidate = mock_invalidate,
    };
}
