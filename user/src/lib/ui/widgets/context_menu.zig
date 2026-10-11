//! ContextMenu and Menu Builder UI widgets (GH #228, Arc2 W2, M27 G9, M41 TS2).
const std = @import("std");
pub const abi = @import("../abi.zig");
pub const theme = @import("../theme.zig");
pub const draw = @import("../draw.zig");

// ABI types & constants
const Event = abi.Event;
const KEY_DOWN = abi.KEY_DOWN;
const MOUSE_DOWN = abi.MOUSE_DOWN;
const MOUSE_MOVE = abi.MOUSE_MOVE;
const MOUSE_RIGHT_DOWN = abi.MOUSE_RIGHT_DOWN;
const MOUSE_RIGHT_UP = abi.MOUSE_RIGHT_UP;
const win_fill = abi.win_fill;

// Theme tokens & styling
const theme_border = theme.theme_border;
const theme_btn_hover = theme.theme_btn_hover;
const theme_surface = theme.theme_surface;
const theme_text_muted = theme.theme_text_muted;
const theme_text_primary = theme.theme_text_primary;

// Draw operations
const Rect = draw.Rect;
const draw_rect = draw.draw_rect;
const draw_rect_outline = draw.draw_rect_outline;
const draw_text = draw.draw_text;

// ---------------------------------------------------------------------------
// Component: ContextMenu & Menu Builder (GH #228, Arc2 W2, M27 G9 #452)
// ---------------------------------------------------------------------------

pub const CanonicalMenuCategory = enum {
    file,
    edit,
    view,
    help,
};

pub const canonical_menu_bar = [_][]const u8{ "File", "Edit", "View", "Help" };

pub const StandardShortcut = struct {
    pub const save = "Ctrl+S";
    pub const open = "Ctrl+O";
    pub const quit = "Ctrl+Q";
    pub const undo = "Ctrl+Z";
    pub const redo = "Ctrl+Y";
    pub const find = "Ctrl+F";
    pub const help = "Ctrl+H";
    pub const cut = "Ctrl+X";
    pub const copy = "Ctrl+C";
    pub const paste = "Ctrl+V";
    pub const select_all = "Ctrl+A";
    pub const new_file = "Ctrl+N";
};

pub const MenuItemKind = enum {
    action,
    separator,
    header,
};

pub const MenuItemSpec = struct {
    label: []const u8 = "",
    shortcut: []const u8 = "",
    kind: MenuItemKind = .action,
    disabled: bool = false,
    action: ?*const fn () void = null,
};

pub const MenuSection = struct {
    title: []const u8 = "",
    items: []const MenuItemSpec = &[_]MenuItemSpec{},
};

pub const MenuBuilder = struct {
    items: [16]MenuItemSpec = @as([16]MenuItemSpec, @splat(@as(MenuItemSpec, .{}))),
    count: usize = 0,

    pub fn init() MenuBuilder {
        return .{};
    }

    pub fn add_item(self: *MenuBuilder, label: []const u8, shortcut: []const u8) *MenuBuilder {
        if (self.count < self.items.len) {
            self.items[self.count] = .{ .label = label, .shortcut = shortcut, .kind = .action };
            self.count += 1;
        }
        return self;
    }

    pub fn add_action(self: *MenuBuilder, label: []const u8, shortcut: []const u8, action_fn: ?*const fn () void) *MenuBuilder {
        if (self.count < self.items.len) {
            self.items[self.count] = .{ .label = label, .shortcut = shortcut, .kind = .action, .action = action_fn };
            self.count += 1;
        }
        return self;
    }

    pub fn add_separator(self: *MenuBuilder) *MenuBuilder {
        if (self.count < self.items.len) {
            self.items[self.count] = .{ .kind = .separator };
            self.count += 1;
        }
        return self;
    }

    pub fn add_header(self: *MenuBuilder, title: []const u8) *MenuBuilder {
        if (self.count < self.items.len) {
            self.items[self.count] = .{ .label = title, .kind = .header };
            self.count += 1;
        }
        return self;
    }

    pub fn slice(self: *const MenuBuilder) []const MenuItemSpec {
        return self.items[0..self.count];
    }
};

/// Build a standardized ContextMenu from a slice of MenuItemSpecs (M27 G9).
pub fn menu_build(specs: []const MenuItemSpec) ContextMenu {
    return ContextMenu.initWithSpecs(specs);
}

pub const ContextMenuItem = struct {
    label: []const u8,
    // Optional callback — not used in host tests, reserved for app wiring.
    action: ?*const fn () void = null,
};

pub const ContextMenu = struct {
    items: []const ContextMenuItem = &[_]ContextMenuItem{},
    specs: []const MenuItemSpec = &[_]MenuItemSpec{},
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 120,
    row_h: u32 = 16,
    open: bool = false,
    hover_idx: ?usize = null,
    selected_idx: ?usize = null,

    pub fn init(items: []const ContextMenuItem) ContextMenu {
        return .{ .items = items, .specs = &[_]MenuItemSpec{} };
    }

    pub fn initWithSpecs(specs: []const MenuItemSpec) ContextMenu {
        return .{ .items = &[_]ContextMenuItem{}, .specs = specs };
    }

    pub fn show(self: *ContextMenu, x: u32, y: u32) void {
        self.x = x;
        self.y = y;
        self.open = true;
        self.hover_idx = null;
        self.selected_idx = null;
    }

    pub fn dismiss(self: *ContextMenu) void {
        self.open = false;
        self.hover_idx = null;
    }

    pub fn is_open(self: *const ContextMenu) bool {
        return self.open;
    }

    pub fn count(self: *const ContextMenu) usize {
        return if (self.specs.len > 0) self.specs.len else self.items.len;
    }

    pub fn bounds(self: *const ContextMenu) Rect {
        return Rect.make(self.x, self.y, self.width, @as(u32, @intCast(self.count())) * self.row_h);
    }

    fn is_item_selectable(self: *const ContextMenu, idx: usize) bool {
        if (self.specs.len > 0) {
            if (idx >= self.specs.len) return false;
            return self.specs[idx].kind == .action and !self.specs[idx].disabled;
        }
        return idx < self.items.len;
    }

    fn hit_test(self: *const ContextMenu, px: u32, py: u32) ?usize {
        if (!self.open) return null;
        const b = self.bounds();
        if (!b.contains(px, py)) return null;
        const rel_y = py - b.y;
        const idx = rel_y / self.row_h;
        if (idx < self.count()) return idx;
        return null;
    }

    pub fn handle_event(self: *ContextMenu, ev: *const Event) bool {
        switch (ev.kind) {
            KEY_DOWN => {
                if (!self.open) return false;
                const kc = ev.arg0;
                const total = self.count();
                if (total == 0) return false;
                if (kc == 0x52) { // Up arrow
                    var cur = if (self.hover_idx) |h| h else 0;
                    var tries: usize = 0;
                    while (tries < total) : (tries += 1) {
                        cur = if (cur == 0) total - 1 else cur - 1;
                        if (self.is_item_selectable(cur)) {
                            self.hover_idx = cur;
                            return true;
                        }
                    }
                    return true;
                } else if (kc == 0x51) { // Down arrow
                    var cur = if (self.hover_idx) |h| h else total - 1;
                    var tries: usize = 0;
                    while (tries < total) : (tries += 1) {
                        cur = if (cur + 1 >= total) 0 else cur + 1;
                        if (self.is_item_selectable(cur)) {
                            self.hover_idx = cur;
                            return true;
                        }
                    }
                    return true;
                } else if (kc == 0x28) { // Enter
                    if (self.hover_idx) |idx| {
                        if (self.is_item_selectable(idx)) {
                            self.selected_idx = idx;
                            self.open = false;
                            if (self.specs.len > 0) {
                                if (self.specs[idx].action) |act| act();
                            } else if (self.items.len > 0) {
                                if (self.items[idx].action) |act| act();
                            }
                            return true;
                        }
                    }
                    return false;
                } else if (kc == 0x29) { // Escape
                    self.dismiss();
                    return true;
                }
                return false;
            },
            MOUSE_RIGHT_DOWN => {
                self.show(ev.arg0, ev.arg1);
                return true;
            },
            MOUSE_DOWN => {
                if (!self.open) return false;
                if (self.hit_test(ev.arg0, ev.arg1)) |idx| {
                    if (self.is_item_selectable(idx)) {
                        self.selected_idx = idx;
                        self.open = false;
                        self.hover_idx = null;
                        if (self.specs.len > 0) {
                            if (self.specs[idx].action) |act| act();
                        } else if (self.items.len > 0) {
                            if (self.items[idx].action) |act| act();
                        }
                        return true;
                    }
                    return true;
                }
                self.dismiss();
                return false;
            },
            MOUSE_MOVE => {
                if (!self.open) return false;
                const hit = self.hit_test(ev.arg0, ev.arg1);
                if (hit) |idx| {
                    if (self.is_item_selectable(idx)) {
                        self.hover_idx = idx;
                    } else {
                        self.hover_idx = null;
                    }
                } else {
                    self.hover_idx = null;
                }
                return false;
            },
            MOUSE_RIGHT_UP => {
                if (self.open) return true;
                return false;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const ContextMenu, win_id: u32) void {
        if (!self.open) return;
        const b = self.bounds();
        draw_rect(win_id, b, theme_surface());
        draw_rect_outline(win_id, b, 1, theme_border());
        const total = self.count();
        var i: usize = 0;
        while (i < total) : (i += 1) {
            const row_y = b.y + @as(u32, @intCast(i)) * self.row_h;
            const row_rect = Rect.make(b.x + 1, row_y, b.w - 2, self.row_h);

            if (self.specs.len > 0) {
                const spec = self.specs[i];
                if (spec.kind == .separator) {
                    const mid_y = row_y + self.row_h / 2;
                    draw_rect(win_id, Rect.make(b.x + 4, mid_y, if (b.w > 8) b.w - 8 else 0, 1), theme_border());
                    continue;
                }
                const bg = if (self.hover_idx != null and self.hover_idx.? == i and !spec.disabled)
                    theme_btn_hover()
                else
                    theme_surface();
                win_fill(win_id, row_rect.x, row_rect.y, row_rect.w, row_rect.h, bg);
                const text_col = if (spec.disabled) theme_text_muted() else theme_text_primary();
                draw_text(win_id, spec.label, row_rect.x + 6, row_rect.y + (self.row_h - 8) / 2, text_col);
                if (spec.shortcut.len > 0) {
                    const sc_w = @as(u32, @intCast(spec.shortcut.len)) * 8;
                    const sc_x = if (row_rect.w > sc_w + 6) row_rect.x + row_rect.w - sc_w - 6 else row_rect.x;
                    draw_text(win_id, spec.shortcut, sc_x, row_rect.y + (self.row_h - 8) / 2, theme_text_muted());
                }
            } else {
                const bg = if (self.hover_idx != null and self.hover_idx.? == i)
                    theme_btn_hover()
                else
                    theme_surface();
                win_fill(win_id, row_rect.x, row_rect.y, row_rect.w, row_rect.h, bg);
                draw_text(win_id, self.items[i].label, row_rect.x + 6, row_rect.y + (self.row_h - 8) / 2, theme_text_primary());
            }
        }
    }
};
