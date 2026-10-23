//! census (M188e, #3190): TTYED.BIN — gate-referenced: live-ttyed.
//! TTYED.BIN — the M45 card SH1 (`user/src/lib/tty.zig`) live smoke demo
//! (issue #1077, ADR 0021 D6).
//!
//! Shapes the class-B proof of the terminal library: an EL0 process opens
//! `/dev/tty`, attaches the serial console front-end (`sys_tty_attach`), and
//! drives `lib/tty.zig`'s `LineEditor` from the raw input queue. The editor's
//! echo goes back THROUGH the terminal, so the serial log shows the editing
//! (insert/delete, Home/End, Up/Down history) applied live.
//!
//! On each submitted line it prints one marker line in a SINGLE write —
//! `ttyed: line <content>` — so a concurrent writer (the SMP heartbeat)
//! cannot split the marker. Ctrl-D ends the session and detaches.
//!
//! No window, no heap.

const std = @import("std");
const ui = @import("lib/ui.zig");
const tty = @import("lib/tty.zig");

pub const ready_marker: []const u8 = "ttyed: ready\n";
pub const attached_marker: []const u8 = "ttyed: attached\n";
pub const line_marker: []const u8 = "ttyed: line ";
pub const bye_marker: []const u8 = "ttyed: bye\n";
pub const prompt: []const u8 = "ttyed> ";
pub const exit_status: u64 = 65;

pub export fn _start() callconv(.c) noreturn {
    ui.write_console(ready_marker);

    var session = tty.Session.open() orelse {
        ui.write_console("ttyed: no /dev/tty\n");
        ui.exit_process(1);
    };
    if (!session.attach(.serial)) {
        ui.write_console("ttyed: attach failed\n");
        session.close();
        ui.exit_process(2);
    }
    ui.write_console(attached_marker);

    // The editor echoes through the terminal; the prompt joins that stream.
    const out = session.output();
    out.write(prompt);
    var editor = tty.LineEditor{};

    var buf: [64]u8 = undefined;
    while (true) {
        const n = session.read(&buf);
        if (n <= 0) {
            // Nothing pending: yield so the kernel pumps the console.
            ui.yield_task();
            continue;
        }
        const len: usize = @intCast(n);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            switch (editor.feed(out, buf[i])) {
                .submitted => {
                    // Marker + content in ONE write (SMP-heartbeat safe).
                    var line: [tty.max_line + 32]u8 = undefined;
                    const msg = std.fmt.bufPrint(&line, "{s}{s}\n", .{ line_marker, editor.line() }) catch line_marker;
                    ui.write_console(msg);
                    editor.next_line();
                    out.write(prompt);
                },
                .cancelled => out.write(prompt),
                .repaint => {
                    out.write(prompt);
                    editor.reprint(out);
                },
                .continued => {},
                .eof => {
                    session.detach();
                    session.close();
                    ui.write_console(bye_marker);
                    ui.exit_process(exit_status);
                },
                .none => {},
            }
        }
    }
}
