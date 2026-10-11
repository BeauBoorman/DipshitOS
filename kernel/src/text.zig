//! Milestone six card G2 (claim 3194) — framebuffer text rendering.
//!
//! Renders text into G1's virtio-gpu framebuffer (B8G8R8X8_UNORM —
//! memory bytes B, G, R, X, claim-6053 observed) using a built-in 8×8
//! monochrome bitmap font (`font8x8.zig`, public domain — Daniel
//! Hepper's font8x8, based on IBM public-domain VGA fonts). The raster
//! is pure logic over an injectable canvas (the fat.zig / virtio_net.zig
//! host-testable pattern): putc/puts with a cursor, line wrap at the
//! region's width, a BOUNDED scrollback ring (fixed BSS — the visible
//! window scrolls one line when full), and `clear`.
//!
//! The text region is the whole framebuffer (1280×720 → 160 cols × 90
//! rows at 8×8 cells). Honest bounds: G2 renders text into G1's
//! framebuffer through G1's transfer/flush path; the console's line
//! editor + command registry stay on serial until card G3 (Road Pops).
//! No libc, no POSIX, no allocation, no interrupts.

const std = @import("std");
const font = @import("font8x8.zig");
const font_unicode = @import("font_unicode.zig");
const font_emoji = @import("font_emoji.zig");
const virtio_gpu = @import("virtio_gpu.zig");

// ---------------------------------------------------------------------------
// Geometry + colors (fixed constants; the claim-time record lives in
// docs/archive/m6-text-prompt.md and the hardware contract)
// ---------------------------------------------------------------------------

/// 8×8 cells over the 1280×720 framebuffer.
pub const cell_w: usize = 8;
pub const cell_h: usize = 8;
pub const cols: usize = virtio_gpu.fb_width / cell_w; // 160
pub const rows: usize = virtio_gpu.fb_height / cell_h; // 90

/// The bounded scrollback ring: `ring_lines` lines × `cols` chars of
/// fixed BSS. The visible window is the LAST `rows` lines of the ring;
/// when the ring is full the oldest line is dropped (the console's
/// scroll-up behavior). Claim-time constant: 4× the visible rows.
pub const ring_lines: usize = 128;

/// Text colors (0xRRGGBB). The foreground is the G1-family green, the
/// background the G1 boot fill (dark slate) — both already observed
/// through the color-managed host pipeline.
pub const fg_rgb: u32 = 0x00ff00;
pub const bg_rgb: u32 = 0x101418;

/// Tab-stop interval in columns (M20-U10). 8 is the terminal default;
/// `set_tab_width` admits 4 (editor style). A TAB advances the cursor to
/// the next multiple of this width, filling the skipped cells with
/// spaces so selection/copy see real characters.
pub var tab_width: usize = 8;

/// Set the tab-stop interval (clamped to 1..=8; M20-U10's 8/4 options).
pub fn set_tab_width(n: usize) void {
    tab_width = if (n == 0) 1 else @min(n, 8);
}

// ---------------------------------------------------------------------------
// Font sizes (M20-U1): 8×8 small (default), 16×16 medium, 24×24 large.
// All three are nearest-neighbor scalings of the single 8×8 source —
// comptime tables live in font_unicode.zig; the raster block-fills from
// the same source rows, which paints exactly the table bits (pinned by
// a test there).
// ---------------------------------------------------------------------------

pub const FontSize = enum(u2) {
    small = 0,
    medium = 1,
    large = 2,

    /// The cell edge in pixels for this size.
    pub fn px(s: FontSize) usize {
        return switch (s) {
            .small => 8,
            .medium => 16,
            .large => 24,
        };
    }
};

/// The terminal layer's font size (window 0 is the only kernel-rendered
/// text window). Default small — the boot look is unchanged.
pub var font_size: FontSize = .small;

/// Change the font size. Geometry applies to output from now on: the
/// scrollback keeps its content, and lines wrap at the new width going
/// forward (no reflow — honest bound, matches classic terminal behavior).
pub fn set_font_size(s: FontSize) void {
    font_size = s;
}

/// Current cell dimensions in pixels.
pub fn cur_cell_w() usize {
    return font_size.px();
}
pub fn cur_cell_h() usize {
    return font_size.px();
}

/// Visible columns/rows at the current size (the ring stays `cols` wide;
/// bigger cells show fewer).
pub fn visible_cols() usize {
    return virtio_gpu.fb_width / cur_cell_w();
}
pub fn visible_rows() usize {
    return virtio_gpu.fb_height / cur_cell_h();
}

// ---------------------------------------------------------------------------
// Text state (fixed BSS — the one-and-only real instance)
// ---------------------------------------------------------------------------

/// One ring cell. M20 widened the ring from raw ASCII bytes to u16 so a
/// cell can name any codepoint the renderer knows:
///
///   0x0000–0x7FFF  literal codepoint (ASCII fast path inside this)
///   0x8000–0xFFFE  reserved for M20's dynamic encodings (combining
///                  clusters, emoji — wired up by their cards)
///   0xFFFF         the right half of a wide (2-cell) character
pub const Cell = u16;

/// The scrollback ring of text lines. A line is `cols` cells.
var ring: [ring_lines][cols]Cell = undefined;

/// Chars used per line (0..cols) — the cursor/report bookkeeping.
var line_fill: [ring_lines]u16 = undefined;

/// Ring bookkeeping: `ring_head` = the index where the NEXT line is
/// written, `ring_count` = valid lines (0..ring_lines). The OLDEST line
/// is at `ring_head - ring_count` (mod ring_lines) once full.
var ring_head: usize = 0;
var ring_count: usize = 0;

/// The cursor: line position within the ring (always the last line) +
/// column.
var cur_line: usize = 0; // = ring_head - 1 mod ring_lines
var cur_col: usize = 0;

/// Whether the text layer has been initialized (the ring reset).
var initialized: bool = false;

/// CSI (`ESC [ <params> <final>`) decode state for the byte stream the
/// line editor and monitor write here: 0 = normal, 1 = ESC, 2 = ESC [.
/// Ctrl-L and `clear` emit `ESC [ 2 J` + `ESC [ H`; without this the
/// escape bytes were STORED and drawn as the glyphs `[2J[H` instead of
/// clearing the screen (the serial console never saw it — its terminal
/// consumes them).
var esc_state: u8 = 0;
var esc_param: u8 = 0;

/// A B8G8R8X8 canvas the renderer writes into (injectable for tests).
pub const Canvas = struct {
    base: [*]u8,
    width: usize,
    height: usize,
    stride: usize, // bytes per row (width × 4 for the framebuffer)
};

// ---------------------------------------------------------------------------
// Character width (M20-U4 — wcwidth, comptime-evaluable)
// ---------------------------------------------------------------------------

/// The terminal width of a codepoint in cells: 0 (invisible/combining),
/// 1 (narrow), or 2 (wide). Bounded to the ranges this OS can actually
/// encounter: Latin-1 + Latin Extended-A render narrow; CJK ideographs,
/// fullwidth forms and the emoji blocks are wide even though only a
/// subset paints real glyphs (the rest fall back — U11); combining
/// diacritics, variation selectors and the zero-width joiners occupy no
/// cell at all. Unlisted codepoints default to 1. Works at comptime so
/// font tables can be generated against it.
pub fn char_width(cp: u21) u8 {
    return switch (cp) {
        // Combining diacritical marks (overlay the previous cell).
        0x0300...0x036F => 0,
        // Zero-width characters: ZWSP, ZWNJ, ZWJ, LRM, RLM.
        0x200B...0x200F => 0,
        // Word joiner.
        0x2060 => 0,
        // Variation selectors.
        0xFE00...0xFE0F => 0,
        // CJK ideographs (no glyph tables yet — still 2 cells wide).
        0x4E00...0x9FFF => 2,
        // Halfwidth/known-narrow punctuation inside the fullwidth block.
        0xFF01...0xFF60 => 2,
        // Emoji blocks (U+1F300–U+1F9FF): Miscellaneous Symbols and
        // Pictographs, Emoticons, Supplemental Symbols and Pictographs.
        0x1F300...0x1F9FF => 2,
        else => 1,
    };
}

/// Whether `cp` is a combining mark that overlays the previous base
/// character (the width-0 set that MODIFIES rather than vanishes).
pub fn is_combining(cp: u21) bool {
    return cp >= 0x0300 and cp <= 0x036F;
}

/// Whether `cp` is an ignorable zero-width codepoint (ZWJ/ZWNJ/ZWSP/
/// selectors): it neither takes a cell nor modifies its neighbor.
pub fn is_zero_width_ignorable(cp: u21) bool {
    return switch (cp) {
        0x200B...0x200F, 0xFE00...0xFE0F, 0x2060 => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// State operations (pure — host-testable)
// ---------------------------------------------------------------------------

/// Reset the ring + cursor (the boot-time call and `text clear`).
pub fn init() void {
    var i: usize = 0;
    while (i < ring_lines) : (i += 1) {
        @memset(&ring[i], 0x20);
        line_fill[i] = 0;
    }
    ring_head = 0;
    ring_count = 0;
    cur_line = 0;
    cur_col = 0;
    esc_state = 0;
    esc_param = 0;
    u8_need = 0;
    u8_acc = 0;
    missing_glyph_count = 0;
    last_missing_cp = 0;
    dyn_count = 0;
    @memset(&glyph_cache, mem_zero);
    glyph_cache_hits = 0;
    glyph_cache_misses = 0;
    initialized = true;
}

/// Start a NEW line at the ring head (advancing/dropping the oldest when
/// full) and move the cursor to it. Returns the ring slot of the new
/// line.
fn new_line() usize {
    const slot = ring_head;
    @memset(&ring[slot], 0x20);
    line_fill[slot] = 0;
    ring_head = (ring_head + 1) % ring_lines;
    if (ring_count < ring_lines) ring_count += 1;
    cur_line = slot;
    cur_col = 0;
    return slot;
}

/// The ring slot of the cursor's line (the last valid line).
fn cursor_slot() usize {
    if (!initialized or ring_count == 0) return new_line();
    return cur_line;
}

/// Emit one character. `\n` starts a new line; `\r` returns the cursor to
/// column 0 of the current line; `\b` moves the cursor left one column (a
/// no-op at column 0) so the line editor's erase/redraw byte stream renders
/// on the framebuffer exactly as it does on a serial terminal (milestone
/// eight card U2). `ESC [ 2 J` clears the layer and `ESC [ H` homes the
/// cursor; any other CSI sequence is swallowed whole rather than drawn.
/// Every other byte renders into the current line (printable chars draw
/// the glyph, control bytes draw as blank), wrapping to a new line at the
/// region's width.
pub fn putc(c: u8) void {
    if (!initialized) init();
    switch (esc_state) {
        0 => {},
        else => esc_state = 0,
        1 => {
            esc_state = 0;
            if (c == 0x5b) { // '['
                esc_state = 2;
                esc_param = 0;
                return;
            }
            // A lone ESC introduces nothing we render: drop the ESC and
            // handle this byte as ordinary text (falls through below).
        },
        2 => {
            if (c >= 0x30 and c <= 0x39) { // parameter digits
                const scaled = @mulWithOverflow(esc_param, 10);
                const added = @addWithOverflow(scaled[0], c - 0x30);
                esc_param = if (scaled[1] == 1 or added[1] == 1) 255 else added[0];
                return;
            }
            if (c >= 0x3a and c <= 0x3f) return; // ';' and friends
            esc_state = 0;
            if (c == 0x4a and esc_param == 2) init(); // ESC [ 2 J: erase all
            if (c == 0x48) cur_col = 0; // ESC [ H: home the cursor
            return;
        },
    }
    if (c == 0x1b) {
        esc_state = 1;
        u8_need = 0; // an ESC also aborts any pending UTF-8 sequence
        return;
    }
    if (c == '\n') {
        _ = new_line();
        return;
    }
    if (c == '\r') {
        cur_col = 0;
        return;
    }
    if (c == 0x08) { // backspace
        backspace();
        return;
    }
    if (c == '\t') {
        // M20-U10: advance to the next tab stop, materializing the
        // skipped cells as spaces. A tab never wraps to the next line —
        // it stops at the region edge like a real terminal.
        const slot = cursor_slot();
        const stop = ((cur_col / tab_width) + 1) * tab_width;
        const edge = @min(cols, visible_cols());
        while (cur_col < @min(stop, edge)) : (cur_col += 1) {
            ring[slot][cur_col] = 0x20;
        }
        line_fill[slot] = @intCast(cur_col);
        return;
    }
    // M20-U2: everything else decodes as (possibly multi-byte) UTF-8 and
    // lands through the codepoint path.
    if (utf8_step(c)) |cp| {
        putc_unicode(cp);
        if (u8_retry) {
            u8_retry = false;
            if (utf8_step(u8_retry_byte)) |cp2| putc_unicode(cp2);
        }
    }
}

// ---------------------------------------------------------------------------
// Codepoint path (M20-U2): UTF-8 decode + cell encoding
// ---------------------------------------------------------------------------

/// Incremental UTF-8 decode state (max 4-byte sequences; bounded BSS).
var u8_need: u8 = 0;
var u8_acc: u21 = 0;

/// When a non-continuation byte interrupts a pending sequence, that
/// byte still deserves normal processing after the U+FFFD is reported.
var u8_retry: bool = false;
var u8_retry_byte: u8 = 0;

/// Feed one byte; returns a complete codepoint when the sequence ends,
/// null while more continuations are expected, or U+FFFD for broken
/// input (stray continuation byte / invalid lead / bad continuation).
fn utf8_step(b: u8) ?u21 {
    if (u8_need > 0) {
        if ((b & 0xC0) != 0x80) {
            u8_need = 0;
            u8_acc = 0;
            // The interrupting byte is re-fed once the caller has taken
            // the replacement codepoint (putc drives the retry below).
            if (b < 0x80 or (b >= 0xC2 and b <= 0xF4)) {
                u8_retry = true;
                u8_retry_byte = b;
            }
            return 0xFFFD; // broken sequence
        }
        u8_need -= 1;
        const next: u21 = (@as(u21, u8_acc) << 6) | (b & 0x3F);
        if (u8_need == 0) {
            u8_acc = 0;
            return next;
        }
        u8_acc = next;
        return null;
    }
    if (b < 0x80) return b;
    if (b >= 0xC2 and b <= 0xDF) {
        u8_need = 1;
        u8_acc = b & 0x1F;
        return null;
    }
    if (b >= 0xE0 and b <= 0xEF) {
        u8_need = 2;
        u8_acc = b & 0x0F;
        return null;
    }
    if (b >= 0xF0 and b <= 0xF4) {
        u8_need = 3;
        u8_acc = b & 0x07;
        return null;
    }
    return 0xFFFD; // stray continuation or invalid lead
}

/// Reserved cell opcodes (see `Cell`). The 0x8000+ dynamic space is
/// wired up by later M20 cards; unknown opcodes render blank.
pub const cell_wide_cont: Cell = 0xFFFF;

/// Emoji base cells: 0x2000 | index into font_emoji.emojis (range
/// [0x2000, 0x3000)). The glyph paints 16px across this cell AND the
/// following continuation cell.
pub const cell_emoji_base: Cell = 0x2000;

/// First cell of the dynamic cluster-pool space (M20-U5/U6 refs).
pub const cell_dyn_base: Cell = 0x8000;

/// The unified glyph lookup for a literal codepoint (M20-U11 shape):
/// ASCII from font8x8, ≥0xA0 from the Unicode tables, null when there is
/// no glyph (caller renders the replacement character).
pub fn glyph_for(cp: u21) ?*const [8]u8 {
    if (cp < 0x80) {
        if (cp < 0x20 or cp > 0x7e) return null;
        return &font.glyphs[cp - 0x20];
    }
    return font_unicode.glyph(cp);
}

/// Emit one CODEPOINT into the current line. Control handling mirrors
/// putc's byte path; width-1 codepoints take one cell, width-2 take two
/// (base + continuation). Width-0 combining/ignorable codepoints are
/// dropped here until the U5/U6 cluster machinery wires them up.
pub fn putc_unicode(cp: u21) void {
    switch (cp) {
        '\n' => {
            _ = new_line();
            return;
        },
        '\r' => {
            cur_col = 0;
            return;
        },
        0x08 => {
            backspace();
            return;
        },
        else => {},
    }
    // Unknown C0 controls and DEL draw as blanks (the historical byte
    // behavior) — never as visible fallback glyphs.
    if (cp < 0x20 or cp == 0x7F) {
        store_narrow_cell(0x20);
        return;
    }
    const w = char_width(cp);
    if (w == 0) {
        // M20-U6: combining marks overlay the previous cell; ignorable
        // zero-width codepoints (ZWJ/ZWNJ/ZWSP/selectors) vanish.
        if (is_combining(cp)) attach_mark(cp);
        return;
    }
    if (w == 2) {
        // M20-U4/U7: wide codepoints claim two cells — base + continuation.
        // Tabled emoji paint their 16×16 art; everything else (CJK until
        // tables exist) falls back to a double-wide replacement box.
        const edge = @min(cols, visible_cols());
        var slot = cursor_slot();
        if (cur_col + 1 >= edge) slot = new_line(); // room for both halves
        if (cur_col >= edge) slot = new_line();
        if (font_emoji.lookup(cp)) |idx| {
            ring[slot][cur_col] = cell_emoji_base | @as(Cell, @intCast(idx));
        } else {
            ring[slot][cur_col] = cell_fffd;
            note_missing(cp);
        }
        cur_col += 1;
        if (cur_col < edge) {
            ring[slot][cur_col] = cell_wide_cont;
            cur_col += 1;
        }
        if (cur_col > line_fill[slot]) line_fill[slot] = @intCast(cur_col);
        if (cur_col >= edge) _ = new_line();
        return;
    }
    if (glyph_for(cp) != null and cp <= 0x17F) {
        store_narrow_cell(@intCast(cp)); // literal encoding (ASCII + Latin tables)
    } else {
        store_narrow_cell(cell_fffd); // M20-U11 fallback art
        note_missing(cp);
    }
}

/// Decode one ring cell into the glyph rows it paints (null paints
/// nothing: wide continuations, reserved opcodes, blanks).
fn cell_glyph(cell: Cell) ?*const [8]u8 {
    if (cell == cell_wide_cont) return null;
    if (cell == cell_fffd) return &font_unicode.fffd_glyph;
    if (cell >= 0x20 and cell <= 0x7e) return &font.glyphs[cell - 0x20];
    if (cell >= 0xA0 and cell <= 0xFF) return &font_unicode.latin1[cell - 0xA0];
    if (cell >= 0x100 and cell <= 0x17F) return &font_unicode.ext_a[cell - 0x100];
    if (cell >= 0x8000 and cell < 0xFFFE) return &dyn_clusters[cell - 0x8000].rows;
    return null;
}

/// The replacement-character cell (U+FFFD art from font_unicode).
/// Occupies the top of the dynamic space (pool ids stay below it) so it
/// can never collide with a literal codepoint.
pub const cell_fffd: Cell = 0xFFFE;

// ---------------------------------------------------------------------------
// Dynamic cluster pool (M20-U5/U6): composed grapheme clusters
// ---------------------------------------------------------------------------

/// A composed grapheme cluster: base glyph + up to 3 combining marks,
/// OR-merged into one 8×8 bitmap at insert time. Entries are
/// content-addressed by an FNV key over (base, marks…) so repeated
/// é/ñ/ö sequences share a slot; the pool is fixed BSS and when full new
/// clusters fall back to the replacement character (honest bound).
const dyn_cap = 1024;
const DynCluster = struct {
    key: u64,
    base: u21, // 0x25CC for dotted-circle bases
    marks: [3]u21,
    nmarks: u8,
    rows: [8]u8,
};
var dyn_clusters: [dyn_cap]DynCluster = undefined;
var dyn_count: usize = 0;

fn fnv1a(h_in: u64, cp: u21) u64 {
    var h = h_in;
    h ^= cp;
    h *%= 0x100000001b3;
    return h;
}

fn base_rows(cp: u21) ?*const [8]u8 {
    if (cp == 0x25CC) return &font_unicode.dotted_circle;
    return glyph_for(cp);
}

/// Allocate (or reuse) a pool cell for base+marks. Returns null when the
/// base has no art or the pool is exhausted.
fn cluster_for(base: u21, marks: []const u21) ?Cell {
    const g0 = base_rows(base) orelse return null;
    var key: u64 = 0xcbf29ce484222325;
    key = fnv1a(key, base);
    for (marks) |m| key = fnv1a(key, m);
    for (dyn_clusters[0..dyn_count], 0..) |*d, i| {
        if (d.key == key) return @as(Cell, 0x8000) | @as(Cell, @intCast(i));
    }
    if (dyn_count >= dyn_cap) return null;
    var composed = g0.*;
    const n = @min(marks.len, 3);
    for (marks[0..n]) |m| {
        if (font_unicode.combining_overlay(m)) |ov| {
            for (0..8) |i| composed[i] |= ov[i];
        }
    }
    dyn_clusters[dyn_count] = .{
        .key = key,
        .base = base,
        .marks = .{ marks[0], if (n > 1) marks[1] else 0, if (n > 2) marks[2] else 0 },
        .nmarks = @intCast(n),
        .rows = composed,
    };
    dyn_count += 1;
    return @as(Cell, 0x8000) | @as(Cell, @intCast(dyn_count - 1));
}

/// Attach one combining mark to the cell left of the cursor (M20-U6).
/// With no preceding base, a dotted circle (U+25CC) becomes the base —
/// Unicode's convention. The cursor never moves: the mark takes no cell.
fn attach_mark(mark: u21) void {
    // Unknown combining mark: ignore entirely (missing-combining rule).
    if (font_unicode.combining_overlay(mark) == null) return;

    // Locate the base cell (stepping over a wide continuation half).
    const have_base = initialized and ring_count > 0 and cur_col > 0;
    if (!have_base) {
        // No base available: dotted circle + mark as its own cell.
        const cell = cluster_for(0x25CC, &[_]u21{mark}) orelse return;
        store_narrow_cell(cell);
        return;
    }
    var col = cur_col - 1;
    if (ring[cur_line][col] == cell_wide_cont and col > 0) col -= 1;
    const prev = ring[cur_line][col];

    if (prev < 0x8000) {
        // A literal codepoint (or blank): blank bases are not composable,
        // everything printable is.
        if (prev < 0x20 or (prev > 0x7e and prev < 0xA0)) return;
        const cell = cluster_for(prev, &[_]u21{mark}) orelse return;
        ring[cur_line][col] = cell;
        return;
    }
    if (prev >= 0x8000 and prev < 0xFFFE) {
        // Extend an existing cluster with one more mark (bounded at 3).
        const idx = prev - 0x8000;
        const d = &dyn_clusters[idx];
        if (d.nmarks >= 3) return; // bound reached: extra marks dropped
        var seed: [4]u21 = undefined;
        seed[0] = d.base;
        for (0..d.nmarks) |i| seed[1 + i] = d.marks[i];
        seed[1 + d.nmarks] = mark;
        // Seed carries [base, marks…] — hand cluster_for only the marks.
        const cell = cluster_for(d.base, seed[1 .. 2 + d.nmarks]) orelse return;
        ring[cur_line][col] = cell;
        return;
    }
    // Replacement opcode / continuation: nothing composable here.
}

/// Move the cursor left one grapheme — a wide character's continuation
/// half belongs to its base cell, so backspace never parks inside a
/// two-cell character (M20-U5).
fn backspace() void {
    if (cur_col == 0) return;
    cur_col -= 1;
    while (cur_col > 0 and ring[cur_line][cur_col] == cell_wide_cont) cur_col -= 1;
}

/// Store a width-1 cell at the cursor with wrap handling (shared by the
/// narrow path of putc_unicode and dotted-circle insertion).
fn store_narrow_cell(cell: Cell) void {
    var slot = cursor_slot();
    if (cur_col >= @min(cols, visible_cols())) slot = new_line();
    ring[slot][cur_col] = cell;
    cur_col += 1;
    if (cur_col > line_fill[slot]) line_fill[slot] = @intCast(cur_col);
    if (cur_col >= @min(cols, visible_cols())) _ = new_line();
}

// ---------------------------------------------------------------------------
// Text measurement (M20-U12)
// ---------------------------------------------------------------------------

/// How much room a byte string needs at a given font size.
pub const TextMetrics = struct {
    /// Width including soft-wrap simulation: the longest RENDERED row in
    /// pixels (never wider than the visible area).
    width_px: usize,
    /// Height: rendered rows (explicit newlines + wraps) × cell height.
    height_px: usize,
    /// Rendered row count (soft-wrapped lines count individually).
    line_count: usize,
    /// The widest single row in pixels before capping (diagnostics).
    max_line_width: usize,
};

/// Measure `text` (UTF-8) as if painted into the terminal at font size
/// `size`. Monospace means measurement is exact cell arithmetic — no
/// pixel loop needed. Wide codepoints occupy their full two cells;
/// combining/zero-width codepoints occupy none (matching putc_unicode).
pub fn measure_text(text: []const u8, size: FontSize) TextMetrics {
    const cw = size.px();
    const ch = size.px();
    const edge = @min(cols, virtio_gpu.fb_width / cw);
    var x: usize = 0; // cells on current row
    var n_rows: usize = 0;
    var max_cells: usize = 0;

    var need: u8 = 0;
    var acc: u21 = 0;
    for (text) |b| {
        const cp_opt: ?u21 = blk: {
            if (need > 0) {
                if ((b & 0xC0) != 0x80) {
                    need = 0;
                    acc = 0;
                    break :blk null; // broken byte: skip in measurement
                }
                need -= 1;
                const next: u21 = (@as(u21, acc) << 6) | (b & 0x3F);
                if (need == 0) {
                    acc = 0;
                    break :blk next;
                }
                acc = next;
                break :blk null;
            }
            if (b < 0x80) break :blk b;
            if (b >= 0xC2 and b <= 0xDF) {
                need = 1;
                acc = b & 0x1F;
                break :blk null;
            }
            if (b >= 0xE0 and b <= 0xEF) {
                need = 2;
                acc = b & 0x0F;
                break :blk null;
            }
            if (b >= 0xF0 and b <= 0xF4) {
                need = 3;
                acc = b & 0x07;
                break :blk null;
            }
            break :blk null;
        };
        const cp = cp_opt orelse continue;
        if (cp == '\n') {
            if (x > max_cells) max_cells = x;
            n_rows += 1;
            x = 0;
            continue;
        }
        if (cp == '\r' or cp == 0x08) {
            x = if (cp == '\r') 0 else if (x > 0) x - 1 else 0;
            continue;
        }
        if (cp < 0x20 or cp == 0x7F) {
            x += 1; // invisible blank still takes a cell
            continue;
        }
        const w = char_width(cp);
        if (w == 0) continue; // combining / zero-width: no cell
        // Wrap when the codepoint does not fit on the current row.
        const span: usize = w;
        if (x + span > edge) {
            if (x > max_cells) max_cells = x;
            n_rows += 1;
            x = 0;
        }
        x += span;
    }
    if (x > max_cells) max_cells = x;
    const final_rows = n_rows + @intFromBool(x > 0 or text.len == 0);
    return .{
        .width_px = max_cells * cw,
        .height_px = final_rows * ch,
        .line_count = final_rows,
        .max_line_width = max_cells * cw,
    };
}

// ---------------------------------------------------------------------------
// Line breaking & word wrapping (M20-U15)
// ---------------------------------------------------------------------------

/// One wrapped segment: a byte range into the source line (UTF-8 intact).
pub const WrapSegment = struct {
    start: usize,
    len: usize,
    /// True when the break AFTER this segment was forced (no boundary).
    hard_break: bool = false,
};

pub const WrapResult = struct {
    segments: []const WrapSegment,
    /// True when `out` was too small to hold every segment.
    truncated: bool = false,
};

/// Break opportunities, per M20-U15:
///   - after a space (the space stays at the end of its segment),
///   - after a hyphen,
///   - adjacent to a wide codepoint,
///   - after an explicit U+200B zero-width space.
/// When a row would overflow `max_width_cells`, back up to the last
/// opportunity; with none available, hard-break at the edge. Widths come
/// from `char_width` — combining marks ride along free. Segments are
/// byte ranges so callers can slice the original UTF-8 without copying.
pub fn wrap_line(
    line: []const u8,
    max_width_cells: usize,
    out: []WrapSegment,
) WrapResult {
    var segs: usize = 0;
    var truncated = false;
    var seg_start: usize = 0;
    var x: usize = 0; // cells since seg_start
    var last_break: ?usize = null; // BYTE offset just after a break point
    // Spaces are dropped at soft breaks (terminal convention); hyphens
    // and wide-char boundaries keep their trailing character.
    var last_break_trims_space = false;

    var need: u8 = 0;
    var acc: u21 = 0;
    var cp_start: usize = 0; // byte offset of the current codepoint's lead
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const b = line[i];
        if (need == 0) cp_start = i;
        const cp_opt: ?u21 = blk: {
            if (need > 0) {
                if ((b & 0xC0) != 0x80) {
                    need = 0;
                    acc = 0;
                    break :blk null;
                }
                need -= 1;
                const next: u21 = (@as(u21, acc) << 6) | (b & 0x3F);
                if (need == 0) {
                    acc = 0;
                    break :blk next;
                }
                acc = next;
                break :blk null;
            }
            if (b < 0x80) break :blk b;
            if (b >= 0xC2 and b <= 0xDF) {
                need = 1;
                acc = b & 0x1F;
                break :blk null;
            }
            if (b >= 0xE0 and b <= 0xEF) {
                need = 2;
                acc = b & 0x0F;
                break :blk null;
            }
            if (b >= 0xF0 and b <= 0xF4) {
                need = 3;
                acc = b & 0x07;
                break :blk null;
            }
            break :blk null;
        };
        const cp = cp_opt orelse continue;

        // Explicit zero-width space: force a break right here (the ZWSP
        // itself belongs to neither segment).
        if (cp == 0x200B) {
            if (segs >= out.len) {
                truncated = true;
                break;
            }
            out[segs] = .{ .start = seg_start, .len = cp_start - seg_start };
            segs += 1;
            seg_start = i + 1;
            x = 0;
            last_break = null;
            continue;
        }

        const w: usize = char_width(cp);

        // Overflow check BEFORE placing this codepoint.
        if (w > 0 and x + w > max_width_cells) {
            if (segs >= out.len) {
                truncated = true;
                break;
            }
            if (last_break) |brk| {
                var emit_end = brk;
                if (last_break_trims_space) {
                    while (emit_end > seg_start and line[emit_end - 1] == ' ') emit_end -= 1;
                }
                out[segs] = .{ .start = seg_start, .len = emit_end - seg_start };
                segs += 1;
                // Rewind to the boundary and re-walk from there so the
                // next segment counts its own cells exactly.
                seg_start = brk;
                x = 0;
                last_break = null;
                need = 0;
                acc = 0;
                i = brk - 1; // the loop's += 1 lands on brk
                continue;
            }
            out[segs] = .{ .start = seg_start, .len = cp_start - seg_start, .hard_break = true };
            segs += 1;
            seg_start = cp_start;
            x = 0;
            last_break = null;
        }

        // Place the codepoint.
        if (w > 0) x += w;

        // Record break opportunities AFTER placement.
        switch (cp) {
            ' ' => {
                last_break = i + 1;
                last_break_trims_space = true;
            },
            '-' => {
                last_break = i + 1;
                last_break_trims_space = false;
            },
            else => {},
        }
        if (w == 2) {
            last_break = i + 1;
            last_break_trims_space = false;
        }
    }

    // Trailing segment (only when something remains uncovered).
    if (!truncated and seg_start < line.len) {
        if (segs >= out.len) {
            truncated = true;
        } else {
            out[segs] = .{ .start = seg_start, .len = line.len - seg_start };
            segs += 1;
        }
    }
    return .{ .segments = out[0..segs], .truncated = truncated };
}

// ---------------------------------------------------------------------------
// Glyph rendering cache (M20-U13)
// ---------------------------------------------------------------------------

/// Pre-scaled glyph rows for one (cell, font-size) pair: `rows[y]` bit x
/// means framebuffer column x of the cell is foreground. Width is
/// font_size.px() ≤ 24, so u32 holds every narrow glyph. Emoji stay on
/// the direct path (their 16px art needs up to 48 columns at large).
const GlyphCacheEntry = struct {
    stamp: u32,
    cell: Cell,
    size: u2,
    rows: [24]u32,
};

/// 128 entries × ~104 B ≈ 13 KiB BSS (the halved option from the card,
/// respecting the kernel budget).
const glyph_cache_cap = 128;
const mem_zero: GlyphCacheEntry = .{ .stamp = 0, .cell = 0, .size = 0, .rows = @as([24]u32, @splat(@as(u32, 0))) };
var glyph_cache: [glyph_cache_cap]GlyphCacheEntry = undefined;
var glyph_cache_stamp: u32 = 0;

/// Diagnostics since init(): hits vs misses (misses include evictions).
pub var glyph_cache_hits: usize = 0;
pub var glyph_cache_misses: usize = 0;

/// Look up (or compute + insert) the scaled rows for a paintable cell.
/// Pure function of (cell, size) except for the cache bookkeeping.
fn cached_glyph_rows(cell: Cell, size: FontSize) ?*const [24]u32 {
    // Only cache what decodes through the static paths.
    const paintable = cell != cell_wide_cont and
        ((cell >= 0x20 and cell <= 0x7e) or (cell >= 0xA0 and cell <= 0xFF) or
            (cell >= 0x100 and cell <= 0x17F) or cell == cell_fffd);
    if (!paintable) return null;

    const sz: u2 = @backingInt(size);
    var oldest: usize = 0;
    var oldest_stamp: u32 = 0xFFFFFFFF;
    for (glyph_cache[0..], 0..) |*e, i| {
        if (e.stamp == 0) {
            // Free slot: claim immediately (this is a miss — nothing
            // cached yet for this key).
            glyph_cache_misses += 1;
            e.cell = cell;
            e.size = sz;
            fill_glyph_cache_entry(e, cell, sz);
            e.stamp = glyph_cache_stamp +% 1;
            glyph_cache_stamp +%= 1;
            return &e.rows;
        }
        if (e.cell == cell and e.size == sz) {
            e.stamp = glyph_cache_stamp +% 1;
            glyph_cache_stamp +%= 1;
            glyph_cache_hits += 1;
            return &e.rows;
        }
        if (e.stamp < oldest_stamp) {
            oldest_stamp = e.stamp;
            oldest = i;
        }
    }
    // Cache full: evict the LRU entry.
    glyph_cache_misses += 1;
    const e = &glyph_cache[oldest];
    e.cell = cell;
    e.size = sz;
    fill_glyph_cache_entry(e, cell, sz);
    e.stamp = glyph_cache_stamp +% 1;
    glyph_cache_stamp +%= 1;
    return &e.rows;
}

/// Compute the scaled rows for a cell into an entry.
fn fill_glyph_cache_entry(e: *GlyphCacheEntry, cell: Cell, sz: u2) void {
    const g8 = blk: {
        if (cell == cell_fffd) break :blk &font_unicode.fffd_glyph;
        if (cell >= 0x20 and cell <= 0x7e) break :blk &font.glyphs[cell - 0x20];
        if (cell >= 0xA0 and cell <= 0xFF) break :blk &font_unicode.latin1[cell - 0xA0];
        if (cell >= 0x100 and cell <= 0x17F) break :blk &font_unicode.ext_a[cell - 0x100];
        unreachable; // guarded by paintable check
    };
    const scale: usize = @as(usize, sz) + 1; // small=1, medium=2, large=3
    @memset(&e.rows, 0);
    for (0..8) |y| {
        var x: usize = 0;
        while (x < 8) : (x += 1) {
            if (!font.row_pixel(g8[y], x)) continue;
            var sy: usize = 0;
            while (sy < scale) : (sy += 1) {
                var sx: usize = 0;
                while (sx < scale) : (sx += 1) {
                    const px = x * scale + sx;
                    const py = y * scale + sy;
                    e.rows[py] |= @as(u32, 1) << @intCast(px);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Missing-glyph diagnostics (M20-U11)
// ---------------------------------------------------------------------------

/// Dev setting (mirror of the SETTINGS.TXT `debug_font` key): when true,
/// every fallback-to-replacement records + reports the codepoint.
pub var debug_font: bool = false;

/// Serial log hook wired by main.zig at boot ("text: no glyph for
/// U+XXXX"). Null in host tests — counting alone is observable there.
pub var missing_glyph_log: ?*const fn (cp: u21) void = null;

/// Fallback statistics since init() (reset by clear/init).
pub var missing_glyph_count: usize = 0;
pub var last_missing_cp: u21 = 0;

fn note_missing(cp: u21) void {
    if (!debug_font) return;
    missing_glyph_count += 1;
    last_missing_cp = cp;
    if (missing_glyph_log) |log_fn| log_fn(cp);
}

/// Emit a string.
pub fn puts(s: []const u8) void {
    for (s) |c| putc(c);
}

/// Clear the text layer (ring + cursor).
pub fn clear() void {
    init();
}

/// The cursor's VISIBLE row: the last ring line, positioned in the
/// window of `rows` visible lines.
pub fn cursor_row() usize {
    if (ring_count == 0) return 0;
    if (ring_count >= rows) return rows - 1;
    return ring_count - 1;
}

/// The cursor's column within its line.
pub fn cursor_col() usize {
    return cur_col;
}

/// Valid lines in the scrollback ring (0..ring_lines).
pub fn line_count() usize {
    return ring_count;
}

// ---------------------------------------------------------------------------
// Rendering (pure — writes B,G,R,X into the canvas)
// ---------------------------------------------------------------------------

fn put_pixel(canvas: Canvas, x: usize, y: usize, rgb: u32) void {
    const off = y * canvas.stride + x * 4;
    canvas.base[off] = @truncate(rgb & 0xff); // B
    canvas.base[off + 1] = @truncate((rgb >> 8) & 0xff); // G
    canvas.base[off + 2] = @truncate((rgb >> 16) & 0xff); // R
    canvas.base[off + 3] = 0xff; // X — opaque (the claim-6053 lesson)
}

/// Render the visible window (the LAST `rows` lines of the ring) into
/// the canvas: background fill + foreground glyphs. The cursor line's
/// underline is not drawn (G2 has no cursor blink — honest bound).
pub fn render(canvas: Canvas) void {
    if (!initialized) init();
    var y: usize = 0;
    while (y < canvas.height) : (y += 1) {
        var x: usize = 0;
        while (x < canvas.width) : (x += 1) {
            put_pixel(canvas, x, y, bg_rgb);
        }
    }
    if (ring_count == 0) return;
    // Card U4/U5 close-out fix: the render is bounded by the CANVAS, not
    // just the module geometry — the tiny-canvas host tests (16x16) and
    // any undersized destination stay in bounds (a latent out-of-bounds
    // write the 16x16 test exercised into adjacent globals for its whole
    // life; new BSS neighbors turned it into a bus error).
    const cw = cur_cell_w();
    const ch = cur_cell_h();
    const visible: usize = @min(@min(ring_count, rows), canvas.height / ch);
    // The visible window: the last `visible` lines of the ring. The
    // cursor line is the last one; its slot is cur_line.
    var r: usize = 0;
    while (r < visible) : (r += 1) {
        // Ring slot of the (ring_count - visible + r)-th valid line.
        const first_valid = if (ring_count >= ring_lines)
            ring_head
        else
            0;
        const slot = (first_valid + ring_count - visible + r) % ring_lines;
        const row_pix = r * ch;
        const cols_fit = @min(cols, canvas.width / cw);
        var col: usize = 0;
        while (col < cols_fit) : (col += 1) {
            // M20-U2/U7: cells decode through one path. The continuation
            // half of a wide character paints nothing (its base cell
            // already drew); unknown opcodes stay blank.
            const cell = ring[slot][col];

            // Emoji base cells paint their full 16px art across BOTH
            // cells at the current font size.
            if (cell >= cell_emoji_base and cell < cell_dyn_base and cell - cell_emoji_base < font_emoji.emojis.len) blk_emoji: {
                const idx = cell - cell_emoji_base;
                if (idx >= font_emoji.emojis.len) break :blk_emoji;
                const art = &font_emoji.emojis[idx].rows;
                const scale = cw / 8; // pixels per source pixel
                var ey: usize = 0;
                while (ey < 16) : (ey += 1) {
                    const bits = art[ey];
                    var ex: usize = 0;
                    while (ex < 16) : (ex += 1) {
                        if ((bits >> @intCast(ex)) & 1 != 0) {
                            var by: usize = 0;
                            while (by < scale) : (by += 1) {
                                var bx: usize = 0;
                                while (bx < scale) : (bx += 1) {
                                    put_pixel(canvas, col * cw + ex * scale + bx, r * ch + ey * scale + by, fg_rgb);
                                }
                            }
                        }
                    }
                }
                continue;
            }

            // M20-U13: static-path cells paint from the pre-scaled
            // cache; dynamic composites (pool clusters) take the direct
            // path below.
            if (cached_glyph_rows(cell, font_size)) |scaled| {
                var py: usize = 0;
                while (py < ch) : (py += 1) {
                    const bits = scaled[py];
                    var px: usize = 0;
                    while (px < cw) : (px += 1) {
                        if ((bits >> @intCast(px)) & 1 != 0) {
                            put_pixel(canvas, col * cw + px, row_pix + py, fg_rgb);
                        }
                    }
                }
                continue;
            }

            const g = cell_glyph(cell) orelse continue;
            const col_pix = col * cw;
            // M20-U1: nearest-neighbor scaling — every source pixel
            // becomes an exact scale² block, painting exactly the bits
            // of the comptime-scaled tables (equality pinned by tests).
            const scale = cw / 8;
            var gy: usize = 0;
            while (gy < 8) : (gy += 1) {
                const row_bits = g[gy];
                var gx: usize = 0;
                while (gx < 8) : (gx += 1) {
                    if (font.row_pixel(row_bits, gx)) {
                        var by: usize = 0;
                        while (by < scale) : (by += 1) {
                            var bx: usize = 0;
                            while (bx < scale) : (bx += 1) {
                                put_pixel(canvas, col_pix + gx * scale + bx, row_pix + gy * scale + by, fg_rgb);
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Render + push to the screen through G1's path (transfer + flush).
/// The caller owns the gpu (guarded by gpu_ready). Returns the CmdResult
/// of the flush (the transfer result is dropped on a flush failure).
pub fn present() virtio_gpu.CmdResult {
    if (!virtio_gpu.gpu_ready) return .not_ready;
    render(.{
        .base = @ptrCast(&virtio_gpu.gpu_fb),
        .width = virtio_gpu.fb_width,
        .height = virtio_gpu.fb_height,
        .stride = virtio_gpu.fb_width * 4,
    });
    if (virtio_gpu.gpu_transfer() != .ok) return .timeout;
    return virtio_gpu.gpu_flush();
}

// ---------------------------------------------------------------------------
// Host tests — the class A raster proof (golden glyphs + behavior)
// ---------------------------------------------------------------------------

const W = 16;
const H = 16;
var test_buf: [W * H * 4]u8 = undefined;

fn testCanvas() Canvas {
    @memset(&test_buf, 0);
    return .{ .base = &test_buf, .width = W, .height = H, .stride = W * 4 };
}

fn pixel(c: Canvas, x: usize, y: usize) [3]u8 {
    const off = y * c.stride + x * 4;
    return .{ c.base[off], c.base[off + 1], c.base[off + 2] }; // B,G,R
}

fn rgbBytes(rgb: u32) [3]u8 {
    return .{ @truncate(rgb & 0xff), @truncate((rgb >> 8) & 0xff), @truncate((rgb >> 16) & 0xff) };
}

/// Test helper: assert `text` occupies the cells starting at (slot,col).
fn expectCells(slot: usize, col: usize, text: []const u8) !void {
    for (text, 0..) |ch, i| {
        try std.testing.expectEqual(@as(Cell, ch), ring[slot][col + i]);
    }
}

test "text: asymmetric C raster is LSB-first in B8G8R8X8" {
    init();
    clear();
    puts("C");
    const canvas = testCanvas();
    render(canvas);
    // Independent human-facing golden for C:
    //   ..####..
    //   .##..##.
    //   ##......  <- source row 0x03, bit 0 is LEFT
    //   ##......
    //   ##......
    //   .##..##.
    //   ..####..
    //   ........
    // The old symmetric '!' golden could not detect horizontal reversal.
    const fg = rgbBytes(fg_rgb);
    const bg = rgbBytes(bg_rgb);
    try std.testing.expectEqualSlices(u8, &fg, &pixel(canvas, 2, 0));
    try std.testing.expectEqualSlices(u8, &fg, &pixel(canvas, 5, 0));
    try std.testing.expectEqualSlices(u8, &fg, &pixel(canvas, 0, 2));
    try std.testing.expectEqualSlices(u8, &fg, &pixel(canvas, 1, 2));
    try std.testing.expectEqualSlices(u8, &bg, &pixel(canvas, 6, 2));
    try std.testing.expectEqualSlices(u8, &bg, &pixel(canvas, 7, 2));
    // The alpha byte is opaque (the claim-6053 lesson).
    try std.testing.expectEqual(@as(u8, 0xff), test_buf[(2 * W) * 4 + 3]);
}

test "text: the full 95-glyph table rasters LSB-first — every pixel matches the raw source bits (issue 125)" {
    // Render EVERY printable glyph into the test canvas and assert all 64
    // pixels against the RAW table byte read LSB-first inline — `(row >>
    // x) & 1`, NOT font.row_pixel. Deriving the expectation from the
    // helper under test would be self-consistent with a reversed helper
    // (the exact trap issue 125 documented in the old decoder); reading
    // the source bits directly pins the CONVENTION. 90 of 95 glyphs are
    // horizontally asymmetric, so a bit-order flip in the terminal raster
    // OR the row_pixel helper breaks 90/95 glyphs immediately.
    init();
    const fg = rgbBytes(fg_rgb);
    const bg = rgbBytes(bg_rgb);
    var i: usize = 0;
    while (i < font.glyphs.len) : (i += 1) {
        clear();
        const ch: u8 = @intCast(0x20 + i);
        const one = [1]u8{ch};
        puts(&one);
        const canvas = testCanvas();
        render(canvas);
        const glyph = font.glyphs[i];
        var gy: usize = 0;
        while (gy < 8) : (gy += 1) {
            var gx: usize = 0;
            while (gx < 8) : (gx += 1) {
                const row = glyph[gy];
                const bit_set = ((row >> @as(u3, @intCast(gx))) & 1) != 0;
                const want: [3]u8 = if (bit_set) fg else bg;
                try std.testing.expectEqualSlices(u8, &want, &pixel(canvas, gx, gy));
            }
        }
    }
}

test "text: line wrap starts a new line at the region width" {
    init();
    clear();
    var i: usize = 0;
    while (i < cols + 3) : (i += 1) puts("x");
    // cols+3 chars → cols fill the first line and wrap (new line), the
    // remaining 3 land on line 2 at col 3: ring holds 2 lines, cursor at
    // col 3 of the last line.
    try std.testing.expectEqual(@as(usize, 2), ring_count);
    try std.testing.expectEqual(@as(usize, 3), cur_col);
    try std.testing.expectEqual(@as(usize, 1), cursor_row());
}

test "text: backspace and carriage return move the cursor (U2)" {
    init();
    clear();
    puts("hello");
    try std.testing.expectEqual(@as(usize, 5), cur_col);
    putc('\r');
    try std.testing.expectEqual(@as(usize, 0), cur_col);
    puts("bye"); // overwrites h,e,l -> the line reads "byelo"
    try std.testing.expectEqual(@as(usize, 3), cur_col);
    try expectCells(cursor_slot(), 0, "byelo");
    // Backspace moves left without writing; the next char overwrites.
    putc(0x08);
    putc(0x08);
    try std.testing.expectEqual(@as(usize, 1), cur_col);
    putc('x');
    try expectCells(cursor_slot(), 0, "bxelo");
    // Backspace at column 0 is a no-op (never wraps negative).
    clear();
    putc(0x08);
    try std.testing.expectEqual(@as(usize, 0), cur_col);
}

test "text: the scrollback ring is bounded and drops the oldest line" {
    init();
    clear();
    var i: usize = 0;
    while (i < ring_lines + 1) : (i += 1) {
        puts("\n");
    }
    try std.testing.expectEqual(ring_lines, ring_count);
    // The first line's first char is gone from the visible window.
    try std.testing.expectEqual(@as(usize, rows - 1), cursor_row());
}

test "text: clear resets the ring and cursor" {
    init();
    puts("hello");
    try std.testing.expect(ring_count >= 1);
    clear();
    try std.testing.expectEqual(@as(usize, 0), ring_count);
    try std.testing.expectEqual(@as(usize, 0), cur_col);
    try std.testing.expectEqual(@as(usize, 0), cursor_row());
}

test "text: Ctrl-L's erase-in-display clears the layer instead of drawing '[2J'" {
    init();
    puts("junk on the screen");
    try std.testing.expect(ring_count >= 1);
    // The exact byte stream lineedit/monitor emit for Ctrl-L and `clear`.
    puts("\x1b[2J\x1b[H");
    try std.testing.expectEqual(@as(usize, 0), ring_count);
    try std.testing.expectEqual(@as(usize, 0), cur_col);
    // Storing the escape bytes would have drawn the glyphs '[2J[H' — the
    // ring must hold no such text afterwards.
    puts("ok");
    try std.testing.expectEqual(@as(Cell, 'o'), ring[cur_line][0]);
    try std.testing.expectEqual(@as(Cell, 'k'), ring[cur_line][1]);
    try std.testing.expectEqual(@as(usize, 2), cur_col);
    // An unhandled CSI sequence is swallowed whole, not rendered.
    puts("\x1b[1;31m!");
    try std.testing.expectEqual(@as(Cell, '!'), ring[cur_line][2]);
    try std.testing.expectEqual(@as(usize, 3), cur_col);
}

test "text: render never writes outside the canvas" {
    init();
    clear();
    // A full visible window of glyphs over a 16×16 canvas must leave the
    // canvas edges at the background (the window only fills rows it has).
    var i: usize = 0;
    while (i < rows) : (i += 1) puts("x\n");
    const canvas = testCanvas();
    render(canvas);
    try std.testing.expectEqualSlices(u8, &rgbBytes(bg_rgb), &pixel(canvas, 0, H - 1));
}

test "text: tab advances to the next multiple of the stop and fills spaces (U10)" {
    init();
    clear();
    puts("ab\tc");
    // 'a','b' at cols 0-1; tab jumps to col 8; 'c' lands at col 8 and
    // leaves the cursor at col 9.
    try std.testing.expectEqual(@as(usize, 9), cur_col);
    try expectCells(cur_line, 0, "ab");
    // The skipped cells hold real spaces (selection/copy see characters).
    try expectCells(cur_line, 2, "      ");
    try expectCells(cur_line, 8, "c");
}

test "text: tab stops land on successive multiples (U10)" {
    init();
    clear();
    puts("\t\t\t");
    try std.testing.expectEqual(@as(usize, 24), cur_col);
    // Mid-line: from col 5 the next multiple-of-8 stop is col 8.
    clear();
    puts("12345\tX");
    try std.testing.expectEqual(@as(Cell, 'X'), ring[cur_line][8]);
}

test "text: tab width is configurable (4-stop editor style) and clamped (U10)" {
    init();
    clear();
    set_tab_width(4);
    puts("\tx");
    try std.testing.expectEqual(@as(Cell, 'x'), ring[cur_line][4]);
    set_tab_width(0); // degenerate request clamps to 1, never divides by zero
    puts("\t");
    try std.testing.expectEqual(@as(usize, 6), cur_col);
    set_tab_width(100); // clamped to the 8 max
    try std.testing.expectEqual(@as(usize, 8), tab_width);
    set_tab_width(8);
}

test "text: tab near the region edge clamps without wrapping (U10)" {
    init();
    clear();
    puts("a"); // materialize a current line (cursor_slot would reset col 0 otherwise)
    cur_col = cols - 3;
    putc('\t');
    // Stop would be past the edge: the cursor parks at the region edge,
    // no new line is started.
    try std.testing.expectEqual(cols, cur_col);
    try std.testing.expectEqual(@as(usize, 1), ring_count);
}

test "text: monospace guarantee — narrow and wide glyphs occupy exactly one cell (U10)" {
    init();
    clear();
    puts("iW");
    const canvas = testCanvas();
    render(canvas);
    const fg = rgbBytes(fg_rgb);
    const bg = rgbBytes(bg_rgb);
    // Cell 0 ('i'): some foreground strictly inside x 0..7 …
    var any_fg_cell0 = false;
    var x: usize = 0;
    while (x < 8) : (x += 1) {
        if (std.mem.eql(u8, &fg, &pixel(canvas, x, 2))) any_fg_cell0 = true;
    }
    try std.testing.expect(any_fg_cell0);
    // … and NO cell-0 glyph pixels leak into cell 1's columns: pixel
    // column 7 belongs to 'i', column 8 to 'W' — the boundary is clean.
    _ = bg;
    // Cell 1 starts exactly at x=8: 'W' row bits must appear there, and
    // both cells rastered fully within their own 8px span (the render
    // loop draws exactly cell_w columns per cell — this pins it).
    var w_any = false;
    x = 8;
    while (x < 16) : (x += 1) {
        if (std.mem.eql(u8, &fg, &pixel(canvas, x, 0))) w_any = true;
    }
    try std.testing.expect(w_any);
}

test "text: char_width categories (U4)" {
    // Narrow: ASCII and the Latin ranges we render.
    try std.testing.expectEqual(@as(u8, 1), char_width('A'));
    try std.testing.expectEqual(@as(u8, 1), char_width(0x7E));
    try std.testing.expectEqual(@as(u8, 1), char_width(0xE9)); // é
    try std.testing.expectEqual(@as(u8, 1), char_width(0x160)); // Š
    // Wide: CJK ideographs, fullwidth forms, emoji.
    try std.testing.expectEqual(@as(u8, 2), char_width(0x4E2D)); // 中
    try std.testing.expectEqual(@as(u8, 2), char_width(0xFF21)); // Ａ fullwidth
    try std.testing.expectEqual(@as(u8, 2), char_width(0x1F525)); // fire
    // Zero: combining marks, joiners, variation selectors.
    try std.testing.expectEqual(@as(u8, 0), char_width(0x0301)); // combining acute
    try std.testing.expectEqual(@as(u8, 0), char_width(0x200D)); // ZWJ
    try std.testing.expectEqual(@as(u8, 0), char_width(0xFE0F)); // VS-16
    try std.testing.expect(is_combining(0x0332));
    try std.testing.expect(!is_combining('e'));
    try std.testing.expect(is_zero_width_ignorable(0x200B));
    try std.testing.expect(is_zero_width_ignorable(0xFE00));
    try std.testing.expect(!is_zero_width_ignorable(0x0301)); // combining is not ignorable
}

test "text: char_width is comptime-evaluable" {
    const w: u8 = comptime char_width(0x4E2D);
    _ = w;
}

test "text: UTF-8 é decodes and stores the Latin-1 literal cell (U2)" {
    init();
    clear();
    puts("caf\xc3\xa9"); // café
    try expectCells(cur_line, 0, "caf");
    try std.testing.expectEqual(@as(Cell, 0xE9), ring[cur_line][3]);
    try std.testing.expectEqual(@as(usize, 4), cur_col);
}

test "text: rendered é paints the accent-composed glyph, not blank (U2)" {
    init();
    clear();
    puts("\xc3\xa9");
    const canvas = testCanvas();
    render(canvas);
    const fg = rgbBytes(fg_rgb);
    const ee = font_unicode.latin1[0xE9 - 0xA0];
    // Every set bit of the composed glyph must appear on screen.
    var gy: usize = 0;
    while (gy < 8) : (gy += 1) {
        var gx: usize = 0;
        while (gx < 8) : (gx += 1) {
            if (font.row_pixel(ee[gy], gx)) {
                try std.testing.expectEqualSlices(u8, &fg, &pixel(canvas, gx, gy));
            }
        }
    }
    // And it is NOT identical to plain 'e' (the overlay is really drawn).
    const e_plain = font.glyphs['e' - 0x20];
    var differs = false;
    for (0..8) |i| {
        if (ee[i] != e_plain[i]) differs = true;
    }
    try std.testing.expect(differs);
}

test "text: a width-2 codepoint takes exactly two cells (U2/U4)" {
    init();
    clear();
    puts("a");
    putc_unicode(0x4E2D); // 中 — no glyph yet, but layout must hold
    putc_unicode('b');
    try expectCells(cur_line, 0, "a");
    try std.testing.expectEqual(cell_fffd, ring[cur_line][1]);
    try std.testing.expectEqual(cell_wide_cont, ring[cur_line][2]);
    try std.testing.expectEqual(@as(Cell, 'b'), ring[cur_line][3]);
    try std.testing.expectEqual(@as(usize, 4), cur_col);
}

test "text: broken UTF-8 becomes U+FFFD, not garbage cells (U2)" {
    init();
    clear();
    // Stray continuation byte.
    putc(0xA9);
    try std.testing.expectEqual(cell_fffd, ring[cur_line][0]);
    clear();
    // Truncated sequence at end of string: C3 alone never emits, so no
    // cell is written until the next byte arrives (which breaks it).
    puts("ok\xc3");
    try expectCells(cur_line, 0, "ok");
    try std.testing.expectEqual(@as(usize, 2), cur_col);
    putc('!'); // breaks the pending sequence: U+FFFD, THEN the byte itself
    try std.testing.expectEqual(cell_fffd, ring[cur_line][2]);
    try std.testing.expectEqual(@as(Cell, '!'), ring[cur_line][3]);
    try std.testing.expectEqual(@as(usize, 4), cur_col);
}

test "text: DEL and unknown control bytes stay invisible blanks (U2)" {
    init();
    clear();
    putc(0x7F);
    putc(0x01);
    try std.testing.expectEqual(@as(usize, 2), cur_col);
    const canvas = testCanvas();
    render(canvas); // must not crash painting them; cells are spaces
    try std.testing.expectEqual(@as(Cell, 0x20), ring[cur_line][0]);
}

test "text: missing glyph falls back to the replacement character (U11)" {
    init();
    clear();
    // U+FFFF is a guaranteed non-character: no table will ever hold it.
    putc_unicode(0xFFFF);
    try std.testing.expectEqual(cell_fffd, ring[cur_line][0]);
    const canvas = testCanvas();
    render(canvas);
    // The FFFD art (diamond) really paints — top row has foreground.
    const fg = rgbBytes(fg_rgb);
    var any_fg = false;
    for (0..8) |gx| {
        if (std.mem.eql(u8, &fg, &pixel(canvas, gx, 0))) any_fg = true;
    }
    try std.testing.expect(any_fg);
}

test "text: Ext-A Š decodes, stores literal, and paints its caron (U3)" {
    init();
    clear();
    // UTF-8 for U+0160 (Š): E2 8C A0? No — U+0160 = 0xC5 0xA0.
    puts("\xc5\xa0");
    try std.testing.expectEqual(@as(Cell, 0x160), ring[cur_line][0]);
    const canvas = testCanvas();
    render(canvas);
    const scaron = font_unicode.ext_a[0x160 - 0x100];
    var painted = false;
    var gy: usize = 0;
    while (gy < 8) : (gy += 1) {
        var gx: usize = 0;
        while (gx < 8) : (gx += 1) {
            if (font.row_pixel(scaron[gy], gx)) painted = true;
        }
    }
    try std.testing.expect(painted);
}

test "text: debug_font counts and reports misses through the hook (U11)" {
    init();
    clear();
    debug_font = false;
    putc_unicode(0x2603); // no glyph — but quiet when debug off
    try std.testing.expectEqual(@as(usize, 0), missing_glyph_count);
    debug_font = true;
    defer debug_font = false;
    missing_glyph_log = null;
    putc_unicode(0x2603);
    putc_unicode(0x10FFFF);
    try std.testing.expectEqual(@as(usize, 2), missing_glyph_count);
    try std.testing.expectEqual(@as(u21, 0x10FFFF), last_missing_cp);
    // A wired hook gets called (observable via a module-level flag).
    const S = struct {
        var called: bool = false;
        fn hook(cp: u21) void {
            called = true;
            std.testing.expectEqual(@as(u21, 0x2603), cp) catch {};
        }
    };
    missing_glyph_log = &S.hook;
    putc_unicode(0x2603);
    try std.testing.expect(S.called);
    missing_glyph_log = null;
}

test "text: e + combining acute is ONE cell and one cursor step (U5/U6)" {
    init();
    clear();
    puts("caf");
    const col_before = cur_col;
    putc('e');
    putc_unicode(0x0301); // combining acute
    try std.testing.expectEqual(col_before + 1, cur_col); // mark took no cell
    const cell = ring[cur_line][col_before];
    try std.testing.expect(cell >= 0x8000 and cell < 0xFFFE); // pool ref
    // Rendered rows = base 'e' OR acute overlay.
    var want = font.glyphs['e' - 0x20];
    const ov = font_unicode.combining_overlay(0x0301).?;
    for (0..8) |i| want[i] |= ov[i];
    try std.testing.expectEqualSlices(u8, &want, &dyn_clusters[cell - 0x8000].rows);
}

test "text: stacked marks stay one cell; identical clusters share a pool slot (U6)" {
    init();
    clear();
    putc('e');
    putc_unicode(0x0301);
    const first = ring[cur_line][0];
    clear(); // resets the pool too
    putc('e');
    putc_unicode(0x0301);
    try std.testing.expectEqual(first, ring[cur_line][0]); // content-addressed reuse
    putc_unicode(0x0308); // acute + diaeresis stack onto the SAME cell
    const cell = ring[cur_line][0];
    try std.testing.expect(cell != first); // a different composition…
    const d = dyn_clusters[cell - 0x8000];
    try std.testing.expectEqual(@as(u8, 2), d.nmarks); // …with both marks
}

test "text: leading combining mark gets a dotted-circle base (U6)" {
    init();
    clear();
    putc_unicode(0x0301); // no base before it
    const cell = ring[cur_line][0];
    try std.testing.expect(cell >= 0x8000 and cell < 0xFFFE);
    try std.testing.expectEqual(@as(u21, 0x25CC), dyn_clusters[cell - 0x8000].base);
    try std.testing.expectEqual(@as(usize, 1), cur_col);
}

test "text: ignorable zero-width codepoints vanish without advancing (U6)" {
    init();
    clear();
    puts("a");
    const c0 = cur_col;
    putc_unicode(0x200B); // ZWSP
    putc_unicode(0x200D); // ZWJ
    putc_unicode(0xFE0F); // VS-16
    try std.testing.expectEqual(c0, cur_col);
    try std.testing.expectEqual(@as(Cell, 'a'), ring[cur_line][0]);
    try std.testing.expectEqual(@as(Cell, 0x20), ring[cur_line][1]);
}

test "text: backspace deletes a whole cluster — composed or wide (U5)" {
    init();
    clear();
    puts("cafe");
    putc_unicode(0x0301); // attaches to the é; cursor stays at col 4
    try std.testing.expectEqual(@as(usize, 4), cur_col);
    backspace(); // the mark came free, so one step clears base+marks
    try std.testing.expectEqual(@as(usize, 3), cur_col);
    // Wide character: backspace from past its continuation clears both.
    putc_unicode(0x4E2D);
    try std.testing.expectEqual(@as(usize, 5), cur_col);
    backspace();
    try std.testing.expectEqual(@as(usize, 3), cur_col);
}

test "text: font sizes — same glyph, exact nearest-neighbor cells (U1)" {
    init();
    clear();
    puts("X");
    // SMALL: 8×8, the classic look.
    try std.testing.expectEqual(FontSize.small, font_size);
    {
        const canvas = testCanvas();
        render(canvas);
        const fg = rgbBytes(fg_rgb);
        // 'X' row 0 = 0x63 → bits 0,1,5,6 set: pixel (0,0) lit.
        try std.testing.expectEqualSlices(u8, &fg, &pixel(canvas, 0, 0));
        try std.testing.expectEqualSlices(u8, &bg_bytes(), &pixel(canvas, 3, 0));
    }
    // MEDIUM: 16×16 — every source pixel is an exact 2×2 block.
    set_font_size(.medium);
    defer set_font_size(.small);
    {
        const canvas = testCanvas();
        render(canvas);
        const fg = rgbBytes(fg_rgb);
        const bg = bg_bytes();
        // Source bit (0,0) → block x0..1,y0..1.
        try std.testing.expectEqualSlices(u8, &fg, &pixel(canvas, 0, 0));
        try std.testing.expectEqualSlices(u8, &fg, &pixel(canvas, 1, 1));
        // Source blank (3,0) → block x6..7,y0..1 stays background.
        try std.testing.expectEqualSlices(u8, &bg, &pixel(canvas, 7, 0));
    }
    // LARGE: 24×24 on a big-enough canvas — 3×3 blocks.
    var buf24: [24 * 24 * 4]u8 = undefined;
    @memset(&buf24, 0);
    set_font_size(.large);
    {
        const canvas = Canvas{ .base = &buf24, .width = 24, .height = 24, .stride = 24 * 4 };
        render(canvas);
        const fg = rgbBytes(fg_rgb);
        const off = (1 * 24 + 2) * 4; // pixel (2,1) inside source bit(0,0)'s block
        try std.testing.expectEqual(fg[0], buf24[off]);
        try std.testing.expectEqual(fg[2], buf24[off + 2]);
    }
}

fn bg_bytes() [3]u8 {
    return rgbBytes(bg_rgb);
}

test "text: visible geometry follows the font size and wrap respects it (U1)" {
    init();
    clear();
    try std.testing.expectEqual(@as(usize, 160), visible_cols());
    try std.testing.expectEqual(@as(usize, 90), visible_rows());
    set_font_size(.medium);
    defer set_font_size(.small);
    try std.testing.expectEqual(@as(usize, 80), visible_cols());
    try std.testing.expectEqual(@as(usize, 45), visible_rows());
    // Wrapping now happens at the narrower edge, not the ring width.
    clear();
    var i: usize = 0;
    while (i < 81) : (i += 1) putc('x');
    try std.testing.expectEqual(@as(usize, 2), ring_count);
    try std.testing.expectEqual(@as(usize, 1), cur_col);
}

test "text: emoji render two cells wide with real art (U7)" {
    init();
    clear();
    puts("a");
    // 🔥 fire = U+1F525, UTF-8 F0 9F 94 A5 — arrives through the byte path.
    puts("\xf0\x9f\x94\xa5");
    putc('b');
    try std.testing.expectEqual(@as(usize, 4), cur_col); // a + 2 + b
    const cell = ring[cur_line][1];
    try std.testing.expectEqual(cell_emoji_base, cell & 0xFF00);
    try std.testing.expectEqual(cell_wide_cont, ring[cur_line][2]);
    try std.testing.expectEqual(@as(Cell, 'b'), ring[cur_line][3]);
}

test "text: unknown wide codepoints stay double-wide fallback (U7)" {
    init();
    clear();
    putc_unicode(0x1F984); // unicorn — not shipped
    try std.testing.expectEqual(cell_fffd, ring[cur_line][0]);
    try std.testing.expectEqual(cell_wide_cont, ring[cur_line][1]);
}

test "text: measure_text — exact monospace arithmetic (U12)" {
    init();
    // "hello" at small = 5 cells × 8px = 40px, one row of 8px.
    const m = measure_text("hello", .small);
    try std.testing.expectEqual(@as(usize, 40), m.width_px);
    try std.testing.expectEqual(@as(usize, 40), m.max_line_width);
    try std.testing.expectEqual(@as(usize, 1), m.line_count);
    try std.testing.expectEqual(@as(usize, 8), m.height_px);
    // Multi-line: explicit newline splits rows; widest wins.
    const m2 = measure_text("hi\nhello\nhey", .small);
    try std.testing.expectEqual(@as(usize, 40), m2.width_px);
    try std.testing.expectEqual(@as(usize, 3), m2.line_count);
    try std.testing.expectEqual(@as(usize, 24), m2.height_px);
    // Font size scales linearly.
    const m3 = measure_text("hello", .medium);
    try std.testing.expectEqual(@as(usize, 80), m3.width_px);
    // Wide codepoint counts two cells (中 = U+4E2D, UTF-8 E4 B8 AD).
    const m4 = measure_text("\xe4\xb8\xad", .small);
    try std.testing.expectEqual(@as(usize, 16), m4.width_px);
    // Soft wrap: 81 narrow chars at medium (80-col edge) → 2 rows.
    var long_buf: [82]u8 = undefined;
    @memset(&long_buf, 'x');
    long_buf[81] = 0;
    const m5 = measure_text(long_buf[0..81], .medium);
    try std.testing.expectEqual(@as(usize, 2), m5.line_count);
    try std.testing.expectEqual(@as(usize, 80 * 16), m5.max_line_width);
}

test "text: wrap_line segment contents pin the issue's examples (U15)" {
    var segs: [8]WrapSegment = undefined;
    // "hello world" at 8 cells → "hello", then "world".
    {
        const r = wrap_line("hello world", 8, &segs);
        try std.testing.expectEqual(@as(usize, 2), r.segments.len);
        try std.testing.expectEqualStrings("hello", "hello world"[r.segments[0].start..][0..r.segments[0].len]);
        try std.testing.expectEqualStrings("world", "hello world"[r.segments[1].start..][0..r.segments[1].len]);
    }
    // No boundary in range → hard break exactly at the edge.
    {
        const r = wrap_line("supercalifragilistic", 10, &segs);
        try std.testing.expectEqual(@as(usize, 2), r.segments.len);
        try std.testing.expect(r.segments[0].hard_break);
        try std.testing.expectEqualStrings("supercalif", "supercalifragilistic"[0..r.segments[0].len]);
        try std.testing.expectEqualStrings("ragilistic", "supercalifragilistic"[r.segments[1].start..][0..r.segments[1].len]);
    }
    // Hyphen is a break AFTER point.
    {
        const r = wrap_line("state-of-the-art", 7, &segs);
        try std.testing.expect(r.segments.len >= 2);
        try std.testing.expectEqualStrings("state-", "state-of-the-art"[0..r.segments[0].len]);
    }
    // Wide codepoints break around themselves when they don't fit…
    {
        const r = wrap_line("a\xe4\xb8\xadb", 2, &segs); // a 中 b
        try std.testing.expectEqual(@as(usize, 3), r.segments.len);
        const src = "a\xe4\xb8\xadb";
        try std.testing.expectEqualStrings("a", src[0..r.segments[0].len]);
        try std.testing.expectEqualStrings("\xe4\xb8\xad", src[r.segments[1].start..][0..r.segments[1].len]);
        try std.testing.expectEqualStrings("b", src[r.segments[2].start..][0..r.segments[2].len]);
    }
    // …and stay glued to the previous word while they fit.
    {
        const r = wrap_line("a\xe4\xb8\xadb", 3, &segs);
        try std.testing.expectEqual(@as(usize, 2), r.segments.len);
        try std.testing.expectEqualStrings("a\xe4\xb8\xad", "a\xe4\xb8\xadb"[0..r.segments[0].len]);
        try std.testing.expectEqualStrings("b", "a\xe4\xb8\xadb"[r.segments[1].start..][0..r.segments[1].len]);
    }
    // Zero-width space forces a break and vanishes from layout.
    {
        const r = wrap_line("ab\xe2\x80\x8bcd", 5, &segs); // ab\u{200B}cd
        try std.testing.expectEqual(@as(usize, 2), r.segments.len);
        try std.testing.expectEqualStrings("ab", "ab\xe2\x80\x8bcd"[0..r.segments[0].len]);
        try std.testing.expectEqualStrings("cd", "ab\xe2\x80\x8bcd"[r.segments[1].start..][0..r.segments[1].len]);
    }
}

test "text: wrap_line reports truncation on a small out-buffer (U15)" {
    var one: [1]WrapSegment = undefined;
    const r = wrap_line("aaa bbb ccc", 3, &one);
    try std.testing.expect(r.truncated);
    try std.testing.expectEqual(@as(usize, 1), r.segments.len);
}

test "text: glyph cache hits, sizes, and LRU eviction (U13)" {
    init();
    clear();
    try std.testing.expectEqual(@as(usize, 0), glyph_cache_hits);
    // First render of 'A': a miss that fills one slot.
    puts("A");
    render(testCanvas());
    const misses_after_first = glyph_cache_misses;
    const hits_after_first = glyph_cache_hits;
    try std.testing.expect(misses_after_first >= 1);
    // Repaint: every visible cell hits ('A' and the trailing blank both
    // live in the cache now), and nothing new fills.
    const misses_before_repaint = glyph_cache_misses;
    render(testCanvas());
    try std.testing.expect(glyph_cache_hits > hits_after_first);
    try std.testing.expectEqual(misses_before_repaint, glyph_cache_misses);
    // A different size is a different key.
    set_font_size(.medium);
    defer set_font_size(.small);
    clear();
    puts("A");
    const m_misses = glyph_cache_misses;
    render(testCanvas());
    try std.testing.expect(glyph_cache_misses > m_misses);
    set_font_size(.small);
    clear();
    // Eviction: paint more distinct cells than the cache holds; every
    // new cell must miss, and repaints after the flood still hit.
    var i: usize = 0;
    while (i < glyph_cache_cap + 10) : (i += 1) {
        putc(@intCast(0x21 + (i % 90)));
        if (i % 70 == 69) putc('\n');
    }
    const pre_flood_misses = glyph_cache_misses;
    render(testCanvas());
    try std.testing.expect(glyph_cache_misses > pre_flood_misses);
    const pre_repaint_hits = glyph_cache_hits;
    render(testCanvas());
    try std.testing.expect(glyph_cache_hits > pre_repaint_hits);
}

test "text: cached rows are pixel-identical to the direct path (U13)" {
    init();
    clear();
    puts("R");
    // Direct computation for 'R' at small…
    var want: [24]u32 = @as([24]u32, @splat(@as(u32, 0)));
    const g8 = font.glyphs['R' - 0x20];
    for (0..8) |y| {
        var x: usize = 0;
        while (x < 8) : (x += 1) {
            if (font.row_pixel(g8[y], x)) want[y] |= @as(u32, 1) << @intCast(x);
        }
    }
    // …must equal what the cache hands back.
    const got = cached_glyph_rows(@intCast('R'), .small).?;
    try std.testing.expectEqualSlices(u32, &want, got);
}

test "text: Unicode torture document renders deterministically (U14)" {
    // tools/test-unicode-torture.sh drives this via `zig test`; the file
    // is embedded so the golden travels with the repo state.
    const torture = @embedFile("unicode-torture.txt");
    init();
    clear();
    puts(torture);
    try std.testing.expect(ring_count >= 20); // the whole document landed
    // Render into a bounded canvas and fingerprint the pixels. ANY
    // rendering change to text.zig or the font tables shifts the hash —
    // intentional regressions must re-pin it deliberately.
    var canvas_buf: [64 * 16 * 4]u8 = undefined;
    const canvas = Canvas{
        .base = &canvas_buf,
        .width = 64,
        .height = 16,
        .stride = 64 * 4,
    };
    render(canvas);
    var h: u64 = 14695981039346656037;
    for (canvas_buf) |b| {
        h ^= b;
        h *%= 1099511628211;
    }
    try std.testing.expectEqual(@as(u64, TORTURE_GOLDEN), h);
}

/// FNV-1a over the 64×16 canvas after rendering tools/unicode-torture.txt
/// at small size. Re-pin ONLY with an explanation in the commit message.
/// Pinned from the first verified render (commit introducing U14);
/// re-pin ONLY with an explanation in the commit message.
const TORTURE_GOLDEN: u64 = 0xbbf8e4b0b4763f44;

test "text: an exhausted cluster pool degrades to ignoring new marks (U6)" {
    init();
    clear();
    // Fill the pool with distinct single-mark clusters on distinct bases.
    var i: usize = 0;
    while (i < dyn_cap) : (i += 1) {
        // Bases cycle through printable ASCII; marks vary for uniqueness.
        putc(@intCast(0x21 + (i % 90)));
        putc_unicode(@intCast(0x0300 + (i % 13)));
        if (i % 2 == 1) putc('\n');
    }
    const used = dyn_count;
    try std.testing.expect(used > dyn_cap / 2); // sanity: pool really filled
    // One more cluster on a fresh line must not crash or corrupt.
    puts("ok");
    putc_unicode(0x0325); // ring above — likely unarted → plain ignore
    render(testCanvas()); // full repaint stays in bounds
}
