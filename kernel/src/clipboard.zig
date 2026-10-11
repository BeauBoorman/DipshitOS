//! VirelaiOS bounded kernel clipboard (milestone fourteen, card S1 — claim
//! 0169, issue #175).
//!
//! ONE shared text buffer for the whole machine: `sys_clipboard_set` (slot
//! 38) copies a caller's bytes in through the claim-6120 uaccess layer and
//! stores them (truncated honestly at the fixed bound — the ipc/udp
//! truncation pattern); `sys_clipboard_get` (slot 39) copies the current
//! contents OUT through uaccess WITHOUT consuming them (a clipboard is a
//! shared, non-destructive read — unlike the mailbox, which drops on recv).
//! The EL1h half is the monitor `clip` command (`clip <text...>` sets it,
//! `clip` prints it).
//!
//! This module is PURE STORAGE — a fixed BSS buffer, a length, and a set
//! counter; no allocation, no libc/POSIX, no policy. The syscall layer
//! owns validation (process-caller check, uaccess copy-in/copy-out,
//! truncation rules, error codes). The buffer is deliberately
//! machine-global (one clipboard, not per-process): the shared-service
//! point is that a value set by one EL0 program is read by another.

const std = @import("std");

/// Bytes in the shared buffer. Sized to round-trip NOTEPAD's full 512-byte
/// editor buffer without truncation; a longer set is truncated honestly at
/// the syscall layer (the `set` bound here).
pub const capacity: usize = 512;

var buffer: [capacity]u8 = @as([capacity]u8, @splat(@as(u8, 0)));
var len: usize = 0;
var set_count: u64 = 0;

/// Reset the buffer + counter (kernel boot + host tests). The syscall
/// layer calls this from its own `init`.
pub fn init() void {
    @memset(&buffer, 0);
    len = 0;
    set_count = 0;
}

/// Store `bytes` (truncated at `capacity`), overwriting any previous
/// contents. Returns the stored length (0 for an empty set — which also
/// clears the buffer). A shorter set shrinks the readable region.
pub fn set(bytes: []const u8) usize {
    const n = @min(bytes.len, capacity);
    @memcpy(buffer[0..n], bytes[0..n]);
    len = n;
    set_count +%= 1;
    return n;
}

/// Copy the current contents into `dst` (truncated to `dst.len`) WITHOUT
/// consuming them. Returns the copied length; 0 when the clipboard is
/// empty or `dst` is empty.
pub fn get(dst: []u8) usize {
    const n = @min(len, dst.len);
    @memcpy(dst[0..n], buffer[0..n]);
    return n;
}

/// Current stored length (0 when empty). The `clip` monitor command uses
/// this to report the empty case.
pub fn current_len() usize {
    return len;
}

/// Number of `set` calls since the last `init` (diagnostic / test counter).
pub fn sets() u64 {
    return set_count;
}

// ---------------------------------------------------------------------------
// Tests (host-side; the live EL0 round trip is proven on VZ by
// tools/verify-live-clipboard.sh, class B)
// ---------------------------------------------------------------------------

test "clipboard: set/get round-trips bytes without consuming" {
    init();
    try std.testing.expectEqual(@as(usize, 0), current_len());
    const text = "copy me";
    try std.testing.expectEqual(@as(usize, text.len), set(text));
    try std.testing.expectEqual(@as(usize, text.len), current_len());
    var buf: [capacity]u8 = undefined;
    const n = get(&buf);
    try std.testing.expectEqual(@as(usize, text.len), n);
    try std.testing.expectEqualStrings(text, buf[0..n]);
    // get is non-destructive.
    try std.testing.expectEqual(@as(usize, text.len), current_len());
    try std.testing.expectEqual(@as(u64, 1), sets());
}

test "clipboard: set truncates at the bound and a shorter set shrinks" {
    init();
    const long = &@as([(capacity + 10):0]u8, @splat("x"[0]));
    try std.testing.expectEqual(capacity, set(long));
    try std.testing.expectEqual(capacity, current_len());

    // A shorter overwrite shrinks the readable region: stale trailing bytes
    // are never returned.
    try std.testing.expectEqual(@as(usize, 3), set("abc"));
    var buf: [capacity]u8 = undefined;
    const n = get(&buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("abc", buf[0..n]);

    // An empty set clears it.
    try std.testing.expectEqual(@as(usize, 0), set(""));
    try std.testing.expectEqual(@as(usize, 0), current_len());
    try std.testing.expectEqual(@as(usize, 0), get(&buf));
}

test "clipboard: get truncates to a smaller destination" {
    init();
    _ = set("hello world");
    var small: [5]u8 = undefined;
    const n = get(&small);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", small[0..5]);
    // The clipboard still holds the full text.
    try std.testing.expectEqual(@as(usize, 11), current_len());
}

test "clipboard: init resets the buffer and the set counter" {
    init();
    _ = set("first");
    _ = set("second");
    try std.testing.expectEqual(@as(u64, 2), sets());
    init();
    try std.testing.expectEqual(@as(usize, 0), current_len());
    try std.testing.expectEqual(@as(u64, 0), sets());
    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), get(&buf));
}
