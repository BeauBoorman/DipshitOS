//! VirelaiOS Generic Interrupt Controller (claims 7948/9187 — roadmap
//! item 5's remaining half; claim 9746 supplied the IRQ vector).
//!
//! Two phases, split by the ExitBootServices boundary:
//!
//! 1. DISCOVERY (PRE-EXIT, `discover`): parse the ACPI MADT (signature
//!    "APIC") for the GIC CPU interface (GICC, type 0x0B, base @+32),
//!    distributor (GICD, type 0x0C, base @+8, version @+20), and GICv3
//!    redistributor range (GICR, type 0x0E, discovery base @+4). The bases
//!    and version land in module globals so the kernel can program the
//!    controller AFTER the identity-map switch, when it owns EL1. ACPI
//!    reads are pre-exit only on VZ (claim 0013: post-exit window reads
//!    hang) — the values are captured, never re-read.
//!
//! 2. PROGRAMMING (POST-MMU, `init`): distributor + redistributor/CPU
//!    interface configuration, and the ack/EOI pair the IRQ handler uses.
//!    GICv3 uses the system-register CPU interface (ICC_SRE_EL1 /
//!    ICC_PMR_EL1 / ICC_IGRPEN1_EL1 / ICC_IAR1_EL1 / ICC_EOIR1_EL1);
//!    GICv2 programs the GICC MMIO window. Only the EL1 physical timer
//!    PPI (conventionally 30, discovered from the GTDT by timer.zig) is
//!    enabled — nothing else should ever fire on this platform.
//!
//! The module never touches the console: `dispatch` (ack -> caller's timer
//! handling -> eoi) runs in IRQ context with a register frame on the stack,
//! so printing there would re-enter the polled virtio TX path mid-flush.
//! The timer heartbeat is printed from the shell idle loop instead.
//!
//! Claim 7948's negative result programmed SGI/PPI registers at the
//! redistributor RD-frame offsets (for example GICR+0x80). In GICv3 those
//! registers live in the SGI frame at GICR+0x10000 (IGROUPR0=0x10080,
//! ISENABLER0=0x10100, ICFGR1=0x10c04). Reading the RD-frame holes naturally
//! returned zero and writes were ignored, so that evidence did not prove a
//! VZ GIC stub. Claim 9187 corrects the frame and the ACPI entry types; a
//! real timer PPI is now observed end to end through the EL1 IRQ vector.
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");
const builtin = @import("builtin");
const mmio = @import("mmio.zig");

// ---------------------------------------------------------------------------
// Discovery result
// ---------------------------------------------------------------------------

pub const GicKind = enum { none, v2, v3 };

/// Interrupt controller discovered from the MADT (pre-exit). `.none` until
/// `discover` runs (and stays `.none` in host test processes, where the
/// programming path must never execute EL1 instructions).
pub var kind: GicKind = .none;
/// GIC distributor (GICD) physical base.
pub var dist_base: u64 = 0;
/// GICv3 redistributor (GICR) base — CPU0's frame is at base+0x0000.
pub var redist_base: u64 = 0;
/// GICv2 CPU interface (GICC) physical base.
pub var cpu_base: u64 = 0;
/// True when firmware discovery did not yield a usable controller and the
/// Apple VZ fixed-layout fallback supplied the bases.
pub var used_fallback: bool = false;
/// The MADT GICD "GIC Version" byte (0 = unspecified, 1 = v1, 2 = v2,
/// 3 = v3, 4 = v4). Used with the presence of GICR/GICC entries to pick the
/// programming path.
var version_byte: u8 = 0;

/// Redistributor frame selected for the boot CPU. This is the RD-frame
/// base; SGI/PPI registers are at `active_redist_base + 0x10000`.
pub var active_redist_base: u64 = 0;

pub fn kind_name() []const u8 {
    return switch (kind) {
        .none => "none",
        .v2 => "v2",
        .v3 => "v3",
    };
}

/// Apple VZ platform layout (fallback when the MADT is non-conformant).
/// Evidence: the VZ guest device tree (`arm,gic-v3`, reg GICD 0x10000000 /
/// GICR 0x10010000 — observed in the wild) and live register probes on
/// this codebase's VZ runs: GICD_CTLR=0x50 and GICD_TYPER=0x0478001f.
/// This remains only a fallback for absent/malformed firmware data. VZ's
/// current MADT still requires it (`fallback=1`, claim 9187 live evidence).
const vz_dist_base: u64 = 0x10000000;
const vz_redist_base: u64 = 0x10010000;

// ACPI 6.5 MADT ARM structure types. Claim 7948 used 0x0B as GICD and
// shifted every later type down by one; 0x0B is actually the per-CPU GICC.
const madt_gicc: u8 = 0x0b;
const madt_gicd: u8 = 0x0c;
const madt_gic_msi_frame: u8 = 0x0d;
const madt_gicr: u8 = 0x0e;
const madt_gic_its: u8 = 0x0f;

// GICv3 redistributor frame layout. Apple's public Hypervisor.framework
// headers expose the same architectural offsets (hv_gic_types.h).
const gicr_sgi_frame_offset: u64 = 0x10000;
const gicr_frame_stride: u64 = 0x20000;
const gicr_vlpi_frame_stride: u64 = 0x40000;
const gicr_typer: u64 = 0x0008;
const gicr_waker: u64 = 0x0014;
const gicr_igroup0: u64 = 0x10080;
const gicr_isenabler0: u64 = 0x10100;
const gicr_icenabler0: u64 = 0x10180;
const gicr_icpendr0: u64 = 0x10280;
const gicr_icactiver0: u64 = 0x10380;
const gicr_ipriority0: u64 = 0x10400;
const gicr_icfgr0: u64 = 0x10c00;

// ---------------------------------------------------------------------------
// Discovery (PRE-EXIT; called from the pci.zig ACPI walk on the APIC table)
// ---------------------------------------------------------------------------

/// Read an 8-byte little-endian field with two 32-bit reads (safe at any
/// alignment, on Normal RAM and in host test fixtures alike).
fn read64(addr: u64) u64 {
    const lo = mmio.mmio_read32(addr);
    const hi = mmio.mmio_read32(addr + 4);
    return lo | (@as(u64, hi) << 32);
}

/// Parse the MADT (sig "APIC") at `madt_addr` for GICD/GICR/GICC entries.
/// Entries start at offset 36 (the 36-byte ACPI header). Host-testable
/// against a RAM fixture; on the kernel this runs pre-exit only.
pub fn discover(madt_addr: u64, madt_len: u32) void {
    dist_base = 0;
    redist_base = 0;
    cpu_base = 0;
    version_byte = 0;
    used_fallback = false;
    active_redist_base = 0;
    kind = .none;
    if (madt_addr != 0 and madt_len > 36) {
        var off: u32 = 36;
        while (off + 2 <= madt_len) {
            const entry_type = mmio.mmio_read8(madt_addr + off);
            const entry_len = mmio.mmio_read8(madt_addr + off + 1);
            if (entry_len < 2) break;
            switch (entry_type) {
                madt_gicc => { // GICC: v2 CPU interface @+32; optional per-CPU GICR @+60
                    if (entry_len >= 40 and cpu_base == 0)
                        cpu_base = read64(madt_addr + off + 32);
                    if (entry_len >= 68 and redist_base == 0)
                        redist_base = read64(madt_addr + off + 60);
                },
                madt_gicd => { // GICD: distributor @+8, version @+20
                    if (entry_len >= 21) {
                        dist_base = read64(madt_addr + off + 8);
                        version_byte = mmio.mmio_read8(madt_addr + off + 20);
                    }
                },
                madt_gicr => { // GICR: redistributor discovery range @+4
                    if (entry_len >= 16)
                        redist_base = read64(madt_addr + off + 4);
                },
                madt_gic_msi_frame, madt_gic_its => {},
                else => {},
            }
            off += entry_len;
        }
        // Version byte is authoritative when it names a generation;
        // otherwise infer from which CPU-interface structures are present
        // (a GICv3 MADT still lists GICC entries with base 0 — the v3
        // interface is the system registers — so GICR presence wins over
        // GICC).
        kind = switch (version_byte) {
            0x01, 0x02 => .v2,
            0x03, 0x04 => .v3,
            else => if (redist_base != 0) .v3 else if (cpu_base != 0) .v2 else .none,
        };
    }
    // Apple VZ fallback when firmware did not describe a usable controller.
    if (kind == .none or dist_base == 0 or
        (kind == .v3 and redist_base == 0) or
        (kind == .v2 and cpu_base == 0))
    {
        used_fallback = true;
        kind = .v3;
        dist_base = vz_dist_base;
        redist_base = vz_redist_base;
        cpu_base = 0;
        version_byte = 0x03;
    }
}

// ---------------------------------------------------------------------------
// Programming (POST-MMU, kernel owns EL1; aarch64 only)
// ---------------------------------------------------------------------------

var programmed: bool = false;
/// True once `init` has programmed the controller (only inside the kernel;
/// a host test process must never touch GIC registers).
pub fn armed() bool {
    return programmed;
}

/// Program the discovered controller: distributor, per-CPU interface, and
/// the EL1 physical-timer PPI (its number comes from timer.zig's GTDT
/// discovery). Does NOT unmask IRQs — the kernel does that after everything
/// (including the timer) is armed.
pub fn init(private_intid: u32, edge_triggered: bool) void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (kind == .none) return;
    if (private_intid < 16 or private_intid > 31) return;
    switch (kind) {
        .v3 => init_v3(private_intid, edge_triggered),
        .v2 => init_v2(private_intid, edge_triggered),
        .none => {},
    }
    programmed = true;
    configure_local_interrupt(profile_update_sgi, true);
}

/// Program the GIC CPU interface and local redistributor for a secondary CPU core.
pub fn init_secondary(private_intid: u32, edge_triggered: bool) void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (kind != .v3) return;
    const rbase = select_redist_frame();
    // GICR_WAKER: wake the redistributor
    var waker = mmio.mmio_read32(rbase + gicr_waker);
    waker &= ~@as(u32, 1);
    mmio.mmio_write32(rbase + gicr_waker, waker);
    var spins: usize = 0;
    while ((mmio.mmio_read32(rbase + gicr_waker) & 2) != 0 and spins < 100_000) : (spins += 1) {}

    const bit: u32 = @as(u32, 1) << @as(u5, @intCast(private_intid));
    mmio.mmio_write32(rbase + gicr_icenabler0, bit);
    mmio.mmio_write32(rbase + gicr_icpendr0, bit);
    mmio.mmio_write32(rbase + gicr_icactiver0, bit);
    var igroup = mmio.mmio_read32(rbase + gicr_igroup0);
    igroup |= bit;
    mmio.mmio_write32(rbase + gicr_igroup0, igroup);
    wait_rwp(rbase);

    // Enable SGIs (INTID 0..15) in Group 1
    var sgi_igroup = mmio.mmio_read32(rbase + gicr_igroup0);
    sgi_igroup |= 0xFFFF;
    mmio.mmio_write32(rbase + gicr_igroup0, sgi_igroup);
    mmio.mmio_write32(rbase + gicr_isenabler0, 0xFFFF);
    wait_rwp(rbase);

    // Priority for private intid
    const priority_word = private_intid / 4;
    const priority_shift: u5 = @intCast((private_intid % 4) * 8);
    const priority_addr = rbase + gicr_ipriority0 + @as(u64, priority_word) * 4;
    var priority = mmio.mmio_read32(priority_addr);
    priority &= ~(@as(u32, 0xff) << priority_shift);
    priority |= @as(u32, 0x80) << priority_shift;
    mmio.mmio_write32(priority_addr, priority);
    wait_rwp(rbase);

    const icfgr_addr = rbase + gicr_icfgr0 + @as(u64, private_intid / 16) * 4;
    const icfg = private_icfgr(mmio.mmio_read32(icfgr_addr), private_intid, edge_triggered);
    mmio.mmio_write32(icfgr_addr, icfg);
    wait_rwp(rbase);
    mmio.mmio_write32(rbase + gicr_isenabler0, bit);
    wait_rwp(rbase);

    // CPU interface via system registers (GICv3)
    var sre: u64 = 0;
    asm volatile ("mrs %[v], icc_sre_el1"
        : [v] "=r" (sre),
    );
    sre |= 1;
    asm volatile ("msr icc_sre_el1, %[v]"
        :
        : [v] "r" (sre),
    );
    asm volatile ("msr icc_pmr_el1, %[v]"
        :
        : [v] "r" (@as(u64, 0xff)),
    );
    asm volatile ("msr icc_igrpen1_el1, %[v]"
        :
        : [v] "r" (@as(u64, 1)),
    );
    asm volatile ("dsb sy");
    asm volatile ("isb");
    configure_local_interrupt(profile_update_sgi, true);
}

/// Private to the sampler: an SGI applies an enable/disable on every PE.
/// It never schedules, acquires a service lock, or modifies the physical PPI.
pub const profile_update_sgi: u32 = 3;
pub const profile_ppi: u32 = 27;
var prefetched: [4]?u32 = @as([4]?u32, @splat(@as(?u32, null)));

pub fn configure_local_interrupt(intid: u32, enabled: bool) void {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    if (kind != .v3 or intid > 31) return;
    const rbase = select_redist_frame();
    const bit = @as(u32, 1) << @as(u5, @intCast(intid));
    mmio.mmio_write32(rbase + gicr_icenabler0, bit);
    if (!enabled) {
        wait_rwp(rbase);
        return;
    }
    mmio.mmio_write32(rbase + gicr_igroup0, mmio.mmio_read32(rbase + gicr_igroup0) | bit);
    const addr = rbase + gicr_ipriority0 + @as(u64, intid / 4) * 4;
    const shift: u5 = @intCast((intid % 4) * 8);
    var priority = mmio.mmio_read32(addr);
    priority = (priority & ~(@as(u32, 255) << shift)) | (@as(u32, 0x80) << shift);
    mmio.mmio_write32(addr, priority);
    if (intid >= 16) {
        const cfg = rbase + gicr_icfgr0 + @as(u64, intid / 16) * 4;
        mmio.mmio_write32(cfg, private_icfgr(mmio.mmio_read32(cfg), intid, false));
    }
    mmio.mmio_write32(rbase + gicr_icpendr0, bit);
    wait_rwp(rbase);
    mmio.mmio_write32(rbase + gicr_isenabler0, bit);
    wait_rwp(rbase);
}

pub fn send_profile_update() void {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    if (kind != .v3) return;
    asm volatile ("dsb ishst");
    asm volatile ("msr icc_sgi1r_el1, %[v]"
        :
        : [v] "r" (@as(u64, profile_update_sgi) << 24 | @as(u64, 1) << 40),
    );
    asm volatile ("isb");
}

/// The vector needs the original frame for PPI 27. An ordinary interrupt
/// is handed to the existing zero-argument dispatcher without a second ack.
pub fn take_profile_interrupt() ?u32 {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return null;
    if (!programmed) return null;
    const intid = ack();
    if (intid == profile_ppi or intid == profile_update_sgi) return intid;
    prefetched[core_index()] = intid;
    return null;
}

fn current_affinity() u32 {
    var mpidr: u64 = 0;
    asm volatile ("mrs %[v], mpidr_el1"
        : [v] "=r" (mpidr),
    );
    return @as(u32, @intCast((mpidr & 0x00ffffff) | ((mpidr >> 8) & 0xff000000)));
}

/// Select the redistributor RD frame for the calling CPU core.
fn select_redist_frame() u64 {
    if (comptime builtin.cpu.arch != .aarch64) return redist_base;
    var mpidr: u64 = 0;
    asm volatile ("mrs %[v], mpidr_el1"
        : [v] "=r" (mpidr),
    );
    const cid: u64 = mpidr & 0xff;
    return redist_base + cid * gicr_frame_stride;
}

fn private_icfgr(value: u32, intid: u32, edge_triggered: bool) u32 {
    const shift: u5 = @intCast((intid % 16) * 2);
    var configured = value & ~(@as(u32, 0b11) << shift);
    // ICFGR field bit[1] is the trigger bit: 0=level, 1=edge. Bit[0] is
    // RES0. Claim 7948 set bit[0], which cannot request edge mode.
    if (edge_triggered) configured |= @as(u32, 0b10) << shift;
    return configured;
}

fn init_v3(private_intid: u32, edge_triggered: bool) void {
    // Distributor: enable Group 1 (bit 1) + Group 0 non-secure (bit 0).
    var ctlr = mmio.mmio_read32(dist_base + 0x0000);
    ctlr |= 0b11;
    mmio.mmio_write32(dist_base + 0x0000, ctlr);

    const rbase = select_redist_frame();
    active_redist_base = rbase;
    // GICR_WAKER: wake the redistributor (clear ProcessorSleep) and wait
    // for ChildrenAsleep to clear. Bounded: a stuck bit must not hang boot.
    var waker = mmio.mmio_read32(rbase + gicr_waker);
    waker &= ~@as(u32, 1);
    mmio.mmio_write32(rbase + gicr_waker, waker);
    var spins: usize = 0;
    while ((mmio.mmio_read32(rbase + gicr_waker) & 2) != 0 and spins < 100_000) : (spins += 1) {}

    const bit: u32 = @as(u32, 1) << @as(u5, @intCast(private_intid));
    // SGI/PPI registers are in the SGI frame at RD_base+0x10000.
    mmio.mmio_write32(rbase + gicr_icenabler0, bit);
    mmio.mmio_write32(rbase + gicr_icpendr0, bit);
    mmio.mmio_write32(rbase + gicr_icactiver0, bit);
    var igroup = mmio.mmio_read32(rbase + gicr_igroup0);
    igroup |= bit;
    mmio.mmio_write32(rbase + gicr_igroup0, igroup);
    wait_rwp(rbase);

    // Priority 0x80 (mid, below PMR=0xff so it passes). Use an aligned
    // word RMW rather than relying on byte MMIO behavior.
    const priority_word = private_intid / 4;
    const priority_shift: u5 = @intCast((private_intid % 4) * 8);
    const priority_addr = rbase + gicr_ipriority0 + @as(u64, priority_word) * 4;
    var priority = mmio.mmio_read32(priority_addr);
    priority &= ~(@as(u32, 0xff) << priority_shift);
    priority |= @as(u32, 0x80) << priority_shift;
    mmio.mmio_write32(priority_addr, priority);
    wait_rwp(rbase);

    const icfgr_addr = rbase + gicr_icfgr0 + @as(u64, private_intid / 16) * 4;
    const icfg = private_icfgr(mmio.mmio_read32(icfgr_addr), private_intid, edge_triggered);
    mmio.mmio_write32(icfgr_addr, icfg);
    wait_rwp(rbase);
    mmio.mmio_write32(rbase + gicr_isenabler0, bit);
    wait_rwp(rbase);

    // CPU interface via the system registers (GICv3).
    var sre: u64 = 0;
    asm volatile ("mrs %[v], icc_sre_el1"
        : [v] "=r" (sre),
    );
    sre |= 1; // SRE: system-register interface
    asm volatile ("msr icc_sre_el1, %[v]"
        :
        : [v] "r" (sre),
    );
    asm volatile ("msr icc_pmr_el1, %[v]"
        :
        : [v] "r" (@as(u64, 0xff)),
    );
    asm volatile ("msr icc_igrpen1_el1, %[v]"
        :
        : [v] "r" (@as(u64, 1)),
    );
    asm volatile ("dsb sy");
    asm volatile ("isb");
}

fn init_v2(private_intid: u32, edge_triggered: bool) void {
    // Distributor: EnableGrp0 | EnableGrp1.
    var ctlr = mmio.mmio_read32(dist_base + 0x0000);
    ctlr |= 0b11;
    mmio.mmio_write32(dist_base + 0x0000, ctlr);
    const bit: u32 = @as(u32, 1) << @as(u5, @intCast(private_intid));
    var igroup = mmio.mmio_read32(dist_base + 0x0080);
    igroup |= bit;
    mmio.mmio_write32(dist_base + 0x0080, igroup);
    const priority_word = private_intid / 4;
    const priority_shift: u5 = @intCast((private_intid % 4) * 8);
    const priority_addr = dist_base + 0x0400 + @as(u64, priority_word) * 4;
    var priority = mmio.mmio_read32(priority_addr);
    priority &= ~(@as(u32, 0xff) << priority_shift);
    priority |= @as(u32, 0x80) << priority_shift;
    mmio.mmio_write32(priority_addr, priority);
    const icfgr_addr = dist_base + 0x0c00 + @as(u64, private_intid / 16) * 4;
    const icfg = private_icfgr(mmio.mmio_read32(icfgr_addr), private_intid, edge_triggered);
    mmio.mmio_write32(icfgr_addr, icfg);
    mmio.mmio_write32(dist_base + 0x0100, bit);
    // CPU interface (GICC): enable + priority mask.
    var ctlr2 = mmio.mmio_read32(cpu_base + 0x0000);
    ctlr2 |= 0b11;
    mmio.mmio_write32(cpu_base + 0x0000, ctlr2);
    mmio.mmio_write32(cpu_base + 0x0004, 0xff);
}

/// Poll GICR_CTLR.RWP (bit 3) until the redistributor finished processing
/// register writes. Bounded: a stuck bit must not hang boot.
fn wait_rwp(rbase: u64) void {
    var spins: usize = 0;
    while ((mmio.mmio_read32(rbase + 0x0000) & (1 << 3)) != 0 and spins < 100_000) : (spins += 1) {}
}

// ---------------------------------------------------------------------------
// Shared-peripheral-interrupt (SPI) window (claim 0828 — the custom virtio
// device's used-ring notification asserts an unknown SPI; arming the whole
// window lets the spike report whatever INTID actually fires)
// ---------------------------------------------------------------------------

/// SPIs start at INTID 32 (0-15 SGIs, 16-31 PPIs).
pub const spi_min: u32 = 32;
/// Distributor register word index holding SPI `intid`'s enable/group bit.
pub fn spi_word(intid: u32) u32 {
    return intid / 32;
}

/// GICD_IPRIORITYR word index for `intid` (one byte per interrupt).
pub fn spi_priority_word(intid: u32) u32 {
    return intid / 4;
}

/// GICD_ICFGR word index for `intid` (2 bits per interrupt).
pub fn spi_icfgr_word(intid: u32) u32 {
    return intid / 16;
}

/// GICD_IROUTER byte offset for `intid` (64-bit register per SPI).
pub fn spi_router_offset(intid: u32) u64 {
    return 0x6100 + @as(u64, intid) * 8;
}

/// Poll GICD_CTLR.RWP (bit 3) until the distributor finished processing
/// register writes. Bounded: a stuck bit must not hang boot.
fn wait_dist_rwp() void {
    var spins: usize = 0;
    while ((mmio.mmio_read32(dist_base + 0x0000) & (1 << 3)) != 0 and spins < 100_000) : (spins += 1) {}
}

/// Program a window of SPIs for delivery to the boot CPU: Group 1, level
/// trigger (both ICFGR bits clear), priority 0x80 (below PMR 0xff so it
/// passes), IROUTER = PE 0, then enabled. GICv3 distributor only (VZ is
/// v3 — claim 9187); no-op in a host test process.
pub fn arm_spi_window(first: u32, count: u32) void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (kind != .v3 or dist_base == 0) return;
    if (first < spi_min) return;
    const last = @min(first +| count, 1020); // SPI space is 32..1019
    var intid = first;
    while (intid < last) : (intid += 1) {
        const word = spi_word(intid);
        const bit: u32 = @as(u32, 1) << @as(u5, @intCast(intid % 32));
        // Group 1.
        var igroup = mmio.mmio_read32(dist_base + 0x0080 + word * 4);
        igroup |= bit;
        mmio.mmio_write32(dist_base + 0x0080 + word * 4, igroup);
        // Priority 0x80 (aligned word RMW, like the PPI path).
        const paddr = dist_base + 0x0400 + spi_priority_word(intid) * 4;
        const pshift: u5 = @intCast((intid % 4) * 8);
        var prio = mmio.mmio_read32(paddr);
        prio &= ~(@as(u32, 0xff) << pshift);
        prio |= @as(u32, 0x80) << pshift;
        mmio.mmio_write32(paddr, prio);
        // ICFGR: level-triggered (clear both field bits; bit 1 is the
        // trigger bit, bit 0 is RES0 — the claim-9187 lesson).
        const iaddr = dist_base + 0x0c00 + spi_icfgr_word(intid) * 4;
        const ishift: u5 = @intCast((intid % 16) * 2);
        var icfg = mmio.mmio_read32(iaddr);
        icfg &= ~(@as(u32, 0b11) << ishift);
        mmio.mmio_write32(iaddr, icfg);
        // Route to PE 0 (two 32-bit halves; IROUTER is 64-bit).
        const raddr = dist_base + spi_router_offset(intid);
        mmio.mmio_write32(raddr, 0);
        mmio.mmio_write32(raddr + 4, 0);
        // Enable.
        mmio.mmio_write32(dist_base + 0x0100 + word * 4, bit);
    }
    wait_dist_rwp();
}

/// Disable a window of SPIs (GICD_ICENABLER). Claim 0828: after the spike
/// experiment the window is disarmed so the shell runs without interrupt
/// noise (a level-stuck device IRQ cannot storm the kernel).
pub fn disarm_spi_window(first: u32, count: u32) void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (kind != .v3 or dist_base == 0) return;
    if (first < spi_min) return;
    const last = @min(first +| count, 1020);
    var intid = first;
    while (intid < last) : (intid += 1) {
        const word = spi_word(intid);
        const bit: u32 = @as(u32, 1) << @as(u5, @intCast(intid % 32));
        mmio.mmio_write32(dist_base + 0x0180 + word * 4, bit);
    }
    wait_dist_rwp();
}

// ---------------------------------------------------------------------------
// IRQ-handler primitives (called by the kernel's irq_dispatch, in IRQ
// context — never touch the console here)
// ---------------------------------------------------------------------------

/// Non-spurious interrupts acked since init (diagnostic; the timer command
/// prints the total — if the GIC delivers on a different INTID than the
/// timer's PPI, irqs_acked grows while ticks stays 0).
/// Issue #810-family audit (claim 7339): PER-CORE — `note_irq` runs from
/// `irq_dispatch` on every core (a secondary core acks its own timer PPI
/// and any SGI in parallel with core 0), so a shared counter was a plain
/// RMW race that lost increments. Core count is literal (4): smp imports
/// gic, so gic cannot import smp for `max_cores` (same idiom as
/// `exceptions.max_resume_cores`).
pub const cpu_cores: usize = 4;
pub var irqs_acked: [cpu_cores]u32 = @as([cpu_cores]u32, @splat(@as(u32, 0)));
/// The first non-spurious INTID acked per core (0xffffffff until one
/// arrives). The monitor prints slot 0, which is the meaningful boot
/// diagnostic: SPIs are IROUTER-pinned to PE 0, and a secondary core's
/// first ack is its own timer PPI or an SGI by construction.
pub var first_intid: [cpu_cores]u32 = @as([cpu_cores]u32, @splat(@as(u32, 0xffffffff)));

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

/// Total non-spurious acks across all cores (what the `timer` command
/// prints).
pub fn acked_total() u64 {
    var sum: u64 = 0;
    for (irqs_acked) |v| sum += v;
    return sum;
}

/// Read the acknowledged INTID from the CPU interface (ICC_IAR1_EL1 for
/// v3, GICC_IAR for v2). 1023 = spurious (the same value in both).
pub fn ack() u32 {
    if (comptime builtin.cpu.arch != .aarch64) return 1023;
    const c = core_index();
    if (prefetched[c]) |intid| {
        prefetched[c] = null;
        return intid;
    }
    return switch (kind) {
        .v3 => blk: {
            var iar: u64 = 1023;
            asm volatile ("mrs %[v], icc_iar1_el1"
                : [v] "=r" (iar),
            );
            break :blk @as(u32, @intCast(iar & 0xffffff));
        },
        .v2 => mmio.mmio_read32(cpu_base + 0x000c) & 0x3ff,
        .none => 1023,
    };
}

/// Spurious-interrupt sentinel (1023 on both GICv2's 10-bit IAR and
/// GICv3's 24-bit IAR).
pub fn is_spurious(intid: u32) bool {
    return intid == 1023;
}

/// Record a non-spurious ack for diagnostics (per-core — claim 7339).
pub fn note_irq(intid: u32) void {
    const cidx = core_index();
    irqs_acked[cidx] += 1;
    if (first_intid[cidx] == 0xffffffff) first_intid[cidx] = intid;
}

/// Deactivate the interrupt (ICC_EOIR1_EL1 for v3, GICC_EOIR for v2).
pub fn eoi(intid: u32) void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    switch (kind) {
        .v3 => asm volatile ("msr icc_eoir1_el1, %[v]"
            :
            : [v] "r" (@as(u64, intid)),
        ),
        .v2 => mmio.mmio_write32(cpu_base + 0x0010, intid),
        .none => {},
    }
}

// ---------------------------------------------------------------------------
// Tests (host-side; fixtures are RAM buffers, programming is aarch64-only)
// ---------------------------------------------------------------------------

const Header = struct {
    len: u32,
};

fn fixture_madt(comptime entries: []const struct { type: u8, len: u8, bytes: []const u8 }, header_len: u32, buf: []u8) Header {
    // header_len is the total table length (header + entries); the first
    // 36 bytes are the ACPI header, entries start at 36.
    @memset(buf[0..], 0);
    std.mem.writeInt(u32, buf[4..8], header_len, .little);
    var off: usize = 36;
    for (entries) |e| {
        buf[off] = e.type;
        buf[off + 1] = e.len;
        @memcpy(buf[off + 2 .. off + 2 + e.bytes.len], e.bytes);
        off += e.len;
    }
    return .{ .len = header_len };
}

fn put64(buf: []u8, off: usize, value: u64) void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, value, .little);
    @memcpy(buf[off .. off + 8], &tmp);
}

fn put32(buf: []u8, off: usize, value: u32) void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, value, .little);
    @memcpy(buf[off .. off + 4], &tmp);
}

test "gic: MADT v3 fixture parses distributor + redistributor + gicc" {
    var buf: [512]u8 align(16) = undefined;
    // GICD: base @+8, version @+20 (3 = GICv3). GICR: base @+4.
    // GICC: base @+32 (0 for v3 — the interface is the system registers).
    const h = fixture_madt(&.{
        .{ .type = madt_gicd, .len = 24, .bytes = &.{} },
        .{ .type = madt_gicr, .len = 16, .bytes = &.{} },
        .{ .type = madt_gicc, .len = 80, .bytes = &.{} },
    }, 36 + 24 + 16 + 80, &buf);
    put64(&buf, 36 + 8, 0x2f000000);
    buf[36 + 20] = 3;
    put64(&buf, 36 + 24 + 4, 0x2f100000);
    put64(&buf, 36 + 24 + 16 + 32, 0);
    discover(@intFromPtr(&buf), h.len);
    try std.testing.expectEqual(GicKind.v3, kind);
    try std.testing.expectEqual(@as(u64, 0x2f000000), dist_base);
    try std.testing.expectEqual(@as(u64, 0x2f100000), redist_base);
    try std.testing.expectEqual(@as(u64, 0), cpu_base);
    try std.testing.expect(!used_fallback);
    try std.testing.expectEqualStrings("v3", kind_name());
}

test "gic: MADT v2 fixture parses GICC and picks the MMIO path" {
    var buf: [512]u8 align(16) = undefined;
    const h = fixture_madt(&.{
        .{ .type = madt_gicd, .len = 24, .bytes = &.{} },
        .{ .type = madt_gicc, .len = 80, .bytes = &.{} },
    }, 36 + 24 + 80, &buf);
    put64(&buf, 36 + 8, 0x2f000000);
    buf[36 + 20] = 2;
    put64(&buf, 36 + 24 + 32, 0x2f020000);
    discover(@intFromPtr(&buf), h.len);
    try std.testing.expectEqual(GicKind.v2, kind);
    try std.testing.expectEqual(@as(u64, 0x2f000000), dist_base);
    try std.testing.expectEqual(@as(u64, 0x2f020000), cpu_base);
    try std.testing.expectEqual(@as(u64, 0), redist_base);
    try std.testing.expect(!used_fallback);
}

test "gic: unversioned MADT infers v3 from GICR presence" {
    var buf: [512]u8 align(16) = undefined;
    const h = fixture_madt(&.{
        .{ .type = madt_gicd, .len = 24, .bytes = &.{} },
        .{ .type = madt_gicr, .len = 16, .bytes = &.{} },
    }, 36 + 24 + 16, &buf);
    put64(&buf, 36 + 8, 0x2f000000);
    buf[36 + 20] = 0xff; // "GIC version not identified"
    put64(&buf, 36 + 24 + 4, 0x2f100000);
    discover(@intFromPtr(&buf), h.len);
    try std.testing.expectEqual(GicKind.v3, kind);
    try std.testing.expectEqual(@as(u64, 0x2f100000), redist_base);
}

test "gic: unknown entry types are skipped; malformed lengths stop the walk" {
    var buf: [512]u8 align(16) = undefined;
    // An ITS (0x0F) entry before the GICD/GICR, then a broken entry
    // (length 1 < 2) that must stop the walk.
    const h = fixture_madt(&.{
        .{ .type = madt_gic_its, .len = 16, .bytes = &.{} },
        .{ .type = madt_gicd, .len = 24, .bytes = &.{} },
        .{ .type = madt_gicr, .len = 16, .bytes = &.{} },
    }, 36 + 16 + 24 + 16, &buf);
    // GICD starts after the 16-byte ITS entry: base at 36+16+8, version
    // byte at 36+16+20.
    put64(&buf, 36 + 16 + 8, 0x2f000000);
    buf[36 + 16 + 20] = 3;
    put64(&buf, 36 + 16 + 24 + 4, 0x2f100000);
    // Append a length-1 entry right after the GICR: walk must stop there.
    buf[36 + 16 + 24 + 16] = madt_gicc;
    buf[36 + 16 + 24 + 16 + 1] = 1;
    discover(@intFromPtr(&buf), h.len + 2);
    try std.testing.expectEqual(GicKind.v3, kind);
    try std.testing.expectEqual(@as(u64, 0x2f000000), dist_base);
    try std.testing.expectEqual(@as(u64, 0x2f100000), redist_base);
}

test "gic: absent/non-conformant MADT falls back to the VZ layout" {
    discover(0, 0);
    try std.testing.expectEqual(GicKind.v3, kind);
    try std.testing.expectEqual(@as(u64, 0x10000000), dist_base);
    try std.testing.expectEqual(@as(u64, 0x10010000), redist_base);
    try std.testing.expect(used_fallback);
    var buf: [36]u8 align(16) = undefined;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[4..8], 36, .little); // header only, no entries
    discover(@intFromPtr(&buf), 36);
    try std.testing.expectEqual(GicKind.v3, kind);
}

test "gic: incomplete v2 MADT without a CPU interface falls back" {
    var buf: [128]u8 align(16) = undefined;
    const h = fixture_madt(&.{
        .{ .type = madt_gicd, .len = 24, .bytes = &.{} },
    }, 36 + 24, &buf);
    put64(&buf, 36 + 8, 0x2f000000);
    buf[36 + 20] = 2;
    discover(@intFromPtr(&buf), h.len);
    try std.testing.expectEqual(GicKind.v3, kind);
    try std.testing.expect(used_fallback);
}

test "gic: spurious sentinel is 1023 on both paths" {
    try std.testing.expect(is_spurious(1023));
    try std.testing.expect(!is_spurious(30));
    try std.testing.expect(!is_spurious(0));
}

test "gic: redistributor private-interrupt offsets include the SGI frame" {
    try std.testing.expectEqual(@as(u64, 0x10000), gicr_sgi_frame_offset);
    try std.testing.expectEqual(@as(u64, 0x10080), gicr_igroup0);
    try std.testing.expectEqual(@as(u64, 0x10100), gicr_isenabler0);
    try std.testing.expectEqual(@as(u64, 0x10400), gicr_ipriority0);
    try std.testing.expectEqual(@as(u64, 0x10c04), gicr_icfgr0 + 4);
}

test "gic: private interrupt trigger fields use ICFGR bit one" {
    // PPI 30 occupies ICFGR1 bits 29:28. Level clears both bits; edge sets
    // bit 29 and leaves the RES0 bit 28 clear.
    try std.testing.expectEqual(@as(u32, 0xcfffffff), private_icfgr(0xffffffff, 30, false));
    try std.testing.expectEqual(@as(u32, 0xefffffff), private_icfgr(0xffffffff, 30, true));
}

test "gic: SPI window register offsets match the distributor layout" {
    // SPI 69 (the Linux-style virtio SPI): enable word 2, priority word
    // 17, ICFGR word 4, IROUTER at 0x6100 + 69*8. SPIs start at 32, so
    // INTID 32 is word 1 (word 0 covers SGIs + PPIs 0..31).
    try std.testing.expectEqual(@as(u32, 2), spi_word(69));
    try std.testing.expectEqual(@as(u32, 17), spi_priority_word(69));
    try std.testing.expectEqual(@as(u32, 4), spi_icfgr_word(69));
    try std.testing.expectEqual(@as(u64, 0x6328), spi_router_offset(69));
    try std.testing.expectEqual(@as(u32, 1), spi_word(32));
    try std.testing.expectEqual(@as(u32, 2), spi_word(95));
    try std.testing.expectEqual(@as(u32, 2), spi_icfgr_word(32));
    try std.testing.expectEqual(@as(u32, 3), spi_icfgr_word(48));
    try std.testing.expectEqual(@as(u32, spi_min), 32);
}
