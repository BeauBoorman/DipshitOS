//! VirelaiOS first EL0 execution boundary (claim 8215, re-homed onto
//! per-task address spaces by claim 5804).
//!
//! One statically linked EL0t task, one static user stack, and a tiny fixed
//! SVC exercise. Claim 5804 gives the task its OWN TTBR0 user root: the
//! payload runs at `text_va` (a fixed USER virtual address — not the
//! physical identity address it ran at under claim 8215) backed by the
//! .usertext pages, with the .userbss stack at `stack_va`. The kernel root
//! carries no EL0 permission; the user root maps ONLY text + stack, so EL0
//! has no route to kernel RAM, firmware, or MMIO. This module owns the user
//! VA layout and the conversions between kernel-side addresses and user VAs
//! (kernel-only helpers — they rely on the pre-jump identity world, so they
//! are called by kernel_main before `install_identity_map`).
//!
//! The live proof is stronger than a one-way `eret`: the EL0 loop increments
//! x0, round-trips it through `svc #0`, receives the kernel's result in x0,
//! and invokes SVC again. Seeing the second valid call proves the first SVC
//! returned to EL0. Reporting is deferred to the shell idle loop because the
//! polled console is not reentrant in exception context.

const std = @import("std");
const builtin = @import("builtin");
const console = @import("console.zig");

const user_text_section = if (builtin.object_format == .elf) ".usertext" else "__TEXT,__usertext";

pub const syscall_ping: u64 = 0;
pub const syscall_write: u64 = 1;
pub const syscall_yield: u64 = 2;
pub const syscall_exit: u64 = 3;
pub const svc_immediate: u16 = 0;

pub const Region = struct { base: u64, len: u64 };
extern var __user_text_start: u8;
extern var __user_text_end: u8;
extern var __user_stack_start: u8;
extern var __user_stack_end: u8;

/// Fixed user-space VAs under the per-task TTBR0 map (claim 5804). Chosen
/// well inside the TTBR0 space and distinct from each other; the user root
/// maps ONLY these two ranges, so every other VA faults at EL0.
pub const text_va: u64 = 0x0040_0000; // 4 MiB
// M129a (#2610): 6 GiB — inside the exec-path ASLR band [4 GiB, 8 GiB),
// above the identity blanket AND above the guest-RAM span. VZ anchors
// guest RAM at phys 0x7000_0000 growing upward (observed: 256 MiB ends at
// 0x8000_0000, 512 MiB at 0x9000_0000); the old 2 GiB default landed ON a
// kernel-live Normal leaf once RAM reached it, and the user-root clone's
// kernel_live_leaf refusal failed build_identity_map at M2_TABLE — zero
// serial. A VA above the whole RAM window never collides.
pub const stack_va: u64 = 0x1_8000_0000;

/// Current EL0 user stack VA. Defaults to the fixed `stack_va`; the exec
/// path (milestone four, claim 2665) randomizes it from the seeded CSPRNG
/// before rebuilding the user root, so the loaded program's stack lands at
/// a per-boot random placement (the seed's real ASLR consumer). The
/// boot-time static payload's root is built pre-seed, so it always uses
/// the fixed default.
var current_stack_va: u64 = stack_va;

/// Set the current EL0 user stack VA (the exec rebuild, claim 2665).
pub fn set_stack_va(va: u64) void {
    current_stack_va = va;
}

/// The current EL0 user stack VA (fixed default until exec randomizes it).
pub fn user_stack_va() u64 {
    return current_stack_va;
}

/// User-space VA of a kernel address inside the .usertext image section.
/// KERNEL-ONLY, pre-jump: `kernel_addr` is a runtime (identity) address of
/// an image symbol; `image_base` is the loader base; the linker-script
/// externs evaluate to image offsets, so `kernel_addr - image_base` is the
/// image offset and the result is the same VA the user root maps. On host
/// test builds the externs do not exist, so the identity is returned (a
/// test's fake entry/stack addresses are already "user" addresses).
pub fn image_user_va(image_base: u64, kernel_addr: u64) u64 {
    if (comptime builtin.is_test) return kernel_addr;
    return text_va + (kernel_addr - image_base) - @intFromPtr(&__user_text_start);
}

/// User-space VA of a kernel address inside the .userbss section (the user
/// stack or the scheduler's timer-preemption witness). Kernel-only,
/// pre-jump (see `image_user_va`); identity on host test builds. The base
/// is the CURRENT stack VA (claim 3693): after the boot-time ASLR rebuild
/// the whole .userbss section moves to the randomized placement, so sp_el0
/// and the witness follow it with the same relative offsets.
pub fn bss_user_va(image_base: u64, kernel_addr: u64) u64 {
    if (comptime builtin.is_test) return kernel_addr;
    return current_stack_va + (kernel_addr - image_base) - @intFromPtr(&__user_stack_start);
}

/// The user-VA region descriptors the syscall/uaccess layers validate
/// against (text read-only, stack read-write). Lengths come from the
/// linker-script externs (image offsets — consistent in any world).
pub fn text_va_region() Region {
    // Host test builds have no linker-script externs (same guard as
    // `image_user_va`): return the fixed VA with a nominal length.
    if (comptime builtin.is_test) return .{ .base = text_va, .len = 0x1000 };
    return .{ .base = text_va, .len = @intFromPtr(&__user_text_end) - @intFromPtr(&__user_text_start) };
}

pub fn stack_va_region() Region {
    if (comptime builtin.is_test) return .{ .base = current_stack_va, .len = 0x2000 };
    return .{ .base = current_stack_va, .len = @intFromPtr(&__user_stack_end) - @intFromPtr(&__user_stack_start) };
}

pub fn text_region(image_base: u64) Region {
    // Absolute linker symbols in this relocation-free ELF evaluate to image
    // offsets. Add the loader-provided runtime base before handing the range
    // to the identity-map builder.
    const start = image_base + @intFromPtr(&__user_text_start);
    const end = @intFromPtr(&__user_text_end);
    return .{ .base = start, .len = end - @intFromPtr(&__user_text_start) };
}

pub fn stack_region(image_base: u64) Region {
    const start = image_base + @intFromPtr(&__user_stack_start);
    const end = @intFromPtr(&__user_stack_end);
    return .{ .base = start, .len = end - @intFromPtr(&__user_stack_start) };
}

var calls_value: u64 = 0;
var valid_sequences_value: u64 = 0;
var rejected_value: u64 = 0;
var last_arg_value: u64 = 0;
var last_result_value: u64 = 0;

var report_pending: bool = false;
var report_calls: u64 = 0;
var report_roundtrips: u64 = 0;
var report_arg: u64 = 0;
var report_result: u64 = 0;
var report_rejected: u64 = 0;

pub const Stats = struct {
    calls: u64,
    valid_sequences: u64,
    rejected: u64,
    last_arg: u64,
    last_result: u64,
};

pub fn init() void {
    calls_value = 0;
    valid_sequences_value = 0;
    rejected_value = 0;
    last_arg_value = 0;
    last_result_value = 0;
    report_pending = false;
}

pub fn stats() Stats {
    return .{
        .calls = calls_value,
        .valid_sequences = valid_sequences_value,
        .rejected = rejected_value,
        .last_arg = last_arg_value,
        .last_result = last_result_value,
    };
}

/// Slot-0 behavior retained from claim 8215. The numbered syscall module owns
/// frame marshalling; this helper preserves the two-call round-trip evidence.
pub fn ping(arg: u64) u64 {
    const expected = calls_value +% 1;
    calls_value +%= 1;
    if (arg == expected) valid_sequences_value +%= 1;
    last_arg_value = arg;
    last_result_value = arg;

    // The second correctly sequenced entry can exist only if the first SVC
    // returned to EL0 and its x0 result survived the exception restore.
    if (!report_pending and calls_value == 2 and valid_sequences_value == 2) {
        report_pending = true;
        report_calls = calls_value;
        report_roundtrips = valid_sequences_value - 1;
        report_arg = arg;
        report_result = last_result_value;
        report_rejected = rejected_value;
    }
    return last_result_value;
}

/// Shell-context evidence line. Never called from the synchronous exception
/// handler or timer IRQ path.
pub fn maybe_report(con: *console.Console) void {
    if (!report_pending) return;
    report_pending = false;
    con.puts("userspace: el0=1 svc=");
    con.print_u64(report_calls);
    con.puts(" roundtrips=");
    con.print_u64(report_roundtrips);
    con.puts(" arg=");
    con.print_u64(report_arg);
    con.puts(" result=");
    con.print_u64(report_result);
    con.puts(" rejected=");
    con.print_u64(report_rejected);
    con.puts("\n");
}

/// Statically linked EL0 payload. The stack store/load proves SP_EL0 points at
/// writable user-accessible RAM; the second ping proves return to EL0. The
/// payload then writes one bounded line, exercises the claim-6120 EFAULT
/// contract (a write from an unmapped address must return -3 without crashing
/// the kernel, and EL0 must survive to write a marker), and waits for the
/// scheduler's user-accessible timer-preemption witness before it yields and
/// exits. That ordering preserves claim 8215's proof that a real timer IRQ
/// returned from EL0 to the shell before this card exercises cooperative
/// scheduling. The final exit must never return; the terminal branch is only
/// a fail-safe. This function intentionally contains no Zig-generated memory
/// references or calls—only the fixed register ABI crosses into EL1.
pub fn entry() linksection(user_text_section) callconv(.naked) noreturn {
    asm volatile (
        \\mov x0, xzr
        \\mov x8, xzr
        \\1:
        \\add x0, x0, #1
        \\sub sp, sp, #16
        \\str x0, [sp]
        \\ldr x0, [sp]
        \\add sp, sp, #16
        \\svc #0
        \\cmp x0, #2
        \\b.lo 1b
        \\mov x0, #1
        \\adr x1, 3f
        \\mov x2, #23
        \\mov x8, #1
        \\svc #0
        \\// Claim 6120: a write from a bad user pointer (0x1_2000_0000, above
        \\// the 4 GiB identity blanket, unmapped) must return -3 (EFAULT).
        \\// The kernel validates the range before any access, so this is the
        \\// EFAULT contract end to end; the marker write proves EL0 survived.
        \\mov x0, #1
        \\mov x1, #0x20000000
        \\movk x1, #0x1, lsl #32
        \\mov x2, #8
        \\mov x8, #1
        \\svc #0
        \\mov x3, #0xfffd
        \\movk x3, #0xffff, lsl #16
        \\movk x3, #0xffff, lsl #32
        \\movk x3, #0xffff, lsl #48
        \\cmp x0, x3
        \\b.ne 2f
        \\mov x0, #1
        \\adr x1, 6f
        \\mov x2, #23
        \\mov x8, #1
        \\svc #0
        \\4:
        \\ldr x10, [x9]
        \\cbz x10, 4b
        \\mov x8, #2
        \\svc #0
        \\mov x0, #7
        \\mov x8, #3
        \\svc #0
        \\2:
        \\b 2b
        \\3:
        \\.ascii "syscall: write ok n=23"
        \\.byte 10
        \\6:
        \\.ascii "uaccess: efault ok n=8"
        \\.byte 10
    );
}

test "userspace: two sequenced pings preserve the claim-8215 round-trip" {
    init();
    try std.testing.expectEqual(@as(u64, 1), ping(1));
    try std.testing.expectEqual(@as(u64, 2), ping(2));
    const s = stats();
    try std.testing.expectEqual(@as(u64, 2), s.calls);
    try std.testing.expectEqual(@as(u64, 2), s.valid_sequences);
    try std.testing.expectEqual(@as(u64, 0), s.rejected);

    var mock = console.MockConsole(256){};
    var con = mock.console();
    maybe_report(&con);
    try std.testing.expectEqualStrings(
        "userspace: el0=1 svc=2 roundtrips=1 arg=2 result=2 rejected=0\n",
        mock.contents(),
    );
    mock.reset();
    maybe_report(&con);
    try std.testing.expectEqual(@as(usize, 0), mock.contents().len);
}
