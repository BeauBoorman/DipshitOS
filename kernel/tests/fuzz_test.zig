//! VirelaiOS fuzz fleet — the seeded **host half** of M70a (#1453).
//!
//! Two targets, both pure/class-A (no VM, no device):
//!
//!   1. **The syscall seam** (`kernel/src/syscall.zig` `dispatch`): every
//!      slot in — and just past — the ADR 0007 namespace is driven with
//!      seeded hostile argument tuples. The invariants are the ADR's own
//!      promises, not per-handler guesses:
//!        * an out-of-namespace number, and an in-range *reserved* row,
//!          answer exactly `-ENOSYS` (never a handler, never a panic);
//!        * a registered row answers a documented errno, or a value from
//!          the reviewed `arg_independent` table below (slots whose return
//!          does not depend on their arguments) — anything else is a
//!          violation worth a human look;
//!        * `call_count(slot)` advances by exactly one per dispatch;
//!        * no service-domain lock is left held on return (the
//!          acquire/release symmetry in `dispatch` is observable here);
//!        * with a live EL0 task registered, a hostile pointer in any
//!          argument position never returns a success that could only come
//!          from having copied bytes, and never moves the caller.
//!
//!   2. **The HF wire** (`kernel/src/virtio_file.zig` decoders): the pinned
//!      `tests/vf-*.bin` fixtures (embedded through the `fuzz_fixtures`
//!      build option, so this cannot silently drift from the checked-in
//!      bytes) are mutated byte-wise and length-wise. Acceptance is
//!      fail-closed: never an out-of-bounds read, never an over-reported
//!      length, `data` always a slice of the input buffer and always
//!      `min(dlen, len - 3)` long, `clamped` exactly when the host declared
//!      more than it delivered.
//!
//! Determinism (M70a D1): every generator is a seeded `DefaultPrng`, and a
//! violation line carries the seed plus the slot/arguments/result that tripped
//! it. No wall clock, no `sys_getrandom`, no host entropy — a CI failure
//! replays identically on a laptop.
//!
//! Quiet on success: this module prints ONLY when it has a violation to
//! report. (An unconditional `std.debug.print` in a test module makes the Zig
//! build runner mark the run step `w` and echo a `failed command:` line
//! for a step whose tests all passed and whose build exits 0 — observed
//! 2026-09-18 with a five-line probe module. A green fuzz step must not add
//! that noise to the fleet log.)
//!
//! Observed at the first green run (2026-09-18, these seeds, 8/8 tests):
//! namespace sweep 4608 dispatches / 0 violations; live sweep 345 / 0;
//! buffer contract 24 rows (12 refused with EFAULT at the uaccess boundary,
//! 12 answered 0 before any copy because the mailbox/event/clipboard/net state
//! is empty at the root); reply corpus 768 decodes / 0; builder corpus 1024
//! shapes / 0. The slots that answered 0 under hostile tuples are recorded in
//! the card comment rather than asserted on (see `reviewed_answer`).
//!
//! Honest limits (M70a D5 — do not read more into a green run than this):
//!   * This is the *host* half. The live half is the monitor `fuzz` command
//!     plus gate `live-fuzz` (#1466): an EL0 sweep through `EL0EXEC.BIN`,
//!     the caller-not-moved spawn, and queue-5 STAT + mutated requests.
//!     Host `dispatch` still cannot observe the trap path; that is why the
//!     live gate exists.
//!   * Reply-byte mutations of the fixtures stay here (the guest cannot
//!     rewrite a reply the host generated). Request mutations replay on
//!     the live channel.
//!   * The host runner's *request* parse lives in `main.swift`
//!     (`VMRouter.handleFileRequest`), which is not VZ-free. Only the pure
//!     `VFWire` half is fuzzed from Swift.

const std = @import("std");
const syscall = @import("syscall");
const fixtures = @import("fuzz_fixtures");
const helpers = @import("helpers");

const Args = syscall.Args;
const dispatch = syscall.dispatch;
const entry_info = syscall.entry_info;
const call_count = syscall.call_count;
const error_result = syscall.error_result;
const slot_count = syscall.slot_count;
const exceptions = syscall.exceptions;
const scheduler = syscall.scheduler;
const svclock = syscall.svclock;
const uaccess = syscall.uaccess;
const virtio_file = syscall.virtio_file;
const fresh_frame = helpers.task.fresh_frame;

// ---------------------------------------------------------------------------
// Seeds and the shared oracle
// ---------------------------------------------------------------------------

/// Fixed seeds (M70a D1). Extending the roster is a one-line change with a
/// re-run; a failure names the seed that found it.
const seeds = [_]u64{
    0x5eed_0001,
    0x1337_2026,
    0xdead_beef_cafe,
    0x0f0f_1234_5678,
};

/// Every errno ADR 0007 defines. A handler that answers anything else that is
/// not on the `arg_independent` table below has either invented an errno or
/// returned a value nobody reviewed against hostile input.
const documented_errnos = [_]u64{
    error_result(.einval),
    error_result(.ebadf),
    error_result(.efault),
    error_result(.enosys),
    error_result(.enospc),
    error_result(.enoent),
    error_result(.eacces),
    error_result(.enametoolong),
    error_result(.enxio),
    error_result(.enomem),
    error_result(.eagain),
    error_result(.etimedout),
};

fn is_documented_errno(result: u64) bool {
    for (documented_errnos) |e| if (result == e) return true;
    return false;
}

/// Slots that legitimately answer a NON-ZERO value under hostile arguments,
/// because their return is a value rather than a status. Each row is a claim
/// about the slot's contract, so the list is small and reviewed.
fn value_return_slots(slot: u64) bool {
    return switch (slot) {
        // Cooperative yield: 0 when there is nothing to switch to.
        syscall.sys_yield => true,
        // Wall clock in seconds — a value, and the slot takes no arguments.
        syscall.sys_time => true,
        // The shell's diagnostic ping; its argument is a payload byte.
        syscall.sys_ping => true,
        // mmap: argument 0 is a HINT address, so a mapped address is the
        // documented answer even for a hostile tuple (the sweep's mappings
        // stay inside this test root; munmap releases them).
        syscall.sys_mmap => true,
        // timer_cancel returns the ADR 0007 boolean "1 = a pending timer was
        // canceled" — and the sweep's own earlier `sys_timer_set` (slot 40
        // runs before 41) arms exactly one, so a hostile cancel of a hostile
        // set is 1 by contract, not by accident.
        syscall.sys_timer_cancel => true,
        // getpid (#2158, ADR 0048): the CALLER's pid — a value return.
        syscall.sys_getpid => true,
        else => false,
    };
}

/// The relaxed half of the oracle (both sweeps). `0` is the ABI's universal
/// "nothing happened / empty / already idle" answer, and this host seam cannot
/// tell a legitimate empty report from a wrong one without a per-slot
/// contract — so the sweep does not pretend to. What it DOES treat as a
/// violation is a non-zero value nobody reviewed (`value_return_slots` above),
/// which is the shape a made-up status under hostile input would take. The
/// observed set of zero-answering slots is recorded in this module's header and
/// on the card, not asserted here (state-dependent).
fn reviewed_answer(slot: u64, result: u64) bool {
    if (is_documented_errno(result)) return true;
    if (result == 0) return true;
    return value_return_slots(slot);
}

/// Any service-domain lock still held on return. `dispatch` takes exactly the
/// domains a slot touches and releases them on the way out; a hold here means
/// a handler acquired without releasing (or the seam's symmetry broke).
fn any_domain_lock_held() bool {
    return svclock.file.held() or
        svclock.net.held() or
        svclock.win.held() or
        svclock.ev.held() or
        svclock.kernel.held();
}

var test_write_len: usize = 0;
fn test_writer(bytes: []const u8) void {
    test_write_len += bytes.len;
}

fn hostile_tuples() [6]Args {
    const unmapped = uaccess.diagnostic_unmapped;
    return .{
        .{ 0, 0, 0, 0, 0, 0 },
        .{ 1, 2, 3, 4, 5, 6 },
        .{ @as(u64, @bitCast(@as(i64, -1))), @as(u64, @bitCast(@as(i64, -1))), @as(u64, @bitCast(@as(i64, -1))), @as(u64, @bitCast(@as(i64, -1))), @as(u64, @bitCast(@as(i64, -1))), @as(u64, @bitCast(@as(i64, -1))) },
        .{ std.math.maxInt(u64), std.math.maxInt(u64) - 1, std.math.maxInt(u64) - 2, std.math.maxInt(u64) - 3, std.math.maxInt(u64) - 4, std.math.maxInt(u64) - 5 },
        .{ unmapped, 64, unmapped + 1, 64, unmapped + 0x1000, 64 },
        .{ 0xffff_ffff, 0x1_0000_0000, 0x7fff_ffff_ffff_ffff, 0x4000_0000, 0x1000, 0xff },
    };
}

/// The seed of the corpus currently running, so every violation line is
/// reproducible from the log alone (null outside a seeded loop).
var active_seed: ?u64 = null;

fn report(context: []const u8, slot: u64, args: Args, result: u64) void {
    const name = if (entry_info(slot)) |info| info.name else "<unregistered/out-of-namespace>";
    if (active_seed) |seed| {
        std.debug.print("FUZZ-VIOLATION [seed 0x{x}] [{s}] slot={d} name={s} args={x} {x} {x} {x} {x} {x} result=0x{x}\n", .{
            seed, context, slot, name, args[0], args[1], args[2], args[3], args[4], args[5], result,
        });
    } else {
        std.debug.print("FUZZ-VIOLATION [{s}] slot={d} name={s} args={x} {x} {x} {x} {x} {x} result=0x{x}\n", .{
            context, slot, name, args[0], args[1], args[2], args[3], args[4], args[5], result,
        });
    }
}

// ---------------------------------------------------------------------------
// Target 1a — the slot namespace with no live task
// ---------------------------------------------------------------------------

test "fuzz: the syscall slot namespace fails closed for seeded hostile tuples" {
    syscall.init(test_writer);
    var frame = fresh_frame();
    var dispatched: usize = 0;
    var violations: usize = 0;

    for (seeds) |seed| {
        active_seed = seed;
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();
        // The namespace boundary: every registered row, every reserved row,
        // and 64 numbers past the end of the table.
        var slot: u64 = 0;
        while (slot < slot_count + 64) : (slot += 1) {
            for (hostile_tuples()) |tuple| {
                var args = tuple;
                // One seeded mutation per tuple: new bytes every seed without
                // giving up replayability.
                args[rand.uintLessThan(usize, 6)] = rand.int(u64);
                const before = call_count(slot);
                const result = dispatch(slot, args, &frame);
                dispatched += 1;

                if (slot >= slot_count or entry_info(slot) == null) {
                    // Out of namespace, or a reserved row: ENOSYS exactly.
                    if (result != error_result(.enosys)) {
                        report("namespace", slot, args, result);
                        violations += 1;
                    }
                } else {
                    if (!reviewed_answer(slot, result)) {
                        report("undocumented-result", slot, args, result);
                        violations += 1;
                    }
                    if (call_count(slot) != before + 1) {
                        std.debug.print("FUZZ-VIOLATION [call-count] slot={d} before={d} after={d}\n", .{ slot, before, call_count(slot) });
                        violations += 1;
                    }
                }
                if (any_domain_lock_held()) {
                    report("leaked-lock", slot, args, result);
                    violations += 1;
                }
            }
        }
    }
    if (violations > 0) std.debug.print("FUZZ-M70a namespace: {d} dispatches, {d} violation(s)\n", .{ dispatched, violations });
    try std.testing.expectEqual(@as(usize, 0), violations);
    // Guard the guard: a sweep that silently tests nothing is not evidence.
    try std.testing.expect(dispatched >= (slot_count + 64) * 6);
}

// ---------------------------------------------------------------------------
// Target 1b — a live EL0 task's buffer slots vs hostile pointers
// ---------------------------------------------------------------------------

/// Slots the live sweep must not drive, each for a stated reason. Every one of
/// them either blocks/stages the caller or mutates lifecycle/budget state, so
/// a hostile-input refusal is not what a call would be measuring.
fn lifecycle_or_blocking(slot: u64) bool {
    return switch (slot) {
        // Terminates the caller (the sweep would reap its own task).
        syscall.sys_exit => true,
        // Parks/stages the caller awaiting a wake. card #3036: slot 94
        // (sys_sleep_ns) parks on the deadline overlay the same way.
        syscall.sys_sleep, syscall.sys_sleep_ns, syscall.sys_wait, syscall.sys_futex, syscall.sys_wait_event => true,
        // Cooperative yield stages another task by design.
        syscall.sys_yield => true,
        // Creates or exits a task: a state change, not a refusal.
        syscall.sys_thread => true,
        // Slot 54 `sys_setrlimit` — shrinks the caller's own limits; a sweep
        // must not edit its budget. (The slot has no exported constant: the
        // table registers it by number.)
        54 => true,
        else => false,
    };
}

test "fuzz: a live EL0 task answers hostile pointers with a documented errno" {
    syscall.init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var tries: usize = 0;
    while (scheduler.current_id() != 2 and tries < 8) : (tries += 1) _ = scheduler.yield_current();
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    var frame = fresh_frame();
    const unmapped = uaccess.diagnostic_unmapped;
    const pointer_tuples = [_]Args{
        .{ 0, 0, 0, 0, 0, 0 },
        .{ unmapped, 64, 0, 0, 0, 0 },
        .{ unmapped, 64, unmapped + 1, 64, 0, 0 },
        .{ unmapped + 0x1000, 1, unmapped + 0x2000, 1, unmapped + 0x3000, 1 },
        .{ std.math.maxInt(u64) - 1, 64, std.math.maxInt(u64), 64, 0, 0 },
    };

    var dispatched: usize = 0;
    var violations: usize = 0;
    var slot: u64 = 0;
    while (slot < slot_count) : (slot += 1) {
        if (entry_info(slot) == null) continue;
        if (lifecycle_or_blocking(slot)) continue;
        for (pointer_tuples) |args| {
            const result = dispatch(slot, args, &frame);
            dispatched += 1;
            if (!reviewed_answer(slot, result)) {
                report("live-undocumented", slot, args, result);
                violations += 1;
            }
            if (any_domain_lock_held()) {
                report("live-leaked-lock", slot, args, result);
                violations += 1;
            }
            if (scheduler.current_id() != 2) {
                std.debug.print("FUZZ-VIOLATION [caller-moved] slot={d} current={d}\n", .{ slot, scheduler.current_id() });
                violations += 1;
            }
        }
    }
    if (violations > 0) std.debug.print("FUZZ-M70a live sweep: {d} dispatches, {d} violation(s)\n", .{ dispatched, violations });
    try std.testing.expectEqual(@as(usize, 0), violations);
    try std.testing.expect(dispatched > 0);
}

/// The EFAULT contract, encoded from the expectations the syscall suite already
/// pins (`kernel/tests/syscall_test.zig` drives each of these with
/// `uaccess.diagnostic_unmapped` and expects a documented errno). The sweep
/// drives the same slot with the hostile pointer in the SAME argument
/// position: a buffer slot may refuse for a different reason (EACCES/EINVAL),
/// but it may never answer a success.
const BufferContract = struct { slot: u64, ptr_arg: usize };
const buffer_contract = [_]BufferContract{
    .{ .slot = 5, .ptr_arg = 1 }, // sys_ipc_send
    .{ .slot = 6, .ptr_arg = 0 }, // sys_ipc_recv
    .{ .slot = 7, .ptr_arg = 0 }, // sys_procs
    .{ .slot = 10, .ptr_arg = 2 }, // sys_udp_send
    .{ .slot = 11, .ptr_arg = 1 }, // sys_udp_recv
    .{ .slot = 18, .ptr_arg = 1 }, // sys_win_get
    .{ .slot = 19, .ptr_arg = 1 }, // sys_win_query
    .{ .slot = 21, .ptr_arg = 0 }, // sys_poll_event
    .{ .slot = 23, .ptr_arg = 0 }, // sys_file_open
    .{ .slot = 25, .ptr_arg = 1 }, // sys_file_write
    .{ .slot = 27, .ptr_arg = 0 }, // sys_dir_list
    .{ .slot = 28, .ptr_arg = 0 }, // sys_exec
    .{ .slot = 34, .ptr_arg = 0 }, // sys_file_delete
    .{ .slot = 35, .ptr_arg = 0 }, // sys_file_rename (from)
    .{ .slot = 35, .ptr_arg = 2 }, // sys_file_rename (to)
    .{ .slot = 38, .ptr_arg = 0 }, // sys_clipboard_set
    .{ .slot = 39, .ptr_arg = 0 }, // sys_clipboard_get
    .{ .slot = 42, .ptr_arg = 0 }, // sys_audio_info
    .{ .slot = 62, .ptr_arg = 0 }, // sys_net_stats
    .{ .slot = 65, .ptr_arg = 2 }, // sys_wmctl
    .{ .slot = 68, .ptr_arg = 0 }, // sys_principal
    .{ .slot = 69, .ptr_arg = 0 }, // sys_file_mode
    .{ .slot = 70, .ptr_arg = 0 }, // sys_secret_get
    .{ .slot = 72, .ptr_arg = 0 }, // sys_getrandom
};

test "fuzz: the documented buffer slots refuse a hostile pointer in their own argument position" {
    syscall.init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    var tries: usize = 0;
    while (scheduler.current_id() != 2 and tries < 8) : (tries += 1) _ = scheduler.yield_current();
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    var frame = fresh_frame();
    var violations: usize = 0;
    var faulted: usize = 0;
    var empty: usize = 0;
    const unmapped = uaccess.diagnostic_unmapped;
    for (buffer_contract) |row| {
        var args: Args = .{ 64, 64, 64, 64, 64, 64 };
        args[row.ptr_arg] = unmapped;
        const result = dispatch(row.slot, args, &frame);
        // A buffer slot can only "succeed" by copying bytes (a count of rows,
        // bytes or samples) — and with an unmapped pointer any POSITIVE result
        // would mean a copy crossed a boundary uaccess rejected. Refusal is an
        // errno; 0 is the empty-state answer (nothing to copy).
        if (!(result == 0 or is_documented_errno(result))) {
            report("buffer-contract", row.slot, args, result);
            violations += 1;
        }
        if (result == error_result(.efault)) faulted += 1 else empty += 1;
        if (scheduler.current_id() != 2) {
            std.debug.print("FUZZ-VIOLATION [buffer-caller-moved] slot={d}\n", .{row.slot});
            violations += 1;
        }
        if (any_domain_lock_held()) {
            report("buffer-leaked-lock", row.slot, args, result);
            violations += 1;
        }
    }
    // Observed data, not a claim (recorded 2026-09-18 at a green run): 12 rows
    // reached the uaccess boundary at this state and refused with EFAULT; the
    // other 12 answered 0 before any copy because the mailbox/event/clipboard/
    // net state is empty at the root, so for those the sweep proves only that
    // no copy happened. Every row must be one or the other — a positive answer
    // to a hostile pointer is the violation the assertion above catches.
    if (violations > 0) std.debug.print("FUZZ-M70a buffer contract: {d} EFAULT, {d} empty-state 0, {d} violation(s)\n", .{ faulted, empty, violations });
    try std.testing.expectEqual(@as(usize, 0), violations);
    try std.testing.expectEqual(buffer_contract.len, faulted + empty);
    try std.testing.expect(faulted > 0);
}

// ---------------------------------------------------------------------------
// Target 2 — the HF wire corpus
// ---------------------------------------------------------------------------

/// Copy a fixture into `buf` and return the used prefix.
fn stage(buf: []u8, source: []const u8) []u8 {
    @memcpy(buf[0..source.len], source);
    return buf[0..source.len];
}

test "fuzz: the pinned HF reply fixtures decode to their reviewed fields" {
    // The 32 KiB pattern fixture is the probe reply's raw body (no frame) and
    // both sides compute it. Pinning it from the Zig side means this module's
    // build option cannot silently diverge from the bytes the Swift S1 test
    // and the class-A gate hash.
    const pattern = fixtures.vf_pattern_32k;
    try std.testing.expectEqual(virtio_file.probe_reply_len, pattern.len);
    var pi: usize = 0;
    while (pi < pattern.len) : (pi += 1) {
        if (pattern[pi] != virtio_file.pattern(pi)) {
            std.debug.print("FUZZ-VIOLATION [pattern-parity] at {d}\n", .{pi});
            break;
        }
    }
    try std.testing.expectEqual(pattern.len, pi);

    const read = virtio_file.decode_reply(fixtures.vf_reply_read);
    try std.testing.expectEqual(virtio_file.st_ok, read.status);
    try std.testing.expectEqual(@as(u16, 5), read.dlen);
    try std.testing.expectEqualStrings("hello", read.data);
    try std.testing.expect(!read.clamped);

    const list = virtio_file.decode_reply(fixtures.vf_reply_list);
    try std.testing.expectEqual(virtio_file.st_ok, list.status);
    try std.testing.expectEqual(@as(u16, 80), list.dlen);
    try std.testing.expectEqual(@as(usize, 2 * virtio_file.entry_row_len), list.data.len);

    // Two rows: FILE1.BIN (file, size 7) then DIR (directory, size 0).
    const first = virtio_file.decode_entry_row(list.data[0..virtio_file.entry_row_len]);
    try std.testing.expectEqualStrings("FILE1.BIN", first.name[0..first.name_len]);
    try std.testing.expectEqual(virtio_file.dir_type_file, first.type);
    try std.testing.expectEqual(@as(u64, 7), first.size);
    const second = virtio_file.decode_entry_row(list.data[virtio_file.entry_row_len..]);
    try std.testing.expectEqualStrings("DIR", second.name[0..second.name_len]);
    try std.testing.expectEqual(virtio_file.dir_type_dir, second.type);
    try std.testing.expectEqual(@as(u64, 0), second.size);
}

test "fuzz: reply decode fails closed across seeded fixture mutations" {
    var buf: [512]u8 = undefined;
    const corpus = [_][]const u8{
        fixtures.vf_reply_read,
        fixtures.vf_reply_list,
        fixtures.vf_req_read, // a request frame: a well-shaped but wrong-op envelope
    };
    var decoded: usize = 0;
    var violations: usize = 0;

    for (seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed ^ 0x9e37_79b9_7f4a_7c15);
        const rand = prng.random();
        for (corpus) |source| {
            var iter: usize = 0;
            while (iter < 64) : (iter += 1) {
                const staged = stage(&buf, source);
                var len = staged.len;
                switch (iter % 4) {
                    // Byte flips (1..3 bytes).
                    0 => {
                        var flips = 1 + rand.uintLessThan(usize, 3);
                        while (flips > 0) : (flips -= 1) staged[rand.uintLessThan(usize, staged.len)] = rand.int(u8);
                    },
                    // Truncation anywhere, including inside the header.
                    1 => len = rand.uintLessThan(usize, staged.len + 1),
                    // Extension with hostile bytes past the declared length.
                    2 => {
                        const extra = 1 + rand.uintLessThan(usize, buf.len - staged.len);
                        var i: usize = staged.len;
                        while (i < staged.len + extra) : (i += 1) buf[i] = rand.int(u8);
                        len = staged.len + extra;
                    },
                    // A hostile declared length with the frame intact.
                    else => {
                        if (len >= virtio_file.reply_hdr_len) {
                            buf[1] = rand.int(u8);
                            buf[2] = rand.int(u8);
                        }
                    },
                }
                const input = buf[0..len];
                const rep = virtio_file.decode_reply(input);
                decoded += 1;

                // Invariant 1: the data slice is always a slice OF the input.
                const in_lo = @intFromPtr(input.ptr);
                const in_hi = in_lo + input.len;
                const data_lo = @intFromPtr(rep.data.ptr);
                if (data_lo < in_lo or data_lo + rep.data.len > in_hi) {
                    std.debug.print("FUZZ-VIOLATION [reply-slice] seed=0x{x} len={d} data_len={d}\n", .{ seed, input.len, rep.data.len });
                    violations += 1;
                }
                if (input.len < virtio_file.reply_hdr_len) {
                    // Invariant 2: a sub-header buffer is an honest host error.
                    if (rep.status != virtio_file.st_host_error or rep.dlen != 0 or rep.data.len != 0 or !rep.clamped) {
                        std.debug.print("FUZZ-VIOLATION [short-reply] seed=0x{x} len={d}\n", .{ seed, input.len });
                        violations += 1;
                    }
                } else {
                    const declared = @as(u16, input[1]) | (@as(u16, input[2]) << 8);
                    const avail = input.len - virtio_file.reply_hdr_len;
                    // Invariant 3: the delivered length is min(dlen, available).
                    if (rep.data.len != @min(@as(usize, declared), avail)) {
                        std.debug.print("FUZZ-VIOLATION [reply-clamp] seed=0x{x} dlen={d} avail={d} got={d}\n", .{ seed, declared, avail, rep.data.len });
                        violations += 1;
                    }
                    // Invariant 4: `clamped` is exactly "the host promised more".
                    if (rep.clamped != (@min(@as(usize, declared), avail) < @as(usize, declared))) {
                        std.debug.print("FUZZ-VIOLATION [reply-clamped] seed=0x{x} dlen={d} len={d}\n", .{ seed, declared, input.len });
                        violations += 1;
                    }
                    // Invariant 5: status and dlen are reported as received.
                    if (rep.status != input[0] or rep.dlen != declared) {
                        std.debug.print("FUZZ-VIOLATION [reply-fields] seed=0x{x}\n", .{seed});
                        violations += 1;
                    }
                }
            }
        }
    }
    if (violations > 0) std.debug.print("FUZZ-M70a reply corpus: {d} decodes, {d} violation(s)\n", .{ decoded, violations });
    try std.testing.expectEqual(@as(usize, 0), violations);
    try std.testing.expect(decoded >= seeds.len * corpus.len * 64);
}

test "fuzz: LIST row decode never reads past its row or over-reports the name" {
    var row: [64]u8 = undefined;
    var violations: usize = 0;
    for (seeds) |seed| {
        active_seed = seed;
        var prng = std.Random.DefaultPrng.init(seed ^ 0xa5a5_5a5a);
        const rand = prng.random();
        var len: usize = 0;
        while (len <= virtio_file.entry_row_len + 8) : (len += 1) {
            for (0..8) |_| {
                var i: usize = 0;
                while (i < row.len) : (i += 1) row[i] = rand.int(u8);
                const e = virtio_file.decode_entry_row(row[0..len]);
                // A short row yields an empty entry; a full row can name at
                // most 31 bytes, and never more than the row holds.
                if (e.name_len > @min(len, 31)) {
                    std.debug.print("FUZZ-VIOLATION [seed 0x{x}] [row-name] len={d} name_len={d}\n", .{ seed, len, e.name_len });
                    violations += 1;
                }
                if (len < virtio_file.entry_row_len and (e.name_len != 0 or e.size != 0 or e.type != virtio_file.dir_type_file)) {
                    std.debug.print("FUZZ-VIOLATION [seed 0x{x}] [short-row] len={d}\n", .{ seed, len });
                    violations += 1;
                }
                if (len >= virtio_file.entry_row_len) {
                    if (e.type != row[31] or e.size != std.mem.readInt(u64, row[32..40], .little)) {
                        std.debug.print("FUZZ-VIOLATION [seed 0x{x}] [row-fields] len={d}\n", .{ seed, len });
                        violations += 1;
                    }
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), violations);
}

test "fuzz: clean_path is idempotent, never grows, and never keeps a leading slash" {
    var buf: [80]u8 = undefined;
    var checked: usize = 0;
    var violations: usize = 0;
    for (seeds) |seed| {
        active_seed = seed;
        var prng = std.Random.DefaultPrng.init(seed ^ 0x0102_0304);
        const rand = prng.random();
        for (0..256) |_| {
            const len = rand.uintLessThan(usize, buf.len);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                // A hostile alphabet: separators, dots, NULs, high bytes.
                const pick = rand.uintLessThan(usize, 8);
                buf[i] = switch (pick) {
                    0 => '/',
                    1 => '.',
                    2 => 0,
                    3 => 0xff,
                    else => @intCast('a' + rand.uintLessThan(usize, 26)),
                };
            }
            const input = buf[0..len];
            const out = virtio_file.clean_path(input);
            checked += 1;
            if (out.len > input.len) {
                std.debug.print("FUZZ-VIOLATION [seed 0x{x}] [clean-growth] in={d} out={d}\n", .{ seed, input.len, out.len });
                violations += 1;
            }
            if (out.len > 0 and out[0] == '/') {
                std.debug.print("FUZZ-VIOLATION [seed 0x{x}] [clean-slash]\n", .{seed});
                violations += 1;
            }
            if (!std.mem.eql(u8, out, virtio_file.clean_path(out))) {
                std.debug.print("FUZZ-VIOLATION [seed 0x{x}] [clean-idempotence]\n", .{seed});
                violations += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), violations);
    try std.testing.expect(checked >= seeds.len * 256);
}

test "fuzz: request encode and the READ payload builder refuse oversized shapes" {
    const offset: u64 = 0x1234_5678_9abc_def0;
    // A destination that holds a 124-byte payload exactly, and one that holds
    // a path of `path_max` plus the offset exactly.
    var out: [virtio_file.request_hdr_len + 124]u8 = undefined;
    var dest: [virtio_file.path_max + virtio_file.read_offset_len]u8 = undefined;
    // A payload longer than the u16 length field can express, and a path one
    // byte past the documented bound.
    const over_long = @as([0x10000]u8, @splat(@as(u8, 0x41)));
    const long_path = @as([(virtio_file.path_max + 1)]u8, @splat(@as(u8, 'a')));
    var payload: [512]u8 = undefined;
    var violations: usize = 0;
    var checked: usize = 0;

    if (virtio_file.encode_request(virtio_file.op_read, 0, &over_long, &out) != null) {
        std.debug.print("FUZZ-VIOLATION [encode-overlong]\n", .{});
        violations += 1;
    }
    if (virtio_file.build_read_payload(&long_path, offset, &dest) != null) {
        std.debug.print("FUZZ-VIOLATION [read-payload-overlong]\n", .{});
        violations += 1;
    }

    for (seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed ^ 0x7777_1111);
        const rand = prng.random();
        for (0..256) |_| {
            var i: usize = 0;
            while (i < payload.len) : (i += 1) payload[i] = rand.int(u8);
            // Payload lengths inside and just past what `out` can hold.
            const len = rand.uintLessThan(usize, out.len + 8);
            checked += 1;

            const built_req = virtio_file.encode_request(virtio_file.op_read, 0, payload[0..@min(len, payload.len)], &out);
            const fits = virtio_file.request_hdr_len + len <= out.len;
            if (!fits) {
                if (built_req != null) {
                    std.debug.print("FUZZ-VIOLATION [encode-short-dest] len={d}\n", .{len});
                    violations += 1;
                }
            } else if (built_req) |n| {
                if (n != virtio_file.request_hdr_len + len or out[0] != virtio_file.op_read or out[1] != 0) {
                    std.debug.print("FUZZ-VIOLATION [encode-header] n={d} len={d}\n", .{ n, len });
                    violations += 1;
                }
                const declared = @as(u16, out[2]) | (@as(u16, out[3]) << 8);
                if (@as(usize, declared) != len) {
                    std.debug.print("FUZZ-VIOLATION [encode-dlen] declared={d} len={d}\n", .{ declared, len });
                    violations += 1;
                }
                if (!std.mem.eql(u8, out[virtio_file.request_hdr_len..n], payload[0..len])) {
                    std.debug.print("FUZZ-VIOLATION [encode-payload] len={d}\n", .{len});
                    violations += 1;
                }
            } else {
                std.debug.print("FUZZ-VIOLATION [encode-refused-fittable] len={d}\n", .{len});
                violations += 1;
            }

            // build_read_payload: valid paths inside the bound; over-long
            // refused; there is no in-range length this destination cannot
            // hold, so a null answer for one is a violation.
            const path_len = rand.uintLessThan(usize, virtio_file.path_max + 1);
            const path = payload[0..path_len];
            const built = virtio_file.build_read_payload(path, offset, &dest);
            if (built) |n| {
                if (n != path.len + virtio_file.read_offset_len) {
                    std.debug.print("FUZZ-VIOLATION [read-payload-len] n={d} path={d}\n", .{ n, path.len });
                    violations += 1;
                }
                if (!std.mem.eql(u8, dest[0..path.len], path)) {
                    std.debug.print("FUZZ-VIOLATION [read-payload-bytes]\n", .{});
                    violations += 1;
                }
                if (std.mem.readInt(u64, dest[path.len..][0..8], .little) != offset) {
                    std.debug.print("FUZZ-VIOLATION [read-payload-offset]\n", .{});
                    violations += 1;
                }
            } else {
                std.debug.print("FUZZ-VIOLATION [read-payload-refused-in-range] path={d}\n", .{path.len});
                violations += 1;
            }
        }
    }
    if (violations > 0) std.debug.print("FUZZ-M70a builder corpus: {d} shapes, {d} violation(s)\n", .{ checked, violations });
    try std.testing.expectEqual(@as(usize, 0), violations);
    try std.testing.expect(checked >= seeds.len * 256);
}
