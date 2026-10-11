//! VirelaiOS UI Theme System & Design Tokens (M39 UI1).
const std = @import("std");
const abi = @import("abi.zig");

// Local aliases from abi:
const file_open = abi.file_open;
const file_read = abi.file_read;
const file_close = abi.file_close;
const write_console = abi.write_console;
const MODE_READ = abi.MODE_READ;

// ---------------------------------------------------------------------------
// Theme System (ADR 0008 & ADR 0011, Issue #207)
// ---------------------------------------------------------------------------

pub const Theme = struct {
    bg: u32,
    surface: u32,
    border: u32,
    text_primary: u32,
    text_muted: u32,
    accent: u32,
    btn_idle: u32,
    btn_hover: u32,
    btn_pressed: u32,
    success: u32,
    danger: u32,
    warning: u32,
};

pub const THEME_DARK: Theme = .{
    .bg = 0x182026,
    .surface = 0x222d35,
    .border = 0x334155,
    .text_primary = 0xffffff,
    .text_muted = 0x94a3b8,
    .accent = 0x3b82f6,
    .btn_idle = 0x2d3748,
    .btn_hover = 0x4a5568,
    .btn_pressed = 0x1a202c,
    .success = 0x22c55e,
    .danger = 0xef4444,
    .warning = 0xf59e0b,
};

pub const THEME_LIGHT: Theme = .{
    .bg = 0xf1f5f9,
    .surface = 0xffffff,
    .border = 0xcbd5e1,
    .text_primary = 0x0f172a,
    .text_muted = 0x64748b,
    .accent = 0x2563eb,
    .btn_idle = 0xe2e8f0,
    .btn_hover = 0xcbd5e1,
    .btn_pressed = 0x94a3b8,
    .success = 0x16a34a,
    .danger = 0xdc2626,
    .warning = 0xd97706,
};

pub const THEME_AMBER: Theme = .{
    .bg = 0x1a1000,
    .surface = 0x2a1a00,
    .border = 0x5a4000,
    .text_primary = 0xffcc00,
    .text_muted = 0x997700,
    .accent = 0xff8800,
    .btn_idle = 0x3a2800,
    .btn_hover = 0x5a4000,
    .btn_pressed = 0x1a1000,
    .success = 0x88cc00,
    .danger = 0xff4444,
    .warning = 0xffaa00,
};

pub var current_theme: Theme = THEME_DARK;

pub const ThemeColors = struct {
    bg: u32,
    fg: u32,
    accent: u32,
    border: u32,
    title_bg: u32,
    title_fg: u32,
    @"error": u32,
    success: u32,
};

/// Get active theme colors palette struct.
pub fn get_theme_colors() ThemeColors {
    return .{
        .bg = current_theme.bg,
        .fg = current_theme.text_primary,
        .accent = current_theme.accent,
        .border = current_theme.border,
        .title_bg = current_theme.surface,
        .title_fg = current_theme.text_primary,
        .@"error" = current_theme.danger,
        .success = current_theme.success,
    };
}

/// Select a theme by name. Returns true if found and applied.
pub fn set_theme(name: []const u8) bool {
    if (eql(name, "dark")) {
        current_theme = THEME_DARK;
        return true;
    } else if (eql(name, "light")) {
        current_theme = THEME_LIGHT;
        return true;
    } else if (eql(name, "amber")) {
        current_theme = THEME_AMBER;
        return true;
    }
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

// Theme color accessors — widget draw functions read from current_theme.
pub fn theme_bg() u32 {
    return current_theme.bg;
}
pub fn theme_surface() u32 {
    return current_theme.surface;
}
pub fn theme_border() u32 {
    return current_theme.border;
}
pub fn theme_text_primary() u32 {
    return current_theme.text_primary;
}
pub fn theme_text_muted() u32 {
    return current_theme.text_muted;
}
pub fn theme_accent() u32 {
    return current_theme.accent;
}
pub fn theme_btn_idle() u32 {
    return current_theme.btn_idle;
}
pub fn theme_btn_hover() u32 {
    return current_theme.btn_hover;
}
pub fn theme_btn_pressed() u32 {
    return current_theme.btn_pressed;
}
pub fn theme_success() u32 {
    return current_theme.success;
}
pub fn theme_danger() u32 {
    return current_theme.danger;
}
pub fn theme_warning() u32 {
    return current_theme.warning;
}

// ---------------------------------------------------------------------------
// Widget State & Styling Accessors (M27 G14 #457)
// ---------------------------------------------------------------------------

pub const WidgetState = enum {
    normal,
    hover,
    pressed,
    disabled,
    focused,
};

pub fn widget_bg(state: WidgetState) u32 {
    return switch (state) {
        .normal => theme_btn_idle(),
        .hover => theme_btn_hover(),
        .pressed => theme_btn_pressed(),
        .disabled => theme_surface(),
        .focused => theme_btn_hover(),
    };
}

pub fn widget_border(state: WidgetState) u32 {
    return switch (state) {
        .normal => theme_border(),
        .hover => theme_accent(),
        .pressed => theme_accent(),
        .disabled => theme_border(),
        .focused => theme_accent(),
    };
}

pub fn widget_text(state: WidgetState) u32 {
    return switch (state) {
        .normal, .hover, .pressed, .focused => theme_text_primary(),
        .disabled => theme_text_muted(),
    };
}

// Backward-compatible pub const aliases for app code that references
// ui.COLOR_*. These match the default (dark) theme. The widget draw
// functions use theme_*() for dynamic theming.
pub const COLOR_BG: u32 = THEME_DARK.bg;
pub const COLOR_SURFACE: u32 = THEME_DARK.surface;
pub const COLOR_BORDER: u32 = THEME_DARK.border;
pub const COLOR_TEXT_PRIMARY: u32 = THEME_DARK.text_primary;
pub const COLOR_TEXT_MUTED: u32 = THEME_DARK.text_muted;
pub const COLOR_ACCENT: u32 = THEME_DARK.accent;
pub const COLOR_BTN_IDLE: u32 = THEME_DARK.btn_idle;
pub const COLOR_BTN_HOVER: u32 = THEME_DARK.btn_hover;
pub const COLOR_BTN_PRESSED: u32 = THEME_DARK.btn_pressed;
pub const COLOR_SUCCESS: u32 = THEME_DARK.success;
pub const COLOR_DANGER: u32 = THEME_DARK.danger;
pub const COLOR_WARNING: u32 = THEME_DARK.warning;

// ---------------------------------------------------------------------------
// M37 DQ4 design tokens (issue #838): one look.
//
// The Theme struct above owns the base palette; this section centralizes
// everything else every first-party app must agree on: spacing/border
// metrics, the extended chrome colors (selection, caret, editor gutter,
// file-type accents, text-over-accent, compositor shadow), the window/
// panel frame + focus-outline helpers, the app-side cursor-kind tokens,
// and the host-share theme sync that makes light/dark real per app.
//
// Rules: token VALUES are pinned by the `dq4:` host tests below — change
// a value and the tests fail loudly. Dark-theme values are chosen to be
// byte-identical to the pre-DQ4 rendering (frozen COLOR_* / hardcoded app
// colors), so the migration is a no-op on dark and a fix on light.
// ---------------------------------------------------------------------------

/// Spacing scale (px). Apps pad with these, never with bare literals.
pub const pad_xs: u32 = 2;
pub const pad_sm: u32 = 4;
pub const pad_md: u32 = 8;
pub const pad_lg: u32 = 16;

/// Border + outline metrics (px).
pub const border_w: u32 = 1;
pub const focus_w: u32 = 2;

/// Text caret metrics (px): the I-beam bar drawn in focused text fields.
pub const caret_w: u32 = 2;
pub const caret_h: u32 = 8;

/// Compositor drop-shadow offset (px): right + bottom bands outside the
/// window rect, in the theme shadow color. Mirrors
/// `kernel/src/driving_award.zig` (`chrome_shadow_off`) — the two values
/// are pinned equal by the dq4 shadow-parity test.
pub const shadow_off: u32 = 4;

/// Extended per-theme chrome colors. Stored beside Theme (not inside it)
/// so the frozen Theme struct layout is untouched; selected by the same
/// `current_theme` identity the theme_*() accessors read.
pub const ChromeColors = struct {
    selection_bg: u32,
    caret: u32,
    gutter_bg: u32,
    line_highlight: u32,
    file_dir: u32,
    file_txt: u32,
    file_bin: u32,
    file_unknown: u32,
    multi_select: u32,
    on_accent: u32,
    shadow: u32,
};

pub const CHROME_DARK: ChromeColors = .{
    .selection_bg = 0x2a4460,
    .caret = 0x3b82f6,
    .gutter_bg = 0x0b0e11,
    .line_highlight = 0x22303a,
    .file_dir = 0x3b82f6,
    .file_txt = 0x22c55e,
    .file_bin = 0xf59e0b,
    .file_unknown = 0x64748b,
    .multi_select = 0x1e3a8a,
    .on_accent = 0xffffff,
    .shadow = 0x000000,
};

pub const CHROME_LIGHT: ChromeColors = .{
    .selection_bg = 0xbfdbfe,
    .caret = 0x2563eb,
    .gutter_bg = 0xe5e7eb,
    .line_highlight = 0xe0e7ff,
    .file_dir = 0x2563eb,
    .file_txt = 0x16a34a,
    .file_bin = 0xd97706,
    .file_unknown = 0x64748b,
    .multi_select = 0x93c5fd,
    .on_accent = 0xffffff,
    .shadow = 0x94a3b8,
};

pub const CHROME_AMBER: ChromeColors = .{
    .selection_bg = 0x4d3300,
    .caret = 0xff8800,
    .gutter_bg = 0x120c00,
    .line_highlight = 0x332200,
    .file_dir = 0xffcc33,
    .file_txt = 0x88cc00,
    .file_bin = 0xff8800,
    .file_unknown = 0x997700,
    .multi_select = 0x664400,
    .on_accent = 0x1a1000,
    .shadow = 0x000000,
};

fn active_chrome() *const ChromeColors {
    if (current_theme.bg == THEME_LIGHT.bg and current_theme.accent == THEME_LIGHT.accent) return &CHROME_LIGHT;
    if (current_theme.bg == THEME_AMBER.bg and current_theme.accent == THEME_AMBER.accent) return &CHROME_AMBER;
    return &CHROME_DARK;
}

pub fn theme_selection_bg() u32 {
    return active_chrome().selection_bg;
}
pub fn theme_caret() u32 {
    return active_chrome().caret;
}
pub fn theme_gutter_bg() u32 {
    return active_chrome().gutter_bg;
}
pub fn theme_line_highlight() u32 {
    return active_chrome().line_highlight;
}
pub fn theme_file_dir() u32 {
    return active_chrome().file_dir;
}
pub fn theme_file_txt() u32 {
    return active_chrome().file_txt;
}
pub fn theme_file_bin() u32 {
    return active_chrome().file_bin;
}
pub fn theme_file_unknown() u32 {
    return active_chrome().file_unknown;
}
pub fn theme_multi_select() u32 {
    return active_chrome().multi_select;
}
pub fn theme_on_accent() u32 {
    return active_chrome().on_accent;
}
pub fn theme_shadow() u32 {
    return active_chrome().shadow;
}

/// Resolve a possibly-legacy frozen COLOR_* value to the live theme.
/// Dark renders byte-identical (aliases equal the dark theme); light/amber
/// map to the matching theme color. Unknown customs pass through.
pub fn live_color(c: u32) u32 {
    if (c == COLOR_BG) return theme_bg();
    if (c == COLOR_SURFACE) return theme_surface();
    if (c == COLOR_BORDER) return theme_border();
    if (c == COLOR_TEXT_PRIMARY) return theme_text_primary();
    if (c == COLOR_TEXT_MUTED) return theme_text_muted();
    if (c == COLOR_ACCENT) return theme_accent();
    if (c == COLOR_BTN_IDLE) return theme_btn_idle();
    if (c == COLOR_BTN_HOVER) return theme_btn_hover();
    if (c == COLOR_BTN_PRESSED) return theme_btn_pressed();
    if (c == COLOR_SUCCESS) return theme_success();
    if (c == COLOR_DANGER) return theme_danger();
    if (c == COLOR_WARNING) return theme_warning();
    return c;
}

/// Relative luminance of a 0xRRGGBB color (WCAG 2.x linearization).
pub fn luminance(rgb: u32) f64 {
    const r: f64 = @as(f64, @floatFromInt((rgb >> 16) & 0xff)) / 255.0;
    const g: f64 = @as(f64, @floatFromInt((rgb >> 8) & 0xff)) / 255.0;
    const b: f64 = @as(f64, @floatFromInt(rgb & 0xff)) / 255.0;
    const lin = struct {
        fn f(c: f64) f64 {
            return if (c <= 0.03928) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
        }
    }.f;
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
}

/// WCAG contrast ratio between two 0xRRGGBB colors (1.0 .. 21.0).
pub fn contrast_ratio(a: u32, b: u32) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    const hi = if (la > lb) la else lb;
    const lo = if (la > lb) lb else la;
    return (hi + 0.05) / (lo + 0.05);
}

/// Border color for a frame: accent when focused, plain border otherwise.
pub fn frame_border(focused: bool) u32 {
    return if (focused) theme_accent() else theme_border();
}

// ---------------------------------------------------------------------------
// Cursor-kind tokens. The compositor owns the hardware glyph (still the
// fixed magenta quad — switching it needs a new ABI, out of DQ4 scope);
// apps own the per-region KIND: which glyph SHOULD show over each region.
// Apps track it in their MOUSE_MOVE path and emit `cursor=<name>` markers
// (observable in the serial log); text carets draw with caret_w/caret_h.
// ---------------------------------------------------------------------------

pub const CursorKind = enum {
    arrow,
    ibeam,
    pointer,
    resize_h,
    resize_v,
    resize_diag,
    crosshair,

    pub fn name(self: CursorKind) []const u8 {
        return switch (self) {
            .arrow => "arrow",
            .ibeam => "ibeam",
            .pointer => "pointer",
            .resize_h => "resize_h",
            .resize_v => "resize_v",
            .resize_diag => "resize_diag",
            .crosshair => "crosshair",
        };
    }
};

/// Pure region → cursor mapping, unit-pinned. Priority: resize borders
/// first (they overlap content edges), then clickables, then text.
pub fn cursor_for_region(on_resize_border: bool, over_clickable: bool, over_text: bool) CursorKind {
    if (on_resize_border) return .resize_diag;
    if (over_clickable) return .pointer;
    if (over_text) return .ibeam;
    return .arrow;
}

/// Parse `theme=<dark|light|amber>` out of a SETTINGS.TXT payload.
/// Pure + host-testable; sync_theme_from_host() feeds it the share file.
pub fn parse_theme_setting(buf: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < buf.len) {
        var eol = i;
        while (eol < buf.len and buf[eol] != '\n') : (eol += 1) {}
        const line = buf[i..eol];
        if (line.len > 6 and eql(line[0..6], "theme=")) {
            const val = line[6..];
            if (eql(val, "dark") or eql(val, "light") or eql(val, "amber")) return val;
            return null;
        }
        i = if (eol < buf.len) eol + 1 else eol;
    }
    return null;
}

/// Current theme name (for markers + gates).
pub fn theme_name() []const u8 {
    if (current_theme.bg == THEME_LIGHT.bg and current_theme.accent == THEME_LIGHT.accent) return "light";
    if (current_theme.bg == THEME_AMBER.bg and current_theme.accent == THEME_AMBER.accent) return "amber";
    return "dark";
}

/// Sync `current_theme` from `/host/SETTINGS.TXT` (the kernel persists
/// `settings set theme <name>` there). Returns true when a theme was
/// applied. Host no-op (returns false) — EL0 file syscalls trap off-guest.
/// Apps call this once at startup so `settings set theme light` + relaunch
/// follows the desktop (DQ1 owns the toggle; DQ4 consumes it).
pub fn sync_theme_from_host() bool {
    if (@import("builtin").os.tag != .freestanding) return false;
    const fd = file_open("/host/SETTINGS.TXT", MODE_READ);
    if (fd < 0) return false;
    var buf: [256]u8 = @as([256]u8, @splat(@as(u8, 0)));
    const n = file_read(@as(u32, @intCast(fd)), buf[0..]);
    file_close(@as(u32, @intCast(fd)));
    if (n <= 0) return false;
    const end: usize = @min(@as(usize, @intCast(n)), buf.len);
    if (parse_theme_setting(buf[0..end]) == null) return false;
    return set_theme(parse_theme_setting(buf[0..end]).?);
}

/// Emit the per-app token marker the DQ4 gate greps:
/// `<tag>: tokens theme=<name> bg=0x… surface=… border=… accent=…`.
pub fn emit_tokens_marker(tag: []const u8) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: tokens theme={s} bg=0x{x:0>6} surface=0x{x:0>6} border=0x{x:0>6} accent=0x{x:0>6}\n", .{
        tag, theme_name(), theme_bg(), theme_surface(), theme_border(), theme_accent(),
    }) catch return;
    write_console(msg);
}

// ---------------------------------------------------------------------------
// M39 UI2 Sidebar Design Tokens & Tab Styling (Issue #927)
// ---------------------------------------------------------------------------

/// Sidebar layout metrics (px).
pub const sidebar_w: u32 = 180;
pub const tab_row_h: u32 = 38;
pub const tab_pill_inset_x: u32 = 8;
pub const tab_pill_inset_y: u32 = 2;
pub const tab_pill_radius: u32 = 6;

/// Typography metrics for sidebar elements (pt / px).
pub const font_size_tab_title: u32 = 14;
pub const font_size_clock: u32 = 13;
pub const font_size_badge: u32 = 11;

/// Sidebar color palette struct.
pub const SidebarColors = struct {
    bg: u32,
    border: u32,
    active_pill: u32,
    hover_pill: u32,
    text_active: u32,
    text_inactive: u32,
};

pub const SIDEBAR_DARK: SidebarColors = .{
    .bg = 0x13191f,
    .border = 0x242f38,
    .active_pill = 0x263340,
    .hover_pill = 0x1c252d,
    .text_active = 0xffffff,
    .text_inactive = 0x94a3b8,
};

pub const SIDEBAR_LIGHT: SidebarColors = .{
    .bg = 0xe2e8f0,
    .border = 0xcbd5e1,
    .active_pill = 0xffffff,
    .hover_pill = 0xedf2f7,
    .text_active = 0x0f172a,
    .text_inactive = 0x64748b,
};

pub const SIDEBAR_AMBER: SidebarColors = .{
    .bg = 0x120a00,
    .border = 0x3a2800,
    .active_pill = 0x3a2800,
    .hover_pill = 0x251800,
    .text_active = 0xffcc00,
    .text_inactive = 0x997700,
};

pub fn active_sidebar() *const SidebarColors {
    if (current_theme.bg == THEME_LIGHT.bg and current_theme.accent == THEME_LIGHT.accent) return &SIDEBAR_LIGHT;
    if (current_theme.bg == THEME_AMBER.bg and current_theme.accent == THEME_AMBER.accent) return &SIDEBAR_AMBER;
    return &SIDEBAR_DARK;
}

pub fn sidebar_bg() u32 {
    return active_sidebar().bg;
}
pub fn sidebar_border() u32 {
    return active_sidebar().border;
}
pub fn sidebar_active_pill() u32 {
    return active_sidebar().active_pill;
}
pub fn sidebar_hover_pill() u32 {
    return active_sidebar().hover_pill;
}
pub fn sidebar_text_active() u32 {
    return active_sidebar().text_active;
}
pub fn sidebar_text_inactive() u32 {
    return active_sidebar().text_inactive;
}
