//! M85b (#1814, index #1808): the terminal image layer — the streaming
//! sixel decoder and the bounded pixel buffers a grid's image cells point
//! into.
//!
//! M85a (#1813) picked sixel as the primary protocol and put the seam on
//! the grid, so an image is CELL-NATIVE: placement writes image cells
//! (terminal.zig `Cell.img`/`tx`/`ty`) that scroll, erase, reflow and get
//! overwritten exactly like text cells. This module owns only the pixels
//! and the decoder that fills them. Pure: fixed arrays, no allocation, no
//! hardware, host-testable.
//!
//! Bounds — the fixed-pools rule: refuse honestly, never clamp silently.
//!   * An image is at most `max_w` x `max_h` pixels. A SET pixel, or a
//!     raster declaration (`"Pan;Pad;Ph;Pv`), past either bound refuses the
//!     WHOLE image: the rest of the payload drains to ST, nothing is placed,
//!     and the image already on screen is untouched (decode targets a
//!     staging buffer, never a live one).
//!   * The payload itself has no byte bound: decode streams byte by byte,
//!     so there is no capture buffer to overflow.
//!   * Pixels store a colour-register INDEX and the image's own 256-entry
//!     palette colours them at paint time — VT340 register semantics, so an
//!     encoder that redefines a register mid-image recolours the pixels it
//!     already drew with it. Registers past 255 wrap (Pc mod 256).
//!   * Unset pixels are transparent (the cell's fill shows through) whatever
//!     the DCS P2 background selector says, and every sixel is one square
//!     pixel: P1 and the raster Pan/Pad aspect ratio are parsed, not
//!     honoured (the modern 1:1 encoder convention).
//!
//! Sizing is measured, not guessed: KERNEL.BIN sits ~24 KiB under the boot
//! loader's 16 MiB `kernel_max_size` and carries BSS as zero fill, and the
//! `screens` registry is .data (every Screen byte costs 4x in the image),
//! so no pixel lives in the image at all. A terminal's `Bank` (`buffers`
//! images at ~7.8 KiB each) comes from the page pool on its first sixel
//! (terminal.zig `imageBankClaim`); the bounds below are RAM-cheap.

const std = @import("std");

/// The largest image, in pixels — a thumbnail per terminal. The tile
/// coordinates in terminal.zig's `Cell` are u7, so neither bound may pass
/// 128 whatever the cell size.
pub const max_w: u16 = 96;
pub const max_h: u16 = 64;
/// Committed images per terminal. A new image past this evicts the oldest
/// one still on the grid (its cells go blank, counted by the Screen).
pub const slots: usize = 1;
/// `slots` committed images plus the staging buffer a decode writes into,
/// so a refused image never costs the one already placed.
pub const buffers: usize = slots + 1;
pub const registers: usize = 256;

const mask_row: usize = (max_w + 7) / 8;

comptime {
    std.debug.assert(max_w <= 128 and max_h <= 128);
    std.debug.assert(buffers <= 7); // `Cell.img` is u3 with 0 = no image
}

/// One decoded image. `w`/`h` and the cell geometry are written only when
/// a decode commits; until then the buffer is staging and no cell refers
/// to it.
pub const Image = struct {
    w: u16 = 0,
    h: u16 = 0,
    /// The cell geometry in force at placement: each image cell shows a
    /// `cell_w` x `cell_h` tile of the image.
    cell_w: u8 = 0,
    cell_h: u8 = 0,
    /// Placement order, for oldest-first eviction.
    seq: u32 = 0,
    palette: [registers]u32 = undefined,
    index: [max_h][max_w]u8 = undefined,
    set: [max_h][mask_row]u8 = undefined,

    /// The pixel at (x, y) as 0xRRGGBB, or null when it is transparent
    /// (unset) or outside the image.
    pub fn pixel(self: *const Image, x: usize, y: usize) ?u32 {
        if (x >= self.w or y >= self.h) return null;
        if (self.set[y][x >> 3] & (@as(u8, 1) << @intCast(x & 7)) == 0) return null;
        return self.palette[self.index[y][x]];
    }

    fn put(self: *Image, x: usize, y: usize, reg: u8) void {
        self.index[y][x] = reg;
        self.set[y][x >> 3] |= @as(u8, 1) << @intCast(x & 7);
    }
};

/// One terminal's image storage.
pub const Bank = struct {
    img: [buffers]Image,
};

/// What one image cell shows: the tile's origin inside its image.
pub const Tile = struct {
    img: *const Image,
    x0: usize,
    y0: usize,

    /// Sample the tile at (dx, dy) of a `cw` x `ch` destination cell.
    /// Nearest neighbour from the placement geometry, so a font zoom
    /// scales the tile with its cell instead of cropping or tearing it.
    pub fn sample(self: Tile, dx: usize, dy: usize, cw: usize, ch: usize) ?u32 {
        if (cw == 0 or ch == 0) return null;
        const sx = self.x0 + dx * self.img.cell_w / cw;
        const sy = self.y0 + dy * self.img.cell_h / ch;
        return self.img.pixel(sx, sy);
    }
};

fn pct(p: u32) u32 {
    const v: u32 = @min(p, 100);
    return (v * 255 + 50) / 100;
}

/// A sixel RGB colour (each channel 0..100 percent) as 0xRRGGBB.
pub fn rgbPercent(r: u32, g: u32, b: u32) u32 {
    return (pct(r) << 16) | (pct(g) << 8) | pct(b);
}

fn hueChannel(p: u32, q: u32, t_in: u32) u32 {
    const t = t_in % 360;
    const v = if (t < 60)
        p + (q - p) * t / 60
    else if (t < 180)
        q
    else if (t < 240)
        p + (q - p) * (240 - t) / 60
    else
        p;
    return (v * 255 + 5000) / 10000;
}

/// A sixel HLS colour as 0xRRGGBB. DEC's hue wheel puts blue at 0, red at
/// 120 and green at 240 (standard HSL has red at 0), so the hue turns by
/// 240 before the usual conversion. Lightness/saturation are percent;
/// the math runs in hundredths of a percent.
pub fn hlsToRgb(h_in: u32, l_in: u32, s_in: u32) u32 {
    const h_c: u32 = @min(h_in, 360);
    const l_c: u32 = @min(l_in, 100);
    const s_c: u32 = @min(s_in, 100);
    const h = (h_c + 240) % 360;
    const l = l_c * 100;
    const s = s_c * 100;
    if (s == 0) {
        const v = (l * 255 + 5000) / 10000;
        return (v << 16) | (v << 8) | v;
    }
    const q = if (l < 5000) l * (10000 + s) / 10000 else l + s - l * s / 10000;
    const p = 2 * l - q;
    const r = hueChannel(p, q, h + 120);
    const g = hueChannel(p, q, h);
    const b = hueChannel(p, q, h + 240);
    return (r << 16) | (g << 8) | b;
}

/// The VT340 default colour map for registers 0..15, in percent; the
/// other registers start black. Encoders that care define what they use.
const vt340_map = [16][3]u8{
    .{ 0, 0, 0 },    .{ 20, 20, 80 }, .{ 80, 13, 13 }, .{ 20, 80, 20 },
    .{ 80, 20, 80 }, .{ 20, 80, 80 }, .{ 80, 80, 20 }, .{ 53, 53, 53 },
    .{ 26, 26, 26 }, .{ 33, 33, 60 }, .{ 60, 26, 26 }, .{ 33, 60, 33 },
    .{ 60, 33, 60 }, .{ 33, 60, 60 }, .{ 60, 60, 33 }, .{ 80, 80, 80 },
};

/// The streaming sixel decoder: one byte in, pixels into the staging
/// image. Lives inside each Screen (small), unlike the pixels.
pub const Decoder = struct {
    /// The bank buffer this decode writes into.
    stage: u8 = 0,
    /// The image broke a bound: the rest of the payload drains.
    refused: bool = false,
    x: u32 = 0,
    band: u32 = 0,
    reg: u8 = 0,
    repeat: u32 = 1,
    /// The command collecting parameters (`#`, `!`, `"`), or 0.
    cmd: u8 = 0,
    params: [5]u16 = @as([5]u16, @splat(@as(u16, 0))),
    /// `;` separators seen so far (the index of the parameter being read).
    pcount: u8 = 0,
    /// The extent so far: set pixels unioned with any raster declaration.
    w: u32 = 0,
    h: u32 = 0,

    /// Start a decode into `img` (bank buffer `stage`).
    pub fn begin(self: *Decoder, img: *Image, stage: u8) void {
        self.* = .{ .stage = stage };
        img.w = 0;
        img.h = 0;
        @memset(std.mem.asBytes(&img.set), 0);
        @memset(&img.palette, 0);
        for (vt340_map, 0..) |c, i| img.palette[i] = rgbPercent(c[0], c[1], c[2]);
    }

    /// Mark the decode refused (a bound broke, or its buffer went away).
    pub fn refuse(self: *Decoder) void {
        self.refused = true;
    }

    /// One payload byte (everything after the DCS `q`, before ST).
    pub fn feed(self: *Decoder, img: *Image, b: u8) void {
        if (self.refused) return;
        if (self.cmd != 0) {
            if (b >= '0' and b <= '9') {
                if (self.pcount < self.params.len) {
                    const i = self.pcount;
                    self.params[i] = self.params[i] *| 10 +| (b - '0');
                }
                return;
            }
            if (b == ';') {
                self.pcount +|= 1;
                return;
            }
            self.command(img);
            if (self.refused) return;
        }
        switch (b) {
            '?'...'~' => self.sixel(img, b - '?'),
            '#', '!', '"' => {
                self.cmd = b;
                self.params = @as([5]u16, @splat(@as(u16, 0)));
                self.pcount = 0;
            },
            '$' => self.x = 0, // graphics carriage return
            '-' => { // graphics new line: the next six-pixel band
                self.x = 0;
                self.band +|= 1;
            },
            else => {}, // anything else inside the payload is ignored
        }
    }

    fn command(self: *Decoder, img: *Image) void {
        const cmd = self.cmd;
        const p = self.params;
        self.cmd = 0;
        switch (cmd) {
            '#' => {
                // `#Pc` selects a register; `#Pc;Pu;Px;Py;Pz` defines and
                // selects it (Pu 1 = HLS, 2 = RGB; other Pu define nothing).
                self.reg = @truncate(p[0]);
                if (self.pcount >= 4) {
                    switch (p[1]) {
                        1 => img.palette[self.reg] = hlsToRgb(p[2], p[3], p[4]),
                        2 => img.palette[self.reg] = rgbPercent(p[2], p[3], p[4]),
                        else => {},
                    }
                }
            },
            '!' => self.repeat = @max(1, p[0]),
            '"' => {
                if (self.pcount < 3) return;
                if (p[2] > max_w or p[3] > max_h) return self.refuse();
                self.w = @max(self.w, p[2]);
                self.h = @max(self.h, p[3]);
            },
            else => {},
        }
    }

    fn sixel(self: *Decoder, img: *Image, bits: u8) void {
        const n = self.repeat;
        self.repeat = 1;
        if (bits == 0) {
            self.x +|= n;
            return;
        }
        const top = self.band *| 6;
        const high: u32 = 7 - @as(u32, @clz(bits));
        if (self.x +| n > max_w or top +| high >= max_h) return self.refuse();
        var bit: u8 = 0;
        while (bit < 6) : (bit += 1) {
            if (bits & (@as(u8, 1) << @intCast(bit)) == 0) continue;
            var x = self.x;
            while (x < self.x + n) : (x += 1) img.put(x, top + bit, self.reg);
        }
        self.x += n;
        self.w = @max(self.w, self.x);
        self.h = @max(self.h, top + high + 1);
    }

    /// ST arrived. True when a non-empty image is ready to place: its
    /// extent and the placement cell geometry are stamped on `img`. False
    /// for a refused decode (`refused` says so) and for an empty one.
    pub fn finish(self: *Decoder, img: *Image, cell_w: u32, cell_h: u32) bool {
        if (self.cmd != 0) self.command(img);
        if (self.refused or self.w == 0 or self.h == 0) return false;
        img.w = @intCast(self.w);
        img.h = @intCast(self.h);
        img.cell_w = @intCast(cell_w);
        img.cell_h = @intCast(cell_h);
        return true;
    }
};

// ---------------------------------------------------------------------------
// Tests — the decoder in isolation. Placement semantics are pinned by the
// corpus (terminal_corpus.zig) and terminal.zig's registry tests.
// ---------------------------------------------------------------------------

var test_img: Image = .{};

fn decode(payload: []const u8) struct { ok: bool, refused: bool } {
    var d: Decoder = .{};
    d.begin(&test_img, 0);
    for (payload) |b| d.feed(&test_img, b);
    const ok = d.finish(&test_img, 8, 16);
    return .{ .ok = ok, .refused = d.refused };
}

test "term_image: a sixel sets six rows per band, bit 0 on top" {
    // '@' = 0x40 - 0x3f = 1 (top pixel only); 'A' = 2; '~' = 63 (all six).
    const r = decode("#1;2;100;0;0@A~");
    try std.testing.expect(r.ok);
    try std.testing.expectEqual(@as(u16, 3), test_img.w);
    try std.testing.expectEqual(@as(u16, 6), test_img.h);
    try std.testing.expectEqual(@as(?u32, 0xff0000), test_img.pixel(0, 0));
    try std.testing.expectEqual(@as(?u32, null), test_img.pixel(0, 1));
    try std.testing.expectEqual(@as(?u32, null), test_img.pixel(1, 0));
    try std.testing.expectEqual(@as(?u32, 0xff0000), test_img.pixel(1, 1));
    for (0..6) |y| try std.testing.expectEqual(@as(?u32, 0xff0000), test_img.pixel(2, y));
    try std.testing.expectEqual(@as(u8, 8), test_img.cell_w);
    try std.testing.expectEqual(@as(u8, 16), test_img.cell_h);
}

test "term_image: repeat, graphics CR and graphics NL" {
    // `!5~` is five full columns; `$` returns to x=0 on the same band and
    // overprints with register 2; `-` moves to the next band.
    const r = decode("#1;2;0;0;100!5~$#2;2;0;100;0@-~");
    try std.testing.expect(r.ok);
    try std.testing.expectEqual(@as(u16, 5), test_img.w);
    try std.testing.expectEqual(@as(u16, 12), test_img.h);
    try std.testing.expectEqual(@as(?u32, 0x00ff00), test_img.pixel(0, 0));
    try std.testing.expectEqual(@as(?u32, 0x0000ff), test_img.pixel(0, 1));
    try std.testing.expectEqual(@as(?u32, 0x0000ff), test_img.pixel(4, 5));
    try std.testing.expectEqual(@as(?u32, 0x00ff00), test_img.pixel(0, 6));
    try std.testing.expectEqual(@as(?u32, null), test_img.pixel(1, 6));
    // `!0` repeats once, like `!1`.
    try std.testing.expect(decode("!0~").ok);
    try std.testing.expectEqual(@as(u16, 1), test_img.w);
}

test "term_image: colour registers — defaults, HLS, RGB, wrap, recolour" {
    // Register 1 keeps the VT340 default (20/20/80 %) until redefined.
    try std.testing.expect(decode("#1~").ok);
    try std.testing.expectEqual(@as(?u32, rgbPercent(20, 20, 80)), test_img.pixel(0, 0));
    try std.testing.expectEqual(@as(u32, 0x3333cc), rgbPercent(20, 20, 80));
    // DEC HLS: hue 0 is blue, 120 red, 240 green; L 50 S 100 is pure.
    try std.testing.expectEqual(@as(u32, 0x0000ff), hlsToRgb(0, 50, 100));
    try std.testing.expectEqual(@as(u32, 0xff0000), hlsToRgb(120, 50, 100));
    try std.testing.expectEqual(@as(u32, 0x00ff00), hlsToRgb(240, 50, 100));
    try std.testing.expectEqual(@as(u32, 0x808080), hlsToRgb(0, 50, 0));
    try std.testing.expectEqual(@as(u32, 0xffffff), hlsToRgb(0, 100, 100));
    // Percentages past 100 are read as 100 (the VT340 range).
    try std.testing.expectEqual(@as(u32, 0xffffff), rgbPercent(250, 101, 100));
    // Pc 257 wraps to register 1.
    try std.testing.expect(decode("#257;2;0;100;0#1~").ok);
    try std.testing.expectEqual(@as(?u32, 0x00ff00), test_img.pixel(0, 0));
    // Redefining a register after drawing recolours what it drew.
    try std.testing.expect(decode("#3;2;100;0;0~#3;2;0;0;100").ok);
    try std.testing.expectEqual(@as(?u32, 0x0000ff), test_img.pixel(0, 0));
}

test "term_image: raster attributes extend the extent; payload noise is ignored" {
    const r = decode("\"1;1;16;20#1\r\n@ ");
    try std.testing.expect(r.ok);
    try std.testing.expectEqual(@as(u16, 16), test_img.w);
    try std.testing.expectEqual(@as(u16, 20), test_img.h);
    try std.testing.expectEqual(@as(?u32, null), test_img.pixel(15, 19));
    // A raster declaration alone is a transparent image of that size.
    try std.testing.expect(decode("\"1;1;4;4").ok);
    try std.testing.expectEqual(@as(u16, 4), test_img.w);
    // Nothing drawn and nothing declared: no image, and not a refusal.
    const e = decode("??$-");
    try std.testing.expect(!e.ok);
    try std.testing.expect(!e.refused);
}

test "term_image: the bounds refuse whole, never clamp" {
    // Exactly max_w columns and max_h rows fit: 11 bands reach row 65,
    // but rows 64/65 stay unset, so the image is 96 x 64.
    // ('N' = 15: bits 0..3, rows 60..63 of band 10.)
    const r = decode("!96~-!96~-!96~-!96~-!96~-!96~-!96~-!96~-!96~-!96~-!96N");
    try std.testing.expect(r.ok);
    try std.testing.expectEqual(max_w, test_img.w);
    try std.testing.expectEqual(max_h, test_img.h);
    try std.testing.expectEqual(@as(?u32, 0), test_img.pixel(95, 63));
    // One more column, one more row, or a raster past the bound: refused.
    try std.testing.expect(decode("!97~").refused);
    try std.testing.expect(decode("!96?~").refused);
    try std.testing.expect(decode("----------O").refused); // band 10, bit 4 = row 64
    try std.testing.expect(decode("-----------@").refused); // band 11 = row 66
    try std.testing.expect(decode("\"1;1;97;1").refused);
    try std.testing.expect(decode("\"1;1;1;65").refused);
    // A blank sixel sets nothing, so a far-right one breaks nothing —
    // only a SET pixel past the bound refuses.
    try std.testing.expect(decode("~!500?").ok);
    try std.testing.expectEqual(@as(u16, 1), test_img.w);
    try std.testing.expect(decode("!500?~").refused);
}
