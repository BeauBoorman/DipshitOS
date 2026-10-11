fn repeat_lit(comptime lit: []const u8, comptime n: usize) *const [n * lit.len:0]u8 {
    if (n == 0) return "";
    return lit ++ repeat_lit(lit, n - 1);
}
const std = @import("std");
const publication = @import("publication.zig");
const fs = @import("sdk").fs;
const t = std.testing;
const Record = struct { path: []const u8, bytes: []const u8 };
const records = [_]Record{
    .{ .path = "index.html", .bytes = "new home\n" },
    .{ .path = "nested/deep/long-shared-name-more-than-thirty-one-bytes.html", .bytes = "nested page\n" },
};
const Node = struct { path: []const u8, bytes: []const u8 = "", directory: bool, inode: u64 };
const Pin = struct { token: i64, path: [512]u8, len: usize };
const Tree = struct {
    nodes: std.ArrayList(Node) = .empty,
    pins: [4]?Pin = @splat(null),
    next: i64 = 1,
    next_inode: u64 = 2,
    peak: usize = 0,
    live_file: bool = false,
    entropy: usize = 0,
    entropy_error: bool = false,
    write_error: bool = false,
    sync_error: bool = false,
    rename_error: ?usize = null,
    renames: usize = 0,
    mutations: usize = 0,
    creation_lost: bool = false,

    fn deinit(self: *Tree) void {
        for (self.nodes.items) |entry| {
            t.allocator.free(entry.path);
            t.allocator.free(entry.bytes);
        }
        self.nodes.deinit(t.allocator);
    }
    fn add(self: *Tree, full: []const u8, directory: bool, bytes: []const u8) !void {
        const retained = try t.allocator.dupe(u8, full);
        errdefer t.allocator.free(retained);
        const data = try t.allocator.dupe(u8, bytes);
        errdefer t.allocator.free(data);
        try self.nodes.append(t.allocator, .{ .path = retained, .bytes = data, .directory = directory, .inode = self.next_inode });
        self.next_inode += 1;
    }
    fn node(self: *Tree, full: []const u8) ?usize {
        for (self.nodes.items, 0..) |entry, i| if (std.mem.eql(u8, entry.path, full)) return i;
        return null;
    }
    fn live(self: *Tree) usize {
        var count: usize = @intFromBool(self.live_file);
        for (self.pins) |value| if (value != null) {
            count += 1;
        };
        return count;
    }
    fn pin(self: *Tree, full: []const u8) !fs.Directory {
        if (self.live() == 4) return error.ResourceLimit;
        const index = self.node(full) orelse return error.FileNotFound;
        if (!self.nodes.items[index].directory) return error.InvalidArgument;
        for (&self.pins) |*slot| if (slot.* == null) {
            var value = Pin{ .token = self.next, .path = undefined, .len = full.len };
            @memcpy(value.path[0..full.len], full);
            self.next += 1;
            slot.* = value;
            self.peak = @max(self.peak, self.live());
            return .{ .token = value.token };
        };
        return error.ResourceLimit;
    }
    fn path(self: *Tree, dir: fs.Directory) ![]const u8 {
        for (&self.pins) |*slot| if (slot.*) |*value| {
            if (value.token == dir.token) return value.path[0..value.len];
        };
        return error.InvalidHandle;
    }
    fn name(self: *Tree, dir: fs.Directory, leaf: []const u8) ![]u8 {
        try fs.entryName(leaf);
        const root = try self.path(dir);
        return std.fmt.allocPrint(t.allocator, "{s}/{s}", .{ root, leaf });
    }
    pub fn openDirectory(self: *Tree, root: []const u8, _: []const u8) !fs.Directory {
        return self.pin(root);
    }
    pub fn openChildDirectory(self: *Tree, dir: fs.Directory, leaf: []const u8) !fs.Directory {
        const full = try self.name(dir, leaf);
        defer t.allocator.free(full);
        return self.pin(full);
    }
    pub fn closeDirectory(self: *Tree, dir: fs.Directory) !void {
        for (&self.pins) |*slot| if (slot.*) |value| {
            if (value.token == dir.token) {
                slot.* = null;
                return;
            }
        };
        return error.InvalidHandle;
    }
    pub fn directoryMetadata(self: *Tree, dir: fs.Directory) !fs.Metadata {
        return self.metadata(try self.path(dir), "");
    }
    pub fn metadata(self: *Tree, root: []const u8, _: []const u8) !fs.Metadata {
        const index = self.node(root) orelse return error.FileNotFound;
        var value = std.mem.zeroes(fs.Metadata);
        value.kind = if (self.nodes.items[index].directory) .directory else .file;
        value.identity = .{ .filesystem = 1, .inode = self.nodes.items[index].inode };
        value.size = self.nodes.items[index].bytes.len;
        return value;
    }
    pub fn makeDirectory(self: *Tree, dir: fs.Directory, leaf: []const u8) !fs.Directory {
        const full = try self.name(dir, leaf);
        defer t.allocator.free(full);
        if (self.node(full) != null) return error.PathAlreadyExists;
        if (self.live() == 4) return error.ResourceLimit;
        try self.add(full, true, "");
        self.mutations += 1;
        if (self.creation_lost) return error.TransportFailure;
        return self.pin(full);
    }
    const Io = struct {
        tree: *Tree,
        pub fn randomSecure(self: Io, output: []u8) !void {
            self.tree.entropy += 1;
            try t.expectEqual(@as(usize, 0), self.tree.mutations);
            if (self.tree.entropy_error) return error.EntropyUnavailable;
            @memset(output, 0xa7);
        }
    };
    pub fn io(self: *Tree) Io {
        return .{ .tree = self };
    }
    const File = struct {
        index: usize,
        pub fn writeStreamingAll(self: File, stream: Io, bytes: []const u8) !void {
            if (stream.tree.write_error) return error.WriteFailed;
            const retained = try t.allocator.dupe(u8, bytes);
            t.allocator.free(stream.tree.nodes.items[self.index].bytes);
            stream.tree.nodes.items[self.index].bytes = retained;
        }
        pub fn sync(_: File, stream: Io) !void {
            if (stream.tree.sync_error) return error.SyncFailed;
        }
    };
    pub fn createExclusive(self: *Tree, dir: fs.Directory, leaf: []const u8) !File {
        const full = try self.name(dir, leaf);
        defer t.allocator.free(full);
        if (self.node(full) != null) return error.PathAlreadyExists;
        try t.expect(!self.live_file);
        if (self.live() == 4) return error.ResourceLimit;
        try self.add(full, false, "");
        self.live_file = true;
        self.peak = @max(self.peak, self.live());
        self.mutations += 1;
        return .{ .index = self.nodes.items.len - 1 };
    }
    pub fn closeChecked(self: *Tree, _: File) !void {
        try t.expect(self.live_file);
        self.live_file = false;
    }
    pub fn fileMetadata(self: *Tree, file: File) !fs.Metadata {
        return self.metadata(self.nodes.items[file.index].path, "");
    }
    pub fn rename(self: *Tree, from_dir: fs.Directory, from: []const u8, to_dir: fs.Directory, to: []const u8, _: fs.Publication) !void {
        const source = try self.name(from_dir, from);
        defer t.allocator.free(source);
        const destination = try self.name(to_dir, to);
        defer t.allocator.free(destination);
        const index = self.node(source) orelse return error.FileNotFound;
        if (self.rename_error == self.renames) return error.TransportFailure;
        if (self.node(destination)) |old| {
            if (self.nodes.items[old].directory) return error.InvalidArgument;
            // Replace bytes without changing the array's file indices.
            const bytes = try t.allocator.dupe(u8, self.nodes.items[index].bytes);
            t.allocator.free(self.nodes.items[old].bytes);
            self.nodes.items[old].bytes = bytes;
            t.allocator.free(self.nodes.items[index].path);
            t.allocator.free(self.nodes.items[index].bytes);
            _ = self.nodes.orderedRemove(index);
        } else {
            const retained = try t.allocator.dupe(u8, destination);
            t.allocator.free(self.nodes.items[index].path);
            self.nodes.items[index].path = retained;
        }
        self.renames += 1;
    }
    pub fn removeDirectory(self: *Tree, dir: fs.Directory, leaf: []const u8) !void {
        const full = try self.name(dir, leaf);
        defer t.allocator.free(full);
        const index = self.node(full) orelse return error.FileNotFound;
        try t.expect(self.nodes.items[index].directory);
        for (self.nodes.items) |entry| {
            if (entry.path.len > full.len and std.mem.startsWith(u8, entry.path, full) and entry.path[full.len] == '/')
                return error.PathAlreadyExists;
        }
        t.allocator.free(self.nodes.items[index].path);
        t.allocator.free(self.nodes.items[index].bytes);
        _ = self.nodes.orderedRemove(index);
    }
};
fn setup() !Tree {
    var tree: Tree = .{};
    errdefer tree.deinit();
    try tree.add("/host/content", true, "");
    try tree.add("/host/site", true, "");
    try tree.add("/host/site/index.html", false, "prior-good-site\n");
    return tree;
}

test "contained serial publication stages and syncs before deterministic entry replacements" {
    var tree = try setup();
    defer tree.deinit();
    for (0..2) |_| {
        tree.mutations = 0;
        var state: publication.State = .{};
        try publication.publish(&tree, t.allocator, "/host/content", "/host/site", &records, &state);
        try t.expectEqual(records.len, state.published);
        try t.expect(!state.staged);
        try t.expectEqual(@as(usize, 0), tree.live());
        try t.expect(tree.peak <= 4);
        for (records) |record| {
            const full = try std.fmt.allocPrint(t.allocator, "/host/site/{s}", .{record.path});
            defer t.allocator.free(full);
            try t.expectEqualStrings(record.bytes, tree.nodes.items[tree.node(full).?].bytes);
        }
        for (tree.nodes.items) |entry| try t.expect(std.mem.indexOf(u8, entry.path, ".boris-stage-") == null);
    }
}

test "entropy and staging write/sync failures preserve prior outputs and never rename" {
    for (0..3) |failure| {
        var tree = try setup();
        defer tree.deinit();
        tree.entropy_error = failure == 0;
        tree.write_error = failure == 1;
        tree.sync_error = failure == 2;
        var state: publication.State = .{};
        try t.expectError(switch (failure) {
            0 => error.EntropyUnavailable,
            1 => error.WriteFailed,
            else => error.SyncFailed,
        }, publication.publish(&tree, t.allocator, "/host/content", "/host/site", &records, &state));
        try t.expectEqualStrings("prior-good-site\n", tree.nodes.items[tree.node("/host/site/index.html").?].bytes);
        try t.expectEqual(@as(usize, 0), tree.renames);
        try t.expectEqual(@as(usize, 0), tree.live());
        try t.expectEqual(failure != 0, state.staged);
        if (failure == 0) try t.expectEqual(@as(usize, 0), tree.mutations);
    }
}

test "late publication failure reports partial progress without rollback or destination deletion" {
    var tree = try setup();
    defer tree.deinit();
    tree.rename_error = 1;
    var state: publication.State = .{};
    try t.expectError(error.TransportFailure, publication.publish(&tree, t.allocator, "/host/content", "/host/site", &records, &state));
    try t.expectEqual(@as(usize, 1), state.published);
    try t.expect(state.submitted and state.staged);
    try t.expectEqualStrings(records[0].bytes, tree.nodes.items[tree.node("/host/site/index.html").?].bytes);
    try t.expectEqual(@as(usize, 0), tree.live());
}

test "root collisions and invalid artifact trees refuse before entropy and mutation" {
    for ([_][]const u8{ "/host/content", "/host/content/site", "/host", "/host/site/../content" }) |out|
        try t.expectError(if (std.mem.indexOf(u8, out, "..") != null) error.InvalidArgument else error.TargetOutputCollision, publication.validateRoots("/host/content", out));
    var tree = try setup();
    defer tree.deinit();
    var state: publication.State = .{};
    const conflict = [_]Record{ .{ .path = "a", .bytes = "a" }, .{ .path = "a/b", .bytes = "b" } };
    try t.expectError(error.InvalidArtifactTree, publication.publish(&tree, t.allocator, "/host/content", "/host/site", &conflict, &state));
    try t.expectEqual(@as(usize, 0), tree.entropy);
    try t.expectEqual(@as(usize, 0), tree.mutations);
}

test "occupied stage names never truncate and unknown creation never pretends no mutation" {
    for ([_]bool{ false, true }) |unknown| {
        var tree = try setup();
        defer tree.deinit();
        const stage_path = "/host/site/.boris-stage-" ++ repeat_lit("a7", 16);
        if (unknown) {
            tree.creation_lost = true;
        } else {
            try tree.add(stage_path, false, "not our stage\n");
        }
        var state: publication.State = .{};
        try t.expectError(if (unknown) error.TransportFailure else error.PathAlreadyExists, publication.publish(&tree, t.allocator, "/host/content", "/host/site", &records, &state));
        try t.expectEqual(unknown, state.stage_uncertain);
        try t.expect(!state.staged and state.published == 0);
        try t.expectEqual(@as(usize, 0), tree.live());
        if (!unknown) try t.expectEqualStrings("not our stage\n", tree.nodes.items[tree.node(stage_path).?].bytes);
    }
}

fn allocatingPublish(allocator: std.mem.Allocator) !void {
    var tree = try setup();
    defer tree.deinit();
    defer std.debug.assert(tree.live() == 0);
    var state: publication.State = .{};
    try publication.publish(&tree, allocator, "/host/content", "/host/site", &records, &state);
}
test "every publisher arena allocation failure closes rolling pins and files" {
    try t.checkAllAllocationFailures(t.allocator, allocatingPublish, .{});
}

test "staging full path exact and one over refuse before mutation" {
    var tree = try setup();
    defer tree.deinit();
    var state: publication.State = .{};
    const exact = [_]Record{.{ .path = &@as([255:0]u8, @splat("x"[0])) ++ "/" ++ &@as([199:0]u8, @splat("y"[0])), .bytes = "bounded\n" }};
    try publication.publish(&tree, t.allocator, "/host/content", "/host/site", &exact, &state);
    try t.expectEqual(@as(usize, 1), state.published);
    tree.mutations = 0;
    const entropy_before = tree.entropy;
    const over = [_]Record{.{ .path = &@as([255:0]u8, @splat("x"[0])) ++ "/" ++ &@as([200:0]u8, @splat("y"[0])), .bytes = "bounded\n" }};
    state = .{};
    try t.expectError(error.NameTooLong, publication.publish(&tree, t.allocator, "/host/content", "/host/site", &over, &state));
    try t.expectEqual(entropy_before, tree.entropy);
    try t.expectEqual(@as(usize, 0), tree.mutations);
}
