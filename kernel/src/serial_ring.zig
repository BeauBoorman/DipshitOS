//! VirelaiOS serial output ring buffer (Arc5 issue #243).
//!
//! Captures the last 512 bytes of serial output so crash tombstones
//! can include a snapshot of what was on screen when the fault occurred.
//!
//! Pure BSS, no allocation, no libc/POSIX. The ring buffer wraps
//! (drop-oldest discipline) and is safe to read from exception context.
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");

/// Maximum bytes captured in the ring buffer.
pub const capacity: usize = 512;

var buf: [capacity]u8 = @as([capacity]u8, @splat(@as(u8, 0)));
var head: usize = 0; // next write position
var count: usize = 0; // bytes written (capped at capacity)

/// Append `bytes` to the ring buffer. Called from the serial TX path.
pub fn append(bytes: []const u8) void {
    for (bytes) |b| {
        buf[head] = b;
        head = (head + 1) % capacity;
        if (count < capacity) count += 1;
    }
}

/// Copy the last `max_len` bytes into `dst`. Returns the number of bytes copied.
/// Safe to call from exception context.
pub fn snapshot(dst: []u8) usize {
    const n = @min(count, dst.len);
    if (n == 0) return 0;
    const start = if (count >= capacity)
        head // ring is full, read from head
    else
        0; // ring not full, read from start
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const src_idx = (start + i) % capacity;
        dst[i] = buf[src_idx];
    }
    return n;
}

/// Reset the ring buffer (for tests).
pub fn reset() void {
    head = 0;
    count = 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "serial_ring: append and snapshot" {
    reset();
    const msg = "hello world";
    append(msg);
    var dst: [64]u8 = undefined;
    const n = snapshot(&dst);
    try std.testing.expectEqual(msg.len, n);
    try std.testing.expectEqualStrings(msg, dst[0..n]);
}

test "serial_ring: overflow wraps" {
    reset();
    // Fill the ring beyond capacity
    var data: [capacity + 100]u8 = undefined;
    @memset(&data, 'x');
    append(&data);
    var dst: [capacity]u8 = undefined;
    const n = snapshot(&dst);
    try std.testing.expectEqual(capacity, n);
    // Last bytes should be the tail of the data
    try std.testing.expectEqual(@as(u8, 'x'), dst[n - 1]);
}

test "serial_ring: empty snapshot" {
    reset();
    var dst: [64]u8 = undefined;
    const n = snapshot(&dst);
    try std.testing.expectEqual(@as(usize, 0), n);
}
