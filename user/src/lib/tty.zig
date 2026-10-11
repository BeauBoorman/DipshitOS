//! VirelaiOS userland terminal library (M45 card SH1 — ADR 0021 D6,
//! issue #1077).
//!
//! One terminal library shared by `SH.BIN` and every front-end so behaviour
//! cannot drift between the serial, window, and remote presentations. It sits
//! directly on the terminal seam (ADR 0020): open `/dev/tty` through the
//! existing file syscalls, attach a front-end through `sys_tty_attach`
//! (slot 67), and read/write raw bytes through the fd.
//!
//! The split is deliberate: the **line editor**, **key decoder**, and
//! **bounded history ring** are pure logic over a small `Output` sink with
//! no syscalls, so the whole interaction surface is host-testable. The
//! `Session` at the bottom is the thin syscall glue (open/attach/read/write/
//! close) and carries no editing policy.
//!
//! The editor echoes a deliberately dumb-terminal protocol (backspace,
//! reprint, trailing-space clear) inherited from the kernel M19 editor
//! (`kernel/src/lineedit.zig`) so the serial console and the framebuffer
//! text layer render it identically. No ANSI is emitted except Ctrl-L's
//! screen clear.

const std = @import("std");
const abi = @import("ui/abi.zig");

/// The terminal device path (ADR 0020 D3).
pub const tty_path = "/dev/tty";
/// M49 SD4 (#1131): ask the front-end for bracketed paste (DECSET 2004).
/// A front-end that does not implement it ignores the sequence; the kernel
/// serial/window presentations swallow it.
pub const paste_enable: []const u8 = "\x1b[?2004h";
/// Fixed line capacity in bytes. `max_line` bytes fit; the next is refused.
pub const max_line: usize = 256;
/// Bounded session history: the most recent N submitted lines (fixed BSS).
pub const hist_capacity: usize = 16;

/// The front-end selectors `sys_tty_attach` accepts (mirrors
/// `kernel/src/terminal.zig` `FrontEnd`; `window`/`net` are reserved until
/// their implementations land — SH6/SH7).
pub const FrontEnd = enum(u64) {
    detach = 0,
    serial = 1,
    window = 2,
    net = 3,
};

/// A byte sink. The editor writes its echo protocol here; the session backs
/// it with the `/dev/tty` fd, and host tests back it with a capture buffer.
pub const Output = struct {
    ctx: ?*anyopaque = null,
    write_fn: *const fn (ctx: ?*anyopaque, bytes: []const u8) void,

    pub fn write(self: Output, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.write_fn(self.ctx, bytes);
    }

    pub fn byte(self: Output, b: u8) void {
        const one = [1]u8{b};
        self.write_fn(self.ctx, &one);
    }
};

/// One decoded keystroke. The decoder turns the raw byte (and its
/// `ESC [ <params> <final>` sequences) into this hardware-free vocabulary.
pub const Key = union(enum) {
    /// A printable byte (including UTF-8 lead/continuation bytes >= 0x80).
    text: u8,
    enter,
    backspace,
    delete,
    left,
    right,
    home,
    end,
    up,
    down,
    ctrl_a,
    ctrl_e,
    ctrl_k,
    ctrl_u,
    ctrl_l,
    ctrl_c,
    ctrl_r,
    tab,
    /// Ctrl-D — the demo uses it as end-of-session.
    eof,
    /// A lone ESC (not the start of a recognized CSI sequence). The byte
    /// that followed the ESC — if any — is available through
    /// `KeyDecoder.takeReplay`; the editor processes it after acting on the
    /// escape (vi mode uses this for insert -> normal, then the replayed
    /// keystroke becomes a normal-mode command).
    escape,
    /// `ESC [ 200 ~` — a bracketed-paste region starts.
    paste_start,
    /// `ESC [ 201 ~` — the bracketed-paste region ends.
    paste_end,
    /// A byte that produced no action (escape-sequence filler, unknown
    /// control codes).
    ignored,
};

/// The `ESC [ <params> <final>` state machine. Special keys arrive as CSI
/// sequences; the editor never echoes the escape bytes — it turns them into
/// editing actions. A sequence whose final is not one we act on is swallowed
/// WHOLE (the tilde of `ESC [ <n> ~` must not reach the line as text).
pub const KeyDecoder = struct {
    /// 0 = normal, 1 = ESC, 2 = ESC [, 3 = collecting parameter bytes.
    esc_state: u8 = 0,
    /// The first numeric parameter (the `3` of Delete's `ESC [ 3 ~`),
    /// saturating so a longer parameter can only fail to match.
    esc_param: u32 = 0,
    /// The byte consumed while resolving a lone ESC (state 1 sees a non-`[`
    /// byte). The editor routes ESC -> action and then decodes this byte so
    /// `ESC x` still types `x`.
    replay: ?u8 = null,

    pub fn reset(self: *KeyDecoder) void {
        self.esc_state = 0;
        self.esc_param = 0;
        self.replay = null;
    }

    /// True while the decoder is mid-escape-sequence. The bracketed-paste
    /// path uses this to swallow the marker bytes without inserting them.
    pub fn inEscape(self: *const KeyDecoder) bool {
        return self.esc_state != 0;
    }

    /// Consume the byte held back after a lone ESC, if any.
    pub fn takeReplay(self: *KeyDecoder) ?u8 {
        const r = self.replay;
        self.replay = null;
        return r;
    }

    pub fn feed(self: *KeyDecoder, byte: u8) Key {
        switch (self.esc_state) {
            0 => {},
            1 => {
                self.esc_state = 0;
                if (byte == '[') {
                    self.esc_state = 2;
                    return .ignored;
                }
                // A lone ESC followed by anything else: report the escape
                // and hold the byte back so the editor can process it next
                // (vi insert -> normal then a command; emacs types it).
                self.replay = byte;
                return .escape;
            },
            2 => {
                self.esc_state = 0;
                switch (byte) {
                    'A' => return .up,
                    'B' => return .down,
                    'C' => return .right,
                    'D' => return .left,
                    'H' => return .home,
                    'F' => return .end,
                    '0'...'9' => {
                        self.esc_param = byte - '0';
                        self.esc_state = 3;
                        return .ignored;
                    },
                    else => return .ignored,
                }
            },
            3 => {
                if (byte >= '0' and byte <= '9') {
                    const scaled = @mulWithOverflow(self.esc_param, 10);
                    const added = @addWithOverflow(scaled[0], byte - '0');
                    self.esc_param = if (scaled[1] == 1 or added[1] == 1) 255 else added[0];
                    return .ignored;
                }
                if (byte >= 0x3a and byte <= 0x3f) return .ignored; // ';' and friends
                self.esc_state = 0;
                if (byte == '~') {
                    if (self.esc_param == 3) return .delete;
                    if (self.esc_param == 200) return .paste_start;
                    if (self.esc_param == 201) return .paste_end;
                }
                return .ignored;
            },
            else => {},
        }
        if (byte == 0x1b) {
            self.esc_state = 1;
            return .ignored;
        }
        if (byte == '\r' or byte == '\n') return .enter;
        if (byte == 0x08 or byte == 0x7f) return .backspace;
        if (byte == 0x03) return .ctrl_c;
        if (byte == 0x01) return .ctrl_a;
        if (byte == 0x05) return .ctrl_e;
        if (byte == 0x0b) return .ctrl_k;
        if (byte == 0x15) return .ctrl_u;
        if (byte == 0x0c) return .ctrl_l;
        if (byte == 0x12) return .ctrl_r;
        if (byte == 0x04) return .eof;
        if (byte == '\t') return .tab;
        if (byte >= 0x20 and byte != 0x7f) return .{ .text = byte };
        // Other control bytes are ignored: not echoed, not appended.
        return .ignored;
    }
};

pub const LineResult = enum {
    /// Byte consumed; the line is still being edited.
    none,
    /// A complete line is in `buffer[0..len]` (terminated by CR or LF).
    submitted,
    /// A trailing `\` continued the line (M49 SD4): the backslash was
    /// removed, the cursor continues after a `> ` continuation prompt, and
    /// the logical line keeps accumulating (POSIX backslash-newline join).
    continued,
    /// Ctrl-C cleared the line; the buffer is empty again.
    cancelled,
    /// Ctrl-L cleared the screen; the caller reprints the prompt and calls
    /// `reprint` to restore the line.
    repaint,
    /// Ctrl-D — the caller should end the session.
    eof,
};

/// The editor's keymap (M49 SD4). Emacs is the default; `set -o vi` in the
/// shell switches to the bounded vi map (insert/normal states).
pub const Mode = enum {
    emacs,
    vi,
};

/// The vi state machine (only consulted when `mode == .vi`).
pub const ViState = enum {
    insert,
    normal,
};

/// One Tab-completion result from an injected completer. Mirrors the M19
/// kernel shape (`kernel/src/lineedit.zig`).
pub const CompletionMatch = struct {
    /// Where in the line the matched token starts.
    replace_start: usize,
    /// The replacement text (a long-lived slice owned by the completer).
    text: []const u8,
    /// Total candidates for this prefix (drives cycling on repeated Tab).
    match_count: usize = 1,
    /// Append a trailing space on a unique match.
    has_trailing_space: bool = false,
};

pub const CompleterFn = *const fn (line: []const u8, cursor: usize, index: usize) ?CompletionMatch;

/// A bounded, allocation-free line editor with session history. Feed it raw
/// bytes (or decoded keys) one at a time; it echoes editing to `out` and
/// reports when a line is ready. Input beyond `max_line` is refused (bell +
/// `rejected`), never silently truncated mid-word.
pub const LineEditor = struct {
    buffer: [max_line]u8 = undefined,
    len: usize = 0,
    /// Insertion point (0..len).
    cursor: usize = 0,
    /// True when at least one byte was refused because the line was full.
    rejected: bool = false,
    /// Set when the last submitted line ended in CR; the LF half of a CRLF
    /// pair is swallowed so one Enter produces one line.
    submitted_cr: bool = false,

    // Bounded session history (index 0 = most recent).
    history: [hist_capacity][max_line]u8 = undefined,
    hist_len: [hist_capacity]usize = undefined,
    hist_count: usize = 0,
    /// Recall position: 0 = editing a fresh line; 1..=hist_count = the
    /// recalled entry (1 = newest). `hist_draft` saves the pre-recall line
    /// so Down past the newest returns to it.
    hist_cursor: usize = 0,
    hist_draft: [max_line]u8 = undefined,
    hist_draft_len: usize = 0,

    decoder: KeyDecoder = .{},

    // Tab completion (SH3). The completer is injected by the shell.
    completer: ?CompleterFn = null,
    completing: bool = false,
    complete_replace_start: usize = 0,
    complete_orig_token: [max_line]u8 = undefined,
    complete_orig_token_len: usize = 0,
    complete_cur_token_len: usize = 0,
    complete_index: usize = 0,
    complete_match_count: usize = 0,

    // Reverse-i-search (SH3): search backward through the history ring.
    searching: bool = false,
    search_query: [64]u8 = undefined,
    search_query_len: usize = 0,
    search_draft: [max_line]u8 = undefined,
    search_draft_len: usize = 0,
    search_draft_cursor: usize = 0,

    // M49 SD4 (#1131): editing ergonomics.
    /// `emacs` (default) or `vi` (bounded: insert/normal, h l 0 $ x i a A I
    /// k j, dd). Switched from the shell via `set -o vi` / `set +o vi`.
    mode: Mode = .emacs,
    vi_state: ViState = .insert,
    /// The `d` half of vi's `dd` (cleared by any other normal-mode key).
    vi_pending_d: bool = false,
    /// True inside an `ESC [ 200 ~` ... `ESC [ 201 ~` bracketed paste.
    /// Pasted bytes insert literally; a pasted newline submits the line.
    pasting: bool = false,
    /// Emit `ESC [ 3 J` on Ctrl-L to clear the front-end's scrollback too
    /// (the window front-end has a bounded scrollback grid; the serial
    /// presentation does not, so it stays off there).
    clear_scrollback: bool = false,
    /// Round-robin count of pasted bytes (diagnostic; `paste` state).
    pasted: usize = 0,

    /// Full reset: empty line, clear flags, and any in-progress recall.
    pub fn reset(self: *LineEditor) void {
        self.len = 0;
        self.cursor = 0;
        self.rejected = false;
        self.submitted_cr = false;
        self.decoder.reset();
        self.hist_cursor = 0;
        self.completing = false;
        self.searching = false;
        self.vi_state = .insert;
        self.vi_pending_d = false;
    }

    /// Prepare for the next line after a submit. Keeps the CRLF swallow
    /// window open and keeps the history (it is session-scoped).
    pub fn next_line(self: *LineEditor) void {
        self.len = 0;
        self.cursor = 0;
        self.rejected = false;
        self.decoder.reset();
        self.hist_cursor = 0;
        self.completing = false;
        self.searching = false;
        self.vi_state = .insert;
        self.vi_pending_d = false;
    }

    /// Feed one raw byte. Echoes editing onto `out` as it goes. In
    /// reverse-i-search mode every byte feeds the query matcher instead.
    pub fn feed(self: *LineEditor, out: Output, byte: u8) LineResult {
        if (self.searching) return self.search_handle(out, byte);
        // The LF half of a CRLF pair is swallowed (one Enter = one line).
        if (self.submitted_cr and byte == '\n') {
            self.submitted_cr = false;
            return .none;
        }
        self.submitted_cr = false;
        // M49 SD4: inside a bracketed paste the byte stream is literal.
        if (self.pasting) return self.pasteByte(out, byte);
        if (byte == 0x12) { // Ctrl+R
            self.search_enter(out);
            return .none;
        }
        // Any non-Tab byte ends a completion cycle (M19 semantics).
        if (byte != '\t') self.completing = false;
        var b = byte;
        while (true) {
            const key = self.decoder.feed(b);
            const result = self.feedKey(out, key);
            if (result == .submitted) {
                self.submitted_cr = (b == '\r');
                return result;
            }
            // A lone ESC: the decoder holds the byte that followed it back;
            // process it next (the escape action may have changed the mode).
            if (key == .escape) {
                if (self.decoder.takeReplay()) |replay| {
                    b = replay;
                    continue;
                }
            }
            return result;
        }
    }

    /// Bracketed paste (M49 SD4): bytes insert literally and a pasted
    /// newline submits — so pasting a script runs it line by line, exactly
    /// like typing it. The decoder still consumes CSI filler so the
    /// `ESC [ 201 ~` terminator is found even when the paste contains
    /// escape bytes.
    fn pasteByte(self: *LineEditor, out: Output, byte: u8) LineResult {
        const key = self.decoder.feed(byte);
        if (key == .paste_end or key == .paste_start) {
            self.pasting = (key == .paste_start);
            return .none;
        }
        if (key == .escape) {
            if (self.decoder.takeReplay()) |replay| return self.insert(out, replay);
            return .none;
        }
        if (self.decoder.inEscape()) return .none; // marker/CSI filler bytes
        if (byte == '\r' or byte == '\n') {
            out.write("\r\n");
            self.remember_line();
            self.submitted_cr = (byte == '\r');
            return .submitted;
        }
        self.pasted += 1;
        return self.insert(out, byte);
    }

    /// Apply one already-decoded key.
    pub fn feedKey(self: *LineEditor, out: Output, key: Key) LineResult {
        // M49 SD4: bracketed paste state is keyed at this level so both the
        // byte path and direct `feedKey` callers share it.
        switch (key) {
            .paste_start => {
                self.pasting = true;
                return .none;
            },
            .paste_end => {
                self.pasting = false;
                return .none;
            },
            else => {},
        }
        // M49 SD4: the bounded vi normal state owns every key while active.
        if (self.mode == .vi and self.vi_state == .normal) return self.feedViNormal(out, key);
        switch (key) {
            .ignored => return .none,
            .text => |b| return self.insert(out, b),
            .enter => {
                if (self.continuesLine()) return self.continueLine(out);
                out.write("\r\n");
                self.remember_line();
                return .submitted;
            },
            .backspace => return self.backspace(out),
            .delete => return self.delete_forward(out),
            .left => return self.cursor_left(out),
            .right => return self.cursor_right(out),
            .home, .ctrl_a => return self.cursor_home(out),
            .end, .ctrl_e => return self.cursor_end(out),
            .up => return self.recall_older(out),
            .down => return self.recall_newer(out),
            .ctrl_k => return self.kill_to_end(out),
            .ctrl_u => return self.kill_to_start(out),
            .ctrl_l => {
                if (self.clear_scrollback) {
                    out.write("\x1b[2J\x1b[3J\x1b[H");
                } else {
                    out.write("\x1b[2J\x1b[H");
                }
                return .repaint;
            },
            .ctrl_c => {
                out.write("^C\r\n");
                self.reset();
                return .cancelled;
            },
            .tab => return self.complete(out),
            .ctrl_r => {
                self.search_enter(out);
                return .none;
            },
            .eof => return .eof,
            .escape => {
                // M49 SD4: in vi mode, ESC enters normal (the held-back
                // byte, if any, is replayed by `feed` and becomes the first
                // normal-mode command). Emacs ignores it.
                if (self.mode == .vi) self.vi_state = .normal;
                return .none;
            },
            .paste_start, .paste_end => return .none, // handled above
        }
    }

    /// M49 SD4: the bounded vi normal map. Motions `h l 0 $`, `x` delete,
    /// `i a A I` re-enter insert, `k j` history, `dd` clears the line.
    /// Everything else bells.
    fn feedViNormal(self: *LineEditor, out: Output, key: Key) LineResult {
        const was_d = self.vi_pending_d;
        self.vi_pending_d = false;
        switch (key) {
            .ignored, .escape => return .none,
            .text => |b| {
                switch (b) {
                    'h' => return self.cursor_left(out),
                    'l' => return self.cursor_right(out),
                    '0' => return self.cursor_home(out),
                    '$' => return self.cursor_end(out),
                    'x' => return self.delete_forward(out),
                    'i' => {
                        self.vi_state = .insert;
                        return .none;
                    },
                    'a' => {
                        _ = self.cursor_right(out);
                        self.vi_state = .insert;
                        return .none;
                    },
                    'A' => {
                        _ = self.cursor_end(out);
                        self.vi_state = .insert;
                        return .none;
                    },
                    'I' => {
                        _ = self.cursor_home(out);
                        self.vi_state = .insert;
                        return .none;
                    },
                    'k' => return self.recall_older(out),
                    'j' => return self.recall_newer(out),
                    'd' => {
                        if (was_d) {
                            const old_len = self.len;
                            const old_cursor = self.cursor;
                            self.len = 0;
                            self.cursor = 0;
                            self.redraw(out, old_len, old_cursor);
                            return .none;
                        }
                        self.vi_pending_d = true;
                        return .none;
                    },
                    else => {
                        out.byte(0x07);
                        return .none;
                    },
                }
            },
            .enter => {
                if (self.continuesLine()) return self.continueLine(out);
                out.write("\r\n");
                self.remember_line();
                self.vi_state = .insert;
                return .submitted;
            },
            .backspace, .left => return self.cursor_left(out),
            .right => return self.cursor_right(out),
            .home => return self.cursor_home(out),
            .end => return self.cursor_end(out),
            .up => return self.recall_older(out),
            .down => return self.recall_newer(out),
            .tab => return self.complete(out),
            .ctrl_c => {
                out.write("^C\r\n");
                self.reset();
                return .cancelled;
            },
            .ctrl_l => {
                if (self.clear_scrollback) {
                    out.write("\x1b[2J\x1b[3J\x1b[H");
                } else {
                    out.write("\x1b[2J\x1b[H");
                }
                return .repaint;
            },
            .eof => return .eof,
            else => {
                out.byte(0x07);
                return .none;
            },
        }
    }

    /// M49 SD4: true when the line ends in an odd run of backslashes (a
    /// POSIX backslash-newline continuation).
    fn continuesLine(self: *const LineEditor) bool {
        var n: usize = 0;
        while (n < self.len and self.buffer[self.len - 1 - n] == '\\') n += 1;
        return (n & 1) == 1;
    }

    /// M49 SD4: drop the continuation backslash (POSIX removes the escaped
    /// newline) and open a `> ` continuation line. The logical line keeps
    /// accumulating in the same buffer.
    fn continueLine(self: *LineEditor, out: Output) LineResult {
        self.len -= 1;
        if (self.cursor > self.len) self.cursor = self.len;
        out.write("\r\n> ");
        return .continued;
    }

    /// Reprint the current line after a screen clear (Ctrl-L): the caller
    /// prints the prompt, then this emits the content and repositions the
    /// cursor (the editor does not own the prompt).
    pub fn reprint(self: *const LineEditor, out: Output) void {
        out.write(self.buffer[0..self.len]);
        var i: usize = self.cursor;
        while (i < self.len) : (i += 1) out.byte(0x08);
    }

    /// The current line's bytes.
    pub fn line(self: *const LineEditor) []const u8 {
        return self.buffer[0..self.len];
    }

    // -- editing primitives ------------------------------------------------

    fn backspace(self: *LineEditor, out: Output) LineResult {
        if (self.len == 0 or self.cursor == 0) {
            out.byte(0x07); // nothing to delete: bell
            return .none;
        }
        if (self.cursor == self.len) {
            // Fast path (byte seam): classic erase pair, no redraw.
            self.len -= 1;
            self.cursor -= 1;
            out.write("\x08 \x08");
            return .none;
        }
        const old_len = self.len;
        const old_cursor = self.cursor;
        var i = self.cursor;
        while (i < self.len) : (i += 1) self.buffer[i - 1] = self.buffer[i];
        self.len -= 1;
        self.cursor -= 1;
        self.redraw(out, old_len, old_cursor);
        return .none;
    }

    fn delete_forward(self: *LineEditor, out: Output) LineResult {
        if (self.cursor >= self.len) {
            out.byte(0x07);
            return .none;
        }
        const old_len = self.len;
        const old_cursor = self.cursor;
        var i = self.cursor;
        while (i + 1 < self.len) : (i += 1) self.buffer[i] = self.buffer[i + 1];
        self.len -= 1;
        self.redraw(out, old_len, old_cursor);
        return .none;
    }

    fn insert(self: *LineEditor, out: Output, byte: u8) LineResult {
        if (self.len >= max_line) {
            self.rejected = true;
            out.byte(0x07);
            return .none;
        }
        if (self.cursor == self.len) {
            // Fast path: append + echo, no redraw.
            self.buffer[self.len] = byte;
            self.len += 1;
            self.cursor += 1;
            out.byte(byte);
            return .none;
        }
        const old_len = self.len;
        const old_cursor = self.cursor;
        var i = self.len;
        while (i > self.cursor) : (i -= 1) self.buffer[i] = self.buffer[i - 1];
        self.buffer[self.cursor] = byte;
        self.len += 1;
        self.cursor += 1;
        self.redraw(out, old_len, old_cursor);
        return .none;
    }

    fn cursor_left(self: *LineEditor, out: Output) LineResult {
        if (self.cursor > 0) {
            self.cursor -= 1;
            out.byte(0x08);
        } else {
            out.byte(0x07);
        }
        return .none;
    }

    fn cursor_right(self: *LineEditor, out: Output) LineResult {
        if (self.cursor < self.len) {
            self.cursor += 1;
            self.redraw(out, self.len, self.cursor - 1);
        } else {
            out.byte(0x07);
        }
        return .none;
    }

    fn cursor_home(self: *LineEditor, out: Output) LineResult {
        if (self.cursor == 0) return .none;
        var i = self.cursor;
        while (i > 0) : (i -= 1) out.byte(0x08);
        self.cursor = 0;
        return .none;
    }

    fn cursor_end(self: *LineEditor, out: Output) LineResult {
        if (self.cursor == self.len) return .none;
        const old_cursor = self.cursor;
        self.cursor = self.len;
        self.redraw(out, self.len, old_cursor);
        return .none;
    }

    fn kill_to_end(self: *LineEditor, out: Output) LineResult {
        if (self.cursor >= self.len) return .none;
        const old_len = self.len;
        const old_cursor = self.cursor;
        self.len = self.cursor;
        self.redraw(out, old_len, old_cursor);
        return .none;
    }

    fn kill_to_start(self: *LineEditor, out: Output) LineResult {
        if (self.cursor == 0) return .none;
        const old_len = self.len;
        const old_cursor = self.cursor;
        const tail = self.len - self.cursor;
        var i: usize = 0;
        while (i < tail) : (i += 1) self.buffer[i] = self.buffer[self.cursor + i];
        self.len = tail;
        self.cursor = 0;
        self.redraw(out, old_len, old_cursor);
        return .none;
    }

    // -- tab completion (SH3) ----------------------------------------------

    fn complete(self: *LineEditor, out: Output) LineResult {
        const completer_fn = self.completer orelse {
            out.byte(0x07); // no completion source wired
            return .none;
        };
        return self.complete_cycle(out, completer_fn);
    }

    fn complete_cycle(self: *LineEditor, out: Output, completer_fn: CompleterFn) LineResult {
        const old_len = self.len;
        const old_cursor = self.cursor;

        if (!self.completing) {
            const m = completer_fn(self.buffer[0..self.len], self.cursor, 0) orelse {
                out.byte(0x07);
                return .none;
            };
            if (m.match_count == 0 or m.replace_start > self.cursor) {
                out.byte(0x07);
                return .none;
            }

            const orig_token = self.buffer[m.replace_start..self.cursor];
            if (orig_token.len > max_line) {
                out.byte(0x07);
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
                out.byte(0x07);
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
            self.redraw(out, old_len, old_cursor);

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
            // M49 SD4: wrapping the cycle lists the candidates (the richer
            // completion surface) and repaints the prompt/line after.
            const wrapped = self.complete_index == 0;

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
                out.byte(0x07);
                self.completing = false;
                return .none;
            };

            const old_token_end = rep_start + cur_token_len;
            const new_token_end = rep_start + m.text.len;
            if (new_token_end + tail_len > max_line) {
                out.byte(0x07);
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
            self.redraw(out, old_len, old_cursor);
            if (wrapped) return self.listMatches(out, completer_fn, temp_buf[0..temp_len], temp_cursor);
            return .none;
        }
    }

    /// M49 SD4: print every candidate for the original token (bounded to 3
    /// columns of 24) and ask the caller to repaint prompt + line. Called
    /// when a Tab cycle wraps, so the user sees what is on offer.
    fn listMatches(
        self: *LineEditor,
        out: Output,
        completer_fn: CompleterFn,
        text: []const u8,
        cursor: usize,
    ) LineResult {
        const count = @min(24, self.complete_match_count);
        out.write("\r\n");
        var i: usize = 0;
        var col: usize = 0;
        while (i < count) : (i += 1) {
            const m = completer_fn(text, cursor, i) orelse continue;
            if (col > 0 and col + m.text.len > 56) {
                out.write("\r\n");
                col = 0;
            }
            out.write(m.text);
            col += m.text.len;
            if (i + 1 < count) {
                out.write("  ");
                col += 2;
            }
        }
        out.write("\r\n");
        return .repaint;
    }

    // -- reverse-i-search (SH3) --------------------------------------------

    /// Search the history ring newest-first for a line containing `query`.
    fn search_match(self: *const LineEditor, query: []const u8) ?[]const u8 {
        if (query.len == 0) return null;
        var hi: usize = 0;
        while (hi < self.hist_count) : (hi += 1) {
            const entry = self.history[hi][0..self.hist_len[hi]];
            if (std.mem.indexOf(u8, entry, query) != null) return entry;
        }
        return null;
    }

    /// Enter reverse-i-search, saving the draft line for cancel.
    fn search_enter(self: *LineEditor, out: Output) void {
        @memcpy(self.search_draft[0..self.len], self.buffer[0..self.len]);
        self.search_draft_len = self.len;
        self.search_draft_cursor = self.cursor;
        self.searching = true;
        self.search_query_len = 0;
        self.search_redraw(out);
    }

    fn search_redraw(self: *LineEditor, out: Output) void {
        out.write("\r\n(reverse-i-search)`");
        if (self.search_query_len > 0) {
            out.write(self.search_query[0..self.search_query_len]);
        } else {
            out.write("_");
        }
        out.write("`: ");
        const query = self.search_query[0..self.search_query_len];
        if (self.search_match(query)) |match| {
            out.write(match);
            self.len = @min(match.len, max_line);
            @memcpy(self.buffer[0..self.len], match[0..self.len]);
            self.cursor = self.len;
        } else {
            out.write("(no match)");
        }
    }

    fn search_handle(self: *LineEditor, out: Output, byte: u8) LineResult {
        switch (byte) {
            0x1b => { // Esc: cancel, restore the draft
                self.search_exit(out, false);
                return .repaint;
            },
            0x0d, 0x0a => { // Enter: accept the current match
                self.search_exit(out, true);
                return .repaint;
            },
            0x7f, 0x08 => { // Backspace: remove the last query byte
                if (self.search_query_len > 0) {
                    self.search_query_len -= 1;
                    self.search_redraw(out);
                }
                return .none;
            },
            0x03 => { // Ctrl-C: cancel
                self.search_exit(out, false);
                return .repaint;
            },
            0x0c => return .none, // Ctrl-L: ignore inside search
            else => {
                if (byte >= 0x20 and byte != 0x7f and self.search_query_len < self.search_query.len) {
                    self.search_query[self.search_query_len] = byte;
                    self.search_query_len += 1;
                    self.search_redraw(out);
                }
                return .none;
            },
        }
    }

    fn search_exit(self: *LineEditor, out: Output, accept: bool) void {
        self.searching = false;
        if (!accept) {
            @memcpy(self.buffer[0..self.search_draft_len], self.search_draft[0..self.search_draft_len]);
            self.len = self.search_draft_len;
            self.cursor = self.search_draft_cursor;
        }
        out.write("\r\n");
    }

    // -- history -----------------------------------------------------------

    /// Store the just-submitted line (non-empty; consecutive duplicates are
    /// collapsed). The oldest entry falls off when the ring is full.
    fn remember_line(self: *LineEditor) void {
        const entry = self.buffer[0..self.len];
        if (entry.len == 0) return;
        if (self.hist_count > 0 and std.mem.eql(u8, entry, self.history[0][0..self.hist_len[0]])) return;
        const keep: usize = @min(self.hist_count, hist_capacity - 1);
        var i = keep;
        while (i > 0) : (i -= 1) {
            @memcpy(self.history[i][0..self.hist_len[i - 1]], self.history[i - 1][0..self.hist_len[i - 1]]);
            self.hist_len[i] = self.hist_len[i - 1];
        }
        @memcpy(self.history[0][0..entry.len], entry);
        self.hist_len[0] = entry.len;
        self.hist_count = keep + 1;
    }

    fn load_line(self: *LineEditor, out: Output, entry: []const u8) void {
        const old_cursor = self.cursor;
        const old_len = self.len;
        @memcpy(self.buffer[0..entry.len], entry);
        self.len = entry.len;
        self.cursor = entry.len;
        self.redraw(out, old_len, old_cursor);
    }

    fn recall_older(self: *LineEditor, out: Output) LineResult {
        if (self.hist_count == 0 or self.hist_cursor >= self.hist_count) {
            out.byte(0x07);
            return .none;
        }
        if (self.hist_cursor == 0) {
            @memcpy(self.hist_draft[0..self.len], self.buffer[0..self.len]);
            self.hist_draft_len = self.len;
        }
        self.hist_cursor += 1;
        self.load_line(out, self.history[self.hist_cursor - 1][0..self.hist_len[self.hist_cursor - 1]]);
        return .none;
    }

    fn recall_newer(self: *LineEditor, out: Output) LineResult {
        if (self.hist_cursor == 0) {
            out.byte(0x07);
            return .none;
        }
        self.hist_cursor -= 1;
        if (self.hist_cursor == 0) {
            self.load_line(out, self.hist_draft[0..self.hist_draft_len]);
        } else {
            self.load_line(out, self.history[self.hist_cursor - 1][0..self.hist_len[self.hist_cursor - 1]]);
        }
        return .none;
    }

    // -- dumb-terminal redraw ----------------------------------------------

    /// Redraw the line content. The terminal cursor is at prompt_len +
    /// `old_cursor` on entry and prompt_len + `self.cursor` on exit. Emits
    /// only `\b`, the reprint, and trailing spaces. Approximate across a
    /// wrapped line (the documented honest bound).
    fn redraw(self: *LineEditor, out: Output, old_len: usize, old_cursor: usize) void {
        var i: usize = 0;
        while (i < old_cursor) : (i += 1) out.byte(0x08);
        out.write(self.buffer[0..self.len]);
        i = self.len;
        while (i < old_len) : (i += 1) out.byte(' ');
        const end_col = @max(self.len, old_len);
        i = self.cursor;
        while (i < end_col) : (i += 1) out.byte(0x08);
    }
};

// ---------------------------------------------------------------------------
// The syscall glue: one `/dev/tty` session (open / attach / raw bytes).
// ---------------------------------------------------------------------------

/// A `/dev/tty` session. Thin by design — the editing policy lives above.
pub const Session = struct {
    handle: u32 = 0,
    valid: bool = false,
    attached: bool = false,

    /// Open the controlling terminal (`/dev/tty`). Null when the open fails.
    pub fn open() ?Session {
        const r = abi.file_open(tty_path, abi.MODE_READ | abi.MODE_WRITE);
        if (r < 0) return null;
        return .{ .handle = @intCast(r), .valid = true };
    }

    /// Attach a front-end (`sys_tty_attach`, slot 67). `detach` is the
    /// explicit selector 0; any other selector is an attach.
    pub fn attach(self: *Session, front_end: FrontEnd) bool {
        const ok = abi.tty_attach(@backingInt(front_end)) == 0;
        if (ok and front_end != .detach) self.attached = true;
        if (ok and front_end == .detach) self.attached = false;
        return ok;
    }

    pub fn detach(self: *Session) void {
        _ = abi.tty_attach(0);
        self.attached = false;
    }

    /// #1082 (ADR 0020 Amendment A): attach the caller's OWN `.user` window
    /// as this terminal's window front-end (selector 2). The kernel renders
    /// the terminal's grid into that window; the process draws no pixels.
    pub fn attachWindow(self: *Session, window_id: u8) bool {
        const ok = abi.tty_attach_window(window_id) == 0;
        if (ok) self.attached = true;
        return ok;
    }

    /// #1083 (ADR 0020 Amendment B): host this terminal's net front-end —
    /// enter LISTEN on `port` through the kernel's single bounded TCP seam
    /// (selector 3). A remote client drives the shell from there.
    pub fn attachNet(self: *Session, port: u16) bool {
        const ok = abi.tty_attach_net(port) == 0;
        if (ok) self.attached = true;
        return ok;
    }

    /// M50 TS4 (#1138, ADR 0024 D6): host the net front-end with the chosen
    /// auth posture — `scheme` 0 = open (the explicit insecure mode),
    /// 1 = hmac-sha256, 2 = ed25519. The credential never rides argv; the
    /// caller reads it from the TS5 store and answers via slot 71
    /// (`lib/netauth.zig`). `allow_ip` is an optional source-IP allowlist
    /// (big-endian u32; 0 = any).
    pub fn attachNetMode(self: *Session, port: u16, scheme: u64, allow_ip: u32) bool {
        const ok = abi.tty_attach_net_mode(port, scheme, allow_ip) == 0;
        if (ok) self.attached = true;
        return ok;
    }

    /// Non-blocking read of the terminal input queue: >0 bytes, 0 when
    /// nothing is pending, <0 on error.
    pub fn read(self: *Session, buf: []u8) i64 {
        if (!self.valid) return -1;
        return abi.file_read(self.handle, buf);
    }

    /// Write raw bytes to the terminal output ring.
    pub fn write(self: *Session, bytes: []const u8) void {
        if (!self.valid) return;
        _ = abi.file_write(self.handle, bytes);
    }

    pub fn close(self: *Session) void {
        if (self.valid) abi.file_close(self.handle);
        self.valid = false;
        self.attached = false;
    }

    /// An `Output` sink backed by this session's terminal fd. The returned
    /// sink borrows `self`, so the session must outlive it.
    pub fn output(self: *Session) Output {
        return .{ .ctx = self, .write_fn = sessionWrite };
    }
};

fn sessionWrite(ctx: ?*anyopaque, bytes: []const u8) void {
    const session: *Session = @ptrCast(@alignCast(ctx.?));
    session.write(bytes);
}

// ---------------------------------------------------------------------------
// Host tests (pure; no hardware, no syscalls executed)
// ---------------------------------------------------------------------------

const Capture = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    fn sink(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx.?));
        const n = @min(bytes.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], bytes[0..n]);
        self.len += n;
    }

    fn out(self: *Capture) Output {
        return .{ .ctx = self, .write_fn = sink };
    }

    fn contents(self: *const Capture) []const u8 {
        return self.buf[0..self.len];
    }

    fn reset(self: *Capture) void {
        self.len = 0;
    }
};

test "tty: ABI constants mirror the terminal seam (drift guard)" {
    try std.testing.expectEqualStrings("/dev/tty", tty_path);
    try std.testing.expectEqual(@as(u64, 0), @backingInt(FrontEnd.detach));
    try std.testing.expectEqual(@as(u64, 1), @backingInt(FrontEnd.serial));
    try std.testing.expectEqual(@as(u64, 2), @backingInt(FrontEnd.window));
    try std.testing.expectEqual(@as(u64, 3), @backingInt(FrontEnd.net));
    try std.testing.expectEqual(@as(u64, 67), abi.sys_tty_attach_num);
}

test "tty: KeyDecoder turns CSI sequences into keys and swallows the rest" {
    var d = KeyDecoder{};
    try std.testing.expectEqual(Key.ignored, d.feed(0x1b));
    try std.testing.expectEqual(Key.ignored, d.feed('['));
    try std.testing.expectEqual(Key.up, d.feed('A'));
    // Re-init for a clean sequence walk per key.
    d.reset();
    _ = d.feed(0x1b);
    _ = d.feed('[');
    try std.testing.expectEqual(Key.down, d.feed('B'));
    d.reset();
    _ = d.feed(0x1b);
    _ = d.feed('[');
    try std.testing.expectEqual(Key.right, d.feed('C'));
    d.reset();
    _ = d.feed(0x1b);
    _ = d.feed('[');
    try std.testing.expectEqual(Key.left, d.feed('D'));
    d.reset();
    _ = d.feed(0x1b);
    _ = d.feed('[');
    try std.testing.expectEqual(Key.home, d.feed('H'));
    d.reset();
    _ = d.feed(0x1b);
    _ = d.feed('[');
    try std.testing.expectEqual(Key.end, d.feed('F'));
    // Delete: ESC [ 3 ~.
    d.reset();
    _ = d.feed(0x1b);
    _ = d.feed('[');
    _ = d.feed('3');
    try std.testing.expectEqual(Key.delete, d.feed('~'));
    // An unhandled CSI key is swallowed whole (no stray '~').
    d.reset();
    for ("\x1b[15~") |c| try std.testing.expectEqual(Key.ignored, d.feed(c));
    // A multi-parameter sequence is swallowed too.
    d.reset();
    for ("\x1b[1;2D") |c| try std.testing.expectEqual(Key.ignored, d.feed(c));
}

test "tty: KeyDecoder handles printable, control, and lone-ESC bytes" {
    var d = KeyDecoder{};
    try std.testing.expectEqual(@as(u8, 'a'), d.feed('a').text);
    try std.testing.expectEqual(@as(u8, 0xc3), d.feed(0xc3).text); // UTF-8 lead
    try std.testing.expectEqual(Key.enter, d.feed('\r'));
    try std.testing.expectEqual(Key.enter, d.feed('\n'));
    try std.testing.expectEqual(Key.backspace, d.feed(0x08));
    try std.testing.expectEqual(Key.backspace, d.feed(0x7f));
    try std.testing.expectEqual(Key.ctrl_c, d.feed(0x03));
    try std.testing.expectEqual(Key.ctrl_a, d.feed(0x01));
    try std.testing.expectEqual(Key.ctrl_e, d.feed(0x05));
    try std.testing.expectEqual(Key.ctrl_k, d.feed(0x0b));
    try std.testing.expectEqual(Key.ctrl_u, d.feed(0x15));
    try std.testing.expectEqual(Key.ctrl_l, d.feed(0x0c));
    try std.testing.expectEqual(Key.eof, d.feed(0x04));
    try std.testing.expectEqual(Key.tab, d.feed('\t'));
    // A lone ESC is reported (M49 SD4: vi uses it), and it does not eat the
    // next keystroke — the byte is held back for the editor to replay.
    try std.testing.expectEqual(Key.ignored, d.feed(0x1b));
    try std.testing.expectEqual(Key.escape, d.feed('x'));
    try std.testing.expectEqual(@as(?u8, 'x'), d.takeReplay());
    try std.testing.expectEqual(@as(?u8, null), d.takeReplay());
}

test "tty: insert and backspace echo through the byte seam" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    _ = ed.feed(out, 'a');
    _ = ed.feed(out, 'b');
    try std.testing.expectEqualStrings("ab", ed.line());
    try std.testing.expectEqualStrings("ab", cap.contents());
    _ = ed.feed(out, 0x08);
    try std.testing.expectEqualStrings("a", ed.line());
    try std.testing.expectEqualStrings("ab\x08 \x08", cap.contents());
    // Backspace at the start is refused with a bell.
    _ = ed.feed(out, 0x01); // home
    cap.reset();
    _ = ed.feed(out, 0x7f);
    try std.testing.expectEqualStrings("\x07", cap.contents());
    try std.testing.expectEqual(@as(usize, 1), ed.len);
}

test "tty: mid-line insert/delete and Home/End track the cursor" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    for ("ac") |c| _ = ed.feed(out, c);
    _ = ed.feedKey(out, .home);
    _ = ed.feedKey(out, .right); // cursor 1
    cap.reset();
    _ = ed.feed(out, 'b');
    try std.testing.expectEqualStrings("abc", ed.line());
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
    try std.testing.expectEqualStrings("\x08abc\x08", cap.contents());
    // Home then Delete: remove the leading 'a' -> "bc".
    _ = ed.feedKey(out, .home);
    cap.reset();
    _ = ed.feedKey(out, .delete);
    try std.testing.expectEqualStrings("bc", ed.line());
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    try std.testing.expectEqualStrings("bc \x08\x08\x08", cap.contents());
    // End moves to the tail.
    _ = ed.feedKey(out, .end);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
    // Right at the tail bells.
    cap.reset();
    _ = ed.feedKey(out, .right);
    try std.testing.expectEqualStrings("\x07", cap.contents());
}

test "tty: submit echoes CRLF, remembers history, and swallows the CRLF LF" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    for ("hi") |c| _ = ed.feed(out, c);
    try std.testing.expectEqual(LineResult.submitted, ed.feed(out, '\r'));
    try std.testing.expectEqualStrings("hi\r\n", cap.contents());
    try std.testing.expectEqual(@as(usize, 1), ed.hist_count);
    // The LF half of the same pair must not start an empty line.
    ed.next_line();
    try std.testing.expectEqual(LineResult.none, ed.feed(out, '\n'));
    try std.testing.expectEqual(@as(usize, 0), ed.len);
    // An empty line is not stored in history.
    try std.testing.expectEqual(LineResult.submitted, ed.feed(out, '\n'));
    try std.testing.expectEqual(@as(usize, 1), ed.hist_count);
}

test "tty: the 257th char is refused, never truncated mid-word" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    var i: usize = 0;
    while (i < max_line) : (i += 1) try std.testing.expectEqual(LineResult.none, ed.feed(out, 'c'));
    try std.testing.expect(!ed.rejected);
    try std.testing.expectEqual(LineResult.none, ed.feed(out, 'c'));
    try std.testing.expectEqual(@as(usize, max_line), ed.len);
    try std.testing.expect(ed.rejected);
    // The line still submits with what fit.
    try std.testing.expectEqual(LineResult.submitted, ed.feed(out, '\n'));
}

test "tty: Ctrl-C cancels and Ctrl-L requests a repaint" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    for ("xy") |c| _ = ed.feed(out, c);
    try std.testing.expectEqual(LineResult.cancelled, ed.feed(out, 0x03));
    try std.testing.expectEqualStrings("xy^C\r\n", cap.contents());
    try std.testing.expectEqual(@as(usize, 0), ed.len);
    try std.testing.expect(!ed.rejected);
    // Ctrl-L clears the screen; the line is intact for the caller to reprint.
    for ("hello") |c| _ = ed.feed(out, c);
    cap.reset();
    try std.testing.expectEqual(LineResult.repaint, ed.feed(out, 0x0c));
    try std.testing.expectEqualStrings("\x1b[2J\x1b[H", cap.contents());
    try std.testing.expectEqualStrings("hello", ed.line());
    cap.reset();
    ed.cursor = 2;
    ed.reprint(out);
    try std.testing.expectEqualStrings("hello\x08\x08\x08", cap.contents());
}

test "tty: Up/Down history walks entries and returns to the draft" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    for ("alpha") |c| _ = ed.feed(out, c);
    _ = ed.feed(out, '\n');
    ed.next_line();
    for ("beta") |c| _ = ed.feed(out, c);
    _ = ed.feed(out, '\n');
    ed.next_line();
    // Up recalls "beta", Up again "alpha".
    _ = ed.feedKey(out, .up);
    try std.testing.expectEqualStrings("beta", ed.line());
    _ = ed.feedKey(out, .up);
    try std.testing.expectEqualStrings("alpha", ed.line());
    // Down returns to "beta", Down again to the (empty) draft.
    _ = ed.feedKey(out, .down);
    try std.testing.expectEqualStrings("beta", ed.line());
    _ = ed.feedKey(out, .down);
    try std.testing.expectEqual(@as(usize, 0), ed.len);
    // A typed draft is preserved across an Up/Down round trip.
    for ("draft") |c| _ = ed.feed(out, c);
    _ = ed.feedKey(out, .up);
    try std.testing.expectEqualStrings("beta", ed.line());
    _ = ed.feedKey(out, .down);
    try std.testing.expectEqualStrings("draft", ed.line());
    // Up at the oldest / Down at the newest bell instead of wrapping.
    _ = ed.feedKey(out, .up);
    _ = ed.feedKey(out, .up);
    cap.reset();
    _ = ed.feedKey(out, .up);
    try std.testing.expectEqualStrings("\x07", cap.contents());
}

test "tty: consecutive duplicate submissions are collapsed in history" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    for ("echo") |c| _ = ed.feed(out, c);
    _ = ed.feed(out, '\n');
    ed.next_line();
    for ("echo") |c| _ = ed.feed(out, c);
    _ = ed.feed(out, '\n');
    ed.next_line();
    try std.testing.expectEqual(@as(usize, 1), ed.hist_count);
}

test "tty: history ring never overflows and keeps the newest entries" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    var i: usize = 0;
    while (i < hist_capacity + 8) : (i += 1) {
        var line_buf: [16]u8 = undefined;
        const n = std.fmt.bufPrint(&line_buf, "line{d}", .{i}) catch unreachable;
        for (n) |c| _ = ed.feed(out, c);
        _ = ed.feed(out, '\n');
        ed.next_line();
    }
    try std.testing.expectEqual(hist_capacity, ed.hist_count);
    try std.testing.expectEqualStrings("line23", ed.history[0][0..ed.hist_len[0]]);
    try std.testing.expectEqualStrings("line8", ed.history[hist_capacity - 1][0..ed.hist_len[hist_capacity - 1]]);
    // Recall walks the whole ring without touching garbage lengths.
    var steps: usize = 0;
    while (steps < hist_capacity) : (steps += 1) _ = ed.feedKey(out, .up);
    try std.testing.expectEqual(@as(usize, hist_capacity), ed.hist_cursor);
    try std.testing.expectEqualStrings("line8", ed.line());
}

test "tty: kill chords truncate toward the cursor" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    for ("hello world") |c| _ = ed.feed(out, c);
    _ = ed.feedKey(out, .home);
    _ = ed.feedKey(out, .ctrl_k);
    try std.testing.expectEqual(@as(usize, 0), ed.len);
    for ("world") |c| _ = ed.feed(out, c);
    _ = ed.feedKey(out, .home);
    _ = ed.feedKey(out, .right);
    _ = ed.feedKey(out, .right);
    _ = ed.feedKey(out, .ctrl_u);
    try std.testing.expectEqualStrings("rld", ed.line());
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
}

test "tty: Tab bells (completion is SH3) and Ctrl-D reports eof" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    try std.testing.expectEqual(LineResult.none, ed.feed(out, '\t'));
    try std.testing.expectEqualStrings("\x07", cap.contents());
    try std.testing.expectEqual(@as(usize, 0), ed.len);
    try std.testing.expectEqual(LineResult.eof, ed.feed(out, 0x04));
}

test "tty: Session.open is a thin facade (no syscall executes on host)" {
    // On the host the syscall helpers are compile-time no-ops, so the open
    // succeeds with a zero handle; the point is that the glue type-checks and
    // the pure layer never calls it.
    var session = Session.open().?;
    try std.testing.expect(session.valid);
    const sink = session.output();
    sink.write("x"); // host no-op
    session.detach();
    try std.testing.expect(!session.attached);
    session.close();
    try std.testing.expect(!session.valid);
}

fn uniqueCompleter(line: []const u8, cursor: usize, index: usize) ?CompletionMatch {
    _ = index;
    var start = cursor;
    while (start > 0 and line[start - 1] != ' ') start -= 1;
    return .{ .replace_start = start, .text = "example", .match_count = 1, .has_trailing_space = true };
}

fn cycleCompleter(line: []const u8, cursor: usize, index: usize) ?CompletionMatch {
    var start = cursor;
    while (start > 0 and line[start - 1] != ' ') start -= 1;
    const prefix = line[start..cursor];
    if (std.mem.eql(u8, prefix, "ca")) {
        const cands = [_][]const u8{ "calc", "cat" };
        return .{ .replace_start = start, .text = cands[index % cands.len], .match_count = cands.len };
    }
    return null;
}

test "tty: tab completion inserts a unique suffix with a trailing space" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{ .completer = uniqueCompleter };
    for ("exam") |c| _ = ed.feed(out, c);
    cap.reset();
    _ = ed.feed(out, '\t');
    try std.testing.expectEqualStrings("example ", ed.line());
    try std.testing.expectEqual(@as(usize, 8), ed.cursor);
    try std.testing.expect(!ed.completing);
    // The inserted suffix was echoed.
    try std.testing.expect(std.mem.indexOf(u8, cap.contents(), "ple") != null);
}

test "tty: multi-match completion cycles candidates on repeated Tab" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{ .completer = cycleCompleter };
    for ("ca") |c| _ = ed.feed(out, c);
    // First Tab -> "calc".
    _ = ed.feed(out, '\t');
    try std.testing.expectEqualStrings("calc", ed.line());
    try std.testing.expect(ed.completing);
    // Second Tab -> "cat".
    _ = ed.feed(out, '\t');
    try std.testing.expectEqualStrings("cat", ed.line());
    // Third Tab -> back to "calc".
    _ = ed.feed(out, '\t');
    try std.testing.expectEqualStrings("calc", ed.line());
    // A non-Tab byte breaks cycling and is inserted.
    _ = ed.feed(out, ' ');
    try std.testing.expect(!ed.completing);
    try std.testing.expectEqualStrings("calc ", ed.line());
}

test "tty: completion with no source or no match bells and changes nothing" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    for ("ab") |c| _ = ed.feed(out, c);
    cap.reset();
    _ = ed.feed(out, '\t');
    try std.testing.expectEqualStrings("\x07", cap.contents());
    try std.testing.expectEqualStrings("ab", ed.line());
    // A completer that returns null also bells.
    var ed2 = LineEditor{ .completer = cycleCompleter };
    _ = ed2.feed(out, 'z');
    cap.reset();
    _ = ed2.feed(out, '\t');
    try std.testing.expect(std.mem.indexOf(u8, cap.contents(), "\x07") != null);
    try std.testing.expectEqualStrings("z", ed2.line());
}

test "tty: Ctrl+R reverse-i-search finds and accepts a history match" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    for ("status43") |c| _ = ed.feed(out, c);
    _ = ed.feed(out, '\r');
    ed.next_line();
    for ("help") |c| _ = ed.feed(out, c);
    _ = ed.feed(out, '\r');
    ed.next_line();
    cap.reset();
    // Ctrl+R enters search and draws the UI.
    try std.testing.expectEqual(LineResult.none, ed.feed(out, 0x12));
    try std.testing.expect(ed.searching);
    try std.testing.expect(std.mem.indexOf(u8, cap.contents(), "reverse-i-search") != null);
    // Typing narrows to the "status43" entry.
    for ("stat") |c| _ = ed.feed(out, c);
    try std.testing.expectEqualStrings("status43", ed.line());
    // Enter accepts (repaint); the line stays runnable.
    try std.testing.expectEqual(LineResult.repaint, ed.feed(out, '\r'));
    try std.testing.expect(!ed.searching);
    try std.testing.expectEqualStrings("status43", ed.line());
    try std.testing.expectEqual(LineResult.submitted, ed.feed(out, '\r'));
}

test "tty: Ctrl+R cancel restores the pre-search draft" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    for ("status43") |c| _ = ed.feed(out, c);
    _ = ed.feed(out, '\r');
    ed.next_line();
    for ("draft") |c| _ = ed.feed(out, c);
    _ = ed.feed(out, 0x12); // enter search (draft saved)
    for ("stat") |c| _ = ed.feed(out, c); // match loads "status43"
    try std.testing.expectEqualStrings("status43", ed.line());
    try std.testing.expectEqual(LineResult.repaint, ed.feed(out, 0x1b)); // Esc cancels
    try std.testing.expect(!ed.searching);
    try std.testing.expectEqualStrings("draft", ed.line());
}

// ---------------------------------------------------------------------------
// M49 SD4 (#1131): editing-ergonomics tests
// ---------------------------------------------------------------------------

test "tty: a lone ESC still types the following byte end to end (emacs)" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    _ = ed.feed(out, 0x1b);
    _ = ed.feed(out, 'x');
    try std.testing.expectEqualStrings("x", ed.line());
}

test "tty: trailing backslash continues the line (POSIX join, no backslash)" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    for ("echo foo \\") |c| _ = ed.feed(out, c);
    try std.testing.expectEqual(LineResult.continued, ed.feed(out, '\r'));
    try std.testing.expectEqualStrings("echo foo ", ed.line());
    try std.testing.expectEqualStrings("echo foo \\\r\n> ", cap.contents());
    for ("bar") |c| _ = ed.feed(out, c);
    try std.testing.expectEqual(LineResult.submitted, ed.feed(out, '\n'));
    try std.testing.expectEqualStrings("echo foo bar", ed.line());
    try std.testing.expectEqual(@as(usize, 1), ed.hist_count);
}

test "tty: an escaped backslash does NOT continue (odd/even run)" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    for ("echo a\\\\") |c| _ = ed.feed(out, c);
    try std.testing.expectEqual(LineResult.submitted, ed.feed(out, '\r'));
    try std.testing.expectEqualStrings("echo a\\\\", ed.line());
}

test "tty: bracketed paste inserts bytes literally and submits on newline" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    for ("\x1b[200~") |c| _ = ed.feed(out, c);
    try std.testing.expect(ed.pasting);
    // Control bytes are literal data, not editor commands; the tab and
    // Ctrl-C bytes ride through.
    _ = ed.feed(out, 'a');
    _ = ed.feed(out, '\t');
    _ = ed.feed(out, 0x03);
    _ = ed.feed(out, 'b');
    try std.testing.expectEqualStrings("a\t\x03b", ed.line());
    try std.testing.expectEqual(@as(usize, 4), ed.pasted);
    // A pasted newline submits the (literal) line.
    try std.testing.expectEqual(LineResult.submitted, ed.feed(out, '\n'));
    try std.testing.expectEqualStrings("a\t\x03b", ed.line());
    // The LF half of a CRLF pair is swallowed; the terminator ends paste.
    for ("\x1b[201~") |c| _ = ed.feed(out, c);
    try std.testing.expect(!ed.pasting);
    // After paste, control codes are commands again.
    ed.next_line();
    try std.testing.expectEqual(LineResult.cancelled, ed.feed(out, 0x03));
}

test "tty: Ctrl-L clears scrollback only when the front-end has one" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    for ("hi") |c| _ = ed.feed(out, c);
    cap.reset();
    try std.testing.expectEqual(LineResult.repaint, ed.feed(out, 0x0c));
    try std.testing.expectEqualStrings("\x1b[2J\x1b[H", cap.contents());
    ed.clear_scrollback = true;
    cap.reset();
    try std.testing.expectEqual(LineResult.repaint, ed.feed(out, 0x0c));
    try std.testing.expectEqualStrings("\x1b[2J\x1b[3J\x1b[H", cap.contents());
    try std.testing.expectEqualStrings("hi", ed.line());
    cap.reset();
    ed.reprint(out);
    try std.testing.expectEqualStrings("hi", cap.contents());
}

test "tty: vi insert -> normal -> motions and back to insert" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{ .mode = .vi };
    for ("abc") |c| _ = ed.feed(out, c);
    // ESC is a prefix: the next byte both switches mode and replays.
    _ = ed.feed(out, 0x1b);
    try std.testing.expectEqual(ViState.insert, ed.vi_state);
    _ = ed.feed(out, 'h');
    try std.testing.expectEqual(ViState.normal, ed.vi_state);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
    // l moves right, 0 home, $ end, x deletes under the cursor.
    _ = ed.feed(out, 'l');
    try std.testing.expectEqual(@as(usize, 3), ed.cursor);
    _ = ed.feed(out, '0');
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    _ = ed.feed(out, 'x');
    try std.testing.expectEqualStrings("bc", ed.line());
    // $ to the end, i returns to insert at the cursor.
    _ = ed.feed(out, '$');
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
    _ = ed.feed(out, 'i');
    try std.testing.expectEqual(ViState.insert, ed.vi_state);
    _ = ed.feed(out, '!');
    try std.testing.expectEqualStrings("bc!", ed.line());
}

test "tty: vi normal j/k walk history and dd clears the line" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{ .mode = .vi };
    for ("first") |c| _ = ed.feed(out, c);
    _ = ed.feed(out, '\r');
    ed.next_line();
    for ("second") |c| _ = ed.feed(out, c);
    _ = ed.feed(out, '\r');
    ed.next_line();
    _ = ed.feed(out, 0x1b);
    _ = ed.feed(out, 'k'); // ESC + k: normal then history older
    try std.testing.expectEqualStrings("second", ed.line());
    _ = ed.feed(out, 'k');
    try std.testing.expectEqualStrings("first", ed.line());
    _ = ed.feed(out, 'j');
    try std.testing.expectEqualStrings("second", ed.line());
    // dd needs two d's; the first d is dropped by another key.
    _ = ed.feed(out, 'd');
    _ = ed.feed(out, 'h');
    _ = ed.feed(out, 'd');
    try std.testing.expectEqualStrings("second", ed.line());
    _ = ed.feed(out, 'd');
    try std.testing.expectEqual(@as(usize, 0), ed.len);
}

test "tty: emacs mode ignores ESC state transitions" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{};
    for ("ab") |c| _ = ed.feed(out, c);
    _ = ed.feedKey(out, .escape);
    try std.testing.expectEqual(ViState.insert, ed.vi_state);
    try std.testing.expectEqualStrings("ab", ed.line());
}

test "tty: completion cycle wrap lists the candidates and repaints" {
    var cap = Capture{};
    const out = cap.out();
    var ed = LineEditor{ .completer = cycleCompleter };
    for ("ca") |c| _ = ed.feed(out, c);
    cap.reset();
    _ = ed.feed(out, '\t'); // -> calc
    try std.testing.expectEqualStrings("calc", ed.line());
    _ = ed.feed(out, '\t'); // -> cat
    try std.testing.expectEqualStrings("cat", ed.line());
    cap.reset();
    try std.testing.expectEqual(LineResult.repaint, ed.feed(out, '\t')); // wrap -> list
    try std.testing.expect(std.mem.indexOf(u8, cap.contents(), "calc") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.contents(), "cat") != null);
    try std.testing.expectEqualStrings("calc", ed.line());
}
