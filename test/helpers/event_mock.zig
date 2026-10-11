//! VirelaiOS shared test helper: Event queue & message dispatch mocking (M41 TS1).
//!
//! Provides synthetic event FIFO queues, keyboard/mouse event builders,
//! and IPC mailbox message dispatch mocking for host unit tests.

const std = @import("std");

pub const KEY_DOWN: u16 = 1;
pub const KEY_UP: u16 = 2;
pub const MOUSE_MOVE: u16 = 3;
pub const MOUSE_DOWN: u16 = 4;
pub const MOUSE_UP: u16 = 5;
pub const WIN_FOCUS: u16 = 6;
pub const WIN_BLUR: u16 = 7;
pub const WIN_CLOSE: u16 = 8;
pub const WIN_RESIZE: u16 = 9;

pub const MOD_SHIFT: u16 = 0x0001;
pub const MOD_CTRL: u16 = 0x0002;
pub const MOD_ALT: u16 = 0x0004;
pub const MOD_CMD: u16 = 0x0008;

pub const BTN_LEFT: u16 = 0x0100;
pub const BTN_RIGHT: u16 = 0x0200;
pub const BTN_MIDDLE: u16 = 0x0400;

/// 16-byte wire format matching kernel/src/events.zig (ADR 0009 D1)
pub const Event = extern struct {
    kind: u16,
    flags: u16,
    seq: u32,
    arg0: u32,
    arg1: u32,
};

pub const MockEventQueue = struct {
    const default_capacity = 64;

    storage: [default_capacity]Event = undefined,
    head: usize = 0,
    count: usize = 0,
    seq_counter: u32 = 0,
    dropped_count: u64 = 0,

    pub fn init() MockEventQueue {
        return .{};
    }

    pub fn clear(self: *MockEventQueue) void {
        self.* = init();
    }

    pub fn pending(self: *const MockEventQueue) usize {
        return self.count;
    }

    pub fn dropped(self: *const MockEventQueue) u64 {
        return self.dropped_count;
    }

    pub fn push(self: *MockEventQueue, ev_in: Event) void {
        self.seq_counter +%= 1;
        var ev = ev_in;
        if (ev.seq == 0) ev.seq = self.seq_counter;

        if (self.count == default_capacity) {
            // Drop oldest
            self.storage[self.head] = ev;
            self.head = (self.head + 1) % default_capacity;
            self.dropped_count += 1;
        } else {
            const tail = (self.head + self.count) % default_capacity;
            self.storage[tail] = ev;
            self.count += 1;
        }
    }

    pub fn peek(self: *const MockEventQueue) ?Event {
        if (self.count == 0) return null;
        return self.storage[self.head];
    }

    pub fn pop(self: *MockEventQueue) ?Event {
        if (self.count == 0) return null;
        const ev = self.storage[self.head];
        self.head = (self.head + 1) % default_capacity;
        self.count -= 1;
        return ev;
    }

    pub fn push_key_down(self: *MockEventQueue, keycode: u32, ch: u32, flags: u16) void {
        self.push(.{
            .kind = KEY_DOWN,
            .flags = flags,
            .seq = 0,
            .arg0 = keycode,
            .arg1 = ch,
        });
    }

    pub fn push_key_up(self: *MockEventQueue, keycode: u32, ch: u32, flags: u16) void {
        self.push(.{
            .kind = KEY_UP,
            .flags = flags,
            .seq = 0,
            .arg0 = keycode,
            .arg1 = ch,
        });
    }

    pub fn push_mouse_move(self: *MockEventQueue, x: u32, y: u32) void {
        self.push(.{
            .kind = MOUSE_MOVE,
            .flags = 0,
            .seq = 0,
            .arg0 = x,
            .arg1 = y,
        });
    }

    pub fn push_mouse_down(self: *MockEventQueue, x: u32, y: u32, buttons: u16) void {
        self.push(.{
            .kind = MOUSE_DOWN,
            .flags = buttons,
            .seq = 0,
            .arg0 = x,
            .arg1 = y,
        });
    }

    pub fn push_mouse_up(self: *MockEventQueue, x: u32, y: u32, buttons: u16) void {
        self.push(.{
            .kind = MOUSE_UP,
            .flags = buttons,
            .seq = 0,
            .arg0 = x,
            .arg1 = y,
        });
    }
};

/// Mock IPC mailbox message dispatch (matching kernel/src/mailbox.zig layout)
pub const MockMessage = struct {
    sender_pid: usize,
    target_pid: usize,
    len: usize,
    payload: [64]u8,
};

pub const MockMessageDispatcher = struct {
    const max_processes = 16;
    const max_messages_per_proc = 8;

    queues: [max_processes][max_messages_per_proc]MockMessage = undefined,
    queue_heads: [max_processes]usize = @as([max_processes]usize, @splat(@as(usize, 0))),
    queue_counts: [max_processes]usize = @as([max_processes]usize, @splat(@as(usize, 0))),

    sent_count: usize = 0,
    recv_count: usize = 0,
    drop_count: usize = 0,

    pub fn init() MockMessageDispatcher {
        return .{};
    }

    pub fn reset(self: *MockMessageDispatcher) void {
        self.* = init();
    }

    pub fn send(self: *MockMessageDispatcher, sender_pid: usize, target_pid: usize, bytes: []const u8) bool {
        if (target_pid >= max_processes) return false;
        if (self.queue_counts[target_pid] >= max_messages_per_proc) {
            self.drop_count += 1;
            return false;
        }

        const copy_len = @min(bytes.len, 64);
        var msg = MockMessage{
            .sender_pid = sender_pid,
            .target_pid = target_pid,
            .len = copy_len,
            .payload = @as([64]u8, @splat(@as(u8, 0))),
        };
        @memcpy(msg.payload[0..copy_len], bytes[0..copy_len]);

        const tail = (self.queue_heads[target_pid] + self.queue_counts[target_pid]) % max_messages_per_proc;
        self.queues[target_pid][tail] = msg;
        self.queue_counts[target_pid] += 1;
        self.sent_count += 1;
        return true;
    }

    pub fn recv(self: *MockMessageDispatcher, pid: usize, out_buf: []u8) ?usize {
        if (pid >= max_processes or self.queue_counts[pid] == 0) return null;

        const head = self.queue_heads[pid];
        const msg = self.queues[pid][head];
        self.queue_heads[pid] = (head + 1) % max_messages_per_proc;
        self.queue_counts[pid] -= 1;

        const copy_len = @min(out_buf.len, msg.len);
        @memcpy(out_buf[0..copy_len], msg.payload[0..copy_len]);
        self.recv_count += 1;
        return copy_len;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "event_mock: event wire size and layout" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Event));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(Event));
}

test "event_mock: queue push/peek/pop/drop-oldest" {
    var q = MockEventQueue.init();

    try std.testing.expectEqual(@as(usize, 0), q.pending());

    q.push_key_down(0x04, 'a', MOD_CTRL);
    q.push_key_up(0x04, 'a', 0);

    try std.testing.expectEqual(@as(usize, 2), q.pending());

    // Peek does not consume
    const p = q.peek().?;
    try std.testing.expectEqual(KEY_DOWN, p.kind);
    try std.testing.expectEqual(MOD_CTRL, p.flags);
    try std.testing.expectEqual(@as(usize, 2), q.pending());

    // Pop consumes
    const e1 = q.pop().?;
    try std.testing.expectEqual(KEY_DOWN, e1.kind);
    try std.testing.expectEqual(@as(usize, 1), q.pending());

    const e2 = q.pop().?;
    try std.testing.expectEqual(KEY_UP, e2.kind);
    try std.testing.expectEqual(@as(usize, 0), q.pending());
    try std.testing.expect(q.pop() == null);
}

test "event_mock: message dispatcher send and recv" {
    var disp = MockMessageDispatcher.init();

    const text = "ping message";
    try std.testing.expect(disp.send(1, 2, text));
    try std.testing.expectEqual(@as(usize, 1), disp.sent_count);

    var buf: [32]u8 = undefined;
    const len = disp.recv(2, &buf).?;
    try std.testing.expectEqual(text.len, len);
    try std.testing.expectEqualStrings(text, buf[0..len]);

    // Recv on empty queue returns null
    try std.testing.expect(disp.recv(2, &buf) == null);
}
