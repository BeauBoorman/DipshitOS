//! Decoupled physical page allocator unit test suite (M41 TS5, #956).
//!
//! Extracted from kernel/src/alloc.zig.

const std = @import("std");
const alloc = @import("alloc");
const memmap = alloc.memmap;

// Aliases from alloc
const page_size = alloc.page_size;
const span_bytes = alloc.span_bytes;
const max_span_pages = alloc.max_span_pages;
const bitmap_bytes = alloc.bitmap_bytes;
const max_regions = alloc.max_regions;
const Region = alloc.Region;
const Exclusion = alloc.Exclusion;
const exclusion_from_bytes = alloc.exclusion_from_bytes;
const Stats = alloc.Stats;
const State = alloc.State;

const init = alloc.init;
const alloc_pages = alloc.alloc_pages;
const free_pages = alloc.free_pages;
const reserve = alloc.reserve;
const stats = alloc.stats;
const largest_free_run = alloc.largest_free_run;
const reset_refcounts = alloc.reset_refcounts;
const ref_page = alloc.ref_page;
const unref_page = alloc.unref_page;
const page_refcount = alloc.page_refcount;

// ---------------------------------------------------------------------------
// Tests (host-side; fixture maps, no hardware)
// ---------------------------------------------------------------------------

const test_descriptors = [_]memmap.MemoryDescriptor{
    .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 960, .attribute = 0 },
    .{ .type = .loader_code, .physical_start = 0x7000000, .virtual_start = 0, .number_of_pages = 64, .attribute = 0 },
    .{ .type = .boot_services_data, .physical_start = 0x8000000, .virtual_start = 0, .number_of_pages = 128, .attribute = 0 },
    .{ .type = .runtime_services_data, .physical_start = 0x9000000, .virtual_start = 0, .number_of_pages = 8, .attribute = 0 },
    .{ .type = .memory_mapped_io, .physical_start = 0x1000000, .virtual_start = 0, .number_of_pages = 16, .attribute = 0 },
    .{ .type = .reserved_memory_type, .physical_start = 0x1ff00000, .virtual_start = 0, .number_of_pages = 1, .attribute = 0 },
};

fn make_view() memmap.MapView {
    return memmap.MapView.init(std.mem.asBytes(&test_descriptors), @sizeOf(memmap.MemoryDescriptor), test_descriptors.len);
}

test "alloc: init pools conventional + loader + boot-services regions" {
    var st = State{};
    try std.testing.expect(st.init(make_view(), &.{}));
    const s = st.stats();
    try std.testing.expect(s.armed);
    // conventional 960 + loader_code 64 + boot_services_data 128.
    try std.testing.expectEqual(@as(u64, 1152), s.total_pages);
    try std.testing.expectEqual(@as(u64, 1152), s.free_pages);
    try std.testing.expectEqual(@as(u64, 0), s.excluded_pages);
    try std.testing.expectEqual(@as(usize, 3), s.region_count);
    // The span now covers the highest pooled region end (0x8080000).
    try std.testing.expectEqual(@as(u64, 0x7f80), s.span_pages);
    try std.testing.expectEqual(@as(u64, 0x100000), st.bitmap_base);
    // Conventional pages come first; the loader and boot regions follow,
    // and the mmio gap at 0x1000000 stays unallocatable.
    try std.testing.expectEqual(@as(u64, 0x100000), (st.alloc_pages(960) orelse return error.TestUnexpectedResult));
    try std.testing.expectEqual(@as(u64, 0x7000000), (st.alloc_pages(64) orelse return error.TestUnexpectedResult));
    try std.testing.expectEqual(@as(u64, 0x8000000), (st.alloc_pages(128) orelse return error.TestUnexpectedResult));
    try std.testing.expect(st.alloc_pages(1) == null);
}

test "alloc: no poolable memory leaves the allocator unarmed" {
    var st = State{};
    // mmio + reserved only: nothing is poolable (loader_code alone WOULD
    // arm the pool now — claim 5162).
    const no_ram = [_]memmap.MemoryDescriptor{
        .{ .type = .memory_mapped_io, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 16, .attribute = 0 },
        .{ .type = .reserved_memory_type, .physical_start = 0x2000000, .virtual_start = 0, .number_of_pages = 8, .attribute = 0 },
        .{ .type = .runtime_services_data, .physical_start = 0x3000000, .virtual_start = 0, .number_of_pages = 4, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&no_ram), @sizeOf(memmap.MemoryDescriptor), no_ram.len);
    try std.testing.expect(!st.init(view, &.{}));
    try std.testing.expect(!st.stats().armed);
    try std.testing.expect(st.alloc_pages(1) == null);
    try std.testing.expect(!st.free_pages(0x100000, 1));
}

test "alloc: first-fit alloc returns contiguous page-aligned runs" {
    var st = State{};
    _ = st.init(make_view(), &.{});
    const a1 = st.alloc_pages(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), a1);
    const a8 = st.alloc_pages(8) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x101000), a8); // contiguous right after a1
    try std.testing.expectEqual(@as(u64, a1 + 0x1000), a8);
    try std.testing.expectEqual(@as(u64, 1152 - 1 - 8), st.free_count);
    try std.testing.expect(st.free_pages(a1, 1));
    // Bit 0 is now a lone free bit (a8 still occupies bits 1..8), so the
    // first 3-page run starts at bit 9.
    const a3 = st.alloc_pages(3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x109000), a3);
    const a5 = st.alloc_pages(5) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x10c000), a5); // contiguous right after a3
    try std.testing.expectEqual(@as(u64, a3 + 3 * page_size), a5);
    try std.testing.expect(st.free_pages(a3, 3));
    try std.testing.expect(st.free_pages(a5, 5));
    try std.testing.expect(st.free_pages(a8, 8));
    try std.testing.expectEqual(@as(u64, 1152), st.free_count);
}

test "alloc: exhaustion returns null and leaves the pool unchanged" {
    var st = State{};
    _ = st.init(make_view(), &.{});
    // The pool is fragmented (conventional + loader + boot regions are not
    // contiguous), so exhaust it region by region: 960 + 64 + 128 = 1152.
    const c = st.alloc_pages(960) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), c);
    const l = st.alloc_pages(64) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x7000000), l);
    const b = st.alloc_pages(128) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x8000000), b);
    try std.testing.expectEqual(@as(u64, 0), st.free_count);
    try std.testing.expect(st.alloc_pages(1) == null);
    try std.testing.expect(st.alloc_pages(0) == null);
    try std.testing.expectEqual(@as(u64, 0), st.free_count); // failed alloc changed nothing
    try std.testing.expect(st.free_pages(c, 960));
    try std.testing.expect(st.free_pages(l, 64));
    try std.testing.expect(st.free_pages(b, 128));
    try std.testing.expectEqual(@as(u64, 1152), st.free_count);
}

test "alloc: gaps between regions are never allocatable" {
    // Two conventional regions with a reserved gap between them: the gap
    // must stay unallocatable (its bitmap bits are set during init).
    const two_regions = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 4, .attribute = 0 },
        .{ .type = .reserved_memory_type, .physical_start = 0x104000, .virtual_start = 0, .number_of_pages = 4, .attribute = 0 },
        .{ .type = .conventional_memory, .physical_start = 0x105000, .virtual_start = 0, .number_of_pages = 4, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&two_regions), @sizeOf(memmap.MemoryDescriptor), two_regions.len);
    var st = State{};
    _ = st.init(view, &.{});
    try std.testing.expectEqual(@as(u64, 8), st.total_pages);
    const first = st.alloc_pages(4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), first);
    // The gap (0x104000..0x104fff) must NOT be handed out: the next run is
    // the second region (0x105000 = bit 20).
    const second = st.alloc_pages(4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x105000), second);
    try std.testing.expect(st.alloc_pages(1) == null);
    try std.testing.expect(st.free_pages(first, 4));
    try std.testing.expect(st.free_pages(second, 4));
    try std.testing.expectEqual(@as(u64, 8), st.free_count);
}

test "alloc: unaligned conventional bases are rounded to whole pages" {
    const unaligned = [_]memmap.MemoryDescriptor{
        // base 0x100001: whole pages start at 0x101000 (2 pages declared,
        // 1 whole page remains after ceil/floor rounding).
        .{ .type = .conventional_memory, .physical_start = 0x100001, .virtual_start = 0, .number_of_pages = 2, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&unaligned), @sizeOf(memmap.MemoryDescriptor), unaligned.len);
    var st = State{};
    _ = st.init(view, &.{});
    try std.testing.expectEqual(@as(u64, 1), st.total_pages);
    const a = st.alloc_pages(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x101000), a);
}

test "alloc: free_pages bounds-checks alignment and span" {
    var st = State{};
    _ = st.init(make_view(), &.{});
    try std.testing.expect(!st.free_pages(0x100001, 1)); // unaligned
    try std.testing.expect(!st.free_pages(0x100000 - 0x1000, 1)); // below base
    try std.testing.expect(!st.free_pages(0x100000, 32641)); // more than the whole span
    try std.testing.expect(!st.free_pages(0x90000000, 1)); // above the span end
    try std.testing.expect(!st.free_pages(0x100000, 0)); // zero pages
    // Freeing pages that were never allocated frees nothing.
    try std.testing.expect(!st.free_pages(0x100000, 1));
    try std.testing.expectEqual(@as(u64, 1152), st.free_count);
}

test "alloc: double free cannot inflate the free count" {
    var st = State{};
    _ = st.init(make_view(), &.{});
    const a = st.alloc_pages(4) orelse return error.TestUnexpectedResult;
    try std.testing.expect(st.free_pages(a, 4));
    try std.testing.expectEqual(@as(u64, 1152), st.free_count);
    // Second free of the same pages frees nothing and reports false.
    try std.testing.expect(!st.free_pages(a, 4));
    try std.testing.expectEqual(@as(u64, 1152), st.free_count);
}

test "alloc: reserve atomically removes pages from the pool" {
    var st = State{};
    _ = st.init(make_view(), &.{});
    try std.testing.expect(st.reserve(0x100000, 4));
    try std.testing.expectEqual(@as(u64, 1148), st.free_count);
    try std.testing.expect(!st.reserve(0x100000, 4)); // already reserved
    try std.testing.expectEqual(@as(u64, 1148), st.free_count); // atomic: unchanged
    // The reserved run is not allocatable; the next run is after it.
    const a = st.alloc_pages(4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x104000), a);
    try std.testing.expect(st.free_pages(0x100000, 4));
    try std.testing.expectEqual(@as(u64, 1148), st.free_count);
}

test "alloc: largest_free_run reports the biggest contiguous run" {
    var st = State{};
    _ = st.init(make_view(), &.{});
    // The regions are not contiguous, so the biggest single run is the
    // 960-page conventional region.
    try std.testing.expectEqual(@as(u64, 960), st.largest_free_run());
    const a = st.alloc_pages(300) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 660), st.largest_free_run());
    try std.testing.expect(st.free_pages(a, 300));
    try std.testing.expectEqual(@as(u64, 960), st.largest_free_run());
}

test "alloc: init is resettable (a second map rebuilds the pool)" {
    var st = State{};
    _ = st.init(make_view(), &.{});
    const a = st.alloc_pages(1) orelse return error.TestUnexpectedResult;
    _ = a;
    try std.testing.expectEqual(@as(u64, 1151), st.free_count);
    // Re-init with the same map resets the bitmap: all 1152 pages free again.
    try std.testing.expect(st.init(make_view(), &.{}));
    try std.testing.expectEqual(@as(u64, 1152), st.free_count);
    try std.testing.expect(st.alloc_pages(1) != null);
}

test "alloc: regions beyond the 4 GiB bitmap span are untracked" {
    const far = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 4, .attribute = 0 },
        // Starts at exactly bitmap_base + 4 GiB — past the span cap.
        .{ .type = .conventional_memory, .physical_start = 0x1_0010_0000, .virtual_start = 0, .number_of_pages = 4, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&far), @sizeOf(memmap.MemoryDescriptor), far.len);
    var st = State{};
    _ = st.init(view, &.{});
    try std.testing.expectEqual(@as(u64, 4), st.total_pages);
    const a = st.alloc_pages(4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), a);
    try std.testing.expect(st.alloc_pages(1) == null); // the far region is untracked
}

test "alloc: more than max_regions pools the first max_regions in map order" {
    var many: [max_regions + 4]memmap.MemoryDescriptor = undefined;
    for (0..many.len) |i| {
        many[i] = .{
            .type = .conventional_memory,
            .physical_start = 0x100000 + @as(u64, i) * 0x2000, // 2 pages each, 8 KiB apart
            .virtual_start = 0,
            .number_of_pages = 2,
            .attribute = 0,
        };
    }
    const view = memmap.MapView.init(std.mem.asBytes(&many), @sizeOf(memmap.MemoryDescriptor), many.len);
    var st = State{};
    _ = st.init(view, &.{});
    try std.testing.expectEqual(@as(usize, max_regions), st.region_count);
    try std.testing.expectEqual(@as(u64, max_regions * 2), st.total_pages);
    try std.testing.expectEqual(@as(u64, max_regions * 2), st.free_count);
}

test "alloc: exclusions protect pooled pages and reduce free" {
    var st = State{};
    // Exclude the first 4 pages of the loader region (0x7000000..0x703fff).
    const exclusions = [_]Exclusion{.{ .base = 0x7000000, .pages = 4 }};
    try std.testing.expect(st.init(make_view(), &exclusions));
    const s = st.stats();
    try std.testing.expectEqual(@as(u64, 1152), s.total_pages);
    try std.testing.expectEqual(@as(u64, 1148), s.free_pages);
    try std.testing.expectEqual(@as(u64, 4), s.excluded_pages);
    // Conventional first, then the loader minus its excluded head (the
    // first free loader page is 0x7004000 because 0x7000000..0x7003fff is
    // excluded).
    try std.testing.expectEqual(@as(u64, 0x100000), (st.alloc_pages(960) orelse return error.TestUnexpectedResult));
    try std.testing.expectEqual(@as(u64, 0x7004000), (st.alloc_pages(60) orelse return error.TestUnexpectedResult));
    // An alloc that would need the excluded head must not land there.
    const b = st.alloc_pages(64) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x8000000), b); // boot region, never 0x7000000
    try std.testing.expectEqual(@as(u64, 128 - 64), st.free_count);
    try std.testing.expect(st.free_pages(0x100000, 960));
    try std.testing.expect(st.free_pages(0x704000, 60));
    try std.testing.expect(st.free_pages(0x8000000, 64));
    try std.testing.expectEqual(@as(u64, 1148), st.free_count);
}

test "alloc: exclusions over gaps are no-ops" {
    var st = State{};
    // 0x1000000..0x100ffff is the mmio gap — not pooled, so excluding it
    // must change nothing (its bits were already set).
    const exclusions = [_]Exclusion{.{ .base = 0x1000000, .pages = 16 }};
    try std.testing.expect(st.init(make_view(), &exclusions));
    const s = st.stats();
    try std.testing.expectEqual(@as(u64, 1152), s.total_pages);
    try std.testing.expectEqual(@as(u64, 1152), s.free_pages);
    try std.testing.expectEqual(@as(u64, 0), s.excluded_pages);
}

test "alloc: exclusions outside the span are ignored" {
    var st = State{};
    // Above the span end (0x8080000) and below the base (0x100000).
    const exclusions = [_]Exclusion{
        .{ .base = 0x90000000, .pages = 8 },
        .{ .base = 0x0, .pages = 4 },
    };
    try std.testing.expect(st.init(make_view(), &exclusions));
    const s = st.stats();
    try std.testing.expectEqual(@as(u64, 1152), s.total_pages);
    try std.testing.expectEqual(@as(u64, 1152), s.free_pages);
    try std.testing.expectEqual(@as(u64, 0), s.excluded_pages);
}

test "alloc: an exclusion covering a whole pooled region empties it" {
    var st = State{};
    const exclusions = [_]Exclusion{.{ .base = 0x7000000, .pages = 64 }};
    try std.testing.expect(st.init(make_view(), &exclusions));
    const s = st.stats();
    try std.testing.expectEqual(@as(u64, 1088), s.free_pages);
    try std.testing.expectEqual(@as(u64, 64), s.excluded_pages);
    try std.testing.expectEqual(@as(u64, 0x100000), (st.alloc_pages(960) orelse return error.TestUnexpectedResult));
    try std.testing.expectEqual(@as(u64, 0x8000000), (st.alloc_pages(128) orelse return error.TestUnexpectedResult));
    try std.testing.expect(st.alloc_pages(1) == null); // loader region is gone
}

test "alloc: an exclusion can span two regions and the gap between them" {
    var st = State{};
    // Covers the loader tail (last 8 pages: 0x7038000..0x703ffff), the gap,
    // and the boot head (first 2 pages: 0x8000000..0x8001fff).
    const exclusions = [_]Exclusion{.{ .base = 0x7038000, .pages = (0x8002000 - 0x7038000) / page_size }};
    try std.testing.expect(st.init(make_view(), &exclusions));
    const s = st.stats();
    try std.testing.expectEqual(@as(u64, 10), s.excluded_pages);
    try std.testing.expectEqual(@as(u64, 1142), s.free_pages);
    try std.testing.expectEqual(@as(u64, 0x100000), (st.alloc_pages(960) orelse return error.TestUnexpectedResult));
    // Loader has 56 usable pages left (its tail is excluded).
    try std.testing.expectEqual(@as(u64, 0x7000000), (st.alloc_pages(56) orelse return error.TestUnexpectedResult));
    // Boot has 126 usable pages (its head is excluded).
    try std.testing.expectEqual(@as(u64, 0x8002000), (st.alloc_pages(126) orelse return error.TestUnexpectedResult));
    try std.testing.expect(st.alloc_pages(1) == null);
}

test "alloc: exclusion_from_bytes rounds base down and size up" {
    // Aligned base, exact page.
    var ex = exclusion_from_bytes(0x100000, 0x1000);
    try std.testing.expectEqual(@as(u64, 0x100000), ex.base);
    try std.testing.expectEqual(@as(u64, 1), ex.pages);
    // Unaligned base + sub-page size protects the whole containing page(s).
    ex = exclusion_from_bytes(0x100001, 0x1000);
    try std.testing.expectEqual(@as(u64, 0x100000), ex.base);
    try std.testing.expectEqual(@as(u64, 2), ex.pages);
    // Zero bytes is a no-op.
    ex = exclusion_from_bytes(0x100000, 0);
    try std.testing.expectEqual(@as(u64, 0), ex.pages);
}

test "alloc: init with exclusions is resettable" {
    var st = State{};
    const first = [_]Exclusion{.{ .base = 0x7000000, .pages = 64 }};
    try std.testing.expect(st.init(make_view(), &first));
    try std.testing.expectEqual(@as(u64, 64), st.stats().excluded_pages);
    // Re-init with different exclusions rebuilds the pool from scratch.
    const second = [_]Exclusion{.{ .base = 0x8000000, .pages = 8 }};
    try std.testing.expect(st.init(make_view(), &second));
    const s = st.stats();
    try std.testing.expectEqual(@as(u64, 8), s.excluded_pages);
    try std.testing.expectEqual(@as(u64, 1144), s.free_pages);
}

test "alloc: boundary first-fit policy pins first-fit order over best-fit" {
    var st = State{};
    try std.testing.expect(st.init(make_view(), &.{}));

    // Largest run in make_view() is 960 pages at 0x100000.
    const big = st.alloc_pages(960) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), big);

    // Next 1-page alloc wraps into the fragmented remainder (loader_code region at 0x7000000).
    const wrap1 = st.alloc_pages(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x7000000), wrap1);

    // Free the big run mid-way.
    try std.testing.expect(st.free_pages(big, 960));

    // Next 1-page alloc lands at 0x100000 (first-fit scans from lower index, picking 0x100000
    // even though loader_code has a 63-page hole at 0x7001000).
    const wrap2 = st.alloc_pages(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), wrap2);

    // Explicit first-fit vs best-fit check using custom regions:
    // Hole A at 0x100000 (size 10 pages), Hole B at 0x200000 (size 2 pages).
    const custom_descriptors = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 10, .attribute = 0 },
        .{ .type = .conventional_memory, .physical_start = 0x200000, .virtual_start = 0, .number_of_pages = 2, .attribute = 0 },
    };
    const c_view = memmap.MapView.init(std.mem.asBytes(&custom_descriptors), @sizeOf(memmap.MemoryDescriptor), custom_descriptors.len);
    var st_fit = State{};
    try std.testing.expect(st_fit.init(c_view, &.{}));

    // Allocating 2 pages: first-fit scans from low address, finding Hole A (10 pages) first,
    // so it allocates 2 pages at 0x100000 (not Hole B at 0x200000, which best-fit would choose).
    const fit2 = st_fit.alloc_pages(2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), fit2);
}

test "alloc: span edges, max_span_pages bounds, and untracked tail bits" {
    const full_span = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = max_span_pages, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&full_span), @sizeOf(memmap.MemoryDescriptor), full_span.len);
    var st = State{};
    try std.testing.expect(st.init(view, &.{}));

    // Reserve 1 page: max_span_pages alloc must now fail.
    try std.testing.expect(st.reserve(0x100000, 1));
    try std.testing.expect(st.alloc_pages(max_span_pages) == null);

    // Unreserve (free) the reserved page.
    try std.testing.expect(st.free_pages(0x100000, 1));

    // Now alloc max_span_pages succeeds (returns base 0x100000).
    const all = st.alloc_pages(max_span_pages) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), all);
    try std.testing.expectEqual(@as(u64, 0), st.free_count);

    // Tail bits past span_pages are never addressable:
    const small_span = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 10, .attribute = 0 },
    };
    const s_view = memmap.MapView.init(std.mem.asBytes(&small_span), @sizeOf(memmap.MemoryDescriptor), small_span.len);
    var st_tail = State{};
    try std.testing.expect(st_tail.init(s_view, &.{}));

    // Allocating the last pooled page (index 9, address 0x109000) works.
    const last = st_tail.alloc_pages(10) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), last);

    // Address past span (0x10a000 = index 10) is not allocatable or freeable.
    try std.testing.expect(st_tail.alloc_pages(1) == null);
    try std.testing.expect(!st_tail.free_pages(0x10a000, 1));
}

test "alloc: free-path guards (boundary cross, re-alloc double free, unaligned, zero)" {
    var st = State{};
    try std.testing.expect(st.init(make_view(), &.{}));

    // free_pages(base, 0) returns false.
    try std.testing.expect(!st.free_pages(0x100000, 0));

    // free_pages on unaligned bases returns false.
    try std.testing.expect(!st.free_pages(0x100001, 1));
    try std.testing.expect(!st.free_pages(0x100800, 1));

    // Double free after re-alloc:
    const p1 = st.alloc_pages(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), p1);
    try std.testing.expect(st.free_pages(p1, 1));

    // Re-alloc gets p1 again.
    const p2 = st.alloc_pages(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), p2);

    // First free of p2 succeeds.
    try std.testing.expect(st.free_pages(p2, 1));
    const free_after_first = st.free_count;

    // Second free of p2 (double free) is rejected and does not inflate free_count.
    try std.testing.expect(!st.free_pages(p2, 1));
    try std.testing.expectEqual(free_after_first, st.free_count);

    // Free crossing region boundary:
    // Region 1: conventional (4 pages at 0x100000), Region 2: loader_code (4 pages at 0x104000).
    const multi_reg = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 4, .attribute = 0 },
        .{ .type = .loader_code, .physical_start = 0x104000, .virtual_start = 0, .number_of_pages = 4, .attribute = 0 },
    };
    const m_view = memmap.MapView.init(std.mem.asBytes(&multi_reg), @sizeOf(memmap.MemoryDescriptor), multi_reg.len);
    var st_multi = State{};
    try std.testing.expect(st_multi.init(m_view, &.{}));

    // Alloc 8 pages spanning across the conventional + loader_code region boundary.
    const cross_alloc = st_multi.alloc_pages(8) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), cross_alloc);
    try std.testing.expectEqual(@as(u64, 0), st_multi.free_count);

    // Free with n crossing from Region 1 into Region 2.
    try std.testing.expect(st_multi.free_pages(cross_alloc, 8));
    try std.testing.expectEqual(@as(u64, 8), st_multi.free_count);
}

test "alloc: middle exclusion leaves both ends allocatable and protects excluded span" {
    // Region: 10 pages at 0x100000 (0x100000..0x109fff).
    const region = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 10, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&region), @sizeOf(memmap.MemoryDescriptor), region.len);

    // Exclusion in middle: 2 pages at 0x104000 (pages index 4 and 5).
    const exclusions = [_]Exclusion{.{ .base = 0x104000, .pages = 2 }};

    var st = State{};
    try std.testing.expect(st.init(view, &exclusions));
    try std.testing.expectEqual(@as(u64, 10), st.total_pages);
    try std.testing.expectEqual(@as(u64, 2), st.excluded_pages);
    try std.testing.expectEqual(@as(u64, 8), st.free_count);

    // Head end (0x100000, 4 pages) is allocatable.
    const head = st.alloc_pages(4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), head);

    // Tail end (0x106000, 4 pages) is allocatable.
    const tail = st.alloc_pages(4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x106000), tail);

    // Middle (excluded span 0x104000..0x105fff) is never allocated.
    try std.testing.expect(st.alloc_pages(1) == null);

    // Alloc/free around exclusion does not disturb protected bits or stats.
    try std.testing.expect(st.free_pages(head, 4));
    try std.testing.expect(st.free_pages(tail, 4));

    try std.testing.expectEqual(@as(u64, 8), st.free_count);
    try std.testing.expectEqual(@as(u64, 2), st.excluded_pages);

    // Confirm excluded span was not freed by freeing adjacent spans.
    const new_head = st.alloc_pages(4) orelse return error.TestUnexpectedResult;
    const new_tail = st.alloc_pages(4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), new_head);
    try std.testing.expectEqual(@as(u64, 0x106000), new_tail);
    try std.testing.expect(st.alloc_pages(1) == null);
}

test "alloc: reset isolation and uninited state contract" {
    // Uninited state: unarmed, alloc returns null, free returns false.
    var raw = State{};
    try std.testing.expect(!raw.armed);
    try std.testing.expect(raw.alloc_pages(1) == null);
    try std.testing.expect(!raw.free_pages(0x100000, 1));
    try std.testing.expect(!raw.reserve(0x100000, 1));
    try std.testing.expectEqual(@as(u64, 0), raw.largest_free_run());
    try std.testing.expect(!raw.stats().armed);

    // Two init calls back to back:
    const map1_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 20, .attribute = 0 },
    };
    const view1 = memmap.MapView.init(std.mem.asBytes(&map1_desc), @sizeOf(memmap.MemoryDescriptor), map1_desc.len);
    const ex1 = [_]Exclusion{.{ .base = 0x100000, .pages = 4 }};

    var st = State{};
    try std.testing.expect(st.init(view1, &ex1));
    const alloc1 = st.alloc_pages(5) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x104000), alloc1);
    try std.testing.expect(st.reserve(0x10a000, 2));

    // Immediately re-init with map2: 4 pages at 0x500000, no exclusions.
    const map2_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x500000, .virtual_start = 0, .number_of_pages = 4, .attribute = 0 },
    };
    const view2 = memmap.MapView.init(std.mem.asBytes(&map2_desc), @sizeOf(memmap.MemoryDescriptor), map2_desc.len);

    try std.testing.expect(st.init(view2, &.{}));

    const s = st.stats();
    try std.testing.expect(s.armed);
    try std.testing.expectEqual(@as(u64, 4), s.total_pages);
    try std.testing.expectEqual(@as(u64, 4), s.free_pages);
    try std.testing.expectEqual(@as(u64, 0), s.excluded_pages);
    try std.testing.expectEqual(@as(usize, 1), s.region_count);

    // Alloc lands in map2 space.
    const alloc2 = st.alloc_pages(4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x500000), alloc2);

    // Old address from map1 is rejected by free.
    try std.testing.expect(!st.free_pages(0x104000, 5));
}

test "alloc: ref_page and unref_page lifecycle" {
    reset_refcounts();
    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 10, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(init(view, &.{}));

    const pa = alloc_pages(1).?;
    try std.testing.expectEqual(@as(u16, 1), page_refcount(pa));

    // Share page (2 owners)
    try std.testing.expect(ref_page(pa));
    try std.testing.expectEqual(@as(u16, 2), page_refcount(pa));

    // Share again (3 owners)
    try std.testing.expect(ref_page(pa));
    try std.testing.expectEqual(@as(u16, 3), page_refcount(pa));

    // First unref (down to 2, not freed)
    try std.testing.expect(!unref_page(pa));
    try std.testing.expectEqual(@as(u16, 2), page_refcount(pa));

    // Second unref (down to 1, not freed)
    try std.testing.expect(!unref_page(pa));
    try std.testing.expectEqual(@as(u16, 1), page_refcount(pa));

    // Final unref (down to 0, freed)
    try std.testing.expect(unref_page(pa));
    try std.testing.expectEqual(@as(u64, 10), stats().free_pages);
}

test "alloc: M133a — inject_fail_nth fails exactly the Nth call, then disarms" {
    defer alloc.inject_fail_nth(0);
    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 8, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(init(view, &.{}));

    // n=1: the very next call fails, consuming no page; the one after lands.
    alloc.inject_fail_nth(1);
    try std.testing.expectEqual(@as(u64, 1), alloc.inject_remaining_calls());
    try std.testing.expect(alloc_pages(1) == null);
    try std.testing.expectEqual(@as(u64, 0), alloc.inject_remaining_calls());
    try std.testing.expectEqual(@as(u64, 8), stats().free_pages);
    const first = alloc_pages(1).?;
    defer _ = free_pages(first, 1);

    // n=3: calls 1 and 2 succeed, call 3 is refused, call 4 succeeds.
    alloc.inject_fail_nth(3);
    const a = alloc_pages(1).?;
    defer _ = free_pages(a, 1);
    const b = alloc_pages(1).?;
    defer _ = free_pages(b, 1);
    try std.testing.expect(alloc_pages(1) == null);
    try std.testing.expectEqual(@as(u64, 0), alloc.inject_remaining_calls());
    const c = alloc_pages(1).?;
    defer _ = free_pages(c, 1);
    try std.testing.expectEqual(@as(u64, 4), stats().free_pages);

    // n=0 disarms a still-armed hook.
    alloc.inject_fail_nth(2);
    alloc.inject_fail_nth(0);
    const d = alloc_pages(1).?;
    defer _ = free_pages(d, 1);
    const e = alloc_pages(1).?;
    defer _ = free_pages(e, 1);
}
