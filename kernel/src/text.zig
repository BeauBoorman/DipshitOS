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
const virtio_gpu = @import("virtio_gpu.zig");

// ---------------------------------------------------------------------------
// Geometry + colors (fixed constants; the claim-time record lives in
// docs/m6-text-prompt.md and the hardware contract)
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

// ---------------------------------------------------------------------------
// Text state (fixed BSS — the one-and-only real instance)
// ---------------------------------------------------------------------------

/// The scrollback ring of text lines. A line is `cols` chars; a char is
/// the ASCII byte (0x20–0x7e printable, anything else renders as blank).
var ring: [ring_lines][cols]u8 = undefined;

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

/// Escape-sequence parser state for the editing bytes the console now
/// emits (milestone eight card U2): `\b` (cursor left), `\r` (column 0),
/// and `ESC [ 2 J` / `ESC [ H` (the `clear` command's and Ctrl-L's
/// erase-in-display — previously rendered as junk glyph cells).
const EscState = enum { none, esc, csi, csi_two };
var esc_state: EscState = .none;

/// A B8G8R8X8 canvas the renderer writes into (injectable for tests).
pub const Canvas = struct {
    base: [*]u8,
    width: usize,
    height: usize,
    stride: usize, // bytes per row (width × 4 for the framebuffer)
};

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

/// Emit one character. `\n` starts a new line; the editing bytes move the
/// cursor instead of drawing (card U2): `\r` returns to column 0, `\b`
/// steps one cell left, and `ESC [ 2 J` / `ESC [ H` clear the layer (the
/// clear command + the editor's Ctrl-L). Every other byte renders into
/// the current line (printable chars draw the glyph, control bytes draw
/// as blank), wrapping to a new line at the region's width. Unknown
/// escape sequences are swallowed.
pub fn putc(c: u8) void {
    if (!initialized) init();
    if (esc_state != .none) {
        putc_esc(c);
        return;
    }
    switch (c) {
        0x1b => esc_state = .esc,
        '\r' => cur_col = 0,
        0x08 => {
            if (cur_col > 0) cur_col -= 1;
        },
        '\n' => _ = new_line(),
        else => put_glyph(c),
    }
}

/// The escape-sequence half of `putc` (only `ESC [ 2 J` and `ESC [ H`
/// are produced by the console; anything else is swallowed, never drawn).
fn putc_esc(c: u8) void {
    switch (esc_state) {
        .none => unreachable,
        .esc => if (c == '[') {
            esc_state = .csi;
        } else if (c == 0x1b) {
            // stay at the start of a sequence
        } else {
            esc_state = .none;
            putc(c); // a lone ESC + a real byte: the byte renders normally
        },
        .csi => if (c == '2') {
            esc_state = .csi_two;
        } else if (c == 'H') {
            esc_state = .none;
            cur_col = 0; // cursor home (after a clear: column 0)
        } else {
            esc_state = .none; // unknown sequence: swallowed
        },
        .csi_two => {
            esc_state = .none;
            if (c == 'J') init(); // ESC [ 2 J: erase in display
        },
    }
}

/// The glyph path (the pre-U2 `putc` body): draw the cell, advance, wrap.
fn put_glyph(c: u8) void {
    var slot = cursor_slot();
    if (cur_col >= cols) {
        slot = new_line();
    }
    ring[slot][cur_col] = c;
    cur_col += 1;
    if (cur_col > line_fill[slot]) line_fill[slot] = @intCast(cur_col);
    if (cur_col >= cols) _ = new_line();
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
    const visible: usize = @min(@min(ring_count, rows), canvas.height / cell_h);
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
        const row_pix = r * cell_h;
        const cols_fit = @min(cols, canvas.width / cell_w);
        var col: usize = 0;
        while (col < cols_fit) : (col += 1) {
            const c = ring[slot][col];
            if (c < 0x20 or c > 0x7e) continue;
            const glyph = font.glyphs[c - 0x20];
            const col_pix = col * cell_w;
            var gy: usize = 0;
            while (gy < cell_h) : (gy += 1) {
                var row_bits = glyph[gy];
                var gx: usize = 0;
                while (gx < cell_w) : (gx += 1) {
                    if ((row_bits & 0x80) != 0) {
                        put_pixel(canvas, col_pix + gx, row_pix + gy, fg_rgb);
                    }
                    row_bits <<= 1;
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

test "text: glyph raster is the golden '!' bits in B8G8R8X8" {
    init();
    clear();
    puts("!");
    const canvas = testCanvas();
    render(canvas);
    // '!' = glyph index 1: row 0 = 0x18 (bits 00011000 → x = 3,4); the
    // rows are 0x18,0x3c,0x3c,0x18,0x18,0x00,0x18,0x00 (public-domain
    // font8x8). Assert the exact foreground cells of the golden rows.
    const fg = rgbBytes(fg_rgb);
    const bg = rgbBytes(bg_rgb);
    try std.testing.expectEqualSlices(u8, &fg, &pixel(canvas, 3, 0));
    try std.testing.expectEqualSlices(u8, &fg, &pixel(canvas, 4, 0));
    try std.testing.expectEqualSlices(u8, &fg, &pixel(canvas, 2, 1));
    try std.testing.expectEqualSlices(u8, &fg, &pixel(canvas, 5, 1));
    try std.testing.expectEqualSlices(u8, &bg, &pixel(canvas, 0, 0));
    try std.testing.expectEqualSlices(u8, &bg, &pixel(canvas, 7, 0));
    // The alpha byte is opaque (the claim-6053 lesson).
    try std.testing.expectEqual(@as(u8, 0xff), test_buf[3]);
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

test "text: card U2 — backspace moves the cursor left and overwrites" {
    init();
    clear();
    puts("ab\x08 \x08"); // the editor's erase pair: back up, blank, back up
    try std.testing.expectEqual(@as(usize, 1), cur_col);
    const slot = cur_line;
    try std.testing.expectEqual(@as(u8, 'a'), ring[slot][0]);
    // A mid-line edit stream renders the corrected line: "ab", left,
    // 'c' -> the cell shows "ac" with the cursor at 2.
    init();
    clear();
    puts("ab\x08c");
    try std.testing.expectEqual(@as(usize, 2), cur_col);
    try std.testing.expectEqual(@as(u8, 'a'), ring[cur_line][0]);
    try std.testing.expectEqual(@as(u8, 'c'), ring[cur_line][1]);
}

test "text: card U2 — carriage return returns to column 0" {
    init();
    clear();
    puts("ab\rc");
    try std.testing.expectEqual(@as(usize, 1), cur_col);
    try std.testing.expectEqual(@as(u8, 'c'), ring[cur_line][0]);
    try std.testing.expectEqual(@as(u8, 'b'), ring[cur_line][1]); // stale tail kept
}

test "text: card U2 — ESC [ 2 J ESC [ H clears; a lone ESC passes the byte through" {
    init();
    clear();
    puts("junk");
    try std.testing.expect(ring_count >= 1);
    puts("\x1b[2J\x1b[H");
    try std.testing.expectEqual(@as(usize, 0), ring_count);
    try std.testing.expectEqual(@as(usize, 0), cur_col);
    // A lone ESC followed by a printable: the printable renders normally.
    puts("\x1bx");
    try std.testing.expectEqual(@as(usize, 1), cur_col);
    try std.testing.expectEqual(@as(u8, 'x'), ring[cursor_slot()][0]);
    // Unknown sequences are swallowed, never drawn.
    init();
    clear();
    puts("\x1b[Zok");
    try std.testing.expectEqual(@as(usize, 2), cur_col);
    try std.testing.expectEqual(@as(u8, 'o'), ring[cur_line][0]);
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
