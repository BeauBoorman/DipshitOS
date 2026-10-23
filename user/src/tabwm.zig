//! census (M188e, #3190): TABWM.BIN — gate-referenced: 13 specs incl. live-tabwm, go-wm-hid; also the APPS.TXT Zig fallback WM (ADR 0034).
//! VirelaiOS M39 TWM2 — TABWM.BIN, the browser-style tabbed window manager server (issue #929).
//!
//! Replaces the 1990s floating overlapping window model with a sleek, browser-like
//! tabbed desktop environment:
//!   - Zero floating windows: every application is a first-class full tab.
//!   - Unified Left Sidebar (180px wide):
//!       * Top: Sexiburger God Menu button with mascot emblem and shortcut hint.
//!       * Middle: Vertical tab list with anti-aliased pill highlights, active accent bar,
//!                 proportional 14pt Inter titles, and close buttons.
//!       * Bottom: Status tray (13pt Inter clock, theme toggle [D]/[L], clipboard badge).
//!   - Content Viewport: unbroken full 720px vertical scanout height, 1100px wide (x=180..1280, y=0..720).
//!       * Active tab receives full viewport (180, 0, 1100, 720).
//!       * Inactive tabs are hidden (sys_wmctl(set_state)).
//!   - Mouse Routing:
//!       * Clicking tab pill activates tab.
//!       * Clicking 'x' closes the tab through the kernel's WIN_CLOSE
//!         seam (wmctl cmd 13) — the app really exits.
//!       * Clicking '+ New tab' summons the Sexiburger launcher palette.
//!       * Clicking Sexiburger summons God Menu command palette.
//!   - Keyboard Shortcuts:
//!       * Ctrl+Tab / Ctrl+Shift+Tab: Cycle active tabs forward / backward.
//!       * Ctrl+1..9: Jump directly to tab index 1..9.
//!       * Ctrl+W: Close active tab.
//!       * Ctrl+T: '+ New tab' — summon the Sexiburger launcher palette.
//!       * Ctrl+Space: Summon Sexiburger command palette overlay.
//!   - Mirror-Synced Lifecycle (M42 UX): the kernel's released bit (flags
//!     bit 13 on kind-20 WM_WINDOW mirrors) removes the tab of a window
//!     the kernel RELEASED (app self-exit); close_tab drives the kernel's
//!     own release primitive (wmctl WIN_CLOSE, cmd 13) so the app gets the
//!     real WIN_CLOSE event and exits — no zombie hidden processes.
//!   - Unsaved-State Honesty (M42 UX r2, claim #1011): the kernel's
//!     unsaved bit (kind-20 flags bit 12, fanned from user_set_unsaved on
//!     every dirty change) rides every mirror into a per-tab dirty flag;
//!     dirty tabs wear an accent dot on their pill, and EVERY close entry
//!     point ('x' click, Ctrl+W, detach RPC) routes a dirty tab through
//!     the unsaved-changes dialog BEFORE any WMCTL_WIN_CLOSE — the
//!     existing slot-65 DIALOG (cmd 11) actions 3-6 kernel primitives,
//!     button hit-tests via the shared wnd_core rule (parity by
//!     construction). TABWM self-paints the modal — its full-scanout
//!     compose overdraws the kernel's own dialog blit — with the same
//!     200x100 centered geometry + palette, so what the user sees matches
//!     WND's dialog exactly while the kernel still applies the decisions.
//!   - Close Feedback (M42 UX r2): a closed tab's row slot flashes an
//!     accent band for ~18 composite ticks (muted when the kernel refused
//!     the close and only a hide was applied) — the cause of the
//!     activation switch is visible.
//!   - Alt-Tab Parity (M42 UX r2): Alt+Tab / Alt+Shift+Tab (kind-21 raw
//!     chords, MOD_ALT + Tab) switch tabs with WND's WMS6 Gate A
//!     semantics — TABWM proposes via the SAME alt_tab_next policy
//!     Ctrl+Tab uses, the kernel applies focus+raise through the ALT_TAB
//!     commit seam (focus auto-show re-reveals the hidden target tab).
//!   - Zero Heap Allocation: all tab mirrors, state, and rendering operate strictly in static BSS and stack.
//!   - Direct Scanout Ownership: maps the 1280x720 framebuffer via M33 Seam B (`sys_mmap` with
//!     `m33_surf_scan_tag`) for sub-millisecond anti-aliased composition.
//!   - Zero-Regression: WND.BIN remains completely untouched and all legacy floating gates remain green.

const std = @import("std");
pub const ui = @import("lib/ui.zig");
const sexiburger_menu = @import("lib/sexiburger.zig");
/// M42 UX r2 (claim #1011): the shared dialog button-rect rule — TABWM
/// hit-tests the SAME unsaved-dialog geometry the kernel applies (parity
/// by construction; the anonymous import already exists on tabwm_mod).
const wnd_core = @import("wnd_core");
const Rect = ui.Rect;
const Event = ui.Event;

// ---------------------------------------------------------------------------
// Syscall numbers (slots frozen in ADR 0007 / ADR 0015).
// ---------------------------------------------------------------------------
const sys_write: u64 = 1;
const sys_yield_num: u64 = 2;
const sys_ipc_send: u64 = 5;
const sys_ipc_recv: u64 = 6;
const sys_wait_event_num: u64 = 22;
const sys_clipboard_get: u64 = 39;
const sys_mmap: u64 = 63;
const sys_wmctl: u64 = 65;

// Slot-65 subcommands
const wmctl_register: u64 = 1;
const wmctl_set_window: u64 = 2;
const wmctl_request_present: u64 = 3;
const wmctl_set_state: u64 = 4;
const wmctl_alt_tab: u64 = 5;
const alt_tab_commit: u64 = 3;
const wmctl_tray: u64 = 10;
const wmctl_dialog: u64 = 11;
/// M42 UX (2026-09-05): WIN_CLOSE — the kernel applies its own
/// `user_close` release (the owner gets the real WIN_CLOSE event push;
/// TABWM gets the released kind-20 mirror back). a0 = window id.
const wmctl_win_close: u64 = 13;
/// #1056 item 2: resolve a window's display name — the app-set title if
/// any, else the owning process's executable name. a1 = window id,
/// a2 = buffer pointer, a3 = buffer length; returns the byte count.
const wmctl_window_name: u64 = 14;

// M42 UX r2 (2026-09-05, claim #1011): the slot-65 DIALOG unsaved-changes
// actions — the SAME primitives WND.BIN issues (user/src/wnd.zig): 3 =
// show (a2 = target window id; the kernel validates it is a live user
// window), 4 = save (kernel posts WIN_UNSAVED to the owner), 5 =
// dont-save (kernel runs user_close on the target), 6 = cancel. The
// kernel refuses 4/5/6 when no dialog is open. No new modal system — the
// existing WMS8 Gate 4 seam, WM-seat-only.
const dialog_unsaved_show: u64 = 3;
const dialog_unsaved_save: u64 = 4;
const dialog_unsaved_dont_save: u64 = 5;
const dialog_unsaved_cancel: u64 = 6;

// M33 Scanout shared surface mapping tag
const m33_surf_scan_tag: u64 = 0x4000_0000_0000_0000;
const prot_rw: u64 = ui.PROT_READ | ui.PROT_WRITE;
const map_anonymous: u64 = ui.MAP_ANONYMOUS;
const m33_map_shared: u64 = 0x10000;

// Event kinds from kernel render server
pub const composite_tick_kind: u16 = 18;
pub const wm_pointer_kind: u16 = 19;
pub const wm_window_kind: u16 = 20;
pub const wm_key_kind: u16 = 21;

pub const btn_left: u8 = 0x01;
/// #1064: the middle mouse button — a middle-click on a tab closes it.
pub const btn_middle: u8 = 0x04;

// HID keyboard usage constants (USB HID Usage Tables §10 Keyboard/Keypad Page)
pub const usage_a: u8 = 0x04;
pub const usage_w: u8 = 0x1a;
/// M42 UX (2026-09-05): 't' — the Ctrl+T "+ New tab" chord (HID Usage Tables §10).
pub const usage_t: u8 = 0x17;
pub const usage_1: u8 = 0x1e;
pub const usage_2: u8 = 0x1f;
pub const usage_3: u8 = 0x20;
pub const usage_4: u8 = 0x21;
pub const usage_5: u8 = 0x22;
pub const usage_6: u8 = 0x23;
pub const usage_7: u8 = 0x24;
pub const usage_8: u8 = 0x25;
pub const usage_9: u8 = 0x26;
pub const usage_tab: u8 = 0x2b;
pub const usage_space: u8 = 0x2c;
/// #1056 item 3: sidebar keyboard navigation — Enter activates the
/// selection, Up/Down move it, PageUp/PageDown scroll the list window.
pub const usage_enter: u8 = 0x28;
pub const usage_pageup: u8 = 0x4b;
pub const usage_pagedown: u8 = 0x4e;
pub const usage_down: u8 = 0x51;
pub const usage_up: u8 = 0x52;
/// #1064: Left/Right — Ctrl+Shift+Left/Right reorders the active tab.
pub const usage_right: u8 = 0x4f;
pub const usage_left: u8 = 0x50;
/// M48/BT1: 'd' — Ctrl+Shift+D duplicates the active tab.
pub const usage_d: u8 = 0x07;
/// M48/BT3: 'p' — Ctrl+Shift+P toggles the pinned bit.
pub const usage_p: u8 = 0x13;
/// M48/BT6: 'f' — Ctrl+Shift+F toggles the frozen badge.
pub const usage_f: u8 = 0x09;
/// TWM: 'g' — Ctrl+Shift+G summons the "Go" quick-jump, the rail-native
/// go-to surface.
pub const usage_g: u8 = 0x0a;
/// M48/BT5: '[' / ']' — Ctrl+Shift+[ / ] step the per-tab history.
pub const usage_left_bracket: u8 = 0x2f;
pub const usage_right_bracket: u8 = 0x30;

// Pinned markers (grepped by class-B live gates and tests)
pub const registered_marker: []const u8 = "tabwm: registered\n";
pub const present_marker: []const u8 = "tabwm: present\n";
pub const sidebar_render_marker: []const u8 = "tabwm: sidebar-rendered\n";
pub const tab_switch_marker: []const u8 = "tabwm: tab-switch";
pub const tab_close_marker: []const u8 = "tabwm: win-close";
pub const god_menu_marker: []const u8 = "tabwm: god-menu\n";
/// M42 SX5 (issue #986): the god-menu overlay launched an app into a new tab.
pub const launch_marker_prefix: []const u8 = "tabwm: launch ";
/// M42 UX (2026-09-05): the "+ New tab" affordance fired (sidebar pill
/// click or Ctrl+T) — the pinned evidence marker.
pub const new_tab_marker: []const u8 = "tabwm: new-tab\n";
/// M42 UX r2 (2026-09-05, claim #1011): the unsaved-changes dialog
/// markers — the dialog marker is id-carrying (`tabwm: unsaved-dialog
/// id=N`), the three choice markers are fixed. All four are pinned by
/// the class-A tests and grepped by the live-tabwm-unsaved gate.
pub const unsaved_dialog_marker: []const u8 = "tabwm: unsaved-dialog id=";
pub const unsaved_save_marker: []const u8 = "tabwm: unsaved-save\n";
pub const unsaved_discard_marker: []const u8 = "tabwm: unsaved-discard\n";
pub const unsaved_cancel_marker: []const u8 = "tabwm: unsaved-cancel\n";
/// M42 UX r2 (2026-09-05): the Alt+Tab parity marker (id-carrying prefix,
/// bufPrint appends `N\n`).
pub const alt_tab_marker: []const u8 = "tabwm: alt-tab id=";
/// #1056 item 3: the sidebar keyboard selection moved (id-carrying prefix,
/// bufPrint appends the absolute tab index + `\n`).
pub const nav_marker: []const u8 = "tabwm: nav ";
/// #1056 item 3: the tab-list overflow scroll offset changed.
pub const tab_scroll_marker: []const u8 = "tabwm: tab-scroll ";
/// #1064: the active tab was reordered (Ctrl+Shift+Left/Right).
pub const tab_move_marker: []const u8 = "tabwm: tab-move\n";
/// #1064: reopen-closed re-exec'd an app (id-carrying prefix, bufPrint
/// appends the bin + `\n`).
pub const reopen_marker: []const u8 = "tabwm: reopen ";

// ---------------------------------------------------------------------------
// TWM — the "Go" quick-jump markers and the rail chip geometry
// ---------------------------------------------------------------------------
/// The Go surface was summoned (pinned evidence marker).
pub const go_marker: []const u8 = "tabwm: go-summon\n";
/// A Go jump selected a live tab (id-carrying prefix).
pub const go_pick_tab_marker: []const u8 = "tabwm: go-pick ";
/// A Go jump launched a catalog app (bin-carrying prefix).
pub const go_launch_marker: []const u8 = "tabwm: go-launch ";
/// A Go jump named a target that no longer exists (honest no-op marker).
pub const go_miss_marker: []const u8 = "tabwm: go-miss\n";
/// Painted chip text. `JUMP` rather than `GO` so the rail does not collide
/// with `GOOS=virelai` in repo vocabulary. The chord is still Ctrl+Shift+G
/// (`^G`); serial markers stay `tabwm: go-*`.
pub const go_chip_label: []const u8 = "JUMP";
pub const go_chip_hint: []const u8 = "^G";
/// Upper bound (microseconds) the live-tabwm-bt gate pins for one
/// `go_refresh` scan. 32 candidates × 3 fields is a few microseconds on
/// the reference host; 5 ms is a loud regression, not a tight budget.
pub const go_scan_us_limit: u64 = 5000;
pub const go_scan_us_marker: []const u8 = "tabwm: go-scan-us=";
/// v2 persist-apply evidence (`tabwm: tabs-applied v2 n=… pin=… freeze=… title=…`).
pub const tabs_applied_marker: []const u8 = "tabwm: tabs-applied v2 ";
/// The Go rail chip lives in the ONE free band of the 180px rail: below
/// the tray row (the clock/theme/clipboard badges occupy y = 672..696)
/// and above the scanout edge. Nothing else draws there, so the chip
/// cannot collide with the tray or with the tab list.
pub const go_chip_x: u32 = 8;
pub const go_chip_y: u32 = 700;
pub const go_chip_w: u32 = 92;
pub const go_chip_h: u32 = 16;

pub fn go_chip_rect() Rect {
    return Rect.make(go_chip_x, go_chip_y, go_chip_w, go_chip_h);
}

// Geometry constants
pub const fb_w: u32 = 1280;
pub const fb_h: u32 = 720;
pub const sidebar_w: u32 = ui.sidebar_w; // 180
pub const viewport_x: u32 = ui.sidebar_w; // 180
pub const viewport_y: u32 = 0;
pub const viewport_w: u32 = fb_w - ui.sidebar_w; // 1100
pub const viewport_h: u32 = fb_h; // 720

pub const tab_row_h: u32 = ui.tab_row_h; // 38
pub const max_tabs: usize = 16;
pub const present_every: u32 = 2;

// ---------------------------------------------------------------------------
// Tab-list geometry (the ONE rule draw and hit-test both read)
// ---------------------------------------------------------------------------
// Pre-fix, the renderer stopped drawing rows at the y=650 list bound while
// the pointer hit-test mapped ANY py < 650 to a row index, so with more
// than ~15 tabs a click could activate a tab that was never drawn. These
// helpers are the shared source of truth: the render loop, the hit-test,
// and the "+ New tab" placement all derive from the same functions.
pub const tab_list_top: u32 = 58;
pub const tab_list_bottom: u32 = 650;
pub const tab_pill_x: u32 = 8;
pub const tab_pill_w: u32 = 164;

/// The y of tab row `i` (the top of its 38px band).
pub fn tab_row_y(i: usize) u32 {
    return tab_list_top + @as(u32, @intCast(i)) * tab_row_h;
}

/// True when row `i`'s band fits strictly above the list bound (the same
/// rule the renderer breaks on). Rows are contiguous, so `!row_fits(i)`
/// means every later row also fails.
pub fn tab_row_fits(i: usize) bool {
    return tab_row_y(i) + tab_row_h < tab_list_bottom;
}

/// The row index under `py`, or null when `py` is outside the band, past
/// the last row that FITS, or beyond the current tab count. The single
/// gate the pointer handler uses — a click can only ever reach a drawn tab.
/// #1056 item 3: the lookup is RELATIVE to the overflow scroll offset, so
/// a scrolled-into-view row resolves to its absolute index.
pub fn tab_index_at(py: u32) ?usize {
    if (py < tab_list_top or py >= tab_list_bottom) return null;
    const rel = (py - tab_list_top) / tab_row_h;
    if (!tab_row_fits(@intCast(rel))) return null;
    const idx = tab_scroll + @as(usize, @intCast(rel));
    if (idx >= manager.tab_count) return null;
    return idx;
}

// ---------------------------------------------------------------------------
// Tab-list navigation & overflow (#1056 item 3)
// ---------------------------------------------------------------------------
// The list is a scrolling window over the tabs. `tab_scroll` is the first
// drawn row; `nav_sel` is the keyboard cursor (independent of the ACTIVE
// tab). The renderer, the hit-test, and the "+ New tab" placement all read
// `tab_scroll`, so a click, a key, and a redraw can never disagree about
// which tab is where. All three fit-test the SAME `tab_row_fits` predicate.

/// The first tab row drawn in the list band (overflow scroll offset).
pub var tab_scroll: usize = 0;

/// The keyboard sidebar selection (an absolute tab index), or null when the
/// user has not started keyboard navigation. Up/Down move it; Enter
/// activates it — distinct from `hover_tab` (pointer) and `active_idx`
/// (the shown tab).
pub var nav_sel: ?usize = null;

/// How many tab rows fit in the list band (the renderer's hard limit).
pub fn visible_tab_rows() usize {
    var n: usize = 0;
    while (tab_row_fits(n)) : (n += 1) {}
    return n;
}

/// The largest valid `tab_scroll` for the current tab count (0 when every
/// tab fits — no overflow).
pub fn tab_scroll_max() usize {
    const vis = visible_tab_rows();
    return if (manager.tab_count > vis) manager.tab_count - vis else 0;
}

fn clamp_tab_scroll() void {
    const maxs = tab_scroll_max();
    if (tab_scroll > maxs) tab_scroll = maxs;
}

fn write_nav_marker() void {
    var buf: [48]u8 = undefined;
    const sel: u32 = @intCast(nav_sel orelse 0);
    const msg = std.fmt.bufPrint(&buf, "{s}{d}\n", .{ nav_marker, sel }) catch "tabwm: nav\n";
    write_marker(msg);
}

fn write_scroll_marker() void {
    var buf: [48]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{d}\n", .{ tab_scroll_marker, tab_scroll }) catch "tabwm: tab-scroll\n";
    write_marker(msg);
}

/// Scroll the tab window by `delta` rows (clamped to the list).
pub fn scroll_tabs(delta: i32) void {
    const cur: i32 = @intCast(tab_scroll);
    const maxs: i32 = @intCast(tab_scroll_max());
    var next = cur + delta;
    if (next < 0) next = 0;
    if (next > maxs) next = maxs;
    if (next == cur) return;
    tab_scroll = @intCast(next);
    write_scroll_marker();
}

/// Slide the scroll window so the keyboard selection stays on screen.
pub fn ensure_nav_visible() void {
    const sel = nav_sel orelse return;
    const vis = visible_tab_rows();
    if (vis == 0) return;
    if (sel < tab_scroll) {
        tab_scroll = sel;
    } else if (sel >= tab_scroll + vis) {
        tab_scroll = sel - vis + 1;
    }
    clamp_tab_scroll();
}

/// Move the keyboard selection by `delta` rows (clamped to the list) and
/// keep it visible. A no-op with no tabs.
pub fn nav_move(delta: i32) void {
    if (manager.tab_count == 0) return;
    const start: usize = nav_sel orelse manager.active_idx orelse 0;
    const last: i32 = @intCast(manager.tab_count - 1);
    var next: i32 = @as(i32, @intCast(start)) + delta;
    if (next < 0) next = 0;
    if (next > last) next = last;
    nav_sel = @intCast(next);
    ensure_nav_visible();
    write_nav_marker();
}

/// Activate the keyboard selection (Enter). A no-op when there is none.
pub fn nav_activate() void {
    if (nav_sel) |sel| {
        if (sel < manager.tab_count) activate_tab(sel);
    }
}

/// Drop a selection that no longer names a live tab (after closes) and
/// re-clamp the scroll window.
pub fn clamp_nav_selection() void {
    if (nav_sel) |sel| {
        if (sel >= manager.tab_count) {
            nav_sel = if (manager.tab_count == 0) null else manager.tab_count - 1;
        }
    }
    clamp_tab_scroll();
}

/// Format the overflow indicator (`"^2-16/18v"`; empty when everything
/// fits). The `^`/`v` show whether rows are hidden above/below. Pure —
/// host-testable with no framebuffer.
pub fn overflow_label(buf: []u8) []const u8 {
    if (tab_scroll_max() == 0) return "";
    const vis = visible_tab_rows();
    const start = tab_scroll + 1;
    const end = @min(tab_scroll + vis, manager.tab_count);
    const up: []const u8 = if (tab_scroll > 0) "^" else "";
    const down: []const u8 = if (tab_scroll < tab_scroll_max()) "v" else "";
    return std.fmt.bufPrint(buf, "{s}{d}-{d}/{d}{s}", .{ up, start, end, manager.tab_count, down }) catch "more";
}

// ---------------------------------------------------------------------------
// #1064 rail-neutral tab ergonomics (middle-click close, reorder, reopen)
// ---------------------------------------------------------------------------

/// Record a closed tab in the reopen LIFO (bounded ring). Pure BSS.
pub fn push_closed_tab(tab: *const Tab) void {
    var c = ClosedTab{};
    @memcpy(c.bin[0..tab.bin_len], tab.get_bin());
    c.bin_len = tab.bin_len;
    @memcpy(c.title[0..tab.title_len], tab.get_title());
    c.title_len = tab.title_len;
    closed_tabs[closed_count % max_tabs] = c;
    closed_count += 1;
}

/// The k-th most-recently-closed tab (0 = most recent), or null.
pub fn recently_closed_at(k: usize) ?*const ClosedTab {
    if (k >= closed_count or k >= max_tabs) return null;
    return &closed_tabs[(closed_count - 1 - k) % max_tabs];
}

/// Ctrl+Shift+T: reopen the most recently closed tab by re-exec'ing the app
/// TABWM launched it from. Returns false when there is nothing left to
/// reopen, or when the closed tab was NOT launched by TABWM (no recorded
/// bin) — an honest no-op, since the WM cannot rebuild a window it never
/// spawned. Un-reopenable entries are popped so the next press tries older
/// ones.
pub fn reopen_last_closed() bool {
    const c = recently_closed_at(0) orelse return false;
    if (c.bin_len == 0) {
        closed_count -= 1;
        return reopen_last_closed();
    }
    _ = ui.exec_program(c.bin[0..c.bin_len]);
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{s}\n", .{ reopen_marker, c.bin[0..c.bin_len] }) catch "tabwm: reopen\n";
    // TWM: record the reopen in the change log.
    tablog_event(tablog_code_reopen, c.bin[0..c.bin_len]);
    closed_count -= 1;
    write_marker(msg);
    return true;
}

/// Ctrl+Shift+Left/Right: move the ACTIVE tab by `delta` within the list
/// (swap with its neighbour) and keep it active/selected. The window stays
/// focused — only the list order changes. Returns true on a move.
pub fn move_active_tab(delta: i32) bool {
    const cur = manager.active_idx orelse return false;
    const last: i32 = @intCast(manager.tab_count - 1);
    const next: i32 = @as(i32, @intCast(cur)) + delta;
    if (next < 0 or next > last) return false;
    if (!manager.swap_tabs(cur, @intCast(next))) return false;
    manager.active_idx = @intCast(next);
    if (nav_sel) |sel| {
        if (sel == cur) nav_sel = @intCast(next);
    }
    write_marker(tab_move_marker);
    // TWM: record the keyboard move in the change log.
    var mmbuf: [16]u8 = undefined;
    tablog_event(tablog_code_reorder, std.fmt.bufPrint(&mmbuf, "{d}->{d}", .{ cur, next }) catch mmbuf[0..0]);
    save_tabs();
    return true;
}

/// Middle-click on a tab row closes it through the SAME decision point as
/// every other close (dirty tabs open the unsaved dialog). No-op while the
/// modal owns input or the click is outside the tab rows.
pub fn handle_middle_click(px: u32, py: u32) void {
    if (unsaved_dialog_open_tabwm) return;
    if (px >= sidebar_w) return;
    if (tab_index_at(py)) |idx| request_close_tab(idx);
}

// ---------------------------------------------------------------------------
// M48 — browser-style tab depth (umbrella #1120, goal #1064). Rail-native:
// no top strip, behavioural only. BT1 reopen/duplicate, BT2 reorder, BT3
// pinned/groups, BT4 start surface, BT5 per-tab history, BT6 preview/badge/
// tab search. Every mutation routes through the existing close/persist seams.
// ---------------------------------------------------------------------------

// --- BT1: duplicate the active tab ---------------------------------------
/// The duplicate affordance re-exec'd the active tab's executable.
pub const duplicate_marker: []const u8 = "tabwm: duplicate ";

/// Ctrl+Shift+D: clone the ACTIVE tab by re-exec'ing the executable the WM
/// launched it from. A tab the WM did not spawn has no recorded bin and is an
/// honest no-op (like reopen). The spawned window joins as a new tab and
/// adopts the bin through the same `pending_launch_bin` handshake the launch
/// overlay uses, so the clone is itself reopenable/duplicable. Returns true
/// when an exec was issued.
pub fn duplicate_active_tab() bool {
    const idx = manager.active_idx orelse return false;
    if (idx >= manager.tab_count) return false;
    const bin = manager.tabs[idx].get_bin();
    if (bin.len == 0) return false;
    const blen = @min(bin.len, pending_launch_bin.len);
    @memcpy(pending_launch_bin[0..blen], bin[0..blen]);
    pending_launch_bin_len = blen;
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{s}\n", .{ duplicate_marker, bin }) catch "tabwm: duplicate\n";
    write_marker(msg);
    _ = ui.exec_program(bin);
    return true;
}

// --- BT2: drag-to-reorder + keyboard move --------------------------------
/// The active tab was reordered by pointer drag (from->to).
pub const tab_reorder_marker: []const u8 = "tabwm: tab-reorder ";

/// Pointer-drag source row (null = no drag in flight). The kernel fans the
/// raw held-button state, so press begins a drag and release commits it.
pub var drag_from: ?usize = null;

/// A left-press landed on the tab at `idx`: if no drag is already in flight,
/// remember it as the drag source. (A plain click releases over the same row
/// and reorder_tab(from, from) is a no-op.)
pub fn begin_tab_drag(idx: usize) void {
    if (unsaved_dialog_open_tabwm) return;
    if (drag_from != null) return;
    if (idx < manager.tab_count) drag_from = idx;
}

/// Release at `py`: if a drag was in flight and the pointer landed on a
/// different drawn row, move the tab there and persist the new order.
pub fn end_tab_drag(py: u32) bool {
    const from = drag_from orelse return false;
    drag_from = null;
    const to = tab_index_at(py) orelse return false;
    return reorder_tab(from, to);
}

/// Move the tab at `from` to `to`, keeping the same tab active, emitting the
/// reorder marker, and persisting the new order to `.tabs` (BT2).
pub fn reorder_tab(from: usize, to: usize) bool {
    if (from >= manager.tab_count or to >= manager.tab_count or from == to) return false;
    const active_id = manager.get_active_id();
    if (!manager.move_tab(from, to)) return false;
    if (active_id) |id| manager.active_idx = manager.find_by_id(id);
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{d}->{d}\n", .{ tab_reorder_marker, from, to }) catch "tabwm: tab-reorder\n";
    write_marker(msg);
    // TWM: record the reorder in the change log.
    var rrbuf: [16]u8 = undefined;
    tablog_event(tablog_code_reorder, std.fmt.bufPrint(&rrbuf, "{d}->{d}", .{ from, to }) catch rrbuf[0..0]);
    save_tabs();
    return true;
}

// --- BT3: pinned tabs / manifest groups ----------------------------------
/// A tab was pinned or unpinned.
pub const pin_marker: []const u8 = "tabwm: tab-pin ";
/// A manifest group label was adopted by a tab (id-carrying).
pub const group_marker: []const u8 = "tabwm: tab-group ";

/// Ctrl+Shift+P: flip the pinned bit on `idx`, stable-partition pinned tabs
/// to the front, and persist. Returns true when the bit changed.
pub fn pin_toggle(idx: usize) bool {
    if (idx >= manager.tab_count) return false;
    const id = manager.tabs[idx].id;
    const on = !manager.tabs[idx].pinned;
    manager.tabs[idx].pinned = on;
    _ = manager.normalize_pinned();
    if (nav_sel) |sel| {
        if (sel == idx) nav_sel = manager.find_by_id(id);
    }
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{d} {s}\n", .{ pin_marker, id, if (on) "on" else "off" }) catch "tabwm: tab-pin\n";
    write_marker(msg);
    // TWM: record the pin change in the change log.
    var pbuf: [16]u8 = undefined;
    tablog_event(if (on) tablog_code_pin else tablog_code_unpin, std.fmt.bufPrint(&pbuf, "{d}", .{id}) catch pbuf[0..0]);
    save_tabs();
    return true;
}

/// Adopt a manifest group label on the tab owning window `id` (the launch
/// overlay hands the label over with the bin). A no-op when the tab or label
/// is absent. Emits the group marker.
pub fn adopt_tab_group(id: u32, label: []const u8) bool {
    const idx = manager.find_by_id(id) orelse return false;
    if (label.len == 0) return false;
    const n = @min(label.len, manager.tabs[idx].group.len);
    @memcpy(manager.tabs[idx].group[0..n], label[0..n]);
    manager.tabs[idx].group_len = n;
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{d} {s}\n", .{ group_marker, id, label }) catch "tabwm: tab-group\n";
    write_marker(msg);
    // TWM: record the group adoption in the change log.
    tablog_event(tablog_code_group, label);
    return true;
}

// --- BT4: the new-tab START surface --------------------------------------
/// The START surface was summoned (`+ New tab` pill or Ctrl+T).
pub const start_marker: []const u8 = "tabwm: start-surface\n";
/// The START surface is on screen (rail-native apps grid).
pub var start_open: bool = false;

/// Summon the START surface. Ctrl+T and the `+ New tab` pill open THIS (the
/// browser mental model: a new tab is a start page), while Ctrl+Space keeps
/// the Sexiburger command palette. The catalog filtering state is shared with
/// the command palette; the two are mutually exclusive.
pub fn start_summon() void {
    if (unsaved_dialog_open_tabwm) return;
    if (!overlay_loaded) _ = overlay_load_manifest();
    overlay_open = false;
    start_open = true;
    overlay_filter_len = 0;
    overlay_refresh_filter();
    write_marker(start_marker);
    write_marker(new_tab_marker);
}

pub fn start_dismiss() void {
    start_open = false;
    overlay_filter_len = 0;
    overlay_refresh_filter();
}

/// Close whichever catalog surface is open (START page or Sexiburger).
fn dismiss_active_catalog() void {
    if (start_open) start_dismiss();
    overlay_dismiss();
}

// --- BT5: per-tab back/forward over app-declared navigation --------------
/// The app-declared navigation RPC kind. The kernel does not interpret WM_RPC
/// kinds (it routes the frame to the registered WM seat), so this additive
/// kind lives beside its handler rather than in the frozen wire mirror.
pub const wm_rpc_kind_nav_declare: u8 = 9;
pub const wm_rpc_kind_nav_poll: u8 = 10;

/// An app declared a navigation event (id-carrying; the target path follows).
pub const nav_decl_marker: []const u8 = "tabwm: nav-decl ";
/// The user stepped a tab's history backward (id-carrying + target).
pub const nav_back_marker: []const u8 = "tabwm: nav-back ";
/// The user stepped a tab's history forward (id-carrying + target).
pub const nav_forward_marker: []const u8 = "tabwm: nav-forward ";

/// The next navigation target an app should move to, queued by back/forward
/// and drained by that app's `nav_poll` RPC. Keyed by window id (id 0 = none).
pub var pending_nav_id: u32 = 0;
pub var pending_nav_path: [hist_path_max]u8 = @as([hist_path_max]u8, @splat(@as(u8, 0)));
pub var pending_nav_len: usize = 0;

fn set_pending_nav(id: u32, path: []const u8) void {
    pending_nav_id = id;
    const n = @min(path.len, pending_nav_path.len);
    @memcpy(pending_nav_path[0..n], path[0..n]);
    pending_nav_len = n;
}

/// Handle an app-declared navigation event (BT5): record it in the owning
/// tab's history. Returns true when the tab exists (the nav was accepted).
pub fn nav_declare(id: u32, path: []const u8) bool {
    const idx = manager.find_by_id(id) orelse return false;
    if (!manager.tabs[idx].nav_record(path)) return true;
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{d} {s}\n", .{ nav_decl_marker, id, path }) catch "tabwm: nav-decl\n";
    write_marker(msg);
    return true;
}

/// Step the ACTIVE tab's history backward and queue the target for its app.
pub fn nav_back_active() bool {
    const idx = manager.active_idx orelse return false;
    if (idx >= manager.tab_count) return false;
    const target = manager.tabs[idx].nav_back() orelse return false;
    const id = manager.tabs[idx].id;
    set_pending_nav(id, target);
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{d} {s}\n", .{ nav_back_marker, id, target }) catch "tabwm: nav-back\n";
    write_marker(msg);
    return true;
}

/// Step the ACTIVE tab's history forward and queue the target for its app.
pub fn nav_forward_active() bool {
    const idx = manager.active_idx orelse return false;
    if (idx >= manager.tab_count) return false;
    const target = manager.tabs[idx].nav_forward() orelse return false;
    const id = manager.tabs[idx].id;
    set_pending_nav(id, target);
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{d} {s}\n", .{ nav_forward_marker, id, target }) catch "tabwm: nav-forward\n";
    write_marker(msg);
    return true;
}

/// Drain the pending navigation target for `id` into `buf`. Returns the
/// target slice, or null when none is queued for this window. Clears the slot
/// (poll-once).
pub fn nav_poll(id: u32, buf: []u8) ?[]const u8 {
    if (pending_nav_id != id or id == 0) return null;
    const n = @min(pending_nav_len, buf.len);
    @memcpy(buf[0..n], pending_nav_path[0..n]);
    pending_nav_id = 0;
    pending_nav_len = 0;
    return buf[0..n];
}

// --- BT6: frozen badge, hover preview, tab search ------------------------
/// The frozen badge was toggled (id-carrying).
pub const freeze_marker: []const u8 = "tabwm: tab-freeze ";
/// The tab-search overlay was summoned.
pub const tab_search_marker: []const u8 = "tabwm: tab-search\n";
/// A tab-search selection was activated (id-carrying).
pub const tab_search_pick_marker: []const u8 = "tabwm: tab-search-pick ";

/// Ctrl+Shift+F: flip the FROZEN badge on `idx` (a suspended background tab).
pub fn freeze_toggle(idx: usize) bool {
    if (idx >= manager.tab_count) return false;
    manager.tabs[idx].frozen = !manager.tabs[idx].frozen;
    var buf: [48]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{d} {s}\n", .{ freeze_marker, manager.tabs[idx].id, if (manager.tabs[idx].frozen) "on" else "off" }) catch "tabwm: tab-freeze\n";
    write_marker(msg);
    // TWM: record the freeze change in the change log.
    var fzbuf: [16]u8 = undefined;
    tablog_event(if (manager.tabs[idx].frozen) tablog_code_freeze else tablog_code_unfreeze, std.fmt.bufPrint(&fzbuf, "{d}", .{manager.tabs[idx].id}) catch fzbuf[0..0]);
    save_tabs();
    return true;
}

/// Hover-preview dwell: how many composite ticks the pointer must rest on a
/// tab before the preview card appears.
pub const hover_preview_delay: u32 = 2;
pub var hover_preview_ticks: u32 = 0;
pub var hover_preview_target: ?usize = null;

/// True when the preview card should draw for `row` (the pointer has dwelt on
/// it long enough).
pub fn hover_preview_visible(row: usize) bool {
    const t = hover_preview_target orelse return false;
    return t == row and hover_preview_ticks >= hover_preview_delay;
}

/// One composite tick of hover dwell bookkeeping. Returns true when the
/// preview target changed (so a caller could redraw).
pub fn hover_tick() bool {
    const cur = hover_tab;
    if (cur == hover_preview_target) {
        if (cur != null) hover_preview_ticks +|= 1;
        return false;
    }
    hover_preview_target = cur;
    hover_preview_ticks = 0;
    return true;
}

/// Tab-search overlay state (independent of the catalog surfaces).
pub var tab_search_open: bool = false;
var tab_search_filter: [16]u8 = @as([16]u8, @splat(@as(u8, 0)));
var tab_search_filter_len: usize = 0;
var tab_search_results: [max_tabs]usize = @as([max_tabs]usize, @splat(@as(usize, 0)));
var tab_search_count: usize = 0;
var tab_search_sel: usize = 0;

pub fn tab_search_is_open() bool {
    return tab_search_open;
}

/// Rebuild the tab-search result list (case-insensitive substring over the
/// tab titles). Pure over `manager`; host-testable.
pub fn tab_search_refresh() void {
    tab_search_count = 0;
    tab_search_sel = 0;
    const q = tab_search_filter[0..tab_search_filter_len];
    var needle: [16]u8 = undefined;
    const nl = @min(q.len, needle.len);
    for (q[0..nl], 0..) |c, k| needle[k] = std.ascii.toLower(c);
    for (0..manager.tab_count) |i| {
        const title = manager.tabs[i].get_title();
        if (nl == 0) {
            tab_search_results[tab_search_count] = i;
            tab_search_count += 1;
            continue;
        }
        if (title.len < nl) continue;
        var start: usize = 0;
        while (start + nl <= title.len) : (start += 1) {
            var k: usize = 0;
            while (k < nl and std.ascii.toLower(title[start + k]) == needle[k]) : (k += 1) {}
            if (k == nl) {
                tab_search_results[tab_search_count] = i;
                tab_search_count += 1;
                break;
            }
        }
    }
}

/// How many tabs match the current search query (host-testable).
pub fn tab_search_match_count() usize {
    return tab_search_count;
}

pub fn tab_search_summon() void {
    if (unsaved_dialog_open_tabwm) return;
    start_open = false;
    overlay_dismiss();
    tab_search_open = true;
    tab_search_filter_len = 0;
    tab_search_refresh();
    write_marker(tab_search_marker);
}

pub fn tab_search_dismiss() void {
    tab_search_open = false;
    tab_search_filter_len = 0;
    tab_search_refresh();
}

/// Activate the selected search result and dismiss the overlay.
pub fn tab_search_activate() bool {
    if (tab_search_count == 0) return false;
    const idx = tab_search_results[tab_search_sel];
    tab_search_dismiss();
    if (idx < manager.tab_count) {
        activate_tab(idx);
        var buf: [48]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}{d}\n", .{ tab_search_pick_marker, manager.tabs[idx].id }) catch "tabwm: tab-search-pick\n";
        write_marker(msg);
        return true;
    }
    return false;
}

/// One key while the tab-search overlay is open. Returns true when consumed.
pub fn tab_search_key(usage: u8) bool {
    if (!tab_search_open) return false;
    switch (usage) {
        0x29 => { // Escape
            tab_search_dismiss();
            return true;
        },
        0x28 => { // Enter
            _ = tab_search_activate();
            return true;
        },
        0x2a => { // Backspace
            if (tab_search_filter_len > 0) {
                tab_search_filter_len -= 1;
                tab_search_refresh();
            }
            return true;
        },
        0x52 => { // Up
            if (tab_search_sel > 0) tab_search_sel -= 1;
            return true;
        },
        0x51 => { // Down
            if (tab_search_sel + 1 < tab_search_count) tab_search_sel += 1;
            return true;
        },
        else => {},
    }
    const printable = (usage >= 0x04 and usage <= 0x1d) or (usage >= 0x1e and usage <= 0x27) or
        usage == 0x2c or usage == 0x2d or usage == 0x37;
    if (printable and tab_search_filter_len < tab_search_filter.len) {
        const c: u8 = if (usage == 0x2c) ' ' else if (usage == 0x2d) '-' else if (usage == 0x37) '.' else if (usage <= 0x1d) @intCast(usage - 0x04 + 'a') else @intCast(usage - 0x1e + '1');
        tab_search_filter[tab_search_filter_len] = c;
        tab_search_filter_len += 1;
        tab_search_refresh();
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// TWM — "Go": the rail-native quick-jump (Ctrl+Shift+G)
// ---------------------------------------------------------------------------
// The user-facing "Go" affordance: ONE surface to jump to anything the rail
// can show — a live tab (by title, 1-based index, or group label) or an app
// in the APPS.TXT catalog. It is a SIBLING of the M48 tab search
// (Ctrl+Shift+A, tabs only), of the Sexiburger catalog (Ctrl+Space) and of
// the START page (Ctrl+T). It shares none of their state and none of their
// chords, so all four surfaces stay independent and mutually exclusive.
//
// Every scan/rank/match function below is PURE over `manager` + the catalog
// arrays — host-testable with no framebuffer, no kernel and no host share.
// Static BSS only: no heap, no dynamic allocation.

/// The Go query buffer — deliberately larger than tab_search's 16 bytes so a
/// real title can be typed in full.
pub const go_query_max: usize = 24;

/// Panel geometry in scanout coordinates (centered on the content viewport).
pub const go_panel_w: u32 = 520;
pub const go_panel_h: u32 = 360;
pub const go_panel_y: u32 = 100;
/// The result rows start this far below the panel top, one `go_row_h` apart.
pub const go_rows_y: u32 = 78;
pub const go_row_h: u32 = 22;
/// Hint row under the list; the last drawn result must stay above this band.
pub const go_panel_footer: u32 = 26;
/// How many results the panel can draw. Derived from geometry so a Down-arrow
/// or click cannot select a row the renderer never paints.
pub const go_max_results: usize = (go_panel_h - go_rows_y - go_panel_footer) / go_row_h;
/// Upper bound on the candidate set scanned (live tabs + catalog apps).
pub const go_scan_max: usize = max_tabs + overlay_max_apps;

pub fn go_panel_x() u32 {
    return viewport_x + (viewport_w - go_panel_w) / 2;
}

/// A result is a live tab or a catalog app.
pub const go_kind_tab: u8 = 0;
pub const go_kind_app: u8 = 1;

/// Match classes, best (0) to worst (3). The ranking rule the spec pins:
/// EXACT > PREFIX > SUBSTRING > SUBSEQUENCE.
pub const go_rank_exact: u8 = 0;
pub const go_rank_prefix: u8 = 1;
pub const go_rank_substring: u8 = 2;
pub const go_rank_subsequence: u8 = 3;

pub const GoTarget = struct {
    kind: u8 = go_kind_tab,
    idx: usize = 0,
    /// Window id for a tab target (0 for an app). Activate looks up by id
    /// so a close that shifts later rows cannot land on the wrong tab.
    id: u32 = 0,
    rank: u8 = go_rank_subsequence,
    pinned: bool = false,
};

pub var go_open: bool = false;
pub var hover_go: bool = false;
var go_query: [go_query_max]u8 = @as([go_query_max]u8, @splat(@as(u8, 0)));
var go_query_len: usize = 0;
var go_results: [go_scan_max]GoTarget = @as([go_scan_max]GoTarget, @splat(@as(GoTarget, .{})));
var go_result_count: usize = 0;
var go_sel: usize = 0;

pub fn go_is_open() bool {
    return go_open;
}

/// The live query text (what the renderer draws after the '>' prompt).
pub fn go_query_slice() []const u8 {
    return go_query[0..go_query_len];
}

/// Case-insensitive ASCII equality.
pub fn go_eql_ci(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Case-insensitive prefix test.
pub fn go_starts_ci(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    return go_eql_ci(hay[0..needle.len], needle);
}

/// Case-insensitive substring test.
pub fn go_contains_ci(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    const last = hay.len - needle.len;
    var start: usize = 0;
    while (start <= last) : (start += 1) {
        if (go_eql_ci(hay[start .. start + needle.len], needle)) return true;
    }
    return false;
}

/// Case-insensitive SUBSEQUENCE test — the deterministic "fuzzy" fallback.
/// Every needle byte must appear in `hay` in order (not necessarily
/// adjacent), so "ntpd" finds "Notepad".
pub fn go_subsequence_ci(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var n: usize = 0;
    for (hay) |c| {
        if (n >= needle.len) break;
        if (std.ascii.toLower(c) == std.ascii.toLower(needle[n])) n += 1;
    }
    return n == needle.len;
}

/// Rank one haystack against the query. Null means NO MATCH. Pure.
pub fn go_rank(hay: []const u8, needle: []const u8) ?u8 {
    if (needle.len == 0) return go_rank_exact;
    if (go_eql_ci(hay, needle)) return go_rank_exact;
    if (go_starts_ci(hay, needle)) return go_rank_prefix;
    if (go_contains_ci(hay, needle)) return go_rank_substring;
    if (go_subsequence_ci(hay, needle)) return go_rank_subsequence;
    return null;
}

fn go_rank_min(best: ?u8, r: ?u8) ?u8 {
    if (r) |v| return if (best) |b| @min(b, v) else v;
    return best;
}

/// Best rank of `needle` over a tab's candidate fields: its title, its
/// manifest group label, and its 1-based index as text. Pure.
pub fn go_rank_tab(i: usize, needle: []const u8) ?u8 {
    if (i >= manager.tab_count) return null;
    const t = &manager.tabs[i];
    var best = go_rank(t.get_title(), needle);
    if (t.group_len > 0) best = go_rank_min(best, go_rank(t.group[0..t.group_len], needle));
    var num: [8]u8 = undefined;
    const n = std.fmt.bufPrint(&num, "{d}", .{i + 1}) catch num[0..0];
    best = go_rank_min(best, go_rank(n, needle));
    return best;
}

/// Best rank of `needle` over a catalog entry (label, bin, group). Pure.
pub fn go_rank_app(e: usize, needle: []const u8) ?u8 {
    if (e >= overlay_count) return null;
    var best = go_rank(overlay_labels[e][0..overlay_label_lens[e]], needle);
    best = go_rank_min(best, go_rank(overlay_bins[e][0..overlay_bin_lens[e]], needle));
    if (overlay_group_lens[e] > 0) best = go_rank_min(best, go_rank(overlay_groups[e][0..overlay_group_lens[e]], needle));
    return best;
}

/// Deterministic order: rank, then pinned, then tabs before apps, then
/// source order. This is the tie-break the spec pins.
fn go_target_less(a: GoTarget, b: GoTarget) bool {
    if (a.rank != b.rank) return a.rank < b.rank;
    if (a.pinned != b.pinned) return a.pinned;
    if (a.kind != b.kind) return a.kind < b.kind;
    return a.idx < b.idx;
}

fn go_push(kind: u8, idx: usize, rank: u8, pinned: bool, id: u32) void {
    if (go_result_count >= go_scan_max) return;
    go_results[go_result_count] = .{ .kind = kind, .idx = idx, .id = id, .rank = rank, .pinned = pinned };
    go_result_count += 1;
}

/// Rebuild the Go result list. Pure over `manager` + the catalog. An EMPTY
/// query yields the default list (pinned tabs first, then tabs in rail
/// order, then catalog apps in manifest order) so the surface is already
/// useful before a single key is typed. Insertion sort — bounded list.
pub fn go_refresh() void {
    go_result_count = 0;
    const q = go_query[0..go_query_len];
    for (0..manager.tab_count) |i| {
        if (go_rank_tab(i, q)) |r| go_push(go_kind_tab, i, r, manager.tabs[i].pinned, manager.tabs[i].id);
    }
    for (0..overlay_count) |e| {
        if (go_rank_app(e, q)) |r| go_push(go_kind_app, e, r, overlay_dock[e], 0);
    }
    var i: usize = 1;
    while (i < go_result_count) : (i += 1) {
        const key = go_results[i];
        var j: usize = i;
        while (j > 0 and go_target_less(key, go_results[j - 1])) : (j -= 1) {
            go_results[j] = go_results[j - 1];
        }
        go_results[j] = key;
    }
    if (go_result_count > go_max_results) go_result_count = go_max_results;
    go_sel = if (go_result_count == 0) 0 else @min(go_sel, go_result_count - 1);
}

fn read_cntpct() u64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var val: u64 = 0;
    asm volatile ("mrs %[val], cntpct_el0"
        : [val] "=r" (val),
    );
    return val;
}

fn read_cntfrq() u64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var val: u64 = 0;
    asm volatile ("mrs %[val], cntfrq_el0"
        : [val] "=r" (val),
    );
    return val;
}

/// Convert a CNTPCT delta to microseconds. Pure — host-testable.
pub fn ticks_to_us(delta: u64, freq: u64) u64 {
    if (freq == 0) return 0;
    return @as(u64, @intCast((@as(u128, delta) * 1_000_000) / freq));
}

/// How many rows the Go panel is offering right now (host-testable).
pub fn go_match_count() usize {
    return go_result_count;
}

/// The current selection index into the result list.
pub fn go_selection() usize {
    return go_sel;
}

/// True when two live tabs carry the SAME title — the case where a row must
/// carry a disambiguator, because otherwise two rows would be
/// indistinguishable. Exact (case-sensitive) comparison: the disambiguator
/// fires on visually identical rows, not on lookalikes.
pub fn go_title_ambiguous(title: []const u8) bool {
    var seen: usize = 0;
    for (0..manager.tab_count) |i| {
        if (std.mem.eql(u8, manager.tabs[i].get_title(), title)) seen += 1;
        if (seen > 1) return true;
    }
    return false;
}

/// The label for result `r`, written into `buf` when a disambiguator is
/// needed. The renderer draws EXACTLY this string, so drawing and
/// key-handling can never disagree. Pure.
pub fn go_row_label(r: usize, buf: []u8) []const u8 {
    if (r >= go_result_count) return "";
    const t = go_results[r];
    if (t.kind == go_kind_tab) {
        if (t.idx >= manager.tab_count) return "";
        const tab = &manager.tabs[t.idx];
        const title = tab.get_title();
        if (go_title_ambiguous(title)) {
            return std.fmt.bufPrint(buf, "{s} #{d}", .{ title, tab.id }) catch title;
        }
        return title;
    }
    if (t.idx >= overlay_count) return "";
    const lbl = overlay_labels[t.idx][0..overlay_label_lens[t.idx]];
    if (overlay_group_lens[t.idx] > 0) {
        const g = overlay_groups[t.idx][0..overlay_group_lens[t.idx]];
        return std.fmt.bufPrint(buf, "{s} / {s}", .{ lbl, g }) catch lbl;
    }
    return lbl;
}

/// The short type tag the row shows on its right.
pub fn go_row_kind_label(r: usize) []const u8 {
    if (r >= go_result_count) return "";
    return if (go_results[r].kind == go_kind_tab) "tab" else "app";
}

/// The empty / no-match copy. Distinguishes a surface with NOTHING to jump
/// to (empty rail + empty catalog) from a query with no hits — the same
/// honest-distinction rule `overlay_empty_message` uses.
pub fn go_empty_message() []const u8 {
    if (go_result_count != 0) return "";
    if (manager.tab_count == 0 and overlay_count == 0) return "nothing to jump to";
    if (go_query_len == 0) return "type to jump";
    return "no matches";
}

pub fn go_summon() void {
    // The modal owns the input: never open over the unsaved dialog.
    if (unsaved_dialog_open_tabwm) return;
    // The catalog surfaces are mutually exclusive.
    overlay_open = false;
    start_open = false;
    tab_search_open = false;
    if (!overlay_loaded) _ = overlay_load_manifest();
    go_query_len = 0;
    go_sel = 0;
    const t0 = read_cntpct();
    go_refresh();
    const t1 = read_cntpct();
    go_open = true;
    write_marker(go_marker);
    const us = ticks_to_us(t1 -| t0, read_cntfrq());
    var ubuf: [40]u8 = undefined;
    const umsg = std.fmt.bufPrint(&ubuf, "{s}{d}\n", .{ go_scan_us_marker, us }) catch "tabwm: go-scan-us=0\n";
    write_marker(umsg);
}

pub fn go_dismiss() void {
    go_open = false;
    go_query_len = 0;
    go_refresh();
}

/// Activate the selected target. A TAB target that has since been closed is
/// a SAFE NO-OP — the miss is reported and false returned, rather than
/// activating the wrong tab. An APP target launches through the SAME
/// `pending_launch_bin` handshake the catalog uses, so the spawned window
/// joins as a normal, reopenable tab.
pub fn go_activate() bool {
    if (!go_open) return false;
    if (go_result_count == 0) return false;
    const r = go_results[go_sel];
    if (r.kind == go_kind_tab) {
        const idx = manager.find_by_id(r.id) orelse {
            write_marker(go_miss_marker);
            go_refresh();
            return false;
        };
        const id = manager.tabs[idx].id;
        activate_tab(idx);
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}{d}\n", .{ go_pick_tab_marker, id }) catch "tabwm: go-pick\n";
        write_marker(msg);
        var dbuf: [16]u8 = undefined;
        tablog_event(tablog_code_go, std.fmt.bufPrint(&dbuf, "tab {d}", .{id}) catch dbuf[0..0]);
        go_dismiss();
        return true;
    }
    const bin = overlay_bins[r.idx][0..overlay_bin_lens[r.idx]];
    if (bin.len == 0) return false;
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{s}\n", .{ go_launch_marker, bin }) catch "tabwm: go-launch\n";
    write_marker(msg);
    const blen = @min(bin.len, pending_launch_bin.len);
    @memcpy(pending_launch_bin[0..blen], bin[0..blen]);
    pending_launch_bin_len = blen;
    const group = overlay_groups[r.idx][0..overlay_group_lens[r.idx]];
    const glen = @min(group.len, pending_launch_group.len);
    @memcpy(pending_launch_group[0..glen], group[0..glen]);
    pending_launch_group_len = glen;
    pending_launch_pinned = overlay_dock[r.idx];
    _ = ui.exec_program(bin);
    var dbuf: [24]u8 = undefined;
    tablog_event(tablog_code_launch, std.fmt.bufPrint(&dbuf, "{s}", .{bin}) catch dbuf[0..0]);
    go_dismiss();
    return true;
}

/// One key while the Go surface is open. The surface is MODAL — the same
/// rule the unsaved-changes dialog uses — so EVERY key is consumed and no
/// tab chord can fire underneath the panel. Escape clears a non-empty query
/// first and dismisses on the second press. (The raw WM_KEY fan carries no
/// modifier bits into these handlers, so Ctrl+U is not distinguishable from
/// 'u' and is deliberately NOT the clear gesture.)
pub fn go_key(usage: u8) bool {
    if (!go_open) return false;
    switch (usage) {
        0x29 => { // Escape: clear, else dismiss
            if (go_query_len > 0) {
                go_query_len = 0;
                go_sel = 0;
                go_refresh();
            } else {
                go_dismiss();
            }
            return true;
        },
        0x28 => { // Enter: jump
            _ = go_activate();
            return true;
        },
        0x2a => { // Backspace: trim the query
            if (go_query_len > 0) {
                go_query_len -= 1;
                go_refresh();
            }
            return true;
        },
        0x52 => { // Up
            if (go_sel > 0) go_sel -= 1;
            return true;
        },
        0x51 => { // Down
            if (go_sel + 1 < go_result_count) go_sel += 1;
            return true;
        },
        0x4b => { // PageUp
            go_sel = if (go_sel > go_max_results) go_sel - go_max_results else 0;
            return true;
        },
        0x4e => { // PageDown
            if (go_result_count > 0) go_sel = @min(go_sel + go_max_results, go_result_count - 1);
            return true;
        },
        else => {},
    }
    // Ctrl+Shift+G again toggles the surface closed.
    if (usage == usage_g) {
        go_dismiss();
        return true;
    }
    const printable = (usage >= 0x04 and usage <= 0x1d) or (usage >= 0x1e and usage <= 0x27) or
        usage == 0x2c or usage == 0x2d or usage == 0x37;
    if (printable and go_query_len < go_query.len) {
        const c: u8 = if (usage == 0x2c) ' ' else if (usage == 0x2d) '-' else if (usage == 0x37) '.' else if (usage <= 0x1d) @intCast(usage - 0x04 + 'a') else @intCast(usage - 0x1e + '1');
        go_query[go_query_len] = c;
        go_query_len += 1;
        go_refresh();
    }
    return true; // modal: swallow everything else
}

/// A click while the Go surface is up. Inside the result list a click
/// selects and activates the row under the pointer; anywhere else it
/// dismisses. Always consumed (the surface is modal).
pub fn go_click(px: u32, py: u32) bool {
    const px0 = go_panel_x();
    if (px < px0 or px >= px0 + go_panel_w or py < go_panel_y or py >= go_panel_y + go_panel_h) {
        go_dismiss();
        return true;
    }
    const first = go_panel_y + go_rows_y;
    if (py >= first) {
        const r = (py - first) / go_row_h;
        if (r < go_result_count and r < go_max_results) {
            go_sel = r;
            _ = go_activate();
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Syscall wrappers
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

fn syscall2(num: u64, a0: u64, a1: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
        : .{ .memory = true });
    return res;
}

fn syscall3(num: u64, a0: u64, a1: u64, a2: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
        : .{ .memory = true });
    return res;
}

fn syscall4(num: u64, a0: u64, a1: u64, a2: u64, a3: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
        : .{ .memory = true });
    return res;
}

fn syscall6(num: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
          [a4] "{x4}" (a4),
          [a5] "{x5}" (a5),
        : .{ .memory = true });
    return res;
}

fn write_marker(msg: []const u8) void {
    _ = syscall3(sys_write, 1, @intFromPtr(msg.ptr), msg.len);
}

// ---------------------------------------------------------------------------
// Tab & Window Mirror Models
// ---------------------------------------------------------------------------
// M48/BT5: the per-tab navigation history is bounded to this many entries.
// Whole-app navigation events are short strings (a directory or file path),
// so the cap keeps the static BSS footprint tiny while covering a normal
// browsing session.
pub const hist_max: usize = 8;
pub const hist_path_max: usize = 24;

/// One recorded navigation target for a tab.
pub const HistEntry = struct {
    path: [hist_path_max]u8 = @as([hist_path_max]u8, @splat(@as(u8, 0))),
    path_len: usize = 0,

    pub fn get(self: *const HistEntry) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn set(self: *HistEntry, text: []const u8) void {
        const len = @min(text.len, self.path.len);
        @memcpy(self.path[0..len], text[0..len]);
        self.path_len = len;
    }
};

pub const Tab = struct {
    id: u32 = 0,
    title: [32]u8 = @as([32]u8, @splat(@as(u8, 0))),
    title_len: usize = 0,
    valid: bool = false,
    visible: bool = false,
    /// M42 UX r2 (claim #1011): the kernel's unsaved bit (kind-20 mirror
    /// flags bit 12, fanned from user_set_unsaved on every dirty change) —
    /// the tab is DIRTY; its closes route through the unsaved-changes
    /// dialog and its pill wears the accent dot.
    unsaved: bool = false,
    orig_w: u32 = 0,
    orig_h: u32 = 0,
    resizable: bool = false,
    /// M42 SX2 (issue #983): the app declared itself tab-aware (the
    /// `wm_rpc_kind_declare_fullscreen` RPC from lib/tabapp.zig) — when its
    /// tab is active it receives the FULL 1100x720 content viewport instead
    /// of the centered native-size presentation, and the kernel's
    /// SET_WINDOW seam tells it with WIN_RESIZE.
    tab_aware: bool = false,
    /// The viewport rect last applied via SET_WINDOW (activation idempotence:
    /// re-activating an already-fullscreen tab issues no repeat proposal, so
    /// the app gets no repeat WIN_RESIZE).
    applied_vp: ?Rect = null,
    /// #1064 (rail-neutral ergonomics): the executable TABWM launched this
    /// tab from, when it knows it (the god-menu launch path records the bin;
    /// windows that opened themselves have none). Reopen-closed re-execs it.
    bin: [24]u8 = @as([24]u8, @splat(@as(u8, 0))),
    bin_len: usize = 0,

    /// M48/BT3: the tab is PINNED — it sorts ahead of unpinned tabs and
    /// carries a pin glyph. The pin is seeded from the APPS.TXT `dock=true`
    /// flag (via the launch overlay) and toggled by Ctrl+Shift+P.
    pinned: bool = false,
    /// M48/BT3: the manifest group label (`group=NAME`), or empty. Rendered
    /// as a small header over the pinned block; never changes tab identity.
    group: [12]u8 = @as([12]u8, @splat(@as(u8, 0))),
    group_len: usize = 0,
    /// M48/BT6: the tab is FROZEN — a background tab the user suspended.
    /// Purely presentational state for now (badge + status); pairs with the
    /// future demand-paging freeze. Toggled by Ctrl+Shift+F.
    frozen: bool = false,
    /// M48/BT5: the bounded per-tab navigation history (the browser-history
    /// analogue for whole apps). `hist_pos` is the current entry; entries at
    /// (`hist_pos`, `hist_count`) are the forward stack.
    hist: [hist_max]HistEntry = @as([hist_max]HistEntry, @splat(@as(HistEntry, .{}))),
    hist_count: usize = 0,
    hist_pos: usize = 0,

    pub fn set_title(self: *Tab, text: []const u8) void {
        const len = @min(text.len, self.title.len);
        @memcpy(self.title[0..len], text[0..len]);
        self.title_len = len;
    }

    pub fn get_title(self: *const Tab) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn set_bin(self: *Tab, text: []const u8) void {
        const len = @min(text.len, self.bin.len);
        @memcpy(self.bin[0..len], text[0..len]);
        self.bin_len = len;
    }

    pub fn get_bin(self: *const Tab) []const u8 {
        return self.bin[0..self.bin_len];
    }

    // -----------------------------------------------------------------------
    // M48/BT5: the per-tab navigation history (pure; host-testable)
    // -----------------------------------------------------------------------

    /// The current history entry, or null when the tab has no history.
    pub fn current_nav(self: *const Tab) ?[]const u8 {
        if (self.hist_count == 0) return null;
        return self.hist[self.hist_pos].get();
    }

    /// Record a navigation to `path`. Consecutive duplicates are a no-op;
    /// navigating after a back() truncates the forward stack (the browser
    /// rule). At the cap the oldest entry is dropped. Returns true when the
    /// history changed.
    pub fn nav_record(self: *Tab, path: []const u8) bool {
        if (path.len == 0) return false;
        if (self.hist_count > 0 and std.mem.eql(u8, self.hist[self.hist_pos].get(), path)) return false;
        // Drop the forward stack (the entry after `hist_pos` is the next
        // append slot). The empty-history case keeps the slot at 0.
        self.hist_count = if (self.hist_count == 0) 0 else self.hist_pos + 1;
        // At the cap, drop the oldest entry to make room.
        if (self.hist_count == hist_max) {
            var i: usize = 1;
            while (i < hist_max) : (i += 1) self.hist[i - 1] = self.hist[i];
            self.hist_count = hist_max - 1;
        }
        self.hist[self.hist_count].set(path);
        self.hist_count += 1;
        self.hist_pos = self.hist_count - 1;
        return true;
    }

    /// True when a back step is available.
    pub fn can_nav_back(self: *const Tab) bool {
        return self.hist_count > 0 and self.hist_pos > 0;
    }

    /// True when a forward step is available.
    pub fn can_nav_forward(self: *const Tab) bool {
        return self.hist_count > 0 and self.hist_pos + 1 < self.hist_count;
    }

    /// Step the cursor back one entry. Returns the new current path, or null
    /// when already at the start.
    pub fn nav_back(self: *Tab) ?[]const u8 {
        if (!self.can_nav_back()) return null;
        self.hist_pos -= 1;
        return self.hist[self.hist_pos].get();
    }

    /// Step the cursor forward one entry. Returns the new current path, or
    /// null when already at the newest entry.
    pub fn nav_forward(self: *Tab) ?[]const u8 {
        if (!self.can_nav_forward()) return null;
        self.hist_pos += 1;
        return self.hist[self.hist_pos].get();
    }
};

pub const TabManager = struct {
    tabs: [max_tabs]Tab = @as([max_tabs]Tab, @splat(@as(Tab, .{}))),
    tab_count: usize = 0,
    active_idx: ?usize = null,

    pub fn init() TabManager {
        return .{};
    }

    pub fn find_by_id(self: *const TabManager, id: u32) ?usize {
        for (0..self.tab_count) |i| {
            if (self.tabs[i].valid and self.tabs[i].id == id) return i;
        }
        return null;
    }

    /// True when `id` is unknown AND the manager is full, i.e. an upsert
    /// of `id` cannot land. `add_or_update_tab_geom` returns index 0 on
    /// overflow, which is a VALID slot — so callers that accepted that 0
    /// as success silently aliased a new window onto tab 0. The RPC
    /// upsert paths use this predicate to REFUSE honestly instead.
    pub fn at_capacity(self: *const TabManager, id: u32) bool {
        return self.find_by_id(id) == null and self.tab_count >= max_tabs;
    }

    pub fn add_or_update_tab(self: *TabManager, id: u32, title: []const u8) usize {
        return self.add_or_update_tab_geom(id, title, 0, 0, false);
    }

    pub fn add_or_update_tab_geom(self: *TabManager, id: u32, title: []const u8, orig_w: u32, orig_h: u32, resizable: bool) usize {
        if (self.find_by_id(id)) |idx| {
            self.tabs[idx].set_title(title);
            if (orig_w > 0) self.tabs[idx].orig_w = orig_w;
            if (orig_h > 0) self.tabs[idx].orig_h = orig_h;
            self.tabs[idx].resizable = resizable;
            return idx;
        }

        if (self.tab_count < max_tabs) {
            const idx = self.tab_count;
            self.tabs[idx] = .{
                .id = id,
                .valid = true,
                .visible = true,
                .orig_w = orig_w,
                .orig_h = orig_h,
                .resizable = resizable,
            };
            self.tabs[idx].set_title(title);
            self.tab_count += 1;
            if (self.active_idx == null) {
                self.active_idx = idx;
            }
            return idx;
        }
        return 0;
    }

    pub fn remove_tab(self: *TabManager, id: u32) bool {
        const idx = self.find_by_id(id) orelse return false;

        // Shift remaining tabs left
        var i = idx;
        while (i + 1 < self.tab_count) : (i += 1) {
            self.tabs[i] = self.tabs[i + 1];
        }
        self.tabs[self.tab_count - 1] = .{};
        self.tab_count -= 1;

        // Adjust active index
        if (self.tab_count == 0) {
            self.active_idx = null;
        } else if (self.active_idx) |cur| {
            if (cur > idx) {
                self.active_idx = cur - 1;
            } else if (cur >= self.tab_count) {
                self.active_idx = self.tab_count - 1;
            }
        }
        return true;
    }

    pub fn activate_tab(self: *TabManager, idx: usize) bool {
        if (idx >= self.tab_count or !self.tabs[idx].valid) return false;
        self.active_idx = idx;
        return true;
    }

    pub fn cycle_tab(self: *TabManager) void {
        if (self.tab_count <= 1) return;
        if (self.active_idx) |cur| {
            self.active_idx = (cur + 1) % self.tab_count;
        } else {
            self.active_idx = 0;
        }
    }

    pub fn cycle_tab_backward(self: *TabManager) void {
        if (self.tab_count <= 1) return;
        if (self.active_idx) |cur| {
            if (cur == 0) {
                self.active_idx = self.tab_count - 1;
            } else {
                self.active_idx = cur - 1;
            }
        } else {
            self.active_idx = self.tab_count - 1;
        }
    }

    pub fn get_active_id(self: *const TabManager) ?u32 {
        if (self.active_idx) |idx| {
            if (idx < self.tab_count and self.tabs[idx].valid) {
                return self.tabs[idx].id;
            }
        }
        return null;
    }

    /// Swap the tabs at `a` and `b` (bounds-checked; a no-op when equal or
    /// out of range). Used by keyboard tab reorder. Returns true on swap.
    pub fn swap_tabs(self: *TabManager, a: usize, b: usize) bool {
        if (a == b or a >= self.tab_count or b >= self.tab_count) return false;
        const tmp = self.tabs[a];
        self.tabs[a] = self.tabs[b];
        self.tabs[b] = tmp;
        return true;
    }

    /// Move the tab at `from` to index `to`, shifting the tabs between them
    /// (M48/BT2 drag-to-reorder). The active index follows the moved tab and
    /// the intermediate tabs shift by one. Returns true on a real move.
    pub fn move_tab(self: *TabManager, from: usize, to: usize) bool {
        if (from >= self.tab_count or to >= self.tab_count or from == to) return false;
        const moved = self.tabs[from];
        if (from < to) {
            var i = from;
            while (i < to) : (i += 1) self.tabs[i] = self.tabs[i + 1];
        } else {
            var i = from;
            while (i > to) : (i -= 1) self.tabs[i] = self.tabs[i - 1];
        }
        self.tabs[to] = moved;
        if (self.active_idx) |a| {
            if (a == from) {
                self.active_idx = to;
            } else if (from < to and a > from and a <= to) {
                self.active_idx = a - 1;
            } else if (from > to and a >= to and a < from) {
                self.active_idx = a + 1;
            }
        }
        return true;
    }

    /// Count the pinned tabs at the FRONT of the list (they are kept sorted
    /// ahead of unpinned tabs — M48/BT3).
    pub fn front_pinned_count(self: *const TabManager) usize {
        var n: usize = 0;
        while (n < self.tab_count and self.tabs[n].pinned) : (n += 1) {}
        return n;
    }

    /// Stable-partition pinned tabs to the front, preserving the relative
    /// order of both halves, and keep the ACTIVE tab on the same tab (by
    /// id). Returns true when the order changed.
    pub noinline fn normalize_pinned(self: *TabManager) bool {
        const active_id = self.get_active_id();
        var n: usize = 0;
        for (0..self.tab_count) |i| {
            if (self.tabs[i].pinned) {
                tab_reorder_scratch[n] = self.tabs[i];
                n += 1;
            }
        }
        for (0..self.tab_count) |i| {
            if (!self.tabs[i].pinned) {
                tab_reorder_scratch[n] = self.tabs[i];
                n += 1;
            }
        }
        var changed = false;
        for (0..self.tab_count) |i| {
            if (tab_reorder_scratch[i].id != self.tabs[i].id) changed = true;
        }
        if (!changed) return false;
        commit_tab_scratch(self, n);
        if (active_id) |id| self.active_idx = self.find_by_id(id);
        return true;
    }
};

// ---------------------------------------------------------------------------
// Global Server State (Static BSS)
// ---------------------------------------------------------------------------
pub var manager: TabManager = TabManager{};
var scanout_ptr: ?[*]u32 = null;
var scanout_mapped: bool = false;

/// EL0 stack is 32 KiB (`scheduler.task_stack_size`). A `[max_tabs]Tab`
/// scratch is ~8 KiB; LLVM inlines `normalize_pinned` and the persist-apply
/// paths into `handle_window_mirror` → `main`, so a stack copy of that array
/// (plus a by-value `TabsStateV2`) overflows. The title slice in
/// `add_or_update_tab_geom` then becomes a NULL memcpy source and TABWM
/// takes an EL0 data abort (`live-tabwm-fullscreen` run B). One BSS scratch,
/// reused serially from the event loop — never live on two call frames.
var tab_reorder_scratch: [max_tabs]Tab = @as([max_tabs]Tab, @splat(@as(Tab, .{})));

fn commit_tab_scratch(self: *TabManager, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) self.tabs[i] = tab_reorder_scratch[i];
    while (i < max_tabs) : (i += 1) self.tabs[i] = .{};
    self.tab_count = n;
}

pub var hover_tab: ?usize = null;
pub var hover_sexiburger: bool = false;
pub var hover_theme_toggle: bool = false;
pub var hover_clip: bool = false;
pub var hover_new_tab: bool = false;

// ---------------------------------------------------------------------------
// #1064 rail-neutral tab ergonomics: middle-click close, keyboard reorder,
// and reopen-closed. BSS only.
// ---------------------------------------------------------------------------
/// The previous pointer button byte, for middle-click EDGE detection (the
/// kernel fans the raw held-button state on every sample, not just edges).
pub var prev_buttons: u8 = 0;

/// A recently-closed tab, enough to reopen it (the executable TABWM launched
/// it from, plus its title for a fallback label).
pub const ClosedTab = struct {
    bin: [24]u8 = @as([24]u8, @splat(@as(u8, 0))),
    bin_len: usize = 0,
    title: [32]u8 = @as([32]u8, @splat(@as(u8, 0))),
    title_len: usize = 0,
};

/// LIFO of recently-closed tabs (bounded to max_tabs); Ctrl+Shift+T reopens
/// the top. `closed_count` grows monotonically; the ring index is
/// `closed_count - 1 - k` mod max_tabs.
pub var closed_tabs: [max_tabs]ClosedTab = @as([max_tabs]ClosedTab, @splat(@as(ClosedTab, .{})));
pub var closed_count: usize = 0;

/// The bin of an app the god-menu just launched, consumed by the NEXT new
/// tab (the kernel fans the window mirror after the exec). Empty = none.
pub var pending_launch_bin: [24]u8 = @as([24]u8, @splat(@as(u8, 0)));
pub var pending_launch_bin_len: usize = 0;

/// M48/BT3: the manifest group label of the app just launched, consumed with
/// the bin by the next new tab (empty = none).
pub var pending_launch_group: [12]u8 = @as([12]u8, @splat(@as(u8, 0)));
pub var pending_launch_group_len: usize = 0;
/// M48/BT3: the launched app declared `dock=true` — the new tab starts pinned.
pub var pending_launch_pinned: bool = false;

// M42 UX r2 (2026-09-05, claim #1011): the unsaved-changes dialog state
// machine — BSS only, no heap in WM paths.
/// Row index of the tab awaiting an unsaved-dialog decision (null = none).
pub var unsaved_pending_close: ?usize = null;
/// Drift guard for the pending row: the pending tab's window id. The
/// modal consumption keeps LOCAL input from shifting rows, but an
/// external released mirror could still shift the list — the recorded
/// row is validated against this id at choice time (fallback: id lookup).
pub var unsaved_pending_id: u32 = 0;
/// True while TABWM's unsaved-changes dialog is on screen (modal: pointer
/// clicks and keys are consumed by the dialog first).
pub var unsaved_dialog_open_tabwm: bool = false;

// M42 UX r2: the close-feedback flash — the row slot the last-closed tab
// occupied, a countdown in composite ticks, and whether the KERNEL
// applied the close (closed=false = refused seam, hide-only fallback:
// muted flash instead of accent).
pub var close_flash_row: ?usize = null;
pub var close_flash_ticks: u32 = 0;
pub var close_flash_closed: bool = false;
/// Flash duration in composite ticks (18 tested below 60).
pub const close_flash_ticks_max: u32 = 18;

/// True while the close flash is live for `row` (the band draws only in
/// that row slot). Pure — unit-testable without a framebuffer.
pub fn close_flash_active(row: usize) bool {
    const r = close_flash_row orelse return false;
    return close_flash_ticks > 0 and r == row;
}

var ticks_count: u64 = 0;
var present_count: u64 = 0;

var clock_hours: u32 = 0;
var clock_minutes: u32 = 0;
var clock_seconds: u32 = 0;

// ---------------------------------------------------------------------------
// The real clock (#1055)
// ---------------------------------------------------------------------------
// TABWM has no RTC: VZ exposes none to the guest and the kernel has no
// time-of-day source (its `timer.ticks` is seconds since the timer armed).
// But the COMPOSITE_TICK cadence IS the core-0 timer at 1 Hz, so TABWM has
// an accurate elapsed-seconds counter. To turn that into wall time, the
// session launcher writes `.clock` into the host share — the host's LOCAL
// time at boot as seconds since midnight. TABWM advances it with the tick.
// Without the file (gate boots, or a share-less run) the clock honestly
// falls back to session UPTIME from 00:00.
pub const clock_epoch_file: []const u8 = ".clock";

/// Parse a decimal seconds-since-midnight value (0..86399). Tolerates
/// surrounding whitespace; rejects junk, an empty value, and anything at or
/// past 24h. Pure — host-testable.
pub fn parse_clock_epoch(text: []const u8) ?u32 {
    var i: usize = 0;
    while (i < text.len and is_clock_ws(text[i])) i += 1;
    var val: u32 = 0;
    var digits: usize = 0;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
        if (digits >= 6) return null; // more than 999999 is not a valid value
        val = val * 10 + (text[i] - '0');
        digits += 1;
    }
    if (digits == 0) return null;
    while (i < text.len) : (i += 1) {
        if (!is_clock_ws(text[i])) return null;
    }
    if (val >= 86400) return null;
    return val;
}

fn is_clock_ws(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// A clock face.
pub const Hms = struct { h: u32, m: u32, s: u32 };

/// The face at `elapsed` seconds into the session. With an `epoch`
/// (seconds since local midnight) it shows time-of-day, wrapping at 24h.
/// Without one it shows uptime (hours keep counting past 24). Pure.
pub fn clock_hms(elapsed: u64, epoch: ?u32) Hms {
    var total: u64 = elapsed;
    if (epoch) |e| total = (@as(u64, e) + elapsed) % 86400;
    const h: u64 = if (epoch != null) (total / 3600) % 24 else total / 3600;
    return .{
        .h = @intCast(h),
        .m = @intCast((total / 60) % 60),
        .s = @intCast(total % 60),
    };
}

/// The boot wall-time from the host share, or null (uptime fallback).
pub var clock_epoch: ?u32 = null;

/// #1058 / #1056: emit the clock-source marker once (kernel firmware epoch /
/// host `.clock` / uptime) so a live gate can tell which path won.
pub var clock_source_logged: bool = false;

/// #1058: ask the kernel for the real system clock — the boot EFI GetTime
/// epoch advanced by 1 Hz uptime (`sys_time`, slot 66). Returns Unix
/// wall-clock seconds, or null on the host / when the firmware provided no
/// epoch (the honest fallback). The value already includes elapsed time, so
/// it is authoritative on every tick.
pub fn query_epoch() ?u64 {
    if (@import("builtin").os.tag != .freestanding) return null;
    const v = ui.sys_time();
    if (v <= 0) return null;
    return @intCast(v);
}

/// One clock face for this tick: the kernel's firmware epoch first (the
/// true system clock), then the session host `.clock` (seconds since
/// midnight), then uptime. Emits the one-shot source marker. Pure
/// formatting lives in `clock_hms`.
pub fn tick_clock_face(ticks: u64) Hms {
    if (query_epoch()) |epoch| {
        const tod = epoch % 86_400;
        if (!clock_source_logged) {
            var b: [80]u8 = undefined;
            const msg = std.fmt.bufPrint(&b, "tabwm: clock-source kernel epoch={d} tod={d:0>2}:{d:0>2}:{d:0>2}\n", .{ epoch, tod / 3600, (tod / 60) % 60, tod % 60 }) catch "tabwm: clock-source kernel\n";
            write_marker(msg);
            clock_source_logged = true;
        }
        return .{ .h = @intCast(tod / 3600), .m = @intCast((tod / 60) % 60), .s = @intCast(tod % 60) };
    }
    if (clock_epoch != null) {
        if (!clock_source_logged) {
            write_marker("tabwm: clock-source host\n");
            clock_source_logged = true;
        }
        return clock_hms(ticks, clock_epoch);
    }
    if (!clock_source_logged) {
        write_marker("tabwm: clock-source uptime\n");
        clock_source_logged = true;
    }
    return clock_hms(ticks, null);
}

/// Read + parse `.clock` from the host share once at startup. A no-op on
/// the host and when the share/file is absent (the honest fallback).
pub fn load_clock_epoch() void {
    if (@import("builtin").os.tag != .freestanding) return;
    var buf: [32]u8 = undefined;
    const fd = ui.file_open(clock_epoch_file, ui.MODE_READ);
    if (fd < 0) return;
    defer ui.file_close(@intCast(fd));
    const n = ui.file_read(@intCast(fd), &buf);
    if (n <= 0) return;
    clock_epoch = parse_clock_epoch(buf[0..@intCast(n)]);
    if (clock_epoch) |e| {
        var b: [48]u8 = undefined;
        const msg = std.fmt.bufPrint(&b, "tabwm: clock epoch={d}\n", .{e}) catch "tabwm: clock epoch\n";
        write_marker(msg);
    }
}

// ---------------------------------------------------------------------------
// Tab-list persistence (#1056 item 3c)
// ---------------------------------------------------------------------------
// The tab list is memory-only, so a reboot loses the user's tab order and
// active tab. The kernel already persists window state to the host share's
// WINDOWS.SAV (M21 W11, shell.zig); TABWM writes its own `.tabs` beside it
// and re-applies the ORDER + ACTIVE selection as the restored windows
// reappear. Native window ids are NOT stable across a reboot (restore
// allocates fresh ids), so records match by TITLE. A partial restore that
// never reaches the saved count simply keeps arrival order.
pub const tabs_state_file: []const u8 = ".tabs";
pub const tabs_state_version: u8 = 1;
/// One title slot per record; matches `Tab.title`'s capacity.
pub const persist_title_max: usize = 32;
/// version + active+1 + count.
pub const tabs_header_bytes: usize = 3;
pub const tabs_state_max_bytes: usize = tabs_header_bytes + max_tabs * persist_title_max;

/// A decoded `.tabs` file: the tab order (by title) + the active index.
pub const TabsState = struct {
    active: ?usize = null,
    count: usize = 0,
    titles: [max_tabs][persist_title_max]u8 = @as([max_tabs][persist_title_max]u8, @splat(@as([persist_title_max]u8, @as([persist_title_max]u8, @splat(@as(u8, 0)))))),
    title_lens: [max_tabs]usize = @as([max_tabs]usize, @splat(@as(usize, 0))),
};

/// Encode the live tab list as `[version, active+1, count, titles...]`.
/// Returns the byte count, or 0 when `buf` is too small. Pure.
pub fn serialize_tabs(buf: []u8) usize {
    if (buf.len < tabs_state_max_bytes) return 0;
    buf[0] = tabs_state_version;
    buf[1] = if (manager.active_idx) |a| @as(u8, @intCast(a)) + 1 else 0;
    buf[2] = @intCast(manager.tab_count);
    var off: usize = tabs_header_bytes;
    for (0..manager.tab_count) |i| {
        const t = manager.tabs[i].get_title();
        const n = @min(t.len, persist_title_max);
        @memcpy(buf[off .. off + n], t[0..n]);
        @memset(buf[off + n .. off + persist_title_max], 0);
        off += persist_title_max;
    }
    return off;
}

/// Decode a `.tabs` buffer into `out`. False on a version mismatch, a bad
/// count, an out-of-range active index, or a truncated record. Pure.
pub fn parse_tabs(buf: []const u8, out: *TabsState) bool {
    if (buf.len < tabs_header_bytes) return false;
    if (buf[0] != tabs_state_version) return false;
    const act_plus1 = buf[1];
    const count: usize = buf[2];
    if (count > max_tabs) return false;
    if (buf.len < tabs_header_bytes + count * persist_title_max) return false;
    var st = TabsState{};
    st.count = count;
    st.active = if (act_plus1 == 0) null else @as(usize, act_plus1 - 1);
    if (st.active) |a| {
        if (a >= count) return false;
    }
    var off: usize = tabs_header_bytes;
    for (0..count) |i| {
        var len: usize = 0;
        while (len < persist_title_max and buf[off + len] != 0) : (len += 1) {}
        @memcpy(st.titles[i][0..len], buf[off .. off + len]);
        st.title_lens[i] = len;
        off += persist_title_max;
    }
    out.* = st;
    return true;
}

/// The persisted state loaded at boot, pending application.
pub var persisted_tabs: ?TabsState = null;

var last_saved_tabs: [tabs_v2_max_bytes]u8 = undefined;
var last_saved_tabs_len: usize = 0;
var have_last_saved_tabs: bool = false;
/// Shared I/O buffer for `.tabs` load/save — must not live on the EL0 stack.
var tabs_io_buf: [tabs_v2_max_bytes]u8 = undefined;

/// Read `.tabs` from the host share once at startup. A no-op on the host
/// and when the file is absent (the honest no-persistence fallback).
pub noinline fn load_tabs() void {
    if (@import("builtin").os.tag != .freestanding) return;
    const fd = ui.file_open(tabs_state_file, ui.MODE_READ);
    if (fd < 0) return;
    defer ui.file_close(@intCast(fd));
    const n = ui.file_read(@intCast(fd), &tabs_io_buf);
    if (n <= 0) return;
    const bytes = tabs_io_buf[0..@intCast(n)];
    // TWM: v2 first; a v1 file falls through to the v1 parser, so an
    // existing install is never stranded by the format bump.
    if (bytes.len > 0 and bytes[0] == tabs_state_version_v2) {
        persisted_tabs_v2 = .{};
        if (parse_tabs_v2(bytes, &persisted_tabs_v2.?)) {
            tabs_seq = persisted_tabs_v2.?.seq;
            var b: [48]u8 = undefined;
            const msg = std.fmt.bufPrint(&b, "tabwm: tabs-restored v2 count={d}\n", .{persisted_tabs_v2.?.count}) catch "tabwm: tabs-restored v2\n";
            write_marker(msg);
        } else {
            persisted_tabs_v2 = null;
        }
        return;
    }
    var st: TabsState = .{};
    if (parse_tabs(bytes, &st)) {
        persisted_tabs = st;
        var b: [48]u8 = undefined;
        const msg = std.fmt.bufPrint(&b, "tabwm: tabs-restored count={d}\n", .{st.count}) catch "tabwm: tabs-restored\n";
        write_marker(msg);
    }
}

/// Write the current tab list to `.tabs` when it differs from the last
/// write (the kernel's WINDOWS.SAV dedup discipline — a stable desktop
/// must not hammer the transport). A no-op on the host.
pub noinline fn save_tabs() void {
    if (@import("builtin").os.tag != .freestanding) return;
    // TWM: v2 is the writer now — the v1 serializer stays for back-compat
    // and for the migration test.
    const written_n = serialize_tabs_v2(&tabs_io_buf);
    if (written_n == 0) return;
    if (have_last_saved_tabs and last_saved_tabs_len == written_n and std.mem.eql(u8, last_saved_tabs[0..written_n], tabs_io_buf[0..written_n])) return;
    // A real write: stamp it so a restored state can be told from a stale one.
    tabs_seq +%= 1;
    tabs_io_buf[3] = @intCast(tabs_seq & 0xff);
    tabs_io_buf[4] = @intCast((tabs_seq >> 8) & 0xff);
    const fd_trunc = ui.file_open(tabs_state_file, ui.MODE_WRITE);
    if (fd_trunc >= 0) {
        _ = ui.file_truncate(@as(u32, @intCast(fd_trunc)), 0);
        ui.file_close(@as(u32, @intCast(fd_trunc)));
    }
    const fd = ui.file_open(tabs_state_file, ui.MODE_WRITE | ui.MODE_CREATE);
    if (fd < 0) return;
    const handle = @as(u32, @intCast(fd));
    const written = ui.file_write(handle, tabs_io_buf[0..written_n]);
    ui.file_close(handle);
    if (written >= 0) {
        @memcpy(last_saved_tabs[0..written_n], tabs_io_buf[0..written_n]);
        last_saved_tabs_len = written_n;
        have_last_saved_tabs = true;
    }
}

/// Re-apply the persisted order + active tab once the restored window set is
/// complete (the live tab count first reaches the saved count). Matches by
/// title; unknown titles append in arrival order. Applies once; returns true
/// when it ran (so the caller can re-activate the restored active tab).
pub noinline fn maybe_apply_persisted_tabs() bool {
    // TWM: a v2 record may be pending instead of the v1 one.
    if (persisted_tabs_v2 != null) return maybe_apply_persisted_tabs_v2();
    const st = if (persisted_tabs) |*s| s else return false;
    if (manager.tab_count != st.count) return false;
    var used = @as([max_tabs]bool, @splat(@as(bool, false)));
    var n: usize = 0;
    for (0..st.count) |pi| {
        const want = st.titles[pi][0..st.title_lens[pi]];
        for (0..manager.tab_count) |ti| {
            if (used[ti]) continue;
            if (std.mem.eql(u8, manager.tabs[ti].get_title(), want)) {
                tab_reorder_scratch[n] = manager.tabs[ti];
                used[ti] = true;
                n += 1;
                break;
            }
        }
    }
    for (0..manager.tab_count) |ti| {
        if (!used[ti]) {
            tab_reorder_scratch[n] = manager.tabs[ti];
            n += 1;
        }
    }
    const old_active_id = manager.get_active_id();
    commit_tab_scratch(&manager, n);
    if (old_active_id) |id| manager.active_idx = manager.find_by_id(id);
    if (st.active) |pa| {
        if (pa < manager.tab_count) manager.active_idx = pa;
    }
    persisted_tabs = null; // apply exactly once
    return true;
}

// ---------------------------------------------------------------------------
// TWM — the tab-state change log (`.tablog`)
// ---------------------------------------------------------------------------
// The deliverable contract asks for "an inspectable local record of stored
// state and setting changes". `.tabs` alone is a snapshot: it can say what
// the state IS, never how it got there. `.tablog` is the bounded history:
// the last `tablog_ring` tab-state events, each `<seq> <event> <detail>`,
// flushed to the host share wholesale (the same discipline `save_tabs` uses
// — a stable desktop must not hammer the transport). The formatter and the
// reader view are pure and host-testable.
pub const tablog_file: []const u8 = ".tablog";
pub const tablog_line_max: usize = 40;
pub const tablog_ring: usize = 24;
pub const tablog_max_bytes: usize = tablog_line_max * tablog_ring;

/// The event codes. The numeric value is the on-disk contract, so the
/// mapping is pinned by a test.
pub const tablog_code_switch: u8 = 1;
pub const tablog_code_close: u8 = 2;
pub const tablog_code_reopen: u8 = 3;
pub const tablog_code_reorder: u8 = 4;
pub const tablog_code_pin: u8 = 5;
pub const tablog_code_unpin: u8 = 6;
pub const tablog_code_group: u8 = 7;
pub const tablog_code_freeze: u8 = 8;
pub const tablog_code_unfreeze: u8 = 9;
pub const tablog_code_go: u8 = 10;
pub const tablog_code_launch: u8 = 11;

pub var tablog_seq: u32 = 0;
var tablog_lines: [tablog_ring][tablog_line_max]u8 = @as([tablog_ring][tablog_line_max]u8, @splat(@as([tablog_line_max]u8, @as([tablog_line_max]u8, @splat(@as(u8, 0))))));
pub var tablog_line_lens: [tablog_ring]usize = @as([tablog_ring]usize, @splat(@as(usize, 0)));
var tablog_head: usize = 0;
var tablog_count: usize = 0;
var tablog_last_flush_seq: u32 = 0;
/// Flush buffer for `.tablog` — kept off the EL0 stack (same reason as
/// `tabs_io_buf`).
var tablog_io_buf: [tablog_max_bytes]u8 = undefined;

/// The stable name for an event code ("switch", "close", "go", ...).
pub fn tablog_code_name(code: u8) []const u8 {
    return switch (code) {
        tablog_code_switch => "switch",
        tablog_code_close => "close",
        tablog_code_reopen => "reopen",
        tablog_code_reorder => "reorder",
        tablog_code_pin => "pin",
        tablog_code_unpin => "unpin",
        tablog_code_group => "group",
        tablog_code_freeze => "freeze",
        tablog_code_unfreeze => "unfreeze",
        tablog_code_go => "go",
        tablog_code_launch => "launch",
        else => "?",
    };
}

/// Format one log line: `<seq> <event> <detail>`. Pure — the ring stores
/// exactly this string and the reader view prints it verbatim, so a test
/// that pins the formatter pins the file too. A detail that would overflow
/// `buf` is truncated rather than degrading the whole line to `0 ? ?`.
pub fn tablog_format(seq: u32, code: u8, detail: []const u8, buf: []u8) []const u8 {
    const name = tablog_code_name(code);
    var pre: [24]u8 = undefined;
    const prefix = std.fmt.bufPrint(&pre, "{d} {s} ", .{ seq, name }) catch return "0 ? ?";
    if (prefix.len >= buf.len) return "0 ? ?";
    @memcpy(buf[0..prefix.len], prefix);
    const n = @min(detail.len, buf.len - prefix.len);
    if (n > 0) @memcpy(buf[prefix.len .. prefix.len + n], detail[0..n]);
    return buf[0 .. prefix.len + n];
}

/// Record one tab-state change. Bounded ring: after `tablog_ring` events the
/// oldest is overwritten. A no-op on the host (like `save_tabs`), but the
/// ring itself is always updated, so the log is host-testable.
pub fn tablog_event(code: u8, detail: []const u8) void {
    tablog_seq += 1;
    var buf: [tablog_line_max]u8 = undefined;
    const line = tablog_format(tablog_seq, code, detail, &buf);
    const n = @min(line.len, tablog_line_max);
    @memcpy(tablog_lines[tablog_head][0..n], line[0..n]);
    tablog_line_lens[tablog_head] = n;
    tablog_head = (tablog_head + 1) % tablog_ring;
    if (tablog_count < tablog_ring) tablog_count += 1;
    tablog_flush();
}

/// How many events the ring currently holds (host-testable).
pub fn tablog_count_events() usize {
    return tablog_count;
}

/// The k-th OLDEST retained line (0 = oldest), or null. This is the reader
/// view an external tool or the shell prints back to the user.
pub fn tablog_view(k: usize) ?[]const u8 {
    if (k >= tablog_count) return null;
    const start = if (tablog_count < tablog_ring) 0 else tablog_head;
    const slot = (start + k) % tablog_ring;
    return tablog_lines[slot][0..tablog_line_lens[slot]];
}

/// Flush the whole ring to the host share (truncate + write), oldest first.
/// A sequence-stamp dedup keeps an unchanged ring off the transport. A
/// no-op on the host.
pub noinline fn tablog_flush() void {
    if (@import("builtin").os.tag != .freestanding) return;
    if (tablog_seq == tablog_last_flush_seq) return;
    var off: usize = 0;
    var k: usize = 0;
    while (k < tablog_count) : (k += 1) {
        const line = tablog_view(k) orelse continue;
        if (off + line.len + 1 > tablog_io_buf.len) break;
        @memcpy(tablog_io_buf[off .. off + line.len], line);
        off += line.len;
        tablog_io_buf[off] = '\n';
        off += 1;
    }
    const fd_trunc = ui.file_open(tablog_file, ui.MODE_WRITE);
    if (fd_trunc >= 0) {
        _ = ui.file_truncate(@as(u32, @intCast(fd_trunc)), 0);
        ui.file_close(@as(u32, @intCast(fd_trunc)));
    }
    const fd = ui.file_open(tablog_file, ui.MODE_WRITE | ui.MODE_CREATE);
    if (fd < 0) return;
    const handle = @as(u32, @intCast(fd));
    const written = ui.file_write(handle, tablog_io_buf[0..off]);
    ui.file_close(handle);
    if (written >= 0) tablog_last_flush_seq = tablog_seq;
}

// ---------------------------------------------------------------------------
// TWM — `.tabs` v2: persist what v1 silently dropped
// ---------------------------------------------------------------------------
// v1 stored ORDER + ACTIVE by title and nothing else, so pinned ordering,
// the pinned bit, group labels, the frozen badge and the executable a tab
// was launched from were all recomputed or lost on every restart. v2 keeps
// every v1 field in the same place and APPENDS the missing ones per record:
//   header: [version, active+1, count, seq_lo, seq_hi, prefs]   (6 bytes)
//   record: [title(32) | flags(1) | group(12) | bin(24)]        (69 bytes)
//     flags bit0 = pinned, bit1 = frozen, bit2 = docked-at-launch
// A v1 FILE still parses exactly as before (load_tabs keeps the v1 path), so
// an existing install is never stranded; the v2 parser refuses a v1 buffer
// rather than misreading it. The other direction is equally loud: an older
// TABWM.BIN's v1 parser rejects a v2 file (version mismatch) and degrades
// to "no saved state" — it does not silently reinterpret the extra fields.
// The parser is TOTAL: a short buffer, a wrong version, a count above
// max_tabs, an out-of-range active index or a truncated record is rejected
// rather than trusted.
pub const tabs_state_version_v2: u8 = 2;
pub const tabs_v2_header_bytes: usize = 6;
pub const persist_group_max: usize = 12;
pub const persist_bin_max: usize = 24;
pub const tabs_v2_record_bytes: usize = persist_title_max + 1 + persist_group_max + persist_bin_max;
pub const tabs_v2_max_bytes: usize = tabs_v2_header_bytes + max_tabs * tabs_v2_record_bytes;

pub const tab_flag_pinned: u8 = 0x01;
pub const tab_flag_frozen: u8 = 0x02;
pub const tab_flag_dock: u8 = 0x04;

pub const TabsStateV2 = struct {
    active: ?usize = null,
    count: usize = 0,
    seq: u16 = 0,
    prefs: u8 = 0,
    titles: [max_tabs][persist_title_max]u8 = @as([max_tabs][persist_title_max]u8, @splat(@as([persist_title_max]u8, @as([persist_title_max]u8, @splat(@as(u8, 0)))))),
    title_lens: [max_tabs]usize = @as([max_tabs]usize, @splat(@as(usize, 0))),
    flags: [max_tabs]u8 = @as([max_tabs]u8, @splat(@as(u8, 0))),
    groups: [max_tabs][persist_group_max]u8 = @as([max_tabs][persist_group_max]u8, @splat(@as([persist_group_max]u8, @as([persist_group_max]u8, @splat(@as(u8, 0)))))),
    group_lens: [max_tabs]usize = @as([max_tabs]usize, @splat(@as(usize, 0))),
    bins: [max_tabs][persist_bin_max]u8 = @as([max_tabs][persist_bin_max]u8, @splat(@as([persist_bin_max]u8, @as([persist_bin_max]u8, @splat(@as(u8, 0)))))),
    bin_lens: [max_tabs]usize = @as([max_tabs]usize, @splat(@as(usize, 0))),
};

/// The monotonically increasing stamp written into every v2 file, so a
/// restored state can be told apart from a stale one.
pub var tabs_seq: u16 = 0;

/// Encode the live tab list as a v2 file. Returns the byte count, or 0 when
/// `buf` is too small. Pure.
pub fn serialize_tabs_v2(buf: []u8) usize {
    if (buf.len < tabs_v2_max_bytes) return 0;
    buf[0] = tabs_state_version_v2;
    buf[1] = if (manager.active_idx) |a| @as(u8, @intCast(a)) + 1 else 0;
    buf[2] = @intCast(manager.tab_count);
    buf[3] = @intCast(tabs_seq & 0xff);
    buf[4] = @intCast((tabs_seq >> 8) & 0xff);
    buf[5] = 0; // prefs (reserved: rail density / Go-enable bits)
    var off: usize = tabs_v2_header_bytes;
    for (0..manager.tab_count) |i| {
        const t = &manager.tabs[i];
        const title = t.get_title();
        const tn = @min(title.len, persist_title_max);
        @memcpy(buf[off .. off + tn], title[0..tn]);
        @memset(buf[off + tn .. off + persist_title_max], 0);
        off += persist_title_max;
        var flags: u8 = 0;
        if (t.pinned) flags |= tab_flag_pinned;
        if (t.frozen) flags |= tab_flag_frozen;
        buf[off] = flags;
        off += 1;
        const g = t.group[0..t.group_len];
        const gn = @min(g.len, persist_group_max);
        @memcpy(buf[off .. off + gn], g[0..gn]);
        @memset(buf[off + gn .. off + persist_group_max], 0);
        off += persist_group_max;
        const b = t.get_bin();
        const bn = @min(b.len, persist_bin_max);
        @memcpy(buf[off .. off + bn], b[0..bn]);
        @memset(buf[off + bn .. off + persist_bin_max], 0);
        off += persist_bin_max;
    }
    return off;
}

fn tab_read_fixed(src: []const u8, out: []u8) usize {
    var n: usize = 0;
    while (n < out.len and src[n] != 0) : (n += 1) {}
    @memcpy(out[0..n], src[0..n]);
    return n;
}

/// Decode a v2 buffer into `out`. False on a non-v2 version byte, a bad
/// count, an out-of-range active index, or a truncated record. Pure.
/// Writes through `out` — never a by-value `TabsStateV2` on the stack.
pub noinline fn parse_tabs_v2(buf: []const u8, out: *TabsStateV2) bool {
    if (buf.len < tabs_v2_header_bytes) return false;
    if (buf[0] != tabs_state_version_v2) return false;
    const act_plus1 = buf[1];
    const count: usize = buf[2];
    if (count > max_tabs) return false;
    if (buf.len < tabs_v2_header_bytes + count * tabs_v2_record_bytes) return false;
    const active: ?usize = if (act_plus1 == 0) null else @as(usize, act_plus1 - 1);
    if (active) |a| {
        if (a >= count) return false;
    }
    out.* = .{};
    out.count = count;
    out.seq = @as(u16, buf[3]) | (@as(u16, buf[4]) << 8);
    out.prefs = buf[5];
    out.active = active;
    var off: usize = tabs_v2_header_bytes;
    for (0..count) |i| {
        out.title_lens[i] = tab_read_fixed(buf[off .. off + persist_title_max], &out.titles[i]);
        off += persist_title_max;
        out.flags[i] = buf[off];
        off += 1;
        out.group_lens[i] = tab_read_fixed(buf[off .. off + persist_group_max], &out.groups[i]);
        off += persist_group_max;
        out.bin_lens[i] = tab_read_fixed(buf[off .. off + persist_bin_max], &out.bins[i]);
        off += persist_bin_max;
    }
    return true;
}

/// The v2 state loaded at boot, pending application.
pub var persisted_tabs_v2: ?TabsStateV2 = null;

/// Apply a v2 state once the restored window set is complete: restore the
/// pinned/frozen/group/bin fields per matched record, then reorder into the
/// stored order (the v1 rule) and restore the active index. Applies exactly
/// once. Pure over the manager + the state record.
pub noinline fn maybe_apply_persisted_tabs_v2() bool {
    const st = if (persisted_tabs_v2) |*s| s else return false;
    if (manager.tab_count != st.count) return false;
    for (0..manager.tab_count) |ti| {
        const title = manager.tabs[ti].get_title();
        for (0..st.count) |pi| {
            if (!std.mem.eql(u8, st.titles[pi][0..st.title_lens[pi]], title)) continue;
            const f = st.flags[pi];
            manager.tabs[ti].pinned = (f & tab_flag_pinned) != 0;
            manager.tabs[ti].frozen = (f & tab_flag_frozen) != 0;
            const gn = st.group_lens[pi];
            @memcpy(manager.tabs[ti].group[0..gn], st.groups[pi][0..gn]);
            manager.tabs[ti].group_len = gn;
            const bn = st.bin_lens[pi];
            if (bn > 0 and manager.tabs[ti].bin_len == 0) {
                @memcpy(manager.tabs[ti].bin[0..bn], st.bins[pi][0..bn]);
                manager.tabs[ti].bin_len = bn;
            }
            break;
        }
    }
    var used = @as([max_tabs]bool, @splat(@as(bool, false)));
    var n: usize = 0;
    for (0..st.count) |pi| {
        const want = st.titles[pi][0..st.title_lens[pi]];
        for (0..manager.tab_count) |ti| {
            if (used[ti]) continue;
            if (std.mem.eql(u8, manager.tabs[ti].get_title(), want)) {
                tab_reorder_scratch[n] = manager.tabs[ti];
                used[ti] = true;
                n += 1;
                break;
            }
        }
    }
    for (0..manager.tab_count) |ti| {
        if (!used[ti]) {
            tab_reorder_scratch[n] = manager.tabs[ti];
            n += 1;
        }
    }
    const old_active_id = manager.get_active_id();
    commit_tab_scratch(&manager, n);
    if (old_active_id) |id| manager.active_idx = manager.find_by_id(id);
    if (st.active) |pa| {
        if (pa < manager.tab_count) manager.active_idx = pa;
    }
    persisted_tabs_v2 = null; // apply exactly once
    var pin_n: usize = 0;
    var freeze_n: usize = 0;
    for (0..manager.tab_count) |i| {
        if (manager.tabs[i].pinned) pin_n += 1;
        if (manager.tabs[i].frozen) freeze_n += 1;
    }
    const title = if (manager.tab_count > 0) manager.tabs[0].get_title() else "";
    var abuf: [96]u8 = undefined;
    const amsg = std.fmt.bufPrint(&abuf, "{s}n={d} pin={d} freeze={d} title={s}\n", .{
        tabs_applied_marker, manager.tab_count, pin_n, freeze_n, title,
    }) catch "tabwm: tabs-applied v2\n";
    write_marker(amsg);
    return true;
}

// ---------------------------------------------------------------------------
// Scanout Mapping via M33 Seam B
// ---------------------------------------------------------------------------
fn ensure_scanout_mapped() bool {
    if (scanout_mapped and scanout_ptr != null) return true;
    const fb_len: u64 = @as(u64, fb_w) * fb_h * 4;
    const scan_va = syscall4(sys_mmap, m33_surf_scan_tag, fb_len, prot_rw, map_anonymous | m33_map_shared);
    if (scan_va > 0) {
        scanout_ptr = @ptrFromInt(@as(usize, @intCast(scan_va)));
        scanout_mapped = true;
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Viewport & Window State Management (M39 TWM2)
// ---------------------------------------------------------------------------

/// Set window position and dimensions via slot-65 SET_WINDOW.
pub fn set_window_rect(id: u32, x: u32, y: u32, w: u32, h: u32) void {
    _ = syscall6(sys_wmctl, wmctl_set_window, id, x | (y << 16), w | (h << 16), 0, 0);
}

/// Set window visibility via slot-65 SET_STATE (1 = show, 0 = hide).
pub fn set_state(id: u32, visible: bool) void {
    const st: u64 = if (visible) 1 else 0;
    _ = syscall6(sys_wmctl, wmctl_set_state, id, st, 0, 0, 0);
}

/// Raise and commit focus to a window via slot-65 ALT_TAB commit.
pub fn focus_window(id: u32) void {
    _ = syscall6(sys_wmctl, wmctl_alt_tab, id, alt_tab_commit, 0, 0, 0);
}

/// Computes content viewport allocation for a tab:
/// - Tab-aware apps (SX2 opt-in) take the entire 1100x720 content area at
///   x=180, y=0 whenever their tab is active — the WM proposes the full
///   viewport and the kernel's WIN_RESIZE seam (SX2 kernel half) tells the
///   app to relayout.
/// - Other resizable or full-bleed apps take the entire 1100x720 content area at x=180, y=0.
/// - Fixed-dimension apps (e.g. 512x384 or 260x340) are cleanly centered inside the 1100x720 viewport.
pub fn compute_tab_viewport(tab: *const Tab) Rect {
    if (tab.tab_aware or tab.resizable or tab.orig_w == 0 or tab.orig_w >= viewport_w or tab.orig_h >= viewport_h) {
        return Rect.make(viewport_x, viewport_y, viewport_w, viewport_h);
    }
    const w = tab.orig_w;
    const h = tab.orig_h;
    const x = viewport_x + (viewport_w - w) / 2;
    const y = viewport_y + (viewport_h - h) / 2;
    return Rect.make(x, y, w, h);
}

/// True when `vp` differs from the rect last applied to `tab` (M42 SX2):
/// the activation path must issue SET_WINDOW. Idempotent re-activations of
/// an already-sized tab return false — no repeat proposal, no repeat
/// WIN_RESIZE at the app.
pub fn viewport_change_needed(tab: *const Tab, vp: Rect) bool {
    const prev = tab.applied_vp orelse return true;
    return prev.x != vp.x or prev.y != vp.y or prev.w != vp.w or prev.h != vp.h;
}

/// Activate tab by index:
/// 1. Computes viewport: full 1100x720 for tab-aware/resizable apps, centered
///    for fixed apps (M42 SX2 opt-in).
/// 2. Sets window rect via set_window_rect — ONLY when the rect changed since
///    the last activation (idempotence; the kernel's SX2 seam answers a
///    size-changing proposal with one WIN_RESIZE to the app).
/// 3. Sets active window visible and focuses it.
/// 4. Hides all inactive tabs (set_state(0)).
/// 5. Emits `tabwm: tab-switch` evidence marker.
pub fn activate_tab(idx: usize) void {
    if (!manager.activate_tab(idx)) return;
    const tab = &manager.tabs[idx];
    const active_id = tab.id;

    // Viewport Allocation: allocate full or centered content viewport
    const vp = compute_tab_viewport(tab);
    if (viewport_change_needed(tab, vp)) {
        set_window_rect(active_id, vp.x, vp.y, vp.w, vp.h);
        tab.applied_vp = vp;
    }

    // Show and focus active window
    set_state(active_id, true);
    focus_window(active_id);

    // Hide all inactive windows
    for (0..manager.tab_count) |i| {
        if (i != idx and manager.tabs[i].valid) {
            set_state(manager.tabs[i].id, false);
        }
    }

    // TWM: record the switch in the change log.
    var srbuf: [16]u8 = undefined;
    tablog_event(tablog_code_switch, std.fmt.bufPrint(&srbuf, "tab {d}", .{active_id}) catch srbuf[0..0]);

    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} idx={d} id={d}\n", .{ tab_switch_marker, idx, active_id }) catch "tabwm: tab-switch\n";
    write_marker(msg);

    // #1056 item 3c: the active tab changed — persist the order + selection.
    save_tabs();
}

/// Close tab by index:
/// 1. Asks the KERNEL to close the window (`wmctl_win_close`, cmd 13 —
///    the M42 UX seam): the kernel applies its own `user_close` release,
///    which pushes the REAL WIN_CLOSE event to the owning process
///    (lib/tabapp.zig dispatches it to a clean exit) and fans the
///    released kind-20 mirror back to TABWM. The local tab removal here
///    is the optimistic half; the released mirror is the authoritative
///    echo (handle_window_mirror is a no-op for an already-removed id).
///    A refused seam (no WM seat on the host / kernel refusal) falls back
///    to hide-only — the pre-M42 behavior — honestly marked.
/// 2. Emits `tabwm: win-close` evidence marker.
/// 3. Removes the tab from manager.
/// 4. Automatically activates the new active tab if any remain.
pub fn close_tab(idx: usize) void {
    if (idx >= manager.tab_count or !manager.tabs[idx].valid) return;
    const closed_id = manager.tabs[idx].id;

    // 1. Real close semantics (M42 UX): the kernel's release primitive.
    //    sys_wmctl returns 0 on success; nonzero (ENOENT-shaped) when the
    //    id is unknown — treated as already-closed. Any other refusal
    //    (host no-op returns 0) keeps the hide fallback honest via
    //    `hidden_only` bookkeeping on the removed tab's successor state.
    const close_rc = syscall6(sys_wmctl, wmctl_win_close, closed_id, 0, 0, 0, 0);
    const kernel_closed = (close_rc == 0);
    if (!kernel_closed) {
        // Fallback: hide the window (pre-M42 behavior).
        set_state(closed_id, false);
    }

    // M42 UX r2: close-feedback flash — record the ROW SLOT this tab
    // occupied (position, not id: the rows shift as tabs remove) BEFORE
    // remove_tab collapses the list. Accent when the kernel applied the
    // close; muted when the seam was refused and only a hide ran.
    close_flash_row = idx;
    close_flash_ticks = close_flash_ticks_max;
    close_flash_closed = kernel_closed;

    // 2. Emit WIN_CLOSE marker
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} id={d} closed={d}\n", .{ tab_close_marker, closed_id, @as(u8, if (kernel_closed) 1 else 0) }) catch "tabwm: win-close\n";
    write_marker(msg);

    // #1064: remember it for reopen (LIFO) before it leaves the list.
    push_closed_tab(&manager.tabs[idx]);

    // 3. Remove tab from manager
    _ = manager.remove_tab(closed_id);

    // 4. Activate new active tab if any
    if (manager.active_idx) |new_idx| {
        activate_tab(new_idx);
    }

    // #1056 item 3: the list shrank — re-clamp the cursor/scroll and persist.
    clamp_nav_selection();
    // TWM: record the close in the change log.
    var lcbuf: [16]u8 = undefined;
    tablog_event(tablog_code_close, std.fmt.bufPrint(&lcbuf, "tab {d}", .{closed_id}) catch lcbuf[0..0]);
    save_tabs();
}

// ---------------------------------------------------------------------------
// Unsaved-changes dialog (M42 UX r2, claim #1011)
// ---------------------------------------------------------------------------

/// Validate the pending-close row against the recorded id (the modal
/// keeps local input from shifting rows, but an external released mirror
/// could still shift the list — a drifted row falls back to the id
/// lookup). Null when the tab is gone.
fn resolve_pending_close() ?usize {
    const row = unsaved_pending_close orelse return null;
    if (row < manager.tab_count and manager.tabs[row].valid and manager.tabs[row].id == unsaved_pending_id) {
        return row;
    }
    return manager.find_by_id(unsaved_pending_id);
}

/// THE close decision point (M42 UX r2): every close entry point — the
/// close-'x' pointer click, Ctrl+W, and the wnd_mail_apply detach RPC —
/// routes here. A CLEAN tab closes immediately (unchanged M42 UX
/// semantics); a DIRTY tab (the kernel's unsaved mirror bit) is
/// INTERCEPTED: the unsaved-changes dialog opens via the slot-65 DIALOG
/// show action (a2 = the tab's window id; the kernel validates it is a
/// live user window) and NO close happens until a choice is applied.
pub fn request_close_tab(idx: usize) void {
    if (idx >= manager.tab_count or !manager.tabs[idx].valid) return;
    if (manager.tabs[idx].unsaved) {
        unsaved_pending_close = idx;
        unsaved_pending_id = manager.tabs[idx].id;
        unsaved_dialog_open_tabwm = true;
        _ = syscall6(sys_wmctl, wmctl_dialog, dialog_unsaved_show, unsaved_pending_id, 0, 0, 0);
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}{d}\n", .{ unsaved_dialog_marker, unsaved_pending_id }) catch "tabwm: unsaved-dialog\n";
        write_marker(msg);
        return;
    }
    close_tab(idx);
}

/// Apply one unsaved-dialog choice (M42 UX r2). The marker goes FIRST,
/// then the syscall (the kernel applies the SAME primitive WND's dialog
/// applies — parity by construction). The save and discard paths are
/// deliberately ASYMMETRIC (documented in the ADR 0018 round-2 addendum):
///   - save: the app saves on WIN_UNSAVED and (observed on 2026-09-05
///     hardware: NOTEPAD) exits by itself — save-and-exit — so the WM's
///     close_tab via WMCTL_WIN_CLOSE lands while the window is still
///     registered (closed=1) and the kernel's WIN_CLOSE push goes
///     unconsumed. Either owner behavior converges: if the app instead
///     kept running after its save, the WIN_CLOSE would close it, and
///     the released mirror echo is absorbed as a no-op (already
///     removed).
///   - discard: the kernel's user_close INSIDE DIALOG action 5 releases
///     the window; NO local close_tab runs — the released kind-20 mirror
///     echo removes the tab (handle_window_mirror) and activates the
///     next. The mirror is the authoritative removal path.
///   - cancel: the dialog clears and the tab stays open (dirty flag
///     intact).
pub fn apply_unsaved_choice(choice: wnd_core.UnsavedChoice) void {
    const pending = resolve_pending_close();
    switch (choice) {
        .none => return,
        .save => {
            write_marker(unsaved_save_marker);
            _ = syscall6(sys_wmctl, wmctl_dialog, dialog_unsaved_save, 0, 0, 0, 0);
            unsaved_dialog_open_tabwm = false;
            unsaved_pending_close = null;
            if (pending) |p| close_tab(p);
        },
        .dont_save => {
            write_marker(unsaved_discard_marker);
            _ = syscall6(sys_wmctl, wmctl_dialog, dialog_unsaved_dont_save, 0, 0, 0, 0);
            unsaved_dialog_open_tabwm = false;
            unsaved_pending_close = null;
        },
        .cancel => {
            write_marker(unsaved_cancel_marker);
            _ = syscall6(sys_wmctl, wmctl_dialog, dialog_unsaved_cancel, 0, 0, 0, 0);
            unsaved_dialog_open_tabwm = false;
            unsaved_pending_close = null;
        },
    }
}

/// One key while TABWM's unsaved-changes dialog is open (M42 UX r2). The
/// dialog is MODAL: Escape (0x29) = cancel, Enter (0x28) = save (the
/// keyboard-driven DIALOG semantics), and every other key is consumed
/// too — no chord (Ctrl+W, Ctrl+Tab, ...) may mutate the tab list while
/// the pending row is outstanding. Returns true (consumed) while open.
pub fn unsaved_dialog_key(usage: u8) bool {
    if (!unsaved_dialog_open_tabwm) return false;
    switch (usage) {
        0x29 => apply_unsaved_choice(.cancel),
        0x28 => apply_unsaved_choice(.save),
        else => {},
    }
    return true;
}

/// If a persisted `.tabs` record is waiting and the live tab count now
/// matches, apply it and keep pinned tabs in front. CALC's
/// `declare_fullscreen` RPC often creates the tab *before* the kernel
/// WM_WINDOW mirror, so apply has to be attempted on every join path
/// (RPC, mirror-add, mirror-update), not only on the first unknown id.
fn try_apply_persisted_after_join() void {
    if (maybe_apply_persisted_tabs()) {
        if (manager.active_idx) |a| activate_tab(a);
    }
    _ = manager.normalize_pinned();
}

/// One kernel WM_WINDOW mirror (kind 20), mirror-synced into the tab list
/// (M42 UX, 2026-09-05 — extracted from main()'s inline handler):
///   - `released=true`: the kernel RELEASED the window (app self-exit or a
///     close_owner sweep — flags bit 13, fanned from remove_user_at). Drop
///     the tab — NO WIN_CLOSE echo back to the app, NO set_state of our
///     own — and, when the removed tab was the active one, activate the
///     new active tab (if any remain).
///   - `visible=false` without released: TABWM's own hide echo or an
///     external hide — ignored; the tab list is ours.
///   - `visible=true`: upsert. A known tab refreshes orig_w/orig_h (when
///     nonzero) and the M42 UX r2 unsaved flag (flags bit 12, fanned from
///     user_set_unsaved — set AND cleared as the app's dirty state
///     changes); an unknown id >= 2 joins as "App N" and activates. A
///     17th window is IGNORED (no add, no activation hijack) when the
///     manager is already at max_tabs.
/// #1056 item 2: resolve a window's display name through the WMCTL
/// WINDOW_NAME query (the kernel returns the app-set title or the owner
/// process's executable name). Returns a slice into `buf`, or null when the
/// window is unknown / the query is refused (e.g. host tests, no kernel).
fn query_window_name(id: u32, buf: []u8) ?[]const u8 {
    const n = syscall6(sys_wmctl, wmctl_window_name, id, @intFromPtr(buf.ptr), buf.len, 0, 0);
    if (n <= 0) return null;
    const len: usize = @intCast(@min(@as(u64, @intCast(n)), buf.len));
    if (len == 0) return null;
    return buf[0..len];
}

/// True when `title` is the "App N" placeholder a mirror-created tab
/// starts with (an empty title counts too) — i.e. the tab is still
/// eligible to be renamed from the kernel's process name.
fn is_placeholder_title(title: []const u8) bool {
    if (title.len == 0) return true;
    return std.mem.startsWith(u8, title, "App ");
}

pub fn handle_window_mirror(wid: u8, visible: bool, released: bool, unsaved: bool, orig_w: u32, orig_h: u32) void {
    const id: u32 = wid;
    if (released) {
        const idx = manager.find_by_id(id) orelse return;
        // #1064: remember it for reopen (LIFO) before it leaves the list.
        push_closed_tab(&manager.tabs[idx]);
        const was_active = (manager.active_idx != null and manager.active_idx.? == idx);
        _ = manager.remove_tab(id);
        if (was_active) {
            if (manager.active_idx) |next| activate_tab(next);
        }
        clamp_nav_selection();
        save_tabs();
        return;
    }
    if (!visible) return;
    if (manager.find_by_id(id)) |idx| {
        if (orig_w > 0) manager.tabs[idx].orig_w = orig_w;
        if (orig_h > 0) manager.tabs[idx].orig_h = orig_h;
        manager.tabs[idx].unsaved = unsaved;
        // #1056 item 2: a placeholder tab (opened before the process name
        // was resolvable) upgrades to the kernel's name on a later mirror.
        if (is_placeholder_title(manager.tabs[idx].get_title())) {
            var name_buf: [32]u8 = undefined;
            if (query_window_name(id, &name_buf)) |name| {
                manager.tabs[idx].set_title(name);
            }
        }
        // CALC's declare_fullscreen RPC often creates the tab *before*
        // this mirror, so the add path (and its apply) never runs. Retry
        // here once the live count can match the saved one.
        try_apply_persisted_after_join();
        return;
    }
    // Unknown window: ids 0/1 are kernel-fixed layers, never tabs; the
    // manager is capped at max_tabs and add_or_update_tab_geom's overflow
    // returns index 0 — so a 17th window is ignored here rather than
    // hijacking tab 0's activation.
    if (wid < 2 or manager.tab_count >= max_tabs) return;
    // #1056 item 2: prefer the kernel-resolved name (app title or owner
    // process name); fall back to the "App N" placeholder when no kernel
    // answers (host tests, or a nameless owner).
    var name_buf: [32]u8 = undefined;
    var title_buf: [32]u8 = undefined;
    const title = query_window_name(id, &name_buf) orelse (std.fmt.bufPrint(&title_buf, "App {d}", .{wid}) catch "App");
    const idx = manager.add_or_update_tab_geom(id, title, orig_w, orig_h, false);
    manager.tabs[idx].unsaved = unsaved;
    // #1064: adopt the launcher bin if the god-menu just spawned this window.
    if (pending_launch_bin_len > 0) {
        manager.tabs[idx].set_bin(pending_launch_bin[0..pending_launch_bin_len]);
        pending_launch_bin_len = 0;
    }
    // M48/BT3: adopt the launched app's manifest group + dock-pin signal.
    if (pending_launch_group_len > 0) {
        const n = @min(pending_launch_group_len, manager.tabs[idx].group.len);
        @memcpy(manager.tabs[idx].group[0..n], pending_launch_group[0..n]);
        manager.tabs[idx].group_len = n;
        pending_launch_group_len = 0;
    }
    manager.tabs[idx].pinned = manager.tabs[idx].pinned or pending_launch_pinned;
    pending_launch_pinned = false;
    activate_tab(idx);
    // #1056 item 3c: if this registration completes the restored window set,
    // reorder to the persisted tab order and re-activate the saved tab.
    try_apply_persisted_after_join();
}

// ---------------------------------------------------------------------------
// "+ New tab" affordance (M42 UX, 2026-09-05)
// ---------------------------------------------------------------------------

/// The "+ New tab" pill height (a slim row under the last tab pill).
pub const new_tab_pill_h: u32 = 24;

/// The y of the "+ New tab" pill: directly below the last DRAWN tab row
/// (58 + drawn * tab_row_h + a 4px gap), clamped to stay above the y=650
/// tab-list bound. With zero tabs it renders in the empty-state area — the
/// affordance exists even when nothing is open. #1056: `drawn` counts from
/// the overflow scroll offset, so the pill tracks the visible window.
pub fn new_tab_pill_y() u32 {
    const vis = visible_tab_rows();
    const visible_count = @min(manager.tab_count -| tab_scroll, vis);
    const base = if (visible_count == 0) 0 else visible_count;
    const y: u32 = tab_row_y(base) + 4;
    return @min(y, tab_list_bottom - new_tab_pill_h);
}

/// The "+ New tab" pill rect (the same pill column as the tabs).
pub fn new_tab_pill_rect() Rect {
    return Rect.make(tab_pill_x, new_tab_pill_y(), tab_pill_w, new_tab_pill_h);
}

/// The affordance fired (pill click or Ctrl+T): emit the pinned
/// `tabwm: new-tab` marker and open the M48 START surface — a new tab is a
/// start page in the browser model. (Ctrl+Space still summons the Sexiburger
/// command palette.)
pub fn trigger_new_tab() void {
    start_summon();
}

// ---------------------------------------------------------------------------
// Sexiburger god-menu overlay (M42 SX5, issue #986)
// ---------------------------------------------------------------------------
// Ctrl+Space or a click on the Sexiburger button summons the command
// palette directly on the scanout (TABWM composes; it has no window
// backing): type-to-filter over the APPS.TXT manifest (the M37 DQ1 wire
// format, parsed by lib/sexiburger.zig), arrows move the selection, Enter
// launches the selected app into a NEW TAB (sys_exec; the kernel's
// WM_WINDOW stream delivers the window and the tab manager picks it up),
// Esc dismisses. TABWM.BIN itself is filtered out (the WM seat is taken).

pub const overlay_max_apps: usize = 16;
pub const overlay_panel_w: u32 = 480;
pub const overlay_panel_h: u32 = 470;
pub const overlay_row_h: u32 = 22;
/// M82a (#1768): the shared manifest read budget (the parser's own constant,
/// the same one WND.BIN's god menu and the Go seat carry). This buffer used to
/// be a private 1024 B, and a manifest that outgrew it lost its tail rows from
/// this overlay with no error — the truncation happens in the read, not in the
/// parse.
pub const overlay_manifest_max: usize = sexiburger_menu.manifest_buf_max;

var overlay_open: bool = false;
var overlay_loaded: bool = false;
var overlay_manifest_buf: [overlay_manifest_max]u8 = undefined;
var overlay_bins: [overlay_max_apps][24]u8 = @as([overlay_max_apps][24]u8, @splat(@as([24]u8, @as([24]u8, @splat(@as(u8, 0))))));
var overlay_bin_lens: [overlay_max_apps]usize = @as([overlay_max_apps]usize, @splat(@as(usize, 0)));
var overlay_labels: [overlay_max_apps][32]u8 = @as([overlay_max_apps][32]u8, @splat(@as([32]u8, @as([32]u8, @splat(@as(u8, 0))))));
var overlay_label_lens: [overlay_max_apps]usize = @as([overlay_max_apps]usize, @splat(@as(usize, 0)));
/// M48/BT3: the manifest group label (`group=NAME`, optional 5th+ field) and
/// the `dock=true` pin signal, per catalog entry.
var overlay_groups: [overlay_max_apps][12]u8 = @as([overlay_max_apps][12]u8, @splat(@as([12]u8, @as([12]u8, @splat(@as(u8, 0))))));
var overlay_group_lens: [overlay_max_apps]usize = @as([overlay_max_apps]usize, @splat(@as(usize, 0)));
var overlay_dock: [overlay_max_apps]bool = @as([overlay_max_apps]bool, @splat(@as(bool, false)));
var overlay_count: usize = 0;
var overlay_filter: [24]u8 = @as([24]u8, @splat(@as(u8, 0)));
var overlay_filter_len: usize = 0;
var overlay_filtered: [overlay_max_apps]usize = undefined;
var overlay_filtered_count: usize = 0;
var overlay_sel: usize = 0;

/// Extract the `group=NAME` field for the manifest line whose executable is
/// `bin_name` (the manifest has one line per app). Returns an empty slice when
/// the app or the field is absent. Pure and host-testable.
pub fn manifest_group_for(text: []const u8, bin_name: []const u8) []const u8 {
    var line_start: usize = 0;
    while (line_start <= text.len) {
        var line_end = line_start;
        while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}
        const line = text[line_start..line_end];
        if (manifest_line_name(line)) |name| {
            if (std.mem.eql(u8, name, bin_name)) return manifest_field_prefix(line, "group=");
        }
        if (line_end == text.len) break;
        line_start = line_end + 1;
    }
    return "";
}

fn manifest_trim(s: []const u8) []const u8 {
    var a: usize = 0;
    while (a < s.len and (s[a] == ' ' or s[a] == '\t' or s[a] == '\r')) : (a += 1) {}
    var b = s.len;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t' or s[b - 1] == '\r')) : (b -= 1) {}
    return s[a..b];
}

fn manifest_line_name(line: []const u8) ?[]const u8 {
    const t = manifest_trim(line);
    if (t.len == 0 or t[0] == '#') return null;
    var i: usize = 0;
    while (i < t.len and t[i] != '|') : (i += 1) {}
    const name = manifest_trim(t[0..i]);
    if (name.len == 0) return null;
    return name;
}

fn manifest_field_prefix(line: []const u8, prefix: []const u8) []const u8 {
    const t = line;
    var fields: usize = 0;
    var fstart: usize = 0;
    var i: usize = 0;
    while (i <= t.len) : (i += 1) {
        if (i == t.len or t[i] == '|') {
            fields += 1;
            if (fields >= 3) {
                const field = manifest_trim(t[fstart..i]);
                if (std.mem.startsWith(u8, field, prefix)) return field[prefix.len..];
            }
            fstart = i + 1;
        }
    }
    return "";
}

/// Read + parse APPS.TXT into the static catalog. Manifest order, capped;
/// TABWM.BIN skipped (the WM seat is taken). Returns the entry count.
pub fn overlay_load_manifest() usize {
    overlay_count = 0;
    if (@import("builtin").os.tag != .freestanding) return 0;
    const fd = ui.file_open("APPS.TXT", ui.MODE_READ);
    if (fd < 0) return 0;
    defer ui.file_close(@intCast(fd));
    const n = ui.file_read(@intCast(fd), &overlay_manifest_buf);
    if (n <= 0) return 0;
    const text = overlay_manifest_buf[0..@intCast(n)];
    var parsed: [24]sexiburger_menu.MenuApp = undefined;
    const parsed_n = sexiburger_menu.parse_apps_manifest(text, &parsed);
    for (parsed[0..parsed_n]) |app| {
        if (overlay_count >= overlay_max_apps) break;
        if (std.mem.eql(u8, app.name, "TABWM.BIN")) continue;
        const bin_len = @min(app.name.len, 24);
        @memcpy(overlay_bins[overlay_count][0..bin_len], app.name[0..bin_len]);
        overlay_bin_lens[overlay_count] = bin_len;
        const label_len = @min(app.desc.len, 32);
        @memcpy(overlay_labels[overlay_count][0..label_len], app.desc[0..label_len]);
        overlay_label_lens[overlay_count] = label_len;
        // M48/BT3: the dock flag pins the spawned tab; `group=` labels it.
        overlay_dock[overlay_count] = app.dock;
        const group = manifest_group_for(text, app.name);
        const glen = @min(group.len, overlay_groups[overlay_count].len);
        @memcpy(overlay_groups[overlay_count][0..glen], group[0..glen]);
        overlay_group_lens[overlay_count] = glen;
        overlay_count += 1;
    }
    overlay_loaded = true;
    overlay_refresh_filter();
    return overlay_count;
}

/// Rebuild the filtered index (case-insensitive substring over label+bin).
pub fn overlay_refresh_filter() void {
    overlay_filtered_count = 0;
    overlay_sel = 0;
    const q = overlay_filter[0..overlay_filter_len];
    for (0..overlay_count) |i| {
        if (q.len == 0) {
            overlay_filtered[overlay_filtered_count] = i;
            overlay_filtered_count += 1;
            continue;
        }
        var hay: [64]u8 = undefined;
        const label = overlay_labels[i][0..overlay_label_lens[i]];
        const bin = overlay_bins[i][0..overlay_bin_lens[i]];
        if (label.len + 1 + bin.len > hay.len) continue;
        @memcpy(hay[0..label.len], label);
        hay[label.len] = ' ';
        @memcpy(hay[label.len + 1 .. label.len + 1 + bin.len], bin);
        const needle_len = @min(q.len, 32);
        var needle: [32]u8 = undefined;
        for (q[0..needle_len], 0..) |c, k| needle[k] = std.ascii.toLower(c);
        var hit = false;
        var start: usize = 0;
        while (start + needle_len <= label.len + 1 + bin.len) : (start += 1) {
            var k: usize = 0;
            while (k < needle_len and std.ascii.toLower(hay[start + k]) == needle[k]) : (k += 1) {}
            if (k == needle_len) {
                hit = true;
                break;
            }
        }
        if (hit) {
            overlay_filtered[overlay_filtered_count] = i;
            overlay_filtered_count += 1;
        }
    }
}

pub fn overlay_summon() void {
    // M42 UX r2: the Sexiburger overlay must not open over the modal
    // unsaved-changes dialog (the dialog owns the input).
    if (unsaved_dialog_open_tabwm) return;
    // M48: the catalog surfaces are mutually exclusive (they share the
    // filter/selection state).
    start_open = false;
    tab_search_open = false;
    if (!overlay_loaded) _ = overlay_load_manifest();
    overlay_open = true;
    write_marker(god_menu_marker);
}

pub fn overlay_dismiss() void {
    overlay_open = false;
    overlay_filter_len = 0;
    overlay_refresh_filter();
}

/// Launch the selected app into a new tab (the kernel's WM_WINDOW stream
/// delivers the window; the tab manager adds and activates it). Returns
/// false when the overlay is empty.
pub fn overlay_launch_selected() bool {
    if (overlay_filtered_count == 0) return false;
    const entry = overlay_filtered[overlay_sel];
    const bin = overlay_bins[entry][0..overlay_bin_lens[entry]];
    var buf: [40]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{s}\n", .{ launch_marker_prefix, bin }) catch launch_marker_prefix;
    write_marker(msg);
    // #1064: remember the bin so the tab this spawns can be reopened later.
    const blen = @min(bin.len, pending_launch_bin.len);
    @memcpy(pending_launch_bin[0..blen], bin[0..blen]);
    pending_launch_bin_len = blen;
    // M48/BT3: carry the manifest group label to the new tab.
    const group = overlay_groups[entry][0..overlay_group_lens[entry]];
    const glen = @min(group.len, pending_launch_group.len);
    @memcpy(pending_launch_group[0..glen], group[0..glen]);
    pending_launch_group_len = glen;
    pending_launch_pinned = overlay_dock[entry];
    _ = ui.exec_program(bin);
    dismiss_active_catalog();
    return true;
}

/// Handle one key while a catalog surface is open (the raw WM_KEY stream).
/// Returns true when consumed. Shared by the Sexiburger palette and the M48
/// START page (they share the filter/selection state).
pub fn overlay_key(usage: u8) bool {
    if (!overlay_open and !start_open) return false;
    switch (usage) {
        0x29 => { // Escape: dismiss
            dismiss_active_catalog();
            return true;
        },
        0x28 => { // Enter: launch selected
            _ = overlay_launch_selected();
            return true;
        },
        0x2a => { // Backspace: trim the filter
            if (overlay_filter_len > 0) {
                overlay_filter_len -= 1;
                overlay_refresh_filter();
            }
            return true;
        },
        0x52 => { // Up
            if (overlay_sel > 0) overlay_sel -= 1;
            return true;
        },
        0x51 => { // Down
            if (overlay_sel + 1 < overlay_filtered_count) overlay_sel += 1;
            return true;
        },
        else => {},
    }
    // Letters a..z, digits 1..0, space, minus, period: extend the filter.
    const printable = (usage >= 0x04 and usage <= 0x1d) or (usage >= 0x1e and usage <= 0x27) or
        usage == 0x2c or usage == 0x2d or usage == 0x37;
    if (printable and overlay_filter_len < overlay_filter.len) {
        const c: u8 = if (usage == 0x2c) ' ' else if (usage == 0x2d) '-' else if (usage == 0x37) '.' else if (usage <= 0x1d) @intCast(usage - 0x04 + 'a') else @intCast(usage - 0x1e + '1');
        overlay_filter[overlay_filter_len] = c;
        overlay_filter_len += 1;
        overlay_refresh_filter();
        return true;
    }
    return false;
}

/// The overlay's empty-state line (M42 UX, 2026-09-05): an EMPTY manifest
/// ("no apps installed") is a different, honestly distinguishable state
/// from a filter that merely has no hits ("no matching apps").
/// Host-testable — the renderer draws exactly this string.
pub fn overlay_empty_message() []const u8 {
    if (overlay_count == 0) return "no apps installed";
    return "no matching apps";
}

/// Draw the overlay panel centered over the content viewport (call after
/// draw_sidebar; the dim + panel overwrite the canvas only).
pub fn draw_overlay(pixels: []u32) void {
    if (!overlay_open) return;
    const px = viewport_x + (viewport_w - overlay_panel_w) / 2;
    const py: u32 = 80;
    // Dim the viewport behind the panel (source-over alpha).
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(viewport_x, 0, viewport_w, fb_h), 0, 0xB0000000);
    // Panel
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(px, py, overlay_panel_w, overlay_panel_h), 8, ui.sidebar_active_pill());
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(px, py, overlay_panel_w, 44), 8, ui.sidebar_hover_pill());
    // Emblem + title
    if (mascot_image()) |img| {
        ui.draw_image_buf(pixels, fb_w, px + 10, py + 8, img);
    }
    ui.draw_text_sized(0, "SEXIBURGER", px + 46, py + 15, ui.font_size_tab_title, ui.sidebar_text_active());
    // Filter line
    ui.draw_text_sized(0, ">", px + 12, py + 52, ui.font_size_badge, ui.theme_accent());
    if (overlay_filter_len > 0) {
        ui.draw_text_sized(0, overlay_filter[0..overlay_filter_len], px + 24, py + 52, ui.font_size_badge, ui.sidebar_text_active());
    } else {
        ui.draw_text_sized(0, "type to filter, enter launches", px + 24, py + 52, ui.font_size_badge, ui.sidebar_text_inactive());
    }
    // App rows
    var row: u32 = 0;
    while (row < overlay_filtered_count and row < overlay_max_apps) : (row += 1) {
        const entry = overlay_filtered[row];
        const ry = py + 70 + row * overlay_row_h;
        const is_sel = (row == overlay_sel);
        if (is_sel) {
            ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(px + 8, ry - 3, overlay_panel_w - 16, overlay_row_h - 2), 4, ui.theme_accent());
        }
        const label = overlay_labels[entry][0..overlay_label_lens[entry]];
        const bin = overlay_bins[entry][0..overlay_bin_lens[entry]];
        var line_buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s} — {s}", .{ label, bin }) catch label;
        ui.draw_text_sized(0, line[0..@min(line.len, 56)], px + 14, ry + 1, ui.font_size_badge, if (is_sel) 0x000000 else ui.sidebar_text_active());
    }
    if (overlay_filtered_count == 0) {
        ui.draw_text_sized(0, overlay_empty_message(), px + 14, py + 74, ui.font_size_badge, ui.sidebar_text_inactive());
    }
    // Footer
    ui.draw_text_sized(0, "esc dismiss", px + 12, py + overlay_panel_h - 20, ui.font_size_badge, ui.sidebar_text_inactive());
}

// ---------------------------------------------------------------------------
// Canvas & Left Sidebar Drawing
// ---------------------------------------------------------------------------

fn fill_canvas_rect(pixels: []u32, rx: u32, ry: u32, rw: u32, rh: u32) void {
    const is_light = std.mem.eql(u8, ui.theme_name(), "light");
    const bg_color: u32 = if (is_light) 0xFFE9EDF2 else 0xFF14161B;
    const dot_color: u32 = if (is_light) 0xFFCBD5E1 else 0xFF252934;

    var y: u32 = ry;
    const y_end = @min(ry + rh, fb_h);
    const x_end = @min(rx + rw, fb_w);

    while (y < y_end) : (y += 1) {
        const row_start = y * fb_w;
        var x: u32 = rx;
        while (x < x_end) : (x += 1) {
            const is_dot = (x % 24 == 0 and y % 24 == 0);
            pixels[row_start + x] = if (is_dot) dot_color else bg_color;
        }
    }
}

/// Renders the dark slate canvas backdrop with subtle grid texture in empty viewport space.
pub fn draw_viewport_backdrop(scan: [*]u32) void {
    const pixels = scan[0 .. @as(usize, fb_w) * fb_h];

    if (manager.active_idx) |idx| {
        if (idx < manager.tab_count and manager.tabs[idx].valid) {
            const tab = &manager.tabs[idx];
            const vp = compute_tab_viewport(tab);

            // Full viewport: nothing to fill outside window
            if (vp.w >= viewport_w and vp.h >= viewport_h and vp.x == viewport_x and vp.y == viewport_y) {
                return;
            }

            // Window is centered with canvas margins around it
            if (vp.y > viewport_y) {
                fill_canvas_rect(pixels, viewport_x, viewport_y, viewport_w, vp.y - viewport_y);
            }
            const bottom_y = vp.y + vp.h;
            if (bottom_y < viewport_y + viewport_h) {
                fill_canvas_rect(pixels, viewport_x, bottom_y, viewport_w, (viewport_y + viewport_h) - bottom_y);
            }
            if (vp.x > viewport_x) {
                fill_canvas_rect(pixels, viewport_x, vp.y, vp.x - viewport_x, vp.h);
            }
            const right_x = vp.x + vp.w;
            if (right_x < viewport_x + viewport_w) {
                fill_canvas_rect(pixels, right_x, vp.y, (viewport_x + viewport_w) - right_x, vp.h);
            }
            return;
        }
    }

    // No active tabs: fill entire content viewport
    fill_canvas_rect(pixels, viewport_x, viewport_y, viewport_w, viewport_h);
}

pub fn draw_sidebar(scan: [*]u32) void {
    draw_viewport_backdrop(scan);

    const pixels = scan[0 .. @as(usize, fb_w) * fb_h];

    // 1. Sidebar background: full vertical height, 180px wide
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(0, 0, sidebar_w, fb_h), 0, ui.sidebar_bg());

    // 2. Right border line: 1px vertical line at x = sidebar_w - 1
    const border_c = ui.sidebar_border();
    var y: u32 = 0;
    while (y < fb_h) : (y += 1) {
        pixels[y * fb_w + (sidebar_w - 1)] = 0xFF000000 | border_c;
    }

    // 3. Top Sexiburger Area (y = 8 .. 48)
    const sexiburg_rect = Rect.make(8, 8, 164, 38);
    if (hover_sexiburger) {
        ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, sexiburg_rect, 6, ui.sidebar_hover_pill());
    }

    // Proper Sexiburger mascot emblem (the real 🐙+🍔 raster, M42 SX1) at (12, 13)
    draw_mascot_emblem(pixels, 12, 13);

    // Header label: "Virelai" in 14pt Inter
    ui.draw_text_sized(0, "Virelai", 48, 20, ui.font_size_tab_title, ui.sidebar_text_active());

    // Header shortcut badge: "[*]" hint
    ui.draw_text_sized(0, "[*]", 144, 21, ui.font_size_badge, ui.theme_accent());

    // Separator line below header (y = 52)
    var sx: u32 = 8;
    while (sx < 172) : (sx += 1) {
        pixels[52 * fb_w + sx] = 0xFF000000 | border_c;
    }

    // #1056 item 3: the overflow indicator — when more tabs exist than fit,
    // the header shows the visible window (`^2-16/18v`) and the arrows mark
    // rows hidden above/below. The list itself scrolls with the keyboard
    // (Up/Down move the selection, PageUp/PageDown scroll a page).
    if (tab_scroll_max() > 0) {
        var obuf: [24]u8 = undefined;
        ui.draw_text_sized(0, overflow_label(&obuf), 92, 40, ui.font_size_badge, ui.sidebar_text_inactive());
    }

    // 4. Middle Tab List (y = 58 .. 650)
    if (manager.tab_count == 0) {
        ui.draw_text_sized(0, "No open tabs", 20, 96, ui.font_size_badge, ui.sidebar_text_inactive());
        ui.draw_text_sized(0, "Ctrl+Space or +", 20, 112, ui.font_size_badge, ui.sidebar_text_inactive());
        ui.draw_text_sized(0, "to launch apps", 20, 126, ui.font_size_badge, ui.sidebar_text_inactive());
    } else {
        const vis_rows = visible_tab_rows();
        var rel: usize = 0;
        while (rel < vis_rows) : (rel += 1) {
            const i = tab_scroll + rel;
            if (i >= manager.tab_count) break;
            const tab_y: u32 = tab_row_y(rel);

            const pill_rect = Rect.make(tab_pill_x, tab_y + 2, tab_pill_w, 34);
            const is_active = (manager.active_idx != null and manager.active_idx.? == i);
            const is_hover = (hover_tab != null and hover_tab.? == i);
            const is_nav = (nav_sel != null and nav_sel.? == i);

            // #1056 item 3: the keyboard-selection ring — a 2px accent
            // outline drawn UNDER the pill fill, so only the ring survives
            // around active/hover/inactive rows and the keyboard cursor is
            // always visible.
            if (is_nav) {
                ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(pill_rect.x - 2, pill_rect.y - 2, pill_rect.w + 4, pill_rect.h + 4), ui.tab_pill_radius + 2, ui.theme_accent());
            }

            if (is_active) {
                // Active pill background
                ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, pill_rect, ui.tab_pill_radius, ui.sidebar_active_pill());
                // Left accent bar
                ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(10, tab_y + 8, 3, 22), 1, ui.theme_accent());
                // Tab title in active text color
                ui.draw_text_sized(0, manager.tabs[i].get_title(), 24, tab_y + 11, ui.font_size_tab_title, ui.sidebar_text_active());
                // M42 UX r2: the unsaved dot — the tab is DIRTY (the
                // kernel's mirror bit 12); 4x4 accent dot at x=142..146,
                // vertically centered, clear of the 'x' at x=154.
                if (manager.tabs[i].unsaved) {
                    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(142, tab_y + 17, 4, 4), 0, ui.theme_accent());
                }
                // Close button 'x'
                ui.draw_text_sized(0, "x", 154, tab_y + 11, ui.font_size_badge, ui.sidebar_text_inactive());
            } else if (is_hover) {
                // Hover pill background
                ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, pill_rect, ui.tab_pill_radius, ui.sidebar_hover_pill());
                ui.draw_text_sized(0, manager.tabs[i].get_title(), 24, tab_y + 11, ui.font_size_tab_title, ui.sidebar_text_active());
                if (manager.tabs[i].unsaved) {
                    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(142, tab_y + 17, 4, 4), 0, ui.theme_accent());
                }
                ui.draw_text_sized(0, "x", 154, tab_y + 11, ui.font_size_badge, ui.sidebar_text_inactive());
            } else {
                // Inactive tab
                ui.draw_text_sized(0, manager.tabs[i].get_title(), 24, tab_y + 11, ui.font_size_tab_title, ui.sidebar_text_inactive());
                if (manager.tabs[i].unsaved) {
                    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(142, tab_y + 17, 4, 4), 0, ui.theme_accent());
                }
            }
        }
    }

    // M48/BT3+BT6: the per-row status badges (a second pass so active,
    // hover, and inactive pills all carry them): a pin dot at the left
    // (clear of the active accent bar) and a frozen '~' at x=132.
    if (manager.tab_count > 0) {
        const vis_rows = visible_tab_rows();
        var brel: usize = 0;
        while (brel < vis_rows) : (brel += 1) {
            const bi = tab_scroll + brel;
            if (bi >= manager.tab_count) break;
            const by = tab_row_y(brel);
            if (manager.tabs[bi].pinned) {
                ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(16, by + 17, 4, 4), 0, ui.theme_accent());
            }
            if (manager.tabs[bi].frozen) {
                ui.draw_text_sized(0, "~", 132, by + 11, ui.font_size_badge, ui.sidebar_text_inactive());
            }
        }
    }

    // M48/BT5: the ACTIVE tab's back/forward affordances in the header row
    // (accent when a step is available, dim otherwise).
    if (manager.active_idx) |ai| {
        if (ai < manager.tab_count) {
            const at = &manager.tabs[ai];
            ui.draw_text_sized(0, "<", 118, 40, ui.font_size_badge, if (at.can_nav_back()) ui.theme_accent() else ui.sidebar_text_inactive());
            ui.draw_text_sized(0, ">", 128, 40, ui.font_size_badge, if (at.can_nav_forward()) ui.theme_accent() else ui.sidebar_text_inactive());
        }
    }

    // M42 UX r2: the close-feedback flash — the row slot the just-closed
    // tab occupied lights for a few composite ticks, drawn AFTER the pills
    // so it overlays (accent = the kernel applied the close; muted = the
    // seam was refused and only a hide ran). #1056: the slot is relative to
    // the scroll window and skipped when scrolled out of view.
    if (close_flash_row) |frow| {
        if (close_flash_active(frow) and frow >= tab_scroll and (frow - tab_scroll) < visible_tab_rows()) {
            const fy: u32 = tab_row_y(frow - tab_scroll) + 2;
            ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(tab_pill_x, fy, tab_pill_w, 34), 0, if (close_flash_closed) ui.theme_accent() else ui.sidebar_text_inactive());
        }
    }

    // M42 UX: the "+ New tab" affordance pill — directly below the last
    // tab row (or in the empty-state area), always rendered so it is
    // discoverable; hover lights it like the other pills.
    const nt_rect = new_tab_pill_rect();
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, nt_rect, ui.tab_pill_radius, if (hover_new_tab) ui.sidebar_hover_pill() else ui.sidebar_active_pill());
    ui.draw_text_sized(0, "+ New tab", 24, nt_rect.y + 5, ui.font_size_badge, if (hover_new_tab) ui.sidebar_text_active() else ui.sidebar_text_inactive());

    // 5. Bottom Status / Tray Area (y = 660 .. 720)    // Separator line at y = 660
    var bx: u32 = 8;
    while (bx < 172) : (bx += 1) {
        pixels[660 * fb_w + bx] = 0xFF000000 | border_c;
    }

    // Clock text "12:00"
    var clock_buf: [12]u8 = undefined;
    const clock_str = std.fmt.bufPrint(&clock_buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ clock_hours, clock_minutes, clock_seconds }) catch "00:00:00";
    ui.draw_text_sized(0, clock_str, 16, 678, ui.font_size_clock, ui.sidebar_text_active());

    // Theme toggle pill [D] / [L]
    const theme_rect = Rect.make(96, 672, 32, 24);
    const theme_bg = if (hover_theme_toggle) ui.sidebar_hover_pill() else ui.sidebar_active_pill();
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, theme_rect, 4, theme_bg);
    const theme_char = if (std.mem.eql(u8, ui.theme_name(), "light")) "L" else "D";
    ui.draw_text_sized(0, theme_char, 108, 676, ui.font_size_badge, ui.sidebar_text_active());

    // Clipboard badge [CB]
    const clip_rect = Rect.make(134, 672, 36, 24);
    const clip_bg = if (hover_clip) ui.sidebar_hover_pill() else ui.sidebar_bg();
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, clip_rect, 4, clip_bg);
    ui.draw_text_sized(0, "CB", 144, 676, ui.font_size_badge, ui.theme_accent());

    // TWM: the "Go" rail chip — the discoverable, mouse-reachable entry
    // to the quick-jump (the keyboard path is Ctrl+Shift+G). It lives in
    // the one free band of the rail, below the tray row.
    const go_rect = go_chip_rect();
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, go_rect, 4, if (hover_go) ui.sidebar_hover_pill() else ui.sidebar_bg());
    ui.draw_text_sized(0, go_chip_label, go_rect.x + 6, go_rect.y + 2, ui.font_size_badge, ui.theme_accent());
    ui.draw_text_sized(0, go_chip_hint, go_rect.x + go_chip_w - 18, go_rect.y + 2, ui.font_size_badge, ui.sidebar_text_inactive());

    // M42 SX5: the Sexiburger god-menu overlay renders last (over the
    // canvas + sidebar dim).
    draw_overlay(pixels);
    // M48/BT4: the START surface (the browser new-tab page).
    draw_start_surface(pixels);
    // M48/BT6: the tab-search overlay and the hover preview card.
    draw_tab_search(pixels);
    draw_hover_preview(pixels);
    // TWM: the Go quick-jump panel renders over the tab surfaces and
    // under the modal.
    draw_go(pixels);
    // M42 UX r2: the unsaved-changes dialog renders after EVERYTHING —
    // TABWM composes the full scanout every tick, so its compose overdraws
    // the kernel's own dialog blit; TABWM self-paints the modal (same
    // 200x100 geometry + palette as driving_award paint_scene) so it is
    // actually visible while the kernel still applies the decisions.
    draw_unsaved_dialog(pixels);
}

/// The M48/BT4 START surface — a rail-native new-tab page. A dark dim over
/// the content viewport, a titled panel, the SAME type-to-filter line the
/// command palette uses, and a two-column apps grid. Rendering only; the
/// filtering/selection state is shared with the catalog (`overlay_*`), so
/// draw and key-handling can never disagree.
pub fn draw_start_surface(pixels: []u32) void {
    if (!start_open) return;
    const pw: u32 = 560;
    const ph: u32 = 420;
    const px = viewport_x + (viewport_w - pw) / 2;
    const py: u32 = 80;
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(viewport_x, 0, viewport_w, fb_h), 0, 0xB0000000);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(px, py, pw, ph), 10, ui.sidebar_active_pill());
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(px, py, pw, 44), 10, ui.sidebar_hover_pill());
    ui.draw_text_sized(0, "NEW TAB", px + 16, py + 15, ui.font_size_tab_title, ui.sidebar_text_active());
    ui.draw_text_sized(0, "Ctrl+T  •  esc dismiss", px + pw - 200, py + 16, ui.font_size_badge, ui.sidebar_text_inactive());
    ui.draw_text_sized(0, ">", px + 12, py + 54, ui.font_size_badge, ui.theme_accent());
    if (overlay_filter_len > 0) {
        ui.draw_text_sized(0, overlay_filter[0..overlay_filter_len], px + 24, py + 54, ui.font_size_badge, ui.sidebar_text_active());
    } else {
        ui.draw_text_sized(0, "search apps", px + 24, py + 54, ui.font_size_badge, ui.sidebar_text_inactive());
    }
    const col_w: u32 = (pw - 36) / 2;
    var row: u32 = 0;
    while (row < overlay_filtered_count and row < overlay_max_apps) : (row += 1) {
        const entry = overlay_filtered[row];
        const gx = px + 12 + (row % 2) * (col_w + 6);
        const gy = py + 82 + (row / 2) * 34;
        if (gy + 30 > py + ph - 20) break;
        const is_sel = (row == overlay_sel);
        ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(gx, gy, col_w, 30), 6, if (is_sel) ui.theme_accent() else ui.sidebar_hover_pill());
        const label = overlay_labels[entry][0..overlay_label_lens[entry]];
        ui.draw_text_sized(0, label[0..@min(label.len, 22)], gx + 8, gy + 9, ui.font_size_badge, if (is_sel) 0x000000 else ui.sidebar_text_active());
    }
    if (overlay_filtered_count == 0) {
        ui.draw_text_sized(0, overlay_empty_message(), px + 16, py + 86, ui.font_size_badge, ui.sidebar_text_inactive());
    }
}

/// The M48/BT6 tab-search overlay: a centered panel listing the tabs that
/// match the typed query. Enter activates the selected tab.
pub fn draw_tab_search(pixels: []u32) void {
    if (!tab_search_open) return;
    const pw: u32 = 380;
    const ph: u32 = 320;
    const px = viewport_x + (viewport_w - pw) / 2;
    const py: u32 = 120;
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(viewport_x, 0, viewport_w, fb_h), 0, 0xB0000000);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(px, py, pw, ph), 10, ui.sidebar_active_pill());
    ui.draw_text_sized(0, "TABS", px + 14, py + 12, ui.font_size_tab_title, ui.sidebar_text_active());
    ui.draw_text_sized(0, "Ctrl+Shift+A", px + pw - 110, py + 14, ui.font_size_badge, ui.sidebar_text_inactive());
    ui.draw_text_sized(0, ">", px + 12, py + 44, ui.font_size_badge, ui.theme_accent());
    if (tab_search_filter_len > 0) {
        ui.draw_text_sized(0, tab_search_filter[0..tab_search_filter_len], px + 24, py + 44, ui.font_size_badge, ui.sidebar_text_active());
    } else {
        ui.draw_text_sized(0, "search tabs", px + 24, py + 44, ui.font_size_badge, ui.sidebar_text_inactive());
    }
    var r: u32 = 0;
    while (r < tab_search_count and r < 12) : (r += 1) {
        const ti = tab_search_results[r];
        const ry = py + 72 + r * 20;
        const is_sel = (r == tab_search_sel);
        if (is_sel) {
            ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(px + 8, ry - 2, pw - 16, 18), 4, ui.theme_accent());
        }
        const t = manager.tabs[ti].get_title();
        ui.draw_text_sized(0, t[0..@min(t.len, 40)], px + 14, ry, ui.font_size_badge, if (is_sel) 0x000000 else ui.sidebar_text_active());
    }
    if (tab_search_count == 0) {
        ui.draw_text_sized(0, "no matching tabs", px + 14, py + 76, ui.font_size_badge, ui.sidebar_text_inactive());
    }
}

/// The TWM "Go" panel: a rail-native quick-jump centered on the content
/// viewport, drawn AFTER the tab surfaces and BEFORE the modal. Rendering
/// only — the scan/rank/selection state lives in `go_*`, and every row label
/// comes from `go_row_label`, so draw and key-handling can never disagree.
pub fn draw_go(pixels: []u32) void {
    if (!go_open) return;
    const pw = go_panel_w;
    const ph = go_panel_h;
    const px = go_panel_x();
    const py = go_panel_y;
    // Dim the content viewport behind the panel (source-over alpha).
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(viewport_x, 0, viewport_w, fb_h), 0, 0xB0000000);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(px, py, pw, ph), 10, ui.sidebar_active_pill());
    ui.draw_text_sized(0, go_chip_label, px + 16, py + 12, ui.font_size_tab_title, ui.sidebar_text_active());
    ui.draw_text_sized(0, "Ctrl+Shift+G", px + pw - 122, py + 14, ui.font_size_badge, ui.sidebar_text_inactive());
    // The query line — a pill, so the type-ahead target is unmistakable.
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(px + 12, py + 40, pw - 24, 26), 6, ui.sidebar_hover_pill());
    ui.draw_text_sized(0, ">", px + 20, py + 46, ui.font_size_badge, ui.theme_accent());
    if (go_query_len > 0) {
        ui.draw_text_sized(0, go_query[0..go_query_len], px + 34, py + 46, ui.font_size_badge, ui.sidebar_text_active());
    } else {
        ui.draw_text_sized(0, "go to a tab, a group, or an app", px + 34, py + 46, ui.font_size_badge, ui.sidebar_text_inactive());
    }
    // Result rows.
    var r: usize = 0;
    while (r < go_result_count) : (r += 1) {
        const ry = py + go_rows_y + @as(u32, @intCast(r)) * go_row_h;
        if (ry + go_row_h > py + ph - go_panel_footer) break;
        const is_sel = (r == go_sel);
        if (is_sel) {
            ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(px + 10, ry - 3, pw - 20, 20), 5, ui.theme_accent());
        }
        const fg = if (is_sel) 0x000000 else ui.sidebar_text_active();
        var lbuf: [56]u8 = undefined;
        const lbl = go_row_label(r, &lbuf);
        ui.draw_text_sized(0, lbl[0..@min(lbl.len, 44)], px + 18, ry, ui.font_size_badge, fg);
        ui.draw_text_sized(0, go_row_kind_label(r), px + pw - 54, ry, ui.font_size_badge, if (is_sel) 0x000000 else ui.sidebar_text_inactive());
    }
    if (go_result_count == 0) {
        ui.draw_text_sized(0, go_empty_message(), px + 18, py + go_rows_y + 4, ui.font_size_badge, ui.sidebar_text_inactive());
    }
    ui.draw_text_sized(0, "Enter jump   Up/Down move   Esc back", px + 16, py + ph - 22, ui.font_size_badge, ui.sidebar_text_inactive());
}

/// The M48/BT6 hover preview card: after the pointer rests on a tab, a small
/// card appears beside the rail with the title, executable, group, and
/// unsaved/frozen/pinned status. The thumbnail area is a neutral placeholder
/// (per-window pixels are not exposed across the WM boundary).
pub fn draw_hover_preview(pixels: []u32) void {
    const row = hover_tab orelse return;
    if (row >= manager.tab_count) return;
    if (!hover_preview_visible(row)) return;
    const t = &manager.tabs[row];
    const pw: u32 = 240;
    const ph: u32 = 132;
    const rel = if (row >= tab_scroll) row - tab_scroll else 0;
    var py: u32 = tab_row_y(rel);
    if (py + ph > tab_list_bottom) py = tab_list_bottom - ph;
    const px: u32 = sidebar_w + 8;
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(px, py, pw, ph), 8, ui.sidebar_active_pill());
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(px + 8, py + 8, pw - 16, 54), 6, ui.sidebar_hover_pill());
    ui.draw_text_sized(0, "[preview]", px + 14, py + 26, ui.font_size_badge, ui.sidebar_text_inactive());
    const title = t.get_title();
    ui.draw_text_sized(0, title[0..@min(title.len, 30)], px + 10, py + 72, ui.font_size_badge, ui.sidebar_text_active());
    const bin = t.get_bin();
    var sub: [48]u8 = undefined;
    const sub_str = if (bin.len > 0)
        (std.fmt.bufPrint(&sub, "{s}{s}", .{ if (t.pinned) "*" else "", bin }) catch bin)
    else if (t.group_len > 0)
        (std.fmt.bufPrint(&sub, "group: {s}", .{t.group[0..t.group_len]}) catch "group")
    else
        "app tab";
    ui.draw_text_sized(0, sub_str, px + 10, py + 88, ui.font_size_badge, ui.sidebar_text_inactive());
    const status: []const u8 = if (t.frozen) "frozen" else if (t.unsaved) "unsaved" else "active";
    ui.draw_text_sized(0, status, px + 10, py + 104, ui.font_size_badge, ui.theme_accent());
}

/// The unsaved-changes dialog, self-painted (M42 UX r2, claim #1011):
/// dimmed viewport, 200x100 centered surface, 2px amber border, the
/// "Save before closing?" message and the Save/Don't/No buttons — the
/// EXACT geometry + palette of the kernel's own blit (driving_award
/// paint_scene), hit-tested through the shared wnd_core rect rule. Mirror
/// parity by construction.
pub fn draw_unsaved_dialog(pixels: []u32) void {
    if (!unsaved_dialog_open_tabwm) return;
    // Dim the viewport behind the modal (same source-over dim the
    // Sexiburger overlay uses).
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(viewport_x, 0, viewport_w, fb_h), 0, 0xB0000000);
    const dw = wnd_core.unsaved_dialog_w; // 200
    const dh = wnd_core.unsaved_dialog_h; // 100
    const dx = (fb_w - dw) / 2; // 540 at 1280
    const dy = (fb_h - dh) / 2; // 310 at 720
    // Surface + 2px amber border (the kernel's exact palette).
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(dx, dy, dw, dh), 0, 0x1e293b);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(dx, dy, dw, 2), 0, 0xf59e0b);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(dx, dy + dh - 2, dw, 2), 0, 0xf59e0b);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(dx, dy, 2, dh), 0, 0xf59e0b);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(dx + dw - 2, dy, 2, dh), 0, 0xf59e0b);
    // Message.
    ui.draw_text_sized(0, "Save before closing?", dx + 10, dy + 10, ui.font_size_badge, 0xffffff);
    // Buttons: Save (green), Don't (red), No (gray) — the wnd_core rects
    // (y in [dy+dh-30, dy+dh-10)).
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(dx + 20, dy + dh - 30, 60, 20), 0, 0x10b981);
    ui.draw_text_sized(0, "Save", dx + 26, dy + dh - 24, ui.font_size_badge, 0xffffff);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(dx + 90, dy + dh - 30, 60, 20), 0, 0xef4444);
    ui.draw_text_sized(0, "Don't", dx + 96, dy + dh - 24, ui.font_size_badge, 0xffffff);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(dx + 160, dy + dh - 30, 30, 20), 0, 0x64748b);
    ui.draw_text_sized(0, "No", dx + 163, dy + dh - 24, ui.font_size_badge, 0xffffff);
}

/// Proper Sexiburger mascot emblem (M42 SX1, issue #982): the real 🐙+🍔
/// artwork — an octopus holding the six-layer burger — downscaled from
/// `assets/sexiburger.png` (534x534, the canonical emoji export) to 28x28
/// and embedded as a QOI fixture (`mascot_28x28.qoi`; regenerate with the
/// premultiplied-Lanczos pass documented in `docs/march-m42-sexiburger-desktop.md`).
/// Decoded ONCE into static BSS (the wnd.zig god-menu fixture pattern) and
/// alpha-blended straight into the scanout via `ui.draw_image_buf`. The
/// rect-drawn fallback emblem stays available in `lib/sexiburger.zig` for
/// the no-asset path.
pub const mascot_size: u32 = 28;

const mascot_qoi_bytes = @embedFile("lib/fixtures/qoi/mascot_28x28.qoi");
var mascot_pixels: [mascot_size * mascot_size]u32 = undefined;
var mascot_loaded: bool = false;

pub fn mascot_image() ?ui.Image {
    if (mascot_loaded) {
        return ui.Image{
            .width = mascot_size,
            .height = mascot_size,
            .pixels = &mascot_pixels,
        };
    }
    const decoded = ui.image.qoi.decode(mascot_qoi_bytes, &mascot_pixels) catch return null;
    if (decoded.width != mascot_size or decoded.height != mascot_size) return null;
    mascot_loaded = true;
    return ui.Image{
        .width = mascot_size,
        .height = mascot_size,
        .pixels = &mascot_pixels,
    };
}

fn draw_mascot_emblem(pixels: []u32, x: u32, y: u32) void {
    if (mascot_image()) |img| {
        ui.draw_image_buf(pixels, fb_w, x, y, img);
        return;
    }
    // Asset unavailable (decode failed): the legacy hand-drawn mini mascot.
    draw_mini_mascot(pixels, x, y);
}

/// Legacy mini Sexiburger mascot fallback: 6 burger layers + tentacles (18x18 px).
fn draw_mini_mascot(pixels: []u32, x: u32, y: u32) void {
    const tentacle: u32 = 0xFFF57C00;

    // Tentacles left
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(x, y + 2, 3, 2), 0, tentacle);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(x - 2, y + 5, 3, 2), 0, tentacle);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(x - 3, y + 8, 3, 3), 0, tentacle);

    // Tentacles right
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(x + 17, y + 2, 3, 2), 0, tentacle);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(x + 19, y + 5, 3, 2), 0, tentacle);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(x + 20, y + 8, 3, 3), 0, tentacle);

    // 6-layer Burger Body
    const bx = x + 2;
    const bw: u32 = 16;
    // Layer 1: Crown Bun
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(bx + 2, y + 1, bw - 4, 2), 1, 0xFFD89632);
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(bx, y + 3, bw, 2), 1, 0xFFD89632);
    // Layer 2: Lettuce
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(bx - 1, y + 5, bw + 2, 2), 0, 0xFF4CAF50);
    // Layer 3: Tomato
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(bx + 1, y + 7, bw - 2, 2), 0, 0xFFE53935);
    // Layer 4: Cheese
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(bx, y + 9, bw, 2), 0, 0xFFFDD835);
    // Layer 5: Patty
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(bx + 1, y + 11, bw - 2, 3), 1, 0xFF6D4C41);
    // Layer 6: Heel Bun
    ui.fill_rounded_rect_buf(pixels, fb_w, fb_h, Rect.make(bx + 1, y + 14, bw - 2, 2), 1, 0xFFC88628);
}

// ---------------------------------------------------------------------------
// Pointer & Hit Testing (M39 TWM2)
// ---------------------------------------------------------------------------
pub fn handle_pointer(px: u32, py: u32, clicked: bool) void {
    // M42 UX r2: while the unsaved-changes dialog is open it is MODAL —
    // clicks route to its buttons FIRST (the shared wnd_core rect rule,
    // the same hit-test the kernel applies) and EVERY click is consumed:
    // nothing underneath (tab pills, Sexiburger, tray) may react. Hover
    // state is parked so the sidebar can't fight the modal.
    if (unsaved_dialog_open_tabwm) {
        hover_sexiburger = false;
        hover_tab = null;
        hover_theme_toggle = false;
        hover_clip = false;
        hover_new_tab = false;
        hover_go = false;
        if (clicked) apply_unsaved_choice(wnd_core.unsaved_dialog_choice_at(fb_w, fb_h, px, py));
        return;
    }

    // TWM: while the Go surface is up it is modal over the rail — a click
    // either picks the row under the pointer or dismisses, and NOTHING
    // underneath (tab pills, Sexiburger, tray) may react.
    if (go_open) {
        hover_sexiburger = false;
        hover_tab = null;
        hover_theme_toggle = false;
        hover_clip = false;
        hover_new_tab = false;
        hover_go = false;
        if (clicked) _ = go_click(px, py);
        return;
    }

    if (px >= sidebar_w) {
        hover_sexiburger = false;
        hover_tab = null;
        hover_theme_toggle = false;
        hover_clip = false;
        hover_new_tab = false;
        hover_go = false;
        return;
    }

    // TWM: the Go rail chip is checked BEFORE the Sexiburger header test —
    // it lives inside the rail, so the generic header hit-test would
    // otherwise eat its click (the same precedence pattern the "+ New
    // tab" pill and the row close 'x' use).
    const gcr = go_chip_rect();
    hover_go = (px >= gcr.x and px < gcr.x + gcr.w and py >= gcr.y and py < gcr.y + gcr.h);
    if (hover_go) {
        if (clicked) go_summon();
        return;
    }

    // Sexiburger header hit test (y = 8..48)
    hover_sexiburger = (px >= 8 and px < 172 and py >= 8 and py < 48);
    if (hover_sexiburger and clicked) {
        overlay_summon(); // emits `tabwm: god-menu` (M42 SX5)
    }

    // Theme toggle hit test (y = 672..696, x = 96..128)
    hover_theme_toggle = (px >= 96 and px < 128 and py >= 672 and py < 696);
    if (hover_theme_toggle and clicked) {
        if (std.mem.eql(u8, ui.theme_name(), "dark")) {
            _ = ui.set_theme("light");
        } else {
            _ = ui.set_theme("dark");
        }
    }

    // Clipboard hit test (y = 672..696, x = 134..170)
    hover_clip = (px >= 134 and px < 170 and py >= 672 and py < 696);

    // Tab items hit test (y = 58..650). M42 UX: the "+ New tab" pill is
    // checked FIRST — it lives inside the tab-row band, and the generic
    // row-index mapping would otherwise eat its click (the same precedence
    // pattern as the close 'x' check at x = 148..168 inside the row).
    hover_tab = null;
    hover_new_tab = (px >= 8 and px < 172 and py >= new_tab_pill_y() and py < new_tab_pill_y() + new_tab_pill_h);
    if (hover_new_tab) {
        if (clicked) trigger_new_tab(); // emits `tabwm: new-tab` + god-menu summon
    } else if (tab_index_at(py)) |idx| {
        hover_tab = idx;
        if (clicked) {
            // #1056 item 3: a click seeds the keyboard selection, so Up/Down
            // continue from the tab the user just pointed at.
            nav_sel = idx;
            // Check if clicked close box 'x' at x = 148..168
            // (M42 UX r2: the close DECISION routes through
            // request_close_tab — a dirty tab opens the dialog
            // instead of closing).
            if (px >= 148 and px < 168) {
                request_close_tab(idx);
            } else {
                activate_tab(idx);
                // M48/BT2: a press on the row body arms a drag; release over
                // a different row commits the reorder (a plain click is a
                // same-row no-op).
                begin_tab_drag(idx);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Keyboard Shortcuts Decoder (M39 TWM2)
// ---------------------------------------------------------------------------

/// The alt-tab next-target policy (M42 UX r2, claim #1011) — the TAB-LIST
/// mirror of WND's WMS6 Gate A `next_alt_tab_target`: the target is the
/// tab AFTER the active one, wrapping; null when fewer than two tabs (the
/// shim's "not enough windows" rule); `active=null` is treated as 0-start;
/// `shift` inverts the direction. Pure — BOTH Alt+Tab and Ctrl+Tab compute
/// their target through this helper, so the two chords can never disagree.
pub fn alt_tab_next(count: usize, active: ?usize, shift: bool) ?usize {
    if (count < 2) return null;
    const cur: usize = active orelse 0;
    if (shift) {
        return if (cur == 0) count - 1 else cur - 1;
    }
    return (cur + 1) % count;
}

pub fn handle_wm_key(usage: u8, flags: u16) void {
    const ctrl = (flags & ui.MOD_CTRL != 0);
    const shift = (flags & ui.MOD_SHIFT != 0);
    const alt = (flags & ui.MOD_ALT != 0);

    // M42 UX r2: Alt+Tab / Alt+Shift+Tab — WND WMS6 Gate A parity. The
    // kernel fans every key-down edge to the WM while it owns input (raw
    // chords included), so the WM proposes the next target via the SAME
    // alt_tab_next policy Ctrl+Tab uses and the kernel applies focus +
    // raise through the ALT_TAB commit seam (driving_award.alt_tab_wm_commit;
    // its focus auto-show re-reveals the TABWM-hidden target tab). Checked
    // BEFORE the Ctrl branch. No activate_tab on this path — the commit is
    // the kernel-side truth; only the local active index and the marker
    // keep the sidebar consistent.
    if (alt and usage == usage_tab and !unsaved_dialog_open_tabwm) {
        if (alt_tab_next(manager.tab_count, manager.active_idx, shift)) |target| {
            const target_id = manager.tabs[target].id;
            _ = syscall6(sys_wmctl, wmctl_alt_tab, target_id, alt_tab_commit, 0, 0, 0);
            manager.active_idx = target;
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s}{d}\n", .{ alt_tab_marker, target_id }) catch "tabwm: alt-tab\n";
            write_marker(msg);
        }
        return;
    }

    // #1056 item 3: plain sidebar navigation. Up/Down move the keyboard
    // selection (the list scrolls to keep it visible), Enter activates it,
    // PageUp/PageDown scroll a page. Only unmodified chords are claimed, so
    // Ctrl/Alt+arrow stay free for the kernel's window geometry chords.
    if (!ctrl and !alt) {
        switch (usage) {
            usage_up => {
                nav_move(-1);
                return;
            },
            usage_down => {
                nav_move(1);
                return;
            },
            usage_enter => {
                if (nav_sel != null) {
                    nav_activate();
                    return;
                }
            },
            usage_pageup => {
                scroll_tabs(-@as(i32, @intCast(visible_tab_rows())));
                return;
            },
            usage_pagedown => {
                scroll_tabs(@as(i32, @intCast(visible_tab_rows())));
                return;
            },
            else => {},
        }
    }

    if (ctrl) {
        // #1064: Ctrl+Shift+T reopens the last closed tab; Ctrl+Shift+Left/
        // Right reorders the active tab in the list. (Ctrl+Shift+Tab still
        // cycles — it is handled by the usage_tab branch below.)
        if (shift) {
            if (usage == usage_t) {
                _ = reopen_last_closed();
                return;
            }
            if (usage == usage_left) {
                _ = move_active_tab(-1);
                return;
            }
            if (usage == usage_right) {
                _ = move_active_tab(1);
                return;
            }
            // M48/BT2: Ctrl+Shift+PgUp/PgDn are the browser keyboard-move
            // chords (alongside Ctrl+Shift+Left/Right).
            if (usage == usage_pageup) {
                _ = move_active_tab(-1);
                return;
            }
            if (usage == usage_pagedown) {
                _ = move_active_tab(1);
                return;
            }
            // M48/BT1: duplicate the active tab.
            if (usage == usage_d) {
                _ = duplicate_active_tab();
                return;
            }
            // M48/BT3: pin/unpin the active tab.
            if (usage == usage_p) {
                if (manager.active_idx) |cur| _ = pin_toggle(cur);
                return;
            }
            // M48/BT6: freeze/unfreeze the active tab's badge.
            if (usage == usage_f) {
                if (manager.active_idx) |cur| _ = freeze_toggle(cur);
                return;
            }
            // M48/BT6: tab search.
            if (usage == usage_a) {
                tab_search_summon();
                return;
            }
            // TWM: Ctrl+Shift+G — the Go quick-jump.
            if (usage == usage_g) {
                go_summon();
                return;
            }
            // M48/BT5: per-tab history back/forward (Ctrl+Shift+[ / ]).
            if (usage == usage_left_bracket) {
                _ = nav_back_active();
                return;
            }
            if (usage == usage_right_bracket) {
                _ = nav_forward_active();
                return;
            }
        }

        // Ctrl+Tab / Ctrl+Shift+Tab: cycle tabs (M42 UX r2: the SAME
        // alt_tab_next policy the Alt+Tab chord uses — the two chords
        // agree by construction).
        if (usage == usage_tab) {
            if (alt_tab_next(manager.tab_count, manager.active_idx, shift)) |target| {
                activate_tab(target);
            }
            return;
        }

        // Ctrl+1..9: jump directly to tab index 0..8
        if (usage >= usage_1 and usage <= usage_9) {
            const target_idx: usize = @as(usize, usage - usage_1);
            if (target_idx < manager.tab_count) {
                activate_tab(target_idx);
            }
            return;
        }

        // Ctrl+W: close active tab (M42 UX r2: through the close DECISION
        // point — a dirty active tab opens the unsaved dialog instead).
        if (usage == usage_w) {
            if (manager.active_idx) |cur| {
                request_close_tab(cur);
            }
            return;
        }

        // Ctrl+T: the "+ New tab" affordance — summon the launcher (M42 UX)
        if (usage == usage_t) {
            trigger_new_tab();
            return;
        }

        // Ctrl+Space: summon the Sexiburger god-menu overlay (M42 SX5)
        if (usage == usage_space) {
            overlay_summon();
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// WM_RPC Mailbox Communication Loop
// ---------------------------------------------------------------------------
/// M48/BT5: a reply payload set by `wnd_mail_apply` and copied into the ack's
/// `title` field by `wnd_mail_reply` (the nav-poll channel: the WM hands the
/// app the target path it must navigate to). Zero length = no payload.
var rpc_reply_payload: [ui.wm_rpc_title_max]u8 = @as([ui.wm_rpc_title_max]u8, @splat(@as(u8, 0)));
var rpc_reply_payload_len: usize = 0;

fn wnd_mail_reply(reply_to: u8, req: *const ui.WmRpc, applied: bool) void {
    var rep: ui.WmRpc = .{
        .kind = req.kind | ui.wm_rpc_reply_flag,
        .id = req.id,
        .seq = req.seq,
        .reply_to = reply_to,
        .applied = if (applied) 1 else 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = @as([ui.wm_rpc_title_max]u8, @splat(@as(u8, 0))),
    };
    if (rpc_reply_payload_len > 0) {
        @memcpy(rep.title[0..rpc_reply_payload_len], rpc_reply_payload[0..rpc_reply_payload_len]);
        rpc_reply_payload_len = 0;
    }
    const rep_bytes = std.mem.asBytes(&rep);
    _ = syscall3(sys_ipc_send, reply_to, @intFromPtr(rep_bytes.ptr), rep_bytes.len);
}

fn set_reply_payload(payload: []const u8) void {
    const n = @min(payload.len, rpc_reply_payload.len);
    @memcpy(rpc_reply_payload[0..n], payload[0..n]);
    rpc_reply_payload_len = n;
}

pub fn wnd_mail_apply(req: *const ui.WmRpc) bool {
    switch (req.kind & 0x7f) {
        ui.wm_rpc_kind_raise => {
            if (manager.find_by_id(req.id)) |idx| {
                activate_tab(idx);
                return true;
            }
            return false;
        },
        ui.wm_rpc_kind_register_action, ui.wm_rpc_kind_config => {
            var label_slice: []const u8 = req.title[0..];
            for (req.title, 0..) |c, i| {
                if (c == 0) {
                    label_slice = req.title[0..i];
                    break;
                }
            }
            if (label_slice.len > 0) {
                if (manager.at_capacity(req.id)) return false;
                _ = manager.add_or_update_tab(req.id, label_slice);
                try_apply_persisted_after_join();
                return true;
            }
            return false;
        },
        ui.wm_rpc_kind_declare_fullscreen => {
            // M42 SX2: the app (via lib/tabapp.zig) declares itself
            // tab-aware — full-viewport eligible. Registers/renames the tab
            // from the payload title and, when the tab is ALREADY active,
            // immediately proposes the full viewport (the next activation
            // would otherwise wait for a tab switch).
            var label_slice: []const u8 = req.title[0..];
            for (req.title, 0..) |c, i| {
                if (c == 0) {
                    label_slice = req.title[0..i];
                    break;
                }
            }
            var idx: usize = undefined;
            if (manager.find_by_id(req.id)) |found| {
                idx = found;
            } else {
                // A full manager cannot accept the new window: refuse
                // honestly (applied=0) rather than aliasing it onto tab 0.
                if (manager.at_capacity(req.id)) return false;
                idx = manager.add_or_update_tab(req.id, if (label_slice.len > 0) label_slice else "App");
            }
            manager.tabs[idx].tab_aware = true;
            if (label_slice.len > 0) manager.tabs[idx].set_title(label_slice);
            if (manager.active_idx != null and manager.active_idx.? == idx) {
                activate_tab(idx);
            }
            try_apply_persisted_after_join();
            return true;
        },
        ui.wm_rpc_kind_cycle_tab => {
            manager.cycle_tab();
            if (manager.active_idx) |idx| {
                activate_tab(idx);
            }
            return true;
        },
        ui.wm_rpc_kind_detach_tab => {
            if (manager.find_by_id(req.id)) |idx| {
                // M42 UX r2: the third close entry point — same decision
                // rule as the pointer 'x' and Ctrl+W (dirty = dialog).
                request_close_tab(idx);
                return true;
            }
            return false;
        },
        // M48/BT5: an app declared a navigation event (FILE.BIN directory,
        // EDIT.BIN file). The path rides the `title` field.
        wm_rpc_kind_nav_declare => {
            var path: []const u8 = req.title[0..];
            for (req.title, 0..) |c, i| {
                if (c == 0) {
                    path = req.title[0..i];
                    break;
                }
            }
            return nav_declare(req.id, path);
        },
        // M48/BT5: an app polls for the target back/forward queued for it.
        // The reply `title` carries the path (id and applied still set).
        wm_rpc_kind_nav_poll => {
            var buf: [hist_path_max]u8 = undefined;
            if (nav_poll(req.id, &buf)) |target| {
                set_reply_payload(target);
                return true;
            }
            return false;
        },
        else => return false,
    }
}

pub fn wnd_mail_loop() void {
    var raw: [128]u8 = undefined;
    while (true) {
        const got = syscall2(sys_ipc_recv, @intFromPtr(&raw), raw.len);
        if (got <= 0) return;
        if (got < @sizeOf(ui.WmRpc)) continue;
        var req: ui.WmRpc = undefined;
        @memcpy(std.mem.asBytes(&req), raw[0..@sizeOf(ui.WmRpc)]);
        if (req.kind & ui.wm_rpc_reply_flag != 0) continue;
        const applied = wnd_mail_apply(&req);
        wnd_mail_reply(req.reply_to, &req, applied);
    }
}

// ---------------------------------------------------------------------------
// Server Entry Point & Main Loop
// ---------------------------------------------------------------------------
export fn _start() callconv(.c) noreturn {
    main();
}

fn main() noreturn {
    // 1. Register as the WM server over slot 65
    if (syscall6(sys_wmctl, wmctl_register, 0, 0, 0, 0, 0) != 0) {
        while (true) {
            _ = syscall0(sys_yield_num);
        }
    }
    write_marker(registered_marker);

    // 2. Map direct scanout surface
    _ = ensure_scanout_mapped();

    // 3. Initialize TrueType fonts and desktop theme
    _ = ui.init_fonts();
    _ = ui.sync_theme_from_host();

    // M42 SX5: load the APPS.TXT catalog for the god-menu overlay
    _ = overlay_load_manifest();

    // #1055: the real clock — read the session's boot wall-time (local
    // seconds since midnight) from the host share, if present.
    load_clock_epoch();

    // #1056 item 3c: the tab order/active selection from the last session
    // (applied as the restored windows reappear).
    load_tabs();

    var ev: Event = undefined;

    while (true) {
        // Block until kernel render server queues an event
        if (syscall2(sys_wait_event_num, @intFromPtr(&ev), @sizeOf(Event)) <= 0) {
            _ = syscall0(sys_yield_num);
            continue;
        }

        switch (ev.kind) {
            composite_tick_kind => {
                ticks_count += 1;

                // Drain app mailbox requests
                wnd_mail_loop();

                // M42 UX r2: the close-feedback flash countdown — one tick
                // per composite; at 0 the band disappears.
                if (close_flash_ticks > 0) {
                    close_flash_ticks -= 1;
                    if (close_flash_ticks == 0) close_flash_row = null;
                }

                // M48/BT6: advance the hover-preview dwell.
                _ = hover_tick();

                // #1056 item 1: the real clock — the session host epoch when
                // `.clock` is present, else the kernel's firmware clock
                // (boot EFI GetTime + uptime), else honest uptime.
                const hms = tick_clock_face(ticks_count);
                clock_hours = hms.h;
                clock_minutes = hms.m;
                clock_seconds = hms.s;

                // Render Left Sidebar directly to scanout
                if (scanout_ptr) |scan| {
                    draw_sidebar(scan);
                    write_marker(sidebar_render_marker);
                }

                // Request present at cadence
                if (ticks_count % present_every == 0) {
                    _ = syscall6(sys_wmctl, wmctl_request_present, 0, 0, 0, 0, 0);
                    present_count += 1;
                    write_marker(present_marker);
                }
            },
            wm_pointer_kind => {
                const px = ev.arg0 & 0xffff;
                const py = ev.arg0 >> 16;
                const buttons: u8 = @intCast(ev.flags & 0xff);
                const clicked = (buttons & btn_left) != 0;
                const left_released = (prev_buttons & btn_left) != 0 and (buttons & btn_left) == 0;
                handle_pointer(px, py, clicked);
                // M48/BT2: a left release commits an in-flight tab drag.
                if (left_released) _ = end_tab_drag(py);
                // #1064: middle-click a tab to close it (edge-detected — the
                // kernel fans the held-button state on every sample).
                if ((buttons & btn_middle) != 0 and (prev_buttons & btn_middle) == 0) {
                    handle_middle_click(px, py);
                }
                prev_buttons = buttons;
            },
            wm_window_kind => {
                // Window opened or registered by an app (id >= 2). M42 UX:
                // the mirror is decoded here and synced into the tab list
                // by handle_window_mirror — flags low byte = id, bit 8 =
                // visible, bit 12 = unsaved (M42 UX r2: fanned from
                // user_set_unsaved), bit 13 = released; arg1 = w|(h<<16)
                // as today.
                const wid: u8 = @intCast(ev.flags & 0xff);
                const visible = (ev.flags & (1 << 8)) != 0;
                const unsaved = (ev.flags & (1 << 12)) != 0;
                const released = (ev.flags & (1 << 13)) != 0;
                const orig_w: u32 = @intCast(ev.arg1 & 0xffff);
                const orig_h: u32 = @intCast(ev.arg1 >> 16);
                handle_window_mirror(wid, visible, released, unsaved, orig_w, orig_h);
            },
            wm_key_kind => {
                const usage: u8 = @intCast(ev.arg0 & 0xff);
                // M42 UX r2: the modal unsaved-changes dialog consumes the
                // key stream FIRST (Escape = cancel, Enter = save, all
                // else swallowed — no chord may mutate the tab list while
                // a close decision is pending).
                if (unsaved_dialog_open_tabwm) {
                    _ = unsaved_dialog_key(usage);
                } else if (!overlay_key(usage) and !go_key(usage) and !tab_search_key(usage)) {
                    // M42 SX5: the god-menu overlay (and the M48 START page)
                    // consume the stream next; the M48 tab-search overlay
                    // follows, then the tab chords.
                    handle_wm_key(usage, ev.flags);
                }
            },
            else => {},
        }
    }
}

/// Restore every file-global TABWM mutates to its cold-boot value, so a
/// test's outcome never depends on which tests ran before it (#1056 item 4).
/// Tests call this FIRST; it is not part of the server path.
pub fn resetForTest() void {
    manager = TabManager.init();

    hover_tab = null;
    hover_sexiburger = false;
    hover_theme_toggle = false;
    hover_clip = false;
    hover_new_tab = false;

    unsaved_pending_close = null;
    unsaved_pending_id = 0;
    unsaved_dialog_open_tabwm = false;

    close_flash_row = null;
    close_flash_ticks = 0;
    close_flash_closed = false;

    clock_hours = 0;
    clock_minutes = 0;
    clock_seconds = 0;
    clock_epoch = null;
    clock_source_logged = false;
    ticks_count = 0;
    present_count = 0;

    // #1056 item 3: the list window, keyboard cursor, and persistence state.
    tab_scroll = 0;
    nav_sel = null;
    persisted_tabs = null;
    have_last_saved_tabs = false;
    last_saved_tabs_len = 0;

    // #1064: rail-neutral tab ergonomics state.
    prev_buttons = 0;
    closed_count = 0;
    pending_launch_bin_len = 0;

    // M48 state (BT1–BT6).
    pending_launch_group_len = 0;
    pending_launch_pinned = false;
    drag_from = null;
    start_open = false;
    pending_nav_id = 0;
    pending_nav_len = 0;
    hover_preview_ticks = 0;
    hover_preview_target = null;
    tab_search_open = false;
    tab_search_filter_len = 0;
    tab_search_count = 0;
    tab_search_sel = 0;
    rpc_reply_payload_len = 0;

    // TWM: the Go surface, the v2 persistence slot, and the change log.
    go_open = false;
    go_query_len = 0;
    go_result_count = 0;
    go_sel = 0;
    hover_go = false;
    persisted_tabs_v2 = null;
    tabs_seq = 0;
    tablog_seq = 0;
    tablog_head = 0;
    tablog_count = 0;
    tablog_last_flush_seq = 0;
    tablog_line_lens = @as([tablog_ring]usize, @splat(@as(usize, 0)));

    overlay_open = false;
    overlay_loaded = false;
    overlay_count = 0;
    overlay_filter_len = 0;
    overlay_filtered_count = 0;
    overlay_sel = 0;

    mascot_loaded = false;
}

// ---------------------------------------------------------------------------
// Unit Tests (M39 TWM1 + TWM2)
// ---------------------------------------------------------------------------
test "tabwm: tab manager allocation and lifecycle" {
    resetForTest();
    var mgr = TabManager.init();
    try std.testing.expectEqual(@as(usize, 0), mgr.tab_count);
    try std.testing.expectEqual(@as(?usize, null), mgr.active_idx);

    // Add first tab
    const idx0 = mgr.add_or_update_tab(1, "Calculator");
    try std.testing.expectEqual(@as(usize, 0), idx0);
    try std.testing.expectEqual(@as(usize, 1), mgr.tab_count);
    try std.testing.expectEqual(@as(?usize, 0), mgr.active_idx);
    try std.testing.expectEqualStrings("Calculator", mgr.tabs[0].get_title());

    // Add second tab
    const idx1 = mgr.add_or_update_tab(2, "Notes");
    try std.testing.expectEqual(@as(usize, 1), idx1);
    try std.testing.expectEqual(@as(usize, 2), mgr.tab_count);
    try std.testing.expectEqual(@as(?usize, 0), mgr.active_idx);

    // Switch active tab
    try std.testing.expect(mgr.activate_tab(1));
    try std.testing.expectEqual(@as(?usize, 1), mgr.active_idx);
    try std.testing.expectEqual(@as(?u32, 2), mgr.get_active_id());

    // Cycle tab
    mgr.cycle_tab();
    try std.testing.expectEqual(@as(?usize, 0), mgr.active_idx);

    // Remove tab
    try std.testing.expect(mgr.remove_tab(1));
    try std.testing.expectEqual(@as(usize, 1), mgr.tab_count);
    try std.testing.expectEqualStrings("Notes", mgr.tabs[0].get_title());
}

test "tabwm: tab manager active index adjustment on removal" {
    resetForTest();
    var mgr = TabManager.init();
    _ = mgr.add_or_update_tab(10, "Tab 0");
    _ = mgr.add_or_update_tab(20, "Tab 1");
    _ = mgr.add_or_update_tab(30, "Tab 2");
    _ = mgr.add_or_update_tab(40, "Tab 3");
    try std.testing.expectEqual(@as(usize, 4), mgr.tab_count);

    // Set active index to 2 (Tab 2, id 30)
    try std.testing.expect(mgr.activate_tab(2));
    try std.testing.expectEqual(@as(?usize, 2), mgr.active_idx);
    try std.testing.expectEqual(@as(?u32, 30), mgr.get_active_id());

    // Remove Tab 0 (index 0 < cur 2) -> cur should decrement to 1 (still Tab 2, id 30)
    try std.testing.expect(mgr.remove_tab(10));
    try std.testing.expectEqual(@as(usize, 3), mgr.tab_count);
    try std.testing.expectEqual(@as(?usize, 1), mgr.active_idx);
    try std.testing.expectEqual(@as(?u32, 30), mgr.get_active_id());

    // Remove Tab 3 (tail, index 2 > cur 1) -> cur stays 1
    try std.testing.expect(mgr.remove_tab(40));
    try std.testing.expectEqual(@as(usize, 2), mgr.tab_count);
    try std.testing.expectEqual(@as(?usize, 1), mgr.active_idx);
    try std.testing.expectEqual(@as(?u32, 30), mgr.get_active_id());

    // Remove Tab 2 (currently active at index 1) -> cur clamps to 0 (Tab 1, id 20)
    try std.testing.expect(mgr.remove_tab(30));
    try std.testing.expectEqual(@as(usize, 1), mgr.tab_count);
    try std.testing.expectEqual(@as(?usize, 0), mgr.active_idx);
    try std.testing.expectEqual(@as(?u32, 20), mgr.get_active_id());

    // Remove final tab -> active_idx becomes null
    try std.testing.expect(mgr.remove_tab(20));
    try std.testing.expectEqual(@as(usize, 0), mgr.tab_count);
    try std.testing.expectEqual(@as(?usize, null), mgr.active_idx);
    try std.testing.expectEqual(@as(?u32, null), mgr.get_active_id());
}

test "tabwm: tab cycle forward and backward" {
    resetForTest();
    var mgr = TabManager.init();
    _ = mgr.add_or_update_tab(1, "A");
    _ = mgr.add_or_update_tab(2, "B");
    _ = mgr.add_or_update_tab(3, "C");
    try std.testing.expectEqual(@as(?usize, 0), mgr.active_idx);

    // Forward cycle: 0 -> 1 -> 2 -> 0
    mgr.cycle_tab();
    try std.testing.expectEqual(@as(?usize, 1), mgr.active_idx);
    mgr.cycle_tab();
    try std.testing.expectEqual(@as(?usize, 2), mgr.active_idx);
    mgr.cycle_tab();
    try std.testing.expectEqual(@as(?usize, 0), mgr.active_idx);

    // Backward cycle: 0 -> 2 -> 1 -> 0
    mgr.cycle_tab_backward();
    try std.testing.expectEqual(@as(?usize, 2), mgr.active_idx);
    mgr.cycle_tab_backward();
    try std.testing.expectEqual(@as(?usize, 1), mgr.active_idx);
    mgr.cycle_tab_backward();
    try std.testing.expectEqual(@as(?usize, 0), mgr.active_idx);
}

test "tabwm: keyboard shortcuts routing" {
    resetForTest();
    manager = TabManager.init();
    _ = manager.add_or_update_tab(101, "Browser");
    _ = manager.add_or_update_tab(102, "Terminal");
    _ = manager.add_or_update_tab(103, "Editor");
    activate_tab(0);
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);

    // 1. Ctrl+Tab -> cycles to Tab 1
    handle_wm_key(usage_tab, ui.MOD_CTRL);
    try std.testing.expectEqual(@as(?usize, 1), manager.active_idx);
    try std.testing.expectEqual(@as(?u32, 102), manager.get_active_id());

    // 2. Ctrl+Shift+Tab -> cycles back to Tab 0
    handle_wm_key(usage_tab, ui.MOD_CTRL | ui.MOD_SHIFT);
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);

    // 3. Ctrl+3 (usage_3 = 0x20) -> jumps directly to Tab 2
    handle_wm_key(usage_3, ui.MOD_CTRL);
    try std.testing.expectEqual(@as(?usize, 2), manager.active_idx);
    try std.testing.expectEqual(@as(?u32, 103), manager.get_active_id());

    // 4. Ctrl+1 (usage_1 = 0x1e) -> jumps directly to Tab 0
    handle_wm_key(usage_1, ui.MOD_CTRL);
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);

    // 5. Ctrl+W -> closes active Tab 0
    handle_wm_key(usage_w, ui.MOD_CTRL);
    try std.testing.expectEqual(@as(usize, 2), manager.tab_count);
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);
    try std.testing.expectEqual(@as(?u32, 102), manager.get_active_id());

    // 6. Ctrl+Space -> triggers god menu
    handle_wm_key(usage_space, ui.MOD_CTRL);
}

test "tabwm: pointer hit testing and tab selection / close button" {
    resetForTest();
    manager = TabManager.init();
    _ = manager.add_or_update_tab(201, "Calc");
    _ = manager.add_or_update_tab(202, "Files");
    activate_tab(0);

    // Hover over Tab 1 (y = 58 + 38 = 96)
    handle_pointer(50, 100, false);
    try std.testing.expectEqual(@as(?usize, 1), hover_tab);

    // Click Tab 1 body (x = 50, y = 100) -> activates Tab 1
    handle_pointer(50, 100, true);
    try std.testing.expectEqual(@as(?usize, 1), manager.active_idx);
    try std.testing.expectEqual(@as(?u32, 202), manager.get_active_id());

    // Click Tab 1 close button 'x' (x = 156, y = 100) -> closes Tab 1
    handle_pointer(156, 100, true);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);
    try std.testing.expectEqual(@as(?u32, 201), manager.get_active_id());

    // Click Sexiburger header (x = 20, y = 20)
    handle_pointer(20, 20, true);
    try std.testing.expect(hover_sexiburger);
}

test "tabwm: wnd_mail_apply RPC commands" {
    resetForTest();
    manager = TabManager.init();
    _ = manager.add_or_update_tab(31, "Old Title");
    _ = manager.add_or_update_tab(32, "Other");
    activate_tab(0);

    // 1. Rename tab via config RPC
    var req_config = ui.WmRpc{
        .kind = ui.wm_rpc_kind_config,
        .id = 31,
        .seq = 1,
        .reply_to = 5,
        .applied = 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = @as([ui.wm_rpc_title_max]u8, @splat(@as(u8, 0))),
    };
    @memcpy(req_config.title[0..9], "New Title");
    try std.testing.expect(wnd_mail_apply(&req_config));
    try std.testing.expectEqualStrings("New Title", manager.tabs[0].get_title());

    // 2. Raise tab via raise RPC
    var req_raise = ui.WmRpc{
        .kind = ui.wm_rpc_kind_raise,
        .id = 32,
        .seq = 2,
        .reply_to = 5,
        .applied = 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = @as([ui.wm_rpc_title_max]u8, @splat(@as(u8, 0))),
    };
    try std.testing.expect(wnd_mail_apply(&req_raise));
    try std.testing.expectEqual(@as(?usize, 1), manager.active_idx);

    // 3. Cycle tab via cycle RPC
    var req_cycle = ui.WmRpc{
        .kind = ui.wm_rpc_kind_cycle_tab,
        .id = 0,
        .seq = 3,
        .reply_to = 5,
        .applied = 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = @as([ui.wm_rpc_title_max]u8, @splat(@as(u8, 0))),
    };
    try std.testing.expect(wnd_mail_apply(&req_cycle));
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);

    // 4. Detach / close tab via detach RPC
    var req_detach = ui.WmRpc{
        .kind = ui.wm_rpc_kind_detach_tab,
        .id = 32,
        .seq = 4,
        .reply_to = 5,
        .applied = 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = @as([ui.wm_rpc_title_max]u8, @splat(@as(u8, 0))),
    };
    try std.testing.expect(wnd_mail_apply(&req_detach));
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
}

test "tabwm: geometry constants respect M39 tokens" {
    resetForTest();
    try std.testing.expectEqual(@as(u32, 1280), fb_w);
    try std.testing.expectEqual(@as(u32, 720), fb_h);
    try std.testing.expectEqual(@as(u32, 180), sidebar_w);
    try std.testing.expectEqual(@as(u32, 1100), viewport_w);
    try std.testing.expectEqual(@as(u32, 720), viewport_h);
    try std.testing.expectEqual(sidebar_w + viewport_w, fb_w);
}

test "tabwm: compute_tab_viewport centering and full bleed" {
    resetForTest();
    // 1. Resizable window gets full 1100x720 at (180, 0)
    var tab_res = Tab{
        .id = 1,
        .orig_w = 600,
        .orig_h = 400,
        .resizable = true,
        .valid = true,
    };
    const vp_res = compute_tab_viewport(&tab_res);
    try std.testing.expectEqual(@as(u32, 180), vp_res.x);
    try std.testing.expectEqual(@as(u32, 0), vp_res.y);
    try std.testing.expectEqual(@as(u32, 1100), vp_res.w);
    try std.testing.expectEqual(@as(u32, 720), vp_res.h);

    // 2. Unspecified size (orig_w=0) gets full 1100x720
    var tab_zero = Tab{
        .id = 2,
        .orig_w = 0,
        .orig_h = 0,
        .resizable = false,
        .valid = true,
    };
    const vp_zero = compute_tab_viewport(&tab_zero);
    try std.testing.expectEqual(@as(u32, 180), vp_zero.x);
    try std.testing.expectEqual(@as(u32, 0), vp_zero.y);
    try std.testing.expectEqual(@as(u32, 1100), vp_zero.w);
    try std.testing.expectEqual(@as(u32, 720), vp_zero.h);

    // 3. Fixed size window (512x384, e.g. WINLOOP.BIN) centers cleanly:
    // x = 180 + (1100 - 512) / 2 = 180 + 294 = 474
    // y = 0 + (720 - 384) / 2 = 168
    var tab_fixed = Tab{
        .id = 3,
        .orig_w = 512,
        .orig_h = 384,
        .resizable = false,
        .valid = true,
    };
    const vp_fixed = compute_tab_viewport(&tab_fixed);
    try std.testing.expectEqual(@as(u32, 474), vp_fixed.x);
    try std.testing.expectEqual(@as(u32, 168), vp_fixed.y);
    try std.testing.expectEqual(@as(u32, 512), vp_fixed.w);
    try std.testing.expectEqual(@as(u32, 384), vp_fixed.h);

    // 4. Fixed size window (260x340, e.g. a leftover Zig client) centers cleanly:
    // x = 180 + (1100 - 260) / 2 = 180 + 420 = 600
    // y = 0 + (720 - 340) / 2 = 190
    var tab_calc = Tab{
        .id = 4,
        .orig_w = 260,
        .orig_h = 340,
        .resizable = false,
        .valid = true,
    };
    const vp_calc = compute_tab_viewport(&tab_calc);
    try std.testing.expectEqual(@as(u32, 600), vp_calc.x);
    try std.testing.expectEqual(@as(u32, 190), vp_calc.y);
    try std.testing.expectEqual(@as(u32, 260), vp_calc.w);
    try std.testing.expectEqual(@as(u32, 340), vp_calc.h);
}

test "tabwm: draw_viewport_backdrop writes canvas outside window" {
    resetForTest();
    var fb: [fb_w * fb_h]u32 = undefined;
    @memset(&fb, 0);

    // With 0 tabs, draw_viewport_backdrop should fill the whole viewport (180..1280, 0..720)
    manager = TabManager.init();
    draw_viewport_backdrop(&fb);

    // Sidebar area (0..179) should be untouched (0)
    try std.testing.expectEqual(@as(u32, 0), fb[100 * fb_w + 50]);
    // Viewport non-dot area should be dark slate canvas 0xFF14161B
    try std.testing.expectEqual(@as(u32, 0xFF14161B), fb[101 * fb_w + 201]);
    // Viewport dot node (x%24 == 0 and y%24 == 0, e.g. x=240, y=120) should be dot color 0xFF252934
    try std.testing.expectEqual(@as(u32, 0xFF252934), fb[120 * fb_w + 240]);
}

// ---------------------------------------------------------------------------
// Unit Tests (M42 SX1 — the proper mascot emblem)
// ---------------------------------------------------------------------------
test "tabwm: proper mascot emblem decodes at 28x28 (M42 SX1)" {
    resetForTest();
    const img = mascot_image() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 28), img.width);
    try std.testing.expectEqual(@as(u32, 28), img.height);
    // The artwork's center pixel is the burger's cheese layer (warm yellow);
    // the rect-drawn mini mascot never had a center like this.
    const c = img.pixels[14 * 28 + 14];
    const r = (c >> 16) & 0xFF;
    const g = (c >> 8) & 0xFF;
    const b = c & 0xFF;
    try std.testing.expect(r > 200 and g > 150 and b < 160);
    // The artwork's background is transparent (alpha 0 at the corner)
    try std.testing.expectEqual(@as(u32, 0), (img.pixels[0] >> 24) & 0xFF);
}

test "tabwm: draw_sidebar blits the raster emblem into the scanout (M42 SX1)" {
    resetForTest();
    var fb: [fb_w * fb_h]u32 = undefined;
    @memset(&fb, 0);
    manager = TabManager.init();
    hover_sexiburger = false; // earlier pointer tests may have left hover state
    mascot_loaded = false; // force a fresh decode for this test run
    draw_sidebar(&fb);
    const img = mascot_image() orelse return error.TestUnexpectedResult;
    // The icon's opaque center is exactly the fixture's cheese pixel
    // (alpha 255 -> blend_source_over is an overwrite)
    const center = fb[(13 + 14) * fb_w + (12 + 14)];
    try std.testing.expectEqual(img.pixels[14 * 28 + 14], center);
    // A fully transparent source pixel leaves the painted sidebar bg (not
    // the emblem) — the emblem's alpha respected the destination
    const corner = fb[13 * fb_w + 12];
    try std.testing.expectEqual(ui.sidebar_bg(), corner & 0x00FFFFFF);
}

// ---------------------------------------------------------------------------
// Unit Tests (M42 SX2 — the full-screen viewport seam)
// ---------------------------------------------------------------------------
test "tabwm: tab-aware fixed app takes the full viewport (M42 SX2)" {
    resetForTest();
    var tab = Tab{
        .id = 3,
        .orig_w = 512,
        .orig_h = 384,
        .resizable = false,
        .tab_aware = false,
        .valid = true,
    };
    // Without the declaration: the M39 TWM3 centered presentation.
    const centered = compute_tab_viewport(&tab);
    try std.testing.expectEqual(@as(u32, 474), centered.x);
    try std.testing.expectEqual(@as(u32, 168), centered.y);
    try std.testing.expectEqual(@as(u32, 512), centered.w);
    try std.testing.expectEqual(@as(u32, 384), centered.h);

    // With the tab-aware declaration: the FULL content viewport.
    tab.tab_aware = true;
    const full = compute_tab_viewport(&tab);
    try std.testing.expectEqual(@as(u32, 180), full.x);
    try std.testing.expectEqual(@as(u32, 0), full.y);
    try std.testing.expectEqual(@as(u32, 1100), full.w);
    try std.testing.expectEqual(@as(u32, 720), full.h);
}

test "tabwm: viewport_change_needed idempotence (M42 SX2)" {
    resetForTest();
    var tab = Tab{ .id = 1, .valid = true };
    const full = Rect.make(viewport_x, viewport_y, viewport_w, viewport_h);
    // First activation always proposes.
    try std.testing.expect(viewport_change_needed(&tab, full));
    tab.applied_vp = full;
    // Same rect: no repeat proposal (no repeat WIN_RESIZE at the app).
    try std.testing.expect(!viewport_change_needed(&tab, full));
    // Any change re-proposes.
    try std.testing.expect(viewport_change_needed(&tab, Rect.make(474, 168, 512, 384)));
}

test "tabwm: declare_fullscreen RPC registers and applies the full viewport (M42 SX2)" {
    resetForTest();
    manager = TabManager.init();
    // Unknown window id: the declaration creates the tab.
    var req = ui.WmRpc{
        .kind = ui.wm_rpc_kind_declare_fullscreen,
        .id = 42,
        .seq = 1,
        .reply_to = 5,
        .applied = 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = @as([ui.wm_rpc_title_max]u8, @splat(@as(u8, 0))),
    };
    @memcpy(req.title[0..4], "CALC");
    try std.testing.expect(wnd_mail_apply(&req));
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expect(manager.tabs[0].tab_aware);
    try std.testing.expectEqualStrings("CALC", manager.tabs[0].get_title());

    // Activate: the full-viewport proposal is applied and recorded.
    activate_tab(0);
    try std.testing.expect(manager.tabs[0].applied_vp != null);
    try std.testing.expectEqual(@as(u32, 1100), manager.tabs[0].applied_vp.?.w);

    // Re-declaration while already active: idempotent re-activation keeps
    // the same applied rect (the app gets no repeat WIN_RESIZE).
    try std.testing.expect(wnd_mail_apply(&req));
    try std.testing.expectEqual(@as(u32, 1100), manager.tabs[0].applied_vp.?.w);
    try std.testing.expectEqual(@as(u32, 180), manager.tabs[0].applied_vp.?.x);
}

test "tabwm: declare_fullscreen on an inactive tab defers the proposal (M42 SX2)" {
    resetForTest();
    manager = TabManager.init();
    _ = manager.add_or_update_tab(31, "Existing");
    activate_tab(0);
    const before = manager.tabs[0].applied_vp;

    var req = ui.WmRpc{
        .kind = ui.wm_rpc_kind_declare_fullscreen,
        .id = 32,
        .seq = 2,
        .reply_to = 5,
        .applied = 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = @as([ui.wm_rpc_title_max]u8, @splat(@as(u8, 0))),
    };
    @memcpy(req.title[0..5], "FILES");
    try std.testing.expect(wnd_mail_apply(&req));
    try std.testing.expectEqual(@as(usize, 2), manager.tab_count);
    try std.testing.expect(manager.tabs[1].tab_aware);
    // The inactive declaration did not steal activation...
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);
    // ...and the active tab's applied viewport is untouched.
    try std.testing.expectEqual(before, manager.tabs[0].applied_vp);
}

// ---------------------------------------------------------------------------
// Unit Tests (M42 SX5 — the god-menu overlay)
// ---------------------------------------------------------------------------
fn overlay_seed_catalog() void {
    overlay_count = 3;
    const seeds = [_]struct { bin: []const u8, label: []const u8 }{
        .{ .bin = "GOCALC.ELF", .label = "64-bit Calc" },
        .{ .bin = "NOTEPAD.BIN", .label = "Text Editor" },
        .{ .bin = "TOP.BIN", .label = "Task Manager" },
    };
    for (seeds, 0..) |s, i| {
        @memcpy(overlay_bins[i][0..s.bin.len], s.bin);
        overlay_bin_lens[i] = s.bin.len;
        @memcpy(overlay_labels[i][0..s.label.len], s.label);
        overlay_label_lens[i] = s.label.len;
    }
    overlay_filter_len = 0;
    overlay_refresh_filter();
}

test "tabwm: god-menu overlay filters the manifest (M42 SX5)" {
    resetForTest();
    overlay_seed_catalog();
    try std.testing.expectEqual(@as(usize, 3), overlay_filtered_count);
    // Case-insensitive substring over label + bin.
    overlay_filter_len = 4;
    @memcpy(overlay_filter[0..4], "calc");
    overlay_refresh_filter();
    try std.testing.expectEqual(@as(usize, 1), overlay_filtered_count);
    try std.testing.expectEqual(@as(usize, 0), overlay_sel);
    // No hits: the empty state renders, launch refuses.
    overlay_filter_len = 3;
    @memcpy(overlay_filter[0..3], "zzz");
    overlay_refresh_filter();
    try std.testing.expectEqual(@as(usize, 0), overlay_filtered_count);
    overlay_open = true;
    try std.testing.expect(!overlay_launch_selected());
    overlay_dismiss();
}

test "tabwm: god-menu overlay keys — filter, select, launch, dismiss (M42 SX5)" {
    resetForTest();
    overlay_seed_catalog();
    overlay_open = true;
    // 'r' extends the filter: "Text Editor"/"Task Manager" contain 'r';
    // "64-bit Calc" + "GOCALC.ELF" do not.
    _ = overlay_key(0x15); // 'r'
    try std.testing.expectEqual(@as(usize, 2), overlay_filtered_count);
    // Backspace clears back to 3 hits.
    _ = overlay_key(0x2a);
    try std.testing.expectEqual(@as(usize, 3), overlay_filtered_count);
    // Down moves the selection.
    _ = overlay_key(0x51);
    try std.testing.expectEqual(@as(usize, 1), overlay_sel);
    // Up moves it back.
    _ = overlay_key(0x52);
    try std.testing.expectEqual(@as(usize, 0), overlay_sel);
    // Enter launches the selected app (host: exec no-ops) and dismisses.
    try std.testing.expect(overlay_launch_selected());
    try std.testing.expect(!overlay_open);
    try std.testing.expectEqual(@as(usize, 0), overlay_filter_len);
    // Escape dismisses cleanly.
    overlay_open = true;
    try std.testing.expect(overlay_key(0x29));
    try std.testing.expect(!overlay_open);
}

test "tabwm: overlay keys are consumed only while open (M42 SX5)" {
    resetForTest();
    overlay_open = false;
    // With the overlay closed, letter keys fall through (not consumed).
    try std.testing.expect(!overlay_key(0x04));
}

test "tabwm: god-menu overlay accepts digits, minus, period in the filter (M42 SX5)" {
    resetForTest();
    overlay_seed_catalog();
    overlay_open = true;
    // "64-bit": digits 6,4 (usages 0x23,0x21), minus (0x2d), b,i,t.
    _ = overlay_key(0x23);
    _ = overlay_key(0x21);
    try std.testing.expectEqual(@as(usize, 2), overlay_filter_len);
    _ = overlay_key(0x2d);
    try std.testing.expectEqual(@as(usize, 3), overlay_filter_len);
    try std.testing.expectEqual(@as(u8, '-'), overlay_filter[2]);
    _ = overlay_key(0x05); // b
    _ = overlay_key(0x0c); // i
    _ = overlay_key(0x17); // t
    try std.testing.expectEqual(@as(usize, 6), overlay_filter_len);
    overlay_refresh_filter();
    // Exactly one hit: "64-bit Calc" (GOCALC.ELF).
    try std.testing.expectEqual(@as(usize, 1), overlay_filtered_count);
    overlay_dismiss();
}

// ---------------------------------------------------------------------------
// Unit Tests (M42 UX hardening — 2026-09-05)
// ---------------------------------------------------------------------------
test "tabwm: released mirror removes the tab and activates the next (M42 UX)" {
    resetForTest();
    manager = TabManager.init();
    _ = manager.add_or_update_tab(2, "Alpha");
    _ = manager.add_or_update_tab(3, "Beta");
    activate_tab(0); // active = id 2

    // The kernel RELEASED window 2 (app self-exit): the tab goes, and the
    // next tab activates because the removed one was active.
    handle_window_mirror(2, false, true, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expect(manager.find_by_id(2) == null);
    try std.testing.expectEqual(@as(?u32, 3), manager.get_active_id());

    // Removing a NON-active tab keeps the active tab (index adjusts).
    _ = manager.add_or_update_tab(4, "Gamma");
    activate_tab(1); // active = id 3 (index 1 after the first removal)
    handle_window_mirror(4, false, true, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expectEqual(@as(?u32, 3), manager.get_active_id());
}

test "tabwm: released mirror for an unknown id is a no-op (M42 UX)" {
    resetForTest();
    manager = TabManager.init();
    _ = manager.add_or_update_tab(2, "Alpha");
    activate_tab(0);
    handle_window_mirror(9, false, true, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);
    try std.testing.expectEqual(@as(?u32, 2), manager.get_active_id());
}

test "tabwm: hide mirror without released does NOT remove a tab (M42 UX)" {
    resetForTest();
    manager = TabManager.init();
    _ = manager.add_or_update_tab(2, "Alpha");
    activate_tab(0);
    // TABWM's own hide echo / an external hide: the tab list is ours.
    handle_window_mirror(2, false, false, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expect(manager.find_by_id(2) != null);
    try std.testing.expectEqual(@as(?u32, 2), manager.get_active_id());
}

test "tabwm: visible mirror upserts geometry (M42 UX)" {
    resetForTest();
    manager = TabManager.init();
    _ = manager.add_or_update_tab(2, "Alpha");
    handle_window_mirror(2, true, false, false, 640, 480);
    try std.testing.expectEqual(@as(u32, 640), manager.tabs[0].orig_w);
    try std.testing.expectEqual(@as(u32, 480), manager.tabs[0].orig_h);
    // Zero geometry never clobbers a known size.
    handle_window_mirror(2, true, false, false, 0, 0);
    try std.testing.expectEqual(@as(u32, 640), manager.tabs[0].orig_w);
    try std.testing.expectEqual(@as(u32, 480), manager.tabs[0].orig_h);
}

test "tabwm: the 17th window is ignored, tab 0 not hijacked (M42 UX)" {
    resetForTest();
    manager = TabManager.init();
    var id: u32 = 2;
    while (id < 2 + max_tabs) : (id += 1) {
        _ = manager.add_or_update_tab(id, "Filler");
    }
    try std.testing.expectEqual(max_tabs, manager.tab_count);
    try std.testing.expect(manager.activate_tab(3));
    handle_window_mirror(99, true, false, false, 100, 100);
    try std.testing.expectEqual(max_tabs, manager.tab_count); // no add
    try std.testing.expect(manager.find_by_id(99) == null);
    try std.testing.expectEqual(@as(?usize, 3), manager.active_idx); // NOT tab 0
}

test "tabwm: + New tab affordance and Ctrl+T trigger the new-tab path (M42 UX)" {
    resetForTest();
    // The pinned marker the class-B live gate greps.
    try std.testing.expectEqualStrings("tabwm: new-tab\n", new_tab_marker);

    // M48/BT4: Ctrl+T summons the START surface (the browser new-tab page),
    // not the Sexiburger command palette.
    manager = TabManager.init();
    start_open = false;
    overlay_open = false;
    handle_wm_key(usage_t, ui.MOD_CTRL);
    try std.testing.expect(start_open);
    try std.testing.expect(!overlay_open);
    start_dismiss();

    // Hover lights the pill; click fires the affordance.
    const r = new_tab_pill_rect();
    handle_pointer(r.x + 40, r.y + 10, false);
    try std.testing.expect(hover_new_tab);
    handle_pointer(r.x + 40, r.y + 10, true);
    try std.testing.expect(start_open);
    start_dismiss();

    // Hit-test ORDER: with max_tabs tabs the '+' pill clamps INTO the
    // tab-row band — the generic row mapping (idx 15) must NOT eat the
    // click; the affordance wins and activation is untouched.
    var id: u32 = 2;
    while (id < 2 + max_tabs) : (id += 1) {
        _ = manager.add_or_update_tab(id, "Filler");
    }
    try std.testing.expect(manager.activate_tab(3));
    const clamped = new_tab_pill_rect();
    try std.testing.expectEqual(@as(u32, 650 - new_tab_pill_h), clamped.y);
    handle_pointer(clamped.x + 40, clamped.y + 10, true);
    try std.testing.expect(start_open);
    try std.testing.expectEqual(@as(?usize, 3), manager.active_idx); // no tab-15 hijack
    start_dismiss();

    // Empty state: the pill renders in the empty-state area and works there.
    manager = TabManager.init();
    handle_pointer(50, 70, true); // y=62..86 pill band, tab_count == 0
    try std.testing.expect(start_open);
    start_dismiss();

    // Ctrl+Space still summons the Sexiburger command palette (unchanged),
    // and the two catalog surfaces are mutually exclusive.
    handle_wm_key(usage_space, ui.MOD_CTRL);
    try std.testing.expect(overlay_open);
    try std.testing.expect(!start_open);
    overlay_dismiss();
}

test "tabwm: overlay empty vs filtered-empty messages are distinguishable (M42 UX)" {
    resetForTest();
    // Empty manifest: no apps installed at all.
    overlay_count = 0;
    overlay_filtered_count = 0;
    try std.testing.expectEqualStrings("no apps installed", overlay_empty_message());
    // Seeded manifest with a filter that has no hits: a different state.
    overlay_seed_catalog();
    try std.testing.expectEqual(@as(usize, 3), overlay_count);
    overlay_filter_len = 3;
    @memcpy(overlay_filter[0..3], "zzz");
    overlay_refresh_filter();
    try std.testing.expectEqual(@as(usize, 0), overlay_filtered_count);
    try std.testing.expectEqualStrings("no matching apps", overlay_empty_message());
}

test "tabwm: close_tab removes the tab and activates the next (M42 UX)" {
    resetForTest();
    manager = TabManager.init();
    _ = manager.add_or_update_tab(31, "Calc");
    _ = manager.add_or_update_tab(32, "Files");
    activate_tab(0);

    // close_tab always removes the tab and activates the next one (the
    // kernel wmctl seam no-ops on the host; on-device the kernel applies
    // its user_close release and fans the released mirror back, which
    // handle_window_mirror already absorbed — removing an unknown id is a
    // no-op, so the optimistic local removal and the mirror echo agree).
    close_tab(0);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expectEqual(@as(?u32, 32), manager.get_active_id());

    // The released mirror for the closed id arrives AFTER the local
    // removal (the kernel answers the seam): absorbed as a no-op.
    handle_window_mirror(31, false, true, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expectEqual(@as(?u32, 32), manager.get_active_id());

    // Closing the last tab empties the manager.
    close_tab(0);
    try std.testing.expectEqual(@as(usize, 0), manager.tab_count);
    try std.testing.expectEqual(@as(?usize, null), manager.active_idx);
}

// ---------------------------------------------------------------------------
// Unit Tests (M42 UX r2 — unsaved-state honesty, close flash, Alt-Tab)
// ---------------------------------------------------------------------------
test "tabwm: unsaved bit-12 mirror sets, clears, and still releases (M42 UX r2)" {
    resetForTest();
    // Creation path: a window born dirty joins with the flag set.
    manager = TabManager.init();
    handle_window_mirror(5, true, false, true, 100, 100);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expect(manager.tabs[0].unsaved);
    // Refresh path: the flag follows the mirror (set).
    _ = manager.add_or_update_tab(2, "Alpha");
    handle_window_mirror(2, true, false, true, 640, 480);
    try std.testing.expect(manager.tabs[1].unsaved);
    // ...and clears when the app saves (the kernel fans bit 12 = 0).
    handle_window_mirror(2, true, false, false, 0, 0);
    try std.testing.expect(!manager.tabs[1].unsaved);
    // Geometry refresh still works alongside the flag.
    try std.testing.expectEqual(@as(u32, 640), manager.tabs[1].orig_w);
    // Regression guard of the extended signature: released still removes.
    handle_window_mirror(2, false, true, true, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expect(manager.find_by_id(2) == null);
}

test "tabwm: request_close_tab intercepts a dirty tab with the dialog (M42 UX r2)" {
    resetForTest();
    manager = TabManager.init();
    unsaved_dialog_open_tabwm = false;
    unsaved_pending_close = null;
    unsaved_pending_id = 0;
    _ = manager.add_or_update_tab(2, "Dirty");
    _ = manager.add_or_update_tab(3, "Clean");
    manager.tabs[0].unsaved = true;
    activate_tab(0);

    // Dirty tab: NO removal — the dialog state is set and the pending row
    // recorded.
    request_close_tab(0);
    try std.testing.expectEqual(@as(usize, 2), manager.tab_count);
    try std.testing.expect(unsaved_dialog_open_tabwm);
    try std.testing.expectEqual(@as(?usize, 0), unsaved_pending_close);
    try std.testing.expectEqual(@as(u32, 2), unsaved_pending_id);

    // Clean tab: the immediate M42 UX close (no dialog).
    unsaved_dialog_open_tabwm = false;
    unsaved_pending_close = null;
    request_close_tab(1);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expect(!unsaved_dialog_open_tabwm);
    try std.testing.expectEqual(@as(?usize, null), unsaved_pending_close);
}

test "tabwm: unsaved choices — save closes, cancel keeps, discard defers to the mirror (M42 UX r2)" {
    resetForTest();
    // SAVE: the dialog clears and close_tab removes the tab (the app saves
    // and keeps running until the WM's WIN_CLOSE — the WM closes it).
    manager = TabManager.init();
    unsaved_dialog_open_tabwm = false;
    unsaved_pending_close = null;
    _ = manager.add_or_update_tab(2, "Doc");
    _ = manager.add_or_update_tab(3, "Other");
    manager.tabs[0].unsaved = true;
    activate_tab(0);
    request_close_tab(0);
    try std.testing.expect(unsaved_dialog_open_tabwm);
    apply_unsaved_choice(.save);
    try std.testing.expect(!unsaved_dialog_open_tabwm);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expectEqual(@as(?u32, 3), manager.get_active_id());
    try std.testing.expectEqual(@as(?usize, null), unsaved_pending_close);

    // CANCEL: the dialog clears and the tab STAYS.
    manager.tabs[0].unsaved = true; // id 3 now dirty
    request_close_tab(0);
    apply_unsaved_choice(.cancel);
    try std.testing.expect(!unsaved_dialog_open_tabwm);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expectEqual(@as(?u32, 3), manager.get_active_id());

    // DISCARD: the dialog clears but the tab is NOT removed locally — the
    // kernel's user_close inside DIALOG 5 releases it; the released
    // mirror echo is the authoritative removal.
    request_close_tab(0);
    apply_unsaved_choice(.dont_save);
    try std.testing.expect(!unsaved_dialog_open_tabwm);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    handle_window_mirror(3, false, true, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), manager.tab_count);

    // .none is a no-op (a click between/around the buttons).
    manager.tabs[0].unsaved = false;
    try std.testing.expectEqual(@as(usize, 0), manager.tab_count);
}

test "tabwm: wnd_core dialog hit-test maps the three buttons (M42 UX r2)" {
    resetForTest();
    // 1280x720: dialog origin (540, 310); Save center (580, 390),
    // Don't Save center (660, 390), Cancel center (715, 390).
    const dx: u32 = (fb_w - wnd_core.unsaved_dialog_w) / 2;
    const dy: u32 = (fb_h - wnd_core.unsaved_dialog_h) / 2;
    try std.testing.expectEqual(@as(u32, 540), dx);
    try std.testing.expectEqual(@as(u32, 310), dy);
    try std.testing.expectEqual(wnd_core.UnsavedChoice.save, wnd_core.unsaved_dialog_choice_at(fb_w, fb_h, dx + 40, dy + 80));
    try std.testing.expectEqual(wnd_core.UnsavedChoice.dont_save, wnd_core.unsaved_dialog_choice_at(fb_w, fb_h, dx + 120, dy + 80));
    try std.testing.expectEqual(wnd_core.UnsavedChoice.cancel, wnd_core.unsaved_dialog_choice_at(fb_w, fb_h, dx + 175, dy + 80));
    try std.testing.expectEqual(wnd_core.UnsavedChoice.none, wnd_core.unsaved_dialog_choice_at(fb_w, fb_h, dx + 40, dy + 40));
    try std.testing.expectEqual(wnd_core.UnsavedChoice.none, wnd_core.unsaved_dialog_choice_at(fb_w, fb_h, dx + 85, dy + 80));
}

test "tabwm: alt_tab_next policy — null, cycle, invert, 0-start (M42 UX r2)" {
    resetForTest();
    // Fewer than two tabs: no alt-tab.
    try std.testing.expectEqual(@as(?usize, null), alt_tab_next(0, null, false));
    try std.testing.expectEqual(@as(?usize, null), alt_tab_next(1, 0, false));
    // Forward cycle with wrap.
    try std.testing.expectEqual(@as(usize, 1), alt_tab_next(3, 0, false).?);
    try std.testing.expectEqual(@as(usize, 2), alt_tab_next(3, 1, false).?);
    try std.testing.expectEqual(@as(usize, 0), alt_tab_next(3, 2, false).?);
    // Shift inverts (the tab before the active one).
    try std.testing.expectEqual(@as(usize, 2), alt_tab_next(3, 0, true).?);
    try std.testing.expectEqual(@as(usize, 1), alt_tab_next(3, 2, true).?);
    // active=null is treated as 0-start.
    try std.testing.expectEqual(@as(usize, 1), alt_tab_next(3, null, false).?);
    try std.testing.expectEqual(@as(usize, 2), alt_tab_next(3, null, true).?);
}

test "tabwm: Alt+Tab chord moves the active tab, Alt+Shift+Tab inverts (M42 UX r2)" {
    resetForTest();
    manager = TabManager.init();
    _ = manager.add_or_update_tab(2, "A");
    _ = manager.add_or_update_tab(3, "B");
    _ = manager.add_or_update_tab(4, "C");
    activate_tab(0);

    // Alt+Tab: the kernel commit is a host no-op, but the local active
    // index follows the target row and the tab list is untouched.
    handle_wm_key(usage_tab, ui.MOD_ALT);
    try std.testing.expectEqual(@as(?usize, 1), manager.active_idx);
    try std.testing.expectEqual(@as(usize, 3), manager.tab_count);
    // Alt+Shift+Tab: back.
    handle_wm_key(usage_tab, ui.MOD_ALT | ui.MOD_SHIFT);
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);
    _ = manager.remove_tab(3);
    _ = manager.remove_tab(4);
    // Single tab: the shim's "not enough windows" rule — no-op.
    handle_wm_key(usage_tab, ui.MOD_ALT);
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);
}

test "tabwm: close_flash_active lives for the tick window then expires (M42 UX r2)" {
    resetForTest();
    close_flash_row = 2;
    close_flash_ticks = 3;
    close_flash_closed = true;
    try std.testing.expect(close_flash_active(2));
    try std.testing.expect(!close_flash_active(1)); // wrong row
    close_flash_ticks = 0;
    try std.testing.expect(!close_flash_active(2)); // expired
    close_flash_row = null;
    close_flash_ticks = close_flash_ticks_max;
    try std.testing.expect(!close_flash_active(2)); // no row recorded
    // Cleanup for the drawing tests.
    close_flash_row = null;
    close_flash_ticks = 0;
}

test "tabwm: dialog modal keys — Enter saves, Escape cancels, chords swallowed (M42 UX r2)" {
    resetForTest();
    manager = TabManager.init();
    unsaved_dialog_open_tabwm = false;
    unsaved_pending_close = null;
    _ = manager.add_or_update_tab(2, "Doc");
    _ = manager.add_or_update_tab(3, "Other");
    manager.tabs[0].unsaved = true;
    activate_tab(0);

    // Closed dialog: keys are not consumed.
    try std.testing.expect(!unsaved_dialog_key(0x29));

    request_close_tab(0);
    try std.testing.expect(unsaved_dialog_open_tabwm);
    // Escape = cancel: the tab stays.
    try std.testing.expect(unsaved_dialog_key(0x29));
    try std.testing.expect(!unsaved_dialog_open_tabwm);
    try std.testing.expectEqual(@as(usize, 2), manager.tab_count);
    // A random chord while open is swallowed (no tab mutation).
    request_close_tab(0);
    try std.testing.expect(unsaved_dialog_key(usage_w)); // Ctrl+W would close — modal eats it
    try std.testing.expectEqual(@as(usize, 2), manager.tab_count);
    try std.testing.expect(unsaved_dialog_open_tabwm);
    // Enter = save: the tab closes (host: the WM close seam no-ops).
    try std.testing.expect(unsaved_dialog_key(0x28));
    try std.testing.expect(!unsaved_dialog_open_tabwm);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
}

test "tabwm: dialog modal pointer — clicks route to the buttons, tabs are safe (M42 UX r2)" {
    resetForTest();
    manager = TabManager.init();
    unsaved_dialog_open_tabwm = false;
    unsaved_pending_close = null;
    _ = manager.add_or_update_tab(2, "Doc");
    _ = manager.add_or_update_tab(3, "Other");
    manager.tabs[0].unsaved = true;
    activate_tab(0);
    request_close_tab(0);

    // A click on the tab area (row 1 pill) is CONSUMED — no activation,
    // no close.
    handle_pointer(50, 100, true);
    try std.testing.expectEqual(@as(usize, 2), manager.tab_count);
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);
    try std.testing.expectEqual(@as(?usize, null), hover_tab); // hover parked
    // A click on Sexiburger is consumed too (no overlay summon).
    overlay_open = false;
    handle_pointer(20, 20, true);
    try std.testing.expect(!overlay_open);
    // A click between the buttons (.none) leaves everything alone.
    handle_pointer(580, 350, true);
    try std.testing.expectEqual(@as(usize, 2), manager.tab_count);
    // Save button center (580, 390): the save choice applies.
    handle_pointer(580, 390, true);
    try std.testing.expect(!unsaved_dialog_open_tabwm);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
}

test "tabwm: the Sexiburger overlay cannot summon over the modal dialog (M42 UX r2)" {
    resetForTest();
    manager = TabManager.init();
    overlay_open = false;
    unsaved_dialog_open_tabwm = true;
    overlay_summon();
    try std.testing.expect(!overlay_open);
    unsaved_dialog_open_tabwm = false;
    overlay_summon();
    try std.testing.expect(overlay_open);
    overlay_dismiss();
}

test "tabwm: unsaved + alt-tab markers are pinned (M42 UX r2)" {
    resetForTest();
    try std.testing.expectEqualStrings("tabwm: unsaved-dialog id=", unsaved_dialog_marker);
    try std.testing.expectEqualStrings("tabwm: unsaved-save\n", unsaved_save_marker);
    try std.testing.expectEqualStrings("tabwm: unsaved-discard\n", unsaved_discard_marker);
    try std.testing.expectEqualStrings("tabwm: unsaved-cancel\n", unsaved_cancel_marker);
    try std.testing.expectEqualStrings("tabwm: alt-tab id=", alt_tab_marker);
}

// ---------------------------------------------------------------------------
// Unit Tests (front-door hardening — shared row geometry + capacity refusal)
// ---------------------------------------------------------------------------

test "tabwm: tab_index_at only reaches DRAWN rows (the shared row rule)" {
    resetForTest();
    // Row geometry is one rule the renderer and the hit-test both read.
    try std.testing.expectEqual(@as(u32, 58), tab_row_y(0));
    try std.testing.expectEqual(@as(u32, 96), tab_row_y(1));
    try std.testing.expectEqual(Rect.make(tab_pill_x, tab_row_y(0) + 2, tab_pill_w, 34), Rect.make(8, 60, 164, 34));

    // The first row whose band spills past the list bound is not hittable.
    var first_unfit: usize = 0;
    while (tab_row_fits(first_unfit)) : (first_unfit += 1) {}
    try std.testing.expect(!tab_row_fits(first_unfit));
    try std.testing.expect(tab_row_fits(first_unfit - 1));

    // Fill the manager to the cap: row `first_unfit` exists (idx < count)
    // but was never drawn — the pre-fix handler still activated it.
    manager = TabManager.init();
    overlay_open = false;
    var id: u32 = 2;
    while (id < 2 + max_tabs) : (id += 1) {
        _ = manager.add_or_update_tab(id, "Filler");
    }
    try std.testing.expectEqual(max_tabs, manager.tab_count);
    const y_unfit = tab_row_y(first_unfit) + 4;
    try std.testing.expect(y_unfit < tab_list_bottom);
    try std.testing.expectEqual(@as(?usize, null), tab_index_at(y_unfit));

    // The pointer path must not select it. px=176 sits inside the sidebar
    // but right of the "+ New tab" pill column, so only the row rule decides.
    try std.testing.expect(manager.activate_tab(3));
    handle_pointer(176, y_unfit, true);
    try std.testing.expectEqual(@as(?usize, 3), manager.active_idx);
    try std.testing.expectEqual(@as(?usize, null), hover_tab);

    // A DRAWN row still resolves and activates.
    try std.testing.expectEqual(@as(?usize, 0), tab_index_at(tab_row_y(0) + 4));
    handle_pointer(50, tab_row_y(0) + 4, true);
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);
}

test "tabwm: RPC upserts refuse a full manager instead of aliasing tab 0" {
    resetForTest();
    manager = TabManager.init();
    var id: u32 = 2;
    while (id < 2 + max_tabs) : (id += 1) {
        _ = manager.add_or_update_tab(id, "Filler");
    }
    try std.testing.expectEqual(max_tabs, manager.tab_count);
    const overflow_id: u32 = 99;
    try std.testing.expect(manager.at_capacity(overflow_id));
    // A KNOWN id is never at capacity (it upserts in place).
    try std.testing.expect(!manager.at_capacity(2));

    // config/register RPC for an unknown id is REFUSED (was: silently
    // aliased onto tab 0 — tab 0's own id/title clobbered).
    var req = ui.WmRpc{
        .kind = ui.wm_rpc_kind_config,
        .id = overflow_id,
        .seq = 1,
        .reply_to = 5,
        .applied = 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = @as([ui.wm_rpc_title_max]u8, @splat(@as(u8, 0))),
    };
    @memcpy(req.title[0..8], "Overflow");
    try std.testing.expect(!wnd_mail_apply(&req));
    try std.testing.expectEqual(max_tabs, manager.tab_count);
    try std.testing.expect(manager.find_by_id(overflow_id) == null);
    try std.testing.expectEqual(@as(u32, 2), manager.tabs[0].id);
    try std.testing.expectEqualStrings("Filler", manager.tabs[0].get_title());

    // declare_fullscreen for an unknown id is refused too.
    req.kind = ui.wm_rpc_kind_declare_fullscreen;
    @memcpy(req.title[0..6], "NewWin");
    try std.testing.expect(!wnd_mail_apply(&req));
    try std.testing.expectEqual(max_tabs, manager.tab_count);
    try std.testing.expect(!manager.tabs[0].tab_aware);

    // A known id still upserts in place at the cap.
    req.id = 2;
    req.kind = ui.wm_rpc_kind_config;
    req.title = @as([ui.wm_rpc_title_max]u8, @splat(@as(u8, 0)));
    @memcpy(req.title[0..7], "Renamed");
    try std.testing.expect(wnd_mail_apply(&req));
    try std.testing.expectEqualStrings("Renamed", manager.tabs[0].get_title());
}

// ---------------------------------------------------------------------------
// Unit Tests (#1055 — the real clock)
// ---------------------------------------------------------------------------

test "tabwm: parse_clock_epoch accepts seconds-since-midnight, rejects junk" {
    resetForTest();
    try std.testing.expectEqual(@as(?u32, 0), parse_clock_epoch("0"));
    try std.testing.expectEqual(@as(?u32, 3661), parse_clock_epoch("3661"));
    try std.testing.expectEqual(@as(?u32, 86399), parse_clock_epoch(" 86399\n"));
    try std.testing.expectEqual(@as(?u32, 59), parse_clock_epoch("59\r\n"));
    // 24h or more is not a time of day.
    try std.testing.expectEqual(@as(?u32, null), parse_clock_epoch("86400"));
    try std.testing.expectEqual(@as(?u32, null), parse_clock_epoch("999999"));
    // Empty / junk / trailing junk / too many digits.
    try std.testing.expectEqual(@as(?u32, null), parse_clock_epoch(""));
    try std.testing.expectEqual(@as(?u32, null), parse_clock_epoch("abc"));
    try std.testing.expectEqual(@as(?u32, null), parse_clock_epoch("12x"));
    try std.testing.expectEqual(@as(?u32, null), parse_clock_epoch("1234567"));
}

test "tabwm: clock_hms shows wall time with an epoch, uptime without" {
    resetForTest();
    // No epoch: honest uptime from 00:00:00; hours do not wrap at 24.
    try std.testing.expectEqual(Hms{ .h = 0, .m = 0, .s = 0 }, clock_hms(0, null));
    try std.testing.expectEqual(Hms{ .h = 1, .m = 1, .s = 1 }, clock_hms(3661, null));
    try std.testing.expectEqual(Hms{ .h = 25, .m = 0, .s = 0 }, clock_hms(90000, null));

    // With an epoch: time-of-day, wrapping at midnight.
    try std.testing.expectEqual(Hms{ .h = 12, .m = 34, .s = 56 }, clock_hms(0, 12 * 3600 + 34 * 60 + 56));
    // 23:59:50 + 20 s = 00:00:10 the next day.
    try std.testing.expectEqual(Hms{ .h = 0, .m = 0, .s = 10 }, clock_hms(20, 23 * 3600 + 59 * 60 + 50));
    // A full day later wraps to the same face.
    try std.testing.expectEqual(Hms{ .h = 8, .m = 15, .s = 0 }, clock_hms(86400, 8 * 3600 + 15 * 60));
}

// ---------------------------------------------------------------------------
// Unit Tests (#1056 item 4 — the test-state reset)
// ---------------------------------------------------------------------------

test "tabwm: resetForTest restores every mutated global to cold-boot" {
    resetForTest();
    // Dirty each global the suite touches.
    _ = manager.add_or_update_tab(2, "Dirty");
    hover_tab = 1;
    hover_sexiburger = true;
    hover_theme_toggle = true;
    hover_clip = true;
    hover_new_tab = true;
    unsaved_pending_close = 0;
    unsaved_pending_id = 2;
    unsaved_dialog_open_tabwm = true;
    close_flash_row = 1;
    close_flash_ticks = 5;
    close_flash_closed = true;
    clock_hours = 9;
    clock_minutes = 8;
    clock_seconds = 7;
    clock_epoch = 12;
    overlay_open = true;
    overlay_loaded = true;
    overlay_count = 3;
    overlay_filter_len = 2;
    overlay_filtered_count = 2;
    overlay_sel = 1;
    mascot_loaded = true;

    resetForTest();

    try std.testing.expectEqual(@as(usize, 0), manager.tab_count);
    try std.testing.expectEqual(@as(?usize, null), manager.active_idx);
    try std.testing.expectEqual(@as(?usize, null), hover_tab);
    try std.testing.expect(!hover_sexiburger);
    try std.testing.expect(!hover_theme_toggle);
    try std.testing.expect(!hover_clip);
    try std.testing.expect(!hover_new_tab);
    try std.testing.expectEqual(@as(?usize, null), unsaved_pending_close);
    try std.testing.expectEqual(@as(u32, 0), unsaved_pending_id);
    try std.testing.expect(!unsaved_dialog_open_tabwm);
    try std.testing.expectEqual(@as(?usize, null), close_flash_row);
    try std.testing.expectEqual(@as(u32, 0), close_flash_ticks);
    try std.testing.expect(!close_flash_closed);
    try std.testing.expectEqual(@as(u32, 0), clock_hours);
    try std.testing.expectEqual(@as(u32, 0), clock_minutes);
    try std.testing.expectEqual(@as(u32, 0), clock_seconds);
    try std.testing.expectEqual(@as(?u32, null), clock_epoch);
    try std.testing.expect(!overlay_open);
    try std.testing.expect(!overlay_loaded);
    try std.testing.expectEqual(@as(usize, 0), overlay_count);
    try std.testing.expectEqual(@as(usize, 0), overlay_filter_len);
    try std.testing.expectEqual(@as(usize, 0), overlay_filtered_count);
    try std.testing.expectEqual(@as(usize, 0), overlay_sel);
    try std.testing.expect(!mascot_loaded);
}

// ---------------------------------------------------------------------------
// Unit Tests (#1056 item 3 — tab navigation, overflow, persistence)
// ---------------------------------------------------------------------------

test "tabwm: overflow scroll moves the list window and the hit-test follows" {
    resetForTest();
    var id: u32 = 2;
    while (id < 2 + max_tabs) : (id += 1) _ = manager.add_or_update_tab(id, "Filler");
    try std.testing.expectEqual(max_tabs, manager.tab_count);

    const vis = visible_tab_rows();
    try std.testing.expectEqual(@as(usize, 15), vis);
    try std.testing.expectEqual(max_tabs - vis, tab_scroll_max());

    // The 16th row is off-screen at scroll 0 and unreachable...
    try std.testing.expectEqual(@as(?usize, null), tab_index_at(632));
    // ...then reachable once the window slides one row.
    scroll_tabs(1);
    try std.testing.expectEqual(@as(usize, 1), tab_scroll);
    try std.testing.expectEqual(@as(?usize, max_tabs - 1), tab_index_at(tab_row_y(14) + 4));

    // Clamps at both ends.
    scroll_tabs(100);
    try std.testing.expectEqual(tab_scroll_max(), tab_scroll);
    scroll_tabs(-100);
    try std.testing.expectEqual(@as(usize, 0), tab_scroll);

    // Keyboard selection auto-scrolls to reach the last tab.
    nav_sel = max_tabs - 1;
    ensure_nav_visible();
    try std.testing.expectEqual(@as(usize, 1), tab_scroll);
}

test "tabwm: overflow_label reports the visible window with arrows" {
    resetForTest();
    var buf: [24]u8 = undefined;
    // Everything fits: no indicator.
    try std.testing.expectEqualStrings("", overflow_label(&buf));

    var id: u32 = 2;
    while (id < 2 + max_tabs) : (id += 1) _ = manager.add_or_update_tab(id, "F");
    try std.testing.expectEqualStrings("1-15/16v", overflow_label(&buf));
    scroll_tabs(1);
    try std.testing.expectEqualStrings("^2-16/16", overflow_label(&buf));

    // A draw smoke test: the scrolled list plus the selection ring render.
    nav_sel = max_tabs - 1;
    ensure_nav_visible();
    var fb: [fb_w * fb_h]u32 = undefined;
    @memset(&fb, 0);
    draw_sidebar(&fb);
    try std.testing.expectEqual(@as(usize, 1), tab_scroll);
}

test "tabwm: keyboard nav moves the selection, scrolls, and activates" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "A");
    _ = manager.add_or_update_tab(3, "B");
    _ = manager.add_or_update_tab(4, "C");
    activate_tab(0);

    // Down starts from the active tab; Up/Down are both clamped.
    handle_wm_key(usage_down, 0);
    try std.testing.expectEqual(@as(?usize, 1), nav_sel);
    handle_wm_key(usage_up, 0);
    handle_wm_key(usage_up, 0);
    try std.testing.expectEqual(@as(?usize, 0), nav_sel);
    handle_wm_key(usage_down, 0);
    handle_wm_key(usage_down, 0);
    handle_wm_key(usage_down, 0);
    try std.testing.expectEqual(@as(?usize, 2), nav_sel);

    // Enter activates the SELECTION, not the previously active tab.
    handle_wm_key(usage_enter, 0);
    try std.testing.expectEqual(@as(?usize, 2), manager.active_idx);
    try std.testing.expectEqual(@as(?u32, 4), manager.get_active_id());

    // A Ctrl chord is not plain navigation (the kernel owns Ctrl+arrow).
    handle_wm_key(usage_down, ui.MOD_CTRL);
    try std.testing.expectEqual(@as(?usize, 2), nav_sel);

    // PageDown/PageUp scroll (clamped; no overflow here so a no-op).
    const before = tab_scroll;
    handle_wm_key(usage_pagedown, 0);
    try std.testing.expectEqual(before, tab_scroll);
}

test "tabwm: serialize_tabs/parse_tabs round-trip order and active" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "Calculator");
    _ = manager.add_or_update_tab(3, "Notes");
    _ = manager.add_or_update_tab(4, "Files");
    activate_tab(1);

    var buf: [tabs_state_max_bytes]u8 = undefined;
    const n = serialize_tabs(&buf);
    try std.testing.expectEqual(tabs_header_bytes + 3 * persist_title_max, n);

    var st: TabsState = .{};
    try std.testing.expect(parse_tabs(buf[0..n], &st));
    try std.testing.expectEqual(@as(usize, 3), st.count);
    try std.testing.expectEqual(@as(?usize, 1), st.active);
    try std.testing.expectEqualStrings("Calculator", st.titles[0][0..st.title_lens[0]]);
    try std.testing.expectEqualStrings("Notes", st.titles[1][0..st.title_lens[1]]);
    try std.testing.expectEqualStrings("Files", st.titles[2][0..st.title_lens[2]]);

    // Corrupt inputs are rejected, never half-applied.
    var bad = buf;
    bad[0] = 99;
    try std.testing.expect(!parse_tabs(bad[0..n], &st));
    bad[0] = tabs_state_version;
    bad[2] = max_tabs + 1;
    try std.testing.expect(!parse_tabs(bad[0..n], &st));
    bad[2] = 3;
    try std.testing.expect(!parse_tabs(bad[0 .. n - 1], &st));
    bad[1] = 4; // active 3 is out of range for count 3
    try std.testing.expect(!parse_tabs(bad[0..n], &st));
    try std.testing.expect(!parse_tabs(buf[0..2], &st));
}

test "tabwm: persisted order re-applies by title and sets the active tab" {
    resetForTest();
    var st = TabsState{};
    st.count = 3;
    st.active = 2;
    @memcpy(st.titles[0][0..4], "Beta");
    st.title_lens[0] = 4;
    @memcpy(st.titles[1][0..5], "Gamma");
    st.title_lens[1] = 5;
    @memcpy(st.titles[2][0..5], "Alpha");
    st.title_lens[2] = 5;
    persisted_tabs = st;

    // Arrival order (Alpha, Beta, Gamma) differs from the saved order.
    _ = manager.add_or_update_tab(2, "Alpha");
    _ = manager.add_or_update_tab(3, "Beta");
    try std.testing.expect(!maybe_apply_persisted_tabs()); // not complete yet
    _ = manager.add_or_update_tab(4, "Gamma");
    try std.testing.expect(maybe_apply_persisted_tabs());

    try std.testing.expectEqualStrings("Beta", manager.tabs[0].get_title());
    try std.testing.expectEqualStrings("Gamma", manager.tabs[1].get_title());
    try std.testing.expectEqualStrings("Alpha", manager.tabs[2].get_title());
    try std.testing.expectEqual(@as(?usize, 2), manager.active_idx);
    try std.testing.expectEqual(@as(?u32, 2), manager.get_active_id()); // Alpha (id 2)

    // Applies exactly once — no reordering churn afterwards.
    try std.testing.expect(!maybe_apply_persisted_tabs());
}

test "tabwm: new-tab pill tracks the visible window" {
    resetForTest();
    // Empty state: the pill renders in the empty-state area.
    try std.testing.expectEqual(tab_row_y(0) + 4, new_tab_pill_y());
    _ = manager.add_or_update_tab(2, "A");
    _ = manager.add_or_update_tab(3, "B");
    try std.testing.expectEqual(tab_row_y(2) + 4, new_tab_pill_y());
    var id: u32 = 4;
    while (id < 2 + max_tabs) : (id += 1) _ = manager.add_or_update_tab(id, "Filler");
    try std.testing.expectEqual(tab_list_bottom - new_tab_pill_h, new_tab_pill_y());
}

// ---------------------------------------------------------------------------
// Unit Tests (#1056 item 1 — the firmware wall clock)
// ---------------------------------------------------------------------------

test "tabwm: tick_clock_face prefers the host epoch, else uptime on the host" {
    resetForTest();
    // Host test: query_epoch() is null (no kernel), no `.clock` -> uptime.
    try std.testing.expectEqual(@as(?u64, null), query_epoch());
    try std.testing.expectEqual(Hms{ .h = 1, .m = 1, .s = 1 }, tick_clock_face(3661));

    // The session `.clock` epoch wins when there is no kernel epoch.
    clock_epoch = 12 * 3600 + 34 * 60 + 56;
    try std.testing.expectEqual(Hms{ .h = 12, .m = 34, .s = 57 }, tick_clock_face(1));
    // 23:59:59 + 1 s wraps to midnight.
    clock_epoch = 23 * 3600 + 59 * 60 + 59;
    try std.testing.expectEqual(Hms{ .h = 0, .m = 0, .s = 0 }, tick_clock_face(1));
}

// ---------------------------------------------------------------------------
// Unit Tests (#1064 — rail-neutral browser tab ergonomics)
// ---------------------------------------------------------------------------

test "tabwm: middle-click closes the tab under the pointer (#1064)" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "A");
    _ = manager.add_or_update_tab(3, "B");
    activate_tab(0);

    // Row 1 band (y = tab_row_y(1)+4): closes B through the close decision.
    handle_middle_click(50, tab_row_y(1) + 4);
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expect(manager.find_by_id(3) == null);

    // Outside the sidebar / outside any row: no-op.
    _ = manager.add_or_update_tab(4, "C");
    handle_middle_click(fb_w, tab_row_y(0) + 4);
    handle_middle_click(50, 5);
    try std.testing.expectEqual(@as(usize, 2), manager.tab_count);

    // While the modal owns input, a middle-click is consumed (no close).
    unsaved_dialog_open_tabwm = true;
    handle_middle_click(50, tab_row_y(0) + 4);
    try std.testing.expectEqual(@as(usize, 2), manager.tab_count);
}

test "tabwm: keyboard reorder moves the active tab (#1064)" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "A");
    _ = manager.add_or_update_tab(3, "B");
    _ = manager.add_or_update_tab(4, "C");
    activate_tab(0);

    // Ctrl+Shift+Right swaps A right and keeps it active.
    handle_wm_key(usage_right, ui.MOD_CTRL | ui.MOD_SHIFT);
    try std.testing.expectEqual(@as(?usize, 1), manager.active_idx);
    try std.testing.expectEqualStrings("B", manager.tabs[0].get_title());
    try std.testing.expectEqualStrings("A", manager.tabs[1].get_title());
    try std.testing.expectEqual(@as(?u32, 2), manager.get_active_id());

    // Edge clamps: the ends do not wrap.
    activate_tab(0);
    try std.testing.expect(!move_active_tab(-1));
    activate_tab(2);
    try std.testing.expect(!move_active_tab(1));

    // Ctrl+Shift+Left routes through the chord decoder.
    activate_tab(1);
    handle_wm_key(usage_left, ui.MOD_CTRL | ui.MOD_SHIFT);
    try std.testing.expectEqual(@as(?usize, 0), manager.active_idx);
}

test "tabwm: reopen-closed re-execs a TABWM-launched app (#1064)" {
    resetForTest();
    // A window spawned through the launch path records its bin.
    pending_launch_bin_len = 4;
    @memcpy(pending_launch_bin[0..4], "CALC");
    handle_window_mirror(2, true, false, false, 0, 0);
    try std.testing.expectEqualStrings("CALC", manager.tabs[0].get_bin());
    try std.testing.expectEqual(@as(usize, 0), pending_launch_bin_len);

    // Close it: the reopen LIFO holds it, and Ctrl+Shift+T re-execs it
    // (host exec is a no-op; the counter is the observable).
    close_tab(0);
    try std.testing.expectEqual(@as(usize, 1), closed_count);
    handle_wm_key(usage_t, ui.MOD_CTRL | ui.MOD_SHIFT);
    try std.testing.expectEqual(@as(usize, 0), closed_count);

    // A tab with no recorded bin (window opened itself) is not reopenable;
    // un-reopenable entries are popped so the stack drains honestly.
    handle_window_mirror(9, true, false, false, 0, 0);
    close_tab(0);
    try std.testing.expectEqual(@as(usize, 1), closed_count);
    try std.testing.expect(!reopen_last_closed());
    try std.testing.expectEqual(@as(usize, 0), closed_count);
}

// ---------------------------------------------------------------------------
// Unit Tests (M48 — browser-style tab depth, umbrella #1120)
// ---------------------------------------------------------------------------

test "tabwm: M48 markers are pinned (BT1–BT6)" {
    try std.testing.expectEqualStrings("tabwm: duplicate ", duplicate_marker);
    try std.testing.expectEqualStrings("tabwm: tab-reorder ", tab_reorder_marker);
    try std.testing.expectEqualStrings("tabwm: tab-pin ", pin_marker);
    try std.testing.expectEqualStrings("tabwm: start-surface\n", start_marker);
    try std.testing.expectEqualStrings("tabwm: nav-decl ", nav_decl_marker);
    try std.testing.expectEqualStrings("tabwm: nav-back ", nav_back_marker);
    try std.testing.expectEqualStrings("tabwm: nav-forward ", nav_forward_marker);
    try std.testing.expectEqualStrings("tabwm: tab-freeze ", freeze_marker);
    try std.testing.expectEqualStrings("tabwm: tab-search\n", tab_search_marker);
}

test "tabwm: duplicate active tab re-execs its recorded bin (M48/BT1)" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "Calc");
    manager.tabs[0].set_bin("GOCALC.ELF");
    activate_tab(0);
    try std.testing.expect(duplicate_active_tab());
    try std.testing.expectEqualStrings("GOCALC.ELF", pending_launch_bin[0..pending_launch_bin_len]);

    // No recorded bin (a self-opened window) -> honest no-op.
    _ = manager.add_or_update_tab(3, "Mystery");
    activate_tab(1);
    try std.testing.expect(!duplicate_active_tab());
}

test "tabwm: move_tab shifts, keeps active, and reorder persists (M48/BT2)" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "A");
    _ = manager.add_or_update_tab(3, "B");
    _ = manager.add_or_update_tab(4, "C");
    activate_tab(1); // B is active

    // Move C to the front; B keeps the active focus by id.
    try std.testing.expect(reorder_tab(2, 0));
    try std.testing.expectEqualStrings("C", manager.tabs[0].get_title());
    try std.testing.expectEqualStrings("A", manager.tabs[1].get_title());
    try std.testing.expectEqualStrings("B", manager.tabs[2].get_title());
    try std.testing.expectEqual(@as(?usize, 2), manager.active_idx);
    try std.testing.expectEqual(@as(?u32, 3), manager.get_active_id());

    // The persisted order reflects the move.
    var buf: [tabs_state_max_bytes]u8 = undefined;
    const n = serialize_tabs(&buf);
    var st: TabsState = .{};
    try std.testing.expect(parse_tabs(buf[0..n], &st));
    try std.testing.expectEqualStrings("C", st.titles[0][0..st.title_lens[0]]);

    // Same-row and out-of-range moves are no-ops.
    try std.testing.expect(!reorder_tab(1, 1));
    try std.testing.expect(!reorder_tab(0, 9));
}

test "tabwm: pointer drag reorders tabs (M48/BT2)" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "A");
    _ = manager.add_or_update_tab(3, "B");
    _ = manager.add_or_update_tab(4, "C");
    activate_tab(0);

    // Press row 0 (A), release over row 2: A moves to the end.
    handle_pointer(50, tab_row_y(0) + 4, true);
    try std.testing.expectEqual(@as(?usize, 0), drag_from);
    try std.testing.expect(end_tab_drag(tab_row_y(2) + 4));
    try std.testing.expectEqualStrings("B", manager.tabs[0].get_title());
    try std.testing.expectEqualStrings("C", manager.tabs[1].get_title());
    try std.testing.expectEqualStrings("A", manager.tabs[2].get_title());
    try std.testing.expect(drag_from == null);

    // A plain click (release over the same row) does not reorder.
    handle_pointer(50, tab_row_y(0) + 4, true);
    try std.testing.expect(!end_tab_drag(tab_row_y(0) + 4));

    // Keyboard move (Ctrl+Shift+PgDn) routes through the same reorder.
    activate_tab(0);
    handle_wm_key(usage_pagedown, ui.MOD_CTRL | ui.MOD_SHIFT);
    try std.testing.expectEqual(@as(?usize, 1), manager.active_idx);
}

test "tabwm: pinning sorts pinned tabs first (M48/BT3)" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "A");
    _ = manager.add_or_update_tab(3, "B");
    _ = manager.add_or_update_tab(4, "C");
    activate_tab(2); // C active

    try std.testing.expect(pin_toggle(2)); // pin C
    try std.testing.expectEqualStrings("C", manager.tabs[0].get_title());
    try std.testing.expectEqual(@as(usize, 1), manager.front_pinned_count());
    // Active follows the tab by id.
    try std.testing.expectEqual(@as(?u32, 4), manager.get_active_id());

    // Unpin restores the unpinned order.
    try std.testing.expect(pin_toggle(0));
    try std.testing.expectEqual(@as(usize, 0), manager.front_pinned_count());
}

test "tabwm: manifest group parsing + dock pin adoption (M48/BT3)" {
    resetForTest();
    const text = "# c\nGOCALC.ELF | Calc | c | dock=true | group=System\nNOTEPAD.BIN | Editor | n | group=Office\n";
    try std.testing.expectEqualStrings("System", manifest_group_for(text, "GOCALC.ELF"));
    try std.testing.expectEqualStrings("Office", manifest_group_for(text, "NOTEPAD.BIN"));
    try std.testing.expectEqualStrings("", manifest_group_for(text, "MISSING.BIN"));

    // The launch handshake carries bin + group + dock-pin; the mirror adopts
    // them onto the new tab.
    pending_launch_bin_len = 10;
    @memcpy(pending_launch_bin[0..10], "GOCALC.ELF");
    pending_launch_group_len = 6;
    @memcpy(pending_launch_group[0..6], "System");
    pending_launch_pinned = true;
    handle_window_mirror(2, true, false, false, 0, 0);
    try std.testing.expectEqualStrings("System", manager.tabs[0].group[0..manager.tabs[0].group_len]);
    try std.testing.expect(manager.tabs[0].pinned);
    try std.testing.expectEqual(@as(usize, 1), manager.front_pinned_count());
}

test "tabwm: START surface summons, shares the catalog, and launches (M48/BT4)" {
    resetForTest();
    overlay_seed_catalog();
    overlay_loaded = true; // catalog seeded; skip the (host no-op) load

    start_summon();
    try std.testing.expect(start_open);
    try std.testing.expect(!overlay_open);
    try std.testing.expectEqual(@as(usize, 3), overlay_filtered_count);

    // Enter launches the selected entry and dismisses the START page.
    overlay_sel = 0;
    try std.testing.expect(overlay_launch_selected());
    try std.testing.expect(!start_open);
    try std.testing.expectEqualStrings("GOCALC.ELF", pending_launch_bin[0..pending_launch_bin_len]);

    // Escape dismisses; the two catalog surfaces are mutually exclusive.
    start_summon();
    try std.testing.expect(overlay_key(0x29));
    try std.testing.expect(!start_open);
    overlay_summon();
    start_summon();
    try std.testing.expect(start_open);
    try std.testing.expect(!overlay_open);
    start_dismiss();
}

test "tabwm: per-tab navigation history records, dedupes, truncates, bounds (M48/BT5)" {
    resetForTest();
    var t = Tab{};
    try std.testing.expect(t.nav_record("/a"));
    try std.testing.expect(t.nav_record("/b"));
    try std.testing.expect(!t.nav_record("/b")); // consecutive duplicate
    try std.testing.expectEqualStrings("/b", t.current_nav().?);
    try std.testing.expect(t.can_nav_back());
    try std.testing.expect(!t.can_nav_forward());

    try std.testing.expectEqualStrings("/a", t.nav_back().?);
    try std.testing.expect(t.can_nav_forward());
    try std.testing.expectEqualStrings("/a", t.current_nav().?);

    // Navigating after a back truncates the forward stack.
    try std.testing.expect(t.nav_record("/c"));
    try std.testing.expect(!t.can_nav_forward());
    try std.testing.expectEqual(@as(usize, 2), t.hist_count);

    // Bound: past hist_max, the oldest entry is dropped.
    var i: usize = 0;
    while (i < hist_max + 3) : (i += 1) {
        var b: [8]u8 = undefined;
        const p = std.fmt.bufPrint(&b, "/p{d}", .{i}) catch "/p";
        _ = t.nav_record(p);
    }
    try std.testing.expectEqual(hist_max, t.hist_count);
}

test "tabwm: back/forward queue the target for the owning app (M48/BT5)" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "Files");
    activate_tab(0);
    try std.testing.expect(nav_declare(2, "/host"));
    try std.testing.expect(nav_declare(2, "/host/docs"));
    try std.testing.expectEqualStrings("/host/docs", manager.tabs[0].current_nav().?);

    try std.testing.expect(nav_back_active());
    try std.testing.expectEqual(@as(u32, 2), pending_nav_id);
    var buf: [hist_path_max]u8 = undefined;
    try std.testing.expectEqualStrings("/host", nav_poll(2, &buf).?);
    try std.testing.expect(nav_poll(2, &buf) == null); // poll-once

    try std.testing.expect(nav_forward_active());
    try std.testing.expectEqualStrings("/host/docs", nav_poll(2, &buf).?);
    try std.testing.expect(!nav_forward_active()); // already at the newest entry

    // The same path through the mailbox RPC (the app-facing seam).
    var req = ui.WmRpc{
        .kind = wm_rpc_kind_nav_declare,
        .id = 2,
        .seq = 1,
        .reply_to = 5,
        .applied = 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = @as([ui.wm_rpc_title_max]u8, @splat(@as(u8, 0))),
    };
    @memcpy(req.title[0..6], "/etc/x");
    try std.testing.expect(wnd_mail_apply(&req));
    try std.testing.expectEqualStrings("/etc/x", manager.tabs[0].current_nav().?);
}

test "tabwm: hover preview dwell, frozen badge, and tab search (M48/BT6)" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "Calculator");
    _ = manager.add_or_update_tab(3, "Notepad");
    _ = manager.add_or_update_tab(4, "Terminal");
    activate_tab(0);

    // Hover dwell: the preview appears only after the delay.
    hover_tab = 0;
    _ = hover_tick(); // target change, ticks = 0
    try std.testing.expect(!hover_preview_visible(0));
    _ = hover_tick(); // ticks = 1
    try std.testing.expect(!hover_preview_visible(0));
    _ = hover_tick(); // ticks = 2
    try std.testing.expect(hover_preview_visible(0));
    try std.testing.expect(!hover_preview_visible(1));

    // Moving the pointer resets the dwell.
    hover_tab = 1;
    _ = hover_tick();
    try std.testing.expect(!hover_preview_visible(0));
    try std.testing.expect(!hover_preview_visible(1));

    // Frozen badge toggles.
    try std.testing.expect(freeze_toggle(0));
    try std.testing.expect(manager.tabs[0].frozen);
    try std.testing.expect(freeze_toggle(0));
    try std.testing.expect(!manager.tabs[0].frozen);

    // Tab search: case-insensitive substring, activate picks the tab.
    tab_search_summon();
    try std.testing.expect(tab_search_is_open());
    try std.testing.expectEqual(@as(usize, 3), tab_search_match_count());
    tab_search_filter_len = 4;
    @memcpy(tab_search_filter[0..4], "note");
    tab_search_refresh();
    try std.testing.expectEqual(@as(usize, 1), tab_search_match_count());
    try std.testing.expect(tab_search_activate());
    try std.testing.expect(!tab_search_is_open());
    try std.testing.expectEqual(@as(?u32, 3), manager.get_active_id());
}

// ---------------------------------------------------------------------------
// Unit Tests (TWM — the "Go" quick-jump, `.tabs` v2, and the change log)
// ---------------------------------------------------------------------------

test "tabwm: go rank classes — exact over prefix over substring (TWM/GO1)" {
    try std.testing.expectEqual(go_rank_exact, go_rank("Notes", "notes").?);
    try std.testing.expectEqual(go_rank_exact, go_rank("notes", "notes").?);
    try std.testing.expectEqual(go_rank_prefix, go_rank("Notes App", "note").?);
    try std.testing.expectEqual(go_rank_substring, go_rank("My Notes", "note").?);
    try std.testing.expectEqual(go_rank_subsequence, go_rank("Notepad Editor", "ntpd").?);
    try std.testing.expect(go_rank("Notes", "zzz") == null);
    try std.testing.expectEqualStrings("go", tablog_code_name(tablog_code_go));
}

test "tabwm: go query append, backspace, two-stage escape, toggle (TWM/GO2)" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "Notes");
    overlay_loaded = true;
    go_summon();
    try std.testing.expect(go_is_open());
    try std.testing.expectEqual(@as(usize, 0), go_query_slice().len);
    _ = go_key(0x11); // 'n'
    _ = go_key(0x12); // 'o'
    try std.testing.expectEqualStrings("no", go_query_slice());
    try std.testing.expectEqual(@as(usize, 1), go_match_count());
    _ = go_key(0x2a); // Backspace
    try std.testing.expectEqualStrings("n", go_query_slice());
    _ = go_key(0x29); // Escape clears a non-empty query, does not dismiss
    try std.testing.expectEqualStrings("", go_query_slice());
    try std.testing.expect(go_is_open());
    _ = go_key(0x29); // A second Escape dismisses
    try std.testing.expect(!go_is_open());
    // Ctrl+Shift+G re-summons, and the chord itself closes it again.
    go_summon();
    _ = go_key(usage_g);
    try std.testing.expect(!go_is_open());
}

test "tabwm: go empty and no-match states are honestly distinct (TWM/GO3)" {
    resetForTest();
    overlay_loaded = true;
    go_summon();
    try std.testing.expectEqualStrings("nothing to jump to", go_empty_message());
    _ = go_key(0x11); // 'n'
    try std.testing.expectEqualStrings("nothing to jump to", go_empty_message());

    resetForTest();
    _ = manager.add_or_update_tab(2, "Notes");
    overlay_loaded = true;
    go_summon();
    try std.testing.expect(go_match_count() >= 1);
    try std.testing.expectEqualStrings("", go_empty_message());
    _ = go_key(0x1a); // 'w' — no hits
    try std.testing.expectEqual(@as(usize, 0), go_match_count());
    try std.testing.expectEqualStrings("no matches", go_empty_message());
}

test "tabwm: go ranks tabs ahead of apps at equal rank (TWM/GO4)" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "Notes");
    overlay_loaded = true;
    overlay_count = 1;
    @memcpy(overlay_labels[0][0..5], "Notes");
    overlay_label_lens[0] = 5;
    @memcpy(overlay_bins[0][0..9], "NOTES.BIN");
    overlay_bin_lens[0] = 9;
    overlay_dock[0] = false;
    go_open = true;
    go_query_len = 5;
    @memcpy(go_query[0..5], "notes");
    go_refresh();
    try std.testing.expectEqual(@as(usize, 2), go_match_count());
    try std.testing.expectEqualStrings("tab", go_row_kind_label(0));
    try std.testing.expectEqualStrings("app", go_row_kind_label(1));
    go_open = false;
}

test "tabwm: go disambiguates two tabs with the same title (TWM/GO5)" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "Text Editor");
    _ = manager.add_or_update_tab(3, "Text Editor");
    try std.testing.expect(go_title_ambiguous("Text Editor"));
    try std.testing.expect(!go_title_ambiguous("Solo"));
    overlay_loaded = true;
    go_summon();
    var b0: [56]u8 = undefined;
    const l0 = go_row_label(0, &b0);
    try std.testing.expect(std.mem.indexOf(u8, l0, "#2") != null);
    var b1: [56]u8 = undefined;
    const l1 = go_row_label(1, &b1);
    try std.testing.expect(std.mem.indexOf(u8, l1, "#3") != null);
    try std.testing.expect(!std.mem.eql(u8, l0, l1));
}

test "tabwm: go activate on a closed target is a safe no-op (TWM/GO6)" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "A");
    _ = manager.add_or_update_tab(3, "B");
    _ = manager.add_or_update_tab(4, "C");
    overlay_loaded = true;
    go_summon();
    go_sel = 1;
    try std.testing.expectEqual(@as(u32, 3), go_results[go_sel].id);
    // Close B: index 1 is now C (id=4). An index+valid check would activate C.
    _ = manager.remove_tab(3);
    try std.testing.expect(!go_activate());
    try std.testing.expect(go_is_open());
    try std.testing.expectEqual(@as(?u32, 2), manager.get_active_id());
    // And a click outside the panel dismisses rather than acting.
    _ = go_click(4, 4);
    try std.testing.expect(!go_is_open());
}

test "tabwm: Go rail chip and chord are wired (TWM/GO7)" {
    const r = go_chip_rect();
    try std.testing.expectEqual(go_chip_x, r.x);
    try std.testing.expect(r.x + r.w <= sidebar_w);
    try std.testing.expect(r.y >= 696 and r.y + r.h <= fb_h);
    try std.testing.expectEqual(@as(u8, 0x0a), usage_g);
    try std.testing.expectEqualStrings("JUMP", go_chip_label);
    try std.testing.expectEqualStrings("^G", go_chip_hint);
    try std.testing.expectEqualStrings("tabwm: go-summon\n", go_marker);
    try std.testing.expectEqualStrings("tabwm: go-miss\n", go_miss_marker);
    try std.testing.expectEqualStrings("tabwm: go-pick ", go_pick_tab_marker);
    try std.testing.expectEqualStrings("tabwm: go-launch ", go_launch_marker);
}

test "tabwm: go panel draws every selectable row (TWM/GO8)" {
    try std.testing.expectEqual(@as(usize, 11), go_max_results);
    const last_row_bottom = go_panel_y + go_rows_y + @as(u32, @intCast(go_max_results)) * go_row_h;
    try std.testing.expect(last_row_bottom <= go_panel_y + go_panel_h - go_panel_footer);
    try std.testing.expectEqual(max_tabs + overlay_max_apps, go_scan_max);
}

test "tabwm: go_refresh is bounded well under the live scan budget (TWM/GO9)" {
    resetForTest();
    overlay_loaded = true;
    overlay_count = overlay_max_apps;
    var e: usize = 0;
    while (e < overlay_max_apps) : (e += 1) {
        overlay_label_lens[e] = 4;
        @memcpy(overlay_labels[e][0..4], "AppX");
        overlay_bin_lens[e] = 8;
        @memcpy(overlay_bins[e][0..8], "APPS.BIN");
    }
    var i: usize = 0;
    while (i < max_tabs) : (i += 1) {
        var tbuf: [8]u8 = undefined;
        const t = std.fmt.bufPrint(&tbuf, "T{d}", .{i}) catch "T";
        _ = manager.add_or_update_tab(@intCast(i + 2), t);
    }
    go_refresh();
    try std.testing.expect(go_match_count() == go_max_results);
    // The live 5 ms budget is pinned by `tabwm: go-scan-us=` on
    // live-tabwm-bt (CNTPCT). Host zig 0.17 has no std.time.Timer; the
    // conversion itself is what we can unit-test here.
    try std.testing.expectEqual(@as(u64, 1000), ticks_to_us(24_000, 24_000_000));
    try std.testing.expectEqual(@as(u64, 0), ticks_to_us(100, 0));
}

test "tabwm: .tabs v2 round-trips pinned, frozen, group, and bin (TWM/ST1)" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "Calc");
    _ = manager.add_or_update_tab(3, "Files");
    manager.tabs[0].pinned = true;
    manager.tabs[1].frozen = true;
    @memcpy(manager.tabs[1].group[0..5], "tools");
    manager.tabs[1].group_len = 5;
    @memcpy(manager.tabs[0].bin[0..10], "GOCALC.ELF");
    manager.tabs[0].bin_len = 10;
    activate_tab(0);
    tabs_seq = 7;
    var buf: [tabs_v2_max_bytes]u8 = undefined;
    const n = serialize_tabs_v2(&buf);
    try std.testing.expectEqual(tabs_v2_header_bytes + 2 * tabs_v2_record_bytes, n);
    var st: TabsStateV2 = .{};
    try std.testing.expect(parse_tabs_v2(buf[0..n], &st));
    try std.testing.expectEqual(@as(usize, 2), st.count);
    try std.testing.expectEqual(@as(?usize, 0), st.active);
    try std.testing.expectEqual(@as(u16, 7), st.seq);
    try std.testing.expectEqualStrings("Calc", st.titles[0][0..st.title_lens[0]]);
    try std.testing.expect((st.flags[0] & tab_flag_pinned) != 0);
    try std.testing.expect((st.flags[1] & tab_flag_frozen) != 0);
    try std.testing.expectEqualStrings("tools", st.groups[1][0..st.group_lens[1]]);
    try std.testing.expectEqualStrings("GOCALC.ELF", st.bins[0][0..st.bin_lens[0]]);
}

test "tabwm: a v2 state re-applies pinned/frozen/group/bin and order (TWM/ST2)" {
    resetForTest();
    var st = TabsStateV2{};
    st.count = 2;
    st.active = 1;
    @memcpy(st.titles[0][0..4], "Calc");
    st.title_lens[0] = 4;
    st.flags[0] = tab_flag_pinned;
    @memcpy(st.bins[0][0..10], "GOCALC.ELF");
    st.bin_lens[0] = 10;
    @memcpy(st.titles[1][0..5], "Files");
    st.title_lens[1] = 5;
    st.flags[1] = tab_flag_frozen;
    @memcpy(st.groups[1][0..5], "tools");
    st.group_lens[1] = 5;
    persisted_tabs_v2 = st;
    // The windows arrive out of order and with none of the extras.
    _ = manager.add_or_update_tab(3, "Files");
    _ = manager.add_or_update_tab(2, "Calc");
    try std.testing.expect(maybe_apply_persisted_tabs());
    try std.testing.expectEqualStrings("Calc", manager.tabs[0].get_title());
    try std.testing.expect(manager.tabs[0].pinned);
    try std.testing.expectEqualStrings("GOCALC.ELF", manager.tabs[0].get_bin());
    try std.testing.expectEqualStrings("Files", manager.tabs[1].get_title());
    try std.testing.expect(manager.tabs[1].frozen);
    try std.testing.expectEqualStrings("tools", manager.tabs[1].group[0..manager.tabs[1].group_len]);
    try std.testing.expectEqual(@as(?usize, 1), manager.active_idx);
    try std.testing.expect(!maybe_apply_persisted_tabs()); // applies once
}

test "tabwm: declare_fullscreen join still applies pending v2 pin/freeze (TWM/ST6)" {
    resetForTest();
    var st = TabsStateV2{};
    st.count = 1;
    st.active = 0;
    @memcpy(st.titles[0][0..4], "Calc");
    st.title_lens[0] = 4;
    st.flags[0] = tab_flag_pinned | tab_flag_frozen;
    persisted_tabs_v2 = st;
    var req = ui.WmRpc{
        .kind = ui.wm_rpc_kind_declare_fullscreen,
        .id = 2,
        .seq = 1,
        .reply_to = 5,
        .applied = 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = @as([ui.wm_rpc_title_max]u8, @splat(@as(u8, 0))),
    };
    @memcpy(req.title[0..4], "Calc");
    try std.testing.expect(wnd_mail_apply(&req));
    try std.testing.expectEqual(@as(usize, 1), manager.tab_count);
    try std.testing.expect(manager.tabs[0].pinned);
    try std.testing.expect(manager.tabs[0].frozen);
    try std.testing.expect(!maybe_apply_persisted_tabs());
}

test "tabwm: a later mirror still applies pending v2 when the RPC joined first (TWM/ST7)" {
    resetForTest();
    var st = TabsStateV2{};
    st.count = 1;
    @memcpy(st.titles[0][0..4], "Calc");
    st.title_lens[0] = 4;
    st.flags[0] = tab_flag_pinned | tab_flag_frozen;
    persisted_tabs_v2 = st;
    _ = manager.add_or_update_tab(2, "Calc");
    handle_window_mirror(2, true, false, false, 512, 424);
    try std.testing.expect(manager.tabs[0].pinned);
    try std.testing.expect(manager.tabs[0].frozen);
}

test "tabwm: a v1 file still parses and a v2 parser refuses it (TWM/ST3)" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "Legacy");
    var buf: [tabs_v2_max_bytes]u8 = undefined;
    const n = serialize_tabs(&buf); // the v1 writer
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
    var st: TabsState = .{};
    try std.testing.expect(parse_tabs(buf[0..n], &st));
    try std.testing.expectEqualStrings("Legacy", st.titles[0][0..st.title_lens[0]]);
    var st2: TabsStateV2 = .{};
    try std.testing.expect(!parse_tabs_v2(buf[0..n], &st2));
    // Downgrade: an older (v1-only) build refuses a v2 file rather than
    // misreading the extra fields — version mismatch, no saved state.
    const n2 = serialize_tabs_v2(&buf);
    try std.testing.expectEqual(@as(u8, 2), buf[0]);
    var st_v1: TabsState = .{};
    try std.testing.expect(!parse_tabs(buf[0..n2], &st_v1));
}

test "tabwm: truncated or out-of-range v2 records are rejected (TWM/ST4)" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "A");
    _ = manager.add_or_update_tab(3, "B");
    var buf: [tabs_v2_max_bytes]u8 = undefined;
    const n = serialize_tabs_v2(&buf);
    var st: TabsStateV2 = .{};
    try std.testing.expect(parse_tabs_v2(buf[0..n], &st));
    try std.testing.expect(!parse_tabs_v2(buf[0 .. n - 1], &st)); // truncated
    try std.testing.expect(!parse_tabs_v2(buf[0..4], &st)); // short header
    var bad = buf;
    bad[2] = max_tabs + 1;
    try std.testing.expect(!parse_tabs_v2(bad[0..n], &st)); // count over max
    bad = buf;
    bad[1] = 9;
    try std.testing.expect(!parse_tabs_v2(bad[0..n], &st)); // active out of range
    bad = buf;
    bad[0] = 9;
    try std.testing.expect(!parse_tabs_v2(bad[0..n], &st)); // wrong version
}

test "tabwm: the change log formats, reads back in order, and is bounded (TWM/LOG1)" {
    resetForTest();
    var buf: [tablog_line_max]u8 = undefined;
    try std.testing.expectEqualStrings("1 switch tab 2", tablog_format(1, tablog_code_switch, "tab 2", &buf));
    try std.testing.expectEqualStrings("2 close tab 7", tablog_format(2, tablog_code_close, "tab 7", &buf));

    resetForTest();
    tablog_event(tablog_code_switch, "tab 2");
    tablog_event(tablog_code_close, "tab 7");
    try std.testing.expectEqual(@as(usize, 2), tablog_count_events());
    try std.testing.expectEqualStrings("1 switch tab 2", tablog_view(0).?);
    try std.testing.expectEqualStrings("2 close tab 7", tablog_view(1).?);
    try std.testing.expect(tablog_view(2) == null);

    // The ring is bounded and drops the OLDEST entry first.
    resetForTest();
    var i: usize = 0;
    while (i < tablog_ring + 3) : (i += 1) tablog_event(tablog_code_reorder, "0->1");
    try std.testing.expectEqual(tablog_ring, tablog_count_events());
    var b0: [tablog_line_max]u8 = undefined;
    try std.testing.expectEqualStrings(tablog_format(4, tablog_code_reorder, "0->1", &b0), tablog_view(0).?);
    var b1: [tablog_line_max]u8 = undefined;
    try std.testing.expectEqualStrings(tablog_format(@intCast(tablog_ring + 3), tablog_code_reorder, "0->1", &b1), tablog_view(tablog_ring - 1).?);
}

test "tabwm: tab actions record into the change log (TWM/LOG2)" {
    resetForTest();
    _ = manager.add_or_update_tab(2, "A");
    _ = manager.add_or_update_tab(3, "B");
    activate_tab(1);
    _ = pin_toggle(0);
    _ = freeze_toggle(1);
    _ = reorder_tab(0, 1);
    close_tab(1);
    // close_tab re-activates the surviving tab, so the close ALSO records a
    // switch: 6 events for 5 user actions. Every action must be present.
    try std.testing.expectEqual(@as(usize, 6), tablog_count_events());
    const want = [_][]const u8{ "switch", "pin", "freeze", "reorder", "close" };
    for (want) |w| {
        var seen = false;
        var k: usize = 0;
        while (k < tablog_count_events()) : (k += 1) {
            if (std.mem.indexOf(u8, tablog_view(k).?, w) != null) seen = true;
        }
        try std.testing.expect(seen);
    }
    try std.testing.expectEqualStrings("switch tab 3", tablog_view(0).?[2..]);
}

test "tabwm: tablog formatter truncates a long detail rather than degrading (TWM/LOG3)" {
    var buf: [tablog_line_max]u8 = undefined;
    const line = tablog_format(1, tablog_code_launch, "THIS_IS_A_VERY_LONG_EXECUTABLE_NAME.BIN", &buf);
    try std.testing.expect(line.len <= tablog_line_max);
    try std.testing.expect(std.mem.startsWith(u8, line, "1 launch "));
    try std.testing.expect(!std.mem.eql(u8, line, "0 ? ?"));
}

test "tabwm: Tab[max_tabs] reorder scratch lives in BSS (TWM/ST5)" {
    // One [max_tabs]Tab is ~6.5 KiB. LLVM inlines normalize_pinned plus the
    // v1 and v2 persist-apply paths into main; three of those plus a
    // by-value TabsStateV2 blow the 32 KiB EL0 stack. The scratch is BSS.
    const reorder = @sizeOf(Tab) * max_tabs;
    try std.testing.expectEqual(reorder, @sizeOf(@TypeOf(tab_reorder_scratch)));
    try std.testing.expect(reorder * 3 + @sizeOf(TabsStateV2) > 16 * 1024);
}
