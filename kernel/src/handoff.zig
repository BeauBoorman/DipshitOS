//! Handoff-v2 contract: shared struct definition and validation
//! (ADR 0004 D5, Milestone 1.5 commands & personality).
//!
//! The boot stub allocates this 4K-aligned `EfiLoaderData` page and passes
//! its pointer in x3; the milestone-two kernel validates it on entry. This
//! module is the canonical struct for the monitor command layer and its
//! host-side tests. The later Console & Shell Core stream may switch
//! `kernel/src/main.zig`'s private copy to import this module.
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");

pub const magic: u32 = 0x324b5344; // "DSK2"
pub const version: u32 = 4;
pub const expected_stack_size: u64 = 16 * 1024; // 16 KiB, ADR 0004 D5

/// Sentinel for "the firmware gave no wall-clock epoch" (no RTC, or
/// RuntimeServices.GetTime failed / returned a garbage face). #1058.
pub const no_boot_epoch: u64 = std.math.maxInt(u64);

/// ADR 0004 D5 layout (offsets 0..64) plus the v3 boot-epoch field at 64.
pub const HandoffV2 = extern struct {
    magic: u32,
    version: u32,
    kernel_base: u64,
    kernel_size: u64,
    system_table: u64,
    image_handle: u64,
    stack_base: u64,
    stack_size: u64,
    flags: u64,
    /// v3 additive (#1058): Unix wall-clock seconds captured from EFI
    /// RuntimeServices.GetTime at boot, or `no_boot_epoch`. The v2 fields
    /// keep offsets 0..64 byte-for-byte; the version bump to 3 makes the
    /// widening explicit and non-silent (the boot stub, this module, and
    /// ADR 0004 move together).
    boot_epoch_secs: u64 = no_boot_epoch,
    /// v4 additive (#2418, ADR 0054 Part I): the loader's measured
    /// Authenticode SHA-256 of its own `\EFI\BOOT\BOOTAA64.EFI` image —
    /// the `stage=loader` receipt digest. The kernel never re-reads the
    /// boot volume, so the loader is the only honest source. Zeros when
    /// `measured_ok` bit0 is clear.
    measured_loader: [32]u8 = @splat(0),
    /// v4 additive: the loader's raw-file SHA-256 of `\KERNEL.BIN` — the
    /// digest it verified against its build-embedded pin before jumping,
    /// republished as the `stage=kernel` receipt digest. Zeros when
    /// `measured_ok` bit1 is clear.
    measured_kernel: [32]u8 = @splat(0),
    /// v4 additive: bit0 — `measured_loader` is a real digest; bit1 —
    /// `measured_kernel` is a real digest. A clear bit must surface as
    /// `unmeasured` on the receipt, never `measured`.
    measured_ok: u64 = 0,
};

pub const ValidateError = enum {
    none,
    bad_magic,
    bad_version,
    bad_flags,
    bad_stack_size,
    unaligned_kernel_base,
    unaligned_stack_base,
    zero_image_handle,
    zero_stack_base,
    zero_kernel_size,
    kernel_bounds_overflow,
    stack_bounds_overflow,
};

/// Struct-internal validation of a handoff-v2 record. Entry-time mirror
/// checks against the x0/x2 register arguments (`kernel_base == base`,
/// `system_table == st`) are performed by the kernel entry path, not here:
/// the monitor only ever sees the struct, and displays its validity.
pub fn validate(h: *const HandoffV2) ValidateError {
    if (h.magic != magic) return .bad_magic;
    if (h.version != version) return .bad_version;
    if (h.flags != 0) return .bad_flags;
    if (h.stack_size != expected_stack_size) return .bad_stack_size;
    if ((h.kernel_base & 0xfff) != 0) return .unaligned_kernel_base;
    if ((h.stack_base & 0xfff) != 0) return .unaligned_stack_base;
    if (h.image_handle == 0) return .zero_image_handle;
    if (h.stack_base == 0) return .zero_stack_base;
    if (h.kernel_size == 0) return .zero_kernel_size;
    if (h.kernel_base > std.math.maxInt(u64) - h.kernel_size) return .kernel_bounds_overflow;
    if (h.stack_base > std.math.maxInt(u64) - h.stack_size) return .stack_bounds_overflow;
    return .none;
}

/// Short, deterministic reason string for diagnostics.
pub fn error_name(err: ValidateError) []const u8 {
    return switch (err) {
        .none => "valid",
        .bad_magic => "bad magic",
        .bad_version => "bad version",
        .bad_flags => "nonzero flags",
        .bad_stack_size => "bad stack size",
        .unaligned_kernel_base => "unaligned kernel base",
        .unaligned_stack_base => "unaligned stack base",
        .zero_image_handle => "zero image handle",
        .zero_stack_base => "zero stack base",
        .zero_kernel_size => "zero kernel size",
        .kernel_bounds_overflow => "kernel bounds overflow",
        .stack_bounds_overflow => "stack bounds overflow",
    };
}

fn valid_fixture() HandoffV2 {
    return .{
        .magic = magic,
        .version = version,
        .kernel_base = 0x7e4df000,
        .kernel_size = 0x823e8,
        .system_table = 0xfeed000,
        .image_handle = 0x2,
        .stack_base = 0x7e520000,
        .stack_size = expected_stack_size,
        .flags = 0,
        .measured_loader = @splat(0),
        .measured_kernel = @splat(0),
        .measured_ok = 0,
    };
}

test "handoff: valid fixture passes" {
    var h = valid_fixture();
    try std.testing.expectEqual(ValidateError.none, validate(&h));
}

test "handoff: each corruption is rejected with a specific reason" {
    var h = valid_fixture();

    h.magic = 0xdeadbeef;
    try std.testing.expectEqual(ValidateError.bad_magic, validate(&h));
    h = valid_fixture();

    h.version = 1;
    try std.testing.expectEqual(ValidateError.bad_version, validate(&h));
    h = valid_fixture();

    h.flags = 1;
    try std.testing.expectEqual(ValidateError.bad_flags, validate(&h));
    h = valid_fixture();

    h.stack_size = 4096;
    try std.testing.expectEqual(ValidateError.bad_stack_size, validate(&h));
    h = valid_fixture();

    h.kernel_base = 0x7e4df001;
    try std.testing.expectEqual(ValidateError.unaligned_kernel_base, validate(&h));
    h = valid_fixture();

    h.stack_base = 0x7e520001;
    try std.testing.expectEqual(ValidateError.unaligned_stack_base, validate(&h));
    h = valid_fixture();

    h.image_handle = 0;
    try std.testing.expectEqual(ValidateError.zero_image_handle, validate(&h));
    h = valid_fixture();

    h.stack_base = 0;
    try std.testing.expectEqual(ValidateError.zero_stack_base, validate(&h));
    h = valid_fixture();

    h.kernel_size = 0;
    try std.testing.expectEqual(ValidateError.zero_kernel_size, validate(&h));
    h = valid_fixture();

    h.kernel_base = std.math.maxInt(u64) - 0xfff;
    h.kernel_size = 0x2000;
    try std.testing.expectEqual(ValidateError.kernel_bounds_overflow, validate(&h));
    h = valid_fixture();

    h.stack_base = std.math.maxInt(u64) - 0xfff;
    try std.testing.expectEqual(ValidateError.stack_bounds_overflow, validate(&h));
}

test "handoff: error_name returns deterministic strings" {
    try std.testing.expectEqualStrings("valid", error_name(.none));
    try std.testing.expectEqualStrings("bad magic", error_name(.bad_magic));
    try std.testing.expectEqualStrings("bad version", error_name(.bad_version));
    try std.testing.expectEqualStrings("unaligned stack base", error_name(.unaligned_stack_base));
}

test "handoff: v3 carries the boot epoch after the frozen v2 layout (#1058)" {
    // The frozen ADR 0004 D5 fields keep their exact offsets...
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(HandoffV2, "magic"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(HandoffV2, "flags"));
    // ...and the v3 epoch follows.
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(HandoffV2, "boot_epoch_secs"));

    var h = valid_fixture();
    try std.testing.expectEqual(h.boot_epoch_secs, no_boot_epoch);
    h.boot_epoch_secs = 1_789_043_696;
    // The epoch is not part of the frozen validation contract.
    try std.testing.expectEqual(ValidateError.none, validate(&h));
}

test "handoff: v4 carries the loader's measured digests after v3 (#2418)" {
    // v4 additive: the two 32-byte measurement digests plus their validity
    // word append after boot_epoch_secs; the frozen layout is untouched.
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(HandoffV2, "measured_loader"));
    try std.testing.expectEqual(@as(usize, 104), @offsetOf(HandoffV2, "measured_kernel"));
    try std.testing.expectEqual(@as(usize, 136), @offsetOf(HandoffV2, "measured_ok"));
    try std.testing.expectEqual(@as(usize, 144), @sizeOf(HandoffV2));

    var h = valid_fixture();
    h.measured_ok = 0x3;
    // The measurement fields are not part of the frozen validation contract.
    try std.testing.expectEqual(ValidateError.none, validate(&h));
}
