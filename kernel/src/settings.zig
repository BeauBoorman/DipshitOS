//! VirelaiOS persistent settings engine (Milestone 8 Card U8, claim 2649).
//!
//! Provides in-memory key-value configuration backed by `SETTINGS.TXT` on
//! the HOST SHARE (M34 HF5/HF6, issues #739/#740): the queue-5 file
//! channel is the persistence home — the DATA partition is gone.
//!
//! Keys supported:
//!   - `hostname`: system host identifier (default: "virelai")
//!   - `prompt`: interactive shell prompt string (default: "virelai> ")
//!   - `theme`: UI visual color accent (default "dark"; M73m #1662 grows
//!     the ternary to include "custom" — the user's own palette)
//!   - `palette_fg` / `palette_bg` / `palette_accent`: the custom palette
//!     (six hex digits RRGGBB) that `theme=custom` resolves to — accepted
//!     keys like `color`/`font_size`, NOT seeded by init(), so a fresh
//!     table and a fresh SETTINGS.TXT stay byte-identical (M73m #1662)
//!   - `scrollback`: terminal scrollback buffer lines (default: "1000")
//!   - `shell`: boot login shell, "monitor"|"sh" (default: "monitor")
//!   - `term_restart`: GOTERM shell-exit policy, "stay"|"exit" (default:
//!     "stay"; accepted as an optional persisted key without changing the
//!     seeded default table)
//!   - `wm`: boot window-manager seat, "gotabwm"|"tabwm"|"none"
//!     (default: "gotabwm" — M59 issue #1298 flipped it from TABWM)
//!   - `init`: declarative boot handoff, "on"|"off" (default: "on", M92e)
//!
//! Boot contract:
//!   On kernel boot, after the file channel is armed, `init_from_share()`
//!   reads `SETTINGS.TXT` from the share if present and parses the
//!   key-values (defaults otherwise).
//!
//! Persistence:
//!   `settings set <key> <value>` persists immediately to the share by
//!   updating in-memory state and writing `SETTINGS.TXT`.
//!
//! Capacity (M183a, issue #3171): the table is a bounded 48 entries — the
//! original 24-row bank plus a second bank of overflow headroom for the
//! rows later arcs add. The file grammar is unchanged (`#v2` header,
//! `key=value` rows, the 2048-byte load/save buffer): a file past the row
//! cap still drops its tail rows at load, `table_full` still refuses a
//! `set` at the new cap, and a file past the byte bound is still refused
//! whole.
//!
//! No libc, no POSIX, bounded BSS storage, no heap allocation.
//!
//! Version contract (Arc5 issue #247; amended M66b #1444):
//!   SETTINGS.TXT carries a version header on the first line: `#v<N>\n`.
//!   The current schema version is `current_version` (= 2).
//!   - v1: versioned format with `#v1` header.
//!   - v2 (M59, issue #1298): adds the `wm` seat key (default "gotabwm").
//!   - newer: refused with honest degradation (compiled defaults used).
//!   - NO header: refused (M66b corrupt-fails-closed). The pre-M66b
//!     "headerless = legacy v0, load anyway" rule is gone: since HF6 the
//!     only SETTINGS.TXT writer is this kernel, which always writes the
//!     header, so a headerless file is not a legacy file — it is exactly
//!     what a partial in-place write produces, and it is refused whole
//!     (compiled defaults) like `.tabs` v2 refuses corrupt bytes.
//!   Migration steps live in `migrate()`. Each step adds missing keys
//!   with defaults and removes obsolete keys. Serial logs what changed.
//!   To increment: bump `current_version`, add a migration step in
//!   `migrate()`, and document the schema change here.
//!
//! Schema (keys, types, defaults, valid values):
//!   hostname   string  "virelai"     1..32 chars, system host identifier
//!   prompt     string  "virelai> "   1..64 chars, interactive shell prompt
//!   theme      string  "dark"        "dark"|"light"|"amber"|"custom", the
//!                                   palette the terminal resolves at paint
//!                                   time (M73m #1662 added "custom")
//!   palette_fg string  "00ff00"      six hex digits RRGGBB: the custom
//!   palette_bg string  "101418"      palette `theme=custom` resolves to
//!   palette_accent string "3b82f6"   (accepted keys, not seeded rows —
//!                                   defaults are the compiled dark colours)
//!   scrollback string  "1000"        positive integer, terminal scrollback lines
//!   color      string  "on"          "on"|"off", ANSI terminal colors in shell
//!   shadow     string  "off"         "on"|"off", M37 DQ4 compositor drop-shadow
//!   shell      string  "monitor"     "monitor"|"sh", M45 SH8 boot login shell
//!   wm         string  "gotabwm"     "gotabwm"|"tabwm"|"none", M59 (#1298)
//!                                   boot window-manager seat: the Go seat by
//!                                   default, the Zig TABWM fallback seat, or
//!                                   no seat at all (shim-only VM)
//!   font_size  string  (none)        "small"|"medium"|"large" — TWO
//!                                   consumers, same key (M80i #1725): the
//!                                   legacy text layer (8x8/16x16/24x24,
//!                                   M20-U1) AND the terminal grid's zoom
//!                                   ladder (7x13/8x16/10x21 cells —
//!                                   FiraCode at 11/13/17px, font_metrics).
//!                                   Accepted key, NOT seeded (the
//!                                   `color`/`palette_*` pattern): absent =
//!                                   the boot look (text small + grid 8x16 —
//!                                   unchanged), present = the rung applies
//!                                   to both consumers. The vocabulary
//!                                   collision is deliberate and said: the
//!                                   grid's compiled default is the MEDIUM
//!                                   rung (8x16), so `small` SHRINKS the
//!                                   grid below the boot cell and `medium`
//!                                   is the no-op rung at the classic rect.
//!   notify_sound string (none)      "on"|"off" — the seat's notification
//!                                   chime (M99d #2182). Accepted, not
//!                                   seeded: absent = on. The kernel
//!                                   stores it; the seat interprets it.
//!   audio_volume string  (none)     "0".."100" — slot-44 stream gain
//!                                   (M99d #2182). Accepted, not seeded:
//!                                   the gain is kernel state that resets
//!                                   to 100 at boot; the row only carries
//!                                   the choice for its consumers to
//!                                   re-apply.
//!   a11y.contrast string (none)     "off"|"high" — the high-contrast theme
//!                                   variant (M165b #2983). Accepted, not
//!                                   seeded: absent = off. The kernel
//!                                   stores it; theme.ApplySettings
//!                                   callers interpret it.
//!   a11y.reduce_motion string (none) "off"|"on" — the seat's toast fade
//!                                   switch (M165b #2983). Accepted, not
//!                                   seeded: absent = off (fades on).
//!   a11y.text_scale string (none)   "100"|"125"|"150" — reserved and
//!                                   named (M165b #2983). Accepted, not
//!                                   seeded: no app honours it yet.

const std = @import("std");
// M34 HF5 (issue #739): the host-share persistence path; HF6 (issue
// #740) made it the ONLY path — the DATA partition is gone.
const virtio_file = @import("virtio_file.zig");
// M50 TS2 (issue #1136, ADR 0024 D4): the kernel-actor file policy for the
// settings consumer.
const trust = @import("trust.zig");

pub const filename = "SETTINGS.TXT";

/// Current schema version. Increment when keys are added/removed/renamed.
/// The version header in SETTINGS.TXT is `#v<N>` on the first line.
/// v2 (M59, issue #1298): added `wm`.
pub const current_version: u32 = 2;

/// M59 (issue #1298): the compiled default window-manager seat. A boot with
/// no persisted `wm` key — a fresh share, or a settings file written before
/// v2 — lands in the Go seat (`GOTABWM.ELF`). `"tabwm"` keeps the Zig
/// TABWM.BIN seat reachable as the fallback; `"none"` is the explicit
/// shim-only opt-out (the default VM every pre-M59 gate assumed).
pub const wm_default: []const u8 = "gotabwm";

pub const max_key_len: usize = 32;
pub const max_val_len: usize = 64;
// M99d (#2182): nine seeded rows plus the Go codec's ten optional/accepted
// rows (palette_fg/bg/accent, font_size, keyboard_layout, idle_minutes,
// notify_dnd, notify_sound, audio_volume, timezone) can all persist — a
// file carrying the full union is 19 rows and must load without dropping
// the tail. M100f (#2311) added data_root, and M165b (#2983) added the
// three a11y.* rows: the Go codec's union is 23 rows, and with the
// kernel's own accepted term_restart the full known union is 24 — exactly
// the wave-5 cap, which is why wave-5 cards could not take a settings row.
// M183a (#3171): the table doubles into a bounded second bank — entries
// 25..48 are pure headroom for the feature rows later arcs add. The
// on-disk format does not change (still `#v2` + `key=value` inside the
// 2048-byte file bound — no schema bump, nothing to migrate), so a
// SETTINGS.TXT written by a 24-cap kernel loads whole; `table_full` still
// names the refusal at the new cap.
pub const max_entries: usize = 48;

pub const Entry = struct {
    key: [max_key_len]u8 = @as([max_key_len]u8, @splat(@as(u8, 0))),
    key_len: usize = 0,
    val: [max_val_len]u8 = @as([max_val_len]u8, @splat(@as(u8, 0))),
    val_len: usize = 0,
};

pub const SetResult = enum {
    ok,
    invalid_key,
    invalid_value,
    table_full,
};

var entries: [max_entries]Entry = undefined;
var entry_count: usize = 0;
var initialized: bool = false;

/// Populate default settings table.
pub fn init() void {
    entry_count = 0;
    _ = set_internal("hostname", "virelai");
    _ = set_internal("prompt", "virelai> ");
    _ = set_internal("theme", "dark");
    _ = set_internal("scrollback", "1000");
    _ = set_internal("shadow", "off"); // M37 DQ4 (issue #838): compositor drop-shadow, default off
    _ = set_internal("focus_follows_mouse", "off");
    _ = set_internal("shell", "monitor"); // M45 SH8 (#1084): boot login shell (monitor|sh)
    _ = set_internal("wm", wm_default); // M59 (#1298): the boot WM seat (gotabwm|tabwm|none)
    _ = set_internal("init", "on"); // M92e: off preserves direct WM autostart
    initialized = true;
}

pub fn ensure_init() void {
    if (!initialized) init();
}

/// Reset settings to built-in defaults.
pub fn reset() void {
    init();
}

/// Count of current configuration entries.
pub fn count() usize {
    ensure_init();
    return entry_count;
}

/// Retrieve an entry by index for listing.
pub fn entry_at(i: usize) ?struct { key: []const u8, val: []const u8 } {
    ensure_init();
    if (i >= entry_count) return null;
    const e = &entries[i];
    return .{
        .key = e.key[0..e.key_len],
        .val = e.val[0..e.val_len],
    };
}

/// Retrieve configuration value for key.
pub fn get(key: []const u8) ?[]const u8 {
    ensure_init();
    for (entries[0..entry_count]) |*e| {
        if (std.mem.eql(u8, e.key[0..e.key_len], key)) {
            return e.val[0..e.val_len];
        }
    }
    return null;
}

/// Dynamic helper for shell prompt string.
pub fn get_prompt() []const u8 {
    return get("prompt") orelse "virelai> ";
}

/// Dynamic helper for system hostname.
pub fn get_hostname() []const u8 {
    return get("hostname") orelse "virelai";
}

/// M45 SH8 (#1084, ADR 0021 D5): the boot login shell. `"monitor"` (the
/// default) keeps the raw-console monitor; `"sh"` hands the console to the
/// shell seat at boot (the Go shell `GOSH.ELF` since M68b, #1450 — the value
/// names the seat, not the binary).
pub fn login_shell() []const u8 {
    return get("shell") orelse "monitor";
}

pub fn login_shell_is_sh() bool {
    return std.mem.eql(u8, login_shell(), "sh");
}

/// GOTERM's shell-exit policy. The terminal window survives a shell exit by
/// default; the exact persisted value "exit" restores close-on-exit. Any
/// missing or unrecognized value fails safe to the durable "stay" default.
pub fn term_restart_policy() []const u8 {
    const val = get("term_restart") orelse return "stay";
    if (std.mem.eql(u8, val, "exit")) return "exit";
    return "stay";
}

/// M59 (issue #1298): the boot window-manager seat, as named in `SETTINGS.TXT`.
/// The compiled default (`wm_default`) is what a boot with no persisted key
/// uses, so the `orelse` is the flip: an unset `wm` is the Go seat, not
/// shim-only.
pub fn wm_seat() []const u8 {
    return get("wm") orelse wm_default;
}

/// M59 (issue #1298): the seat vocabulary, resolved once so the autostart,
/// the tests and any future `wm` report agree on it. `"gotabwm"` and
/// `"tabwm"` name the two seats; `"none"` (and any unrecognized value)
/// means no default seat is launched — the pre-M59 shim-only VM.
pub const WmSeat = enum {
    gotabwm,
    tabwm,
    none,

    pub fn of(setting: []const u8) WmSeat {
        if (std.mem.eql(u8, setting, "gotabwm")) return .gotabwm;
        if (std.mem.eql(u8, setting, "tabwm")) return .tabwm;
        return .none;
    }

    /// The share-resident program that seats this manager (null for `none`).
    pub fn program(self: WmSeat) ?[]const u8 {
        return switch (self) {
            .gotabwm => "GOTABWM.ELF",
            .tabwm => "TABWM.BIN",
            .none => null,
        };
    }

    pub fn name(self: WmSeat) []const u8 {
        return switch (self) {
            .gotabwm => "gotabwm",
            .tabwm => "tabwm",
            .none => "none",
        };
    }
};

/// M59 (issue #1298): the persisted seat resolved to its kind (see `WmSeat`).
pub fn wm_seat_kind() WmSeat {
    return WmSeat.of(wm_seat());
}

pub fn init_enabled() bool {
    return std.mem.eql(u8, get("init") orelse "on", "on");
}

/// M18 T5: whether ANSI terminal colors are enabled.
pub fn get_color() bool {
    const val = get("color") orelse return true; // on by default
    return std.mem.eql(u8, val, "on") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
}

/// M27 G13 (#456): whether focus follows mouse pointer.
pub fn get_focus_follows_mouse() bool {
    const val = get("focus_follows_mouse") orelse return false;
    return std.mem.eql(u8, val, "on") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
}

/// M37 DQ4 (issue #838): whether the compositor draws drop-shadows.
/// Default off — every pre-DQ4 pixel gate stays byte-identical.
pub fn get_shadow() bool {
    const val = get("shadow") orelse return false;
    return std.mem.eql(u8, val, "on") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
}

// ---------------------------------------------------------------------------
// Theme & Font Settings API (M27 G20 #463, G21 #464)
// ---------------------------------------------------------------------------

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

/// Retrieve active theme identifier: 0=dark, 1=light, 2=amber, 3=custom.
pub fn get_theme_id() u8 {
    const val = get("theme") orelse "dark";
    if (std.mem.eql(u8, val, "light")) return 1;
    if (std.mem.eql(u8, val, "amber")) return 2;
    // M73m (#1662): the fourth name. Anything unrecognized is dark — a
    // stored typo never invents an id the resolver would guess at.
    if (std.mem.eql(u8, val, "custom")) return driving_award.theme_id_custom;
    return 0; // dark / default
}

/// Set active theme by ID: 0=dark, 1=light, 2=amber, 3=custom.
pub fn set_theme_id(id: u8) void {
    const name: []const u8 = switch (id) {
        1 => "light",
        2 => "amber",
        3 => "custom",
        else => "dark",
    };
    _ = set("theme", name);
}

// -------------------------------------------------------------------------
// M73m (#1662): the palette BEYOND the ternary — `theme=custom` plus the
// user's own fg/bg/accent, stored as plain key=value rows like everything
// else in this file.
//
// The three palette keys are ACCEPTED keys, not seeded rows: init() does not
// set them (the `color`/`font_size` pattern), so a fresh settings table —
// and the SETTINGS.TXT a fresh share carries — stays byte-identical to the
// pre-M73m image (pinned by test). Value in force falls back PER KEY to the
// compiled default, which is the DARK colour: a partial or invalid palette
// resolves to dark, never to a half-read number or garbage.
// ---------------------------------------------------------------------------

/// The compiled custom-palette defaults: the dark terminal fg/bg (the same
/// source `driving_award`'s `custom_*` fields default to) and dark's accent.
pub const palette_fg_default: u32 = text.fg_rgb;
pub const palette_bg_default: u32 = text.bg_rgb;
pub const palette_accent_default: u32 = 0x3b82f6;

/// Parse one stored palette colour: EXACTLY six hex digits (RRGGBB),
/// case-insensitive, no `0x` prefix. Anything else is refused (null) so the
/// apply side substitutes the compiled default rather than half-reading a
/// number. Pure — host-tested.
pub fn parse_hex6(val: []const u8) ?u32 {
    if (val.len != 6) return null;
    var v: u32 = 0;
    for (val) |c| {
        const d: u32 = switch (c) {
            '0'...'9' => @as(u32, c - '0'),
            'a'...'f' => @as(u32, c - 'a' + 10),
            'A'...'F' => @as(u32, c - 'A' + 10),
            else => return null,
        };
        v = (v << 4) | d;
    }
    return v;
}

fn palette_value(key: []const u8, fallback: u32) u32 {
    const raw = get(key) orelse return fallback;
    return parse_hex6(raw) orelse fallback;
}

/// The custom foreground in force (six hex digits, else the dark default).
pub fn palette_fg() u32 {
    return palette_value("palette_fg", palette_fg_default);
}

/// The custom background in force.
pub fn palette_bg() u32 {
    return palette_value("palette_bg", palette_bg_default);
}

/// The custom accent in force (chrome focus ring / active taskbar entry).
pub fn palette_accent() u32 {
    return palette_value("palette_accent", palette_accent_default);
}

fn is_palette_key(key: []const u8) bool {
    return std.mem.eql(u8, key, "palette_fg") or
        std.mem.eql(u8, key, "palette_bg") or
        std.mem.eql(u8, key, "palette_accent");
}

/// Get the active theme color palette for UI rendering.
pub fn get_theme_colors() ThemeColors {
    return switch (get_theme_id()) {
        1 => .{ // Light
            .bg = 0xf1f5f9,
            .fg = 0x0f172a,
            .accent = 0x2563eb,
            .border = 0xcbd5e1,
            .title_bg = 0xe2e8f0,
            .title_fg = 0x0f172a,
            .@"error" = 0xdc2626,
            .success = 0x16a34a,
        },
        2 => .{ // Amber
            .bg = 0x1a1000,
            .fg = 0xffcc00,
            .accent = 0xff8800,
            .border = 0x5a4000,
            .title_bg = 0x3a2800,
            .title_fg = 0xffcc00,
            .@"error" = 0xff4444,
            .success = 0x88cc00,
        },
        else => .{ // Dark (0)
            .bg = 0x182026,
            .fg = 0xffffff,
            .accent = 0x3b82f6,
            .border = 0x334155,
            .title_bg = 0x222d35,
            .title_fg = 0xffffff,
            .@"error" = 0xef4444,
            .success = 0x22c55e,
        },
    };
}

/// Retrieve terminal font size identifier: 0=8x8 (small), 1=16x16 (medium), 2=24x24 (large).
pub fn get_font_size() u8 {
    const val = get("font_size") orelse return 0;
    if (std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "medium") or std.mem.eql(u8, val, "16x16")) return 1;
    if (std.mem.eql(u8, val, "2") or std.mem.eql(u8, val, "large") or std.mem.eql(u8, val, "24x24")) return 2;
    return 0; // 0 = 8x8 / small
}

/// Set terminal font size by identifier: 0=8x8, 1=16x16, 2=24x24.
pub fn set_font_size(size: u8) void {
    const val: []const u8 = switch (size) {
        1 => "medium",
        2 => "large",
        else => "small",
    };
    _ = set("font_size", val);
}

fn set_internal(key: []const u8, val: []const u8) SetResult {
    if (key.len == 0 or key.len > max_key_len) return .invalid_key;
    if (val.len > max_val_len) return .invalid_value;

    for (entries[0..entry_count]) |*e| {
        if (std.mem.eql(u8, e.key[0..e.key_len], key)) {
            @memcpy(e.val[0..val.len], val);
            e.val_len = val.len;
            return .ok;
        }
    }

    if (entry_count >= max_entries) return .table_full;
    var e = &entries[entry_count];
    @memcpy(e.key[0..key.len], key);
    e.key_len = key.len;
    @memcpy(e.val[0..val.len], val);
    e.val_len = val.len;
    entry_count += 1;
    return .ok;
}

const driving_award = @import("driving_award.zig");
const text = @import("text.zig");
const font_metrics = @import("font_metrics.zig"); // M80i (#1725): the grid half of font_size

/// Set a configuration key-value pair in memory.
pub fn set(key: []const u8, val: []const u8) SetResult {
    ensure_init();
    const result = set_internal(key, val);
    // Step 7 (Issue #207): when theme is set, update the compositor's theme_id.
    // M73m (#1662): a palette key write resolves the SAME chain — the whole
    // palette is resolved in one place and the desktop is marked dirty, so
    // the next repaint shows what was just written (live apply).
    if (result == .ok and (std.mem.eql(u8, key, "theme") or is_palette_key(key))) {
        apply_palette();
    }
    // M20-U11 (claim 5127): debug_font is the text layer's dev setting.
    if (result == .ok and std.mem.eql(u8, key, "debug_font")) {
        apply_debug_font(val);
    }
    // M20-U1 (claim 5127): font_size persists the terminal font choice.
    // M80i (#1725): persist BEFORE the apply chain. apply_font_size moves
    // the grid and pushes WIN_RESIZE to every bound TUI the moment it
    // does, and a TUI that answers that event derives its cells from the
    // STORED rung (the Go CellGrid mirror reads /host/SETTINGS.TXT) — the
    // new row must already be on the share before that event can exist,
    // so the app-side read can never observe the old rung. (cmd_settings'
    // own save after this is then a byte-identical re-publish.)
    if (result == .ok and std.mem.eql(u8, key, "font_size")) {
        _ = save_to_share();
        apply_font_size(val);
    }
    // M27 G13 (#456): focus_follows_mouse setting
    if (result == .ok and std.mem.eql(u8, key, "focus_follows_mouse")) {
        apply_focus_follows_mouse(val);
    }
    return result;
}

fn apply_focus_follows_mouse(val: []const u8) void {
    const is_on = std.mem.eql(u8, val, "on") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
    driving_award.focus_follows_mouse = is_on;
}

/// Apply the font_size key to BOTH consumers (M80i #1725): the legacy
/// framebuffer text layer (8x8/16x16/24x24, M20-U1) and the terminal
/// grid's zoom ladder (font_metrics 7x13/8x16/10x21). Same rung names,
/// two ladders — the vocabulary collision the card documents. The grid
/// half runs through driving_award.apply_grid_font_size, which moves the
/// cell, re-flows every bound grid and tells each bound TUI (WIN_RESIZE)
/// before the caller's paints. An unrecognized value applies NOTHING
/// (both consumers keep what they had — the Go mirror's sticky
/// derivation in user/go/vi/gridcell.go follows the same contract, so a
/// row the kernel cannot apply never disagrees with the app's cells).
fn apply_font_size(val: []const u8) void {
    const size: ?text.FontSize = if (std.mem.eql(u8, val, "small") or std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "8x8"))
        .small
    else if (std.mem.eql(u8, val, "medium") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "16x16"))
        .medium
    else if (std.mem.eql(u8, val, "large") or std.mem.eql(u8, val, "2") or std.mem.eql(u8, val, "24x24"))
        .large
    else
        null;
    if (size) |s| {
        text.set_font_size(s);
        driving_award.apply_grid_font_size(switch (s) {
            .small => .small,
            .medium => .medium,
            .large => .large,
        });
    }
}

/// Apply the debug_font key to the framebuffer text layer.
fn apply_debug_font(val: []const u8) void {
    text.debug_font = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "on") or std.mem.eql(u8, val, "1");
}

/// Apply a theme by name, updating driving_award.theme_id.
/// M73m (#1662): `custom` is the fourth name (id 3, the store's own palette);
/// an UNRECOGNIZED name lands on dark — deterministic at load and at set,
/// never a stale id the resolver would guess past.
fn apply_theme(name: []const u8) void {
    if (std.mem.eql(u8, name, "light")) {
        driving_award.theme_id = 1;
    } else if (std.mem.eql(u8, name, "amber")) {
        driving_award.theme_id = 2;
    } else if (std.mem.eql(u8, name, "custom")) {
        driving_award.theme_id = driving_award.theme_id_custom;
    } else {
        driving_award.theme_id = 0; // dark, "default", or anything unrecognized
    }
}

/// M73m (#1662): the whole apply chain — resolve the store's palette into
/// driving_award (theme id + the three custom RGB fields, each validated with
/// a per-key fallback to the compiled dark default), then mark the desktop
/// dirty so the NEXT REPAINT paints the choice. No reboot, no re-exec: the
/// M73h resolver runs at paint time and reads exactly these fields.
fn apply_palette() void {
    apply_theme(get("theme") orelse "dark");
    driving_award.custom_fg = palette_fg();
    driving_award.custom_bg = palette_bg();
    driving_award.custom_accent = palette_accent();
    driving_award.mark_palette_dirty();
}

/// Parse a single `key=value` line into settings.
pub fn parse_line(line: []const u8) bool {
    ensure_init();
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return false;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (key.len == 0) return false;
    return set_internal(key, val) == .ok;
}

/// Serialize in-memory settings table into a newline-separated buffer.
/// The first line is the version header: `#v<N>\n`.
pub fn serialize(out: []u8) usize {
    ensure_init();
    // Write version header (comptime-known string)
    const header = comptime blk: {
        const v = current_version;
        break :blk if (v < 10) "#v" ++ &[_]u8{'0' + v} ++ "\n" else if (v < 100) "#v" ++ &[_]u8{ '0' + v / 10, '0' + v % 10 } ++ "\n" else "#v100\n";
    };
    if (header.len > out.len) return 0;
    @memcpy(out[0..header.len], header);
    var pos: usize = header.len;
    for (entries[0..entry_count]) |*e| {
        const line_len = e.key_len + 1 + e.val_len + 1;
        if (pos + line_len > out.len) break;
        @memcpy(out[pos .. pos + e.key_len], e.key[0..e.key_len]);
        pos += e.key_len;
        out[pos] = '=';
        pos += 1;
        @memcpy(out[pos .. pos + e.val_len], e.val[0..e.val_len]);
        pos += e.val_len;
        out[pos] = '\n';
        pos += 1;
    }
    return pos;
}

/// Parse + apply a SETTINGS.TXT payload. M66b (#1444): the version header
/// is the LOAD GATE — corrupt-fails-closed like `.tabs` v2. The first line
/// (trimmed of surrounding SP/CR/TAB) must be `#v<digits>` (at least one
/// digit, at most three, value this kernel understands); a headerless
/// file (the leftover shape of a partial in-place write), malformed
/// header, or newer schema is refused WHOLE — the compiled defaults stay
/// in force, never a partial parse. Shared by the host-share loader.
/// Returns false when refused.
fn apply_bytes(bytes: []const u8) bool {
    var pos: usize = 0;
    var file_version: u32 = 0; // set below once the header validates
    var have_header = false;

    // Parse first line: it must be exactly `#v<digits>`.
    if (bytes.len > 0) {
        var end: usize = 0;
        while (end < bytes.len and bytes[end] != '\n') : (end += 1) {}
        const first_line = std.mem.trim(u8, bytes[0..end], " \r\t");
        if (std.mem.startsWith(u8, first_line, "#v") and first_line.len > 2) {
            var digits: usize = 0;
            var v: u32 = 0;
            for (first_line[2..]) |c| {
                if (c < '0' or c > '9') break;
                v = v * 10 + @as(u32, c - '0');
                digits += 1;
                if (digits > 3) break; // no real schema version needs > 3 digits
            }
            // Every header-line byte after `#v` must be a digit.
            if (digits > 0 and digits == first_line.len - 2) {
                file_version = v;
                have_header = true;
                pos = end + 1; // skip version line
            }
        }
        // If the first line is not a valid header the file is refused.
    }
    if (!have_header) return false;

    // Handle version-specific loading
    if (file_version > current_version) {
        // Newer version than we support — refuse, use compiled defaults.
        return false;
    }

    // Parse key=value lines (skip comment lines starting with #)
    while (pos < bytes.len) {
        var end = pos;
        while (end < bytes.len and bytes[end] != '\n') : (end += 1) {}
        const line = std.mem.trim(u8, bytes[pos..end], " \r\t");
        if (line.len > 0 and line[0] != '#') {
            _ = parse_line(line);
        }
        pos = end + 1;
    }

    // Run migration if needed (v0 -> v1 adds missing keys with defaults)
    if (file_version < current_version) {
        migrate(file_version);
    }
    // M73m (#1662): the LOAD half of the apply chain — parse_line went
    // through set_internal (no per-key applies), so resolve the persisted
    // palette here, once, after the table is whole. A default image never
    // reaches this line (no file), and a seeded default file carries
    // theme=dark (id 0) — byte-identical either way.
    apply_palette();
    // M80i (#1725): the LOAD half of the font_size chain, same shape. An
    // ABSENT key applies nothing — the boot look (text small + grid 8x16)
    // is the compiled default and stays put; the key moves the ladder
    // only when the file actually carries it.
    if (get("font_size")) |v| apply_font_size(v);
    return true;
}

/// M66b (#1444): set by `load_from_share` when a settings file EXISTS on
/// the share but was refused (no valid schema header — the corrupt shape).
/// Read by main.zig's queue-5 arming point for the one honest boot line;
/// not a general-purpose flag.
pub var last_load_refused: bool = false;

/// M34 HF5 (issue #739): load settings from the HOST SHARE when the file
/// channel is armed. No-op without a channel (defaults stay in force).
/// M66b (#1444): a file that is present but unloadable — empty, larger
/// than the bounded buffer, or refused by `apply_bytes` — is corrupt:
/// report it via `last_load_refused` and keep the defaults.
pub fn load_from_share() bool {
    ensure_init();
    last_load_refused = false;
    if (!virtio_file.available()) return false;
    if (trust.check(trust.kernel_actor(), .host, filename, .read) != .allow) return false;
    var st = virtio_file.StatResult{};
    if (virtio_file.stat(filename, &st) != virtio_file.st_ok) return false; // absent: normal first boot
    var file_buf: [2048]u8 = undefined;
    if (st.is_dir or st.size == 0 or st.size > file_buf.len) {
        last_load_refused = true;
        return false;
    }
    const n = virtio_file.read_whole(filename, &file_buf) orelse {
        // Stat said present; the read could not deliver it — corrupt too
        // (M66b review): take the refused line, not a silent default.
        last_load_refused = true;
        return false;
    };
    if (!apply_bytes(file_buf[0..n])) {
        last_load_refused = true;
        return false;
    }
    return true;
}

/// Migrate from one version to the current version.
/// Each migration step adds missing keys with defaults and removes obsolete ones.
/// Logs changes to serial for debugging.
fn migrate(from_version: u32) void {
    // v0 -> v1: no new keys added in v1; this is the schema documentation
    // milestone. Future migrations will add keys here.
    if (from_version < 1) {
        // v0 was the original format without version header.
        // No key changes needed — the schema is stable.
    }
    // v1 -> v2 (M59, issue #1298): the `wm` seat key. No key has to be added
    // to the table here: `init()` already populated `wm` with the compiled
    // default before the file was parsed, so a v1 file that never carried
    // `wm` keeps that default (the Go seat). A v1 file that DID carry a
    // `wm=tabwm` line (a human who opted out before the flip) parses it and
    // wins — the persisted choice is respected, which is the point of the
    // default seam. The version bump exists so an older kernel refuses the
    // new file honestly instead of dropping the key silently.
    if (from_version < 2) {}
}

/// Persist current in-memory configuration to `SETTINGS.TXT` on the HOST
/// SHARE — crash-safe (M66b #1444): the body is written to a sacrificial
/// `SETTINGS.TXT.tmp` (write_whole may truncate OUR temp; the live file is
/// never touched until publish), fsync'd through the handle, and published
/// by one replacement rename. A rejected publish preserves the previous
/// settings, with no delete-then-rename absence window. This does not promise
/// directory-fsync/power-loss durability. An
/// orphan tmp from a save that crashed between its close and the publish
/// is not cleaned at boot — the next save simply replaces it.
/// HF6 (issue #740): without a channel the save is an honest no-op.
pub fn save_to_share() bool {
    ensure_init();
    if (!virtio_file.available()) return false;
    if (trust.check(trust.kernel_actor(), .host, filename, .write) != .allow) return false;
    const tmp_name = filename ++ ".tmp";
    if (trust.check(trust.kernel_actor(), .host, tmp_name, .create) != .allow or
        trust.check(trust.kernel_actor(), .host, tmp_name, .delete) != .allow or
        trust.check(trust.kernel_actor(), .host, filename, .create) != .allow) return false;
    var buf: [2048]u8 = undefined;
    const len = serialize(&buf);
    if (virtio_file.write_whole(tmp_name, buf[0..len]) != virtio_file.st_ok) return false;
    if (virtio_file.replace(tmp_name, filename) != virtio_file.st_ok) {
        _ = virtio_file.delete(tmp_name);
        return false;
    }
    return true;
}

/// Initializer called during kernel boot: resets defaults then attempts
/// the share load (no-op without a channel).
pub fn init_from_share() void {
    init();
    _ = load_from_share();
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "settings: default initialization and getters" {
    init();
    try std.testing.expectEqualStrings("virelai", get_hostname());
    try std.testing.expectEqualStrings("virelai> ", get_prompt());
    try std.testing.expectEqualStrings("dark", get("theme").?);
    try std.testing.expectEqualStrings("1000", get("scrollback").?);
}

test "settings: login shell defaults to monitor and accepts sh (M45 SH8)" {
    init();
    try std.testing.expectEqualStrings("monitor", login_shell());
    try std.testing.expect(!login_shell_is_sh());
    try std.testing.expectEqual(SetResult.ok, set("shell", "sh"));
    try std.testing.expect(login_shell_is_sh());
    init(); // restore defaults for other tests
}

test "settings: terminal restart defaults to stay and accepts explicit exit" {
    init();
    try std.testing.expectEqualStrings("stay", term_restart_policy());
    try std.testing.expectEqual(SetResult.ok, set("term_restart", "exit"));
    try std.testing.expectEqualStrings("exit", term_restart_policy());
    try std.testing.expectEqual(SetResult.ok, set("term_restart", "bogus"));
    try std.testing.expectEqualStrings("stay", term_restart_policy());
    init();
}

test "settings: debug_font applies to the text layer (M20-U11)" {
    init();
    defer _ = set("debug_font", "false");
    try std.testing.expect(!text.debug_font);
    try std.testing.expectEqual(SetResult.ok, set("debug_font", "true"));
    try std.testing.expect(text.debug_font);
    try std.testing.expectEqual(SetResult.ok, set("debug_font", "off"));
    try std.testing.expect(!text.debug_font);
}

test "settings: set and update existing keys" {
    init();
    try std.testing.expectEqual(SetResult.ok, set("hostname", "my-box"));
    try std.testing.expectEqualStrings("my-box", get_hostname());

    try std.testing.expectEqual(SetResult.ok, set("prompt", "custom# "));
    try std.testing.expectEqualStrings("custom# ", get_prompt());

    try std.testing.expectEqual(SetResult.ok, set("newkey", "newval"));
    try std.testing.expectEqualStrings("newval", get("newkey").?);
}

test "settings: line parser" {
    init();
    try std.testing.expect(parse_line("hostname=testbox"));
    try std.testing.expectEqualStrings("testbox", get_hostname());

    try std.testing.expect(parse_line("prompt = myprompt> "));
    try std.testing.expectEqualStrings("myprompt>", get_prompt());

    try std.testing.expect(!parse_line("no_equals_here"));
}

test "settings: serialization round trip" {
    init();
    try std.testing.expectEqual(SetResult.ok, set("hostname", "roundtrip-host"));
    try std.testing.expectEqual(SetResult.ok, set("prompt", "rt> "));

    var buf: [512]u8 = undefined;
    const len = serialize(&buf);
    try std.testing.expect(len > 0);
    // Version header must be the first line
    try std.testing.expect(std.mem.startsWith(u8, buf[0..len], "#v2\n"));
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "hostname=roundtrip-host\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "prompt=rt> \n") != null);
}

test "settings: version header is present" {
    init();
    var buf: [512]u8 = undefined;
    const len = serialize(&buf);
    try std.testing.expect(len > 3);
    try std.testing.expectEqual(@as(u8, '#'), buf[0]);
    try std.testing.expectEqual(@as(u8, 'v'), buf[1]);
    try std.testing.expectEqual(@as(u8, '2'), buf[2]);
    try std.testing.expectEqual(@as(u8, '\n'), buf[3]);
}

test "settings: the boot WM seat defaults to the Go seat (M59 #1298)" {
    init();
    try std.testing.expectEqualStrings("gotabwm", wm_seat());
    try std.testing.expectEqualStrings("GOTABWM.ELF", wm_seat_kind().program().?);

    // The fallback seat and the explicit shim-only opt-out both persist.
    try std.testing.expectEqual(SetResult.ok, set("wm", "tabwm"));
    try std.testing.expectEqualStrings("TABWM.BIN", wm_seat_kind().program().?);
    try std.testing.expectEqual(SetResult.ok, set("wm", "none"));
    try std.testing.expect(wm_seat_kind().program() == null);

    // An unrecognized value is not a seat: no default manager, never a guess.
    try std.testing.expectEqual(SetResult.ok, set("wm", "wnd"));
    try std.testing.expect(wm_seat_kind() == .none);

    init(); // restore defaults for other tests
    try std.testing.expectEqualStrings("gotabwm", wm_seat());
}

test "settings: a pre-v2 file without wm keeps the flipped default (M59 #1298)" {
    init();
    defer init();
    // A v1 settings file from before the flip: no `wm` line at all.
    try std.testing.expect(apply_bytes("#v1\nhostname=v1box\n"));
    try std.testing.expectEqualStrings("v1box", get_hostname());
    try std.testing.expectEqualStrings("gotabwm", wm_seat());

    // A v1 file that opted out of the default before the flip keeps its choice.
    init();
    try std.testing.expect(apply_bytes("#v1\nwm=tabwm\n"));
    try std.testing.expectEqualStrings("TABWM.BIN", wm_seat_kind().program().?);

    // A file written by a NEWER kernel is refused (honest degradation): the
    // compiled defaults stay in force rather than a partial parse.
    init();
    try std.testing.expect(!apply_bytes("#v3\nwm=tabwm\n"));
    try std.testing.expectEqualStrings("gotabwm", wm_seat());
}

test "settings: a headerless or malformed file is refused whole (M66b #1444)" {
    init();
    defer init();
    // The corrupt shapes: empty, headerless (what a partial in-place write
    // leaves behind), a truncated or malformed header, a merged header+data
    // line, and a newer schema. EVERY one is refused whole — the compiled
    // defaults stay in force, never a partial parse.
    try std.testing.expect(!apply_bytes(""));
    try std.testing.expect(!apply_bytes("hostname=legacy\n"));
    try std.testing.expect(!apply_bytes("wm=none\n"));
    try std.testing.expect(!apply_bytes("#\nwm=none\n"));
    try std.testing.expect(!apply_bytes("#v\nwm=none\n"));
    try std.testing.expect(!apply_bytes("#vx\nwm=none\n"));
    try std.testing.expect(!apply_bytes("#v2x\nwm=none\n"));
    try std.testing.expect(!apply_bytes("#v2 wm=none\n"));
    try std.testing.expect(!apply_bytes("#v300\nwm=none\n"));
    try std.testing.expectEqualStrings("gotabwm", wm_seat());
    try std.testing.expectEqualStrings("virelai", get_hostname());
}

test "settings: a valid v2 file still loads (M66b #1444)" {
    init();
    defer init();
    try std.testing.expect(apply_bytes("#v2\nwm=tabwm\nhostname=m66b\n"));
    try std.testing.expectEqualStrings("tabwm", wm_seat());
    try std.testing.expectEqualStrings("m66b", get_hostname());
}

test "settings: a full legacy table can gain the persisted layout" {
    init();
    defer init();
    try std.testing.expectEqual(@as(usize, 9), count());
    for (0..max_entries - 9 - 1) |i| {
        var key: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&key, "extension{d}", .{i});
        try std.testing.expectEqual(SetResult.ok, set(name, "v"));
    }
    try std.testing.expectEqual(max_entries - 1, count());
    try std.testing.expectEqual(SetResult.ok, set("keyboard_layout", "de"));
    try std.testing.expectEqual(max_entries, count());
    try std.testing.expectEqual(SetResult.table_full, set("overflow", "v"));

    var bytes: [2048]u8 = undefined;
    const len = serialize(&bytes);
    init();
    try std.testing.expect(apply_bytes(bytes[0..len]));
    try std.testing.expectEqualStrings("de", get("keyboard_layout").?);
    try std.testing.expectEqualStrings("v", get("extension7").?);
}

test "settings: the second bank loads a >24-row file whole; table_full at 48 (M183a #3171)" {
    init();
    defer {
        // The fixture file carries font_size — restore the boot look for
        // the rest of the suite (the M80i pattern above).
        text.set_font_size(.small);
        driving_award.apply_grid_font_size(.medium);
        init();
        apply_palette();
    }
    // The wave-5 census as a file: three seeded-key rows plus the fifteen
    // accepted rows make the full known union — 24 distinct keys, the
    // table a pre-M183a kernel held AT its cap. It must still load whole:
    // nothing a 24-cap kernel or codec could write may drop.
    const file_rows = [_][]const u8{
        "hostname=oldbox",   "wm=tabwm",               "theme=light",
        "palette_fg=00ff00", "palette_bg=101418",      "palette_accent=3b82f6",
        "font_size=medium",  "keyboard_layout=us",     "idle_minutes=5",
        "notify_dnd=off",    "notify_sound=on",        "audio_volume=40",
        "timezone=UTC",      "data_root=host",         "term_restart=stay",
        "a11y.contrast=off", "a11y.reduce_motion=off", "a11y.text_scale=100",
    };
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;
    const hdr = "#v2\n";
    @memcpy(buf[pos .. pos + hdr.len], hdr);
    pos += hdr.len;
    for (file_rows) |row| {
        @memcpy(buf[pos .. pos + row.len], row);
        pos += row.len;
        buf[pos] = '\n';
        pos += 1;
    }
    try std.testing.expect(apply_bytes(buf[0..pos]));
    try std.testing.expectEqual(@as(usize, 24), count());
    try std.testing.expectEqualStrings("oldbox", get_hostname());
    try std.testing.expectEqualStrings("tabwm", wm_seat());
    try std.testing.expectEqualStrings("stay", get("term_restart").?);

    // Rows 25..32 ride the second bank — the row past the OLD cap no
    // longer drops at load.
    for (0..8) |i| {
        const row = try std.fmt.bufPrint(buf[pos..], "overflow{d}=zz{d}\n", .{ i, i });
        pos += row.len;
    }
    init();
    try std.testing.expect(apply_bytes(buf[0..pos]));
    try std.testing.expectEqual(@as(usize, 32), count());
    try std.testing.expectEqualStrings("zz7", get("overflow7").?);
    try std.testing.expectEqualStrings("stay", get("term_restart").?);

    // `set` still refuses at the cap, under the same verdict name.
    for (count()..max_entries) |i| {
        var kb: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&kb, "pad{d}", .{i});
        try std.testing.expectEqual(SetResult.ok, set(name, "v"));
    }
    try std.testing.expectEqual(SetResult.table_full, set("one_too_many", "v"));

    // And the grown table round-trips through the unchanged byte format.
    var out: [2048]u8 = undefined;
    const n = serialize(&out);
    init();
    try std.testing.expect(apply_bytes(out[0..n]));
    try std.testing.expectEqual(max_entries, count());
    try std.testing.expectEqualStrings("zz7", get("overflow7").?);
}

test "settings: the a11y rows are accepted, unseeded, and persist once set (M165b #2983)" {
    init();
    defer init();
    // A fresh table seeds none of them: the default SETTINGS.TXT stays
    // byte-identical to a share that never heard of a11y.
    try std.testing.expect(get("a11y.contrast") == null);
    try std.testing.expect(get("a11y.reduce_motion") == null);
    try std.testing.expect(get("a11y.text_scale") == null);
    var buf: [2048]u8 = undefined;
    var len = serialize(&buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "a11y.") == null);
    // Once set they round-trip like every other accepted row.
    try std.testing.expectEqual(SetResult.ok, set("a11y.contrast", "high"));
    try std.testing.expectEqual(SetResult.ok, set("a11y.reduce_motion", "on"));
    try std.testing.expectEqual(SetResult.ok, set("a11y.text_scale", "125"));
    len = serialize(&buf);
    init();
    try std.testing.expect(apply_bytes(buf[0..len]));
    try std.testing.expectEqualStrings("high", get("a11y.contrast").?);
    try std.testing.expectEqualStrings("on", get("a11y.reduce_motion").?);
    try std.testing.expectEqualStrings("125", get("a11y.text_scale").?);
}

test "settings: save_to_share without a channel is an honest no-op (M66b #1444)" {
    init();
    try std.testing.expect(!save_to_share());
    try std.testing.expect(!last_load_refused); // no channel is not a refusal
}

test "settings: current_version constant" {
    try std.testing.expect(current_version >= 1);
    try std.testing.expect(current_version <= 100);
}

test "settings: theme colors and IDs (M27 G20)" {
    init();
    try std.testing.expectEqual(@as(u8, 0), get_theme_id());
    const dark_colors = get_theme_colors();
    try std.testing.expectEqual(@as(u32, 0x182026), dark_colors.bg);
    try std.testing.expectEqual(@as(u32, 0xef4444), dark_colors.@"error");

    set_theme_id(1); // Light
    try std.testing.expectEqual(@as(u8, 1), get_theme_id());
    const light_colors = get_theme_colors();
    try std.testing.expectEqual(@as(u32, 0xf1f5f9), light_colors.bg);
    try std.testing.expectEqual(@as(u32, 0xdc2626), light_colors.@"error");

    set_theme_id(2); // Amber
    try std.testing.expectEqual(@as(u8, 2), get_theme_id());
    const amber_colors = get_theme_colors();
    try std.testing.expectEqual(@as(u32, 0x1a1000), amber_colors.bg);
    try std.testing.expectEqual(@as(u32, 0xff4444), amber_colors.@"error");

    set_theme_id(0); // Reset to dark
    try std.testing.expectEqual(@as(u8, 0), get_theme_id());
}

test "settings: drop-shadow flag (M37 DQ4)" {
    init();
    try std.testing.expect(!get_shadow());
    try std.testing.expectEqualStrings("off", get("shadow").?);
    _ = set("shadow", "on");
    try std.testing.expect(get_shadow());
    _ = set("shadow", "off");
    try std.testing.expect(!get_shadow());
    // Serialized round-trip: the flag persists to the share.
    var buf: [2048]u8 = undefined;
    const len = serialize(&buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "shadow=off") != null);
}

test "settings: font size getters and setters (M27 G21)" {
    init();
    // M80i: the rung now also moves the grid; restore the boot look for
    // the rest of the suite (text small + grid MEDIUM = the 13px cell).
    defer {
        text.set_font_size(.small);
        driving_award.apply_grid_font_size(.medium);
        init();
    }
    try std.testing.expectEqual(@as(u8, 0), get_font_size());

    set_font_size(1);
    try std.testing.expectEqual(@as(u8, 1), get_font_size());
    try std.testing.expectEqualStrings("medium", get("font_size").?);

    set_font_size(2);
    try std.testing.expectEqual(@as(u8, 2), get_font_size());
    try std.testing.expectEqualStrings("large", get("font_size").?);

    set_font_size(0);
    try std.testing.expectEqual(@as(u8, 0), get_font_size());
    try std.testing.expectEqualStrings("small", get("font_size").?);
}

test "settings: font_size drives BOTH consumers; absent keeps the boot look (M80i #1725)" {
    init();
    defer {
        text.set_font_size(.small);
        driving_award.apply_grid_font_size(.medium);
        init();
    }
    // An ABSENT key applies nothing: the boot look is text small + the
    // grid's MEDIUM rung (the 13px 8x16 cell — font_metrics' compiled
    // default). Loading a file without the key must not move the ladder.
    try std.testing.expectEqual(@as(u8, 0), get_font_size());
    try std.testing.expect(apply_bytes("#v2\nhostname=x\n"));
    try std.testing.expectEqual(font_metrics.Size.medium, font_metrics.size);
    try std.testing.expectEqual(@as(u32, 8), font_metrics.cell_w);
    try std.testing.expectEqual(text.FontSize.small, text.font_size);
    // PRESENT: the rung applies to both ladders at load time.
    try std.testing.expect(apply_bytes("#v2\nfont_size=large\n"));
    try std.testing.expectEqual(font_metrics.Size.large, font_metrics.size);
    try std.testing.expectEqual(@as(u32, 10), font_metrics.cell_w);
    try std.testing.expectEqual(@as(u32, 21), font_metrics.cell_h);
    try std.testing.expectEqual(text.FontSize.large, text.font_size);
    // `small` shrinks the grid BELOW the boot cell — the said wart of
    // one key with two ladders (the text layer's small is its default,
    // the grid's default is medium).
    try std.testing.expectEqual(SetResult.ok, set("font_size", "small"));
    try std.testing.expectEqual(font_metrics.Size.small, font_metrics.size);
    try std.testing.expectEqual(@as(u32, 7), font_metrics.cell_w);
    try std.testing.expectEqual(@as(u32, 13), font_metrics.cell_h);
    try std.testing.expectEqual(text.FontSize.small, text.font_size);
    // An unrecognized value applies NOTHING: both consumers keep theirs.
    try std.testing.expectEqual(SetResult.ok, set("font_size", "bogus"));
    try std.testing.expectEqual(font_metrics.Size.small, font_metrics.size);
    try std.testing.expectEqual(text.FontSize.small, text.font_size);
}

test "settings: the palette schema is additive — a fresh table stays dark (M73m #1662)" {
    init();
    // A fresh table carries NO palette rows and keeps theme=dark: the bytes
    // a fresh share writes are byte-identical to the pre-M73m image, and a
    // fresh image resolves exactly what it resolved before.
    var buf: [2048]u8 = undefined;
    const len = serialize(&buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "palette_") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "theme=dark\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "theme=custom") == null);
    try std.testing.expectEqual(@as(u8, 0), get_theme_id());
    // The accepted keys still read back: unset = the compiled dark default.
    try std.testing.expect(get("palette_fg") == null);
    try std.testing.expectEqual(palette_fg_default, palette_fg());
    try std.testing.expectEqual(palette_bg_default, palette_bg());
    try std.testing.expectEqual(palette_accent_default, palette_accent());
    // The value grammar: EXACTLY six hex digits, case-insensitive, no 0x.
    try std.testing.expectEqual(@as(?u32, 0x20ff9e), parse_hex6("20ff9e"));
    try std.testing.expectEqual(@as(?u32, 0x20FF9E), parse_hex6("20FF9E"));
    try std.testing.expect(parse_hex6("20ff9") == null); // five digits
    try std.testing.expect(parse_hex6("20ff9e0") == null); // seven
    try std.testing.expect(parse_hex6("20ff9z") == null); // not hex
    try std.testing.expect(parse_hex6("0x20ff9e") == null); // no prefix
    try std.testing.expect(parse_hex6("") == null);
    // The theme vocabulary grew a fourth name, and only a fourth.
    try std.testing.expectEqual(SetResult.ok, set("theme", "custom"));
    try std.testing.expectEqual(@as(u8, driving_award.theme_id_custom), get_theme_id());
    init(); // restore defaults for the other tests
    apply_palette();
}

test "settings: a custom palette round-trips store -> resolver -> exact RGB (M73m #1662)" {
    init();
    try std.testing.expectEqual(SetResult.ok, set("theme", "custom"));
    try std.testing.expectEqual(SetResult.ok, set("palette_fg", "20ff9e"));
    try std.testing.expectEqual(SetResult.ok, set("palette_bg", "0b1020"));
    try std.testing.expectEqual(SetResult.ok, set("palette_accent", "ff7733"));
    // The store's numbers land on the resolver EXACTLY (no rounding, no
    // nearest-colour step) and the preset id became custom.
    try std.testing.expectEqual(@as(u8, driving_award.theme_id_custom), driving_award.theme_id);
    try std.testing.expectEqual(@as(u32, 0x20ff9e), driving_award.custom_fg);
    try std.testing.expectEqual(@as(u32, 0x0b1020), driving_award.custom_bg);
    try std.testing.expectEqual(@as(u32, 0xff7733), driving_award.custom_accent);
    var d = driving_award.terminalThemeDefaults();
    try std.testing.expectEqual(@as(u32, 0x20ff9e), d.fg);
    try std.testing.expectEqual(@as(u32, 0x0b1020), d.bg);
    // ...and they SURVIVE the bytes: serialize into a fresh table, then let
    // the load path resolve them again (the round trip the card pins).
    var buf: [2048]u8 = undefined;
    const len = serialize(&buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "theme=custom\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "palette_fg=20ff9e\n") != null);
    init(); // a fresh boot's compiled defaults...
    apply_palette();
    try std.testing.expectEqual(@as(u8, 0), driving_award.theme_id);
    try std.testing.expectEqual(palette_fg_default, palette_fg());
    try std.testing.expect(apply_bytes(buf[0..len])); // ...then the persisted bytes
    try std.testing.expectEqual(@as(u8, 3), get_theme_id());
    try std.testing.expectEqual(@as(u32, 0x20ff9e), palette_fg());
    try std.testing.expectEqual(@as(u32, 0x0b1020), palette_bg());
    try std.testing.expectEqual(@as(u32, 0xff7733), palette_accent());
    try std.testing.expectEqual(@as(u8, driving_award.theme_id_custom), driving_award.theme_id);
    try std.testing.expectEqual(@as(u32, 0x20ff9e), driving_award.custom_fg);
    d = driving_award.terminalThemeDefaults();
    try std.testing.expectEqual(@as(u32, 0x20ff9e), d.fg);
    try std.testing.expectEqual(@as(u32, 0x0b1020), d.bg);
    // Restore: the compiled defaults, dark, for the rest of the suite.
    init();
    apply_palette();
    try std.testing.expectEqual(@as(u8, 0), driving_award.theme_id);
}

test "settings: a partial or invalid palette falls back safely (M73m #1662)" {
    init();
    // An invalid VALUE: the row stores (the key is valid), the colour is
    // refused, and the compiled dark default stands — never a half-read
    // number, never garbage.
    try std.testing.expectEqual(SetResult.ok, set("theme", "custom"));
    try std.testing.expectEqual(SetResult.ok, set("palette_fg", "zzzzzz"));
    try std.testing.expectEqualStrings("zzzzzz", get("palette_fg").?); // stored...
    try std.testing.expectEqual(palette_fg_default, palette_fg()); // ...refused
    try std.testing.expectEqual(palette_fg_default, driving_award.custom_fg);
    // A PARTIAL palette: only fg chosen, bg/accent keep their defaults, so
    // the resolver still produces a complete pair.
    try std.testing.expectEqual(SetResult.ok, set("palette_fg", "20ff9e"));
    try std.testing.expectEqual(@as(u32, 0x20ff9e), driving_award.custom_fg);
    try std.testing.expectEqual(palette_bg_default, driving_award.custom_bg);
    try std.testing.expectEqual(palette_accent_default, driving_award.custom_accent);
    // An unrecognized theme name lands on dark — deterministic at set AND at
    // load, never a stale id the resolver would guess past.
    try std.testing.expectEqual(SetResult.ok, set("theme", "bogus"));
    try std.testing.expectEqual(@as(u8, 0), get_theme_id());
    try std.testing.expectEqual(@as(u8, 0), driving_award.theme_id);
    // A refused (headerless) load resolves NOTHING: the fresh compiled
    // defaults are already in force and stay there (M66b's fail-closed).
    init();
    apply_palette();
    try std.testing.expect(!apply_bytes("theme=custom\npalette_fg=20ff9e\n"));
    try std.testing.expectEqual(@as(u8, 0), get_theme_id());
    try std.testing.expectEqual(palette_fg_default, palette_fg());
    try std.testing.expectEqual(@as(u8, 0), driving_award.theme_id);
    // Restore defaults for the other tests.
    init();
    apply_palette();
}
