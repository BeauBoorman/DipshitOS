//! M19 P2 (issue #291): I/O redirection — a bounded capture buffer for `>`
//! and `>>` (captures a command's stdout into a buffer to be written to a
//! file) and a feed adapter for `<` (reads a pre-loaded buffer as stdin).
//!
//! Bounded and heap-free: one 4 KiB BSS capture buffer, no allocation.
//!
//! Two consumers:
//!   * The shell's `>`, `>>`, `<` operators use the console adapters below.
//!   * Host tests exercise them through MockConsole round-trips.

const std = @import("std");
const console = @import("console.zig");
const virtio_file = @import("virtio_file.zig"); // HF6: the host file channel is the only file store
const trust = @import("trust.zig"); // M50 TS2 (#1136, ADR 0024 D4): the kernel-actor gate for redirect I/O

/// The capture buffer size — same as the pipe buffer (4 KiB).
pub const capture_capacity: usize = 4096;

var capture_buf: [capture_capacity]u8 = undefined;
var capture_len: usize = 0;

/// Clear the capture buffer before a new redirection command.
pub fn reset_capture() void {
    capture_len = 0;
}

/// Bytes captured so far.
pub fn captured() []const u8 {
    return capture_buf[0..capture_len];
}

/// Bytes captured so far (mutable, for append path).
pub fn captured_mut() []u8 {
    return capture_buf[0..capture_len];
}

/// Space left in the capture buffer.
pub fn capture_capacity_left() usize {
    return capture_capacity - capture_len;
}

/// Append `bytes` to the capture buffer; returns the number stored.
pub fn capture_write(bytes: []const u8) usize {
    const n = @min(bytes.len, capture_capacity_left());
    @memcpy(capture_buf[capture_len..][0..n], bytes[0..n]);
    capture_len += n;
    return n;
}

// ---------------------------------------------------------------------------
// Capture console — a command's stdout during `a > file` / `a >> file`
// ---------------------------------------------------------------------------

const CaptureCtx = struct {};
var capture_ctx: CaptureCtx = .{};
// ADR 0005 (claim 0015): vtables are built at runtime into BSS.
var capture_vtable: console.Console.VTable = undefined;
var capture_vtable_ready = false;
fn ensure_capture_vtable() *const console.Console.VTable {
    if (!capture_vtable_ready) {
        capture_vtable = .{
            .write = capture_write_fn,
            .flush = capture_flush_fn,
            .readByte = capture_read_fn,
        };
        capture_vtable_ready = true;
    }
    return &capture_vtable;
}
fn capture_write_fn(_: *anyopaque, bytes: []const u8) void {
    _ = capture_write(bytes);
}
fn capture_flush_fn(_: *anyopaque) void {}
fn capture_read_fn(_: *anyopaque) ?u8 {
    return null; // no stdin during output redirection
}

/// A console whose writes are captured and whose reads return nothing.
pub fn capture_console() console.Console {
    return .{ .ctx = &capture_ctx, .vtable = ensure_capture_vtable() };
}

/// Write captured bytes to a file on the HOST SHARE through the queue-5
/// file channel (open-create + truncate + chunked write + close). Returns
/// an error message for the console (or null on success). M34 HF6 (issue
/// #740): the ESP/FAT write paths are gone — the share is the only file
/// store.
pub fn write_captured_to_file(name: []const u8, content: []const u8) ?[]const u8 {
    // M50 TS2 (ADR 0024 D4/D8): the kernel-actor gate (secret paths deny).
    if (trust.check(trust.kernel_actor(), .host, name, .write) != .allow) return "redirect: permission denied";
    const st = virtio_file.write_whole(name, content);
    if (st != virtio_file.st_ok) {
        return switch (st) {
            virtio_file.st_host_error => "redirect: no host file channel",
            virtio_file.st_not_found => "redirect: file not found",
            virtio_file.st_handle => "redirect: host handle table full",
            else => "redirect: file write failed",
        };
    }
    return null;
}

/// Read a file from the HOST SHARE into a caller-provided buffer. Returns
/// the slice of `out` holding the content, or null (absent / too big / no
/// channel). M34 HF6 (issue #740): the ESP/FAT read paths are gone.
pub fn read_file_into(name: []const u8, out: []u8) ?[]const u8 {
    // M50 TS2 (ADR 0024 D4/D8): the kernel-actor gate (secret paths deny).
    if (trust.check(trust.kernel_actor(), .host, name, .read) != .allow) return null;
    var st = virtio_file.StatResult{};
    if (virtio_file.stat(name, &st) != virtio_file.st_ok or st.is_dir) return null;
    if (st.size > out.len) return null;
    const got = virtio_file.read_into(name, st.size, out) orelse return null;
    return out[0..got];
}

// ---------------------------------------------------------------------------
// Feed console — a command's stdin during `a < file`
// ---------------------------------------------------------------------------

const FeedCtx = struct {
    inner: console.Console,
    data: []const u8,
    pos: usize,
};
var feed_ctx: FeedCtx = undefined;
var feed_vtable: console.Console.VTable = undefined;
var feed_vtable_ready = false;
fn ensure_feed_vtable() *const console.Console.VTable {
    if (!feed_vtable_ready) {
        feed_vtable = .{
            .write = feed_write_fn,
            .flush = feed_flush_fn,
            .readByte = feed_read_fn,
        };
        feed_vtable_ready = true;
    }
    return &feed_vtable;
}
fn feed_write_fn(ctx: *anyopaque, bytes: []const u8) void {
    const fc: *FeedCtx = @ptrCast(@alignCast(ctx));
    fc.inner.write(bytes);
}
fn feed_flush_fn(ctx: *anyopaque) void {
    const fc: *FeedCtx = @ptrCast(@alignCast(ctx));
    fc.inner.flush();
}
fn feed_read_fn(ctx: *anyopaque) ?u8 {
    const fc: *FeedCtx = @ptrCast(@alignCast(ctx));
    if (fc.pos >= fc.data.len) return null;
    const b = fc.data[fc.pos];
    fc.pos += 1;
    return b;
}

/// A console whose reads pull from `data` and whose writes pass through
/// to `inner`. Used as the command's console during `a < file`.
pub fn feed_console(inner: console.Console, data: []const u8) console.Console {
    feed_ctx.inner = inner;
    feed_ctx.data = data;
    feed_ctx.pos = 0;
    return .{ .ctx = &feed_ctx, .vtable = ensure_feed_vtable() };
}

// ---------------------------------------------------------------------------
// Tests (host-side; no hardware)
// ---------------------------------------------------------------------------

test "redirect: capture console captures writes" {
    reset_capture();
    const cap = capture_console();
    cap.write("hello redirect");
    cap.putc('\n');
    try std.testing.expectEqualStrings("hello redirect\n", captured());
    try std.testing.expect(captured().len > 0);
}

test "redirect: capture console overflow is dropped" {
    reset_capture();
    const cap = capture_console();
    const big = &@as([(capture_capacity + 100):0]u8, @splat("x"[0]));
    cap.write(big);
    try std.testing.expectEqual(capture_capacity, captured().len);
}

test "redirect: reset clears capture buffer" {
    reset_capture();
    const cap = capture_console();
    cap.write("test");
    try std.testing.expect(captured().len > 0);
    reset_capture();
    try std.testing.expectEqual(@as(usize, 0), captured().len);
}

test "redirect: feed console feeds data as stdin" {
    var mock = console.MockConsole(256){};
    const real = mock.console();
    const feed = feed_console(real, "hello stdin");
    var got: [32]u8 = undefined;
    var n: usize = 0;
    while (feed.readByte()) |b| : (n += 1) {
        if (n < got.len) got[n] = b;
    }
    try std.testing.expectEqualStrings("hello stdin", got[0..n]);
}

test "redirect: feed console passes writes through" {
    var mock = console.MockConsole(256){};
    const real = mock.console();
    const feed = feed_console(real, "input");
    // Drain all input bytes
    while (feed.readByte()) |_| {}
    // Writes should go to the real console
    feed.puts("output");
    try std.testing.expectEqualStrings("output", mock.contents());
}

test "redirect: feed console exhausts input then returns null" {
    var mock = console.MockConsole(256){};
    const real = mock.console();
    const feed = feed_console(real, "ab");
    try std.testing.expect(feed.readByte() != null);
    try std.testing.expect(feed.readByte() != null);
    try std.testing.expectEqual(@as(?u8, null), feed.readByte());
}
