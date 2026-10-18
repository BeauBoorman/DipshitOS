//! VirelaiOS bounded per-process IPC mailbox (milestone-four follow-on 3,
//! card 3f — claim 5965).
//!
//! The first inter-process data path: `sys_ipc_send` (slot 5) copies the
//! caller's bytes in through the claim-6120 uaccess layer and enqueues
//! them into the TARGET process's ring; `sys_ipc_recv` (slot 6) copies the
//! caller's OWN ring out (also uaccess-bounded). A process can only reach
//! its own mailbox (recv) and a target's (send) — the ring is keyed by
//! process id, every byte crosses the kernel's uaccess window, and the
//! ring is reset whenever a process id is created/recycled.
//!
//! This module is PURE STORAGE — fixed BSS rings, no allocation, no
//! libc/POSIX, no policy. The syscall layer owns validation (target
//! liveness against the process registry, uaccess copy-in/copy-out,
//! truncation rules, error codes). It imports process.zig only for the
//! registry bound (`max_processes`) and knows nothing about tasks or
//! scheduling.
//!
//! Ring shape: per process id, up to `max_messages` slots of `message_max`
//! bytes each (32 × 64 B — card 4b claim 3179 raised 4 → 8, M119c issue
//! #2487 raised 8 → 32 for the stalled seat drain). FIFO
//! discipline (head = oldest). `send` enqueues
//! (a full ring refuses); `peek` copies the oldest message out WITHOUT
//! consuming it; `drop` consumes it. The recv syscall does peek → uaccess
//! copy_out → drop, so a bad user buffer (EFAULT) never loses a message.
//! Per-pid `sent`/`recv` counters (enqueues into / dequeues from each
//! ring) let the `mbox` monitor command prove draining.
//!
//! No allocation, no libc, no POSIX, no scheduler import.

const std = @import("std");
const process = @import("process.zig"); // the registry bound (max_processes)

/// Slots per process ring (32 messages outstanding per process — M119c,
/// issue #2487: raised 8 → 32, 512 → 2048 B of BSS. The seat's mailbox is
/// drained once per composite-loop iteration, and that iteration stalls
/// while the seat drains an input burst under sustained PCM; the 8-deep
/// ring then refused client posts with ENOSPC and the toast was lost —
/// pending high-water measured 7/8 on a healthy live-sound-playback run.
/// Same contract the events queue got in #2260 (16 → 64): a data-path
/// constant raised 4 → 8 by card 4b claim 3179; NOT a syscall number.
pub const max_messages: usize = 32;
/// Bytes per message slot (a message longer than this is truncated at the
/// send syscall; a recv buffer cap larger than this is clamped).
pub const message_max: usize = 64;

var storage: [process.max_processes][max_messages][message_max]u8 =
    @as([process.max_processes][max_messages][message_max]u8, @splat(@as([max_messages][message_max]u8, undefined)));
var lens: [process.max_processes][max_messages]u8 =
    @as([process.max_processes][max_messages]u8, @splat(@as([max_messages]u8, @as([max_messages]u8, @splat(@as(u8, 0))))));
var head: [process.max_processes]usize = @as([process.max_processes]usize, @splat(@as(usize, 0)));
var count: [process.max_processes]usize = @as([process.max_processes]usize, @splat(@as(usize, 0)));
/// Messages enqueued into each process's ring (by any sender targeting it).
var sent_counts: [process.max_processes]u64 = @as([process.max_processes]u64, @splat(@as(u64, 0)));
/// Messages dequeued from each process's ring (by that process's recv).
var recv_counts: [process.max_processes]u64 = @as([process.max_processes]u64, @splat(@as(u64, 0)));

fn in_range(pid: usize) bool {
    return pid < process.max_processes;
}

/// Reset every ring (boot + host tests; called by `scheduler.init` next
/// to `process.init`, so every pool reset also clears the IPC layer).
pub fn init() void {
    for (&storage) |*ring| for (ring) |*slot| @memset(slot, 0);
    for (&lens) |*lens_ring| @memset(lens_ring, 0);
    for (&head) |*h| h.* = 0;
    for (&count) |*c| c.* = 0;
    for (&sent_counts) |*s| s.* = 0;
    for (&recv_counts) |*r| r.* = 0;
}

/// Clear ONE process's ring + counters. Called right after `process.create`
/// (exec path + boot-payload registration) so a created/recycled process
/// id never inherits a stale ring from an earlier occupant.
pub fn reset(pid: usize) void {
    if (!in_range(pid)) return;
    for (&storage[pid]) |*slot| @memset(slot, 0);
    @memset(&lens[pid], 0);
    head[pid] = 0;
    count[pid] = 0;
    sent_counts[pid] = 0;
    recv_counts[pid] = 0;
}

pub const SendResult = enum { ok, full };

/// Enqueue `bytes` into process `pid`'s ring (FIFO). The caller has
/// already validated the target and bounded `bytes` to `message_max`;
/// this module only enforces the ring bound. A full ring refuses (the
/// syscall turns that into ENOSPC) without touching the stored bytes.
pub fn send(pid: usize, bytes: []const u8) SendResult {
    if (!in_range(pid) or bytes.len == 0 or bytes.len > message_max) return .ok; // defensive no-op
    if (count[pid] == max_messages) return .full;
    const slot = (head[pid] + count[pid]) % max_messages;
    @memcpy(storage[pid][slot][0..bytes.len], bytes);
    lens[pid][slot] = @intCast(bytes.len);
    count[pid] += 1;
    sent_counts[pid] +%= 1;
    return .ok;
}

/// Copy the OLDEST message of process `pid`'s ring into `dst` (up to `max`
/// bytes — truncation is documented and host-tested) WITHOUT consuming it.
/// Returns the copied length, or null when the ring is empty. The recv
/// syscall uses this so a failed uaccess copy_out never loses a message.
pub fn peek(pid: usize, dst: []u8, max: usize) ?usize {
    if (!in_range(pid) or count[pid] == 0 or max == 0) return null;
    const slot = head[pid];
    const msg_len: usize = lens[pid][slot];
    const take = @min(msg_len, @min(max, dst.len));
    @memcpy(dst[0..take], storage[pid][slot][0..take]);
    return take;
}

/// Consume the OLDEST message of process `pid`'s ring (after a successful
/// peek + copy_out). A no-op when empty.
pub fn drop(pid: usize) void {
    if (!in_range(pid) or count[pid] == 0) return;
    lens[pid][head[pid]] = 0;
    head[pid] = (head[pid] + 1) % max_messages;
    count[pid] -= 1;
    recv_counts[pid] +%= 1;
}

/// Pending (queued, not yet dropped) message count for process `pid`.
pub fn pending(pid: usize) usize {
    if (!in_range(pid)) return 0;
    return count[pid];
}

/// Per-process mailbox view for `mbox` / tests: pending queue depth and
/// the enqueue/dequeue counters (draining proof: a process whose ring is
/// drained has `recv` tracking its `sent` and a small `pending`).
pub const MailboxInfo = struct {
    pending: usize,
    sent: u64,
    recv: u64,
};

pub fn info(pid: usize) MailboxInfo {
    return .{ .pending = pending(pid), .sent = if (in_range(pid)) sent_counts[pid] else 0, .recv = if (in_range(pid)) recv_counts[pid] else 0 };
}

/// The `index`-th pending message (0 = oldest) as a byte slice into the
/// ring, for the `mbox` monitor command's raw dump. Bounds-checked; the
/// slice stays valid until the ring mutates (a command's snapshot use).
pub fn message(pid: usize, index: usize) ?[]const u8 {
    if (!in_range(pid) or index >= count[pid]) return null;
    const slot = (head[pid] + index) % max_messages;
    const msg_len: usize = lens[pid][slot];
    return storage[pid][slot][0..msg_len];
}

// ---------------------------------------------------------------------------
// Tests (host-side; the live inter-process flow is proven on VZ by
// tools/verify-live-ipc.sh, class B)
// ---------------------------------------------------------------------------

test "mailbox: send/peek/drop round-trips a message FIFO" {
    init();
    try std.testing.expectEqual(@as(usize, 0), pending(0));
    try std.testing.expectEqual(SendResult.ok, send(0, "ping 1\n"));
    try std.testing.expectEqual(SendResult.ok, send(0, "ping 2\n"));
    try std.testing.expectEqual(@as(usize, 2), pending(0));
    var buf: [message_max]u8 = undefined;
    // FIFO: peek returns the OLDEST first, and does not consume it.
    const got = peek(0, &buf, message_max).?;
    try std.testing.expectEqual(@as(usize, 7), got);
    try std.testing.expectEqualStrings("ping 1\n", buf[0..got]);
    try std.testing.expectEqual(@as(usize, 2), pending(0)); // peek is a no-op
    try std.testing.expectEqualStrings("ping 1\n", message(0, 0).?);
    try std.testing.expectEqualStrings("ping 2\n", message(0, 1).?);
    try std.testing.expect(message(0, 2) == null);
    drop(0);
    try std.testing.expectEqual(@as(usize, 1), pending(0));
    try std.testing.expectEqualStrings("ping 2\n", message(0, 0).?);
    drop(0);
    try std.testing.expectEqual(@as(usize, 0), pending(0));
    try std.testing.expect(peek(0, &buf, message_max) == null);
}

test "mailbox: ring wraps and a full ring refuses without losing bytes" {
    init();
    // Fill all 8 slots (the ring then wraps on the next cycle).
    for (1..max_messages + 1) |_| try std.testing.expectEqual(SendResult.ok, send(0, "m"));
    try std.testing.expectEqual(@as(usize, max_messages), pending(0));
    // The 9th send refuses: ENOSPC at the syscall layer.
    try std.testing.expectEqual(SendResult.full, send(0, "n"));
    try std.testing.expectEqual(@as(usize, max_messages), pending(0));
    // Drain one, then a new send lands at the wrapped slot 0 (the slot
    // freed by the drop — head was 1, count 7, so the new message goes to
    // (1 + 7) % 8 = 0). Index 0 is the second-oldest message now; the new
    // "z" is the LAST pending index (max_messages - 1 = 7).
    drop(0);
    try std.testing.expectEqual(SendResult.ok, send(0, "z"));
    for (0..max_messages - 1) |i| try std.testing.expectEqualStrings("m", message(0, i).?);
    try std.testing.expectEqualStrings("z", message(0, max_messages - 1).?);
    // Drain everything: the ring is empty and the counters track exactly
    // (max_messages + 1 = 9 sends, 9 drops).
    while (pending(0) > 0) drop(0);
    const info0 = info(0);
    try std.testing.expectEqual(@as(u64, max_messages + 1), info0.sent);
    try std.testing.expectEqual(@as(u64, max_messages + 1), info0.recv);
    try std.testing.expectEqual(@as(usize, 0), info0.pending);
}

test "mailbox: send/peek respect the 64-byte slot bound and truncate" {
    init();
    // A message at the slot bound stores exactly message_max bytes; anything
    // longer is refused by the module's defensive bound (the syscall layer
    // truncates BEFORE calling send — the module never stores a partial
    // oversized message from a caller bug).
    try std.testing.expectEqual(SendResult.ok, send(0, &@as([message_max:0]u8, @splat("x"[0]))));
    try std.testing.expectEqual(SendResult.ok, send(0, &@as([(message_max + 1):0]u8, @splat("y"[0])))); // defensive no-op
    try std.testing.expectEqual(@as(usize, 1), pending(0));
    const msg = message(0, 0).?;
    try std.testing.expectEqual(@as(usize, message_max), msg.len);
    // peek with a max smaller than the message truncates the copy without
    // consuming anything.
    var buf: [message_max]u8 = undefined;
    const got = peek(0, &buf, 8).?;
    try std.testing.expectEqual(@as(usize, 8), got);
    try std.testing.expectEqualStrings("xxxxxxxx", buf[0..8]);
    try std.testing.expectEqual(@as(usize, 1), pending(0));
}

test "mailbox: reset clears a ring and its counters (recycled process ids)" {
    init();
    _ = send(0, "ping 1\n");
    _ = send(1, "ping 2\n");
    try std.testing.expectEqual(@as(usize, 1), pending(0));
    try std.testing.expectEqual(@as(usize, 1), pending(1));
    reset(0); // process 0 is reaped/recycled: its ring must not leak
    try std.testing.expectEqual(@as(usize, 0), pending(0));
    try std.testing.expectEqual(@as(usize, 0), info(0).sent);
    try std.testing.expectEqual(@as(usize, 0), info(0).recv);
    // Process 1's ring is untouched (isolation between pids).
    try std.testing.expectEqual(@as(usize, 1), pending(1));
    try std.testing.expectEqualStrings("ping 2\n", message(1, 0).?);
    // init() clears everything.
    init();
    try std.testing.expectEqual(@as(usize, 0), pending(1));
}

test "mailbox: out-of-range pids are defensive no-ops" {
    init();
    try std.testing.expectEqual(SendResult.ok, send(process.max_processes, "x"));
    var junk: [message_max]u8 = @as([message_max]u8, @splat(@as(u8, 0)));
    try std.testing.expect(peek(process.max_processes, &junk, 1) == null);
    drop(process.max_processes);
    try std.testing.expectEqual(@as(usize, 0), pending(process.max_processes));
    try std.testing.expect(message(process.max_processes, 0) == null);
    reset(process.max_processes);
}
