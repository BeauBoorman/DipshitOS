const std = @import("std");
const network = @import("network.zig");
const io_module = @import("io.zig");
const t = std.testing;
const Mock = struct {
    var tick: u64 = 0;
    var slept: usize = 0;
    var closed: usize = 0;
    var bytes: []const u8 = "";
    var forced: ?i64 = null;
    var request: [64]u8 = undefined;
    var request_len: usize = 0;
    var dns_timeout: bool = false;
    var bad_dns: bool = false;
    var creates: usize = 0;
    var last_op: u64 = 0;
    pub fn networkNow() u64 {
        return tick;
    }
    pub fn diagnostic(_: []const u8) void {}
    pub fn fatal(_: []const u8) noreturn {
        @panic("mock fatal");
    }
    pub fn instance() *anyopaque {
        unreachable;
    }
    pub fn reset() void {
        tick = 0;
        slept = 0;
        closed = 0;
        bytes = "";
        forced = null;
        dns_timeout = false;
        bad_dns = false;
        request_len = 0;
        creates = 0;
    }
    pub fn call(slot: u64, args: [6]u64) i64 {
        if (slot == 4) {
            tick += 1_000_000_000;
            slept += 1;
            return 0;
        }
        if (slot == 72) {
            const ptr: [*]u8 = @ptrFromInt(args[0]);
            @memset(ptr[0..@intCast(args[1])], 7);
            return @intCast(args[1]);
        }
        if (slot != network.slot) return -4;
        last_op = args[0];
        if (forced) |value| return value;
        switch (args[0]) {
            0 => {
                creates += 1;
                return 4;
            },
            1 => return 9,
            7 => return 0x0a000002_1388,
            2 => {
                if (slept == 0) return -11;
                const n = @min(bytes.len, args[3]);
                const ptr: [*]u8 = @ptrFromInt(args[2]);
                @memcpy(ptr[0..n], bytes[0..n]);
                bytes = bytes[n..];
                return @intCast(n);
            },
            3 => return @intCast(@min(args[3], 3)),
            4 => {
                closed += 1;
                return 0;
            },
            5 => return if (args[1] == 15 and dns_timeout) (if (slept >= 30) 1 else 0) else (if (slept == 0) 0 else 15),
            8 => {
                const ptr: [*]const u8 = @ptrFromInt(args[2]);
                request_len = @intCast(args[3]);
                @memcpy(request[0..request_len], ptr[0..request_len]);
                return 15;
            },
            9 => {
                if (dns_timeout) return -12;
                const output: [*]u8 = @ptrFromInt(args[2]);
                const n = answer(output[0..64], request[0..request_len]);
                if (bad_dns) output[3] = 0x82;
                return @intCast(n);
            },
            else => return -1,
        }
    }
};
fn answer(output: []u8, request: []const u8) usize {
    @memcpy(output[0..request.len], request);
    output[2] = 0x81;
    output[3] = 0x80;
    output[7] = 1;
    const record = [_]u8{ 0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 1, 0, 4, 10, 0, 0, 2 };
    @memcpy(output[request.len..][0..record.len], &record);
    return request.len + record.len;
}
test "B6 DNS: bounded names, exact echoed question, malformed records and NXDOMAIN" {
    var q: [64]u8 = undefined;
    const request = try network.query("MYHOST.local.", 42, &q);
    var b: [64]u8 = undefined;
    const len = answer(&b, request);
    try t.expectEqual([4]u8{ 10, 0, 0, 2 }, try network.parseReply(b[0..len], request));
    for ([_][]const u8{ "", "-bad", "bad-", "a..b", "bad_name" }) |name|
        try t.expectError(error.InvalidArgument, network.query(name, 1, &q));
    try t.expectError(error.NameTooLong, network.query(&@as([47:0]u8, @splat("a"[0])), 1, &q));
    for (12..len) |cut| try t.expectError(error.DnsFailed, network.parseReply(b[0..cut], request));
    b[3] = 0x83;
    try t.expectError(error.NameNotFound, network.parseReply(b[0..len], request));
    try t.expectError(error.DnsFailed, network.parseReply(b[0..12], request));
    b[13] = 'Z';
    try t.expectError(error.DnsFailed, network.parseReply(b[0..len], request));
    b[3] = 0x80;
    b[2] |= 2;
    try t.expectError(error.DnsFailed, network.parseReply(b[0..len], request));
    b[2] &= ~@as(u8, 2);
    b[13] = 'x';
    try t.expectError(error.DnsFailed, network.parseReply(b[0..len], request));
}
test "B6 DNS: transaction closes on success timeout and parsing failure" {
    const Net = network.Native(Mock);
    Mock.reset();
    try t.expectEqual([4]u8{ 10, 0, 0, 2 }, try Net.resolve("myhost.local", network.default_dns));
    try t.expectEqual(@as(usize, 1), Mock.closed);
    Mock.reset();
    Mock.bad_dns = true;
    try t.expectError(error.DnsFailed, Net.resolve("myhost.local", network.default_dns));
    try t.expectEqual(@as(usize, 1), Mock.closed);
    Mock.reset();
    Mock.dns_timeout = true;
    try t.expectError(error.TimedOut, Net.resolve("myhost.local", network.default_dns));
    try t.expectEqual(@as(usize, 30), Mock.slept);
    try t.expectEqual(@as(usize, 1), Mock.closed);
    Mock.reset();
    try t.expectError(error.NameTooLong, Net.resolve(&@as([47:0]u8, @splat("a"[0])), network.default_dns));
    try t.expectEqual(@as(usize, 0), Mock.closed);
    try t.expectEqual([4]u8{ 10, 0, 0, 2 }, try Net.resolve("10.0.0.2", network.default_dns));
    try t.expectEqual(@as(usize, 0), Mock.closed);
}

test "B6 native result: bad pointers remain named refusals" {
    try t.expectError(error.BadPointer, network.result(-3));
    try t.expectError(error.ProtocolViolation, network.result(-123));
}
test "B6 std.Io: listener stream share four resources and use readiness sleep" {
    Mock.reset();
    var backend: io_module.Backend(Mock) = .{};
    const io = backend.io();
    const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, 1 }, .port = 8090 } };
    var server = try address.listen(io, .{ .kernel_backlog = 2 });
    const stream = try server.accept(io);
    try t.expectEqual(@as(usize, 6), backend.liveResources());
    Mock.bytes = "hello";
    var output: [5]u8 = undefined;
    var vec = [_][]u8{&output};
    try t.expectEqual(@as(usize, 5), try io.vtable.netRead(io.userdata, stream.socket.handle, &vec));
    try t.expectEqualStrings("hello", &output);
    try t.expectEqual(@as(usize, 1), Mock.slept);
    try t.expectEqual(@as(usize, 3), try io.vtable.netWrite(io.userdata, stream.socket.handle, "abcde", &.{}, 0));
    Mock.forced = -13;
    try t.expectError(error.ConnectionResetByPeer, io.vtable.netRead(io.userdata, stream.socket.handle, &vec));
    Mock.forced = -12;
    try t.expectError(error.Timeout, io.vtable.netRead(io.userdata, stream.socket.handle, &vec));
    Mock.forced = null;
    stream.close(io);
    server.deinit(io);
    try t.expectEqual(@as(usize, 4), backend.liveResources());
    try t.expectEqual(@as(usize, 2), Mock.closed);
    try t.expectError(error.SocketUnconnected, io.vtable.netRead(io.userdata, stream.socket.handle, &vec));
}
test "B6 std.Io: capacity and options refuse before creating transport" {
    Mock.reset();
    var backend: io_module.Backend(Mock) = .{};
    const io = backend.io();
    const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, 1 }, .port = 8090 } };
    try t.expectError(error.OptionUnsupported, address.listen(io, .{}));
    try t.expectEqual(@as(usize, 0), Mock.creates);
    var servers: [4]std.Io.net.Server = undefined;
    for (&servers) |*server| server.* = try address.listen(io, .{ .kernel_backlog = 2 });
    try t.expectError(error.ProcessFdQuotaExceeded, address.listen(io, .{ .kernel_backlog = 2 }));
    try t.expectEqual(@as(usize, 8), backend.liveResources());
    try backend.closeAll();
    try t.expectEqual(@as(usize, 4), backend.liveResources());
}

test "B6 std.Io: finish closes children before listener and a pure wait has a deadline" {
    Mock.reset();
    var backend: io_module.Backend(Mock) = .{};
    const io = backend.io();
    const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, 1 }, .port = 8090 } };
    var server = try address.listen(io, .{ .kernel_backlog = 2 });
    _ = try server.accept(io);
    try backend.closeAll();
    try t.expectEqual(@as(usize, 2), Mock.closed);
    try t.expectEqual(@as(usize, 4), backend.liveResources());
    Mock.reset();
    Mock.dns_timeout = true;
    try t.expectError(error.TimedOut, network.Native(Mock).wait(15, 2, network.budget_ns));
    try t.expectEqual(@as(usize, 30), Mock.slept);
}
