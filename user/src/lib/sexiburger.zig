//! VirelaiOS Sexiburger Standalone Menu Component (Milestone 19, Issues #677, #702, #704).
//!
//! One corner menu merging the macOS Apple menu + app menu bar + Windows Start menu,
//! raised by BeOS's Deskbar into a single well-organized god menu.
//!
//! Invariants:
//! 1. Zero-pixel idle footprint: costs zero pixels until summoned.
//! 2. One chord to open (or toggle / click).
//! 3. The Covenant of Six: exactly 6 sections at fixed, invariant positions
//!    (System, Apps, Active app, Windows & tabs, Services, Power).
//! 4. Type-to-filter: instant search across all registered commands with
//!    Quicksilver abbreviation matching.
//! 5. Mascot emblem: 6-layer burger + 6 tentacles rendered natively.

const std = @import("std");
const ui = @import("ui.zig");
const Rect = ui.Rect;
const Event = ui.Event;
const action_reg = @import("action_registry.zig");
pub const SectionId = action_reg.SectionId;
pub const Command = action_reg.Command;
pub const ActionRegistry = action_reg.ActionRegistry;
pub const FilterResult = action_reg.FilterResult;

pub const menu_default_width: u32 = 488;
pub const menu_default_height: u32 = 316;

pub const SexiburgerMenu = struct {
    rect: Rect,
    open: bool = false,
    registry: ActionRegistry,

    // Type-to-filter search buffer
    search_buf: [64]u8 = @as([64]u8, @splat(@as(u8, 0))),
    search_len: usize = 0,

    // Filter results cache
    filtered: [32]FilterResult = undefined,
    filtered_count: usize = 0,

    // Navigation & selection
    selected_filter_idx: usize = 0,
    hovered_section: ?SectionId = null,
    hovered_cmd_id: ?u16 = null,
    last_invoked_cmd: ?Command = null,
    raster_mascot: ?ui.Image = null,

    pub fn init(rect: Rect) SexiburgerMenu {
        var menu = SexiburgerMenu{
            .rect = rect,
            .open = false,
            .registry = ActionRegistry.init(),
        };
        menu.update_filter();
        return menu;
    }

    pub fn is_open(self: *const SexiburgerMenu) bool {
        return self.open;
    }

    /// Costs ZERO pixels until summoned (Issue #702 acceptance criteria).
    pub fn visual_bounds(self: *const SexiburgerMenu) Rect {
        if (!self.open) {
            return Rect.make(self.rect.x, self.rect.y, 0, 0);
        }
        return self.rect;
    }

    pub fn show(self: *SexiburgerMenu) void {
        self.open = true;
        self.search_len = 0;
        self.selected_filter_idx = 0;
        self.hovered_section = null;
        self.hovered_cmd_id = null;
        self.update_filter();
    }

    pub fn dismiss(self: *SexiburgerMenu) void {
        self.open = false;
        self.search_len = 0;
        self.hovered_section = null;
        self.hovered_cmd_id = null;
    }

    pub fn toggle(self: *SexiburgerMenu) void {
        if (self.open) {
            self.dismiss();
        } else {
            self.show();
        }
    }

    pub fn get_search_query(self: *const SexiburgerMenu) []const u8 {
        return self.search_buf[0..self.search_len];
    }

    pub fn set_search_query(self: *SexiburgerMenu, query: []const u8) void {
        const copy_len = @min(query.len, self.search_buf.len);
        @memcpy(self.search_buf[0..copy_len], query[0..copy_len]);
        self.search_len = copy_len;
        self.selected_filter_idx = 0;
        self.update_filter();
    }

    pub fn clear_search(self: *SexiburgerMenu) void {
        self.search_len = 0;
        self.selected_filter_idx = 0;
        self.update_filter();
    }

    pub fn update_filter(self: *SexiburgerMenu) void {
        const q = self.get_search_query();
        self.filtered_count = self.registry.filter(q, &self.filtered);
        if (self.selected_filter_idx >= self.filtered_count and self.filtered_count > 0) {
            self.selected_filter_idx = self.filtered_count - 1;
        }
    }

    // -----------------------------------------------------------------------
    // Invariant Section Layout Geometry (Issue #702)
    // -----------------------------------------------------------------------

    pub const header_h: u32 = 36;
    pub const search_bar_h: u32 = 28;
    pub const footer_h: u32 = 20;

    /// Invariant computed layout positions for the 6 sections (2 columns x 3 rows).
    pub fn section_slot_rect(self: *const SexiburgerMenu, sec: SectionId) Rect {
        const base_x = self.rect.x + 12;
        const base_y = self.rect.y + header_h + search_bar_h + 8;
        const col_w: u32 = if (self.rect.w > 36) (self.rect.w - 32) / 2 else 120;
        const col_gap: u32 = 8;
        const row_h: u32 = if (self.rect.h > (header_h + search_bar_h + footer_h + 36))
            (self.rect.h - (header_h + search_bar_h + footer_h + 36)) / 3
        else
            80;
        const row_gap: u32 = 6;

        return switch (sec) {
            // Left column (Sections 0, 1, 2)
            .system => Rect.make(base_x, base_y + 0 * (row_h + row_gap), col_w, row_h),
            .apps => Rect.make(base_x, base_y + 1 * (row_h + row_gap), col_w, row_h),
            .active_app => Rect.make(base_x, base_y + 2 * (row_h + row_gap), col_w, row_h),

            // Right column (Sections 3, 4, 5)
            .windows_tabs => Rect.make(base_x + col_w + col_gap, base_y + 0 * (row_h + row_gap), col_w, row_h),
            .services => Rect.make(base_x + col_w + col_gap, base_y + 1 * (row_h + row_gap), col_w, row_h),
            .power => Rect.make(base_x + col_w + col_gap, base_y + 2 * (row_h + row_gap), col_w, row_h),
        };
    }

    pub fn search_bar_rect(self: *const SexiburgerMenu) Rect {
        return Rect.make(self.rect.x + 12, self.rect.y + header_h + 4, if (self.rect.w > 24) self.rect.w - 24 else 100, 24);
    }

    // -----------------------------------------------------------------------
    // Event Handling
    // -----------------------------------------------------------------------

    pub fn handle_event(self: *SexiburgerMenu, ev: *const Event) bool {
        // Chord detection when closed: Super / Cmd / Alt+Space / Ctrl+Space / Ctrl+B
        // keycodes: 0x2c is Space, 0x05 is 'b', 0x29 is Esc
        const is_chord = (ev.flags & (ui.MOD_CMD | ui.MOD_ALT | ui.MOD_CTRL)) != 0 and
            (ev.arg0 == 0x2c or ev.arg0 == 0x05 or ev.arg0 == 0x29);

        if (!self.open) {
            if (ev.kind == ui.KEY_DOWN and is_chord) {
                self.show();
                return true;
            }
            return false;
        }

        switch (ev.kind) {
            ui.KEY_DOWN => {
                const keycode = ev.arg0;
                const ascii_char: u8 = if (ev.arg1 <= 0x7f) @intCast(ev.arg1) else 0;

                // Chord toggles/dismisses menu
                if (is_chord and keycode == 0x05) {
                    self.dismiss();
                    return true;
                }

                // Escape -> dismiss
                if (keycode == 0x29) {
                    self.dismiss();
                    return true;
                }

                // Enter -> execute currently selected command
                if (keycode == 0x28) {
                    return self.execute_selected();
                }

                // Up arrow -> select previous
                if (keycode == 0x52) {
                    if (self.filtered_count > 0) {
                        if (self.selected_filter_idx > 0) {
                            self.selected_filter_idx -= 1;
                        } else {
                            self.selected_filter_idx = self.filtered_count - 1;
                        }
                    }
                    return true;
                }

                // Down arrow -> select next
                if (keycode == 0x51) {
                    if (self.filtered_count > 0) {
                        if (self.selected_filter_idx + 1 < self.filtered_count) {
                            self.selected_filter_idx += 1;
                        } else {
                            self.selected_filter_idx = 0;
                        }
                    }
                    return true;
                }

                // Backspace -> delete character in search filter
                if (ascii_char == 0x08 or keycode == 0x2a) {
                    if (self.search_len > 0) {
                        self.search_len -= 1;
                        self.update_filter();
                        return true;
                    }
                    return true;
                }

                // Printable character insertion for type-to-filter
                if (ascii_char >= 0x20 and ascii_char <= 0x7e) {
                    if (self.search_len < self.search_buf.len) {
                        self.search_buf[self.search_len] = ascii_char;
                        self.search_len += 1;
                        self.update_filter();
                        return true;
                    }
                }

                return true; // Consume keys while menu is open
            },

            ui.MOUSE_DOWN => {
                const mx = ev.arg0;
                const my = ev.arg1;

                // Click outside menu -> dismiss (modal behavior)
                if (!self.rect.contains(mx, my)) {
                    self.dismiss();
                    return true;
                }

                // Check click on items
                if (self.search_len > 0) {
                    // Filtered list view hit-test
                    if (self.hit_test_filtered_list(mx, my)) |idx| {
                        self.selected_filter_idx = idx;
                        return self.execute_selected();
                    }
                } else {
                    // Invariant section slot hit-test
                    if (self.hit_test_section_item(mx, my)) |cmd| {
                        self.last_invoked_cmd = cmd;
                        _ = self.registry.invoke_command(cmd.id);
                        self.dismiss();
                        return true;
                    }
                }

                return true;
            },

            ui.MOUSE_MOVE => {
                const mx = ev.arg0;
                const my = ev.arg1;

                if (!self.rect.contains(mx, my)) {
                    self.hovered_section = null;
                    self.hovered_cmd_id = null;
                    return false;
                }

                if (self.search_len > 0) {
                    if (self.hit_test_filtered_list(mx, my)) |idx| {
                        self.selected_filter_idx = idx;
                    }
                } else {
                    self.update_hover(mx, my);
                }

                return true;
            },

            else => return false,
        }
    }

    fn execute_selected(self: *SexiburgerMenu) bool {
        if (self.filtered_count > 0 and self.selected_filter_idx < self.filtered_count) {
            const cmd = self.filtered[self.selected_filter_idx].command;
            self.last_invoked_cmd = cmd;
            _ = self.registry.invoke_command(cmd.id);
            self.dismiss();
            return true;
        }
        return false;
    }

    fn hit_test_filtered_list(self: *const SexiburgerMenu, mx: u32, my: u32) ?usize {
        const list_x = self.rect.x + 12;
        const list_w = if (self.rect.w > 24) self.rect.w - 24 else 200;
        if (mx < list_x or mx >= list_x + list_w) return null;

        const start_y = self.rect.y + header_h + search_bar_h + 8;
        const row_h: u32 = 18;
        if (my < start_y) return null;
        const idx = (my - start_y) / row_h;
        if (idx < self.filtered_count) {
            return idx;
        }
        return null;
    }

    fn hit_test_section_item(self: *const SexiburgerMenu, mx: u32, my: u32) ?Command {
        for (0..SectionId.count) |i| {
            const sec = SectionId.from_index(i).?;
            const srect = self.section_slot_rect(sec);
            if (srect.contains(mx, my)) {
                var cmds: [action_reg.max_commands_per_section]Command = undefined;
                const n = self.registry.get_section_commands(sec, &cmds);
                const item_start_y = srect.y + 18;
                const item_h: u32 = 16;
                if (my >= item_start_y) {
                    const idx = (my - item_start_y) / item_h;
                    if (idx < n) {
                        return cmds[idx];
                    }
                }
            }
        }
        return null;
    }

    fn update_hover(self: *SexiburgerMenu, mx: u32, my: u32) void {
        for (0..SectionId.count) |i| {
            const sec = SectionId.from_index(i).?;
            const srect = self.section_slot_rect(sec);
            if (srect.contains(mx, my)) {
                self.hovered_section = sec;
                var cmds: [action_reg.max_commands_per_section]Command = undefined;
                const n = self.registry.get_section_commands(sec, &cmds);
                const item_start_y = srect.y + 18;
                const item_h: u32 = 16;
                if (my >= item_start_y) {
                    const idx = (my - item_start_y) / item_h;
                    if (idx < n) {
                        self.hovered_cmd_id = cmds[idx].id;
                        return;
                    }
                }
                self.hovered_cmd_id = null;
                return;
            }
        }
        self.hovered_section = null;
        self.hovered_cmd_id = null;
    }

    // -----------------------------------------------------------------------
    // Drawing & Mascot Graphics (Milestone 19 Acceptance Criteria)
    // -----------------------------------------------------------------------

    pub fn draw(self: *const SexiburgerMenu, win_id: u32) void {
        // Zero-pixel idle footprint: costs zero pixels when not open!
        if (!self.open) return;

        // 1. Menu Frame
        ui.draw_rect(win_id, self.rect, ui.theme_surface());
        ui.draw_rect_outline(win_id, self.rect, 2, ui.theme_accent());

        // 2. Mascot Header
        self.draw_mascot_header(win_id);

        // 3. Search Bar (Type-to-filter)
        self.draw_search_bar(win_id);

        // 4. Body Content
        if (self.search_len > 0) {
            self.draw_filtered_view(win_id);
        } else {
            self.draw_invariant_sections(win_id);
        }

        // 5. Footer Status
        self.draw_footer(win_id);
    }

    fn draw_mascot_header(self: *const SexiburgerMenu, win_id: u32) void {
        const h_rect = Rect.make(self.rect.x, self.rect.y, self.rect.w, header_h);
        ui.draw_rect(win_id, h_rect, ui.theme_bg());
        ui.draw_rect(win_id, Rect.make(self.rect.x, self.rect.y + header_h - 1, self.rect.w, 1), ui.theme_border());

        // Draw Sexiburger 6-layer 6-tentacle graphic emblem (left side)
        const emblem_x = self.rect.x + 8;
        const emblem_y = self.rect.y + 6;
        if (self.raster_mascot) |img| {
            ui.draw_image(win_id, emblem_x, emblem_y, img);
        } else {
            draw_sexiburger_emblem(win_id, emblem_x, emblem_y);
        }

        // Title and lore tag
        ui.draw_text(win_id, "SEXIBURGER", emblem_x + 36, self.rect.y + 8, ui.theme_accent());
        ui.draw_text(win_id, "The Covenant of Six (6 layers * 6 tentacles)", emblem_x + 36, self.rect.y + 20, ui.theme_text_muted());

        // Close indicator button on far right
        const close_x = self.rect.x + self.rect.w - 24;
        ui.draw_text(win_id, "[x]", close_x, self.rect.y + 12, ui.theme_text_muted());
    }

    fn draw_search_bar(self: *const SexiburgerMenu, win_id: u32) void {
        const srect = self.search_bar_rect();
        ui.draw_rect(win_id, srect, ui.theme_bg());
        ui.draw_rect_outline(win_id, srect, 1, ui.theme_border());

        const icon_x = srect.x + 6;
        const text_x = srect.x + 22;
        const text_y = srect.y + 8;

        ui.draw_text(win_id, ">", icon_x, text_y, ui.theme_accent());

        const q = self.get_search_query();
        if (q.len > 0) {
            ui.draw_text(win_id, q, text_x, text_y, ui.theme_text_primary());
            // Cursor
            const cursor_x = text_x + ui.measure_text(q);
            ui.draw_rect(win_id, Rect.make(cursor_x, text_y, 2, 10), ui.theme_accent());
        } else {
            ui.draw_text(win_id, "Filter commands / verbs (e.g. sysinfo, save, new-tab)...", text_x, text_y, ui.theme_text_muted());
        }
    }

    fn draw_invariant_sections(self: *const SexiburgerMenu, win_id: u32) void {
        for (0..SectionId.count) |i| {
            const sec = SectionId.from_index(i).?;
            const srect = self.section_slot_rect(sec);

            // Section tile container
            const is_sec_hovered = (self.hovered_section == sec);
            ui.draw_rect(win_id, srect, if (is_sec_hovered) ui.theme_bg() else ui.theme_surface());
            ui.draw_rect_outline(win_id, srect, 1, if (is_sec_hovered) ui.theme_accent() else ui.theme_border());

            // Section header strip
            const hdr_h: u32 = 18;
            const hdr_rect = Rect.make(srect.x, srect.y, srect.w, hdr_h);
            ui.draw_rect(win_id, hdr_rect, ui.theme_bg());
            ui.draw_rect(win_id, Rect.make(srect.x, srect.y + hdr_h - 1, srect.w, 1), ui.theme_border());

            // Color bar representing the burger layer (Crown, Lettuce, Tomato, Cheese, Patty, Heel)
            const layer_color = get_layer_color(sec);
            ui.draw_rect(win_id, Rect.make(srect.x + 2, srect.y + 2, 4, hdr_h - 4), layer_color);

            // Header text: Name + layer
            ui.draw_text(win_id, sec.name(), srect.x + 10, srect.y + 5, ui.theme_text_primary());
            ui.draw_text(win_id, sec.layer_name(), srect.x + srect.w - 60, srect.y + 5, ui.theme_text_muted());

            // List items for this section
            var cmds: [action_reg.max_commands_per_section]Command = undefined;
            const n = self.registry.get_section_commands(sec, &cmds);
            var item_y = srect.y + hdr_h + 3;

            for (0..n) |ci| {
                const cmd = cmds[ci];
                const is_item_hovered = (self.hovered_cmd_id == cmd.id);

                if (is_item_hovered) {
                    ui.draw_rect(win_id, Rect.make(srect.x + 2, item_y - 1, srect.w - 4, 14), ui.theme_btn_hover());
                }

                // Command label
                ui.draw_text(win_id, cmd.label, srect.x + 8, item_y + 2, if (is_item_hovered) ui.theme_accent() else ui.theme_text_primary());

                // Shortcut or verb on right
                if (cmd.shortcut.len > 0) {
                    const sc_w = ui.measure_text(cmd.shortcut);
                    const sc_x = if (srect.w > sc_w + 10) srect.x + srect.w - sc_w - 6 else srect.x + 120;
                    ui.draw_text(win_id, cmd.shortcut, sc_x, item_y + 2, ui.theme_text_muted());
                } else if (cmd.verb.len > 0) {
                    const vb_w = ui.measure_text(cmd.verb);
                    const vb_x = if (srect.w > vb_w + 10) srect.x + srect.w - vb_w - 6 else srect.x + 120;
                    ui.draw_text(win_id, cmd.verb, vb_x, item_y + 2, ui.theme_text_muted());
                }

                item_y += 15;
            }
        }
    }

    fn draw_filtered_view(self: *const SexiburgerMenu, win_id: u32) void {
        const list_x = self.rect.x + 12;
        const list_y = self.rect.y + header_h + search_bar_h + 8;
        const list_w = if (self.rect.w > 24) self.rect.w - 24 else 200;
        const list_h = if (self.rect.h > (header_h + search_bar_h + footer_h + 16))
            self.rect.h - (header_h + search_bar_h + footer_h + 16)
        else
            150;

        const container_rect = Rect.make(list_x, list_y, list_w, list_h);
        ui.draw_rect(win_id, container_rect, ui.theme_bg());
        ui.draw_rect_outline(win_id, container_rect, 1, ui.theme_border());

        if (self.filtered_count == 0) {
            ui.draw_text(win_id, "No matching commands found.", list_x + 16, list_y + 20, ui.theme_text_muted());
            return;
        }

        var cur_y = list_y + 4;
        const row_h: u32 = 18;
        const max_visible = list_h / row_h;
        const limit = @min(self.filtered_count, max_visible);

        for (0..limit) |idx| {
            const item = self.filtered[idx];
            const is_selected = (idx == self.selected_filter_idx);
            const row_rect = Rect.make(list_x + 2, cur_y, list_w - 4, row_h - 2);

            if (is_selected) {
                ui.draw_rect(win_id, row_rect, ui.theme_btn_hover());
                ui.draw_rect_outline(win_id, row_rect, 1, ui.theme_accent());
            }

            // Section badge (e.g. [SYS], [APP], [WIN])
            ui.draw_text(win_id, item.command.section.icon(), list_x + 6, cur_y + 4, ui.theme_accent());

            // Label
            ui.draw_text(win_id, item.command.label, list_x + 50, cur_y + 4, if (is_selected) ui.theme_accent() else ui.theme_text_primary());

            // Shell verb
            if (item.command.verb.len > 0) {
                ui.draw_text(win_id, item.command.verb, list_x + 260, cur_y + 4, ui.theme_text_muted());
            }

            // Shortcut
            if (item.command.shortcut.len > 0) {
                const sc_w = ui.measure_text(item.command.shortcut);
                const sc_x = if (list_w > sc_w + 12) list_x + list_w - sc_w - 8 else list_x + 380;
                ui.draw_text(win_id, item.command.shortcut, sc_x, cur_y + 4, ui.theme_text_muted());
            }

            cur_y += row_h;
        }
    }

    fn draw_footer(self: *const SexiburgerMenu, win_id: u32) void {
        const foot_y = self.rect.y + self.rect.h - footer_h;
        const foot_rect = Rect.make(self.rect.x, foot_y, self.rect.w, footer_h);
        ui.draw_rect(win_id, foot_rect, ui.theme_bg());
        ui.draw_rect(win_id, Rect.make(self.rect.x, foot_y, self.rect.w, 1), ui.theme_border());

        ui.draw_text(win_id, "6 Sections * 6 Tentacles (Covenant of Six)", self.rect.x + 12, foot_y + 6, ui.theme_text_muted());
        const help_txt = "Esc: Close  Enter: Run  Up/Down: Navigate";
        const help_w = ui.measure_text(help_txt);
        const help_x = if (self.rect.w > help_w + 16) self.rect.x + self.rect.w - help_w - 12 else self.rect.x + 200;
        ui.draw_text(win_id, help_txt, help_x, foot_y + 6, ui.theme_text_muted());
    }
};

/// Color mapping for the 6 burger layers.
pub fn get_layer_color(sec: SectionId) u32 {
    return switch (sec) {
        .system => 0xD89632, // Crown bun: golden amber
        .apps => 0x4CAF50, // Lettuce: crisp green
        .active_app => 0xE53935, // Tomato: red
        .windows_tabs => 0xFDD835, // Cheese: cheddar yellow
        .services => 0x6D4C41, // Patty: beef brown
        .power => 0xC88628, // Heel bun: baked crust
    };
}

/// Native pixel drawing of the Sexiburger mascot emblem:
/// 6 burger layers + 6 tentacles (3 left, 3 right).
pub fn draw_sexiburger_emblem(win_id: u32, x: u32, y: u32) void {
    // 6 tentacles: 3 on left, 3 on right
    // Tentacle colors: 0xFF9800
    const tentacle_color: u32 = 0xF57C00;

    // Left tentacles (upper, mid, lower-curl-in)
    ui.draw_rect(win_id, Rect.make(x, y + 2, 4, 3), tentacle_color);
    ui.draw_rect(win_id, Rect.make(x - 2, y + 5, 4, 3), tentacle_color);
    ui.draw_rect(win_id, Rect.make(x - 4, y + 8, 4, 4), tentacle_color);

    ui.draw_rect(win_id, Rect.make(x - 3, y + 13, 4, 3), tentacle_color);
    ui.draw_rect(win_id, Rect.make(x - 1, y + 16, 4, 3), tentacle_color);
    ui.draw_rect(win_id, Rect.make(x + 1, y + 19, 4, 3), tentacle_color);

    // Right tentacles (upper, mid, lower-curl-in)
    const rx = x + 20;
    ui.draw_rect(win_id, Rect.make(rx, y + 2, 4, 3), tentacle_color);
    ui.draw_rect(win_id, Rect.make(rx + 2, y + 5, 4, 3), tentacle_color);
    ui.draw_rect(win_id, Rect.make(rx + 4, y + 8, 4, 4), tentacle_color);

    ui.draw_rect(win_id, Rect.make(rx + 3, y + 13, 4, 3), tentacle_color);
    ui.draw_rect(win_id, Rect.make(rx + 1, y + 16, 4, 3), tentacle_color);
    ui.draw_rect(win_id, Rect.make(rx - 1, y + 19, 4, 3), tentacle_color);

    // 6-layer Burger Body (x + 2 .. x + 18)
    const bx = x + 3;
    const bw: u32 = 18;

    // Layer 1: Crown Bun
    ui.draw_rect(win_id, Rect.make(bx + 2, y + 1, bw - 4, 2), 0xD89632);
    ui.draw_rect(win_id, Rect.make(bx, y + 3, bw, 3), 0xD89632);

    // Layer 2: Lettuce
    ui.draw_rect(win_id, Rect.make(bx - 1, y + 6, bw + 2, 3), 0x4CAF50);

    // Layer 3: Tomato
    ui.draw_rect(win_id, Rect.make(bx + 1, y + 9, bw - 2, 3), 0xE53935);

    // Layer 4: Cheese
    ui.draw_rect(win_id, Rect.make(bx, y + 12, bw, 3), 0xFDD835);

    // Layer 5: Patty
    ui.draw_rect(win_id, Rect.make(bx + 1, y + 15, bw - 2, 4), 0x6D4C41);

    // Layer 6: Heel Bun
    ui.draw_rect(win_id, Rect.make(bx + 1, y + 19, bw - 2, 3), 0xC88628);
}

/// Blit a raster image mascot emblem using ui.draw_image.
pub fn draw_sexiburger_raster_emblem(win_id: u32, x: u32, y: u32, img: ui.Image) void {
    ui.draw_image(win_id, x, y, img);
}

// ---------------------------------------------------------------------------
// Manifest → menu apps (M37 DQ1, issue #836)
// ---------------------------------------------------------------------------
// The same `NAME.BIN | Display Name | icon-char | dock=true` wire format
// `desktop.zig:parse_manifest` reads (comments + blanks ignored) — a
// different consumer (menu entries, not launcher rows), so the parser lives
// here next to its tests rather than importing an app binary. Entries are
// slices into `text`; the caller (WND.BIN) keeps its static manifest buffer
// alive across populates. Pure and host-testable.

/// One launchable app as the God Menu sees it.
pub const MenuApp = struct {
    name: []const u8 = "",
    desc: []const u8 = "",
    dock: bool = false,
};

/// Registry section cap: the apps section holds at most this many entries.
pub const menu_apps_max: usize = 16;

/// The manifest read budget, shared by every reader of APPS.TXT: WND.BIN's
/// god-menu buffer, TABWM.BIN's overlay buffer, and the Go seat's
/// `appsMaxBytes`. It is ONE constant because the failure is silent: a
/// manifest bigger than a reader's buffer is cut at the last whole line that
/// fits, so the tail rows simply stop existing in that seat's menu — no
/// error, no marker, just a shorter list. The readers used to carry their own
/// 1024 B copies of this number and M82a (#1768) grew the file past all of
/// them; the test at the bottom of this file pins the real file under it, so
/// the next card that adds rows has to move this number rather than discover
/// the truncation in a screenshot.
pub const manifest_buf_max: usize = 4096;

/// Parse manifest text into `out`, returning the entry count (capped at
/// `out.len`). Malformed lines (fewer than 2 fields, empty name/desc) are
/// skipped, never trapped.
pub fn parse_apps_manifest(text: []const u8, out: []MenuApp) usize {
    var count: usize = 0;
    var line_start: usize = 0;
    while (line_start <= text.len and count < out.len) {
        var line_end = line_start;
        while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}
        const line = text[line_start..line_end];

        var s: usize = 0;
        while (s < line.len and (line[s] == ' ' or line[s] == '\t' or line[s] == '\r')) : (s += 1) {}
        if (s < line.len and line[s] != '#') {
            const content = line[s..];
            var fields: [4][]const u8 = undefined;
            var field_count: usize = 0;
            var fstart: usize = 0;
            var i: usize = 0;
            while (i <= content.len and field_count < 4) : (i += 1) {
                if (i == content.len or content[i] == '|') {
                    fields[field_count] = trim_field(content[fstart..i]);
                    field_count += 1;
                    fstart = i + 1;
                }
            }
            if (field_count >= 2 and fields[0].len > 0 and fields[1].len > 0) {
                out[count] = .{
                    .name = fields[0],
                    .desc = fields[1],
                    .dock = field_count >= 4 and std.mem.eql(u8, fields[3], "dock=true"),
                };
                count += 1;
            }
        }
        if (line_end == text.len) break;
        line_start = line_end + 1;
    }
    return count;
}

fn trim_field(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t' or s[start] == '\r')) : (start += 1) {}
    var end = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[start..end];
}

// ---------------------------------------------------------------------------
// Host Unit Tests
// ---------------------------------------------------------------------------

test "sexiburger menu: zero-pixel idle footprint until summoned" {
    const rect = Rect.make(10, 10, menu_default_width, menu_default_height);
    var menu = SexiburgerMenu.init(rect);

    try std.testing.expect(!menu.is_open());
    const idle_bounds = menu.visual_bounds();
    try std.testing.expectEqual(@as(u32, 0), idle_bounds.w);
    try std.testing.expectEqual(@as(u32, 0), idle_bounds.h);

    menu.show();
    try std.testing.expect(menu.is_open());
    const open_bounds = menu.visual_bounds();
    try std.testing.expectEqual(menu_default_width, open_bounds.w);
    try std.testing.expectEqual(menu_default_height, open_bounds.h);

    menu.dismiss();
    try std.testing.expect(!menu.is_open());
    try std.testing.expectEqual(@as(u32, 0), menu.visual_bounds().w);
}

test "sexiburger menu: chord open and dismiss" {
    const rect = Rect.make(10, 10, menu_default_width, menu_default_height);
    var menu = SexiburgerMenu.init(rect);

    // Ordinary key does not open
    var ev_key = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x05, .arg1 = 'b' };
    _ = menu.handle_event(&ev_key);
    try std.testing.expect(!menu.is_open());

    // Chord (MOD_CMD + 'b') opens menu
    var ev_chord = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CMD, .seq = 2, .arg0 = 0x05, .arg1 = 'b' };
    const handled = menu.handle_event(&ev_chord);
    try std.testing.expect(handled);
    try std.testing.expect(menu.is_open());

    // Escape closes menu
    var ev_esc = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x29, .arg1 = 0x1b };
    _ = menu.handle_event(&ev_esc);
    try std.testing.expect(!menu.is_open());
}

test "sexiburger menu: six sections at invariant positions" {
    const rect = Rect.make(0, 0, 560, 420);
    const menu = SexiburgerMenu.init(rect);

    const r_sys = menu.section_slot_rect(.system);
    const r_app = menu.section_slot_rect(.apps);
    const r_act = menu.section_slot_rect(.active_app);
    const r_win = menu.section_slot_rect(.windows_tabs);
    const r_srv = menu.section_slot_rect(.services);
    const r_pwr = menu.section_slot_rect(.power);

    // Left column positions
    try std.testing.expectEqual(r_sys.x, r_app.x);
    try std.testing.expectEqual(r_app.x, r_act.x);

    // Right column positions
    try std.testing.expectEqual(r_win.x, r_srv.x);
    try std.testing.expectEqual(r_srv.x, r_pwr.x);
    try std.testing.expect(r_win.x > r_sys.x);

    // Row positions
    try std.testing.expectEqual(r_sys.y, r_win.y);
    try std.testing.expectEqual(r_app.y, r_srv.y);
    try std.testing.expectEqual(r_act.y, r_pwr.y);

    try std.testing.expect(r_app.y > r_sys.y);
    try std.testing.expect(r_act.y > r_app.y);
}

test "sexiburger menu: type-to-filter interaction" {
    const rect = Rect.make(10, 10, menu_default_width, menu_default_height);
    var menu = SexiburgerMenu.init(rect);
    menu.show();

    // Type 's' then 'y' then 's'
    var ev_s = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x16, .arg1 = 's' };
    var ev_y = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x1c, .arg1 = 'y' };
    _ = menu.handle_event(&ev_s);
    _ = menu.handle_event(&ev_y);
    _ = menu.handle_event(&ev_s);

    try std.testing.expectEqualStrings("sys", menu.get_search_query());
    try std.testing.expect(menu.filtered_count >= 1);
    try std.testing.expectEqualStrings("System Info", menu.filtered[0].command.label);

    // Enter executes selected command
    var ev_enter = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x28, .arg1 = '\r' };
    _ = menu.handle_event(&ev_enter);
    try std.testing.expect(!menu.is_open());
    try std.testing.expect(menu.last_invoked_cmd != null);
    try std.testing.expectEqualStrings("System Info", menu.last_invoked_cmd.?.label);
}

test "sexiburger menu: raster mascot emblem integration" {
    const fixture_bytes = @embedFile("fixtures/qoi/mascot_24x24.qoi");
    var mascot_pixels: [24 * 24]u32 = undefined;
    const mascot_img = try ui.image.decode(fixture_bytes, &mascot_pixels);

    try std.testing.expectEqual(@as(u32, 24), mascot_img.width);
    try std.testing.expectEqual(@as(u32, 24), mascot_img.height);

    var menu = SexiburgerMenu.init(Rect.make(0, 0, menu_default_width, menu_default_height));
    menu.raster_mascot = mascot_img;
    menu.show();

    ui.fill_batcher.reset();
    ui.fill_batcher.cur_id = 0;

    menu.draw(1);

    // Should have emitted fill batches for header, background, and the raster mascot
    try std.testing.expect(ui.fill_batcher.len > 0);
    ui.fill_batcher.reset();
}

test "sexiburger manifest: parses apps, skips comments/blanks/malformed" {
    const text =
        \\# comment line
        \\
        \\GOCALC.ELF | Calculator | c | dock=true
        \\NOTEPAD.BIN|Text Editor|n
        \\MALFORMED-NO-PIPE
        \\ | Empty Name | x
        \\FILE.BIN | File Browser | b |
        \\
    ;
    var out: [menu_apps_max]MenuApp = undefined;
    const n = parse_apps_manifest(text, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("GOCALC.ELF", out[0].name);
    try std.testing.expectEqualStrings("Calculator", out[0].desc);
    try std.testing.expect(out[0].dock);
    try std.testing.expectEqualStrings("NOTEPAD.BIN", out[1].name);
    try std.testing.expect(!out[1].dock);
    try std.testing.expectEqualStrings("FILE.BIN", out[2].name);
}

test "sexiburger manifest: empty text yields zero, overlong input caps at out.len" {
    var out: [menu_apps_max]MenuApp = undefined;
    try std.testing.expectEqual(@as(usize, 0), parse_apps_manifest("", &out));

    var tiny: [2]MenuApp = undefined;
    const n = parse_apps_manifest("A.BIN | A | a\nB.BIN | B | b\nC.BIN | C | c\n", &tiny);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("A.BIN", tiny[0].name);
    try std.testing.expectEqualStrings("B.BIN", tiny[1].name);
}

// --- M82a (#1768): the real manifest, and the two Zig mirrors -------------
//
// These are the pins the card asks for, kept HERE rather than in the two
// reader call sites for a plain reason: this is the module whose
// `parse_apps_manifest` every Zig seat actually runs, and this file is the
// only one of the three whose tests a gate executes
// (tools/verify-unit-tests.sh runs `zig test user/src/sexiburger.zig`).
// A pin in a test root nothing runs is a comment with braces.

/// Read `image/apps.txt` from the repo root. The direct `zig test` runs with
/// the repo root as its working directory; the `../../` form is for a runner
/// that sets it to the module's own directory. Neither existing, so the file
/// is reported missing rather than skipped.
fn readRepoManifest(io: anytype, allocator: std.mem.Allocator) ![]u8 {
    const limit = std.Io.Limit.limited(manifest_buf_max);
    return std.Io.Dir.cwd().readFileAlloc(io, "image/apps.txt", allocator, limit) catch |err| switch (err) {
        error.FileNotFound => std.Io.Dir.cwd().readFileAlloc(
            io,
            "../../image/apps.txt",
            allocator,
            limit,
        ) catch |err2| {
            std.debug.print("sexiburger: image/apps.txt is not readable from this " ++
                "working directory ({s}, then {s})\n", .{ @errorName(err), @errorName(err2) });
            return err2;
        },
        else => |e| e,
    };
}

test "sexiburger manifest: the real image/apps.txt fits the shared read budget" {
    const allocator = std.testing.allocator;
    var io_impl = std.Io.Threaded.init_single_threaded;
    const text = try readRepoManifest(io_impl.io(), allocator);
    defer allocator.free(text);

    // The pin itself. A file at or over manifest_buf_max would be truncated
    // at the last whole line in every reader, so this is the property that
    // keeps a longer manifest from quietly losing its tail rows.
    try std.testing.expect(text.len > 0);
    try std.testing.expect(text.len < manifest_buf_max);
}

test "sexiburger manifest: the real image/apps.txt decodes whole under the v1 four fields" {
    const allocator = std.testing.allocator;
    var io_impl = std.Io.Threaded.init_single_threaded;
    const text = try readRepoManifest(io_impl.io(), allocator);
    defer allocator.free(text);

    // Every row must survive, not just the ones that fit a smaller buffer:
    // the v2 schema (M82a) added TRAILING fields to rows, and this reader
    // reads at most four, so a full parse here is the proof that the
    // additive change is invisible to the Zig seats.
    var out: [64]MenuApp = undefined;
    const n = parse_apps_manifest(text, &out);
    try std.testing.expectEqual(@as(usize, 20), n);

    // The dock set is what the mirrors claim about this file. WND.BIN's
    // god-menu selection test says "8 dock + dup stems past the cutoff" and
    // the kernel dock renderer says "first 5 from image/apps.txt" — the
    // first number is only true while this file has exactly 8 docked rows,
    // so it is pinned here against the real file rather than left to a
    // synthetic 22-entry fixture that can drift from it unnoticed.
    var dock: usize = 0;
    for (out[0..n]) |app| {
        if (app.dock) dock += 1;
        try std.testing.expect(app.name.len > 0);
        try std.testing.expect(app.desc.len > 0);
    }
    try std.testing.expectEqual(@as(usize, 8), dock);

    // The manifest's own contract: a v2 row declares its version in field 5,
    // which no reader above looks at, and every row still has a name and a
    // label in the first two.
    try std.testing.expect(std.mem.indexOf(u8, text, " | v=2 ") != null);
}
