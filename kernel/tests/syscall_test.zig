//! VirelaiOS syscall decoupled unit tests (M41 TS3, #954).
//!
//! Host unit test suite extracted from kernel/src/syscall.zig.
//! Tests system call registration, argument decoding/marshaling,
//! permission checks, EFAULT bounds, service routing, and lifecycle events.

const std = @import("std");
const syscall = @import("syscall");
const helpers = @import("helpers");
const task_mock = helpers.task;

// Re-export syscall types and constants
const Args = syscall.Args;
const NetStats = syscall.NetStats;
const alloc = syscall.alloc;
const app_timers = syscall.app_timers;
const arp = syscall.arp;
const call_count = syscall.call_count;
const clipboard = syscall.clipboard;
const console = syscall.console;
const dispatch = syscall.dispatch;
const driving_award = syscall.driving_award;
const ensure_table = syscall.ensure_table;
const entry_info = syscall.entry_info;
const error_result = syscall.error_result;
const events = syscall.events;
const exceptions = syscall.exceptions;
const file_table = syscall.file_table;
const handle_svc = syscall.handle_svc;
const handle_win_close = syscall.handle_win_close;
const init = syscall.init;
const m33_surf_scan_tag = syscall.m33_surf_scan_tag;
const m33_surf_win_tag = syscall.m33_surf_win_tag;
const mailbox = syscall.mailbox;
const memmap = syscall.memmap;
const mmu = syscall.mmu;
const net_stats_bytes = syscall.net_stats_bytes;
const process = syscall.process;
const report = syscall.report;
const scheduler = syscall.scheduler;
const set_user_regions = syscall.set_user_regions;
const shared_mmap = syscall.shared_mmap;
const shared_region = syscall.shared_region;
const slot_count = syscall.slot_count;
const svc_immediate = syscall.svc_immediate;
const sys_audio_info = syscall.sys_audio_info;
const sys_audio_mute = syscall.sys_audio_mute;
const sys_audio_play = syscall.sys_audio_play;
const sys_audio_volume = syscall.sys_audio_volume;
const sys_clipboard_get = syscall.sys_clipboard_get;
const sys_clipboard_set = syscall.sys_clipboard_set;
const sys_dir_list = syscall.sys_dir_list;
const sys_drag_read = syscall.sys_drag_read;
const sys_exec = syscall.sys_exec;
const sys_exit = syscall.sys_exit;
const sys_thread = syscall.sys_thread;
const sys_futex = syscall.sys_futex;
const sys_exnotify = syscall.sys_exnotify;
const sys_file_close = syscall.sys_file_close;
const sys_file_delete = syscall.sys_file_delete;
const sys_file_free = syscall.sys_file_free;
const sys_file_open = syscall.sys_file_open;
const sys_file_read = syscall.sys_file_read;
const sys_file_rename = syscall.sys_file_rename;
const sys_file_truncate = syscall.sys_file_truncate;
const sys_file_write = syscall.sys_file_write;
const sys_font_size = syscall.sys_font_size;
const sys_ipc_recv = syscall.sys_ipc_recv;
const sys_ipc_send = syscall.sys_ipc_send;
const sys_kill = syscall.sys_kill;
const sys_mmap = syscall.sys_mmap;
const sys_munmap = syscall.sys_munmap;
const sys_net_stats = syscall.sys_net_stats;
const sys_notify = syscall.sys_notify;
const sys_ping = syscall.sys_ping;
const sys_ping_poll = syscall.sys_ping_poll;
const sys_ping_send = syscall.sys_ping_send;
const sys_pipe_read = syscall.sys_pipe_read;
const sys_pipe_write = syscall.sys_pipe_write;
const sys_poll_event = syscall.sys_poll_event;
const sys_procs = syscall.sys_procs;
const sys_sleep = syscall.sys_sleep;
const sys_tcp_close = syscall.sys_tcp_close;
const sys_tcp_connect = syscall.sys_tcp_connect;
const sys_tcp_recv = syscall.sys_tcp_recv;
const sys_tcp_send = syscall.sys_tcp_send;
const sys_timer_cancel = syscall.sys_timer_cancel;
const sys_timer_set = syscall.sys_timer_set;
const sys_udp_listen = syscall.sys_udp_listen;
const sys_udp_recv = syscall.sys_udp_recv;
const sys_udp_send = syscall.sys_udp_send;
const sys_wait = syscall.sys_wait;
const sys_wait_event = syscall.sys_wait_event;
const sys_win_close = syscall.sys_win_close;
const sys_win_fill = syscall.sys_win_fill;
const sys_win_fill_batch = syscall.sys_win_fill_batch;
const sys_win_get = syscall.sys_win_get;
const sys_win_lower_back = syscall.sys_win_lower_back;
const sys_win_move = syscall.sys_win_move;
const sys_win_open = syscall.sys_win_open;
const sys_win_present = syscall.sys_win_present;
const sys_win_query = syscall.sys_win_query;
const sys_win_raise = syscall.sys_win_raise;
const sys_win_raise_front = syscall.sys_win_raise_front;
const sys_win_resize = syscall.sys_win_resize;
const sys_win_set_title = syscall.sys_win_set_title;
const sys_win_set_unsaved = syscall.sys_win_set_unsaved;
const sys_setrlimit = syscall.sys_setrlimit;
const sys_win_set_visible = syscall.sys_win_set_visible;
const sys_wmctl = syscall.sys_wmctl;
const sys_time = syscall.sys_time;
const sys_time_set = syscall.sys_time_set;
const sys_tty_attach = syscall.sys_tty_attach;
const sys_tty_net_auth = syscall.sys_tty_net_auth;
const sys_principal = syscall.sys_principal;
const sys_file_mode = syscall.sys_file_mode;
const sys_secret_get = syscall.sys_secret_get;
const sys_getrandom = syscall.sys_getrandom;
const getrandom_max = syscall.getrandom_max;
const secret = syscall.secret;
const trust = syscall.trust;
const principal_bytes = syscall.principal_bytes;
const terminal = syscall.terminal;
const sys_write = syscall.sys_write;
const sys_yield = syscall.sys_yield;
const tcp = syscall.tcp;
const timer = syscall.timer;
const uaccess = syscall.uaccess;
const udp = syscall.udp;
const userspace = syscall.userspace;
const virtio_file = syscall.virtio_file;
const virtio_gpu = syscall.virtio_gpu;
const virtio_net = syscall.virtio_net;
const virtio_snd = syscall.virtio_snd;
const win_query_bytes = syscall.win_query_bytes;
const win_rect_bytes = syscall.win_rect_bytes;
const wm_server = syscall.wm_server;
const wnd_core = syscall.wnd_core;
const write_cap = syscall.write_cap;

test "syscall: M94 trace and profile control and remaining observability stub are registered" {
    init(test_writer);
    var frame = fresh_frame();
    const names = [_][]const u8{ "sys_trace", "sys_profile", "sys_memstat" };
    for (names, 81..) |name, number| {
        const info = entry_info(number);
        try std.testing.expect(info != null);
        try std.testing.expectEqualStrings(name, info.?.name);
        const refused = error_result(.einval);
        try std.testing.expectEqual(refused, dispatch(number, .{ 0, 0, 0, 0, 0, 0 }, &frame));
        try std.testing.expectEqual(refused, dispatch(number, .{ 99, 99, 99, 99, 99, 99 }, &frame));
        try std.testing.expectEqual(@as(u64, 2), call_count(number));
    }
}

test "syscall: ABI metadata covers every registered row without pointers" {
    const abi = syscall.abi;
    try std.testing.expectEqual(@as(usize, 84), abi.slots.len);
    for (&abi.slots, 0..) |slot, index| {
        try std.testing.expectEqual(index, slot.number);
        try std.testing.expectEqualStrings(slot.name(), entry_info(index).?.name);
        try std.testing.expect(slot.arg_count <= 6);
        for (slot.args[0..slot.arg_count], 0..) |arg, arg_index| {
            if (arg.kind == .string) {
                try std.testing.expect(arg.length_arg < slot.arg_count);
                try std.testing.expect(arg.length_arg != arg_index);
                try std.testing.expect(arg.length_mask != 0);
            }
        }
        try std.testing.expectEqual(index == 70 or index == 71, abi.redacted(index));
    }
    for (abi.variants, 0..) |item, index| {
        try std.testing.expect(item.number < abi.slots.len);
        try std.testing.expect(item.selector < 6);
        try std.testing.expect(!abi.redacted(item.number));
        for (abi.variants[0..index]) |earlier| {
            try std.testing.expect(earlier.number != item.number or earlier.selector != item.selector or earlier.op != item.op);
        }
    }
    try std.testing.expect(abi.lookup(84) == null);
    try std.testing.expectEqual(abi.ArgKind.string, abi.shape(79, .{ 0, 0, 0, 0, 0, 0 }).?.args[1].kind);
    try std.testing.expectEqual(abi.ArgKind.fd, abi.shape(80, .{ 2, 0, 0, 0, 0, 0 }).?.args[1].kind);
    try std.testing.expectEqual(abi.ArgKind.int, abi.shape(27, .{ 0, 0, 0, 0x8000000000000002, 0, 0 }).?.args[0].kind);
}

// Shared test helper from helpers.task_mock
const fresh_frame = task_mock.fresh_frame;

var test_write_buffer: [8192]u8 = undefined;
var test_write_len: usize = 0;

fn test_writer(bytes: []const u8) void {
    @memcpy(test_write_buffer[test_write_len..][0..bytes.len], bytes);
    test_write_len += bytes.len;
}

var test_marshaled_args: Args = [_]u64{0} ** 6;
fn capture_marshaled_args(args: Args, _: *exceptions.VectorFrame) u64 {
    test_marshaled_args = args;
    return 0xcafe;
}

test "syscall: runtime table has 128 slots and eighty-four registered rows" {
    init(test_writer);
    const table = ensure_table();
    try std.testing.expectEqual(@as(usize, 128), table.len);
    var seen: [slot_count]bool = [_]bool{false} ** slot_count;
    var implemented: usize = 0;
    for (table, 0..) |entry, number| {
        if (entry.handler != null) {
            try std.testing.expect(!seen[number]);
            seen[number] = true;
            implemented += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 84), implemented);
    try std.testing.expectEqualStrings("sys_socket", entry_info(80).?.name);
    try std.testing.expectEqualStrings("sys_fs_metadata", entry_info(79).?.name);
    try std.testing.expectEqualStrings("sys_pipe_read", entry_info(sys_pipe_read).?.name);
    try std.testing.expectEqualStrings("sys_pipe_write", entry_info(sys_pipe_write).?.name);
    try std.testing.expectEqualStrings("sys_font_size", entry_info(sys_font_size).?.name);
    try std.testing.expectEqualStrings("sys_audio_info", entry_info(42).?.name);
    try std.testing.expectEqualStrings("sys_audio_play", entry_info(43).?.name);
    try std.testing.expectEqualStrings("sys_audio_volume", entry_info(44).?.name);
    try std.testing.expectEqualStrings("sys_audio_mute", entry_info(45).?.name);
    try std.testing.expectEqualStrings("sys_ping", entry_info(0).?.name);
    try std.testing.expectEqualStrings("sys_exit", entry_info(3).?.name);
    try std.testing.expectEqualStrings("sys_sleep", entry_info(4).?.name);
    try std.testing.expectEqualStrings("sys_ipc_send", entry_info(5).?.name);
    try std.testing.expectEqualStrings("sys_ipc_recv", entry_info(6).?.name);
    try std.testing.expectEqualStrings("sys_procs", entry_info(7).?.name);
    try std.testing.expectEqualStrings("sys_wait", entry_info(8).?.name);
    try std.testing.expectEqualStrings("sys_udp_listen", entry_info(9).?.name);
    try std.testing.expectEqualStrings("sys_udp_send", entry_info(10).?.name);
    try std.testing.expectEqualStrings("sys_udp_recv", entry_info(11).?.name);
    try std.testing.expectEqualStrings("sys_win_open", entry_info(12).?.name);
    try std.testing.expectEqualStrings("sys_win_fill", entry_info(13).?.name);
    try std.testing.expectEqualStrings("sys_win_present", entry_info(14).?.name);
    try std.testing.expectEqualStrings("sys_win_close", entry_info(15).?.name);
    try std.testing.expectEqualStrings("sys_win_move", entry_info(16).?.name);
    try std.testing.expectEqualStrings("sys_win_raise", entry_info(17).?.name);
    try std.testing.expectEqualStrings("sys_win_get", entry_info(18).?.name);
    try std.testing.expectEqualStrings("sys_win_query", entry_info(19).?.name);
    try std.testing.expectEqualStrings("sys_win_set_visible", entry_info(20).?.name);
    try std.testing.expectEqualStrings("sys_poll_event", entry_info(21).?.name);
    try std.testing.expectEqualStrings("sys_wait_event", entry_info(22).?.name);
    try std.testing.expectEqualStrings("sys_file_open", entry_info(23).?.name);
    try std.testing.expectEqualStrings("sys_file_read", entry_info(24).?.name);
    try std.testing.expectEqualStrings("sys_file_write", entry_info(25).?.name);
    try std.testing.expectEqualStrings("sys_file_close", entry_info(26).?.name);
    try std.testing.expectEqualStrings("sys_dir_list", entry_info(27).?.name);
    try std.testing.expectEqualStrings("sys_exec", entry_info(28).?.name);
    try std.testing.expectEqualStrings("sys_kill", entry_info(29).?.name);
    try std.testing.expectEqualStrings("sys_tcp_connect", entry_info(30).?.name);
    try std.testing.expectEqualStrings("sys_tcp_send", entry_info(31).?.name);
    try std.testing.expectEqualStrings("sys_tcp_recv", entry_info(32).?.name);
    try std.testing.expectEqualStrings("sys_tcp_close", entry_info(33).?.name);
    try std.testing.expectEqualStrings("sys_file_delete", entry_info(34).?.name);
    try std.testing.expectEqualStrings("sys_file_rename", entry_info(35).?.name);
    try std.testing.expectEqualStrings("sys_file_truncate", entry_info(36).?.name);
    try std.testing.expectEqualStrings("sys_file_free", entry_info(37).?.name);
    try std.testing.expectEqualStrings("sys_clipboard_set", entry_info(38).?.name);
    try std.testing.expectEqualStrings("sys_clipboard_get", entry_info(39).?.name);
    try std.testing.expectEqualStrings("sys_timer_set", entry_info(40).?.name);
    try std.testing.expectEqualStrings("sys_timer_cancel", entry_info(41).?.name);
    try std.testing.expectEqualStrings("sys_win_fill_batch", entry_info(46).?.name);
    try std.testing.expectEqualStrings("sys_win_resize", entry_info(47).?.name);
    try std.testing.expectEqualStrings("sys_drag_start", entry_info(48).?.name);
    try std.testing.expectEqualStrings("sys_win_raise_front", entry_info(49).?.name);
    try std.testing.expectEqualStrings("sys_win_lower_back", entry_info(50).?.name);
    try std.testing.expectEqualStrings("sys_notify", entry_info(51).?.name);
    try std.testing.expectEqualStrings("sys_ping_send", entry_info(sys_ping_send).?.name);
    try std.testing.expectEqualStrings("sys_ping_poll", entry_info(sys_ping_poll).?.name);
    try std.testing.expectEqualStrings("sys_net_stats", entry_info(sys_net_stats).?.name);
    try std.testing.expectEqualStrings("sys_mmap", entry_info(sys_mmap).?.name);
    try std.testing.expectEqualStrings("sys_munmap", entry_info(sys_munmap).?.name);
    // M32 WMS2 (issue #622): slot 65 is the render-server register.
    try std.testing.expectEqualStrings("sys_wmctl", entry_info(sys_wmctl).?.name);
    // M50 TS1 (issue #1135): slot 68 is the read-only principal report.
    try std.testing.expectEqualStrings("sys_principal", entry_info(sys_principal).?.name);
    // M50 TS2 (issue #1136): slot 69 is owner-only chmod.
    try std.testing.expectEqualStrings("sys_file_mode", entry_info(sys_file_mode).?.name);
    // M51 SSH-P1 (issue #1166, ADR 0025 D5): slot 72 is the EL0 entropy read.
    try std.testing.expectEqualStrings("sys_getrandom", entry_info(sys_getrandom).?.name);
    // ADR 0027 D3 (M65a, #1439): slot 73 is sys_thread.
    try std.testing.expectEqualStrings("sys_thread", entry_info(sys_thread).?.name);
    // ADR 0027 D4 (M65b, #1440): slot 74 is sys_futex.
    try std.testing.expectEqualStrings("sys_futex", entry_info(sys_futex).?.name);
    // Issue #1228 (phase 0c): slot 75 is the EL0 fault-handler register.
    try std.testing.expectEqualStrings("sys_exnotify", entry_info(sys_exnotify).?.name);
}

test "syscall: adapter decodes x8 and x0-x5 and unknown numbers return ENOSYS" {
    userspace.init();
    init(test_writer);
    var frame = fresh_frame();
    try std.testing.expect(exceptions.frame_write(&frame, 8, sys_ping));
    try std.testing.expect(exceptions.frame_write(&frame, 0, 41));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(@as(u64, 41), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_ping));

    // Unregistered in-range slots still return ENOSYS. M94 reserves 81–83.
    try std.testing.expect(exceptions.frame_write(&frame, 8, 84));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(error_result(.enosys), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(84));

    try std.testing.expect(exceptions.frame_write(&frame, 8, 85));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(error_result(.enosys), exceptions.frame_read(&frame, 0));
}

test "syscall: handle_svc marshals every x0-x5 argument before replacing x0" {
    init(test_writer);
    _ = ensure_table();
    const saved = syscall.table_storage[65];
    defer syscall.table_storage[65] = saved;
    syscall.table_storage[65] = .{ .name = "test_capture", .handler = capture_marshaled_args };
    var frame = fresh_frame();
    const expected: Args = .{
        0x0101_0101_0101_0101,
        0x1212_1212_1212_1212,
        0x2323_2323_2323_2323,
        0x3434_3434_3434_3434,
        0x4545_4545_4545_4545,
        0x5656_5656_5656_5656,
    };
    for (expected, 0..) |value, reg| try std.testing.expect(exceptions.frame_write(&frame, @intCast(reg), value));
    try std.testing.expect(exceptions.frame_write(&frame, 8, 65));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(expected, test_marshaled_args);
    try std.testing.expectEqual(@as(u64, 0xcafe), exceptions.frame_read(&frame, 0));
}

test "syscall: write validates stream fd, short staging, and the uaccess EFAULT contract" {
    init(test_writer);
    test_write_len = 0;
    var frame = fresh_frame();
    const bytes = "write-through-mock";
    set_user_regions(
        .{ .base = @intFromPtr(bytes.ptr), .len = bytes.len },
        .{ .base = 0, .len = 0 },
    );
    var args: Args = .{ 1, @intFromPtr(bytes.ptr), bytes.len, 0, 0, 0 };
    try std.testing.expectEqual(@as(u64, bytes.len), dispatch(sys_write, args, &frame));
    try std.testing.expectEqualStrings(bytes, test_write_buffer[0..test_write_len]);

    args[0] = 2;
    test_write_len = 0;
    try std.testing.expectEqual(@as(u64, bytes.len), dispatch(sys_write, args, &frame));
    args[0] = 3;
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_write, args, &frame));
    args[0] = 1;
    args[2] = write_cap + 1;
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_write, args, &frame));
    // Bad user pointers now return the reserved EFAULT (-3), never EINVAL:
    // arithmetic overflow, one byte before the region, one byte past it,
    // and an unmapped address above the identity blanket.
    args[1] = std.math.maxInt(u64) - 1;
    args[2] = 4;
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_write, args, &frame));
    args[1] = @intFromPtr(bytes.ptr) - 1;
    args[2] = 1;
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_write, args, &frame));
    args[1] = @intFromPtr(bytes.ptr) + bytes.len - 1;
    args[2] = 2;
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_write, args, &frame));
    args[1] = uaccess.diagnostic_unmapped;
    args[2] = 8;
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_write, args, &frame));

    // Zero length is legal even at a wild address: nothing is copied.
    test_write_len = 0;
    args[1] = uaccess.diagnostic_unmapped;
    args[2] = 0;
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_write, args, &frame));
    try std.testing.expectEqual(@as(usize, 0), test_write_len);
}

test "B1: console writes larger than staging complete through confirmed short counts" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    test_write_len = 0;
    var frame = fresh_frame();
    var bytes: [1103]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @intCast(i % 251);
    set_user_regions(.{ .base = @intFromPtr(&bytes), .len = bytes.len }, .{ .base = 0, .len = 0 });
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = dispatch(sys_write, .{ 2, @intFromPtr(&bytes) + sent, bytes.len - sent, 0, 0, 0 }, &frame);
        try std.testing.expect(n > 0 and n <= write_cap);
        sent += @intCast(n);
    }
    try std.testing.expectEqual(@as(u64, 5), call_count(sys_write));
    try std.testing.expectEqualSlices(u8, &bytes, test_write_buffer[0..test_write_len]);
}

test "B1: stream syscall identities EOF EFAULT closure and legacy file zero do not alias" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    try std.testing.expect(scheduler.yield_current());
    const files = [_]virtio_file.TestFile{.{ .name = "INPUT", .data = "bytes" }};
    virtio_file.set_test_share(&files);
    defer virtio_file.set_test_share(null);
    const fd = file_table.open(1, "INPUT", file_table.MODE_READ);
    var plan: file_table.StreamPlan = .{};
    try std.testing.expectEqual(@as(i64, 0), file_table.prepare_streams(1, .{ .sources = .{ @intCast(fd), file_table.stream_console, file_table.stream_closed } }, &plan));
    file_table.commit_streams(0, &plan);
    var frame = fresh_frame();
    var bytes: [4097]u8 = undefined;
    @memset(&bytes, 'x');
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = @intFromPtr(&bytes), .len = bytes.len });
    const stdin = file_table.stream_base;
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_file_read, .{ stdin, uaccess.diagnostic_unmapped, bytes.len, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 5), dispatch(sys_file_read, .{ stdin, @intFromPtr(&bytes), bytes.len, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("bytes", bytes[0..5]);
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_file_read, .{ stdin, @intFromPtr(&bytes), bytes.len, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_file_read, .{ 0, @intFromPtr(&bytes), 5, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_file_write, .{ stdin, @intFromPtr(&bytes), 5, 0, 0, 0 }, &frame));
    test_write_len = 0;
    try std.testing.expectEqual(@as(u64, write_cap), dispatch(sys_file_write, .{ stdin + 1, @intFromPtr(&bytes), bytes.len, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_write, .{ 2, @intFromPtr(&bytes), 5, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_file_close, .{ stdin, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_file_read, .{ stdin, @intFromPtr(&bytes), 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_file_close, .{ stdin, 0, 0, 0, 0, 0 }, &frame));
    file_table.reset_process(0);
}

test "B1: versioned spawn marshalling and loader failures preserve source ownership" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    try std.testing.expect(scheduler.yield_current());
    const files = [_]virtio_file.TestFile{.{ .name = "INPUT", .data = "bytes" }};
    virtio_file.set_test_share(&files);
    defer virtio_file.set_test_share(null);
    const fd = file_table.open(0, "INPUT", file_table.MODE_READ);
    var wire = extern struct {
        request: file_table.StreamRequest,
        path: [10]u8,
    }{ .request = .{ .sources = .{ @intCast(fd), file_table.stream_console, file_table.stream_console } }, .path = "NOSUCH.BIN".* };
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = @intFromPtr(&wire), .len = @sizeOf(@TypeOf(wire)) });
    var frame = fresh_frame();
    var args: Args = .{ @intFromPtr(&wire.path), wire.path.len, 0, syscall.exec_stream_flag, @intFromPtr(&wire.request), @sizeOf(file_table.StreamRequest) };
    args[5] -= 1;
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_exec, args, &frame));
    args[5] += 1;
    args[4] = uaccess.diagnostic_unmapped;
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_exec, args, &frame));
    args[4] = @intFromPtr(&wire.request);
    wire.request.version = 2;
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_exec, args, &frame));
    wire.request.version = 1;
    try std.testing.expectEqual(error_result(.enoent), dispatch(sys_exec, args, &frame));
    var buf: [5]u8 = undefined;
    try std.testing.expectEqual(@as(i64, 5), file_table.read(0, @intCast(fd), &buf));
    try std.testing.expectEqualStrings("bytes", &buf);
    try std.testing.expectEqual(@as(?usize, 0), process.find_by_task(scheduler.current_id()));
    try std.testing.expectEqual(@as(i64, 0), file_table.close(0, @intCast(fd)));
}

test "syscall: yield returns zero and exit removes the current task" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_yield, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), scheduler.cooperative_yield_count());
    // The first yield selected EL0 directly; now exit it. It is off the
    // ring, so the selected frame belongs to shell and can never be `frame`.
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_exit, .{ 7, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(scheduler.is_terminated(2));
    try std.testing.expectEqual(@as(?u64, 7), scheduler.terminated_status(2));
    try std.testing.expectEqual(@as(u64, 1), scheduler.exit_count());
    try std.testing.expect(exceptions.resume_frame[0] != @intFromPtr(&frame));
}

test "syscall: sleep blocks the current task and returns zero on wake" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    var frame = fresh_frame();
    // The shell (slot 0) sleeps 2 ticks: it is blocked and EL0 is
    // staged. Publish the result before the caller can wake on another
    // core, rather than returning the original argument through that race.
    exceptions.resume_frame[0] = @intFromPtr(&frame);
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_sleep, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@intFromPtr(&frame), scheduler.tasks[0].sp);
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.is_blocked(0));
    // A blocked task is skipped by the round-robin ring.
    try std.testing.expect(scheduler.yield_current()); // user -> idle
    try std.testing.expectEqual(@as(usize, scheduler.idle_id), scheduler.current_id());
    try std.testing.expect(scheduler.yield_current()); // idle -> user (worker suppressed)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    // One tick is not enough for a 2-tick sleep; the second tick wakes it.
    scheduler.on_tick();
    try std.testing.expect(scheduler.is_blocked(0));
    scheduler.on_tick();
    try std.testing.expect(!scheduler.is_blocked(0));
    // The ring reaches the woken shell again.
    try std.testing.expect(scheduler.yield_current()); // user -> idle
    try std.testing.expect(scheduler.yield_current()); // idle -> shell
    try std.testing.expectEqual(@as(usize, 0), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(&frame, 0));
}

test "B6 wait: refused sleep retains its error through SVC dispatch" {
    init(test_writer);
    _ = scheduler.init(); // not started, so the sleep cannot park
    var frame = fresh_frame();
    _ = exceptions.frame_write(&frame, 0, 1);
    _ = exceptions.frame_write(&frame, 8, sys_sleep);
    try std.testing.expect(syscall.handle_svc(&frame, syscall.svc_immediate));
    try std.testing.expectEqual(error_result(.einval), exceptions.frame_read(&frame, 0));
}

test "syscall: handle_svc writes yield result into the suspended caller frame" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    var caller = fresh_frame();
    try std.testing.expect(exceptions.frame_write(&caller, 0, 0xdead));
    try std.testing.expect(exceptions.frame_write(&caller, 8, sys_yield));
    exceptions.resume_frame[0] = @intFromPtr(&caller);
    try std.testing.expect(handle_svc(&caller, svc_immediate));
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(&caller, 0));
    try std.testing.expect(exceptions.resume_frame[0] != @intFromPtr(&caller));
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
}

test "syscall: ipc send/recv round-trip moves bytes between two processes" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    // A second live process (the peer) on its own task slot.
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const peer_pid = process.create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const peer_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(peer_pid, peer_task);
    scheduler.start();

    const send_bytes = "ping 1\n";
    var recv_buf: [mailbox.message_max]u8 = undefined;
    set_user_regions(
        .{ .base = @intFromPtr(send_bytes.ptr), .len = send_bytes.len },
        .{ .base = @intFromPtr(&recv_buf), .len = recv_buf.len },
    );
    var frame = fresh_frame();
    // Drive the ring to the boot payload's task (process 0).
    try std.testing.expect(scheduler.yield_current()); // shell -> user (task 2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    // Process 0 sends "ping 1\n" to the peer (pid 1).
    try std.testing.expectEqual(@as(u64, send_bytes.len), dispatch(sys_ipc_send, .{ peer_pid, @intFromPtr(send_bytes.ptr), send_bytes.len, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 1), mailbox.pending(peer_pid));
    // Drive the ring to the peer's task: it recv's the SAME bytes.
    try std.testing.expect(scheduler.yield_current()); // user -> peer (task 3)
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, send_bytes.len), dispatch(sys_ipc_recv, .{ @intFromPtr(&recv_buf), mailbox.message_max, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings(send_bytes, recv_buf[0..send_bytes.len]);
    try std.testing.expectEqual(@as(usize, 0), mailbox.pending(peer_pid));
    const peer_info = mailbox.info(peer_pid);
    try std.testing.expectEqual(@as(u64, 1), peer_info.sent);
    try std.testing.expectEqual(@as(u64, 1), peer_info.recv);
}

test "syscall: ipc send refuses full, empty, and isolated targets exactly" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // process 0 (boot payload), task 2
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const peer_pid = process.create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const peer_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(peer_pid, peer_task);
    scheduler.start();
    const bytes = "ping 1\n";
    set_user_regions(
        .{ .base = @intFromPtr(bytes.ptr), .len = bytes.len },
        .{ .base = 0, .len = 0 },
    );
    var frame = fresh_frame();
    // A zero-length send is a no-op returning 0.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_ipc_send, .{ peer_pid, 0, 0, 0, 0, 0 }, &frame));
    // Truncation: a 100-byte send stores the first 64 bytes and returns 64.
    const long = "x" ** 100;
    set_user_regions(.{ .base = @intFromPtr(long.ptr), .len = long.len }, .{ .base = 0, .len = 0 });
    try std.testing.expectEqual(@as(u64, mailbox.message_max), dispatch(sys_ipc_send, .{ peer_pid, @intFromPtr(long.ptr), long.len, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 1), mailbox.pending(peer_pid));
    try std.testing.expectEqual(@as(usize, mailbox.message_max), mailbox.message(peer_pid, 0).?.len);
    // Re-arm the window on `bytes` (the truncation block moved it to `long`),
    // then fill the ring: 7 more sends fill the 8 slots (card 4b, claim
    // 3179: the capacity is a data-path constant, re-derived 4 → 8); the
    // 9th is ENOSPC.
    set_user_regions(
        .{ .base = @intFromPtr(bytes.ptr), .len = bytes.len },
        .{ .base = 0, .len = 0 },
    );
    for (1..mailbox.max_messages) |_| try std.testing.expectEqual(@as(u64, 1), dispatch(sys_ipc_send, .{ peer_pid, @intFromPtr(bytes.ptr), 1, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enospc), dispatch(sys_ipc_send, .{ peer_pid, @intFromPtr(bytes.ptr), 1, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, mailbox.max_messages), mailbox.pending(peer_pid));
    // Isolation: a free pid, an out-of-range pid, and an exited pid are EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_ipc_send, .{ 7, @intFromPtr(bytes.ptr), 1, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_ipc_send, .{ process.max_processes, @intFromPtr(bytes.ptr), 1, 0, 0, 0 }, &frame));
    const gone = process.create("GONE", .{ .entry_va = 0x400000, .content_len = 1 }, .{}, .{}).?;
    _ = process.bind(gone, 99);
    _ = process.on_task_exit(99, 7);
    _ = process.take_exit_report();
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_ipc_send, .{ gone, @intFromPtr(bytes.ptr), 1, 0, 0, 0 }, &frame));
    // Error precedence: the full-ring check runs BEFORE the uaccess check,
    // so a bad pointer against a full ring is still ENOSPC (nothing is ever
    // copied into a full ring).
    try std.testing.expectEqual(error_result(.enospc), dispatch(sys_ipc_send, .{ peer_pid, uaccess.diagnostic_unmapped, 4, 0, 0, 0 }, &frame));
    // With a slot free, EFAULT: a bad user pointer is rejected before any
    // mailbox mutation.
    mailbox.drop(peer_pid);
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_ipc_send, .{ peer_pid, uaccess.diagnostic_unmapped, 4, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, mailbox.max_messages - 1), mailbox.pending(peer_pid));
}

test "syscall: ipc recv returns empty, clamps, truncates, and EFAULT keeps the message" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0
    scheduler.start();
    var frame = fresh_frame();
    var recv_buf: [mailbox.message_max]u8 = undefined;
    // An EL1h task (the shell here) is never a process: EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_ipc_recv, .{ @intFromPtr(&recv_buf), mailbox.message_max, 0, 0, 0, 0 }, &frame));
    // Drive to the boot payload's task (process 0).
    try std.testing.expect(scheduler.yield_current()); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = @intFromPtr(&recv_buf), .len = recv_buf.len },
    );
    // Empty: nothing to receive -> 0.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_ipc_recv, .{ @intFromPtr(&recv_buf), mailbox.message_max, 0, 0, 0, 0 }, &frame));
    // Seed process 0's own ring directly (a sender targeted it).
    try std.testing.expectEqual(mailbox.SendResult.ok, mailbox.send(0, "ping 7\n"));
    // max > 64 clamps to 64 (still returns the full 7).
    try std.testing.expectEqual(@as(u64, 7), dispatch(sys_ipc_recv, .{ @intFromPtr(&recv_buf), 100, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("ping 7\n", recv_buf[0..7]);
    try std.testing.expectEqual(@as(usize, 0), mailbox.pending(0));
    // A message longer than max is truncated to max and consumed (documented).
    try std.testing.expectEqual(mailbox.SendResult.ok, mailbox.send(0, "ping 77\n"));
    try std.testing.expectEqual(@as(u64, 4), dispatch(sys_ipc_recv, .{ @intFromPtr(&recv_buf), 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("ping", recv_buf[0..4]);
    try std.testing.expectEqual(@as(usize, 0), mailbox.pending(0));
    // EFAULT on a bad recv buffer: the message is NOT dropped (peek ->
    // copy_out -> drop ordering).
    try std.testing.expectEqual(mailbox.SendResult.ok, mailbox.send(0, "ping 9\n"));
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_ipc_recv, .{ uaccess.diagnostic_unmapped, mailbox.message_max, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 1), mailbox.pending(0));
    // The message is still there for a correct recv.
    try std.testing.expectEqual(@as(u64, 7), dispatch(sys_ipc_recv, .{ @intFromPtr(&recv_buf), mailbox.message_max, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("ping 9\n", recv_buf[0..7]);
    try std.testing.expectEqual(@as(usize, 0), mailbox.pending(0));
    const own = mailbox.info(0);
    try std.testing.expectEqual(@as(u64, 3), own.sent);
    try std.testing.expectEqual(@as(u64, 3), own.recv);
}

test "syscall: handle_svc decodes and dispatches slots 5 and 6 via the frame" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0
    scheduler.start();
    const send_bytes = "ping 5\n";
    var recv_buf: [mailbox.message_max]u8 = undefined;
    set_user_regions(
        .{ .base = @intFromPtr(send_bytes.ptr), .len = send_bytes.len },
        .{ .base = @intFromPtr(&recv_buf), .len = recv_buf.len },
    );
    // The marshaling seam (claim 3594): x8 carries the number, x0-x5 the
    // arguments, x0 receives the result — driven through handle_svc like
    // real EL0 SVC entries. These run from the EL1h shell: its zero TCB
    // regions do not trigger claim 0826's re-arm, so the mock windows armed
    // above stay in force (the re-arm only fires for a live user task, and
    // a host-test user task's fixed VAs are not mapped). Self-send to
    // process 0, then slot 6's seam on a non-process task.
    var frame = fresh_frame();
    try std.testing.expect(exceptions.frame_write(&frame, 8, sys_ipc_send));
    try std.testing.expect(exceptions.frame_write(&frame, 0, 0)); // target = self (pid 0)
    try std.testing.expect(exceptions.frame_write(&frame, 1, @intFromPtr(send_bytes.ptr)));
    try std.testing.expect(exceptions.frame_write(&frame, 2, send_bytes.len));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(@as(u64, send_bytes.len), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_ipc_send));
    try std.testing.expectEqual(@as(usize, 1), mailbox.pending(0));
    // Slot 6's seam: the recv handler resolves the CALLING task's process;
    // the EL1h shell is never a process, so the documented EINVAL result is
    // written back through the frame (the self-send round-trip itself is
    // covered at dispatch level above, and the full live path on VZ).
    try std.testing.expect(exceptions.frame_write(&frame, 8, sys_ipc_recv));
    try std.testing.expect(exceptions.frame_write(&frame, 0, @intFromPtr(&recv_buf)));
    try std.testing.expect(exceptions.frame_write(&frame, 1, mailbox.message_max));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(error_result(.einval), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_ipc_recv));
    // The failed recv never dropped the message.
    try std.testing.expectEqual(@as(usize, 1), mailbox.pending(0));
}

test "syscall: procs snapshot reflects live registry state and marshals fixed rows" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    var buf: [process.max_processes * process.snapshot_row_bytes]u8 = undefined;
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = @intFromPtr(&buf), .len = buf.len },
    );
    // The boot payload is process 0, RUNNING, named "user-el0".
    try std.testing.expectEqual(@as(u64, 1), dispatch(sys_procs, .{ @intFromPtr(&buf), buf.len, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, buf[0..8], .little)); // pid 0
    try std.testing.expectEqual(@as(u64, @intFromEnum(process.State.running)), std.mem.readInt(u64, buf[8..16], .little));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, buf[16..24], .little)); // no status while running
    try std.testing.expectEqualStrings("user-el0", buf[24 .. 24 + 8]);
    // The name field is NUL-padded to the full 16-byte slot.
    for (buf[24 + 8 .. 40]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    // Exit the payload: process 0 becomes exited with the status kept.
    try std.testing.expect(scheduler.yield_current()); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expectEqual(@as(u64, 1), dispatch(sys_procs, .{ @intFromPtr(&buf), buf.len, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, @intFromEnum(process.State.exited)), std.mem.readInt(u64, buf[8..16], .little));
    try std.testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, buf[16..24], .little)); // the snapshotted status
    // A created (loaded, not yet bound) process joins the snapshot: two
    // rows, in id order, with the free rows skipped.
    _ = process.create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    try std.testing.expectEqual(@as(u64, 2), dispatch(sys_procs, .{ @intFromPtr(&buf), buf.len, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, buf[0..8], .little));
    try std.testing.expectEqualStrings("user-el0", buf[24 .. 24 + 8]);
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, buf[40..48], .little)); // row 2's pid
    try std.testing.expectEqual(@as(u64, @intFromEnum(process.State.created)), std.mem.readInt(u64, buf[48..56], .little));
    try std.testing.expectEqualStrings("PEER.BIN", buf[64 .. 64 + 8]);
}

test "syscall: procs truncates to whole rows, clamps max, and EFAULTs on a bad buf" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // process 0
    scheduler.start();
    var frame = fresh_frame();
    var buf: [process.max_processes * process.snapshot_row_bytes]u8 = undefined;
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = @intFromPtr(&buf), .len = buf.len },
    );
    // max == 0 copies nothing (0 rows, even with a wild address).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_procs, .{ uaccess.diagnostic_unmapped, 0, 0, 0, 0, 0 }, &frame));
    // max below one whole row truncates to 0 rows (a partial row is never
    // copied — the documented truncation result).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_procs, .{ @intFromPtr(&buf), process.snapshot_row_bytes - 1, 0, 0, 0, 0 }, &frame));
    // max of exactly one row copies one row.
    try std.testing.expectEqual(@as(u64, 1), dispatch(sys_procs, .{ @intFromPtr(&buf), process.snapshot_row_bytes, 0, 0, 0, 0 }, &frame));
    // max larger than the full snapshot clamps to it.
    try std.testing.expectEqual(@as(u64, 1), dispatch(sys_procs, .{ @intFromPtr(&buf), 1_000_000, 0, 0, 0, 0 }, &frame));
    // A bad user pointer is EFAULT (the claim-6120 contract), never a
    // crash and never a partial write.
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_procs, .{ uaccess.diagnostic_unmapped, process.snapshot_row_bytes, 0, 0, 0, 0 }, &frame));
    // A read-only target (the user TEXT aperture) is EFAULT too — the
    // snapshot is a copy_out, so the caller's region must be writable.
    const text = "read-only";
    set_user_regions(
        .{ .base = @intFromPtr(text.ptr), .len = text.len },
        .{ .base = 0, .len = 0 },
    );
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_procs, .{ @intFromPtr(text.ptr), process.snapshot_row_bytes, 0, 0, 0, 0 }, &frame));
}

test "syscall: handle_svc decodes and dispatches slot 7 via the frame" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // process 0
    scheduler.start();
    var frame = fresh_frame();
    var buf: [process.snapshot_row_bytes]u8 = undefined;
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = @intFromPtr(&buf), .len = buf.len },
    );
    // The marshaling seam (claim 3594): x8 carries the number (7), x0 the
    // buf, x1 the max, x0 receives the row count.
    try std.testing.expect(exceptions.frame_write(&frame, 8, sys_procs));
    try std.testing.expect(exceptions.frame_write(&frame, 0, @intFromPtr(&buf)));
    try std.testing.expect(exceptions.frame_write(&frame, 1, buf.len));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(@as(u64, 1), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_procs));
    try std.testing.expectEqualStrings("user-el0", buf[24 .. 24 + 8]);
}

test "syscall: sys_net_stats marshals a whole snapshot and pins the layout" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // process 0
    scheduler.start();
    var frame = fresh_frame();

    // Pin the layout — the userland mirror (user/src/lib/netstats.zig)
    // must match every offset or this test fails loudly.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(NetStats, "mac"));
    try std.testing.expectEqual(@as(usize, 6), @offsetOf(NetStats, "own_ip"));
    try std.testing.expectEqual(@as(usize, 10), @offsetOf(NetStats, "gateway"));
    try std.testing.expectEqual(@as(usize, 14), @offsetOf(NetStats, "dhcp_state"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(NetStats, "lease_secs"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(NetStats, "tcp_state"));
    try std.testing.expectEqual(@as(usize, 33), @offsetOf(NetStats, "tcp_peer_ip"));
    try std.testing.expectEqual(@as(usize, 38), @offsetOf(NetStats, "tcp_peer_port"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(NetStats, "udp_count"));
    // The whole struct must stay well under the 512-byte scratch budget.
    try std.testing.expect(net_stats_bytes <= 256);

    // Mutate some state so the snapshot demonstrably carries it (restore
    // the previous values on the way out — host tests share globals).
    const saved_own_ip = arp.own_ip;
    const saved_peer_ip = tcp.peer_ip;
    const saved_peer_port = tcp.peer_port;
    defer arp.own_ip = saved_own_ip;
    defer tcp.peer_ip = saved_peer_ip;
    defer tcp.peer_port = saved_peer_port;
    arp.own_ip = .{ 10, 0, 0, 2 };
    tcp.peer_ip = .{ 10, 0, 0, 9 };
    tcp.peer_port = 8080;

    var buf: [net_stats_bytes]u8 = undefined;
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = @intFromPtr(&buf), .len = buf.len },
    );
    // Too-small buffer: honest truncation — 0 bytes, no copy.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_net_stats, .{ @intFromPtr(&buf), net_stats_bytes - 1, 0, 0, 0, 0 }, &frame));
    // Full snapshot: returns the byte count; the state round-trips.
    const rc = dispatch(sys_net_stats, .{ @intFromPtr(&buf), buf.len, 0, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, net_stats_bytes), rc);
    const snap: *align(1) const NetStats = @ptrCast(&buf);
    try std.testing.expectEqualSlices(u8, &arp.own_ip, &snap.own_ip); // the mutation round-trips
    try std.testing.expectEqual(@as(u16, 8080), snap.tcp_peer_port);
    try std.testing.expectEqualSlices(u8, &tcp.peer_ip, &snap.tcp_peer_ip);
    // A bad user pointer is EFAULT (nothing copied).
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_net_stats, .{ uaccess.diagnostic_unmapped, buf.len, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 3), call_count(sys_net_stats));
}

test "syscall: wait returns an already-exited target's status and refuses invalid/self/EL1h targets exactly" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const target_pid = process.create("TARGET.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const target_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(target_pid, target_task);
    scheduler.start();
    var frame = fresh_frame();
    // An EL1h task (the shell here) is never a process: EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wait, .{ target_pid, 0, 0, 0, 0, 0 }, &frame));
    // Out-of-range and free pids are EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wait, .{ process.max_processes, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wait, .{ 7, 0, 0, 0, 0, 0 }, &frame));
    // Drive to the boot payload (process 0, task 2): it may not wait on
    // itself (the deadlock the kernel refuses).
    try std.testing.expect(scheduler.yield_current()); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wait, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!scheduler.is_blocked(2));
    // Drive to the target and exit it with status 43.
    try std.testing.expect(scheduler.yield_current()); // user -> target
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_exit, .{ 43, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(scheduler.is_terminated(3));
    // Drive back to the caller: its wait on the now-exited target returns
    // the stored status IMMEDIATELY (no block — the already-exited path).
    try std.testing.expect(scheduler.yield_current()); // idle
    try std.testing.expect(scheduler.yield_current()); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 43), dispatch(sys_wait, .{ target_pid, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!scheduler.is_blocked(2));
    // The kernel's exit record agrees (process-level, survives the reap).
    try std.testing.expectEqual(process.State.exited, process.info(target_pid).?.state);
    try std.testing.expectEqual(@as(u64, 43), process.info(target_pid).?.exit_status);
}

test "syscall: wait blocks the caller and the target's exit wakes it with the status in its saved frame" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const target_pid = process.create("TARGET.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const target_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(target_pid, target_task);
    scheduler.start();
    // Drive to the caller (process 0, task 2).
    try std.testing.expect(scheduler.yield_current()); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    var frame = fresh_frame();
    // Stand in for the caller's SVC frame (the yield-test seam): the
    // adapter saves it, blocks the caller, and stages the target's task.
    var caller = fresh_frame();
    try std.testing.expect(exceptions.frame_write(&caller, 8, sys_wait));
    try std.testing.expect(exceptions.frame_write(&caller, 0, target_pid));
    exceptions.resume_frame[0] = @intFromPtr(&caller);
    try std.testing.expect(handle_svc(&caller, svc_immediate));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_wait));
    try std.testing.expect(scheduler.is_blocked(2));
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    // #2093: the placeholder is staged in the saved frame BEFORE the park
    // made it waker-visible — the exit-status patch below must be the
    // last write, and handle_svc's trailing write never runs on a parked
    // frame.
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(&caller, 0));
    // The target (task 3) exits with status 43: the exit path wakes the
    // waiter and patches the status into its SAVED frame's x0 — the value
    // the caller's sys_wait return will carry when the ring resumes it.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_exit, .{ 43, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!scheduler.is_blocked(2));
    try std.testing.expectEqual(@as(u64, 43), exceptions.frame_read(&caller, 0));
    try std.testing.expectEqual(process.State.exited, process.info(target_pid).?.state);
    try std.testing.expectEqual(@as(u64, 43), process.info(target_pid).?.exit_status);
    // The ring can reach the woken caller again (3 is a zombie, skipped).
    try std.testing.expect(scheduler.yield_current()); // idle
    try std.testing.expect(scheduler.yield_current()); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    // The process-level exit report carries the status (TARGET.BIN, 43).
    const r = process.take_exit_report().?;
    try std.testing.expectEqualStrings("TARGET.BIN", r.name);
    try std.testing.expectEqual(@as(u64, 43), r.status);
}

test "syscall: handle_svc decodes and dispatches slot 8 via the frame" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const target_pid = process.create("TARGET.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const target_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(target_pid, target_task);
    scheduler.start();
    // The marshaling seam (claim 3594): x8 carries the number (8), x0 the
    // target pid, x0 receives the status. Run from the EL1h shell: its
    // zero TCB regions mean the wait is refused exactly (EINVAL — the
    // shell is never a process), written back through the frame.
    var frame = fresh_frame();
    try std.testing.expect(exceptions.frame_write(&frame, 8, sys_wait));
    try std.testing.expect(exceptions.frame_write(&frame, 0, target_pid));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(error_result(.einval), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_wait));
}

test "syscall: udp listen — ok, duplicate, full, and port-zero refusal" {
    init(test_writer);
    virtio_net.udp.reset();
    defer virtio_net.udp.reset();
    var frame = fresh_frame();
    // Port 0 is never bindable (and > 65535 is refused): EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_listen, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_listen, .{ 0x10000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_udp_listen, .{ 7000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(virtio_net.udp.is_listening(7000));
    // Duplicate: EINVAL (the N5 layer's honest bool, mapped).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_listen, .{ 7000, 0, 0, 0, 0, 0 }, &frame));
    // Fill the 4-slot table: the fifth bind is EINVAL.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_udp_listen, .{ 7001, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_udp_listen, .{ 7002, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_udp_listen, .{ 7003, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_listen, .{ 7004, 0, 0, 0, 0, 0 }, &frame));
}

test "syscall: udp send/recv — loopback round trip through the handlers" {
    init(test_writer);
    virtio_net.udp.reset();
    defer virtio_net.udp.reset();
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    defer virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    virtio_net.net_ready = false; // the loopback path must NOT need a device
    const payload = "ping";
    var recv_buf: [udp.datagram_max]u8 = undefined;
    set_user_regions(
        .{ .base = @intFromPtr(payload.ptr), .len = payload.len },
        .{ .base = @intFromPtr(&recv_buf), .len = recv_buf.len },
    );
    var frame = fresh_frame();
    // Bind 7000 through the seam, then loopback-send to OUR OWN IP
    // (10.0.0.1 = 0x0a000001 in network byte order) with the payload.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_udp_listen, .{ 7000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, payload.len), dispatch(sys_udp_send, .{ 0x0a000001, 7000, @intFromPtr(payload.ptr), payload.len, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), virtio_net.udp.sent);
    try std.testing.expectEqual(@as(u64, 1), virtio_net.udp.loopbacked);
    try std.testing.expectEqual(@as(u64, 1), virtio_net.udp.received);
    // Recv the loopbacked datagram: the full 12-byte shape (src 7000,
    // dst 7000, len 12, checksum, payload) — the caller parses the header.
    try std.testing.expectEqual(@as(u64, 12), dispatch(sys_udp_recv, .{ 7000, @intFromPtr(&recv_buf), udp.datagram_max, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u16, 7000), (@as(u16, recv_buf[0]) << 8) | recv_buf[1]);
    try std.testing.expectEqual(@as(u16, 7000), (@as(u16, recv_buf[2]) << 8) | recv_buf[3]);
    try std.testing.expectEqual(@as(u16, 12), (@as(u16, recv_buf[4]) << 8) | recv_buf[5]);
    try std.testing.expectEqualSlices(u8, payload, recv_buf[8..12]);
    // The ring is now empty: recv returns 0 (not EINVAL — the port IS bound).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_udp_recv, .{ 7000, @intFromPtr(&recv_buf), udp.datagram_max, 0, 0, 0 }, &frame));
    // Recv on an UNBOUND port: EINVAL (distinct from the empty result).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_recv, .{ 9998, @intFromPtr(&recv_buf), udp.datagram_max, 0, 0, 0 }, &frame));
    // A bad recv buffer: EFAULT and the datagram stays QUEUED (peek ->
    // copy_out -> pop).
    try std.testing.expectEqual(@as(u64, 4), dispatch(sys_udp_send, .{ 0x0a000001, 7000, @intFromPtr(payload.ptr), payload.len, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_udp_recv, .{ 7000, uaccess.diagnostic_unmapped, udp.datagram_max, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 12), dispatch(sys_udp_recv, .{ 7000, @intFromPtr(&recv_buf), udp.datagram_max, 0, 0, 0 }, &frame));
    try std.testing.expectEqualSlices(u8, payload, recv_buf[8..12]);
}

test "syscall: udp send — EINVAL mapping, EFAULT, and the honest truncation" {
    init(test_writer);
    virtio_net.udp.reset();
    defer virtio_net.udp.reset();
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    defer virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
    defer virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
    var big: [100]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @intCast(i & 0xff);
    set_user_regions(
        .{ .base = @intFromPtr(&big), .len = big.len },
        .{ .base = 0, .len = 0 },
    );
    var frame = fresh_frame();
    // Port 0 is refused before anything is copied.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_send, .{ 0x0a000001, 0, @intFromPtr(&big), 4, 0, 0 }, &frame));
    // A bad payload pointer: EFAULT (the uaccess contract).
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_udp_send, .{ 0x0a000001, 7000, uaccess.diagnostic_unmapped, 4, 0, 0 }, &frame));
    // No static IP (0.0.0.0): the send is refused honestly (not_ready).
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_send, .{ 0x0a000001, 7000, @intFromPtr(&big), 4, 0, 0 }, &frame));
    // Transport down, IP set: a PEER send is not_ready -> EINVAL.
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    virtio_net.net_ready = false;
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_send, .{ 0x0a000002, 9999, @intFromPtr(&big), 4, 0, 0 }, &frame));
    // Transport up, peer NOT in the ARP table: .no_peer -> EINVAL (the
    // seam does not resolve ARP — `net arp <ip>` first, then retry).
    virtio_net.net_ready = true;
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_send, .{ 0x0a000002, 9999, @intFromPtr(&big), 4, 0, 0 }, &frame));
    virtio_net.net_ready = false;
    // len > 64 truncates honestly at payload_max (the ipc send shape) and
    // the send returns the WRITTEN length: 64. The loopbacked datagram is
    // 72 bytes with the first 64 payload bytes.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_udp_listen, .{ 7000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, udp.payload_max), dispatch(sys_udp_send, .{ 0x0a000001, 7000, @intFromPtr(&big), big.len, 0, 0 }, &frame));
    var recv_buf: [udp.datagram_max]u8 = undefined;
    set_user_regions(
        .{ .base = @intFromPtr(&big), .len = big.len },
        .{ .base = @intFromPtr(&recv_buf), .len = recv_buf.len },
    );
    try std.testing.expectEqual(@as(u64, udp.datagram_max), dispatch(sys_udp_recv, .{ 7000, @intFromPtr(&recv_buf), 100, 0, 0, 0 }, &frame));
    try std.testing.expectEqualSlices(u8, big[0..udp.payload_max], recv_buf[8..72]);
}

test "syscall: handle_svc decodes and dispatches slots 9/10/11 via the frame" {
    init(test_writer);
    virtio_net.udp.reset();
    defer virtio_net.udp.reset();
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    defer virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    const payload = "ping";
    var recv_buf: [udp.datagram_max]u8 = undefined;
    set_user_regions(
        .{ .base = @intFromPtr(payload.ptr), .len = payload.len },
        .{ .base = @intFromPtr(&recv_buf), .len = recv_buf.len },
    );
    // The marshaling seam (claim 3594): x8 carries the number, x0-x5 the
    // arguments, x0 receives the result — driven through handle_svc like
    // real EL0 SVC entries.
    var frame = fresh_frame();
    try std.testing.expect(exceptions.frame_write(&frame, 8, sys_udp_listen));
    try std.testing.expect(exceptions.frame_write(&frame, 0, 7000));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_udp_listen));
    try std.testing.expect(exceptions.frame_write(&frame, 8, sys_udp_send));
    try std.testing.expect(exceptions.frame_write(&frame, 0, 0x0a000001));
    try std.testing.expect(exceptions.frame_write(&frame, 1, 7000));
    try std.testing.expect(exceptions.frame_write(&frame, 2, @intFromPtr(payload.ptr)));
    try std.testing.expect(exceptions.frame_write(&frame, 3, payload.len));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(@as(u64, payload.len), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_udp_send));
    try std.testing.expect(exceptions.frame_write(&frame, 8, sys_udp_recv));
    try std.testing.expect(exceptions.frame_write(&frame, 0, 7000));
    try std.testing.expect(exceptions.frame_write(&frame, 1, @intFromPtr(&recv_buf)));
    try std.testing.expect(exceptions.frame_write(&frame, 2, udp.datagram_max));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(@as(u64, 12), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_udp_recv));
    try std.testing.expectEqualSlices(u8, payload, recv_buf[8..12]);
}

test "syscall: win open/fill/present/close round-trips with per-process ownership + auto-close" {
    init(test_writer);
    driving_award.arm();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const win_pid = process.create("WIN.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const win_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(win_pid, win_task);
    scheduler.start();
    var frame = fresh_frame();
    // Drive to the exec'd WIN.BIN (task 3).
    try std.testing.expect(scheduler.yield_current()); // shell -> user (boot payload, 2)
    try std.testing.expect(scheduler.yield_current()); // user -> WIN.BIN (3)
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    // Open window 2 as WIN.BIN: the caller's pid is recorded as the owner.
    try std.testing.expectEqual(@as(u64, 2), dispatch(sys_win_open, .{ 64, 64, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_win_open));
    try std.testing.expectEqual(@as(?usize, win_pid), driving_award.user_owner(2));
    // Fill + present the OWN window: both return 0.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_fill, .{ 2, 8, 8, 48, 48, 0xff0000 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_present, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_win_fill));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_win_present));
    // Move (slot 16) + raise (slot 17) the OWN window: both return 0.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_move, .{ 2, 600, 100, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_raise, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_win_move));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_win_raise));
    // Close the OWN window: slot 15 releases it (0 on success).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_close, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_win_close));
    try std.testing.expectEqual(@as(usize, 4), driving_award.count());
    // A second close of the freed id is EINVAL (no such user window).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_close, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    // Re-open (id 2 reused), then open the remaining slots (ids 3..9):
    // the full-registry ENOSPC split now holds at the 8-slot WM1 bound,
    // and the caller owns all eight.
    try std.testing.expectEqual(@as(u64, 2), dispatch(sys_win_open, .{ 64, 64, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 3), dispatch(sys_win_open, .{ 320, 64, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 4), dispatch(sys_win_open, .{ 576, 64, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 5), dispatch(sys_win_open, .{ 64, 288, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 6), dispatch(sys_win_open, .{ 576, 288, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 7), dispatch(sys_win_open, .{ 832, 64, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 8), dispatch(sys_win_open, .{ 832, 288, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 9), dispatch(sys_win_open, .{ 320, 288, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enospc), dispatch(sys_win_open, .{ 0, 0, 10, 10, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(?usize, win_pid), driving_award.user_owner(2));
    try std.testing.expectEqual(@as(?usize, win_pid), driving_award.user_owner(3));
    try std.testing.expectEqual(@as(?usize, win_pid), driving_award.user_owner(4));
    try std.testing.expectEqual(@as(?usize, win_pid), driving_award.user_owner(5));
    try std.testing.expectEqual(@as(?usize, win_pid), driving_award.user_owner(9));
    // Error mapping in the OWNING context: invalid geometry, out-of-bounds
    // rects, unknown ids, and the fixed windows are all EINVAL. WM1: the
    // 512×424 buffer cap is gone — 425-tall and 385-tall both fit the
    // scanout now, so with the full registry they map to ENOSPC (geometry
    // is no longer EINVAL); past-scanout sizes stay EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_open, .{ 0, 0, 0, 10, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enospc), dispatch(sys_win_open, .{ 0, 0, 10, 425, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enospc), dispatch(sys_win_open, .{ 0, 0, 10, 385, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_open, .{ 0, 0, 10, 721, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_fill, .{ 99, 0, 0, 10, 10, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_fill, .{ 2, 255, 191, 2, 2, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_present, .{ 99, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_present, .{ 1, 0, 0, 0, 0, 0 }, &frame)); // the clock is not a user window
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_move, .{ 99, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_raise, .{ 99, 0, 0, 0, 0, 0 }, &frame));
    // Drive to the boot payload (process 0, task 2): it does NOT own
    // WIN.BIN's windows, so fill/present/close are EINVAL.
    try std.testing.expect(scheduler.yield_current()); // WIN.BIN -> idle
    try std.testing.expect(scheduler.yield_current()); // idle -> shell
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_fill, .{ 2, 0, 0, 10, 10, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_present, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_close, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_move, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_raise, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    // AUTO-CLOSE on exit: drive back to WIN.BIN (task 3) and exit it —
    // all eight of its windows (ids 2..9) are released with NO sys_win_close
    // call.
    try std.testing.expect(scheduler.yield_current()); // user -> WIN.BIN (3)
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_exit, .{ 87, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(driving_award.user_owner(2) == null);
    try std.testing.expect(driving_award.user_owner(3) == null);
    try std.testing.expect(driving_award.user_owner(4) == null);
    try std.testing.expect(driving_award.user_owner(5) == null);
    try std.testing.expectEqual(@as(usize, 4), driving_award.count());
    // The close counter only ever saw the THREE explicit dispatches (one
    // success + the two refusals above): the exit-path teardown is NOT a
    // syscall (it rides close_owner, never handle_win_close).
    try std.testing.expectEqual(@as(u64, 3), call_count(sys_win_close));
}

test "syscall: win open maps pool exhaustion to ENOMEM (WM1, claim 919)" {
    init(test_writer);
    driving_award.arm();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const win_pid = process.create("WIN.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const win_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(win_pid, win_task);
    scheduler.start();
    var frame = fresh_frame();
    // Drive to the exec'd WIN.BIN (task 3).
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expect(scheduler.yield_current()); // user -> WIN.BIN (3)
    // Shrink the pool to a single page: a 256×192 window needs 12.
    var desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 1, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&desc), @sizeOf(memmap.MemoryDescriptor), desc.len);
    _ = alloc.init(view, &.{});
    // Geometry fits the scanout, slots are free — the failure is the pool.
    try std.testing.expectEqual(error_result(.enomem), dispatch(sys_win_open, .{ 64, 64, 256, 192, 0, 0 }, &frame));
}

test "syscall: win get copies the clamped rect back through uaccess and enforces ownership" {
    init(test_writer);
    driving_award.arm();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const win_pid = process.create("WIN.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const win_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(win_pid, win_task);
    scheduler.start();
    var frame = fresh_frame();
    var rect_buf: [win_rect_bytes]u8 = undefined;
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = @intFromPtr(&rect_buf), .len = rect_buf.len },
    );
    // Drive to WIN.BIN (task 3).
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expect(scheduler.yield_current()); // user -> WIN.BIN (3)
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 2), dispatch(sys_win_open, .{ 64, 64, 256, 192, 0, 0 }, &frame));
    // Read back the open rect (four u32 LE words).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_get, .{ 2, @intFromPtr(&rect_buf), 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u32, 64), std.mem.readInt(u32, rect_buf[0..4], .little));
    try std.testing.expectEqual(@as(u32, 64), std.mem.readInt(u32, rect_buf[4..8], .little));
    try std.testing.expectEqual(@as(u32, 256), std.mem.readInt(u32, rect_buf[8..12], .little));
    try std.testing.expectEqual(@as(u32, 192), std.mem.readInt(u32, rect_buf[12..16], .little));
    // After a CLAMPED move the read-back reports the CLAMPED position (the
    // gate constants: 1280x720 scanout, 256-wide window -> 1024,528).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_move, .{ 2, 1200, 700, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_get, .{ 2, @intFromPtr(&rect_buf), 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u32, 1024), std.mem.readInt(u32, rect_buf[0..4], .little));
    try std.testing.expectEqual(@as(u32, 528), std.mem.readInt(u32, rect_buf[4..8], .little));
    try std.testing.expectEqual(@as(u32, 256), std.mem.readInt(u32, rect_buf[8..12], .little));
    try std.testing.expectEqual(@as(u32, 192), std.mem.readInt(u32, rect_buf[12..16], .little));
    // A bad buf is EFAULT (the claim-6120 contract), never a crash.
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_win_get, .{ 2, uaccess.diagnostic_unmapped, 0, 0, 0, 0 }, &frame));
    // Unknown + fixed ids are EINVAL (never a user window).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_get, .{ 99, @intFromPtr(&rect_buf), 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_get, .{ 1, @intFromPtr(&rect_buf), 0, 0, 0, 0 }, &frame));
    // Drive to the boot payload (process 0, task 2): it does NOT own
    // WIN.BIN's window, so win_get is EINVAL.
    try std.testing.expect(scheduler.yield_current()); // WIN.BIN -> idle
    try std.testing.expect(scheduler.yield_current()); // idle -> shell
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_get, .{ 2, @intFromPtr(&rect_buf), 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 6), call_count(sys_win_get));
}

test "syscall: win query copies the full window state back and enforces ownership" {
    init(test_writer);
    driving_award.arm();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const win_pid = process.create("WIN.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const win_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(win_pid, win_task);
    scheduler.start();
    var frame = fresh_frame();
    var qbuf: [win_query_bytes]u8 = undefined;
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = @intFromPtr(&qbuf), .len = qbuf.len },
    );
    // Drive to WIN.BIN (task 3).
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expect(scheduler.yield_current()); // user -> WIN.BIN (3)
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 2), dispatch(sys_win_open, .{ 64, 64, 256, 192, 0, 0 }, &frame));
    // The full state right after open: top of the z-order (index 4 with dock, after tray migration 4 base +1), focused,
    // visible, dirty (the compositor never runs in a host test).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_query, .{ 2, @intFromPtr(&qbuf), 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u32, 64), std.mem.readInt(u32, qbuf[0..4], .little));
    try std.testing.expectEqual(@as(u32, 64), std.mem.readInt(u32, qbuf[4..8], .little));
    try std.testing.expectEqual(@as(u32, 256), std.mem.readInt(u32, qbuf[8..12], .little));
    try std.testing.expectEqual(@as(u32, 192), std.mem.readInt(u32, qbuf[12..16], .little));
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, qbuf[16..20], .little)); // z
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, qbuf[20..24], .little)); // focused
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, qbuf[24..28], .little)); // visible
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, qbuf[28..32], .little)); // dirty
    // A bad buf is EFAULT, never a crash.
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_win_query, .{ 2, uaccess.diagnostic_unmapped, 0, 0, 0, 0 }, &frame));
    // Unknown + fixed ids are EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_query, .{ 99, @intFromPtr(&qbuf), 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_query, .{ 1, @intFromPtr(&qbuf), 0, 0, 0, 0 }, &frame));
    // Drive to the boot payload (process 0, task 2): it does NOT own
    // WIN.BIN's window, so win_query is EINVAL.
    try std.testing.expect(scheduler.yield_current()); // WIN.BIN -> idle
    try std.testing.expect(scheduler.yield_current()); // idle -> shell
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_query, .{ 2, @intFromPtr(&qbuf), 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 5), call_count(sys_win_query));
}

test "syscall: win set_visible hides/shows the caller's window and enforces ownership" {
    init(test_writer);
    driving_award.arm();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const win_pid = process.create("WIN.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const win_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(win_pid, win_task);
    scheduler.start();
    var frame = fresh_frame();
    // Drive to WIN.BIN (task 3).
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expect(scheduler.yield_current()); // user -> WIN.BIN (3)
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 2), dispatch(sys_win_open, .{ 64, 64, 256, 192, 0, 0 }, &frame));
    // Hide the OWN window: 0 on success, visible flips to 0.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_set_visible, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u32, 0), driving_award.user_query(2).?.visible);
    // Show it again: 0 on success, visible flips back to 1.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_set_visible, .{ 2, 1, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u32, 1), driving_award.user_query(2).?.visible);
    // A visible flag outside 0/1 is EINVAL (no ambiguity).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_set_visible, .{ 2, 2, 0, 0, 0, 0 }, &frame));
    // Unknown + fixed ids are EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_set_visible, .{ 99, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_set_visible, .{ 1, 0, 0, 0, 0, 0 }, &frame));
    // Drive to the boot payload (process 0, task 2): it does NOT own
    // WIN.BIN's window, so set_visible is EINVAL.
    try std.testing.expect(scheduler.yield_current()); // WIN.BIN -> idle
    try std.testing.expect(scheduler.yield_current()); // idle -> shell
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_set_visible, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 6), call_count(sys_win_set_visible));
}

test "syscall: counters are monotonic and report is deterministic" {
    userspace.init();
    init(test_writer);
    var frame = fresh_frame();
    _ = dispatch(sys_ping, .{ 9, 0, 0, 0, 0, 0 }, &frame);
    _ = dispatch(sys_ping, .{ 10, 0, 0, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, 2), call_count(sys_ping));
    var mock = console.MockConsole(4096){};
    var con = mock.console();
    report(&con);
    try std.testing.expectEqualStrings(
        "syscalls: slots=64 implemented=84\n" ++
            "  0 sys_ping calls=2\n" ++
            "  1 sys_write calls=0\n" ++
            "  2 sys_yield calls=0\n" ++
            "  3 sys_exit calls=0\n" ++
            "  4 sys_sleep calls=0\n" ++
            "  5 sys_ipc_send calls=0\n" ++
            "  6 sys_ipc_recv calls=0\n" ++
            "  7 sys_procs calls=0\n" ++
            "  8 sys_wait calls=0\n" ++
            "  9 sys_udp_listen calls=0\n" ++
            "  10 sys_udp_send calls=0\n" ++
            "  11 sys_udp_recv calls=0\n" ++
            "  12 sys_win_open calls=0\n" ++
            "  13 sys_win_fill calls=0\n" ++
            "  14 sys_win_present calls=0\n" ++
            "  15 sys_win_close calls=0\n" ++
            "  16 sys_win_move calls=0\n" ++
            "  17 sys_win_raise calls=0\n" ++
            "  18 sys_win_get calls=0\n" ++
            "  19 sys_win_query calls=0\n" ++
            "  20 sys_win_set_visible calls=0\n" ++
            "  21 sys_poll_event calls=0\n" ++
            "  22 sys_wait_event calls=0\n" ++
            "  23 sys_file_open calls=0\n" ++
            "  24 sys_file_read calls=0\n" ++
            "  25 sys_file_write calls=0\n" ++
            "  26 sys_file_close calls=0\n" ++
            "  27 sys_dir_list calls=0\n" ++
            "  28 sys_exec calls=0\n" ++
            "  29 sys_kill calls=0\n" ++
            "  30 sys_tcp_connect calls=0\n" ++
            "  31 sys_tcp_send calls=0\n" ++
            "  32 sys_tcp_recv calls=0\n" ++
            "  33 sys_tcp_close calls=0\n" ++
            "  34 sys_file_delete calls=0\n" ++
            "  35 sys_file_rename calls=0\n" ++
            "  36 sys_file_truncate calls=0\n" ++
            "  37 sys_file_free calls=0\n" ++
            "  38 sys_clipboard_set calls=0\n" ++
            "  39 sys_clipboard_get calls=0\n" ++
            "  40 sys_timer_set calls=0\n" ++
            "  41 sys_timer_cancel calls=0\n" ++
            "  42 sys_audio_info calls=0\n" ++
            "  43 sys_audio_play calls=0\n" ++
            "  44 sys_audio_volume calls=0\n" ++
            "  45 sys_audio_mute calls=0\n" ++
            "  46 sys_win_fill_batch calls=0\n" ++
            "  47 sys_win_resize calls=0\n" ++
            "  48 sys_drag_start calls=0\n" ++
            "  49 sys_win_raise_front calls=0\n" ++
            "  50 sys_win_lower_back calls=0\n" ++
            "  51 sys_notify calls=0\n" ++
            "  52 sys_win_move_to_workspace calls=0\n" ++
            "  53 sys_win_set_unsaved calls=0\n" ++
            "  54 sys_setrlimit calls=0\n" ++
            "  55 sys_drag_read calls=0\n" ++
            "  56 sys_pipe_read calls=0\n" ++
            "  57 sys_pipe_write calls=0\n" ++
            "  58 sys_font_size calls=0\n" ++
            "  59 sys_ping_send calls=0\n" ++
            "  60 sys_ping_poll calls=0\n" ++
            "  61 sys_win_set_title calls=0\n" ++
            "  62 sys_net_stats calls=0\n" ++
            "  63 sys_mmap calls=0\n" ++
            "  64 sys_munmap calls=0\n" ++
            "  65 sys_wmctl calls=0\n" ++
            "  66 sys_time calls=0\n" ++
            "  67 sys_tty_attach calls=0\n" ++
            "  68 sys_principal calls=0\n" ++
            "  69 sys_file_mode calls=0\n" ++
            "  70 sys_secret_get calls=0\n" ++
            "  71 sys_tty_net_auth calls=0\n" ++
            "  72 sys_getrandom calls=0\n" ++
            "  73 sys_thread calls=0\n" ++
            "  74 sys_futex calls=0\n" ++
            "  75 sys_exnotify calls=0\n" ++
            "  76 sys_sock_ready calls=0\n" ++
            "  77 sys_file_sync calls=0\n" ++
            "  78 sys_time_set calls=0\n" ++
            "  79 sys_fs_metadata calls=0\n" ++
            "  80 sys_socket calls=0\n" ++
            "  81 sys_trace calls=0\n" ++
            "  82 sys_profile calls=0\n" ++
            "  83 sys_memstat calls=0\n",
        mock.contents(),
    );
}

test "syscall: file storage slots 23..27 dispatch and fault safety" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    file_table.init();
    var frame = fresh_frame();

    // In task 0 (shell, not a registered process), calls return EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_open, .{ 0x1000, 10, file_table.MODE_READ, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_read, .{ 0, 0x1000, 10, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_write, .{ 0, 0x1000, 10, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_close, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_dir_list, .{ 0x1000, 0, 0x2000, 10, 0, 0 }, &frame));

    // Yield to user task (task 2, pid 0)
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    var test_buf: [64]u8 = undefined;
    const test_buf_addr = @intFromPtr(&test_buf);
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = test_buf_addr, .len = test_buf.len },
    );

    // Bad user pointer on path / buffer -> EFAULT
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_file_open, .{ uaccess.diagnostic_unmapped, 8, file_table.MODE_READ, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_dir_list, .{ uaccess.diagnostic_unmapped, 5, test_buf_addr, 1, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_file_write, .{ 0, uaccess.diagnostic_unmapped, 10, 0, 0, 0 }, &frame));

    // Bad / unallocated file descriptors -> EBADF
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_file_read, .{ 0, test_buf_addr, 10, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_file_read, .{ 99, test_buf_addr, 10, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_file_write, .{ 0, test_buf_addr, 10, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_file_write, .{ 99, test_buf_addr, 10, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_file_close, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_file_close, .{ 99, 0, 0, 0, 0, 0 }, &frame));
}

test "syscall: mutating file slots 34..37 dispatch and fault safety (claim 5801)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    file_table.init();
    var frame = fresh_frame();

    // In task 0 (shell, not a registered process), calls return EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_delete, .{ 0x1000, 8, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_rename, .{ 0x1000, 4, 0x1000, 4, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_truncate, .{ 0, 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_free, .{ 0, 0, 0, 0, 0, 0 }, &frame));

    // Yield to user task (task 2, pid 0)
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    var test_buf: [64]u8 = undefined;
    const test_buf_addr = @intFromPtr(&test_buf);
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = test_buf_addr, .len = test_buf.len },
    );

    // Bad user pointer -> EFAULT (delete + rename path copy-in)
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_file_delete, .{ uaccess.diagnostic_unmapped, 8, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_file_rename, .{ uaccess.diagnostic_unmapped, 4, test_buf_addr, 4, 0, 0 }, &frame));
    // Over-long path -> EINVAL (checked before uaccess)
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_delete, .{ 0x1000, file_table.max_path_len + 1, 0, 0, 0, 0 }, &frame));
    // truncate on an unallocated fd -> EBADF
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_file_truncate, .{ 0, 4, 0, 0, 0, 0 }, &frame));
    // free with a bad volume -> EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_free, .{ 2, 0, 0, 0, 0, 0 }, &frame));
}

test "B2: slot 27 versioned marshaling, fault retry, EOF and legacy compatibility" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    file_table.init();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current());
    const dir = file_table.directory;
    var files: [40]syscall.virtio_file.TestFile = undefined;
    var names: [40][16]u8 = undefined;
    for (&files, 0..) |*f, i| f.* = .{
        .name = try std.fmt.bufPrint(&names[i], "entry-{d:0>2}", .{i}),
        .data = "payload",
    };
    syscall.virtio_file.set_test_share(&files);
    defer syscall.virtio_file.set_test_share(null);
    var storage: extern struct {
        path: [512]u8,
        page: dir.Page,
        legacy: [16]file_table.DirEntry,
    } = undefined;
    @memcpy(storage.path[0..5], "/host");
    const addr = @intFromPtr(&storage);
    const path_addr = @intFromPtr(&storage.path);
    const page_addr = @intFromPtr(&storage.page);
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = addr, .len = @sizeOf(@TypeOf(storage)) });
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_dir_list, .{ uaccess.diagnostic_unmapped, 5, 0, dir.open_op, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enametoolong), dispatch(sys_dir_list, .{ path_addr, 513, 0, dir.open_op, 0, 0 }, &frame));
    const token = dispatch(sys_dir_list, .{ path_addr, 5, 0, dir.open_op, 0, 0 }, &frame);
    try std.testing.expect(@as(i64, @bitCast(token)) > 0);
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_dir_list, .{ token, 0, uaccess.diagnostic_unmapped, dir.page_op, 16, 0 }, &frame));
    // The failed copy must not consume a page.
    try std.testing.expectEqual(@as(u64, 16), dispatch(sys_dir_list, .{ token, 0, page_addr, dir.page_op, 16, 0 }, &frame));
    try std.testing.expectEqualStrings("entry-00", storage.page.entries[0].name[0..8]);
    try std.testing.expectEqual(@as(u64, 16), storage.page.header.next);
    try std.testing.expectEqual(@as(u32, 0), storage.page.header.end);
    try std.testing.expectEqual(@as(u64, 16), dispatch(sys_dir_list, .{ token, 16, page_addr, dir.page_op, 16, 0 }, &frame));
    try std.testing.expectEqualStrings("entry-16", storage.page.entries[0].name[0..8]);
    try std.testing.expectEqual(@as(u64, 8), dispatch(sys_dir_list, .{ token, 32, page_addr, dir.page_op, 16, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 40), storage.page.header.next);
    try std.testing.expectEqual(@as(u32, 1), storage.page.header.end);
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_dir_list, .{ token, 40, page_addr, dir.page_op, 16, 0 }, &frame));
    try std.testing.expectEqual(@as(u32, 1), storage.page.header.end);
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_dir_list, .{ token, 0, page_addr, dir.page_op, 17, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_dir_list, .{ token, 0, page_addr, dir.version | 4, 16, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_dir_list, .{ token, 0, 0, dir.close_op, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_dir_list, .{ token, 0, page_addr, dir.page_op, 16, 0 }, &frame));
    // Legacy callers keep 40-byte rows, ignore x4/x5 and retain their clamp.
    try std.testing.expectEqual(@as(u64, 16), dispatch(sys_dir_list, .{ path_addr, 5, @intFromPtr(&storage.legacy), 40, dir.version, 999 }, &frame));
    try std.testing.expectEqualStrings("entry-00", storage.legacy[0].name[0..8]);
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(file_table.DirEntry));
}

fn start_metadata_case(frame: *exceptions.VectorFrame, base: usize, len: usize) void {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    file_table.init();
    syscall.trust.init();
    frame.* = fresh_frame();
    std.debug.assert(scheduler.yield_current());
    B3Case.Server.start();
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = base, .len = len });
}

const B3Case = struct {
    const meta = file_table.metadata;
    const Server = syscall.virtio_file.virtio_fs.TestMetadataServer;
    storage: extern struct {
        root: [512]u8,
        relative: [506]u8,
        value: meta.Wire,
        page: meta.Page,
        data: [8]u8,
    } = undefined,
    frame: exceptions.VectorFrame = undefined,

    fn start(self: *B3Case) void {
        start_metadata_case(&self.frame, @intFromPtr(&self.storage), @sizeOf(@TypeOf(self.storage)));
    }

    fn stop(_: *B3Case) void {
        file_table.init();
        Server.stop();
        syscall.trust.init();
    }

    fn call(self: *B3Case, op: u64, root: []const u8, path: []const u8) i64 {
        @memcpy(self.storage.root[0..root.len], root);
        @memcpy(self.storage.relative[0..path.len], path);
        return @bitCast(dispatch(79, .{
            op,                                  @intFromPtr(&self.storage.root), root.len,
            @intFromPtr(&self.storage.relative), path.len,                        if (op <= meta.identity_op) @intFromPtr(&self.storage.value) else 0,
        }, &self.frame));
    }

    fn page(self: *B3Case, token: u64, offset: u64, limit: u64, address: u64) i64 {
        return @bitCast(dispatch(79, .{ meta.dir_page_op, token, offset, limit, address, 0 }, &self.frame));
    }
};

test "B3 EL0: nested stable identities honest rich rows and indexed fault retry" {
    var c: B3Case = .{};
    c.start();
    defer c.stop();
    const meta = file_table.metadata;
    var ids: [3]meta.Identity = undefined;
    for ([_][]const u8{ "", "a", "a/b" }, 0..) |path, i| {
        try std.testing.expectEqual(@as(i64, 0), c.call(meta.stat_op, "/host/content", path));
        ids[i] = c.storage.value.identity;
        try std.testing.expectEqual(meta.Kind.directory, c.storage.value.kind);
        try std.testing.expectEqual(@as(u64, 4096), c.storage.value.size);
        try std.testing.expectEqual(@as(u32, 501), c.storage.value.host_uid);
        try std.testing.expectEqual(@as(u32, 123), c.storage.value.mtime.nanoseconds);
        try std.testing.expectEqual(@as(i64, 0), c.call(meta.identity_op, "/host/content", path));
        const queried: *const meta.Identity = @ptrCast(&c.storage.value);
        try std.testing.expect(ids[i].eql(queried.*));
        for (ids[0..i]) |prior| try std.testing.expect(!prior.eql(ids[i]));
    }
    const token = c.call(meta.dir_open_op, "/host/content", "");
    try std.testing.expect(token > 0);
    try std.testing.expectEqual(@as(i64, -3), c.page(@intCast(token), 0, 1, uaccess.diagnostic_unmapped));
    try std.testing.expectEqual(@as(i64, 1), c.page(@intCast(token), 0, 1, @intFromPtr(&c.storage.page)));
    try std.testing.expectEqualStrings("a", c.storage.page.entries[0].name[0..1]);
    try std.testing.expect(ids[1].eql(c.storage.page.entries[0].metadata.identity));
    try std.testing.expectEqual(@as(u32, 1), c.storage.page.header.end);
    try std.testing.expectEqual(@as(i64, 0), c.page(@intCast(token), 1, 1, @intFromPtr(&c.storage.page)));
    try std.testing.expectEqual(@as(i64, -2), file_table.metadata_dir_page(1, @intCast(token), 0, 1, &c.storage.page));
    try std.testing.expectEqual(@as(u64, 0), dispatch(79, .{ meta.dir_close_op, @intCast(token), 0, 0, 0, 0 }, &c.frame));
    try std.testing.expectEqual(@as(i64, -2), c.page(@intCast(token), 0, 1, @intFromPtr(&c.storage.page)));
    try std.testing.expectEqual(@as(usize, 0), B3Case.Server.transient_pins());
}

test "B3 EL0: fresh watch stamps pinned reads and writes survive leaf replacement" {
    var c: B3Case = .{};
    c.start();
    defer c.stop();
    const meta = file_table.metadata;
    try std.testing.expectEqual(@as(i64, 0), c.call(meta.stat_op, "/host/content", "a/b/page.md"));
    const old = c.storage.value;
    B3Case.Server.mtime += 1;
    try std.testing.expectEqual(@as(i64, 0), c.call(meta.stat_op, "/host/content", "a/b/page.md"));
    try std.testing.expect(c.storage.value.mtime.seconds != old.mtime.seconds);
    B3Case.Server.mtime = @intCast(old.mtime.seconds);
    B3Case.Server.size += 1;
    try std.testing.expectEqual(@as(i64, 0), c.call(meta.stat_op, "/host/content", "a/b/page.md"));
    try std.testing.expect(c.storage.value.size != old.size);
    B3Case.Server.swap_leaf = true;
    const fd = c.call(meta.read_open_op, "/host/content", "a/b/page.md");
    try std.testing.expect(fd >= 0);
    try std.testing.expectEqual(error_result(.efault), dispatch(24, .{ @intCast(fd), uaccess.diagnostic_unmapped, 4, 0, 0, 0 }, &c.frame));
    try std.testing.expectEqual(@as(u64, 4), dispatch(24, .{ @intCast(fd), @intFromPtr(&c.storage.data), 4, 0, 0, 0 }, &c.frame));
    try std.testing.expectEqualStrings("safe", c.storage.data[0..4]);
    try std.testing.expectEqual(@as(i64, -7), c.call(meta.stat_op, "/host/content", "a/b/page.md"));
    try std.testing.expectEqual(@as(u64, 0), dispatch(26, .{ @intCast(fd), 0, 0, 0, 0, 0 }, &c.frame));
    B3Case.Server.start();
    B3Case.Server.swap_leaf = true;
    const writer = c.call(meta.write_open_op, "/host/content", "a/b/page.md");
    try std.testing.expect(writer >= 0);
    @memcpy(c.storage.data[0..4], "edit");
    try std.testing.expectEqual(@as(u64, 4), dispatch(25, .{ @intCast(writer), @intFromPtr(&c.storage.data), 4, 0, 0, 0 }, &c.frame));
    try std.testing.expectEqual(@as(i64, -7), c.call(meta.read_open_op, "/host/content", "a/b/page.md"));
    try std.testing.expectEqual(@as(u64, 0), dispatch(26, .{ @intCast(writer), 0, 0, 0, 0, 0 }, &c.frame));
    try std.testing.expectEqual(@as(usize, 0), B3Case.Server.transient_pins());
}

test "B3 EL0: all no-follow shortcuts and malformed metadata refuse without output" {
    var c: B3Case = .{};
    c.start();
    defer c.stop();
    const meta = file_table.metadata;
    for ([_]u64{ 2, 3, 4, 5 }) |node| {
        B3Case.Server.symlink_node = node;
        for ([_]u64{ meta.stat_op, meta.identity_op, meta.read_open_op, meta.write_open_op }) |op|
            try std.testing.expectEqual(@as(i64, -7), c.call(op, "/host/content", "a/b/page.md"));
    }
    B3Case.Server.symlink_node = 6;
    B3Case.Server.include_link = true;
    try std.testing.expectEqual(@as(i64, -7), c.call(meta.dir_open_op, "/host/content", ""));
    B3Case.Server.include_link = false;
    @memset(std.mem.asBytes(&c.storage.value), 0xa5);
    const unchanged = c.storage.value;
    B3Case.Server.short_attr = true;
    try std.testing.expectEqual(@as(i64, -1), c.call(meta.stat_op, "/host/content", ""));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&unchanged), std.mem.asBytes(&c.storage.value));
    B3Case.Server.short_attr = false;
    B3Case.Server.zero_inode = true;
    try std.testing.expectEqual(@as(i64, -1), c.call(meta.stat_op, "/host/content", ""));
    B3Case.Server.zero_inode = false;
    for ([_]struct { wire: i32, native: i64 }{
        .{ .wire = -2, .native = -6 },
        .{ .wire = -13, .native = -7 },
        .{ .wire = -38, .native = -4 },
        .{ .wire = -5, .native = -1 },
        .{ .wire = -116, .native = -2 },
    }) |case| {
        B3Case.Server.fail_opcode = 3;
        B3Case.Server.fail_errno = case.wire;
        try std.testing.expectEqual(case.native, c.call(meta.stat_op, "/host/content", ""));
    }
    B3Case.Server.fail_opcode = 0;
    for ([_][]const u8{ "../escape", "a//b", "a/./b", "a\x00b" }) |path|
        try std.testing.expectEqual(@as(i64, -1), c.call(meta.stat_op, "/host/content", path));
    try std.testing.expectEqual(@as(i64, -4), c.call(meta.stat_op, "/usb", ""));
    try std.testing.expectEqual(@as(usize, 0), B3Case.Server.transient_pins());
    B3Case.Server.stop();
    try std.testing.expectEqual(@as(i64, -4), c.call(meta.stat_op, "/host/content", ""));
    try std.testing.expectEqual(@as(i64, -4), c.call(meta.read_open_op, "/host/content", "a/b/page.md"));
    try std.testing.expectEqual(@as(i64, -4), c.call(meta.dir_open_op, "/host/content", ""));
}

test "B3 EL0: principal policy applies before lookup and after handle or page revocation" {
    var c: B3Case = .{};
    c.start();
    defer c.stop();
    const meta = file_table.metadata;
    const fd = c.call(meta.read_open_op, "/host/content", "a/b/page.md");
    const cursor = c.call(meta.dir_open_op, "/host/content", "");
    try std.testing.expect(fd >= 0 and cursor > 0);
    _ = syscall.trust.load("#v1\ncontent/a\t600\t0\t-\n");
    const lookups = B3Case.Server.lookup_count;
    try std.testing.expectEqual(@as(i64, -7), c.call(meta.stat_op, "/host/content/a", "b/page.md"));
    try std.testing.expectEqual(lookups, B3Case.Server.lookup_count);
    try std.testing.expectEqual(@as(i64, -7), c.page(@intCast(cursor), 0, 1, @intFromPtr(&c.storage.page)));
    try std.testing.expectEqual(error_result(.eacces), dispatch(24, .{ @intCast(fd), @intFromPtr(&c.storage.data), 4, 0, 0, 0 }, &c.frame));
    syscall.trust.init();
    _ = syscall.trust.load("#v1\ncontent/a/b/page.md\t600\t0\tsecret\n");
    try std.testing.expectEqual(@as(i64, -7), c.call(meta.identity_op, "/host/content", "a/b/page.md"));
    try std.testing.expectEqual(@as(i64, -7), c.call(meta.read_open_op, "/host/content", "a/b/page.md"));
    try std.testing.expectEqual(@as(u64, 0), dispatch(26, .{ @intCast(fd), 0, 0, 0, 0, 0 }, &c.frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(79, .{ meta.dir_close_op, @intCast(cursor), 0, 0, 0, 0 }, &c.frame));
}

test "B3 EL0: malformed calls fault bounds and backend failures never consume resources or EOF" {
    var c: B3Case = .{};
    c.start();
    defer c.stop();
    const meta = file_table.metadata;
    const bad = uaccess.diagnostic_unmapped;
    const r = @intFromPtr(&c.storage.root);
    const p = @intFromPtr(&c.storage.relative);
    try std.testing.expectEqual(@as(i64, 0), c.call(meta.stat_op, "/host/content", ""));
    for ([_]Args{
        .{ 0, bad, 13, p, 0, @intFromPtr(&c.storage.value) },
        .{ 0, r, 13, bad, 1, @intFromPtr(&c.storage.value) },
        .{ 0, r, 13, p, 0, bad },
        .{ 1, r, 13, p, 0, bad },
    }) |args| try std.testing.expectEqual(error_result(.efault), dispatch(79, args, &c.frame));
    try std.testing.expectEqual(error_result(.enametoolong), dispatch(79, .{ 0, r, 513, p, 0, 0 }, &c.frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(79, .{ 99, 0, 0, 0, 0, 0 }, &c.frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(79, .{ 2, r, 13, p, 0, 1 }, &c.frame));
    const fd = c.call(meta.read_open_op, "/host/content", "a/b/page.md");
    try std.testing.expect(fd >= 0);
    B3Case.Server.fail_opcode = 15; // FUSE_READ
    B3Case.Server.fail_errno = -5;
    try std.testing.expectEqual(error_result(.einval), dispatch(24, .{ @intCast(fd), @intFromPtr(&c.storage.data), 4, 0, 0, 0 }, &c.frame));
    B3Case.Server.fail_opcode = 18; // FUSE_RELEASE
    try std.testing.expectEqual(error_result(.einval), dispatch(26, .{ @intCast(fd), 0, 0, 0, 0, 0 }, &c.frame));
    B3Case.Server.fail_opcode = 0;
    try std.testing.expectEqual(@as(u64, 4), dispatch(24, .{ @intCast(fd), @intFromPtr(&c.storage.data), 4, 0, 0, 0 }, &c.frame));
    try std.testing.expectEqualStrings("safe", c.storage.data[0..4]);
    try std.testing.expectEqual(@as(u64, 0), dispatch(26, .{ @intCast(fd), 0, 0, 0, 0, 0 }, &c.frame));
    try std.testing.expectEqual(@as(usize, 0), B3Case.Server.transient_pins());
}

const B5Case = struct {
    const meta = file_table.metadata;
    const Server = B3Case.Server;
    const root = "/host/content";
    storage: extern struct {
        root: [512]u8,
        relative: [506]u8,
        from: [256]u8,
        to: [256]u8,
        value: meta.Wire,
        data: [8]u8,
    } = undefined,
    frame: exceptions.VectorFrame = undefined,

    fn start(self: *B5Case) void {
        start_metadata_case(&self.frame, @intFromPtr(&self.storage), @sizeOf(@TypeOf(self.storage)));
    }

    fn stop(_: *B5Case) void {
        file_table.init();
        Server.stop();
        syscall.trust.init();
    }

    fn pid() u64 {
        return process.find_by_task(scheduler.current_id()).?;
    }

    fn raw(self: *B5Case, args: Args) i64 {
        return @bitCast(dispatch(79, args, &self.frame));
    }

    fn path_call(self: *B5Case, op: u64, path: []const u8) i64 {
        @memcpy(self.storage.root[0..root.len], root);
        @memcpy(self.storage.relative[0..path.len], path);
        return self.raw(.{ op, @intFromPtr(&self.storage.root), root.len, @intFromPtr(&self.storage.relative), path.len, 0 });
    }

    fn pin(self: *B5Case, path: []const u8) i64 {
        return self.path_call(meta.pin_open_op, path);
    }

    fn named(self: *B5Case, op: u64, dir: i64, name: []const u8, x4: u64) i64 {
        @memcpy(self.storage.from[0..name.len], name);
        return self.raw(.{ op, @bitCast(dir), @intFromPtr(&self.storage.from), name.len, x4, 0 });
    }

    fn close(self: *B5Case, dir: i64) i64 {
        return self.raw(.{ meta.pin_close_op, @bitCast(dir), 0, 0, 0, 0 });
    }

    fn stat(self: *B5Case, handle: i64, kind: u64) i64 {
        return self.raw(.{ meta.handle_metadata_op, @bitCast(handle), kind, 0, 0, @intFromPtr(&self.storage.value) });
    }

    fn rename(self: *B5Case, from_dir: i64, from: []const u8, to_dir: i64, to: []const u8, replace: bool) i64 {
        @memcpy(self.storage.from[0..from.len], from);
        @memcpy(self.storage.to[0..to.len], to);
        const lengths: u64 = from.len | (to.len << 16) | (if (replace) meta.rename_replace else 0);
        return self.raw(.{ meta.rename_op, @bitCast(from_dir), @intFromPtr(&self.storage.from), @bitCast(to_dir), @intFromPtr(&self.storage.to), lengths });
    }
};

test "B5 EL0: pinned directories create stat rename and remove by name" {
    var c: B5Case = .{};
    c.start();
    defer c.stop();
    const meta = file_table.metadata;
    const S = B5Case.Server;
    const a = c.pin("a");
    try std.testing.expect(a > 0);
    try std.testing.expectEqual(@as(i64, 0), c.stat(a, meta.handle_directory));
    try std.testing.expectEqual(meta.Kind.directory, c.storage.value.kind);
    try std.testing.expectEqual(@as(u64, 103), c.storage.value.identity.inode);
    const b = c.named(meta.pin_child_op, a, "b", 0);
    try std.testing.expect(b > 0 and b != a);
    try std.testing.expectEqual(@as(i64, 0), c.stat(b, meta.handle_directory));
    try std.testing.expectEqual(@as(u64, 104), c.storage.value.identity.inode);
    try std.testing.expectEqual(@as(i64, -6), c.named(meta.pin_child_op, a, "missing", 0));
    try std.testing.expectEqual(@as(i64, -7), c.named(meta.pin_child_op, a, "link", 0));
    try std.testing.expectEqual(@as(i64, -1), c.named(meta.pin_child_op, b, "page.md", 0));
    try std.testing.expectEqual(@as(i64, -1), c.pin("a/b/page.md"));

    const fd = c.named(meta.create_op, a, "new.txt", 0);
    try std.testing.expect(fd >= 0 and fd < file_table.max_handles_per_process);
    try std.testing.expectEqual(@as(i64, -9), c.named(meta.create_op, a, "new.txt", 0));
    @memcpy(c.storage.data[0..4], "four");
    try std.testing.expectEqual(@as(u64, 4), dispatch(25, .{ @intCast(fd), @intFromPtr(&c.storage.data), 4, 0, 0, 0 }, &c.frame));
    try std.testing.expectEqual(@as(i64, 0), c.stat(fd, meta.handle_file));
    try std.testing.expectEqual(meta.Kind.file, c.storage.value.kind);
    try std.testing.expectEqual(@as(u64, 4), c.storage.value.size);
    try std.testing.expectEqual(@as(u64, 150), c.storage.value.identity.inode);
    try std.testing.expectEqual(@as(i64, -2), c.stat(fd, meta.handle_directory));
    try std.testing.expectEqual(@as(u64, 0), dispatch(26, .{ @intCast(fd), 0, 0, 0, 0, 0 }, &c.frame));
    try std.testing.expectEqual(@as(i64, -2), c.stat(fd, meta.handle_file));

    const sub = c.named(meta.mkdir_op, a, "sub", 0);
    try std.testing.expect(sub > 0);
    try std.testing.expectEqual(@as(i64, -9), c.named(meta.mkdir_op, a, "sub", 0));
    try std.testing.expectEqual(@as(i64, 0), c.stat(sub, meta.handle_directory));
    try std.testing.expectEqual(@as(u64, 151), c.storage.value.identity.inode);
    // Ownership metadata moves with a guest rename and goes with a removal.
    try std.testing.expectEqual(trust.SetResult.ok, trust.set_mode(file_table.actorFor(B5Case.pid()), .host, "content/a/new.txt", 0o640));
    try std.testing.expectEqual(@as(i64, 0), c.rename(a, "new.txt", sub, "moved.txt", false));
    try std.testing.expect(!S.exists(3, "new.txt") and S.exists(51, "moved.txt"));
    var saved: [trust.save_max]u8 = undefined;
    const owners = saved[0..trust.save(&saved)];
    try std.testing.expect(std.mem.indexOf(u8, owners, "content/a/sub/moved.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, owners, "content/a/new.txt") == null);
    const other = c.named(meta.create_op, a, "x", 0);
    try std.testing.expect(other >= 0);
    try std.testing.expectEqual(@as(u64, 0), dispatch(26, .{ @intCast(other), 0, 0, 0, 0, 0 }, &c.frame));
    try std.testing.expectEqual(@as(i64, -9), c.rename(a, "x", sub, "moved.txt", false));
    try std.testing.expect(S.exists(3, "x"));
    try std.testing.expectEqual(@as(i64, 0), c.rename(a, "x", sub, "moved.txt", true));
    try std.testing.expect(!S.exists(3, "x") and S.exists(51, "moved.txt"));

    const mutations = S.mutations;
    try std.testing.expectEqual(@as(i64, -1), c.named(meta.remove_op, a, "sub", meta.remove_file));
    try std.testing.expectEqual(mutations, S.mutations);
    try std.testing.expectEqual(@as(i64, -9), c.named(meta.remove_op, a, "sub", meta.remove_directory));
    try std.testing.expectEqual(@as(i64, 0), c.named(meta.remove_op, sub, "moved.txt", meta.remove_file));
    try std.testing.expectEqual(@as(usize, 0), trust.count());
    try std.testing.expectEqual(@as(i64, 0), c.named(meta.remove_op, a, "sub", meta.remove_directory));
    // The removed directory's pin is stale: only close is accepted.
    try std.testing.expectEqual(@as(i64, -2), c.stat(sub, meta.handle_directory));
    try std.testing.expectEqual(@as(i64, -2), c.named(meta.create_op, sub, "x", 0));
    try std.testing.expectEqual(@as(i64, -6), c.named(meta.remove_op, a, "sub", meta.remove_directory));
    for ([_]i64{ sub, b, a }) |token| try std.testing.expectEqual(@as(i64, 0), c.close(token));
    try std.testing.expectEqual(@as(i64, -2), c.close(a));
    try std.testing.expectEqual(@as(usize, 0), S.transient_pins());
}

test "B5 EL0: guest renames and removals stale every process's pins at or under the names" {
    var c: B5Case = .{};
    c.start();
    defer c.stop();
    const meta = file_table.metadata;
    const S = B5Case.Server;
    const pid = B5Case.pid();
    const peer_pid: u64 = if (pid == 1) 2 else 1;
    const a = c.pin("a");
    const d = c.named(meta.mkdir_op, a, "d", 0);
    const inner = c.named(meta.mkdir_op, d, "inner", 0);
    const sibling = c.named(meta.mkdir_op, a, "dd", 0);
    try std.testing.expect(a > 0 and d > 0 and inner > 0 and sibling > 0);
    const peer = file_table.pin_open(peer_pid, "/host/content", "a/d/inner");
    const peer_live = file_table.pin_open(peer_pid, "/host/content", "a");
    try std.testing.expect(peer > 0 and peer_live > 0);
    // Tokens belong to the process that opened them.
    var value: meta.Wire = undefined;
    try std.testing.expectEqual(@as(i64, -2), file_table.pin_close(peer_pid, @intCast(a)));
    try std.testing.expectEqual(@as(i64, -2), file_table.handle_metadata(peer_pid, @intCast(d), meta.handle_directory, &value));
    try std.testing.expectEqual(@as(i64, -2), c.close(peer));

    try std.testing.expectEqual(@as(i64, 0), c.rename(a, "d", a, "e", false));
    for ([_]i64{ d, inner }) |token| {
        try std.testing.expectEqual(@as(i64, -2), c.stat(token, meta.handle_directory));
        try std.testing.expectEqual(@as(i64, -2), c.named(meta.pin_child_op, token, "inner", 0));
        try std.testing.expectEqual(@as(i64, -2), c.named(meta.mkdir_op, token, "x", 0));
    }
    try std.testing.expectEqual(@as(i64, -2), file_table.handle_metadata(peer_pid, @intCast(peer), meta.handle_directory, &value));
    // A shared name prefix is not a path prefix.
    try std.testing.expectEqual(@as(i64, 0), c.stat(sibling, meta.handle_directory));
    try std.testing.expectEqual(@as(i64, 0), file_table.handle_metadata(peer_pid, @intCast(peer_live), meta.handle_directory, &value));
    const e = c.named(meta.pin_child_op, a, "e", 0);
    try std.testing.expect(e > 0);
    const moved = c.named(meta.pin_child_op, e, "inner", 0);
    try std.testing.expect(moved > 0);
    try std.testing.expectEqual(@as(i64, 0), c.stat(moved, meta.handle_directory));
    try std.testing.expectEqual(@as(u64, 151), c.storage.value.identity.inode);

    // Pins, snapshots and fds never share a close or page path.
    try std.testing.expectEqual(@as(i64, -2), c.raw(.{ meta.dir_close_op, @bitCast(a), 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(i64, -2), c.raw(.{ meta.dir_page_op, @bitCast(a), 0, 1, @intFromPtr(&c.storage.value), 0 }));
    for (0..file_table.max_handles_per_process) |slot|
        try std.testing.expectEqual(error_result(.ebadf), dispatch(26, .{ slot, 0, 0, 0, 0, 0 }, &c.frame));
    try std.testing.expectEqual(@as(i64, 0), c.close(moved));
    const listing = c.path_call(meta.dir_open_op, "a");
    try std.testing.expect(listing > 0);
    try std.testing.expectEqual(@as(i64, -2), c.close(listing));
    try std.testing.expectEqual(@as(i64, -2), c.named(meta.create_op, listing, "x", 0));
    try std.testing.expectEqual(@as(i64, -2), c.stat(listing, meta.handle_directory));
    try std.testing.expectEqual(@as(i64, 0), c.raw(.{ meta.dir_close_op, @bitCast(listing), 0, 0, 0, 0 }));

    try std.testing.expectEqual(@as(i64, 0), c.named(meta.remove_op, a, "dd", meta.remove_directory));
    try std.testing.expectEqual(@as(i64, -2), c.stat(sibling, meta.handle_directory));
    for ([_]i64{ d, inner, sibling, e, a }) |token| try std.testing.expectEqual(@as(i64, 0), c.close(token));
    // Process teardown releases its stale and live pins alike.
    file_table.reset_process(peer_pid);
    try std.testing.expectEqual(@as(i64, -2), file_table.pin_close(peer_pid, @intCast(peer_live)));
    try std.testing.expectEqual(@as(usize, 0), S.transient_pins());
}

test "B5 EL0: malformed registers faults limits and revocation refuse before backend use" {
    var c: B5Case = .{};
    c.start();
    defer c.stop();
    const meta = file_table.metadata;
    const S = B5Case.Server;
    const bad = uaccess.diagnostic_unmapped;
    const a = c.pin("a");
    try std.testing.expect(a > 0);
    const dir: u64 = @intCast(a);
    const r = @intFromPtr(&c.storage.root);
    const p = @intFromPtr(&c.storage.relative);
    const name = @intFromPtr(&c.storage.from);
    const to = @intFromPtr(&c.storage.to);
    c.storage.from[0] = 'x';
    c.storage.to[0] = 'y';
    const one: u64 = 1 | 1 << 16;
    const lookups = S.lookup_count;
    for ([_]Args{
        .{ meta.pin_open_op, bad, 13, p, 1, 0 },
        .{ meta.pin_child_op, dir, bad, 1, 0, 0 },
        .{ meta.create_op, dir, bad, 1, 0, 0 },
        .{ meta.mkdir_op, dir, bad, 1, 0, 0 },
        .{ meta.remove_op, dir, bad, 1, 0, 0 },
        .{ meta.rename_op, dir, bad, dir, to, one },
        .{ meta.rename_op, dir, name, dir, bad, one },
        .{ meta.handle_metadata_op, dir, meta.handle_directory, 0, 0, bad },
    }) |args| try std.testing.expectEqual(error_result(.efault), dispatch(79, args, &c.frame));
    for ([_]Args{
        .{ meta.pin_child_op, dir, name, 0, 0, 0 },
        .{ meta.pin_child_op, dir, name, 1, 1, 0 },
        .{ meta.create_op, dir, name, 1, 0, 1 },
        .{ meta.mkdir_op, dir, name, 1, 1, 0 },
        .{ meta.remove_op, dir, name, 1, 0, 1 },
        .{ meta.remove_op, dir, name, 1, 2, 0 },
        .{ meta.pin_close_op, dir, 1, 0, 0, 0 },
        .{ meta.handle_metadata_op, dir, meta.handle_directory, 1, 0, name },
        .{ meta.handle_metadata_op, dir, 2, 0, 0, name },
        .{ meta.rename_op, dir, name, dir, to, one | 1 << 33 },
        .{ meta.rename_op, dir, name, dir, to, 1 },
        .{ meta.pin_open_op, r, 13, p, 1, name },
        .{ meta.rename_op + 1, dir, name, 1, 0, 0 },
    }) |args| try std.testing.expectEqual(error_result(.einval), dispatch(79, args, &c.frame));
    try std.testing.expectEqual(error_result(.enametoolong), dispatch(79, .{ meta.create_op, dir, name, 256, 0, 0 }, &c.frame));
    try std.testing.expectEqual(error_result(.enametoolong), dispatch(79, .{ meta.rename_op, dir, name, dir, to, 256 | 1 << 16 }, &c.frame));
    for ([_][]const u8{ ".", "..", "x/y", "x\x00" }) |invalid| {
        try std.testing.expectEqual(@as(i64, -1), c.named(meta.create_op, a, invalid, 0));
        try std.testing.expectEqual(@as(i64, -1), c.named(meta.pin_child_op, a, invalid, 0));
        try std.testing.expectEqual(@as(i64, -1), c.rename(a, invalid, a, "y", true));
    }
    try std.testing.expectEqual(lookups, S.lookup_count);
    try std.testing.expectEqual(@as(usize, 0), S.mutations);

    // The per-process resource limit counts pins and refuses before lookup.
    var held: [file_table.max_handles_per_process - 1]i64 = undefined;
    for (&held) |*token| {
        token.* = c.named(meta.pin_child_op, a, "b", 0);
        try std.testing.expect(token.* > 0);
    }
    const full = S.lookup_count;
    try std.testing.expectEqual(@as(i64, -5), c.named(meta.pin_child_op, a, "b", 0));
    try std.testing.expectEqual(@as(i64, -5), c.named(meta.create_op, a, "x", 0));
    try std.testing.expectEqual(@as(i64, -5), c.named(meta.mkdir_op, a, "x", 0));
    try std.testing.expectEqual(@as(i64, -5), c.pin("a"));
    try std.testing.expectEqual(full, S.lookup_count);
    try std.testing.expectEqual(@as(usize, 0), S.mutations);
    for (held) |token| try std.testing.expectEqual(@as(i64, 0), c.close(token));

    // A legacy fd has no pinned object to describe.
    var files = [_]syscall.virtio_file.TestFile{.{ .name = "legacy.txt", .data = "old" }};
    syscall.virtio_file.set_test_share(&files);
    const legacy = file_table.open(B5Case.pid(), "/host/legacy.txt", file_table.MODE_READ);
    syscall.virtio_file.set_test_share(null);
    try std.testing.expect(legacy >= 0);
    try std.testing.expectEqual(@as(i64, -4), c.stat(legacy, meta.handle_file));
    try std.testing.expectEqual(@as(i64, -2), c.stat(7, meta.handle_file));
    try std.testing.expectEqual(@as(i64, 0), file_table.close(B5Case.pid(), @intCast(legacy)));

    // Revocation applies at every use; close still releases the reference.
    const fd = c.named(meta.create_op, a, "x", 0);
    try std.testing.expect(fd >= 0);
    _ = syscall.trust.load("#v1\ncontent/a\t600\t0\t-\n");
    const before = S.lookup_count;
    try std.testing.expectEqual(@as(i64, -7), c.stat(a, meta.handle_directory));
    try std.testing.expectEqual(@as(i64, -7), c.stat(fd, meta.handle_file));
    for ([_]u64{ meta.pin_child_op, meta.create_op, meta.mkdir_op, meta.remove_op }) |op|
        try std.testing.expectEqual(@as(i64, -7), c.named(op, a, "b", 0));
    try std.testing.expectEqual(@as(i64, -7), c.rename(a, "x", a, "y", true));
    try std.testing.expectEqual(before, S.lookup_count);
    try std.testing.expectEqual(@as(usize, 1), S.mutations);
    try std.testing.expectEqual(@as(i64, -7), c.pin("a"));
    try std.testing.expectEqual(@as(u64, 0), dispatch(26, .{ @intCast(fd), 0, 0, 0, 0, 0 }, &c.frame));
    try std.testing.expectEqual(@as(i64, 0), c.close(a));
    syscall.trust.init();
    try std.testing.expectEqual(@as(usize, 0), S.transient_pins());
    S.stop();
    try std.testing.expectEqual(@as(i64, -4), c.pin("a"));
}

test "syscall: slot 35 replacement selector preserves legacy register behavior" {
    const vf = syscall.virtio_file;
    const Probe = struct {
        var mode: file_table.RenameMode = .replace;
        var calls: usize = 0;
        fn rename_probe(_: []const u8, _: []const u8, selected: file_table.RenameMode) u8 {
            mode = selected;
            calls += 1;
            return syscall.virtio_file.st_not_found;
        }
    };
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    _ = scheduler.yield_current();
    syscall.trust.init();
    defer syscall.trust.init();
    vf.set_test_rename(Probe.rename_probe);
    defer vf.set_test_rename(null);
    Probe.calls = 0;
    var frame = fresh_frame();
    const max_length = file_table.max_path_len;
    var paths = [_]u8{'a'} ** (max_length * 2);
    for (0..2) |i| {
        var separator = file_table.directory.name_max;
        while (separator + 1 < max_length) : (separator += file_table.directory.name_max)
            paths[i * max_length + separator] = '/';
    }
    const address = @intFromPtr(&paths);
    set_user_regions(.{ .base = address, .len = paths.len }, .{ .base = address, .len = paths.len });

    // Existing four-argument gateways leave x4/x5 unspecified.
    try std.testing.expectEqual(error_result(.enoent), dispatch(sys_file_rename, .{ address, 64, address + 64, 64, 0xffff, 0x12345678 }, &frame));
    try std.testing.expectEqual(file_table.RenameMode.preserve_existing, Probe.mode);
    try std.testing.expectEqual(error_result(.enoent), dispatch(sys_file_rename, .{ address, max_length, address + max_length, max_length, 0xffff, 0x12345678 }, &frame));
    try std.testing.expectEqual(file_table.RenameMode.preserve_existing, Probe.mode);
    try std.testing.expectEqual(error_result(.enoent), dispatch(sys_file_rename, .{ address, max_length | syscall.file_rename_replace, address + max_length, max_length, 0, 0 }, &frame));
    try std.testing.expectEqual(file_table.RenameMode.replace, Probe.mode);
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_rename, .{ address, syscall.file_rename_replace, address, 4, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_rename, .{ address, (max_length + 1) | syscall.file_rename_replace, address, 4, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_rename, .{ address, 4 | (@as(u64, 1) << 62), address, 4, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_rename, .{ address, 4 | syscall.file_rename_replace, address, max_length + 1, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_file_rename, .{ uaccess.diagnostic_unmapped, 4 | syscall.file_rename_replace, address, 4, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_file_rename, .{ address, 4 | syscall.file_rename_replace, uaccess.diagnostic_unmapped, 4, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 3), Probe.calls);
}

test "syscall: clipboard slots 38..39 dispatch and fault safety (claim 0169)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    // M97g (#2082): slots 38/39 require CAP_CLIPBOARD — bind an admin caller.
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const adm_pid = process.create_as("CLIPADM.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}, .{ .uid = process.uid_system, .caps = process.kernel_caps }).?;
    const adm_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(adm_pid, adm_task);
    scheduler.start();
    var frame = fresh_frame();

    // In task 0 (shell, not a registered process), calls return EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_clipboard_set, .{ 0x1000, 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_clipboard_get, .{ 0x1000, 4, 0, 0, 0, 0 }, &frame));

    // Yield to the admin task.
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expect(scheduler.yield_current()); // user (2) -> admin
    try std.testing.expectEqual(adm_task, scheduler.current_id());

    var test_buf: [64]u8 = undefined;
    const test_buf_addr = @intFromPtr(&test_buf);
    // The same region serves as the copy-in source (readable) and the
    // copy-out destination (writable).
    set_user_regions(
        .{ .base = test_buf_addr, .len = test_buf.len },
        .{ .base = test_buf_addr, .len = test_buf.len },
    );

    // Bad pointer on a non-empty set -> EFAULT (the copy-in path validates
    // before touching memory).
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_clipboard_set, .{ uaccess.diagnostic_unmapped, 4, 0, 0, 0, 0 }, &frame));

    // An EMPTY clipboard get returns 0 without validating the pointer — the
    // same empty -> 0 discipline as udp/ipc recv (no copy runs).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_clipboard_get, .{ uaccess.diagnostic_unmapped, 4, 0, 0, 0, 0 }, &frame));

    // Set copies bytes into the shared buffer and returns the stored length.
    @memcpy(test_buf[0..5], "hello");
    try std.testing.expectEqual(@as(u64, 5), dispatch(sys_clipboard_set, .{ test_buf_addr, 5, 0, 0, 0, 0 }, &frame));

    // A NON-empty get validates the pointer -> EFAULT.
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_clipboard_get, .{ uaccess.diagnostic_unmapped, 4, 0, 0, 0, 0 }, &frame));

    // Get copies them back out (non-destructive) and returns the length.
    @memset(&test_buf, 0);
    try std.testing.expectEqual(@as(u64, 5), dispatch(sys_clipboard_get, .{ test_buf_addr, 64, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("hello", test_buf[0..5]);

    // A second get returns the SAME contents (the clipboard is not consumed).
    @memset(&test_buf, 0);
    try std.testing.expectEqual(@as(u64, 5), dispatch(sys_clipboard_get, .{ test_buf_addr, 64, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("hello", test_buf[0..5]);

    // max == 0 -> 0 without touching the buffer.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_clipboard_get, .{ test_buf_addr, 0, 0, 0, 0, 0 }, &frame));

    // An empty set clears the shared buffer.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_clipboard_set, .{ test_buf_addr, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_clipboard_get, .{ test_buf_addr, 64, 0, 0, 0, 0 }, &frame));
}

test "syscall: clipboard slots refuse a caller without CAP_CLIPBOARD (#2082)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0: uid_user, no caps
    scheduler.start();
    var frame = fresh_frame();

    // Seed the buffer through the kernel-internal path (what the monitor
    // `clip` command and the chrome copy chord do — they never enter the
    // syscall handlers).
    try std.testing.expectEqual(@as(usize, 5), clipboard.set("hello"));

    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    var test_buf: [64]u8 = undefined;
    const test_buf_addr = @intFromPtr(&test_buf);
    set_user_regions(
        .{ .base = test_buf_addr, .len = test_buf.len },
        .{ .base = test_buf_addr, .len = test_buf.len },
    );

    // Both slots refuse EACCES — and the refusal precedes argument
    // validation, so even a wild pointer or a clear-set cannot probe.
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_clipboard_get, .{ test_buf_addr, 64, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_clipboard_set, .{ test_buf_addr, 5, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_clipboard_set, .{ uaccess.diagnostic_unmapped, 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_clipboard_set, .{ test_buf_addr, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_clipboard_get, .{ uaccess.diagnostic_unmapped, 4, 0, 0, 0, 0 }, &frame));

    // Nothing was read and nothing was written: the buffer is unchanged
    // and the caller's region was never touched.
    try std.testing.expectEqual(@as(usize, 5), clipboard.current_len());
    var out: [clipboard.capacity]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), clipboard.get(&out));
    try std.testing.expectEqualStrings("hello", out[0..5]);

    // The seat carve-out: the same uncapped caller, once it IS the
    // kernel-registered WM (the user's gesture mediator), reads the
    // buffer again — WND.BIN's tray probe stays honest.
    wm_server.init();
    try std.testing.expect(wm_server.register(0));
    try std.testing.expectEqual(@as(u64, 5), dispatch(sys_clipboard_get, .{ test_buf_addr, 64, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("hello", test_buf[0..5]);
}

test "syscall: app timer slots 40..41 dispatch, fire through the tick, and clamp (claim 7323)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();

    // In task 0 (shell, not a registered process), both calls return EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_timer_set, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_timer_cancel, .{ 0, 0, 0, 0, 0, 0 }, &frame));

    // Yield to the user task (task 2, pid 0).
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    // Cancel with nothing armed -> 0.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_timer_cancel, .{ 0, 0, 0, 0, 0, 0 }, &frame));

    // Arm a 2-tick timer -> 0, and the module sees it armed with 2 left.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_timer_set, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(app_timers.armed_pending(0));
    try std.testing.expectEqual(@as(u64, 2), app_timers.info(0).remaining);

    // Re-arm replaces the pending countdown (back to 3).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_timer_set, .{ 3, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 3), app_timers.info(0).remaining);
    try std.testing.expectEqual(@as(u64, 2), app_timers.info(0).sets);

    // The scheduler tick drives the countdown; the timer fires exactly one
    // TIMER event into pid 0's queue after three ticks.
    scheduler.on_tick();
    scheduler.on_tick();
    try std.testing.expectEqual(@as(u64, 1), app_timers.info(0).remaining);
    try std.testing.expectEqual(@as(usize, 0), events.pending(0));
    scheduler.on_tick();
    try std.testing.expect(!app_timers.armed_pending(0));
    try std.testing.expectEqual(@as(u64, 1), app_timers.info(0).fired);
    try std.testing.expectEqual(@as(usize, 1), events.pending(0));
    const ev = events.peek(0).?;
    try std.testing.expectEqual(events.TIMER, ev.kind);
    _ = events.drop(0);

    // Zero clamps to one tick (the sys_sleep minimum); over-long truncates.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_timer_set, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), app_timers.info(0).remaining);
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_timer_set, .{ app_timers.max_delay_ticks + 1000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(app_timers.max_delay_ticks, app_timers.info(0).remaining);

    // Cancel a pending timer -> 1, and it never fires.
    try std.testing.expectEqual(@as(u64, 1), dispatch(sys_timer_cancel, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!app_timers.armed_pending(0));
    try std.testing.expectEqual(@as(u64, 1), app_timers.info(0).cancels);
    scheduler.on_tick();
    try std.testing.expectEqual(@as(usize, 0), events.pending(0));
    try std.testing.expectEqual(@as(u64, 1), app_timers.info(0).fired);
}

test "syscall: slot 28 sys_exec marshals the path and maps loader errors" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    // No host file channel — exec_file reports no_disk honestly (HF6: the
    // ESP disk is gone; the share is the only app source).
    virtio_file.set_test_share(null);
    var frame = fresh_frame();

    // In task 0 (shell, not a registered process), sys_exec returns EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_exec, .{ 0x1000, 8, 0, 0, 0, 0 }, &frame));
    // Empty path and an over-long path are EINVAL (checked before uaccess)
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_exec, .{ 0x1000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_exec, .{ 0x1000, virtio_file.path_max + 1, 0, 0, 0, 0 }, &frame));

    // Yield to the user task (task 2, pid 0)
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(process.find_by_task(2) != null);

    var path_buf: [16]u8 = undefined;
    const path_addr = @intFromPtr(&path_buf);
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = path_addr, .len = path_buf.len },
    );

    // Bad path pointer -> EFAULT
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_exec, .{ uaccess.diagnostic_unmapped, 8, 0, 0, 0, 0 }, &frame));
    // No disk -> EINVAL (exec_file .no_disk — the loader cannot mount the ESP)
    @memcpy(path_buf[0..8], "CALC.BIN");
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_exec, .{ path_addr, 8, 0, 0, 0, 0 }, &frame));
    // The slot is counted like every other implemented row
    try std.testing.expectEqual(@as(u64, 5), call_count(sys_exec));
}

test "syscall: slot 28 sys_exec argc>8 is EINVAL and ENOENT leaves the caller (issue #1333)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    var share_files = [_]virtio_file.TestFile{
        .{ .name = "BOOTED.TXT", .data = "1\n" },
    };
    virtio_file.set_test_share(&share_files);
    defer virtio_file.set_test_share(null);
    var frame = fresh_frame();

    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(@as(?usize, 0), process.find_by_task(2));

    var path_buf: [16]u8 = undefined;
    const path_addr = @intFromPtr(&path_buf);
    @memcpy(path_buf[0..8], "NOSUCH.B");
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = path_addr, .len = path_buf.len },
    );

    try std.testing.expectEqual(error_result(.einval), dispatch(sys_exec, .{ path_addr, 8, 0, 9, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 1), process.count());
    try std.testing.expectEqual(process.State.running, process.info(0).?.state);

    @memcpy(path_buf[0..10], "NOSUCH.BIN");
    try std.testing.expectEqual(error_result(.enoent), dispatch(sys_exec, .{ path_addr, 10, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(@as(?usize, 0), process.find_by_task(2));
    try std.testing.expectEqual(process.State.running, process.info(0).?.state);
    try std.testing.expectEqual(@as(usize, 1), process.count());
}

// Host-backed page pool for a successful sys_exec (exec copies into
// text_phys; a fake 0x100000 base would segfault the host test).
// #1336: one exec is text 1 + 48-page user stack + 48-page kstack = 97
// pages; keep the same 1024-page headroom as exec.zig's fixture pool.
const sys_exec_pool_pages: usize = 1024;
var sys_exec_pool: [sys_exec_pool_pages * 4096]u8 align(4096) = undefined;

fn arm_sys_exec_allocator() void {
    const descriptors = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = @intFromPtr(&sys_exec_pool), .virtual_start = 0, .number_of_pages = sys_exec_pool_pages, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&descriptors), @sizeOf(memmap.MemoryDescriptor), descriptors.len);
    _ = alloc.init(view, &.{});
}

test "syscall: slot 28 sys_exec success preserves the caller task (issue #1333)" {
    userspace.init();
    init(test_writer);
    mmu.reset();
    arm_sys_exec_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();

    const content = "user: hello from the ESP\n";
    var img = [_]u8{0} ** (24 + 25);
    std.mem.writeInt(u32, img[0..4], 0x314b5344, .little);
    std.mem.writeInt(u64, img[8..16], 24, .little);
    std.mem.writeInt(u64, img[16..24], 24 + 25, .little);
    @memcpy(img[24..], content);
    var share_files = [_]virtio_file.TestFile{
        .{ .name = "USER.BIN", .data = img[0..] },
    };
    virtio_file.set_test_share(&share_files);
    defer virtio_file.set_test_share(null);

    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(@as(?usize, 0), process.find_by_task(2));

    // Path (8) plus one argv slot (exec.arg_slot_bytes, 256). The kernel
    // copies the whole slot; a short buffer is EFAULT.
    var wire: [8 + 256]u8 = [_]u8{0} ** (8 + 256);
    @memcpy(wire[0..8], "USER.BIN");
    @memcpy(wire[8..13], "alpha");
    const wire_addr = @intFromPtr(&wire);
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = wire_addr, .len = wire.len },
    );

    var frame = fresh_frame();
    const rc = dispatch(sys_exec, .{ wire_addr, 8, wire_addr + 8, 1, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, 1), rc);
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(@as(?usize, 0), process.find_by_task(2));
    try std.testing.expectEqual(process.State.running, process.info(0).?.state);
    try std.testing.expectEqual(process.State.running, process.info(1).?.state);
    try std.testing.expectEqualStrings("USER.BIN", process.info(1).?.name);
}

test "syscall: slot 29 sys_kill arms a process target and maps refusals" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const target_pid = process.create("TARGET.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const target_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(target_pid, target_task);
    scheduler.start();
    var frame = fresh_frame();

    // In task 0 (shell, not a process), sys_kill returns EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_kill, .{ target_pid, 0, 0, 0, 0, 0 }, &frame));
    // Out-of-range and free pids are EINVAL (the sys_wait precedent).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_kill, .{ process.max_processes, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_kill, .{ 7, 0, 0, 0, 0, 0 }, &frame));

    // Drive to the caller (task 2, pid 0).
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    // Arm the target: returns 0.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_kill, .{ target_pid, 0, 0, 0, 0, 0 }, &frame));

    // The kill lands at the target's NEXT selection: the ring walks to the
    // target (task 3), the kill branch converts the selection into the
    // existing exit path with the reserved status 137, and the ring moves
    // on — the target never resumes.
    try std.testing.expect(scheduler.yield_current()); // user -> target -> killed -> idle
    try std.testing.expectEqual(@as(usize, scheduler.idle_id), scheduler.current_id());
    try std.testing.expect(scheduler.is_terminated(target_task));
    try std.testing.expectEqual(@as(?u64, scheduler.reserved_kill_status), scheduler.terminated_status(target_task));
    const pinfo = process.info(target_pid).?;
    try std.testing.expectEqual(process.State.exited, pinfo.state);
    try std.testing.expectEqual(@as(u64, scheduler.reserved_kill_status), pinfo.exit_status);

    // The exited target is refused on the next call (back in a process
    // context — the ring returns to the caller).
    try std.testing.expect(scheduler.yield_current()); // idle
    try std.testing.expect(scheduler.yield_current()); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_kill, .{ target_pid, 0, 0, 0, 0, 0 }, &frame));
    // The slot is counted like every other implemented row.
    try std.testing.expectEqual(@as(u64, 5), call_count(sys_kill));
}

test "syscall: sys_poll_event and sys_wait_event handle events, blocking, and uaccess fault safety" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    events.init();
    events.on_event_pushed = scheduler.wake_event_waiters;
    var frame = fresh_frame();

    // In task 0 (shell, not a registered process), syscalls return EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_poll_event, .{ 0x1000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wait_event, .{ 0x1000, 0, 0, 0, 0, 0 }, &frame));

    // Yield to user task (task 2, pid 0)
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    const pid = process.find_by_task(2).?;
    try std.testing.expectEqual(@as(usize, 0), pid);

    var ev_buf: [16]u8 align(16) = undefined;
    const buf_addr = @intFromPtr(&ev_buf);
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = buf_addr, .len = ev_buf.len },
    );

    // 1. Poll on empty queue -> returns 0
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_poll_event, .{ buf_addr, 0, 0, 0, 0, 0 }, &frame));

    // 2. Push an event to pid 0
    events.push(0, .{
        .kind = events.KEY_DOWN,
        .flags = events.MOD_SHIFT,
        .seq = 0,
        .arg0 = 0x04,
        .arg1 = 'A',
    });

    // 3. Poll with bad buffer address -> EFAULT (event is preserved in queue)
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_poll_event, .{ uaccess.diagnostic_unmapped, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 1), events.pending(0));

    // 4. Poll with valid buffer -> 1 (event copied and dropped)
    try std.testing.expectEqual(@as(u64, 1), dispatch(sys_poll_event, .{ buf_addr, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 0), events.pending(0));
    const got_kind = std.mem.readInt(u16, ev_buf[0..2], .little);
    const got_flags = std.mem.readInt(u16, ev_buf[2..4], .little);
    const got_arg0 = std.mem.readInt(u32, ev_buf[8..12], .little);
    const got_arg1 = std.mem.readInt(u32, ev_buf[12..16], .little);
    try std.testing.expectEqual(events.KEY_DOWN, got_kind);
    try std.testing.expectEqual(events.MOD_SHIFT, got_flags);
    try std.testing.expectEqual(@as(u32, 0x04), got_arg0);
    try std.testing.expectEqual(@as(u32, 'A'), got_arg1);

    // 5. sys_wait_event with queued event -> returns 1 immediately
    events.push(0, .{
        .kind = events.MOUSE_MOVE,
        .flags = 0,
        .seq = 0,
        .arg0 = 120,
        .arg1 = 80,
    });
    try std.testing.expectEqual(@as(u64, 1), dispatch(sys_wait_event, .{ buf_addr, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 0), events.pending(0));

    // 6. sys_wait_event with empty queue -> blocks task in scheduler!
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wait_event, .{ buf_addr, 0, 0, 0, 0, 0 }, &frame));
    // Task 2 is now blocked waiting for events on pid 0
    // Current task switched to idle/next
    try std.testing.expect(scheduler.current_id() != 2);

    // 7. Pushing an event to pid 0 wakes task 2!
    events.push(0, .{
        .kind = events.WIN_FOCUS,
        .flags = 0,
        .seq = 0,
        .arg0 = 2,
        .arg1 = 0,
    });

    // Task 2 should now be ready
    try std.testing.expectEqual(@as(usize, 1), events.pending(0));
}

test "syscall: sys_wmctl (slot 65) enforces the render-server register contract" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();

    // In task 0 (shell, not a registered process) REGISTER is EINVAL — an
    // EL1h task can never be the WM (non-process caller).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_register, 0, 0, 0, 0, 0 }, &frame));

    // Drive to the caller (task 2, pid 0).
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(@as(usize, 0), process.find_by_task(2).?);

    // No WM registered, no GPU (host test):
    //   REGISTER -> ENXIO (no gpu / unarmed compositor)
    //   SET_WINDOW / REQUEST_PRESENT -> ENOSYS (the ADR 0007 "no WM" case)
    //   unknown cmd -> EINVAL
    try std.testing.expectEqual(error_result(.enxio), dispatch(sys_wmctl, .{ wm_server.wmctl_register, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_set_window, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_request_present, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ 99, 0, 0, 0, 0, 0 }, &frame));

    // The slot is counted like every other implemented row.
    try std.testing.expectEqual(@as(u64, 5), call_count(sys_wmctl));

    // Seed the WM as pid 0; the registrant drives the seam:
    try std.testing.expect(wm_server.register(0));
    try std.testing.expectEqual(@as(u64, 0), wm_server.info().present_count);
    //   REQUEST_PRESENT from the WM -> 0, and the present counter advanced.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_request_present, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().present_count);
    //   A second REGISTER while the seat is taken -> EACCES.
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_wmctl, .{ wm_server.wmctl_register, 0, 0, 0, 0, 0 }, &frame));
    //   SET_WINDOW (WMS4): a valid descriptor from the WM is accepted and
    //   stored; every malformed submission is refused honestly.
    var desc: wnd_core.ChromeDesc = wnd_core.chrome_parity_policy();
    const desc_ptr = @intFromPtr(&desc);
    set_user_regions(.{ .base = desc_ptr, .len = wnd_core.chrome_desc_bytes }, .{ .base = 0, .len = 0 });
    // Broadcast (ALL): accepted, the policy is stored, submissions counted.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_set_window, wnd_core.chrome_window_all, 0, 0, desc_ptr, wnd_core.chrome_desc_bytes }, &frame));
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().set_window_count);
    try std.testing.expectEqual(@as(u32, 0x7f), driving_award.wm_chrome_policy_kind());
    // Per-window id with no such window -> EINVAL (the broadcast always
    // succeeds; a specific id must exist).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_set_window, 7, 0, 0, desc_ptr, wnd_core.chrome_desc_bytes }, &frame));
    // Bad length (not the frozen 40) -> EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_set_window, wnd_core.chrome_window_all, 0, 0, desc_ptr, 39 }, &frame));
    // WMS5 (issue #625): the ALL broadcast stays chrome-only — nonzero
    // rect on the broadcast -> EINVAL (geometry is per-window).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_set_window, wnd_core.chrome_window_all, 1, 0, desc_ptr, wnd_core.chrome_desc_bytes }, &frame));
    // Unknown kind bit -> EINVAL (the single wnd_core refusal rule).
    const bad = wnd_core.ChromeDesc{ .kind = wnd_core.chrome_kind_all | 0x80, .flags = 0, .border_rgb = 0, .border_unfocus_rgb = 0, .title_bg_rgb = 0, .title_fg_rgb = 0, .ring_rgb = 0, .close_rgb = 0, .min_rgb = 0, .pin_rgb = 0 };
    const bad_ptr = @intFromPtr(&bad);
    set_user_regions(.{ .base = bad_ptr, .len = wnd_core.chrome_desc_bytes }, .{ .base = 0, .len = 0 });
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_set_window, wnd_core.chrome_window_all, 0, 0, bad_ptr, wnd_core.chrome_desc_bytes }, &frame));
    // Bad descriptor pointer (no readable region) -> EFAULT.
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = 0, .len = 0 });
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_wmctl, .{ wm_server.wmctl_set_window, wnd_core.chrome_window_all, 0, 0, 0x1000, wnd_core.chrome_desc_bytes }, &frame));

    // Seed a DIFFERENT pid as the WM; pid 0 becomes an outsider:
    wm_server.init();
    try std.testing.expect(wm_server.register(1));
    //   REGISTER -> EACCES (seat taken); SET_WINDOW / REQUEST_PRESENT ->
    //   EACCES (the ADR 0007 WM-exclusive refusal).
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_wmctl, .{ wm_server.wmctl_register, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_wmctl, .{ wm_server.wmctl_set_window, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_wmctl, .{ wm_server.wmctl_request_present, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, 0, 0, 0, 0, 0 }, &frame));
    // WMS5: the input seam is part of the register contract — registering
    // hands the raw pointer stream + window mirrors to the WM (kind 19/20);
    // teardown restores shim input consumption. Tear down so the aggregated
    // test binary does not leak input ownership into later tests.
    try std.testing.expect(driving_award.wm_owns_input);
    try std.testing.expect(wm_server.unregister(1));
    try std.testing.expect(!driving_award.wm_owns_input);
}

test "syscall: #2079 wmctl REGISTER is provenance-gated; SEAT_PID answers the kernel register" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = pid 0, kernel-spawned
    scheduler.start();
    // Arm the compositor check so REGISTER reaches the seat gate; restore
    // on exit and never leak a held seat into the next test.
    const saved_gpu_ok = virtio_gpu.gpu_setup_ok;
    virtio_gpu.gpu_setup_ok = true;
    defer virtio_gpu.gpu_setup_ok = saved_gpu_ok;
    defer wm_server.init();
    var frame = fresh_frame();

    // Drive to pid 0's task (kernel-spawned: allocated while a kernel task
    // was current, so spawned_by == null).
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(@as(?usize, 0), process.find_by_task(2));

    // SEAT_PID (cmd 16) with no seat held -> ENOENT; it is an ordinary
    // unprivileged read — the seat pid was always observable.
    try std.testing.expectEqual(error_result(.enoent), dispatch(sys_wmctl, .{ wm_server.wmctl_seat_pid, 0, 0, 0, 0, 0 }, &frame));

    // Kernel-spawned caller may register (monitor `exec`, boot autostart).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_register, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(?usize, 0), wm_server.registered_pid());
    // SEAT_PID answers the kernel's register — a pid, not a name.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_seat_pid, 0, 0, 0, 0, 0 }, &frame));
    // Seat taken: even a privileged caller is refused (one-seat rule).
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_wmctl, .{ wm_server.wmctl_register, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(wm_server.unregister(0));

    // Build the launcher hierarchy with `current` pointing at the
    // would-be spawner: children of pid 0 (kernel-spawned) are the
    // launcher class; children of a launcher child are ordinary EL0.
    var kstack1: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack2: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack3: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack4: [scheduler.task_stack_size]u8 align(16) = undefined;

    const seat_pid = process.create("GOTABWM.ELF", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const seat_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack1, 0, 0).?;
    _ = process.bind(seat_pid, seat_task);
    const gosh_pid = process.create("GOSH.ELF", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const gosh_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack2, 0, 0).?;
    _ = process.bind(gosh_pid, gosh_task);
    // Both spawned while task 2 (pid 0, kernel-spawned) was current:
    // spawned_by = 0, launcher_spawned = true.
    try std.testing.expectEqual(@as(?usize, 0), scheduler.spawn_provenance(seat_task).parent);
    try std.testing.expect(scheduler.spawn_provenance(seat_task).launcher);

    // Now spawn while GOSH's task is current: an ordinary EL0 child —
    // spawned_by = gosh_pid, launcher_spawned = false — NAMED like the
    // seat. The forged name must not help it.
    scheduler.current[0] = gosh_task;
    const rogue_pid = process.create("GOTABWM.ELF", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const rogue_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack3, 0, 0).?;
    _ = process.bind(rogue_pid, rogue_task);
    try std.testing.expectEqual(@as(?usize, gosh_pid), scheduler.spawn_provenance(rogue_task).parent);
    try std.testing.expect(!scheduler.spawn_provenance(rogue_task).launcher);
    // An admin-capability child of the same ordinary parent: the cap is
    // the credential, not the provenance.
    const admin_pid = process.create_as("ADMIN.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}, .{ .caps = process.cap_proc_admin }).?;
    const admin_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack4, 0, 0).?;
    _ = process.bind(admin_pid, admin_task);

    // The launcher child bearing the configured seat program registers.
    scheduler.current[0] = seat_task;
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_register, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(?usize, seat_pid), wm_server.registered_pid());
    try std.testing.expectEqual(@as(u64, seat_pid), dispatch(sys_wmctl, .{ wm_server.wmctl_seat_pid, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(wm_server.unregister(seat_pid));

    // The launcher child with a non-seat name is refused (GOSH -> EACCES).
    scheduler.current[0] = gosh_task;
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_wmctl, .{ wm_server.wmctl_register, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!wm_server.registered());

    // The forged-name grandchild (ordinary EL0 spawn) is refused — the
    // name alone is never the credential.
    scheduler.current[0] = rogue_task;
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_wmctl, .{ wm_server.wmctl_register, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!wm_server.registered());

    // cap_proc_admin crosses the gate from ANY provenance class.
    scheduler.current[0] = admin_task;
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_register, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(?usize, admin_pid), wm_server.registered_pid());
    try std.testing.expect(wm_server.unregister(admin_pid));
    scheduler.current[0] = 0;
}

test "syscall: SET_STATE (cmd 4, claim 4278) applies visibility/workspace/ws-switch with the seam refusals" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)

    // No WM registered: SET_STATE -> ENOSYS (the ADR 0007 "no WM" case).
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, 2, 0, 0, 0, 0 }, &frame));

    // Seed the WM as pid 0 and arm the compositor state for window tests.
    try std.testing.expect(wm_server.register(0));
    // No such window -> EINVAL (id validated even with no visible change).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, 9, 2, 0, 0, 0 }, &frame));
    // Out-of-range workspace (bits 8-15 >= workspace_max and not 0xff) -> EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, 2, 0x0900, 0, 0, 0 }, &frame));
    // The ALL broadcast with an OUT-OF-RANGE workspace -> EINVAL (the
    // global ws-switch validates its target; ws 0 IS valid, 3 is not —
    // `switch_workspace` refuses `>= workspace_max`, and the handler
    // validates before the call so the refusal is an honest EINVAL).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, wnd_core.chrome_window_all, 0x0300, 0, 0, 0 }, &frame));

    // Open a real user window (id 2), then drive the seam from the WM:
    const open_res = driving_award.user_open(64, 64, 512, 384, 0);
    try std.testing.expectEqual(@as(u8, 2), open_res.opened); // window id 2
    //   GLOBAL workspace switch (a0 = ALL, bits 8-15 = 1): current ws moves.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, wnd_core.chrome_window_all, 0x0100, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u8, 1), driving_award.current_workspace);
    //   Per-window hide (minimize): visible -> false, counter advanced.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, 2, 0, 0, 0, 0 }, &frame));
    const w2 = driving_award.find_user_window(2).?;
    try std.testing.expect(!w2.visible);
    //   Per-window show (restore): visible -> true.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, 2, 1, 0, 0, 0 }, &frame));
    try std.testing.expect(driving_award.find_user_window(2).?.visible);
    //   Per-window workspace move (bits 8-15 = 2): w.workspace -> 2.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, 2, 0x0200, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u8, 2), driving_award.find_user_window(2).?.workspace);
    //   Always-on-top toggle (bit 16): the flag flips.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, 2, (1 << 16) | 2, 0, 0, 0 }, &frame));
    try std.testing.expect(driving_award.find_user_window(2).?.always_on_top);
    // The counter observed every accepted call (global + 4 per-window).
    try std.testing.expectEqual(@as(u64, 5), wm_server.info().set_state_count);

    // Teardown: no leaked input ownership into the aggregated binary.
    try std.testing.expect(wm_server.unregister(0));
    try std.testing.expect(!driving_award.wm_owns_input);
    _ = driving_award.user_close(2);
}

test "syscall: ALT_TAB (cmd 5, claim 4510) drives the overlay from the WM's chosen id" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)

    // No WM registered: ALT_TAB -> ENOSYS (the ADR 0007 "no WM" case).
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_alt_tab, 2, wm_server.alt_tab_commit, 0, 0, 0 }, &frame));

    // Seed the WM as pid 0 + open two real user windows.
    try std.testing.expect(wm_server.register(0));
    const o2 = driving_award.user_open(64, 64, 400, 300, 0);
    const o3 = driving_award.user_open(200, 100, 400, 300, 0);
    try std.testing.expectEqual(@as(u8, 2), o2.opened);
    try std.testing.expectEqual(@as(u8, 3), o3.opened);
    // The WM proposes focus on window 3; the kernel focuses/raises + dismisses,
    // and the submission is counted.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_alt_tab, 3, wm_server.alt_tab_commit, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u8, 3), driving_award.focused_window_id());
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().alt_tab_apply_count);
    // activate highlights the WM's chosen id in the overlay snapshot.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_alt_tab, 2, wm_server.alt_tab_activate, 0, 0, 0 }, &frame));
    try std.testing.expect(driving_award.alt_tab_is_active());
    try std.testing.expectEqual(@as(u8, 2), driving_award.alt_tab_selected_id().?);
    // dismiss drops the overlay.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_alt_tab, 0, wm_server.alt_tab_dismiss, 0, 0, 0 }, &frame));
    try std.testing.expect(!driving_award.alt_tab_is_active());
    try std.testing.expectEqual(@as(u64, 3), wm_server.info().alt_tab_apply_count);
    // A commit to a window that does not exist -> EINVAL (kernel clamps).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_alt_tab, 9, wm_server.alt_tab_commit, 0, 0, 0 }, &frame));
    // A malformed action -> EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_alt_tab, 2, 77, 0, 0, 0 }, &frame));
    // The counter only counted the accepted calls.
    try std.testing.expectEqual(@as(u64, 3), wm_server.info().alt_tab_apply_count);

    // Teardown: no leaked input ownership into the aggregated binary.
    try std.testing.expect(wm_server.unregister(0));
    try std.testing.expect(!driving_award.wm_owns_input);
    _ = driving_award.user_close(2);
    _ = driving_award.user_close(3);
}

test "syscall: NOTIF_CENTER / NOTIF_DISMISS (cmd 6/7, claim 7557) drive the center from the WM's decision" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)

    // No WM registered: NOTIF_CENTER -> ENOSYS (the ADR 0007 "no WM" case).
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_notif_center, 1, 0, 0, 0, 0 }, &frame));

    // Seed the WM as pid 0.
    try std.testing.expect(wm_server.register(0));
    // Open -> notif_center_open true.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_notif_center, 1, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(driving_award.notif_center_open);
    // Close -> false.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_notif_center, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!driving_award.notif_center_open);
    // Clear-all is accepted with no notifications.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_notif_center, 2, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 3), wm_server.info().notif_center_count);
    // Dismissing an out-of-range row -> EINVAL (honest, no silent no-op).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_notif_dismiss, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), wm_server.info().notif_dismiss_count);
    // A malformed NOTIF_CENTER action -> EINVAL, not counted.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_notif_center, 9, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 3), wm_server.info().notif_center_count);

    // Teardown: no leaked input ownership into the aggregated binary.
    try std.testing.expect(wm_server.unregister(0));
    try std.testing.expect(!driving_award.wm_owns_input);
}

test "syscall: TOOLTIP (cmd 8, claim 6154) shows/hides the tooltip from the WM's text" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)

    // No WM registered: TOOLTIP -> ENOSYS (the ADR 0007 "no WM" case).
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_tooltip, 1, 0, 0, 0, 3 }, &frame));

    // Seed the WM as pid 0.
    try std.testing.expect(wm_server.register(0));
    // A valid text pointer (registered region) shows the tooltip immediately.
    var txt: [5]u8 = "Clock".*;
    const txt_ptr = @intFromPtr(&txt);
    set_user_regions(.{ .base = txt_ptr, .len = 5 }, .{ .base = 0, .len = 0 });
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_tooltip, 1, 0, 0, txt_ptr, 5 }, &frame));
    try std.testing.expect(driving_award.tooltip_visible);
    try std.testing.expectEqual(@as(u8, 5), driving_award.tooltip_text_len);
    try std.testing.expectEqualStrings("Clock", driving_award.tooltip_text[0..5]);
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().tooltip_count);
    // Hide (a0 = 0) clears it.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_tooltip, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!driving_award.tooltip_visible);
    try std.testing.expectEqual(@as(u8, 0), driving_award.tooltip_text_len);
    try std.testing.expectEqual(@as(u64, 2), wm_server.info().tooltip_count);
    // Over-length (> 32) / zero-length text -> EINVAL, not counted.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_tooltip, 1, 0, 0, txt_ptr, 33 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_tooltip, 1, 0, 0, txt_ptr, 0 }, &frame));
    // A bad text pointer -> EFAULT.
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = 0, .len = 0 });
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_wmctl, .{ wm_server.wmctl_tooltip, 1, 0, 0, 0x2000, 5 }, &frame));
    // A malformed action -> EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_tooltip, 9, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 2), wm_server.info().tooltip_count);

    // Teardown: no leaked input ownership into the aggregated binary.
    try std.testing.expect(wm_server.unregister(0));
    try std.testing.expect(!driving_award.wm_owns_input);
}

test "syscall: DOCK (cmd 9, claim 9197) restores/focuses through the WM's icon decision" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)

    // No WM registered: DOCK -> ENOSYS (the ADR 0007 "no WM" case).
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_dock, 0, 0, 0, 0, 0 }, &frame));

    // Seed the WM as pid 0 and open a real user window.
    try std.testing.expect(wm_server.register(0));
    const o2 = driving_award.user_open(64, 64, 400, 300, 0);
    try std.testing.expectEqual(@as(u8, 2), o2.opened);
    // Minimize it — the dock restore chain's target.
    var w2 = driving_award.find_user_window(2).?;
    w2.minimized = true;
    w2.visible = false;
    // The WM's DOCK decision (icon 0) restores + focuses it.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_dock, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!w2.minimized);
    try std.testing.expect(w2.visible);
    try std.testing.expectEqual(@as(u8, 2), driving_award.focused_window_id());
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().dock_count);
    // An out-of-range icon (the bar has 5) -> EINVAL, not counted.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_dock, 5, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().dock_count);

    // Teardown: no leaked input ownership into the aggregated binary.
    try std.testing.expect(wm_server.unregister(0));
    try std.testing.expect(!driving_award.wm_owns_input);
    _ = driving_award.user_close(2);
}

test "syscall: TRAY (cmd 10, claim 3744) stores the WM's tray widget content" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)

    // No WM registered: TRAY -> ENOSYS (the ADR 0007 "no WM" case).
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_tray, 0b111, 0, 0, 0, 0 }, &frame));

    // Seed the WM as pid 0.
    try std.testing.expect(wm_server.register(0));
    // The WM's TRAY decision: clock "12:34" packed little-endian, theme 'D',
    // clipboard filled. a0 = flags 0b111 (all three), a1 = packed clock,
    // a2 = 'D' | (1 << 8).
    const clock_packed = @as(u64, '1') | (@as(u64, '2') << 8) | (@as(u64, ':') << 16) | (@as(u64, '3') << 24) | (@as(u64, '4') << 32);
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_tray, 0b111, clock_packed, @as(u64, 'D') | (@as(u64, 1) << 8), 0, 0 }, &frame));
    try std.testing.expect(driving_award.wm_tray_clock_set);
    try std.testing.expectEqualStrings("12:34", driving_award.wm_tray_clock_text[0..5]);
    try std.testing.expect(driving_award.wm_tray_theme_set);
    try std.testing.expectEqual(@as(u8, 'D'), driving_award.wm_tray_theme);
    try std.testing.expect(driving_award.wm_tray_clip_set);
    try std.testing.expect(driving_award.wm_tray_clip);
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().tray_count);
    // A partial decision (clock only) leaves the other widgets untouched.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_tray, 0b001, clock_packed, 0, 0, 0 }, &frame));
    try std.testing.expect(driving_award.wm_tray_theme_set); // unchanged (still set)
    try std.testing.expectEqual(@as(u64, 2), wm_server.info().tray_count);
    // Unknown flag bits -> EINVAL, not counted.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_tray, 0b1000, 0, 0, 0, 0 }, &frame));
    // A non-HH:MM clock char -> EINVAL ('Z' in slot 0).
    const bad2 = (@as(u64, 'Z') << 0) | (@as(u64, '1') << 8);
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_tray, 0b001, bad2, 0, 0, 0 }, &frame));
    // A theme letter outside D/L/A -> EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_tray, 0b010, 0, 'Z', 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 2), wm_server.info().tray_count);

    // Teardown: no leaked input ownership into the aggregated binary, and the
    // WM's tray content dies with it (clear_wm_chrome resets the _set flags).
    try std.testing.expect(wm_server.unregister(0));
    try std.testing.expect(!driving_award.wm_owns_input);
    try std.testing.expect(!driving_award.wm_tray_clock_set);
    try std.testing.expect(!driving_award.wm_tray_theme_set);
    try std.testing.expect(!driving_award.wm_tray_clip_set);
}

test "syscall: DIALOG (cmd 11, claim 9980) applies the WM's about-dialog decision" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)

    // No WM registered: DIALOG -> ENOSYS (the ADR 0007 "no WM" case).
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 2, 0, 0, 0, 0 }, &frame));

    // Seed the WM as pid 0.
    try std.testing.expect(wm_server.register(0));
    try std.testing.expect(!driving_award.about_dialog_open);
    // The WM's DIALOG decision: a0=1 OPEN opens the about dialog.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 1, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(driving_award.about_dialog_open);
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().dialog_count);
    // a0=2 TOGGLE closes it (was open) — parity with the shim's self-toggle.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 2, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!driving_award.about_dialog_open);
    try std.testing.expectEqual(@as(u64, 2), wm_server.info().dialog_count);
    // a0=0 CLOSE is a no-op when already closed but still counted (an applied
    // decision), and a0=9 is EINVAL (not counted).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 3), wm_server.info().dialog_count);
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 9, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 3), wm_server.info().dialog_count);

    // Teardown: no leaked input ownership into the aggregated binary.
    try std.testing.expect(wm_server.unregister(0));
    try std.testing.expect(!driving_award.wm_owns_input);
    try std.testing.expect(!driving_award.about_dialog_open); // teardown restores
}

test "syscall: DIALOG (cmd 11, claim 6155) applies the WM's unsaved-dialog decision" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)

    // Seed the WM as pid 0, arm the compositor seam, and open a real user
    // window (id 2) — arm() makes this test standalone (the dock test relies
    // on a prior test having armed it).
    driving_award.arm();
    try std.testing.expect(wm_server.register(0));
    const o2 = driving_award.user_open(64, 64, 400, 300, 0);
    try std.testing.expectEqual(@as(u8, 2), o2.opened);
    const id2: u8 = 2;

    // No WM -> ENOSYS is covered by the about test; here a0=3 SHOW opens the
    // unsaved dialog for the target window (a WM decision, applied).
    try std.testing.expect(!driving_award.unsaved_dialog_is_open());
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 3, id2, 0, 0, 0 }, &frame));
    try std.testing.expect(driving_award.unsaved_dialog_is_open());
    // A show for an unknown window -> EINVAL, not counted.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 3, 99, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().dialog_count);
    // a0=5 DONT_SAVE closes the target window (the WM's discard decision).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 5, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!driving_award.unsaved_dialog_is_open());
    try std.testing.expect(driving_award.find_user_window(id2) == null);
    try std.testing.expectEqual(@as(u64, 2), wm_server.info().dialog_count);
    // Review fix (claim 7639): with the dialog CLOSED, the button actions
    // 4/5/6 are EINVAL (the stale BSS-zero target stays unreachable) and are
    // NOT counted — the shim's click path returned `.none` first.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 6, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 5, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 2), wm_server.info().dialog_count);
    // a0=4 SAVE posts WIN_UNSAVED to the owner and leaves the window open.
    const o3 = driving_award.user_open(64, 64, 400, 300, 0);
    // The freed slot is reused, so the second open gets id 2 again.
    try std.testing.expectEqual(@as(u8, 2), o3.opened);
    const id3: u8 = o3.opened;
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 3, id3, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!driving_award.unsaved_dialog_is_open());
    try std.testing.expect(driving_award.find_user_window(id3) != null); // save keeps the window
    try std.testing.expectEqual(@as(u64, 4), wm_server.info().dialog_count);

    // Teardown: no leaked input ownership into the aggregated binary.
    try std.testing.expect(wm_server.unregister(0));
    try std.testing.expect(!driving_award.wm_owns_input);
}

test "syscall: sys_wmctl tab subcommands (cmd 18/19/20, issue #782) validate IDs and record decisions" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)

    // No WM registered: returns ENOSYS
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_attach_tab, 2, 3, 0, 0, 0 }, &frame));

    // Register WM as pid 0
    try std.testing.expect(wm_server.register(0));

    // Valid attach: child 2, parent 3
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_attach_tab, 2, 3, 0, 0, 0 }, &frame));
    // Invalid attach: same id or out of bounds
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_attach_tab, 2, 2, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_attach_tab, 0x100, 3, 0, 0, 0 }, &frame));

    // Valid activate: tab 2
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_activate_tab, 2, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_activate_tab, 0x100, 0, 0, 0, 0 }, &frame));

    // Valid detach: tab 2
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_detach_tab, 2, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_detach_tab, 0x100, 0, 0, 0, 0 }, &frame));

    // M37 DQ2 (issue #840): the recording hooks mirror validated calls
    // into driving_award without changing validation — unknown ids are
    // defensive no-ops (no phantom grouping state).
    try std.testing.expectEqual(@as(u8, 0), driving_award.tab_parent_of(2));
    try std.testing.expectEqual(@as(u8, 0), driving_award.tab_parent_of(3));

    // Teardown
    try std.testing.expect(wm_server.unregister(0));
}

test "syscall: wait_event block+wake preserves the event buffer across the svc re-execution (claim 6359)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = boot payload (pid 0)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    var ev_buf: [16]u8 align(16) = undefined;
    const buf_addr = @intFromPtr(&ev_buf);
    // The caller: a registered process whose TCB stack region covers the
    // host test buffer, so the re-executed svc's copy_out is both range-
    // valid and dereferenceable (register_exec_user arms the TCB regions
    // from its stack_va/stack_len arguments).
    const caller_pid = process.create("CALLER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const caller_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, buf_addr, ev_buf.len, &kstack, 0, 0).?;
    _ = process.bind(caller_pid, caller_task);
    scheduler.start();
    events.init();
    events.on_event_pushed = scheduler.wake_event_waiters;
    // Drive to the caller (task 3).
    try std.testing.expect(scheduler.yield_current()); // shell -> boot payload
    try std.testing.expect(scheduler.yield_current()); // boot -> caller
    try std.testing.expectEqual(caller_task, scheduler.current_id());

    // Stand in for the caller's SVC frame: x0 = the event buffer address,
    // x8 = sys_wait_event (the svc re-execution contract).
    var caller = fresh_frame();
    try std.testing.expect(exceptions.frame_write(&caller, 8, sys_wait_event));
    try std.testing.expect(exceptions.frame_write(&caller, 0, buf_addr));
    exceptions.resume_frame[0] = @intFromPtr(&caller);

    // 1. Empty queue: handle_svc blocks the caller. With the #2093 fix
    // the dispatch's trailing write is SKIPPED for a parked frame —
    // x0 keeps the event-buffer address the re-executed svc needs (the
    // historical handle_svc write had already been neutralised by the
    // claim-6359 stash/restore; now no post-park write exists at all).
    try std.testing.expect(handle_svc(&caller, svc_immediate));
    try std.testing.expectEqual(@as(u64, buf_addr), exceptions.frame_read(&caller, 0));
    try std.testing.expect(scheduler.is_blocked(caller_task));

    // 2. An event arrives: the push hook wakes the waiter and patches the
    // saved frame's x0 back to the event-buffer address (claim 6359 fix).
    events.push(caller_pid, .{
        .kind = events.KEY_DOWN,
        .flags = 0,
        .seq = 0,
        .arg0 = 0x04,
        .arg1 = 'A',
    });
    try std.testing.expect(!scheduler.is_blocked(caller_task));
    try std.testing.expectEqual(@as(u64, buf_addr), exceptions.frame_read(&caller, 0));

    // 3. The ring resumes the caller: the svc re-executes with x0 restored
    // and the event copies out (the re-executed handler returns 1).
    try std.testing.expect(scheduler.yield_current()); // idle
    try std.testing.expect(scheduler.yield_current()); // shell
    try std.testing.expect(scheduler.yield_current()); // boot -> caller
    try std.testing.expectEqual(caller_task, scheduler.current_id());
    try std.testing.expect(handle_svc(&caller, svc_immediate));
    try std.testing.expectEqual(@as(u64, 1), exceptions.frame_read(&caller, 0));
    try std.testing.expectEqual(@as(usize, 0), events.pending(caller_pid));
    const got_kind = std.mem.readInt(u16, ev_buf[0..2], .little);
    const got_arg0 = std.mem.readInt(u32, ev_buf[8..12], .little);
    try std.testing.expectEqual(events.KEY_DOWN, got_kind);
    try std.testing.expectEqual(@as(u32, 0x04), got_arg0);
}

test "syscall: tcp connect, send, recv, close slots 30..33 and sys_kill slot 29" {
    userspace.init();
    init(test_writer);
    var frame = fresh_frame();

    // Slot 29: sys_kill on invalid process ID returns EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_kill, .{ 999, 0, 0, 0, 0, 0 }, &frame));

    // Slot 30: sys_tcp_connect with port 0 or >0xffff returns EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_tcp_connect, .{ 0x0a000002, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_tcp_connect, .{ 0x0a000002, 0x10000, 0, 0, 0, 0 }, &frame));

    // Slot 31: sys_tcp_send when not connected returns EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_tcp_send, .{ 0x1000, 5, 0, 0, 0, 0 }, &frame));

    // Slot 32: sys_tcp_recv when not connected returns EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_tcp_recv, .{ 0x1000, 64, 0, 0, 0, 0 }, &frame));

    // Slot 33: sys_tcp_close when idle returns 0
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_tcp_close, .{ 0, 0, 0, 0, 0, 0 }, &frame));
}

fn test_net_read8(_: u32) u8 {
    return 0;
}
fn test_net_read16(_: u32) u16 {
    return 0;
}
fn test_net_read32(_: u32) u32 {
    return 0;
}
fn test_net_write8(_: u32, _: u8) void {}
fn test_net_write16(_: u32, _: u16) void {}
fn test_net_write32(_: u32, _: u32) void {}
fn test_net_notify(q: u16) void {
    _ = q;
    virtio_net.net_dev.tx_used.idx = virtio_net.net_dev.tx_avail.idx;
}
fn test_net_to_phys(va: usize) u64 {
    return va;
}
fn test_net_clean(_: usize, _: usize) void {}
fn test_net_invalidate(_: usize, _: usize) void {}

fn test_net_ops() virtio_net.Ops {
    return .{
        .dev_read32 = test_net_read32,
        .cfg_read8 = test_net_read8,
        .cfg_read16 = test_net_read16,
        .cfg_read32 = test_net_read32,
        .cfg_write8 = test_net_write8,
        .cfg_write16 = test_net_write16,
        .cfg_write32 = test_net_write32,
        .notify = test_net_notify,
        .to_phys = test_net_to_phys,
        .clean = test_net_clean,
        .invalidate = test_net_invalidate,
    };
}

fn native_inject(port: u16, flags: u8, seq: u32, ack: u32, payload: []const u8) void {
    var segment: [tcp.segment_max]u8 = undefined;
    const len = tcp.build_segment(&segment, .{ 10, 0, 0, 2 }, .{ 10, 0, 0, 1 }, port, 8090, seq, ack, flags, payload);
    var frame: [tcp.frame_max]u8 = undefined;
    const n = tcp.build_frame(&frame, &.{ 2, 0, 0, 0, 0, 2 }, .{ 10, 0, 0, 2 }, .{ 2, 0, 0, 0, 0, 1 }, .{ 10, 0, 0, 1 }, segment[0..len]);
    var scratch: [128]u8 = undefined;
    _ = virtio_net.ipv4.handle_rx(frame[0..n], &.{ 2, 0, 0, 0, 0, 1 }, &scratch);
}

test "B6 syscall: native routing two handles ownership EFAULT partial reads reset timeout cleanup" {
    const ns = syscall.native_socket;
    ns.sockets = .{};
    ns.dns = null;
    ns.test_now = 0;
    defer {
        ns.sockets = .{};
        ns.dns = null;
        ns.test_now = 0;
    }
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    try std.testing.expect(scheduler.yield_current());
    const pid = process.find_by_task(scheduler.current_id()).?;
    const saved = virtio_net.net_ops;
    virtio_net.net_ops = test_net_ops();
    defer virtio_net.net_ops = saved;
    virtio_net.net_ready = true;
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    tcp.reset();
    defer {
        virtio_net.net_ready = false;
        virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
        tcp.reset();
    }
    var output: [32]u8 = undefined;
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = @intFromPtr(&output), .len = output.len });
    var frame = fresh_frame();
    const listen = dispatch(80, .{ 0, 0, 8090, 0, 0, 0 }, &frame);
    try std.testing.expect(@as(i64, @bitCast(listen)) > 0);
    try std.testing.expectEqual(@as(u64, 0), dispatch(80, .{ 5, listen, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enospc), dispatch(80, .{ 0, 0, 8091, 0, 0, 0 }, &frame));
    for (0..2) |i| {
        const port: u16 = @intCast(5000 + i);
        native_inject(port, tcp.flag_syn, 10, 0, "");
        _ = dispatch(80, .{ 5, listen, 0, 0, 0, 0 }, &frame);
        const c = ns.sockets.children[i].?;
        try std.testing.expect(c.tx_started);
        native_inject(port, tcp.flag_ack, 11, c.snd_nxt, "abcdef");
    }
    const a = dispatch(80, .{ 1, listen, 0, 0, 0, 0 }, &frame);
    const b = dispatch(80, .{ 1, listen, 0, 0, 0, 0 }, &frame);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(u64, 3), dispatch(80, .{ 11, 0, 0, 0, 0, 0 }, &frame));
    native_inject(6000, tcp.flag_syn, 30, 0, "");
    try std.testing.expectEqual(@as(u64, 1), ns.sockets.counters.capacity_refused);
    try std.testing.expectError(error.AccessDenied, ns.ready(pid + 1, .{ .value = a }));
    try std.testing.expectEqual(error_result(.efault), dispatch(80, .{ 2, a, 0, 2, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 6), ns.sockets.children[0].?.rx_len);
    try std.testing.expectEqual(@as(u64, 0), dispatch(80, .{ 2, a, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.ebadf), dispatch(80, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    {
        const previous = uaccess.resolve_write_pages;
        defer uaccess.resolve_write_pages = previous;
        uaccess.resolve_write_pages = &struct {
            fn refuse(_: u64, _: usize) bool {
                return false;
            }
        }.refuse;
        try std.testing.expectEqual(error_result(.efault), dispatch(80, .{ 2, a, @intFromPtr(&output), 2, 0, 0 }, &frame));
        try std.testing.expectEqual(@as(usize, 6), ns.sockets.children[0].?.rx_len);
    }
    try std.testing.expectEqual(@as(u64, 2), dispatch(80, .{ 2, a, @intFromPtr(&output), 2, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("ab", output[0..2]);
    native_inject(5000, tcp.flag_rst | tcp.flag_ack, 17, ns.sockets.children[0].?.snd_nxt, "");
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -13))), dispatch(80, .{ 2, a, @intFromPtr(&output), 1, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(80, .{ 4, a, 0, 0, 0, 0 }, &frame));
    ns.test_now = ns.core.deadline_ns;
    try std.testing.expectEqual(error_result(.etimedout), dispatch(80, .{ 2, b, @intFromPtr(&output), 1, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 9), dispatch(80, .{ 5, b, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(80, .{ 4, b, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.ebadf), dispatch(80, .{ 5, b, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(80, .{ 4, listen, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), ns.ownedCount(pid));
}

test "B6 DNS service: ownership source ID exclusive UDP seat timeout and release" {
    const ns = syscall.native_socket;
    ns.sockets = .{};
    ns.dns = null;
    ns.test_now = 0;
    udp.reset();
    defer {
        ns.sockets = .{};
        ns.dns = null;
        ns.test_now = 0;
        udp.reset();
    }
    var query: [17]u8 = @splat(0);
    query[0] = 1;
    query[1] = 2;
    const h = try ns.beginDns(7, .{ 10, 0, 0, 2 }, &query);
    try std.testing.expect(!udp.listen_port(ns.dns_port));
    try std.testing.expectError(error.Capacity, ns.beginDns(8, .{ 10, 0, 0, 2 }, &query));
    var output: [64]u8 = undefined;
    try std.testing.expectError(error.AccessDenied, ns.readDns(8, h, &output));
    var reply: [12]u8 = @splat(0);
    reply[0] = 1;
    reply[1] = 2;
    reply[2] = 0x81;
    var packet: [128]u8 = undefined;
    reply[1] = 3;
    const wrong_id_len = udp.build_frame_ex(&packet, .{ 2, 0, 0, 0, 0, 1 }, &.{ 2, 0, 0, 0, 0, 2 }, .{ 10, 0, 0, 2 }, .{ 10, 0, 0, 1 }, 53, ns.dns_port, &reply);
    try std.testing.expect(ns.receiveDns(packet[0..wrong_id_len]));
    try std.testing.expectError(error.WouldBlock, ns.readDns(7, h, &output));
    reply[1] = 2;
    for ([_][4]u8{ .{ 10, 0, 0, 3 }, .{ 10, 0, 0, 2 } }) |source| {
        const n = udp.build_frame_ex(&packet, .{ 2, 0, 0, 0, 0, 1 }, &.{ 2, 0, 0, 0, 0, 2 }, source, .{ 10, 0, 0, 1 }, 53, ns.dns_port, &reply);
        try std.testing.expect(ns.receiveDns(packet[0..n]));
        if (source[3] == 3) try std.testing.expectError(error.WouldBlock, ns.readDns(7, h, &output));
    }
    try std.testing.expectEqual(@as(usize, 12), try ns.readDns(7, h, &output));
    try ns.close(7, h);
    try std.testing.expect(!udp.is_listening(ns.dns_port));
    try std.testing.expect(udp.listen_port(ns.dns_port));
    try std.testing.expectError(error.Capacity, ns.beginDns(7, .{ 10, 0, 0, 2 }, &query));
    try std.testing.expect(udp.close_port(ns.dns_port));
    const next = try ns.beginDns(7, .{ 10, 0, 0, 2 }, &query);
    try std.testing.expect(next.value != h.value);
    try std.testing.expectError(error.InvalidHandle, ns.close(7, h));
    ns.test_now = ns.core.deadline_ns;
    ns.poll();
    try std.testing.expectEqual(@as(u64, 1), try ns.ready(7, next));
    try std.testing.expectError(error.TimedOut, ns.readDns(7, next, &output));
    ns.closeOwner(7);
    try std.testing.expect(!udp.is_listening(ns.dns_port));
    try std.testing.expectEqual(@as(u64, 0), ns.ownedCount(7));
}

test "B6 scheduler: real process exit releases listener half-open children and DNS transaction" {
    const ns = syscall.native_socket;
    ns.sockets = .{};
    ns.dns = null;
    ns.test_now = 0;
    udp.reset();
    defer udp.reset();
    defer {
        ns.sockets = .{};
        ns.dns = null;
    }
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    try std.testing.expect(scheduler.yield_current());
    const pid = process.find_by_task(scheduler.current_id()).?;
    _ = try ns.sockets.listen(pid, .{ .ip = .{ 10, 0, 0, 1 }, .port = 8090 }, 0);
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    defer virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    native_inject(5000, tcp.flag_syn, 10, 0, "");
    _ = try ns.beginDns(pid, .{ 10, 0, 0, 2 }, "x" ** 17);
    try std.testing.expectEqual(@as(u64, 3), ns.ownedCount(pid));
    try std.testing.expect(scheduler.exit_current(0));
    try std.testing.expectEqual(@as(u64, 0), ns.ownedCount(pid));
    try std.testing.expect(ns.sockets.listener == null and ns.dns == null);
}

test "syscall: sys_tcp_connect timeout aborts cleanly and increments timed_out" {
    userspace.init();
    init(test_writer);
    var frame = fresh_frame();

    const saved_ops = virtio_net.net_ops;
    virtio_net.net_ops = test_net_ops();
    defer virtio_net.net_ops = saved_ops;

    virtio_net.net_ready = true;
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    virtio_net.arp.upsert(.{ 10, 0, 0, 2 }, .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 });
    tcp.reset();
    const initial_timeouts = tcp.timed_out;

    // Connect to peer that never responds in test mode
    const rc = dispatch(sys_tcp_connect, .{ 0x0a000002, 80, 0, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(error_result(.einval), rc);
    try std.testing.expectEqual(tcp.State.idle, tcp.state);
    try std.testing.expectEqual(initial_timeouts + 1, tcp.timed_out);

    tcp.reset();
    virtio_net.net_ready = false;
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
}

test "syscall: TCP connection is process-owned — non-owner send/recv/close/connect refused EACCES (claim 4482)" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const peer_pid = process.create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const peer_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(peer_pid, peer_task);
    scheduler.start();

    var test_buf: [64]u8 = undefined;
    const test_buf_addr = @intFromPtr(&test_buf);
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = test_buf_addr, .len = test_buf.len },
    );
    var frame = fresh_frame();

    // Simulate process 0 (task 2) owning an ESTABLISHED connection to
    // 10.0.0.2:9999 (the net bits so the idempotent-connect path is
    // reachable; nothing transmits on the host).
    tcp.reset();
    tcp.state = .established;
    tcp.peer_ip = .{ 10, 0, 0, 2 };
    tcp.peer_port = 9999;
    tcp.owner_pid = 0;
    virtio_net.net_ready = true;
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };

    // Drive the ring to the non-owner (task 3 = process 1).
    try std.testing.expect(scheduler.yield_current()); // shell -> user (task 2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.yield_current()); // user -> peer (task 3)
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 1), peer_pid);

    // Non-owner: every connection-driving syscall is refused EACCES before
    // any state is touched (the S4 ownership audit fix).
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_tcp_send, .{ test_buf_addr, 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_tcp_recv, .{ test_buf_addr, 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_tcp_close, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    // Idempotent re-connect to the same peer is owner-only.
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_tcp_connect, .{ 0x0a000002, 9999, 0, 0, 0, 0 }, &frame));
    // The refused calls never mutated the connection.
    try std.testing.expectEqual(@as(u64, 0), tcp.owner_pid.?);

    // Drive the ring back to the owner (task 2): the idempotent re-connect
    // succeeds (returns 0, no transmit) — the ownership check passes.
    try std.testing.expect(scheduler.yield_current()); // peer -> idle
    try std.testing.expect(scheduler.yield_current()); // idle -> shell
    try std.testing.expect(scheduler.yield_current()); // shell -> user (task 2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_tcp_connect, .{ 0x0a000002, 9999, 0, 0, 0, 0 }, &frame));

    tcp.rx_payload[0..6].* = "abcdef".*;
    tcp.rx_len = 6;
    tcp.rx_pending = true;
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_tcp_recv, .{ 0, 2, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 6), tcp.rx_len);
    try std.testing.expectEqual(@as(u64, 2), dispatch(sys_tcp_recv, .{ test_buf_addr, 2, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("ab", test_buf[0..2]);
    try std.testing.expectEqual(@as(usize, 4), tcp.rx_len);
    try std.testing.expect(tcp.rx_pending);
    try std.testing.expect(tcp.ready_mask() & 1 != 0);
    try std.testing.expectEqualStrings("cdef", tcp.rx_payload[0..tcp.rx_len]);
    try std.testing.expectEqual(@as(u64, 4), dispatch(sys_tcp_recv, .{ test_buf_addr, test_buf.len, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("cdef", test_buf[0..4]);
    try std.testing.expectEqual(@as(usize, 0), tcp.rx_len);
    try std.testing.expect(!tcp.rx_pending);
    try std.testing.expect(tcp.ready_mask() & 1 == 0);

    // Restore the honest default (net absent).
    tcp.reset();
    virtio_net.net_ready = false;
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
}

test "syscall: slot 42 sys_audio_info marshals; slot 43 sys_audio_play refuses without a device" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    virtio_snd.snd_ready = false; // honest default — no --sound device in a test
    virtio_snd.ctrl_armed = false;
    virtio_snd.tx_armed = false;
    var frame = fresh_frame();

    // In task 0 (shell, not a registered process), both audio syscalls are
    // refused EINVAL before any state is touched.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_audio_info, .{ 0x1000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_audio_play, .{ 0x1000, 8, 0, 0, 0, 0 }, &frame));

    // Yield to the user task (task 2, pid 0).
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(process.find_by_task(2) != null);

    var info_buf: [32]u8 = @splat(0);
    const info_addr = @intFromPtr(&info_buf);
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = info_addr, .len = info_buf.len },
    );

    // Bad info buffer -> EFAULT.
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_audio_info, .{ uaccess.diagnostic_unmapped, 0, 0, 0, 0, 0 }, &frame));

    // Valid buffer: the info struct is copied out with the honest no-device
    // state (ready=0, format/rate 0xff — never guessed).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_audio_info, .{ info_addr, 0, 0, 0, 0, 0 }, &frame));
    const info: *const virtio_snd.AudioInfo = @ptrCast(@alignCast(&info_buf));
    try std.testing.expectEqual(@as(u32, 0), info.ready);
    try std.testing.expectEqual(@as(u8, 0xff), info.format);
    try std.testing.expectEqual(@as(u8, 0xff), info.rate);
    try std.testing.expectEqual(@as(u32, virtio_snd.audio_max_len), info.max_len);

    // sys_audio_play arg validation before the device check: zero length ->
    // EINVAL, over-long -> ENAMETOOLONG, then the honest no-device ENXIO.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_audio_play, .{ info_addr, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enametoolong), dispatch(sys_audio_play, .{ info_addr, virtio_snd.audio_max_len + 1, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enxio), dispatch(sys_audio_play, .{ info_addr, 8, 0, 0, 0, 0 }, &frame));

    // Restore the honest default.
    virtio_snd.snd_ready = false;
}

test "syscall: slots 44/45 — sys_audio_volume/sys_audio_mute are bounded and process-only (claim 9297)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();

    // Defaults: full volume, unmuted — the honest out-of-the-box stream.
    virtio_snd.stream_volume = 100;
    virtio_snd.stream_muted = false;

    // In task 0 (shell, not a registered process), both are refused EINVAL
    // before any state is touched.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_audio_volume, .{ 50, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_audio_mute, .{ 1, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u8, 100), virtio_snd.stream_volume);
    try std.testing.expect(!virtio_snd.stream_muted);

    // Yield to the user task (task 2, pid 0).
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(process.find_by_task(2) != null);

    // Volume: bounded — 101 is refused EINVAL (no silent clamping), the
    // in-range sets return the volume.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_audio_volume, .{ 101, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 30), dispatch(sys_audio_volume, .{ 30, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u8, 30), virtio_snd.stream_volume);
    try std.testing.expectEqual(@as(u64, 100), dispatch(sys_audio_volume, .{ 100, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u8, 100), virtio_snd.stream_volume);

    // Mute: only 0/1 — anything else is EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_audio_mute, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_audio_mute, .{ 1, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(virtio_snd.stream_muted);
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_audio_mute, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!virtio_snd.stream_muted);

    // Restore the honest default.
    virtio_snd.stream_volume = 100;
    virtio_snd.stream_muted = false;
}

test "syscall: B7 device binding, atomic copy rollback, bounds, tokens and exit cleanup" {
    const pcm = virtio_snd.playback.pcm;
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    try std.testing.expect(scheduler.yield_current());
    var device = virtio_snd.playback.Fixture{};
    var current = virtio_snd.playback.Playback{};
    virtio_snd.stream = &current;
    virtio_snd.snd_ready = false;
    virtio_snd.ctrl_armed = true;
    virtio_snd.tx_armed = true;
    virtio_snd.test_stream_io = device.io();
    virtio_snd.test_stream_caps = .{ .present = true, .output = true, .queue_descriptors = 32, .formats = &.{.float32}, .rates_hz = &.{48000}, .channels_min = 1, .channels_max = 2 };
    defer {
        virtio_snd.stream = null;
        virtio_snd.test_stream_io = null;
        virtio_snd.test_stream_caps = null;
        virtio_snd.snd_ready = false;
        virtio_snd.ctrl_armed = false;
        virtio_snd.tx_armed = false;
    }
    const Memory = extern struct {
        params: virtio_snd.StreamParams,
        status: virtio_snd.StreamStatus = undefined,
        samples: [4096]u8 = @splat(0),
    };
    var memory = Memory{ .params = .{ .format = 19, .rate = 7, .channels = 2 } };
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = @intFromPtr(&memory), .len = @sizeOf(Memory) });
    var frame = fresh_frame();
    const flag = virtio_snd.audio_stream_flag;
    const request = @intFromPtr(&memory.params);
    const source = @intFromPtr(&memory.samples);
    try std.testing.expectEqual(error_result(.enxio), dispatch(43, .{ request, flag | 8, 1, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(pcm.State.closed, current.model.state);
    virtio_snd.snd_ready = true;
    memory.params.channels = 3;
    try std.testing.expectEqual(error_result(.einval), dispatch(43, .{ request, flag | 8, 1, 0, 0, 0 }, &frame));
    memory.params.channels = 2;
    try std.testing.expectEqual(error_result(.efault), dispatch(43, .{ uaccess.diagnostic_unmapped, flag | 8, 1, 0, 0, 0 }, &frame));
    const generation = dispatch(43, .{ request, flag | 8, 1, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, 1), generation);
    try std.testing.expectEqual(error_result(.eagain), dispatch(43, .{ request, flag | 8, 1, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.eagain), dispatch(43, .{ source, 8, 999, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(43, .{ 0, flag, 3, generation, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(43, .{ source, flag | 7, 2, generation, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enametoolong), dispatch(43, .{ source, flag | 4097, 2, generation, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(43, .{ source, flag | 8, 2, generation + 1, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.efault), dispatch(43, .{ uaccess.diagnostic_unmapped, flag | 4096, 2, generation, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), current.model.counts.accepted);
    for (0..8) |_| try std.testing.expectEqual(@as(u64, 4096), dispatch(43, .{ source, flag | 4096, 2, generation, 0, 0 }, &frame));
    const before = current.model.counts;
    try std.testing.expectEqual(error_result(.eagain), dispatch(43, .{ source, flag | 4096, 2, generation, 0, 0 }, &frame));
    try std.testing.expectEqual(before, current.model.counts);
    try std.testing.expectEqual(@as(u64, 0), dispatch(43, .{ 0, flag, 3, generation, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 8), current.model.owned);
    try std.testing.expectEqual(@as(u64, 0), dispatch(43, .{ @intFromPtr(&memory.status), flag | 72, 6, generation, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 32768), memory.status.accepted);
    // Real process exit, not just the model's injected death.
    try std.testing.expect(scheduler.exit_current(0));
    try std.testing.expect(current.model.owner == null);
    virtio_snd.snd_stream_poll();
    try std.testing.expectEqual(pcm.State.closed, current.model.state);
    try std.testing.expectEqual(pcm.Reason.owner_died, current.model.reason);
    try std.testing.expectEqual(@as(u64, 32768), current.model.counts.canceled);
    try std.testing.expectEqual(@as(u64, 1), current.resets);
}

var reclaim_pool: [4100 * 4096]u8 align(4096) = undefined;
var reclaim_stack: [scheduler.task_stack_size]u8 align(16) = undefined;

fn reclaimFixture(pages: u64) !struct { pid: usize, task: usize, root: u64 } {
    mmu.reset();
    alloc.reset_refcounts();
    shared_region.reset();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    const descriptors = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = @intFromPtr(&reclaim_pool), .virtual_start = 0, .number_of_pages = pages, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&descriptors), @sizeOf(memmap.MemoryDescriptor), descriptors.len);
    try std.testing.expect(alloc.init(view, &.{}));
    const root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const pid = process.create("RECLAIM", .{}, .{ .root_phys = root }, .{}).?;
    const task = scheduler.register_exec_user(userspace.text_va, 0x40000000, 64, 0x80000000, 8192, &reclaim_stack, 0, 0).?;
    try std.testing.expect(process.bind(pid, task));
    scheduler.start();
    while (scheduler.current_id() != task) try std.testing.expect(scheduler.yield_current());
    return .{ .pid = pid, .task = task, .root = root };
}

test "syscall: reclaim munmap remap and reap never frees a reallocated page" {
    const f = try reclaimFixture(8);
    var frame = fresh_frame();
    const va: u64 = 0x60000000;
    try std.testing.expectEqual(va, dispatch(sys_mmap, .{ va, 4096, 3, 0x8022, 0, 0 }, &frame));
    const pa = mmu.get_user_leaf(f.root, va).?.* & 0x0000_ffff_ffff_f000;
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_munmap, .{ va, 4096, 0, 0, 0, 0 }, &frame));
    // A different live owner acquires exactly the physical page just unmapped.
    const other_pa = alloc.alloc_pages(1).?;
    try std.testing.expectEqual(pa, other_pa);
    const other = process.create("OTHER", .{}, .{}, .{}).?;
    try std.testing.expect(process.record_dynamic_page(other, other_pa));
    // Remapping the same VA must own a different PA and release only that PA.
    try std.testing.expectEqual(va, dispatch(sys_mmap, .{ va, 4096, 3, 0x8022, 0, 0 }, &frame));
    try std.testing.expect((mmu.get_user_leaf(f.root, va).?.* & 0x0000_ffff_ffff_f000) != other_pa);
    try std.testing.expectEqual(@as(?usize, f.pid), process.on_task_exit(f.task, 0));
    try std.testing.expectEqual(@as(usize, 1), process.runtime_receipt(f.pid).?.peak_pages);
    try std.testing.expectEqual(@as(usize, 2), process.runtime_receipt(f.pid).?.total_pages);
    try std.testing.expect(process.release_pages_on_reap(f.task));
    try std.testing.expectEqual(@as(u64, 7), alloc.stats().free_pages);
    try std.testing.expect(!alloc.reserve(other_pa, 1)); // still allocated
    try std.testing.expect(process.reap(f.pid));
    try std.testing.expect(!alloc.reserve(other_pa, 1)); // descriptor reap is also safe
    try std.testing.expect(process.reap(other));
    try std.testing.expectEqual(@as(u64, 8), alloc.stats().free_pages);
}

test "syscall: reclaim populated mmap overflow returns every backing and record page" {
    const f = try reclaimFixture(4100);
    var frame = fresh_frame();
    const va: u64 = 0x60000000;
    try std.testing.expectEqual(va, dispatch(sys_mmap, .{ va, 4097 * 4096, 3, 0x8022, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 2), alloc.stats().free_pages); // 4097 backing + one metadata
    // Remove an inline record, compacting from overflow and returning metadata.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_munmap, .{ va, 4096, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 4), alloc.stats().free_pages);
    const held = alloc.alloc_pages(1).?;
    _ = process.on_task_exit(f.task, 0);
    try std.testing.expectEqual(@as(usize, 4097), process.runtime_receipt(f.pid).?.peak_pages);
    try std.testing.expect(process.release_pages_on_reap(f.task));
    try std.testing.expectEqual(@as(u64, 4099), alloc.stats().free_pages);
    try std.testing.expect(!alloc.reserve(held, 1));
    try std.testing.expect(alloc.free_pages(held, 1));
}

test "syscall: reclaim all four allocation paths unwind record storage exhaustion" {
    const f = try reclaimFixture(1);
    var frame = fresh_frame();
    for (0..process.max_dynamic_pages) |_| try std.testing.expect(process.record_dynamic_page(f.pid, 0));
    const va: u64 = 0x60000000;
    try std.testing.expectEqual(error_result(.enomem), dispatch(sys_mmap, .{ va, 4096, 3, 0x8022, 0, 0 }, &frame));
    try std.testing.expect(process.find_mmap_region(f.pid, va) == null);
    try std.testing.expect(!mmu.leaf_el0_visible(f.root, va));
    try std.testing.expectEqual(@as(u64, 1), alloc.stats().free_pages);
    try std.testing.expectEqual(error_result(.enomem), dispatch(sys_mmap, .{ va, 4096, 3, 0x10020, 0, 0 }, &frame));
    try std.testing.expect(shared_region.find_owner(f.pid, va) == null);
    try std.testing.expect(process.find_mmap_region(f.pid, va) == null);
    try std.testing.expect(!mmu.leaf_el0_visible(f.root, va));
    try std.testing.expectEqual(@as(u64, 1), alloc.stats().free_pages);
    try std.testing.expect(process.add_mmap_region(f.pid, va, 4096, 3, 0x22));
    try std.testing.expect(!exceptions.populate_user_page(f.pid, f.root, va, true));
    try std.testing.expect(!mmu.leaf_el0_visible(f.root, va));
    try std.testing.expectEqual(@as(u64, 1), alloc.stats().free_pages);
    // A borrowed COW page is outside the pool (in the refcount span, but
    // never a page the pool hands out); its private copy can allocate, but
    // no second page remains for the overflow record.
    const borrowed: u64 = @intFromPtr(&reclaim_pool) + 4096;
    try std.testing.expect(mmu.map_user_cow_page(f.root, va, borrowed));
    try std.testing.expect(alloc.ref_page(borrowed));
    try std.testing.expect(!exceptions.try_handle_page_fault((0x24 << 26) | (1 << 6) | 0xf, va));
    try std.testing.expectEqual(borrowed, mmu.get_user_leaf(f.root, va).?.* & 0x0000_ffff_ffff_f000);
    try std.testing.expectEqual(@as(u16, 2), alloc.page_refcount(borrowed));
    try std.testing.expectEqual(@as(u64, 1), alloc.stats().free_pages);
    _ = process.on_task_exit(f.task, 0);
    try std.testing.expectEqual(@as(usize, 4), process.runtime_receipt(f.pid).?.record_failures);
    try std.testing.expect(process.release_pages_on_reap(f.task));
    try std.testing.expectEqual(@as(u64, 1), alloc.stats().free_pages);
}

test "syscall: reclaim COW replacement followed by reap keeps the old owner's page" {
    const f = try reclaimFixture(8);
    var frame = fresh_frame();
    const va: u64 = 0x60000000;
    try std.testing.expectEqual(va, dispatch(sys_mmap, .{ va, 4096, 3, 0x8022, 0, 0 }, &frame));
    const old_pa = mmu.get_user_leaf(f.root, va).?.* & 0x0000_ffff_ffff_f000;
    const other = process.create("OTHER", .{}, .{}, .{}).?;
    try std.testing.expect(process.record_dynamic_page(other, old_pa));
    try std.testing.expect(alloc.ref_page(old_pa));
    try std.testing.expect(mmu.map_user_cow_page(f.root, va, old_pa));
    try std.testing.expect(exceptions.try_handle_page_fault((0x24 << 26) | (1 << 6) | 0xf, va));
    try std.testing.expect(!process.owns_dynamic_page(f.pid, old_pa));
    try std.testing.expectEqual(@as(u16, 1), alloc.page_refcount(old_pa));
    _ = process.on_task_exit(f.task, 0);
    try std.testing.expect(process.release_pages_on_reap(f.task));
    try std.testing.expectEqual(@as(u64, 7), alloc.stats().free_pages);
    try std.testing.expect(!alloc.reserve(old_pa, 1));
    try std.testing.expect(process.reap(other));
    try std.testing.expectEqual(@as(u64, 8), alloc.stats().free_pages);
}

test "syscall: reclaim borrowed COW copy leaves no stale record after peer detach" {
    const f = try reclaimFixture(8);
    const va: u64 = 0x60000000;
    const old_pa = alloc.alloc_pages(1).?;
    try std.testing.expect(mmu.map_user_cow_page(f.root, va, old_pa));
    try std.testing.expect(alloc.ref_page(old_pa));
    try std.testing.expect(exceptions.try_handle_page_fault((0x24 << 26) | (1 << 6) | 0xf, va));
    const copy = mmu.get_user_leaf(f.root, va).?.* & 0x0000_ffff_ffff_f000;
    try std.testing.expect(process.owns_dynamic_page(f.pid, copy));
    shared_mmap.unmap_peer_leaves(f.root, va, 1, old_pa);
    const held = alloc.alloc_pages(1).?;
    try std.testing.expectEqual(copy, held);
    _ = process.on_task_exit(f.task, 0);
    try std.testing.expect(process.release_pages_on_reap(f.task));
    try std.testing.expect(!alloc.reserve(held, 1));
    try std.testing.expectEqual(@as(u64, 6), alloc.stats().free_pages);
    try std.testing.expect(alloc.free_pages(held, 1));
    try std.testing.expect(alloc.unref_page(old_pa));
}

test "syscall: reclaim populated mmap mapping failure unwinds the region" {
    const f = try reclaimFixture(8);
    var frame = fresh_frame();
    const va: u64 = 0x60000000;
    try std.testing.expectEqual(error_result(.enomem), dispatch(sys_mmap, .{ va, 4096, 7, 0x8022, 0, 0 }, &frame)); // W^X refusal
    try std.testing.expect(process.find_mmap_region(f.pid, va) == null);
    try std.testing.expectEqual(@as(u64, 8), alloc.stats().free_pages);
    _ = process.on_task_exit(f.task, 0);
    try std.testing.expect(process.release_pages_on_reap(f.task));
    try std.testing.expectEqual(@as(u64, 8), alloc.stats().free_pages);
}

test "syscall: #2092 — sys_mmap refuses kernel-live and wrapping hints with EINVAL" {
    const f = try reclaimFixture(8);
    var frame = fresh_frame();

    // Fabricate a kernel-live EL1-only leaf the way map_low_identity does:
    // install an EL0 leaf under the fresh root, then strip its AP bits —
    // the descriptor shape the cloned identity overlay carries over pooled
    // RAM (Normal attr + AP=0b00 => kernel_live_leaf).
    const twin_va: u64 = 0x7000_0000;
    try std.testing.expect(mmu.map_user_page(f.root, twin_va, 0x5000_0000, true, false));
    mmu.get_user_leaf(f.root, twin_va).?.* &= ~@as(u64, 0b11 << 6);
    try std.testing.expect(!mmu.user_slot_free(f.root, twin_va));

    // The hinted mmap at the kernel-live VA is refused BEFORE a region row
    // is registered — the twin leaf survives untouched.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_mmap, .{ twin_va, 4096, 3, 0x22, 0, 0 }, &frame));
    try std.testing.expect(process.find_mmap_region(f.pid, twin_va) == null);
    try std.testing.expectEqual(@as(u64, 0), (mmu.get_user_leaf(f.root, twin_va).?.* >> 6) & 3);
    // A range SPANNING INTO the kernel-live page refuses too.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_mmap, .{ twin_va - 4096, 8192, 3, 0x22, 0, 0 }, &frame));
    try std.testing.expect(process.find_mmap_region(f.pid, twin_va - 4096) == null);

    // A hint whose va+len wraps u64 is refused at the collision check —
    // page-aligned, so it reaches mmap_collides, which must not read the
    // wrapped end as a tiny range below the apertures.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_mmap, .{ std.math.maxInt(u64) - 0xfff, 4096, 3, 0x22, 0, 0 }, &frame));
    try std.testing.expect(process.mmap_collides(f.pid, std.math.maxInt(u64) - 0xfff, 4096));

    // A clean hint in the mmap band still maps — the check refuses shadows,
    // not ordinary windows.
    try std.testing.expectEqual(@as(u64, 0x6000_0000), dispatch(sys_mmap, .{ 0x6000_0000, 4096, 3, 0x22, 0, 0 }, &frame));
    _ = process.on_task_exit(f.task, 0);
    try std.testing.expect(process.release_pages_on_reap(f.task));
}

test "syscall: #2098 — sys_exit refuses the kernel-reserved statuses" {
    mmu.reset();
    alloc.reset_refcounts();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();

    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    const task = scheduler.current_id();

    // EL0 may not forge the statuses the kernel reserves for its own
    // verdicts (OOM-kill 137, fault 139, mem-limit 140, cpu-limit 141).
    for ([_]u64{ 137, 139, 140, 141 }) |status| {
        try std.testing.expectEqual(error_result(.einval), dispatch(sys_exit, .{ status, 0, 0, 0, 0, 0 }, &frame));
        try std.testing.expectEqual(task, scheduler.current_id()); // still alive
    }
    // An ordinary status still exits — the guard refuses forgeries, not exit.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_exit, .{ 7, 0, 0, 0, 0, 0 }, &frame));
}

test "syscall: #2113 — shared-surface munmap is full-region only, whatever the overlap shape" {
    mmu.reset();
    alloc.reset_refcounts();
    shared_region.reset();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);

    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 256, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    const owner_root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const peer_root = mmu.build_user_root(userspace.text_va, 0x3000, 64, userspace.stack_va, 0x4000, 8192).?;
    var kstack1: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack2: [scheduler.task_stack_size]u8 align(16) = undefined;
    const owner_pid = process.create("OWNER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = owner_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const peer_pid = process.create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = peer_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const owner_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack1, 0, 0).?;
    const peer_task = scheduler.register_exec_user(userspace.text_va, 0x5000_0000, 100, 0x9000_0000, 8192, &kstack2, 0, 0).?;
    _ = process.bind(owner_pid, owner_task);
    _ = process.bind(peer_pid, peer_task);
    scheduler.start();

    var frame = fresh_frame();
    var guard: usize = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());

    // A TWO-page shared surface so partial ranges exist inside it.
    const owner_va = dispatch(sys_mmap, .{ 0, 8192, 3, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(owner_va >= 0x1000_0000);
    const h: u32 = 1;
    const r = shared_region.info(h).?;
    try std.testing.expectEqual(@as(u32, 2), r.page_count);
    const pa_base = r.pa_base;

    // Every partial-overlap shape is EINVAL and strips NOTHING:
    //  - a suffix inside the region,
    //  - a prefix inside the region,
    //  - a range beginning BEFORE the region that overlaps it (the old
    //    covers() bug — the start was outside, so the check never ran),
    //  - a range spanning past the region's end.
    for ([_]struct { va: u64, len: u64 }{
        .{ .va = owner_va + 4096, .len = 4096 },
        .{ .va = owner_va, .len = 4096 },
        .{ .va = owner_va - 4096, .len = 8192 },
        .{ .va = owner_va + 4096, .len = 8192 },
    }) |range| {
        try std.testing.expectEqual(error_result(.einval), dispatch(sys_munmap, .{ range.va, range.len, 0, 0, 0, 0 }, &frame));
        try std.testing.expectEqual(@as(u32, 2), shared_region.info(h).?.page_count);
        try std.testing.expect(mmu.leaf_el0_visible(owner_root, owner_va));
        try std.testing.expect(mmu.leaf_el0_visible(owner_root, owner_va + 4096));
    }
    // A wrapping len is refused before it can alias anything.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_munmap, .{ owner_va, std.math.maxInt(u64) - 0xfff, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(shared_region.info(h) != null);

    // The PEER attaches, then the same full-region rule binds its seat.
    _ = wm_server.register(peer_pid);
    guard = 0;
    while (scheduler.current_id() != peer_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(peer_task, scheduler.current_id());
    const peer_va = dispatch(sys_mmap, .{ h, 8192, 1, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(peer_va >= 0x1000_0000);
    for ([_]struct { va: u64, len: u64 }{
        .{ .va = peer_va, .len = 4096 },
        .{ .va = peer_va - 4096, .len = 8192 },
    }) |range| {
        try std.testing.expectEqual(error_result(.einval), dispatch(sys_munmap, .{ range.va, range.len, 0, 0, 0, 0 }, &frame));
        try std.testing.expect(mmu.leaf_el0_visible(peer_root, peer_va));
        try std.testing.expectEqual(@as(u64, peer_pid), shared_region.info(h).?.peer_pid);
    }
    // Exact peer detach succeeds: the peer seat drops, the owner keeps the surface.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_munmap, .{ peer_va, 8192, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(mmu.get_user_leaf(peer_root, peer_va) == null or mmu.get_user_leaf(peer_root, peer_va).?.* == 0);
    try std.testing.expectEqual(@as(u64, 0), shared_region.info(h).?.peer_pid);
    try std.testing.expect(mmu.leaf_el0_visible(owner_root, owner_va));
    _ = wm_server.unregister(peer_pid);

    // Back on the owner, exact teardown still frees the whole surface.
    guard = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_munmap, .{ owner_va, 8192, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(shared_region.info(h) == null);
    try std.testing.expect(!alloc.unref_page(pa_base)); // both pages freed, refcount honest
}

test "syscall: #2114 — a mid-attach auto-mirror failure unwinds peer leaves, refs, and the WM row" {
    mmu.reset();
    alloc.reset_refcounts();
    shared_region.reset();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    driving_award.arm();

    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 256, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    const owner_root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const wm_root = mmu.build_user_root(userspace.text_va, 0x3000, 64, userspace.stack_va, 0x4000, 8192).?;
    var kstack1: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack2: [scheduler.task_stack_size]u8 align(16) = undefined;
    const owner_pid = process.create("APP.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = owner_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const wm_pid = process.create("WM.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = wm_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const owner_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack1, 0, 0).?;
    const wm_task = scheduler.register_exec_user(userspace.text_va, 0x5000_0000, 100, 0x9000_0000, 8192, &kstack2, 0, 0).?;
    _ = process.bind(owner_pid, owner_task);
    _ = process.bind(wm_pid, wm_task);
    scheduler.start();

    var frame = fresh_frame();
    var guard: usize = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());
    _ = wm_server.register(wm_pid);

    // Plant a kernel-live EL1-only leaf mid-way through the range the WM's
    // auto-mirror would take: the WM's first next_mmap_va is
    // mmap_default_va, and map_peer_leaves installs pages sequentially —
    // page 0-2 land, page 3 refuses, and the whole attempt must unwind.
    const fail_va = process.mmap_default_va + 3 * 4096;
    try std.testing.expect(mmu.map_user_page(wm_root, fail_va, 0x5100_0000, true, false));
    mmu.get_user_leaf(wm_root, fail_va).?.* &= ~@as(u64, 0b11 << 6); // EL1-only
    const wm_rows_before = live_mmap_rows(wm_pid);
    const free_before = alloc.stats().free_pages;

    const wid = dispatch(sys_win_open, .{ 64, 64, 128, 96, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, 2), wid);
    const surf_len: u64 = 128 * 96 * 4; // 12 pages
    const bound = dispatch(sys_mmap, .{ m33_surf_win_tag | wid, surf_len, 3, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expectEqual(error_result(.enomem), bound);

    // Zero peer leaves survive and zero elevated refs — the three installed
    // pages are unmapped AND unref'd (each back to the owner's sole ref).
    const r = shared_region.info(1).?;
    for (0..3) |i| {
        try std.testing.expect(mmu.get_user_leaf(wm_root, process.mmap_default_va + @as(u64, i) * 4096) == null or
            mmu.get_user_leaf(wm_root, process.mmap_default_va + @as(u64, i) * 4096).?.* == 0);
        try std.testing.expectEqual(@as(u16, 1), alloc.page_refcount(r.pa_base + @as(u64, i) * 4096));
    }
    // The failed page kept its single owner ref — the double-unref would
    // have freed a page the owner still maps.
    try std.testing.expectEqual(@as(u16, 1), alloc.page_refcount(r.pa_base + 3 * 4096));
    // No peer seat, no WM region row, no phantom read grant.
    try std.testing.expectEqual(@as(u64, 0), r.peer_pid);
    try std.testing.expectEqual(wm_rows_before, live_mmap_rows(wm_pid));
    try std.testing.expectEqual(@as(u32, 0), shared_region.read_count(1));
    // The owner surface itself stays live and bound — the caller's error
    // was honest, and owner teardown still frees every page exactly once.
    try std.testing.expect(driving_award.user_is_surface_backed(@intCast(wid)));
    try std.testing.expect(mmu.leaf_el0_visible(owner_root, r.owner_va));
    try std.testing.expect(alloc.stats().free_pages < free_before); // only the surface pages are gone

    // Owner exit through the real seam frees every page exactly once —
    // close_owner ends the bound window, revoke_owner drops the region,
    // and the reap unrefs the owner's charge (12 surface pages return).
    try std.testing.expect(scheduler.exit_current(0));
    try std.testing.expect(process.release_pages_on_reap(owner_task));
    var pg: u64 = 0;
    while (pg < r.page_count) : (pg += 1) {
        // free now — reserve flips it allocated, freeing returns the probe.
        try std.testing.expect(alloc.reserve(r.pa_base + pg * 4096, 1));
        try std.testing.expect(alloc.free_pages(r.pa_base + pg * 4096, 1));
    }
    try std.testing.expectEqual(free_before, alloc.stats().free_pages);

    _ = wm_server.unregister(wm_pid);
}

test "syscall: #2115 — the memory rlimit charges demand pages, refuses at the ceiling, and drops on free" {
    const f = try reclaimFixture(8);
    var frame = fresh_frame();
    const pid = f.pid;

    // setrlimit(0, 2) through the syscall gate — process.current() is the
    // fixture's pid (no later create has moved it yet).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_setrlimit, .{ 0, 2, 0, 0, 0, 0 }, &frame));

    // Usage starts clean; other processes stay unaffected throughout.
    const other = process.create("OTHER", .{}, .{}, .{}).?;
    try std.testing.expectEqual(@as(u64, 0), process.getrusage(pid).?.mem_usage);
    try std.testing.expectEqual(@as(u64, 0), process.getrusage(other).?.mem_usage);

    // A MAP_POPULATE mmap charges every page it installs: two fit the
    // ceiling, so the call succeeds and usage reflects the charge.
    const va: u64 = 0x6000_0000;
    try std.testing.expectEqual(va, dispatch(sys_mmap, .{ va, 2 * 4096, 3, 0x8022, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 2), process.getrusage(pid).?.mem_usage);

    // The next charged page is refused at the ceiling — the populate
    // unwinds ALL of it (region row gone, leaves gone, usage unchanged)
    // and reports ENOMEM, while the refusal is named for the 140 verdict.
    try std.testing.expectEqual(error_result(.enomem), dispatch(sys_mmap, .{ va + 0x2000, 4096, 3, 0x8022, 0, 0 }, &frame));
    try std.testing.expect(process.find_mmap_region(pid, va + 0x2000) == null);
    try std.testing.expect(!mmu.leaf_el0_visible(f.root, va + 0x2000));
    try std.testing.expectEqual(@as(u64, 2), process.getrusage(pid).?.mem_usage);
    try std.testing.expect(process.mem_limit_refused(pid));
    try std.testing.expectEqual(@as(u64, 0), process.getrusage(other).?.mem_usage);

    // Demand populate of a RESERVED region also refuses at the ceiling —
    // populate, not reservation, is where the charge lands.
    const va2: u64 = 0x6100_0000;
    try std.testing.expectEqual(va2, dispatch(sys_mmap, .{ va2, 4096, 3, 0x22, 0, 0 }, &frame));
    try std.testing.expect(!exceptions.populate_user_page(pid, f.root, va2, true));
    try std.testing.expect(!mmu.leaf_el0_visible(f.root, va2));

    // Freeing pages drops the charge: munmap of the populated region
    // returns usage to 0 and re-arms the limit (mem_refused stays latched
    // until the next setrlimit re-arms it).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_munmap, .{ va, 2 * 4096, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), process.getrusage(pid).?.mem_usage);

    // Below the ceiling again, charging resumes — and a fresh setrlimit
    // re-arms the 140 verdict flag.
    try std.testing.expectEqual(va, dispatch(sys_mmap, .{ va, 4096, 3, 0x8022, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), process.getrusage(pid).?.mem_usage);
    try std.testing.expect(process.setrlimit(pid, 0, 4));
    try std.testing.expect(!process.mem_limit_refused(pid));

    _ = process.on_task_exit(f.task, 0);
    try std.testing.expect(process.release_pages_on_reap(f.task));
    try std.testing.expect(process.reap(other));
}

test "syscall: sys_mmap and sys_munmap anonymous allocation and teardown" {
    mmu.reset();
    alloc.reset_refcounts();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();

    var frame = fresh_frame();

    // In task 0 (shell), calls return EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_mmap, .{ 0, 4096, 3, 0x22, 0, 0 }, &frame));

    // Yield to user task (task 2, pid 0)
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    // mmap 8192 bytes
    const mapped_va = dispatch(sys_mmap, .{ 0, 8192, 3, 0x22, 0, 0 }, &frame);
    try std.testing.expect(mapped_va >= 0x1000_0000);
    try std.testing.expectEqual(@as(u64, 2), call_count(sys_mmap));

    // munmap the region
    const unmap_res = dispatch(sys_munmap, .{ mapped_va, 8192, 0, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, 0), unmap_res);
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_munmap));

    // Invalid munmap (unaligned addr)
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_munmap, .{ mapped_va + 1, 4096, 0, 0, 0, 0 }, &frame));
}

test "syscall: mmap visibility survives past the old 6-slot TCB cap (issue #1163 A1)" {
    mmu.reset();
    alloc.reset_refcounts();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();

    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    // Eight prot-RW mappings: the OLD extra capacity (6) silently dropped
    // the 7th/8th TCB registrations and the 8-slot module list overflowed —
    // file round-trips into the 7th+ heap buffer EFAULTed invisibly. Since
    // ADR 0027's review the mappings live on the PROCESS registry and arm
    // from there; the last mapping must still be visible.
    var last_va: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const va = dispatch(sys_mmap, .{ 0, 4096, 3, 0x22, 0, 0 }, &frame);
        try std.testing.expect(va >= 0x1000_0000);
        last_va = va;
    }

    // Re-arm exactly as handle_svc does at every SVC entry, then the LAST
    // mapping must be visible to copy_in's region check.
    syscall.arm_task_regions();
    try std.testing.expect(uaccess.read_region_covers(last_va, 8));
}

test "syscall: mmap capacity is PROCESS-scope, not the calling task's TCB (ADR 0027 review)" {
    mmu.reset();
    alloc.reset_refcounts();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();

    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    // The task TCB extras are full (the old pre-check refused here). Since
    // the fix, mmap consumes no TCB slot: the mapping registers on the
    // process and arms from there, so it must succeed and be visible.
    var i: usize = 0;
    while (i < scheduler.extra_region_capacity) : (i += 1) {
        try std.testing.expect(scheduler.add_task_write_region(2, .{ .base = 0x7000_0000 + @as(u64, i) * 0x1000, .len = 0x1000 }));
    }
    const va = dispatch(sys_mmap, .{ 0, 4096, 3, 0x22, 0, 0 }, &frame);
    try std.testing.expect(va >= 0x1000_0000);
    syscall.arm_task_regions();
    try std.testing.expect(uaccess.read_region_covers(va, 8));
}

test "syscall: mmap at process region capacity fails LOUDLY with ENOMEM (issue #1163 A1)" {
    mmu.reset();
    alloc.reset_refcounts();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();

    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    // The process registry (max_mmap_regions = 16) is the loud gate: fill
    // it, then the next mapping refuses instead of half-registering; the
    // last live mapping is still visible after a re-arm (no silent drop at
    // capacity — 2 base + 16 regions fit the 26-slot per-core lists).
    var last_va: u64 = 0;
    var i: usize = 0;
    while (i < process.max_mmap_regions) : (i += 1) {
        const va = dispatch(sys_mmap, .{ 0, 4096, 3, 0x22, 0, 0 }, &frame);
        try std.testing.expect(va >= 0x1000_0000);
        last_va = va;
    }
    try std.testing.expectEqual(error_result(.enomem), dispatch(sys_mmap, .{ 0, 4096, 3, 0x22, 0, 0 }, &frame));
    syscall.arm_task_regions();
    try std.testing.expect(uaccess.read_region_covers(last_va, 8));
}

test "syscall: sys_mmap refuses hints that alias the caller's own apertures/regions (issue #1214)" {
    // The go-args boot flake: the GOOS=virelai sbrk heap's reservation
    // swallowed the randomized stack aperture because handle_mmap honored
    // page-aligned hints blindly. Now every mapping — hinted or picked —
    // is checked against the process's text/rodata/data/STACK apertures and
    // its earlier mmap regions, and a collision is an honest EINVAL.
    mmu.reset();
    alloc.reset_refcounts();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();

    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    const stack = userspace.stack_va_region();
    const text = userspace.text_va_region();

    // Into the stack aperture (the exact go-args shape) — refused.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_mmap, .{ stack.base, 4096, 3, 0x22, 0, 0 }, &frame));
    // Into the text aperture — refused.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_mmap, .{ text.base, 4096, 3, 0x22, 0, 0 }, &frame));
    // A clean hint maps fine; a range touching its own earlier mapping —
    // overlap refused, page-adjacent allowed (region bookkeeping is
    // page-granular).
    const clean_va = dispatch(sys_mmap, .{ 0x6000_0000, 4096, 3, 0x22, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, 0x6000_0000), clean_va);
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_mmap, .{ 0x6000_0000, 8192, 3, 0x22, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0x6000_1000), dispatch(sys_mmap, .{ 0x6000_1000, 4096, 3, 0x22, 0, 0 }, &frame));
}

test "syscall: shared anon mmap — two EL0 roots map one region; owner RW, WM RO; munmap revokes the peer seat" {
    mmu.reset();
    alloc.reset_refcounts();
    shared_region.reset(); // the region table is global — a fresh table per test
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)

    // Arm the physical allocator (SB2's create allocates its pages eagerly).
    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 64, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    // Two REAL TTBR0 roots: the owner renders into its shared surface; the WM
    // peer reads it EL0-RO from ITS OWN root at ITS OWN va.
    const owner_root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const peer_root = mmu.build_user_root(userspace.text_va, 0x3000, 64, userspace.stack_va, 0x4000, 8192).?;
    var kstack1: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack2: [scheduler.task_stack_size]u8 align(16) = undefined;
    const owner_pid = process.create("OWNER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = owner_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const peer_pid = process.create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = peer_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const owner_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack1, 0, 0).?;
    const peer_task = scheduler.register_exec_user(userspace.text_va, 0x5000_0000, 100, 0x9000_0000, 8192, &kstack2, 0, 0).?;
    _ = process.bind(owner_pid, owner_task);
    _ = process.bind(peer_pid, peer_task);
    scheduler.start();

    var frame = fresh_frame();
    // Drive the ring to the OWNER's task.
    var guard: usize = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());

    // --- Owner creates the shared surface (1 page, RW, MAP_ANON|M33_MAP_SHARED).
    const owner_va = dispatch(sys_mmap, .{ 0, 4096, 3, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(owner_va >= 0x1000_0000);
    const h: u32 = 1; // first kernel-issued handle
    const r = shared_region.info(h).?;
    try std.testing.expectEqual(@as(u64, owner_pid), r.owner_pid);
    try std.testing.expectEqual(@as(u32, 1), r.page_count);
    try std.testing.expectEqual(owner_va, r.owner_va);
    const pa_base: u64 = r.pa_base; // captured BEFORE teardown (the descriptor is zeroed on drop)
    try std.testing.expect(pa_base != 0);
    // The owner's leaf is WRITABLE (AP=0b01), maps the region's pa, no sw_cow.
    const owner_leaf = mmu.get_user_leaf(owner_root, owner_va).?.*;
    try std.testing.expectEqual(r.pa_base, owner_leaf & 0x0000_ffff_ffff_f000);
    try std.testing.expectEqual(@as(u64, 1), (owner_leaf >> 6) & 3); // EL0 RW
    try std.testing.expect((owner_leaf & mmu.sw_cow) == 0);
    // The OWNER attaching by handle keeps its writable surface (never maps a
    // redundant COW view of itself — the SB1 review duty).
    try std.testing.expectEqual(owner_va, dispatch(sys_mmap, .{ h, 4096, 1, 0x20 | 0x10000, 0, 0 }, &frame));

    // Drive the ring to the PEER's task.
    guard = 0;
    while (scheduler.current_id() != peer_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(peer_task, scheduler.current_id());

    // --- A stranger (the peer, pre-WM) cannot attach by handle: EACCES.
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_mmap, .{ h, 4096, 1, 0x20 | 0x10000, 0, 0 }, &frame));

    // --- A writable peer request is EINVAL (D2: peers are read-only).
    _ = wm_server.register(peer_pid);
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_mmap, .{ h, 4096, 3, 0x20 | 0x10000, 0, 0 }, &frame));

    // --- The WM attaches RO by handle: its OWN root, EL0-RO + sw_cow, SAME pa.
    const peer_va = dispatch(sys_mmap, .{ h, 4096, 1, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(peer_va >= 0x1000_0000);
    const peer_leaf = mmu.get_user_leaf(peer_root, peer_va).?.*;
    try std.testing.expectEqual(r.pa_base, peer_leaf & 0x0000_ffff_ffff_f000); // SAME physical page
    try std.testing.expectEqual(@as(u64, 3), (peer_leaf >> 6) & 3); // EL0 RO
    try std.testing.expect((peer_leaf & mmu.sw_cow) != 0);
    // Roots are independent: the peer's va may even coincide with the owner's
    // (both va allocators start at 0x1000_0000). The OWNER's leaf at that va,
    // if present, must never be the peer's RO/COW view.
    if (mmu.get_user_leaf(owner_root, peer_va)) |ol| {
        try std.testing.expect((ol.* & mmu.sw_cow) == 0);
    }
    // The peer seat + read ref were recorded.
    try std.testing.expectEqual(@as(u32, 1), shared_region.read_count(h));
    try std.testing.expectEqual(@as(u64, peer_pid), shared_region.info(h).?.peer_pid);
    // Re-attach is idempotent (keeps the existing seat).
    try std.testing.expectEqual(peer_va, dispatch(sys_mmap, .{ h, 4096, 1, 0x20 | 0x10000, 0, 0 }, &frame));

    // Drive back to the OWNER's task for teardown.
    guard = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());

    // --- A PARTIAL munmap of the shared surface is refused: EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_munmap, .{ owner_va, 8192, 0, 0, 0, 0 }, &frame));

    // --- Owner munmap revokes the peer seat: peer leaf unmapped, descriptor
    // gone, pages freed; the owner's own leaf is unmapped too.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_munmap, .{ owner_va, 4096, 0, 0, 0, 0 }, &frame));
    // A revoked leaf is value-zeroed (the intermediate table may remain — mmu
    // unmap semantics), so "gone" means the leaf is absent OR zero; a second
    // unmap of a zeroed leaf returns null (the honest probe).
    try std.testing.expect(mmu.unmap_user_page(peer_root, peer_va) == null);
    try std.testing.expect(mmu.unmap_user_page(owner_root, owner_va) == null);
    try std.testing.expect(shared_region.info(h) == null);
    // The physical page is FREED: a second free attempt returns false (the
    // allocator bit is already clear, and no shared_pages entry remains).
    try std.testing.expect(!alloc.unref_page(pa_base));
    // A stale handle re-attach is EFAULT (.gone).
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_mmap, .{ h, 4096, 1, 0x20 | 0x10000, 0, 0 }, &frame));

    // --- ENOSPC: fill the shared_region table, then a syscall create refuses.
    var n: u32 = 0;
    while (n < shared_region.max_shared_regions) : (n += 1) {
        const hh = shared_region.create(@as(u64, owner_pid));
        try std.testing.expect(hh != 0);
    }
    try std.testing.expectEqual(error_result(.enospc), dispatch(sys_mmap, .{ 0, 4096, 3, 0x20 | 0x10000, 0, 0 }, &frame));

    // Cleanup: unregister the WM seat — a leftover registration would hand
    // later tests (the input routing test uses pid 2) the driving_award
    // window/input hooks and cross-deliver events.
    _ = wm_server.unregister(peer_pid);
}

test "syscall: shared anon revoke-on-exit — owner exit revokes the peer seat; WM exit detaches only its seat" {
    mmu.reset();
    alloc.reset_refcounts();
    shared_region.reset(); // the region table is global — a fresh table per test
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    // M52 card 1 (#1238): the exit seam runs close_owner, so the window
    // registry must start EMPTY — a window left behind by an earlier test in
    // this binary would have its (foreign-arena) back-buffer freed here.
    driving_award.arm();

    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 64, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    const owner_root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const peer_root = mmu.build_user_root(userspace.text_va, 0x3000, 64, userspace.stack_va, 0x4000, 8192).?;
    var kstack1: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack2: [scheduler.task_stack_size]u8 align(16) = undefined;
    const owner_pid = process.create("OWNER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = owner_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const peer_pid = process.create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = peer_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const owner_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack1, 0, 0).?;
    const peer_task = scheduler.register_exec_user(userspace.text_va, 0x5000_0000, 100, 0x9000_0000, 8192, &kstack2, 0, 0).?;
    _ = process.bind(owner_pid, owner_task);
    _ = process.bind(peer_pid, peer_task);
    scheduler.start();

    var frame = fresh_frame();
    var guard: usize = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());

    const owner_va = dispatch(sys_mmap, .{ 0, 4096, 3, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(owner_va >= 0x1000_0000);
    const h: u32 = 1;
    const pa_base = shared_region.info(h).?.pa_base;

    guard = 0;
    while (scheduler.current_id() != peer_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(peer_task, scheduler.current_id());
    _ = wm_server.register(peer_pid);
    const peer_va = dispatch(sys_mmap, .{ h, 4096, 1, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(peer_va >= 0x1000_0000);
    // Owner (1) + peer (1): the page is 2-ref'd while both roots map it.
    try std.testing.expectEqual(@as(u16, 2), alloc.page_refcount(pa_base));

    // --- The WM (peer) exits first THROUGH THE REAL SEAM (M52 card 1,
    // #1238): only ITS seat detaches. The region and the owner's writable
    // leaf survive; the page drops back to the owner's single ref. The seam
    // runs revoke_owner (nothing owned) + revoke_peer_role + the service
    // resets + wm_server.unregister; the peer's descriptor is still
    // resolvable here (state `.exited`, not yet `.free`), which is exactly
    // why the peer leaf CAN be unmapped from its root.
    try std.testing.expect(scheduler.exit_current(0));
    try std.testing.expect(scheduler.is_terminated(peer_task));
    try std.testing.expect(mmu.unmap_user_page(peer_root, peer_va) == null); // peer RO leaf gone
    try std.testing.expect(shared_region.info(h) != null); // region survives
    try std.testing.expectEqual(@as(u32, 0), shared_region.read_count(h));
    try std.testing.expectEqual(@as(u64, 0), shared_region.info(h).?.peer_pid); // seat cleared
    try std.testing.expectEqual(@as(u16, 1), alloc.page_refcount(pa_base));
    // The owner's writable leaf is untouched.
    try std.testing.expect(mmu.unmap_user_page(owner_root, owner_va) != null); // still mapped (probe returns its pa)

    // --- The owner exits through the seam too: the region dies; the page is
    // only held by the owner's dynamic_pages list now (1) — the reap unrefs
    // it to 0 (free).
    var owner_guard: usize = 0;
    while (scheduler.current_id() != owner_task and owner_guard < scheduler.max_tasks) : (owner_guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(0));
    try std.testing.expect(scheduler.is_terminated(owner_task));
    try std.testing.expect(shared_region.info(h) == null);
    try std.testing.expectEqual(@as(u16, 1), alloc.page_refcount(pa_base));
    // Simulate the reap's release_resources unref of the owner's dynamic page.
    // The reap's release_resources unref frees the page (1 -> 0); a second
    // free attempt then does nothing (the honest "already freed" probe).
    try std.testing.expect(alloc.unref_page(pa_base));
    try std.testing.expect(!alloc.unref_page(pa_base));

    // The seam's own wm_server.unregister already tore the seat down — a
    // zombie WM leaves no registered seat behind, and the shim fallback is
    // reported exactly once (the shell idle loop drains it).
    try std.testing.expect(!wm_server.registered());
    try std.testing.expect(wm_server.registered_pid() == null);
    try std.testing.expect(wm_server.take_fallback_report());
    try std.testing.expect(!wm_server.take_fallback_report());
}

test "syscall: M52 exit-path inventory — the owner's death through the scheduler seam (window, focus, WM mirror, surface revoke, timer)" {
    mmu.reset();
    alloc.reset_refcounts();
    shared_region.reset();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    driving_award.arm();

    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 256, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    const owner_root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const wm_root = mmu.build_user_root(userspace.text_va, 0x3000, 64, userspace.stack_va, 0x4000, 8192).?;
    var kstack1: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack2: [scheduler.task_stack_size]u8 align(16) = undefined;
    const owner_pid = process.create("OWNER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = owner_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const wm_pid = process.create("WM.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = wm_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const owner_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack1, 0, 0).?;
    const wm_task = scheduler.register_exec_user(userspace.text_va, 0x5000_0000, 100, 0x9000_0000, 8192, &kstack2, 0, 0).?;
    _ = process.bind(owner_pid, owner_task);
    _ = process.bind(wm_pid, wm_task);
    scheduler.start();

    var frame = fresh_frame();
    var guard: usize = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());

    // Inventory step 2's input: a user window owned by the dying process, and
    // FOCUSED (user_open focuses the new window) — the "holder of focus"
    // shape the M52 umbrella kills.
    const wid: u8 = @intCast(dispatch(sys_win_open, .{ 48, 48, 96, 64, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u8, 2), wid);
    try std.testing.expectEqual(wid, driving_award.focused_window_id());

    // Inventory step 3's input: a shared surface the owner OWNS (the peer
    // half is attached by the registered WM below).
    const owner_va = dispatch(sys_mmap, .{ 0, 4096, 3, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(owner_va >= 0x1000_0000);
    const h: u32 = 1;
    const pa_base = shared_region.info(h).?.pa_base;

    // Inventory step 7's input: an armed app timer for the dying pid — the
    // seam's reset must disarm it so no stale TIMER can reach a recycled pid.
    try std.testing.expect(app_timers.set(owner_pid, 4));
    try std.testing.expect(app_timers.armed_pending(owner_pid));

    // The WM registers and attaches the surface READ-ONLY by handle.
    guard = 0;
    while (scheduler.current_id() != wm_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(wm_task, scheduler.current_id());
    _ = wm_server.register(wm_pid);
    const peer_va = dispatch(sys_mmap, .{ h, 4096, 1, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(peer_va >= 0x1000_0000);
    try std.testing.expectEqual(@as(u16, 2), alloc.page_refcount(pa_base));
    // Drain the WM's queue so the RELEASED mirror below is unambiguously the
    // exit path's own fan-out.
    while (events.pop(wm_pid)) |_| {}

    // Back to the owner: it dies THROUGH THE REAL SEAM.
    guard = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(0));

    // --- The seam ran to completion: a zombie with its status, teardown done.
    try std.testing.expect(scheduler.is_terminated(owner_task));
    try std.testing.expectEqual(@as(?u64, 0), scheduler.terminated_status(owner_task));

    // --- Step 2: no zombie window. The window left the registry and focus
    // fell back to the terminal (the shim default) instead of latching onto
    // a dead owner.
    try std.testing.expect(driving_award.find_user_window(wid) == null);
    try std.testing.expectEqual(@as(u8, 0), driving_award.focused_window_id());

    // --- Step 2: the WM is told EXACTLY ONCE that the window left the
    // registry (RELEASED mirror, flags bit 13, focus bit set because the
    // removed window held focus at fan time) — the WM drops a hit-test
    // target instead of compositing a stale surface.
    const rel = events.pop(wm_pid).?;
    try std.testing.expectEqual(events.WM_WINDOW, rel.kind);
    try std.testing.expectEqual(wid, @as(u8, @truncate(rel.flags))); // the released window's id
    try std.testing.expect((rel.flags & (1 << 8)) == 0); // NOT a visibility mirror
    try std.testing.expect((rel.flags & (1 << 9)) != 0); // it held focus at fan time
    try std.testing.expect((rel.flags & (1 << 13)) != 0); // RELEASED — left the registry
    try std.testing.expect(events.pop(wm_pid) == null);

    // --- Steps 3+4: the owned surface is revoked. The peer's RO leaf is
    // unmapped, the descriptor is dropped, and the page is back to the
    // owner's single ref (the reap unrefs it to 0).
    try std.testing.expect(mmu.unmap_user_page(wm_root, peer_va) == null);
    try std.testing.expect(shared_region.info(h) == null);
    try std.testing.expectEqual(@as(u16, 1), alloc.page_refcount(pa_base));

    // --- Step 7: the timer died with the process (no stale fire).
    try std.testing.expect(!app_timers.armed_pending(owner_pid));

    // --- Step 8: a CLIENT's death leaves the WM seat alone — unregister is
    // the registrant's own teardown, not any window owner's.
    try std.testing.expect(wm_server.registered());
    try std.testing.expectEqual(@as(?usize, wm_pid), wm_server.registered_pid());

    // Cleanup: the reap's release_resources unref frees the owner's dynamic
    // page (1 -> 0; the second probe is the honest "already freed" check),
    // then the WM seat tears down for the aggregated binary.
    try std.testing.expect(alloc.unref_page(pa_base));
    try std.testing.expect(!alloc.unref_page(pa_base));
    try std.testing.expect(wm_server.unregister(wm_pid));
}

test "syscall: M33 SB3 — window surface handoff; bind records the surface, WM mirror aliases RO, unmigrated stays frozen" {
    mmu.reset();
    alloc.reset_refcounts();
    shared_region.reset();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    driving_award.arm();

    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 256, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    const owner_root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const wm_root = mmu.build_user_root(userspace.text_va, 0x3000, 64, userspace.stack_va, 0x4000, 8192).?;
    var kstack1: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack2: [scheduler.task_stack_size]u8 align(16) = undefined;
    const owner_pid = process.create("APP.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = owner_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const wm_pid = process.create("WM.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = wm_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const owner_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack1, 0, 0).?;
    const wm_task = scheduler.register_exec_user(userspace.text_va, 0x5000_0000, 100, 0x9000_0000, 8192, &kstack2, 0, 0).?;
    _ = process.bind(owner_pid, owner_task);
    _ = process.bind(wm_pid, wm_task);
    scheduler.start();

    var frame = fresh_frame();
    // Drive to the OWNER's task.
    var guard: usize = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());

    // Register the WM BEFORE the bind so the surface auto-mirrors RO.
    _ = wm_server.register(wm_pid);

    // --- The app opens a user window (frozen slot 12, unchanged), unmigrated.
    const wid = dispatch(sys_win_open, .{ 64, 64, 128, 96, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, 2), wid);
    try std.testing.expect(!driving_award.user_is_surface_backed(@intCast(wid)));

    // --- Bind a shared surface AS the window's back-buffer via the sys_mmap
    // window-tag (SB3 handoff). Surface must hold the 128×96×4 back-buffer.
    const surf_len: u64 = 128 * 96 * 4; // 49152 = exactly 12 pages
    const owner_va = dispatch(sys_mmap, .{ m33_surf_win_tag | wid, surf_len, 3, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(owner_va >= 0x1000_0000);
    try std.testing.expect(driving_award.user_is_surface_backed(@intCast(wid)));
    const r = shared_region.info(1).?; // first kernel-issued handle
    try std.testing.expectEqual(@as(u64, owner_pid), r.owner_pid);
    try std.testing.expectEqual(@as(u32, 12), r.page_count); // window back-buffer
    const pa_base: u64 = r.pa_base;
    try std.testing.expect(pa_base != 0);

    // The owner's WRITABLE leaf maps the surface (no sw_cow).
    const owner_leaf = mmu.get_user_leaf(owner_root, owner_va).?.*;
    try std.testing.expectEqual(pa_base, owner_leaf & 0x0000_ffff_ffff_f000);
    try std.testing.expectEqual(@as(u64, 1), (owner_leaf >> 6) & 3); // EL0 RW
    try std.testing.expect((owner_leaf & mmu.sw_cow) == 0);

    // The window now reports the surface identity (composite's direct source).
    const surf = driving_award.user_surface(@intCast(wid)).?;
    try std.testing.expectEqual(@as(u32, 1), surf.handle);
    try std.testing.expectEqual(pa_base, surf.pa_base);

    // --- The WM's RO mirror was auto-granted: peer seat filled, maps the
    // SAME physical region EL0-RO sw_cow in the WM's OWN root.
    try std.testing.expectEqual(@as(u64, wm_pid), shared_region.info(1).?.peer_pid);
    const wm_va = shared_region.info(1).?.peer_va;
    const wm_leaf = mmu.get_user_leaf(wm_root, wm_va).?.*;
    try std.testing.expectEqual(pa_base, wm_leaf & 0x0000_ffff_ffff_f000); // SAME pages
    try std.testing.expectEqual(@as(u64, 3), (wm_leaf >> 6) & 3); // EL0 RO
    try std.testing.expect((wm_leaf & mmu.sw_cow) != 0);

    // The owner's leaf stays writable while the WM's is RO — independent
    // roots, one shared region (the composite + WM compose read the SAME pa).
    try std.testing.expect(mmu.get_user_leaf(owner_root, owner_va) != null);

    // --- OWNER re-attach by handle keeps its writable surface (D2 keep), and
    // a re-bind of the SAME window is EINVAL (one surface per window).
    try std.testing.expectEqual(owner_va, dispatch(sys_mmap, .{ 1, surf_len, 3, 0x20 | 0x10000, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_mmap, .{ m33_surf_win_tag | wid, surf_len, 3, 0x20 | 0x10000, 0, 0 }, &frame));

    // --- Frozen fill/present/open unchanged for unmigrated ids: present on
    // the migrated window still returns 0 (it marks dirty), fill on an
    // unknown id is still EINVAL, and a migrated fill RO's the shared surface
    // in the same B8G8R8X8 encoding as the old path (same fill_rect; the byte
    // parity is exercised by the live VZ gate where real physical pages hold
    // the writes).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_present, .{ wid, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_fill, .{ 99, 0, 0, 10, 10, 0 }, &frame));

    // Owner teardown: munmap the surface revokes the WM mirror (D2).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_munmap, .{ owner_va, surf_len, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(mmu.unmap_user_page(wm_root, wm_va) == null); // peer leaf gone
    try std.testing.expect(shared_region.info(1) == null);

    // Cleanup: unregister the WM seat (see the sibling test's note).
    _ = wm_server.unregister(wm_pid);
}

/// M52 card 3 (#1240): count the live `mmap_region` rows a process owns (the
/// rows compact into the low slots, so a scan is the count).
fn live_mmap_rows(pid: usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < process.max_mmap_regions) : (i += 1) {
        if (process.mmap_region_at(pid, i) != null) n += 1;
    }
    return n;
}

test "syscall: M52 card 3 — an owner-side revoke ends the bound window and drops the peer's mirror row + aperture; 17 cycles never exhaust the WM" {
    mmu.reset();
    alloc.reset_refcounts();
    shared_region.reset();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    driving_award.arm();
    events.init();

    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 256, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    const owner_root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const wm_root = mmu.build_user_root(userspace.text_va, 0x3000, 64, userspace.stack_va, 0x4000, 8192).?;
    var kstack1: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack2: [scheduler.task_stack_size]u8 align(16) = undefined;
    const owner_pid = process.create("APP.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = owner_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const wm_pid = process.create("WM.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = wm_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const owner_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack1, 0, 0).?;
    const wm_task = scheduler.register_exec_user(userspace.text_va, 0x5000_0000, 100, 0x9000_0000, 8192, &kstack2, 0, 0).?;
    _ = process.bind(owner_pid, owner_task);
    _ = process.bind(wm_pid, wm_task);
    scheduler.start();

    var frame = fresh_frame();
    var guard: usize = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());
    _ = wm_server.register(wm_pid);

    // --- The owner's WINDOW-BOUND surface (SB3 handoff): the binding makes
    // the zombie question concrete — the window's pixels live in the region.
    const wid = dispatch(sys_win_open, .{ 64, 64, 128, 96, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, 2), wid);
    const surf_len: u64 = 128 * 96 * 4;
    const owner_va = dispatch(sys_mmap, .{ m33_surf_win_tag | wid, surf_len, 3, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(owner_va >= 0x1000_0000);
    try std.testing.expect(driving_award.user_is_surface_backed(@intCast(wid)));
    const h: u32 = 1;
    try std.testing.expectEqual(surf_len, @as(u64, shared_region.info(h).?.page_count) * 4096);
    const pa_base = shared_region.info(h).?.pa_base;
    try std.testing.expectEqual(@as(u64, wm_pid), shared_region.info(h).?.peer_pid);
    try std.testing.expectEqual(@as(u16, 2), alloc.page_refcount(pa_base)); // owner + WM mirror

    // The WM's auto-mirror registered a PROCESS-scope row for its own va (the
    // row every SVC entry's `arm_task_regions` bridges into the EL0 aperture).
    guard = 0;
    while (scheduler.current_id() != wm_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(wm_task, scheduler.current_id());
    const wm_va = shared_region.info(h).?.peer_va;
    try std.testing.expect(wm_va >= 0x1000_0000);
    var row_found = false;
    {
        var i: usize = 0;
        while (i < process.max_mmap_regions) : (i += 1) {
            const r = process.mmap_region_at(wm_pid, i) orelse continue;
            if (r.base_va == wm_va) row_found = true;
        }
    }
    try std.testing.expect(row_found);
    // The WM's SVC-entry arming turns that row into the EL0 read aperture
    // (the exact sequence handle_svc runs; the A1 mmap-visibility tests use
    // this same seam).
    @import("syscall").arm_task_regions();
    try std.testing.expect(uaccess.read_region_covers(wm_va, 8));
    // Drain the WM's queue: the RELEASED mirror asserted below must be the
    // revoke's own fan, not an open-time leftover.
    while (events.pop(wm_pid)) |_| {}

    // --- Back on the owner: it MUNMAPS the window's surface (not an exit —
    // the ordinary owner-side teardown, which used to leave the window
    // surface-backed on the freed physical pages).
    guard = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());
    // Drain the owner's queue too: the open/focus fan-out is not what this
    // test reads (the WIN_CLOSE below must be the revoke's own push).
    while (events.pop(owner_pid)) |_| {}
    const rows_before = live_mmap_rows(wm_pid);
    try std.testing.expectEqual(@as(usize, 1), rows_before);
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_munmap, .{ owner_va, surf_len, 0, 0, 0, 0 }, &frame));

    // --- The ZOMBIE CLOSE: the window that was bound to the revoked surface
    // left the registry (it has no source left — its pixels were the region's
    // pages) and the registry is back to the four fixed layers. No window, so
    // composite() can never blit the freed pa and sys_win_fill can never
    // write it.
    try std.testing.expect(driving_award.find_user_window(@intCast(wid)) == null);
    try std.testing.expectEqual(@as(usize, 4), driving_award.count());
    try std.testing.expectEqual(@as(u8, 0), driving_award.focused_window_id()); // focus fell back
    // The release ran through the ONE primitive: the owner learned WIN_CLOSE
    // and the WM learned RELEASED (bit 13) exactly once.
    const close_ev = events.pop(owner_pid).?;
    try std.testing.expectEqual(events.WIN_CLOSE, close_ev.kind);
    try std.testing.expectEqual(wid, close_ev.arg0);
    try std.testing.expect(events.pop(owner_pid) == null); // exactly one WIN_CLOSE
    const rel = events.pop(wm_pid).?;
    try std.testing.expectEqual(events.WM_WINDOW, rel.kind);
    try std.testing.expectEqual(wid, @as(u8, @truncate(rel.flags)));
    try std.testing.expect((rel.flags & (1 << 8)) == 0); // not a visibility mirror
    try std.testing.expect((rel.flags & (1 << 13)) != 0); // RELEASED
    try std.testing.expect(events.pop(wm_pid) == null); // exactly one
    // The region died and the WM holds no leaf, no row, no aperture — the
    // mirror's kernel-side half is not separable from the leaves.
    try std.testing.expect(shared_region.info(h) == null);
    try std.testing.expect(mmu.unmap_user_page(wm_root, wm_va) == null); // peer RO leaf gone
    try std.testing.expectEqual(@as(u16, 1), alloc.page_refcount(pa_base)); // back to the owner's ref only
    try std.testing.expectEqual(@as(usize, 0), live_mmap_rows(wm_pid)); // peer's va reservation released
    try std.testing.expect(!uaccess.read_region_covers(wm_va, 8)); // aperture dropped

    // --- 17 further create/attach/revoke cycles: the WM's 16-row table is
    // never the binding constraint. Pre-fix each owner revoke left its row
    // behind, so the 17th attach failed ENOMEM and the WM could never mirror
    // again for the rest of the boot.
    var cycle: usize = 0;
    while (cycle < 17) : (cycle += 1) {
        var g: usize = 0;
        while (scheduler.current_id() != owner_task and g < scheduler.max_tasks) : (g += 1) {
            try std.testing.expect(scheduler.yield_current());
        }
        const cva = dispatch(sys_mmap, .{ 0, 4096, 3, 0x20 | 0x10000, 0, 0 }, &frame);
        try std.testing.expect(cva >= 0x1000_0000);
        // The kernel-issued handle of the newest region (the table is emptied
        // by every revoke, so this is the only live region the owner holds).
        const handle = shared_region.find_owner(owner_pid, cva).?;
        try std.testing.expect(handle != 0);
        g = 0;
        while (scheduler.current_id() != wm_task and g < scheduler.max_tasks) : (g += 1) {
            try std.testing.expect(scheduler.yield_current());
        }
        const cpeer_va = dispatch(sys_mmap, .{ handle, 4096, 1, 0x20 | 0x10000, 0, 0 }, &frame);
        // A REAL va, never an error: the WM's 16-row table is never the
        // binding constraint. (Errors are small negative i64s, so `>=` alone
        // would happily accept ENOMEM — assert the range AND the code.)
        try std.testing.expect(cpeer_va != error_result(.enomem));
        try std.testing.expect(cpeer_va >= 0x1000_0000 and cpeer_va < 0x0001_0000_0000_0000);
        try std.testing.expectEqual(@as(usize, 1), live_mmap_rows(wm_pid));
        g = 0;
        while (scheduler.current_id() != owner_task and g < scheduler.max_tasks) : (g += 1) {
            try std.testing.expect(scheduler.yield_current());
        }
        try std.testing.expectEqual(@as(u64, 0), dispatch(sys_munmap, .{ cva, 4096, 0, 0, 0, 0 }, &frame));
        try std.testing.expectEqual(@as(usize, 0), live_mmap_rows(wm_pid)); // released every cycle
    }

    // Cleanup: unregister the WM seat.
    _ = wm_server.unregister(wm_pid);
}

test "syscall: a >256-page shared surface records every peer ref and frees each page exactly once (issue #2110)" {
    mmu.reset();
    alloc.reset_refcounts();
    shared_region.reset();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    events.init();

    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 1024, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    const owner_root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const wm_root = mmu.build_user_root(userspace.text_va, 0x3000, 64, userspace.stack_va, 0x4000, 8192).?;
    var kstack1: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack2: [scheduler.task_stack_size]u8 align(16) = undefined;
    const owner_pid = process.create("APP.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = owner_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const wm_pid = process.create("WM.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = wm_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const owner_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack1, 0, 0).?;
    const wm_task = scheduler.register_exec_user(userspace.text_va, 0x5000_0000, 100, 0x9000_0000, 8192, &kstack2, 0, 0).?;
    _ = process.bind(owner_pid, owner_task);
    _ = process.bind(wm_pid, wm_task);
    scheduler.start();
    _ = wm_server.register(wm_pid);

    var frame = fresh_frame();
    var guard: usize = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    // 1280x720x4 — the audit's concrete example — is 900 pages: pre-fix the
    // 256-entry table silently dropped refs 257..900, so the peer's mirror
    // share of those pages was unrecorded.
    const surf_pages: u64 = 900;
    const surf_len: u64 = surf_pages * 4096;
    const owner_va = dispatch(sys_mmap, .{ 0, surf_len, 3, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(owner_va >= 0x1000_0000);
    const handle = shared_region.find_owner(owner_pid, owner_va).?;
    const pa_base = shared_region.info(handle).?.pa_base;

    // The WM attaches by handle — every leaf, not just the first 256, gets
    // its peer ref recorded.
    guard = 0;
    while (scheduler.current_id() != wm_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    const peer_va = dispatch(sys_mmap, .{ handle, surf_len, 1, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(peer_va != error_result(.enomem));
    try std.testing.expect(peer_va >= 0x1000_0000 and peer_va < 0x0001_0000_0000_0000);

    // Every page — including the ones past the old table's 256-entry bound —
    // carries a RECORDED count of 2 (owner leaf + peer RO leaf).
    try std.testing.expectEqual(@as(?u16, 2), alloc.page_refcount_recorded(pa_base));
    try std.testing.expectEqual(@as(?u16, 2), alloc.page_refcount_recorded(pa_base + 256 * 4096));
    try std.testing.expectEqual(@as(?u16, 2), alloc.page_refcount_recorded(pa_base + (surf_pages - 1) * 4096));

    // Owner munmaps: the revoke unrefs the peer seat first, then the owner's
    // leaves unref to zero and free — each of the 900 pages exactly once.
    guard = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_munmap, .{ owner_va, surf_len, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(shared_region.info(handle) == null);
    try std.testing.expect(mmu.unmap_user_page(wm_root, peer_va) == null);
    // If any of the 900 ref/unref pairs had been lost, the pool would not be
    // whole (leak) or a still-mapped page would have been freed early.
    try std.testing.expectEqual(@as(u64, 1024), alloc.stats().free_pages);

    _ = wm_server.unregister(wm_pid);
}

test "syscall: M52 card 3 — the WM dying FIRST still ends the owner's bound window when it later munmaps" {
    mmu.reset();
    alloc.reset_refcounts();
    shared_region.reset();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    driving_award.arm();
    events.init();

    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 256, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    const owner_root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const wm_root = mmu.build_user_root(userspace.text_va, 0x3000, 64, userspace.stack_va, 0x4000, 8192).?;
    var kstack1: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack2: [scheduler.task_stack_size]u8 align(16) = undefined;
    const owner_pid = process.create("APP.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = owner_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const wm_pid = process.create("WM.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = wm_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const owner_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack1, 0, 0).?;
    const wm_task = scheduler.register_exec_user(userspace.text_va, 0x5000_0000, 100, 0x9000_0000, 8192, &kstack2, 0, 0).?;
    _ = process.bind(owner_pid, owner_task);
    _ = process.bind(wm_pid, wm_task);
    scheduler.start();

    var frame = fresh_frame();
    var guard: usize = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());
    _ = wm_server.register(wm_pid);

    // The owner's WINDOW-BOUND surface (SB3 handoff), auto-mirrored RO into
    // the registered WM — the exact shape card 3's zombie close exists for.
    const wid = dispatch(sys_win_open, .{ 64, 64, 128, 96, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, 2), wid);
    const surf_len: u64 = 128 * 96 * 4;
    const owner_va = dispatch(sys_mmap, .{ m33_surf_win_tag | wid, surf_len, 3, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(owner_va >= 0x1000_0000);
    try std.testing.expect(driving_award.user_is_surface_backed(@intCast(wid)));
    const h: u32 = 1;
    const pa_base = shared_region.info(h).?.pa_base;
    try std.testing.expectEqual(@as(u64, wm_pid), shared_region.info(h).?.peer_pid);
    try std.testing.expectEqual(@as(u16, 2), alloc.page_refcount(pa_base));

    // --- The WM dies FIRST, through the real seam (inventory step 4:
    // revoke_peer_role clears the peer seat; D1 keeps the owner's surface AND
    // its window alive — the owner outliving its compositor is legal).
    guard = 0;
    while (scheduler.current_id() != wm_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(wm_task, scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(0));
    // The seat is cleared and the mirror's ref dropped, and step 8's seat
    // teardown ran — but the OWNER's window is untouched (the WM's death is
    // none of the owner's business).
    try std.testing.expectEqual(@as(u64, 0), shared_region.info(h).?.peer_pid);
    try std.testing.expectEqual(@as(u16, 1), alloc.page_refcount(pa_base));
    try std.testing.expect(driving_award.user_is_surface_backed(@intCast(wid)));
    try std.testing.expect(driving_award.find_user_window(@intCast(wid)) != null);
    try std.testing.expect(!wm_server.registered());

    // --- The owner LATER munmaps the surface. There is no peer seat left to
    // revoke, but the owner-side teardown still OWES the zombie close: the
    // window's pixels were the region's pages, so it has no source left.
    guard = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());
    while (events.pop(owner_pid)) |_| {}
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_munmap, .{ owner_va, surf_len, 0, 0, 0, 0 }, &frame));

    // THE POINT (pre-fix the window survived, still surface_backed over freed
    // physical pages): the window left the registry, so no composite() can
    // blit the freed pa and no sys_win_fill can write it.
    try std.testing.expect(driving_award.find_user_window(@intCast(wid)) == null);
    try std.testing.expect(!driving_award.user_is_surface_backed(@intCast(wid)));
    try std.testing.expectEqual(@as(usize, 4), driving_award.count());
    try std.testing.expectEqual(@as(u8, 0), driving_award.focused_window_id()); // focus fell back
    // Exactly one WIN_CLOSE for the owner — the release primitive ran once.
    const close_ev = events.pop(owner_pid).?;
    try std.testing.expectEqual(events.WIN_CLOSE, close_ev.kind);
    try std.testing.expectEqual(wid, close_ev.arg0);
    try std.testing.expect(events.pop(owner_pid) == null);
    // The descriptor died with the munmap, and with no seat to release the
    // peer table keeps nothing. (The dead WM's OWN va reservation is not
    // asserted here: nothing released it early — `revoke_peer_role` never did,
    // and this process was never reaped — so the row is reclaimed at reap, not
    // by the owner's munmap. The live-peer row cleanup is the previous test's
    // job.)
    try std.testing.expect(shared_region.info(h) == null);
}

test "syscall: M33 SB5 — the scanout grant is WM-only, full-frame, writable, idempotent, and tears down (claim 7397)" {
    mmu.reset();
    alloc.reset_refcounts();
    shared_region.reset();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    driving_award.arm();

    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 256, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    const owner_root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const wm_root = mmu.build_user_root(userspace.text_va, 0x3000, 64, userspace.stack_va, 0x4000, 8192).?;
    var kstack1: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack2: [scheduler.task_stack_size]u8 align(16) = undefined;
    const owner_pid = process.create("APP.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = owner_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const wm_pid = process.create("WM.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = wm_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const owner_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack1, 0, 0).?;
    const wm_task = scheduler.register_exec_user(userspace.text_va, 0x5000_0000, 100, 0x9000_0000, 8192, &kstack2, 0, 0).?;
    _ = process.bind(owner_pid, owner_task);
    _ = process.bind(wm_pid, wm_task);
    scheduler.start();

    var frame = fresh_frame();
    // Register the WM (the syscall seat check needs it) and fake a
    // framebuffer physical base — the test only inspects leaves, never the
    // pages themselves, so an out-of-the-way fake PA is safe.
    _ = wm_server.register(wm_pid);
    const fb_pa: u64 = 0x9000_0000;
    const saved_fb_phys = virtio_gpu.gpu_fb_phys;
    virtio_gpu.gpu_fb_phys = fb_pa;
    defer {
        virtio_gpu.gpu_fb_phys = saved_fb_phys;
        _ = wm_server.unregister(wm_pid);
    }
    const fb_len: u64 = virtio_gpu.fb_size;

    // --- A NON-WM process is refused EACCES (the seat is the privilege).
    var guard: usize = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_mmap, .{ m33_surf_scan_tag, fb_len, 3, 0x20 | 0x10000, 0, 0 }, &frame));

    // --- The WM: wrong geometry refused (partial frame EINVAL; RO prot EINVAL).
    guard = 0;
    while (scheduler.current_id() != wm_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_mmap, .{ m33_surf_scan_tag, fb_len - 4096, 3, 0x20 | 0x10000, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_mmap, .{ m33_surf_scan_tag, fb_len, 1, 0x20 | 0x10000, 0, 0 }, &frame));

    // --- The WM binds the full framebuffer WRITABLE into ITS OWN root.
    const scan_va = dispatch(sys_mmap, .{ m33_surf_scan_tag, fb_len, 3, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(scan_va >= 0x1000_0000);
    try std.testing.expect(wm_server.scanout_bound(wm_pid));
    // Each leaf aliases the GPU framebuffer's physical pages, EL0 RW, no sw_cow.
    {
        const leaf = mmu.get_user_leaf(wm_root, scan_va).?.*;
        try std.testing.expectEqual(fb_pa, leaf & 0x0000_ffff_ffff_f000);
        try std.testing.expectEqual(@as(u64, 1), (leaf >> 6) & 3); // EL0 RW
        try std.testing.expect((leaf & mmu.sw_cow) == 0);
        // The last page too (full-frame).
        const last_va = scan_va + (fb_len - 4096);
        const leaf_last = mmu.get_user_leaf(wm_root, last_va).?.*;
        try std.testing.expectEqual(fb_pa + fb_len - 4096, leaf_last & 0x0000_ffff_ffff_f000);
    }

    // --- Idempotent re-bind returns the SAME va (no second mapping).
    try std.testing.expectEqual(scan_va, dispatch(sys_mmap, .{ m33_surf_scan_tag, fb_len, 3, 0x20 | 0x10000, 0, 0 }, &frame));

    // --- The kernel did NOT ref-count the GPU pages (they are kernel-owned):
    // no dynamic page was recorded, so teardown must never unref them.
    // (probe: the mapped pa is NOT in the WM's dynamic list — the syscall
    // path records dynamic pages for OWNER surfaces only.)

    // --- Full-frame munmap unbinds: leaves unmapped WITHOUT unref.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_munmap, .{ scan_va, fb_len, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!wm_server.scanout_bound(wm_pid));
    // The leaves were unmapped (probe: unmap finds no valid leaf anymore).
    try std.testing.expect(mmu.unmap_user_page(wm_root, scan_va) == null);
    // Re-bind (a fresh grant): a new va, full-frame only enforced again.
    const scan_va2 = dispatch(sys_mmap, .{ m33_surf_scan_tag, fb_len, 3, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(scan_va2 >= 0x1000_0000);
    try std.testing.expect(scan_va2 != scan_va);
    // Partial munmap of the scanout is refused (full-frame only).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_munmap, .{ scan_va2, 4096, 0, 0, 0, 0 }, &frame));

    // --- WM unregister tears the grant down too (the exit path).
    try std.testing.expect(wm_server.scanout_bound(wm_pid));
    _ = wm_server.unregister(wm_pid);
    try std.testing.expect(!wm_server.scanout_bound(wm_pid));
    try std.testing.expect(mmu.unmap_user_page(wm_root, scan_va2) == null);
    // The user layer ownership went back to the kernel shim.
    try std.testing.expect(!driving_award.wm_owns_user_layer);
}

test "syscall: WMCTL WINDOW_NAME (cmd 14, #1056) resolves a window's display name" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (the WM seat)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)

    // No WM registered -> ENOSYS (the ADR 0007 "no WM" case).
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_window_name, 2, 0, 0, 0, 0 }, &frame));

    try std.testing.expect(wm_server.register(0));
    const o = driving_award.user_open(64, 64, 256, 192, 0);
    try std.testing.expectEqual(@as(u8, 2), o.opened);

    // Unknown id / the fixed terminal window -> EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_window_name, 9, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_window_name, 0, 0, 0, 0, 0 }, &frame));

    // App-set title: copied OUT and the handler returns its byte count.
    try std.testing.expect(driving_award.set_window_title(2, "Calc"));
    var out: [16]u8 = [_]u8{0} ** 16;
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = @intFromPtr(&out), .len = out.len });
    try std.testing.expectEqual(@as(u64, 4), dispatch(sys_wmctl, .{ wm_server.wmctl_window_name, 2, @intFromPtr(&out), out.len, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("Calc", out[0..4]);

    // An unwritable destination -> EFAULT.
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = 0, .len = 0 });
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_wmctl, .{ wm_server.wmctl_window_name, 2, uaccess.diagnostic_unmapped, 8, 0, 0 }, &frame));

    // Teardown: no leaked seats or windows into the aggregated binary.
    try std.testing.expect(wm_server.unregister(0));
    _ = driving_award.user_close(2);
}

test "syscall: SYS_TIME (slot 66, #1058) returns the firmware wall-clock epoch" {
    init(test_writer);
    var frame = fresh_frame();

    // The slot is registered and named in the table.
    try std.testing.expectEqualStrings("sys_time", entry_info(sys_time).?.name);
    // M50 TS1 added slot 68 (sys_principal), TS2 slot 69 (sys_file_mode),
    // TS5 slot 70 (sys_secret_get), TS4 slot 71 (sys_tty_net_auth);
    // M51 SSH-P1 (#1166) slot 72 (sys_getrandom); issue #1228 slot 75;
    // issue #1163 phase 2 slot 76 (sys_sock_ready).
    try std.testing.expectEqual(@as(usize, 84), syscall.implemented_count);

    const saved_epoch = timer.boot_epoch_secs;
    const saved_ticks = timer.ticks;
    defer {
        timer.boot_epoch_secs = saved_epoch;
        timer.ticks = saved_ticks;
    }

    // No firmware epoch captured -> ENOSYS (the honest uptime fallback).
    timer.boot_epoch_secs = std.math.maxInt(u64);
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_time, .{ 0, 0, 0, 0, 0, 0 }, &frame));

    // Boot epoch + 3 s of 1 Hz uptime: the current wall-clock seconds.
    timer.boot_epoch_secs = 1_789_043_696; // 2026-09-10 12:34:56 wall-clock
    timer.ticks = 3;
    try std.testing.expectEqual(@as(u64, 1_789_043_699), dispatch(sys_time, .{ 0, 0, 0, 0, 0, 0 }, &frame));
}

test "syscall: SYS_TIME_SET (slot 78, M83b #1775) re-anchors the wall clock inside its range" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (uid_user)
    scheduler.start();
    var frame = fresh_frame();

    try std.testing.expectEqualStrings("sys_time_set", entry_info(sys_time_set).?.name);
    try std.testing.expectEqual(@as(u64, 78), sys_time_set);

    const saved_epoch = timer.boot_epoch_secs;
    const saved_ticks = timer.ticks;
    defer {
        timer.boot_epoch_secs = saved_epoch;
        timer.ticks = saved_ticks;
    }
    timer.boot_epoch_secs = std.math.maxInt(u64);
    timer.ticks = 5;

    // An EL1h caller (the shell) is not a process: EINVAL, clock untouched.
    const synced: u64 = 1_789_043_696; // 2026-09-10 12:34:56 wall-clock
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_time_set, .{ synced, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_time, .{ 0, 0, 0, 0, 0, 0 }, &frame));

    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    // A process gives a no-firmware-epoch boot a clock; slot 66 reads it back.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_time_set, .{ synced, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(synced, dispatch(sys_time, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    // The tick count did not move; the clock keeps advancing from the anchor.
    timer.ticks = 9;
    try std.testing.expectEqual(synced + 4, dispatch(sys_time, .{ 0, 0, 0, 0, 0, 0 }, &frame));

    // Every out-of-range value is EINVAL and leaves the clock exactly as it was.
    const held = dispatch(sys_time, .{ 0, 0, 0, 0, 0, 0 }, &frame);
    for ([_]u64{ 0, timer.wall_epoch_min - 1, timer.wall_epoch_max + 1, 0xffff_ffff, std.math.maxInt(u64) }) |bad| {
        try std.testing.expectEqual(error_result(.einval), dispatch(sys_time_set, .{ bad, 0, 0, 0, 0, 0 }, &frame));
        try std.testing.expectEqual(held, dispatch(sys_time, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    }
    // A backwards correction is accepted: this is a set, not a monotonic clock.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_time_set, .{ synced - 3600, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(synced - 3600, dispatch(sys_time, .{ 0, 0, 0, 0, 0, 0 }, &frame));
}

test "syscall: SYS_PRINCIPAL (slot 68, #1135) reports uid_user and is read-only" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (uid_user)
    scheduler.start();
    var frame = fresh_frame();
    var buf: [principal_bytes]u8 = undefined;
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = @intFromPtr(&buf), .len = buf.len });
    // An EL1h caller (the shell) is not a process: EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_principal, .{ @intFromPtr(&buf), 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, principal_bytes), dispatch(sys_principal, .{ @intFromPtr(&buf), 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(process.uid_user, std.mem.readInt(u32, buf[0..4], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[4..8], .little));
    // A bad buffer is EFAULT, never a crash or a fabricated identity.
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_principal, .{ uaccess.diagnostic_unmapped, 0, 0, 0, 0, 0 }, &frame));
}

test "syscall: SYS_PRINCIPAL reports an explicit uid_system principal" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (uid_user)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const sys_pid = process.create_as("SYS.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}, .{ .uid = process.uid_system, .caps = process.kernel_caps }).?;
    const sys_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(sys_pid, sys_task);
    scheduler.start();
    var frame = fresh_frame();
    var buf: [principal_bytes]u8 = undefined;
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = @intFromPtr(&buf), .len = buf.len });
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(sys_task, scheduler.current_id());
    try std.testing.expectEqual(@as(u64, principal_bytes), dispatch(sys_principal, .{ @intFromPtr(&buf), 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(process.uid_system, std.mem.readInt(u32, buf[0..4], .little));
    try std.testing.expectEqual(process.kernel_caps, std.mem.readInt(u32, buf[4..8], .little));
}

// ---------------------------------------------------------------------------
// M50 TS3 (issue #1137, ADR 0024 D5/D10): the capability gate table + kill gate
// ---------------------------------------------------------------------------

test "syscall: M50 TS3 gate table is explicit, bounded, and exactly the ADR 0024 D10 set" {
    init(test_writer);
    // The auditable rows: the whole dangerous-syscall capability surface —
    // M50's kill row plus M97g (#2082)'s two clipboard rows.
    try std.testing.expectEqual(@as(usize, 3), syscall.capability_gates.len);
    try std.testing.expectEqual(sys_kill, syscall.capability_gates[0].number);
    try std.testing.expectEqual(process.cap_proc_admin, syscall.capability_gates[0].cap);
    try std.testing.expectEqual(@as(?u32, process.cap_proc_admin), syscall.gated(sys_kill));
    try std.testing.expectEqual(sys_clipboard_set, syscall.capability_gates[1].number);
    try std.testing.expectEqual(process.cap_clipboard, syscall.capability_gates[1].cap);
    try std.testing.expectEqual(sys_clipboard_get, syscall.capability_gates[2].number);
    try std.testing.expectEqual(process.cap_clipboard, syscall.capability_gates[2].cap);
    try std.testing.expectEqual(@as(?u32, process.cap_clipboard), syscall.gated(sys_clipboard_set));
    try std.testing.expectEqual(@as(?u32, process.cap_clipboard), syscall.gated(sys_clipboard_get));
    // ADR 0024 D10's OTHER existing syscalls are deliberately NOT in the
    // capability table: exec inherits (TS1), the file family enforces D3/D4
    // inside trust.check (TS2), tty_attach keeps its owner checks (TS4),
    // wmctl/mmap already hold, and setrlimit is self-only. Adding one here
    // would change behavior silently — the table is the audit point.
    const not_gated = [_]u64{
        sys_exec,          sys_file_open, sys_file_read,   sys_file_write,
        sys_file_close,    sys_dir_list,  sys_file_delete, sys_file_rename,
        sys_file_truncate, sys_file_free, sys_file_mode,   sys_tty_attach,
        sys_tty_net_auth,  sys_wmctl,     sys_mmap,        sys_munmap,
        54, // slot 54 sys_setrlimit (self-only, ADR 0024 D10)
        sys_principal,
        sys_secret_get,
        // M51 SSH-P1 (#1166): the EL0 entropy read is capability-free by
        // contract — every principal may read entropy (ADR 0025 D5).
        sys_getrandom,
        // M83b (#1775): the wall-clock write is bounded by its range check,
        // not a capability — every EL0 principal is uid_user with no caps and
        // nothing elevates, so a row here could only ever say no.
        sys_time_set,
    };
    for (not_gated) |number| {
        try std.testing.expectEqual(@as(?u32, null), syscall.gated(number));
    }
    // Every gated row names an EXISTING implemented slot, and TS3 adds NO
    // slot: implemented_count is 79 after M83b's slot 78 (issue #1228's 75,
    // ADR 0027's 73/74, issue #1163 phase 2's 76 and M66a's 77 came earlier).
    for (syscall.capability_gates) |gate| {
        try std.testing.expect(gate.number < syscall.implemented_count);
        try std.testing.expect(entry_info(gate.number) != null);
    }
    try std.testing.expectEqual(@as(usize, 84), syscall.implemented_count);
}

test "syscall: no slot can raise uid/caps (TS3 consumes caps, adds no setter)" {
    init(test_writer);
    // The principal surface is read-only by construction: `process.principal`
    // has no setter and `create_as` is the only assignment. The TS3 gate
    // table only CONSUMES a capability, and every implemented row is audited
    // here so a future privilege-NAMED row cannot land unnoticed.
    var seen_principal = false;
    for (0..syscall.implemented_count) |number| {
        const info = entry_info(number).?;
        if (std.mem.eql(u8, info.name, "sys_principal")) {
            seen_principal = true;
            continue;
        }
        try std.testing.expect(std.mem.indexOf(u8, info.name, "uid") == null);
        try std.testing.expect(std.mem.indexOf(u8, info.name, "gid") == null);
        try std.testing.expect(std.mem.indexOf(u8, info.name, "cap") == null);
        try std.testing.expect(std.mem.indexOf(u8, info.name, "cred") == null);
    }
    try std.testing.expect(seen_principal);
    // sys_exec (the EL0 spawn) is ungated and takes no principal argument:
    // it inherits the caller (TS1), so `gated(28)` must stay null.
    try std.testing.expectEqual(@as(?u32, null), syscall.gated(sys_exec));
    try std.testing.expectEqualStrings("sys_exec", entry_info(sys_exec).?.name);
}

// ---------------------------------------------------------------------------
// M51 SSH-P1 (issue #1166, ADR 0025 D5): the EL0 entropy read — slot 72
// ---------------------------------------------------------------------------

test "syscall: SYS_GETRANDOM (slot 72, #1166) is registered, capped, capability-free, and not called at boot" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    // Seed explicitly: module state is shared across the test binary, so
    // the seeded/unseeded default is not order-dependent. (#2084)
    const test_seed: [syscall.csprng.seed_len]u8 = @splat(0xA5);
    syscall.csprng.seed(&test_seed);

    // Registered under its name; the table test pins the count at 73.
    try std.testing.expectEqualStrings("sys_getrandom", entry_info(sys_getrandom).?.name);
    // No capability: every principal may read entropy (ADR 0025 D5).
    try std.testing.expectEqual(@as(?u32, null), syscall.gated(sys_getrandom));

    // Boot default unchanged (ADR 0025 D9): bring-up registers the slot but
    // NOTHING on the boot path dispatches it — the call counter is still zero
    // after the scheduler and the static boot payload are running.
    try std.testing.expectEqual(@as(u64, 0), call_count(sys_getrandom));

    var buf: [getrandom_max + 64]u8 = undefined;
    // An EL1h caller (the shell) is not a process: EINVAL, never entropy.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_getrandom, .{ @intFromPtr(&buf), 8, 0, 0, 0, 0 }, &frame));

    // Drive to the boot payload's task (process 0) and arm its stack as the
    // destination region so uaccess copy_out can validate it.
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = @intFromPtr(&buf), .len = buf.len });

    // len == 0 returns 0 without touching the buffer.
    @memset(buf[0..16], 0xAA);
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_getrandom, .{ @intFromPtr(&buf), 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u8, 0xAA), buf[0]);

    // A normal request writes exactly the requested bytes out of the CSPRNG.
    @memset(buf[0..16], 0xAA);
    try std.testing.expectEqual(@as(u64, 16), dispatch(sys_getrandom, .{ @intFromPtr(&buf), 16, 0, 0, 0, 0 }, &frame));
    var filled = false;
    for (buf[0..16]) |b| {
        if (b != 0xAA) filled = true;
    }
    try std.testing.expect(filled);

    // The cap clamps a longer request to getrandom_max; the caller loops.
    @memset(buf[0..], 0x55);
    try std.testing.expectEqual(@as(u64, getrandom_max), dispatch(sys_getrandom, .{ @intFromPtr(&buf), buf.len, 0, 0, 0, 0 }, &frame));

    // A bad buffer is EFAULT, never a crash or a silently dropped entropy call.
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_getrandom, .{ uaccess.diagnostic_unmapped, 8, 0, 0, 0, 0 }, &frame));

    // The slot was dispatched exactly the times the checks above issued it
    // (EINVAL + zero + normal + cap + EFAULT) — proving no boot-path call.
    try std.testing.expectEqual(@as(u64, 5), call_count(sys_getrandom));
}

fn entropy_fill_5c(out: []u8) bool {
    @memset(out, 0x5c);
    return true;
}

fn entropy_fill_fail(_: []u8) bool {
    return false;
}

test "syscall: getrandom fails closed while unseeded and the lazy reseed keys on device reappearance (#2084)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    var buf: [32]u8 = undefined;

    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = @intFromPtr(&buf), .len = buf.len });

    // Unseeded (the deterministic fallback is armed): the slot refuses
    // honestly — EAGAIN — and writes NOTHING to the caller's buffer.
    syscall.csprng.seed_fallback();
    @memset(buf[0..16], 0xAA);
    try std.testing.expectEqual(error_result(.eagain), dispatch(sys_getrandom, .{ @intFromPtr(&buf), 16, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!syscall.csprng.seeded());
    try std.testing.expectEqual(@as(u8, 0xAA), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xAA), buf[15]);
    // len == 0 stays a no-op (0, not an error) — no entropy was requested.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_getrandom, .{ @intFromPtr(&buf), 0, 0, 0, 0, 0 }, &frame));

    // The device (re)appears: the same call drives the lazy reseed —
    // the injected read keys the CSPRNG and the request is served on
    // the spot (the contract: unseeded refusal is transient).
    syscall.virtio_entropy.test_read_hook = entropy_fill_5c;
    defer syscall.virtio_entropy.test_read_hook = null;
    @memset(buf[0..16], 0xAA);
    try std.testing.expectEqual(@as(u64, 16), dispatch(sys_getrandom, .{ @intFromPtr(&buf), 16, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(syscall.csprng.seeded());
    var filled = false;
    for (buf[0..16]) |b| {
        if (b != 0xAA) filled = true;
    }
    try std.testing.expect(filled);
    // A device read that fails (wedged transport) keeps the refusal
    // honest — the fallback stream is still never served.
    syscall.csprng.seed_fallback();
    syscall.virtio_entropy.test_read_hook = entropy_fill_fail;
    try std.testing.expectEqual(error_result(.eagain), dispatch(sys_getrandom, .{ @intFromPtr(&buf), 16, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!syscall.csprng.seeded());
}

test "syscall: M50 TS3 kill gate — same-uid/self allowed, cross-principal EACCES" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (uid_user caller)
    var kstack_sys: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack_nocap: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack_peer: [scheduler.task_stack_size]u8 align(16) = undefined;
    // Cross-principal targets: one uid_system WITH both caps and one with
    // no caps — the DENIAL keys on the caller's principal, not the
    // target's capability mask.
    const sys_cap_pid = process.create_as("SYS.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}, .{ .uid = process.uid_system, .caps = process.kernel_caps }).?;
    const sys_cap_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack_sys, 0, 0).?;
    _ = process.bind(sys_cap_pid, sys_cap_task);
    const sys_nocap_pid = process.create_as("NOCAP.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}, .{ .uid = process.uid_system, .caps = 0 }).?;
    const sys_nocap_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack_nocap, 0, 0).?;
    _ = process.bind(sys_nocap_pid, sys_nocap_task);
    // A same-uid (uid_user) target.
    const peer_pid = process.create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const peer_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack_peer, 0, 0).?;
    _ = process.bind(peer_pid, peer_task);
    scheduler.start();
    var frame = fresh_frame();

    // An EL1h caller is not a process: EINVAL (unchanged precedence).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_kill, .{ peer_pid, 0, 0, 0, 0, 0 }, &frame));

    // Drive to the uid_user caller (task 2, process 0).
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    // Cross-principal -> EACCES, never armed (targets stay running).
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_kill, .{ sys_cap_pid, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_kill, .{ sys_nocap_pid, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(process.State.running, process.info(sys_cap_pid).?.state);
    try std.testing.expectEqual(process.State.running, process.info(sys_nocap_pid).?.state);

    // Same-uid live target is allowed (0) and armed.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_kill, .{ peer_pid, 0, 0, 0, 0, 0 }, &frame));
    // The denial precedes the target-state checks: an EXITED cross-principal
    // target still answers EACCES (never the state-dependent EINVAL), so an
    // unprivileged caller cannot learn a foreign principal's process state.
    _ = process.on_task_exit(sys_nocap_task, 0);
    try std.testing.expectEqual(process.State.exited, process.info(sys_nocap_pid).?.state);
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_kill, .{ sys_nocap_pid, 0, 0, 0, 0, 0 }, &frame));
    // The same-uid exit path keeps its EINVAL contract (the sys_wait
    // precedent) — only the cross-principal rule changed.
    _ = process.on_task_exit(peer_task, 0);
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_kill, .{ peer_pid, 0, 0, 0, 0, 0 }, &frame));
    // Self is allowed (the caller's own pid — same principal by definition).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_kill, .{ 0, 0, 0, 0, 0, 0 }, &frame));
}

test "syscall: M50 TS3 — uid_system + CAP_PROC_ADMIN kills across principals" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (uid_user)
    var kstack_admin: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack_victim: [scheduler.task_stack_size]u8 align(16) = undefined;
    // The admin caller: uid_system + both caps — exactly the `exec -u0`
    // admin-spawn principal (ADR 0024 D5).
    const admin_pid = process.create_as("ADMIN.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}, .{ .uid = process.uid_system, .caps = process.kernel_caps }).?;
    const admin_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack_admin, 0, 0).?;
    _ = process.bind(admin_pid, admin_task);
    // A uid_user victim (a different principal).
    const victim_pid = process.create("VICTIM.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const victim_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack_victim, 0, 0).?;
    _ = process.bind(victim_pid, victim_task);
    scheduler.start();
    var frame = fresh_frame();

    // shell -> user (2) -> admin (3).
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(admin_task, scheduler.current_id());

    // The privileged cross-principal kill is allowed and armed; the ring
    // converts the victim's next selection into the exit path (137).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_kill, .{ victim_pid, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(process.State.running, process.info(victim_pid).?.state);
    try std.testing.expect(scheduler.yield_current()); // admin -> victim -> killed -> idle
    try std.testing.expect(scheduler.is_terminated(victim_task));
    try std.testing.expectEqual(@as(?u64, scheduler.reserved_kill_status), scheduler.terminated_status(victim_task));
    try std.testing.expectEqual(process.State.exited, process.info(victim_pid).?.state);
    try std.testing.expectEqual(@as(u64, scheduler.reserved_kill_status), process.info(victim_pid).?.exit_status);
}

test "syscall: SYS_FILE_MODE (slot 69, #1136) is process-gated with the frozen error contract" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0
    scheduler.start();
    file_table.init();
    var frame = fresh_frame();

    // An EL1h caller is not a process: EINVAL, never a silent chmod.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_mode, .{ 0x1000, 5, 0o600, 0, 0, 0 }, &frame));
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    const bad = "../x.txt";
    const good = "PLAIN.TXT";
    var path_buf: [file_table.max_path_len]u8 = undefined;
    @memcpy(path_buf[0..bad.len], bad);
    set_user_regions(.{ .base = @intFromPtr(&path_buf), .len = path_buf.len }, .{ .base = 0, .len = 0 });
    // Traversal syntax is refused before any filesystem access.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_mode, .{ @intFromPtr(&path_buf), bad.len, 0o600, 0, 0, 0 }, &frame));
    // A valid path with no host channel is an honest ENOENT.
    @memcpy(path_buf[0..good.len], good);
    try std.testing.expectEqual(error_result(.enoent), dispatch(sys_file_mode, .{ @intFromPtr(&path_buf), good.len, 0o600, 0, 0, 0 }, &frame));
    // A bad pointer is EFAULT.
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_file_mode, .{ uaccess.diagnostic_unmapped, 5, 0o600, 0, 0, 0 }, &frame));
}

test "syscall: SYS_SECRET_GET (slot 70, #1139) serves only the caller's principal" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (uid_user)
    scheduler.start();
    var frame = fresh_frame();
    // Seed the store with uid_user + uid_system entries (the TS5 class-A
    // known-value pair).
    try std.testing.expectEqual(secret.LoadResult.ok, secret.parse(
        "#v1\n" ++
            "netkey\t1000\tsupersecretvalue\n" ++
            "audkey\t0\tsystemsecretvalue\n",
    ));

    // An EL1h caller is not a process: EINVAL, never a read.
    var buf: [secret.max_secret_entries * secret.record_bytes]u8 = undefined;
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_secret_get, .{ @intFromPtr(&buf), buf.len, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = @intFromPtr(&buf), .len = buf.len });
    // The user principal (uid_user) gets ONLY its own entry.
    const rc = dispatch(sys_secret_get, .{ @intFromPtr(&buf), buf.len, 0, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, secret.record_bytes), rc);
    const rec = @as(*align(1) const secret.SecretRecord, @ptrCast(&buf));
    try std.testing.expectEqual(process.uid_user, rec.uid);
    try std.testing.expectEqualStrings("netkey", rec.key[0..rec.key_len]);
    try std.testing.expectEqualStrings("supersecretvalue", rec.val[0..rec.val_len]);

    // A buffer too small to hold every caller entry is EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_secret_get, .{ @intFromPtr(&buf), secret.record_bytes - 1, 0, 0, 0, 0 }, &frame));
    // A bad buffer address is EFAULT.
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_secret_get, .{ uaccess.diagnostic_unmapped, buf.len, 0, 0, 0, 0 }, &frame));
    // The uid_system entry is NOT visible to the uid_user caller.
    try std.testing.expect(std.mem.indexOf(u8, &buf, "systemsecretvalue") == null);
}

test "syscall: SYS_SECRET_GET serves a uid_system principal its own entries" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (uid_user)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const sys_pid = process.create_as("SYS.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}, .{ .uid = process.uid_system, .caps = process.kernel_caps }).?;
    const sys_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(sys_pid, sys_task);
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expectEqual(secret.LoadResult.ok, secret.parse(
        "#v1\n" ++
            "netkey\t1000\tsupersecretvalue\n" ++
            "audkey\t0\tsystemsecretvalue\n",
    ));
    var buf: [secret.max_secret_entries * secret.record_bytes]u8 = undefined;
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = @intFromPtr(&buf), .len = buf.len });
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(sys_task, scheduler.current_id());
    const rc = dispatch(sys_secret_get, .{ @intFromPtr(&buf), buf.len, 0, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, secret.record_bytes), rc);
    const rec = @as(*align(1) const secret.SecretRecord, @ptrCast(&buf));
    try std.testing.expectEqual(process.uid_system, rec.uid);
    try std.testing.expectEqualStrings("audkey", rec.key[0..rec.key_len]);
    try std.testing.expectEqualStrings("systemsecretvalue", rec.val[0..rec.val_len]);
}

test "syscall: SYS_SECRET_GET app-bound entries gate on the caller's image (#2083)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    // task 2 = process 0: a uid_user caller whose image NAME claims the
    // authorized binary but whose file carries no uid_system row.
    _ = scheduler.register_user(0x3000, 0);
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const sshd_pid = process.create_as("GOSSHD.ELF", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}, process.default_principal).?;
    const sshd_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(sshd_pid, sshd_task);
    scheduler.start();
    var frame = fresh_frame();
    trust.init();
    try std.testing.expectEqual(secret.LoadResult.ok, secret.parse(
        "#v1\n" ++
            "hostkey\t1000\tsshprivatevalue\tGOSSHD.ELF\n" ++
            "openkey\t1000\tpublicvalue\n",
    ));
    var buf: [secret.max_secret_entries * secret.record_bytes]u8 = undefined;
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = @intFromPtr(&buf), .len = buf.len });

    // The name-matched caller is still refused while no OWNERS.TXT row
    // proves the image is operator-provisioned: only the unbound key shows.
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(sshd_task, scheduler.current_id());
    var rc = dispatch(sys_secret_get, .{ @intFromPtr(&buf), buf.len, 0, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, secret.record_bytes), rc);
    var rec = @as(*align(1) const secret.SecretRecord, @ptrCast(&buf));
    try std.testing.expectEqualStrings("openkey", rec.key[0..rec.key_len]);
    try std.testing.expect(std.mem.indexOf(u8, &buf, "sshprivatevalue") == null);

    // Once the operator pins GOSSHD.ELF to uid_system, the same caller
    // reads its bound entry.
    try std.testing.expectEqual(trust.LoadResult.ok, trust.load(
        "#v1\nGOSSHD.ELF\t644\t0\t-\n",
    ));
    rc = dispatch(sys_secret_get, .{ @intFromPtr(&buf), buf.len, 0, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, 2 * secret.record_bytes), rc);
    try std.testing.expect(std.mem.indexOf(u8, &buf, "sshprivatevalue") != null);
}

test "syscall: secret VALUES never reach the sys_procs snapshot (D8 redaction)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (uid_user)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expectEqual(secret.LoadResult.ok, secret.parse("#v1\nnetkey\t1000\tsupersecretvalue\n"));
    // The monitor/secrets surface prints the key NAME, so the name may
    // legitimately reach a log; the VALUE must never follow it.
    var snap: [process.max_processes * process.snapshot_row_bytes]u8 = undefined;
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = @intFromPtr(&snap), .len = snap.len });
    const rc = dispatch(sys_procs, .{ @intFromPtr(&snap), snap.len, 0, 0, 0, 0 }, &frame);
    try std.testing.expect(rc > 0);
    try std.testing.expect(std.mem.indexOf(u8, &snap, "supersecretvalue") == null);
    // The snapshot is byte-frozen: no secret-bearing field was added.
    try std.testing.expectEqual(process.snapshot_row_bytes, 40);
}

test "syscall: sys_secret_get is excluded from strace (never-logged contract, D8)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (uid_user)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expectEqual(secret.LoadResult.ok, secret.parse("#v1\nnetkey\t1000\tsupersecretvalue\n"));
    var buf: [secret.max_secret_entries * secret.record_bytes]u8 = undefined;
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = @intFromPtr(&buf), .len = buf.len });
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    // Arm the tracer on the user process (pid 0).
    syscall.strace_pid = 0;
    defer syscall.strace_pid = null;
    // A NORMAL syscall IS traced — proves the tracer works.
    test_write_len = 0;
    _ = dispatch(sys_ping, .{ 9, 0, 0, 0, 0, 0 }, &frame);
    try std.testing.expect(std.mem.indexOf(u8, test_write_buffer[0..test_write_len], "[strace 0] sys_ping") != null);
    const after_ping = test_write_len;
    // sys_secret_get is NOT traced: the capture does not grow at all, so
    // neither the argument pointers nor the returned secret bytes ever
    // reach the transcript.
    _ = dispatch(sys_secret_get, .{ @intFromPtr(&buf), buf.len, 0, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(after_ping, test_write_len);
    // The known secret VALUE is absent from the captured output, and so is
    // the syscall name (the whole line is suppressed).
    try std.testing.expect(std.mem.indexOf(u8, test_write_buffer[0..test_write_len], "supersecretvalue") == null);
    try std.testing.expect(std.mem.indexOf(u8, test_write_buffer[0..test_write_len], "sys_secret_get") == null);
    // A subsequent normal syscall still traces (the exclusion is per-slot).
    _ = dispatch(sys_ping, .{ 10, 0, 0, 0, 0, 0 }, &frame);
    try std.testing.expect(test_write_len > after_ping);
}

test "syscall: SYS_TTY_ATTACH (slot 67, #1072) attaches the caller's terminal" {
    userspace.init();
    init(test_writer);
    driving_award.arm();
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current());

    for (&terminal.terminals) |*t| t.reset();
    file_table.reset_process(0);

    // Without opening /dev/tty there is no controlling terminal: EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_tty_attach, .{ 1, 0, 0, 0, 0, 0 }, &frame));

    // Open the controlling terminal for process 0, then attach serial.
    const fd = file_table.open(0, "/dev/tty", file_table.MODE_READ | file_table.MODE_WRITE);
    try std.testing.expect(fd >= 0);
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_tty_attach, .{ 1, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(terminal.attachedSerial() != null);
    // Idempotent re-attach; detach clears it.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_tty_attach, .{ 1, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_tty_attach, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(terminal.attachedSerial() == null);

    // A window front-end (selector 2) requires an existing `.user` window the
    // caller OWNS (else EINVAL); a bad selector is EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_tty_attach, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    // The net front-end (selector 3, SH7/Amendment B) needs an armed NIC and
    // an own-IP (this host test has neither): the honest refusal is EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_tty_attach, .{ 3, 2323, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_tty_attach, .{ 3, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_tty_attach, .{ 9, 0, 0, 0, 0, 0 }, &frame));

    // Open a `.user` window owned by the caller (process 0) and attach it as
    // the terminal's window front-end; the binding is observable and detach
    // frees it.
    try std.testing.expectEqual(@as(u64, 2), dispatch(sys_win_open, .{ 32, 32, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_tty_attach, .{ 2, 2, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(terminal.windowTerminal(2) != null);
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_tty_attach, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(terminal.windowTerminal(2) == null);

    file_table.reset_process(0);
}

test "syscall: SYS_TTY_NET_AUTH (slot 71, #1138) serves the owner and never traces" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0
    scheduler.start();
    var frame = fresh_frame();
    for (&terminal.terminals) |*t| t.reset();
    file_table.reset_process(0);
    tcp.reset();
    defer tcp.reset();
    virtio_net.net_ready = true;
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    defer {
        virtio_net.net_ready = false;
        virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    }

    // An EL1h caller is not a process: EINVAL, never a read.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_tty_net_auth, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(scheduler.yield_current());

    const fd = file_table.open(0, "/dev/tty", file_table.MODE_READ | file_table.MODE_WRITE);
    try std.testing.expect(fd >= 0);
    // Attach the net front-end in hmac-sha256 mode (selector 3, a2 = 1).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_tty_attach, .{ 3, 2323, 1, 0, 0, 0 }, &frame));
    const t = terminal.attachedNet() orelse return error.TestUnexpectedResult;
    try std.testing.expect(t.net_auth_on);
    try std.testing.expect(!t.net_authed);

    var scratch: [256]u8 = undefined;
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = @intFromPtr(&scratch), .len = scratch.len });
    // No challenge minted yet: op 0 returns 0 (nothing to read).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_tty_net_auth, .{ 0, @intFromPtr(&scratch), scratch.len, 0, 0, 0 }, &frame));
    // Once the pump framed it: op 0 copies the 32 challenge bytes OUT.
    var fixed: [terminal.net_challenge_len]u8 = undefined;
    for (&fixed, 0..) |*b, i| b.* = @intCast(i + 1);
    t.net_challenge = fixed;
    t.net_challenge_sent = true;
    // A too-small out buffer is EINVAL before any copy.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_tty_net_auth, .{ 0, @intFromPtr(&scratch), 8, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 32), dispatch(sys_tty_net_auth, .{ 0, @intFromPtr(&scratch), scratch.len, 0, 0, 0 }, &frame));
    try std.testing.expectEqualSlices(u8, &fixed, scratch[0..32]);
    // No reply yet: op 1 returns 0 and a verdict is EINVAL.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_tty_net_auth, .{ 1, @intFromPtr(&scratch), scratch.len, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_tty_net_auth, .{ 2, @intFromPtr(&scratch), 1, 0, 0, 0 }, &frame));
    // A buffered 64-hex reply: op 1 copies it OUT.
    const hexr = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    @memcpy(t.net_reply[0..64], hexr);
    t.net_reply_len = 64;
    t.net_reply_ready = true;
    // A too-small out buffer is EINVAL before any copy.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_tty_net_auth, .{ 1, @intFromPtr(&scratch), 32, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 64), dispatch(sys_tty_net_auth, .{ 1, @intFromPtr(&scratch), scratch.len, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings(hexr, scratch[0..64]);
    // The verdict op is strace-excluded even while tracing this pid.
    syscall.strace_pid = 0;
    defer syscall.strace_pid = null;
    test_write_len = 0;
    scratch[0] = 1; // accept
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_tty_net_auth, .{ 2, @intFromPtr(&scratch), 1, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 0), test_write_len);
    try std.testing.expect(t.net_authed);
    // A subsequent normal syscall still traces (the exclusion is per-slot).
    _ = dispatch(sys_ping, .{ 1, 0, 0, 0, 0, 0 }, &frame);
    try std.testing.expect(test_write_len > 0);
    // Key-material hygiene: the challenge and reply are wiped on accept.
    try std.testing.expect(std.mem.allEqual(u8, &t.net_challenge, 0));
    try std.testing.expect(std.mem.allEqual(u8, &t.net_reply, 0));
    try std.testing.expectEqual(@as(usize, 0), t.net_reply_len);

    for (&terminal.terminals) |*tt| tt.reset();
    file_table.reset_process(0);
}

// ---------------------------------------------------------------------------
// ADR 0027 (issue #1214 round 2): slots 73/74 — sys_thread + sys_futex
// ---------------------------------------------------------------------------

/// ADR 0027 review finding 1 test seam: a re-check that always reports a
/// changed word, so the post-seat authoritative check path is exercised
/// without a real concurrent peer.
fn futex_never_matches(_: u64, _: u32) bool {
    return false;
}

test "syscall: sys_futex wait re-checks the user word, sleeps, wakes, and times out" {
    mmu.reset();
    alloc.reset_refcounts();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    const pid = process.find_by_task(2).?;

    // Host tests deref user VAs as host pointers, so the futex word is a
    // real test-local buffer registered in the task's uaccess regions —
    // the same path the kernel's 4-byte compare reads through on hardware.
    var futex_word: [8]u8 align(4) = [_]u8{0} ** 8;
    const word_va: u64 = @intFromPtr(&futex_word);
    _ = scheduler.add_task_read_region(2, .{ .base = word_va, .len = 8 });
    _ = scheduler.add_task_write_region(2, .{ .base = word_va, .len = 8 });
    syscall.arm_task_regions();

    // Misaligned uaddr: EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_futex, .{ 0, word_va + 2, 0, 0, 0, 0 }, &frame));
    // Word mismatch -> EAGAIN without blocking (the kernel re-check).
    futex_word[0] = 1;
    try std.testing.expectEqual(error_result(.eagain), dispatch(sys_futex, .{ 0, word_va, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!scheduler.is_blocked(2));

    // Review finding 1: the post-seat re-check is authoritative. A false
    // re-check (a peer stored the word in the fast-compare-to-seat window)
    // clears the seat and reports word_changed instead of parking forever.
    try std.testing.expectEqual(scheduler.FutexWaitOutcome.word_changed, scheduler.futex_wait_current(pid, word_va, 0, 0, futex_never_matches));
    try std.testing.expect(!scheduler.is_blocked(2));

    // Word holds the expected value -> the task BLOCKS (successor staged);
    // the wake from the other-task context returns 1 and x0 = 0.
    futex_word[0] = 0;
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_futex, .{ 0, word_va, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(scheduler.is_blocked(2));
    try std.testing.expectEqual(@as(usize, 1), scheduler.futex_wake(pid, word_va, 1));
    try std.testing.expect(!scheduler.is_blocked(2));
    const woken_frame: *const exceptions.VectorFrame = @ptrFromInt(scheduler.tasks[2].sp);
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(woken_frame, 0));

    // Timeout: rotate back to the user task, wait with a 1-tick deadline,
    // tick, observe -ETIMEDOUT patched into the saved frame.
    var spins: usize = 0;
    while (scheduler.current_id() != 2 and spins < 8) : (spins += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_futex, .{ 0, word_va, 0, timer.period_ns, 0, 0 }, &frame));
    try std.testing.expect(scheduler.is_blocked(2));
    scheduler.on_tick(); // expires the deadline
    try std.testing.expect(!scheduler.is_blocked(2));
    const timeout_frame: *const exceptions.VectorFrame = @ptrFromInt(scheduler.tasks[2].sp);
    try std.testing.expectEqual(syscall.error_result(.etimedout), exceptions.frame_read(timeout_frame, 0));
}

fn futex_boot_user() void {
    mmu.reset();
    alloc.reset_refcounts();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0
    scheduler.start();
}

fn futex_drive_to_user() !void {
    try std.testing.expect(scheduler.yield_current()); // shell -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
}

fn futex_arm_word(task: usize, word_va: u64) void {
    _ = scheduler.add_task_read_region(task, .{ .base = word_va, .len = 8 });
    _ = scheduler.add_task_write_region(task, .{ .base = word_va, .len = 8 });
}

fn futex_init_thread_ram(ram: *[64 * 4096]u8) !void {
    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = @intFromPtr(ram), .virtual_start = 0, .number_of_pages = 64, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));
}

fn futex_yield_until(id: usize) !void {
    var spins: usize = 0;
    while (scheduler.current_id() != id and spins < scheduler.max_tasks) : (spins += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(id, scheduler.current_id());
}

fn tls_task(token: u64) !usize {
    for (scheduler.tasks, 0..) |task, id| {
        if (task.join_token == token) return id;
    }
    return error.MissingThread;
}

test "syscall B5: independent TP contexts, blocking join, status and exact kstack recovery" {
    futex_boot_user();
    var ram: [128 * 4096]u8 align(4096) = undefined;
    const desc = [_]memmap.MemoryDescriptor{.{ .type = .conventional_memory, .physical_start = @intFromPtr(&ram), .virtual_start = 0, .number_of_pages = 128, .attribute = 0 }};
    try std.testing.expect(alloc.init(memmap.MapView.init(std.mem.asBytes(&desc), @sizeOf(memmap.MemoryDescriptor), 1), &.{}));
    try futex_drive_to_user();
    const pid = process.find_by_task(2).?;
    var contexts: [3][64]u8 align(16) = @splat(@splat(0));
    var stacks: [2][4096]u8 align(16) = undefined;
    _ = scheduler.add_task_read_region(2, .{ .base = @intFromPtr(&contexts), .len = @sizeOf(@TypeOf(contexts)) });
    _ = scheduler.add_task_write_region(2, .{ .base = @intFromPtr(&contexts), .len = @sizeOf(@TypeOf(contexts)) });
    _ = scheduler.add_task_write_region(2, .{ .base = @intFromPtr(&stacks), .len = @sizeOf(@TypeOf(stacks)) });
    var frame = fresh_frame();
    const before = alloc.stats().free_pages;
    syscall.arm_task_regions();
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_thread, .{ 3, @intFromPtr(&contexts[0]), 0, 0, 0, 0 }, &frame));
    var tokens: [2]u64 = undefined;
    var ids: [2]usize = undefined;
    for (&tokens, &ids, 0..) |*token, *id, i| {
        token.* = dispatch(sys_thread, .{ 0, userspace.text_va + 4, @intFromPtr(&stacks[i]) + 4096, 80 + i, @intFromPtr(&contexts[i + 1]), 0 }, &frame);
        id.* = try tls_task(token.*);
        try std.testing.expectEqual(@as(u64, @intFromPtr(&contexts[i + 1])), scheduler.tasks[id.*].tls);
        try std.testing.expectEqual(@as(u64, 80 + i), exceptions.frame_read(@ptrFromInt(scheduler.tasks[id.*].sp), 0));
    }
    try std.testing.expect(scheduler.join_thread(pid + 1, tokens[0]) == null);
    exceptions.resume_frame[0] = @intFromPtr(&frame);
    _ = dispatch(sys_thread, .{ 2, tokens[0], 0, 0, 0, 0 }, &frame);
    try std.testing.expect(scheduler.tasks[2].wait_thread);
    // #2093: the joiner parked with the placeholder staged in its saved
    // frame — never the op/argument values the frame held on SVC entry.
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(&frame, 0));
    scheduler.on_tick();
    try std.testing.expect(scheduler.is_blocked(2)); // join is not a timed sleep
    try futex_yield_until(ids[0]);
    try std.testing.expectEqual(scheduler.tasks[ids[0]].tls, scheduler.pending_tls[0]);
    var child_frame = fresh_frame();
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_thread, .{ 2, tokens[0], 0, 0, 0, 0 }, &child_frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_thread, .{ 1, 256, 0, 0, 0, 0 }, &child_frame));
    _ = dispatch(sys_thread, .{ 1, 7, 0, 0, 0, 0 }, &child_frame);
    try std.testing.expectEqual(@as(u64, 7), exceptions.frame_read(&frame, 0));
    try std.testing.expect(!scheduler.tasks[2].wait_thread);
    try std.testing.expect(scheduler.reap(ids[0]));
    try futex_yield_until(ids[1]);
    _ = dispatch(sys_thread, .{ 1, 9, 0, 0, 0, 0 }, &child_frame);
    try std.testing.expect(!scheduler.reap(ids[1])); // retain before late join
    try futex_yield_until(2);
    try std.testing.expectEqual(@as(u64, @intFromPtr(&contexts[0])), scheduler.pending_tls[0]);
    try std.testing.expectEqual(@as(u64, 9), dispatch(sys_thread, .{ 2, tokens[1], 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_thread, .{ 2, tokens[1], 0, 0, 0, 0 }, &frame));
    try std.testing.expect(scheduler.reap(ids[1]));
    try std.testing.expectEqual(before, alloc.stats().free_pages);
    const new_token = dispatch(sys_thread, .{ 0, userspace.text_va + 4, @intFromPtr(&stacks[0]) + 4096, 0, @intFromPtr(&contexts[1]), 0 }, &frame);
    try std.testing.expect(new_token > tokens[1]);
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_thread, .{ 2, tokens[0], 0, 0, 0, 0 }, &frame));
}

test "syscall B5: native live and retained threads share the existing six-thread capacity" {
    futex_boot_user();
    var ram: [512 * 4096]u8 align(4096) = undefined;
    const desc = [_]memmap.MemoryDescriptor{.{ .type = .conventional_memory, .physical_start = @intFromPtr(&ram), .virtual_start = 0, .number_of_pages = 512, .attribute = 0 }};
    try std.testing.expect(alloc.init(memmap.MapView.init(std.mem.asBytes(&desc), @sizeOf(memmap.MemoryDescriptor), 1), &.{}));
    try futex_drive_to_user();
    var contexts: [7][64]u8 align(16) = undefined;
    var stacks: [7][4096]u8 align(16) = undefined;
    _ = scheduler.add_task_read_region(2, .{ .base = @intFromPtr(&contexts), .len = @sizeOf(@TypeOf(contexts)) });
    _ = scheduler.add_task_write_region(2, .{ .base = @intFromPtr(&contexts), .len = @sizeOf(@TypeOf(contexts)) });
    _ = scheduler.add_task_write_region(2, .{ .base = @intFromPtr(&stacks), .len = @sizeOf(@TypeOf(stacks)) });
    var frame = fresh_frame();
    var tokens: [6]u64 = undefined;
    syscall.arm_task_regions();
    for (&tokens, 0..) |*token, i| {
        token.* = dispatch(sys_thread, .{ 0, userspace.text_va + 4, @intFromPtr(&stacks[i]) + 4096, i, @intFromPtr(&contexts[i]), 0 }, &frame);
        _ = try tls_task(token.*);
    }
    const before = alloc.stats().free_pages;
    const seventh: Args = .{ 0, userspace.text_va + 4, @intFromPtr(&stacks[6]) + 4096, 0, @intFromPtr(&contexts[6]), 0 };
    try std.testing.expectEqual(error_result(.eagain), dispatch(sys_thread, seventh, &frame));
    try std.testing.expectEqual(before, alloc.stats().free_pages);
    const first = try tls_task(tokens[0]);
    try futex_yield_until(first);
    var death = fresh_frame();
    _ = dispatch(sys_thread, .{ 1, 0, 0, 0, 0, 0 }, &death);
    try futex_yield_until(2);
    try std.testing.expectEqual(error_result(.eagain), dispatch(sys_thread, seventh, &frame));
    _ = dispatch(sys_thread, .{ 2, tokens[0], 0, 0, 0, 0 }, &frame);
    try std.testing.expect(scheduler.reap(first));
    const replacement = dispatch(sys_thread, seventh, &frame);
    _ = try tls_task(replacement);
    try std.testing.expect(replacement > tokens[5]);
}

test "syscall B5: TLS and stack prefix validation refuse without seating a thread" {
    futex_boot_user();
    try futex_drive_to_user();
    var frame = fresh_frame();
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_thread, .{ 0, userspace.text_va + 4, 0x70000000, 0, 1, 0 }, &frame));
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_thread, .{ 0, userspace.text_va + 4, 0x70000000, 0, 0x60000000, 0 }, &frame));
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_thread, .{ 3, 0x60000000, 0, 0, 0, 0 }, &frame));
    var prefix: [16]u8 align(16) = undefined;
    _ = scheduler.add_task_read_region(2, .{ .base = @intFromPtr(&prefix), .len = 16 });
    _ = scheduler.add_task_write_region(2, .{ .base = @intFromPtr(&prefix), .len = 16 });
    syscall.arm_task_regions();
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_thread, .{ 0, userspace.text_va + 4, 0x70000000, 0, @intFromPtr(&prefix), 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_thread, .{ 3, 0, 0, 0, 0, 0 }, &frame));
}

test "syscall B5: process exit releases retained completions and a blocked joiner" {
    futex_boot_user();
    var ram: [128 * 4096]u8 align(4096) = undefined;
    const desc = [_]memmap.MemoryDescriptor{.{ .type = .conventional_memory, .physical_start = @intFromPtr(&ram), .virtual_start = 0, .number_of_pages = 128, .attribute = 0 }};
    try std.testing.expect(alloc.init(memmap.MapView.init(std.mem.asBytes(&desc), @sizeOf(memmap.MemoryDescriptor), 1), &.{}));
    try futex_drive_to_user();
    const pid = process.find_by_task(2).?;
    var contexts: [2][64]u8 align(16) = undefined;
    var stacks: [2][4096]u8 align(16) = undefined;
    _ = scheduler.add_task_read_region(2, .{ .base = @intFromPtr(&contexts), .len = @sizeOf(@TypeOf(contexts)) });
    _ = scheduler.add_task_write_region(2, .{ .base = @intFromPtr(&contexts), .len = @sizeOf(@TypeOf(contexts)) });
    _ = scheduler.add_task_write_region(2, .{ .base = @intFromPtr(&stacks), .len = @sizeOf(@TypeOf(stacks)) });
    syscall.arm_task_regions();
    const before = alloc.stats().free_pages;
    var frame = fresh_frame();
    var tokens: [2]u64 = undefined;
    var ids: [2]usize = undefined;
    for (&tokens, &ids, 0..) |*token, *id, i| {
        token.* = dispatch(sys_thread, .{ 0, userspace.text_va + 4, @intFromPtr(&stacks[i]) + 4096, 0, @intFromPtr(&contexts[i]), 0 }, &frame);
        id.* = try tls_task(token.*);
        try std.testing.expect(!scheduler.tasks[id.*].secondary_ok);
    }
    try futex_yield_until(ids[0]);
    _ = dispatch(sys_thread, .{ 1, 0, 0, 0, 0, 0 }, &frame);
    try std.testing.expect(!scheduler.reap(ids[0]));
    try futex_yield_until(2);
    exceptions.resume_frame[0] = @intFromPtr(&frame);
    _ = dispatch(sys_thread, .{ 2, tokens[1], 0, 0, 0, 0 }, &frame);
    try std.testing.expect(scheduler.tasks[2].wait_thread);
    try futex_yield_until(ids[1]);
    _ = dispatch(sys_exit, .{ 0, 0, 0, 0, 0, 0 }, &frame);
    var turns: usize = 0;
    while (process.info(pid).?.state != .exited and turns < scheduler.max_tasks) : (turns += 1)
        try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(process.State.exited, process.info(pid).?.state);
    try std.testing.expect(!scheduler.tasks[2].wait_thread);
    for (ids) |id| {
        try std.testing.expectEqual(@as(u64, 0), scheduler.tasks[id].join_token);
        try std.testing.expect(scheduler.tasks[id].joiner == null);
        try std.testing.expect(scheduler.reap(id));
    }
    try std.testing.expect(scheduler.reap(2));
    try std.testing.expectEqual(before, alloc.stats().free_pages);
}

test "syscall B5: strict futex precision refusal, phase guard and no stale timeout seat" {
    futex_boot_user();
    try futex_drive_to_user();
    var word: u32 = 0;
    futex_arm_word(2, @intFromPtr(&word));
    var frame = fresh_frame();
    syscall.arm_task_regions();
    exceptions.resume_frame[0] = @intFromPtr(&frame);
    for ([_]u64{ 1, timer.period_ns - 1, timer.period_ns + 1, std.math.maxInt(u64) }) |ns| {
        try std.testing.expectEqual(error_result(.einval), dispatch(sys_futex, .{ 2, @intFromPtr(&word), 0, ns, 0, 0 }, &frame));
        try std.testing.expect(!scheduler.is_blocked(2));
    }
    _ = dispatch(sys_futex, .{ 2, @intFromPtr(&word), 0, timer.period_ns, 0, 0 }, &frame);
    scheduler.on_tick();
    try std.testing.expect(scheduler.is_blocked(2));
    scheduler.on_tick();
    try std.testing.expect(!scheduler.is_blocked(2));
    try std.testing.expectEqual(error_result(.etimedout), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(usize, 0), scheduler.futex_wake(process.find_by_task(2).?, @intFromPtr(&word), 6));
}

test "syscall B5: two contended futex seats wake exactly n, never another process" {
    futex_boot_user();
    var ram: [128 * 4096]u8 align(4096) = undefined;
    const desc = [_]memmap.MemoryDescriptor{.{ .type = .conventional_memory, .physical_start = @intFromPtr(&ram), .virtual_start = 0, .number_of_pages = 128, .attribute = 0 }};
    try std.testing.expect(alloc.init(memmap.MapView.init(std.mem.asBytes(&desc), @sizeOf(memmap.MemoryDescriptor), 1), &.{}));
    try futex_drive_to_user();
    const pid = process.find_by_task(2).?;
    var word: u32 = 1;
    futex_arm_word(2, @intFromPtr(&word));
    var frame = fresh_frame();
    syscall.arm_task_regions();
    exceptions.resume_frame[0] = @intFromPtr(&frame);
    const tid = dispatch(sys_thread, .{ 0, userspace.text_va + 4, 0x70000000, 0, 0, 0 }, &frame);
    _ = dispatch(sys_futex, .{ 0, @intFromPtr(&word), 1, 0, 0, 0 }, &frame);
    try futex_yield_until(@intCast(tid));
    var peer = fresh_frame();
    syscall.arm_task_regions();
    exceptions.resume_frame[0] = @intFromPtr(&peer);
    _ = dispatch(sys_futex, .{ 0, @intFromPtr(&word), 1, 0, 0, 0 }, &peer);
    try std.testing.expectEqual(@as(usize, 0), scheduler.futex_wake(pid + 1, @intFromPtr(&word), 2));
    try std.testing.expectEqual(@as(usize, 0), scheduler.futex_wake(pid, @intFromPtr(&word), 0));
    try std.testing.expectEqual(@as(usize, 1), scheduler.futex_wake(pid, @intFromPtr(&word), 1));
    try std.testing.expectEqual(@as(usize, 1), scheduler.futex_wake(pid, @intFromPtr(&word), 2));
    try std.testing.expectEqual(@as(usize, 0), scheduler.futex_wake(pid, @intFromPtr(&word), 2));
    try futex_yield_until(2);
    @atomicStore(u32, &word, 0, .release);
    syscall.arm_task_regions();
    try std.testing.expectEqual(@as(usize, 0), scheduler.futex_wake(pid, @intFromPtr(&word), 1));
    try std.testing.expectEqual(error_result(.eagain), dispatch(sys_futex, .{ 0, @intFromPtr(&word), 1, 0, 0, 0 }, &frame));
    // Simulate a store in the fast-compare -> seat window. The authoritative
    // compare after seating refuses and removes the seat, not a lost wake.
    try std.testing.expectEqual(scheduler.FutexWaitOutcome.word_changed, scheduler.futex_wait_current(pid, @intFromPtr(&word), 1, 0, futex_never_matches));
    try std.testing.expectEqual(@as(usize, 0), scheduler.futex_wake(pid, @intFromPtr(&word), 1));
}

test "syscall: sys_futex wait-equals parks while the user word matches (ADR 0027 D4)" {
    // Op 0 waits only when the kernel-verified 4-byte word still holds val.
    futex_boot_user();
    var frame = fresh_frame();
    try futex_drive_to_user();
    const pid = process.find_by_task(2).?;

    var futex_word: [8]u8 align(4) = [_]u8{0} ** 8;
    const word_va: u64 = @intFromPtr(&futex_word);
    futex_arm_word(2, word_va);
    syscall.arm_task_regions();

    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_futex, .{ 0, word_va, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(scheduler.is_blocked(2));
    try std.testing.expect(scheduler.tasks[2].futex_waiting);
    try std.testing.expectEqual(@as(usize, 1), scheduler.futex_wake(pid, word_va, 1));
    try std.testing.expect(!scheduler.is_blocked(2));
}

test "syscall: sys_futex op 1 wake(n) default 1 unparks a same-process waiter (ADR 0027 D4)" {
    // Go's semawakeup passes n=1; n=0 wakes nobody (Linux FUTEX_WAKE).
    futex_boot_user();
    var thread_test_ram: [64 * 4096]u8 align(4096) = undefined;
    try futex_init_thread_ram(&thread_test_ram);
    var frame = fresh_frame();
    try futex_drive_to_user();
    const pid = process.find_by_task(2).?;

    var futex_word: [8]u8 align(4) = [_]u8{0} ** 8;
    const word_va: u64 = @intFromPtr(&futex_word);
    futex_arm_word(2, word_va);
    syscall.arm_task_regions();

    const tid = dispatch(sys_thread, .{ 0, userspace.text_va + 4, 0x7000_0000, 0, 0, 0 }, &frame);
    try std.testing.expect(tid < scheduler.max_tasks);
    const thread_id: usize = @intCast(tid);
    try std.testing.expectEqual(pid, process.find_by_task(thread_id).?);

    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_futex, .{ 0, word_va, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(scheduler.is_blocked(2));
    try futex_yield_until(thread_id);
    syscall.arm_task_regions();

    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_futex, .{ 1, word_va, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(scheduler.is_blocked(2));
    try std.testing.expectEqual(@as(u64, 1), dispatch(sys_futex, .{ 1, word_va, 1, 0, 0, 0 }, &frame));
    try std.testing.expect(!scheduler.is_blocked(2));
    const woken_frame: *const exceptions.VectorFrame = @ptrFromInt(scheduler.tasks[2].sp);
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(woken_frame, 0));
}

test "syscall: sys_futex ETIMEDOUT is distinct from a real wake (ADR 0027 D4)" {
    futex_boot_user();
    var frame = fresh_frame();
    try futex_drive_to_user();
    const pid = process.find_by_task(2).?;

    var futex_word: [8]u8 align(4) = [_]u8{0} ** 8;
    const word_va: u64 = @intFromPtr(&futex_word);
    futex_arm_word(2, word_va);
    syscall.arm_task_regions();

    const wake_rc: u64 = 0;
    const timeout_rc = error_result(.etimedout);
    try std.testing.expect(wake_rc != timeout_rc);
    try std.testing.expectEqual(@as(i64, -12), @as(i64, @bitCast(timeout_rc)));

    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_futex, .{ 0, word_va, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(scheduler.is_blocked(2));
    try std.testing.expectEqual(@as(usize, 1), scheduler.futex_wake(pid, word_va, 1));
    try std.testing.expect(!scheduler.is_blocked(2));
    const woken_frame: *const exceptions.VectorFrame = @ptrFromInt(scheduler.tasks[2].sp);
    try std.testing.expectEqual(wake_rc, exceptions.frame_read(woken_frame, 0));

    try futex_yield_until(2);
    syscall.arm_task_regions();
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_futex, .{ 0, word_va, 0, timer.period_ns, 0, 0 }, &frame));
    try std.testing.expect(scheduler.is_blocked(2));
    scheduler.on_tick();
    try std.testing.expect(!scheduler.is_blocked(2));
    const timeout_frame: *const exceptions.VectorFrame = @ptrFromInt(scheduler.tasks[2].sp);
    try std.testing.expectEqual(timeout_rc, exceptions.frame_read(timeout_frame, 0));
}

test "syscall: sys_futex death-wakes-peer (ADR 0027 D4 exitThread)" {
    // Two same-process waiters on one word. The dying waiter leaves its
    // seat with wake(1); the peer resumes with x0 = 0 (a real wake, not
    // ETIMEDOUT). The process lives — this is thread-exit, not sys_exit.
    futex_boot_user();
    var thread_test_ram: [64 * 4096]u8 align(4096) = undefined;
    try futex_init_thread_ram(&thread_test_ram);
    var frame = fresh_frame();
    try futex_drive_to_user();
    const pid = process.find_by_task(2).?;

    var futex_word: [8]u8 align(4) = [_]u8{0} ** 8;
    const word_va: u64 = @intFromPtr(&futex_word);
    futex_arm_word(2, word_va);
    syscall.arm_task_regions();

    const tid = dispatch(sys_thread, .{ 0, userspace.text_va + 4, 0x7000_0000, 0, 0, 0 }, &frame);
    try std.testing.expect(tid < scheduler.max_tasks);
    const thread_id: usize = @intCast(tid);

    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(thread_id, scheduler.current_id());
    syscall.arm_task_regions();
    var tframe = fresh_frame();
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_futex, .{ 0, word_va, 0, 0, 0, 0 }, &tframe));
    try std.testing.expect(scheduler.is_blocked(thread_id));
    try std.testing.expect(scheduler.tasks[thread_id].futex_waiting);

    try futex_yield_until(2);
    syscall.arm_task_regions();
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_futex, .{ 0, word_va, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(scheduler.is_blocked(2));
    try std.testing.expect(scheduler.tasks[2].futex_waiting);

    scheduler.tasks[thread_id].state = .running;
    scheduler.current[0] = thread_id;
    var death = fresh_frame();
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_thread, .{ 1, 0, 0, 0, 0, 0 }, &death));
    try std.testing.expect(scheduler.is_terminated(thread_id));
    try std.testing.expect(!scheduler.is_blocked(2));
    const peer_frame: *const exceptions.VectorFrame = @ptrFromInt(scheduler.tasks[2].sp);
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(peer_frame, 0));
    try std.testing.expect(error_result(.etimedout) != exceptions.frame_read(peer_frame, 0));
    try std.testing.expect(process.info(pid).?.state == .running);
}

test "syscall: sys_thread creates a same-process task and op 1 exits only the thread" {
    mmu.reset();
    alloc.reset_refcounts();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (primary)
    scheduler.start();
    // The thread's EL1 kstack is pool-allocated: arm the physical allocator
    // the exec tests do — host tests identity-map phys == kernel pointer, so
    // the fixture's "physical" base must be a real host-writable buffer.
    var thread_test_ram: [64 * 4096]u8 align(4096) = undefined;
    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = @intFromPtr(&thread_test_ram), .virtual_start = 0, .number_of_pages = 64, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    const pid = process.find_by_task(2).?;

    // Refusals: unknown op, bad tls, null stack_hi, misaligned stack_hi,
    // entry outside the process's executable text aperture.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_thread, .{ 2, userspace.text_va + 4, 0x7000_0000, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_thread, .{ 0, userspace.text_va + 4, 0x7000_0000, 0, 1, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_thread, .{ 0, userspace.text_va + 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_thread, .{ 0, userspace.text_va + 4, 0x7000_0003, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_thread, .{ 0, 0x9000_0000, 0x7000_0000, 0, 0, 0 }, &frame));

    // Create: entry inside text, 16-byte-aligned stack_hi, arg = 0x1234.
    // ADR 0027 D3: the initial frame uses the same machinery as
    // register_exec_user — x0 = arg, pc/ELR = entry, SP_EL0 = stack_hi.
    const entry: u64 = userspace.text_va + 4;
    const stack_hi: u64 = 0x7000_0000;
    const tid = dispatch(sys_thread, .{ 0, entry, stack_hi, 0x1234, 0, 0 }, &frame);
    try std.testing.expect(tid < scheduler.max_tasks);
    const thread_id: usize = @intCast(tid);
    // Same process, thread-shaped (own kstack), unpinned, named like the process.
    try std.testing.expectEqual(pid, process.find_by_task(thread_id).?);
    try std.testing.expect(process.info(pid).?.state == .running);
    try std.testing.expect(scheduler.tasks[thread_id].is_thread);
    try std.testing.expect(scheduler.tasks[thread_id].thread_kstack_phys != 0);
    try std.testing.expect(scheduler.tasks[thread_id].secondary_ok);
    try std.testing.expectEqualStrings(process.info(pid).?.name, scheduler.tasks[thread_id].name);
    const thread_frame: *const exceptions.VectorFrame = @ptrFromInt(scheduler.tasks[thread_id].sp);
    try std.testing.expectEqual(@as(u64, 0x1234), exceptions.frame_read(thread_frame, 0));
    try std.testing.expectEqual(entry, scheduler.tasks[thread_id].elr);
    try std.testing.expectEqual(stack_hi, scheduler.tasks[thread_id].sp_el0);

    // Op 1 from the thread: only the thread exits; the process survives.
    try std.testing.expect(scheduler.yield_current()); // rotate until the thread is current
    try std.testing.expectEqual(thread_id, scheduler.current_id());
    var exit_frame = fresh_frame();
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_thread, .{ 1, 0, 0, 0, 0, 0 }, &exit_frame));
    try std.testing.expect(scheduler.is_terminated(thread_id));
    try std.testing.expect(process.info(pid).?.state == .running);
    // Reap the thread; the pool slot frees without touching process pages.
    try std.testing.expect(scheduler.reap(thread_id));

    // Primary exits via sys_exit: the process dies with the requested status.
    var spins2: usize = 0;
    while (scheduler.current_id() != 2 and spins2 < 8) : (spins2 += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    var exit2 = fresh_frame();
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_exit, .{ 7, 0, 0, 0, 0, 0 }, &exit2));
    try std.testing.expect(process.info(pid).?.state == .exited);
    try std.testing.expectEqual(@as(u64, 7), process.info(pid).?.exit_status);
}

test "syscall: sys_thread last remaining task dies the process (ADR 0027 D2/D3)" {
    // Thread-exit (op 1) is not process-exit. sys_exit stays process-exit;
    // the process dies only when its LAST task leaves.
    mmu.reset();
    alloc.reset_refcounts();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (primary)
    scheduler.start();
    var thread_test_ram: [64 * 4096]u8 align(4096) = undefined;
    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = @intFromPtr(&thread_test_ram), .virtual_start = 0, .number_of_pages = 64, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    const pid = process.find_by_task(2).?;

    const tid = dispatch(sys_thread, .{ 0, userspace.text_va + 4, 0x7000_0000, 0, 0, 0 }, &frame);
    try std.testing.expect(tid < scheduler.max_tasks);
    const thread_id: usize = @intCast(tid);
    try std.testing.expect(process.info(pid).?.state == .running);

    // Child thread-exits: the process stays running with the primary.
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(thread_id, scheduler.current_id());
    var child_exit = fresh_frame();
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_thread, .{ 1, 0, 0, 0, 0, 0 }, &child_exit));
    try std.testing.expect(scheduler.is_terminated(thread_id));
    try std.testing.expect(process.info(pid).?.state == .running);
    try std.testing.expect(scheduler.reap(thread_id));

    // Primary thread-exits (op 1, not sys_exit) as the last remaining task:
    // the process dies with this task's status (0 — no prior sys_exit snapshot).
    var spins: usize = 0;
    while (scheduler.current_id() != 2 and spins < 8) : (spins += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    var last_exit = fresh_frame();
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_thread, .{ 1, 0, 0, 0, 0, 0 }, &last_exit));
    try std.testing.expect(scheduler.is_terminated(2));
    try std.testing.expect(process.info(pid).?.state == .exited);
    try std.testing.expectEqual(@as(u64, 0), process.info(pid).?.exit_status);
}

test "syscall: sys_thread op 1 reap frees the thread EL1 kstack (ADR 0027 D3)" {
    mmu.reset();
    alloc.reset_refcounts();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    var thread_test_ram: [64 * 4096]u8 align(4096) = undefined;
    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = @intFromPtr(&thread_test_ram), .virtual_start = 0, .number_of_pages = 64, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    const pid = process.find_by_task(2).?;
    const free_before = alloc.stats().free_pages;

    const tid = dispatch(sys_thread, .{ 0, userspace.text_va + 4, 0x7000_0000, 0, 0, 0 }, &frame);
    try std.testing.expect(tid < scheduler.max_tasks);
    const thread_id: usize = @intCast(tid);
    const kstack_pages = scheduler.tasks[thread_id].thread_kstack_pages;
    try std.testing.expect(kstack_pages > 0);
    try std.testing.expectEqual(free_before - kstack_pages, alloc.stats().free_pages);

    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(thread_id, scheduler.current_id());
    var exit_frame = fresh_frame();
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_thread, .{ 1, 0, 0, 0, 0, 0 }, &exit_frame));
    try std.testing.expect(scheduler.is_terminated(thread_id));
    try std.testing.expect(process.info(pid).?.state == .running);
    // Exit marks the zombie; the kstack returns on reap (D3).
    try std.testing.expectEqual(free_before - kstack_pages, alloc.stats().free_pages);
    try std.testing.expect(scheduler.reap(thread_id));
    try std.testing.expectEqual(free_before, alloc.stats().free_pages);
    try std.testing.expectEqual(@as(u64, 0), scheduler.tasks[thread_id].thread_kstack_phys);
    try std.testing.expectEqual(@as(u64, 0), scheduler.tasks[thread_id].thread_kstack_pages);
}

test "syscall: mmap is process-scope — a post-spawn mapping reaches a thread (ADR 0027 review finding 2)" {
    mmu.reset();
    alloc.reset_refcounts();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    // spawn_thread allocates its EL1 kstack from the physical pool (the
    // fixture's identity-mapped host buffer).
    var thread_test_ram: [64 * 4096]u8 align(4096) = undefined;
    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = @intFromPtr(&thread_test_ram), .virtual_start = 0, .number_of_pages = 64, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    // Thread FIRST: its TCB region snapshot predates the mapping below —
    // exactly the case the old per-TCB registration missed.
    const tid = dispatch(sys_thread, .{ 0, userspace.text_va + 4, 0x7000_0000, 0, 0, 0 }, &frame);
    try std.testing.expect(tid < scheduler.max_tasks);
    const thread_id: usize = @intCast(tid);

    // ...then the primary maps. Arm from the THREAD: the process-scope
    // merge must make the new mapping visible even though the thread's own
    // TCB copy never saw it.
    const va = dispatch(sys_mmap, .{ 0, 4096, 3, 0x22, 0, 0 }, &frame);
    try std.testing.expect(va >= 0x1000_0000);
    var spins: usize = 0;
    while (scheduler.current_id() != thread_id and spins < 8) : (spins += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(thread_id, scheduler.current_id());
    syscall.arm_task_regions();
    try std.testing.expect(uaccess.read_region_covers(va, 8));
}

// Issue #1228 (phase 0c): slot 75 sys_exnotify — register/unregister/refuse,
// plus the EL0 delivery rewrite (frame x0-x4 + ELR redirect) and the
// nested-fault refusal that keeps a faulting handler from looping.
test "syscall: sys_exnotify registers the handler and EL0 faults deliver to it" {
    mmu.reset();
    alloc.reset_refcounts();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (primary)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    const pid = process.find_by_task(2).?;

    // Refusals: misaligned handler, handler outside the process's
    // executable text aperture. Zero is not a refusal — it unregisters.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_exnotify, .{ userspace.text_va + 1, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_exnotify, .{ 0x9000_0000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!process.set_exnotify_handler(999, userspace.text_va));

    // Register: a 4-aligned PC inside text.
    const handler = userspace.text_va + 0x40;
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_exnotify, .{ handler, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(handler, process.exnotify_handler(pid).?);

    // Delivery: an EL0 data abort (EC 0x24) rewrites the SAME frame with
    // the fault record and redirects ELR at the handler (staged in
    // test_redirect_pc on host; `msr elr_el1` on hardware).
    exceptions.test_redirect_pc = 0;
    var dframe = fresh_frame();
    const esr: u64 = 0x24 << 26;
    const res = exceptions.exc_dispatch(&dframe, esr, 0xdead, 0x5000, 0, exceptions.kind_sync);
    try std.testing.expectEqual(@intFromPtr(&dframe), res.frame);
    try std.testing.expectEqual(@as(u64, 11), exceptions.frame_read(&dframe, 0)); // SIGSEGV
    try std.testing.expectEqual(@as(u64, 0xdead), exceptions.frame_read(&dframe, 1)); // FAR
    try std.testing.expectEqual(@as(u64, 0x5000), exceptions.frame_read(&dframe, 2)); // PC
    try std.testing.expectEqual(esr, exceptions.frame_read(&dframe, 3)); // ESR
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(&dframe, 4)); // SP_EL0 (host: none)
    try std.testing.expectEqual(handler, exceptions.test_redirect_pc);

    // Nested fault (PC already the handler) refuses delivery: with no test
    // dispatcher installed the report path parks (frame 0), i.e. the reap
    // shape — and the redirect is untouched.
    exceptions.test_redirect_pc = 0;
    var nframe = fresh_frame();
    const nres = exceptions.exc_dispatch(&nframe, esr, 0xdead, handler, 0, exceptions.kind_sync);
    try std.testing.expectEqual(@as(u64, 0), nres.frame);
    try std.testing.expectEqual(@as(u64, 0), exceptions.test_redirect_pc);

    // Unregister (zero): the process is reap-shaped again.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_exnotify, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), process.exnotify_handler(pid).?);
}

test "pipe: EL0 slots bind per-process — no cross-pid read, write or steal (#2081)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 -> pid 0
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const other = process.create_as("OTHER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}, process.default_principal).?;
    const other_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(other, other_task);
    scheduler.start();

    var frame = fresh_frame();
    var wbuf: [64]u8 = [_]u8{0} ** 64;
    var rbuf: [64]u8 = [_]u8{0} ** 64;
    set_user_regions(.{ .base = @intFromPtr(&wbuf), .len = wbuf.len }, .{ .base = @intFromPtr(&rbuf), .len = rbuf.len });

    var hops: usize = 0;
    while (scheduler.current_id() != 2 and hops < 8) : (hops += 1) _ = scheduler.yield_current();
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    // pid 0 stages pipeline bytes, then drains five of them.
    @memcpy(wbuf[0..11], "staged-one!");
    try std.testing.expectEqual(@as(u64, 11), dispatch(sys_pipe_write, .{ @intFromPtr(&wbuf), 11, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 5), dispatch(sys_pipe_read, .{ @intFromPtr(&rbuf), 5, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("stage", rbuf[0..5]);

    // A second same-uid pid cannot snoop the staged remainder ...
    hops = 0;
    while (scheduler.current_id() != other_task and hops < 8) : (hops += 1) _ = scheduler.yield_current();
    try std.testing.expectEqual(other_task, scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_pipe_read, .{ @intFromPtr(&rbuf) + 5, 32, 0, 0, 0, 0 }, &frame));
    // ... and its own writes land in ITS pipe, invisible to the victim.
    @memcpy(wbuf[0..5], "attkr");
    try std.testing.expectEqual(@as(u64, 5), dispatch(sys_pipe_write, .{ @intFromPtr(&wbuf), 5, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 5), dispatch(sys_pipe_read, .{ @intFromPtr(&rbuf) + 5, 32, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("attkr", rbuf[5..10]);

    // The owner's remaining staged bytes are intact and private.
    hops = 0;
    while (scheduler.current_id() != 2 and hops < 8) : (hops += 1) _ = scheduler.yield_current();
    try std.testing.expectEqual(@as(u64, 11 - 5), dispatch(sys_pipe_read, .{ @intFromPtr(&rbuf) + 10, 32, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("d-one!", rbuf[10..16]);

    // Table exhaustion is an honest ENOSPC, not a cross-pipe leak: hold a
    // byte in every other slot, then the next pid's write refuses.
    var holders: [syscall.pipe.max_el0_pipes]usize = undefined;
    var held: usize = 0;
    for (0..syscall.pipe.max_el0_pipes) |_| {
        const hp = process.create_as("HOLD.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}, process.default_principal) orelse break;
        if (syscall.pipe.el0_append(hp)) |_| {
            syscall.pipe.el0_advance_write(hp, 1);
            holders[held] = hp;
            held += 1;
        }
    }
    // pid 0 already holds a drained-free... its pipe is empty (drained), so
    // every table slot is either held or free; if the table is full the
    // write must refuse rather than share.
    const wr = dispatch(sys_pipe_write, .{ @intFromPtr(&wbuf), 5, 0, 0, 0, 0 }, &frame);
    if (held == syscall.pipe.max_el0_pipes) {
        try std.testing.expectEqual(error_result(.enospc), wr);
    } else {
        try std.testing.expectEqual(@as(u64, 5), wr);
    }
    // Releasing a held slot (drain) makes room again.
    if (held > 0) {
        syscall.pipe.el0_advance_read(holders[0], 1);
        try std.testing.expectEqual(@as(u64, 5), dispatch(sys_pipe_write, .{ @intFromPtr(&wbuf), 5, 0, 0, 0, 0 }, &frame));
    }
    for (holders[0..held]) |hp| _ = process.reap(hp);
}

test "syscall: copy_in/load_u32 consult the read resolver — a refused source faults without reading (issue #2109)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 -> pid 0
    scheduler.start();
    var frame = fresh_frame();
    var hops: usize = 0;
    while (scheduler.current_id() != 2 and hops < 8) : (hops += 1) _ = scheduler.yield_current();
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    var src: [16]u8 align(4) = [_]u8{0} ** 16;
    set_user_regions(.{ .base = @intFromPtr(&src), .len = src.len }, .{ .base = @intFromPtr(&src), .len = src.len });

    // Drain anything an earlier test left in this pid's pipe so the staged
    // byte count below is exact.
    while (dispatch(sys_pipe_read, .{ @intFromPtr(&src), src.len, 0, 0, 0, 0 }, &frame) != 0) {}
    @memcpy(src[0..4], "data");

    // Baseline: the pipe write lands and the futex word loads.
    try std.testing.expectEqual(@as(u64, 4), dispatch(sys_pipe_write, .{ @intFromPtr(&src), 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(?u32, std.mem.readInt(u32, src[0..4], .little)), uaccess.load_u32(@intFromPtr(&src)));

    // A refusing resolver (the "not this process's page" verdict the kernel
    // returns for a registered-but-unpopulated mmap page it cannot populate)
    // turns the copy into EFAULT and the word load into null — the read-side
    // twin of the #1391 write-resolver refusal pinned above.
    const previous = uaccess.resolve_read_pages;
    defer uaccess.resolve_read_pages = previous;
    uaccess.resolve_read_pages = &struct {
        fn refuse(_: u64, _: usize) bool {
            return false;
        }
    }.refuse;
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_pipe_write, .{ @intFromPtr(&src), 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(?u32, null), uaccess.load_u32(@intFromPtr(&src)));
    // The staged pipe bytes are unchanged: the refused copy read nothing and
    // appended nothing.
    try std.testing.expectEqual(@as(u64, 4), dispatch(sys_pipe_read, .{ @intFromPtr(&src) + 4, 8, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_pipe_read, .{ @intFromPtr(&src) + 8, 8, 0, 0, 0, 0 }, &frame));
}
