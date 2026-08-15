//! Milestone seven, card I3 (claim 6050): keyboard/pointer event FIFO +
//! keycode decode → Road Pops.
//!
//! The XHCI interrupt-IN reports (I1/I2) land here as keyboard/pointer
//! events. The shell idle loop is the drain site (the card-3d shell-idle-
//! drain pattern, next to the net RX drain): `drain()` polls the armed
//! interrupt-IN endpoints, decodes keyboard HID boot reports (modifier +
//! 6-key rollover) into ASCII bytes through a pure keymap, and records
//! pointer reports (buttons + absolute X/Y, best-effort — raw bytes are
//! the ground truth). The decoded bytes sit in a bounded pure-BSS FIFO that
//! the Road Pops tee's read path (`pop_byte`) hands to the shell's line
//! editor — the FIRST screen-side keystrokes reach the terminal.
//!
//! The keymap covers the usable ASCII subset: letters (shift → caps),
//! digits (shift → the shifted symbol), Enter, Backspace, Tab, Space, and
//! the common punctuation. Anything outside it is honestly refused (no
//! byte is invented). Modifiers other than shift are observed (the modifier
//! byte is recorded) but not acted on beyond shift.
//!
//! No libc, no POSIX, no allocation. The FIFO and driver state are fixed
//! BSS (the card-3d pattern); a full FIFO drops the newest byte and counts
//! it (bounded, never wraps).
//!
//! Host tests exercise the pure surface (keymap, FIFO, keyboard-report
//! decode); the `drain()` path is hardware-gated (a no-op when unarmed).

const std = @import("std");
const xhci = @import("xhci.zig"); // I1/I2: the XHCI transport + enumerated HID devices

pub const max_fifo: usize = 64;

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
var kb_held: [6]u8 = [_]u8{0} ** 6;
var kb_last_usage: u8 = 0;
var kb_last_byte: u8 = 0;

var ptr_buttons: u8 = 0;
var ptr_x: u16 = 0;
var ptr_y: u16 = 0;
var ptr_reports: usize = 0;

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

/// Map a HID keyboard boot-protocol usage ID to an ASCII byte, applying
/// shift when set. Returns null for usages outside the usable subset (the
/// card's honest bound: no invented bytes). The U2 editing keys (arrows,
/// Home, End, Delete) and Ctrl chords are NOT ASCII — see `usage_bytes`.
pub fn hid_to_ascii(usage: u8, shift: bool) ?u8 {
    if (usage >= 0x04 and usage <= 0x1d) {
        // a..z
        return if (shift) 'A' + (usage - 0x04) else 'a' + (usage - 0x04);
    }
    if (usage >= 0x1e and usage <= 0x27) {
        // 1..0 (the top row)
        const unshifted = "1234567890";
        const shifted = "!@#$%^&*()";
        const i = usage - 0x1e;
        return if (shift) shifted[i] else unshifted[i];
    }
    return switch (usage) {
        0x28 => '\n', // Enter / Return
        0x2a => 0x08, // Backspace
        0x2b => '\t', // Tab
        0x2c => ' ', // Space
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

/// Milestone eight card U2 (ADR 0008 D2): the editing keys leave ASCII.
/// Arrows/Home/End/Delete become the classic ANSI sequences a serial
/// terminal sends (`ESC [ A/B/C/D`, `ESC [ H/F`, `ESC [ 3 ~`), and
/// Ctrl+letter becomes the raw control byte (0x01..0x1a) — so the line
/// editor's one parser serves both the USB-HID path and the serial path.
/// Returns the byte count written into `out` (0 = not an editing key).
pub fn usage_bytes(usage: u8, mods: u8, out: *[4]u8) usize {
    const ctrl = (mods & 0x01) != 0 or (mods & 0x10) != 0; // left/right Ctrl
    if (ctrl and usage >= 0x04 and usage <= 0x1d) {
        out[0] = usage - 0x04 + 1; // Ctrl-A..Z -> 0x01..0x1a
        return 1;
    }
    return switch (usage) {
        0x4a => seq(out, "\x1b[H"), // Home
        0x4c => seq(out, "\x1b[3~"), // Delete (forward)
        0x4d => seq(out, "\x1b[F"), // End
        0x4f => seq(out, "\x1b[C"), // Right
        0x50 => seq(out, "\x1b[D"), // Left
        0x51 => seq(out, "\x1b[B"), // Down
        0x52 => seq(out, "\x1b[A"), // Up
        else => 0,
    };
}

fn seq(out: *[4]u8, s: []const u8) usize {
    for (s, 0..) |b, i| out[i] = b;
    return s.len;
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
// Report decode (keyboard boot report + best-effort absolute pointer)
// ---------------------------------------------------------------------------

/// Decode an 8-byte HID keyboard boot report: byte 0 = modifier, bytes 2-7
/// = up to six held keycodes (the boot protocol's rollover limit). A keycode
/// present now but not in the previously-held set is a key-DOWN; its ASCII
/// byte (shift applied) is pushed. The held set is then updated.
fn decode_keyboard_report(rep: []const u8) void {
    if (rep.len < 8) return;
    const mods = rep[0];
    const shift = (mods & 0x02) != 0 or (mods & 0x20) != 0;
    kb_mods = mods;
    // Claim-time diagnostic (card U2): one line per keyboard report —
    // the raw modifier byte + the six rollover usages, so the exact usages
    // VZ delivers for the editing keys (arrows/Home/End/Delete/chords)
    // are observable in the serial log under --input.
    if (debug != null) {
        dbg("kb: rep mods=");
        dbg_hex(mods);
        dbg(" keys=");
        for (rep[2..8]) |k| {
            dbg_hex(k);
            dbg(",");
        }
        dbg("\n");
    }
    var keys: [6]u8 = [_]u8{0} ** 6;
    for (rep[2..8], 0..) |k, i| keys[i] = k;
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
            // Card U2: editing keys first (Ctrl chords + arrows/Home/End/
            // Delete -> ANSI sequences), then the printable keymap.
            var ebytes: [4]u8 = undefined;
            const n = usage_bytes(k, mods, &ebytes);
            if (n > 0) {
                kb_last_byte = ebytes[0];
                for (ebytes[0..n]) |b| push_byte(b);
                events += 1;
            } else if (hid_to_ascii(k, shift)) |b| {
                kb_last_byte = b;
                push_byte(b);
                events += 1;
            }
        }
    }
    kb_held = keys;
}

/// Record a pointer report (best-effort absolute decode: buttons + little-
/// endian X/Y). The raw bytes are the ground truth; the absolute report's
/// exact word order is a claim-time observation, recorded honestly.
fn record_pointer_report(rep: []const u8) void {
    if (rep.len < 3) return;
    ptr_buttons = rep[0];
    ptr_x = @as(u16, rep[1]) | (@as(u16, rep[2]) << 8);
    if (rep.len >= 5) {
        ptr_y = @as(u16, rep[3]) | (@as(u16, rep[4]) << 8);
    }
    ptr_reports += 1;
}

/// The shell-idle-loop drain: poll each enumerated device's interrupt-IN
/// endpoint for a completed report, decode it, and (for the keyboard) push
/// the decoded bytes. No-op when unarmed (default VM / host tests).
pub fn drain() void {
    if (!armed_global) return;
    var i: usize = 0;
    while (i < xhci.EnumMax) : (i += 1) {
        const d = xhci.enum_devs[i];
        if (!d.present or d.ep_in_num == 0) continue;
        // Non-blocking: a no-pending-event poll is one cheap event-ring
        // read, so the idle loop is not slowed by the blocking budget
        // (`usb report` keeps the blocking path).
        if (xhci.xhci_poll_intr_nb(d.slot_id)) {
            const rep = xhci.xhci_report(d.slot_id);
            const bytes = rep.bytes[0..rep.len];
            switch (xhci.hid_kind[i]) {
                .keyboard => decode_keyboard_report(bytes),
                // The absolute pointer enumerates with bInterfaceProtocol 0
                // (not a boot mouse), so hid_kind is .unknown — the raw
                // report is still recorded best-effort.
                .mouse, .unknown => record_pointer_report(bytes),
            }
        }
    }
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

// ---------------------------------------------------------------------------
// Tests (host-side; pure surface, no hardware)
// ---------------------------------------------------------------------------

test "input: hid_to_ascii maps the usable subset (unshifted + shifted)" {
    try std.testing.expectEqual(@as(?u8, 'a'), hid_to_ascii(0x04, false));
    try std.testing.expectEqual(@as(?u8, 'A'), hid_to_ascii(0x04, true));
    try std.testing.expectEqual(@as(?u8, 'z'), hid_to_ascii(0x1d, false));
    try std.testing.expectEqual(@as(?u8, 'Z'), hid_to_ascii(0x1d, true));
    try std.testing.expectEqual(@as(?u8, '1'), hid_to_ascii(0x1e, false));
    try std.testing.expectEqual(@as(?u8, '!'), hid_to_ascii(0x1e, true));
    try std.testing.expectEqual(@as(?u8, '0'), hid_to_ascii(0x27, false));
    try std.testing.expectEqual(@as(?u8, ')'), hid_to_ascii(0x27, true));
    try std.testing.expectEqual(@as(?u8, '\n'), hid_to_ascii(0x28, false));
    try std.testing.expectEqual(@as(?u8, ' '), hid_to_ascii(0x2c, false));
    try std.testing.expectEqual(@as(?u8, '-'), hid_to_ascii(0x2d, false));
    try std.testing.expectEqual(@as(?u8, '_'), hid_to_ascii(0x2d, true));
    try std.testing.expectEqual(@as(?u8, 0x08), hid_to_ascii(0x2a, false));
}

test "input: usages outside the usable subset are refused (no invented bytes)" {
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii(0x00, false));
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii(0x29, false)); // Escape
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii(0x39, false)); // Caps Lock
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii(0x4c, false)); // Delete (not ASCII)
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii(0xe0, false)); // Left Ctrl
}

test "input: card U2 — editing usages map to the ANSI sequences a serial terminal sends" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[A", out[0..usage_bytes(0x52, 0, &out)]); // Up
    try std.testing.expectEqualStrings("\x1b[B", out[0..usage_bytes(0x51, 0, &out)]); // Down
    try std.testing.expectEqualStrings("\x1b[C", out[0..usage_bytes(0x4f, 0, &out)]); // Right
    try std.testing.expectEqualStrings("\x1b[D", out[0..usage_bytes(0x50, 0, &out)]); // Left
    try std.testing.expectEqualStrings("\x1b[H", out[0..usage_bytes(0x4a, 0, &out)]); // Home
    try std.testing.expectEqualStrings("\x1b[F", out[0..usage_bytes(0x4d, 0, &out)]); // End
    try std.testing.expectEqualStrings("\x1b[3~", out[0..usage_bytes(0x4c, 0, &out)]); // Delete
    // Not editing keys: zero bytes (the ASCII keymap handles them, or refuses).
    try std.testing.expectEqual(@as(usize, 0), usage_bytes(0x04, 0, &out));
    try std.testing.expectEqual(@as(usize, 0), usage_bytes(0x28, 0, &out));
    try std.testing.expectEqual(@as(usize, 0), usage_bytes(0x39, 0, &out));
}

test "input: card U2 — Ctrl+letter maps to the raw control byte (both Ctrl mods)" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqualStrings("\x01", out[0..usage_bytes(0x04, 0x01, &out)]); // Ctrl-A (left)
    try std.testing.expectEqualStrings("\x05", out[0..usage_bytes(0x08, 0x10, &out)]); // Ctrl-E (right)
    try std.testing.expectEqualStrings("\x03", out[0..usage_bytes(0x06, 0x01, &out)]); // Ctrl-C
    try std.testing.expectEqualStrings("\x0b", out[0..usage_bytes(0x0e, 0x01, &out)]); // Ctrl-K ('k' = 0x0e)
    try std.testing.expectEqualStrings("\x15", out[0..usage_bytes(0x18, 0x01, &out)]); // Ctrl-U ('u' = 0x18)
    try std.testing.expectEqualStrings("\x0c", out[0..usage_bytes(0x0f, 0x01, &out)]); // Ctrl-L ('l' = 0x0f)
    // Ctrl without a letter is not a chord (e.g. Ctrl+Enter stays Enter).
    try std.testing.expectEqual(@as(usize, 0), usage_bytes(0x28, 0x01, &out));
}

test "input: keyboard report decode pushes arrow sequences and Ctrl chords" {
    fifo_count = 0;
    fifo_head = 0;
    events = 0;
    dropped = 0;
    kb_held = [_]u8{0} ** 6;
    // Up arrow pressed (usage 0x52): ESC [ A lands in the FIFO.
    decode_keyboard_report(&[_]u8{ 0, 0, 0x52, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 3), fifo_count);
    try std.testing.expectEqual(@as(u8, 0x1b), pop_byte().?);
    try std.testing.expectEqual(@as(u8, '['), pop_byte().?);
    try std.testing.expectEqual(@as(u8, 'A'), pop_byte().?);
    // Ctrl+A pressed (left Ctrl 0x01 + usage 0x04): 0x01 lands.
    decode_keyboard_report(&[_]u8{ 0x01, 0, 0x04, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 1), fifo_count);
    try std.testing.expectEqual(@as(u8, 0x01), pop_byte().?);
    try std.testing.expectEqual(@as(usize, 2), events);
}

test "input: keyboard report decode pushes key-down bytes with shift" {
    // Reset the module state (host tests share the globals).
    fifo_count = 0;
    fifo_head = 0;
    events = 0;
    dropped = 0;
    kb_held = [_]u8{0} ** 6;
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
}

test "input: a held key does not re-fire (no repeat on unchanged report)" {
    fifo_count = 0;
    fifo_head = 0;
    events = 0;
    kb_held = [_]u8{0} ** 6;
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
    record_pointer_report(&[_]u8{ 0x01, 0x34, 0x12, 0x78, 0x56 });
    try std.testing.expectEqual(@as(u8, 0x01), ptr_buttons);
    try std.testing.expectEqual(@as(u16, 0x1234), ptr_x);
    try std.testing.expectEqual(@as(u16, 0x5678), ptr_y);
    try std.testing.expectEqual(@as(usize, 1), ptr_reports);
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
