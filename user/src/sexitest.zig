//! census (M188e, #3190): SEXITEST.BIN — gate-referenced: live-sexiburger-actions, live-wm1.
//! VirelaiOS Milestone 19 Sexiburger Action Registry & Tab Test App (SEXITEST.BIN).
//!
//! Tests the end-to-end action registration seam (issue #701, #705) and the
//! WM tab model (issue #782).
//!
//! 1. Opens an EL0 user window.
//! 2. Connects to WND.BIN via IPC mailbox (sys_ipc_send/recv).
//! 3. Registers an action into section 2 (Active app / Tomato layer) with
//!    label "Sexitest Action" and shell verb "test-act".
//! 4. Invokes the registered action and verifies the ack.
//! 5. Tests tab attachment, tab cycling, and tab detachment.
//! 6. Emits pinned serial markers for live gate verification.

const std = @import("std");
const wnd_core = @import("wnd_core");
const ui = @import("lib/ui.zig");

const sys_write: u64 = 1;
const sys_sleep: u64 = 4;
const sys_win_open: u64 = 12;

pub const ready_marker: []const u8 = "sexitest: ready\n";
pub const own_marker: []const u8 = "sexitest: own-id=";
pub const reg_ack_marker: []const u8 = "sexitest: register-ack applied=";
pub const act_exec_marker: []const u8 = "sexitest: action executed: Sexitest Action ok=1\n";
pub const tab_attach_ack_marker: []const u8 = "sexitest: tab-attached ok=1\n";
pub const tab_cycle_ack_marker: []const u8 = "sexitest: tab-cycled ok=1\n";
pub const tab_detach_ack_marker: []const u8 = "sexitest: tab-detached ok=1\n";
pub const done_marker: []const u8 = "sexitest: done\n";
pub const no_wm_marker: []const u8 = "sexitest: no-wm\n";

export fn _start(argc: u64, argv_va: u64) callconv(.c) noreturn {
    main(@intCast(argc), argv_va);
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
    _ = syscall3(sys_write, 1, @intFromPtr(msg.ptr), msg.len);
}

fn syscall0(num: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
        : .{ .memory = true });
    return res;
}

fn park() noreturn {
    while (true) {
        _ = syscall0(ui.sys_yield_num);
    }
}

fn main(argc: usize, argv_va: u64) noreturn {
    _ = argc;
    _ = argv_va;

    write_marker(ready_marker);

    // Open a user window
    const own_id = syscall4(sys_win_open, 200, 200, 320, 240);
    var buf_id: [48]u8 = undefined;
    const s_id = std.fmt.bufPrint(&buf_id, "{s}{d}\n", .{ own_marker, own_id }) catch "sexitest: own-id=0\n";
    write_marker(s_id);

    // Find WM server (WND.BIN)
    const wm_pid = ui.wm_find_pid("WND.BIN");
    if (wm_pid == 0) {
        write_marker(no_wm_marker);
        park();
    }

    // 1. Action registration: section 2 (Active app / Tomato layer)
    const reg_ok = ui.wm_register_action(@intCast(own_id), 2, 1, "Sexitest Action", "SEXITEST.BIN");
    var buf_ack: [64]u8 = undefined;
    const s_ack = std.fmt.bufPrint(&buf_ack, "{s}{s}\n", .{ reg_ack_marker, if (reg_ok) "yes" else "no" }) catch "sexitest: register-ack\n";
    write_marker(s_ack);

    // 2. Action invocation
    const inv_ok = ui.wm_invoke_action("Sexitest Action", "SEXITEST.BIN");
    if (inv_ok) {
        write_marker(act_exec_marker);
    }

    // 3. Tab model: attach own window as a tab to window 2 (e.g. NOTEPAD or previous window)
    const target_parent: u32 = if (own_id == 2) 3 else 2;
    const attach_ok = ui.wm_attach_tab(@intCast(own_id), target_parent, "SEXITEST.BIN");
    if (attach_ok) {
        write_marker(tab_attach_ack_marker);
    }

    // 4. Tab cycle
    const cycle_ok = ui.wm_cycle_tab("SEXITEST.BIN");
    if (cycle_ok) {
        write_marker(tab_cycle_ack_marker);
    }

    // 5. Tab detach
    const detach_ok = ui.wm_detach_tab(@intCast(own_id), "SEXITEST.BIN");
    if (detach_ok) {
        write_marker(tab_detach_ack_marker);
    }

    write_marker(done_marker);
    park();
}
