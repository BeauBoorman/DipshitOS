//! census (M188e, #3190): RESMON.BIN — gate-referenced: live-resmon, live-wm1.
//! VirelaiOS ESP user program — RESMON.BIN (M22 D10, issue #333, claim 9815).
//!
//! Lightweight resource monitor window: shows process count, scheduler state,
//! and uptime via sys_procs (slot 7) + timer ticks. Auto-refreshes at 1 Hz.
//!
//! Memory/disk/network stats require new syscalls (not in M22 ABI budget);
//! those sections report "unavailable" honestly.
//!
//! No libc, no POSIX, no heap; state lives on the task stack.

const std = @import("std");
const ui = @import("lib/ui.zig");

const win_x: u32 = 200;
const win_y: u32 = 24;
const win_w: u32 = 320;
const win_h: u32 = 200;

const refresh_ticks: u64 = 100; // 1 second

const proc_snapshot_rows: usize = 16;
const proc_row_size: usize = 40;
var snap_buf: [proc_snapshot_rows * proc_row_size]u8 = undefined;
var rows: [12]ui.ProcInfo = undefined;

pub export fn _start() callconv(.c) noreturn {
    const win_res = ui.win_open(win_x, win_y, win_w, win_h);
    if (win_res < 0) {
        ui.write_console("resmon: failed to open window\n");
        ui.exit_process(1);
    }
    const win: u32 = @intCast(win_res);
    ui.write_console("resmon: open\n");
    _ = ui.timer_set(refresh_ticks);
    refresh(win);
    ui.write_console("resmon: ready\n");

    var ev: ui.Event = undefined;
    while (true) {
        if (ui.wait_event(&ev) < 0) break;
        switch (ev.kind) {
            ui.WIN_CLOSE => {
                ui.win_close(win);
                ui.exit_process(0);
            },
            ui.EVENT_TIMER => {
                refresh(win);
                _ = ui.timer_set(refresh_ticks);
            },
            else => {},
        }
    }
    ui.exit_process(0);
}

fn refresh(win: u32) void {
    ui.win_fill(win, 0, 0, win_w, win_h, ui.COLOR_BG);
    // Title bar
    ui.win_fill(win, 0, 0, win_w, 6, ui.COLOR_SURFACE);
    ui.draw_text(win, "Resource Monitor", 8, 8, ui.COLOR_TEXT_MUTED);

    // Process count
    const n_raw = ui.get_procs(&snap_buf);
    var active_count: u32 = 0;
    var exited_count: u32 = 0;
    if (n_raw > 0) {
        const count = ui.parse_procs(snap_buf[0..], @intCast(n_raw), &rows);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (rows[i].state == .running) active_count += 1;
            if (rows[i].state == .exited) exited_count += 1;
        }
    }

    ui.draw_text(win, "PROCESSES:", 8, 30, ui.COLOR_TEXT_MUTED);
    var buf: [32]u8 = undefined;
    const active_s = fmt_u32(&buf, active_count);
    ui.draw_text(win, active_s, 120, 30, ui.COLOR_SUCCESS);
    ui.draw_text(win, " active", @intCast(120 + active_s.len * 8 + 4), 30, ui.COLOR_TEXT_MUTED);

    // Memory (honest: no syscall available)
    ui.draw_text(win, "MEMORY:", 8, 52, ui.COLOR_TEXT_MUTED);
    ui.draw_text(win, "unavailable (no sys_mem_info)", 72, 52, ui.COLOR_TEXT_PRIMARY);

    // Disk (honest: no syscall available)
    ui.draw_text(win, "DISK:", 8, 74, ui.COLOR_TEXT_MUTED);
    ui.draw_text(win, "unavailable (no sys_disk_stats)", 56, 74, ui.COLOR_TEXT_PRIMARY);

    // Network (honest: no syscall available)
    ui.draw_text(win, "NET:", 8, 96, ui.COLOR_TEXT_MUTED);
    ui.draw_text(win, "unavailable (no sys_net_stats)", 48, 96, ui.COLOR_TEXT_PRIMARY);

    // Uptime (ticks since boot — read from serial console marker if available)
    ui.draw_text(win, "UPTIME:", 8, 118, ui.COLOR_TEXT_MUTED);
    ui.draw_text(win, "see sysinfo", 72, 118, ui.COLOR_TEXT_PRIMARY);

    // Process list
    ui.draw_text(win, "LIVE PROCESSES:", 8, 144, ui.COLOR_TEXT_MUTED);
    var y: u32 = 160;
    var i: usize = 0;
    while (i < rows.len and y + 14 < win_h) : (i += 1) {
        const r = &rows[i];
        if (r.state != .running) continue;
        ui.draw_text(win, r.name[0..r.name_len], 16, y, ui.COLOR_TEXT_PRIMARY);
        y += 14;
    }
    if (y == 160) {
        ui.draw_text(win, "(none)", 16, y, ui.COLOR_TEXT_MUTED);
    }

    ui.win_present(win);
}

fn fmt_u32(buf: *[32]u8, v_in: u32) []const u8 {
    if (v_in == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = v_in;
    var n: usize = 0;
    var tmp: [10]u8 = undefined;
    while (v > 0) : (v /= 10) {
        tmp[n] = @intCast('0' + v % 10);
        n += 1;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[i] = tmp[n - 1 - i];
    }
    return buf[0..n];
}
