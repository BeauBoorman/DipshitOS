//! census (M188e, #3190): TABHOLD.BIN — gate-referenced: live-tabclick, live-tabstrip.
//! VirelaiOS M37 DQ2 tab-strip live-gate holder (TABHOLD.BIN, issue #840).
//!
//! Opens a user window, attaches it as a tab of the OTHER window in the
//! fixture (NOTEPAD), then parks in a yield loop HOLDING the attachment so
//! the gate can snapshot the kernel-painted strip. SEXITEST.BIN stays
//! untouched as the M19 fixture (it attaches, cycles, and detaches
//! immediately — no hold), and the holder reuses DQ3's click target.
//!
//! Census note: window ids are free-slot order from user_window_id_base
//! (2), and the M42 SX4 TabApp open (NOTEPAD) waits on a host theme-sync
//! round trip BEFORE win_open — so NOTEPAD's window can land as id 2 or id
//! 3 relative to this holder's own id, whichever opens first. The attach
//! target is therefore derived from own_id (SEXITEST's M19 precedent), not
//! hardcoded: the burst census is exactly {2,3} (WND opens no window).

const std = @import("std");
const wnd_core = @import("wnd_core");
const ui = @import("lib/ui.zig");

const sys_write: u64 = 1;
const sys_win_open: u64 = 12;

pub const ready_marker: []const u8 = "tabhold: ready\n";
pub const attached_marker: []const u8 = "tabhold: attached parent="; // + "{d}\n" at the print site
pub const cycled_marker: []const u8 = "tabhold: cycled\n";
pub const done_marker: []const u8 = "tabhold: done\n";
pub const no_wm_marker: []const u8 = "tabhold: no-wm\n";
pub const attach_fail_marker: []const u8 = "tabhold: attach-failed\n";
pub const cycle_fail_marker: []const u8 = "tabhold: cycle-failed\n";

export fn _start(argc: u64, argv_va: u64) callconv(.c) noreturn {
    main(@intCast(argc), argv_va);
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

fn park() noreturn {
    while (true) {
        _ = syscall0(ui.sys_yield_num);
    }
}

fn main(argc: usize, argv_va: u64) noreturn {
    _ = argc;
    _ = argv_va;
    _ = wnd_core.tab_bar_height; // drift guard: holder builds on the shared rules

    write_marker(ready_marker);

    const own_id = syscall4(sys_win_open, 200, 200, 320, 240);
    if (own_id < 0) park();

    // Self-driving: the gate execs us in the boot burst alongside NOTEPAD,
    // so the WM / NOTEPAD's window may not exist yet. Retry attach until it
    // lands (bounded: 40 × 2s ≈ 80s — NOTEPAD opens in ~15-30s). No
    // script-phase triggers needed, which dodges the phase-2 delivery flake
    // (issue #843). Target the fixture's OTHER window whatever the census
    // (see the header): NOTEPAD's M42 SX4 theme-sync delay lets our own
    // instant open win id 2, in which case hardcoding parent=2 would be a
    // self-attach that WND honestly refuses (regression that redded the
    // DQ2/DQ3 gates after the SX4 port).
    const target_parent: u32 = if (own_id == 2) 3 else 2;
    var attached = false;
    var tries: usize = 0;
    while (!attached and tries < 40) : (tries += 1) {
        if (ui.wm_find_pid("WND.BIN") != 0) {
            attached = ui.wm_attach_tab(@intCast(own_id), target_parent, "TABHOLD.BIN");
        }
        if (!attached) ui.sleep_ticks(2);
    }
    if (!attached) {
        write_marker(attach_fail_marker);
        park();
    }
    var abuf: [48]u8 = undefined;
    const amsg = std.fmt.bufPrint(&abuf, "{s}{d}\n", .{ attached_marker, target_parent }) catch "tabhold: attached parent=?\n";
    write_marker(amsg);
    // Cycle twice (container→child→container, ids census-dependent): the
    // group ends on NOTEPAD visible+focused with this window
    // attached-but-hidden — the canonical tabbed state the strip paint
    // reads. Either cycle failing leaves a held-but-unfocused group; the
    // gate snapshots whatever is, honestly.
    if (!ui.wm_cycle_tab("TABHOLD.BIN") or !ui.wm_cycle_tab("TABHOLD.BIN")) {
        write_marker(cycle_fail_marker);
        park();
    }
    write_marker(cycled_marker);
    // Hold the attachment across the snapshot stream (~25s by the chrome
    // gate's calibration), then print done so the gate's expect can fire
    // with zero further script phases.
    ui.sleep_ticks(60);
    write_marker(done_marker);
    park();
}
