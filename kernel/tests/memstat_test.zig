const std = @import("std");
const syscall = @import("syscall");
const memstat = syscall.memstat;
const helpers = @import("helpers");

test "memstat: frozen receipt extension and non-process refusal" {
    try std.testing.expectEqual(@as(usize, 240), @sizeOf(memstat.Record));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(memstat.Record, "peak_pages"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(memstat.Record, "live_pages"));
    try std.testing.expectEqual(@as(usize, 112), @offsetOf(memstat.Record, "region_sizes"));
    try std.testing.expectEqual(syscall.process.max_mmap_regions, memstat.max_regions);
    syscall.process.init();
    var frame = helpers.task.fresh_frame();
    try std.testing.expectEqual(syscall.error_result(.einval), memstat.handle(.{ 0, 0, 0, 0, 0, 0 }, &frame));
}

fn read(pid: usize, output: *memstat.Record) u64 {
    syscall.uaccess.set_regions(.{ .base = 0, .len = 0 }, .{ .base = @intFromPtr(output), .len = @sizeOf(memstat.Record) });
    var frame = helpers.task.fresh_frame();
    return memstat.handle(.{ pid, @intFromPtr(output), @sizeOf(memstat.Record), 99, 88, 77 }, &frame);
}

test "memstat: live map/unmap counts, compact regions and retained exited receipt" {
    const process = syscall.process;
    process.init();
    defer process.init();
    syscall.uaccess.init();
    defer syscall.uaccess.init();
    const caller = process.create("heap", .{}, .{}, .{}).?;
    try std.testing.expect(process.bind(caller, syscall.scheduler.current_id()));
    const target = process.create("target", .{}, .{
        .text_va = 0x400000,
        .text_len = 5000,
        .ro_va = 0x800000,
        .ro_pages = 2,
        .ro_len = 8192,
        .data_va = 0x900000,
        .data_len = 4096,
        .argv_end_va = 0x901900,
        .stack_va = 0x1000000,
        .stack_len = 12288,
    }, .{}).?;
    try std.testing.expect(process.bind(target, 15));
    try std.testing.expect(process.add_mmap_region(target, 0x10000000, 4096, 3, 0));
    try std.testing.expect(process.add_mmap_region(target, 0x10001000, 8192, 3, 0));
    try std.testing.expect(process.record_dynamic_page(target, 0));
    try std.testing.expect(process.record_dynamic_page(target, 0));
    var output: memstat.Record = undefined;
    try std.testing.expectEqual(@as(u64, 240), read(target, &output));
    try std.testing.expectEqual(@as(u32, 1), output.version);
    try std.testing.expectEqual(@as(u32, 0), output.flags);
    try std.testing.expectEqual(@as(u64, 2), output.live_pages);
    try std.testing.expectEqual(@as(u64, 2), output.live_regions);
    try std.testing.expectEqual(@as(u64, 8192), output.text_bytes);
    try std.testing.expectEqual(@as(u64, 8192), output.ro_bytes);
    try std.testing.expectEqual(@as(u64, 0x1900), output.data_bytes);
    try std.testing.expectEqual(@as(u64, 12288), output.stack_bytes);
    try std.testing.expect(process.forget_dynamic_page(target, 0));
    try std.testing.expect(process.remove_mmap_region(target, 0x10000000, 4096));
    try std.testing.expectEqual(@as(u64, 240), read(target, &output));
    try std.testing.expectEqual(@as(u64, 1), output.live_pages);
    try std.testing.expectEqual(@as(u64, 1), output.live_regions);
    try std.testing.expectEqual(@as(u64, 8192), output.region_sizes[0]);
    try std.testing.expectEqual(@as(u64, 0), output.region_sizes[1]);
    try std.testing.expectEqual(@as(u64, 2), output.peak_pages);
    try std.testing.expectEqual(@as(u64, 2), output.peak_regions);
    _ = process.on_task_exit(15, 0);
    try std.testing.expectEqual(@as(u64, 240), read(target, &output));
    try std.testing.expectEqual(@as(u32, memstat.flag_exited), output.flags);
    try std.testing.expectEqual(@as(u64, 2), output.peak_pages);
    try std.testing.expectEqual(@as(u64, 2), output.total_pages);
    const bytes = std.mem.asBytes(&output);
    for (bytes[64..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expect(process.reap(target));
    try std.testing.expectEqual(syscall.error_result(.einval), read(target, &output));
}

test "memstat: cross uid EACCES, same uid and cap_proc_admin; denied output untouched" {
    const process = syscall.process;
    process.init();
    defer process.init();
    syscall.uaccess.init();
    defer syscall.uaccess.init();
    const caller = process.create_as("heap", .{}, .{}, .{}, .{ .uid = 42 }).?;
    try std.testing.expect(process.bind(caller, syscall.scheduler.current_id()));
    const target = process.create_as("foreign", .{}, .{}, .{}, .{ .uid = 99 }).?;
    var output = std.mem.zeroes(memstat.Record);
    output.pid = 1234;
    try std.testing.expectEqual(syscall.error_result(.eacces), read(target, &output));
    try std.testing.expectEqual(@as(u64, 1234), output.pid);
    try std.testing.expectEqual(@as(u64, 240), read(caller, &output));
    _ = process.on_task_exit(syscall.scheduler.current_id(), 0);
    const admin = process.create_as("admin", .{}, .{}, .{}, .{ .uid = 42, .caps = process.cap_proc_admin }).?;
    try std.testing.expect(process.bind(admin, syscall.scheduler.current_id()));
    try std.testing.expectEqual(@as(u64, 240), read(target, &output));
    try std.testing.expectEqual(@as(u64, target), output.pid);
}

var copy_domain_held = false;
fn check_domain(_: u64, _: usize) bool {
    copy_domain_held = syscall.svclock.kernel.held();
    return true;
}

test "memstat: exact capacity, EFAULT, invalid pid, lock through copy, no receipt mutation" {
    const process = syscall.process;
    process.init();
    defer process.init();
    syscall.uaccess.init();
    defer syscall.uaccess.init();
    const caller = process.create("heap", .{}, .{}, .{}).?;
    try std.testing.expect(process.bind(caller, syscall.scheduler.current_id()));
    var output = std.mem.zeroes(memstat.Record);
    var frame = helpers.task.fresh_frame();
    for ([_]u64{ 0, 239, 241, std.math.maxInt(u64) }) |capacity| {
        try std.testing.expectEqual(syscall.error_result(.einval), memstat.handle(.{ caller, @intFromPtr(&output), capacity, 0, 0, 0 }, &frame));
    }
    try std.testing.expectEqual(syscall.error_result(.efault), memstat.handle(.{ caller, 0, 240, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(syscall.error_result(.einval), read(process.max_processes, &output));
    const old_resolver = syscall.uaccess.resolve_write_pages;
    syscall.uaccess.resolve_write_pages = check_domain;
    defer syscall.uaccess.resolve_write_pages = old_resolver;
    copy_domain_held = false;
    try std.testing.expectEqual(@as(u64, 240), read(caller, &output));
    try std.testing.expect(copy_domain_held);
    try std.testing.expect(!syscall.svclock.kernel.held());
    const before = process.runtime_receipt(caller).?;
    syscall.svclock.kernel.acquire();
    defer syscall.svclock.kernel.release();
    try std.testing.expectEqual(@as(u64, 240), read(caller, &output));
    try std.testing.expect(syscall.svclock.kernel.held());
    try std.testing.expectEqualDeep(before, process.runtime_receipt(caller).?);
}
