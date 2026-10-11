//! VirelaiOS evidence channel (extracted verbatim from the former
//! kernel/src/main.zig junk drawer; claim 0023 mechanical split — no
//! behavior change).
//!
//! Takeover markers (the ADR 0004 D4 ladder: stage names, values, and
//! write ordering are preserved byte-for-byte), the NVRAM persistence
//! channel (`SetVariable` into the `VirelaiM2`/`VirelaiProbe`/
//! `VirelaiMmu` variables), and the bounded diagnostic dump helpers (the
//! pre-exit probe dump + the claim-0021 firmware-MMU-state capture).
//!
//! The marker NVRAM channel: EFI Runtime Services `SetVariable` survives
//! ExitBootServices (it is a *runtime* service, not a boot service — the
//! same table M1.5's reboot/shutdown design cites via `ResetSystem`).
//! Writing each stage as a non-volatile variable gives the host a
//! post-exit-visible marker: artifacts/efi-vars.bin is host-readable after
//! the run. This is the working form of the ADR 0004 D4 fallback on VZ —
//! the memory-dump variant is impossible there (guest RAM is not mapped
//! into the runner process, claim 0009).
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");
const uefi = std.os.uefi;
const SystemTable = uefi.tables.SystemTable;
const MemoryMapSlice = uefi.tables.MemoryMapSlice;
const handoff = @import("handoff.zig");
const mmu = @import("mmu.zig");
const mmio = @import("mmio.zig");

/// Console layout selector, shared with the console driver in main.zig
/// (the probe's `Kind`). Lives here because `dump_sel` formats it.
pub const Kind = enum { none, pl011, ns16550, virtio };

// ---------------------------------------------------------------------------
// Takeover markers (ADR 0004 D4 fixed-memory-marker fallback)
// ---------------------------------------------------------------------------

// `takeover_marker` is a BSS word a host-side dump can read. It records the
// takeover stage so a silent post-exit death (no serial output) is
// discriminable: the stage present when the kernel halts names the failure
// window, and a missing later stage names the crash site. Values are 8-byte
// ASCII, little-endian in RAM.
pub const marker_entry: u64 = 0x4d325f454e545259; // "M2_ENTRY"
pub const marker_cmap: u64 = 0x4d325f434d415021; // "M2_CMAP!" — about to capture the EFI map
pub const marker_mapd: u64 = 0x4d325f4d41504421; // "M2_MAPD!" — identity map built, about to install it
pub const marker_prex: u64 = 0x4d325f5052455821; // "M2_PREX!" — about to call ExitBootServices
pub const marker_exit: u64 = 0x4d325f4558495421; // "M2_EXIT!"
pub const marker_mmu: u64 = 0x4d325f4d4d555021; // "M2_MMUP!"
pub const marker_table: u64 = 0x4d325f5441424c45; // "M2_TABLE"
pub const marker_seria: u64 = 0x4d325f5345524941; // "M2_SERIA"
pub const marker_ready: u64 = 0x4d325f5245414459; // "M2_READY" — console ready, banner next
pub const marker_raw: u64 = 0x4d325f52415721; // "M2_RAW!" — post-switch probe: declared-window base checks
pub const marker_txok: u64 = 0x4d325f54584f4b21; // "M2_TXOK!" — first serial TX completed (bytes may still be dropped; the log is the gate)
pub const marker_txst: u64 = 0x4d325f5458535421; // "M2_TXST!" — virtio flush entered (desc/avail posted)
pub const marker_txnt: u64 = 0x4d325f54584e5421; // "M2_TXNT!" — notify write issued
pub const marker_txpl: u64 = 0x4d325f5458504c21; // "M2_TXPL!" — used-ring poll finished
pub const marker_vpscan: u64 = 0x4d325f5650533031; // "M2_VPS01" — virtio-pci console dev scan done
pub const marker_seam: u64 = 0x4d325f5345414d21; // "M2_SEAM!" — claim 0015 diag: shell seam entered
pub const marker_vpbar: u64 = 0x4d325f5650533032; // "M2_VPS02" — BAR bases read
pub const marker_vpcap: u64 = 0x4d325f5650533033; // "M2_VPS03" — about to read the capability pointer (0x34)
pub const marker_vpcapr: u64 = 0x4d325f5650533034; // "M2_VPS04" — capability pointer read; walk about to start
pub const marker_vpwalk: u64 = 0x4d325f5650533035; // "M2_VPS05" — walk exited
pub const marker_vpdev: u64 = 0x4d325f5650444556; // "M2_VPDEV" — virtio-pci console device found, caps walked
pub const marker_vptx: u64 = 0x4d325f5650545821; // "M2_VPTX!" — transport programmed (features + queue)
pub const marker_vpok: u64 = 0x4d325f56504f4b21; // "M2_VPOK!" — DRIVER_OK, TX path armed
pub const marker_pext: u64 = 0x4d325f5045585421; // "M2_PEXT!" — claim 0017: pre-exit TX experiment entered, about to flush
pub const marker_pexd: u64 = 0x4d325f5045584421; // "M2_PEXD!" — claim 0017: pre-exit TX experiment flush returned
// Claim 0018: per-stage bisect markers for the FIRST post-exit virtio TX.
// Ten ordered 8-byte NVRAM writes bracket each potentially fatal operation;
// the ladder's last marker names the smallest confirmed failure interval
// (tools/verify-tx-diag.sh, build-gated -Dtx-diag).
pub const marker_txfl: u64 = 0x4d325f5458464c21; // "M2_TXFL!" — 1 entered virtio flush
pub const marker_txda: u64 = 0x4d325f5458444121; // "M2_TXDA!" — 2 descriptor/avail buffers prepared
pub const marker_txcc: u64 = 0x4d325f5458434321; // "M2_TXCC!" — 3 DMA cache clean completed
pub const marker_txbr: u64 = 0x4d325f5458425221; // "M2_TXBR!" — 4 before first post-exit BAR/common-cfg read
pub const marker_txar: u64 = 0x4d325f5458415221; // "M2_TXAR!" — 5 after that read
pub const marker_txbn: u64 = 0x4d325f5458424e21; // "M2_TXBN!" — 6 before queue notify MMIO write
pub const marker_txan: u64 = 0x4d325f5458414e21; // "M2_TXAN!" — 7 after notify
pub const marker_txup: u64 = 0x4d325f5458555021; // "M2_TXUP!" — 8 entered used-ring poll
pub const marker_txuc: u64 = 0x4d325f5458554321; // "M2_TXUC!" — 9 device changed used.idx (break condition seen)
pub const marker_txfr: u64 = 0x4d325f5458465221; // "M2_TXFR!" — 10 flush returned
// Claim 0020: TX-transition matrix markers. Build-gated `-Dtx-transition-*`
// (one phase per build). For each phase x ∈ {A=pre-EBS, B=post-EBS/pre-MMU,
// C=post-MMU, D=final location}: M2_TRx1! = experiment entered, about to
// flush; M2_TRx2! = flush returned; M2_TRxU! = flush returned AND used.idx
// advanced (device consumed). Absence of x2 with x1 present = hung inside
// the flush; x2 present without xU = returned but the device never consumed.
// M2_TRNX! = experiment skipped (transport not armed pre-exit).
pub const marker_tra1: u64 = 0x4d325f5452413121; // "M2_TRA1!"
pub const marker_tra2: u64 = 0x4d325f5452413221; // "M2_TRA2!"
pub const marker_trau: u64 = 0x4d325f5452415521; // "M2_TRAU!"
pub const marker_trb1: u64 = 0x4d325f5452423121; // "M2_TRB1!"
pub const marker_trb2: u64 = 0x4d325f5452423221; // "M2_TRB2!"
pub const marker_trbu: u64 = 0x4d325f5452425521; // "M2_TRBU!"
pub const marker_trc1: u64 = 0x4d325f5452433121; // "M2_TRC1!"
pub const marker_trc2: u64 = 0x4d325f5452433221; // "M2_TRC2!"
pub const marker_trcu: u64 = 0x4d325f5452435521; // "M2_TRCU!"
pub const marker_trd1: u64 = 0x4d325f5452443121; // "M2_TRD1!"
pub const marker_trd2: u64 = 0x4d325f5452443221; // "M2_TRD2!"
pub const marker_trdu: u64 = 0x4d325f5452445521; // "M2_TRDU!"
pub const marker_trnx: u64 = 0x4d325f54524e5821; // "M2_TRNX!"
// Claim 7896 (6460 follow-up): post-switch walk-probe markers. M2_WP_00 =
// probe battery entered; M2_WP_01..M2_WP_05 = the corresponding probe's
// volatile read returned (self / ram-hi / ram-mid / ram-lo / BAR). The
// ladder's last WP marker names the first address whose walk (or MMIO read)
// does not return under the programmed T0SZ.
pub const marker_wp00: u64 = 0x4d325f57505f3030; // "M2_WP_00"
pub const marker_wp01: u64 = 0x4d325f57505f3031; // "M2_WP_01"
pub const marker_wp02: u64 = 0x4d325f57505f3032; // "M2_WP_02"
pub const marker_wp03: u64 = 0x4d325f57505f3033; // "M2_WP_03"
pub const marker_wp04: u64 = 0x4d325f57505f3034; // "M2_WP_04"
pub const marker_wp05: u64 = 0x4d325f57505f3035; // "M2_WP_05"

const marker_variable_name = utf16z("VirelaiM2");
pub const marker_vendor_guid = uefi.Guid{
    .time_low = 0x4d324d32, // "M2M2"
    .time_mid = 0x5f44, // "_D"
    .time_high_and_version = 0x4950, // "IP"
    .clock_seq_high_and_reserved = 0x53, // "S"
    .clock_seq_low = 0x48, // "H"
    .node = .{ 0x49, 0x54, 0x4f, 0x53, 0x2d, 0x4d }, // "ITOS-M"
};

fn utf16z(comptime text: []const u8) [text.len + 1:0]u16 {
    var result: [text.len + 1:0]u16 = undefined;
    for (text, 0..) |byte, index| result[index] = byte;
    result[text.len] = 0;
    return result;
}

/// BSS word behind the marker ladder (ADR 0004 D4 fallback).
var takeover_marker: u64 = 0;

/// Volatile marker write: a bare dead store to BSS could be elided under
/// ReleaseSmall (nothing in the guest reads `takeover_marker` back), which
/// would silently rob the host dump of its discriminator.
pub fn set_marker(value: u64) void {
    @as(*volatile u64, &takeover_marker).* = value;
}

/// Fixed BSS evidence remains available to a host-side debugger if the
/// serial probe is blocked. It is not reported as serial success. The
/// discriminating marker word was already set to M2_SERIA by the caller;
/// the M2M! breadcrumb is written into the transport's scratch region
/// (`scratch` — the caller passes virtio_console.virtio_tx, claim 0023) so
/// the halt reason is never clobbered.
pub fn write_marker_fallback(scratch: *[128]u8, base: u64, size: u64, map: MemoryMapSlice) void {
    scratch[0] = 'M';
    scratch[1] = '2';
    scratch[2] = '!';
    scratch[3] = 0;
    _ = base;
    _ = size;
    _ = map;
}

/// Write the current marker stage as an EFI non-volatile variable. Best
/// effort: a failed runtime call never changes control flow (on VZ the
/// firmware may not keep runtime services resident — then this is a no-op and
/// the BSS marker remains the only record). The first write (pre-exit)
/// creates the variable; later writes update it in place.
pub fn write_marker_var(st: *const SystemTable, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    _ = st.runtime_services._setVariable(
        &marker_variable_name,
        &marker_vendor_guid,
        .{ .non_volatile = true, .bootservice_access = true, .runtime_access = true },
        bytes.len,
        &bytes,
    );
}

// ---------------------------------------------------------------------------
// Claim 0013 diagnostic: the probe's ground truth is persisted to the NVRAM
// channel (a second variable, `VirelaiProbe`, same vendor GUID as the marker
// ladder) so the host can read exactly what each declared MMIO window
// contains even though the serial log is silent. The ladder (VirelaiM2) is
// untouched. Lines are plain ASCII so `strings artifacts/efi-vars.bin` shows
// them.
// ---------------------------------------------------------------------------
const probe_variable_name = utf16z("VirelaiProbe");
var probe_dump: [32768]u8 = undefined;
var probe_dump_len: usize = 0;

pub fn dump_str(text: []const u8) void {
    if (text.len > probe_dump.len - probe_dump_len) return;
    @memcpy(probe_dump[probe_dump_len .. probe_dump_len + text.len], text);
    probe_dump_len += text.len;
}

pub fn dump_hex(value: u64) void {
    var tmp: [18]u8 = undefined;
    tmp[0] = '0';
    tmp[1] = 'x';
    var index: usize = 2;
    var shift: u6 = 60;
    while (true) : (shift -= 4) {
        const digit: u8 = @intCast((value >> shift) & 0xf);
        tmp[index] = if (digit < 10) '0' + digit else 'a' + digit - 10;
        index += 1;
        if (shift == 0) break;
    }
    dump_str(tmp[0..index]);
}

pub fn dump_probe_line(off: u64, base: u64, magic: u32, version: u32, device: u32, vendor: u32) void {
    dump_str("VIRTIO O=");
    dump_hex(off);
    dump_str(" B=");
    dump_hex(base);
    dump_str(" M=");
    dump_hex(magic);
    dump_str(" V=");
    dump_hex(version);
    dump_str(" D=");
    dump_hex(device);
    dump_str(" R=");
    dump_hex(vendor);
    dump_str("\n");
}

pub fn dump_pl011_line(off: u64, addr: u64, pid0: u32, pid1: u32, pid2: u32, fr: u32) void {
    dump_str("UART PL011 O=");
    dump_hex(off);
    dump_str(" B=");
    dump_hex(addr);
    dump_str(" PID=");
    dump_hex(pid0 | (pid1 << 8) | (pid2 << 16));
    dump_str(" FR=");
    dump_hex(fr);
    dump_str("\n");
}

pub fn dump_16550_line(off: u64, addr: u64, ier: u32, iir: u32, lcr: u32, mcr: u32, lsr: u32, msr: u32, scratch: u32) void {
    dump_str("UART 16550 O=");
    dump_hex(off);
    dump_str(" B=");
    dump_hex(addr);
    dump_str(" IER=");
    dump_hex(ier);
    dump_str(" IIR=");
    dump_hex(iir);
    dump_str(" LCR=");
    dump_hex(lcr);
    dump_str(" MCR=");
    dump_hex(mcr);
    dump_str(" LSR=");
    dump_hex(lsr);
    dump_str(" MSR=");
    dump_hex(msr);
    dump_str(" SCR=");
    dump_hex(scratch);
    dump_str("\n");
}

pub fn dump_sel(kind: Kind, base: u64) void {
    dump_str("SEL=");
    switch (kind) {
        .pl011 => dump_str("PL011 "),
        .ns16550 => dump_str("16550 "),
        .virtio => dump_str("VIRTIO "),
        .none => dump_str("NONE "),
    }
    dump_str("base=");
    dump_hex(base);
    dump_str("\n");
}

/// Persist the probe dump to the NVRAM channel as a sequence of ≤ 2048-byte
/// chunks (variables `VirelaiP0`, `VirelaiP1`, ...). Chunked because a
/// single large SetVariable silently FAILS on VZ above ~4-5 KB (claim 0013:
/// a ~6 KB write vanished while a ~4.5 KB instance persisted). Best effort
/// per chunk; a failed call never changes control flow. Used PRE-EXIT only:
/// big SetVariable re-writes hang post-exit on VZ (claim 0013).
const probe_chunk_size: usize = 2048;
pub fn write_probe_var(st: *const SystemTable) void {
    if (probe_dump_len == 0) return;
    var pos: usize = 0;
    var chunk: usize = 0;
    while (pos < probe_dump_len) : (pos += probe_chunk_size) {
        const len = @min(probe_chunk_size, probe_dump_len - pos);
        var name: [16:0]u16 = undefined;
        const prefix = "VirelaiP";
        var i: usize = 0;
        while (i < prefix.len) : (i += 1) name[i] = prefix[i];
        var digits: [4]u8 = undefined;
        var n = chunk;
        var nd: usize = 0;
        while (true) : (nd += 1) {
            digits[nd] = @intCast('0' + (n % 10));
            n /= 10;
            if (n == 0) break;
        }
        while (nd > 0) : (nd -= 1) {
            name[i] = digits[nd - 1];
            i += 1;
        }
        name[i] = 0;
        _ = st.runtime_services._setVariable(
            &name,
            &marker_vendor_guid,
            .{ .non_volatile = true, .bootservice_access = true, .runtime_access = true },
            len,
            probe_dump[pos .. pos + len].ptr,
        );
        chunk += 1;
    }
}

/// POST-EXIT variant: persist only the newest tail of the dump buffer (≤ 512
/// bytes) as a SEPARATE variable, so post-exit probe additions (candidate
/// hits, SEL) are observable without a large re-write of `VirelaiProbe`
/// (which hangs post-exit on VZ). Best effort; a failure is ignored.
const probe_tail_variable_name = utf16z("VirelaiP2");
pub fn write_probe_tail(st: *const SystemTable) void {
    if (probe_dump_len == 0) return;
    const start: usize = if (probe_dump_len > 512) probe_dump_len - 512 else 0;
    const len = probe_dump_len - start;
    _ = st.runtime_services._setVariable(
        &probe_tail_variable_name,
        &marker_vendor_guid,
        .{ .non_volatile = true, .bootservice_access = true, .runtime_access = true },
        len,
        probe_dump[start..].ptr,
    );
}

pub fn dump_raw(addr: u64, len: usize, tag: []const u8) void {
    dump_str(tag);
    dump_str(" @");
    dump_hex(addr);
    dump_str(": ");
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dump_hex(mmio.mmio_read8(addr + i));
        dump_str(" ");
    }
    dump_str("\n");
}

pub fn dump_guid_bytes(guid: *const uefi.Guid) void {
    const raw: [*]const u8 = @ptrCast(guid);
    var i: usize = 0;
    while (i < 16) : (i += 1) dump_hex(raw[i]);
}

/// Pre-exit dump of every EFI configuration-table entry: vendor GUID, table
/// pointer, and the first 32-bit word of the table (a flattened device tree
/// starts with the big-endian magic 0xd00dfeed — the authoritative VZ device
/// list). This runs before ExitBootServices so all firmware memory is
/// readable; the buffer is persisted post-exit by write_probe_var.
pub fn dump_config_table(st: *const SystemTable) void {
    const entries = st.number_of_table_entries;
    dump_str("CFG n=");
    dump_hex(entries);
    dump_str("\n");
    const table = st.configuration_table;
    var i: usize = 0;
    while (i < entries and i < 12) : (i += 1) {
        const entry = &table[i];
        dump_str("CFG ");
        dump_hex(i);
        dump_str(" G=");
        dump_guid_bytes(&entry.vendor_guid);
        dump_str(" P=");
        dump_hex(@intCast(@intFromPtr(entry.vendor_table)));
        const first = @as(*const volatile u32, @ptrFromInt(@intFromPtr(entry.vendor_table))).*;
        dump_str(" F=");
        dump_hex(first);
        dump_str("\n");
    }
}

pub fn dump_raw_sparse(addr: u64, len: usize, tag: []const u8) void {
    // Dump only the non-zero 16-byte groups of a window: a sparse register
    // file (claim 0013: 0x20050000 reads 0x23 0xd3 0x75 0x6a at +0, 0x01 at
    // +0x0c, and 0x31/0x10/0x04 in the +0xfe0 area) is shown completely
    // without paying 20 KB of ASCII for the zero pages.
    var pos: usize = 0;
    while (pos < len) : (pos += 16) {
        const group = @min(16, len - pos);
        var nonzero = false;
        var i: usize = 0;
        while (i < group) : (i += 1) {
            if (mmio.mmio_read8(addr + pos + i) != 0) {
                nonzero = true;
                break;
            }
        }
        if (!nonzero) continue;
        dump_str(tag);
        dump_str(" @");
        dump_hex(addr + pos);
        dump_str(": ");
        i = 0;
        while (i < group) : (i += 1) {
            dump_hex(mmio.mmio_read8(addr + pos + i));
            dump_str(" ");
        }
        dump_str("\n");
    }
}

/// Pre-exit dump of the FULL EFI map (every descriptor — no device window
/// or high region missed) plus the complete non-zero register bytes of each
/// declared MMIO window. PRE-EXIT only: post-exit reads of these windows
/// hang on VZ (claim 0013).
pub fn dump_mmio_descriptors(map: MemoryMapSlice) void {
    var count: usize = 0;
    var it = map.iterator();
    while (it.next()) |desc| : (count += 1) {
        if (count >= 64) break;
        if (desc.number_of_pages == 0 or desc.number_of_pages > std.math.maxInt(u64) / 4096) continue;
        dump_str("MAP T=");
        dump_hex(@backingInt(desc.type));
        dump_str(" B=");
        dump_hex(desc.physical_start);
        dump_str(" N=");
        dump_hex(desc.number_of_pages);
        dump_str(" A=");
        dump_hex(@bitCast(desc.attribute));
        dump_str("\n");
    }
    var it2 = map.iterator();
    while (it2.next()) |desc| {
        if (desc.type != .memory_mapped_io and desc.type != .memory_mapped_io_port_space) continue;
        if (desc.number_of_pages == 0 or desc.number_of_pages > std.math.maxInt(u64) / 4096) continue;
        const bytes = desc.number_of_pages * 4096;
        if (desc.physical_start > std.math.maxInt(u64) - bytes) continue;
        if (bytes <= 4096) {
            // Small window: dump every non-zero register byte in full.
            dump_raw_sparse(desc.physical_start, @intCast(bytes), "RAW");
        } else {
            // Big window (e.g. the efivars store): base string only.
            dump_raw(desc.physical_start, 64, "RAW");
        }
    }
}

// ---------------------------------------------------------------------------
// Claim 0021 diagnostic: firmware MMU-state capture (-Dfw-mmu-capture,
// default off). Pre-exit, while the firmware translation regime is still
// live, record SCTLR/TCR/MAIR/TTBR0/TTBR1/ID_AA64MMFR0 plus a bounded walk
// of the firmware's TTBR0 tables for the virtio BAR0 window (the
// claim-0020 post-switch hang target) and a RAM control address, and the
// kernel's planned values — so the host can diff the two translation
// regimes. Persisted as the single small ASCII variable `VirelaiMmu` via
// the proven pre-exit SetVariable channel (no re-write of the big
// `VirelaiProbe` chunks — the store budget is ~61 KB on VZ, claim 0015).
// ---------------------------------------------------------------------------
const mmu_var_name = utf16z("VirelaiMmu");
var mmu_dump: [4096]u8 = undefined;
var mmu_dump_len: usize = 0;

fn mmu_str(text: []const u8) void {
    if (text.len > mmu_dump.len - mmu_dump_len) return;
    @memcpy(mmu_dump[mmu_dump_len .. mmu_dump_len + text.len], text);
    mmu_dump_len += text.len;
}

fn mmu_hex(value: u64) void {
    var tmp: [18]u8 = undefined;
    tmp[0] = '0';
    tmp[1] = 'x';
    var index: usize = 2;
    var shift: u6 = 60;
    while (true) : (shift -= 4) {
        const digit: u8 = @intCast((value >> shift) & 0xf);
        tmp[index] = if (digit < 10) '0' + digit else 'a' + digit - 10;
        index += 1;
        if (shift == 0) break;
    }
    mmu_str(tmp[0..index]);
}

fn read_sctlr() u64 {
    var value: u64 = undefined;
    asm volatile ("mrs %[value], sctlr_el1"
        : [value] "=r" (value),
    );
    return value;
}

fn read_tcr() u64 {
    var value: u64 = undefined;
    asm volatile ("mrs %[value], tcr_el1"
        : [value] "=r" (value),
    );
    return value;
}

fn read_mair() u64 {
    var value: u64 = undefined;
    asm volatile ("mrs %[value], mair_el1"
        : [value] "=r" (value),
    );
    return value;
}

fn read_ttbr0() u64 {
    var value: u64 = undefined;
    asm volatile ("mrs %[value], ttbr0_el1"
        : [value] "=r" (value),
    );
    return value;
}

fn read_ttbr1() u64 {
    var value: u64 = undefined;
    asm volatile ("mrs %[value], ttbr1_el1"
        : [value] "=r" (value),
    );
    return value;
}

/// Initial lookup level for a 4 K-granule TTBR0 walk from the VA width
/// W = 64 - T0SZ (ARM ARM, translation table lookup rules): W 39..48 → L0,
/// 30..38 → L1, 21..29 → L2, 12..20 → L3.
fn fw_initial_level(va_width: usize) u8 {
    if (va_width >= 39) return 0;
    if (va_width >= 30) return 1;
    if (va_width >= 21) return 2;
    return 3;
}

const FwWalk = struct {
    found: bool,
    level: u8,
    entry: u64,
    entry_addr: u64,
};

/// Bounded walk of a TTBR0 table tree (4 K granule) for `va`, starting at
/// the initial level implied by T0SZ. Records the final descriptor (block or
/// page) or stops at an invalid entry. Volatile reads: the tables are plain
/// firmware RAM, fully readable pre-exit.
fn fw_walk(ttbr0: u64, t0sz: u6, va: u64) FwWalk {
    var result = FwWalk{ .found = false, .level = 0, .entry = 0, .entry_addr = 0 };
    if (ttbr0 == 0) return result;
    const va_width: usize = 64 - @as(usize, t0sz);
    var level: u8 = fw_initial_level(va_width);
    var addr = ttbr0 & ~@as(u64, 0xfff);
    while (level <= 3) {
        const shift: u6 = switch (level) {
            0 => 39,
            1 => 30,
            2 => 21,
            else => 12,
        };
        const index = (va >> shift) & 0x1ff;
        const entry_addr = addr + index * 8;
        const entry = @as(*const volatile u64, @ptrFromInt(entry_addr)).*;
        result.entry_addr = entry_addr;
        const kind = entry & 3;
        if (kind == 0) return result; // invalid
        if (kind == 1 or level == 3) { // block (or page at L3)
            result.found = true;
            result.level = level;
            result.entry = entry;
            return result;
        }
        addr = entry & ~@as(u64, 0xfff); // table: descend
        level += 1;
    }
    return result;
}

/// Append one decoded descriptor line: kind, output base, MAIR attr index +
/// byte, AF/SH/AP/XN bits.
fn mmu_describe(tag: []const u8, walk: FwWalk, mair: u64) void {
    mmu_str(tag);
    mmu_str(" L");
    mmu_str(&.{'0' + walk.level});
    mmu_str(" @");
    mmu_hex(walk.entry_addr);
    mmu_str(" E=");
    mmu_hex(walk.entry);
    if (!walk.found) {
        mmu_str(" INV\n");
        return;
    }
    const out_shift: u6 = switch (walk.level) {
        0 => 39,
        1 => 30,
        2 => 21,
        else => 12,
    };
    // Output address field = bits [47:out_shift] of the descriptor (the
    // bits above 47 are attributes such as XN/PXN and must be masked out).
    const out_bits: u6 = 48 - out_shift;
    const out = ((walk.entry >> out_shift) & ((@as(u64, 1) << out_bits) - 1)) << out_shift;
    mmu_str(if ((walk.entry & 3) == 1) " BLK out=" else " PAG out=");
    mmu_hex(out);
    const aidx = (walk.entry >> 2) & 7;
    mmu_str(" AIDX=");
    mmu_hex(aidx);
    mmu_str(" A=");
    mmu_hex((mair >> @intCast(aidx * 8)) & 0xff);
    mmu_str(" AF=");
    mmu_hex((walk.entry >> 10) & 1);
    mmu_str(" SH=");
    mmu_hex((walk.entry >> 8) & 3);
    mmu_str(" AP=");
    mmu_hex((walk.entry >> 6) & 3);
    mmu_str(" XN=");
    mmu_hex((walk.entry >> 54) & 1);
    mmu_str("\n");
}

/// Claim 0021 capture (build-gated by the caller). `vp_ready`/`vp_bar0`
/// are the virtio transport discovery results, passed in by the caller
/// (main.zig orchestrates; the transport lives in virtio_console.zig).
pub fn fw_mmu_capture_diag(st: *const SystemTable, handoff_rec: *const handoff.HandoffV2, vp_ready: bool, vp_bar0: u64) void {
    mmu_dump_len = 0;
    const sctlr = read_sctlr();
    const tcr = read_tcr();
    const mair = read_mair();
    const ttbr0 = read_ttbr0();
    const ttbr1 = read_ttbr1();
    const mmfr0 = mmu.read_mmfr0();

    mmu_str("MMU SCTLR=");
    mmu_hex(sctlr);
    mmu_str("\n");
    mmu_str("MMU TCR=");
    mmu_hex(tcr);
    const t0sz: u6 = @intCast(tcr & 0x3f);
    const va_width: usize = 64 - @as(usize, t0sz);
    mmu_str(" T0SZ=");
    mmu_hex(t0sz);
    mmu_str(" W=");
    mmu_hex(va_width);
    mmu_str(" INITLVL=");
    mmu_hex(fw_initial_level(va_width));
    mmu_str(" TG0=");
    // ARMv8.1+ layout: TG0 at bits [15:14] (0b00 = 4 K granule).
    mmu_hex((tcr >> 14) & 3);
    mmu_str("\n");
    mmu_str("MMU MAIR=");
    mmu_hex(mair);
    mmu_str("\n");
    mmu_str("MMU TTBR0=");
    mmu_hex(ttbr0);
    mmu_str("\n");
    mmu_str("MMU TTBR1=");
    mmu_hex(ttbr1);
    mmu_str("\n");
    mmu_str("MMU IDAA64MMFR0=");
    mmu_hex(mmfr0);
    mmu_str("\n");

    // Walk the firmware's TTBR0 tables for the virtio BAR0 window (the
    // post-switch hang target, claim 0020) and a RAM control address.
    if (vp_ready and vp_bar0 != 0) {
        mmu_str("MMU WALK BAR va=");
        mmu_hex(vp_bar0);
        mmu_str("\n");
        mmu_describe("MMU   ", fw_walk(ttbr0, t0sz, vp_bar0), mair);
    } else {
        mmu_str("MMU WALK BAR va=none (transport not armed)\n");
    }
    mmu_str("MMU WALK RAM va=");
    mmu_hex(handoff_rec.stack_base);
    mmu_str("\n");
    mmu_describe("MMU   ", fw_walk(ttbr0, t0sz, handoff_rec.stack_base), mair);

    // The kernel's planned values, for the host-side diff. T0SZ is
    // mmu.plan_t0sz (production 16, claim 1517; class-D -Dt0sz25 selects the
    // legacy 25), so the capture reports the true planned TCR in both
    // variants.
    const ips: u64 = @min(mmu.read_mmfr0() & 0xf, 5);
    mmu_str("MMU KERNEL-PLAN MAIR=");
    mmu_hex(0x000000000000ff00); // Attr0 Device-nGnRnE, Attr1 Normal WB
    mmu_str(" TCR=");
    mmu_hex(mmu.plan_t0sz | (ips << 32));
    mmu_str(" TTBR0=");
    mmu_hex(mmu.table_root());
    if (vp_ready and vp_bar0 != 0) {
        mmu_str(" BAR=");
        mmu_hex(vp_bar0);
        mmu_str("|0x403"); // Device 4 K page descriptor: 0x3 | AF(1<<10)
    }
    mmu_str("\n");

    _ = st.runtime_services._setVariable(
        &mmu_var_name,
        &marker_vendor_guid,
        .{ .non_volatile = true, .bootservice_access = true, .runtime_access = true },
        mmu_dump_len,
        mmu_dump[0..mmu_dump_len].ptr,
    );
}
