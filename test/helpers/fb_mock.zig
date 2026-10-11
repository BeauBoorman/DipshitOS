//! VirelaiOS shared test helper: Framebuffer scanout & clipping rects mocking (M41 TS1).
//!
//! Provides synthetic framebuffer surfaces (32-bpp B8G8R8X8 format),
//! clipping rect math, damaged region unioning, and pixel assertion helpers.

const std = @import("std");

pub const default_scanout_w: u32 = 1280;
pub const default_scanout_h: u32 = 720;

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    pub fn contains(self: Rect, px: u32, py: u32) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }

    pub fn intersects(self: Rect, other: Rect) bool {
        return self.x < other.x + other.w and self.x + self.w > other.x and
            self.y < other.y + other.h and self.y + self.h > other.y;
    }

    pub fn clip_to(self: Rect, bounds: Rect) ?Rect {
        const left = @max(self.x, bounds.x);
        const top = @max(self.y, bounds.y);
        const right = @min(self.x + self.w, bounds.x + bounds.w);
        const bottom = @min(self.y + self.h, bounds.y + bounds.h);

        if (right <= left or bottom <= top) return null;
        return Rect{
            .x = left,
            .y = top,
            .w = right - left,
            .h = bottom - top,
        };
    }

    pub fn union_with(self: Rect, other: Rect) Rect {
        if (self.w == 0 or self.h == 0) return other;
        if (other.w == 0 or other.h == 0) return self;

        const left = @min(self.x, other.x);
        const top = @min(self.y, other.y);
        const right = @max(self.x + self.w, other.x + other.w);
        const bottom = @max(self.y + self.h, other.y + other.h);

        return Rect{
            .x = left,
            .y = top,
            .w = right - left,
            .h = bottom - top,
        };
    }
};

/// B8G8R8X8 color manipulation helpers
pub fn make_color(r: u8, g: u8, b: u8, a: u8) u32 {
    return @as(u32, b) | (@as(u32, g) << 8) | (@as(u32, r) << 16) | (@as(u32, a) << 24);
}

pub fn get_b(color: u32) u8 {
    return @truncate(color);
}

pub fn get_g(color: u32) u8 {
    return @truncate(color >> 8);
}

pub fn get_r(color: u32) u8 {
    return @truncate(color >> 16);
}

pub fn get_a(color: u32) u8 {
    return @truncate(color >> 24);
}

pub fn MockScanoutSurface(comptime W: u32, comptime H: u32) type {
    return struct {
        const Self = @This();
        pub const width: u32 = W;
        pub const height: u32 = H;
        pub const stride: usize = W * 4;

        buffer: [W * H * 4]u8 = @as([(W * H * 4)]u8, @splat(@as(u8, 0))),

        pub fn init() Self {
            return .{};
        }

        pub fn bounds(self: *const Self) Rect {
            _ = self;
            return Rect{ .x = 0, .y = 0, .w = W, .h = H };
        }

        pub fn clear(self: *Self, color: u32) void {
            self.fill_rect(self.bounds(), color);
        }

        pub fn put_pixel(self: *Self, x: u32, y: u32, color: u32) void {
            if (x >= W or y >= H) return;
            const offset = (y * W + x) * 4;
            self.buffer[offset + 0] = get_b(color);
            self.buffer[offset + 1] = get_g(color);
            self.buffer[offset + 2] = get_r(color);
            self.buffer[offset + 3] = get_a(color);
        }

        pub fn get_pixel(self: *const Self, x: u32, y: u32) u32 {
            if (x >= W or y >= H) return 0;
            const offset = (y * W + x) * 4;
            return make_color(
                self.buffer[offset + 2],
                self.buffer[offset + 1],
                self.buffer[offset + 0],
                self.buffer[offset + 3],
            );
        }

        pub fn fill_rect(self: *Self, rect: Rect, color: u32) void {
            const clipped = rect.clip_to(self.bounds()) orelse return;
            var cy: u32 = clipped.y;
            while (cy < clipped.y + clipped.h) : (cy += 1) {
                var cx: u32 = clipped.x;
                while (cx < clipped.x + clipped.w) : (cx += 1) {
                    self.put_pixel(cx, cy, color);
                }
            }
        }

        pub fn fill_rect_clipped(self: *Self, rect: Rect, clip: Rect, color: u32) void {
            const clipped1 = rect.clip_to(clip) orelse return;
            self.fill_rect(clipped1, color);
        }

        pub fn blit(self: *Self, dst_x: u32, dst_y: u32, src: []const u8, src_stride: usize, src_w: u32, src_h: u32) void {
            const src_rect = Rect{ .x = dst_x, .y = dst_y, .w = src_w, .h = src_h };
            const clipped = src_rect.clip_to(self.bounds()) orelse return;

            var cy: u32 = clipped.y;
            while (cy < clipped.y + clipped.h) : (cy += 1) {
                const sy = cy - dst_y;
                const sx_start = clipped.x - dst_x;
                const src_row_off = sy * src_stride + sx_start * 4;
                const dst_row_off = (cy * W + clipped.x) * 4;
                const copy_bytes = clipped.w * 4;
                @memcpy(self.buffer[dst_row_off..][0..copy_bytes], src[src_row_off..][0..copy_bytes]);
            }
        }

        pub fn expect_pixel(self: *const Self, x: u32, y: u32, color: u32) !void {
            const actual = self.get_pixel(x, y);
            try std.testing.expectEqual(color, actual);
        }

        pub fn expect_rect(self: *const Self, rect: Rect, color: u32) !void {
            var cy: u32 = rect.y;
            while (cy < rect.y + rect.h) : (cy += 1) {
                var cx: u32 = rect.x;
                while (cx < rect.x + rect.w) : (cx += 1) {
                    try self.expect_pixel(cx, cy, color);
                }
            }
        }

        pub fn count_pixels(self: *const Self, color: u32) usize {
            var count: usize = 0;
            var y: u32 = 0;
            while (y < H) : (y += 1) {
                var x: u32 = 0;
                while (x < W) : (x += 1) {
                    if (self.get_pixel(x, y) == color) count += 1;
                }
            }
            return count;
        }
    };
}

/// Standard 1280x720 scanout surface mock
pub const StandardScanout = MockScanoutSurface(default_scanout_w, default_scanout_h);

/// Small test surface for fast unit test assertions (e.g. 64x48)
pub const SmallSurface = MockScanoutSurface(64, 48);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "fb_mock: rect math - intersection, clipping, union" {
    const r1 = Rect{ .x = 10, .y = 10, .w = 20, .h = 20 };
    const r2 = Rect{ .x = 20, .y = 20, .w = 20, .h = 20 };

    try std.testing.expect(r1.contains(15, 15));
    try std.testing.expect(!r1.contains(35, 35));

    try std.testing.expect(r1.intersects(r2));

    const clipped = r1.clip_to(r2).?;
    try std.testing.expectEqual(@as(u32, 20), clipped.x);
    try std.testing.expectEqual(@as(u32, 20), clipped.y);
    try std.testing.expectEqual(@as(u32, 10), clipped.w);
    try std.testing.expectEqual(@as(u32, 10), clipped.h);

    const united = r1.union_with(r2);
    try std.testing.expectEqual(@as(u32, 10), united.x);
    try std.testing.expectEqual(@as(u32, 10), united.y);
    try std.testing.expectEqual(@as(u32, 30), united.w);
    try std.testing.expectEqual(@as(u32, 30), united.h);
}

test "fb_mock: color packing and surface operations" {
    var surf = SmallSurface.init();

    const red = make_color(0xff, 0x00, 0x00, 0xff);
    const blue = make_color(0x00, 0x00, 0xff, 0xff);

    try std.testing.expectEqual(@as(u8, 0xff), get_r(red));
    try std.testing.expectEqual(@as(u8, 0x00), get_b(red));
    try std.testing.expectEqual(@as(u8, 0xff), get_b(blue));

    // Fill rect
    const fill_area = Rect{ .x = 5, .y = 5, .w = 10, .h = 10 };
    surf.fill_rect(fill_area, red);
    try surf.expect_rect(fill_area, red);
    try std.testing.expectEqual(@as(usize, 100), surf.count_pixels(red));

    // Pixel outside rect remains untouched (0)
    try std.testing.expectEqual(@as(u32, 0), surf.get_pixel(0, 0));
}
