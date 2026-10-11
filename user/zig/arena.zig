//! One retained populated mapping, address-ordered free list with coalescing.
//! All metadata, headers, and alignment waste are charged inside the mapping.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const page_bytes = 4096;
pub const max_bytes = 12 * 1024 * 1024;
pub const max_alignment = page_bytes;
const quantum = 16;
const Node = struct { len: usize, next: ?*Node };
const Allocation = struct { start: usize, len: usize };
const State = struct { head: ?*Node, capacity: usize, used: usize, peak: usize };
const state_bytes = std.mem.alignForward(usize, @sizeOf(State), quantum);

pub const Arena = struct {
    state: *State,

    pub fn init(memory: []align(quantum) u8) error{OutOfMemory}!Arena {
        if (memory.len < page_bytes or memory.len > max_bytes or memory.len % page_bytes != 0)
            return error.OutOfMemory;
        const state: *State = @ptrCast(memory.ptr);
        const node: *Node = @ptrCast(@alignCast(memory.ptr + state_bytes));
        node.* = .{ .len = memory.len - state_bytes, .next = null };
        state.* = .{ .head = node, .capacity = memory.len, .used = state_bytes, .peak = state_bytes };
        return .{ .state = state };
    }

    /// Invalid budgets and native reservation/population failures are both OOM.
    /// The caller must retain this Arena and must not reserve a second mapping.
    pub fn reserve(bytes: usize, map: *const fn (usize) ?[]align(page_bytes) u8) error{OutOfMemory}!Arena {
        if (bytes < page_bytes or bytes > max_bytes or bytes % page_bytes != 0)
            return error.OutOfMemory;
        const memory = map(bytes) orelse return error.OutOfMemory;
        return init(memory);
    }

    pub fn allocator(self: Arena) Allocator {
        return .{ .ptr = self.state, .vtable = &.{
            .alloc = alloc,
            .free = free,
            .resize = Allocator.noResize,
            .remap = Allocator.noRemap,
        } };
    }

    pub fn used(self: Arena) usize {
        return self.state.used;
    }

    pub fn peak(self: Arena) usize {
        return self.state.peak;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const state: *State = @ptrCast(@alignCast(ctx));
        const align_bytes = alignment.toByteUnits();
        if (align_bytes > max_alignment or len > state.capacity) return null;
        var link = &state.head;
        while (link.*) |node| {
            const start = @intFromPtr(node);
            const payload = std.mem.alignForward(usize, start + @sizeOf(Allocation), @max(quantum, align_bytes));
            const need = std.mem.alignForward(usize, payload - start + len, quantum);
            if (need > node.len) {
                link = &node.next;
                continue;
            }
            const consumed = if (node.len - need < @sizeOf(Node)) node.len else need;
            const next = node.next;
            const remaining = node.len - consumed;
            if (remaining > 0) {
                const tail: *Node = @ptrFromInt(start + consumed);
                tail.* = .{ .len = remaining, .next = next };
                link.* = tail;
            } else link.* = next;
            const header: *Allocation = @ptrFromInt(payload - @sizeOf(Allocation));
            header.* = .{ .start = start, .len = consumed };
            state.used += consumed;
            state.peak = @max(state.peak, state.used);
            return @ptrFromInt(payload);
        }
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
        const state: *State = @ptrCast(@alignCast(ctx));
        const addr = @intFromPtr(memory.ptr);
        const base = @intFromPtr(state);
        // The header read below touches [addr - @sizeOf(Allocation), addr):
        // keep every free inside the arena mapping.
        std.debug.assert(addr >= base + @sizeOf(Allocation) and addr <= base + state.capacity);
        const header: *const Allocation = @ptrFromInt(addr - @sizeOf(Allocation));
        const start = header.start;
        const len = header.len;
        var link = &state.head;
        var previous: ?*Node = null;
        while (link.*) |node| {
            if (@intFromPtr(node) > start) break;
            previous = node;
            link = &node.next;
        }
        const released: *Node = @ptrFromInt(start);
        released.* = .{ .len = len, .next = link.* };
        link.* = released;
        if (released.next) |next| {
            if (start + released.len == @intFromPtr(next)) {
                released.len += next.len;
                released.next = next.next;
            }
        }
        if (previous) |prev| {
            if (@intFromPtr(prev) + prev.len == start) {
                prev.len += released.len;
                prev.next = released.next;
            }
        }
        state.used -= len;
    }
};

test "arena: reusable free, coalescing both neighbors, accounting and fallback realloc" {
    var memory: [4 * page_bytes]u8 align(page_bytes) = undefined;
    const arena = try Arena.init(&memory);
    const a = arena.allocator();
    const base = arena.used();
    const first = try a.alloc(u8, 100);
    const middle = try a.alloc(u8, 300);
    const last = try a.alloc(u8, 200);
    @memset(middle, 0x5a);
    a.free(first);
    a.free(last);
    a.free(middle);
    try std.testing.expectEqual(base, arena.used());
    const again = try a.alloc(u8, 100);
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(again.ptr));
    @memset(again, 0x5a);
    const grown = try a.realloc(again, 200);
    try std.testing.expectEqualSlices(u8, &(@as([100]u8, @splat(@as(u8, 0x5a)))), grown[0..100]);
    a.free(grown);
    const largest = try a.alloc(u8, memory.len - base - @sizeOf(Allocation));
    try std.testing.expectEqual(memory.len, arena.used());
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    a.free(largest);
    try std.testing.expectEqual(base, arena.used());
    try std.testing.expectEqual(memory.len, arena.peak());
}

test "arena: alignment, overflow, zero-size and repeated churn" {
    var memory: [4 * page_bytes]u8 align(page_bytes) = undefined;
    const arena = try Arena.init(&memory);
    const a = arena.allocator();
    const base = arena.used();
    const empty = try a.alloc(u8, 0);
    a.free(empty);
    for (0..1000) |_| {
        const aligned = try a.alignedAlloc(u8, .fromByteUnits(page_bytes), 4097);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) % page_bytes);
        @memset(aligned, 0xa5);
        a.free(aligned);
    }
    try std.testing.expect(a.rawAlloc(1, .fromByteUnits(page_bytes * 2), 0) == null);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, std.math.maxInt(usize)));
    try std.testing.expectEqual(base, arena.used());
}

test "arena: bounds and failed native reservation are explicit" {
    const Mock = struct {
        var calls: usize = 0;
        fn fail(_: usize) ?[]align(page_bytes) u8 {
            calls += 1;
            return null;
        }
    };
    Mock.calls = 0;
    for ([_]usize{ 0, 1, page_bytes - 1, max_bytes + page_bytes, std.math.maxInt(usize) }) |size|
        try std.testing.expectError(error.OutOfMemory, Arena.reserve(size, Mock.fail));
    try std.testing.expectEqual(@as(usize, 0), Mock.calls);
    try std.testing.expectError(error.OutOfMemory, Arena.reserve(max_bytes, Mock.fail));
    try std.testing.expectEqual(@as(usize, 1), Mock.calls);
}

test "arena: maximum approved capacity includes metadata" {
    const memory = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(page_bytes), max_bytes);
    defer std.testing.allocator.free(memory);
    const arena = try Arena.init(memory);
    const a = arena.allocator();
    const payload = try a.alloc(u8, max_bytes - state_bytes - @sizeOf(Allocation));
    try std.testing.expectEqual(max_bytes, arena.used());
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    a.free(payload);
    try std.testing.expectEqual(state_bytes, arena.used());
}

test "arena: deterministic fragmented allocation contents survive reuse" {
    var memory: [64 * page_bytes]u8 align(page_bytes) = undefined;
    const arena = try Arena.init(&memory);
    const a = arena.allocator();
    var slots: [64]?[]u8 = @splat(null);
    var prng = std.Random.DefaultPrng.init(1866);
    const random = prng.random();
    for (0..4000) |_| {
        const index = random.uintLessThan(usize, slots.len);
        if (slots[index]) |bytes| {
            for (bytes) |byte| try std.testing.expectEqual(@as(u8, @intCast(index)), byte);
            a.free(bytes);
            slots[index] = null;
        } else {
            const size = random.uintLessThan(usize, 8192) + 1;
            const bytes = a.alloc(u8, size) catch continue;
            @memset(bytes, @intCast(index));
            slots[index] = bytes;
        }
    }
    for (slots) |slot| if (slot) |bytes| {
        a.free(bytes);
    };
    try std.testing.expectEqual(state_bytes, arena.used());
}
