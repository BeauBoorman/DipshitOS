//! M73l (issue #1661) deliverable 1 — the glyph-atlas codegen and its
//! drift tripwire. M80i (#1725) grows it from ONE rasterized size to
//! the zoom ladder: three pixel sizes, one generated struct each.
//!
//! Why codegen instead of a comptime kernel bake (observed 2026-09-22):
//! the kernel package root is kernel/src, so from inside it both
//! `@import("../../user/src/lib/font_ttf.zig")` and
//! `@embedFile("../../image/fonts/…")` fail with *import of file outside
//! module path* — the engine and the font bytes are unreachable at
//! kernel comptime without build.zig surgery on every root that imports
//! text.zig. This tool sits in user/src/lib (the engine's own package),
//! reads the TTF at run time, renders printable ASCII at each ladder
//! pixel size through the single engine, and writes
//! kernel/src/font_atlas_data.zig: a small checked-in byte-vector
//! fixture the kernel imports from its own directory with zero build
//! wiring.
//!
//! Regenerate (repo root):  zig run user/src/lib/font_atlas_gen.zig
//! Tripwire   (repo root):  zig test user/src/lib/font_atlas_gen.zig
//!   — re-renders and byte-compares the checked-in file, so any engine
//!     or font change reddens the gate until the fixture is deliberately
//!     regenerated and the diff reviewed.

const std = @import("std");
const ttf = @import("font_ttf.zig");

pub const ttf_path = "image/fonts/FiraCode-Regular.ttf";
pub const out_path = "kernel/src/font_atlas_data.zig";

pub const first_cp: u32 = 0x20;
pub const last_cp: u32 = 0x7E;
pub const glyph_count: usize = last_cp - first_cp + 1; // 95

/// M80i (#1725): the zoom ladder — three rasterized pixel sizes for the
/// persisted `font_size` vocabulary (small/medium/large). The cell at
/// each size is measured, not guessed: FiraCode Regular has upem 1950
/// and M=W=x advance 1200 units, so the advance at px is
/// round(1200*px/1950) and the cell height is round(asc*px/1950) +
/// round(-desc*px/1950) over hhea's 1800/-600 — which lands on
/// 7x13 / 8x16 / 10x21 for 11/13/17 px (13px is the M73l design cell,
/// and the boot default the kernel keeps when the key is absent).
pub const SizeName = enum { small, medium, large };
pub const size_px: [3]u32 = .{ 11, 13, 17 };

/// Fixed cells array upper bounds — the ladder's largest raster is 17px:
/// cell 10x21 -> 5 bytes/row x 21 rows = 105 bytes/glyph.
pub const max_cell_w: u32 = 12;
pub const max_cell_h: u32 = 24;
pub const max_row_bytes: u32 = (max_cell_w + 1) / 2; // 6
pub const max_glyph_bytes: usize = max_cell_h * max_row_bytes; // 144

pub const Metrics = struct {
    px_size: u32,
    adv: u32, // the face's advance at this size — one cell wide
    ascent: u32, // baseline rows from the cell top
    descent: u32, // the rows below the baseline; cell_h - ascent
    cell_w: u32,
    cell_h: u32,
    row_bytes: u32, // ceil(cell_w/2): two 4-bit pixels per byte
    glyph_bytes: usize, // cell_h * row_bytes
    atlas_bytes: usize, // glyph_count * glyph_bytes
};

/// The three formulas in one place: the advance at the size, and the
/// rounded hhea ascender/descender at the size. `cell_h = ascent +
/// descent` by construction, so the renderer's placement invariant can
/// never drift away from the cell the kernel computes into.
pub fn measure(face: *const ttf.TrueTypeFace, px_size: u32) Metrics {
    const upem: f64 = @floatFromInt(face.units_per_em);
    const adv: u32 = face.measure_string(px_size, "M");
    const asc_f: f64 = @as(f64, @floatFromInt(face.ascender)) * @as(f64, @floatFromInt(px_size)) / upem;
    const desc_f: f64 = @as(f64, @floatFromInt(face.descender)) * @as(f64, @floatFromInt(px_size)) / upem;
    const ascent: u32 = @intFromFloat(@round(asc_f));
    const descent: u32 = @intFromFloat(@round(-desc_f)); // descender is negative
    const cell_w = adv;
    const cell_h = ascent + descent;
    const row_bytes = (cell_w + 1) / 2; // odd widths keep one spare nibble
    return .{
        .px_size = px_size,
        .adv = adv,
        .ascent = ascent,
        .descent = descent,
        .cell_w = cell_w,
        .cell_h = cell_h,
        .row_bytes = row_bytes,
        .glyph_bytes = cell_h * row_bytes,
        .atlas_bytes = glyph_count * cell_h * row_bytes,
    };
}

pub const Atlas = struct {
    m: Metrics,
    /// [95][max_glyph_bytes]u8, row-major: glyph (cp-0x20), row y, byte
    /// y*row_bytes + x/2, high nibble = even x, low nibble = odd x,
    /// level 0..15 = alpha/17. Bytes past `m.glyph_bytes` stay zero.
    cells: [glyph_count][max_glyph_bytes]u8 = @splat(@as([max_glyph_bytes]u8, @splat(0))),
};

/// Render every printable ASCII glyph through the engine and compose it
/// into its cell at `px_size`: pen x = 0 at the cell's left edge,
/// baseline `ascent` rows down, engine 8-bit alpha downsampled to 4 bits
/// (16 levels — the classic greyscale-font precision, and it halves the
/// fixture). Each call rasterizes at ONE size: the engine's glyph cache
/// is per-pixel-size by construction (entries do not carry their size),
/// so the cache lives here and dies with the call.
pub fn render(face: *const ttf.TrueTypeFace, px_size: u32) !Atlas {
    const m = measure(face, px_size);
    if (m.cell_w > max_cell_w or m.cell_h > max_cell_h) return error.MetricsDrift;

    var atlas: Atlas = .{ .m = m };
    var cache: ttf.TrueTypeFace.GlyphCache = .{};
    for (first_cp..last_cp + 1) |cp_usize| {
        const cp: u32 = @intCast(cp_usize);
        const gi = cp - first_cp;
        const g = cache.get_or_render(face, cp, px_size) orelse return error.RenderFailed;
        if (g.width == 0 or g.height == 0) continue; // space: cell stays zero
        const a = cache.glyph_alpha(g);
        // Pen starts at the cell's left edge; the baseline sits `ascent`
        // rows down, and bearing_y counts up from the baseline.
        const dx: i32 = g.bearing_x;
        const dy: i32 = @as(i32, @intCast(m.ascent)) - g.bearing_y;
        var gy: u32 = 0;
        while (gy < g.height) : (gy += 1) {
            const cy = dy + @as(i32, @intCast(gy));
            if (cy < 0 or cy >= m.cell_h) continue;
            var gx: u32 = 0;
            while (gx < g.width) : (gx += 1) {
                const cx = dx + @as(i32, @intCast(gx));
                if (cx < 0 or cx >= m.cell_w) continue;
                const lvl = a[@as(usize, @intCast(gy)) * g.width + @as(usize, @intCast(gx))] >> 4;
                if (lvl == 0) continue;
                const bi = @as(usize, @intCast(cy)) * m.row_bytes + @as(usize, @intCast(cx)) / 2;
                if (@rem(cx, 2) == 0) {
                    atlas.cells[gi][bi] |= lvl << 4;
                } else {
                    atlas.cells[gi][bi] |= lvl;
                }
            }
        }
    }
    return atlas;
}

/// The complete text of kernel/src/font_atlas_data.zig — one
/// allocPrint per size plus a hand-encoded hex blob (string literals are
/// the one thing `zig fmt` never reflows, so the fixture is fmt-stable
/// by construction).
pub fn generateSource(alloc: std.mem.Allocator, face: *const ttf.TrueTypeFace) ![]u8 {
    var blocks: [size_px.len][]u8 = undefined;
    var total: usize = header_text.len;
    inline for (size_px, 0..) |px, si| {
        const atlas = try render(face, px);
        const m = atlas.m;
        const hex = try alloc.alloc(u8, m.atlas_bytes * 4);
        defer alloc.free(hex);
        const digits = "0123456789abcdef";
        var i: usize = 0;
        for (atlas.cells) |cell| {
            for (cell[0..m.glyph_bytes]) |b| {
                hex[i] = '\\';
                hex[i + 1] = 'x';
                hex[i + 2] = digits[b >> 4];
                hex[i + 3] = digits[b & 0xF];
                i += 4;
            }
        }
        const block = try std.fmt.allocPrint(alloc,
            \\pub const {s} = struct {{
            \\    pub const px_size: u32 = {d};
            \\    pub const cell_w: u32 = {d};
            \\    pub const cell_h: u32 = {d};
            \\    pub const adv: u32 = {d};
            \\    pub const ascent: u32 = {d};
            \\    pub const descent: u32 = {d};
            \\    pub const first_cp: u32 = {d};
            \\    pub const last_cp: u32 = {d};
            \\    pub const glyph_count: usize = {d};
            \\    pub const row_bytes: u32 = {d};
            \\    pub const glyph_bytes: usize = {d};
            \\    pub const atlas_bytes: usize = {d};
            \\    pub const blob: *const [{d}:0]u8 =
            \\        "{s}";
            \\}};
            \\
        , .{
            @tagName(@as(SizeName, @fromBackingInt(@intCast(si)))),
            m.px_size,
            m.cell_w,
            m.cell_h,
            m.adv,
            m.ascent,
            m.descent,
            first_cp,
            last_cp,
            glyph_count,
            m.row_bytes,
            m.glyph_bytes,
            m.atlas_bytes,
            m.atlas_bytes,
            hex,
        });
        blocks[si] = block;
        total += block.len;
    }
    defer for (blocks) |b| alloc.free(b);
    const out = try alloc.alloc(u8, total);
    var pos: usize = 0;
    @memcpy(out[pos .. pos + header_text.len], header_text);
    pos += header_text.len;
    for (blocks) |b| {
        @memcpy(out[pos .. pos + b.len], b);
        pos += b.len;
    }
    return out;
}

/// The generated file's fixed header — kept here so the tripwire's
/// comparison is against the WHOLE file, header included.
const header_text =
    \\//! GENERATED FILE — do not edit. Regenerate:
    \\//!   zig run user/src/lib/font_atlas_gen.zig   (repo root)
    \\//! Tripwire (byte-compares this file against a fresh render):
    \\//!   zig test user/src/lib/font_atlas_gen.zig   (repo root)
    \\//!
    \\//! M73l (#1661) + M80i (#1725): FiraCode-Regular through
    \\//! user/src/lib/font_ttf.zig at the zoom ladder's three pixel sizes
    \\//! — printable ASCII 0x20..0x7E, 4-bit alpha (level v = alpha v*17),
    \\//! baseline `ascent` rows from the cell top. One struct per size
    \\//! (small 11px 7x13, medium 13px 8x16, large 17px 10x21 — the cell
    \\//! is measured at the size, so the advance is NOT constant across
    \\//! the ladder). Layout: glyph (cp-32) starts at
    \\//! blob[(cp-32)*glyph_bytes]; row y is
    \\//! blob[off + y*row_bytes .. off + (y+1)*row_bytes]; high nibble =
    \\//! even x, low nibble = odd x (odd cell widths leave the last low
    \\//! nibble unused).
    \\
    \\
;

fn loadFira(alloc: std.mem.Allocator) ![]u8 {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    return std.Io.Dir.cwd().readFileAlloc(io, ttf_path, alloc, std.Io.Limit.limited(2 * 1024 * 1024));
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const fira = try loadFira(alloc);
    var face = try ttf.TrueTypeFace.init(fira);
    const src = try generateSource(alloc, &face);
    var io_impl = std.Io.Threaded.init_single_threaded;
    try std.Io.Dir.cwd().writeFile(io_impl.io(), .{ .sub_path = out_path, .data = src });
    std.debug.print("font_atlas_gen: wrote {s} ({d} bytes)\n", .{ out_path, src.len });
}

test "checked-in atlas is exactly a fresh engine render" {
    const alloc = std.testing.allocator;
    const fira = try loadFira(alloc);
    defer alloc.free(fira);
    var face = try ttf.TrueTypeFace.init(fira);
    const fresh = try generateSource(alloc, &face);
    defer alloc.free(fresh);

    var io_impl = std.Io.Threaded.init_single_threaded;
    const checked = try std.Io.Dir.cwd().readFileAlloc(io_impl.io(), out_path, alloc, std.Io.Limit.limited(512 * 1024));
    defer alloc.free(checked);
    // The tripwire: an engine or font change reddens here until the
    // fixture is regenerated on purpose and the diff reviewed.
    try std.testing.expectEqualStrings(fresh, checked);
}

test "cell metrics pin at the measured values" {
    const alloc = std.testing.allocator;
    const fira = try loadFira(alloc);
    defer alloc.free(fira);
    var face = try ttf.TrueTypeFace.init(fira);

    // M80i (#1725): the ladder's three expectations. The numbers come
    // from the face's own design units — advance 1200, hhea ascender
    // 1800, descender -600 at upem 1950 — each scaled to the pixel size
    // and rounded, so a font change moves them and reddens here. 13px
    // is the M73l design cell (8x16, unchanged); 11px and 17px are the
    // M80i zoom sizes the `font_size` key selects.
    const expectations = [_]struct { px: u32, adv: u32, ascent: u32, descent: u32 }{
        .{ .px = 11, .adv = 7, .ascent = 10, .descent = 3 },
        .{ .px = 13, .adv = 8, .ascent = 12, .descent = 4 },
        .{ .px = 17, .adv = 10, .ascent = 16, .descent = 5 },
    };
    for (expectations) |e| {
        const m = measure(&face, e.px);
        try std.testing.expectEqual(e.adv, m.adv);
        try std.testing.expectEqual(e.ascent, m.ascent);
        try std.testing.expectEqual(e.descent, m.descent);
        try std.testing.expectEqual(e.adv, m.cell_w);
        try std.testing.expectEqual(e.ascent + e.descent, m.cell_h);
        try std.testing.expectEqual((e.adv + 1) / 2, m.row_bytes);
        try std.testing.expectEqual(@as(usize, m.cell_h) * m.row_bytes, m.glyph_bytes);
    }

    // The three size slots are exactly the ladder, in order.
    try std.testing.expectEqual(@as(u32, 11), size_px[0]);
    try std.testing.expectEqual(@as(u32, 13), size_px[1]);
    try std.testing.expectEqual(@as(u32, 17), size_px[2]);
}

test "every size's atlas: space is empty, the rest is inked" {
    const alloc = std.testing.allocator;
    const fira = try loadFira(alloc);
    defer alloc.free(fira);
    var face = try ttf.TrueTypeFace.init(fira);
    for (size_px) |px| {
        const atlas = try render(&face, px);
        const gb = atlas.m.glyph_bytes;
        // Space is the empty cell.
        for (atlas.cells[0][0..gb]) |b| try std.testing.expectEqual(@as(u8, 0), b);
        // The engine actually inked the rest: a conservative floor over
        // 94 glyphs (typical coverage lands well above it at every size).
        var total: u64 = 0;
        for (atlas.cells[1..]) |cell| {
            for (cell[0..gb]) |b| total += b;
        }
        try std.testing.expect(total > 0x800);
    }
}
