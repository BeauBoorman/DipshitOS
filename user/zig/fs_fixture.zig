//! Shared-SDK EL0 acceptance only, not another allowlisted application.
const std = @import("std");
const sdk = @import("runtime.zig");
pub const virelai = sdk.platform;
pub const os = sdk.os;
pub const std_options = sdk.std_options;
pub const std_options_debug_io = sdk.std_options_debug_io;
pub const std_options_FilePermissions = sdk.std_options_FilePermissions;
pub const std_options_cwd = sdk.std_options_cwd;
pub const panic = std.debug.FullPanic(sdk.panic);
var checkpoint: []const u8 = "initialize";
var checks: usize = 0;

comptime {
    @import("entry.zig").exportEntry(run);
}

fn check(ok: bool) !void {
    if (!ok) {
        try sdk.print("zig-fs: FAIL ");
        try sdk.print(checkpoint);
        try sdk.print("\n");
        return error.Acceptance;
    }
    checks += 1;
}
fn refused(expected: anyerror, value: anytype) !void {
    if (value) |_| {
        try check(false);
    } else |err| try check(err == expected);
}
fn write(path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(sdk.io, path, .{});
    defer file.close(sdk.io);
    try file.writeStreamingAll(sdk.io, bytes);
    try file.sync(sdk.io);
}
fn read(file: std.Io.File, expected: []const u8) !void {
    var buffer: [64]u8 = undefined;
    const bytes = try sdk.io_helpers.readBounded(file, sdk.io, &buffer);
    try check(std.mem.eql(u8, bytes, expected));
}

fn publication() !void {
    checkpoint = "publication";
    const fs = sdk.filesystem();
    const cwd: std.Io.Dir = .cwd();
    try write("SDK/stage", "first publication\n");
    try cwd.rename("SDK/stage", cwd, "SDK/output", sdk.io);
    try write("SDK/stage", "second publication\n");
    try fs.publish("SDK/stage", "SDK/output", .replace);
    try write("SDK/stage", "retained stage\n");
    try refused(error.PathAlreadyExists, cwd.renamePreserve("SDK/stage", cwd, "SDK/output", sdk.io));
    try refused(error.FileNotFound, fs.publish("SDK/absent", "SDK/output", .replace));
    try refused(error.InvalidArgument, fs.publish("SDK/directory", "SDK/output", .replace));
    try refused(error.AccessDenied, fs.publish("SDK/denied", "SDK/output", .replace));
    try refused(error.AccessDenied, fs.publish("SDK/stage", "SDK/denied", .replace));
    try refused(error.AccessDenied, fs.publish("SDK/stage", "SDK/secret", .replace));
    try refused(error.Unexpected, cwd.createFile(sdk.io, "SDK/output", .{ .exclusive = true }));
    try refused(error.Unexpected, cwd.createFile(sdk.io, "SDK/output", .{ .resolve_beneath = true }));
    try sdk.print("zig-fs: publications=2 failure-preservation refusals=8\n");
}

fn discovery() !void {
    checkpoint = "discovery";
    const fs = sdk.filesystem();
    const root = "/host/SDK/content";
    const root_metadata = try fs.metadata(root, "");
    const root_id = try fs.identity(root, "");
    try check(root_id.eql(root_metadata.identity));
    const nested_id = try fs.identity(root, "nested");
    const deep_id = try fs.identity(root, "nested/deep");
    try check(!root_id.eql(nested_id) and !root_id.eql(deep_id) and !nested_id.eql(deep_id));
    const before = try fs.metadata(root, "nested/deep/page");
    try check(before.size == 4 and before.kind == .file);
    try check(before.identity.eql(try fs.identity(root, "nested/deep/page")));
    const cursor = try fs.openSnapshot(root, "");
    const receipt = try std.Io.Dir.cwd().createFile(sdk.io, "SDK/names", .{});
    const page = try sdk.os.heap.page_allocator.create(sdk.fs.Page);
    defer sdk.os.heap.page_allocator.destroy(page);
    var offset: u64 = 0;
    var pages: usize = 0;
    var long: usize = 0;
    while (true) {
        try fs.snapshotPage(cursor, offset, 7, page);
        pages += 1;
        for (page.rows()) |*entry| {
            const name = entry.nameBytes();
            try receipt.writeStreamingAll(sdk.io, name);
            try receipt.writeStreamingAll(sdk.io, "\n");
            if (name.len > 31) long += 1;
            try check(entry.metadata.identity.eql(try fs.identity(root, name)));
            try check(entry.metadata.size == (try fs.metadata(root, name)).size);
        }
        offset = page.header.next;
        if (page.done()) break;
    }
    try check(offset == 24 and pages == 4 and long == 3);
    try fs.snapshotPage(cursor, offset, 7, page);
    try check(page.done() and page.rows().len == 0);
    try receipt.sync(sdk.io);
    receipt.close(sdk.io);
    try fs.closeSnapshot(cursor);
    try refused(error.InvalidHandle, fs.snapshotPage(cursor, 0, 7, page));
    try sdk.print("zig-fs: rich rows=24 pages=4 long-names=3 identities=stable\n");

    checkpoint = "metadata freshness";
    const writer = try fs.openContained(root, "nested/deep/page", .write);
    // A real write and truncate change native metadata; no cached stat answer.
    try writer.writeStreamingAll(sdk.io, "safe!");
    try writer.setLength(sdk.io, 5);
    try writer.sync(sdk.io);
    writer.close(sdk.io);
    const after = try fs.metadata(root, "nested/deep/page");
    try check(after.size == 5 and after.identity.eql(before.identity));
    try check(after.mtime.toNanoseconds() != before.mtime.toNanoseconds());
    const mode = try fs.metadata(root, "entry-00");
    // Compare owner fields to the native wire, not macOS's uid namespace.
    // VZ's VirtioFS server can map ownership while preserving mode and times.
    var raw: [96]u8 align(8) = undefined;
    try check(sdk.native.call(79, .{
        0, @intFromPtr(root.ptr), root.len, @intFromPtr("entry-00"), 8, @intFromPtr(&raw),
    }) == 0);
    const native_uid = std.mem.readInt(u32, raw[84..88], .little);
    const native_gid = std.mem.readInt(u32, raw[88..92], .little);
    try check(mode.host_uid == native_uid and mode.host_gid == native_gid);
    var buffer: [192]u8 = undefined;
    try sdk.print(try std.fmt.bufPrint(&buffer, "zig-fs: native-owners uid={d} gid={d}\n", .{ native_uid, native_gid }));
    try sdk.print(try std.fmt.bufPrint(&buffer, "zig-fs: host-mode={d} uid={d} gid={d} size={d} mtime={d}\n", .{
        mode.host_mode, mode.host_uid, mode.host_gid, mode.size, mode.mtime.toNanoseconds(),
    }));
}

fn boundaries() !void {
    checkpoint = "path and entry bounds";
    const fs = sdk.filesystem();
    const exact = &@as([250:0]u8, @splat("a"[0])) ++ "/" ++ &@as([255:0]u8, @splat("b"[0]));
    _ = try fs.metadata("/host", exact);
    try refused(error.NameTooLong, fs.metadata("/host", exact ++ "c"));
    try refused(error.NameTooLong, fs.metadata("/host", &@as([256:0]u8, @splat("a"[0]))));
    _ = try fs.metadata("/host", "d/e/e/e/e/e/e/e");
    try refused(error.ResourceLimit, fs.metadata("/host", "d/e/e/e/e/e/e/e/e"));
    const cursor = try fs.openSnapshot("/host", "LIMIT");
    const page = try sdk.os.heap.page_allocator.create(sdk.fs.Page);
    defer sdk.os.heap.page_allocator.destroy(page);
    var offset: u64 = 0;
    while (true) {
        try fs.snapshotPage(cursor, offset, 16, page);
        offset = page.header.next;
        if (page.done()) break;
    }
    try check(offset == 256);
    try fs.closeSnapshot(cursor);
    try sdk.print("zig-fs: path=512 name=255 depth=8 entries=256 path-over refused\n");
}

fn containment() !void {
    checkpoint = "nofollow and guest ACLs";
    const fs = sdk.filesystem();
    for ([_][]const u8{ "LINKS/leaf", "LINKS/dir/deep/page", "LINKS/dangling", "denied", "secret", "denied-dir/leaf" }) |path| {
        try refused(error.AccessDenied, fs.metadata("/host/SDK", path));
        try refused(error.AccessDenied, fs.openContained("/host/SDK", path, .read));
    }
    try refused(error.AccessDenied, fs.openSnapshot("/host/SDK", "LINKS"));
    try refused(error.AccessDenied, fs.openSnapshot("/host/SDK/root-link", ""));
    try refused(error.AccessDenied, fs.openContained("/host/SDK/root-link", "nested/deep/page", .read));
    try sdk.print("zig-fs: nofollow and guest permissions refused=15\n");

    checkpoint = "pinned replacement";
    const reader = try fs.openContained("/host/SDK/content", "nested/deep/page", .read);
    const writer = try fs.openContained("/host/SDK/content", "nested/deep/page", .write);
    const opened = try fs.fileMetadata(reader);
    try check(opened.kind == .file and opened.size == 5);
    try fs.publish("SDK/content/nested", "SDK/parked", .replace);
    try fs.publish("SDK/SWAP", "SDK/content/nested", .replace);
    try refused(error.AccessDenied, fs.openContained("/host/SDK/content", "nested/deep/page", .read));
    try refused(error.AccessDenied, fs.metadata("/host/SDK/content", "nested/deep/page"));
    // The fd's own object, not whatever its old name now resolves to.
    try check((try fs.fileMetadata(reader)).identity.eql(opened.identity));
    try check(try reader.length(sdk.io) == 5);
    try refused(error.Unexpected, reader.stat(sdk.io));
    try read(reader, "safe!");
    try writer.writeStreamingAll(sdk.io, "pinned");
    try writer.setLength(sdk.io, 6);
    try writer.sync(sdk.io);
    try check(try reader.length(sdk.io) == 6);
    reader.close(sdk.io);
    writer.close(sdk.io);
    try fs.publish("SDK/content/nested", "SDK/SWAP", .replace);
    try fs.publish("SDK/parked", "SDK/content/nested", .replace);
    try sdk.print("zig-fs: pinned reads/writes/fd-metadata survive replacement; File.stat refused\n");
}

fn pinned() !void {
    checkpoint = "pinned publication";
    const fs = sdk.filesystem();
    const top = try fs.openDirectory("/host/SDK", "PUB");
    const top_metadata = try fs.directoryMetadata(top);
    try check(top_metadata.kind == .directory and top_metadata.identity.eql(try fs.identity("/host/SDK", "PUB")));
    const stage = try fs.makeDirectory(top, "stage");
    const assets = try fs.makeDirectory(stage, "assets");
    const page = try fs.createExclusive(stage, "index.html");
    try page.writeStreamingAll(sdk.io, "<p>sdk</p>\n");
    try page.sync(sdk.io);
    try check(try page.length(sdk.io) == 11);
    try check((try fs.fileMetadata(page)).identity.eql(try fs.identity("/host/SDK/PUB", "stage/index.html")));
    try check(fs.liveResources() == 8);
    try refused(error.ResourceLimit, fs.openDirectory("/host/SDK", "PUB"));
    page.close(sdk.io);
    try refused(error.PathAlreadyExists, fs.createExclusive(stage, "index.html"));
    try refused(error.PathAlreadyExists, fs.makeDirectory(stage, "assets"));
    const css = try fs.createExclusive(assets, "site.css");
    try css.writeStreamingAll(sdk.io, "p{}\n");
    try css.sync(sdk.io);
    css.close(sdk.io);
    try fs.closeDirectory(assets);
    // Boris's publish: swap, else park the old output, swap, drop the parked tree.
    try refused(error.PathAlreadyExists, fs.rename(top, "stage", top, "out", .preserve_existing));
    try fs.rename(top, "out", top, "out.prev", .preserve_existing);
    try fs.rename(top, "stage", top, "out", .preserve_existing);
    try refused(error.InvalidHandle, fs.createExclusive(stage, "late"));
    try refused(error.InvalidHandle, fs.directoryMetadata(stage));
    try fs.closeDirectory(stage);
    try refused(error.InvalidHandle, fs.closeDirectory(stage));
    const prev = try fs.openChildDirectory(top, "out.prev");
    try refused(error.PathAlreadyExists, fs.removeDirectory(top, "out.prev"));
    try refused(error.InvalidArgument, fs.removeFile(prev, "keep"));
    try fs.removeFile(prev, "old.html");
    try fs.removeDirectory(prev, "keep");
    try refused(error.FileNotFound, fs.removeFile(prev, "old.html"));
    try fs.closeDirectory(prev);
    try fs.removeDirectory(top, "out.prev");
    try sdk.print("zig-fs: pinned publication staged=4 swapped parked-removed stale-refusals=2\n");

    checkpoint = "pinned atomic replace and refusals";
    const out = try fs.openChildDirectory(top, "out");
    const next = try fs.createExclusive(out, "index.tmp");
    try next.writeStreamingAll(sdk.io, "<p>v2</p>\n");
    try next.sync(sdk.io);
    next.close(sdk.io);
    try refused(error.PathAlreadyExists, fs.rename(out, "index.tmp", out, "index.html", .preserve_existing));
    try fs.rename(out, "index.tmp", out, "index.html", .replace);
    const live = try fs.openContained("/host/SDK/PUB", "out/index.html", .read);
    try check(try live.length(sdk.io) == 10);
    try read(live, "<p>v2</p>\n");
    live.close(sdk.io);
    for ([_][]const u8{ "", ".", "..", "a/b", "nul\x00" }) |name|
        try refused(error.InvalidArgument, fs.createExclusive(out, name));
    try refused(error.NameTooLong, fs.createExclusive(out, &@as([256:0]u8, @splat("n"[0]))));
    try refused(error.AccessDenied, fs.openChildDirectory(top, "link"));
    try refused(error.AccessDenied, fs.removeFile(top, "link"));
    try refused(error.AccessDenied, fs.createExclusive(top, "denied"));
    try refused(error.AccessDenied, fs.removeFile(top, "secret"));
    try refused(error.AccessDenied, fs.rename(out, "index.html", top, "secret", .replace));
    try fs.closeDirectory(out);
    try fs.closeDirectory(top);
    try check(fs.liveResources() == 4);
    try sdk.print("zig-fs: pinned atomic replace; names symlinks and ACLs refused=11\n");
}

fn capacity() !void {
    checkpoint = "shared SDK resource table";
    const fs = sdk.filesystem();
    const file = try fs.openContained("/host/SDK/content", "nested/deep/page", .read);
    const legacy = try std.Io.Dir.cwd().openFile(sdk.io, "SDK/output", .{});
    // A path fd has no pinned object; no pathname is retained to emulate one.
    try refused(error.Unsupported, fs.fileMetadata(legacy));
    try refused(error.Unexpected, legacy.length(sdk.io));
    const a = try fs.openSnapshot("/host/SDK/content", "");
    const b = try fs.openSnapshot("/host/SDK/content", "nested");
    try check(fs.liveResources() == 8);
    try refused(error.ResourceLimit, fs.openSnapshot("/host/SDK", "directory"));
    try refused(error.ResourceLimit, fs.openDirectory("/host/SDK", "PUB"));
    try refused(error.ResourceLimit, fs.openContained("/host/SDK/content", "entry-00", .read));
    try refused(error.ProcessFdQuotaExceeded, std.Io.Dir.cwd().createFile(sdk.io, "SDK/overflow", .{}));
    try fs.closeSnapshot(a);
    const c = try fs.openSnapshot("/host/SDK/content", "");
    try check(c.token != a.token);
    try refused(error.InvalidHandle, fs.closeSnapshot(a));
    try fs.closeSnapshot(b);
    file.close(sdk.io);
    legacy.close(sdk.io);
    // c remains for normal SDK finish cleanup, together with three more.
    _ = try fs.openSnapshot("/host/SDK/content", "");
    _ = try fs.openSnapshot("/host/SDK/content", "");
    _ = try fs.openSnapshot("/host/SDK/content", "");
    try check(fs.liveResources() == 8);
    try sdk.print("zig-fs: resources=8 overflow refused finish-cursors=4\n");
}

fn run(args: *const sdk.startup.Startup) !void {
    try sdk.initialize(1024 * 1024);
    try check(args.argc == 2);
    if (std.mem.eql(u8, args.args[1], "bounds")) {
        try boundaries();
    } else if (std.mem.eql(u8, args.args[1], "over")) {
        checkpoint = "entry overflow";
        try refused(error.ResourceLimit, sdk.filesystem().openSnapshot("/host", "OVER"));
        try check(sdk.filesystem().liveResources() == 4);
        try sdk.print("zig-fs: entries=257 refused no leaked records\n");
    } else if (std.mem.eql(u8, args.args[1], "legacy")) {
        try publication();
        checkpoint = "legacy unsupported";
        const fs = sdk.filesystem();
        try refused(error.Unsupported, fs.metadata("/host/SDK", ""));
        try refused(error.Unsupported, fs.identity("/host/SDK", ""));
        try refused(error.Unsupported, fs.openContained("/host/SDK", "output", .read));
        try refused(error.Unsupported, fs.openContained("/host/SDK", "output", .write));
        try refused(error.Unsupported, fs.openSnapshot("/host/SDK", ""));
        try refused(error.Unsupported, fs.openDirectory("/host/SDK", "PUB"));
        const file = try std.Io.Dir.cwd().openFile(sdk.io, "SDK/output", .{});
        try refused(error.Unsupported, fs.fileMetadata(file));
        try refused(error.Unexpected, file.length(sdk.io));
        file.close(sdk.io);
        try check(fs.liveResources() == 4);
        try sdk.print("zig-fs: legacy unsupported=8 no leaked records\n");
    } else {
        try check(std.mem.eql(u8, args.args[1], "virtiofs"));
        try publication();
        try discovery();
        try containment();
        try pinned();
        // B3 retains only 512 mount identities. The 257-row failed capture
        // also pins identities, so exercise the entry boundary in its own boot.
        try capacity();
    }
    const high_water = sdk.stackHighWater();
    try check(high_water <= sdk.stack_budget);
    var buffer: [192]u8 = undefined;
    try sdk.print(try std.fmt.bufPrint(&buffer, "zig-fs: PASS checks={d} arena_peak={d} stack_high_water={d}\n", .{
        checks, sdk.currentArena().peak(), high_water,
    }));
}
