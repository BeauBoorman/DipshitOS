//! census (M188e, #3190): SB3OWN.BIN — gate-referenced: live-sb3-surface-handoff.
//! VirelaiOS M33 SB3 (claim 3633) live-gate test app — SB3OWN.BIN: the
//! migrated-app half of the window surface handoff proof.
//!
//! Opens a user window (frozen slot 12), BINDS a shared-anonymous surface as
//! its back-buffer via `sys_mmap(addr = M33_SURF_WIN_TAG | window_id, MAP_ANON|
//! M33_MAP_SHARED)`, then renders into that surface with PLAIN STORES through
//! its own writable leaf (the SB3 handoff — no kernel fill syscall for the
//! migrated path). It writes a known magic byte + a colored row, hands
//! {window_id, handle, magic} to the registered WM over the mailbox, and the
//! WM (SB3WM.BIN) reads the byte RO through its peer mirror and prints
//! `sb3: wm-read=0xAB` — parity with the old fill path: the app's stores, not
//! a kernel `sys_win_fill`, produced the bytes the WM sees.
//!
//! Real EL0 Zig, freestanding, no libc. Marker strings host-tested so the live
//! gate's grep targets cannot drift.

const std = @import("std");

const sys_write: u64 = 1;
const sys_yield_num: u64 = 2;
const sys_exit: u64 = 3;
const sys_ipc_send: u64 = 5;
const sys_ipc_recv: u64 = 6;
const sys_procs: u64 = 7;
const sys_win_open: u64 = 12;
const sys_win_present: u64 = 14;
const sys_mmap: u64 = 63;

const map_anonymous: u64 = 0x20;
const m33_map_shared: u64 = 0x10000;
const m33_surf_win_tag: u64 = 0x8000_0000_0000_0000;
const prot_rw: u64 = 3;

pub const win_w: u32 = 128;
pub const win_h: u32 = 96;
pub const magic: u8 = 0xAB;
pub const create_ok_marker: []const u8 = "sb3: own opened";
pub const bind_ok_marker: []const u8 = "sb3: own bound";
pub const stored_marker: []const u8 = "sb3: own stored";
pub const done_marker: []const u8 = "sb3: owner done";
pub const created_marker: []const u8 = "sb3: own create-fail";
pub const no_wm_marker: []const u8 = "sb3: own no-wm";
pub const handshake_size: usize = 17; // pid u64 + handle u64 + magic u8

pub const ProcsRow = extern struct {
    pid: u64,
    state: u64,
    exit: u64,
    name: [16]u8,
};
pub const procs_row_bytes: usize = 40;
pub const procs_state_running: u64 = 2;

// --- freestanding syscall wrappers ----------------------------------------
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
    // Terminate with a newline so the runner's --script-expect sees whole lines.
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

/// NUL-trim the 16-byte procs name column before comparing.
fn name_matches(row: *align(1) const ProcsRow, want: []const u8) bool {
    var len: usize = 0;
    while (len < row.name.len and row.name[len] != 0) : (len += 1) {}
    return len == want.len and std.mem.eql(u8, row.name[0..len], want);
}

/// Scan the sys_procs snapshot for a RUNNING process named `want`.
fn find_wm_pid() ?u64 {
    var buf: [16 * procs_row_bytes]u8 = undefined;
    var spins: u32 = 0;
    while (spins < 2_000_000) : (spins += 1) {
        const n = syscall2(sys_procs, @intFromPtr(&buf), buf.len);
        var off: usize = 0;
        while (off + procs_row_bytes <= @as(usize, @intCast(n)) * procs_row_bytes) : (off += procs_row_bytes) {
            const row = @as(*align(1) const ProcsRow, @ptrCast(&buf[off]));
            if (row.state == procs_state_running and name_matches(row, "SB3WM.BIN")) {
                return row.pid;
            }
        }
        _ = syscall0(sys_yield_num);
    }
    return null;
}

fn find_self_pid() ?u64 {
    var buf: [16 * procs_row_bytes]u8 = undefined;
    const n = syscall2(sys_procs, @intFromPtr(&buf), buf.len);
    var off: usize = 0;
    while (off + procs_row_bytes <= @as(usize, @intCast(n)) * procs_row_bytes) : (off += procs_row_bytes) {
        const row = @as(*align(1) const ProcsRow, @ptrCast(&buf[off]));
        if (name_matches(row, "SB3OWN.BIN")) return row.pid;
    }
    return null;
}

fn main() noreturn {
    // 1. Open a user window (frozen slot 12). The window is unmigrated.
    const wid = syscall4(sys_win_open, 0, 0, win_w, win_h);
    if (wid <= 0) {
        write_marker(created_marker);
        _ = syscall1(sys_exit, 1);
        unreachable;
    }
    write_marker(create_ok_marker);

    // 2. Bind a shared surface AS the window's back-buffer: addr carries the
    //    M33_SURF_WIN_TAG | window_id. Returns the owner's writable va.
    const surf_len: u64 = @as(u64, win_w) * win_h * 4;
    const owner_va = syscall4(sys_mmap, m33_surf_win_tag | @as(u64, @intCast(wid)), surf_len, prot_rw, map_anonymous | m33_map_shared);
    if (owner_va <= 0) {
        write_marker(bind_fail);
        _ = syscall1(sys_exit, 2);
        unreachable;
    }
    write_marker(bind_ok_marker);

    // 3. RENDER via PLAIN STORES through the owner's writable leaf: a magic
    //    byte at the top-left pixel and a colored row. No kernel fill.
    const base = @as(usize, @intCast(owner_va));
    @as(*volatile u8, @ptrFromInt(base + 0)).* = magic; // B of pixel(0,0)
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        @as(*volatile u8, @ptrFromInt(base + i * 4 + 2)).* = 0xff; // red row
        @as(*volatile u8, @ptrFromInt(base + i * 4 + 3)).* = 0xff; // opaque
    }
    write_marker(stored_marker);
    // Mark dirty so the window composites (present still works — frozen).
    _ = syscall1(sys_win_present, @as(u64, @intCast(wid)));

    // 4. Hand {self_pid, handle=1, magic} to the registered WM.
    const wm_pid = find_wm_pid() orelse {
        write_marker(no_wm_marker);
        _ = syscall1(sys_exit, 3);
        unreachable;
    };
    const self_pid = find_self_pid() orelse 0;
    var msg: [64]u8 = undefined;
    std.mem.writeInt(u64, msg[0..8], self_pid, .little);
    std.mem.writeInt(u64, msg[8..16], 1, .little); // handle 1 (first region)
    msg[16] = magic;
    _ = syscall3(sys_ipc_send, wm_pid, @intFromPtr(&msg), 17);

    // 5. Wait for the WM's read-ack (byte == magic seen through the RO mirror),
    //    then hand off teardown: send "bye" and exit — the owner exit revokes
    //    the WM mirror (D2).
    var ack: [8]u8 = undefined;
    var ack_got: bool = false;
    var spins: u32 = 0;
    while (!ack_got and spins < 2_000_000) : (spins += 1) {
        const n = syscall2(sys_ipc_recv, @intFromPtr(&ack), ack.len);
        if (n >= 1 and ack[0] == 1) {
            ack_got = true;
        } else {
            _ = syscall0(sys_yield_num);
        }
    }
    const bye = "bye";
    _ = syscall3(sys_ipc_send, wm_pid, @intFromPtr(bye.ptr), bye.len);
    write_marker(done_marker);
    _ = syscall1(sys_exit, 0);
    unreachable;
}

const bind_fail: []const u8 = "sb3: own bind-fail";

// ---------------------------------------------------------------------------
// Host tests — the gate's grep targets, pinned so they cannot drift.
// ---------------------------------------------------------------------------
test "sb3_own: the pinned markers are the live gate's grep targets" {
    try std.testing.expectEqualStrings("sb3: own opened", create_ok_marker);
    try std.testing.expectEqualStrings("sb3: own bound", bind_ok_marker);
    try std.testing.expectEqualStrings("sb3: own stored", stored_marker);
    try std.testing.expectEqualStrings("sb3: owner done", done_marker);
    try std.testing.expectEqual(@as(u8, 0xAB), magic);
    try std.testing.expectEqual(@as(u32, 128), win_w);
    try std.testing.expectEqual(@as(u8, 2), @truncate(m33_surf_win_tag | 2));
    try std.testing.expectEqual(@as(u64, 17), handshake_size);
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(ProcsRow));
}
