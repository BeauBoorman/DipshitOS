//! Bounded line editor (Milestone 1.5, console & shell core; extended by
//! milestone eight card U2, ADR 0008 D2).
//!
//! A fixed 256-byte line buffer with no allocation and no libc. Feed it
//! console bytes one at a time; it echoes editing back and reports when a
//! complete line is ready (CR/LF), when the line was cancelled (Ctrl-C),
//! that it is still mid-line, or that Ctrl-L cleared the screen (repaint).
//! Input beyond the buffer is **refused** (bell + `rejected` flag), never
//! silently truncated mid-word.
//!
//! Milestone eight (ADR 0008 D2) adds, all as fixed BSS:
//!   * a bounded session history ring (Up/Down recall);
//!   * cursor movement (Left/Right/Home/End) and Delete in addition to
//!     Backspace;
//!   * the editing chords Ctrl-A (start), Ctrl-E (end), Ctrl-K (kill to
//!     end), Ctrl-U (kill to start), Ctrl-L (clear screen), Ctrl-C (cancel);
//!   * tab completion through an injected completer callback (the shell
//!     wires the command registry), a bell on no/ambiguous completion.
//!
//! The special keys arrive from `input.zig` as `ESC [ <final>` sequences
//! (the editor never echoes those bytes — it turns them into editing
//! actions), and Ctrl chords arrive as the ASCII control codes 0x01/0x05/
//! 0x0b/0x15/0x0c/0x03.
//!
//! The echo protocol is deliberately dumb-terminal so BOTH the serial
//! console and the framebuffer text layer (`text.zig`, which honors `\b`
//! and `\r`) render it: left/homes emit backspace (`\b`), and every
//! mid-line edit/recall redraws the whole line with backspace-back-to-start
//! + reprint + trailing-space clear + backspace-reposition. UTF-8 input
//! inserts and edits whole scalars; the ASCII backspace-at-end fast path
//! still emits `\b \b`, submit emits `\r\n`, cancel emits `^C\r\n`. Editing
//! across a wrapped line is approximate (the same honest bound as the
//! original erase pair); no ANSI is emitted except Ctrl-L's screen clear.

const std = @import("std");
const console = @import("console.zig");

/// Fixed line capacity in bytes (march step 10: "Fixed 256-byte line
/// buffer"). `max_line` bytes fit exactly; the next byte is refused.
pub const max_line: usize = 256;

/// Bounded history-ring capacity (ADR 0008 D2): the most recent N submitted
/// lines, session-scoped, in fixed BSS (no allocation). NOTE: the kernel's
/// Shell lives in BSS (not the kernel stack) because this ring is
/// N × max_line bytes — see `boot_shell_storage` in shell.zig.
pub const hist_capacity: usize = 16;

pub const LineResult = enum {
    /// Byte consumed; the line is still being edited.
    none,
    /// A complete line is in `buffer[0..len]` (terminated by CR or LF).
    submitted,
    /// Ctrl-C cleared the line; the buffer is empty again.
    cancelled,
    /// Ctrl-L cleared the screen; the caller must reprint the prompt and
    /// call `reprint` to restore the line (the editor does not own the
    /// prompt, so it cannot redraw it itself).
    repaint,
};

pub const CompletionMatch = struct {
    replace_start: usize,
    text: []const u8,
    match_count: usize = 1,
    has_trailing_space: bool = false,
};

pub const CompleterFn = *const fn (line: []const u8, cursor: usize, index: usize) ?CompletionMatch;

pub const LineEditor = struct {
    buffer: [max_line]u8 = undefined,
    len: usize = 0,
    /// The insertion point as a byte offset (0..len), always at a UTF-8
    /// boundary. The shell owns the prompt; redraw uses character columns.
    cursor: usize = 0,
    /// True when at least one input byte was refused because the buffer
    /// was full. Survives until `nextLine`/`reset`; the shell prints an
    /// overflow notice for the submitted line.
    rejected: bool = false,
    /// Set when the last submitted line ended in CR. The LF half of a
    /// CRLF pair arrives on the very next feed and is swallowed, so one
    /// Enter produces one line.
    submitted_cr: bool = false,

    // Bounded session history (ADR 0008 D2): index 0 = most recent.
    history: [hist_capacity][max_line]u8 = undefined,
    hist_len: [hist_capacity]usize = undefined,
    hist_count: usize = 0,
    /// Recall position: 0 = editing a fresh line; 1..=hist_count = the
    /// recalled entry (1 = newest). `hist_draft` saves the pre-recall line
    /// so Down past the newest returns to it.
    hist_cursor: usize = 0,
    hist_draft: [max_line]u8 = undefined,
    hist_draft_len: usize = 0,

    /// CSI (`ESC [ <params> <final>`) decode state: 0 = normal, 1 = ESC,
    /// 2 = ESC [, 3 = collecting parameter bytes before the final. A
    /// sequence whose final is not one we act on is swallowed WHOLE — the
    /// tilde of an `ESC [ <n> ~` key must never reach the line as text.
    esc_state: u8 = 0,
    /// The first numeric parameter of the sequence being collected (the
    /// `3` of Delete's `ESC [ 3 ~`). Saturates: a longer parameter can
    /// only fail to match a key we handle, never wrap into one.
    esc_param: u8 = 0,
    /// A multi-byte scalar is staged until all its bytes arrive, so an edit
    /// or the buffer bound cannot split it.
    utf8_pending: [4]u8 = undefined,
    utf8_len: u8 = 0,
    utf8_need: u8 = 0,
    utf8_discard: u8 = 0,

    /// Tab-completion source (ADR 0008 D2), wired by the shell to the
    /// command registry. Given the line + cursor it returns the suffix to
    /// insert (a long-lived slice), or null on no/ambiguous completion.
    completion: ?*const fn (line: []const u8, cursor: usize) ?[]const u8 = null,

    /// Extended Tab-completion source supporting candidate cycling (issue #783).
    completer: ?CompleterFn = null,
    completing: bool = false,
    complete_replace_start: usize = 0,
    complete_orig_token: [max_line]u8 = undefined,
    complete_orig_token_len: usize = 0,
    complete_cur_token_len: usize = 0,
    complete_index: usize = 0,
    complete_match_count: usize = 0,

    /// Full reset: empty line, clear flags, the CRLF swallow window, and
    /// any in-progress recall.
    pub fn reset(self: *LineEditor) void {
        self.len = 0;
        self.cursor = 0;
        self.rejected = false;
        self.submitted_cr = false;
        self.esc_state = 0;
        self.utf8_len = 0;
        self.utf8_need = 0;
        self.utf8_discard = 0;
        self.hist_cursor = 0;
        self.completing = false;
    }

    /// Prepare for the next line after a submit. Keeps the CRLF swallow
    /// window open (the pair's LF must not start a new empty line) and
    /// keeps the history (it is session-scoped).
    pub fn next_line(self: *LineEditor) void {
        self.len = 0;
        self.cursor = 0;
        self.rejected = false;
        self.esc_state = 0;
        self.utf8_len = 0;
        self.utf8_need = 0;
        self.utf8_discard = 0;
        self.hist_cursor = 0;
        self.completing = false;
    }

    /// Abandon any in-progress CSI decode. The shell consumes the final
    /// byte of a scroll/paste/selection sequence before it reaches the
    /// editor, leaving the editor mid-`ESC [ <param>`; the next byte would
    /// otherwise be swallowed (or `[ <param>` fragments inserted). The
    /// shell calls this whenever its tracker consumes a byte.
    pub fn csi_reset(self: *LineEditor) void {
        self.esc_state = 0;
        self.esc_param = 0;
        self.completing = false;
    }

    /// Reprint the current line after a screen clear (Ctrl-L): the shell
    /// prints the prompt, then this emits the content and repositions the
    /// cursor. No redraw bookkeeping — the screen is already cleared.
    pub fn reprint(self: *const LineEditor, con: console.Console) void {
        con.puts(self.buffer[0..self.len]);
        var i: usize = 0;
        const tail_cells = cellCount(self.buffer[self.cursor..self.len]);
        while (i < tail_cells) : (i += 1) con.putc(0x08);
    }

    /// Feed one console byte. Echoes editing onto `con` as it goes.
    pub fn feed(self: *LineEditor, con: console.Console, byte: u8) LineResult {
        if (self.utf8_discard > 0) {
            if (byte >= 0x80 and byte <= 0xbf) {
                self.utf8_discard -= 1;
                return .none;
            }
            self.utf8_discard = 0;
        }
        if (self.utf8_need > 0) {
            if (byte >= 0x80 and byte <= 0xbf) {
                self.utf8_pending[self.utf8_len] = byte;
                self.utf8_len += 1;
                if (self.utf8_len == self.utf8_need) {
                    const encoded = self.utf8_pending[0..self.utf8_len];
                    self.utf8_len = 0;
                    self.utf8_need = 0;
                    _ = std.unicode.utf8Decode(encoded) catch {
                        con.putc(0x07);
                        return .none;
                    };
                    return self.insert_bytes(con, encoded);
                }
                return .none;
            }
            self.utf8_len = 0;
            self.utf8_need = 0;
            con.putc(0x07); // incomplete scalar; keep the next key
        }
        // The LF half of a CRLF pair arrives on the very next feed and is
        // swallowed (one Enter = one line).
        if (self.submitted_cr and byte == '\n') {
            self.submitted_cr = false;
            return .none;
        }
        // Any other real byte closes the CRLF swallow window.
        self.submitted_cr = false;
        if (byte != '\t') {
            self.completing = false;
        }
        // `ESC [ <final>` sequence decode: input.zig's encoding of the
        // special keys. The escape bytes are never echoed — they become
        // cursor/recall actions that emit the dumb-terminal protocol.
        switch (self.esc_state) {
            0 => {},
            else => {},
            1 => {
                self.esc_state = 0;
                if (byte == '[') {
                    self.esc_state = 2;
                    return .none;
                }
                // A lone ESC followed by anything else is not a sequence:
                // the byte is a real keystroke and is processed normally
                // (dropping it silently loses the character).
                return self.feed(con, byte);
            },
            2 => {
                switch (byte) {
                    'A' => {
                        self.esc_state = 0;
                        return self.recall_older(con);
                    },
                    'B' => {
                        self.esc_state = 0;
                        return self.recall_newer(con);
                    },
                    'C' => {
                        self.esc_state = 0;
                        return self.cursor_right(con);
                    },
                    'D' => {
                        self.esc_state = 0;
                        return self.cursor_left(con);
                    },
                    'H' => {
                        self.esc_state = 0;
                        return self.cursor_home(con);
                    },
                    'F' => {
                        self.esc_state = 0;
                        return self.cursor_end(con);
                    },
                    '0'...'9' => {
                        self.esc_param = byte - '0';
                        self.esc_state = 3;
                    },
                    else => self.esc_state = 0, // unhandled final: whole sequence swallowed
                }
                return .none;
            },
            3 => {
                // Parameter bytes (0x30-0x3f) continue the sequence; the
                // final byte (0x40-0x7e) ends it. Only Delete's `3 ~` acts.
                if (byte >= '0' and byte <= '9') {
                    const scaled = @mulWithOverflow(self.esc_param, 10);
                    const added = @addWithOverflow(scaled[0], byte - '0');
                    self.esc_param = if (scaled[1] == 1 or added[1] == 1) 255 else added[0];
                    return .none;
                }
                if (byte >= 0x3a and byte <= 0x3f) return .none; // ';' and friends
                self.esc_state = 0;
                if (byte == '~' and self.esc_param == 3) return self.delete_forward(con);
                return .none;
            },
        }
        if (byte == 0x1b) {
            self.esc_state = 1;
            return .none;
        }
        if (byte == '\r' or byte == '\n') {
            con.puts("\r\n");
            self.submitted_cr = byte == '\r';
            self.remember_line();
            return .submitted;
        }
        if (byte == 0x03) { // Ctrl-C: cancel the whole line
            con.puts("^C\r\n");
            self.reset();
            return .cancelled;
        }
        if (byte == 0x08 or byte == 0x7f) return self.backspace(con); // backspace / DEL
        // ADR 0008 D2 editing chords.
        if (byte == 0x01) return self.cursor_home(con); // Ctrl-A: start
        if (byte == 0x05) return self.cursor_end(con); // Ctrl-E: end
        if (byte == 0x0b) return self.kill_to_end(con); // Ctrl-K: kill to end
        if (byte == 0x15) return self.kill_to_start(con); // Ctrl-U: kill to start
        if (byte == 0x0c) { // Ctrl-L: clear screen (same sequence as `clear`)
            con.puts("\x1b[2J\x1b[H");
            return .repaint;
        }
        if (byte == '\t') return self.complete(con);
        if (byte >= 0xc2 and byte <= 0xf4) {
            const n = std.unicode.utf8ByteSequenceLength(byte) catch unreachable;
            if (self.len + n > max_line) {
                self.rejected = true;
                self.utf8_discard = n - 1;
                con.putc(0x07);
                return .none;
            }
            self.utf8_pending[0] = byte;
            self.utf8_len = 1;
            self.utf8_need = n;
            return .none;
        }
        if (byte >= 0x80) {
            con.putc(0x07); // stray continuation or invalid lead
            return .none;
        }
        if (byte >= 0x20 and byte != 0x7f) return self.insert(con, byte);
        // Other control bytes are ignored: not echoed, not appended.
        return .none;
    }

    // -- editing primitives ------------------------------------------------

    fn backspace(self: *LineEditor, con: console.Console) LineResult {
        if (self.len == 0 or self.cursor == 0) {
            con.putc(0x07); // nothing to delete: bell
            return .none;
        }
        const start = previousRune(self.buffer[0..self.len], self.cursor);
        if (self.cursor == self.len and start + 1 == self.cursor) {
            // Keep the classic erase pair for ASCII at the end.
            self.len -= 1;
            self.cursor -= 1;
            con.puts("\x08 \x08");
            return .none;
        }
        const old = self.displayPos();
        std.mem.copyForwards(u8, self.buffer[start..], self.buffer[self.cursor..self.len]);
        self.len -= self.cursor - start;
        self.cursor = start;
        self.redraw(con, old);
        return .none;
    }

    fn delete_forward(self: *LineEditor, con: console.Console) LineResult {
        if (self.cursor >= self.len) {
            con.putc(0x07);
            return .none;
        }
        const old = self.displayPos();
        const end = nextRune(self.buffer[0..self.len], self.cursor);
        std.mem.copyForwards(u8, self.buffer[self.cursor..], self.buffer[end..self.len]);
        self.len -= end - self.cursor;
        self.redraw(con, old);
        return .none;
    }

    fn insert(self: *LineEditor, con: console.Console, byte: u8) LineResult {
        if (self.len >= max_line) {
            self.rejected = true;
            con.putc(0x07);
            return .none;
        }
        if (self.cursor == self.len) {
            // Fast path (byte seam): append + echo, no redraw.
            self.buffer[self.len] = byte;
            self.len += 1;
            self.cursor += 1;
            con.putc(byte);
            return .none;
        }
        const old = self.displayPos();
        var i = self.len;
        while (i > self.cursor) : (i -= 1) self.buffer[i] = self.buffer[i - 1];
        self.buffer[self.cursor] = byte;
        self.len += 1;
        self.cursor += 1;
        self.redraw(con, old);
        return .none;
    }

    fn cursor_left(self: *LineEditor, con: console.Console) LineResult {
        if (self.cursor > 0) {
            self.cursor = previousRune(self.buffer[0..self.len], self.cursor);
            con.putc(0x08);
        } else {
            con.putc(0x07);
        }
        return .none;
    }

    fn cursor_right(self: *LineEditor, con: console.Console) LineResult {
        if (self.cursor < self.len) {
            const old = self.displayPos();
            self.cursor = nextRune(self.buffer[0..self.len], self.cursor);
            self.redraw(con, old);
        } else {
            con.putc(0x07);
        }
        return .none;
    }

    fn cursor_home(self: *LineEditor, con: console.Console) LineResult {
        if (self.cursor == 0) return .none;
        var i = cellCount(self.buffer[0..self.cursor]);
        while (i > 0) : (i -= 1) con.putc(0x08);
        self.cursor = 0;
        return .none;
    }

    fn cursor_end(self: *LineEditor, con: console.Console) LineResult {
        if (self.cursor == self.len) return .none;
        const old = self.displayPos();
        self.cursor = self.len;
        self.redraw(con, old);
        return .none;
    }

    fn kill_to_end(self: *LineEditor, con: console.Console) LineResult {
        if (self.cursor >= self.len) return .none; // nothing to kill
        const old = self.displayPos();
        self.len = self.cursor;
        self.redraw(con, old);
        return .none;
    }

    fn kill_to_start(self: *LineEditor, con: console.Console) LineResult {
        if (self.cursor == 0) return .none;
        const old = self.displayPos();
        // Shift buffer[cursor..len] to the start.
        const tail = self.len - self.cursor;
        var i: usize = 0;
        while (i < tail) : (i += 1) self.buffer[i] = self.buffer[self.cursor + i];
        self.len = tail;
        self.cursor = 0;
        self.redraw(con, old);
        return .none;
    }

    fn complete(self: *LineEditor, con: console.Console) LineResult {
        if (self.completer) |completer_fn| {
            return self.complete_cycle(con, completer_fn);
        }
        const complete_fn = self.completion orelse {
            con.putc(0x07); // no completion source wired
            return .none;
        };
        const suffix = complete_fn(self.buffer[0..self.len], self.cursor) orelse {
            con.putc(0x07); // no/ambiguous completion (ADR 0008 D2)
            return .none;
        };
        if (suffix.len == 0) {
            con.putc(0x07);
            return .none;
        }
        return self.insert_bytes(con, suffix);
    }

    fn complete_cycle(self: *LineEditor, con: console.Console, completer_fn: CompleterFn) LineResult {
        const old = self.displayPos();

        if (!self.completing) {
            const m = completer_fn(self.buffer[0..self.len], self.cursor, 0) orelse {
                con.putc(0x07);
                return .none;
            };
            if (m.match_count == 0 or m.replace_start > self.cursor) {
                con.putc(0x07);
                return .none;
            }

            const orig_token = self.buffer[m.replace_start..self.cursor];
            if (orig_token.len > max_line) {
                con.putc(0x07);
                return .none;
            }
            @memcpy(self.complete_orig_token[0..orig_token.len], orig_token);
            self.complete_orig_token_len = orig_token.len;
            self.complete_replace_start = m.replace_start;

            const add_space = (m.match_count == 1 and m.has_trailing_space);
            const extra_space: usize = if (add_space) 1 else 0;
            const new_token_len = m.text.len + extra_space;
            const tail_len = self.len - self.cursor;

            if (m.replace_start + new_token_len + tail_len > max_line) {
                con.putc(0x07);
                return .none;
            }

            if (m.replace_start + new_token_len > self.cursor) {
                const shift = (m.replace_start + new_token_len) - self.cursor;
                var i = self.len;
                while (i > self.cursor) : (i -= 1) {
                    self.buffer[i - 1 + shift] = self.buffer[i - 1];
                }
            } else if (m.replace_start + new_token_len < self.cursor) {
                const shift = self.cursor - (m.replace_start + new_token_len);
                var i = self.cursor;
                while (i < self.len) : (i += 1) {
                    self.buffer[i - shift] = self.buffer[i];
                }
            }

            @memcpy(self.buffer[m.replace_start .. m.replace_start + m.text.len], m.text);
            if (add_space) {
                self.buffer[m.replace_start + m.text.len] = ' ';
            }

            self.cursor = m.replace_start + new_token_len;
            self.len = m.replace_start + new_token_len + tail_len;
            self.redraw(con, old);

            if (m.match_count > 1) {
                self.completing = true;
                self.complete_cur_token_len = m.text.len;
                self.complete_index = 0;
                self.complete_match_count = m.match_count;
            } else {
                self.completing = false;
            }
            return .none;
        } else {
            self.complete_index = (self.complete_index + 1) % self.complete_match_count;

            const rep_start = self.complete_replace_start;
            const orig_len = self.complete_orig_token_len;
            const cur_token_len = self.complete_cur_token_len;
            const tail_len = self.len - self.cursor;

            var temp_buf: [max_line]u8 = undefined;
            @memcpy(temp_buf[0..rep_start], self.buffer[0..rep_start]);
            @memcpy(temp_buf[rep_start .. rep_start + orig_len], self.complete_orig_token[0..orig_len]);
            const temp_cursor = rep_start + orig_len;
            @memcpy(temp_buf[temp_cursor .. temp_cursor + tail_len], self.buffer[self.cursor .. self.cursor + tail_len]);
            const temp_len = temp_cursor + tail_len;

            const m = completer_fn(temp_buf[0..temp_len], temp_cursor, self.complete_index) orelse {
                con.putc(0x07);
                self.completing = false;
                return .none;
            };

            const old_token_end = rep_start + cur_token_len;
            const new_token_end = rep_start + m.text.len;
            if (new_token_end + tail_len > max_line) {
                con.putc(0x07);
                self.completing = false;
                return .none;
            }

            if (new_token_end > old_token_end) {
                const shift = new_token_end - old_token_end;
                var i = self.len;
                while (i > old_token_end) : (i -= 1) {
                    self.buffer[i - 1 + shift] = self.buffer[i - 1];
                }
            } else if (new_token_end < old_token_end) {
                const shift = old_token_end - new_token_end;
                var i = old_token_end;
                while (i < self.len) : (i += 1) {
                    self.buffer[i - shift] = self.buffer[i];
                }
            }

            @memcpy(self.buffer[rep_start..new_token_end], m.text);
            self.complete_cur_token_len = m.text.len;
            self.cursor = new_token_end;
            self.len = new_token_end + tail_len;
            self.redraw(con, old);
            return .none;
        }
    }

    fn insert_bytes(self: *LineEditor, con: console.Console, bytes: []const u8) LineResult {
        if (self.len + bytes.len > max_line) {
            con.putc(0x07); // completion does not fit: refused, bounded
            return .none;
        }
        if (self.cursor == self.len) {
            // Fast path: append + echo.
            @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
            self.cursor += bytes.len;
            con.puts(bytes);
            return .none;
        }
        const old = self.displayPos();
        // Shift the tail right by bytes.len (high to low, no overlap).
        var i = self.len;
        while (i > self.cursor) : (i -= 1) self.buffer[i - 1 + bytes.len] = self.buffer[i - 1];
        @memcpy(self.buffer[self.cursor..][0..bytes.len], bytes);
        self.len += bytes.len;
        self.cursor += bytes.len;
        self.redraw(con, old);
        return .none;
    }

    // -- history (ADR 0008 D2) ---------------------------------------------

    /// Store the just-submitted line (non-empty; consecutive duplicates are
    /// collapsed). Called on submit, before the shell reads the buffer.
    fn remember_line(self: *LineEditor) void {
        const line = self.buffer[0..self.len];
        if (line.len == 0) return;
        if (self.hist_count > 0 and std.mem.eql(u8, line, self.history[0][0..self.hist_len[0]])) return;
        // The fuzz (card U3) caught a latent width bug here: `@min` with the
        // comptime `hist_capacity - 1` (= 15) inferred a u4 for `keep`, so
        // `keep + 1` overflowed at the 16th distinct history entry. The
        // explicit usize anchor keeps the arithmetic at the field's width.
        const keep: usize = @min(self.hist_count, hist_capacity - 1);
        var i = keep;
        while (i > 0) : (i -= 1) {
            @memcpy(self.history[i][0..self.hist_len[i - 1]], self.history[i - 1][0..self.hist_len[i - 1]]);
            self.hist_len[i] = self.hist_len[i - 1];
        }
        @memcpy(self.history[0][0..line.len], line);
        self.hist_len[0] = line.len;
        self.hist_count = keep + 1;
    }

    fn load_line(self: *LineEditor, con: console.Console, line: []const u8) void {
        const old = self.displayPos();
        @memcpy(self.buffer[0..line.len], line);
        self.len = line.len;
        self.cursor = line.len;
        self.redraw(con, old);
    }

    fn recall_older(self: *LineEditor, con: console.Console) LineResult {
        if (self.hist_count == 0 or self.hist_cursor >= self.hist_count) {
            con.putc(0x07);
            return .none;
        }
        if (self.hist_cursor == 0) {
            // Save the draft so Down can return to it.
            @memcpy(self.hist_draft[0..self.len], self.buffer[0..self.len]);
            self.hist_draft_len = self.len;
        }
        self.hist_cursor += 1;
        self.load_line(con, self.history[self.hist_cursor - 1][0..self.hist_len[self.hist_cursor - 1]]);
        return .none;
    }

    fn recall_newer(self: *LineEditor, con: console.Console) LineResult {
        if (self.hist_cursor == 0) {
            con.putc(0x07);
            return .none;
        }
        self.hist_cursor -= 1;
        if (self.hist_cursor == 0) {
            self.load_line(con, self.hist_draft[0..self.hist_draft_len]);
        } else {
            self.load_line(con, self.history[self.hist_cursor - 1][0..self.hist_len[self.hist_cursor - 1]]);
        }
        return .none;
    }

    // -- dumb-terminal redraw ----------------------------------------------

    /// Redraw the line content. The terminal cursor is at prompt_len +
    /// the old cursor column; after the call it is at the new cursor column.
    /// Emits only `\b`, the reprint, and trailing spaces. Approximate across
    /// a wrapped line (the documented honest bound).
    fn redraw(self: *LineEditor, con: console.Console, old: DisplayPos) void {
        var i: usize = 0;
        while (i < old.cursor) : (i += 1) con.putc(0x08); // back to content start
        con.puts(self.buffer[0..self.len]); // reprint the line
        const now = self.displayPos();
        i = now.len;
        while (i < old.len) : (i += 1) con.putc(' '); // clear leftover cells
        const end_col = @max(now.len, old.len);
        i = now.cursor;
        while (i < end_col) : (i += 1) con.putc(0x08); // reposition to cursor
    }

    const DisplayPos = struct { len: usize, cursor: usize };

    fn displayPos(self: *const LineEditor) DisplayPos {
        return .{
            .len = cellCount(self.buffer[0..self.len]),
            .cursor = cellCount(self.buffer[0..self.cursor]),
        };
    }
};

fn nextRune(bytes: []const u8, at: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(bytes[at]) catch return at + 1;
    if (n > bytes.len - at) return at + 1;
    _ = std.unicode.utf8Decode(bytes[at .. at + n]) catch return at + 1;
    return at + n;
}

fn previousRune(bytes: []const u8, end: usize) usize {
    var at = end - 1;
    while (at > 0 and (bytes[at] & 0xc0) == 0x80 and end - at < 4) : (at -= 1) {}
    return if (nextRune(bytes, at) == end) at else end - 1;
}

fn cellCount(bytes: []const u8) usize {
    var count: usize = 0;
    var at: usize = 0;
    while (at < bytes.len) : (count += 1) at = nextRune(bytes, at);
    return count;
}

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

test "lineedit: UTF-8 input edits whole scalars at end and in the middle" {
    var mock = console.MockConsole(256){};
    var editor = LineEditor{};
    for ("aöb") |byte| _ = editor.feed(mock.console(), byte);
    try std.testing.expectEqualStrings("aöb", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 4), editor.cursor);

    mock.reset();
    for ("\x1b[D\x1b[D") |byte| _ = editor.feed(mock.console(), byte);
    try std.testing.expectEqual(@as(usize, 1), editor.cursor); // before ö
    try std.testing.expectEqualStrings("\x08\x08", mock.contents());
    mock.reset();
    for ("\x1b[3~") |byte| _ = editor.feed(mock.console(), byte);
    try std.testing.expectEqualStrings("ab", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 1), editor.cursor);
    try std.testing.expectEqualStrings("\x08ab \x08\x08", mock.contents());

    editor.next_line();
    mock.reset();
    for ("aö") |byte| _ = editor.feed(mock.console(), byte);
    _ = editor.feed(mock.console(), 0x08);
    try std.testing.expectEqualStrings("a", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 1), editor.cursor);
    try std.testing.expectEqualStrings("aö\x08\x08a \x08", mock.contents());
}

test "lineedit: UTF-8 staging refuses partial input at the byte bound" {
    var mock = console.MockConsole(512){};
    var editor = LineEditor{};
    for (0..max_line - 1) |_| _ = editor.feed(mock.console(), 'a');
    mock.reset();
    for ("ö") |byte| _ = editor.feed(mock.console(), byte);
    try std.testing.expect(editor.rejected);
    try std.testing.expectEqual(@as(usize, max_line - 1), editor.len);
    try std.testing.expectEqualStrings("\x07", mock.contents());
    _ = editor.feed(mock.console(), 0x08);
    try std.testing.expectEqual(@as(usize, max_line - 2), editor.len);

    editor.next_line();
    mock.reset();
    _ = editor.feed(mock.console(), 0xc3);
    _ = editor.feed(mock.console(), 'x'); // incomplete scalar must not eat x
    try std.testing.expectEqualStrings("x", editor.buffer[0..editor.len]);
    try std.testing.expectEqualStrings("\x07x", mock.contents());
}

test "lineedit: 255 and 256 chars fit exactly and submit" {
    var mock = console.MockConsole(1024){};
    var editor = LineEditor{};
    const line_255 = @as([255]u8, @splat(@as(u8, 'a')));
    for (line_255) |c| try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), c));
    try std.testing.expectEqual(@as(usize, 255), editor.len);
    try std.testing.expect(!editor.rejected);
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
    editor.next_line();

    const line_256 = @as([256]u8, @splat(@as(u8, 'b')));
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
    const line_257 = @as([257]u8, @splat(@as(u8, 'c')));
    for (line_257) |c| try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), c));
    try std.testing.expectEqual(@as(usize, 256), editor.len); // 257th refused
    try std.testing.expect(editor.rejected);
    // The refusal echoed one bell after the 256 echoed chars.
    try std.testing.expectEqualStrings(&@as([256:0]u8, @splat("c"[0])) ++ "\x07", mock.contents());
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

test "lineedit: tab with no completion source bells; stray control bytes are no-ops" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    // Tab with no completer wired: bell, nothing appended.
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), '\t'));
    try std.testing.expectEqual(@as(usize, 0), editor.len);
    try std.testing.expectEqualStrings("\x07", mock.contents());
    mock.reset();
    // A lone ESC and a spurious ESC [ q sequence are ignored (no echo).
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 0x1b));
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 0x01)); // Ctrl-A at empty line: no-op
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 0x1b));
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), '['));
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 'q'));
    try std.testing.expectEqual(@as(usize, 0), editor.len);
    try std.testing.expectEqualStrings("", mock.contents());
}

test "lineedit: cursor movement tracks the logical cursor" {
    var mock = console.MockConsole(128){};
    var editor = LineEditor{};
    for ("abc") |c| _ = editor.feed(mock.console(), c);
    try std.testing.expectEqual(@as(usize, 3), editor.cursor);
    mock.reset();
    // Left (ESC [ D): cursor 2, echo a single backspace.
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'D');
    try std.testing.expectEqual(@as(usize, 2), editor.cursor);
    try std.testing.expectEqualStrings("\x08", mock.contents());
    // Ctrl-A (home): cursor 0, echo two backspaces.
    _ = editor.feed(mock.console(), 0x01);
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
    // Ctrl-E (end): cursor 3 via a redraw (\b*0 + "abc" + \b*(3-3)).
    mock.reset();
    _ = editor.feed(mock.console(), 0x05);
    try std.testing.expectEqual(@as(usize, 3), editor.cursor);
    try std.testing.expectEqualStrings("abc", mock.contents());
    // Right at the end bells.
    mock.reset();
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'C');
    try std.testing.expectEqualStrings("\x07", mock.contents());
}

test "lineedit: mid-line insert shifts and redraws" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    _ = editor.feed(mock.console(), 'a');
    _ = editor.feed(mock.console(), 'c');
    _ = editor.feed(mock.console(), 0x01); // home: cursor 0
    mock.reset();
    // Right once: cursor 1; redraw = "ac" + \b*1 (no leading backspaces).
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'C');
    try std.testing.expectEqual(@as(usize, 1), editor.cursor);
    try std.testing.expectEqualStrings("ac\x08", mock.contents());
    // Insert 'b': buffer "abc", cursor 2; redraw = \b*1 + "abc" + \b*1.
    mock.reset();
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 'b'));
    try std.testing.expectEqualStrings("abc", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 2), editor.cursor);
    try std.testing.expectEqualStrings("\x08abc\x08", mock.contents());
}

test "lineedit: mid-line backspace and forward delete redraw" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    for ("abc") |c| _ = editor.feed(mock.console(), c);
    // Left once (cursor 2), then backspace: delete 'b' -> "ac", cursor 1.
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'D');
    mock.reset();
    _ = editor.feed(mock.console(), 0x08);
    try std.testing.expectEqualStrings("ac", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 1), editor.cursor);
    try std.testing.expectEqualStrings("\x08\x08ac \x08\x08", mock.contents());
    // Home, then Delete (ESC [ 3 ~): delete 'a' -> "c", cursor 0.
    _ = editor.feed(mock.console(), 0x01);
    mock.reset();
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), '3');
    _ = editor.feed(mock.console(), '~');
    try std.testing.expectEqualStrings("c", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
    try std.testing.expectEqualStrings("c \x08\x08", mock.contents());
}

test "lineedit: an unhandled CSI key is swallowed whole, tilde and all" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    for ("ab") |c| _ = editor.feed(mock.console(), c);
    mock.reset();
    // PageUp (ESC [ 5 ~) and F5 (ESC [ 1 5 ~) are not editing keys. The
    // final `~` is a printable byte: swallowing only the prefix inserted a
    // literal '~' into the line.
    for ("\x1b[5~") |c| _ = editor.feed(mock.console(), c);
    for ("\x1b[15~") |c| _ = editor.feed(mock.console(), c);
    // A multi-parameter sequence (ESC [ 1 ; 2 D) is swallowed too.
    for ("\x1b[1;2D") |c| _ = editor.feed(mock.console(), c);
    try std.testing.expectEqualStrings("ab", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 2), editor.cursor);
    try std.testing.expectEqualStrings("", mock.contents());
    // Delete still works after the swallowed sequences (state is clean).
    _ = editor.feed(mock.console(), 0x01); // home
    mock.reset();
    for ("\x1b[3~") |c| _ = editor.feed(mock.console(), c);
    try std.testing.expectEqualStrings("b", editor.buffer[0..editor.len]);
}

test "lineedit: a lone ESC does not eat the next keystroke" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    _ = editor.feed(mock.console(), 0x1b); // ESC alone: no sequence follows
    _ = editor.feed(mock.console(), 'x'); // a real keystroke, not a final
    try std.testing.expectEqualStrings("x", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 1), editor.cursor);
    try std.testing.expectEqualStrings("x", mock.contents());
    // ESC then Enter still submits (the CR reaches the normal path).
    _ = editor.feed(mock.console(), 0x1b);
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\r'));
}

test "lineedit: kill chords truncate toward the cursor" {
    var mock = console.MockConsole(128){};
    var editor = LineEditor{};
    // Ctrl-K at the start of a full line kills everything (spaces clear it).
    for ("hello world") |c| _ = editor.feed(mock.console(), c);
    _ = editor.feed(mock.console(), 0x01); // home: cursor 0
    mock.reset();
    _ = editor.feed(mock.console(), 0x0b);
    try std.testing.expectEqual(@as(usize, 0), editor.len);
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
    try std.testing.expectEqualStrings("           " ++ &@as([11:0]u8, @splat("\x08"[0])), mock.contents());
    // Ctrl-U kills back to the cursor: "world" -> "rld", cursor 0.
    for ("world") |c| _ = editor.feed(mock.console(), c);
    _ = editor.feed(mock.console(), 0x01); // home
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'C'); // right: cursor 1
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'C'); // right: cursor 2
    mock.reset();
    _ = editor.feed(mock.console(), 0x15);
    try std.testing.expectEqualStrings("rld", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
    try std.testing.expectEqualStrings("\x08\x08rld  \x08\x08\x08\x08\x08", mock.contents());
}

test "lineedit: history recall walks up/down and returns to the draft" {
    var mock = console.MockConsole(256){};
    var editor = LineEditor{};
    for ("alpha") |c| _ = editor.feed(mock.console(), c);
    _ = editor.feed(mock.console(), '\n');
    editor.next_line();
    for ("beta") |c| _ = editor.feed(mock.console(), c);
    _ = editor.feed(mock.console(), '\n');
    editor.next_line();
    try std.testing.expectEqual(@as(usize, 2), editor.hist_count);
    mock.reset();
    // Up: recall "beta".
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'A');
    try std.testing.expectEqualStrings("beta", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 4), editor.cursor);
    try std.testing.expectEqualStrings("beta", mock.contents());
    // Up again: recall "alpha" (redraw from the end of "beta").
    mock.reset();
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'A');
    try std.testing.expectEqualStrings("alpha", editor.buffer[0..editor.len]);
    try std.testing.expectEqualStrings("\x08\x08\x08\x08alpha", mock.contents());
    // Down: back to "beta".
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'B');
    try std.testing.expectEqualStrings("beta", editor.buffer[0..editor.len]);
    // Down again: back to the (empty) draft.
    _ = editor.feed(mock.console(), 0x1b);
    _ = editor.feed(mock.console(), '[');
    _ = editor.feed(mock.console(), 'B');
    try std.testing.expectEqual(@as(usize, 0), editor.len);
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
}

test "lineedit: consecutive duplicate submissions are collapsed in history" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    for ("echo") |c| _ = editor.feed(mock.console(), c);
    _ = editor.feed(mock.console(), '\n');
    editor.next_line();
    for ("echo") |c| _ = editor.feed(mock.console(), c);
    _ = editor.feed(mock.console(), '\n');
    editor.next_line();
    try std.testing.expectEqual(@as(usize, 1), editor.hist_count);
}

test "lineedit: history ring never overflows past capacity (card U3 regression)" {
    // Card U3's fuzz found a latent U2 width bug: `@min(hist_count,
    // hist_capacity - 1)` inferred a u4 for the bound (= 15 fits 4 bits),
    // so `keep + 1` overflowed at the 16th distinct entry. Submit more
    // distinct lines than the ring holds; the ring must stay full, never
    // overflow, and every entry stays in bounds.
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    var i: usize = 0;
    while (i < hist_capacity + 8) : (i += 1) {
        var line_buf: [16]u8 = undefined;
        const n = std.fmt.bufPrint(&line_buf, "line{d}", .{i}) catch unreachable;
        for (n) |c| _ = editor.feed(mock.console(), c);
        _ = editor.feed(mock.console(), '\n');
        editor.next_line();
    }
    try std.testing.expectEqual(hist_capacity, editor.hist_count);
    // The newest entry is the last line submitted (line23); the oldest
    // survivor is line8 (24 submitted, 16 kept) — earlier ones fell off.
    try std.testing.expectEqualStrings("line23", editor.history[0][0..editor.hist_len[0]]);
    try std.testing.expectEqualStrings("line8", editor.history[hist_capacity - 1][0..editor.hist_len[hist_capacity - 1]]);
    // Recall walks the whole ring without touching garbage lengths.
    var steps: usize = 0;
    while (steps < hist_capacity) : (steps += 1) {
        _ = editor.feed(mock.console(), 0x1b);
        _ = editor.feed(mock.console(), '[');
        _ = editor.feed(mock.console(), 'A');
    }
    try std.testing.expectEqual(@as(usize, hist_capacity), editor.hist_cursor);
}

fn testComplete(line: []const u8, cursor: usize) ?[]const u8 {
    _ = line;
    _ = cursor;
    return "ple"; // completes "exam" -> "example"
}

test "lineedit: tab completion inserts the unique suffix; ambiguity bells" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{ .completion = testComplete };
    for ("exam") |c| _ = editor.feed(mock.console(), c);
    mock.reset();
    _ = editor.feed(mock.console(), '\t');
    try std.testing.expectEqualStrings("example", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 7), editor.cursor);
    try std.testing.expectEqualStrings("ple", mock.contents());
    // A completer that returns null (ambiguous) bells and inserts nothing.
    editor.completion = null;
    mock.reset();
    _ = editor.feed(mock.console(), '\t');
    try std.testing.expectEqualStrings("\x07", mock.contents());
    try std.testing.expectEqualStrings("example", editor.buffer[0..editor.len]);
}

test "lineedit: ctrl-l clears the screen and requests a repaint" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    for ("hello") |c| _ = editor.feed(mock.console(), c);
    mock.reset();
    try std.testing.expectEqual(LineResult.repaint, editor.feed(mock.console(), 0x0c));
    try std.testing.expectEqualStrings("\x1b[2J\x1b[H", mock.contents());
    // The line is intact for the shell to reprint.
    try std.testing.expectEqualStrings("hello", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 5), editor.cursor);
    // reprint emits the content and repositions to the cursor.
    mock.reset();
    editor.cursor = 2;
    editor.reprint(mock.console());
    try std.testing.expectEqualStrings("hello\x08\x08\x08", mock.contents());
}

fn testCycleCompleter(line: []const u8, cursor: usize, index: usize) ?CompletionMatch {
    var start = cursor;
    while (start > 0 and line[start - 1] != ' ') start -= 1;
    const prefix = line[start..cursor];
    if (std.mem.eql(u8, prefix, "ca")) {
        const candidates = [_][]const u8{ "calc", "cat" };
        return CompletionMatch{
            .replace_start = start,
            .text = candidates[index % candidates.len],
            .match_count = candidates.len,
            .has_trailing_space = false,
        };
    } else if (std.mem.eql(u8, prefix, "un")) {
        return CompletionMatch{
            .replace_start = start,
            .text = "unique",
            .match_count = 1,
            .has_trailing_space = true,
        };
    }
    return null;
}

test "lineedit: completer single match inserts text and trailing space" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{ .completer = testCycleCompleter };
    for ("un") |c| _ = editor.feed(mock.console(), c);
    _ = editor.feed(mock.console(), '\t');
    try std.testing.expectEqualStrings("unique ", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 7), editor.cursor);
    try std.testing.expect(!editor.completing);
}

test "lineedit: completer multi-match cycles candidates on repeated tab" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{ .completer = testCycleCompleter };
    for ("ca") |c| _ = editor.feed(mock.console(), c);
    _ = editor.feed(mock.console(), '\t');
    // First Tab -> "calc"
    try std.testing.expectEqualStrings("calc", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 4), editor.cursor);
    try std.testing.expect(editor.completing);

    // Second Tab -> "cat"
    _ = editor.feed(mock.console(), '\t');
    try std.testing.expectEqualStrings("cat", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 3), editor.cursor);
    try std.testing.expect(editor.completing);

    // Third Tab -> cycles back to "calc"
    _ = editor.feed(mock.console(), '\t');
    try std.testing.expectEqualStrings("calc", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 4), editor.cursor);
    try std.testing.expect(editor.completing);

    // Typing non-tab breaks cycling
    _ = editor.feed(mock.console(), ' ');
    try std.testing.expect(!editor.completing);
    try std.testing.expectEqualStrings("calc ", editor.buffer[0..editor.len]);
}

test "lineedit: completer mid-line preserves tail and shifts correctly" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{ .completer = testCycleCompleter };
    for ("ca world") |c| _ = editor.feed(mock.console(), c);
    // Move cursor left to right after "ca" (cursor = 2)
    editor.cursor = 2;
    _ = editor.feed(mock.console(), '\t');
    try std.testing.expectEqualStrings("calc world", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 4), editor.cursor);

    // Cycle to "cat"
    _ = editor.feed(mock.console(), '\t');
    try std.testing.expectEqualStrings("cat world", editor.buffer[0..editor.len]);
    try std.testing.expectEqual(@as(usize, 3), editor.cursor);
}
