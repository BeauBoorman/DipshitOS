//! VirelaiOS Freestanding QOI (Quite OK Image) Decoder.
//!
//! Milestone 23 / Issue #822 (IMG1).
//! Freestanding, single-pass sequential decoder with zero heap allocation.
//! Decodes directly into caller-provided 32-bpp B8G8R8X8_UNORM destination buffers.

const std = @import("std");

pub const DecodeError = error{
    HeaderMagic, // first 4 bytes != "qoif"
    TruncatedInput, // stream ends before expected pixel count or end marker
    BufferTooSmall, // destination buffer cannot hold width * height pixels
    EndMarkerMissing, // 8-byte end marker not found at expected position
    InvalidDimensions, // width == 0 or height == 0
};

pub const QoiHeader = struct {
    width: u32,
    height: u32,
    channels: u8,
    colorspace: u8,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub inline fn hash(self: Color) usize {
        const h: usize = @as(usize, self.r) * 3 +
            @as(usize, self.g) * 5 +
            @as(usize, self.b) * 7 +
            @as(usize, self.a) * 11;
        return h % 64;
    }

    pub inline fn to_u32(self: Color) u32 {
        // Little-endian word format: (A << 24) | (R << 16) | (G << 8) | B
        // Memory bytes: [B, G, R, A]
        return (@as(u32, self.a) << 24) |
            (@as(u32, self.r) << 16) |
            (@as(u32, self.g) << 8) |
            @as(u32, self.b);
    }
};

/// Parse the 14-byte QOI header.
pub fn parse_header(bytes: []const u8) DecodeError!QoiHeader {
    if (bytes.len < 14) return error.TruncatedInput;
    if (!std.mem.eql(u8, bytes[0..4], "qoif")) return error.HeaderMagic;

    const width = std.mem.readInt(u32, bytes[4..8], .big);
    const height = std.mem.readInt(u32, bytes[8..12], .big);
    if (width == 0 or height == 0) return error.InvalidDimensions;

    return QoiHeader{
        .width = width,
        .height = height,
        .channels = bytes[12],
        .colorspace = bytes[13],
    };
}

/// Decode a QOI stream into a caller-provided destination slice of 32-bit B8G8R8X8 pixels.
pub fn decode(bytes: []const u8, out_pixels: []align(1) u32) DecodeError!QoiHeader {
    const header = try parse_header(bytes);
    const total_pixels: u64 = @as(u64, header.width) * @as(u64, header.height);
    if (out_pixels.len < total_pixels) return error.BufferTooSmall;

    var index = @as([64]Color, @splat(@as(Color, .{ .r = 0, .g = 0, .b = 0, .a = 0 })));
    var current = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };

    var in_pos: usize = 14;
    var px_pos: usize = 0;

    while (px_pos < total_pixels and in_pos < bytes.len) {
        const b1 = bytes[in_pos];
        in_pos += 1;

        if (b1 == 0xFE) { // QOI_OP_RGB
            if (in_pos + 3 > bytes.len) return error.TruncatedInput;
            current.r = bytes[in_pos];
            current.g = bytes[in_pos + 1];
            current.b = bytes[in_pos + 2];
            in_pos += 3;
            index[current.hash()] = current;
            out_pixels[px_pos] = current.to_u32();
            px_pos += 1;
        } else if (b1 == 0xFF) { // QOI_OP_RGBA
            if (in_pos + 4 > bytes.len) return error.TruncatedInput;
            current.r = bytes[in_pos];
            current.g = bytes[in_pos + 1];
            current.b = bytes[in_pos + 2];
            current.a = bytes[in_pos + 3];
            in_pos += 4;
            index[current.hash()] = current;
            out_pixels[px_pos] = current.to_u32();
            px_pos += 1;
        } else {
            const tag = b1 & 0xC0;
            if (tag == 0x00) { // QOI_OP_INDEX
                const idx = b1 & 0x3F;
                current = index[idx];
                out_pixels[px_pos] = current.to_u32();
                px_pos += 1;
            } else if (tag == 0x40) { // QOI_OP_DIFF
                const dr: i8 = @as(i8, @intCast((b1 >> 4) & 0x03)) - 2;
                const dg: i8 = @as(i8, @intCast((b1 >> 2) & 0x03)) - 2;
                const db: i8 = @as(i8, @intCast(b1 & 0x03)) - 2;
                current.r = @truncate(@as(u16, current.r) +% @as(u16, @bitCast(@as(i16, dr))));
                current.g = @truncate(@as(u16, current.g) +% @as(u16, @bitCast(@as(i16, dg))));
                current.b = @truncate(@as(u16, current.b) +% @as(u16, @bitCast(@as(i16, db))));
                index[current.hash()] = current;
                out_pixels[px_pos] = current.to_u32();
                px_pos += 1;
            } else if (tag == 0x80) { // QOI_OP_LUMA
                if (in_pos >= bytes.len) return error.TruncatedInput;
                const b2 = bytes[in_pos];
                in_pos += 1;
                const dg: i8 = @as(i8, @intCast(b1 & 0x3F)) - 32;
                const dr_dg: i8 = @as(i8, @intCast((b2 >> 4) & 0x0F)) - 8;
                const db_dg: i8 = @as(i8, @intCast(b2 & 0x0F)) - 8;
                const dr: i16 = @as(i16, dr_dg) + @as(i16, dg);
                const db: i16 = @as(i16, db_dg) + @as(i16, dg);
                current.r = @truncate(@as(u16, current.r) +% @as(u16, @bitCast(dr)));
                current.g = @truncate(@as(u16, current.g) +% @as(u16, @bitCast(@as(i16, dg))));
                current.b = @truncate(@as(u16, current.b) +% @as(u16, @bitCast(db)));
                index[current.hash()] = current;
                out_pixels[px_pos] = current.to_u32();
                px_pos += 1;
            } else { // 0xC0: QOI_OP_RUN
                const run_len: usize = @as(usize, b1 & 0x3F) + 1;
                var r: usize = 0;
                while (r < run_len) : (r += 1) {
                    if (px_pos >= total_pixels) return error.TruncatedInput;
                    out_pixels[px_pos] = current.to_u32();
                    px_pos += 1;
                }
            }
        }
    }

    if (px_pos < total_pixels) return error.TruncatedInput;

    // Verify 8-byte end marker: 7 zeros followed by 0x01
    const end_marker = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };
    if (in_pos + 8 > bytes.len) return error.EndMarkerMissing;
    if (!std.mem.eql(u8, bytes[in_pos..][0..8], &end_marker)) {
        return error.EndMarkerMissing;
    }

    return header;
}

// ---------------------------------------------------------------------------
// Host Unit Tests
// ---------------------------------------------------------------------------

test "qoi: reject header magic and truncated headers" {
    var out: [16]u32 = undefined;
    try std.testing.expectError(error.TruncatedInput, decode("qo", &out));
    try std.testing.expectError(error.HeaderMagic, decode("badf0000000000", &out));
}

test "qoi: decode solid red 4x4 fixture" {
    const fixture_bytes = @embedFile("fixtures/qoi/solid_red_4x4.qoi");
    var pixels: [16]u32 = undefined;
    const header = try decode(fixture_bytes, &pixels);

    try std.testing.expectEqual(@as(u32, 4), header.width);
    try std.testing.expectEqual(@as(u32, 4), header.height);

    // Opaque Red in little-endian B8G8R8X8: (0xFF << 24) | (0xFF << 16) | (0x00 << 8) | 0x00 = 0xFFFF0000
    const expected_red: u32 = 0xFFFF0000;
    for (pixels) |px| {
        try std.testing.expectEqual(expected_red, px);
    }
}

test "qoi: decode gradient rgba 8x8 fixture" {
    const fixture_bytes = @embedFile("fixtures/qoi/gradient_rgba_8x8.qoi");
    var pixels: [64]u32 = undefined;
    const header = try decode(fixture_bytes, &pixels);

    try std.testing.expectEqual(@as(u32, 8), header.width);
    try std.testing.expectEqual(@as(u32, 8), header.height);

    // Verify origin pixel (0,0): r=0, g=0, b=0, a=255 -> 0xFF000000
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0]);

    // Verify pixel at (1, 0): r=32, g=0, b=16, a=128
    // LE u32: (128 << 24) | (32 << 16) | (0 << 8) | 16 = 0x80200010
    const expected_1_0: u32 = (128 << 24) | (32 << 16) | (0 << 8) | 16;
    try std.testing.expectEqual(expected_1_0, pixels[1]);
}

test "qoi: decode non-square 12x4 fixture" {
    const fixture_bytes = @embedFile("fixtures/qoi/rect_12x4.qoi");
    var pixels: [48]u32 = undefined;
    const header = try decode(fixture_bytes, &pixels);

    try std.testing.expectEqual(@as(u32, 12), header.width);
    try std.testing.expectEqual(@as(u32, 4), header.height);

    // Verify pixel (0, 0): r=0, g=0, b=100, a=255 -> (0xFF << 24) | (0 << 16) | (0 << 8) | 100 = 0xFF000064
    try std.testing.expectEqual(@as(u32, 0xFF000064), pixels[0]);
}

test "qoi: buffer too small rejection" {
    const fixture_bytes = @embedFile("fixtures/qoi/solid_red_4x4.qoi");
    var small_buf: [15]u32 = undefined; // 4x4 requires 16
    try std.testing.expectError(error.BufferTooSmall, decode(fixture_bytes, &small_buf));
}

test "qoi: corrupt end marker rejection" {
    const fixture_bytes = @embedFile("fixtures/qoi/solid_red_4x4.qoi");
    var corrupt: [fixture_bytes.len]u8 = undefined;
    @memcpy(&corrupt, fixture_bytes);
    corrupt[corrupt.len - 1] = 0x99; // Corrupt end marker byte

    var pixels: [16]u32 = undefined;
    try std.testing.expectError(error.EndMarkerMissing, decode(&corrupt, &pixels));
}
