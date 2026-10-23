//! census (M188e, #3190): SB4DAM.BIN — gate-referenced: live-sb4-damage-tracking, live-wm1.
//! VirelaiOS M33 SB4 (claim 2382) live-gate test app — SB4DAM.BIN: the
//! rect-granular damage proof.
//!
//! Opens a user window (frozen slot 12, 128x96), then FILLS TWO rects via the
//! kernel-visible fill path (slot 13) with NO yield between them, so they
//! COALESCE into ONE damage rect (the union). The compositor then repaints
//! exactly that union rect — NOT the whole 128x96 window — which the live gate
//! observes on serial via `dui`'s new `last=x,y,w,h` column (the rect paint
//! actually blitted). Both properties are load-bearing for SB4:
//!   * rect-granular:  last=8,8,108,68 (the union of the two fills), not a
//!                     full-window 0,0,128,96
//!   * monotonic union: two fills coalesce into their bounding box, proving
//!                     damage accumulates until the drain consumes it.
//!
//! Marker chain (the gate's serial grep targets, pinned host-side):
//!   sb4: filled   sb4: settled   sb4: open-fail   sb4: fill-fail
//! The app then yield-loops forever so the window stays alive for `dui`.

const std = @import("std");

const sys_write: u64 = 1;
const sys_yield_num: u64 = 2;
const sys_exit: u64 = 3;
const sys_win_open: u64 = 12;
const sys_win_fill: u64 = 13;
const sys_win_present: u64 = 14;

pub const win_w: u32 = 128;
pub const win_h: u32 = 96;
pub const r1: [4]u32 = .{ 8, 8, 48, 48 };
pub const r2: [4]u32 = .{ 100, 60, 16, 16 };
pub const union_rect: [4]u32 = .{ 8, 8, 108, 68 }; // bounding box of r1+r2
pub const filled_marker: []const u8 = "sb4: filled";
pub const open_fail_marker: []const u8 = "sb4: open-fail";
pub const fill_fail_marker: []const u8 = "sb4: fill-fail";

fn syscall0(num: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
        : .{ .memory = true });
    return res;
}
fn syscall1(num: u64, a0: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
        : .{ .memory = true });
    return res;
}
fn syscall4(num: u64, a0: u64, a1: u64, a2: u64, a3: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
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
fn syscall3(num: u64, a0: u64, a1: u64, a2: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
        : .{ .memory = true });
    return res;
}

export fn _start(argc: u64, argv_va: u64) callconv(.c) noreturn {
    _ = argc;
    _ = argv_va;
    main();
}

fn main() noreturn {
    const wid = syscall4(sys_win_open, 0, 0, win_w, win_h);
    if (wid <= 0) {
        write_marker(open_fail_marker);
        _ = syscall1(sys_exit, 2);
        unreachable;
    }
    const w = @as(u64, @intCast(wid));
    // Two fills, no yield between them -> they coalesce into ONE union damage
    // rect (the SB4 monotonic-union property). 0xff0000 = red, 0x00ff00 = green.
    if (syscall6(sys_win_fill, w, r1[0], r1[1], r1[2], r1[3], 0xff0000) != 0) {
        write_marker(fill_fail_marker);
        _ = syscall1(sys_exit, 3);
        unreachable;
    }
    if (syscall6(sys_win_fill, w, r2[0], r2[1], r2[2], r2[3], 0x00ff00) != 0) {
        write_marker(fill_fail_marker);
        _ = syscall1(sys_exit, 3);
        unreachable;
    }
    _ = syscall1(sys_win_present, w);
    write_marker(filled_marker);
    // Yield-loop forever to keep the window alive for `dui`. The gate waits a
    // few idle heartbeats (during which the shell drain composites and consumes
    // this damage) before running `dui`, so its `last=` column shows the exact
    // rect composite actually repainted — no in-app settle marker needed.
    while (true) _ = syscall0(sys_yield_num);
}

// ---------------------------------------------------------------------------
// Host tests — pin the gate's grep targets + the expected union rect.
// ---------------------------------------------------------------------------
test "sb4dam: pinned markers + the expected union damage rect" {
    try std.testing.expectEqualStrings("sb4: filled", filled_marker);
    try std.testing.expectEqual(@as(u32, 128), win_w);
    try std.testing.expectEqual(@as(u32, 96), win_h);
    // union of r1 (8,8,48,48) and r2 (100,60,16,16) == (8,8,108,68)
    try std.testing.expectEqual(@as(u32, 108), union_rect[2]);
    try std.testing.expectEqual(@as(u32, 68), union_rect[3]);
}
