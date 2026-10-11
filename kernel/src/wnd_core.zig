//! M32 WMS3 (issue #623) — shared PURE window-manager logic (the drift
//! guard).
//!
//! The single-source home for the window manager's pure geometry and
//! policy RULES: rect math, hit-testing, z-order reasoning, resize
//! clamping, workspace visibility, and chrome title layout. It is compiled
//! by BOTH the kernel shim (`kernel/src/driving_award.zig`) and the
//! long-lived EL0 WM server (`user/src/wnd.zig`), so the two cannot
//! behaviorally drift while both are live — the whole point of WMS3's
//! single-source extraction (one physical file, not a checked copy).
//!
//! DEPENDENCY-FREE CONTRACT: this module imports NOTHING (no kernel
//! modules, no `std` at comptime-only is allowed for tests) — it is pure
//! computation over plain value types. It deliberately does NOT render and
//! holds NO kernel state (no framebuffer, no `virtio_gpu`, no event
//! queues); it only returns decisions the caller applies. This is what
//! lets the same file compile at EL1 (kernel) and EL0 (user), freestanding,
//! no libc, no POSIX.
//!
//! WMS4–WMS6 drain-out contract: as chrome / geometry / z-order / focus
//! policy moves to the WM server, the POLICY RULES live HERE; the kernel
//! keeps only blit/present/input-fan-out. When the two disagree about a
//! rule, they both get the fix from this one file — that is the no-drift
//! guarantee.
//!
//! Extraction discipline (issue #623 risk note): only what WMS4–WMS6 need
//! (rects, registry, z-order, hit-test, focus/clamp) lives here — NOT the
//! whole 4,740-line `driving_award.zig`.

/// The window-kind tags (the terminal and the fixed chrome layers).
pub const Kind = enum {
    terminal,
    clock,
    user,
    taskbar,
    wallpaper,
    dock,
};

/// The pure, kernel-agnostic geometry row the rules operate on. The kernel
/// shim adapts its runtime `Window` to this via `Geom.of`; the WM server
/// can carry the same rows to make decisions. This is deliberately NOT the
/// kernel's full `Window` (which owns back-buffers, event state, animation
/// phases, dynamic titles — none of which are policy decisions).
pub const Geom = struct {
    id: u8,
    kind: Kind,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    visible: bool,
    workspace: u8,
};

/// The resize bounds and hit size (the numeric policy; single source).
/// The kernel re-exports these so the two sides can never use different
/// numbers for the same rule.
pub const resize_min_w: u32 = 128;
pub const resize_min_h: u32 = 64;
pub const resize_hit_size: u32 = 6;
pub const user_buf_w: u32 = 512;
pub const user_buf_h: u32 = 424;

/// True when (x, y) is inside the geometry row's rect (left-inclusive,
/// right-exclusive — the same convention the compositor uses).
pub fn rect_contains(g: Geom, x: u32, y: u32) bool {
    return x >= g.x and x < g.x + g.w and y >= g.y and y < g.y + g.h;
}

/// Arc4 #241: is a window visible in the current workspace? Fixed layers
/// (everything non-`.user`) are visible on all workspaces; user windows
/// only on their own. Pure.
pub fn workspace_visible(g: Geom, current_workspace: u8) bool {
    if (g.kind != .user) return true;
    return g.workspace == current_workspace;
}

/// The topmost visible, in-workspace, interactive window containing
/// (x, y), or null. Iterates the z-order from TOP (last) to bottom, skips
/// hidden windows, out-of-workspace windows, and the non-interactive
/// wallpaper layer. Pure — the ONLY hit-test rule; the compositor's input
/// fan-out and the WM server's hit-testing both call this.
///
/// `geoms` must be in registry order (index 0 = bottom of the z-order, the
/// last index = top) — exactly the z-order convention the compositor uses.
pub fn hit_test(geoms: []const Geom, current_workspace: u8, x: u32, y: u32) ?u8 {
    var i: usize = geoms.len;
    while (i > 0) {
        i -= 1;
        const g = geoms[i];
        if (!g.visible) continue;
        if (!workspace_visible(g, current_workspace)) continue;
        if (g.kind == .wallpaper) continue;
        if (rect_contains(g, x, y)) return g.id;
    }
    return null;
}

/// M32 WMS5 (issue #625, claim 9849): the title-bar band height — the
/// drag-grab zone. Single source: the kernel shim's drag initiation and
/// the WM server's drag hit-test use the SAME number (driving_award's
/// `user_title_h` re-exports this).
pub const title_bar_h: u32 = 16;

/// M32 WMS5 (issue #625): the title-bar drag-grab rule — true when
/// (x, y) is inside the window's title band (the top `title_bar_h` rows
/// of its rect, full width — the close/minimize buttons sit inside it,
/// which is why the kernel checks buttons BEFORE the drag). Pure, single
/// source: the kernel shim's drag initiation and WND.BIN's EL0 hit-test
/// are both this shape (the live gate proves WND.BIN's asm obeys it).
pub fn title_bar_contains(g: Geom, x: u32, y: u32) bool {
    return x >= g.x and x < g.x + g.w and y >= g.y and y < g.y + title_bar_h;
}

/// WMS8 Gate 4 (issue #628): the unsaved-changes dialog's button geometry.
/// Single source: the kernel's `unsaved_dialog_click` rects and WND.BIN's
/// EL0 button hit-test use the SAME numbers (200x100 centered on the
/// scanout; Save / Don't Save / Cancel on the bottom row) — parity by
/// construction. Pure.
pub const unsaved_dialog_w: u32 = 200;
pub const unsaved_dialog_h: u32 = 100;

pub const UnsavedChoice = enum { save, dont_save, cancel, none };

pub fn unsaved_dialog_choice_at(fw: u32, fh: u32, x: u32, y: u32) UnsavedChoice {
    const dlg_x: u32 = if (fw > unsaved_dialog_w) (fw - unsaved_dialog_w) / 2 else 0;
    const dlg_y: u32 = if (fh > unsaved_dialog_h) (fh - unsaved_dialog_h) / 2 else 0;
    if (y >= dlg_y + unsaved_dialog_h - 30 and y < dlg_y + unsaved_dialog_h - 10) {
        if (x >= dlg_x + 20 and x < dlg_x + 80) return .save;
        if (x >= dlg_x + 90 and x < dlg_x + 150) return .dont_save;
        // Review fix (claim 7639): Cancel is the painted 30px button
        // (x+160..190) — the old 60px rect (x+160..220) overran the 200px
        // dialog by 20px and enshrined a dead zone.
        if (x >= dlg_x + 160 and x < dlg_x + 190) return .cancel;
    }
    return .none;
}

/// The z-order rank of a window by id (the registry index, 0 = bottom), or
/// null. Pure — the number the kernel's monitor row and the EL0
/// `sys_win_query` both report; the WM server uses it once it owns the
/// registry (WMS4).
pub fn z_rank(geoms: []const Geom, id: u8) ?usize {
    for (geoms, 0..) |el, i| {
        if (el.id == id) return i;
    }
    return null;
}

/// Clamp a requested window width to `min_w..max_buf_w` AND on-scanout
/// (never wider than the framebuffer minus the window's x). Pure.
pub fn clamp_resize_w(req_w: i32, win_x: u32, sw: u32, min_w: u32, max_buf_w: u32) u32 {
    _ = sw; // the shared fb_w constant is the scanout width (fixed 1280)
    var w: i32 = req_w;
    if (w < @as(i32, @intCast(min_w))) w = @as(i32, @intCast(min_w));
    if (w > @as(i32, @intCast(max_buf_w))) w = @as(i32, @intCast(max_buf_w));
    // Screen containment: max is remaining width from win_x.
    const max_screen = @as(i32, @intCast(fb_w -| win_x));
    if (w > max_screen) w = max_screen;
    if (w < @as(i32, @intCast(min_w))) w = @as(i32, @intCast(min_w));
    if (w < 0) w = @as(i32, @intCast(min_w));
    return @intCast(w);
}

/// Clamp a requested window height to `min_h..max_buf_h` AND on-scanout.
/// Pure.
pub fn clamp_resize_h(req_h: i32, win_y: u32, sw: u32, min_h: u32, max_buf_h: u32) u32 {
    _ = sw; // the shared fb_h constant is the scanout height (fixed 720)
    var h: i32 = req_h;
    if (h < @as(i32, @intCast(min_h))) h = @as(i32, @intCast(min_h));
    if (h > @as(i32, @intCast(max_buf_h))) h = @as(i32, @intCast(max_buf_h));
    const max_screen = @as(i32, @intCast(fb_h -| win_y));
    if (h > max_screen) h = max_screen;
    if (h < @as(i32, @intCast(min_h))) h = @as(i32, @intCast(min_h));
    if (h < 0) h = @as(i32, @intCast(min_h));
    return @intCast(h);
}

/// M20-U9 layout helper: where the centered title text starts and how many
/// bytes to draw, given a window width and label length. Leaves room for
/// the minimize+close buttons; too-wide labels truncate with "...". Pure.
/// The title-layout result (named so BOTH sides return the SAME type — an
/// anonymous struct would create two distinct types the delegating kernel
/// could not return directly).
// ---------------------------------------------------------------------------
// WMS5 Gate 2 (issue #625, claim 4278) — the shared GEOMETRY POLICY rules.
// The pure math the WM server issues over SET_WINDOW rects: tile/master-
// detail layout, snap zones, maximize rect, and the scanout chrome
// geometry (framebuffer dims + taskbar + dock). Compiled by BOTH the
// kernel shim and WND.BIN — a rule change on either side fails the
// drift-guard tests, so the WM's proposed rects can never disagree with
// the shim's own numbers while both are live.
// ---------------------------------------------------------------------------

/// The scanout chrome geometry — single source for BOTH sides (the shim's
/// `taskbar_h`/`dock_w`/fb constants re-export these; the WM computes
/// tile/snap/max rects from them). The framebuffer is a fixed 1280x720
/// scanout (virtio_gpu) with a 20 px bottom taskbar and 24 px left dock.
pub const fb_w: u32 = 1280;
pub const fb_h: u32 = 720;
pub const taskbar_h: u32 = 20;
pub const dock_w: u32 = 24;

/// M15 C3 (snap zones, #227) + M21 W1/W2 (tiling): the zone tags the WM
/// hit-tests against. `none` = free (no snap).
pub const SnapZone = enum { none, left, right, top, bottom, top_left, top_right, bottom_left, bottom_right };

/// The snap threshold (px from a scanout edge that counts as "near").
pub const snap_thresh: u32 = 20;

/// M15 C3 (snap zones, #227): 20 px threshold, corners first, then edges.
/// Pure — the WM hit-tests a pointer position against this on drag-drop,
/// and the shim uses the identical rule for its own pointer path.
pub fn snap_zone_for_point(x: u32, y: u32, sw: u32, sh: u32) SnapZone {
    const fbw = sw;
    const fbh = sh;
    const near_left = x < snap_thresh;
    const near_right = x + snap_thresh >= fbw;
    const near_top = y < snap_thresh;
    const near_bottom = y + snap_thresh >= fbh;
    // Corners take precedence (avoid flicker when corner zones overlap edges).
    if (near_left and near_top) return .top_left;
    if (near_right and near_top) return .top_right;
    if (near_left and near_bottom) return .bottom_left;
    if (near_right and near_bottom) return .bottom_right;
    if (near_left) return .left;
    if (near_right) return .right;
    if (near_top) return .top;
    if (near_bottom) return .bottom;
    return .none;
}

/// Zone bounds in scanout coordinates (taskbar excluded for bottom zones).
/// Pure — the WM snaps a window to this rect (then the kernel clamps); the
/// shim uses the same numbers.
/// The snap-zone rect type (named so BOTH sides return the SAME type — an
/// anonymous struct would create two distinct types the delegating kernel
/// could not return directly).
pub const SnapBounds = struct { x: u32, y: u32, w: u32, h: u32 };

pub fn snap_zone_bounds(zone: SnapZone, sw: u32, sh: u32, tb_h: u32) ?SnapBounds {
    const fbw = sw;
    const fbh = sh;
    const half_w = fbw / 2;
    const half_h = (fbh - tb_h) / 2;
    return switch (zone) {
        .none => null,
        .left => .{ .x = 0, .y = 0, .w = half_w, .h = fbh - tb_h },
        .right => .{ .x = half_w, .y = 0, .w = fbw - half_w, .h = fbh - tb_h },
        .top => .{ .x = 0, .y = 0, .w = fbw, .h = half_h },
        .bottom => .{ .x = 0, .y = half_h, .w = fbw, .h = fbh - half_h - tb_h },
        .top_left => .{ .x = 0, .y = 0, .w = half_w, .h = half_h },
        .top_right => .{ .x = half_w, .y = 0, .w = fbw - half_w, .h = half_h },
        .bottom_left => .{ .x = 0, .y = half_h, .w = half_w, .h = half_h },
        .bottom_right => .{ .x = half_w, .y = half_h, .w = fbw - half_w, .h = half_h },
    };
}

/// M21 W1/W2 tiling layout: the two tiled rects (master + detail) for the
/// current master side and percentage. Master gets `master_pct`/1000 of the
/// usable width (the scanout minus the dock); detail gets the rest; both
/// fill the usable height (scanout minus the taskbar). Pure — the WM
/// computes the rects it issues via SET_WINDOW, and the shim's
/// `apply_tile_layout` uses the identical rule.
pub const TileLayout = struct { master_x: u32, master_w: u32, detail_x: u32, detail_w: u32, y: u32, h: u32 };

pub fn tile_layout(sw: u32, sh: u32, tb_h: u32, dk_w: u32, master_pct: u32, master_side_left: bool) TileLayout {
    const fbw = sw;
    const fbh = sh;
    const usable_w = fbw - dk_w;
    const usable_h = fbh - tb_h;
    const master_w = usable_w * master_pct / 1000;
    const detail_w = usable_w - master_w;
    if (master_side_left) {
        return .{ .master_x = dk_w, .master_w = master_w, .detail_x = dk_w + master_w, .detail_w = detail_w, .y = 0, .h = usable_h };
    }
    return .{ .master_x = dk_w + detail_w, .master_w = master_w, .detail_x = dk_w, .detail_w = detail_w, .y = 0, .h = usable_h };
}

/// M21 W6 maximize rect: fill the workspace area (scanout minus the dock
/// and taskbar; title bar stays visible). Pure — the WM issues this rect
/// via SET_WINDOW; the shim's `toggle_maximize` uses the same numbers.
pub fn maximize_rect(sw: u32, sh: u32, tb_h: u32, dk_w: u32) struct { x: u32, y: u32, w: u32, h: u32 } {
    const fbw = sw;
    const fbh = sh;
    return .{ .x = dk_w, .y = 0, .w = fbw - dk_w, .h = fbh - tb_h };
}

/// M21 W7 fullscreen rect: the ENTIRE scanout (no title bar, no taskbar).
pub fn fullscreen_rect(sw: u32, sh: u32) struct { x: u32, y: u32, w: u32, h: u32 } {
    const fbw = sw;
    const fbh = sh;
    return .{ .x = 0, .y = 0, .w = fbw, .h = fbh };
}

pub const TitleLayout = struct { x_off: usize, draw_len: usize, truncated: bool };

// ---------------------------------------------------------------------------
// WM3 (issue #707 card 3): taskbar ENTRY layout — single-sourced so the
// kernel render (window 255's `.taskbar` branch) and the registered WM's
// hit-test cannot disagree about which rect belongs to which entry.
// Entries enumerate CURRENT-WORKSPACE user windows in ID-ASCENDING order
// (the kernel loops the user-window id range; the WM loops its mirror
// slots, which are keyed by the same ids). Both sides call these same
// pure functions — the drift-guard pattern of the snap/tile rules above.
// ---------------------------------------------------------------------------

/// The workspace switcher geometry (the bar's left edge): `ws_count`
/// cells of `taskbar_ws_cell` px spaced `taskbar_ws_stride` apart,
/// starting at `taskbar_ws_x0`. The kernel's `.taskbar` render and the
/// WM's entry math share these numbers.
pub const taskbar_ws_x0: u32 = 4;
pub const taskbar_ws_cell: u32 = 20;
pub const taskbar_ws_stride: u32 = 24;

/// One taskbar entry: `taskbar_entry_w` px wide with `taskbar_entry_gap`
/// px between entries; the title draws `taskbar_entry_pad` px inside at
/// the 8 px monospace advance, so `taskbar_entry_max_chars` bytes fit.
/// The slice is clipped to 8 (not the geometric 9) so the minimized
/// indicator dot at the entry's right edge never overlaps the text.
pub const taskbar_entry_w: u32 = 80;
pub const taskbar_entry_gap: u32 = 4;
pub const taskbar_entry_pad: u32 = 4;
pub const taskbar_entry_char_w: u32 = 8;
pub const taskbar_entry_max_chars: usize = 8;

/// The 2 px focused-entry underline (the active indicator), inset
/// `taskbar_indicator_inset` px from the entry's left/right edges.
pub const taskbar_indicator_h: u32 = 2;
pub const taskbar_indicator_inset: u32 = 4;

/// The taskbar entry rect (the same shape `SnapBounds` uses — a flat
/// number struct BOTH sides return).
pub const TaskbarRect = struct { x: u32, y: u32, w: u32, h: u32 };

/// The x where entry 0 starts (right of the switcher + one gap).
pub fn taskbar_entries_x0(ws_count: u32) u32 {
    return taskbar_ws_x0 + ws_count * taskbar_ws_stride + taskbar_entry_gap;
}

/// The rect of taskbar entry `i` (the i-th current-workspace user window,
/// id-ascending), or null once an entry would reach the tray — the bar's
/// right `tray_w` px belong to the tray widgets, never to entries. Pure:
/// the kernel render walks i = 0.. until null; the WM hit-tests the same
/// rects.
pub fn taskbar_entry_rect(i: u32, ws_count: u32, sw: u32, sh: u32, tray_w: u32) ?TaskbarRect {
    const x = taskbar_entries_x0(ws_count) + i * (taskbar_entry_w + taskbar_entry_gap);
    if (x + taskbar_entry_w > sw - tray_w) return null;
    return .{ .x = x, .y = sh - taskbar_h + 2, .w = taskbar_entry_w, .h = taskbar_h - 4 };
}

/// The taskbar-entry hit-test: which entry index (if any) sits under
/// (px, py). Pure — the WM calls this on a kind-19 DOWN EDGE with the
/// SAME ws_count/sw/sh/tray_w the kernel rendered with; the kernel never
/// hit-tests (the entry click decision is the WM's, like the dock's).
pub fn taskbar_entry_at(ws_count: u32, sw: u32, sh: u32, tray_w: u32, px: u32, py: u32) ?u32 {
    if (py < sh - taskbar_h or py >= sh) return null;
    var i: u32 = 0;
    while (taskbar_entry_rect(i, ws_count, sw, sh, tray_w)) |r| : (i += 1) {
        if (px >= r.x and px < r.x + r.w) return i;
    }
    return null;
}

/// The taskbar title slice: at most `taskbar_entry_max_chars` bytes of
/// the 8 px-advance monospace fit inside an entry (the kernel render and
/// the WM's own taskbar notion clip identically).
pub fn taskbar_title_slice(title: []const u8) []const u8 {
    return title[0..@min(title.len, taskbar_entry_max_chars)];
}

// ---------------------------------------------------------------------------
// WMS4 (issue #624) — the SET_WINDOW chrome descriptor ABI (ADR 0007
// amendment). The single source of the chrome LOOK: element kinds, per-
// window flags, and the theme colors. The WM server (userland) computes
// chrome from these rules and issues descriptors; the kernel blits whatever
// the descriptor dictates. BOTH sides compile this same struct, so the
// two cannot drift about what a descriptor means.
// ---------------------------------------------------------------------------

/// The 40-byte flat SET_WINDOW chrome descriptor (10 × u32 — no pointers;
/// the frozen ADR 0007 encoding: `sys_wmctl(SET_WINDOW, a0=window_id,
/// a1=0, a2=0, ptr=descriptor, len=40)`). Colors are 0xRRGGBB. The
/// kernel copies it in via uaccess, validates, and stores it per window
/// (or as the broadcast policy when a0 = ALL).
pub const ChromeDesc = extern struct {
    /// Element bitmask (chrome_border | chrome_title | ... ). Zero is
    /// invalid — a descriptor must say what chrome it wants.
    kind: u32,
    /// Per-window flags (chrome_flag_focus_accent | ...). Reserved bits
    /// must be zero.
    flags: u32,
    /// 2px window border, focused (or accent when FOCUS_ACCENT).
    border_rgb: u32,
    /// 2px window border, unfocused (muted).
    border_unfocus_rgb: u32,
    /// 16px title band background.
    title_bg_rgb: u32,
    /// Title label ink.
    title_fg_rgb: u32,
    /// 3px focus ring on the focused window.
    ring_rgb: u32,
    /// Close glyph ("×").
    close_rgb: u32,
    /// Minimize glyph ("—").
    min_rgb: u32,
    /// Pin glyph ("*", always-on-top windows).
    pin_rgb: u32,
    /// WM4 (issue #707 card 4, ABI v2 — BACKWARD COMPATIBLE): the rest
    /// opacity for the window's CLIENT area. 0 = none (normalized to 256
    /// — the v1 zero-extension semantics), 1..255 = the at-rest alpha,
    /// 256 = fully opaque (the v1 default). Applied by the kernel ONLY
    /// to the client blit of an AT-REST (fade complete) UNFOCUSED window;
    /// the chrome (border/title/ring) never fades, so the WMS4
    /// pixel-exact chrome parity gate is untouched. The frozen 40-byte
    /// v1 wire ABI grows to 44 with a DEFAULT field: every existing
    /// descriptor site compiles unchanged and every 40-byte SET_WINDOW
    /// submitter is still accepted (zero-extended → rest_alpha = 0 = the
    /// v1 behavior).
    rest_alpha: u32 = 256,
};

/// Descriptor byte size — the frozen v1 `len` for SET_WINDOW (the kernel
/// refuses any other length with EINVAL). WM4 ABI v2: `chrome_desc_bytes_v2`
/// is ALSO accepted (the v1 10 u32s + the rest_alpha tail = 11 u32s).
pub const chrome_desc_bytes: usize = 40;
pub const chrome_desc_bytes_v2: usize = 44;

/// Window-id broadcast: SET_WINDOW with a0 = ALL sets the WM's chrome
/// POLICY — applied to every user window and inherited by windows created
/// afterwards (the kernel stores it as the fallback). A specific id sets
/// that window's override.
pub const chrome_window_all: u64 = 0xFFFF_FFFF;

// ---------------------------------------------------------------------------
// M32 WMS7 Gate A (issue #627): the app↔WM mailbox protocol (WM_RPC) wire
// format — frozen in ADR 0015. WND.BIN (the server) and WMRPC.BIN (the test
// app) compile this SAME source, so the two cannot drift; the kernel imports
// wnd_core already, so a future in-kernel consumer gets the same ABI. It rides
// the EXISTING per-process mailbox (sys_ipc_send/recv, slots 5/6) and FITS the
// frozen 64-byte slot — the sanctioned size decision is "grow nothing".
// ---------------------------------------------------------------------------

/// A request (or reply — `kind` carries the reply flag bit 7). Frozen
/// little-endian layout. Applies through the WM's existing clamped
/// primitives: WIN_RAISE -> ALT_TAB commit (focus+raise), WIN_CONFIG ->
/// SET_WINDOW rect (clamped move/resize).
pub const WmRpc = extern struct {
    /// 1 = WIN_RAISE, 2 = WIN_CONFIG; a reply is `kind | wm_rpc_reply_flag`.
    kind: u8,
    /// Target window id (WMRPC never legitimately targets the ALL sentinel).
    id: u8,
    /// Request/reply correlation sequence (the app echoes it back).
    seq: u8,
    /// Reply destination process id (max_processes < 256).
    reply_to: u8,
    /// Reply flag: 1 = applied, 0 = refused (unknown kind / bad id).
    applied: u8,
    /// Explicit pad so the u16 rect is 2-aligned (size pinned by test).
    pad: u8,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    /// WIN_CONFIG bounded title (NUL-safe). The WM logs it (does not render
    /// it yet — Gate B's toolkit round-trip will). Zero-padded.
    title: [wm_rpc_title_max]u8,
};

pub const wm_rpc_title_max: usize = 24;
pub const wm_rpc_kind_raise: u8 = 1;
pub const wm_rpc_kind_config: u8 = 2;
/// S1/S5 Action registry seam (Milestone 19, issues #701, #705).
pub const wm_rpc_kind_register_action: u8 = 3;
pub const wm_rpc_kind_invoke_action: u8 = 4;
/// S6 Tab model (Milestone 19, issue #782).
pub const wm_rpc_kind_attach_tab: u8 = 5;
pub const wm_rpc_kind_detach_tab: u8 = 6;
pub const wm_rpc_kind_cycle_tab: u8 = 7;
/// M42 SX2 (issue #983): the app declares itself tab-aware — full-viewport
/// eligible. Additive kind; WND.BIN (which has no tab-aware concept) treats
/// it as unknown and refuses, TABWM.BIN registers the declaration.
pub const wm_rpc_kind_declare_fullscreen: u8 = 8;
/// M79d (#1707) / M80g (#1715): the seat replaces a window's tab title
/// (client -> seat; the kernel's tty-side producer is OSC 0/2's title).
/// Mirrors `vi.WmRpcKindSetTitle` — kinds 9/10 (nav) stay Go-only. Additive
/// like kind 8: WND.BIN treats an unknown kind as refused.
pub const wm_rpc_kind_set_title: u8 = 11;
pub const wm_rpc_reply_flag: u8 = 0x80;
/// The frozen mailbox slot bound the message must fit (ADR 0015 size
/// decision — the compact fixed layout fits 64 B, so message_max stays).
pub const wm_rpc_max: usize = 64;

/// Element-kind bits (the chrome the WM wants drawn per window).
pub const chrome_border: u32 = 0x01;
pub const chrome_title: u32 = 0x02;
pub const chrome_close: u32 = 0x04;
pub const chrome_minimize: u32 = 0x08;
pub const chrome_pin: u32 = 0x10;
pub const chrome_ring: u32 = 0x20;
/// M37 DQ2 (issue #840): the tab-strip element — a tab bar row below the
/// title bar on windows with attached tabs (titles + active highlight +
/// hover + per-tab close geometry; clicks are DQ3). Colors reuse the
/// frozen descriptor fields (no struct change): trough = unfocus, cell =
/// title_bg, active underline = ring, text = title_fg, close = close.
pub const chrome_tab_bar: u32 = 0x40;
/// Every element bit that exists (the mask valid kinds are checked
/// against; reserved bits are refused).
pub const chrome_kind_all: u32 = 0x7f;

/// Per-window flag bits.
pub const chrome_flag_focus_accent: u32 = 0x01;
/// Every flag bit that exists.
pub const chrome_flags_all: u32 = 0x01;

/// True when every set kind bit is known. Zero selects no per-window chrome;
/// the broadcast policy still requires at least one element.
pub fn chrome_kind_valid(kind: u32) bool {
    return (kind & ~chrome_kind_all) == 0;
}

/// True when every set flag bit is a known flag. Pure.
pub fn chrome_flags_valid(flags: u32) bool {
    return (flags & ~chrome_flags_all) == 0;
}

/// Full descriptor validity (kind + flags + the WM4 rest-alpha bound).
/// Pure — the kernel's refusal predicate and the WM's own self-check
/// share this one rule.
pub fn chrome_valid(d: ChromeDesc) bool {
    return chrome_kind_valid(d.kind) and chrome_flags_valid(d.flags) and d.rest_alpha <= 256;
}

pub fn chrome_valid_for_window(id: u64, d: ChromeDesc) bool {
    return chrome_valid(d) and (id != chrome_window_all or d.kind != 0);
}

/// WM4: the normalized rest alpha (0 = "none" → 256, the v1 default;
/// > 256 can't pass chrome_valid but is normalized defensively too).
pub fn chrome_rest_alpha_normalized(d: ChromeDesc) u32 {
    return if (d.rest_alpha == 0 or d.rest_alpha > 256) 256 else d.rest_alpha;
}

/// The WMS4 parity policy: the chrome descriptor WND.BIN issues at
/// startup — the dark-theme values, byte-equal to the kernel shim's own
/// chrome constants (user_border()/user_border_unfocused()/user_title_bg()/
/// user_title_fg_rgb/focus_ring()/0xef4444/0x94a3b8/0x38bdf8 on theme 0).
/// The WM becomes the theme owner by carrying the values, not theme
/// references; parity is provable because the values are equal, and this
/// single source is what both the EL0 blob test and the kernel pin
/// against.
pub fn chrome_parity_policy() ChromeDesc {
    return .{
        .kind = chrome_border | chrome_title | chrome_close | chrome_minimize | chrome_pin | chrome_ring | chrome_tab_bar,
        .flags = chrome_flag_focus_accent,
        .border_rgb = 0x0c1826,
        .border_unfocus_rgb = 0x475569,
        .title_bg_rgb = 0x1a2b3c,
        .title_fg_rgb = 0xffffff,
        .ring_rgb = 0x3b82f6,
        .close_rgb = 0xef4444,
        .min_rgb = 0x94a3b8,
        .pin_rgb = 0x38bdf8,
    };
}

pub fn chrome_title_layout(win_w: usize, label_len: usize) TitleLayout {
    const btn_reserve: usize = 34; // minimize + close + margins (right side)
    const min_pad: usize = 4; // never start left of x+4
    const usable = if (win_w > btn_reserve + min_pad) win_w - btn_reserve else win_w;
    const max_chars = usable / 8;
    var draw_len = label_len;
    var truncated = false;
    if (draw_len > max_chars and max_chars >= 4) {
        draw_len = max_chars - 3;
        truncated = true;
    } else if (draw_len > max_chars) {
        draw_len = max_chars;
        truncated = true;
    }
    const text_px = if (truncated) (draw_len + 3) * 8 else draw_len * 8;
    var x_off: usize = 0;
    if (win_w > text_px) x_off = (win_w - text_px) / 2;
    if (x_off < min_pad) x_off = min_pad;
    return .{ .x_off = x_off, .draw_len = draw_len, .truncated = truncated };
}

// ---------------------------------------------------------------------------
// S6 Tab model (Milestone 19, issue #782) — pure tab layout and cycle rules.
// ---------------------------------------------------------------------------

pub const tab_bar_height: u32 = 22;
pub const max_tabs_per_group: usize = 8;

pub const TabItem = struct {
    window_id: u8,
    parent_id: u8, // 0 = container/standalone, >0 = parent tab group
    active: bool,
    title: [24]u8 = @as([24]u8, @splat(@as(u8, 0))),
    title_len: u8 = 0,
};

pub const TabRect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

/// Pure tab item rect calculation for tab bar layout:
/// Given container window rect (x, y, w, h), tab index, and total tabs in group.
pub fn tab_item_rect(win_x: u32, win_y: u32, win_w: u32, tab_idx: usize, total_tabs: usize) TabRect {
    if (total_tabs == 0) return .{ .x = win_x, .y = win_y, .w = 0, .h = tab_bar_height };
    const tab_w = @max(48, win_w / @as(u32, @intCast(total_tabs)));
    const tab_x = win_x + @as(u32, @intCast(tab_idx)) * tab_w;
    return .{
        .x = tab_x,
        .y = win_y,
        // DQ2: saturating tail — narrow windows with many tabs clip the
        // last cells to zero instead of underflowing (this rule was dead
        // until the strip paint called it; the old plain subtract trapped).
        .w = @min(tab_w, (win_x + win_w) -| tab_x),
        .h = tab_bar_height,
    };
}

/// Pure tab cycle helper: given an array of tab items and currently active window ID,
/// returns the next window ID in the group to activate.
pub fn cycle_next_tab(tabs: []const TabItem, current_window_id: u8) ?u8 {
    var parent: u8 = 0;
    for (tabs) |t| {
        if (t.window_id == current_window_id) {
            parent = if (t.parent_id != 0) t.parent_id else t.window_id;
            break;
        }
    }
    if (parent == 0) return null;

    var first_id: ?u8 = null;
    var return_next = false;
    for (tabs) |t| {
        const item_parent = if (t.parent_id != 0) t.parent_id else t.window_id;
        if (item_parent == parent) {
            if (first_id == null) first_id = t.window_id;
            if (return_next) return t.window_id;
            if (t.window_id == current_window_id) return_next = true;
        }
    }
    return first_id;
}

// ---------------------------------------------------------------------------
// M37 DQ2 (issue #840) — tab-strip chrome geometry. The strip is one
// tab_bar_height row directly BELOW the title band (which owns
// w.y..w.y+title_bar_h; apps already keep client content below it), so the
// strip extends the chrome zone instead of moving the title. Paint lives in
// driving_award.draw_chrome (kernel blits WM-decided chrome); hit-testing
// in DQ3 routes through tab_item_rect + tab_rect_contains.
/// Strip rect for a window at (win_x, win_y) of width win_w.
pub fn tab_strip_rect(win_x: u32, win_y: u32, win_w: u32) TabRect {
    return .{ .x = win_x, .y = win_y + title_bar_h, .w = win_w, .h = tab_bar_height };
}

/// Per-tab title layout inside a cell of width tab_w: same truncation
/// shape as chrome_title_layout, reserving the per-tab close glyph + pads
/// instead of the title-bar buttons.
pub fn tab_title_layout(tab_w: usize, label_len: usize) TitleLayout {
    const close_reserve: usize = 14;
    const min_pad: usize = 4;
    const usable = if (tab_w > close_reserve + min_pad) tab_w - close_reserve else tab_w;
    const max_chars = usable / 8;
    var draw_len = label_len;
    var truncated = false;
    if (draw_len > max_chars and max_chars >= 4) {
        draw_len = max_chars - 3;
        truncated = true;
    } else if (draw_len > max_chars) {
        draw_len = max_chars;
        truncated = true;
    }
    return .{ .x_off = min_pad, .draw_len = draw_len, .truncated = truncated };
}

/// Close-box rect at the right end of a tab cell (12×12, vertically
/// centered) — geometry now, clicks in DQ3.
pub fn tab_close_rect(tab: TabRect) TabRect {
    const s: u32 = 12;
    const w = @min(s, tab.w);
    const h = @min(s, tab.h);
    return .{
        .x = tab.x + tab.w - w,
        .y = tab.y + (tab.h - h) / 2,
        .w = w,
        .h = h,
    };
}

/// Point-in-rect for strip hit-testing (DQ3's click routing proves it).
pub fn tab_rect_contains(r: TabRect, x: u32, y: u32) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

// ---------------------------------------------------------------------------
// WM2 mission-control overview (Self-hosting Lane 1, issue #707 card 2).
// The shared grid layout + hit-test rules (the drift guard): the kernel
// compositor renders the overview cards from these rects and WND.BIN
// hit-tests pointer clicks against the SAME rects, so the two cannot
// disagree about which card (or workspace button) a click landed on.
// ---------------------------------------------------------------------------

/// Maximum windows the overview grid lays out (the WM1 ceiling).
pub const overview_max_windows: usize = 8;
/// Workspace strip: one row at the bottom of the usable area holding one
/// button per workspace (drag a card onto a button to move it there).
pub const overview_strip_h: u32 = 28;
/// Number of workspace buttons in the strip (workspaces 0..2).
pub const overview_ws_count: u8 = 3;
/// Gap between cards and around the grid edge.
pub const overview_gap: u32 = 8;

/// The computed grid for `n` overview cards on the scanout. Cards fill the
/// usable area (scanout minus dock, taskbar, and the workspace strip);
/// `cols`/`rows` are the smallest near-square tiling holding `n`.
pub const OverviewGrid = struct {
    n: usize,
    cols: u32,
    rows: u32,
    card_w: u32,
    card_h: u32,
    x0: u32,
    y0: u32,
    strip_y: u32,
};

/// Compute the overview grid for `n` cards (`n` clamps to
/// `overview_max_windows`). Pure.
pub fn overview_grid(n: usize, sw: u32, sh: u32, tb_h: u32, dk_w: u32) OverviewGrid {
    const count = @min(n, overview_max_windows);
    const strip_y = sh -| tb_h -| overview_strip_h;
    if (count == 0) {
        return .{ .n = 0, .cols = 0, .rows = 0, .card_w = 0, .card_h = 0, .x0 = dk_w, .y0 = 0, .strip_y = strip_y };
    }
    // Smallest cols with cols*cols >= count (near-square, fills row-major).
    var cols: u32 = 1;
    while (@as(usize, cols) * @as(usize, cols) < count) : (cols += 1) {}
    const rows: u32 = @as(u32, @intCast((count + @as(usize, cols) - 1) / @as(usize, cols)));
    const usable_w = sw -| dk_w;
    const usable_h = strip_y;
    const card_w = (usable_w -| overview_gap * (cols + 1)) / cols;
    const card_h = (usable_h -| overview_gap * (rows + 1)) / rows;
    return .{
        .n = count,
        .cols = cols,
        .rows = rows,
        .card_w = card_w,
        .card_h = card_h,
        .x0 = dk_w + overview_gap,
        .y0 = overview_gap,
        .strip_y = strip_y,
    };
}

/// One card's rect (named so BOTH sides return the SAME type).
pub const OverviewCardRect = struct { x: u32, y: u32, w: u32, h: u32 };

/// Card `idx`'s rect within the grid (row-major). Pure.
pub fn overview_card_rect(g: OverviewGrid, idx: usize) OverviewCardRect {
    const c: u32 = @as(u32, @intCast(idx)) % g.cols;
    const r: u32 = @as(u32, @intCast(idx)) / g.cols;
    return .{
        .x = g.x0 + c * (g.card_w + overview_gap),
        .y = g.y0 + r * (g.card_h + overview_gap),
        .w = g.card_w,
        .h = g.card_h,
    };
}

/// Point-in-rect for card hit-testing (left-inclusive, right-exclusive —
/// the compositor convention).
pub fn overview_rect_contains(r: OverviewCardRect, x: u32, y: u32) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

/// The card index containing (x, y), or null (gaps, strip, chrome all
/// miss). The kernel render and the WM hit-test both call this. Pure.
pub fn overview_card_at(g: OverviewGrid, x: u32, y: u32) ?usize {
    var idx: usize = 0;
    while (idx < g.n) : (idx += 1) {
        if (overview_rect_contains(overview_card_rect(g, idx), x, y)) return idx;
    }
    return null;
}

/// Workspace button `ws`'s rect: the strip split into `overview_ws_count`
/// equal parts across the usable width (the last button takes the
/// remainder). Pure.
pub fn overview_ws_button_rect(ws: u8, sw: u32, dk_w: u32, strip_y: u32) OverviewCardRect {
    const usable_w = sw -| dk_w;
    const btn_w = usable_w / overview_ws_count;
    const x = dk_w + @as(u32, ws) * btn_w;
    const w = if (ws + 1 == overview_ws_count) (sw -| x) else btn_w;
    return .{ .x = x, .y = strip_y, .w = w, .h = overview_strip_h };
}

/// The workspace button containing (x, y), or null (outside the strip).
/// Pure.
pub fn overview_ws_button_at(g: OverviewGrid, sw: u32, dk_w: u32, x: u32, y: u32) ?u8 {
    var ws: u8 = 0;
    while (ws < overview_ws_count) : (ws += 1) {
        if (overview_rect_contains(overview_ws_button_rect(ws, sw, dk_w, g.strip_y), x, y)) return ws;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Host tests (Class A) — pin the RULES so the shim and the WM server provably
// share identical decision logic (the drift guard's machine check).
// ---------------------------------------------------------------------------

fn mk(id: u8, kind: Kind, x: u32, y: u32, w: u32, h: u32) Geom {
    return .{ .id = id, .kind = kind, .x = x, .y = y, .w = w, .h = h, .visible = true, .workspace = 0 };
}

const std = @import("std");

test "wnd_core: hit_test returns the topmost visible interactive window" {
    const geoms = [_]Geom{
        mk(0, .terminal, 0, 0, 1280, 720), // bottom
        mk(254, .wallpaper, 0, 0, 1280, 720),
        mk(255, .taskbar, 0, 700, 1280, 20),
        mk(2, .user, 100, 100, 400, 300), // top
    };
    // Wallpaper is skipped, topmost user wins.
    try std.testing.expectEqual(@as(?u8, 2), hit_test(&geoms, 0, 200, 200));
    // Taskbar (skipping the overlapping user window? no — taskbar is above here)...
    try std.testing.expectEqual(@as(?u8, 255), hit_test(&geoms, 0, 640, 710));
    // Genuine miss (outside every window).
    try std.testing.expectEqual(@as(?u8, null), hit_test(&geoms, 0, 2000, 2000));
    // User window's right edge is exclusive: x == w falls through to the
    // full-screen terminal underneath, so the topmost is the terminal (0).
    try std.testing.expectEqual(@as(?u8, 0), hit_test(&geoms, 0, 500, 200)); // x == user.w, exclusive
    // One pixel inside the user window top-right.
    try std.testing.expectEqual(@as(?u8, 2), hit_test(&geoms, 0, 499, 399)); // inside
}

test "wnd_core: hit_test honours workspace and visibility" {
    var geoms = [_]Geom{
        mk(0, .terminal, 0, 0, 1280, 720),
        mk(2, .user, 100, 100, 400, 300),
        mk(3, .user, 200, 200, 300, 200),
    };
    geoms[1].workspace = 1; // window 2 only on ws 1
    // Current ws 0: window 2 hidden, window 3 (ws 0) wins.
    try std.testing.expectEqual(@as(?u8, 3), hit_test(&geoms, 0, 250, 250));
    // Current ws 1: window 3 hidden, window 2 wins.
    try std.testing.expectEqual(@as(?u8, 2), hit_test(&geoms, 1, 250, 250));
    // Hidden window is never hit — only the full-screen terminal remains.
    geoms[2].visible = false;
    try std.testing.expectEqual(@as(?u8, 0), hit_test(&geoms, 0, 250, 250));
}

test "wnd_core: resize clamps are the on-scanout bounds" {
    // Under min, inside buffer, screen-bounded.
    try std.testing.expectEqual(@as(u32, resize_min_w), clamp_resize_w(10, 0, 1280, resize_min_w, user_buf_w));
    // Requested from x=1200: remaining screen = 80 → clamps to 128 (min).
    try std.testing.expectEqual(@as(u32, 128), clamp_resize_w(300, 1200, 1280, resize_min_w, user_buf_w));
    // Max buffer bound.
    try std.testing.expectEqual(@as(u32, user_buf_w), clamp_resize_w(99999, 0, 1280, resize_min_w, user_buf_w));
    try std.testing.expectEqual(@as(u32, 400), clamp_resize_w(400, 100, 1280, resize_min_w, user_buf_w));
}

test "wnd_core: workspace visibility rule (fixed layers always visible)" {
    try std.testing.expect(workspace_visible(mk(255, .taskbar, 0, 0, 1, 1), 2));
    try std.testing.expect(workspace_visible(mk(254, .wallpaper, 0, 0, 1, 1), 2));
    try std.testing.expect(!workspace_visible(mk(2, .user, 0, 0, 1, 1), 1)); // ws 0 vs current 1
    try std.testing.expect(workspace_visible(mk(3, .user, 0, 0, 1, 1), 0));
}

test "wnd_core: WMS5 title-bar drag-grab rule (single source)" {
    const g = mk(2, .user, 100, 100, 400, 300);
    // Inside the 16px title band, full width: left, middle, right edges.
    try std.testing.expect(title_bar_contains(g, 100, 100));
    try std.testing.expect(title_bar_contains(g, 300, 110));
    try std.testing.expect(title_bar_contains(g, 499, 115)); // x == right edge - 1
    // Below the band (client area) → NOT a drag grab.
    try std.testing.expect(!title_bar_contains(g, 300, 116)); // y == band end
    try std.testing.expect(!title_bar_contains(g, 300, 200));
    // Outside the window entirely.
    try std.testing.expect(!title_bar_contains(g, 99, 100)); // left edge exclusive
    try std.testing.expect(!title_bar_contains(g, 500, 100)); // right edge exclusive
    try std.testing.expect(!title_bar_contains(g, 300, 99)); // above
    // The band is exactly title_bar_h rows tall.
    try std.testing.expect(title_bar_contains(g, 100, 100 + title_bar_h - 1));
}

test "wnd_core: chrome title layout (the shared truncation rule)" {
    const wide = chrome_title_layout(400, 100);
    try std.testing.expect(wide.truncated);
    try std.testing.expect(wide.draw_len < 100);
    const narrow = chrome_title_layout(400, 4);
    try std.testing.expect(!narrow.truncated);
    try std.testing.expectEqual(@as(usize, 8), narrow.draw_len * 8 / 4); // 4 chars
    // Symmetric centring for a small label.
    const small = chrome_title_layout(200, 2);
    try std.testing.expectEqual(@as(usize, (200 - 16) / 2), small.x_off);
    try std.testing.expectEqual(@as(usize, 2), small.draw_len);
}

test "wnd_core: z_rank reports registry order (0 = bottom)" {
    const geoms = [_]Geom{ mk(0, .terminal, 0, 0, 1, 1), mk(2, .user, 0, 0, 1, 1), mk(3, .user, 0, 0, 1, 1) };
    try std.testing.expectEqual(@as(?usize, 0), z_rank(&geoms, 0));
    try std.testing.expectEqual(@as(?usize, 1), z_rank(&geoms, 2));
    try std.testing.expectEqual(@as(?usize, 2), z_rank(&geoms, 3));
    try std.testing.expectEqual(@as(?usize, null), z_rank(&geoms, 99));
}

test "wnd_core: chrome descriptor accepts zero per window but refuses zero broadcast" {
    const p = chrome_parity_policy();
    try std.testing.expect(chrome_valid(p));
    // No-chrome is an explicit per-window decision, never a broadcast.
    var d = p;
    d.kind = 0;
    try std.testing.expect(chrome_kind_valid(0));
    try std.testing.expect(chrome_valid(d));
    try std.testing.expect(chrome_valid_for_window(2, d));
    try std.testing.expect(!chrome_valid_for_window(chrome_window_all, d));
    try std.testing.expect(chrome_valid_for_window(chrome_window_all, p));
    // Reserved kind bit (0x80) is refused (0x40 is the DQ2 tab bar).
    d = p;
    d.kind = chrome_kind_all | 0x80;
    try std.testing.expect(!chrome_kind_valid(d.kind));
    try std.testing.expect(!chrome_valid(d));
    // Reserved flag bit (0x2) is refused.
    d = p;
    d.flags = chrome_flags_all | 0x2;
    try std.testing.expect(!chrome_flags_valid(d.flags));
    try std.testing.expect(!chrome_valid(d));
    // Every element bit is individually known.
    d = p;
    d.kind = chrome_border;
    try std.testing.expect(chrome_valid(d));
    d.kind = chrome_title;
    try std.testing.expect(chrome_valid(d));
    d.kind = chrome_close;
    try std.testing.expect(chrome_valid(d));
    d.kind = chrome_minimize;
    try std.testing.expect(chrome_valid(d));
    d.kind = chrome_pin;
    try std.testing.expect(chrome_valid(d));
    d.kind = chrome_ring;
    try std.testing.expect(chrome_valid(d));
    d.kind = chrome_tab_bar;
    try std.testing.expect(chrome_valid(d));
}

test "wnd_core: WMS5 Gate 2 geometry rules are pinned (tile/snap/max — the WM's rect math)" {
    // Scanout constants: the fixed 1280x720 scanout + the chrome geometry.
    try std.testing.expectEqual(@as(u32, 1280), fb_w);
    try std.testing.expectEqual(@as(u32, 720), fb_h);
    try std.testing.expectEqual(@as(u32, 20), taskbar_h);
    try std.testing.expectEqual(@as(u32, 24), dock_w);

    // Snap zone hit-test: 20 px threshold, corners first, then edges.
    try std.testing.expectEqual(SnapZone.top_left, snap_zone_for_point(5, 5, fb_w, fb_h));
    try std.testing.expectEqual(SnapZone.top_right, snap_zone_for_point(fb_w - 5, 5, fb_w, fb_h));
    try std.testing.expectEqual(SnapZone.left, snap_zone_for_point(5, 360, fb_w, fb_h));
    try std.testing.expectEqual(SnapZone.right, snap_zone_for_point(fb_w - 5, 360, fb_w, fb_h));
    try std.testing.expectEqual(SnapZone.bottom, snap_zone_for_point(640, fb_h - 5, fb_w, fb_h));
    try std.testing.expectEqual(SnapZone.none, snap_zone_for_point(640, 360, fb_w, fb_h));

    // Snap bounds: left/right halves, bottom zones exclude the taskbar.
    const l = snap_zone_bounds(.left, fb_w, fb_h, taskbar_h).?;
    try std.testing.expectEqual(@as(u32, 0), l.x);
    try std.testing.expectEqual(@as(u32, 640), l.w);
    try std.testing.expectEqual(@as(u32, fb_h - taskbar_h), l.h);
    const bl = snap_zone_bounds(.bottom_left, fb_w, fb_h, taskbar_h).?;
    try std.testing.expectEqual(@as(u32, (fb_h - taskbar_h) / 2), bl.y);

    // Tile layout: master gets 667/1000 of the usable width; sides flip.
    const tl = tile_layout(fb_w, fb_h, taskbar_h, dock_w, 667, true);
    const usable_w = fb_w - dock_w; // 1256
    try std.testing.expectEqual(@as(u32, 1256), usable_w);
    try std.testing.expectEqual(@as(u32, 837), tl.master_w); // 1256*667/1000
    try std.testing.expectEqual(@as(u32, 419), tl.detail_w); // 1256-837
    try std.testing.expectEqual(@as(u32, 24), tl.master_x); // dock left
    try std.testing.expectEqual(@as(u32, 24 + 837), tl.detail_x);
    try std.testing.expectEqual(@as(u32, fb_h - taskbar_h), tl.h);
    const tr = tile_layout(fb_w, fb_h, taskbar_h, dock_w, 667, false);
    try std.testing.expectEqual(@as(u32, 24 + 419), tr.master_x); // master right
    try std.testing.expectEqual(@as(u32, 24), tr.detail_x);

    // Maximize: the workspace area (dock + taskbar excluded).
    const mx = maximize_rect(fb_w, fb_h, taskbar_h, dock_w);
    try std.testing.expectEqual(@as(u32, 24), mx.x);
    try std.testing.expectEqual(@as(u32, 0), mx.y);
    try std.testing.expectEqual(@as(u32, fb_w - 24), mx.w);
    try std.testing.expectEqual(@as(u32, fb_h - taskbar_h), mx.h);

    // Fullscreen: the ENTIRE scanout.
    const fs = fullscreen_rect(fb_w, fb_h);
    try std.testing.expectEqual(@as(u32, 0), fs.x);
    try std.testing.expectEqual(@as(u32, fb_w), fs.w);
    try std.testing.expectEqual(@as(u32, fb_h), fs.h);

    // WMS8 Gate 4 (issue #628): the unsaved-dialog button hit-test — the
    // 200x100 centered dialog with Save / Don't Save / Cancel on the bottom
    // row (x=540, y=310 on the 1280x720 scanout; buttons at y 380..400).
    const dx = (fb_w - 200) / 2; // 540
    const dy = (fb_h - 100) / 2; // 310
    try std.testing.expectEqual(@as(u32, 540), dx);
    try std.testing.expectEqual(@as(u32, 310), dy);
    try std.testing.expectEqual(UnsavedChoice.save, unsaved_dialog_choice_at(fb_w, fb_h, dx + 40, dy + 80));
    try std.testing.expectEqual(UnsavedChoice.dont_save, unsaved_dialog_choice_at(fb_w, fb_h, dx + 120, dy + 80));
    try std.testing.expectEqual(UnsavedChoice.cancel, unsaved_dialog_choice_at(fb_w, fb_h, dx + 175, dy + 80)); // the 30px Cancel (review fix 7639)
    try std.testing.expectEqual(UnsavedChoice.none, unsaved_dialog_choice_at(fb_w, fb_h, dx + 40, dy + 40)); // outside the buttons
    try std.testing.expectEqual(UnsavedChoice.none, unsaved_dialog_choice_at(fb_w, fb_h, dx + 85, dy + 80)); // between Save/Don't Save
    try std.testing.expectEqual(UnsavedChoice.none, unsaved_dialog_choice_at(fb_w, fb_h, dx + 195, dy + 80)); // past the 30px Cancel (review fix 7639)
}

test "wnd_core: chrome descriptor is a flat number struct (the frozen ABI, v2 backward-compatible)" {
    try std.testing.expectEqual(@as(usize, 40), chrome_desc_bytes);
    try std.testing.expectEqual(@as(usize, 44), chrome_desc_bytes_v2);
    try std.testing.expectEqual(@as(usize, 44), @sizeOf(ChromeDesc));
    // extern struct: no padding beyond the 11 u32s — the byte layout the
    // EL0 blob and the kernel both compile from.
    try std.testing.expectEqual(@as(usize, 11 * 4), @sizeOf(ChromeDesc));
    const p = chrome_parity_policy();
    // The broadcast id is the frozen "all windows" target.
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF), chrome_window_all);
    // Parity values: the dark-theme chrome the shim renders today.
    try std.testing.expectEqual(@as(u32, 0x0c1826), p.border_rgb);
    try std.testing.expectEqual(@as(u32, 0x475569), p.border_unfocus_rgb);
    try std.testing.expectEqual(@as(u32, 0x1a2b3c), p.title_bg_rgb);
    try std.testing.expectEqual(@as(u32, 0xffffff), p.title_fg_rgb);
    try std.testing.expectEqual(@as(u32, 0x3b82f6), p.ring_rgb);
    try std.testing.expectEqual(@as(u32, 0xef4444), p.close_rgb);
    try std.testing.expectEqual(@as(u32, 0x94a3b8), p.min_rgb);
    try std.testing.expectEqual(@as(u32, 0x38bdf8), p.pin_rgb);
    // WM4 ABI v2: the rest-alpha tail defaults to opaque (256) — a v1
    // (40-byte) descriptor zero-extends to rest_alpha = 0, which
    // normalizes to 256, so the v1 behavior is byte-identical.
    try std.testing.expectEqual(@as(u32, 256), p.rest_alpha);
    try std.testing.expectEqual(@as(u32, 256), chrome_rest_alpha_normalized(p));
    var v1 = p;
    v1.rest_alpha = 0;
    try std.testing.expectEqual(@as(u32, 256), chrome_rest_alpha_normalized(v1));
    try std.testing.expect(chrome_valid(v1));
    // A real rest policy: below-256 alpha validates; above does not.
    var v2 = p;
    v2.rest_alpha = 240;
    try std.testing.expect(chrome_valid(v2));
    try std.testing.expectEqual(@as(u32, 240), chrome_rest_alpha_normalized(v2));
    v2.rest_alpha = 257;
    try std.testing.expect(!chrome_valid(v2));
}

test "wnd_core: tab item layout and cycle rules" {
    // 1. Tab rects layout
    const tr0 = tab_item_rect(100, 100, 300, 0, 3);
    const tr1 = tab_item_rect(100, 100, 300, 1, 3);
    const tr2 = tab_item_rect(100, 100, 300, 2, 3);
    try std.testing.expectEqual(@as(u32, 100), tr0.x);
    try std.testing.expectEqual(@as(u32, 200), tr1.x);
    try std.testing.expectEqual(@as(u32, 300), tr2.x);
    try std.testing.expectEqual(@as(u32, 100), tr0.w);
    try std.testing.expectEqual(@as(u32, 22), tr0.h);

    // 2. Tab cycling
    const tabs = [_]TabItem{
        .{ .window_id = 2, .parent_id = 0, .active = true },
        .{ .window_id = 3, .parent_id = 2, .active = false },
        .{ .window_id = 4, .parent_id = 2, .active = false },
    };
    try std.testing.expectEqual(@as(?u8, 3), cycle_next_tab(&tabs, 2));
    try std.testing.expectEqual(@as(?u8, 4), cycle_next_tab(&tabs, 3));
    try std.testing.expectEqual(@as(?u8, 2), cycle_next_tab(&tabs, 4));
    // Non-tabbed window
    try std.testing.expectEqual(@as(?u8, null), cycle_next_tab(&tabs, 5));
}

test "wnd_core: DQ2 tab-strip chrome geometry (strip row, title truncation, close box, hit-test)" {
    // Strip sits exactly one title band below the window top, full width.
    const strip = tab_strip_rect(100, 200, 400);
    try std.testing.expectEqual(@as(u32, 100), strip.x);
    try std.testing.expectEqual(@as(u32, 200 + title_bar_h), strip.y);
    try std.testing.expectEqual(@as(u32, 400), strip.w);
    try std.testing.expectEqual(@as(u32, tab_bar_height), strip.h);

    // Cells tile the strip via the shared tab_item_rect (strip origin).
    const c0 = tab_item_rect(strip.x, strip.y, strip.w, 0, 2);
    const c1 = tab_item_rect(strip.x, strip.y, strip.w, 1, 2);
    try std.testing.expectEqual(@as(u32, 100), c0.x);
    try std.testing.expectEqual(@as(u32, 300), c1.x);
    try std.testing.expectEqual(@as(u32, 200), c0.w);
    try std.testing.expectEqual(@as(u32, 216), c0.y); // 200 + title_bar_h(16)

    // Narrow window: cells clamp to 48px min and clip at the right edge.
    const n0 = tab_item_rect(0, 16, 100, 0, 4);
    const n3 = tab_item_rect(0, 16, 100, 3, 4);
    try std.testing.expectEqual(@as(u32, 48), n0.w);
    try std.testing.expectEqual(@as(u32, 0), n3.w); // saturating tail clip

    // Title truncation reserves the close glyph: wide fits, narrow clips.
    const wt = tab_title_layout(200, 10);
    try std.testing.expect(!wt.truncated);
    try std.testing.expectEqual(@as(usize, 10), wt.draw_len);
    const nt = tab_title_layout(60, 20);
    try std.testing.expect(nt.truncated);
    try std.testing.expect(nt.draw_len < 20);

    // Close box: right-aligned inside the cell, 12x12.
    const cb = tab_close_rect(c0);
    try std.testing.expectEqual(@as(u32, 12), cb.w);
    try std.testing.expectEqual(@as(u32, 12), cb.h);
    try std.testing.expectEqual(c0.x + c0.w - 12, cb.x);
    try std.testing.expect(cb.y >= c0.y and cb.y + cb.h <= c0.y + c0.h);

    // Hit-test: edges exclusive on the far side, inclusive on the near.
    try std.testing.expect(tab_rect_contains(c0, 100, 216));
    try std.testing.expect(tab_rect_contains(c0, 299, 237));
    try std.testing.expect(!tab_rect_contains(c0, 300, 216)); // next cell
    try std.testing.expect(!tab_rect_contains(c0, 100, 238)); // below strip
    try std.testing.expect(!tab_rect_contains(c0, 99, 216)); // left of strip
}

test "wnd_core: WM3 taskbar entry layout — rects, hit-test, tray clamp, title slice" {
    // Entries start right of the 3-cell switcher (4 + 3*24 + 4 = 80).
    try std.testing.expectEqual(@as(u32, 80), taskbar_entries_x0(3));
    // Entry 0: the bar's inner band (720-20+2 .. 720-2), 80px wide.
    const r0 = taskbar_entry_rect(0, 3, fb_w, fb_h, 80).?;
    try std.testing.expectEqual(@as(u32, 80), r0.x);
    try std.testing.expectEqual(@as(u32, 702), r0.y);
    try std.testing.expectEqual(@as(u32, 80), r0.w);
    try std.testing.expectEqual(@as(u32, 16), r0.h);
    // Entry 1 strides by width+gap; the tray clamp: 12 entries fit left of
    // the tray (the bar's right 80px), the 13th would reach it — refused.
    const r1 = taskbar_entry_rect(1, 3, fb_w, fb_h, 80).?;
    try std.testing.expectEqual(@as(u32, 164), r1.x);
    try std.testing.expect(taskbar_entry_rect(12, 3, fb_w, fb_h, 80) != null);
    try std.testing.expect(taskbar_entry_rect(13, 3, fb_w, fb_h, 80) == null);
    // The tray clamp tracks the scanout: at the taskbar's top edge the
    // band is empty; py inside is required.
    try std.testing.expect(taskbar_entry_at(3, fb_w, fb_h, 80, 100, fb_h - taskbar_h - 1) == null);
    try std.testing.expect(taskbar_entry_at(3, fb_w, fb_h, 80, 100, fb_h) == null);
    try std.testing.expectEqual(@as(u32, 0), taskbar_entry_at(3, fb_w, fb_h, 80, 100, fb_h - 10).?);
    try std.testing.expectEqual(@as(u32, 1), taskbar_entry_at(3, fb_w, fb_h, 80, 168, fb_h - 10).?);
    // Edges exclusive on the far side; past the last entry (tray clamp) null.
    try std.testing.expectEqual(@as(u32, 0), taskbar_entry_at(3, fb_w, fb_h, 80, 80, fb_h - 10).?);
    try std.testing.expect(taskbar_entry_at(3, fb_w, fb_h, 80, 160, fb_h - 10) == null);
    try std.testing.expect(taskbar_entry_at(3, fb_w, fb_h, 80, fb_w - 40, fb_h - 10) == null);
    // Title slice: short titles pass through, long ones clip to 8 chars.
    try std.testing.expectEqualStrings("Calc", taskbar_title_slice("Calc"));
    try std.testing.expectEqualStrings("NOTEPAD1", taskbar_title_slice("NOTEPAD12345"));
    try std.testing.expectEqual(@as(usize, 8), taskbar_entry_max_chars);
}

test "wnd_core: WM2 overview grid layout is pinned (shared kernel/WM rule)" {
    // 1280x720 scanout: usable = 1256 wide (minus dock), strip at y=672.
    const g4 = overview_grid(4, fb_w, fb_h, taskbar_h, dock_w);
    try std.testing.expectEqual(@as(u32, 2), g4.cols);
    try std.testing.expectEqual(@as(u32, 2), g4.rows);
    try std.testing.expectEqual(@as(u32, 616), g4.card_w); // (1256-24)/2
    try std.testing.expectEqual(@as(u32, 324), g4.card_h); // (672-24)/2
    try std.testing.expectEqual(@as(u32, 32), g4.x0); // dock + gap
    try std.testing.expectEqual(@as(u32, 8), g4.y0);
    try std.testing.expectEqual(@as(u32, 672), g4.strip_y); // 720-20-28

    // Card rects tile row-major with 8px gaps.
    const c0 = overview_card_rect(g4, 0);
    try std.testing.expectEqual(@as(u32, 32), c0.x);
    try std.testing.expectEqual(@as(u32, 8), c0.y);
    const c1 = overview_card_rect(g4, 1);
    try std.testing.expectEqual(@as(u32, 656), c1.x); // 32+616+8
    try std.testing.expectEqual(@as(u32, 8), c1.y);
    const c3 = overview_card_rect(g4, 3);
    try std.testing.expectEqual(@as(u32, 656), c3.x);
    try std.testing.expectEqual(@as(u32, 340), c3.y); // 8+324+8

    // 8 windows: 3x3 grid.
    const g8 = overview_grid(8, fb_w, fb_h, taskbar_h, dock_w);
    try std.testing.expectEqual(@as(u32, 3), g8.cols);
    try std.testing.expectEqual(@as(u32, 3), g8.rows);
    try std.testing.expectEqual(@as(u32, 408), g8.card_w); // (1256-32)/3
    try std.testing.expectEqual(@as(u32, 213), g8.card_h); // (672-32)/3

    // 1 window: one near-full-area card.
    const g1 = overview_grid(1, fb_w, fb_h, taskbar_h, dock_w);
    try std.testing.expectEqual(@as(u32, 1), g1.cols);
    try std.testing.expectEqual(@as(u32, 1), g1.rows);
    try std.testing.expectEqual(@as(u32, 1240), g1.card_w);
    try std.testing.expectEqual(@as(u32, 656), g1.card_h);

    // 0 windows: empty grid, strip still placed.
    const g0 = overview_grid(0, fb_w, fb_h, taskbar_h, dock_w);
    try std.testing.expectEqual(@as(usize, 0), g0.n);
    try std.testing.expectEqual(@as(u32, 672), g0.strip_y);

    // Over-ceiling clamps to 8.
    const g9 = overview_grid(9, fb_w, fb_h, taskbar_h, dock_w);
    try std.testing.expectEqual(@as(usize, 8), g9.n);
    try std.testing.expectEqual(@as(u32, 3), g9.cols);
}

test "wnd_core: WM2 overview hit-testing (cards + workspace buttons)" {
    const g4 = overview_grid(4, fb_w, fb_h, taskbar_h, dock_w);
    // Card centers hit their index.
    try std.testing.expectEqual(@as(?usize, 0), overview_card_at(g4, 100, 100));
    try std.testing.expectEqual(@as(?usize, 1), overview_card_at(g4, 900, 100));
    try std.testing.expectEqual(@as(?usize, 2), overview_card_at(g4, 100, 500));
    try std.testing.expectEqual(@as(?usize, 3), overview_card_at(g4, 900, 500));
    // Gaps miss (between card 0 and card 1: x 648..656).
    try std.testing.expectEqual(@as(?usize, null), overview_card_at(g4, 650, 100));
    // The strip is not a card.
    try std.testing.expectEqual(@as(?usize, null), overview_card_at(g4, 640, 690));
    // Card edges: near-inclusive, far-exclusive.
    try std.testing.expectEqual(@as(?usize, 0), overview_card_at(g4, 32, 8));
    try std.testing.expectEqual(@as(?usize, null), overview_card_at(g4, 648, 8));

    // Workspace buttons: three equal parts of the usable width.
    try std.testing.expectEqual(@as(?u8, 0), overview_ws_button_at(g4, fb_w, dock_w, 100, 690));
    try std.testing.expectEqual(@as(?u8, 1), overview_ws_button_at(g4, fb_w, dock_w, 640, 690));
    try std.testing.expectEqual(@as(?u8, 2), overview_ws_button_at(g4, fb_w, dock_w, 1100, 690));
    // Above the strip (cards) and below it (taskbar) miss.
    try std.testing.expectEqual(@as(?u8, null), overview_ws_button_at(g4, fb_w, dock_w, 640, 660));
    try std.testing.expectEqual(@as(?u8, null), overview_ws_button_at(g4, fb_w, dock_w, 640, 710));
    // Button rects: 418px thirds starting past the dock.
    const b0 = overview_ws_button_rect(0, fb_w, dock_w, g4.strip_y);
    try std.testing.expectEqual(@as(u32, 24), b0.x);
    try std.testing.expectEqual(@as(u32, 418), b0.w);
    try std.testing.expectEqual(@as(u32, 672), b0.y);
    try std.testing.expectEqual(@as(u32, 28), b0.h);
}
