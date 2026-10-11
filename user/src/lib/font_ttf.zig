//! Freestanding TrueType (.ttf) font parser and rasterizer for VirelaiOS.
//!
//! Designed for EL0 userland with zero libc or POSIX dependencies.
//! Parses standard TrueType tables (head, maxp, hhea, hmtx, cmap, loca, glyf),
//! evaluates quadratic Bézier curves, and rasterizes anti-aliased glyphs.

const std = @import("std");

pub const Error = error{
    InvalidFontFormat,
    TableNotFound,
    UnsupportedCmapFormat,
    InvalidGlyphIndex,
    MalformedTable,
    BufferTooSmall,
};

pub const TableRecord = struct {
    tag: [4]u8,
    checksum: u32,
    offset: u32,
    length: u32,
};

pub const GlyphMetrics = struct {
    advance_width: u16,
    lsb: i16,
};

pub const TrueTypeFace = struct {
    data: []const u8,
    num_tables: u16,

    // Cached table slices
    head_table: []const u8,
    maxp_table: []const u8,
    hhea_table: []const u8,
    hmtx_table: []const u8,
    cmap_table: []const u8,
    loca_table: []const u8,
    glyf_table: []const u8,

    // Header metrics
    units_per_em: u16,
    index_to_loc_format: i16, // 0 = 16-bit / 2, 1 = 32-bit
    num_glyphs: u16,
    num_h_metrics: u16,
    ascender: i16,
    descender: i16,
    line_gap: i16,

    // Selected cmap subtable offset relative to cmap_table
    cmap_subtable_offset: u32,
    cmap_format: u16,

    // Static scratch buffers to eliminate stack pressure in 8 KiB userland threads
    pub var scratch_pts: [512]Point = undefined;
    pub var scratch_ends: [32]u16 = undefined;
    pub var scratch_segs: [1024]LineSegment = undefined;
    pub var scratch_scaled_segs: [1024]LineSegment = undefined;
    pub var scratch_sub_accum: [2048]u16 = undefined;
    pub var scratch_comp_pts: [256]Point = undefined;
    pub var scratch_comp_ends: [16]u16 = undefined;

    pub fn init(data: []const u8) Error!TrueTypeFace {
        if (data.len < 12) return error.InvalidFontFormat;

        const sfnt_version = std.mem.readInt(u32, data[0..4], .big);
        // Standard TrueType versions: 0x00010000 or 'true' (0x74727565)
        if (sfnt_version != 0x00010000 and sfnt_version != 0x74727565) {
            return error.InvalidFontFormat;
        }

        const num_tables = std.mem.readInt(u16, data[4..6], .big);
        if (data.len < 12 + @as(usize, num_tables) * 16) {
            return error.InvalidFontFormat;
        }

        var face = TrueTypeFace{
            .data = data,
            .num_tables = num_tables,
            .head_table = &.{},
            .maxp_table = &.{},
            .hhea_table = &.{},
            .hmtx_table = &.{},
            .cmap_table = &.{},
            .loca_table = &.{},
            .glyf_table = &.{},
            .units_per_em = 1000,
            .index_to_loc_format = 0,
            .num_glyphs = 0,
            .num_h_metrics = 0,
            .ascender = 0,
            .descender = 0,
            .line_gap = 0,
            .cmap_subtable_offset = 0,
            .cmap_format = 0,
        };

        // Scan table directory
        var i: usize = 0;
        while (i < num_tables) : (i += 1) {
            const entry_offset = 12 + i * 16;
            const tag: [4]u8 = data[entry_offset..][0..4].*;
            const offset = std.mem.readInt(u32, data[entry_offset + 8 ..][0..4], .big);
            const length = std.mem.readInt(u32, data[entry_offset + 12 ..][0..4], .big);

            if (offset + length > data.len) return error.MalformedTable;
            const slice = data[offset .. offset + length];

            if (std.mem.eql(u8, &tag, "head")) face.head_table = slice;
            if (std.mem.eql(u8, &tag, "maxp")) face.maxp_table = slice;
            if (std.mem.eql(u8, &tag, "hhea")) face.hhea_table = slice;
            if (std.mem.eql(u8, &tag, "hmtx")) face.hmtx_table = slice;
            if (std.mem.eql(u8, &tag, "cmap")) face.cmap_table = slice;
            if (std.mem.eql(u8, &tag, "loca")) face.loca_table = slice;
            if (std.mem.eql(u8, &tag, "glyf")) face.glyf_table = slice;
        }

        // Validate required tables
        if (face.head_table.len < 54) return error.TableNotFound;
        if (face.maxp_table.len < 6) return error.TableNotFound;
        if (face.hhea_table.len < 36) return error.TableNotFound;
        if (face.hmtx_table.len == 0) return error.TableNotFound;
        if (face.cmap_table.len < 4) return error.TableNotFound;
        if (face.loca_table.len == 0) return error.TableNotFound;
        if (face.glyf_table.len == 0) return error.TableNotFound;

        // Parse head
        face.units_per_em = std.mem.readInt(u16, face.head_table[18..20], .big);
        face.index_to_loc_format = std.mem.readInt(i16, face.head_table[50..52], .big);

        // Parse maxp
        face.num_glyphs = std.mem.readInt(u16, face.maxp_table[4..6], .big);

        // Parse hhea
        face.ascender = std.mem.readInt(i16, face.hhea_table[4..6], .big);
        face.descender = std.mem.readInt(i16, face.hhea_table[6..8], .big);
        face.line_gap = std.mem.readInt(i16, face.hhea_table[8..10], .big);
        face.num_h_metrics = std.mem.readInt(u16, face.hhea_table[34..36], .big);

        // Select cmap subtable (prefer Platform 3 / Windows Unicode BMP format 4 or full format 12)
        try face.select_cmap_subtable();

        return face;
    }

    fn select_cmap_subtable(self: *TrueTypeFace) Error!void {
        const num_subtables = std.mem.readInt(u16, self.cmap_table[2..4], .big);
        var chosen_offset: ?u32 = null;
        var chosen_fmt: u16 = 0;

        var i: usize = 0;
        while (i < num_subtables) : (i += 1) {
            const rec_offset = 4 + i * 8;
            if (rec_offset + 8 > self.cmap_table.len) return error.MalformedTable;

            const platform_id = std.mem.readInt(u16, self.cmap_table[rec_offset..][0..2], .big);
            const encoding_id = std.mem.readInt(u16, self.cmap_table[rec_offset + 2 ..][0..2], .big);
            const sub_offset = std.mem.readInt(u32, self.cmap_table[rec_offset + 4 ..][0..4], .big);

            if (sub_offset + 2 > self.cmap_table.len) continue;
            const sub_fmt = std.mem.readInt(u16, self.cmap_table[sub_offset..][0..2], .big);

            // Prefer Windows Unicode BMP (3, 1) format 4, or Unicode Full (3, 10) format 12
            if (platform_id == 3 and encoding_id == 1 and sub_fmt == 4) {
                chosen_offset = sub_offset;
                chosen_fmt = 4;
                break; // Format 4 on (3, 1) is ideal
            } else if (platform_id == 0 and sub_fmt == 4) {
                if (chosen_offset == null) {
                    chosen_offset = sub_offset;
                    chosen_fmt = 4;
                }
            } else if ((platform_id == 3 and encoding_id == 10) or (platform_id == 0 and encoding_id == 4)) {
                if (sub_fmt == 12 and chosen_fmt != 4) {
                    chosen_offset = sub_offset;
                    chosen_fmt = 12;
                }
            }
        }

        if (chosen_offset) |off| {
            self.cmap_subtable_offset = off;
            self.cmap_format = chosen_fmt;
        } else {
            return error.UnsupportedCmapFormat;
        }
    }

    /// Map a Unicode codepoint to a glyph index (0 if not found).
    pub fn glyph_index(self: *const TrueTypeFace, codepoint: u32) u16 {
        if (self.cmap_format == 4) {
            return self.glyph_index_format4(codepoint);
        } else if (self.cmap_format == 12) {
            return self.glyph_index_format12(codepoint);
        }
        return 0;
    }

    fn glyph_index_format4(self: *const TrueTypeFace, cp: u32) u16 {
        if (cp > 0xFFFF) return 0; // Format 4 only covers 16-bit BMP
        const c16: u16 = @intCast(cp);

        const sub = self.cmap_table[self.cmap_subtable_offset..];
        if (sub.len < 14) return 0;

        const seg_count_x2 = std.mem.readInt(u16, sub[6..8], .big);
        const seg_count = seg_count_x2 / 2;

        const end_code_off: usize = 14;
        const start_code_off: usize = end_code_off + seg_count_x2 + 2; // +2 for reservedPad
        const id_delta_off: usize = start_code_off + seg_count_x2;
        const id_range_offset_off: usize = id_delta_off + seg_count_x2;

        if (id_range_offset_off + seg_count_x2 > sub.len) return 0;

        // Binary search segments
        var low: usize = 0;
        var high: usize = seg_count;

        while (low < high) {
            const mid = low + (high - low) / 2;
            const end_code = std.mem.readInt(u16, sub[end_code_off + mid * 2 ..][0..2], .big);
            if (end_code < c16) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        const seg_idx = low;
        if (seg_idx >= seg_count) return 0;

        const start_code = std.mem.readInt(u16, sub[start_code_off + seg_idx * 2 ..][0..2], .big);
        if (c16 < start_code) return 0;

        const id_delta = std.mem.readInt(i16, sub[id_delta_off + seg_idx * 2 ..][0..2], .big);
        const id_range_offset_pos = id_range_offset_off + seg_idx * 2;
        const id_range_offset = std.mem.readInt(u16, sub[id_range_offset_pos..][0..2], .big);

        if (id_range_offset == 0) {
            return @as(u16, @bitCast(@as(i16, @bitCast(c16)) +% id_delta));
        }

        // idRangeOffset points into glyphIdArray
        const glyph_idx_addr = id_range_offset_pos + id_range_offset + (c16 - start_code) * 2;
        if (glyph_idx_addr + 2 > sub.len) return 0;

        const raw_glyph_id = std.mem.readInt(u16, sub[glyph_idx_addr..][0..2], .big);
        if (raw_glyph_id == 0) return 0;

        return @as(u16, @bitCast(@as(i16, @bitCast(raw_glyph_id)) +% id_delta));
    }

    fn glyph_index_format12(self: *const TrueTypeFace, cp: u32) u16 {
        const sub = self.cmap_table[self.cmap_subtable_offset..];
        if (sub.len < 16) return 0;

        const num_groups = std.mem.readInt(u32, sub[12..16], .big);
        const groups_offset: usize = 16;
        if (groups_offset + num_groups * 12 > sub.len) return 0;

        var low: usize = 0;
        var high: usize = num_groups;

        while (low < high) {
            const mid = low + (high - low) / 2;
            const off = groups_offset + mid * 12;
            const start_char = std.mem.readInt(u32, sub[off..][0..4], .big);
            const end_char = std.mem.readInt(u32, sub[off + 4 ..][0..4], .big);

            if (cp < start_char) {
                high = mid;
            } else if (cp > end_char) {
                low = mid + 1;
            } else {
                const start_glyph = std.mem.readInt(u32, sub[off + 8 ..][0..4], .big);
                return @intCast(start_glyph + (cp - start_char));
            }
        }

        return 0;
    }

    /// Retrieve horizontal metrics for a glyph index.
    pub fn glyph_metrics(self: *const TrueTypeFace, glyph_idx: u16) GlyphMetrics {
        if (self.num_h_metrics == 0) return .{ .advance_width = self.units_per_em, .lsb = 0 };

        if (glyph_idx < self.num_h_metrics) {
            const off = @as(usize, glyph_idx) * 4;
            if (off + 4 <= self.hmtx_table.len) {
                const adv = std.mem.readInt(u16, self.hmtx_table[off..][0..2], .big);
                const lsb = std.mem.readInt(i16, self.hmtx_table[off + 2 ..][0..2], .big);
                return .{ .advance_width = adv, .lsb = lsb };
            }
        } else {
            // Beyond numberOfHMetrics: advance width is that of the last entry
            const last_adv_off = @as(usize, self.num_h_metrics - 1) * 4;
            const adv = if (last_adv_off + 2 <= self.hmtx_table.len)
                std.mem.readInt(u16, self.hmtx_table[last_adv_off..][0..2], .big)
            else
                self.units_per_em;

            const lsb_off = @as(usize, self.num_h_metrics) * 4 + @as(usize, glyph_idx - self.num_h_metrics) * 2;
            const lsb = if (lsb_off + 2 <= self.hmtx_table.len)
                std.mem.readInt(i16, self.hmtx_table[lsb_off..][0..2], .big)
            else
                0;

            return .{ .advance_width = adv, .lsb = lsb };
        }

        return .{ .advance_width = self.units_per_em, .lsb = 0 };
    }

    /// Retrieve the byte offset and length in `glyf_table` for a glyph index.
    pub fn glyph_slice(self: *const TrueTypeFace, glyph_idx: u16) Error![]const u8 {
        if (glyph_idx >= self.num_glyphs) return error.InvalidGlyphIndex;

        var offset0: u32 = 0;
        var offset1: u32 = 0;

        if (self.index_to_loc_format == 0) {
            // 16-bit word offsets (offset = value * 2)
            const off = @as(usize, glyph_idx) * 2;
            if (off + 4 > self.loca_table.len) return error.MalformedTable;
            offset0 = @as(u32, std.mem.readInt(u16, self.loca_table[off..][0..2], .big)) * 2;
            offset1 = @as(u32, std.mem.readInt(u16, self.loca_table[off + 2 ..][0..2], .big)) * 2;
        } else {
            // 32-bit byte offsets
            const off = @as(usize, glyph_idx) * 4;
            if (off + 8 > self.loca_table.len) return error.MalformedTable;
            offset0 = std.mem.readInt(u32, self.loca_table[off..][0..4], .big);
            offset1 = std.mem.readInt(u32, self.loca_table[off + 4 ..][0..4], .big);
        }

        if (offset0 == offset1) {
            return &.{}; // Empty glyph (e.g. space)
        }
        if (offset1 > self.glyf_table.len or offset0 > offset1) {
            return error.MalformedTable;
        }

        return self.glyf_table[offset0..offset1];
    }

    /// Measure pixel width of a string at target pixel size.
    pub fn measure_string(self: *const TrueTypeFace, pixel_size: u32, text: []const u8) u32 {
        if (text.len == 0 or self.units_per_em == 0) return 0;

        var total_design_units: u64 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const end = @min(i + cp_len, text.len);
            const cp = std.unicode.utf8Decode(text[i..end]) catch text[i];
            i = end;

            const g_id = self.glyph_index(cp);
            const metrics = self.glyph_metrics(g_id);
            total_design_units += metrics.advance_width;
        }

        return @intCast((total_design_units * pixel_size + (self.units_per_em / 2)) / self.units_per_em);
    }

    pub const Point = struct {
        x: i32,
        y: i32,
        on_curve: bool,
    };

    pub const Outline = struct {
        num_contours: u16,
        x_min: i16,
        y_min: i16,
        x_max: i16,
        y_max: i16,
        points: []Point,
        contour_ends: []u16,
    };

    /// Parse a glyph outline (simple or composite) into provided point and contour buffers.
    pub fn load_glyph_outline(
        self: *const TrueTypeFace,
        glyph_idx: u16,
        pts_buf: []Point,
        ends_buf: []u16,
    ) Error!Outline {
        const raw = try self.glyph_slice(glyph_idx);
        if (raw.len == 0) {
            return Outline{
                .num_contours = 0,
                .x_min = 0,
                .y_min = 0,
                .x_max = 0,
                .y_max = 0,
                .points = pts_buf[0..0],
                .contour_ends = ends_buf[0..0],
            };
        }
        if (raw.len < 10) return error.MalformedTable;

        const num_contours = std.mem.readInt(i16, raw[0..2], .big);
        const x_min = std.mem.readInt(i16, raw[2..4], .big);
        const y_min = std.mem.readInt(i16, raw[4..6], .big);
        const x_max = std.mem.readInt(i16, raw[6..8], .big);
        const y_max = std.mem.readInt(i16, raw[8..10], .big);

        if (num_contours < 0) {
            // Composite glyph!
            var stream_idx: usize = 10;
            var more_components = true;
            var total_pts: usize = 0;
            var total_contours: usize = 0;

            while (more_components) {
                if (stream_idx + 4 > raw.len) return error.MalformedTable;
                const flags = std.mem.readInt(u16, raw[stream_idx..][0..2], .big);
                const component_glyph_idx = std.mem.readInt(u16, raw[stream_idx + 2 ..][0..2], .big);
                stream_idx += 4;

                var dx: i32 = 0;
                var dy: i32 = 0;

                const ARG_1_AND_2_ARE_WORDS: u16 = 0x0001;
                const ARGS_ARE_XY_VALUES: u16 = 0x0002;
                const WE_HAVE_A_SCALE: u16 = 0x0008;
                const MORE_COMPONENTS: u16 = 0x0020;
                const WE_HAVE_AN_X_AND_Y_SCALE: u16 = 0x0040;
                const WE_HAVE_A_TWO_BY_TWO: u16 = 0x0080;

                if ((flags & ARG_1_AND_2_ARE_WORDS) != 0) {
                    if (stream_idx + 4 > raw.len) return error.MalformedTable;
                    const arg1 = std.mem.readInt(i16, raw[stream_idx..][0..2], .big);
                    const arg2 = std.mem.readInt(i16, raw[stream_idx + 2 ..][0..2], .big);
                    stream_idx += 4;
                    if ((flags & ARGS_ARE_XY_VALUES) != 0) {
                        dx = arg1;
                        dy = arg2;
                    }
                } else {
                    if (stream_idx + 2 > raw.len) return error.MalformedTable;
                    const arg1 = @as(i8, @bitCast(raw[stream_idx]));
                    const arg2 = @as(i8, @bitCast(raw[stream_idx + 1]));
                    stream_idx += 2;
                    if ((flags & ARGS_ARE_XY_VALUES) != 0) {
                        dx = arg1;
                        dy = arg2;
                    }
                }

                if ((flags & WE_HAVE_A_SCALE) != 0) {
                    stream_idx += 2;
                } else if ((flags & WE_HAVE_AN_X_AND_Y_SCALE) != 0) {
                    stream_idx += 4;
                } else if ((flags & WE_HAVE_A_TWO_BY_TWO) != 0) {
                    stream_idx += 8;
                }

                const comp_outline = try self.load_glyph_outline(component_glyph_idx, &scratch_comp_pts, &scratch_comp_ends);

                const pts_base = total_pts;
                for (comp_outline.points) |p| {
                    if (total_pts >= pts_buf.len) return error.BufferTooSmall;
                    pts_buf[total_pts] = .{
                        .x = p.x + dx,
                        .y = p.y + dy,
                        .on_curve = p.on_curve,
                    };
                    total_pts += 1;
                }

                for (comp_outline.contour_ends) |end| {
                    if (total_contours >= ends_buf.len) return error.BufferTooSmall;
                    ends_buf[total_contours] = @intCast(pts_base + end);
                    total_contours += 1;
                }

                more_components = (flags & MORE_COMPONENTS) != 0;
            }

            return Outline{
                .num_contours = @intCast(total_contours),
                .x_min = x_min,
                .y_min = y_min,
                .x_max = x_max,
                .y_max = y_max,
                .points = pts_buf[0..total_pts],
                .contour_ends = ends_buf[0..total_contours],
            };
        }

        if (num_contours == 0) {
            return Outline{
                .num_contours = 0,
                .x_min = x_min,
                .y_min = y_min,
                .x_max = x_max,
                .y_max = y_max,
                .points = pts_buf[0..0],
                .contour_ends = ends_buf[0..0],
            };
        }

        const nc: usize = @intCast(num_contours);
        if (nc > ends_buf.len) return error.BufferTooSmall;
        if (10 + nc * 2 > raw.len) return error.MalformedTable;

        var i: usize = 0;
        while (i < nc) : (i += 1) {
            ends_buf[i] = std.mem.readInt(u16, raw[10 + i * 2 ..][0..2], .big);
        }

        const num_points: usize = @as(usize, ends_buf[nc - 1]) + 1;
        if (num_points > pts_buf.len) return error.BufferTooSmall;

        const inst_len_off = 10 + nc * 2;
        if (inst_len_off + 2 > raw.len) return error.MalformedTable;
        const inst_len = std.mem.readInt(u16, raw[inst_len_off..][0..2], .big);

        var stream_idx = inst_len_off + 2 + @as(usize, inst_len);

        // Read flags
        var flags_buf: [1024]u8 = undefined;
        if (num_points > flags_buf.len) return error.BufferTooSmall;

        var p: usize = 0;
        while (p < num_points) {
            if (stream_idx >= raw.len) return error.MalformedTable;
            const flag = raw[stream_idx];
            stream_idx += 1;
            flags_buf[p] = flag;
            p += 1;

            if ((flag & 0x08) != 0) { // REPEAT_FLAG
                if (stream_idx >= raw.len) return error.MalformedTable;
                const repeat = raw[stream_idx];
                stream_idx += 1;
                var r: usize = 0;
                while (r < repeat and p < num_points) : (r += 1) {
                    flags_buf[p] = flag;
                    p += 1;
                }
            }
        }

        // Read X coordinates
        var cur_x: i32 = 0;
        for (0..num_points) |idx| {
            const flag = flags_buf[idx];
            if ((flag & 0x02) != 0) { // X_SHORT_VECTOR
                if (stream_idx >= raw.len) return error.MalformedTable;
                const b = raw[stream_idx];
                stream_idx += 1;
                const dx: i32 = if ((flag & 0x10) != 0) @as(i32, b) else -@as(i32, b);
                cur_x += dx;
            } else {
                if ((flag & 0x10) != 0) {
                    // Same as previous X
                } else {
                    if (stream_idx + 2 > raw.len) return error.MalformedTable;
                    const dx = std.mem.readInt(i16, raw[stream_idx..][0..2], .big);
                    stream_idx += 2;
                    cur_x += dx;
                }
            }
            pts_buf[idx].x = cur_x;
            pts_buf[idx].on_curve = (flag & 0x01) != 0;
        }

        // Read Y coordinates
        var cur_y: i32 = 0;
        for (0..num_points) |idx| {
            const flag = flags_buf[idx];
            if ((flag & 0x04) != 0) { // Y_SHORT_VECTOR
                if (stream_idx >= raw.len) return error.MalformedTable;
                const b = raw[stream_idx];
                stream_idx += 1;
                const dy: i32 = if ((flag & 0x20) != 0) @as(i32, b) else -@as(i32, b);
                cur_y += dy;
            } else {
                if ((flag & 0x20) != 0) {
                    // Same as previous Y
                } else {
                    if (stream_idx + 2 > raw.len) return error.MalformedTable;
                    const dy = std.mem.readInt(i16, raw[stream_idx..][0..2], .big);
                    stream_idx += 2;
                    cur_y += dy;
                }
            }
            pts_buf[idx].y = cur_y;
        }

        return Outline{
            .num_contours = @intCast(nc),
            .x_min = x_min,
            .y_min = y_min,
            .x_max = x_max,
            .y_max = y_max,
            .points = pts_buf[0..num_points],
            .contour_ends = ends_buf[0..nc],
        };
    }

    pub const load_simple_glyph = load_glyph_outline;

    pub const LineSegment = struct {
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
    };

    pub const RasterizedGlyph = struct {
        width: u32,
        height: u32,
        bearing_x: i32,
        bearing_y: i32,
        advance_width: u32,
        alpha: []u8,
    };

    fn flatten_quad_bezier(
        p0: Point,
        p1: Point,
        p2: Point,
        segs: []LineSegment,
        seg_count: *usize,
    ) void {
        const x0: i64 = p0.x;
        const y0: i64 = p0.y;
        const x1: i64 = p1.x;
        const y1: i64 = p1.y;
        const x2: i64 = p2.x;
        const y2: i64 = p2.y;

        // 4-step subdivision using integer Bernstein weights
        // t = 1/4: (9*P0 + 6*P1 + P2) / 16
        const pt1_x: i32 = @intCast(@divTrunc(9 * x0 + 6 * x1 + x2 + 8, 16));
        const pt1_y: i32 = @intCast(@divTrunc(9 * y0 + 6 * y1 + y2 + 8, 16));

        // t = 2/4: (4*P0 + 8*P1 + 4*P2) / 16
        const pt2_x: i32 = @intCast(@divTrunc(4 * x0 + 8 * x1 + 4 * x2 + 8, 16));
        const pt2_y: i32 = @intCast(@divTrunc(4 * y0 + 8 * y1 + 4 * y2 + 8, 16));

        // t = 3/4: (P0 + 6*P1 + 9*P2) / 16
        const pt3_x: i32 = @intCast(@divTrunc(x0 + 6 * x1 + 9 * x2 + 8, 16));
        const pt3_y: i32 = @intCast(@divTrunc(y0 + 6 * y1 + 9 * y2 + 8, 16));

        const pts = [5]Point{
            p0,
            .{ .x = pt1_x, .y = pt1_y, .on_curve = true },
            .{ .x = pt2_x, .y = pt2_y, .on_curve = true },
            .{ .x = pt3_x, .y = pt3_y, .on_curve = true },
            p2,
        };

        for (0..4) |s| {
            if (seg_count.* < segs.len) {
                segs[seg_count.*] = .{
                    .x0 = pts[s].x,
                    .y0 = pts[s].y,
                    .x1 = pts[s + 1].x,
                    .y1 = pts[s + 1].y,
                };
                seg_count.* += 1;
            }
        }
    }

    /// Decompose outline into straight line segments by flattening curves.
    pub fn decompose_outline(
        outline: Outline,
        segs_buf: []LineSegment,
    ) []LineSegment {
        if (outline.num_contours == 0 or outline.points.len == 0) return segs_buf[0..0];

        var seg_count: usize = 0;
        var start_idx: usize = 0;

        for (0..outline.num_contours) |c| {
            const end_idx = outline.contour_ends[c];
            if (end_idx >= outline.points.len or end_idx < start_idx) break;

            const slice = outline.points[start_idx .. end_idx + 1];
            start_idx = end_idx + 1;
            if (slice.len < 2) continue;

            const count = slice.len;

            // Determine start point of contour loop
            var start_pt: Point = undefined;
            if (slice[0].on_curve) {
                start_pt = slice[0];
            } else if (slice[count - 1].on_curve) {
                start_pt = slice[count - 1];
            } else {
                start_pt = Point{
                    .x = @divTrunc(slice[0].x + slice[count - 1].x, 2),
                    .y = @divTrunc(slice[0].y + slice[count - 1].y, 2),
                    .on_curve = true,
                };
            }

            var curr = start_pt;
            var i: usize = 0;
            while (i < count) {
                const pt = slice[i];
                if (pt.on_curve) {
                    if (curr.x != pt.x or curr.y != pt.y) {
                        if (seg_count < segs_buf.len) {
                            segs_buf[seg_count] = .{ .x0 = curr.x, .y0 = curr.y, .x1 = pt.x, .y1 = pt.y };
                            seg_count += 1;
                        }
                    }
                    curr = pt;
                    i += 1;
                } else {
                    const ctrl = pt;
                    const next_idx = (i + 1) % count;
                    const next_pt = slice[next_idx];
                    var dest: Point = undefined;

                    if (next_pt.on_curve) {
                        dest = next_pt;
                        i += 2;
                    } else {
                        dest = Point{
                            .x = @divTrunc(ctrl.x + next_pt.x, 2),
                            .y = @divTrunc(ctrl.y + next_pt.y, 2),
                            .on_curve = true,
                        };
                        i += 1;
                    }

                    flatten_quad_bezier(curr, ctrl, dest, segs_buf, &seg_count);
                    curr = dest;
                }
            }

            // Close back to start_pt
            if (curr.x != start_pt.x or curr.y != start_pt.y) {
                if (seg_count < segs_buf.len) {
                    segs_buf[seg_count] = .{ .x0 = curr.x, .y0 = curr.y, .x1 = start_pt.x, .y1 = start_pt.y };
                    seg_count += 1;
                }
            }
        }

        return segs_buf[0..seg_count];
    }

    /// Rasterize glyph outline to an 8-bit anti-aliased alpha mask using scanline coverage.
    pub fn rasterize_outline(
        self: *const TrueTypeFace,
        outline: Outline,
        glyph_idx: u16,
        pixel_size: u32,
        alpha_buf: []u8,
        segs_scratch: []LineSegment,
    ) Error!RasterizedGlyph {
        const metrics = self.glyph_metrics(glyph_idx);
        const adv_px = (metrics.advance_width * pixel_size + self.units_per_em / 2) / self.units_per_em;

        if (outline.num_contours == 0 or outline.x_max <= outline.x_min or outline.y_max <= outline.y_min) {
            return RasterizedGlyph{
                .width = 0,
                .height = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .advance_width = adv_px,
                .alpha = alpha_buf[0..0],
            };
        }

        const segments = decompose_outline(outline, segs_scratch);

        // Dimensions at target pixel size
        const upm: i64 = self.units_per_em;
        const ps: i64 = pixel_size;

        const w_px: u32 = @intCast(@max(1, @divTrunc(@as(i64, outline.x_max - outline.x_min) * ps + upm - 1, upm) + 1));
        const h_px: u32 = @intCast(@max(1, @divTrunc(@as(i64, outline.y_max - outline.y_min) * ps + upm - 1, upm) + 1));

        if (@as(usize, w_px) * @as(usize, h_px) > alpha_buf.len) return error.BufferTooSmall;

        const bearing_x: i32 = @intCast(@divTrunc(@as(i64, outline.x_min) * ps, upm));
        const bearing_y: i32 = @intCast(@divTrunc(@as(i64, outline.y_max) * ps, upm));

        // Subpixel multiplier (4x supersampling)
        const sub_mult: i64 = 4;
        const x_min_base: i64 = outline.x_min;
        const y_max_base: i64 = outline.y_max;

        // Scale segments to 4x subpixel coordinate space
        const scaled_segs = &scratch_scaled_segs;
        const seg_count = @min(segments.len, scaled_segs.len);

        for (0..seg_count) |s| {
            const seg = segments[s];
            // X relative to x_min (positive going right)
            const sx0: i32 = @intCast(@divTrunc((@as(i64, seg.x0) - x_min_base) * ps * sub_mult, upm));
            const sx1: i32 = @intCast(@divTrunc((@as(i64, seg.x1) - x_min_base) * ps * sub_mult, upm));

            // Y relative to y_max (positive going DOWN in screen coordinates)
            const sy0: i32 = @intCast(@divTrunc((y_max_base - @as(i64, seg.y0)) * ps * sub_mult, upm));
            const sy1: i32 = @intCast(@divTrunc((y_max_base - @as(i64, seg.y1)) * ps * sub_mult, upm));

            scaled_segs[s] = .{ .x0 = sx0, .y0 = sy0, .x1 = sx1, .y1 = sy1 };
        }

        // Initialize subpixel coverage accumulator
        const total_pixels = @as(usize, w_px) * @as(usize, h_px);
        if (total_pixels > scratch_sub_accum.len) return error.BufferTooSmall;
        const sub_accum = &scratch_sub_accum;
        @memset(sub_accum[0..total_pixels], 0);

        const sub_h = @as(i32, @intCast(h_px)) * 4;
        const sub_w = @as(i32, @intCast(w_px)) * 4;

        // Scanline loop over all subpixel rows (sample at half-subpixel y = sub_y + 0.5)
        var sub_y: i32 = 0;
        while (sub_y < sub_h) : (sub_y += 1) {
            // Half-subpixel center scaled by 2: odd number 2*sub_y + 1
            const y_mid = sub_y * 2 + 1;
            var crosses: [64]i32 = undefined;
            var cross_count: usize = 0;

            for (0..seg_count) |s| {
                const seg = scaled_segs[s];
                const y0_2 = seg.y0 * 2;
                const y1_2 = seg.y1 * 2;
                const min_y = @min(y0_2, y1_2);
                const max_y = @max(y0_2, y1_2);

                if (y_mid > min_y and y_mid < max_y) {
                    // Compute X intersection at half-integer y
                    const dy: i64 = y1_2 - y0_2;
                    const dx: i64 = seg.x1 - seg.x0;
                    const x_cross: i32 = @intCast(seg.x0 + @divFloor((@as(i64, y_mid - y0_2) * dx), dy));

                    if (cross_count < crosses.len) {
                        crosses[cross_count] = x_cross;
                        cross_count += 1;
                    }
                }
            }

            if (cross_count < 2) continue;

            // Sort crossings in ascending order (insertion sort for small array)
            var k: usize = 1;
            while (k < cross_count) : (k += 1) {
                var j = k;
                while (j > 0 and crosses[j - 1] > crosses[j]) : (j -= 1) {
                    const tmp = crosses[j];
                    crosses[j] = crosses[j - 1];
                    crosses[j - 1] = tmp;
                }
            }

            // Fill spans between pairs (even-odd rule)
            const py: usize = @intCast(@divTrunc(sub_y, 4));
            var pair: usize = 0;
            while (pair + 1 < cross_count) : (pair += 2) {
                const x_start = @max(0, @min(sub_w, crosses[pair]));
                const x_end = @max(0, @min(sub_w, crosses[pair + 1]));

                var sx = x_start;
                while (sx < x_end) : (sx += 1) {
                    const px: usize = @intCast(@divTrunc(sx, 4));
                    if (px < w_px and py < h_px) {
                        sub_accum[py * w_px + px] += 1;
                    }
                }
            }
        }

        // Convert accumulator to 8-bit alpha (16 subpixels per pixel -> scale by 16)
        for (0..total_pixels) |idx| {
            const val = @as(u32, sub_accum[idx]) * 16;
            alpha_buf[idx] = @intCast(@min(255, val));
        }

        return RasterizedGlyph{
            .width = w_px,
            .height = h_px,
            .bearing_x = bearing_x,
            .bearing_y = bearing_y,
            .advance_width = adv_px,
            .alpha = alpha_buf[0..total_pixels],
        };
    }

    pub const CachedGlyph = struct {
        valid: bool,
        width: u16,
        height: u16,
        bearing_x: i16,
        bearing_y: i16,
        advance_width: u16,
        alpha_offset: u32,
    };

    pub const GlyphCache = struct {
        // Fast direct cache for ASCII 0x20..0x7E
        ascii_entries: [95]CachedGlyph = @splat(@as(CachedGlyph, .{
            .valid = false,
            .width = 0,
            .height = 0,
            .bearing_x = 0,
            .bearing_y = 0,
            .advance_width = 0,
            .alpha_offset = 0,
        })),
        alpha_storage: [32768]u8 = @as([32768]u8, @splat(@as(u8, 0))),
        storage_used: usize = 0,

        pub fn get_or_render(
            self: *GlyphCache,
            face: *const TrueTypeFace,
            cp: u32,
            pixel_size: u32,
        ) ?CachedGlyph {
            if (cp >= 0x20 and cp <= 0x7E) {
                const idx = cp - 0x20;
                if (self.ascii_entries[idx].valid) {
                    return self.ascii_entries[idx];
                }

                // Render on demand
                const g_idx = face.glyph_index(cp);
                const outline = face.load_glyph_outline(g_idx, &scratch_pts, &scratch_ends) catch return null;

                const remaining = self.alpha_storage.len - self.storage_used;
                if (remaining == 0) return null;

                const raster = face.rasterize_outline(
                    outline,
                    g_idx,
                    pixel_size,
                    self.alpha_storage[self.storage_used..],
                    &scratch_segs,
                ) catch return null;

                const entry = CachedGlyph{
                    .valid = true,
                    .width = @intCast(raster.width),
                    .height = @intCast(raster.height),
                    .bearing_x = @intCast(raster.bearing_x),
                    .bearing_y = @intCast(raster.bearing_y),
                    .advance_width = @intCast(raster.advance_width),
                    .alpha_offset = @intCast(self.storage_used),
                };

                self.storage_used += raster.alpha.len;
                self.ascii_entries[idx] = entry;
                return entry;
            }
            return null;
        }

        pub fn glyph_alpha(self: *const GlyphCache, entry: CachedGlyph) []const u8 {
            const end = entry.alpha_offset + @as(usize, entry.width) * @as(usize, entry.height);
            if (end <= self.alpha_storage.len) {
                return self.alpha_storage[entry.alpha_offset..end];
            }
            return &.{};
        }
    };

    /// Alpha-blend a glyph into a 32-bpp BGRA buffer.
    pub fn blend_glyph_bgra(
        dest_buf: []u32,
        dest_stride: usize,
        dest_w: usize,
        dest_h: usize,
        x: i32,
        y: i32,
        glyph_w: usize,
        glyph_h: usize,
        alpha_mask: []const u8,
        fg_rgb: u32,
    ) void {
        const src_b: u32 = fg_rgb & 0xFF;
        const src_g: u32 = (fg_rgb >> 8) & 0xFF;
        const src_r: u32 = (fg_rgb >> 16) & 0xFF;

        for (0..glyph_h) |gy| {
            const dy = y + @as(i32, @intCast(gy));
            if (dy < 0 or dy >= dest_h) continue;
            const row_offset = @as(usize, @intCast(dy)) * dest_stride;

            for (0..glyph_w) |gx| {
                const dx = x + @as(i32, @intCast(gx));
                if (dx < 0 or dx >= dest_w) continue;

                const mask_idx = gy * glyph_w + gx;
                if (mask_idx >= alpha_mask.len) break;
                const a = alpha_mask[mask_idx];
                if (a == 0) continue;

                const px_idx = row_offset + @as(usize, @intCast(dx));
                if (px_idx >= dest_buf.len) continue;

                if (a == 255) {
                    dest_buf[px_idx] = (fg_rgb & 0x00FFFFFF) | 0xFF000000;
                } else {
                    const dst_val = dest_buf[px_idx];
                    const dst_b = dst_val & 0xFF;
                    const dst_g = (dst_val >> 8) & 0xFF;
                    const dst_r = (dst_val >> 16) & 0xFF;
                    const inv_a: u32 = 255 - a;

                    const out_b = (src_b * a + dst_b * inv_a + 128) / 255;
                    const out_g = (src_g * a + dst_g * inv_a + 128) / 255;
                    const out_r = (src_r * a + dst_r * inv_a + 128) / 255;

                    dest_buf[px_idx] = out_b | (out_g << 8) | (out_r << 16) | 0xFF000000;
                }
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

/// The four faces vendored under image/fonts/ (ADR 0028 amendment B). A missing
/// file fails the test — there is no FONTS-CHOOSE/ fallback that would hide it.
fn load_test_font(io: anytype, name: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const path: []const u8 = if (std.mem.eql(u8, name, "inter"))
        "image/fonts/Inter-Regular.ttf"
    else if (std.mem.eql(u8, name, "inter-bold"))
        "image/fonts/Inter-Bold.ttf"
    else if (std.mem.eql(u8, name, "inter-italic"))
        "image/fonts/Inter-Italic.ttf"
    else if (std.mem.eql(u8, name, "fira"))
        "image/fonts/FiraCode-Regular.ttf"
    else
        return error.UnknownFont;
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(2 * 1024 * 1024));
}

test "TrueTypeFace opens the four vendored faces" {
    const allocator = std.testing.allocator;
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();

    const names = [_][]const u8{ "inter", "inter-bold", "inter-italic", "fira" };
    const want_upem = [_]u16{ 2048, 2048, 2048, 1950 };
    for (names, want_upem) |name, upem| {
        const data = try load_test_font(io, name, allocator);
        defer allocator.free(data);
        const face = try TrueTypeFace.init(data);
        try std.testing.expectEqual(upem, face.units_per_em);
        try std.testing.expect(face.num_glyphs > 100);
        try std.testing.expect(face.glyph_index('A') > 0);
        try std.testing.expect(face.glyph_index('n') > 0);
    }
}

test "TrueTypeFace parses Fira Code and Inter headers and cmap" {
    const allocator = std.testing.allocator;
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();

    // Load Fira Code
    const fira_data = try load_test_font(io, "fira", allocator);
    defer allocator.free(fira_data);
    const fira = try TrueTypeFace.init(fira_data);

    try std.testing.expectEqual(@as(u16, 1950), fira.units_per_em);
    try std.testing.expectEqual(@as(i16, 1), fira.index_to_loc_format);
    try std.testing.expectEqual(@as(u16, 2030), fira.num_glyphs);

    // Test codepoint mapping in Fira Code
    const fira_a = fira.glyph_index('A');
    try std.testing.expect(fira_a > 0);
    const fira_metrics_a = fira.glyph_metrics(fira_a);
    // Fira Code is monospaced: advance_width is 1200 design units (1200 / 1950 = ~0.615 aspect ratio)
    try std.testing.expectEqual(@as(u16, 1200), fira_metrics_a.advance_width);

    // Test codepoint mapping in Inter
    const inter_data = try load_test_font(io, "inter", allocator);
    defer allocator.free(inter_data);
    const inter = try TrueTypeFace.init(inter_data);

    try std.testing.expectEqual(@as(u16, 2048), inter.units_per_em);
    try std.testing.expectEqual(@as(i16, 1), inter.index_to_loc_format);
    try std.testing.expectEqual(@as(u16, 2937), inter.num_glyphs);

    const inter_i = inter.glyph_index('i');
    const inter_m = inter.glyph_index('m');
    try std.testing.expect(inter_i > 0);
    try std.testing.expect(inter_m > 0);

    const metrics_i = inter.glyph_metrics(inter_i);
    const metrics_m = inter.glyph_metrics(inter_m);
    // Inter is proportional: 'm' must be significantly wider than 'i'
    try std.testing.expect(metrics_m.advance_width > metrics_i.advance_width * 2);

    // Test string measurement
    const width_mono = fira.measure_string(15, "Hello, World!");
    const width_prop = inter.measure_string(15, "Hello, World!");
    try std.testing.expect(width_mono > 0);
    try std.testing.expect(width_prop > 0);

    // Empty string measures 0
    try std.testing.expectEqual(@as(u32, 0), inter.measure_string(15, ""));
}

test "TrueTypeFace loads simple glyph outlines" {
    const allocator = std.testing.allocator;
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();

    const fira_data = try load_test_font(io, "fira", allocator);
    defer allocator.free(fira_data);
    const fira = try TrueTypeFace.init(fira_data);

    var pts: [512]TrueTypeFace.Point = undefined;
    var ends: [16]u16 = undefined;

    // 'A' in Fira Code
    const fira_a = fira.glyph_index('A');
    const outline_a = try fira.load_simple_glyph(fira_a, &pts, &ends);

    // 'A' has 2 contours (outer triangle, inner hole)
    try std.testing.expectEqual(@as(u16, 2), outline_a.num_contours);
    try std.testing.expect(outline_a.points.len > 10);
    try std.testing.expect(outline_a.y_max > outline_a.y_min);
    try std.testing.expect(outline_a.x_max > outline_a.x_min);

    // 'O' in Inter
    const inter_data = try load_test_font(io, "inter", allocator);
    defer allocator.free(inter_data);
    const inter = try TrueTypeFace.init(inter_data);

    const inter_o = inter.glyph_index('O');
    const outline_o = try inter.load_simple_glyph(inter_o, &pts, &ends);

    // 'O' has 2 contours (outer ellipse, inner hole)
    try std.testing.expectEqual(@as(u16, 2), outline_o.num_contours);
    try std.testing.expect(outline_o.points.len > 10);
}

test "TrueTypeFace rasterizes anti-aliased glyphs with subpixel coverage" {
    const allocator = std.testing.allocator;
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();

    const inter_data = try load_test_font(io, "inter", allocator);
    defer allocator.free(inter_data);
    const inter = try TrueTypeFace.init(inter_data);

    var pts: [512]TrueTypeFace.Point = undefined;
    var ends: [16]u16 = undefined;
    var alpha_o: [1024]u8 = undefined;
    var alpha_a: [1024]u8 = undefined;
    var segs_scratch: [1024]TrueTypeFace.LineSegment = undefined;

    // Rasterize 'O' at 16px
    const glyph_o = inter.glyph_index('O');
    const outline_o = try inter.load_simple_glyph(glyph_o, &pts, &ends);

    const raster_o = try inter.rasterize_outline(outline_o, glyph_o, 16, &alpha_o, &segs_scratch);

    try std.testing.expect(raster_o.width > 5);
    try std.testing.expect(raster_o.height > 5);

    // Verify presence of anti-aliasing (intermediate alpha values between 1 and 254)
    var has_solid = false;
    var has_antialiased = false;
    for (raster_o.alpha) |a| {
        if (a == 255) has_solid = true;
        if (a > 0 and a < 255) has_antialiased = true;
    }

    try std.testing.expect(has_solid);
    try std.testing.expect(has_antialiased);

    // Rasterize Fira Code 'A' at 14px
    const fira_data = try load_test_font(io, "fira", allocator);
    defer allocator.free(fira_data);
    const fira = try TrueTypeFace.init(fira_data);

    const glyph_a = fira.glyph_index('A');
    const outline_a = try fira.load_simple_glyph(glyph_a, &pts, &ends);
    const raster_a = try fira.rasterize_outline(outline_a, glyph_a, 14, &alpha_a, &segs_scratch);

    try std.testing.expect(raster_a.width > 5);
    try std.testing.expect(raster_a.height > 5);
    try std.testing.expectEqual(@as(u32, 9), raster_a.advance_width); // 1200 * 14 / 1950 ≈ 8.6 -> 9px

    // Print ASCII art of 'O' and 'A' to stdout
    const shades = " .:-=+*#%@";
    std.debug.print("\n--- Rasterized Inter 'O' (16px, {d}x{d}, advance={d}px) ---\n", .{ raster_o.width, raster_o.height, raster_o.advance_width });
    for (0..raster_o.height) |y| {
        for (0..raster_o.width) |x| {
            const a = raster_o.alpha[y * raster_o.width + x];
            const idx = (@as(usize, a) * (shades.len - 1)) / 255;
            std.debug.print("{c}", .{shades[idx]});
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("\n--- Rasterized Fira Code 'A' (14px, {d}x{d}) ---\n", .{ raster_a.width, raster_a.height });
    for (0..raster_a.height) |y| {
        for (0..raster_a.width) |x| {
            const a = raster_a.alpha[y * raster_a.width + x];
            const idx = (@as(usize, a) * (shades.len - 1)) / 255;
            std.debug.print("{c}", .{shades[idx]});
        }
        std.debug.print("\n", .{});
    }
}

test "TrueTypeFace loads and rasterizes composite glyphs (accented é)" {
    const allocator = std.testing.allocator;
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();

    const inter_data = try load_test_font(io, "inter", allocator);
    defer allocator.free(inter_data);
    const inter = try TrueTypeFace.init(inter_data);

    var pts: [512]TrueTypeFace.Point = undefined;
    var ends: [16]u16 = undefined;
    var alpha: [1024]u8 = undefined;
    var segs_scratch: [1024]TrueTypeFace.LineSegment = undefined;

    // 'é' (U+00E9) in Inter is composite (base 'e' + acute accent)
    const glyph_e_acute = inter.glyph_index(0x00E9);
    try std.testing.expect(glyph_e_acute > 0);

    const outline_e = try inter.load_glyph_outline(glyph_e_acute, &pts, &ends);
    // Composite glyph 'é' has contours for 'e' (inner + outer) PLUS acute accent contour
    try std.testing.expect(outline_e.num_contours >= 3);
    try std.testing.expect(outline_e.points.len > 20);

    const raster_e = try inter.rasterize_outline(outline_e, glyph_e_acute, 16, &alpha, &segs_scratch);
    try std.testing.expect(raster_e.width > 5);
    try std.testing.expect(raster_e.height > 8);
}

test "GlyphCache and blend_glyph_bgra render text into 32-bpp BGRA buffer" {
    const allocator = std.testing.allocator;
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();

    const inter_data = try load_test_font(io, "inter", allocator);
    defer allocator.free(inter_data);
    const inter = try TrueTypeFace.init(inter_data);

    var cache = TrueTypeFace.GlyphCache{};

    // Allocate a 120x30 32-bpp BGRA destination surface filled with dark slate (0x101418)
    const buf_w: usize = 120;
    const buf_h: usize = 30;
    var screen_buf = @as([(buf_w * buf_h)]u32, @splat(@as(u32, 0xFF101418)));

    const text = "Virelai";
    var cur_x: i32 = 8;
    const baseline_y: i32 = 20;
    const fg_color: u32 = 0x0000FF00; // Bright green text

    for (text) |ch| {
        const entry = cache.get_or_render(&inter, ch, 16) orelse continue;
        const alpha = cache.glyph_alpha(entry);

        TrueTypeFace.blend_glyph_bgra(
            &screen_buf,
            buf_w,
            buf_w,
            buf_h,
            cur_x + entry.bearing_x,
            baseline_y - entry.bearing_y,
            entry.width,
            entry.height,
            alpha,
            fg_color,
        );

        cur_x += entry.advance_width;
    }

    // Verify cache has stored entries
    try std.testing.expect(cache.storage_used > 0);
    const initial_storage = cache.storage_used;

    // Render same string again: 100% cache hit, storage_used should not change
    for (text) |ch| {
        _ = cache.get_or_render(&inter, ch, 16);
    }
    try std.testing.expectEqual(initial_storage, cache.storage_used);

    // Verify pixels in buffer: must contain non-background pixels and blended anti-aliased values
    var num_modified: usize = 0;
    var num_blended: usize = 0;
    for (screen_buf) |px| {
        if (px != 0xFF101418) {
            num_modified += 1;
            // Check if green channel has intermediate value (blended between 0x14 and 0xFF)
            const g = (px >> 8) & 0xFF;
            if (g > 0x14 and g < 0xFF) {
                num_blended += 1;
            }
        }
    }

    try std.testing.expect(num_modified > 50);
    try std.testing.expect(num_blended > 20);
}
