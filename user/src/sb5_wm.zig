//! census (M188e, #3190): SB5WM.BIN — gate-referenced: live-sb5-wm-compose-n.
//! VirelaiOS M33 SB5 (claim 7397) live-gate test app — SB5WM.BIN: the
//! registered-WM half of the WM compose-N + one final present proof.
//!
//! Registers as the WM server (slot 65 REGISTER), binds the SCANOUT writable
//! (`sys_mmap(addr = M33_SURF_SCAN_TAG, len = fb_size, PROT_RW, MAP_ANON|
//! M33_MAP_SHARED)` — the SB5 grant), receives the owner's {owner_pid,
//! handle, magic} handshake over the mailbox, PEERS the shared surface by
//! handle (SB2 peer attach, EL0-RO sw_cow in ITS OWN root), COMPOSES the
//! surface into its scanout view at the window's (320,64) 256x192 rect
//! (compose-N: plain byte copies — the WM does the compositing, no kernel
//! fill), reads the byte back from the SCANOUT (proving the composited
//! pixels are the app's plain-store bytes), issues the FINAL present
//! (REQUEST_PRESENT cmd 3 — flush only, the kernel never re-paints over the
//! WM's stores), acks the owner, and exits.
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
const wmctl_request_present: u64 = 3;
const map_anonymous: u64 = 0x20;
const m33_map_shared: u64 = 0x10000;
const m33_surf_scan_tag: u64 = 0x4000_0000_0000_0000;
const prot_read: u64 = 1;
const prot_rw: u64 = 3;

pub const fb_w: u32 = 1280;
pub const fb_h: u32 = 720;
pub const win_x: u32 = 320;
pub const win_y: u32 = 64;
pub const win_w: u32 = 256;
pub const win_h: u32 = 192;
pub const magic: u8 = 0x5B;
pub const ready_marker: []const u8 = "sb5: wm registered";
pub const scanout_marker: []const u8 = "sb5: wm scanout=1";
pub const readback_marker: []const u8 = "sb5: wm readback=0x5B";
pub const present_marker: []const u8 = "sb5: wm present";
pub const done_marker: []const u8 = "sb5: wm done";
pub const register_fail_marker: []const u8 = "sb5: wm register-fail";
pub const scanout_fail_marker: []const u8 = "sb5: wm scanout-fail";
pub const attach_fail_marker: []const u8 = "sb5: wm attach-fail";
pub const compose_fail_marker: []const u8 = "sb5: wm compose-fail";
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
    // 1. Register as the WM server (slot 65 cmd 1).
    const reg = syscall1(sys_wmctl, wmctl_register);
    if (reg == 0) {
        write_marker(ready_marker);
    } else {
        write_marker(register_fail_marker);
        _ = syscall1(sys_exit, 1);
        unreachable;
    }

    // 2. Bind the scanout writable (the compose-N target) — full frame.
    const fb_len: u64 = @as(u64, fb_w) * fb_h * 4;
    const scan_va = syscall4(sys_mmap, m33_surf_scan_tag, fb_len, prot_rw, map_anonymous | m33_map_shared);
    if (scan_va <= 0) {
        write_marker(scanout_fail_marker);
        _ = syscall1(sys_exit, 2);
        unreachable;
    }
    write_marker(scanout_marker);

    // 3. Wait for the owner's handshake: {owner_pid u64, handle u64, magic u8}.
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
        _ = syscall1(sys_exit, 3);
        unreachable;
    }

    // 4. Peer the surface by handle (EL0-RO sw_cow in the WM's own root).
    const surf_len: u64 = @as(u64, win_w) * win_h * 4;
    const surf_va = syscall4(sys_mmap, handle, surf_len, prot_read, map_anonymous | m33_map_shared);
    if (surf_va <= 0) {
        write_marker(attach_fail_marker);
        _ = syscall1(sys_exit, 4);
        unreachable;
    }

    // 5. COMPOSE-N: copy the surface into the scanout at the window's rect
    //    (plain byte copies — the WM composites; no kernel fill involved).
    const scan_base = @as(usize, @intCast(scan_va));
    const surf_base = @as(usize, @intCast(surf_va));
    const fb_stride: usize = @as(usize, fb_w) * 4;
    const surf_stride: usize = @as(usize, win_w) * 4;
    const dst_x: usize = win_x * 4;
    const dst_y: usize = win_y;
    var row: usize = 0;
    while (row < win_h) : (row += 1) {
        const src = @as([*]const volatile u8, @ptrFromInt(surf_base + row * surf_stride));
        const dst = @as([*]volatile u8, @ptrFromInt(scan_base + (dst_y + row) * fb_stride + dst_x));
        var col: usize = 0;
        while (col < surf_stride) : (col += 1) {
            dst[col] = src[col];
        }
    }

    // 6. Read the byte back FROM THE SCANOUT at the window's origin — the
    //    composited pixel must be the app's plain-store magic byte.
    const readback = @as(*const volatile u8, @ptrFromInt(scan_base + dst_y * fb_stride + dst_x + 0)).*;
    if (readback == magic) {
        write_marker(readback_marker);
    } else {
        var buf: [48]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "sb5: wm readback=0x{x:0>2}\n", .{readback}) catch compose_fail_marker;
        write_marker(m);
    }

    // 7. The FINAL present: REQUEST_PRESENT (cmd 3) — flush only. The kernel
    //    painted its layer at the last tick; the WM's stores are on top.
    const pres = syscall1(sys_wmctl, wmctl_request_present);
    if (pres == 0) {
        write_marker(present_marker);
    } else {
        write_marker(compose_fail_marker);
    }

    // 8. Ack the owner, wait for "bye", exit.
    const owner_pid = std.mem.readInt(u64, msg[0..8], .little);
    var ack: [1]u8 = .{1};
    _ = syscall3(sys_ipc_send, owner_pid, @intFromPtr(&ack), ack.len);

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

// ---------------------------------------------------------------------------
// Host tests — the gate's grep targets, pinned so they cannot drift.
// ---------------------------------------------------------------------------
test "sb5_wm: the pinned markers are the live gate's grep targets" {
    try std.testing.expectEqualStrings("sb5: wm registered", ready_marker);
    try std.testing.expectEqualStrings("sb5: wm scanout=1", scanout_marker);
    try std.testing.expectEqualStrings("sb5: wm readback=0x5B", readback_marker);
    try std.testing.expectEqualStrings("sb5: wm present", present_marker);
    try std.testing.expectEqualStrings("sb5: wm done", done_marker);
    try std.testing.expectEqual(@as(u8, 0x5B), magic);
    try std.testing.expectEqual(@as(usize, 17), handshake_size);
    try std.testing.expectEqual(@as(u8, 2), @truncate(m33_surf_scan_tag >> 62));
}
