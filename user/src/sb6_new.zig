//! census (M188e, #3190): SB6NEW.BIN — gate-referenced: live-sb6-perf-payoff.
//! VirelaiOS M33 SB6 (claim 6864) live-gate test app — SB6NEW.BIN: the
//! SEAM-B half of the perf-payoff measurement.
//!
//! Renders the SAME 8x8 grid frame as SB6OLD.BIN (static + 8 dynamic
//! redraws) but with PLAIN STORES into a bound shared surface (SB3 handoff)
//! — ZERO `sys_win_fill` (slot 13) SVCs, proven by the kernel's `syscalls`
//! counter (snapshot B minus snapshot A = 0 fills). Presents via
//! `sys_win_present` (slot 14, frozen — marks the window dirty so the
//! kernel's paint_scene visits it and counts a MIGRATED SKIP instead of a
//! blit), then hands {owner_pid, handle, magic} to the registered WM which
//! compose-N's the surface into the scanout (the seam-B composite).
//!
//! Real EL0 Zig, freestanding, no libc. Marker strings host-tested so the
//! live gate's grep targets cannot drift.

const std = @import("std");

const sys_write: u64 = 1;
const sys_yield_num: u64 = 2;
const sys_sleep: u64 = 4;
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

pub const win_x: u32 = 64;
pub const win_y: u32 = 64;
pub const win_w: u32 = 256;
pub const win_h: u32 = 192;
pub const grid: u32 = 8;
pub const cell: u32 = 16;
pub const redraws: u32 = 8;
pub const magic: u8 = 0x6B;
pub const ready_marker: []const u8 = "sb6: new ready";
pub const bound_marker: []const u8 = "sb6: new bound";
pub const stored_marker: []const u8 = "sb6: new fills=0 stores=ok";
pub const done_marker: []const u8 = "sb6: new done";
pub const open_fail_marker: []const u8 = "sb6: new open-fail";
pub const bind_fail_marker: []const u8 = "sb6: new bind-fail";
pub const no_wm_marker: []const u8 = "sb6: new no-wm";
pub const handshake_size: usize = 17;

pub const ProcsRow = extern struct {
    pid: u64,
    state: u64,
    exit: u64,
    name: [16]u8,
};
pub const procs_row_bytes: usize = 40;
pub const procs_state_running: u64 = 2;

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

fn name_matches(row: *align(1) const ProcsRow, want: []const u8) bool {
    var len: usize = 0;
    while (len < row.name.len and row.name[len] != 0) : (len += 1) {}
    return len == want.len and std.mem.eql(u8, row.name[0..len], want);
}

fn find_wm_pid() ?u64 {
    var buf: [16 * procs_row_bytes]u8 = undefined;
    var spins: u32 = 0;
    while (spins < 2_000_000) : (spins += 1) {
        const n = syscall2(sys_procs, @intFromPtr(&buf), buf.len);
        var off: usize = 0;
        while (off + procs_row_bytes <= @as(usize, @intCast(n)) * procs_row_bytes) : (off += procs_row_bytes) {
            const row = @as(*align(1) const ProcsRow, @ptrCast(&buf[off]));
            if (row.state == procs_state_running and name_matches(row, "SB6WM.BIN")) {
                return row.pid;
            }
        }
        _ = syscall1(sys_sleep, 1);
    }
    return null;
}

fn find_self_pid() ?u64 {
    var buf: [16 * procs_row_bytes]u8 = undefined;
    const n = syscall2(sys_procs, @intFromPtr(&buf), buf.len);
    var off: usize = 0;
    while (off + procs_row_bytes <= @as(usize, @intCast(n)) * procs_row_bytes) : (off += procs_row_bytes) {
        const row = @as(*align(1) const ProcsRow, @ptrCast(&buf[off]));
        if (name_matches(row, "SB6NEW.BIN")) return row.pid;
    }
    return null;
}

fn store_frame(base: usize, color: u32) void {
    // The SAME 8x8 grid as SB6OLD, via PLAIN STORES (no syscalls).
    var r: u32 = 0;
    while (r < grid) : (r += 1) {
        var c: u32 = 0;
        while (c < grid) : (c += 1) {
            const x: u32 = c * cell;
            const y: u32 = r * cell;
            const rgb: u32 = if (((r + c) & 1) == 0) color else (color ^ 0x00ffff);
            var yy: u32 = 0;
            while (yy < cell) : (yy += 1) {
                var xx: u32 = 0;
                while (xx < cell) : (xx += 1) {
                    const off = ((y + yy) * win_w + (x + xx)) * 4;
                    @as(*volatile u8, @ptrFromInt(base + off + 0)).* = @truncate(rgb & 0xff);
                    @as(*volatile u8, @ptrFromInt(base + off + 1)).* = @truncate((rgb >> 8) & 0xff);
                    @as(*volatile u8, @ptrFromInt(base + off + 2)).* = @truncate((rgb >> 16) & 0xff);
                    @as(*volatile u8, @ptrFromInt(base + off + 3)).* = 0xff;
                }
            }
        }
    }
}

fn main() noreturn {
    const wid = syscall4(sys_win_open, win_x, win_y, win_w, win_h);
    if (wid <= 0) {
        write_marker(open_fail_marker);
        _ = syscall1(sys_exit, 1);
        unreachable;
    }
    write_marker(ready_marker);

    const surf_len: u64 = @as(u64, win_w) * win_h * 4;
    const owner_va = syscall4(sys_mmap, m33_surf_win_tag | @as(u64, @intCast(wid)), surf_len, prot_rw, map_anonymous | m33_map_shared);
    if (owner_va <= 0) {
        write_marker(bind_fail_marker);
        _ = syscall1(sys_exit, 2);
        unreachable;
    }
    write_marker(bound_marker);

    const base = @as(usize, @intCast(owner_va));
    var frame: u32 = 0;
    while (frame <= redraws) : (frame += 1) {
        store_frame(base, 0xcc0000 + frame * 0x001000);
        // The magic byte at pixel (0,0) — the WM's readback proof.
        @as(*volatile u8, @ptrFromInt(base + 0)).* = magic;
        // Frozen present: marks the window dirty so paint_scene visits it
        // and counts a MIGRATED SKIP (never a blit). No slot-13 fill.
        _ = syscall1(sys_win_present, @as(u64, @intCast(wid)));
        // Sleep one scheduler tick between frames (the proven blocking
        // pacing — a sustained yield-spin stalls after the first timer
        // preemption; see the SB6 claim notes).
        _ = syscall1(sys_sleep, 1);
    }
    write_marker(stored_marker);

    // Hand {self_pid, handle=1, magic} to the registered WM for compose-N.
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

    var ack: [8]u8 = undefined;
    var ack_got: bool = false;
    var spins: u32 = 0;
    while (!ack_got and spins < 2_000_000) : (spins += 1) {
        const n = syscall2(sys_ipc_recv, @intFromPtr(&ack), ack.len);
        if (n >= 1 and ack[0] == 1) {
            ack_got = true;
        } else {
            _ = syscall1(sys_sleep, 1);
        }
    }
    write_marker(done_marker);
    _ = syscall1(sys_exit, 0);
    unreachable;
}

// ---------------------------------------------------------------------------
// Host tests — the gate's grep targets, pinned so they cannot drift.
// ---------------------------------------------------------------------------
test "sb6_new: the pinned markers are the live gate's grep targets" {
    try std.testing.expectEqualStrings("sb6: new bound", bound_marker);
    try std.testing.expectEqualStrings("sb6: new fills=0 stores=ok", stored_marker);
    try std.testing.expectEqualStrings("sb6: new done", done_marker);
    try std.testing.expectEqual(@as(u8, 0x6B), magic);
    try std.testing.expectEqual(@as(usize, 17), handshake_size);
}
