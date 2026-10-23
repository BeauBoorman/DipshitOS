//! census (M188e, #3190): SMPWIN.BIN — gate-referenced: live-smp-stress.
//! VirelaiOS four-core stress WIN hammer — SMPWIN.BIN (claim 907,
//! issue #858). Pinned to CORE 3 by the gate (`exec -c3 SMPWIN.BIN`);
//! it hammers the WIN service domain (slots 12-15 — kernel-owned window
//! open/fill/present/close) in a tight, bounded loop, so its core-3
//! traffic runs CONCURRENTLY with the FILE hammer on core 1, the NET
//! hammer on core 2, and the EV hammer on core 0. The fill/present path
//! also dirties the kernel compositor state that core 0's shell idle
//! blits — real cross-core WIN-domain traffic, same-domain only.
//!
//! Shape: open one 96x96 window (the first free user slot, id 2), then
//! 6 heartbeats x 2 fill+present rounds (each repaints the background
//! plus a cycling accent block) = 12 presents, one exact `smpwin: hb=<n>`
//! line per heartbeat (~1 s apart via sys_sleep — the wake is a ring
//! resume on core 3), then close the window, `smpwin: done presents=12`,
//! then sys_exit(0). A lost wakeup, a duplicate staging, a cross-domain
//! lock hold, or a wedged compositor breaks a marker or the clean reap.
//!
//! Plain freestanding Zig (the calc/notepad _start(.c) shape), no libc.
//! The marker/count constants are `pub const`s pinned by host tests so
//! the live gate's grep targets cannot drift from the payload.

const std = @import("std");
const st = @import("lib/smpst.zig");

/// The window id the first `sys_win_open` returns (first free user slot).
pub const window_id: u32 = 2;
/// The window geometry.
pub const win_w: u32 = 96;
pub const win_h: u32 = 96;
/// The colors (background + the cycling accent block).
pub const bg_rgb: u32 = 0x202830;
pub const accent_rgb: u32 = 0xff8800;
/// Heartbeats x fill+present rounds per heartbeat = total presents.
pub const heartbeats: u32 = 6;
pub const rounds_per_hb: u32 = 2;
pub const total_presents: u32 = heartbeats * rounds_per_hb;
/// The exit status.
pub const exit_status: u32 = 0;

/// A REAL writable global — forces a .bss segment (see smpst_file.zig:
/// the DSK3 loader maps it EL0-RW and the per-process uaccess regions
/// carry it across SVCs; hammering it under load exercises that seam).
var presents: u32 = 0;

pub export fn _start() callconv(.c) noreturn {
    const id = st.win_open(0, 0, win_w, win_h);
    st.print("smpwin: ", "open id={d}\n", .{id});
    if (id != window_id) st.exit_process(131);
    var hb: u32 = 1;
    while (hb <= heartbeats) : (hb += 1) {
        var j: u32 = 0;
        while (j < rounds_per_hb) : (j += 1) {
            if (st.win_fill(window_id, 0, 0, win_w, win_h, bg_rgb) != 0) st.exit_process(132);
            // A 24x24 accent block cycling by column so each fill differs.
            const col: u32 = (j + hb) % 3;
            if (st.win_fill(window_id, col * 32 + 4, 4, 24, 24, accent_rgb) != 0) st.exit_process(133);
            if (st.win_present(window_id) != 0) st.exit_process(134);
            presents += 1;
        }
        st.print("smpwin: ", "hb={d}\n", .{hb});
        st.sleep_ticks(1);
    }
    st.win_close(window_id);
    st.print("smpwin: ", "done presents={d}\n", .{presents});
    st.exit_process(exit_status);
}

test "user smpwin: marker/count/exit constants are pinned (live-gate targets)" {
    try std.testing.expectEqual(@as(u32, 2), window_id);
    try std.testing.expectEqual(@as(u32, 96), win_w);
    try std.testing.expectEqual(@as(u32, 96), win_h);
    try std.testing.expectEqual(@as(u32, 0x202830), bg_rgb);
    try std.testing.expectEqual(@as(u32, 0xff8800), accent_rgb);
    try std.testing.expectEqual(@as(u32, 6), heartbeats);
    try std.testing.expectEqual(@as(u32, 12), total_presents);
    try std.testing.expectEqual(@as(u32, 0), exit_status);
}

test "user smpwin module compiles on the host" {
    _ = @intFromPtr(&_start);
}
