//! Captured EFI memory-map view for the Virelai Monitor `mem` command
//! (Milestone 1.5, commands & personality).
//!
//! ADR 0004 D2: the map the kernel captured *before* ExitBootServices is
//! the sole authority on memory layout; there is no `GetMemoryMap` after
//! exit. This module is a target-agnostic view over the raw descriptor
//! bytes, so host tests can exercise it and the later Console & Shell Core
//! stream can feed it directly from the kernel's `MemoryMapSlice`.
//!
//! No libc, no POSIX, no allocation, no global mutable state. All totals
//! use saturating arithmetic so a hostile map cannot wrap or panic.

const std = @import("std");

/// EFI memory type values (UEFI spec; mirrored from the kernel's
/// `std.os.uefi.tables.MemoryType` so this module stays freestanding-safe).
pub const MemoryType = enum(u32) {
    reserved_memory_type = 0,
    loader_code = 1,
    loader_data = 2,
    boot_services_code = 3,
    boot_services_data = 4,
    runtime_services_code = 5,
    runtime_services_data = 6,
    conventional_memory = 7,
    unusable_memory = 8,
    acpi_reclaim_memory = 9,
    acpi_memory_nvs = 10,
    memory_mapped_io = 11,
    memory_mapped_io_port_space = 12,
    pal_code = 13,
    persistent_memory = 14,
    _,
};

/// 40-byte EFI_MEMORY_DESCRIPTOR layout: u32 type + implicit padding, then
/// four u64 fields.
pub const MemoryDescriptor = extern struct {
    type: MemoryType,
    physical_start: u64,
    virtual_start: u64,
    number_of_pages: u64,
    attribute: u64,
};

pub const page_size: u64 = 4096;

/// Byte-stride view over a captured map buffer. Handles the EFI convention
/// of a descriptor stride (`descriptor_size`) that may exceed
/// `@sizeOf(MemoryDescriptor)`. Accessors copy fields out byte-wise, so no
/// alignment assumption is made about the buffer.
pub const MapView = struct {
    data: []const u8,
    descriptor_size: usize,
    count: usize,
    key: u64 = 0,
    descriptor_version: u32 = 0,

    /// Clamps `count` so it cannot read past `data`; a zero descriptor size
    /// yields an empty view rather than a divide-by-zero.
    pub fn init(data: []const u8, descriptor_size: usize, count: usize) MapView {
        if (descriptor_size == 0) return .{ .data = data, .descriptor_size = 0, .count = 0 };
        return .{
            .data = data,
            .descriptor_size = descriptor_size,
            .count = @min(count, data.len / descriptor_size),
        };
    }

    /// Copy-out accessor; returns null for out-of-range indices or a
    /// truncated tail. Safe for any stride and any buffer alignment.
    pub fn get(self: MapView, index: usize) ?MemoryDescriptor {
        if (index >= self.count) return null;
        const base = index * self.descriptor_size;
        if (base + @sizeOf(MemoryDescriptor) > self.data.len) return null;
        return .{
            .type = @fromBackingInt(@intCast(std.mem.readInt(u32, self.data[base..][0..4], .little))),
            .physical_start = std.mem.readInt(u64, self.data[base + 8 ..][0..8], .little),
            .virtual_start = std.mem.readInt(u64, self.data[base + 16 ..][0..8], .little),
            .number_of_pages = std.mem.readInt(u64, self.data[base + 24 ..][0..8], .little),
            .attribute = std.mem.readInt(u64, self.data[base + 32 ..][0..8], .little),
        };
    }
};

pub const Summary = struct {
    /// RAM usable by the kernel (conventional + loader + boot services +
    /// persistent), mirroring the kernel's own `is_ram` classification.
    usable_pages: u64 = 0,
    conventional_pages: u64 = 0,
    loader_pages: u64 = 0,
    boot_services_pages: u64 = 0,
    runtime_pages: u64 = 0,
    reserved_pages: u64 = 0,
    mmio_pages: u64 = 0,
};

pub fn add_pages(a: u64, b: u64) u64 {
    return std.math.add(u64, a, b) catch std.math.maxInt(u64);
}

pub fn bytes_of(pages: u64) u64 {
    return std.math.mul(u64, pages, page_size) catch std.math.maxInt(u64);
}

fn is_ram(kind: MemoryType) bool {
    return switch (kind) {
        .loader_code,
        .loader_data,
        .boot_services_code,
        .boot_services_data,
        .conventional_memory,
        .persistent_memory,
        => true,
        else => false,
    };
}

fn is_mmio(kind: MemoryType) bool {
    return kind == .memory_mapped_io or kind == .memory_mapped_io_port_space;
}

/// One bounded pass over the view; saturating, never allocates.
pub fn summarize(view: MapView) Summary {
    var s = Summary{};
    var index: usize = 0;
    while (index < view.count) : (index += 1) {
        const d = view.get(index) orelse continue;
        const pages = d.number_of_pages;
        if (is_mmio(d.type)) {
            s.mmio_pages = add_pages(s.mmio_pages, pages);
        } else if (is_ram(d.type)) {
            s.usable_pages = add_pages(s.usable_pages, pages);
            switch (d.type) {
                .conventional_memory => s.conventional_pages = add_pages(s.conventional_pages, pages),
                .loader_code, .loader_data => s.loader_pages = add_pages(s.loader_pages, pages),
                .boot_services_code, .boot_services_data => s.boot_services_pages = add_pages(s.boot_services_pages, pages),
                else => {},
            }
        } else {
            s.reserved_pages = add_pages(s.reserved_pages, pages);
            switch (d.type) {
                .runtime_services_code, .runtime_services_data => s.runtime_pages = add_pages(s.runtime_pages, pages),
                else => {},
            }
        }
    }
    return s;
}

const test_descriptors = [_]MemoryDescriptor{
    .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 960, .attribute = 0x800000000000000f },
    .{ .type = .loader_code, .physical_start = 0x7000000, .virtual_start = 0, .number_of_pages = 64, .attribute = 0x800000000000000f },
    .{ .type = .boot_services_data, .physical_start = 0x8000000, .virtual_start = 0, .number_of_pages = 128, .attribute = 0x800000000000000f },
    .{ .type = .runtime_services_data, .physical_start = 0x9000000, .virtual_start = 0, .number_of_pages = 8, .attribute = 0x800000000000000f },
    .{ .type = .memory_mapped_io, .physical_start = 0x1000000, .virtual_start = 0, .number_of_pages = 16, .attribute = 0 },
    .{ .type = .reserved_memory_type, .physical_start = 0x1ff00000, .virtual_start = 0, .number_of_pages = 1, .attribute = 0 },
};

test "memmap: dense-stride view round-trips descriptors" {
    const view = MapView.init(std.mem.asBytes(&test_descriptors), @sizeOf(MemoryDescriptor), test_descriptors.len);
    try std.testing.expectEqual(test_descriptors.len, view.count);
    for (test_descriptors, 0..) |expected, index| {
        const actual = view.get(index) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(expected.type, actual.type);
        try std.testing.expectEqual(expected.physical_start, actual.physical_start);
        try std.testing.expectEqual(expected.number_of_pages, actual.number_of_pages);
        try std.testing.expectEqual(expected.attribute, actual.attribute);
    }
    try std.testing.expect(view.get(test_descriptors.len) == null);
}

test "memmap: sparse-stride view reads past padding" {
    const stride = @sizeOf(MemoryDescriptor) + 8; // EFI may pad descriptors
    var raw: [2 * stride]u8 align(@alignOf(MemoryDescriptor)) = undefined;
    std.mem.bytesAsValue(MemoryDescriptor, raw[0..@sizeOf(MemoryDescriptor)]).* = test_descriptors[0];
    std.mem.bytesAsValue(MemoryDescriptor, raw[stride .. stride + @sizeOf(MemoryDescriptor)]).* = test_descriptors[2];
    var view = MapView.init(&raw, stride, 2);
    const first = view.get(0) orelse return error.TestUnexpectedResult;
    const second = view.get(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(test_descriptors[0].type, first.type);
    try std.testing.expectEqual(test_descriptors[0].physical_start, first.physical_start);
    try std.testing.expectEqual(test_descriptors[2].type, second.type);
    try std.testing.expectEqual(test_descriptors[2].number_of_pages, second.number_of_pages);
}

test "memmap: init clamps count and rejects zero stride" {
    const bytes = std.mem.asBytes(&test_descriptors);
    const view = MapView.init(bytes, @sizeOf(MemoryDescriptor), 999);
    try std.testing.expectEqual(test_descriptors.len, view.count);
    var empty = MapView.init(bytes, 0, 999);
    try std.testing.expectEqual(@as(usize, 0), empty.count);
    try std.testing.expect(empty.get(0) == null);
}

test "memmap: summarize totals match the fixture" {
    const view = MapView.init(std.mem.asBytes(&test_descriptors), @sizeOf(MemoryDescriptor), test_descriptors.len);
    const s = summarize(view);
    try std.testing.expectEqual(@as(u64, 960 + 64 + 128), s.usable_pages);
    try std.testing.expectEqual(@as(u64, 960), s.conventional_pages);
    try std.testing.expectEqual(@as(u64, 64), s.loader_pages);
    try std.testing.expectEqual(@as(u64, 128), s.boot_services_pages);
    try std.testing.expectEqual(@as(u64, 8), s.runtime_pages);
    try std.testing.expectEqual(@as(u64, 8 + 1), s.reserved_pages); // runtime + reserved descriptor
    try std.testing.expectEqual(@as(u64, 16), s.mmio_pages);
}

test "memmap: bytes_of converts pages to bytes" {
    try std.testing.expectEqual(@as(u64, 4096), bytes_of(1));
    try std.testing.expectEqual(@as(u64, 0x480000), bytes_of(1152));
    try std.testing.expectEqual(std.math.maxInt(u64), bytes_of(std.math.maxInt(u64)));
}
