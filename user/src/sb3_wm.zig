//! census (M188e, #3190): SB3WM.BIN — gate-referenced: live-sb3-surface-handoff.
//! VirelaiOS M33 SB3 (claim 3633) live-gate test app — SB3WM.BIN: the
//! registered-WM half of the window surface handoff proof.
//!
//! Registers as the WM server (slot 65 REGISTER — the D2 trust boundary),
//! receives the owner's {owner_pid, handle, magic} handshake over the mailbox,
//! PEERS the shared surface by handle (`sys_mmap(addr=<handle>, prot=READ,
//! M33_MAP_SHARED)` — SB2 peer attach, EL0-RO sw_cow in ITS OWN root), reads
//! the byte the owner stored through its writable leaf, and prints
//! `sb3: wm-read=0xAB`: the WM sees the app's PLAIN-STORE bytes exactly —
//! the surface handoff parity gate (no kernel fill produced what the WM reads).
//! Acks the owner, waits for "bye", then exits (the owner's exit revokes the
//! mirror); the completion marker drives the runner's --script-expect.
//!
//! Real EL0 Zig, freestanding, no libc. Marker strings host-tested so the live
//! gate's grep targets cannot drift.

const std = @import("std");

const sys_write: u64 = 1;
const sys_yield_num: u64 = 2;
const sys_exit: u64 = 3;
const sys_ipc_send: u64 = 5;
const sys_ipc_recv: u64 = 6;
const sys_wmctl: u64 = 65;
const sys_mmap: u64 = 63;

const wmctl_register: u64 = 1;
const map_anonymous: u64 = 0x20;
const m33_map_shared: u64 = 0x10000;
const prot_read: u64 = 1;

pub const magic: u8 = 0xAB;
pub const ready_marker: []const u8 = "sb3: wm registered";
pub const read_marker: []const u8 = "sb3: wm-read=0xAB";
pub const done_marker: []const u8 = "sb3: wm done";
pub const register_fail_marker: []const u8 = "sb3: wm register-fail";
pub const attach_fail_marker: []const u8 = "sb3: wm attach-fail";
pub const handshake_size: usize = 17;

fn syscall0(num: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
        : .{ .memory = true });
    return res;
}
fn syscall1(num: u64, arg0: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
        : .{ .memory = true });
    return res;
}
fn syscall2(num: u64, arg0: u64, arg1: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
        : .{ .memory = true });
    return res;
}
fn syscall3(num: u64, arg0: u64, arg1: u64, arg2: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
        : .{ .memory = true });
    return res;
}
fn syscall4(num: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
          [arg3] "{x3}" (arg3),
        : .{ .memory = true });
    return res;
}

fn write_marker(msg: []const u8) void {
    var line: [80]u8 = undefined;
    var n: usize = msg.len;
    if (n > line.len) n = line.len;
    @memcpy(line[0..n], msg[0..n]);
    if (n > 0 and line[n - 1] != '\n') {
        line[n] = '\n';
        n += 1;
    }
    _ = syscall3(sys_write, 1, @intFromPtr(&line), n);
}

export fn _start(argc: u64, argv_va: u64) callconv(.c) noreturn {
    _ = argc;
    _ = argv_va;
    main();
}

fn main() noreturn {
    const reg = syscall1(sys_wmctl, wmctl_register);
    if (reg == 0) {
        write_marker(ready_marker);
    } else {
        write_marker(register_fail_marker);
    }

    // Wait for the owner's handshake: {owner_pid u64, handle u64, magic u8}.
    var msg: [64]u8 = undefined;
    var handle: u32 = 0;
    var got: bool = false;
    var spins: u32 = 0;
    while (!got and spins < 2_000_000) : (spins += 1) {
        const n = syscall2(sys_ipc_recv, @intFromPtr(&msg), msg.len);
        if (n >= handshake_size and msg[16] == magic) {
            handle = @intCast(std.mem.readInt(u64, msg[8..16], .little));
            got = true;
        } else {
            _ = syscall0(sys_yield_num);
        }
    }
    if (!got) {
        write_marker(attach_fail_marker);
        _ = syscall1(sys_exit, 2);
        unreachable;
    }

    // Peer the surface by handle: EL0-RO sw_cow in the WM's own root.
    const wm_va = syscall4(sys_mmap, handle, 128 * 96 * 4, prot_read, map_anonymous | m33_map_shared);
    if (wm_va <= 0) {
        write_marker(attach_fail_marker);
        _ = syscall1(sys_exit, 3);
        unreachable;
    }
    const b = @as(*const volatile u8, @ptrFromInt(@as(usize, @intCast(wm_va)) + 0)).*;
    if (b == magic) {
        write_marker(read_marker);
    } else {
        var buf: [48]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "sb3: wm-read=0x{x:0>2}\n", .{b}) catch "sb3: wm-read=bad\n";
        write_marker(m);
    }

    // Ack the owner (the byte was read through the RO mirror), then wait for
    // "bye" and exit (the owner's exit revokes this mirror).
    var ack: [1]u8 = .{1};
    _ = syscall3(sys_ipc_send, read_owner_pid(msg[0..8]), @intFromPtr(&ack), ack.len);

    var bye: [8]u8 = undefined;
    var bye_got: bool = false;
    spins = 0;
    while (!bye_got and spins < 2_000_000) : (spins += 1) {
        const n = syscall2(sys_ipc_recv, @intFromPtr(&bye), bye.len);
        if (n >= 3 and std.mem.eql(u8, bye[0..3], "bye")) {
            bye_got = true;
        } else {
            _ = syscall0(sys_yield_num);
        }
    }
    write_marker(done_marker);
    _ = syscall1(sys_exit, 0);
    unreachable;
}

fn read_owner_pid(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}

// ---------------------------------------------------------------------------
// Host tests — the gate's grep targets, pinned so they cannot drift.
// ---------------------------------------------------------------------------
test "sb3_wm: the pinned markers are the live gate's grep targets" {
    try std.testing.expectEqualStrings("sb3: wm registered", ready_marker);
    try std.testing.expectEqualStrings("sb3: wm-read=0xAB", read_marker);
    try std.testing.expectEqualStrings("sb3: wm done", done_marker);
    try std.testing.expectEqual(@as(u8, 0xAB), magic);
    try std.testing.expectEqual(@as(usize, 17), handshake_size);
}
