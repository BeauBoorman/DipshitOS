//! M73g (#1633) — VT conformance corpus: pinned sequence → grid goldens.
//!
//! Byte vector in, visible grid out, compared byte-equal. This file is a
//! class-A TEST ROOT (registered in build.zig's kernel test list) — no spec
//! boots it, no parser code lives here.
//!
//! THE CONTRACT for parser cards (written by M73g so every later card knows
//! where its rows go):
//!
//!   - A row pins TODAY'S parser. Behaviour unchanged → rows must be
//!     untouched (a regression turns the corpus red in host-seconds).
//!   - A card that deliberately changes behaviour changes its rows in the
//!     SAME PR. Existing hooks:
//!       * M73h (256-colour/truecolour, Amendment E) LANDED its rows in
//!         the SGR-depth group and rewrote the old "extended SGR params
//!         are ignored" row — that flip is exactly what a behaviour
//!         change looks like here;
//!       * M73i (mouse modes) landed its mode rows in the modes group next
//!         to the `?2004h` private-mode row — flags live in terminal.zig's
//!         mode-table test; these rows pin consumed-and-unpainted;
//!       * UTF-8 decode rows (M73a-1's policy) live in the decode group —
//!         that card landed before this corpus existed, so its behaviour is
//!         pinned here now.
//!       * M80a (#1712) landed its cursor-motion and REP rows in the CSI
//!         group next to the `H`/`f` rows — no existing row flipped (the
//!         "unknown CSI final" pin uses `Z`, which stays unknown).
//!       * M80b (#1713) landed its insert/delete/erase rows (@/P/X/L/M/
//!         S/T) and the ED 3 row at the end of the CSI group — no
//!         existing row flipped (ED 3 was lumped with ED 2 and unpinned).
//!         The history half of ED 3 cannot live here (a corpus `Screen`
//!         has no history bank): it is pinned by registry tests in
//!         terminal.zig, the M73i mode-table precedent.
//!       * M80e (#1722) deliberately replaced the old ESC charset
//!         divergence pin with DECSC/DECRC, ESC motion, charset, reset,
//!         and keypad rows. These are behavior changes, not silent fixes.
//!       * M80c (#1714) adds DECSTBM/DECOM/DECAWM rows in the CSI
//!         group. Its VT-correct pending-wrap policy deliberately flips
//!         the old CUB pending-wrap pin: motion resolves the wrap, then
//!         applies its displacement.
//!       * M80g (#1715) lands an OSC group: Ps 0/2 titles and OSC 52 rows
//!         pin "consumed, never painted" plus the queue state (the
//!         `title`/`clip` Case fields). Delivery — window title buffer,
//!         M79d's kind-11 seam, the clipboard bridge — is pinned by
//!         registry tests in terminal.zig (the M73i precedent): a corpus
//!         Screen has no pump to deliver on.
//!       * M85a (#1813) lands the image-intake group: DCS `q` (sixel)
//!         header Ps (`sixel_p`/`sixel_origin` Case fields) and every
//!         other ESC string (APC/SOS/PM, non-`q` DCS) plus OSC 1337 is
//!         "consumed, never painted".
//!       * M85b (#1814) decodes and places sixel, so it deliberately flips
//!         M85a's capture rows: the 4 KiB payload capture (`sixel`/
//!         `sixel_ready`) is gone — decode streams, the bound is PIXELS
//!         (`term_image.max_w`/`max_h`), and `sixel_overflow` now means
//!         "refused whole". The two rows whose payload was a valid image
//!         now place it (the grid is no longer innocent: that is the
//!         point). Its placement group pins default placement, overlap
//!         with text, scrolling with the buffer, ED/EL/ICH/DCH/ECH, the
//!         alternate screen and eviction (`images` counts, `tile` cell
//!         spots, `pixels` spots); resize and history are pinned by the
//!         test blocks after the group and by terminal.zig.
//!       * Group I is a deterministic CSI parameter-soup FUZZ — not
//!         goldens. It enforces INVARIANTS (no panic, whole wide pairs,
//!         bounded indices, nothing below the used tail) under random
//!         load; a parser card that changes what "uncorrupted" means
//!         asserts it there.
//!   - A row that DISAGREES with the code is wrong — or you found a bug.
//!     The bug goes in a comment or an issue, never a silent "fix" inside
//!     an unrelated parser card.
//!
//! Placement: its own file so terminal.zig (~2,600 lines) gains no test
//! bulk; ADR 0020 D1's `Screen` is pure (fixed arrays, no allocation), so
//! the corpus drives it from outside through the pub feed/grid surface
//! (`feed`, `line`, `cellAt`, `styleAt`, `cursorLine`/`cursorCol`).

fn repeat_lit(comptime lit: []const u8, comptime n: usize) *const [n * lit.len:0]u8 {
    if (n == 0) return "";
    return lit ++ repeat_lit(lit, n - 1);
}
const std = @import("std");
const t = @import("terminal.zig");

/// A pinned rendition expectation: every field is always checked
/// (`fg`/`bg` null = the presentation default, `bold` the bit 10 state).
const Rendition = struct {
    fg: ?u8 = null,
    bg: ?u8 = null,
    bold: bool = false,
};

/// A style spot-check at a cell. `fg`/`bg` are the PALETTE accessors
/// (null = default or truecolour — the rgb fields pin which);
/// `fg_rgb`/`bg_rgb` assert `Screen.rgbAt` (null = this cell stores no
/// RGB, the correct default for every palette/default row);
/// `default_exact` additionally asserts the cell style is byte-identical
/// to `default_cell_style`.
const StyleSpot = struct {
    row: usize,
    col: usize,
    fg: ?u8 = null,
    bg: ?u8 = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    fg_rgb: ?t.Rgb = null,
    bg_rgb: ?t.Rgb = null,
    default_exact: bool = false,
};

/// A rune-cell spot-check (presentation truth — `line()` projects
/// non-ASCII runes to 0x00, so rune expectations live here).
const CellSpot = struct {
    row: usize,
    col: usize,
    base: u21 = ' ',
    mark: u21 = 0,
    cont: u1 = 0,
    /// M85b (#1814): the image tile {tx, ty} this cell shows; null
    /// asserts a text cell (no image).
    tile: ?[2]u7 = null,
};

/// M85b (#1814): an image pixel spot-check — pixel (dx, dy) of the tile
/// the cell at (row, col) shows, sampled at its placement geometry.
/// `rgb` null = transparent (an unset sixel pixel, or outside the image).
const PixelSpot = struct {
    row: usize,
    col: usize,
    dx: usize = 0,
    dy: usize = 0,
    rgb: ?u32,
};

const Case = struct {
    name: []const u8,
    input: []const u8,
    /// Expected ASCII projection of lines 0..lines.len (`Screen.line`).
    lines: []const []const u8 = &.{},
    /// Exact cursor position {row, col} after the feed.
    cursor: ?[2]usize = null,
    /// Expected `lineCount()` (lines in use).
    used: ?usize = null,
    /// Expected DECTCEM visibility.
    visible: ?bool = null,
    /// Expected alternate-screen-active flag.
    alt: ?bool = null,
    /// Expected current SGR rendition.
    rendition: ?Rendition = null,
    /// Expected keypad mode (DECKPAM=true, DECKPNM=false).
    keypad: ?bool = null,
    /// Expected OSC title queue (M80g #1715) — the bounded bytes the
    /// parser stored for Ps 0/2, before any delivery.
    title: ?[]const u8 = null,
    /// Expected OSC 52 queue (M80g #1715) — the decoded clipboard bytes
    /// awaiting the pump; empty means no copy landed.
    clip: ?[]const u8 = null,
    /// Expected DCS header Ps values (M85a).
    sixel_p: ?[3]u16 = null,
    /// Expected sticky refusal flag (M85b #1814; M85a's overflow flag):
    /// the last sixel string broke a bound and was refused whole.
    sixel_overflow: ?bool = null,
    /// Expected cursor origin at the string's start (M85a) — where M85b
    /// places the image.
    sixel_origin: ?[2]usize = null,
    /// Expected image outcome counters (M85b): {placed, refused, evicted}.
    images: ?[3]u32 = null,
    cells: []const CellSpot = &.{},
    styles: []const StyleSpot = &.{},
    pixels: []const PixelSpot = &.{},
};

fn run(c: Case) !void {
    var s: t.Screen = .{};
    s.feed(c.input);
    for (c.lines, 0..) |want, i| try std.testing.expectEqualStrings(want, s.line(i));
    if (c.used) |u| try std.testing.expectEqual(u, s.lineCount());
    if (c.cursor) |rc| {
        try std.testing.expectEqual(rc[0], s.cursorLine());
        try std.testing.expectEqual(rc[1], s.cursorCol());
    }
    if (c.visible) |v| try std.testing.expectEqual(v, s.cursor_visible);
    if (c.alt) |a| try std.testing.expectEqual(a, s.alt_active);
    if (c.keypad) |k| try std.testing.expectEqual(k, s.keypadApplication());
    if (c.title) |want| try std.testing.expectEqualStrings(want, s.title[0..s.title_len]);
    if (c.clip) |want| try std.testing.expectEqualStrings(want, s.clip_data[0..s.clip_len]);
    if (c.sixel_p) |p| try std.testing.expectEqual(p, s.sixel_p);
    if (c.sixel_overflow) |o| try std.testing.expectEqual(o, s.sixel_overflow);
    if (c.images) |n| {
        try std.testing.expectEqual(n[0], s.img_placed);
        try std.testing.expectEqual(n[1], s.img_refused);
        try std.testing.expectEqual(n[2], s.img_evicted);
    }
    if (c.sixel_origin) |rc| {
        try std.testing.expectEqual(rc[0], s.sixel_origin_line);
        try std.testing.expectEqual(rc[1], s.sixel_origin_col);
    }
    if (c.rendition) |r| {
        try std.testing.expectEqual(r.fg, t.styleForeground(s.style));
        try std.testing.expectEqual(r.bg, t.styleBackground(s.style));
        try std.testing.expectEqual(r.bold, t.styleBold(s.style));
    }
    for (c.cells) |x| {
        const cell = s.cellAt(x.row, x.col);
        try std.testing.expectEqual(x.base, cell.base);
        try std.testing.expectEqual(x.mark, cell.mark);
        try std.testing.expectEqual(x.cont, cell.cont);
        if (x.tile) |tile| {
            try std.testing.expect(cell.img != 0);
            try std.testing.expectEqual(tile[0], cell.tx);
            try std.testing.expectEqual(tile[1], cell.ty);
        } else {
            try std.testing.expectEqual(@as(u3, 0), cell.img);
        }
    }
    for (c.pixels) |x| {
        const tile = s.imageTile(x.row, x.col) orelse return error.TestExpectedImageCell;
        try std.testing.expectEqual(x.rgb, tile.sample(x.dx, x.dy, tile.img.cell_w, tile.img.cell_h));
    }
    for (c.styles) |x| {
        const st = s.styleAt(x.row, x.col);
        try std.testing.expectEqual(x.fg, t.styleForeground(st));
        try std.testing.expectEqual(x.bg, t.styleBackground(st));
        try std.testing.expectEqual(x.bold, t.styleBold(st));
        try std.testing.expectEqual(x.dim, t.styleDim(st));
        try std.testing.expectEqual(x.italic, t.styleItalic(st));
        try std.testing.expectEqual(x.underline, t.styleUnderline(st));
        try std.testing.expectEqual(x.reverse, t.styleReverse(st));
        const side = s.rgbAt(x.row, x.col);
        if (x.fg_rgb) |want| {
            try std.testing.expectEqual(t.rgb_colour, st.fg);
            const got = side.fg.?;
            try std.testing.expectEqual(want.r, got.r);
            try std.testing.expectEqual(want.g, got.g);
            try std.testing.expectEqual(want.b, got.b);
        } else {
            try std.testing.expectEqual(@as(?t.Rgb, null), side.fg);
        }
        if (x.bg_rgb) |want| {
            try std.testing.expectEqual(t.rgb_colour, st.bg);
            const got = side.bg.?;
            try std.testing.expectEqual(want.r, got.r);
            try std.testing.expectEqual(want.g, got.g);
            try std.testing.expectEqual(want.b, got.b);
        } else {
            try std.testing.expectEqual(@as(?t.Rgb, null), side.bg);
        }
        if (x.default_exact) try std.testing.expectEqual(t.default_cell_style, st);
    }
}

/// Run a group, naming the failing case (the grid diff itself comes from
/// the expect* location line).
fn runAll(cases: []const Case) !void {
    for (cases) |c| {
        run(c) catch |err| {
            std.debug.print("\ncorpus case failed: {s} (input {any})\n", .{ c.name, c.input });
            return err;
        };
    }
}

// Repeated inputs (comptime) so the tables stay readable.
const a80: [80]u8 = @as([80]u8, @splat(@as(u8, 'a')));
const a79: [79]u8 = @as([79]u8, @splat(@as(u8, 'a')));
/// M80b: three spaces + 77 `a`s — an ICH that shoves 3 cells off the
/// right margin of a full row.
const spaces3_a77: [80]u8 = @as([3]u8, @splat(@as(u8, ' '))) ++ @as([77]u8, @splat(@as(u8, 'a')));
/// M80g: an over-bound OSC payload (780 > osc_max) and a 70-byte title
/// (past title_max 64) — the overflow and truncation probes.
const x780: [780]u8 = @as([780]u8, @splat(@as(u8, 'x')));
const t70: [70]u8 = @as([70]u8, @splat(@as(u8, 't')));
/// M85a: 4097 sixels — once one byte past the 4 KiB capture bound; since
/// M85b (#1814) an image 4097 pixels wide, far past `term_image.max_w`.
const s4097: [4097]u8 = @as([4097]u8, @splat(@as(u8, 's')));
/// M85b: wrap a sixel payload in its DCS `q` … ST envelope.
fn sx(comptime payload: []const u8) *const [payload.len + 5]u8 {
    return "\x1bPq" ++ payload ++ "\x1b\\";
}

// ---------------------------------------------------------------------------
// Group A — ASCII control and line discipline.
// ---------------------------------------------------------------------------

const control_cases = [_]Case{
    .{
        .name = "fresh grid is empty, cursor home, cursor visible",
        .input = "",
        .lines = &.{""},
        .cursor = .{ 0, 0 },
        .used = 1,
        .visible = true,
        .rendition = .{},
    },
    .{
        .name = "CR returns to column 0 (no erase)",
        .input = "abc\rX",
        .lines = &.{"Xbc"},
        .cursor = .{ 0, 1 },
    },
    .{
        .name = "LF moves down and resets the column",
        .input = "ab\ncd",
        .lines = &.{ "ab", "cd" },
        .cursor = .{ 1, 2 },
        .used = 2,
    },
    .{
        // 127 LFs walk the cursor to the last row; the 128th scrolls the
        // grid up and drops the oldest row ("TOP") off the top.
        .name = "scroll at the bottom drops the oldest row",
        .input = "TOP" ++ (&@as([128:0]u8, @splat("\n"[0]))) ++ "Z",
        .lines = &.{""},
        .cursor = .{ 127, 1 },
        .used = 128,
        .cells = &.{.{ .row = 127, .col = 0, .base = 'Z' }},
    },
    .{
        .name = "BS steps back and the next write overwrites",
        .input = "abcd\x08X",
        .lines = &.{"abcX"},
        .cursor = .{ 0, 4 },
    },
    .{
        .name = "BS at column 0 is a no-op",
        .input = "\x08A",
        .lines = &.{"A"},
        .cursor = .{ 0, 1 },
    },
    .{
        .name = "TAB advances to the next 8-column stop (gap = spaces)",
        .input = "ab\tZ",
        .lines = &.{"ab      Z"},
        .cursor = .{ 0, 9 },
    },
    .{
        .name = "TAB at the right margin clamps to the last column",
        .input = &a79 ++ "\tZ",
        .lines = &.{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaZ"},
        .cursor = .{ 0, 80 },
    },
    .{
        .name = "bell, NUL and DEL paint nothing",
        .input = "A\x07B\x00C\x7fD",
        .lines = &.{"ABCD"},
        .cursor = .{ 0, 4 },
    },
};

test "terminal corpus: ASCII control and line discipline" {
    try runAll(&control_cases);
}

// ---------------------------------------------------------------------------
// Group B — wrap at the right margin (80 columns default).
// ---------------------------------------------------------------------------

const wrap_cases = [_]Case{
    .{
        .name = "exactly cols characters leave a PENDING wrap (col == cols)",
        .input = &a80,
        .lines = &.{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        .cursor = .{ 0, 80 },
        .used = 1,
    },
    .{
        .name = "the next printable lands on a fresh row",
        .input = &a80 ++ "XY",
        .lines = &.{ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "XY" },
        .cursor = .{ 1, 2 },
        .used = 2,
    },
    .{
        // 79 columns + a double-width rune: wrapping happens BEFORE the
        // split, so the pair starts row 1 whole.
        .name = "a wide pair never splits across the margin",
        .input = &a79 ++ "\xe4\xbd\xa0",
        .lines = &.{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        .cursor = .{ 1, 2 },
        .used = 2,
        .cells = &.{
            .{ .row = 1, .col = 0, .base = 0x4F60 },
            .{ .row = 1, .col = 1, .base = ' ', .cont = 1 },
        },
    },
};

test "terminal corpus: wrap at the right margin" {
    try runAll(&wrap_cases);
}

// ---------------------------------------------------------------------------
// Group C — CSI cursor positioning and erase (H/f/J/K).
// ---------------------------------------------------------------------------

const csi_cases = [_]Case{
    .{
        .name = "CUP with both params moves 1-based and grows `used`",
        .input = "\x1b[10;20H",
        .cursor = .{ 9, 19 },
        .used = 10,
    },
    .{
        .name = "CUP with no params homes the cursor",
        .input = "\x1b[H",
        .cursor = .{ 0, 0 },
        .used = 1,
    },
    .{
        .name = "HVP (f) behaves exactly like CUP (H)",
        .input = "\x1b[4;6f",
        .cursor = .{ 3, 5 },
        .used = 4,
    },
    .{
        .name = "out-of-range CUP clamps to the grid (127, 79)",
        .input = "\x1b[999;999H",
        .cursor = .{ 127, 79 },
        .used = 128,
    },
    .{
        // A zero (or missing) param falls back to 1 — rows/cols are 1-based.
        .name = "zero and missing CUP params default to 1",
        .input = "\x1b[;10H",
        .cursor = .{ 0, 9 },
        .used = 1,
    },
    // ---- M80a (#1712): cursor motion finals A/B/C/D/E/F/G/d and REP b. ----
    // Relative moves clamp at the grid edges and never materialise rows
    // (`used` grows on WRITE, in putRune); the absolute finals grow `used`
    // exactly like CUP. A motion cancels a pending wrap (col == cols) by
    // standing the cursor back on the last column (BS parity), and nothing
    // here clears a row.
    .{
        .name = "CUU (A) moves up n rows and keeps the column",
        .input = "\x1b[10;20H\x1b[3A",
        .cursor = .{ 6, 19 },
        .used = 10,
    },
    .{
        .name = "CUU clamps at row 0",
        .input = "\x1b[4;5H\x1b[99A",
        .cursor = .{ 0, 4 },
        .used = 4,
    },
    .{
        .name = "CUD (B) moves down n rows without materialising them",
        .input = "\x1b[5B",
        .cursor = .{ 5, 0 },
        .used = 1,
    },
    .{
        .name = "CUD clamps at the last grid row (128 rows)",
        .input = "\x1b[999B",
        .cursor = .{ 127, 0 },
        .used = 1,
    },
    .{
        .name = "CUF (C) moves right n columns and keeps the row",
        .input = "A\x1b[5C",
        .lines = &.{"A"},
        .cursor = .{ 0, 6 },
        .used = 1,
    },
    .{
        .name = "CUF clamps at the last column",
        .input = "A\x1b[999C",
        .cursor = .{ 0, 79 },
        .used = 1,
    },
    .{
        .name = "CUB (D) moves left n columns and keeps the row",
        .input = "\x1b[1;20H\x1b[3D",
        .cursor = .{ 0, 16 },
        .used = 1,
    },
    .{
        .name = "CUB clamps at column 0",
        .input = "A\x1b[999D",
        .cursor = .{ 0, 0 },
        .used = 1,
    },
    .{
        // Like CUP: a zero (or missing) motion param falls back to 1.
        .name = "zero and missing motion params default to 1",
        .input = "\x1b[5;5H\x1b[0A\x1b[A",
        .cursor = .{ 2, 4 },
        .used = 5,
    },
    .{
        // CNL/CPL are NOT "down/up and keep the column": the column
        // resets to 0 (a Charm header/footer layout depends on this).
        .name = "CNL (E) moves down n rows and resets the column",
        .input = "ABC\x1b[2E",
        .lines = &.{"ABC"},
        .cursor = .{ 2, 0 },
        .used = 1,
    },
    .{
        .name = "CNL clamps at the last grid row",
        .input = "\x1b[999E",
        .cursor = .{ 127, 0 },
        .used = 1,
    },
    .{
        .name = "CPL (F) moves up n rows and resets the column",
        .input = "\x1b[5;10H\x1b[2F",
        .cursor = .{ 2, 0 },
        .used = 5,
    },
    .{
        .name = "CPL clamps at row 0",
        .input = "\x1b[5;10H\x1b[99F",
        .cursor = .{ 0, 0 },
        .used = 5,
    },
    .{
        .name = "CHA (G) sets a 1-based absolute column",
        .input = "AB\x1b[5G",
        .lines = &.{"AB"},
        .cursor = .{ 0, 4 },
        .used = 1,
    },
    .{
        .name = "out-of-range CHA clamps to the last column",
        .input = "AB\x1b[999G",
        .cursor = .{ 0, 79 },
        .used = 1,
    },
    .{
        .name = "zero CHA param defaults to 1 (column 0)",
        .input = "AB\x1b[0G",
        .cursor = .{ 0, 0 },
        .used = 1,
    },
    .{
        .name = "VPA (d) sets a 1-based absolute row and grows used like CUP",
        .input = "\x1b[7d",
        .cursor = .{ 6, 0 },
        .used = 7,
    },
    .{
        .name = "VPA keeps the column and clamps at the last grid row",
        .input = "ABC\x1b[999d",
        .lines = &.{"ABC"},
        .cursor = .{ 127, 3 },
        .used = 128,
    },
    .{
        // xterm rule: the motion finals read param 0 only and never
        // touch the rendition.
        .name = "motion finals ignore extra params and leave the rendition",
        .input = "\x1b[1;31m\x1b[5;5H\x1b[1;3A",
        .cursor = .{ 3, 4 },
        .used = 5,
        .rendition = .{ .fg = 1, .bold = true },
    },
    .{
        // M80c (#1714): pending-wrap behavior is VT-correct. A motion first
        // resolves the deferred wrap to the last visible column, then applies
        // its own displacement; this row deliberately flips the old CUB
        // "without moving further" pin. CUD below the used tail still does
        // not materialise the row.
        .name = "CUD from a pending wrap cancels it and still moves rows",
        .input = &a80 ++ "\x1b[B",
        .lines = &.{&a80},
        .cursor = .{ 1, 79 },
        .used = 1,
    },
    .{
        .name = "CUB from a pending wrap resolves it, then moves one column",
        .input = &a80 ++ "\x1b[D",
        .lines = &.{&a80},
        .cursor = .{ 0, 78 },
        .used = 1,
    },
    .{
        .name = "CUF from a pending wrap stays on the last column",
        .input = &a80 ++ "\x1b[C",
        .lines = &.{&a80},
        .cursor = .{ 0, 79 },
        .used = 1,
    },
    .{
        // The only growth path for a relative motion's target row: a
        // WRITE materialises the rows up to the cursor.
        .name = "a write below the used tail materialises the rows up to it",
        .input = "\x1b[3BX",
        .lines = &.{ "", "", "", "X" },
        .cursor = .{ 3, 1 },
        .used = 4,
    },
    .{
        // Erasing a row that is already blank is not a write: the row
        // stays unmaterialised (nothing to project).
        .name = "an erase below the used tail does not materialise the row",
        .input = "\x1b[3B\x1b[2K",
        .cursor = .{ 3, 0 },
        .used = 1,
    },
    // ---- M80d (#1721): HTS/TBC and CHT/CBT tab-stop control. ----
    .{
        .name = "TAB keeps xterm's next-multiple-of-eight rule from every column",
        .input = "abc\x1b[1;4H\tZ\x1b[1;9H\tY\x1b[1;10H\tX",
        .lines = &.{"abc     Z       X"},
        .cursor = .{ 0, 17 },
        .used = 1,
    },
    .{
        .name = "HTS adds a non-default stop honoured by the next TAB",
        .input = "\x1b[1;13H\x1bH\x1b[1;10H\tZ",
        .lines = &.{"            Z"},
        .cursor = .{ 0, 13 },
        .used = 1,
    },
    .{
        .name = "TBC 0 clears the stop under the cursor",
        .input = "\x1b[1;13H\x1bH\x1b[1;13H\x1b[0g\x1b[1;10H\tZ",
        .lines = &.{"                Z"},
        .cursor = .{ 0, 17 },
        .used = 1,
    },
    .{
        .name = "TBC 3 clears every stop and TAB clamps at the right margin",
        .input = "\x1b[H\x1b[3g\tZ",
        .lines = &.{(&@as([79:0]u8, @splat(" "[0]))) ++ "Z"},
        .cursor = .{ 0, 80 },
        .used = 1,
    },
    .{
        .name = "CHT advances by stop count and CBT retreats by stop count",
        .input = "\x1b[2I\x1b[1;17H\x1bZ\x1b[1;9H\x1b[2Z",
        .lines = &.{""},
        .cursor = .{ 0, 0 },
        .used = 1,
    },
    .{
        .name = "CBT at column 0 clamps and never wraps",
        .input = "\x1b[999Z\x1b[1;3H\tZ",
        .lines = &.{"        Z"},
        .cursor = .{ 0, 9 },
        .used = 1,
    },
    .{
        .name = "unknown TBC modes are consumed without moving",
        .input = "\x1b[2g\x1b[1;5H\tZ",
        .lines = &.{"        Z"},
        .cursor = .{ 0, 9 },
        .used = 1,
    },
    // ---- M80a: REP (CSI b) repeats the last printed rune. ----
    .{
        .name = "REP (b) repeats the last printed rune n more times",
        .input = "a\x1b[3b",
        .lines = &.{"aaaa"},
        .cursor = .{ 0, 4 },
        .used = 1,
    },
    .{
        .name = "zero and missing REP params repeat once",
        .input = "a\x1b[0b\x1b[b",
        .lines = &.{"aaa"},
        .cursor = .{ 0, 3 },
        .used = 1,
    },
    .{
        .name = "REP with no prior print is a no-op",
        .input = "\x1b[3bX",
        .lines = &.{"X"},
        .cursor = .{ 0, 1 },
        .used = 1,
    },
    .{
        // Stream state, not cell state: a cursor motion between the print
        // and the REP does not reset it, and the repeats land at the
        // cursor, not behind it.
        .name = "REP survives a cursor motion",
        .input = "a\x1b[5C\x1b[2b",
        .lines = &.{"a     aa"},
        .cursor = .{ 0, 8 },
        .used = 1,
    },
    .{
        // xterm behaviour, pinned on purpose: the pending wrap fires on
        // the FIRST repeat (REP routes through putRune, never a direct
        // cell write).
        .name = "REP with a pending wrap wraps on the first repeat",
        .input = &a80 ++ "\x1b[3b",
        .lines = &.{ &a80, "aaa" },
        .cursor = .{ 1, 3 },
        .used = 2,
    },
    .{
        .name = "REP repeats a wide rune as a whole pair",
        .input = "\xe4\xbd\xa0\x1b[2b",
        .lines = &.{"\x00\x00\x00\x00\x00\x00"},
        .cursor = .{ 0, 6 },
        .used = 1,
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 0x4F60 },
            .{ .row = 0, .col = 2, .base = 0x4F60 },
            .{ .row = 0, .col = 3, .base = ' ', .cont = 1 },
            .{ .row = 0, .col = 4, .base = 0x4F60 },
            .{ .row = 0, .col = 5, .base = ' ', .cont = 1 },
        },
    },
    .{
        // REP re-places the stored rune VERBATIM: its stored rendition
        // wins over the current one (the truecolour side channels follow
        // the current state, like any placement).
        .name = "REP repeats the stored rendition, not the current one",
        .input = "\x1b[31mz\x1b[0m\x1b[2b",
        .lines = &.{"zzz"},
        .cursor = .{ 0, 3 },
        .used = 1,
        .styles = &.{
            .{ .row = 0, .col = 0, .fg = 1 },
            .{ .row = 0, .col = 1, .fg = 1 },
            .{ .row = 0, .col = 2, .fg = 1 },
        },
    },
    .{
        .name = "ED 2 clears the grid, homes the cursor, used = 1",
        .input = "HELLO\x1b[2J",
        .lines = &.{""},
        .cursor = .{ 0, 0 },
        .used = 1,
    },
    .{
        // ED 0: cursor-to-end of the current row, then every row below.
        .name = "ED 0 erases from the cursor down",
        .input = "AB\r\nCD\x1b[1;2H\x1b[J",
        .lines = &.{ "A", "" },
        .cursor = .{ 0, 1 },
        .used = 2,
    },
    .{
        // ED 1: every row above, then start-of-row through the cursor
        // (cursor INCLUSIVE). Row 1's lens is untouched by design — the
        // line() length stays 2 and the cleared cells project as spaces.
        .name = "ED 1 erases from the top through the cursor",
        .input = "AB\r\nCD\x1b[2;2H\x1b[1J",
        .lines = &.{ "", "  " },
        .cursor = .{ 1, 1 },
        .used = 2,
    },
    .{
        .name = "EL 0 erases from the cursor to the right margin",
        .input = "ABCDEFG\x1b[1;4H\x1b[K",
        .lines = &.{"ABC"},
        .cursor = .{ 0, 3 },
    },
    .{
        .name = "EL 1 erases start-of-row through the cursor",
        .input = "ABCD\x1b[1;3H\x1b[1K",
        .lines = &.{"   D"},
        .cursor = .{ 0, 2 },
    },
    .{
        .name = "EL 2 erases the whole row (length drops to 0)",
        .input = "ABC\x1b[2K",
        .lines = &.{""},
        .cursor = .{ 0, 3 },
    },
    // ---- M80b (#1713): insert/delete/erase finals — chars @/P/X, lines
    // L/M, scroll S/T, and ED 3. Blanks are the erase default (empty
    // cell + default rendition — the grid erases to the default, never
    // the current SGR); moved cells carry their own rendition with them.
    // The cursor is never touched except IL/DL, which take it to the
    // left margin (xterm's VT102-compatible IL/DL — xterm changelog:
    // "modify IL/DL to set cursor to first column on row"). A row edit
    // at a pending wrap (col == cols) acts on the last column (BS
    // parity), and an edit below the used tail is a no-op (the M80a
    // rule: a row materialises on write, never on edit).
    .{
        .name = "ICH (@) inserts blanks at the cursor and slides the tail right",
        .input = "abcdef\x1b[1;3H\x1b[2@",
        .lines = &.{"ab  cdef"},
        .cursor = .{ 0, 2 },
    },
    .{
        .name = "ICH drops cells past the right margin",
        .input = &a79 ++ "Z\x1b[1;1H\x1b[3@",
        .lines = &.{&spaces3_a77},
        .cursor = .{ 0, 0 },
    },
    .{
        .name = "zero and missing ICH params insert one blank",
        .input = "abcd\x1b[1;2H\x1b[0@\x1b[@",
        .lines = &.{"a  bcd"},
        .cursor = .{ 0, 1 },
    },
    .{
        // The slide moves stored renditions with their cells; the
        // inserted blank is default-styled (an erase default, not BCE).
        .name = "ICH slides stored renditions right; the blank is default",
        .input = "\x1b[31mabc\x1b[0m\x1b[1;2H\x1b[1@",
        .lines = &.{"a bc"},
        .cursor = .{ 0, 1 },
        .styles = &.{
            .{ .row = 0, .col = 0, .fg = 1 },
            .{ .row = 0, .col = 1, .default_exact = true },
            .{ .row = 0, .col = 2, .fg = 1 },
            .{ .row = 0, .col = 3, .fg = 1 },
        },
    },
    .{
        // House rule (M73a-1): the slide never splits a wide pair — the
        // insert point steps back to the pair's base so it moves whole.
        .name = "ICH slides a straddling wide pair as a whole",
        .input = "A\xe4\xbd\xa0B\x1b[1;2H\x1b[1@",
        .lines = &.{"A \x00\x00B"},
        .cursor = .{ 0, 1 },
        .cells = &.{
            .{ .row = 0, .col = 1, .base = ' ' },
            .{ .row = 0, .col = 2, .base = 0x4F60 },
            .{ .row = 0, .col = 3, .base = ' ', .cont = 1 },
            .{ .row = 0, .col = 4, .base = 'B' },
        },
    },
    .{
        .name = "DCH (P) deletes chars at the cursor and pulls the tail left",
        .input = "abcdef\x1b[1;3H\x1b[2P",
        .lines = &.{"abef"},
        .cursor = .{ 0, 2 },
    },
    .{
        .name = "DCH past the row end shortens the line to the cursor",
        .input = "abcdef\x1b[1;5H\x1b[4P",
        .lines = &.{"abcd"},
        .cursor = .{ 0, 4 },
    },
    .{
        .name = "zero and missing DCH params delete one char",
        .input = "abc\x1b[1;2H\x1b[0P\x1b[P",
        .lines = &.{"a"},
        .cursor = .{ 0, 1 },
    },
    .{
        // A delete range that would split a wide pair extends over the
        // pair edge (eraseLine's rule) — the pair goes WHOLE.
        .name = "DCH deletes a straddling wide pair whole",
        .input = "A\xe4\xbd\xa0B\x1b[1;2H\x1b[1P",
        .lines = &.{"AB"},
        .cursor = .{ 0, 1 },
    },
    .{
        .name = "DCH at a pair's continuation deletes the pair whole",
        .input = "A\xe4\xbd\xa0B\x1b[1;3H\x1b[1P",
        .lines = &.{"AB"},
        .cursor = .{ 0, 2 },
    },
    .{
        .name = "ECH (X) erases cells in place without shifting the tail",
        .input = "abcdef\x1b[1;3H\x1b[2X",
        .lines = &.{"ab  ef"},
        .cursor = .{ 0, 2 },
    },
    .{
        .name = "ECH to the row end trims the line length",
        .input = "abcdef\x1b[1;4H\x1b[9X",
        .lines = &.{"abc"},
        .cursor = .{ 0, 3 },
    },
    .{
        // Two ECHs at the same un-moving cursor erase the same cell.
        .name = "zero and missing ECH params erase one cell; the cursor stays",
        .input = "abcdef\x1b[1;3H\x1b[0X\x1b[X",
        .lines = &.{"ab def"},
        .cursor = .{ 0, 2 },
    },
    .{
        .name = "ECH erases a straddling wide pair whole",
        .input = "A\xe4\xbd\xa0B\x1b[1;2H\x1b[1X",
        .lines = &.{"A  B"},
        .cursor = .{ 0, 1 },
    },
    .{
        // A row edit from a pending wrap acts on the LAST column and
        // resolves the wrap (BS parity) — the edit itself never wraps.
        .name = "ECH from a pending wrap edits the last column",
        .input = &a80 ++ "\x1b[2X",
        .lines = &.{&a79},
        .cursor = .{ 0, 79 },
        .used = 1,
    },
    .{
        .name = "ICH below the used tail is a no-op",
        .input = "\x1b[3B\x1b[2@",
        .cursor = .{ 3, 0 },
        .used = 1,
    },
    .{
        .name = "IL (L) inserts a blank line at the cursor and pushes rows down",
        .input = "AA\r\nBB\r\nCC\x1b[2;1H\x1b[L",
        .lines = &.{ "AA", "", "BB", "CC" },
        .cursor = .{ 1, 0 },
        .used = 4,
    },
    .{
        // Rows pushed past the bottom of the grid are dropped (no
        // scrollback for the bottom edge) — one row survives onto the
        // last grid line.
        .name = "IL past the bottom of the grid drops the pushed rows",
        .input = "AA\r\nBB\x1b[2;1H\x1b[126L",
        .lines = &.{"AA"},
        .cursor = .{ 1, 0 },
        .used = 128,
        .cells = &.{
            .{ .row = 127, .col = 0, .base = 'B' },
            .{ .row = 127, .col = 1, .base = 'B' },
        },
    },
    .{
        .name = "IL below the used tail is a no-op",
        .input = "\x1b[3B\x1b[2L",
        .cursor = .{ 3, 0 },
        .used = 1,
    },
    .{
        .name = "DL (M) deletes lines at the cursor and pulls rows up",
        .input = "AA\r\nBB\r\nCC\x1b[2;1H\x1b[M",
        .lines = &.{ "AA", "CC" },
        .cursor = .{ 1, 0 },
        .used = 2,
    },
    .{
        .name = "DL past the bottom empties the rows at and below the cursor",
        .input = "AA\r\nBB\x1b[1;1H\x1b[999M",
        .lines = &.{""},
        .cursor = .{ 0, 0 },
        .used = 1,
    },
    .{
        .name = "zero and missing DL params delete one line",
        .input = "AA\r\nBB\r\nCC\x1b[2;1H\x1b[0M\x1b[M",
        .lines = &.{"AA"},
        .cursor = .{ 1, 0 },
        .used = 1,
    },
    .{
        .name = "SU (S) scrolls the grid up and drops the top row",
        .input = "AA\r\nBB\r\nCC\x1b[S",
        .lines = &.{ "BB", "CC" },
        .cursor = .{ 2, 2 },
        .used = 2,
    },
    .{
        .name = "zero and missing SU params scroll one row",
        .input = "AA\r\nBB\r\nCC\r\nDD\x1b[0S\x1b[S",
        .lines = &.{ "CC", "DD" },
        .cursor = .{ 3, 2 },
        .used = 2,
    },
    .{
        // xterm: SU/SD never touch the cursor — a pending wrap survives
        // (only IL/DL take the cursor to the left margin).
        .name = "SU from a pending wrap leaves the cursor put",
        .input = &a80 ++ "\x1b[S",
        .lines = &.{""},
        .cursor = .{ 0, 80 },
        .used = 1,
    },
    .{
        .name = "SD (T) scrolls the grid down and inserts a blank top row",
        .input = "AA\r\nBB\x1b[T",
        .lines = &.{ "", "AA", "BB" },
        .cursor = .{ 1, 2 },
        .used = 3,
    },
    .{
        .name = "zero and missing SD params scroll one row",
        .input = "AA\r\nBB\x1b[0T\x1b[T\x1b[T",
        .lines = &.{ "", "", "", "AA", "BB" },
        .cursor = .{ 1, 2 },
        .used = 5,
    },
    .{
        // CSI Ps;Ps;Ps;Ps;Ps T is XTHIMOUSE (highlight tracking), not SD
        // — unsupported here, so consumed and never painted (M80 rule).
        .name = "five-parameter CSI T is XTHIMOUSE — consumed, never painted",
        .input = "AA\x1b[1;2;3;4;5T",
        .lines = &.{"AA"},
        .cursor = .{ 0, 2 },
        .used = 1,
    },
    .{
        // ED 3 is "Erase Saved Lines" (xterm ctlseqs #411): the grid and
        // the cursor are untouched. The history half is pinned by
        // registry tests in terminal.zig — a corpus Screen has no bank.
        .name = "ED 3 leaves the grid and the cursor untouched",
        .input = "HELLO\x1b[1;3H\x1b[3J",
        .lines = &.{"HELLO"},
        .cursor = .{ 0, 2 },
        .used = 1,
    },
};

test "terminal corpus: CSI cursor positioning and erase" {
    try runAll(&csi_cases);
}

// ---------------------------------------------------------------------------
// M80c (#1714) — DECSTBM, DECOM, and VT-correct pending-wrap/DECAWM.
// ---------------------------------------------------------------------------

const m80c_cases = [_]Case{
    .{
        .name = "an invalid DECSTBM region is refused and preserves the old margins",
        .input = "\x1b[3;5r\x1b[5;5r\x1b[5;1HA",
        .lines = &.{ "", "", "", "", "A" },
        .cursor = .{ 4, 1 },
        .used = 5,
    },
    .{
        .name = "CSI r with no parameters restores the full-screen region",
        .input = "\x1b[3;5r\x1b[2;3r\x1b[r\x1b[5;1HA",
        .lines = &.{ "", "", "", "", "A" },
        .cursor = .{ 4, 1 },
        .used = 5,
    },
    .{
        .name = "LF at a DECSTBM bottom scrolls only the region",
        .input = "0\r\n1\r\n2\r\n3\r\n4\x1b[3;5r\x1b[5;1H\nZ",
        .lines = &.{ "0", "1", "3", "4", "Z" },
        .cursor = .{ 4, 1 },
        .used = 5,
    },
    .{
        .name = "a soft wrap at a DECSTBM bottom scrolls the region, not the full grid",
        .input = "\x1b[2;3r\x1b[3;1H" ++ &a80 ++ "X",
        .lines = &.{ "", &a80, "X" },
        .cursor = .{ 2, 1 },
        .used = 3,
    },
    .{
        .name = "DECOM makes H and VPA region-relative and clamps at its bottom",
        .input = "\x1b[3;5r\x1b[?6h\x1b[1;1HA\x1b[2d\x1b[1GB\x1b[99;1HC",
        .lines = &.{ "", "", "A", "B", "C" },
        .cursor = .{ 4, 1 },
        .used = 5,
    },
    .{
        .name = "DECAWM disabled makes the next write overwrite the last column",
        .input = &a80 ++ "\x1b[?7lX",
        .lines = &.{(repeat_lit("a", 79)) ++ "X"},
        .cursor = .{ 0, 79 },
        .used = 1,
    },
    .{
        .name = "SGR resolves a pending wrap before the next write",
        .input = &a80 ++ "\x1b[31mX",
        .lines = &.{(repeat_lit("a", 79)) ++ "X"},
        .cursor = .{ 0, 80 },
        .used = 1,
        .rendition = .{ .fg = 1 },
        .styles = &.{.{ .row = 0, .col = 79, .fg = 1 }},
    },
    .{
        .name = "soft reset also resolves a pending wrap",
        .input = &a80 ++ "\x1b[!pX",
        .lines = &.{(repeat_lit("a", 79)) ++ "X"},
        .cursor = .{ 0, 80 },
        .used = 1,
    },
    .{
        .name = "RIS restores full-screen margins, origin mode, and autowrap",
        .input = "\x1b[3;5r\x1b[?6h\x1b[?7l\x1bc\x1b[5;1HX",
        .lines = &.{ "", "", "", "", "X" },
        .cursor = .{ 4, 1 },
        .used = 5,
    },
    .{
        .name = "alternate-screen margins do not replace the primary margins",
        .input = "0\r\n1\r\n2\r\n3\r\n4\x1b[3;5r\x1b[?1049h\x1b[2;4r\x1b[?1049l\x1b[5;1H\nZ",
        .lines = &.{ "0", "1", "3", "4", "Z" },
        .cursor = .{ 4, 1 },
        .used = 5,
        .alt = false,
    },
};

test "terminal corpus: M80c scroll region, origin mode, and autowrap" {
    try runAll(&m80c_cases);
}

test "terminal corpus: resize drops tab stops and does not restore them (#1721)" {
    var s: t.Screen = .{};
    s.feed("\x1b[1;13H\x1bH");
    try std.testing.expectEqual(@as(usize, 10), s.setCols(10));
    try std.testing.expectEqual(@as(usize, 80), s.setCols(80));
    s.feed("\x1b[H\tZ");
    try std.testing.expectEqualStrings("        Z", s.line(0));
    try std.testing.expectEqual(@as(usize, 9), s.cursorCol());
}

test "terminal corpus: tab stops round-trip with the alternate screen (#1721)" {
    var s: t.Screen = .{};
    s.feed("\x1b[1;13H\x1bH\x1b[?1049h\x1b[3g");
    s.feed("\x1b[?1049l\x1b[1;10H\tZ");
    try std.testing.expectEqualStrings("            Z", s.line(0));
    s.feed("\x1b[?1049h\x1b[1;3H\tX");
    try std.testing.expectEqualStrings("        X", s.line(0));
}

// ---------------------------------------------------------------------------
// Group D — SGR renditions. The M72b 16-colour contract is frozen: any row
// here changing means the freeze broke.
// ---------------------------------------------------------------------------

const sgr_cases = [_]Case{
    .{
        .name = "SGR fg/bg set, SGR 0 resets the whole rendition",
        .input = "\x1b[31;42mA\x1b[0mB",
        .lines = &.{"AB"},
        .cursor = .{ 0, 2 },
        .styles = &.{
            .{ .row = 0, .col = 0, .fg = 1, .bg = 2 },
            .{ .row = 0, .col = 1 },
        },
        .rendition = .{},
    },
    .{
        .name = "SGR 1 sets bold, SGR 22 clears it",
        .input = "\x1b[1mA\x1b[22mB",
        .lines = &.{"AB"},
        .cursor = .{ 0, 2 },
        .styles = &.{
            .{ .row = 0, .col = 0, .bold = true },
            .{ .row = 0, .col = 1 },
        },
        .rendition = .{},
    },
    .{
        .name = "bright fg 90-97 / bright bg 100-107 map to indices 8-15",
        .input = "\x1b[91;104mX",
        .lines = &.{"X"},
        .cursor = .{ 0, 1 },
        .styles = &.{.{ .row = 0, .col = 0, .fg = 9, .bg = 12 }},
    },
    .{
        .name = "SGR 39/49 restore the default colours",
        .input = "\x1b[32;43mA\x1b[39;49mB",
        .lines = &.{"AB"},
        .cursor = .{ 0, 2 },
        .styles = &.{
            .{ .row = 0, .col = 0, .fg = 2, .bg = 3 },
            .{ .row = 0, .col = 1 },
        },
    },
    .{
        // Deliverable pin: "SGR reset -> default_cell_style", byte-exact.
        .name = "SGR reset yields default_cell_style exactly",
        .input = "\x1b[1;34;45mA\x1b[mB",
        .lines = &.{"AB"},
        .cursor = .{ 0, 2 },
        .styles = &.{
            .{ .row = 0, .col = 0, .fg = 4, .bg = 5, .bold = true },
            .{ .row = 0, .col = 1, .default_exact = true },
        },
        .rendition = .{},
    },
    .{
        // REWRITTEN BY M73h — the contract in action. The old row pinned
        // `4` and `38;5;99` as ignored; now `4` sets the underline flag
        // and `38;5;99` stores index 99. Params still without an arm
        // (bare 5/6 flicker, 99) remain consumed-and-ignored — see the
        // SGR-depth group.
        .name = "4 sets underline and 38;5;99 stores index 99 (M73h flip)",
        .input = "\x1b[4;38;5;99mA",
        .lines = &.{"A"},
        .cursor = .{ 0, 1 },
        .styles = &.{.{ .row = 0, .col = 0, .fg = 99, .underline = true }},
        .rendition = .{ .fg = 99 },
    },
};

test "terminal corpus: SGR renditions (16-colour frozen)" {
    try runAll(&sgr_cases);
}

// ---------------------------------------------------------------------------
// Group E — modes: the alternate screen (DECSET 47/1049) and DECTCEM (?25).
// Private modes without an arm are consumed, never painted.
// ---------------------------------------------------------------------------

const mode_cases = [_]Case{
    .{
        // Enter clears the swapped-in grid; exit swaps the primary back
        // UNCHANGED, cursor position included — "MORE" continues after
        // "MAIN", proving col 4 was preserved across the round trip.
        .name = "alternate round trip preserves the primary grid and cursor",
        .input = "MAIN\x1b[?1049hALT\x1b[?1049lMORE",
        .lines = &.{"MAINMORE"},
        .cursor = .{ 0, 8 },
        .used = 1,
        .alt = false,
    },
    .{
        // DECRST swapped the primary back into storage; the next DECSET
        // swaps again and CLEARS the active grid (the field doc's
        // contract): stale alternate content does not survive an exit.
        // The primary "MAIN" now sits in the inactive storage, invisible
        // until the next exit.
        .name = "re-entering starts a fresh cleared alternate grid",
        .input = "MAIN\x1b[?1049hALT\x1b[?1049l\x1b[?1049h",
        .lines = &.{""},
        .cursor = .{ 0, 0 },
        .used = 1,
        .alt = true,
    },
    .{
        // alt_active == enabled is a no-op: a second ?1049h must NOT
        // re-clear the active alternate grid.
        .name = "a second enter of the same mode does not re-clear",
        .input = "\x1b[?1049hB\x1b[?1049hC",
        .lines = &.{"BC"},
        .cursor = .{ 0, 2 },
        .alt = true,
    },
    .{
        .name = "DECSET 47 aliases 1049 and exits mix freely",
        .input = "\x1b[?47hX\x1b[?1049lY",
        .lines = &.{"Y"},
        .cursor = .{ 0, 1 },
        .alt = false,
    },
    .{
        .name = "DECTCEM hide (?25l) drops the painted cursor",
        .input = "\x1b[?25l",
        .cursor = .{ 0, 0 },
        .visible = false,
    },
    .{
        .name = "DECTCEM show (?25h) restores it",
        .input = "\x1b[?25lA\x1b[?25h",
        .lines = &.{"A"},
        .visible = true,
    },
    .{
        // cursor_visible is a terminal-mode bit: it is NOT part of the
        // alternate-screen swap, so hiding before the trip stays hidden.
        .name = "cursor visibility survives an alternate round trip",
        .input = "X\x1b[?25l\x1b[?1049h\x1b[?1049l",
        .lines = &.{"X"},
        .cursor = .{ 0, 1 },
        .visible = false,
        .alt = false,
    },
    .{
        // A private mode with no grid arm is consumed and paints nothing.
        // ?2004 (bracketed paste) has terminal-object state since M73e but
        // is grid-invisible here.
        .name = "private mode with object state is consumed, grid untouched (M73e)",
        .input = "\x1b[?2004hA",
        .lines = &.{"A"},
        .cursor = .{ 0, 1 },
        .visible = true,
        .alt = false,
        .rendition = .{},
    },
    .{
        // M73i: all four mouse DECSET modes are consumed and never paint.
        // The flags themselves are pinned in terminal.zig's mode-table test
        // (mouse DECSET modes track independently, default off).
        .name = "mouse tracking modes are consumed, grid untouched (M73i)",
        .input = "\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006hM\n" ++
            "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l!",
        .lines = &.{ "M", "!" },
        .cursor = .{ 1, 1 },
        .visible = true,
        .alt = false,
        .rendition = .{},
    },
};

test "terminal corpus: modes — alternate screen and DECTCEM" {
    try runAll(&mode_cases);
}

// ---------------------------------------------------------------------------
// Group F — ESC and CSI policy pins.
// ---------------------------------------------------------------------------

const esc_cases = [_]Case{
    .{
        .name = "ESC followed by a non-[ byte consumes exactly that byte",
        // M85a (#1813) deliberate flip: `X` (SOS) is now an ESC *string*
        // introducer, consumed through ST (pinned in the image-intake
        // group). The row keeps its intent — an unknown plain final
        // consumes exactly the ESC + final — on `V` (SPA, a no-op final
        // here).
        .input = "\x1bVabc",
        .lines = &.{"abc"},
        .cursor = .{ 0, 3 },
    },
    .{
        .name = "ESC 7/8 save and restore cursor and rendition",
        .input = "AB\x1b[31m\x1b7\x1b[0m\x1b[2;3HC\x1b8D",
        .lines = &.{ "ABD", "  C" },
        .cursor = .{ 0, 3 },
        .rendition = .{ .fg = 1 },
        .styles = &.{
            .{ .row = 0, .col = 2, .fg = 1 },
            .{ .row = 1, .col = 2, .default_exact = true },
        },
    },
    .{
        .name = "DECSC/DECRC restores the G0 line-drawing designation",
        .input = "\x1b(0q\x1b7\x1b(B\x1b8q",
        .lines = &.{"\x00\x00"},
        .cursor = .{ 0, 2 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 0x2500 },
            .{ .row = 0, .col = 1, .base = 0x2500 },
        },
    },
    .{
        .name = "G0 line drawing maps box runes and SI returns to ASCII",
        .input = "\x1b(0lqkxm\x0fZ",
        .lines = &.{"\x00\x00\x00\x00\x00Z"},
        .cursor = .{ 0, 6 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 0x250c },
            .{ .row = 0, .col = 1, .base = 0x2500 },
            .{ .row = 0, .col = 2, .base = 0x2510 },
            .{ .row = 0, .col = 3, .base = 0x2502 },
            .{ .row = 0, .col = 4, .base = 0x2514 },
        },
    },
    .{
        .name = "SO invokes G1 line drawing and SI returns to ASCII",
        .input = "\x1b)0\x0elqkxm\x0fZ",
        .lines = &.{"\x00\x00\x00\x00\x00Z"},
        .cursor = .{ 0, 6 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 0x250c },
            .{ .row = 0, .col = 1, .base = 0x2500 },
            .{ .row = 0, .col = 2, .base = 0x2510 },
            .{ .row = 0, .col = 3, .base = 0x2502 },
            .{ .row = 0, .col = 4, .base = 0x2514 },
        },
    },
    .{
        .name = "IND moves down without a carriage return",
        .input = "AB\x1bD C",
        .lines = &.{ "AB", "   C" },
        .cursor = .{ 1, 4 },
        .used = 2,
    },
    .{
        .name = "NEL performs a carriage return and index",
        .input = "AB\x1bE C",
        .lines = &.{ "AB", " C" },
        .cursor = .{ 1, 2 },
        .used = 2,
    },
    .{
        .name = "RI moves up without changing the column",
        .input = "A\r\nB\x1bM C",
        .lines = &.{ "A C", "B" },
        .cursor = .{ 0, 3 },
        .used = 2,
    },
    .{
        .name = "RI at the top edge scrolls the grid down",
        .input = "A\x1bM B",
        .lines = &.{ "  B", "A" },
        .cursor = .{ 0, 3 },
        .used = 2,
    },
    .{
        .name = "keypad modes are consumed and never painted",
        .input = "\x1b=X\x1b>Y",
        .lines = &.{"XY"},
        .cursor = .{ 0, 2 },
        .keypad = false,
    },
    .{
        .name = "soft reset restores modes and style but not the grid",
        .input = "\x1b[31mA\x1b[?25l\x1b[?2004h\x1b[?1000h\x1b(0q\x1b[!pBq",
        .lines = &.{"A\x00Bq"},
        .cursor = .{ 0, 4 },
        .visible = true,
        .rendition = .{},
        .keypad = false,
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 'A' },
            .{ .row = 0, .col = 1, .base = 0x2500 },
            .{ .row = 0, .col = 2, .base = 'B' },
            .{ .row = 0, .col = 3, .base = 'q' },
        },
        .styles = &.{
            .{ .row = 0, .col = 0, .fg = 1 },
            .{ .row = 0, .col = 1, .fg = 1 },
            .{ .row = 0, .col = 2, .default_exact = true },
            .{ .row = 0, .col = 3, .default_exact = true },
        },
    },
    .{
        .name = "RIS clears the grid and restores modes, style, and charset",
        .input = "\x1b[31mA\x1b[?25l\x1b[?2004h\x1b[?1000h\x1b(0q\x1b=\x1bcBq",
        .lines = &.{"Bq"},
        .cursor = .{ 0, 2 },
        .visible = true,
        .rendition = .{},
        .keypad = false,
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 'B' },
            .{ .row = 0, .col = 1, .base = 'q' },
        },
    },
    .{
        .name = "an unknown CSI final is consumed, never printed",
        .input = "\x1b[3ZX",
        .lines = &.{"X"},
        .cursor = .{ 0, 1 },
    },
    .{
        // M182a (#3150) rename, same pin: 0x3c-0x3f are now private
        // markers, and an intermediate disarms every arm but DECSTR's —
        // `CSI ! p` is exactly that check.
        .name = "CSI ! p is DECSTR — the one armed intermediate form",
        .input = "\x1b[!pX",
        .lines = &.{"X"},
        .cursor = .{ 0, 1 },
    },
    // M182a (#3150): '<' '=' '>' '?' are ECMA-48 private-parameter
    // markers. Only '?' has arms here; the other markers swallow the
    // sequence whole — no paint and no reply (DA2's `CSI > c` included,
    // D17). A marker after the first parameter byte, or a second marker,
    // malforms the sequence: consumed to the final byte, nothing acts.
    .{
        .name = "CSI > m marks a private sequence — its SGR never lands",
        .input = "\x1b[>4;1mX",
        .lines = &.{"X"},
        .cursor = .{ 0, 1 },
        .rendition = .{},
        .styles = &.{.{ .row = 0, .col = 0, .default_exact = true }},
    },
    .{
        .name = "CSI > c, CSI = c, and CSI < u paint nothing",
        .input = "\x1b[>c\x1b[=c\x1b[<uX",
        .lines = &.{"X"},
        .cursor = .{ 0, 1 },
    },
    .{
        .name = "a private marker after the first parameter byte is malformed",
        .input = "\x1b[?25l\x1b[1?hX",
        .lines = &.{"X"},
        .cursor = .{ 0, 1 },
        .visible = false,
    },
    .{
        .name = "a second private marker is malformed — the mode arms never run",
        .input = "\x1b[??25lX",
        .lines = &.{"X"},
        .cursor = .{ 0, 1 },
        .visible = true,
    },
    .{
        .name = "CSI ? 1049 h still switches to the alternate screen",
        .input = "MAIN\x1b[?1049hALT",
        .lines = &.{"ALT"},
        .cursor = .{ 0, 3 },
        .alt = true,
    },
};

test "terminal corpus: ESC and CSI policy pins" {
    try runAll(&esc_cases);
}

// ---------------------------------------------------------------------------
// M80g (#1715) — OSC: window titles (Ps 0/2) and the OSC 52 clipboard.
// OSC strings are consumed, never painted — these rows pin the side queue
// (`title`/`clip`) and the grid's innocence. Delivery (window buffer, seat
// kind-11 frame, clipboard bridge) is registry-tested in terminal.zig; a
// corpus Screen has no pump.
// ---------------------------------------------------------------------------

const osc_cases = [_]Case{
    .{
        .name = "OSC 0 sets the window title and paints nothing",
        .input = "\x1b]0;desk\x07A",
        .lines = &.{"A"},
        .cursor = .{ 0, 1 },
        .title = "desk",
    },
    .{
        .name = "OSC 2 sets the title; ST (ESC \\) terminates it",
        .input = "\x1b]2;edit\x1b\\B",
        .lines = &.{"B"},
        .cursor = .{ 0, 1 },
        .title = "edit",
    },
    .{
        .name = "OSC 1/7/10 and a numberless string are consumed, never painted",
        .input = "\x1b]1;icon\x07\x1b]7;cwd\x07\x1b]10;?\x07\x1b];p\x07C",
        .lines = &.{"C"},
        .cursor = .{ 0, 1 },
        .title = "",
    },
    .{
        .name = "an empty title is refused: a tab keeps its name",
        .input = "\x1b]2;keep\x07\x1b]0;\x07",
        .title = "keep",
    },
    .{
        .name = "a title is truncated honestly at title_max",
        .input = "\x1b]2;" ++ &t70 ++ "\x07",
        .title = t70[0..64],
    },
    .{
        .name = "an over-bound unterminated OSC is dropped whole; text resumes",
        .input = "\x1b]0;" ++ &x780 ++ "\x07D",
        .lines = &.{"D"},
        .cursor = .{ 0, 1 },
        .title = "",
    },
    .{
        .name = "OSC 52 c;base64 queues the decoded clipboard bytes",
        .input = "\x1b]52;c;aGVsbG8=\x07E",
        .lines = &.{"E"},
        .cursor = .{ 0, 1 },
        .clip = "hello",
    },
    .{
        .name = "an OSC 52 read query is refused: no copy, never painted",
        .input = "\x1b]52;c;?\x07F",
        .lines = &.{"F"},
        .cursor = .{ 0, 1 },
        .clip = "",
    },
    .{
        .name = "OSC 52 to a non-clipboard target is dropped",
        .input = "\x1b]52;p;aGVsbG8=\x07",
        .clip = "",
    },
    .{
        .name = "invalid base64 is refused whole: no partial copy",
        .input = "\x1b]52;c;aG!sbG8=\x07",
        .clip = "",
    },
    .{
        .name = "ESC inside an OSC aborts it; the escape final still runs",
        .input = "\x1b]2;title\x1bEG",
        .lines = &.{ "", "G" },
        .cursor = .{ 1, 1 },
        .title = "",
    },
    .{
        .name = "CAN aborts an OSC mid-payload; the next byte prints",
        .input = "\x1b]2;t\x18H",
        .lines = &.{"H"},
        .cursor = .{ 0, 1 },
        .title = "",
    },
};

test "terminal corpus: OSC window titles and clipboard (M80g #1715)" {
    try runAll(&osc_cases);
}

// ---------------------------------------------------------------------------
// M85a (#1813) — image-sequence intake: DCS/sixel and the "consumed, never
// painted" rule. Protocol pick (recorded on the M85a claim): **sixel is
// PRIMARY** — the seam is cell-native (the kernel painter composites cell
// fills + glyphs into the window buffer), so pixels that ride the grid are
// the shape that fits; kitty's channel (APC and OSC 1337) stays a pinned
// drain until a layer seam exists. M85b (#1814) flipped the capture rows
// here (see the header contract): a valid payload now PLACES an image.
// ---------------------------------------------------------------------------

const sixel_cases = [_]Case{
    .{
        .name = "DCS q (sixel) decodes and places at the string's origin; the cursor lands below",
        .input = "A\x1bP1;2;3q#0~~??\x1b\\B",
        // `#0~~??` is two full columns of register 0 (VT340 black): a 2x6
        // image, one cell at the origin. The cursor goes to the left
        // margin of the next line, where `B` prints.
        .lines = &.{ "A ", "B" },
        .cursor = .{ 1, 1 },
        .sixel_p = .{ 1, 2, 3 },
        .sixel_overflow = false,
        .sixel_origin = .{ 0, 1 },
        .images = .{ 1, 0, 0 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 'A' },
            .{ .row = 0, .col = 1, .tile = .{ 0, 0 } },
            .{ .row = 1, .col = 0, .base = 'B' },
        },
        .pixels = &.{
            .{ .row = 0, .col = 1, .dx = 1, .dy = 5, .rgb = 0x000000 },
            .{ .row = 0, .col = 1, .dx = 2, .dy = 0, .rgb = null },
            .{ .row = 0, .col = 1, .dx = 0, .dy = 6, .rgb = null },
        },
    },
    .{
        .name = "params beyond three DCS Ps are consumed, never parsed",
        .input = "\x1bP1;2;3;4qz\x1b\\",
        // `z` = 59 = bits 0,1,3,4,5: a 1x6 image with row 2 unset.
        .sixel_p = .{ 1, 2, 3 },
        .cursor = .{ 1, 0 },
        .images = .{ 1, 0, 0 },
        .cells = &.{.{ .row = 0, .col = 0, .tile = .{ 0, 0 } }},
        .pixels = &.{
            .{ .row = 0, .col = 0, .dy = 1, .rgb = 0x000000 },
            .{ .row = 0, .col = 0, .dy = 2, .rgb = null },
            .{ .row = 0, .col = 0, .dy = 3, .rgb = 0x000000 },
        },
    },
    .{
        .name = "an empty sixel payload places nothing and is not a refusal",
        .input = "\x1bP0;0q\x1b\\",
        .lines = &.{""},
        .cursor = .{ 0, 0 },
        .sixel_overflow = false,
        .images = .{ 0, 0, 0 },
    },
    .{
        .name = "a non-q DCS final is consumed, never painted, and decodes nothing",
        .input = "A\x1bP1;2;3pDATA\x1b\\B",
        .lines = &.{"AB"},
        .cursor = .{ 0, 2 },
        .images = .{ 0, 0, 0 },
    },
    .{
        .name = "APC (kitty's channel), SOS and PM strings are consumed, never painted",
        .input = "\x1b_Gm=1;aAA\x1b\\\x1bXsos\x1b\\\x1b^pm\x1b\\C",
        .lines = &.{"C"},
        .cursor = .{ 0, 1 },
        .images = .{ 0, 0, 0 },
    },
    .{
        .name = "OSC 1337 (kitty graphics) is consumed by the OSC path, never painted",
        .input = "\x1b]1337;File=AAAA\x07D",
        .lines = &.{"D"},
        .cursor = .{ 0, 1 },
        .images = .{ 0, 0, 0 },
    },
    .{
        .name = "a sixel wider than term_image.max_w is refused WHOLE; the grid is innocent",
        .input = "\x1bP0;0;0q" ++ &s4097 ++ "\x1b\\B",
        .lines = &.{"B"},
        .cursor = .{ 0, 1 },
        .sixel_overflow = true,
        .images = .{ 0, 1, 0 },
        .cells = &.{.{ .row = 0, .col = 1 }},
    },
    .{
        .name = "an unterminated string stays pending: nothing placed, grid innocent",
        .input = "A\x1bP1;2;3q~~",
        .lines = &.{"A"},
        .cursor = .{ 0, 1 },
        .images = .{ 0, 0, 0 },
        .cells = &.{.{ .row = 0, .col = 1 }},
    },
    .{
        .name = "CAN aborts the decode whole; the next byte prints",
        .input = "\x1bP0;0;0q~~\x18C",
        .lines = &.{"C"},
        .cursor = .{ 0, 1 },
        .images = .{ 0, 0, 0 },
    },
    .{
        .name = "an ESC that does not complete ST aborts and the escape final runs",
        .input = "\x1bP0;0;0q~~\x1bED",
        .lines = &.{ "", "D" },
        .cursor = .{ 1, 1 },
        .images = .{ 0, 0, 0 },
    },
};

test "terminal corpus: DCS/sixel intake and the image-sequence rule (M85a #1813)" {
    try runAll(&sixel_cases);
}

// ---------------------------------------------------------------------------
// M85b (#1814) — image placement. Cell-native (the M85a pick): an image is
// a block of image cells from the cursor, ceil(w / cell_w) x ceil(h /
// cell_h) at the corpus's 8x16 cell, and every grid operation treats those
// cells like text cells. `"1;1;W;H` raster attributes size an image without
// drawing it (a transparent W x H), which keeps the rows readable.
// ---------------------------------------------------------------------------

const image_cases = [_]Case{
    .{
        .name = "default placement: a 16x32 image covers 2x2 cells; cursor at the left margin below",
        .input = sx("\"1;1;16;32#1;2;100;0;0~"),
        .lines = &.{ "  ", "  ", "" },
        .cursor = .{ 2, 0 },
        .used = 3,
        .images = .{ 1, 0, 0 },
        .cells = &.{
            .{ .row = 0, .col = 0, .tile = .{ 0, 0 } },
            .{ .row = 0, .col = 1, .tile = .{ 1, 0 } },
            .{ .row = 1, .col = 0, .tile = .{ 0, 1 } },
            .{ .row = 1, .col = 1, .tile = .{ 1, 1 } },
            .{ .row = 0, .col = 2 },
            .{ .row = 2, .col = 0 },
        },
        .pixels = &.{
            .{ .row = 0, .col = 0, .dx = 0, .dy = 5, .rgb = 0xff0000 },
            .{ .row = 0, .col = 0, .dx = 0, .dy = 6, .rgb = null },
            .{ .row = 0, .col = 0, .dx = 1, .dy = 0, .rgb = null },
            .{ .row = 1, .col = 1, .dx = 7, .dy = 15, .rgb = null },
        },
    },
    .{
        .name = "colour registers: RGB and DEC HLS (hue 120 = red), one column each",
        .input = sx("#1;2;0;100;0~#2;1;120;50;100~#3;2;0;0;100?~"),
        .images = .{ 1, 0, 0 },
        .pixels = &.{
            .{ .row = 0, .col = 0, .dx = 0, .rgb = 0x00ff00 },
            .{ .row = 0, .col = 0, .dx = 1, .rgb = 0xff0000 },
            .{ .row = 0, .col = 0, .dx = 2, .rgb = null },
            .{ .row = 0, .col = 0, .dx = 3, .rgb = 0x0000ff },
        },
    },
    .{
        .name = "the payload has no byte bound: 4.8 KiB of register definitions still places",
        .input = sx(repeat_lit("#1;2;100;0;0", 400) ++ "~"),
        .images = .{ 1, 0, 0 },
        .pixels = &.{.{ .row = 0, .col = 0, .rgb = 0xff0000 }},
    },
    .{
        .name = "an image replaces the text cells it covers; the rest of the line keeps its text",
        .input = "abcdef\r\x1b[3C" ++ sx("\"1;1;16;1"),
        .lines = &.{ "abc  f", "" },
        .cursor = .{ 1, 0 },
        .cells = &.{
            .{ .row = 0, .col = 2, .base = 'c' },
            .{ .row = 0, .col = 3, .tile = .{ 0, 0 } },
            .{ .row = 0, .col = 4, .tile = .{ 1, 0 } },
            .{ .row = 0, .col = 5, .base = 'f' },
        },
    },
    .{
        .name = "text overwrites an image cell; the other tiles stay",
        .input = sx("\"1;1;24;16") ++ "\x1b[1;2HX",
        .lines = &.{" X "},
        .cells = &.{
            .{ .row = 0, .col = 0, .tile = .{ 0, 0 } },
            .{ .row = 0, .col = 1, .base = 'X' },
            .{ .row = 0, .col = 2, .tile = .{ 2, 0 } },
        },
    },
    .{
        .name = "a wide rune over an image replaces two tiles",
        .input = sx("\"1;1;24;16") ++ "\x1b[1;1H\xe4\xb8\xad",
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 0x4e2d },
            .{ .row = 0, .col = 1, .base = ' ', .cont = 1 },
            .{ .row = 0, .col = 2, .tile = .{ 2, 0 } },
        },
    },
    .{
        .name = "a combining mark after an image cell takes the no-base rule (U+FFFD)",
        .input = sx("\"1;1;8;16") ++ "\x1b[1;2H\xcc\x81",
        .cursor = .{ 0, 2 },
        .cells = &.{
            .{ .row = 0, .col = 0, .tile = .{ 0, 0 } },
            .{ .row = 0, .col = 1, .base = 0xfffd },
        },
    },
    .{
        .name = "placing over half a wide pair blanks the orphaned half",
        .input = "\xe4\xb8\xad\xe4\xb8\xad\x1b[1;2H" ++ sx("\"1;1;16;16"),
        .cells = &.{
            .{ .row = 0, .col = 0, .base = ' ' },
            .{ .row = 0, .col = 1, .tile = .{ 0, 0 } },
            .{ .row = 0, .col = 2, .tile = .{ 1, 0 } },
            .{ .row = 0, .col = 3, .base = ' ' },
        },
    },
    .{
        .name = "the right margin crops an image — tiles never wrap to the next line",
        .input = "\x1b[1;79H" ++ sx("\"1;1;32;16"),
        .cursor = .{ 1, 0 },
        .cells = &.{
            .{ .row = 0, .col = 78, .tile = .{ 0, 0 } },
            .{ .row = 0, .col = 79, .tile = .{ 1, 0 } },
            .{ .row = 1, .col = 0 },
        },
    },
    .{
        .name = "a pending wrap places at the last column",
        .input = &a80 ++ sx("\"1;1;16;16"),
        .lines = &.{ &a79 ++ " ", "" },
        .cursor = .{ 1, 0 },
        .cells = &.{
            .{ .row = 0, .col = 79, .tile = .{ 0, 0 } },
            .{ .row = 1, .col = 0 },
        },
    },
    .{
        .name = "an image taller than the room below scrolls the region (sixel scrolling)",
        // Region rows 1-3; the image starts on the region's bottom row, so
        // each further tile row — and the cursor's move below it — scrolls.
        .input = "\x1b[1;3rL0\r\nL1\r\nL2\r" ++ sx("\"1;1;8;32"),
        .lines = &.{ " 2", " ", "" },
        .cursor = .{ 2, 0 },
        .cells = &.{
            .{ .row = 0, .col = 0, .tile = .{ 0, 0 } },
            .{ .row = 1, .col = 0, .tile = .{ 0, 1 } },
            .{ .row = 2, .col = 0 },
        },
    },
    .{
        .name = "SU moves image rows up with the text (scroll with the buffer)",
        .input = "A\r\n" ++ sx("\"1;1;8;32") ++ "B\x1b[1S",
        .lines = &.{ " ", " ", "B" },
        .cells = &.{
            .{ .row = 0, .col = 0, .tile = .{ 0, 0 } },
            .{ .row = 1, .col = 0, .tile = .{ 0, 1 } },
            .{ .row = 2, .col = 0, .base = 'B' },
        },
    },
    .{
        .name = "IL pushes image rows down with the text",
        .input = sx("\"1;1;8;32") ++ "\x1b[1;1H\x1b[L",
        .cells = &.{
            .{ .row = 0, .col = 0 },
            .{ .row = 1, .col = 0, .tile = .{ 0, 0 } },
            .{ .row = 2, .col = 0, .tile = .{ 0, 1 } },
        },
    },
    .{
        .name = "ED 2 erases images like text",
        .input = sx("\"1;1;16;16") ++ "\x1b[2J",
        .lines = &.{""},
        .images = .{ 1, 0, 0 },
        .cells = &.{
            .{ .row = 0, .col = 0 },
            .{ .row = 0, .col = 1 },
        },
    },
    .{
        .name = "ED 0 erases the image rows below the cursor, not above",
        .input = sx("\"1;1;8;48") ++ "\x1b[2;1H\x1b[J",
        .cells = &.{
            .{ .row = 0, .col = 0, .tile = .{ 0, 0 } },
            .{ .row = 1, .col = 0 },
            .{ .row = 2, .col = 0 },
        },
    },
    .{
        .name = "EL 2 erases the image tiles on its row only",
        .input = sx("\"1;1;8;32") ++ "\x1b[1;1H\x1b[2K",
        .cells = &.{
            .{ .row = 0, .col = 0 },
            .{ .row = 1, .col = 0, .tile = .{ 0, 1 } },
        },
    },
    .{
        .name = "ECH blanks one tile in place",
        .input = sx("\"1;1;24;16") ++ "\x1b[1;2H\x1b[X",
        .cells = &.{
            .{ .row = 0, .col = 0, .tile = .{ 0, 0 } },
            .{ .row = 0, .col = 1 },
            .{ .row = 0, .col = 2, .tile = .{ 2, 0 } },
        },
    },
    .{
        .name = "DCH pulls tiles left; ICH pushes them right",
        .input = sx("\"1;1;24;16") ++ "\x1b[1;1H\x1b[P" ++ "\x1b[1;1H\x1b[2@",
        .cells = &.{
            .{ .row = 0, .col = 0 },
            .{ .row = 0, .col = 1 },
            .{ .row = 0, .col = 2, .tile = .{ 1, 0 } },
            .{ .row = 0, .col = 3, .tile = .{ 2, 0 } },
            .{ .row = 0, .col = 4 },
        },
    },
    .{
        .name = "the primary's image survives an alternate-screen round trip",
        .input = sx("\"1;1;8;16") ++ "\x1b[?1049hx\x1b[?1049l",
        .alt = false,
        .images = .{ 1, 0, 0 },
        .cells = &.{.{ .row = 0, .col = 0, .tile = .{ 0, 0 } }},
    },
    .{
        .name = "one image per terminal: a second image evicts the first, whose cells go blank",
        .input = sx("\"1;1;8;16") ++ sx("\"1;1;8;16"),
        .cursor = .{ 2, 0 },
        .images = .{ 2, 0, 1 },
        .cells = &.{
            .{ .row = 0, .col = 0 },
            .{ .row = 1, .col = 0, .tile = .{ 0, 0 } },
        },
    },
    .{
        .name = "an alternate-screen image evicts the primary's; the primary shows a blank on return",
        .input = sx("\"1;1;8;16") ++ "\x1b[?1049h" ++ sx("\"1;1;8;16") ++ "\x1b[?1049l",
        .images = .{ 2, 0, 1 },
        .cells = &.{.{ .row = 0, .col = 0 }},
    },
    .{
        .name = "an image whose every cell was overwritten is not evicted — its buffer was free",
        .input = sx("\"1;1;8;16") ++ "\x1b[1;1HX\r\n" ++ sx("\"1;1;8;16"),
        .images = .{ 2, 0, 0 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 'X' },
            .{ .row = 1, .col = 0, .tile = .{ 0, 0 } },
        },
    },
    .{
        .name = "a refused image leaves the placed one untouched and the cursor where it was",
        .input = sx("\"1;1;8;16") ++ sx("!97~"),
        .cursor = .{ 1, 0 },
        .sixel_overflow = true,
        .images = .{ 1, 1, 0 },
        .cells = &.{
            .{ .row = 0, .col = 0, .tile = .{ 0, 0 } },
            .{ .row = 1, .col = 0 },
        },
    },
    .{
        .name = "a raster declaration past the bound is refused whole",
        .input = sx("\"1;1;97;1~"),
        .cursor = .{ 0, 0 },
        .sixel_overflow = true,
        .images = .{ 0, 1, 0 },
        .cells = &.{.{ .row = 0, .col = 0 }},
    },
};

test "terminal corpus: image placement (M85b #1814)" {
    try runAll(&image_cases);
}

test "terminal corpus: resize never wraps an image cell; widening does not bring it back (M85b #1814)" {
    var s: t.Screen = .{};
    // A 3-cell image at columns 6..8, then a text line under it.
    s.feed("\x1b[1;7H" ++ sx("\"1;1;24;16") ++ "abcdefghijk");
    try std.testing.expectEqual(@as(u3, 0), s.cellAt(0, 5).img);
    try std.testing.expect(s.cellAt(0, 8).img != 0);
    _ = s.setCols(8);
    // Text re-wraps as ever; the image row keeps columns 6 and 7 and drops
    // the tile past the new margin instead of wrapping it onto a new row.
    try std.testing.expectEqualStrings("        ", s.line(0));
    try std.testing.expectEqual(@as(u7, 0), s.cellAt(0, 6).tx);
    try std.testing.expect(s.cellAt(0, 6).img != 0);
    try std.testing.expectEqual(@as(u7, 1), s.cellAt(0, 7).tx);
    try std.testing.expectEqualStrings("abcdefgh", s.line(1));
    try std.testing.expectEqualStrings("ijk", s.line(2));
    try std.testing.expect(s.imageTile(0, 7) != null);
    _ = s.setCols(80);
    try std.testing.expect(s.cellAt(0, 7).img != 0);
    try std.testing.expectEqual(@as(u3, 0), s.cellAt(0, 8).img);
    try std.testing.expectEqual(@as(usize, 8), s.line(0).len);
}

// ---------------------------------------------------------------------------
// Group G — UTF-8 decode (M73a-1 #1625 policy). `line()` projects every
// non-ASCII rune to one 0x00 byte, so rune expectations use cell spots.
// ---------------------------------------------------------------------------

const utf8_cases = [_]Case{
    .{
        .name = "2-byte rune decodes; ASCII projection shows 0x00",
        .input = "\xc3\xa9",
        .lines = &.{"\x00"},
        .cursor = .{ 0, 1 },
        .cells = &.{.{ .row = 0, .col = 0, .base = 0xE9 }},
    },
    .{
        .name = "3-byte rune is double-width: base + continuation cell",
        .input = "\xe4\xbd\xa0",
        .lines = &.{"\x00\x00"},
        .cursor = .{ 0, 2 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 0x4F60 },
            .{ .row = 0, .col = 1, .base = ' ', .cont = 1 },
        },
    },
    .{
        .name = "4-byte (astral) rune decodes and occupies a wide pair",
        .input = "\xf0\x9f\x98\x80",
        .lines = &.{"\x00\x00"},
        .cursor = .{ 0, 2 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 0x1F600 },
            .{ .row = 0, .col = 1, .base = ' ', .cont = 1 },
        },
    },
    .{
        .name = "a stray continuation byte is one U+FFFD, then text resumes",
        .input = "\x80A",
        .lines = &.{"\x00A"},
        .cursor = .{ 0, 2 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 0xFFFD },
            .{ .row = 0, .col = 1, .base = 'A' },
        },
    },
    .{
        .name = "an invalid lead (F5-FF) is one U+FFFD",
        .input = "\xf5A",
        .lines = &.{"\x00A"},
        .cursor = .{ 0, 2 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 0xFFFD },
            .{ .row = 0, .col = 1, .base = 'A' },
        },
    },
    .{
        // Truncated tail: one U+FFFD for the half-sequence, then the
        // offending byte is processed fresh (a printable stays printable).
        .name = "a truncated tail is one U+FFFD, the next byte reprocesses",
        .input = "\xc3A",
        .lines = &.{"\x00A"},
        .cursor = .{ 0, 2 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 0xFFFD },
            .{ .row = 0, .col = 1, .base = 'A' },
        },
    },
    .{
        .name = "an overlong 3-byte sequence is one U+FFFD for the sequence",
        .input = "\xe0\x80\xaf",
        .lines = &.{"\x00"},
        .cursor = .{ 0, 1 },
        .cells = &.{.{ .row = 0, .col = 0, .base = 0xFFFD }},
    },
    .{
        .name = "a surrogate code point is one U+FFFD for the sequence",
        .input = "\xed\xa0\x80",
        .lines = &.{"\x00"},
        .cursor = .{ 0, 1 },
        .cells = &.{.{ .row = 0, .col = 0, .base = 0xFFFD }},
    },
    .{
        // C0/C1 bytes (C0..C1) fail the LEAD check, so each byte is its
        // own U+FFFD — different from valid leads, which fail at the end
        // of the sequence and produce ONE replacement (rows above).
        .name = "C0 lead bytes each become one U+FFFD (lead-level rule)",
        .input = "\xc0\xaf",
        .lines = &.{"\x00\x00"},
        .cursor = .{ 0, 2 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = 0xFFFD },
            .{ .row = 0, .col = 1, .base = 0xFFFD },
        },
    },
    .{
        .name = "a combining rune overlays the base behind the cursor",
        .input = "e\xcc\x81",
        .lines = &.{"e"},
        .cursor = .{ 0, 1 },
        .cells = &.{.{ .row = 0, .col = 0, .base = 'e', .mark = 0x301 }},
    },
    .{
        .name = "an orphan combining rune (no base) pins to U+FFFD",
        .input = "\xcc\x81",
        .lines = &.{"\x00"},
        .cursor = .{ 0, 1 },
        .cells = &.{.{ .row = 0, .col = 0, .base = 0xFFFD }},
    },
    .{
        .name = "an ignorable zero-width rune is dropped cursor-neutral",
        .input = "\xe2\x80\x8dU", // ZWJ + U
        .lines = &.{"U"},
        .cursor = .{ 0, 1 },
        .cells = &.{.{ .row = 0, .col = 0, .base = 'U' }},
    },
    .{
        // Overwriting one half of a wide pair repairs the orphan first:
        // the base becomes an erased (space) cell instead of a torn pair.
        .name = "overwriting a continuation cell repairs its base",
        .input = "\xe4\xbd\xa0\x1b[1;2Hx",
        .lines = &.{" x"},
        .cursor = .{ 0, 2 },
        .cells = &.{
            .{ .row = 0, .col = 0, .base = ' ' },
            .{ .row = 0, .col = 1, .base = 'x' },
        },
    },
};

test "terminal corpus: UTF-8 decode (M73a-1 policy)" {
    try runAll(&utf8_cases);
}

// ---------------------------------------------------------------------------
// Group H — SGR depth (M73h #1634, ADR 0020 Amendment E): xterm 256,
// truecolour side arrays, the attribute flags, and their resets. The
// 16-colour groups above must stay untouched — old sequences, identical
// cells (their green run is the pixel-parity proof).
// ---------------------------------------------------------------------------

const sgr_depth_cases = [_]Case{
    .{
        .name = "38;5/48;5 store xterm indices in the u9 slots",
        .input = "\x1b[38;5;196mA\x1b[48;5;21mB",
        .lines = &.{"AB"},
        .cursor = .{ 0, 2 },
        .styles = &.{
            .{ .row = 0, .col = 0, .fg = 196 },
            .{ .row = 0, .col = 1, .fg = 196, .bg = 21 },
        },
    },
    .{
        // The default sentinel moved to 256 precisely so this index can
        // be a real colour instead of reading as "default".
        .name = "38;5;16 is a real colour (the old sentinel moved to 256)",
        .input = "\x1b[38;5;16mX",
        .lines = &.{"X"},
        .cursor = .{ 0, 1 },
        .styles = &.{.{ .row = 0, .col = 0, .fg = 16 }},
    },
    .{
        .name = "38;2/48;2 stores exact truecolour in the side arrays",
        .input = "\x1b[38;2;255;128;71;48;2;17;34;51mX",
        .lines = &.{"X"},
        .cursor = .{ 0, 1 },
        .styles = &.{.{
            .row = 0,
            .col = 0,
            .fg_rgb = .{ .r = 255, .g = 128, .b = 71 },
            .bg_rgb = .{ .r = 17, .g = 34, .b = 51 },
        }},
    },
    .{
        // 39/49 return the slots to default: the cell stops being rgb
        // (rgbAt gates on the slot) and is byte-exact default again.
        .name = "39/49 drop back to default after truecolour",
        .input = "\x1b[38;2;1;2;3mA\x1b[39;49mB",
        .lines = &.{"AB"},
        .cursor = .{ 0, 2 },
        .styles = &.{
            .{ .row = 0, .col = 0, .fg_rgb = .{ .r = 1, .g = 2, .b = 3 } },
            .{ .row = 0, .col = 1, .default_exact = true },
        },
    },
    .{
        .name = "dim/italic/underline/reverse set on write, cleared by their resets",
        .input = "\x1b[2;3;4;7mA\x1b[22;23;24;27mB",
        .lines = &.{"AB"},
        .cursor = .{ 0, 2 },
        .styles = &.{
            .{ .row = 0, .col = 0, .dim = true, .italic = true, .underline = true, .reverse = true },
            .{ .row = 0, .col = 1 },
        },
    },
    .{
        .name = "SGR 0 clears flags byte-exactly (not just colours)",
        .input = "\x1b[1;4;31mA\x1b[0mB",
        .lines = &.{"AB"},
        .cursor = .{ 0, 2 },
        .styles = &.{
            .{ .row = 0, .col = 0, .fg = 1, .bold = true, .underline = true },
            .{ .row = 0, .col = 1, .default_exact = true },
        },
    },
    .{
        // 12 params: truecolour fg (5) + 256 bg (2) + four flags — this
        // overflowed the old [8] and silently dropped the tail.
        .name = "a 12-param line fits the widened csi_params",
        .input = "\x1b[1;4;7;3;38;2;1;2;3;48;5;9mX",
        .lines = &.{"X"},
        .cursor = .{ 0, 1 },
        .styles = &.{.{
            .row = 0,
            .col = 0,
            .fg = null,
            .bg = 9,
            .bold = true,
            .italic = true,
            .underline = true,
            .reverse = true,
            .fg_rgb = .{ .r = 1, .g = 2, .b = 3 },
        }},
    },
    .{
        // Three invalid forms in one line: out-of-range index (999),
        // truncated rgb (`38;2;31` — the tail is DROPPED, never re-read
        // as SGR 31), and the ITU colon form (digits collapse into one
        // unknown param). All three leave the rendition alone.
        .name = "invalid selectors are ignored, tails dropped, colon form unsupported",
        .input = "\x1b[38;5;999mA\x1b[38;2;31mB\x1b[38:5:9mC",
        .lines = &.{"ABC"},
        .cursor = .{ 0, 3 },
        .styles = &.{
            .{ .row = 0, .col = 0, .default_exact = true },
            .{ .row = 0, .col = 1, .default_exact = true },
            .{ .row = 0, .col = 2, .default_exact = true },
        },
    },
};

test "terminal corpus: SGR depth — 256, truecolour, attributes (M73h)" {
    try runAll(&sgr_depth_cases);
}

// ---------------------------------------------------------------------------
// Group I — CSI parameter-soup fuzz (M80b follow-up, #1713's hardening).
// NOT a golden table: this group pins INVARIANTS under random load — the
// parser must never panic and the grid must never corrupt. "Not corrupted"
// is defined here as: every index inside its bound, wide pairs whole (a
// continuation never stands without its base), row lengths inside the
// width, and nothing left behind below the used tail (M80a's
// materialise-on-write rule). Deterministic: fixed xorshift64 seeds, so a
// failure reproduces byte-for-byte — the seed and step print on failure.
//
// The soup runs through a REGISTRY screen (the pub surface): unlike the
// golden rows above it also exercises the history ring, the alternate
// screen and the scan overlay paths (a corpus-local Screen has no history
// bank).
// ---------------------------------------------------------------------------

/// Deterministic xorshift64 — no std.rand dependency, byte-stable across
/// toolchains (the seeds below are part of the corpus).
const SoupRng = struct {
    s: u64,

    fn init(seed: u64) SoupRng {
        return .{ .s = if (seed == 0) 0x9E3779B97F4A7C15 else seed };
    }

    fn next(self: *SoupRng) u64 {
        self.s ^= self.s << 13;
        self.s ^= self.s >> 7;
        self.s ^= self.s << 17;
        return self.s;
    }

    fn pick(self: *SoupRng, n: u64) u64 {
        return self.next() % n;
    }
};

/// One soup chunk: mostly `ESC [ … final` with random params (empty,
/// 1–2 digits, rarely 3 to hit the clamping paths), random separators
/// (`;` mostly, `:` as the ITU sub-parameter probe), a random private
/// prefix or intermediate byte, and a final drawn from the known dispatch
/// set AND unknown finals ("consumed, never painted" territory).
/// Occasionally the chunk is instead a short text/C0 run so the ops have
/// content and cursor positions to act on (including a bare wide-rune
/// lead byte, probing UTF-8 recovery), or an ABANDONED partial sequence
/// probing stream-state recovery.
fn soupChunk(rng: *SoupRng, buf: *[64]u8) []const u8 {
    var n: usize = 0;
    const roll = rng.pick(8);
    if (roll < 2) {
        // Text / C0 run.
        const len = 1 + rng.pick(6);
        var i: u64 = 0;
        while (i < len) : (i += 1) {
            buf[n] = switch (rng.pick(9)) {
                0 => '\r',
                1 => '\n',
                2 => 0x08,
                3 => '\t',
                4 => 0x07,
                5, 6 => 'a' + @as(u8, @intCast(rng.pick(26))),
                7 => ' ',
                else => 0xE4, // wide-rune lead byte, alone: UTF-8 recovery
            };
            n += 1;
        }
        return buf[0..n];
    }
    if (roll == 2) {
        // Abandoned partial sequence: no final byte, the next chunk's
        // bytes run through the parser mid-state.
        buf[n] = 0x1b;
        n += 1;
        buf[n] = '[';
        n += 1;
        buf[n] = '1';
        n += 1;
        buf[n] = ';';
        n += 1;
        return buf[0..n];
    }
    if (roll == 3) {
        // M80g: an OSC string — Ps, payload, terminator. Variants: a
        // title, a clipboard copy, a refused `?` read, and a TRUNCATED
        // string with no terminator (the next chunk probes recovery
        // mid-OSC).
        buf[n] = 0x1b;
        n += 1;
        buf[n] = ']';
        n += 1;
        const variant = rng.pick(4);
        const ps: []const u8 = if (variant == 1) "52" else if (variant == 3) "0" else "2";
        for (ps) |d| {
            buf[n] = d;
            n += 1;
        }
        buf[n] = ';';
        n += 1;
        const payload: []const u8 = switch (variant) {
            1 => "c;aGVsbG8=",
            2 => "c;?",
            else => "soup",
        };
        for (payload) |c| {
            buf[n] = c;
            n += 1;
        }
        if (variant != 3) {
            buf[n] = 0x07;
            n += 1;
        }
        return buf[0..n];
    }
    buf[n] = 0x1b;
    n += 1;
    buf[n] = '[';
    n += 1;
    if (rng.pick(4) == 0) {
        buf[n] = if (rng.pick(2) == 0) '?' else '>'; // private vs intermediate
        n += 1;
    }
    if (rng.pick(8) == 0) {
        buf[n] = ' '; // intermediate byte (the SL/SR form) — probe the skip
        n += 1;
    }
    const nparams = 1 + rng.pick(5);
    var p: u64 = 0;
    while (p < nparams) : (p += 1) {
        if (p > 0) {
            buf[n] = if (rng.pick(8) == 0) ':' else ';';
            n += 1;
        }
        switch (rng.pick(4)) {
            0 => {}, // empty (the default)
            1, 2 => {
                buf[n] = '0' + @as(u8, @intCast(rng.pick(10)));
                n += 1;
            },
            else => {
                buf[n] = '1' + @as(u8, @intCast(rng.pick(9)));
                n += 1;
                buf[n] = '0' + @as(u8, @intCast(rng.pick(10)));
                n += 1;
            },
        }
        if (rng.pick(32) == 0) {
            for ("999") |d| { // rare 3-digit: the out-of-range clamps
                buf[n] = d;
                n += 1;
            }
        }
    }
    const finals = "mHfJKABCDEFGdb@PXL" ++ "MSTnc" ++ "Z~ghiovwxyz";
    buf[n] = finals[rng.pick(finals.len)];
    n += 1;
    return buf[0..n];
}

/// The definition of "the grid is not corrupted". Bounded indices,
/// whole wide pairs, lengths inside the width, and nothing below the
/// used tail.
fn soupInvariants(s: *const t.Screen) !void {
    try std.testing.expect(s.used >= 1 and s.used <= t.grid_lines);
    try std.testing.expect(s.cur < t.grid_lines);
    try std.testing.expect(s.col <= s.cols);
    try std.testing.expect(s.cols <= t.grid_cols);
    try std.testing.expect(s.viewOffset() < s.lineCount());
    try std.testing.expect(s.hist_count <= t.history_lines);
    try std.testing.expect(s.hist_start < t.history_lines);
    // M80g: the OSC queues stay inside their bounds whatever the soup
    // feeds — the string bound, the title bound, the clipboard bound.
    try std.testing.expect(s.osc_len <= t.osc_max);
    try std.testing.expect(s.title_len <= t.title_max);
    try std.testing.expect(s.clip_len <= s.clip_data.len);
    for (0..t.grid_lines) |r| {
        try std.testing.expect(s.lens[r] <= s.cols);
        if (r >= s.used) try std.testing.expect(s.lens[r] == 0);
        for (0..t.grid_cols) |c| {
            const cell = s.cells[r][c];
            if (cell.cont == 1) {
                // A continuation always has its base to the left: never
                // at column 0, never behind another continuation.
                try std.testing.expect(c > 0);
                try std.testing.expect(s.cells[r][c - 1].cont == 0);
            }
            if (r >= s.used) {
                // Nothing survives below the used tail.
                try std.testing.expect(cell.base == ' ');
                try std.testing.expect(cell.mark == 0);
                try std.testing.expect(cell.cont == 0);
            }
        }
    }
}

test "terminal corpus: CSI parameter soup never panics or corrupts the grid" {
    for (&t.terminals) |*tm| tm.reset();
    for (&t.screens) |*sc| sc.reset();
    const h = t.create(7) orelse return error.TestUnexpectedResult;
    const tm = t.get(h).?;
    try std.testing.expect(tm.attachWindow(7));
    const s = t.screenForWindow(7).?;
    const seeds = [_]u64{
        0x1234_5678_9ABC_DEF0, 0xDEAD_BEEF_CAFE_F00D,
        0x0000_0000_0000_0001, 0x8000_0000_0000_0001,
        0xA5A5_5A5A_C3C3_3C3C, 0x0123_4567_89AB_CDEF,
    };
    for (seeds) |seed| {
        s.reset();
        var rng = SoupRng.init(seed);
        var step: usize = 0;
        while (step < 256) : (step += 1) {
            var buf: [64]u8 = undefined;
            s.feed(soupChunk(&rng, &buf));
            if (step % 16 == 15) {
                soupInvariants(s) catch |err| {
                    std.debug.print("\ncorpus fuzz failed: seed 0x{x} step {d}\n", .{ seed, step });
                    return err;
                };
            }
        }
        soupInvariants(s) catch |err| {
            std.debug.print("\ncorpus fuzz failed: seed 0x{x} final sweep\n", .{seed});
            return err;
        };
    }
}
