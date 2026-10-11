//! Native B6 acceptance, separate from the injected-core artifact and Boris.
const std = @import("std");
const sdk = @import("runtime.zig");
const net = @import("network.zig");
const Net = net.Native(sdk.native);
pub const virelai = sdk.platform;
pub const os = sdk.os;
pub const std_options = sdk.std_options;
pub const std_options_debug_io = sdk.std_options_debug_io;
pub const std_options_FilePermissions = sdk.std_options_FilePermissions;
pub const std_options_cwd = sdk.std_options_cwd;
pub const panic = std.debug.FullPanic(sdk.panic);
comptime {
    @import("entry.zig").exportEntry(run);
}
fn check(ok: bool) !void {
    if (!ok) return error.NativeSocketAcceptance;
}
fn read(stream: std.Io.net.Stream, expected: []const u8) !void {
    var data: [64]u8 = undefined;
    var vectors = [_][]u8{data[0..expected.len]};
    var at: usize = 0;
    while (at < expected.len) {
        vectors[0] = data[at..expected.len];
        const n = (try stream.readWithControl(sdk.io, &vectors, &.{})).data_len;
        try check(n != 0);
        at += n;
    }
    try check(std.mem.eql(u8, data[0..at], expected));
}
fn run(args: *const sdk.startup.Startup) !void {
    try sdk.initialize(1024 * 1024);
    const mode = if (args.argc > 1) args.args[1] else "preview";
    if (std.mem.eql(u8, mode, "dns")) {
        var storage: [16]std.Io.net.HostName.LookupResult = undefined;
        var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&storage);
        const name = try std.Io.net.HostName.init("myhost.local");
        var canonical: [255]u8 = undefined;
        try name.lookup(sdk.io, &queue, .{ .port = 8090, .family = .ip4, .canonical_name_buffer = &canonical });
        const resolved = try queue.getOne(sdk.io);
        try check(std.mem.eql(u8, &resolved.address.ip4.bytes, &.{ 10, 0, 0, 2 }));
        try check(resolved.address.ip4.port == 8090);
        try check(std.mem.eql(u8, (try queue.getOne(sdk.io)).canonical_name.bytes, name.bytes));
        try check(try Net.call(11, 0, 0, 0) == 0);
        try sdk.print("native-socket: DNS std.Io lookup cleanup ok\n");
        return;
    }
    if (std.mem.eql(u8, mode, "dns-timeout")) {
        if (Net.resolve("myhost.local", net.default_dns)) |_| return error.UnexpectedDnsSuccess else |err| try check(err == error.TimedOut);
        try check(try Net.call(11, 0, 0, 0) == 0);
        try sdk.print("native-socket: DNS timeout cleanup ok\n");
        return;
    }
    const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, 1 }, .port = 8090 } };
    var server = try address.listen(sdk.io, .{ .kernel_backlog = 2 });
    if (std.mem.eql(u8, mode, "death")) {
        // Leave an owned listener to real scheduler teardown, not finish().
        try sdk.print("native-socket: death listener owned\n");
        sdk.native.exit(0);
    }
    try sdk.print("native-socket: listening two-client limit\n");
    const one = try server.accept(sdk.io);
    const two = try server.accept(sdk.io);
    try check(try Net.call(11, 0, 0, 0) == 3);
    try read(one, "GET /one\n");
    try read(two, "GET /two\n");
    try sdk.print("native-socket: two clients accepted\n");
    var writer = one.writer(sdk.io, &.{});
    try writer.interface.writeAll("preview-one\n");
    try writer.interface.flush();
    var writer2 = two.writer(sdk.io, &.{});
    try writer2.interface.writeAll("preview-two\n");
    try writer2.interface.flush();
    var b: [1]u8 = undefined;
    var vector = [_][]u8{&b};
    // Probe drives an independent FIN or reset; honest terminal read result.
    try check((try one.readWithControl(sdk.io, &vector, &.{})).data_len == 0);
    one.close(sdk.io);
    if (std.mem.eql(u8, mode, "timeout")) {
        if (two.readWithControl(sdk.io, &vector, &.{})) |_| return error.UnexpectedRead else |err| try check(err == error.ConnectionTimedOut);
        try sdk.print("native-socket: peer timeout reported\n");
    } else {
        if (two.readWithControl(sdk.io, &vector, &.{})) |_| return error.UnexpectedRead else |err| try check(err == error.ConnectionResetByPeer);
        try sdk.print("native-socket: peer reset reported\n");
    }
    two.close(sdk.io);
    server.deinit(sdk.io);
    try check(try Net.call(11, 0, 0, 0) == 0);
    try check(sdk.filesystem().liveResources() == 4);
    try sdk.print("native-socket: disconnect capacity cleanup ok\n");
}
