//! A2 console only. B1 must supply actual independent stdout/stderr streams.
const std = @import("std");
pub const Write = *const fn ([]const u8) i64;
pub const Error = error{ WriteFailed, DiagnosticLimit };
pub const diagnostic_limit = 16 * 1024;

pub fn writeAll(write: Write, bytes: []const u8) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const chunk = bytes[offset..][0..@min(256, bytes.len - offset)];
        const n = write(chunk);
        if (n <= 0 or n > chunk.len) return error.WriteFailed;
        offset += @intCast(n);
    }
}

pub const Diagnostics = struct {
    remaining: usize = diagnostic_limit - "DiagnosticLimit\n".len,
    exhausted: bool = false,

    pub fn emit(self: *Diagnostics, write: Write, bytes: []const u8) Error!void {
        if (self.exhausted) return error.DiagnosticLimit;
        if (bytes.len > self.remaining) {
            self.exhausted = true;
            try writeAll(write, "DiagnosticLimit\n");
            return error.DiagnosticLimit;
        }
        self.remaining -= bytes.len;
        try writeAll(write, bytes);
    }
};

test "console: chunks, short writes, zero progress and native errors" {
    const Mock = struct {
        var seen: usize = 0;
        var result: i64 = 17;
        fn write(bytes: []const u8) i64 {
            std.debug.assert(bytes.len <= 256);
            if (result <= 0 or result > 256) return result;
            const n = @min(bytes.len, @as(usize, @intCast(result)));
            seen += n;
            return @intCast(n);
        }
    };
    Mock.seen = 0;
    Mock.result = 17;
    try writeAll(Mock.write, &(@as([777]u8, @splat(@as(u8, 'x')))));
    try std.testing.expectEqual(@as(usize, 777), Mock.seen);
    for ([_]i64{ 0, -1, 257 }) |result| {
        Mock.result = result;
        try std.testing.expectError(error.WriteFailed, writeAll(Mock.write, "hello"));
    }
}

test "diagnostics: reserve exactly one bounded limit message" {
    const Mock = struct {
        var bytes: usize = 0;
        fn write(chunk: []const u8) i64 {
            bytes += chunk.len;
            return @intCast(chunk.len);
        }
    };
    Mock.bytes = 0;
    var diag: Diagnostics = .{};
    try diag.emit(Mock.write, &(@as([(diagnostic_limit - "DiagnosticLimit\n".len)]u8, @splat(@as(u8, 'x')))));
    try std.testing.expectError(error.DiagnosticLimit, diag.emit(Mock.write, "x"));
    try std.testing.expectError(error.DiagnosticLimit, diag.emit(Mock.write, "x"));
    try std.testing.expectEqual(diagnostic_limit, Mock.bytes);
}
