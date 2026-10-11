//! Keep the three implicit memory helpers inside the guarded object.
//! Volatile accesses prevent LLVM from replacing the loops with self-calls.
const std = @import("std");

export fn memset(destination: [*]u8, value: c_int, count: usize) callconv(.c) [*]u8 {
    const output: [*]volatile u8 = destination;
    const byte: u8 = @truncate(@as(c_uint, @bitCast(value)));
    for (0..count) |i| output[i] = byte;
    return destination;
}

export fn memcpy(destination: [*]u8, source: [*]const u8, count: usize) callconv(.c) [*]u8 {
    const output: [*]volatile u8 = destination;
    const input: [*]const volatile u8 = source;
    for (0..count) |i| output[i] = input[i];
    return destination;
}

export fn memmove(destination: [*]u8, source: [*]const u8, count: usize) callconv(.c) [*]u8 {
    const output: [*]volatile u8 = destination;
    const input: [*]const volatile u8 = source;
    if (@intFromPtr(destination) <= @intFromPtr(source)) {
        for (0..count) |i| output[i] = input[i];
    } else {
        var i = count;
        while (i != 0) {
            i -= 1;
            output[i] = input[i];
        }
    }
    return destination;
}

test "guarded memory helper contracts include overlapping moves and byte truncation" {
    var bytes = [_]u8{ 1, 2, 3, 4, 5, 6 };
    _ = memmove(bytes[1..].ptr, &bytes, 5);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 2, 3, 4, 5 }, &bytes);
    _ = memmove(&bytes, bytes[1..].ptr, 5);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 5 }, &bytes);
    _ = memset(&bytes, -1, bytes.len);
    try std.testing.expectEqualSlices(u8, &(@splat(255)), &bytes);
    const source = [_]u8{ 6, 5, 4, 3, 2, 1 };
    _ = memcpy(&bytes, &source, source.len);
    try std.testing.expectEqualSlices(u8, &source, &bytes);
    _ = memcpy(&bytes, &source, 0);
}
