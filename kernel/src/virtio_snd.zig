//! VirelaiOS virtio-pci sound transport (milestone fifteen — claim 6140
//! card A1 transport, claim 5877 card A2 PCM playback).
//!
//! Drives the device the runner attaches as `VZVirtioSoundDeviceConfiguration`
//! — to the guest a modern virtio-pci sound device (VID 0x1af4, DID 0x1059 =
//! 0x1040 + virtio device type 25, the same 0x1040+type scheme as net 0x1041 /
//! entropy 0x1044 / gpu 0x1050; the transitional 0x1019 = 0x1000 + 25 is also
//! accepted). The transport mirrors `virtio_entropy.zig`'s proven patterns:
//! discovery + capability walk + feature negotiation + split-ring queue
//! setup run PRE-EXIT; post-MMU the transport is RE-ARMED (claim 6420's
//! lesson — VZ resets SOME virtio devices at ExitBootServices; blk/entropy
//! reset to st=00, net/gpu do NOT — the sound answer is observed, not
//! assumed: st=0f pre-rearm on the live runs, so the sound device is NOT
//! reset, like net/gpu).
//!
//! Card A1 is the TRANSPORT: locate the device, resolve BARs + the virtio
//! capabilities (common/notify/device-config), negotiate features, arm the
//! CONTROL queue (queue 0), reach DRIVER_OK, and capture the device-config
//! counts (jacks / PCM streams / channel maps — three le32 at offsets
//! 0/4/8, virtio-snd §5.14.4) PRE-EXIT (config-space reads must stay
//! pre-exit, claim 0013; the devcfg MMIO window is read the same way net
//! reads its MAC).
//!
//! CLAIM-TIME OBSERVATION (2026-08-18, live on VZ): the device config
//! reads ALL ZEROS — jacks/streams/chmaps 0/0/0 from both the pre-exit
//! firmware map and the post-exit identity map, and a 32-byte raw dump of
//! the devcfg window is uniformly zero, even with two output streams
//! attached host-side. VZ's virtio-snd emulation does not populate the
//! le32 config counts. The transport is fully healthy regardless (DID
//! 0x1059 — the 0x1040+25 prediction HELD — class 0x040100, st=0x0f
//! DRIVER_OK, control queue armed). Stream topology is therefore
//! enumerated via the spec-sanctioned CONTROL-queue JACK_INFO/PCM_INFO
//! queries (card A2), not the config counts.
//!
//! Card A2 (claim 5877) is the PCM PLAYBACK path: control-queue request/
//! response exchanges (PCM_INFO → PCM_SET_PARAMS → PCM_PREPARE →
//! PCM_START → submit → PCM_STOP → PCM_RELEASE, virtio-snd §5.14.6), a
//! bounded zero-heap BSS sample buffer, and the `beep <freq> <ms>` monitor
//! command that synthesizes a sine into the negotiated format and submits
//! it to the stream's TX queue (queue 2 = stream 0 playback) with used-ring
//! drain accounting.
//!
//! OBSERVED (2026-08-18, live on VZ): VZ's virtio-snd speaks the
//! virtio-1.3 control renumbering — a 1.2-style PCM_INFO (code 3) was
//! answered with BAD_MSG 0x8001, and OK is 0x8000 (not 0). The driver
//! therefore uses the 1.3 codes (PCM_INFO 0x0100, ...). Two transport
//! lessons were also pinned live: the used ring's cache line MUST be
//! invalidated on every poll (the console/blk/net pattern — without it the
//! device's completion is invisible and the exchange times out), and the
//! 16-bit kick is the QUEUE-INDEX write (Virtio 1.3 §4.1.5.2.1), the net
//! driver's proven shape.
//!
//! No libc, no POSIX, no allocation, no interrupts.

const std = @import("std");
const build_options = @import("build_options");
const klog = @import("klog.zig");
const mmio = @import("mmio.zig");
const mmu = @import("mmu.zig");
const pci = @import("pci.zig");
const evidence = @import("evidence.zig");
const timer = @import("timer.zig");
const spinlock = @import("spinlock.zig");
const alloc = @import("alloc.zig");
pub const playback = @import("pcm_playback.zig");
const pcm = playback.pcm;

const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};
const VirtqAvail = extern struct {
    flags: u16,
    idx: u16,
    ring: [pcm.tx_descriptors]u16,
    padding: [60]u8 = @splat(0),
};
const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};
const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
    ring: [pcm.tx_descriptors]VirtqUsedElem,
    padding: [60]u8 = @splat(0),
};

const VIRTQ_DESC_F_NEXT: u16 = 1;
const VIRTQ_DESC_F_WRITE: u16 = 2;

/// Split-ring size: 4 (power of two, Virtio 1.3 §4.1.4.3).
pub const queue_size: u16 = 4;
pub const tx_queue_size: u16 = pcm.tx_descriptors;

/// virtio-snd device config layout (virtio-snd §5.14.4): three le32
/// counts at offsets 0/4/8. Offsets + width are the spec shape — pinned
/// by the host test (and verified live: VZ reports streams=1 for the
/// `--sound` one-output-stream attach).
pub const cfg_jacks_off: u32 = 0;
pub const cfg_streams_off: u32 = 4;
pub const cfg_chmaps_off: u32 = 8;
pub const cfg_bytes: usize = 12; // the counts we capture (config is 12 B total)

// ---------------------------------------------------------------------------
// virtio-snd control protocol (virtio 1.3 codes; §5.14.6)
// ---------------------------------------------------------------------------

/// Control request codes. OBSERVED (2026-08-18, live on VZ): a virtio-1.2
/// PCM_INFO (code 3) was answered with BAD_MSG 0x8001 — VZ's virtio-snd
/// speaks the virtio-1.3 renumbering (PCM_INFO 0x0100, status OK 0x8000).
/// The request codes below are the 1.3 values, pinned by that observation.
pub const R_JACK_INFO: u32 = 1;
pub const R_JACK_REMAP: u32 = 2;
pub const R_PCM_INFO: u32 = 0x0100;
pub const R_PCM_SET_PARAMS: u32 = 0x0101;
pub const R_PCM_PREPARE: u32 = 0x0102;
pub const R_PCM_RELEASE: u32 = 0x0103;
pub const R_PCM_START: u32 = 0x0104;
pub const R_PCM_STOP: u32 = 0x0105;
pub const R_CHMAP_INFO: u32 = 0x0200;

/// Reply status codes (the 1.3 values — the observed 0x8001 BAD_MSG
/// reply pinned the set).
pub const S_OK: u32 = 0x8000;
pub const S_BAD_MSG: u32 = 0x8001;
pub const S_NOT_SUPP: u32 = 0x8002;
pub const S_IO_ERR: u32 = 0x8003;

/// Sample formats (1 << FMT_* in the pcm_info formats bitmap — the Linux
/// uapi enum: S16=5, S32=17, FLOAT=19; a first attempt used 16/18 and
/// mis-read the device's bitmap — the live formats=0x000a0020 (bits
/// 5/17/19) pinned the correct values).
pub const FMT_S16: u8 = 5;
pub const FMT_S32: u8 = 17;
pub const FMT_FLOAT: u8 = 19;
/// Frame rates (1 << RATE_* in the pcm_info rates bitmap).
pub const RATE_48000: u8 = 7;
pub const RATE_44100: u8 = 6;
pub const RATE_32000: u8 = 5;
pub const RATE_22050: u8 = 4;
pub const RATE_16000: u8 = 3;
pub const RATE_8000: u8 = 1;
/// Dataflow directions.
pub const D_OUTPUT: u8 = 0;
pub const D_INPUT: u8 = 1;

const Hdr = extern struct { code: u32 };
const QueryInfo = extern struct {
    hdr: Hdr,
    start_id: u32,
    count: u32,
    size: u32,
};
const PcmHdr = extern struct {
    hdr: Hdr,
    stream_id: u32,
};
const PcmInfo = extern struct {
    hda_fn_nid: u32,
    features: u32,
    formats: u64,
    rates: u64,
    direction: u8,
    channels_min: u8,
    channels_max: u8,
    padding: [5]u8,
};
const PcmSetParams = extern struct {
    hdr: PcmHdr,
    buffer_bytes: u32,
    period_bytes: u32,
    features: u32,
    channels: u8,
    format: u8,
    rate: u8,
    padding: u8,
};
const PcmXfer = extern struct { stream_id: u32 };
const PcmStatus = extern struct {
    status: u32,
    latency_bytes: u32,
};

// ---------------------------------------------------------------------------
// Queues: 0 = control (A1), 1 = events (unused), 2 = stream-0 TX / playback
// (A2). Each queue has its own descriptor table + avail + used rings (BSS).
// ---------------------------------------------------------------------------

pub var ctrl_desc: [pcm.tx_descriptors]VirtqDesc align(64) = undefined;
pub var ctrl_avail: VirtqAvail align(64) = undefined;
pub var ctrl_used: VirtqUsed align(64) = undefined;
var ctrl_last_used: u16 = 0;
pub var ctrl_armed: bool = false;

pub var tx_desc: [pcm.tx_descriptors]VirtqDesc align(64) = undefined;
pub var tx_avail: VirtqAvail align(64) = undefined;
pub var tx_used: VirtqUsed align(64) = undefined;
var tx_last_used: u16 = 0;
pub var tx_armed: bool = false;
pub var tx_queue_notify_off: u16 = 0; // queue 2 notify offset (observed)

// Queue 3 = stream RX / capture (M118b, virtio-snd §4: 0=control, 1=event,
// 2=tx, 3=rx). Armed unconditionally like queue 2 — the capture path
// refuses by name when it isn't there.
pub var rx_desc: [pcm.tx_descriptors]VirtqDesc align(64) = undefined;
pub var rx_avail: VirtqAvail align(64) = undefined;
pub var rx_used: VirtqUsed align(64) = undefined;
var rx_last_used: u16 = 0;
pub var rx_armed: bool = false;
pub var rx_queue_notify_off: u16 = 0; // queue 3 notify offset
pub const rx_queue_size: u16 = queue_size;

/// Transport state. Discovery/setup run pre-exit; the re-arm runs post-MMU.
pub var snd_dev: u32 = 0; // sound device PCI device number
pub var snd_ready: bool = false; // transport initialized (control queue armed)
pub var snd_common: u64 = 0; // common-config struct address (BAR + cap offset)
pub var snd_notify: u64 = 0; // notify region base (BAR + cap offset)
pub var snd_notify_mult: u32 = 0; // notify_off_multiplier
pub var snd_queue_notify_off: u16 = 0; // queue 0 notify offset
pub var snd_bar0: u64 = 0; // sound BAR0 base (the identity-map window)
pub var snd_devcfg: u64 = 0; // device-config region (BAR + cap offset)
pub var snd_did: u32 = 0; // OBSERVED device ID (0x1059 expected)
pub var snd_class: u32 = 0; // observed PCI class
pub var snd_feats: u32 = 0; // device features, low word
pub var snd_fail: []const u8 = ""; // honest failure reason ("" = ok)

/// The device-config counts (captured PRE-EXIT, the net-MAC pattern).
/// le32 fields per §5.14.4 — the u8-at-0/1/2 first attempt read all
/// zeros (streams=1 lives at offset 4), fixed by the spec shape.
pub var snd_jacks: u32 = 0;
pub var snd_streams: u32 = 0;
pub var snd_chmaps: u32 = 0;
var snd_cfg_seen: bool = false;

/// OBSERVED 2026-10-20 (macOS 27.2, mic-denied VZ): when the capture START
/// exchange expires its poll budget, the host's audio backend wedges
/// BELOW the ctl channel — every later common-config register READ parks
/// the guest CPU inside the load (a stalled VZ trap no budget outlives;
/// writes still post). Latched at the START timeout so every register
/// path refuses honestly instead of hanging the boot CPU (#2847).
pub var snd_regs_suspect: bool = false;
var snd_status_latched: u8 = 0xff; // last status read that completed

// ---------------------------------------------------------------------------
// A2 playback state: the negotiated stream + the bounded BSS sample buffer.
// ---------------------------------------------------------------------------

/// The bounded zero-heap sample buffer (fixed BSS, the M14 rule): the
/// pcm_xfer header + ONE period of audio. A beep is synthesized and
/// submitted period-by-period, so the buffer stays tiny regardless of
/// duration/format (the drain accounting then counts every period).
pub const beep_period_bytes: u32 = 4096; // audio bytes per TX submission
pub const beep_buf_size: usize = @sizeOf(PcmXfer) + beep_period_bytes;
pub var beep_buf: [beep_buf_size]u8 align(64) = undefined;

/// Negotiated playback parameters (0xff = never negotiated).
pub var beep_format: u8 = 0xff;
pub var beep_rate: u8 = 0xff;
pub var beep_channels: u8 = 0;
pub var beep_buffer_bytes: u32 = 65536; // SET_PARAMS buffer (device latency hint)

/// Accounting + last result (the gate's evidence).
pub var beep_submitted: u32 = 0; // bytes submitted to the TX queue
pub var beep_drained: u32 = 0; // bytes drained (used ring completion)
pub var beep_frames: u32 = 0; // frames synthesized
pub var beep_last_status: u32 = 0xffffffff; // pcm_status from the TX used entry
pub var beep_last_latency: u32 = 0; // pcm_status latency_bytes
pub var beep_fail: []const u8 = ""; // honest failure reason
/// Per-step control statuses (the gate's full evidence trail).
pub var beep_params_status: u32 = 0xffffffff;
pub var beep_prepare_status: u32 = 0xffffffff;
pub var beep_start_status: u32 = 0xffffffff;
pub var beep_stop_status: u32 = 0xffffffff;
pub var beep_release_status: u32 = 0xffffffff;

/// Bounded kernel-side stream-state control (claim 9297): `stream_volume`
/// is the playback gain in percent (0..100) and `stream_muted` silences
/// the stream. Both are applied to every sample that flows through the TX
/// staging buffer at submit time — the single choke point shared by
/// `beep`, the boot chime, and `sys_audio_play`. Plain BSS, zero heap;
/// the setters reject out-of-range values honestly (no silent clamping).
pub var stream_volume: u8 = 100; // 0..100 percent; 100 = full gain
pub var stream_muted: bool = false;

/// Set the stream volume (0..100, bounded). Returns the volume on success
/// or 0xffffffff for an out-of-range value (honest refusal — the caller
/// learns the bound, nothing is clamped silently).
pub fn snd_set_volume(vol: u8) u32 {
    if (vol > 100) return 0xffffffff;
    const saved = audio_lock.lock();
    defer audio_lock.unlock(saved);
    stream_volume = vol;
    return vol;
}

/// Set the stream mute state (true = silent). Returns 0.
pub fn snd_set_mute(muted: bool) u32 {
    const saved = audio_lock.lock();
    defer audio_lock.unlock(saved);
    stream_muted = muted;
    return 0;
}

/// The observed pcm_info reply (recorded by `snd_pcm_probe`).
pub var beep_obs_formats: u64 = 0;
pub var beep_obs_rates: u64 = 0;
pub var beep_obs_ch_min: u8 = 0;
pub var beep_obs_ch_max: u8 = 0;
pub var beep_obs_dir: u8 = 0xff;
pub var beep_info_status: u32 = 0xffffffff; // PCM_INFO reply status

/// Current device status (device_status register, common cfg + 0x14). 0xff
/// when the transport was never discovered. When the register path is
/// suspect (a wedged device parks the CPU inside the read), the last
/// completed read — the wedge verdict itself lives in `cap_refusal`.
pub fn snd_status() u8 {
    if (snd_common == 0) return 0xff;
    if (snd_regs_suspect) return snd_status_latched;
    const st = vp_read8(0x14);
    snd_status_latched = st;
    return st;
}

/// Fresh le32 read of the device-config region (devcfg + `off`). Exposed
/// for the monitor's post-exit comparison (the identity map covers the
/// BAR0 window the capability resolved inside, so the read is safe there).
pub fn snd_read32(off: u32) u32 {
    if (snd_devcfg == 0) return 0;
    if (snd_regs_suspect) return 0;
    return mmio.mmio_read32(snd_devcfg + off);
}

/// The device-config counts, only when actually captured (never guessed).
pub fn snd_cfg() ?struct { jacks: u32, streams: u32, chmaps: u32 } {
    if (!snd_cfg_seen) return null;
    return .{ .jacks = snd_jacks, .streams = snd_streams, .chmaps = snd_chmaps };
}

/// Re-arm the transport POST-exit (claim 6420's lesson, applied to the
/// sound device): VZ resets some virtio devices at ExitBootServices, so
/// the queue setup runs again after the MMU switch. Common-config MMIO
/// writes work post-exit through the mapped Device window; PCI config-space
/// reads must stay pre-exit (claim 0013). Unconditional and idempotent.
/// Arms queue 0 (control), queue 2 (stream-0 TX / playback — A2) and queue
/// 3 (stream-0 RX / capture — M118b).
pub fn snd_rearm() bool {
    if (snd_regs_suspect) return false;
    snd_ready = false;
    ctrl_armed = false;
    tx_armed = false;
    rx_armed = false;
    beep_format = 0xff;
    if (snd_common == 0) return false;
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

    ctrl_armed = arm_queue(0, &ctrl_desc, &ctrl_avail, &ctrl_used, &ctrl_last_used, &snd_queue_notify_off);
    tx_armed = arm_queue(2, &tx_desc, &tx_avail, &tx_used, &tx_last_used, &tx_queue_notify_off);
    rx_armed = arm_queue(3, &rx_desc, &rx_avail, &rx_used, &rx_last_used, &rx_queue_notify_off);

    vp_write8(0x14, 1 | 2 | 8 | 4); // DRIVER_OK
    const driver_status = vp_read8(0x14);
    snd_status_latched = driver_status;
    if ((driver_status & 4) == 0) return false;
    // The RX queue's absence never gates playback — capture refuses by name.
    snd_ready = ctrl_armed and tx_armed;
    evidence.dump_str("VS rearm st=");
    evidence.dump_hex(vp_read8(0x14));
    evidence.dump_str(" ctrl=");
    evidence.dump_hex(if (ctrl_armed) 1 else 0);
    evidence.dump_str(" tx=");
    evidence.dump_hex(if (tx_armed) 1 else 0);
    evidence.dump_str(" rx=");
    evidence.dump_hex(if (rx_armed) 1 else 0);
    evidence.dump_str("\n");
    // M118b (#2480): the capture self-test — the boot chime's input twin.
    // Runs at most once, at the moment the transport is live, and only
    // prints when stream 0 reports INPUT (the --sound-in topology);
    // output-only and no-device boots keep byte-identical serial.
    if (snd_ready) snd_capture_probe();
    return snd_ready;
}

/// Arm one split-ring queue: select it, size it, point the three rings,
/// enable it, and capture its notify offset. Shared by queue 0 (control)
/// and queue 2 (TX). `desc/avail/used` are zeroed + the used ring's init
/// write cleaned to RAM first (BSS is not trusted zeroed — the console's
/// claim-0013 lesson).
fn arm_queue(
    qsel: u16,
    desc: *[pcm.tx_descriptors]VirtqDesc,
    avail: *VirtqAvail,
    used: *VirtqUsed,
    last_used: *u16,
    notify_off: *u16,
) bool {
    vp_write16(0x16, qsel); // queue_select
    const qsz = vp_read16(0x18);
    const size = if (qsel == 2) tx_queue_size else queue_size;
    if (qsz < size) return false;
    vp_write16(0x18, size);
    desc.* = @splat(.{ .addr = 0, .len = 0, .flags = 0, .next = 0 });
    avail.* = .{ .flags = 0, .idx = 0, .ring = @splat(0) };
    used.* = .{ .flags = 0, .idx = 0, .ring = @splat(.{ .id = 0, .len = 0 }) };
    mmu.clean_dcache_range(@intFromPtr(desc), @sizeOf(@TypeOf(desc.*)));
    mmu.clean_dcache_range(@intFromPtr(avail), @sizeOf(VirtqAvail));
    mmu.clean_dcache_range(@intFromPtr(used), @sizeOf(VirtqUsed));
    last_used.* = 0;
    // Claim 5804: queue GPAs are guest PHYSICAL addresses — translate the
    // post-jump kernel VAs.
    const qd = mmu.to_phys(@intFromPtr(desc));
    mmio.mmio_write32(snd_common + 0x20, @truncate(qd));
    mmio.mmio_write32(snd_common + 0x24, @truncate(qd >> 32));
    const qa = mmu.to_phys(@intFromPtr(avail));
    mmio.mmio_write32(snd_common + 0x28, @truncate(qa));
    mmio.mmio_write32(snd_common + 0x2c, @truncate(qa >> 32));
    const qu = mmu.to_phys(@intFromPtr(used));
    mmio.mmio_write32(snd_common + 0x30, @truncate(qu));
    mmio.mmio_write32(snd_common + 0x34, @truncate(qu >> 32));
    vp_write16(0x1c, 1); // queue_enable
    notify_off.* = vp_read16(0x1e); // queue_notify_off
    return true;
}

fn vp_read8(off: u32) u8 {
    return mmio.mmio_read8(snd_common + off);
}

fn vp_write8(off: u32, value: u8) void {
    mmio.mmio_write8(snd_common + off, value);
}

fn vp_read16(off: u32) u16 {
    return mmio.mmio_read16(snd_common + off);
}

fn vp_write16(off: u32, value: u16) void {
    mmio.mmio_write16(snd_common + off, value);
}

fn vp_read32(off: u32) u32 {
    return mmio.mmio_read32(snd_common + off);
}

fn vp_write32(off: u32, value: u32) void {
    mmio.mmio_write32(snd_common + off, value);
}

/// Kick a queue: the 16-bit QUEUE-INDEX write at
/// notify_base + queue_notify_off * multiplier (Virtio 1.3 §4.1.5.2.1 —
/// without VIRTIO_F_NOTIFICATION_DATA the notification is the queue
/// index, NOT the avail index; the net driver's proven kick is the
/// template). `q` is the queue index (0 control, 2 TX).
fn kick(qoff: u16, q: u16) void {
    const addr = snd_notify + @as(u64, qoff) * snd_notify_mult;
    mmio.mmio_write16(addr, q);
}

/// Resolve the virtio common/notify/device-config capability addresses for
/// `dev` (its BARs + cap walk). Returns the common-config address, or 0 on
/// failure. Mirrors the net/entropy resolve_dev shape; additionally records
/// the device-config region (cfg_type 3) for the jacks/streams/chmaps read.
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
                3 => {
                    devcfg_bar = bar;
                    devcfg_off = off;
                },
                else => {},
            }
        }
        c = next;
    }
    if (common_bar >= 6 or notify_bar >= 6) return 0;
    snd_notify = bar_base[notify_bar] + notify_off;
    snd_notify_mult = notify_mult;
    snd_bar0 = bar_base[0];
    if (devcfg_bar < 6) snd_devcfg = bar_base[devcfg_bar] + devcfg_off;
    return bar_base[common_bar] + common_off;
}

/// Initialize the modern virtio-pci sound transport: locate the sound
/// device (DID 0x1059 — virtio device type 25; 0x1019 transitional also
/// accepted) on bus 0, resolve BARs + the virtio capabilities, program
/// features (VIRTIO_F_VERSION_1 mandatory), set up the CONTROL queue (queue
/// 0, split ring, size 4), capture the device-config counts, and reach
/// DRIVER_OK. PRE-EXIT only (config-space reads hang post-exit, claim
/// 0013). Evidence is dumped to the probe buffer so the host sees the
/// device + queue state either way.
pub fn virtio_snd_init() bool {
    if (pci.pci_ecam == 0) {
        evidence.dump_str("VS: no ECAM\n");
        snd_fail = "no ECAM";
        return false;
    }

    // Locate the sound device: modern DID 0x1059 (Virtio Device ID 25 +
    // 0x1040, the 2026-08-11 DID scheme), transitional 0x1019 accepted too.
    // The DID actually OBSERVED is recorded in `snd_did` (confirm-at-claim-
    // time: a differing DID is a finding, not an assumption). Bus 0, func 0.
    var found_dev: u32 = 32; // sentinel: not found
    var dev: u32 = 0;
    while (dev < 32) : (dev += 1) {
        const id = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0);
        if ((id & 0xffff) == 0xffff) continue;
        const did = id >> 16;
        if (did != 0x1059 and did != 0x1019) continue;
        found_dev = dev;
        snd_did = did;
        snd_class = (pci.pci_read32(pci.pci_ecam, 0, dev, 0, 8) >> 8) & 0xffffff;
        break;
    }
    if (found_dev == 32) {
        evidence.dump_str("VS: no virtio-snd PCI device\n");
        snd_fail = "DID 0x1059 not found on bus 0";
        return false;
    }
    snd_dev = found_dev;
    evidence.dump_str("VS dev=");
    evidence.dump_hex(snd_dev);
    evidence.dump_str(" did=");
    evidence.dump_hex(snd_did);
    evidence.dump_str(" cls=");
    evidence.dump_hex(snd_class);
    evidence.dump_str("\n");

    snd_common = resolve_dev(snd_dev);
    if (snd_common == 0) {
        evidence.dump_str("VS: missing capability structs\n");
        snd_fail = "missing capability structs";
        return false;
    }
    evidence.dump_str("VS common=");
    evidence.dump_hex(snd_common);
    evidence.dump_str(" notify=");
    evidence.dump_hex(snd_notify);
    evidence.dump_str(" devcfg=");
    evidence.dump_hex(snd_devcfg);
    evidence.dump_str(" bar0=");
    evidence.dump_hex(snd_bar0);
    evidence.dump_str("\n");

    // Capture the device-config counts PRE-EXIT (claim 0013: config-space
    // reads hang post-exit; the devcfg MMIO window is read the same way net
    // reads its MAC). jacks/streams/chmaps are le32 at offsets 0/4/8
    // (virtio-snd §5.14.4).
    if (snd_devcfg != 0) {
        snd_jacks = mmio.mmio_read32(snd_devcfg + cfg_jacks_off);
        snd_streams = mmio.mmio_read32(snd_devcfg + cfg_streams_off);
        snd_chmaps = mmio.mmio_read32(snd_devcfg + cfg_chmaps_off);
        snd_cfg_seen = true;
        evidence.dump_str("VS cfg j=");
        evidence.dump_hex(snd_jacks);
        evidence.dump_str(" s=");
        evidence.dump_hex(snd_streams);
        evidence.dump_str(" c=");
        evidence.dump_hex(snd_chmaps);
        evidence.dump_str("\n");
    }

    // Modern transport init: reset, ACKNOWLEDGE|DRIVER, accept
    // VIRTIO_F_VERSION_1, FEATURES_OK (the console/blk/entropy sequence).
    vp_write8(0x14, 0); // reset
    var reset_spins: usize = 0;
    while (vp_read8(0x14) != 0) : (reset_spins += 1) {
        if (reset_spins >= 1_000_000) {
            evidence.dump_str("VS: reset timeout\n");
            snd_fail = "reset timeout";
            return false;
        }
    }
    vp_write8(0x14, 1 | 2); // ACKNOWLEDGE | DRIVER
    snd_feats = vp_read32(0x04);
    evidence.dump_str("VS feats=");
    evidence.dump_hex(snd_feats);
    evidence.dump_str("\n");
    vp_write32(0x08, 1);
    vp_write32(0x0c, 1); // accept VIRTIO_F_VERSION_1
    vp_write8(0x14, 1 | 2 | 8); // FEATURES_OK
    if ((vp_read8(0x14) & 8) == 0) {
        evidence.dump_str("VS: FEATURES_OK failed\n");
        snd_fail = "FEATURES_OK failed";
        return false;
    }

    // Queue 0 = the CONTROL queue (virtio-snd §4: queue 0 is control, 1 is
    // events, 2+ are PCM). A1 arms the control queue; A2's PCM queues are
    // armed by the post-exit re-arm (claim 6420's lesson — the pre-exit
    // queue setup is a no-op the moment ExitBootServices resets it).
    if (!arm_queue(0, &ctrl_desc, &ctrl_avail, &ctrl_used, &ctrl_last_used, &snd_queue_notify_off)) {
        evidence.dump_str("VS: queue 0 too small\n");
        snd_fail = "queue 0 too small";
        return false;
    }
    vp_write8(0x14, 1 | 2 | 8 | 4); // DRIVER_OK
    if ((vp_read8(0x14) & 4) == 0) {
        evidence.dump_str("VS: DRIVER_OK failed\n");
        snd_fail = "DRIVER_OK failed";
        return false;
    }
    evidence.dump_str("VS qsz=");
    evidence.dump_hex(vp_read16(0x18));
    evidence.dump_str(" qen=");
    evidence.dump_hex(vp_read16(0x1c));
    evidence.dump_str(" qoff=");
    evidence.dump_hex(snd_queue_notify_off);
    evidence.dump_str(" st=");
    evidence.dump_hex(vp_read8(0x14));
    evidence.dump_str("\n");
    snd_ready = true;
    snd_fail = "";
    return true;
}

// ---------------------------------------------------------------------------
// A2: the CONTROL-queue request/response exchanges (virtio-snd §5.14.6)
// ---------------------------------------------------------------------------

/// Control request + reply staging (BSS — the driver's other transports use
/// global staging too; the stack is not trusted for DMA). Sized for the
/// largest exchange: PCM_INFO = 32 B info + 4 B status.
var ctl_req_buf: [64]u8 align(64) = undefined;
pub var ctl_reply_buf: [64]u8 align(64) = undefined;

/// Exchange diagnostics (the honest failure record — which stage bailed).
/// 0 = ok; 1 = queue not armed; 2 = request too large; 3 = drain timeout;
/// 4 = bad used id; 5 = short reply.
pub var ctl_fail_stage: u32 = 0;
pub var ctl_spins: usize = 0;
pub var ctl_used_idx: u16 = 0;
pub var ctl_used_id: u32 = 0;
pub var ctl_used_len: u32 = 0;
/// The used-ring poll budget for one control exchange. INPUT-stream START
/// can block on host mic consent (the M118b observation), so the capture
/// path widens its own budget rather than the shared one.
pub var ctl_spin_budget: usize = 60_000_000;

/// One control-queue exchange: submit [request][reply] and poll the used
/// ring for completion. Returns the reply's status code (S_OK = 0 on
/// success; 0xffffffff on transport failure). `reply` must fit the staging
/// buffer; the device writes the reply data + appends the 4-byte status.
fn ctl_exchange(request: []const u8, reply_len: usize) u32 {
    ctl_fail_stage = 0;
    ctl_spins = 0;
    if (!ctrl_armed) {
        ctl_fail_stage = 1;
        return 0xffffffff;
    }
    if (request.len > ctl_req_buf.len or reply_len > ctl_reply_buf.len) {
        ctl_fail_stage = 2;
        return 0xffffffff;
    }
    @memcpy(ctl_req_buf[0..request.len], request);
    @memset(&ctl_reply_buf, 0xff);
    mmu.clean_dcache_range(@intFromPtr(&ctl_reply_buf), ctl_reply_buf.len);

    // desc 0: the request (device-readable, NEXT)
    ctrl_desc[0] = .{ .addr = mmu.to_phys(@intFromPtr(&ctl_req_buf)), .len = @intCast(request.len), .flags = VIRTQ_DESC_F_NEXT, .next = 1 };
    // desc 1: the reply (device-writable, last)
    ctrl_desc[1] = .{ .addr = mmu.to_phys(@intFromPtr(&ctl_reply_buf)), .len = @intCast(reply_len), .flags = VIRTQ_DESC_F_WRITE, .next = 0 };

    const avail_idx = ctrl_avail.idx;
    ctrl_avail.ring[avail_idx % queue_size] = 0;
    ctrl_avail.idx = avail_idx +% 1;
    mmu.clean_dcache_range(@intFromPtr(&ctrl_desc), @sizeOf(VirtqDesc) * 2);
    mmu.clean_dcache_range(@intFromPtr(&ctrl_avail), @sizeOf(VirtqAvail));
    mmu.clean_dcache_range(@intFromPtr(&ctl_req_buf), request.len);
    kick(snd_queue_notify_off, 0);

    // Poll the used ring (bounded — the device completes a control
    // exchange or the transport is stuck; the START exchange can take
    // longer — the host audio device setup — hence the generous budget).
    // The device's DMA write is invisible to the guest's cache without an
    // invalidate on every poll (the console/blk/net poll pattern — the
    // net TX wait invalidates the used ring's cache line each iteration).
    var spins: usize = 0;
    while (true) : (spins += 1) {
        mmu.invalidate_dcache_range(@intFromPtr(&ctrl_used), @sizeOf(VirtqUsed));
        if (ctrl_used.idx != ctrl_last_used) break;
        if (spins > ctl_spin_budget) {
            ctl_fail_stage = 3;
            ctl_spins = spins;
            ctl_used_idx = ctrl_used.idx;
            return 0xffffffff;
        }
    }
    const used_elem = ctrl_used.ring[ctrl_last_used % queue_size];
    ctrl_last_used +%= 1;
    ctl_used_idx = ctrl_used.idx;
    ctl_used_id = used_elem.id;
    ctl_used_len = used_elem.len;
    if (used_elem.id != 0) {
        ctl_fail_stage = 4;
        return 0xffffffff;
    }
    // OBSERVED reply layout (live on VZ): the status hdr is the FIRST
    // word of the reply, followed by any info entries (the live bytes
    // were 0x8000 0x00000000 0x000a0020 ... — status first; the Linux
    // driver reads status last, VZ's emulation writes it first — pinned
    // by observation, recorded). The simple requests (SET_PARAMS,
    // PREPARE, ...) reply with the 4-byte status alone.
    const data_len: usize = @min(@as(usize, used_elem.len), reply_len);
    if (data_len < 4) {
        ctl_fail_stage = 5;
        return 0xffffffff;
    }
    mmu.invalidate_dcache_range(@intFromPtr(&ctl_reply_buf), ctl_reply_buf.len);
    return std.mem.readInt(u32, ctl_reply_buf[0..4], .little);
}

/// PCM_INFO(0): ask the device what stream 0 is (the A1-finding workaround
/// — the config counts read 0, so the driver must ASK). Records the reply
/// in `beep_obs_*` and returns the status. A refused exchange keeps the
/// LAST observed tuple — slot 91's report is the observation, not the
/// exchange (#2847: a wedged device must not erase its own cap record).
pub fn snd_pcm_probe() u32 {
    beep_info_status = 0xffffffff;
    if (!ctrl_armed) return 0xffffffff;
    var req: QueryInfo = .{ .hdr = .{ .code = R_PCM_INFO }, .start_id = 0, .count = 1, .size = @sizeOf(PcmInfo) };
    const st = ctl_exchange(std.mem.asBytes(&req), @sizeOf(PcmInfo) + 4);
    beep_info_status = st;
    if (st != S_OK) return st;
    if (ctl_used_len < @sizeOf(PcmInfo) + 4) return 0xffffffff;
    // OBSERVED reply layout (live on VZ): [status hdr][info entries] — the
    // status is the FIRST word, then the entries (the live reply bytes were
    // 0x8000 0x00000000 0x000a0020 ... — status first; the Linux driver
    // reads [entries][status], VZ's emulation writes status first — pinned
    // by observation, recorded).
    const status = std.mem.readInt(u32, ctl_reply_buf[0..4], .little);
    if (status != S_OK) return status;
    // The 4-byte status prefix does not align the u64 fields of PcmInfo.
    // Decode the wire rather than promising an impossible 8-byte alignment.
    beep_obs_formats = std.mem.readInt(u64, ctl_reply_buf[12..20], .little);
    beep_obs_rates = std.mem.readInt(u64, ctl_reply_buf[20..28], .little);
    beep_obs_dir = ctl_reply_buf[28];
    beep_obs_ch_min = ctl_reply_buf[29];
    beep_obs_ch_max = ctl_reply_buf[30];
    return S_OK;
}

/// Choose a format/rate/channels from the observed pcm_info. Preference
/// order: FLOAT (VZ's sink is CoreAudio Float32), S16, S32; rates
/// 48000/44100/32000/22050/16000/8000; channels: prefer the advertised
/// maximum (stereo when offered), mono otherwise.
fn pick_params() struct { format: u8, rate: u8, channels: u8 } {
    const fmt_pref = [_]u8{ FMT_FLOAT, FMT_S16, FMT_S32 };
    const rate_pref = [_]u8{ RATE_48000, RATE_44100, RATE_32000, RATE_22050, RATE_16000, RATE_8000 };
    var format: u8 = 0xff;
    for (fmt_pref) |f| {
        if ((beep_obs_formats & (@as(u64, 1) << @intCast(f))) != 0) {
            format = f;
            break;
        }
    }
    var rate: u8 = 0xff;
    for (rate_pref) |r| {
        if ((beep_obs_rates & (@as(u64, 1) << @intCast(r))) != 0) {
            rate = r;
            break;
        }
    }
    const channels: u8 = if (beep_obs_ch_min == 0 or beep_obs_ch_min > beep_obs_ch_max or beep_obs_ch_min > 2)
        0
    else if (beep_obs_ch_max >= 2) 2 else 1;
    return .{ .format = format, .rate = rate, .channels = channels };
}

/// PCM_SET_PARAMS(0, ...) — negotiate the stream's format.
pub fn snd_pcm_set_params(channels: u8, format: u8, rate: u8) u32 {
    var req: PcmSetParams = .{
        .hdr = .{ .hdr = .{ .code = R_PCM_SET_PARAMS }, .stream_id = 0 },
        .buffer_bytes = beep_buffer_bytes,
        .period_bytes = beep_period_bytes,
        .features = 0,
        .channels = channels,
        .format = format,
        .rate = rate,
        .padding = 0,
    };
    return ctl_exchange(std.mem.asBytes(&req), 4);
}

/// A control request with only a code + stream_id (PREPARE/START/STOP/...).
fn ctl_pcm_simple(code: u32) u32 {
    var req: PcmHdr = .{ .hdr = .{ .code = code }, .stream_id = 0 };
    return ctl_exchange(std.mem.asBytes(&req), 4);
}

/// Samples-per-second for a RATE_* enum value (0 for unknown).
pub fn snd_rate_hz(rate: u8) u32 {
    return switch (rate) {
        RATE_8000 => 8000,
        RATE_16000 => 16000,
        RATE_22050 => 22050,
        RATE_32000 => 32000,
        RATE_44100 => 44100,
        RATE_48000 => 48000,
        else => 0,
    };
}

/// Bytes per sample frame for a FMT_* enum value (0 for unsupported).
pub fn snd_fmt_bytes(format: u8) u32 {
    return switch (format) {
        FMT_S16 => 2,
        FMT_S32 => 4,
        FMT_FLOAT => 4,
        else => 0,
    };
}

/// Sample-frame count for a given beep duration at the negotiated rate.
fn frame_count(rate: u8, ms: u32) u32 {
    const hz = snd_rate_hz(rate);
    if (hz == 0) return 0;
    const n: u64 = @divTrunc(@as(u64, hz) * ms, 1000);
    return @intCast(@max(@as(u64, 1), n));
}

/// The EL0 audio seam (claim 7636, milestone fifteen card A3): the info
/// struct `sys_audio_info` copies out. 16 bytes, fixed layout.
pub const AudioInfo = extern struct {
    ready: u32, // transport + stream armed
    format: u8, // negotiated FMT_* (0xff = none)
    rate: u8, // negotiated RATE_* (0xff = none)
    channels: u8,
    padding: u8,
    period_bytes: u32, // the TX period the kernel submits
    max_len: u32, // the sys_audio_play length bound
};

/// The sys_audio_play length bound (bounded, zero-heap staging — a
/// melody note is a few KB; 64 KiB covers a ~0.35 s FLOAT-stereo-48 kHz
/// note and keeps the accounting honest).
pub const audio_max_len: u32 = 64 * 1024;

/// The negotiated playback state for `sys_audio_info`. Drives the
/// probe+SET_PARAMS negotiation on the FIRST call (before any play, the
/// app must learn what to synthesize); later calls report the cached
/// state. Returns `.ready = 1` only when the transport AND the
/// negotiation succeeded.
pub fn snd_audio_info() AudioInfo {
    if (mixer) |m| {
        if (m.playback.model.state == .quarantined) {
            return .{ .ready = 0, .format = 0xff, .rate = 0xff, .channels = 0, .padding = 0, .period_bytes = beep_period_bytes, .max_len = audio_max_len };
        }
    }
    if (beep_format == 0xff) {
        if (snd_audio_negotiate() != S_OK) {
            return .{
                .ready = 0,
                .format = 0xff,
                .rate = 0xff,
                .channels = 0,
                .padding = 0,
                .period_bytes = beep_period_bytes,
                .max_len = audio_max_len,
            };
        }
    }
    return .{
        .ready = if (snd_ready and tx_armed) 1 else 0,
        .format = beep_format,
        .rate = beep_rate,
        .channels = beep_channels,
        .padding = 0,
        .period_bytes = beep_period_bytes,
        .max_len = audio_max_len,
    };
}

/// The negotiation half of the control flow (claim 7636, shared with the
/// beep): PCM_INFO → pick → SET_PARAMS. Records the negotiated params in
/// beep_format/rate/channels and the step statuses. Returns S_OK or the
/// failing step's status.
pub fn snd_audio_negotiate() u32 {
    beep_fail = "";
    if (!snd_ready or !ctrl_armed) {
        beep_fail = "transport not armed";
        return 0xffffffff;
    }
    if (!tx_armed) {
        beep_fail = "TX queue (2) not armed";
        return 0xffffffff;
    }
    // 1. Enumerate the stream (the A1-finding workaround).
    const info_st = snd_pcm_probe();
    if (info_st != S_OK) {
        beep_fail = "PCM_INFO refused";
        return info_st;
    }
    const p = pick_params();
    if (beep_obs_dir != D_OUTPUT or p.channels == 0) {
        beep_fail = "no supported output channel tuple";
        return 0xffffffff;
    }
    if (p.format == 0xff) {
        beep_fail = "no supported sample format advertised";
        return 0xffffffff;
    }
    if (p.rate == 0xff) {
        beep_fail = "no supported rate advertised";
        return 0xffffffff;
    }
    // 2. Negotiate the params.
    const params_st = snd_pcm_set_params(p.channels, p.format, p.rate);
    beep_params_status = params_st;
    if (params_st != S_OK) {
        beep_fail = "SET_PARAMS refused";
        return params_st;
    }
    beep_format = p.format;
    beep_rate = p.rate;
    beep_channels = p.channels;
    return S_OK;
}

/// The control-flow preamble (claim 7636, shared with the beep):
/// PCM_INFO → SET_PARAMS → PREPARE → START. Every step's status is
/// recorded; the negotiated params land in beep_format/rate/channels.
/// Returns S_OK or the failing step's status (0xffffffff on a transport
/// failure) — the honest record is in the statuses + beep_fail.
pub fn snd_audio_start() u32 {
    const neg_st = snd_audio_negotiate();
    if (neg_st != S_OK) return neg_st;
    // 3. Prepare + start the stream.
    const prep_st = ctl_pcm_simple(R_PCM_PREPARE);
    beep_prepare_status = prep_st;
    if (prep_st != S_OK) {
        beep_fail = "PREPARE refused";
        return prep_st;
    }
    const start_st = ctl_pcm_simple(R_PCM_START);
    beep_start_status = start_st;
    if (start_st != S_OK) {
        beep_fail = "START refused";
        return start_st;
    }
    return S_OK;
}

/// Scale the staged samples in `beep_buf[4..4+chunk_len]` by the bounded
/// stream state (claim 9297): gain = (muted ? 0 : volume) / 100. In place,
/// zero heap; the 100% fast path leaves the bytes untouched (bit-exact for
/// the default VM). The frames are implied by the negotiated format and
/// channel count — the same math the synth uses — so any caller's staging
/// (synth or uaccess copy-in) is scaled uniformly.
fn apply_stream_gain(chunk_len: u32) void {
    snd_apply_gain(beep_buf[4..][0..chunk_len], beep_format, beep_channels);
}

pub fn snd_apply_gain(samples: []u8, format: u8, channels: u8) void {
    const vol: u32 = if (stream_muted) 0 else stream_volume;
    if (vol == 100) return;
    const gain: f32 = @as(f32, @floatFromInt(vol)) / 100.0;
    const fmt_b = snd_fmt_bytes(format);
    if (fmt_b == 0 or channels == 0) return;
    const frame_bytes = fmt_b * channels;
    const frames = samples.len / frame_bytes;
    var i: u32 = 0;
    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        var ch: u8 = 0;
        while (ch < channels) : (ch += 1) {
            switch (format) {
                FMT_FLOAT => {
                    const v: f32 = @bitCast(std.mem.readInt(u32, samples[i..][0..4], .little));
                    std.mem.writeInt(u32, samples[i..][0..4], @bitCast(v * gain), .little);
                },
                FMT_S16 => {
                    const s: i16 = std.mem.readInt(i16, samples[i..][0..2], .little);
                    // gain <= 1.0, so the scaled value always fits i16
                    // (scaling down never overflows) — the existing
                    // synth's @intFromFloat pattern.
                    const scaled: i16 = @intFromFloat(@as(f32, @floatFromInt(s)) * gain);
                    std.mem.writeInt(i16, samples[i..][0..2], scaled, .little);
                },
                FMT_S32 => {
                    const s: i32 = std.mem.readInt(i32, samples[i..][0..4], .little);
                    const scaled: i32 = @intCast(@divTrunc(@as(i64, s) * vol, 100));
                    std.mem.writeInt(i32, samples[i..][0..4], scaled, .little);
                },
                else => {},
            }
            i += fmt_b;
        }
    }
}

/// Submit ONE period of audio from `beep_buf[4..4+chunk_len]` (the caller
/// fills the staging — the synth for `beep`, the syscall handler's
/// uaccess copy-in for `sys_audio_play`), then drain the used entry.
/// Accounts beep_submitted/beep_drained; records pcm_status/latency.
/// Returns S_OK or 0xffffffff (with the honest reason in beep_fail).
pub fn snd_audio_submit(chunk_len: u32) u32 {
    if (chunk_len == 0 or chunk_len > beep_period_bytes) {
        beep_fail = "bad period length";
        return 0xffffffff;
    }
    const xfer: PcmXfer = .{ .stream_id = 0 };
    @memcpy(beep_buf[0..@sizeOf(PcmXfer)], std.mem.asBytes(&xfer));
    // Apply the bounded stream-state gain (claim 9297) in place before the
    // kick: gain = muted ? 0 : volume/100. One choke point for `beep`, the
    // boot chime, and `sys_audio_play`; scaling down never overflows, and
    // the submitted/drained accounting below counts bytes unchanged.
    apply_stream_gain(chunk_len);
    beep_status_staging = .{ .status = 0xffffffff, .latency_bytes = 0 };
    mmu.clean_dcache_range(@intFromPtr(&beep_status_staging), @sizeOf(@TypeOf(beep_status_staging)));
    // Submit the chain [pcm_xfer][data][pcm_status] to queue 2.
    tx_desc[0] = .{ .addr = mmu.to_phys(@intFromPtr(&beep_buf)), .len = @sizeOf(PcmXfer), .flags = VIRTQ_DESC_F_NEXT, .next = 1 };
    tx_desc[1] = .{ .addr = mmu.to_phys(@intFromPtr(&beep_buf)) + @sizeOf(PcmXfer), .len = chunk_len, .flags = VIRTQ_DESC_F_NEXT, .next = 2 };
    tx_desc[2] = .{ .addr = mmu.to_phys(@intFromPtr(&beep_status_staging)), .len = @sizeOf(PcmStatus), .flags = VIRTQ_DESC_F_WRITE, .next = 0 };
    const tx_avail_idx = tx_avail.idx;
    tx_avail.ring[tx_avail_idx % tx_queue_size] = 0;
    tx_avail.idx = tx_avail_idx +% 1;
    mmu.clean_dcache_range(@intFromPtr(&tx_desc), @sizeOf(VirtqDesc) * 3);
    mmu.clean_dcache_range(@intFromPtr(&tx_avail), @sizeOf(VirtqAvail));
    mmu.clean_dcache_range(@intFromPtr(&beep_buf), @sizeOf(PcmXfer) + chunk_len);
    kick(tx_queue_notify_off, 2);
    beep_submitted += chunk_len;
    // Drain: wait for the used entry (the device consumed the period).
    // Invalidate the used ring's cache line on every poll (the net TX
    // wait pattern — the device's DMA completion is cache-invisible).
    var spins: usize = 0;
    while (true) : (spins += 1) {
        mmu.invalidate_dcache_range(@intFromPtr(&tx_used), @sizeOf(VirtqUsed));
        if (tx_used.idx != tx_last_used) break;
        if (spins > 20_000_000) {
            beep_fail = "TX drain timeout";
            return 0xffffffff;
        }
    }
    const used_elem = tx_used.ring[tx_last_used % tx_queue_size];
    tx_last_used +%= 1;
    if (used_elem.id != 0) {
        beep_fail = "TX used entry id mismatch";
        return 0xffffffff;
    }
    if (used_elem.len != @sizeOf(PcmStatus)) {
        beep_fail = "TX short status";
        return 0xffffffff;
    }
    mmu.invalidate_dcache_range(@intFromPtr(&beep_status_staging), @sizeOf(@TypeOf(beep_status_staging)));
    beep_last_status = std.mem.readInt(u32, std.mem.asBytes(&beep_status_staging)[0..4], .little);
    beep_last_latency = std.mem.readInt(u32, std.mem.asBytes(&beep_status_staging)[4..8], .little);
    if (beep_last_status != S_OK) {
        beep_fail = "TX device refused";
        return 0xffffffff;
    }
    beep_drained += chunk_len;
    return S_OK;
}

/// The control-flow epilogue: STOP → RELEASE. Records the statuses.
pub fn snd_audio_stop() u32 {
    const stop_st = ctl_pcm_simple(R_PCM_STOP);
    beep_stop_status = stop_st;
    if (stop_st != S_OK) {
        beep_fail = "STOP refused";
        return stop_st;
    }
    const rel_st = ctl_pcm_simple(R_PCM_RELEASE);
    beep_release_status = rel_st;
    if (rel_st != S_OK) {
        beep_fail = "RELEASE refused";
        return rel_st;
    }
    return S_OK;
}

/// Synthesize a sine beep into `beep_buf` and submit it to the TX queue
/// (the A2 monitor command). The full flow: snd_audio_start → synth +
/// snd_audio_submit per period → snd_audio_stop. Returns S_OK (or the
/// failing status / 0xffffffff); every step's status is recorded.
pub fn snd_beep(freq: u32, ms: u32) u32 {
    const saved = audio_lock.lock();
    defer audio_lock.unlock(saved);
    if (!snd_legacy_available()) {
        beep_fail = "continuous PCM owns device";
        return 0xffffffff;
    }
    beep_submitted = 0;
    beep_drained = 0;
    beep_frames = 0;
    beep_last_status = 0xffffffff;
    beep_last_latency = 0;
    beep_params_status = 0xffffffff;
    beep_prepare_status = 0xffffffff;
    beep_start_status = 0xffffffff;
    beep_stop_status = 0xffffffff;
    beep_release_status = 0xffffffff;
    if (freq == 0 or freq > 20000 or ms == 0 or ms > 650) {
        beep_fail = "freq 1..20000 Hz, ms 1..650";
        return 0xffffffff;
    }
    const start_st = snd_audio_start();
    if (start_st != S_OK) return start_st;
    // Synthesize + submit the sine period-by-period into the bounded BSS
    // buffer (one period in flight at a time; the drain accounting counts
    // every period). FLOAT stereo 48 kHz = 4 B/frame/channel, so a period
    // is ~511 frames (~10.6 ms); the ms bound only limits the total
    // duration, never the buffer.
    const frames = frame_count(beep_rate, ms);
    const fmt_b = snd_fmt_bytes(beep_format);
    const frame_bytes = fmt_b * beep_channels;
    const frames_per_period = @max(@as(u32, 1), (beep_period_bytes - @sizeOf(PcmXfer)) / frame_bytes);
    var remaining: u32 = frames;
    var start_frame: u32 = 0;
    while (remaining > 0) : (start_frame += frames_per_period) {
        const period_frames = @min(remaining, frames_per_period);
        const period_bytes = period_frames * frame_bytes;
        synth_sine(freq, period_frames, beep_format, beep_channels, beep_rate, start_frame);
        const st = snd_audio_submit(period_bytes);
        if (st != S_OK) {
            _ = snd_audio_stop();
            return st;
        }
        remaining -= period_frames;
    }
    beep_frames = frames;
    return snd_audio_stop();
}

/// Milestone 15 card A4 (claim 3206): the BOOT CHIME — a short two-tone
/// "ding-dong" played once at boot through the proven A2 beep path. The
/// kernel plays it right after the post-MMU rearm when the sound device is
/// present (the default VM has no sound device, so the default boot stays
/// byte-identical — the same flag-gating as the transport itself).
/// Returns S_OK (or the failing step's status); every step's status is
/// recorded in the same beep_* fields `beep` reports, so the monitor's
/// `beep` command and the gate share one honest record.
pub fn snd_chime() u32 {
    // A rising two-note "ding-dong" (E5 → A5): 660 Hz for 150 ms, then
    // 880 Hz for 220 ms. Short enough to not slow boot, recognizable
    // enough to be the milestone's hearable composition moment.
    const st1 = snd_beep(660, 150);
    if (st1 != S_OK) return st1;
    return snd_beep(880, 220);
}

// ---------------------------------------------------------------------------
// M118b (issue #2480): the CAPTURE (RX) path — queue 3 feeding ONE bounded
// ring, capped at S16 / 48 kHz / mono, with named refusals for
// device-absent, over-cap tuple, no-input-stream and ring-full. The v1
// consumer is the boot self-test (snd_capture_probe, run once from
// snd_rearm when stream 0 reports INPUT — the --sound-in topology);
// the EL0 capture surface is M118c.
// ---------------------------------------------------------------------------

/// The v1 capture tuple — ONE stream, S16, 48 kHz, mono (the card's cap).
/// A request for anything beyond it is a named refusal, never a silent
/// conversion.
pub const cap_format: u8 = FMT_S16;
pub const cap_rate: u8 = RATE_48000;
pub const cap_channels: u8 = 1;
pub const cap_frame_bytes: u32 = 2; // S16 × mono

/// The bounded capture ring (fixed BSS, the M14 rule): ~0.68 s of
/// S16/48 kHz/mono. A write that would pass the bound refuses by name —
/// the ring never wraps silently and never drops without counting it.
pub const cap_ring_bytes: usize = 64 * 1024;
pub const cap_max_frames: u32 = cap_ring_bytes / cap_frame_bytes;
var cap_ring: [cap_ring_bytes]u8 align(64) = undefined;
var cap_ring_wr: usize = 0;
var cap_ring_rd: usize = 0;
pub var cap_ring_used: usize = 0;
pub var cap_ring_dropped: u64 = 0; // bytes refused by a full ring

/// RX posting geometry: four period buffers in flight at a time, each
/// 1024 S16-mono frames (~21 ms at 48 kHz).
pub const cap_slots: usize = 4;
pub const cap_period_bytes: u32 = 2048;
/// The frames the boot self-test captures: 8192 × 2 B = 16 KiB (~171 ms).
pub const cap_selftest_frames: u32 = 8192;
/// The capture START exchange's own used-ring poll budget (~5× the shared
/// 60 M): input-stream START can block on host mic consent — a bounded
/// wait, still honest about a block.
pub const cap_start_spin_budget: usize = 300_000_000;

/// One posted RX buffer: [pcm_xfer][data period][pcm_status] — the same
/// three-descriptor chain as TX with the data descriptor's direction
/// flipped to device-writable (the device fills `data`, then writes
/// `status`). `xfer`, `data` and `status` each sit on their own 64-byte
/// line so the dcache ops never span regions with different directions.
const CapBuf = extern struct {
    xfer: u32 = 0, // stream_id (device-readable)
    xfer_pad: [60]u8 = @splat(0),
    data: [cap_period_bytes]u8 align(64) = @splat(0), // device-writable
    status: PcmStatus = .{ .status = 0xffffffff, .latency_bytes = 0 }, // device-writable
    status_pad: [56]u8 = @splat(0),
};
var cap_bufs: [cap_slots]CapBuf align(64) = @splat(.{});

/// Capture accounting + last result (the gate's evidence; mirrors the
/// beep_* honest-record naming).
pub var cap_submitted: u32 = 0; // RX periods posted
pub var cap_completed: u32 = 0; // RX periods the device completed
pub var cap_frames: u32 = 0; // frames drained into the ring
pub var cap_bytes: u64 = 0; // sample bytes drained
pub var cap_nonzero: u64 = 0; // nonzero sample bytes (the silence detector)
pub var cap_sum: u32 = 0x811c9dc5; // FNV-1a 32 over the drained bytes
pub var cap_fail: []const u8 = ""; // honest refusal ("" = ok)

/// M118c (#2481): the refusal class paired with `cap_fail`'s text — the
/// slot-92 handler maps this to the ADR 0007 errno. The string is the
/// human/serial record; the enum is the machine one (the EL0 seam never
/// string-matches).
pub const CapRefusal = enum(u8) {
    none,
    no_device, // no virtio-snd device attached
    rx_unarmed, // queue 3 (stream RX) never armed
    over_cap, // the requested tuple is beyond S16/48kHz/mono
    over_ring, // the request exceeds the ring bound
    no_input, // stream 0 is not INPUT, or lacks the v1 tuple
    ctl_refused, // a control exchange refused (transport-level failure)
    ctl_timeout, // a control exchange expired its poll budget — the mic-denied wedge
    drain_timeout, // the bounded RX drain expired (e.g. host mic denied)
    malformed, // malformed used-ring completion
    device_refused, // the device refused a posted buffer
    ring_full, // the bounded ring refused a write
    epilogue, // STOP/RELEASE refused
};
pub var cap_refusal: CapRefusal = .none;

fn cap_set_fail(why: []const u8, refusal: CapRefusal) void {
    cap_fail = why;
    cap_refusal = refusal;
}

/// The refusal class for a dead ctl exchange: stage 3 — the used-ring
/// poll expired its budget — is a TIMEOUT (the mic-denied wedge's name is
/// ETIMEDOUT); every other stage is a transport refusal (EIO).
fn ctl_refusal_class() CapRefusal {
    return if (ctl_fail_stage == 3) .ctl_timeout else .ctl_refused;
}

/// M118c (#2481): the capture-side info struct `sys_audio_rec_info` copies
/// out — the slot-42 shape for the RX direction. 16 bytes, fixed layout.
pub const AudioCapInfo = extern struct {
    ready: u32, // RX queue armed AND stream 0 last observed INPUT with the v1 tuple
    format: u8, // the v1 capture tuple when ready (0xff when not)
    rate: u8, // (0xff when not)
    channels: u8, // (0 when not)
    padding: u8,
    period_bytes: u32, // one posted RX period
    ring_bytes: u32, // the bounded ring — also the per-call byte bound
};

/// The capture capability report for slot 91: the LAST OBSERVED stream-0
/// topology held to the v1 tuple — no device exchange in this call (the
/// rearm-time self-test and every `snd_capture` refresh `beep_obs_*`, so a
/// device-present boot always carries an observation; a never-probed or
/// no-device boot reads ready=0 with the 0xff sentinels).
pub fn snd_cap_info() AudioCapInfo {
    const ready = snd_ready and ctrl_armed and rx_armed and
        beep_obs_dir == D_INPUT and
        cap_admit_caps(beep_obs_dir, beep_obs_formats, beep_obs_rates, beep_obs_ch_min) == null;
    return .{
        .ready = if (ready) 1 else 0,
        .format = if (ready) cap_format else 0xff,
        .rate = if (ready) cap_rate else 0xff,
        .channels = if (ready) cap_channels else 0,
        .padding = 0,
        .period_bytes = cap_period_bytes,
        .ring_bytes = @intCast(cap_ring_bytes),
    };
}
/// Per-step control statuses (same roles as beep_*_status).
pub var cap_info_status: u32 = 0xffffffff;
pub var cap_params_status: u32 = 0xffffffff;
pub var cap_prepare_status: u32 = 0xffffffff;
pub var cap_start_status: u32 = 0xffffffff;
pub var cap_stop_status: u32 = 0xffffffff;
pub var cap_release_status: u32 = 0xffffffff;

/// Append `bytes` to the ring FIFO. Refuses honestly when the free space
/// is short — the bytes are counted in `cap_ring_dropped` and NOTHING is
/// written (no partial write, no silent wrap).
fn cap_ring_push(bytes: []const u8) error{RingFull}!void {
    if (bytes.len > cap_ring_bytes - cap_ring_used) {
        cap_ring_dropped += bytes.len;
        return error.RingFull;
    }
    const head = @min(bytes.len, cap_ring_bytes - cap_ring_wr);
    @memcpy(cap_ring[cap_ring_wr..][0..head], bytes[0..head]);
    @memcpy(cap_ring[0 .. bytes.len - head], bytes[head..]);
    cap_ring_wr = (cap_ring_wr + bytes.len) % cap_ring_bytes;
    cap_ring_used += bytes.len;
}

/// Read up to `out.len` bytes FIFO; returns the count moved (0 = empty).
pub fn cap_ring_pop(out: []u8) usize {
    const n = @min(out.len, cap_ring_used);
    const head = @min(n, cap_ring_bytes - cap_ring_rd);
    @memcpy(out[0..head], cap_ring[cap_ring_rd..][0..head]);
    @memcpy(out[head..n], cap_ring[0 .. n - head]);
    cap_ring_rd = (cap_ring_rd + n) % cap_ring_bytes;
    cap_ring_used -= n;
    return n;
}

fn cap_ring_reset() void {
    cap_ring_wr = 0;
    cap_ring_rd = 0;
    cap_ring_used = 0;
    cap_ring_dropped = 0;
}

/// The request-vs-cap check (pure — class-A testable): anything beyond
/// the v1 tuple is refused by NAME. Returns the refusal or null.
pub fn cap_admit(format: u8, rate: u8, channels: u8) ?[]const u8 {
    if (format != cap_format) return "capture format over cap (S16)";
    if (rate != cap_rate) return "capture rate over cap (48kHz)";
    if (channels != cap_channels) return "capture channels over cap (mono)";
    return null;
}

/// The device-vs-cap check (pure): refuses by name when stream 0 is not
/// an input or cannot speak the v1 tuple.
pub fn cap_admit_caps(dir: u8, formats: u64, rates: u64, ch_min: u8) ?[]const u8 {
    if (dir != D_INPUT) return "no input stream";
    if (formats & (@as(u64, 1) << cap_format) == 0) return "device lacks S16 capture";
    if (rates & (@as(u64, 1) << cap_rate) == 0) return "device lacks 48kHz capture";
    if (ch_min > cap_channels) return "device lacks mono capture";
    return null;
}

/// Post one RX slot on queue 3: chain [pcm_xfer][data (device-writable)]
/// [pcm_status (device-writable)] — the TX chain with the data
/// descriptor's direction flipped.
fn rx_post(slot: usize) void {
    const head: u16 = @intCast(slot * 3);
    const buf = &cap_bufs[slot];
    buf.xfer = 0; // stream 0
    buf.status = .{ .status = 0xffffffff, .latency_bytes = 0 };
    rx_desc[head] = .{ .addr = mmu.to_phys(@intFromPtr(&buf.xfer)), .len = 4, .flags = VIRTQ_DESC_F_NEXT, .next = head + 1 };
    rx_desc[head + 1] = .{ .addr = mmu.to_phys(@intFromPtr(&buf.data)), .len = cap_period_bytes, .flags = VIRTQ_DESC_F_WRITE | VIRTQ_DESC_F_NEXT, .next = head + 2 };
    rx_desc[head + 2] = .{ .addr = mmu.to_phys(@intFromPtr(&buf.status)), .len = @sizeOf(PcmStatus), .flags = VIRTQ_DESC_F_WRITE, .next = 0 };
    mmu.clean_dcache_range(@intFromPtr(&rx_desc[head]), @sizeOf(VirtqDesc) * 3);
    // The whole slot buffer is cleaned before the kick: `xfer` carries the
    // CPU write; the device-WRITE regions (data + status) get it so a
    // dirty BSS line can never writeback over the DMA payload. The
    // completion side invalidates before the CPU reads.
    mmu.clean_dcache_range(@intFromPtr(buf), @sizeOf(CapBuf));
    const index = rx_avail.idx;
    rx_avail.ring[index % rx_queue_size] = head;
    rx_avail.idx = index +% 1;
    mmu.clean_dcache_range(@intFromPtr(&rx_avail), @sizeOf(VirtqAvail));
    kick(rx_queue_notify_off, 3);
    cap_submitted += 1;
    if (@import("builtin").is_test) {
        if (test_rx_post_hook) |h| h(slot);
    }
}

/// Consume one completed RX slot: verify the status the device wrote,
/// push the sample bytes into the bounded ring, and fold them into the
/// receipt (byte count + FNV-1a + nonzero count). `used_len` is the
/// device's total written length spanning [data][status]; the sample
/// payload is it minus the 8-byte pcm_status.
fn rx_consume(slot: usize, used_len: u32) u32 {
    const buf = &cap_bufs[slot];
    mmu.invalidate_dcache_range(@intFromPtr(&buf.status), @sizeOf(PcmStatus));
    if (buf.status.status != S_OK) {
        cap_set_fail("RX device refused", .device_refused);
        return 0xffffffff;
    }
    const payload = @min(used_len -| @sizeOf(PcmStatus), cap_period_bytes);
    if (payload == 0) return S_OK;
    mmu.invalidate_dcache_range(@intFromPtr(&buf.data), payload);
    cap_ring_push(buf.data[0..payload]) catch {
        cap_set_fail("capture ring full", .ring_full);
        return 0xffffffff;
    };
    for (buf.data[0..payload]) |b| {
        cap_sum = (cap_sum ^ b) *% 16777619;
        if (b != 0) cap_nonzero += 1;
    }
    cap_bytes += payload;
    cap_frames = @intCast(cap_bytes / cap_frame_bytes);
    return S_OK;
}

/// The bounded RX drain: consume completions into the ring until
/// `want_bytes` land, the device stops completing (`outstanding` hits 0),
/// or `deadline_ns` fires. The deadline is evaluated EVERY iteration —
/// ahead of the no-completion branch — because a device that completes
/// posted buffers continuously (OBSERVED 2026-10-20, macOS 27.2
/// mic-denied VZ input stream: len = PcmStatus + 0 payload, reposted
/// forever) keeps `outstanding` constant and would starve an
/// idle-path-only check (#2847). Extracted so the host test can drive it.
fn cap_drain(want_bytes: usize, deadline_ns: u64) void {
    var outstanding: u32 = cap_slots;
    var spins: usize = 0;
    while (cap_bytes < want_bytes and outstanding > 0) : (spins += 1) {
        mmu.invalidate_dcache_range(@intFromPtr(&rx_used), @sizeOf(VirtqUsed));
        const expired = if (timer.freq != 0)
            snd_stream_now() >= deadline_ns
        else
            spins > 400_000_000;
        if (expired) {
            cap_set_fail("RX drain timeout", .drain_timeout);
            return;
        }
        if (rx_used.idx == rx_last_used) continue;
        const used_elem = rx_used.ring[rx_last_used % rx_queue_size];
        rx_last_used +%= 1;
        outstanding -= 1;
        cap_completed += 1;
        if (used_elem.id % 3 != 0 or used_elem.id / 3 >= cap_slots) {
            cap_set_fail("RX malformed completion", .malformed);
            return;
        }
        const slot = used_elem.id / 3;
        if (rx_consume(slot, used_elem.len) != S_OK) return;
        if (cap_bytes < want_bytes) {
            rx_post(slot);
            outstanding += 1;
        }
    }
}

/// Bounded capture: negotiate the v1 tuple on stream 0, then drain the
/// RX queue into the ring until `want_frames` land. Returns S_OK, the
/// failing step's status, or 0xffffffff on a transport/request refusal —
/// `cap_fail` names every refusal. The caller serializes (the boot
/// self-test today; the M118c syscall path under audio_lock later).
pub fn snd_capture(format: u8, rate: u8, channels: u8, want_frames: u32) u32 {
    cap_set_fail("", .none);
    if (!snd_ready or !ctrl_armed) {
        cap_set_fail("no virtio-snd device", .no_device);
        return 0xffffffff;
    }
    if (!rx_armed) {
        cap_set_fail("RX queue (3) not armed", .rx_unarmed);
        return 0xffffffff;
    }
    if (cap_admit(format, rate, channels)) |why| {
        cap_set_fail(why, .over_cap);
        return 0xffffffff;
    }
    if (want_frames == 0 or want_frames > cap_max_frames) {
        cap_set_fail("capture request exceeds ring", .over_ring);
        return 0xffffffff;
    }
    cap_ring_reset();
    cap_submitted = 0;
    cap_completed = 0;
    cap_frames = 0;
    cap_bytes = 0;
    cap_nonzero = 0;
    cap_recovered = false;
    cap_sum = 0x811c9dc5; // FNV-1a basis
    cap_info_status = 0xffffffff;
    cap_params_status = 0xffffffff;
    cap_prepare_status = 0xffffffff;
    cap_start_status = 0xffffffff;
    cap_stop_status = 0xffffffff;
    cap_release_status = 0xffffffff;

    // 1. What is stream 0 today? (The A1-finding workaround — the devcfg
    //    counts read zero, so the driver asks.)
    const info_st = snd_pcm_probe();
    cap_info_status = info_st;
    if (info_st != S_OK) {
        cap_set_fail("PCM_INFO refused", ctl_refusal_class());
        return info_st;
    }
    if (cap_admit_caps(beep_obs_dir, beep_obs_formats, beep_obs_rates, beep_obs_ch_min)) |why| {
        cap_set_fail(why, .no_input);
        return 0xffffffff;
    }
    // 2. Negotiate the v1 tuple.
    const req = PcmSetParams{
        .hdr = .{ .hdr = .{ .code = R_PCM_SET_PARAMS }, .stream_id = 0 },
        .buffer_bytes = cap_ring_bytes,
        .period_bytes = cap_period_bytes,
        .features = 0,
        .channels = cap_channels,
        .format = cap_format,
        .rate = cap_rate,
        .padding = 0,
    };
    const params_st = ctl_exchange(std.mem.asBytes(&req), 4);
    cap_params_status = params_st;
    if (params_st != S_OK) {
        cap_set_fail("SET_PARAMS refused", ctl_refusal_class());
        return params_st;
    }
    const prep_st = ctl_pcm_simple(R_PCM_PREPARE);
    cap_prepare_status = prep_st;
    if (prep_st != S_OK) {
        cap_set_fail("PREPARE refused", ctl_refusal_class());
        return prep_st;
    }
    // 3. START, then post the slot buffers — the device fills a posted
    //    period and completes it on the used ring. OBSERVED (2026-10-17,
    //    live on VZ, M118b): posting the RX buffers BEFORE START wedges
    //    the control queue — the START exchange times out; START-first
    //    returns 0x8000 instantly. The order below is pinned by that.
    //    INPUT START can also stall on host mic consent (TCC), so it gets
    //    its own budget — bounded, never a hang.
    ctl_spin_budget = cap_start_spin_budget;
    const start_st = ctl_pcm_simple(R_PCM_START);
    ctl_spin_budget = 60_000_000;
    cap_start_status = start_st;
    if (start_st != S_OK) {
        cap_set_fail("START refused", ctl_refusal_class());
        // A START that expired its budget wedged the device below the ctl
        // channel — every later register read stalls (OBSERVED 2026-10-20).
        if (ctl_fail_stage == 3) snd_regs_suspect = true;
        // Cleanup must not mask the primary refusal.
        const cleanup = cap_fail;
        const cleanup_refusal = cap_refusal;
        _ = snd_capture_stop();
        cap_fail = cleanup;
        cap_refusal = cleanup_refusal;
        snd_capture_recover();
        return start_st;
    }
    // 4. Drain until want_frames or the bound (wall-clock when the timer
    //    is live, a spin budget otherwise — the self-test asks for ~171 ms
    //    of audio and gets seconds of slack).
    for (0..cap_slots) |s| rx_post(s);
    const want_bytes: usize = @as(usize, want_frames) * cap_frame_bytes;
    cap_drain(want_bytes, snd_stream_now() + 5 * std.time.ns_per_s);
    const tail_st = blk: {
        // The epilogue's own refusal never masks the drain's primary one.
        const primary = cap_fail;
        const primary_refusal = cap_refusal;
        const s = snd_capture_stop();
        if (primary.len != 0) {
            cap_fail = primary;
            cap_refusal = primary_refusal;
            break :blk s;
        }
        break :blk s;
    };
    snd_capture_recover();
    if (cap_fail.len != 0) return 0xffffffff;
    return tail_st;
}

/// OBSERVED (2026-10-17, live on VZ): a mic-denied input stream wedges
/// the whole control channel — after the bounded drain times out, STOP,
/// RELEASE and even PCM_INFO all stop answering (transport-level
/// 0xffffffff, never a device status). The virtio reset inside
/// `snd_rearm` is the recovery: re-arm the transport so the next caller
/// finds a working device (the same reset the mixer's recovery path
/// uses). The capture's own result is unchanged — recovery is for the
/// NEXT user of the device.
pub var cap_recovered: bool = false;
fn snd_capture_recover() void {
    // On a START-expired wedge the recovery reset's first register read
    // never completes — recovery is itself the hang, so the refusal stands
    // and the device stays armed for a later, healthier attempt. A
    // drain-time wedge (START answered; the stream datapath then stopped)
    // still rearms — the registers answer there.
    if (snd_regs_suspect) return;
    if (cap_stop_status == 0xffffffff or cap_release_status == 0xffffffff) {
        cap_recovered = true;
        _ = snd_rearm();
    }
}

/// The capture epilogue: STOP → RELEASE + a bounded drain of the posted
/// buffers the device returns on stop (virtio-snd: STOP completes pending
/// I/O — consume the entries so a later capture never reads stale
/// completions). Records cap_stop_status/cap_release_status.
fn snd_capture_stop() u32 {
    const stop_st = ctl_pcm_simple(R_PCM_STOP);
    cap_stop_status = stop_st;
    // Best-effort: bounded wait for in-flight completions, then RELEASE
    // regardless — a device that never returns them is not a hang reason.
    var spins: usize = 0;
    var completed: u32 = 0;
    while (completed < cap_slots and spins < 60_000_000) : (spins += 1) {
        mmu.invalidate_dcache_range(@intFromPtr(&rx_used), @sizeOf(VirtqUsed));
        if (rx_used.idx == rx_last_used) continue;
        _ = rx_used.ring[rx_last_used % rx_queue_size];
        rx_last_used +%= 1;
        completed += 1;
    }
    const rel_st = ctl_pcm_simple(R_PCM_RELEASE);
    cap_release_status = rel_st;
    if (stop_st != S_OK) {
        cap_set_fail("STOP refused", .epilogue);
        return stop_st;
    }
    if (rel_st != S_OK) {
        cap_set_fail("RELEASE refused", .epilogue);
        return rel_st;
    }
    return S_OK;
}

var cap_probe_done: bool = false;

/// The boot self-test — the capture path's boot-chime twin. Runs at most
/// once, from snd_rearm at the moment the transport is live (the
/// single-threaded boot context needs no audio_lock; the once-flag keeps
/// the mixer-reset rearm path from re-entering). SILENT unless stream 0
/// reports INPUT — output-only and no-device boots keep byte-identical
/// serial. On INPUT (the --sound-in topology) it runs one bounded capture
/// and prints the receipt plus the named-refusal exercise: the gate's
/// evidence and the mic-TCC question's answer.
fn snd_capture_probe() void {
    if (cap_probe_done) return;
    cap_probe_done = true;
    if (!snd_ready or !ctrl_armed or !rx_armed) return;
    if (snd_pcm_probe() != S_OK or beep_obs_dir != D_INPUT) return;
    var buf: [384]u8 = undefined;
    cap_line(&buf, "cap: rx capture fmt={d} rate={d} ch={d} want={d}", .{ cap_format, cap_rate, cap_channels, cap_selftest_frames });
    const st = snd_capture(cap_format, cap_rate, cap_channels, cap_selftest_frames);
    cap_line(&buf, "cap: info=0x{x:0>16} params=0x{x:0>16} prepare=0x{x:0>16} start=0x{x:0>16}", .{ cap_info_status, cap_params_status, cap_prepare_status, cap_start_status });
    if (st == S_OK) {
        cap_line(&buf, "cap: captured={d} frames bytes={d} ring={d}/{d} dropped={d} nonzero={d} sum=0x{x:0>8}", .{ cap_frames, cap_bytes, cap_ring_used, cap_ring_bytes, cap_ring_dropped, cap_nonzero, cap_sum });
        cap_line(&buf, "cap: stop=0x{x:0>16} release=0x{x:0>16}", .{ cap_stop_status, cap_release_status });
        cap_line(&buf, "cap: ok", .{});
    } else {
        cap_line(&buf, "cap: captured={d} frames bytes={d} nonzero={d}", .{ cap_frames, cap_bytes, cap_nonzero });
        // The exchange diagnostics name the failing stage: 1 unarmed /
        // 2 oversize / 3 drain timeout / 4 bad used id / 5 short reply.
        cap_line(&buf, "cap: FAILED ({s}) ctl stage={d} stop=0x{x:0>16} release=0x{x:0>16} recovered={d}", .{ cap_fail, ctl_fail_stage, cap_stop_status, cap_release_status, @intFromBool(cap_recovered) });
    }
    // The named-refusal exercise — pure checks plus the ring bound, no
    // device touch, so the gate sees the refusal names whatever the
    // device did. `snd_capture` with an over-ring request refuses before
    // probing, leaving the receipt's accounting intact.
    const fwhy = cap_admit(FMT_FLOAT, cap_rate, cap_channels) orelse "";
    const rwhy = cap_admit(cap_format, RATE_44100, cap_channels) orelse "";
    const cwhy = cap_admit(cap_format, cap_rate, 2) orelse "";
    _ = snd_capture(cap_format, cap_rate, cap_channels, cap_max_frames + 1);
    cap_line(&buf, "cap: refuse fmt '{s}' rate '{s}' ch '{s}' ring '{s}'", .{ fwhy, rwhy, cwhy, cap_fail });
}

fn cap_line(buf: []u8, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(buf, fmt ++ "\n", args) catch return;
    klog.line(s);
}

const StatusLine = extern struct {
    status: u32 = 0xffffffff,
    latency_bytes: u32 = 0,
    padding: [56]u8 = @splat(0),
};
var beep_status_staging: StatusLine align(64) = .{};

// B7 opt-in stream ABI. The flag is in x1 so legacy callers' unused x2
// register never changes their behavior. Operations use x2; x3 is generation.
pub const audio_stream_flag: u64 = @as(u64, 1) << 63;
pub const StreamOp = enum(u64) { open = 1, submit = 2, start = 3, end = 4, abort = 5, status = 6 };
pub const StreamParams = extern struct {
    format: u8,
    rate: u8,
    channels: u8,
    reserved: u8 = 0,
    version: u32 = 1,
};
/// M99b (ADR 0046): status is per-source now. accepted/submitted/completed/
/// canceled/underruns count this source's bytes through the mix; `slots` is
/// the per-source queue bound; sources/peak_sources/refused are mixer-wide
/// occupancy and over-cap (ENOSPC) counters; clipped is mixer-wide samples
/// clamped at the post-sum saturation; starts..resets count the shared
/// device stream's lifecycle.
pub const StreamStatus = extern struct {
    generation: u64,
    accepted: u64,
    submitted: u64,
    completed: u64,
    canceled: u64,
    underruns: u64,
    clipped: u64,
    state: u32,
    reason: u32,
    outstanding: u32,
    slots: u32,
    sources: u32,
    peak_sources: u32,
    refused: u32,
    starts: u32,
    stops: u32,
    releases: u32,
    resets: u32,
};
pub var audio_lock = spinlock.IrqSaveSpinlock{};
// One fixed pool charge on first open, retained for reuse/quarantine. Keeping
// the mixer's ~100 KiB of source+ring storage out of the flat kernel
// preserves its 16 MiB loader ceiling.
pub const stream_pages = (@sizeOf(playback.Mixer) + 4095) / 4096;
pub var mixer: ?*playback.Mixer = null;
const HeaderLine = extern struct { stream_id: u32 = 0, padding: [60]u8 = @splat(0) };
var stream_headers: [pcm.slot_count]HeaderLine align(64) = @splat(.{});
var stream_statuses: [pcm.slot_count]StatusLine align(64) = @splat(.{});
var io_context: u8 = 0;
// Host tests inject the same pump boundary; production always uses PCI DMA.
pub var test_stream_io: ?playback.Io = null;
pub var test_stream_caps: ?pcm.Capabilities = null;
/// Host-test wall clock: when set, `snd_stream_now` reports it — the
/// drain's deadline is wall-clock, so a test driving the drain moves
/// time through this counter.
pub var test_now_ns: ?u64 = null;
/// Host-test device model: when set, `rx_post` invokes it after the
/// kick — a fake device completing the just-posted buffer.
pub var test_rx_post_hook: ?*const fn (slot: usize) void = null;

pub fn snd_stream_now() u64 {
    if (@import("builtin").is_test) {
        if (test_now_ns) |t| return t;
    }
    if (timer.freq == 0) return 0;
    return @intCast(@as(u128, timer.cntpct()) * 1_000_000_000 / timer.freq);
}

fn stream_io() playback.Io {
    if (@import("builtin").is_test) {
        if (test_stream_io) |io| return io;
    }
    return .{ .context = &io_context, .params = stream_set_params, .control = stream_control, .publish = stream_publish, .poll = stream_completion, .clock = stream_clock };
}

fn stream_clock(_: *anyopaque) u64 {
    return snd_stream_now();
}

fn stream_set_params(_: *anyopaque, params: pcm.Params) bool {
    beep_format = switch (params.format) {
        .s16 => FMT_S16,
        .s32 => FMT_S32,
        .float32 => FMT_FLOAT,
    };
    const rates = [_]u8{ RATE_48000, RATE_44100, RATE_32000, RATE_22050, RATE_16000, RATE_8000 };
    beep_rate = 0xff;
    for (rates) |rate| {
        if (snd_rate_hz(rate) == params.rate_hz) beep_rate = rate;
    }
    beep_channels = params.channels;
    const req = PcmSetParams{
        .hdr = .{ .hdr = .{ .code = R_PCM_SET_PARAMS }, .stream_id = 0 },
        .buffer_bytes = pcm.pcm_bytes,
        .period_bytes = pcm.period_bytes,
        .features = 0,
        .channels = beep_channels,
        .format = beep_format,
        .rate = beep_rate,
        .padding = 0,
    };
    return ctl_exchange(std.mem.asBytes(&req), 4) == S_OK;
}

fn stream_control(_: *anyopaque, kind: pcm.Control) bool {
    if (kind == .reset) return snd_rearm();
    return ctl_pcm_simple(switch (kind) {
        .prepare => R_PCM_PREPARE,
        .start => R_PCM_START,
        .stop => R_PCM_STOP,
        .release => R_PCM_RELEASE,
        .reset => unreachable,
    }) == S_OK;
}

fn stream_publish(_: *anyopaque, transfer: pcm.Transfer, payload: []const u8) void {
    const slot = transfer.head / pcm.descriptors_per_period;
    const head: u16 = @intCast(transfer.head);
    stream_headers[slot] = .{};
    stream_statuses[slot] = .{};
    tx_desc[head] = .{ .addr = mmu.to_phys(@intFromPtr(&stream_headers[slot])), .len = 4, .flags = VIRTQ_DESC_F_NEXT, .next = head + 1 };
    tx_desc[head + 1] = .{ .addr = mmu.to_phys(@intFromPtr(payload.ptr)), .len = @intCast(payload.len), .flags = VIRTQ_DESC_F_NEXT, .next = head + 2 };
    tx_desc[head + 2] = .{ .addr = mmu.to_phys(@intFromPtr(&stream_statuses[slot])), .len = 8, .flags = VIRTQ_DESC_F_WRITE, .next = 0 };
    mmu.clean_dcache_range(@intFromPtr(payload.ptr), payload.len);
    mmu.clean_dcache_range(@intFromPtr(&stream_headers[slot]), @sizeOf(HeaderLine));
    mmu.clean_dcache_range(@intFromPtr(&stream_statuses[slot]), @sizeOf(StatusLine));
    mmu.clean_dcache_range(@intFromPtr(&tx_desc[head]), @sizeOf(VirtqDesc) * 3);
    const index = tx_avail.idx;
    tx_avail.ring[index % tx_queue_size] = head;
    tx_avail.idx = index +% 1;
    mmu.clean_dcache_range(@intFromPtr(&tx_avail), @sizeOf(VirtqAvail));
    kick(tx_queue_notify_off, 2);
}

fn stream_completion(_: *anyopaque) ?playback.RawCompletion {
    if (!tx_armed) return null;
    mmu.invalidate_dcache_range(@intFromPtr(&tx_used), @sizeOf(VirtqUsed));
    if (tx_used.idx == tx_last_used) return null;
    const used = tx_used.ring[tx_last_used % tx_queue_size];
    tx_last_used +%= 1;
    if (used.id % pcm.descriptors_per_period != 0 or used.id / pcm.descriptors_per_period >= pcm.slot_count)
        return .{ .head = used.id, .written = used.len, .ok = false };
    const slot = used.id / pcm.descriptors_per_period;
    mmu.invalidate_dcache_range(@intFromPtr(&stream_statuses[slot]), @sizeOf(StatusLine));
    return .{ .head = used.id, .written = used.len, .ok = stream_statuses[slot].status == S_OK };
}

/// M99b: slots 44/45 are the post-mix choke point now — applied to each
/// composed output period after the f32 sum + clamp, not per submit.
fn stream_post_gain(_: *anyopaque, samples: []u8) void {
    snd_apply_gain(samples, beep_format, beep_channels);
}

/// Callers hold audio_lock, including seat alloc/copy/commit as one
/// transaction. M99b: each open is a mixer source seat, not the device.
pub fn snd_stream_open(owner: u64, request: StreamParams) playback.MixerError!pcm.StreamToken {
    if (mixer) |m| {
        if (m.playback.model.state == .quarantined) return error.Quarantined;
    }
    if (!snd_ready or !ctrl_armed or !tx_armed) {
        beep_fail = "NO AUDIO DEVICE: continuous PCM refused";
        return error.NoDevice;
    }
    if (request.version != 1 or request.reserved != 0) return error.UnsupportedFormat;
    const format: pcm.Format = switch (request.format) {
        FMT_S16 => .s16,
        FMT_S32 => .s32,
        FMT_FLOAT => .float32,
        else => return error.UnsupportedFormat,
    };
    const params = pcm.Params{ .format = format, .rate_hz = snd_rate_hz(request.rate), .channels = request.channels };
    // The probe/negotiation only runs when this open prepares a fresh
    // device stream; sources joining a live stream just match its tuple.
    const fresh = mixer == null or mixer.?.playback.model.state == .closed;
    var caps: ?pcm.Capabilities = null;
    if (fresh) {
        var formats: [3]pcm.Format = undefined;
        var rates: [6]u32 = undefined;
        var nf: usize = 0;
        var nr: usize = 0;
        var c: pcm.Capabilities = undefined;
        if (@import("builtin").is_test and test_stream_caps != null) {
            c = test_stream_caps.?;
        } else {
            if (snd_pcm_probe() != S_OK) return error.DeviceFailed;
            for ([_]u8{ FMT_S16, FMT_S32, FMT_FLOAT }, [_]pcm.Format{ .s16, .s32, .float32 }) |bit, fmt| {
                if (beep_obs_formats & (@as(u64, 1) << @intCast(bit)) != 0) {
                    formats[nf] = fmt;
                    nf += 1;
                }
            }
            for ([_]u8{ RATE_48000, RATE_44100, RATE_32000, RATE_22050, RATE_16000, RATE_8000 }) |bit| {
                if (beep_obs_rates & (@as(u64, 1) << @intCast(bit)) != 0) {
                    rates[nr] = snd_rate_hz(bit);
                    nr += 1;
                }
            }
            c = .{ .present = true, .output = beep_obs_dir == D_OUTPUT, .queue_descriptors = tx_queue_size, .formats = formats[0..nf], .rates_hz = rates[0..nr], .channels_min = beep_obs_ch_min, .channels_max = @min(beep_obs_ch_max, 2) };
        }
        caps = c;
    }
    if (mixer == null) {
        if (@import("builtin").is_test) return error.InsufficientCapacity;
        const physical = alloc.alloc_pages(stream_pages) orelse return error.InsufficientCapacity;
        mixer = @ptrFromInt(mmu.to_kva(physical));
        mixer.?.* = .{};
    }
    mixer.?.post_mix = stream_post_gain;
    mixer.?.post_mix_ctx = &io_context;
    return mixer.?.open(owner, caps, params, snd_stream_now(), stream_io());
}

pub fn snd_stream_drive() void {
    const m = mixer orelse return;
    m.drive(snd_stream_now(), stream_io());
}

pub fn snd_stream_status(owner: u64, generation: u64) pcm.Error!StreamStatus {
    const m = mixer orelse return error.InvalidToken;
    const token = pcm.StreamToken{ .owner = owner, .generation = generation };
    var counts: pcm.Counts = .{};
    var underruns: u64 = 0;
    var state: pcm.State = .closed;
    var reason: pcm.Reason = .none;
    if (m.source_of(token)) |s| {
        counts = s.counts;
        underruns = s.underruns;
        state = switch (s.state) {
            .idle => .prepared,
            .live => m.playback.model.state,
            .draining => .draining,
            .free => unreachable,
        };
        reason = m.playback.model.reason;
    } else {
        const last = m.last_of(token) orelse return error.InvalidToken;
        counts = last.counts;
        underruns = last.underruns;
        state = last.state;
        reason = last.reason;
    }
    return .{
        .generation = generation,
        .accepted = counts.accepted,
        .submitted = counts.submitted,
        .completed = counts.completed,
        .canceled = counts.canceled,
        .underruns = underruns,
        .clipped = m.clipped,
        .state = @backingInt(state),
        .reason = @backingInt(reason),
        .outstanding = @intCast(@min(counts.outstanding, std.math.maxInt(u32))),
        .slots = playback.source_periods,
        .sources = m.open_count,
        .peak_sources = m.peak_sources,
        .refused = @intCast(@min(m.refused, std.math.maxInt(u32))),
        .starts = @intCast(m.playback.starts),
        .stops = @intCast(m.playback.stops),
        .releases = @intCast(m.playback.releases),
        .resets = @intCast(m.playback.resets),
    };
}

/// Legacy slot-43 playback stays excluded while the mixer holds any open
/// source or a live device stream (ADR 0046 D5).
pub fn snd_legacy_available() bool {
    return if (mixer) |m| m.open_count == 0 and m.playback.model.state == .closed else true;
}

/// Exit context only changes ownership. STOP/RELEASE/reset run in the next
/// main-context pump; kernel-owned DMA storage outlives process mappings.
/// M99b: only the dead owner's source seats are torn down — other
/// processes' sources keep streaming.
pub fn snd_stream_owner_death(owner: u64) void {
    const saved = audio_lock.lock();
    defer audio_lock.unlock(saved);
    const m = mixer orelse return;
    m.owner_death(owner, snd_stream_now());
}

pub fn snd_stream_poll() void {
    const saved = audio_lock.lock();
    defer audio_lock.unlock(saved);
    snd_stream_drive();
}

test "virtio_snd: continuous DMA layout and ABI are bounded and cache isolated" {
    try std.testing.expectEqual(@as(usize, 512), @sizeOf(@TypeOf(tx_desc)));
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(VirtqAvail));
    try std.testing.expectEqual(@as(usize, 320), @sizeOf(VirtqUsed));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(HeaderLine));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(StatusLine));
    try std.testing.expectEqual(@as(usize, 1984), @sizeOf(@TypeOf(tx_desc)) + @sizeOf(VirtqAvail) + @sizeOf(VirtqUsed) + @sizeOf(@TypeOf(stream_headers)) + @sizeOf(@TypeOf(stream_statuses)));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(StreamParams));
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(StreamStatus));
    try std.testing.expectEqual(@as(u16, 32), tx_queue_size);
    try std.testing.expectEqual(@as(usize, (@sizeOf(playback.Mixer) + 4095) / 4096), stream_pages);
}

test "virtio_snd: S32 gain handles both signed endpoints exactly" {
    var samples: [8]u8 = undefined;
    std.mem.writeInt(i32, samples[0..4], std.math.maxInt(i32), .little);
    std.mem.writeInt(i32, samples[4..8], std.math.minInt(i32), .little);
    stream_volume = 50;
    stream_muted = false;
    defer {
        stream_volume = 100;
    }
    snd_apply_gain(&samples, FMT_S32, 1);
    try std.testing.expectEqual(@as(i32, 1073741823), std.mem.readInt(i32, samples[0..4], .little));
    try std.testing.expectEqual(@as(i32, -1073741824), std.mem.readInt(i32, samples[4..8], .little));
}

test "virtio_snd: quarantined storage refuses open and reports not ready" {
    var current = playback.Mixer{};
    current.playback.model.state = .quarantined;
    mixer = &current;
    defer {
        mixer = null;
    }
    try std.testing.expectError(error.Quarantined, snd_stream_open(42, .{ .format = FMT_FLOAT, .rate = RATE_48000, .channels = 2 }));
    try std.testing.expectEqual(@as(u32, 0), snd_audio_info().ready);
    try std.testing.expect(!snd_legacy_available());
}

/// Fill `beep_buf` (after the 4-byte pcm_xfer header) with a sine at
/// `freq` Hz, `frames` sample frames starting at absolute frame
/// `start_frame` (phase continuity across periods), `channels` interleaved
/// channels, in the negotiated format. Amplitude 50% (a polite beep).
fn synth_sine(freq: u32, frames: u32, format: u8, channels: u8, rate: u8, start_frame: u32) void {
    const hz = snd_rate_hz(rate);
    const step = 2.0 * std.math.pi * @as(f64, @floatFromInt(freq)) / @as(f64, @floatFromInt(hz));
    var i: u32 = 0;
    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        const t = @as(f64, @floatFromInt(start_frame + f));
        const sample = @sin(step * t) * 0.5;
        var ch: u8 = 0;
        while (ch < channels) : (ch += 1) {
            switch (format) {
                FMT_FLOAT => {
                    const v: f32 = @floatCast(sample);
                    const bytes = std.mem.asBytes(&v);
                    @memcpy(beep_buf[@sizeOf(PcmXfer) + i ..][0..4], bytes);
                },
                FMT_S16 => {
                    const v: i16 = @intFromFloat(sample * 32767.0);
                    const bytes = std.mem.asBytes(&v);
                    @memcpy(beep_buf[@sizeOf(PcmXfer) + i ..][0..2], bytes);
                },
                FMT_S32 => {
                    const v: i32 = @intFromFloat(sample * 2147483647.0);
                    const bytes = std.mem.asBytes(&v);
                    @memcpy(beep_buf[@sizeOf(PcmXfer) + i ..][0..4], bytes);
                },
                else => {},
            }
            i += snd_fmt_bytes(format);
        }
    }
}

// ---------------------------------------------------------------------------
// Host tests — only the pieces that need no device
// ---------------------------------------------------------------------------

test "virtio_snd: capture ring is bounded, FIFO across the wrap, and refuses a full write" {
    cap_ring_reset();
    var a: [10_000]u8 = undefined;
    var b: [60_000]u8 = undefined;
    for (&a, 0..) |*p, i| p.* = @truncate(i *% 31 +% 7);
    for (&b, 0..) |*p, i| p.* = @truncate(i *% 17 +% 3);
    try cap_ring_push(&a);
    try std.testing.expectEqual(@as(usize, a.len), cap_ring_used);
    // A write that would pass the bound refuses: nothing partial lands,
    // the refused bytes are counted.
    try std.testing.expectError(error.RingFull, cap_ring_push(&b));
    try std.testing.expectEqual(@as(u64, b.len), cap_ring_dropped);
    try std.testing.expectEqual(@as(usize, a.len), cap_ring_used);
    // Pop part of A, then land B — wr wraps the end of the buffer.
    var out: [cap_ring_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8_000), cap_ring_pop(out[0..8_000]));
    try std.testing.expectEqualSlices(u8, a[0..8_000], out[0..8_000]);
    try cap_ring_push(&b);
    try std.testing.expectEqual(@as(usize, 2_000 + b.len), cap_ring_used);
    // FIFO order survives the wrap: the A remainder, then all of B.
    const got = cap_ring_pop(&out);
    try std.testing.expectEqual(@as(usize, 62_000), got);
    try std.testing.expectEqualSlices(u8, a[8_000..], out[0..2_000]);
    try std.testing.expectEqualSlices(u8, b[0..], out[2_000..62_000]);
    try std.testing.expectEqual(@as(usize, 0), cap_ring_used);
    try std.testing.expectEqual(@as(usize, 0), cap_ring_pop(out[0..1]));
    cap_ring_reset();
}

test "virtio_snd: capture admits exactly the v1 tuple and refuses beyond it by name" {
    try std.testing.expect(cap_admit(cap_format, cap_rate, cap_channels) == null);
    try std.testing.expectEqualStrings("capture format over cap (S16)", cap_admit(FMT_FLOAT, cap_rate, cap_channels).?);
    try std.testing.expectEqualStrings("capture format over cap (S16)", cap_admit(FMT_S32, cap_rate, cap_channels).?);
    try std.testing.expectEqualStrings("capture rate over cap (48kHz)", cap_admit(cap_format, RATE_44100, cap_channels).?);
    try std.testing.expectEqualStrings("capture rate over cap (48kHz)", cap_admit(cap_format, RATE_8000, cap_channels).?);
    try std.testing.expectEqualStrings("capture channels over cap (mono)", cap_admit(cap_format, cap_rate, 2).?);
    try std.testing.expectEqualStrings("capture channels over cap (mono)", cap_admit(cap_format, cap_rate, 0).?);
    // The device-side check: direction and the advertised bitmaps.
    const fmts = (@as(u64, 1) << FMT_S16) | (@as(u64, 1) << FMT_FLOAT);
    const rates = (@as(u64, 1) << RATE_48000) | (@as(u64, 1) << RATE_44100);
    try std.testing.expect(cap_admit_caps(D_INPUT, fmts, rates, 1) == null);
    try std.testing.expectEqualStrings("no input stream", cap_admit_caps(D_OUTPUT, fmts, rates, 1).?);
    try std.testing.expectEqualStrings("device lacks S16 capture", cap_admit_caps(D_INPUT, @as(u64, 1) << FMT_FLOAT, rates, 1).?);
    try std.testing.expectEqualStrings("device lacks 48kHz capture", cap_admit_caps(D_INPUT, fmts, @as(u64, 1) << RATE_44100, 1).?);
    try std.testing.expectEqualStrings("device lacks mono capture", cap_admit_caps(D_INPUT, fmts, rates, 2).?);
}

test "virtio_snd: capture refuses honestly when absent or over-cap" {
    // Device-absent: refused by name, no hang.
    snd_ready = false;
    ctrl_armed = false;
    rx_armed = false;
    defer {
        snd_ready = false;
        ctrl_armed = false;
        rx_armed = false;
    }
    try std.testing.expectEqual(@as(u32, 0xffffffff), snd_capture(cap_format, cap_rate, cap_channels, 1024));
    try std.testing.expectEqualStrings("no virtio-snd device", cap_fail);
    try std.testing.expectEqual(CapRefusal.no_device, cap_refusal);
    snd_ready = true;
    ctrl_armed = true;
    try std.testing.expectEqual(@as(u32, 0xffffffff), snd_capture(cap_format, cap_rate, cap_channels, 1024));
    try std.testing.expectEqualStrings("RX queue (3) not armed", cap_fail);
    try std.testing.expectEqual(CapRefusal.rx_unarmed, cap_refusal);
    // Armed but over-cap tuple / over-ring request: refused BEFORE any
    // control exchange — the refusals are deterministic.
    rx_armed = true;
    try std.testing.expectEqual(@as(u32, 0xffffffff), snd_capture(FMT_FLOAT, cap_rate, cap_channels, 1024));
    try std.testing.expectEqualStrings("capture format over cap (S16)", cap_fail);
    try std.testing.expectEqual(CapRefusal.over_cap, cap_refusal);
    try std.testing.expectEqual(@as(u32, 0xffffffff), snd_capture(cap_format, cap_rate, cap_channels, cap_max_frames + 1));
    try std.testing.expectEqualStrings("capture request exceeds ring", cap_fail);
    try std.testing.expectEqual(CapRefusal.over_ring, cap_refusal);
    try std.testing.expectEqual(@as(u32, 0xffffffff), snd_capture(cap_format, cap_rate, cap_channels, 0));
    try std.testing.expectEqualStrings("capture request exceeds ring", cap_fail);
    try std.testing.expectEqual(CapRefusal.over_ring, cap_refusal);
}

test "virtio_snd: RX drain deadline is unconditional — continuous completions cannot starve it (#2847)" {
    // #2847: a mic-denied VZ input stream completes every posted buffer
    // at once — len = PcmStatus + 0 sample bytes — and the repost keeps
    // `outstanding` constant, so an expiry check that only runs on the
    // no-completion path starves forever. Drive that exact device: every
    // post completes immediately, each completion costs 1 ms of wall
    // clock, and the drain must still retire on the deadline.
    const saved_freq = timer.freq;
    const saved_now = test_now_ns;
    const saved_hook = test_rx_post_hook;
    const saved_notify = snd_notify;
    const saved_notify_mult = snd_notify_mult;
    const saved_rx_notify_off = rx_queue_notify_off;
    const saved_rx_last_used = rx_last_used;
    defer {
        timer.freq = saved_freq;
        test_now_ns = saved_now;
        test_rx_post_hook = saved_hook;
        snd_notify = saved_notify;
        snd_notify_mult = saved_notify_mult;
        rx_queue_notify_off = saved_rx_notify_off;
        rx_last_used = saved_rx_last_used;
    }
    timer.freq = 24_000_000;
    test_now_ns = 0;
    test_rx_post_hook = struct {
        fn complete(slot: usize) void {
            // The wedge's device side: a posted period returns at once
            // with the status word and zero sample bytes.
            cap_bufs[slot].status.status = S_OK;
            rx_used.ring[rx_used.idx % rx_queue_size] =
                .{ .id = @intCast(slot * 3), .len = @sizeOf(PcmStatus) };
            rx_used.idx +%= 1;
            test_now_ns.? +%= std.time.ns_per_ms;
        }
    }.complete;
    var notify_sink: [64]u8 align(2) = @splat(0);
    snd_notify = @intFromPtr(&notify_sink);
    snd_notify_mult = 1;
    rx_queue_notify_off = 0;
    rx_last_used = 0;
    rx_used.idx = 0;
    rx_avail.idx = 0;
    cap_ring_reset();
    cap_submitted = 0;
    cap_completed = 0;
    cap_frames = 0;
    cap_bytes = 0;
    cap_nonzero = 0;
    cap_sum = 0x811c9dc5;
    cap_set_fail("", .none);

    for (0..cap_slots) |s| rx_post(s);
    // 100 ms deadline, ~1 ms per completion: the drain expires mid-stream
    // — completions never stop arriving and want_bytes never lands.
    cap_drain(16 * 1024, 100 * std.time.ns_per_ms);
    try std.testing.expectEqualStrings("RX drain timeout", cap_fail);
    try std.testing.expectEqual(CapRefusal.drain_timeout, cap_refusal);
    // Completions WERE being served — expiry fired anyway.
    try std.testing.expect(cap_completed > cap_slots);
    try std.testing.expectEqual(@as(u64, 0), cap_bytes);
    cap_ring_reset();
}

test "virtio_snd: a ctl exchange that expired its poll budget names a timeout, not a refusal (#2847)" {
    const saved_stage = ctl_fail_stage;
    defer ctl_fail_stage = saved_stage;
    ctl_fail_stage = 3; // the used-ring poll expired
    try std.testing.expectEqual(CapRefusal.ctl_timeout, ctl_refusal_class());
    ctl_fail_stage = 1; // unarmed
    try std.testing.expectEqual(CapRefusal.ctl_refused, ctl_refusal_class());
    ctl_fail_stage = 4; // bad used id
    try std.testing.expectEqual(CapRefusal.ctl_refused, ctl_refusal_class());
}

test "virtio_snd: a suspect register path refuses everywhere — status latched, rearm refused, recovery skipped (#2847)" {
    const saved_suspect = snd_regs_suspect;
    const saved_stop = cap_stop_status;
    const saved_release = cap_release_status;
    const saved_recovered = cap_recovered;
    defer {
        snd_regs_suspect = saved_suspect;
        cap_stop_status = saved_stop;
        cap_release_status = saved_release;
        cap_recovered = saved_recovered;
    }
    // START-expired wedge: the recovery reset would stall on the wedged
    // device's registers — no rearm runs, cap_recovered stays false, and
    // the register accessors refuse honestly.
    snd_regs_suspect = true;
    cap_stop_status = 0xffffffff;
    cap_release_status = 0xffffffff;
    cap_recovered = false;
    snd_capture_recover();
    try std.testing.expect(!cap_recovered);
    try std.testing.expect(!snd_rearm());
    // A live-read would stall inside the load; the suspect path must
    // answer the latched status without touching the device.
    snd_common = 1;
    snd_status_latched = 0x0f;
    try std.testing.expectEqual(@as(u8, 0x0f), snd_status());
    snd_common = 0; // restore before the healthy rearm path below
    snd_status_latched = 0xff;
    snd_devcfg = 1;
    defer snd_devcfg = 0;
    try std.testing.expectEqual(@as(u32, 0), snd_read32(0));
    // Drain-time wedge (registers healthy): the rearm attempts recovery —
    // snd_common == 0 in tests, so the attempt is what cap_recovered names.
    snd_regs_suspect = false;
    snd_capture_recover();
    try std.testing.expect(cap_recovered);
    // Clean epilogue: nothing to recover.
    cap_stop_status = S_OK;
    cap_release_status = S_OK;
    cap_recovered = false;
    snd_capture_recover();
    try std.testing.expect(!cap_recovered);
}

test "virtio_snd: cap info reports the observed INPUT verdict with the v1 tuple" {
    // M118c (#2481): snd_cap_info is the slot-91 report — the last observed
    // stream-0 topology held to the v1 tuple, never a device exchange.
    snd_ready = false;
    ctrl_armed = false;
    rx_armed = false;
    const saved_dir = beep_obs_dir;
    const saved_formats = beep_obs_formats;
    const saved_rates = beep_obs_rates;
    const saved_ch_min = beep_obs_ch_min;
    defer {
        snd_ready = false;
        ctrl_armed = false;
        rx_armed = false;
        beep_obs_dir = saved_dir;
        beep_obs_formats = saved_formats;
        beep_obs_rates = saved_rates;
        beep_obs_ch_min = saved_ch_min;
    }
    // No device: not ready, the sentinel tuple.
    var info = snd_cap_info();
    try std.testing.expectEqual(@as(u32, 0), info.ready);
    try std.testing.expectEqual(@as(u8, 0xff), info.format);
    try std.testing.expectEqual(@as(u8, 0xff), info.rate);
    try std.testing.expectEqual(@as(u8, 0), info.channels);
    try std.testing.expectEqual(@as(u32, cap_period_bytes), info.period_bytes);
    try std.testing.expectEqual(@as(u32, @intCast(cap_ring_bytes)), info.ring_bytes);
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(AudioCapInfo));
    // Armed + stream 0 last observed INPUT with the v1 tuple: ready, the
    // cap constants reported.
    snd_ready = true;
    ctrl_armed = true;
    rx_armed = true;
    beep_obs_dir = D_INPUT;
    beep_obs_formats = (@as(u64, 1) << FMT_S16) | (@as(u64, 1) << FMT_FLOAT);
    beep_obs_rates = @as(u64, 1) << RATE_48000;
    beep_obs_ch_min = 1;
    info = snd_cap_info();
    try std.testing.expectEqual(@as(u32, 1), info.ready);
    try std.testing.expectEqual(cap_format, info.format);
    try std.testing.expectEqual(cap_rate, info.rate);
    try std.testing.expectEqual(cap_channels, info.channels);
    // Stream 0 observed OUTPUT (--sound only): ready=0 honestly.
    beep_obs_dir = D_OUTPUT;
    info = snd_cap_info();
    try std.testing.expectEqual(@as(u32, 0), info.ready);
    // Armed but never probed (a device whose capture self-test skipped):
    // the 0xff observation is not an input — ready=0.
    beep_obs_dir = 0xff;
    info = snd_cap_info();
    try std.testing.expectEqual(@as(u32, 0), info.ready);
}

test "virtio_snd: capture DMA layout and cap geometry are bounded" {
    try std.testing.expectEqual(@as(u16, 4), rx_queue_size);
    try std.testing.expectEqual(@as(usize, 2176), @sizeOf(CapBuf));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(CapBuf, "data"));
    try std.testing.expectEqual(@as(usize, 2112), @offsetOf(CapBuf, "status"));
    try std.testing.expectEqual(@as(u32, cap_ring_bytes / 2), cap_max_frames);
    try std.testing.expect(cap_selftest_frames * cap_frame_bytes <= cap_ring_bytes);
    try std.testing.expect(cap_slots * 3 <= pcm.tx_descriptors);
}

test "virtio_snd: spec shapes — config layout, queue size, DID constants" {
    // The device-config counts are le32 at offsets 0/4/8 (virtio-snd
    // §5.14.4) — the u8-at-0/1/2 first attempt read all zeros live.
    try std.testing.expectEqual(@as(u32, 0), cfg_jacks_off);
    try std.testing.expectEqual(@as(u32, 4), cfg_streams_off);
    try std.testing.expectEqual(@as(u32, 8), cfg_chmaps_off);
    try std.testing.expectEqual(@as(usize, 12), cfg_bytes);
    try std.testing.expectEqual(@as(u16, 4), queue_size);
    // The modern DID scheme: 0x1040 + virtio device type 25.
    try std.testing.expectEqual(@as(u32, 0x1059), 0x1040 + 25);
    // The virtio-1.3 control codes — OBSERVED live on VZ: a 1.2-style
    // PCM_INFO (3) was answered with BAD_MSG 0x8001, pinning the set.
    try std.testing.expectEqual(@as(u32, 0x0100), R_PCM_INFO);
    try std.testing.expectEqual(@as(u32, 0x0101), R_PCM_SET_PARAMS);
    try std.testing.expectEqual(@as(u32, 0x0102), R_PCM_PREPARE);
    try std.testing.expectEqual(@as(u32, 0x0104), R_PCM_START);
    try std.testing.expectEqual(@as(u32, 0x0105), R_PCM_STOP);
    try std.testing.expectEqual(@as(u32, 0x8000), S_OK);
}

test "virtio_snd: unarmed transport reports honestly" {
    snd_common = 0;
    snd_ready = false;
    snd_fail = "";
    ctrl_armed = false;
    tx_armed = false;
    try std.testing.expectEqual(@as(u8, 0xff), snd_status());
    try std.testing.expect(!snd_rearm()); // no common cfg — refused, not a hang
    // No config capture — the counts are never guessed.
    try std.testing.expect(snd_cfg() == null);
    try std.testing.expectEqual(@as(u32, 0), snd_jacks);
    try std.testing.expectEqual(@as(u32, 0), snd_streams);
    try std.testing.expectEqual(@as(u32, 0), snd_chmaps);
    // A2: control exchange + probe + beep all refuse honestly when the
    // transport is not armed (no device, no hang).
    try std.testing.expectEqual(@as(u32, 0xffffffff), snd_pcm_probe());
    try std.testing.expectEqual(@as(u32, 0xffffffff), snd_beep(440, 100));
    try std.testing.expectEqualStrings("transport not armed", beep_fail);
    // A4 (claim 3206): the boot chime refuses the same way with no device
    // (the default VM's boot is byte-identical — no hang, honest reason).
    try std.testing.expectEqual(@as(u32, 0xffffffff), snd_chime());
    try std.testing.expectEqualStrings("transport not armed", beep_fail);
}

test "virtio_snd: stream-state setters are bounded and honest" {
    // The setters work without a device (pure kernel state) and reject
    // out-of-range values — no silent clamping.
    stream_volume = 100;
    stream_muted = false;
    try std.testing.expectEqual(@as(u32, 100), snd_set_volume(100));
    try std.testing.expectEqual(@as(u32, 0), snd_set_volume(0));
    try std.testing.expectEqual(@as(u32, 0xffffffff), snd_set_volume(101)); // bounded
    try std.testing.expectEqual(@as(u32, 100), snd_set_volume(100));
    try std.testing.expectEqual(@as(u32, 0), snd_set_mute(true));
    try std.testing.expect(stream_muted);
    try std.testing.expectEqual(@as(u32, 0), snd_set_mute(false));
    try std.testing.expect(!stream_muted);
    stream_volume = 100;
    stream_muted = false;
}

test "virtio_snd: apply_stream_gain scales in place, zeroes when muted, and is bit-exact at 100%" {
    // S16 stereo, 2 frames (4 samples). Full volume = untouched bytes.
    beep_format = FMT_S16;
    beep_channels = 2;
    stream_volume = 100;
    stream_muted = false;
    const orig = [_]i16{ 20000, -16000, 8000, -4000 };
    @memcpy(beep_buf[4..][0..8], std.mem.sliceAsBytes(orig[0..]));
    apply_stream_gain(8);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(orig[0..]), beep_buf[4..][0..8]);
    // 50% volume halves each sample (truncation toward zero).
    stream_volume = 50;
    stream_muted = false;
    @memcpy(beep_buf[4..][0..8], std.mem.sliceAsBytes(orig[0..]));
    apply_stream_gain(8);
    const half = [_]i16{ 10000, -8000, 4000, -2000 };
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(half[0..]), beep_buf[4..][0..8]);
    // Muted zeroes the samples (the stream still drains — accounting exact).
    stream_muted = true;
    @memcpy(beep_buf[4..][0..8], std.mem.sliceAsBytes(orig[0..]));
    apply_stream_gain(8);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, beep_buf[4..][0..8]);
    // FLOAT format: 50% halves the f32.
    beep_format = FMT_FLOAT;
    beep_channels = 1;
    stream_volume = 50;
    stream_muted = false;
    const f: f32 = 0.5;
    @memcpy(beep_buf[4..][0..4], std.mem.asBytes(&f));
    apply_stream_gain(4);
    const got: f32 = @bitCast(std.mem.readInt(u32, beep_buf[4..][0..4], .little));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), got, 0.0001);
    beep_format = 0xff;
    beep_channels = 0;
    stream_volume = 100;
    stream_muted = false;
}

test "virtio_snd: format/rate/channel math is deterministic" {
    // S16 mono at 48 kHz: 2 B/frame.
    try std.testing.expectEqual(@as(u32, 2), snd_fmt_bytes(FMT_S16));
    try std.testing.expectEqual(@as(u32, 4), snd_fmt_bytes(FMT_S32));
    try std.testing.expectEqual(@as(u32, 4), snd_fmt_bytes(FMT_FLOAT));
    try std.testing.expectEqual(@as(u32, 0), snd_fmt_bytes(0xff));
    try std.testing.expectEqual(@as(u32, 48000), snd_rate_hz(RATE_48000));
    try std.testing.expectEqual(@as(u32, 44100), snd_rate_hz(RATE_44100));
    try std.testing.expectEqual(@as(u32, 0), snd_rate_hz(0xff));
    // 300 ms at 48 kHz = 14400 frames; at 8 kHz = 2400.
    try std.testing.expectEqual(@as(u32, 14400), frame_count(RATE_48000, 300));
    try std.testing.expectEqual(@as(u32, 2400), frame_count(RATE_8000, 300));
    // frame_count never returns 0 for a valid rate+ms.
    try std.testing.expect(frame_count(RATE_8000, 1) >= 1);
}

test "virtio_snd: pick_params prefers FLOAT then S16/S32, stereo when offered" {
    // Simulate a VZ-like device: FLOAT + S16 + S32, 44.1/48k, 1-2 ch.
    beep_obs_formats = (@as(u64, 1) << FMT_FLOAT) | (@as(u64, 1) << FMT_S16) | (@as(u64, 1) << FMT_S32);
    beep_obs_rates = (@as(u64, 1) << RATE_48000) | (@as(u64, 1) << RATE_44100);
    beep_obs_ch_min = 1;
    beep_obs_ch_max = 2;
    const p = pick_params();
    try std.testing.expectEqual(FMT_FLOAT, p.format);
    try std.testing.expectEqual(RATE_48000, p.rate);
    try std.testing.expectEqual(@as(u8, 2), p.channels);
    // S16-only device: falls back to S16.
    beep_obs_formats = @as(u64, 1) << FMT_S16;
    const p2 = pick_params();
    try std.testing.expectEqual(FMT_S16, p2.format);
    try std.testing.expectEqual(@as(u8, 2), p2.channels);
    // Mono-only device: 1 channel.
    beep_obs_ch_max = 1;
    const p3 = pick_params();
    try std.testing.expectEqual(@as(u8, 1), p3.channels);
    // Nothing supported: refused by the caller (0xff markers here).
    beep_obs_formats = 0;
    const p4 = pick_params();
    try std.testing.expectEqual(@as(u8, 0xff), p4.format);
}

test "virtio_snd: sine synthesis produces a bounded, non-silent buffer" {
    // Synthesize 480 frames of 440 Hz mono S16 at 48 kHz into beep_buf
    // (bypassing the device path — the synth is pure).
    const frames: u32 = 480;
    const channels: u8 = 1;
    beep_buf = @splat(0);
    synth_sine(440, frames, FMT_S16, channels, RATE_48000, 0);
    // First sample should be near zero (sin 0 = 0) ...
    const s0 = std.mem.readInt(i16, beep_buf[4..][0..2], .little);
    try std.testing.expect(@abs(s0) < 2);
    // ... but the buffer is not silent: some sample exceeds half scale.
    var loud: bool = false;
    var i: usize = 4;
    while (i < @as(usize, frames) * 2 + 4) : (i += 2) {
        const v = std.mem.readInt(i16, beep_buf[i..][0..2], .little);
        if (@abs(@as(i32, v)) > 8000) loud = true;
    }
    try std.testing.expect(loud);
    // Total bytes = 4 (xfer hdr) + frames*2; the period buffer fits it.
    try std.testing.expectEqual(@as(usize, 4 + frames * 2), @as(usize, 4) + frames * 2);
    try std.testing.expect(beep_buf_size >= 4 + frames * 2);
    // Phase continuity: the first sample of a later period is NOT forced
    // to zero — it continues the sine (a period boundary glitch check).
    beep_buf = @splat(0);
    synth_sine(440, 1, FMT_S16, channels, RATE_48000, 100);
    const sc = std.mem.readInt(i16, beep_buf[4..][0..2], .little);
    try std.testing.expect(@abs(@as(i32, sc)) > 5000); // 100 frames in = mid-cycle
}
