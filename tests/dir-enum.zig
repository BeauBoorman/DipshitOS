//! Native ABI acceptance fixture, not a portfolio app or SDK backend.
const std = @import("std");
const dir = @import("directory");
var page: dir.Page = undefined;
var receipt: [8192]u8 = undefined;
var receipt_len: usize = 0;
var path: [513]u8 = undefined;
var checkpoint: []const u8 = "listing";

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

fn print(text: []const u8) void {
    var at: usize = 0;
    while (at < text.len) {
        const take = @min(text.len - at, 256);
        if (svc(1, .{ 1, @intFromPtr(text.ptr + at), take, 0, 0, 0 }) != take) finish(1);
        at += take;
    }
}

fn finish(status: u64) noreturn {
    _ = svc(3, .{ status, 0, 0, 0, 0, 0 });
    while (true) asm volatile ("wfe");
}

fn check(ok: bool) void {
    if (!ok) {
        print("b2: FAIL ");
        print(checkpoint);
        print("\n");
        finish(1);
    }
}

fn open(name: []const u8) i64 {
    return svc(27, .{ @intFromPtr(name.ptr), name.len, 0, dir.open_op, 0, 0 });
}

fn close(token: i64) void {
    check(svc(27, .{ @intCast(token), 0, 0, dir.close_op, 0, 0 }) == 0);
}

fn read(token: i64, offset: u64, limit: u64) i64 {
    return svc(27, .{ @intCast(token), offset, @intFromPtr(&page), dir.page_op, limit, 0 });
}

fn append(text: []const u8) void {
    check(text.len <= receipt.len - receipt_len);
    @memcpy(receipt[receipt_len..][0..text.len], text);
    receipt_len += text.len;
}

fn save(name: []const u8, bytes: []const u8) void {
    const fd = svc(23, .{ @intFromPtr(name.ptr), name.len, 2 | 4, 0, 0, 0 });
    check(fd >= 0);
    var at: usize = 0;
    while (at < bytes.len) {
        const take = @min(bytes.len - at, 2048);
        const n = svc(25, .{ @intCast(fd), @intFromPtr(bytes.ptr + at), take, 0, 0, 0 });
        check(n > 0 and n <= take);
        at += @intCast(n);
    }
    check(svc(77, .{ @intCast(fd), 0, 0, 0, 0, 0 }) == 0);
    check(svc(26, .{ @intCast(fd), 0, 0, 0, 0, 0 }) == 0);
}

export fn b2_main() noreturn {
    print("b2: starting\n");
    const token = open("/host/B2");
    if (token <= 0) {
        var diagnostic: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&diagnostic, "b2: open result={d}\n", .{token}) catch unreachable;
        print(text);
    }
    check(token > 0);
    // EFAULT must leave the indexed page available.
    check(svc(27, .{ @intCast(token), 0, 0x1_2000_0000, dir.page_op, 7, 0 }) == -3);
    var offset: u64 = 0;
    var count: usize = 0;
    while (true) {
        const n = read(token, offset, 7);
        check(n >= 0 and n <= 7);
        check(page.header.count == n and page.header.next == offset + @as(u64, @intCast(n)));
        for (page.entries[0..@intCast(n)]) |entry| {
            check(entry.name_len > 0 and entry.name_len <= 255);
            append(entry.name[0..entry.name_len]);
            append("\n");
            count += 1;
        }
        offset = page.header.next;
        if (page.header.end == 1) break;
        check(n > 0);
    }
    check(count == 40);
    check(read(token, offset, 7) == 0 and page.header.end == 1);
    close(token);
    check(read(token, 0, 7) == -2);
    save("B2.RECEIPT", receipt[0..receipt_len]);
    print("b2: lossless count=40 pages=6 eof=1\n");

    // Exact 256 entries requires a real EOF probe, not a full-page guess.
    const exact = open("B2LIMIT");
    check(exact > 0);
    check(read(exact, 240, 16) == 16 and page.header.end == 1);
    check(read(exact, 256, 16) == 0 and page.header.end == 1);
    close(exact);
    check(open("B2OVER") == -5);
    print("b2: entries 256 accepted 257 refused\n");

    // Path = six-byte prefix + 250-byte directory + '/' + 255-byte leaf.
    @memcpy(path[0..6], "/host/");
    @memset(path[6..256], 'a');
    path[256] = '/';
    @memset(path[257..512], 'b');
    const wide = open(path[0..512]);
    checkpoint = "path 512 open";
    check(wide > 0);
    checkpoint = "path 512 page";
    check(read(wide, 0, 16) == 1);
    check(std.mem.eql(u8, page.entries[0].name[0..page.entries[0].name_len], "leaf"));
    close(wide);
    path[512] = 'c';
    checkpoint = "path 513 refusal";
    check(open(&path) == -8);
    const eight = open("d/e/e/e/e/e/e/e");
    checkpoint = "depth 8 open";
    check(eight > 0);
    close(eight);
    checkpoint = "depth 9 refusal";
    check(open("d/e/e/e/e/e/e/e/e") == -8);
    checkpoint = "component 256 refusal";
    check(open(&(@as([256]u8, @splat(@as(u8, 'x'))))) == -8);
    checkpoint = "ACL refusal";
    check(open("B2DENIED") == -7);
    checkpoint = "traversal refusal";
    check(open("../escape") < 0);
    checkpoint = "USB refusal";
    check(open("usb1") == -4);
    print("b2: path 512 accepted 513 refused depth 8 accepted 9 refused acl denied\n");

    // Membership snapshot survives mutation between pages.
    checkpoint = "mutation";
    const stable = open("B2MUTATE");
    check(stable > 0);
    check(read(stable, 0, 1) == 1);
    check(svc(34, .{ @intFromPtr("B2MUTATE/old"), 12, 0, 0, 0, 0 }) == 0);
    save("B2MUTATE/new", "new");
    check(read(stable, 0, 1) == 1);
    check(std.mem.eql(u8, page.entries[0].name[0..page.entries[0].name_len], "old"));
    close(stable);
    const fresh = open("B2MUTATE");
    check(fresh > 0);
    check(read(fresh, 0, 1) == 1);
    check(std.mem.eql(u8, page.entries[0].name[0..page.entries[0].name_len], "new"));
    close(fresh);
    print("b2: stable snapshot mutation ok\n");

    checkpoint = "capacity and close";
    var tokens: [8]i64 = undefined;
    for (&tokens) |*t| {
        t.* = open("B2");
        check(t.* > 0);
    }
    check(open("B2") == -5);
    for (tokens) |t| close(t);
    // Native regular handles consume the same eight resources.
    for (&tokens) |*t| {
        t.* = svc(23, .{ @intFromPtr("B2.RECEIPT"), 10, 1, 0, 0, 0 });
        check(t.* >= 0);
    }
    check(open("B2") == -5);
    for (tokens) |fd| check(svc(26, .{ @intCast(fd), 0, 0, 0, 0, 0 }) == 0);
    // Deliberately leave eight cursors live: reaping must free 144 pool pages.
    for (&tokens) |*t| {
        t.* = open("B2");
        check(t.* > 0);
    }
    print("b2: capacity close ok death cursors=8\n");
    finish(0);
}

export fn _start() callconv(.naked) noreturn {
    asm volatile ("b b2_main");
}
