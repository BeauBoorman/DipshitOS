//! VirelaiOS terminal scrollback ring (M18 T1, issue #404).
//!
//! A bounded ring buffer that captures terminal output line-by-line so the
//! user can scroll back through command history. The ring stores the last
//! `max_lines` lines of terminal output; older lines are dropped silently.
//!
//! Each line is capped at `line_cap` bytes — longer lines are truncated
//! with an indicator. The ring is pure BSS (no allocation).

const std = @import("std");

/// Maximum number of scrollback lines.
pub const max_lines: usize = 200;
/// Maximum bytes per scrollback line (longer lines are truncated).
pub const line_cap: usize = 128;

/// A bounded ring buffer of the last N lines of terminal output.
pub const Scrollback = struct {
    /// Ring storage: `max_lines` slots of `line_cap` bytes each.
    lines: [max_lines][line_cap]u8 = undefined,
    /// Actual length of each line in the ring.
    lens: [max_lines]usize = @as([max_lines]usize, @splat(@as(usize, 0))),
    /// Number of lines ever stored (monotonic counter, used for view math).
    total: usize = 0,
    /// Index of the next slot to write (wraps around `max_lines`).
    head: usize = 0,
    /// Current write position within the active line.
    col: usize = 0,

    /// Append raw bytes to the scrollback ring. Bytes are accumulated into
    /// the current line until a newline is seen, at which point the line is
    /// committed. Carriage returns reset the column but don't commit.
    pub fn append(self: *Scrollback, bytes: []const u8) void {
        for (bytes) |b| {
            switch (b) {
                0x0D => {
                    // Carriage return: go back to column 0 on the current line.
                    self.col = 0;
                },
                0x0A => {
                    // Newline: commit the current line to the ring.
                    self.commit();
                },
                else => {
                    if (self.col < line_cap) {
                        self.lines[self.head][self.col] = b;
                        self.col += 1;
                    } else if (self.col == line_cap) {
                        // Truncation indicator.
                        self.lines[self.head][line_cap - 3] = '.';
                        self.lines[self.head][line_cap - 2] = '.';
                        self.lines[self.head][line_cap - 1] = '.';
                        self.col += 1;
                    }
                    // else: silently drop bytes past the truncation indicator
                },
            }
        }
    }

    /// Commit the current line and advance to the next slot.
    fn commit(self: *Scrollback) void {
        self.lens[self.head] = @min(self.col, line_cap);
        self.head = (self.head + 1) % max_lines;
        self.col = 0;
        self.total += 1;
    }

    /// Flush any partial line in progress (called when printing the prompt,
    /// which doesn't end with a newline).
    pub fn flush_partial(self: *Scrollback) void {
        if (self.col > 0) {
            self.commit();
        }
    }

    /// Copy `count` lines from the scrollback (starting `offset` lines back
    /// from the newest) into `dst`. Returns the number of lines actually
    /// copied. `offset` = 0 means the newest line.
    pub fn copy_lines(self: *Scrollback, offset: usize, count: usize, dst: [][]u8) usize {
        if (self.total == 0) return 0;
        const kept = @min(self.total, max_lines);
        if (offset >= kept) return 0;

        const newest_idx: usize = if (self.total == 0)
            0
        else
            (self.head + max_lines - 1) % max_lines;

        var copied: usize = 0;
        var i: usize = 0;
        while (i < count and offset + i < kept) : (i += 1) {
            const idx = (newest_idx + max_lines - (offset + i)) % max_lines;
            const len = @min(self.lens[idx], dst[copied].len);
            @memcpy(dst[copied][0..len], self.lines[idx][0..len]);
            copied += 1;
        }
        return copied;
    }

    /// Reset the scrollback ring.
    pub fn reset(self: *Scrollback) void {
        self.head = 0;
        self.col = 0;
        self.total = 0;
        @memset(&self.lens, 0);
    }

    /// The number of lines currently stored (min(total, max_lines)).
    pub fn stored(self: *const Scrollback) usize {
        return @min(self.total, max_lines);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────
const NL = [_]u8{0x0A};
const CR = [_]u8{0x0D};

test "scrollback: append lines and retrieve" {
    var sb = Scrollback{};
    sb.reset();

    sb.append("line one");
    sb.append(&NL);
    sb.append("line two");
    sb.append(&NL);
    sb.append("line three");
    sb.append(&NL);
    sb.flush_partial();

    try std.testing.expectEqual(@as(usize, 3), sb.stored());

    var dst: [max_lines][line_cap]u8 = undefined;
    var slices: [max_lines][]u8 = undefined;
    for (&slices, 0..) |*s, j| s.* = dst[j][0..];

    const n = sb.copy_lines(0, 3, slices[0..]);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("line three", slices[0][0..10]);
    try std.testing.expectEqualStrings("line two", slices[1][0..8]);
    try std.testing.expectEqualStrings("line one", slices[2][0..8]);
}

test "scrollback: overflow wraps and drops oldest" {
    var sb = Scrollback{};
    sb.reset();

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 250) : (i += 1) {
        const line = std.fmt.bufPrint(&buf, "line {d}", .{i}) catch unreachable;
        sb.append(line);
        sb.append(&NL);
    }
    sb.flush_partial();

    try std.testing.expectEqual(@as(usize, max_lines), sb.stored());
    try std.testing.expectEqual(@as(usize, 250), sb.total);

    // Oldest lines (0..49) should be gone. Newest is line 249.
    var dst: [max_lines][line_cap]u8 = undefined;
    var slices: [max_lines][]u8 = undefined;
    for (&slices, 0..) |*s, j| s.* = dst[j][0..];

    const n = sb.copy_lines(0, 5, slices[0..]);
    try std.testing.expectEqual(@as(usize, 5), n);
    // Newest line should contain "line 249"
    var found_newest: bool = false;
    for (slices[0..n]) |sl| {
        if (std.mem.indexOf(u8, sl, "line 249") != null) found_newest = true;
    }
    try std.testing.expect(found_newest);

    // line 0 should NOT be in the ring any more
    var found_zero: bool = false;
    const sb_stored = sb.stored();
    for (slices[0..sb_stored]) |sl| {
        if (std.mem.startsWith(u8, sl, "line 0") and (sl.len == 6 or sl[6] != '0')) {
            found_zero = true;
            break;
        }
    }
    try std.testing.expect(!found_zero);
}

test "scrollback: long lines are truncated" {
    var sb = Scrollback{};
    sb.reset();

    const long: [200]u8 = @as([200]u8, @splat(@as(u8, 'X')));
    sb.append(&long);
    sb.append(&NL);
    sb.flush_partial();

    try std.testing.expectEqual(@as(usize, 1), sb.stored());

    var dst: [1][line_cap]u8 = undefined;
    var slices: [1][]u8 = undefined;
    slices[0] = dst[0][0..];

    const n = sb.copy_lines(0, 1, slices[0..]);
    try std.testing.expectEqual(@as(usize, 1), n);
    // Should end with "..." truncation indicator
    try std.testing.expect(std.mem.indexOf(u8, slices[0], "...") != null);
}

test "scrollback: carriage return resets column but keeps line" {
    var sb = Scrollback{};
    sb.reset();

    sb.append("hello");
    sb.append(&CR);
    sb.append("bye");
    sb.append(&NL);
    sb.flush_partial();

    try std.testing.expectEqual(@as(usize, 1), sb.stored());

    var dst: [1][line_cap]u8 = undefined;
    var slices: [1][]u8 = undefined;
    slices[0] = dst[0][0..];

    const n = sb.copy_lines(0, 1, slices[0..]);
    try std.testing.expectEqual(@as(usize, 1), n);
    // CR resets col to 0, so "bye" overwrites "hel" — result starts with "bye"
    try std.testing.expect(std.mem.indexOf(u8, slices[0][0..5], "bye") != null);
}
