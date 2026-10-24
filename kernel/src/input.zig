//! Milestone seven, card I3 (claim 6050): keyboard/pointer event FIFO +
//! keycode decode → Road Pops.
//!
//! The XHCI interrupt-IN reports (I1/I2) land here as keyboard/pointer
//! events. The shell idle loop is the drain site (the card-3d shell-idle-
//! drain pattern, next to the net RX drain): `drain()` polls the armed
//! interrupt-IN endpoints, decodes keyboard HID boot reports (modifier +
//! 6-key rollover) into UTF-8 console bytes / Unicode app codepoints through a
//! pure keymap, and records
//! transport-specific pointer reports (native VZ report-ID 1 or canonical
//! custom-virtio buttons + absolute X/Y). The decoded bytes sit in a bounded
//! pure-BSS FIFO that the Road Pops tee's read path (`pop_byte`) hands to the shell's line
//! editor — the FIRST screen-side keystrokes reach the terminal.
//!
//! The keymap covers the usable printable subset: letters (shift → caps,
//! ctrl → the ADR 0008 D2 editing chords 0x01..0x1a), digits (shift → the
//! shifted symbol), Enter, Backspace, Tab, Space, the common punctuation,
//! and the editing nav cluster (arrows, Home, End, Delete) encoded as
//! `ESC [ <final>` sequences so the line editor stays byte-driven. Anything
//! outside the subset is honestly refused (no byte is invented).
//!
//! No libc, no POSIX, no allocation. The FIFO and driver state are fixed
//! BSS (the card-3d pattern); a full FIFO drops the newest byte and counts
//! it (bounded, never wraps).
//!
//! Host tests exercise the pure surface (keymap, FIFO, keyboard-report
//! decode); the `drain()` path is hardware-gated (a no-op when unarmed).

const std = @import("std");
const builtin = @import("builtin");
const xhci = @import("xhci.zig"); // I1/I2: the XHCI transport + enumerated HID devices
const app_events = @import("events.zig"); // Milestone 9 (claim 7206): application event queues
const driving_award = @import("driving_award.zig"); // Milestone six G5: window focus query for event routing
const terminal = @import("terminal.zig"); // #1082 (ADR 0020 A5): window-front-end key routing
const svclock = @import("svclock.zig"); // claim 9498 follow-on: the keyboard decode interleaves WIN + EV state
const klog = @import("klog.zig"); // M49 SD5 (#1132): the terminal copy audit line
const settings = @import("settings.zig"); // M83d2 (#1786): selected kernel keymap

pub const KeyboardLayout = enum { us, de };

/// Resolve the optional persisted selector. Any absent or unknown value keeps
/// the compiled US table, without adding a default row to SETTINGS.TXT.
pub fn selected_layout() KeyboardLayout {
    const val = settings.get("keyboard_layout") orelse return .us;
    return if (std.mem.eql(u8, val, "de")) .de else .us;
}

pub const max_fifo: usize = 64;

/// The longest key sequence the keymap can produce (a modified function key
/// or Insert, e.g. `ESC [ 15;5~`).
pub const max_key_bytes: usize = 7;

/// HID keyboard boot-protocol modifier bit masks.
const mod_lctrl: u8 = 0x01;
const mod_lshift: u8 = 0x02;
const mod_rctrl: u8 = 0x10;
const mod_rshift: u8 = 0x20;

/// The `input` monitor command's report shape.
pub const Report = struct {
    armed: bool,
    fifo_used: usize,
    fifo_max: usize,
    dropped: usize,
    events: usize,
    kb_mods: u8,
    kb_last_usage: u8,
    kb_last_byte: u8,
    ptr_buttons: u8,
    ptr_x: u16,
    ptr_y: u16,
    ptr_reports: usize,
};

// ---------------------------------------------------------------------------
// Driver state (pure BSS)
// ---------------------------------------------------------------------------

var armed_global: bool = false;

var fifo: [max_fifo]u8 = undefined;
var fifo_head: usize = 0;
var fifo_count: usize = 0;
var dropped: usize = 0;
var events: usize = 0;

var kb_mods: u8 = 0;
var kb_held: [6]u8 = @as([6]u8, @splat(@as(u8, 0)));
var kb_last_usage: u8 = 0;
var kb_last_byte: u8 = 0;

var ptr_buttons: u8 = 0;
var ptr_x: u16 = 0;
var ptr_y: u16 = 0;
var ptr_reports: usize = 0;
/// Card U4 (claim 4993): the pointer became observable (at least one
/// report) and the click edge (buttons 0 -> nonzero) latches here until
/// the window manager consumes it via `take_click`.
var ptr_valid: bool = false;
var ptr_click_pending: bool = false;
/// M49 SD5 (#1132): the left-button press sample, latched even when a whole
/// injected drag is drained in one pass (last-write-wins state would lose
/// the down edge). Consumed by `take_press`.
var ptr_press_pending: bool = false;
var ptr_press_x: u16 = 0;
var ptr_press_y: u16 = 0;
/// Card U5 (claim 0935): the Alt+Tab chord (modifier 0x04/0x40 + Tab
/// usage 0x2b) latches here — the shell idle loop consumes it as a
/// focus-cycle request (ADR 0008 D4's keyboard cycling). M32 WMS8 Gate 5
/// (issue #628): the OTHER geometry chords (tile/master/min/max/ws/
/// fullscreen/aot) are DELETED — WMS5 Gate 2 drained them to the WM; the
/// applied primitives remain, driven by `dui`/SET_STATE, but the kernel no
/// longer self-decides them from the keyboard.
var alt_tab_pending: bool = false;
var alt_tab_shift: bool = false;
/// Arc4 #238: Ctrl+Shift+B lowers the focused window to back. KEPT — the WM
/// does not serve this chord yet (no WM coverage would regress shim mode).
var lower_back_pending: bool = false;
/// M21 W10: Alt+arrow movement. KEPT — the WM does not serve this chord yet.
var move_pending_dx: i32 = 0;
var move_pending_dy: i32 = 0;
var move_pending_fine: bool = false;

// M32 WMS8 Gate 5 (issue #628): the geometry chord pending flags for
// workspace switch/cycle, tile toggle, master swap, minimize, maximize,
// fullscreen, and always-on-top are DELETED — WMS5 Gate 2 drained the
// geometry-policy decision to the WM (kind-21 WM_KEY -> handle_wm_key ->
// SET_WINDOW/SET_STATE). With a WM registered the kernel's own consumers
// were provably dormant (gated behind !wm_owns_input); per WMS8's delete
// rule (the W5 matrix re-ran green while seated) they are removed. Shim
// end-state: the drained geometry chords now do nothing with no WM (the
// issue's "no compositing policy" end-state).

/// Diagnostic hooks (kernel/src/main.zig wires these to uart_puts/uart_hex
/// under `--input`; null in host tests and the default VM).
pub var debug: ?*const fn ([]const u8) void = null;
pub var debug_hex: ?*const fn (u64) void = null;

fn dbg(bytes: []const u8) void {
    if (debug) |d| d(bytes);
}
fn dbg_hex(v: u64) void {
    if (debug_hex) |d| d(v);
}

/// Arm the input path (called by kernel/src/main.zig after the XHCI
/// transport is up and the devices are enumerated). Until armed, `drain()`
/// is a no-op and `pop_byte` returns null.
pub fn arm() void {
    armed_global = true;
}

pub fn armed() bool {
    return armed_global;
}

// ---------------------------------------------------------------------------
// HID-usage → ASCII keymap (pure — host-testable)
// ---------------------------------------------------------------------------

/// M80k (#1727): the terminal hygiene chords. `ctrl-shift-K` clears the
/// scrollback (the ED 3 the user could not type), `ctrl-shift-R` is the
/// soft reset (styles and modes, grid intact) and `ctrl-shift-alt-R` the
/// full RIS. Split out as a pure classifier so the chord table is
/// pinnable without a window: the dispatch site stays a switch, and the
/// "alt is the RIS, not the soft reset" rule is testable rather than
/// eyeballed. Everything else is no chord.
pub const HygieneChord = enum { clear_scrollback, soft_reset, ris };

/// The chord for one key-DOWN edge, or null when this is not a hygiene
/// chord. The modifiers are the same booleans the chrome table tests, so
/// the two can never disagree about what a chord is.
pub fn hygieneChord(usage: u8, shift: bool, alt: bool, ctrl: bool) ?HygieneChord {
    if (!ctrl or !shift) return null;
    return switch (usage) {
        0x0e => .clear_scrollback, // 'k'
        0x15 => if (alt) .ris else .soft_reset, // 'r'
        else => null,
    };
}

const KeyPair = struct { plain: u21 = 0, shifted: u21 = 0 };

/// Punctuation rows are indexed from usage 0x2d through 0x38. Zero means
/// the physical key has no symbol in this layout's printable subset.
const us_punctuation = [_]KeyPair{
    .{ .plain = '-', .shifted = '_' },
    .{ .plain = '=', .shifted = '+' },
    .{ .plain = '[', .shifted = '{' },
    .{ .plain = ']', .shifted = '}' },
    .{ .plain = '\\', .shifted = '|' },
    .{},
    .{ .plain = ';', .shifted = ':' },
    .{ .plain = '\'', .shifted = '"' },
    .{ .plain = '`', .shifted = '~' },
    .{ .plain = ',', .shifted = '<' },
    .{ .plain = '.', .shifted = '>' },
    .{ .plain = '/', .shifted = '?' },
};
const de_punctuation = [_]KeyPair{
    .{ .plain = 0x00df, .shifted = '?' }, // ß / ?
    .{}, // dead acute key
    .{ .plain = 0x00fc, .shifted = 0x00dc }, // ü / Ü
    .{ .plain = '+', .shifted = '*' },
    .{ .plain = '#', .shifted = '\'' },
    .{},
    .{ .plain = 0x00f6, .shifted = 0x00d6 }, // ö / Ö
    .{ .plain = 0x00e4, .shifted = 0x00c4 }, // ä / Ä
    .{ .plain = '^', .shifted = 0x00b0 }, // ^ / °; dead keys are not composed
    .{ .plain = ',', .shifted = ';' },
    .{ .plain = '.', .shifted = ':' },
    .{ .plain = '-', .shifted = '_' },
};

const LayoutTable = struct {
    letters: []const u8,
    shifted_digits: [10]u21,
    punctuation: *const [12]KeyPair,
    iso_angle_bracket_key: bool = false,
};

const us_table = LayoutTable{
    .letters = "abcdefghijklmnopqrstuvwxyz",
    .shifted_digits = .{ '!', '@', '#', '$', '%', '^', '&', '*', '(', ')' },
    .punctuation = &us_punctuation,
};
const de_table = LayoutTable{
    // German QWERTZ swaps the symbols on the physical Y and Z keys.
    .letters = "abcdefghijklmnopqrstuvwxzy",
    .shifted_digits = .{ '!', '"', 0x00a7, '$', '%', '&', '/', '(', ')', '=' },
    .punctuation = &de_punctuation,
    .iso_angle_bracket_key = true,
};

fn layout_table(layout: KeyboardLayout) *const LayoutTable {
    return if (layout == .de) &de_table else &us_table;
}

/// Map a HID keyboard boot-protocol usage through the selected data table to
/// its Unicode symbol. KEY_DOWN/KEY_UP carry this codepoint in the existing
/// arg1 field (ADR 0014); kind-21 remains raw usage+flags.
pub fn hid_to_codepoint_layout(layout: KeyboardLayout, usage: u8, shift: bool) ?u21 {
    const table = layout_table(layout);
    if (usage >= 0x04 and usage <= 0x1d) {
        const plain = table.letters[usage - 0x04];
        return if (shift) 'A' + (plain - 'a') else plain;
    }
    if (usage >= 0x1e and usage <= 0x27) {
        const i = usage - 0x1e;
        return if (shift) table.shifted_digits[i] else "1234567890"[i];
    }
    if (usage >= 0x2d and usage <= 0x38) {
        const pair = table.punctuation[usage - 0x2d];
        const symbol = if (shift) pair.shifted else pair.plain;
        return if (symbol == 0) null else symbol;
    }
    return switch (usage) {
        0x28 => '\n',
        0x2a => 0x08,
        0x2b => '\t',
        0x2c => ' ',
        0x64 => if (table.iso_angle_bracket_key) (if (shift) '>' else '<') else null,
        else => null,
    };
}

/// Map a HID usage to the ASCII subset used by control chords and compose
/// lookup. Printable app and terminal paths use the full codepoint mapping.
pub fn hid_to_ascii_layout(layout: KeyboardLayout, usage: u8, shift: bool) ?u8 {
    const cp = hid_to_codepoint_layout(layout, usage, shift) orelse return null;
    if (cp > 0x7f) return null;
    return @intCast(cp);
}

/// Map the printable key using the persisted layout in force.
pub fn hid_to_codepoint(usage: u8, shift: bool) ?u21 {
    return hid_to_codepoint_layout(selected_layout(), usage, shift);
}

/// Map the ASCII subset using the persisted layout in force.
pub fn hid_to_ascii(usage: u8, shift: bool) ?u8 {
    return hid_to_ascii_layout(selected_layout(), usage, shift);
}

fn emitCsiTilde(out: *[max_key_bytes]u8, number: u8, modifier: u8) usize {
    out[0] = 0x1b;
    out[1] = '[';
    var i: usize = 2;
    if (number >= 10) {
        out[i] = '0' + number / 10;
        i += 1;
    }
    out[i] = '0' + number % 10;
    i += 1;
    if (modifier != 1) {
        out[i] = ';';
        out[i + 1] = '0' + modifier;
        i += 2;
    }
    out[i] = '~';
    return i + 1;
}

fn emitFunctionKey(out: *[max_key_bytes]u8, usage: u8, modifier: u8) usize {
    switch (usage) {
        0x3a...0x3d => { // F1-F4: xterm's unmodified SS3 form.
            const final = 'P' + (usage - 0x3a);
            if (modifier == 1) {
                out[0] = 0x1b;
                out[1] = 'O';
                out[2] = final;
                return 3;
            }
            out[0] = 0x1b;
            out[1] = '[';
            out[2] = '1';
            out[3] = ';';
            out[4] = '0' + modifier;
            out[5] = final;
            return 6;
        },
        // USB HID function-row usages run F1=0x3a..F12=0x45 — the table
        // used to skip 0x3e (real F5), so every F-key from F5 on emitted
        // the previous key's tilde spelling (F10 arrived as F9's
        // `ESC[20~`) and F5 emitted nothing at all.
        0x3e => return emitCsiTilde(out, 15, modifier), // F5
        0x3f => return emitCsiTilde(out, 17, modifier), // F6
        0x40 => return emitCsiTilde(out, 18, modifier), // F7
        0x41 => return emitCsiTilde(out, 19, modifier), // F8
        0x42 => return emitCsiTilde(out, 20, modifier), // F9
        0x43 => return emitCsiTilde(out, 21, modifier), // F10
        0x44 => return emitCsiTilde(out, 23, modifier), // F11
        0x45 => return emitCsiTilde(out, 24, modifier), // F12
        else => return 0,
    }
}

fn emitUtf8(cp: u21, out: *[max_key_bytes]u8) usize {
    if (cp <= 0x7f) {
        out[0] = @intCast(cp);
        return 1;
    }
    if (cp <= 0x7ff) {
        out[0] = @intCast(0xc0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3f));
        return 2;
    }
    if (cp >= 0xd800 and cp <= 0xdfff) return 0;
    if (cp <= 0xffff) {
        out[0] = @intCast(0xe0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3f));
        out[2] = @intCast(0x80 | (cp & 0x3f));
        return 3;
    }
    if (cp <= 0x10ffff) {
        out[0] = @intCast(0xf0 | (cp >> 18));
        out[1] = @intCast(0x80 | ((cp >> 12) & 0x3f));
        out[2] = @intCast(0x80 | ((cp >> 6) & 0x3f));
        out[3] = @intCast(0x80 | (cp & 0x3f));
        return 4;
    }
    return 0;
}

/// Decode one HID keyboard usage (with shift/alt/ctrl modifiers) into 0-7
/// bytes of console input, written to `out`; returns the byte count (0 =
/// the usage is outside the usable subset — no bytes are invented). The
/// editing nav cluster arrives as `ESC [ <final>` sequences, modified nav
/// uses xterm's `CSI 1;<modifier><final>` form, and F1-F12/Insert use
/// xterm's SS3/CSI-tilde forms. Ctrl + a-z remains the ASCII control-code
/// mapping (ADR 0008 D2); printable keys use UTF-8 for the selected symbol.
pub fn hid_to_bytes(usage: u8, shift: bool, alt: bool, ctrl: bool, out: *[max_key_bytes]u8) usize {
    const modifier: u8 = 1 + @as(u8, if (shift) 1 else 0) +
        @as(u8, if (alt) 2 else 0) + @as(u8, if (ctrl) 4 else 0);

    const nav_final: u8 = switch (usage) {
        0x4f => 'C', // Right
        0x50 => 'D', // Left
        0x51 => 'B', // Down
        0x52 => 'A', // Up
        0x4a => 'H', // Home
        0x4d => 'F', // End
        else => 0,
    };
    if (nav_final != 0) {
        if (modifier == 1) {
            out[0] = 0x1b;
            out[1] = '[';
            out[2] = nav_final;
            return 3;
        }
        out[0] = 0x1b;
        out[1] = '[';
        out[2] = '1';
        out[3] = ';';
        out[4] = '0' + modifier;
        out[5] = nav_final;
        return 6;
    }

    // Function keys and Insert have xterm modifier forms too, so they are
    // decoded before the ctrl-letter fast path below.
    switch (usage) {
        0x3a...0x45 => return emitFunctionKey(out, usage, modifier),
        0x70 => return emitCsiTilde(out, 2, modifier), // Insert
        else => {},
    }

    if (ctrl) {
        if (usage >= 0x04 and usage <= 0x1d) {
            const letter = hid_to_ascii_layout(selected_layout(), usage, false) orelse return 0;
            if (letter < 'a' or letter > 'z') return 0;
            out[0] = letter - 'a' + 0x01; // Ctrl + the layout's a-z
            return 1;
        }
        // Preserve the original honest refusal for Ctrl+Enter, Ctrl+Space,
        // and every other non-letter/non-nav usage.
        return 0;
    }

    switch (usage) {
        0x29 => { // Escape (lone ESC — the line editor treats it as a no-op key)
            out[0] = 0x1b;
            return 1;
        },
        0x4b => { // PageUp (the shell's scroll interceptor consumes CSI 5 ~)
            out[0] = 0x1b;
            out[1] = '[';
            out[2] = '5';
            out[3] = '~';
            return 4;
        },
        0x4e => { // PageDown (the shell's scroll interceptor consumes CSI 6 ~)
            out[0] = 0x1b;
            out[1] = '[';
            out[2] = '6';
            out[3] = '~';
            return 4;
        },
        0x4c => { // Delete (forward)
            out[0] = 0x1b;
            out[1] = '[';
            out[2] = '3';
            out[3] = '~';
            return 4;
        },
        else => {},
    }
    const cp = hid_to_codepoint(usage, shift) orelse return 0;
    return emitUtf8(cp, out);
}

// ---------------------------------------------------------------------------
// Bounded byte FIFO (the line-editor feed)
// ---------------------------------------------------------------------------

fn push_byte(b: u8) void {
    if (fifo_count >= max_fifo) {
        dropped += 1;
        return;
    }
    fifo[(fifo_head + fifo_count) % max_fifo] = b;
    fifo_count += 1;
}

/// Pop the next decoded keyboard byte, or null when the FIFO is empty.
/// The Road Pops tee consults this before falling back to serial.
pub fn pop_byte() ?u8 {
    if (fifo_count == 0) return null;
    const b = fifo[fifo_head];
    fifo_head = (fifo_head + 1) % max_fifo;
    fifo_count -= 1;
    return b;
}

// ---------------------------------------------------------------------------
// Arc5 #245: Compose state machine (ADR 0014)
// ---------------------------------------------------------------------------

/// Compose state: IDLE (normal) or WAITING (Alt held, awaiting second key).
const ComposeState = enum { idle, waiting };

/// A single compose pair: two HID usage IDs → Unicode codepoint.
const ComposePair = struct {
    first: u8,
    second: u8,
    codepoint: u21,
};

/// Compile-time compose table: ~27 pairs for common accented characters.
/// Alt + first_key + second_key → Unicode codepoint.
const compose_table = [_]ComposePair{
    // Alt + e + vowel → acute accent
    .{ .first = 0x08, .second = 0x04, .codepoint = 0x00e1 }, // e+a → á
    .{ .first = 0x08, .second = 0x05, .codepoint = 0x00e9 }, // e+e → é
    .{ .first = 0x08, .second = 0x0c, .codepoint = 0x00ed }, // e+i → í
    .{ .first = 0x08, .second = 0x12, .codepoint = 0x00f3 }, // e+o → ó
    .{ .first = 0x08, .second = 0x18, .codepoint = 0x00fa }, // e+u → ú
    // Alt + u + vowel → umlaut
    .{ .first = 0x18, .second = 0x04, .codepoint = 0x00e4 }, // u+a → ä
    .{ .first = 0x18, .second = 0x05, .codepoint = 0x00eb }, // u+e → ë
    .{ .first = 0x18, .second = 0x0c, .codepoint = 0x00ef }, // u+i → ï
    .{ .first = 0x18, .second = 0x12, .codepoint = 0x00f6 }, // u+o → ö
    .{ .first = 0x18, .second = 0x18, .codepoint = 0x00fc }, // u+u → ü
    // Alt + ` + vowel → grave accent
    .{ .first = 0x35, .second = 0x04, .codepoint = 0x00e0 }, // `+a → à
    .{ .first = 0x35, .second = 0x05, .codepoint = 0x00e8 }, // `+e → è
    .{ .first = 0x35, .second = 0x0c, .codepoint = 0x00ec }, // `+i → ì
    .{ .first = 0x35, .second = 0x12, .codepoint = 0x00f2 }, // `+o → ò
    .{ .first = 0x35, .second = 0x18, .codepoint = 0x00f9 }, // `+u → ù
    // Alt + n + n → tilde
    .{ .first = 0x11, .second = 0x11, .codepoint = 0x00f1 }, // n+n → ñ
    // Alt + c → cedilla
    .{ .first = 0x06, .second = 0x06, .codepoint = 0x00e7 }, // c+c → ç
};

/// Current compose state (BSS, bounded, no allocation).
var compose_state: ComposeState = .idle;
/// The first key of a pending compose sequence (HID usage).
var compose_first: u8 = 0;

/// Look up a compose pair in the table. Returns the Unicode codepoint or null.
fn compose_lookup(first: u8, second: u8) ?u21 {
    for (compose_table) |pair| {
        if (pair.first == first and pair.second == second) return pair.codepoint;
    }
    return null;
}

/// Reset compose state (called on Alt release or focus change).
pub fn compose_reset() void {
    compose_state = .idle;
}

/// List all compose sequences for the `compose` monitor command.
pub fn compose_list(con: anytype) void {
    con.print_line("compose: Alt + key1 + key2 → Unicode codepoint");
    for (compose_table) |pair| {
        con.puts("  Alt+");
        con.puts(&[_]u8{hid_to_ascii(pair.first, false) orelse '?'});
        con.puts("+");
        con.puts(&[_]u8{hid_to_ascii(pair.second, false) orelse '?'});
        con.puts(" → U+");
        var buf: [4]u8 = undefined;
        var v = pair.codepoint;
        var i: usize = 4;
        while (i > 0) : (i -= 1) {
            const nib = @as(u8, @intCast(v & 0xf));
            buf[i - 1] = if (nib < 10) '0' + nib else 'a' + nib - 10;
            v >>= 4;
        }
        con.print_line(&buf);
    }
}

// ---------------------------------------------------------------------------
// Report decode (keyboard boot report + transport-specific absolute pointer)
// ---------------------------------------------------------------------------

/// Map raw HID keyboard boot report modifier byte to ADR 0009 modifier flags.
pub fn hid_modifiers_to_flags(mods: u8) u16 {
    var flags: u16 = 0;
    if ((mods & mod_lshift) != 0 or (mods & mod_rshift) != 0) flags |= app_events.MOD_SHIFT;
    if ((mods & mod_lctrl) != 0 or (mods & mod_rctrl) != 0) flags |= app_events.MOD_CTRL;
    if ((mods & 0x04) != 0 or (mods & 0x40) != 0) flags |= app_events.MOD_ALT;
    if ((mods & 0x08) != 0 or (mods & 0x80) != 0) flags |= app_events.MOD_CMD;
    return flags;
}

/// Decode an 8-byte HID keyboard boot report: byte 0 = modifier, bytes 2-7
/// = up to six held keycodes (the boot protocol's rollover limit). A keycode
/// present now but not in the previously-held set is a key-DOWN; its ASCII
/// byte (shift applied) is pushed. The held set is then updated.
/// Card E2 (claim 7206): when a user window is focused, KEY_DOWN / KEY_UP
/// events are pushed to the owning process's event queue.
pub fn decode_keyboard_report(rep: []const u8) void {
    if (rep.len != 8 or rep[1] != 0) return;
    // Boot rollover/error usages are not keys or an all-up report. Preserve
    // the last valid held set until a valid report supplies the release.
    for (rep[2..8]) |k| if (k >= 1 and k <= 3) return;
    // Per-domain locks (claim 9498 follow-on): the decode interleaves WIN
    // state (driving_award focus/wm-ownership reads, the wm_key_hook) with
    // EV pushes (app_events) — take win+ev in canonical order for the whole
    // decode. acquire_missing: a nested call (input.drain under the idle
    // loop's own win+ev hold) takes nothing; a fresh entry (the custom-
    // virtio input hook, IRQ-masked) spins only against a completing
    // holder, which the IRQ-masking lock guarantees.
    const took = svclock.acquire_missing(svclock.dom_bit(.win) | svclock.dom_bit(.ev));
    defer svclock.release_set(took);
    const mods = rep[0];
    const flags = hid_modifiers_to_flags(mods);
    const shift = (flags & app_events.MOD_SHIFT) != 0;
    const ctrl = (flags & app_events.MOD_CTRL) != 0;
    const alt = (flags & app_events.MOD_ALT) != 0;
    kb_mods = mods;
    var keys: [6]u8 = @as([6]u8, @splat(@as(u8, 0)));
    for (rep[2..8], 0..) |k, i| {
        var duplicate = false;
        for (keys[0..i]) |h| {
            if (h == k) duplicate = true;
        }
        keys[i] = if (duplicate) 0 else k;
    }
    // Card U5 (ADR 0008 D4): Alt+Tab cycles window focus — the
    // chord is consumed as a window-manager signal across all windows.
    // C2 (M15): capture Shift for reverse cycling.
    for (keys) |k| {
        // M32 WMS5 Gate 2 (claim 4278): while a WM owns input, the raw
        // key stream fans out to it on key-DOWN edges (kind 21 WM_KEY) —
        // the WM, not the kernel, decides geometry from chords. The
        // kernel's own geometry pending flags below are gated behind
        // !wm_owns_input; plain KEY_DOWN/KEY_UP delivery to the focused
        // window (card E2) is unchanged.
        if (k != 0 and driving_award.wm_owns_input) {
            var edge = true;
            for (kb_held) |h| {
                if (h == k) {
                    edge = false;
                    break;
                }
            }
            if (edge) {
                if (driving_award.wm_key_hook) |hook| hook(k, flags);
            }
        }
        if (k == 0x2b and alt) {
            var held = false;
            for (kb_held) |h| {
                if (h == k) {
                    held = true;
                    break;
                }
            }
            if (!held and !driving_award.wm_owns_input) {
                alt_tab_pending = true;
                alt_tab_shift = shift;
            }
        }
        // M21 W4: Alt+` workspace-CYCLE is DELETED (M32 WMS8 Gate 5, issue
        // #628) — WMS5 Gate 2 drained it to the WM (kind-21 -> handle_wm_key
        // usage 0x35). The kernel no longer self-cycles workspaces.
        // Arc4 #238: Ctrl+Shift+B lowers focused window to back (KEPT — no
        // WM coverage yet).
        if (k == 0x05 and (flags & app_events.MOD_CTRL) != 0 and (flags & app_events.MOD_SHIFT) != 0) {
            var held = false;
            for (kb_held) |h| {
                if (h == k) {
                    held = true;
                    break;
                }
            }
            if (!held and !driving_award.wm_owns_input) {
                lower_back_pending = true;
            }
        }
        // M32 WMS8 Gate 5 (issue #628): the Ctrl chord consumers for
        // workspace-switch (Ctrl+F1/F2/F3), tile (Ctrl+T), master-swap
        // (Ctrl+M), minimize (Ctrl+N), maximize (Ctrl+Shift+M), always-
        // on-top (Ctrl+Shift+T), and F11 fullscreen are DELETED — WMS5
        // Gate 2 drained all of them to the WM (kind-21 -> handle_wm_key >
        // SET_WINDOW/SET_STATE). The Ctrl+Shift+A about chord was already
        // deleted in Gate 3. The WM serves these; the kernel no longer
        // self-decides them.
        // M21 W10: Alt+arrow for keyboard window movement (KEPT — no WM
        // coverage yet).
        if (alt) {
            var dx: i32 = 0;
            var dy: i32 = 0;
            if (k == 0x4f) dx = 16; // Right arrow
            if (k == 0x50) dx = -16; // Left arrow
            if (k == 0x52) dy = -16; // Up arrow
            if (k == 0x51) dy = 16; // Down arrow
            if (dx != 0 or dy != 0) {
                var held = false;
                for (kb_held) |h| {
                    if (h == k) {
                        held = true;
                        break;
                    }
                }
                if (!held and !driving_award.wm_owns_input) {
                    // Alt+Shift = fine movement (1px).
                    move_pending_dx = if (shift) @divTrunc(dx, 16) else dx;
                    move_pending_dy = if (shift) @divTrunc(dy, 16) else dy;
                    move_pending_fine = shift;
                }
            }
        }
    }

    if (driving_award.focused_owner()) |owner_pid| {
        // #1082 (ADR 0020 Amendment A, A5): when the focused window is a
        // terminal front-end, encode its keys with the SAME `hid_to_bytes`
        // encoder the console path uses and push them into the bound
        // terminal's input queue — the shell reads them via `/dev/tty`.
        // Focus is NOT stolen, and WIN_CLOSE/WIN_RESIZE/WIN_FOCUS are
        // delivered by their own paths (this only redirects key bytes).
        if (terminal.windowTerminal(driving_award.focused_window_id())) |tt| {
            const scr = terminal.screenForTerminal(tt);
            for (keys) |k| {
                if (k == 0) continue;
                var held = false;
                for (kb_held) |h| {
                    if (h == k) {
                        held = true;
                        break;
                    }
                }
                if (held) continue;
                kb_last_usage = k;
                // M49 SD5 (#1132): terminal-window chrome chords are consumed
                // by the kernel presentation, not typed into the shell:
                //   PageUp/PageDown + Shift+Up/Down  scroll the view
                //   Shift+Home / Shift+End           jump to oldest / tail
                //   Ctrl+Shift+C                     copy the selection
                //   Ctrl+Shift+V                     paste the clipboard into the tty
                if (k == 0x4b or k == 0x4e) { // PageUp / PageDown
                    const up = (k == 0x4b);
                    var wheel_ok = false;
                    if (scr) |s| {
                        // M73i (#1635): with mouse tracking on, PageUp/
                        // PageDown report `CSI 64/65` (xterm wheel) instead
                        // of scrolling the view; Shift — or modes off —
                        // keeps local scroll-by-8 byte-identically. The
                        // report sits at the cursor cell (pointer-cell
                        // coords need the WM geometry seam — future note).
                        if ((s.mouse_1000 or s.mouse_1002 or s.mouse_1003) and !shift) {
                            var enc: [24]u8 = undefined;
                            const n = terminal.encodeMouse(
                                s.mouse_1006,
                                .wheel,
                                if (up) 0 else 1,
                                @intCast(s.cursorCol() + 1),
                                @intCast(s.cursorLine() + 1),
                                @intCast(s.cols),
                                &enc,
                            );
                            if (n > 0) {
                                _ = tt.pushMouse(enc[0..n]);
                                wheel_ok = true;
                            }
                        }
                        if (!wheel_ok) s.scrollBy(if (up) 8 else -8);
                    }
                    events += 1;
                    continue;
                }
                if (shift and k == 0x52) { // Shift+Up
                    if (scr) |s| s.scrollBy(1);
                    events += 1;
                    continue;
                }
                if (shift and k == 0x51) { // Shift+Down
                    if (scr) |s| s.scrollBy(-1);
                    events += 1;
                    continue;
                }
                if (shift and k == 0x4a) { // Shift+Home
                    if (scr) |s| s.scrollBy(32767);
                    events += 1;
                    continue;
                }
                if (shift and k == 0x4d) { // Shift+End
                    if (scr) |s| s.scrollReset();
                    events += 1;
                    continue;
                }
                if (ctrl and shift and k == 0x06) { // Ctrl+Shift+C
                    const copied = terminal.copySelectionToClipboard(driving_award.focused_window_id());
                    var msg: [48]u8 = undefined;
                    const m = std.fmt.bufPrint(&msg, "tty: copy {d} bytes\n", .{copied}) catch "tty: copy\n";
                    klog.line(m);
                    events += 1;
                    continue;
                }
                if (ctrl and shift and k == 0x19) { // Ctrl+Shift+V (HID 'v')
                    // M73e (#1629): the reverse of copy — the clipboard
                    // lands in the bound tty's input queue in one push,
                    // wrapped in `\e[200~ … \e[201~` when the app asked
                    // for DECSET 2004 (GOSH requests it at startup).
                    const pasted = terminal.pasteFromClipboard(driving_award.focused_window_id());
                    var pmsg: [48]u8 = undefined;
                    const pm = std.fmt.bufPrint(&pmsg, "tty: paste {d} bytes\n", .{pasted}) catch "tty: paste\n";
                    klog.line(pm);
                    events += 1;
                    continue;
                }
                // M73k (#1637): Ctrl+Shift+F opens the kernel search bar —
                // same chrome-chord family as copy/paste (HID 'f' = 0x09).
                // Normal screen only: searchOpen refuses on the alt screen
                // (pinned class-A); the chord is still consumed there.
                if (ctrl and shift and k == 0x09) {
                    if (scr) |s| _ = s.searchOpen();
                    events += 1;
                    continue;
                }
                // M80k (#1727): the hygiene chords every terminal has and
                // this one did not — clear the scrollback, soft reset, full
                // reset. The cure for a grid wedged by an app that died
                // mid-escape, without closing the tab. Same chrome-chord
                // family (consumed here, before the tty queue, and never
                // injected as bytes), and the operations are the M80b /
                // M80e seams themselves rather than a second
                // implementation that could drift. Must sit ABOVE the
                // search-capture block below: a wedged grid is exactly
                // when the scan bar is most likely to be up, and a chord
                // swallowed as a search pattern is no cure at all.
                if (hygieneChord(k, shift, alt, ctrl)) |hyg| {
                    if (scr) |s| {
                        switch (hyg) {
                            .clear_scrollback => {
                                const before = s.historyCount();
                                // #1757: the count alone was unexplained (run
                                // 03 dropped 24 rows from a ~300-row fill —
                                // exactly one viewport). The ring-state
                                // figures AT READ TIME make the number
                                // diagnosable: `hist`+`used` is the unified
                                // depth, `pend` the tty output still queued
                                // (a non-zero pend means the chord raced the
                                // pump), `vis` the focused window's visible
                                // rows for the viewport-cap comparison.
                                const used_before = s.used;
                                const total_before = s.lineCount();
                                var vis: usize = 0;
                                if (driving_award.find_user_window(driving_award.focused_window_id())) |w| {
                                    vis = if (w.h > driving_award.user_title_h)
                                        (w.h - driving_award.user_title_h) / driving_award.font_metrics.cell_h
                                    else
                                        1;
                                }
                                const pend = tt.pendingOut();
                                s.clearScrollback();
                                // Snap to the tail even when the clear
                                // itself was a no-op (the alternate
                                // screen's ring belongs to the primary
                                // grid): "scroll to tail" is half the
                                // promise, and it is unconditional.
                                s.scrollReset();
                                var cmsg: [112]u8 = undefined;
                                const cm = std.fmt.bufPrint(&cmsg, "tty: clear {d} lines (hist={d} used={d} total={d} vis={d} pend={d})\n", .{
                                    before - s.historyCount(),
                                    before,
                                    used_before,
                                    total_before,
                                    vis,
                                    pend,
                                }) catch "tty: clear\n";
                                klog.line(cm);
                            },
                            .soft_reset => {
                                // The scan bar is presentation, not parser
                                // state: leave it up and the "grid intact"
                                // reset is invisible behind the overlay.
                                s.searchExit();
                                s.softReset();
                                klog.line("tty: reset soft\n");
                            },
                            .ris => {
                                // RIS wipes the grid itself, overlay and all
                                // — no searchExit needed (and none wanted:
                                // restoring a covered row into a grid that
                                // no longer exists would resurrect bytes).
                                s.hardReset();
                                klog.line("tty: reset full\n");
                            },
                        }
                        // #1757: composite the chord's effect NOW, under the
                        // win+ev hold this decode already runs in. Post-1747
                        // the chords decode on the idle task while the
                        // compositor drains in the shell loop, so the
                        // framebuffer lagged the marker by an unbounded
                        // number of passes — and the claim-0680 snapshot
                        // fired from this very marker raced it (observed on
                        // live-term-depth run 03: the RIS snapshot shipped
                        // the pre-RIS grid). Present-then-marker makes the
                        // frame fresh by construction: the request can only
                        // arrive after the marker, and the pixels it must
                        // capture are already on the scanout. The chord
                        // mutates the Screen directly, so the dirty flag
                        // needs marking first — the same user_present seam
                        // the tty write path uses — or paint_scene finds a
                        // clean scene and paints nothing (observed). Host
                        // builds skip the hardware half (the established
                        // !is_test gate: paint/composite reach MMU + virtio
                        // GPU MMIO that aborts a host test binary).
                        if (comptime !builtin.is_test) {
                            _ = driving_award.user_present(driving_award.focused_window_id());
                            _ = driving_award.composite();
                        }
                    }
                    events += 1;
                    continue;
                }
                // M73k: while the bar is up, its keys are captured by the
                // presentation and never reach the app's tty. Enter/next,
                // Shift+Enter/prev, Esc exits, backspace edits, everything
                // mappable types into the pattern; unmappable keys (arrows
                // etc.) keep falling through to the normal path below.
                if (scr) |s| {
                    if (s.searchActive()) {
                        var sk: ?terminal.Screen.SearchKey = null;
                        if (k == 0x29) {
                            sk = .esc;
                        } else if (k == 0x28) {
                            sk = if (shift) .prev else .enter;
                        } else if (k == 0x2a) {
                            sk = .backspace;
                        } else if (hid_to_ascii(k, shift)) |ch| {
                            sk = .{ .ch = ch };
                        }
                        if (sk) |key| {
                            if (s.searchFeed(key)) |n| {
                                var smsg: [48]u8 = undefined;
                                const sm = std.fmt.bufPrint(&smsg, "tty: search: {d} matches\n", .{n}) catch "tty: search\n";
                                klog.line(sm);
                            }
                            events += 1;
                            continue;
                        }
                    }
                }
                var kout: [max_key_bytes]u8 = undefined;
                const kn = hid_to_bytes(k, shift, alt, ctrl, &kout);
                if (kn > 0) {
                    kb_last_byte = kout[kn - 1]; // the sequence's final byte
                    _ = tt.pushInput(kout[0..kn]);
                    events += 1;
                }
            }
            kb_held = keys;
            return;
        }
        // Milestone 9 Card E2: Route keyboard events to focused user window process!
        // 1. Key DOWN: keys present now but not in kb_held
        for (keys) |k| {
            if (k == 0) continue;
            var held = false;
            for (kb_held) |h| {
                if (h == k) {
                    held = true;
                    break;
                }
            }
            if (!held) {
                kb_last_usage = k;
                const key_codepoint: u32 = if (hid_to_codepoint(k, shift)) |ch| ch else 0;
                // Arc5 #245: Compose state machine (ADR 0014).
                // When Alt is held, route through compose logic instead of
                // immediately dispatching KEY_DOWN.
                if (alt and k != 0 and compose_state == .idle) {
                    // Alt + key: start compose sequence (save pending event).
                    compose_state = .waiting;
                    compose_first = k;
                } else if (compose_state == .waiting) {
                    // Second key of compose sequence: look up the pair.
                    const cp = compose_lookup(compose_first, k);
                    compose_state = .idle;
                    if (cp) |codepoint| {
                        // Compose match: dispatch KEY_DOWN with Unicode codepoint.
                        app_events.push(owner_pid, .{
                            .kind = app_events.KEY_DOWN,
                            .flags = flags,
                            .seq = 0,
                            .arg0 = k,
                            .arg1 = codepoint,
                        });
                        events += 1;
                    } else {
                        // Compose miss: dispatch both keys as normal KEY_DOWN.
                        const first_codepoint: u32 = if (hid_to_codepoint(compose_first, shift)) |ch| ch else 0;
                        app_events.push(owner_pid, .{
                            .kind = app_events.KEY_DOWN,
                            .flags = flags,
                            .seq = 0,
                            .arg0 = compose_first,
                            .arg1 = first_codepoint,
                        });
                        events += 1;
                        app_events.push(owner_pid, .{
                            .kind = app_events.KEY_DOWN,
                            .flags = flags,
                            .seq = 0,
                            .arg0 = k,
                            .arg1 = key_codepoint,
                        });
                        events += 1;
                    }
                } else {
                    // Normal KEY_DOWN: no compose active.
                    app_events.push(owner_pid, .{
                        .kind = app_events.KEY_DOWN,
                        .flags = flags,
                        .seq = 0,
                        .arg0 = k,
                        .arg1 = key_codepoint,
                    });
                    events += 1;
                }
                // Arc4 #236: translate PageUp/PageDown to MOUSE_SCROLL events.
                // On VZ the absolute pointer has no wheel byte, so this is the
                // working scroll path. ScrollView/HScrollBar consume kind 12.
                if (k == 0x4b) { // PageUp
                    // Packed arg0: magnitude=1, sign=0 (scroll up).
                    app_events.push(owner_pid, .{
                        .kind = app_events.MOUSE_SCROLL,
                        .flags = 0,
                        .seq = 0,
                        .arg0 = 1, // magnitude=1, bit15=0 (up)
                        .arg1 = 0,
                    });
                    events += 1;
                } else if (k == 0x4e) { // PageDown
                    // Packed arg0: magnitude=1, sign=1 (scroll down).
                    app_events.push(owner_pid, .{
                        .kind = app_events.MOUSE_SCROLL,
                        .flags = 0,
                        .seq = 0,
                        .arg0 = 0x8001, // magnitude=1, bit15=1 (down)
                        .arg1 = 0,
                    });
                    events += 1;
                }
            }
        }
        // 2. Key UP: keys in kb_held but not in keys now
        for (kb_held) |h| {
            if (h == 0) continue;
            var still_held = false;
            for (keys) |k| {
                if (k == h) {
                    still_held = true;
                    break;
                }
            }
            if (!still_held) {
                const codepoint: u32 = if (hid_to_codepoint(h, shift)) |ch| ch else 0;
                app_events.push(owner_pid, .{
                    .kind = app_events.KEY_UP,
                    .flags = flags,
                    .seq = 0,
                    .arg0 = h,
                    .arg1 = codepoint,
                });
            }
        }
    } else if (!driving_award.wm_owns_input) {
        // Terminal / console route (existing behavior — gated on
        // !wm_owns_input like every other kernel-side key consumer in
        // this decode: while a WM owns input the raw stream is THE WM's
        // (kind-21 fan above), so bytes typed during the owned-but-
        // unfocused window — e.g. the seat's launcher before it grabs
        // focus — must not also land in the console line-editor FIFO.
        // Observed go-dogfood boot 04 (#2703): the Enter-summon's first
        // strokes leaked 'te' into `virelai>` and the next forwarded
        // script ran as 'teexec CHARMHELLO.ELF').
        for (keys) |k| {
            if (k == 0) continue;
            var held = false;
            for (kb_held) |h| {
                if (h == k) {
                    held = true;
                    break;
                }
            }
            if (!held) {
                kb_last_usage = k;
                if (alt and k == 0x2b) {
                    continue;
                }
                var out: [max_key_bytes]u8 = undefined;
                const n = hid_to_bytes(k, shift, false, ctrl, &out);
                if (n > 0) {
                    kb_last_byte = out[n - 1]; // the sequence's final byte
                    var i: usize = 0;
                    while (i < n) : (i += 1) push_byte(out[i]);
                    events += 1;
                }
            }
        }
    }
    kb_held = keys;
}

/// #3007 (slot-65 cmd 23, wm_server.wmctl_content_key): the registered
/// seat forwards one agent-injected key press (WM_RPC kind 29 'k', ADR
/// 0007 R2) for the kernel's app-delivery half — the part of this decode
/// the seat-side mirror can never reach. Kind-21 WM_KEY is a fan-out
/// only, so a synthesized event that enters at consumeSeatEvent runs the
/// seat's chord/hit-test work but never produces the kind-1/2 pair the
/// focused app reads; the seat echoes the press here so the app sees
/// exactly what a real report would have queued. `usage` is the HID
/// usage, `flags` the press's ADR 0009 modifier bits — the same fields
/// the wire packs and decode stamps on its pushes.
///
/// Delivery mirrors decode's focused-owner route: a kernel-terminal
/// front-end gets the encoded bytes a real press types, anything else
/// gets the KEY_DOWN/KEY_UP pair with the codepoint in arg1. A press is
/// one down+up pair — the wire's 'k' names a press, never a held key, so
/// no held-set or compose state is touched. The kernel-terminal chrome
/// chords (scroll/search/copy) stay inside decode: the seat consumed
/// chrome before it forwards, same contract wm_content_pointer carries.
/// Dormant with no seat: returns without touching any queue.
pub fn inject_content_key(usage: u8, flags: u16) void {
    if (!driving_award.wm_owns_input) return;
    // EV only — the same hold the sys_wmctl caller already arrives with,
    // under which wm_content_pointer walks the same window table and
    // pushes the same queue. Taking WIN here would invert the canonical
    // order (win < ev) against that held bit.
    const took = svclock.acquire_missing(svclock.dom_bit(.ev));
    defer svclock.release_set(took);
    const owner_pid = driving_award.focused_owner() orelse return;
    const shift = (flags & app_events.MOD_SHIFT) != 0;
    const ctrl = (flags & app_events.MOD_CTRL) != 0;
    const alt = (flags & app_events.MOD_ALT) != 0;
    if (terminal.windowTerminal(driving_award.focused_window_id())) |tt| {
        var kout: [max_key_bytes]u8 = undefined;
        const kn = hid_to_bytes(usage, shift, alt, ctrl, &kout);
        if (kn > 0) {
            kb_last_usage = usage;
            kb_last_byte = kout[kn - 1];
            _ = tt.pushInput(kout[0..kn]);
        }
        return;
    }
    const cp: u32 = if (hid_to_codepoint(usage, shift)) |ch| ch else 0;
    app_events.push(owner_pid, .{
        .kind = app_events.KEY_DOWN,
        .flags = flags,
        .seq = 0,
        .arg0 = usage,
        .arg1 = cp,
    });
    app_events.push(owner_pid, .{
        .kind = app_events.KEY_UP,
        .flags = flags,
        .seq = 0,
        .arg0 = usage,
        .arg1 = cp,
    });
}

/// Canonical custom-virtio kind-2 payload only: buttons, LE16 X, LE16 Y.
/// Native USB has its own explicit decoder, never a length-based fallback.
pub fn decode_pointer_report(rep: []const u8) void {
    if (rep.len != 5) return;
    const prev_buttons = ptr_buttons;
    ptr_buttons = rep[0];
    ptr_x = @as(u16, rep[1]) | (@as(u16, rep[2]) << 8);
    ptr_y = @as(u16, rep[3]) | (@as(u16, rep[4]) << 8);
    ptr_reports += 1;
    ptr_valid = true;
    if ((prev_buttons & 0x01) == 0 and (ptr_buttons & 0x01) != 0) {
        ptr_click_pending = true;
        ptr_press_pending = true;
        ptr_press_x = ptr_x;
        ptr_press_y = ptr_y;
    }
}

fn usb_pointer_payload(d: xhci.EnumDevice, rep: []const u8) ?[]const u8 {
    // VZ's non-boot tablet prefixes report ID 1. Normalize only this
    // device; the canonical custom-virtio pointer ABI has no report ID.
    if (d.vid != 0x05ac or d.pid != 0x8106 or d.hid_boot) return null;
    if (rep.len < 6 or rep.len > xhci.max_report_bytes or rep[0] != 1) return null;
    const x = @as(u16, rep[2]) | (@as(u16, rep[3]) << 8);
    const y = @as(u16, rep[4]) | (@as(u16, rep[5]) << 8);
    if (x > 32767 or y > 32767) return null;
    return rep[1..6];
}

fn decode_usb_pointer_report(d: xhci.EnumDevice, rep: []const u8) void {
    const payload = usb_pointer_payload(d, rep) orelse return;
    var canonical: [5]u8 = undefined;
    @memcpy(&canonical, payload);
    canonical[0] &= 7; // descriptor: three button bits, five padding bits
    decode_pointer_report(&canonical);
}

/// Decode the next globally ordered native report. The transport discards
/// detached devices' queued snapshots before handing them to this seam.
/// No-op when unarmed (default VM / host tests).
pub fn drain() void {
    if (!armed_global) return;
    // One report per idle pass: downstream samples pointer state once per
    // pass, so batching a press and release here would hide the button edge.
    // The shared FIFO supplies global completion order, not slot order.
    const rep = xhci.xhci_next_hid_report() orelse return;
    const i: usize = rep.slot_id - 1;
    const d = xhci.enum_devs[i];
    const bytes = rep.bytes[0..rep.len];
    switch (xhci.hid_kind[i]) {
        .keyboard => decode_keyboard_report(bytes),
        .mouse, .unknown => decode_usb_pointer_report(d, bytes),
    }
    // USB-only consumption evidence, not a keystroke log.
    dbg("input: usb consumed slot=");
    dbg_hex(rep.slot_id);
    dbg(" len=");
    dbg_hex(rep.len);
    dbg("\n");
}

pub fn report() Report {
    return .{
        .armed = armed_global,
        .fifo_used = fifo_count,
        .fifo_max = max_fifo,
        .dropped = dropped,
        .events = events,
        .kb_mods = kb_mods,
        .kb_last_usage = kb_last_usage,
        .kb_last_byte = kb_last_byte,
        .ptr_buttons = ptr_buttons,
        .ptr_x = ptr_x,
        .ptr_y = ptr_y,
        .ptr_reports = ptr_reports,
    };
}

/// Card U4 (claim 4993): the pointer snapshot for the window manager.
pub const PointerState = struct { x: u16, y: u16, buttons: u8, valid: bool };
pub fn pointer_state() PointerState {
    return .{ .x = ptr_x, .y = ptr_y, .buttons = ptr_buttons, .valid = ptr_valid };
}

/// Card U4: a consumed click edge (the pointer cell, HID logical units).
pub const Click = struct { x: u16, y: u16 };

/// M49 SD5 (#1132): the latched left-press position, consumed once.
pub fn take_press() ?Click {
    if (!ptr_press_pending) return null;
    ptr_press_pending = false;
    return .{ .x = ptr_press_x, .y = ptr_press_y };
}

/// Consume the latched click edge (buttons 0 -> nonzero). Returns the
/// click's pointer cell or null when no click is pending.
pub fn take_click() ?Click {
    if (!ptr_click_pending) return null;
    ptr_click_pending = false;
    return .{ .x = ptr_x, .y = ptr_y };
}

/// Card U5: consume the Alt+Tab chord edge.
pub fn take_alt_tab() bool {
    if (take_alt_tab_shift() != null) return true;
    return false;
}

/// C2 (M15): Alt still held (either left 0x04 or right 0x40).
pub fn alt_held() bool {
    return (kb_mods & 0x04) != 0 or (kb_mods & 0x40) != 0;
}

/// C2 (M15): consume the Alt+Tab edge with Shift direction — null if no edge, else `true` if Shift+Tab (reverse), `false` if plain Tab.
pub fn take_alt_tab_shift() ?bool {
    if (!alt_tab_pending) return null;
    alt_tab_pending = false;
    const s = alt_tab_shift;
    alt_tab_shift = false;
    return s;
}

/// Arc4 #238: consume the Ctrl+Shift+B chord edge.
pub fn take_lower_back() bool {
    if (!lower_back_pending) return false;
    lower_back_pending = false;
    return true;
}

/// M32 WMS8 Gate 5 (issue #628): the take_* accessors for the drained
/// geometry chords (workspace switch/cycle, tile toggle, master swap,
/// minimize, maximize, fullscreen, always-on-top) are DELETED — the WM owns
/// those decisions now; the kernel no longer self-consumes them.
pub const MoveDelta = struct { dx: i32, dy: i32 };

/// M21 W10: consume the Alt+arrow movement edge. Returns (dx, dy) or
/// null if no movement is pending.
pub fn take_move() ?MoveDelta {
    if (move_pending_dx == 0 and move_pending_dy == 0) return null;
    const result = MoveDelta{ .dx = move_pending_dx, .dy = move_pending_dy };
    move_pending_dx = 0;
    move_pending_dy = 0;
    return result;
}

// ---------------------------------------------------------------------------
// Tests (host-side; pure surface, no hardware)
// ---------------------------------------------------------------------------

test "input: hid_to_ascii maps the usable subset (unshifted + shifted)" {
    try std.testing.expectEqual(@as(?u8, 'a'), hid_to_ascii_layout(.us, 0x04, false));
    try std.testing.expectEqual(@as(?u8, 'A'), hid_to_ascii_layout(.us, 0x04, true));
    try std.testing.expectEqual(@as(?u8, 'z'), hid_to_ascii_layout(.us, 0x1d, false));
    try std.testing.expectEqual(@as(?u8, 'Z'), hid_to_ascii_layout(.us, 0x1d, true));
    try std.testing.expectEqual(@as(?u8, '1'), hid_to_ascii_layout(.us, 0x1e, false));
    try std.testing.expectEqual(@as(?u8, '!'), hid_to_ascii_layout(.us, 0x1e, true));
    try std.testing.expectEqual(@as(?u8, '0'), hid_to_ascii_layout(.us, 0x27, false));
    try std.testing.expectEqual(@as(?u8, ')'), hid_to_ascii_layout(.us, 0x27, true));
    try std.testing.expectEqual(@as(?u8, '\n'), hid_to_ascii_layout(.us, 0x28, false));
    try std.testing.expectEqual(@as(?u8, ' '), hid_to_ascii_layout(.us, 0x2c, false));
    try std.testing.expectEqual(@as(?u8, '-'), hid_to_ascii_layout(.us, 0x2d, false));
    try std.testing.expectEqual(@as(?u8, '_'), hid_to_ascii_layout(.us, 0x2d, true));
    try std.testing.expectEqual(@as(?u8, 0x08), hid_to_ascii_layout(.us, 0x2a, false));
}

test "input: keyboard layouts map symbols to Unicode codepoints" {
    try std.testing.expectEqual(@as(?u8, 'y'), hid_to_ascii_layout(.us, 0x1c, false));
    try std.testing.expectEqual(@as(?u8, 'z'), hid_to_ascii_layout(.us, 0x1d, false));
    try std.testing.expectEqual(@as(?u8, 'z'), hid_to_ascii_layout(.de, 0x1c, false));
    try std.testing.expectEqual(@as(?u8, 'y'), hid_to_ascii_layout(.de, 0x1d, false));
    try std.testing.expectEqual(@as(?u8, 'Z'), hid_to_ascii_layout(.de, 0x1c, true));
    try std.testing.expectEqual(@as(?u8, ';'), hid_to_ascii_layout(.de, 0x36, true));
    try std.testing.expectEqual(@as(?u8, ':'), hid_to_ascii_layout(.de, 0x37, true));
    try std.testing.expectEqual(@as(?u8, '<'), hid_to_ascii_layout(.de, 0x64, false));
    try std.testing.expectEqual(@as(?u8, '>'), hid_to_ascii_layout(.de, 0x64, true));
    try std.testing.expectEqual(@as(?u21, 0x00f6), hid_to_codepoint_layout(.de, 0x33, false));
    try std.testing.expectEqual(@as(?u21, 0x00d6), hid_to_codepoint_layout(.de, 0x33, true));
    // The ASCII-only helper remains useful for control chords, but the app
    // event arg1 and terminal text path carry the full codepoint/UTF-8.
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii_layout(.de, 0x33, false));
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii_layout(.de, 0x20, true));
}

test "input: selected layout comes from the persisted setting" {
    settings.init();
    defer settings.init();
    try std.testing.expectEqual(KeyboardLayout.us, selected_layout());
    try std.testing.expectEqual(settings.SetResult.ok, settings.set("keyboard_layout", "de"));
    try std.testing.expectEqual(KeyboardLayout.de, selected_layout());
    try std.testing.expectEqual(@as(?u8, 'z'), hid_to_ascii(0x1c, false));
    try std.testing.expectEqual(@as(?u21, 'z'), hid_to_codepoint(0x1c, false));
    try std.testing.expectEqual(settings.SetResult.ok, settings.set("keyboard_layout", "invalid"));
    try std.testing.expectEqual(KeyboardLayout.us, selected_layout());
}

test "input: selected German symbols encode as UTF-8 console bytes" {
    settings.init();
    defer settings.init();
    try std.testing.expectEqual(settings.SetResult.ok, settings.set("keyboard_layout", "de"));
    var out: [max_key_bytes]u8 = undefined;
    var n = hid_to_bytes(0x33, false, false, false, &out);
    try std.testing.expectEqualSlices(u8, "\xc3\xb6", out[0..n]); // ö
    n = hid_to_bytes(0x33, true, false, false, &out);
    try std.testing.expectEqualSlices(u8, "\xc3\x96", out[0..n]); // Ö
}

test "input: usages outside the usable subset are refused (no invented bytes)" {
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii(0x00, false));
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii(0x29, false)); // Escape
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii(0x39, false)); // Caps Lock
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii(0x4c, false)); // Pause
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii(0xe0, false)); // Left Ctrl
}

test "input: hid_to_bytes maps the nav cluster to ESC sequences" {
    var out: [max_key_bytes]u8 = undefined;
    // Up arrow -> ESC [ A (3 bytes).
    var n = hid_to_bytes(0x52, false, false, false, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(u8, "\x1b[A", out[0..n]);
    // Left arrow -> ESC [ D.
    n = hid_to_bytes(0x50, false, false, false, &out);
    try std.testing.expectEqualSlices(u8, "\x1b[D", out[0..n]);
    // End -> ESC [ F; Delete -> ESC [ 3 ~ (4 bytes).
    n = hid_to_bytes(0x4d, false, false, false, &out);
    try std.testing.expectEqualSlices(u8, "\x1b[F", out[0..n]);
    n = hid_to_bytes(0x4c, false, false, false, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualSlices(u8, "\x1b[3~", out[0..n]);
    // PageUp -> ESC [ 5 ~, PageDown -> ESC [ 6 ~ (4 bytes each) — the
    // shell's scroll interceptor consumes these (M18 T1).
    n = hid_to_bytes(0x4b, false, false, false, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualSlices(u8, "\x1b[5~", out[0..n]);
    n = hid_to_bytes(0x4e, false, false, false, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualSlices(u8, "\x1b[6~", out[0..n]);
    // Escape -> a lone ESC byte (the line editor treats it as a no-op).
    n = hid_to_bytes(0x29, false, false, false, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x1b), out[0]);
    // Not a printable, not a nav key: no bytes invented.
    try std.testing.expectEqual(@as(usize, 0), hid_to_bytes(0x39, false, false, false, &out)); // Caps Lock
}

test "input: hid_to_bytes maps the full function-key and Insert vocabulary" {
    const cases = [_]struct { usage: u8, want: []const u8 }{
        .{ .usage = 0x3a, .want = "\x1bOP" }, // F1
        .{ .usage = 0x3b, .want = "\x1bOQ" }, // F2
        .{ .usage = 0x3c, .want = "\x1bOR" }, // F3
        .{ .usage = 0x3d, .want = "\x1bOS" }, // F4
        .{ .usage = 0x3e, .want = "\x1b[15~" }, // F5
        .{ .usage = 0x3f, .want = "\x1b[17~" }, // F6
        .{ .usage = 0x40, .want = "\x1b[18~" }, // F7
        .{ .usage = 0x41, .want = "\x1b[19~" }, // F8
        .{ .usage = 0x42, .want = "\x1b[20~" }, // F9
        .{ .usage = 0x43, .want = "\x1b[21~" }, // F10
        .{ .usage = 0x44, .want = "\x1b[23~" }, // F11
        .{ .usage = 0x45, .want = "\x1b[24~" }, // F12
        .{ .usage = 0x70, .want = "\x1b[2~" }, // Insert
    };
    for (cases) |tc| {
        var out: [max_key_bytes]u8 = undefined;
        const n = hid_to_bytes(tc.usage, false, false, false, &out);
        try std.testing.expectEqualSlices(u8, tc.want, out[0..n]);
    }

    // Modified function keys use the same xterm modifier parameter as the
    // navigation keys; this also exercises the seven-byte bound.
    var out: [max_key_bytes]u8 = undefined;
    var n = hid_to_bytes(0x3a, true, false, false, &out); // Shift-F1
    try std.testing.expectEqualSlices(u8, "\x1b[1;2P", out[0..n]);
    n = hid_to_bytes(0x3e, false, false, true, &out); // Ctrl-F5
    try std.testing.expectEqualSlices(u8, "\x1b[15;5~", out[0..n]);
}

test "input: hid_to_bytes maps every modified navigation final" {
    const nav = [_]struct { usage: u8, final: u8 }{
        .{ .usage = 0x52, .final = 'A' }, // Up
        .{ .usage = 0x51, .final = 'B' }, // Down
        .{ .usage = 0x4f, .final = 'C' }, // Right
        .{ .usage = 0x50, .final = 'D' }, // Left
        .{ .usage = 0x4a, .final = 'H' }, // Home
        .{ .usage = 0x4d, .final = 'F' }, // End
    };
    const modifiers = [_]struct { shift: bool, alt: bool, ctrl: bool, code: u8 }{
        .{ .shift = true, .alt = false, .ctrl = false, .code = 2 },
        .{ .shift = false, .alt = true, .ctrl = false, .code = 3 },
        .{ .shift = false, .alt = false, .ctrl = true, .code = 5 },
        .{ .shift = true, .alt = true, .ctrl = true, .code = 8 },
    };
    for (nav) |key| {
        for (modifiers) |mod| {
            var out: [max_key_bytes]u8 = undefined;
            const n = hid_to_bytes(key.usage, mod.shift, mod.alt, mod.ctrl, &out);
            try std.testing.expectEqual(@as(usize, 6), n);
            try std.testing.expectEqual(@as(u8, 0x1b), out[0]);
            try std.testing.expectEqual(@as(u8, '['), out[1]);
            try std.testing.expectEqual(@as(u8, '1'), out[2]);
            try std.testing.expectEqual(@as(u8, ';'), out[3]);
            try std.testing.expectEqual(@as(u8, '0' + mod.code), out[4]);
            try std.testing.expectEqual(key.final, out[5]);
        }
    }
}

test "input: hid_to_bytes maps ctrl+a-z to ASCII control codes" {
    var out: [max_key_bytes]u8 = undefined;
    // Ctrl-A (usage 0x04) -> 0x01; Ctrl-C (usage 0x06) -> 0x03; Ctrl-Z -> 0x1a.
    try std.testing.expectEqual(@as(usize, 1), hid_to_bytes(0x04, false, false, true, &out));
    try std.testing.expectEqual(@as(u8, 0x01), out[0]);
    try std.testing.expectEqual(@as(usize, 1), hid_to_bytes(0x06, false, false, true, &out));
    try std.testing.expectEqual(@as(u8, 0x03), out[0]);
    try std.testing.expectEqual(@as(usize, 1), hid_to_bytes(0x1d, false, false, true, &out));
    try std.testing.expectEqual(@as(u8, 0x1a), out[0]);
    // Ctrl + non-letter is outside the usable subset (no invented bytes).
    try std.testing.expectEqual(@as(usize, 0), hid_to_bytes(0x28, false, false, true, &out)); // Ctrl+Enter
}

test "input: WMS8 Gate 5 — the drained geometry chords fan out but the kernel no longer consumes them (claim 9879)" {
    // WMS5 Gate 2 drained the geometry chords (tile/master/min/max/ws/
    // fullscreen/aot) to the WM; WMS8 Gate 5 DELETES the kernel's chord
    // consumers. The raw key stream STILL fans out to the WM (kind 21) on
    // key-DOWN edges, and the kernel has no pending-flag/take_* for those
    // chords anymore. Ctrl+Shift+B (lower-back) and Alt+arrows (move) stay
    // kernel-consumed until the WM covers them.
    _ = driving_award.focus(0);
    fifo_count = 0;
    fifo_head = 0;
    events = 0;
    kb_held = @as([6]u8, @splat(@as(u8, 0)));
    var key_calls: usize = 0;
    var last_usage: u8 = 0;
    var last_flags: u16 = 0;
    const capture = struct {
        var calls: *usize = undefined;
        var usage: *u8 = undefined;
        var flags: *u16 = undefined;
        fn hook(u: u8, f: u16) void {
            calls.* += 1;
            usage.* = u;
            flags.* = f;
        }
    };
    capture.calls = &key_calls;
    capture.usage = &last_usage;
    capture.flags = &last_flags;

    // No WM (shim mode): the drained Ctrl+T does NOT set a pending flag
    // (the consumer is deleted) and does NOT fan out (no WM).
    driving_award.wm_owns_input = false;
    driving_award.wm_key_hook = capture.hook;
    decode_keyboard_report(&[_]u8{ 0x01, 0, 0x17, 0, 0, 0, 0, 0 }); // Ctrl+T
    try std.testing.expectEqual(@as(usize, 0), key_calls); // no fan-out without a WM
    decode_keyboard_report(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }); // release

    // With a WM registered: the raw key fans out to the WM (kind 21); the
    // kernel has no chord consumer left to trigger.
    driving_award.wm_owns_input = true;
    decode_keyboard_report(&[_]u8{ 0x01, 0, 0x17, 0, 0, 0, 0, 0 }); // Ctrl+T
    try std.testing.expectEqual(@as(usize, 1), key_calls); // ...the WM got it
    try std.testing.expectEqual(@as(u8, 0x17), last_usage);
    try std.testing.expectEqual(@as(u16, app_events.MOD_CTRL), last_flags);
    decode_keyboard_report(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }); // release

    // KEPT chord — Ctrl+Shift+B (lower-back): while no WM, the kernel still
    // self-consumes it (no WM coverage yet -> zero regression).
    driving_award.wm_key_hook = null;
    driving_award.wm_owns_input = false;
    decode_keyboard_report(&[_]u8{ 0x01 | 0x02, 0, 0x05, 0, 0, 0, 0, 0 }); // Ctrl+Shift+B
    try std.testing.expect(take_lower_back());
    decode_keyboard_report(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }); // release
    // KEPT chord — Alt+Right (move): still self-consumed in shim mode.
    decode_keyboard_report(&[_]u8{ 0x04, 0, 0x4f, 0, 0, 0, 0, 0 }); // Alt+Right
    const mv = take_move().?;
    try std.testing.expectEqual(@as(i32, 16), mv.dx);
    try std.testing.expectEqual(@as(i32, 0), mv.dy);
    decode_keyboard_report(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }); // release

    // Cleanup: WM mode restored (the raw fan-out stays available).
    driving_award.wm_owns_input = false;
}

test "input: a WM-owned key stream does not also feed the console FIFO (#2703)" {
    _ = driving_award.focus(0); // no focused window: the console route
    fifo_count = 0;
    fifo_head = 0;
    events = 0;
    kb_held = @as([6]u8, @splat(@as(u8, 0)));
    var key_calls: usize = 0;
    const capture = struct {
        var calls: *usize = undefined;
        fn hook(u: u8, f: u16) void {
            _ = u;
            _ = f;
            calls.* += 1;
        }
    };
    capture.calls = &key_calls;
    // Owned-but-unfocused: a launcher summons while the WM holds input and
    // no window is focused. The kind-21 fan still gets every edge…
    driving_award.wm_owns_input = true;
    driving_award.wm_key_hook = capture.hook;
    defer {
        driving_award.wm_owns_input = false;
        driving_award.wm_key_hook = null;
    }
    decode_keyboard_report(&[_]u8{ 0, 0, 0x17, 0, 0, 0, 0, 0 }); // 't' down
    decode_keyboard_report(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }); // release
    try std.testing.expectEqual(@as(usize, 1), key_calls);
    // …but the byte must NOT also queue for the console line editor —
    // observed boot 04: a leaked prefix ran the next script as 'teexec'.
    try std.testing.expectEqual(@as(usize, 0), fifo_count);
    // Shim mode (no WM): the identical stroke still reaches the console.
    driving_award.wm_owns_input = false;
    driving_award.wm_key_hook = null;
    decode_keyboard_report(&[_]u8{ 0, 0, 0x17, 0, 0, 0, 0, 0 });
    decode_keyboard_report(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 1), fifo_count);
    try std.testing.expectEqual(@as(u8, 't'), pop_byte().?);
}

test "input: keyboard report decode pushes a ctrl chord and an arrow sequence" {
    _ = driving_award.focus(0);
    fifo_count = 0;
    fifo_head = 0;
    events = 0;
    kb_held = @as([6]u8, @splat(@as(u8, 0)));
    // Left Ctrl (0x01) held + 'a' (usage 0x04) pressed -> 0x01 (Ctrl-A).
    decode_keyboard_report(&[_]u8{ 0x01, 0, 0x04, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 1), fifo_count);
    try std.testing.expectEqual(@as(u8, 0x01), pop_byte().?);
    // Release; then Up arrow (usage 0x52) -> ESC [ A (3 bytes).
    decode_keyboard_report(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
    decode_keyboard_report(&[_]u8{ 0, 0, 0x52, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 3), fifo_count);
    try std.testing.expectEqual(@as(u8, 0x1b), pop_byte().?);
    try std.testing.expectEqual(@as(u8, '['), pop_byte().?);
    try std.testing.expectEqual(@as(u8, 'A'), pop_byte().?);
    try std.testing.expectEqual(@as(?u8, null), pop_byte());
    try std.testing.expectEqual(@as(usize, 2), events);
}

test "input: keyboard report decode pushes key-down bytes with shift" {
    // Reset the module state (host tests share the globals).
    _ = driving_award.focus(0);
    fifo_count = 0;
    fifo_head = 0;
    events = 0;
    dropped = 0;
    kb_held = @as([6]u8, @splat(@as(u8, 0)));
    // Shift held + 'I' key (usage 0x0c) pressed: byte 0 = 0x02 (left shift),
    // byte 2 = 0x0c.
    decode_keyboard_report(&[_]u8{ 0x02, 0, 0x0c, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 1), fifo_count);
    try std.testing.expectEqual(@as(u8, 'I'), pop_byte().?);
    try std.testing.expectEqual(@as(?u8, null), pop_byte());
    try std.testing.expectEqual(@as(usize, 1), events);
    // Key released: no new key-down, no new byte.
    decode_keyboard_report(&[_]u8{ 0x02, 0, 0, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 0), fifo_count);
    // Lift the held shift too — kb_mods is shared global state.
    decode_keyboard_report(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
}

test "input: a held key does not re-fire (no repeat on unchanged report)" {
    _ = driving_award.focus(0);
    fifo_count = 0;
    fifo_head = 0;
    events = 0;
    kb_held = @as([6]u8, @splat(@as(u8, 0)));
    const pressed = [_]u8{ 0, 0, 0x04, 0, 0, 0, 0, 0 }; // 'a' held
    decode_keyboard_report(&pressed);
    decode_keyboard_report(&pressed); // unchanged → no second push
    try std.testing.expectEqual(@as(usize, 1), fifo_count);
    try std.testing.expectEqual(@as(u8, 'a'), pop_byte().?);
    try std.testing.expectEqual(@as(?u8, null), pop_byte());
    try std.testing.expectEqual(@as(usize, 1), events);
}

test "input: FIFO is bounded and drops on overflow, never wrapping" {
    fifo_count = 0;
    fifo_head = 0;
    dropped = 0;
    var i: usize = 0;
    while (i < max_fifo + 3) : (i += 1) push_byte('x');
    try std.testing.expectEqual(@as(usize, max_fifo), fifo_count);
    try std.testing.expectEqual(@as(usize, 3), dropped);
    // Drains exactly the first max_fifo bytes in order.
    var n: usize = 0;
    while (pop_byte()) |b| {
        try std.testing.expectEqual(@as(u8, 'x'), b);
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, max_fifo), n);
}

test "input: pointer report is recorded best-effort (buttons + LE X/Y)" {
    ptr_buttons = 0;
    ptr_x = 0;
    ptr_y = 0;
    ptr_reports = 0;
    decode_pointer_report(&[_]u8{ 0x01, 0x34, 0x12, 0x78, 0x56 });
    try std.testing.expectEqual(@as(u8, 0x01), ptr_buttons);
    try std.testing.expectEqual(@as(u16, 0x1234), ptr_x);
    try std.testing.expectEqual(@as(u16, 0x5678), ptr_y);
    try std.testing.expectEqual(@as(usize, 1), ptr_reports);
}

test "input: VZ USB pointer report ID is not a held button or coordinate byte" {
    const d: xhci.EnumDevice = .{ .vid = 0x05ac, .pid = 0x8106 };
    // Genuine motion capture, also pinned in native-motion.hex.
    const wire = [_]u8{ 1, 0, 0x44, 0x24, 0x2f, 0x67, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, &.{ 0, 0x44, 0x24, 0x2f, 0x67 }, usb_pointer_payload(d, &wire).?);
    // Synthetic button-down derivative, not a captured physical press.
    const press = [_]u8{ 1, 1, 0x44, 0x24, 0x2f, 0x67, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, &.{ 1, 0x44, 0x24, 0x2f, 0x67 }, usb_pointer_payload(d, &press).?);
    // Canonical reports are not accepted by any USB fallback.
    const canonical = [_]u8{ 1, 0x44, 0x24, 0x2f, 0x67 };
    try std.testing.expect(usb_pointer_payload(.{}, &canonical) == null);
    try std.testing.expect(usb_pointer_payload(d, &canonical) == null);
    var other = wire;
    other[0] = 2;
    try std.testing.expect(usb_pointer_payload(d, &other) == null);
}

test "input: drain is a no-op when unarmed" {
    armed_global = false;
    const before = fifo_count;
    drain();
    try std.testing.expectEqual(before, fifo_count);
    try std.testing.expect(!report().armed);
    armed_global = true;
    try std.testing.expect(report().armed);
    armed_global = false;
}

test "input: M91 short canonical pointer cannot partially mutate state" {
    ptr_buttons = 0;
    decode_pointer_report(&.{ 0, 0x44, 0x24, 0x2f, 0x67 });
    const before = pointer_state();
    decode_pointer_report(&.{ 1, 0xff, 0x7f });
    try std.testing.expectEqual(before, pointer_state());
}

test "input: M91 native wire is not canonical pointer bytes" {
    ptr_buttons = 0;
    decode_usb_pointer_report(.{ .vid = 0x05ac, .pid = 0x8106 }, &.{ 1, 0, 0x44, 0x24, 0x2f, 0x67, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(u8, 0), ptr_buttons);
    try std.testing.expectEqual(@as(u16, 0x2444), ptr_x);
    try std.testing.expectEqual(@as(u16, 0x672f), ptr_y);
}

fn m91_fixture_hex(path: []const u8, out: []u8) !usize {
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(2048));
    defer std.testing.allocator.free(text);
    var tokens = std.mem.tokenizeAny(u8, text, " \r\n\t");
    var n: usize = 0;
    while (tokens.next()) |token| {
        if (n == out.len) return error.FixtureTooLarge;
        out[n] = try std.fmt.parseInt(u8, token, 16);
        n += 1;
    }
    return n;
}

test "input: M91 genuine descriptor and motion vectors pin native VZ layout" {
    var bytes: [256]u8 = undefined;
    const kb_len = try m91_fixture_hex("tests/fixtures/input/m91/native-keyboard-descriptor.hex", &bytes);
    const kb = bytes[0..kb_len];
    try std.testing.expectEqual(@as(usize, 60), kb_len);
    try std.testing.expectEqualSlices(u8, &.{ 5, 1, 9, 6, 0xa1, 1 }, kb[0..6]);
    // E0..E7 modifier bits, one reserved byte, six key-array entries.
    try std.testing.expect(std.mem.indexOf(u8, kb, &.{ 0x19, 0xe0, 0x29, 0xe7 }) != null);
    try std.testing.expect(std.mem.indexOf(u8, kb, &.{ 0x75, 1, 0x95, 8, 0x81, 2, 0x75, 8, 0x95, 1, 0x81, 1 }) != null);
    try std.testing.expect(std.mem.indexOf(u8, kb, &.{ 0x95, 6, 0x81, 0 }) != null);
    const desc_len = try m91_fixture_hex("tests/fixtures/input/m91/native-descriptor.hex", &bytes);
    const desc = bytes[0..desc_len];
    try std.testing.expectEqualSlices(u8, &.{ 5, 1, 9, 2, 0xa1, 1, 0x85, 1 }, desc[0..8]);
    // Three one-bit buttons; two absolute 16-bit axes, logical max 32767.
    try std.testing.expect(std.mem.indexOf(u8, desc, &.{ 0x95, 3, 0x75, 1, 0x81, 2 }) != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, &.{ 0x26, 0xff, 0x7f, 0x75, 0x10, 0x95, 2, 0x81, 2 }) != null);
    const n = try m91_fixture_hex("tests/fixtures/input/m91/native-motion.hex", &bytes);
    try std.testing.expectEqual(@as(usize, 30), n);
    const coords = [_][2]u16{ .{ 0x2444, 0x672f }, .{ 0x2359, 0x6632 }, .{ 0x22b5, 0x6545 } };
    ptr_click_pending = false;
    ptr_press_pending = false;
    for (coords, 0..) |xy, i| {
        decode_usb_pointer_report(.{ .vid = 0x05ac, .pid = 0x8106 }, bytes[i * 10 ..][0..10]);
        try std.testing.expectEqual(PointerState{ .x = xy[0], .y = xy[1], .buttons = 0, .valid = true }, pointer_state());
        try std.testing.expect(take_press() == null);
        try std.testing.expect(take_click() == null);
    }
}

test "input: M91 each pointer transport has explicit boundaries and button edges" {
    const d: xhci.EnumDevice = .{ .vid = 0x05ac, .pid = 0x8106 };
    var bytes: [20]u8 = undefined;
    const n = try m91_fixture_hex("tests/fixtures/input/m91/canonical-abi.hex", &bytes);
    try std.testing.expectEqual(@as(usize, 20), n);
    // These are synthetic ABI endpoint/edge cases, not captured gestures.
    for ([_]bool{ false, true }) |native| {
        ptr_buttons = 0;
        ptr_click_pending = false;
        ptr_press_pending = false;
        for (0..4) |i| {
            const canonical = bytes[i * 5 ..][0..5];
            var wire = @as([10]u8, @splat(@as(u8, 0)));
            wire[0] = 1;
            @memcpy(wire[1..6], canonical);
            if (native) decode_usb_pointer_report(d, &wire) else decode_pointer_report(canonical);
            const want_x: u16 = if (i == 0) 0 else 32767;
            const want_y: u16 = if (i == 0 or i == 2) 0 else 32767;
            try std.testing.expectEqual(want_x, ptr_x);
            try std.testing.expectEqual(want_y, ptr_y);
            try std.testing.expectEqual(canonical[0], ptr_buttons);
            if (i == 1) {
                try std.testing.expectEqual(Click{ .x = 32767, .y = 32767 }, take_press().?);
                try std.testing.expect(take_click() != null);
            } else {
                try std.testing.expect(take_press() == null);
                try std.testing.expect(take_click() == null);
            }
        }
        // Right held -> left down must still be a left-button edge.
        const right = [_]u8{ 2, 0, 0, 0, 0 };
        const both = [_]u8{ 3, 0, 0, 0, 0 };
        if (native) {
            decode_usb_pointer_report(d, &.{ 1, 2, 0, 0, 0, 0, 0, 0, 0, 0 });
            decode_usb_pointer_report(d, &.{ 1, 3, 0, 0, 0, 0, 0, 0, 0, 0 });
        } else {
            decode_pointer_report(&right);
            decode_pointer_report(&both);
        }
        try std.testing.expect(take_press() != null);
    }
}

test "input: M91 malformed native and canonical reports are refused whole" {
    const d: xhci.EnumDevice = .{ .vid = 0x05ac, .pid = 0x8106 };
    const native = [_]u8{ 1, 1, 0xff, 0x7f, 0xff, 0x7f, 0, 0, 0, 0 };
    const canonical = native[1..6];
    decode_pointer_report(canonical);
    const before = pointer_state();
    const count = ptr_reports;
    for (0..6) |len| decode_usb_pointer_report(d, native[0..len]);
    for (0..5) |len| decode_pointer_report(canonical[0..len]);
    // Report IDs 0, 2 (feature), 3 (feature), and 255 are not pointer input.
    for ([_]u8{ 0, 2, 3, 255 }) |id| {
        var bad = native;
        bad[0] = id;
        decode_usb_pointer_report(d, &bad);
    }
    for ([_]usize{ 3, 5 }) |axis_hi| {
        var bad = native;
        bad[axis_hi] = 0x80;
        decode_usb_pointer_report(d, &bad);
    }
    decode_pointer_report(&native); // never infer transport from length
    decode_usb_pointer_report(d, &.{ 1, 1, 0xff, 0x7f, 0xff, 0x7f, 0, 0, 0, 0, 0 });
    decode_usb_pointer_report(d, canonical);
    decode_usb_pointer_report(.{}, &native);
    decode_usb_pointer_report(.{ .vid = 0x05ac, .pid = 0x8106, .hid_boot = true }, &native);
    try std.testing.expectEqual(before, pointer_state());
    try std.testing.expectEqual(count, ptr_reports);
}

test "input: M91 native drain preserves cross-device and press held release order" {
    var hw: xhci.HidTest = .{};
    hw.init();
    defer hw.deinit();
    armed_global = true;
    defer armed_global = false;
    _ = driving_award.focus(0);
    fifo_head = 0;
    fifo_count = 0;
    kb_held = @as([6]u8, @splat(@as(u8, 0)));
    ptr_buttons = 0;
    ptr_press_pending = false;
    hw.report(1, &.{ 1, 1, 0x44, 0x24, 0x2f, 0x67, 0, 0, 0, 0 });
    hw.report(0, &.{ 2, 0, 4, 0, 0, 0, 0, 0 });
    hw.report(1, &.{ 1, 1, 0x59, 0x23, 0x32, 0x66, 0, 0, 0, 0 });
    hw.report(1, &.{ 1, 0, 0x59, 0x23, 0x32, 0x66, 0, 0, 0, 0 });
    hw.report(0, &.{ 0, 0, 0, 0, 0, 0, 0, 0 });
    drain();
    try std.testing.expectEqual(@as(u8, 1), ptr_buttons);
    try std.testing.expectEqual(@as(usize, 0), fifo_count);
    try std.testing.expectEqual(Click{ .x = 0x2444, .y = 0x672f }, take_press().?);
    drain();
    try std.testing.expectEqual(@as(u8, 'A'), pop_byte().?);
    drain();
    try std.testing.expectEqual(@as(u16, 0x2359), ptr_x);
    try std.testing.expectEqual(@as(u8, 1), ptr_buttons);
    try std.testing.expect(take_press() == null);
    drain();
    try std.testing.expectEqual(@as(u8, 0), ptr_buttons);
    drain();
    try std.testing.expectEqual(@as(u8, 0), kb_mods);
    try std.testing.expectEqualSlices(u8, &(@as([6]u8, @splat(@as(u8, 0)))), &kb_held);
}

test "input: M91 keyboard release repeat modifiers rollover and malformed policy" {
    settings.init();
    driving_award.arm();
    app_events.init();
    const opened = driving_award.user_open(40, 40, 100, 100, 9);
    const id = switch (opened) {
        .opened => |i| i,
        else => return error.TestUnexpectedResult,
    };
    defer _ = driving_award.user_close(id);
    try std.testing.expect(driving_award.focus(id));
    app_events.reset(9);
    kb_held = @as([6]u8, @splat(@as(u8, 0)));
    compose_reset();
    const down = [_]u8{ 0x22, 0, 4, 4, 0, 0, 0, 0 }; // duplicate usage, both shifts
    decode_keyboard_report(&down);
    const press = app_events.pop(9).?;
    try std.testing.expectEqual(app_events.KEY_DOWN, press.kind);
    try std.testing.expectEqual(app_events.MOD_SHIFT, press.flags);
    try std.testing.expectEqual(@as(u32, 'A'), press.arg1);
    decode_keyboard_report(&down); // unchanged held report: no auto-repeat
    for (0..8) |n| decode_keyboard_report(down[0..n]);
    decode_keyboard_report(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    decode_keyboard_report(&.{ 0, 1, 0, 0, 0, 0, 0, 0 }); // reserved byte
    decode_keyboard_report(&.{ 0, 0, 1, 1, 1, 1, 1, 1 }); // rollover
    decode_keyboard_report(&.{ 0, 0, 2, 0, 0, 0, 0, 0 }); // POST failure
    decode_keyboard_report(&.{ 0, 0, 3, 0, 0, 0, 0, 0 }); // error undefined
    try std.testing.expect(app_events.pop(9) == null);
    try std.testing.expectEqual(@as(u8, 0x22), kb_mods);
    decode_keyboard_report(&.{ 0, 0, 0, 0, 0, 0, 0, 0 });
    const up = app_events.pop(9).?;
    try std.testing.expectEqual(app_events.KEY_UP, up.kind);
    try std.testing.expectEqual(@as(u32, 4), up.arg0);
    try std.testing.expectEqual(@as(u16, 0), up.flags);
    decode_keyboard_report(&down); // release + press is a new key edge
    try std.testing.expectEqual(app_events.KEY_DOWN, app_events.pop(9).?.kind);
    for (0..8) |bit| {
        const mod: u8 = @as(u8, 1) << @as(u3, @intCast(bit));
        decode_keyboard_report(&.{ mod, 0, 0, 0, 0, 0, 0, 0 });
        try std.testing.expectEqual(mod, kb_mods);
        const want = [_]u16{ app_events.MOD_CTRL, app_events.MOD_SHIFT, app_events.MOD_ALT, app_events.MOD_CMD };
        try std.testing.expectEqual(want[bit % 4], hid_modifiers_to_flags(mod));
    }
    decode_keyboard_report(&.{ 0, 0, 0, 0, 0, 0, 0, 0 });
}

test "input: hid_modifiers_to_flags maps modifiers to ADR 0009 bitmasks" {
    try std.testing.expectEqual(@as(u16, 0), hid_modifiers_to_flags(0));
    try std.testing.expectEqual(app_events.MOD_SHIFT, hid_modifiers_to_flags(0x02)); // left shift
    try std.testing.expectEqual(app_events.MOD_SHIFT, hid_modifiers_to_flags(0x20)); // right shift
    try std.testing.expectEqual(app_events.MOD_CTRL, hid_modifiers_to_flags(0x01)); // left ctrl
    try std.testing.expectEqual(app_events.MOD_CTRL, hid_modifiers_to_flags(0x10)); // right ctrl
    try std.testing.expectEqual(app_events.MOD_ALT, hid_modifiers_to_flags(0x04)); // left alt
    try std.testing.expectEqual(app_events.MOD_ALT, hid_modifiers_to_flags(0x40)); // right alt
    try std.testing.expectEqual(app_events.MOD_CMD, hid_modifiers_to_flags(0x08)); // left cmd
    try std.testing.expectEqual(app_events.MOD_CMD, hid_modifiers_to_flags(0x80)); // right cmd
    try std.testing.expectEqual(app_events.MOD_SHIFT | app_events.MOD_CTRL | app_events.MOD_ALT | app_events.MOD_CMD, hid_modifiers_to_flags(0x02 | 0x01 | 0x04 | 0x08));
}

test "input: keyboard routing delivers KEY_DOWN and KEY_UP events to focused user window" {
    app_events.init();
    driving_award.arm();
    // Open a user window owned by pid 2 (delivers WIN_FOCUS)
    const res = driving_award.user_open(10, 10, 100, 100, 2);
    try std.testing.expect(res == .opened);
    const win_id = res.opened;
    try std.testing.expectEqual(@as(?usize, 2), driving_award.focused_owner());
    _ = app_events.pop(2); // Consume WIN_FOCUS

    fifo_count = 0;
    fifo_head = 0;
    kb_held = @as([6]u8, @splat(@as(u8, 0)));

    // Press 'a' (usage 0x04) with left shift (0x02)
    decode_keyboard_report(&[_]u8{ 0x02, 0, 0x04, 0, 0, 0, 0, 0 });
    // Terminal FIFO is untouched
    try std.testing.expectEqual(@as(usize, 0), fifo_count);

    // Event queue for pid 2 receives KEY_DOWN
    try std.testing.expectEqual(@as(usize, 1), app_events.pending(2));
    const ev1 = app_events.pop(2).?;
    try std.testing.expectEqual(app_events.KEY_DOWN, ev1.kind);
    try std.testing.expectEqual(app_events.MOD_SHIFT, ev1.flags);
    try std.testing.expectEqual(@as(u32, 0x04), ev1.arg0);
    try std.testing.expectEqual(@as(u32, 'A'), ev1.arg1);

    // Release 'a'
    decode_keyboard_report(&[_]u8{ 0x02, 0, 0, 0, 0, 0, 0, 0 });
    // Event queue for pid 2 receives KEY_UP
    try std.testing.expectEqual(@as(usize, 1), app_events.pending(2));
    const ev2 = app_events.pop(2).?;
    try std.testing.expectEqual(app_events.KEY_UP, ev2.kind);
    try std.testing.expectEqual(app_events.MOD_SHIFT, ev2.flags);
    try std.testing.expectEqual(@as(u32, 0x04), ev2.arg0);
    try std.testing.expectEqual(@as(u32, 'A'), ev2.arg1);

    // Clean up window
    _ = driving_award.user_close(win_id);
}

test "input: inject_content_key delivers the decode-path pair to the focused owner (#3007)" {
    app_events.init();
    driving_award.arm();
    const res = driving_award.user_open(10, 10, 100, 100, 2);
    try std.testing.expect(res == .opened);
    const win_id = res.opened;
    _ = app_events.pop(2); // Consume WIN_FOCUS

    // Dormant with no registered seat: nothing queued, exactly like
    // wm_content_pointer's early return.
    driving_award.wm_owns_input = false;
    inject_content_key(0x0b, 0);
    try std.testing.expectEqual(@as(usize, 0), app_events.pending(2));

    // Under a seat the press lands as the pair a real report pushes:
    // KEY_DOWN then KEY_UP, usage in arg0, codepoint in arg1, mods in
    // flags.
    driving_award.wm_owns_input = true;
    defer driving_award.wm_owns_input = false;
    inject_content_key(0x0b, app_events.MOD_SHIFT); // 'H'
    try std.testing.expectEqual(@as(usize, 2), app_events.pending(2));
    const d = app_events.pop(2).?;
    try std.testing.expectEqual(app_events.KEY_DOWN, d.kind);
    try std.testing.expectEqual(app_events.MOD_SHIFT, d.flags);
    try std.testing.expectEqual(@as(u32, 0x0b), d.arg0);
    try std.testing.expectEqual(@as(u32, 'H'), d.arg1);
    const u = app_events.pop(2).?;
    try std.testing.expectEqual(app_events.KEY_UP, u.kind);
    try std.testing.expectEqual(app_events.MOD_SHIFT, u.flags);
    try std.testing.expectEqual(@as(u32, 0x0b), u.arg0);
    try std.testing.expectEqual(@as(u32, 'H'), u.arg1);

    _ = driving_award.user_close(win_id);
}

test "input: inject_content_key feeds a window-bound terminal encoded bytes, not app events (#3007)" {
    app_events.init();
    driving_award.arm();
    for (&terminal.terminals) |*tt| tt.reset();
    const res = driving_award.user_open(10, 10, 100, 100, 2);
    try std.testing.expect(res == .opened);
    const win_id = res.opened;
    _ = app_events.pop(2); // Consume WIN_FOCUS
    const th = terminal.create(2) orelse return error.TestUnexpectedResult;
    const tt = terminal.get(th).?;
    try std.testing.expect(tt.attachWindow(win_id));

    driving_award.wm_owns_input = true;
    defer driving_award.wm_owns_input = false;
    inject_content_key(0x0b, 0); // 'h' — the press's bytes, no app event
    try std.testing.expectEqual(@as(usize, 0), app_events.pending(2));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), tt.readInput(&buf));
    try std.testing.expectEqual(@as(u8, 'h'), buf[0]);

    _ = driving_award.user_close(win_id);
}

test "input: a window-bound terminal receives encoded keys, not app events (#1082 A5)" {
    app_events.init();
    driving_award.arm();
    for (&terminal.terminals) |*tt| tt.reset();
    const res = driving_award.user_open(10, 10, 100, 100, 2);
    try std.testing.expect(res == .opened);
    const win_id = res.opened;
    _ = app_events.pop(2); // Consume WIN_FOCUS
    const th = terminal.create(2) orelse return error.TestUnexpectedResult;
    const tt = terminal.get(th).?;
    try std.testing.expect(tt.attachWindow(win_id));

    fifo_count = 0;
    fifo_head = 0;
    kb_held = @as([6]u8, @splat(@as(u8, 0)));
    // Space (usage 0x2c) with no modifiers: the bound terminal gets the byte,
    // the console FIFO stays empty, and no KEY_DOWN app event is pushed.
    decode_keyboard_report(&[_]u8{ 0, 0, 0x2c, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 0), fifo_count);
    try std.testing.expectEqual(@as(usize, 0), app_events.pending(2));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), tt.readInput(&buf));
    try std.testing.expectEqual(@as(u8, ' '), buf[0]);

    // Closing the bound window auto-detaches the terminal (A6) and the
    // terminal survives, buffered, unattached.
    _ = driving_award.user_close(win_id);
    try std.testing.expect(!tt.isAttached());
    try std.testing.expect(terminal.windowTerminal(win_id) == null);
    for (&terminal.terminals) |*t2| t2.reset();
}

test "input: the M80k hygiene chords are exactly ctrl-shift-K, ctrl-shift-R and ctrl-shift-alt-R (#1727)" {
    // The chord TABLE, pinned without a window: a third modifier on 'r'
    // is the difference between a soft reset and a full RIS, so it has to
    // be a table fact rather than an if-ordering accident.
    try std.testing.expectEqual(HygieneChord.clear_scrollback, hygieneChord(0x0e, true, false, true).?);
    try std.testing.expectEqual(HygieneChord.soft_reset, hygieneChord(0x15, true, false, true).?);
    try std.testing.expectEqual(HygieneChord.ris, hygieneChord(0x15, true, true, true).?);
    // Alt alone must not buy a RIS: without ctrl+shift there is no chord.
    try std.testing.expect(hygieneChord(0x15, false, true, true) == null);
    try std.testing.expect(hygieneChord(0x15, true, false, false) == null);
    try std.testing.expect(hygieneChord(0x15, false, false, true) == null);
    try std.testing.expect(hygieneChord(0x15, true, true, false) == null);
    // Not letters: no accidental capture of the existing chrome chords
    // (ctrl-shift-C/V/F) or of a bare keystroke.
    try std.testing.expect(hygieneChord(0x06, true, false, true) == null);
    try std.testing.expect(hygieneChord(0x19, true, false, true) == null);
    try std.testing.expect(hygieneChord(0x09, true, false, true) == null);
    try std.testing.expect(hygieneChord(0x0e, false, false, false) == null);
    try std.testing.expect(hygieneChord(0x2c, false, false, false) == null); // Space
}

test "input: a hygiene chord is consumed before the tty queue — the app never sees the bytes (#1727)" {
    // The chord is a kernel presentation act, not typed input: whatever
    // the bound tty would have received for ctrl-shift-K (0x0b, the
    // kill-line control) must never reach it, and the app event queue
    // must stay empty exactly as a plain key does.
    app_events.init();
    driving_award.arm();
    for (&terminal.terminals) |*tt| tt.reset();
    const res = driving_award.user_open(10, 10, 100, 100, 2);
    try std.testing.expect(res == .opened);
    const win_id = res.opened;
    _ = app_events.pop(2); // Consume WIN_FOCUS
    const th = terminal.create(2) orelse return error.TestUnexpectedResult;
    const tt = terminal.get(th).?;
    try std.testing.expect(tt.attachWindow(win_id));
    const scr = terminal.screenForWindow(win_id).?;
    var b: [8]u8 = undefined;

    fifo_count = 0;
    fifo_head = 0;
    kb_held = @as([6]u8, @splat(@as(u8, 0)));

    // Real scrollback first: 160 lines over the 128-row grid pushes rows
    // into the ring, so the clear chord has something to actually drop.
    var line_buf: [4 * 160]u8 = undefined;
    var w: usize = 0;
    for (0..160) |_| {
        @memcpy(line_buf[w..][0..4], "row\n");
        w += 4;
    }
    scr.feed(line_buf[0..w]);
    const before = scr.historyCount();
    const used_before = scr.used;
    try std.testing.expect(before > 0);
    try std.testing.expect(scr.lineCount() > scr.used); // grid+history is one space

    // ctrl-shift-k: LCTRL(0x01) + LSHIFT(0x02) + 'k' (usage 0x0e). The
    // ED 3 semantics: the ring goes, the live grid stays.
    decode_keyboard_report(&[_]u8{ 0x03, 0, 0x0e, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 0), tt.readInput(&b));
    try std.testing.expectEqual(@as(usize, 0), app_events.pending(2));
    try std.testing.expectEqual(@as(usize, 0), fifo_count);
    try std.testing.expectEqual(@as(usize, 0), scr.historyCount());
    try std.testing.expectEqual(@as(usize, 0), scr.viewOffset());
    // The grid survives the clear (that is ED 3, not ED 2): the used row
    // count is untouched and the last written line is still its own text.
    try std.testing.expectEqual(used_before, scr.used);
    try std.testing.expectEqual(used_before, scr.lineCount());
    try std.testing.expect(std.mem.indexOf(u8, scr.line(used_before - 2), "row") != null);

    // ctrl-shift-r: LCTRL + LSHIFT + 'r' (usage 0x15) — no alt, so the
    // soft reset: no bytes, and the cursor stays where it was.
    const cur = scr.cursorLine();
    decode_keyboard_report(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }); // release
    decode_keyboard_report(&[_]u8{ 0x03, 0, 0x15, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 0), tt.readInput(&b));
    try std.testing.expectEqual(@as(usize, 0), app_events.pending(2));
    try std.testing.expectEqual(cur, scr.cursorLine());

    // ctrl-shift-alt-r: the full RIS. Still no bytes, still no app event,
    // and the grid itself is blanked.
    decode_keyboard_report(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }); // release
    decode_keyboard_report(&[_]u8{ 0x07, 0, 0x15, 0, 0, 0, 0, 0 }); // ctrl+shift+alt
    try std.testing.expectEqual(@as(usize, 0), tt.readInput(&b));
    try std.testing.expectEqual(@as(usize, 0), app_events.pending(2));
    try std.testing.expectEqual(@as(usize, 0), scr.historyCount());
    try std.testing.expectEqual(@as(usize, 0), scr.lineCount() - 1);
    try std.testing.expect(std.mem.indexOf(u8, scr.line(0), "row") == null);

    // The RIS chord left ctrl+shift+alt held — release it so the next
    // test in the binary does not inherit pressed modifiers.
    decode_keyboard_report(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }); // release
    _ = driving_award.user_close(win_id);
    for (&terminal.terminals) |*t2| t2.reset();
}
