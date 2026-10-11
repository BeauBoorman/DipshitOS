//! VirelaiOS Core Image Representation & Operations.
//!
//! Milestone 23 / Issue #822 (IMG1).
//! Pixel format: 32-bpp B8G8R8X8_UNORM (little-endian: [B, G, R, X/A]),
//! matching virtio-gpu scanout (format 2).
//! Stride is derived: width * 4 bytes per row. Pure value type borrowing memory.

const std = @import("std");
pub const qoi = @import("qoi.zig");
pub const png = @import("png.zig");

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    pub fn make(x: u32, y: u32, w: u32, h: u32) Rect {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }
};

pub const DecodeError = error{
    UnknownFormat,
    HeaderMagic,
    TruncatedInput,
    BufferTooSmall,
    EndMarkerMissing,
    InvalidDimensions,
    InvalidCrc,
    UnsupportedBitDepth,
    UnsupportedColorType,
    UnsupportedInterlace,
    CorruptStream,
};

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []align(1) u32,

    /// Stride in bytes is derived: width * 4.
    pub inline fn stride(self: Image) u32 {
        return self.width * 4;
    }

    /// Bounds-checked pixel pointer access (returns null on OOB, no UB).
    pub fn pixel_at(self: Image, x: u32, y: u32) ?*align(1) u32 {
        if (x >= self.width or y >= self.height) return null;
        const idx = @as(usize, y) * self.width + x;
        if (idx >= self.pixels.len) return null;
        return &self.pixels[idx];
    }

    /// Return a sub-image view sharing the parent buffer and row stride.
    /// The sub-image's pixels slice starts at (rect.y * self.width + rect.x)
    /// with the same width stride.
    pub fn sub_image(self: Image, rect: Rect) Image {
        if (rect.w == 0 or rect.h == 0 or rect.x >= self.width or rect.y >= self.height) {
            return .{
                .width = self.width,
                .height = 0,
                .pixels = self.pixels[0..0],
            };
        }

        const eff_w = @min(rect.w, self.width - rect.x);
        const eff_h = @min(rect.h, self.height - rect.y);
        const start_idx = @as(usize, rect.y) * self.width + rect.x;

        // The slice extent covers through the last row's effective pixels
        const end_idx = if (eff_h > 0)
            @as(usize, rect.y + eff_h - 1) * self.width + rect.x + eff_w
        else
            start_idx;

        return .{
            .width = self.width,
            .height = eff_h,
            .pixels = self.pixels[start_idx..end_idx],
        };
    }

    /// Software Porter-Duff source-over alpha blending (src over dest).
    pub fn blit(dest: Image, src: Image, dx: i32, dy: i32) void {
        var sy: u32 = 0;
        while (sy < src.height) : (sy += 1) {
            const dest_y_i = dy + @as(i32, @intCast(sy));
            if (dest_y_i < 0 or dest_y_i >= dest.height) continue;
            const dest_y: u32 = @intCast(dest_y_i);

            var sx: u32 = 0;
            while (sx < src.width) : (sx += 1) {
                const dest_x_i = dx + @as(i32, @intCast(sx));
                if (dest_x_i < 0 or dest_x_i >= dest.width) continue;
                const dest_x: u32 = @intCast(dest_x_i);

                const src_ptr = src.pixel_at(sx, sy) orelse continue;
                const src_px = src_ptr.*;
                const src_a: u32 = (src_px >> 24) & 0xFF;
                if (src_a == 0) continue; // Fully transparent: no-op

                const dest_ptr = dest.pixel_at(dest_x, dest_y) orelse continue;
                if (src_a == 255) {
                    // Fully opaque: direct overwrite
                    dest_ptr.* = src_px;
                } else {
                    // Source-over blending
                    const dest_px = dest_ptr.*;
                    const src_r: u32 = (src_px >> 16) & 0xFF;
                    const src_g: u32 = (src_px >> 8) & 0xFF;
                    const src_b: u32 = src_px & 0xFF;

                    const dest_a: u32 = (dest_px >> 24) & 0xFF;
                    const dest_r: u32 = (dest_px >> 16) & 0xFF;
                    const dest_g: u32 = (dest_px >> 8) & 0xFF;
                    const dest_b: u32 = dest_px & 0xFF;

                    const inv_a: u32 = 255 - src_a;
                    const out_r = (src_r * src_a + dest_r * inv_a + 127) / 255;
                    const out_g = (src_g * src_a + dest_g * inv_a + 127) / 255;
                    const out_b = (src_b * src_a + dest_b * inv_a + 127) / 255;
                    const out_a = src_a + (dest_a * inv_a + 127) / 255;

                    dest_ptr.* = (out_a << 24) | (out_r << 16) | (out_g << 8) | out_b;
                }
            }
        }
    }
};

/// Unified image decode entry point: detects format signature and dispatches.
pub fn decode(bytes: []const u8, out_buf: []align(1) u32) DecodeError!Image {
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "qoif")) {
        const hdr = qoi.decode(bytes, out_buf) catch |err| switch (err) {
            error.HeaderMagic => return error.HeaderMagic,
            error.TruncatedInput => return error.TruncatedInput,
            error.BufferTooSmall => return error.BufferTooSmall,
            error.EndMarkerMissing => return error.EndMarkerMissing,
            error.InvalidDimensions => return error.InvalidDimensions,
        };
        const total = @as(usize, hdr.width) * hdr.height;
        return Image{
            .width = hdr.width,
            .height = hdr.height,
            .pixels = out_buf[0..total],
        };
    }

    // PNG signature check
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) {
        const hdr = png.decode(bytes, out_buf) catch |err| switch (err) {
            error.HeaderMagic => return error.HeaderMagic,
            error.TruncatedInput => return error.TruncatedInput,
            error.BufferTooSmall => return error.BufferTooSmall,
            error.InvalidCrc => return error.InvalidCrc,
            error.UnsupportedBitDepth => return error.UnsupportedBitDepth,
            error.UnsupportedColorType => return error.UnsupportedColorType,
            error.UnsupportedInterlace => return error.UnsupportedInterlace,
            error.CorruptStream,
            error.InvalidBlockType,
            error.InvalidHuffmanTree,
            error.InvalidDistance,
            error.InvalidZlibHeader,
            error.Adler32Mismatch,
            => return error.CorruptStream,
        };
        const total = @as(usize, hdr.width) * hdr.height;
        return Image{
            .width = hdr.width,
            .height = hdr.height,
            .pixels = out_buf[0..total],
        };
    }

    return error.UnknownFormat;
}

// ---------------------------------------------------------------------------
// Host Unit Tests
// ---------------------------------------------------------------------------

test "image: pixel_at bounds checking" {
    var raw: [16]u32 = @as([16]u32, @splat(@as(u32, 0)));
    const img = Image{ .width = 4, .height = 4, .pixels = &raw };

    try std.testing.expect(img.pixel_at(0, 0) != null);
    try std.testing.expect(img.pixel_at(3, 3) != null);
    try std.testing.expect(img.pixel_at(4, 0) == null);
    try std.testing.expect(img.pixel_at(0, 4) == null);
}

test "image: sub_image view and zero-sized handling" {
    var raw: [36]u32 = @as([36]u32, @splat(@as(u32, 0)));
    for (&raw, 0..) |*p, i| p.* = @intCast(i);

    const img = Image{ .width = 6, .height = 6, .pixels = &raw };

    // Sub-image at (2, 1) size 3x2
    const sub = img.sub_image(Rect.make(2, 1, 3, 2));
    try std.testing.expectEqual(@as(u32, 6), sub.width); // Preserves parent row stride
    try std.testing.expectEqual(@as(u32, 2), sub.height);

    // First pixel of sub-image should be at (2, 1) in parent: 1 * 6 + 2 = 8
    try std.testing.expectEqual(@as(u32, 8), sub.pixels[0]);

    // Zero-sized sub-image
    const zero = img.sub_image(Rect.make(0, 0, 0, 0));
    try std.testing.expectEqual(@as(u32, 0), zero.height);
    try std.testing.expectEqual(@as(usize, 0), zero.pixels.len);
}

test "image: blit Porter-Duff alpha blending" {
    var dest_raw: [4]u32 = @as([4]u32, @splat(@as(u32, 0xFF000000))); // Opaque Black: (A=255, R=0, G=0, B=0)
    var src_raw: [4]u32 = [_]u32{
        0x00FFFFFF, // Fully transparent White -> should not alter dest
        0x80FF0000, // 50% Alpha Red (A=128, R=255, G=0, B=0) -> blend with Black
        0xFFFF0000, // 100% Opaque Red -> overwrite
        0x8000FF00, // 50% Alpha Green (A=128, R=0, G=255, B=0)
    };

    const dest = Image{ .width = 2, .height = 2, .pixels = &dest_raw };
    const src = Image{ .width = 2, .height = 2, .pixels = &src_raw };

    Image.blit(dest, src, 0, 0);

    // Pixel 0: was black, src was transparent -> remains black
    try std.testing.expectEqual(@as(u32, 0xFF000000), dest.pixels[0]);

    // Pixel 1: was black, src was 50% red (128/255)
    // out_r = (255 * 128 + 0 * 127 + 127) / 255 = (32640 + 127) / 255 = 128 (0x80)
    const px1 = dest.pixels[1];
    const r1 = (px1 >> 16) & 0xFF;
    try std.testing.expect(r1 >= 127 and r1 <= 129);

    // Pixel 2: 100% opaque red -> exactly 0xFFFF0000
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), dest.pixels[2]);
}

test "image: format dispatch with QOI" {
    const fixture_bytes = @embedFile("fixtures/qoi/solid_red_4x4.qoi");
    var buf: [16]u32 = undefined;
    const img = try decode(fixture_bytes, &buf);

    try std.testing.expectEqual(@as(u32, 4), img.width);
    try std.testing.expectEqual(@as(u32, 4), img.height);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), img.pixels[0]);

    // Unknown format
    try std.testing.expectError(error.UnknownFormat, decode("GARBAGE_DATA", &buf));
}

test "image: format dispatch with PNG" {
    const fixture_bytes = @embedFile("fixtures/png/solid_rgb_4x4.png");
    var buf: [16]u32 = undefined;
    const img = try decode(fixture_bytes, &buf);

    try std.testing.expectEqual(@as(u32, 4), img.width);
    try std.testing.expectEqual(@as(u32, 4), img.height);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), img.pixels[0]);
}
