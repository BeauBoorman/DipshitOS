//! ADR 0007 numbering and argument shapes. Data only: no slice/function
//! pointers in this const table (the flat-image ADR 0005 rule).
const std = @import("std");

pub const slot_count = 128;
pub const ArgKind = enum(u8) { int, fd, pid, ptr, string, flags, redacted };
pub const Arg = struct {
    kind: ArgKind = .int,
    length_arg: u8 = 0,
    length_mask: u64 = 0,
};
pub const Slot = struct {
    number: u8,
    name_bytes: [32]u8,
    name_len: u8,
    arg_count: u8,
    args: [6]Arg,

    pub fn name(self: *const Slot) []const u8 {
        return self.name_bytes[0..self.name_len];
    }
};
pub const Variant = struct {
    number: u8,
    selector: u8,
    op: u64,
    arg_count: u8,
    args: [6]Arg,
};

fn str(length_arg: u8) Arg {
    return .{ .kind = .string, .length_arg = length_arg, .length_mask = std.math.maxInt(u64) };
}

fn str_flags(length_arg: u8) Arg {
    var arg = str(length_arg);
    arg.length_mask >>= 1;
    return arg;
}

fn arg_list(values: anytype) [6]Arg {
    var args = @as([6]Arg, @splat(@as(Arg, .{})));
    inline for (values, 0..) |value, index| {
        args[index] = if (@TypeOf(value) == Arg) value else .{ .kind = value };
    }
    return args;
}

fn row(number_in: u8, name_in: []const u8, values: anytype) Slot {
    var slot: Slot = .{
        .number = number_in,
        .name_bytes = @as([32]u8, @splat(@as(u8, 0))),
        .name_len = @intCast(name_in.len),
        .arg_count = values.len,
        .args = arg_list(values),
    };
    @memcpy(slot.name_bytes[0..name_in.len], name_in);
    return slot;
}

fn variant(number_in: u8, selector: u8, op: u64, values: anytype) Variant {
    return .{ .number = number_in, .selector = selector, .op = op, .arg_count = values.len, .args = arg_list(values) };
}

// Each line is also the input to vi's host-only mirror generator.
pub const slots = [_]Slot{
    row(0, "sys_ping", .{.int}),
    row(1, "sys_write", .{ .fd, .ptr, .int }),
    row(2, "sys_yield", .{}),
    row(3, "sys_exit", .{.int}),
    row(4, "sys_sleep", .{.int}),
    row(5, "sys_ipc_send", .{ .pid, .ptr, .int }),
    row(6, "sys_ipc_recv", .{ .ptr, .int }),
    row(7, "sys_procs", .{ .ptr, .int }),
    row(8, "sys_wait", .{.pid}),
    row(9, "sys_udp_listen", .{.int}),
    row(10, "sys_udp_send", .{ .int, .int, .ptr, .int }),
    row(11, "sys_udp_recv", .{ .int, .ptr, .int }),
    row(12, "sys_win_open", .{ .int, .int, .int, .int }),
    row(13, "sys_win_fill", .{ .int, .int, .int, .int, .int, .int }),
    row(14, "sys_win_present", .{.int}),
    row(15, "sys_win_close", .{.int}),
    row(16, "sys_win_move", .{ .int, .int, .int }),
    row(17, "sys_win_raise", .{.int}),
    row(18, "sys_win_get", .{ .int, .ptr }),
    row(19, "sys_win_query", .{ .int, .ptr }),
    row(20, "sys_win_set_visible", .{ .int, .flags }),
    row(21, "sys_poll_event", .{.ptr}),
    row(22, "sys_wait_event", .{.ptr}),
    row(23, "sys_file_open", .{ str(1), .int, .flags }),
    row(24, "sys_file_read", .{ .fd, .ptr, .int }),
    row(25, "sys_file_write", .{ .fd, .ptr, .int }),
    row(26, "sys_file_close", .{.fd}),
    row(27, "sys_dir_list", .{ str(1), .int, .ptr, .flags, .int }),
    row(28, "sys_exec", .{ str(1), .int, .ptr, .flags, .ptr, .int }),
    row(29, "sys_kill", .{.pid}),
    row(30, "sys_tcp_connect", .{ .int, .int }),
    row(31, "sys_tcp_send", .{ .ptr, .int }),
    row(32, "sys_tcp_recv", .{ .ptr, .int }),
    row(33, "sys_tcp_close", .{}),
    row(34, "sys_file_delete", .{ str(1), .int }),
    row(35, "sys_file_rename", .{ str_flags(1), .flags, str(3), .int }),
    row(36, "sys_file_truncate", .{ .fd, .int }),
    row(37, "sys_file_free", .{.int}),
    row(38, "sys_clipboard_set", .{ .ptr, .int }),
    row(39, "sys_clipboard_get", .{ .ptr, .int }),
    row(40, "sys_timer_set", .{.int}),
    row(41, "sys_timer_cancel", .{}),
    row(42, "sys_audio_info", .{.ptr}),
    row(43, "sys_audio_play", .{ .ptr, .flags, .int, .int }),
    row(44, "sys_audio_volume", .{.int}),
    row(45, "sys_audio_mute", .{.flags}),
    row(46, "sys_win_fill_batch", .{ .ptr, .int }),
    row(47, "sys_win_resize", .{ .int, .int, .int }),
    row(48, "sys_drag_start", .{ .ptr, .int }),
    row(49, "sys_win_raise_front", .{.int}),
    row(50, "sys_win_lower_back", .{.int}),
    row(51, "sys_notify", .{ str(1), .int, .int }),
    row(52, "sys_win_move_to_workspace", .{ .int, .int }),
    row(53, "sys_win_set_unsaved", .{ .int, .flags }),
    row(54, "sys_setrlimit", .{ .int, .int }),
    row(55, "sys_drag_read", .{ .ptr, .int }),
    row(56, "sys_pipe_read", .{ .ptr, .int }),
    row(57, "sys_pipe_write", .{ .ptr, .int }),
    row(58, "sys_font_size", .{ .int, .int }),
    row(59, "sys_ping_send", .{.int}),
    row(60, "sys_ping_poll", .{}),
    row(61, "sys_win_set_title", .{ .int, str(2), .int }),
    row(62, "sys_net_stats", .{ .ptr, .int }),
    row(63, "sys_mmap", .{ .ptr, .int, .flags, .flags }),
    row(64, "sys_munmap", .{ .ptr, .int }),
    row(65, "sys_wmctl", .{ .int, .int, .int, .int, .ptr, .int }),
    row(66, "sys_time", .{}),
    row(67, "sys_tty_attach", .{ .int, .int, .int, .int, .int }),
    row(68, "sys_principal", .{.ptr}),
    row(69, "sys_file_mode", .{ str(1), .int, .flags }),
    row(70, "sys_secret_get", .{ .redacted, .redacted, .redacted, .redacted, .redacted, .redacted }),
    row(71, "sys_tty_net_auth", .{ .redacted, .redacted, .redacted, .redacted, .redacted, .redacted }),
    row(72, "sys_getrandom", .{ .ptr, .int }),
    row(73, "sys_thread", .{ .int, .ptr, .ptr, .int, .ptr }),
    row(74, "sys_futex", .{ .int, .ptr, .int, .int }),
    row(75, "sys_exnotify", .{.ptr}),
    row(76, "sys_sock_ready", .{ .int, .flags, .int }),
    row(77, "sys_file_sync", .{.fd}),
    row(78, "sys_time_set", .{.int}),
    row(79, "sys_fs_metadata", .{ .int, .ptr, .int, .ptr, .int, .ptr }),
    row(80, "sys_socket", .{ .int, .int, .ptr, .int }),
    row(81, "sys_trace", .{ .int, .int, .ptr, .int }),
    row(82, "sys_profile", .{ .int, .int, .ptr, .int }),
    row(83, "sys_memstat", .{ .pid, .ptr, .int }),
    row(84, "sys_udp_send_from", .{ .int, .int, .int, .ptr, .int }),
    row(85, "sys_udp_recv_from", .{ .int, .ptr, .int }),
    row(86, "sys_udp_close", .{.int}),
    row(87, "sys_getpid", .{}),
    row(88, "sys_scanout_read", .{ .int, .int, .int, .int, .ptr, .int }),
    // M113c (#2419, ADR 0054 D7/D11, ADR 0007 amendment): slot 89 is the
    // ONE in-guest read/write path for GRANTS.TXT user rows —
    // `sys_grant_admin(op, index, ptr, len)`: op 0 marshals user row
    // `index` as its grants line into `ptr`, op 1 sets the row from the
    // line at `ptr` and persists. Gated to the registered WM seat or
    // CAP_PROC_ADMIN, and never the app the row names.
    row(89, "sys_grant_admin", .{ .int, .int, .ptr, .int }),
    row(90, "sys_gpucomp", .{ .int, .int, .int, .int, .ptr, .int }),
    // M118c (#2481, ADR 0007 amendment): the capture half of the audio
    // seam — slot 91 reports the observed input capability (the slot-42
    // shape for the RX direction), slot 92 runs ONE bounded capture into
    // the caller's buffer (virtio_snd.snd_capture, the v1 tuple
    // S16/48kHz/mono, len capped by the 64 KiB ring).
    row(91, "sys_audio_rec_info", .{.ptr}),
    row(92, "sys_audio_rec", .{ .int, .int, .int, .ptr, .int }),
    // M115d (#2463, ADR 0056 D5 + ADR 0007 amendment): slot 93 — the
    // ONE EL0 door to the virelai-ctl/1 channel. The kernel keeps the
    // uid_system credential and runs the whole authenticated session on
    // the caller's behalf; EL0 names a verb (and an optional name arg)
    // and gets the reply verdict back — no key ever crosses the seam.
    row(93, "sys_vsock_ctl", .{ str(1), .int, str(3), .int, .ptr, .int }),
};

// op-dependent shapes override the base row. No pointed-to output or binary
// payload is classified as text; redacted slots have no variants.
//
// M117c (#2475): the v6 marshal — `family_v6_tag` (148283745894406 =
// 0x0000_86dd_0000_0006; decimal here because the slots_gen.go mirror's
// regex parses `variant(...)` op values literally, and trailing comments
// would break its row shape) occupies the argument the v4 form used for
// the IP word, and the 16-byte literal arrives through the pointer arg.
// The selector is the tag position (args[0] for ping send/poll, args[1]
// for socket op 10).
pub const variants = [_]Variant{
    variant(59, 0, 148283745894406, .{ .int, .ptr }),
    variant(60, 0, 148283745894406, .{.int}),
    variant(80, 1, 148283745894406, .{ .int, .int, .int, .ptr }),
    variant(27, 3, 9223372036854775809, .{ str(1), .int, .int, .flags }),
    variant(27, 3, 9223372036854775810, .{ .int, .int, .ptr, .flags, .int }),
    variant(27, 3, 9223372036854775811, .{ .int, .int, .int, .flags }),
    variant(65, 0, 8, .{ .int, .int, .int, .int, str(5), .int }),
    variant(73, 0, 1, .{ .int, .int }),
    variant(73, 0, 2, .{ .int, .int }),
    variant(73, 0, 3, .{ .int, .ptr }),
    variant(74, 0, 1, .{ .int, .ptr, .int }),
    variant(79, 0, 0, .{ .int, str(2), .int, str(4), .int, .ptr }),
    variant(79, 0, 1, .{ .int, str(2), .int, str(4), .int, .ptr }),
    variant(79, 0, 2, .{ .int, str(2), .int, str(4), .int }),
    variant(79, 0, 3, .{ .int, str(2), .int, str(4), .int }),
    variant(79, 0, 4, .{ .int, str(2), .int, str(4), .int }),
    variant(79, 0, 5, .{ .int, .int, .int, .int, .ptr }),
    variant(79, 0, 6, .{ .int, .int }),
    variant(79, 0, 7, .{ .int, str(2), .int, str(4), .int }),
    variant(79, 0, 8, .{ .int, .int, str(3), .int }),
    variant(79, 0, 9, .{ .int, .int }),
    variant(79, 0, 10, .{ .int, .int, .int, .int, .int, .ptr }),
    variant(79, 0, 11, .{ .int, .int, str(3), .int }),
    variant(79, 0, 12, .{ .int, .int, str(3), .int }),
    variant(79, 0, 13, .{ .int, .int, str(3), .int, .int }),
    variant(80, 0, 0, .{ .int, .int, .int }),
    variant(80, 0, 1, .{ .int, .fd }),
    variant(80, 0, 2, .{ .int, .fd, .ptr, .int }),
    variant(80, 0, 3, .{ .int, .fd, .ptr, .int }),
    variant(80, 0, 4, .{ .int, .fd }),
    variant(80, 0, 5, .{ .int, .fd }),
    variant(80, 0, 6, .{ .int, .fd }),
    variant(80, 0, 7, .{ .int, .fd }),
    variant(80, 0, 8, .{ .int, .int, .ptr, .int }),
    variant(80, 0, 9, .{ .int, .fd, .ptr, .int }),
    variant(80, 0, 10, .{ .int, .int, .int }),
    variant(80, 0, 11, .{.int}),
    variant(80, 0, 12, .{ .int, .ptr, .int }),
};

pub fn number(comptime name_in: []const u8) u64 {
    inline for (slots) |slot| {
        if (comptime std.mem.eql(u8, slot.name(), name_in)) return slot.number;
    }
    @compileError("unknown syscall name: " ++ name_in);
}

pub fn lookup(number_in: u64) ?*const Slot {
    if (number_in >= slots.len) return null;
    return &slots[number_in];
}

pub fn shape(number_in: u64, args: [6]u64) ?Variant {
    const slot = lookup(number_in) orelse return null;
    for (variants) |item| {
        if (item.number == number_in and args[item.selector] == item.op) return item;
    }
    return .{ .number = slot.number, .selector = 0, .op = args[0], .arg_count = slot.arg_count, .args = slot.args };
}

pub fn redacted(number_in: u64) bool {
    const slot = lookup(number_in) orelse return false;
    for (slot.args[0..slot.arg_count]) |arg| {
        if (arg.kind == .redacted) return true;
    }
    return false;
}
