//! VirelaiOS ARM Power State Coordination Interface (PSCI) client (Milestone 28, claim 6438).
//!
//! Implements ARM PSCI v0.2+ calling convention via HVC for secondary CPU
//! core wakeups (PSCI CPU_ON, func_id 0xC4000003).
//!
//! No libc, no POSIX, no heap allocation.

const std = @import("std");
const builtin = @import("builtin");

pub const PSCI_VERSION: u32 = 0x84000000;
pub const CPU_SUSPEND_64: u32 = 0xC4000001;
pub const CPU_OFF: u32 = 0x84000002;
pub const CPU_ON_64: u32 = 0xC4000003;
pub const AFFINITY_INFO_64: u32 = 0xC4000004;

pub const PsciResult = enum(i32) {
    success = 0,
    not_supported = -1,
    invalid_params = -2,
    denied = -3,
    already_on = -4,
    on_pending = -5,
    internal_failure = -6,
    not_present = -7,
    disabled = -8,
    invalid_address = -9,
    _,
};

/// Call PSCI via HVC instruction (Hypervisor Call, EL1 -> EL2).
pub fn psci_call(fn_id: u64, arg0: u64, arg1: u64, arg2: u64) i64 {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return 0;
    var res: i64 = 0;
    asm volatile (
        \\mov x0, %[fid]
        \\mov x1, %[a0]
        \\mov x2, %[a1]
        \\mov x3, %[a2]
        \\hvc #0
        \\mov %[r], x0
        : [r] "=r" (res),
        : [fid] "r" (fn_id),
          [a0] "r" (arg0),
          [a1] "r" (arg1),
          [a2] "r" (arg2),
        : .{ .memory = true });
    return res;
}

/// Query PSCI version.
pub fn get_version() u32 {
    const res = psci_call(PSCI_VERSION, 0, 0, 0);
    return @as(u32, @truncate(@as(u64, @bitCast(res))));
}

/// Power on a secondary CPU core at the specified physical entry point.
pub fn cpu_on(target_mpidr: u64, entry_point_pa: u64, context_id: u64) PsciResult {
    const rc = psci_call(CPU_ON_64, target_mpidr, entry_point_pa, context_id);
    return @fromBackingInt(@intCast(@as(i32, @intCast(rc))));
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "psci: constants are standard ARM PSCI v0.2+ function IDs" {
    try std.testing.expectEqual(@as(u32, 0x84000000), PSCI_VERSION);
    try std.testing.expectEqual(@as(u32, 0xC4000001), CPU_SUSPEND_64);
    try std.testing.expectEqual(@as(u32, 0x84000002), CPU_OFF);
    try std.testing.expectEqual(@as(u32, 0xC4000003), CPU_ON_64);
    try std.testing.expectEqual(@as(u32, 0xC4000004), AFFINITY_INFO_64);
}

test "psci: result enum conversions" {
    try std.testing.expectEqual(PsciResult.success, @as(PsciResult, @fromBackingInt(@intCast(0))));
    try std.testing.expectEqual(PsciResult.not_supported, @as(PsciResult, @fromBackingInt(@intCast(-1))));
    try std.testing.expectEqual(PsciResult.already_on, @as(PsciResult, @fromBackingInt(@intCast(-4))));
    try std.testing.expectEqual(PsciResult.on_pending, @as(PsciResult, @fromBackingInt(@intCast(-5))));
}
