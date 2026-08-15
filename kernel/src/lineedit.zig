//! Bounded line editor (Milestone 1.5, console & shell core; milestone
//! eight card U2, ADR 0008 D2: editing & history).
//!
//! A fixed 256-byte line buffer with no allocation and no libc. Feed it
//! console bytes one at a time; it echoes editing back and reports when a
//! complete line is ready (CR/LF), when the line was cancelled (Ctrl-C),
//! or that it is still mid-line. Input beyond the buffer is **refused**
//! (bell + `rejected` flag), never silently truncated mid-word.
//!
//! Card U2 (ADR 0008 D2) adds, as bounded fixed state: a session-scoped
//! history ring (up/down recall), cursor movement (left/right, Home, End),
//! editing chords (Ctrl-A/E/K/U/L, plus the existing Ctrl-C), forward
//! Delete, and tab completion through an injected completer (bell on no
//! match or ambiguity — no alternative listing). Arrow/Home/End/Delete
//! arrive as the classic ANSI sequences (`ESC [ A/B/C/D`, `ESC [ H/F`,
//! `ESC [ 3 ~`) so the SAME parser serves both input paths: the USB-HID
//! keymap (input.zig) emits these sequences for the arrow/Home/End/Delete
//! usages, and a serial terminal sends them natively. Ctrl+letter arrives
//! as the raw control byte (0x01..0x1a) on both paths.
//!
//! The editor stays deliberately dumb about terminals: it emits the classic
//! `\b \b` erase pair for backspace at end, `\r\n` on submit, `^C\r\n` on
//! cancel, and the ASCII bell (0x07) when an action is refused. Mid-line
//! edits re-echo the tail and backspace back — no forward cursor movement
//! is ever emitted, so a terminal that understands only `\b` renders every
//! editing action correctly. Ctrl-L reuses the `clear` command's
//! erase-in-display sequence and redraws prompt + line. Every byte stream
//! is deterministic, so host tests assert it exactly.

const std = @import("std");
const console = @import("console.zig");

/// Fixed line capacity in bytes (march step 10: "Fixed 256-byte line
/// buffer"). `max_line` bytes fit exactly; the next byte is refused.
pub const max_line: usize = 256;

/// History capacity in entries (ADR 0008 D2: "bounded history ring,
/// session-scoped"). The ring holds the newest `max_history` submitted
/// lines; older ones are overwritten. 16 x 256 B = 4 KiB of fixed state.
pub const max_history: usize = 16;

pub const LineResult = enum {
    /// Byte consumed; the line is still being edited.
    none,
    /// A complete line is in `buffer[0..len]` (terminated by CR or LF).
    submitted,
    /// Ctrl-C cleared the line; the buffer is empty again.
    cancelled,
};

/// Tab-completion hook (card U2). Given the line up to the cursor, return
/// the bytes to insert at the cursor (the completion extension), or null
/// when there is no match / the match is ambiguous (the editor bells).
/// The shell wires this to the monitor's verb/sub-verb lookup; the editor
/// itself stays transport- and registry-agnostic.
pub const Completer = *const fn (line: []const u8) ?[]const u8;

/// Escape-sequence parser state (the arrows/Home/End/Delete seam).
const EscState = enum {
    /// Not in a sequence.
    none,
    /// Saw ESC; expecting `[` (or a lone ESC that goes nowhere).
    esc,
    /// Saw `ESC [`; expecting the final byte or a parameter.
    csi,
    /// Saw `ESC [ <digits>`; expecting `~` (the Delete form `ESC [ 3 ~`).
    csi_param,
};

pub const LineEditor = struct {
    buffer: [max_line]u8 = undefined,
    len: usize = 0,
    /// Insert point, 0..len. The editor tracks it; every echo keeps the
    /// terminal's displayed cursor in sync with it.
    cursor: usize = 0,
    /// True when at least one input byte was refused because the buffer
    /// was full. Survives until `nextLine`/`reset`; the shell prints an
    /// overflow notice for the submitted line.
    rejected: bool = false,
    /// Set when the last submitted line ended in CR. The LF half of a
    /// CRLF pair arrives on the very next feed and is swallowed, so one
    /// Enter produces one line. Kept by `nextLine` (a submit is normally
    /// followed by the pair's LF), cleared by `reset` and by any other
    /// input byte.
    submitted_cr: bool = false,
    /// Redraw target for Ctrl-L (clear screen + repaint). The shell sets
    /// it to `dipshit> `; host tests keep it empty.
    prompt: []const u8 = "",
    /// Tab-completion hook (null = tab is refused with a bell).
    completer: ?Completer = null,

    // Escape-sequence parser (per-byte; sequences arrive one byte per feed).
    esc: EscState = .none,
    esc_param: u8 = 0,

    // History ring (session-scoped; survives line submits and cancels).
    history: [max_history][max_line]u8 = undefined,
    /// Number of valid entries (oldest..newest = ring order 0..hist_len).
    hist_len: usize = 0,
    /// Next insert slot (the ring's moving write head).
    hist_next: usize = 0,
    /// Browsing position, 0..hist_len. `hist_len` means "the live draft"
    /// (not browsing). Up decrements, Down increments.
    hist_pos: usize = 0,
    /// The in-progress line saved when Up first leaves the live draft;
    /// Down past the newest entry restores it.
    draft: [max_line]u8 = undefined,
    draft_len: usize = 0,
    have_draft: bool = false,

    /// Full reset: empty line, clear flags, drop any browse state (the
    /// history ring itself survives — it is session-scoped).
    pub fn reset(self: *LineEditor) void {
        self.len = 0;
        self.cursor = 0;
        self.rejected = false;
        self.submitted_cr = false;
        self.end_browse();
    }

    /// Prepare for the next line after a submit. Keeps the CRLF swallow
    /// window open so the pair's LF is not mistaken for a new empty line.
    pub fn next_line(self: *LineEditor) void {
        self.len = 0;
        self.cursor = 0;
        self.rejected = false;
        self.end_browse();
    }

    fn end_browse(self: *LineEditor) void {
        self.hist_pos = self.hist_len;
        self.have_draft = false;
    }

    /// Feed one console byte. Echoes editing onto `con` as it goes.
    pub fn feed(self: *LineEditor, con: console.Console, byte: u8) LineResult {
        // Escape-sequence bytes never reach the normal paths.
        if (self.esc != .none) return self.feed_esc(con, byte);
        if (byte == 0x1b) {
            self.esc = .esc;
            return .none;
        }
        // LF immediately after a CR-submitted line is the same Enter.
        if (self.submitted_cr and byte == '\n') {
            self.submitted_cr = false;
            return .none;
        }
        if (byte == '\r' or byte == '\n') {
            con.puts("\r\n");
            self.push_history();
            self.submitted_cr = byte == '\r';
            return .submitted;
        }
        if (byte == 0x08 or byte == 0x7f) { // backspace / DEL (at cursor)
            self.backspace(con);
            self.submitted_cr = false;
            return .none;
        }
        if (byte == 0x03) { // Ctrl-C: cancel the whole line
            con.puts("^C\r\n");
            self.reset();
            return .cancelled;
        }
        self.submitted_cr = false;
        switch (byte) {
            0x01 => self.cursor_home(con), // Ctrl-A
            0x05 => self.cursor_end(con), // Ctrl-E
            0x0b => self.kill_to_end(con), // Ctrl-K
            0x0c => self.clear_screen(con), // Ctrl-L
            0x15 => self.kill_to_start(con), // Ctrl-U
            '\t' => self.complete(con),
            0x20...0x7e => self.insert(con, byte),
            else => {}, // other control bytes: ignored, not echoed
        }
        return .none;
    }

    // -----------------------------------------------------------------------
    // Escape-sequence parser (up/down/left/right, Home, End, Delete)
    // -----------------------------------------------------------------------

    fn feed_esc(self: *LineEditor, con: console.Console, byte: u8) LineResult {
        switch (self.esc) {
            .none => unreachable,
            .esc => if (byte == '[') {
                self.esc = .csi;
                return .none;
            } else if (byte == 0x1b) {
                return .none; // ESC ESC: stay at the start of a sequence
            } else {
                // A lone ESC followed by a real key: the key is a normal
                // keystroke; process it through the normal paths.
                self.esc = .none;
                return self.feed(con, byte);
            },
            .csi => switch (byte) {
                'A' => { // up
                    self.esc = .none;
                    self.recall_prev(con);
                },
                'B' => { // down
                    self.esc = .none;
                    self.recall_next(con);
                },
                'C' => { // right
                    self.esc = .none;
                    self.move_right(con);
                },
                'D' => { // left
                    self.esc = .none;
                    self.move_left(con);
                },
                'H' => { // home
                    self.esc = .none;
                    self.cursor_home(con);
                },
                'F' => { // end
                    self.esc = .none;
                    self.cursor_end(con);
                },
                '0'...'9' => {
                    self.esc_param = byte - '0';
                    self.esc = .csi_param;
                },
                else => self.esc = .none, // unknown sequence: swallowed
            },
            .csi_param => switch (byte) {
                '~' => {
                    self.esc = .none;
                    if (self.esc_param == 3) self.delete_forward(con); // `ESC [ 3 ~`
                },
                '0'...'9' => {
                    // Accumulate (bounded; anything past 255 saturates and
                    // then simply never equals a handled parameter).
                    const acc = @as(u16, self.esc_param) * 10 + (byte - '0');
                    self.esc_param = if (acc > 255) 255 else @intCast(acc);
                },
                else => self.esc = .none,
            },
        }
        return .none;
    }

    // -----------------------------------------------------------------------
    // Primitive edits (each echoes its own display update)
    // -----------------------------------------------------------------------

    /// Insert a printable byte at the cursor. At end this is the classic
    /// single echo; mid-line it re-echoes the tail and backs over it.
    fn insert(self: *LineEditor, con: console.Console, byte: u8) void {
        if (self.len >= max_line) {
            self.rejected = true;
            con.putc(0x07);
            return;
        }
        const tail_len = self.len - self.cursor;
        std.mem.copyBackwards(u8, self.buffer[self.cursor + 1 .. self.len + 1], self.buffer[self.cursor..self.len]);
        self.buffer[self.cursor] = byte;
        self.len += 1;
        self.cursor += 1;
        con.putc(byte);
        con.puts(self.buffer[self.cursor..self.len]);
        self.emit_backspaces(con, tail_len);
    }

    /// Backspace: delete the byte before the cursor. At end this emits
    /// exactly the classic `\b \b` pair (the M1.5 byte seam).
    fn backspace(self: *LineEditor, con: console.Console) void {
        if (self.cursor == 0) {
            con.putc(0x07); // nothing to delete: bell
            return;
        }
        const tail_len = self.len - self.cursor;
        std.mem.copyForwards(u8, self.buffer[self.cursor - 1 .. self.len - 1], self.buffer[self.cursor..self.len]);
        self.cursor -= 1;
        self.len -= 1;
        con.putc(0x08);
        con.puts(self.buffer[self.cursor..self.len]);
        con.putc(' '); // erase the stale last char (empty when tail is empty)
        self.emit_backspaces(con, tail_len + 1);
    }

    /// Forward Delete: delete the byte at the cursor.
    fn delete_forward(self: *LineEditor, con: console.Console) void {
        if (self.cursor >= self.len) {
            con.putc(0x07); // nothing ahead: bell
            return;
        }
        const tail_len = self.len - self.cursor - 1;
        std.mem.copyForwards(u8, self.buffer[self.cursor .. self.len - 1], self.buffer[self.cursor + 1 .. self.len]);
        self.len -= 1;
        con.puts(self.buffer[self.cursor..self.len]);
        con.putc(' ');
        self.emit_backspaces(con, tail_len + 1);
    }

    fn cursor_home(self: *LineEditor, con: console.Console) void {
        self.emit_backspaces(con, self.cursor);
        self.cursor = 0;
    }

    fn cursor_end(self: *LineEditor, con: console.Console) void {
        // Re-echo the tail (harmless overwrite on any \b-only terminal);
        // the display cursor lands at the line end.
        con.puts(self.buffer[self.cursor..self.len]);
        self.cursor = self.len;
    }

    fn move_left(self: *LineEditor, con: console.Console) void {
        if (self.cursor == 0) {
            con.putc(0x07);
            return;
        }
        self.cursor -= 1;
        con.putc(0x08);
    }

    fn move_right(self: *LineEditor, con: console.Console) void {
        if (self.cursor >= self.len) {
            con.putc(0x07);
            return;
        }
        con.putc(self.buffer[self.cursor]);
        self.cursor += 1;
    }

    /// Ctrl-K: kill from the cursor to the end.
    fn kill_to_end(self: *LineEditor, con: console.Console) void {
        const killed = self.len - self.cursor;
        self.len = self.cursor;
        var i: usize = 0;
        while (i < killed) : (i += 1) con.putc(' ');
        self.emit_backspaces(con, killed);
    }

    /// Ctrl-U: kill from the start to the cursor.
    fn kill_to_start(self: *LineEditor, con: console.Console) void {
        const kept = self.len - self.cursor;
        if (self.cursor == 0) return;
        std.mem.copyForwards(u8, self.buffer[0..kept], self.buffer[self.cursor..self.len]);
        const moved = self.cursor;
        self.len = kept;
        self.cursor = 0;
        self.emit_backspaces(con, moved);
        con.puts(self.buffer[0..self.len]);
        var i: usize = 0;
        while (i < moved) : (i += 1) con.putc(' ');
        self.emit_backspaces(con, moved);
    }

    /// Ctrl-L: clear the screen (the `clear` command's sequence) and
    /// repaint the prompt + line with the cursor where it was.
    fn clear_screen(self: *LineEditor, con: console.Console) void {
        con.puts("\x1b[2J\x1b[H");
        con.puts(self.prompt);
        con.puts(self.buffer[0..self.len]);
        self.emit_backspaces(con, self.len - self.cursor);
    }

    fn emit_backspaces(self: *LineEditor, con: console.Console, n: usize) void {
        _ = self;
        var i: usize = 0;
        while (i < n) : (i += 1) con.putc(0x08);
    }

    // -----------------------------------------------------------------------
    // Tab completion (injected completer; bell on no match / ambiguity)
    // -----------------------------------------------------------------------

    fn complete(self: *LineEditor, con: console.Console) void {
        const cp = self.completer orelse {
            con.putc(0x07); // no completer wired: tab is refused
            return;
        };
        const ext = cp(self.buffer[0..self.cursor]) orelse {
            con.putc(0x07); // no match or ambiguous
            return;
        };
        for (ext) |b| self.insert(con, b);
    }

    // -----------------------------------------------------------------------
    // History ring (session-scoped)
    // -----------------------------------------------------------------------

    /// Ring slot for entry index `i` (0 = oldest valid entry).
    fn hist_slot(self: *const LineEditor, i: usize) usize {
        const first = (self.hist_next + max_history - self.hist_len) % max_history;
        return (first + i) % max_history;
    }

    /// Record a submitted line. Empty lines and immediate repeats of the
    /// newest entry are skipped (the classic dedupe).
    fn push_history(self: *LineEditor) void {
        if (self.len == 0) return;
        if (self.hist_len > 0) {
            const newest = self.history[self.hist_slot(self.hist_len - 1)];
            var newest_len: usize = 0;
            while (newest_len < max_line and newest[newest_len] != 0) : (newest_len += 1) {}
            if (newest_len == self.len and std.mem.eql(u8, newest[0..newest_len], self.buffer[0..self.len])) return;
        }
        const slot = self.hist_next;
        @memset(&self.history[slot], 0);
        @memcpy(self.history[slot][0..self.len], self.buffer[0..self.len]);
        self.hist_next = (self.hist_next + 1) % max_history;
        if (self.hist_len < max_history) self.hist_len += 1;
    }

    /// Up: walk one entry back; the first Up saves the live draft.
    fn recall_prev(self: *LineEditor, con: console.Console) void {
        if (self.hist_len == 0 or self.hist_pos == 0) {
            con.putc(0x07);
            return;
        }
        if (self.hist_pos == self.hist_len) {
            @memcpy(self.draft[0..self.len], self.buffer[0..self.len]);
            self.draft_len = self.len;
            self.have_draft = true;
        }
        self.hist_pos -= 1;
        self.show_history_entry(con, self.hist_slot(self.hist_pos));
    }

    /// Down: walk one entry forward; past the newest restores the draft.
    fn recall_next(self: *LineEditor, con: console.Console) void {
        if (self.hist_len == 0 or self.hist_pos == self.hist_len) {
            con.putc(0x07);
            return;
        }
        self.hist_pos += 1;
        if (self.hist_pos == self.hist_len) {
            if (self.have_draft) {
                const n = self.draft_len;
                self.replace_line(con, self.draft[0..n]);
            } else {
                self.replace_line(con, "");
            }
            return;
        }
        self.show_history_entry(con, self.hist_slot(self.hist_pos));
    }

    fn show_history_entry(self: *LineEditor, con: console.Console, slot: usize) void {
        const entry = self.history[slot];
        var n: usize = 0;
        while (n < max_line and entry[n] != 0) : (n += 1) {}
        self.replace_line(con, entry[0..n]);
    }

    /// Replace the displayed line wholesale (recall): back up to the line
    /// start, print the new content, erase any stale tail, park at the end.
    fn replace_line(self: *LineEditor, con: console.Console, new: []const u8) void {
        const old_len = self.len;
        self.emit_backspaces(con, self.cursor);
        const n = @min(new.len, max_line);
        @memcpy(self.buffer[0..n], new[0..n]);
        self.len = n;
        self.cursor = n;
        con.puts(self.buffer[0..self.len]);
        if (old_len > n) {
            var i: usize = 0;
            while (i < old_len - n) : (i += 1) con.putc(' ');
            self.emit_backspaces(con, old_len - n);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests (host-side; no hardware)
// ---------------------------------------------------------------------------

test "lineedit: empty line submits immediately on LF" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
    try std.testing.expectEqual(@as(usize, 0), editor.len);
    try std.testing.expectEqualStrings("\r\n", mock.contents());
    try std.testing.expect(!editor.rejected);
}

test "lineedit: CR alone submits (no LF required)" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    _ = editor.feed(mock.console(), 'h');
    _ = editor.feed(mock.console(), 'i');
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\r'));
    try std.testing.expectEqualStrings("hi\r\n", mock.contents());
    try std.testing.expectEqual(@as(usize, 2), editor.len);
}

test "lineedit: CRLF pair submits exactly one line" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    _ = editor.feed(mock.console(), 'a');
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\r'));
    editor.next_line();
    // The LF half of the same CRLF pair must not start an empty line.
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), '\n'));
    try std.testing.expectEqual(@as(usize, 0), editor.len);
    try std.testing.expectEqualStrings("a\r\n", mock.contents());
    // A subsequent LF really does start a fresh (empty) line.
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
}

test "lineedit: backspace deletes and erases" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    _ = editor.feed(mock.console(), 'a');
    _ = editor.feed(mock.console(), 'b');
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 0x08));
    try std.testing.expectEqual(@as(usize, 1), editor.len);
    try std.testing.expectEqual('a', editor.buffer[0]);
    try std.testing.expectEqualStrings("ab\x08 \x08", mock.contents());
}

test "lineedit: backspace at start is refused with a bell" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 0x7f));
    try std.testing.expectEqual(@as(usize, 0), editor.len);
    try std.testing.expectEqualStrings("\x07", mock.contents());
}

test "lineedit: 255 and 256 chars fit exactly and submit" {
    var mock = console.MockConsole(1024){};
    var editor = LineEditor{};
    const line_255 = [_]u8{'a'} ** 255;
    for (line_255) |c| try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), c));
    try std.testing.expectEqual(@as(usize, 255), editor.len);
    try std.testing.expect(!editor.rejected);
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
    editor.next_line();

    const line_256 = [_]u8{'b'} ** 256;
    for (line_256) |c| try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), c));
    try std.testing.expectEqual(@as(usize, 256), editor.len);
    try std.testing.expect(!editor.rejected);
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
    // The 255-char line was echoed, then the 256-char line: content matches.
    try std.testing.expectEqual(@as(usize, 255 + 256 + 2 * 2), mock.contents().len);
}

test "lineedit: the 257th char is refused, never truncated mid-word" {
    var mock = console.MockConsole(1024){};
    var editor = LineEditor{};
    const line_257 = [_]u8{'c'} ** 257;
    for (line_257) |c| try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), c));
    try std.testing.expectEqual(@as(usize, 256), editor.len); // 257th refused
    try std.testing.expect(editor.rejected);
    // The refusal echoed one bell after the 256 echoed chars.
    try std.testing.expectEqualStrings("c" ** 256 ++ "\x07", mock.contents());
    // The line still submits (with what fit); rejected stays set for the shell.
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
    try std.testing.expect(editor.rejected);
}

test "lineedit: ctrl-c cancels and clears" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    _ = editor.feed(mock.console(), 'x');
    _ = editor.feed(mock.console(), 'y');
    try std.testing.expectEqual(LineResult.cancelled, editor.feed(mock.console(), 0x03));
    try std.testing.expectEqual(@as(usize, 0), editor.len);
    try std.testing.expect(!editor.rejected);
    try std.testing.expectEqualStrings("xy^C\r\n", mock.contents());
    // After cancel, a fresh line works.
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 'z'));
    try std.testing.expectEqual(@as(usize, 1), editor.len);
}

test "lineedit: tab without a completer is refused with a bell (U2)" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), '\t'));
    try std.testing.expectEqual(@as(usize, 0), editor.len);
    try std.testing.expectEqualStrings("\x07", mock.contents());
}

// A test completer: extends "hel" -> "help " and "net u" -> "udp ".
fn test_completer(line: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, line, "hel")) return "p ";
    if (std.mem.eql(u8, line, "net u")) return "dp ";
    return null;
}

test "lineedit: tab completion inserts the extension at the cursor" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{ .completer = test_completer };
    _ = editor.feed(mock.console(), 'h');
    _ = editor.feed(mock.console(), 'e');
    _ = editor.feed(mock.console(), 'l');
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), '\t'));
    try std.testing.expectEqualStrings("help ", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 5), editor.cursor);
    // The extension is echoed: "p " after the typed "hel".
    try std.testing.expectEqualStrings("help ", mock.contents());
    // A second tab has no match left ("help " is not "hel"): bell.
    mock.reset();
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), '\t'));
    try std.testing.expectEqualStrings("\x07", mock.contents());
}

test "lineedit: completion with no match or a null completer bells" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{ .completer = test_completer };
    _ = editor.feed(mock.console(), 'q');
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), '\t'));
    try std.testing.expectEqual(@as(usize, 1), editor.len);
    try std.testing.expectEqualStrings("q\x07", mock.contents());
}

test "lineedit: cursor left/right move and bell at the edges" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    _ = editor.feed(mock.console(), 'a');
    _ = editor.feed(mock.console(), 'b');
    // Left: one backspace of display movement.
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 0x1b));
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), '['));
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 'D'));
    try std.testing.expectEqual(@as(usize, 1), editor.cursor);
    try std.testing.expectEqualStrings("ab\x08", mock.contents());
    // Left again (to 0), then left again: bell.
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'D');
    mock.reset();
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'D');
    try std.testing.expectEqualStrings("\x07", mock.contents());
    // Right: re-echo the char under the cursor ('a' at position 0).
    mock.reset();
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'C');
    try std.testing.expectEqual(@as(usize, 1), editor.cursor);
    try std.testing.expectEqualStrings("a", mock.contents());
    // Right at end: bell.
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'C');
    mock.reset();
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'C');
    try std.testing.expectEqualStrings("\x07", mock.contents());
}

test "lineedit: mid-line insert re-echoes the tail" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    _ = editor.feed(mock.console(), 'a');
    _ = editor.feed(mock.console(), 'c');
    // Move left once (cursor 1, between 'a' and 'c'), then insert 'b':
    // the line becomes "abc".
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'D');
    try std.testing.expectEqual(@as(usize, 1), editor.cursor);
    mock.reset();
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 'b'));
    try std.testing.expectEqualStrings("abc", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 2), editor.cursor);
    // Echo: the inserted 'b', the tail "c", then one backspace.
    try std.testing.expectEqualStrings("bc\x08", mock.contents());
    // Submit from mid-line still submits the whole line.
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
    try std.testing.expectEqualStrings("abc", editor.buffer[0..editor.len]);
}

test "lineedit: mid-line backspace still ends with the classic seam bytes" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    _ = editor.feed(mock.console(), 'a');
    _ = editor.feed(mock.console(), 'b');
    _ = editor.feed(mock.console(), 'c');
    // Cursor between 'a' and 'b'; backspace removes 'a' -> "bc".
    _ = editor.feed(mock.console(), 0x01); // Ctrl-A: home
    _ = editor.feed(mock.console(), 0x05); // Ctrl-E: end
    _ = editor.feed(mock.console(), 0x1b); // left: cursor 3 -> 2
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'D');
    _ = editor.feed(mock.console(), 0x1b); // left: cursor 2 -> 1
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'D');
    try std.testing.expectEqual(@as(usize, 1), editor.cursor);
    mock.reset();
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 0x08));
    try std.testing.expectEqualStrings("bc", editor.buffer[0..editor.len]);
    // \b, tail "bc", erase space, then three backspaces.
    try std.testing.expectEqualStrings("\x08bc \x08\x08\x08", mock.contents());
    // And at end-of-line the seam is EXACTLY `\b \b` (M1.5 contract).
    _ = editor.feed(mock.console(), 0x05); // Ctrl-E: end
    mock.reset();
    _ = editor.feed(mock.console(), 0x08);
    try std.testing.expectEqualStrings("\x08 \x08", mock.contents());
}

test "lineedit: Home and End via sequences and Ctrl-A/Ctrl-E" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    _ = editor.feed(mock.console(), 'x');
    _ = editor.feed(mock.console(), 'y');
    // ESC [ H = Home.
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'H');
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
    // ESC [ F = End.
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'F');
    try std.testing.expectEqual(@as(usize, 2), editor.cursor);
    // Ctrl-A home (two backspaces), Ctrl-E end (re-echo "xy").
    mock.reset();
    _ = editor.feed(mock.console(), 0x01);
    try std.testing.expectEqualStrings("\x08\x08", mock.contents());
    mock.reset();
    _ = editor.feed(mock.console(), 0x05);
    try std.testing.expectEqualStrings("xy", mock.contents());
}

test "lineedit: forward delete via ESC [ 3 ~ and its bell" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    _ = editor.feed(mock.console(), 'a');
    _ = editor.feed(mock.console(), 'b');
    _ = editor.feed(mock.console(), 'c');
    // Home, then delete 'a' forward: "bc".
    _ = editor.feed(mock.console(), 0x01);
    mock.reset();
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), '3'));
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), '~'));
    try std.testing.expectEqualStrings("bc", editor.buffer[0..editor.len]);
    // Echo: tail "bc", erase, three backspaces.
    try std.testing.expectEqualStrings("bc \x08\x08\x08", mock.contents());
    // Delete at end: bell.
    _ = editor.feed(mock.console(), 0x05);
    mock.reset();
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), '3');
    _ = editor.feed(mock.console(), '~');
    try std.testing.expectEqualStrings("\x07", mock.contents());
}

test "lineedit: Ctrl-K kills to end, Ctrl-U kills to start" {
    var mock = console.MockConsole(256){};
    var editor = LineEditor{};
    _ = editor.feed(mock.console(), 'a');
    _ = editor.feed(mock.console(), 'b');
    _ = editor.feed(mock.console(), 'c');
    _ = editor.feed(mock.console(), 'd');
    // Home, right once (cursor 1), Ctrl-K: kills "bcd" -> "a".
    _ = editor.feed(mock.console(), 0x01);
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'C');
    mock.reset();
    _ = editor.feed(mock.console(), 0x0b);
    try std.testing.expectEqualStrings("a", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 1), editor.cursor);
    // Echo: three spaces, three backspaces.
    try std.testing.expectEqualStrings("   \x08\x08\x08", mock.contents());
    // Type "xyz" (line "axyz"), Ctrl-E, Ctrl-U: kills all -> "".
    _ = editor.feed(mock.console(), 'x');
    _ = editor.feed(mock.console(), 'y');
    _ = editor.feed(mock.console(), 'z');
    _ = editor.feed(mock.console(), 0x05); // Ctrl-E: end (cursor 4)
    mock.reset();
    _ = editor.feed(mock.console(), 0x15);
    try std.testing.expectEqual(@as(usize, 0), editor.len);
    // Echo: \b x4, kept "" (nothing printed), spaces x4, backspaces x4.
    try std.testing.expectEqualStrings("\x08\x08\x08\x08    \x08\x08\x08\x08", mock.contents());
}

test "lineedit: Ctrl-L clears and repaints prompt + line at the cursor" {
    var mock = console.MockConsole(128){};
    var editor = LineEditor{ .prompt = "dipshit> " };
    _ = editor.feed(mock.console(), 'h');
    _ = editor.feed(mock.console(), 'i');
    _ = editor.feed(mock.console(), 0x01); // home
    mock.reset();
    _ = editor.feed(mock.console(), 0x0c); // Ctrl-L
    try std.testing.expectEqualStrings("\x1b[2J\x1b[Hdipshit> hi\x08\x08", mock.contents());
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
}

test "lineedit: up/down recall walks the history and restores the draft" {
    var mock = console.MockConsole(256){};
    var editor = LineEditor{};
    // Submit two lines (each push happens on submit).
    for ("one") |c| _ = editor.feed(mock.console(), c);
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
    editor.next_line();
    for ("two") |c| _ = editor.feed(mock.console(), c);
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
    editor.next_line();
    try std.testing.expectEqual(@as(usize, 2), editor.hist_len);

    // Up: newest ("two").
    mock.reset();
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'A');
    try std.testing.expectEqualStrings("two", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 3), editor.cursor);
    try std.testing.expectEqualStrings("two", mock.contents());
    // Up again: oldest ("one") — display backs up and reprints.
    mock.reset();
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'A');
    try std.testing.expectEqualStrings("one", editor.buffer[0..editor.len]);
    // \b\b\b (from "two"'s end) + "one".
    try std.testing.expectEqualStrings("\x08\x08\x08one", mock.contents());
    // Up at the oldest: bell.
    mock.reset();
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'A');
    try std.testing.expectEqualStrings("\x07", mock.contents());
    // Down: newest again; replace display.
    mock.reset();
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'B');
    try std.testing.expectEqualStrings("two", editor.buffer[0..editor.len]);
    // Down past the newest with no draft: empty line, stale erased.
    mock.reset();
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'B');
    try std.testing.expectEqual(@as(usize, 0), editor.len);
    try std.testing.expectEqualStrings("\x08\x08\x08   \x08\x08\x08", mock.contents());
    // Down at the live line: bell.
    mock.reset();
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'B');
    try std.testing.expectEqualStrings("\x07", mock.contents());

    // Draft restore: type "abc", Up (saves draft, shows "two"), Down
    // (returns to the live line): "abc" is back.
    for ("abc") |c| _ = editor.feed(mock.console(), c);
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'A');
    try std.testing.expectEqualStrings("two", editor.buffer[0..editor.len]);
    mock.reset();
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'B');
    try std.testing.expectEqualStrings("abc", editor.buffer[0..editor.len]);
    // Display: back over "two", print "abc", no stale tail.
    try std.testing.expectEqualStrings("\x08\x08\x08abc", mock.contents());
}

test "lineedit: empty lines and immediate repeats are not recorded" {
    var mock = console.MockConsole(128){};
    var editor = LineEditor{};
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n')); // empty
    editor.next_line();
    try std.testing.expectEqual(@as(usize, 0), editor.hist_len);
    for ("dup") |c| _ = editor.feed(mock.console(), c);
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
    editor.next_line();
    for ("dup") |c| _ = editor.feed(mock.console(), c);
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
    editor.next_line();
    try std.testing.expectEqual(@as(usize, 1), editor.hist_len); // repeat skipped
    // Cancel does not record.
    for ("gone") |c| _ = editor.feed(mock.console(), c);
    try std.testing.expectEqual(LineResult.cancelled, editor.feed(mock.console(), 0x03));
    try std.testing.expectEqual(@as(usize, 1), editor.hist_len);
}

test "lineedit: the history ring wraps at max_history, keeping the newest" {
    var mock = console.MockConsole(256){};
    var editor = LineEditor{};
    var i: usize = 0;
    while (i < max_history + 3) : (i += 1) {
        var buf: [8]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "l{d}", .{i});
        for (s) |c| _ = editor.feed(mock.console(), c);
        try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
        editor.next_line();
    }
    try std.testing.expectEqual(max_history, editor.hist_len);
    // The newest entry is "l18" (max_history + 2); the oldest kept is "l3".
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'A');
    try std.testing.expectEqualStrings("l18", editor.buffer[0..editor.len]);
    var up: usize = 1;
    while (up < max_history) : (up += 1) {
        _ = editor.feed(mock.console(), 0x1b);
        _ = editor.feed(mock.console(), '[');
        _ = editor.feed(mock.console(), 'A');
    }
    try std.testing.expectEqualStrings("l3", editor.buffer[0..editor.len]);
}

test "lineedit: unknown escape sequences are swallowed; lone ESC passes the next key through" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    // ESC [ Z (unknown final): swallowed entirely.
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 'Z'));
    try std.testing.expectEqual(@as(usize, 0), editor.len);
    // Lone ESC then a printable: the printable is a normal keystroke.
    _ = editor.feed(mock.console(), 0x1b);
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 'k'));
    try std.testing.expectEqualStrings("k", editor.buffer[0..editor.len]);
    // ESC [ 5 ~ (an unhandled parameter): swallowed.
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), '5');
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), '~'));
    try std.testing.expectEqualStrings("k", editor.buffer[0..editor.len]);
    try std.testing.expectEqualStrings("k", mock.contents());
}

test "lineedit: submit while browsing keeps the recalled line and resets browsing" {
    var mock = console.MockConsole(128){};
    var editor = LineEditor{};
    for ("first") |c| _ = editor.feed(mock.console(), c);
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
    editor.next_line();
    // Recall "first", edit it to "first2", submit.
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'A');
    _ = editor.feed(mock.console(), '2');
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
    try std.testing.expectEqualStrings("first2", editor.buffer[0..editor.len]);
    editor.next_line();
    try std.testing.expectEqual(@as(usize, 2), editor.hist_len);
    // Up now recalls "first2".
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'A');
    try std.testing.expectEqualStrings("first2", editor.buffer[0..editor.len]);
}
