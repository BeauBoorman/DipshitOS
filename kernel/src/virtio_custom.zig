//! VirelaiOS custom-virtio guest driver (macOS 27 capability-audit step
//! 4/5, claims 0828/4374/9492/9737/4837): the guest driver for the spike
//! device the runner attaches as `VZCustomVirtioDeviceConfiguration`
//! (`zig build spike-virtio`, claim 5844). To the guest it is a modern
//! virtio-pci device VID 0x1af4 / DID 0x1082 (deviceID 0x42) with two
//! virtqueues, class 0x00/0x00, on bus 0 — found through the MCFG ECAM
//! base exactly like the console (DID 0x1043, claim 0013) and the block
//! device (DID 0x1042, claim 6420).
//!
//! Two phases, split by the ExitBootServices boundary (the claim-0013
//! discipline):
//!
//!   1. DISCOVERY (PRE-EXIT, `probe`): config-space reads only — find
//!      DID 0x1082 and resolve the common/notify capability addresses +
//!      the transport BAR base. VZ's firmware BAR assignment moves between
//!      boots (observed: the claim-5844 boot placed the transport BAR at
//!      0x50001000, a later boot ABOVE the 4 GiB blanket at 0x100020000 —
//!      where the identity map's blanket ends and the post-MMU access
//!      faults). main.zig maps the discovered window into the identity map
//!      so post-exit MMIO reaches the device either way.
//!   2. PROGRAMMING + EXPERIMENT (POST-MMU, `init` + the main.zig spike
//!      orchestration): reset -> ACKNOWLEDGE|DRIVER -> negotiate features
//!      (VERSION_1 +, when the device offers them, ANY_LAYOUT +
//!      NOTIFICATION_DATA) -> FEATURES_OK -> arm BOTH virtqueues (split
//!      rings, size 32) -> DRIVER_OK, then run the transport API and
//!      observe the used ring + IRQ.
//!
//! The transport API (claims 4374/9492/9737/4837 — the claim-0828
//! exchange API grown into a real transport):
//!
//!   * `submit_ex(queue, scatter, reply_buf, reply_first)` allocates a
//!     descriptor chain from the ring's free list (a proper allocator:
//!     many elements can be in flight concurrently, and freed chains are
//!     recycled), posts one avail entry, and kicks. Returns the head
//!     descriptor index — the element handle.
//!   * `wait(queue, handle, budget, reply_buf)` scans the used ring and
//!     matches on the used entry's `id` (the head index), so completions
//!     may arrive in any order; returns the used length (the host's
//!     writtenByteCount), clamped for the caller by `reply_len()`.
//!   * `free_chain(queue, handle)` returns the chain's descriptors to the
//!     free list.
//! * `cvlog_puts(line)` is the guest log path: one element on queue 1
//!     carrying the line, the host echoes `CUSTOM-VIRTIO-LOG: <line>` to
//!     its stdout and replies `ACK:<len>`; returns true when the ack
//!     verifies.
//! * The claim-3141 HOST-push echo (queue 2, present only under the
//!   runner's `--cvc-echo`, which attaches a third virtqueue): `arm_push()`
//!   pre-arms ONE empty device-write receive buffer and kicks; the HOST app
//!   dequeues it whenever it chooses, writes the request, and returns it;
//!   `wait_any_push()` observes the completion; the driver then posts the
//!   reply through the normal submit_ex/wait path on queue 2. The SDK has
//!   NO host-side enqueue — this pre-arm/dequeue/write/return pattern is
//!   the only host→guest data path (virtio-net-RX shaped), discovered from
//!   the Xcode 27 Virtualization.framework ObjC headers.
//!
//! * The claim-9588 INPUT channel (queue 3, present only under the runner's
//!   `--via-virtio`, which attaches FOUR virtqueues): keyboard injection
//!   without CGEvent/NSEvent synthesis (issues #179/#151). Same host-push
//!   pattern at pool scale: `arm_input_pool()` pre-arms EIGHT device-write
//!   receive buffers; the host dequeues one per injected key report, writes
//!   receive buffers; the host dequeues one per injected input message,
//!   writes
//!   a fixed 16-byte message ([kind u8][flags u8][len u16le][payload]),
//!   kind 1 = raw 8-byte HID keyboard boot report, kind 2 = raw 5-byte
//!   absolute-pointer report [buttons, x_lo, x_hi, y_lo, y_hi] (claim 9367),
//!   and returns it;
//!   `poll_input()` — called from the shell idle loop's RX seam in main.zig
//!   — validates each completion, hands kind-1 payloads to the
//!   `on_input_report` hook (main.zig wires it to input.decode_keyboard_
//!   report so injected keys are ordinary keys downstream: event FIFO,
//!   compose, keymap, `input` counters) and kind-2 payloads to the
//!   `on_pointer_report` hook (wired to input.decode_pointer_report — the
//!   exact path XHCI pointer reports take, so click-to-focus works with no
//!   USB device attached), and replenishes the buffer. Wire
//!   format is normative in docs/hardware-contract.md.
//!
//! Feature negotiation (claim 9737): the driver reads the full 64-bit
//! device-features word, accepts VIRTIO_F_VERSION_1 (bit 32) always and
//! VIRTIO_F_ANY_LAYOUT (bit 27) / VIRTIO_F_NOTIFICATION_DATA (bit 38)
//! when the device offers them, then MUST use the negotiated behavior:
//! 32-bit notification-data kicks (`vqn << 16 | next_off`, Virtio 1.3
//! §4.1.5.2.1) when NOTIFICATION_DATA is on, and (when ANY_LAYOUT is on)
//! the big-payload exchange posts its device-write reply descriptor FIRST
//! in the chain — any layout per §2.7.6 — to prove the device accepts it.
//! `device_features`/`guest_features`/`has_*` let main.zig report exactly
//! what VZ offers and what was accepted (honest either way).
//!
//! Multi-descriptor payloads (claim 9492): `submit_ex`'s scatter list
//! becomes N device-read descriptors + 1 device-write reply descriptor in
//! one chain; main.zig posts a 12,340-byte payload (0x3034, deliberately
//! not a page multiple) as three descriptors (4 KiB + 4 KiB + 4148 B) and
//! the host reassembles the spans — testing the VZVirtioQueueElement read
//! span semantics.
//!
//! No device -> silent no-op: the DID probe finds nothing and every
//! existing gate is byte-identical. No libc, no POSIX, no allocation.
//!
//! Cache correctness mirrors the console/blk transports: clean the
//! D-cache over driver-written rings + buffers before the kick,
//! invalidate the used ring before polling. On VZ (coherent emulation)
//! these are harmless defensive code (claim 0016).

const std = @import("std");
const builtin = @import("builtin");
const mmio = @import("mmio.zig");
const mmu = @import("mmu.zig");
const pci = @import("pci.zig");
const evidence = @import("evidence.zig");
const virtio_gpu = @import("virtio_gpu.zig");
const spinlock = @import("spinlock.zig"); // #990 (claim #997): the console tee's TX lock
const klog = @import("klog.zig"); // snap completion receipt (run-03 serialization anchor)

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

/// The spike device's PCI device ID (claim 5844: DID = 0x1040 + deviceID
/// 0x42, ADD not OR — an OR collides with virtio-blk's 0x1042).
pub const custom_did: u32 = 0x1082;
/// Virtio device ID (the DID's low byte).
pub const custom_device_id: u32 = 0x42;

/// Split-ring size per queue: 32 (power of two, Virtio 1.3 §4.1.4.3).
/// Large enough for many concurrent in-flight elements AND the claim-9492
/// four-descriptor chain (3 read + 1 write).
pub const queue_size: u16 = 32;
/// Queues armed by `init`: 0 = the exchange/transport queue, 1 = the guest
/// log transport (claims 4374/4837). The host side attaches this many
/// queues (`virtioQueueCount = 2`) unless the runner runs the claim-3141
/// push spike (`--cvc-echo`), which attaches ONE more.
pub const queue_count: u16 = 2;
/// The optional push-echo queue index (present only under `--cvc-echo`;
/// the host exposes it as a third virtqueue). Queue-count IS the capability
/// signal: the driver probes queue 2's size through the common config and
/// skips the whole push experiment when it reads 0 — no feature-bit mapping
/// guessed from session notes.
pub const push_qidx: u16 = 2;
/// The claim-9588 input-queue index (present only under `--via-virtio`,
/// which attaches FOUR virtqueues; contiguous queues mean --via-virtio
/// implies the push-echo shape too).
pub const input_qidx: u16 = 3;
/// The claim-0680 snapshot queue index (present only under the runner's
/// `--cvc-snap`, which attaches FIVE virtqueues; --cvc-snap therefore
/// implies the full four-queue shape). Queue-count IS the capability
/// signal, unchanged rule.
pub const snap_qidx: u16 = 4;
/// The M34 host-file-channel queue index (present only under the runner's
/// `--cvc-file <dir>`, which attaches SIX virtqueues; --cvc-file therefore
/// implies the full five-queue shape below it — the deepest flag rule,
/// unchanged). The file channel is a macOS folder served over this queue
/// (issues #735/#736; guest client kernel/src/virtio_file.zig).
pub const file_qidx: u16 = 5;
/// Probe up to the file-channel queue (the deepest optional queue).
pub const max_queue_probe: u16 = file_qidx + 1;
/// The pre-armed push receive buffer: capacity (one device-write descriptor)
/// and the exact request size the host writes (`"CVC-PING-0x42"`).
pub const push_buf_len: usize = 16;
pub const push_req_len: usize = 13;
/// Queues actually armed by `init` (2 on every device; 3 under --cvc-echo;
/// 4 under --via-virtio).
pub var armed_queues: u16 = 0;
/// True when init armed the optional push queue (index `push_qidx`).
pub var has_push_queue: bool = false;
/// True when init armed the optional input queue (index `input_qidx`).
pub var has_input_queue: bool = false;
/// True when init armed the optional snapshot queue (index `snap_qidx`).
pub var has_snap_queue: bool = false;
/// True when init armed the optional file-channel queue (index `file_qidx`).
pub var has_file_queue: bool = false;

/// Descriptor flags (Virtio 1.3 §2.7.6).
const vq_next: u16 = 0x1; // VIRTQ_DESC_F_NEXT: more descriptors follow
const vq_write: u16 = 0x2; // VIRTQ_DESC_F_WRITE: device writes this buffer

/// Feature bits (Virtio 1.3 §6): VIRTIO_F_ANY_LAYOUT = 27 (device accepts
/// arbitrary descriptor layouts), VIRTIO_F_VERSION_1 = 32 (modern device),
/// VIRTIO_F_NOTIFICATION_DATA = 38 (driver writes a 32-bit notification
/// datum instead of the 16-bit queue index).
pub const vq_feature_any_layout: u64 = @as(u64, 1) << 27;
pub const vq_feature_version_1: u64 = @as(u64, 1) << 32;
pub const vq_feature_notification_data: u64 = @as(u64, 1) << 38;

/// The known 16-byte payload: printable ASCII the host delegate must
/// dequeue verbatim. The class-B gate greps runner stdout for this string.
pub const payload_len: usize = 16;
/// Payload bytes as a raw [16:0]u8 VALUE (not a slice/pointer): the
/// flat kernel loader does not relocate, so any comptime-folded pointer
/// into .rodata holds a link-time (image-relative) address and the
/// descriptor would point at guest RAM near 0 (observed d0.addr=0xdbb2
/// vs the loaded base 0x7e49d000). init_payload() copies these bytes
/// into the BSS `payload`, whose address is runtime-correct.
const payload_bytes = "VIRELAIOS-CV0x42".*;
/// The BSS payload buffer the driver hands to the device (runtime
/// address; filled by init_payload before the first submit).
pub var payload: [payload_len]u8 align(16) = undefined;

/// Copy the known payload into the BSS buffer (PC-relative source, BSS
/// destination — no comptime-folded pointers, no relocation dependency).
pub fn init_payload() void {
    @memcpy(&payload, &payload_bytes);
}

/// The largest reply buffer the small-exchange API is designed for.
pub const reply_cap: usize = 64;

/// The claim-9492 big payload: 12,340 bytes (0x3034), deliberately not a
/// page multiple, split across three device-read descriptors.
pub const big_payload_len: usize = 12340;

/// Size of the transport BAR window mapped into the identity map (VZ
/// exposes 64 KiB BARs, same as the console/blk — claim 0013/6420).
pub const bar_window_len: u64 = 0x10000;

// ---------------------------------------------------------------------------
// Discovery state (PRE-EXIT; read by main.zig for the identity-map window)
// ---------------------------------------------------------------------------

/// Custom device PCI device number, or 32 (sentinel) when absent.
pub var cv_dev: u32 = 32;
/// Common-config struct address (BAR + cap offset), pre-exit resolved.
pub var cv_common: u64 = 0;
/// Notify region base (BAR + cap offset), pre-exit resolved.
pub var cv_notify: u64 = 0;
/// notify_off_multiplier (0 when the cap lacks it).
pub var cv_notify_mult: u32 = 0;
/// Transport BAR base holding the common cfg (the identity-map window).
pub var cv_bar: u64 = 0;
/// All six BAR values read during the pre-exit probe (diagnostic).
pub var cv_bars: [6]u64 = @splat(0);
/// Capability-pointer value read during the pre-exit probe (diagnostic).
pub var cv_cap_ptr: u32 = 0;
/// Per-capability decode: id, next, cfg_type, bar, offset (diagnostic).
pub const CapDecode = struct { id: u32, next: u32, cfg_type: u32, bar: u32, off: u32, head: u32, base: u32 };
pub var cv_caps: [8]CapDecode = @as([8]CapDecode, @splat(@as(CapDecode, .{ .id = 0, .next = 0, .cfg_type = 0, .bar = 0, .off = 0, .head = 0, .base = 0 })));
pub var cv_cap_count: usize = 0;

/// PRE-EXIT probe (config-space reads only — the claim-0013 discipline):
/// find DID 0x1082 on bus 0 and resolve the common/notify capability
/// addresses + the transport BAR base. Returns true when the device is
/// present; main.zig then maps `device_window()` into the identity map.
pub fn probe() bool {
    if (pci.pci_ecam == 0) return false;

    var found_dev: u32 = 32; // sentinel: not found
    var dev: u32 = 0;
    while (dev < 32) : (dev += 1) {
        const id = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0);
        if ((id & 0xffff) == 0xffff) continue;
        const did = id >> 16;
        if (did != custom_did) continue;
        const cls = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 8) >> 8;
        if (cls != 0x000000) continue; // class 0x00/0x00 — the spike's identity
        found_dev = dev;
        break;
    }
    if (found_dev == 32) return false;
    cv_dev = found_dev;

    // BAR bases (memory BARs; 64-bit pairs merged).
    var bar_base: [6]u64 = @splat(0);
    var bi: usize = 0;
    while (bi < 6) : (bi += 1) {
        const low = pci.pci_read32(pci.pci_ecam, 0, found_dev, 0, 0x10 + @as(u32, @intCast(bi)) * 4);
        cv_bars[bi] = low;
        if ((low & 1) != 0) continue; // I/O space — ignored
        const base: u64 = low & ~@as(u32, 0xf);
        bar_base[bi] = base;
        if (((low >> 1) & 0x3) == 2 and bi + 1 < 6) { // 64-bit BAR
            const high = pci.pci_read32(pci.pci_ecam, 0, found_dev, 0, 0x10 + @as(u32, @intCast(bi + 1)) * 4);
            bar_base[bi] |= @as(u64, high) << 32;
            bi += 1;
        }
    }

    // Walk the capability list for the virtio vendor-specific caps (ID
    // 0x09): each carries cfg_type + bar + offset; the notify cap adds a
    // multiplier. Aligned u32 reads only (claim 0013: byte reads of config
    // space return garbage on VZ).
    cv_cap_ptr = pci.pci_read32(pci.pci_ecam, 0, found_dev, 0, 0x34) & 0xff;
    const cap_ptr = cv_cap_ptr;
    evidence.dump_str("CVPROBE dev=");
    evidence.dump_hex(found_dev);
    evidence.dump_str(" b0=");
    evidence.dump_hex(cv_bars[0]);
    evidence.dump_str(" b2=");
    evidence.dump_hex(cv_bars[2]);
    evidence.dump_str(" cp=");
    evidence.dump_hex(cv_cap_ptr);
    evidence.dump_str("\n");
    var common_bar: u32 = 0;
    var common_off: u32 = 0;
    var notify_bar: u32 = 0;
    var notify_off: u32 = 0;
    var notify_mult: u32 = 0;
    var found_common = false;
    var found_notify = false;
    var c: u32 = cap_ptr;
    var caps: usize = 0;
    cv_cap_count = 0;
    while (c != 0 and c < 0x100 and (c & 3) == 0 and caps < 16) : (caps += 1) {
        const head = pci.pci_read32(pci.pci_ecam, 0, found_dev, 0, c);
        const id = head & 0xff;
        const next = (head >> 8) & 0xff;
        if (id == 0x09) {
            const cfg_type = (head >> 24) & 0xff;
            const bar = pci.pci_read32(pci.pci_ecam, 0, found_dev, 0, c + 4) & 0xff;
            const off = pci.pci_read32(pci.pci_ecam, 0, found_dev, 0, c + 8);
            if (cv_cap_count < cv_caps.len) {
                cv_caps[cv_cap_count] = .{ .id = id, .next = next, .cfg_type = cfg_type, .bar = bar, .off = off, .head = head, .base = c };
                cv_cap_count += 1;
            }
            evidence.dump_str("CVPROBE cap @");
            evidence.dump_hex(c);
            evidence.dump_str(" head=");
            evidence.dump_hex(head);
            evidence.dump_str(" t=");
            evidence.dump_hex(cfg_type);
            evidence.dump_str(" bar=");
            evidence.dump_hex(bar);
            evidence.dump_str(" off=");
            evidence.dump_hex(off);
            evidence.dump_str("\n");
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
    cv_common = bar_base[common_bar] + common_off;
    cv_notify = bar_base[notify_bar] + notify_off;
    cv_notify_mult = notify_mult;
    cv_bar = bar_base[common_bar];
    return true;
}

/// The identity-map Device window covering the transport BAR (added by
/// main.zig next to the console/blk windows; below the blanket it is
/// skipped by mmu.zig, above it the window keeps the device reachable
/// post-MMU).
pub fn device_window() mmu.DeviceWindow {
    return .{ .base = cv_bar, .len = bar_window_len };
}

// ---------------------------------------------------------------------------
// Per-queue transport state (POST-exit; read by main.zig's report)
// ---------------------------------------------------------------------------

/// One armed split virtqueue (claim 4374): its own descriptor table, avail
/// ring, used ring, free-list allocator, and notification offset.
pub const VirtqRing = struct {
    desc: [queue_size]VirtqDesc align(16) = undefined,
    avail: VirtqAvail align(2) = undefined,
    used: VirtqUsed align(4) = undefined,
    /// Free-list stack of unused descriptor indices (LIFO — recycled).
    free: [queue_size]u16 = undefined,
    free_count: u16 = 0,
    /// How many used-ring entries this driver has consumed.
    last_used: u16 = 0,
    /// queue_notify_off (common-cfg 0x1e) for this queue.
    notify_off: u16 = 0,
    armed: bool = false,
};

/// The armed rings, one per queue (indexed by queue number; slot
/// `push_qidx` is used only when the device exposes the third queue).
pub var cv_rings: [max_queue_probe]VirtqRing = undefined;
/// Transport initialized (DRIVER_OK set) and queues armed.
pub var cv_ready: bool = false;

/// Full 64-bit device-features word read during negotiation (claim 9737).
pub var device_features: u64 = 0;
/// The features accepted (written to the guest-features registers).
pub var guest_features: u64 = 0;
/// True when VIRTIO_F_ANY_LAYOUT (bit 27) was negotiated.
pub var has_any_layout: bool = false;
/// True when VIRTIO_F_NOTIFICATION_DATA (bit 38) was negotiated — kicks
/// then use the 32-bit notification-datum format.
pub var has_notification_data: bool = false;

// ---------------------------------------------------------------------------
// Exchange observation (claims 0828 + 4374/9492/9737/4837)
// ---------------------------------------------------------------------------

/// Bytes the most recent exchange's used-ring entry reports (the host's
/// reply length — the framework's writtenByteCount; 0 when the host wrote
/// nothing).
pub var used_len: u32 = 0;
/// Runtime-built scatter staging (the claim-0015/cv_log_lines class): an
/// ANONYMOUS array literal of slices (`&.{a[0..], b[0..]}`) const-folds
/// into .rodata with baked link-time pointers, and the flat kernel loader
/// does not relocate — the device would read image-relative GPAs
/// (observed d0.addr=0xc37f0 vs the loaded base 0x7e49d000). Building
/// the scatter array here in BSS at runtime keeps every element's address
/// PC-relative-correct. Sized for the 3-part claim-9492 payload.
pub var cv_scatter: [4][]const u8 = undefined;
/// The most recent exchange's reply buffer length (set by `wait`; the
/// clamp bound for `reply_len`).
var current_reply_len: usize = 0;

/// Bytes of the host's reply to read back: the used-ring length (the
/// host's writtenByteCount), clamped to the exchange's reply buffer. The
/// reply read is length-driven — exactly this many bytes are valid,
/// whatever size descriptor was posted or bytes the host chose to write.
pub fn reply_len() usize {
    return @min(@as(usize, used_len), current_reply_len);
}
/// Non-timer IRQs acked since `reset_irq_observation` (recorded by
/// main.zig's irq_dispatch, IRQ context — increments only, console-free).
/// Issue #810-family audit (claim 7339): PER-CORE, defensively — SPIs are
/// IROUTER-pinned to PE 0 today (gic.arm_spi_window), so core 0 is the
/// only writer, but the irq_dispatch path is reachable on every core and a
/// shared counter would silently lose increments if SPI routing ever
/// becomes any-core. Core count literal (4), the gic/exceptions idiom.
pub const cpu_cores: usize = 4;
pub var irq_count: [cpu_cores]u32 = @as([cpu_cores]u32, @splat(@as(u32, 0)));
/// First non-timer INTID acked per core (0xffffffff = none yet).
pub var irq_first: [cpu_cores]u32 = @as([cpu_cores]u32, @splat(@as(u32, 0xffffffff)));

/// This core's index into the per-core counters (MPIDR_EL1.Aff0; 0 on
/// host tests / non-aarch64 — the exceptions.resume_core idiom).
fn core_index() usize {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return 0;
    var mpidr: u64 = 0;
    asm volatile ("mrs %[v], mpidr_el1"
        : [v] "=r" (mpidr),
    );
    const aff0: usize = @intCast(mpidr & 0xff);
    return if (aff0 < cpu_cores) aff0 else 0;
}

/// Called from irq_dispatch for every non-spurious, non-timer INTID.
/// MUST stay console-free (runs in IRQ context with a frame on the stack).
pub fn note_irq(intid: u32) void {
    const cidx = core_index(); // claim 7339: per-core counters
    irq_count[cidx] += 1;
    if (irq_first[cidx] == 0xffffffff) irq_first[cidx] = intid;
}

/// Reset the observation window (call right before the first kick so only
/// IRQs delivered after the first element was submitted are attributed).
pub fn reset_irq_observation() void {
    for (&irq_count) |*v| v.* = 0;
    for (&irq_first) |*v| v.* = 0xffffffff;
}

// ---------------------------------------------------------------------------
// Common-cfg register access (natural size, the console's exact pattern)
// ---------------------------------------------------------------------------

// Natural-size accesses only (mmio_read8/16/32, not a widened 32-bit
// pattern): the common cfg's 16-bit registers sit at odd offsets (0x16,
// 0x1e), where a 32-bit access would fault on Device memory (observed
// alignment fault, claim 0828). The console/blk transports use exactly
// these accessors and VZ accepts them for every virtio device.
fn vp_read8(off: u32) u8 {
    return mmio.mmio_read8(cv_common + off);
}

fn vp_write8(off: u32, value: u8) void {
    mmio.mmio_write8(cv_common + off, value);
}

fn vp_read16(off: u32) u16 {
    return mmio.mmio_read16(cv_common + off);
}

fn vp_write16(off: u32, value: u16) void {
    mmio.mmio_write16(cv_common + off, value);
}

fn vp_read32(off: u32) u32 {
    return mmio.mmio_read32(cv_common + off);
}

fn vp_write32(off: u32, value: u32) void {
    mmio.mmio_write32(cv_common + off, value);
}

/// Enable the device's PCI command register so its BAR MMIO becomes live.
/// The firmware arms memory space for the standard virtio devices (console/
/// blk boot with command = 0x16) but NOT for the custom device (it boots
/// with command = 0x10, MWI only) — its BARs are inert, and any BAR access
/// external-aborts (observed far = the BAR base, claim 0828). The custom
/// driver therefore performs the enumeration step the firmware skips:
/// memory space + bus master + MWI (0x16, the console's exact value —
/// proven to make the custom BAR0 respond). Config-space writes work
/// post-exit (claim 0828 observation; post-exit config reads already
/// worked per claims 1517/6684). Idempotent; safe when the device is
/// absent (probe() failed -> cv_dev == 32 sentinel, never reached).
fn enable_memory_space() void {
    if (cv_dev >= 32) return;
    if (pci.pci_ecam == 0) return;
    pci.pci_write32(pci.pci_ecam, 0, cv_dev, 0, 0x04, 0x16);
}

// ---------------------------------------------------------------------------
// Ring allocator (claim 4374): a free list over the descriptor table
// ---------------------------------------------------------------------------

/// Initialize a ring's tables + free list. BSS is not trusted zeroed, so
/// the used ring's init write is cleaned to RAM (the claim-0016 lesson).
pub fn ring_init(r: *VirtqRing) void {
    r.avail = .{ .flags = 0, .idx = 0, .ring = @as([queue_size]u16, @splat(@as(u16, 0))), .used_event = 0 };
    r.used = .{ .flags = 0, .idx = 0, .ring = @as([queue_size]VirtqUsedElem, @splat(@as(VirtqUsedElem, .{ .id = 0, .len = 0 }))), .avail_event = 0 };
    // Free list initialized REVERSED so the LIFO pop hands out LOW indices
    // first (heads 0,2,4,... — the claim-0828-proven pattern). Observed on
    // VZ: the custom device's queue parser reads the head descriptors it
    // expects at low indices; high-index heads (LIFO ascending) parse as
    // garbage and nextElement() returns nil.
    for (&r.free, 0..) |*f, i| f.* = @intCast(queue_size - 1 - i);
    r.free_count = queue_size;
    r.last_used = 0;
    r.armed = false;
    mmu.clean_dcache_range(@intFromPtr(&r.used), @sizeOf(VirtqUsed));
}

/// Pop `count` descriptors off the free list and link them into one chain
/// (head -> ... -> tail; NEXT set on all but the tail). Returns the head
/// descriptor index, or null when the list cannot satisfy the request.
pub fn alloc_chain(r: *VirtqRing, count: u16) ?u16 {
    if (count == 0) return null;
    if (count > r.free_count) return null;
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
    // Chain linkage: NEXT on every descriptor except the tail.
    var cur = head.?;
    var remaining = count;
    while (remaining > 1) : (remaining -= 1) {
        r.desc[cur].flags |= vq_next;
        cur = r.desc[cur].next;
    }
    return head;
}

/// Return a chain's descriptors to the free list (walks the chain via the
/// NEXT flag). Recycled indices are handed out again by alloc_chain — the
/// claim-4374 recycle proof.
pub fn free_chain(r: *VirtqRing, head: u16) void {
    // Collect the chain (head..tail), then push TAIL-first so the head is
    // the next index handed out again — freeing + re-allocating yields the
    // exact same head indices (the claim-4374 deterministic recycle proof).
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

/// Fill a chain + post its avail entry (pure: no MMIO, no cache ops — the
/// pieces host tests exercise). `reply_first` (ANY_LAYOUT, claim 9737)
/// puts the device-write reply descriptor at the head; otherwise the read
/// descriptors come first (Virtio 1.3 §2.7.6). The chain's NEXT links come
/// from alloc_chain and are preserved.
pub fn post_avail(r: *VirtqRing, head: u16, scatter: []const []const u8, reply_buf: []const u8, reply_first: bool) void {
    // Claim 5804: descriptor addrs are guest PHYSICAL addresses — the
    // device DMA-reads them, so translate the post-jump kernel VAs.
    var cur = head;
    if (reply_first) {
        r.desc[cur].addr = mmu.to_phys(@intFromPtr(reply_buf.ptr));
        r.desc[cur].len = @intCast(reply_buf.len);
        r.desc[cur].flags = (r.desc[cur].flags & vq_next) | vq_write;
        cur = r.desc[cur].next;
    }
    for (scatter) |part| {
        r.desc[cur].addr = mmu.to_phys(@intFromPtr(part.ptr));
        r.desc[cur].len = @intCast(part.len);
        r.desc[cur].flags = r.desc[cur].flags & vq_next; // preserve NEXT, clear WRITE
        cur = r.desc[cur].next;
    }
    if (!reply_first) {
        r.desc[cur].addr = mmu.to_phys(@intFromPtr(reply_buf.ptr));
        r.desc[cur].len = @intCast(reply_buf.len);
        r.desc[cur].flags = (r.desc[cur].flags & vq_next) | vq_write;
    }
    const slot = r.avail.idx % queue_size;
    r.avail.ring[slot] = head;
    r.avail.idx +%= 1;
}

/// Scan the used ring for the element with head index `handle` (pure — no
/// cache ops; `wait` adds the invalidate around it). Entries are consumed
/// one per call so out-of-order completion across many in-flight elements
/// is handled: an entry with a different id is skipped (last_used advances
/// by one), never lost.
pub fn scan_used(r: *VirtqRing, handle: u16, budget: usize, reply_buf: []u8) ?u32 {
    var i: usize = 0;
    while (i < budget) : (i += 1) {
        const used_idx = r.used.idx;
        if (used_idx != r.last_used) {
            const elem = r.used.ring[r.last_used % queue_size];
            r.last_used +%= 1;
            if (elem.id == handle) {
                used_len = elem.len;
                current_reply_len = reply_buf.len;
                return elem.len;
            }
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Transport setup (POST-exit; called by main.zig after the console is up)
// ---------------------------------------------------------------------------

/// Initialize the custom-virtio transport on the pre-exit-resolved
/// addresses: reset -> ACKNOWLEDGE|DRIVER -> negotiate (VERSION_1 +
/// ANY_LAYOUT + NOTIFICATION_DATA when offered, claim 9737) -> FEATURES_OK
/// -> arm both queues (split rings, size 32) -> DRIVER_OK (the console's
/// exact sequence, Virtio 1.3 §3.1.1). POST-exit only; no config-space
/// reads (claim 0013). Returns true when armed; a silent no-op when the
/// device was not discovered pre-exit.
pub fn init() bool {
    if (cv_common == 0) return false;
    enable_memory_space(); // claim 0828: the firmware skips this for the custom device
    vp_write8(0x14, 0); // reset
    var reset_spins: usize = 0;
    while (vp_read8(0x14) != 0) : (reset_spins += 1) {
        if (reset_spins >= 1_000_000) return false;
    }
    vp_write8(0x14, 1 | 2); // ACKNOWLEDGE | DRIVER

    // Claim 9737: read the full 64-bit device-features word (lo word then
    // hi word), accept VERSION_1 always and ANY_LAYOUT / NOTIFICATION_DATA
    // when offered, and report what happened.
    vp_write32(0x00, 0);
    const feat_lo = vp_read32(0x04);
    vp_write32(0x00, 1);
    const feat_hi = vp_read32(0x04);
    vp_write32(0x00, 0);
    device_features = (@as(u64, feat_hi) << 32) | feat_lo;
    if ((device_features & vq_feature_version_1) == 0) return false; // no VIRTIO_F_VERSION_1
    const wanted = vq_feature_version_1 | vq_feature_any_layout | vq_feature_notification_data;
    guest_features = wanted & device_features;
    has_any_layout = (guest_features & vq_feature_any_layout) != 0;
    has_notification_data = (guest_features & vq_feature_notification_data) != 0;
    vp_write32(0x08, 0);
    vp_write32(0x0c, @truncate(guest_features));
    vp_write32(0x08, 1);
    vp_write32(0x0c, @truncate(guest_features >> 32));
    vp_write32(0x08, 0);
    vp_write32(0x0c, 0);
    vp_write8(0x14, 1 | 2 | 8); // FEATURES_OK
    if ((vp_read8(0x14) & 8) == 0) return false;

    // Arm every queue: select, size, ring addresses (le64 written as two
    // 32-bit stores — claim 0013 access-size quirk), enable, notify offset.
    // Queue `push_qidx` is OPTIONAL (the claim-3141 --cvc-echo device): a
    // size-0 read means the two-queue device — stop cleanly, leave
    // has_push_queue false, keep the classic world byte-identical.
    armed_queues = 0;
    has_push_queue = false;
    has_input_queue = false;
    has_snap_queue = false;
    has_file_queue = false;
    var qi: u16 = 0;
    while (qi < max_queue_probe) : (qi += 1) {
        vp_write16(0x16, qi); // queue_select
        const qsz = vp_read16(0x18);
        if (qsz == 0) break; // absent queue (spec: reads return 0 past the last)
        if (qsz < queue_size) return false;
        vp_write16(0x18, queue_size); // queue_size = 32 (power of 2, §4.1.4.3)
        const r = &cv_rings[qi];
        ring_init(r);
        // Claim 5804: queue GPAs are guest PHYSICAL — translate post-jump
        // kernel VAs back to phys for the device.
        const qd = mmu.to_phys(@intFromPtr(&r.desc));
        mmio.mmio_write32(cv_common + 0x20, @truncate(qd));
        mmio.mmio_write32(cv_common + 0x24, @truncate(qd >> 32));
        const qa = mmu.to_phys(@intFromPtr(&r.avail));
        mmio.mmio_write32(cv_common + 0x28, @truncate(qa));
        mmio.mmio_write32(cv_common + 0x2c, @truncate(qa >> 32));
        const qu = mmu.to_phys(@intFromPtr(&r.used));
        mmio.mmio_write32(cv_common + 0x30, @truncate(qu));
        mmio.mmio_write32(cv_common + 0x34, @truncate(qu >> 32));
        vp_write16(0x1c, 1); // queue_enable
        r.notify_off = vp_read16(0x1e);
        r.armed = true;
        armed_queues = qi + 1;
    }
    if (armed_queues < queue_count) return false;
    has_push_queue = armed_queues > push_qidx;
    has_input_queue = armed_queues > input_qidx;
    has_snap_queue = armed_queues > snap_qidx;
    has_file_queue = armed_queues > file_qidx;
    vp_write8(0x14, 1 | 2 | 8 | 4); // DRIVER_OK
    if ((vp_read8(0x14) & 4) == 0) return false;
    cv_ready = true;
    return true;
}

// ---------------------------------------------------------------------------
// Transport API (claims 4374/9492/9737/4837)
// ---------------------------------------------------------------------------

/// Submit one element on queue `qidx`: allocate a chain of
/// `scatter.len + 1` descriptors from the ring's free list (the read
/// buffers, then — or FIRST when `reply_first` — the write reply buffer),
/// post one avail entry, and kick. Returns the head descriptor index (the
/// element handle for `wait`), or null when the transport is unarmed or
/// the ring cannot satisfy the request. Buffers are caller-owned and of
/// caller-chosen length. Many elements may be in flight concurrently
/// (outstanding < queue_size); freed chains are recycled (claim 4374).
pub fn submit_ex(qidx: u16, scatter: []const []const u8, reply_buf: []const u8, reply_first: bool) ?u16 {
    if (!cv_ready) return null;
    if (qidx >= armed_queues) return null;
    const r = &cv_rings[qidx];
    if (!r.armed) return null;
    if (scatter.len == 0 or reply_buf.len == 0) return null;
    if (scatter.len + 1 > queue_size) return null;
    const total: u16 = @intCast(scatter.len + 1);
    const head = alloc_chain(r, total) orelse return null;
    post_avail(r, head, scatter, reply_buf, reply_first);
    mmu.clean_dcache_range(@intFromPtr(&r.desc), @sizeOf(VirtqDesc) * queue_size);
    mmu.clean_dcache_range(@intFromPtr(&r.avail), @sizeOf(VirtqAvail));
    for (scatter) |part| mmu.clean_dcache_range(@intFromPtr(part.ptr), part.len);
    mmu.clean_dcache_range(@intFromPtr(reply_buf.ptr), reply_buf.len);
    kick(qidx);
    return head;
}

/// Kick queue `qidx` (notify the device): the negotiated NOTIFICATION_DATA
/// format (Virtio 1.3 §4.1.5.2.1: vqn << 16 | next_off, ring_flags 0) or
/// the classic 16-bit queue index. Shared by submit_ex and the push API.
fn kick(qidx: u16) void {
    const r = &cv_rings[qidx];
    if (has_notification_data) {
        const data: u32 = (@as(u32, qidx) << 16) | (@as(u32, r.avail.idx) & 0x3fff);
        mmio.mmio_write32(cv_notify + @as(u64, r.notify_off) * cv_notify_mult, data);
    } else {
        mmio.mmio_write16(cv_notify + @as(u64, r.notify_off) * cv_notify_mult, qidx);
    }
}

// ---------------------------------------------------------------------------
// Host-push echo transport (claim 3141, issue #523 item 3): the HOST app
// initiates. The SDK exposes no host-side enqueue — elements exist only as
// descriptors the guest posted — so this is the virtio-net-RX pattern:
// the driver PRE-ARMS one empty device-write receive buffer on queue 2 and
// kicks; the host dequeues it at a time of its choosing, writes the request,
// and returns it (used ring advances + the device IRQ asserts); this driver
// observes the completion, reads the request, and posts the reply.
// ---------------------------------------------------------------------------

/// The pre-armed receive buffer the host writes its request into (BSS — a
/// runtime address; .rodata pointers are image-relative in a flat image).
pub var push_rx_buf: [push_buf_len]u8 align(16) = undefined;
/// Chain head of the pre-armed receive buffer (the handle wait_any_push
/// matches against the used entry's id).
pub var push_rx_handle: u16 = 0;

/// Pre-arm ONE receive buffer on the push queue and kick once. Returns true
/// when armed + kicked; false when the transport/queue is unavailable.
pub fn arm_push() bool {
    if (!cv_ready or !has_push_queue) return false;
    const r = &cv_rings[push_qidx];
    if (!r.armed) return false;
    const head = alloc_chain(r, 1) orelse return false;
    r.desc[head].addr = mmu.to_phys(@intFromPtr(&push_rx_buf));
    r.desc[head].len = @intCast(push_buf_len);
    r.desc[head].flags |= vq_write; // device-write only (an RX buffer)
    const slot = r.avail.idx % queue_size;
    r.avail.ring[slot] = head;
    r.avail.idx +%= 1;
    push_rx_handle = head;
    mmu.clean_dcache_range(@intFromPtr(&r.desc), @sizeOf(VirtqDesc) * queue_size);
    mmu.clean_dcache_range(@intFromPtr(&r.avail), @sizeOf(VirtqAvail));
    mmu.clean_dcache_range(@intFromPtr(&push_rx_buf), push_buf_len);
    kick(push_qidx);
    return true;
}

/// One completed pre-armed receive buffer: which chain came back and how
/// many bytes the host wrote into it.
pub const PushRx = struct { handle: u16, len: u32 };

/// Poll the push queue's used ring until the pre-armed receive buffer
/// completes (or the budget runs out). Entries are consumed one per loop
/// iteration; a zero-length entry (a drained spare — none with the single
/// pre-armed buffer) is skipped, not lost. On the match the host-written
/// bytes are invalidated for reading and `used_len` carries the length.
pub fn wait_any_push(budget: usize) ?PushRx {
    if (!cv_ready or !has_push_queue) return null;
    const r = &cv_rings[push_qidx];
    if (!r.armed) return null;
    var i: usize = 0;
    while (i < budget) : (i += 1) {
        // Host tests stage the used ring directly; `dc ivac` is EL0-illegal
        // there (the reap_parked idiom) and a coherent host never needs it.
        if (comptime !builtin.is_test) {
            mmu.invalidate_dcache_range(@intFromPtr(&r.used), @sizeOf(VirtqUsed));
        }
        if (r.used.idx != r.last_used) {
            const elem = r.used.ring[r.last_used % queue_size];
            r.last_used +%= 1;
            if (elem.len == 0) continue; // drained spare — keep waiting
            used_len = elem.len;
            // M97e-D2 (#2100): the used-ring length is host-controlled —
            // return it CLAMPED to the armed receive buffer so the next
            // caller cannot repeat the unclamped-len mistake (the A1/A2
            // class). `used_len` still records the raw report.
            const n: usize = @min(@as(usize, elem.len), push_buf_len);
            if (comptime !builtin.is_test) {
                mmu.invalidate_dcache_range(@intFromPtr(&push_rx_buf), n);
            }
            return .{ .handle = @intCast(elem.id), .len = @intCast(n) };
        }
    }
    return null;
}

/// Convenience single-payload submit on queue 0 (classic read-then-write
/// order). Returns the element handle.
pub fn submit(payload_buf: []const u8, reply_buf: []u8) ?u16 {
    return submit_ex(0, &.{payload_buf}, reply_buf, false);
}

// ---------------------------------------------------------------------------
// Input channel (claim 9588, issue #523 item 3): queue 3 carries host→guest
// keyboard injection as fixed 16-byte messages (wire format normative in
// docs/hardware-contract.md). Same virtio-net-RX pattern as the push echo,
// at pool scale: eight pre-armed device-write buffers, replenished per
// completion, consumed by a polled drain from the shell idle loop's RX seam.
// ---------------------------------------------------------------------------

/// Receive-buffer capacity (the descriptor length; messages are 16 bytes —
/// a mismatch surfaces as the bad counter, never a wedge).
pub const input_buf_cap: usize = 32;
/// Fixed total message size: [kind u8][flags u8][len u16le][12-byte payload].
pub const input_msg_len: usize = 16;
/// Message kinds (kind 1 keyboard, kind 2 pointer — claim 9367; kind 3
/// console control and kind 4 snapshot request — claim 0680). Queue 3 is
/// the general host→guest CONTROL/INPUT queue: every kind rides the same
/// 16-byte envelope into the same pre-armed receive pool.
pub const input_kind_keyboard: u8 = 1;
pub const input_kind_pointer: u8 = 2;
pub const input_kind_console_ctrl: u8 = 3;
pub const input_kind_snapshot_req: u8 = 4;
/// Kind-1 payload length: the raw HID keyboard boot report.
pub const input_keyboard_rep_len: usize = 8;
/// Kind-2 payload length: the raw absolute-pointer report
/// [buttons, x_lo, x_hi, y_lo, y_hi] — the same shape the XHCI pointer's
/// interrupt-IN reports decode from (coords are HID absolute 0..32767).
pub const input_pointer_rep_len: usize = 5;
/// Kind-3 payload length: one control byte (bit0 = console-tee enable).
pub const input_ctrl_rep_len: usize = 1;
/// Kind-4 payload length: the snapshot request is empty.
pub const input_snap_req_len: usize = 0;
/// Pre-armed receive buffers (bounded pool; the host paces well below this
/// and the idle-loop drain replenishes within one tick anyway).
pub const input_pool_count: usize = 8;

/// The pre-armed receive buffers (BSS — runtime addresses; .rodata pointers
/// are image-relative in a flat image, the claim-0015 lesson).
pub var input_rx_bufs: [input_pool_count][input_buf_cap]u8 align(16) = undefined;
/// Each buffer's chain head (used-ring id -> slot lookup).
var input_rx_handles: [input_pool_count]u16 = @as([input_pool_count]u16, @splat(@as(u16, 0)));
/// True once `arm_input_pool` posted + kicked the whole pool.
pub var input_armed: bool = false;
/// Messages consumed and dispatched (valid envelopes, any kind).
pub var input_rx_count: u32 = 0;
/// Kind-2 pointer messages consumed and dispatched (claim 9367).
pub var input_ptr_count: u32 = 0;
/// Kind-3 console-control messages consumed (claim 0680).
pub var input_ctrl_count: u32 = 0;
/// Malformed messages dropped (bad kind / bad len / short envelope) — the
/// loud-by-counter failure mode; never a partial decode.
pub var input_bad_count: u32 = 0;
/// The decode hook: main.zig wires it to input.decode_keyboard_report so an
/// injected key report takes the exact path an XHCI report takes (event
/// FIFO when an app window owns focus, console bytes at the terminal, and
/// the `input` report counters either way). Null = count-only (honest no-op).
pub var on_input_report: ?*const fn (rep: []const u8) void = null;
/// Claim 9367: the pointer decode hook — main.zig wires it to
/// input.decode_pointer_report so an injected absolute-pointer report takes
/// the exact path an XHCI pointer report takes (`dui` click-to-focus,
/// cursor moves, `input` ptr-* counters). Null = count-only.
pub var on_pointer_report: ?*const fn (rep: []const u8) void = null;

/// Pre-arm the receive pool on queue 3 and kick once. Returns true when all
/// EIGHT buffers are posted; false when the transport/queue is unavailable
/// or the ring cannot satisfy the pool (partial pools are not armed).
pub fn arm_input_pool() bool {
    if (!cv_ready or !has_input_queue) return false;
    const r = &cv_rings[input_qidx];
    if (!r.armed) return false;
    var posted: usize = 0;
    for (0..input_pool_count) |i| {
        const head = alloc_chain(r, 1) orelse break;
        r.desc[head].addr = mmu.to_phys(@intFromPtr(&input_rx_bufs[i]));
        r.desc[head].len = @intCast(input_buf_cap);
        r.desc[head].flags |= vq_write; // device-write only (an RX buffer)
        const slot = r.avail.idx % queue_size;
        r.avail.ring[slot] = head;
        r.avail.idx +%= 1;
        input_rx_handles[i] = head;
        posted += 1;
    }
    if (posted != input_pool_count) return false;
    mmu.clean_dcache_range(@intFromPtr(&r.desc), @sizeOf(VirtqDesc) * queue_size);
    mmu.clean_dcache_range(@intFromPtr(&r.avail), @sizeOf(VirtqAvail));
    for (0..input_pool_count) |i| mmu.clean_dcache_range(@intFromPtr(&input_rx_bufs[i]), input_buf_cap);
    kick(input_qidx);
    input_armed = true;
    return true;
}

/// Validate one completed message and dispatch kind-1 (keyboard) / kind-2
/// (pointer) payloads to their hooks. Anything else — bad kind, bad flags,
/// wrong payload length, short envelope — increments the bad counter and is
/// dropped loudly-by-counter, never decoded partially.
fn dispatch_input_msg(msg: []const u8) void {
    if (msg.len < 4 or msg[1] != 0) {
        input_bad_count += 1;
        return;
    }
    const len: usize = @as(usize, msg[2]) | (@as(usize, msg[3]) << 8);
    switch (msg[0]) {
        input_kind_keyboard => {
            if (len != input_keyboard_rep_len or msg.len < 4 + len) {
                input_bad_count += 1;
                return;
            }
            input_rx_count += 1;
            if (on_input_report) |hook| hook(msg[4 .. 4 + len]);
        },
        input_kind_pointer => {
            if (len != input_pointer_rep_len or msg.len < 4 + len) {
                input_bad_count += 1;
                return;
            }
            input_ptr_count += 1;
            if (on_pointer_report) |hook| hook(msg[4 .. 4 + len]);
        },
        input_kind_console_ctrl => {
            if (len != input_ctrl_rep_len or msg.len < 4 + len) {
                input_bad_count += 1;
                return;
            }
            input_ctrl_count += 1;
            console_tee_set_enabled((msg[4] & 0x01) != 0);
        },
        input_kind_snapshot_req => {
            if (len != input_snap_req_len) {
                input_bad_count += 1;
                return;
            }
            input_rx_count += 1;
            snap_pending = true; // serviced from the idle seam, never inline
        },
        else => {
            input_bad_count += 1;
        },
    }
}

/// Return one consumed buffer to service: free its chain (the deterministic
/// LIFO hands the same head back), refill the descriptor, re-post it.
fn rearm_input_slot(r: *VirtqRing, slot: usize) void {
    free_chain(r, input_rx_handles[slot]);
    const head = alloc_chain(r, 1) orelse return;
    r.desc[head].addr = mmu.to_phys(@intFromPtr(&input_rx_bufs[slot]));
    r.desc[head].len = @intCast(input_buf_cap);
    r.desc[head].flags |= vq_write;
    const avail_slot = r.avail.idx % queue_size;
    r.avail.ring[avail_slot] = head;
    r.avail.idx +%= 1;
    input_rx_handles[slot] = head;
}

/// Non-blocking pump for the shell idle loop's RX seam: scan the used ring,
/// dispatch every completed message, and replenish its buffer (one kick per
/// batch). Bounded per call so a burst cannot starve the loop. A no-op
/// unless the four-queue device armed its pool.
pub fn poll_input() void {
    if (!cv_ready or !has_input_queue or !input_armed) return;
    const r = &cv_rings[input_qidx];
    if (!r.armed) return;
    var replenished = false;
    var processed: usize = 0;
    while (processed < queue_size) : (processed += 1) {
        mmu.invalidate_dcache_range(@intFromPtr(&r.used), @sizeOf(VirtqUsed));
        if (r.used.idx == r.last_used) break;
        const elem = r.used.ring[r.last_used % queue_size];
        r.last_used +%= 1;
        // Match the completion back to its pool slot by chain head.
        var slot: ?usize = null;
        for (&input_rx_handles, 0..) |h, i| {
            if (h == elem.id) {
                slot = i;
                break;
            }
        }
        const s = slot orelse continue; // unknown element: skip, never lost
        const n: usize = @min(@as(usize, elem.len), input_msg_len);
        mmu.invalidate_dcache_range(@intFromPtr(&input_rx_bufs[s]), n);
        dispatch_input_msg(input_rx_bufs[s][0..n]);
        rearm_input_slot(r, s);
        replenished = true;
    }
    if (replenished) {
        mmu.clean_dcache_range(@intFromPtr(&r.desc), @sizeOf(VirtqDesc) * queue_size);
        mmu.clean_dcache_range(@intFromPtr(&r.avail), @sizeOf(VirtqAvail));
        kick(input_qidx);
    }
}

/// Return element `handle`'s chain to queue `qidx`'s free list.
pub fn free_chain_q(qidx: u16, handle: u16) void {
    if (!cv_ready) return;
    if (qidx >= armed_queues) return;
    free_chain(&cv_rings[qidx], handle);
}

/// A queue's kick without a new submit — an explicit notify so the device
/// rescans the avail ring. The file channel uses it on a wait timeout: the
/// element is still posted, and a host-side callback that ran too early
/// (or whose notification was dropped) will serve it on the re-scan.
pub fn kick_q(qidx: u16) void {
    if (!cv_ready) return;
    if (qidx >= armed_queues) return;
    kick(qidx);
}

// ---------------------------------------------------------------------------
// Parked-chain discipline (claim #899 — the z2a zc-leg OUT.TXT flake).
//
// When an exchange's wait times out, the host may STILL hold the element
// (its reply arrives later — the host was slow, not dead). Freeing the
// chain immediately lets the next submit REUSE the same head while the
// element is still queued on the host side; the host then serves the
// recycled chain with the NEW exchange's descriptors/content (the observed
// "request length mismatch" refusals and mis-served elements) or its late
// reply is matched by the next exchange (wrong data for the right op).
// Instead: a timed-out chain is PARKED — never returned to the free list,
// so its head is never reallocated — until its used-ring entry is observed
// (reap_parked), at which point the reply is known to have arrived and the
// chain is freed for good. Parked heads can therefore never be misattrib-
// uted; the only cost is a descriptor held out of the pool while the host
// is slow (the ring self-throttles; 32 descriptors, a handful of parked
// heads is nothing). The file channel (queue 5) is the only user.
// ---------------------------------------------------------------------------
pub var parked_heads: [8]u16 = undefined;
pub var parked_count: u16 = 0;

/// Park chain `head` (queue 5) after a wait timeout. The chain stays out
/// of the free list until its reply is observed by reap_parked. If the
/// park list is full the head is simply leaked (never freed, never
/// recycled) — the same corruption-free invariant, one descriptor lost to
/// a pathological host.
pub fn park_chain(head: u16) void {
    if (parked_count < parked_heads.len) {
        parked_heads[parked_count] = head;
        parked_count += 1;
    }
}

/// Consumed used entries on the file queue that named no live element and
/// no parked head — a device fabrication or a double-consumed id. Bounded
/// counter only (issue #2495): observed non-zero would mean the host
/// returned an element the driver never posted.
pub var stale_used_count: u32 = 0;

/// A consumed used entry carrying a parked head's id: its late reply
/// arrived, the element is done — free the chain and drop it from the
/// parked list. Any other consumed id is a fabrication — counted, never
/// attributed, never freed. Mirrors gpu3d's reap_parked_id (claim #899
/// follow-through): the previous wait-loop dropped these entries without
/// freeing, so a parked chain whose reply arrived DURING a later exchange
/// was never reclaimed — every park permanently leaked its descriptors.
fn reap_parked_id(id: u32) void {
    for (&parked_heads, 0..) |*h, idx| {
        if (idx >= parked_count) break;
        if (h.* == id) {
            free_chain(&cv_rings[file_qidx], @intCast(id));
            parked_count -= 1;
            parked_heads[idx] = parked_heads[parked_count];
            return;
        }
    }
    stale_used_count += 1;
}

/// Reap parked chains whose used-ring entry has now appeared (the host's
/// late reply arrived). Called after every completed exchange while the
/// caller still holds the file-channel lock, so it never races. Consumes
/// used entries in order; a parked head that shows up is freed; any other
/// outstanding entry is impossible by the invariant (the previous wait
/// consumed the current exchange's reply, and every stale reply is a
/// parked head), so non-parked entries are just advanced past.
pub fn reap_parked() void {
    if (parked_count == 0) return;
    if (!cv_ready) return;
    const r = &cv_rings[file_qidx];
    if (!r.armed) return;
    var scanned: usize = 0;
    while (parked_count > 0 and scanned < parked_heads.len) : (scanned += 1) {
        if (comptime !builtin.is_test) {
            mmu.invalidate_dcache_range(@intFromPtr(&r.used), @sizeOf(VirtqUsed));
        }
        if (r.used.idx == r.last_used) break;
        const elem = r.used.ring[r.last_used % queue_size];
        r.last_used +%= 1;
        reap_parked_id(elem.id);
    }
}

/// A parked element stays ARMED in the avail ring — the host may dequeue
/// and serve it at any later moment (issue #2495). Its descriptors still
/// point at the caller's shared request/reply buffers, so a late serve
/// reads whatever request the NEXT exchange staged there — re-executing
/// it (a duplicated write/open/rename mutates share state a second time)
/// — and writes its reply into the live reply buffer between exchanges.
/// Before a timed-out chain is parked, repoint its descriptors at the
/// caller-provided sink buffers: the late serve then performs a fixed
/// benign request and drops its reply in the sink, never live state.
///
/// Store order keeps every torn device view benign: the length is zeroed
/// and made visible BEFORE the address moves, and the new length is
/// published only after the new address is — the device can never observe
/// <stale buffer, nonzero new length>, the combination that would let it
/// read live buffer contents. Each descriptor's existing flags/next are
/// preserved (the chain shape the host recorded is unchanged).
pub fn neutralize_chain(qidx: u16, head: u16, req_sink: []const u8, reply_sink: []u8) void {
    if (qidx >= armed_queues) return;
    const r = &cv_rings[qidx];
    if (!r.armed) return;
    var cur = head;
    while (true) {
        const d = &r.desc[cur];
        const is_write = (d.flags & vq_write) != 0;
        const last = (d.flags & vq_next) == 0;
        const sink_ptr = if (is_write) @intFromPtr(reply_sink.ptr) else @intFromPtr(req_sink.ptr);
        const sink_len: u32 = @intCast(if (is_write) reply_sink.len else req_sink.len);
        d.len = 0;
        if (comptime !builtin.is_test) {
            asm volatile ("dsb ish" ::: .{ .memory = true });
        }
        d.addr = mmu.to_phys(sink_ptr);
        if (comptime !builtin.is_test) {
            asm volatile ("dsb ish" ::: .{ .memory = true });
        }
        d.len = sink_len;
        if (last) break;
        cur = d.next;
    }
    if (comptime !builtin.is_test) {
        mmu.clean_dcache_range(@intFromPtr(&r.desc), @sizeOf(VirtqDesc) * queue_size);
    }
}

/// Poll the used ring until the element with head index `handle` returns
/// (the host's returnToQueue) or the budget runs out. Entries are matched
/// by id, so out-of-order completion across in-flight elements is handled.
/// On the match the reply buffer (written by the host) is invalidated so
/// the caller reads the device's bytes; `used_len`/`reply_len()` then
/// describe the exchange. Returns the used length, or null on timeout.
pub fn wait(qidx: u16, handle: u16, budget: usize, reply_buf: []u8) ?u32 {
    if (!cv_ready) return null;
    if (qidx >= armed_queues) return null;
    const r = &cv_rings[qidx];
    if (!r.armed) return null;
    var i: usize = 0;
    while (i < budget) : (i += 1) {
        // Host tests stage the used ring directly; `dc ivac` is EL0-illegal
        // there (the reap_parked idiom) and a coherent host never needs it.
        if (comptime !builtin.is_test) {
            mmu.invalidate_dcache_range(@intFromPtr(&r.used), @sizeOf(VirtqUsed));
        }
        const used_idx = r.used.idx;
        if (used_idx != r.last_used) {
            const elem = r.used.ring[r.last_used % queue_size];
            r.last_used +%= 1;
            if (elem.id == handle) {
                used_len = elem.len;
                current_reply_len = reply_buf.len;
                // The chain's tail is the device-write reply buffer: the
                // host's written bytes land there before the used entry is
                // published, so the used advance is the memory-ordering
                // point. Invalidate only the reported length (defensive on
                // VZ's coherent emulation).
                if (comptime !builtin.is_test) {
                    mmu.invalidate_dcache_range(@intFromPtr(reply_buf.ptr), reply_len());
                }
                return elem.len;
            }
            // #2495: a consumed non-matching id on the file queue is a
            // parked head's late reply — free its chain here, at the point
            // of consumption. The previous shape just advanced past it, so
            // the parked list never shrank and every park leaked its
            // descriptors (reap_parked could only ever observe entries
            // landing in the microsecond window after this wait returned).
            if (qidx == file_qidx) reap_parked_id(elem.id);
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Guest log transport (claim 4837): queue 1 carries guest log lines; the
// host echoes each to its stdout and replies ACK:<len>
// ---------------------------------------------------------------------------

/// Buffer the host's ACK reply lands in (exposed for the report).
pub var cv_log_ack_buf: [32]u8 align(16) = undefined;
/// Bytes of the most recent log line's host ack (used-ring length).
pub var cv_log_ack_len: usize = 0;
/// The guest log line currently being sent (report helper).
pub var cv_log_line: [64]u8 = undefined;
/// Length of the current log line.
pub var cv_log_line_len: usize = 0;

/// The bounded wait budget for one log-line exchange.
pub const cv_log_budget: usize = 16_000_000;

/// Send one guest log line over queue 1 (polled transport — no IRQ
/// dependency; claim 4837): submit the line as the device-read descriptor,
/// wait for the host's ack, and verify `ACK:<len>` with len == line.len.
/// The line + ack are captured in `cv_log_line`/`cv_log_ack_buf` for the
/// report. Returns false when the transport is unarmed, the line is empty/
/// too long, or the ack does not verify.
pub fn cvlog_puts(line: []const u8) bool {
    if (!cv_ready) return false;
    if (cv_rings[1].armed == false) return false;
    if (line.len == 0 or line.len > cv_log_line.len) return false;
    @memcpy(cv_log_line[0..line.len], line);
    cv_log_line_len = line.len;
    // Scatter via the BSS staging array — an anonymous `&.{...}` slice
    // array would fold into .rodata with a baked (image-relative) pointer.
    cv_scatter[0] = cv_log_line[0..cv_log_line_len];
    const h = submit_ex(1, cv_scatter[0..1], cv_log_ack_buf[0..], false) orelse return false;
    // Claim 0680 fix: the chain MUST go back to the free list — a polled
    // send-and-forget here leaked two descriptors per line, which the
    // spike's five lines survived but the console tee's sustained traffic
    // did not (ring exhausted after ~16 sends, every later send dropped).
    defer free_chain_q(1, h);
    const n = wait(1, h, cv_log_budget, cv_log_ack_buf[0..]) orelse return false;
    cv_log_ack_len = @min(@as(usize, n), cv_log_ack_buf.len);
    if (cv_log_ack_len < 5) return false; // "ACK:0" is the shortest valid ack
    if (!std.mem.eql(u8, cv_log_ack_buf[0..4], "ACK:")) return false;
    var num: usize = 0;
    for (cv_log_ack_buf[4..cv_log_ack_len]) |b| {
        if (b < '0' or b > '9') return false;
        num = num * 10 + (b - '0');
    }
    return num == line.len;
}

// ---------------------------------------------------------------------------
// Structured console tee (claim 0680, issue #523 item 3): when the host
// arms it (kind-3 control message), every kernel console byte is DUPLICATED
// onto queue 1 as it already is on serial — vm-serial.log parsing stops
// being the only way to observe guest output. Line-buffered like the
// virtio-console transport: complete lines (terminated by '\n') go as one
// message; a partial line flushes from the idle seam (the prompt case).
// Default-off, additive: without the kind-3 message nothing changes.
// ---------------------------------------------------------------------------

/// Tee line capacity. Longer kernel output hard-splits into back-to-back
/// messages; the host appends the raw bytes verbatim (NO injected newline),
/// so the reconstructed stream stays byte-faithful to serial across splits.
pub const tee_line_cap: usize = 256;
/// Bounded wait budget for ONE tee'd line — much tighter than the spike's
/// cv_log_budget: console output happens everywhere, and a stalled host
/// must cost microseconds-plus-counter, never a hang.
pub const tee_budget: usize = 4_000_000;

var tee_line_buf: [tee_line_cap]u8 align(16) = undefined;
var tee_line_len: usize = 0;
var tee_ack_buf: [32]u8 align(16) = undefined;
/// True once a kind-3 enable arrived (and stayed true until an explicit
/// disable — bit0=0 — arrives).
pub var tee_enabled: bool = false;
/// Lines dropped because the host did not drain queue 1 within the budget
/// (or the transport was unavailable). Loud-by-counter; never a wedge.
pub var tee_drop_count: u32 = 0;
/// Lines successfully delivered over queue 1.
pub var tee_sent_count: u32 = 0;

/// Arm/disarm the console tee (kind-3 payload bit0). Resets the partial
/// accumulator either way so no stale fragment leaks across state changes.
fn console_tee_set_enabled(enable: bool) void {
    tee_enabled = enable;
    tee_line_len = 0;
    if (enable) _ = tee_send_line("cvconsole: armed\n");
}

/// Accumulate one console byte; flush on newline or when the staging
/// buffer is full. Called from uart_putc — MUST stay cheap when disarmed.
/// #990 (claim #997): the console tee's TX runs on BOTH cores (core 0's
/// shell/WM prints, the secondary's app prints) with NO synchronization —
/// concurrent tee_flush/tee_send_line raced the CVC chain allocator and
/// the queue-1 rings, and a failed submit DROPPED the line (an EL0 app's
/// stdout intermittently never reached the serial; the WM2 gate keys its
/// script phases on the demo's prints and lost ~50% of WM-mode boots to
/// it). Serialize the flush+send with an IRQ-save spinlock, and give the
/// send a bounded retry (4 attempts) — a contended queue now gets through;
/// a stuck one still drops honestly (tee_drop_count).
var tee_tx_lock = spinlock.IrqSaveSpinlock{};

pub fn console_tee_putc(byte: u8) void {
    if (!tee_enabled or !cv_ready) return;
    if (tee_line_len >= tee_line_cap) tee_flush(false);
    if (tee_line_len >= tee_line_cap) {
        // Even after the forced flush the byte does not fit (impossible:
        // cap > 0 means a flush always empties) — count and drop honestly.
        tee_drop_count += 1;
        return;
    }
    tee_line_buf[tee_line_len] = byte;
    tee_line_len += 1;
    if (byte == '\n') tee_flush(true);
}

/// Idle-seam hook: deliver a partial line (the prompt has no trailing
/// newline). One cheap branch when there is nothing buffered.
pub fn console_tee_flush_partial() void {
    if (!tee_enabled or !cv_ready or tee_line_len == 0) return;
    tee_flush(false);
}

/// Send the accumulated bytes as one queue-1 message and reset the
/// accumulator. `terminated` is diagnostic-only today (the wire form is
/// the raw bytes either way).
fn tee_flush(terminated: bool) void {
    _ = terminated;
    const n = tee_line_len;
    tee_line_len = 0;
    if (n == 0) return;
    const daif = tee_tx_lock.lock();
    defer tee_tx_lock.unlock(daif);
    if (!tee_send_line(tee_line_buf[0..n])) tee_drop_count += 1;
}

/// One tee message: copy into the BSS staging buffer, submit on queue 1,
/// poll-wait for the host's ACK:<len>, validate. False = dropped (counted
/// by the caller). Self-contained — deliberately NOT cvlog_puts, whose
/// 64-byte report buffer would split long kernel lines mid-token.
fn tee_send_line(line_bytes: []const u8) bool {
    if (!cv_ready) return false;
    if (cv_rings[1].armed == false) return false;
    if (line_bytes.len == 0 or line_bytes.len > tee_tx_buf.len) return false;
    // #990: bounded retry — the idle-seam pump reclaims chains between
    // attempts; a contended queue gets through, a stuck one still fails.
    var attempt: usize = 0;
    while (attempt < 4) : (attempt += 1) {
        @memcpy(tee_tx_buf[0..line_bytes.len], line_bytes);
        cv_scatter[0] = tee_tx_buf[0..line_bytes.len];
        const h = submit_ex(1, cv_scatter[0..1], tee_ack_buf[0..], false) orelse continue;
        defer free_chain_q(1, h); // claim 0680: never leak a polled send's chain
        const n = wait(1, h, tee_budget, tee_ack_buf[0..]) orelse continue;
        if (n < 4) continue;
        if (!std.mem.eql(u8, tee_ack_buf[0..3], "OK" ++ ":")) continue;
        tee_sent_count += 1;
        return true;
    }
    return false;
}

/// The tee's own TX staging (BSS — runtime address discipline, claim 0015).
var tee_tx_buf: [tee_line_cap]u8 align(16) = undefined;

/// #1757: the snapshot stream's TX lock — the idle pass and the console
/// reader both service kind-4 requests now, and the framing buffers plus
/// `cv_scatter` are shared BSS. Same IRQ-save discipline as `tee_tx_lock`
/// (a chunk submit spins on the host's OK ack, so holders run bounded).
var snap_tx_lock = spinlock.IrqSaveSpinlock{};

// ---------------------------------------------------------------------------
// Framebuffer snapshot channel (claim 0680, issue #523 item 3): a kind-4
// request arms `snap_pending`; the idle seam calls service_snapshot(), which
// streams the composed scanout (`virtio_gpu.gpu_fb`) as tagged binary
// messages over the optional fifth queue. Wire format normative in
// docs/hardware-contract.md:
//
//   header  [tag=0x01]['S''N''A''P'][ver=1][bpp][width u32le]
//           [height u32le][total u32le][chunk u32le]           (32 bytes)
//   chunk   [tag=0x02][seq u16le][len u16le][cksum u16le][rsvd u8 x6]
//           [payload ≤ chunk_len]                              (12 + len)
//   done    [tag=0x03][chunks u16le][total u32le][cksum u16le]
//           [rsvd x8]                                          (16 bytes)
//
// cksum is the RFC 1071 one's-complement checksum (big-endian words) over
// the chunk payload / the whole frame respectively. Chunks point DIRECTLY
// into gpu_fb (no staging copy, no BSS impact); submit_ex cleans their
// dcache range before the kick. The host acknowledges every element with
// "OK:<n>" exactly like the log transport.
// ---------------------------------------------------------------------------

pub const snap_tag_header: u8 = 0x01;
pub const snap_tag_chunk: u8 = 0x02;
pub const snap_tag_done: u8 = 0x03;
/// Snapshot chunk payload size: 32 KiB → 113 chunks for the 1280×720×4
/// scanout. Small enough for one descriptor per part, large enough that
/// the round trips do not dominate.
pub const snap_chunk_len: usize = 32768;
/// True while a kind-4 request waits for the idle seam (set by
/// dispatch_input_msg, consumed by service_snapshot).
pub var snap_pending: bool = false;
/// Snapshots successfully streamed since boot.
pub var snap_count: u32 = 0;
/// Snapshot requests refused or failed mid-stream (loud by counter).
pub var snap_fail_count: u32 = 0;

/// BSS buffers the framing messages are built into (runtime addresses —
/// anonymous slice arrays would fold .rodata pointers into descriptors).
var snap_hdr_buf: [32]u8 align(16) = undefined;
var snap_chunk_hdr_buf: [12]u8 align(16) = undefined;
var snap_done_buf: [16]u8 align(16) = undefined;
var snap_ack_buf: [32]u8 align(16) = undefined;

/// RFC 1071 one's-complement Internet checksum, big-endian word semantics
/// (mirrors ipv4.checksum; kept local so this module stays self-contained
/// and testable without importing the network stack). The accumulator is
/// u64: a whole-frame checksum over the 3.5 MiB scanout overflows u32
/// before the fold (observed live, claim 0680).
pub fn checksum1071(data: []const u8) u16 {
    var sum: u64 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u64, data[i]) << 8) | data[i + 1];
    }
    if (i < data.len) sum += @as(u64, data[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

fn put16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @truncate(v & 0xff);
    buf[off + 1] = @truncate(v >> 8);
}
fn put32(buf: []u8, off: usize, v: u32) void {
    buf[off] = @truncate(v & 0xff);
    buf[off + 1] = @truncate((v >> 8) & 0xff);
    buf[off + 2] = @truncate((v >> 16) & 0xff);
    buf[off + 3] = @truncate((v >> 24) & 0xff);
}

/// Build the 32-byte snapshot header message (pure; unit-tested).
pub fn build_snap_header(w: u32, h: u32, bpp: u32, total: u32, chunk: u32) [32]u8 {
    var m = @as([32]u8, @splat(@as(u8, 0)));
    m[0] = snap_tag_header;
    m[1] = 'S';
    m[2] = 'N';
    m[3] = 'A';
    m[4] = 'P';
    m[5] = 1; // version
    m[6] = @truncate(bpp);
    put32(&m, 8, w);
    put32(&m, 12, h);
    put32(&m, 16, total);
    put32(&m, 20, chunk);
    return m;
}

/// Build one 12-byte chunk header (payload follows as its own descriptor).
pub fn build_snap_chunk(seq: u16, len: u16, cksum: u16) [12]u8 {
    var m = @as([12]u8, @splat(@as(u8, 0)));
    m[0] = snap_tag_chunk;
    put16(&m, 2, seq);
    put16(&m, 4, len);
    put16(&m, 6, cksum);
    return m;
}

/// Build the 16-byte done message.
pub fn build_snap_done(chunks: u16, total: u32, cksum: u16) [16]u8 {
    var m = @as([16]u8, @splat(@as(u8, 0)));
    m[0] = snap_tag_done;
    put16(&m, 2, chunks);
    put32(&m, 4, total);
    put16(&m, 8, cksum);
    return m;
}

/// The post-stream serial receipt (live-term-depth run 03's coalescing
/// fix): one line per COMPLETED stream, printed after the done message's
/// OK. A `--snapshot-after` or `--input-chords-after` trigger anchored on
/// it is outside every burst window by construction — the channel is idle
/// again the moment this line exists (the guest's `snap_pending` is a
/// bool, so two requests drained by one poll_input still coalesce; the
/// receipt is how a gate keeps them apart).
pub fn build_snap_marker(n: u32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "cvspike: snap n={d}\n", .{n}) catch "cvspike: snap\n";
}

/// Submit one pre-built message (+ optional second scatter part) on the
/// snapshot queue and verify the host's OK ack. Returns false loudly.
fn snap_submit(parts: []const []const u8) bool {
    const h = submit_ex(snap_qidx, parts, snap_ack_buf[0..], false) orelse return false;
    defer free_chain_q(snap_qidx, h); // claim 0680: 113-chunk streams cannot afford leaks
    const n = wait(snap_qidx, h, tee_budget * 4, snap_ack_buf[0..]) orelse return false;
    if (n < 3) return false;
    return std.mem.eql(u8, snap_ack_buf[0..3], "OK" ++ ":");
}

/// Stream the whole framebuffer (called from the console reader's idle tick
/// after poll_input, and — since #1757 — from the scheduler idle pass right
/// after the drain that armed the request). Two callers on two contexts
/// means the stream itself needs serializing: the framing buffers and
/// `cv_scatter` below are shared module BSS. One-shot per kind-4 request;
/// failures increment `snap_fail_count` and end the stream early — the
/// host-side assembly reports what it got.
pub fn service_snapshot() void {
    const daif = snap_tx_lock.lock();
    defer snap_tx_lock.unlock(daif);
    // #1796 review: the arming guard is re-checked UNDER the lock. Both
    // callers test `snap_pending` outside as a fast path, so two contexts
    // can enter on one arming; without the re-check the lock loser would
    // stream a duplicate framebuffer for the same kind-4 request — the
    // overlapped-stream shape the runner's single pendingSnapPath slot
    // mislabels. A call that loses here returns silently: no stream, no
    // fail-counter movement (the request the winner is streaming is the
    // same one).
    if (!snap_pending) return;
    snap_pending = false;
    if (!cv_ready or !has_snap_queue) {
        snap_fail_count += 1;
        return;
    }
    if (!virtio_gpu.gpu_setup_ok) {
        // No scanout was ever set up (GPU absent or not yet flushed):
        // refuse loudly-by-counter rather than ship an undefined buffer.
        snap_fail_count += 1;
        return;
    }
    const total = virtio_gpu.fb_size;
    const frame_cksum = checksum1071(virtio_gpu.gpu_fb[0..]);
    const chunks: u16 = @intCast((total + snap_chunk_len - 1) / snap_chunk_len);

    snap_hdr_buf = build_snap_header(virtio_gpu.fb_width, virtio_gpu.fb_height, virtio_gpu.fb_bpp, @intCast(total), @intCast(snap_chunk_len));
    cv_scatter[0] = snap_hdr_buf[0..];
    if (!snap_submit(cv_scatter[0..1])) {
        snap_fail_count += 1;
        return;
    }

    var seq: u16 = 0;
    var off: usize = 0;
    while (off < total) : ({
        off += snap_chunk_len;
        seq += 1;
    }) {
        const n: usize = @min(snap_chunk_len, total - off);
        const cks = checksum1071(virtio_gpu.gpu_fb[off..][0..n]);
        snap_chunk_hdr_buf = build_snap_chunk(seq, @intCast(n), cks);
        cv_scatter[0] = snap_chunk_hdr_buf[0..];
        cv_scatter[1] = virtio_gpu.gpu_fb[off..][0..n];
        if (!snap_submit(cv_scatter[0..2])) {
            snap_fail_count += 1;
            return;
        }
    }

    snap_done_buf = build_snap_done(chunks, @intCast(total), frame_cksum);
    cv_scatter[0] = snap_done_buf[0..];
    if (!snap_submit(cv_scatter[0..1])) {
        snap_fail_count += 1;
        return;
    }
    snap_count += 1;
    // Completion receipt for the class-B choreography: multi-snapshot
    // gates anchor the NEXT request (or the input burst that leads to it)
    // on this line so no two kind-4 requests are ever in flight together —
    // run 03's snap-03-* coalescing flake. klog is a no-op pre-boot and in
    // host tests, so the receipt costs nothing there.
    var marker_buf: [32]u8 = undefined;
    klog.line(build_snap_marker(snap_count, &marker_buf));
}

/// Test-hook recording (module-level BSS — nested functions cannot capture
/// mutable locals in Zig 0.17).
var test_hook_calls: usize = 0;
var test_hook_last_len: usize = 0;
fn test_input_hook(rep: []const u8) void {
    test_hook_calls += 1;
    test_hook_last_len = rep.len;
}

var test_ptr_calls: usize = 0;
var test_ptr_last_len: usize = 0;
var test_ptr_last_buttons: u8 = 0;
fn test_pointer_hook(rep: []const u8) void {
    test_ptr_calls += 1;
    test_ptr_last_len = rep.len;
    if (rep.len >= 1) test_ptr_last_buttons = rep[0];
}

test "virtio_custom: payload is the 16-byte known string, reply cap 64, big payload 12340" {
    try std.testing.expectEqual(@as(usize, 16), payload.len);
    init_payload();
    try std.testing.expectEqualStrings("VIRELAIOS-CV0x42", &payload);
    try std.testing.expectEqual(@as(usize, 64), reply_cap);
    try std.testing.expectEqual(@as(usize, 12340), big_payload_len);
    try std.testing.expectEqual(@as(u32, 0x1082), custom_did);
    try std.testing.expectEqual(@as(u32, 0x42), custom_device_id);
    try std.testing.expectEqual(@as(u64, 0x10000), bar_window_len);
}

test "virtio_custom: ring shapes match the split-ring spec" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(VirtqDesc));
    // 2 flags + 2 idx + 32x2 ring + 2 used_event = 70
    try std.testing.expectEqual(@as(usize, 70), @sizeOf(VirtqAvail));
    // 2 flags + 2 idx + 32x8 ring + 2 avail_event = 262, aligned to 4
    // (the u32 used-entry fields) -> 264
    try std.testing.expectEqual(@as(usize, 264), @sizeOf(VirtqUsed));
    try std.testing.expectEqual(@as(u16, 32), queue_size); // power of two
    try std.testing.expectEqual(@as(u16, 2), queue_count);
}

test "virtio_custom: feature bits are the spec's ANY_LAYOUT / VERSION_1 / NOTIFICATION_DATA" {
    try std.testing.expectEqual(@as(u64, 1) << 27, vq_feature_any_layout);
    try std.testing.expectEqual(@as(u64, 1) << 32, vq_feature_version_1);
    try std.testing.expectEqual(@as(u64, 1) << 38, vq_feature_notification_data);
}

test "virtio_custom: allocator hands out chains, recycles freed indices, and exhausts" {
    var r: VirtqRing = undefined;
    ring_init(&r);
    try std.testing.expectEqual(@as(u16, 32), r.free_count);
    // The free list is a LIFO initialized REVERSED (low indices on top):
    // the first 2-chain pops 0 then 1 -> head 0 (next 1); the second pops
    // 2 then 3 -> head 2 (next 3).
    const h0 = alloc_chain(&r, 2).?;
    try std.testing.expectEqual(@as(u16, 0), h0);
    try std.testing.expectEqual(@as(u16, 1), r.desc[h0].next);
    try std.testing.expect((r.desc[h0].flags & vq_next) != 0);
    try std.testing.expect((r.desc[1].flags & vq_next) == 0);
    try std.testing.expectEqual(@as(u16, 30), r.free_count);
    const h1 = alloc_chain(&r, 2).?;
    try std.testing.expectEqual(@as(u16, 2), h1);
    try std.testing.expectEqual(@as(u16, 28), r.free_count);
    // Free both (LAST-freed chain's head is on top of the LIFO stack, so
    // free in reverse order) and the SAME head indices come back
    // (deterministic recycle: chains are pushed tail-first so heads pop
    // first again).
    free_chain(&r, h1);
    free_chain(&r, h0);
    try std.testing.expectEqual(@as(u16, 32), r.free_count);
    const h0b = alloc_chain(&r, 2).?;
    const h1b = alloc_chain(&r, 2).?;
    try std.testing.expectEqual(h0, h0b);
    try std.testing.expectEqual(h1, h1b);
    // Exhaustion: alloc everything, then one more fails honestly.
    var used: usize = 0;
    while (alloc_chain(&r, 1)) |_| used += 1;
    try std.testing.expectEqual(@as(usize, 28), used);
    try std.testing.expectEqual(@as(u16, 0), r.free_count);
    try std.testing.expect(alloc_chain(&r, 1) == null);
    try std.testing.expect(alloc_chain(&r, 0) == null);
}

test "virtio_custom: post_avail builds the spec-correct chain (read-then-write)" {
    var r: VirtqRing = undefined;
    ring_init(&r);
    var payload_buf: [16]u8 align(16) = undefined;
    var reply_buf: [64]u8 align(16) = undefined;
    const head = alloc_chain(&r, 2).?;
    post_avail(&r, head, &.{payload_buf[0..]}, reply_buf[0..], false);
    try std.testing.expectEqual(head, r.avail.ring[0]); // the head descriptor index
    try std.testing.expectEqual(@as(u16, 1), r.avail.idx);
    try std.testing.expectEqual(@intFromPtr(&payload_buf), r.desc[head].addr);
    try std.testing.expectEqual(@as(u32, 16), r.desc[head].len);
    try std.testing.expect((r.desc[head].flags & vq_next) != 0);
    try std.testing.expect((r.desc[head].flags & vq_write) == 0);
    const tail = r.desc[head].next;
    try std.testing.expectEqual(@intFromPtr(&reply_buf), r.desc[tail].addr);
    try std.testing.expectEqual(@as(u32, 64), r.desc[tail].len);
    try std.testing.expect((r.desc[tail].flags & vq_write) != 0);
    try std.testing.expect((r.desc[tail].flags & vq_next) == 0);
}

test "virtio_custom: post_avail builds an ANY_LAYOUT chain (write first) with a 3-part scatter" {
    var r: VirtqRing = undefined;
    ring_init(&r);
    var p0: [4096]u8 align(16) = undefined;
    var p1: [4096]u8 align(16) = undefined;
    var p2: [4148]u8 align(16) = undefined;
    var reply_buf: [12340]u8 align(16) = undefined;
    const head = alloc_chain(&r, 4).?;
    post_avail(&r, head, &.{ p0[0..], p1[0..], p2[0..] }, reply_buf[0..], true);
    // Head = the write reply descriptor; the three reads follow.
    try std.testing.expect((r.desc[head].flags & vq_write) != 0);
    try std.testing.expectEqual(@intFromPtr(&reply_buf), r.desc[head].addr);
    const rd0 = r.desc[head].next;
    const rd1 = r.desc[rd0].next;
    const rd2 = r.desc[rd1].next;
    try std.testing.expectEqual(@intFromPtr(&p0), r.desc[rd0].addr);
    try std.testing.expectEqual(@intFromPtr(&p1), r.desc[rd1].addr);
    try std.testing.expectEqual(@intFromPtr(&p2), r.desc[rd2].addr);
    try std.testing.expect((r.desc[rd2].flags & vq_write) == 0);
    try std.testing.expect((r.desc[rd2].flags & vq_next) == 0);
}

test "virtio_custom: scan_used matches by id, handles out-of-order completion, wraps" {
    var r: VirtqRing = undefined;
    ring_init(&r);
    var reply_buf: [16]u8 = undefined;
    // Simulate three in-flight elements (heads 30, 28, 26) completing in
    // one burst, out of order: used.idx = 3, entries 26, 30, 28.
    r.used.ring[0] = .{ .id = 26, .len = 16 };
    r.used.ring[1] = .{ .id = 30, .len = 16 };
    r.used.ring[2] = .{ .id = 28, .len = 16 };
    r.used.idx = 3;
    // Waiting for 30: the first entry (26) is consumed and skipped.
    const n = scan_used(&r, 30, 100, reply_buf[0..]).?;
    try std.testing.expectEqual(@as(u32, 16), n);
    try std.testing.expectEqual(@as(u16, 2), r.last_used);
    // Now 28.
    const n2 = scan_used(&r, 28, 100, reply_buf[0..]).?;
    try std.testing.expectEqual(@as(u32, 16), n2);
    try std.testing.expectEqual(@as(u16, 3), r.last_used);
    // The leftover 26 was consumed while scanning for 30; a fresh wait for
    // it finds nothing (budget exhausted).
    try std.testing.expect(scan_used(&r, 26, 10, reply_buf[0..]) == null);
    // u16 idx wrap: used.idx wrapping 0xffff -> 0 is still a 1-entry
    // advance and the entry is found at its slot (0xfffe % 32 = 30).
    ring_init(&r);
    r.last_used = 0xfffe;
    r.used.ring[30] = .{ .id = 4, .len = 7 };
    r.used.idx = 0;
    const n3 = scan_used(&r, 4, 100, reply_buf[0..]).?;
    try std.testing.expectEqual(@as(u32, 7), n3);
}

test "virtio_custom: park_chain keeps a timed-out head out of the free list until reap_parked sees its reply" {
    parked_count = 0;
    // Real-flow balance: two chains were ALLOCATED from the file ring
    // (free_count dropped), then their exchanges timed out and parked
    // them (never freed back).
    cv_ready = true;
    const rr = &cv_rings[file_qidx];
    ring_init(rr);
    rr.armed = true;
    const p1 = alloc_chain(rr, 1).?;
    const p2 = alloc_chain(rr, 1).?;
    park_chain(p1);
    park_chain(p2);
    try std.testing.expectEqual(@as(u16, 2), parked_count);
    // Parked heads are out of the free pool: the next allocation returns a
    // DIFFERENT head — the host's late reply can never be misattributed.
    const fresh = alloc_chain(rr, 1).?;
    try std.testing.expect(fresh != p1 and fresh != p2);
    // The host's late replies arrive: used ring gains entries p1 then p2.
    rr.used.ring[0] = .{ .id = p1, .len = 3 };
    rr.used.ring[1] = .{ .id = p2, .len = 3 };
    rr.used.idx = 2;
    const free_before = rr.free_count;
    reap_parked();
    // Both parked heads reaped: freed back into the pool, list empty,
    // last_used consumed both entries (and nothing else).
    try std.testing.expectEqual(@as(u16, 0), parked_count);
    try std.testing.expectEqual(@as(u16, 2), rr.last_used);
    try std.testing.expectEqual(free_before + 2, rr.free_count);
    // An empty parked list is a no-op; a full list degrades to a leak
    // (never freed, never recycled — corruption-free either way).
    parked_count = 0;
    reap_parked();
    try std.testing.expectEqual(@as(u16, 0), parked_count);
    for (&parked_heads) |*h| h.* = 1;
    parked_count = parked_heads.len;
    park_chain(99);
    try std.testing.expectEqual(parked_heads.len, parked_count);
    parked_count = 0;
    cv_ready = false;
}

test "virtio_custom: wait reaps a consumed parked head; a fabricated id is only counted (#2495)" {
    cv_ready = true;
    defer cv_ready = false;
    const rr = &cv_rings[file_qidx];
    ring_init(rr);
    rr.armed = true;
    const saved_armed = armed_queues;
    defer armed_queues = saved_armed;
    armed_queues = file_qidx + 1;
    parked_count = 0;
    stale_used_count = 0;
    // A parked 2-desc chain (its reply never arrived) ahead of the live
    // element the wait is for — the congestion shape from the card.
    const p1 = alloc_chain(rr, 2).?;
    park_chain(p1);
    const live = alloc_chain(rr, 2).?;
    rr.used.ring[0] = .{ .id = p1, .len = 0 };
    rr.used.ring[1] = .{ .id = live, .len = 7 };
    rr.used.idx = 2;
    var reply_buf: [16]u8 = undefined;
    const n = wait(file_qidx, live, 100, reply_buf[0..]).?;
    try std.testing.expectEqual(@as(u32, 7), n);
    // The consumed parked entry was reaped AT the consume point: chain
    // freed, list empty, both descriptors back in the pool (the previous
    // shape left it parked forever — every park leaked two descriptors).
    try std.testing.expectEqual(@as(u16, 0), parked_count);
    try std.testing.expectEqual(@as(u16, queue_size - 2), rr.free_count);
    try std.testing.expectEqual(@as(u32, 0), stale_used_count);
    // A fabricated id — no live element, no parked head — is consumed and
    // counted, never attributed and never freed.
    rr.used.ring[2] = .{ .id = 31, .len = 1 };
    rr.used.idx = 3;
    try std.testing.expect(wait(file_qidx, 4, 50, reply_buf[0..]) == null);
    try std.testing.expectEqual(@as(u32, 1), stale_used_count);
    try std.testing.expectEqual(@as(u16, queue_size - 2), rr.free_count);
    cv_rings[file_qidx].armed = false;
}

test "virtio_custom: neutralize_chain repoints a posted chain at the sink buffers (#2495)" {
    const rr = &cv_rings[file_qidx];
    ring_init(rr);
    rr.armed = true;
    const saved_armed = armed_queues;
    defer armed_queues = saved_armed;
    armed_queues = file_qidx + 1;
    var req_buf: [32]u8 align(16) = @splat(0xaa);
    var rep_buf: [64]u8 align(16) = @splat(0xbb);
    var sink_req: [20]u8 align(16) = @splat(0);
    var sink_rep: [64]u8 align(16) = @splat(0);
    const head = alloc_chain(rr, 2).?;
    post_avail(rr, head, &.{req_buf[0..]}, rep_buf[0..], false);
    neutralize_chain(file_qidx, head, sink_req[0..], sink_rep[0..]);
    // The chain shape (NEXT/WRITE flags, next links) is preserved; every
    // descriptor's address+length now names the sinks, so a late serve
    // can neither read a live request buffer nor write a live reply one.
    const rd = rr.desc[head];
    try std.testing.expectEqual(mmu.to_phys(@intFromPtr(&sink_req)), rd.addr);
    try std.testing.expectEqual(@as(u32, 20), rd.len);
    try std.testing.expect((rd.flags & vq_next) != 0);
    try std.testing.expect((rd.flags & vq_write) == 0);
    const td = rr.desc[rd.next];
    try std.testing.expectEqual(mmu.to_phys(@intFromPtr(&sink_rep)), td.addr);
    try std.testing.expectEqual(@as(u32, 64), td.len);
    try std.testing.expect((td.flags & vq_write) != 0);
    try std.testing.expectEqual(@as(u16, 0), td.next);
    cv_rings[file_qidx].armed = false;
}

test "virtio_custom: the reply read is length-driven, clamped to the buffer" {
    used_len = 16;
    current_reply_len = 64;
    try std.testing.expectEqual(@as(usize, 16), reply_len());
    used_len = 0;
    try std.testing.expectEqual(@as(usize, 0), reply_len());
    used_len = 0xffffffff;
    try std.testing.expectEqual(@as(usize, 64), reply_len());
    current_reply_len = 8;
    used_len = 16;
    try std.testing.expectEqual(@as(usize, 8), reply_len());
    used_len = 0;
    current_reply_len = 0;
}

test "virtio_custom: fresh transport reports no-device honestly" {
    // The module defaults must describe an unarmed transport so a default
    // build's call to init() is a silent no-op and the API refuses.
    cv_ready = false;
    cv_dev = 32;
    cv_common = 0;
    cv_notify = 0;
    try std.testing.expect(!cv_ready);
    try std.testing.expect(!init()); // cv_common == 0 -> honest no-op
    var payload_buf: [16]u8 = undefined;
    var reply_buf: [64]u8 = undefined;
    try std.testing.expect(submit(payload_buf[0..], reply_buf[0..]) == null); // unarmed
    try std.testing.expect(!cvlog_puts("nope")); // queue 1 unarmed
    try std.testing.expect(!arm_push()); // push queue unavailable
    try std.testing.expect(wait_any_push(10) == null);
    try std.testing.expect(!has_input_queue); // four-queue device absent
    try std.testing.expect(!arm_input_pool()); // input queue unavailable
    try std.testing.expect(!input_armed);
    poll_input(); // honest no-op on an unarmed transport
    reset_irq_observation();
    try std.testing.expectEqual(@as(u32, 0), irq_count[0]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), irq_first[0]);
    try std.testing.expectEqual(@as(u32, 0), used_len);
    try std.testing.expectEqual(@as(usize, 0), reply_len());
}

test "virtio_custom: note_irq records the first INTID and count" {
    reset_irq_observation();
    note_irq(69);
    note_irq(69);
    try std.testing.expectEqual(@as(u32, 2), irq_count[0]);
    try std.testing.expectEqual(@as(u32, 69), irq_first[0]);
}

test "virtio_custom: push-echo shapes (claim 3141) — queue index, buffer sizes" {
    // The push queue rides ONE past the classic pair; the rx buffer is one
    // descriptor of capacity 16 and the request is exactly 13 bytes
    // ("CVC-PING-0x42").
    try std.testing.expectEqual(@as(u16, 2), push_qidx);
    // The probe depth now covers the claim-0680 snapshot queue AND the
    // M34 file-channel queue (issues #735/#736); the push queue sits three
    // below the file queue.
    try std.testing.expectEqual(push_qidx + 1, input_qidx);
    try std.testing.expectEqual(@as(u16, 6), max_queue_probe);
    try std.testing.expectEqual(@as(u16, 5), file_qidx);
    try std.testing.expect(push_buf_len >= push_req_len);
    try std.testing.expectEqual(@as(usize, 16), push_rx_buf.len);
}

test "virtio_custom: input-channel shapes (claim 9588) — queue index, envelope, pool" {
    // The input queue rides at index 3 (four-queue --via-virtio device);
    // the envelope is a fixed 16 bytes carrying an 8-byte HID report.
    try std.testing.expectEqual(@as(u16, 3), input_qidx);
    try std.testing.expectEqual(@as(u16, 6), max_queue_probe);
    try std.testing.expectEqual(@as(usize, 16), input_msg_len);
    try std.testing.expectEqual(@as(usize, 8), input_keyboard_rep_len);
    try std.testing.expectEqual(@as(u8, 1), input_kind_keyboard);
    try std.testing.expectEqual(@as(u8, 2), input_kind_pointer);
    try std.testing.expectEqual(@as(usize, 5), input_pointer_rep_len);
    try std.testing.expect(input_buf_cap >= input_msg_len);
    try std.testing.expectEqual(@as(usize, 32), input_buf_cap);
    try std.testing.expectEqual(@as(usize, 8), input_pool_count);
    try std.testing.expectEqual(@as(usize, 32), input_rx_bufs[0].len);
}

test "virtio_custom: dispatch_input_msg validates the envelope and counts honestly" {
    var msg: [input_msg_len]u8 align(16) = undefined;
    const report = [input_keyboard_rep_len]u8{ 0x02, 0, 0x04, 0, 0, 0, 0, 0 }; // Shift+a
    msg[0] = input_kind_keyboard;
    msg[1] = 0;
    msg[2] = @intCast(input_keyboard_rep_len & 0xff);
    msg[3] = 0;
    @memcpy(msg[4 .. 4 + input_keyboard_rep_len], &report);

    // The hook records into module-level BSS (a Zig 0.17 nested function
    // cannot capture mutable locals).
    on_input_report = &test_input_hook;
    defer on_input_report = null;
    test_hook_calls = 0;
    test_hook_last_len = 0;
    input_rx_count = 0;
    input_bad_count = 0;

    dispatch_input_msg(&msg); // valid
    try std.testing.expectEqual(@as(u32, 1), input_rx_count);
    try std.testing.expectEqual(@as(u32, 0), input_bad_count);
    try std.testing.expectEqual(@as(usize, 1), test_hook_calls);
    try std.testing.expectEqual(@as(usize, 8), test_hook_last_len);

    msg[0] = 7; // unknown kind
    dispatch_input_msg(&msg);
    try std.testing.expectEqual(@as(u32, 1), input_rx_count);
    try std.testing.expectEqual(@as(u32, 1), input_bad_count);

    msg[0] = input_kind_keyboard;
    msg[1] = 0;
    msg[2] = 7; // wrong payload length
    dispatch_input_msg(&msg);
    try std.testing.expectEqual(@as(u32, 2), input_bad_count);

    msg[2] = 8;
    msg[1] = 9; // reserved flags nonzero
    dispatch_input_msg(&msg);
    try std.testing.expectEqual(@as(u32, 3), input_bad_count);

    dispatch_input_msg(msg[0..3]); // truncated envelope
    try std.testing.expectEqual(@as(u32, 4), input_bad_count);
    try std.testing.expectEqual(@as(u32, 1), input_rx_count);
    try std.testing.expectEqual(@as(usize, 1), test_hook_calls);
    input_rx_count = 0;
    input_bad_count = 0;
}

test "virtio_custom: kind-2 pointer messages dispatch through the pointer hook (claim 9367)" {
    var msg: [input_msg_len]u8 align(16) = undefined;
    // Absolute-pointer report: button 1 down at logical (24576, 4551)
    // — guest pixels (960, 100) on the 1280x720 framebuffer.
    const rep = [input_pointer_rep_len]u8{ 0x01, 0x00, 0x60, 0xa7, 0x11 };
    msg[0] = input_kind_pointer;
    msg[1] = 0;
    msg[2] = @intCast(input_pointer_rep_len & 0xff);
    msg[3] = 0;
    @memcpy(msg[4 .. 4 + input_pointer_rep_len], &rep);

    on_pointer_report = &test_pointer_hook;
    defer on_pointer_report = null;
    test_ptr_calls = 0;
    test_ptr_last_len = 0;
    test_ptr_last_buttons = 0;
    input_ptr_count = 0;
    input_bad_count = 0;

    dispatch_input_msg(&msg); // valid
    try std.testing.expectEqual(@as(u32, 1), input_ptr_count);
    try std.testing.expectEqual(@as(u32, 0), input_bad_count);
    try std.testing.expectEqual(@as(usize, 1), test_ptr_calls);
    try std.testing.expectEqual(@as(usize, 5), test_ptr_last_len);
    try std.testing.expectEqual(@as(u8, 0x01), test_ptr_last_buttons);

    // Wrong payload length (a keyboard-sized payload under a pointer
    // envelope) is malformed, not partially decoded.
    msg[2] = 8;
    dispatch_input_msg(&msg);
    try std.testing.expectEqual(@as(u32, 1), input_bad_count);
    try std.testing.expectEqual(@as(u32, 1), input_ptr_count);

    // Null hook still counts the message honestly.
    on_pointer_report = null;
    msg[2] = @intCast(input_pointer_rep_len & 0xff);
    dispatch_input_msg(&msg);
    try std.testing.expectEqual(@as(u32, 2), input_ptr_count);
    try std.testing.expectEqual(@as(usize, 1), test_ptr_calls);
    input_ptr_count = 0;
    input_bad_count = 0;
}

test "virtio_custom: checksum1071 matches RFC 1071 semantics" {
    // Zero data folds to the complement of zero.
    try std.testing.expectEqual(@as(u16, 0xffff), checksum1071(&[_]u8{ 0, 0, 0, 0 }));
    // Big-endian word pairing: {0x01,0x02,0x03,0x04} sums 0x0102+0x0304
    // = 0x0406 → complement 0xfbf9.
    try std.testing.expectEqual(@as(u16, 0xfbf9), checksum1071(&[_]u8{ 0x01, 0x02, 0x03, 0x04 }));
    // Odd length pads the trailing byte with zero: {0x01,0x02,0x03}
    // sums 0x0102 + 0x0300 = 0x0402 → complement 0xfbfd.
    try std.testing.expectEqual(@as(u16, 0xfbfd), checksum1071(&[_]u8{ 0x01, 0x02, 0x03 }));
    // Carry folding: 0xff00 + 0xff00 = 0x1fe00 → fold 0xfe01 → complement
    // 0x01fe.
    try std.testing.expectEqual(@as(u16, 0x01fe), checksum1071(&[_]u8{ 0xff, 0x00, 0xff, 0x00 }));
    // Whole-frame scale: 256 KiB of 0xff = 131072 words × 0xffff sums to
    // 0x1_FFFE_0000, which OVERFLOWS a u32 accumulator before folding
    // (observed live as a host-side Swift arithmetic-overflow trap,
    // claim 0680). Fold: 0x1_FFFE_0000 → 0x1_FFFE → 0xFFFF → complement
    // 0x0000 — a valid checksum of zero, exactly what the wire needs.
    const big_ff = @as([262144]u8, @splat(@as(u8, 0xff)));
    try std.testing.expectEqual(@as(u16, 0x0000), checksum1071(&big_ff));
}

test "virtio_custom: snapshot framing builders produce the documented wire shapes (claim 0680)" {
    const hdr = build_snap_header(1280, 720, 4, 3686400, 32768);
    try std.testing.expectEqual(@as(u8, snap_tag_header), hdr[0]);
    try std.testing.expectEqualStrings("SNAP", hdr[1..5]);
    try std.testing.expectEqual(@as(u8, 1), hdr[5]); // version
    try std.testing.expectEqual(@as(u8, 4), hdr[6]); // bpp
    try std.testing.expectEqual(@as(u64, 1280), @as(u64, hdr[8]) | (@as(u64, hdr[9]) << 8) | (@as(u64, hdr[10]) << 16) | (@as(u64, hdr[11]) << 24));
    try std.testing.expectEqual(@as(u64, 720), @as(u64, hdr[12]) | (@as(u64, hdr[13]) << 8) | (@as(u64, hdr[14]) << 16) | (@as(u64, hdr[15]) << 24));
    try std.testing.expectEqual(@as(u64, 3686400), @as(u64, hdr[16]) | (@as(u64, hdr[17]) << 8) | (@as(u64, hdr[18]) << 16) | (@as(u64, hdr[19]) << 24));
    try std.testing.expectEqual(@as(u64, 32768), @as(u64, hdr[20]) | (@as(u64, hdr[21]) << 8) | (@as(u64, hdr[22]) << 16) | (@as(u64, hdr[23]) << 24));
    for (hdr[24..32]) |b| try std.testing.expectEqual(@as(u8, 0), b);

    const chunk = build_snap_chunk(112, 32768, 0xbeef);
    try std.testing.expectEqual(@as(u8, snap_tag_chunk), chunk[0]);
    try std.testing.expectEqual(@as(u64, 112), @as(u64, chunk[2]) | (@as(u64, chunk[3]) << 8));
    try std.testing.expectEqual(@as(u64, 32768), @as(u64, chunk[4]) | (@as(u64, chunk[5]) << 8));
    try std.testing.expectEqual(@as(u64, 0xbeef), @as(u64, chunk[6]) | (@as(u64, chunk[7]) << 8));

    const done = build_snap_done(113, 3686400, 0x1234);
    try std.testing.expectEqual(@as(u8, snap_tag_done), done[0]);
    try std.testing.expectEqual(@as(u64, 113), @as(u64, done[2]) | (@as(u64, done[3]) << 8));
    try std.testing.expectEqual(@as(u64, 3686400), @as(u64, done[4]) | (@as(u64, done[5]) << 8) | (@as(u64, done[6]) << 16) | (@as(u64, done[7]) << 24));
    try std.testing.expectEqual(@as(u64, 0x1234), @as(u64, done[8]) | (@as(u64, done[9]) << 8));

    // Chunk-count arithmetic for the real scanout: ceil(3686400 / 32768).
    const total: usize = virtio_gpu.fb_size;
    try std.testing.expectEqual(@as(usize, 113), (total + snap_chunk_len - 1) / snap_chunk_len);
}

test "virtio_custom: snap completion receipt shape (run-03 serialization anchor)" {
    // The gate anchors the next request on `cvspike: snap n=N` — pin the
    // exact line so a rename fails the class-A build, not a live gate.
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("cvspike: snap n=1\n", build_snap_marker(1, &buf));
    try std.testing.expectEqualStrings("cvspike: snap n=113\n", build_snap_marker(113, &buf));
}

test "virtio_custom: kind-3 console control arms and disarms the tee (claim 0680)" {
    var msg: [input_msg_len]u8 align(16) = undefined;
    msg[0] = input_kind_console_ctrl;
    msg[1] = 0;
    msg[2] = @intCast(input_ctrl_rep_len & 0xff);
    msg[3] = 0;

    tee_enabled = false;
    tee_line_len = 0;
    input_ctrl_count = 0;
    input_bad_count = 0;

    msg[4] = 0x01; // bit0 = enable
    dispatch_input_msg(&msg);
    try std.testing.expectEqual(@as(bool, true), tee_enabled);
    try std.testing.expectEqual(@as(u32, 1), input_ctrl_count);
    try std.testing.expectEqual(@as(u32, 0), input_bad_count);
    try std.testing.expectEqual(@as(usize, 0), tee_line_len); // accumulator reset

    msg[4] = 0x00; // disable
    dispatch_input_msg(&msg);
    try std.testing.expectEqual(@as(bool, false), tee_enabled);
    try std.testing.expectEqual(@as(u32, 2), input_ctrl_count);

    // Wrong payload length is malformed, not a state change.
    msg[2] = 0;
    dispatch_input_msg(&msg);
    try std.testing.expectEqual(@as(bool, false), tee_enabled);
    try std.testing.expectEqual(@as(u32, 1), input_bad_count);
    input_ctrl_count = 0;
    input_bad_count = 0;
}

test "virtio_custom: kind-4 snapshot request pends for the idle seam (claim 0680)" {
    var msg: [input_msg_len]u8 align(16) = undefined;
    msg[0] = input_kind_snapshot_req;
    msg[1] = 0;
    msg[2] = 0;
    msg[3] = 0;

    snap_pending = false;
    input_bad_count = 0;
    dispatch_input_msg(&msg);
    try std.testing.expectEqual(@as(bool, true), snap_pending);
    try std.testing.expectEqual(@as(u32, 0), input_bad_count);

    // A non-empty payload under a snapshot envelope is malformed.
    msg[2] = 1;
    dispatch_input_msg(&msg);
    try std.testing.expectEqual(@as(u32, 1), input_bad_count);
    input_bad_count = 0;
}

test "virtio_custom: console tee accumulator buffers, splits, and drops (claim 0680)" {
    tee_enabled = true;
    cv_ready = true; // accumulate for real; sends still fail (rings unarmed)
    tee_line_len = 0;
    tee_drop_count = 0;
    defer cv_ready = false;

    // Bytes accumulate until newline; the flush attempt fails unarmed and
    // counts as a drop (loud-by-counter), leaving the accumulator empty.
    console_tee_putc('a');
    console_tee_putc('b');
    try std.testing.expectEqual(@as(usize, 2), tee_line_len);
    console_tee_putc('\n');
    try std.testing.expectEqual(@as(usize, 0), tee_line_len);
    try std.testing.expectEqual(@as(u32, 1), tee_drop_count);

    // Overflow forces a split exactly at the capacity boundary: byte 257
    // triggers one failed (unarmed) flush of the full 256-byte line —
    // counted as a drop — then lands in the emptied accumulator; the
    // remaining 7 bytes follow.
    tee_drop_count = 0;
    var i: usize = 0;
    while (i < tee_line_cap + 8) : (i += 1) console_tee_putc('x');
    try std.testing.expectEqual(@as(usize, 8), tee_line_len);
    try std.testing.expectEqual(@as(u32, 1), tee_drop_count);

    // Disarmed putc is a cheap no-op.
    tee_enabled = false;
    tee_line_len = 0;
    tee_drop_count = 0;
    console_tee_putc('z');
    try std.testing.expectEqual(@as(usize, 0), tee_line_len);
    try std.testing.expectEqual(@as(u32, 0), tee_drop_count);
    tee_enabled = false;
}

test "virtio_custom: M97e-D2 (#2100) — wait_any_push returns the used length clamped to the rx buffer" {
    // The used-ring length is host-controlled. A hostile completion that
    // over-reports (0xffffffff on a 16-byte armed buffer) must surface as
    // push_buf_len — not the raw count — so no caller can copy or parse
    // past push_rx_buf. `used_len` keeps the RAW report for diagnostics.
    cv_ready = true;
    has_push_queue = true;
    const r = &cv_rings[push_qidx];
    ring_init(r);
    r.armed = true;
    push_rx_handle = 9;
    defer {
        cv_ready = false;
        has_push_queue = false;
        r.armed = false;
    }
    r.used.ring[0] = .{ .id = push_rx_handle, .len = std.math.maxInt(u32) };
    r.used.idx = 1;
    const rx = wait_any_push(4).?;
    try std.testing.expectEqual(push_rx_handle, rx.handle);
    try std.testing.expect(rx.len <= push_buf_len);
    try std.testing.expectEqual(@as(u32, push_buf_len), rx.len);
    try std.testing.expectEqual(std.math.maxInt(u32), used_len); // raw report kept
}
