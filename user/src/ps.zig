//! census (M188e, #3190): PS.BIN — gate-referenced: live-ps, live-wm1.
//! VirelaiOS ESP user program — PS.BIN (M22 D6, issue #329, claim 9815).
//!
//! Windowed process viewer: polls `sys_procs` (slot 7) once per second via
//! the M14 app-timer (`sys_timer_set`, slot 40) and renders one row per
//! non-free registry entry — PID, name, state, and exit status for exited
//! rows. F5 re-reads immediately; closing the window exits. The monitor's
//! `ps` command is the text-side twin of this view.
//!
//! No libc, no POSIX, no heap; state lives in a fixed BSS-free shape on
//! the task stack (DSK1 flat images map their text pages only).

const std = @import("std");
const ui = @import("lib/ui.zig");

const win_x: u32 = 24;
const win_y: u32 = 24;
const win_w: u32 = 300;
const win_h: u32 = 200;

/// 1-second auto-refresh (scheduler ticks; the timer re-arms each fire).
const auto_refresh_ticks: u64 = 100;

const max_rows: usize = 12;
const row_h: u32 = 14;
const header_y: u32 = 8;
const first_row_y: u32 = 24;

/// Snapshot staging: registry bound (11 processes) x the 40-byte row.
const proc_snapshot_rows: usize = 16;
const proc_row_size: usize = 40;
var snap_buf: [proc_snapshot_rows * proc_row_size]u8 = undefined;
var rows: [max_rows]ui.ProcInfo = undefined;

pub export fn _start() callconv(.c) noreturn {
    const win_res = ui.win_open(win_x, win_y, win_w, win_h);
    if (win_res < 0) {
        ui.write_console("ps: failed to open window\n");
        ui.exit_process(1);
    }
    const win: u32 = @intCast(win_res);
    ui.write_console("ps: open\n");
    _ = ui.timer_set(auto_refresh_ticks);
    refresh(win);
    ui.write_console("ps: ready\n");

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
                _ = ui.timer_set(auto_refresh_ticks);
            },
            else => {},
        }
    }
    ui.exit_process(0);
}

fn refresh(win: u32) void {
    // Background
    ui.win_fill(win, 0, 0, win_w, win_h, ui.COLOR_BG);
    // Title bar strip
    ui.win_fill(win, 0, 0, win_w, 6, ui.COLOR_SURFACE);

    ui.draw_text(win, "PID", 8, header_y, ui.COLOR_TEXT_MUTED);
    ui.draw_text(win, "NAME", 40, header_y, ui.COLOR_TEXT_MUTED);
    ui.draw_text(win, "STATE", 130, header_y, ui.COLOR_TEXT_MUTED);
    ui.draw_text(win, "EXIT", 210, header_y, ui.COLOR_TEXT_MUTED);

    const n_raw = ui.get_procs(&snap_buf);
    if (n_raw <= 0) {
        ui.draw_text(win, "no processes", 8, first_row_y, ui.COLOR_TEXT_PRIMARY);
        ui.win_present(win);
        return;
    }
    const count = ui.parse_procs(snap_buf[0..], @intCast(n_raw), &rows);
    var y: u32 = first_row_y;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const r = &rows[i];
        var num: [16]u8 = undefined;
        const pid_s = fmt_u64(&num, r.pid);
        ui.draw_text(win, pid_s, 8, y, ui.COLOR_TEXT_PRIMARY);

        const name = r.name[0..r.name_len];
        ui.draw_text(win, name, 40, y, ui.COLOR_TEXT_PRIMARY);

        ui.draw_text(win, state_str(r.state), 130, y, state_color(r.state));

        if (r.state == .exited) {
            var ex: [16]u8 = undefined;
            const ex_s = fmt_u64(&ex, r.exit_status);
            ui.draw_text(win, ex_s, 210, y, ui.COLOR_TEXT_MUTED);
        } else {
            ui.draw_text(win, "-", 210, y, ui.COLOR_TEXT_MUTED);
        }
        y += row_h;
        if (y + row_h > win_h) break;
    }
    ui.win_present(win);
}

fn state_str(s: ui.ProcState) []const u8 {
    return switch (s) {
        .created => "created",
        .running => "running",
        .exited => "exited",
        else => "?",
    };
}

fn state_color(s: ui.ProcState) u32 {
    return switch (s) {
        .created => ui.COLOR_TEXT_PRIMARY,
        .running => ui.COLOR_SUCCESS,
        .exited => ui.COLOR_TEXT_MUTED,
        else => ui.COLOR_TEXT_PRIMARY,
    };
}

fn fmt_u64(buf: []u8, v_in: u64) []const u8 {
    var v = v_in;
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
        return buf[i..];
    }
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + v % 10);
    }
    return buf[i..];
}
