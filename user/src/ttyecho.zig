//! census (M188e, #3190): TTYECHO.BIN — gate-referenced: live-ttyecho.
//! VirelaiOS terminal-seam pilot — TTYECHO.BIN (#1072, ADR 0020).
//!
//! Proves an EL0 process can OWN a terminal through the seam:
//!   1. `sys_file_open("/dev/tty", MODE_READ|MODE_WRITE)` (slot 23)
//!   2. `sys_tty_attach(1)` — attach the serial console front-end (slot 67)
//!   3. loop: `sys_file_read(fd, buf)` -> `sys_file_write(fd, buf)` (echo)
//!   4. `sys_exit(status)`.
//!
//! The kernel pumps console RX into the terminal's input queue and drains the
//! terminal's output ring back to the console (ADR 0020 D2). Markers on
//! stdout let the class-B gate prove the round trip in the serial log.
//!
//! No window, no heap. `q` alone quits.

const std = @import("std");
const ui = @import("lib/ui.zig");

pub const ready_marker: []const u8 = "ttyecho: ready\n";
pub const attached_marker: []const u8 = "ttyecho: attached\n";
pub const got_marker: []const u8 = "ttyecho: got ";
pub const bye_marker: []const u8 = "ttyecho: bye\n";
pub const exit_status: u64 = 66;
pub const tty_path: []const u8 = "/dev/tty";

pub export fn _start() callconv(.c) noreturn {
    ui.write_console(ready_marker);

    const fd_res = ui.file_open(tty_path, ui.MODE_READ | ui.MODE_WRITE);
    if (fd_res < 0) {
        ui.write_console("ttyecho: no /dev/tty\n");
        ui.exit_process(1);
    }
    const fd: u32 = @intCast(fd_res);

    if (ui.tty_attach(1) != 0) {
        ui.write_console("ttyecho: attach failed\n");
        ui.file_close(fd);
        ui.exit_process(2);
    }
    ui.write_console(attached_marker);

    var buf: [64]u8 = undefined;
    var quitting = false;
    while (!quitting) {
        const n = ui.file_read(fd, &buf);
        if (n <= 0) {
            // Nothing pending: yield so the kernel shell can pump the console
            // and other tasks run. The console RX FIFO buffers keys.
            ui.yield_task();
            continue;
        }
        const len: usize = @intCast(n);
        // Echo a marker line on stdout (the serial console) in ONE write so a
        // concurrent writer (the SMP heartbeat) cannot split the marker from
        // the bytes, then echo the bytes back THROUGH the terminal so the
        // front-end pump emits them.
        var line: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&line, "{s}{s}", .{ got_marker, buf[0..len] }) catch got_marker;
        ui.write_console(msg);
        _ = ui.file_write(fd, buf[0..len]);
        if (len == 1 and (buf[0] == 'q' or buf[0] == 0x04)) quitting = true;
    }

    _ = ui.tty_attach(0); // detach — the kernel shell reclaims the console
    ui.file_close(fd);
    ui.write_console(bye_marker);
    ui.exit_process(exit_status);
}
