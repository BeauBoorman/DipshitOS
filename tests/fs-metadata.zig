//! B3/B5 raw EL0 acceptance probe, independent of the C-card SDK trees.
const std = @import("std");
const meta = @import("metadata");
var value: meta.Wire = undefined;
var page: meta.Page = undefined;
var bytes: [64]u8 = undefined;
var checkpoint: []const u8 = "start";
var checks: usize = 0;
var pending: [8][meta.max_relative_path]u8 = undefined;
var lengths: [8]usize = @splat(0);
var identities: [8]meta.Identity = undefined;

fn svc(number: u64, args: [6]u64) i64 {
    return asm volatile ("svc #0"
        : [result] "={x0}" (-> i64),
        : [number] "{x8}" (number),
          [a0] "{x0}" (args[0]),
          [a1] "{x1}" (args[1]),
          [a2] "{x2}" (args[2]),
          [a3] "{x3}" (args[3]),
          [a4] "{x4}" (args[4]),
          [a5] "{x5}" (args[5]),
        : .{ .memory = true });
}

fn say(text: []const u8) void {
    var at: usize = 0;
    while (at < text.len) {
        const n = @min(text.len - at, 256);
        if (svc(1, .{ 1, @intFromPtr(text.ptr + at), n, 0, 0, 0 }) != n) finish(1);
        at += n;
    }
}

fn finish(status: u64) noreturn {
    _ = svc(3, .{ status, 0, 0, 0, 0, 0 });
    while (true) asm volatile ("wfe");
}

fn check(ok: bool) void {
    if (!ok) {
        say("b3: FAIL ");
        say(checkpoint);
        var diagnostic: [48]u8 = undefined;
        say(std.fmt.bufPrint(&diagnostic, " checks={d}\n", .{checks}) catch unreachable);
        finish(1);
    }
    checks += 1;
}

fn call(op: u64, root: []const u8, path: []const u8) i64 {
    return svc(79, .{
        op,                                                     @intFromPtr(root.ptr), root.len, @intFromPtr(path.ptr), path.len,
        if (op <= meta.identity_op) @intFromPtr(&value) else 0,
    });
}

fn stat(root: []const u8, path: []const u8) meta.Wire {
    check(call(meta.stat_op, root, path) == 0);
    check(value.version == 1 and value.identity.filesystem != 0 and value.identity.inode != 0);
    check(value.mtime.nanoseconds < 1_000_000_000);
    return value;
}

fn close(fd: i64) void {
    check(svc(26, .{ @intCast(fd), 0, 0, 0, 0, 0 }) == 0);
}

fn read(fd: i64, expected: []const u8) void {
    check(svc(24, .{ @intCast(fd), @intFromPtr(&bytes), bytes.len, 0, 0, 0 }) == expected.len);
    check(std.mem.eql(u8, bytes[0..expected.len], expected));
}

fn rename(from: []const u8, to: []const u8) void {
    check(svc(35, .{ @intFromPtr(from.ptr), from.len | (@as(u64, 1) << 63), @intFromPtr(to.ptr), to.len, 0, 0 }) == 0);
}

fn named(op: u64, dir: i64, name: []const u8, x4: u64) i64 {
    return svc(79, .{ op, @bitCast(dir), @intFromPtr(name.ptr), name.len, x4, 0 });
}

fn renameAt(from: i64, a: []const u8, to: i64, b: []const u8, replace: bool) i64 {
    const packed_lengths = a.len | b.len << 16 | (if (replace) meta.rename_replace else 0);
    return svc(79, .{ meta.rename_op, @bitCast(from), @intFromPtr(a.ptr), @bitCast(to), @intFromPtr(b.ptr), packed_lengths });
}

fn handleStat(handle: i64, kind: u64) i64 {
    return svc(79, .{ meta.handle_metadata_op, @bitCast(handle), kind, 0, 0, @intFromPtr(&value) });
}

fn unpin(dir: i64) void {
    check(svc(79, .{ meta.pin_close_op, @bitCast(dir), 0, 0, 0, 0 }) == 0);
}

fn createWith(dir: i64, name: []const u8, content: []const u8) void {
    const fd = named(meta.create_op, dir, name, 0);
    check(fd >= 0 and fd < 8);
    check(svc(25, .{ @intCast(fd), @intFromPtr(content.ptr), content.len, 0, 0, 0 }) == content.len);
    check(svc(77, .{ @intCast(fd), 0, 0, 0, 0, 0 }) == 0);
    check(handleStat(fd, meta.handle_file) == 0 and value.kind == .file and value.size == content.len);
    close(fd);
}

/// B5: the Boris C3 publication sequence through pinned directories.
fn pinned() void {
    checkpoint = "B5 pin and handle metadata";
    const top = call(meta.pin_open_op, "/host/PUB", "");
    check(top > 0);
    const top_id = stat("/host", "PUB").identity;
    check(handleStat(top, meta.handle_directory) == 0 and value.kind == .directory and value.identity.eql(top_id));
    check(handleStat(top, meta.handle_file) == -2);
    check(call(meta.pin_open_op, "/host/PUB", "link") == -7);
    const path_fd = svc(23, .{ @intFromPtr("/host/PUB/out/old.html"), 22, 1, 0, 0, 0 });
    check(path_fd >= 0);
    check(handleStat(path_fd, meta.handle_file) == -4);
    close(path_fd);
    say("b5: pin metadata own-object path-fd unsupported symlink refused\n");

    checkpoint = "B5 Boris stage";
    const stage = named(meta.mkdir_op, top, "stage", 0);
    check(stage > 0);
    check(named(meta.mkdir_op, top, "stage", 0) == -9);
    const assets = named(meta.mkdir_op, stage, "assets", 0);
    check(assets > 0);
    createWith(stage, "index.html", "<p>raw</p>\n");
    check(named(meta.create_op, stage, "index.html", 0) == -9);
    createWith(assets, "site.css", "p{}\n");
    unpin(assets);
    check(stat("/host/PUB", "stage/index.html").size == 11);
    say("b5: staged directories=2 files=2 exclusive EEXIST=2\n");

    checkpoint = "B5 Boris publish";
    check(renameAt(top, "stage", top, "out", false) == -9);
    check(renameAt(top, "stage", top, "out", true) == -9);
    check(renameAt(top, "out", top, "out.prev", false) == 0);
    check(renameAt(top, "stage", top, "out", false) == 0);
    check(named(meta.create_op, stage, "late", 0) == -2);
    check(handleStat(stage, meta.handle_directory) == -2);
    unpin(stage);
    check(svc(79, .{ meta.pin_close_op, @bitCast(stage), 0, 0, 0, 0 }) == -2);
    const prev = named(meta.pin_child_op, top, "out.prev", 0);
    check(prev > 0);
    check(named(meta.remove_op, top, "out.prev", meta.remove_directory) == -9);
    check(named(meta.remove_op, prev, "keep", meta.remove_file) == -1);
    check(named(meta.remove_op, prev, "old.html", meta.remove_directory) == -1);
    check(named(meta.remove_op, prev, "old.html", meta.remove_file) == 0);
    check(named(meta.remove_op, prev, "old.html", meta.remove_file) == -6);
    check(named(meta.remove_op, prev, "keep", meta.remove_directory) == 0);
    unpin(prev);
    check(named(meta.remove_op, top, "out.prev", meta.remove_directory) == 0);
    check(call(meta.stat_op, "/host/PUB", "out.prev") == -6);
    say("b5: Boris publish EEXIST=2 park swap remove stale-refusals=2\n");

    checkpoint = "B5 atomic file replace";
    const out = named(meta.pin_child_op, top, "out", 0);
    check(out > 0);
    createWith(out, "index.tmp", "<p>v2</p>\n");
    check(renameAt(out, "index.tmp", out, "index.html", false) == -9);
    check(renameAt(out, "index.tmp", out, "index.html", true) == 0);
    check(renameAt(out, "index.tmp", out, "index.html", true) == -6);
    const reader = call(meta.read_open_op, "/host/PUB", "out/index.html");
    check(reader >= 0);
    read(reader, "<p>v2</p>\n");
    check(handleStat(reader, meta.handle_file) == 0 and value.size == 10);
    close(reader);

    checkpoint = "B5 stale-inode mutation refusal";
    // A delete+recreate under the live pin rebinds the recorded path to a
    // new inode; write, truncate and sync through the earlier fd must
    // refuse rather than hit the stale object under a laundered auth.
    createWith(out, "swapped.txt", "one\n");
    const doomed = call(meta.write_open_op, "/host/PUB", "out/swapped.txt");
    check(doomed >= 0);
    check(named(meta.remove_op, out, "swapped.txt", meta.remove_file) == 0);
    createWith(out, "swapped.txt", "two\n");
    check(svc(36, .{ @intCast(doomed), 1, 0, 0, 0, 0 }) == -2);
    check(svc(25, .{ @intCast(doomed), @intFromPtr("!"), 1, 0, 0, 0 }) == -2);
    check(svc(77, .{ @intCast(doomed), 0, 0, 0, 0, 0 }) == -2);
    close(doomed);
    check(stat("/host/PUB", "out/swapped.txt").size == 4);
    check(named(meta.remove_op, out, "swapped.txt", meta.remove_file) == 0);
    say("b5: stale-inode write truncate sync refuse a rebound name\n");

    // A slot-35 rename stales pins at or under either name, too.
    rename("/host/PUB/out", "/host/PUB/moved");
    check(handleStat(out, meta.handle_directory) == -2);
    rename("/host/PUB/moved", "/host/PUB/out");
    check(handleStat(out, meta.handle_directory) == -2);
    unpin(out);
    say("b5: atomic replace preserve EEXIST replace ok slot-35 stales pins\n");

    checkpoint = "B5 names registers faults and policy";
    for ([_][]const u8{ ".", "..", "a/b", "nul\x00" }) |name| check(named(meta.create_op, top, name, 0) == -1);
    check(named(meta.create_op, top, "", 0) == -1);
    check(named(meta.create_op, top, &@as([256:0]u8, @splat("n"[0])), 0) == -8);
    check(svc(79, .{ meta.create_op, @bitCast(top), 0x1_2000_0000, 4, 0, 0 }) == -3);
    check(svc(79, .{ meta.create_op, @bitCast(top), @intFromPtr("x"), 1, 1, 0 }) == -1);
    check(svc(79, .{ meta.pin_close_op, @bitCast(top), 1, 0, 0, 0 }) == -1);
    check(svc(79, .{ meta.handle_metadata_op, @bitCast(top), meta.handle_directory, 0, 0, 0x1_2000_0000 }) == -3);
    check(svc(79, .{ meta.handle_metadata_op, @bitCast(top), 2, 0, 0, @intFromPtr(&value) }) == -1);
    check(svc(79, .{ meta.rename_op, @bitCast(top), @intFromPtr("out"), @bitCast(top), @intFromPtr("x"), 3 | 1 << 16 | 1 << 33 }) == -1);
    check(named(meta.remove_op, top, "out", 2) == -1);
    check(named(meta.pin_child_op, top, "link", 0) == -7);
    check(named(meta.remove_op, top, "link", meta.remove_file) == -7);
    check(named(meta.create_op, top, "denied", 0) == -7);
    check(named(meta.remove_op, top, "denied", meta.remove_file) == -7);
    check(named(meta.remove_op, top, "secret", meta.remove_file) == -7);
    check(renameAt(top, "secret", top, "leaked", false) == -7);
    check(renameAt(top, "out", top, "secret", true) == -7);
    check(named(meta.create_op, 1 << 40, "x", 0) == -2);
    // PUB itself lists a symlink, which a B3 snapshot refuses.
    const cursor = call(meta.dir_open_op, "/host/PUB", "out");
    check(cursor > 0);
    check(named(meta.create_op, cursor, "x", 0) == -2);
    check(svc(79, .{ meta.dir_close_op, @intCast(top), 0, 0, 0, 0 }) == -2);
    check(svc(79, .{ meta.dir_close_op, @intCast(cursor), 0, 0, 0, 0 }) == 0);
    check(svc(79, .{ meta.pin_close_op, @intCast(cursor), 0, 0, 0, 0 }) == -2);
    unpin(top);
    say("b5: refusals names=6 registers=7 policy=7 tokens=4\n");
}

fn discover(root: []const u8, root_id: meta.Identity) void {
    // Boris's cycle rule: remember the root, refuse a repeated directory
    // identity, and walk returned names, not a host-supplied file list.
    lengths = @splat(0);
    identities[0] = root_id;
    var queued: usize = 1;
    var current: usize = 0;
    var visited: usize = 0;
    while (current < queued) : (current += 1) {
        const parent = pending[current][0..lengths[current]];
        checkpoint = "Boris directory open";
        const token = call(meta.dir_open_op, root, parent);
        check(token > 0);
        var offset: u64 = 0;
        while (true) {
            checkpoint = "Boris page";
            const n = svc(79, .{ meta.dir_page_op, @intCast(token), offset, 7, @intFromPtr(&page), 0 });
            check(n >= 0 and n <= 7);
            for (page.entries[0..@intCast(n)]) |entry| {
                checkpoint = "Boris entry bound";
                visited += 1;
                if (visited > 256 or queued >= pending.len) {
                    var details: [96]u8 = undefined;
                    say(std.fmt.bufPrint(&details, "b3: Boris visited={d} queued={d} kind={d}\n", .{ visited, queued, @backingInt(entry.metadata.kind) }) catch unreachable);
                }
                check(visited <= 256);
                if (entry.metadata.kind != .directory) continue;
                check(queued < pending.len);
                checkpoint = "Boris directory identity cycle";
                for (identities[0..queued]) |seen| check(!seen.eql(entry.metadata.identity));
                identities[queued] = entry.metadata.identity;
                const sep: usize = @intFromBool(parent.len != 0);
                const len = parent.len + sep + entry.name_len;
                checkpoint = "Boris path length";
                check(len <= meta.max_relative_path);
                @memcpy(pending[queued][0..parent.len], parent);
                if (sep != 0) pending[queued][parent.len] = '/';
                @memcpy(pending[queued][parent.len + sep ..][0..entry.name_len], entry.name[0..entry.name_len]);
                lengths[queued] = len;
                queued += 1;
            }
            offset = page.header.next;
            if (page.header.end == 1) break;
            check(n > 0);
        }
        checkpoint = "Boris cursor close";
        check(svc(79, .{ meta.dir_close_op, @intCast(token), 0, 0, 0, 0 }) == 0);
    }
    checkpoint = "Boris totals";
    check(queued == 3 and visited == 25);
    say("b3: Boris-style discovery directories=3 entries=25 cycles=0\n");
}

export fn b3_main() noreturn {
    say("b3: starting\n");
    const root = "/host/content";
    const first = call(meta.stat_op, root, "");
    if (first == -4) {
        checkpoint = "legacy unsupported";
        check(call(meta.identity_op, root, "") == -4);
        check(call(meta.read_open_op, root, "a/b/page.md") == -4);
        check(call(meta.write_open_op, root, "a/b/page.md") == -4);
        check(call(meta.dir_open_op, root, "") == -4);
        say("b3: legacy explicitly unsupported operations=5\n");
        checkpoint = "B5 legacy unsupported";
        check(call(meta.pin_open_op, "/host/PUB", "") == -4);
        const fd = svc(23, .{ @intFromPtr("/host/PUB/out/old.html"), 22, 1, 0, 0, 0 });
        check(fd >= 0);
        check(handleStat(fd, meta.handle_file) == -4);
        close(fd);
        check(named(meta.create_op, 1, "x", 0) == -2);
        say("b5: legacy explicitly unsupported pin=1 path-fd=1 unbound=1\n");
        finish(0);
    }
    if (first != 0) {
        var diagnostic: [64]u8 = undefined;
        say(std.fmt.bufPrint(&diagnostic, "b3: root metadata result={d}\n", .{first}) catch unreachable);
    }
    check(first == 0);
    checkpoint = "nested scanner identities";
    var ids: [3]meta.Identity = undefined;
    for ([_][]const u8{ "", "a", "a/b" }, 0..) |path, i| {
        const info = stat(root, path);
        ids[i] = info.identity;
        check(info.kind == .directory);
        const again = stat(root, path);
        check(info.identity.eql(again.identity));
        for (ids[0..i]) |prior| check(!prior.eql(info.identity));
        check(call(meta.identity_op, root, path) == 0);
        const identity: *const meta.Identity = @ptrCast(&value);
        check(identity.*.eql(ids[i]));
    }
    say("b3: nested discovery directories=3 stable distinct\n");
    checkpoint = "rich directory pages";
    const token = call(meta.dir_open_op, root, "");
    check(token > 0);
    check(svc(79, .{ meta.dir_page_op, @intCast(token), 0, 7, 0x1_2000_0000, 0 }) == -3);
    var offset: u64 = 0;
    var count: usize = 0;
    var directories: usize = 0;
    var long_names: usize = 0;
    while (true) {
        const n = svc(79, .{ meta.dir_page_op, @intCast(token), offset, 7, @intFromPtr(&page), 0 });
        check(n >= 0 and n <= 7 and page.header.count == n);
        for (page.entries[0..@intCast(n)]) |entry| {
            const name = entry.name[0..entry.name_len];
            const info = stat(root, name);
            check(info.identity.eql(entry.metadata.identity));
            check(info.kind == entry.metadata.kind and info.size == entry.metadata.size);
            check(info.mtime.seconds == entry.metadata.mtime.seconds and info.mtime.nanoseconds == entry.metadata.mtime.nanoseconds);
            if (entry.metadata.kind == .directory) {
                if (!info.identity.eql(ids[1])) {
                    var diagnostic: [128]u8 = undefined;
                    say(std.fmt.bufPrint(&diagnostic, "b3: row directory ino={d} expected={d} name=", .{ info.identity.inode, ids[1].inode }) catch unreachable);
                    say(name);
                    say("\n");
                }
                check(info.identity.eql(ids[1]));
                directories += 1;
            }
            if (name.len > 31) long_names += 1;
            count += 1;
        }
        offset = page.header.next;
        if (page.header.end == 1) break;
        check(n > 0);
    }
    check(count == 23 and directories == 1 and long_names == 2);
    check(svc(79, .{ meta.dir_close_op, @intCast(token), 0, 0, 0, 0 }) == 0);
    check(svc(79, .{ meta.dir_page_op, @intCast(token), 0, 1, @intFromPtr(&page), 0 }) == -2);
    say("b3: directory rows=23 pages=4 long-names=2 fresh metadata\n");
    checkpoint = "Boris-style discovery";
    discover(root, ids[0]);

    checkpoint = "root intermediate leaf dangling no-follow";
    for ([_][]const u8{ "leaf", "dir/page.md", "dangling" }) |path| {
        for ([_]u64{ meta.stat_op, meta.identity_op, meta.read_open_op, meta.write_open_op }) |op| check(call(op, "/host/B3LINKS", path) == -7);
    }
    check(call(meta.stat_op, "/host/ROOTLINK", "") == -7);
    check(call(meta.dir_open_op, "/host/B3LINKS", "") == -7);
    check(call(meta.stat_op, root, "../outside") == -1);
    check(call(meta.stat_op, root, "missing") == -6);
    check(call(meta.stat_op, "/usb", "") == -4);
    say("b3: no-follow refusals=17 root intermediate leaf dangling\n");

    checkpoint = "watch stamps";
    const old = stat(root, "a/b/page.md");
    const writer = call(meta.write_open_op, root, "a/b/page.md");
    check(writer >= 0);
    check(svc(25, .{ @intCast(writer), @intFromPtr("edit"), 4, 0, 0, 0 }) == 4);
    check(svc(77, .{ @intCast(writer), 0, 0, 0, 0, 0 }) == 0);
    const edited = stat(root, "a/b/page.md");
    check(edited.size == old.size);
    check(edited.mtime.seconds != old.mtime.seconds or edited.mtime.nanoseconds != old.mtime.nanoseconds);
    check(svc(25, .{ @intCast(writer), @intFromPtr("!"), 1, 0, 0, 0 }) == 1);
    check(svc(77, .{ @intCast(writer), 0, 0, 0, 0, 0 }) == 0);
    check(stat(root, "a/b/page.md").size == 5);
    close(writer);
    say("b3: watch independent mtime and size changes detected\n");

    checkpoint = "pinned directory and leaf replacements";
    const reader = call(meta.read_open_op, root, "a/b/page.md");
    check(reader >= 0);
    const pinned_writer = call(meta.write_open_op, root, "a/b/page.md");
    check(pinned_writer >= 0);
    rename("/host/content/a", "/host/saved-a");
    rename("/host/SWAPDIR", "/host/content/a");
    check(call(meta.stat_op, root, "a/b/page.md") == -7);
    read(reader, "edit!");
    close(reader);
    // The rebound name no longer authorizes the open inode: the contained
    // write refuses through the swapped path rather than mutate it under
    // whatever policy the new object carries.
    check(svc(25, .{ @intCast(pinned_writer), @intFromPtr("safe"), 4, 0, 0, 0 }) == -7);
    close(pinned_writer);
    rename("/host/content/a", "/host/SWAPDIR");
    rename("/host/saved-a", "/host/content/a");
    const leaf_reader = call(meta.read_open_op, root, "a/b/page.md");
    check(leaf_reader >= 0);
    rename("/host/content/a/b/page.md", "/host/content/a/b/saved.md");
    rename("/host/SWAPLEAF", "/host/content/a/b/page.md");
    check(call(meta.identity_op, root, "a/b/page.md") == -7);
    read(leaf_reader, "edit!");
    close(leaf_reader);
    rename("/host/content/a/b/page.md", "/host/SWAPLEAF");
    rename("/host/content/a/b/saved.md", "/host/content/a/b/page.md");
    say("b3: replacement races pinned reads survive and rebound mutation refused\n");

    checkpoint = "ownership secret and ancestor policy";
    for ([_][]const u8{ "DENIED", "SECRET" }) |path| {
        check(call(meta.stat_op, "/host", path) == -7);
        check(call(meta.identity_op, "/host", path) == -7);
        check(call(meta.read_open_op, "/host", path) == -7);
    }
    check(call(meta.stat_op, "/host/DENIEDDIR", "leaf") == -7);
    say("b3: ownership and secret refusals=7\n");
    pinned();
    checkpoint = "resource capacity and teardown";
    var fds: [8]i64 = undefined;
    for (&fds) |*fd| {
        fd.* = call(meta.read_open_op, root, "a/b/page.md");
        check(fd.* >= 0);
    }
    check(call(meta.read_open_op, root, "a/b/page.md") == -5);
    check(call(meta.pin_open_op, root, "") == -5);
    for (fds) |fd| close(fd);
    // Leave rich cursors and pins for process-death cleanup, within native ceilings.
    for (fds[0..4]) |*fd| {
        fd.* = call(meta.dir_open_op, root, "");
        check(fd.* > 0);
    }
    for (fds[4..]) |*fd| {
        fd.* = call(meta.pin_open_op, root, "a");
        check(fd.* > 0);
    }
    check(call(meta.pin_open_op, root, "") == -5);
    var diagnostic: [96]u8 = undefined;
    say(std.fmt.bufPrint(&diagnostic, "b3: PASS checks={d} death-cursors=4 death-pins=4\n", .{checks}) catch unreachable);
    finish(0);
}

export fn _start() callconv(.naked) noreturn {
    asm volatile ("b b3_main");
}
