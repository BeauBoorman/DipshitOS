//! VirelaiOS exception vectors (claim 9746 — the first half of roadmap
//! item 5; GIC + timer programming is the next card).
//!
//! Installs a real VBAR_EL1 vector table with basic synchronous and IRQ
//! handlers. Until this module, any fault at EL1 silently hung (no vectors
//! programmed); now a synchronous exception produces an `[EXC]` report over
//! the kernel console — ESR_EL1 (class + ISS), FAR_EL1, ELR_EL1, SPSR_EL1,
//! and the x0/x30 saved at the fault — and either resumes (only for a
//! deliberate test fault, see `trigger_test_fault`) or parks.
//!
//! Vector layout: a single contiguous 2048-byte region, one self-contained
//! stub per 128-byte architectural vector slot (4 exception types x 4
//! source modes; the kernel runs at EL1h — SPSel=1, observed SPSR.M=0x5 on
//! VZ — so the EL1h vectors at 0x200..0x380 are the current-EL entries).
//! Each stub saves a register frame on the current SP,
//! passes (frame, esr, far, elr, spsr, kind) to the shared C dispatch,
//! then either restores the frame and `eret`s (resume) or parks in WFE.
//! The region is pure position-independent code with no cross-region
//! branch or absolute address, so it is correct at any load base — the
//! flat loader applies no relocations (claim 0015 root cause).
//!
//! IRQ handling (claim 7948): with a dispatcher registered
//! (`set_irq_dispatcher` — the GIC ack -> timer handle -> GIC eoi chain),
//! taken IRQs dispatch to it and the stub `eret`s back to the interrupted
//! instruction with no report. Without one, IRQ/FIQ/SError vectors report
//! + park: nothing programs the GIC in that case, so an IRQ cannot legally
//! fire; if one does, reporting and parking beats silently running off
//! into firmware vectors. The synchronous handler's resume path is the
//! only place ELR_EL1 is rewritten, and only while `resume_armed` is set
//! by `trigger_test_fault` (the `virelai> fault` command). The dispatcher
//! runs in IRQ context with a register frame on the stack and MUST NOT
//! touch the console (claim 7948: heartbeats print from the shell idle
//! loop).
//!
//! No libc, no POSIX, no allocation, no GIC programming (that lives in
//! gic.zig / timer.zig; this module only routes taken IRQs to it).

const std = @import("std");
const builtin = @import("builtin");
const uaccess = @import("uaccess.zig"); // claim 6120: fault-safe copy-in/copy-out window
const mmu = @import("mmu.zig");
const alloc = @import("alloc.zig");
const process = @import("process.zig");
const scheduler = @import("scheduler.zig");
const svclock = @import("svclock.zig"); // claim 9498 follow-on: demand-paging faults gate only the KERNEL domain (mmap-region/registry state)
const memmap = @import("memmap.zig");
const userspace = @import("userspace.zig");
const forensics = @import("forensics.zig"); // #1261: exception-entry probe (inert unless `forensics on`)
const tombstone = @import("tombstone.zig"); // M97c #2098: pid-bound fault evidence for crash receipts
const sampler = @import("sampler.zig");
const timer = @import("timer.zig");
const gic = @import("gic.zig");

// ---------------------------------------------------------------------------
// Exception kinds (the x5 value each stub passes; also the vector offset's
// low 5 bits, 0x0/0x8/0x10/0x18 in 32-bit slots, i.e. 0x000/0x080/0x100/0x180
// per mode).
// ---------------------------------------------------------------------------

pub const kind_sync: u64 = 0;
pub const kind_irq: u64 = 1;
pub const kind_fiq: u64 = 2;
pub const kind_serror: u64 = 3;

/// Saved by every vector stub, in reverse pair order because each `stp`
/// pre-decrements the stack. Keeping the layout helpers here prevents SVC
/// handlers from repeating the easy-to-get-wrong slot arithmetic.
pub const vector_frame_slots: usize = 32;
pub const vector_frame_bytes: u64 = vector_frame_slots * @sizeOf(u64);

/// The FP/SIMD block every vector stub pushes below the GPR frame (q0..q31,
/// 512 bytes) so the kernel may use NEON freely without corrupting EL0 state
/// that was live across the exception (claim 8877 bisect: DESKTOP's marker
/// build hoisted `ldr q0` across an `svc` and the kernel's ReleaseSmall
/// memcpy destroyed it). The C-visible `VectorFrame` EXCLUDES this block;
/// the restore macro pops it first via `sub sp, x0, #fp_save_bytes` + 16
/// `ldp q` pairs. `build_initial_frame` reserves the same block (zeroed)
/// beneath every synthetic frame.
pub const fp_save_bytes: u64 = 32 * @sizeOf(u128);
pub const VectorFrame = [vector_frame_slots]u64;

fn frame_index(reg: u5) ?usize {
    if (reg <= 17) return 18 - 2 * (@as(usize, reg) / 2) + (@as(usize, reg) & 1);
    if (reg == 30) return 0;
    // Claim 6729: the callee-saved extension (x19..x28 + x29) appended at
    // the TOP of the frame ([20..31]) by the vector stubs' first pushes.
    if (reg == 29) return 20;
    if (reg >= 19 and reg <= 28) return @as(usize, if (reg % 2 == 0) 51 else 49) - reg;
    return null;
}

pub fn frame_read(frame: *const VectorFrame, reg: u5) u64 {
    const index = frame_index(reg) orelse return 0;
    return frame[index];
}

pub fn frame_write(frame: *VectorFrame, reg: u5, value: u64) bool {
    const index = frame_index(reg) orelse return false;
    frame[index] = value;
    return true;
}

var sample_read_active: [4]bool = [_]bool{false} ** 4;
var sample_read_fault: [4]bool = [_]bool{false} ** 4;

/// IRQ-only, fault-safe user read with EL0 permissions. LDTR refuses the
/// identity overlay even if another thread unmaps a page after validation.
/// Two loads total; no demand paging, service lock, allocation or console.
pub fn read_sample_frame(address: u64, bytes: *[16]u8) bool {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64)
        return uaccess.copy_in(bytes, address, bytes.len) == .ok;
    const c = resume_core();
    const active: *volatile bool = &sample_read_active[c];
    const fault: *volatile bool = &sample_read_fault[c];
    fault.* = false;
    active.* = true;
    asm volatile ("" ::: .{ .memory = true });
    defer {
        asm volatile ("" ::: .{ .memory = true });
        active.* = false;
    }
    var previous: u64 = 0;
    asm volatile ("ldtr %[v], [%[address]]"
        : [v] "=r" (previous),
        : [address] "r" (address),
        : .{ .memory = true });
    if (fault.*) return false;
    var lr: u64 = 0;
    asm volatile ("ldtr %[v], [%[address]]"
        : [v] "=r" (lr),
        : [address] "r" (address + 8),
        : .{ .memory = true });
    if (fault.*) return false;
    std.mem.writeInt(u64, bytes[0..8], previous, .little);
    std.mem.writeInt(u64, bytes[8..16], lr, .little);
    return true;
}

// ---------------------------------------------------------------------------
// Report writer (set by the kernel seam so this module stays transport-
// agnostic and host-testable).
// ---------------------------------------------------------------------------

var report_writer: ?*const fn ([]const u8) void = null;

/// Set the console writer the `[EXC]` report is emitted through. The
/// kernel passes a wrapper over its polled uart; host tests may leave it
/// null and assert on `format_report` directly.
pub fn init(writer: *const fn ([]const u8) void) void {
    report_writer = writer;
    // Issue #1391: arm the kernel -> user destination resolver. Every
    // `uaccess.copy_out` asks it before it stores, because under a task's
    // root a user VA that has no EL0 leaf still resolves for EL1 into the
    // EL1-only identity overlay — a store there is silently lost. The
    // resolver demand-populates the page in the process's own root or
    // refuses the copy; see `ensure_user_write_pages`.
    uaccess.resolve_write_pages = ensure_user_write_pages;
    // Issue #2109: arm the read-direction twin — every `uaccess.copy_in` and
    // `load_u32` asks it before it loads, because a source page with no EL0
    // leaf still resolves for EL1 into the identity overlay and the load
    // returns kernel physical memory at PA == VA. The resolver is the same
    // proof: the process's own page or refusal.
    uaccess.resolve_read_pages = ensure_user_read_pages;
}

// ---------------------------------------------------------------------------
// IRQ dispatcher (claim 7948)
// ---------------------------------------------------------------------------

/// Called for every taken IRQ (kind == kind_irq) once registered. Runs in
/// IRQ context with a register frame on the stack: it must not touch the
/// console (the timer heartbeat prints from the shell idle loop instead).
pub const IrqDispatcher = *const fn () void;

var irq_dispatcher: ?IrqDispatcher = null;

/// Register the IRQ chain (kernel seam: gic.ack -> timer.handle ->
/// scheduler.tick -> gic.eoi composed in main.zig). Host tests can
/// register a plain function and assert dispatch behavior.
pub fn set_irq_dispatcher(d: IrqDispatcher) void {
    irq_dispatcher = d;
}

/// Minimal synchronous lower-EL seam. The registered handler owns only
/// recognized AArch64 SVC exceptions from EL0t; returning false leaves the
/// exception on the normal report-and-park path. The mutable vector frame is
/// the syscall ABI: arguments arrive in saved GPRs and x0 carries the result.
pub const SvcDispatcher = *const fn (*VectorFrame, u16) bool;

var svc_dispatcher: ?SvcDispatcher = null;

pub fn set_svc_dispatcher(d: SvcDispatcher) void {
    svc_dispatcher = d;
}

/// Milestone sixteen C2 (claim 8403): the EL0-fault seam. Called for a
/// synchronous exception taken FROM EL0 (SPSR.M == 0) that is NOT an SVC and
/// NOT a recoverable uaccess fault — a hostile program stepping off its
/// stack into a guard page, executing from data, or touching unmapped memory.
/// The registered handler reaps the faulting process (status
/// `scheduler.reserved_fault_status`) and stages the next task, so the
/// machine never parks on a user fault. Host tests can register a plain
/// function and assert dispatch behavior.
pub const FaultDispatcher = *const fn (esr: u64, far: u64, pc: u64) void;

var fault_dispatcher: ?FaultDispatcher = null;

pub fn set_fault_dispatcher(d: FaultDispatcher) void {
    fault_dispatcher = d;
}

/// True when a sync exception originated at EL0t (SPSR.M[3:0] == 0).
pub fn is_from_el0(spsr: u64) bool {
    return (spsr & 0xf) == 0;
}

// ---------------------------------------------------------------------------
// Issue #1228 (phase 0c): EL0 fault delivery to a registered process
// handler (the Fuchsia-exception-channel pattern, synchronous form).
// ---------------------------------------------------------------------------

/// Exception classes a registered handler receives instead of the reap
/// path: EL0 data/instruction aborts, PC/SP alignment faults, and
/// illegal encodings (EC 0x00 unknown-reason). Debug classes (breakpoint,
/// step, watchpoint, BRK) stay reap-only — no debugger exists yet to back
/// them, and silently swallowing a BRK would hide kernel/user bugs alike.
pub fn fault_deliverable(ec: u64) bool {
    return switch (ec) {
        0x00, 0x20, 0x22, 0x24, 0x26 => true,
        else => false,
    };
}

/// Signal number per delivered class. The values match the GOOS=virelai
/// runtime's `_SIGILL`/`_SIGBUS`/`_SIGSEGV` so the handler can classify
/// without parsing ESR itself (ESR still rides in x3 for forensics).
pub fn fault_signal(ec: u64) u64 {
    return switch (ec) {
        0x00 => 4, // SIGILL: illegal encoding
        0x22, 0x26 => 7, // SIGBUS: PC/SP alignment
        else => 11, // SIGSEGV: data/instruction abort
    };
}

/// Fault address per delivered class. FAR_EL1 is meaningless for PC/SP
/// alignment faults, so the faulting PC rides along instead (the M22 D3
/// rule already used for BRK).
pub fn fault_addr(ec: u64, far: u64, elr: u64) u64 {
    return switch (ec) {
        0x22, 0x26 => elr,
        else => far,
    };
}

/// The ELR redirect the delivery writes. Host-test-visible: on hardware
/// this is `msr elr_el1` (like the resume-armed path below); under test
/// the `msr` cannot execute, so the target is staged here for the assert.
pub var test_redirect_pc: u64 = 0;

fn redirect_elr(handler: u64) void {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) {
        test_redirect_pc = handler;
        return;
    }
    asm volatile ("msr elr_el1, %[v]"
        :
        : [v] "r" (handler),
    );
    asm volatile ("isb");
}

/// Try to deliver an EL0 fault to the current process's registered
/// handler. On success the saved frame carries the fault record
/// (x0=sig, x1=addr, x2=pc, x3=esr, x4=sp_el0, x5=lr, x6=r29 — x5/x6 ride
/// in place, the handler reads them), ELR points at the handler, and the
/// caller resumes the SAME frame. Returns false (the reap path runs) when
/// the class is not deliverable, no handler is registered, or the fault
/// PC is already the handler (a fault INSIDE the handler — reaping beats
/// a delivery loop). Runs in exception context: no console, no
/// allocation, only the scheduler/process lookups the reap path uses.
fn try_deliver_fault(esr: u64, far: u64, elr: u64, frame: *VectorFrame, sp_el0: u64) bool {
    const ec = (esr >> 26) & 0x3f;
    if (!fault_deliverable(ec)) return false;
    const pid = process.find_by_task(scheduler.current_id()) orelse return false;
    const handler = process.exnotify_handler(pid) orelse return false;
    if (handler == 0 or elr == handler) return false;
    _ = frame_write(frame, 0, fault_signal(ec));
    _ = frame_write(frame, 1, fault_addr(ec, far, elr));
    _ = frame_write(frame, 2, elr);
    _ = frame_write(frame, 3, esr);
    _ = frame_write(frame, 4, sp_el0);
    redirect_elr(handler);
    return true;
}

/// Per-core count for the staged resume seam. Mirrors `smp.max_cores`; a
/// direct import would cycle (smp.zig imports this module for
/// `install`/`irq_unmask`).
pub const max_resume_cores: usize = 4;

/// Local core index for the per-core resume seam (0 on host tests;
/// clamped like `smp.core_id`).
fn resume_core() usize {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return 0;
    var mpidr: u64 = 0;
    asm volatile ("mrs %[v], mpidr_el1"
        : [v] "=r" (mpidr),
    );
    const aff0: usize = @intCast(mpidr & 0xff);
    return if (aff0 < max_resume_cores) aff0 else 0;
}

/// The vector-frame pointer the IRQ stub must restore from when the
/// dispatcher chain returns (claim 5275). PER-CORE (issue #820 family):
/// set to the interrupted task's frame at IRQ entry on the local core; the
/// scheduler may rewrite it to the next task's frame, and the stub's
/// `mov sp, x0` + register restore + `eret` then lands in that task as if
/// IT had been interrupted. A single global was corrupted two ways: (a)
/// same-EL IRQ nesting — AArch64 same-EL exception entry leaves
/// PSTATE.DAIF unchanged and the vector stubs never masked IRQ, so a timer
/// IRQ taken inside the tick handler overwrote the outer frame and the
/// outer handler saved/restored the nested mid-handler frame (a task
/// resumed holding the GIC/timer handler's register image — the
/// x23=0x1e/x26=0x10040080 crash family); (b) on SMP, core 1's exception
/// entry unconditionally overwrote core 0's staged frame mid-handler.
/// Meaningful only in IRQ context, on the local core.
pub var resume_frame: [max_resume_cores]u64 = [_]u64{0} ** max_resume_cores;

/// SP_EL0 to install before the vector stub restores registers and `eret`s.
/// EL1h tasks do not consume it, but an EL0t task must regain its separate
/// userspace stack when scheduled after an EL1 task. Per-core like
/// `resume_frame`.
pub var resume_sp_el0: [max_resume_cores]u64 = [_]u64{0} ** max_resume_cores;
/// Source-frame guard released only after the vector has changed SP. The
/// pointer array is per-core; restore scratch registers are still saved.
pub export var exc_scheduler_handoff: [max_resume_cores]?*u64 = @splat(null);
pub export var exc_scheduler_depth: [max_resume_cores]u64 = @splat(0);

/// Unmask IRQs (clear DAIF.I). The caller arms the GIC + timer first so no
/// interrupt can arrive before the chain is ready. No-op on non-aarch64
/// hosts (never meaningful in a host test process).
pub fn irq_unmask() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    asm volatile ("msr daifclr, #2");
}

// ---------------------------------------------------------------------------
// Install
// ---------------------------------------------------------------------------

/// Program VBAR_EL1 with the vector region. No-op on non-aarch64 hosts
/// (the module must stay `zig test`-able on x86_64 CI). The vector region
/// is emitted only for aarch64 targets (see `exception_vectors`).
pub fn install() void {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    const table_addr = @intFromPtr(&exception_vectors);
    asm volatile ("msr vbar_el1, %[addr]"
        :
        : [addr] "r" (table_addr),
    );
    asm volatile ("isb");
    installed_flag = true;
}

/// True once `install` has actually programmed VBAR_EL1 (only inside the
/// kernel — never in a host test process, even on an aarch64 host where a
/// user-space `msr` or `udf` would SIGILL). The `fault` command gates on
/// this, so a host transcript can never execute the real instructions.
var installed_flag: bool = false;
pub fn installed() bool {
    return installed_flag;
}

// ---------------------------------------------------------------------------
// Counters
// ---------------------------------------------------------------------------

/// Issue #810-family audit (claim 8513): PER-CORE. Every exception on
/// every core increments this at `exc_dispatch` entry, and the secondary
/// cores' timer IRQs fire in parallel with the scheduler core's dispatch —
/// a shared counter was a plain RMW race that lost increments. Indexed by
/// `resume_core()`; `handled_count()` sums the slots. Same literal-4
/// rationale as `max_resume_cores` above (smp imports this module).
var handled_count_value: [max_resume_cores]u64 = [_]u64{0} ** max_resume_cores;
var resume_count_value: u64 = 0;

/// Total exceptions taken since boot.
pub fn handled_count() u64 {
    var sum: u64 = 0;
    for (handled_count_value) |v| sum += v;
    return sum;
}

/// Exceptions that were resumed (the deliberate test fault).
pub fn resume_count() u64 {
    return resume_count_value;
}

// ---------------------------------------------------------------------------
// Pure decoders (host-tested)
// ---------------------------------------------------------------------------

/// ESR_EL1 EC (bits [31:26]) -> human name. Bounded table; unknown classes
/// decode to a stable "ec-unknown-0x<hex>" string.
pub fn ec_name(esr: u64) []const u8 {
    return switch ((esr >> 26) & 0x3f) {
        0x00 => "unknown-reason",
        0x01 => "trapped-wfi-wfe",
        0x15 => "svc64",
        0x18 => "trapped-msr-mrs",
        0x19 => "trapped-eret",
        0x20 => "instruction-abort-lower",
        0x21 => "instruction-abort-same",
        0x22 => "pc-alignment",
        0x24 => "data-abort-lower",
        0x25 => "data-abort-same",
        0x26 => "sp-alignment",
        0x30 => "breakpoint-lower",
        0x31 => "breakpoint-same",
        0x32 => "step-lower",
        0x33 => "step-same",
        0x34 => "watchpoint-lower",
        0x35 => "watchpoint-same",
        0x3c => "brk64",
        else => "ec-unknown",
    };
}

/// Decode the AArch64 source mode from SPSR_EL1.M[3:0]. The old decoder
/// shifted every mode up by one exception level and called the observed
/// 0x5 EL1t; architecturally it is EL1h.
pub fn mode_name(spsr: u64) []const u8 {
    return switch (spsr & 0xf) {
        0x0 => "EL0t",
        0x4 => "EL1t",
        0x5 => "EL1h",
        0x8 => "EL2t",
        0x9 => "EL2h",
        0xc => "EL3t",
        0xd => "EL3h",
        else => "mode-unknown",
    };
}

pub fn is_svc64_from_el0(kind: u64, esr: u64, spsr: u64) bool {
    return kind == kind_sync and ((esr >> 26) & 0x3f) == 0x15 and (spsr & 0xf) == 0;
}

/// Decode the exception kind (the stub's x5) to a report name.
pub fn kind_name(kind: u64) []const u8 {
    return switch (kind) {
        0 => "sync",
        1 => "irq",
        2 => "fiq",
        3 => "serror",
        else => "exc-kind-unknown",
    };
}

/// May the handler resume execution after the report? Only a synchronous
/// exception while the deliberate test fault is armed. Pure decision so
/// the host tests pin the exact rule.
pub fn should_resume(kind: u64, armed: bool) bool {
    return armed and kind == kind_sync;
}

// ---------------------------------------------------------------------------
// Report formatting (pure, host-tested)
// ---------------------------------------------------------------------------

const hex_digits = "0123456789abcdef";

fn append_slice(buf: []u8, text: []const u8) usize {
    if (text.len > buf.len) return 0;
    @memcpy(buf[0..text.len], text);
    return text.len;
}

/// Fixed-width lowercase hex (no "0x" prefix), `digits` wide.
fn append_hex(buf: []u8, value: u64, digits: usize) usize {
    if (digits > buf.len) return 0;
    var index: usize = 0;
    while (index < digits) : (index += 1) {
        const shift = 4 * (digits - 1 - index);
        buf[index] = hex_digits[@as(usize, @intCast((value >> @intCast(shift)) & 0xf))];
    }
    return digits;
}

/// Decimal u64 (no padding).
fn append_u64(buf: []u8, value: u64) usize {
    var tmp: [20]u8 = undefined;
    var index: usize = 0;
    var v = value;
    if (v == 0) {
        if (buf.len == 0) return 0;
        buf[0] = '0';
        return 1;
    }
    while (v > 0) : (v /= 10) {
        tmp[index] = @intCast('0' + (v % 10));
        index += 1;
    }
    if (index > buf.len) return 0;
    var out: usize = 0;
    while (index > 0) {
        index -= 1;
        buf[out] = tmp[index];
        out += 1;
    }
    return out;
}

/// Claim 9094 (#810): EL1h data-abort deep dump. Prints the translation
/// system registers, a bounded 4-level stage-1 walk of `far` (root from
/// TTBR0_EL1, 4 KiB granules; bails on non-RAM table addresses), and the
/// kernel stack window around `raw_sp` with any value that looks like a
/// text address (within ±0x50000 of `elr`) flagged for the offline
/// symbol decode. Pure reads — safe from the synchronous handler.
pub fn deep_dump(buf: []u8, esr: u64, far: u64, elr: u64, raw_sp: u64) []const u8 {
    _ = esr; // reserved: the EC/ISS decode is printed by format_report
    var pos: usize = 0;
    pos += append_slice(buf[pos..], "[DEEP] ttbr0=0x");
    var ttbr0: u64 = 0;
    var ttbr1: u64 = 0;
    var mair: u64 = 0;
    var tcr: u64 = 0;
    asm volatile ("mrs %[v], ttbr0_el1"
        : [v] "=r" (ttbr0),
    );
    asm volatile ("mrs %[v], ttbr1_el1"
        : [v] "=r" (ttbr1),
    );
    asm volatile ("mrs %[v], mair_el1"
        : [v] "=r" (mair),
    );
    asm volatile ("mrs %[v], tcr_el1"
        : [v] "=r" (tcr),
    );
    pos += append_hex(buf[pos..], ttbr0, 16);
    pos += append_slice(buf[pos..], " ttbr1=0x");
    pos += append_hex(buf[pos..], ttbr1, 16);
    pos += append_slice(buf[pos..], " mair=0x");
    pos += append_hex(buf[pos..], mair, 16);
    pos += append_slice(buf[pos..], " tcr=0x");
    pos += append_hex(buf[pos..], tcr, 16);
    pos += append_slice(buf[pos..], "\n");
    pos += append_slice(buf[pos..], "[DEEP] user_stack_va=0x");
    pos += append_hex(buf[pos..], userspace.user_stack_va(), 16);
    pos += append_slice(buf[pos..], "\n");
    // Bounded 4-level walk of far (4 KiB granules, T0SZ=16 -> 48-bit VA).
    // Every table address is RAM below 4 GiB; anything else bails.
    pos += append_slice(buf[pos..], "[DEEP] walk far=0x");
    pos += append_hex(buf[pos..], far, 16);
    pos += append_slice(buf[pos..], "\n");
    const root = ttbr0 & 0xffff_ffff_f000;
    var table: u64 = root;
    const shift_table = [_]u6{ 39, 30, 21, 12 };
    const block_mask = [_]u64{ 0, 0x3f_ffff, 0x1f_ffff, 0xfff };
    // Claim 9094 lesson: every read here must stay below the RAM ceiling
    // (0x80000000 = top of the guest's 2 GiB RAM @ 0 — the kernel image
    // loads at ~0x7daa…, i.e. 2 GiB − 22 MiB; run-13 far=0x20080296 =
    // 512 MiB+ region; NOT the "256 MiB @ 0x70000000" label guessed
    // earlier). The first version's unbound walk/crawl recursed
    // SEA-on-SEA inside the dump itself (the run-7/8 storm ate the boot
    // stack to text); bounded reads are SEA-proof, so one hang = exactly
    // one clean dump.
    const ram_ceiling: u64 = 0x8000_0000;
    var level: u4 = 0;
    var done = false;
    var walk_ok = true;
    while (level < 4 and !done and walk_ok) {
        const idx = (far >> shift_table[level]) & 0x1ff;
        if (table >= ram_ceiling or table < 0x1000) { // not a RAM table address
            walk_ok = false;
            break;
        }
        const pte_addr = table + idx * 8;
        const pte: u64 = if (pte_addr < ram_ceiling) @as(*const u64, @ptrFromInt(pte_addr)).* else 0;
        pos += append_slice(buf[pos..], "[DEEP]   l");
        pos += append_u64(buf[pos..], level);
        pos += append_slice(buf[pos..], " idx=0x");
        pos += append_hex(buf[pos..], idx, 3);
        pos += append_slice(buf[pos..], " pte=0x");
        pos += append_hex(buf[pos..], pte, 16);
        pos += append_slice(buf[pos..], "\n");
        if ((pte & 1) == 0) {
            done = true; // unmapped at this level
            break;
        }
        if ((pte & 0x200) != 0 or level == 3) { // block or page leaf
            pos += append_slice(buf[pos..], "[DEEP]   leaf pa=0x");
            pos += append_hex(buf[pos..], (pte & ~block_mask[level]) | (far & block_mask[level]), 16);
            pos += append_slice(buf[pos..], "\n");
            done = true;
            break;
        }
        table = pte & 0xffff_ffff_f000;
        level += 1;
    }
    if (!walk_ok) {
        pos += append_slice(buf[pos..], "[DEEP]   walk aborted (non-RAM table)\n");
    }
    // Claim 9094 (v2): stack crawl runs DOWNWARD from raw_sp (the stack
    // grows down — the interrupted function's frame and its callers' saved
    // x30/x29 links live BELOW raw_sp; the v1 crawl went UP into unused
    // stack and printed only the known GPR-frame slots). Rows in the
    // vector frames (raw_sp-768..raw_sp: the 256-byte GPR frame + 512-byte
    // FP block) print unconditionally; deeper rows print only when the
    // word looks like a text address (candidate saved return address),
    // so one clean fault yields the caller chain in bounded output.
    pos += append_slice(buf[pos..], "[DEEP] stack\n");
    var off: u64 = 0;
    var skipped: u64 = 0;
    while (off < 2304) : (off += 8) {
        const addr = raw_sp -% off -% 16;
        const in_vector_frames = addr >= raw_sp -% 768;
        const word: u64 = if (addr < ram_ceiling and addr >= 0x1000) @as(*const u64, @ptrFromInt(addr)).* else 0;
        const near_text = (word >= elr -% 0x80000 and word <= elr +% 0x80000);
        if (!in_vector_frames and !near_text) {
            skipped += 1;
            continue;
        }
        if (skipped > 0 and near_text) {
            pos += append_slice(buf[pos..], "[DEEP]   ...");
            pos += append_u64(buf[pos..], skipped);
            pos += append_slice(buf[pos..], " non-text words\n");
            skipped = 0;
        }
        pos += append_slice(buf[pos..], "[DEEP]   ");
        pos += append_hex(buf[pos..], addr, 12);
        pos += append_slice(buf[pos..], " ");
        if (near_text) {
            pos += append_slice(buf[pos..], "T ");
            pos += append_hex(buf[pos..], word, 16);
        } else {
            pos += append_slice(buf[pos..], "  ");
            pos += append_hex(buf[pos..], word, 16);
        }
        pos += append_slice(buf[pos..], "\n");
        if (pos > buf.len - 96) break; // stay inside the caller's buffer
    }
    return buf[0..pos];
}

/// Claim 9094 (#810): EL1h-only extended dump — the volatile registers
/// x3..x17 (the [EXC] report prints x0/x1/x2 and x19..x28; x8 and the
/// arg registers are exactly what the faulting call was holding) and the
/// eight raw instruction words at `elr` ± 16 bytes, so the report names
/// its own fault site without offline symbol games (the booted image's
/// offsets drift per build; raw words disassemble against the exact ELF).
pub fn el1h_extras(buf: []u8, frame: *const VectorFrame, elr: u64) []const u8 {
    var pos: usize = 0;
    // Volatile registers x3..x17, two per line, mirroring the [EXC] shape.
    var idx: usize = 3;
    while (idx <= 17) : (idx += 2) {
        pos += append_slice(buf[pos..], "[EXC]     x");
        pos += append_u64(buf[pos..], idx);
        pos += append_slice(buf[pos..], "=0x");
        pos += append_hex(buf[pos..], frame_read(frame, @intCast(idx)), 16);
        pos += append_slice(buf[pos..], " x");
        pos += append_u64(buf[pos..], idx + 1);
        pos += append_slice(buf[pos..], "=0x");
        pos += append_hex(buf[pos..], frame_read(frame, @intCast(idx + 1)), 16);
        pos += append_slice(buf[pos..], "\n");
    }
    // Instruction words around elr (bounded RAM reads; text sits below the
    // RAM ceiling in the booted image). Read-only, SEA-proof by the bounds.
    pos += append_slice(buf[pos..], "[DEEP] insn@elr-16..elr+16:\n");
    const ram_ceiling: u64 = 0x8000_0000;
    var i: i64 = -4;
    while (i <= 4) : (i += 1) {
        const addr = elr +% @as(u64, @bitCast(i * 4));
        const word: u32 = if (addr < ram_ceiling and addr >= 0x1000) @as(*const u32, @ptrFromInt(addr)).* else 0;
        pos += append_slice(buf[pos..], "[DEEP]   ");
        pos += append_hex(buf[pos..], addr, 16);
        pos += append_slice(buf[pos..], " 0x");
        pos += append_hex(buf[pos..], word, 8);
        if (i == 0) pos += append_slice(buf[pos..], "  <== elr");
        pos += append_slice(buf[pos..], "\n");
    }
    return buf[0..pos];
}

/// Format the full `[EXC]` report into `buf` (caller-owned, >= 512 bytes
/// recommended) and return the written slice. Deterministic byte-for-byte:
/// the class B gate asserts substrings of this exact shape in vm-serial.log.
pub fn format_report(
    buf: []u8,
    kind: u64,
    esr: u64,
    far: u64,
    elr: u64,
    spsr: u64,
    count: u64,
    x0: u64,
    x30: u64,
    sp_el0: u64,
    x1: u64,
    x2: u64,
    x29: u64,
    will_resume: bool,
    /// Raw kernel SP_EL1 at vector entry (the pre-push stack pointer). The
    /// stubs push the 32-slot GPR frame (256 bytes) below the SP that was
    /// live at the fault, so "frame base + 256" recovers it exactly without
    /// any asm change. Only meaningful for EL1h entries (SPSel=1 at entry:
    /// kernel-mode faults). Pass 0 for EL0t/user faults.
    raw_sp: u64,
    /// Callee-saved registers x19..x28 (claim 6729: frame slots [30..21]).
    /// These belong to the interrupted kernel function (they must survive
    /// calls), so they identify WHERE the fault happened far better than the
    /// volatile x0/x1/x2 already reported.
    x19: u64,
    x20: u64,
    x21: u64,
    x22: u64,
    x23: u64,
    x24: u64,
    x25: u64,
    x26: u64,
    x27: u64,
    x28: u64,
) []const u8 {
    var pos: usize = 0;

    pos += append_slice(buf[pos..], "[EXC] ");
    pos += append_slice(buf[pos..], kind_name(kind));
    pos += append_slice(buf[pos..], " from ");
    pos += append_slice(buf[pos..], mode_name(spsr));
    pos += append_slice(buf[pos..], " count=");
    pos += append_u64(buf[pos..], count);
    pos += append_slice(buf[pos..], "\n");

    pos += append_slice(buf[pos..], "[EXC] esr=0x");
    pos += append_hex(buf[pos..], esr, 16);
    pos += append_slice(buf[pos..], " ec=0x");
    pos += append_hex(buf[pos..], (esr >> 26) & 0x3f, 2);
    pos += append_slice(buf[pos..], " ");
    pos += append_slice(buf[pos..], ec_name(esr));
    pos += append_slice(buf[pos..], " iss=0x");
    pos += append_hex(buf[pos..], esr & 0xffffff, 6);
    pos += append_slice(buf[pos..], "\n");

    pos += append_slice(buf[pos..], "[EXC] far=0x");
    pos += append_hex(buf[pos..], far, 16);
    pos += append_slice(buf[pos..], "\n");

    pos += append_slice(buf[pos..], "[EXC] elr=0x");
    pos += append_hex(buf[pos..], elr, 16);
    pos += append_slice(buf[pos..], " spsr=0x");
    pos += append_hex(buf[pos..], spsr, 16);
    pos += append_slice(buf[pos..], "\n");

    pos += append_slice(buf[pos..], "[EXC] x0=0x");
    pos += append_hex(buf[pos..], x0, 16);
    pos += append_slice(buf[pos..], " x30=0x");
    pos += append_hex(buf[pos..], x30, 16);
    pos += append_slice(buf[pos..], "\n");

    pos += append_slice(buf[pos..], "[EXC] sp=0x");
    pos += append_hex(buf[pos..], sp_el0, 16);
    pos += append_slice(buf[pos..], " x1=0x");
    pos += append_hex(buf[pos..], x1, 16);
    pos += append_slice(buf[pos..], " x2=0x");
    pos += append_hex(buf[pos..], x2, 16);
    pos += append_slice(buf[pos..], " x29=0x");
    pos += append_hex(buf[pos..], x29, 16);
    pos += append_slice(buf[pos..], "\n");

    if (raw_sp != 0) {
        pos += append_slice(buf[pos..], "[EXC] raw_sp=0x");
        pos += append_hex(buf[pos..], raw_sp, 16);
        pos += append_slice(buf[pos..], " x19=0x");
        pos += append_hex(buf[pos..], x19, 16);
        pos += append_slice(buf[pos..], " x20=0x");
        pos += append_hex(buf[pos..], x20, 16);
        pos += append_slice(buf[pos..], " x21=0x");
        pos += append_hex(buf[pos..], x21, 16);
        pos += append_slice(buf[pos..], " x22=0x");
        pos += append_hex(buf[pos..], x22, 16);
        pos += append_slice(buf[pos..], "\n");
        pos += append_slice(buf[pos..], "[EXC]     x23=0x");
        pos += append_hex(buf[pos..], x23, 16);
        pos += append_slice(buf[pos..], " x24=0x");
        pos += append_hex(buf[pos..], x24, 16);
        pos += append_slice(buf[pos..], " x25=0x");
        pos += append_hex(buf[pos..], x25, 16);
        pos += append_slice(buf[pos..], " x26=0x");
        pos += append_hex(buf[pos..], x26, 16);
        pos += append_slice(buf[pos..], " x27=0x");
        pos += append_hex(buf[pos..], x27, 16);
        pos += append_slice(buf[pos..], " x28=0x");
        pos += append_hex(buf[pos..], x28, 16);
        pos += append_slice(buf[pos..], "\n");
    }

    if (will_resume) {
        pos += append_slice(buf[pos..], "[EXC] resume-armed: skipping faulting instruction\n");
    } else {
        pos += append_slice(buf[pos..], "[EXC] parking: no recovery path for this exception\n");
    }
    return buf[0..pos];
}

// ---------------------------------------------------------------------------
// Deliberate test fault (`virelai> fault`)
// ---------------------------------------------------------------------------

/// Arm the resume flag and execute a permanently-undefined instruction.
/// The synchronous handler sees `resume_armed`, reports, advances ELR_EL1
/// past the 32-bit `udf`, and returns — so this function returns normally
/// and the shell continues. On non-aarch64 hosts this is a no-op (no
/// vectors exist in a host test binary).
pub fn trigger_test_fault() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (!installed_flag) return; // host test process: never execute `udf`
    resume_armed = true;
    asm volatile ("udf #0x0" ::: .{ .memory = true });
}

var resume_armed: bool = false;

// ---------------------------------------------------------------------------
// Shared C dispatch (called by every vector stub)
// ---------------------------------------------------------------------------

/// Shared handler for every vector. `frame` is the saved register frame
/// pushed by the stub ([0] = x30, [1] = pad, [2..19] = x16..x17 through
/// x0..x1 in descending register-pair order); the
/// system registers are passed in from the stub's `mrs` reads. Returns the
/// vector-frame pointer the stub should restore from (then `eret`), or 0
/// to park. For the plain IRQ/sync paths that is the entry frame itself
/// (the restore macro selects that frame); a context-switching
/// dispatcher chain may return another task's frame (claim 5275).
///
/// Must be callable from the naked asm with exactly this signature and
/// symbol name (`bl exc_dispatch`), hence `export` + `callconv(.c)`.
pub const Resume = extern struct {
    frame: u64,
    sp_el0: u64,
};

fn read_sp_el0() u64 {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return 0;
    var value: u64 = 0;
    asm volatile ("mrs %[v], sp_el0"
        : [v] "=r" (value),
    );
    return value;
}

fn source_sp_el0(frame: *const VectorFrame, spsr: u64) u64 {
    // An EL1t source used SP_EL0 for the vector frame itself; once the 160
    // saved bytes are popped, that task's logical stack is frame+160.
    if ((spsr & 0xf) == 0x4) return @intFromPtr(frame) + vector_frame_bytes;
    // EL1h and EL0t sources preserve SP_EL0 independently while the vector
    // and C dispatcher run on SP_EL1.
    return read_sp_el0();
}

fn zero_phys_page(pa: u64) void {
    if (builtin.is_test) return;
    const pa_ptr: [*]u8 = @ptrFromInt(pa);
    @memset(pa_ptr[0..4096], 0);
}

fn copy_phys_page(dst_pa: u64, src_pa: u64) void {
    if (builtin.is_test) return;
    const dst_ptr: [*]u8 = @ptrFromInt(dst_pa);
    const src_ptr: [*]const u8 = @ptrFromInt(src_pa);
    @memcpy(dst_ptr[0..4096], src_ptr[0..4096]);
}

pub var demand_fault_count: u64 = 0;
pub var cow_fault_count: u64 = 0;

/// M29 VM Depth: Attempt to resolve a synchronous page fault from EL0.
/// Handles zero-fill demand faults (translation faults DFSC=0x4..0x7) and
/// Copy-on-Write (permission faults DFSC=0xc..0xf on write).
pub fn try_handle_page_fault(esr: u64, far: u64) bool {
    const ec = (esr >> 26) & 0x3f;
    // Only handle EL0 Data Aborts (0x24)
    if (ec != 0x24) return false;
    // Userspace-service gate (claim 9498): the mapping below allocates
    // physical pages and mutates the process registry — the same state
    // exec/mmap syscalls hold the kernel-domain lock over on ANY core.
    // Runs in exception context (IRQ-masked): the holder always runs to
    // completion, so spinning is safe.
    svclock.kernel.acquire();
    defer svclock.kernel.release();

    const pid = if (process.find_by_task(scheduler.current_id())) |p|
        p
    else if (process.current()) |p|
        p
    else
        return false;
    const pinfo = process.info(pid) orelse return false;
    const root = pinfo.root_phys;
    if (root == 0) return false;

    const dfsc = esr & 0x3f;
    const is_write = ((esr >> 6) & 1) != 0;

    // Case 1: Permission fault (0xc..0xf) on write -> Copy-on-Write (COW)
    if (is_write and (dfsc >= 0xc and dfsc <= 0xf)) {
        if (mmu.get_user_leaf(root, far)) |leaf_ptr| {
            if ((leaf_ptr.* & mmu.sw_cow) != 0) {
                const old_pa = leaf_ptr.* & 0x0000_ffff_ffff_f000;
                // M97b (#2110): trust only a RECORDED refcount. `page_refcount`
                // reports 1 for an untracked page, which is exactly what a
                // shared page looked like once the side table filled — the
                // promote-in-place below then flipped the WM's RO `sw_cow`
                // mirror writable on the OWNER's page. An unrecorded leaf's
                // provenance is unproven: the fault is delivered, never
                // promoted and never split-and-unref'd (the untracked unref
                // would free a page the owner still maps).
                const refcount = alloc.page_refcount_recorded(old_pa) orelse return false;
                if (refcount <= 1) {
                    mmu.set_user_leaf_writable(leaf_ptr, true);
                    mmu.invalidate_tlb_va(far);
                    cow_fault_count += 1;
                    return true;
                } else {
                    const new_pa = alloc.alloc_pages(1) orelse return false;
                    copy_phys_page(new_pa, old_pa);
                    const owned_old = process.owns_dynamic_page(pid, old_pa);
                    if (!process.replace_dynamic_page(pid, old_pa, new_pa)) {
                        _ = alloc.free_pages(new_pa, 1);
                        return false;
                    }
                    const page_va = far & ~@as(u64, 0xfff);
                    if (!mmu.map_user_page(root, page_va, new_pa, true, false)) {
                        if (owned_old) {
                            _ = process.replace_dynamic_page(pid, new_pa, old_pa);
                        } else {
                            _ = process.forget_dynamic_page(pid, new_pa);
                        }
                        _ = alloc.free_pages(new_pa, 1);
                        return false;
                    }
                    _ = alloc.unref_page(old_pa);
                    cow_fault_count += 1;
                    return true;
                }
            }
        }
    }

    // Case 2: zero-fill demand paging (translation fault 0x4..0x7 OR a
    // permission fault on an address the EL1-only identity overlay still
    // covers — the clone copies that overlay verbatim, so an untouched user
    // page is present-but-AP=0b00 rather than absent). ONE resolution,
    // shared with the kernel -> user copy path (issue #1391), so both agree
    // on what counts as this process's page.
    if (populate_user_page(pid, root, far, is_write)) return true;

    return false;
}

/// Issue #1391: populate ONE 4 KiB page of `pid` at `va` in the process's OWN
/// root — the mapping EL0 will actually read — and record it for teardown.
/// The VA must be a demand region of the process: one of its anonymous mmap
/// regions (that region's prot picks the leaf) or its stack aperture
/// (writable, grown down). Anything else returns false, which both callers
/// treat as "not this process's page": the fault path reaps or delivers it,
/// the copy path refuses with EFAULT. Nothing here ever falls back to the
/// identity overlay — that is the defect this function exists to close.
/// The caller holds the kernel domain lock (allocator + process registry).
///
/// #2112: populate only a GENUINE demand fault — a VA the process owns but
/// has not yet mapped. `for_write` is the fault's WnR bit (the uaccess copy
/// path passes true): a store to a page the region does not make writable,
/// a read the region does not make readable, and any access to a page that
/// already has an EL0 leaf are program faults to deliver — allocating a
/// fresh page over the leaf would just fault again on the retry, leaking
/// one page per iteration until the pool drains.
pub fn populate_user_page(pid: usize, root: u64, va: u64, for_write: bool) bool {
    const page = va & ~@as(u64, 0xfff);
    var readable = false;
    var writable = false;
    var executable = false;
    var demand = false;
    if (process.find_mmap_region(pid, page)) |mreg| {
        readable = (mreg.prot & 1) != 0;
        writable = (mreg.prot & 2) != 0;
        executable = (mreg.prot & 4) != 0;
        demand = true;
    } else if (process.info(pid)) |inf| {
        if (inf.stack_len > 0 and page >= inf.stack_va and page < inf.stack_va + inf.stack_len) {
            readable = true;
            writable = true;
            demand = true;
        }
    }
    if (!demand) return false;
    // The fault is only serviceable when the region admits the access — an
    // already-mapped page faults for its own reason (permissions, COW was
    // tried above) and must be delivered, not re-populated.
    if (mmu.leaf_el0_visible(root, page)) return false;
    if (for_write) {
        if (!writable) return false;
    } else if (!readable and !writable) return false;
    const pa = alloc.alloc_pages(1) orelse return false;
    zero_phys_page(pa);
    if (!process.record_dynamic_page(pid, pa)) {
        _ = alloc.free_pages(pa, 1);
        return false;
    }
    if (!mmu.map_user_page(root, page, pa, writable, executable)) {
        _ = process.forget_dynamic_page(pid, pa);
        _ = alloc.free_pages(pa, 1);
        return false;
    }
    demand_fault_count += 1;
    return true;
}

/// Issue #1391: the destination resolver armed into
/// `uaccess.resolve_write_pages`. A kernel -> user store may only land in a
/// page the CURRENT process's own root exposes to EL0; anything else either
/// stores through the EL1-only identity overlay (the bytes are lost, the
/// syscall still reports success — the M61b/M61c zeros) or is memory the
/// process does not own. Returns true when every 4 KiB page of
/// [address, address+len) is EL0-visible after the call — demand-populating
/// the ones that are not — and false when a page is not the process's to map,
/// in which case `copy_out` refuses with EFAULT and touches nothing.
///
/// The caller has already validated the range against the task's uaccess
/// write regions, so a refusal here means the region view and the page tables
/// disagree — a real bug — rather than a hostile pointer. Host test binaries
/// have neither user roots nor a live process; there the seam is a no-op and
/// the copy primitives keep their off-guest contract.
pub fn ensure_user_write_pages(address: u64, len: usize) bool {
    if (comptime builtin.is_test) return true;
    const pid = if (process.find_by_task(scheduler.current_id())) |p|
        p
    else if (process.current()) |p|
        p
    else
        return false;
    const inf = process.info(pid) orelse return false;
    const root = inf.root_phys;
    if (root == 0) return false;
    // Mapping allocates pages and records them on the process descriptor —
    // state exec/mmap mutate under the kernel domain lock, and the canonical
    // order puts that lock LAST. This runs under the caller's own domain lock
    // (FILE for a read, KERNEL for mmap/pipes), so take only the bits this
    // core does not already hold: acquiring it again on the same core would
    // self-deadlock an IRQ-masking spinlock.
    const taken = svclock.acquire_missing(svclock.dom_bit(.kernel));
    defer svclock.release_set(taken);
    const end = address +% len;
    if (end < address) return false;
    var page = address & ~@as(u64, 0xfff);
    while (page < end) : (page += 4096) {
        if (!mmu.leaf_el0_visible(root, page)) {
            if (!populate_user_page(pid, root, page, true)) return false;
        }
    }
    return true;
}

/// Issue #2109: the source resolver armed into `uaccess.resolve_read_pages`.
/// A user -> kernel load may only read a page the CURRENT process's own root
/// exposes to EL0; anything else loads through the EL1-only identity overlay
/// and returns kernel physical memory at PA == VA — an information-disclosure
/// primitive into every copy_in result (file_write, tcp/udp/ipc send,
/// clipboard, pipe_write, the futex word). The proof is the same one
/// `ensure_user_write_pages` runs: a registered-but-unpopulated demand page
/// is populated in the process's own root (the copy reads the zero page EL0
/// itself would fault in — never the twin), and a page that is not the
/// process's to map refuses the copy with EFAULT having read nothing.
/// Host test binaries keep the off-guest no-op contract.
pub fn ensure_user_read_pages(address: u64, len: usize) bool {
    return ensure_user_write_pages(address, len);
}

pub export fn exc_dispatch(
    frame: *VectorFrame,
    esr: u64,
    far: u64,
    elr: u64,
    spsr: u64,
    kind: u64,
) callconv(.c) Resume {
    const cid = resume_core(); // per-core resume handoff (issue #810)
    exc_scheduler_depth[cid] += 1;
    const schedulable = exc_scheduler_depth[cid] == 1 and (kind == kind_irq or is_from_el0(spsr));
    if (schedulable) scheduler.begin_exception(cid);
    if (exc_scheduler_depth[cid] == 1)
        exc_scheduler_handoff[cid] = if (schedulable) scheduler.exception_handoff(cid) else null;
    defer if (builtin.is_test and schedulable) scheduler.end_exception(cid);
    defer if (builtin.is_test) {
        exc_scheduler_depth[cid] -= 1;
        if (exc_scheduler_depth[cid] == 0) exc_scheduler_handoff[cid] = null;
    };
    handled_count_value[cid] += 1; // per-core: secondary-core IRQs fire in parallel
    // #1261: record exception ENTRY, before any GIC state is consumed. The
    // post-ack `irq` probe cannot distinguish "the interrupt stopped being
    // delivered" from "it was delivered but acked as spurious"; this one
    // fires the instant C code takes control, and its cadence vs the `irq`
    // cadence and the `rearm` cadence separates the two.
    forensics.note(.entry, kind);
    resume_frame[cid] = @intFromPtr(frame);
    resume_sp_el0[cid] = source_sp_el0(frame, spsr);
    // Claim 7948: taken IRQs route to the registered dispatcher (GIC ack
    // -> timer handle -> scheduler tick -> GIC eoi); the stub restores the
    // frame and erets. IRQs were masked until the whole chain was armed,
    // so a dispatcher that is present is always ready. Without one (host
    // tests, or the pre-GIC milestone), IRQs fall through to the report +
    // park path. Claim 5275: stage the interrupted task's frame pointer so
    // the scheduler can save it (and rewrite it to the next task's frame);
    // the stub's `mov sp, x0` restores from whatever frame is left staged.
    if (kind == kind_irq) {
        if (irq_dispatcher) |d| {
            if (gic.take_profile_interrupt()) |intid| {
                gic.note_irq(intid);
                const interrupted_sp = resume_sp_el0[cid];
                if (intid == gic.profile_update_sgi) {
                    timer.profile_sync_local();
                } else if (timer.profile_handle()) {
                    sampler.on_irq(frame, elr, spsr);
                }
                // A fault-safe FP read may take a nested synchronous abort.
                // Restore the outer IRQ's architectural and staging state,
                // not the copy loop's ELR/SPSR or its kernel stack frame.
                resume_frame[cid] = @intFromPtr(frame);
                resume_sp_el0[cid] = interrupted_sp;
                if (comptime !builtin.is_test and builtin.cpu.arch == .aarch64) {
                    asm volatile ("msr elr_el1, %[v]"
                        :
                        : [v] "r" (elr),
                    );
                    asm volatile ("msr spsr_el1, %[v]"
                        :
                        : [v] "r" (spsr),
                    );
                    asm volatile ("isb");
                }
                gic.eoi(intid);
                return .{ .frame = @intFromPtr(frame), .sp_el0 = interrupted_sp };
            }
            d();
            return .{ .frame = resume_frame[cid], .sp_el0 = resume_sp_el0[cid] };
        }
    }
    if (is_svc64_from_el0(kind, esr, spsr)) {
        if (svc_dispatcher) |d| {
            const immediate: u16 = @truncate(esr & 0xffff);
            if (d(frame, immediate)) {
                // A normal syscall leaves resume_frame pointing at `frame`.
                // Cooperative yield/exit may instead stage another runnable
                // task through the scheduler; honor the same return-frame
                // seam the IRQ path already uses.
                return .{ .frame = resume_frame[cid], .sp_el0 = resume_sp_el0[cid] };
            }
        }
    }
    // Claim 6120: a synchronous data abort while a uaccess window is active
    // is a bad user pointer inside a bounded copy, not a kernel bug. The
    // uaccess module latches the fault and advances ELR past the 4-byte
    // faulting instruction; the copy loop observes the latch and returns
    // EFAULT, so the shell/user task survives. Any other synchronous
    // exception falls through to the normal report/park path.
    if (kind == kind_sync and sample_read_active[cid] and (((esr >> 26) & 0x3f) == 0x25)) {
        @as(*volatile bool, &sample_read_fault[cid]).* = true;
        if (comptime !builtin.is_test and builtin.cpu.arch == .aarch64) {
            asm volatile ("msr elr_el1, %[v]"
                :
                : [v] "r" (elr + 4),
            );
            asm volatile ("isb");
        }
        return .{ .frame = @intFromPtr(frame), .sp_el0 = resume_sp_el0[cid] };
    }
    if (kind == kind_sync and uaccess.try_recover(esr, elr)) {
        return .{ .frame = @intFromPtr(frame), .sp_el0 = resume_sp_el0[cid] };
    }
    // Milestone sixteen C2 (claim 8403): a synchronous exception from EL0
    // that is not an SVC and not a recoverable uaccess fault is checked for
    // M29 VM Depth (demand paging zero-fill translation fault or COW permission
    // fault). If handleable, the page is mapped/promoted and resumed transparently.
    // If not, the fault dispatcher reaps the faulting process safely.
    if (kind == kind_sync and is_from_el0(spsr)) {
        if (try_handle_page_fault(esr, far)) {
            return .{ .frame = @intFromPtr(frame), .sp_el0 = resume_sp_el0[cid] };
        }
        // Issue #1228 (phase 0c): a process with a registered slot-75
        // handler receives deliverable faults synchronously (the runtime
        // converts them to panics); everything else reaps as before.
        if (try_deliver_fault(esr, far, elr, frame, resume_sp_el0[cid])) {
            return .{ .frame = @intFromPtr(frame), .sp_el0 = resume_sp_el0[cid] };
        }
        if (fault_dispatcher) |d| {
            // M22 D3 (issue #326): ELR rides along — BRK faults carry a
            // meaningless FAR but their PC names the crashing function.
            // M97c #2098: pin the fault to THIS task's pid before the
            // dispatcher reaps it — a fault-status tombstone is minted
            // only from evidence bound to the exiting pid, which is what
            // stops a forged `sys_exit(139)` from stamping a receipt with
            // another task's far/pc.
            const fault_pid: u64 = if (process.find_by_task(scheduler.current[cid])) |fpid|
                @intCast(fpid)
            else
                0;
            tombstone.note_fault(fault_pid, far, elr);
            d(esr, far, elr);
            return .{ .frame = resume_frame[cid], .sp_el0 = resume_sp_el0[cid] };
        }
    }
    const will_resume = should_resume(kind, resume_armed);
    var buf: [768]u8 = undefined;
    const raw_sp: u64 = if ((spsr & 0xf) == 0x5) @intFromPtr(frame) + vector_frame_bytes else 0;
    const report = format_report(
        &buf,
        kind,
        esr,
        far,
        elr,
        spsr,
        handled_count(), // claim 7339: summed across cores
        frame_read(frame, 0),
        frame_read(frame, 30),
        resume_sp_el0[cid],
        frame_read(frame, 1),
        frame_read(frame, 2),
        frame_read(frame, 29),
        will_resume,
        raw_sp,
        frame_read(frame, 19),
        frame_read(frame, 20),
        frame_read(frame, 21),
        frame_read(frame, 22),
        frame_read(frame, 23),
        frame_read(frame, 24),
        frame_read(frame, 25),
        frame_read(frame, 26),
        frame_read(frame, 27),
        frame_read(frame, 28),
    );
    if (report_writer) |w| w(report);
    // Claim 9094 (#810 forensics): for EL1h synchronous aborts, append a
    // deep dump — system translation regs, a bounded 4-level PTE walk of
    // FAR, and the saved-return-address crawl of the kernel stack window
    // (the [EXC] register dump alone could not name the faulting path;
    // the parked frames carried elr inside a non-faulting outlined stub).
    // EL1h-only, so EL0 faults and every healthy boot are byte-identical.
    if (kind == kind_sync and (spsr & 0xf) == 0x5) {
        // Claim 9094: the 0x97090010 storm (issue #810) re-enters the
        // faulting path from the parked WFE on every un-masked IRQ, eating
        // the boot stack until it walks into text; masking ALL of DAIF here
        // stops the storm so the ONE original fault's dump stays decodable.
        asm volatile ("msr daifset, #0b1111"); // D|A|I|F
        // Claim 9094: the crawl (saved return addresses) is the call-path
        // evidence, so it prints immediately after the [EXC] header block
        // (run-11 dumps decoded cleanly in this order). The bounded reads
        // + full DAIF mask above are what keep ONE fault = ONE dump — the
        // v1 unbound walk recursed SEA-on-SEA (the run-7/8 storm).
        var deep: [4096]u8 = undefined;
        const d = deep_dump(&deep, esr, far, elr, raw_sp);
        if (report_writer) |w| w(d);
        // Claim 9094 (v2): the volatile registers x3..x17 + raw instruction
        // words at elr — self-decoding evidence for the offline decode.
        var extras: [1024]u8 = undefined;
        const e = el1h_extras(&extras, frame, elr);
        if (report_writer) |w| w(e);
    }
    if (will_resume) {
        resume_armed = false;
        resume_count_value += 1;
        // Skip the 32-bit faulting instruction (the test `udf`), so the
        // resumed code continues right after it instead of re-faulting.
        // Only ever reached while resume_armed was set by the test trigger.
        asm volatile ("msr elr_el1, %[v]"
            :
            : [v] "r" (elr + 4),
        );
        asm volatile ("isb");
        return .{ .frame = @intFromPtr(frame), .sp_el0 = resume_sp_el0[cid] };
    }
    return .{ .frame = 0, .sp_el0 = resume_sp_el0[cid] };
}

// ---------------------------------------------------------------------------
// Vector region (aarch64 only)
// ---------------------------------------------------------------------------

/// The VBAR_EL1 vector region: 16 stubs, one per 128-byte slot (offsets
/// 0x000/0x080/0x100/0x180 x EL1t/EL1h/EL0-64/EL0-32). Each stub saves the
/// full GPR frame (x0..x17 + x30 + the claim-6729 callee set x19..x28 +
/// x29 = 32 slots) on the current SP, passes kind in x5 (0 sync / 1 irq /
/// 2 fiq / 3 serror), and branches to the shared `exc_fp_common`, which
/// pushes the FP/SIMD block (q0..q31, 512 bytes) below the GPR frame,
/// loads (esr, far, elr, spsr) from the EL1 system registers, and calls
/// `exc_dispatch`. On return (x0 != 0) the restore macro pops the FP block
/// first, then the GPR frame, and `eret`s; x0 == 0 parks in WFE.
/// `exc_dispatch` returns a two-register C aggregate: x0 is the vector-frame
/// pointer (the GPR base — `VectorFrame` excludes the FP block) and x1 is
/// the SP_EL0 belonging to the selected task. The restore macro switches
/// to SP_EL1 before installing SP_EL0, so the same exit path safely targets
/// EL1h and EL0t contexts.
///
/// The FP block is the claim 8877 fix: the kernel uses NEON freely (e.g.
/// ReleaseSmall memcpy), and without the save a user `ldr q0` hoisted
/// across an `svc` was silently corrupted — DESKTOP's manifest marker lost
/// its first 15 bytes to exactly the kernel's q0/q1 values.
///
/// The region is emitted only on aarch64: this function is referenced
/// solely from `install`'s comptime-aarch64 branch, so x86 host tests
/// never codegen the AArch64 assembly. `.balign 2048` at the start plus
/// the fn's `align(2048)` guarantee slot i sits at VBAR + i*128; each stub
/// body is 18 instructions (72 bytes: 16 GPR `stp` pairs + `movz` + `b
/// exc_fp_common`), padded to the 128-byte slot boundary by the trailing
/// `.balign 128`. `exc_fp_common` + the tail live beyond the table (the
/// hardware only fetches the 16 slots). The tail pops the full frame and
/// `eret`s — the callee-saved half is what makes the scheduler's per-task
/// context switch safe for compiled tasks (claim 6729 bisect: the shell's
/// live `mon` in x19 was clobbered by the preempting task's value because
/// the old 20-slot frame never saved x19..x28).
fn exception_vectors() align(2048) callconv(.naked) void {
    asm volatile (
        \\.balign 2048
        \\.macro exc_restore
        \\msr spsel, #1
        \\sub sp, x0, #512
        \\ldp q30, q31, [sp], #32
        \\ldp q28, q29, [sp], #32
        \\ldp q26, q27, [sp], #32
        \\ldp q24, q25, [sp], #32
        \\ldp q22, q23, [sp], #32
        \\ldp q20, q21, [sp], #32
        \\ldp q18, q19, [sp], #32
        \\ldp q16, q17, [sp], #32
        \\ldp q14, q15, [sp], #32
        \\ldp q12, q13, [sp], #32
        \\ldp q10, q11, [sp], #32
        \\ldp q8, q9, [sp], #32
        \\ldp q6, q7, [sp], #32
        \\ldp q4, q5, [sp], #32
        \\ldp q2, q3, [sp], #32
        \\ldp q0, q1, [sp], #32
        \\msr sp_el0, x1
        \\// SP now belongs to the selected frame, not the source handler.
        \\// Releasing before this point lets another core overwrite the
        \\// source C epilogue. Release and deferred SGIs need no C call.
        \\adrp x9, exc_scheduler_handoff
        \\add x9, x9, :lo12:exc_scheduler_handoff
        \\mrs x10, mpidr_el1
        \\and x10, x10, #0xff
        \\cmp x10, #4
        \\csel x10, x10, xzr, lo
        \\adrp x11, exc_scheduler_depth
        \\add x11, x11, :lo12:exc_scheduler_depth
        \\ldr x12, [x11, x10, lsl #3]
        \\sub x12, x12, #1
        \\str x12, [x11, x10, lsl #3]
        \\cbnz x12, exc_handoff_done
        \\ldr x11, [x9, x10, lsl #3]
        \\cbz x11, exc_handoff_done
        \\str xzr, [x9, x10, lsl #3]
        \\exc_handoff_release:
        \\ldaxr x12, [x11]
        \\stlxr w13, xzr, [x11]
        \\cbnz w13, exc_handoff_release
        \\lsr x12, x12, #1
        \\cbz x12, exc_handoff_done
        \\// RESCHEDULE is SGI 0; bits 0..3 are its target list.
        \\dsb ishst
        \\msr icc_sgi1r_el1, x12
        \\dsb ish
        \\isb
        \\exc_handoff_done:
        \\b exc_restore_tail
        \\.endm
        \\// Entry 0x000: EL1t synchronous (kind 0)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #0
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x080: EL1t IRQ (kind 1)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #1
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x100: EL1t FIQ (kind 2)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #2
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x180: EL1t SError (kind 3)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #3
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x200: EL1h synchronous (kind 0)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #0
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x280: EL1h IRQ (kind 1)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #1
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x300: EL1h FIQ (kind 2)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #2
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x380: EL1h SError (kind 3)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #3
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x400: lower EL AArch64 synchronous (kind 0)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #0
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x480: lower EL AArch64 IRQ (kind 1)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #1
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x500: lower EL AArch64 FIQ (kind 2)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #2
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x580: lower EL AArch64 SError (kind 3)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #3
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x600: lower EL AArch32 synchronous (kind 0)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #0
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x680: lower EL AArch32 IRQ (kind 1)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #1
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x700: lower EL AArch32 FIQ (kind 2)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #2
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x780: lower EL AArch32 SError (kind 3)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #3
        \\b exc_fp_common
        \\.balign 128
        \\exc_fp_common:
        \\// Issue #820 family (same-EL IRQ nesting): AArch64 exception
        \\// entry to the SAME EL leaves PSTATE.DAIF unchanged, so an IRQ
        \\// taken while already inside an EL1 handler would nest — the
        \\// nested exc_dispatch overwrites the staged resume frame and a
        \\// task resumes holding the nested handler's register image
        \\// (observed: GIC/timer values at two different crash sites). Mask
        \\// IRQ for the whole handler; `eret` restores PSTATE from
        \\// SPSR_EL1 (saved at entry), so the resumed task gets its own
        \\// DAIF back. A no-op for the lower-EL entries, where hardware
        \\// already masks on EL0 -> EL1.
        \\msr daifset, #2
        \\stp q0, q1, [sp, #-32]!
        \\stp q2, q3, [sp, #-32]!
        \\stp q4, q5, [sp, #-32]!
        \\stp q6, q7, [sp, #-32]!
        \\stp q8, q9, [sp, #-32]!
        \\stp q10, q11, [sp, #-32]!
        \\stp q12, q13, [sp, #-32]!
        \\stp q14, q15, [sp, #-32]!
        \\stp q16, q17, [sp, #-32]!
        \\stp q18, q19, [sp, #-32]!
        \\stp q20, q21, [sp, #-32]!
        \\stp q22, q23, [sp, #-32]!
        \\stp q24, q25, [sp, #-32]!
        \\stp q26, q27, [sp, #-32]!
        \\stp q28, q29, [sp, #-32]!
        \\stp q30, q31, [sp, #-32]!
        \\add x0, sp, #512
        \\mrs x1, esr_el1
        \\mrs x2, far_el1
        \\mrs x3, elr_el1
        \\mrs x4, spsr_el1
        \\bl exc_dispatch
        \\cbz x0, exc_park
        \\exc_restore
        \\exc_restore_tail:
        \\ldp x30, xzr, [sp], #16
        \\ldp x16, x17, [sp], #16
        \\ldp x14, x15, [sp], #16
        \\ldp x12, x13, [sp], #16
        \\ldp x10, x11, [sp], #16
        \\ldp x8, x9, [sp], #16
        \\ldp x6, x7, [sp], #16
        \\ldp x4, x5, [sp], #16
        \\ldp x2, x3, [sp], #16
        \\ldp x0, x1, [sp], #16
        \\ldp x29, xzr, [sp], #16
        \\ldp x27, x28, [sp], #16
        \\ldp x25, x26, [sp], #16
        \\ldp x23, x24, [sp], #16
        \\ldp x21, x22, [sp], #16
        \\ldp x19, x20, [sp], #16
        \\eret
        \\exc_park:
        \\wfe
        \\b exc_park
    );
}

// ---------------------------------------------------------------------------
// Tests (host-side; the asm region is proven on real VZ hardware by the
// class B gate, tools/verify-live-exceptions.sh)
// ---------------------------------------------------------------------------

var test_svc_immediate: u16 = 0;
var test_svc_resume_frame: ?*VectorFrame = null;
var test_nested_handoff_preserved = false;

fn test_nested_irq() void {}

fn test_nested_svc(_: *VectorFrame, _: u16) bool {
    const guard = exc_scheduler_handoff[0];
    const saved_frame = resume_frame[0];
    const saved_sp = resume_sp_el0[0];
    var nested: VectorFrame = @splat(0);
    _ = exc_dispatch(&nested, 0, 0, 0, 0x4, kind_irq);
    test_nested_handoff_preserved = exc_scheduler_depth[0] == 1 and
        exc_scheduler_handoff[0] == guard and guard != null and
        (@atomicLoad(u64, guard.?, .acquire) & 1) != 0;
    resume_frame[0] = saved_frame;
    resume_sp_el0[0] = saved_sp;
    return true;
}

test "exceptions: nested dispatch preserves the outer source-stack handoff (#1965)" {
    _ = scheduler.init();
    _ = scheduler.register_worker(0x1111).?;
    const user = scheduler.register_user(0x2222, 0).?;
    scheduler.start();
    try std.testing.expect(scheduler.yield_current());
    const old_irq = irq_dispatcher;
    const old_svc = svc_dispatcher;
    defer irq_dispatcher = old_irq;
    defer svc_dispatcher = old_svc;
    set_irq_dispatcher(test_nested_irq);
    set_svc_dispatcher(test_nested_svc);
    test_nested_handoff_preserved = false;
    var frame: VectorFrame = @splat(0);
    const resumed = exc_dispatch(&frame, 0x15 << 26, 0, 0x2222, 0, kind_sync);
    try std.testing.expect(test_nested_handoff_preserved);
    try std.testing.expectEqual(@intFromPtr(&frame), resumed.frame);
    try std.testing.expectEqual(@as(u64, 0), exc_scheduler_depth[0]);
    try std.testing.expect(exc_scheduler_handoff[0] == null);
    try std.testing.expectEqual(@as(u64, 0), scheduler.tasks[user].exception_guard);
}

fn test_svc_handler(frame: *VectorFrame, immediate: u16) bool {
    test_svc_immediate = immediate;
    _ = frame_write(frame, 0, frame_read(frame, 0) + 1);
    if (test_svc_resume_frame) |selected| resume_frame[0] = @intFromPtr(selected);
    return true;
}

var test_fault_esr: u64 = 0;
var test_fault_far: u64 = 0;
var test_fault_resume_frame: ?*VectorFrame = null;

fn test_exnotify_handler(esr: u64, far: u64, pc: u64) void {
    _ = pc; // M22 D3: the PC rides along for symbol resolution; tests ignore it
    test_fault_esr = esr;
    test_fault_far = far;
    if (test_fault_resume_frame) |selected| resume_frame[0] = @intFromPtr(selected);
}

test "exceptions: ec_name decodes known and unknown classes" {
    try std.testing.expectEqualStrings("unknown-reason", ec_name(0x00000000));
    try std.testing.expectEqualStrings("unknown-reason", ec_name(0x00000000)); // udf
    try std.testing.expectEqualStrings("svc64", ec_name(0x15 << 26));
    try std.testing.expectEqualStrings("trapped-msr-mrs", ec_name(0x18 << 26));
    try std.testing.expectEqualStrings("data-abort-same", ec_name(0x25 << 26));
    try std.testing.expectEqualStrings("brk64", ec_name(0x3c << 26));
    try std.testing.expectEqualStrings("ec-unknown", ec_name(0x3f << 26));
}

test "exceptions: mode_name decodes SPSR M field" {
    try std.testing.expectEqualStrings("EL0t", mode_name(0x0));
    try std.testing.expectEqualStrings("EL1t", mode_name(0x4));
    try std.testing.expectEqualStrings("EL1h", mode_name(0x5));
    try std.testing.expectEqualStrings("EL2t", mode_name(0x8));
    try std.testing.expectEqualStrings("EL2h", mode_name(0x9));
    try std.testing.expectEqualStrings("EL3t", mode_name(0xc));
    try std.testing.expectEqualStrings("EL3h", mode_name(0xd));
    try std.testing.expectEqualStrings("mode-unknown", mode_name(0x1));
}

test "exceptions: vector-frame helpers match the reverse stp layout" {
    var frame: VectorFrame = [_]u64{0} ** vector_frame_slots;
    try std.testing.expect(frame_write(&frame, 0, 0x10));
    try std.testing.expect(frame_write(&frame, 1, 0x11));
    try std.testing.expect(frame_write(&frame, 8, 0x18));
    try std.testing.expect(frame_write(&frame, 17, 0x21));
    try std.testing.expect(frame_write(&frame, 30, 0x30));
    try std.testing.expectEqual(@as(u64, 0x10), frame[18]);
    try std.testing.expectEqual(@as(u64, 0x11), frame[19]);
    try std.testing.expectEqual(@as(u64, 0x18), frame[10]);
    try std.testing.expectEqual(@as(u64, 0x21), frame[3]);
    try std.testing.expectEqual(@as(u64, 0x30), frame[0]);
    try std.testing.expectEqual(@as(u64, 0x18), frame_read(&frame, 8));
    // Claim 6729: the callee-saved extension is writable and lands at the
    // frame top ([20] = x29, [30] = x19, [31] = x20).
    try std.testing.expect(frame_write(&frame, 29, 0x29));
    try std.testing.expect(frame_write(&frame, 19, 0x19));
    try std.testing.expect(frame_write(&frame, 20, 0x20));
    try std.testing.expectEqual(@as(u64, 0x29), frame[20]);
    try std.testing.expectEqual(@as(u64, 0x19), frame[30]);
    try std.testing.expectEqual(@as(u64, 0x20), frame[31]);
    try std.testing.expectEqual(@as(u64, 0x29), frame_read(&frame, 29));
    try std.testing.expect(!frame_write(&frame, 18, 1)); // x18 is not part of the frame
    try std.testing.expect(!frame_write(&frame, 31, 1)); // x31 (SP) is not saved
}

test "exceptions: only AArch64 SVC from EL0t reaches the SVC seam" {
    const svc_esr: u64 = (0x15 << 26) | 0x42;
    try std.testing.expect(is_svc64_from_el0(kind_sync, svc_esr, 0x0));
    try std.testing.expect(!is_svc64_from_el0(kind_irq, svc_esr, 0x0));
    try std.testing.expect(!is_svc64_from_el0(kind_sync, svc_esr, 0x5));
    try std.testing.expect(!is_svc64_from_el0(kind_sync, 0, 0x0));
}

test "exceptions: is_from_el0 matches SPSR M field 0x0 only" {
    try std.testing.expect(is_from_el0(0x0));
    try std.testing.expect(!is_from_el0(0x4));
    try std.testing.expect(!is_from_el0(0x5));
    try std.testing.expect(!is_from_el0(0xd));
}

test "exceptions: an EL0 sync fault reaches the fault dispatcher and resumes its frame" {
    var frame: VectorFrame = [_]u64{0} ** vector_frame_slots;
    var selected: VectorFrame = [_]u64{0} ** vector_frame_slots;
    test_fault_esr = 0;
    test_fault_far = 0;
    test_fault_resume_frame = &selected;
    set_fault_dispatcher(test_exnotify_handler);
    // A data-abort-lower (EC 0x24) from EL0 (SPSR.M == 0) at FAR 0x7fff_f000.
    const esr: u64 = 0x24 << 26;
    const result = exc_dispatch(&frame, esr, 0x7fff_f000, 0x4000, 0, kind_sync);
    try std.testing.expectEqual(esr, test_fault_esr);
    try std.testing.expectEqual(@as(u64, 0x7fff_f000), test_fault_far);
    try std.testing.expectEqual(@intFromPtr(&selected), result.frame);
    test_fault_resume_frame = null;
}

test "exceptions: SVC dispatcher mutates x0 and resumes the same EL0 frame" {
    var frame: VectorFrame = [_]u64{0} ** vector_frame_slots;
    try std.testing.expect(frame_write(&frame, 0, 41));
    test_svc_immediate = 0;
    test_svc_resume_frame = null;
    set_svc_dispatcher(test_svc_handler);
    const esr: u64 = (0x15 << 26) | 0x1234;
    const dispatch_result = exc_dispatch(&frame, esr, 0, 0x4000, 0, kind_sync);
    try std.testing.expectEqual(@intFromPtr(&frame), dispatch_result.frame);
    try std.testing.expectEqual(@as(u64, 0), dispatch_result.sp_el0); // host has no SP_EL0
    try std.testing.expectEqual(@as(u16, 0x1234), test_svc_immediate);
    try std.testing.expectEqual(@as(u64, 42), frame_read(&frame, 0));
}

test "exceptions: handled SVC may select another existing scheduler frame" {
    var frame: VectorFrame = [_]u64{0} ** vector_frame_slots;
    var selected: VectorFrame = [_]u64{0} ** vector_frame_slots;
    test_svc_resume_frame = &selected;
    set_svc_dispatcher(test_svc_handler);
    const result = exc_dispatch(&frame, 0x15 << 26, 0, 0x4000, 0, kind_sync);
    try std.testing.expectEqual(@intFromPtr(&selected), result.frame);
    test_svc_resume_frame = null;
}

test "exceptions: fault delivery classifies, signals, and addresses purely" {
    // Deliverable: illegal encoding, aborts, alignment.
    try std.testing.expect(fault_deliverable(0x00));
    try std.testing.expect(fault_deliverable(0x20));
    try std.testing.expect(fault_deliverable(0x22));
    try std.testing.expect(fault_deliverable(0x24));
    try std.testing.expect(fault_deliverable(0x26));
    // Reap-only: SVC, debug classes, IRQs-as-kind never reach here.
    try std.testing.expect(!fault_deliverable(0x15));
    try std.testing.expect(!fault_deliverable(0x25));
    try std.testing.expect(!fault_deliverable(0x30));
    try std.testing.expect(!fault_deliverable(0x3c));
    // Signals match the runtime's _SIGILL/_SIGBUS/_SIGSEGV.
    try std.testing.expectEqual(@as(u64, 4), fault_signal(0x00));
    try std.testing.expectEqual(@as(u64, 7), fault_signal(0x22));
    try std.testing.expectEqual(@as(u64, 7), fault_signal(0x26));
    try std.testing.expectEqual(@as(u64, 11), fault_signal(0x20));
    try std.testing.expectEqual(@as(u64, 11), fault_signal(0x24));
    // FAR rides for aborts; the PC rides for alignment (FAR meaningless).
    try std.testing.expectEqual(@as(u64, 0xdead), fault_addr(0x24, 0xdead, 0x5000));
    try std.testing.expectEqual(@as(u64, 0xdead), fault_addr(0x20, 0xdead, 0x5000));
    try std.testing.expectEqual(@as(u64, 0x5000), fault_addr(0x22, 0xdead, 0x5000));
    try std.testing.expectEqual(@as(u64, 0x5000), fault_addr(0x26, 0xdead, 0x5000));
}

test "exceptions: kind_name is stable" {
    try std.testing.expectEqualStrings("sync", kind_name(0));
    try std.testing.expectEqualStrings("irq", kind_name(1));
    try std.testing.expectEqualStrings("fiq", kind_name(2));
    try std.testing.expectEqualStrings("serror", kind_name(3));
    try std.testing.expectEqualStrings("exc-kind-unknown", kind_name(9));
}

test "exceptions: resume decision is sync-and-armed only" {
    try std.testing.expect(should_resume(kind_sync, true));
    try std.testing.expect(!should_resume(kind_sync, false));
    try std.testing.expect(!should_resume(kind_irq, true));
    try std.testing.expect(!should_resume(kind_fiq, true));
    try std.testing.expect(!should_resume(kind_serror, true));
}

test "exceptions: format_report is deterministic (resume path)" {
    var buf: [512]u8 = undefined;
    // A udf at EL1h: ESR EC=0x00 (unknown reason), SPSR.M=0x5 (EL1h).
    const esr: u64 = 0;
    const report = format_report(&buf, kind_sync, esr, 0, 0x7e4dfabc, 0x5, 1, 0x2a, 0x7e4df000, 0x1234, 0x2b, 0x2c, 0x29, true, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqualStrings(
        "[EXC] sync from EL1h count=1\n" ++
            "[EXC] esr=0x0000000000000000 ec=0x00 unknown-reason iss=0x000000\n" ++
            "[EXC] far=0x0000000000000000\n" ++
            "[EXC] elr=0x000000007e4dfabc spsr=0x0000000000000005\n" ++
            "[EXC] x0=0x000000000000002a x30=0x000000007e4df000\n" ++
            "[EXC] sp=0x0000000000001234 x1=0x000000000000002b x2=0x000000000000002c x29=0x0000000000000029\n" ++
            "[EXC] resume-armed: skipping faulting instruction\n",
        report,
    );
}

test "exceptions: format_report is deterministic (park path, irq)" {
    var buf: [512]u8 = undefined;
    const esr: u64 = 0x80000000; // EC=0x20 (instruction abort, lower EL)
    const report = format_report(&buf, kind_irq, esr, 0xdead0000, 0x1234, 0x0, 7, 0, 0, 0, 0, 0, 0, false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqualStrings(
        "[EXC] irq from EL0t count=7\n" ++
            "[EXC] esr=0x0000000080000000 ec=0x20 instruction-abort-lower iss=0x000000\n" ++
            "[EXC] far=0x00000000dead0000\n" ++
            "[EXC] elr=0x0000000000001234 spsr=0x0000000000000000\n" ++
            "[EXC] x0=0x0000000000000000 x30=0x0000000000000000\n" ++
            "[EXC] sp=0x0000000000000000 x1=0x0000000000000000 x2=0x0000000000000000 x29=0x0000000000000000\n" ++
            "[EXC] parking: no recovery path for this exception\n",
        report,
    );
}

test "exceptions: install and trigger never execute in a host test process" {
    // On x86_64 CI these are comptime no-ops. On an aarch64 host the test
    // process is user-space EL0: executing `msr vbar_el1` or `udf` would
    // SIGILL, so the test must not call them there — the real vectors are
    // proven on VZ hardware by the class B gate
    // (tools/verify-live-exceptions.sh) instead.
    if (comptime builtin.cpu.arch == .aarch64) return;
    install();
    trigger_test_fault();
    try std.testing.expect(handled_count() == 0);
}

test "exceptions: report buffer is bounded (max-size fields never overflow)" {
    var buf: [512]u8 = undefined;
    const report = format_report(
        &buf,
        kind_serror,
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        false,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    );
    try std.testing.expect(report.len < buf.len);
    try std.testing.expect(std.mem.indexOf(u8, report, "ec=0x3f") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "count=18446744073709551615") != null);
}

test "exceptions: try_handle_page_fault demand zero-fill and COW splitting" {
    mmu.reset();
    alloc.reset_refcounts();
    process.init();

    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 20, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    const root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const pid = process.create("TEST_VM", .{}, .{
        .root_phys = root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    _ = process.bind(pid, 2);

    // Register an anonymous mmap region
    const mmap_va: u64 = 0x0000_0000_1000_0000;
    try std.testing.expect(process.add_mmap_region(pid, mmap_va, 8192, 3, 0x22)); // RW

    // 1. Demand translation fault (EC=0x24 Data Abort from lower EL, DFSC=0x7 translation fault L3)
    const esr_trans_fault: u64 = (0x24 << 26) | 0x7;
    const handled_demand = try_handle_page_fault(esr_trans_fault, mmap_va + 64);
    try std.testing.expect(handled_demand);
    try std.testing.expectEqual(@as(u64, 1), demand_fault_count);

    // Leaf is now present and RW
    const leaf = mmu.get_user_leaf(root, mmap_va).?;
    try std.testing.expect((leaf.* & 3) == 3);
    try std.testing.expectEqual(@as(u64, 1), (leaf.* >> 6) & 3); // RW

    // 2. COW page test: Map a shared COW page
    const cow_va: u64 = 0x0000_0000_1000_4000;
    const shared_pa = alloc.alloc_pages(1).?;
    _ = mmu.map_user_cow_page(root, cow_va, shared_pa);
    try std.testing.expect(alloc.ref_page(shared_pa)); // refcount = 2

    // Permission fault on write (DFSC=0xf permission fault L3, WnR=1 (bit 6))
    const esr_perm_write: u64 = (0x24 << 26) | (1 << 6) | 0xf;
    const handled_cow = try_handle_page_fault(esr_perm_write, cow_va + 12);
    try std.testing.expect(handled_cow);
    try std.testing.expectEqual(@as(u64, 1), cow_fault_count);

    // Old page refcount dropped to 1
    try std.testing.expectEqual(@as(u16, 1), alloc.page_refcount(shared_pa));

    // New leaf is present, RW, and not sw_cow
    const new_leaf = mmu.get_user_leaf(root, cow_va).?;
    try std.testing.expect((new_leaf.* & 3) == 3);
    try std.testing.expectEqual(@as(u64, 1), (new_leaf.* >> 6) & 3); // RW
    try std.testing.expect((new_leaf.* & mmu.sw_cow) == 0);
    try std.testing.expect((new_leaf.* & 0x0000_ffff_ffff_f000) != shared_pa);
}

test "exceptions: a COW fault on an unrecorded page is delivered, not promoted (issue #2110)" {
    mmu.reset();
    alloc.reset_refcounts();
    process.init();

    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 20, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    const root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const pid = process.create("TEST_2110", .{}, .{
        .root_phys = root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    _ = process.bind(pid, 2);

    const esr_perm_write: u64 = (0x24 << 26) | (1 << 6) | 0xf;

    // 1. The audit's case: an sw_cow leaf whose page was NEVER recorded —
    //    `page_refcount` still answers 1, and pre-fix that promoted the
    //    mirror writable in place on a page another root may map. Now the
    //    fault is delivered (not handled): the leaf keeps sw_cow and stays
    //    RO, and the page is neither promoted nor split-and-unref'd.
    const cow_va: u64 = 0x0000_0000_1000_0000;
    const untracked_pa = alloc.alloc_pages(1).?;
    _ = mmu.map_user_cow_page(root, cow_va, untracked_pa);
    try std.testing.expect(alloc.page_refcount_recorded(untracked_pa) == null);
    const cows_before = cow_fault_count;
    try std.testing.expect(!try_handle_page_fault(esr_perm_write, cow_va + 12));
    try std.testing.expectEqual(cows_before, cow_fault_count); // not handled
    const leaf = mmu.get_user_leaf(root, cow_va).?;
    try std.testing.expect((leaf.* & mmu.sw_cow) != 0); // still a COW leaf
    try std.testing.expectEqual(@as(u64, 3), (leaf.* >> 6) & 3); // still EL0-RO
    try std.testing.expectEqual(untracked_pa, leaf.* & 0x0000_ffff_ffff_f000);
    try std.testing.expect(alloc.page_refcount_recorded(untracked_pa) == null); // no phantom unref

    // 2. The legitimate sole-owner case is unchanged: a RECORDED count of 1
    //    (peer seat dropped) still promotes in place — no copy, no new page.
    const sole_va: u64 = 0x0000_0000_1000_4000;
    const sole_pa = alloc.alloc_pages(1).?;
    _ = mmu.map_user_cow_page(root, sole_va, sole_pa);
    try std.testing.expect(alloc.ref_page(sole_pa)); // 0 -> 2
    try std.testing.expect(!alloc.unref_page(sole_pa)); // 2 -> 1 (peer seat gone)
    try std.testing.expectEqual(@as(?u16, 1), alloc.page_refcount_recorded(sole_pa));
    try std.testing.expect(try_handle_page_fault(esr_perm_write, sole_va + 12));
    const sole_leaf = mmu.get_user_leaf(root, sole_va).?;
    try std.testing.expect((sole_leaf.* & mmu.sw_cow) == 0);
    try std.testing.expectEqual(@as(u64, 1), (sole_leaf.* >> 6) & 3); // EL0 RW
    try std.testing.expectEqual(sole_pa, sole_leaf.* & 0x0000_ffff_ffff_f000); // same page
}

test "exceptions: populate_user_page maps the process's own demand regions and refuses the rest (issue #1391)" {
    mmu.reset();
    alloc.reset_refcounts();
    process.init();

    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 20, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    const root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const pid = process.create("TEST_1391", .{}, .{
        .root_phys = root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    _ = process.bind(pid, 2);

    const mmap_va: u64 = 0x0000_0000_1000_0000;
    try std.testing.expect(process.add_mmap_region(pid, mmap_va, 8192, 3, 0x22)); // RW

    // An untouched page of a registered region has no EL0 leaf: the
    // kernel->user path populates it in the process's OWN root, EL0-RW, so
    // the store cannot be swallowed by the identity overlay.
    try std.testing.expect(!mmu.leaf_el0_visible(root, mmap_va));
    try std.testing.expect(populate_user_page(pid, root, mmap_va + 64, true));
    try std.testing.expect(mmu.leaf_el0_visible(root, mmap_va));
    const leaf = mmu.get_user_leaf(root, mmap_va).?;
    try std.testing.expectEqual(@as(u64, 1), (leaf.* >> 6) & 3); // EL0 RW

    // A VA that is neither an mmap region nor the stack is REFUSED, and the
    // refusal leaves the page tables untouched (so no store can land).
    const foreign: u64 = 0x0000_0000_2000_0000;
    try std.testing.expect(!populate_user_page(pid, root, foreign, true));
    try std.testing.expect(!mmu.leaf_el0_visible(root, foreign));
}

test "exceptions: #2112 — populate refuses already-mapped and permission-denied faults without burning a page" {
    mmu.reset();
    alloc.reset_refcounts();
    process.init();

    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 20, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    const root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const pid = process.create("TEST_2112", .{}, .{
        .root_phys = root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    _ = process.bind(pid, 2);

    const rw_va: u64 = 0x1000_0000;
    const ro_va: u64 = 0x1100_0000;
    try std.testing.expect(process.add_mmap_region(pid, rw_va, 4096, 3, 0x22)); // R+W
    try std.testing.expect(process.add_mmap_region(pid, ro_va, 4096, 1, 0x22)); // R only

    // A genuine demand write populates exactly once; a second fault on the
    // SAME page (already EL0-visible) allocates nothing — before #2112 the
    // retry loop leaked a page per fault until the pool drained.
    try std.testing.expect(populate_user_page(pid, root, rw_va, true));
    try std.testing.expect(mmu.leaf_el0_visible(root, rw_va));
    const free_after_first = alloc.stats().free_pages;
    try std.testing.expect(!populate_user_page(pid, root, rw_va, true));
    try std.testing.expect(!populate_user_page(pid, root, rw_va, false));
    try std.testing.expectEqual(free_after_first, alloc.stats().free_pages);

    // A WRITE fault against a read-only region is a program fault to
    // deliver, not a page to allocate.
    try std.testing.expect(!populate_user_page(pid, root, ro_va, true));
    try std.testing.expect(!mmu.leaf_el0_visible(root, ro_va));
    try std.testing.expectEqual(free_after_first, alloc.stats().free_pages);
    // The READ fault the region DOES admit still populates.
    try std.testing.expect(populate_user_page(pid, root, ro_va, false));
    try std.testing.expect(mmu.leaf_el0_visible(root, ro_va));

    // An exec-only region (prot=4) admits neither read nor write.
    const x_va: u64 = 0x1200_0000;
    try std.testing.expect(process.add_mmap_region(pid, x_va, 4096, 4, 0x22));
    try std.testing.expect(!populate_user_page(pid, root, x_va, false));
    try std.testing.expect(!populate_user_page(pid, root, x_va, true));
    try std.testing.expect(!mmu.leaf_el0_visible(root, x_va));
}

test "exceptions: ensure_user_write_pages is a no-op on host test binaries (issue #1391)" {
    // Host test processes have no user roots and no live task: the seam must
    // not refuse the copies the off-guest tests perform with host pointers.
    // The resolver's real work is proven on VZ by the class-B gates (the
    // go-selftest intake case reads a host-seeded fixture into a page EL0 has
    // never written and requires the exact bytes back).
    try std.testing.expect(ensure_user_write_pages(0x1000, 4096));
}
