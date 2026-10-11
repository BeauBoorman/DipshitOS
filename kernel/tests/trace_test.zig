const std = @import("std");
const syscall = @import("syscall");
const trace = syscall.trace;
const helpers = @import("helpers");

var output: [512]u8 = undefined;
var output_len: usize = 0;
var copy_had_control_locks = false;

fn observe_copy_locks(_: u64, _: usize) bool {
    copy_had_control_locks = syscall.svclock.held_set(
        syscall.svclock.dom_bit(.file) | syscall.svclock.dom_bit(.kernel),
    );
    return true;
}

fn writer(bytes: []const u8) void {
    @memcpy(output[output_len..][0..bytes.len], bytes);
    output_len += bytes.len;
}

test "trace: frozen layout and non-process control refusal" {
    try std.testing.expectEqual(@as(usize, 896), @sizeOf(trace.Record));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(trace.Config));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(trace.ExecRequest));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(trace.ReadHeader));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(trace.Record, "args"));
    try std.testing.expectEqual(@as(usize, 88), @offsetOf(trace.Record, "result"));
    try std.testing.expectEqual(@as(usize, 96), @offsetOf(trace.Record, "errno"));
    try std.testing.expectEqual(@as(usize, 128), @offsetOf(trace.Record, "strings"));
    var frame = helpers.task.fresh_frame();
    _ = syscall.scheduler.init();
    try std.testing.expectEqual(syscall.error_result(.einval), trace.handle(.{ 0, 0, 0, 0, 0, 0 }, &frame));
}

test "trace: each metadata kind preserves all six arguments without copying binary pointers" {
    const args = [6]u64{ 12, 34, 56, 78, 90, 123 };
    for (syscall.abi.slots) |slot| {
        if (syscall.abi.redacted(slot.number)) continue;
        var binary_only = true;
        const shape = syscall.abi.shape(slot.number, args).?;
        for (shape.args[0..shape.arg_count]) |arg| if (arg.kind == .string) {
            binary_only = false;
        };
        if (!binary_only) continue;
        const record = trace.capture(slot.number, args, 2, 3, 4);
        try std.testing.expectEqual(args, record.args);
        try std.testing.expectEqual(@as(u32, 0), record.string_mask);
        try std.testing.expectEqual(@as(u64, 2), record.pid);
        try std.testing.expectEqual(@as(u64, 3), record.tid);
        try std.testing.expectEqual(@as(u64, 4), record.cntpct);
    }
}

test "trace: bounded entry strings, escaped bytes, hostile pointer and rename length flag" {
    var text = @as([160]u8, @splat(@as(u8, 'x')));
    text[1] = '\n';
    syscall.uaccess.init();
    syscall.uaccess.set_regions(.{ .base = @intFromPtr(&text), .len = text.len }, .{ .base = 0, .len = 0 });
    const record = trace.capture(23, .{ @intFromPtr(&text), text.len, 1, 4, 5, 6 }, 0, 2, 99);
    try std.testing.expectEqual(@as(u32, 1), record.string_mask);
    try std.testing.expectEqual(@as(u32, 1), record.truncated_mask);
    try std.testing.expectEqual(@as(u16, 128), record.string_lengths[0]);
    try std.testing.expectEqualSlices(u8, text[0..128], &record.strings[0]);
    const hostile = trace.capture(23, .{ std.math.maxInt(u64), 128, 1, 0, 0, 0 }, 0, 2, 99);
    try std.testing.expectEqual(@as(u32, 1), hostile.fault_mask);
    try std.testing.expectEqual(@as(u16, 0), hostile.string_lengths[0]);
    try std.testing.expectEqualSlices(u8, &(@as([128]u8, @splat(@as(u8, 0)))), &hostile.strings[0]);
    const rename = trace.capture(35, .{ @intFromPtr(&text), (@as(u64, 1) << 63) | 3, @intFromPtr(&text), 4, 0, 0 }, 0, 2, 99);
    try std.testing.expectEqual(@as(u16, 3), rename.string_lengths[0]);
    try std.testing.expectEqual(@as(u16, 4), rename.string_lengths[2]);
    try std.testing.expectEqual(@as(u32, 0), rename.truncated_mask);
    // Op-specific metadata input strings, never the base row's output ptr.
    const title = trace.capture(65, .{ 8, 0, 0, 0, @intFromPtr(&text), 5 }, 0, 2, 99);
    try std.testing.expectEqual(@as(u16, 5), title.string_lengths[4]);
}

test "trace: never-logged slots copy nothing and zero all sensitive fields" {
    syscall.uaccess.init();
    const before = syscall.uaccess.stats();
    for ([_]u64{ 70, 71 }) |slot| {
        var record = trace.capture(slot, .{ std.math.maxInt(u64), 128, 3, 4, 5, 6 }, 7, 8, 9);
        trace.complete(&record, @bitCast(@as(i64, -7)));
        try std.testing.expectEqual(@as(u32, trace.flag_redacted), record.flags);
        try std.testing.expectEqual(@as([6]u64, @splat(@as(u64, 0))), record.args);
        try std.testing.expectEqual(@as(i64, 0), record.result);
        const bytes = std.mem.asBytes(&record);
        for (bytes[96..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
    const after = syscall.uaccess.stats();
    try std.testing.expectEqual(before.copies, after.copies);
    try std.testing.expectEqual(before.validation_faults, after.validation_faults);
}

test "trace: native errno and process/thread exit keep original entry identity" {
    var record = trace.capture(0, .{ 1, 2, 3, 4, 5, 6 }, 7, 8, 9);
    trace.complete(&record, @bitCast(@as(i64, -7)));
    try std.testing.expectEqual(@as(i64, -7), record.result);
    try std.testing.expectEqual(@as(u32, 7), record.errno);
    for ([_]u64{ 3, 73 }) |slot| {
        var exit = trace.capture(slot, .{ 1, 2, 3, 4, 5, 6 }, 7, 8, 9);
        trace.complete(&exit, 123);
        try std.testing.expectEqual(@as(u32, trace.flag_no_return), exit.flags);
        try std.testing.expectEqual(@as(u64, 7), exit.pid);
        try std.testing.expectEqual(@as(u64, 8), exit.tid);
        try std.testing.expectEqual(@as(i64, 0), exit.result);
        try std.testing.expectEqual(@as(u32, 0), exit.errno);
    }
}

test "trace: exact ring wrap, loss saturation and staged consume after overwrite" {
    var storage: [trace.backing_pages * 4096]u8 align(8) = undefined;
    var ring = trace.Ring{ .backing = @ptrCast(&storage) };
    for (0..300) |i| ring.publish(trace.capture(0, .{ i, 0, 0, 0, 0, 0 }, 1, 2, 3), 1000);
    try std.testing.expectEqual(@as(usize, 256), ring.count());
    try std.testing.expectEqual(@as(u64, 44), ring.dropped);
    try std.testing.expectEqual(@as(u64, 44), ring.backing.records[44].args[0]);
    const first = ring.first;
    for (0..4) |_| ring.publish(trace.capture(0, .{ 0, 0, 0, 0, 0, 0 }, 1, 2, 3), 2000);
    ring.consume(first, 16);
    try std.testing.expectEqual(@as(usize, 244), ring.count());
    const new_first = ring.first;
    ring.consume(first, 16);
    try std.testing.expectEqual(new_first, ring.first);
    ring.dropped = std.math.maxInt(u64);
    for (0..13) |_| ring.publish(trace.capture(0, .{ 0, 0, 0, 0, 0, 0 }, 1, 2, 3), 2000);
    try std.testing.expectEqual(std.math.maxInt(u64), ring.dropped);
    // Wrapping sequence counters do not erase or duplicate the staged tail.
    ring.first = std.math.maxInt(u64) - 3;
    ring.next = ring.first;
    for (0..8) |_| ring.publish(trace.capture(0, .{ 0, 0, 0, 0, 0, 0 }, 1, 2, 3), 2000);
    ring.consume(std.math.maxInt(u64) - 3, 5);
    try std.testing.expectEqual(@as(usize, 3), ring.count());
}

test "trace: pid and slot filters, same uid and administrative privilege" {
    var config = std.mem.zeroes(trace.Config);
    config.pid_count = 2;
    config.pids[0] = 0;
    config.pids[1] = 3;
    config.slots = .{ @as(u64, 1) << 23, @as(u64, 1) << 6 };
    try std.testing.expect(trace.selected(&config, 0, 23));
    try std.testing.expect(trace.selected(&config, 3, 70));
    try std.testing.expect(!trace.selected(&config, 4, 23));
    try std.testing.expect(!trace.selected(&config, 3, 24));
    try std.testing.expect(!trace.selected(&config, 3, 128));
    const plain = syscall.process.Principal{ .uid = 1000, .caps = 0 };
    const admin = syscall.process.Principal{ .uid = 1000, .caps = syscall.process.cap_proc_admin };
    try std.testing.expect(trace.authorized(plain, 1000));
    try std.testing.expect(!trace.authorized(plain, 0));
    try std.testing.expect(trace.authorized(admin, 0));
}

test "trace: atomic configuration, token replacement, whole reads and copy-out rollback" {
    trace.reset_for_test();
    defer trace.reset_for_test();
    syscall.init(writer);
    syscall.strace_pid = null;
    output_len = 0;
    syscall.userspace.init();
    _ = syscall.scheduler.init();
    _ = syscall.scheduler.register_worker(0x2000);
    _ = syscall.scheduler.register_user(0x3000, 0);
    syscall.scheduler.start();
    try std.testing.expect(syscall.scheduler.yield_current());
    var frame = helpers.task.fresh_frame();
    var config = std.mem.zeroes(trace.Config);
    config.version = trace.version;
    config.pid_count = 1;
    config.pids[0] = 0;
    config.slots[0] = 1;
    var output_bytes: [24 + 2 * 896 + 17]u8 align(8) = @as([(24 + 2 * 896 + 17)]u8, @splat(@as(u8, 0xaa)));
    // M97g (#2086): the session token is a CSPRNG mint — the arm fails
    // closed while unseeded, so tests key the stream explicitly.
    var seed_bytes: [syscall.csprng.seed_len]u8 = undefined;
    for (&seed_bytes, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    syscall.csprng.seed(&seed_bytes);
    syscall.uaccess.set_regions(
        .{ .base = @intFromPtr(&config), .len = @sizeOf(trace.Config) },
        .{ .base = @intFromPtr(&output_bytes), .len = output_bytes.len },
    );
    const token = trace.handle(.{ trace.op_arm, 0, @intFromPtr(&config), 88, 99, 99 }, &frame);
    try std.testing.expect(token != 0);
    const call = trace.before(0, .{ 7, 2, 3, 4, 5, 6 }, &frame);
    trace.after(call, 0, .{ 7, 2, 3, 4, 5, 6 }, 7);
    config.version = 2;
    try std.testing.expectEqual(syscall.error_result(.einval), trace.handle(.{ trace.op_filter, token, @intFromPtr(&config), 88, 0, 0 }, &frame));
    config.version = 1;
    const foreign = syscall.process.create_as(
        "foreign",
        .{ .entry_va = 1, .content_len = 1 },
        .{},
        .{},
        .{ .uid = 0, .caps = syscall.process.kernel_caps },
    ).?;
    config.pids[0] = foreign;
    try std.testing.expectEqual(syscall.error_result(.eacces), trace.handle(.{ trace.op_filter, token, @intFromPtr(&config), 88, 0, 0 }, &frame));
    config.pids[0] = 0;
    config.pids[1] = 0;
    config.pid_count = 2;
    try std.testing.expectEqual(syscall.error_result(.einval), trace.handle(.{ trace.op_filter, token, @intFromPtr(&config), 88, 0, 0 }, &frame));
    config.pid_count = 1;
    try std.testing.expectEqual(syscall.error_result(.efault), trace.handle(.{ trace.op_read, token, 8, output_bytes.len, 0, 0 }, &frame));
    const previous_resolver = syscall.uaccess.resolve_write_pages;
    syscall.uaccess.resolve_write_pages = observe_copy_locks;
    defer syscall.uaccess.resolve_write_pages = previous_resolver;
    copy_had_control_locks = false;
    try std.testing.expectEqual(@as(u64, 0), trace.handle(.{ trace.op_status, token, @intFromPtr(&output_bytes), 24, 0, 0 }, &frame));
    try std.testing.expect(copy_had_control_locks);
    try std.testing.expect(!syscall.svclock.file.held() and !syscall.svclock.kernel.held());
    const header: *const trace.ReadHeader = @ptrCast(&output_bytes);
    try std.testing.expectEqual(@as(u32, 1), header.count);
    // Header-only READ does not consume a partial record.
    try std.testing.expectEqual(@as(u64, 0), trace.handle(.{ trace.op_read, token, @intFromPtr(&output_bytes), 24, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), trace.handle(.{ trace.op_read, token, @intFromPtr(&output_bytes), output_bytes.len, 0, 0 }, &frame));
    const record: *const trace.Record = @ptrCast(@alignCast(output_bytes[24..].ptr));
    try std.testing.expectEqual(@as(u64, 0), record.pid);
    try std.testing.expectEqual([_]u64{ 7, 2, 3, 4, 5, 6 }, record.args);
    try std.testing.expectEqual(@as(i64, 7), record.result);
    for (output_bytes[24 + 896 ..]) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
    const replacement = trace.handle(.{ trace.op_arm, 0, @intFromPtr(&config), 88, 0, 0 }, &frame);
    try std.testing.expect(replacement != 0 and replacement != token);
    try std.testing.expectEqual(syscall.error_result(.ebadf), trace.handle(.{ trace.op_read, token, @intFromPtr(&output_bytes), output_bytes.len, 0, 0 }, &frame));
    const pending = trace.before(0, .{ 99, 0, 0, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, 0), trace.handle(.{ trace.op_disarm, replacement, 0, 0, 99, 99 }, &frame));
    trace.after(pending, 0, .{ 99, 0, 0, 0, 0, 0 }, 99);
    try std.testing.expectEqual(@as(u64, 0), trace.handle(.{ trace.op_read, replacement, @intFromPtr(&output_bytes), output_bytes.len, 0, 0 }, &frame));
    // Init, ring arm/control and disabled hooks never use the serial writer.
    try std.testing.expectEqual(@as(usize, 0), output_len);
}

test "trace: session tokens are CSPRNG mints bound to the owner pid (#2086)" {
    trace.reset_for_test();
    defer trace.reset_for_test();
    syscall.init(writer);
    syscall.userspace.init();
    _ = syscall.scheduler.init();
    _ = syscall.scheduler.register_worker(0x2000);
    _ = syscall.scheduler.register_user(0x3000, 0); // task 2 = pid 0, uid_user
    // A second uid_user process — same uid, different pid: the class the
    // audit could cross-read/disarm under uid equality.
    var kstack: [syscall.scheduler.task_stack_size]u8 align(16) = undefined;
    const other_pid = syscall.process.create_as("OTHER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}, syscall.process.default_principal).?;
    const other_task = syscall.scheduler.register_exec_user(syscall.userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = syscall.process.bind(other_pid, other_task);
    syscall.scheduler.start();

    var config = std.mem.zeroes(trace.Config);
    config.version = trace.version;
    config.pid_count = 1;
    config.pids[0] = 0;
    config.slots[0] = 1;
    var out: [@sizeOf(trace.ReadHeader)]u8 align(8) = undefined;
    syscall.uaccess.set_regions(
        .{ .base = @intFromPtr(&config), .len = @sizeOf(trace.Config) },
        .{ .base = @intFromPtr(&out), .len = out.len },
    );
    var frame = helpers.task.fresh_frame();

    var hops: usize = 0;
    while (syscall.scheduler.current_id() != 2 and hops < 8) : (hops += 1)
        _ = syscall.scheduler.yield_current();
    try std.testing.expectEqual(@as(usize, 2), syscall.scheduler.current_id());

    // Unseeded: the arm fails closed — a deterministic fallback token is
    // derivable, so EAGAIN (-11) is the honest answer.
    syscall.csprng.seed_fallback();
    try std.testing.expectEqual(syscall.error_result(.eagain), trace.handle(.{ trace.op_arm, 0, @intFromPtr(&config), 88, 0, 0 }, &frame));

    var seed_bytes: [syscall.csprng.seed_len]u8 = undefined;
    for (&seed_bytes, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    syscall.csprng.seed(&seed_bytes);

    const token = trace.handle(.{ trace.op_arm, 0, @intFromPtr(&config), 88, 0, 0 }, &frame);
    try std.testing.expect(token != 0);

    // A second session for the same owner gets a fresh, non-sequential
    // mint — not derivable from the observed token.
    const token2 = trace.handle(.{ trace.op_arm, 0, @intFromPtr(&config), 88, 0, 0 }, &frame);
    try std.testing.expect(token2 != 0 and token2 != token and token2 != token +% 1);

    // The other same-uid pid cannot read, filter, replace or disarm the
    // session even while holding the (leaked) token.
    hops = 0;
    while (syscall.scheduler.current_id() != other_task and hops < 8) : (hops += 1)
        _ = syscall.scheduler.yield_current();
    try std.testing.expectEqual(other_task, syscall.scheduler.current_id());
    try std.testing.expectEqual(syscall.error_result(.eacces), trace.handle(.{ trace.op_status, token2, @intFromPtr(&out), out.len, 0, 0 }, &frame));
    try std.testing.expectEqual(syscall.error_result(.eacces), trace.handle(.{ trace.op_disarm, token2, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(syscall.error_result(.eacces), trace.handle(.{ trace.op_read, token2, @intFromPtr(&out), out.len, 0, 0 }, &frame));
    try std.testing.expectEqual(syscall.error_result(.eacces), trace.handle(.{ trace.op_filter, token2, @intFromPtr(&config), 88, 0, 0 }, &frame));
    // Nor can it replace the session with its own arm.
    try std.testing.expectEqual(syscall.error_result(.eacces), trace.handle(.{ trace.op_arm, 0, @intFromPtr(&config), 88, 0, 0 }, &frame));

    // The owner still controls its session.
    hops = 0;
    while (syscall.scheduler.current_id() != 2 and hops < 8) : (hops += 1)
        _ = syscall.scheduler.yield_current();
    try std.testing.expectEqual(@as(usize, 2), syscall.scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 0), trace.handle(.{ trace.op_status, token2, @intFromPtr(&out), out.len, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), trace.handle(.{ trace.op_disarm, token2, 0, 0, 0, 0 }, &frame));
}

test "trace: monitor compatibility output is byte-for-byte unchanged" {
    syscall.userspace.init();
    syscall.init(writer);
    _ = syscall.scheduler.init();
    _ = syscall.scheduler.register_worker(0x2000);
    _ = syscall.scheduler.register_user(0x3000, 0);
    syscall.scheduler.start();
    try std.testing.expect(syscall.scheduler.yield_current());
    syscall.strace_pid = 0;
    defer syscall.strace_pid = null;
    var frame = helpers.task.fresh_frame();
    output_len = 0;
    _ = syscall.dispatch(syscall.sys_ping, .{ 9, 10, 11, 12, 13, 14 }, &frame);
    try std.testing.expectEqualStrings("[strace 0] sys_ping(0x9, 0xa, 0xb) = 0x9\n", output[0..output_len]);
    const call = trace.before(syscall.sys_exit, .{ 42, 0, 0, 0, 0, 0 }, &frame);
    _ = call;
    try std.testing.expectEqualStrings(
        "[strace 0] sys_ping(0x9, 0xa, 0xb) = 0x9\n[strace 0] sys_exit(0x2a) = \xe2\x80\x94\n",
        output[0..output_len],
    );
    const old_len = output_len;
    for ([_]u64{ 70, 71 }) |slot| {
        const redacted_call = trace.before(slot, .{ 1, 2, 3, 4, 5, 6 }, &frame);
        trace.after(redacted_call, slot, .{ 1, 2, 3, 4, 5, 6 }, 7);
    }
    try std.testing.expectEqual(old_len, output_len);
    syscall.strace_pid = null;
    _ = syscall.dispatch(syscall.sys_ping, .{ 9, 0, 0, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(old_len, output_len);
}
