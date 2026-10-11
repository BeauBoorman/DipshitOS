//! QJS allocations use the existing SDK allocator, not another arena.
//! Charged 4 KiB granules bound its otherwise unpolled free-list traversal.
const std = @import("std");
const memory = @import("arena");

pub const arena_bytes = 4 * 1024 * 1024;
pub const granule = 4096;
pub const maximum_initial_free_nodes = 5;
const magic: usize = 0x514a53414c4c4f43;
const Header = struct {
    previous: ?*Header,
    next: ?*Header,
    reserved: usize,
    charged: usize,
    owner: *Bridge,
    tag: usize,
    engine: bool,
};
const header_bytes = std.mem.alignForward(usize, @sizeOf(Header), 16);
pub const maximum_bridge_blocks = (arena_bytes - 32) / (granule + 16);
// Coalescing separates every two free nodes with a live allocation. Each
// such QJS allocation costs >=4096+16 bytes, and each free node costs >=16.
// Add the initial free nodes around immutable SDK state. Their allocation
// count is irrelevant: no non-QJS allocation changes while the bridge lives.
pub const maximum_sdk_nodes = (arena_bytes - 32) / (granule + 16 + 16) + maximum_initial_free_nodes;

comptime {
    if (maximum_sdk_nodes > 1024) @compileError("QuickJS SDK traversal bound exceeds ADR 0039");
}

pub const Poll = struct {
    context: *anyopaque,
    check: *const fn (*anyopaque) bool,

    fn ready(self: Poll) bool {
        return self.check(self.context);
    }
};

pub const Bridge = struct {
    arena: memory.Arena,
    poll: Poll,
    head: ?*Header = null,
    blocks: usize = 0,
    oom: bool = false,
    expected_used: usize,
    engine_allocations: bool = false,

    /// The runtime owns allocation during engine boundaries. Its fixed SDK
    /// state leaves at most five free nodes; adapter buffers use Bridge.
    /// No callback may allocate directly from the SDK or enter another eval.
    pub fn init(arena: memory.Arena, poll: Poll) Bridge {
        var fixed_nodes: usize = 0;
        var cursor = arena.state.head;
        while (cursor) |node| : (cursor = node.next) {
            fixed_nodes += 1;
            std.debug.assert(fixed_nodes <= maximum_initial_free_nodes);
        }
        return .{ .arena = arena, .poll = poll, .expected_used = arena.used() };
    }

    pub fn allocate(self: *Bridge, requested: usize) ?[*]u8 {
        if (!self.poll.ready()) return null;
        std.debug.assert(self.arena.used() == self.expected_used);
        const total = std.math.add(usize, requested, header_bytes) catch return self.refuse();
        if (total > arena_bytes - (granule - 1)) return self.refuse();
        const reserved = std.mem.alignForward(usize, @max(total, granule), granule);
        const block = self.arena.allocator().alloc(u8, reserved) catch return self.refuse();
        const charged = self.arena.used() - self.expected_used;
        self.expected_used += charged;
        const h: *Header = @ptrCast(@alignCast(block.ptr));
        h.* = .{
            .previous = null,
            .next = self.head,
            .reserved = reserved,
            .charged = charged,
            .owner = self,
            .tag = magic,
            .engine = self.engine_allocations,
        };
        if (self.head) |first| first.previous = h;
        self.head = h;
        self.blocks += 1;
        std.debug.assert(self.blocks <= maximum_bridge_blocks);
        _ = self.poll.ready();
        std.debug.assert(self.arena.used() == self.expected_used);
        return block.ptr + header_bytes;
    }

    fn refuse(self: *Bridge) ?[*]u8 {
        self.oom = true;
        return null;
    }

    fn header(self: *Bridge, ptr: [*]const u8) *Header {
        const result: *Header = @ptrFromInt(@intFromPtr(ptr) - header_bytes);
        std.debug.assert(result.tag == magic and result.owner == self);
        return result;
    }

    pub fn usable(self: *Bridge, ptr: ?[*]const u8) usize {
        const p = ptr orelse return 0;
        return self.header(p).reserved - header_bytes;
    }

    pub fn release(self: *Bridge, ptr: ?[*]u8) void {
        const p = ptr orelse return;
        // Cancellation never abandons a free or teardown halfway through.
        _ = self.poll.ready();
        std.debug.assert(self.arena.used() == self.expected_used);
        const h = self.header(p);
        const reserved = h.reserved;
        const charged = h.charged;
        if (h.previous) |previous| previous.next = h.next else self.head = h.next;
        if (h.next) |next| next.previous = h.previous;
        h.tag = 0;
        self.blocks -= 1;
        const bytes: [*]u8 = @ptrCast(h);
        self.arena.allocator().free(bytes[0..reserved]);
        self.expected_used -= charged;
        std.debug.assert(self.arena.used() == self.expected_used);
        _ = self.poll.ready();
    }

    /// Both allocations, alignment waste and SDK headers stay charged until
    /// the copy completes. Failure preserves the original allocation.
    pub fn resize(self: *Bridge, ptr: ?[*]u8, requested: usize) ?[*]u8 {
        if (requested == 0) {
            self.release(ptr);
            return null;
        }
        const old = ptr orelse return self.allocate(requested);
        // QuickJS sizes arrays and string buffers from malloc_usable_size and
        // fills that slack, so the old contents extend past the last request.
        const old_usable = self.usable(old);
        const next = self.allocate(requested) orelse return null;
        const count = @min(old_usable, requested);
        var offset: usize = 0;
        while (offset < count) {
            if (!self.poll.ready()) {
                self.release(next);
                return null;
            }
            const end = @min(count, offset + 1024);
            @memcpy(next[offset..end], old[offset..end]);
            offset = end;
        }
        self.release(old);
        return next;
    }

    pub fn releaseAll(self: *Bridge) void {
        while (self.head) |first| {
            const bytes: [*]u8 = @ptrCast(first);
            self.release(bytes + header_bytes);
        }
    }

    pub fn releaseEngine(self: *Bridge) void {
        var cursor = self.head;
        while (cursor) |h| {
            cursor = h.next;
            if (h.engine) {
                const bytes: [*]u8 = @ptrCast(h);
                self.release(bytes + header_bytes);
            }
        }
    }
};

const TestPoll = struct {
    calls: usize = 0,
    cancel_at: usize = std.math.maxInt(usize),

    fn check(context: *anyopaque) bool {
        const self: *TestPoll = @ptrCast(@alignCast(context));
        self.calls += 1;
        return self.calls < self.cancel_at;
    }

    fn get(self: *TestPoll) Poll {
        return .{ .context = self, .check = check };
    }
};

fn nodeCount(arena: memory.Arena) usize {
    var count: usize = 0;
    var cursor = arena.state.head;
    while (cursor) |node| : (cursor = node.next) count += 1;
    return count;
}

test "granule charging bounds fragmentation without a second allocator" {
    const backing = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(memory.page_bytes), arena_bytes);
    defer std.testing.allocator.free(backing);
    const arena = try memory.Arena.init(backing);
    const base = arena.used();
    var poll: TestPoll = .{};
    var bridge = Bridge.init(arena, poll.get());
    var slots: [maximum_bridge_blocks]?[*]u8 = @splat(null);
    var count: usize = 0;
    while (bridge.allocate(700)) |block| {
        slots[count] = block;
        count += 1;
    }
    try std.testing.expect(bridge.oom);
    try std.testing.expectEqual(maximum_bridge_blocks, count);
    try std.testing.expect(arena.peak() <= arena_bytes);
    for (&slots, 0..) |*slot, i| if (i % 2 == 0) {
        bridge.release(slot.*);
        slot.* = null;
    };
    try std.testing.expect(nodeCount(arena) <= maximum_sdk_nodes);
    bridge.release(slots[1]);
    slots[1] = null;
    const larger = bridge.allocate(4096) orelse return error.TestUnexpectedResult;
    bridge.release(larger);
    for (slots) |slot| bridge.release(slot);
    try std.testing.expectEqual(@as(usize, 0), bridge.blocks);
    try std.testing.expectEqual(base, arena.used());
}

test "granules charge metadata and expose only owned usable bytes" {
    var backing: [4 * granule]u8 align(granule) = undefined;
    const arena = try memory.Arena.init(&backing);
    const base = arena.used();
    var poll: TestPoll = .{};
    var bridge = Bridge.init(arena, poll.get());
    const first = bridge.allocate(1).?;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(first) % 16);
    try std.testing.expectEqual(granule + 16, arena.used() - base);
    try std.testing.expectEqual(granule - header_bytes, bridge.usable(first));
    try std.testing.expectEqual(@as(usize, 0), bridge.usable(null));
    bridge.release(first);
    bridge.release(null);
    const again = bridge.allocate(1).?;
    try std.testing.expectEqual(@intFromPtr(first), @intFromPtr(again));
    bridge.releaseAll();
    try std.testing.expectEqual(base, arena.used());
    try std.testing.expect(bridge.allocate(std.math.maxInt(usize)) == null);
    try std.testing.expect(bridge.oom);
}

test "resize charges both blocks and cancellation preserves the original" {
    var backing: [8 * granule]u8 align(granule) = undefined;
    const arena = try memory.Arena.init(&backing);
    const base = arena.used();
    var poll: TestPoll = .{};
    var bridge = Bridge.init(arena, poll.get());
    const first = bridge.allocate(3000).?;
    @memset(first[0..3000], 0x5a);
    const next = bridge.resize(first, 6000).?;
    try std.testing.expectEqualSlices(u8, &(@as([3000]u8, @splat(@as(u8, 0x5a)))), next[0..3000]);
    try std.testing.expect(arena.peak() >= base + granule + 16 + 2 * granule + 16);
    poll.cancel_at = poll.calls + 4;
    try std.testing.expect(bridge.resize(next, 7000) == null);
    try std.testing.expectEqual(@as(usize, 1), bridge.blocks);
    try std.testing.expectEqualSlices(u8, &(@as([3000]u8, @splat(@as(u8, 0x5a)))), next[0..3000]);
    bridge.releaseAll();
    try std.testing.expectEqual(base, arena.used());
}

test "resize preserves the usable slack a caller may have filled" {
    var backing: [8 * granule]u8 align(granule) = undefined;
    const arena = try memory.Arena.init(&backing);
    const base = arena.used();
    var poll: TestPoll = .{};
    var bridge = Bridge.init(arena, poll.get());
    const first = bridge.allocate(1000).?;
    const usable = bridge.usable(first);
    try std.testing.expect(usable > 1000);
    for (first[0..usable], 0..) |*byte, i| byte.* = @truncate(i *% 7 +% 1);
    const grown = bridge.resize(first, usable + 1).?;
    try std.testing.expect(bridge.usable(grown) >= usable + 1);
    for (grown[0..usable], 0..) |byte, i| try std.testing.expectEqual(@as(u8, @truncate(i *% 7 +% 1)), byte);
    const shrunk = bridge.resize(grown, 100).?;
    for (shrunk[0..100], 0..) |byte, i| try std.testing.expectEqual(@as(u8, @truncate(i *% 7 +% 1)), byte);
    bridge.releaseAll();
    try std.testing.expectEqual(base, arena.used());
}

test "deterministic churn bounds every SDK traversal by its free-list length" {
    const backing = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(memory.page_bytes), arena_bytes);
    defer std.testing.allocator.free(backing);
    const arena = try memory.Arena.init(backing);
    const base = arena.used();
    var poll: TestPoll = .{};
    var bridge = Bridge.init(arena, poll.get());
    var slots: [1024]?[*]u8 = @splat(null);
    var prng = std.Random.DefaultPrng.init(1934);
    const random = prng.random();
    for (0..10000) |_| {
        const index = random.uintLessThan(usize, slots.len);
        if (slots[index]) |block| {
            bridge.release(block);
            slots[index] = null;
        } else {
            slots[index] = bridge.allocate(random.uintLessThan(usize, 8192) + 1);
        }
        try std.testing.expect(nodeCount(arena) <= maximum_sdk_nodes);
    }
    bridge.releaseAll();
    try std.testing.expectEqual(base, arena.used());
}

test "immutable SDK state and four existing holes preserve the traversal bound" {
    const backing = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(memory.page_bytes), arena_bytes);
    defer std.testing.allocator.free(backing);
    const arena = try memory.Arena.init(backing);
    const sdk_allocator = arena.allocator();
    const initial = arena.used();
    var fixed: [8][]u8 = undefined;
    for (&fixed) |*block| block.* = try sdk_allocator.alloc(u8, 16);
    for (fixed, 0..) |block, i| if (i % 2 == 0) sdk_allocator.free(block);
    try std.testing.expectEqual(maximum_initial_free_nodes, nodeCount(arena));
    const base = arena.used();
    var poll: TestPoll = .{};
    var bridge = Bridge.init(arena, poll.get());
    while (bridge.allocate(1)) |_| {}
    try std.testing.expect(bridge.oom);
    try std.testing.expect(nodeCount(arena) <= maximum_sdk_nodes);
    bridge.releaseAll();
    try std.testing.expectEqual(base, arena.used());
    for (fixed, 0..) |block, i| if (i % 2 == 1) sdk_allocator.free(block);
    try std.testing.expectEqual(initial, arena.used());
}
