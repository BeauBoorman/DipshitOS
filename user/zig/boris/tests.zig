const std = @import("std");
const policy = @import("policy.zig");
const core = @import("core.zig");
const fixture = @import("fixture.zig");
const boris = @import("boris");
const t = std.testing;
comptime {
    _ = @import("workspace.zig");
    _ = @import("memory.zig");
    _ = @import("discovery_test.zig");
    _ = @import("publication_test.zig");
}

test "compiler corpus retains Oliver, nested identities, includes, assets and offline evidence" {
    var result = try core.compile(t.io, t.allocator, &fixture.files);
    defer result.deinit();
    try t.expectEqual(@as(usize, 20), result.result.pages.items.len);
    const html = result.artifacts.get("index.html").?;
    try t.expect(std.mem.indexOf(u8, html, "A shared <em>tip</em>") != null);
    try t.expect(std.mem.indexOf(u8, html, "guides/intro.html") != null);
    try t.expectEqualStrings(fixture.files[4].bytes, result.artifacts.get(fixture.files[4].path).?);
    for ([_][]const u8{ "manifest.json", "graph.json", "completion.json", "build-report.json", "_boris/proof/artifacts.json", "_boris/proof/checks.json", "_boris/proof/claims.json", "_boris/proof/touches.json" }) |name|
        try t.expect(result.artifacts.get(name) != null);
}

test "two compilations and reversed source order are byte identical" {
    var first = try core.compile(t.io, t.allocator, &fixture.files);
    defer first.deinit();
    var reversed = fixture.files;
    std.mem.reverse(boris.SourceFile, &reversed);
    var second = try core.compile(t.io, t.allocator, &reversed);
    defer second.deinit();
    try t.expectEqual(first.artifacts.items().len, second.artifacts.items().len);
    for (first.artifacts.items()) |record|
        try t.expectEqualStrings(record.bytes, second.artifacts.get(record.path).?);
}

test "invalid author input refuses before any successful compiler result" {
    try t.expectError(error.CompilationFailed, core.compile(t.io, t.allocator, &.{
        .{ .path = "index.md", .bytes = "---\ntitle: Home\nparent: missing\n---\n# Home\n" },
    }));
    try t.expectError(error.DuplicatePath, core.compile(t.io, t.allocator, &.{
        .{ .path = "index.md", .bytes = "# First\n" },
        .{ .path = "index.md", .bytes = "# Second\n" },
    }));
    try t.expectError(error.PathLimit, core.compile(t.io, t.allocator, &.{
        .{ .path = "../escape.md", .bytes = "# Escape\n" },
    }));
}

test "unsupported product surfaces and parallel options refuse explicitly" {
    for ([_][]const u8{ "watch", "preview", "serve", "publish", "auth", "login", "keys", "editor", "--watch", "--preview", "--online", "--capture" }) |name|
        try t.expectError(error.UnsupportedFeature, policy.parse(&.{name}));
    for ([_][]const u8{ "--jobs=1", "--jobs=2", "--jobs", "--jobs=0" }) |name|
        try t.expectError(error.UnsupportedParallelism, policy.parse(&.{ "probe", name }));
    try t.expectEqual(policy.Command.build, try policy.parse(&.{ "build", "/host/content", "/host/site" }));
    try t.expectEqual(policy.Command.compile, try policy.parse(&.{ "compile", "/host/content" }));
    try t.expectError(error.Usage, policy.parse(&.{"build"}));
    try t.expectError(error.Usage, policy.parse(&.{}));
}

test "path component full path and nesting exact and over boundaries" {
    try policy.path(&@as([255:0]u8, @splat("x"[0])));
    try t.expectError(error.PathLimit, policy.path(&@as([256:0]u8, @splat("x"[0]))));
    try policy.path(&@as([255:0]u8, @splat("x"[0])) ++ "/" ++ &@as([250:0]u8, @splat("y"[0])));
    try t.expectError(error.PathLimit, policy.path(&@as([255:0]u8, @splat("x"[0])) ++ "/" ++ &@as([251:0]u8, @splat("y"[0]))));
    try policy.path("a/b/c/d/e/f/g/h/i");
    try t.expectError(error.TreeLimit, policy.path("a/b/c/d/e/f/g/h/i/j"));
    for ([_][]const u8{ "", "/a", "../a", "a/./b", "a//b", "a/", "a\\b", "a\x00b", "a:b" }) |name|
        try t.expectError(error.PathLimit, policy.path(name));
}

test "per-file and aggregate input exact and over boundaries" {
    const bytes = try t.allocator.alloc(u8, policy.file_limit + 1);
    defer t.allocator.free(bytes);
    var files: [9]boris.SourceFile = undefined;
    for (&files) |*file| file.* = .{ .path = "a.md", .bytes = bytes[0..policy.file_limit] };
    try policy.inputs(files[0..8]);
    try t.expectError(error.InputLimit, policy.inputs(&files));
    files[0].bytes = bytes;
    try t.expectError(error.InputLimit, policy.inputs(files[0..1]));
}

test "visited-entry and emitted-artifact boundaries include directories and ignored files" {
    var files: [257]boris.SourceFile = undefined;
    for (&files) |*file| file.* = .{ .path = "ignored.txt", .bytes = "" };
    try policy.inputs(files[0..256]);
    try t.expectError(error.TreeLimit, policy.inputs(&files));
    files[0].path = "dir/ignored.txt";
    try t.expectError(error.TreeLimit, policy.inputs(files[0..256]));
    try policy.inputs(files[0..255]);
    var records: [129]struct { path: []const u8, bytes: []const u8 } = undefined;
    for (&records) |*record| record.* = .{ .path = "a.html", .bytes = "" };
    try policy.outputs(records[0..128]);
    try t.expectError(error.TreeLimit, policy.outputs(&records));
}

test "aggregate output exact and over boundaries" {
    const bytes = try t.allocator.alloc(u8, policy.output_limit + 1);
    defer t.allocator.free(bytes);
    const Record = struct { path: []const u8, bytes: []const u8 };
    try policy.outputs(&[_]Record{.{ .path = "a.html", .bytes = bytes[0..policy.output_limit] }});
    try t.expectError(error.OutputLimit, policy.outputs(&[_]Record{.{ .path = "a.html", .bytes = bytes }}));
}

test "real compiler accepts exact include recursion depth and refuses one beyond" {
    for ([_]usize{ 32, 33 }) |depth| {
        const files = try t.allocator.alloc(boris.SourceFile, depth + 2);
        defer t.allocator.free(files);
        files[0] = .{ .path = "index.md", .bytes = "# Home\n\n{{include includes/link-0.md}}\n" };
        files[1] = fixture.files[3];
        var initialized: usize = 2;
        defer for (files[2..initialized]) |file| {
            t.allocator.free(file.path);
            t.allocator.free(file.bytes);
        };
        for (0..depth) |i| {
            const path = try std.fmt.allocPrint(t.allocator, "includes/link-{d}.md", .{i});
            errdefer t.allocator.free(path);
            const bytes = if (i + 1 == depth)
                try t.allocator.dupe(u8, "Terminal include.\n")
            else
                try std.fmt.allocPrint(t.allocator, "{{{{include includes/link-{d}.md}}}}\n", .{i + 1});
            files[i + 2] = .{ .path = path, .bytes = bytes };
            initialized += 1;
        }
        if (depth == 32) {
            var result = try core.compile(t.io, t.allocator, files);
            defer result.deinit();
            try t.expect(std.mem.indexOf(u8, result.artifacts.get("index.html").?, "Terminal include.") != null);
        } else {
            try t.expectError(error.CompilationFailed, core.compile(t.io, t.allocator, files));
        }
    }
}
