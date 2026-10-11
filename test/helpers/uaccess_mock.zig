//! VirelaiOS shared test helper: User memory access & uaccess mocking (M41 TS1).
//!
//! Provides synthetic user-memory address spaces, region validation,
//! permission enforcement, and programmable fault injection for host unit tests.

const std = @import("std");

pub const Outcome = enum(u32) {
    ok = 0,
    fault = 1,
};

pub const Permission = enum {
    none,
    read,
    write,
    read_write,

    pub fn can_read(self: Permission) bool {
        return self == .read or self == .read_write;
    }

    pub fn can_write(self: Permission) bool {
        return self == .write or self == .read_write;
    }
};

pub const Region = struct {
    base: u64,
    len: usize,
    perm: Permission = .read_write,
    backing: ?[]u8 = null,

    pub fn contains(self: Region, addr: u64, size: usize) bool {
        if (size == 0) return true;
        const end = std.math.add(u64, addr, size) catch return false;
        const region_end = std.math.add(u64, self.base, self.len) catch return false;
        return addr >= self.base and end <= region_end;
    }
};

pub const FaultMode = union(enum) {
    none,
    always,
    after_bytes: usize,
    address_range: struct { start: u64, end: u64 },
};

pub const MockUserSpace = struct {
    const max_regions = 16;

    regions: [max_regions]Region = @as([max_regions]Region, @splat(@as(Region, .{ .base = 0, .len = 0, .perm = .none }))),
    region_count: usize = 0,

    fault_mode: FaultMode = .none,
    fault_counter: usize = 0,

    copies_in: usize = 0,
    copies_out: usize = 0,
    bytes_in: usize = 0,
    bytes_out: usize = 0,
    faults: usize = 0,

    pub fn init() MockUserSpace {
        return .{};
    }

    pub fn reset(self: *MockUserSpace) void {
        self.* = init();
    }

    pub fn add_region(self: *MockUserSpace, base: u64, slice: []u8, perm: Permission) bool {
        if (self.region_count >= max_regions) return false;
        self.regions[self.region_count] = .{
            .base = base,
            .len = slice.len,
            .perm = perm,
            .backing = slice,
        };
        self.region_count += 1;
        return true;
    }

    pub fn add_const_region(self: *MockUserSpace, base: u64, slice: []const u8) bool {
        // Safe cast for read-only tracking
        return self.add_region(base, @constCast(slice), .read);
    }

    pub fn set_fault_mode(self: *MockUserSpace, mode: FaultMode) void {
        self.fault_mode = mode;
        self.fault_counter = 0;
    }

    fn should_fault(self: *MockUserSpace, addr: u64, size: usize) bool {
        switch (self.fault_mode) {
            .none => return false,
            .always => return true,
            .after_bytes => |limit| {
                if (self.fault_counter + size > limit) return true;
                self.fault_counter += size;
                return false;
            },
            .address_range => |range| {
                const end = std.math.add(u64, addr, size) catch return true;
                return addr < range.end and end > range.start;
            },
        }
    }

    fn find_region(self: *const MockUserSpace, addr: u64, size: usize) ?*const Region {
        for (self.regions[0..self.region_count]) |*r| {
            if (r.contains(addr, size)) return r;
        }
        return null;
    }

    /// Read bytes from mock user memory into dst
    pub fn copy_in(self: *MockUserSpace, dst: []u8, src_addr: u64, len: usize) Outcome {
        if (len == 0) return .ok;
        if (self.should_fault(src_addr, len)) {
            self.faults += 1;
            return .fault;
        }

        const reg = self.find_region(src_addr, len) orelse {
            self.faults += 1;
            return .fault;
        };

        if (!reg.perm.can_read()) {
            self.faults += 1;
            return .fault;
        }

        if (reg.backing) |buf| {
            const offset = src_addr - reg.base;
            @memcpy(dst[0..len], buf[offset..][0..len]);
        } else {
            @memset(dst[0..len], 0);
        }

        self.copies_in += 1;
        self.bytes_in += len;
        return .ok;
    }

    /// Write bytes from src into mock user memory at dst_addr
    pub fn copy_out(self: *MockUserSpace, dst_addr: u64, src: []const u8, len: usize) Outcome {
        if (len == 0) return .ok;
        if (self.should_fault(dst_addr, len)) {
            self.faults += 1;
            return .fault;
        }

        const reg = self.find_region(dst_addr, len) orelse {
            self.faults += 1;
            return .fault;
        };

        if (!reg.perm.can_write()) {
            self.faults += 1;
            return .fault;
        }

        if (reg.backing) |buf| {
            const offset = dst_addr - reg.base;
            @memcpy(buf[offset..][0..len], src[0..len]);
        }

        self.copies_out += 1;
        self.bytes_out += len;
        return .ok;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "uaccess_mock: basic read-write regions" {
    var uspace = MockUserSpace.init();

    var text_backing = [_]u8{ 'H', 'e', 'l', 'l', 'o' };
    var stack_backing: [64]u8 = @as([64]u8, @splat(@as(u8, 0)));

    try std.testing.expect(uspace.add_const_region(0x400000, &text_backing));
    try std.testing.expect(uspace.add_region(0x800000, &stack_backing, .read_write));

    var read_buf: [5]u8 = undefined;
    try std.testing.expectEqual(Outcome.ok, uspace.copy_in(&read_buf, 0x400000, 5));
    try std.testing.expectEqualStrings("Hello", &read_buf);

    // Write to read-only region should fault
    try std.testing.expectEqual(Outcome.fault, uspace.copy_out(0x400000, "World", 5));

    // Write to read-write region should succeed
    try std.testing.expectEqual(Outcome.ok, uspace.copy_out(0x800000, "World", 5));
    try std.testing.expectEqualStrings("World", stack_backing[0..5]);

    // Read back from read-write region
    try std.testing.expectEqual(Outcome.ok, uspace.copy_in(&read_buf, 0x800000, 5));
    try std.testing.expectEqualStrings("World", &read_buf);
}

test "uaccess_mock: boundary and fault conditions" {
    var uspace = MockUserSpace.init();
    var backing: [16]u8 = @as([16]u8, @splat(@as(u8, 0)));
    _ = uspace.add_region(0x1000, &backing, .read_write);

    var buf: [4]u8 = undefined;

    // Out of bounds address
    try std.testing.expectEqual(Outcome.fault, uspace.copy_in(&buf, 0x2000, 4));

    // Straddling end of region
    try std.testing.expectEqual(Outcome.fault, uspace.copy_in(&buf, 0x1000 + 14, 4));

    // Zero length at invalid address is ok
    try std.testing.expectEqual(Outcome.ok, uspace.copy_in(&buf, 0xdeadbeef, 0));

    // Injected fault mode
    uspace.set_fault_mode(.always);
    try std.testing.expectEqual(Outcome.fault, uspace.copy_in(&buf, 0x1000, 4));

    // Address range fault
    uspace.set_fault_mode(.{ .address_range = .{ .start = 0x1004, .end = 0x1008 } });
    try std.testing.expectEqual(Outcome.ok, uspace.copy_in(buf[0..2], 0x1000, 2));
    try std.testing.expectEqual(Outcome.fault, uspace.copy_in(buf[0..2], 0x1004, 2));
}
