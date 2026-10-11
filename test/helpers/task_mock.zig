//! VirelaiOS shared test helper: Task frames, registers & CPU context mocking (M41 TS1).
//!
//! Provides synthetic CPU vector frames (matching exceptions.VectorFrame layout),
//! register read/write helpers, calling convention argument marshaling,
//! and mock task lifecycle primitives for host unit tests.

const std = @import("std");

/// Vector frame slot count (32 u64 registers) matching kernel exceptions.VectorFrame
pub const vector_frame_slots: usize = 32;
pub const VectorFrame = [vector_frame_slots]u64;

/// Map architectural register (0..31) to frame slot index.
/// Matches kernel/src/exceptions.zig layout.
pub fn frame_index(reg: u5) ?usize {
    if (reg <= 17) return 18 - 2 * (@as(usize, reg) / 2) + (@as(usize, reg) & 1);
    if (reg == 30) return 0;
    if (reg == 29) return 20;
    if (reg >= 19 and reg <= 28) return @as(usize, if (reg % 2 == 0) 51 else 49) - reg;
    return null;
}

pub fn fresh_frame() VectorFrame {
    return @as([vector_frame_slots]u64, @splat(@as(u64, 0)));
}

pub fn get_reg(frame: *const VectorFrame, reg: u5) u64 {
    const idx = frame_index(reg) orelse return 0;
    return frame[idx];
}

pub fn set_reg(frame: *VectorFrame, reg: u5, val: u64) bool {
    const idx = frame_index(reg) orelse return false;
    frame[idx] = val;
    return true;
}

pub const Args = [6]u64;

pub fn set_args(frame: *VectorFrame, args: Args) void {
    inline for (0..6) |i| {
        _ = set_reg(frame, @intCast(i), args[i]);
    }
}

pub fn get_args(frame: *const VectorFrame) Args {
    var args: Args = undefined;
    inline for (0..6) |i| {
        args[i] = get_reg(frame, @intCast(i));
    }
    return args;
}

pub fn set_ret(frame: *VectorFrame, val: u64) void {
    _ = set_reg(frame, 0, val);
}

pub fn get_ret(frame: *const VectorFrame) u64 {
    return get_reg(frame, 0);
}

pub fn set_syscall_num(frame: *VectorFrame, num: u64) void {
    _ = set_reg(frame, 8, num);
}

pub fn get_syscall_num(frame: *const VectorFrame) u64 {
    return get_reg(frame, 8);
}

pub const TaskState = enum {
    ready,
    running,
    blocked,
    exited,
};

pub const MockTask = struct {
    id: usize,
    name: [32]u8 = @as([32]u8, @splat(@as(u8, 0))),
    name_len: usize = 0,
    state: TaskState = .ready,
    frame: VectorFrame = fresh_frame(),
    exit_status: i32 = 0,
    ticks_run: u64 = 0,

    pub fn init(id: usize, name_str: []const u8) MockTask {
        var t = MockTask{
            .id = id,
        };
        const len = @min(name_str.len, t.name.len);
        @memcpy(t.name[0..len], name_str[0..len]);
        t.name_len = len;
        return t;
    }

    pub fn get_name(self: *const MockTask) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const MockScheduler = struct {
    const max_tasks = 16;

    tasks: [max_tasks]?MockTask = @as([max_tasks]?MockTask, @splat(@as(?MockTask, null))),
    current_task: ?usize = null,
    total_ticks: u64 = 0,

    pub fn init() MockScheduler {
        return .{};
    }

    pub fn spawn(self: *MockScheduler, name: []const u8) ?usize {
        for (0..max_tasks) |i| {
            if (self.tasks[i] == null) {
                self.tasks[i] = MockTask.init(i, name);
                return i;
            }
        }
        return null;
    }

    pub fn get_task(self: *MockScheduler, id: usize) ?*MockTask {
        if (id >= max_tasks) return null;
        if (self.tasks[id]) |*t| return t;
        return null;
    }

    pub fn schedule_next(self: *MockScheduler) ?usize {
        const start = if (self.current_task) |curr| (curr + 1) % max_tasks else 0;
        for (0..max_tasks) |offset| {
            const idx = (start + offset) % max_tasks;
            if (self.tasks[idx]) |*t| {
                if (t.state == .ready) {
                    if (self.current_task) |curr| {
                        if (self.tasks[curr]) |*prev| {
                            if (prev.state == .running) prev.state = .ready;
                        }
                    }
                    t.state = .running;
                    self.current_task = idx;
                    return idx;
                }
            }
        }
        return null;
    }

    pub fn tick(self: *MockScheduler) void {
        self.total_ticks += 1;
        if (self.current_task) |curr| {
            if (self.tasks[curr]) |*t| {
                if (t.state == .running) {
                    t.ticks_run += 1;
                }
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "task_mock: register read/write and fresh_frame" {
    var frame = fresh_frame();

    // Verify all slots start at 0
    for (frame) |slot| {
        try std.testing.expectEqual(@as(u64, 0), slot);
    }

    // Set and read x0..x7
    for (0..8) |r| {
        const reg: u5 = @intCast(r);
        const val: u64 = @as(u64, 0x1000) + reg;
        try std.testing.expect(set_reg(&frame, reg, val));
        try std.testing.expectEqual(val, get_reg(&frame, reg));
    }

    // Calling convention args marshaling
    const args: Args = .{ 10, 20, 30, 40, 50, 60 };
    set_args(&frame, args);
    try std.testing.expectEqual(args, get_args(&frame));

    // Return value and syscall number
    set_ret(&frame, 42);
    try std.testing.expectEqual(@as(u64, 42), get_ret(&frame));

    set_syscall_num(&frame, 65);
    try std.testing.expectEqual(@as(u64, 65), get_syscall_num(&frame));
}

test "task_mock: mock task lifecycle and scheduler" {
    var sched = MockScheduler.init();

    const id1 = sched.spawn("worker_1").?;
    const id2 = sched.spawn("worker_2").?;

    try std.testing.expectEqualStrings("worker_1", sched.get_task(id1).?.get_name());
    try std.testing.expectEqualStrings("worker_2", sched.get_task(id2).?.get_name());

    const next1 = sched.schedule_next().?;
    try std.testing.expectEqual(id1, next1);
    try std.testing.expectEqual(TaskState.running, sched.get_task(id1).?.state);

    sched.tick();
    sched.tick();
    try std.testing.expectEqual(@as(u64, 2), sched.get_task(id1).?.ticks_run);

    const next2 = sched.schedule_next().?;
    try std.testing.expectEqual(id2, next2);
    try std.testing.expectEqual(TaskState.ready, sched.get_task(id1).?.state);
    try std.testing.expectEqual(TaskState.running, sched.get_task(id2).?.state);
}
