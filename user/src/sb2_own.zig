//! census (M188e, #3190): SB2OWN.BIN — gate-referenced: live-sb2-shared-anon.
//! VirelaiOS M33 SB2 (claim 8878) live-gate test app — SB2OWN.BIN: the
//! owner half of the shared-anon proof.
//!
//! Creates a shared-anonymous surface (`sys_mmap` with M33_MAP_SHARED —
//! the owner's WRITABLE leaf), renders a magic byte into it (plain store),
//! sends {self_pid, handle, magic} to the registered WM over the mailbox,
//! waits for the WM's read-ack, then sends "bye" and exits — the exit path
//! revokes the WM's RO view (ADR 0016 D2).
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
const sys_procs: u64 = 7;
const sys_mmap: u64 = 63;

const map_anonymous: u64 = 0x20;
const m33_map_shared: u64 = 0x10000; // ADR 0007 (claim 7418)
const prot_rw: u64 = 3;

pub const magic: u8 = 0xAB;
/// The kernel-issued handle is deterministic in this boot: the owner creates
/// the FIRST (and only) shared region, so it gets handle 1. The app learns
/// the handle out-of-band exactly as seam B's future transport will deliver
/// it (the SB2 ABI carries it in `sys_mmap`'s addr argument).
pub const expected_handle: u64 = 1;
pub const create_ok_marker: []const u8 = "sb2: own created";
pub const create_fail_marker: []const u8 = "sb2: own create-fail";
pub const no_wm_marker: []const u8 = "sb2: own no-wm";
pub const ack_marker: []const u8 = "sb2: own ack";
pub const done_marker: []const u8 = "sb2: owner done";

pub const ProcsRow = extern struct {
    pid: u64,
    state: u64,
    exit: u64,
    name: [16]u8,
};
pub const procs_row_bytes: usize = 40;
pub const procs_state_running: u64 = 2;

/// The kernel's `sys_procs` name column is 16 bytes, NUL-padded; `eql` on
/// the full array would never match a shorter name. Trim to the NUL.
fn name_matches(row: *align(1) const ProcsRow, want: []const u8) bool {
    var len: usize = 0;
    while (len < row.name.len and row.name[len] != 0) : (len += 1) {}
    return len == want.len and std.mem.eql(u8, row.name[0..len], want);
}

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

/// Scan the sys_procs snapshot for a RUNNING process named `want`; polls
/// until it appears (the WM exec may not be scheduled yet) or the bound hits.
fn find_wm_pid() ?u64 {
    var buf: [16 * procs_row_bytes]u8 = undefined;
    var spins: u32 = 0;
    while (spins < 2_000_000) : (spins += 1) {
        const n = syscall2(sys_procs, @intFromPtr(&buf), buf.len);
        var off: usize = 0;
        while (off + procs_row_bytes <= @as(usize, @intCast(n)) * procs_row_bytes) : (off += procs_row_bytes) {
            const row = @as(*align(1) const ProcsRow, @ptrCast(&buf[off]));
            if (row.state == procs_state_running and name_matches(row, "SB2WM.BIN")) {
                return row.pid;
            }
        }
        _ = syscall0(sys_yield_num);
    }
    return null;
}

fn main() noreturn {
    // Owner create: the shared surface (1 page, RW) — the owner's WRITABLE
    // leaf (D2: only the owner's root ever holds a writable leaf).
    const owner_va = syscall4(sys_mmap, 0, 4096, prot_rw, map_anonymous | m33_map_shared);
    if (owner_va <= 0) {
        write_marker(create_fail_marker);
        _ = syscall1(sys_exit, 1);
        unreachable;
    }
    write_marker(create_ok_marker);
    // Render into the surface: a plain store through the writable leaf.
    @as(*volatile u8, @ptrFromInt(@as(usize, @intCast(owner_va)))).* = magic;

    const wm_pid = find_wm_pid() orelse {
        write_marker(no_wm_marker);
        _ = syscall1(sys_exit, 2);
        unreachable;
    };

    // Handshake: {self_pid u64, handle u64, magic u8}.
    const self_pid = find_self_pid() orelse 0;
    var msg: [64]u8 = undefined;
    std.mem.writeInt(u64, msg[0..8], self_pid, .little);
    std.mem.writeInt(u64, msg[8..16], expected_handle, .little);
    msg[16] = magic;
    _ = syscall3(sys_ipc_send, wm_pid, @intFromPtr(&msg), 17);

    // Wait for the WM's read-ack (the byte was read through the RO view).
    var ack: [8]u8 = undefined;
    var ack_got: bool = false;
    var spins: u32 = 0;
    while (!ack_got and spins < 2_000_000) : (spins += 1) {
        const n = syscall2(sys_ipc_recv, @intFromPtr(&ack), ack.len);
        if (n >= 1 and ack[0] == 1) {
            ack_got = true;
            write_marker(ack_marker);
        } else {
            _ = syscall0(sys_yield_num);
        }
    }

    // Tell the WM we are leaving, then exit — the exit path revokes its RO
    // view (ADR 0016 D2 revocation-on-teardown).
    const bye = "bye";
    _ = syscall3(sys_ipc_send, wm_pid, @intFromPtr(bye.ptr), bye.len);
    write_marker(done_marker);
    _ = syscall1(sys_exit, 0);
    unreachable;
}

fn find_self_pid() ?u64 {
    var buf: [16 * procs_row_bytes]u8 = undefined;
    const n = syscall2(sys_procs, @intFromPtr(&buf), buf.len);
    var off: usize = 0;
    while (off + procs_row_bytes <= @as(usize, @intCast(n)) * procs_row_bytes) : (off += procs_row_bytes) {
        const row = @as(*align(1) const ProcsRow, @ptrCast(&buf[off]));
        if (name_matches(row, "SB2OWN.BIN")) return row.pid;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Host tests — the gate's grep targets, pinned so they cannot drift.
// ---------------------------------------------------------------------------
test "sb2_own: the pinned markers are the live gate's grep targets" {
    try std.testing.expectEqualStrings("sb2: own created", create_ok_marker);
    try std.testing.expectEqualStrings("sb2: own ack", ack_marker);
    try std.testing.expectEqualStrings("sb2: owner done", done_marker);
    try std.testing.expectEqual(@as(u8, 0xAB), magic);
    try std.testing.expectEqual(@as(u64, 1), expected_handle);
    try std.testing.expectEqual(@as(usize, 40), procs_row_bytes);
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(ProcsRow));
    try std.testing.expectEqual(@as(u64, 2), procs_state_running);
}
