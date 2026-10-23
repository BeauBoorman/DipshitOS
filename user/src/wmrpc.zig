//! census (M188e, #3190): WMRPC.BIN — gate-referenced: live-wm-ipc, live-wm7-gateb.
//! VirelaiOS WMS7 Gate A test app — WMRPC.BIN (issue #627).
//!
//! The app-facing half of the app↔WM mailbox protocol. It discovers the
//! registered WM server and its OWN pid by reading `sys_procs` (slot 7 —
//! the process name + `running` state, the same EL0 table-read the
//! `peer: sees` IPC probe uses), opens a user window, then sends TWO WM_RPC
//! requests to the WM over the per-process mailbox (`sys_ipc_send`, slot 5;
//! `sys_ipc_recv`, slot 6): a `WIN_RAISE` for the target window (the WM
//! focuses+raises it via the ALT_TAB-commit path) and a `WIN_CONFIG` that
//! moves/resizes it (the SET_WINDOW-rect path) with a bounded title — both
//! "ask the WM" instead of "syscall the desktop". For each request it polls
//! its own inbox for the WM's ack reply and prints a pinned marker, so the
//! live gate can prove the request round-tripped AND applied.
//!
//! Back-compat mode: when no WM server is running the app finds no
//! `WND.BIN` in the process table, prints `wmrpc: no-wm` and parks — an app
//! that can't reach a WM does nothing harmful (the frozen syscalls are
//! untouched; the protocol is additive).
//!
//! Never exits (a long-lived peer, like WND.BIN/PEER.BIN). Real EL0 Zig,
//! freestanding, no libc; the WM_RPC wire format (WmRpc) is single-sourced
//! in `kernel/src/wnd_core.zig` so this app and the server cannot drift.
//!
//! Invocation:  exec WMRPC.BIN <target-window-id> [wm-name]
//!   argv[0] = the window id to raise/config (NOTEPAD is id 2 in the gate),
//!   argv[1] = the WM server's process name (default WND.BIN). The app finds
//!   its OWN pid by scanning `sys_procs` for its own name (the gate runs one
//!   instance).

const std = @import("std");
const wnd_core = @import("wnd_core");
/// M32 WMS7 Gate B (issue #627): this app is the TOOLKIT consumer. It rides
/// `ui.wm_*` (the WM_RPC client in lib/ui.zig) instead of hand-rolling mail,
/// proving "a test app asked the WM through the toolkit" (the issue's
/// acceptance). The toolkit wire mirror + the wmrpc pins below lock the
/// markers and the 64-B bound so nothing drifts from wnd_core.
const ui = @import("lib/ui.zig");

// Syscall slots (ADR 0007). WMRPC keeps only win_open + write + sleep/yield
// locally; the mailbox + procs plumbing delegates to the toolkit client.
const sys_write: u64 = 1;
const sys_sleep: u64 = 4;
const sys_win_open: u64 = 12;
const sys_yield_num: u64 = 2;

/// The procs snapshot row the kernel marshals (u64 pid, u64 state, u64 exit,
/// 16-byte NUL-padded name — 40 bytes). The state code for RUNNING is 2
/// (process.State order — the same value peer.zig's naked asm compares).
/// WMRPC keeps the struct for its own discovery; the toolkit's wm_find_pid /
/// wm_peers reuse get_procs/parse_procs under the hood.
pub const ProcsRow = extern struct {
    pid: u64,
    state: u64,
    exit: u64,
    name: [16]u8,
};
pub const procs_row_bytes: usize = 40;
pub const procs_state_running: u64 = 2;
/// The snapshot buffer bound (16 rows × 40 B — plenty for the boot payload +
/// WND + NOTEPAD + this app). WMRPC delegates the scan to the toolkit client
/// (ui.wm_find_pid owns its own buffer), so this is a pinned-standing doc
/// value rather than an allocation here.
pub const procs_buf_bytes: usize = 16 * 40;

// ---------------------------------------------------------------------------
// Pinned markers (the live gate's grep targets; host-tested so they cannot
// drift from the payload).
// ---------------------------------------------------------------------------
pub const ready_marker: []const u8 = "wmrpc: wm";
pub const own_marker: []const u8 = "wmrpc: own-id=";
pub const raise_ack_marker: []const u8 = "wmrpc: raise-ack";
pub const config_ack_marker: []const u8 = "wmrpc: config-ack";
pub const done_marker: []const u8 = "wmrpc: done";
pub const no_wm_marker: []const u8 = "wmrpc: no-wm";
/// WMS7 Gate B no-WM fallback marker (the toolkit's syscall fallback proof;
/// the gate greps `wmrpc: fallback raise=ok move=ok`).
pub const wmrpc_fallback_fmt: []const u8 = "wmrpc: fallback raise={s} move={s}\n";
/// The config title the app sends (the WM_RPC payload carries it within 64 B).
pub const config_title: []const u8 = "wm-rpc";
/// The WIN_CONFIG target rect (the gate asserts the dui row reflects it).
pub const config_x: u16 = 40;
pub const config_y: u16 = 40;
pub const config_w: u16 = 360;
pub const config_h: u16 = 260;
/// The app's own window open rect (the second window, so a raise is visible).
pub const own_x: u32 = 400;
pub const own_y: u32 = 60;
pub const own_w: u32 = 256;
pub const own_h: u32 = 192;

export fn _start(argc: u64, argv_va: u64) callconv(.c) noreturn {
    main(@intCast(argc), argv_va);
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

/// Write a marker line to the serial console (fd 1) — the gate's grep target.
fn write_marker(msg: []const u8) void {
    _ = syscall3(sys_write, 1, @intFromPtr(msg.ptr), msg.len);
}

// (argv is intentionally unused: importing the toolkit grew WMRPC past the
// flat-DSK1 single-page argv cap, so the fixed gate topology is hardcoded in
// main() and `exec WMRPC.BIN` takes no arguments — see main().)

/// Scan the sys_procs snapshot for a RUNNING process whose name equals
/// `want`. Returns its pid, or null. WMS7 Gate B: delegates to the toolkit
/// client (`ui.wm_find_pid`), which owns the claim-5799 row parsing.
fn find_pid(want: []const u8) ?u8 {
    const pid = ui.wm_find_pid(want);
    return if (pid == 0) null else @intCast(pid);
}

fn main(argc: usize, argv_va: u64) noreturn {
    // The gate's topology is fixed (NOTEPAD opens window 2; the WM server is
    // WND.BIN), and importing the toolkit grew WMRPC past the flat-DSK1
    // single-text-page argv cap (content must leave 256 B for the argv
    // block) — so these are hardcoded rather than argv-fed. `_start` still
    // receives argc/argv (the kernel always passes them); WMRPC just
    // ignores them, so `exec WMRPC.BIN` needs no argv room.
    _ = argc;
    _ = argv_va;
    const target: u8 = 2; // NOTEPAD.BIN's window in the gate
    const wm_name: []const u8 = "WND.BIN";

    // Open our own window first (a SECOND user window in the WM boot, so the
    // raise is observable: opening focuses it; WIN_RAISE for `target` must
    // move focus back). In the no-WM boot it is WMRPC's own window — the one
    // window the owner-restricted fallback syscalls (`sys_win_raise_front`,
    // `sys_win_move`) will accept.
    const own_id = syscall4(sys_win_open, own_x, own_y, own_w, own_h);
    var buf2: [48]u8 = undefined;
    const s2 = std.fmt.bufPrint(&buf2, "{s}{d}\n", .{ own_marker, own_id }) catch "wmrpc: own-id=0\n";
    write_marker(s2);

    // Discover the WM (must be a running row). With NO WM registered
    // (the shim desktop), Gate B proves the toolkit's syscall fallback: the
    // re-pointed `ui.wm_raise_front` / `ui.wm_config` drop to the FROZEN
    // syscalls (`sys_win_raise_front` slot 49, `sys_win_move` slot 16) so a
    // toolkit app behaves identically with or without a WM. We exercise that
    // additive path on OUR OWN window (the owner-restricted syscalls need
    // it) and print markers the gate greps — then park.
    const wm_pid = find_pid(wm_name) orelse {
        write_marker(no_wm_marker);
        var fb: [56]u8 = undefined;
        const raised = ui.wm_raise_front(@intCast(own_id), "WMRPC.BIN");
        const moved = ui.wm_config(@intCast(own_id), 40, 40, 360, 260, "WMRPC.BIN");
        const m = std.fmt.bufPrint(&fb, wmrpc_fallback_fmt, .{ if (raised) "ok" else "no", if (moved) "ok" else "no" }) catch "wmrpc: fallback\n";
        write_marker(m);
        park();
    };
    // The toolkit resolves self pid for the ack's reply_to; report it in the
    // ready marker (the toolkit's wm_peers does one sys_procs scan).
    const peers = ui.wm_peers("WMRPC.BIN");
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s} pid={d} self={d} target={d}\n", .{ ready_marker, wm_pid, peers.self, target }) catch "wmrpc: wm\n";
    write_marker(s);

    // WIN_RAISE the target window THROUGH THE TOOLKIT (WMS7 Gate B):
    // ui.wm_mail_request builds the WmRpc frame, sends to the WM's mailbox,
    // awaits the ack, and reports applied. The toolkit's synchronous-shaped
    // client means WMRPC is a plain caller — no hand-rolled mail, no own
    // sequence/poll state machine.
    {
        const applied = ui.wm_mail_request(wnd_core.wm_rpc_kind_raise, target, 0, 0, 0, 0, "", "WMRPC.BIN", 1);
        var b: [56]u8 = undefined;
        const m = std.fmt.bufPrint(&b, "{s} applied={s}\n", .{ raise_ack_marker, if (applied) "yes" else "no" }) catch "wmrpc: raise-ack\n";
        write_marker(m);
    }
    // WIN_CONFIG the target window (clamped move/resize + bounded title).
    {
        const applied = ui.wm_mail_request(wnd_core.wm_rpc_kind_config, target, config_x, config_y, config_w, config_h, config_title, "WMRPC.BIN", 2);
        var b: [56]u8 = undefined;
        const m = std.fmt.bufPrint(&b, "{s} applied={s}\n", .{ config_ack_marker, if (applied) "yes" else "no" }) catch "wmrpc: config-ack\n";
        write_marker(m);
    }

    write_marker(done_marker);
    park();
}

fn park() noreturn {
    while (true) {
        _ = syscall0(sys_yield_num);
    }
}

// ---------------------------------------------------------------------------
// Host tests — pins + pure discovery logic (the EL0 payload itself can't run
// a host test; these lock the markers + the WM_RPC fit so the gate's grep
// targets and the 64-B bound cannot drift).
// ---------------------------------------------------------------------------
test "wmrpc: the pinned markers are the live gate's grep targets" {
    try std.testing.expectEqualStrings("wmrpc: wm", ready_marker);
    try std.testing.expectEqualStrings("wmrpc: own-id=", own_marker);
    try std.testing.expectEqualStrings("wmrpc: raise-ack", raise_ack_marker);
    try std.testing.expectEqualStrings("wmrpc: config-ack", config_ack_marker);
    try std.testing.expectEqualStrings("wmrpc: done", done_marker);
    try std.testing.expectEqualStrings("wmrpc: no-wm", no_wm_marker);
    // Gate B's no-WM fallback marker (the live gate's grep target).
    try std.testing.expectEqualStrings("wmrpc: fallback raise={s} move={s}\n", wmrpc_fallback_fmt);
    try std.testing.expectEqualStrings("wm-rpc", config_title);
    // The config rect the gate asserts on the dui window row.
    try std.testing.expectEqual(@as(u16, 40), config_x);
    try std.testing.expectEqual(@as(u16, 360), config_w);
    try std.testing.expectEqual(@as(u16, 260), config_h);
}

test "wmrpc: the WM_RPC request fits the frozen 64-byte mailbox slot" {
    // The ADR 0015 size decision: NO message_max growth — the compact fixed
    // layout (with the bounded title) must fit wnd_core.wm_rpc_max.
    try std.testing.expect(@sizeOf(wnd_core.WmRpc) <= wnd_core.wm_rpc_max);
    try std.testing.expectEqual(@as(usize, 64), wnd_core.wm_rpc_max);
    // The toolkit mirror the app actually sends through must match wnd_core's
    // frozen values + layout (WMS7 Gate B's single drift guard, locked here).
    try std.testing.expectEqual(@as(u8, wnd_core.wm_rpc_kind_raise), ui.wm_rpc_kind_raise);
    try std.testing.expectEqual(@as(u8, wnd_core.wm_rpc_kind_config), ui.wm_rpc_kind_config);
    try std.testing.expectEqual(@as(u8, wnd_core.wm_rpc_reply_flag), ui.wm_rpc_reply_flag);
    // M42 SX2: the additive tab-aware declaration kind mirrors too.
    try std.testing.expectEqual(@as(u8, wnd_core.wm_rpc_kind_declare_fullscreen), ui.wm_rpc_kind_declare_fullscreen);
    try std.testing.expectEqual(@as(usize, wnd_core.wm_rpc_max), ui.wm_rpc_max);
    try std.testing.expectEqual(@as(usize, @sizeOf(wnd_core.WmRpc)), @sizeOf(ui.WmRpc));
    // The procs row layout + running code (must match process.State order).
    try std.testing.expectEqual(@as(usize, 40), procs_row_bytes);
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(ProcsRow));
    try std.testing.expectEqual(@as(u64, 2), procs_state_running);
}
