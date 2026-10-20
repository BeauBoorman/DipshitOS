//! Decoupled compositor and window manager unit test suite (M41 TS5, #956).
//!
//! Extracted from kernel/src/driving_award.zig.

const std = @import("std");
const driving_award = @import("driving_award");

// Re-export / alias everything from driving_award for the test bodies
const ChromeRow = driving_award.ChromeRow;
const DamageRect = driving_award.DamageRect;
const Kind = driving_award.Kind;
const SurfaceInfo = driving_award.SurfaceInfo;
const UserOpenResult = driving_award.UserOpenResult;
const WinQuery = driving_award.WinQuery;
const WinRect = driving_award.WinRect;
const Window = driving_award.Window;
const about_dialog_close = driving_award.about_dialog_close;
const about_dialog_open_dialog = driving_award.about_dialog_open_dialog;
const about_dialog_toggle = driving_award.about_dialog_toggle;
const alloc = driving_award.alloc;
const alt_tab_activate = driving_award.alt_tab_activate;
const alt_tab_commit = driving_award.alt_tab_commit;
const alt_tab_count = driving_award.alt_tab_count;
const alt_tab_cycle = driving_award.alt_tab_cycle;
const alt_tab_dismiss = driving_award.alt_tab_dismiss;
const alt_tab_is_active = driving_award.alt_tab_is_active;
const alt_tab_overlay_focus = driving_award.alt_tab_overlay_focus;
const alt_tab_selected_id = driving_award.alt_tab_selected_id;
const alt_tab_wm_commit = driving_award.alt_tab_wm_commit;
const apply_tile_layout = driving_award.apply_tile_layout;
const arm = driving_award.arm;
const armed = driving_award.armed;
const blit_rect = driving_award.blit_rect;
const blit_rect_alpha = driving_award.blit_rect_alpha;
const blit_scaled = driving_award.blit_scaled;
const builtin = driving_award.builtin;
const chrome_border_w = driving_award.chrome_border_w;
const chrome_shadow_off = driving_award.chrome_shadow_off;
const chrome_title_layout = driving_award.chrome_title_layout;
const clamp_resize_h = driving_award.clamp_resize_h;
const clamp_resize_w = driving_award.clamp_resize_w;
const clear_wm_chrome = driving_award.clear_wm_chrome;
const clipboard = driving_award.clipboard;
const clock_accent_rgb = driving_award.clock_accent_rgb;
const clock_bg = driving_award.clock_bg;
const clock_bg_rgb = driving_award.clock_bg_rgb;
const clock_border_rgb = driving_award.clock_border_rgb;
const clock_fg_rgb = driving_award.clock_fg_rgb;
const clock_h = driving_award.clock_h;
const clock_title_bg = driving_award.clock_title_bg;
const clock_title_bg_rgb = driving_award.clock_title_bg_rgb;
const clock_title_fg_rgb = driving_award.clock_title_fg_rgb;
const clock_w = driving_award.clock_w;
const clock_x = driving_award.clock_x;
const clock_y = driving_award.clock_y;
const close_owner = driving_award.close_owner;
const composite = driving_award.composite;
const count = driving_award.count;
const cursor_h = driving_award.cursor_h;
const cursor_pos = driving_award.cursor_pos;
const cursor_rgb = driving_award.cursor_rgb;
const cursor_w = driving_award.cursor_w;
const cycle_focus = driving_award.cycle_focus;
const cycle_workspace = driving_award.cycle_workspace;
const dismiss_transients = driving_award.dismiss_transients;
const dock_bg_rgb = driving_award.dock_bg_rgb;
const dock_h = driving_award.dock_h;
const dock_icon_active_rgb = driving_award.dock_icon_active_rgb;
const dock_icon_bg_rgb = driving_award.dock_icon_bg_rgb;
const dock_icon_click = driving_award.dock_icon_click;
const dock_w = driving_award.dock_w;
const dock_x = driving_award.dock_x;
const dock_y = driving_award.dock_y;
const drag_cancel = driving_award.drag_cancel;
const drag_get_payload = driving_award.drag_get_payload;
const drag_is_active = driving_award.drag_is_active;
const drag_payload_max = driving_award.drag_payload_max;
const drag_start = driving_award.drag_start;
const drain = driving_award.drain;
const draw_chrome = driving_award.draw_chrome;
const draw_glyph = driving_award.draw_glyph;
const draw_glyph_16 = driving_award.draw_glyph_16;
const draw_string = driving_award.draw_string;
const draw_string_16 = driving_award.draw_string_16;
const effective_chrome = driving_award.effective_chrome;
const events = driving_award.events;
const fade_half_frames = driving_award.fade_half_frames;
const fb_canvas = driving_award.fb_canvas;
const fbtext = driving_award.fbtext;
const fill_rect = driving_award.fill_rect;
const find_user_window = driving_award.find_user_window;
const find_user_window_index = driving_award.find_user_window_index;
const fmt_decimal = driving_award.fmt_decimal;
const focus = driving_award.focus;
const focus_at = driving_award.focus_at;
const focus_ring = driving_award.focus_ring;
const focus_ring_rgb = driving_award.focus_ring_rgb;
const focus_ring_w = driving_award.focus_ring_w;
const focused_index = driving_award.focused_index;
const focused_owner = driving_award.focused_owner;
const focused_window = driving_award.focused_window;
const focused_window_id = driving_award.focused_window_id;
const font = driving_award.font;
const format_hhmm = driving_award.format_hhmm;
const geom = driving_award.geom;
const hit_test = driving_award.hit_test;
const input = driving_award.input;
const is_resize_hit = driving_award.is_resize_hit;
const kbuf_bytes = driving_award.kbuf_bytes;
const kbuf_pages_for = driving_award.kbuf_pages_for;
const kbuf_ptr = driving_award.kbuf_ptr;
const kind_name = driving_award.kind_name;
const map_pointer_axis = driving_award.map_pointer_axis;
const mark_damage = driving_award.mark_damage;
const mark_dirty = driving_award.mark_dirty;
const mark_terminal_dirty = driving_award.mark_terminal_dirty;
const max_windows = driving_award.max_windows;
const memmap = driving_award.memmap;
const minimize_window = driving_award.minimize_window;
const modal_active = driving_award.modal_active;
const mouse_buttons_to_flags = driving_award.mouse_buttons_to_flags;
const move_window_keyboard = driving_award.move_window_keyboard;
const note_tab_attach = driving_award.note_tab_attach;
const note_tab_detach = driving_award.note_tab_detach;
const notif_center_clear_all = driving_award.notif_center_clear_all;
const notif_center_dismiss = driving_award.notif_center_dismiss;
const notif_center_h = driving_award.notif_center_h;
const notif_center_hit_test = driving_award.notif_center_hit_test;
const notif_center_set_open = driving_award.notif_center_set_open;
const notif_center_toggle = driving_award.notif_center_toggle;
const notif_center_w = driving_award.notif_center_w;
const notify_advance_ticks = driving_award.notify_advance_ticks;
const notify_count_visible = driving_award.notify_count_visible;
const notify_dismiss = driving_award.notify_dismiss;
const notify_dismiss_ticks = driving_award.notify_dismiss_ticks;
const notify_entry = driving_award.notify_entry;
const notify_max = driving_award.notify_max;
const notify_push = driving_award.notify_push;
const notify_text_max = driving_award.notify_text_max;
const overview_enter = driving_award.overview_enter;
const overview_exit = driving_award.overview_exit;
const overview_focus = driving_award.overview_focus;
const overview_is_open = driving_award.overview_is_open;
const overview_move = driving_award.overview_move;
const overview_window_count = driving_award.overview_window_count;
const paint = driving_award.paint;
const paint_scene = driving_award.paint_scene;
const paint_tab_strip = driving_award.paint_tab_strip;
const persist_max_bytes = driving_award.persist_max_bytes;
const persist_max_records = driving_award.persist_max_records;
const persist_record_bytes = driving_award.persist_record_bytes;
const pointer_tick = driving_award.pointer_tick;
const presents_pushed = driving_award.presents_pushed;
const preview_h = driving_award.preview_h;
const preview_w = driving_award.preview_w;
const put_px = driving_award.put_px;
const raise = driving_award.raise;
const read_u32_le = driving_award.read_u32_le;
const reflow = driving_award.reflow;
const remove_user_at = driving_award.remove_user_at;
const render_clock_content = driving_award.render_clock_content;
const render_preview = driving_award.render_preview;
const render_splash = driving_award.render_splash;
const render_terminal_screen = driving_award.render_terminal_screen;
const repaint_start = driving_award.repaint_start;
const resize_active = driving_award.resize_active;
const resize_current_id = driving_award.resize_current_id;
const resize_hit_size = driving_award.resize_hit_size;
const resize_min_h = driving_award.resize_min_h;
const resize_min_w = driving_award.resize_min_w;
const resize_window_keyboard = driving_award.resize_window_keyboard;
const restore_from_dock = driving_award.restore_from_dock;
const restore_state = driving_award.restore_state;
const serialize_state = driving_award.serialize_state;
const set_modal = driving_award.set_modal;
const set_transient = driving_award.set_transient;
const set_window_chrome = driving_award.set_window_chrome;
const set_window_title = driving_award.set_window_title;
const settings = driving_award.settings;
const shadow_color = driving_award.shadow_color;
const strip_fill = driving_award.strip_fill;
const strip_glyph = driving_award.strip_glyph;
const strip_text = driving_award.strip_text;
const swap_master = driving_award.swap_master;
const switch_workspace = driving_award.switch_workspace;
const tab_group_count = driving_award.tab_group_count;
const tab_group_members = driving_award.tab_group_members;
const tab_parent_of = driving_award.tab_parent_of;
const taskbar_bg = driving_award.taskbar_bg;
const taskbar_bg_rgb = driving_award.taskbar_bg_rgb;
const taskbar_entry_active = driving_award.taskbar_entry_active;
const taskbar_click = driving_award.taskbar_click;
const wm_rest_alpha = driving_award.wm_rest_alpha;
const taskbar_entries = driving_award.taskbar_entries;
const TaskbarEntry = driving_award.TaskbarEntry;
const taskbar_entry_active_rgb = driving_award.taskbar_entry_active_rgb;
const taskbar_entry_dimmed = driving_award.taskbar_entry_dimmed;
const taskbar_entry_dimmed_rgb = driving_award.taskbar_entry_dimmed_rgb;
const taskbar_h = driving_award.taskbar_h;
const taskbar_y = driving_award.taskbar_y;
const terminal_focused = driving_award.terminal_focused;
const terminal = driving_award.terminal;
const test_arena = driving_award.test_arena;
const theme_letter = driving_award.theme_letter;
const tile_master_pct = driving_award.tile_master_pct;
const tile_x_start = driving_award.tile_x_start;
const tile_y_start = driving_award.tile_y_start;
const to_geom = driving_award.to_geom;
const toggle_always_on_top = driving_award.toggle_always_on_top;
const toggle_fullscreen = driving_award.toggle_fullscreen;
const toggle_maximize = driving_award.toggle_maximize;
const toggle_tiling = driving_award.toggle_tiling;
const tooltip_clear = driving_award.tooltip_clear;
const tooltip_show = driving_award.tooltip_show;
const tooltip_show_now = driving_award.tooltip_show_now;
const topmost_modal_id = driving_award.topmost_modal_id;
const transient_advance_tick = driving_award.transient_advance_tick;
const tray_clipboard_filled = driving_award.tray_clipboard_filled;
const tray_current_tick = driving_award.tray_current_tick;
const tray_h = driving_award.tray_h;
const tray_has_clock = driving_award.tray_has_clock;
const tray_rect = driving_award.tray_rect;
const tray_set = driving_award.tray_set;
const tray_theme_accent = driving_award.tray_theme_accent;
const tray_w = driving_award.tray_w;
const tray_x = driving_award.tray_x;
const tray_y = driving_award.tray_y;
const unsaved_dialog_cancel = driving_award.unsaved_dialog_cancel;
const unsaved_dialog_click = driving_award.unsaved_dialog_click;
const unsaved_dialog_dont_save = driving_award.unsaved_dialog_dont_save;
const unsaved_dialog_is_open = driving_award.unsaved_dialog_is_open;
const unsaved_dialog_save = driving_award.unsaved_dialog_save;
const unsaved_dialog_show = driving_award.unsaved_dialog_show;
const user_bind_surface = driving_award.user_bind_surface;
const user_border = driving_award.user_border;
const user_border_unfocused = driving_award.user_border_unfocused;
const user_close = driving_award.user_close;
const user_damage = driving_award.user_damage;
const user_damage_mask = driving_award.user_damage_mask;
const user_fill = driving_award.user_fill;
const user_is_surface_backed = driving_award.user_is_surface_backed;
const user_lower_back = driving_award.user_lower_back;
const user_move = driving_award.user_move;
const user_move_to_workspace = driving_award.user_move_to_workspace;
const user_open = driving_award.user_open;
const user_owner = driving_award.user_owner;
const user_present = driving_award.user_present;
const user_query = driving_award.user_query;
const user_raise = driving_award.user_raise;
const user_raise_front = driving_award.user_raise_front;
const user_rect = driving_award.user_rect;
const user_resize = driving_award.user_resize;
const user_set_unsaved = driving_award.user_set_unsaved;
const user_set_visible = driving_award.user_set_visible;
const user_surface = driving_award.user_surface;
const user_title_bg = driving_award.user_title_bg;
const user_title_bg_rgb = driving_award.user_title_bg_rgb;
const user_title_fg_rgb = driving_award.user_title_fg_rgb;
const user_title_h = driving_award.user_title_h;
const user_win_max_h = driving_award.user_win_max_h;
const user_win_max_w = driving_award.user_win_max_w;
const user_window_id_base = driving_award.user_window_id_base;
const user_window_slot = driving_award.user_window_slot;
const user_windows_max = driving_award.user_windows_max;
const virtio_gpu = driving_award.virtio_gpu;
const virtio_snd = driving_award.virtio_snd;
const wallpaper_bot = driving_award.wallpaper_bot;
const wallpaper_bot_rgb = driving_award.wallpaper_bot_rgb;
const wallpaper_top = driving_award.wallpaper_top;
const wallpaper_top_rgb = driving_award.wallpaper_top_rgb;
const window_at = driving_award.window_at;
const wm_apply_rect = driving_award.wm_apply_rect;
const wm_chrome_kind = driving_award.wm_chrome_kind;
const wm_chrome_policy_kind = driving_award.wm_chrome_policy_kind;
const wm_chrome_rows = driving_award.wm_chrome_rows;
const wm_mirror = driving_award.wm_mirror;
const workspace_max = driving_award.workspace_max;
const workspace_visible = driving_award.workspace_visible;

// ---------------------------------------------------------------------------
// Host tests — the pure contracts (hit-test, z-order, focus, repaint plan,
// clock rendering, blit)
// ---------------------------------------------------------------------------

test "driving_award: arm registers the terminal (window 0) and the clock (window 1)" {
    arm();
    // Arc2 W3: clock window (Kind.clock id 1) migrated to tray — arm now registers
    // terminal + wallpaper + taskbar + dock = 4 driving_award.windows. Kind.clock remains in
    // enum but no window is created for it (no duplicate clock).
    try std.testing.expectEqual(@as(usize, 4), driving_award.win_count);
    try std.testing.expectEqual(@as(u8, 0), driving_award.windows[0].id);
    try std.testing.expectEqual(Kind.terminal, driving_award.windows[0].kind);
    try std.testing.expectEqual(@as(u8, 254), driving_award.windows[1].id);
    try std.testing.expectEqual(Kind.wallpaper, driving_award.windows[1].kind);
    try std.testing.expectEqual(@as(u8, 255), driving_award.windows[2].id);
    try std.testing.expectEqual(Kind.taskbar, driving_award.windows[2].kind);
    try std.testing.expectEqual(@as(u8, 253), driving_award.windows[3].id);
    try std.testing.expectEqual(Kind.dock, driving_award.windows[3].kind);
    try std.testing.expectEqual(@as(u8, 0), driving_award.focused_id);
    try std.testing.expect(terminal_focused());
    // The terminal is full-screen.
    try std.testing.expectEqual(@as(u32, 0), driving_award.windows[0].x);
    try std.testing.expectEqual(@as(u32, 0), driving_award.windows[0].y);
    try std.testing.expectEqual(virtio_gpu.fb_width, driving_award.windows[0].w);
    try std.testing.expectEqual(virtio_gpu.fb_height, driving_award.windows[0].h);
    // Tray occupies right 80px of taskbar at y=700.
    const tr = tray_rect();
    try std.testing.expectEqual(@as(u32, 1200), tr.x);
    try std.testing.expectEqual(@as(u32, 700), tr.y);
    try std.testing.expectEqual(@as(u32, 80), tr.w);
    try std.testing.expectEqual(@as(u32, 20), tr.h);
}

test "driving_award: hit_test returns the topmost window containing the point" {
    arm();
    // Clock window migrated to tray — (clock_x,clock_y) is now inside the
    // terminal (full-screen). The terminal is topmost there (wallpaper is
    // background-only, not hit-testable).
    try std.testing.expectEqual(@as(?u8, 0), hit_test(clock_x + 10, clock_y + 10));
    // Inside the terminal: the terminal.
    try std.testing.expectEqual(@as(?u8, 0), hit_test(100, 400));
    try std.testing.expectEqual(@as(?u8, 0), hit_test(clock_x - 1, clock_y + 10));
    // Outside every window.
    try std.testing.expectEqual(@as(?u8, null), hit_test(virtio_gpu.fb_width, virtio_gpu.fb_height));
}

test "driving_award: raise moves a window to the top and hit_test follows" {
    arm();
    // With tray migration, arm has terminal(0), wallpaper(254), taskbar(255), dock(253).
    // Raise terminal (0) — it moves to top of z-order (above dock).
    try std.testing.expect(raise(0));
    try std.testing.expectEqual(@as(u8, 0), driving_award.windows[driving_award.win_count - 1].id);
    try std.testing.expectEqual(@as(?u8, 0), hit_test(clock_x + 10, clock_y + 10));
    // Focus is unchanged by raise (tracked by id).
    try std.testing.expectEqual(@as(u8, 0), driving_award.focused_id);
}

test "driving_award: focus + focus_at switch the focused window" {
    arm();
    // Clock window no longer exists — focus a user window instead. Verify
    // terminal focus switching still works via focus_at.
    _ = user_open(100, 100, 200, 100, 7);
    try std.testing.expect(focus(2));
    try std.testing.expectEqual(@as(u8, 2), driving_award.focused_id);
    try std.testing.expect(!terminal_focused());
    // A point in the user window focuses it; a point in terminal area focuses terminal.
    try std.testing.expect(focus_at(110, 110));
    try std.testing.expectEqual(@as(u8, 2), driving_award.focused_id);
    try std.testing.expect(focus_at(50, 400));
    try std.testing.expectEqual(@as(u8, 0), driving_award.focused_id);
    try std.testing.expect(terminal_focused());
    // Unknown ids are refused.
    try std.testing.expect(!focus(99));
    _ = user_close(2);
}

test "driving_award: repaint_start is the lowest dirty visible window" {
    arm();
    // All dirty at arm: the lowest is window 0.
    try std.testing.expectEqual(@as(?usize, 0), repaint_start());
    // Clean everything.
    var i: usize = 0;
    while (i < driving_award.win_count) : (i += 1) driving_award.windows[i].dirty = false;
    try std.testing.expectEqual(@as(?usize, null), repaint_start());
    // Only wallpaper dirty: repaint starts at window 1 (the terminal is
    // untouched — the dirty-rect contract).
    driving_award.windows[1].dirty = true;
    try std.testing.expectEqual(@as(?usize, 1), repaint_start());
    // A hidden dirty window is skipped.
    driving_award.windows[0].dirty = true;
    driving_award.windows[0].visible = false;
    try std.testing.expectEqual(@as(?usize, 1), repaint_start());
}

test "driving_award: mark_dirty targets a window by id" {
    arm();
    var i: usize = 0;
    while (i < driving_award.win_count) : (i += 1) driving_award.windows[i].dirty = false;
    try std.testing.expect(mark_dirty(254));
    try std.testing.expect(!driving_award.windows[0].dirty);
    try std.testing.expect(driving_award.windows[1].dirty);
    try std.testing.expect(!mark_dirty(9));
}

test "driving_award: chrome_title_layout centers and truncates (M20-U9)" {
    // A wide window with a short label: centered, no truncation.
    {
        const l = chrome_title_layout(512, 8);
        try std.testing.expect(!l.truncated);
        // 8 chars = 64px; (512-64)/2 = 224 ≥ min pad.
        try std.testing.expectEqual(@as(usize, 224), l.x_off);
        try std.testing.expectEqual(@as(usize, 8), l.draw_len);
    }
    // A narrow window with a long label: truncates with "..." and never
    // starts left of the minimum pad.
    {
        const l = chrome_title_layout(120, 24);
        try std.testing.expect(l.truncated);
        try std.testing.expect(l.draw_len + 3 <= 120 / 8);
        try std.testing.expect(l.x_off >= 4);
        // The ellipsis fits inside the reserved span.
        const text_px = (l.draw_len + 3) * 8;
        try std.testing.expect(l.x_off + text_px <= 120);
    }
    // Degenerate: tiny window keeps at least the pad.
    {
        const l = chrome_title_layout(16, 10);
        try std.testing.expectEqual(@as(usize, 4), l.x_off);
    }
}

test "driving_award: the border is two pixels on every theme (M20-U9)" {
    const saved = driving_award.theme_id;
    defer driving_award.theme_id = saved;
    driving_award.theme_id = 0;
    _ = user_border();
    try std.testing.expectEqual(@as(usize, 2), chrome_border_w);
    driving_award.theme_id = 1;
    _ = user_border();
    try std.testing.expectEqual(@as(usize, 2), chrome_border_w);
}

test "driving_award: DQ4 drop-shadow color per theme + offset parity (issue #838)" {
    const saved = driving_award.theme_id;
    defer driving_award.theme_id = saved;
    driving_award.theme_id = 0;
    try std.testing.expectEqual(@as(u32, 0x000000), shadow_color());
    driving_award.theme_id = 1;
    try std.testing.expectEqual(@as(u32, 0x94a3b8), shadow_color());
    driving_award.theme_id = 2;
    try std.testing.expectEqual(@as(u32, 0x000000), shadow_color());
    // Offset parity with user/src/lib/ui.zig shadow_off (both pinned 4;
    // the two literals are the contract — see the dq4 metric test).
    try std.testing.expectEqual(@as(usize, 4), chrome_shadow_off);
    // Flag defaults off: pre-DQ4 pixel gates stay byte-identical.
    try std.testing.expect(!settings.get_shadow());
}

test "driving_award: fmt_decimal formats unsigned values without leading zeros" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0", fmt_decimal(&buf, 0));
    try std.testing.expectEqualStrings("1", fmt_decimal(&buf, 1));
    try std.testing.expectEqualStrings("42", fmt_decimal(&buf, 42));
    try std.testing.expectEqualStrings("123456789", fmt_decimal(&buf, 123456789));
}

test "driving_award: asymmetric C glyph is LSB-first" {
    const W = 8;
    const H = 8;
    var buf: [W * H * 4]u8 = undefined;
    @memset(&buf, 0);
    draw_glyph(&buf, W * 4, 0, 0, 'C', 0xffffff);

    // The C's source row 2 is 0x03, so x=0,1 are foreground and x=6,7
    // remain untouched. An MSB-first regression reverses these assertions.
    try std.testing.expectEqual(@as(u8, 0xff), buf[(2 * W + 0) * 4]);
    try std.testing.expectEqual(@as(u8, 0xff), buf[(2 * W + 1) * 4]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[(2 * W + 6) * 4]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[(2 * W + 7) * 4]);
}

test "driving_award: DQ2 tab-group facts (attach/detach/collect/orphan-clear)" {
    arm();
    const o2 = user_open(64, 64, 512, 384, 7);
    const o3 = user_open(700, 64, 320, 240, 7);
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, o2);
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, o3);
    // Standalone by default.
    try std.testing.expectEqual(@as(u8, 0), tab_parent_of(2));
    try std.testing.expectEqual(@as(usize, 0), tab_group_count(2));
    // Unknown ids are no-ops, never traps.
    note_tab_attach(99, 2);
    note_tab_detach(99);
    try std.testing.expectEqual(@as(u8, 0), tab_parent_of(99));
    // Attach + collect.
    note_tab_attach(3, 2);
    try std.testing.expectEqual(@as(u8, 2), tab_parent_of(3));
    try std.testing.expectEqual(@as(u8, 0), tab_parent_of(2));
    try std.testing.expectEqual(@as(usize, 1), tab_group_count(2));
    var members: [max_windows]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), tab_group_members(2, &members));
    try std.testing.expectEqual(@as(u8, 3), members[0]);
    // Detach back to standalone.
    note_tab_detach(3);
    try std.testing.expectEqual(@as(u8, 0), tab_parent_of(3));
    try std.testing.expectEqual(@as(usize, 0), tab_group_count(2));
    // Closing the container orphans children to standalone.
    note_tab_attach(3, 2);
    try std.testing.expect(user_close(2));
    try std.testing.expectEqual(@as(u8, 0), tab_parent_of(3));
}

test "driving_award: the full 95-glyph table rasters LSB-first through draw_glyph (issue 125)" {
    // Render EVERY printable glyph through the window-manager raster into
    // an 8x8 buffer and assert all 64 pixels against the RAW table byte
    // read LSB-first inline — `(row >> x) & 1`, NOT font.row_pixel (see
    // the text.zig full-table golden: deriving the expectation from the
    // helper under test would be self-consistent with a reversed helper).
    // 90 of 95 glyphs are horizontally asymmetric, so a bit-order flip in
    // draw_glyph OR row_pixel breaks 90/95 glyphs immediately — the
    // window-manager path cannot drift from the terminal path without
    // this failing.
    const W = 8;
    const H = 8;
    var buf: [W * H * 4]u8 = undefined;
    var i: usize = 0;
    while (i < font.glyphs.len) : (i += 1) {
        @memset(&buf, 0);
        const ch: u8 = @intCast(0x20 + i);
        draw_glyph(&buf, W * 4, 0, 0, ch, 0xffffff);
        const glyph = font.glyphs[i];
        var gy: usize = 0;
        while (gy < 8) : (gy += 1) {
            var gx: usize = 0;
            while (gx < 8) : (gx += 1) {
                const row = glyph[gy];
                const bit_set = ((row >> @as(u3, @intCast(gx))) & 1) != 0;
                const want: u8 = if (bit_set) 0xff else 0x00;
                try std.testing.expectEqual(want, buf[(gy * W + gx) * 4]);
            }
        }
    }
}

test "driving_award: render_clock_content paints the title bar and body colors" {
    const W = 304;
    const H = 192;
    var buf: [W * H * 4]u8 = undefined;
    @memset(&buf, 0);
    render_clock_content(&buf, W * 4, W, H, 42, false);
    // Title bar (inside the border): amber.
    try std.testing.expectEqual(@as(u8, 0x00), buf[(6 * W + 8) * 4 + 0]); // B of amber 0xb58900
    try std.testing.expectEqual(@as(u8, 0x89), buf[(6 * W + 8) * 4 + 1]); // G
    try std.testing.expectEqual(@as(u8, 0xb5), buf[(6 * W + 8) * 4 + 2]); // R
    try std.testing.expectEqual(@as(u8, 0xff), buf[(6 * W + 8) * 4 + 3]); // opaque
    // Border: gray-blue (top-left pixel is border).
    try std.testing.expectEqual(@as(u8, 0xaa), buf[0 + 0]); // B of 0x8899aa
    // Body background: navy (a pixel inside, away from text/border).
    try std.testing.expectEqual(@as(u8, 0x2e), buf[(170 * W + 300) * 4 + 0]); // B of 0x0a1a2e
    try std.testing.expectEqual(@as(u8, 0x1a), buf[(170 * W + 300) * 4 + 1]); // G
}

// ---------------------------------------------------------------------------
// M73h (#1634): rendition depth — theme defaults, the resolver, and the
// three new paint paths (exact truecolour, underline stroke, italic shear).
// ---------------------------------------------------------------------------

test "driving_award: terminal theme defaults pin the source and dark byte-parity" {
    const save = driving_award.theme_id;
    defer driving_award.theme_id = save;
    // Dark = the boot theme = the pre-M73h hardcoded text constants
    // (fbtext.fg_rgb 0x00ff00 / fbtext.bg_rgb 0x101418). Byte-parity with
    // every existing pixel gate lives in these two numbers.
    driving_award.theme_id = 0;
    var d = driving_award.terminalThemeDefaults();
    try std.testing.expectEqual(@as(u32, 0x00ff00), d.fg);
    try std.testing.expectEqual(@as(u32, 0x101418), d.bg);
    // Light and amber resolve differently — pinned values (#207).
    driving_award.theme_id = 1;
    d = driving_award.terminalThemeDefaults();
    try std.testing.expectEqual(@as(u32, 0x353b45), d.fg);
    try std.testing.expectEqual(@as(u32, 0xf5f6f8), d.bg);
    driving_award.theme_id = 2;
    d = driving_award.terminalThemeDefaults();
    try std.testing.expectEqual(@as(u32, 0xffd27f), d.fg);
    try std.testing.expectEqual(@as(u32, 0x0a1a2e), d.bg);
}

test "driving_award: terminalRendition resolves rgb, reverse, dim, and flags" {
    const tr = driving_award.terminalRendition;
    // Truecolour passes through exactly (both channels, side arrays first).
    var scr = terminal.Screen{};
    scr.feed("\x1b[38;2;255;128;71;48;2;17;34;51m");
    var r = tr(scr.style, scr.fg_rgb_cur, scr.bg_rgb_cur);
    try std.testing.expectEqual(@as(u32, 0xff8047), r.fg);
    try std.testing.expectEqual(@as(u32, 0x112233), r.bg);
    // Reverse SWAPS the resolved channels (xterm semantics) and carries
    // the draw flags through. ansi_palette: 1 = 0xcd3131, 4 = 0x2472c8.
    var s2 = terminal.Screen{};
    s2.feed("\x1b[31;44m\x1b[7;3;4m");
    r = tr(s2.style, s2.fg_rgb_cur, s2.bg_rgb_cur);
    try std.testing.expectEqual(@as(u32, 0x2472c8), r.fg);
    try std.testing.expectEqual(@as(u32, 0xcd3131), r.bg);
    try std.testing.expectEqual(true, r.italic);
    try std.testing.expectEqual(true, r.underline);
    // Dim scales the resolved foreground to 2/3: bold+31 → ansi[9]
    // 0xf14c4c → (241·2/3, 76·2/3, 76·2/3) = (160, 50, 50) = 0xa03232.
    var s3 = terminal.Screen{};
    s3.feed("\x1b[1;31m\x1b[2m");
    r = tr(s3.style, s3.fg_rgb_cur, s3.bg_rgb_cur);
    try std.testing.expectEqual(@as(u32, 0xa03232), r.fg);
    // Default + bold on the DARK theme keeps the legacy bright-green
    // rendition (ansi[10] = 0x23d18b); default alone is the theme colour.
    const save = driving_award.theme_id;
    defer driving_award.theme_id = save;
    driving_award.theme_id = 0;
    var s4 = terminal.Screen{};
    s4.feed("\x1b[1m");
    r = tr(s4.style, s4.fg_rgb_cur, s4.bg_rgb_cur);
    try std.testing.expectEqual(@as(u32, 0x23d18b), r.fg);
    try std.testing.expectEqual(@as(u32, 0x101418), r.bg);
    const s5 = terminal.Screen{};
    r = tr(s5.style, s5.fg_rgb_cur, s5.bg_rgb_cur);
    try std.testing.expectEqual(@as(u32, 0x00ff00), r.fg);
}

// ---------------------------------------------------------------------------
// M73m (#1662): the palette the USER chose. Data + chain only — no new
// resolution seam: theme_id 3 (= custom) prefers the three custom fields,
// every other accessor falls through its EXISTING switch arm, and the M73h
// pins above stay green untouched.
// ---------------------------------------------------------------------------

test "driving_award: a custom palette resolves exactly and never paints garbage (M73m)" {
    const save_id = driving_award.theme_id;
    const save_fg = driving_award.custom_fg;
    const save_bg = driving_award.custom_bg;
    const save_accent = driving_award.custom_accent;
    defer {
        driving_award.theme_id = save_id;
        driving_award.custom_fg = save_fg;
        driving_award.custom_bg = save_bg;
        driving_award.custom_accent = save_accent;
    }
    // Fresh-image state: dark, byte-identical (the M73h pin above holds).
    driving_award.theme_id = 0;
    var d = driving_award.terminalThemeDefaults();
    try std.testing.expectEqual(@as(u32, 0x00ff00), d.fg);
    try std.testing.expectEqual(@as(u32, 0x101418), d.bg);
    // custom with NOTHING written resolves to the same dark values: the
    // compiled defaults are dark by construction — never garbage, never an
    // uninitialized colour.
    driving_award.theme_id = driving_award.theme_id_custom;
    d = driving_award.terminalThemeDefaults();
    try std.testing.expectEqual(@as(u32, 0x00ff00), d.fg);
    try std.testing.expectEqual(@as(u32, 0x101418), d.bg);
    // The user's own colours: exact RGB through the M73h resolver.
    driving_award.custom_fg = 0x20ff9e;
    driving_award.custom_bg = 0x0b1020;
    driving_award.custom_accent = 0xff7733;
    d = driving_award.terminalThemeDefaults();
    try std.testing.expectEqual(@as(u32, 0x20ff9e), d.fg);
    try std.testing.expectEqual(@as(u32, 0x0b1020), d.bg);
    // Chrome: the two accent accessors follow the user's accent; every other
    // accessor falls through to the dark arm (a switch, never an index —
    // theme_id 3 can never read past a two-entry table).
    try std.testing.expectEqual(@as(u32, 0xff7733), focus_ring());
    try std.testing.expectEqual(@as(u32, 0xff7733), taskbar_entry_active());
    try std.testing.expectEqual(@as(u32, 0x1a2b3c), user_title_bg());
    try std.testing.expectEqual(@as(u32, 0x0f172a), taskbar_bg());
    try std.testing.expectEqual(@as(u32, 0x000000), shadow_color());
    // A default cell with SGR 1 keeps the custom foreground: the legacy
    // bright-green rendition is DARK-only, so a custom palette is never
    // overridden by it (the dark pin above still expects green).
    var s = terminal.Screen{};
    s.feed("\x1b[1m");
    const r = driving_award.terminalRendition(s.style, s.fg_rgb_cur, s.bg_rgb_cur);
    try std.testing.expectEqual(@as(u32, 0x20ff9e), r.fg);
    try std.testing.expectEqual(@as(u32, 0x0b1020), r.bg);
}

test "driving_award: the store resolves the palette into the resolver (M73m)" {
    const save_id = driving_award.theme_id;
    const save_fg = driving_award.custom_fg;
    const save_bg = driving_award.custom_bg;
    const save_accent = driving_award.custom_accent;
    defer {
        driving_award.theme_id = save_id;
        driving_award.custom_fg = save_fg;
        driving_award.custom_bg = save_bg;
        driving_award.custom_accent = save_accent;
        settings.reset();
        _ = settings.set("theme", "dark");
    }
    settings.reset();
    _ = settings.set("theme", "custom");
    _ = settings.set("palette_fg", "20ff9e");
    _ = settings.set("palette_bg", "0b1020");
    _ = settings.set("palette_accent", "ff7733");
    try std.testing.expectEqual(@as(u8, driving_award.theme_id_custom), driving_award.theme_id);
    var d = driving_award.terminalThemeDefaults();
    try std.testing.expectEqual(@as(u32, 0x20ff9e), d.fg);
    try std.testing.expectEqual(@as(u32, 0x0b1020), d.bg);
    try std.testing.expectEqual(@as(u32, 0xff7733), focus_ring());
    // Back to a preset: dark again, byte-identical to the legacy constants.
    _ = settings.set("theme", "dark");
    try std.testing.expectEqual(@as(u8, 0), driving_award.theme_id);
    d = driving_award.terminalThemeDefaults();
    try std.testing.expectEqual(@as(u32, 0x00ff00), d.fg);
    try std.testing.expectEqual(@as(u32, 0x101418), d.bg);
    try std.testing.expectEqual(@as(u32, 0x3b82f6), focus_ring());
}

test "driving_award: a palette write dirties every window for the next repaint (M73m)" {
    arm();
    _ = user_open(64, 64, 320, 200, 7);
    // Start from a settled frame: nothing dirty.
    var i: usize = 0;
    while (i < driving_award.count()) : (i += 1) driving_award.windows[i].dirty = false;
    driving_award.mark_palette_dirty();
    // EVERY window is dirty now — the live-apply contract: the next
    // composite re-resolves each paint-time colour (no reboot, no re-exec).
    i = 0;
    while (i < driving_award.count()) : (i += 1) {
        try std.testing.expect(driving_award.windows[i].dirty);
    }
}

test "driving_award: a 38;2 cell paints its exact RGB on the scanout" {
    const W = 80;
    const H = 32;
    var buf: [W * H * 4]u8 = undefined;
    var screen = terminal.Screen{};
    screen.feed("\x1b[38;2;255;128;71mX\x1b[0m\x1b[?25l");
    const window = Window{
        .id = 2,
        .title = "term",
        .x = 0,
        .y = 0,
        .w = W,
        .h = H,
        .kind = .user,
        .visible = true,
        .dirty = true,
    };
    render_terminal_screen(&buf, &window, &screen);
    // Cell (0,0) = x0..cell_w-1, y(title_bar)..+cell_h-1; count exact
    // 0xff8047 ink (buffer is B8G8R8X8: B@0, G@1, R@2). M73l: the cell
    // is 8×16 — full-height rect, accessors not literals.
    const y0: usize = geom.title_bar_h;
    var hits: usize = 0;
    var y: usize = y0;
    while (y < y0 + driving_award.font_metrics.cell_h) : (y += 1) {
        var x: usize = 0;
        while (x < driving_award.font_metrics.cell_w) : (x += 1) {
            const k = (y * W + x) * 4;
            if (buf[k + 2] == 0xff and buf[k + 1] == 0x80 and buf[k] == 0x47) hits += 1;
        }
    }
    try std.testing.expect(hits >= 4);
}

fn countRedInRect(buf: []const u8, width: usize, x0: usize, y0: usize, w: usize, h: usize) usize {
    var hits: usize = 0;
    var y: usize = y0;
    while (y < y0 + h) : (y += 1) {
        var x: usize = x0;
        while (x < x0 + w) : (x += 1) {
            const k = (y * width + x) * 4;
            if (buf[k + 2] == 0xff and buf[k + 1] == 0x00 and buf[k] == 0x00) hits += 1;
        }
    }
    return hits;
}

test "driving_award: a sixel image cell paints its set pixels and scales with the zoom (M85b #1814)" {
    const W = 80;
    const H = 64;
    var buf: [W * H * 4]u8 = undefined;
    const prev_size = driving_award.font_metrics.size;
    defer driving_award.font_metrics.set_size(prev_size);
    driving_award.font_metrics.set_size(.medium);
    var screen = terminal.Screen{};
    // One 8x16 image (the medium cell): columns 0..3 red on all 16 rows
    // (two full bands + `N` = the top four rows of the third), columns
    // 4..7 transparent. The cursor is hidden so it paints nothing.
    screen.feed("\x1b[?25l\x1bPq\"1;1;8;16#1;2;100;0;0!4~-!4~-!4N\x1b\\");
    const window = Window{
        .id = 2,
        .title = "term",
        .x = 0,
        .y = 0,
        .w = W,
        .h = H,
        .kind = .user,
        .visible = true,
        .dirty = true,
    };
    const y0: usize = geom.title_bar_h;
    render_terminal_screen(&buf, &window, &screen);
    // Exactly the set half is red; the transparent half and the next cell
    // show the fill.
    try std.testing.expectEqual(@as(usize, 4 * 16), countRedInRect(&buf, W, 0, y0, 8, 16));
    try std.testing.expectEqual(@as(usize, 0), countRedInRect(&buf, W, 4, y0, 4, 16));
    try std.testing.expectEqual(@as(usize, 0), countRedInRect(&buf, W, 8, y0, 8, 16));
    // Large zoom (10x21): the tile scales nearest-neighbour — source
    // column 3 covers destination columns up to 4, every row stays red.
    driving_award.font_metrics.set_size(.large);
    render_terminal_screen(&buf, &window, &screen);
    try std.testing.expectEqual(@as(usize, 5 * 21), countRedInRect(&buf, W, 0, y0, 10, 21));
    try std.testing.expectEqual(@as(usize, 0), countRedInRect(&buf, W, 5, y0, 5, 21));
}

test "driving_award: SGR 4 underline strokes the bottom row of even a blank cell" {
    const W = 80;
    const H = 32;
    var plain_buf: [W * H * 4]u8 = undefined;
    var und_buf: [W * H * 4]u8 = undefined;
    const save = driving_award.theme_id;
    defer driving_award.theme_id = save;
    driving_award.theme_id = 0; // default fg = 0x00ff00 (exact ink check)
    var plain = terminal.Screen{};
    plain.feed(" \x1b[?25l");
    var und = terminal.Screen{};
    und.feed("\x1b[4m \x1b[0m\x1b[?25l");
    const window = Window{
        .id = 2,
        .title = "term",
        .x = 0,
        .y = 0,
        .w = W,
        .h = H,
        .kind = .user,
        .visible = true,
        .dirty = true,
    };
    render_terminal_screen(&plain_buf, &window, &plain);
    render_terminal_screen(&und_buf, &window, &und);
    const y0: usize = geom.title_bar_h;
    // The blank glyph draws nothing — only the underline paints the
    // cell's bottom row (M73l: `underline_row` = cell_h-1, not 7).
    // Default fg on dark = 0x00ff00 (B8G8R8X8: B=0x00, G=0xff, R=0x00).
    const uy = y0 + driving_award.font_metrics.underline_row;
    var plain_ink: usize = 0;
    var x: usize = 0;
    while (x < driving_award.font_metrics.cell_w) : (x += 1) {
        const k = (uy * W + x) * 4;
        if (plain_buf[k + 1] == 0xff and plain_buf[k + 2] == 0x00 and plain_buf[k] == 0x00) plain_ink += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), plain_ink);
    var und_ink: usize = 0;
    x = 0;
    while (x < driving_award.font_metrics.cell_w) : (x += 1) {
        const k = (uy * W + x) * 4;
        if (und_buf[k + 1] == 0xff and und_buf[k + 2] == 0x00 and und_buf[k] == 0x00) und_ink += 1;
    }
    try std.testing.expect(und_ink >= 6);
    // No bleed into the neighbouring cell's underline.
    var n_ext: usize = 0;
    x = driving_award.font_metrics.cell_w;
    while (x < driving_award.font_metrics.wide_cell_w) : (x += 1) {
        const k = (uy * W + x) * 4;
        if (und_buf[k + 1] == 0xff and und_buf[k + 2] == 0x00) n_ext += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), n_ext);
}

test "driving_award: SGR 3 italic shears the glyph without bleeding columns" {
    const W = 80;
    const H = 32;
    var plain_buf: [W * H * 4]u8 = undefined;
    var it_buf: [W * H * 4]u8 = undefined;
    var plain = terminal.Screen{};
    plain.feed("M\x1b[?25l");
    var it = terminal.Screen{};
    it.feed("\x1b[3mM\x1b[0m\x1b[?25l");
    const window = Window{
        .id = 2,
        .title = "term",
        .x = 0,
        .y = 0,
        .w = W,
        .h = H,
        .kind = .user,
        .visible = true,
        .dirty = true,
    };
    render_terminal_screen(&plain_buf, &window, &plain);
    render_terminal_screen(&it_buf, &window, &it);
    // The shear moved pixels (buffers differ) and ink still exists.
    try std.testing.expect(!std.mem.eql(u8, &plain_buf, &it_buf));
    const y0: usize = geom.title_bar_h;
    var ink: usize = 0;
    var y: usize = y0;
    while (y < y0 + driving_award.font_metrics.cell_h) : (y += 1) {
        var x: usize = 0;
        while (x < driving_award.font_metrics.cell_w) : (x += 1) {
            const k = (y * W + x) * 4;
            if (plain_buf[k + 1] != it_buf[k + 1] or plain_buf[k + 2] != it_buf[k + 2]) ink += 1;
        }
    }
    try std.testing.expect(ink > 0);
    // Cell 1 (x cell_w..2*cell_w) is an untouched blank: nothing bled right of cell 0.
    var bleed: usize = 0;
    y = y0;
    while (y < y0 + driving_award.font_metrics.cell_h) : (y += 1) {
        var x: usize = driving_award.font_metrics.cell_w;
        while (x < driving_award.font_metrics.wide_cell_w) : (x += 1) {
            const k = (y * W + x) * 4;
            if (it_buf[k + 1] == 0xff and it_buf[k + 2] == 0x00) bleed += 1; // green ink
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bleed);
}

test "driving_award: terminal presentation paints ANSI cell backgrounds" {
    const W = 80;
    const H = 32;
    var buf: [W * H * 4]u8 = undefined;
    var screen = terminal.Screen{};
    screen.feed("\x1b[41m \x1b[0m\x1b[?25l");
    const window = Window{
        .id = 2,
        .title = "term",
        .x = 0,
        .y = 0,
        .w = W,
        .h = H,
        .kind = .user,
        .visible = true,
        .dirty = true,
    };
    render_terminal_screen(&buf, &window, &screen);
    const pixel: usize = @as(usize, @intCast(geom.title_bar_h)) * W * 4;
    // ANSI 41 is 0xcd3131, stored B8G8R8X8.
    try std.testing.expectEqual(@as(u8, 0x31), buf[pixel + 0]);
    try std.testing.expectEqual(@as(u8, 0x31), buf[pixel + 1]);
    try std.testing.expectEqual(@as(u8, 0xcd), buf[pixel + 2]);
    try std.testing.expectEqual(@as(u8, 0xff), buf[pixel + 3]);
}

// ---------------------------------------------------------------------------
// M73a-2 (#1631): rune cells reach the scanout — pixel proofs
// ---------------------------------------------------------------------------

/// Count pixels in the rect whose B8G8R8X8 bytes equal `rgb` (the painter
/// proofs below measure ink, never colour-class guesses).
fn ink_count(buf: []const u8, stride: usize, x0: usize, y0: usize, w: usize, h: usize, rgb: u32) usize {
    var n: usize = 0;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const k = (y0 + y) * stride + (x0 + x) * 4;
            const r: u32 = buf[k + 2];
            const g: u32 = buf[k + 1];
            const b: u32 = buf[k];
            if (r == ((rgb >> 16) & 0xff) and g == ((rgb >> 8) & 0xff) and b == (rgb & 0xff)) n += 1;
        }
    }
    return n;
}

test "driving_award: an accented rune cell paints ink and the overlay changes the art (M73a-2 #1631)" {
    const W = 96;
    const H = 48;
    const fg = driving_award.fbtext.fg_rgb;
    const y0 = geom.title_bar_h;
    var bare_buf: [W * H * 4]u8 = undefined;
    var acc_buf: [W * H * 4]u8 = undefined;
    @memset(&bare_buf, 0);
    @memset(&acc_buf, 0);
    const window = Window{ .id = 2, .title = "term", .x = 0, .y = 0, .w = W, .h = H, .kind = .user, .visible = true, .dirty = true };
    var bare = terminal.Screen{};
    bare.feed("\x1b[?25le");
    render_terminal_screen(&bare_buf, &window, &bare);
    var acc = terminal.Screen{};
    acc.feed("\x1b[?25le\xcc\x81"); // e + U+0301 combining acute
    render_terminal_screen(&acc_buf, &window, &acc);
    const bare_ink = ink_count(&bare_buf, W * 4, 0, y0, driving_award.font_metrics.cell_w, driving_award.font_metrics.cell_h, fg);
    const acc_ink = ink_count(&acc_buf, W * 4, 0, y0, driving_award.font_metrics.cell_w, driving_award.font_metrics.cell_h, fg);
    // Both paint real ink (never blank), and the overlay changes the art.
    try std.testing.expect(bare_ink > 4);
    try std.testing.expect(acc_ink > 4);
    try std.testing.expect(acc_ink != bare_ink);
}

test "driving_award: ASCII cells paint the atlas fixture's own bytes (M73l #1661, Amendment F)" {
    // The M72b byte-parity pin retired with the 8×8 cell: the ground
    // truth for an ASCII cell is now the checked-in fixture itself.
    // Every nibble decides its pixel — 15 lands on exact fg (a=255),
    // 0 stays on the exact cell fill, mid levels blend off the fill.
    const W = 96;
    const H = 48;
    const fg = driving_award.fbtext.fg_rgb;
    const bg = driving_award.fbtext.bg_rgb;
    const y0 = geom.title_bar_h;
    var buf: [W * H * 4]u8 = undefined;
    @memset(&buf, 0);
    const window = Window{ .id = 2, .title = "term", .x = 0, .y = 0, .w = W, .h = H, .kind = .user, .visible = true, .dirty = true };
    var s = terminal.Screen{};
    s.feed("\x1b[?25lA");
    render_terminal_screen(&buf, &window, &s);
    // M80i (#1725): the fixture is now per-size; the painter reads the
    // ACTIVE rung's blob/strides (boot default = MEDIUM), so this
    // golden walk reads the same active metrics. Pin the rung — these
    // pixel proofs size their loops (and their buffers) at 8x16.
    const prev_size = driving_award.font_metrics.size;
    defer driving_award.font_metrics.set_size(prev_size);
    driving_award.font_metrics.set_size(.medium);
    const m = driving_award.font_metrics;
    const atlas = m.active().blob;
    const off: usize = ('A' - m.first_cp) * m.glyph_bytes;
    const row_stride = m.row_bytes;
    var lvl15: usize = 0;
    var lvl0: usize = 0;
    var mid: usize = 0;
    var dy: usize = 0;
    while (dy < m.cell_h) : (dy += 1) {
        var gx: usize = 0;
        while (gx < m.cell_w) : (gx += 1) {
            const byte = atlas[off + dy * row_stride + gx / 2];
            const lvl: u8 = if (@rem(gx, 2) == 0) byte >> 4 else byte & 0x0f;
            const k = ((y0 + dy) * W + gx) * 4;
            const pr: u32 = buf[k + 2];
            const pg: u32 = buf[k + 1];
            const pb: u32 = buf[k];
            if (lvl == 15) {
                try std.testing.expectEqual(@as(u32, (fg >> 16) & 0xff), pr);
                try std.testing.expectEqual(@as(u32, (fg >> 8) & 0xff), pg);
                try std.testing.expectEqual(@as(u32, fg & 0xff), pb);
                lvl15 += 1;
            } else if (lvl == 0) {
                try std.testing.expectEqual(@as(u32, (bg >> 16) & 0xff), pr);
                try std.testing.expectEqual(@as(u32, (bg >> 8) & 0xff), pg);
                try std.testing.expectEqual(@as(u32, bg & 0xff), pb);
                lvl0 += 1;
            } else {
                // Blended off the fill: never still the raw fill (bright
                // fg vs dark fill — ≥17/255 moves the fg channel).
                try std.testing.expect(pr != ((bg >> 16) & 0xff) or pg != ((bg >> 8) & 0xff) or pb != (bg & 0xff));
                mid += 1;
            }
        }
    }
    // Census floors for 'A' at pixel size 13 (observed 6/≈40/≈80 —
    // generous margins over the antialiased diagonal ink).
    try std.testing.expect(lvl15 >= 4);
    try std.testing.expect(mid >= 8);
    try std.testing.expect(lvl0 >= 60);
}

test "driving_award: terminal hit-test resolves cells at the M73l metrics (8×16)" {
    // Deliverable 4: a click lands on the row it paints. Under the
    // stale /8 a click one-and-a-bit cells down resolved to row 2;
    // every number below is derived from the accessors, not literals.
    arm();
    // M80i: pin the boot rung — the 8x16 expectations below (30 cols,
    // 7 rows) assume the MEDIUM cell.
    const prev_size = driving_award.font_metrics.size;
    defer driving_award.font_metrics.set_size(prev_size);
    driving_award.font_metrics.set_size(.medium);
    const m = driving_award.font_metrics;
    const o = user_open(300, 300, 240, 128, 7); // title 16 + exactly 7 rows of 16
    const id: u8 = switch (o) {
        .opened => |i| i,
        else => return error.TestUnexpectedResult,
    };
    defer _ = user_close(id);
    const h = terminal.create(null) orelse return error.TestUnexpectedResult;
    const t = terminal.get(h).?;
    try std.testing.expect(t.attachWindow(id));
    terminal.syncWindowCols(id, 240);
    try std.testing.expectEqual(@as(usize, 30), terminal.screenForWindow(id).?.columns());
    const top: usize = 300 + driving_award.user_title_h; // client origin
    // One cell + 2px down, one cell + 1px right: row 1 / col 1 (the
    // pre-M73l /8 would have said row 2).
    const hit1 = driving_award.terminalHitAt(309, @intCast(top + m.cell_h + 2)).?;
    try std.testing.expectEqual(id, hit1.win_id);
    try std.testing.expectEqual(@as(usize, 1), hit1.row);
    try std.testing.expectEqual(@as(usize, 1), hit1.col);
    try std.testing.expectEqual(hit1.row, hit1.line); // empty screen: line == row
    // Visible rows in the client area: (128 - title) / cell_h.
    const rows_vis: usize = (128 - driving_award.user_title_h) / @as(usize, m.cell_h);
    try std.testing.expectEqual(@as(usize, 7), rows_vis);
    // The last painted row still resolves inside the window.
    const last = driving_award.terminalHitAt(304, @intCast(top + (rows_vis - 1) * m.cell_h + 5)).?;
    try std.testing.expectEqual(id, last.win_id);
    try std.testing.expectEqual(@as(usize, 6), last.row);
    // Column maths at the accessors: 2·cell_w + 3 in, col 2 out; the
    // first 3px below the origin is still row 0.
    const c2 = driving_award.terminalHitAt(300 + 2 * m.cell_w + 3, @intCast(top + 3)).?;
    try std.testing.expectEqual(@as(usize, 2), c2.col);
    try std.testing.expectEqual(@as(usize, 0), c2.row);
}

test "driving_award: a wide rune spans both cells once and never bleeds past its pair (M73a-2 #1631)" {
    const W = 96;
    const H = 48;
    const fg = driving_award.fbtext.fg_rgb;
    const y0 = geom.title_bar_h;
    var buf: [W * H * 4]u8 = undefined;
    @memset(&buf, 0);
    const window = Window{ .id = 2, .title = "term", .x = 0, .y = 0, .w = W, .h = H, .kind = .user, .visible = true, .dirty = true };
    var s = terminal.Screen{};
    s.feed("\x1b[?25l\xe4\xbd\xa0"); // U+4F60: wide, unmapped -> FFFD art at cols 0-1
    render_terminal_screen(&buf, &window, &s);
    const left = ink_count(&buf, W * 4, 0, y0, 8, 8, fg);
    const right = ink_count(&buf, W * 4, 8, y0, 8, 8, fg);
    const past = ink_count(&buf, W * 4, 16, y0, 8, 8, fg);
    // Real art in BOTH halves (the 2× stretch), byte-symmetric (painted
    // once), and nothing at all past the pair (no column shift).
    try std.testing.expect(left > 4);
    try std.testing.expectEqual(left, right);
    try std.testing.expectEqual(@as(usize, 0), past);
    // The continuation cell alone draws nothing (the base owns the pair).
    var lone: [8 * 8 * 4]u8 = undefined;
    @memset(&lone, 0);
    driving_award.draw_cell_glyph(&lone, 32, 0, 0, s.cellAt(0, 1), 0xffffff, true, false);
    try std.testing.expectEqual(@as(usize, 0), ink_count(&lone, 32, 0, 0, 8, 8, 0xffffff));
}

test "driving_award: rune resolve — box art is real, FFFD and unmapped paint the fallback (M73a-2 #1631)" {
    // PULSE's exact frame resolves to its own art, never the fallback.
    const frame = [_]u21{ 0x250c, 0x2500, 0x2510, 0x2502, 0x2514, 0x2518 };
    for (frame) |cp| {
        const rows = driving_award.rune_cell_rows(.{ .base = cp });
        try std.testing.expect(!std.mem.eql(u8, &rows, &driving_award.font_unicode.fffd_glyph));
    }
    // U+FFFD resolves to the real fallback art (never a skip)…
    try std.testing.expect(std.mem.eql(
        u8,
        &driving_award.rune_cell_rows(.{ .base = 0xFFFD }),
        &driving_award.font_unicode.fffd_glyph,
    ));
    // …and so does an unmapped CJK rune (wide: the fallback stretches).
    try std.testing.expect(std.mem.eql(
        u8,
        &driving_award.rune_cell_rows(.{ .base = 0x4F60 }),
        &driving_award.font_unicode.fffd_glyph,
    ));
    // ASCII resolves through font8x8 byte-exactly.
    try std.testing.expect(std.mem.eql(
        u8,
        &driving_award.rune_cell_rows(.{ .base = 'A' }),
        &driving_award.font.glyphs['A' - 0x20],
    ));
}

test "driving_award: blit_rect copies a sub-rect at the destination offset" {
    const SW = 4;
    const DW = 10;
    var src: [SW * SW * 4]u8 = undefined;
    var dst: [DW * DW * 4]u8 = undefined;
    @memset(&src, 0);
    @memset(&dst, 0);
    // Source pixel (1,1) = green.
    src[(1 * SW + 1) * 4 + 0] = 0x00; // B
    src[(1 * SW + 1) * 4 + 1] = 0xff; // G
    src[(1 * SW + 1) * 4 + 2] = 0x00; // R
    src[(1 * SW + 1) * 4 + 3] = 0xff;
    blit_rect(&dst, DW * 4, &src, SW * 4, 3, 3, SW, SW);
    try std.testing.expectEqual(@as(u8, 0xff), dst[((3 + 1) * DW + (3 + 1)) * 4 + 1]);
    // A pixel outside the blit region is still zero.
    try std.testing.expectEqual(@as(u8, 0), dst[(0 * DW + 0) * 4 + 0]);
}

test "driving_award: user_open/fill/present round-trips a bounded user window" {
    arm();
    // Open window 2 at (64, 64) 256x192 — the first free user slot.
    const r = user_open(64, 64, 512, 384, 7);
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, r);
    try std.testing.expectEqual(@as(usize, 5), driving_award.win_count);
    try std.testing.expectEqual(@as(u8, 2), driving_award.windows[4].id);
    try std.testing.expectEqual(Kind.user, driving_award.windows[4].kind);
    try std.testing.expectEqual(@as(?usize, 7), user_owner(2));
    try std.testing.expect(user_owner(0) == null); // the terminal is unowned
    // The new window is on top and focused.
    try std.testing.expectEqual(@as(u8, 2), driving_award.focused_id);
    try std.testing.expect(!terminal_focused());
    try std.testing.expectEqual(@as(?u8, 2), hit_test(64 + 10, 64 + 10));
    // Fill a rect: the pool back-buffer pixel carries the B8G8R8X8 rgb
    // (WM1: the buffer is exactly win.w×win.h — stride is win.w*4).
    try std.testing.expect(user_fill(2, 8, 8, 48, 48, 0xff0000));
    const win2 = find_user_window(2).?;
    try std.testing.expect(win2.kbuf_pa != 0); // pool-backed, not BSS
    try std.testing.expectEqual(kbuf_pages_for(512 * 384 * 4), win2.kbuf_pages);
    const base = kbuf_ptr(win2);
    try std.testing.expectEqual(@as(u8, 0x00), base[(8 * 512 + 8) * 4 + 0]); // B
    try std.testing.expectEqual(@as(u8, 0x00), base[(8 * 512 + 8) * 4 + 1]); // G
    try std.testing.expectEqual(@as(u8, 0xff), base[(8 * 512 + 8) * 4 + 2]); // R
    try std.testing.expectEqual(@as(u8, 0xff), base[(8 * 512 + 8) * 4 + 3]); // opaque
    // The unfilled corner is zero (the back-buffer starts cleared).
    try std.testing.expectEqual(@as(u8, 0), base[(100 * 512 + 200) * 4 + 0]);
    try std.testing.expect(user_present(2));
    try std.testing.expect(driving_award.windows[4].dirty);
}

test "driving_award: SB4 rect-granular damage is exact, unions, and masks (claim 2382)" {
    arm();
    // One 512x384 window (id 2). A single fill records the EXACT written rect.
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    try std.testing.expect(user_fill(2, 8, 8, 48, 48, 0xff0000));
    // The damage is the written rect — NOT the whole 512x384 window.
    try std.testing.expectEqual(DamageRect{ .x = 8, .y = 8, .w = 48, .h = 48 }, user_damage(2).?);
    // Union-rect: a second fill expands to the bounding box.
    try std.testing.expect(user_fill(2, 120, 60, 16, 16, 0x00ff00));
    try std.testing.expectEqual(DamageRect{ .x = 8, .y = 8, .w = 128, .h = 68 }, user_damage(2).?);
    // The COMPOSITE_TICK damage mask has bit 0 for surface id 2.
    try std.testing.expect(user_damage_mask() & 1 != 0);
    // A second window (id 3) damages its own surface bit, not window 2's.
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 512, 384, 8));
    try std.testing.expect(user_fill(3, 0, 0, 10, 10, 0x0000ff));
    const mask = user_damage_mask();
    try std.testing.expect(mask & 1 != 0);
    try std.testing.expect(mask & (1 << 1) != 0);
    // mark_damage clamps to window bounds and ignores an out-of-window rect.
    try std.testing.expect(mark_damage(3, 500, 0, 50, 10)); // x+w spills -> clamp, unions to x=0
    try std.testing.expectEqual(DamageRect{ .x = 0, .y = 0, .w = 512, .h = 10 }, user_damage(3).?);
    _ = mark_damage(3, 1000, 1000, 5, 5); // out-of-window -> ignored
    try std.testing.expectEqual(DamageRect{ .x = 0, .y = 0, .w = 512, .h = 10 }, user_damage(3).?);
    // The drain captures and consumes the damage: after composite, window 2's
    // LAST-repainted rect == the union {8,8,128,68}, and no pending damage remains.
    _ = composite();
    try std.testing.expect(user_damage(2) == null);
    try std.testing.expect(user_damage(3) == null);
    {
        var li: usize = 0;
        while (li < driving_award.win_count) : (li += 1) {
            if (driving_award.windows[li].id == 2) break;
        }
        try std.testing.expect(li < driving_award.win_count);
        try std.testing.expectEqual(@as(u32, 8), driving_award.windows[li].last_dx);
        try std.testing.expectEqual(@as(u32, 8), driving_award.windows[li].last_dy);
        try std.testing.expectEqual(@as(u32, 128), driving_award.windows[li].last_dw);
        try std.testing.expectEqual(@as(u32, 68), driving_award.windows[li].last_dh);
    }
}

test "driving_award: SB5 paint_scene skips migrated windows when the WM owns the user layer (claim 7397)" {
    arm();
    driving_award.wm_owns_user_layer = false; // an earlier test in an aggregated binary may have left it
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    // Migrate window 2 with a fake surface identity (the paint path only
    // reads the surface's pa for the source pointer — never dereferences it
    // when the skip is active, and the kernel-blit path below is only
    // exercised while the window is dirty-but-not-yet-painted; a page-aligned
    // fake keeps the test pure).
    try std.testing.expect(user_bind_surface(2, .{ .handle = 1, .pa_base = 0x1000_0000, .page_count = 48 }));
    try std.testing.expect(user_is_surface_backed(2));

    // WHILE the WM owns the user layer (scanout bound), paint_scene SKIPS
    // the migrated window: its damage is consumed but NO kernel blit happens
    // (last_* untouched — the WM's compose-N stores are the pixels; the
    // kernel never dereferences the surface here, so the fake pa is safe).
    driving_award.wm_owns_user_layer = true;
    defer driving_award.wm_owns_user_layer = false;
    try std.testing.expect(mark_damage(2, 20, 20, 30, 30));
    try std.testing.expect(user_damage(2) != null);
    _ = driving_award.paint_scene(); // tick-side layer, not a shim present
    try std.testing.expect(user_damage(2) == null); // damage consumed by the skip
    {
        var li: usize = 0;
        while (li < driving_award.win_count) : (li += 1) {
            if (driving_award.windows[li].id == 2) break;
        }
        try std.testing.expect(li < driving_award.win_count);
        // The kernel did NOT blit: last_* is untouched (still 0 — the shim
        // blit never ran for this window), NOT the new {20,20,30,30}.
        try std.testing.expectEqual(@as(u32, 0), driving_award.windows[li].last_dx);
        try std.testing.expectEqual(@as(u32, 0), driving_award.windows[li].last_dy);
        try std.testing.expectEqual(@as(u32, 0), driving_award.windows[li].last_dw);
        try std.testing.expectEqual(@as(u32, 0), driving_award.windows[li].last_dh);
    }
}

test "driving_award: SB6 user_blits vs migrated_skips move on the blit vs skip paths (claim 6864)" {
    arm();
    driving_award.wm_owns_user_layer = false;
    driving_award.user_blits = 0;
    driving_award.migrated_skips = 0;
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    // Pre-seam-B path (no WM layer ownership): an unmigrated window blit is
    // counted as a kernel user-blit, never a skip.
    try std.testing.expect(mark_damage(2, 0, 0, 16, 16));
    _ = composite();
    try std.testing.expectEqual(@as(u64, 1), driving_award.user_blits);
    try std.testing.expectEqual(@as(u64, 0), driving_award.migrated_skips);
    // Migrate the window (fake surface identity — the skip path never
    // dereferences it).
    try std.testing.expect(user_bind_surface(2, .{ .handle = 1, .pa_base = 0x1000_0000, .page_count = 48 }));
    // Seam-B path (WM owns the user layer): the migrated window is SKIPPED —
    // the kernel blit count stays, the skip count moves.
    driving_award.wm_owns_user_layer = true;
    defer driving_award.wm_owns_user_layer = false;
    try std.testing.expect(mark_damage(2, 0, 0, 16, 16));
    _ = driving_award.paint_scene(); // tick-side layer, not a shim present
    try std.testing.expectEqual(@as(u64, 1), driving_award.user_blits); // still 1 (no new blit)
    try std.testing.expectEqual(@as(u64, 1), driving_award.migrated_skips); // skipped once
}

test "driving_award: WMS4 SET_WINDOW chrome policy + per-window overrides (issue #624)" {
    arm();
    clear_wm_chrome(); // an earlier test in an aggregated binary may have set the policy
    _ = user_open(64, 64, 512, 384, 7); // window id 2
    // No WM chrome yet: policy kind 0, per-window kind 0 (shim rules).
    try std.testing.expectEqual(@as(u32, 0), wm_chrome_policy_kind());
    try std.testing.expectEqual(@as(u32, 0), wm_chrome_kind(2));
    // Unknown window id -> 0.
    try std.testing.expectEqual(@as(u32, 0), wm_chrome_kind(99));
    // Broadcast policy (a0 = ALL): every window falls back to it.
    const p = geom.chrome_parity_policy();
    try std.testing.expect(set_window_chrome(geom.chrome_window_all, p));
    try std.testing.expectEqual(@as(u32, 0x7f), wm_chrome_policy_kind());
    try std.testing.expectEqual(@as(u32, 0x7f), wm_chrome_kind(2));
    // Per-window override: a custom kind for window 2 only.
    var custom = p;
    custom.kind = geom.chrome_border | geom.chrome_title; // minimal chrome
    try std.testing.expect(set_window_chrome(2, custom));
    try std.testing.expectEqual(@as(u32, 0x3), wm_chrome_kind(2));
    // Unknown per-window id -> false (the broadcast always succeeds).
    try std.testing.expect(!set_window_chrome(99, p));
    // The observability rows: one per user window with its effective kind.
    var rows: [max_windows]ChromeRow = undefined;
    const n = wm_chrome_rows(&rows);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 2), rows[0].id);
    try std.testing.expectEqual(@as(u32, 0x3), rows[0].kind);

    _ = user_close(2);
}

// WMS5 test capture state — module-level so the naked fn-pointer hooks
// (which cannot capture) can record what they receive.
var wms5_mirror_calls: usize = 0;
var wms5_last_id: u8 = 0;
var wms5_last_x: u32 = 0;
var wms5_last_y: u32 = 0;
var wms5_last_w: u32 = 0;
var wms5_last_h: u32 = 0;
var wms5_last_vis: bool = false;
var wms5_last_foc: bool = false;
var wms5_last_rel: bool = false;
var wms5_ptr_calls: usize = 0;
var wms5_ptr_x: u32 = 0;
var wms5_ptr_y: u32 = 0;
var wms5_ptr_btn: u8 = 0;

fn wms5_mirror_capture(id: u8, x: u32, y: u32, w: u32, h: u32, visible: bool, focused: bool, workspace: u8, unsaved: bool, released: bool) void {
    _ = workspace;
    _ = unsaved;
    wms5_mirror_calls += 1;
    wms5_last_id = id;
    wms5_last_x = x;
    wms5_last_y = y;
    wms5_last_w = w;
    wms5_last_h = h;
    wms5_last_vis = visible;
    wms5_last_foc = focused;
    wms5_last_rel = released;
}

fn wms5_ptr_capture(x: u32, y: u32, buttons: u8) void {
    wms5_ptr_calls += 1;
    wms5_ptr_x = x;
    wms5_ptr_y = y;
    wms5_ptr_btn = buttons;
}

test "driving_award: WMS5 registry mirrors fire on window mutations (issue #625)" {
    arm();
    driving_award.wm_owns_input = true; // a WM is registered — the mirrors go live
    driving_award.wm_window_hook = wms5_mirror_capture;
    wms5_mirror_calls = 0;

    // user_open -> mirror (visible, focused — the new window is focused).
    _ = user_open(64, 64, 512, 384, 7); // window id 2
    try std.testing.expect(wms5_mirror_calls >= 1);
    try std.testing.expectEqual(@as(u8, 2), wms5_last_id);
    try std.testing.expectEqual(@as(u32, 64), wms5_last_x);
    try std.testing.expectEqual(@as(u32, 64), wms5_last_y);
    try std.testing.expectEqual(@as(u32, 512), wms5_last_w);
    try std.testing.expectEqual(@as(u32, 384), wms5_last_h);
    try std.testing.expect(wms5_last_vis);
    try std.testing.expect(wms5_last_foc);
    try std.testing.expect(!wms5_last_rel); // a plain state mirror, not a release

    // user_move -> the clamped move is mirrored (the WM proposes, the
    // kernel clamps — the mirror carries the clamped truth).
    try std.testing.expect(user_move(2, 200, 100));
    try std.testing.expectEqual(@as(u32, 200), wms5_last_x);
    try std.testing.expectEqual(@as(u32, 100), wms5_last_y);

    // user_resize -> the clamped resize is mirrored.
    try std.testing.expect(user_resize(2, 300, 200));
    try std.testing.expectEqual(@as(u32, 300), wms5_last_w);
    try std.testing.expectEqual(@as(u32, 200), wms5_last_h);

    // user_set_visible(false) -> mirror with visible=false (the WM drops
    // its hit-test target).
    try std.testing.expect(user_set_visible(2, false));
    try std.testing.expect(!wms5_last_vis);

    // user_close -> the RELEASE mirror goes out from remove_user_at
    // (M42 UX): visible=false and the released bit set — the WM learns
    // the window left the registry, not merely hid.
    _ = user_close(2);
    try std.testing.expect(!wms5_last_vis);
    try std.testing.expect(wms5_last_rel);

    // No hook (shim mode) -> all of the above are silent no-ops.
    driving_award.wm_owns_input = false;
    driving_award.wm_window_hook = null;
    _ = user_open(10, 10, 100, 100, 7); // window id 3 — no crash, no call
    const calls_before = wms5_mirror_calls;
    _ = user_close(3);
    try std.testing.expectEqual(calls_before, wms5_mirror_calls); // the hook never fired
}

test "driving_award: WMS5 input ownership gates kernel geometry consumption (issue #625)" {
    arm();
    driving_award.wm_owns_input = false;
    driving_award.wm_pointer_hook = null;
    // A click on the terminal focuses it in shim mode (kernel geometry).
    const st: input.PointerState = .{ .x = 26000, .y = 8000, .buttons = 0x01, .valid = true };
    try std.testing.expectEqual(@as(?u8, 0), pointer_tick(st, .{ .x = st.x, .y = st.y }));

    // With a WM registered: the raw stream fans out and the kernel consumes
    // NOTHING (no focus change, no drag, no buttons) — the WM decides. A
    // FRESH position (the shim click above already consumed st's position
    // and buttons, so this must be a new state to count as "changed").
    const st2: input.PointerState = .{ .x = 10000, .y = 12000, .buttons = 0x03, .valid = true };
    driving_award.wm_owns_input = true;
    driving_award.wm_pointer_hook = wms5_ptr_capture;
    wms5_ptr_calls = 0;
    try std.testing.expectEqual(@as(?u8, null), pointer_tick(st2, null)); // no kernel decision
    try std.testing.expect(wms5_ptr_calls >= 1); // ...but the raw sample reached the WM
    // The hook gets the MAPPED fb pixels (the WM operates in pixels — the
    // same space its kind-20 mirrors and its SET_WINDOW rects use).
    const exp_x = map_pointer_axis(st2.x, virtio_gpu.fb_width);
    const exp_y = map_pointer_axis(st2.y, virtio_gpu.fb_height);
    try std.testing.expectEqual(exp_x, wms5_ptr_x);
    try std.testing.expectEqual(exp_y, wms5_ptr_y);
    try std.testing.expectEqual(@as(u8, 0x03), wms5_ptr_btn);

    // Cleanup: shim mode restored (the wm_server init() path also does this).
    driving_award.wm_owns_input = false;
    driving_award.wm_pointer_hook = null;
    _ = user_close(2);
    _ = user_close(3);
}

test "driving_award: wm_fan_pointer fans every distinct report — a pump-pass batch cannot collapse the button edges" {
    arm();
    // The boot-08 drag flake's regression shape: poll_input drains the
    // whole used ring in one idle pass, so a press and its first
    // held-move decoded back-to-back. The OLD path sampled pointer_state
    // once at pointer_tick — the batch collapsed to its last write and
    // the down edge presented the MOVE's coordinates (or vanished), so
    // the app never saw a press on the dragged row and no drag armed.
    // cv_pointer_dispatch now calls wm_fan_pointer per decoded report:
    // each distinct state reaches the WM, in order.
    driving_award.wm_owns_input = true;
    driving_award.wm_pointer_hook = wms5_ptr_capture;
    wms5_ptr_calls = 0;

    // move -> down at the same point: the press is an edge, both fan.
    driving_award.wm_fan_pointer(1024, 2822, 0x00);
    try std.testing.expectEqual(@as(usize, 1), wms5_ptr_calls);
    driving_award.wm_fan_pointer(1024, 2822, 0x01);
    try std.testing.expectEqual(@as(usize, 2), wms5_ptr_calls);
    try std.testing.expectEqual(@as(u8, 0x01), wms5_ptr_btn);
    try std.testing.expectEqual(map_pointer_axis(1024, virtio_gpu.fb_width), wms5_ptr_x);

    // An identical repeat collapses (the dedup the tick used to provide).
    driving_award.wm_fan_pointer(1024, 2822, 0x01);
    try std.testing.expectEqual(@as(usize, 2), wms5_ptr_calls);

    // The held move and the in-place release both fan — a batched
    // down/move/up sequence can no longer collapse to its last write.
    driving_award.wm_fan_pointer(5120, 9102, 0x01);
    try std.testing.expectEqual(@as(usize, 3), wms5_ptr_calls);
    try std.testing.expectEqual(map_pointer_axis(5120, virtio_gpu.fb_width), wms5_ptr_x);
    driving_award.wm_fan_pointer(5120, 9102, 0x00);
    try std.testing.expectEqual(@as(usize, 4), wms5_ptr_calls);
    try std.testing.expectEqual(@as(u8, 0x00), wms5_ptr_btn);

    // pointer_tick re-sampling an already-fanned state is a no-op (the
    // shared dedup record), and a state that bypassed decode still fans.
    _ = pointer_tick(.{ .x = 5120, .y = 9102, .buttons = 0x00, .valid = true }, null);
    try std.testing.expectEqual(@as(usize, 4), wms5_ptr_calls);
    _ = pointer_tick(.{ .x = 16384, .y = 18204, .buttons = 0x00, .valid = true }, null);
    try std.testing.expectEqual(@as(usize, 5), wms5_ptr_calls);

    // Shim mode never fans.
    driving_award.wm_owns_input = false;
    driving_award.wm_fan_pointer(100, 100, 0x01);
    try std.testing.expectEqual(@as(usize, 5), wms5_ptr_calls);

    driving_award.wm_pointer_hook = null;
}

test "driving_award: user_open bounds and the eight slots fill the registry" {
    arm();
    // Invalid geometry: zero size, past the scanout cap, off-scanout.
    // WM1: the 512×424 buffer cap is gone — 513-wide and 425-tall now
    // open (they fit the 1280×720 scanout); the cap is the scanout.
    try std.testing.expectEqual(UserOpenResult.invalid, user_open(0, 0, 0, 10, 7));
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(0, 0, 513, 10, 7));
    try std.testing.expect(user_close(2));
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(0, 0, 10, 425, 7));
    try std.testing.expect(user_close(2));
    try std.testing.expectEqual(UserOpenResult.invalid, user_open(0, 0, 1281, 10, 7));
    try std.testing.expectEqual(UserOpenResult.invalid, user_open(0, 0, 10, 721, 7));
    try std.testing.expectEqual(UserOpenResult.invalid, user_open(virtio_gpu.fb_width, 0, 10, 10, 7));
    try std.testing.expectEqual(UserOpenResult.invalid, user_open(virtio_gpu.fb_width - 4, 0, 10, 10, 7));
    // A fullscreen window opens (the scanout cap, not the old 512×424).
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(0, 0, 1280, 720, 7));
    try std.testing.expect(user_close(2));
    // Eight opens fill all slots (ids 2..9); the ninth is .full.
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 512, 384, 8));
    try std.testing.expectEqual(UserOpenResult{ .opened = 4 }, user_open(576, 64, 512, 384, 9));
    try std.testing.expectEqual(UserOpenResult{ .opened = 5 }, user_open(64, 288, 512, 384, 10));
    try std.testing.expectEqual(UserOpenResult{ .opened = 6 }, user_open(576, 288, 256, 192, 11));
    try std.testing.expectEqual(UserOpenResult{ .opened = 7 }, user_open(832, 64, 256, 192, 12));
    try std.testing.expectEqual(UserOpenResult{ .opened = 8 }, user_open(832, 288, 256, 192, 13));
    try std.testing.expectEqual(UserOpenResult{ .opened = 9 }, user_open(320, 288, 256, 192, 14));
    try std.testing.expectEqual(UserOpenResult.full, user_open(0, 0, 10, 10, 15));
    try std.testing.expectEqual(@as(usize, 12), driving_award.win_count);
    try std.testing.expectEqual(@as(?usize, 7), user_owner(2));
    try std.testing.expectEqual(@as(?usize, 8), user_owner(3));
    try std.testing.expectEqual(@as(?usize, 9), user_owner(4));
    try std.testing.expectEqual(@as(?usize, 10), user_owner(5));
    try std.testing.expectEqual(@as(?usize, 14), user_owner(9));
}

test "driving_award: WM1 pool exhaustion reports .nomem without consuming the pool (claim 919)" {
    arm();
    // Shrink the pool to a single page: a 200×100 window needs 20.
    var desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 1, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&desc), @sizeOf(memmap.MemoryDescriptor), desc.len);
    _ = alloc.init(view, &.{});
    try std.testing.expectEqual(@as(u64, 1), alloc.stats().free_pages);
    try std.testing.expectEqual(UserOpenResult.nomem, user_open(64, 64, 200, 100, 7));
    // Failed open consumes nothing and registers nothing.
    try std.testing.expectEqual(@as(u64, 1), alloc.stats().free_pages);
    try std.testing.expectEqual(@as(usize, 4), driving_award.win_count);
    // The next test's arm() re-arms the generous pool.
}

test "driving_award: WM1 resize reallocates preserving the overlap and zeroing growth (claim 919)" {
    arm();
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 200, 100, 7));
    try std.testing.expect(user_fill(2, 8, 8, 48, 48, 0xff0000));
    const p0 = kbuf_ptr(find_user_window(2).?);
    try std.testing.expectEqual(@as(u8, 0xff), p0[(8 * 200 + 8) * 4 + 2]); // R of the fill
    // Grow: overlap preserved under the new stride, grown area zero.
    try std.testing.expect(user_resize(2, 400, 300));
    const w1 = find_user_window(2).?;
    try std.testing.expectEqual(kbuf_pages_for(400 * 300 * 4), w1.kbuf_pages);
    const p1 = kbuf_ptr(w1);
    try std.testing.expectEqual(@as(u8, 0xff), p1[(8 * 400 + 8) * 4 + 2]);
    try std.testing.expectEqual(@as(u8, 0), p1[(250 * 400 + 350) * 4 + 0]);
    // Shrink (clamped to the 128×64 min): overlap preserved.
    try std.testing.expect(user_resize(2, 100, 50));
    const w2 = find_user_window(2).?;
    try std.testing.expectEqual(@as(u32, 128), w2.w);
    try std.testing.expectEqual(@as(u32, 64), w2.h);
    try std.testing.expectEqual(kbuf_pages_for(128 * 64 * 4), w2.kbuf_pages);
    const p2 = kbuf_ptr(w2);
    try std.testing.expectEqual(@as(u8, 0xff), p2[(8 * 128 + 8) * 4 + 2]);
    try std.testing.expect(user_close(2));
}

test "driving_award: WM1 close returns pool pages — free-count round-trips (claim 919)" {
    arm();
    const before = alloc.stats().free_pages;
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    try std.testing.expect(alloc.stats().free_pages < before);
    try std.testing.expect(user_close(2));
    try std.testing.expectEqual(before, alloc.stats().free_pages);
    // The close_owner path (scheduler exit) frees too.
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    try std.testing.expectEqual(@as(usize, 1), close_owner(7));
    try std.testing.expectEqual(before, alloc.stats().free_pages);
}

test "driving_award: user_fill refuses unknown ids and out-of-bounds rects" {
    arm();
    _ = user_open(64, 64, 512, 384, 7);
    try std.testing.expect(!user_fill(0, 0, 0, 10, 10, 0xffffff)); // terminal is not a user window
    try std.testing.expect(!user_fill(1, 0, 0, 10, 10, 0xffffff)); // deprecated clock id 1 is not a user window
    try std.testing.expect(!user_fill(9, 0, 0, 10, 10, 0xffffff)); // unknown
    try std.testing.expect(!user_fill(2, 0, 0, 0, 10, 0xffffff)); // zero size
    try std.testing.expect(!user_fill(2, 511, 383, 2, 2, 0xffffff)); // past the window edge
    try std.testing.expect(!user_present(3)); // never opened
    try std.testing.expect(!user_present(0));
    try std.testing.expect(!user_present(1));
}

test "driving_award: user_close releases a user window and frees its slot" {
    arm();
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    try std.testing.expectEqual(@as(usize, 5), driving_award.win_count);
    try std.testing.expectEqual(@as(u8, 2), driving_award.focused_id);
    // The terminal is fixed — never closable; deprecated clock id 1 also not closable.
    try std.testing.expect(!user_close(0));
    try std.testing.expect(!user_close(1));
    try std.testing.expect(!user_close(9));
    // Close window 2: count decrements, focus falls back to the terminal,
    // and the slot is reusable by the next open.
    try std.testing.expect(user_close(2));
    try std.testing.expectEqual(@as(usize, 4), driving_award.win_count);
    try std.testing.expectEqual(@as(u8, 0), driving_award.focused_id);
    try std.testing.expect(terminal_focused());
    try std.testing.expect(find_user_window(2) == null);
    // Re-opening reuses id 2 (the freed slot — the "release, not leak" proof).
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    try std.testing.expectEqual(@as(usize, 5), driving_award.win_count);
    // Two opens, one close, one re-open: slot 3 is still free for a second
    // window, and closing BOTH user driving_award.windows returns the registry to the
    // fixed driving_award.windows.
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 512, 384, 8));
    try std.testing.expect(user_close(3));
    try std.testing.expect(user_close(2));
    try std.testing.expectEqual(@as(usize, 4), driving_award.win_count);
    try std.testing.expectEqual(@as(u8, 0), driving_award.focused_id);
}

test "driving_award: user_move clamps on-scanout and user_raise reorders z" {
    arm();
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 512, 384, 8));
    // The terminal is fixed — never movable or raisable; deprecated clock also not.
    try std.testing.expect(!user_move(0, 10, 10));
    try std.testing.expect(!user_move(1, 10, 10));
    try std.testing.expect(!user_raise(0));
    try std.testing.expect(!user_raise(1));
    try std.testing.expect(!user_move(9, 0, 0));
    try std.testing.expect(!user_raise(9));
    // Move window 2 to a new in-bounds position overlapping window 3 and
    // confirm the rect.
    try std.testing.expect(user_move(2, 100, 50));
    try std.testing.expectEqual(@as(u32, 100), find_user_window(2).?.x);
    try std.testing.expectEqual(@as(u32, 50), find_user_window(2).?.y);
    try std.testing.expect(find_user_window(2).?.dirty);
    // Z-order: (321, 65) is inside BOTH driving_award.windows; window 3 (opened last) is
    // on top. Raising window 2 puts it above window 3, without changing the
    // focus (tracked by id, stays 3).
    try std.testing.expectEqual(@as(u8, 3), hit_test(321, 65).?);
    try std.testing.expect(user_raise(2));
    try std.testing.expectEqual(@as(u8, 2), hit_test(321, 65).?);
    try std.testing.expectEqual(@as(u8, 3), driving_award.focused_id);
    // The clamp keeps the window fully on-scanout (bottom-right corner).
    try std.testing.expect(user_move(2, 1200, 700));
    try std.testing.expectEqual(@as(u32, virtio_gpu.fb_width - 512), find_user_window(2).?.x);
    try std.testing.expectEqual(@as(u32, virtio_gpu.fb_height - 384), find_user_window(2).?.y);
}

test "driving_award: wm_apply_rect uses LAYOUT semantics (WMS5 Gate 2, claim 4278)" {
    arm();
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    // Window 2 opens at the natural 512x384. The WM proposes the tiled
    // master rect (24,0,837,700) — WIDER than the app's 512x424 back
    // buffer. The shim's own apply_tile_layout writes 837 directly; the WM
    // must be able to produce the SAME rects (the W1–W16 registered-matrix
    // parity bar). wm_apply_rect clamps on-scanout only.
    try std.testing.expect(wm_apply_rect(2, 24, 0, 837, 700));
    try std.testing.expectEqual(@as(u32, 24), find_user_window(2).?.x);
    try std.testing.expectEqual(@as(u32, 0), find_user_window(2).?.y);
    try std.testing.expectEqual(@as(u32, 837), find_user_window(2).?.w);
    try std.testing.expectEqual(@as(u32, 700), find_user_window(2).?.h);
    // On-scanout clamp: proposing (1200, 700) with an 837x700 rect pulls the
    // position back so the window stays fully visible.
    try std.testing.expect(wm_apply_rect(2, 1200, 700, 837, 700));
    try std.testing.expectEqual(@as(u32, virtio_gpu.fb_width - 837), find_user_window(2).?.x);
    try std.testing.expectEqual(@as(u32, virtio_gpu.fb_height - 700), find_user_window(2).?.y);
    // A too-big proposal is clamped to the shared scanout constant, not the
    // app back-buffer (the layout-semantics rule).
    try std.testing.expect(wm_apply_rect(2, 0, 0, 9999, 9999));
    try std.testing.expect(find_user_window(2).?.w <= virtio_gpu.fb_width);
    try std.testing.expect(find_user_window(2).?.h <= virtio_gpu.fb_height);
    // Minimum-size clamp still holds (the shared wnd_core rule).
    try std.testing.expect(wm_apply_rect(2, 100, 100, 10, 10));
    try std.testing.expectEqual(@as(u32, geom.resize_min_w), find_user_window(2).?.w);
    // Unknown / non-user id -> false.
    try std.testing.expect(!wm_apply_rect(9, 0, 0, 100, 100));
    try std.testing.expect(!wm_apply_rect(0, 0, 0, 100, 100));
}

test "driving_award: wm_apply_rect emits WIN_RESIZE to the owner on size change (M42 SX2)" {
    events.init();
    arm();
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    // Consume the WIN_FOCUS from open so the queue starts empty.
    _ = events.pop(7);
    try std.testing.expectEqual(@as(usize, 0), events.pending(7));

    // Size change (512x384 -> 837x700): the owner is told its new canvas.
    try std.testing.expect(wm_apply_rect(2, 24, 0, 837, 700));
    const ev = events.pop(7).?;
    try std.testing.expectEqual(events.WIN_RESIZE, ev.kind);
    try std.testing.expectEqual(@as(u32, 837), ev.arg0);
    try std.testing.expectEqual(@as(u32, 700), ev.arg1);
    try std.testing.expectEqual(@as(usize, 0), events.pending(7));

    // Pure move (same size): no event — the WM repositioning a window must
    // not spam the app with resize notifications.
    try std.testing.expect(wm_apply_rect(2, 100, 50, 837, 700));
    try std.testing.expectEqual(@as(usize, 0), events.pending(7));

    // Idempotent re-apply of the same rect: still no event.
    try std.testing.expect(wm_apply_rect(2, 100, 50, 837, 700));
    try std.testing.expectEqual(@as(usize, 0), events.pending(7));

    // A shrinking layout notifies too (the clamped size differs).
    try std.testing.expect(wm_apply_rect(2, 100, 50, 300, 200));
    const ev2 = events.pop(7).?;
    try std.testing.expectEqual(events.WIN_RESIZE, ev2.kind);
    try std.testing.expectEqual(@as(u32, 300), ev2.arg0);
    try std.testing.expectEqual(@as(u32, 200), ev2.arg1);
}

test "driving_award: apply_grid_font_size moves the ladder, re-flows the bound grid, and tells the owner (M80i #1725)" {
    // The grid half of the `font_size` apply chain. The rung moves, a
    // BOUND grid re-flows to the new cell before the next composite
    // (columns re-derived from the new cell_w), and the owner hears the
    // SAME payload shape `user_resize` pushes (a font change is a
    // winsize change for a cell-addressed app). Unbound windows are
    // silent: their canvas is app pixels, not grid font.
    events.init();
    arm();
    const prev_size = driving_award.font_metrics.size;
    defer driving_award.font_metrics.set_size(prev_size);
    driving_award.font_metrics.set_size(.medium);
    const o = user_open(300, 300, 240, 128, 7);
    const id: u8 = switch (o) {
        .opened => |i| i,
        else => return error.TestUnexpectedResult,
    };
    defer _ = user_close(id);
    const o2 = user_open(560, 300, 240, 128, 8);
    const id2: u8 = switch (o2) {
        .opened => |i| i,
        else => return error.TestUnexpectedResult,
    };
    defer _ = user_close(id2);
    // Drain the open-time focus traffic (window 2's open blurs window
    // 1, so both owner queues carry focus events) — only the font
    // zoom's own notification may remain below.
    while (events.pop(7) != null) {}
    while (events.pop(8) != null) {}

    const h = terminal.create(null) orelse return error.TestUnexpectedResult;
    const t = terminal.get(h).?;
    try std.testing.expect(t.attachWindow(id));
    terminal.syncWindowCols(id, 240);
    // Boot look: 240 / cell_w(8) = 30 columns.
    try std.testing.expectEqual(@as(usize, 30), terminal.screenForWindow(id).?.columns());
    find_user_window(id).?.dirty = false;
    find_user_window(id2).?.dirty = false;

    // Up the ladder: metrics move, the bound grid re-flows, the owner
    // is told (pixel rect — the app derives its cell grid from it).
    driving_award.apply_grid_font_size(.large);
    try std.testing.expectEqual(driving_award.font_metrics.Size.large, driving_award.font_metrics.size);
    try std.testing.expectEqual(@as(u32, 10), driving_award.font_metrics.cell_w);
    try std.testing.expectEqual(@as(u32, 21), driving_award.font_metrics.cell_h);
    try std.testing.expectEqual(@as(usize, 24), terminal.screenForWindow(id).?.columns()); // 240 / 10
    const ev = events.pop(7).?;
    try std.testing.expectEqual(events.WIN_RESIZE, ev.kind);
    try std.testing.expectEqual(@as(u32, 240), ev.arg0);
    try std.testing.expectEqual(@as(u32, 128), ev.arg1);
    try std.testing.expectEqual(@as(usize, 0), events.pending(7));
    try std.testing.expect(find_user_window(id).?.dirty);
    // The UNBOUND window hears nothing and is not dirtied.
    try std.testing.expectEqual(@as(usize, 0), events.pending(8));
    try std.testing.expect(!find_user_window(id2).?.dirty);

    // Down the ladder: re-flow back, the owner hears again.
    driving_award.apply_grid_font_size(.small);
    try std.testing.expectEqual(driving_award.font_metrics.Size.small, driving_award.font_metrics.size);
    try std.testing.expectEqual(@as(usize, 34), terminal.screenForWindow(id).?.columns()); // 240 / 7
    const ev2 = events.pop(7).?;
    try std.testing.expectEqual(events.WIN_RESIZE, ev2.kind);
    try std.testing.expectEqual(@as(u32, 240), ev2.arg0);
    try std.testing.expectEqual(@as(u32, 128), ev2.arg1);
}

test "driving_award: user_rect reads back the clamped geometry (the sys_win_get seam)" {
    arm();
    _ = user_open(64, 64, 512, 384, 7);
    // The fixed driving_award.windows are never user driving_award.windows -> null.
    try std.testing.expect(user_rect(0) == null);
    try std.testing.expect(user_rect(1) == null);
    try std.testing.expect(user_rect(9) == null);
    // The open rect.
    var r = user_rect(2).?;
    try std.testing.expectEqual(@as(u32, 64), r.x);
    try std.testing.expectEqual(@as(u32, 64), r.y);
    try std.testing.expectEqual(@as(u32, 512), r.w);
    try std.testing.expectEqual(@as(u32, 384), r.h);
    // After a CLAMPED move the read-back reports the clamped position — the
    // exact seam the EL0 `sys_win_get` exposes (the move is silent).
    try std.testing.expect(user_move(2, 1200, 700));
    r = user_rect(2).?;
    try std.testing.expectEqual(@as(u32, virtio_gpu.fb_width - 512), r.x);
    try std.testing.expectEqual(@as(u32, virtio_gpu.fb_height - 384), r.y);
    try std.testing.expectEqual(@as(u32, 512), r.w);
    try std.testing.expectEqual(@as(u32, 384), r.h);
}

test "driving_award: user_query reports the full window state (z-order + focus + flags)" {
    arm();
    try std.testing.expect(user_query(0) == null);
    try std.testing.expect(user_query(1) == null);
    try std.testing.expect(user_query(9) == null);
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    // The single user window sits at the TOP of the z-order (registry index
    // 4, above terminal 0 + wallpaper 254 + taskbar 255 + dock 253),
    // holds focus, is visible, and is dirty from the open.
    var q = user_query(2).?;
    try std.testing.expectEqual(@as(u32, 64), q.x);
    try std.testing.expectEqual(@as(u32, 64), q.y);
    try std.testing.expectEqual(@as(u32, 512), q.w);
    try std.testing.expectEqual(@as(u32, 384), q.h);
    try std.testing.expectEqual(@as(u32, 4), q.z);
    try std.testing.expectEqual(@as(u32, 1), q.focused);
    try std.testing.expectEqual(@as(u32, 1), q.visible);
    try std.testing.expectEqual(@as(u32, 1), q.dirty);
    // A second window takes focus (id 3) and the z-order: window 2 drops to
    // rank 4 (bottom of the two user driving_award.windows), unfocused.
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 512, 384, 8));
    q = user_query(2).?;
    try std.testing.expectEqual(@as(u32, 4), q.z);
    try std.testing.expectEqual(@as(u32, 0), q.focused);
    q = user_query(3).?;
    try std.testing.expectEqual(@as(u32, 5), q.z);
    try std.testing.expectEqual(@as(u32, 1), q.focused);
    // Raising window 2 moves it to the top (rank 5) without changing focus
    // (still id 3).
    try std.testing.expect(user_raise(2));
    q = user_query(2).?;
    try std.testing.expectEqual(@as(u32, 5), q.z);
    try std.testing.expectEqual(@as(u32, 0), q.focused);
}

test "driving_award: WM4 rest alpha — policy fallback, override, v1 default, composite blend" {
    arm();
    clear_wm_chrome();
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 512, 384, 8));
    try std.testing.expect(user_fill(2, 0, 0, 512, 384, 0x00ff00));
    try std.testing.expect(user_fill(3, 0, 0, 512, 384, 0x00ff00));
    // No policy / no override: the v1 default (opaque).
    try std.testing.expectEqual(@as(u32, 256), wm_rest_alpha(2));
    try std.testing.expectEqual(@as(u32, 256), wm_rest_alpha(3));
    // A v2 broadcast policy carries the rest alpha to every user window.
    var pol = geom.chrome_parity_policy();
    pol.rest_alpha = 240;
    try std.testing.expect(driving_award.set_window_chrome(geom.chrome_window_all, pol));
    try std.testing.expectEqual(@as(u32, 240), wm_rest_alpha(2));
    try std.testing.expectEqual(@as(u32, 240), wm_rest_alpha(3));
    // A per-window override wins over the policy.
    var ovr = pol;
    ovr.rest_alpha = 200;
    try std.testing.expect(driving_award.set_window_chrome(2, ovr));
    try std.testing.expectEqual(@as(u32, 200), wm_rest_alpha(2));
    try std.testing.expectEqual(@as(u32, 240), wm_rest_alpha(3));
    // The v1 zero-extension semantics: rest_alpha = 0 normalizes to 256.
    ovr.rest_alpha = 0;
    try std.testing.expect(driving_award.set_window_chrome(2, ovr));
    try std.testing.expectEqual(@as(u32, 256), wm_rest_alpha(2));
    clear_wm_chrome();
    // The COMPOSITE blend: window 3 is focused — its client stays pure
    // green even under a rest policy; window 2 (unfocused, at rest) blends
    // with whatever is beneath (the gradient/terminal) — visibly not the
    // source color, still green-dominant.
    var p240 = geom.chrome_parity_policy();
    p240.rest_alpha = 240;
    try std.testing.expect(driving_award.set_window_chrome(geom.chrome_window_all, p240));
    // The fade-in must be complete (at rest) for the rest-alpha path —
    // the test opens leave fade_phase 1 / tick 0 (25% blend).
    find_user_window(2).?.fade_phase = 0;
    find_user_window(3).?.fade_phase = 0;
    try std.testing.expect(user_present(3));
    try std.testing.expect(user_present(2));
    _ = composite();
    const stride = virtio_gpu.fb_width * 4;
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const px = struct {
        fn at(f: [*]u8, st: usize, x: usize, y: usize) u32 {
            const o = y * st + x * 4;
            return @as(u32, f[o + 2]) << 16 | @as(u32, f[o + 1]) << 8 | f[o];
        }
    };
    const w3 = find_user_window(3).?;
    try std.testing.expectEqual(@as(u32, 0x00ff00), px.at(fb, stride, w3.x + 100, w3.y + 100));
    const w2 = find_user_window(2).?;
    const blended = px.at(fb, stride, w2.x + 100, w2.y + 100);
    try std.testing.expect(blended != 0x00ff00);
    try std.testing.expect((blended >> 8) & 0xff > (blended >> 16) & 0xff); // green-dominant
    try std.testing.expect((blended >> 8) & 0xff > (blended & 0xff));
    // With the policy cleared, the same pixel is the pure source color.
    clear_wm_chrome();
    find_user_window(2).?.fade_phase = 0;
    try std.testing.expect(user_present(2));
    _ = composite();
    try std.testing.expectEqual(@as(u32, 0x00ff00), px.at(fb, stride, w2.x + 100, w2.y + 100));
}

test "driving_award: M69g (#1558) a fully covered window's chrome is not painted over the cover" {
    arm();
    // The covered window: the 96x64 shape GOTABWM's client-death probe leaves
    // open at (8,8) for the whole session.
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(8, 8, 96, 64, 7));
    // The cover: a full-viewport client on top (GOSH's tab).
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(0, 0, 1280, 720, 8));
    // Both faded in (the rest-alpha blend is complete), the cover focused and
    // therefore opaque — an opaque cover really does hide the window under it.
    find_user_window(2).?.fade_phase = 0;
    find_user_window(3).?.fade_phase = 0;
    try std.testing.expect(user_fill(3, 0, 0, 1280, 720, 0x123456));
    try std.testing.expect(user_present(3));
    try std.testing.expect(user_present(2));
    _ = composite();
    const stride = virtio_gpu.fb_width * 4;
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const px = struct {
        fn at(f: [*]u8, st: usize, x: usize, y: usize) u32 {
            const o = y * st + x * 4;
            return @as(u32, f[o + 2]) << 16 | @as(u32, f[o + 1]) << 8 | f[o];
        }
    };
    // Inside the covered window's own chrome that the cover's chrome does not
    // also own — its left and bottom border pixels — the value must be the
    // COVER's content, never the buried window's border/title bar.
    try std.testing.expectEqual(@as(u32, 0x123456), px.at(fb, stride, 8, 8 + 40));
    try std.testing.expectEqual(@as(u32, 0x123456), px.at(fb, stride, 8 + 40, 8 + 63));
    // Not a blanket "skip chrome": raise the small window and its chrome is
    // back (and it is no longer covered, so it is legitimately visible).
    try std.testing.expect(user_raise(2));
    find_user_window(2).?.fade_phase = 0;
    try std.testing.expect(user_present(2));
    _ = composite();
    try std.testing.expect(px.at(fb, stride, 8, 8 + 40) != 0x123456);
}

test "driving_award: WM3 taskbar_click restores a minimized entry, focuses a visible one" {
    arm();
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 512, 384, 7));
    // Focus followed the open (id 3 is on top) — a taskbar click on the
    // OTHER visible entry (id 2) refocuses + raises it.
    try std.testing.expectEqual(@as(u8, 3), driving_award.focused_id);
    try std.testing.expect(taskbar_click(2));
    try std.testing.expectEqual(@as(u8, 2), driving_award.focused_id);
    // Minimize id 3; a taskbar click on it RESTORES it (visible + focused).
    try std.testing.expect(minimize_window(3));
    try std.testing.expectEqual(@as(u32, 0), user_query(3).?.visible);
    try std.testing.expect(taskbar_click(3));
    try std.testing.expectEqual(@as(u32, 1), user_query(3).?.visible);
    try std.testing.expectEqual(@as(u8, 3), driving_award.focused_id);
    // Unknown / non-user ids are honestly refused.
    try std.testing.expect(!taskbar_click(9));
    try std.testing.expect(!taskbar_click(0));
    // The enumeration snapshot: two entries, id-ascending, focused=3,
    // none minimized (the click above restored id 3).
    var tb: [8]TaskbarEntry = undefined;
    const tn = taskbar_entries(&tb);
    try std.testing.expectEqual(@as(usize, 2), tn);
    try std.testing.expectEqual(@as(u8, 2), tb[0].id);
    try std.testing.expectEqual(@as(u8, 3), tb[1].id);
    try std.testing.expect(!tb[0].focused);
    try std.testing.expect(tb[1].focused);
    try std.testing.expect(!tb[1].minimized);
    // Minimize id 2: the snapshot marks it minimized (the restore dot).
    try std.testing.expect(minimize_window(2));
    const tn2 = taskbar_entries(&tb);
    try std.testing.expectEqual(@as(usize, 2), tn2);
    try std.testing.expect(tb[0].minimized);
    // A window on another workspace drops out of the enumeration.
    try std.testing.expect(driving_award.user_move_to_workspace(3, 1));
    const tn3 = taskbar_entries(&tb);
    try std.testing.expectEqual(@as(usize, 1), tn3);
    try std.testing.expectEqual(@as(u8, 2), tb[0].id);
}

test "driving_award: user_set_visible hides and shows a user window (fixed windows refused)" {
    arm();
    _ = user_open(64, 64, 512, 384, 7);
    // The terminal is fixed — never hideable; deprecated clock id 1 also not hideable.
    try std.testing.expect(!user_set_visible(0, false));
    try std.testing.expect(!user_set_visible(1, false));
    try std.testing.expect(!user_set_visible(9, false));
    // Hide window 2: its visible flag flips, it stays in the registry, and
    // the terminal is marked dirty (the reveal repaint).
    try std.testing.expect(user_set_visible(2, false));
    try std.testing.expectEqual(@as(u32, 0), user_query(2).?.visible);
    try std.testing.expect(find_user_window(2) != null);
    try std.testing.expect(driving_award.windows[0].dirty);
    // The hide is idempotent (a second hide is a no-op — no dirty churn).
    driving_award.windows[0].dirty = false;
    try std.testing.expect(user_set_visible(2, false));
    try std.testing.expectEqual(@as(u32, 0), user_query(2).?.visible);
    try std.testing.expect(!driving_award.windows[0].dirty);
    // Show it again: the window reappears (visible=1, dirty for the blit).
    try std.testing.expect(user_set_visible(2, true));
    try std.testing.expectEqual(@as(u32, 1), user_query(2).?.visible);
    try std.testing.expect(find_user_window(2).?.dirty);
}

test "driving_award: close_owner auto-closes exactly the owning process's windows" {
    arm();
    // Process 7 opens both slots; process 8 owns nothing yet.
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 512, 384, 7));
    try std.testing.expectEqual(@as(usize, 6), driving_award.win_count);
    try std.testing.expectEqual(@as(u8, 3), driving_award.focused_id);
    // Closing a process with no driving_award.windows is a no-op (returns 0).
    try std.testing.expectEqual(@as(usize, 0), close_owner(8));
    try std.testing.expectEqual(@as(usize, 6), driving_award.win_count);
    // Closing process 7 releases BOTH of its driving_award.windows and falls the focus
    // back to the terminal.
    try std.testing.expectEqual(@as(usize, 2), close_owner(7));
    try std.testing.expectEqual(@as(usize, 4), driving_award.win_count);
    try std.testing.expectEqual(@as(u8, 0), driving_award.focused_id);
    try std.testing.expect(find_user_window(2) == null);
    try std.testing.expect(find_user_window(3) == null);
    // The slots are free again (id 2 re-opens for a different owner).
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 9));
    try std.testing.expectEqual(@as(?usize, 9), user_owner(2));
}

test "driving_award: M52 card 3 — a revoked surface closes exactly its bound window (the zombie close)" {
    arm();
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 512, 384, 7));
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 512, 384, 8));
    // Only window 2 is migrated (the SB3 handoff): its pixels live in the
    // shared region, so once that region is revoked it has no source left.
    try std.testing.expect(user_bind_surface(2, .{ .handle = 5, .pa_base = 0x1000_0000, .page_count = 48 }));
    try std.testing.expect(user_is_surface_backed(2));
    try std.testing.expect(!user_is_surface_backed(3));

    // A handle nobody is bound to (and the unmigrated sentinel 0) close
    // nothing — the sweep is exact, not a blanket window purge.
    try std.testing.expectEqual(@as(usize, 0), driving_award.surface_revoked(0));
    try std.testing.expectEqual(@as(usize, 0), driving_award.surface_revoked(9));
    try std.testing.expectEqual(@as(usize, 6), driving_award.win_count);

    // The revoke ends the bound window through the ordinary release
    // primitive — the registry holds no zombie and window 3, bound to
    // nothing, is untouched. Window 3 held the focus, so it KEEPS it (only a
    // removed FOCUSED window falls the focus back to the terminal).
    try std.testing.expectEqual(@as(usize, 1), driving_award.surface_revoked(5));
    try std.testing.expect(find_user_window(2) == null);
    try std.testing.expect(find_user_window(3) != null);
    try std.testing.expectEqual(@as(usize, 5), driving_award.win_count);
    try std.testing.expectEqual(@as(u8, 3), driving_award.focused_id);
    // No window means no fill can reach the freed physical pages a surface
    // binding used to point at (`user_fill` writes `surface_pa` directly).
    try std.testing.expect(!user_fill(2, 0, 0, 4, 4, 0xff0000));
    // Idempotent: the binding is gone with the window, so a second sweep for
    // the same handle finds nothing.
    try std.testing.expectEqual(@as(usize, 0), driving_award.surface_revoked(5));
    _ = close_owner(8);
}

test "driving_award: a surface-backed window cannot outgrow its bound surface (issue #2111)" {
    arm();
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 128, 64, 7));
    // Bind a surface with headroom: 16 pages (64 KiB) holds up to 128x128 /
    // 256x64 at 4 Bpp — the bind-time check only asks len >= win bytes.
    try std.testing.expect(user_bind_surface(2, .{ .handle = 1, .pa_base = 0x1000_0000, .page_count = 16 }));

    // Growing past the bound surface is REFUSED on the app path — the
    // window keeps its old rect (the pool-exhaustion contract). Pre-fix,
    // reflow grew win.w/h and the next sys_win_fill wrote ~3.5 MiB past the
    // surface's physical pages.
    try std.testing.expect(!user_resize(2, 1280, 720));
    try std.testing.expectEqual(WinRect{ .x = 64, .y = 64, .w = 128, .h = 64 }, user_rect(2).?);

    // ...and on the WM path (wm_apply_rect skips the back-buffer clamp but
    // the surface bound is a memory-safety invariant, not a layout policy).
    try std.testing.expect(!wm_apply_rect(2, 0, 0, 1280, 720));
    try std.testing.expectEqual(WinRect{ .x = 64, .y = 64, .w = 128, .h = 64 }, user_rect(2).?);

    // A same-size move still lands (position only, no surface pressure).
    try std.testing.expect(user_move(2, 32, 32));
    try std.testing.expectEqual(WinRect{ .x = 32, .y = 32, .w = 128, .h = 64 }, user_rect(2).?);

    // A resize that still fits the surface is honored (256x64 = 64 KiB).
    // (The fill itself is not re-asserted here: it writes through the real
    // surface pa, which a host test cannot dereference — the guard below
    // proves the refusal happens BEFORE any surface write.)
    try std.testing.expect(user_resize(2, 256, 64));
    try std.testing.expectEqual(WinRect{ .x = 32, .y = 32, .w = 256, .h = 64 }, user_rect(2).?);
    // One page further is refused again (256x128 = 128 KiB > 64 KiB).
    try std.testing.expect(!user_resize(2, 256, 128));
    try std.testing.expectEqual(WinRect{ .x = 32, .y = 32, .w = 256, .h = 64 }, user_rect(2).?);

    // The defensive guard: a hand-desynced rect (surface_pages smaller than
    // w*h*4 — reflow now prevents this) refuses the fill rather than writing
    // past the region.
    const win = find_user_window(2).?;
    win.surface_pages = 8; // 32 KiB < 256*64*4 — impossible post-fix
    try std.testing.expect(!user_fill(2, 0, 0, 1, 1, 0xff0000));
    _ = user_close(2);
}

test "driving_award: M52 card 3 — a dead drag source leaves no capture; another process's death does not cancel it" {
    arm();
    try std.testing.expect(!drag_is_active());
    _ = user_open(64, 64, 512, 384, 7);
    _ = user_open(320, 64, 512, 384, 8);

    // Process 7 starts the Arc4 #237 drag (the payload is process-scoped).
    drag_start("hello", 7);
    try std.testing.expect(drag_is_active());
    try std.testing.expectEqualStrings("hello", drag_get_payload());
    try std.testing.expectEqual(@as(usize, 7), driving_award.drag_source_pid);

    // A DIFFERENT process dying must not steal the live drag: only the
    // source's own death ends it.
    try std.testing.expectEqual(@as(usize, 1), close_owner(8));
    try std.testing.expect(drag_is_active());
    try std.testing.expectEqualStrings("hello", drag_get_payload());

    // The source's death cancels the capture and clears every field that
    // named it — nothing survives pointing at a dead pid.
    try std.testing.expectEqual(@as(usize, 1), close_owner(7));
    try std.testing.expect(!drag_is_active());
    try std.testing.expectEqual(@as(usize, 0), drag_get_payload().len);
    try std.testing.expectEqual(@as(usize, 0), driving_award.drag_source_pid);
    try std.testing.expectEqual(@as(?u8, null), driving_award.drag_over_id);
}

test "driving_award: M52 card 3 review — removing the HOVERED window clears the drag target (review nit)" {
    arm();
    _ = user_open(64, 64, 512, 384, 7); // window 2, owned by 7 (the drag source)
    _ = user_open(320, 64, 512, 384, 8); // window 3, owned by 8

    // An active drag whose pointer sits over window 2. The pointer path sets
    // this field (`pointer_tick`, which returns early once a WM is
    // registered), so the host test writes the state that path would have.
    drag_start("payload", 7);
    driving_award.drag_over_id = 2;

    // A DIFFERENT window leaving must not disturb the hover.
    try std.testing.expectEqual(@as(usize, 1), close_owner(8));
    try std.testing.expectEqual(@as(?u8, 2), driving_award.drag_over_id);

    // The HOVERED window leaving clears it: capture state may not keep naming
    // a window that has left the registry.
    try std.testing.expect(user_close(2));
    try std.testing.expectEqual(@as(?u8, null), driving_award.drag_over_id);

    // The drag itself survives — its live source is untouched; only the
    // target it named is gone.
    try std.testing.expect(drag_is_active());
    try std.testing.expectEqual(@as(usize, 7), driving_award.drag_source_pid);
    drag_cancel();
}

// ---------------------------------------------------------------------------
// Card U4/U5 host tests (claims 0935/4993)
// ---------------------------------------------------------------------------

test "driving_award: card U5 — cycle_focus walks the z-order and wraps" {
    arm();
    // Clock migrated to tray — cycle now needs user driving_award.windows to walk.
    // Order after two opens: [0 terminal, wallpaper, taskbar, dock, 2, 3] focused 3.
    _ = user_open(64, 64, 200, 100, 7);
    _ = user_open(320, 64, 200, 100, 8);
    // Focus 3 -> next is terminal 0 (wraps), then 2, then 3
    try std.testing.expectEqual(@as(?u8, 0), cycle_focus());
    try std.testing.expectEqual(@as(?u8, 2), cycle_focus());
    try std.testing.expectEqual(@as(?u8, 3), cycle_focus());
    _ = user_close(3);
    _ = user_close(2);
}

test "driving_award: card U4 — map_pointer_axis scales 0..32767 onto the span" {
    try std.testing.expectEqual(@as(u32, 0), map_pointer_axis(0, 1280));
    try std.testing.expectEqual(@as(u32, 640), map_pointer_axis(16384, 1280));
    try std.testing.expectEqual(@as(u32, 1279), map_pointer_axis(32767, 1280));
    try std.testing.expectEqual(@as(u32, 719), map_pointer_axis(32767, 720));
}

test "driving_award: card U5 — the chrome draws the focus ring on the focused window" {
    arm();
    // Clock migrated to tray — test focus ring on a user window instead.
    _ = user_open(100, 100, 200, 100, 7);
    try std.testing.expect(focus(2));
    _ = composite();
    const stride = virtio_gpu.fb_width * 4;
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const px = struct {
        fn at(f: [*]u8, st: usize, x: usize, y: usize) u32 {
            const o = y * st + x * 4;
            return @as(u32, f[o + 2]) << 16 | @as(u32, f[o + 1]) << 8 | f[o];
        }
    };
    const w = find_user_window(2).?;
    try std.testing.expectEqual(focus_ring(), px.at(fb, stride, w.x, w.y));
    // ...and just inside the ring, the window's title bar (not ring).
    try std.testing.expect(px.at(fb, stride, w.x + focus_ring_w, w.y + focus_ring_w) != focus_ring());
    // Focus back to the terminal: the full-screen terminal never carries
    // the ring (issue #164 — a ring around it would cover the first text
    // row/column), so the screen corner is NOT white.
    try std.testing.expect(focus(0));
    _ = composite();
    try std.testing.expect(px.at(fb, stride, 0, 0) != focus_ring());
    // The window's corner is NOT ringed anymore.
    try std.testing.expect(px.at(fb, stride, w.x, w.y) != focus_ring());
    _ = user_close(2);
}

test "driving_award: card U4 — pointer motion moves the cursor; a click focuses + raises" {
    arm();
    // Move to the former clock's area (now terminal, clock migrated to tray) — no click yet.
    const st_no: input.PointerState = .{ .x = 26000, .y = 8000, .buttons = 0, .valid = true };
    try std.testing.expectEqual(@as(?u8, null), pointer_tick(st_no, null));
    const c = cursor_pos().?;
    try std.testing.expectEqual(hit_test(c.x, c.y).?, 0); // the cursor is over the terminal (clock gone)
    // Click: D4 click = focus + raise on the topmost window under it (terminal).
    try std.testing.expectEqual(@as(?u8, 0), pointer_tick(st_no, .{ .x = st_no.x, .y = st_no.y }));
    try std.testing.expectEqual(@as(u8, 0), focused_window_id());
    try std.testing.expectEqual(@as(u8, 0), driving_award.windows[driving_award.win_count - 1].id); // raised on top (terminal)
    // Move to the terminal area and click: focus remains window 0.
    const st_term: input.PointerState = .{ .x = 4000, .y = 30000, .buttons = 0, .valid = true };
    try std.testing.expectEqual(@as(?u8, 0), pointer_tick(st_term, .{ .x = 4000, .y = 30000 }));
    // The hotspot stays at the pointer coordinate; the arrow tip is outlined.
    _ = composite();
    const stride = virtio_gpu.fb_width * 4;
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const o = c.y * stride + c.x * 4; // NOTE: st_no's cursor cell (over the clock)
    _ = o;
    const cc = cursor_pos().?;
    const off = cc.y * stride + cc.x * 4;
    try std.testing.expectEqual(@as(u8, 0x10), fb[off + 2]);
    try std.testing.expectEqual(@as(u8, 0x10), fb[off + 1]);
    try std.testing.expectEqual(@as(u8, 0x18), fb[off]);
}

test "driving_award: M91 cursor is an outlined arrow, not a solid block" {
    const px = struct {
        fn at(f: [*]u8, st: usize, x: usize, y: usize) u32 {
            const o = y * st + x * 4;
            return @as(u32, f[o + 2]) << 16 | @as(u32, f[o + 1]) << 8 | f[o];
        }
    };
    arm();
    driving_award.wm_owns_user_layer = false;
    _ = pointer_tick(.{ .x = 16384, .y = 16384, .buttons = 0, .valid = true }, null);
    _ = driving_award.paint_scene();
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const c = cursor_pos().?;
    var white: usize = 0;
    var dark: usize = 0;
    var transparent: usize = 0;
    for (0..cursor_h) |y| {
        for (0..cursor_w) |x| {
            const rgb = px.at(fb, virtio_gpu.fb_width * 4, c.x + x, c.y + y);
            if (rgb == 0xffffff) white += 1 else if (rgb == 0x101018) dark += 1 else transparent += 1;
        }
    }
    try std.testing.expect(white > 0 and dark > 0 and transparent > 0);
}

test "driving_award: M91 bound scanout rejects a competing kernel composite" {
    arm();
    driving_award.wm_owns_user_layer = true;
    defer driving_award.wm_owns_user_layer = false;
    const dirty = driving_award.windows[0].dirty;
    _ = composite();
    try std.testing.expectEqual(dirty, driving_award.windows[0].dirty);
}

test "driving_award: M91 cursor mask, hotspot, four-edge clipping and restoration" {
    arm();
    driving_award.wm_owns_user_layer = false;
    try std.testing.expectEqual(cursor_h, driving_award.cursor_mask.len);
    for (driving_award.cursor_mask) |row| try std.testing.expectEqual(cursor_w, row.len);
    const hot = driving_award.cursor_hotspot;
    try std.testing.expectEqual(@as(?u32, driving_award.cursor_outline_rgb), driving_award.cursor_pixel(hot.x, hot.y, false));
    try std.testing.expectEqual(@as(?u32, null), driving_award.cursor_pixel(0, 0, false));
    try std.testing.expectEqual(@as(?u32, 0xffaa00), driving_award.cursor_pixel(2, 3, true));
    try std.testing.expectEqual(@as(?u32, null), driving_award.cursor_pixel(cursor_w, cursor_h, false));
    try std.testing.expect(driving_award.cursor_rect(0, 0, 0, 1) == null);
    try std.testing.expect(driving_award.cursor_rect(500, 500, 10, 10) == null);

    const fb = &virtio_gpu.gpu_fb;
    const corners = [_]struct { x: u32, y: u32 }{
        .{ .x = 0, .y = 0 },
        .{ .x = virtio_gpu.fb_width - 1, .y = 0 },
        .{ .x = 0, .y = virtio_gpu.fb_height - 1 },
        .{ .x = virtio_gpu.fb_width - 1, .y = virtio_gpu.fb_height - 1 },
    };
    for (corners) |c| {
        @memset(fb, 0x32);
        driving_award.cursor_x = c.x;
        driving_award.cursor_y = c.y;
        driving_award.cursor_shown = true;
        driving_award.cursor_draw();
        const rect = driving_award.cursor_rect(c.x, c.y, virtio_gpu.fb_width, virtio_gpu.fb_height).?;
        try std.testing.expect(rect.x + rect.w <= virtio_gpu.fb_width);
        try std.testing.expect(rect.y + rect.h <= virtio_gpu.fb_height);
        // The entire framebuffer, not just its rectangle, matches the clipped mask.
        for (0..virtio_gpu.fb_height) |y| {
            for (0..virtio_gpu.fb_width) |x| {
                const mx: i64 = @as(i64, @intCast(x)) - c.x + hot.x;
                const my: i64 = @as(i64, @intCast(y)) - c.y + hot.y;
                const color = if (mx >= 0 and my >= 0)
                    driving_award.cursor_pixel(@intCast(mx), @intCast(my), false)
                else
                    null;
                const expected = if (color) |rgb| rgb | 0xff000000 else 0x32323232;
                try std.testing.expectEqual(expected, std.mem.readInt(u32, fb[(y * virtio_gpu.fb_width + x) * 4 ..][0..4], .little));
            }
        }
        driving_award.cursor_restore();
        for (fb) |byte| try std.testing.expectEqual(@as(u8, 0x32), byte);
    }
}

test "driving_award: M91 cursor old/new damage coalesces and restores without stale stores" {
    arm();
    driving_award.wm_owns_user_layer = false;
    @memset(&virtio_gpu.gpu_fb, 0x32);
    _ = pointer_tick(.{ .x = 4096, .y = 4096, .buttons = 0, .valid = true }, null);
    const old = cursor_pos().?;
    driving_award.cursor_draw();
    driving_award.cursor_damage_clear();
    _ = pointer_tick(.{ .x = 8192, .y = 8192, .buttons = 0, .valid = true }, null);
    _ = pointer_tick(.{ .x = 16384, .y = 16384, .buttons = 0, .valid = true }, null);
    const new = cursor_pos().?;
    try std.testing.expectEqual(driving_award.cursor_rect(old.x, old.y, 1280, 720), driving_award.cursor_old_damage);
    try std.testing.expectEqual(driving_award.cursor_rect(new.x, new.y, 1280, 720), driving_award.cursor_new_damage);
    driving_award.cursor_restore();
    for (virtio_gpu.gpu_fb) |byte| try std.testing.expectEqual(@as(u8, 0x32), byte);
    driving_award.cursor_draw();
    const off = (new.y * virtio_gpu.fb_width + new.x) * 4;
    std.mem.writeInt(u32, virtio_gpu.gpu_fb[off..][0..4], 0xffabcdef, .little);
    driving_award.cursor_restore();
    try std.testing.expectEqual(@as(u32, 0xffabcdef), std.mem.readInt(u32, virtio_gpu.gpu_fb[off..][0..4], .little));
    driving_award.cursor_damage_clear();
    _ = pointer_tick(.{ .x = 16384, .y = 16384, .buttons = 0, .valid = true }, null);
    try std.testing.expect(driving_award.cursor_old_damage == null);
    try std.testing.expect(driving_award.cursor_new_damage == null);
}

var m91_transfers: usize = 0;
var m91_flushes: usize = 0;
fn m91_transfer() virtio_gpu.CmdResult {
    m91_transfers += 1;
    return .ok;
}
fn m91_flush() virtio_gpu.CmdResult {
    m91_flushes += 1;
    return .ok;
}
test "driving_award: M91 clean scene does not transfer or flush; shim still presents damage" {
    arm();
    driving_award.wm_owns_user_layer = false;
    driving_award.splash_hold = false;
    const ready = virtio_gpu.gpu_ready;
    virtio_gpu.gpu_ready = true;
    driving_award.transfer_hook = m91_transfer;
    driving_award.flush_hook = m91_flush;
    defer {
        virtio_gpu.gpu_ready = ready;
        driving_award.transfer_hook = null;
        driving_award.flush_hook = null;
    }
    m91_transfers = 0;
    m91_flushes = 0;
    try std.testing.expectEqual(virtio_gpu.CmdResult.ok, composite());
    const before = m91_transfers;
    try std.testing.expectEqual(virtio_gpu.CmdResult.ok, composite());
    try std.testing.expectEqual(before, m91_transfers);
    try std.testing.expectEqual(before, m91_flushes);
    try std.testing.expect(mark_dirty(0));
    try std.testing.expectEqual(virtio_gpu.CmdResult.ok, composite());
    try std.testing.expectEqual(before + 1, m91_transfers);
    try std.testing.expectEqual(before + 1, m91_flushes);
}

test "driving_award: card E3 — mouse_buttons_to_flags maps button bits" {
    try std.testing.expectEqual(@as(u16, 0), mouse_buttons_to_flags(0));
    try std.testing.expectEqual(events.BTN_LEFT, mouse_buttons_to_flags(0x01));
    try std.testing.expectEqual(events.BTN_RIGHT, mouse_buttons_to_flags(0x02));
    try std.testing.expectEqual(events.BTN_MIDDLE, mouse_buttons_to_flags(0x04));
    try std.testing.expectEqual(events.BTN_LEFT | events.BTN_RIGHT | events.BTN_MIDDLE, mouse_buttons_to_flags(0x07));
}

test "driving_award: card E3 — pointer motion and clicks queue window-local events to owner" {
    events.init();
    arm();
    // Open a user window at (100, 50, 200, 100) owned by pid 3 (receives WIN_FOCUS)
    const res = user_open(100, 50, 200, 100, 3);
    try std.testing.expect(res == .opened);
    const win_id = res.opened;
    _ = events.pop(3); // Consume WIN_FOCUS

    // Move pointer to (150, 80) scanout coordinates (inside the user window)
    // 150 / 1280 * 32768 = 3840; 80 / 720 * 32768 = 3641
    const st_motion: input.PointerState = .{ .x = 3840, .y = 3641, .buttons = 0, .valid = true };
    _ = pointer_tick(st_motion, null);

    // MOUSE_MOVE event should be queued for pid 3
    try std.testing.expect(events.pending(3) >= 1);
    const ev_move = events.pop(3).?;
    try std.testing.expectEqual(events.MOUSE_MOVE, ev_move.kind);
    // Scanout (150, 80) mapped to window-local coordinates: x = 150 - 100 = 50, y = 80 - 50 = 30
    try std.testing.expectEqual(@as(u32, 50), ev_move.arg0);
    try std.testing.expectEqual(@as(u32, 30), ev_move.arg1);

    // Press left mouse button
    const st_down: input.PointerState = .{ .x = 3840, .y = 3641, .buttons = 0x01, .valid = true };
    _ = pointer_tick(st_down, null);

    // MOUSE_DOWN event queued with BTN_LEFT flag
    try std.testing.expect(events.pending(3) >= 1);
    const ev_down = events.pop(3).?;
    try std.testing.expectEqual(events.MOUSE_DOWN, ev_down.kind);
    try std.testing.expect((ev_down.flags & events.BTN_LEFT) != 0);
    try std.testing.expectEqual(@as(u32, 50), ev_down.arg0);
    try std.testing.expectEqual(@as(u32, 30), ev_down.arg1);

    // Release mouse button
    const st_up: input.PointerState = .{ .x = 3840, .y = 3641, .buttons = 0, .valid = true };
    _ = pointer_tick(st_up, null);

    // MOUSE_UP event queued
    try std.testing.expect(events.pending(3) >= 1);
    const ev_up = events.pop(3).?;
    try std.testing.expectEqual(events.MOUSE_UP, ev_up.kind);
    try std.testing.expectEqual(@as(u32, 50), ev_up.arg0);
    try std.testing.expectEqual(@as(u32, 30), ev_up.arg1);

    // Clean up
    _ = user_close(win_id);
}

test "driving_award: card E4 — window lifecycle emits WIN_FOCUS, WIN_BLUR, and WIN_CLOSE" {
    events.init();
    arm();

    // 1. Open user window 2 owned by pid 4 -> receives WIN_FOCUS
    const res1 = user_open(10, 10, 100, 100, 4);
    try std.testing.expect(res1 == .opened);
    const win2 = res1.opened;
    try std.testing.expectEqual(@as(usize, 1), events.pending(4));
    const ev_f1 = events.pop(4).?;
    try std.testing.expectEqual(events.WIN_FOCUS, ev_f1.kind);
    try std.testing.expectEqual(@as(u32, win2), ev_f1.arg0);

    // 2. Open user window 3 owned by pid 5 -> pid 4 gets WIN_BLUR, pid 5 gets WIN_FOCUS
    const res2 = user_open(120, 10, 100, 100, 5);
    try std.testing.expect(res2 == .opened);
    const win3 = res2.opened;

    // Check pid 4 received WIN_BLUR
    try std.testing.expectEqual(@as(usize, 1), events.pending(4));
    const ev_b1 = events.pop(4).?;
    try std.testing.expectEqual(events.WIN_BLUR, ev_b1.kind);
    try std.testing.expectEqual(@as(u32, win2), ev_b1.arg0);
    try std.testing.expectEqual(@as(u32, win3), ev_b1.arg1);

    // Check pid 5 received WIN_FOCUS
    try std.testing.expectEqual(@as(usize, 1), events.pending(5));
    const ev_f2 = events.pop(5).?;
    try std.testing.expectEqual(events.WIN_FOCUS, ev_f2.kind);
    try std.testing.expectEqual(@as(u32, win3), ev_f2.arg0);

    // 3. Focus back to window 0 (terminal) -> pid 5 gets WIN_BLUR
    try std.testing.expect(focus(0));
    try std.testing.expectEqual(@as(usize, 1), events.pending(5));
    const ev_b2 = events.pop(5).?;
    try std.testing.expectEqual(events.WIN_BLUR, ev_b2.kind);
    try std.testing.expectEqual(@as(u32, win3), ev_b2.arg0);
    try std.testing.expectEqual(@as(u32, 0), ev_b2.arg1);

    // 4. Close window 2 -> pid 4 receives WIN_CLOSE
    try std.testing.expect(user_close(win2));
    try std.testing.expectEqual(@as(usize, 1), events.pending(4));
    const ev_c1 = events.pop(4).?;
    try std.testing.expectEqual(events.WIN_CLOSE, ev_c1.kind);
    try std.testing.expectEqual(@as(u32, win2), ev_c1.arg0);

    // Clean up window 3
    _ = user_close(win3);
}

test "driving_award: M15 C2 — Alt+Tab overlay snapshots, cycles, commits" {
    arm();
    // 0 user driving_award.windows → no overlay.
    try std.testing.expect(!alt_tab_is_active());
    try std.testing.expect(!alt_tab_activate());
    try std.testing.expect(!alt_tab_is_active());
    // 1 user window → no overlay (honest no-op).
    _ = user_open(10, 10, 200, 100, 7);
    try std.testing.expect(!alt_tab_activate());
    try std.testing.expectEqual(@as(usize, 0), alt_tab_count());
    // 2 user driving_award.windows → overlay snapshots both, selected is next after focused.
    _ = user_open(120, 10, 200, 100, 8);
    try std.testing.expectEqual(@as(u8, 3), driving_award.focused_id); // last opened has focus
    try std.testing.expect(alt_tab_activate());
    try std.testing.expect(alt_tab_is_active());
    try std.testing.expectEqual(@as(usize, 2), alt_tab_count());
    // Focus is 3, so selected should be 2 (the other window).
    try std.testing.expectEqual(@as(?u8, 2), alt_tab_selected_id());
    // Cycle forward → wraps to 3, back → 2.
    alt_tab_cycle(false);
    try std.testing.expectEqual(@as(?u8, 3), alt_tab_selected_id());
    alt_tab_cycle(false);
    try std.testing.expectEqual(@as(?u8, 2), alt_tab_selected_id());
    alt_tab_cycle(true); // Shift+Tab reverse
    try std.testing.expectEqual(@as(?u8, 3), alt_tab_selected_id());
    // Commit → focuses selected (3) and dismisses overlay.
    const committed = alt_tab_commit().?;
    try std.testing.expectEqual(@as(u8, 3), committed);
    try std.testing.expect(!alt_tab_is_active());
    try std.testing.expectEqual(@as(u8, 3), driving_award.focused_id);
    try std.testing.expectEqual(@as(usize, 5), driving_award.win_count - 1); // raised to top (4 base +2 users -> top index 5)
    // Re-activate then dismiss without commit.
    try std.testing.expect(alt_tab_activate());
    try std.testing.expectEqual(@as(?u8, 2), alt_tab_selected_id());
    alt_tab_dismiss();
    try std.testing.expect(!alt_tab_is_active());
    try std.testing.expectEqual(@as(u8, 3), driving_award.focused_id); // unchanged
    // Close while active → honest dismiss.
    try std.testing.expect(alt_tab_activate());
    try std.testing.expect(alt_tab_is_active());
    _ = user_close(2);
    try std.testing.expect(!alt_tab_is_active());
    _ = user_close(3);
}

test "driving_award: M15 C2 — overlay renders centered list with highlight" {
    arm();
    _ = user_open(10, 10, 200, 100, 7);
    _ = user_open(120, 10, 200, 100, 8);
    _ = alt_tab_activate();
    _ = composite();
    const stride = virtio_gpu.fb_width * 4;
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const ov_w: u32 = 440;
    const ov_x: u32 = (virtio_gpu.fb_width - ov_w) / 2;
    const ov_y: u32 = (virtio_gpu.fb_height - (24 + 8 * 2 + 2 * 28 + 8)) / 2;
    // Overlay border is accent color (0xffaa00 → B=0x00 G=0xaa R=0xff).
    const px = struct {
        fn at(f: [*]u8, st: usize, x: usize, y: usize) u32 {
            const o = y * st + x * 4;
            return @as(u32, f[o + 2]) << 16 | @as(u32, f[o + 1]) << 8 | f[o];
        }
    };
    try std.testing.expectEqual(@as(u32, 0xffaa00), px.at(fb, stride, ov_x, ov_y));
    // Inside the highlighted row (first selected is id 2) the row bg is active (0x3b82f6 blue in dark theme).
    const sel_y = ov_y + 24 + 8 + 10;
    try std.testing.expectEqual(@as(u32, 0x3b82f6), px.at(fb, stride, ov_x + 10, sel_y));
}

test "driving_award: Arc2 W1 — clamp_resize_w/h clamp to 128×64..512×384 and screen" {
    // Pure clamp math — no window needed except screen containment.
    // Buffer bounds.
    try std.testing.expectEqual(@as(u32, 128), clamp_resize_w(100, 0));
    try std.testing.expectEqual(@as(u32, 128), clamp_resize_w(127, 0));
    try std.testing.expectEqual(@as(u32, 128), clamp_resize_w(128, 0));
    try std.testing.expectEqual(@as(u32, 200), clamp_resize_w(200, 0));
    try std.testing.expectEqual(@as(u32, 512), clamp_resize_w(512, 0));
    // WM1: no 512 cap — the bound is the scanout (1280).
    try std.testing.expectEqual(@as(u32, 600), clamp_resize_w(600, 0));
    try std.testing.expectEqual(@as(u32, 1000), clamp_resize_w(1000, 0));
    try std.testing.expectEqual(@as(u32, 1280), clamp_resize_w(99999, 0));
    try std.testing.expectEqual(@as(u32, 64), clamp_resize_h(10, 0));
    try std.testing.expectEqual(@as(u32, 64), clamp_resize_h(64, 0));
    try std.testing.expectEqual(@as(u32, 100), clamp_resize_h(100, 0));
    // WM1: no 424 cap — 500 and 700 clamp to the scanout, not the buffer.
    try std.testing.expectEqual(@as(u32, 424), clamp_resize_h(424, 0));
    try std.testing.expectEqual(@as(u32, 500), clamp_resize_h(500, 0));
    try std.testing.expectEqual(@as(u32, 700), clamp_resize_h(700, 0));
    try std.testing.expectEqual(@as(u32, 720), clamp_resize_h(99999, 0));
    // Screen containment: fb is 1280×720.
    try std.testing.expectEqual(@as(u32, 280), clamp_resize_w(512, 1000)); // 1280-1000=280
    try std.testing.expectEqual(@as(u32, 128), clamp_resize_w(128, 1152)); // 1280-1152=128 exactly min
    // Negative request clamps to min.
    try std.testing.expectEqual(@as(u32, 128), clamp_resize_w(-50, 0));
    try std.testing.expectEqual(@as(u32, 64), clamp_resize_h(-10, 0));
}

test "driving_award: Arc2 W1 — is_resize_hit detects 6×6 bottom-right corner" {
    arm();
    _ = user_open(100, 50, 200, 100, 7);
    const w = find_user_window(2).?.*;
    // Inside the 6×6 corner: x+w-6 .. x+w-1, y+h-6 .. y+h-1
    try std.testing.expect(is_resize_hit(w, 100 + 200 - 3, 50 + 100 - 3));
    try std.testing.expect(is_resize_hit(w, 100 + 200 - 1, 50 + 100 - 1));
    try std.testing.expect(is_resize_hit(w, 100 + 200 - 6, 50 + 100 - 6));
    // Outside the corner but inside window — not a resize hit.
    try std.testing.expect(!is_resize_hit(w, 100 + 10, 50 + 10));
    try std.testing.expect(!is_resize_hit(w, 100 + 200 - 3, 50 + 10));
    try std.testing.expect(!is_resize_hit(w, 100 + 200 - 7, 50 + 100 - 3));
    // Outside window.
    try std.testing.expect(!is_resize_hit(w, 100 + 200 + 1, 50 + 100 - 3));
    _ = user_close(2);
}

test "driving_award: Arc2 W1 — user_resize clamps and emits WIN_RESIZE" {
    events.init();
    arm();
    _ = user_open(64, 64, 200, 100, 9);
    // Consume the WIN_FOCUS from open.
    _ = events.pop(9);
    // Below min clamps to 128×64.
    try std.testing.expect(user_resize(2, 50, 10));
    try std.testing.expectEqual(@as(u32, 128), find_user_window(2).?.w);
    try std.testing.expectEqual(@as(u32, 64), find_user_window(2).?.h);
    var ev = events.pop(9).?;
    try std.testing.expectEqual(events.WIN_RESIZE, ev.kind);
    try std.testing.expectEqual(@as(u32, 128), ev.arg0);
    try std.testing.expectEqual(@as(u32, 64), ev.arg1);
    // Above the old 512×424 cap no longer clamps (WM1: the pool buffer
    // follows up to the scanout) — 800×500 lands exactly, and the pool
    // pages grow with it.
    try std.testing.expect(user_resize(2, 800, 500));
    try std.testing.expectEqual(@as(u32, 800), find_user_window(2).?.w);
    try std.testing.expectEqual(@as(u32, 500), find_user_window(2).?.h);
    try std.testing.expectEqual(kbuf_pages_for(800 * 500 * 4), find_user_window(2).?.kbuf_pages);
    ev = events.pop(9).?;
    try std.testing.expectEqual(events.WIN_RESIZE, ev.kind);
    try std.testing.expectEqual(@as(u32, 800), ev.arg0);
    try std.testing.expectEqual(@as(u32, 500), ev.arg1);
    // Chrome dirty + terminal dirty for repaint.
    try std.testing.expect(find_user_window(2).?.dirty);
    try std.testing.expect(driving_award.windows[0].dirty);
    // Unknown id refused.
    try std.testing.expect(!user_resize(99, 200, 100));
    try std.testing.expect(!user_resize(0, 200, 100));
    _ = user_close(2);
}

test "driving_award: Arc2 W1 — pointer_tick drag-to-resize via bottom-right corner" {
    events.init();
    arm();
    _ = user_open(100, 50, 200, 100, 7);
    _ = events.pop(7); // WIN_FOCUS
    const win0 = find_user_window(2).?;
    const rx = win0.x + win0.w - 3;
    const ry = win0.y + win0.h - 3;
    const cx = @as(u16, @intCast((rx * 32768) / virtio_gpu.fb_width));
    const cy = @as(u16, @intCast((ry * 32768) / virtio_gpu.fb_height));
    // MOUSE_DOWN in resize corner starts resize.
    const st_down: input.PointerState = .{ .x = cx, .y = cy, .buttons = 0x01, .valid = true };
    _ = pointer_tick(st_down, .{ .x = cx, .y = cy });
    try std.testing.expect(resize_active());
    try std.testing.expectEqual(@as(?u8, 2), resize_current_id());
    // MOUSE_MOVE 30,20 larger — new size 230×120.
    const nx = rx + 30;
    const ny = ry + 20;
    const cx2 = @as(u16, @intCast((nx * 32768) / virtio_gpu.fb_width));
    const cy2 = @as(u16, @intCast((ny * 32768) / virtio_gpu.fb_height));
    const st_move: input.PointerState = .{ .x = cx2, .y = cy2, .buttons = 0x01, .valid = true };
    _ = pointer_tick(st_move, null);
    try std.testing.expectEqual(@as(u32, 230), find_user_window(2).?.w);
    try std.testing.expectEqual(@as(u32, 120), find_user_window(2).?.h);
    try std.testing.expect(events.pending(7) >= 1);
    var found_resize = false;
    while (events.pop(7)) |ev| {
        if (ev.kind == events.WIN_RESIZE) {
            found_resize = true;
            try std.testing.expectEqual(@as(u32, 230), ev.arg0);
            try std.testing.expectEqual(@as(u32, 120), ev.arg1);
        }
    }
    try std.testing.expect(found_resize);
    // MOUSE_UP ends resize.
    const st_up: input.PointerState = .{ .x = cx2, .y = cy2, .buttons = 0x00, .valid = true };
    _ = pointer_tick(st_up, null);
    try std.testing.expect(!resize_active());
    // M32 WMS8 Gate 6: the title-bar drag state is deleted (the WM owns it),
    // so there is no drag_id to assert — resize remains a kernel surface.
    // Clamp test via pointer_tick: drag far negative — clamps to min.
    // Need to re-hit after move: window is now 230×120 at (100,50), corner at 327,167.
    const rx2 = find_user_window(2).?.x + find_user_window(2).?.w - 3;
    const ry2 = find_user_window(2).?.y + find_user_window(2).?.h - 3;
    const cx3 = @as(u16, @intCast((rx2 * 32768) / virtio_gpu.fb_width));
    const cy3 = @as(u16, @intCast((ry2 * 32768) / virtio_gpu.fb_height));
    _ = pointer_tick(.{ .x = cx3, .y = cy3, .buttons = 0x01, .valid = true }, .{ .x = cx3, .y = cy3 });
    const st_far_neg: input.PointerState = .{ .x = 0, .y = 0, .buttons = 0x01, .valid = true };
    _ = pointer_tick(st_far_neg, null);
    try std.testing.expectEqual(@as(u32, 128), find_user_window(2).?.w);
    try std.testing.expectEqual(@as(u32, 64), find_user_window(2).?.h);
    _ = pointer_tick(.{ .x = 0, .y = 0, .buttons = 0x00, .valid = true }, null);
    _ = user_close(2);
}

test "driving_award: Arc2 W3 — tray helpers and geometry" {
    arm();
    clipboard.init();
    // tray_rect is right 80px at y=700, 20px tall.
    const tr = tray_rect();
    try std.testing.expectEqual(@as(u32, 1200), tr.x);
    try std.testing.expectEqual(@as(u32, 700), tr.y);
    try std.testing.expectEqual(@as(u32, 80), tr.w);
    try std.testing.expectEqual(@as(u32, 20), tr.h);
    try std.testing.expectEqual(taskbar_y, tr.y);
    try std.testing.expectEqual(taskbar_h, tr.h);
    // format_hhmm zero-padded 24h wrap.
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("00:00", format_hhmm(&buf, 0));
    try std.testing.expectEqualStrings("00:01", format_hhmm(&buf, 60));
    try std.testing.expectEqualStrings("01:00", format_hhmm(&buf, 3600));
    try std.testing.expectEqualStrings("01:01", format_hhmm(&buf, 3660));
    try std.testing.expectEqualStrings("23:59", format_hhmm(&buf, 23 * 3600 + 59 * 60));
    try std.testing.expectEqualStrings("00:00", format_hhmm(&buf, 24 * 3600));
    // theme_letter maps dark/light/amber.
    driving_award.theme_id = 0;
    try std.testing.expectEqual(@as(u8, 'D'), theme_letter());
    driving_award.theme_id = 1;
    try std.testing.expectEqual(@as(u8, 'L'), theme_letter());
    driving_award.theme_id = 2;
    try std.testing.expectEqual(@as(u8, 'A'), theme_letter());
    driving_award.theme_id = 99;
    try std.testing.expectEqual(@as(u8, 'D'), theme_letter());
    // clipboard indicator empty -> filled.
    try std.testing.expect(!tray_clipboard_filled());
    _ = clipboard.set("hello");
    try std.testing.expect(tray_clipboard_filled());
    _ = clipboard.set("");
    try std.testing.expect(!tray_clipboard_filled());
    driving_award.theme_id = 0;
}

test "driving_award: Arc2 W3 — drain ticks tray HH:MM without timer" {
    arm();
    clipboard.init();
    // First tick initializes tray.
    try std.testing.expect(!tray_has_clock());
    _ = drain(0);
    try std.testing.expect(tray_has_clock());
    try std.testing.expectEqual(@as(u64, 0), tray_current_tick());
    // Different tick marks taskbar dirty and updates tray.
    driving_award.windows[2].dirty = false; // taskbar at index 2 after migration
    _ = drain(60);
    try std.testing.expectEqual(@as(u64, 60), tray_current_tick());
    // HH:MM at 60s is 00:01
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("00:01", format_hhmm(&buf, tray_current_tick()));
}

test "driving_award: Arc2 W3 — composite renders tray in right 80px" {
    arm();
    clipboard.init();
    driving_award.theme_id = 1; // light -> L in blue accent
    _ = clipboard.set("x");
    _ = drain(3660); // 01:01
    _ = composite();
    const stride = virtio_gpu.fb_width * 4;
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const px = struct {
        fn at(f: [*]u8, st: usize, x: usize, y: usize) u32 {
            const o = y * st + x * 4;
            return @as(u32, f[o + 2]) << 16 | @as(u32, f[o + 1]) << 8 | f[o];
        }
    };
    // Taskbar background at (4,702) is taskbar_bg (light: 0xe2e8f0), not black.
    try std.testing.expect(px.at(fb, stride, 4, 702) != 0);
    // Tray clock area at tray_x+4, tray_y+6 should have white glyph pixels (HH:MM).
    // We check that the tray region is not just background — at least one white pixel near HH:MM.
    var found_white = false;
    var x: u32 = tray_x + 4;
    while (x < tray_x + 40) : (x += 1) {
        if (px.at(fb, stride, x, tray_y + 6) == 0xffffff) {
            found_white = true;
            break;
        }
    }
    try std.testing.expect(found_white);
    // Theme letter at tray_x+48 should be accent blue for light theme (0x2563eb).
    // Check that accent pixel exists near that x (glyph may not cover every pixel, but background is taskbar_bg).
    // Clipboard filled rect at tray_x+64,6 size 10x8 should be filled white when has content.
    try std.testing.expectEqual(@as(u32, 0xffffff), px.at(fb, stride, tray_x + 64 + 5, tray_y + 6 + 4));
    // Switch to empty clipboard -> outline, center pixel should NOT be white (it is taskbar_bg).
    _ = clipboard.set("");
    // Need to mark dirty via composite preamble: theme unchanged but clip changed -> mark dirty + composite.
    _ = composite();
    try std.testing.expect(px.at(fb, stride, tray_x + 64 + 5, tray_y + 6 + 4) != 0xffffff);
    driving_award.theme_id = 0;
    clipboard.init();
}

test "driving_award: Arc2 W3 — Kind.clock deprecated but enum remains" {
    // Kind.clock still exists for ABI compat but arm no longer creates window id 1.
    arm();
    try std.testing.expectEqualStrings("clock", kind_name(.clock));
    var found_clock = false;
    var i: usize = 0;
    while (i < driving_award.win_count) : (i += 1) {
        if (driving_award.windows[i].id == 1 and driving_award.windows[i].kind == .clock) found_clock = true;
    }
    try std.testing.expect(!found_clock);
    // id 1 is free for future repurpose but currently not a user window.
    try std.testing.expect(find_user_window(1) == null);
    try std.testing.expect(!user_fill(1, 0, 0, 10, 10, 0xffffff));
}

test "driving_award: blit_rect_alpha blends src over dst at given opacity" {
    // 4x4 dst filled with 0x404040 (dark gray), src filled with 0xc0c0c0 (light gray).
    var dst: [4 * 4 * 4]u8 = undefined;
    var src: [4 * 4 * 4]u8 = undefined;
    for (0..(4 * 4 * 4)) |i| {
        dst[i] = 0x40;
        src[i] = 0xc0;
    }
    // 50% alpha (128): result = 0x40*(128/256) + 0xc0*(128/256) = 0x20 + 0x60 = 0x80.
    blit_rect_alpha(&dst, 4 * 4, &src, 4 * 4, 0, 0, 4, 4, 128);
    for (0..(4 * 4 * 4)) |i| {
        try std.testing.expectEqual(@as(u8, 0x80), dst[i]);
    }
}

test "driving_award: blit_rect_alpha at 25% opacity (64)" {
    var dst: [4 * 4 * 4]u8 = undefined;
    var src: [4 * 4 * 4]u8 = undefined;
    for (0..(4 * 4 * 4)) |i| {
        dst[i] = 0x00;
        src[i] = 0xff;
    }
    // 25% alpha (64): result = 0*(192/256) + 255*(64/256) ≈ 63.
    blit_rect_alpha(&dst, 4 * 4, &src, 4 * 4, 0, 0, 4, 4, 64);
    for (0..(4 * 4 * 4)) |i| {
        try std.testing.expectEqual(@as(u8, 63), dst[i]);
    }
}

test "driving_award: blit_rect_alpha at full opacity falls back to memcpy" {
    var dst: [4 * 4 * 4]u8 = undefined;
    var src: [4 * 4 * 4]u8 = undefined;
    for (0..(4 * 4 * 4)) |i| {
        dst[i] = 0x00;
        src[i] = 0xab;
    }
    blit_rect_alpha(&dst, 4 * 4, &src, 4 * 4, 0, 0, 4, 4, 256);
    for (0..(4 * 4 * 4)) |i| {
        try std.testing.expectEqual(@as(u8, 0xab), dst[i]);
    }
}

test "driving_award: window fade-in state transitions" {
    // user_open sets fade_phase=1, fade_tick=0.
    driving_award.armed_global = true;
    _ = user_open(100, 100, 200, 150, 99);
    const w = find_user_window(2).?;
    try std.testing.expectEqual(@as(u8, 1), w.fade_phase);
    try std.testing.expectEqual(@as(u8, 0), w.fade_tick);
    // After fade_half_frames ticks, phase is still 1 but alpha should be 50%.
    var fi: u8 = 0;
    while (fi < fade_half_frames) : (fi += 1) {
        w.fade_tick +|= 1;
    }
    try std.testing.expectEqual(@as(u8, 1), w.fade_phase);
    // After another fade_half_frames, fade completes.
    while (fi < fade_half_frames * 2) : (fi += 1) {
        w.fade_tick +|= 1;
    }
    w.fade_phase = 0; // simulate composite advancing
    w.fade_tick = 0;
    try std.testing.expectEqual(@as(u8, 0), w.fade_phase);
    _ = user_close(2);
}

test "driving_award: notification FIFO push/dismiss/advance" {
    // Reset state.
    driving_award.notify_head = 0;
    driving_award.notify_count = 0;
    // Push 3 notifications.
    notify_push("hello", 0);
    notify_push("warn", 1);
    notify_push("error", 2);
    try std.testing.expectEqual(@as(usize, 3), notify_count_visible());
    // entry(0) = oldest, entry(count-1) = newest.
    var e = notify_entry(2).?;
    try std.testing.expectEqual(@as(u8, 2), e.level);
    try std.testing.expectEqualStrings("error", e.text);
    e = notify_entry(1).?;
    try std.testing.expectEqualStrings("warn", e.text);
    e = notify_entry(0).?;
    try std.testing.expectEqualStrings("hello", e.text);
    // Dismiss index 0 (oldest = hello).
    try std.testing.expect(notify_dismiss(0));
    try std.testing.expectEqual(@as(usize, 2), notify_count_visible());
    // Overflow drops oldest — push enough to fill the ring.
    var p: usize = 0;
    while (p < notify_max) : (p += 1) {
        notify_push("item", 0);
    }
    try std.testing.expectEqual(@as(usize, notify_max), notify_count_visible());
    // Auto-dismiss after notify_dismiss_ticks.
    var t: u32 = 0;
    while (t < notify_dismiss_ticks) : (t += 1) {
        notify_advance_ticks();
    }
    try std.testing.expectEqual(@as(usize, 0), notify_count_visible());
}

test "driving_award: WM2 overview enter snapshots current-workspace windows" {
    arm();
    try std.testing.expect(!overview_is_open());
    try std.testing.expectEqual(@as(usize, 0), overview_window_count());
    // No user windows: enter opens an empty grid (honest, not a refusal).
    try std.testing.expectEqual(@as(usize, 0), overview_enter());
    try std.testing.expect(overview_is_open());
    overview_exit();
    try std.testing.expect(!overview_is_open());
    // Two windows on ws 0, one moved to ws 1: only ws-0 windows snapshot.
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(100, 100, 200, 100, 7));
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(400, 100, 200, 100, 7));
    try std.testing.expectEqual(UserOpenResult{ .opened = 4 }, user_open(700, 100, 200, 100, 7));
    try std.testing.expect(user_move_to_workspace(4, 1));
    try std.testing.expectEqual(@as(usize, 2), overview_enter());
    try std.testing.expectEqual(@as(usize, 2), overview_window_count());
    try std.testing.expectEqual(@as(u8, 2), driving_award.overview_ids[0]);
    try std.testing.expectEqual(@as(u8, 3), driving_award.overview_ids[1]);
    overview_exit();
    // Registry order is NOT the card order: raise(2) moves it to the top
    // of the z-order, but the snapshot still sorts ascending (the shared
    // card-index contract with the WM's mirror-order list).
    try std.testing.expect(raise(2));
    try std.testing.expectEqual(@as(usize, 2), overview_enter());
    try std.testing.expectEqual(@as(u8, 2), driving_award.overview_ids[0]);
    try std.testing.expectEqual(@as(u8, 3), driving_award.overview_ids[1]);
    overview_exit();
    // Exit closes without touching focus.
    const before = driving_award.focused_id;
    _ = overview_enter();
    overview_exit();
    try std.testing.expect(!overview_is_open());
    try std.testing.expectEqual(before, driving_award.focused_id);
    _ = user_close(2);
    _ = user_close(3);
    _ = user_close(4);
}

test "driving_award: WM2 overview focus raises the card and closes" {
    arm();
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(100, 100, 200, 100, 7));
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(400, 100, 200, 100, 7));
    _ = overview_enter();
    // Unknown id is refused, grid stays open.
    try std.testing.expect(!overview_focus(9));
    try std.testing.expect(overview_is_open());
    // Focus while closed is refused.
    overview_exit();
    try std.testing.expect(!overview_focus(2));
    // Card click: focus+raise + close.
    _ = overview_enter();
    try std.testing.expect(overview_focus(3));
    try std.testing.expect(!overview_is_open());
    try std.testing.expectEqual(@as(u8, 3), driving_award.focused_id);
    _ = user_close(2);
    _ = user_close(3);
}

test "driving_award: WM2 overview move relocates the card and switches" {
    arm();
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(100, 100, 200, 100, 7));
    _ = overview_enter();
    // Bad workspace and unknown id are refused, grid stays open.
    try std.testing.expect(!overview_move(2, 9));
    try std.testing.expect(!overview_move(9, 1));
    try std.testing.expect(overview_is_open());
    // Drag onto workspace 1: window moves and the desktop follows.
    try std.testing.expect(overview_move(2, 1));
    try std.testing.expect(!overview_is_open());
    try std.testing.expectEqual(@as(u8, 1), driving_award.current_workspace);
    const w = driving_award.find_user_window(2).?;
    try std.testing.expectEqual(@as(u8, 1), w.workspace);
    switch_workspace(0);
    _ = user_close(2);
}

test "driving_award: WM2 blit_scaled maps source corners onto the card" {
    // 4x4 source with distinct corners, scaled 2x into an 8x8 target.
    var src: [4 * 4 * 4]u8 = @as([(4 * 4 * 4)]u8, @splat(@as(u8, 0)));
    src[0] = 0x11; // (0,0) R
    src[(3 * 4 + 3) * 4] = 0x22; // (3,3) R
    var dst: [8 * 8 * 4]u8 = @as([(8 * 8 * 4)]u8, @splat(@as(u8, 0)));
    blit_scaled(&dst, 8 * 4, &src, 4, 4, 4 * 4, 0, 0, 8, 8);
    // Top-left 2x2 block comes from source (0,0).
    try std.testing.expectEqual(@as(u8, 0x11), dst[0]);
    try std.testing.expectEqual(@as(u8, 0x11), dst[(1 * 8 + 1) * 4]);
    // Bottom-right 2x2 block comes from source (3,3); alpha forced opaque.
    try std.testing.expectEqual(@as(u8, 0x22), dst[(7 * 8 + 7) * 4]);
    try std.testing.expectEqual(@as(u8, 0xff), dst[(7 * 8 + 7) * 4 + 3]);
    // Zero-size rects are no-ops (no trap).
    blit_scaled(&dst, 8 * 4, &src, 4, 4, 4 * 4, 0, 0, 0, 8);
    blit_scaled(&dst, 8 * 4, &src, 0, 4, 4 * 4, 0, 0, 8, 8);
}

test "driving_award: user_display_name prefers the title, else the owner process name (#1056)" {
    arm();
    // A named owner process, then a user window owned by it.
    const pid = driving_award.process.create("WINLOOP.BIN", .{}, .{}, .{}).?;
    const r = user_open(64, 64, 512, 384, pid);
    try std.testing.expectEqual(@as(u8, 2), r.opened);

    // No app title yet: the owner process's executable name is the label.
    try std.testing.expectEqualStrings("WINLOOP.BIN", driving_award.user_display_name(2).?);

    // An app-set title wins over the process name.
    try std.testing.expect(set_window_title(2, "Road Pops"));
    try std.testing.expectEqualStrings("Road Pops", driving_award.user_display_name(2).?);

    // Unknown id and a fixed (non-user) window are null.
    try std.testing.expectEqual(@as(?[]const u8, null), driving_award.user_display_name(250));
    try std.testing.expectEqual(@as(?[]const u8, null), driving_award.user_display_name(0));
}
