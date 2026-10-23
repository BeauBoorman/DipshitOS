//! census (M188e, #3190): SB6OLD.BIN — gate-referenced: live-sb6-perf-payoff.
//! VirelaiOS M33 SB6 (claim 6864) live-gate test app — SB6OLD.BIN: the
//! PRE-seam-B control half of the perf-payoff measurement.
//!
//! Opens a user window (slot 12) and renders a text-like frame using the
//! FROZEN kernel path: an 8x8 grid of 16x16 rects via `sys_win_fill` (slot
//! 13) = 64 fills for the STATIC frame, then 8 DYNAMIC redraws (color
//! cycling) x 64 fills = 512 more, with `sys_win_present` (slot 14) per
//! frame — 576 slot-13 fill SVCs and 9 presents total, all kernel-visible.
//! It counts its own fills and prints `sb6: old fills=576`; the kernel's
//! `syscalls` report (snapshot A, taken after `sb6: old done`) confirms the
//! slot-13 count. This is the "before" number the SB6 gate compares against
//! the seam-B app (SB6NEW.BIN, which issues ZERO fills).
//!
//! Real EL0 Zig, freestanding, no libc. Marker strings host-tested so the
//! live gate's grep targets cannot drift.

const std = @import("std");

const sys_write: u64 = 1;
const sys_yield_num: u64 = 2;
const sys_sleep: u64 = 4;
const sys_exit: u64 = 3;
const sys_win_open: u64 = 12;
const sys_win_fill: u64 = 13;
const sys_win_present: u64 = 14;

pub const win_x: u32 = 64;
pub const win_y: u32 = 64;
pub const win_w: u32 = 256;
pub const win_h: u32 = 192;
pub const grid: u32 = 8; // 8x8 grid of 16x16 rects
pub const cell: u32 = 16;
pub const redraws: u32 = 8;
pub const fills_per_frame: u32 = grid * grid; // 64
pub const total_fills: u32 = fills_per_frame * (redraws + 1); // 576
pub const fills_marker: []const u8 = "sb6: old fills=576";
pub const done_marker: []const u8 = "sb6: old done";
pub const open_fail_marker: []const u8 = "sb6: old open-fail";

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
fn syscall6(num: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
          [a4] "{x4}" (a4),
          [a5] "{x5}" (a5),
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

fn draw_frame(wid: i64, color: u32) void {
    // The frozen per-rect fill path: one sys_win_fill per grid cell.
    var r: u32 = 0;
    while (r < grid) : (r += 1) {
        var c: u32 = 0;
        while (c < grid) : (c += 1) {
            const x: u32 = c * cell;
            const y: u32 = r * cell;
            const rgb: u32 = if (((r + c) & 1) == 0) color else (color ^ 0x00ffff);
            _ = syscall6(sys_win_fill, @as(u64, @intCast(wid)), x, y, cell, cell, rgb);
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

    var frame: u32 = 0;
    while (frame <= redraws) : (frame += 1) {
        draw_frame(wid, 0xcc0000 + frame * 0x001000);
        _ = syscall1(sys_win_present, @as(u64, @intCast(wid)));
        // Sleep one scheduler tick so the drain composites this frame (one
        // blit per present, like a real desktop) before the next frame.
        // (Blocking sleep — the proven app pacing; a sustained cooperative
        // yield-spin is observed to stall the task after the first timer
        // preemption — see the SB6 claim notes.)
        _ = syscall1(sys_sleep, 1);
    }

    write_marker(fills_marker);
    write_marker(done_marker);
    _ = syscall1(sys_exit, 0);
    unreachable;
}

// ---------------------------------------------------------------------------
// Host tests — the gate's grep targets, pinned so they cannot drift.
// ---------------------------------------------------------------------------
test "sb6_old: the pinned markers are the live gate's grep targets" {
    try std.testing.expectEqualStrings("sb6: old fills=576", fills_marker);
    try std.testing.expectEqualStrings("sb6: old done", done_marker);
    try std.testing.expectEqual(@as(u32, 576), total_fills);
    try std.testing.expectEqual(@as(u32, 9), redraws + 1); // static + 8 dynamic
    try std.testing.expectEqual(@as(u32, 256), win_w);
}
