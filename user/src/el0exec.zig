//! VirelaiOS EL0EXEC.BIN — issue #1333 class-B fixture, plus M70a-live (#1466)
//! fuzz mode.
//!
//! Default (no argv): an EL0 Zig program (real call frames) that:
//!   1. `sys_exec`s a missing name and keeps running (ENOENT must not
//!      disturb the caller);
//!   2. `sys_exec`s USER.BIN with argv `alpha`, then uses the stack
//!      (a noinline helper copies the survived marker through a local
//!      buffer) — the kstack overflow smashed those frames;
//!   3. `sys_wait`s the child and prints a done marker.
//!
//! `exec EL0EXEC.BIN fuzz <seed|roster>`: the live half of M70a. A seeded
//! `(slot, args)` sweep against the real SVC path, the buffer-contract
//! rows, and a named successful-spawn assertion. Not a GUI app (ADR 0030).
//! Markers are `pub const` so a drift from the live spec is a host-test
//! failure if this file is compiled as a test.

const std = @import("std");
const builtin = @import("builtin");

pub const enoent_ok_marker: []const u8 = "el0-exec: enoent ok\n";
pub const survived_marker: []const u8 = "el0-exec: parent survived\n";
pub const child_done_marker: []const u8 = "el0-exec: child done\n";
pub const exec_failed_marker: []const u8 = "el0-exec: exec failed\n";
pub const enoent_bad_marker: []const u8 = "el0-exec: enoent unexpected\n";

pub const fuzz_done_marker: []const u8 = "fuzz: done\n";
pub const fuzz_caller_ok_marker: []const u8 = "fuzz: caller-not-moved ok\n";
pub const fuzz_violation_tag: []const u8 = "fuzz: VIOLATION";
pub const oom_enomem_marker: []const u8 = "oom: enomem ok\n";
pub const oom_rlimit_fail_marker: []const u8 = "oom: setrlimit failed\n";
pub const oom_mmap_fail_marker: []const u8 = "oom: mmap unexpected\n";
pub const oom_reap_miss_marker: []const u8 = "oom: reap-miss\n";

const sys_write: u64 = 1;
const sys_exit: u64 = 3;
const sys_wait: u64 = 8;
const sys_exec: u64 = 28;
const sys_setrlimit: u64 = 54;
const sys_mmap: u64 = 63;
const sys_munmap: u64 = 64;
const enoent: i64 = -6;
const enomem: i64 = -10;

// M133a (#2755): the `oom` mode's ceiling — refuse mode's populated page
// count, reap mode's lazy-touch bound.
const rlimit_mem_pages: u64 = 0; // setrlimit type 0 = memory pages
const oom_page_limit: u64 = 6;
const prot_rw: u64 = 3;
const map_anon_private: u64 = 0x22; // MAP_ANONYMOUS|MAP_PRIVATE
const map_populate: u64 = 0x8000;

const slot_count: u64 = 128;
const past_namespace: u64 = 64;
const arg_slot_bytes: usize = 256;

// The one writable image global: staging for the USER.BIN child's argv
// block (default and fuzz paths share it — sequential use, one thread).
// Beyond deduplicating two stack copies, it keeps a .bss page in the
// image, which is what the segmented (DSK3) build needs for a writable
// data segment — the argv tail packs there (M133d #2758 fixup).
var child_arg_block: [arg_slot_bytes]u8 = @as([arg_slot_bytes]u8, @splat(@as(u8, 0)));
const unmapped: u64 = 0x1_2000_0000;

/// Same roster as `kernel/tests/fuzz_test.zig` (M70a D1).
const seeds = [_]u64{
    0x5eed_0001,
    0x1337_2026,
    0xdead_beef_cafe,
    0x0f0f_1234_5678,
};

const documented_errnos = [_]i64{ -1, -2, -3, -4, -5, -6, -7, -8, -9, -10, -11, -12 };

const BufferRow = struct { slot: u64, ptr_arg: usize };
const buffer_contract = [_]BufferRow{
    .{ .slot = 5, .ptr_arg = 1 },
    .{ .slot = 6, .ptr_arg = 0 },
    .{ .slot = 7, .ptr_arg = 0 },
    .{ .slot = 10, .ptr_arg = 2 },
    .{ .slot = 11, .ptr_arg = 1 },
    .{ .slot = 18, .ptr_arg = 1 },
    .{ .slot = 19, .ptr_arg = 1 },
    .{ .slot = 21, .ptr_arg = 0 },
    .{ .slot = 23, .ptr_arg = 0 },
    .{ .slot = 25, .ptr_arg = 1 },
    .{ .slot = 27, .ptr_arg = 0 },
    .{ .slot = 28, .ptr_arg = 0 },
    .{ .slot = 34, .ptr_arg = 0 },
    .{ .slot = 35, .ptr_arg = 0 },
    .{ .slot = 35, .ptr_arg = 2 },
    .{ .slot = 38, .ptr_arg = 0 },
    .{ .slot = 39, .ptr_arg = 0 },
    .{ .slot = 42, .ptr_arg = 0 },
    .{ .slot = 62, .ptr_arg = 0 },
    .{ .slot = 65, .ptr_arg = 2 },
    .{ .slot = 68, .ptr_arg = 0 },
    .{ .slot = 69, .ptr_arg = 0 },
    .{ .slot = 70, .ptr_arg = 0 },
    .{ .slot = 72, .ptr_arg = 0 },
};

fn svc1(num: u64, a0: u64) i64 {
    if (builtin.os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
        : .{ .memory = true });
    return res;
}

fn svc2(num: u64, a0: u64, a1: u64) i64 {
    if (builtin.os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
        : .{ .memory = true });
    return res;
}

fn svc3(num: u64, a0: u64, a1: u64, a2: u64) i64 {
    if (builtin.os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
        : .{ .memory = true });
    return res;
}

fn svc4(num: u64, a0: u64, a1: u64, a2: u64, a3: u64) i64 {
    if (builtin.os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
        : .{ .memory = true });
    return res;
}

fn svc6(num: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) i64 {
    if (builtin.os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
          [a4] "{x4}" (a4),
          [a5] "{x5}" (a5),
        : .{ .memory = true });
    return res;
}

fn write(msg: []const u8) void {
    if (msg.len == 0) return;
    _ = svc3(sys_write, 1, @intFromPtr(msg.ptr), msg.len);
}

fn exit(status: u64) noreturn {
    _ = svc1(sys_exit, status);
    while (true) {}
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    return std.mem.eql(u8, a, b);
}

fn is_documented_errno(result: i64) bool {
    for (documented_errnos) |e| if (result == e) return true;
    return false;
}

fn value_return_slot(slot: u64) bool {
    return switch (slot) {
        0, // sys_ping: echoes the payload u64 (high bit set is still a value)
        41, // sys_timer_cancel: 1 when a pending timer was canceled
        44, // sys_audio_volume: 0..100 gain (handle_audio_volume). Host oracle omits 44 — its corpora never land a small-vol success; do not drop this row to "match" host.
        63, // sys_mmap: mapped address
        66, // sys_time: wall clock seconds
        87, // sys_getpid (#2158, ADR 0048): the caller's pid
        => true,
        else => false,
    };
}

fn reviewed_answer(slot: u64, result: i64) bool {
    if (is_documented_errno(result)) return true;
    if (result == 0) return true;
    // Match the host half: a reviewed value-return slot may use the full
    // u64 (sys_ping echoes its argument, which is often high-bit-set).
    return value_return_slot(slot);
}

/// Slots the live sweep must not drive: they block, reap the caller, or
/// wait on a peer for up to the kernel's 30 s TCP clock — any of those
/// would blow M70a D2's in-fleet bound.
fn skip_slot(slot: u64) bool {
    return switch (slot) {
        1, // write (must not spray the serial the gate greps)
        2, // yield
        3, // exit
        4, // sleep
        8, // wait
        11, // udp_recv (may park on an empty listen)
        22, // wait_event
        29, // kill (must not reap the caller or the shell)
        30, // tcp_connect (30 s refuse clock)
        32, // tcp_recv
        54, // setrlimit
        73, // thread
        74, // futex
        76, // sock_ready park
        => true,
        else => false,
    };
}

fn report_violation(seed: u64, slot: u64, result: i64) void {
    var buf: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s} seed=0x{x} slot={d} result={d}\n", .{
        fuzz_violation_tag, seed, slot, result,
    }) catch "fuzz: VIOLATION\n";
    write(line);
}

fn hostile_tuple(which: usize) [6]u64 {
    return switch (which) {
        0 => .{ 0, 0, 0, 0, 0, 0 },
        1 => .{ 1, 2, 3, 4, 5, 6 },
        2 => .{ @as(u64, @bitCast(@as(i64, -1))), @as(u64, @bitCast(@as(i64, -1))), @as(u64, @bitCast(@as(i64, -1))), @as(u64, @bitCast(@as(i64, -1))), @as(u64, @bitCast(@as(i64, -1))), @as(u64, @bitCast(@as(i64, -1))) },
        3 => .{ std.math.maxInt(u64), std.math.maxInt(u64) - 1, std.math.maxInt(u64) - 2, std.math.maxInt(u64) - 3, std.math.maxInt(u64) - 4, std.math.maxInt(u64) - 5 },
        4 => .{ unmapped, 64, unmapped + 1, 64, unmapped + 0x1000, 64 },
        else => .{ 0xffff_ffff, 0x1_0000_0000, 0x7fff_ffff_ffff_ffff, 0x4000_0000, 0x1000, 0xff },
    };
}

fn sweep_one_seed(seed: u64, violations: *usize, dispatched: *usize) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var hist_errno: u64 = 0;
    var hist_zero: u64 = 0;
    var hist_value: u64 = 0;
    var slot: u64 = 0;
    while (slot < slot_count + past_namespace) : (slot += 1) {
        if (slot < slot_count and skip_slot(slot)) continue;
        var which: usize = 0;
        while (which < 6) : (which += 1) {
            var args = hostile_tuple(which);
            args[rand.uintLessThan(usize, 6)] = rand.int(u64);
            const result = svc6(slot, args[0], args[1], args[2], args[3], args[4], args[5]);
            dispatched.* += 1;
            if (slot >= slot_count) {
                if (result != -4) {
                    report_violation(seed, slot, result);
                    violations.* += 1;
                } else hist_errno += 1;
            } else if (!reviewed_answer(slot, result)) {
                report_violation(seed, slot, result);
                violations.* += 1;
            } else if (is_documented_errno(result)) {
                hist_errno += 1;
            } else if (result == 0) {
                hist_zero += 1;
            } else {
                hist_value += 1;
            }
            if (slot == 63 and result > 0) {
                _ = svc3(sys_munmap, @as(u64, @intCast(result)), args[1], 0);
            }
        }
    }
    var buf: [160]u8 = undefined;
    const tag: []const u8 = if (violations.* == 0) "ok" else "FAIL";
    const line = std.fmt.bufPrint(&buf, "seed=0x{x} {s} dispatched={d} errno={d} zero={d} value={d} violations={d}\n", .{
        seed, tag, dispatched.*, hist_errno, hist_zero, hist_value, violations.*,
    }) catch "seed=0x?\n";
    write(line);
}

fn buffer_phase(violations: *usize) void {
    var faulted: u64 = 0;
    var empty: u64 = 0;
    for (buffer_contract) |row| {
        var args: [6]u64 = .{ 64, 64, 64, 64, 64, 64 };
        args[row.ptr_arg] = unmapped;
        const result = svc6(row.slot, args[0], args[1], args[2], args[3], args[4], args[5]);
        if (!(result == 0 or is_documented_errno(result))) {
            report_violation(0, row.slot, result);
            violations.* += 1;
        }
        if (result == -3) faulted += 1 else empty += 1;
    }
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "fuzz: buffer EFAULT={d} empty={d}\n", .{ faulted, empty }) catch "fuzz: buffer EFAULT=\n";
    write(line);
}

/// Copy the survived marker through a stack buffer so a smashed high
/// frame (the #1333 overflow) faults here instead of silently returning.
noinline fn announce_survived(pid: i64) void {
    var scratch: [64]u8 = undefined;
    const n = survived_marker.len;
    @memcpy(scratch[0..n], survived_marker);
    scratch[n - 1] = if (pid >= 0) '\n' else '!';
    write(scratch[0..n]);
}

fn spawn_phase(violations: *usize) void {
    const missing = "NOSUCH.BIN";
    const miss = svc4(sys_exec, @intFromPtr(missing.ptr), missing.len, 0, 0);
    if (miss != enoent) {
        write(enoent_bad_marker);
        violations.* += 1;
        return;
    }
    write(enoent_ok_marker);

    const child = "USER.BIN";
    const arg = "alpha";
    @memcpy(child_arg_block[0..arg.len], arg);
    const pid = svc4(sys_exec, @intFromPtr(child.ptr), child.len, @intFromPtr(&child_arg_block), 1);
    if (pid < 0) {
        write(exec_failed_marker);
        violations.* += 1;
        return;
    }
    announce_survived(pid);
    write(fuzz_caller_ok_marker);

    const st = svc1(sys_wait, @as(u64, @intCast(pid)));
    if (st < 0) {
        write(exec_failed_marker);
        violations.* += 1;
        return;
    }
    write(child_done_marker);
}

fn parse_seed_token(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var index: usize = 0;
    const radix: u64 = if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) blk: {
        index = 2;
        break :blk 16;
    } else 10;
    if (index >= text.len) return null;
    var value: u64 = 0;
    while (index < text.len) : (index += 1) {
        const c = text[index];
        const digit: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        if (radix == 10 and digit >= 10) return null;
        const next = value *% radix;
        if (value != 0 and next / radix != value) return null;
        if (next > std.math.maxInt(u64) - digit) return null;
        value = next + digit;
    }
    return value;
}

fn arg_slot(argv_va: u64, index: usize) []const u8 {
    const slot: [*]const u8 = @ptrFromInt(argv_va + index * arg_slot_bytes);
    var n: usize = 0;
    while (n < arg_slot_bytes - 1 and slot[n] != 0) : (n += 1) {}
    return slot[0..n];
}

fn run_fuzz(argc: u64, argv_va: u64) noreturn {
    var token: []const u8 = "roster";
    if (argc >= 2 and argv_va != 0) token = arg_slot(argv_va, 1);

    var violations: usize = 0;
    buffer_phase(&violations);
    spawn_phase(&violations);

    if (eql(token, "roster")) {
        for (seeds) |seed| {
            var dispatched: usize = 0;
            var seed_violations: usize = 0;
            sweep_one_seed(seed, &seed_violations, &dispatched);
            violations += seed_violations;
        }
    } else if (parse_seed_token(token)) |seed| {
        var dispatched: usize = 0;
        var seed_violations: usize = 0;
        sweep_one_seed(seed, &seed_violations, &dispatched);
        violations += seed_violations;
    } else {
        write("fuzz: bad seed\n");
        exit(1);
    }

    write(fuzz_done_marker);
    exit(if (violations == 0) 0 else 1);
}

fn oom_arm_limit() void {
    if (svc2(sys_setrlimit, rlimit_mem_pages, oom_page_limit) != 0) {
        write(oom_rlimit_fail_marker);
        exit(1);
    }
}

/// M133a (#2755): refuse mode — `exec EL0EXEC.BIN oom`. Populate one page
/// at a time past the 6-page rlimit ceiling; the record charge refused at
/// the limit makes the mmap answer ENOMEM by name.
fn oom_refuse() noreturn {
    oom_arm_limit();
    var i: u64 = 0;
    while (i < 2 * oom_page_limit) : (i += 1) {
        const r = svc4(sys_mmap, 0, 4096, prot_rw, map_anon_private | map_populate);
        if (r == enomem) {
            write(oom_enomem_marker);
            exit(0);
        }
        if (r <= 0) {
            var buf: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "oom: mmap unexpected i={d} r={d}\n", .{ i, r }) catch oom_mmap_fail_marker;
            write(line);
            exit(1);
        }
    }
    write(oom_mmap_fail_marker); // no refusal inside 2x the limit — wrong verdict
    exit(1);
}

/// M133a (#2755): reap mode — `exec EL0EXEC.BIN oom reap`. One lazy
/// reservation past the ceiling, then a byte stored per page; the 7th
/// page's demand-fault charge is refused and the kernel reaps this caller
/// with the mem-limit receipt (status 140 on serial). A return from the
/// last store means the reap never came.
fn oom_reap() noreturn {
    oom_arm_limit();
    const r = svc4(sys_mmap, 0, 2 * oom_page_limit * 4096, prot_rw, map_anon_private);
    if (r <= 0) {
        write(oom_mmap_fail_marker);
        exit(1);
    }
    const base: u64 = @intCast(r);
    var i: u64 = 0;
    while (i < 2 * oom_page_limit) : (i += 1) {
        const p: *volatile u8 = @ptrFromInt(base + i * 4096);
        p.* = 0x5a;
    }
    write(oom_reap_miss_marker);
    exit(2);
}

export fn _start(argc: u64, argv_va: u64) callconv(.c) noreturn {
    if (argc >= 1 and argv_va != 0) {
        const first = arg_slot(argv_va, 0);
        if (eql(first, "fuzz")) run_fuzz(argc, argv_va);
        if (eql(first, "oom")) {
            if (argc >= 2 and eql(arg_slot(argv_va, 1), "reap")) oom_reap();
            oom_refuse();
        }
    }
    run();
}

fn run() noreturn {
    const missing = "NOSUCH.BIN";
    const miss = svc4(sys_exec, @intFromPtr(missing.ptr), missing.len, 0, 0);
    if (miss != enoent) {
        write(enoent_bad_marker);
        exit(1);
    }
    write(enoent_ok_marker);

    const child = "USER.BIN";
    const arg = "alpha";
    @memcpy(child_arg_block[0..arg.len], arg);
    const pid = svc4(sys_exec, @intFromPtr(child.ptr), child.len, @intFromPtr(&child_arg_block), 1);
    if (pid < 0) {
        write(exec_failed_marker);
        exit(2);
    }
    announce_survived(pid);

    const st = svc1(sys_wait, @intCast(pid));
    if (st < 0) {
        write(exec_failed_marker);
        exit(3);
    }
    write(child_done_marker);
    exit(0);
}

test "el0exec: marker shapes are pinned (live-gate grep targets)" {
    try std.testing.expectEqualStrings("el0-exec: enoent ok\n", enoent_ok_marker);
    try std.testing.expectEqualStrings("el0-exec: parent survived\n", survived_marker);
    try std.testing.expectEqualStrings("el0-exec: child done\n", child_done_marker);
    try std.testing.expectEqualStrings("fuzz: done\n", fuzz_done_marker);
    try std.testing.expectEqualStrings("fuzz: caller-not-moved ok\n", fuzz_caller_ok_marker);
    try std.testing.expectEqualStrings("fuzz: VIOLATION", fuzz_violation_tag);
    try std.testing.expectEqualStrings("oom: enomem ok\n", oom_enomem_marker);
    try std.testing.expectEqualStrings("oom: setrlimit failed\n", oom_rlimit_fail_marker);
    try std.testing.expectEqualStrings("oom: mmap unexpected\n", oom_mmap_fail_marker);
    try std.testing.expectEqualStrings("oom: reap-miss\n", oom_reap_miss_marker);
}

test "el0exec: roster seeds match the host fuzz module" {
    try std.testing.expectEqual(@as(u64, 0x5eed_0001), seeds[0]);
    try std.testing.expectEqual(@as(u64, 0x1337_2026), seeds[1]);
    try std.testing.expectEqual(@as(u64, 0xdead_beef_cafe), seeds[2]);
    try std.testing.expectEqual(@as(u64, 0x0f0f_1234_5678), seeds[3]);
    try std.testing.expectEqual(@as(usize, 24), buffer_contract.len);
}
