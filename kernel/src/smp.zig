//! VirelaiOS Symmetric Multi-Processing (SMP) Subsystem (Milestone 28, claim 6438).
//!
//! Manages CPU core discovery, secondary core bringup via PSCI CPU_ON,
//! per-core stacks and state, and cross-core Inter-Processor Interrupts (IPIs).
//!
//! No libc, no POSIX, no heap allocation.

const std = @import("std");
const builtin = @import("builtin");
const psci = @import("psci.zig");
const gic = @import("gic.zig");
const mmu = @import("mmu.zig");
const timer = @import("timer.zig");
const exceptions = @import("exceptions.zig");
const spinlock = @import("spinlock.zig");

pub const max_cores: usize = 4;
pub const core_stack_size: usize = 32 * 1024;

pub var num_cores: u32 = 1;
pub var core_online: [max_cores]bool = [_]bool{ true, false, false, false };
pub var core_mpidr: [max_cores]u64 = [_]u64{ 0, 0, 0, 0 };
pub var core_ticks: [max_cores]u64 = [_]u64{ 0, 0, 0, 0 };

// SGI INTIDs
pub const SGI_IPI_RESCHEDULE: u8 = 0;
pub const SGI_IPI_TLB_SHOOTDOWN: u8 = 1;
pub const SGI_IPI_PING: u8 = 2;

pub var ipi_counts: [max_cores][4]u64 = @as([max_cores][4]u64, @splat(@as([4]u64, @as([4]u64, @splat(@as(u64, 0))))));

// Stacks for secondary cores
pub var secondary_stacks: [max_cores][core_stack_size]u8 align(16) = undefined;

/// Read the current CPU affinity / core ID from MPIDR_EL1.
pub fn core_id() u32 {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return 0;
    var mpidr: u64 = 0;
    asm volatile ("mrs %[v], mpidr_el1"
        : [v] "=r" (mpidr),
    );
    // Aff0 is bits [7:0]
    const aff0: u32 = @as(u32, @truncate(mpidr & 0xFF));
    return if (aff0 < max_cores) aff0 else 0;
}

pub fn read_mpidr() u64 {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return 0;
    var mpidr: u64 = 0;
    asm volatile ("mrs %[v], mpidr_el1"
        : [v] "=r" (mpidr),
    );
    return mpidr;
}

/// Initialize SMP subsystem on Core 0 (BSP).
pub fn init() void {
    core_mpidr[0] = read_mpidr();
    core_online[0] = true;
    num_cores = 1;
}

/// Entry trampoline for secondary cores.
export fn secondary_entry(context_id: u64) callconv(.c) noreturn {
    _ = context_id;
    if (comptime !builtin.is_test and builtin.cpu.arch == .aarch64) {
        const cid = core_id();
        core_mpidr[cid] = read_mpidr();

        // 1. Install vector table
        exceptions.install();

        // 2. Setup MMU (TCR, MAIR, TTBR0/1, SCTLR)
        mmu.setup_secondary_core();

        // 3. Initialize secondary GIC CPU interface + redistributor
        gic.init_secondary(timer.ppi, timer.interrupt_edge);

        // 4. Initialize secondary timer
        timer.init_secondary();

        // 5. Mark core as online
        core_online[cid] = true;

        // 6. Unmask IRQs
        exceptions.irq_unmask();

        // 7. Loop in secondary idle / work
        while (true) {
            asm volatile ("wfe");
        }
    } else {
        while (true) {}
    }
}

/// Naked assembly entry point where secondary cores arrive with MMU OFF.
export fn secondary_entry_asm() align(16) callconv(.naked) void {
    if (comptime !builtin.is_test and builtin.cpu.arch == .aarch64) {
        asm volatile (
            \\// Disable all interrupts
            \\msr daifset, #0xf
            \\
            \\// Read MPIDR_EL1 to determine core_id
            \\mrs x0, mpidr_el1
            \\and x0, x0, #0xff
            \\
            \\// Calculate stack pointer: secondary_stacks[x0] + core_stack_size
            \\mov x1, %[stacks_ptr]
            \\mov x2, %[stack_size]
            \\madd x1, x0, x2, x1
            \\add sp, x1, x2
            \\
            \\// Call secondary_entry(x0)
            \\b secondary_entry
            :
            : [stacks_ptr] "r" (&secondary_stacks),
              [stack_size] "r" (@as(u64, core_stack_size)),
        );
    }
}

/// Boot every secondary core the hypervisor exposes (claim 907 / issue
/// #858: the four-core four-domain stress gate boots all 4 VCPUs).
/// Each mpidr (Aff0 = core id) is powered on via PSCI CPU_ON; the first
/// failure (PSCI_NOT_PRESENT — no VCPU at that affinity — or any other
/// non-success) ends the sweep. `num_cores` counts the cores that came
/// up: 1 (BSP only) on a 1-VCPU VM, 2/3/4 as the hypervisor provides.
pub fn boot_secondary_cores() void {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    // On Virtualization.framework each configured VCPU is one Aff0
    // (mpidr 0..cpuCount-1); VZ's virtual PSCI answers PSCI_NOT_PRESENT
    // for affinities beyond the configured count, which ends the sweep.
    const entry_pa = @intFromPtr(&secondary_entry_asm);
    var target: u64 = 1;
    while (target < max_cores) : (target += 1) {
        const res = psci.cpu_on(target, entry_pa, 0);
        if (res == .success or res == .already_on or res == .on_pending) {
            num_cores = @intCast(target + 1);
        } else {
            break;
        }
    }
}

/// Send an SGI (IPI) to target CPU core.
pub fn send_ipi(target_core: u32, sgi_intid: u8) void {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    if (target_core >= max_cores) return;
    // ICC_SGI1R_EL1 format:
    // Bits [27:24]: INTID (0..15)
    // Bits [15:0]: TargetList (bit n corresponds to CPU n in affinity group)
    const val: u64 = (@as(u64, sgi_intid & 0xF) << 24) | (@as(u64, 1) << @as(u6, @intCast(target_core)));
    asm volatile ("msr icc_sgi1r_el1, %[v]"
        :
        : [v] "r" (val),
    );
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb");
}

/// Broadcast TLB shootdown to all other cores.
pub fn broadcast_tlb_shootdown() void {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    asm volatile ("tlbi vmalle1is" ::: .{ .memory = true });
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb");
}

/// Handle incoming SGI.
pub fn handle_sgi(intid: u32) void {
    const cid = core_id();
    if (intid < 4) {
        ipi_counts[cid][intid] += 1;
    }
    switch (intid) {
        SGI_IPI_RESCHEDULE => {},
        SGI_IPI_TLB_SHOOTDOWN => {
            if (comptime !builtin.is_test and builtin.cpu.arch == .aarch64) {
                asm volatile ("tlbi vmalle1" ::: .{ .memory = true });
                asm volatile ("dsb ish" ::: .{ .memory = true });
                asm volatile ("isb");
            }
        },
        SGI_IPI_PING => {},
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "smp: initial state and core tracking" {
    init();
    try std.testing.expectEqual(@as(u32, 0), core_id());
    try std.testing.expect(core_online[0]);
    try std.testing.expect(!core_online[1]);
    try std.testing.expectEqual(@as(u32, 1), num_cores);
}

test "smp: IPI counting" {
    handle_sgi(SGI_IPI_PING);
    try std.testing.expectEqual(@as(u64, 1), ipi_counts[0][SGI_IPI_PING]);
}
