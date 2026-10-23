//! census (M188e, #3190): WND.BIN — gate-referenced: live-wnd-server, live-wallpaper; also launched by the monitor `wnd start` builtin.
//! VirelaiOS M32 WMS3+WMS5 — WND.BIN, the long-lived EL0 window-manager SERVER
//! (issues #623/#625).
//!
//! WMS3 (issue #623): REGISTERs via `sys_wmctl` (slot 65, cmd 1) at startup,
//! then loops on `sys_wait_event` (slot 22), servicing the kernel's kind-18
//! `COMPOSITE_TICK` and issuing `REQUEST_PRESENT` (slot 65, cmd 3) at its OWN
//! cadence (every `present_every` ticks, not every tick). While it is
//! registered the shell idle drain is a no-op (WMS2), so THIS loop drives the
//! desktop's scanout presents.
//!
//! WMS5 (issue #625): the registered WM owns INPUT — the kernel fans the raw
//! pointer stream (kind 19 WM_POINTER), the window-registry mirrors (kind 20
//! WM_WINDOW), and — Gate 2 (claim 4278) — the raw keyboard stream (kind 21
//! WM_KEY) out to this process, and stops consuming geometry itself. This
//! server hit-tests and DECIDES geometry:
//!   * drag-to-move from kind 19 (title-bar grab -> SET_WINDOW rects);
//!   * snap-on-drop (a drag ending near a scanout edge issues the snapped rect);
//!   * tile / master-swap, minimize/restore, maximize/restore, workspace
//!     switch/cycle, fullscreen, always-on-top from kind 21 chords — all
//!     issued through SET_WINDOW (cmd 2) rects + SET_STATE (cmd 4) state, the
//!     frozen ADR 0007 encoding. The kernel clamps + blits whatever it gets.
//!
//! It NEVER exits — it occupies its scheduler slot + process row for the whole
//! session, like COUNTER.BIN/PEER.BIN. The loop is a draining server: each
//! wake (a `sys_wait_event` return) serves the WHOLE queued backlog, then the
//! next `sys_wait_event` parks it until the kernel pushes more — bounded work
//! per wake, and a blocked-in-wait rings around a hung one stalling the ring.
//! The kernel round-robins every tick regardless (the WMS2 exit fallback
//! covers the WM being killed; blocking-in-wait covers a hung one).
//!
//! The pure policy RULES it issues are compiled from the SAME source as the
//! kernel shim (`kernel/src/wnd_core.zig`, the drift guard) — the tile/snap/
//! maximize rect math and the chrome policy are one physical file, so the two
//! implementations cannot behaviorally drift while both are live.
//!
//! Written as a real Zig program (freestanding, no libc/POSIX) with inline
//! `svc` syscall wrappers — the payload grew past the WMS3-era naked-asm
//! pacing loop once policy landed (Gate 2). It imports mutable globals, so it
//! is built through the segmented DSK3 loader path (`linker-segmented.ld` +
//! `elf2bin.py --segments`) exactly like GLOBALS.BIN. The markers it writes
//! are pinned `pub const`s so host tests and the live gates' grep targets
//! cannot drift.

const std = @import("std");
// The drift guard: BOTH the kernel shim and this WM server compile the same
// pure rules from one file — the two implementations cannot behaviorally
// drift while both are live. Provided by build.zig as an anonymous import
// (the kernel compiles the same file from kernel/src/wnd_core.zig).
const wnd_core = @import("wnd_core");
pub const ui = @import("lib/ui.zig");
pub const sexiburger = @import("lib/sexiburger.zig");
pub const Command = sexiburger.Command;
pub const SectionId = sexiburger.SectionId;
pub const ActionRegistry = sexiburger.ActionRegistry;
pub const SexiburgerMenu = sexiburger.SexiburgerMenu;
pub const Rect = ui.Rect;

// ---------------------------------------------------------------------------
// Syscall numbers (slots frozen in ADR 0007; the same numbers the naked
// payload used — no new syscalls).
// ---------------------------------------------------------------------------
const sys_write: u64 = 1;
const sys_yield_num: u64 = 2;
const sys_wait_event_num: u64 = 22;
/// WMP card 2 (#1250): the non-blocking sibling of slot 22. It CONSUMES an
/// event (kernel `events.drop`), so the loop carries its result rather than
/// treating it as a peek — see the loop head.
const sys_poll_event_num: u64 = 21;
const sys_wmctl: u64 = 65;

// Slot-65 subcommands (ADR 0007 — frozen by WMS1/claim 1484, extended by
// WMS4 (cmd 2 chrome) and WMS5 Gate 2 (cmd 4 SET_STATE)).
const wmctl_register: u64 = 1;
const wmctl_set_window: u64 = 2;
/// WM4 (issue #707 card 4): the REST-OPACITY policy the WM submits in its
/// v2 chrome descriptor (an unfocused at-rest window's CLIENT area blends
/// at this alpha; chrome stays opaque; 256 = the v1 no-op).
const wm_rest_alpha_policy: u32 = 240;
const wmctl_request_present: u64 = 3;
const wmctl_set_state: u64 = 4;
const wmctl_alt_tab: u64 = 5;
/// ALT_TAB action 3 (commit) — the WM tells the kernel which window to
/// focus+raise+dismiss to. The kernel clamps + repaints the overlay blit.
const alt_tab_commit: u64 = 3;
// WMS6 Gate B (issue #626): the notification-center decision channel.
// NOTIF_CENTER (cmd 6) a0 = 0 close / 1 open / 2 clear-all; NOTIF_DISMISS
// (cmd 7) a0 = row index. The kernel clamps + blits from its own state.
const wmctl_notif_center: u64 = 6;
const notif_close_act: u64 = 0;
const notif_open_act: u64 = 1;
const notif_clear_act: u64 = 2;
const wmctl_notif_dismiss: u64 = 7;
// WMS6 Gate C (issue #626): the tooltip decision channel. TOOLTIP (cmd 8)
// a0 = 0 hide / 1 show (text via ptr/len, the 32-byte M27 bound). The WM
// decides when/what; the kernel clamps + blits below its own cursor.
const wmctl_tooltip: u64 = 8;
const tooltip_show_act: u64 = 1;
const tooltip_hide_act: u64 = 0;
// WMS6 Gate D (issue #626): the dock decision channel. DOCK (cmd 9) a0 =
// icon index (0..4) — the WM decides which icon a click hits; the kernel
// applies the same clamped chain the shim runs (restore/focus/open).
const wmctl_dock: u64 = 9;
// WMS6 Gate E (issue #626): the tray decision channel. TRAY (cmd 10) — the
// WM owns the tray WIDGET CONTENT: the clock string, theme letter, and
// clipboard indicator. a0 = flags (bit 0 clock, bit 1 theme, bit 2
// clipboard); a1 = the 5-byte "HH:MM" clock text packed little-endian; a2 =
// theme letter (low byte) | clipboard filled (bit 8). The kernel clamps +
// stores + repaints; the shim fallback re-derives all three from its own
// state (no-WM mode is byte-identical).
const wmctl_tray: u64 = 10;
const tray_flag_clock: u64 = 0b001;
const tray_flag_theme: u64 = 0b010;
const tray_flag_clip: u64 = 0b100;
// WMS8 Gate 2 (issue #628): the modal-dialog decision channel. DIALOG (cmd
// 11) a0 = 0 close / 1 open / 2 toggle. The WM — not the kernel — decides
// WHEN the about dialog opens/closes/toggles (it owns the kind-21 keyboard
// stream); the kernel applies the same clamped primitives the shim runs and
// blits the modal from its own `about_dialog_open` state.
const wmctl_dialog: u64 = 11;
const dialog_toggle_act: u64 = 2;
// WMS8 Gate 4 (issue #628): the unsaved-changes dialog rides the same
// DIALOG seam — a0 = 3 show (a1 = target window), 4 save, 5 dont-save,
// 6 cancel — applied through the kernel's own unsaved_dialog_* primitives.
const dialog_unsaved_show: u64 = 3;
const dialog_unsaved_save: u64 = 4;
const dialog_unsaved_dont_save: u64 = 5;
const dialog_unsaved_cancel: u64 = 6;
// WM3 (issue #707 card 3): the taskbar decision channel. TASKBAR (cmd 12)
// a0 = the entry's window id — the WM hit-tests the shared wnd_core entry
// rects and decides which entry a click landed on; the kernel applies the
// same clamped chain a shim click would run (restore-if-minimized, else
// focus + raise).
const wmctl_taskbar: u64 = 12;
// S6 Tab model (Milestone 19, issue #782)
const wmctl_attach_tab: u64 = 18;
const wmctl_detach_tab: u64 = 19;
const wmctl_activate_tab: u64 = 20;
// WM2 mission-control overview (Self-hosting Lane 1, issue #707 card 2):
// OVERVIEW (cmd 21) a0 = action (0 enter, 1 exit, 2 focus with a1 = id,
// 3 move with a1 = id and a2 = workspace). The WM decides grid policy from
// its kind-19/21 streams; the kernel applies + repaints. Zero new slots.
const wmctl_overview: u64 = 21;
const overview_enter_act: u64 = 0;
const overview_exit_act: u64 = 1;
const overview_focus_act: u64 = 2;
const overview_move_act: u64 = 3;
/// sys_clipboard_get (slot 39) — the WM probes the clipboard each tray
/// refresh (filled = return length != 0) to decide the indicator state.
const sys_clipboard_get: u64 = 39;
/// WMS7 (issue #627, Gate A): the app↔WM mailbox protocol rides the frozen
/// mailbox syscalls — sys_ipc_recv (slot 6) drains the WM's own request
/// inbox; sys_ipc_send (slot 5) returns the ack to the requester. No new
/// ABI; the mailbox.service loop below is EL0 policy.
const sys_ipc_recv: u64 = 6;
const sys_ipc_send: u64 = 5;

// ---------------------------------------------------------------------------
// Syscall wrappers (AArch64 `svc #0` — the fixed-register ABI).
// ---------------------------------------------------------------------------
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

fn syscall6(num: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
          [arg3] "{x3}" (arg3),
          [arg4] "{x4}" (arg4),
          [arg5] "{x5}" (arg5),
        : .{ .memory = true });
    return res;
}

/// Write a marker line to the serial console (fd 1) — the live gates' grep
/// targets. `msg` is a slice (in rodata/data).
fn write_marker(msg: []const u8) void {
    _ = syscall3(sys_write, 1, @intFromPtr(msg.ptr), msg.len);
}

/// The kernel event struct (same layout as events.Event — u16 kind, u16
/// flags, u32 seq, u32 arg0, u32 arg1; `sys_wait_event` fills it).
const Event = extern struct {
    kind: u16,
    flags: u16,
    seq: u32,
    arg0: u32,
    arg1: u32,
};

// ---------------------------------------------------------------------------
// Pinned markers + tuning (the live gates' grep targets — DO NOT change).
// ---------------------------------------------------------------------------

/// Written right after REGISTER returns 0 (proves the WM is live + seated).
pub const registered_marker: []const u8 = "wnd: registered\n";
/// Written every `marker_every` REQUEST_PRESENTs — the observable present
/// cadence (a marker per present would flood the serial over a long run).
pub const present_marker: []const u8 = "wnd: present\n";
/// Present every Nth COMPOSITE_TICK (its own cadence, not every tick).
/// Ticks are 1 Hz on VZ, so every 2 ticks = a present every 2 s.
pub const present_every: u32 = 2;
/// Write a present marker every Nth present. With cadence 2 s this bounds
/// serial volume to one line per present.
pub const marker_every: u32 = 1;
/// The kind-18 event the loop services (must match kernel events.COMPOSITE_TICK).
pub const composite_tick_kind: u64 = 18;

// WMS5 (issue #625): the event kinds the WM services — the raw pointer
// stream (19, WM_POINTER), the window-registry mirrors (20, WM_WINDOW), and
// the raw keyboard stream (21, WM_KEY, Gate 2). Pinned against kernel events
// (drift guard), like kind 18.
pub const wm_pointer_kind: u64 = 19;
pub const wm_window_kind: u64 = 20;
pub const wm_key_kind: u64 = 21;
/// Left-button bit inside the WM_POINTER `flags` byte (must match the HID
/// button byte the kernel fans out: 0x01 = left).
pub const btn_left: u8 = 0x01;
/// The title-bar drag markers — written on grab / move-while-held / drop.
/// The live gate greps these to prove the WM — not the kernel — moved the
/// window (the kernel's own geometry is gated off while a WM is registered).
pub const grab_marker: []const u8 = "wnd: grab\n";
pub const drag_marker: []const u8 = "wnd: drag\n";
pub const drop_marker: []const u8 = "wnd: drop\n";
/// M37 DQ5 (issue #837): the snap-preview decision marker prefix. The WM
/// prints the zone + bounds after it (`wnd: snap-preview zone=left
/// x=0 y=0 w=640 h=700`) so the live gate can prove the WM previewed the
/// exact rect the release then commits through the unchanged WMS5 path.
pub const snap_preview_marker: []const u8 = "wnd: snap-preview";
/// M37 DQ5 (issue #837): printed on every composite tick that redraws the
/// outline while a drag is held (at most ~1 Hz, bounded by the drag) — the
/// per-tick restore that keeps the outline on screen past repaints, and the
/// clock the settled marker counts.
pub const snap_tick_marker: []const u8 = "wnd: snap-tick\n";
/// M37 DQ5 (issue #837): printed once after eight continuous tick-restores
/// in the same zone (~8 s of held preview). The move's own SET_WINDOW
/// damage repaints the desktop over the move-time outline within
/// milliseconds, and shell output (e.g. a later `dui`) re-dirties it again —
/// so the gate snapshots after THIS marker (the clean window: restored and
/// stable), never right after the drag marker.
pub const snap_settled_marker: []const u8 = "wnd: snap-settled\n";
/// Ticks of continuous restore before the settled marker fires.
pub const snap_settled_ticks: u32 = 8;

// WMS5 Gate 2 (issue #625, claim 4278): the policy markers — one per
// geometry decision the WM issues over the seam. The live gate greps these
// to prove the WM — not the kernel — decided (the kernel's keyboard geometry
// consumers are gated off while a WM is registered).
pub const tile_marker: []const u8 = "wnd: tile\n";
pub const snap_marker: []const u8 = "wnd: snap\n";
pub const min_marker: []const u8 = "wnd: min\n";
pub const max_marker: []const u8 = "wnd: max\n";
pub const ws_marker: []const u8 = "wnd: ws\n";
pub const fs_marker: []const u8 = "wnd: fs\n";
pub const aot_marker: []const u8 = "wnd: aot\n";
// S6 Tab model (Milestone 19, issue #782)
pub const tab_attach_marker: []const u8 = "wnd: tab-attach";
pub const tab_detach_marker: []const u8 = "wnd: tab-detach";
pub const tab_activate_marker: []const u8 = "wnd: tab-activate";
pub const tab_cycle_marker: []const u8 = "wnd: tab-cycle";
/// M37 DQ3 (issue #839): press-dragged past the threshold — disambiguates
/// drag-detach from ×-detach in the gate (both end in `wnd: tab-detach`).
pub const tab_drag_marker: []const u8 = "wnd: tab-drag";
// S1/S5 Action registry seam (Milestone 19, issues #701, #705)
pub const action_reg_marker: []const u8 = "wnd: action-registered";
pub const action_inv_marker: []const u8 = "wnd: action-invoked";
// Issue #821 Phase 1: Global God Menu decision markers
pub const god_menu_open_marker: []const u8 = "wnd: god-menu open\n";
pub const god_menu_close_marker: []const u8 = "wnd: god-menu close\n";
pub const god_menu_exec_marker: []const u8 = "wnd: god-menu exec";

// WMS6 Gate A (issue #626): the Alt+Tab decision marker. The WM prints the
// target id after the pinned prefix (`wnd: alt-tab id=N`) so the live gate
// can prove the WM — not the kernel — picked the window that gets focus.
pub const alt_tab_marker: []const u8 = "wnd: alt-tab";

// WM2 mission-control overview (Self-hosting Lane 1, issue #707 card 2):
// the grid decision markers. The WM prints the card count after enter
// (`wnd: overview-enter n=N`), the target id after focus (`wnd:
// overview-focus id=N`), and id + workspace after a strip move (`wnd:
// overview-move id=N ws=M`); the live gate greps `wnd: overview-*` to
// prove the WM — not the kernel — made the grid decisions.
pub const overview_enter_marker: []const u8 = "wnd: overview-enter";
pub const overview_exit_marker: []const u8 = "wnd: overview-exit\n";
pub const overview_focus_marker: []const u8 = "wnd: overview-focus";
pub const overview_move_marker: []const u8 = "wnd: overview-move";

// WMS6 Gate B (issue #626): the notification-center decision markers — the
// WM opens/closes/clears/dismisses via NOTIF_CENTER/NOTIF_DISMISS. The live
// gate greps `wnd: notif` to prove the WM — not the kernel — decided.
pub const notif_open_marker: []const u8 = "wnd: notif-open\n";
pub const notif_close_marker: []const u8 = "wnd: notif-close\n";
pub const notif_clear_marker: []const u8 = "wnd: notif-clear\n";
pub const notif_dismiss_marker: []const u8 = "wnd: notif-dismiss\n";

// WMS6 Gate B: the tray region the WM hit-tests for a notification-center
// click — must mirror the kernel shim's tray_rect (fb_w - 80, taskbar row)
// so the injected click hits BOTH surfaces in the gate's two boots.
pub const tray_w: u32 = 80;

// WMS6 Gate C (issue #626): the tooltip decision markers — the WM shows /
// hides a tooltip via TOOLTIP (cmd 8). The live gate greps `wnd: tooltip`
// to prove the WM — not the kernel — decided what the hover shows.
pub const tooltip_show_marker: []const u8 = "wnd: tooltip\n";
pub const tooltip_hide_marker: []const u8 = "wnd: tooltip-hide\n";
/// The tooltip text the WM decides for a tray hover (rides ptr/len).
pub const tray_tooltip_text: []const u8 = "Clock";

// WMS6 Gate D (issue #626): the dock decision marker (the live gate greps
// `wnd: dock` to prove the WM — not the kernel — hit-tested the icon) and the
// icon hover labels the WM issues over the Gate-C TOOLTIP seam (the bar's
// glyphs are c n t b s — Calc, Notes, Terminal, Browser, Settings).
pub const dock_marker: []const u8 = "wnd: dock";
pub const dock_labels = [_][]const u8{ "Calc", "Notes", "Terminal", "Browser", "Settings" };

// WM3 (issue #707 card 3): the taskbar-entry decision marker (the live
// gate greps `wnd: taskbar` to prove the WM — not the kernel — hit-tested
// the entry and decided restore vs focus).
pub const taskbar_marker: []const u8 = "wnd: taskbar";

// WMS8 Gate 2 (issue #628): the about-dialog decision marker (the live gate
// greps `wnd: about` to prove the WM — not the kernel — decided Ctrl+Shift+A).
pub const about_marker: []const u8 = "wnd: about\n";

// WMS8 Gate 4 (issue #628): the unsaved-changes dialog decision markers — the
// live gate greps `wnd: unsaved-*` to prove the WM — not the kernel — decided
// when the dialog shows and which button applies.
pub const unsaved_dialog_marker: []const u8 = "wnd: unsaved-dialog\n";
pub const unsaved_save_marker: []const u8 = "wnd: unsaved-save\n";
pub const unsaved_discard_marker: []const u8 = "wnd: unsaved-discard\n";
pub const unsaved_cancel_marker: []const u8 = "wnd: unsaved-cancel\n";

/// WMS8 Gate 2 (issue #628): the about-dialog decision. Ctrl+Shift+A (kind
/// 21, usage 0x04) fans to the WM because it owns the keyboard stream; the WM
/// issues DIALOG (cmd 11) toggle — the SAME kernel primitive the shim's
/// Ctrl+Shift+A chord runs, so a WM decision and a shim chord are byte-
/// identical (parity by construction). The kernel blits the modal from its
/// own state.
fn toggle_about() void {
    _ = syscall6(sys_wmctl, wmctl_dialog, dialog_toggle_act, 0, 0, 0, 0);
    write_marker(about_marker);
}

/// WMS8 Gate 4 (issue #628): a dirty window's close button was clicked — the
/// WM, not the kernel, decides to show the unsaved-changes dialog (DIALOG 3,
/// target = the window id). The kernel applies its own `unsaved_dialog_show`.
fn show_unsaved_dialog(id: u8) void {
    _ = syscall6(sys_wmctl, wmctl_dialog, dialog_unsaved_show, id, 0, 0, 0);
    unsaved_dialog_open = true;
    write_marker(unsaved_dialog_marker);
}

/// WMS8 Gate 4 (issue #628): a dialog button was clicked — the WM decides the
/// choice and issues DIALOG 4/5/6; the kernel applies the SAME primitives the
/// shim's button click ran (parity by construction).
fn apply_unsaved_choice(choice: wnd_core.UnsavedChoice) void {
    switch (choice) {
        .save => {
            _ = syscall6(sys_wmctl, wmctl_dialog, dialog_unsaved_save, 0, 0, 0, 0);
            write_marker(unsaved_save_marker);
        },
        .dont_save => {
            _ = syscall6(sys_wmctl, wmctl_dialog, dialog_unsaved_dont_save, 0, 0, 0, 0);
            write_marker(unsaved_discard_marker);
        },
        .cancel => {
            _ = syscall6(sys_wmctl, wmctl_dialog, dialog_unsaved_cancel, 0, 0, 0, 0);
            write_marker(unsaved_cancel_marker);
        },
        .none => return,
    }
    unsaved_dialog_open = false;
}

// WMS6 Gate E (issue #626): the tray decision marker — written when the WM
// issues TRAY with CHANGED content (`wnd: tray clock=HH:MM theme=D
// clip=yes/no`). The live gate greps it to prove the WM — not the kernel —
// owns the tray widgets (the kernel render is source-selected off the
// WM-declared values once set).
pub const tray_marker: []const u8 = "wnd: tray";
/// The theme letter the WM declares — the WM is the theme owner; parity
/// with the shim's default 'D' (the kernel clamps to D/L/A).
pub const tray_theme_letter: u8 = 'D';
/// The tray refresh cadence: re-decide the widget content every Nth
/// COMPOSITE_TICK (kind-18 ticks are 1 Hz on VZ = seconds). The clock
/// REFRESHES under the WM — it was frozen while a WM was registered (the
/// kernel's drain is gated off), the exact gap this gate closes.
pub const tray_refresh_every: u64 = 10;
/// The clipboard probe buffer the WM reads each refresh (filled = returned
/// length != 0). The kernel clamps to its capacity.
pub const tray_clip_probe: usize = 32;

// WMS7 Gate A (issue #627): the app↔WM mailbox protocol marker — written per
// applied request (`wnd: mail kind=N id=M seq=S applied=yes|no title=..`).
// The live gate greps it to prove the WM SERVED a mail request (the app asked
// the WM, not the kernel, over the mailbox).
pub const mail_marker: []const u8 = "wnd: mail";
/// The 64-B mailbox slot bound the WM_RPC message must fit (wnd_core owns it).
pub const mail_inbox_max: usize = wnd_core.wm_rpc_max;

// ADR 0009 modifier bits (must match kernel events MOD_*).
pub const mod_shift: u16 = 0x0001;
pub const mod_ctrl: u16 = 0x0002;
pub const mod_alt: u16 = 0x0004;

// HID keyboard usages for the chords the WM owns (must match the usages
// input.zig decodes: Ctrl+T tile, Ctrl+M master-swap, Ctrl+N minimize,
// Ctrl+Shift+M maximize, Ctrl+Shift+T always-on-top, Ctrl+F1-3 workspace
// switch, Alt+` workspace cycle, F11 fullscreen, Ctrl+F12 overview).
// NOTE (WM2): kind-21 carries the RAW USB HID usage byte (input.zig fans
// rep[2..8] untranslated), so F12 is the HID value 0x45.
pub const usage_t: u8 = 0x17;
pub const usage_m: u8 = 0x10;
pub const usage_n: u8 = 0x11;
pub const usage_f1: u8 = 0x58;
pub const usage_f2: u8 = 0x59;
pub const usage_f3: u8 = 0x5a;
pub const usage_backtick: u8 = 0x35;
pub const usage_f11: u8 = 0x5c;
pub const usage_f12: u8 = 0x45; // WM2 (issue #707 card 2): USB HID F12 — the overview hotkey with Ctrl
pub const usage_esc: u8 = 0x29; // WM2: Esc exits the overview grid
pub const usage_tab: u8 = 0x2b;
pub const usage_w: u8 = 0x1a; // S6 Tab model: Ctrl+W closes/detaches tab
pub const usage_a: u8 = 0x04; // M27 G2 / WMS8 Gate 2: Ctrl+Shift+A toggles the about dialog
pub const usage_space: u8 = 0x2c; // Issue #821: Ctrl+Space toggles Sexiburger God Menu

pub fn hid_to_ascii(usage: u8, shift: bool) ?u8 {
    if (usage >= 0x04 and usage <= 0x1d) {
        return if (shift) 'A' + (usage - 0x04) else 'a' + (usage - 0x04);
    }
    if (usage >= 0x1e and usage <= 0x27) {
        const unshifted = "1234567890";
        const shifted = "!@#$%^&*()";
        const i = usage - 0x1e;
        return if (shift) shifted[i] else unshifted[i];
    }
    return switch (usage) {
        0x28 => '\n',
        0x2a => 0x08,
        0x2b => '\t',
        0x2c => ' ',
        0x2d => if (shift) '_' else '-',
        0x2e => if (shift) '+' else '=',
        0x2f => if (shift) '{' else '[',
        0x30 => if (shift) '}' else ']',
        0x31 => if (shift) '|' else '\\',
        0x33 => if (shift) ':' else ';',
        0x34 => if (shift) '"' else '\'',
        0x35 => if (shift) '~' else '`',
        0x36 => if (shift) '<' else ',',
        0x37 => if (shift) '>' else '.',
        0x38 => if (shift) '?' else '/',
        else => null,
    };
}

// WMS4 (issue #624): the EXACT values the chrome-descriptor blob embeds.
// Pinned against the shared wnd_core parity policy below, so the EL0 blob
// cannot drift from the kernel's expectation without a test failure.
pub const policy_kind: u32 = 0x7f;
pub const policy_flags: u32 = 0x01;
pub const policy_border_rgb: u32 = 0x0c1826;
pub const policy_border_unfocus_rgb: u32 = 0x475569;
pub const policy_title_bg_rgb: u32 = 0x1a2b3c;
pub const policy_title_fg_rgb: u32 = 0xffffff;
pub const policy_ring_rgb: u32 = 0x3b82f6;
pub const policy_close_rgb: u32 = 0xef4444;
pub const policy_min_rgb: u32 = 0x94a3b8;
pub const policy_pin_rgb: u32 = 0x38bdf8;

// ---------------------------------------------------------------------------
// The WM's own policy state (WMS5 Gate 2 — what the kernel used to own).
// ---------------------------------------------------------------------------

/// The one mirrored user window the WM tracks (the live gates open exactly
/// one window — NOTEPAD — so the WMS5 asm kept one slot; policy extends it
/// to the full user-window range 2..9 with a per-id table).
/// WM2 (issue #707 card 2): the kernel ceiling is 8 (WM1, PR #922), so the
/// WM-side policy sees all eight kernel windows.
const max_user_windows: usize = 8;

const MirrorWin = struct {
    id: u8 = 0,
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    visible: bool = false,
    focused: bool = false,
    workspace: u8 = 0,
    // S6 Tab model (Milestone 19, issue #782)
    tab_parent: u8 = 0,
    tab_active: bool = true,
    // WMS8 Gate 4 (issue #628): the kernel's dirty flag, carried by the
    // kind-20 mirror (bit 12) — the WM's unsaved-dialog decision input.
    unsaved: bool = false,
    valid: bool = false,
    // Gate 2 policy state: the WM's own copies of what the kernel shim
    // tracked (tile slots, snap-restore rect, pre-max/pre-fs rects).
    minimized: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    always_on_top: bool = false,
    pre_max_x: u32 = 0,
    pre_max_y: u32 = 0,
    pre_max_w: u32 = 0,
    pre_max_h: u32 = 0,
    snap_last_x: u32 = 0,
    snap_last_y: u32 = 0,
    snap_last_w: u32 = 0,
    snap_last_h: u32 = 0,
    snapped: bool = false,
    snap_valid: bool = false,
};

/// The mirror table (id 2..9 -> slots 0..7).
var mirrors: [max_user_windows]MirrorWin = @as([max_user_windows]MirrorWin, @splat(@as(MirrorWin, .{})));
// WMS8 Gate 4 (issue #628): the unsaved-changes dialog open state the WM
// tracks to route dialog-button clicks (the kernel's open state is the
// applied truth; this is the WM's decision-side mirror).
var unsaved_dialog_open: bool = false;
var current_workspace: u8 = 0;
var tile_mode: bool = false;
var tile_master_id: u8 = 0xff;
var tile_stack_id: u8 = 0xff;
var tile_master_side: bool = true;

fn mirror_slot(id: u8) ?usize {
    if (id < 2 or id > 9) return null;
    return id - 2;
}

fn mirror(id: u8) ?*MirrorWin {
    const s = mirror_slot(id) orelse return null;
    return &mirrors[s];
}

fn focused_mirror() ?*MirrorWin {
    for (&mirrors) |*m| {
        if (m.valid and m.focused) return m;
    }
    return null;
}

/// The scanout dimensions the WM computes rects from (the fixed 1280x720
/// scanout; single-sourced in wnd_core so the WM and kernel agree).
const fb_w = wnd_core.fb_w;
const fb_h = wnd_core.fb_h;
const taskbar_h = wnd_core.taskbar_h;
const dock_w = wnd_core.dock_w;
/// WM3 (issue #707 card 3): the workspace count the taskbar entry layout
/// enumerates against (the kernel's `workspace_max` — mirrored here since
/// the WM computes the entry rects from the shared wnd_core rule).
const taskbar_ws_count: u32 = 3;

// ---------------------------------------------------------------------------
// Issue #825 (IMG4): Desktop Wallpaper via Scanout Compositing
// ---------------------------------------------------------------------------

const m33_surf_scan_tag: u64 = 0x4000_0000_0000_0000;
const prot_rw: u64 = 0x3;
const map_anonymous: u64 = 0x20;
const m33_map_shared: u64 = 0x10000;

pub const wallpaper_loaded_marker: []const u8 = "wnd: wallpaper loaded\n";
pub const wallpaper_present_marker: []const u8 = "wnd: wallpaper present\n";

var wallpaper_loaded: bool = false;
var wallpaper_bg_buf: ?[*]u32 = null;
var scanout_ptr: ?[*]u32 = null;
var scanout_mapped: bool = false;

const max_wallpaper_file_bytes: usize = 96 * 1024;
var wallpaper_file_buf: [max_wallpaper_file_bytes]u8 = undefined;

/// Probe `/host/WALLPAPER.QOI` (falling back to `/host/WALLPAPER.PNG`). If present,
/// decode and scale the image to 1280x720 and bind the scanout surface.
pub fn init_wallpaper_if_present() void {
    var fd = ui.file_open("/host/WALLPAPER.QOI", ui.MODE_READ);
    if (fd < 0) {
        fd = ui.file_open("/host/WALLPAPER.PNG", ui.MODE_READ);
    }
    if (fd < 0) {
        write_marker("wnd: no wallpaper file\n");
        return;
    }
    write_marker("wnd: wallpaper file opened\n");

    const handle: u32 = @intCast(fd);
    defer ui.file_close(handle);

    var file_len: usize = 0;
    while (file_len < max_wallpaper_file_bytes) {
        const chunk = ui.file_read(handle, wallpaper_file_buf[file_len..]);
        if (chunk <= 0) break;
        file_len += @intCast(chunk);
    }
    if (file_len == 0) {
        write_marker("wnd: wallpaper read fail\n");
        return;
    }

    // 2. Map decode buffer (up to full frame pixels)
    const fb_len: u64 = @as(u64, fb_w) * fb_h * 4;
    const decode_va = ui.syscall4(ui.sys_mmap_num, 0, fb_len, prot_rw, map_anonymous);
    if (decode_va <= 0) {
        write_marker("wnd: wallpaper mmap decode fail\n");
        return;
    }
    const decode_buf: [*]align(1) u32 = @ptrFromInt(@as(usize, @intCast(decode_va)));

    // Decode QOI format (native desktop wallpaper format)
    const qoi_hdr = ui.image.qoi.decode(wallpaper_file_buf[0..file_len], decode_buf[0..(@as(usize, fb_w) * fb_h)]) catch {
        write_marker("wnd: wallpaper decode fail\n");
        return;
    };
    const decoded = ui.image.Image{
        .width = qoi_hdr.width,
        .height = qoi_hdr.height,
        .pixels = decode_buf[0..(@as(usize, qoi_hdr.width) * qoi_hdr.height)],
    };

    // 3. Map full 1280x720 background buffer
    const bg_va = ui.syscall4(ui.sys_mmap_num, 0, fb_len, prot_rw, map_anonymous);
    if (bg_va <= 0) {
        write_marker("wnd: wallpaper mmap bg fail\n");
        return;
    }
    const bg_pixels: [*]u32 = @ptrFromInt(@as(usize, @intCast(bg_va)));

    // Scale to screen dimensions using nearest-neighbor
    var dy: u32 = 0;
    while (dy < fb_h) : (dy += 1) {
        const sy = (dy * decoded.height) / fb_h;
        var dx: u32 = 0;
        while (dx < fb_w) : (dx += 1) {
            const sx = (dx * decoded.width) / fb_w;
            const px_ptr = decoded.pixel_at(sx, sy);
            bg_pixels[dy * fb_w + dx] = if (px_ptr) |p| p.* else 0xFF1E1E2E;
        }
    }

    // 4. Map the scanout surface
    if (!scanout_mapped) {
        const scan_va = ui.syscall4(ui.sys_mmap_num, m33_surf_scan_tag, fb_len, prot_rw, map_anonymous | m33_map_shared);
        if (scan_va > 0) {
            scanout_ptr = @ptrFromInt(@as(usize, @intCast(scan_va)));
            scanout_mapped = true;
        } else {
            write_marker("wnd: wallpaper scanout map fail\n");
        }
    }

    if (scanout_mapped) {
        wallpaper_bg_buf = bg_pixels;
        wallpaper_loaded = true;
        write_marker(wallpaper_loaded_marker);
    }
}

/// Blit the scaled wallpaper pixels to the scanout surface, preserving dock,
/// taskbar, and all visible interactive windows.
pub fn render_wallpaper_root() void {
    const bg = wallpaper_bg_buf orelse return;
    const scan = scanout_ptr orelse return;

    const max_y = fb_h - taskbar_h;
    var y: u32 = 0;
    while (y < max_y) : (y += 1) {
        const row_off = y * fb_w;
        var x: u32 = dock_w;
        while (x < fb_w) : (x += 1) {
            // Check occlusion by visible windows
            var occluded = false;
            for (mirrors) |m| {
                if (m.valid and m.visible and !m.minimized) {
                    if (x >= m.x and x < m.x + m.w and y >= m.y and y < m.y + m.h) {
                        occluded = true;
                        break;
                    }
                }
            }
            if (!occluded and god_menu_open) {
                const menu_x = if (fb_w > god_menu_w) (fb_w - god_menu_w) / 2 else 0;
                const menu_y = if (fb_h > god_menu_h) (fb_h - god_menu_h) / 2 else 0;
                if (x >= menu_x and x < menu_x + god_menu_w and y >= menu_y and y < menu_y + god_menu_h) {
                    occluded = true;
                }
            }
            if (!occluded) {
                scan[row_off + x] = bg[row_off + x];
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Issue #821 Phase 1: Global Sexiburger God Menu Overlay & Action Dispatch
// ---------------------------------------------------------------------------

pub const AppAction = struct {
    owner_id: u8 = 0,
    section: u8 = 2,
    label: [32]u8 = @as([32]u8, @splat(@as(u8, 0))),
    label_len: usize = 0,
    verb: [24]u8 = @as([24]u8, @splat(@as(u8, 0))),
    verb_len: usize = 0,
};

var app_actions: [8]AppAction = @as([8]AppAction, @splat(@as(AppAction, .{})));
var app_actions_count: usize = 0;

pub const god_menu_w: u32 = 488;
pub const god_menu_h: u32 = 316;

pub var god_menu: SexiburgerMenu = undefined;
pub var god_menu_initialized: bool = false;
pub var god_menu_win: ?u32 = null;
pub var god_menu_open: bool = false;
var god_menu_mascot_pixels: [24 * 24]u32 = undefined;
var god_menu_mascot_loaded: bool = false;
var god_menu_prev_focus: u8 = 0;
const mascot_qoi_bytes = @embedFile("lib/fixtures/qoi/mascot_24x24.qoi");

// ---------------------------------------------------------------------------
// M37 DQ1 (issue #836): dynamic apps section from the APPS.TXT manifest
// ---------------------------------------------------------------------------
// Same wire format `desktop.zig:parse_manifest` reads (M34/HF4 share,
// `NAME.BIN | Display Name | ...`); parsed by the menu-owned
// `sexiburger.parse_apps_manifest`. Registry commands borrow slices of
// these static buffers, which outlive every populate (the registry is
// rebuilt from them each summon). Lengths mirror action_registry caps
// (label 32 / verb 24); bin names cap at 16 (`NOTEPAD.BIN` is 11).
/// M82a (#1768): the read budget is the manifest parser's, not a private copy
/// of the number. A manifest longer than this buffer is cut at the last whole
/// line, so the tail rows stop existing in this menu with no error at all.
pub const god_menu_manifest_max: usize = sexiburger.manifest_buf_max;

var god_menu_manifest_buf: [god_menu_manifest_max]u8 = undefined;
var god_menu_app_verbs: [sexiburger.menu_apps_max][24]u8 = @as([sexiburger.menu_apps_max][24]u8, @splat(@as([24]u8, @as([24]u8, @splat(@as(u8, 0))))));
var god_menu_app_verb_lens: [sexiburger.menu_apps_max]usize = @as([sexiburger.menu_apps_max]usize, @splat(@as(usize, 0)));
var god_menu_app_bins: [sexiburger.menu_apps_max][16]u8 = @as([sexiburger.menu_apps_max][16]u8, @splat(@as([16]u8, @as([16]u8, @splat(@as(u8, 0))))));
var god_menu_app_bin_lens: [sexiburger.menu_apps_max]usize = @as([sexiburger.menu_apps_max]usize, @splat(@as(usize, 0)));
var god_menu_app_labels: [sexiburger.menu_apps_max][32]u8 = @as([sexiburger.menu_apps_max][32]u8, @splat(@as([32]u8, @as([32]u8, @splat(@as(u8, 0))))));
var god_menu_app_label_lens: [sexiburger.menu_apps_max]usize = @as([sexiburger.menu_apps_max]usize, @splat(@as(usize, 0)));
var god_menu_app_count: usize = 0;

/// Lowercase stem of `NOTEPAD.BIN` → `notepad`: the verb shape Phase 1
/// pinned (the `calc` filter test). Stops at `.`, truncates to `out.len`.
pub fn app_verb_for(name: []const u8, out: []u8) usize {
    var n: usize = 0;
    for (name) |c| {
        if (c == '.') break;
        if (n >= out.len) break;
        out[n] = std.ascii.toLower(c);
        n += 1;
    }
    return n;
}

/// Bin filename behind an app verb (`gocalc` → `GOCALC.ELF`), or null when the
/// manifest yielded nothing (host tests) or the verb is unknown.
pub fn god_menu_bin_for(verb: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < god_menu_app_count) : (i += 1) {
        if (std.mem.eql(u8, verb, god_menu_app_verbs[i][0..god_menu_app_verb_lens[i]])) {
            return god_menu_app_bins[i][0..god_menu_app_bin_lens[i]];
        }
    }
    return null;
}

/// (Re)load the apps catalog from `APPS.TXT` (M34/HF4 share manifest —
/// same path `desktop.zig:load_manifest` reads). Freestanding-only: host
/// unit tests keep the hardcoded fallback. Dock entries first (most
/// relevant), then manifest order, capped at `menu_apps_max`; duplicate
/// stems dropped (first wins). Returns the loaded count — 0 means the
/// caller falls back to the hardcoded four.
pub fn load_god_menu_apps() usize {
    god_menu_app_count = 0;
    if (@import("builtin").os.tag != .freestanding) return 0;
    const fd = ui.file_open("APPS.TXT", ui.MODE_READ);
    if (fd < 0) return 0;
    defer ui.file_close(@intCast(fd));
    const n = ui.file_read(@intCast(fd), &god_menu_manifest_buf);
    if (n <= 0) return 0;
    // Parse room for the whole manifest (desktop's manifest_max_apps): the
    // registry cap (menu_apps_max) applies at SELECTION (dock-first below),
    // not at parse — capping the parse would silently drop dock entries
    // past the cutoff (observed live: apps=14 with a 22-entry manifest).
    var parsed: [24]sexiburger.MenuApp = undefined;
    const parsed_n = sexiburger.parse_apps_manifest(god_menu_manifest_buf[0..@intCast(n)], &parsed);
    return select_god_menu_apps(parsed[0..parsed_n]);
}

/// Select up to `menu_apps_max` entries from a parsed manifest into the
/// static verb/bin/label tables (dock-first, duplicate stems dropped).
/// Pure over its input — host-testable; the file read stays in the caller.
pub fn select_god_menu_apps(parsed: []const sexiburger.MenuApp) usize {
    god_menu_app_count = 0;
    var pass: usize = 0;
    while (pass < 2) : (pass += 1) {
        var i: usize = 0;
        while (i < parsed.len and god_menu_app_count < sexiburger.menu_apps_max) : (i += 1) {
            if (parsed[i].dock != (pass == 0)) continue;
            var stem: [24]u8 = undefined;
            const stem_len = app_verb_for(parsed[i].name, &stem);
            if (stem_len == 0) continue;
            if (god_menu_bin_for(stem[0..stem_len]) != null) continue;
            const idx = god_menu_app_count;
            @memcpy(god_menu_app_verbs[idx][0..stem_len], stem[0..stem_len]);
            const bin_len = @min(parsed[i].name.len, god_menu_app_bins[idx].len);
            @memcpy(god_menu_app_bins[idx][0..bin_len], parsed[i].name[0..bin_len]);
            const label_len = @min(parsed[i].desc.len, god_menu_app_labels[idx].len);
            @memcpy(god_menu_app_labels[idx][0..label_len], parsed[i].desc[0..label_len]);
            god_menu_app_verb_lens[idx] = stem_len;
            god_menu_app_bin_lens[idx] = bin_len;
            god_menu_app_label_lens[idx] = label_len;
            god_menu_app_count += 1;
        }
    }
    return god_menu_app_count;
}

// ---------------------------------------------------------------------------
// M37 DQ1 slices 2–3 (issue #836): real theme toggle + full win/tab entries
// ---------------------------------------------------------------------------
// Theme: WND owns the desktop mode flag (default dark = ui.current_theme's
// default) and flips `ui.set_theme` so every widget drawn after the toggle
// reads the new tokens. Windows/tabs: per-mirror entries borrowed from
// static buffers (the old loop-local `wbuf`/`vbuf` slices dangled past
// their iteration — these outlive every populate).

var god_menu_dark: bool = true;

var god_menu_win_labels: [max_user_windows][32]u8 = @as([max_user_windows][32]u8, @splat(@as([32]u8, @as([32]u8, @splat(@as(u8, 0))))));
var god_menu_win_label_lens: [max_user_windows]usize = @as([max_user_windows]usize, @splat(@as(usize, 0)));
var god_menu_win_verbs: [max_user_windows][8]u8 = @as([max_user_windows][8]u8, @splat(@as([8]u8, @as([8]u8, @splat(@as(u8, 0))))));
var god_menu_win_verb_lens: [max_user_windows]usize = @as([max_user_windows]usize, @splat(@as(usize, 0)));

/// Flip the desktop theme; returns the new mode name. The `set_theme` call
/// + repaint are freestanding-only (host tests assert the flag flip).
pub fn toggle_god_menu_theme() []const u8 {
    god_menu_dark = !god_menu_dark;
    if (@import("builtin").os.tag == .freestanding) {
        _ = ui.set_theme(if (god_menu_dark) "dark" else "light");
        redraw_god_menu();
    }
    return if (god_menu_dark) "dark" else "light";
}

/// Hand-rolled label builders for win/tab entries (static buffers, no
/// stack formatting — the slices must outlive populate).
fn append_win_text(buf: []u8, pos: usize, s: []const u8) usize {
    const n = @min(s.len, buf.len -| pos);
    @memcpy(buf[pos .. pos + n], s[0..n]);
    return pos + n;
}

fn append_win_num(buf: []u8, pos: usize, v: u8) usize {
    var tmp: [3]u8 = undefined;
    var len: usize = 0;
    var x = v;
    if (x == 0) {
        tmp[0] = '0';
        len = 1;
    } else {
        var rev: [3]u8 = undefined;
        var rlen: usize = 0;
        while (x > 0) : (rlen += 1) {
            rev[rlen] = '0' + (x % 10);
            x /= 10;
        }
        while (rlen > 0) : (rlen -= 1) {
            tmp[len] = rev[rlen - 1];
            len += 1;
        }
    }
    return append_win_text(buf, pos, tmp[0..len]);
}

/// Decimal id after a `win-`/`tab-` prefix, range-checked to mirror ids
/// 2..9. Pure and host-testable.
pub fn parse_id_suffix(verb: []const u8, prefix: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, verb, prefix)) return null;
    const digits = verb[prefix.len..];
    if (digits.len == 0 or digits.len > 3) return null;
    var id: u16 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
        id = id * 10 + (c - '0');
    }
    if (id < 2 or id > 9) return null;
    return @intCast(id);
}

// ---------------------------------------------------------------------------
// M37 DQ3 (issue #839) — tab-strip mouse interaction. Hit-testing is pure
// over the mirrors (host-testable); dispatch rides the existing
// activate_tab / detach_tab fns. The shared wnd_core geometry (the SAME
// rule the kernel paints) keeps pixels and clicks from drifting.
// ---------------------------------------------------------------------------

/// A pressed tab cell: which tab, and whether the press landed on ×.
pub const TabHit = struct {
    container_id: u8,
    tab_id: u8,
    on_close: bool,
};

/// Hit-test a point against every visible tab strip, top-down (reverse id
/// order == top of the stack, mirroring the close-button scan). A strip
/// exists ONLY on containers (tab_parent == 0) with ≥1 attached child —
/// plain windows keep every client click. Returns null on miss.
pub fn tab_hit_at(px: u32, py: u32) ?TabHit {
    var si: usize = max_user_windows;
    while (si > 0) {
        si -= 1;
        const m = &mirrors[si];
        if (!m.valid or !m.visible or m.tab_parent != 0) continue;
        // Attached children?
        var has_child = false;
        for (&mirrors) |*c| {
            if (c.valid and c.tab_parent == m.id) {
                has_child = true;
                break;
            }
        }
        if (!has_child) continue;
        const strip = wnd_core.tab_strip_rect(m.x, m.y, m.w);
        if (!wnd_core.tab_rect_contains(strip, px, py)) continue;
        // Rebuild the group (container first, then children in order) and
        // find the pressed cell.
        var group: [max_user_windows + 1]u8 = undefined;
        var gcount: usize = 0;
        group[0] = m.id;
        gcount = 1;
        for (&mirrors) |*c| {
            if (c.valid and c.tab_parent == m.id and gcount < group.len) {
                group[gcount] = c.id;
                gcount += 1;
            }
        }
        var gi: usize = 0;
        while (gi < gcount) : (gi += 1) {
            const cell = wnd_core.tab_item_rect(strip.x, strip.y, strip.w, gi, gcount);
            if (cell.w == 0) continue;
            if (!wnd_core.tab_rect_contains(cell, px, py)) continue;
            const cb = wnd_core.tab_close_rect(cell);
            return TabHit{
                .container_id = m.id,
                .tab_id = group[gi],
                .on_close = wnd_core.tab_rect_contains(cb, px, py),
            };
        }
        return null; // inside the strip but past the last cell (narrow clip)
    }
    return null;
}

/// Drag threshold (Chebyshev > 12px) — press becomes a detach-drag. Pure.
pub fn tab_drag_exceeded(x0: u32, y0: u32, x1: u32, y1: u32) bool {
    const dx = if (x1 > x0) x1 - x0 else x0 - x1;
    const dy = if (y1 > y0) y1 - y0 else y0 - y1;
    return @max(dx, dy) > 12;
}

// Press state (a strip press in progress). Cleared on release and whenever
// the god menu opens (modal capture would strand it).
var tab_press_id: ?u8 = null;
var tab_press_close: bool = false;
var tab_press_x: u32 = 0;
var tab_press_y: u32 = 0;
var tab_dragging: bool = false;

fn tab_press_clear() void {
    tab_press_id = null;
    tab_press_close = false;
    tab_dragging = false;
}

pub fn init_god_menu_if_needed() void {
    if (!god_menu_initialized) {
        god_menu = SexiburgerMenu.init(Rect.make(0, 0, god_menu_w, god_menu_h));
        if (!god_menu_mascot_loaded) {
            const decoded = ui.image.qoi.decode(mascot_qoi_bytes, &god_menu_mascot_pixels) catch null;
            if (decoded) |qhdr| {
                god_menu.raster_mascot = ui.image.Image{
                    .width = qhdr.width,
                    .height = qhdr.height,
                    .pixels = &god_menu_mascot_pixels,
                };
                god_menu_mascot_loaded = true;
            }
        }
        god_menu_initialized = true;
    }
}

pub fn populate_god_menu() void {
    init_god_menu_if_needed();
    god_menu.registry = ActionRegistry.init_empty();

    // 1. System (Top Bun / Crown)
    _ = god_menu.registry.register_command(.system, "About VirelaiOS", "Ctrl+Shift+A", "about", null) catch {};
    _ = god_menu.registry.register_command(.system, "System Monitor", "Ctrl+Esc", "top", null) catch {};
    _ = god_menu.registry.register_command(.system, "Settings Panel", "Ctrl+,", "settings", null) catch {};
    _ = god_menu.registry.register_command(.system, "Reboot System", "", "reboot", null) catch {};
    _ = god_menu.registry.register_command(.system, "Power Off", "", "shutdown", null) catch {};

    // 2. Apps — dynamic APPS.TXT catalog (DQ1 #836); the hardcoded four
    // survive only as the fallback (host tests, missing manifest).
    // Preloaded at startup and refreshed per summon (issue #846).
    const app_count = load_god_menu_apps();
    {
        var abuf: [32]u8 = undefined;
        const amsg = std.fmt.bufPrint(&abuf, "wnd: god-menu apps={d}\n", .{app_count}) catch "wnd: god-menu apps\n";
        write_marker(amsg);
    }
    if (app_count > 0) {
        var ai: usize = 0;
        while (ai < god_menu_app_count) : (ai += 1) {
            _ = god_menu.registry.register_command(
                .apps,
                god_menu_app_labels[ai][0..god_menu_app_label_lens[ai]],
                "",
                god_menu_app_verbs[ai][0..god_menu_app_verb_lens[ai]],
                null,
            ) catch {};
        }
    } else {
        _ = god_menu.registry.register_command(.apps, "Text Editor", "Ctrl+Alt+E", "notepad", null) catch {};
        _ = god_menu.registry.register_command(.apps, "Calculator", "Ctrl+Alt+C", "calc", null) catch {};
        _ = god_menu.registry.register_command(.apps, "File Browser", "Ctrl+Alt+F", "file", null) catch {};
        _ = god_menu.registry.register_command(.apps, "Terminal (Road Pops)", "Ctrl+Alt+T", "devcons", null) catch {};
    }

    // 3. Active App (Tomato) - Live actions from focused app via mailbox seam
    var active_count: usize = 0;
    for (app_actions[0..app_actions_count]) |act| {
        if (act.label_len > 0) {
            _ = god_menu.registry.register_command(
                .active_app,
                act.label[0..act.label_len],
                "",
                act.verb[0..act.verb_len],
                null,
            ) catch {};
            active_count += 1;
        }
    }
    if (active_count == 0) {
        _ = god_menu.registry.register_command(.active_app, "Save Document", "Ctrl+S", "save", null) catch {};
        _ = god_menu.registry.register_command(.active_app, "Find in Document", "Ctrl+F", "find", null) catch {};
    }

    // 4. Windows & tabs — one entry per visible mirror (DQ1 #836):
    // standalone windows focus via `win-N`, attached tabs activate via
    // `tab-N` (parent shown). Tab verbs always registered — they now work.
    var win_count_added: usize = 0;
    for (mirrors, 0..) |m, slot| {
        if (!m.valid or !m.visible) continue;
        var lpos: usize = 0;
        var vpos: usize = 0;
        if (m.tab_parent == 0) {
            lpos = append_win_text(&god_menu_win_labels[slot], lpos, "Window ");
            lpos = append_win_num(&god_menu_win_labels[slot], lpos, m.id);
            if (m.focused) lpos = append_win_text(&god_menu_win_labels[slot], lpos, " *");
            vpos = append_win_text(&god_menu_win_verbs[slot], vpos, "win-");
            vpos = append_win_num(&god_menu_win_verbs[slot], vpos, m.id);
        } else {
            lpos = append_win_text(&god_menu_win_labels[slot], lpos, "Tab ");
            lpos = append_win_num(&god_menu_win_labels[slot], lpos, m.id);
            lpos = append_win_text(&god_menu_win_labels[slot], lpos, " (in ");
            lpos = append_win_num(&god_menu_win_labels[slot], lpos, m.tab_parent);
            lpos = append_win_text(&god_menu_win_labels[slot], lpos, ")");
            if (m.tab_active) lpos = append_win_text(&god_menu_win_labels[slot], lpos, " *");
            vpos = append_win_text(&god_menu_win_verbs[slot], vpos, "tab-");
            vpos = append_win_num(&god_menu_win_verbs[slot], vpos, m.id);
        }
        god_menu_win_label_lens[slot] = lpos;
        god_menu_win_verb_lens[slot] = vpos;
        _ = god_menu.registry.register_command(
            .windows_tabs,
            god_menu_win_labels[slot][0..lpos],
            "",
            god_menu_win_verbs[slot][0..vpos],
            null,
        ) catch {};
        win_count_added += 1;
    }
    _ = god_menu.registry.register_command(.windows_tabs, "Next Tab", "Ctrl+Tab", "tab-next", null) catch {};
    _ = god_menu.registry.register_command(.windows_tabs, "Close Tab", "Ctrl+W", "tab-close", null) catch {};
    if (win_count_added == 0) {
        _ = god_menu.registry.register_command(.windows_tabs, "New Tab", "Ctrl+T", "tab-new", null) catch {};
    }

    // 5. Services (Patty) - Quick tools / services
    _ = god_menu.registry.register_command(.services, "Toggle Theme (Light/Dark)", "Ctrl+Shift+L", "theme", null) catch {};
    _ = god_menu.registry.register_command(.services, "Notifications Panel", "", "notify", null) catch {};
    _ = god_menu.registry.register_command(.services, "Clipboard History", "Ctrl+Shift+V", "clipboard", null) catch {};

    // 6. Power / Mascot (Heel Bun)
    _ = god_menu.registry.register_command(.power, "Sexipus Mascot Diagnostics", "", "sexiburger", null) catch {};
    _ = god_menu.registry.register_command(.power, "Cascade Windows", "Alt+C", "cascade", null) catch {};

    god_menu.clear_search();
}

pub fn redraw_god_menu() void {
    if (god_menu_win) |wid| {
        god_menu.draw(wid);
        ui.win_present(wid);
    }
}

pub fn execute_god_menu_command(cmd: Command) void {
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} verb={s} label={s}\n", .{ god_menu_exec_marker, cmd.verb, cmd.label }) catch "wnd: god-menu exec\n";
    write_marker(msg);

    if (std.mem.eql(u8, cmd.verb, "about")) {
        toggle_about();
    } else if (std.mem.eql(u8, cmd.verb, "theme")) {
        const mode = toggle_god_menu_theme();
        var tbuf: [40]u8 = undefined;
        const tmsg = std.fmt.bufPrint(&tbuf, "wnd: theme toggled {s}\n", .{mode}) catch "wnd: theme toggled\n";
        write_marker(tmsg);
    } else if (god_menu_bin_for(cmd.verb)) |bin| {
        // DQ1 dynamic app (or a fallback verb matching a loaded entry).
        _ = ui.exec_program(bin);
    } else if (std.mem.eql(u8, cmd.verb, "notepad")) {
        // M66c (#1485): the Zig app is retired; the fallback verb runs its Go
        // successor. Manifest-driven verbs (the normal path) come from APPS.TXT.
        _ = ui.exec_program("NOTE.ELF");
    } else if (std.mem.eql(u8, cmd.verb, "calc")) {
        _ = ui.exec_program("GOCALC.ELF");
    } else if (std.mem.eql(u8, cmd.verb, "file")) {
        _ = ui.exec_program("FILE.BIN");
    } else if (std.mem.eql(u8, cmd.verb, "top")) {
        _ = ui.exec_program("TOP.BIN");
    } else if (std.mem.eql(u8, cmd.verb, "devcons")) {
        _ = ui.exec_program("DEVCONS.BIN");
    } else if (std.mem.eql(u8, cmd.verb, "notify")) {
        _ = syscall6(sys_wmctl, wmctl_notif_center, notif_open_act, 0, 0, 0, 0);
    } else if (std.mem.eql(u8, cmd.verb, "tab-next")) {
        cycle_tabs();
    } else if (std.mem.eql(u8, cmd.verb, "tab-close")) {
        if (focused_mirror()) |fm| {
            if (!detach_tab(fm.id)) {
                write_marker("wnd: tab-close idle (focused window has no tab)\n");
            }
        }
    } else if (parse_id_suffix(cmd.verb, "tab-")) |tid| {
        _ = activate_tab(tid);
    } else if (parse_id_suffix(cmd.verb, "win-")) |wid| {
        _ = syscall6(sys_wmctl, wmctl_alt_tab, wid, alt_tab_commit, 0, 0, 0);
    } else if (cmd.section == .active_app) {
        var inv_buf: [80]u8 = undefined;
        const inv_msg = std.fmt.bufPrint(&inv_buf, "{s} label={s}\n", .{ action_inv_marker, cmd.label }) catch "wnd: action-invoked\n";
        write_marker(inv_msg);
    }
}

pub fn toggle_god_menu() void {
    if (god_menu_open) {
        if (god_menu_win) |wid| {
            ui.win_close(wid);
            god_menu_win = null;
        }
        god_menu_open = false;
        god_menu.open = false;
        write_marker(god_menu_close_marker);
        if (god_menu_prev_focus >= 2 and god_menu_prev_focus <= 9) {
            _ = syscall6(sys_wmctl, wmctl_alt_tab, god_menu_prev_focus, alt_tab_commit, 0, 0, 0);
        }
    } else {
        god_menu_prev_focus = if (focused_mirror()) |fm| fm.id else 0;
        // M37 DQ3: modal capture would strand a tab press — clear it.
        tab_press_clear();
        populate_god_menu();
        const menu_x = if (fb_w > god_menu_w) (fb_w - god_menu_w) / 2 else 0;
        const menu_y = if (fb_h > god_menu_h) (fb_h - god_menu_h) / 2 else 0;
        const w_res = ui.win_open(menu_x, menu_y, god_menu_w, god_menu_h);
        if (w_res >= 0) {
            const wid: u32 = @intCast(w_res);
            god_menu_win = wid;
            god_menu_open = true;
            god_menu.open = true;
            god_menu.rect = Rect.make(0, 0, god_menu_w, god_menu_h);
            redraw_god_menu();
            write_marker(god_menu_open_marker);
        } else {
            write_marker("wnd: god-menu open-failed\n");
        }
    }
}

// ---------------------------------------------------------------------------
// The policy actions (each issues SET_WINDOW rects / SET_STATE state).
// ---------------------------------------------------------------------------

/// SET_WINDOW(id, x|y<<16, w|h<<16) — propose a rect (kernel clamps + blits).
fn set_window_rect(id: u8, x: u32, y: u32, w: u32, h: u32) void {
    _ = syscall6(sys_wmctl, wmctl_set_window, id, x | (y << 16), w | (h << 16), 0, 0);
}

/// SET_STATE(id, state) — visibility (bits 0-1), workspace (bits 8-15),
/// always-on-top (bit 16). The ALL id = global workspace switch.
fn set_state(id: u8, visible: ?bool, ws: ?u8, aot: bool) void {
    var st: u64 = 2; // no visibility change (2/3)
    if (visible) |v| st = if (v) 1 else 0;
    if (ws) |w| st |= @as(u64, w) << 8;
    if (aot) st |= 1 << 16;
    _ = syscall6(sys_wmctl, wmctl_set_state, id, st, 0, 0, 0);
}

/// Switch the CURRENT workspace globally (SET_STATE with a0 = ALL).
fn switch_workspace(ws: u8) void {
    _ = syscall6(sys_wmctl, wmctl_set_state, 0xFFFF_FFFF, @as(u64, ws) << 8, 0, 0, 0);
}

/// M21 W1: toggle the focused window floating/tiled. Mirrors the kernel
/// shim's rule (max 2 tiled windows; a third shifts master -> stack).
fn toggle_tiling() void {
    const fm = focused_mirror() orelse return;
    const fid = fm.id;
    // Already master? detach (promote stack).
    if (tile_mode and tile_master_id == fid) {
        if (tile_stack_id != 0xff) {
            tile_master_id = tile_stack_id;
            tile_stack_id = 0xff;
        } else {
            tile_master_id = 0xff;
            tile_mode = false;
        }
    } else if (tile_mode and tile_stack_id == fid) {
        tile_stack_id = 0xff;
        if (tile_master_id == 0xff) tile_mode = false;
    } else {
        // Not yet tiled — add this window.
        if (tile_master_id == 0xff) {
            tile_master_id = fid;
        } else if (tile_stack_id == 0xff) {
            tile_stack_id = fid;
        } else {
            // Both slots occupied — detach the oldest (master) and shift.
            tile_master_id = tile_stack_id;
            tile_stack_id = fid;
        }
        tile_mode = true;
    }
    write_marker(tile_marker);
    apply_tile_layout();
}

/// M21 W2: swap which window is master and which is detail (flip the side).
fn swap_master() void {
    if (!tile_mode or tile_master_id == 0xff or tile_stack_id == 0xff) return;
    const mid = tile_master_id;
    tile_master_id = tile_stack_id;
    tile_stack_id = mid;
    tile_master_side = !tile_master_side;
    write_marker(tile_marker);
    apply_tile_layout();
}

/// Apply the tile layout through the shared wnd_core math (master 2/3,
/// detail 1/3 — the SAME rule the kernel shim's apply_tile_layout uses).
fn apply_tile_layout() void {
    if (!tile_mode) return;
    const tl = wnd_core.tile_layout(fb_w, fb_h, taskbar_h, dock_w, 667, tile_master_side);
    if (tile_master_id != 0xff) {
        if (mirror(tile_master_id)) |m| {
            m.x = tl.master_x;
            m.y = tl.y;
            m.w = tl.master_w;
            m.h = tl.h;
            set_window_rect(m.id, m.x, m.y, m.w, m.h);
        }
    }
    if (tile_stack_id != 0xff) {
        if (mirror(tile_stack_id)) |m| {
            m.x = tl.detail_x;
            m.y = tl.y;
            m.w = tl.detail_w;
            m.h = tl.h;
            set_window_rect(m.id, m.x, m.y, m.w, m.h);
        }
    }
}

/// M21 W3: minimize/restore the focused window (SET_STATE visibility).
fn toggle_minimize() void {
    const fm = focused_mirror() orelse return;
    if (fm.minimized) {
        fm.minimized = false;
        set_state(fm.id, true, null, false);
        // Restore the saved rect (the kernel kept it; we mirror the truth).
        if (fm.snap_valid) {
            set_window_rect(fm.id, fm.snap_last_x, fm.snap_last_y, fm.snap_last_w, fm.snap_last_h);
            fm.x = fm.snap_last_x;
            fm.y = fm.snap_last_y;
            fm.w = fm.snap_last_w;
            fm.h = fm.snap_last_h;
            fm.snap_valid = false;
        }
        write_marker(min_marker);
    } else {
        fm.minimized = true;
        // Save the current rect for restore (the WM's own pre-min copy).
        fm.snap_last_x = fm.x;
        fm.snap_last_y = fm.y;
        fm.snap_last_w = fm.w;
        fm.snap_last_h = fm.h;
        fm.snap_valid = true;
        set_state(fm.id, false, null, false);
        write_marker(min_marker);
    }
}

/// M21 W6: maximize/restore the focused window (SET_WINDOW max rect).
fn toggle_maximize() void {
    const fm = focused_mirror() orelse return;
    if (fm.maximized) {
        fm.maximized = false;
        if (fm.snap_valid) {
            set_window_rect(fm.id, fm.snap_last_x, fm.snap_last_y, fm.snap_last_w, fm.snap_last_h);
            fm.x = fm.snap_last_x;
            fm.y = fm.snap_last_y;
            fm.w = fm.snap_last_w;
            fm.h = fm.snap_last_h;
            fm.snap_valid = false;
        }
        write_marker(max_marker);
    } else {
        const mx = wnd_core.maximize_rect(fb_w, fb_h, taskbar_h, dock_w);
        fm.maximized = true;
        fm.snap_last_x = fm.x;
        fm.snap_last_y = fm.y;
        fm.snap_last_w = fm.w;
        fm.snap_last_h = fm.h;
        fm.snap_valid = true;
        fm.x = mx.x;
        fm.y = mx.y;
        fm.w = mx.w;
        fm.h = mx.h;
        set_window_rect(fm.id, mx.x, mx.y, mx.w, mx.h);
        write_marker(max_marker);
    }
}

/// M21 W7: fullscreen/restore the focused window (SET_WINDOW full rect).
fn toggle_fullscreen() void {
    const fm = focused_mirror() orelse return;
    if (fm.fullscreen) {
        fm.fullscreen = false;
        if (fm.snap_valid) {
            set_window_rect(fm.id, fm.snap_last_x, fm.snap_last_y, fm.snap_last_w, fm.snap_last_h);
            fm.x = fm.snap_last_x;
            fm.y = fm.snap_last_y;
            fm.w = fm.snap_last_w;
            fm.h = fm.snap_last_h;
            fm.snap_valid = false;
        }
        write_marker(fs_marker);
    } else {
        const fs = wnd_core.fullscreen_rect(fb_w, fb_h);
        fm.fullscreen = true;
        fm.snap_last_x = fm.x;
        fm.snap_last_y = fm.y;
        fm.snap_last_w = fm.w;
        fm.snap_last_h = fm.h;
        fm.snap_valid = true;
        fm.x = fs.x;
        fm.y = fs.y;
        fm.w = fs.w;
        fm.h = fs.h;
        set_window_rect(fm.id, fs.x, fs.y, fs.w, fs.h);
        write_marker(fs_marker);
    }
}

/// M21 W8: toggle always-on-top on the focused window (SET_STATE bit 16).
fn toggle_always_on_top() void {
    const fm = focused_mirror() orelse return;
    fm.always_on_top = !fm.always_on_top;
    set_state(fm.id, null, null, true);
    write_marker(aot_marker);
}

/// WMS5 Gate 2: snap the mirror window to the zone under the drop point
/// (M15 C3 rule from wnd_core — corners first, then edges; 20 px threshold).
fn snap_window_to(id: u8, px: u32, py: u32) void {
    const m = mirror(id) orelse return;
    const zone = wnd_core.snap_zone_for_point(px, py, fb_w, fb_h);
    if (zone == .none) return;
    const zb = wnd_core.snap_zone_bounds(zone, fb_w, fb_h, taskbar_h) orelse return;
    // The kernel clamps to user_buf_w/h; we propose the zone-centered rect.
    const win_w = @min(zb.w, wnd_core.user_buf_w);
    const win_h = @min(zb.h, wnd_core.user_buf_h);
    const win_x = zb.x + (zb.w - win_w) / 2;
    const win_y = zb.y + (zb.h - win_h) / 2;
    if (!m.snapped) {
        m.snap_last_x = m.x;
        m.snap_last_y = m.y;
        m.snap_last_w = m.w;
        m.snap_last_h = m.h;
        m.snap_valid = true;
    }
    m.snapped = true;
    m.x = win_x;
    m.y = win_y;
    m.w = win_w;
    m.h = win_h;
    set_window_rect(m.id, win_x, win_y, win_w, win_h);
    write_marker(snap_marker);
}

// ---------------------------------------------------------------------------
// M37 DQ5 (issue #837) — the snap-preview outline. Preview-only: while a
// title-bar drag is in progress and the pointer nears a scanout edge, the
// WM draws the target zone's outline into the shared scanout (the M33
// seam-B surface, same mapping the wallpaper path uses) so the user sees
// the snap before it happens. Release commits through the UNCHANGED
// snap_window_to above — the preview never issues SET_WINDOW itself.
// Cleanup is automatic: the kernel's per-tick paint_scene repaints the
// desktop gradient over the scribble within a tick of the drag ending, and
// while held the outline is redrawn every composite tick (after the
// kernel's paint, before the flush) so a compose can never leave it stale.
// ---------------------------------------------------------------------------

/// Outline thickness (px) — the DQ4 focus-outline token (DQ4 wins ties).
pub const snap_preview_thick: u32 = ui.focus_w;
/// WM4 (issue #707 card 4): the snap-preview corner-bracket polish —
/// 16 px arms inset 8 px from each zone corner (the same solid accent).
pub const snap_preview_tick: u32 = 16;
pub const snap_preview_gap: u32 = 8;

/// The preview rect for a pointer position: the snap zone's bounds from the
/// shared wnd_core rules (20 px threshold, corners first). Null = free
/// (no zone under the pointer — draw nothing). Pure (host-testable).
pub const SnapPreview = struct {
    zone: wnd_core.SnapZone,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub fn snap_preview_for_point(px: u32, py: u32) ?SnapPreview {
    const zone = wnd_core.snap_zone_for_point(px, py, fb_w, fb_h);
    if (zone == .none) return null;
    const zb = wnd_core.snap_zone_bounds(zone, fb_w, fb_h, taskbar_h) orelse return null;
    return .{ .zone = zone, .x = zb.x, .y = zb.y, .w = zb.w, .h = zb.h };
}

/// Print the preview decision with its zone + bounds (the live gate greps
/// the pinned prefix + the values).
fn write_snap_preview_marker(p: SnapPreview) void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s} zone={s} x={d} y={d} w={d} h={d}\n", .{
        snap_preview_marker, @tagName(p.zone), p.x, p.y, p.w, p.h,
    }) catch "wnd: snap-preview\n";
    write_marker(s);
}

/// Map the shared scanout surface when the wallpaper path has not already
/// done so (no /host/WALLPAPER file in the gate share). Same syscall shape
/// as init_wallpaper_if_present; no-op on host (syscall4 stubs to 0, so
/// scanout stays unmapped and draws are skipped in tests).
fn ensure_scanout_mapped() bool {
    if (scanout_mapped) return true;
    const fb_len: u64 = @as(u64, fb_w) * fb_h * 4;
    const scan_va = ui.syscall4(ui.sys_mmap_num, m33_surf_scan_tag, fb_len, prot_rw, map_anonymous | m33_map_shared);
    if (scan_va > 0) {
        scanout_ptr = @ptrFromInt(@as(usize, @intCast(scan_va)));
        scanout_mapped = true;
        return true;
    }
    return false;
}

/// Blit the preview outline: a snap_preview_thick band in the DQ4 accent
/// token around the zone bounds (solid, not translucent — a 50% blend
/// would deny the gate its exact-hex probes; subtlety comes from the thin
/// 2 px band, not alpha). Unconditional overdraw (no occlusion skip): any
/// pixels landing on a window heal at the next kernel paint, and the gate
/// probes desktop-area border pixels.
/// WM4 (issue #707 card 4) polish: 16 px CORNER BRACKETS (L marks, same
/// solid accent, inset 8 px from each corner, one band thick) reaching
/// into the zone interior — the drop target reads at a glance even over
/// busy content. The snap-guides gate probes only edge/center pixels, so
/// the brackets are an additive change.
fn draw_snap_preview(p: SnapPreview) void {
    const scan = scanout_ptr orelse return;
    const accent = ui.theme_accent();
    const r: u32 = (accent >> 16) & 0xff;
    const g: u32 = (accent >> 8) & 0xff;
    const b: u32 = accent & 0xff;
    const pxv: u32 = 0xff000000 | (r << 16) | (g << 8) | b; // B8G8R8X8
    const t = snap_preview_thick;
    const tick = snap_preview_tick;
    const gap = snap_preview_gap;
    const xe = @min(p.x + p.w, fb_w);
    const ye = @min(p.y + p.h, fb_h);
    var y: u32 = p.y;
    while (y < ye) : (y += 1) {
        const on_h = (y < p.y + t) or (y + t >= ye);
        var x: u32 = p.x;
        while (x < xe) : (x += 1) {
            const on_v = (x < p.x + t) or (x + t >= xe);
            if (on_h or on_v) scan[@as(usize, y) * fb_w + x] = pxv;
        }
    }
    // WM4 corner brackets: at each of the 4 corners, an L of two
    // snap_preview_tick-long arms (one band thick), inset `gap` px from
    // the corner, pointing into the zone interior.
    var c: u32 = 0;
    while (c < 4) : (c += 1) {
        const left = (c & 1) == 0;
        const top = c < 2;
        const cx: u32 = if (left) p.x + gap else xe - gap - tick;
        const cy_h: u32 = if (top) p.y + gap else ye - gap - t;
        const cy_v: u32 = if (top) p.y + gap else ye - gap - tick;
        // Horizontal arm (t px tall, tick px long).
        var ty: u32 = cy_h;
        while (ty < cy_h + t and ty < ye) : (ty += 1) {
            var tx: u32 = cx;
            while (tx < cx + tick and tx < xe) : (tx += 1) {
                scan[@as(usize, ty) * fb_w + tx] = pxv;
            }
        }
        // Vertical arm (t px wide, tick px tall).
        var vy: u32 = cy_v;
        while (vy < cy_v + tick and vy < ye) : (vy += 1) {
            var vx: u32 = cx;
            while (vx < cx + t and vx < xe) : (vx += 1) {
                scan[@as(usize, vy) * fb_w + vx] = pxv;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// S6 Tab model (Milestone 19, issue #782) — WM registry tabs.
// ---------------------------------------------------------------------------

fn attach_tab(child_id: u8, parent_id: u8) bool {
    if (child_id == parent_id or child_id > 0xff or parent_id > 0xff) return false;
    const cm = mirror(child_id) orelse return false;
    const pm = mirror(parent_id) orelse return false;
    cm.tab_parent = parent_id;
    cm.tab_active = false;
    cm.x = pm.x;
    cm.y = pm.y;
    cm.w = pm.w;
    cm.h = pm.h;
    set_window_rect(child_id, pm.x, pm.y, pm.w, pm.h);
    _ = syscall6(sys_wmctl, wmctl_attach_tab, child_id, parent_id, 0, 0, 0);
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} child={d} parent={d}\n", .{ tab_attach_marker, child_id, parent_id }) catch "wnd: tab-attach\n";
    write_marker(msg);
    return true;
}

fn detach_tab(child_id: u8) bool {
    const cm = mirror(child_id) orelse return false;
    if (cm.tab_parent == 0) return false;
    cm.tab_parent = 0;
    cm.tab_active = true;
    cm.x +%= 24;
    cm.y +%= 24;
    set_window_rect(child_id, cm.x, cm.y, cm.w, cm.h);
    set_state(child_id, true, null, false);
    _ = syscall6(sys_wmctl, wmctl_detach_tab, child_id, 0, 0, 0, 0);
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} child={d}\n", .{ tab_detach_marker, child_id }) catch "wnd: tab-detach\n";
    write_marker(msg);
    return true;
}

fn activate_tab(tab_id: u8) bool {
    const tm = mirror(tab_id) orelse return false;
    const parent = if (tm.tab_parent != 0) tm.tab_parent else tab_id;
    for (&mirrors) |*m| {
        if (!m.valid) continue;
        const item_parent = if (m.tab_parent != 0) m.tab_parent else m.id;
        if (item_parent == parent) {
            if (m.id == tab_id) {
                m.tab_active = true;
                set_state(m.id, true, null, false);
                _ = syscall6(sys_wmctl, wmctl_alt_tab, m.id, alt_tab_commit, 0, 0, 0);
            } else {
                m.tab_active = false;
                set_state(m.id, false, null, false);
            }
        }
    }
    _ = syscall6(sys_wmctl, wmctl_activate_tab, tab_id, 0, 0, 0, 0);
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} id={d}\n", .{ tab_activate_marker, tab_id }) catch "wnd: tab-activate\n";
    write_marker(msg);
    return true;
}

fn cycle_tabs() void {
    const fm = focused_mirror() orelse return;
    var tab_items: [max_user_windows]wnd_core.TabItem = undefined;
    var count: usize = 0;
    for (&mirrors) |*m| {
        if (!m.valid) continue;
        tab_items[count] = .{
            .window_id = m.id,
            .parent_id = m.tab_parent,
            .active = m.tab_active,
        };
        count += 1;
    }
    if (wnd_core.cycle_next_tab(tab_items[0..count], fm.id)) |next_id| {
        _ = activate_tab(next_id);
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s} active={d}\n", .{ tab_cycle_marker, next_id }) catch "wnd: tab-cycle\n";
        write_marker(msg);
    }
}

// ---------------------------------------------------------------------------
// WMS6 Gate A — the Alt+Tab policy (which window gets focus).
// ---------------------------------------------------------------------------

/// Print the Alt+Tab decision with its target id (the live gate greps the
/// pinned prefix + the value).
fn write_alt_tab_marker(id: u8) void {
    var buf: [40]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s} id={d}\n", .{ alt_tab_marker, id }) catch "wnd: alt-tab id=0\n";
    write_marker(s);
}

/// The next Alt+Tab target: the window AFTER the focused one in the mirror
/// registry (wrap), skipping hidden or off-workspace windows — the same
/// M21 W3/W4 rules the shim's snapshot uses. Pure (host-testable). Returns
/// null when fewer than two windows are cyclable (mirror the shim's no-op).
fn next_alt_tab_target() ?u8 {
    // Collect the cyclable candidates (valid + visible + current workspace).
    var cands: [max_user_windows]u8 = undefined;
    var cnt: usize = 0;
    var focus_idx: ?usize = null;
    for (&mirrors) |*m| {
        if (!m.valid or m.id < 2) continue;
        if (!m.visible) continue;
        if (m.workspace != current_workspace) continue;
        if (cnt < max_user_windows) cands[cnt] = m.id;
        if (m.focused) focus_idx = cnt;
        cnt += 1;
    }
    if (cnt < 2) return null; // not enough windows to Alt+Tab (mirror the shim)
    // Pick the next window after the focused one (starting slot 0 if none).
    const start = focus_idx orelse 0;
    return cands[(start + 1) % cnt];
}

/// The WM's Alt+Tab policy: decide the switch target via `next_alt_tab_target`,
/// then issue ALT_TAB commit so the kernel focuses/raises the WM's choice
/// (the kernel clamps + repaints).
fn handle_alt_tab() void {
    const target = next_alt_tab_target() orelse return;
    _ = syscall6(sys_wmctl, wmctl_alt_tab, target, alt_tab_commit, 0, 0, 0);
    write_alt_tab_marker(target);
}

// ---------------------------------------------------------------------------
// WM2 mission-control overview (Self-hosting Lane 1, issue #707 card 2).
// The grid POLICY: the WM hit-tests its kind-19 pointer stream against the
// SHARED wnd_core grid rules (the same rects the kernel paints) and issues
// OVERVIEW (cmd 21) decisions — the kernel applies + repaints. The card
// order is ascending id on both sides (mirror slot order here, the sorted
// kernel snapshot there), so card index i names the same window everywhere.
// ---------------------------------------------------------------------------

/// The grid input state (open = the kernel grid is on screen; press_id =
/// the card pressed at the down-edge, 0 = none).
var overview_open: bool = false;
var overview_press_id: u8 = 0;

/// The WM's card list: valid + visible mirrors on the current workspace in
/// ascending id order — the same membership rule AND order as the kernel's
/// overview snapshot (which filters on its own visible/workspace fields and
/// sorts ascending). Pure over the mirrors (host-testable via the real
/// table — tests set up mirrors directly).
fn overview_card_list() struct { ids: [max_user_windows]u8, n: usize } {
    var out: [max_user_windows]u8 = @as([max_user_windows]u8, @splat(@as(u8, 0)));
    var n: usize = 0;
    for (&mirrors) |*m| {
        if (!m.valid or m.id < 2) continue;
        if (!m.visible) continue;
        if (m.workspace != current_workspace) continue;
        if (n < max_user_windows) {
            out[n] = m.id;
            n += 1;
        }
    }
    return .{ .ids = out, .n = n };
}

/// Print the enter decision with its card count (the gate greps the pinned
/// prefix + the value).
fn write_overview_enter_marker(n: usize) void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s} n={d}\n", .{ overview_enter_marker, n }) catch "wnd: overview-enter n=0\n";
    write_marker(s);
}

/// Print the focus decision with its target id.
fn write_overview_focus_marker(id: u8) void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s} id={d}\n", .{ overview_focus_marker, id }) catch "wnd: overview-focus id=0\n";
    write_marker(s);
}

/// Print the move decision with its target id + workspace.
fn write_overview_move_marker(id: u8, ws: u8) void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s} id={d} ws={d}\n", .{ overview_move_marker, id, ws }) catch "wnd: overview-move id=0 ws=0\n";
    write_marker(s);
}

/// Enter the grid: issue OVERVIEW enter, mirror the open state, report the
/// card count the kernel returned.
fn overview_enter_grid() void {
    if (overview_open) return;
    const rc = syscall6(sys_wmctl, wmctl_overview, overview_enter_act, 0, 0, 0, 0);
    overview_open = true;
    overview_press_id = 0;
    write_overview_enter_marker(if (rc >= 0) @as(usize, @intCast(rc)) else 0);
}

/// Exit the grid without touching focus.
fn overview_exit_grid() void {
    if (!overview_open) return;
    _ = syscall6(sys_wmctl, wmctl_overview, overview_exit_act, 0, 0, 0, 0);
    overview_open = false;
    overview_press_id = 0;
    write_marker(overview_exit_marker);
}

/// Toggle the grid (the Ctrl+F12 hotkey + re-press path).
fn overview_toggle_grid() void {
    if (overview_open) overview_exit_grid() else overview_enter_grid();
}

/// Click decision: card `id` gains focus+raise and the grid closes.
fn overview_focus_card(id: u8) void {
    _ = syscall6(sys_wmctl, wmctl_overview, overview_focus_act, id, 0, 0, 0);
    overview_open = false;
    overview_press_id = 0;
    write_overview_focus_marker(id);
}

/// Drag decision: card `id` moves to workspace `ws` and the desktop follows.
fn overview_move_card(id: u8, ws: u8) void {
    _ = syscall6(sys_wmctl, wmctl_overview, overview_move_act, id, ws, 0, 0);
    current_workspace = ws;
    overview_open = false;
    overview_press_id = 0;
    write_overview_move_marker(id, ws);
}

/// Route one pointer sample while the grid is open. Down-edge on a card
/// arms the press; up-edge on a workspace-strip button moves the pressed
/// card there; up-edge on a card focuses that card; anything else cancels
/// the press but leaves the grid open (Esc / hotkey / a decision exits).
/// Returns true when the sample was consumed (the caller skips the normal
/// pointer dispatch). Pure hit-testing over the shared grid rules.
fn overview_pointer(px: u32, py: u32, left: bool, prev_left: bool) bool {
    if (!overview_open) return false;
    const cards = overview_card_list();
    const g = wnd_core.overview_grid(cards.n, fb_w, fb_h, taskbar_h, dock_w);
    const down_edge = left and !prev_left;
    const up_edge = !left and prev_left;
    if (down_edge) {
        if (wnd_core.overview_card_at(g, px, py)) |idx| {
            if (idx < cards.n) overview_press_id = cards.ids[idx];
        } else {
            overview_press_id = 0;
        }
        return true;
    }
    if (up_edge) {
        const pressed = overview_press_id;
        overview_press_id = 0;
        if (pressed != 0) {
            if (wnd_core.overview_ws_button_at(g, fb_w, dock_w, px, py)) |ws| {
                overview_move_card(pressed, ws);
                return true;
            }
            if (wnd_core.overview_card_at(g, px, py)) |idx| {
                if (idx < cards.n) {
                    overview_focus_card(cards.ids[idx]);
                    return true;
                }
            }
        }
        return true;
    }
    return true;
}

// ---------------------------------------------------------------------------
// WMS6 Gate D — the dock policy (icon clicks + hover labels).
// ---------------------------------------------------------------------------

/// Hit-test the dock icon grid — mirrors the shim's M15 C4 geometry: 24 px
/// left bar, 20×20 icons at (2, 8+idx*32), 5 icons. Returns the icon index.
fn dock_icon_at(px: u32, py: u32) ?u8 {
    if (px < 2 or px >= 22) return null;
    if (py < 8) return null;
    const rel = py - 8;
    const idx = rel / 32;
    if (idx >= 5) return null;
    if (rel - idx * 32 >= 20) return null;
    return @intCast(idx);
}

/// Print the dock decision with its icon index (the live gate greps the
/// pinned prefix + the value).
fn write_dock_marker(idx: u8) void {
    var buf: [40]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s} idx={d}\n", .{ dock_marker, idx }) catch "wnd: dock idx=0\n";
    write_marker(s);
}

/// The dock icon-click decision: issue DOCK <idx> so the kernel applies the
/// same clamped chain the shim runs (restore-first-minimized -> focus/raise
/// -> open). The kernel clamps + blits.
fn handle_dock_click(idx: u8) void {
    _ = syscall6(sys_wmctl, wmctl_dock, idx, 0, 0, 0, 0);
    write_dock_marker(idx);
}

/// WM3 (issue #707 card 3): the taskbar entry enumeration — the
/// CURRENT-workspace windows in ID-ASCENDING order (mirror slot order ==
/// id order), the same order the kernel's `.taskbar` render walks (the
/// shared wnd_core drift guard), so entry i on both sides is the same
/// window. Returns the count written into `out`.
fn taskbar_entry_ids(out: *[max_user_windows]u8) usize {
    var n: usize = 0;
    var si: usize = 0;
    while (si < max_user_windows) : (si += 1) {
        const m = &mirrors[si];
        if (!m.valid) continue;
        if (m.workspace != current_workspace) continue;
        out[n] = m.id;
        n += 1;
    }
    return n;
}

/// The taskbar-entry hit-test: which WINDOW id (if any) sits under
/// (px, py) — the entry index from the shared wnd_core rule, mapped
/// through the id-ascending enumeration.
fn taskbar_window_at(px: u32, py: u32) ?u8 {
    const ei = wnd_core.taskbar_entry_at(taskbar_ws_count, fb_w, fb_h, tray_w, px, py) orelse return null;
    var ids: [max_user_windows]u8 = undefined;
    const n = taskbar_entry_ids(&ids);
    if (ei >= n) return null;
    return ids[ei];
}

/// The taskbar click decision: issue TASKBAR <id> (cmd 12) — the kernel
/// applies the restore/focus chain. `restore` = the WM's own view that
/// the entry is minimized (hidden mirror); marker-only (the kernel
/// re-derives the truth from its registry).
fn handle_taskbar_click(id: u8, restore: bool) void {
    _ = syscall6(sys_wmctl, wmctl_taskbar, id, 0, 0, 0, 0);
    var buf: [40]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s} id={d} restore={d}\n", .{ taskbar_marker, id, @intFromBool(restore) }) catch "wnd: taskbar id=0 restore=0\n";
    write_marker(s);
}

/// The dock hover-label decision: entering an icon (or moving to a new one)
/// shows the icon's label via the Gate-C TOOLTIP seam; leaving hides it.
fn handle_dock_hover(prev: ?u8, cur: ?u8) void {
    if (cur) |c| {
        if (prev == null or prev.? != c) {
            const label = dock_labels[c];
            _ = syscall6(sys_wmctl, wmctl_tooltip, tooltip_show_act, 0, 0, @intFromPtr(label.ptr), label.len);
            write_marker(tooltip_show_marker);
        }
    } else if (prev != null) {
        _ = syscall6(sys_wmctl, wmctl_tooltip, tooltip_hide_act, 0, 0, 0, 0);
        write_marker(tooltip_hide_marker);
    }
}

// ---------------------------------------------------------------------------
// WMS6 Gate E (issue #626): the tray widget-content policy. The WM — not the
// kernel — owns what the tray shows: the clock string (formatted from its own
// 1 Hz tick counter, the same minute-rollover formula the shim's format_hhmm
// uses — parity by value), the theme letter (the WM is the theme owner;
// parity 'D'), and the clipboard indicator (a sys_clipboard_get probe).
// ---------------------------------------------------------------------------

/// The last content the WM declared (so a refresh only re-issues on change,
/// mirroring the shim's drain: repaint when something changed, not every
/// tick).
const TrayState = struct {
    clock: [5]u8 = .{ '0', '0', ':', '0', '0' },
    clock_set: bool = false,
    clip: bool = false,
};

/// Format HH:MM from the 1 Hz tick count (seconds since this WM registered)
/// — the same formula the shim's format_hhmm uses (minute rollover, 24 h
/// wrap), so parity-by-value holds.
pub fn format_wm_hhmm(buf: *[5]u8, ticks: u64) []const u8 {
    const total_minutes = (ticks / 60) % (24 * 60);
    const hh = total_minutes / 60;
    const mm = total_minutes % 60;
    buf[0] = @as(u8, @intCast('0' + hh / 10));
    buf[1] = @as(u8, @intCast('0' + hh % 10));
    buf[2] = ':';
    buf[3] = @as(u8, @intCast('0' + mm / 10));
    buf[4] = @as(u8, @intCast('0' + mm % 10));
    return buf[0..5];
}

/// The tray refresh decision: compute the widget content from the WM's own
/// state and, when it differs from what was last declared, issue TRAY (cmd
/// 10) and write the `wnd: tray` marker. Returns true when it issued.
pub fn tray_tick_policy(ticks: u64, clip_filled: bool, state: *TrayState) bool {
    var clock_buf: [5]u8 = undefined;
    const clock = format_wm_hhmm(&clock_buf, ticks);
    if (state.clock_set and std.mem.eql(u8, state.clock[0..], clock) and state.clip == clip_filled) {
        return false; // nothing changed — no re-issue (mirrors the shim drain)
    }
    state.clock = clock_buf;
    state.clip = clip_filled;
    state.clock_set = true;
    // Pack the 5-byte clock text little-endian into a1 (the frozen encoding).
    var clock_packed: u64 = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) clock_packed |= @as(u64, clock_buf[i]) << @intCast(i * 8);
    const a2 = @as(u64, tray_theme_letter) | (if (clip_filled) @as(u64, 1) << 8 else 0);
    _ = syscall6(sys_wmctl, wmctl_tray, tray_flag_clock | tray_flag_theme | tray_flag_clip, clock_packed, a2, 0, 0);
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s} clock={s} theme={c} clip={s}\n", .{
        tray_marker,
        clock,
        tray_theme_letter,
        if (clip_filled) "yes" else "no",
    }) catch "wnd: tray\n";
    write_marker(s);
    return true;
}

// ---------------------------------------------------------------------------
// WMS7 Gate A (issue #627): the app↔WM mailbox service loop. The WM serves
// bounded IPC requests from apps (the wire format, WM_RPC, is single-sourced
// in wnd_core so the server and the app cannot drift). Runs once per tick
// (kind-18 at 1 Hz => <= 1 s request latency — accepted + documented).
// ---------------------------------------------------------------------------

/// Send a WM_RPC reply to `reply_to` (the requesting app's pid) — the echo
/// kind + seq with the applied flag, so the app's bounded poll has something
/// definitive to match. A dead/unknown reply target is simply dropped (the
/// sys_ipc_send returns EINVAL before any copy — honest, no loss inside the
/// kernel mailbox).
fn wnd_mail_reply(reply_to: u8, req: *const wnd_core.WmRpc, applied: bool) void {
    var rep: wnd_core.WmRpc = .{
        .kind = req.kind | wnd_core.wm_rpc_reply_flag,
        .id = req.id,
        .seq = req.seq,
        .reply_to = reply_to,
        .applied = if (applied) 1 else 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = @as([wnd_core.wm_rpc_title_max]u8, @splat(@as(u8, 0))),
    };
    const rep_bytes = std.mem.asBytes(&rep);
    _ = syscall3(sys_ipc_send, reply_to, @intFromPtr(rep_bytes.ptr), rep_bytes.len);
}

/// Apply ONE WM_RPC request through the WM's OWN clamped primitives — the
/// same paths its native decisions use, so a mail-driven raise/config is
/// byte-identical to a WM-native one. Returns whether it applied.
fn wnd_mail_apply(req: *const wnd_core.WmRpc) bool {
    switch (req.kind & 0x7f) {
        wnd_core.wm_rpc_kind_raise => {
            // WIN_RAISE: focus + raise via the ALT_TAB-commit path (the
            // proven WMS6 Gate-A primitive; a bad id returns EINVAL).
            const rc = syscall6(sys_wmctl, wmctl_alt_tab, req.id, alt_tab_commit, 0, 0, 0);
            return rc == 0;
        },
        wnd_core.wm_rpc_kind_config => {
            // WIN_CONFIG: clamped move/resize via the SET_WINDOW rect path.
            const rc = syscall6(sys_wmctl, wmctl_set_window, req.id, @as(u64, req.x) | (@as(u64, req.y) << 16), @as(u64, req.w) | (@as(u64, req.h) << 16), 0, 0);
            return rc == 0;
        },
        wnd_core.wm_rpc_kind_register_action => {
            var label_slice: []const u8 = req.title[0..];
            for (req.title, 0..) |c, i| {
                if (c == 0) {
                    label_slice = req.title[0..i];
                    break;
                }
            }
            if (app_actions_count < app_actions.len) {
                var act = &app_actions[app_actions_count];
                act.owner_id = req.id;
                act.section = @intCast(@min(req.x, 5));
                const copy_l = @min(label_slice.len, act.label.len);
                @memcpy(act.label[0..copy_l], label_slice[0..copy_l]);
                act.label_len = copy_l;
                const verb = "test-act";
                const copy_v = @min(verb.len, act.verb.len);
                @memcpy(act.verb[0..copy_v], verb[0..copy_v]);
                act.verb_len = copy_v;
                app_actions_count += 1;
            }
            var buf: [80]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s} section={d} label={s} verb=test-act\n", .{ action_reg_marker, req.x, label_slice }) catch "wnd: action-registered\n";
            write_marker(msg);
            return true;
        },
        wnd_core.wm_rpc_kind_invoke_action => {
            var label_slice: []const u8 = req.title[0..];
            for (req.title, 0..) |c, i| {
                if (c == 0) {
                    label_slice = req.title[0..i];
                    break;
                }
            }
            var buf: [80]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s} label={s}\n", .{ action_inv_marker, label_slice }) catch "wnd: action-invoked\n";
            write_marker(msg);
            return true;
        },
        wnd_core.wm_rpc_kind_attach_tab => {
            return attach_tab(req.id, @intCast(req.x));
        },
        wnd_core.wm_rpc_kind_detach_tab => {
            return detach_tab(req.id);
        },
        wnd_core.wm_rpc_kind_cycle_tab => {
            cycle_tabs();
            return true;
        },
        else => return false, // unknown kind — refused honestly
    }
}

/// Drain the WM's own inbox: recv (non-blocking), bound each message to the
/// frozen WM_RPC shape, apply, reply, and print the `wnd: mail` marker. The
/// loop empties the whole inbox each tick (bounded work per wake).
fn wnd_mail_loop() void {
    var raw: [mail_inbox_max]u8 = undefined;
    while (true) {
        const got = syscall2(sys_ipc_recv, @intFromPtr(&raw), raw.len);
        if (got <= 0) return; // empty inbox — drained
        if (got < @sizeOf(wnd_core.WmRpc)) continue; // truncated junk — skip
        var req: wnd_core.WmRpc = undefined;
        @memcpy(std.mem.asBytes(&req), raw[0..@sizeOf(wnd_core.WmRpc)]);
        const reply_to = req.reply_to;
        if (req.kind & wnd_core.wm_rpc_reply_flag != 0) continue; // a reply, not a request
        const applied = wnd_mail_apply(&req);
        // Marker: wnd: mail kind=N id=M seq=S applied=yes|no [title=..]
        var title_slice: []const u8 = req.title[0..];
        for (req.title, 0..) |c, i| {
            if (c == 0) {
                title_slice = req.title[0..i];
                break;
            }
        }
        var buf: [72]u8 = undefined;
        const s = if (title_slice.len == 0)
            std.fmt.bufPrint(&buf, "{s} kind={d} id={d} seq={d} applied={s}\n", .{ mail_marker, req.kind, req.id, req.seq, if (applied) "yes" else "no" }) catch "wnd: mail\n"
        else
            std.fmt.bufPrint(&buf, "{s} kind={d} id={d} seq={d} applied={s} title={s}\n", .{ mail_marker, req.kind, req.id, req.seq, if (applied) "yes" else "no", title_slice }) catch "wnd: mail\n";
        write_marker(s);
        wnd_mail_reply(reply_to, &req, applied);
    }
}

// ---------------------------------------------------------------------------
// The WMS5 keyboard chord decoder (kind 21 WM_KEY).
// ---------------------------------------------------------------------------
fn handle_wm_key(usage: u8, flags: u16) void {
    const ctrl = (flags & mod_ctrl) != 0;
    const shift = (flags & mod_shift) != 0;
    const alt = (flags & mod_alt) != 0;

    // Issue #821 Phase 1: Ctrl+Space toggles the Global Sexiburger God Menu.
    if (ctrl and usage == usage_space) {
        toggle_god_menu();
        return;
    }

    // WM2 (issue #707 card 2): the overview hotkey works everywhere —
    // Ctrl+F12 toggles the grid even over the god menu; Esc exits it.
    if (ctrl and usage == usage_f12) {
        if (god_menu_open) toggle_god_menu();
        overview_toggle_grid();
        return;
    }
    if (usage == usage_esc and overview_open and !god_menu_open) {
        overview_exit_grid();
        return;
    }

    if (god_menu_open) {
        if (usage == 0x29) { // Escape dismisses
            toggle_god_menu();
            return;
        }
        if (usage == 0x28) { // Enter executes selected
            if (god_menu.filtered_count > 0 and god_menu.selected_filter_idx < god_menu.filtered_count) {
                const sel_cmd = god_menu.filtered[god_menu.selected_filter_idx].command;
                execute_god_menu_command(sel_cmd);
            }
            toggle_god_menu();
            return;
        }
        if (usage == 0x52) { // Up arrow
            if (god_menu.filtered_count > 0) {
                if (god_menu.selected_filter_idx > 0) {
                    god_menu.selected_filter_idx -= 1;
                } else {
                    god_menu.selected_filter_idx = god_menu.filtered_count - 1;
                }
                redraw_god_menu();
            }
            return;
        }
        if (usage == 0x51) { // Down arrow
            if (god_menu.filtered_count > 0) {
                if (god_menu.selected_filter_idx + 1 < god_menu.filtered_count) {
                    god_menu.selected_filter_idx += 1;
                } else {
                    god_menu.selected_filter_idx = 0;
                }
                redraw_god_menu();
            }
            return;
        }
        if (usage == 0x2a) { // Backspace
            if (god_menu.search_len > 0) {
                god_menu.search_len -= 1;
                god_menu.update_filter();
                redraw_god_menu();
            }
            return;
        }
        if (hid_to_ascii(usage, shift)) |ch| {
            if (ch >= 0x20 and ch <= 0x7e) {
                if (god_menu.search_len < god_menu.search_buf.len) {
                    god_menu.search_buf[god_menu.search_len] = ch;
                    god_menu.search_len += 1;
                    god_menu.update_filter();
                    redraw_god_menu();
                }
            }
        }
        return;
    }

    if (alt and usage == usage_tab) {
        // WMS6 Gate A: the WM, not the kernel, decides which window Alt+Tab
        // switches to.
        handle_alt_tab();
        return;
    }
    if (ctrl and usage == usage_tab) {
        // S6 Tab model (Milestone 19, issue #782): Ctrl+Tab cycles tabs.
        cycle_tabs();
        return;
    }
    if (ctrl and usage == usage_w) {
        // S6 Tab model (Milestone 19, issue #782): Ctrl+W detaches/closes tab.
        if (focused_mirror()) |fm| {
            if (fm.tab_parent != 0) {
                _ = detach_tab(fm.id);
                return;
            }
        }
    }
    if (alt and usage == usage_backtick) {
        // Alt+` cycles workspaces (W4).
        current_workspace = (current_workspace + 1) % 3;
        switch_workspace(current_workspace);
        write_marker(ws_marker);
        return;
    }
    if (ctrl and !shift) {
        if (usage == usage_f1) {
            current_workspace = 0;
            switch_workspace(0);
            write_marker(ws_marker);
            return;
        }
        if (usage == usage_f2) {
            current_workspace = 1;
            switch_workspace(1);
            write_marker(ws_marker);
            return;
        }
        if (usage == usage_f3) {
            current_workspace = 2;
            switch_workspace(2);
            write_marker(ws_marker);
            return;
        }
        if (usage == usage_t) {
            toggle_tiling();
            return;
        }
        if (usage == usage_m) {
            swap_master();
            return;
        }
        if (usage == usage_n) {
            toggle_minimize();
            return;
        }
    }
    if (ctrl and shift) {
        if (usage == usage_m) {
            toggle_maximize();
            return;
        }
        if (usage == usage_t) {
            toggle_always_on_top();
            return;
        }
        if (usage == usage_a) {
            toggle_about();
            return;
        }
    }
    if (usage == usage_f11) {
        toggle_fullscreen();
        return;
    }
}

// ---------------------------------------------------------------------------
// The main loop (REGISTER -> chrome policy -> wait/serve events forever).
// ---------------------------------------------------------------------------

export fn _start() callconv(.c) noreturn {
    // The whole body is Zig below (freestanding, no libc) — the entry is a
    // plain function; the kernel enters at _start with a valid stack,
    // exactly like NOTEPAD.BIN. This program never returns.
    main();
}

fn main() noreturn {
    // WMS3: REGISTER (cmd 1). Only seated when the kernel compositor seam is
    // armed (the live gate boots with --screen); otherwise ENXIO parks here.
    if (syscall6(sys_wmctl, wmctl_register, 0, 0, 0, 0, 0) != 0) {
        while (true) {
            _ = syscall0(sys_yield_num); // fail-safe park
        }
    }
    write_marker(registered_marker);

    // Ensure mirror table is initialized cleanly.
    mirrors = @as([max_user_windows]MirrorWin, @splat(@as(MirrorWin, .{})));

    // Issue #825: probe for desktop wallpaper (/host/WALLPAPER.QOI or .PNG)
    init_wallpaper_if_present();

    // Issue #846: preload god-menu dynamic apps catalog from APPS.TXT at startup.
    // Safe across tasks and concurrent boot bursts with locked file-channel reads.
    _ = load_god_menu_apps();

    // WMS4 (issue #624): submit the chrome POLICY — one
    // sys_wmctl(SET_WINDOW, a0=ALL, a1=0, a2=0, ptr=desc, len=48). The WM
    // becomes the theme owner: the kernel blits chrome from this descriptor
    // (dark-theme values, byte-equal to the shim's own constants — parity by
    // value). Issued right after REGISTER, before any window exists, so every
    // window created later inherits it (the kernel's draw-time fallback).
    // WM4 (issue #707 card 4): the v2 descriptor adds the REST-OPACITY
    // policy — an unfocused at-rest window's CLIENT area blends at
    // wm_rest_alpha (the chrome stays opaque; the WMS4 chrome parity gate
    // is untouched). 256 would be the v1 no-op; the WM opts in below.
    var desc = wnd_core.chrome_parity_policy();
    desc.rest_alpha = wm_rest_alpha_policy;
    _ = syscall6(sys_wmctl, wmctl_set_window, 0xFFFF_FFFF, 0, 0, @intFromPtr(&desc), wnd_core.chrome_desc_bytes_v2);
    {
        var rbuf: [32]u8 = undefined;
        const rs = std.fmt.bufPrint(&rbuf, "wnd: rest-alpha={d}\n", .{wm_rest_alpha_policy}) catch "wnd: rest-alpha=240\n";
        write_marker(rs);
    }

    // WMS5 mirror + drag + policy state.
    var ev: Event = undefined;
    var ticks: u64 = 0;
    var presents: u64 = 0;
    // WMP card 2 (#1250): an event the head's look-ahead already took out of
    // the queue, to be serviced WITHOUT parking.
    var queued: bool = false;
    // WMP card 2 (#1250): this burst serviced input (kinds 19/20/21), so the
    // frame owes a flush before the loop parks. See the loop head.
    var input_dirty: bool = false;
    var grabbing: bool = false;
    var grab_dx: u32 = 0;
    var grab_dy: u32 = 0;
    var prev_btn: u8 = 0;
    // M37 DQ5 (issue #837): the snap-preview outline state — the last zone
    // previewed (.none = no outline on screen) + the last pointer position
    // (the tick redraw needs it; pointer events stop while held still).
    var snap_zone: wnd_core.SnapZone = .none;
    var snap_px: u32 = 0;
    var snap_py: u32 = 0;
    // M37 DQ5 (issue #837): continuous tick-restores in the current zone
    // (drives the settled marker; reset on zone change/drop/grab).
    var snap_tick_count: u32 = 0;
    var notif_open: bool = false;
    // WMS6 Gate E (issue #626): the tray widget-content state the WM owns.
    var tray_state: TrayState = .{};
    var prev_in_tray: bool = false;
    var prev_dock_idx: ?u8 = null;
    while (true) {
        // WMP card 2 (#1250): NON-BLOCKING look-ahead before parking.
        // `sys_poll_event` CONSUMES, so a hit is not a peek — it is the next
        // queued event, carried to the body by `queued` without parking. An
        // empty queue with `input_dirty` set means an input burst just ENDED,
        // and the frame is flushed HERE.
        //
        // Present-on-input is the fix for the measured WMP card 1 (#1247)
        // finding: the kernel's kind-18 tick is 1 Hz and this WM presented
        // only every Nth tick (`present_every` = 2 s on VZ), so a pointer
        // sample waited 0.8-1.2 s on average and up to 3.0 s for its frame
        // while a present's own transfer+flush costs 0.3 ms. Flushing at the
        // END of a burst coalesces a pointer storm into ONE present while a
        // single click or drag step reaches the screen at once. The tick
        // cadence stays as the idle repaint heartbeat.
        //
        // This sits at the HEAD rather than after the switch on purpose: the
        // arms `continue` in several places (an untracked registry mirror, a
        // pointer event that changes nothing), and a tail flush would be
        // skipped by every one of them — stranding the frame until the next
        // decimated tick, which is the bug being fixed.
        if (!queued) {
            const rc = syscall1(sys_poll_event_num, @intFromPtr(&ev));
            if (rc == 1) {
                queued = true;
            } else {
                if (input_dirty) {
                    _ = syscall6(sys_wmctl, wmctl_request_present, 0, 0, 0, 0, 0);
                    presents +%= 1;
                    if (presents % marker_every == 0) {
                        write_marker(present_marker);
                    }
                    input_dirty = false;
                }
                // BLOCK until at least one event is queued for this process.
                // The kernel delivers COMPOSITE_TICK (18), WM_POINTER (19),
                // WM_WINDOW (20), and WM_KEY (21) while we are registered.
                // `handle_wait_event` returns immediately while the queue is
                // non-empty and only parks us when it drains — so a single
                // wake serves the WHOLE backlog, and the bounded work per
                // wake is "drain the queue", not "one event".
                const wait_rc = syscall1(sys_wait_event_num, @intFromPtr(&ev));
                if (wait_rc != 1) {
                    // TEMP DEBUG: print the wait_event return code.
                    var dbg: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&dbg, "wnd: wait_rc={d}\n", .{wait_rc}) catch "wnd: dbg-err\n";
                    write_marker(s);
                    _ = syscall0(sys_yield_num);
                    continue;
                }
            }
        }
        queued = false;

        switch (ev.kind) {
            composite_tick_kind => {
                ticks +%= 1;
                // Issue #825: render wallpaper on root desktop behind windows
                if (wallpaper_loaded and scanout_mapped) {
                    render_wallpaper_root();
                    write_marker(wallpaper_present_marker);
                }
                // M37 DQ5 (issue #837): redraw the snap outline while held —
                // the kernel's paint ran before this tick was delivered and
                // the move's own SET_WINDOW damage may have repainted the
                // desktop over the move-time outline since.
                if (grabbing and snap_zone != .none) {
                    if (snap_preview_for_point(snap_px, snap_py)) |prev| {
                        if (scanout_mapped) {
                            draw_snap_preview(prev);
                            write_marker(snap_tick_marker);
                            snap_tick_count +%= 1;
                            if (snap_tick_count == snap_settled_ticks) {
                                write_marker(snap_settled_marker);
                            }
                        }
                    }
                }
                if (ticks % present_every == 0) {
                    _ = syscall6(sys_wmctl, wmctl_request_present, 0, 0, 0, 0, 0);
                    presents +%= 1;
                    if (presents % marker_every == 0) {
                        write_marker(present_marker);
                    }
                }
                // WMS6 Gate E (issue #626): the tray refresh cadence — every
                // `tray_refresh_every` ticks the WM re-decides the tray
                // widget content from its own state (the clock string from
                // the tick counter, the clipboard indicator from a
                // sys_clipboard_get probe) and issues TRAY on change. Before
                // this gate the tray froze while a WM was registered (the
                // kernel's drain is gated off); now the WM drives it.
                if (ticks % tray_refresh_every == 0) {
                    var clip_buf: [tray_clip_probe]u8 = undefined;
                    // M97g (#2082): slot 39 admits CAP_CLIPBOARD or the
                    // registered seat — a refused probe is rc < 0 and must
                    // not fake "filled".
                    const clip_len = syscall3(sys_clipboard_get, @intFromPtr(&clip_buf), clip_buf.len, 0);
                    _ = tray_tick_policy(ticks, clip_len > 0, &tray_state);
                }
                // WMS7 Gate A (issue #627): the app↔WM mailbox service loop —
                // serve any WM_RPC requests an app queued in the WM's inbox
                // since the last wake (<= 1 s latency at the 1 Hz tick).
                wnd_mail_loop();
            },
            wm_window_kind => {
                // WM_WINDOW (kind 20) registry mirror: flags low byte = id,
                // bit 8 = visible, bit 9 = focused, bits 10-11 = workspace;
                // arg0 = x|(y<<16), arg1 = w|(h<<16).
                // WMP card 2 (#1250): a registry mirror IS something the frame
                // must show — a window moved/resized/raised is exactly what a
                // drag looks like from here. Dirtied before the `continue` so
                // the flush cannot be skipped (the head reads it next turn).
                input_dirty = true;
                const id: u8 = @intCast(ev.flags & 0xff);
                const s = mirror_slot(id) orelse continue; // not a window we track
                const m = &mirrors[s];
                if (!m.valid) {
                    m.* = .{};
                }
                m.id = id;
                m.valid = true;
                m.x = ev.arg0 & 0xffff;
                m.y = ev.arg0 >> 16;
                m.w = ev.arg1 & 0xffff;
                m.h = ev.arg1 >> 16;
                m.visible = (ev.flags & (1 << 8)) != 0;
                m.focused = (ev.flags & (1 << 9)) != 0;
                m.workspace = @intCast((ev.flags >> 10) & 0x3);
                m.unsaved = (ev.flags & (1 << 12)) != 0;
            },
            wm_pointer_kind => {
                // WM_POINTER (kind 19): raw absolute pointer. arg0 =
                // px|(py<<16) (framebuffer pixels), flags low byte = HID
                // button byte (0x01 = left). The WM — not the kernel —
                // hit-tests and decides geometry.
                // WMP card 2 (#1250): the pointer stream is what the desktop
                // must answer promptly — the measured 0.8-1.2 s wait lived
                // here. Set before the arm's `continue`s for the same reason
                // as the mirror arm: the head reads it on the next turn.
                input_dirty = true;
                const px = ev.arg0 & 0xffff;
                const py = ev.arg0 >> 16;
                const btn: u8 = @intCast(ev.flags & 0xff);
                const left = (btn & btn_left) != 0;
                const prev_left = (prev_btn & btn_left) != 0;

                // WM2 (issue #707 card 2): the overview grid captures
                // pointer input while open — the god menu, when open,
                // sits above it (Ctrl+F12 closes the menu first).
                if (overview_open and !god_menu_open) {
                    _ = overview_pointer(px, py, left, prev_left);
                    prev_btn = btn;
                    continue;
                }

                // Issue #821 Phase 1: God Menu modal pointer capture
                if (god_menu_open) {
                    const menu_x = if (fb_w > god_menu_w) (fb_w - god_menu_w) / 2 else 0;
                    const menu_y = if (fb_h > god_menu_h) (fb_h - god_menu_h) / 2 else 0;
                    if (!prev_left and left) {
                        if (px < menu_x or px >= menu_x + god_menu_w or py < menu_y or py >= menu_y + god_menu_h) {
                            toggle_god_menu();
                        } else {
                            const mev = ui.Event{
                                .kind = ui.MOUSE_DOWN,
                                .flags = ui.BTN_LEFT,
                                .seq = 0,
                                .arg0 = px - menu_x,
                                .arg1 = py - menu_y,
                            };
                            if (god_menu.handle_event(&mev)) {
                                if (!god_menu.is_open()) {
                                    if (god_menu.last_invoked_cmd) |lic| {
                                        execute_god_menu_command(lic);
                                    }
                                    toggle_god_menu();
                                } else {
                                    redraw_god_menu();
                                }
                            }
                        }
                    } else if (px >= menu_x and px < menu_x + god_menu_w and py >= menu_y and py < menu_y + god_menu_h) {
                        const mev = ui.Event{
                            .kind = ui.MOUSE_MOVE,
                            .flags = 0,
                            .seq = 0,
                            .arg0 = px - menu_x,
                            .arg1 = py - menu_y,
                        };
                        if (god_menu.handle_event(&mev)) {
                            redraw_god_menu();
                        }
                    }
                    prev_btn = btn;
                    continue;
                }

                // M37 DQ3 (issue #839): a tab-strip press in progress owns
                // the button until release (click / × / detach-drag).
                if (tab_press_id) |tid| {
                    if (!left) {
                        if (tab_dragging) {
                            // Detach-drag: drop with top-left at the cursor.
                            if (mirror(tid)) |tm| {
                                const tw = tm.w;
                                const th = tm.h;
                                if (detach_tab(tid)) {
                                    set_window_rect(tid, @intCast(px), @intCast(py), tw, th);
                                }
                            }
                        } else if (tab_press_close) {
                            _ = detach_tab(tid);
                        } else {
                            _ = activate_tab(tid);
                        }
                        tab_press_clear();
                    } else if (!tab_dragging and tab_drag_exceeded(tab_press_x, tab_press_y, @intCast(px), @intCast(py))) {
                        tab_dragging = true;
                        var dbuf: [32]u8 = undefined;
                        const dmsg = std.fmt.bufPrint(&dbuf, "{s} id={d}\n", .{ tab_drag_marker, tid }) catch "wnd: tab-drag\n";
                        write_marker(dmsg);
                    }
                    prev_btn = btn;
                    continue;
                }
                if (grabbing) {
                    if (left) {
                        // While held: MOVE via SET_WINDOW rect (the kernel
                        // clamps whatever we propose and mirrors the clamped
                        // truth back at us).
                        const fm = focused_mirror();
                        if (fm) |m| {
                            const nx = px -% grab_dx;
                            const ny = py -% grab_dy;
                            set_window_rect(m.id, nx, ny, m.w, m.h);
                            m.x = nx;
                            m.y = ny;
                            write_marker(drag_marker);
                            // M37 DQ5 (issue #837): preview the snap target
                            // while held — render-only, never SET_WINDOW.
                            snap_px = px;
                            snap_py = py;
                            if (snap_preview_for_point(px, py)) |prev| {
                                if (ensure_scanout_mapped()) draw_snap_preview(prev);
                                if (snap_zone != prev.zone) {
                                    snap_zone = prev.zone;
                                    snap_tick_count = 0;
                                    write_snap_preview_marker(prev);
                                }
                            } else {
                                snap_zone = .none;
                                snap_tick_count = 0;
                            }
                        }
                    } else {
                        // Released: DROP. Snap if the drop point is near a
                        // scanout edge (M15 C3).
                        grabbing = false;
                        // M37 DQ5: the outline dies with the drag — the next
                        // kernel paint covers the scribble; stop redrawing.
                        snap_zone = .none;
                        snap_tick_count = 0;
                        const fm = focused_mirror();
                        if (fm) |m| {
                            snap_window_to(m.id, px, py);
                        }
                        write_marker(drop_marker);
                    }
                } else {
                    // Not grabbing: a left-button DOWN EDGE starts a drag —
                    // but only when the pointer is inside the focused
                    // window's TITLE BAR (the wnd_core.title_bar_contains
                    // rule: [my, my+16), full width).
                    if (!prev_left and left) {
                        // WMS6 Gate B (issue #626): a left-button DOWN EDGE on
                        // the TRAY (the taskbar's right slice) toggles the
                        // notification center — the WM, not the kernel,
                        // decides (the kernel's own tray-click handler is
                        // gated behind !wm_owns_input). Mirrors the shim's
                        // tray_rect so the live gate's injected click is
                        // visible to both surfaces.
                        if (py >= fb_h - taskbar_h and px >= fb_w - tray_w) {
                            notif_open = !notif_open;
                            _ = syscall6(sys_wmctl, wmctl_notif_center, if (notif_open) notif_open_act else notif_close_act, 0, 0, 0, 0);
                            write_marker(if (notif_open) notif_open_marker else notif_close_marker);
                        }
                        // WMS6 Gate D (issue #626): a left-button DOWN EDGE on a
                        // dock icon issues DOCK — the WM, not the kernel, decides.
                        if (dock_icon_at(px, py)) |didx| {
                            handle_dock_click(didx);
                        }
                        // WM3 (issue #707 card 3): a left-button DOWN EDGE on a
                        // taskbar ENTRY issues TASKBAR — the WM, not the kernel,
                        // decides which entry (the entry rects are the shared
                        // wnd_core rule, parity by construction). The restore bit
                        // is the WM's own view (hidden mirror); the kernel
                        // re-derives the truth from its registry.
                        var tb_clicked = false;
                        if (taskbar_window_at(px, py)) |tbid| {
                            const tm = mirror(tbid);
                            const restore = tm != null and !tm.?.visible;
                            handle_taskbar_click(tbid, restore);
                            tb_clicked = true;
                        }
                        // WMS8 Gate 4 (issue #628): the unsaved-changes dialog —
                        // the WM, not the kernel, decides. While the dialog is
                        // open, a click routes to its buttons (the shared
                        // wnd_core rule — the same rects the kernel's
                        // unsaved_dialog_click applies, parity by construction).
                        // Otherwise a close-button click (title-bar top-right)
                        // on a DIRTY mirror (kind-20 unsaved bit) shows it.
                        // Review fix (claim 7639): the DOWN EDGE is CONSUMED
                        // when the dialog or a close button takes it — the
                        // kernel shim set `handled_btn` and broke, and the WM
                        // must not also start a title-bar grab (the close rect
                        // sits inside the title band).
                        var down_handled = false;
                        // WM3: a taskbar-entry click consumes the edge — the
                        // entry band is kernel chrome, never a title bar.
                        if (tb_clicked) down_handled = true;
                        if (unsaved_dialog_open) {
                            apply_unsaved_choice(wnd_core.unsaved_dialog_choice_at(fb_w, fb_h, px, py));
                            down_handled = true;
                        } else {
                            // Review fix (claim 7639): scan TOP-DOWN (the
                            // kernel shim walks win_count..0) so an
                            // overlapping higher window's title bar wins —
                            // z-order == id order (raise() has no callers),
                            // so reverse id order == top of the stack.
                            var si: usize = max_user_windows;
                            while (si > 0) {
                                si -= 1;
                                const m = &mirrors[si];
                                if (!m.valid or !m.visible) continue;
                                if (px >= m.x + m.w - 16 and px < m.x + m.w - 4 and
                                    py >= m.y and py < m.y + wnd_core.title_bar_h)
                                {
                                    if (m.unsaved) show_unsaved_dialog(m.id);
                                    // Not dirty: the WM has no close capability
                                    // yet (status quo — a later gate); ignore.
                                    down_handled = true;
                                    break;
                                }
                            }
                        }
                        // M37 DQ3 (issue #839): a tab-strip press consumes
                        // the edge (cells switch, × detaches, press+drag
                        // detaches at drop). Checked before the title grab;
                        // strip rows never overlap the title band, but the
                        // consumed edge keeps the two grabs exclusive.
                        if (!down_handled) {
                            if (tab_hit_at(@intCast(px), @intCast(py))) |hit| {
                                tab_press_id = hit.tab_id;
                                tab_press_close = hit.on_close;
                                tab_press_x = @intCast(px);
                                tab_press_y = @intCast(py);
                                tab_dragging = false;
                                down_handled = true;
                            }
                        }
                        // WMS5: a title-bar grab starts a drag — only when the
                        // DOWN EDGE was not consumed above (the dialog, a
                        // close button, or a tab-strip press already took it).
                        if (!down_handled) {
                            const fm = focused_mirror();
                            if (fm) |m| {
                                const g = wnd_core.Geom{
                                    .id = m.id,
                                    .kind = .user,
                                    .x = m.x,
                                    .y = m.y,
                                    .w = m.w,
                                    .h = m.h,
                                    .visible = m.visible,
                                    .workspace = m.workspace,
                                };
                                if (wnd_core.title_bar_contains(g, px, py)) {
                                    grabbing = true;
                                    grab_dx = px -% m.x;
                                    grab_dy = py -% m.y;
                                    // M37 DQ5: a fresh drag previews nothing yet.
                                    snap_zone = .none;
                                    snap_tick_count = 0;
                                    snap_px = px;
                                    snap_py = py;
                                    write_marker(grab_marker);
                                }
                            }
                        }
                    }
                }
                // WMS6 Gate C (issue #626): hover (move, no click) over the
                // TRAY shows a tooltip — the WM, not the kernel, decides when
                // and what (kind 19 already fanned the hover; the kernel's
                // own tooltip system is a dormant stub that WMS8 deletes).
                const in_tray = (py >= fb_h - taskbar_h and px >= fb_w - tray_w);
                if (in_tray and !prev_in_tray) {
                    _ = syscall6(sys_wmctl, wmctl_tooltip, tooltip_show_act, 0, 0, @intFromPtr(tray_tooltip_text.ptr), tray_tooltip_text.len);
                    write_marker(tooltip_show_marker);
                } else if (!in_tray and prev_in_tray) {
                    _ = syscall6(sys_wmctl, wmctl_tooltip, tooltip_hide_act, 0, 0, 0, 0);
                    write_marker(tooltip_hide_marker);
                }
                prev_in_tray = in_tray;
                // WMS6 Gate D (issue #626): hover over a DOCK icon shows its
                // label (via the Gate-C TOOLTIP seam); leaving hides it.
                const didx = dock_icon_at(px, py);
                handle_dock_hover(prev_dock_idx, didx);
                prev_dock_idx = didx;
                prev_btn = btn;
            },
            wm_key_kind => {
                // WM_KEY (kind 21): raw keyboard — arg0 = HID usage, flags =
                // ADR 0009 modifier bits. The WM — not the kernel — decides
                // geometry from chords.
                handle_wm_key(@intCast(ev.arg0), ev.flags);
                // WMP card 2 (#1250): a chord is input too (a WM-driven
                // Ctrl+T layout change, a modal, a focus move) — flush it
                // when the burst ends rather than at the next tick.
                input_dirty = true;
            },
            else => {},
        }
    }
}

test "wnd: module compiles and exports the EL0 entry (drift guard import)" {
    _ = @intFromPtr(&_start);
    // The WM binary is built against the SAME shared rules as the kernel shim.
    _ = wnd_core.hit_test;
    _ = wnd_core.clamp_resize_w;
}

test "wnd: the WMS4 chrome policy matches the shared parity values (drift guard)" {
    const p = wnd_core.chrome_parity_policy();
    try std.testing.expectEqual(policy_kind, p.kind);
    try std.testing.expectEqual(policy_flags, p.flags);
    try std.testing.expectEqual(policy_border_rgb, p.border_rgb);
    try std.testing.expectEqual(policy_border_unfocus_rgb, p.border_unfocus_rgb);
    try std.testing.expectEqual(policy_title_bg_rgb, p.title_bg_rgb);
    try std.testing.expectEqual(policy_title_fg_rgb, p.title_fg_rgb);
    try std.testing.expectEqual(policy_ring_rgb, p.ring_rgb);
    try std.testing.expectEqual(policy_close_rgb, p.close_rgb);
    try std.testing.expectEqual(policy_min_rgb, p.min_rgb);
    try std.testing.expectEqual(policy_pin_rgb, p.pin_rgb);
    // The descriptor itself validates under the kernel's single refusal rule.
    try std.testing.expect(wnd_core.chrome_valid(p));
}

test "wnd: the marker/tuning shapes are pinned (live-gate grep targets)" {
    try std.testing.expectEqualStrings("wnd: registered\n", registered_marker);
    try std.testing.expectEqual(@as(usize, 16), registered_marker.len);
    try std.testing.expectEqualStrings("wnd: present\n", present_marker);
    try std.testing.expectEqual(@as(usize, 13), present_marker.len);
    try std.testing.expectEqual(@as(u32, 2), present_every);
    try std.testing.expectEqual(@as(u32, 1), marker_every);
    try std.testing.expectEqual(@as(u64, 18), composite_tick_kind);
    // WMS5: the drag markers + kinds (the live gate greps these).
    try std.testing.expectEqualStrings("wnd: grab\n", grab_marker);
    try std.testing.expectEqual(@as(usize, 10), grab_marker.len);
    try std.testing.expectEqualStrings("wnd: drag\n", drag_marker);
    try std.testing.expectEqual(@as(usize, 10), drag_marker.len);
    try std.testing.expectEqualStrings("wnd: drop\n", drop_marker);
    try std.testing.expectEqual(@as(usize, 10), drop_marker.len);
    try std.testing.expectEqual(@as(u64, 19), wm_pointer_kind);
    try std.testing.expectEqual(@as(u64, 20), wm_window_kind);
    try std.testing.expectEqual(@as(u64, 21), wm_key_kind);
    try std.testing.expectEqual(@as(u8, 0x01), btn_left);
    // WMS5 Gate 2: the policy markers + chords are pinned too.
    try std.testing.expectEqualStrings("wnd: tile\n", tile_marker);
    try std.testing.expectEqualStrings("wnd: snap\n", snap_marker);
    try std.testing.expectEqualStrings("wnd: min\n", min_marker);
    try std.testing.expectEqualStrings("wnd: max\n", max_marker);
    try std.testing.expectEqualStrings("wnd: ws\n", ws_marker);
    try std.testing.expectEqualStrings("wnd: fs\n", fs_marker);
    try std.testing.expectEqualStrings("wnd: aot\n", aot_marker);
    try std.testing.expectEqualStrings("wnd: alt-tab", alt_tab_marker);
    try std.testing.expectEqual(@as(u8, 0x2b), usage_tab);
    try std.testing.expectEqual(@as(u64, 5), wmctl_alt_tab);
    try std.testing.expectEqual(@as(u64, 3), alt_tab_commit);
    // M37 DQ1 (issue #836): the god-menu markers + Ctrl+Space chord.
    try std.testing.expectEqualStrings("wnd: god-menu open\n", god_menu_open_marker);
    try std.testing.expectEqualStrings("wnd: god-menu close\n", god_menu_close_marker);
    try std.testing.expectEqualStrings("wnd: god-menu exec", god_menu_exec_marker);
    try std.testing.expectEqual(@as(u8, 0x2c), usage_space);
    // M37 DQ3 (issue #839): the tab-drag transition marker.
    try std.testing.expectEqualStrings("wnd: tab-drag", tab_drag_marker);
    // WMS6 Gate B (issue #626): the notification-center markers + subcommands.
    try std.testing.expectEqualStrings("wnd: notif-open\n", notif_open_marker);
    try std.testing.expectEqualStrings("wnd: notif-close\n", notif_close_marker);
    try std.testing.expectEqualStrings("wnd: notif-clear\n", notif_clear_marker);
    try std.testing.expectEqualStrings("wnd: notif-dismiss\n", notif_dismiss_marker);
    try std.testing.expectEqual(@as(u64, 6), wmctl_notif_center);
    try std.testing.expectEqual(@as(u64, 7), wmctl_notif_dismiss);
    try std.testing.expectEqual(@as(u32, 80), tray_w);
    // WMS6 Gate C (issue #626): the tooltip markers + subcommand.
    try std.testing.expectEqualStrings("wnd: tooltip\n", tooltip_show_marker);
    try std.testing.expectEqualStrings("wnd: tooltip-hide\n", tooltip_hide_marker);
    try std.testing.expectEqualStrings("Clock", tray_tooltip_text);
    try std.testing.expectEqual(@as(u64, 8), wmctl_tooltip);
    try std.testing.expectEqual(@as(u64, 1), tooltip_show_act);
    try std.testing.expectEqual(@as(u64, 0), tooltip_hide_act);
    // WMS6 Gate D (issue #626): the dock marker + labels + subcommand.
    try std.testing.expectEqualStrings("wnd: dock", dock_marker);
    try std.testing.expectEqualStrings("Calc", dock_labels[0]);
    try std.testing.expectEqualStrings("Notes", dock_labels[1]);
    try std.testing.expectEqualStrings("Terminal", dock_labels[2]);
    try std.testing.expectEqualStrings("Browser", dock_labels[3]);
    try std.testing.expectEqualStrings("Settings", dock_labels[4]);
    try std.testing.expectEqual(@as(u64, 9), wmctl_dock);
    // WM3 (issue #707 card 3): the taskbar marker + subcommand + shared rule.
    try std.testing.expectEqualStrings("wnd: taskbar", taskbar_marker);
    try std.testing.expectEqual(@as(u64, 12), wmctl_taskbar);
    try std.testing.expectEqual(@as(u32, 3), taskbar_ws_count);
    try std.testing.expectEqual(@as(u32, 80), wnd_core.taskbar_entries_x0(taskbar_ws_count));
    try std.testing.expectEqual(@as(u32, 0), wnd_core.taskbar_entry_at(taskbar_ws_count, fb_w, fb_h, tray_w, 100, fb_h - 10).?);
    try std.testing.expect(wnd_core.taskbar_entry_at(taskbar_ws_count, fb_w, fb_h, tray_w, fb_w - 40, fb_h - 10) == null);
    // WM4 (issue #707 card 4): the rest-opacity policy is a real blend
    // (below 256) and the snap-bracket polish constants are pinned.
    try std.testing.expectEqual(@as(u32, 240), wm_rest_alpha_policy);
    try std.testing.expect(wm_rest_alpha_policy > 0 and wm_rest_alpha_policy < 256);
    try std.testing.expectEqual(@as(u32, 16), snap_preview_tick);
    try std.testing.expectEqual(@as(u32, 8), snap_preview_gap);
    // WMS6 Gate E (issue #626): the tray marker + policy constants.
    try std.testing.expectEqualStrings("wnd: tray", tray_marker);
    try std.testing.expectEqual(@as(u8, 'D'), tray_theme_letter);
    try std.testing.expectEqual(@as(u64, 10), tray_refresh_every);
    try std.testing.expectEqual(@as(u64, 10), wmctl_tray);
    try std.testing.expectEqual(@as(u64, 39), sys_clipboard_get);
    // WMS7 Gate A (issue #627): the mailbox-service marker + slot consts.
    try std.testing.expectEqualStrings("wnd: mail", mail_marker);
    try std.testing.expectEqual(@as(u64, 6), sys_ipc_recv);
    try std.testing.expectEqual(@as(u64, 5), sys_ipc_send);
    try std.testing.expectEqual(@as(usize, 64), mail_inbox_max);
    try std.testing.expectEqual(@as(u8, 0x17), usage_t);
    try std.testing.expectEqual(@as(u8, 0x10), usage_m);
    try std.testing.expectEqual(@as(u8, 0x11), usage_n);
    // WMS8 Gate 2 (issue #628): the about-dialog channel — subcommand 11,
    // toggle action 2, the Ctrl+Shift+A HID usage, and the decision marker
    // (the live gate greps `wnd: about`).
    try std.testing.expectEqualStrings("wnd: about\n", about_marker);
    try std.testing.expectEqual(@as(u64, 11), wmctl_dialog);
    try std.testing.expectEqual(@as(u64, 2), dialog_toggle_act);
    try std.testing.expectEqual(@as(u8, 0x04), usage_a);
    // WMS8 Gate 4 (issue #628): the unsaved-dialog channel — DIALOG actions
    // 3-6, the decision markers, and the mirror's unsaved bit (12).
    try std.testing.expectEqualStrings("wnd: unsaved-dialog\n", unsaved_dialog_marker);
    try std.testing.expectEqualStrings("wnd: unsaved-save\n", unsaved_save_marker);
    try std.testing.expectEqualStrings("wnd: unsaved-discard\n", unsaved_discard_marker);
    try std.testing.expectEqualStrings("wnd: unsaved-cancel\n", unsaved_cancel_marker);
    try std.testing.expectEqual(@as(u64, 3), dialog_unsaved_show);
    try std.testing.expectEqual(@as(u64, 4), dialog_unsaved_save);
    try std.testing.expectEqual(@as(u64, 5), dialog_unsaved_dont_save);
    try std.testing.expectEqual(@as(u64, 6), dialog_unsaved_cancel);
    try std.testing.expectEqual(@as(u32, 200), wnd_core.unsaved_dialog_w);
    try std.testing.expectEqual(@as(u32, 100), wnd_core.unsaved_dialog_h);
}

test "wnd: the WMS6 tray policy formats HH:MM and issues TRAY on change only" {
    // The WM's clock mirrors the shim's minute-rollover formula (parity).
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("00:00", format_wm_hhmm(&buf, 0));
    try std.testing.expectEqualStrings("00:01", format_wm_hhmm(&buf, 60));
    try std.testing.expectEqualStrings("01:00", format_wm_hhmm(&buf, 3600));
    try std.testing.expectEqualStrings("12:34", format_wm_hhmm(&buf, 12 * 3600 + 34 * 60));
    // The policy issues on the FIRST refresh (content differs from unset)...
    var st: TrayState = .{};
    try std.testing.expect(tray_tick_policy(0, false, &st));
    try std.testing.expect(st.clock_set);
    // ...and not again while the content is unchanged (mirrors the shim drain).
    try std.testing.expect(!tray_tick_policy(5, false, &st));
    // A minute rollover re-issues.
    try std.testing.expect(tray_tick_policy(60, false, &st));
    // A clipboard change re-issues.
    try std.testing.expect(tray_tick_policy(61, true, &st));
    try std.testing.expect(!tray_tick_policy(62, true, &st));
}

test "wnd: WM3 taskbar enumeration is id-ascending and workspace-filtered" {
    mirrors = @as([max_user_windows]MirrorWin, @splat(@as(MirrorWin, .{})));
    current_workspace = 0;
    // Slot order == id order (mirrors[si] is id 2+si): id 2 (ws 0),
    // id 3 (ws 1 — filtered), id 4 (ws 0), id 5 (invalid — filtered).
    mirrors[0] = .{ .id = 2, .valid = true, .workspace = 0 };
    mirrors[1] = .{ .id = 3, .valid = true, .workspace = 1 };
    mirrors[2] = .{ .id = 4, .valid = true, .workspace = 0 };
    var ids: [max_user_windows]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), taskbar_entry_ids(&ids));
    try std.testing.expectEqual(@as(u8, 2), ids[0]);
    try std.testing.expectEqual(@as(u8, 4), ids[1]);
    // The hit-test maps entry rects to ids: entry 0 -> id 2, entry 1 -> id 4.
    try std.testing.expectEqual(@as(u8, 2), taskbar_window_at(100, fb_h - 10).?);
    try std.testing.expectEqual(@as(u8, 4), taskbar_window_at(180, fb_h - 10).?);
    // A switcher click (x < entries x0) and a tray click are not entries.
    try std.testing.expect(taskbar_window_at(14, fb_h - 10) == null);
    try std.testing.expect(taskbar_window_at(fb_w - 40, fb_h - 10) == null);
    // A third current-workspace window takes entry 2 (all three rects fit
    // left of the tray at this ws_count — the kernel clamps past that).
    mirrors[3] = .{ .id = 5, .valid = true, .workspace = 0 };
    try std.testing.expectEqual(@as(usize, 3), taskbar_entry_ids(&ids));
    try std.testing.expectEqual(@as(u8, 5), taskbar_window_at(260, fb_h - 10).?);
    // Other-workspace mirrors are invisible to the enumeration.
    current_workspace = 1;
    try std.testing.expectEqual(@as(usize, 1), taskbar_entry_ids(&ids));
    try std.testing.expectEqual(@as(u8, 3), ids[0]);
    mirrors = @as([max_user_windows]MirrorWin, @splat(@as(MirrorWin, .{})));
    current_workspace = 0;
}

test "wnd: the WMS5 drag-grab rule matches the shared title-bar rule (drift guard)" {
    const g = wnd_core.Geom{ .id = 2, .kind = .user, .x = 100, .y = 100, .w = 400, .h = 300, .visible = true, .workspace = 0 };
    try std.testing.expect(wnd_core.title_bar_contains(g, 100, 100)); // top-left
    try std.testing.expect(wnd_core.title_bar_contains(g, 300, 115)); // mid band
    try std.testing.expect(!wnd_core.title_bar_contains(g, 300, 116)); // one below the band
    try std.testing.expect(!wnd_core.title_bar_contains(g, 300, 200)); // client area
    try std.testing.expectEqual(@as(usize, 16), wnd_core.title_bar_h);
    // The kernel re-exports the SAME number (no second constant to drift).
    _ = wnd_core.hit_test;
}

test "wnd: the WMS6 dock icon hit-test matches the shim's grid (drift guard)" {
    // The shim's M15 C4 grid: 20×20 icons at (2, 8+idx*32), 5 icons.
    try std.testing.expectEqual(@as(?u8, 0), dock_icon_at(12, 18)); // icon 0 center
    try std.testing.expectEqual(@as(?u8, 1), dock_icon_at(12, 40)); // icon 1 (8+32)
    try std.testing.expectEqual(@as(?u8, 4), dock_icon_at(12, 8 + 4 * 32 + 5)); // icon 4
    try std.testing.expectEqual(@as(?u8, 1), dock_icon_at(12, 8 + 1 * 32 + 19)); // icon 1 bottom edge
    // The 12 px gap between icons (20 px box, 32 px pitch) is a miss.
    try std.testing.expectEqual(@as(?u8, null), dock_icon_at(12, 8 + 20));
    // Outside the icon x-band / below the 5 icons is a miss.
    try std.testing.expectEqual(@as(?u8, null), dock_icon_at(0, 18)); // left of the band
    try std.testing.expectEqual(@as(?u8, null), dock_icon_at(22, 18)); // right of the band
    try std.testing.expectEqual(@as(?u8, null), dock_icon_at(12, 8 + 5 * 32)); // below icon 4
}

test "wnd: the WMS6 Alt+Tab target rule (drift guard against the shim snapshot)" {
    // Two visible windows on the current workspace (mirrors built from kind-20).
    // Zero-fill FIRST: `= undefined` left slots 4+ with garbage `.valid` bits
    // that made this drift guard flaky standalone (the pure rule iterates the
    // WHOLE table; unset slots must read `valid=false`, as in the zeroed BSS
    // of the real EL0 binary). Pre-existing Gate-A bug, fixed with Gate E.
    mirrors = @as([max_user_windows]MirrorWin, @splat(@as(MirrorWin, .{})));
    mirrors[0] = MirrorWin{ .id = 2, .visible = true, .workspace = 0, .valid = true, .focused = true };
    mirrors[1] = MirrorWin{ .id = 3, .visible = true, .workspace = 0, .valid = true, .focused = false };
    // Hidden + off-workspace windows never cycled (M21 W3/W4).
    mirrors[2] = MirrorWin{ .id = 4, .visible = true, .workspace = 1, .valid = true, .focused = false };
    mirrors[3] = MirrorWin{ .id = 5, .visible = false, .workspace = 0, .valid = true, .focused = false };
    current_workspace = 0;
    // Focused (2) -> next is 3.
    try std.testing.expectEqual(@as(?u8, 3), next_alt_tab_target());
    // One candidate only (hide 3) -> null (shim no-op).
    mirrors[1].visible = false;
    try std.testing.expectEqual(@as(?u8, null), next_alt_tab_target());
    mirrors[1].visible = true;
    // A stale/corrupt mirror slot (id < 2) is skipped, not a target — with
    // TWO real candidates left (3, 5) the cycle runs over them only (no
    // focused window -> start at slot 0 -> next is 5; the corrupt id-1 slot
    // is never selected). Pre-existing Gate-A assertion bug (it expected 3
    // with a single candidate, which the rule correctly no-ops), fixed with
    // Gate E.
    mirrors[0].id = 1;
    mirrors[0].focused = false;
    mirrors[3].visible = true;
    try std.testing.expectEqual(@as(?u8, 5), next_alt_tab_target());
}

test "wnd: the WMS5 Gate 2 policy issues the SAME rects as the kernel shim (drift guard)" {
    // The WM's tile layout must match the kernel's apply_tile_layout numbers
    // (master 2/3 left, detail 1/3 right on a 1280x720 scanout with the
    // 20 px taskbar + 24 px dock).
    const tl = wnd_core.tile_layout(fb_w, fb_h, taskbar_h, dock_w, 667, true);
    try std.testing.expectEqual(@as(u32, 1256), tl.master_w + tl.detail_w);
    try std.testing.expectEqual(@as(u32, 837), tl.master_w);
    try std.testing.expectEqual(@as(u32, 419), tl.detail_w);
    try std.testing.expectEqual(@as(u32, 24), tl.master_x);
    try std.testing.expectEqual(@as(u32, 24 + 837), tl.detail_x);
    try std.testing.expectEqual(@as(u32, 700), tl.h); // 720 - 20 taskbar
    // Maximize = the workspace area (dock + taskbar excluded).
    const mx = wnd_core.maximize_rect(fb_w, fb_h, taskbar_h, dock_w);
    try std.testing.expectEqual(@as(u32, 24), mx.x);
    try std.testing.expectEqual(@as(u32, 0), mx.y);
    try std.testing.expectEqual(@as(u32, 1256), mx.w);
    try std.testing.expectEqual(@as(u32, 700), mx.h);
    // Snap bounds (M15 C3) — left half, taskbar excluded.
    const lb = wnd_core.snap_zone_bounds(.left, fb_w, fb_h, taskbar_h).?;
    try std.testing.expectEqual(@as(u32, 640), lb.w);
    try std.testing.expectEqual(@as(u32, 700), lb.h);
    // The WM's mirrored constants are the SAME numbers (no drift).
    try std.testing.expectEqual(wnd_core.fb_w, fb_w);
    try std.testing.expectEqual(wnd_core.taskbar_h, taskbar_h);
    try std.testing.expectEqual(wnd_core.dock_w, dock_w);
}

test "wnd: dq5 snap preview maps the pointer to zone bounds (8 zones + none)" {
    // M37 DQ5 (issue #837): the preview rect IS the snap zone's bounds
    // (1280x720 scanout, 20 px taskbar excluded from bottom zones).
    const l = snap_preview_for_point(5, 360).?;
    try std.testing.expectEqual(wnd_core.SnapZone.left, l.zone);
    try std.testing.expectEqual([4]u32{ 0, 0, 640, 700 }, [4]u32{ l.x, l.y, l.w, l.h });
    const r = snap_preview_for_point(fb_w - 5, 360).?;
    try std.testing.expectEqual(wnd_core.SnapZone.right, r.zone);
    try std.testing.expectEqual([4]u32{ 640, 0, 640, 700 }, [4]u32{ r.x, r.y, r.w, r.h });
    const t = snap_preview_for_point(640, 5).?;
    try std.testing.expectEqual(wnd_core.SnapZone.top, t.zone);
    try std.testing.expectEqual([4]u32{ 0, 0, 1280, 350 }, [4]u32{ t.x, t.y, t.w, t.h });
    const b = snap_preview_for_point(640, fb_h - 5).?;
    try std.testing.expectEqual(wnd_core.SnapZone.bottom, b.zone);
    try std.testing.expectEqual([4]u32{ 0, 350, 1280, 350 }, [4]u32{ b.x, b.y, b.w, b.h });
    const tl = snap_preview_for_point(5, 5).?;
    try std.testing.expectEqual(wnd_core.SnapZone.top_left, tl.zone);
    try std.testing.expectEqual([4]u32{ 0, 0, 640, 350 }, [4]u32{ tl.x, tl.y, tl.w, tl.h });
    const tr = snap_preview_for_point(fb_w - 5, 5).?;
    try std.testing.expectEqual(wnd_core.SnapZone.top_right, tr.zone);
    try std.testing.expectEqual([4]u32{ 640, 0, 640, 350 }, [4]u32{ tr.x, tr.y, tr.w, tr.h });
    const bl = snap_preview_for_point(5, fb_h - 5).?;
    try std.testing.expectEqual(wnd_core.SnapZone.bottom_left, bl.zone);
    try std.testing.expectEqual([4]u32{ 0, 350, 640, 350 }, [4]u32{ bl.x, bl.y, bl.w, bl.h });
    const br = snap_preview_for_point(fb_w - 5, fb_h - 5).?;
    try std.testing.expectEqual(wnd_core.SnapZone.bottom_right, br.zone);
    try std.testing.expectEqual([4]u32{ 640, 350, 640, 350 }, [4]u32{ br.x, br.y, br.w, br.h });
    // Center = free (no preview while dragging mid-screen).
    try std.testing.expect(snap_preview_for_point(640, 360) == null);
}

test "wnd: dq5 snap preview threshold edges (20 px, corners first)" {
    // Horizontal edges: near_left is x < 20; near_right is x + 20 >= 1280.
    try std.testing.expectEqual(wnd_core.SnapZone.left, snap_preview_for_point(19, 360).?.zone);
    try std.testing.expect(snap_preview_for_point(20, 360) == null);
    try std.testing.expect(snap_preview_for_point(1259, 360) == null);
    try std.testing.expectEqual(wnd_core.SnapZone.right, snap_preview_for_point(1260, 360).?.zone);
    // Vertical edges: near_top is y < 20; near_bottom is y + 20 >= 720.
    try std.testing.expectEqual(wnd_core.SnapZone.top, snap_preview_for_point(640, 19).?.zone);
    try std.testing.expect(snap_preview_for_point(640, 20) == null);
    try std.testing.expect(snap_preview_for_point(640, 699) == null);
    try std.testing.expectEqual(wnd_core.SnapZone.bottom, snap_preview_for_point(640, 700).?.zone);
    // Corners take precedence over edges at every corner.
    try std.testing.expectEqual(wnd_core.SnapZone.top_left, snap_preview_for_point(0, 0).?.zone);
    try std.testing.expectEqual(wnd_core.SnapZone.top_right, snap_preview_for_point(1279, 0).?.zone);
    try std.testing.expectEqual(wnd_core.SnapZone.bottom_left, snap_preview_for_point(0, 719).?.zone);
    try std.testing.expectEqual(wnd_core.SnapZone.bottom_right, snap_preview_for_point(1279, 719).?.zone);
}

test "wnd: dq5 snap preview styling defers to DQ4 tokens" {
    // The outline band is the DQ4 focus-outline metric, in the DQ4 accent.
    try std.testing.expectEqual(ui.focus_w, snap_preview_thick);
    try std.testing.expectEqual(@as(u32, 2), snap_preview_thick);
    _ = ui.set_theme("dark");
    try std.testing.expectEqual(@as(u32, 0x3b82f6), ui.theme_accent());
    // The decision marker prefix is pinned (the live gate greps it).
    try std.testing.expectEqualStrings("wnd: snap-preview", snap_preview_marker);
    // The tick-redraw marker is pinned (per-tick restore proof).
    try std.testing.expectEqualStrings("wnd: snap-tick\n", snap_tick_marker);
    // The settled marker + count are pinned (the live gate snapshots after
    // it — the clean window, ~8 s of continuous restore).
    try std.testing.expectEqualStrings("wnd: snap-settled\n", snap_settled_marker);
    try std.testing.expectEqual(@as(u32, 8), snap_settled_ticks);
}

test "wnd: hid_to_ascii maps keyboard usages accurately" {
    try std.testing.expectEqual(@as(?u8, 'a'), hid_to_ascii(0x04, false));
    try std.testing.expectEqual(@as(?u8, 'A'), hid_to_ascii(0x04, true));
    try std.testing.expectEqual(@as(?u8, 'z'), hid_to_ascii(0x1d, false));
    try std.testing.expectEqual(@as(?u8, 'Z'), hid_to_ascii(0x1d, true));
    try std.testing.expectEqual(@as(?u8, '1'), hid_to_ascii(0x1e, false));
    try std.testing.expectEqual(@as(?u8, '!'), hid_to_ascii(0x1e, true));
    try std.testing.expectEqual(@as(?u8, ' '), hid_to_ascii(usage_space, false));
    try std.testing.expectEqual(@as(?u8, '\n'), hid_to_ascii(0x28, false));
    try std.testing.expectEqual(@as(?u8, 0x08), hid_to_ascii(0x2a, false));
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii(0x29, false)); // Escape
}

test "wnd: dq1 app verb stems and bin lookup" {
    var vbuf: [24]u8 = undefined;
    var n = app_verb_for("NOTEPAD.BIN", &vbuf);
    try std.testing.expectEqualStrings("notepad", vbuf[0..n]);
    n = app_verb_for("GOCALC.ELF", &vbuf);
    try std.testing.expectEqualStrings("gocalc", vbuf[0..n]);
    n = app_verb_for("FILE", &vbuf);
    try std.testing.expectEqualStrings("file", vbuf[0..n]);
    n = app_verb_for("", &vbuf);
    try std.testing.expectEqual(@as(usize, 0), n);
    n = app_verb_for("DEVCONS.BIN", vbuf[0..4]);
    try std.testing.expectEqualStrings("devc", vbuf[0..n]);

    // Empty table (host: manifest never loads) resolves nothing.
    god_menu_app_count = 0;
    try std.testing.expect(god_menu_bin_for("gocalc") == null);

    // A loaded entry resolves verb → bin.
    @memcpy(god_menu_app_verbs[0][0..6], "gocalc");
    god_menu_app_verb_lens[0] = 6;
    @memcpy(god_menu_app_bins[0][0..10], "GOCALC.ELF");
    god_menu_app_bin_lens[0] = 10;
    god_menu_app_count = 1;
    const bin = god_menu_bin_for("gocalc").?;
    try std.testing.expectEqualStrings("GOCALC.ELF", bin);
    try std.testing.expect(god_menu_bin_for("nope") == null);
    god_menu_app_count = 0;
}

test "wnd: dq1 selection over a 22-entry manifest caps at 16, dock-first" {
    // Mirror image/apps.txt shape: 8 dock + dup stems past the cutoff. The
    // 8 is pinned against the REAL file by sexiburger.zig's manifest tests
    // (which a gate runs); this fixture stays synthetic on purpose, because
    // it is about the cap and the duplicate stems, not about the catalog.
    var parsed: [22]sexiburger.MenuApp = undefined;
    const names = [_][]const u8{ "GOCALC.ELF", "NOTEPAD.BIN", "TOP.BIN", "KEYTEST.BIN", "TYPE.BIN", "DIR.BIN", "FETCH.BIN", "CHAT.BIN", "FILE.BIN", "SETTINGS.BIN", "EDIT.BIN", "SYSMON.BIN", "HTTPD.BIN", "DYNAPP.ELF", "GOCALC.ELF", "NOTEPAD.ELF", "FILE.ELF", "DESKTOP.ELF", "ZC.BIN", "SEXIBURG.BIN", "VIEW.BIN", "SEXITEST.BIN" };
    const descs = [_][]const u8{ "Calc", "Editor", "Tasks", "Keys", "Type", "Dir", "Fetch", "Chat", "Files", "Settings", "Edit", "Sysmon", "Http", "Dyn", "Calc2", "Edit2", "Files2", "Desk", "Zc", "Sexi", "View", "Stest" };
    for (names, 0..) |nm, i| {
        parsed[i] = .{ .name = nm, .desc = descs[i], .dock = i == 0 or i == 1 or i == 2 or i == 8 or i == 9 or i == 11 or i == 13 or i == 19 };
    }
    const count = select_god_menu_apps(&parsed);
    try std.testing.expectEqual(@as(usize, 16), count);
    // All 8 dock entries survive (incl. SEXIBURG past the old cutoff).
    for ([_][]const u8{ "gocalc", "notepad", "top", "file", "settings", "sysmon", "dynapp", "sexiburg" }) |verb| {
        try std.testing.expect(god_menu_bin_for(verb) != null);
    }
    // Duplicate stems resolve to the FIRST (BIN) entry.
    try std.testing.expectEqualStrings("GOCALC.ELF", god_menu_bin_for("gocalc").?);
    try std.testing.expectEqualStrings("NOTEPAD.BIN", god_menu_bin_for("notepad").?);
    // Nondock tail fills the rest; entries past the cap are absent.
    try std.testing.expect(god_menu_bin_for("desktop") != null);
    try std.testing.expect(god_menu_bin_for("view") == null);
    try std.testing.expect(god_menu_bin_for("stest") == null);
    god_menu_app_count = 0;
}

test "wnd: dq1 theme toggle flips mode (host: flag only)" {
    god_menu_dark = true;
    try std.testing.expectEqualStrings("light", toggle_god_menu_theme());
    try std.testing.expectEqualStrings("dark", toggle_god_menu_theme());
}

test "wnd: dq1 id-suffix parse accepts 2..9, rejects the rest" {
    try std.testing.expectEqual(@as(?u8, 2), parse_id_suffix("win-2", "win-"));
    try std.testing.expectEqual(@as(?u8, 5), parse_id_suffix("tab-5", "tab-"));
    try std.testing.expectEqual(@as(?u8, 9), parse_id_suffix("win-9", "win-"));
    try std.testing.expect(parse_id_suffix("win-1", "win-") == null);
    try std.testing.expect(parse_id_suffix("win-10", "win-") == null);
    try std.testing.expect(parse_id_suffix("win-", "win-") == null);
    try std.testing.expect(parse_id_suffix("win-x", "win-") == null);
    try std.testing.expect(parse_id_suffix("tab-3", "win-") == null);
    try std.testing.expect(parse_id_suffix("win-22", "win-") == null);
}

test "wnd: dq1 windows+tabs populate from mirrors with tab entries" {
    mirrors[0] = .{ .id = 2, .valid = true, .visible = true, .focused = true };
    mirrors[1] = .{ .id = 3, .valid = true, .visible = true, .tab_parent = 2, .tab_active = false };
    defer {
        mirrors[0] = .{};
        mirrors[1] = .{};
    }
    populate_god_menu();
    var cmds: [16]Command = undefined;
    const n = god_menu.registry.get_section_commands(.windows_tabs, &cmds);
    try std.testing.expect(n >= 4); // win + tab + next + close
    var saw_win = false;
    var saw_tab = false;
    var saw_next = false;
    for (cmds[0..n]) |c| {
        if (std.mem.eql(u8, c.verb, "win-2")) {
            saw_win = true;
            try std.testing.expectEqualStrings("Window 2 *", c.label);
        }
        if (std.mem.eql(u8, c.verb, "tab-3")) {
            saw_tab = true;
            try std.testing.expectEqualStrings("Tab 3 (in 2)", c.label);
        }
        if (std.mem.eql(u8, c.verb, "tab-next")) saw_next = true;
    }
    try std.testing.expect(saw_win and saw_tab and saw_next);
}

test "wnd: dq3 tab hit-testing over mirrors (cells, close, misses)" {
    mirrors[0] = .{ .id = 2, .x = 56, .y = 56, .w = 512, .h = 384, .valid = true, .visible = true, .focused = true };
    mirrors[1] = .{ .id = 3, .x = 56, .y = 56, .w = 512, .h = 384, .valid = true, .visible = true, .tab_parent = 2, .tab_active = false };
    defer {
        mirrors[0] = .{};
        mirrors[1] = .{};
        tab_press_clear();
    }
    // Strip rows are 72..93 (title band 56..71 above, client below).
    const c0 = tab_hit_at(100, 80).?;
    try std.testing.expectEqual(@as(u8, 2), c0.container_id);
    try std.testing.expectEqual(@as(u8, 2), c0.tab_id);
    try std.testing.expect(!c0.on_close);
    const c1 = tab_hit_at(400, 80).?;
    try std.testing.expectEqual(@as(u8, 3), c1.tab_id);
    try std.testing.expect(!c1.on_close);
    // × boxes: cell0 right end + cell1 right end.
    const x0 = tab_hit_at(305, 80).?;
    try std.testing.expectEqual(@as(u8, 2), x0.tab_id);
    try std.testing.expect(x0.on_close);
    const x1 = tab_hit_at(560, 80).?;
    try std.testing.expectEqual(@as(u8, 3), x1.tab_id);
    try std.testing.expect(x1.on_close);
    // Misses: title rows, client area, outside.
    try std.testing.expect(tab_hit_at(56, 60) == null);
    try std.testing.expect(tab_hit_at(100, 200) == null);
    try std.testing.expect(tab_hit_at(10, 10) == null);
    // Plain window (child detached): no strip anywhere.
    mirrors[1].tab_parent = 0;
    try std.testing.expect(tab_hit_at(100, 80) == null);
    mirrors[1].tab_parent = 2;
    // Hidden container: no strip.
    mirrors[0].visible = false;
    try std.testing.expect(tab_hit_at(100, 80) == null);
    mirrors[0].visible = true;
}

test "wnd: dq3 drag threshold (Chebyshev > 12px)" {
    try std.testing.expect(!tab_drag_exceeded(100, 100, 105, 105));
    try std.testing.expect(!tab_drag_exceeded(100, 100, 112, 100));
    try std.testing.expect(tab_drag_exceeded(100, 100, 113, 100));
    try std.testing.expect(tab_drag_exceeded(100, 100, 100, 113));
    try std.testing.expect(tab_drag_exceeded(400, 80, 400, 200));
}

test "wnd: god menu init, 6-section population, and type-to-filter" {
    populate_god_menu();
    try std.testing.expect(god_menu_initialized);
    try std.testing.expect(god_menu_mascot_loaded);
    try std.testing.expect(god_menu.raster_mascot != null);
    try std.testing.expectEqual(@as(u32, 24), god_menu.raster_mascot.?.width);
    try std.testing.expectEqual(@as(u32, 24), god_menu.raster_mascot.?.height);

    // Verify sections have commands
    var sec0_cmds: [16]Command = undefined;
    const sec0_cnt = god_menu.registry.get_section_commands(.system, &sec0_cmds);
    try std.testing.expect(sec0_cnt >= 4);

    var sec1_cmds: [16]Command = undefined;
    const sec1_cnt = god_menu.registry.get_section_commands(.apps, &sec1_cmds);
    try std.testing.expect(sec1_cnt >= 3);

    // Verify type-to-filter in God Menu
    god_menu.set_search_query("calc");
    try std.testing.expect(god_menu.filtered_count > 0);
    try std.testing.expectEqualStrings("calc", god_menu.filtered[0].command.verb);

    god_menu.set_search_query("about");
    try std.testing.expect(god_menu.filtered_count > 0);
    try std.testing.expectEqualStrings("about", god_menu.filtered[0].command.verb);
}

test "wnd: god menu key chord Ctrl+Space toggle and state" {
    // Ensure initial closed state
    god_menu_open = false;
    god_menu_win = null;

    // Simulate Ctrl+Space chord
    handle_wm_key(usage_space, mod_ctrl);
    try std.testing.expect(god_menu_initialized);
}

test "wnd: wallpaper render occlusion and blit logic" {
    var fake_scan = @as([(fb_w * fb_h)]u32, @splat(@as(u32, 0xFF000000)));
    var fake_bg = @as([(fb_w * fb_h)]u32, @splat(@as(u32, 0xFF123456)));

    scanout_ptr = &fake_scan;
    scanout_mapped = true;
    wallpaper_bg_buf = &fake_bg;
    wallpaper_loaded = true;
    defer {
        scanout_ptr = null;
        scanout_mapped = false;
        wallpaper_bg_buf = null;
        wallpaper_loaded = false;
    }

    // Set a window at x=100, y=100, w=200, h=150
    mirrors[0] = .{
        .id = 2,
        .valid = true,
        .x = 100,
        .y = 100,
        .w = 200,
        .h = 150,
        .visible = true,
    };
    defer mirrors[0] = .{};

    render_wallpaper_root();

    // Dock region (x < dock_w) should remain unpainted (0xFF000000)
    try std.testing.expectEqual(@as(u32, 0xFF000000), fake_scan[50 * fb_w + 5]);

    // Root desktop pixel (x=50, y=50) should have wallpaper color
    try std.testing.expectEqual(@as(u32, 0xFF123456), fake_scan[50 * fb_w + 50]);

    // Inside window area (x=150, y=150) should be occluded and unpainted (0xFF000000)
    try std.testing.expectEqual(@as(u32, 0xFF000000), fake_scan[150 * fb_w + 150]);

    // Taskbar area (y >= fb_h - taskbar_h) should remain unpainted (0xFF000000)
    try std.testing.expectEqual(@as(u32, 0xFF000000), fake_scan[(fb_h - 10) * fb_w + 50]);
}

test "wnd: wm2 mirror covers ids 2..9 (the WM1 kernel ceiling)" {
    try std.testing.expectEqual(@as(?usize, 0), mirror_slot(2));
    try std.testing.expectEqual(@as(?usize, 3), mirror_slot(5));
    try std.testing.expectEqual(@as(?usize, 7), mirror_slot(9));
    try std.testing.expect(mirror_slot(1) == null);
    try std.testing.expect(mirror_slot(10) == null);
    try std.testing.expect(mirror_slot(0xff) == null);
}

test "wnd: wm2 card list is ascending over visible current-workspace mirrors" {
    const saved_ws = current_workspace;
    current_workspace = 0;
    mirrors[0] = .{ .id = 2, .valid = true, .visible = true, .workspace = 0 };
    mirrors[2] = .{ .id = 4, .valid = true, .visible = true, .workspace = 1 }; // other ws: skipped
    mirrors[3] = .{ .id = 5, .valid = true, .visible = false, .workspace = 0 }; // hidden: skipped
    mirrors[5] = .{ .id = 7, .valid = true, .visible = true, .workspace = 0 };
    defer {
        mirrors[0] = .{};
        mirrors[2] = .{};
        mirrors[3] = .{};
        mirrors[5] = .{};
        current_workspace = saved_ws;
    }
    const cards = overview_card_list();
    try std.testing.expectEqual(@as(usize, 2), cards.n);
    try std.testing.expectEqual(@as(u8, 2), cards.ids[0]);
    try std.testing.expectEqual(@as(u8, 7), cards.ids[1]);
}

test "wnd: wm2 grid click focuses the card under the cursor" {
    const saved_ws = current_workspace;
    current_workspace = 0;
    mirrors[0] = .{ .id = 2, .valid = true, .visible = true, .workspace = 0 };
    mirrors[1] = .{ .id = 3, .valid = true, .visible = true, .workspace = 0 };
    defer {
        mirrors[0] = .{};
        mirrors[1] = .{};
        current_workspace = saved_ws;
        overview_open = false;
        overview_press_id = 0;
    }
    // Two cards: grid is 2x1; card 1 spans x 648..1264, y 8..664.
    overview_open = true;
    try std.testing.expect(overview_pointer(900, 100, true, false)); // down on card 1
    try std.testing.expectEqual(@as(u8, 3), overview_press_id);
    try std.testing.expect(overview_pointer(900, 100, false, true)); // up: focus card 1
    try std.testing.expect(!overview_open); // a decision exits the grid
    // Move path: press card 0, release on workspace-1 strip button.
    overview_open = true;
    try std.testing.expect(overview_pointer(100, 100, true, false)); // down on card 0
    try std.testing.expectEqual(@as(u8, 2), overview_press_id);
    try std.testing.expect(overview_pointer(640, 690, false, true)); // up on WS 1 button
    try std.testing.expect(!overview_open);
    try std.testing.expectEqual(@as(u8, 1), current_workspace);
    current_workspace = saved_ws;
}

test "wnd: wm2 hotkey toggles the grid, Esc exits" {
    const saved_open = overview_open;
    defer overview_open = saved_open;
    overview_open = false;
    handle_wm_key(usage_f12, mod_ctrl); // Ctrl+F12 enters
    try std.testing.expect(overview_open);
    handle_wm_key(usage_f12, mod_ctrl); // re-press exits
    try std.testing.expect(!overview_open);
    handle_wm_key(usage_f12, mod_ctrl);
    try std.testing.expect(overview_open);
    handle_wm_key(usage_esc, 0); // Esc exits
    try std.testing.expect(!overview_open);
}
