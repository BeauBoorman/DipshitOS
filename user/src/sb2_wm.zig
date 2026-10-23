//! census (M188e, #3190): SB2WM.BIN — gate-referenced: live-sb2-shared-anon.
//! VirelaiOS M33 SB2 (claim 8878) live-gate test app — SB2WM.BIN: the WM
//! (peer) half of the shared-anon proof.
//!
//! Registers as the WM server (slot 65 REGISTER — the D2 trust boundary),
//! receives the owner's {owner_pid, handle, magic} handshake over the mailbox
//! (slots 5/6), attaches the shared surface READ-ONLY by handle (`sys_mmap`
//! addr=<handle>, prot=READ, M33_MAP_SHARED — ADR 0016 D2: the registered WM
//! maps the owner's surface EL0-RO), reads the owner's byte, prints
//! `sb2: wm-read=0xAB`, acks the owner. When the owner sends "bye" and exits,
//! the kernel revokes the region (ADR 0016 D2 revocation-on-teardown); the
//! WM re-attaches the now-stale handle and prints `sb2: wm-reattach=EFAULT`
//! — the live proof that a peer can never retain access past the owner.
//!
//! Real EL0 Zig, freestanding, no libc. The marker strings are host-tested
//! so the live gate's grep targets cannot drift.

const std = @import("std");

// Syscall slots (ADR 0007).
const sys_write: u64 = 1;
const sys_yield_num: u64 = 2;
const sys_exit: u64 = 3;
const sys_ipc_send: u64 = 5;
const sys_ipc_recv: u64 = 6;
const sys_wmctl: u64 = 65;
const sys_mmap: u64 = 63;

const wmctl_register: u64 = 1; // sys_wmctl cmd 1 (WMS1, claim 1484)
const map_anonymous: u64 = 0x20;
const m33_map_shared: u64 = 0x10000; // ADR 0007 (claim 7418)
const prot_read: u64 = 1;

pub const magic: u8 = 0xAB;
pub const ready_marker: []const u8 = "sb2: wm registered";
pub const read_marker: []const u8 = "sb2: wm-read=0xAB";
pub const reattach_marker: []const u8 = "sb2: wm-reattach=EFAULT";
pub const done_marker: []const u8 = "sb2: wm done";
pub const register_fail_marker: []const u8 = "sb2: wm register-fail";
pub const attach_fail_marker: []const u8 = "sb2: wm attach-fail";
pub const bad_magic_marker: []const u8 = "sb2: wm bad-magic";
pub const handshake_size: usize = 17; // pid u64 + handle u64 + magic u8

// --- freestanding syscall wrappers (svc #0, the fixed-register ABI) --------
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
    // Terminate with a newline so the runner's --script-expect (and the
    // gate's greps) see whole lines; the marker constants stay the exact
    // grep targets and the host test pins them.
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
    // D2 trust boundary: only the REGISTERED WM may attach a peer surface.
    const reg = syscall1(sys_wmctl, wmctl_register);
    if (reg == 0) {
        write_marker(ready_marker);
    } else {
        write_marker(register_fail_marker);
    }

    // Wait for the owner's handshake: {owner_pid u64, handle u64, magic u8}.
    var msg: [64]u8 = undefined;
    var owner_pid: u64 = 0;
    var handle: u32 = 0;
    var got: bool = false;
    var spins: u32 = 0;
    while (!got and spins < 2_000_000) : (spins += 1) {
        const n = syscall2(sys_ipc_recv, @intFromPtr(&msg), msg.len);
        if (n >= handshake_size and msg[16] == magic) {
            owner_pid = std.mem.readInt(u64, msg[0..8], .little);
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

    // Attach the owner's surface READ-ONLY by handle (the WM's own va).
    const wm_va = syscall4(sys_mmap, handle, 4096, prot_read, map_anonymous | m33_map_shared);
    if (wm_va <= 0) {
        write_marker(attach_fail_marker);
        _ = syscall1(sys_exit, 3);
        unreachable;
    }
    const b = @as(*const volatile u8, @ptrFromInt(@as(usize, @intCast(wm_va)))).*;
    if (b == magic) {
        write_marker(read_marker);
    } else {
        write_marker(bad_magic_marker);
    }

    // Ack the owner so it knows the read happened.
    var ack: [1]u8 = .{1};
    _ = syscall3(sys_ipc_send, owner_pid, @intFromPtr(&ack), ack.len);

    // Wait for the owner's "bye" (sent immediately before its sys_exit; the
    // exit revokes this region — D2 revocation-on-teardown).
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

    // Re-attach the now-STALE handle: EFAULT — the owner tore the region
    // down, so no stale peer access survives.
    const again = syscall4(sys_mmap, handle, 4096, prot_read, map_anonymous | m33_map_shared);
    if (again == -3) {
        write_marker(reattach_marker);
    } else {
        var buf: [48]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "sb2: wm-reattach=rc={d}\n", .{again}) catch "sb2: wm-reattach=rc=?\n";
        write_marker(m);
    }
    write_marker(done_marker);
    _ = syscall1(sys_exit, 0);
    unreachable;
}

// ---------------------------------------------------------------------------
// Host tests — the gate's grep targets, pinned so they cannot drift.
// ---------------------------------------------------------------------------
test "sb2_wm: the pinned markers are the live gate's grep targets" {
    try std.testing.expectEqualStrings("sb2: wm registered", ready_marker);
    try std.testing.expectEqualStrings("sb2: wm-read=0xAB", read_marker);
    try std.testing.expectEqualStrings("sb2: wm-reattach=EFAULT", reattach_marker);
    try std.testing.expectEqualStrings("sb2: wm done", done_marker);
    try std.testing.expectEqual(@as(u8, 0xAB), magic);
    try std.testing.expectEqual(@as(usize, 17), handshake_size);
}
