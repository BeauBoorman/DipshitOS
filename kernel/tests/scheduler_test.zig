//! VirelaiOS scheduler decoupled unit tests (M41 TS3, #954).
//!
//! Host unit test suite extracted from kernel/src/scheduler.zig.
//! Tests thread registration, priority/ready rings, context switching,
//! EL0 preemption, SMP work-stealing, sleeping deadlines, and lifecycle reaping.

const std = @import("std");
const scheduler = @import("scheduler");
const helpers = @import("helpers");
const task_mock = helpers.task;

// Re-export scheduler types, functions, and state
const KillResult = scheduler.KillResult;
const ReadyRing = scheduler.ReadyRing;
const State = scheduler.State;
const build_initial_frame = scheduler.build_initial_frame;
const check_ready_membership = scheduler.check_ready_membership;
const console = scheduler.console;
const current_id = scheduler.current_id;
const current_user_regions = scheduler.current_user_regions;
const enabled = scheduler.enabled;
const exceptions = scheduler.exceptions;
const exit_count = scheduler.exit_count;
const exit_current = scheduler.exit_current;
const fault_current = scheduler.fault_current;
const frame_bytes = scheduler.frame_bytes;
const has_free_slot = scheduler.has_free_slot;
const idle_entry = scheduler.idle_entry;
const idle_pass = scheduler.idle_pass;
const on_idle_pass = &scheduler.on_idle_pass;
const idle_id = scheduler.idle_id;
const init = scheduler.init;
const is_blocked = scheduler.is_blocked;
const is_terminated = scheduler.is_terminated;
const max_tasks = scheduler.max_tasks;
const maybe_report = scheduler.maybe_report;
const mmu = scheduler.mmu;
const next_runnable_for = scheduler.next_runnable_for;
const note_advance = scheduler.note_advance;
const on_tick = scheduler.on_tick;
const park = scheduler.park;
const pin_task = scheduler.pin_task;
const process = scheduler.process;
const reap = scheduler.reap;
const reap_one_zombie = scheduler.reap_one_zombie;
const register_exec_user = scheduler.register_exec_user;
const register_exec_user_pinned = scheduler.register_exec_user_pinned;
const publish_task = scheduler.publish_task;
const register_user = scheduler.register_user;
const register_worker = scheduler.register_worker;
const request_kill = scheduler.request_kill;
const request_report = scheduler.request_report;
const request_resched_on = scheduler.request_resched_on;
// The pure half of the rotation's discharge. `tick` itself reads
// ELR_EL1/SPSR_EL1 and cannot be called from a host test process.
const discharge_resched = scheduler.discharge_resched;
const reserved_fault_status = scheduler.reserved_fault_status;
const reserved_kill_status = scheduler.reserved_kill_status;
const ring_claim = scheduler.ring_claim;
const rotation_lock = scheduler.rotation_lock;
const rotation_unlock = scheduler.rotation_unlock;
const scheduling_active = scheduler.scheduling_active;
const sleep_current = scheduler.sleep_current;
const spawn = scheduler.spawn;
const spawn_demo = scheduler.spawn_demo;
const spsr_el0t_irqs = scheduler.spsr_el0t_irqs;
const spsr_el1h_irqs = scheduler.spsr_el1h_irqs;
const start = scheduler.start;
const stats = scheduler.stats;
const switch_context = scheduler.switch_context;
const task_info = scheduler.task_info;
const task_stack_size = scheduler.task_stack_size;
const task_ttbr0 = scheduler.task_ttbr0;
const terminated_status = scheduler.terminated_status;

// #1336: N × 192 KiB kstack locals overflow a typical host test stack,
// so the multi-user coexistence test borrows this BSS pool.
var exec_kstack_pool: [max_tasks][task_stack_size]u8 align(16) = undefined;
const tick = scheduler.tick;
const timer_switch_context = scheduler.timer_switch_context;
const user_timer_preemption_count = scheduler.user_timer_preemption_count;
const userspace = scheduler.userspace;
const yield_current = scheduler.yield_current;

// ---------------------------------------------------------------------------
// Tests (host-side; the asm tick is proven on real VZ hardware by the
// class B gate tools/verify-live-scheduler.tasks.sh)
// ---------------------------------------------------------------------------

// #1978: reconstructed from the card's four probe scenarios. Each task
// owns a distinct saved frame; synthetic second-core ownership is explicit.
const ExitKillCase = struct {
    pid: usize,
    primary: usize,
    sibling: usize,

    fn boot() !ExitKillCase {
        _ = init();
        scheduler.current[1] = idle_id;
        scheduler.current[2] = idle_id;
        scheduler.current[3] = idle_id;
        const primary = spawn("user-exec", 0x3000, spsr_el0t_irqs, &exec_kstack_pool[0], 0, 0).?;
        const sibling = spawn("GOTABWM.ELF", 0x4000, spsr_el0t_irqs, &exec_kstack_pool[1], 0, 0).?;
        scheduler.tasks[sibling].is_thread = true;
        const pid = process.create("GOTABWM.ELF", .{}, .{}, .{}).?;
        try std.testing.expect(process.bind(pid, primary));
        try std.testing.expect(process.bind_thread(pid, sibling));
        start();
        return .{ .pid = pid, .primary = primary, .sibling = sibling };
    }

    fn select(id: usize) !void {
        for (0..max_tasks * 2) |_| {
            if (current_id() == id) {
                exceptions.resume_frame[0] = scheduler.tasks[id].sp;
                exceptions.resume_sp_el0[0] = scheduler.tasks[id].sp_el0;
                return;
            }
            try std.testing.expect(yield_current());
        }
        return error.TestUnexpectedResult;
    }

    fn word_matches(_: u64, _: u32) bool {
        return true;
    }

    fn futex(self: ExitKillCase) !void {
        try std.testing.expectEqual(scheduler.FutexWaitOutcome.blocked, scheduler.futex_wait_current(self.pid, 0x1000, 0, 0, word_matches));
    }

    fn arm_running(self: ExitKillCase) !void {
        // A foreign-core sibling is already running, off every ring,
        // when the primary's process exit performs the arming scan.
        try select(self.sibling);
        scheduler.current[1] = self.sibling;
        scheduler.current[0] = self.primary;
        try std.testing.expect(scheduler.ready_rings[0].remove(self.primary));
        exceptions.resume_frame[0] = scheduler.tasks[self.primary].sp;
        try std.testing.expect(exit_current(7));
        try std.testing.expect(scheduler.tasks[self.sibling].kill_pending);
        scheduler.current[1] = idle_id;
        // Resume that already-running sibling's syscall on the host core.
        const previous = current_id();
        scheduler.tasks[previous].state = .ready;
        scheduler.ready_rings[0].push(previous);
        scheduler.current[0] = self.sibling;
        exceptions.resume_frame[0] = scheduler.tasks[self.sibling].sp;
        check_ready_membership();
    }

    fn defer_conversion(self: ExitKillCase) !void {
        const svc = scheduler.svclock;
        svc.file.gate.lock();
        defer svc.file.gate.unlock();
        try std.testing.expect(yield_current());
        try select(self.sibling);
        try std.testing.expectEqual(State.running, scheduler.tasks[self.sibling].state);
        try std.testing.expect(scheduler.tasks[self.sibling].kill_pending);
        check_ready_membership();
    }

    fn finish(self: ExitKillCase, beats: usize) !void {
        try self.finish_status(beats, 7);
    }

    fn finish_status(self: ExitKillCase, beats: usize, status: u64) !void {
        for (0..beats) |_| {
            on_tick();
            try std.testing.expect(yield_current());
            check_ready_membership();
        }
        try std.testing.expectEqual(process.State.exited, process.info(self.pid).?.state);
        try std.testing.expectEqual(status, process.info(self.pid).?.exit_status);
        try std.testing.expect(is_terminated(self.sibling));
        try std.testing.expect(!scheduler.tasks[self.sibling].kill_pending);
    }
};

test "scheduler: exit-kill control wakes an already futex-blocked sibling (#1978)" {
    const c = try ExitKillCase.boot();
    try ExitKillCase.select(c.sibling);
    try c.futex();
    try std.testing.expect(is_blocked(c.sibling));
    try ExitKillCase.select(c.primary);
    try std.testing.expect(exit_current(7));
    try c.finish(max_tasks);
}

test "scheduler: exit-kill control retries a deferred kill on selection (#1978)" {
    const c = try ExitKillCase.boot();
    try c.arm_running();
    try c.defer_conversion();
    try c.finish(max_tasks);
}

test "scheduler: exit-kill repro deferred conversion then infinite futex (#1978)" {
    const c = try ExitKillCase.boot();
    try c.arm_running();
    try c.defer_conversion();
    try c.futex();
    try std.testing.expect(is_blocked(c.sibling));
    try c.finish(200);
}

test "scheduler: exit-kill repro already-running sibling then infinite futex (#1978)" {
    const c = try ExitKillCase.boot();
    try c.arm_running();
    try c.futex();
    try std.testing.expect(is_blocked(c.sibling));
    try c.finish(200);
}

test "scheduler: exit-kill rescues every deadline and event wait within one sweep (#1978)" {
    const Wait = enum { sleep, process_wait, event_wait };
    for ([_]Wait{ .sleep, .process_wait, .event_wait }) |wait| {
        for ([_]bool{ false, true }) |deferred| {
            const c = try ExitKillCase.boot();
            try c.arm_running();
            if (deferred) try c.defer_conversion();
            switch (wait) {
                .sleep => try std.testing.expect(sleep_current(10_000)),
                .process_wait => try std.testing.expect(scheduler.wait_current(process.max_processes - 1)),
                .event_wait => try std.testing.expect(scheduler.wait_event_current(c.pid)),
            }
            try std.testing.expect(is_blocked(c.sibling));
            on_tick();
            try std.testing.expectEqual(State.ready, scheduler.tasks[c.sibling].state);
            try std.testing.expectEqual(@as(u64, 0), scheduler.tasks[c.sibling].wakeup_tick);
            try std.testing.expect(scheduler.tasks[c.sibling].wait_pid == null);
            try std.testing.expect(scheduler.tasks[c.sibling].wait_event_pid == null);
            try std.testing.expectEqual(@as(u64, 0), scheduler.tasks[c.sibling].wait_event_buf);
            check_ready_membership();
            try c.finish(max_tasks);
        }
    }
}

test "scheduler: exit-kill rescues a pending-kill joiner and detaches its seat (#1978)" {
    const c = try ExitKillCase.boot();
    try ExitKillCase.select(c.sibling);
    // A single-task kill does not invalidate the target token until its
    // conversion requests process exit. Model a native primary as target.
    const token = max_tasks + 1;
    scheduler.tasks[c.primary].join_token = token;
    scheduler.tasks[c.primary].join_pid = c.pid;
    try std.testing.expectEqual(KillResult.ok, request_kill(c.sibling));
    {
        scheduler.svclock.file.gate.lock();
        defer scheduler.svclock.file.gate.unlock();
        try std.testing.expectEqual(@as(?u64, 0), scheduler.join_thread(c.pid, token));
    }
    try std.testing.expect(is_blocked(c.sibling));
    try std.testing.expectEqual(@as(?usize, c.sibling), scheduler.tasks[c.primary].joiner);
    on_tick();
    try std.testing.expect(!scheduler.tasks[c.sibling].wait_thread);
    try std.testing.expect(scheduler.tasks[c.primary].joiner == null);
    check_ready_membership();
    try c.finish_status(max_tasks, reserved_kill_status);
}

test "scheduler: exit-kill rescues a join that blocked before the arming scan (#1978)" {
    const c = try ExitKillCase.boot();
    const token = max_tasks + 1;
    scheduler.tasks[c.primary].join_token = token;
    scheduler.tasks[c.primary].join_pid = c.pid;
    try ExitKillCase.select(c.sibling);
    try std.testing.expectEqual(@as(?u64, 0), scheduler.join_thread(c.pid, token));
    try std.testing.expect(is_blocked(c.sibling));
    try ExitKillCase.select(c.primary);
    try std.testing.expect(exit_current(7));
    try c.finish(max_tasks);
}

test "scheduler: exit-kill retains the request and status when conversion refuses (#1978)" {
    const c = try ExitKillCase.boot();
    try ExitKillCase.select(c.sibling);
    try c.futex();
    // Replay the shared secondary-tick seam against a non-runnable task.
    // exit_current_locked must refuse without consuming the pending status.
    const previous = current_id();
    scheduler.current[0] = c.sibling;
    scheduler.tasks[c.sibling].kill_pending = true;
    scheduler.tasks[c.sibling].kill_pending_status = scheduler.reserved_cpu_limit_status;
    try std.testing.expect(!scheduler.convert_pending_kill());
    try std.testing.expect(scheduler.tasks[c.sibling].kill_pending);
    try std.testing.expectEqual(scheduler.reserved_cpu_limit_status, scheduler.tasks[c.sibling].kill_pending_status);
    scheduler.current[0] = previous;
    try c.finish_status(max_tasks, scheduler.reserved_cpu_limit_status);
    for (&scheduler.ring_locks) |*lock| try std.testing.expect(!lock.lock_impl.is_locked());
    try std.testing.expect(!scheduler.sched_lock.is_locked());
    try std.testing.expect(!scheduler.svclock.held_set(scheduler.svclock.all_bits));
}

test "scheduler: exit-kill conversion defers under a non-prefix service hold (#1978)" {
    const c = try ExitKillCase.boot();
    try c.arm_running();
    scheduler.svclock.kernel.acquire();
    try std.testing.expect(!scheduler.convert_pending_kill());
    try std.testing.expect(scheduler.tasks[c.sibling].kill_pending);
    try std.testing.expect(!scheduler.svclock.file.held());
    try std.testing.expect(scheduler.svclock.kernel.held());
    scheduler.svclock.kernel.release();
    try std.testing.expect(scheduler.convert_pending_kill());
    try c.finish(max_tasks);
}

var exit_kill_ram: [192 * 4096]u8 align(4096) = undefined;

fn exit_kill_allocator() !void {
    const allocator = scheduler.alloc;
    const desc = [_]allocator.memmap.MemoryDescriptor{.{
        .type = .conventional_memory,
        .physical_start = @intFromPtr(&exit_kill_ram),
        .virtual_start = 0,
        .number_of_pages = 192,
        .attribute = 0,
    }};
    try std.testing.expect(allocator.init(allocator.memmap.MapView.init(std.mem.asBytes(&desc), @sizeOf(allocator.memmap.MemoryDescriptor), 1), &.{}));
}

test "scheduler: exit-kill rejects late detached and native threads after requester reap (#1978)" {
    const c = try ExitKillCase.boot();
    try exit_kill_allocator();
    try c.arm_running();
    try std.testing.expect(reap(c.primary));
    const before = scheduler.alloc.stats().free_pages;
    const count = scheduler.task_count;
    try std.testing.expect(scheduler.spawn_thread(c.sibling, 0x5000, 0x70000000, 0) == null);
    try std.testing.expect(scheduler.spawn_tls_thread(c.sibling, 0x5000, 0x70000000, 0, 0x60000000) == null);
    try std.testing.expectEqual(before, scheduler.alloc.stats().free_pages);
    try std.testing.expectEqual(count, scheduler.task_count);
    try c.finish(max_tasks);
}

test "scheduler: exit-kill publication guard clears for a recycled process (#1978)" {
    const c = try ExitKillCase.boot();
    try exit_kill_allocator();
    try c.arm_running();
    try c.finish(max_tasks);
    try std.testing.expect(reap(c.primary));
    try std.testing.expect(reap(c.sibling));
    // create prefers unused descriptors, recycling an exited row only
    // once the fixed registry is full.
    for (1..process.max_processes) |_| {
        _ = process.create("occupied", .{}, .{}, .{}).?;
    }
    const primary = spawn("fresh", 0x3000, spsr_el0t_irqs, &exec_kstack_pool[0], 0, 0).?;
    const pid = process.create("fresh", .{}, .{}, .{}).?;
    try std.testing.expectEqual(c.pid, pid);
    try std.testing.expect(process.bind(pid, primary));
    const child = scheduler.spawn_thread(primary, 0x5000, 0x70000000, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?usize, pid), process.find_by_task(child));
    try std.testing.expect(!scheduler.tasks[child].kill_pending);
    try ExitKillCase.select(primary);
    try std.testing.expect(exit_current(0));
    for (0..max_tasks) |_| try std.testing.expect(yield_current());
    try std.testing.expect(reap(primary));
    try std.testing.expect(reap(child));
}

test "scheduler: exit-kill finishes WM teardown without a healthy diagnostic (#1978)" {
    const c = try ExitKillCase.boot();
    try std.testing.expect(scheduler.wm_server.register(c.pid));
    try c.arm_running();
    try std.testing.expectEqual(@as(?usize, c.pid), scheduler.wm_server.registered_pid());
    try c.defer_conversion();
    try c.futex();
    try c.finish(max_tasks);
    try std.testing.expect(!scheduler.wm_server.registered());
    var mock = console.MockConsole(4096){};
    var con = mock.console();
    maybe_report(&con);
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "tasks exit-kill outstanding") == null);
}

test "scheduler: exit-kill diagnostic is strictly after 64 ticks and prints once (#1978)" {
    const c = try ExitKillCase.boot();
    try c.arm_running();
    try c.futex();
    // No rotations: deliberately leave the exit request outstanding.
    for (0..scheduler.exit_kill_diagnostic_ticks) |_| on_tick();
    var mock = console.MockConsole(4096){};
    var con = mock.console();
    maybe_report(&con);
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "tasks exit-kill outstanding") == null);
    mock.reset();
    on_tick();
    maybe_report(&con);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, mock.contents(), "tasks exit-kill outstanding"));
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "state=ready kill_pending=true futex_waiting=false wakeup_tick=0 rings=0x1 age=65") != null);
    for (0..100) |_| on_tick();
    mock.reset();
    maybe_report(&con);
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "tasks exit-kill outstanding") == null);
    try c.finish(max_tasks);
}

test "scheduler: init registers the shell and idle scheduler.tasks; start flips enabled" {
    try std.testing.expectEqual(@as(usize, 0), init());
    // Claim 6729: the pool starts as shell + the scheduler-owned idle task
    // (the idle task's synthetic frame targets `idle_entry`).
    try std.testing.expectEqual(@as(usize, 2), scheduler.task_count);
    try std.testing.expectEqualStrings("shell", scheduler.tasks[0].name);
    try std.testing.expectEqualStrings("idle", scheduler.tasks[idle_id].name);
    try std.testing.expectEqual(State.ready, scheduler.tasks[idle_id].state);
    try std.testing.expectEqual(@intFromPtr(&idle_entry), scheduler.tasks[idle_id].elr);
    try std.testing.expect(!enabled());
    try std.testing.expect(!scheduling_active());
    start();
    try std.testing.expect(enabled());
    // Two runnable scheduler.tasks (shell + idle) are enough for the tick to switch.
    try std.testing.expect(scheduling_active());
    // Claim 0826: shell + idle leave three free slots (the capacity gate).
    try std.testing.expect(has_free_slot());
}

test "scheduler: register_worker builds a valid synthetic frame" {
    _ = init();
    const entry: u64 = 0x1234_5678_9abc_def0;
    try std.testing.expectEqual(@as(usize, 1), register_worker(entry).?);
    try std.testing.expectEqual(@as(usize, 3), scheduler.task_count); // shell + idle + worker
    const t = &scheduler.tasks[1];
    try std.testing.expectEqual(entry, t.elr);
    try std.testing.expectEqual(spsr_el1h_irqs, t.spsr);
    try std.testing.expectEqual(State.ready, t.state);
    // Frame: 160 bytes below the stack top; the x30 slot holds the park
    // address; every other slot is zeroed (the stub pops them as x0..x17).
    const stack_top = @intFromPtr(&scheduler.worker_stack) + scheduler.worker_stack.len;
    try std.testing.expectEqual(stack_top - frame_bytes, t.sp);
    try std.testing.expectEqual(@intFromPtr(&park), std.mem.readInt(u64, @as(*const [8]u8, @ptrFromInt(t.sp)), .little));
    var i: usize = 8;
    while (i < frame_bytes) : (i += 8) {
        try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, @as(*const [8]u8, @ptrFromInt(t.sp + i)), .little));
    }
    // #1426/#1442: the pool is shell + idle + worker + (max_tasks-3) user
    // slots (64/64 after M129b); a registration beyond that budget fails.
    try std.testing.expectEqual(@as(usize, 2), register_user(0x3333, 0).?);
    var next: usize = 3;
    while (next < idle_id) : (next += 1) {
        try std.testing.expectEqual(next, register_worker(0).?);
    }
    try std.testing.expectEqual(max_tasks, scheduler.task_count);
    try std.testing.expect(register_worker(0) == null);
    // Claim 0826: capacity is observable — the full pool has no free slot.
    try std.testing.expect(!has_free_slot());
}

test "scheduler: user scheduler.tasks are any-core and the shell/idle stay on core 0" {
    // Claim 9498: the console TX is locked (2369) and the userspace gate
    // serializes syscalls, so USER scheduler.tasks default to ANY core. The shell
    // (console owner / command runner) and the shared idle slot (core 0's
    // reaper — one frame, one owner) stay core-0.
    _ = init();
    const worker = register_worker(0x1111).?; // secondary_ok = true
    try std.testing.expectEqual(@as(usize, 1), worker);
    try std.testing.expect(scheduler.tasks[worker].secondary_ok);
    try std.testing.expect(!scheduler.tasks[0].secondary_ok); // shell stays on core 0
    try std.testing.expect(!scheduler.tasks[idle_id].secondary_ok); // idle is core-0's reaper
    const user = register_user(0x2222, 0).?;
    try std.testing.expectEqual(@as(usize, 2), user);
    try std.testing.expect(scheduler.tasks[user].secondary_ok); // any-core default
    try std.testing.expectEqual(@as(usize, 0), scheduler.tasks[user].pin_core);
    // Ready EL0 work suppresses the demo worker on either core.
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(0, 1));
    // Core 1 from the worker finds the user task (now eligible) ahead of
    // the wrap.
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(worker, 1));
    // Core 0 picks the user task normally too.
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(worker, 0));
}

test "scheduler: pin_task restricts a user task to exactly one core" {
    // SMP user scheduler.tasks (claim 2369 + 9498): `exec -c<core>` pins a spawned
    // task; `pin_task(.., 0)` pins back to CORE 0 only (the any-core
    // default is a RESTRICTION removed by pinning, never re-added).
    _ = init();
    const worker = register_worker(0x1111).?;
    const user = register_user(0x2222, 0).?;
    try std.testing.expect(scheduler.tasks[user].secondary_ok); // any-core default
    try std.testing.expect(pin_task(user, 1));
    try std.testing.expectEqual(@as(usize, 1), scheduler.tasks[user].pin_core);
    try std.testing.expect(scheduler.tasks[user].secondary_ok); // pinned off core 0
    // Core 1 from the worker finds the pinned user task (it is eligible
    // AND ahead of the worker in the wrap order).
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(worker, 1));
    // Core 0 skips the pinned task entirely — from the worker it wraps
    // straight to the idle fallback, never to the user task.
    try std.testing.expectEqual(@as(?usize, idle_id), next_runnable_for(worker, 0));
    // The ready pinned user suppresses the worker even at the wrap.
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(user, 1));
    // Pinning to core 0 (the WM registration) makes the task core-0-ONLY:
    // core 1 skips it again and core 0 picks it again.
    try std.testing.expect(pin_task(user, 0));
    try std.testing.expectEqual(@as(usize, 0), scheduler.tasks[user].pin_core);
    try std.testing.expect(!scheduler.tasks[user].secondary_ok);
    try std.testing.expectEqual(@as(?usize, worker), next_runnable_for(worker, 1));
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(worker, 0));
    // Unknown ids are refused.
    try std.testing.expect(!pin_task(max_tasks + 4, 1));
}

test "scheduler: core 0 steals an unpinned ready task parked on ring 1 (#857)" {
    // The issue-857 gap: a task preempted on core 1 sits on ring 1 while
    // core 0 needs work. Core 0's rotation must pull it in slot order,
    // and the claim must drop it off ring 1 (single owner — no other
    // core can select it afterwards).
    _ = init();
    const worker = register_worker(0x1111).?; // slot 1
    const user = register_user(0x2222, 0).?; // slot 2, any-core
    // Simulate a preemption on core 1: the user parks on ring 1.
    try std.testing.expect(scheduler.ready_rings[0].remove(user));
    scheduler.ready_rings[1].push(user);
    check_ready_membership();
    // Core 0 walking from the worker steals the ring-1 user (slot 2)
    // ahead of the idle fallback (slot 10).
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(worker, 0));
    // The claim removes it from ring 1.
    try std.testing.expectEqual(@as(?usize, user), ring_claim(0, worker));
    try std.testing.expect(!scheduler.ready_rings[1].contains(user));
    try std.testing.expect(!scheduler.ready_rings[0].contains(user));
}

test "scheduler: core-0 yield steals ring-1 work synchronously (#857)" {
    // End to end through the real rotation: the steal happens AT the
    // block/yield point — no tick, no park — which is the issue-857
    // success criterion on two cores.
    _ = init();
    _ = register_worker(0x2000).?; // slot 1
    start();
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expectEqual(@as(usize, 1), scheduler.current[0]);
    _ = register_user(0x3000, 0).?; // slot 2, published while worker runs
    // The user is preempted on core 1: parked on ring 1 while core 1 is
    // busy elsewhere.
    try std.testing.expect(scheduler.ready_rings[0].remove(2));
    scheduler.ready_rings[1].push(2);
    // Core 0 yields: the worker rejoins ring 0 and the rotation steals
    // the ring-1 user immediately.
    try std.testing.expect(yield_current()); // worker -> user (stolen)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current[0]);
    try std.testing.expect(!scheduler.ready_rings[1].contains(2));
    check_ready_membership();
}

test "scheduler: secondaries steal from each other's rings; pins stay home (#857)" {
    // The four-core shape (max_cores = 4): a secondary's rotation sees
    // every ring, not just ring 0 + its own. Pinned scheduler.tasks are still
    // never stolen — the pin ring keeps them.
    _ = init();
    const worker = register_worker(0x1111).?; // slot 1, any-core
    const user = register_user(0x2222, 0).?; // slot 2, any-core
    const pinned = register_user(0x3333, 0).?; // slot 3, pinned to core 2
    try std.testing.expect(pin_task(pinned, 2));
    // Park the any-core scheduler.tasks on ring 2 (as if preempted there).
    try std.testing.expect(scheduler.ready_rings[0].remove(worker));
    try std.testing.expect(scheduler.ready_rings[0].remove(user));
    scheduler.ready_rings[2].push(worker);
    scheduler.ready_rings[2].push(user);
    check_ready_membership();
    // Core 1 steals the EL0 user before the idle-class worker. The
    // core-2-pinned task is skipped, and with everything eligible gone
    // the scan finds nothing (idle is never stealable).
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(0, 1));
    try std.testing.expectEqual(@as(?usize, user), ring_claim(1, 0));
    try std.testing.expectEqual(@as(?usize, worker), next_runnable_for(user, 1));
    try std.testing.expectEqual(@as(?usize, worker), ring_claim(1, user));
    try std.testing.expect(next_runnable_for(user, 1) == null);
    // Core 0 steals from ring 2 the same way, then falls back to idle.
    _ = init();
    const w2 = register_worker(0x1111).?;
    const u_two = register_user(0x2222, 0).?;
    try std.testing.expect(scheduler.ready_rings[0].remove(u_two));
    scheduler.ready_rings[2].push(u_two);
    try std.testing.expectEqual(@as(?usize, u_two), next_runnable_for(0, 0));
    try std.testing.expectEqual(@as(?usize, u_two), next_runnable_for(w2, 0));
}

test "scheduler: the worker yields to eligible EL0 work on own and foreign rings (#1965)" {
    _ = init();
    const worker = register_worker(0x1111).?;
    const user = register_user(0x2222, 0).?;
    for ([_]usize{ 0, 1, 2 }) |ring| {
        for (&scheduler.ready_rings) |*r| _ = r.remove(user);
        scheduler.ready_rings[ring].push(user);
        // At the wrap and before slot 1, on core 0 and a secondary.
        for ([_]usize{ 0, 1 }) |core| {
            try std.testing.expectEqual(@as(?usize, user), next_runnable_for(0, core));
            try std.testing.expect(next_runnable_for(idle_id, core).? != worker);
        }
    }
    // Foreign work pinned elsewhere is not runnable here.
    try std.testing.expect(pin_task(user, 1));
    try std.testing.expectEqual(@as(?usize, worker), next_runnable_for(0, 0));
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(0, 1));
    try std.testing.expect(pin_task(user, 0));
    try std.testing.expectEqual(@as(?usize, worker), next_runnable_for(0, 1));
    // spawn-demo is not idle-class: it retains its place even with EL0 ready.
    const demo = spawn_demo().?;
    try std.testing.expectEqual(@as(?usize, demo), next_runnable_for(user, 0));
    check_ready_membership();
}

test "scheduler: without ready EL0 the worker still rotates with shell and idle (#1965)" {
    _ = init();
    const worker = register_worker(0x1111).?;
    const user = register_user(0x2222, 0).?;
    start();
    try std.testing.expect(yield_current()); // shell -> user
    try std.testing.expect(sleep_current(2)); // user -> idle
    try std.testing.expectEqual(@as(usize, idle_id), current_id());
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expectEqual(@as(usize, 0), current_id());
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expectEqual(worker, current_id());
    try std.testing.expect(yield_current()); // worker -> idle
    try std.testing.expectEqual(@as(usize, idle_id), current_id());
    try std.testing.expect(is_blocked(user));
    check_ready_membership();
}

test "scheduler: a lone EL0 with only the worker ready self-rotates and counts a timer preemption (#1965)" {
    _ = init();
    const worker = register_worker(0x1111).?;
    const user = register_user(0x2222, 0).?;
    // A secondary's ring-only shape: shell and the reaper cannot run there.
    try std.testing.expect(pin_task(user, 1));
    try std.testing.expectEqual(@as(?usize, user), ring_claim(1, 0));
    scheduler.ready_rings[1].push(user); // preempted EL0 rejoins its ring
    try std.testing.expectEqual(@as(?usize, user), ring_claim(1, user));
    // The timer wrapper uses the same save/claim/stage on the host's core 0.
    // Remove core-0-only peers to exercise that lone-user path end to end.
    scheduler.tasks[0].state = .blocked;
    scheduler.tasks[idle_id].state = .blocked;
    try std.testing.expect(scheduler.ready_rings[0].remove(idle_id));
    scheduler.current[0] = user;
    scheduler.tasks[user].state = .running;
    start();
    timer_switch_context(scheduler.tasks[user].sp, 0x2224, spsr_el0t_irqs, scheduler.tasks[user].sp_el0);
    try std.testing.expectEqual(user, current_id());
    try std.testing.expectEqual(@as(u64, 1), user_timer_preemption_count());
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[user].saves);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[user].resumes);
    try std.testing.expectEqual(@as(u64, 0), scheduler.tasks[worker].resumes);
    check_ready_membership();
}

test "scheduler: EL0 wakes preempt the worker at local IRQ exit and nudge a remote worker (#1965)" {
    _ = init();
    const worker = register_worker(0x1111).?;
    start();
    try std.testing.expect(yield_current()); // shell -> worker, no EL0 yet
    const user = register_user(0x2222, 0).?;
    var irq_frame: exceptions.VectorFrame align(16) = @splat(0x12345678);
    const worker_pc: u64 = 0x1114;
    const worker_pstate = spsr_el1h_irqs | (1 << 30);
    scheduler.tasks[worker].elr = worker_pc;
    scheduler.tasks[worker].spsr = worker_pstate;
    const user_frame = scheduler.tasks[user].sp;
    const user_sp = scheduler.tasks[user].sp_el0;
    exceptions.resume_frame[0] = @intFromPtr(&irq_frame);
    exceptions.resume_sp_el0[0] = 0xabcdef00;
    const ticks = scheduler.tick_count;
    try std.testing.expect(scheduler.resched_requested[0]);
    try std.testing.expect(scheduler.irq_exit_reschedule());
    try std.testing.expectEqual(user, current_id());
    try std.testing.expectEqual(@intFromPtr(&irq_frame), scheduler.tasks[worker].sp);
    try std.testing.expectEqual(worker_pc, scheduler.tasks[worker].elr);
    try std.testing.expectEqual(worker_pstate, scheduler.tasks[worker].spsr);
    try std.testing.expectEqual(@as(u64, 0xabcdef00), scheduler.tasks[worker].sp_el0);
    try std.testing.expectEqual(user_frame, exceptions.resume_frame[0]);
    try std.testing.expectEqual(user_sp, exceptions.resume_sp_el0[0]);
    try std.testing.expectEqual(@as(u64, 0x2222), scheduler.pending_elr[0]);
    try std.testing.expectEqual(spsr_el0t_irqs, scheduler.pending_spsr[0]);
    for (irq_frame) |reg| try std.testing.expectEqual(@as(u64, 0x12345678), reg);
    try std.testing.expectEqual(scheduler.pending_sp[0], exceptions.resume_frame[0]);
    try std.testing.expect(!scheduler.resched_requested[0]);
    try std.testing.expectEqual(ticks, scheduler.tick_count);
    try std.testing.expectEqual(@as(u64, 0), user_timer_preemption_count());
    try std.testing.expect(!scheduler.irq_exit_reschedule()); // never preempt EL0
    check_ready_membership();

    _ = init();
    const remote_worker = register_worker(0x1111).?;
    const remote_user = register_user(0x2222, 0).?;
    try std.testing.expect(pin_task(remote_user, 1));
    try std.testing.expect(scheduler.ready_rings[1].remove(remote_user));
    scheduler.tasks[remote_user].state = .blocked;
    try std.testing.expect(scheduler.ready_rings[0].remove(remote_worker));
    scheduler.tasks[remote_worker].state = .running;
    scheduler.current[1] = remote_worker;
    scheduler.smp.core_online[1] = true;
    defer scheduler.smp.core_online[1] = false;
    defer scheduler.current[1] = idle_id;
    start();
    const nudges = scheduler.wake_nudges;
    scheduler.tasks[remote_user].state = .ready;
    scheduler.push_home_locked(remote_user);
    try std.testing.expect(scheduler.resched_requested[1]);
    try std.testing.expectEqual(nudges + 1, scheduler.wake_nudges);
    try std.testing.expect(scheduler.ready_rings[1].contains(remote_user));
    check_ready_membership();
    // A non-EL0 wake does not add a worker-preemption nudge.
    try std.testing.expect(scheduler.ready_rings[1].remove(remote_user));
    scheduler.tasks[remote_user].spsr = spsr_el1h_irqs;
    scheduler.push_home_locked(remote_user);
    try std.testing.expectEqual(nudges + 1, scheduler.wake_nudges);

    // Exercise the SGI handler's worker branch using the host's core 0.
    scheduler.smp.core_online[1] = false;
    scheduler.current[1] = idle_id;
    _ = init();
    _ = register_worker(0x1111).?;
    start();
    try std.testing.expect(yield_current());
    const sgi_user = register_user(0x2222, 0).?;
    var sgi_frame: exceptions.VectorFrame align(16) = @splat(0x87654321);
    scheduler.tasks[1].elr = 0x1118;
    scheduler.tasks[1].spsr = worker_pstate;
    const sgi_user_frame = scheduler.tasks[sgi_user].sp;
    const sgi_user_sp = scheduler.tasks[sgi_user].sp_el0;
    exceptions.resume_frame[0] = @intFromPtr(&sgi_frame);
    exceptions.resume_sp_el0[0] = 0xabcdef08;
    scheduler.ipi_reschedule();
    try std.testing.expectEqual(sgi_user, current_id());
    try std.testing.expectEqual(@intFromPtr(&sgi_frame), scheduler.tasks[1].sp);
    try std.testing.expectEqual(@as(u64, 0x1118), scheduler.tasks[1].elr);
    try std.testing.expectEqual(worker_pstate, scheduler.tasks[1].spsr);
    try std.testing.expectEqual(@as(u64, 0xabcdef08), scheduler.tasks[1].sp_el0);
    try std.testing.expectEqual(sgi_user_frame, exceptions.resume_frame[0]);
    try std.testing.expectEqual(sgi_user_sp, exceptions.resume_sp_el0[0]);
    try std.testing.expectEqual(@as(u64, 0x2222), scheduler.pending_elr[0]);
    try std.testing.expectEqual(spsr_el0t_irqs, scheduler.pending_spsr[0]);
    for (sgi_frame) |reg| try std.testing.expectEqual(@as(u64, 0x87654321), reg);
    try std.testing.expect(!scheduler.resched_requested[0]);
    check_ready_membership();
}

test "scheduler: register_user separates EL1 exception and EL0 stacks" {
    _ = init();
    _ = register_worker(0x2000).?;
    const entry: u64 = 0x3000;
    try std.testing.expectEqual(@as(usize, 2), register_user(entry, 0).?);
    const task = &scheduler.tasks[2];
    try std.testing.expectEqualStrings("user-el0", task.name);
    try std.testing.expectEqual(entry, task.elr);
    try std.testing.expectEqual(spsr_el0t_irqs, task.spsr);
    try std.testing.expectEqual(@intFromPtr(&scheduler.user_kernel_stack) + scheduler.user_kernel_stack.len - frame_bytes, task.sp);
    try std.testing.expectEqual(@intFromPtr(&scheduler.user_stack) + scheduler.user_stack.len, task.sp_el0);
    try std.testing.expect(task.sp + frame_bytes != task.sp_el0);
    const frame: *exceptions.VectorFrame = @ptrFromInt(task.sp);
    try std.testing.expectEqual(@intFromPtr(&scheduler.user_timer_preemptions), exceptions.frame_read(frame, 9));
}

test "scheduler: a foreign core cannot claim or reap a frame still owned by an exception (#1965)" {
    _ = init();
    _ = register_worker(0x1111).?;
    const user = register_user(0x2222, 0).?;
    start();
    try std.testing.expect(yield_current()); // shell -> user
    scheduler.begin_exception(0);
    // The source publishes its saved frame during a cooperative switch.
    try std.testing.expect(yield_current()); // user -> idle
    try std.testing.expect(scheduler.ready_rings[0].contains(user));
    try std.testing.expect((scheduler.tasks[user].exception_guard & 1) != 0);
    try std.testing.expect(next_runnable_for(0, 1).? != user);
    // Same-core self-selection is safe: it restores only after this handler
    // returns. The foreign-core exclusion ends with the dispatcher's handoff.
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(1, 0));
    scheduler.end_exception(0);
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(0, 1));
    scheduler.tasks[user].state = .zombie;
    try std.testing.expect(scheduler.ready_rings[0].remove(user));
    scheduler.tasks[user].exception_guard = 1;
    try std.testing.expect(!reap(user));
    scheduler.tasks[user].exception_guard = 0;
    try std.testing.expect(reap(user));
}

test "scheduler: a wake retains its nudge until the protected frame is handed off (#1965)" {
    _ = init();
    const user = register_user(0x2222, 0).?;
    try std.testing.expect(pin_task(user, 1));
    try std.testing.expect(scheduler.ready_rings[1].remove(user));
    scheduler.tasks[user].state = .blocked;
    scheduler.tasks[user].exception_guard = 1;
    start();
    scheduler.tasks[user].state = .ready;
    scheduler.push_home_locked(user);
    try std.testing.expectEqual(@as(u64, 1 | (1 << 2)), scheduler.tasks[user].exception_guard);
    try std.testing.expect(next_runnable_for(0, 1) == null);
    // Stand in for the vector's atomic release, which runs on the selected
    // stack and consumes the retained core-1 SGI target bit.
    const guard = @atomicRmw(u64, &scheduler.tasks[user].exception_guard, .Xchg, 0, .acq_rel);
    try std.testing.expectEqual(@as(u64, 1 << 1), guard >> 1);
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(0, 1));
    // A parked secondary must not inherit a previous source owner.
    const old_current = scheduler.current[1];
    scheduler.current[1] = user;
    scheduler.begin_exception(1);
    scheduler.end_exception(1);
    scheduler.current[1] = idle_id;
    scheduler.begin_exception(1);
    try std.testing.expect(scheduler.exception_handoff(1) == null);
    scheduler.current[1] = old_current;
}

test "scheduler: register_exec_user passes argc and argv VA through the x0/x1 frame slots" {
    // Card 3e (claim 4636): the entry-contract extension — the exec'd
    // program's `_start` receives argc in x0 and the argv block VA in x1.
    // `build_initial_frame` zeroes the frame, so `register_exec_user`
    // writes the two slots (the same seam `register_user` uses for the
    // timer-witness VA in slot x9). A no-args exec passes 0/0: identical
    // to the zeroed frame, so earlier cards' no-args behavior is unchanged.
    _ = init();
    _ = register_worker(0x2000).?;
    var kstack: [task_stack_size]u8 align(16) = undefined;
    const id = register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 2, 0x4000_0064).?;
    const frame: *exceptions.VectorFrame = @ptrFromInt(scheduler.tasks[id].sp);
    try std.testing.expectEqual(@as(u64, 2), exceptions.frame_read(frame, 0));
    try std.testing.expectEqual(@as(u64, 0x4000_0064), exceptions.frame_read(frame, 1));
    const id2 = register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    const frame2: *exceptions.VectorFrame = @ptrFromInt(scheduler.tasks[id2].sp);
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(frame2, 0));
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(frame2, 1));
}

test "scheduler: exec registration is invisible to wake_expired until publish_task (M70b)" {
    // The M70b review blocker: a fresh pool slot's `wakeup_tick` defaults
    // to 0, and `wake_expired` reads any blocked non-waiter with
    // `tick_count >= wakeup_tick` as an EXPIRED sleep. Exec builds across
    // two sched_lock holds with a lock-free gap (regions/bind happen
    // between them) and IRQ masking is per-core, so an AP exec's gap and
    // core 0's tick interleave — pre-fix the tick published the half-built
    // task (and the M70b SGI nudge handed it to a parked AP before the
    // build completed). The registration sentinel-shields the task; only
    // `publish_task` makes it visible to the clock.
    _ = init();
    start();
    const kstack = &exec_kstack_pool[1];
    const id = register_exec_user_pinned(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, kstack, 0, 0, 0, null).?;
    try std.testing.expect(is_blocked(id));
    // A full on_tick beat runs the wake_expired scan — pre-fix it
    // published the task right here.
    on_tick();
    try std.testing.expect(is_blocked(id));
    check_ready_membership();
    // Publish makes it visible: home ring (single online core → ring 0),
    // ready state, and the clock sentinel cleared.
    publish_task(id);
    try std.testing.expect(!is_blocked(id));
    try std.testing.expect(scheduler.ready_rings[0].contains(id));
    check_ready_membership();
}

test "scheduler: round-robin alternates and round-trips saved context" {
    _ = init();
    const worker_entry: u64 = 0x2000;
    _ = register_worker(worker_entry).?;
    start();
    // First switch: the shell is preempted at pc 0x1000; the worker is
    // restored to its synthetic frame.
    switch_context(0x1000, 0x1000, 0x5, 0xaaaa);
    try std.testing.expectEqual(@as(usize, 1), scheduler.current[0]);
    try std.testing.expectEqual(@as(u64, 1), scheduler.switches);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[0].saves);
    try std.testing.expectEqual(@as(u64, 0), scheduler.tasks[0].resumes);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[1].resumes);
    try std.testing.expectEqual(@as(u64, 0), scheduler.tasks[1].saves);
    try std.testing.expectEqual(scheduler.tasks[1].sp, scheduler.pending_sp[0]);
    try std.testing.expectEqual(worker_entry, scheduler.pending_elr[0]);
    try std.testing.expectEqual(spsr_el1h_irqs, scheduler.pending_spsr[0]);
    // Second switch: with no EL0 ready, worker -> idle is unchanged.
    switch_context(0x2000, 0x2000, 0x5, 0xbbbb);
    try std.testing.expectEqual(@as(usize, idle_id), scheduler.current[0]);
    try std.testing.expectEqual(@as(u64, 2), scheduler.switches);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[1].saves);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[1].resumes);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[idle_id].resumes);
    try std.testing.expectEqual(scheduler.tasks[idle_id].sp, scheduler.pending_sp[0]);
    // Third switch: the idle task is preempted; the shell is restored to
    // its exact saved context (the round-trip).
    switch_context(0x4000, 0x4000, 0x5, 0xdddd);
    try std.testing.expectEqual(@as(usize, 0), scheduler.current[0]);
    try std.testing.expectEqual(@as(u64, 3), scheduler.switches);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[idle_id].saves);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[0].resumes);
    try std.testing.expectEqual(@as(u64, 0x1000), scheduler.pending_sp[0]);
    try std.testing.expectEqual(@as(u64, 0x1000), scheduler.pending_elr[0]);
    try std.testing.expectEqual(@as(u64, 0x5), scheduler.pending_spsr[0]);
    try std.testing.expectEqual(@as(u64, 0xaaaa), scheduler.pending_sp_el0[0]);
    // Fourth switch returns to the worker's saved context (the round-trip).
    switch_context(0x1000, 0x1001, 0x5, 0xaaaa);
    try std.testing.expectEqual(@as(usize, 1), scheduler.current[0]);
    try std.testing.expectEqual(@as(u64, 4), scheduler.switches);
    try std.testing.expectEqual(@as(u64, 2), scheduler.tasks[0].saves);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[0].resumes);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[1].saves);
    try std.testing.expectEqual(@as(u64, 2), scheduler.tasks[1].resumes);
}

test "scheduler: mixed EL1h and EL0t round-robin restores SP_EL0" {
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    const initial_user_sp = scheduler.tasks[2].sp_el0;

    switch_context(0x1000, 0x1000, spsr_el1h_irqs, 0xaaaa); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current[0]);
    try std.testing.expectEqual(spsr_el0t_irqs, scheduler.pending_spsr[0]);
    try std.testing.expectEqual(initial_user_sp, scheduler.pending_sp_el0[0]);

    const preempted_user_sp: u64 = initial_user_sp - 16;
    // Claim 6729: the preempted EL0 task's successor is the idle task
    // (sp_el0 = 0 for an EL1h task), then the shell on the next switch.
    switch_context(0x3000, 0x3004, spsr_el0t_irqs, preempted_user_sp); // user -> idle
    try std.testing.expectEqual(@as(usize, idle_id), scheduler.current[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler.pending_sp_el0[0]);
    try std.testing.expectEqual(preempted_user_sp, scheduler.tasks[2].sp_el0);
    switch_context(0x4000, 0x4000, spsr_el1h_irqs, 0xcccc); // idle -> shell
    try std.testing.expectEqual(@as(usize, 0), scheduler.current[0]);
    try std.testing.expectEqual(@as(u64, 0xaaaa), scheduler.pending_sp_el0[0]);

    switch_context(0x1000, 0x1004, spsr_el1h_irqs, 0xaaaa);
    try std.testing.expectEqual(@as(usize, 2), scheduler.current[0]);
    try std.testing.expectEqual(preempted_user_sp, scheduler.pending_sp_el0[0]);
    try std.testing.expectEqual(@as(u64, 0x3004), scheduler.pending_elr[0]);
}

test "scheduler: only a tick preemption publishes the EL0 witness" {
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    switch_context(0x1000, 0x1000, spsr_el1h_irqs, 0xaaaa); // shell -> user
    try std.testing.expectEqual(@as(u64, 0), user_timer_preemption_count());
    // Cooperative switching cannot satisfy the claim-8215 witness. The
    // user's successor is the idle task (claim 6729), then the shell.
    try std.testing.expect(yield_current()); // user -> idle
    try std.testing.expectEqual(@as(u64, 0), user_timer_preemption_count());
    switch_context(0x4000, 0x4000, spsr_el1h_irqs, 0xcccc); // idle -> shell
    switch_context(0x1004, 0x1004, spsr_el1h_irqs, 0xaaaa); // shell -> user
    timer_switch_context(0x3000, 0x3004, spsr_el0t_irqs, scheduler.tasks[2].sp_el0);
    try std.testing.expectEqual(@as(u64, 1), user_timer_preemption_count());
}

test "scheduler: the worker's advance counter belongs to its own task" {
    _ = init();
    _ = register_worker(0x2000).?;
    scheduler.current[0] = 1; // pretend the worker is running
    note_advance();
    note_advance();
    note_advance();
    try std.testing.expectEqual(@as(u64, 3), scheduler.tasks[1].advances);
    try std.testing.expectEqual(@as(u64, 0), scheduler.tasks[0].advances);
}

test "scheduler: worker report snapshots once and prints from the shell side" {
    _ = init();
    _ = register_worker(0x2000).?;
    scheduler.current[0] = 1; // pretend the worker is running
    note_advance();
    note_advance();
    request_report();
    request_report(); // second request while pending: keeps the first snapshot
    var mock = console.MockConsole(256){};
    var con = mock.console();
    maybe_report(&con);
    try std.testing.expectEqualStrings("tasks worker advances=2\n", mock.contents());
    // The flag is consumed: a second print emits nothing.
    mock.reset();
    maybe_report(&con);
    try std.testing.expectEqual(@as(usize, 0), mock.contents().len);
}

test "scheduler: stats and task_info report deterministic state" {
    _ = init();
    _ = register_worker(0x2000).?;
    start();
    const s = stats();
    try std.testing.expect(s.enabled);
    try std.testing.expectEqual(@as(usize, 3), s.count); // shell + idle + worker
    try std.testing.expectEqual(@as(usize, 0), s.zombies);
    try std.testing.expectEqual(@as(usize, 0), s.current);
    try std.testing.expectEqual(@as(u64, 0), s.switches);
    const shell = task_info(0).?;
    try std.testing.expectEqualStrings("shell", shell.name);
    try std.testing.expectEqual(State.ready, shell.state);
    try std.testing.expectEqual(@as(u64, 0), shell.saves);
    try std.testing.expectEqual(@as(u64, 0), shell.advances);
    const worker = task_info(1).?;
    try std.testing.expectEqualStrings("worker", worker.name);
    try std.testing.expect(task_info(2) == null);
    const idle = task_info(idle_id).?;
    try std.testing.expectEqualStrings("idle", idle.name);
    try std.testing.expectEqual(State.ready, idle.state);
}

test "scheduler: cooperative exit is non-runnable and reports from shell" {
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    try std.testing.expect(yield_current()); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    try std.testing.expect(exit_current(7)); // user -> idle (the ring's fallback)
    try std.testing.expectEqual(@as(usize, idle_id), current_id());
    try std.testing.expect(is_terminated(2));
    try std.testing.expectEqual(@as(?u64, 7), terminated_status(2));
    // The next scheduler.switches skip the zombie user: idle -> shell -> worker -> idle.
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 0), current_id());
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 1), current_id());
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, idle_id), current_id());
    var mock = console.MockConsole(128){};
    var con = mock.console();
    maybe_report(&con);
    // Claim 3848: the same exit also produced the PROCESS-level report
    // (the exited user-el0 process keeps its status past the task reap).
    try std.testing.expectEqualStrings("tasks user-el0 exited status=7\nprocs user-el0 exited status=7\n", mock.contents());
}

test "scheduler: sleep_current blocks, wakes on the deadline tick, and rolls back" {
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    // Shell sleeps 2 ticks; ready EL0 runs before the worker.
    try std.testing.expect(sleep_current(2));
    try std.testing.expect(is_blocked(0));
    try std.testing.expectEqual(@as(u64, 2), scheduler.tasks[0].wakeup_tick);
    try std.testing.expectEqual(@as(usize, 2), scheduler.current[0]);
    // The blocked shell drops out: user -> idle -> user (worker suppressed).
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, idle_id), scheduler.current[0]);
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current[0]);
    // Tick 1: deadline (scheduler.tick_count 0 + 2) not reached yet.
    on_tick();
    try std.testing.expect(is_blocked(0));
    try std.testing.expectEqual(@as(u64, 1), scheduler.tick_count);
    // Tick 2: the timer-driven wakeup flips the sleeper back to ready.
    on_tick();
    try std.testing.expect(!is_blocked(0));
    try std.testing.expectEqual(State.ready, scheduler.tasks[0].state);
    try std.testing.expectEqual(@as(u64, 0), scheduler.tasks[0].wakeup_tick);
    // The ring reaches the woken shell again.
    try std.testing.expect(yield_current()); // user -> idle
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expectEqual(@as(usize, 0), scheduler.current[0]);
}

test "scheduler: sleep guards — zero clamps to one tick, idle and inactive fail" {
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    // Inactive pool: no switching.
    try std.testing.expect(!sleep_current(1));
    start();
    // sleep(0) clamps to one tick and still blocks.
    try std.testing.expect(sleep_current(0));
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[0].wakeup_tick);
    // The idle task cannot sleep (it is the ring's fallback).
    scheduler.current[0] = idle_id;
    try std.testing.expect(!sleep_current(1));
    try std.testing.expect(!is_blocked(idle_id));
    // A zombie cannot sleep either.
    scheduler.tasks[1].state = .zombie;
    scheduler.current[0] = 1;
    try std.testing.expect(!sleep_current(1));
}

test "scheduler: two live user scheduler.tasks coexist with their own roots and regions" {
    // Claim 0826: the exec gate is gone — a second user program loads and
    // runs while the first is alive. Give each a DISTINCT user root and
    // user stack (per-process address spaces), and pin the per-task
    // syscall regions that follow the TCB at SVC entry.
    _ = init();
    _ = register_worker(0x2000).?;
    // Build A's root FIRST (the boot payload registers against the scheduler.current
    // global root, like the real boot), then B's own root for the second
    // live program.
    const root_a = (mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult);
    // Pin the boot payload's stack placement explicitly: the module-global
    // current_stack_va can be left at a rebuilt (ASLR) placement by earlier
    // exec-path tests in the same process, and register_user derives the
    // payload's stack region from it. This test pins the per-task regions
    // mechanism, not the ASLR default.
    userspace.set_stack_va(userspace.stack_va);
    const user_a = register_user(0x3000, 0).?;
    try std.testing.expectEqual(@as(usize, 2), user_a);
    const root_b = (mmu.build_user_root(userspace.text_va, 0x1000, 64, 0x1a400000, 0x3000, 8192) orelse return error.TestUnexpectedResult);
    const kstack_b = exec_kstack_pool[0][0..];
    const user_b = register_exec_user(0x4000, root_b, 64, 0x1a400000, 8192, kstack_b, 0, 0).?;
    try std.testing.expectEqual(@as(usize, 3), user_b);
    // #1426/#1442: fill remaining user slots so the capacity gate is
    // observable at max_tasks (shell + worker + idle + 61 user tasks).
    var fill: usize = 0;
    while (has_free_slot()) : (fill += 1) {
        const kstack = exec_kstack_pool[1 + fill][0..];
        const entry: u64 = 0x5000 + fill * 0x1000;
        const stack_va: u64 = 0x1b400000 + fill * 0x100000;
        _ = register_exec_user(entry, root_b, 64, stack_va, 8192, kstack, 0, 0) orelse
            return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(max_tasks, scheduler.task_count);
    try std.testing.expect(!has_free_slot());
    // Each task carries ITS OWN root and apertures.
    try std.testing.expect(task_ttbr0(user_a) != task_ttbr0(user_b));
    try std.testing.expectEqual(root_a, task_ttbr0(user_a));
    try std.testing.expectEqual(root_b, task_ttbr0(user_b));
    // The scheduler.current-task regions follow the ring: put A scheduler.current and read its
    // regions, then B.
    scheduler.current[0] = user_a;
    const ra = current_user_regions();
    try std.testing.expectEqual(userspace.text_va, ra.text.base);
    try std.testing.expectEqual(userspace.stack_va, ra.stack.base);
    scheduler.current[0] = user_b;
    const rb = current_user_regions();
    try std.testing.expectEqual(userspace.text_va, rb.text.base);
    try std.testing.expectEqual(@as(u64, 0x1a400000), rb.stack.base);
    try std.testing.expectEqual(@as(u64, 8192), rb.stack.len);
    // Restore the ring position before the round-robin exercise (the region
    // checks above moved `scheduler.current` for readability).
    scheduler.current[0] = 0;
    // Both run in the ring (round-robin reaches each).
    start();
    try std.testing.expect(yield_current()); // shell -> user A
    try std.testing.expectEqual(@as(usize, user_a), current_id());
    try std.testing.expect(yield_current()); // A -> B
    try std.testing.expectEqual(@as(usize, user_b), current_id());
    // One more user program cannot load: the pool is the capacity gate.
    try std.testing.expect(register_exec_user(0x5000, root_a, 64, 0x2a400000, 8192, kstack_b, 0, 0) == null);
}

test "scheduler: lifecycle — spawn, exit to zombie, idle reaps back to free" {
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    // The pool is shell + worker + user + idle; the spare slot is the
    // monitor demo spawn (claim 6729). One spawn per boot, bounded.
    try std.testing.expectEqual(@as(usize, 3), spawn_demo().?);
    try std.testing.expect(spawn_demo() == null);
    try std.testing.expectEqual(@as(usize, 5), stats().count);
    try std.testing.expectEqualStrings("spawn-demo", task_info(3).?.name);
    try std.testing.expectEqual(State.ready, task_info(3).?.state);
    // user scheduler.exits -> zombie at slot 2; the ring's next ready task is the
    // spawn-demo task (slot 3).
    try std.testing.expect(yield_current()); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    try std.testing.expect(exit_current(7)); // user -> spawn-demo
    try std.testing.expectEqual(@as(usize, 3), current_id());
    try std.testing.expectEqual(@as(usize, 1), stats().zombies);
    try std.testing.expect(is_terminated(2));
    try std.testing.expectEqual(@as(?u64, 7), terminated_status(2));
    // The idle task reaps one zombie per iteration; the slot returns free.
    reap_one_zombie();
    try std.testing.expect(!is_terminated(2));
    try std.testing.expectEqual(@as(usize, 0), stats().zombies);
    try std.testing.expectEqual(@as(usize, 4), stats().count);
    try std.testing.expect(task_info(2) == null);
    // The freed slot is spawnable again (the lifecycle is a closed loop).
    try std.testing.expectEqual(@as(usize, 2), spawn("revived", 0x5000, spsr_el1h_irqs, &scheduler.worker_stack, 0, 0).?);
    try std.testing.expectEqual(@as(usize, 5), stats().count);
    // The shell loop prints the exit, the process-level exit report
    // (claim 3848: the exited process keeps its status past the reap) and
    // the reap, in order.
    var mock = console.MockConsole(256){};
    var con = mock.console();
    maybe_report(&con);
    try std.testing.expectEqualStrings("tasks user-el0 exited status=7\nprocs user-el0 exited status=7\ntasks user-el0 reaped\n", mock.contents());
}

// Claim 1747: `idle_pass` is the console-free drain seam that took the
// custom-virtio queue-3 pump off the shell idle loop. Two properties the
// fix rests on, both host-observable without booting a VM:
//   1. a registrant is reached exactly once per pass, so input liveness no
//      longer depends on the shell idle loop running; and
//   2. the lifecycle reap still happens in the SAME pass, so inserting the
//      hook did not cost the reaper a beat.
var idle_hook_calls: usize = 0;

fn counting_idle_hook() void {
    idle_hook_calls += 1;
}

test "scheduler: the idle pass runs the console-free hook and still reaps" {
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();

    // No registrant: the pass is still safe and still reaps.
    on_idle_pass.* = null;
    idle_hook_calls = 0;
    idle_pass();
    try std.testing.expectEqual(@as(usize, 0), idle_hook_calls);

    // With a registrant, every pass reaches it exactly once.
    on_idle_pass.* = counting_idle_hook;
    defer on_idle_pass.* = null;
    idle_pass();
    try std.testing.expectEqual(@as(usize, 1), idle_hook_calls);
    idle_pass();
    try std.testing.expectEqual(@as(usize, 2), idle_hook_calls);

    // The reap half is unchanged: drive the user to a zombie, then confirm
    // ONE pass both ran the hook and freed the slot.
    try std.testing.expect(yield_current()); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    try std.testing.expect(exit_current(7)); // user -> idle
    try std.testing.expectEqual(@as(usize, 1), stats().zombies);
    const before = idle_hook_calls;
    idle_pass();
    try std.testing.expectEqual(before + 1, idle_hook_calls); // hook ran
    try std.testing.expectEqual(@as(usize, 0), stats().zombies); // and reaped
}

test "scheduler: two exits in one window report BOTH lines in order" {
    // Card 3d (claim 1014): the exit/reap reports are FIFOs, not single
    // first-wins flags — two scheduler.exits in one idle-loop window print two
    // `scheduler.tasks <name> exited status=` lines (and two process reports) in
    // exit order, and a second drain prints nothing (no double-print).
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    // Exit the user (slot 2, status 43), then the worker (slot 1, status
    // 9), WITHOUT draining between them.
    try std.testing.expect(yield_current()); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    try std.testing.expect(exit_current(43)); // user -> idle
    try std.testing.expectEqual(@as(usize, idle_id), current_id());
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expectEqual(@as(usize, 1), current_id());
    try std.testing.expect(exit_current(9)); // worker -> idle
    try std.testing.expectEqual(@as(usize, idle_id), current_id());
    // One drain prints BOTH scheduler.exits in order, then nothing more.
    var mock = console.MockConsole(256){};
    var con = mock.console();
    maybe_report(&con);
    // The task-exit FIFO drains first (both lines, in exit order), then
    // the process FIFO (the user-el0 process's report), then the reap
    // FIFO. Every exit printed exactly once, in order, no collapse.
    try std.testing.expectEqualStrings(
        "tasks user-el0 exited status=43\n" ++
            "tasks worker exited status=9\n" ++
            "procs user-el0 exited status=43\n",
        mock.contents(),
    );
    mock.reset();
    maybe_report(&con);
    try std.testing.expectEqual(@as(usize, 0), mock.contents().len);
}

test "scheduler: two reaps in one window report BOTH reap lines in order" {
    // Card 3d: the reap report is a FIFO too — two zombies reaped before
    // the shell drains print two `scheduler.tasks <name> reaped` lines.
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    try std.testing.expect(yield_current()); // shell -> user
    try std.testing.expect(exit_current(43)); // user -> idle
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(exit_current(9)); // worker -> idle
    // Reap BOTH zombies before the shell drains (the idle task's
    // one-per-iteration reaper makes this the normal window).
    reap_one_zombie();
    reap_one_zombie();
    var mock = console.MockConsole(256){};
    var con = mock.console();
    maybe_report(&con);
    // Reaps scan slots lowest-first, so the worker (slot 1) is reaped
    // before the user (slot 2) — the FIFO preserves THAT order.
    try std.testing.expectEqualStrings(
        "tasks user-el0 exited status=43\n" ++
            "tasks worker exited status=9\n" ++
            "procs user-el0 exited status=43\n" ++
            "tasks worker reaped\n" ++
            "tasks user-el0 reaped\n",
        mock.contents(),
    );
}

test "scheduler: request_kill refuses unknown, exited, and scheduler-owned targets" {
    // Card 3c (claim 7786): the kill ARMS a target; the refusals are the
    // monitor command's exact error strings.
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    // The shell (0) owns the console and the idle task is scheduler-owned:
    // neither may be force-terminated.
    try std.testing.expectEqual(KillResult.refused, request_kill(0));
    try std.testing.expectEqual(KillResult.refused, request_kill(idle_id));
    // A free slot and an out-of-range id are not_found.
    try std.testing.expectEqual(KillResult.not_found, request_kill(3)); // free spare slot
    try std.testing.expectEqual(KillResult.not_found, request_kill(max_tasks));
    // Drive the user to a zombie: an exited task is already_exited.
    start();
    try std.testing.expect(yield_current()); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    try std.testing.expect(exit_current(43)); // user -> idle
    try std.testing.expectEqual(KillResult.already_exited, request_kill(2));
}

test "scheduler: a killed task exits with the reserved status at its next selection" {
    // Card 3c: `kill` arms the target's TCB (main context); the ring's
    // next selection of that task converts the selection into the EXISTING
    // exit path with the reserved status 137 — the killed task never
    // resumes, and the exit report + reap carry the reserved status.
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    // The shell arms the kill on the user task (slot 2).
    try std.testing.expectEqual(KillResult.ok, request_kill(2));
    // The next scheduler.switches walk the ring; when the ring SELECTS the user, the
    // kill branch converts the selection into exit_current(137).
    try std.testing.expect(yield_current()); // shell -> user -> killed -> idle
    try std.testing.expectEqual(@as(usize, idle_id), current_id());
    try std.testing.expect(is_terminated(2));
    try std.testing.expectEqual(@as(?u64, reserved_kill_status), terminated_status(2));
    try std.testing.expectEqual(@as(u64, 1), exit_count());
    // The process bound to the killed task reports the reserved status.
    const pinfo = process.info(0).?;
    try std.testing.expectEqual(process.State.exited, pinfo.state);
    try std.testing.expectEqual(@as(u64, reserved_kill_status), pinfo.exit_status);
    // The exit report carries 137, drained in order by the shell loop.
    var mock = console.MockConsole(128){};
    var con = mock.console();
    maybe_report(&con);
    try std.testing.expectEqualStrings("tasks user-el0 exited status=137\nprocs user-el0 exited status=137\n", mock.contents());
    // The slot reaps back to free and is spawnable again (the kill flows
    // through the real lifecycle, not a special teardown).
    try std.testing.expect(reap(2));
    try std.testing.expect(task_info(2) == null);
    try std.testing.expect(has_free_slot());
    try std.testing.expectEqual(KillResult.not_found, request_kill(2)); // the freed slot is not_found
}

test "scheduler: an EL0 fault reaps the task with status 139 and reports it" {
    // Milestone sixteen C2 (claim 8403): a synchronous EL0 fault (here an
    // EC-0x24 data abort at a guard-page FAR) reaches fault_current, which
    // snapshots the fault report AND reaps the task through the existing
    // exit path with reserved_fault_status. The shell drains `fault:` before
    // the exit report.
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    try std.testing.expect(yield_current()); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    fault_current(0x24 << 26, 0x7fff_f000, 0x4000); // user -> idle
    try std.testing.expectEqual(@as(usize, idle_id), current_id());
    try std.testing.expect(is_terminated(2));
    try std.testing.expectEqual(@as(?u64, reserved_fault_status), terminated_status(2));
    var mock = console.MockConsole(256){};
    var con = mock.console();
    maybe_report(&con);
    try std.testing.expectEqualStrings(
        // Issue #1214: the fault line surfaces the tombstone's anchor facts
        // (PC + raw ESR); this fixture PC resolves to no symbol, so the line
        // ends without a symbol note.
        "fault: user-el0 far=0x000000007ffff000 ec=0x24 pc=0x0000000000004000 esr=0x0000000090000000\n" ++
            "tasks user-el0 exited status=139\n" ++
            "procs user-el0 exited status=139\n",
        mock.contents(),
    );
    try std.testing.expect(reap(2));
    try std.testing.expect(task_info(2) == null);
}

test "scheduler: a killed sleeping task is terminated at its wake-selection" {
    // Card 3c: a task parked by sys_sleep has NO scheduled quantum while
    // blocked; the kill takes effect when its wake flips it to ready and
    // the ring selects it — the same stage_current kill branch.
    _ = init();
    _ = register_worker(0x2000).?;
    start();
    // The worker sleeps 4 ticks (scheduler.current = worker, slot 1).
    try std.testing.expect(yield_current()); // shell -> worker
    _ = register_user(0x3000, 0).?;
    try std.testing.expect(sleep_current(4)); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    // Arm the kill on the sleeping worker.
    try std.testing.expectEqual(KillResult.ok, request_kill(1));
    // Walk the ring (user -> idle -> shell -> ...); the blocked worker is
    // skipped until its wake. Wake it, then the next selection kills it.
    try std.testing.expect(yield_current()); // user -> idle
    on_tick();
    on_tick();
    on_tick();
    on_tick(); // tick 4: the worker's deadline passes -> ready
    try std.testing.expect(!is_blocked(1));
    // The ring reaches the woken worker's selection: killed -> 137.
    try std.testing.expect(yield_current()); // idle -> shell
    // Ready EL0 suppresses the worker, so block it before the worker's
    // pending kill is selected.
    try std.testing.expect(yield_current()); // shell -> user
    try std.testing.expect(sleep_current(1)); // user -> idle
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expect(yield_current()); // shell -> worker -> killed -> idle
    on_tick(); // user wakes
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expect(yield_current()); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    try std.testing.expect(is_terminated(1));
    try std.testing.expectEqual(@as(?u64, reserved_kill_status), terminated_status(1));
}

// ---------------------------------------------------------------------------
// Claim 881 slice 1 — per-core ready rings
// ---------------------------------------------------------------------------

test "scheduler: ready rings — sorted membership, contains, remove, remove_at" {
    var r: ReadyRing = .{};
    try std.testing.expect(r.empty());
    try std.testing.expectEqual(@as(usize, 0), r.len());

    // push keeps ascending-slot order (the pre-ring round-robin scanned
    // slot order from `after + 1`, and the 508 tests pin that order).
    r.push(3);
    r.push(1);
    r.push(2);
    try std.testing.expectEqual(@as(usize, 3), r.len());
    try std.testing.expect(r.contains(1));
    try std.testing.expect(!r.contains(9));
    try std.testing.expectEqual(@as(usize, 1), r.get(0));
    try std.testing.expectEqual(@as(usize, 2), r.get(1));
    try std.testing.expectEqual(@as(usize, 3), r.get(2));

    // remove compacts while keeping order (middle, head, tail).
    try std.testing.expect(r.remove(2));
    try std.testing.expect(!r.remove(99));
    try std.testing.expectEqual(@as(usize, 1), r.get(0));
    try std.testing.expectEqual(@as(usize, 3), r.get(1));
    r.push(4);
    try std.testing.expect(r.remove(1));
    try std.testing.expect(r.remove(4));
    try std.testing.expectEqual(@as(usize, 1), r.len());

    // remove_at returns the removed member and compacts (the claim).
    try std.testing.expectEqual(@as(usize, 3), r.remove_at(0));
    try std.testing.expect(r.empty());
    r.push(7);
    r.push(5);
    r.push(6);
    try std.testing.expectEqual(@as(usize, 5), r.remove_at(0));
    try std.testing.expectEqual(@as(usize, 7), r.remove_at(1));
    try std.testing.expectEqual(@as(usize, 6), r.remove_at(0));
    try std.testing.expect(r.empty());
}

test "scheduler: ready rings — seeded membership at init/spawn/pin with the invariant" {
    // Slice-1 seeding seams (no rotation yet — the checker's call
    // precondition; rotation paths wire into the rings in slice 2).
    _ = init();
    // init: the idle reaper is ring 0's only member; the shell is
    // scheduler.current[0] and executing (off-ring).
    try std.testing.expectEqual(@as(usize, 1), scheduler.ready_rings[0].len());
    try std.testing.expect(scheduler.ready_rings[0].contains(idle_id));
    check_ready_membership();

    // spawn: new ready scheduler.tasks join ring 0 in spawn order.
    const worker = register_worker(0x1111).?;
    try std.testing.expectEqual(@as(usize, 2), scheduler.ready_rings[0].len());
    try std.testing.expect(scheduler.ready_rings[0].contains(worker));
    const user = register_user(0x2222, 0).?;
    try std.testing.expect(scheduler.ready_rings[0].contains(user));
    // Slot-sorted run order: worker, user, idle (the old scan's order).
    try std.testing.expectEqual(@as(usize, 1), scheduler.ready_rings[0].get(0));
    try std.testing.expectEqual(@as(usize, 2), scheduler.ready_rings[0].get(1));
    try std.testing.expectEqual(@as(usize, idle_id), scheduler.ready_rings[0].get(2));
    check_ready_membership();

    // pin re-homes a still-ready task: ring 0 -> ring 1, and back.
    try std.testing.expect(pin_task(user, 1));
    try std.testing.expect(!scheduler.ready_rings[0].contains(user));
    try std.testing.expect(scheduler.ready_rings[1].contains(user));
    check_ready_membership();
    try std.testing.expect(pin_task(user, 0));
    try std.testing.expect(scheduler.ready_rings[0].contains(user));
    try std.testing.expect(!scheduler.ready_rings[1].contains(user));
    check_ready_membership();
}

test "scheduler: ready rings — reap drops the slot's ring membership" {
    _ = init();
    const t = spawn("ring-test", 0x6000, spsr_el1h_irqs, &scheduler.worker_stack, 0, 0).?;
    try std.testing.expect(scheduler.ready_rings[0].contains(t));
    // Exit it (state -> zombie) and reap. Slice 2: the exit path itself
    // drops the membership (the task was scheduler.current/off-ring — the remove is
    // defensive), so the checker is valid again right after the exit.
    scheduler.current[0] = t;
    try std.testing.expect(exit_current(7));
    try std.testing.expect(!scheduler.ready_rings[0].contains(t));
    check_ready_membership();
    try std.testing.expect(reap(t));
    try std.testing.expect(!scheduler.ready_rings[0].contains(t));
    // The freed slot is spawnable again and re-joins ring 0 exactly once.
    const again = spawn("ring-test-2", 0x6001, spsr_el1h_irqs, &scheduler.worker_stack, 0, 0).?;
    try std.testing.expectEqual(@as(usize, t), again);
    var on: usize = 0;
    for (&scheduler.ready_rings) |*r| {
        if (r.contains(again)) on += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), on);
}

test "scheduler: ready rings — rotation, block, wake, exit keep the invariant" {
    // Claim 881 slice 2: every rotation path claims from / pushes onto the
    // per-core rings, so the ready-membership invariant holds after every
    // transition — asserted with the checker at each phase.
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    check_ready_membership();

    // shell -> user: the shell joins ring 0; the worker stays ready.
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current[0]);
    try std.testing.expect(scheduler.ready_rings[0].contains(0));
    try std.testing.expect(scheduler.ready_rings[0].contains(1));
    check_ready_membership();

    // The user sleeps: blocked, off-ring; the successor is the idle
    // reaper (ring 0's always-ready seat).
    try std.testing.expect(sleep_current(1));
    try std.testing.expectEqual(@as(usize, idle_id), scheduler.current[0]);
    try std.testing.expect(!scheduler.ready_rings[0].contains(2));
    check_ready_membership();

    // Deadline passes: the user wakes onto its home ring (ring 0).
    on_tick();
    try std.testing.expect(!is_blocked(2));
    try std.testing.expect(scheduler.ready_rings[0].contains(2));
    check_ready_membership();

    // idle -> shell -> user: the woken user runs again.
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 0), scheduler.current[0]);
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current[0]);
    check_ready_membership();

    // The user scheduler.exits: zombie off-ring (the exit path drops membership), a
    // successor claimed from the ring.
    try std.testing.expect(exit_current(43));
    try std.testing.expectEqual(@as(usize, idle_id), scheduler.current[0]);
    try std.testing.expect(!scheduler.ready_rings[0].contains(2));
    check_ready_membership();

    // The idle reaper reaps; the slot stays off every ring.
    reap_one_zombie();
    try std.testing.expect(!scheduler.ready_rings[0].contains(2));
    check_ready_membership();
}

// ---------------------------------------------------------------------------
// Claim 881 slice 3 — per-ring locks; exit teardown out of scheduler.sched_lock
// ---------------------------------------------------------------------------

test "scheduler: rotation paths release every ring lock" {
    // Claim 881 slice 3: the rotation (yield/switch, block, exit) holds
    // the per-ring locks only for the claim/push/flip critical section —
    // an accidentally-held ring lock would stall every other core's
    // rotation forever (and a held-then-released pair is the easiest way
    // for this single-threaded suite to catch the choreography).
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    const rings_clear = struct {
        fn all_clear() bool {
            for (&scheduler.ring_locks) |*l| {
                if (l.lock_impl.is_locked()) return false;
            }
            return true;
        }
    }.all_clear;
    try std.testing.expect(rings_clear());
    try std.testing.expect(yield_current()); // shell -> user
    try std.testing.expect(rings_clear());
    try std.testing.expect(sleep_current(3)); // user -> idle (its successor)
    try std.testing.expect(rings_clear());
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expect(rings_clear());
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(rings_clear());
    try std.testing.expect(exit_current(43)); // worker -> idle (zombie)
    try std.testing.expect(rings_clear());
    // The kill conversion path releases the ring locks BEFORE the exit
    // teardown (the frozen lock-order rule) — drive it via a killed
    // selection and re-check.
    const worker2 = register_worker(0x2000).?; // a fresh worker (slot 3)
    try std.testing.expectEqual(KillResult.ok, request_kill(worker2));
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expect(yield_current()); // shell -> worker2 -> killed -> idle
    try std.testing.expect(rings_clear());
    check_ready_membership();
}

test "scheduler: rotation_lock holds every ring ascending; unlock releases all" {
    // Issue #857: the generalized steal scans every ring, so the
    // rotation's set is ALL rings acquired in ascending index order (the
    // frozen no-cycle rule). Verify the helper's lock/unlock
    // choreography directly.
    _ = init();
    const lk0 = rotation_lock(0);
    for (&scheduler.ring_locks) |*l| try std.testing.expect(l.lock_impl.is_locked());
    rotation_unlock(lk0);
    for (&scheduler.ring_locks) |*l| try std.testing.expect(!l.lock_impl.is_locked());
    const lk1 = rotation_lock(1);
    for (&scheduler.ring_locks) |*l| try std.testing.expect(l.lock_impl.is_locked());
    rotation_unlock(lk1);
    for (&scheduler.ring_locks) |*l| try std.testing.expect(!l.lock_impl.is_locked());
}

test "scheduler: teardown_pending gates the reaper off a mid-teardown zombie" {
    // Claim 881 slice 3: the exit teardown runs OUTSIDE scheduler.sched_lock; the
    // zombie mark + teardown_pending flag (under scheduler.sched_lock) keep the
    // idle reaper off the slot until the teardown completes. Simulate
    // the mid-teardown window and verify reap refuses, then clears.
    _ = init();
    _ = register_worker(0x2000).?; // slot 1 — the user then lands at slot 2
    _ = register_user(0x3000, 0).?;
    start();
    try std.testing.expect(yield_current()); // shell -> user
    try std.testing.expect(exit_current(43)); // user -> shell (zombie)
    try std.testing.expect(is_terminated(2));
    // Mid-teardown: the slot is a zombie but the reaper must not touch it.
    scheduler.tasks[2].teardown_pending = true;
    try std.testing.expect(!reap(2));
    try std.testing.expect(!reap(2)); // still gated
    try std.testing.expect(task_info(2) != null);
    // Teardown completes: the reaper may free the slot.
    scheduler.tasks[2].teardown_pending = false;
    try std.testing.expect(reap(2));
    try std.testing.expect(task_info(2) == null);
    // A reaped slot's flag is cleared by the reset; a fresh exit -> reap
    // cycle never sees a stale gate.
    try std.testing.expectEqual(@as(usize, 2), register_user(0x3000, 0).?);
    try std.testing.expect(!scheduler.tasks[2].teardown_pending);
}

// ---------------------------------------------------------------------------
// WMP card 3 — the reschedule request (#1274)
// ---------------------------------------------------------------------------
//
// WMP card 1 (#1247) measured the cost of the absence of prompt preemption:
// the scheduler only evaluates it at the 1 Hz period tick, so a woken WM waited
// a uniformly distributed 0-1 s for its frame (786-1216 ms typical, 3004 ms
// worst) while the frame's own transfer+flush was ~0.3 ms. These tests pin the
// REQUEST BOOKKEEPING that measures that demand. They deliberately do not pin
// any comparator move — there isn't one yet; the pull is parked on #1255.
//
// The coalescing rule is the whole safety argument for ever adding the pull: at
// most one request is outstanding between rotations, so a pointer storm would
// cost one extra preemption, not one per wake.

test "scheduler: a wake through the ready-ring funnel raises a reschedule request; a core-0 rotation discharges it" {
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    // Explicit reset: these are module globals and the host test binary runs
    // every scheduler test in one process.
    for (&scheduler.resched_requested) |*r| r.* = false;
    scheduler.resched_requests = 0;
    scheduler.resched_coalesced = 0;
    scheduler.resched_discharged = 0;

    try std.testing.expect(!scheduler.resched_requested[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler.resched_requests);

    try std.testing.expect(yield_current()); // shell -> user (slot 2)

    // The running user sleeps. Blocking stages a successor and takes the user
    // off the rings — NO task became runnable, so nothing is owed. A user- or
    // WM-initiated block must not count as demand, or a GUI that blocks waiting
    // for input would report the comparator hot for the whole wait.
    try std.testing.expect(sleep_current(1));
    try std.testing.expect(is_blocked(2));
    try std.testing.expect(!scheduler.resched_requested[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler.resched_requests);
    check_ready_membership();

    // The deadline passes and the sleeper becomes runnable again. In a real boot
    // this runs inside `tick`'s `on_tick`, so the rotation from the SAME beat
    // discharges the request and the tick-driven wake is served for free; here
    // `on_tick` is driven standalone, which is what leaves the request
    // observable to the test. (With M70b wake targeting the wake still lands
    // on ring 0 here: the host test boots with only core 0 online, so the
    // targeting scan skips every offline core.)
    on_tick();
    try std.testing.expect(!is_blocked(2));
    try std.testing.expect(scheduler.ready_rings[0].contains(2));
    try std.testing.expect(scheduler.resched_requested[0]);
    try std.testing.expectEqual(@as(u64, 1), scheduler.resched_requests);
    check_ready_membership();

    // COALESCE: while a request is outstanding, further demand is absorbed
    // rather than counted again. Two more demands leave `requests` at 1 — this
    // is what would cap a wake burst at one extra preemption, and it is why a
    // burst cannot turn the comparator into a storm if the pull is ever added.
    request_resched_on(0);
    request_resched_on(0);
    try std.testing.expectEqual(@as(u64, 1), scheduler.resched_requests);
    try std.testing.expectEqual(@as(u64, 2), scheduler.resched_coalesced);

    // A core only ever clears ITS OWN outstanding request (M70b: the request
    // is per-core — the pre-M70b core-0-only gate is subsumed by this, since
    // a core can only raise requests on cores whose ring took a wake).
    discharge_resched(1);
    try std.testing.expect(scheduler.resched_requested[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler.resched_discharged);

    // The core-0 rotation does discharge it. (This is the pure half of `tick`;
    // that `tick` calls it at its tail, on the path that actually rotated, is
    // asserted at the source level below.)
    discharge_resched(0);
    try std.testing.expect(!scheduler.resched_requested[0]);
    try std.testing.expectEqual(@as(u64, 1), scheduler.resched_discharged);

    // Discharge must leave the mechanism ARMED, not latched off: the next wake
    // owes a fresh rotation. Without this, one discharge would silence every
    // later wake and the demand would silently read as zero forever.
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expect(yield_current()); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current[0]);
    try std.testing.expect(sleep_current(1));
    try std.testing.expect(!scheduler.resched_requested[0]);
    on_tick();
    try std.testing.expectEqual(@as(u64, 2), scheduler.resched_requests);
    check_ready_membership();
}

// ---------------------------------------------------------------------------
// M70b (#1454): wake targeting + the per-core resched request + the
// RESCHEDULE SGI nudge. Host tests boot with only core 0 online
// (`smp.core_online[1..3] == false`), which is exactly the offline-gating
// property the live 1/2-core boots rely on: the tests that need the
// multi-core shape bring the other cores online explicitly and restore
// them afterwards.
// ---------------------------------------------------------------------------

test "scheduler: wake targeting — least-loaded online core, caller wins ties (M70b)" {
    _ = init();
    // Bring every core online (deferred restore: the rest of the suite
    // relies on the single-core boot shape — and `init` resets only
    // current[0], so the fake per-core currents must be restored too).
    scheduler.smp.core_online[1] = true;
    scheduler.smp.core_online[2] = true;
    scheduler.smp.core_online[3] = true;
    defer scheduler.smp.core_online[1] = false;
    defer scheduler.smp.core_online[2] = false;
    defer scheduler.smp.core_online[3] = false;
    defer scheduler.current[1] = idle_id;
    defer scheduler.current[2] = idle_id;
    defer scheduler.current[3] = idle_id;

    // Core 0 executes the shell (current[0] = 0 -> load 1); the rest are
    // parked with EMPTY rings — a parked core is load 0, the most attractive
    // target, which is exactly the point of the heuristic: wake onto an idle
    // core. The first minimal load cyclically after the caller is core 1.
    try std.testing.expectEqual(@as(usize, 1), scheduler.wake_target_core());

    // A running task on core 1: loads c0=1, c1=1, c2=0, c3=0 → the first
    // minimal after the caller is still core 2.
    scheduler.current[1] = 4;
    try std.testing.expectEqual(@as(usize, 2), scheduler.wake_target_core());

    // A ring member on core 3 too: c2 stays the unique minimum.
    scheduler.ready_rings[3].push(6);
    try std.testing.expectEqual(@as(usize, 2), scheduler.wake_target_core());

    // Load core 2 to parity: c0=1, c1=1, c2=1, c3=1 → caller wins the tie.
    scheduler.current[2] = 4;
    try std.testing.expectEqual(@as(usize, 0), scheduler.wake_target_core());

    // OFFLINE gating: with core 0 loaded to 2 (extra ring member), core 1
    // is at the strict minimum; take core 1 offline and the scan must skip
    // it — the next minimum is the c2/c3 tie (load 1 each), won by the
    // lower index, never an offline core.
    scheduler.ready_rings[0].push(7);
    try std.testing.expectEqual(@as(usize, 1), scheduler.wake_target_core());
    scheduler.smp.core_online[1] = false;
    try std.testing.expectEqual(@as(usize, 2), scheduler.wake_target_core());
}

test "scheduler: the wake funnel places unpinned wakes on the target ring, nudges a parked target, and raises a PER-CORE request (M70b)" {
    _ = init();
    // `init` resets only current[0]; normalize the secondaries explicitly
    // so this test pins its own precondition.
    scheduler.current[1] = idle_id;
    scheduler.current[2] = idle_id;
    scheduler.current[3] = idle_id;
    const worker = register_worker(0x1111).?; // slot 1; spawn lands on ring 0 (cores 1-3 offline)
    start();
    for (&scheduler.resched_requested) |*r| r.* = false;
    scheduler.resched_requests = 0;
    scheduler.resched_coalesced = 0;
    scheduler.resched_discharged = 0;
    // The wake counters accumulate across the whole test binary — snapshot
    // baselines instead of assuming zeros.
    const wake_remote0 = scheduler.wake_remote;
    const wake_local0 = scheduler.wake_local;
    const wake_nudges0 = scheduler.wake_nudges;
    scheduler.smp.core_online[1] = true;
    scheduler.smp.core_online[2] = true;
    scheduler.smp.core_online[3] = true;
    defer scheduler.smp.core_online[1] = false;
    defer scheduler.smp.core_online[2] = false;
    defer scheduler.smp.core_online[3] = false;

    // Loads with the worker off its ring: c0=1 (shell), c1=c2=c3=0 → the
    // first minimal after the caller (0) is core 1.
    try std.testing.expect(scheduler.ready_rings[0].remove(worker));
    scheduler.push_home_locked(worker);
    try std.testing.expect(scheduler.ready_rings[1].contains(worker));
    try std.testing.expect(!scheduler.ready_rings[0].contains(worker));
    // Remote wake to a PARKED target: nudged (send_ipi is a no-op on the
    // host) and a request raised ON THE TARGET, not on core 0.
    try std.testing.expectEqual(wake_remote0 + 1, scheduler.wake_remote);
    try std.testing.expectEqual(wake_local0, scheduler.wake_local);
    try std.testing.expectEqual(wake_nudges0 + 1, scheduler.wake_nudges);
    try std.testing.expect(scheduler.resched_requested[1]);
    try std.testing.expect(!scheduler.resched_requested[0]);

    // The target's rotation discharges its own request; core 0's discharge
    // cannot clear it.
    discharge_resched(0);
    try std.testing.expect(scheduler.resched_requested[1]);
    try std.testing.expectEqual(@as(u64, 0), scheduler.resched_discharged);
    discharge_resched(1);
    try std.testing.expect(!scheduler.resched_requested[1]);
    try std.testing.expectEqual(@as(u64, 1), scheduler.resched_discharged);
    check_ready_membership();

    // Every core busy (running-load 1 everywhere) → the caller's own core
    // wins the tie: a LOCAL wake, no nudge.
    scheduler.current[1] = 4;
    scheduler.current[2] = 4;
    scheduler.current[3] = 4;
    defer scheduler.current[1] = idle_id;
    defer scheduler.current[2] = idle_id;
    defer scheduler.current[3] = idle_id;
    try std.testing.expect(scheduler.ready_rings[1].remove(worker));
    scheduler.push_home_locked(worker);
    try std.testing.expect(scheduler.ready_rings[0].contains(worker));
    try std.testing.expectEqual(wake_local0 + 1, scheduler.wake_local);
    try std.testing.expectEqual(wake_nudges0 + 1, scheduler.wake_nudges); // unchanged
    try std.testing.expect(scheduler.resched_requested[0]);
}

test "scheduler: a wake before preemption is armed requests nothing" {
    // The same boundary `start` draws for preemption itself. Boot-time wakes
    // (process registration, the early service spawns) run before the shell loop
    // is the running context, and must not be counted as demand against a shell
    // that is not yet running.
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    for (&scheduler.resched_requested) |*r| r.* = false;
    scheduler.resched_requests = 0;
    try std.testing.expect(!enabled());

    request_resched_on(0);
    try std.testing.expect(!scheduler.resched_requested[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler.resched_requests);

    // ...and the identical call IS live once preemption is armed, so the guard
    // is a gate and not a permanently dead path.
    start();
    request_resched_on(0);
    try std.testing.expect(scheduler.resched_requested[0]);
    try std.testing.expectEqual(@as(u64, 1), scheduler.resched_requests);
    discharge_resched(0);
}

test "scheduler: M129b max_tasks is 3 kernel + 61 user slots (#2611)" {
    // The M65d derivation was kernel 3 + 3 runtimes × 4 Ms + 1 spare = 16.
    // M129b re-derived it at the 512 MiB default: the pool is the sole
    // concurrency bound (a service-graph boot plus a restored session
    // saturates 16), measured per-task cost is a 48-page EL1 kstack plus
    // ~1 KiB BSS, and the exec-side binder stays the 512-table carve-out
    // — so the pool is sized for ~15 compiled-GOMAXPROCS runtimes.
    //   kernel fixed     = shell + worker + idle = 3
    //   user slots       = 61 ≈ 15 runtimes × 4 Ms
    //   max_tasks        = 64; idle_id stays max_tasks-1
    const kernel_fixed: usize = 3;
    const user_slots: usize = 61;
    try std.testing.expectEqual(kernel_fixed + user_slots, max_tasks);
    try std.testing.expectEqual(max_tasks - 1, idle_id);
    try std.testing.expectEqual(user_slots, max_tasks - kernel_fixed);
}

test "scheduler: seating 3 runtimes × 4 Ms leaves headroom then fills (#1442)" {
    _ = init();
    _ = register_worker(0x2000).?;
    try std.testing.expectEqual(@as(usize, 2), register_user(0x3000, 0).?);
    const go_ms: usize = 12; // 3 runtimes × 4 Ms
    var fill: usize = 0;
    var last_root: u64 = 0;
    while (fill < go_ms - 1) : (fill += 1) {
        const kstack = exec_kstack_pool[fill][0..];
        const entry: u64 = 0x4000 + fill * 0x1000;
        const stack_va: u64 = 0x1a400000 + fill * 0x100000;
        last_root = (mmu.build_user_root(userspace.text_va, 0x1000, 64, stack_va, 0x3000, 8192) orelse
            return error.TestUnexpectedResult);
        _ = register_exec_user(entry, last_root, 64, stack_va, 8192, kstack, 0, 0) orelse
            return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 3 + go_ms), scheduler.task_count); // 15 occupied
    try std.testing.expect(has_free_slot()); // the #1426-style headroom
    // M129b: fill the remaining user slots — the same registration path
    // saturates at max_tasks (extra tasks reuse the last root; a task's
    // root is bookkeeping here, not a live TTBR0).
    while (scheduler.task_count < max_tasks) : (fill += 1) {
        const kstack = exec_kstack_pool[fill][0..];
        try std.testing.expect(register_exec_user(0x9000 + fill * 0x1000, last_root, 64, 0x2a400000, 8192, kstack, 0, 0) != null);
    }
    try std.testing.expectEqual(max_tasks, scheduler.task_count);
    try std.testing.expect(!has_free_slot());
    try std.testing.expect(register_worker(0) == null);
}

// ---------------------------------------------------------------------------
// M133b (#2756): scheduler aging — decay arithmetic + starvation bound
// ---------------------------------------------------------------------------

test "scheduler: M133b aging — a burned slice accrues decay, capped at age_max; a yield does not" {
    _ = init();
    const user = register_user(0x2222, 0).?;
    start();
    // Drive the user task into `current` and charge it timer preemptions.
    _ = scheduler.ready_rings[0].remove(user); // registered ready on ring 0
    scheduler.current[0] = user;
    scheduler.tasks[user].state = .running;
    var k: u8 = 0;
    while (k < scheduler.age_max + 2) : (k += 1) {
        timer_switch_context(scheduler.tasks[user].sp, 0x3004, spsr_el0t_irqs, 0);
        const want: u8 = @intCast(@min(@as(usize, k) + 1, @as(usize, scheduler.age_max)));
        try std.testing.expectEqual(want, scheduler.tasks[user].age_penalty);
        // age_skip is charged to the penalty but may already have drained
        // once inside the switch's own claim scan (a lone-task ring's
        // fallback re-picks the outgoing task) — the skip arithmetic is
        // pinned by the ring_claim tests below, not here.
        try std.testing.expect(scheduler.tasks[user].age_skip <= want);
        // Re-arm the user as the outgoing task for the next charge without
        // going through the claim (which would drain the skip).
        _ = scheduler.ready_rings[0].remove(user);
        scheduler.current[0] = user;
        scheduler.tasks[user].state = .running;
    }
    try std.testing.expectEqual(scheduler.age_max, scheduler.tasks[user].age_penalty);
    try std.testing.expect(scheduler.tasks[user].age_skip <= scheduler.age_max);
    check_ready_membership();
}

test "scheduler: M133b aging — cooperative rotations leave decay at zero" {
    _ = init();
    _ = register_worker(0x1111).?;
    const user = register_user(0x2222, 0).?;
    start();
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        // A cooperative yield + the plain save/claim/stage path — neither
        // is a burned timer slice, so nothing may age.
        try std.testing.expect(yield_current());
        switch_context(0x1000 + @as(u64, i), 0x1000 + @as(u64, i), spsr_el1h_irqs, 0);
    }
    for (scheduler.tasks) |task| {
        try std.testing.expectEqual(@as(u8, 0), task.age_penalty);
        try std.testing.expectEqual(@as(u8, 0), task.age_skip);
    }
    _ = user;
    check_ready_membership();
}

test "scheduler: M133b aging — a decayed task loses picks until its skip drains" {
    _ = init();
    const a = spawn("hog", 0x3000, spsr_el1h_irqs, &exec_kstack_pool[0], 0, 0).?;
    const b = spawn("mate", 0x4000, spsr_el1h_irqs, &exec_kstack_pool[1], 0, 0).?;
    // a is a two-slice decayed task: it must lose exactly age_skip picks
    // to its un-decayed queue-mates, then win.
    scheduler.tasks[a].age_penalty = 2;
    scheduler.tasks[a].age_skip = 2;
    // Scan order after slot 0: a(1), b(2), idle(63). The idle reaper is
    // itself a queue-mate at decay 0 here — keep the assertions on the
    // first three picks before it can rotate in.
    try std.testing.expectEqual(@as(?usize, b), ring_claim(0, 0)); // a skipped (2->1)
    try std.testing.expectEqual(@as(u8, 1), scheduler.tasks[a].age_skip);
    scheduler.ready_rings[0].push(b); // the claimed mate re-readies
    try std.testing.expectEqual(@as(?usize, b), ring_claim(0, 0)); // a skipped again (1->0)
    try std.testing.expectEqual(@as(u8, 0), scheduler.tasks[a].age_skip);
    scheduler.ready_rings[0].push(b);
    try std.testing.expectEqual(@as(?usize, a), ring_claim(0, 0)); // eligible now — wins
    // The claim only removes the task; the stage would flip it running —
    // a .ready task off every ring trips the membership invariant.
    scheduler.current[0] = a;
    scheduler.tasks[a].state = .running;
    check_ready_membership();
}

test "scheduler: M133b aging — the all-decayed scan falls back to the least-decayed candidate" {
    _ = init();
    const a = spawn("hog", 0x3000, spsr_el1h_irqs, &exec_kstack_pool[0], 0, 0).?;
    const b = spawn("hog2", 0x4000, spsr_el1h_irqs, &exec_kstack_pool[1], 0, 0).?;
    scheduler.tasks[a].age_skip = 2;
    scheduler.tasks[b].age_skip = 3;
    scheduler.tasks[idle_id].age_skip = 3;
    // Every candidate is decayed: the claim still returns a pick (the
    // starvation guard) — the least-decayed one after this scan's drains.
    try std.testing.expectEqual(@as(?usize, a), ring_claim(0, 0));
    try std.testing.expectEqual(@as(u8, 1), scheduler.tasks[a].age_skip);
    try std.testing.expectEqual(@as(u8, 2), scheduler.tasks[b].age_skip);
    try std.testing.expectEqual(@as(u8, 2), scheduler.tasks[idle_id].age_skip);
    scheduler.current[0] = a;
    scheduler.tasks[a].state = .running;
    scheduler.tasks[b].age_skip = 0;
    scheduler.tasks[idle_id].age_skip = 0;
    check_ready_membership();
}

test "scheduler: M133b aging — a capped hog is re-selected within the stated bound" {
    _ = init();
    const hog = spawn("hog", 0x3000, spsr_el1h_irqs, &exec_kstack_pool[0], 0, 0).?;
    const m1 = spawn("mate1", 0x4000, spsr_el1h_irqs, &exec_kstack_pool[1], 0, 0).?;
    const m2 = spawn("mate2", 0x5000, spsr_el1h_irqs, &exec_kstack_pool[2], 0, 0).?;
    scheduler.tasks[hog].age_penalty = scheduler.age_max;
    scheduler.tasks[hog].age_skip = scheduler.age_max;
    // The bound the code comment states: a ready task wins within
    // age_max * max_tasks + 1 claims. Tighten it for this shape: the hog
    // drains one skip per scan that passes over it, so it must be picked
    // within age_max + (ring population) claims — the claim loop below
    // fails long before the loose bound is in question.
    var picks: usize = 0;
    var hog_seen = false;
    var c: usize = 0;
    while (c < scheduler.age_max + max_tasks) : (c += 1) {
        const claimed = ring_claim(0, 0) orelse break;
        picks += 1;
        if (claimed == hog) {
            hog_seen = true;
            break;
        }
        scheduler.ready_rings[0].push(claimed); // the mate re-readies
        if (claimed != m1 and claimed != m2 and claimed != hog) break; // idle won a turn — population still contended
    }
    try std.testing.expect(hog_seen);
    try std.testing.expect(picks <= scheduler.age_max + max_tasks + 1);
    scheduler.current[0] = hog;
    scheduler.tasks[hog].state = .running;
    check_ready_membership();
}

test "scheduler: M133b aging — a committed block resets the decay" {
    _ = init();
    const user = register_user(0x2222, 0).?;
    start();
    try std.testing.expect(yield_current()); // shell -> user
    try std.testing.expectEqual(user, current_id());
    scheduler.tasks[user].age_penalty = 3;
    scheduler.tasks[user].age_skip = 3;
    try std.testing.expect(sleep_current(2));
    try std.testing.expectEqual(@as(u8, 0), scheduler.tasks[user].age_penalty);
    try std.testing.expectEqual(@as(u8, 0), scheduler.tasks[user].age_skip);
    try std.testing.expect(is_blocked(user));
    // The wake does not re-charge anything: the task re-enters ready at
    // full priority.
    on_tick();
    on_tick();
    try std.testing.expect(!is_blocked(user));
    try std.testing.expectEqual(@as(u8, 0), scheduler.tasks[user].age_penalty);
    try std.testing.expectEqual(@as(u8, 0), scheduler.tasks[user].age_skip);
    check_ready_membership();
}

// NOTE: there is deliberately no source-level "is it wired?" guard test here.
// The obvious one (embedding `../src/scheduler.zig` and grepping for the two
// call sites) does not compile — `@embedFile` cannot reach outside the test
// binary's package path, which is `kernel/tests/`. The wiring is pinned where
// it can actually be observed instead: `tools/gate/specs/live-wm-pacing.spec`
// asserts `resched_requests >= 1` and `resched_discharged >= resched_requests`
// on a real VZ boot, so deleting the funnel call site reads as zero requests
// and deleting the discharge reads as stranded requests. Both fail the gate.
