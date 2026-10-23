//! census (M188e, #3190): DEVCONS.BIN — gate-referenced: live-devcons, live-tabclick, live-tokens, live-typography, live-wm1.
//! VirelaiOS ESP user program — DEVCONS.BIN (M22 D14, issue #337, claim 9815).
//!
//! Developer console window: split-screen layout with a log pane (top) and
//! a command prompt (bottom). Commands typed at the prompt execute through
//! sys_exec (slot 28) and their output appears in the log pane.
//!
//! Without sys_dmesg_read (not in M22 ABI budget), the log pane shows
//! boot markers and command output only — honest about the limitation.
//!
//! No libc, no POSIX, no heap; state lives on the task stack.

const std = @import("std");
const ui = @import("lib/ui.zig");
const tabapp = @import("lib/tabapp.zig");

const win_x: u32 = 260;
const win_y: u32 = 24;
const win_w: u32 = 400;
const win_h: u32 = 300;

const log_lines: usize = 20;
const log_line_h: u32 = 12;
const native_prompt_y: u32 = 250;
const input_max: usize = 64;

// M42 SX4 (issue #985): the tab-aware canvas. The window opens at the
// native 400x300 (the legacy shim/WND presentation is unchanged); under
// TABWM.BIN the declaration is accepted and activation delivers the full
// 1100x720 viewport via the kernel's WIN_RESIZE seam, which `layout`
// maps into (prompt row + log pane stretch proportionally).
var canvas_w: u32 = win_w;
var canvas_h: u32 = win_h;
var prompt_y: u32 = native_prompt_y;

/// Map the fixed 400x300 layout into a `w x h` canvas. At the native
/// size every rect maps to itself (the zero-regression fixed point).
pub fn layout(w: u32, h: u32) void {
    canvas_w = w;
    canvas_h = h;
    prompt_y = tabapp.scale(ui.Rect.make(0, native_prompt_y, 1, 1), win_w, win_h, w, h).y;
}

/// Visible log rows for the current canvas (storage caps at log_lines;
// the pane itself stretches to fill the viewport).
pub fn visible_rows() usize {
    if (prompt_y <= 26) return 1;
    const rows = (prompt_y - 22) / log_line_h;
    return @min(rows, log_lines);
}

var log_buf: [log_lines * 128]u8 = undefined;
var log_lens: [log_lines]u16 = undefined;
var log_head: usize = 0;
var log_count: usize = 0;
var cursor_kind: ui.CursorKind = .arrow; // M37 DQ4: per-region cursor state

/// M37 DQ4: ibeam over the prompt line (text entry), arrow elsewhere.
/// Emits `devcons: cursor=<name>` on change (serial-observable).
fn update_cursor(x: u32, y: u32) void {
    _ = x;
    const kind = ui.cursor_for_region(false, false, y >= prompt_y);
    if (kind != cursor_kind) {
        cursor_kind = kind;
        var buf: [48]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "devcons: cursor={s}\n", .{kind.name()}) catch return;
        ui.write_console(msg);
    }
}

pub export fn _start() callconv(.c) noreturn {
    // M42 SX4: the tab-aware open. Native 400x300 when the viewport
    // proposal is absent (shim/WND); full 1100x720 under TABWM.BIN.
    const ta_res = tabapp.TabApp.init(.{
        .name = "DEVCONS.BIN",
        .title = "DevCons",
        .x = win_x,
        .y = win_y,
        .w = win_w,
        .h = win_h,
    }) orelse {
        ui.write_console("devcons: failed to open window\n");
        ui.exit_process(1);
    };
    var ta = ta_res;
    layout(ta.w, ta.h);
    const win = ta.win;
    if (ta.tab_aware) {
        ui.write_console("devcons: tab-aware (full-viewport)\n");
    } else {
        ui.write_console("devcons: not-tab-aware (shim or WND desktop)\n");
    }
    ui.write_console("devcons: open\n");

    log_append("VirelaiOS Developer Console (M22 D14)");
    log_append("Type commands at the prompt below.");
    log_append("---");
    refresh(win);
    ui.emit_tokens_marker("devcons");
    ui.write_console("devcons: ready\n");
    // M37 DQ4 gate: let the compositor settle (several ticks) so the
    // kind-4 snapshot captures the presented frame, not a stale one.
    ui.sleep_ticks(5);
    ui.write_console("devcons: settled\n");

    var ev: ui.Event = undefined;
    var input_buf: [input_max]u8 = undefined;
    var input_len: usize = 0;

    while (true) {
        if (ui.wait_event(&ev) < 0) break;
        // M42 SX4: WM-lifecycle events (resize -> relayout) first.
        switch (ta.dispatch(&ev)) {
            .closed => {
                ta.close();
                ui.exit_process(0);
            },
            .resized => {
                ui.write_console("devcons: resize relayout\n");
                layout(ta.w, ta.h);
                refresh(ta.win);
                continue;
            },
            .none => {},
        }
        switch (ev.kind) {
            ui.WIN_CLOSE => {
                ta.close();
                ui.exit_process(0);
            },
            ui.MOUSE_MOVE => {
                // M37 DQ4: cursor tracking only (no click actions).
                update_cursor(ev.arg0, ev.arg1);
            },
            ui.KEY_DOWN => {
                handle_key_down(ta.win, &ev, &input_buf, &input_len);
            },
            else => {},
        }
        // Drain pending queue. The drain MUST consume KEY_DOWN with the
        // same handler as the wait path — the custom-virtio input channel
        // delivers key reports in batches (one shell-idle pass drains
        // several enqueued reports), so a `dir.bin\n` typed as 8 strokes
        // queues as multiple events at once. The M42 SX4 port (179276c)
        // drained with MOUSE_MOVE-only handling, silently dropping every
        // KEY_DOWN behind the first in each batch — the typed-input gate
        // (issue #553) regressed with no error, just dead keys.
        while (ui.poll_event(&ev) > 0) {
            switch (ta.dispatch(&ev)) {
                .closed => {
                    ta.close();
                    ui.exit_process(0);
                },
                .resized => {
                    ui.write_console("devcons: resize relayout\n");
                    layout(ta.w, ta.h);
                    refresh(ta.win);
                    continue;
                },
                .none => {},
            }
            switch (ev.kind) {
                ui.WIN_CLOSE => {
                    ta.close();
                    ui.exit_process(0);
                },
                ui.MOUSE_MOVE => {
                    update_cursor(ev.arg0, ev.arg1);
                },
                ui.KEY_DOWN => {
                    handle_key_down(ta.win, &ev, &input_buf, &input_len);
                },
                else => {},
            }
        }
    }
    ta.close_and_exit(0);
}

/// The DEVCONS prompt's KEY_DOWN handling — shared by the wait path and the
/// poll drain so no queued keystroke is lost (see the drain-loop note
/// above). ADR 0014 event convention: arg0 is the raw HID usage (Enter 0x28,
/// Backspace 0x2a), arg1 is a Unicode codepoint. The command prompt remains
/// ASCII-only and refuses symbols it cannot encode.
fn handle_key_down(win: u32, ev: *const ui.Event, input_buf: *[input_max]u8, input_len: *usize) void {
    const usage = ev.arg0;
    const ascii = ev.arg1;
    if (usage == 0x28) {
        // Enter: execute command
        if (input_len.* > 0) {
            execute_command(input_buf.*[0..input_len.*]);
            input_len.* = 0;
        }
        refresh(win);
    } else if (usage == 0x2a) {
        // Backspace
        if (input_len.* > 0) input_len.* -= 1;
        refresh(win);
    } else if (ascii >= 0x20 and ascii < 0x7f and input_len.* < input_max) {
        input_buf.*[input_len.*] = @intCast(ascii);
        input_len.* += 1;
        refresh(win);
    }
}

fn log_append(msg: []const u8) void {
    const idx = (log_head + log_count) % log_lines;
    const start = idx * 128;
    const take = @min(msg.len, 127);
    @memcpy(log_buf[start..][0..take], msg[0..take]);
    log_buf[start + take] = 0;
    log_lens[idx] = @intCast(take);
    if (log_count < log_lines) {
        log_count += 1;
    } else {
        log_head = (log_head + 1) % log_lines;
    }
}

fn execute_command(cmd: []const u8) void {
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    const prefix = "> ";
    @memcpy(buf[0..prefix.len], prefix);
    n = prefix.len;
    const take = @min(cmd.len, buf.len - n - 1);
    @memcpy(buf[n..][0..take], cmd[0..take]);
    n += take;
    buf[n] = 0;
    log_append(buf[0..n]);

    // Execute via sys_exec (slot 28) — the command runs as a child process.
    // Output goes to the serial console (not captured into the log pane
    // without sys_dmesg_read, but the marker proves execution happened).
    const exec_res = ui.exec_program(cmd);
    if (exec_res < 0) {
        log_append("exec: failed");
    } else {
        log_append("exec: ok (output on serial)");
    }
}

fn refresh(win: u32) void {
    // Background
    ui.win_fill(win, 0, 0, canvas_w, canvas_h, ui.theme_bg());
    // Title bar
    ui.win_fill(win, 0, 0, canvas_w, 6, ui.theme_surface());
    ui.draw_text(win, "Developer Console", ui.pad_md, 8, ui.theme_text_muted());

    // Log pane (top section) — M37 DQ4: unified surface (was 0x1a1a2e).
    ui.win_fill(win, 0, 18, canvas_w, prompt_y - 18, ui.theme_surface());
    var y: u32 = 22;
    var i: usize = 0;
    while (i < log_count and i < log_lines) : (i += 1) {
        const idx = (log_head + i) % log_lines;
        const len = log_lens[idx];
        if (len > 0) {
            const start = idx * 128;
            ui.draw_text_mono(win, log_buf[start..][0..len], ui.pad_md, y, ui.theme_text_primary());
        }
        y += log_line_h;
        if (y + log_line_h > prompt_y - 4) break;
    }

    // Separator
    ui.win_fill(win, 0, prompt_y - 2, canvas_w, ui.border_w, ui.theme_text_muted());

    // Prompt area
    ui.draw_text(win, "$ ", ui.pad_sm, prompt_y + 4, ui.theme_success());

    // Show a hint about serial output
    ui.draw_text(win, "(output on serial console)", 80, prompt_y + 4, ui.theme_text_muted());

    ui.win_present(win);
}

// ---------------------------------------------------------------------------
// Host unit tests (M42 SX4 — the tab-aware layout)
// ---------------------------------------------------------------------------

test "devcons layout: native canvas is the identity (zero-regression fixed point)" {
    layout(win_w, win_h);
    try std.testing.expectEqual(win_w, canvas_w);
    try std.testing.expectEqual(win_h, canvas_h);
    try std.testing.expectEqual(native_prompt_y, prompt_y);
    // Native geometry holds 19 rows ((250-22)/12), storage caps at 20.
    try std.testing.expectEqual(@as(usize, 19), visible_rows());
}

test "devcons layout: full viewport stretches the console rows" {
    layout(1100, 720);
    try std.testing.expectEqual(@as(u32, 1100), canvas_w);
    try std.testing.expectEqual(@as(u32, 720), canvas_h);
    // Prompt row maps proportionally: 250 * 720 / 300 = 600.
    try std.testing.expectEqual(@as(u32, 600), prompt_y);
    // The pane grows with the viewport (storage still caps the ring).
    try std.testing.expectEqual(log_lines, visible_rows());
    try std.testing.expect(prompt_y + 4 < canvas_h);
}
