const std = @import("std");
const discovery = @import("discovery.zig");
const fs = discovery.fs;
const t = std.testing;

fn meta(kind: fs.Kind, filesystem: u64, inode: u64) fs.Metadata {
    var value = std.mem.zeroes(fs.Metadata);
    value.version = 1;
    value.kind = kind;
    value.identity = .{ .filesystem = filesystem, .inode = inode };
    value.host_mode = if (kind == .directory) 0o040755 else 0o100644;
    return value;
}
const Node = struct { path: []const u8, metadata: fs.Metadata };
const Tree = struct {
    nodes: []const Node,
    live: usize = 0,
    peak: usize = 0,
    relative: []const u8 = "",
    replacement: bool = false,
    page_failure: bool = false,
    close_failure: bool = false,

    pub fn metadata(self: *Tree, _: []const u8, relative: []const u8) !fs.Metadata {
        if (relative.len == 0) return meta(.directory, 1, 1);
        for (self.nodes) |node| {
            if (std.mem.eql(u8, node.path, relative)) {
                var value = node.metadata;
                if (self.replacement) value.identity.inode += 1000;
                return value;
            }
        }
        return error.FileNotFound;
    }
    pub fn openSnapshot(self: *Tree, _: []const u8, relative: []const u8) !fs.Snapshot {
        try t.expectEqual(@as(usize, 0), self.live);
        self.live += 1;
        self.peak = @max(self.peak, self.live);
        self.relative = relative;
        return .{ .token = 1 };
    }
    pub fn closeSnapshot(self: *Tree, _: fs.Snapshot) !void {
        try t.expectEqual(@as(usize, 1), self.live);
        if (self.close_failure) return error.CloseFailed;
        self.live -= 1;
    }
    pub fn snapshotPage(self: *Tree, _: fs.Snapshot, offset: u64, limit: usize, page: *fs.Page) !void {
        if (self.page_failure) return error.AccessDenied;
        page.* = std.mem.zeroes(fs.Page);
        var seen: usize = 0;
        var count: usize = 0;
        for (self.nodes) |node| {
            const parent = if (std.mem.lastIndexOfScalar(u8, node.path, '/')) |slash| node.path[0..slash] else "";
            if (!std.mem.eql(u8, parent, self.relative)) continue;
            defer seen += 1;
            if (seen < offset or count == limit) continue;
            const basename = node.path[parent.len + @intFromBool(parent.len != 0) ..];
            @memcpy(page.entries[count].name[0..basename.len], basename);
            page.entries[count].name_len = @intCast(basename.len);
            page.entries[count].metadata = node.metadata;
            count += 1;
        }
        page.header = .{ .next = offset + count, .count = @intCast(count), .end = @intFromBool(offset + count == seen) };
    }
};

test "native inventory counts ignored entries and empty directories at aggregate 256/257" {
    var nodes: [257]Node = undefined;
    nodes[0] = .{ .path = "ignored", .metadata = meta(.directory, 1, 2) };
    nodes[1] = .{ .path = "empty", .metadata = meta(.directory, 1, 3) };
    var names: [255][32]u8 = undefined;
    for (nodes[2..], 0..) |*node, i| {
        node.* = .{
            .path = try std.fmt.bufPrint(&names[i], "ignored/file-{d}.txt", .{i}),
            .metadata = meta(.file, 1, 10 + i),
        };
    }
    var exact = Tree{ .nodes = nodes[0..256] };
    var inventory = try discovery.discover(&exact, t.allocator, "/host/content");
    defer inventory.deinit();
    try t.expectEqual(@as(usize, 256), inventory.entries.items.len);
    try t.expectEqual(@as(usize, 1), exact.peak);
    try t.expectEqual(@as(usize, 0), exact.live);
    var over = Tree{ .nodes = &nodes };
    try t.expectError(error.TreeLimit, discovery.discover(&over, t.allocator, "/host/content"));
    try t.expectEqual(@as(usize, 0), over.live);
}

test "directory identities include filesystem discriminator and refuse real reentry" {
    var nodes = [_]Node{
        .{ .path = "a", .metadata = meta(.directory, 1, 2) },
        .{ .path = "b", .metadata = meta(.directory, 2, 2) },
    };
    var tree = Tree{ .nodes = &nodes };
    var inventory = try discovery.discover(&tree, t.allocator, "/host/content");
    inventory.deinit();
    nodes[1].metadata.identity.filesystem = 1;
    try t.expectError(error.SymlinkCycle, discovery.discover(&tree, t.allocator, "/host/content"));
    try t.expectEqual(@as(usize, 0), tree.live);
}

test "replacement and snapshot errors refuse and close materialized traversal" {
    const nodes = [_]Node{.{ .path = "a", .metadata = meta(.directory, 1, 2) }};
    var tree = Tree{ .nodes = &nodes, .replacement = true };
    try t.expectError(error.TreeChanged, discovery.discover(&tree, t.allocator, "/host/content"));
    tree.replacement = false;
    tree.page_failure = true;
    try t.expectError(error.AccessDenied, discovery.discover(&tree, t.allocator, "/host/content"));
    try t.expectEqual(@as(usize, 0), tree.live);
    tree.close_failure = true;
    try t.expectError(error.CloseFailed, discovery.discover(&tree, t.allocator, "/host/content"));
    try t.expectEqual(@as(usize, 1), tree.live); // Retryable, not false cleanup success.
    tree.close_failure = false;
    try tree.closeSnapshot(.{ .token = 1 });
}

test "native relative path depth eight and nine, and root-dependent 512 byte limit" {
    const node = [_]Node{.{ .path = "a/b/c/d/e/f/g/h", .metadata = meta(.file, 1, 2) }};
    // Direct root rows in a mock still pass through the real B3 path validator.
    try fs.rootedPath("/host/content", node[0].path);
    try t.expectError(error.ResourceLimit, fs.rootedPath("/host/content", "a/b/c/d/e/f/g/h/i"));
    try fs.rootedPath("/host/content", &@as([255:0]u8, @splat("x"[0])) ++ "/" ++ &@as([242:0]u8, @splat("y"[0])));
    try t.expectError(error.NameTooLong, fs.rootedPath("/host/content", &@as([255:0]u8, @splat("x"[0])) ++ "/" ++ &@as([243:0]u8, @splat("y"[0]))));
}

fn allocatingWalk(allocator: std.mem.Allocator) !void {
    const nodes = [_]Node{
        .{ .path = "ignored", .metadata = meta(.directory, 1, 2) },
        .{ .path = "ignored/long-name.txt", .metadata = meta(.file, 1, 3) },
    };
    var tree = Tree{ .nodes = &nodes };
    defer std.debug.assert(tree.live == 0);
    var inventory = try discovery.discover(&tree, allocator, "/host/content");
    defer inventory.deinit();
}
test "every traversal allocation failure releases cursor and retained paths" {
    try t.checkAllAllocationFailures(t.allocator, allocatingWalk, .{});
}

const ReadDriver = struct {
    var input: []const u8 = "";
    var at: usize = 0;
    var opens: usize = 0;
    var closes: usize = 0;
    var read_error = false;
    var replaced = false;
    var changed_during_read = false;
    pub const filesystem_b2 = true;
    pub fn instance() *anyopaque {
        @panic("missing test backend");
    }
    pub fn diagnostic(_: []const u8) void {}
    pub fn fatal(_: []const u8) noreturn {
        @panic("unexpected fatal");
    }
    pub fn call(number: u64, args: [6]u64) i64 {
        switch (number) {
            79 => {
                switch (args[0]) {
                    1 => {
                        const identity: *fs.Identity = @ptrFromInt(args[5]);
                        identity.* = .{ .filesystem = 1, .inode = 1 };
                        return 0;
                    },
                    2 => {
                        opens += 1;
                        at = 0;
                        return 0;
                    },
                    10 => {
                        const value: *fs.Metadata = @ptrFromInt(args[5]);
                        value.* = meta(.file, 1, if (replaced) 3 else 2);
                        value.size = input.len;
                        if (changed_during_read and at != 0) value.mtime.seconds = 1;
                        return 0;
                    },
                    else => @panic("forbidden path-stat or mutation"),
                }
            },
            24 => {
                if (read_error) return -1;
                const n = @min(args[2], input.len - at, 17); // Short fills.
                const out: [*]u8 = @ptrFromInt(args[1]);
                @memcpy(out[0..n], input[at..][0..n]);
                at += n;
                return @intCast(n);
            },
            26 => {
                closes += 1;
                return 0;
            },
            else => @panic("forbidden native operation"),
        }
    }
    fn reset(bytes: []const u8) void {
        input = bytes;
        at = 0;
        opens = 0;
        closes = 0;
        read_error = false;
        replaced = false;
        changed_during_read = false;
    }
};
const ReadBackend = @import("sdk").io_helpers.Backend(ReadDriver);
fn inventoryFor(entries: []discovery.Entry) discovery.Inventory {
    return .{
        .allocator = t.allocator,
        .root_identity = .{ .filesystem = 1, .inode = 1 },
        .entries = .{ .items = entries, .capacity = entries.len },
    };
}

test "contained capture probes file/aggregate limits and propagates native read errors" {
    const bytes = try t.allocator.alloc(u8, 131073);
    defer t.allocator.free(bytes);
    @memset(bytes, 'x');
    var entries: [9]discovery.Entry = undefined;
    for (&entries) |*entry| entry.* = .{ .path = "ignored.txt", .metadata = meta(.file, 1, 2) };
    var backend: ReadBackend = .{};
    for ([_]usize{ 131072, 131073 }) |length| {
        ReadDriver.reset(bytes[0..length]);
        entries[0].metadata.size = length;
        const inventory = inventoryFor(entries[0..1]);
        if (length == 131072) {
            var captured = try discovery.capture(&backend, t.allocator, "/host/content", &inventory);
            defer captured.deinit();
            try t.expectEqual(length, captured.bytes);
        } else {
            try t.expectError(error.InputLimit, discovery.capture(&backend, t.allocator, "/host/content", &inventory));
        }
        try t.expectEqual(ReadDriver.opens, ReadDriver.closes);
        try t.expectEqual(@as(usize, 0), backend.liveFiles());
    }
    ReadDriver.reset(bytes[0..131072]);
    for (&entries) |*entry| entry.metadata.size = 131072;
    var exact = inventoryFor(entries[0..8]);
    var captured = try discovery.capture(&backend, t.allocator, "/host/content", &exact);
    captured.deinit();
    exact = inventoryFor(&entries);
    try t.expectError(error.InputLimit, discovery.capture(&backend, t.allocator, "/host/content", &exact));
    ReadDriver.read_error = true;
    const one = inventoryFor(entries[0..1]);
    try t.expectError(error.InputOutput, discovery.capture(&backend, t.allocator, "/host/content", &one));
    try t.expectEqual(ReadDriver.opens, ReadDriver.closes);
}

fn allocatingCapture(allocator: std.mem.Allocator) !void {
    ReadDriver.reset("native input");
    var entries = [_]discovery.Entry{.{ .path = "page.md", .metadata = meta(.file, 1, 2) }};
    entries[0].metadata.size = ReadDriver.input.len;
    const inventory = inventoryFor(&entries);
    var backend: ReadBackend = .{};
    defer std.debug.assert(ReadDriver.opens == ReadDriver.closes and backend.liveFiles() == 0);
    var captured = try discovery.capture(&backend, allocator, "/host/content", &inventory);
    defer captured.deinit();
}
test "every capture allocation failure releases contained file and retained input" {
    try t.checkAllAllocationFailures(t.allocator, allocatingCapture, .{});
}

test "actual file identity replacement and in-read attribute changes refuse before retaining input" {
    ReadDriver.reset("native input");
    var entries = [_]discovery.Entry{.{ .path = "page.md", .metadata = meta(.file, 1, 2) }};
    entries[0].metadata.size = ReadDriver.input.len;
    const inventory = inventoryFor(&entries);
    var backend: ReadBackend = .{};
    ReadDriver.replaced = true;
    try t.expectError(error.SourceChanged, discovery.capture(&backend, t.allocator, "/host/content", &inventory));
    try t.expectEqual(@as(usize, 0), ReadDriver.at);
    ReadDriver.replaced = false;
    ReadDriver.changed_during_read = true;
    try t.expectError(error.SourceChanged, discovery.capture(&backend, t.allocator, "/host/content", &inventory));
    try t.expectEqual(ReadDriver.opens, ReadDriver.closes);
    try t.expectEqual(@as(usize, 0), backend.liveFiles());
}
