//! Milestone six card G5 (claim 1543) — Driving Award, the window manager.
//!
//! A bounded window registry (fixed BSS, no heap) with z-order, focus,
//! hit-testing, and a dirty-rect compositor that blits window buffers into
//! the G1 framebuffer (kernel/src/virtio_gpu.zig). Road Pops — the G3 boot
//! terminal (kernel/src/text.zig, kernel/src/road_pops.zig) — is the FIRST
//! window (window 0, a full-screen terminal); a second demo window (a 1 Hz
//! clock) overlaps its top-right corner and proves multiple windows with
//! distinct content + focus.
//!
//! Z-order is the registry array order (index 0 = bottom, the last index =
//! top). `raise` moves a window to the top; focus is tracked by window id
//! (stable across raises), and `hit_test` returns the TOPMOST visible window
//! containing a point. The compositor repaints from the lowest dirty window
//! upward — a genuine dirty-rect redraw: a window whose content did not
//! change is never repainted, and the scanout transfer + flush run once per
//! dirty batch (the G1/G2/G3 full-frame present discipline).
//!
//! Window 0 (the terminal) renders the shared text layer straight into the
//! scanout framebuffer (its "buffer" IS the framebuffer — a terminal
//! redraws its full client area, which here is the whole screen). Window 1
//! (the clock) renders into its own fixed BSS back-buffer, which the
//! compositor blits over the terminal. Because the terminal's repaint
//! covers the clock's region, the compositor repaints from the lowest dirty
//! window UP, so the clock is always re-blitted over a freshly repainted
//! terminal — the classic overlay-preserving order.
//!
//! Input routing (the I3 path): keyboard bytes reach the Road Pops line
//! editor only while the terminal window is focused (`terminal_focused`);
//! when another window holds focus the keystrokes simply queue in the input
//! FIFO until the terminal regains focus. Serial (the scripted evidence
//! channel) stays an always-wired fallback, unchanged.
//!
//! No libc, no POSIX, no allocation, no function pointers in any const
//! table (the claim-0015 discipline — the registry is a BSS array built at
//! runtime).
//!
//! Host tests pin the pure contracts: hit-test, z-order/raise, focus, the
//! repaint-from-lowest-dirty plan, the clock rendering, and the blit.

pub const std = @import("std");
pub const builtin = @import("builtin");
pub const alloc = @import("alloc.zig"); // WM1 (#707, claim 919): pool-backed user back-buffers
pub const memmap = @import("memmap.zig"); // WM1: the test-pool descriptor (is_test only)
pub const font = @import("font8x8.zig");
pub const font_unicode = @import("font_unicode.zig"); // M73a-2 (#1631): the shared codepoint→glyph table + U+FFFD fallback art
pub const font_metrics = @import("font_metrics.zig"); // M73l (#1661): THE cell geometry — no terminal geometry literal says 8
pub const font_atlas = @import("font_atlas_data.zig"); // M73l (#1661): the generated FiraCode cell atlas
pub const input = @import("input.zig"); // card U4 (claim 4993): the pointer reports
pub const virtio_gpu = @import("virtio_gpu.zig");
pub const fbtext = @import("text.zig");
pub const events = @import("events.zig"); // Milestone 9 (claim 9228): application events
pub const clipboard = @import("clipboard.zig"); // Arc2 W3 (claim 1264): tray clipboard indicator
pub const virtio_snd = @import("virtio_snd.zig"); // M27 G5 (#448): action sound feedback
pub const settings = @import("settings.zig");
pub const klog = @import("klog.zig"); // issue #990 (claim #997): the serial-log seam (hook armed by main.zig)
pub const geom = @import("wnd_core.zig"); // M32 WMS3 (issue #623): the shared pure rules (hit-test / workspace / clamps / title-layout) — compiled by the kernel AND the WM server so they cannot drift
pub const process = @import("process.zig"); // #1056 item 2: resolve a window's owning process name (the non-tabapp tab-title fallback)
pub const terminal = @import("terminal.zig"); // #1082 (ADR 0020 A4/A6): window-bound terminal grid + close auto-detach
pub const gpu3d_broker = @import("gpu3d_broker.zig"); // M102d1 (#2166): window death revokes its GPU3D context (remove_user_at)
const gpu3d_compute = @import("gpu3d_compute.zig"); // M111b (#2409): owner death revokes its compute session (close_owner)

/// M27 G13: Focus-follows-mouse configuration and dialog previous-focus tracking
pub var focus_follows_mouse: bool = false;
pub var previous_focus: ?u8 = null;
// ---------------------------------------------------------------------------

/// Bounded window registry size (fixed BSS: 4 fixed windows + the WM1
/// user ceiling of 8 + one spare, mirroring the pre-WM1 4+4+1 sizing).
pub const max_windows: usize = 13;

/// The clock window: an overlay in the terminal's top-right corner. 304x192
/// at (960,16) — inside the 1280x720 scanout, overlapping the terminal.
pub const clock_x: u32 = 960;
pub const clock_y: u32 = 16;
pub const clock_w: u32 = 304;
pub const clock_h: u32 = 192;

/// Clock palette (0xRRGGBB) — deliberately distinct from the terminal's
/// green-on-dark so the live gate can tell the two windows apart by pixel.
pub const clock_border_rgb: u32 = 0x8899aa;
pub const clock_title_bg_rgb: u32 = 0xb58900; // amber title bar
pub const clock_title_fg_rgb: u32 = 0x141414;
pub const clock_bg_rgb: u32 = 0x0a1a2e; // dark navy body
pub const clock_fg_rgb: u32 = 0xd8dee9; // light body text
pub const clock_accent_rgb: u32 = 0xffaa00; // amber accent (mascot line)

/// Card U5 (claim 0935, ADR 0008 D4): the HIG chrome palette. The focus
/// ring is white (distinct from every window fill); the user title bar
/// reuses the window-manager's dark blue with white text.
pub const focus_ring_rgb: u32 = 0xffffff;
pub const focus_ring_w: usize = 3;
/// M32 WMS5: the title-bar band height — single source is wnd_core (the
/// WM server's drag hit-test uses the SAME number). Re-export, not a
/// second constant.
pub const user_title_h: usize = geom.title_bar_h;
pub const user_title_bg_rgb: u32 = 0x1a2b3c;
pub const user_title_fg_rgb: u32 = 0xffffff;
pub const cursor_rgb: u32 = 0xffffff;
pub const cursor_outline_rgb: u32 = 0x101018;
pub const cursor_w: usize = 16;
pub const cursor_h: usize = 24;
/// Pointer coordinates and hit tests name the arrow tip, not its bitmap origin.
pub const cursor_hotspot = struct { x: u32, y: u32 }{ .x = 1, .y = 1 };
pub const cursor_mask = [_][]const u8{
    "................",
    ".#..............",
    ".##.............",
    ".#o#............",
    ".#oo#...........",
    ".#ooo#..........",
    ".#oooo#.........",
    ".#ooooo#........",
    ".#oooooo#.......",
    ".#ooooooo#......",
    ".#oooooooo#.....",
    ".#ooooooooo#....",
    ".#oooooooooo#...",
    ".#ooooooooooo#..",
    ".#oooooooooooo#.",
    ".#oooooo#######.",
    ".#oooo#o#.......",
    ".#ooo#.o#.......",
    ".#oo#..#o#......",
    ".#o#...#o#......",
    ".##.....#o#.....",
    ".#......#o#.....",
    ".........##.....",
    "................",
};

/// Card G6 (claim 0487) + WM1 (#707, claim 919): user windows — the
/// draw/window syscall seam. EIGHT user windows (ids 2..9,
/// `user_window_id_base`), each with a per-window B8G8R8X8 back-buffer
/// exactly win.w × win.h, carved from the kernel page pool at
/// `sys_win_open` and freed at close/`close_owner` (near-zero standing
/// BSS — the fixed `user_bufs` BSS is gone). An EL0 program renders into
/// its buffer through `sys_win_fill` / `sys_win_present`; the kernel owns
/// the pages. Zero new slots.
pub const user_window_id_base: u8 = 2;
pub const user_windows_max: usize = 8;
/// WM1: the absolute per-window geometry cap is the scanout itself (a
/// window must fit on screen anyway — `user_open` enforces x+w/y+h). The
/// binding memory constraint is pool availability (`.nomem`), not BSS.
/// (The 512×424 cap died with the fixed BSS buffers; the WM-side mirror
/// `wnd_core.user_buf_w/h` proposal clamp is WM2/WM3 follow-up.)
pub const user_win_max_w: u32 = virtio_gpu.fb_width;
pub const user_win_max_h: u32 = virtio_gpu.fb_height;

/// Step 8 (Issue #211): the system taskbar at the bottom of the scanout.
/// M32 WMS5 Gate 2 (claim 4278): single-sourced with the WM server —
/// wnd_core owns the number; this re-exports it (the drift guard).
pub const taskbar_h: u32 = geom.taskbar_h;
pub const taskbar_y: u32 = virtio_gpu.fb_height - taskbar_h;
pub const taskbar_bg_rgb: u32 = 0x0f172a;
pub const taskbar_entry_active_rgb: u32 = 0x3b82f6;
pub const taskbar_entry_dimmed_rgb: u32 = 0x1e293b;

/// Arc2 W3 (claim 1264, #226): system tray — right 80px of 20px taskbar at y=700.
/// HH:MM from tick, D/L/A theme letter in accent, filled/empty clipboard rect.
/// Clock ticks on composite() without timer; migrates Kind.clock id 1 (no duplicate).
pub const tray_w: u32 = 80;
pub const tray_x: u32 = virtio_gpu.fb_width - tray_w;
pub const tray_h: u32 = taskbar_h;
pub const tray_y: u32 = taskbar_y;

/// M15 C4 (Dock, #229): 24 px left dock, topmost fixed layer. M32 WMS5
/// Gate 2 (claim 4278): single-sourced with the WM server via wnd_core.
pub const dock_w: u32 = geom.dock_w;
pub const dock_x: u32 = 0;
pub const dock_y: u32 = 0;
pub const dock_h: u32 = virtio_gpu.fb_height - taskbar_h;
pub const dock_bg_rgb: u32 = 0x0f172a;
pub const dock_icon_bg_rgb: u32 = 0x1e293b;
pub const dock_icon_active_rgb: u32 = 0x3b82f6;

/// Step 9 (Issue #212): the desktop wallpaper gradient.
pub const wallpaper_top_rgb: u32 = 0x1a1a2e;
pub const wallpaper_bot_rgb: u32 = 0x0a0a14;

/// The window-kind tags (the terminal and the demo window).
pub const Kind = enum {
    terminal,
    clock,
    user,
    taskbar,
    wallpaper,
    dock,
};

/// One window in the registry. Value type; the registry is a fixed BSS
/// array. `title` is a static string literal (data, never a function
/// pointer — safe at any load base).
pub const Window = struct {
    id: u8,
    title: []const u8,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    kind: Kind,
    visible: bool,
    dirty: bool,
    /// M33 SB4 (claim 2382): rect-granular damage. `damaged` means the
    /// tracked `dx/dy/dw/dh` union is valid; when false the whole window
    /// is treated as dirty (the pre-SB4 whole-window repaint), so every
    /// existing `.dirty = true` site keeps its current behavior. `user_fill`
    /// sets the EXACT written rect so composite repaints only that region.
    damaged: bool = false,
    dx: u32 = 0,
    dy: u32 = 0,
    dw: u32 = 0,
    dh: u32 = 0,
    /// M33 SB4 (claim 2382): the LAST damage rect composite consumed (what
    /// paint() actually repainted) — populated with the exact rect for a
    /// partial repaint; 0,0,0,0 means no partial repaint was recorded yet
    /// (whole-window or never). Makes the rect-granular gate observable on
    /// serial even AFTER the drain consumes the pending damage (no race).
    last_dx: u32 = 0,
    last_dy: u32 = 0,
    last_dw: u32 = 0,
    last_dh: u32 = 0,
    /// Card G6 teardown follow-on (per-process ownership): the owning
    /// process id for a `.user` window (null for the fixed terminal +
    /// clock, which are kernel-owned). The syscall layer records the
    /// caller here at `sys_win_open`, restricts fill/present/close to the
    /// owner, and the exit path auto-closes the owner's windows via
    /// `close_owner` — a real teardown semantic instead of a window that
    /// leaks until reboot.
    owner: ?usize = null,
    /// Arc4 #239: animated window fade-in. 0=none (fully opaque),
    /// 1=fade-in active. The paint path applies per-pixel alpha
    /// blending during the fade frames.
    fade_phase: u8 = 0,
    fade_tick: u8 = 0,
    /// Arc4 #241: workspace assignment. 0..2 = workspace, fixed layers
    /// are always workspace 0 (visible on all).
    workspace: u8 = 0,
    /// Arc4 #242: unsaved-changes flag. The compositor shows a
    /// confirmation dialog when the user clicks close on a dirty window.
    unsaved: bool = false,
    /// M21 W3: minimized flag. Minimized windows don't paint, don't
    /// receive events, and are skipped by Alt+Tab. The dock icon shows
    /// the restore action when minimized.
    minimized: bool = false,
    /// M21 W6: maximized flag. Maximised windows fill the workspace area
    /// (screen minus taskbar and dock). Title bar stays visible.
    maximized: bool = false,
    /// M21 W8: always-on-top flag. Always-on-top windows render above
    /// all normal windows in the z-order, regardless of focus.
    always_on_top: bool = false,
    /// M21 W15: modal flag. Modal windows block input to windows below.
    /// Used by dialogs, context menus, dropdowns, popups.
    modal: bool = false,
    /// M21 W16: transient flag. Transient windows are short-lived popups
    /// that auto-close on timeout or click-outside.
    transient: bool = false,
    transient_timeout: u32 = 0,
    /// M21 W12: dynamic title buffer. Apps set this via sys_win_set_title.
    /// `title` points here when a dynamic title is set; otherwise it
    /// points to a static string literal. 64 bytes — enough for "NOTEPAD -
    /// filename.txt (*)" plus room.
    title_buf: [64]u8 = @as([64]u8, @splat(@as(u8, 0))),
    title_len: u8 = 0,
    /// M37 DQ2 (issue #840): tab-group fact mirrored from the WM's
    /// validated ATTACH_TAB/DETACH_TAB calls (the WM owns grouping and
    /// layout; the kernel records which container a window is attached to
    /// so draw_chrome can paint the strip — facts, not policy, exactly
    /// like the tooltip text the WM pushes for the kernel to blit).
    /// 0 = standalone/container. Orphans reset here on close.
    tab_parent: u8 = 0,
    /// M32 WMS4 (issue #624): the WM server's chrome descriptor for THIS
    /// window (a per-window SET_WINDOW override). When invalid, the draw
    /// path falls back to the broadcast policy, then to the shim's own
    /// rules — the two paths coexist behind the presence of WM chrome.
    chrome_valid: bool = false,
    chrome: geom.ChromeDesc = undefined,
    /// M33 SB3 (claim 9361): when a `.user` window is SURFACE-BACKED, its
    /// rendering lives in a shared-anonymous region (M33_MAP_SHARED) instead
    /// of the kernel `user_bufs[id]` copy. The kernel records the region's
    /// handle + physical base here so `composite()` blits from the surface's
    /// OWN pages (identity-mapped into the kernel root) and the registered WM
    /// mirrors the same region RO. 0 = unmigrated (frozen kernel-buffer path,
    /// byte-identical to pre-SB3). The surface is owned by the WINDOW's owner
    /// pid; close/owner-exit drops the binding and revokes the WM mirror.
    surface_handle: u32 = 0,
    /// Physical base of the shared surface (for composite's direct blit).
    surface_pa: u64 = 0,
    /// Page count of the shared surface (for composite's source bounds).
    surface_pages: u32 = 0,
    /// WM1 (#707, claim 919): the pool-backed kernel back-buffer, exactly
    /// win.w × win.h B8G8R8X8. `kbuf_pa` is the pool physical base (the
    /// kernel is identity-mapped, so it is directly dereferenceable on
    /// device); `kbuf_pages` is the accounted span for the free path.
    /// pa == 0 means no buffer (fixed windows, or a `.user` between struct
    /// init and `user_open` storing the allocation — never observable).
    kbuf_pa: u64 = 0,
    kbuf_pages: u32 = 0,
    /// WM1 host-test seam: `zig test` cannot dereference pool physical
    /// addresses, so the CPU-visible bytes live in the test-arena bump
    /// allocation instead (freed implicitly by the per-test reset in
    /// arm()). Production builds never read it; `kbuf_ptr` selects.
    /// 8 B × 13 windows of BSS — noise against the removed 3.3 MB.
    kbuf_test: ?[*]u8 = null,
};

/// Arc4 #239: fade-in constants. The window is at 25% opacity for
/// `fade_half_frames` composites, then 50% for the same count, then
/// fully opaque. Total fade-in = 2 × fade_half_frames composites.
pub const fade_half_frames: u8 = 2;

// ---------------------------------------------------------------------------
// Registry state (fixed BSS)
// ---------------------------------------------------------------------------

pub var windows: [max_windows]Window = undefined;
pub var win_count: usize = 0;
/// Focused window id (stable across raises); 0xff = none.
pub var focused_id: u8 = 0xff;
pub var armed_global: bool = false;
/// M32 WMS5 (issue #625, claim 9849): while a WM is registered it owns
/// pointer geometry — `pointer_tick` keeps tracking the cursor (a kernel
/// blit surface) but skips ALL geometry consumption (drag, resize, snap,
/// focus-at, minimize/close buttons) and instead fans the raw stream out
/// through `wm_pointer_hook`. Flipped by `wm_server.register/unregister`;
/// false in shim mode (the default VM) → byte-identical to pre-WMS5.
pub var wm_owns_input: bool = false;
/// M33 SB5 (claim 7397): the registered WM owns the migrated USER layer —
/// true once the WM has bound the scanout (wm_server.scanout_bind) and false
/// after teardown/unbind. While true, paint_scene() SKIPS surface-backed
/// (migrated) user windows: their bytes are already in the scanout via the
/// WM's compose-N stores (written between the COMPOSITE_TICK and the final
/// present), so a kernel blit would double-draw them.
pub var wm_owns_user_layer: bool = false;
/// M33 SB6 (claim 6864): how many `.user` windows paint_scene actually
/// BLITTED (the pre-seam-B composite cost) vs how many surface-backed
/// (migrated) windows were SKIPPED while the WM owns the user layer (the
/// seam-B saving). Monotonic per boot; the gate diffs snapshots.
pub var user_blits: u64 = 0;
pub var migrated_skips: u64 = 0;
/// The raw-pointer fan-out (set by wm_server at REGISTER time; null when
/// no WM — the hook style of `events.on_event_pushed`). Callback gets the
/// mapped fb pixels + the raw HID button byte; the WM edge-detects.
pub var wm_pointer_hook: ?*const fn (x: u32, y: u32, buttons: u8) void = null;
/// The last pointer state already fanned to the WM, in the hook's pixel
/// space. Shared by BOTH fan entry points — the per-report decode fan
/// (main.zig's cv_pointer_dispatch) and pointer_tick's state-sampling fan
/// — so a report one delivered is never repeated by the other.
var wm_fan_valid: bool = false;
var wm_fan_x: u32 = 0;
var wm_fan_y: u32 = 0;
var wm_fan_buttons: u8 = 0;

/// Fan ONE absolute-pointer state to the registered WM's kind-19 stream,
/// deduped against the last fanned state (mapped-pixel space — the hook's
/// coordinate contract — so identical reports and same-pixel logicals both
/// collapse, exactly like the tick sampler's moved/btn_changed check).
///
/// Two callers, one record: cv_pointer_dispatch calls this PER DECODED
/// REPORT — the used-ring pump can complete several reports in one idle
/// pass, and the tick's state sampling collapsed them to the last write
/// (observed on go-dogfood boot 08: a press batched with its first
/// held-move presented the MOVE's coordinates as the down edge — the app
/// saw a press off its list rows, the drag never armed, and the arm
/// markers never printed) — while pointer_tick calls it with the sampled
/// state, covering the USB path's one-report-per-pass decode and any
/// caller that bypassed the per-report fan. The keyboard seam has always
/// fanned per report (decode_keyboard_report -> wm_key_hook); this makes
/// the pointer seam symmetric.
pub fn wm_fan_pointer(x: u16, y: u16, buttons: u8) void {
    if (!wm_owns_input) return;
    const nx = map_pointer_axis(x, virtio_gpu.fb_width);
    const ny = map_pointer_axis(y, virtio_gpu.fb_height);
    if (wm_fan_valid and nx == wm_fan_x and ny == wm_fan_y and
        buttons == wm_fan_buttons) return;
    wm_fan_valid = true;
    wm_fan_x = nx;
    wm_fan_y = ny;
    wm_fan_buttons = buttons;
    if (wm_pointer_hook) |hook| hook(nx, ny, buttons);
}
/// The window-registry mirror fan-out (set by wm_server at REGISTER time;
/// null when no WM). Callback gets the id + full rect + state; wm_server
/// packs kind 20 WM_WINDOW. Called from the user-window mutation points.
/// M42 UX (2026-09-05): `released` marks a RELEASE mirror — the window has
/// left the registry (app self-exit / close_owner / user_close), not a
/// mere visibility change; wm_server encodes it as flags bit 13 (additive;
/// every existing bit is unchanged).
pub var wm_window_hook: ?*const fn (id: u8, x: u32, y: u32, w: u32, h: u32, visible: bool, focused: bool, workspace: u8, unsaved: bool, released: bool) void = null;
/// WMS5 Gate 2 (claim 4278): the raw-keyboard fan-out (set by wm_server at
/// REGISTER time; null when no WM — the hook style of the pointer/window
/// hooks). Callback gets the raw HID keyboard usage byte + the ADR 0009
/// modifier bits on key-DOWN edges; wm_server packs kind 21 WM_KEY. The
/// kernel's own keyboard geometry consumers are gated behind
/// `wm_owns_input` (shell idle), so the WM — not the kernel — decides.
pub var wm_key_hook: ?*const fn (usage: u8, flags: u16) void = null;
/// M32 WMS4: the WM's broadcast chrome policy (SET_WINDOW with a0 = ALL).
/// When set, every user window without its own override renders chrome
/// from this descriptor; null = no WM chrome (shim rules — the default
/// VM, zero-regression). New windows inherit it automatically via the
/// draw-time fallback.
pub var wm_chrome_policy: ?geom.ChromeDesc = null;
/// Scanout presents pushed by the compositor since arm.
pub var presents: usize = 0;

/// Arc4 #241: virtual desktop workspaces. Three workspaces (0, 1, 2).
/// The current workspace controls which user windows are visible.
/// Fixed layers (terminal, wallpaper, taskbar, dock) are visible on all.
pub const workspace_max: u8 = 3;
pub var current_workspace: u8 = 0;

/// Arc4 #241: switch to a workspace (0..2). Marks all windows dirty
/// so the compositor repaints the new visibility set.
pub fn switch_workspace(ws: u8) void {
    if (ws >= workspace_max) return;
    current_workspace = ws;
    // Mark all windows dirty so the compositor repaints.
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        windows[i].dirty = true;
    }
    _ = mark_dirty(0);
    _ = mark_dirty(1);
}

/// M21 W4: cycle to the next workspace (wrapping). Marks all windows
/// dirty so the compositor repaints the new visibility set.
pub fn cycle_workspace() void {
    const next = (current_workspace + 1) % workspace_max;
    switch_workspace(next);
}

/// Arc4 #241: check if a window is visible in the current workspace.
pub fn workspace_visible(w: *const Window) bool {
    // Delegated to the shared wnd_core rule (single source with the WM
    // server — the drift guard). Fixed layers are always visible.
    return geom.workspace_visible(to_geom(w), current_workspace);
}

/// The clock's back-buffer (fixed BSS, contiguous B8G8R8X8). The
/// compositor blits it over the terminal.
pub var clock_buf: [clock_w * clock_h * 4]u8 = undefined;
/// Card G6 (claim 0487): the user windows' back-buffers are WM1
/// pool-backed (see the `kbuf_*` Window fields) — no fixed BSS here.
/// WM1 host-test arena (compiled out on device): `zig test` cannot
/// dereference pool physical addresses, so the CPU-visible window bytes
/// live here instead. A bump allocator — free is a no-op and `arm()`
/// resets it per test, so cross-test leaks are impossible by
/// construction (std.testing.allocator would panic on free-after-leak-
/// report, verified empirically). 16 MB fits the hungriest single test
/// (8 windows + a fullscreen one ≈ 7 MB). Pool ACCOUNTING stays real —
/// alloc_pages/free_pages run in both builds and the close tests assert
/// the free-count round-trips.
pub const test_arena = if (builtin.is_test) struct {
    var buf: [16 * 1024 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = undefined;
    var ready: bool = false;
} else struct {};

/// WM1: the CPU-visible base of a `.user` window's kernel back-buffer —
/// the pool pages (the kernel identity-maps physical RAM, so `kbuf_pa`
/// dereferences directly) on device, the test-arena bytes on host. All
/// readers (fill, composite, preview) go through this so the host tests
/// prove the same pixel path the device executes.
pub fn kbuf_ptr(win: *const Window) [*]u8 {
    if (builtin.is_test) return win.kbuf_test orelse unreachable;
    return @as([*]u8, @ptrFromInt(win.kbuf_pa));
}

/// WM1: the byte length of a window's kernel back-buffer (w×h×4).
pub fn kbuf_bytes(w: u32, h: u32) usize {
    return @as(usize, w) * @as(usize, h) * 4;
}

/// WM1: pages spanned by `nbytes` (round up to the 4 KiB page).
pub fn kbuf_pages_for(nbytes: usize) u32 {
    return @intCast((nbytes + alloc.page_size - 1) / alloc.page_size);
}
/// The clock's displayed tick (so it only repaints when the second changes).
pub var clock_shown_tick: u64 = 0;
pub var clock_has_tick: bool = false;

/// Card U4 (claim 4993): the pointer cursor's framebuffer position. Hidden
/// until the first pointer report arrives (the default VM has no pointer).
pub var cursor_x: u32 = 0;
pub var cursor_y: u32 = 0;
pub var cursor_shown: bool = false;
pub const CursorRect = struct { x: u32, y: u32, w: u32, h: u32 };
pub var cursor_old_damage: ?CursorRect = null;
pub var cursor_new_damage: ?CursorRect = null;
var cursor_saved: [cursor_w * cursor_h]u32 = undefined;
var cursor_drawn: bool = false;
var cursor_drawn_x: u32 = 0;
var cursor_drawn_y: u32 = 0;
var cursor_drawn_resize: bool = false;
pub var prev_ptr_buttons: u8 = 0;
/// M49 SD5 (#1132): a terminal selection drag is in progress (pointer held
/// inside a terminal window's client area).
var term_sel_dragging: bool = false;

/// M49 SD5 (#1132): the terminal window under the pointer and the grid cell
/// (absolute line + column) it maps to, or null. Searches topmost first.
/// M73l: pub — the geometry gate calls it directly.
pub const TermHit = struct { win_id: u8, line: usize, col: usize, row: usize };

pub fn terminalHitAt(px: u32, py: u32) ?TermHit {
    var wi: usize = win_count;
    while (wi > 0) {
        wi -= 1;
        const w = &windows[wi];
        if (w.kind != .user or !w.visible) continue;
        const top_y = w.y + @as(u32, @intCast(user_title_h));
        if (px < w.x or px >= w.x + w.w) continue;
        if (py < top_y or py >= w.y + w.h) continue;
        const scr = terminal.screenForWindow(w.id) orelse continue;
        const rows_visible: usize = if (w.h > user_title_h) ((w.h - user_title_h) / font_metrics.cell_h) else 1;
        // M73k (#1637): `lineCount` is grid+history as one space — the
        // mirror of the painter's `lineCount - view - rows` walk, so a
        // click lands on the same row it paints (selection lives in
        // unified indices too).
        const total = scr.lineCount();
        const first: usize = if (total > scr.view + rows_visible) total - scr.view - rows_visible else 0;
        const row: usize = (py - top_y) / font_metrics.cell_h;
        const col: usize = (px - w.x) / font_metrics.cell_w;
        return .{ .win_id = w.id, .line = first + row, .col = col, .row = row };
    }
    return null;
}

/// M73i (#1635): does mouse tracking own this pointer position? Plain
/// (no Shift held) AND over a bound window with `?1000/1002/1003` on.
/// Every decision — report vs selection — asks this at ITS OWN coordinates:
/// the press latch and the cursor can disagree for one tick, and a per-tick
/// "did I just report?" flag cannot arbitrate between them. Shift — or
/// modes off — always leaves the pointer local (selection stays exact).
fn mouseOwnsAt(px: u32, py: u32) bool {
    if ((input.report().kb_mods & 0x22) != 0) return false; // L/R shift held
    const mh = terminalHitAt(px, py) orelse return false;
    const s = terminal.screenForWindow(mh.win_id) orelse return false;
    return s.mouse_1000 or s.mouse_1002 or s.mouse_1003;
}

/// M32 WMS8 Gate 6 (issue #628): title-bar drag + snap-on-drop state is
/// DELETED — WMS5 proved the WM owns pointer GEOMETRY: while registered it
/// fans the raw pointer (kind 19), hit-tests the title bar, and issues
/// SET_WINDOW rects (`user_move`); on release it snaps via its own mirror
/// + the shared wnd_core rule. With a WM seated the kernel's drag_id /
/// snap_zone tracking below was provably dormant (pointer_tick returns
/// early), so it is removed. RESIZE stays (the WM has no resize path).
/// Arc2 W1 (claim 3589, #224): drag-to-resize — 6×6 bottom-right corner.
/// Bounds + hit size are the shared wnd_core policy (single source with
/// the WM server).
pub const resize_min_w: u32 = geom.resize_min_w;
pub const resize_min_h: u32 = geom.resize_min_h;
pub const resize_hit_size: u32 = geom.resize_hit_size;
pub var resize_id: ?u8 = null;
pub var resize_start_x: u32 = 0;
pub var resize_start_y: u32 = 0;
pub var resize_origin_w: u32 = 0;
pub var resize_origin_h: u32 = 0;

/// Arc4 #237: drag-and-drop state — BSS, no heap.
/// The drag payload is copied from the source app via sys_drag_start,
/// then delivered to the target window on DROP via uaccess.
pub const drag_payload_max: usize = 512;
pub var drag_payload: [drag_payload_max]u8 = undefined;
pub var drag_payload_len: usize = 0;
pub var drag_active: bool = false;
pub var drag_source_pid: usize = 0;
pub var drag_over_id: ?u8 = null; // window currently under pointer during drag

/// Arc4 #237: store a drag payload from the source app (slot 48).
/// Called from the syscall handler.
pub fn drag_start(payload: []const u8, source_pid: usize) void {
    const copy_len = @min(payload.len, drag_payload_max);
    @memcpy(drag_payload[0..copy_len], payload[0..copy_len]);
    drag_payload_len = copy_len;
    drag_active = true;
    drag_source_pid = source_pid;
    drag_over_id = null;
}

/// Arc4 #237: check if a drag is currently active.
pub fn drag_is_active() bool {
    return drag_active;
}

/// Arc4 #237: get the drag payload for copy to target.
pub fn drag_get_payload() []const u8 {
    return drag_payload[0..drag_payload_len];
}

/// Arc4 #237: cancel an active drag (e.g. source window closed).
/// M52 card 3 (#1240): the source pid clears with the payload — a cancelled
/// drag must not leave state naming a process that may already be gone (the
/// DRAG_ENTER/LEAVE/DROP fans are gated on `drag_active`, so a stale pid was
/// inert, but "inert stale capture state" is exactly what this card bans).
pub fn drag_cancel() void {
    drag_active = false;
    drag_payload_len = 0;
    drag_source_pid = 0;
    drag_over_id = null;
}

/// Arc4 #242: unsaved-changes confirmation dialog state — BSS, no heap.
/// M32 WMS8 Gate 4 (issue #628): the WM — not the kernel — decides WHEN the
/// dialog appears (a dirty window's close) and WHICH button applies; the
/// kernel applies through the primitives below (cmd-11 DIALOG actions
/// 3-6). The 5-tick auto-close timeout is DELETED (the WM decides duration).
pub var unsaved_dialog_open: bool = false;
pub var unsaved_dialog_target: u8 = 0; // window id being closed

/// Arc4 #242: open the unsaved-changes dialog for a window.
pub fn unsaved_dialog_show(target_id: u8) void {
    unsaved_dialog_open = true;
    unsaved_dialog_target = target_id;
}

/// Arc4 #242: check if the unsaved dialog is open.
pub fn unsaved_dialog_is_open() bool {
    return unsaved_dialog_open;
}

/// Arc4 #242: the Save button action — post WIN_UNSAVED arg0=0 (save) to
/// the target app (the app saves; the window stays open). Extracted from
/// the click hit-test so the WM's cmd-11 DIALOG save applies the SAME code.
pub fn unsaved_dialog_save() void {
    const tid = unsaved_dialog_target;
    unsaved_dialog_open = false;
    if (find_user_window(tid)) |w| {
        if (w.owner) |pid| {
            events.push(pid, .{
                .kind = events.WIN_UNSAVED,
                .flags = 0,
                .seq = 0,
                .arg0 = 0, // save
                .arg1 = 0,
            });
        }
    }
}

/// Arc4 #242: the Don't Save button action — close the target window.
/// Extracted from the click hit-test (parity by construction).
pub fn unsaved_dialog_dont_save() void {
    const tid = unsaved_dialog_target;
    unsaved_dialog_open = false;
    _ = user_close(tid);
}

/// Arc4 #242: the Cancel button action — dismiss the dialog.
pub fn unsaved_dialog_cancel() void {
    unsaved_dialog_open = false;
}

/// Arc4 #242: handle a click inside the unsaved dialog. The button rects
/// are the SINGLE source the shared `wnd_core.unsaved_dialog_choice_at`
/// rule mirrors (both sides agree — parity by construction).
pub fn unsaved_dialog_click(x: u32, y: u32) enum { save, dont_save, cancel, none } {
    if (!unsaved_dialog_open) return .none;
    // Dialog rect: centered, 200×100.
    const dlg_w: u32 = 200;
    const dlg_h: u32 = 100;
    const dlg_x: u32 = if (virtio_gpu.fb_width > dlg_w) (virtio_gpu.fb_width - dlg_w) / 2 else 0;
    const dlg_y: u32 = if (virtio_gpu.fb_height > dlg_h) (virtio_gpu.fb_height - dlg_h) / 2 else 0;
    // Save button: left, 60×20 at bottom of dialog.
    if (x >= dlg_x + 20 and x < dlg_x + 80 and y >= dlg_y + dlg_h - 30 and y < dlg_y + dlg_h - 10) {
        unsaved_dialog_save();
        return .save;
    }
    // Don't Save button: middle.
    if (x >= dlg_x + 90 and x < dlg_x + 150 and y >= dlg_y + dlg_h - 30 and y < dlg_y + dlg_h - 10) {
        unsaved_dialog_dont_save();
        return .dont_save;
    }
    // Cancel button: right — the painted 30px button (review fix, claim
    // 7639: the old 60px rect overran the 200px dialog).
    if (x >= dlg_x + 160 and x < dlg_x + 190 and y >= dlg_y + dlg_h - 30 and y < dlg_y + dlg_h - 10) {
        unsaved_dialog_cancel();
        return .cancel;
    }
    return .none;
}

/// Arc4 #242: set/clear the unsaved flag on a user window. M32 WMS8 Gate 4
/// (issue #628): also fans a kind-20 mirror so the registered WM learns the
/// dirty state as it changes (the WM's unsaved-dialog decision input).
pub fn user_set_unsaved(id: u8, flag: bool) bool {
    const w = find_user_window(id) orelse return false;
    // Review fix (claim 7639): no-op when the flag is unchanged — don't
    // fan a redundant mirror.
    if (w.unsaved == flag) return true;
    w.unsaved = flag;
    wm_mirror(id);
    return true;
}

/// M15 C2 (Alt+Tab overlay, #225): hold-Alt cycling UI state — BSS, no heap.
pub var overlay_active: bool = false;
pub var overlay_selected: usize = 0;
pub var overlay_ids: [max_windows]u8 = undefined;
pub var overlay_count: usize = 0;

/// M32 WMS8 Gate 6 (issue #628): the drag-snap state (snap_zone, the
/// snap_last_*/snap_snapped per-window arrays, and the applied
/// snap_window/snap_restore primitives) is DELETED — the WM owns snap-on-drop
/// via its own mirror + the shared wnd_core rule (wnd_core.snap_zone_for_point/
/// snap_zone_bounds stay, single-source for the WM). With a WM seated this
/// kernel snap state was dormant behind the early-returning pointer_tick.
/// M21 W1/W2: tiling state — BSS, no heap.
/// `tile_mode` is true when the focused workspace uses tiling layout.
/// `tile_master_id` / `tile_stack_id` are the window ids assigned to
/// master and stack roles. When tiling is toggled, the compositor
/// recalculates window rects. The split ratio is 2/3 master, 1/3 detail.
pub var tile_mode: bool = false;
pub var tile_master_id: ?u8 = null;
pub var tile_stack_id: ?u8 = null;
/// M21 W2: master side — true = master on left (default), false = right.
pub var tile_master_side: bool = true;
/// M21 W2: master/detail split ratio (comptime). 2/3 : 1/3.
pub const tile_master_pct: u32 = 667; // per mille (66.7%)
/// M21 W3: per-window minimized state. When a window is minimized,
/// its previous rect is saved here for restore.
pub var minimize_prev_x: [user_windows_max]u32 = @as([user_windows_max]u32, @splat(@as(u32, 0)));
pub var minimize_prev_y: [user_windows_max]u32 = @as([user_windows_max]u32, @splat(@as(u32, 0)));
pub var minimize_prev_w: [user_windows_max]u32 = @as([user_windows_max]u32, @splat(@as(u32, 0)));
pub var minimize_prev_h: [user_windows_max]u32 = @as([user_windows_max]u32, @splat(@as(u32, 0)));
pub var minimize_prev_valid: [user_windows_max]bool = @as([user_windows_max]bool, @splat(@as(bool, false)));

/// M21 W6: per-window pre-maximize rect storage.
pub var pre_max_x: [user_windows_max]u32 = @as([user_windows_max]u32, @splat(@as(u32, 0)));
pub var pre_max_y: [user_windows_max]u32 = @as([user_windows_max]u32, @splat(@as(u32, 0)));
pub var pre_max_w: [user_windows_max]u32 = @as([user_windows_max]u32, @splat(@as(u32, 0)));
pub var pre_max_h: [user_windows_max]u32 = @as([user_windows_max]u32, @splat(@as(u32, 0)));
pub var pre_max_valid: [user_windows_max]bool = @as([user_windows_max]bool, @splat(@as(bool, false)));

/// M21 W7: fullscreen state — BSS, no heap.
pub var fullscreen_active: bool = false;
pub var fullscreen_window_id: ?u8 = null;

/// Arc2 W3 (claim 1264, #226): system tray state — fixed BSS, ~32B, zero heap.
/// Right 80px of 20px taskbar at y=700: HH:MM from tick, D/L/A theme letter
/// in accent, filled/empty clipboard rect. Clock ticks on composite() without
/// timer; migrates Kind.clock id 1 (no duplicate tray-vs-clock).
pub var tray_tick: u64 = 0;
pub var tray_has_tick: bool = false;
pub var tray_last_theme: u8 = 0xff;
pub var tray_last_clip_len: usize = 0;
/// M32 WMS6 Gate E (issue #626): WM-declared tray widget content — the
/// clock string, theme letter, and clipboard indicator the registered WM
/// owns (the final WMS6 chrome gate). When a field's `_set` flag is true
/// the renderer draws the WM's value; otherwise it falls back to the
/// shim's derived value (no-WM mode is byte-identical). Reset by
/// clear_wm_chrome on WM teardown.
pub var wm_tray_clock_text: [5]u8 = .{ '0', '0', ':', '0', '0' };
pub var wm_tray_clock_set: bool = false;
pub var wm_tray_theme: u8 = 'D';
pub var wm_tray_theme_set: bool = false;
pub var wm_tray_clip: bool = false;
pub var wm_tray_clip_set: bool = false;

/// Arc4 #240/M21 W5: desktop notification toasts — bounded BSS FIFO,
/// 10 entries (expanded from 4 for the notification center). Follows the
/// exit-report FIFO pattern (M3 claim 1014). Apps post via sys_notify;
/// the compositor renders top-right and auto-dismisses. The notification
/// center (W5) shows the last 10 in a pull-out panel.
pub const notify_max: usize = 10;
pub const notify_text_max: usize = 280;
pub const notify_dismiss_ticks: u32 = 5;
pub var notify_texts: [notify_max][notify_text_max]u8 = undefined;
pub var notify_lens: [notify_max]usize = @as([notify_max]usize, @splat(@as(usize, 0)));
pub var notify_levels: [notify_max]u8 = @as([notify_max]u8, @splat(@as(u8, 0)));
pub var notify_head: usize = 0;
pub var notify_count: usize = 0;

/// M21 W5: notification center panel state — BSS, no heap.
/// The panel opens on tray clock click and shows the last 10 notifications.
pub var notif_center_open: bool = false;
pub const notif_center_w: u32 = 300;
pub const notif_center_h: u32 = 400;
pub var notify_ticks: [notify_max]u32 = @as([notify_max]u32, @splat(@as(u32, 0)));

/// M27 G6: tooltip state — BSS, no heap. M32 WMS8 Gate 1 (claim 4270): the
/// dwell-decision is gone — the WM owns WHEN a tooltip shows via TOOLTIP
/// (cmd 8); the kernel keeps only the clamp + place + blit surface (visible,
/// position, text). No kernel hover timer remains.
pub var tooltip_visible: bool = false;
pub var tooltip_x: u32 = 0;
pub var tooltip_y: u32 = 0;
pub var tooltip_text: [32]u8 = undefined;
pub var tooltip_text_len: u8 = 0;

/// M27 G2: about dialog state — BSS, no heap.
pub var about_dialog_open: bool = false;

/// M27 G3: alt-tab preview buffer — 64×48 B8G8R8X8 (12,288 bytes).
/// Nearest-neighbor scaled from each window's framebuffer content.
pub const preview_w: u32 = 64;
pub const preview_h: u32 = 48;
pub var preview_buf: [preview_w * preview_h * 4]u8 = undefined;

/// Push a notification into the bounded FIFO (drop-oldest on overflow).
/// Called from the syscall handler (kernel context).
pub fn notify_push(text: []const u8, level: u8) void {
    const slot = (notify_head + notify_count) % notify_max;
    const copy_len = @min(text.len, notify_text_max);
    @memcpy(notify_texts[slot][0..copy_len], text[0..copy_len]);
    notify_lens[slot] = copy_len;
    notify_levels[slot] = level;
    notify_ticks[slot] = 0;
    if (notify_count < notify_max) {
        notify_count += 1;
    } else {
        // Drop-oldest: advance head.
        notify_head = (notify_head + 1) % notify_max;
    }
    // M27 G5: sound feedback for notifications
    if (virtio_snd.snd_status() == 0x0f) {
        if (level == 2) {
            _ = virtio_snd.snd_beep(880, 100);
        } else {
            _ = virtio_snd.snd_beep(440, 50);
        }
    }
}

/// Drain (dismiss) a notification by index within the visible set.
/// Returns true if dismissed.
pub fn notify_dismiss(index: usize) bool {
    if (index >= notify_count) return false;
    // Compact: shift remaining entries forward.
    var i: usize = index;
    while (i + 1 < notify_count) : (i += 1) {
        const src = (notify_head + i + 1) % notify_max;
        const dst = (notify_head + i) % notify_max;
        const n = notify_lens[src];
        @memcpy(notify_texts[dst][0..n], notify_texts[src][0..n]);
        notify_lens[dst] = n;
        notify_levels[dst] = notify_levels[src];
        notify_ticks[dst] = notify_ticks[src];
    }
    notify_count -= 1;
    return true;
}

/// Advance notification ticks (called once per composite). Auto-dismiss
/// entries that have exceeded notify_dismiss_ticks.
pub fn notify_advance_ticks() void {
    if (notify_count == 0) return;
    var i: usize = notify_count;
    while (i > 0) {
        i -= 1;
        const slot = (notify_head + i) % notify_max;
        notify_ticks[slot] +|= 1;
        if (notify_ticks[slot] >= notify_dismiss_ticks) {
            _ = notify_dismiss(i);
        }
    }
}

/// The current notification count (for compositor rendering).
pub fn notify_count_visible() usize {
    return notify_count;
}

/// Read notification data by visible index (0 = newest).
pub fn notify_entry(index: usize) ?struct { text: []const u8, level: u8 } {
    if (index >= notify_count) return null;
    const slot = (notify_head + index) % notify_max;
    return .{ .text = notify_texts[slot][0..notify_lens[slot]], .level = notify_levels[slot] };
}

/// M21 W5: toggle the notification center panel. Called on tray clock click.
pub fn notif_center_toggle() void {
    notif_center_open = !notif_center_open;
    _ = mark_dirty(0);
}

/// M32 WMS6 Gate B (issue #626): open/close the panel explicitly — the
/// decision channel for the registered WM (NOTIF_CENTER cmd 6). The kernel
/// clamps + blits; the WM says open or closed.
pub fn notif_center_set_open(open: bool) void {
    notif_center_open = open;
    _ = mark_dirty(0);
}

/// M21 W5: dismiss a notification by index in the center panel.
pub fn notif_center_dismiss(index: usize) bool {
    const result = notify_dismiss(index);
    if (result) _ = mark_dirty(0);
    return result;
}

/// M21 W5: clear all notifications from the center panel.
pub fn notif_center_clear_all() void {
    notify_count = 0;
    notify_head = 0;
    _ = mark_dirty(0);
}

/// M21 W5: hit-test the notification center panel. Returns the
/// notification index if a click landed on a notification row, or
/// ~0 for the "clear all" button, or null for a miss.
pub fn notif_center_hit_test(x: u32, y: u32) ?usize {
    if (!notif_center_open) return null;
    const panel_x: u32 = if (virtio_gpu.fb_width > notif_center_w) virtio_gpu.fb_width - notif_center_w else 0;
    const panel_y: u32 = 40;
    const row_h: u32 = 36;
    const pad: u32 = 8;
    const header_h: u32 = 24;
    // "Clear all" button at the bottom.
    const btn_y = panel_y + header_h + pad * 2 + @as(u32, @intCast(@min(notify_count, 8))) * row_h + pad;
    if (x >= panel_x + pad and x < panel_x + notif_center_w - pad and y >= btn_y and y < btn_y + 20) {
        return ~@as(usize, 0); // clear all sentinel
    }
    // Check notification rows.
    var i: usize = 0;
    while (i < @min(notify_count, 8)) : (i += 1) {
        const row_y = panel_y + header_h + pad + @as(u32, @intCast(i)) * row_h;
        if (x >= panel_x + pad and x < panel_x + notif_center_w - pad and y >= row_y and y < row_y + row_h) {
            return i;
        }
    }
    return null;
}

/// Step 7 (Issue #207): theme selection. 0=dark, 1=light, 2=amber.
/// Read by the compositor chrome pass for title bars, clock, focus ring.
/// M73m (#1662): 3 = `custom` — the user's own palette, resolved from the
/// three fields below (store keys `palette_fg`/`palette_bg`/`palette_accent`,
/// applied by settings.zig's apply chain). Every chrome accessor still
/// switches 1/2/else, so an unknown id lands on the dark arm — a custom
/// palette can never paint garbage, and a fresh image (theme "dark") never
/// reads these fields at all.
pub var theme_id: u8 = 0;

/// M73m (#1662): the custom palette the resolver prefers when
/// `theme_id == theme_id_custom`. Compiled defaults ARE the dark values
/// (`fbtext.fg_rgb`/`bg_rgb`, dark's accent), so a `theme=custom` boot with
/// nothing of its own written resolves byte-identically to the boot theme.
pub const theme_id_custom: u8 = 3;
pub var custom_fg: u32 = fbtext.fg_rgb;
pub var custom_bg: u32 = fbtext.bg_rgb;
/// Dark's focus-ring / active taskbar-entry accent (#207, #1662).
pub var custom_accent: u32 = 0x3b82f6;

/// Theme color for the clock title bar background.
pub fn clock_title_bg() u32 {
    return switch (theme_id) {
        1 => 0xf8fafc, // light: near-white title bar
        2 => 0xb58900, // amber: warm gold
        else => 0xb58900, // dark: original amber
    };
}

/// Theme color for the clock body background.
pub fn clock_bg() u32 {
    return switch (theme_id) {
        1 => 0xf1f5f9, // light: light gray
        2 => 0x0a1a2e, // amber: dark navy (original)
        else => 0x0a1a2e, // dark: original
    };
}

/// M20-U9: window border width — 2px, visible on every theme.
pub const chrome_border_w: usize = 2;

/// Theme color for the user window border (darker than the title bar).
pub fn user_border() u32 {
    return switch (theme_id) {
        1 => 0x94a3b8, // light: slate
        2 => 0x0c1826, // amber: near-black navy (original)
        else => 0x0c1826, // dark: original
    };
}

/// M21 W9: muted border color for unfocused windows (visible but not
/// attention-grabbing). The focused window gets an accent border instead.
pub fn user_border_unfocused() u32 {
    return switch (theme_id) {
        1 => 0x9ca3af, // light: muted slate
        2 => 0x44403c, // amber: warm stone
        else => 0x475569, // dark: muted blue-gray
    };
}

/// M37 DQ4 (issue #838): compositor drop-shadow offset (px) — right +
/// bottom bands outside the window rect. Mirrors `user/src/lib/ui.zig`
/// (`shadow_off`); pinned equal by the dq4 shadow-parity host test.
/// Gated by `settings set shadow on` (default off) so every pre-DQ4
/// pixel gate stays byte-identical.
pub const chrome_shadow_off: usize = 4;

/// M37 DQ4: theme color for the drop-shadow bands.
pub fn shadow_color() u32 {
    return switch (theme_id) {
        1 => 0x94a3b8, // light: slate (visible on light wallpaper)
        2 => 0x000000, // amber: black
        else => 0x000000, // dark: black
    };
}
/// M20-U9 layout helper: where the centered title text starts and how
/// many bytes of it to draw, given a window width and label length.
/// Leaves room for the minimize+close buttons on the right; labels too
/// wide for the remaining span truncate with a trailing "...".
pub fn chrome_title_layout(win_w: usize, label_len: usize) geom.TitleLayout {
    // Single source: the shared wnd_core layout rule.
    return geom.chrome_title_layout(win_w, label_len);
}

/// Theme color for the user window title bar.
pub fn user_title_bg() u32 {
    return switch (theme_id) {
        1 => 0xe2e8f0, // light: light surface
        2 => 0x1a2b3c, // amber: dark blue (original)
        else => 0x1a2b3c, // dark: original
    };
}

/// M21 W9: theme color for the focus ring — accent per theme.
/// Dark: blue, Light: deeper blue, Amber: amber.
pub fn focus_ring() u32 {
    return switch (theme_id) {
        1 => 0x1d4ed8, // light: blue ring (distinct on white)
        2 => 0xf59e0b, // amber: warm amber
        3 => custom_accent, // custom: the user's accent (#1662)
        else => 0x3b82f6, // dark: blue accent
    };
}

/// Theme color for the taskbar background.
pub fn taskbar_bg() u32 {
    return switch (theme_id) {
        1 => 0xe2e8f0, // light: light surface
        2 => 0x0f172a, // amber: dark (original)
        else => 0x0f172a, // dark: original
    };
}

/// Theme color for the taskbar entry highlight.
pub fn taskbar_entry_active() u32 {
    return switch (theme_id) {
        1 => 0x2563eb, // light: blue
        2 => 0xff8800, // amber: orange
        3 => custom_accent, // custom: the user's accent (#1662)
        else => 0x3b82f6, // dark: blue (original)
    };
}

/// Theme color for the taskbar entry (dimmed).
pub fn taskbar_entry_dimmed() u32 {
    return switch (theme_id) {
        1 => 0xcbd5e1, // light: light border
        2 => 0x1e293b, // amber: dark (original)
        else => 0x1e293b, // dark: original
    };
}

/// WM3 (issue #707 card 3): theme color for a MINIMIZED entry (darker than
/// the plain dimmed fill — the entry is a restore target, not a task).
pub fn taskbar_entry_minimized() u32 {
    return switch (theme_id) {
        1 => 0xb0bccd, // light: dimmer border
        2 => 0x0b1220, // amber: darker than dimmed
        else => 0x0b1220, // dark: darker than dimmed
    };
}

/// WM3: the focused entry's active-indicator underline ink (white —
/// visible on the active fill in every theme).
pub const taskbar_indicator_rgb: u32 = 0xffffff;

/// WM3: the minimized entry's indicator dot ink (the restore affordance).
pub const taskbar_min_dot_rgb: u32 = 0x94a3b8;

/// WM3: the minimized entry's title ink (muted gray).
pub const taskbar_min_title_rgb: u32 = 0x94a3b8;

/// Theme color for the desktop wallpaper top.
pub fn wallpaper_top() u32 {
    return switch (theme_id) {
        1 => 0xf1f5f9, // light: very light
        2 => 0x1a1a2e, // amber: dark (original)
        else => 0x1a1a2e, // dark: original
    };
}

/// Theme color for the desktop wallpaper bottom.
pub fn wallpaper_bot() u32 {
    return switch (theme_id) {
        1 => 0xe2e8f0, // light: light surface
        2 => 0x0a0a14, // amber: darker (original)
        else => 0x0a0a14, // dark: original
    };
}

// ---------------------------------------------------------------------------
// Arc2 W3 — system tray helpers (pure, host-testable, isolated for merge)
// ---------------------------------------------------------------------------

/// Tray rect — right 80px of 20px taskbar at y=700. Pure — host-testable.
pub fn tray_rect() struct { x: u32, y: u32, w: u32, h: u32 } {
    return .{ .x = tray_x, .y = tray_y, .w = tray_w, .h = tray_h };
}

/// Format HH:MM from tick (seconds since boot, 1 Hz timer). Zero-padded,
/// 24h wrap. Pure — host-testable. Writes into buf[0..5] and returns slice.
pub fn format_hhmm(buf: []u8, ticks: u64) []const u8 {
    if (buf.len < 5) return "";
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

/// Theme letter D/L/A per theme_id. Pure — host-testable.
pub fn theme_letter() u8 {
    return switch (theme_id) {
        1 => 'L',
        2 => 'A',
        else => 'D',
    };
}

/// Theme accent for tray letter — taskbar active entry color per theme.
pub fn tray_theme_accent() u32 {
    return taskbar_entry_active();
}

/// Clipboard filled when current_len !=0. Pure wrapper — host-testable.
pub fn tray_clipboard_filled() bool {
    return clipboard.current_len() != 0;
}

/// M32 WMS6 Gate E (issue #626): apply the registered WM's TRAY decision —
/// the clock string, theme letter, and clipboard indicator (each optional;
/// a null field leaves the current value untouched). The kernel clamps to
/// the frozen bounds (5-char clock, one of D/L/A, clip bool) and marks the
/// taskbar (window 255) dirty so composite repaints it.
pub fn tray_set(clock: ?[]const u8, theme: ?u8, clip: ?bool) void {
    if (clock) |c| {
        var i: usize = 0;
        while (i < 5 and i < c.len) : (i += 1) wm_tray_clock_text[i] = c[i];
        wm_tray_clock_set = true;
    }
    if (theme) |t| {
        wm_tray_theme = t;
        wm_tray_theme_set = true;
    }
    if (clip) |v| {
        wm_tray_clip = v;
        wm_tray_clip_set = true;
    }
    _ = mark_dirty(255); // taskbar
}

/// Current tray tick (for tests).
pub fn tray_current_tick() u64 {
    return tray_tick;
}
pub fn tray_has_clock() bool {
    return tray_has_tick;
}

// ---------------------------------------------------------------------------
// Arm / query
// ---------------------------------------------------------------------------

/// Arm the window manager: register the terminal (window 0, full screen)
/// and the fixed chrome (wallpaper, taskbar, dock). The clock window
/// (Kind.clock id 1) is migrated to the taskbar tray (Arc2 W3) — no duplicate
/// window. Focus the terminal, mark dirty so first composite paints the scene.
pub fn arm() void {
    // WM1 (#707, claim 919) host-test scaffolding (compiled out on
    // device — production arm() runs once at boot on a fresh pool):
    // reset the test arena (bump allocator — frees are no-ops, so every
    // test starts with a full arena and cross-test leaks are impossible),
    // then re-arm a generous fake pool (host writes never touch these
    // phys addresses — `kbuf_test` carries the CPU-visible bytes — so the
    // span costs nothing; 65536 pages covers 8 fullscreen windows).
    if (builtin.is_test) {
        if (!test_arena.ready) {
            test_arena.fba = std.heap.FixedBufferAllocator.init(&test_arena.buf);
            test_arena.ready = true;
        }
        test_arena.fba.reset();
        var desc = [_]memmap.MemoryDescriptor{
            .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 65536, .attribute = 0 },
        };
        const view = memmap.MapView.init(std.mem.asBytes(&desc), @sizeOf(memmap.MemoryDescriptor), desc.len);
        _ = alloc.init(view, &.{});
    }
    win_count = 0;
    // M102d1 (#2166): a registry reset strands no GPU3D context — the
    // broker's records bind to window ids, so a fresh window registry
    // means a fresh context pool too (pure BSS wipe, mirrors c1's
    // reset_state contract; nothing is live at boot).
    gpu3d_broker.reset_state();
    windows[win_count] = .{
        .id = 0,
        .title = "roadpops",
        .x = 0,
        .y = 0,
        .w = virtio_gpu.fb_width,
        .h = virtio_gpu.fb_height,
        .kind = .terminal,
        .visible = true,
        .dirty = true,
    };
    win_count += 1;
    // Arc2 W3: Kind.clock id 1 deprecated — tray clock in taskbar replaces it.
    // No window created for clock; tray state holds HH:MM.
    // Step 9: wallpaper window (id 254) — gradient background between terminal and taskbar.
    windows[win_count] = .{
        .id = 254,
        .title = "wallpaper",
        .x = 0,
        .y = 0,
        .w = virtio_gpu.fb_width,
        .h = virtio_gpu.fb_height,
        .kind = .wallpaper,
        .visible = true,
        .dirty = true,
    };
    win_count += 1;
    // Step 8: taskbar window (id 255) — always topmost.
    windows[win_count] = .{
        .id = 255,
        .title = "taskbar",
        .x = 0,
        .y = taskbar_y,
        .w = virtio_gpu.fb_width,
        .h = taskbar_h,
        .kind = .taskbar,
        .visible = true,
        .dirty = true,
    };
    win_count += 1;
    // M15 C4: dock window (id 253) — 24 px left bar, always visible.
    windows[win_count] = .{
        .id = 253,
        .title = "dock",
        .x = dock_x,
        .y = dock_y,
        .w = dock_w,
        .h = dock_h,
        .kind = .dock,
        .visible = true,
        .dirty = true,
    };
    win_count += 1;
    focused_id = 0;
    armed_global = true;
    presents = 0;
    clock_shown_tick = 0;
    clock_has_tick = false;
    tray_tick = 0;
    tray_has_tick = false;
    tray_last_theme = 0xff;
    tray_last_clip_len = 0;
    // M32 WMS6 Gate E: no WM-declared tray content at boot.
    wm_tray_clock_set = false;
    wm_tray_theme_set = false;
    wm_tray_clip_set = false;
    cursor_shown = false;
    cursor_drawn = false;
    cursor_old_damage = null;
    cursor_new_damage = null;
    prev_ptr_buttons = 0;
    wm_fan_valid = false;
    resize_id = null;
    // M52 card 3 (#1240): a fresh registry holds no drag — the Arc4 #237
    // capture is process-scoped BSS and must not survive a re-arm (a stuck
    // capture would otherwise outlive the process it named).
    drag_active = false;
    drag_payload_len = 0;
    drag_source_pid = 0;
    drag_over_id = null;
    overlay_active = false;
    overlay_count = 0;
    overlay_selected = 0;
    // WM2: the overview grid never survives a registry reset.
    overview_open = false;
    overview_n = 0;
    presentation_trace_arm();
}

pub fn armed() bool {
    return armed_global;
}

pub fn count() usize {
    return win_count;
}

pub fn presents_pushed() usize {
    return presents;
}

pub fn window_at(i: usize) ?*const Window {
    if (i >= win_count) return null;
    return &windows[i];
}

pub fn kind_name(kind: Kind) []const u8 {
    return switch (kind) {
        .terminal => "terminal",
        .clock => "clock",
        .user => "user",
        .taskbar => "taskbar",
        .wallpaper => "wallpaper",
        .dock => "dock",
    };
}

// ---------------------------------------------------------------------------
// Z-order, focus, hit-testing (pure — host-testable)
// ---------------------------------------------------------------------------

/// The index of the focused window, or null when none.
pub fn focused_index() ?usize {
    if (!armed_global) return null;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id == focused_id) return i;
    }
    return null;
}

/// The focused window's id, or 0xff when none.
pub fn focused_window_id() u8 {
    return focused_id;
}

/// True when the focused window is the terminal (the I3 keyboard sink).
pub fn terminal_focused() bool {
    const fi = focused_index() orelse return false;
    return windows[fi].kind == .terminal;
}

/// The focused window, or null when none.
pub fn focused_window() ?*const Window {
    const fi = focused_index() orelse return null;
    return &windows[fi];
}

/// The owning process ID of the focused user window, or null if terminal/clock/none.
pub fn focused_owner() ?usize {
    const fi = focused_index() orelse return null;
    if (windows[fi].kind == .user) return windows[fi].owner;
    return null;
}

/// Focus a window by id. Returns false for an unknown id.
/// Card E4 (claim 0293): emits WIN_BLUR to previous focused user window
/// and WIN_FOCUS to newly focused user window.
pub fn focus(id: u8) bool {
    if (!armed_global) return false;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id == id) {
            // Card U5 (ADR 0008 D4): focus is ALWAYS VISIBLE — a focus
            // change must repaint so the ring moves.
            if (focused_id != id) {
                const old_id = focused_id;
                // Deliver WIN_BLUR to previously focused user window owner
                if (find_user_window(old_id)) |old_win| {
                    if (old_win.owner) |old_owner| {
                        events.push(old_owner, .{
                            .kind = events.WIN_BLUR,
                            .flags = 0,
                            .seq = 0,
                            .arg0 = old_id,
                            .arg1 = id,
                        });
                    }
                }
                // Deliver WIN_FOCUS to newly focused user window owner
                if (windows[i].kind == .user and windows[i].owner != null) {
                    events.push(windows[i].owner.?, .{
                        .kind = events.WIN_FOCUS,
                        .flags = 0,
                        .seq = 0,
                        .arg0 = id,
                        .arg1 = old_id,
                    });
                }
                // M32 WMS5: the old window's focused bit cleared — mirror it.
                if (find_user_window(old_id)) |old_win| wm_mirror(old_win.id);
                // WM4 (issue #707 card 4): a focus change flips the
                // rest-alpha state of BOTH windows (the focused one is
                // exempt, the unfocused one blends). When either side
                // carries a rest policy, mark both dirty so the next
                // composite re-blits their CLIENTS at the new alpha (the
                // chrome repaints every composite anyway). No policy = 256
                // = no churn (the v1 behavior is untouched).
                if (wm_rest_alpha(old_id) < 256 or wm_rest_alpha(id) < 256) {
                    if (find_user_window(old_id)) |ow| ow.dirty = true;
                    if (find_user_window(id)) |nw| nw.dirty = true;
                }
                _ = mark_dirty(0);
            }
            // Step 7 (Issue #210): auto-show a hidden window on focus.
            if (!windows[i].visible) {
                windows[i].visible = true;
                windows[i].dirty = true;
                _ = mark_dirty(0);
            }
            focused_id = id;
            // M32 WMS5: focus is the WM's hit-test input — mirror the new
            // focused window.
            wm_mirror(id);
            return true;
        }
    }
    return false;
}

/// Raise a window to the top of the z-order (the end of the array). Focus
/// is unchanged (tracked by id). Returns false for an unknown id.
pub fn raise(id: u8) bool {
    if (!armed_global) return false;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id == id) {
            const moved = windows[i];
            var j = i;
            while (j + 1 < win_count) : (j += 1) windows[j] = windows[j + 1];
            windows[win_count - 1] = moved;
            // Re-blit the raised window (z-order changed).
            windows[win_count - 1].dirty = true;
            return true;
        }
    }
    return false;
}

/// Adapter: the pure wnd_core geometry view of a kernel Window. The ONLY
/// rule logic lives in wnd_core (the drift guard); this is pure glue.
pub fn to_geom(w: *const Window) geom.Geom {
    return .{
        .id = w.id,
        .kind = @fromBackingInt(@intCast(@backingInt(w.kind))),
        .x = w.x,
        .y = w.y,
        .w = w.w,
        .h = w.h,
        .visible = w.visible,
        .workspace = w.workspace,
    };
}

/// The topmost visible window containing (x, y), or null when none does.
pub fn hit_test(x: u32, y: u32) ?u8 {
    // Delegated to the shared wnd_core hit-test rule (single source with
    // the WM server). The registry order IS the z-order (0 = bottom).
    var gbuf: [max_windows]geom.Geom = undefined;
    var i: usize = 0;
    while (i < win_count) : (i += 1) gbuf[i] = to_geom(&windows[i]);
    return geom.hit_test(gbuf[0..win_count], current_workspace, x, y);
}

/// Focus the topmost window at (x, y). Returns false when nothing is there.
pub fn focus_at(x: u32, y: u32) bool {
    const id = hit_test(x, y) orelse return false;
    return focus(id);
}

// ---------------------------------------------------------------------------
// Dirty tracking
// ---------------------------------------------------------------------------

/// Mark a window dirty (by id) so the next composite repaints it. Returns
/// false for an unknown id.
pub fn mark_dirty(id: u8) bool {
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id == id) {
            windows[i].dirty = true;
            return true;
        }
    }
    return false;
}

/// M33 SB4 (claim 2382): union-rect a partial damage region into a window's
/// tracked damage rect, marking it dirty. When called while `damaged` is
/// already true, the tracked rect EXPANDS to the bounding box of the new
/// rect (damage is monotonic until composite consumes it). Returns false for
/// an unknown id. The rect is CLAMPED to the window's own bounds so a caller
/// can never push damage outside the repaintable surface.
pub fn mark_damage(id: u8, x: u32, y: u32, w: u32, h: u32) bool {
    if (w == 0 or h == 0) return false;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id != id) continue;
        const win = &windows[i];
        // Clamp to the window (local coords; caller passes in-window rects).
        const cx = x;
        const cy = y;
        var cw = w;
        var ch = h;
        if (x >= win.w or y >= win.h) return true; // out-of-window -> ignore
        if (x + w > win.w) cw = win.w - x;
        if (y + h > win.h) ch = win.h - y;
        const ex = cx + cw;
        const ey = cy + ch;
        if (win.damaged) {
            const ox = win.dx;
            const oy = win.dy;
            const oex = ox + win.dw;
            const oey = oy + win.dh;
            win.dx = @min(ox, cx);
            win.dy = @min(oy, cy);
            win.dw = @max(oex, ex) - win.dx;
            win.dh = @max(oey, ey) - win.dy;
        } else {
            win.dx = cx;
            win.dy = cy;
            win.dw = cw;
            win.dh = ch;
            win.damaged = true;
        }
        win.dirty = true;
        return true;
    }
    return false;
}

/// M33 SB4: the per-surface damage rect for a user window, or null when it
/// has no rect-granular (partial) damage pending (whole-window dirty only).
pub const DamageRect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};
pub fn user_damage(id: u8) ?DamageRect {
    const win = find_user_window(id) orelse return null;
    if (!win.damaged) return null;
    return .{ .x = win.dx, .y = win.dy, .w = win.dw, .h = win.dh };
}

/// M33 SB4: a per-surface dirty bitmask for the COMPOSITE_TICK (kind-18)
/// damage payload — bit i is set when user window (i + user_window_id_base)
/// has pending damage this tick. The registered WM consumes this to know
/// WHICH surfaces changed (the rects come via `user_damage`); SB5's compose-N
/// repaints only those.
pub fn user_damage_mask() u32 {
    var mask: u32 = 0;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        // Only `.user` surfaces carry the bitmask — the fixed layers (terminal
        // 0, wallpaper 254, taskbar 255, dock 253) are compositor-owned, not
        // user surfaces, and their ids would overflow the mask shift.
        if (windows[i].kind != .user) continue;
        const idx = windows[i].id - user_window_id_base;
        if (idx >= user_windows_max) continue;
        if (windows[i].dirty) {
            mask |= (@as(u32, 1) << @intCast(idx));
        }
    }
    return mask;
}

/// Mark the terminal (window 0) dirty — the Road Pops tee's write path.
pub fn mark_terminal_dirty() void {
    if (win_count > 0) windows[0].dirty = true;
}

/// M73m (#1662): a palette write recolours the WHOLE desktop — chrome,
/// tray, wallpaper and every window-bound terminal all resolve theme state
/// at paint time — so mark every window dirty. The next composite
/// re-resolves each colour: live apply, no reboot, no re-exec.
pub fn mark_palette_dirty() void {
    var i: usize = 0;
    while (i < win_count) : (i += 1) windows[i].dirty = true;
}

/// M80i (#1725): the grid half of the `font_size` apply chain. Moves the
/// zoom ladder (font_metrics.set_size), re-flows every bound grid to the
/// new cell IMMEDIATELY (the next composite's syncWindowCols would get
/// there anyway; doing it here makes the change atomic with the setting
/// and runs before the repaint the caller triggers), and tells each
/// bound TUI its canvas changed in CELL terms — a font change is a
/// winsize change for a cell-addressed app — with the SAME payload
/// shape `user_resize` pushes (the pixel rect, arg0=w arg1=h). The cell
/// mapping the app derives from it (tabapp.CellGrid, the charm overlay's
/// cellsForRect) mirrors font_metrics at that instant.
pub fn apply_grid_font_size(s: font_metrics.Size) void {
    font_metrics.set_size(s);
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        const w = &windows[i];
        if (w.kind != .user) continue;
        if (terminal.screenForWindow(w.id) == null) continue;
        terminal.syncWindowCols(w.id, w.w);
        if (w.owner) |owner| {
            events.push(owner, .{
                .kind = events.WIN_RESIZE,
                .flags = 0,
                .seq = 0,
                .arg0 = w.w,
                .arg1 = w.h,
            });
        }
        w.dirty = true;
    }
}

// ---------------------------------------------------------------------------
// Card G6 (claim 0487): the draw/window syscall seam — user windows
// ---------------------------------------------------------------------------

pub const UserOpenResult = union(enum) {
    opened: u8,
    invalid: void,
    full: void,
    /// WM1: geometry fit but the pool had no contiguous run for w×h×4.
    nomem: void,
};

/// Find a user window by id (only `.user` kinds — the terminal/clock ids
/// are fixed and never match the user id base).
pub fn find_user_window(id: u8) ?*Window {
    const idx = find_user_window_index(id) orelse return null;
    return &windows[idx];
}

/// The registry index of a user window, or null.
pub fn find_user_window_index(id: u8) ?usize {
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id == id and windows[i].kind == .user) return i;
    }
    return null;
}

/// Open a kernel-owned user window at screen position (x, y) with a
/// pool-backed back-buffer exactly w×h (WM1: carved from the kernel page
/// pool here, freed at close/`close_owner`), OWNED by the process `owner`
/// (the syscall layer records the caller's pid here). The window is
/// appended at the top of the z-order and focused. Returns `.opened`
/// with the id (2..9), `.invalid` for geometry outside the scanout
/// bounds (or when the manager is unarmed — no gpu), `.full` when all
/// eight user slots are already open, and `.nomem` when the pool has no
/// contiguous run for the buffer. The window is OWNED by `owner` — it
/// auto-closes when that process exits (the scheduler's exit path calls
/// `close_owner`, which frees the pages — the allocator is a lock-free
/// bitmap, so the exception-context contract holds).
pub fn user_open(x: u32, y: u32, w: u32, h: u32, owner: usize) UserOpenResult {
    if (!armed_global) return .invalid;
    if (w == 0 or h == 0 or w > user_win_max_w or h > user_win_max_h) return .invalid;
    if (x >= virtio_gpu.fb_width or y >= virtio_gpu.fb_height) return .invalid;
    if (w > virtio_gpu.fb_width - x or h > virtio_gpu.fb_height - y) return .invalid;
    var i: usize = 0;
    while (i < user_windows_max) : (i += 1) {
        const id = user_window_id_base + @as(u8, @intCast(i));
        var used = false;
        var j: usize = 0;
        while (j < win_count) : (j += 1) {
            if (windows[j].id == id) {
                used = true;
                break;
            }
        }
        if (used) continue;
        const nbytes = kbuf_bytes(w, h);
        const npages = kbuf_pages_for(nbytes);
        const pa = alloc.alloc_pages(npages) orelse return .nomem;
        // Host tests cannot dereference pool phys: the CPU-visible bytes
        // live in the test arena (bump allocator — freed implicitly by
        // the per-test reset in arm()). On device this branch is out.
        var test_ptr: ?[*]u8 = null;
        if (builtin.is_test) {
            const backing = test_arena.fba.allocator().alloc(u8, nbytes) catch {
                _ = alloc.free_pages(pa, npages);
                return .nomem;
            };
            test_ptr = backing.ptr;
        }
        // The buffer starts cleared (the old BSS semantic — a fresh window
        // reads back zeros). Host tests cannot dereference pool phys, so
        // the CPU-visible bytes live in the test allocation instead.
        if (builtin.is_test) {
            @memset(test_ptr.?[0..nbytes], 0);
        } else {
            @memset(@as([*]u8, @ptrFromInt(pa))[0..nbytes], 0);
        }
        windows[win_count] = .{
            .id = id,
            .title = "user",
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .kind = .user,
            .visible = true,
            .dirty = true,
            .owner = owner,
            .fade_phase = 1, // Arc4 #239: start fade-in
            .fade_tick = 0,
            .workspace = current_workspace, // Arc4 #241: assign to current workspace
            .kbuf_pa = pa,
            .kbuf_pages = npages,
            .kbuf_test = test_ptr,
        };
        win_count += 1;
        // Issue #990 (claim #997): the open-attribution marker — the
        // WM2 gate's overview counted a PHANTOM third window (n=3 vs the
        // pinned n=2) with exec forwarded exactly once; this line names
        // every kernel-side open (id/owner/rect) so the serial log can
        // attribute it. One line per real open, klog-gated (silent in
        // host tests / pre-boot).
        {
            var kbuf: [80]u8 = undefined;
            const s = std.fmt.bufPrint(&kbuf, "open: id={d} owner={d} rect={d},{d} {d}x{d} ws={d}\n", .{ id, owner, x, y, w, h, current_workspace }) catch "open: ?\n";
            klog.line(s);
        }
        _ = focus(id);
        // M32 WMS5: the registered WM must see the new window to hit-test it.
        wm_mirror(id);
        return .{ .opened = id };
    }
    return .full;
}

/// M97b-F3 (#2111): the bind-time invariant "a surface-backed window's rect
/// never exceeds its bound surface", re-validated on every resize. `reflow`
/// is the single writer of `win.w`/`win.h` post-open, so one check there
/// covers `user_resize`, `wm_apply_rect`, and the tile/maximize/fullscreen
/// paths — `user_fill`/`composite`/overview/`render_preview` all stride the
/// surface's `pa_base` by win.w×win.h×4, so letting the rect grow past
/// `surface_pages` is a kernel OOB write/read past the region. Refusal
/// keeps the window's old rect (the pool-exhaustion contract); an app that
/// wants a bigger canvas re-binds a bigger surface.
fn surface_covers(page_count: u32, w: u32, h: u32) bool {
    return @as(usize, page_count) * alloc.page_size >= kbuf_bytes(w, h);
}

/// WM1 (#707, claim 919): set a user window's rect, reallocating the
/// pool back-buffer when the size changes (the overlap is preserved row
/// by row — the static-buffer semantic that a resize reframes bytes
/// rather than discarding them; grown area reads back zero). Geometry +
/// buffer change atomically: on pool exhaustion returns false with the
/// window entirely unchanged. Same-size is a position-only fast path.
/// Callers: every post-open size writer (user_resize, wm_apply_rect,
/// tile/maximize/fullscreen/keyboard/restore) routes here so the buffer
/// can never disagree with win.w×win.h.
pub fn reflow(win: *Window, x: u32, y: u32, w: u32, h: u32) bool {
    if (w == 0 or h == 0) return false;
    if (w == win.w and h == win.h) {
        win.x = x;
        win.y = y;
        return true;
    }
    if (win.surface_handle != 0 and !surface_covers(win.surface_pages, w, h)) return false;
    const nbytes = kbuf_bytes(w, h);
    const npages = kbuf_pages_for(nbytes);
    const pa = alloc.alloc_pages(npages) orelse return false;
    var test_ptr: ?[*]u8 = null;
    if (builtin.is_test) {
        const backing = test_arena.fba.allocator().alloc(u8, nbytes) catch {
            _ = alloc.free_pages(pa, npages);
            return false;
        };
        @memset(backing, 0);
        test_ptr = backing.ptr;
    } else {
        @memset(@as([*]u8, @ptrFromInt(pa))[0..nbytes], 0);
    }
    const copy_w: usize = @min(win.w, w);
    const copy_h: usize = @min(win.h, h);
    const old_stride: usize = @as(usize, win.w) * 4;
    const new_stride: usize = @as(usize, w) * 4;
    const old_ptr = kbuf_ptr(win);
    const new_ptr: [*]u8 = if (builtin.is_test) test_ptr.? else @as([*]u8, @ptrFromInt(pa));
    var row: usize = 0;
    while (row < copy_h) : (row += 1) {
        @memcpy(new_ptr[row * new_stride ..][0 .. copy_w * 4], old_ptr[row * old_stride ..][0 .. copy_w * 4]);
    }
    if (win.kbuf_pa != 0) _ = alloc.free_pages(win.kbuf_pa, win.kbuf_pages);
    // The host-test arena needs no per-window free (per-test reset).
    win.x = x;
    win.y = y;
    win.w = w;
    win.h = h;
    win.kbuf_pa = pa;
    win.kbuf_pages = npages;
    win.kbuf_test = test_ptr;
    return true;
}

/// Fill a rect in the user window's back-buffer (local coordinates,
/// 0..window w/h) and mark it dirty. Returns false for an unknown id or a
/// rect outside the window bounds.
pub fn user_fill(id: u8, x: u32, y: u32, w: u32, h: u32, rgb: u32) bool {
    const win = find_user_window(id) orelse return false;
    if (w == 0 or h == 0) return false;
    if (x >= win.w or y >= win.h) return false;
    if (w > win.w - x or h > win.h - y) return false;
    // M33 SB3 (claim 9361): a surface-backed window FILLS ITS OWN SHARED
    // PAGES, not the kernel pool buffer — the frozen slot hands off to the
    // surface. fill_rect writes the same B8G8R8X8 bytes into the region the
    // WM mirrors RO, so parity between the migrated fill and the legacy path
    // is exact (identical pixel encoding). An unmigrated window is unchanged.
    const surface = user_surface(id);
    if (surface) |sf| {
        // #2111: a desynced rect would write past the surface's physical
        // pages — refuse the fill rather than corrupt adjacent memory.
        if (!surface_covers(sf.page_count, win.w, win.h)) return false;
        fill_rect(@as([*]u8, @ptrFromInt(sf.pa_base)), win.w * 4, x, y, w, h, rgb);
    } else {
        fill_rect(kbuf_ptr(win), win.w * 4, x, y, w, h, rgb);
    }
    // M33 SB4 (claim 2382): record the EXACT written rect as the surface's
    // damage, so composite (and, via COMPOSITE_TICK, the WM) repaints only
    // this region — the rect-granular gate (one rect writes -> one rect
    // repaints), not a whole-window present.
    _ = mark_damage(id, x, y, w, h);
    return true;
}

/// Mark a user window dirty so the compositor blits its back-buffer on the
/// next idle-loop pass (the deferred-present discipline — the syscall never
/// touches the gpu directly; the shell idle loop's `drain` composites).
/// Returns false for an unknown id.
pub fn user_present(id: u8) bool {
    const win = find_user_window(id) orelse return false;
    win.dirty = true;
    return true;
}

/// M33 SB3 (claim 9361): the surface info a surface-backed user window
/// holds (the kernel's composite source + the WM-mirror identity). Returns
/// null for an unknown / non-user / unmigrated window.
pub const SurfaceInfo = struct {
    handle: u32,
    pa_base: u64,
    page_count: u32,
};

/// Bind user window `id` to the shared surface described by `si`. The
/// caller (the `sys_mmap` window-tag path) has already created the region,
/// mapped the owner's writable leaves into the window owner's root, and
/// granted the WM its RO mirror; this records the identity on the window so
/// `composite()` blits from the surface's own pages. Returns false if the
/// window is unknown / not `.user` / already surface-backed (a window binds
/// ONE surface; unbind before rebind).
pub fn user_bind_surface(id: u8, si: SurfaceInfo) bool {
    const win = find_user_window(id) orelse return false;
    if (win.surface_handle != 0) return false; // already migrated
    win.surface_handle = si.handle;
    win.surface_pa = si.pa_base;
    win.surface_pages = si.page_count;
    win.dirty = true;
    return true;
}

/// The surface a user window is bound to, or null when unmigrated.
pub fn user_surface(id: u8) ?SurfaceInfo {
    const win = find_user_window(id) orelse return null;
    if (win.surface_handle == 0) return null;
    return .{ .handle = win.surface_handle, .pa_base = win.surface_pa, .page_count = win.surface_pages };
}

/// True when user window `id` is surface-backed (migrated). An unmigrated
/// window is `false` (the frozen kernel-buffer path, byte-identical).
pub fn user_is_surface_backed(id: u8) bool {
    const win = find_user_window(id) orelse return false;
    return win.surface_handle != 0;
}

/// M102d1 (#2166): the CPU-visible pixel destination for one user window —
/// the bound surface's own pages when migrated (identity-mapped into the
/// kernel root, exactly where `composite()`/`user_fill` already address it),
/// else the pool back-buffer. Surface capacity is re-validated HERE, at
/// copy time, against the CURRENT win.w×win.h — an undersized surface
/// refuses rather than painting past its pages (the #2111 invariant). Null
/// for an unknown/non-user window or an undersized surface; the returned
/// extent/stride are this moment's geometry so the caller clips and clears
/// against the live rect, never a captured one.
pub const PaintDest = struct {
    base: [*]u8,
    stride: usize,
    w: u32,
    h: u32,
};

pub fn user_paint_dest(id: u8) ?PaintDest {
    const win = find_user_window(id) orelse return null;
    if (win.surface_handle != 0) {
        if (!surface_covers(win.surface_pages, win.w, win.h)) return null;
        return .{ .base = @as([*]u8, @ptrFromInt(win.surface_pa)), .stride = @as(usize, win.w) * 4, .w = win.w, .h = win.h };
    }
    return .{ .base = kbuf_ptr(win), .stride = @as(usize, win.w) * 4, .w = win.w, .h = win.h };
}

/// M104f: render a window's KERNEL front-end (attached terminal grid) into
/// its bound surface — the half of paint() a migrated window still needs
/// while the seat owns the scanout blit (wm_owns_user_layer). No-op for
/// self-painting apps (no terminal screen) and for a rect that outgrew the
/// bound pages (the #2111 invariant — the seat clips to the last honest
/// extent until the owner re-shares).
fn render_frontend_to_surface(w: *const Window) void {
    if (w.kind != .user or w.surface_handle == 0) return;
    const scr = terminal.screenOf(w.id) orelse return;
    if (!surface_covers(w.surface_pages, w.w, w.h)) return;
    terminal.syncWindowCols(w.id, w.w);
    render_terminal_screen(@as([*]u8, @ptrFromInt(w.surface_pa)), w, scr);
}

/// Move a user window's top-left corner to (x, y), CLAMPED so the whole
/// window stays inside the scanout (a window is never allowed off-screen —
/// the honest bound). Marks the moved window dirty and the terminal dirty
/// (its old rect is revealed) so the next composite repaints over the old
/// position and blits at the new one. Returns false for an unknown id, a
/// non-user window (the terminal + clock are fixed), or an unarmed manager.
/// The EL0 `sys_win_move` enforces ownership on top of this.
pub fn user_move(id: u8, x: u32, y: u32) bool {
    const win = find_user_window(id) orelse return false;
    const max_x = virtio_gpu.fb_width - win.w;
    const max_y = virtio_gpu.fb_height - win.h;
    win.x = @min(x, max_x);
    win.y = @min(y, max_y);
    win.dirty = true;
    // Reveal whatever sat under the window's old rect (the terminal repaint).
    _ = mark_dirty(0);
    // M32 WMS5: the WM's mirror follows the clamped move (it proposes, the
    // kernel clamps — the mirror carries the clamped truth).
    wm_mirror(id);
    return true;
}

/// Raise a user window to the top of the z-order (the EL0 `sys_win_raise`
/// primitive — ownership is enforced at the syscall layer). Focus is
/// unchanged (tracked by id, the G5 discipline). Returns false for an
/// unknown id or a non-user window (the terminal + clock are fixed).
pub fn user_raise(id: u8) bool {
    if (find_user_window_index(id) == null) return false;
    return raise(id);
}

/// Arc4 #238 (slot 49): raise the caller's user window to the top of the
/// z-order (EL0-callable variant of `user_raise`). Owner-restricted like
/// `sys_win_raise`; refused on fixed layers. Returns false for unknown id,
/// non-user window, or unarmed manager.
pub fn user_raise_front(id: u8) bool {
    if (!armed_global) return false;
    if (find_user_window_index(id) == null) return false;
    return raise(id);
}

/// Arc4 #238 (slot 50): lower the caller's user window to the bottom of
/// the z-order — above fixed windows (wallpaper/taskbar/dock, ids 255/253)
/// but below all other user windows. Owner-restricted; refused on fixed
/// layers. Returns false for unknown id, non-user window, or unarmed.
pub fn user_lower_back(id: u8) bool {
    if (!armed_global) return false;
    const idx = find_user_window_index(id) orelse return false;
    // Move to index 0: shift everything above down by one.
    const moved = windows[idx];
    var j = idx;
    while (j > 0) : (j -= 1) windows[j] = windows[j - 1];
    windows[0] = moved;
    windows[0].dirty = true;
    return true;
}

/// Arc4 #241: move a user window to a different workspace.
pub fn user_move_to_workspace(id: u8, ws: u8) bool {
    if (!armed_global) return false;
    const w = find_user_window(id) orelse return false;
    w.workspace = ws;
    w.dirty = true;
    _ = mark_dirty(0);
    return true;
}

/// Close (release) a user window: remove it from the registry (the z-order
/// stays compact — later windows shift down), fall the focus back to the
/// terminal when the closed window held it, and mark the fixed windows
/// (terminal + clock) dirty so the next composite repaints over the
/// released window's pixels. Returns false for an unknown id or a non-user
/// window (the terminal + clock are fixed and never closable). The pool
/// back-buffer is freed for the next `user_open` (which re-clears it).
/// This is the PRIVILEGED release path (the monitor's `dui close <n>`); the
/// EL0 `sys_win_close` enforces ownership on top of it. The WM mirror goes
/// out from `remove_user_at` (the shared release primitive) — every release
/// path informs the WM exactly once.
pub fn user_close(id: u8) bool {
    const idx = find_user_window_index(id) orelse return false;
    remove_user_at(idx);
    return true;
}

/// The owner of a user window, or null for an unknown id / non-user window
/// (the syscall layer compares this to the caller to enforce ownership).
pub fn user_owner(id: u8) ?usize {
    const win = find_user_window(id) orelse return null;
    return win.owner;
}

/// Card G6 (claim 0487) follow-on (slot 18): the geometry of a user window
/// — the `sys_win_get` result. The syscall layer marshals this into the
/// caller's buffer (four u32 LE words) through uaccess so an EL0 program
/// can read its window's rect back after a CLAMPED move (the move is
/// silent; this is the read-back seam).
pub const WinRect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

/// The rect of a user window, or null for an unknown id / non-user window
/// (the terminal + clock are fixed and never match).
pub fn user_rect(id: u8) ?WinRect {
    const win = find_user_window(id) orelse return null;
    return .{ .x = win.x, .y = win.y, .w = win.w, .h = win.h };
}

/// #1056 item 2: the best human-readable name for a user window — its
/// app-set title when one exists (sys_win_set_title / the tabapp declare
/// RPC), otherwise the OWNING PROCESS's name (the FAT executable name, e.g.
/// "WINLOOP.BIN"). This names the tabs of apps that never set a title, so
/// the WM's kind-20 mirror (which carries no title bytes) can resolve a
/// label. Null for a non-user window / unknown id / nameless owner.
pub fn user_display_name(id: u8) ?[]const u8 {
    const win = find_user_window(id) orelse return null;
    if (win.title_len > 0) return win.title_buf[0..win.title_len];
    const owner = win.owner orelse return null;
    const pinfo = process.info(owner) orelse return null;
    if (pinfo.name.len == 0) return null;
    return pinfo.name;
}

/// M32 WMS5 (issue #625): push ONE registry mirror (kind 20 WM_WINDOW)
/// through the `wm_window_hook` for window `id` — the kernel's window data
/// fanned out so the registered WM can hit-test. A no-op when no WM is
/// registered (hook null) or the window is gone. Called from the user-
/// window mutation points (open/close/move/resize/visibility/focus) so the
/// WM's mirror stays current.
pub fn wm_mirror(id: u8) void {
    const hook = wm_window_hook orelse return;
    const win = find_user_window(id) orelse return;
    hook(id, win.x, win.y, win.w, win.h, win.visible, win.id == focused_id, win.workspace, win.unsaved, false);
}

/// Card G6 (claim 0487) follow-on (slot 19): the FULL state of a user
/// window — the `sys_win_query` result. The rect (like `user_rect`) plus the
/// z-order rank (`z` = the registry index, 0 = bottom — the SAME number the
/// monitor's `dui` report prints), and the focus/visible/dirty flags (1/0).
/// The syscall layer marshals this into the caller's buffer (eight u32 LE
/// words) so an EL0 program can introspect its window end to end.
pub const WinQuery = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    z: u32,
    focused: u32,
    visible: u32,
    dirty: u32,
};

/// The full state of a user window, or null for an unknown id / non-user
/// window. `z` is the registry index (0 = bottom of the z-order).
pub fn user_query(id: u8) ?WinQuery {
    const idx = find_user_window_index(id) orelse return null;
    const win = windows[idx];
    return .{
        .x = win.x,
        .y = win.y,
        .w = win.w,
        .h = win.h,
        .z = @intCast(idx),
        .focused = if (focused_id == id) 1 else 0,
        .visible = if (win.visible) 1 else 0,
        .dirty = if (win.dirty) 1 else 0,
    };
}

/// Card G6 (claim 0487) follow-on (slot 20): set a user window's visibility
/// (hide/show). Returns false for an unknown id or a non-user window (the
/// terminal + clock are fixed and never hideable). Hiding marks the window
/// hidden + dirty (inert while hidden) and marks the terminal dirty so the
/// next composite repaints over the hidden window's pixels; showing marks the
/// window dirty so it reappears. Idempotent (same-flag calls are a no-op — no
/// dirty churn). The EL0 `sys_win_set_visible` enforces ownership on top of
/// this; focus is unchanged (tracked by id, the G5 discipline).
pub fn user_set_visible(id: u8, visible: bool) bool {
    const win = find_user_window(id) orelse return false;
    if (win.visible == visible) return true;
    win.visible = visible;
    win.dirty = true;
    if (!visible) _ = mark_dirty(0); // reveal whatever sat under the hidden window
    wm_mirror(id); // M32 WMS5: visibility changes must reach the WM's mirror
    return true;
}

/// Arc2 W1 (claim 3589, #224): drag-to-resize — hit-test, clamp, and resize.
///
/// 6×6 bottom-right corner at (x+w-6, y+h-6). Pure — host-testable.
pub fn is_resize_hit(win: Window, px: u32, py: u32) bool {
    if (win.kind != .user or !win.visible) return false;
    if (win.w < resize_hit_size or win.h < resize_hit_size) return false;
    const rx = win.x + win.w - resize_hit_size;
    const ry = win.y + win.h - resize_hit_size;
    return px >= rx and px < win.x + win.w and py >= ry and py < win.y + win.h;
}

/// Clamp helpers — pure, host-testable. Buffer bounds 128×64..scanout
/// (WM1: the pool buffer follows the window up to the scanout) plus
/// on-scanout containment (so a resize never writes beyond the framebuffer).
pub fn clamp_resize_w(req_w: i32, win_x: u32) u32 {
    // Delegated to the shared wnd_core clamp rule (single source with the
    // WM server).
    return geom.clamp_resize_w(req_w, win_x, virtio_gpu.fb_width, resize_min_w, user_win_max_w);
}

pub fn clamp_resize_h(req_h: i32, win_y: u32) u32 {
    // Delegated to the shared wnd_core clamp rule.
    return geom.clamp_resize_h(req_h, win_y, virtio_gpu.fb_height, resize_min_h, user_win_max_h);
}

/// Resize a user window to (w, h), clamped to 128×64..scanout and
/// on-scanout, reallocating the pool buffer to the clamped size (WM1 —
/// content overlap preserved). Marks the window dirty + the terminal
/// dirty (reveal old rect + chrome repaint on next `composite()`), and
/// emits `WIN_RESIZE` to the owning pid. Returns false for an unknown
/// id / non-user window, or when the pool cannot satisfy the new size
/// (the window keeps its old rect). The EL0 `sys_win_resize` enforces
/// ownership on top of this; the compositor's pointer_tick calls it
/// directly.
pub fn user_resize(id: u8, w: u32, h: u32) bool {
    const win = find_user_window(id) orelse return false;
    const clamped_w = clamp_resize_w(@intCast(w), win.x);
    const clamped_h = clamp_resize_h(@intCast(h), win.y);
    if (!reflow(win, win.x, win.y, clamped_w, clamped_h)) return false;
    win.dirty = true;
    _ = mark_dirty(0);
    _ = mark_dirty(1);
    wm_mirror(id); // M32 WMS5: the WM's mirror follows the clamped resize
    if (win.owner) |owner| {
        events.push(owner, .{
            .kind = events.WIN_RESIZE,
            .flags = 0,
            .seq = 0,
            .arg0 = clamped_w,
            .arg1 = clamped_h,
        });
    }
    return true;
}

/// M32 WMS5 Gate 2 (claim 4278): apply a WM-proposed rect with LAYOUT
/// semantics — on-scanout clamping only, NO back-buffer clamp. The shim's
/// own tile/maximize/fullscreen write 837-wide rects directly (the blit
/// source-clamps to the app's 512x424 buffer, claim 8777); the WM must be
/// able to produce the SAME rects (the W1–W16 registered-matrix parity bar
/// of issue #625). `sys_win_move`/`sys_win_resize` keep the back-buffer
/// clamp (an APP asking its window to grow past its own buffer is refused);
/// this is the WM deciding LAYOUT, so the back-buffer is not the limit.
/// WM proposes, kernel clamps to the scanout, mirror follows.
pub fn wm_apply_rect(id: u8, x: u32, y: u32, w: u32, h: u32) bool {
    const win = find_user_window(id) orelse return false;
    // M42 SX2 (issue #983): remember the pre-layout size so the owner can be
    // told when the WM's LAYOUT decision grew/shrank its canvas — the seam
    // TABWM's full-viewport proposal rides. Pure moves emit nothing (no
    // event spam; parity with `user_resize`, which notifies on resize only).
    const old_w = win.w;
    const old_h = win.h;
    // Move FIRST so the size clamp sees the final position (the shim's
    // user_move-then-user_resize order, per the WMS4 comment). The max is
    // the SCANOUT, not the app's back buffer: the shim's own
    // tile/maximize/fullscreen write 837-wide rects directly, and the WM
    // must be able to produce the SAME rects (the W1–W16 registered-matrix
    // parity bar). WM proposes, kernel clamps on-scanout, mirror follows.
    const max_x = virtio_gpu.fb_width -| win.w;
    const max_y = virtio_gpu.fb_height -| win.h;
    const nx = @min(x, max_x);
    const ny = @min(y, max_y);
    const cw = geom.clamp_resize_w(@intCast(w), nx, virtio_gpu.fb_width, resize_min_w, virtio_gpu.fb_width);
    const ch = geom.clamp_resize_h(@intCast(h), ny, virtio_gpu.fb_height, resize_min_h, virtio_gpu.fb_height);
    // WM1: the pool buffer follows the layout size (content overlap
    // preserved); on pool exhaustion the window keeps its old rect.
    if (!reflow(win, nx, ny, cw, ch)) return false;
    if (wm_owns_user_layer and win.chrome_valid and win.chrome.kind == 0) {
        // The WM now owns this client's surrounding pixels. Finish the
        // native opening fade and replace the old scanout contents BEFORE
        // the seat can present: blending over them preserves the old frame.
        win.fade_phase = 0;
        win.fade_tick = 0;
        win.damaged = false;
        // Migrated clients are composed by the WM, not by this legacy blit —
        // but a kernel-rendered front-end (attached tty) still needs its grid
        // re-rendered into the resized surface, or the seat reads stale rows.
        if (win.surface_handle == 0) paint(win) else render_frontend_to_surface(win);
    }
    win.dirty = true;
    _ = mark_dirty(0);
    _ = mark_dirty(1);
    wm_mirror(id); // M32 WMS5: the WM's mirror follows the clamped layout
    // M42 SX2: the owner learns its new canvas when the clamped size differs
    // from the old one (same payload shape as `user_resize`: w in arg0,
    // h in arg1) — TABWM's full-viewport proposals reach the app.
    if (win.w != old_w or win.h != old_h) {
        if (win.owner) |owner| {
            events.push(owner, .{
                .kind = events.WIN_RESIZE,
                .flags = 0,
                .seq = 0,
                .arg0 = win.w,
                .arg1 = win.h,
            });
        }
    }
    return true;
}

/// True when a resize drag is active.
pub fn resize_active() bool {
    return resize_id != null;
}

pub fn resize_current_id() ?u8 {
    return resize_id;
}

/// Auto-close every user window owned by the process `owner` (the exit
/// path's teardown seam — `scheduler.exit_current` calls this with the
/// exited process's pid). Returns how many windows were released. Pure
/// BSS writes (safe in the exception context the exit path runs in).
pub fn close_owner(owner: usize) usize {
    // M111b (#2409): a dying owner's GPU3D compute session revokes here —
    // the one per-process teardown funnel the exit inventory reaches
    // (compute binds no window, so remove_user_at never sees it). Handle
    // invalidation first, the bounded device drain second.
    gpu3d_compute.owner_exit(owner);
    // M52 card 3 (#1240): a dead drag SOURCE leaves no live pointer capture.
    // The Arc4 #237 drag payload is process-scoped (`drag_source_pid`) and
    // its only clear sites are the drop path and `sys_drag_read`, so a
    // source that dies mid-drag used to strand `drag_active` forever: every
    // later pointer move kept crossing windows and every drop still named
    // the dead pid as the source. Cancel it with the source.
    if (drag_active and drag_source_pid == owner) drag_cancel();
    var closed: usize = 0;
    while (true) {
        var idx: ?usize = null;
        var i: usize = 0;
        while (i < win_count) : (i += 1) {
            if (windows[i].kind == .user and windows[i].owner == owner) {
                idx = i;
                break;
            }
        }
        const found = idx orelse break;
        remove_user_at(found);
        closed += 1;
    }
    return closed;
}

/// M52 card 3 (#1240): close every user window BOUND to shared-surface
/// `handle` (the zombie-close seam `shared_mmap.revoke_peer` calls when an
/// owner-side revoke frees the surface). A surface-backed window's pixels
/// live in the region's pages, so once the region is revoked the window has
/// no source left: `composite()` would blit from freed physical pages and a
/// frozen `sys_win_fill` would WRITE into them (the surface fill path uses
/// `surface_pa` directly, not a uaccess-checked va). Ending the window here
/// keeps the registry honest — the release runs through the same
/// `remove_user_at` primitive as every other path, so the WM gets its one
/// released mirror and the owner its WIN_CLOSE. Returns the windows closed.
/// Pure BSS writes (safe in the exit/exception context the revoke runs in).
pub fn surface_revoked(handle: u32) usize {
    if (handle == 0) return 0; // unmigrated windows hold no surface
    var closed: usize = 0;
    while (true) {
        var idx: ?usize = null;
        var i: usize = 0;
        while (i < win_count) : (i += 1) {
            if (windows[i].kind == .user and windows[i].surface_handle == handle) {
                idx = i;
                break;
            }
        }
        const found = idx orelse break;
        remove_user_at(found);
        closed += 1;
    }
    return closed;
}

/// Remove the user window at registry index `idx` (the shared release
/// primitive behind `user_close` and `close_owner`): compact the z-order,
/// fall the focus back to the terminal when the removed window held it,
/// and mark the fixed windows dirty so the next composite repaints over
/// the released window's pixels.
/// Card E4 (claim 0293): emits WIN_CLOSE to the user window owner.
/// M42 UX (2026-09-05): fans ONE "released" mirror to the registered WM
/// from the already-copied `removed_win` state (visible=false, released —
/// flags bit 13), so EVERY release path (user_close, close_owner/app
/// self-exit) informs the WM exactly once that the window left the
/// registry — not merely hid. Pure BSS writes (allocation-free), so the
/// exit/exception context contract of the WIN_CLOSE push holds for the
/// fan equally.
pub fn remove_user_at(idx: usize) void {
    const removed_win = windows[idx];
    const removed_id = removed_win.id;
    // M102d1 (#2166): a dying window revokes its GPU3D context FIRST — the
    // handle is invalidated before c1's bounded drain runs, so a late
    // publish can never reach this window's pixels. Non-blocking: a device
    // that cannot drain leaves the session quarantined (backing pinned for
    // late DMA). Runs in the exit path via close_owner — the same
    // bounded-exchange contract as the kbuf free below.
    gpu3d_broker.revoke_window(removed_id);
    // #1082 (ADR 0020 Amendment A, A6): closing the bound window auto-detaches
    // its terminal. The terminal survives, buffered, unattached, and the
    // serial console is NOT reclaimed (boot default unchanged). Pure BSS
    // writes — safe in the exit/exception context this runs in.
    terminal.detachWindow(removed_id);
    // M42 UX: the released mirror goes out FIRST (the pre-removal fan the
    // old user_close owned) — focused_id still holds the pre-removal truth
    // here, and the WM drops its hit-test target before anything mutates.
    if (wm_window_hook) |hook| {
        hook(removed_win.id, removed_win.x, removed_win.y, removed_win.w, removed_win.h, false, removed_win.id == focused_id, removed_win.workspace, removed_win.unsaved, true);
    }
    // WM1 (#707, claim 919): return the pool back-buffer to the allocator.
    // Runs in the exit path via close_owner — free_pages is a lock-free
    // bitmap op, so the exception-context contract holds. Unconditional: a
    // zero pa frees nothing (free_pages reports false). The host-test
    // arena needs no free (per-test reset in arm()).
    if (removed_win.kbuf_pa != 0) {
        _ = alloc.free_pages(removed_win.kbuf_pa, removed_win.kbuf_pages);
    }
    if (removed_win.kind == .user and removed_win.owner != null) {
        events.push(removed_win.owner.?, .{
            .kind = events.WIN_CLOSE,
            .flags = 0,
            .seq = 0,
            .arg0 = removed_id,
            .arg1 = 0,
        });
    }
    var j = idx;
    while (j + 1 < win_count) : (j += 1) windows[j] = windows[j + 1];
    win_count -= 1;
    // M37 DQ2 (issue #840): a closed container orphans its tabs — attached
    // children become standalone rather than pointing at a dead parent.
    var k: usize = 0;
    while (k < win_count) : (k += 1) {
        if (windows[k].tab_parent == removed_id) windows[k].tab_parent = 0;
    }
    if (focused_id == removed_id) {
        focused_id = 0; // fall back to the terminal
    }
    // M15 C2: overlay snapshot is stale after a close — dismiss honestly.
    if (overlay_active) {
        overlay_active = false;
        overlay_count = 0;
    }
    // M32 WMS8 Gate 6 (issue #628): the per-window snap-clear block is
    // DELETED (the snap_last_*/snap_snapped arrays are gone — the WM owns
    // snap). Tiling state clearing continues below.
    // M21 W1: clear tiling state if a tiled window is closed.
    if (tile_master_id) |mid| {
        if (mid == removed_id) {
            tile_master_id = null;
            if (tile_stack_id) |sid| {
                tile_master_id = sid;
                tile_stack_id = null;
            }
            tile_mode = tile_master_id != null;
        }
    }
    if (tile_stack_id) |sid| {
        if (sid == removed_id) {
            tile_stack_id = null;
        }
    }
    // M32 WMS8 Gate 6 (issue #628): the drag_id/snap_zone clear on window
    // close is DELETED (the title-bar drag + snap state is gone). Resize
    // state clearing stays.
    if (resize_id != null and resize_id.? == removed_id) {
        resize_id = null;
    }
    // M52 card 3 review nit (#1240): the Arc4 #237 drag target is capture
    // state too — if the pointer was over THIS window, the drag must stop
    // naming it. (Not the WMS8-deleted title-bar drag_id above: this is the
    // drag-and-drop hover. The DRAG_LEAVE/DROP fans are gated on drag_active,
    // so a removed target made them inert rather than absent — the same
    // "no stale capture state" rule the rest of the card enforces.)
    if (drag_over_id != null and drag_over_id.? == removed_id) {
        drag_over_id = null;
    }
    // Reveal whatever sat under the released window.
    _ = mark_dirty(0);
    _ = mark_dirty(1);
}

/// Card U5 (claim 0935, ADR 0008 D4): cycle focus to the next visible
/// window in z-order (wrapping). Returns the newly focused id, or null
/// when no window is cyclable. A focus change repaints the whole scene
/// (mark_dirty(0) — the compositor repaints everything above the lowest
/// dirty window, so the ring moves correctly under any overlay).
pub fn cycle_focus() ?u8 {
    if (win_count == 0) return null;
    const start = focused_index() orelse 0;
    var i: usize = 1;
    while (i <= win_count) : (i += 1) {
        const idx = (start + i) % win_count;
        if (!windows[idx].visible) continue;
        // Wallpaper, taskbar and dock are not cyclable.
        if (windows[idx].kind == .wallpaper or windows[idx].kind == .taskbar or windows[idx].kind == .dock) continue;
        const target_id = windows[idx].id;
        _ = focus(target_id);
        return focused_id;
    }
    return null;
}

/// M15 C2 (Alt+Tab overlay, #225): hold-Alt cycling UI — BSS snapshot + highlight.
/// Pure overlay: Alt held + first Tab captures user-window ids, Tab/Shift+Tab cycles
/// `overlay_selected`, Alt release commits the highlight. No new syscall/kind.
pub fn alt_tab_is_active() bool {
    return overlay_active;
}

pub fn alt_tab_selected_id() ?u8 {
    if (!overlay_active or overlay_count == 0) return null;
    return overlay_ids[overlay_selected];
}

pub fn alt_tab_count() usize {
    return overlay_count;
}

/// Snapshot user windows and activate the overlay. Returns true when an overlay
/// with ≥2 windows is now visible (1 window → no overlay, honest no-op).
pub fn alt_tab_activate() bool {
    if (overlay_active) return false;
    var ids: [max_windows]u8 = undefined;
    var cnt: usize = 0;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        const w = &windows[i];
        if (!w.visible) continue;
        if (w.kind != .user) continue;
        // M21 W3: skip minimized windows in Alt+Tab.
        if (w.minimized) continue;
        // M21 W4: only show windows on the current workspace.
        if (!workspace_visible(w)) continue;
        if (cnt < max_windows) {
            ids[cnt] = w.id;
            cnt += 1;
        }
    }
    if (cnt <= 1) return false;
    var sel: usize = 0;
    var found: ?usize = null;
    var k: usize = 0;
    while (k < cnt) : (k += 1) {
        if (ids[k] == focused_id) {
            found = k;
            break;
        }
    }
    if (found) |idx| sel = (idx + 1) % cnt else sel = 0;
    var j: usize = 0;
    while (j < cnt) : (j += 1) overlay_ids[j] = ids[j];
    overlay_count = cnt;
    overlay_selected = sel;
    overlay_active = true;
    _ = mark_dirty(0);
    return true;
}

/// Cycle the highlight — Shift inverts (reverse).
pub fn alt_tab_cycle(shift: bool) void {
    if (!overlay_active or overlay_count == 0) return;
    if (shift) {
        if (overlay_selected == 0) overlay_selected = overlay_count - 1 else overlay_selected -= 1;
    } else {
        overlay_selected = (overlay_selected + 1) % overlay_count;
    }
    _ = mark_dirty(0);
}

/// Commit the highlighted window (focus+raise) and dismiss the overlay.
pub fn alt_tab_commit() ?u8 {
    if (!overlay_active or overlay_count == 0) return null;
    const id = overlay_ids[overlay_selected];
    overlay_active = false;
    overlay_count = 0;
    _ = focus(id);
    _ = raise(id);
    _ = mark_dirty(0);
    return id;
}

/// Dismiss without committing (right-click / Escape).
pub fn alt_tab_dismiss() void {
    if (!overlay_active) return;
    overlay_active = false;
    overlay_count = 0;
    _ = mark_dirty(0);
}

/// M32 WMS6 Gate A (issue #626): the WM, not the kernel, picks which window
/// Alt+Tab switches to. The kernel keeps the overlay SNAPSHOT + blit (WMS8
/// deletes it) but exposes focus-by-id so the WM's decision drives it. The
/// WM proposes the highlighted id; the kernel clamps (id must name a live
/// alt-tab window: visible, non-minimized, on the current workspace — the
/// M21 W3/W4 rules) and repaints. Returns false when `id` is not a valid
/// alt-tab target (the handler maps that to EINVAL).
pub fn alt_tab_overlay_focus(id: u8) bool {
    // Build the snapshot if the overlay isn't active (the same rules
    // alt_tab_activate uses — visible, non-minimized, current workspace).
    if (!overlay_active) {
        var ids: [max_windows]u8 = undefined;
        var cnt: usize = 0;
        var i: usize = 0;
        while (i < win_count) : (i += 1) {
            const w = &windows[i];
            if (!w.visible) continue;
            if (w.kind != .user) continue;
            if (w.minimized) continue;
            if (!workspace_visible(w)) continue;
            if (cnt < max_windows) {
                ids[cnt] = w.id;
                cnt += 1;
            }
        }
        if (cnt <= 1) return false; // not enough windows to Alt+Tab
        var j: usize = 0;
        while (j < cnt) : (j += 1) overlay_ids[j] = ids[j];
        overlay_count = cnt;
        overlay_active = true;
    }
    // Find the WM's proposed id in the snapshot and make it the highlight.
    var k: usize = 0;
    while (k < overlay_count) : (k += 1) {
        if (overlay_ids[k] == id) {
            overlay_selected = k;
            _ = mark_dirty(0);
            return true;
        }
    }
    return false; // id not a live alt-tab window
}

/// WMS6 Gate A: commit the WM's chosen id directly (focus + raise + dismiss),
/// the same final action `alt_tab_commit` performs (by value, not by snapshot
/// index). Returns false when `id` does not name a live user window (the
/// handler maps that to EINVAL).
pub fn alt_tab_wm_commit(id: u8) bool {
    if (find_user_window_index(id) == null) return false;
    overlay_active = false;
    overlay_count = 0;
    _ = focus(id);
    _ = raise(id);
    _ = mark_dirty(0);
    return true;
}

// ---------------------------------------------------------------------------
// WM2 mission-control overview (Self-hosting Lane 1, issue #707 card 2).
// A hotkey-summoned grid of the current workspace's user windows: click a
// card to focus+raise it, drag a card onto a workspace-strip button to move
// it there (and switch to it), Esc/hotkey to exit. The GRID GEOMETRY is the
// shared wnd_core rule (geom.overview_grid / card_rect / ws_button_rect) —
// the kernel renders these rects and the WM hit-tests the SAME rects, so
// the two cannot disagree. Policy (which card was clicked) arrives over
// slot-65 OVERVIEW (cmd 21); the kernel only applies + repaints.
// ---------------------------------------------------------------------------

/// True while the overview grid is on screen.
pub var overview_open: bool = false;
/// Snapshot of current-workspace user-window ids taken at enter.
pub var overview_ids: [user_windows_max]u8 = @as([user_windows_max]u8, @splat(@as(u8, 0)));
/// Live entries in `overview_ids`.
pub var overview_n: usize = 0;

pub fn overview_is_open() bool {
    return overview_open;
}

/// Live card count (0 when closed).
pub fn overview_window_count() usize {
    if (!overview_open) return 0;
    return overview_n;
}

/// Snapshot the current workspace's user windows (visible ones on the
/// current workspace) and open the grid. The snapshot sorts ids ASCENDING
/// so card index i names the same window on both sides of the seam: the WM
/// rebuilds the identical order from its mirrors (slot order == id order)
/// using only mirrored fields (valid/visible/workspace), so the card-index
/// mapping cannot drift. Returns the card count (0 with the grid still open
/// but empty — honest, not a refusal).
pub fn overview_enter() usize {
    var cnt: usize = 0;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        const w = &windows[i];
        if (!w.visible) continue;
        if (w.kind != .user) continue;
        if (!workspace_visible(w)) continue;
        if (cnt < user_windows_max) {
            overview_ids[cnt] = w.id;
            cnt += 1;
        }
    }
    // Ascending-id insertion sort (<= 8 entries — the shared card order).
    var a: usize = 1;
    while (a < cnt) : (a += 1) {
        const key = overview_ids[a];
        var b: usize = a;
        while (b > 0 and overview_ids[b - 1] > key) : (b -= 1) {
            overview_ids[b] = overview_ids[b - 1];
        }
        overview_ids[b] = key;
    }
    overview_n = cnt;
    overview_open = true;
    _ = mark_dirty(0);
    return cnt;
}

/// Close the grid without touching focus.
pub fn overview_exit() void {
    if (!overview_open) return;
    overview_open = false;
    overview_n = 0;
    _ = mark_dirty(0);
}

/// The WM's click decision: card `id` gains focus+raise and the grid
/// closes. Returns false when closed or `id` is not a live card (the
/// handler maps that to EINVAL).
pub fn overview_focus(id: u8) bool {
    if (!overview_open) return false;
    var k: usize = 0;
    while (k < overview_n) : (k += 1) {
        if (overview_ids[k] == id) {
            overview_open = false;
            overview_n = 0;
            _ = focus(id);
            _ = raise(id);
            _ = mark_dirty(0);
            return true;
        }
    }
    return false;
}

/// The WM's drag decision: card `id` moves to workspace `ws` and the grid
/// closes onto that workspace. Returns false when closed, `id` is not a
/// live card, or `ws` is out of range.
pub fn overview_move(id: u8, ws: u8) bool {
    if (!overview_open) return false;
    if (ws >= workspace_max) return false;
    var k: usize = 0;
    while (k < overview_n) : (k += 1) {
        if (overview_ids[k] == id) {
            overview_open = false;
            overview_n = 0;
            _ = user_move_to_workspace(id, ws);
            switch_workspace(ws);
            _ = mark_dirty(0);
            return true;
        }
    }
    return false;
}

/// #990 (claim #997): WHY overview_move would refuse (id, ws) — the same
/// predicate the move runs, as a name for the serial. Pure.
pub fn overview_move_refusal(id: u8, ws: u8) []const u8 {
    if (!overview_open) return "closed";
    if (ws >= workspace_max) return "ws-range";
    var k: usize = 0;
    while (k < overview_n) : (k += 1) {
        if (overview_ids[k] == id) return "none";
    }
    return "not-a-card";
}

/// WM2: nearest-neighbor scale blit — a source image (a user window's own
/// back-buffer or shared surface, never the scanout, so source and
/// destination cannot overlap) scaled into a destination rect. Pure BSS
/// math, no allocation. Zero-size rects are honest no-ops.
pub fn blit_scaled(
    dst: [*]u8,
    dst_stride: usize,
    src: [*]const u8,
    src_w: usize,
    src_h: usize,
    src_stride: usize,
    dx: usize,
    dy: usize,
    dw: usize,
    dh: usize,
) void {
    if (dw == 0 or dh == 0 or src_w == 0 or src_h == 0) return;
    var y: usize = 0;
    while (y < dh) : (y += 1) {
        const src_y = y * src_h / dh;
        var x: usize = 0;
        while (x < dw) : (x += 1) {
            const src_x = x * src_w / dw;
            const s = src + src_y * src_stride + src_x * 4;
            const d = dst + (dy + y) * dst_stride + (dx + x) * 4;
            d[0] = s[0];
            d[1] = s[1];
            d[2] = s[2];
            d[3] = 0xff;
        }
    }
}

/// WM2: paint the overview grid (called from the overlay section when
/// `overview_open`). Dim backdrop + one card per snapshot window (title
/// band + live scaled content) + the workspace strip with one button per
/// workspace. Card/strip rects are the shared geom rules — the same ones
/// the WM hit-tests.
pub fn paint_overview(fb: [*]u8, stride: usize, wspan: usize, hspan: usize) void {
    if (!overview_open) return;
    const sw: u32 = @intCast(@min(wspan, 0xffff));
    const sh: u32 = @intCast(@min(hspan, 0xffff));
    // Dim backdrop over the whole scanout.
    fill_rect(fb, stride, 0, 0, wspan, hspan, 0x0f0f1a);
    const g = geom.overview_grid(overview_n, sw, sh, geom.taskbar_h, geom.dock_w);
    draw_string(fb, stride, @as(usize, g.x0), 0, "Overview - click focuses, drag to a workspace, Esc exits", 0x94a3b8);
    var idx: usize = 0;
    while (idx < overview_n) : (idx += 1) {
        const id = overview_ids[idx];
        const card = geom.overview_card_rect(g, idx);
        const cx: usize = card.x;
        const cy: usize = card.y;
        const cw: usize = card.w;
        const ch: usize = card.h;
        // Card surface + border (accent when focused).
        fill_rect(fb, stride, cx, cy, cw, ch, 0x1e293b);
        const border = if (id == focused_id) focus_ring() else 0x64748b;
        fill_rect(fb, stride, cx, cy, cw, 2, border);
        fill_rect(fb, stride, cx, cy + ch - 2, cw, 2, border);
        fill_rect(fb, stride, cx, cy, 2, ch, border);
        fill_rect(fb, stride, cx + cw - 2, cy, 2, ch, border);
        // Title band: first bytes of the window title.
        if (find_user_window(id)) |win| {
            const max_chars = if (cw > 8) (cw - 8) / 8 else 0;
            const n = @min(win.title.len, max_chars);
            if (n > 0) draw_string(fb, stride, cx + 4, cy + 4, win.title[0..n], 0xffffff);
            // Live content scaled into the card below the title band.
            const thumb_y = cy + @as(usize, geom.title_bar_h);
            const thumb_h = ch -| (@as(usize, geom.title_bar_h) + 2);
            const thumb_w = cw -| 4;
            if (thumb_w > 0 and thumb_h > 0) {
                var src: ?[*]const u8 = null;
                var src_w: usize = 0;
                var src_h: usize = 0;
                var src_stride: usize = 0;
                if (user_surface(id)) |sf| {
                    // #2111: read the surface only while the rect fits it.
                    if (surface_covers(sf.page_count, win.w, win.h)) {
                        src = @as([*]const u8, @ptrFromInt(sf.pa_base));
                        src_w = win.w;
                        src_h = win.h;
                        src_stride = @as(usize, win.w) * 4;
                    }
                }
                if (src == null and win.kbuf_pa != 0) {
                    src = kbuf_ptr(win);
                    src_w = win.w;
                    src_h = win.h;
                    src_stride = @as(usize, win.w) * 4;
                }
                if (src) |s| blit_scaled(fb, stride, s, src_w, src_h, src_stride, cx + 2, thumb_y, thumb_w, thumb_h);
            }
        }
    }
    // Workspace strip: one button per workspace, current highlighted.
    var ws: u8 = 0;
    while (ws < geom.overview_ws_count) : (ws += 1) {
        const b = geom.overview_ws_button_rect(ws, sw, geom.dock_w, g.strip_y);
        const bg = if (ws == current_workspace) taskbar_entry_active() else 0x0f172a;
        fill_rect(fb, stride, @as(usize, b.x), @as(usize, b.y), @as(usize, b.w), @as(usize, b.h), bg);
        var label: [4]u8 = .{ 'W', 'S', ' ', '0' + ws };
        draw_string(fb, stride, @as(usize, b.x) + 6, @as(usize, b.y) + 10, &label, 0xffffff);
    }
}

// M32 WMS8 Gate 6 (issue #628): the kernel's drag-snap applied primitives
// (snap_zone_for_point / snap_zone_bounds / snap_window / snap_restore /
// snap_is_snapped / snap_current_zone + the per-window snap state) are
// DELETED — the WM owns snap-on-drop via its own mirror + the SHARED
// wnd_core.snap_zone_for_point / wnd_core.snap_zone_bounds rules (which
// stay). The kernel shim no longer snaps from the pointer.
// Tiling (M21 W1/W2) is a SEPARATE geometry policy the WM also serves via
// SET_STATE; it is NOT affected and its primitives remain below.

// ---------------------------------------------------------------------------
// M21 W1/W2 — Tiling mode
// ---------------------------------------------------------------------------

/// Usable area for tiled windows (avoids dock + taskbar).
pub const tile_x_start = dock_w;
pub const tile_y_start: u32 = 0;

/// M21 W1: toggle tiling for the focused window. When tiling is activated,
/// the focused window becomes master (or stack if a master already exists).
/// Max 2 tiled windows per workspace; third window reverts to floating.
pub fn toggle_tiling() void {
    const fid = focused_id;
    if (fid < user_window_id_base or fid >= user_window_id_base + user_windows_max) return;
    // If already tiled, detach this window (back to floating).
    if (tile_master_id) |mid| {
        if (mid == fid) {
            tile_master_id = null;
            if (tile_stack_id) |sid| {
                // Stack becomes the only tiled window — promote to master.
                tile_master_id = sid;
                tile_stack_id = null;
            }
            tile_mode = tile_master_id != null;
            apply_tile_layout();
            return;
        }
    }
    if (tile_stack_id) |sid| {
        if (sid == fid) {
            tile_stack_id = null;
            tile_mode = tile_master_id != null;
            apply_tile_layout();
            return;
        }
    }
    // Not yet tiled — add this window.
    if (tile_master_id == null) {
        tile_master_id = fid;
    } else if (tile_stack_id == null) {
        tile_stack_id = fid;
    } else {
        // Both slots occupied — detach the oldest (master) and shift.
        tile_master_id = tile_stack_id;
        tile_stack_id = fid;
    }
    tile_mode = true;
    apply_tile_layout();
}

/// M21 W2: swap which window is master and which is detail.
pub fn swap_master() void {
    if (!tile_mode) return;
    if (tile_master_id) |mid| {
        if (tile_stack_id) |sid| {
            tile_master_id = sid;
            tile_stack_id = mid;
        }
    }
    tile_master_side = !tile_master_side;
    apply_tile_layout();
}

/// Apply the current tiling layout: recalculate window rects for all
/// tiled windows. Master gets 2/3 width, detail gets 1/3.
pub fn apply_tile_layout() void {
    if (!tile_mode) return;
    const usable_w = virtio_gpu.fb_width - tile_x_start;
    const usable_h: u32 = virtio_gpu.fb_height - taskbar_h;
    const master_w: u32 = usable_w * tile_master_pct / 1000;
    const detail_w: u32 = usable_w - master_w;
    // Master window.
    if (tile_master_id) |mid| {
        if (find_user_window(mid)) |w| {
            const nx = if (tile_master_side) tile_x_start else tile_x_start + detail_w;
            // WM1: buffer follows the tile size; on pool exhaustion the
            // window keeps its old size at the new position.
            _ = reflow(w, nx, tile_y_start, master_w, usable_h);
            w.dirty = true;
            _ = mark_dirty(0); // terminal repaint behind old rect
        }
    }
    // Detail (stack) window.
    if (tile_stack_id) |sid| {
        if (find_user_window(sid)) |w| {
            const nx = if (tile_master_side) tile_x_start + master_w else tile_x_start;
            _ = reflow(w, nx, tile_y_start, detail_w, usable_h);
            w.dirty = true;
            _ = mark_dirty(0);
        }
    }
}

/// M21 W3: minimize the focused window. Saves its current rect for
/// restore. Returns false for unknown id or non-user window.
pub fn minimize_window(id: u8) bool {
    const s = user_window_slot(id) orelse return false;
    const w = find_user_window(id) orelse return false;
    // Save current rect for restore.
    minimize_prev_x[s] = w.x;
    minimize_prev_y[s] = w.y;
    minimize_prev_w[s] = w.w;
    minimize_prev_h[s] = w.h;
    minimize_prev_valid[s] = true;
    // Mark as minimized and hide.
    w.minimized = true;
    w.visible = false;
    w.dirty = true;
    _ = mark_dirty(0); // reveal whatever sat under
    // WM3 (issue #707 card 3): the WM's mirror must follow a minimize —
    // it is a visibility change (the WMS5 rule) and the WM's taskbar
    // restore bit is derived from the hidden mirror. No-op in shim mode.
    wm_mirror(id);
    // Fall focus back to terminal or next window.
    if (focused_id == id) {
        focused_id = 0;
    }
    return true;
}

/// M21 W3: restore a minimized window from dock click. Returns false
/// if the window is not minimized or unknown.
pub fn restore_from_dock(id: u8) bool {
    const s = user_window_slot(id) orelse return false;
    const w = find_user_window(id) orelse return false;
    if (!w.minimized) return false;
    // Restore saved rect (same size the buffer already holds — WM1
    // reflow is a position-only fast path here).
    if (minimize_prev_valid[s]) {
        if (!reflow(w, minimize_prev_x[s], minimize_prev_y[s], minimize_prev_w[s], minimize_prev_h[s])) return false;
        minimize_prev_valid[s] = false;
    }
    w.minimized = false;
    w.visible = true;
    w.dirty = true;
    _ = focus(id);
    _ = raise(id);
    return true;
}

/// M32 WMS6 Gate D (issue #626): the dock-icon click ACTION — the exact chain
/// the shim's dock-click handler runs (restore the first minimized user
/// window, else focus + raise a user window, else open one), applied by the
/// registered WM via DOCK (cmd 9). Clamped: the bar has exactly 5 icons
/// (c n t b s), so an out-of-range index is refused (EINVAL). The action
/// itself is byte-identical to the shim's, so a WM decision and a shim click
/// are identical actions.
pub fn dock_icon_click(idx: u32) bool {
    if (idx >= 5) return false; // the bar has 5 icons
    var restored = false;
    var k: usize = 0;
    while (k < win_count) : (k += 1) {
        if (windows[k].kind == .user and windows[k].minimized) {
            _ = restore_from_dock(windows[k].id);
            restored = true;
            break;
        }
    }
    if (!restored) {
        var has_user = false;
        var kk: usize = 0;
        while (kk < win_count) : (kk += 1) {
            if (windows[kk].kind == .user) {
                has_user = true;
                break;
            }
        }
        if (!has_user) {
            _ = user_open(64, 64, 512, 384, 99);
        } else {
            var kkk: usize = 0;
            while (kkk < win_count) : (kkk += 1) {
                if (windows[kkk].kind == .user) {
                    _ = focus(windows[kkk].id);
                    _ = raise(windows[kkk].id);
                    break;
                }
            }
        }
    }
    _ = mark_dirty(0);
    return true;
}

/// WM3 (issue #707 card 3): the taskbar ENTRY enumeration snapshot — the
/// id-ascending current-workspace filter the `.taskbar` render walks.
/// The render iterates THIS (single source); `dui taskbar` reports it so
/// a live gate can grep the exact entries the bar draws.
pub const TaskbarEntry = struct { id: u8, focused: bool, minimized: bool };

pub fn taskbar_entries(buf: *[user_windows_max]TaskbarEntry) usize {
    var n: usize = 0;
    var id_i: usize = 0;
    while (id_i < user_windows_max) : (id_i += 1) {
        const ww = find_user_window(user_window_id_base + @as(u8, @intCast(id_i))) orelse continue;
        if (ww.workspace != current_workspace) continue;
        buf[n] = .{
            .id = ww.id,
            .focused = focused_id == ww.id,
            .minimized = ww.minimized and !ww.visible,
        };
        n += 1;
    }
    return n;
}

/// WM3 (issue #707 card 3): the taskbar-entry click ACTION — restore a
/// minimized entry, else focus + raise a visible one — applied by the
/// registered WM via TASKBAR (slot-65 cmd 12). The WM — not the kernel —
/// decides WHICH entry the click hit (it hit-tests the shared wnd_core
/// entry rects); the kernel clamps (the id must name a live user window)
/// and applies the SAME chain a shim click would run, so a WM decision
/// and a click on the same window are identical actions. Mirrors the
/// window back (the WM's mirror must see the restored/focused state).
pub fn taskbar_click(id: u8) bool {
    const win = find_user_window(id) orelse return false;
    if (win.minimized and !win.visible) {
        if (!restore_from_dock(id)) return false;
    } else {
        _ = focus(id);
        _ = raise(id);
    }
    _ = mark_dirty(0);
    wm_mirror(id);
    return true;
}

// ---------------------------------------------------------------------------
// M21 W6 — Maximize / restore
// ---------------------------------------------------------------------------

/// M21 W6: toggle maximize on the focused window. Maximized windows
/// fill the workspace area (screen minus taskbar and dock). Title bar
/// stays visible. Saves the pre-maximize rect for restore.
pub fn toggle_maximize(id: u8) bool {
    const s = user_window_slot(id) orelse return false;
    const w = find_user_window(id) orelse return false;
    if (w.maximized) {
        // Restore from maximize (WM1: buffer follows back down).
        if (pre_max_valid[s]) {
            if (!reflow(w, pre_max_x[s], pre_max_y[s], pre_max_w[s], pre_max_h[s])) return false;
            pre_max_valid[s] = false;
        }
        w.maximized = false;
    } else {
        // Save current rect and maximize.
        pre_max_x[s] = w.x;
        pre_max_y[s] = w.y;
        pre_max_w[s] = w.w;
        pre_max_h[s] = w.h;
        pre_max_valid[s] = true;
        // WM1: the pool buffer grows to the workspace area (content
        // overlap preserved); on pool exhaustion the window stays put.
        if (!reflow(w, dock_w, 0, virtio_gpu.fb_width - dock_w, virtio_gpu.fb_height - taskbar_h)) return false;
        w.maximized = true;
        // W6 edge case: tiled wins — clear tile state.
        if (tile_master_id) |mid| {
            if (mid == id) {
                tile_master_id = null;
                if (tile_stack_id) |sid| {
                    tile_master_id = sid;
                    tile_stack_id = null;
                }
                tile_mode = tile_master_id != null;
            }
        }
        if (tile_stack_id) |sid| {
            if (sid == id) tile_stack_id = null;
        }
    }
    w.dirty = true;
    _ = mark_dirty(0);
    return true;
}

// ---------------------------------------------------------------------------
// M21 W7 — Fullscreen mode
// ---------------------------------------------------------------------------

/// M21 W7: toggle fullscreen on the focused window. Fullscreen fills
/// the ENTIRE framebuffer (1280x720), no title bar, no border, taskbar
/// and dock hidden. Only the fullscreen window paints.
pub fn toggle_fullscreen(id: u8) bool {
    const w = find_user_window(id) orelse return false;
    if (fullscreen_active and fullscreen_window_id == id) {
        // Exit fullscreen — restore saved rect (WM1: buffer follows).
        const s = user_window_slot(id) orelse return false;
        if (pre_max_valid[s]) {
            if (!reflow(w, pre_max_x[s], pre_max_y[s], pre_max_w[s], pre_max_h[s])) return false;
            pre_max_valid[s] = false;
        }
        fullscreen_active = false;
        fullscreen_window_id = null;
        // Show taskbar and dock again.
        var i: usize = 0;
        while (i < win_count) : (i += 1) {
            if (windows[i].kind == .taskbar or windows[i].kind == .dock) {
                windows[i].visible = true;
                windows[i].dirty = true;
            }
        }
    } else {
        // Enter fullscreen — save current rect and fill screen.
        const s = user_window_slot(id) orelse return false;
        pre_max_x[s] = w.x;
        pre_max_y[s] = w.y;
        pre_max_w[s] = w.w;
        pre_max_h[s] = w.h;
        pre_max_valid[s] = true;
        // WM1: the pool buffer grows to the full framebuffer (content
        // overlap preserved); on pool exhaustion the window stays put.
        if (!reflow(w, 0, 0, virtio_gpu.fb_width, virtio_gpu.fb_height)) return false;
        fullscreen_active = true;
        fullscreen_window_id = id;
        // Hide taskbar and dock.
        var i: usize = 0;
        while (i < win_count) : (i += 1) {
            if (windows[i].kind == .taskbar or windows[i].kind == .dock) {
                windows[i].visible = false;
            }
        }
    }
    w.dirty = true;
    _ = mark_dirty(0);
    return true;
}

// ---------------------------------------------------------------------------
// M21 W8 — Always-on-top
// ---------------------------------------------------------------------------

/// M21 W8: toggle always-on-top on a user window. Always-on-top windows
/// render above all normal windows in the z-order.
pub fn toggle_always_on_top(id: u8) bool {
    const w = find_user_window(id) orelse return false;
    w.always_on_top = !w.always_on_top;
    w.dirty = true;
    _ = mark_dirty(0);
    return true;
}

// ---------------------------------------------------------------------------
// M21 W12 — Window title updates
// ---------------------------------------------------------------------------

/// M21 W12: set the dynamic title of a user window. Copies up to 63 bytes
/// (one byte reserved for NUL terminator in monitor output) into the
/// window's title buffer. The `title` slice is then pointed at the buffer
/// so taskbar, alt-tab, and monitor listings show the custom title.
/// Returns false for unknown window id.
pub fn set_window_title(id: u8, new_title: []const u8) bool {
    const w = find_user_window(id) orelse return false;
    const len = @min(new_title.len, 63);
    @memcpy(w.title_buf[0..len], new_title[0..len]);
    w.title_buf[len] = 0; // NUL-terminate for monitor safety
    w.title_len = @intCast(len);
    w.title = w.title_buf[0..len];
    w.dirty = true;
    _ = mark_dirty(0);
    return true;
}

// ---------------------------------------------------------------------------
// M21 W11 — Window persistence across sessions
// ---------------------------------------------------------------------------

pub const persist_record_bytes: usize = 32;
pub const persist_max_records: usize = 16;
pub const persist_max_bytes: usize = persist_record_bytes * persist_max_records;

pub fn serialize_state(buf: []u8) usize {
    if (buf.len < persist_max_bytes) return 0;
    var off: usize = 0;
    var wi: usize = 0;
    while (wi < win_count and off + persist_record_bytes <= buf.len) : (wi += 1) {
        const w = &windows[wi];
        if (w.kind != .user) continue;
        var flags: u8 = 0;
        if (w.minimized) flags |= 0x01;
        if (w.maximized) flags |= 0x02;
        if (w.always_on_top) flags |= 0x04;
        buf[off] = w.id;
        buf[off + 1] = flags;
        buf[off + 2] = w.workspace;
        buf[off + 3] = 0;
        buf[off + 4] = @truncate(w.x);
        buf[off + 5] = @truncate(w.x >> 8);
        buf[off + 6] = @truncate(w.x >> 16);
        buf[off + 7] = @truncate(w.x >> 24);
        buf[off + 8] = @truncate(w.y);
        buf[off + 9] = @truncate(w.y >> 8);
        buf[off + 10] = @truncate(w.y >> 16);
        buf[off + 11] = @truncate(w.y >> 24);
        buf[off + 12] = @truncate(w.w);
        buf[off + 13] = @truncate(w.w >> 8);
        buf[off + 14] = @truncate(w.w >> 16);
        buf[off + 15] = @truncate(w.w >> 24);
        buf[off + 16] = @truncate(w.h);
        buf[off + 17] = @truncate(w.h >> 8);
        buf[off + 18] = @truncate(w.h >> 16);
        buf[off + 19] = @truncate(w.h >> 24);
        @memset(buf[off + 20 .. off + 32], 0);
        const title = if (w.title_len > 0) w.title_buf[0..w.title_len] else w.title;
        const tlen = @min(title.len, 12);
        @memcpy(buf[off + 20 .. off + 20 + tlen], title[0..tlen]);
        off += persist_record_bytes;
    }
    return off;
}

pub fn restore_state(buf: []const u8, owner: usize) usize {
    var restored: usize = 0;
    var off: usize = 0;
    while (off + persist_record_bytes <= buf.len) : (off += persist_record_bytes) {
        const id: u8 = buf[off];
        if (id == 0) continue;
        const flags: u8 = buf[off + 1];
        const ws: u8 = buf[off + 2];
        const x = read_u32_le(buf[off + 4 .. off + 8]);
        const y = read_u32_le(buf[off + 8 .. off + 12]);
        const ww = read_u32_le(buf[off + 12 .. off + 16]);
        const wh = read_u32_le(buf[off + 16 .. off + 20]);
        if (ww == 0 or wh == 0) continue;
        if (x >= virtio_gpu.fb_width or y >= virtio_gpu.fb_height) continue;
        const result = user_open(x, y, ww, wh, owner);
        if (result != .opened) continue;
        const new_id = result.opened;
        const w = find_user_window(new_id) orelse continue;
        w.minimized = (flags & 0x01) != 0;
        w.maximized = (flags & 0x02) != 0;
        w.always_on_top = (flags & 0x04) != 0;
        w.workspace = ws;
        w.owner = owner;
        var tlen: usize = 0;
        while (tlen < 12 and buf[off + 20 + tlen] != 0) : (tlen += 1) {}
        if (tlen > 0) {
            _ = set_window_title(new_id, buf[off + 20 .. off + 20 + tlen]);
        }
        restored += 1;
    }
    return restored;
}

pub fn read_u32_le(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

// ---------------------------------------------------------------------------
// M21 W10 — Keyboard window movement
// ---------------------------------------------------------------------------

/// M21 W10: move the focused window by (dx, dy) pixels. Used for
/// Alt+arrow keyboard movement (16px normal, 1px with Shift).
pub fn move_window_keyboard(id: u8, dx: i32, dy: i32) bool {
    const w = find_user_window(id) orelse return false;
    const new_x: i32 = @as(i32, @intCast(w.x)) + dx;
    const new_y: i32 = @as(i32, @intCast(w.y)) + dy;
    const clamped_x: u32 = if (new_x < 0) 0 else @intCast(@min(@as(u32, @intCast(new_x)), virtio_gpu.fb_width - w.w));
    const clamped_y: u32 = if (new_y < 0) 0 else @intCast(@min(@as(u32, @intCast(new_y)), virtio_gpu.fb_height - w.h));
    w.x = clamped_x;
    w.y = clamped_y;
    w.dirty = true;
    _ = mark_dirty(0);
    return true;
}

/// M21 W10: resize the focused window by (dw, dh) pixels. Used for
/// Alt+Ctrl+arrow keyboard resizing (16px normal).
pub fn resize_window_keyboard(id: u8, dw: i32, dh: i32) bool {
    const w = find_user_window(id) orelse return false;
    const min_w: u32 = 128;
    const min_h: u32 = 64;
    const max_w: u32 = if (virtio_gpu.fb_width > w.x) virtio_gpu.fb_width - w.x else min_w;
    const max_h: u32 = if (virtio_gpu.fb_height > taskbar_h + w.y) virtio_gpu.fb_height - taskbar_h - w.y else min_h;
    const new_w: i32 = @as(i32, @intCast(w.w)) + dw;
    const new_h: i32 = @as(i32, @intCast(w.h)) + dh;
    const clamped_w: u32 = if (new_w < @as(i32, @intCast(min_w))) min_w else @min(@as(u32, @intCast(new_w)), max_w);
    const clamped_h: u32 = if (new_h < @as(i32, @intCast(min_h))) min_h else @min(@as(u32, @intCast(new_h)), max_h);
    // WM1: the pool buffer follows (content overlap preserved); on pool
    // exhaustion the window keeps its old size.
    if (!reflow(w, w.x, w.y, clamped_w, clamped_h)) return false;
    w.dirty = true;
    _ = mark_dirty(0);
    return true;
}

// ---------------------------------------------------------------------------
// M21 W15 — Modal windows
// ---------------------------------------------------------------------------

/// M21 W15: set a window as modal. Modal windows block input to windows
/// below them. Clicks outside the modal are ignored (except to dismiss).
pub fn set_modal(id: u8, modal: bool) bool {
    const w = find_user_window(id) orelse return false;
    w.modal = modal;
    if (modal) {
        // Raise the modal above all other windows.
        _ = raise(id);
        _ = focus(id);
    }
    return true;
}

/// M21 W15: check if a modal window is currently open.
pub fn modal_active() bool {
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].modal and windows[i].visible) return true;
    }
    return false;
}

/// M21 W15: get the topmost modal window id, or null.
pub fn topmost_modal_id() ?u8 {
    var i: usize = win_count;
    while (i > 0) {
        i -= 1;
        if (windows[i].modal and windows[i].visible) return windows[i].id;
    }
    return null;
}

// ---------------------------------------------------------------------------
// M21 W16 — Transient window behavior
// ---------------------------------------------------------------------------

/// M21 W16: set a window as transient with a timeout. Transient windows
/// are short-lived popups that auto-close when the timeout expires.
pub fn set_transient(id: u8, timeout: u32) bool {
    const w = find_user_window(id) orelse return false;
    w.transient = true;
    w.transient_timeout = timeout;
    return true;
}

/// M21 W16: advance transient timeouts. Called once per composite.
/// Returns the id of any window that expired (and was closed).
pub fn transient_advance_tick() ?u8 {
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].transient and windows[i].transient_timeout > 0) {
            windows[i].transient_timeout -|= 1;
            if (windows[i].transient_timeout == 0) {
                const id = windows[i].id;
                _ = user_close(id);
                return id;
            }
        }
    }
    return null;
}

/// M21 W16: dismiss all transient windows (e.g., on click-outside).
pub fn dismiss_transients() void {
    // Iterate backwards to handle removals safely.
    var i: usize = win_count;
    while (i > 0) {
        i -= 1;
        if (windows[i].transient) {
            _ = user_close(windows[i].id);
        }
    }
}

// ---------------------------------------------------------------------------
// M27 G6 — Tooltip system
// ---------------------------------------------------------------------------

/// M27 G6 / M32 WMS8 Gate 1 (claim 4270): tooltip surface functions — the
/// kernel clamps + places + blits; the dwell/hover decision is the WM's.
/// M32 WMS6 Gate C (issue #626) / M32 WMS8 Gate 1 (claim 4270): clear the
/// tooltip — the WM owns the WHEN/HIDE decision; its TOOLTIP (cmd 8) clear
/// reaches through here. No kernel hover timer remains.
pub fn tooltip_clear() void {
    tooltip_visible = false;
    tooltip_text_len = 0;
}

/// M32 WMS6 Gate C (issue #626): set + show the tooltip IMMEDIATELY — the
/// decision channel for the registered WM (TOOLTIP cmd 8). The WM owns the
/// dwell policy by choosing WHEN to show; the kernel's old 10-tick hover timer
/// and its dwell decision died with WMS8 Gate 1. The kernel still clamps +
/// places + blits the box.
pub fn tooltip_show_now() void {
    if (tooltip_text_len == 0) return;
    tooltip_visible = true;
    _ = mark_dirty(0);
}

/// M32 WMS6 Gate C (issue #626): set + show the tooltip at the kernel's own
/// cursor (the `cursor_x/cursor_y` the box renders below) — the one call the
/// registered WM's TOOLTIP show reaches through (clamped 32-byte bound).
pub fn tooltip_show(text: []const u8) void {
    // Place at the kernel's cursor; the WM decided WHEN + WHAT. The clamp is
    // 32 bytes (the frozen WM_RPC bound) — WMS8 keeps only the surface.
    tooltip_x = cursor_x;
    tooltip_y = cursor_y;
    const len = @min(text.len, 32);
    @memcpy(tooltip_text[0..len], text[0..len]);
    tooltip_text_len = @intCast(len);
    tooltip_visible = true;
    _ = mark_dirty(0);
}

// ---------------------------------------------------------------------------
// M27 G2 — About dialog
// ---------------------------------------------------------------------------

pub fn about_dialog_open_dialog() void {
    if (!about_dialog_open) {
        previous_focus = focused_id;
        about_dialog_open = true;
        _ = mark_dirty(0);
    }
}

pub fn about_dialog_close() void {
    if (about_dialog_open) {
        about_dialog_open = false;
        if (previous_focus) |pf| {
            _ = focus(pf);
            previous_focus = null;
        }
        _ = mark_dirty(0);
    }
}

/// M27 G2: toggle the about dialog.
pub fn about_dialog_toggle() void {
    if (!about_dialog_open) {
        about_dialog_open_dialog();
    } else {
        about_dialog_close();
    }
}

/// M27 G3: scale a window's framebuffer content into the preview buffer
/// using nearest-neighbor sampling. For user windows, reads the live
/// bytes — the shared surface when migrated (WM1 follows the SB3
/// surface-first convention; the old code read the frozen `user_bufs`
/// copy, which a migrated window never fills), else the pool back-buffer
/// at the window's own w×h (WM1: no more 512×424 full-buffer scale, so a
/// small window's thumbnail shows its content, not zero padding); for
/// the terminal, reads from the scanout framebuffer.
pub fn render_preview(id: u8) void {
    @memset(&preview_buf, 0);
    // Find the window and its source buffer.
    var src: [*]const u8 = undefined;
    var src_w: u32 = 0;
    var src_h: u32 = 0;
    var src_stride: usize = 0;
    if (id >= user_window_id_base) {
        const win = find_user_window(id) orelse return;
        if (win.kbuf_pa == 0 and user_surface(id) == null) return;
        // #2111: read the surface only while the rect still fits its pages;
        // a desync falls back to the pool back-buffer (always exactly w×h).
        if (user_surface(id)) |sf| {
            src = if (surface_covers(sf.page_count, win.w, win.h))
                @as([*]const u8, @ptrFromInt(sf.pa_base))
            else
                kbuf_ptr(win);
        } else {
            src = kbuf_ptr(win);
        }
        src_w = win.w;
        src_h = win.h;
        src_stride = @as(usize, win.w) * 4;
    } else if (id == 0) {
        // Terminal — read from scanout framebuffer.
        src = @ptrCast(&virtio_gpu.gpu_fb);
        src_w = virtio_gpu.fb_width;
        src_h = virtio_gpu.fb_height;
        src_stride = virtio_gpu.fb_width * 4;
    } else {
        return; // clock/deprecated — no preview
    }
    // Nearest-neighbor scale to preview_w × preview_h.
    var py: u32 = 0;
    while (py < preview_h) : (py += 1) {
        const src_y = py * src_h / preview_h;
        var px: u32 = 0;
        while (px < preview_w) : (px += 1) {
            const src_x = px * src_w / preview_w;
            const src_off = src_y * src_stride + src_x * 4;
            const dst_off = (py * preview_w + px) * 4;
            preview_buf[dst_off] = src[src_off];
            preview_buf[dst_off + 1] = src[src_off + 1];
            preview_buf[dst_off + 2] = src[src_off + 2];
            preview_buf[dst_off + 3] = 0xff;
        }
    }
}

/// Helper: user window slot index (id - base) or null.
pub fn user_window_slot(id: u8) ?usize {
    if (id < user_window_id_base) return null;
    const s = @as(usize, id - user_window_id_base);
    if (s >= user_windows_max) return null;
    return s;
}

/// Map raw pointer buttons bitmask to ADR 0009 button flags.
pub fn mouse_buttons_to_flags(buttons: u8) u16 {
    var flags: u16 = 0;
    if ((buttons & 0x01) != 0) flags |= events.BTN_LEFT;
    if ((buttons & 0x02) != 0) flags |= events.BTN_RIGHT;
    if ((buttons & 0x04) != 0) flags |= events.BTN_MIDDLE;
    return flags;
}

// #1688 (issue #1688): the CONTENT half of one pointer sample — mouse-
// tracking report vs local text selection — with explicit coordinates and
// explicit edge flags. Called twice in the system: from pointer_tick with
// the raw virtio stream's edges (shim path — the pre-#1688 structure,
// WMS5's no-compositing end-state untouched), and from wm_content_pointer
// below with the registered seat's forwarded sample (slot-65 cmd 15).
// mouseOwnsAt arbitrates at the sample's own coordinates exactly as the
// local path always has; the selection guards lost only their redundant
// `!mouseOwnsAt` conjunct, which the else makes implicit.
fn content_pointer_pass(
    nx: u32,
    ny: u32,
    moved: bool,
    cur_left: bool,
    cur_right: bool,
    left_pressed: bool,
    right_pressed: bool,
    left_released: bool,
    right_released: bool,
    press_handled: bool,
) void {
    if (mouseOwnsAt(nx, ny)) {
        if (terminalHitAt(nx, ny)) |mh| {
            if (terminal.screenForWindow(mh.win_id)) |mscr| {
                if (terminal.windowTerminal(mh.win_id)) |mtt| {
                    var kind: ?terminal.MouseKind = null;
                    var btn: u8 = 0;
                    if (left_pressed) {
                        kind = .press;
                        btn = 0;
                    } else if (right_pressed) {
                        kind = .press;
                        btn = 2;
                    } else if (left_released) {
                        kind = .release;
                        btn = 0;
                    } else if (right_released) {
                        kind = .release;
                        btn = 2;
                    } else if (moved and (cur_left or cur_right)) {
                        kind = .drag;
                        btn = if (cur_left) 0 else 2;
                    } else if (moved) {
                        kind = .motion;
                        btn = 0;
                    }
                    if (kind) |k| {
                        if (terminal.mouseReports(
                            mscr.mouse_1000,
                            mscr.mouse_1002,
                            mscr.mouse_1003,
                            k,
                        )) {
                            var enc: [24]u8 = undefined;
                            const n = terminal.encodeMouse(
                                mscr.mouse_1006,
                                k,
                                btn,
                                @intCast(mh.col + 1),
                                @intCast(mh.row + 1),
                                @intCast(mscr.cols),
                                &enc,
                            );
                            if (n > 0) {
                                if (k == .motion or k == .drag) {
                                    _ = mtt.stageMouseMotion(enc[0..n]);
                                } else {
                                    _ = mtt.pushMouse(enc[0..n]);
                                }
                            }
                        }
                    }
                }
            }
        }
    } else {
        if (left_pressed and !press_handled) {
            if (terminalHitAt(nx, ny)) |hit| {
                if (terminal.screenForWindow(hit.win_id)) |scr| {
                    scr.beginSelection(hit.line, hit.col);
                    term_sel_dragging = true;
                    klog.line("dui: term sel begin\n");
                }
            }
        } else if (cur_left and term_sel_dragging) {
            if (terminalHitAt(nx, ny)) |hit| {
                if (terminal.screenForWindow(hit.win_id)) |scr| {
                    scr.extendSelection(hit.line, hit.col);
                }
            }
        }
        if (left_released and term_sel_dragging) {
            // Land the final endpoint on the release position, then close
            // the selection (the gate's copy chord waits for this line).
            if (terminalHitAt(nx, ny)) |hit| {
                if (terminal.screenForWindow(hit.win_id)) |scr| {
                    scr.extendSelection(hit.line, hit.col);
                }
            }
            term_sel_dragging = false;
            klog.line("dui: term sel end\n");
        }
    }
}

// #1688: the seat-serialized forward stream's own sample history. Press/
// release edges and "moved" derive here exactly as prev_ptr_buttons and
// the stream deltas do for the raw path in pointer_tick, so the content
// pass cannot tell the two apart.
var wm_fwd_prev_buttons: u8 = 0;
var wm_fwd_prev_x: u32 = 0;
var wm_fwd_prev_y: u32 = 0;

/// #1688 (slot-65 cmd 15, wm_server.wmctl_content_ptr): the registered
/// seat forwarded one pointer sample for the kernel's LOCAL content path —
/// terminal text selection and mouse-tracking reports. Chrome the seat
/// consumed (start surface, rail, launcher) is never forwarded, so this
/// entry only ever sees content coordinates. Dormant with no seat: kernel
/// terminal selection stays exactly where WMS5 left it.
pub fn wm_content_pointer(x: u32, y: u32, buttons: u8) void {
    if (!wm_owns_input) return;
    const cur_left = (buttons & 0x01) != 0;
    const cur_right = (buttons & 0x02) != 0;
    const prev_left = (wm_fwd_prev_buttons & 0x01) != 0;
    const prev_right = (wm_fwd_prev_buttons & 0x02) != 0;
    const moved = (x != wm_fwd_prev_x or y != wm_fwd_prev_y);
    wm_fwd_prev_buttons = buttons;
    wm_fwd_prev_x = x;
    wm_fwd_prev_y = y;
    content_pointer_pass(
        x,
        y,
        moved,
        cur_left,
        cur_right,
        (!prev_left and cur_left),
        (!prev_right and cur_right),
        (prev_left and !cur_left),
        (prev_right and !cur_right),
        false, // the seat consumed chrome; no local press latch applies
    );
}

/// Card U4 (claim 4993): the pointer tick — consume the pointer state from
/// the input path (motion + click edges). Returns the newly focused window
/// id when a CLICK landed on a window (D4: click = focus + raise), null
/// otherwise. Called from the shell idle loop; a no-op when the input path
/// is unarmed (the default VM).
/// Card E3 (claim 9228): converts absolute pointer motion and button clicks
/// within a user window to window-local coordinates and queues MOUSE_DOWN,
/// MOUSE_UP, and MOUSE_MOVE events to the hit user window's owning process.
pub fn pointer_tick(st: input.PointerState, click: ?input.Click) ?u8 {
    if (!armed_global) return null;
    var focused_changed: ?u8 = null;
    if (st.valid) {
        const nx = map_pointer_axis(st.x, virtio_gpu.fb_width);
        const ny = map_pointer_axis(st.y, virtio_gpu.fb_height);
        const moved = (!cursor_shown or nx != cursor_x or ny != cursor_y);
        if (moved) {
            if (cursor_shown and cursor_old_damage == null)
                cursor_old_damage = cursor_rect(cursor_x, cursor_y, virtio_gpu.fb_width, virtio_gpu.fb_height);
            cursor_x = nx;
            cursor_y = ny;
            cursor_shown = true;
            cursor_new_damage = cursor_rect(nx, ny, virtio_gpu.fb_width, virtio_gpu.fb_height);
            // M27 G6: clear tooltip on mouse move. M32 WMS6 Gate D (issue
            // #626): while a WM owns input the tooltip policy lives in the WM
            // — it receives the move (kind 19) and decides when to hide
            // (TOOLTIP cmd 8), so the kernel's blanket move-clear must NOT
            // fight its decisions (it gates behind !wm_owns_input like the
            // other shim decisions).
            if (!wm_owns_input) tooltip_clear();
            _ = mark_dirty(0); // the cursor moves over a full repaint
        }

        // M32 WMS5 (issue #625): the input-seam handover — while a WM is
        // registered it owns pointer GEOMETRY. The kernel keeps tracking the
        // cursor (a blit surface) but fans the raw stream out and consumes
        // nothing: no drag, no resize, no snap, no focus-at, no minimize/
        // close buttons. The WM hit-tests and issues SET_WINDOW rects; the
        // kernel clamps + blits those. Zero regression: shim mode (the
        // default) runs the full geometry block below byte-identically.
        if (wm_owns_input) {
            // Deliver the sample when the pointer state CHANGED — motion OR
            // a button edge (a release with no motion must still be seen).
            // wm_fan_pointer owns the dedup (shared with the per-report
            // decode fan): the tick is now only the residual fan for
            // reports that never saw decode (the USB path still samples
            // here; a cv report decode already fanned is a no-op repeat).
            wm_fan_pointer(st.x, st.y, st.buttons);
            prev_ptr_buttons = st.buttons;
            return null; // no kernel geometry decision while the WM owns input
        }

        const kb_flags = input.hid_modifiers_to_flags(input.report().kb_mods);
        const btn_flags = mouse_buttons_to_flags(st.buttons);
        const all_flags = btn_flags | kb_flags;

        const left_bit: u8 = 0x01;
        const right_bit: u8 = 0x02;
        const prev_left = (prev_ptr_buttons & left_bit) != 0;
        const prev_right = (prev_ptr_buttons & right_bit) != 0;
        const cur_left = (st.buttons & left_bit) != 0;
        const cur_right = (st.buttons & right_bit) != 0;
        const left_pressed = (!prev_left and cur_left) or (click != null);
        const left_released = (prev_left and !cur_left);
        const right_pressed = (!prev_right and cur_right);
        const right_released = (prev_right and !cur_right);

        // M49 SD5 (#1132): pointer text selection in a terminal-bound
        // window's client area. Selection is model-only here (terminal.zig);
        // Ctrl+Shift+C copies it (input.zig). The click below still focuses
        // the window. The press latch survives a whole injected drag being
        // drained in one pass (last-write-wins state would lose the down).
        // M73i (#1635): mouse tracking owns a plain pointer over a bound
        // window — the app gets the report, selection stays local, and
        // Shift (or modes off) hands everything back to the local path.
        // #1688: the report-or-selection decision itself lives in
        // content_pointer_pass below — one body, called from here with the
        // raw stream's edges and from wm_content_pointer with the registered
        // seat's forwarded sample — so the two paths cannot diverge.
        var press_handled = false;
        if (input.take_press()) |p| {
            const px = map_pointer_axis(p.x, virtio_gpu.fb_width);
            const py = map_pointer_axis(p.y, virtio_gpu.fb_height);
            if (mouseOwnsAt(px, py)) {
                // The latched press belongs to the app: consume it, suppress
                // the stale-cursor begin below, let the report path deliver.
                press_handled = true;
            } else if (terminalHitAt(px, py)) |hit| {
                if (terminal.screenForWindow(hit.win_id)) |scr| {
                    scr.beginSelection(hit.line, hit.col);
                    press_handled = true;
                    if (cur_left) {
                        // A held drag: keep extending on later samples.
                        term_sel_dragging = true;
                        if (terminalHitAt(cursor_x, cursor_y)) |end| {
                            if (end.win_id == hit.win_id) scr.extendSelection(end.line, end.col);
                        }
                        klog.line("dui: term sel begin\n");
                    } else {
                        // The whole injected drag drained in one pass: the
                        // current sample IS the end.
                        if (terminalHitAt(cursor_x, cursor_y)) |end| {
                            if (end.win_id == hit.win_id) scr.extendSelection(end.line, end.col);
                        }
                        klog.line("dui: term sel end\n");
                    }
                }
            }
        }
        content_pointer_pass(
            cursor_x,
            cursor_y,
            moved,
            cur_left,
            cur_right,
            left_pressed,
            right_pressed,
            left_released,
            right_released,
            press_handled,
        );

        // Step 5/6/7: drag + close + minimize handling on MOUSE_DOWN (left only).
        // M15 C4: dock handling must precede user windows — dock is at 0,0,24,700.
        if (left_pressed) {
            var handled_btn = false;
            // Arc4 #242: the unsaved-dialog click intercept is DELETED (M32
            // WMS8 Gate 4, issue #628) — the WM owns the unsaved-dialog
            // decision via slot-65 DIALOG (cmd 11); with a WM registered
            // pointer_tick returns early above, and without one the dialog
            // can never open (the close dirty-check is deleted too).
            // M21 W15: modal windows block input to windows below.
            // Clicks outside the modal are ignored (except to dismiss).
            if (!handled_btn and modal_active()) {
                if (topmost_modal_id()) |modal_id| {
                    if (find_user_window(modal_id)) |mw| {
                        if (cursor_x >= mw.x and cursor_x < mw.x + mw.w and
                            cursor_y >= mw.y and cursor_y < mw.y + mw.h)
                        {
                            // Click inside modal — process normally below.
                        } else {
                            // Click outside modal — dismiss transient popups.
                            if (mw.transient) {
                                _ = user_close(modal_id);
                                handled_btn = true;
                            } else {
                                // Non-transient modal: ignore click.
                                handled_btn = true;
                            }
                        }
                    }
                }
            }
            // M32 WMS8 Gate 7 (issue #628): the kernel's dock-click, tray-click,
            // and notification-panel click DECISION blocks are deleted — WMS6
            // Gates B and D proved the WM owns those decisions (kind-19 ->
            // NOTIF_CENTER / NOTIF_DISMISS / DOCK) with parity gates green, so
            // the !wm_owns_input-gated shim copies were dormant whenever a WM is
            // registered. The applied primitives stay (slot-65 cmds 6/7/9 + the
            // dui monitor commands drive them; the panel/blit rendering is
            // unchanged). Shim end-state (intended): with no WM registered,
            // dock/tray/panel clicks do nothing — the issue's "no compositing
            // policy" end-state.
            // M27 G2: the about-dialog close-button hit-test is DELETED (M32
            // WMS8 Gate 3, issue #628) — the WM owns the about dialog via
            // slot-65 DIALOG (cmd 11); with a WM registered pointer_tick returns
            // early above, and without one about_dialog_open can never be set,
            // so the click path was provably dead.
            if (!handled_btn) {
                // Check close/minimize buttons on user windows first.
                var wi: usize = win_count;
                while (wi > 0) {
                    wi -= 1;
                    const w = &windows[wi];
                    if (w.kind != .user or !w.visible) continue;
                    // Close button: top-right corner (x + w.w - 14, y + 4, 8x8).
                    if (cursor_x >= w.x + w.w - 16 and cursor_x < w.x + w.w - 4 and
                        cursor_y >= w.y and cursor_y < w.y + user_title_h)
                    {
                        // Arc4 #242 / M32 WMS8 Gate 4 (issue #628): the dirty-
                        // check is DELETED — the WM owns the unsaved-dialog
                        // decision (cmd-11 DIALOG actions 3-6); in shim mode
                        // closing a dirty window closes it immediately (the
                        // issue's "no compositing policy" end-state).
                        _ = user_close(w.id);
                        handled_btn = true;
                        break;
                    }
                    // Minimize button: left of close (x + w.w - 26, y + 4, 8x8).
                    if (cursor_x >= w.x + w.w - 28 and cursor_x < w.x + w.w - 16 and
                        cursor_y >= w.y and cursor_y < w.y + user_title_h)
                    {
                        _ = user_set_visible(w.id, false);
                        handled_btn = true;
                        break;
                    }
                    // Arc2 W1: resize handle — 6×6 bottom-right corner.
                    if (is_resize_hit(w.*, cursor_x, cursor_y)) {
                        resize_id = w.id;
                        resize_start_x = cursor_x;
                        resize_start_y = cursor_y;
                        resize_origin_w = w.w;
                        resize_origin_h = w.h;
                        _ = focus(w.id);
                        _ = raise(w.id);
                        _ = mark_dirty(0);
                        focused_changed = w.id;
                        handled_btn = true;
                        break;
                    }
                    // M32 WMS8 Gate 6 (issue #628): the title-bar DRAG-initiation
                    // block is DELETED — WMS5 proved the WM owns title-bar drag
                    // (kind 19 -> SET_WINDOW -> user_move). With a WM registered
                    // pointer_tick returns early, so this was dormant. A title-bar
                    // click below simply falls through to focus-at (focusing the
                    // window) — no drag is started by the kernel shim.
                }
            }
            // Fall through to normal focus-at if no button/title bar was hit.
            if (!handled_btn) {
                if (focus_at(cursor_x, cursor_y)) {
                    const id = focused_id;
                    _ = raise(id);
                    _ = mark_dirty(0);
                    focused_changed = id;
                }
            }
        }
        // Arc2 W2: right-click — focus the hit window (no drag/resize/close).
        if (right_pressed) {
            if (focus_at(cursor_x, cursor_y)) {
                const id = focused_id;
                _ = raise(id);
                _ = mark_dirty(0);
                focused_changed = id;
            }
        }

        // Arc2 W1: resize drag — live clamp + chrome repaint + WIN_RESIZE.
        if (resize_id) |rid| {
            if (moved and cur_left) {
                const dx = @as(i32, @intCast(cursor_x)) - @as(i32, @intCast(resize_start_x));
                const dy = @as(i32, @intCast(cursor_y)) - @as(i32, @intCast(resize_start_y));
                const req_w = @as(i32, @intCast(resize_origin_w)) + dx;
                const req_h = @as(i32, @intCast(resize_origin_h)) + dy;
                const win = find_user_window(rid) orelse null;
                if (win) |w| {
                    const new_w = clamp_resize_w(req_w, w.x);
                    const new_h = clamp_resize_h(req_h, w.y);
                    if (new_w != w.w or new_h != w.h) {
                        _ = user_resize(rid, new_w, new_h);
                    }
                }
            }
            if (left_released) {
                resize_id = null;
            }
        } else if (moved and !cur_left and !cur_right and focus_follows_mouse) {
            // M27 G13: Focus-follows-mouse
            if (focus_at(cursor_x, cursor_y)) {
                const id = focused_id;
                _ = raise(id);
                _ = mark_dirty(0);
                focused_changed = id;
            }
        }

        // Arc4 #237: drag-and-drop — detect window crossing during active drag.
        if (drag_active and moved) {
            const new_hit = hit_test(cursor_x, cursor_y);
            const new_id: ?u8 = if (new_hit) |hid| blk: {
                if (find_user_window(hid)) |w| {
                    if (w.owner) |_| break :blk hid;
                }
                break :blk null;
            } else null;
            if (new_id != drag_over_id) {
                // DRAG_LEAVE to old window.
                if (drag_over_id) |old_id| {
                    if (find_user_window(old_id)) |ow| {
                        if (ow.owner) |old_owner| {
                            events.push(old_owner, .{
                                .kind = events.DRAG_LEAVE,
                                .flags = 0,
                                .seq = 0,
                                .arg0 = 0,
                                .arg1 = @intCast(drag_source_pid),
                            });
                        }
                    }
                }
                // DRAG_ENTER to new window.
                if (new_id) |nid| {
                    if (find_user_window(nid)) |nw| {
                        if (nw.owner) |new_owner| {
                            events.push(new_owner, .{
                                .kind = events.DRAG_ENTER,
                                .flags = 0,
                                .seq = 0,
                                .arg0 = @intCast(drag_payload_len),
                                .arg1 = @intCast(drag_source_pid),
                            });
                        }
                    }
                }
                drag_over_id = new_id;
            }
        }
        // Arc4 #237: DROP on left release during active drag.
        // Two-step: DROP event signals payload available (arg0=size),
        // then the target calls sys_drag_read to copy the payload.
        if (drag_active and left_released) {
            if (hit_test(cursor_x, cursor_y)) |drop_id| {
                if (find_user_window(drop_id)) |dw| {
                    if (dw.owner) |drop_owner| {
                        events.push(drop_owner, .{
                            .kind = events.DROP,
                            .flags = 0,
                            .seq = 0,
                            .arg0 = @intCast(drag_payload_len),
                            .arg1 = @intCast(drag_source_pid),
                        });
                    }
                }
            }
            // Don't clear drag_active yet — sys_drag_read needs the payload.
            // Clear after the target reads or on a new sys_drag_start.
        }

        // Deliver pointer events to hit user window
        if (hit_test(cursor_x, cursor_y)) |hit_id| {
            if (find_user_window(hit_id)) |w| {
                if (w.owner) |owner_pid| {
                    const local_x: u32 = if (cursor_x >= w.x) @min(cursor_x - w.x, w.w - 1) else 0;
                    const local_y: u32 = if (cursor_y >= w.y) @min(cursor_y - w.y, w.h - 1) else 0;

                    if (moved) {
                        events.push(owner_pid, .{
                            .kind = events.MOUSE_MOVE,
                            .flags = all_flags,
                            .seq = 0,
                            .arg0 = local_x,
                            .arg1 = local_y,
                        });
                    }
                    if (left_pressed) {
                        events.push(owner_pid, .{
                            .kind = events.MOUSE_DOWN,
                            .flags = all_flags,
                            .seq = 0,
                            .arg0 = local_x,
                            .arg1 = local_y,
                        });
                    }
                    if (left_released) {
                        events.push(owner_pid, .{
                            .kind = events.MOUSE_UP,
                            .flags = all_flags,
                            .seq = 0,
                            .arg0 = local_x,
                            .arg1 = local_y,
                        });
                    }
                    if (right_pressed) {
                        events.push(owner_pid, .{
                            .kind = events.MOUSE_RIGHT_DOWN,
                            .flags = all_flags,
                            .seq = 0,
                            .arg0 = local_x,
                            .arg1 = local_y,
                        });
                    }
                    if (right_released) {
                        events.push(owner_pid, .{
                            .kind = events.MOUSE_RIGHT_UP,
                            .flags = all_flags,
                            .seq = 0,
                            .arg0 = local_x,
                            .arg1 = local_y,
                        });
                    }
                }
            }
        }

        prev_ptr_buttons = st.buttons;
    }
    return focused_changed;
}

/// HID absolute pointers report 0..32767 logical; map onto the framebuffer
/// axis. Pure — host-testable.
pub fn map_pointer_axis(v: u16, span: u32) u32 {
    const scaled = (@as(u32, v) * span + 16384) / 32768;
    return if (scaled >= span) span - 1 else scaled;
}

/// Card U4: the cursor's current framebuffer cell (for reports + tests).
pub fn cursor_pos() ?struct { x: u32, y: u32 } {
    if (!cursor_shown) return null;
    return .{ .x = cursor_x, .y = cursor_y };
}

pub fn cursor_rect(x: u32, y: u32, width: u32, height: u32) ?CursorRect {
    if (width == 0 or height == 0) return null;
    const left: i64 = @as(i64, x) - cursor_hotspot.x;
    const top: i64 = @as(i64, y) - cursor_hotspot.y;
    const x0 = @max(left, 0);
    const y0 = @max(top, 0);
    const x1 = @min(left + cursor_w, width);
    const y1 = @min(top + cursor_h, height);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = @intCast(x0), .y = @intCast(y0), .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
}

pub fn cursor_pixel(x: usize, y: usize, resizing: bool) ?u32 {
    if (y >= cursor_mask.len or x >= cursor_w) return null;
    return switch (cursor_mask[y][x]) {
        '#' => cursor_outline_rgb,
        'o' => if (resizing) 0xffaa00 else cursor_rgb,
        else => null,
    };
}

/// Save only opaque mask pixels. A seat frame gets the cursor LAST, and its
/// shared compose target is restored immediately after transfer/flush so the
/// seat never reads the cursor into its own chrome/back buffers.
pub fn cursor_draw() void {
    if (!cursor_shown) return;
    cursor_restore();
    const fb = &virtio_gpu.gpu_fb;
    for (0..cursor_h) |my| {
        for (0..cursor_w) |mx| {
            const rgb = cursor_pixel(mx, my, resize_id != null) orelse continue;
            const x = @as(i64, cursor_x) - cursor_hotspot.x + @as(i64, @intCast(mx));
            const y = @as(i64, cursor_y) - cursor_hotspot.y + @as(i64, @intCast(my));
            if (x < 0 or y < 0 or x >= virtio_gpu.fb_width or y >= virtio_gpu.fb_height) continue;
            const at: usize = @intCast((y * virtio_gpu.fb_width + x) * 4);
            cursor_saved[my * cursor_w + mx] = std.mem.readInt(u32, fb[at..][0..4], .little);
            put_px(fb, virtio_gpu.fb_width * 4, @intCast(x), @intCast(y), rgb);
        }
    }
    cursor_drawn_x = cursor_x;
    cursor_drawn_y = cursor_y;
    cursor_drawn_resize = resize_id != null;
    cursor_drawn = true;
}

pub fn cursor_restore() void {
    if (!cursor_drawn) return;
    const fb = &virtio_gpu.gpu_fb;
    for (0..cursor_h) |my| {
        for (0..cursor_w) |mx| {
            const rgb = cursor_pixel(mx, my, cursor_drawn_resize) orelse continue;
            const x = @as(i64, cursor_drawn_x) - cursor_hotspot.x + @as(i64, @intCast(mx));
            const y = @as(i64, cursor_drawn_y) - cursor_hotspot.y + @as(i64, @intCast(my));
            if (x < 0 or y < 0 or x >= virtio_gpu.fb_width or y >= virtio_gpu.fb_height) continue;
            const at: usize = @intCast((y * virtio_gpu.fb_width + x) * 4);
            // Do not restore stale underlay over a newer seat/application store.
            if (std.mem.readInt(u32, fb[at..][0..4], .little) == (rgb | 0xff000000))
                std.mem.writeInt(u32, fb[at..][0..4], cursor_saved[my * cursor_w + mx], .little);
        }
    }
    cursor_drawn = false;
}

pub fn cursor_damage_clear() void {
    cursor_old_damage = null;
    cursor_new_damage = null;
}

// ---------------------------------------------------------------------------
// Pixel helpers (pure — host-testable)
// ---------------------------------------------------------------------------

pub fn put_px(buf: [*]u8, stride: usize, x: usize, y: usize, rgb: u32) void {
    const off = y * stride + x * 4;
    buf[off] = @truncate(rgb & 0xff); // B
    buf[off + 1] = @truncate((rgb >> 8) & 0xff); // G
    buf[off + 2] = @truncate((rgb >> 16) & 0xff); // R
    buf[off + 3] = 0xff; // X — opaque (the claim-6053 lesson)
}

pub fn fill_rect(buf: [*]u8, stride: usize, x0: usize, y0: usize, w: usize, h: usize, rgb: u32) void {
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) put_px(buf, stride, x0 + x, y0 + y, rgb);
    }
}

/// Draw one 8x8 glyph at (x0, y0) in the given 0xRRGGBB color. Non-printable
/// bytes are skipped (no invented pixels).
pub fn draw_glyph(buf: [*]u8, stride: usize, x0: usize, y0: usize, c: u8, rgb: u32) void {
    if (c < 0x20 or c > 0x7e) return;
    const glyph = font.glyphs[c - 0x20];
    var gy: usize = 0;
    while (gy < 8) : (gy += 1) {
        const bits = glyph[gy];
        var gx: usize = 0;
        while (gx < 8) : (gx += 1) {
            if (font.row_pixel(bits, gx)) put_px(buf, stride, x0 + gx, y0 + gy, rgb);
        }
    }
}

pub fn draw_string(buf: [*]u8, stride: usize, x0: usize, y0: usize, s: []const u8, rgb: u32) void {
    for (s, 0..) |c, i| draw_glyph(buf, stride, x0 + i * 8, y0, c, rgb);
}

/// M73a-2 (#1631): resolve one terminal rune cell to its 8x8 rows — the
/// shared M20 lookup (`text.glyph_for` → `font_unicode`), the pinned
/// fallback (unmapped or ill-formed art is U+FFFD, never a skip), and
/// part 1's overlay policy OR'd onto the base.
pub fn rune_cell_rows(cell: terminal.Cell) [8]u8 {
    const base = fbtext.glyph_for(cell.base) orelse &font_unicode.fffd_glyph;
    var rows = base.*;
    if (cell.mark != 0) {
        if (font_unicode.combining_overlay(cell.mark)) |ov| {
            for (0..8) |i| rows[i] |= ov[i];
        }
    }
    return rows;
}

/// M73l (#1661): paint one cell at (x0, y0). ASCII with no overlay
/// paints from the FiraCode atlas — the face IS the cell now (8×16,
/// 4-bit alpha over the cell fill); everything else keeps the composed
/// 8×8 rune art, stretched ×1/×2 into the taller cell (no coverage
/// regression). A wide base still spans both cells of its pair —
/// `wide` is the caller's clipped pair check — and a continuation cell
/// draws nothing (the base owns the pair: no double-draw, no shift).
pub fn draw_cell_glyph(buf: [*]u8, stride: usize, x0: usize, y0: usize, cell: terminal.Cell, rgb: u32, wide: bool, italic: bool) void {
    if (cell.cont != 0) return;
    // M73l: the atlas path — M72b's byte-identical font8x8 fast path
    // retires with the 8×8 cell (ADR 0020 Amendment F).
    if (cell.mark == 0 and cell.base >= 0x20 and cell.base <= 0x7e) {
        draw_atlas_glyph(buf, stride, x0, y0, cell.base, rgb, italic);
        return;
    }
    // Fallback: composed rows (rune/overlay path), nearest-neighbour
    // stretched over the WHOLE tall cell (M80i #1725: the zoom ladder's
    // cells are 13/16/21 tall — no longer a multiple of 8 — so every
    // output row samples its source row instead of a fixed ×1/×2
    // repeat). At cell_h 8/16 the mapping is byte-identical to the old
    // stretch; at 13/21 it fills the cell instead of stranding the
    // bottom rows empty.
    const rows = rune_cell_rows(cell);
    const ch: usize = font_metrics.cell_h;
    var dy: usize = 0;
    while (dy < ch) : (dy += 1) {
        const bits = rows[dy * 8 / ch];
        // M73h (Amendment E): fake italic — top rows shift right up
        // to 2px, bottom none, same ≤2px rendition over the taller
        // cell. A pixel that would leave the cell is DROPPED (no
        // column bleed: the pixel gates pin x extents).
        const xoff: usize = if (italic) italic_shear(dy) else 0;
        var gx: usize = 0;
        while (gx < 8) : (gx += 1) {
            if (font.row_pixel(bits, gx)) {
                if (gx + xoff < font_metrics.cell_w) {
                    put_px(buf, stride, x0 + gx + xoff, y0 + dy, rgb);
                    if (wide) put_px(buf, stride, x0 + gx + xoff + font_metrics.cell_w, y0 + dy, rgb);
                }
            }
        }
    }
}

/// M73l: the ≤2px top shear, linear over the cell's height — dy 0 (cell
/// top) shifts 2px right, dy cell_h-1 (bottom) shifts none.
fn italic_shear(dy: usize) usize {
    return ((font_metrics.cell_h - 1 - dy) * 2) / (font_metrics.cell_h - 1);
}

/// M73l: one atlas glyph, alpha-blended over the cell fill. Placement
/// is baked into the fixture (baseline at `ascent` from the top), so
/// this walks rows 0..cell_h and high/low nibbles per byte. Pixels the
/// shear would push past the cell edge are dropped (M73h x-extent pin).
/// M80i (#1725): the blob and its row/glyph strides come from the
/// ACTIVE cell (font_metrics), so the painter follows the zoom ladder
/// — each size's atlas is rasterized at its own pixel size.
fn draw_atlas_glyph(buf: [*]u8, stride: usize, x0: usize, y0: usize, cp: u21, rgb: u32, italic: bool) void {
    const blob = font_metrics.active().blob;
    const off: usize = @as(usize, cp - font_metrics.first_cp) * font_metrics.glyph_bytes;
    const row_stride = font_metrics.row_bytes; // cell_w/2 rounded up: 4-bit pixels
    var dy: usize = 0;
    while (dy < font_metrics.cell_h) : (dy += 1) {
        const xoff: usize = if (italic) italic_shear(dy) else 0;
        const row = off + dy * row_stride;
        var gx: usize = 0;
        while (gx < font_metrics.cell_w) : (gx += 1) {
            const byte = blob[row + gx / 2];
            const lvl: u8 = if (@rem(gx, 2) == 0) byte >> 4 else byte & 0x0f;
            if (lvl == 0) continue;
            if (gx + xoff >= font_metrics.cell_w) continue;
            put_alpha_px(buf, stride, x0 + gx + xoff, y0 + dy, rgb, lvl * 17);
        }
    }
}

/// M73l: blend one atlas pixel (alpha 0..255) over what the cell fill
/// left. Level 15 lands exactly on fg (255/255 — no rounding slop for
/// the golden pins), level 0 is never called.
fn put_alpha_px(buf: [*]u8, stride: usize, x: usize, y: usize, rgb: u32, a: u16) void {
    const off = y * stride + x * 4;
    const inv: u16 = 255 - a;
    const s_b: u16 = @truncate(rgb & 0xff);
    const s_g: u16 = @truncate((rgb >> 8) & 0xff);
    const s_r: u16 = @truncate((rgb >> 16) & 0xff);
    buf[off] = @intCast((@as(u16, buf[off]) * inv + s_b * a) / 255);
    buf[off + 1] = @intCast((@as(u16, buf[off + 1]) * inv + s_g * a) / 255);
    buf[off + 2] = @intCast((@as(u16, buf[off + 2]) * inv + s_r * a) / 255);
    buf[off + 3] = 0xff;
}

/// Step 6 (Issue #206): draw one 8×16 glyph at (x0, y0). Uses the 2×-stretched
/// glyph table for titles and headings. Non-printable bytes are skipped.
pub fn draw_glyph_16(buf: [*]u8, stride: usize, x0: usize, y0: usize, c: u8, rgb: u32) void {
    if (c < 0x20 or c > 0x7e) return;
    const glyph = font.glyphs_16[c - 0x20];
    var gy: usize = 0;
    while (gy < 16) : (gy += 1) {
        const bits = glyph[gy];
        var gx: usize = 0;
        while (gx < 8) : (gx += 1) {
            if (font.row_pixel_16(bits, gx)) put_px(buf, stride, x0 + gx, y0 + gy, rgb);
        }
    }
}

/// Draw a string using the 8×16 font. Each glyph advances 8px horizontally.
pub fn draw_string_16(buf: [*]u8, stride: usize, x0: usize, y0: usize, s: []const u8, rgb: u32) void {
    for (s, 0..) |c, i| draw_glyph_16(buf, stride, x0 + i * 8, y0, c, rgb);
}

/// Minimal unsigned-decimal formatting (no heap, no failure modes) — the
/// clock's dynamic text. Returns the filled slice.
pub fn fmt_decimal(buf: []u8, v: u64) []const u8 {
    if (buf.len == 0) return "";
    if (v == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (x > 0 and n < tmp.len) : (n += 1) {
        tmp[n] = @as(u8, @intCast(x % 10)) + '0';
        x /= 10;
    }
    const out = @min(n, buf.len);
    var i: usize = 0;
    while (i < out) : (i += 1) buf[i] = tmp[n - 1 - i];
    return buf[0..out];
}

/// Copy a B8G8R8X8 rect from `src` (stride `src_stride` bytes) into `dst`
/// (stride `dst_stride` bytes) at (dx, dy). Pure — host-testable.
pub fn blit_rect(
    dst: [*]u8,
    dst_stride: usize,
    src: [*]const u8,
    src_stride: usize,
    dx: usize,
    dy: usize,
    w: usize,
    h: usize,
) void {
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const drow = dst + (dy + y) * dst_stride + dx * 4;
        const srow = src + y * src_stride;
        @memcpy(drow[0 .. w * 4], srow[0 .. w * 4]);
    }
}

/// Arc4 #239: alpha-blended blit. Blends `src` over `dst` with the
/// given alpha (0..256). 256 = fully opaque (same as blit_rect),
/// 64 = 25%, 128 = 50%. Per-pixel: dst = dst × (1 - a/256) + src × (a/256).
/// Pure BSS math, no allocation.
pub fn blit_rect_alpha(
    dst: [*]u8,
    dst_stride: usize,
    src: [*]const u8,
    src_stride: usize,
    dx: usize,
    dy: usize,
    w: usize,
    h: usize,
    alpha: u16,
) void {
    if (alpha >= 256) {
        blit_rect(dst, dst_stride, src, src_stride, dx, dy, w, h);
        return;
    }
    const inv_alpha: u16 = 256 - alpha;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const drow = dst + (dy + y) * dst_stride + dx * 4;
        const srow = src + y * src_stride;
        var x: usize = 0;
        while (x < w * 4) : (x += 1) {
            const d: u16 = drow[x];
            const s: u16 = srow[x];
            drow[x] = @intCast((d * inv_alpha + s * alpha) >> 8);
        }
    }
}

// ---------------------------------------------------------------------------
// Window painting
// ---------------------------------------------------------------------------

pub fn fb_canvas() fbtext.Canvas {
    return .{
        .base = @ptrCast(&virtio_gpu.gpu_fb),
        .width = virtio_gpu.fb_width,
        .height = virtio_gpu.fb_height,
        .stride = virtio_gpu.fb_width * 4,
    };
}

/// Render the clock window's content into a buffer. `focused` selects the
/// focus-status line. Pure — host-testable with an injectable buffer.
pub fn render_clock_content(buf: [*]u8, stride: usize, w: usize, h: usize, ticks: u64, focused: bool) void {
    // Background + border (2 px), then the amber title bar.
    fill_rect(buf, stride, 0, 0, w, h, clock_bg());
    fill_rect(buf, stride, 0, 0, w, 2, clock_border_rgb);
    fill_rect(buf, stride, 0, h - 2, w, 2, clock_border_rgb);
    fill_rect(buf, stride, 0, 0, 2, h, clock_border_rgb);
    fill_rect(buf, stride, w - 2, 0, 2, h, clock_border_rgb);
    fill_rect(buf, stride, 2, 2, w - 4, 16, clock_title_bg());

    draw_string(buf, stride, 8, 6, "clock", clock_title_fg_rgb);

    var nb: [24]u8 = undefined;
    // Body lines (8 px grid, origin 8 px inside the border).
    draw_string_16(buf, stride, 8, 26, "DRIVING AWARD", clock_accent_rgb);
    draw_string(buf, stride, 8, 42, "ticks=", clock_fg_rgb);
    draw_string(buf, stride, 8 + 6 * 8, 42, fmt_decimal(&nb, ticks), clock_fg_rgb);
    draw_string(buf, stride, 8, 58, if (focused) "focus=clock" else "focus=roadpops", clock_fg_rgb);
    draw_string(buf, stride, 8, 74, "windows=2", clock_fg_rgb);
}

/// #1082 (ADR 0020 Amendment A, A4): render a window-bound terminal's
/// presentation grid into its back-buffer with the kernel glyph raster. The
/// bytes were already drained into the grid (file_table's write path); this
/// turns the grid into the window's pixels, and the compositor blits it on
/// its cadence (the deferred-present discipline).
const ansi_palette = [_]u32{
    0x000000, 0xcd3131, 0x0dbc79, 0xe5e510,
    0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5,
    0x666666, 0xf14c4c, 0x23d18b, 0xf5f543,
    0x3b8eea, 0xd670d6, 0x29b8db, 0xffffff,
};

/// M73h (#1634): one palette index → RGB. 0..=15 keep the paint-local
/// `ansi_palette` (pixel parity for old sequences); 16..=255 come from
/// the canonical xterm table in terminal.zig.
fn terminalColour(index: u8) u32 {
    if (index < ansi_palette.len) return ansi_palette[index];
    return rgbToU32(terminal.xterm256Rgb(index));
}

fn rgbToU32(c: terminal.Rgb) u32 {
    return (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
}

/// M73h (#1634, dim SGR 2): reduce each channel to 2/3 intensity.
fn dimRgb(c: u32) u32 {
    const r = ((c >> 16) & 0xff) * 2 / 3;
    const g = ((c >> 8) & 0xff) * 2 / 3;
    const b = (c & 0xff) * 2 / 3;
    return (r << 16) | (g << 8) | b;
}

/// M73h (#1634, deliverable 3): what the terminal's DEFAULT colour slots
/// (256) resolve to — the desktop theme, the same `theme_id` source the
/// chrome accessors read (#207). Dark (the boot theme) is BYTE-IDENTICAL
/// to the pre-M73h hardcoded `fbtext.fg_rgb`/`fbtext.bg_rgb`, so every
/// existing pixel gate stays valid; pinned by driving_award_test.
pub fn terminalThemeDefaults() struct { fg: u32, bg: u32 } {
    return switch (theme_id) {
        1 => .{ .fg = 0x353b45, .bg = 0xf5f6f8 }, // light: slate ink on paper
        2 => .{ .fg = 0xffd27f, .bg = 0x0a1a2e }, // amber: warm text on navy
        // M73m (#1662): the user's own colours. The slot semantics are
        // unchanged (Amendment E: presentation default, resolved at paint,
        // never a stored per-cell RGB) — only what "default" resolves TO.
        3 => .{ .fg = custom_fg, .bg = custom_bg }, // custom == the store's palette
        else => .{ .fg = fbtext.fg_rgb, .bg = fbtext.bg_rgb }, // dark == legacy
    };
}

/// M73h: what one cell paints as — both channels resolved to RGB
/// (truecolour side arrays > palette/xterm > theme default), then
/// reverse swaps them (xterm semantics: the FLAG is stored, the swap
/// happens here), then dim scales the foreground. `italic`/`underline`
/// pass through for the draw path.
pub const Rendition = struct { fg: u32, bg: u32, italic: bool, underline: bool };

pub fn terminalRendition(style: terminal.CellStyle, fg_side: ?terminal.Rgb, bg_side: ?terminal.Rgb) Rendition {
    const theme = terminalThemeDefaults();
    var fg: u32 = undefined;
    if (style.fg == terminal.rgb_colour) {
        fg = rgbToU32(fg_side orelse .{});
    } else if (terminal.styleForeground(style)) |colour| {
        fg = terminalColour(colour);
        if (terminal.styleBold(style) and colour < 8) fg = terminalColour(colour + 8);
    } else if (terminal.styleBold(style) and theme_id == 0) {
        // The historical default is terminal-green rather than ANSI
        // colour 7. Give `SGR 1` on that default a visible bright-green
        // rendition too (dark theme ONLY — byte parity with the pre-M73h
        // gates; light/amber/custom keep their theme foreground, so a
        // custom palette is never overridden by the legacy green).
        fg = ansi_palette[10];
    } else {
        fg = theme.fg;
    }
    var bg: u32 = if (style.bg == terminal.rgb_colour)
        rgbToU32(bg_side orelse .{})
    else if (terminal.styleBackground(style)) |colour|
        terminalColour(colour)
    else
        theme.bg;
    if (terminal.styleReverse(style)) {
        const tmp = fg;
        fg = bg;
        bg = tmp;
    }
    if (terminal.styleDim(style)) fg = dimRgb(fg);
    return .{ .fg = fg, .bg = bg, .italic = style.italic, .underline = style.underline };
}

/// M85b (#1814): one image cell — its tile's SET pixels over the cell
/// (unset sixel pixels are transparent), scaled nearest-neighbour from
/// the geometry the image was placed at to the active cell, so a font
/// zoom keeps the image covering exactly its cells.
fn paint_image_tile(dst: [*]u8, stride: usize, x0: usize, y0: usize, tile: terminal.term_image.Tile) void {
    const cw: usize = font_metrics.cell_w;
    const ch: usize = font_metrics.cell_h;
    var dy: usize = 0;
    while (dy < ch) : (dy += 1) {
        var dx: usize = 0;
        while (dx < cw) : (dx += 1) {
            if (tile.sample(dx, dy, cw, ch)) |rgb| put_px(dst, stride, x0 + dx, y0 + dy, rgb);
        }
    }
}

pub fn render_terminal_screen(dst: [*]u8, w: *const Window, scr: *const terminal.Screen) void {
    const wu: usize = @intCast(w.w);
    const hu: usize = @intCast(w.h);
    const stride = wu * 4;
    fill_rect(dst, stride, 0, 0, wu, hu, fbtext.bg_rgb);
    const cols = @min(scr.columns(), wu / font_metrics.cell_w);
    // The compositor draws the title bar over the top `title_bar_h` rows, so
    // the grid's first line starts below it (client-area origin).
    const y0: usize = @intCast(geom.title_bar_h);
    const rows = if (hu > y0) (hu - y0) / font_metrics.cell_h else 0;
    if (cols == 0 or rows == 0) return;
    const total = scr.lineCount();
    // M49 SD5 (#1132): the scrollback view shifts the first visible line
    // back by `view` lines (0 = follow the tail).
    const view = scr.viewOffset();
    const bottom = if (total > view) total - view else 0;
    const first = if (bottom > rows) bottom - rows else 0;
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        const ri = first + r;
        // M73a-2 (#1631): `line()` is the length gate (lens, in cells) and
        // the byte source for the ASCII fast path; the real content comes
        // from `cellAt` — runes, overlays, and wide pairs included.
        const line = scr.line(ri);
        const ry = y0 + r * font_metrics.cell_h;
        var c: usize = 0;
        while (c < cols) : (c += 1) {
            const cell = scr.cellAt(ri, c);
            const side = scr.rgbAt(ri, c);
            const colours = terminalRendition(scr.styleAt(ri, c), side.fg, side.bg);
            const x = c * font_metrics.cell_w;
            const wide = fbtext.char_width(cell.base) >= 2 and c + 1 < cols;
            // M49 SD5: selected cells invert (fg on bg).
            if (scr.inSelection(ri, c)) {
                fill_rect(dst, stride, x, ry, font_metrics.cell_w, font_metrics.cell_h, colours.fg);
                if (c < line.len) draw_cell_glyph(dst, stride, x, ry, cell, colours.bg, wide, colours.italic);
            } else if (cell.cont != 0) {
                // The wide base already filled this cell's half of the pair
                // and stroked its glyph across both cells; a continuation
                // paints nothing of its own.
            } else if (colours.bg != fbtext.bg_rgb or c < line.len) {
                // A wide base fills (and strokes) its whole pair in one pass.
                const span: usize = if (wide) font_metrics.wide_cell_w else font_metrics.cell_w;
                fill_rect(dst, stride, x, ry, span, font_metrics.cell_h, colours.bg);
                if (c < line.len) draw_cell_glyph(dst, stride, x, ry, cell, colours.fg, wide, colours.italic);
            }
            // M85b (#1814): an image cell composites its tile over the
            // fill it just got (image cells carry the erase default, so
            // that is the theme background — or the selection's ink).
            if (cell.img != 0) {
                if (scr.imageTile(ri, c)) |tile| paint_image_tile(dst, stride, x, ry, tile);
            }
            // M73h: underline strokes the cell's bottom row (the base owns
            // its whole pair — a continuation skips so the line draws
            // once, wide or not).
            if (colours.underline and cell.cont == 0) {
                const u_span: usize = if (wide) font_metrics.wide_cell_w else font_metrics.cell_w;
                fill_rect(dst, stride, x, ry + font_metrics.underline_row, u_span, 1, colours.fg);
            }
        }
    }
    // The block cursor: invert the cell the shell's line editor is at —
    // only while following the tail (a scrolled-back view has no cursor).
    // M73k (#1637): unified index — with history, the grid-relative
    // cursorLine would sit `hist_count` rows above its painted position.
    const cl = scr.cursorLineUnified();
    if (scr.cursor_visible and view == 0 and cl >= first and cl - first < rows) {
        const cc = scr.cursorCol();
        if (cc < cols) {
            const cy = y0 + (cl - first) * font_metrics.cell_h;
            const c_side = scr.rgbAt(cl, cc);
            const colours = terminalRendition(scr.styleAt(cl, cc), c_side.fg, c_side.bg);
            fill_rect(dst, stride, cc * font_metrics.cell_w, cy, font_metrics.cell_w, font_metrics.cell_h, colours.fg);
            const line = scr.line(cl);
            const cell = scr.cellAt(cl, cc);
            const wide = fbtext.char_width(cell.base) >= 2 and cc + 1 < cols;
            // M80i (#1725): was `cc * 8` — the one geometry literal
            // M73l missed. At the zoom sizes the cursor glyph landed a
            // row-width away from its cell fill.
            if (cc < line.len) draw_cell_glyph(dst, stride, cc * font_metrics.cell_w, cy, cell, colours.bg, wide, colours.italic);
        }
    }
}

/// Paint one window into the framebuffer. The terminal renders the shared
/// text layer straight into the scanout framebuffer; the clock renders its
/// back-buffer and blits it over the terminal.
pub fn paint(w: *Window) void {
    switch (w.kind) {
        .terminal => fbtext.render(fb_canvas()),
        .clock => {
            render_clock_content(
                @ptrCast(&clock_buf),
                clock_w * 4,
                clock_w,
                clock_h,
                if (clock_has_tick) clock_shown_tick else 0,
                focused_id == w.id,
            );
            blit_rect(
                @ptrCast(&virtio_gpu.gpu_fb),
                virtio_gpu.fb_width * 4,
                @ptrCast(&clock_buf),
                clock_w * 4,
                w.x,
                w.y,
                w.w,
                w.h,
            );
        },
        .user => {
            // M33 SB3 (claim 9361): a SURFACE-BACKED window's rendering lives
            // in its shared-anonymous pages (mapped into the owner's root and
            // mirrored RO into the registered WM), NOT the kernel pool
            // buffer. The kernel root identity-maps the low physical space, so
            // composite() blits directly from the surface's OWN pages — the
            // on-scanout bytes are the app's plain stores, byte-identical to
            // what the old fill path produced (parity). An unmigrated window
            // blits from its pool back-buffer (WM1), sized exactly win.w×h.
            const surface = user_surface(w.id);
            // #2111: blit from the surface only while the rect still fits
            // inside its pages; a desync falls back to the pool back-buffer
            // (always exactly w×h) rather than reading past the region.
            const src_ptr: [*]const u8 = if (surface) |sf|
                if (surface_covers(sf.page_count, w.w, w.h))
                    @as([*]const u8, @ptrFromInt(sf.pa_base))
                else
                    kbuf_ptr(w)
            else
                kbuf_ptr(w);
            // #1082 (A4): a WINDOW-bound terminal repaints its whole grid
            // into the back-buffer from the kernel's presentation state; the
            // blit below then shows it. The full-grid render means the whole
            // window is repainted, so the partial-damage path is skipped.
            // M49 SD5 (#1132): sync the grid to the window's width first so
            // a resize reflows before this frame paints.
            terminal.syncWindowCols(w.id, w.w);
            const term_screen = terminal.screenOf(w.id);
            if (term_screen) |scr| {
                render_terminal_screen(@constCast(src_ptr), w, scr);
            }
            const src_stride: usize = @as(usize, w.w) * 4;
            // The source is the window's own back-buffer (surface and pool
            // buffer are both sized exactly win.w × win.h); clamp SOURCE
            // dims for the legacy rect overflow (M21 tiling) defensively.
            const bw = w.w;
            const bh = w.h;
            // M33 SB4 (claim 2382): rect-granular repaint — when this window
            // carries a partial damage rect, blit ONLY that region (from its
            // back-buffer origin to the scanout origin), not the whole window.
            // Whole-window ops (move/focus/fade) leave `damaged` false -> full
            // blit, so the pre-SB4 path is unchanged.
            var src_off: usize = 0;
            var dest_x: u32 = w.x;
            var dest_y: u32 = w.y;
            var sw = bw;
            var sh = bh;
            if (w.damaged and term_screen == null) {
                const sx = @min(w.dx, bw);
                const sy = @min(w.dy, bh);
                sw = @min(w.dw, bw - @min(w.dx, bw));
                sh = @min(w.dh, bh - @min(w.dy, bh));
                dest_x = w.x + sx;
                dest_y = w.y + sy;
                src_off = @as(usize, sy) * src_stride + @as(usize, sx) * 4;
            }
            const src_ptr2: [*]const u8 = src_ptr + src_off;
            // Arc4 #239: during fade-in, blend with alpha over the
            // background (wallpaper/terminal already composited below).
            // WM4 (issue #707 card 4): at REST — fade complete — an
            // UNFOCUSED window with a rest-alpha policy blends its CLIENT
            // area at that alpha (the chrome is drawn opaque afterwards,
            // so the WMS4 chrome pixel parity is untouched). No policy /
            // no WM / focused = 256, byte-identical to v1.
            const alpha: u16 = client_alpha(w);
            if (alpha < 256) {
                blit_rect_alpha(
                    @ptrCast(&virtio_gpu.gpu_fb),
                    virtio_gpu.fb_width * 4,
                    src_ptr2,
                    src_stride,
                    dest_x,
                    dest_y,
                    sw,
                    sh,
                    alpha,
                );
            } else {
                blit_rect(
                    @ptrCast(&virtio_gpu.gpu_fb),
                    virtio_gpu.fb_width * 4,
                    src_ptr2,
                    src_stride,
                    dest_x,
                    dest_y,
                    sw,
                    sh,
                );
            }
        },
        .wallpaper => {
            // Step 9: vertical gradient from wallpaper_top() to wallpaper_bot().
            const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
            const stride = virtio_gpu.fb_width * 4;
            var y: u32 = 0;
            while (y < virtio_gpu.fb_height) : (y += 1) {
                const t = y * 256 / virtio_gpu.fb_height;
                const r = ((wallpaper_top() >> 16) & 0xff) * (256 - t) / 256 + ((wallpaper_bot() >> 16) & 0xff) * t / 256;
                const g = ((wallpaper_top() >> 8) & 0xff) * (256 - t) / 256 + ((wallpaper_bot() >> 8) & 0xff) * t / 256;
                const b = (wallpaper_top() & 0xff) * (256 - t) / 256 + (wallpaper_bot() & 0xff) * t / 256;
                const row_color: u32 = (@as(u32, @intCast(r)) << 16) | (@as(u32, @intCast(g)) << 8) | @as(u32, @intCast(b));
                fill_rect(fb, stride, 0, y, virtio_gpu.fb_width, 1, row_color);
            }
        },
        .taskbar => {
            // Step 8: dark background bar spanning full width.
            const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
            const stride = virtio_gpu.fb_width * 4;
            fill_rect(fb, stride, 0, taskbar_y, virtio_gpu.fb_width, taskbar_h, taskbar_bg());
            // Arc4 #241: workspace switcher [1][2][3] on the left side.
            // WM3: the cell geometry is the shared wnd_core rule.
            var ws_idx: u8 = 0;
            while (ws_idx < workspace_max) : (ws_idx += 1) {
                const ws_x = geom.taskbar_ws_x0 + @as(u32, ws_idx) * geom.taskbar_ws_stride;
                const is_cur = ws_idx == current_workspace;
                const ws_bg = if (is_cur) taskbar_entry_active() else taskbar_entry_dimmed();
                fill_rect(fb, stride, ws_x, taskbar_y + 2, geom.taskbar_ws_cell, taskbar_h - 4, ws_bg);
                const label: [1]u8 = .{'1' + ws_idx};
                draw_string(fb, stride, ws_x + 6, taskbar_y + 6, label[0..1], 0xffffff);
            }
            // WM3 (issue #707 card 3): entries for the CURRENT workspace
            // only, enumerated ID-ASCENDING by the shared wnd_core rule —
            // the same enumeration the registered WM hit-tests with (the
            // drift guard: kernel render and WM hit-test cannot disagree).
            // The focused entry carries the active fill + the 2px
            // underline indicator; a minimized entry carries the darker
            // fill + restore dot (the taskbar is the restore target).
            var tb: [user_windows_max]TaskbarEntry = undefined;
            const tn = taskbar_entries(&tb);
            var ei: u32 = 0;
            while (ei < tn) : (ei += 1) {
                const r = geom.taskbar_entry_rect(ei, workspace_max, virtio_gpu.fb_width, virtio_gpu.fb_height, tray_w) orelse break;
                const is_focused = tb[ei].focused;
                const is_min = tb[ei].minimized;
                const ww = find_user_window(tb[ei].id).?;
                const entry_bg = if (is_focused) taskbar_entry_active() else if (is_min) taskbar_entry_minimized() else taskbar_entry_dimmed();
                fill_rect(fb, stride, r.x, r.y, r.w, r.h, entry_bg);
                const entry_title = geom.taskbar_title_slice(ww.title);
                const title_ink: u32 = if (is_min) taskbar_min_title_rgb else 0xffffff;
                draw_string(fb, stride, r.x + geom.taskbar_entry_pad, taskbar_y + 6, entry_title, title_ink);
                if (is_focused) {
                    // Active indicator: a 2px underline across the entry.
                    fill_rect(fb, stride, r.x + geom.taskbar_indicator_inset, r.y + r.h - geom.taskbar_indicator_h, r.w - 2 * geom.taskbar_indicator_inset, geom.taskbar_indicator_h, taskbar_indicator_rgb);
                } else if (is_min) {
                    // Restore affordance: a 4x4 dot in the entry's tail.
                    fill_rect(fb, stride, r.x + r.w - 9, r.y + 5, 4, 4, taskbar_min_dot_rgb);
                }
            }
            // Arc2 W3: tray in right 80px — HH:MM, D/L/A, clipboard rect.
            // HH:MM from tray_tick (tick-derived, 1 Hz). M32 WMS6 Gate E:
            // when the registered WM has declared a field (its `_set` flag),
            // draw ITS value; the shim fallback (no WM) stays derived.
            var tbuf: [5]u8 = undefined;
            const hhmm: []const u8 = if (wm_tray_clock_set)
                wm_tray_clock_text[0..]
            else
                format_hhmm(&tbuf, if (tray_has_tick) tray_tick else 0);
            draw_string(fb, stride, tray_x + 4, tray_y + 6, hhmm, 0xffffff);
            // Theme letter in accent
            var tletter: [1]u8 = .{if (wm_tray_theme_set) wm_tray_theme else theme_letter()};
            draw_string(fb, stride, tray_x + 48, tray_y + 6, tletter[0..1], tray_theme_accent());
            // Clipboard indicator: filled when has content, outline when empty.
            const clip_x = tray_x + 64;
            const clip_y = tray_y + 6;
            const clip_w: usize = 10;
            const clip_h: usize = 8;
            if (if (wm_tray_clip_set) wm_tray_clip else tray_clipboard_filled()) {
                fill_rect(fb, stride, clip_x, clip_y, clip_w, clip_h, 0xffffff);
            } else {
                fill_rect(fb, stride, clip_x, clip_y, clip_w, 1, 0xffffff);
                fill_rect(fb, stride, clip_x, clip_y + clip_h - 1, clip_w, 1, 0xffffff);
                fill_rect(fb, stride, clip_x, clip_y, 1, clip_h, 0xffffff);
                fill_rect(fb, stride, clip_x + clip_w - 1, clip_y, 1, clip_h, 0xffffff);
            }
        },
        .dock => {
            // M15 C4: 24 px left dock, vertical icon bar (hardcoded dock apps).
            const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
            const stride = virtio_gpu.fb_width * 4;
            fill_rect(fb, stride, w.x, w.y, w.w, w.h, dock_bg_rgb);
            // Icons for dock=true apps (first 5 from image/apps.txt).
            const dock_icons = [_]u8{ 'c', 'n', 't', 'b', 's' };
            // M21 W3: count minimized windows to show restore indicators.
            var minimized_count: usize = 0;
            {
                var mi: usize = 0;
                while (mi < win_count) : (mi += 1) {
                    if (windows[mi].kind == .user and windows[mi].minimized) minimized_count += 1;
                }
            }
            var idx: usize = 0;
            while (idx < dock_icons.len) : (idx += 1) {
                const iy = w.y + 8 + @as(u32, @intCast(idx)) * 32;
                if (iy + 24 > w.y + w.h) break;
                // M21 W3: highlight first icon if there are minimized windows.
                const bg = if (idx == 0 and minimized_count > 0)
                    0xf59e0b // amber — indicates minimized windows to restore
                else if (idx == 0 and focused_id == 2)
                    dock_icon_active_rgb
                else
                    dock_icon_bg_rgb;
                fill_rect(fb, stride, w.x + 2, iy, 20, 20, bg);
                draw_glyph(fb, stride, w.x + 8, iy + 6, dock_icons[idx], 0xffffff);
                // M21 W3: small dot indicator below the icon for each minimized window.
                if (idx == 0 and minimized_count > 0) {
                    fill_rect(fb, stride, w.x + 8, iy + 22, 2, 2, 0xf59e0b);
                }
            }
        },
    }
}

/// The repaint plan: the index of the LOWEST dirty visible window, or null
/// when the scene is clean. Pure — host-testable.
pub fn repaint_start() ?usize {
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].visible and windows[i].dirty) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// The compositor
// ---------------------------------------------------------------------------

/// Composite: repaint every visible window from the lowest dirty one UP (so
/// the clock is always re-blitted over a freshly repainted terminal), then
/// push one transfer + flush. Returns the flush result; `.ok` with no work
/// when the scene is clean (dirty-rect: unchanged windows are never
/// repainted).
/// M33 SB5 (claim 7397): the kernel's compositor LAYER — paint chrome +
/// unmigrated windows into the scanout framebuffer WITHOUT a transfer/flush.
/// While a WM is registered, wm_server.on_tick calls this BEFORE pushing the
/// COMPOSITE_TICK, so the kernel layer is UNDER the WM's compose-N stores
/// (correct z-order at flush time). Surface-backed (migrated) user windows
/// are skipped when `wm_owns_user_layer` — the WM owns those pixels. Pure
/// BSS writes: only gpu_transfer's `dc ivac` cache-clean is EL0-illegal, so
/// this half is host-test safe (the established `!builtin.is_test` gate stays
/// on the flush half).
pub fn paint_scene() virtio_gpu.CmdResult {
    if (!armed_global) return .not_ready;
    cursor_restore();
    // Arc2 W3: tray clock ticks on composite() without timer — detect theme/
    // clipboard changes that happened since last composite and mark taskbar
    // dirty so the tray repaints even without a tick. Tick-driven dirty is
    // handled in drain(); this covers settings/clipboard writes that occur
    // between ticks.
    {
        const cur_theme = theme_id;
        const cur_clip = clipboard.current_len();
        var need = false;
        if (cur_theme != tray_last_theme) {
            tray_last_theme = cur_theme;
            need = true;
        }
        if (cur_clip != tray_last_clip_len) {
            tray_last_clip_len = cur_clip;
            need = true;
        }
        if (need) _ = mark_dirty(255);
    }
    // M33 SB5: whether this scene painted anything (drives composite()'s
    // decision to flush — a clean scene is not flushed, pre-SB5 behavior).
    scene_dirty = false;
    const start = repaint_start() orelse return .ok;
    scene_dirty = true;
    // M71c (#1562): while a registered seat owns the scanout, the kernel
    // composites NONE of its own fixed desktop layer — the full-screen
    // Road Pops terminal window, the wallpaper gradient, the taskbar and
    // the dock. The seat writes its own desktop + chrome straight into the
    // same framebuffer (wm_server.scanout_bind maps gpu_fb_phys), so a
    // kernel blit here would double-draw over it. The tee calls this on
    // every dirty console batch (the monitor's `tasks worker advances=`
    // line keeps it permanently dirty), which is why the kernel terminal
    // used to land ON TOP of the seat: measured 2026-09-21 (#1562), the
    // captured frame held the kernel's console-green text and none of the
    // seat's pixels. In WM mode this layer is painted at COMPOSITE_TICK;
    // only the seat's REQUEST_PRESENT publishes the completed frame.
    const seat_owns_layer = wm_owns_user_layer;
    // Step 9: render the wallpaper gradient BEFORE windows so it is the background.
    if (start <= 1 and !seat_owns_layer) {
        // The wallpaper is at index 1 (after tray migration); if it or anything below is dirty, render gradient.
        const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
        const stride = virtio_gpu.fb_width * 4;
        var y: u32 = 0;
        while (y < virtio_gpu.fb_height) : (y += 1) {
            const t = y * 256 / virtio_gpu.fb_height;
            const r = ((wallpaper_top() >> 16) & 0xff) * (256 - t) / 256 + ((wallpaper_bot() >> 16) & 0xff) * t / 256;
            const g = ((wallpaper_top() >> 8) & 0xff) * (256 - t) / 256 + ((wallpaper_bot() >> 8) & 0xff) * t / 256;
            const b = (wallpaper_top() & 0xff) * (256 - t) / 256 + (wallpaper_bot() & 0xff) * t / 256;
            const row_color: u32 = (@as(u32, @intCast(r)) << 16) | (@as(u32, @intCast(g)) << 8) | @as(u32, @intCast(b));
            fill_rect(fb, stride, 0, y, virtio_gpu.fb_width, 1, row_color);
        }
    }
    var i = start;
    while (i < win_count) : (i += 1) {
        const w = &windows[i];
        if (!w.visible) continue;
        // Arc4 #241: skip user windows not in the current workspace.
        if (!workspace_visible(w)) {
            w.dirty = false;
            continue;
        }
        // Wallpaper is rendered via the gradient path above.
        if (w.kind == .wallpaper) {
            w.dirty = false;
            continue;
        }
        // M71c (#1562): the kernel's own fixed desktop layer (its full-screen
        // terminal window, wallpaper, taskbar, dock) is the seat's job while
        // a registered seat owns the scanout — skip the blit, consume the
        // damage. User windows are NOT skipped here: the migrated ones are
        // already gated by `wm_owns_user_layer` above, and an unmigrated
        // kernel-rendered user window (a hosted tty band) still paints.
        if (seat_owns_layer and (w.kind == .terminal or w.kind == .taskbar or w.kind == .dock)) {
            w.dirty = false;
            w.damaged = false;
            continue;
        }
        // M33 SB5 (claim 7397): while the registered WM owns the user layer
        // (scanout bound), surface-backed (migrated) user windows are the
        // WM's compositing job — their bytes are already in the scanout via
        // the WM's compose-N stores (written after this tick's chrome paint,
        // before the final present). Skip the kernel blit entirely; the
        // damage is consumed (the WM composites from the same tick mask).
        if (w.kind == .user and wm_owns_user_layer and user_surface(w.id) != null) {
            // M104f: only the SCANOUT BLIT is the seat's job — a window with
            // a kernel-rendered front-end (attached tty) still needs its grid
            // painted into the surface pages, or the seat's compose-N reads
            // zeros. Apps that paint their own surface have no terminal
            // screen and take the pure skip.
            render_frontend_to_surface(w);
            w.dirty = false;
            w.damaged = false;
            // M33 SB6 (claim 6864): the seam-B composite-cost saving — the
            // kernel did NOT blit this migrated window (the WM's compose-N
            // stores are the pixels).
            migrated_skips +%= 1;
            continue;
        }
        if (w.kind == .user) {
            // M33 SB6 (claim 6864): the pre-seam-B composite cost — a user
            // window the kernel actually blitted this scene.
            user_blits +%= 1;
        }
        paint(w);
        // M33 SB4 (claim 2382): record the rect paint() actually repainted so
        // the gate can observe it after the drain (unless whole-window, in
        // which case damaged was false and we leave the prior last_*).
        if (w.damaged) {
            w.last_dx = w.dx;
            w.last_dy = w.dy;
            w.last_dw = w.dw;
            w.last_dh = w.dh;
        }
        w.dirty = false;
        w.damaged = false; // the tracked damage rect was consumed by paint
    }
    // Arc4 #239: advance fade-in ticks after painting. Each composite
    // frame increments the tick; after 2 × fade_half_frames the fade
    // completes and the window renders at full opacity.
    {
        var fi: usize = 0;
        while (fi < win_count) : (fi += 1) {
            const fw = &windows[fi];
            if (fw.fade_phase == 1) {
                fw.fade_tick +|= 1;
                if (fw.fade_tick >= fade_half_frames * 2) {
                    fw.fade_phase = 0; // fade complete
                    fw.fade_tick = 0;
                }
                fw.dirty = true; // repaint at new alpha
            }
        }
    }
    // Arc4 #240: advance notification dismiss ticks once per composite.
    notify_advance_ticks();
    // M21 W16: advance transient window timeouts.
    _ = transient_advance_tick();
    draw_chrome();
    if (!wm_owns_user_layer) cursor_draw();
    return .ok;
}

/// Whether the last paint_scene() actually repainted anything (drives the
/// clean-scene no-flush decision in composite()). Read by composite() only.
pub var scene_dirty: bool = false;

/// Opt-in, guest-only presentation evidence. The exact fixture consent is
/// required; ordinary boots neither record scanouts nor perform capture IO.
pub var presentation_trace: bool = false;
var trace_seq: u32 = 0;
var trace_busy: bool = false;
const trace_file = @import("virtio_file.zig");

pub fn presentation_trace_arm() void {
    if (builtin.is_test) return;
    presentation_trace = false;
    var consent: [4]u8 = undefined;
    const n = trace_file.read_whole("M91-PRESENTATION.TRACE", &consent) orelse return;
    presentation_trace = std.mem.eql(u8, consent[0..n], "v1\n");
    if (presentation_trace) klog.line("m91: trace armed guest-only\n");
}

fn trace_write(handle: u16, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        var written: u64 = 0;
        const n = @min(bytes.len - off, trace_file.write_chunk_limit());
        if (trace_file.write(handle, bytes[off..][0..n], &written) != trace_file.st_ok or
            written == 0 or written > n) return false;
        off += @intCast(written);
    }
    return true;
}

/// Lossless runs of (u32 count, u32 BGRX), prefixed with M91F/width/height/seq.
/// Each file is the framebuffer at a transfer boundary, not a delayed sample
/// requested by the host. Capture errors are reported, never treated as frames.
pub fn presentation_begin(owner: []const u8) u32 {
    if (!presentation_trace or builtin.is_test) return 0;
    if (trace_busy) {
        klog.line("m91: trace ERROR reentrant\n");
        return 0;
    }
    trace_busy = true;
    defer trace_busy = false;
    trace_seq +%= 1;
    var name_buf: [48]u8 = undefined;
    const path = std.fmt.bufPrint(&name_buf, "M91-FRAME-{d}.rle", .{trace_seq}) catch unreachable;
    var handle: u16 = 0;
    var captured = trace_file.open(path, trace_file.open_flag_create, &handle) == trace_file.st_ok;
    if (captured) {
        defer _ = trace_file.close(handle);
        captured = trace_file.truncate(handle, 0) == trace_file.st_ok;
        const buf = &trace_file.chunk_staging;
        @memcpy(buf[0..4], "M91F");
        std.mem.writeInt(u32, buf[4..8], virtio_gpu.fb_width, .little);
        std.mem.writeInt(u32, buf[8..12], virtio_gpu.fb_height, .little);
        std.mem.writeInt(u32, buf[12..16], trace_seq, .little);
        var used: usize = 16;
        var at: usize = 0;
        const pixels = virtio_gpu.fb_size / 4;
        while (captured and at < pixels) {
            const color = std.mem.readInt(u32, virtio_gpu.gpu_fb[at * 4 ..][0..4], .little);
            var end = at + 1;
            while (end < pixels and std.mem.readInt(u32, virtio_gpu.gpu_fb[end * 4 ..][0..4], .little) == color) : (end += 1) {}
            std.mem.writeInt(u32, buf[used..][0..4], @intCast(end - at), .little);
            std.mem.writeInt(u32, buf[used + 4 ..][0..4], color, .little);
            used += 8;
            if (used + 8 > buf.len) {
                captured = trace_write(handle, buf[0..used]);
                used = 0;
            }
            at = end;
        }
        if (captured) captured = trace_write(handle, buf[0..used]);
    }
    var line_buf: [192]u8 = undefined;
    const t = @import("timer.zig");
    const ns: u64 = if (t.freq == 0) 0 else @intCast(@as(u128, t.cntpct()) * 1_000_000_000 / t.freq);
    const line = std.fmt.bufPrint(&line_buf, "m91: frame={d} owner={s} seat={d} phase=transfer captured={d} ns={d} cursor={d},{d},{d}\n", .{
        trace_seq, owner,    @intFromBool(wm_owns_user_layer), @intFromBool(captured), ns,
        cursor_x,  cursor_y, @intFromBool(cursor_shown),
    }) catch unreachable;
    klog.line(line);
    return trace_seq;
}

pub fn presentation_end(seq: u32, result: virtio_gpu.CmdResult) void {
    if (seq == 0) return;
    var buf: [96]u8 = undefined;
    klog.line(std.fmt.bufPrint(&buf, "m91: frame={d} phase=complete result={s}\n", .{ seq, @tagName(result) }) catch unreachable);
}

/// One transport seam for completed shim/seat frames, with injectable hardware
/// results in host tests. Success means BOTH transfer and flush completed.
pub var transfer_hook: ?*const fn () virtio_gpu.CmdResult = null;
pub var flush_hook: ?*const fn () virtio_gpu.CmdResult = null;
pub fn present_completed(owner: []const u8) virtio_gpu.CmdResult {
    const seq = presentation_begin(owner);
    const transfer = if (builtin.is_test)
        (if (transfer_hook) |h| h() else virtio_gpu.CmdResult.ok)
    else
        virtio_gpu.gpu_transfer();
    const result = if (transfer != .ok)
        transfer
    else if (builtin.is_test)
        (if (flush_hook) |h| h() else virtio_gpu.CmdResult.ok)
    else
        virtio_gpu.gpu_flush();
    presentation_end(seq, result);
    return result;
}

/// The shim composite: paint the scene, then transfer+flush the scanout
/// (the G1 seam). When the scene is clean, nothing is flushed (pre-SB5
/// behavior). The transfer/flush half runs `dc ivac` cache-maintenance asm
/// — EL0-illegal in host test binaries — so the flush half keeps the
/// established `!builtin.is_test` gating at ITS call sites (the WM path
/// flushes via wm_server.request_present, which already gates).
pub fn composite() virtio_gpu.CmdResult {
    // M76a (#1674): while the splash hold stands, refuse the kernel
    // present — no paint, no transfer, no flush, so the splash frame
    // stays on the scanout while boot continues underneath. A seat that
    // binds the scanout paints through its OWN present path (never
    // suppressed); the first kernel present after the bind releases the
    // hold. Once bound, only the seat may publish a completed frame.
    if (splash_hold) {
        if (!wm_owns_user_layer) return .ok;
        splash_hold = false;
    }
    // A console batch or pointer move must not repaint/flush between the
    // kernel's tick-side layer and the seat's chrome stores. Otherwise the
    // intermediate kernel frame flashes over the desktop.
    if (wm_owns_user_layer) return .ok;
    if (paint_scene() != .ok) return .not_ready;
    if (!scene_dirty) return .ok; // clean scene: no flush
    if (!virtio_gpu.gpu_ready) return .not_ready;
    const result = present_completed("shim");
    if (result == .ok) {
        presents += 1;
        cursor_damage_clear();
    }
    return result;
}

// ---------------------------------------------------------------------------
// M32 WMS4 (issue #624): the SET_WINDOW chrome-descriptor seam. The WM
// server (userland) is the chrome-policy owner; the kernel stores the
// descriptors it submits and blits whatever they dictate. No WM chrome is
// present in the default VM — the shim's own rules (the "default
// descriptor" below) render byte-identically, so every pre-WMS4 gate is
// untouched.
// ---------------------------------------------------------------------------

/// Store a chrome descriptor for `id`, or the broadcast policy when `id`
/// is `geom.chrome_window_all`. Returns false for an unknown per-window
/// id or invalid descriptor (including a zero-kind broadcast). The syscall
/// validates the wire before this store applies the same pure rule.
/// Drop every WM chrome decision (the broadcast policy + per-window
/// overrides). Called on WM teardown (unregister) so the shim fallback
/// restores its own chrome rules — a dead WM must not leave its look
/// painted on the desktop.
pub fn clear_wm_chrome() void {
    wm_chrome_policy = null;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        windows[i].chrome_valid = false;
    }
    // M32 WMS6 Gate E (issue #626): the WM's tray widget content dies with
    // it — the shim fallback re-derives clock/theme/clipboard from its own
    // state (a dead WM's declared values must not stay painted).
    wm_tray_clock_set = false;
    wm_tray_theme_set = false;
    wm_tray_clip_set = false;
}

pub fn set_window_chrome(id_in: u64, desc: geom.ChromeDesc) bool {
    if (!geom.chrome_valid_for_window(id_in, desc)) return false;
    if (id_in == geom.chrome_window_all) {
        // WM4 (issue #707 card 4): a policy change can flip the effective
        // rest alpha of windows already painted under the old policy —
        // snapshot the old effective alphas, swap the policy, and mark
        // every user window whose alpha changed dirty so the next
        // composite re-blits its client (chrome repaints anyway).
        var before: [max_windows]u32 = undefined;
        var i: usize = 0;
        while (i < win_count) : (i += 1) before[i] = wm_rest_alpha(windows[i].id);
        wm_chrome_policy = desc;
        i = 0;
        while (i < win_count) : (i += 1) {
            if (windows[i].kind != .user) continue;
            if (before[i] != wm_rest_alpha(windows[i].id)) windows[i].dirty = true;
        }
        return true;
    }
    if (id_in > 0xff) return false;
    const id: u8 = @intCast(id_in);
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id != id) continue;
        windows[i].chrome = desc;
        windows[i].chrome_valid = true;
        return true;
    }
    return false;
}

/// The broadcast policy's chrome kind (0 when no WM chrome is set) — the
/// `wm` observability row.
pub fn wm_chrome_policy_kind() u32 {
    return if (wm_chrome_policy) |p| p.kind else 0;
}

/// The last chrome kind stored for window `id` (its override, else the
/// policy, else 0 = shim rules / unknown window) — the "last chrome kind
/// per window" observability.
pub fn wm_chrome_kind(id: u8) u32 {
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id != id) continue;
        if (windows[i].chrome_valid) return windows[i].chrome.kind;
        return if (wm_chrome_policy) |p| p.kind else 0;
    }
    return 0; // no such window
}

/// One observability row for the `wm` report: a user window's id, its
/// effective last chrome kind, and its effective WM4 rest alpha.
pub const ChromeRow = struct { id: u8, kind: u32, rest_alpha: u32 };

// ---------------------------------------------------------------------------
// M37 DQ2 (issue #840) — tab-group facts for the strip paint. The WM
// decides grouping via validated ATTACH_TAB/DETACH_TAB; the kernel mirrors
// the facts here (parent id per window) so draw_chrome can paint the
// strip. Unknown ids are no-ops (the syscall layer validated already).
// ---------------------------------------------------------------------------

/// Record a validated attach (child → parent). Pure registry write.
pub fn note_tab_attach(child_id: u8, parent_id: u8) void {
    if (find_user_window(child_id)) |cm| cm.tab_parent = parent_id;
}

/// Record a validated detach (child → standalone). Pure registry write.
pub fn note_tab_detach(child_id: u8) void {
    if (find_user_window(child_id)) |cm| cm.tab_parent = 0;
}

/// The recorded parent of a window (0 = standalone / unknown). Pure.
pub fn tab_parent_of(id: u8) u8 {
    if (find_user_window(id)) |w| return w.tab_parent;
    return 0;
}

/// Count windows attached to `parent_id`. Pure over the registry.
pub fn tab_group_count(parent_id: u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].kind != .user) continue;
        if (windows[i].tab_parent == parent_id) n += 1;
    }
    return n;
}

/// Fill `out` with the ids attached to `parent_id`, in registry order.
/// Returns the count written. Pure over the registry.
pub fn tab_group_members(parent_id: u8, out: []u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < win_count and n < out.len) : (i += 1) {
        if (windows[i].kind != .user) continue;
        if (windows[i].tab_parent != parent_id) continue;
        out[n] = windows[i].id;
        n += 1;
    }
    return n;
}

/// Fill `rows` with one ChromeRow per user window in registry order.
/// Returns the count written. Pure over the registry.
pub fn wm_chrome_rows(rows: *[max_windows]ChromeRow) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        const w = &windows[i];
        if (w.kind != .user) continue;
        if (n >= rows.len) break;
        rows[n] = .{ .id = w.id, .kind = wm_chrome_kind(w.id), .rest_alpha = wm_rest_alpha(w.id) };
        n += 1;
    }
    return n;
}

/// WM4 (issue #707 card 4): the effective REST alpha for window `id` —
/// its chrome override's rest_alpha, else the broadcast policy's, else
/// 256 (opaque; no WM / no policy = byte-identical v1 behavior).
/// Normalized through wnd_core (0 = none → 256). Pure over the registry.
pub fn wm_rest_alpha(id: u8) u32 {
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id != id) continue;
        if (windows[i].chrome_valid) return geom.chrome_rest_alpha_normalized(windows[i].chrome);
        if (wm_chrome_policy) |p| return geom.chrome_rest_alpha_normalized(p);
        return 256;
    }
    return 256; // no such window
}

// ---------------------------------------------------------------------------
// M37 DQ2 (issue #840) — tab-strip paint. Called from draw_chrome for a
// container window with attached tabs when its chrome enables
// chrome_tab_bar. Trough + cells from the shared tab_item_rect geometry
// (the SAME rule DQ3 hit-tests, so pixels and clicks cannot drift).
// Titles from window title_buf with the title-bar "dui{id}" fallback;
// active = focused member (fallback: visible member); hover = cursor
// geometry (no policy). All fills clamped to the scanout (put_px has no
// bounds check); text/glyphs guarded per-cell.
// ---------------------------------------------------------------------------

/// Scanout-clamped fill (put_px writes blind — every strip fill routes here).
pub fn strip_fill(fb: [*]u8, stride: usize, x: u32, y: u32, w: u32, h: u32, rgb: u32, wspan: usize, hspan: usize) void {
    if (w == 0 or h == 0) return;
    if (x >= wspan or y >= hspan) return;
    const cw: usize = @min(@as(usize, w), wspan - x);
    const chh: usize = @min(@as(usize, h), hspan - y);
    fill_rect(fb, stride, x, y, cw, chh, rgb);
}

/// Guarded 8x16 text draw (drops glyphs that would leave the scanout).
pub fn strip_text(fb: [*]u8, stride: usize, x: u32, y: u32, s: []const u8, rgb: u32, wspan: usize, hspan: usize) void {
    if (y + 16 > hspan) return;
    for (s, 0..) |c, i| {
        const gx = x + @as(u32, @intCast(i)) * 8;
        if (gx + 8 > wspan) break;
        draw_glyph_16(fb, stride, gx, y, c, rgb);
    }
}

/// Guarded 8x8 glyph draw.
pub fn strip_glyph(fb: [*]u8, stride: usize, x: u32, y: u32, c: u8, rgb: u32, wspan: usize, hspan: usize) void {
    if (x + 8 > wspan or y + 8 > hspan) return;
    draw_glyph(fb, stride, x, y, c, rgb);
}

pub fn paint_tab_strip(fb: [*]u8, stride: usize, w: *const Window, ch: *const geom.ChromeDesc, wspan: usize, hspan: usize) void {
    // Collect the group: container first, then attached children in order.
    var members: [max_windows]u8 = undefined;
    var mcount: usize = 0;
    members[0] = w.id;
    mcount = 1;
    var mbuf: [max_windows]u8 = undefined;
    const cn = tab_group_members(w.id, &mbuf);
    var ci: usize = 0;
    while (ci < cn and mcount < members.len) : (ci += 1) {
        members[mcount] = mbuf[ci];
        mcount += 1;
    }
    if (mcount < 2) return; // no attached tabs — nothing to paint

    const strip = geom.tab_strip_rect(w.x, w.y, w.w);
    strip_fill(fb, stride, strip.x, strip.y, strip.w, strip.h, ch.border_unfocus_rgb, wspan, hspan);

    // Active member: the focused one; fallback: the first visible one.
    var active_id: u8 = 0xff;
    var mi: usize = 0;
    while (mi < mcount) : (mi += 1) {
        if (members[mi] == focused_id) {
            active_id = members[mi];
            break;
        }
    }
    if (active_id == 0xff) {
        mi = 0;
        while (mi < mcount) : (mi += 1) {
            if (find_user_window(members[mi])) |mw| {
                if (mw.visible) {
                    active_id = members[mi];
                    break;
                }
            }
        }
    }

    mi = 0;
    while (mi < mcount) : (mi += 1) {
        const id = members[mi];
        const cell = geom.tab_item_rect(strip.x, strip.y, strip.w, mi, mcount);
        if (cell.w == 0) continue;
        const is_active = id == active_id;
        // Cell interior leaves a 1px trough divider on its left (the
        // shared rect still tiles fully — DQ3 hit-tests the full cell).
        if (cell.w > 1) strip_fill(fb, stride, cell.x + 1, cell.y, cell.w - 1, cell.h, ch.title_bg_rgb, wspan, hspan);
        if (is_active) {
            // Active underline: 2px accent at the cell bottom.
            if (cell.h >= 2) strip_fill(fb, stride, cell.x, cell.y + cell.h - 2, cell.w, 2, ch.ring_rgb, wspan, hspan);
        } else if (cursor_shown and geom.tab_rect_contains(cell, cursor_x, cursor_y)) {
            // Hover outline: 1px border on the cell edges.
            strip_fill(fb, stride, cell.x, cell.y, cell.w, 1, ch.border_rgb, wspan, hspan);
            if (cell.h >= 1) strip_fill(fb, stride, cell.x, cell.y + cell.h - 1, cell.w, 1, ch.border_rgb, wspan, hspan);
            strip_fill(fb, stride, cell.x, cell.y, 1, cell.h, ch.border_rgb, wspan, hspan);
            if (cell.w >= 1) strip_fill(fb, stride, cell.x + cell.w - 1, cell.y, 1, cell.h, ch.border_rgb, wspan, hspan);
        }
        // Title: window title_buf, else the title-bar "dui{id}" fallback.
        var tb: [24]u8 = undefined;
        var n: usize = 0;
        if (find_user_window(id)) |mw| {
            if (mw.title_len > 0) {
                n = @min(@as(usize, mw.title_len), tb.len);
                @memcpy(tb[0..n], mw.title_buf[0..n]);
            }
        }
        if (n == 0) {
            @memcpy(tb[0..3], "dui");
            n = 3;
            const idstr = fmt_decimal(tb[n..], id);
            n += idstr.len;
        }
        const lay = geom.tab_title_layout(@as(usize, cell.w), n);
        const tx = cell.x + @as(u32, @intCast(lay.x_off));
        const ty = cell.y + 3;
        if (!lay.truncated) {
            strip_text(fb, stride, tx, ty, tb[0..lay.draw_len], ch.title_fg_rgb, wspan, hspan);
        } else {
            var tt: [24]u8 = undefined;
            @memcpy(tt[0..lay.draw_len], tb[0..lay.draw_len]);
            @memcpy(tt[lay.draw_len..][0..3], "...");
            strip_text(fb, stride, tx, ty, tt[0 .. lay.draw_len + 3], ch.title_fg_rgb, wspan, hspan);
        }
        // Per-tab close glyph (geometry only — DQ3 wires the click).
        const cb = geom.tab_close_rect(cell);
        strip_glyph(fb, stride, cb.x + 2, cb.y + 2, 'x', ch.close_rgb, wspan, hspan);
    }
}

/// The chrome decision for a window: its per-window override, else the
/// WM's broadcast policy, else the shim's own rules expressed as a
/// descriptor (the dark-theme defaults — byte-identical to the pre-WMS4
/// paint). The shim is thus just a default descriptor; parity is by
/// construction.
pub fn effective_chrome(w: *const Window) geom.ChromeDesc {
    if (w.chrome_valid) return w.chrome;
    if (wm_chrome_policy) |p| return p;
    return .{
        .kind = geom.chrome_kind_all,
        .flags = geom.chrome_flag_focus_accent,
        .border_rgb = user_border(),
        .border_unfocus_rgb = user_border_unfocused(),
        .title_bg_rgb = user_title_bg(),
        .title_fg_rgb = user_title_fg_rgb,
        .ring_rgb = focus_ring(),
        .close_rgb = 0xef4444,
        .min_rgb = 0x94a3b8,
        .pin_rgb = 0x38bdf8,
    };
}

/// Arc4 #239 / WM4 (issue #707 card 4): the blend alpha a window's CLIENT
/// area is painted at this frame (256 = fully opaque). Shared by `paint`
/// (the blit) and `chrome_occluded` — only an OPAQUE cover can hide a
/// window's chrome. Pure.
fn client_alpha(w: *const Window) u16 {
    if (w.fade_phase == 1) {
        if (w.fade_tick < fade_half_frames) return 64; // 25%
        if (w.fade_tick < fade_half_frames * 2) return 128; // 50%
        return 256; // fully opaque (fade complete)
    }
    const rest = wm_rest_alpha(w.id);
    if (w.id != focused_id and rest < 256) return @intCast(rest);
    return 256;
}

/// M69g (#1558): whether a user window is COMPLETELY covered by a higher
/// opaque user window. The compositor blits window CONTENT in z-order, so a
/// full-viewport client really does hide every window under it — but the
/// chrome pass runs AFTER the whole stack, so without this check a hidden
/// window paints its title bar and border straight over the covering
/// client's content. GOTABWM's own 96x64 client-death probe window did
/// exactly that over GOSH's tab, hiding the shell's first terminal line (the
/// only line a fresh prompt has). Chrome that cannot be seen is not drawn.
/// Pure over the registry.
fn chrome_occluded(i: usize) bool {
    const w = &windows[i];
    if (w.kind != .user) return false;
    var j = i + 1;
    while (j < win_count) : (j += 1) {
        const o = &windows[j];
        if (o.kind != .user or !o.visible) continue;
        if (!workspace_visible(o)) continue;
        if (client_alpha(o) < 256) continue; // a translucent cover lets chrome through
        if (o.x > w.x or o.y > w.y) continue;
        if (@as(u64, o.x) + o.w < @as(u64, w.x) + w.w) continue;
        if (@as(u64, o.y) + o.h < @as(u64, w.y) + w.h) continue;
        return true;
    }
    return false;
}

/// Card U5/U4: the chrome pass, drawn on the framebuffer AFTER the window
/// paints and BEFORE the transfer — user title bars, the focus ring on the
/// focused window, and the pointer cursor. Chrome never touches a window's
/// back-buffer (user buffers stay EL0-owned).
///
/// M32 WMS4: the per-window chrome decision (elements + colors) comes from
/// the WM's descriptor (`effective_chrome`) — the kernel blits what the
/// descriptor dictates; it no longer decides chrome. The element gating
/// that is DATA, not policy (focus, always-on-top, workspace, terminal)
/// stays kernel-side exactly as before.
pub fn draw_chrome() void {
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const stride = virtio_gpu.fb_width * 4;
    const wspan = virtio_gpu.fb_width;
    const hspan = virtio_gpu.fb_height;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        const w = &windows[i];
        if (w.kind != .user or !w.visible) continue;
        // Arc4 #241: skip chrome for windows not in the current workspace.
        if (!workspace_visible(w)) continue;
        // M69g (#1558): a fully covered window is not visible, so its chrome
        // must not be painted over the covering window's content.
        if (chrome_occluded(i)) continue;
        // M32 WMS4: the chrome LOOK (elements + colors) is the WM's
        // descriptor; the shim's own rules are just the default descriptor.
        const ch = effective_chrome(w);
        // Kind zero disables every chrome element, including shadow bands.
        if (ch.kind == 0) continue;
        const focus_accent = (ch.flags & geom.chrome_flag_focus_accent) != 0;
        // M20-U9: 2px border around the whole window first (paint order:
        // background → border → title bar → buttons → title → content).
        if (ch.kind & geom.chrome_border != 0) {
            const b = if (focus_accent and w.id == focused_id) ch.border_rgb else ch.border_unfocus_rgb;
            const bw = chrome_border_w;
            const ww: usize = if (w.w > wspan) wspan else w.w;
            const wh: usize = if (w.h > hspan) hspan else w.h;
            fill_rect(fb, stride, w.x, w.y, ww, bw, b); // top
            if (wh > bw) fill_rect(fb, stride, w.x, w.y + wh - bw, ww, bw, b); // bottom
            fill_rect(fb, stride, w.x, w.y, bw, wh, b); // left
            if (ww > bw) fill_rect(fb, stride, w.x + ww - bw, w.y, bw, wh, b); // right
        }
        // M37 DQ4: drop-shadow bands OUTSIDE the window rect (right +
        // bottom + corner), drawn back-to-front per window so a front
        // window covers the shadow of the one beneath. Flag-gated
        // (`settings set shadow on`, default off): put_px does no
        // clipping, so every band is clamped to the scanout here.
        if (settings.get_shadow()) {
            const sc = shadow_color();
            const so = chrome_shadow_off;
            const ww: usize = if (w.w > wspan) wspan else w.w;
            const wh: usize = if (w.h > hspan) hspan else w.h;
            const zx0 = w.x + ww;
            const zy0 = w.y + so;
            const zy1 = @min(w.y + wh, hspan);
            if (zx0 < wspan and zy1 > zy0) {
                const zx1 = @min(zx0 + so, wspan);
                fill_rect(fb, stride, zx0, zy0, zx1 - zx0, zy1 - zy0, sc); // right
            }
            const bx0 = w.x + so;
            const by0 = w.y + wh;
            if (by0 < hspan and bx0 < wspan) {
                const bx1 = @min(bx0 + ww -| so, wspan);
                const by1 = @min(by0 + so, hspan);
                if (bx1 > bx0) fill_rect(fb, stride, bx0, by0, bx1 - bx0, by1 - by0, sc); // bottom
                if (zx0 < wspan and by1 > by0) {
                    const cx1 = @min(zx0 + so, wspan);
                    fill_rect(fb, stride, zx0, by0, cx1 - zx0, by1 - by0, sc); // corner
                }
            }
        }
        // Title bar: "dui<id> pid=<pid>" (the owning pid when known),
        // CENTERED with "..." truncation when it does not fit (M20-U9). The
        // label is DATA (kernel-owned); its colors are the WM's.
        if (ch.kind & geom.chrome_title != 0) {
            fill_rect(fb, stride, w.x, w.y, w.w, user_title_h, ch.title_bg_rgb);
            var tb: [24]u8 = undefined;
            var n: usize = 0;
            const label = "dui";
            @memcpy(tb[0..3], label);
            n = 3;
            const idstr = fmt_decimal(tb[n..], w.id);
            n += idstr.len;
            if (w.owner) |pid| {
                const ps = " pid=";
                @memcpy(tb[n..][0..ps.len], ps);
                n += ps.len;
                const pids = fmt_decimal(tb[n..], pid);
                n += pids.len;
            }
            const lay = chrome_title_layout(w.w, n);
            if (!lay.truncated) {
                draw_string_16(fb, stride, w.x + lay.x_off, w.y, tb[0..lay.draw_len], ch.title_fg_rgb);
            } else {
                var tt: [24]u8 = undefined;
                @memcpy(tt[0..lay.draw_len], tb[0..lay.draw_len]);
                @memcpy(tt[lay.draw_len..][0..3], "...");
                draw_string_16(fb, stride, w.x + lay.x_off, w.y, tt[0 .. lay.draw_len + 3], ch.title_fg_rgb);
            }
        }
        // Step 6: close button ("×" — red glyph at top-right of title bar).
        if (ch.kind & geom.chrome_close != 0) {
            draw_glyph(fb, stride, w.x + w.w - 14, w.y + 4, 'x', ch.close_rgb);
        }
        // Step 7: minimize button ("—" — muted glyph left of close).
        if (ch.kind & geom.chrome_minimize != 0) {
            draw_glyph(fb, stride, w.x + w.w - 26, w.y + 4, '-', ch.min_rgb);
        }
        // M21 W8: pin indicator for always-on-top windows ("*" — cyan glyph left of minimize).
        if (ch.kind & geom.chrome_pin != 0 and w.always_on_top and w.w >= 50) {
            draw_glyph(fb, stride, w.x + w.w - 38, w.y + 4, '*', ch.pin_rgb);
        }
        // M37 DQ2 (issue #840): tab strip on containers with attached tabs.
        // Containers only (children paint no strip of their own); hidden
        // groups never reach here (invisible windows skip above).
        if (ch.kind & geom.chrome_tab_bar != 0 and w.tab_parent == 0 and tab_group_count(w.id) > 0) {
            paint_tab_strip(fb, stride, w, &ch, wspan, hspan);
        }
    }
    // The focus ring: on the focused window's rect (D4 — focus is always
    // visible). 0xff = none (no ring). The full-screen TERMINAL never
    // carries it (issue #164): it is the always-focused background, and a
    // ring around it paints a white strip over the first/last text row
    // and column — the live-glyphs tripwire decoded cell 0 of every line
    // as unknown. The clock and user windows keep the ring.
    if (focused_id != 0xff) {
        var idx: usize = 0;
        while (idx < win_count) : (idx += 1) {
            if (windows[idx].id != focused_id) continue;
            const w = &windows[idx];
            if (w.kind == .terminal) break;
            // Arc4 #241: don't draw focus ring on off-workspace windows.
            if (!workspace_visible(w)) break;
            // M32 WMS4: the ring is drawn only when the WM's descriptor
            // enables it, in the WM's ring color (shim: always, accent).
            if (effective_chrome(w).kind & geom.chrome_ring == 0) break;
            const rx: usize = w.x;
            const ry: usize = w.y;
            const rw: usize = if (w.w > wspan) wspan else w.w;
            const rh: usize = if (w.h > hspan) hspan else w.h;
            const ring_rgb = effective_chrome(w).ring_rgb;
            fill_rect(fb, stride, rx, ry, rw, focus_ring_w, ring_rgb);
            fill_rect(fb, stride, rx, ry + rh - focus_ring_w, rw, focus_ring_w, ring_rgb);
            fill_rect(fb, stride, rx, ry, focus_ring_w, rh, ring_rgb);
            fill_rect(fb, stride, rx + rw - focus_ring_w, ry, focus_ring_w, rh, ring_rgb);
            break;
        }
    }
    // M15 C2 (Alt+Tab overlay, #225): centered window previews while Alt held.
    // Topmost below notification (D7 ordering), above user chrome. Dim the
    // backdrop by filling a translucent dark rect over the whole scanout, then
    // a centered list of user-window rows with highlight on `overlay_selected`.
    if (overlay_active and overlay_count > 0) {
        // Dim backdrop — 50% dark (opaque dark gray is the honest preview for the
        // host's ScreenCaptureKit composite; true alpha would be compositor-pricey).
        fill_rect(fb, stride, 0, 0, wspan, hspan, 0x0f0f1a);
        const ov_w: u32 = 440;
        const row_h: u32 = 28;
        const header_h: u32 = 24;
        const pad: u32 = 8;
        const ov_h: u32 = header_h + pad * 2 + @as(u32, @intCast(overlay_count)) * row_h + pad;
        const ov_x: u32 = if (wspan > ov_w) (wspan - ov_w) / 2 else 0;
        const ov_y: u32 = if (hspan > ov_h) (hspan - ov_h) / 2 else 0;
        // Overlay surface + border.
        fill_rect(fb, stride, ov_x, ov_y, ov_w, ov_h, 0x1e293b);
        // 2-px border in accent.
        fill_rect(fb, stride, ov_x, ov_y, ov_w, 2, clock_accent_rgb);
        fill_rect(fb, stride, ov_x, ov_y + ov_h - 2, ov_w, 2, clock_accent_rgb);
        fill_rect(fb, stride, ov_x, ov_y, 2, ov_h, clock_accent_rgb);
        fill_rect(fb, stride, ov_x + ov_w - 2, ov_y, 2, ov_h, clock_accent_rgb);
        // M21 W4: show workspace name in the overlay header.
        draw_string(fb, stride, ov_x + pad, ov_y + pad, "Alt+Tab  —  Switch window", 0xffffff);
        var ws_label_buf: [8]u8 = undefined;
        ws_label_buf[0] = ' ';
        ws_label_buf[1] = ' ';
        ws_label_buf[2] = 'W';
        ws_label_buf[3] = 'S';
        ws_label_buf[4] = ' ';
        ws_label_buf[5] = '0' + current_workspace;
        draw_string(fb, stride, ov_x + pad + 200, ov_y + pad, ws_label_buf[0..6], 0xf59e0b);
        draw_string(fb, stride, ov_x + pad, ov_y + pad + 12, "(Tab / Shift+Tab cycles, release Alt)", 0x94a3b8);
        var idx: usize = 0;
        while (idx < overlay_count) : (idx += 1) {
            const id = overlay_ids[idx];
            const row_y = ov_y + header_h + pad + @as(u32, @intCast(idx)) * row_h;
            const is_sel = idx == overlay_selected;
            const bg = if (is_sel) taskbar_entry_active() else 0x0f172a;
            fill_rect(fb, stride, ov_x + pad, row_y, ov_w - pad * 2, row_h - 2, bg);
            // Outline highlight on selected.
            if (is_sel) {
                fill_rect(fb, stride, ov_x + pad, row_y, ov_w - pad * 2, 1, 0xffffff);
                fill_rect(fb, stride, ov_x + pad, row_y + row_h - 3, ov_w - pad * 2, 1, 0xffffff);
            }
            var win_title: []const u8 = "user";
            var win_owner: ?usize = null;
            var k: usize = 0;
            while (k < win_count) : (k += 1) {
                if (windows[k].id == id and windows[k].kind == .user) {
                    win_title = windows[k].title;
                    win_owner = windows[k].owner;
                    break;
                }
            }
            var tbuf: [32]u8 = undefined;
            var tn: usize = 0;
            @memcpy(tbuf[0..4], "dui ");
            tn = 4;
            const id_s = fmt_decimal(tbuf[tn..], id);
            tn += id_s.len;
            if (win_owner) |pid| {
                const pfx = " pid=";
                @memcpy(tbuf[tn..][0..pfx.len], pfx);
                tn += pfx.len;
                const pid_s = fmt_decimal(tbuf[tn..], pid);
                tn += pid_s.len;
            }
            draw_string(fb, stride, ov_x + pad + 6, row_y + 10, tbuf[0..tn], if (is_sel) 0xffffff else 0xd8dee9);
            draw_string(fb, stride, ov_x + ov_w - pad - 80, row_y + 10, win_title, 0x94a3b8);
            // M27 G3: render scaled preview of the window's content.
            render_preview(id);
            const pv_x = ov_x + ov_w - pad - 68;
            const pv_y = row_y + 4;
            const pv_w: u32 = 64;
            const pv_h: u32 = row_h - 8;
            blit_rect(fb, stride, @ptrCast(&preview_buf), pv_w * 4, pv_x, pv_y, pv_w, pv_h);
            // Border around preview.
            fill_rect(fb, stride, pv_x, pv_y, pv_w, 1, 0x64748b);
            fill_rect(fb, stride, pv_x, pv_y + pv_h - 1, pv_w, 1, 0x64748b);
            fill_rect(fb, stride, pv_x, pv_y, 1, pv_h, 0x64748b);
            fill_rect(fb, stride, pv_x + pv_w - 1, pv_y, 1, pv_h, 0x64748b);
        }
    }
    // WM2 mission-control overview (issue #707 card 2): the grid paints
    // above the alt-tab overlay (both cannot be open at once in practice —
    // the WM exits overview before other chords — but a deterministic order
    // keeps the scanout honest if they ever coincide).
    if (overview_open) paint_overview(fb, stride, wspan, hspan);
    // M32 WMS8 Gate 6 (issue #628): the kernel snap-preview render (dragging
    // near an edge highlighted the zone) is DELETED — the WM owns snap-on-
    // drop; with a WM registered pointer_tick never reaches this drag path.
    // Arc4 #242: unsaved-changes confirmation dialog — centered modal.
    if (unsaved_dialog_open) {
        const dlg_w: u32 = 200;
        const dlg_h: u32 = 100;
        const dlg_x: u32 = if (wspan > dlg_w) (wspan - dlg_w) / 2 else 0;
        const dlg_y: u32 = if (hspan > dlg_h) (hspan - dlg_h) / 2 else 0;
        // Dim backdrop.
        fill_rect(fb, stride, 0, 0, wspan, hspan, 0x0f0f1a);
        // Dialog surface.
        fill_rect(fb, stride, dlg_x, dlg_y, dlg_w, dlg_h, 0x1e293b);
        // Border.
        fill_rect(fb, stride, dlg_x, dlg_y, dlg_w, 2, 0xf59e0b);
        fill_rect(fb, stride, dlg_x, dlg_y + dlg_h - 2, dlg_w, 2, 0xf59e0b);
        fill_rect(fb, stride, dlg_x, dlg_y, 2, dlg_h, 0xf59e0b);
        fill_rect(fb, stride, dlg_x + dlg_w - 2, dlg_y, 2, dlg_h, 0xf59e0b);
        // Message.
        draw_string(fb, stride, dlg_x + 10, dlg_y + 10, "Save before closing?", 0xffffff);
        // Buttons: Save (green), Don't Save (red), Cancel (gray).
        fill_rect(fb, stride, dlg_x + 20, dlg_y + dlg_h - 30, 60, 20, 0x10b981);
        draw_string(fb, stride, dlg_x + 26, dlg_y + dlg_h - 24, "Save", 0xffffff);
        fill_rect(fb, stride, dlg_x + 90, dlg_y + dlg_h - 30, 60, 20, 0xef4444);
        draw_string(fb, stride, dlg_x + 96, dlg_y + dlg_h - 24, "Don't", 0xffffff);
        fill_rect(fb, stride, dlg_x + 160, dlg_y + dlg_h - 30, 30, 20, 0x64748b);
        draw_string(fb, stride, dlg_x + 163, dlg_y + dlg_h - 24, "No", 0xffffff);
    }
    // Arc4 #240: notification toasts — top-right, stacked newest-top.
    // 300×40 px per toast, 8×8 font, colored left border.
    if (notify_count > 0) {
        const toast_w: u32 = 300;
        const toast_h: u32 = 40;
        const toast_x: u32 = if (wspan > toast_w) wspan - toast_w - 8 else 0;
        var ti: usize = 0;
        while (ti < notify_count) : (ti += 1) {
            if (notify_entry(ti)) |entry| {
                const toast_y: u32 = 8 + @as(u32, @intCast(ti)) * (toast_h + 4);
                if (toast_y + toast_h > hspan) break;
                // Background.
                fill_rect(fb, stride, toast_x, toast_y, toast_w, toast_h, 0x1e293b);
                // Colored left border: blue=info, amber=warn, red=error.
                const border_color: u32 = switch (entry.level) {
                    1 => 0xf59e0b, // amber warning
                    2 => 0xef4444, // red error
                    else => 0x3b82f6, // blue info
                };
                fill_rect(fb, stride, toast_x, toast_y, 4, toast_h, border_color);
                // Text — up to 36 chars (300-8 px / 8 px per glyph).
                const max_chars = 36;
                const len = @min(entry.text.len, max_chars);
                if (len > 0) {
                    draw_string(fb, stride, toast_x + 10, toast_y + 6, entry.text[0..len], 0xffffff);
                }
            }
        }
    }
    // M21 W5: notification center panel — right-side pull-out when open.
    if (notif_center_open) {
        const panel_x: u32 = if (wspan > notif_center_w) wspan - notif_center_w else 0;
        const panel_y: u32 = 40;
        const row_h: u32 = 36;
        const pad: u32 = 8;
        const header_h: u32 = 24;
        const display_count = @min(notify_count, 8);
        const panel_h: u32 = header_h + pad * 2 + @as(u32, @intCast(display_count)) * row_h + pad + 28;
        // Dim backdrop.
        fill_rect(fb, stride, 0, 0, wspan, hspan, 0x0f0f1a);
        // Panel surface.
        fill_rect(fb, stride, panel_x, panel_y, notif_center_w, panel_h, 0x1e293b);
        // Border.
        fill_rect(fb, stride, panel_x, panel_y, notif_center_w, 2, 0x3b82f6);
        fill_rect(fb, stride, panel_x, panel_y + panel_h - 2, notif_center_w, 2, 0x3b82f6);
        fill_rect(fb, stride, panel_x, panel_y, 2, panel_h, 0x3b82f6);
        fill_rect(fb, stride, panel_x + notif_center_w - 2, panel_y, 2, panel_h, 0x3b82f6);
        // Header.
        draw_string(fb, stride, panel_x + pad, panel_y + pad, "Notifications", 0xffffff);
        // Notification rows.
        var ni: usize = 0;
        while (ni < display_count) : (ni += 1) {
            if (notify_entry(ni)) |entry| {
                const row_y = panel_y + header_h + pad + @as(u32, @intCast(ni)) * row_h;
                const bg: u32 = if (ni == 0) 0x0f172a else 0x1e293b;
                fill_rect(fb, stride, panel_x + pad, row_y, notif_center_w - pad * 2, row_h - 2, bg);
                // Colored left border.
                const border_color: u32 = switch (entry.level) {
                    1 => 0xf59e0b,
                    2 => 0xef4444,
                    else => 0x3b82f6,
                };
                fill_rect(fb, stride, panel_x + pad, row_y, 4, row_h - 2, border_color);
                // Text — up to 34 chars.
                const max_chars = 34;
                const len = @min(entry.text.len, max_chars);
                if (len > 0) {
                    draw_string(fb, stride, panel_x + pad + 10, row_y + 6, entry.text[0..len], 0xffffff);
                }
            }
        }
        // "Clear all" button.
        const btn_y = panel_y + header_h + pad * 2 + @as(u32, @intCast(display_count)) * row_h + pad;
        fill_rect(fb, stride, panel_x + pad, btn_y, notif_center_w - pad * 2, 20, 0xef4444);
        draw_string(fb, stride, panel_x + pad + 8, btn_y + 6, "Clear all", 0xffffff);
    }
    // M27 G2: about dialog — centered modal.
    if (about_dialog_open) {
        const dlg_w: u32 = 280;
        const dlg_h: u32 = 160;
        const dlg_x: u32 = if (wspan > dlg_w) (wspan - dlg_w) / 2 else 0;
        const dlg_y: u32 = if (hspan > dlg_h) (hspan - dlg_h) / 2 else 0;
        // Dim backdrop.
        fill_rect(fb, stride, 0, 0, wspan, hspan, 0x0f0f1a);
        // Dialog surface.
        fill_rect(fb, stride, dlg_x, dlg_y, dlg_w, dlg_h, 0x1e293b);
        // Border.
        fill_rect(fb, stride, dlg_x, dlg_y, dlg_w, 2, 0x3b82f6);
        fill_rect(fb, stride, dlg_x, dlg_y + dlg_h - 2, dlg_w, 2, 0x3b82f6);
        fill_rect(fb, stride, dlg_x, dlg_y, 2, dlg_h, 0x3b82f6);
        fill_rect(fb, stride, dlg_x + dlg_w - 2, dlg_y, 2, dlg_h, 0x3b82f6);
        // Title.
        draw_string(fb, stride, dlg_x + 10, dlg_y + 10, "VirelaiOS", clock_accent_rgb);
        // Version.
        draw_string(fb, stride, dlg_x + 10, dlg_y + 26, "v0.1  (M21+M27)", 0x94a3b8);
        // Info lines.
        draw_string(fb, stride, dlg_x + 10, dlg_y + 42, "AArch64 on Apple Virtualization", 0xd8dee9);
        draw_string(fb, stride, dlg_x + 10, dlg_y + 54, ".framework", 0xd8dee9);
        draw_string(fb, stride, dlg_x + 10, dlg_y + 70, "Built with Zig 0.17", 0x94a3b8);
        draw_string(fb, stride, dlg_x + 10, dlg_y + 86, "Window Manager: Driving Award", 0x94a3b8);
        // Close button.
        fill_rect(fb, stride, dlg_x + dlg_w - 16, dlg_y + 4, 8, 8, 0xef4444);
        draw_glyph(fb, stride, dlg_x + dlg_w - 14, dlg_y + 4, 'x', 0xffffff);
    }
    // M27 G6: tooltip — small text box below cursor on hover.
    if (tooltip_visible and tooltip_text_len > 0) {
        const tw: u32 = @as(u32, tooltip_text_len) * 8 + 8;
        const th: u32 = 14;
        var tx: u32 = cursor_x + 4;
        var ty: u32 = cursor_y + 12;
        // Clamp to scanout.
        if (tx + tw > wspan) tx = if (wspan > tw) wspan - tw else 0;
        if (ty + th > hspan) ty = if (hspan > th) hspan - th else 0;
        fill_rect(fb, stride, tx, ty, tw, th, 0x1e293b);
        fill_rect(fb, stride, tx, ty, tw, 1, 0x3b82f6);
        draw_string(fb, stride, tx + 4, ty + 3, tooltip_text[0..tooltip_text_len], 0xffffff);
    }
}

// ---------------------------------------------------------------------------
// M76a (#1674): the splash-to-seat handoff hold.
//
// render_splash leaves `splash_hold` standing: while it stands,
// composite() refuses every kernel present (no transfer+flush), so the
// splash frame stays exactly where the last flush put it — the tee keeps
// writing the text layer into the framebuffer underneath, but the pixels
// do not move until the handoff resolves. The hold ends on the first of:
//
//   * the seat binding the scanout (`wm_owns_user_layer`, set by
//     wm_server.scanout_bind) — the seat paints through its OWN present
//     path (wm_server.request_present), which is never suppressed, so the
//     screen goes splash -> seat in one frame with zero kernel-art frames
//     between. The serial ordering for that happy path is carried by the
//     seat's own markers (go-dogfood: `wm: autostart` ->
//     `gotabwm: registered` -> `gotabwm: seat-taken`).
//   * the BOUND: `splash_bound_ticks` timer ticks (1 Hz) after the first
//     idle evaluation — one honest klog line naming what was waited for,
//     then Road Pops presents as before. The bound is stated in (and
//     gated by) tools/gate/specs/live-roadpops.spec. Every no-seat
//     outcome lands exactly as today, honestly and on time: share mode
//     `none` (`GOTABWM.ELF not on the share`), `settings wm none`, and a
//     seat that loads but never binds all reach the bound and say so.
//
// Headless boots never engage the hold: render_splash early-returns when
// the gpu never armed, and the hold is only set on the path that actually
// pushed a splash frame. No timing is tuned by feel — the bound is one
// named constant, and the spec asserts both its arithmetic and its line.
// The M59 invariant is untouched: this changes pixels only; the `wm` and
// `shell` compiled defaults, the monitor, and the serial seam are all
// exactly where they were (every line still reaches klog/uart first).
// ---------------------------------------------------------------------------

/// Whether the splash frame is still holding the scanout.
pub var splash_hold: bool = false;
/// The timer.ticks value of the first evaluation — the bound's anchor.
var splash_anchor_tick: ?u64 = null;
/// The bound: 1 Hz timer ticks after the anchor before the hold expires
/// honestly. Stated and gated in tools/gate/specs/live-roadpops.spec.
pub const splash_bound_ticks: u64 = 3;

/// The deadline pump, called from drain(ticks) every idle iteration.
/// First evaluation anchors the bound; the expiry prints ONE line.
fn splash_eval(ticks: u64) void {
    if (!splash_hold) return;
    if (wm_owns_user_layer) {
        splash_hold = false; // the seat bound the scanout: silent handoff
        return;
    }
    const anchor = splash_anchor_tick orelse {
        splash_anchor_tick = ticks;
        return;
    };
    if (ticks < anchor + splash_bound_ticks) return;
    splash_hold = false;
    var buf: [96]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "splash: seat present not observed within {d}s, continuing with Road Pops\n",
        .{splash_bound_ticks},
    ) catch return;
    klog.line(line);
}

// Host tests pin the handoff state machine; the pixel half (the splash
// actually holding the scanout) is gated live by live-roadpops (seatless
// bound) and go-dogfood (happy-path handoff).
var splash_test_log: [192]u8 = undefined;
var splash_test_log_len: usize = 0;
fn splash_test_capture(bytes: []const u8) void {
    splash_test_log_len = @min(bytes.len, splash_test_log.len);
    @memcpy(splash_test_log[0..splash_test_log_len], bytes[0..splash_test_log_len]);
}

test "splash hold: bound expires with one honest line" {
    splash_hold = false;
    splash_anchor_tick = null;
    splash_test_log_len = 0;
    // Headless (gpu never armed): render_splash must NOT engage the hold.
    render_splash(1);
    try std.testing.expect(!splash_hold);
    klog.line_hook = splash_test_capture;
    defer klog.line_hook = null;
    // Engage, anchor on the first evaluation, hold through bound-1...
    splash_hold = true;
    splash_anchor_tick = null;
    splash_eval(10);
    try std.testing.expect(splash_hold);
    try std.testing.expect(splash_anchor_tick == 10);
    splash_eval(10 + splash_bound_ticks - 1);
    try std.testing.expect(splash_hold);
    // ...and expire exactly at anchor + bound, with the line.
    splash_eval(10 + splash_bound_ticks);
    try std.testing.expect(!splash_hold);
    try std.testing.expect(splash_test_log_len > 0);
    try std.testing.expect(std.mem.indexOf(
        u8,
        splash_test_log[0..splash_test_log_len],
        "seat present not observed within 3s",
    ) != null);
}

test "splash hold: a seat that binds releases silently" {
    splash_hold = true;
    splash_anchor_tick = null;
    splash_test_log_len = 0;
    klog.line_hook = splash_test_capture;
    defer klog.line_hook = null;
    wm_owns_user_layer = true;
    defer wm_owns_user_layer = false;
    splash_eval(50);
    try std.testing.expect(!splash_hold);
    // The happy path never prints: the seat's own markers carry the chain.
    try std.testing.expect(splash_test_log_len == 0);
}

test "splash hold: composite refuses kernel presents while held" {
    splash_hold = true;
    defer splash_hold = false;
    const before = presents;
    // Held: .ok WITHOUT painting or flushing — the splash frame survives
    // on the scanout (the gpu flush half never runs: the guard returns
    // before paint_scene, so this is host-test safe with no device).
    try std.testing.expect(composite() == .ok);
    try std.testing.expect(presents == before);
}

test "compositor: a bound WM keeps exclusive paint and present ownership" {
    const saved_armed = armed_global;
    const saved_owned = wm_owns_user_layer;
    const saved_hold = splash_hold;
    const saved_dirty = scene_dirty;
    defer {
        armed_global = saved_armed;
        wm_owns_user_layer = saved_owned;
        splash_hold = saved_hold;
        scene_dirty = saved_dirty;
    }
    armed_global = false; // unowned path is .not_ready, with no hardware work
    splash_hold = false;
    wm_owns_user_layer = true;
    scene_dirty = true;
    const before = presents;
    try std.testing.expectEqual(virtio_gpu.CmdResult.ok, composite());
    try std.testing.expect(scene_dirty); // do not consume the WM's pending paint
    try std.testing.expectEqual(before, presents);
    splash_hold = true;
    try std.testing.expectEqual(virtio_gpu.CmdResult.ok, composite());
    try std.testing.expect(!splash_hold); // the scanout bind still ends the hold
    wm_owns_user_layer = false;
    try std.testing.expectEqual(virtio_gpu.CmdResult.not_ready, composite());
}

test "hosted chrome: full viewport replaces the native frame before the first present" {
    arm();
    clear_wm_chrome();
    wm_owns_user_layer = true;
    defer wm_owns_user_layer = false;
    const id = switch (user_open(32, 32, 512, 384, 7)) {
        .opened => |opened| opened,
        else => return error.TestUnexpectedResult,
    };
    virtio_gpu.fill_framebuffer(0x182026);
    try std.testing.expectEqual(virtio_gpu.CmdResult.ok, paint_scene());
    const old_border = (415 * virtio_gpu.fb_width + 300) * 4;
    try std.testing.expectEqual(@as(u8, 0xf6), virtio_gpu.gpu_fb[old_border]);
    var desc = geom.chrome_parity_policy();
    desc.kind = 0;
    try std.testing.expect(set_window_chrome(id, desc));
    try std.testing.expect(wm_apply_rect(id, 0, 0, virtio_gpu.fb_width, virtio_gpu.fb_height));
    const win = find_user_window(id).?;
    // No tick or present has occurred since the handoff. Neither the old
    // body/title/frame nor a new screen-edge ring may survive it.
    draw_chrome();
    try std.testing.expectEqualSlices(u8, kbuf_ptr(win)[0..virtio_gpu.fb_size], &virtio_gpu.gpu_fb);
    try std.testing.expectEqual(@as(u16, 256), client_alpha(win));
    // A later split remains hosted; focus changes cannot reintroduce chrome.
    try std.testing.expect(wm_apply_rect(id, 0, 0, 640, 720));
    virtio_gpu.fill_framebuffer(0x182026);
    draw_chrome();
    try std.testing.expectEqual(@as(u8, 0x26), virtio_gpu.gpu_fb[0]);
    focused_id = 0xff;
    draw_chrome();
    try std.testing.expectEqual(@as(u8, 0x26), virtio_gpu.gpu_fb[0]);
}

test "hosted chrome: migrated clients skip frame title and focus ring" {
    arm();
    clear_wm_chrome();
    wm_owns_user_layer = true;
    defer wm_owns_user_layer = false;
    const id = switch (user_open(32, 32, 512, 384, 7)) {
        .opened => |opened| opened,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(user_bind_surface(id, .{ .handle = 1, .pa_base = 0x1000_0000, .page_count = 192 }));
    var desc = geom.chrome_parity_policy();
    desc.kind = 0;
    try std.testing.expect(set_window_chrome(id, desc));
    virtio_gpu.fill_framebuffer(0x182026);
    try std.testing.expectEqual(virtio_gpu.CmdResult.ok, paint_scene());
    const at = (32 * virtio_gpu.fb_width + 32) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0x26, 0x20, 0x18, 0xff }, virtio_gpu.gpu_fb[at..][0..4]);
}

test "hosted chrome: no-chrome descriptor also suppresses shadows" {
    arm();
    clear_wm_chrome();
    const shadow = settings.get_shadow();
    defer {
        _ = settings.set("shadow", if (shadow) "on" else "off");
    }
    _ = settings.set("shadow", "on");
    const id = switch (user_open(32, 32, 512, 384, 7)) {
        .opened => |opened| opened,
        else => return error.TestUnexpectedResult,
    };
    var desc = geom.chrome_parity_policy();
    desc.kind = 0;
    try std.testing.expect(set_window_chrome(id, desc));
    virtio_gpu.fill_framebuffer(0x182026);
    draw_chrome();
    for (0..virtio_gpu.fb_size / 4) |i| {
        try std.testing.expectEqualSlices(u8, &.{ 0x26, 0x20, 0x18, 0xff }, virtio_gpu.gpu_fb[i * 4 ..][0..4]);
    }
}

test "hosted chrome: explicit seat chrome and the unbound shim retain their look" {
    arm();
    clear_wm_chrome();
    wm_owns_user_layer = true;
    defer wm_owns_user_layer = false;
    const id = switch (user_open(32, 32, 512, 384, 7)) {
        .opened => |opened| opened,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(wm_apply_rect(id, 0, 0, virtio_gpu.fb_width, virtio_gpu.fb_height));
    const menu = switch (user_open(224, 692, 96, 20, 1)) {
        .opened => |opened| opened,
        else => return error.TestUnexpectedResult,
    };
    var desc = effective_chrome(find_user_window(menu).?);
    desc.kind = geom.chrome_border;
    desc.border_rgb = 0x123456;
    try std.testing.expect(set_window_chrome(menu, desc));
    virtio_gpu.fill_framebuffer(0x182026);
    draw_chrome();
    const at = (692 * virtio_gpu.fb_width + 224) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0x56, 0x34, 0x12, 0xff }, virtio_gpu.gpu_fb[at..][0..4]);
    try std.testing.expect(user_close(menu));
    try std.testing.expect(focus(id));
    // The descriptor remains authoritative even for a full-viewport client.
    try std.testing.expect(set_window_chrome(id, desc));
    virtio_gpu.fill_framebuffer(0x182026);
    draw_chrome();
    try std.testing.expectEqual(@as(u8, 0x56), virtio_gpu.gpu_fb[0]);
    clear_wm_chrome();
    wm_owns_user_layer = false;
    virtio_gpu.fill_framebuffer(0x182026);
    draw_chrome();
    try std.testing.expectEqual(@as(u8, 0xf6), virtio_gpu.gpu_fb[0]);
}

test "hosted chrome: zero broadcast is refused without changing existing policy" {
    arm();
    clear_wm_chrome();
    const policy = geom.chrome_parity_policy();
    try std.testing.expect(set_window_chrome(geom.chrome_window_all, policy));
    var none = policy;
    none.kind = 0;
    try std.testing.expect(!set_window_chrome(geom.chrome_window_all, none));
    try std.testing.expectEqual(policy.kind, wm_chrome_policy.?.kind);
    clear_wm_chrome();
}

/// Step 13 (Issue #213): boot splash screen. Renders once into the framebuffer
/// and pushes a transfer+flush. Shows the system name in 8×16 font, version,
/// and a cycling progress indicator. Returns after `max_ticks` or when a
/// keystroke arrives (whichever is first).
pub fn render_splash(max_ticks: u64) void {
    if (!armed_global or !virtio_gpu.gpu_ready) return;
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const stride = virtio_gpu.fb_width * 4;
    // Fill background.
    fill_rect(fb, stride, 0, 0, virtio_gpu.fb_width, virtio_gpu.fb_height, wallpaper_top());
    // Title: "VirelaiOS" centered, using 8×16 font (the draw_glyph path,
    // stretched to 2× height).
    const title = "VirelaiOS";
    const title_x: usize = (virtio_gpu.fb_width - title.len * 8) / 2;
    const title_y: usize = virtio_gpu.fb_height / 2 - 40;
    // Render each glyph at 2× height (simple stretch).
    for (title, 0..) |ch, i| {
        if (ch < 0x20 or ch > 0x7e) continue;
        const glyph = font.glyphs[ch - 0x20];
        var gy: usize = 0;
        while (gy < 8) : (gy += 1) {
            const bits = glyph[gy];
            var gx: usize = 0;
            while (gx < 8) : (gx += 1) {
                if (font.row_pixel(bits, gx)) {
                    // Draw at 2× size.
                    fill_rect(fb, stride, title_x + i * 8 + gx * 2, title_y + gy * 2, 2, 2, clock_accent_rgb);
                }
            }
        }
    }
    // Version line.
    draw_string(fb, stride, title_x + 16, title_y + 24, "v0.1", clock_fg_rgb);
    // Push the splash frame.
    _ = virtio_gpu.gpu_transfer();
    _ = virtio_gpu.gpu_flush();
    // Cycle progress indicator for max_ticks (or until GPU not ready).
    var tick: u64 = 0;
    while (tick < max_ticks) : (tick += 1) {
        // Simple busy-wait for ~1 second per tick (the timer is not yet
        // running at this point in boot).
        var wait: u64 = 0;
        while (wait < 10_000_000) : (wait += 1) {}
        // Draw cycling dots.
        const dots = [5]u8{ '.', 'o', 'O', 'o', '.' };
        const dot_idx = tick % 5;
        fill_rect(fb, stride, title_x + 24, title_y + 40, 40, 8, wallpaper_top());
        draw_glyph(fb, stride, title_x + 24 + @as(usize, @intCast(dot_idx)) * 8, title_y + 40, dots[dot_idx], clock_fg_rgb);
        _ = virtio_gpu.gpu_transfer();
        _ = virtio_gpu.gpu_flush();
    }
    // M76a (#1674): the splash frame is now the scanout's LAST flush —
    // engage the handoff hold. Reached only on the armed+gpu-ready path
    // (the early return above left every headless boot untouched), so a
    // real splash was pushed and the hold may stand on it.
    splash_hold = true;
    splash_anchor_tick = null;
}

/// Refresh the tray clock from the 1 Hz generic timer and composite any dirty
/// windows. The shell idle loop is the drain site (the card-3d pattern).
/// Clock ticks on composite() without timer — drain marks taskbar dirty when
/// the minute (or tick) advances; composite() also handles theme/clipboard.
pub fn drain(ticks: u64) virtio_gpu.CmdResult {
    if (!armed_global) return .not_ready;
    // M76a (#1674): the splash-hold deadline pump — every idle iteration
    // while the shim composites. Anchors the bound on the first call,
    // releases silently when the seat binds, expires honestly at the
    // bound. While the hold stands, the clock/tray churn is skipped too:
    // nothing may mark the scene dirty enough to matter — composite()
    // refuses it anyway, and the seat's own presents are never suppressed.
    splash_eval(ticks);
    if (splash_hold) return .not_ready;
    var need = false;
    if (!tray_has_tick or ticks != tray_tick) {
        tray_has_tick = true;
        tray_tick = ticks;
        need = true;
        // Keep deprecated clock vars in sync for any external read.
        clock_has_tick = true;
        clock_shown_tick = ticks;
    }
    if (tray_last_theme != theme_id) {
        tray_last_theme = theme_id;
        need = true;
    }
    const cur_clip = clipboard.current_len();
    if (cur_clip != tray_last_clip_len) {
        tray_last_clip_len = cur_clip;
        need = true;
    }
    if (need) _ = mark_dirty(255);
    return composite();
}

// #1688: line-hook capture for the forward's marker pins — the splash
// capture pattern, but APPENDING: the begin and end lines must coexist in
// one buffer to be pinned together.
var wm_fwd_test_log: [512]u8 = undefined;
var wm_fwd_test_log_len: usize = 0;

fn wm_fwd_test_capture(bytes: []const u8) void {
    const n = @min(bytes.len, wm_fwd_test_log.len - wm_fwd_test_log_len);
    @memcpy(wm_fwd_test_log[wm_fwd_test_log_len..][0..n], bytes[0..n]);
    wm_fwd_test_log_len += n;
}

test "wm content forward: a seat-forwarded drag runs local selection (#1688)" {
    arm();
    wm_owns_input = true;
    defer {
        wm_owns_input = false;
        wm_fwd_prev_buttons = 0;
        wm_fwd_prev_x = 0;
        wm_fwd_prev_y = 0;
        term_sel_dragging = false;
    }
    wm_fwd_test_log_len = 0;
    klog.line_hook = wm_fwd_test_capture;
    defer klog.line_hook = null;
    const id = switch (user_open(64, 48, 640, 400, 9)) {
        .opened => |i| i,
        else => return error.TestUnexpectedResult,
    };
    defer _ = user_close(id);
    const h = terminal.create(null).?;
    defer terminal.release(h);
    defer terminal.detachWindow(id);
    try std.testing.expect(terminal.get(h).?.attachWindow(id));
    // Press at (68,70): inside the client area (top_y = 48+16 = 64) —
    // row 0, col 0. The seat-derived press edge must latch a drag...
    wm_content_pointer(68, 70, 0x01);
    try std.testing.expect(term_sel_dragging);
    // ...a held sample at (700,140) — row 4, col 79 — extends...
    wm_content_pointer(700, 140, 0x01);
    // ...and the release edge closes it, end marker printed.
    wm_content_pointer(700, 140, 0x00);
    try std.testing.expect(!term_sel_dragging);
    const cap = wm_fwd_test_log[0..wm_fwd_test_log_len];
    try std.testing.expect(std.mem.indexOf(u8, cap, "dui: term sel begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap, "dui: term sel end") != null);
}

test "wm content forward: dormant with no seat; chrome never begins selection (#1688)" {
    arm();
    wm_fwd_test_log_len = 0;
    klog.line_hook = wm_fwd_test_capture;
    defer klog.line_hook = null;
    const id = switch (user_open(64, 48, 640, 400, 9)) {
        .opened => |i| i,
        else => return error.TestUnexpectedResult,
    };
    defer _ = user_close(id);
    const h = terminal.create(null).?;
    defer terminal.release(h);
    defer terminal.detachWindow(id);
    try std.testing.expect(terminal.get(h).?.attachWindow(id));
    // (a) no seat: the identical drag is fully dormant — WMS5's state.
    wm_owns_input = false;
    wm_content_pointer(68, 70, 0x01);
    wm_content_pointer(700, 140, 0x01);
    wm_content_pointer(700, 140, 0x00);
    try std.testing.expect(!term_sel_dragging);
    // (b) seat on: chrome coordinates are never content — the title band
    // (terminalHitAt skips below top_y) and points outside the window.
    wm_owns_input = true;
    defer {
        wm_owns_input = false;
        wm_fwd_prev_buttons = 0;
        wm_fwd_prev_x = 0;
        wm_fwd_prev_y = 0;
        term_sel_dragging = false;
    }
    wm_content_pointer(100, 50, 0x01); // title band (48..63)
    wm_content_pointer(100, 50, 0x00);
    wm_content_pointer(10, 10, 0x01); // outside the window (dock corner)
    wm_content_pointer(10, 10, 0x00);
    try std.testing.expect(!term_sel_dragging);
    const cap = wm_fwd_test_log[0..wm_fwd_test_log_len];
    try std.testing.expect(std.mem.indexOf(u8, cap, "dui: term sel") == null);
}
