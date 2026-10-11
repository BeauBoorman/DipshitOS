//! VirelaiOS UI Drawing Primitives, Typography & Raster Surface Engine (M39 UI1).
const std = @import("std");
pub const abi = @import("abi.zig");
pub const theme = @import("theme.zig");

pub const font8x8 = @import("../font8x8.zig");
pub const font_ttf = @import("../font_ttf.zig");
pub const TrueTypeFace = font_ttf.TrueTypeFace;
pub const image = @import("../image.zig");
pub const Image = image.Image;

// Local aliases from abi:
const MAP_ANONYMOUS = abi.MAP_ANONYMOUS;
const MAP_POPULATE = abi.MAP_POPULATE;
const MAP_PRIVATE = abi.MAP_PRIVATE;
const MODE_READ = abi.MODE_READ;
const PROT_READ = abi.PROT_READ;
const PROT_WRITE = abi.PROT_WRITE;
const file_close = abi.file_close;
const file_open = abi.file_open;
const file_read = abi.file_read;
const mmap = abi.mmap;
const sys_win_fill_batch_num = abi.sys_win_fill_batch_num;
const syscall2 = abi.syscall2;
const win_present = abi.win_present;
const write_console = abi.write_console;

// Local aliases from theme:
const border_w = theme.border_w;
const focus_w = theme.focus_w;
const frame_border = theme.frame_border;
const theme_accent = theme.theme_accent;
const theme_border = theme.theme_border;

// ---------------------------------------------------------------------------
// M32 WMS9 (issue #629): batched fills on the surface seam.
//
// Instead of one syscall per glyph pixel, drawing primitives accumulate fill
// rects in a static `FillBatcher` and flush them through slot 46
// `sys_win_fill_batch` (one SVC per up-to-32 rects). Zero heap allocation:
// the batch lives in static BSS. Output is pixel-identical to per-pixel
// fills; only the syscall count collapses.
// ---------------------------------------------------------------------------

/// One packed rect in a slot-46 batch: 24 bytes, matching the kernel's
/// handle_win_fill_batch layout {id: u8, _pad: [3]u8, x, y, w, h: u32, rgb: u32}.
pub const FILL_RECT_SIZE: usize = 24;
pub const FILL_BATCH_MAX: usize = 32;

/// Accumulates fill rects and flushes them through slot 46 in chunks of 32.
/// Zero heap allocation: the buffer lives in static BSS. Batches are keyed
/// per window id — flushing automatically whenever the window id changes,
/// so callers never need to think about it.
pub const FillBatcher = struct {
    buf: [FILL_BATCH_MAX * FILL_RECT_SIZE]u8 align(8) = undefined,
    len: usize = 0,
    cur_id: u32 = 0,

    pub fn reset(self: *FillBatcher) void {
        self.len = 0;
    }

    fn push(self: *FillBatcher, id: u32, x: u32, y: u32, w: u32, h: u32, rgb: u32) void {
        if (self.len >= FILL_BATCH_MAX * FILL_RECT_SIZE) {
            self.flush();
        }
        const off = self.len;
        self.buf[off] = @intCast(id & 0xff);
        self.buf[off + 1] = 0;
        self.buf[off + 2] = 0;
        self.buf[off + 3] = 0;
        std.mem.writeInt(u32, self.buf[off + 4 ..][0..4], x, .little);
        std.mem.writeInt(u32, self.buf[off + 8 ..][0..4], y, .little);
        std.mem.writeInt(u32, self.buf[off + 12 ..][0..4], w, .little);
        std.mem.writeInt(u32, self.buf[off + 16 ..][0..4], h, .little);
        std.mem.writeInt(u32, self.buf[off + 20 ..][0..4], rgb, .little);
        self.len += FILL_RECT_SIZE;
    }

    /// Send all buffered rects through slot 46 in one SVC per 32 rects.
    pub fn flush(self: *FillBatcher) void {
        if (self.len == 0) return;
        _ = syscall2(sys_win_fill_batch_num, @intFromPtr(&self.buf), self.len);
        self.reset();
    }
};

/// The toolkit-wide fill batcher (static BSS, zero heap allocation).
pub var fill_batcher = FillBatcher{};

/// Queue a fill rect into the batcher. Flushes automatically on window-id
/// change or when the 32-rect batch is full, so ordering across windows is
/// preserved and callers never need to flush manually.
pub fn win_fill_batched(id: u32, x: u32, y: u32, w: u32, h: u32, rgb: u32) void {
    if (fill_batcher.len > 0 and fill_batcher.cur_id != id) {
        fill_batcher.flush();
    }
    fill_batcher.cur_id = id;
    fill_batcher.push(id, x, y, w, h, rgb);
}

/// Flush any pending batched fills (call before win_present / frame end).
pub fn flush_fills() void {
    fill_batcher.flush();
}

// ---------------------------------------------------------------------------
// Geometry Primitives
// ---------------------------------------------------------------------------

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    pub fn make(x: u32, y: u32, w: u32, h: u32) Rect {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    pub fn contains(self: Rect, px: u32, py: u32) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }

    pub fn inset(self: Rect, dx: u32, dy: u32) Rect {
        const double_dx = dx * 2;
        const double_dy = dy * 2;
        return .{
            .x = self.x + dx,
            .y = self.y + dy,
            .w = if (self.w > double_dx) self.w - double_dx else 0,
            .h = if (self.h > double_dy) self.h - double_dy else 0,
        };
    }
};

// ---------------------------------------------------------------------------
// Drawing Primitives
// ---------------------------------------------------------------------------

pub fn draw_rect(win_id: u32, rect: Rect, rgb: u32) void {
    if (rect.w == 0 or rect.h == 0) return;
    win_fill_batched(win_id, rect.x, rect.y, rect.w, rect.h, rgb);
}

pub fn draw_rect_outline(win_id: u32, rect: Rect, thickness: u32, rgb: u32) void {
    if (rect.w == 0 or rect.h == 0 or thickness == 0) return;
    // Top
    win_fill_batched(win_id, rect.x, rect.y, rect.w, thickness, rgb);
    // Bottom
    if (rect.h > thickness) {
        win_fill_batched(win_id, rect.x, rect.y + rect.h - thickness, rect.w, thickness, rgb);
    }
    // Left
    win_fill_batched(win_id, rect.x, rect.y, thickness, rect.h, rgb);
    // Right
    if (rect.w > thickness) {
        win_fill_batched(win_id, rect.x + rect.w - thickness, rect.y, thickness, rect.h, rgb);
    }
}

// ---------------------------------------------------------------------------
// Typography & Font Engine (Inter for UI, Fira Code for Monospace)
// ---------------------------------------------------------------------------

/// Which face slot a run paints with. Distinct from `FaceStyle` because a
/// style can be *wanted* while its face is absent: the slot is the storage and
/// the style is the request.
pub const FaceSlot = enum(u2) { regular, bold, italic, mono };

/// M69d2 (#1536): the weight a run asks for. `bold`/`italic` mean the face the
/// share staged for that weight; when it is absent the painter falls back to
/// Regular (and, for bold, keeps the 1-px second strike). The fallback is what
/// the app's typography probe reports, so it is visible, never silent.
pub const FaceStyle = enum { regular, bold, italic };

pub const FaceSelection = struct {
    face: ?*const TrueTypeFace,
    cache: *TrueTypeFace.GlyphCache,
};

pub var active_ui_font: ?*const TrueTypeFace = null;
pub var active_ui_bold_font: ?*const TrueTypeFace = null;
pub var active_ui_italic_font: ?*const TrueTypeFace = null;
pub var active_mono_font: ?*const TrueTypeFace = null;
pub var active_ui_cache: TrueTypeFace.GlyphCache = .{};
pub var active_ui_bold_cache: TrueTypeFace.GlyphCache = .{};
pub var active_ui_italic_cache: TrueTypeFace.GlyphCache = .{};
pub var active_mono_cache: TrueTypeFace.GlyphCache = .{};
var static_inter_face: TrueTypeFace = undefined;
var static_inter_bold_face: TrueTypeFace = undefined;
var static_inter_italic_face: TrueTypeFace = undefined;
var static_fira_face: TrueTypeFace = undefined;

pub var fonts_initialized: bool = false;

/// One face read. Staged bytes: Inter Regular 411,640, Bold 420,428, Italic
/// 417,388, Fira Code 289,624 — 1 MiB holds each with room for a rebuild.
const face_max_bytes: u64 = 1024 * 1024;

/// A face parses in place over the mmap'd bytes it borrows, so each slot needs
/// its own storage that outlives the load.
fn slotStorage(slot: FaceSlot) *TrueTypeFace {
    return switch (slot) {
        .regular => &static_inter_face,
        .bold => &static_inter_bold_face,
        .italic => &static_inter_italic_face,
        .mono => &static_fira_face,
    };
}

fn setSlot(slot: FaceSlot, face: *const TrueTypeFace) void {
    switch (slot) {
        .regular => active_ui_font = face,
        .bold => active_ui_bold_font = face,
        .italic => active_ui_italic_font = face,
        .mono => active_mono_font = face,
    }
}

/// The loaded face for a slot, or null when the share did not stage one.
pub fn slotFace(slot: FaceSlot) ?*const TrueTypeFace {
    return switch (slot) {
        .regular => active_ui_font,
        .bold => active_ui_bold_font,
        .italic => active_ui_italic_font,
        .mono => active_mono_font,
    };
}

pub fn slotCache(slot: FaceSlot) *TrueTypeFace.GlyphCache {
    return switch (slot) {
        .regular => &active_ui_cache,
        .bold => &active_ui_bold_cache,
        .italic => &active_ui_italic_cache,
        .mono => &active_mono_cache,
    };
}

/// The face and cache a style paints with: the requested weight when the share
/// staged it, otherwise Regular. (The glyph cache is keyed by codepoint alone,
/// which is why every face needs its own.)
pub fn selectFace(style: FaceStyle) FaceSelection {
    const want: FaceSlot = switch (style) {
        .regular => .regular,
        .bold => .bold,
        .italic => .italic,
    };
    if (slotFace(want)) |face| return .{ .face = face, .cache = slotCache(want) };
    return .{ .face = active_ui_font, .cache = &active_ui_cache };
}

/// Read one staged face and parse it into its slot. A failure leaves the slot
/// empty — the app keeps rendering on whatever else loaded (ADR 0028 D4), and
/// its typography probe is what tells a gate which faces are real.
fn loadFace(path: []const u8, slot: FaceSlot) void {
    const fd = file_open(path, MODE_READ);
    if (fd < 0) return;
    const handle: u32 = @intCast(fd);
    defer file_close(handle);

    const va = mmap(0, face_max_bytes, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE | MAP_POPULATE);
    if (va == 0) return;
    const ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(va)));
    var total_read: usize = 0;
    while (total_read < face_max_bytes) {
        const chunk = file_read(handle, ptr[total_read..face_max_bytes]);
        if (chunk <= 0) break;
        total_read += @intCast(chunk);
    }
    if (total_read <= 1024) return;
    const face = TrueTypeFace.init(ptr[0..total_read]) catch return;
    slotStorage(slot).* = face;
    setSlot(slot, slotStorage(slot));
}

pub fn init_fonts() bool {
    if (fonts_initialized) return active_ui_font != null;
    fonts_initialized = true;

    loadFace("/host/INTER.TTF", .regular);
    loadFace("/host/FIRACODE.TTF", .mono);
    // M69d2 (#1536) D1: the share names M69d (#1531) froze. Bold is what
    // retires the synthetic 1-px second strike; Italic is optional, and its
    // absence is reported so the two stories stay distinguishable.
    loadFace("/host/INTERB.TTF", .bold);
    loadFace("/host/INTERI.TTF", .italic);

    if (active_ui_font != null) {
        write_console("typography: Inter TrueType font loaded\n");
    }
    if (active_mono_font != null) {
        write_console("typography: Fira Code TrueType font loaded\n");
    }
    if (active_ui_bold_font != null) {
        write_console("typography: Inter Bold TrueType font loaded\n");
    }
    if (active_ui_italic_font != null) {
        write_console("typography: Inter Italic TrueType font loaded\n");
    } else {
        write_console("typography: Inter Italic absent, em keeps accent\n");
    }

    return active_ui_font != null;
}

// ---------------------------------------------------------------------------
// Ink probes (M69d2, #1536)
//
// The point of a real Bold face is that it is NOT the 1-px second strike the
// fallback draws, and the masks are where that is measurable: Inter matches
// ADVANCES across weights (a width probe cannot see Bold), and both a strike
// and a Bold face add ink (so ink alone cannot either). What separates them is
// the SHAPE — the strike is Regular unioned with itself shifted one pixel, and
// a real face is not that. These probes are the Zig mirror of the Go side's
// glyphCover/BoldHeavier and its render-and-diff test (#1531); the metric here
// is painted PIXELS at the painter's own coverage cut.
// ---------------------------------------------------------------------------

/// The cut `draw_alpha_mask` uses to turn a mask into spans: a pixel at or
/// above it is painted. Every probe below counts at this cut, so the numbers
/// describe pixels the guest actually lights.
pub const ink_cut: u8 = 96;

/// One glyph's mask as the probes read it.
pub const MaskView = struct { w: usize, h: usize, alpha: []const u8 };

/// Painted pixels in one glyph mask.
pub fn litPixels(alpha: []const u8) u32 {
    var n: u32 = 0;
    for (alpha) |a| {
        if (a >= ink_cut) n += 1;
    }
    return n;
}

/// Painted pixels of the synthetic strike: the union of the mask and the same
/// mask translated one pixel right — exactly what a consumer draws twice when
/// no Bold face is staged (Zig DOC.BIN did, and its probe read the union; M71i
/// #1568 retired that app, so this is the helper's remaining meaning). The
/// union is over the box WIDENED by one column, since
/// the shifted copy can light a pixel past the mask's own width.
pub fn strikeUnion(w: usize, h: usize, alpha: []const u8) u32 {
    if (w == 0 or h == 0) return 0;
    var n: u32 = 0;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x <= w) : (x += 1) {
            const here = if (x < w and y * w + x < alpha.len) alpha[y * w + x] >= ink_cut else false;
            const left = if (x > 0 and y * w + x - 1 < alpha.len) alpha[y * w + x - 1] >= ink_cut else false;
            if (here or left) n += 1;
        }
    }
    return n;
}

/// Materialize the strike's mask (Regular ∪ Regular-shifted-right) into `dst`.
/// Null when `dst` cannot hold the box — the strike is one column wider than
/// the mask it doubles, and the returned view carries that width so a caller
/// comparing it with another mask strides each one by its OWN width.
pub fn strikeMaskInto(dst: []u8, src: MaskView) ?MaskView {
    if (src.w == 0 or src.h == 0) return null;
    const ow = src.w + 1;
    const box = ow * src.h;
    if (dst.len < box) return null;
    @memset(dst[0..box], 0);
    var y: usize = 0;
    while (y < src.h) : (y += 1) {
        var x: usize = 0;
        while (x <= src.w) : (x += 1) {
            const here = if (x < src.w and y * src.w + x < src.alpha.len) src.alpha[y * src.w + x] >= ink_cut else false;
            const left = if (x > 0 and y * src.w + x - 1 < src.alpha.len) src.alpha[y * src.w + x - 1] >= ink_cut else false;
            if (here or left) dst[y * ow + x] = 255;
        }
    }
    return .{ .w = ow, .h = src.h, .alpha = dst[0..box] };
}

/// Pixels on which two masks disagree, treated as ink/not-ink at `ink_cut` over
/// the union of their boxes. Each mask is read with its OWN width (the strike is
/// a column wider than the glyph it doubles), so the comparison is pixel-for-
/// pixel rather than byte-for-byte. A run drawn with the fallback strike scores
/// 0 against the strike — which is what makes "this <strong> is not the double
/// strike" a number in the app's own serial line rather than a claim in a
/// comment.
pub fn maskDiff(a: MaskView, b: MaskView) u32 {
    const w = @max(a.w, b.w);
    const h = @max(a.h, b.h);
    var n: u32 = 0;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const la = if (x < a.w and y < a.h) a.alpha[y * a.w + x] >= ink_cut else false;
            const lb = if (x < b.w and y < b.h) b.alpha[y * b.w + x] >= ink_cut else false;
            if (la != lb) n += 1;
        }
    }
    return n;
}

/// Ink of a slot's glyph at a pixel size, in painted pixels. 0 when the slot is
/// empty or the glyph does not rasterize: the caller reports that rather than
/// inventing a number.
pub fn glyphInk(slot: FaceSlot, ch: u8, size: u32) u32 {
    const view = glyphMask(slot, ch, size) orelse return 0;
    return litPixels(view.alpha);
}

/// A slot's glyph mask, or null when the slot is empty / the glyph does not
/// rasterize.
pub fn glyphMask(slot: FaceSlot, ch: u8, size: u32) ?MaskView {
    const face = slotFace(slot) orelse return null;
    const cache = slotCache(slot);
    const entry = cache.get_or_render(face, ch, size) orelse return null;
    if (entry.width == 0 or entry.height == 0) return null;
    return .{ .w = entry.width, .h = entry.height, .alpha = cache.glyph_alpha(entry) };
}

/// Ink the synthetic strike would produce for a slot's glyph — the number a
/// regular-only build would publish as its "bold".
pub fn strikeInk(slot: FaceSlot, ch: u8, size: u32) u32 {
    const view = glyphMask(slot, ch, size) orelse return 0;
    return strikeUnion(view.w, view.h, view.alpha);
}

/// Lean in sixteenths of a pixel: 16 x (bottom band's ink centre x - top band's
/// ink centre x). A stem that leans RIGHT has its top to the right of its
/// bottom, so the score is NEGATIVE; an upright stem scores ~0. Fixed point
/// because a lean at body size is a fraction of a pixel, and the comparison is
/// always the SAME glyph across faces, so the number is about the lean and not
/// about the glyph's shape (Inter Italic 'l'@14 measures -21 against Roman 0).
pub fn maskSkew16(w: usize, h: usize, alpha: []const u8) i32 {
    if (w == 0 or h == 0) return 0;
    const band: usize = if (h >= 3) h / 3 else 1;
    var top_n: i64 = 0;
    var top_sum: i64 = 0;
    var bot_n: i64 = 0;
    var bot_sum: i64 = 0;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const is_top = y < band;
        const is_bot = y >= h - band;
        if (!is_top and !is_bot) continue;
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const i = y * w + x;
            if (i >= alpha.len) break;
            if (alpha[i] < ink_cut) continue;
            if (is_top) {
                top_n += 1;
                top_sum += @intCast(x);
            } else {
                bot_n += 1;
                bot_sum += @intCast(x);
            }
        }
    }
    if (top_n == 0 or bot_n == 0) return 0;
    return @intCast(@divTrunc(16 * (bot_sum * top_n - top_sum * bot_n), top_n * bot_n));
}

/// Lean of a slot's glyph, from its cached mask.
pub fn glyphSkew16(slot: FaceSlot, ch: u8, size: u32) i32 {
    const view = glyphMask(slot, ch, size) orelse return 0;
    return maskSkew16(view.w, view.h, view.alpha);
}

pub fn draw_alpha_mask(win_id: u32, x: i32, y: i32, w: usize, h: usize, alpha: []const u8, fg_rgb: u32) void {
    if (win_get_backing(win_id)) |backing| {
        TrueTypeFace.blend_glyph_bgra(
            backing.pixels[0 .. @as(usize, @intCast(backing.width)) * @as(usize, @intCast(backing.height))],
            backing.width,
            backing.width,
            backing.height,
            x,
            y,
            w,
            h,
            alpha,
            fg_rgb,
        );
        return;
    }

    for (0..h) |row| {
        const dy = y + @as(i32, @intCast(row));
        if (dy < 0) continue;
        const udy: u32 = @intCast(dy);

        var col: usize = 0;
        while (col < w) {
            const a = alpha[row * w + col];
            if (a < 96) {
                col += 1;
                continue;
            }
            const start_col = col;
            while (col < w and alpha[row * w + col] >= 96) : (col += 1) {}
            const dx = x + @as(i32, @intCast(start_col));
            if (dx >= 0) {
                const udx: u32 = @intCast(dx);
                const span_len: u32 = @intCast(col - start_col);
                win_fill_batched(win_id, udx, udy, span_len, 1, fg_rgb);
            }
        }
    }
}

pub fn measure_text(text: []const u8) u32 {
    if (active_ui_font) |face| {
        var w: u32 = 0;
        for (text) |ch| {
            if (active_ui_cache.get_or_render(face, ch, 14)) |entry| {
                w += entry.advance_width;
            } else {
                w += 8;
            }
        }
        return w;
    }
    return @as(u32, @intCast(text.len)) * 8;
}

pub fn measure_text_mono(text: []const u8) u32 {
    if (active_mono_font) |face| {
        var w: u32 = 0;
        for (text) |ch| {
            if (active_mono_cache.get_or_render(face, ch, 13)) |entry| {
                w += entry.advance_width;
            } else {
                w += 8;
            }
        }
        return w;
    }
    return @as(u32, @intCast(text.len)) * 8;
}

pub fn draw_char(win_id: u32, ch: u8, x: u32, y: u32, fg_rgb: u32) void {
    if (active_ui_font) |face| {
        if (active_ui_cache.get_or_render(face, ch, 14)) |entry| {
            const alpha = active_ui_cache.glyph_alpha(entry);
            const gx = @as(i32, @intCast(x)) + entry.bearing_x;
            const gy = @as(i32, @intCast(y)) + (10 - entry.bearing_y);
            draw_alpha_mask(win_id, gx, gy, entry.width, entry.height, alpha, fg_rgb);
            return;
        }
    }

    if (ch < 0x20 or ch > 0x7e) return;
    const glyph = font8x8.glyphs[ch - 0x20];
    var row_idx: usize = 0;
    while (row_idx < 8) : (row_idx += 1) {
        const row_byte = glyph[row_idx];
        var col_idx: usize = 0;
        while (col_idx < 8) {
            if (!font8x8.row_pixel(row_byte, col_idx)) {
                col_idx += 1;
                continue;
            }
            const start_col = col_idx;
            while (col_idx < 8 and font8x8.row_pixel(row_byte, col_idx)) : (col_idx += 1) {}
            win_fill_batched(win_id, x + @as(u32, @intCast(start_col)), y + @as(u32, @intCast(row_idx)), @as(u32, @intCast(col_idx - start_col)), 1, fg_rgb);
        }
    }
}

pub fn draw_char_mono(win_id: u32, ch: u8, x: u32, y: u32, fg_rgb: u32) void {
    if (active_mono_font) |face| {
        if (active_mono_cache.get_or_render(face, ch, 13)) |entry| {
            const alpha = active_mono_cache.glyph_alpha(entry);
            const gx = @as(i32, @intCast(x)) + entry.bearing_x;
            const gy = @as(i32, @intCast(y)) + (10 - entry.bearing_y);
            draw_alpha_mask(win_id, gx, gy, entry.width, entry.height, alpha, fg_rgb);
            return;
        }
    }
    draw_char(win_id, ch, x, y, fg_rgb);
}

pub fn draw_text(win_id: u32, text: []const u8, x: u32, y: u32, fg_rgb: u32) void {
    var cur_x = x;
    if (active_ui_font) |face| {
        for (text) |ch| {
            if (active_ui_cache.get_or_render(face, ch, 14)) |entry| {
                const alpha = active_ui_cache.glyph_alpha(entry);
                const gx = @as(i32, @intCast(cur_x)) + entry.bearing_x;
                const gy = @as(i32, @intCast(y)) + (10 - entry.bearing_y);
                draw_alpha_mask(win_id, gx, gy, entry.width, entry.height, alpha, fg_rgb);
                cur_x += entry.advance_width;
            } else {
                draw_char(win_id, ch, cur_x, y, fg_rgb);
                cur_x += 8;
            }
        }
        return;
    }

    for (text) |ch| {
        draw_char(win_id, ch, cur_x, y, fg_rgb);
        cur_x += 8;
    }
}

pub fn draw_text_mono(win_id: u32, text: []const u8, x: u32, y: u32, fg_rgb: u32) void {
    var cur_x = x;
    if (active_mono_font) |face| {
        for (text) |ch| {
            if (active_mono_cache.get_or_render(face, ch, 13)) |entry| {
                const alpha = active_mono_cache.glyph_alpha(entry);
                const gx = @as(i32, @intCast(cur_x)) + entry.bearing_x;
                const gy = @as(i32, @intCast(y)) + (10 - entry.bearing_y);
                draw_alpha_mask(win_id, gx, gy, entry.width, entry.height, alpha, fg_rgb);
                cur_x += entry.advance_width;
            } else {
                draw_char(win_id, ch, cur_x, y, fg_rgb);
                cur_x += 8;
            }
        }
        return;
    }

    for (text) |ch| {
        draw_char(win_id, ch, cur_x, y, fg_rgb);
        cur_x += 8;
    }
}

pub fn draw_text_centered(win_id: u32, text: []const u8, rect: Rect, fg_rgb: u32) void {
    const text_w = measure_text(text);
    const text_h: u32 = if (active_ui_font != null) 12 else 8;
    const x = if (rect.w > text_w) rect.x + (rect.w - text_w) / 2 else rect.x;
    const y = if (rect.h > text_h) rect.y + (rect.h - text_h) / 2 else rect.y;
    draw_text(win_id, text, x, y, fg_rgb);
}

pub fn measure_text_sized(text: []const u8, size: u32) u32 {
    if (active_ui_font) |face| {
        var w: u32 = 0;
        for (text) |ch| {
            if (active_ui_cache.get_or_render(face, ch, size)) |entry| {
                w += entry.advance_width;
            } else {
                w += 8;
            }
        }
        return w;
    }
    return @as(u32, @intCast(text.len)) * 8;
}

pub fn draw_text_sized(win_id: u32, text: []const u8, x: u32, y: u32, size: u32, fg_rgb: u32) void {
    draw_text_sized_styled(win_id, text, x, y, size, .regular, fg_rgb);
}

/// Draw a run with the face its style asks for (M69d2, #1536). When that face
/// is absent the run is drawn with Regular — the caller decides whether to add
/// the synthetic strike, because that decision is the app's documented fallback
/// and its typography probe reports which path it took.
pub fn draw_text_sized_styled(win_id: u32, text: []const u8, x: u32, y: u32, size: u32, style: FaceStyle, fg_rgb: u32) void {
    const sel = selectFace(style);
    var cur_x = x;
    if (sel.face) |face| {
        const base_y: i32 = @intCast((size * 10) / 14);
        for (text) |ch| {
            if (sel.cache.get_or_render(face, ch, size)) |entry| {
                const alpha = sel.cache.glyph_alpha(entry);
                const gx = @as(i32, @intCast(cur_x)) + entry.bearing_x;
                const gy = @as(i32, @intCast(y)) + (base_y - entry.bearing_y);
                draw_alpha_mask(win_id, gx, gy, entry.width, entry.height, alpha, fg_rgb);
                cur_x += entry.advance_width;
            } else {
                draw_char(win_id, ch, cur_x, y, fg_rgb);
                cur_x += 8;
            }
        }
        return;
    }

    for (text) |ch| {
        draw_char(win_id, ch, cur_x, y, fg_rgb);
        cur_x += 8;
    }
}

// ---------------------------------------------------------------------------
// Step 6 (Issue #206): 8×16 font helpers for titles and headings.
// Uses the kernel's 2×-stretched glyph table via a runtime pixel walk.
// ---------------------------------------------------------------------------

pub fn draw_char_16(win_id: u32, ch: u8, x: u32, y: u32, fg_rgb: u32) void {
    if (ch < 0x20 or ch > 0x7e) return;
    // The 8×16 glyph is the 8×8 glyph with each row doubled.
    // We re-derive the stretch at render time to stay in sync with
    // font8x8.zig's glyphs_16 table (same data, user-side copy).
    const glyph = font8x8.glyphs[ch - 0x20];
    var row_idx: usize = 0;
    while (row_idx < 8) : (row_idx += 1) {
        const row_byte = glyph[row_idx];
        var col_idx: usize = 0;
        while (col_idx < 8) {
            if (!font8x8.row_pixel(row_byte, col_idx)) {
                col_idx += 1;
                continue;
            }
            const start_col = col_idx;
            while (col_idx < 8 and font8x8.row_pixel(row_byte, col_idx)) : (col_idx += 1) {}
            // One 2px-tall span per contiguous run (2× vertical stretch) —
            // replaces two 1×1 fills per pixel (WMS9, issue #629).
            win_fill_batched(win_id, x + @as(u32, @intCast(start_col)), y + @as(u32, @intCast(row_idx * 2)), @as(u32, @intCast(col_idx - start_col)), 2, fg_rgb);
        }
    }
}

pub fn draw_text_large(win_id: u32, text: []const u8, x: u32, y: u32, fg_rgb: u32) void {
    var cur_x = x;
    for (text) |ch| {
        draw_char_16(win_id, ch, cur_x, y, fg_rgb);
        cur_x += 8;
    }
}

pub fn draw_text_centered_large(win_id: u32, text: []const u8, rect: Rect, fg_rgb: u32) void {
    const text_w = @as(u32, @intCast(text.len)) * 8;
    const text_h: u32 = 16;
    const x = if (rect.w > text_w) rect.x + (rect.w - text_w) / 2 else rect.x;
    const y = if (rect.h > text_h) rect.y + (rect.h - text_h) / 2 else rect.y;
    draw_text_large(win_id, text, x, y, fg_rgb);
}

// ---------------------------------------------------------------------------
// Window Backing Buffer Support & Raster Blitting
// ---------------------------------------------------------------------------

pub const WindowBacking = struct {
    pixels: [*]u32,
    width: u32,
    height: u32,
};

const max_backing_windows: usize = 16;
var window_backings: [max_backing_windows]?WindowBacking = @as([max_backing_windows]?WindowBacking, @splat(@as(?WindowBacking, null)));

/// Associate a direct 32-bpp RGBA/RGBX backing buffer with a window ID.
pub fn win_set_backing(win_id: u32, pixels: [*]u32, width: u32, height: u32) void {
    if (win_id >= max_backing_windows) return;
    window_backings[win_id] = .{
        .pixels = pixels,
        .width = width,
        .height = height,
    };
}

/// Disassociate any registered backing buffer for a window ID.
pub fn win_clear_backing(win_id: u32) void {
    if (win_id >= max_backing_windows) return;
    window_backings[win_id] = null;
}

/// Retrieve the registered backing buffer for a window ID, if any.
pub fn win_get_backing(win_id: u32) ?WindowBacking {
    if (win_id >= max_backing_windows) return null;
    return window_backings[win_id];
}

/// Standard Porter-Duff source-over alpha blending for 32-bpp 0xAARRGGBB pixels.
pub fn blend_source_over(dst: u32, src: u32) u32 {
    const src_a: u32 = (src >> 24) & 0xFF;
    if (src_a == 0) return dst;
    if (src_a == 255) return src;

    const inv_a: u32 = 255 - src_a;
    const src_r: u32 = (src >> 16) & 0xFF;
    const src_g: u32 = (src >> 8) & 0xFF;
    const src_b: u32 = src & 0xFF;

    const dst_a: u32 = (dst >> 24) & 0xFF;
    const dst_r: u32 = (dst >> 16) & 0xFF;
    const dst_g: u32 = (dst >> 8) & 0xFF;
    const dst_b: u32 = dst & 0xFF;

    const out_r = (src_r * src_a + dst_r * inv_a) / 255;
    const out_g = (src_g * src_a + dst_g * inv_a) / 255;
    const out_b = (src_b * src_a + dst_b * inv_a) / 255;
    const out_a = src_a + (dst_a * inv_a) / 255;

    return (out_a << 24) | (out_r << 16) | (out_g << 8) | out_b;
}

/// Blit raster image pixels to a window backing surface.
/// If a backing buffer is registered via win_set_backing, blends pixels directly
/// with source-over alpha blending and boundary clipping.
/// Otherwise, falls back to win_fill_batched span emission.
pub fn draw_image(win_id: u32, x: u32, y: u32, img: image.Image) void {
    if (img.width == 0 or img.height == 0) return;
    if (win_get_backing(win_id)) |backing| {
        if (x >= backing.width or y >= backing.height) return;
        const max_w = @min(img.width, backing.width - x);
        const max_h = @min(img.height, backing.height - y);
        var sy: u32 = 0;
        while (sy < max_h) : (sy += 1) {
            const dst_row = (y + sy) * backing.width + x;
            var sx: u32 = 0;
            while (sx < max_w) : (sx += 1) {
                const px_ptr = img.pixel_at(sx, sy) orelse continue;
                const src_px = px_ptr.*;
                if (((src_px >> 24) & 0xFF) == 0) continue;
                const dst_idx = dst_row + sx;
                backing.pixels[dst_idx] = blend_source_over(backing.pixels[dst_idx], src_px);
            }
        }
        return;
    }

    var sy: u32 = 0;
    while (sy < img.height) : (sy += 1) {
        var sx: u32 = 0;
        while (sx < img.width) {
            const px_ptr = img.pixel_at(sx, sy) orelse break;
            const px = px_ptr.*;
            const a = (px >> 24) & 0xFF;
            if (a == 0) {
                sx += 1;
                continue;
            }
            const rgb = px & 0x00FFFFFF;
            const start_x = sx;
            sx += 1;
            while (sx < img.width) {
                const next_ptr = img.pixel_at(sx, sy) orelse break;
                const next_px = next_ptr.*;
                if (((next_px >> 24) & 0xFF) == 0 or (next_px & 0x00FFFFFF) != rgb) break;
                sx += 1;
            }
            win_fill_batched(win_id, x + start_x, y + sy, sx - start_x, 1, rgb);
        }
    }
}

/// Draw a clipped raster image to a window, rendering only pixels that fall within clip.
/// Uses direct backing buffer alpha blending when registered, otherwise batched fills.
pub fn draw_image_clipped(win_id: u32, x: u32, y: u32, img: image.Image, clip: Rect) void {
    if (img.width == 0 or img.height == 0 or clip.w == 0 or clip.h == 0) return;
    if (win_get_backing(win_id)) |backing| {
        const clip_x0 = clip.x;
        const clip_y0 = clip.y;
        const clip_x1 = @min(clip.x + clip.w, backing.width);
        const clip_y1 = @min(clip.y + clip.h, backing.height);
        if (clip_x0 >= clip_x1 or clip_y0 >= clip_y1) return;

        var sy: u32 = 0;
        while (sy < img.height) : (sy += 1) {
            const py = y + sy;
            if (py < clip_y0 or py >= clip_y1) continue;
            var sx: u32 = 0;
            while (sx < img.width) : (sx += 1) {
                const px_pos = x + sx;
                if (px_pos < clip_x0 or px_pos >= clip_x1) continue;
                const px_ptr = img.pixel_at(sx, sy) orelse continue;
                const src_px = px_ptr.*;
                if (((src_px >> 24) & 0xFF) == 0) continue;
                const dst_idx = py * backing.width + px_pos;
                backing.pixels[dst_idx] = blend_source_over(backing.pixels[dst_idx], src_px);
            }
        }
        return;
    }

    var sy: u32 = 0;
    while (sy < img.height) : (sy += 1) {
        const py = y + sy;
        if (py < clip.y or py >= clip.y + clip.h) continue;

        var sx: u32 = 0;
        while (sx < img.width) {
            const px_ptr = img.pixel_at(sx, sy) orelse break;
            const px = px_ptr.*;
            const a = (px >> 24) & 0xFF;
            const cur_x = x + sx;
            if (a == 0 or cur_x < clip.x or cur_x >= clip.x + clip.w) {
                sx += 1;
                continue;
            }
            const rgb = px & 0x00FFFFFF;
            const start_x = sx;
            sx += 1;
            while (sx < img.width) {
                const next_x = x + sx;
                if (next_x >= clip.x + clip.w) break;
                const next_ptr = img.pixel_at(sx, sy) orelse break;
                const next_px = next_ptr.*;
                if (((next_px >> 24) & 0xFF) == 0 or (next_px & 0x00FFFFFF) != rgb) break;
                sx += 1;
            }
            win_fill_batched(win_id, x + start_x, py, sx - start_x, 1, rgb);
        }
    }
}

/// Nearest-neighbor scaled image blitting into target destination rectangle.
/// Uses direct backing buffer alpha blending when registered, otherwise batched fills.
pub fn draw_image_scaled(win_id: u32, dest: Rect, img: image.Image) void {
    if (dest.w == 0 or dest.h == 0 or img.width == 0 or img.height == 0) return;
    if (win_get_backing(win_id)) |backing| {
        if (dest.x >= backing.width or dest.y >= backing.height) return;
        const max_w = @min(dest.w, backing.width - dest.x);
        const max_h = @min(dest.h, backing.height - dest.y);
        var dy: u32 = 0;
        while (dy < max_h) : (dy += 1) {
            const sy = (dy * img.height) / dest.h;
            const dst_row = (dest.y + dy) * backing.width + dest.x;
            var dx: u32 = 0;
            while (dx < max_w) : (dx += 1) {
                const sx = (dx * img.width) / dest.w;
                const px_ptr = img.pixel_at(sx, sy) orelse continue;
                const src_px = px_ptr.*;
                if (((src_px >> 24) & 0xFF) == 0) continue;
                const dst_idx = dst_row + dx;
                backing.pixels[dst_idx] = blend_source_over(backing.pixels[dst_idx], src_px);
            }
        }
        return;
    }

    var dy: u32 = 0;
    while (dy < dest.h) : (dy += 1) {
        const sy = (dy * img.height) / dest.h;
        var dx: u32 = 0;
        while (dx < dest.w) {
            const sx = (dx * img.width) / dest.w;
            const px_ptr = img.pixel_at(sx, sy) orelse break;
            const px = px_ptr.*;
            const a = (px >> 24) & 0xFF;
            if (a == 0) {
                dx += 1;
                continue;
            }
            const rgb = px & 0x00FFFFFF;
            const start_dx = dx;
            dx += 1;
            while (dx < dest.w) {
                const next_sx = (dx * img.width) / dest.w;
                const next_ptr = img.pixel_at(next_sx, sy) orelse break;
                const next_px = next_ptr.*;
                if (((next_px >> 24) & 0xFF) == 0 or (next_px & 0x00FFFFFF) != rgb) break;
                dx += 1;
            }
            win_fill_batched(win_id, dest.x + start_dx, dest.y + dy, dx - start_dx, 1, rgb);
        }
    }
}

/// Blit a raster image directly into a raw pixel buffer (M42 SX1, issue #982)
/// — the WM-server seam: TABWM composes straight into the M33 scanout, which
/// has no window backing, so `draw_image`'s backing path does not apply.
/// `stride` is in PIXELS; the buffer is `pixels.len` pixels tall-strided
/// (row `y` starts at `y * stride`). Source-over alpha blending with
/// boundary clipping on both the buffer and the image. Pure buffer math —
/// host-testable, zero syscalls, zero allocation.
pub fn draw_image_buf(pixels: []u32, stride: u32, x: u32, y: u32, img: image.Image) void {
    if (img.width == 0 or img.height == 0 or stride == 0 or pixels.len == 0) return;
    const buf_h: u32 = @intCast(pixels.len / stride);
    if (x >= stride or y >= buf_h) return;

    const max_w = @min(img.width, stride - x);
    const max_h = @min(img.height, buf_h - y);
    var sy: u32 = 0;
    while (sy < max_h) : (sy += 1) {
        const dst_row = (y + sy) * stride + x;
        var sx: u32 = 0;
        while (sx < max_w) : (sx += 1) {
            const px_ptr = img.pixel_at(sx, sy) orelse continue;
            const src_px = px_ptr.*;
            if (((src_px >> 24) & 0xFF) == 0) continue;
            const dst_idx = dst_row + sx;
            pixels[dst_idx] = blend_source_over(pixels[dst_idx], src_px);
        }
    }
}

/// Draw a 1px panel frame inside `rect` (in-app panels, dialogs, editors
/// — the compositor owns the OUTER window border). Uses token metrics.
pub fn draw_panel_frame(win_id: u32, rect: Rect, focused: bool) void {
    draw_rect_outline(win_id, rect, border_w, frame_border(focused));
}

/// Draw the focus outline OUTSIDE `rect` (focus_w band in accent).
/// Callers must leave focus_w px of clear space around the control.
pub fn draw_focus_outline(win_id: u32, rect: Rect) void {
    const outer = Rect.make(
        if (rect.x >= focus_w) rect.x - focus_w else 0,
        if (rect.y >= focus_w) rect.y - focus_w else 0,
        rect.w + focus_w * 2,
        rect.h + focus_w * 2,
    );
    draw_rect_outline(win_id, outer, focus_w, theme_accent());
    draw_rect_outline(win_id, rect, border_w, theme_border());
}

// ---------------------------------------------------------------------------
// M39 UI2 Anti-Aliased Rounded Rectangles & Pills (Issue #927)
// ---------------------------------------------------------------------------

/// Integer square root via Newton-Raphson approximation.
pub fn isqrt(val: u64) u32 {
    if (val == 0) return 0;
    var x0: u64 = val;
    var x1: u64 = (x0 + 1) / 2;
    while (x1 < x0) {
        x0 = x1;
        x1 = (x0 + val / x0) / 2;
    }
    return @intCast(x0);
}

/// Anti-aliased rounded rectangle fill directly into a 32-bpp BGRA/RGBA pixel buffer.
/// Renders with 4-way subpixel quarter-circle anti-aliasing on the corners and
/// optimal non-overlapping solid spans for the interior.
pub fn fill_rounded_rect_buf(pixels: []u32, buf_w: u32, buf_h: u32, rect: Rect, radius: u32, color: u32) void {
    if (rect.w == 0 or rect.h == 0 or buf_w == 0 or buf_h == 0) return;
    if (rect.x >= buf_w or rect.y >= buf_h) return;

    const max_w = @min(rect.w, buf_w - rect.x);
    const max_h = @min(rect.h, buf_h - rect.y);
    const x0 = rect.x;
    const y0 = rect.y;
    const x1 = x0 + max_w;
    const y1 = y0 + max_h;

    const r = @min(radius, @min(max_w / 2, max_h / 2));
    const src_a: u32 = (color >> 24) & 0xFF;
    const base_a: u32 = if (src_a == 0) 255 else src_a;
    const rgb: u32 = color & 0x00FFFFFF;

    if (r == 0) {
        // Plain rectangular fill
        var py = y0;
        while (py < y1) : (py += 1) {
            const row_off = py * buf_w;
            var px = x0;
            while (px < x1) : (px += 1) {
                const idx = row_off + px;
                pixels[idx] = blend_source_over(pixels[idx], (base_a << 24) | rgb);
            }
        }
        return;
    }

    // 1. Center column (from x0 + r to x1 - r, full height y0 .. y1)
    if (x1 > x0 + 2 * r) {
        var py = y0;
        while (py < y1) : (py += 1) {
            const row_off = py * buf_w;
            var px = x0 + r;
            const end_x = x1 - r;
            while (px < end_x) : (px += 1) {
                const idx = row_off + px;
                pixels[idx] = blend_source_over(pixels[idx], (base_a << 24) | rgb);
            }
        }
    }

    // 2. Left and right waists (between top and bottom corners)
    if (y1 > y0 + 2 * r) {
        var py = y0 + r;
        const end_y = y1 - r;
        while (py < end_y) : (py += 1) {
            const row_off = py * buf_w;
            // Left waist
            var px_l = x0;
            const end_l = x0 + r;
            while (px_l < end_l) : (px_l += 1) {
                const idx = row_off + px_l;
                pixels[idx] = blend_source_over(pixels[idx], (base_a << 24) | rgb);
            }
            // Right waist
            var px_r = x1 - r;
            while (px_r < x1) : (px_r += 1) {
                const idx = row_off + px_r;
                pixels[idx] = blend_source_over(pixels[idx], (base_a << 24) | rgb);
            }
        }
    }

    // 3. 4 Anti-aliased corners (4-way quarter-circle symmetry)
    const R: u32 = r * 16;
    var iy: u32 = 0;
    while (iy < r) : (iy += 1) {
        // Vertical distance from corner center in 16x units
        const dy: i32 = @as(i32, @intCast((r - iy) * 16)) - 8;
        var ix: u32 = 0;
        while (ix < r) : (ix += 1) {
            // Horizontal distance from corner center in 16x units
            const dx: i32 = @as(i32, @intCast((r - ix) * 16)) - 8;
            const dist_sq: u64 = @intCast(dx * dx + dy * dy);
            const dist = isqrt(dist_sq);

            if (dist >= R + 8) continue; // Completely outside circle

            const coverage: u32 = if (dist + 8 <= R)
                255
            else
                ((R + 8 - dist) * 255) / 16;

            const eff_a = (base_a * coverage) / 255;
            if (eff_a == 0) continue;
            const src_px = (eff_a << 24) | rgb;

            // TL corner: (x0 + ix, y0 + iy)
            const tl_idx = (y0 + iy) * buf_w + (x0 + ix);
            pixels[tl_idx] = blend_source_over(pixels[tl_idx], src_px);

            // TR corner: (x1 - 1 - ix, y0 + iy)
            const tr_idx = (y0 + iy) * buf_w + (x1 - 1 - ix);
            pixels[tr_idx] = blend_source_over(pixels[tr_idx], src_px);

            // BL corner: (x0 + ix, y1 - 1 - iy)
            const bl_idx = (y1 - 1 - iy) * buf_w + (x0 + ix);
            pixels[bl_idx] = blend_source_over(pixels[bl_idx], src_px);

            // BR corner: (x1 - 1 - ix, y1 - 1 - iy)
            const br_idx = (y1 - 1 - iy) * buf_w + (x1 - 1 - ix);
            pixels[br_idx] = blend_source_over(pixels[br_idx], src_px);
        }
    }
}

/// Draw a filled rounded rectangle with corner radius r.
/// Uses subpixel anti-aliased blending if a backing buffer is registered,
/// otherwise falls back to batched span fills.
pub fn fill_rounded_rect(win_id: u32, rect: Rect, radius: u32, color: u32) void {
    if (rect.w == 0 or rect.h == 0) return;
    if (win_get_backing(win_id)) |backing| {
        fill_rounded_rect_buf(
            backing.pixels[0 .. @as(usize, backing.width) * backing.height],
            backing.width,
            backing.height,
            rect,
            radius,
            color,
        );
        return;
    }

    const r = @min(radius, @min(rect.w / 2, rect.h / 2));
    if (r == 0) {
        draw_rect(win_id, rect, color);
        return;
    }

    // Batched fill fallback
    // Center column
    if (rect.w > 2 * r) {
        win_fill_batched(win_id, rect.x + r, rect.y, rect.w - 2 * r, rect.h, color);
    }

    // Left and right waists
    if (rect.h > 2 * r) {
        win_fill_batched(win_id, rect.x, rect.y + r, r, rect.h - 2 * r, color);
        win_fill_batched(win_id, rect.x + rect.w - r, rect.y + r, r, rect.h - 2 * r, color);
    }

    // Corner spans
    var iy: u32 = 0;
    while (iy < r) : (iy += 1) {
        const dy = r - iy;
        const dx = isqrt(r * r - dy * dy);
        if (dx > 0) {
            // TL & TR
            win_fill_batched(win_id, rect.x + r - dx, rect.y + iy, dx, 1, color);
            win_fill_batched(win_id, rect.x + rect.w - r, rect.y + iy, dx, 1, color);
            // BL & BR
            win_fill_batched(win_id, rect.x + r - dx, rect.y + rect.h - 1 - iy, dx, 1, color);
            win_fill_batched(win_id, rect.x + rect.w - r, rect.y + rect.h - 1 - iy, dx, 1, color);
        }
    }
}

pub const draw_rounded_rect = fill_rounded_rect;

/// Fill a pill-shaped button or tab highlight (radius = min(w, h) / 2).
pub fn fill_pill(win_id: u32, rect: Rect, color: u32) void {
    const r = @min(rect.w, rect.h) / 2;
    fill_rounded_rect(win_id, rect, r, color);
}

/// Fill a pill-shaped button or tab highlight in a raw pixel buffer.
pub fn fill_pill_buf(pixels: []u32, buf_w: u32, buf_h: u32, rect: Rect, color: u32) void {
    const r = @min(rect.w, rect.h) / 2;
    fill_rounded_rect_buf(pixels, buf_w, buf_h, rect, r, color);
}

// ---------------------------------------------------------------------------
// Tests — draw_image_buf (M42 SX1, issue #982): the WM-server scanout blit.
// ---------------------------------------------------------------------------

test "draw: draw_image_buf source-over into a raw buffer" {
    var buf: [16]u32 = @as([16]u32, @splat(@as(u32, 0xFF202020))); // opaque dark gray, 4x4
    var src_px: [9]u32 = undefined;
    const src = Image{ .width = 3, .height = 3, .pixels = &src_px };

    // Row 0: transparent, opaque, 50% red
    src_px[0] = 0x00FFFFFF;
    src_px[1] = 0xFFFF0000;
    src_px[2] = 0x80FF0000;
    // Row 1: opaque green
    src_px[3] = 0xFF00FF00;
    src_px[4] = 0xFF00FF00;
    src_px[5] = 0xFF00FF00;
    // Row 2: transparent
    src_px[6] = 0x00000000;
    src_px[7] = 0x00000000;
    src_px[8] = 0x00000000;

    draw_image_buf(&buf, 4, 1, 1, src);

    // Transparent pixels leave the destination untouched
    try std.testing.expectEqual(@as(u32, 0xFF202020), buf[1 * 4 + 1]);
    try std.testing.expectEqual(@as(u32, 0xFF202020), buf[3 * 4 + 1]);
    // Opaque overwrite
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), buf[1 * 4 + 2]);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), buf[2 * 4 + 1]);
    // 50% red over dark gray 0x20: out = (255*128 + 32*127)/255 = 143 (0x8F)
    const blended = buf[1 * 4 + 3];
    const r = (blended >> 16) & 0xFF;
    try std.testing.expect(r >= 142 and r <= 144);
}

test "draw: draw_image_buf clips to buffer and stride" {
    var buf: [9]u32 = @as([9]u32, @splat(@as(u32, 0xFF101010))); // 3x3
    var src_px: [4]u32 = @as([4]u32, @splat(@as(u32, 0xFFFFFFFF)));
    const src = Image{ .width = 2, .height = 2, .pixels = &src_px };

    // Blit at the bottom-right corner: only the (2,2) pixel fits
    draw_image_buf(&buf, 3, 2, 2, src);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), buf[8]);
    try std.testing.expectEqual(@as(u32, 0xFF101010), buf[5]);

    // Fully outside: no-op, no OOB
    draw_image_buf(&buf, 3, 3, 0, src);
    draw_image_buf(&buf, 3, 0, 3, src);
    try std.testing.expectEqual(@as(u32, 0xFF101010), buf[2]);
    try std.testing.expectEqual(@as(u32, 0xFF101010), buf[6]);
}
