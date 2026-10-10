//! VirelaiOS tick-driven round-robin kernel task scheduler (claim 5275 —
//! the first milestone-three "tasks" card).
//!
//! Preemptive at the tick, or on an EL0 wake interrupting the demo worker:
//! the claim-9187 timer PPI enters the
//! claim-9746 EL1 IRQ vector, the GIC/timer chain runs (ack -> timer
//! handle/re-arm -> scheduler tick -> EOI), and the scheduler preempts the
//! current task for the next one. Claim 8215 extends the same fixed pool
//! with one EL0t task and no allocation: the shell keeps the handoff stack,
//! the EL1h worker has a static BSS stack, and the EL0 task has distinct
//! static EL1 exception and EL0 execution stacks.
//!
//! Why the switch is tiny:
//!   * The claim-9746 IRQ stubs already push the full register file (x0..
//!     x17 + x30, plus the claim-6729 callee-saved extension x19..x28 +
//!     x29) as a 256-byte "vector frame" on the interrupted task's stack,
//!     and pop it back before `eret`.
//!   * The scheduler therefore only saves/restores per task: the
//!     vector-frame pointer (sp), ELR_EL1 (interrupted PC) and SPSR_EL1
//!     (interrupted PSTATE). The frame pointer reaches the tick through
//!     `exceptions.resume_frame[c]` (staged by `exc_dispatch` at IRQ entry);
//!     the tick rewrites that global to the NEXT task's frame and programs
//!     ELR/SPSR, and the stub's `mov sp, x0` + register restore + `eret`
//!     lands in the next task exactly as if IT had been interrupted.
//!   * Claim 8215 also saves/restores SP_EL0. The exception dispatcher
//!     stages the source task's SP_EL0 and returns the selected task's value
//!     in x1; the vector exit installs it before `eret`. That is inert for
//!     EL1h tasks and essential for an EL0t task.
//!   * Round-robin: every tick preempts the current task; the next task
//!     resumes from wherever it was preempted.
//!
//! Console discipline: the scheduler itself never touches the console (IRQ
//! context — claim 9187). Worker progress is reported from the shell idle
//! loop via `maybe_report`, the same pattern as the timer heartbeat.
//!
//! Claim 5804: every task now owns a TTBR0 root. The EL1h shell/worker
//! share the EL1-only kernel root (identity map, zero EL0 leaves — also
//! the root runtime services run under); the EL0 task gets the user root
//! (text + stack only) and its entry/SP/witness are USER VAs, not kernel
//! addresses. The switch therefore programs TTBR0 + TLB-invalidates before
//! restoring ELR/SPSR.
//!
//! Claim 6729: the task lifecycle. Each pool slot carries an EXPLICIT
//! state: free -> ready -> running -> ready (preempted) -> zombie (exited)
//! -> free (reaped). `spawn` allocates the first free slot (bounded, no
//! dynamic allocation); `exit_current` (the sys_exit path) turns the
//! current task into a zombie; the scheduler-owned IDLE task (registered
//! at the last slot by `init`, always ready, WFE-parked) reaps one zombie
//! per iteration and the shell loop prints the reap. The idle task is the
//! ring's fallback, so an exit always has a successor and the pool drains
//! without a parent/child relationship. The monitor's `spawn` command
//! exercises runtime spawn with one dedicated demo stack.
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");
const builtin = @import("builtin");
pub const console = @import("console.zig");
pub const exceptions = @import("exceptions.zig");
pub const mmu = @import("mmu.zig"); // claim 5804: per-task TTBR0 roots
pub const userspace = @import("userspace.zig"); // claim 5804: user-VA layout
const shared_mmap = @import("shared_mmap.zig"); // M33 SB2 (claim 8878): shared-anon revoke-on-exit (ADR 0016 D2)
// Milestone four (claim 3848): the process registry — the task pool is the
// executor, the process owns the program (image + address space + lifecycle
// + exit status). One-way import: process.zig knows nothing about this
// module.
pub const process = @import("process.zig");
pub const svclock = @import("svclock.zig"); // claim 9498 follow-on: per-service-domain locks — canonical file < net < win < ev < kernel, then sched_lock (brief), ring locks innermost (claim 881 slice 3)
// Card 3f (claim 5965): the per-process IPC mailbox — the pool reset
// clears it and the boot payload's process registration resets its ring.
const mailbox = @import("mailbox.zig");
// Milestone 9 (claim 7670): per-process event queue
const events = @import("events.zig");
// Milestone 14 (claim 7323): per-process app timer facility — fired from
// the SAME host-testable tick seam as the sleep wakeups below.
const app_timers = @import("app_timers.zig");
// Milestone 10 (claim 9948): per-process file handle table
const file_table = @import("file_table.zig");
// Milestone 12 (claim 7483): per-process TCP connection cleanup
const tcp = @import("tcp.zig");
const virtio_snd = @import("virtio_snd.zig");
// Card G6 teardown follow-on (per-process window ownership): the exit path
// auto-closes the exiting process's user windows via `close_owner`. Pure
// BSS writes, safe in the exception context `exit_current` runs in.
const driving_award = @import("driving_award.zig");
// M32 WMS2 (issue #622): the render-server register. Fired from the SAME
// host-testable tick seam as app_timers; the exit path unregisters a dying
// WM so pacing falls back to the shell idle shim automatically.
pub const wm_server = @import("wm_server.zig");
// Arc5 issue #243: crash tombstone recording — written in the exit path
// when status is 139 (fault) or non-zero unexpected exits. Pure BSS
// writes, safe in the exception context `exit_current` runs in.
pub const alloc = @import("alloc.zig");
const tombstone = @import("tombstone.zig");
const symbol = @import("symbol.zig");
const serial_ring = @import("serial_ring.zig"); // Arc5 #243: serial snapshot for tombstones
const virtio_file = @import("virtio_file.zig"); // Arc5 #243: tombstone write through the host file channel (HF6: the DATA partition is gone)
pub const smp = @import("smp.zig");
const spinlock = @import("spinlock.zig");
const forensics = @import("forensics.zig"); // #1278: last-words recorder (inert unless `forensics on`)

const user_stack_section = if (builtin.object_format == .elf) ".userbss" else "__DATA,__userbss";

/// Round-robin pool (card 3g, claim 5795 — the pool-scale capstone;
/// milestone sixteen C3, claim 0339 — the measured growth; #1426 — three
/// concurrent Go runtimes). Card 3g set the budget at 7: shell + EL1h demo
/// worker + FOUR EL0t user slots + the scheduler-owned idle task (7/7,
/// FOUR live user programs). C3 measures that the demo apps exhaust those
/// four user slots — the exec path refuses a FIFTH concurrent program with
/// `pool_full` — and grows the pool to 11: shell + worker + EIGHT EL0t
/// user slots + idle. #1426: GOTABWM + two Go clients is 9/11 already
/// (each runtime is primary + sysmon + helper even with GOMAXPROCS=1); a
/// third runtime's sysmon hits EAGAIN. Grown 11 → 13 so idle_id stays
/// `max_tasks - 1` with TEN EL0t user slots (12 occupied + one spare).
/// M65d (#1442): every live Go M is a task (ADR 0027 D1). Compiled
/// default GOMAXPROCS=2 (D6) is 2 Ps + sysmon + template = 4 Ms per
/// runtime. Seating GOTABWM + two hosted ELFs is 3 × 4 = 12 user tasks;
/// plus shell + worker + idle = 15 occupied. Same one-spare headroom as
/// #1426 → 16 (`idle_id` stays `max_tasks - 1`; THIRTEEN EL0t user slots).
/// WM specs still pin GOMAXPROCS=1 (3 Ms/runtime); that still fits.
/// Fixed at comptime — no allocation, no dynamic registration or
/// processes; the lifecycle's spawn/reap only recycle these slots.
pub const max_tasks: usize = 16;
/// The idle task's fixed slot (registered by `init`, never recycled).
pub const idle_id: usize = max_tasks - 1;
/// The worker's static stack (BSS, like every other kernel global). The
/// shell task continues to run on the handoff stack.
// 16 KiB (claim 8877): the EL0 file-read path stacks ~5 KiB of staging
// (read_staging + file_table staging + FAT sector buffers) on the process's
// kernel stack; at 8 KiB an overflow spilled DOWNWARD into the adjacent
// user-stack pages (exec allocates text/stack/kstack consecutively) and
// clobbered DESKTOP's AppState with FAT bytes. The user stack doubles too
// — GUI apps get more headroom at no real cost.
/// Per-task stacks. Doubled 16 → 32 KiB for M25 Lane A/B (claims
/// 0434/2539): FILE.BIN's AppState alone occupies ~7.3 KiB of its EL0
/// stack, and real feature chains (batch ops + deferred listing walks)
/// overflowed the remaining headroom — observed live as guard-page
/// status=139 faults on VZ. Raised 32 → 192 KiB for #1336: FETCHS.BIN's
/// TLS 1.3 call nest reaches ~131 KiB below the stack top (prologue
/// `stp`, not a bad pointer); 192 KiB is the smallest page-aligned size
/// tried that is >131 KiB. Cost: +160 KiB BSS per static stack and 40
/// extra pages per stack (80 per exec: user stack + EL1 kstack).
pub const task_stack_size: usize = 192 * 1024;

/// SPSR modes for synthetic first entry. The kernel's observed M=0x5 is
/// architecturally EL1h (SP_EL1), not EL1t; EL0t is M=0x0. DAIF bits are
/// clear in both so the timer may preempt either task immediately.
pub const spsr_el1h_irqs: u64 = 0x5;
pub const spsr_el0t_irqs: u64 = 0x0;

/// Card 3c (claim 7786): the reserved exit status a force-terminated
/// process reports. A plain number (128 + 9) — no POSIX semantics; it is
/// the counter's `exit=137` / `tasks user-exec exited status=137` in the
/// serial log and the `procs` table.
pub const reserved_kill_status: u64 = 137;

/// Milestone sixteen C2 (claim 8403): the reserved exit status an EL0
/// synchronous fault (a guard-page step, an unmapped access, or a
/// non-executable fetch) reports. A plain number (128 + 11) — no POSIX
/// semantics; it is the `tasks GUARD.BIN exited status=139` line the live
/// gate asserts, distinct from the kill path's 137.
pub const reserved_fault_status: u64 = 139;
/// Arc5 issue #246: per-process memory limit exceeded (killed in page fault path).
pub const reserved_mem_limit_status: u64 = 140;
/// Arc5 issue #246: per-process CPU limit exceeded (killed in scheduler tick).
pub const reserved_cpu_limit_status: u64 = 141;

/// The claim-9746 vector frame: 32 slots holding x0..x17, x30, a pad, and
/// the claim-6729 callee-saved extension (x19..x28 + x29), pushed in
/// reverse pair order by the IRQ stub on the interrupted task's stack; the
/// "sp" a task saves/restores. The callee-saved half is what makes a
/// context switch safe for compiled tasks (a preempted task's live
/// x19..x28 survive the tick and are restored on resume — claim 6729
/// bisect).
pub const frame_bytes: usize = 32 * 8;

/// Explicit task lifecycle state (claim 6729). A slot's state is the ONLY
/// ownership signal: `free` slots are spawnable, `zombie` slots hold an
/// exited task's status until the idle task reaps them, and the idle task
/// itself never leaves `ready` (the scheduler refuses to exit it).
pub const State = enum {
    free,
    ready,
    running,
    /// Claim 0635: a task parked by `sys_sleep` until `wakeup_tick` ticks
    /// have passed. Blocked tasks drop out of the round-robin ring
    /// (`next_runnable` scans `ready` only) and the tick's `wake_expired`
    /// moves them back to `ready` when their deadline passes.
    blocked,
    zombie,
};

/// Human-readable state label for the `tasks` monitor command.
pub fn state_name(state: State) []const u8 {
    return switch (state) {
        .free => "free",
        .ready => "ready",
        .running => "running",
        .blocked => "blocked",
        .zombie => "zombie",
    };
}

/// Per-task extra-region capacity, sized for the WORST case (issue #1163
/// A1): every sys_mmap registers one read + one write extra (and the Go
/// runtime's sbrk heap accumulates up to `max_mmap_regions` of them), ON
/// TOP of the exec-path registrations (gap layout: rodata read + data
/// read/write; dynamic: data r/w + interp r/w + lib read). Sized as
/// max_mmap_regions + 8 so the exec shapes always fit with headroom; a
/// task that somehow exceeds it fails LOUDLY at `sys_mmap` time (ENOMEM)
/// instead of silently EFAULTing later.
pub const extra_region_capacity: usize = process.max_mmap_regions + 8;

/// Claim 0826: the uaccess/syscall apertures a user task's syscalls
/// validate against (its OWN text + stack VAs — every live user task has
/// its own root + stack now). Zero for EL1h tasks (they never SVC).
pub const UserRegions = struct {
    text: userspace.Region = .{ .base = 0, .len = 0 },
    stack: userspace.Region = .{ .base = 0, .len = 0 },
    extra_reads: [extra_region_capacity]userspace.Region = [_]userspace.Region{.{ .base = 0, .len = 0 }} ** extra_region_capacity,
    extra_read_count: usize = 0,
    extra_writes: [extra_region_capacity]userspace.Region = [_]userspace.Region{.{ .base = 0, .len = 0 }} ** extra_region_capacity,
    extra_write_count: usize = 0,
};

const Task = struct {
    name: []const u8 = "",
    state: State = .free,
    /// #1965: only the registered demo worker yields its place to ready EL0
    /// work. Shell, idle reaper and spawn-demo keep their existing rotation.
    demo_worker: bool = false,
    /// The source exception still owns this kernel stack. Publishing a
    /// ready task must not let another core restore its frame before the
    /// source handler has finished using the stack.
    exception_guard: u64 = 0,
    /// Saved vector-frame pointer (the SP to restore); 0 until the task
    /// has been preempted once (the shell task's context is captured on
    /// its first preemption; the worker's frame is built at registration).
    sp: u64 = 0,
    /// Interrupted PC (ELR_EL1) to `eret` to.
    elr: u64 = 0,
    /// Interrupted PSTATE (SPSR_EL1).
    spsr: u64 = 0,
    /// Stack selected by EL0t (and EL1t, which this scheduler does not
    /// create). EL1h tasks ignore this value.
    sp_el0: u64 = 0,
    /// B5: real AArch64 local-exec thread pointer, zero for legacy tasks.
    tls: u64 = 0,
    /// Physical TTBR0 root for this task's user space (claim 5804). The
    /// EL1h tasks point at the EL1-only kernel root; the EL0 task points at
    /// its text+stack-only user root. Written to TTBR0 on every switch.
    ttbr0: u64 = 0,
    /// Claim 0826: the user text/stack apertures this task's syscalls
    /// validate against (armed into the syscall layer at SVC entry). Each
    /// live user task carries its own regions; EL1h tasks leave them zero.
    regions: UserRegions = .{},
    /// How many times this task's context was saved by a tick.
    saves: u64 = 0,
    /// How many times this task's context was restored by a tick.
    resumes: u64 = 0,
    /// Task-side progress counter (the worker bumps it; `tasks` reports).
    advances: u64 = 0,
    /// Exit status preserved while the task is a zombie (until reaped).
    exit_status: u64 = 0,
    /// Claim 881 slice 3: the exit teardown runs OUTSIDE sched_lock
    /// (under the service-domain locks only). This gate keeps the idle
    /// reaper off the slot from the zombie mark until the teardown
    /// completes — the reaper must never free a slot mid-teardown.
    teardown_pending: bool = false,
    /// Claim 0635: scheduler tick count at/after which a `blocked` task
    /// wakes (`tick_count >= wakeup_tick`). Meaningful only while blocked.
    wakeup_tick: u64 = 0,
    /// Card 4c (claim 9946): the process id this blocked task waits on via
    /// `sys_wait` (slot 8). Set by `wait_current`; cleared when
    /// `wake_waiters` returns the task to `ready` on the target's exit. An
    /// EVENT block (no deadline) — distinct from the claim-0635 time block
    /// that uses `wakeup_tick`; the tick's `wake_expired` never touches a
    /// task with this field set.
    wait_pid: ?usize = null,
    /// Milestone 9 (claim 1016): the process id this blocked task waits on
    /// for application events via `sys_wait_event` (slot 22). Set by
    /// `wait_event_current`; cleared when `wake_event_waiters` returns the
    /// task to `ready` upon event enqueue.
    wait_event_pid: ?usize = null,
    /// Claim 6359 (wait_event fix): the event-buffer address a woken
    /// `sys_wait_event` task's re-executed `svc` must see. The blocking
    /// result write (x0=0) in the syscall layer clobbers the saved frame's
    /// x0 at block time; `wait_event_current` stashes the original
    /// argument here and `wake_event_waiters` patches it back into the
    /// saved frame before the task resumes, so the re-executed copy_out
    /// targets the app's buffer, not address 0.
    wait_event_buf: u64 = 0,
    /// Card 3c (claim 7786): armed-kill flag. `kill` sets it from main
    /// context; the ring converts the task's NEXT selection into the
    /// existing exit path (status 137) instead of resuming it — the OS,
    /// not the program, owns process lifetime. Reset by the slot's reap
    /// (`.{ }` clears it).
    kill_pending: bool = false,
    /// The reserved status the kill conversion exits with when
    /// `kill_pending` converts (claim 9498 follow-on: the CPU-limit
    /// arming rides 141, request_kill the 137 default). Reset to the
    /// default by the conversion and by the slot's reap (`.{ }` clears
    /// it).
    kill_pending_status: u64 = reserved_kill_status,
    /// #1978: at most one outstanding-exit diagnostic per task lifetime.
    exit_kill_reported: bool = false,
    /// SMP lift (claim 8477 follow-up): may this task run on a secondary
    /// core? Only console-free kernel tasks (the worker) and explicitly
    /// pinned user tasks today — ordinary user tasks print through the
    /// polled virtio TX and must stay on core 0 (their other syscalls
    /// touch unlocked core-0 state).
    secondary_ok: bool = false,
    /// SMP user tasks (claim 2369): the ONLY core this task may run on
    /// (0 = any core). Core 0's pick skips a pinned candidate outright;
    /// a secondary core's pick requires pin_core == its own id (plus
    /// `secondary_ok`). `exec -c<core>` sets this via `pin_task`.
    pin_core: usize = 0,
    /// ADR 0027 D3: this task is a THREAD of its process (created via
    /// `sys_thread` op 0), not the exec'd creator. Its EL1 exception stack
    /// is pool-allocated per thread and freed at this task's own reap.
    is_thread: bool = false,
    thread_kstack_phys: u64 = 0,
    thread_kstack_pages: u64 = 0,
    /// Non-recycled join token. An unjoined zombie retains its task seat.
    join_token: u64 = 0,
    join_pid: usize = 0,
    joiner: ?usize = null,
    wait_thread: bool = false,
    /// ADR 0027 D4: this blocked task is parked in `sys_futex` wait — the
    /// wake path patches its saved frame x0 (0 = real wake, the ETIMEDOUT
    /// errno on expiry) and clears its futex-table seat.
    futex_waiting: bool = false,
    /// M97g (#2079): spawn provenance for the WM seat gate. `spawned_by` is
    /// the pid of the process whose task allocated this task; `null` means
    /// the spawn ran on a kernel task (boot autostart, monitor `exec`,
    /// kernel-internal `exec_file_as`), which is the only provenance an EL0
    /// caller cannot forge. `launcher_spawned` marks a direct child of a
    /// KERNEL-SPAWNED process (INIT's service spawn is the desktop case):
    /// its own task's `spawned_by` was null. Neither field is writable from
    /// EL0; both are recomputed at task allocation, never inherited across
    /// a re-exec except through the same rule.
    spawned_by: ?usize = null,
    launcher_spawned: bool = false,
};
pub var tasks: [max_tasks]Task = [_]Task{.{}} ** max_tasks;
var exception_owner: [smp.max_cores]?usize = @splat(null);
var next_join_token: u64 = max_tasks;

/// #1978: first process-exit beat, also the late-thread publication guard.
/// sched_lock protects this scheduler-owned state; process.zig stays unchanged.
var process_exit_tick: [process.max_processes]?u64 = @splat(null);

/// Four full fixed-pool sweeps at the 1 s scheduler cadence. A diagnostic
/// fires only AFTER 64 ticks, never as a timeout or a change to wait semantics.
pub const exit_kill_diagnostic_ticks: u64 = 64;
const ExitKillReport = struct {
    pid: usize,
    task: usize,
    state: State,
    kill_pending: bool,
    futex_waiting: bool,
    wakeup_tick: u64,
    rings: u8,
    age: u64,
};
var exit_kill_reports: [max_tasks]ExitKillReport = undefined;
var exit_kill_report_head: usize = 0;
var exit_kill_report_count: usize = 0;

/// IRQs are masked and no scheduler lock is held at vector-dispatch entry.
pub fn begin_exception(c: usize) void {
    exception_owner[c] = null;
    if (task_count == 0 or (c != 0 and current[c] == idle_id)) return;
    const lk = rotation_lock(c);
    const id = current[c];
    @atomicStore(u64, &tasks[id].exception_guard, 1, .release);
    exception_owner[c] = id;
    rotation_unlock(lk);
}

/// Address consumed by the vector restore after it has switched SP away from
/// the source stack. Bit 0 protects the frame; bits 1..4 retain wake nudges
/// that arrived while another core was still finishing the source exception.
pub fn exception_handoff(c: usize) ?*u64 {
    const id = exception_owner[c] orelse return null;
    return &tasks[id].exception_guard;
}

/// Host simulation of the assembly handoff. Never release a live source
/// frame from C: even the dispatcher's epilogue still uses its source stack.
pub fn end_exception(c: usize) void {
    if (comptime !builtin.is_test) @compileError("live exception handoff belongs in the vector restore");
    const id = exception_owner[c] orelse return;
    const lk = rotation_lock(c);
    _ = @atomicRmw(u64, &tasks[id].exception_guard, .Xchg, 0, .acq_rel);
    exception_owner[c] = null;
    rotation_unlock(lk);
}

fn defer_frame_nudge(id: usize, home: usize) void {
    var guard = @atomicLoad(u64, &tasks[id].exception_guard, .acquire);
    while (guard & 1 != 0) {
        const nudged = guard | (@as(u64, 1) << @intCast(home + 1));
        if (@cmpxchgStrong(u64, &tasks[id].exception_guard, guard, nudged, .acq_rel, .acquire)) |changed| {
            guard = changed;
        } else return;
    }
}

fn save_tls(id: usize) void {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    tasks[id].tls = asm volatile ("mrs %[v], tpidr_el0"
        : [v] "=r" (-> u64),
    );
}

pub fn set_current_tls(value: u64) void {
    tasks[current_id()].tls = value;
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    asm volatile ("msr tpidr_el0, %[v]"
        :
        : [v] "r" (value),
        : .{ .memory = true });
}

// ---------------------------------------------------------------------------
// Futex wait table (ADR 0027 D4, issue #1214 round 2)
// ---------------------------------------------------------------------------

/// Bounded BSS wait table keyed (pid, uaddr) — the same shape as the
/// pipe/event seams, flat scan (max_tasks entries; no hash table at this
/// bound). `sys_futex` op 0 inserts the calling task; op 1 and the exit
/// path remove/wake.
pub const futex_max: usize = max_tasks;
const FutexEntry = struct {
    used: bool = false,
    pid: usize = 0,
    uaddr: u64 = 0,
    task: usize = 0,
};
var futex_table: [futex_max]FutexEntry = [_]FutexEntry{.{}} ** futex_max;

fn futex_entry_clear(entry: *FutexEntry) void {
    if (!entry.used) return;
    if (entry.task < max_tasks) {
        tasks[entry.task].futex_waiting = false;
    }
    entry.* = .{};
}

/// The (pid, uaddr) seat a task held in the futex wait table.
pub const FutexSeat = struct { pid: usize, uaddr: u64 };

/// Remove the calling task's futex seat, if any (exit path bookkeeping).
/// Returns the (pid, uaddr) it was waiting on so the exit path can perform
/// the wake-on-thread-death one-wake (ADR 0027 D4).
fn futex_clear_for(task_id: usize) ?FutexSeat {
    for (&futex_table) |*e| {
        if (e.used and e.task == task_id) {
            const out = FutexSeat{ .pid = e.pid, .uaddr = e.uaddr };
            futex_entry_clear(e);
            return out;
        }
    }
    return null;
}

/// Wake up to `n` waiters keyed (pid, uaddr): clear their seats, patch each
/// saved frame's x0 with `result` (0 for a real wake), and re-home them to
/// the ready rings. Returns the number woken. Caller holds sched_lock.
fn futex_wake_locked(pid: usize, uaddr: u64, n: usize, result: u64) usize {
    var woken: usize = 0;
    for (&futex_table) |*e| {
        if (woken >= n) break;
        if (!e.used or e.pid != pid or e.uaddr != uaddr) continue;
        const tid = e.task;
        futex_entry_clear(e);
        if (tid >= max_tasks or tasks[tid].state != .blocked) continue;
        tasks[tid].state = .ready;
        const frame: *exceptions.VectorFrame = @ptrFromInt(tasks[tid].sp);
        _ = exceptions.frame_write(frame, 0, result);
        push_home_locked(tid);
        woken += 1;
    }
    return woken;
}

// ---------------------------------------------------------------------------
// Per-core ready rings (claim 881 / issue #856)
// ---------------------------------------------------------------------------
//
// The ready ring of core `c` is the set of tasks core `c` will run next:
// a task with state `.ready` sits on EXACTLY ONE core's ring (its "home").
// Selection claims (removes) the member, so two cores can never both
// select the same ready task — single-owner by construction, not by lock.
// Claim 881 slice 1 introduced the structure + the seeding seams
// (init/spawn/pin/reap) with the invariant checker; slice 2 rewired every
// rotation path (tick/switch_context/yield/sleep/wait/exit + the wake
// placement) onto ring claim/push, so the ring is now the scheduler's
// ONLY notion of "ready" — the shared slot scan is gone.
//
// Ring-home rules (frozen in the claim): spawns join ring 0 unless
// `pin_core` is set (then that ring — a pinned task never leaves it); a
// preempted/self-yielded task joins the ring of the core it ran on; a
// blocked task leaves its ring and wakes onto ring 0 (or its pin ring);
// an idle core steals from ANY other ring at the WFE->run seam and on
// every rotation path (issue #857 — the generalized steal: a ready task
// parked on another core's ring migrates to the core that needs work,
// unless it is pinned there). Capacity is the
// whole pool: every task could be ready at once.
pub const ReadyRing = struct {
    /// Sorted compact membership list (ascending slot index), `members[0..
    /// count)`. Sorted order is what preserves the pre-ring round-robin:
    /// the old `next_runnable_for` scanned SLOT order from `after + 1`
    /// wrapping around, and the 508 host tests pin that exact order (e.g.
    /// after the user task exits, slot 3's spawn-demo runs before the
    /// always-ready idle at slot 10). Selection scans cyclically from the
    /// first member strictly after the interrupted slot, so a member at or
    /// before `after` is reached only at the wrap — the old scan's
    /// `offset == max_tasks` re-pick of the preempted task itself.
    members: [max_tasks]usize = undefined,
    count: usize = 0,

    pub fn len(self: *const ReadyRing) usize {
        return self.count;
    }

    pub fn empty(self: *const ReadyRing) bool {
        return self.count == 0;
    }

    /// The i-th member in run order (smallest slot first).
    pub fn get(self: *const ReadyRing, i: usize) usize {
        std.debug.assert(i < self.count);
        return self.members[i];
    }

    pub fn contains(self: *const ReadyRing, id: usize) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.members[i] == id) return true;
        }
        return false;
    }

    /// Insert keeping sorted (ascending slot) order. Single-home
    /// invariant: a task already on this (or any) ring must not be pushed
    /// again — the assert is the double-pick guard.
    pub fn push(self: *ReadyRing, id: usize) void {
        std.debug.assert(self.count < max_tasks);
        std.debug.assert(!self.contains(id));
        var i = self.count;
        while (i > 0 and self.members[i - 1] > id) : (i -= 1) {
            self.members[i] = self.members[i - 1];
        }
        self.members[i] = id;
        self.count += 1;
    }

    /// Remove `id`, compacting the tail down one slot. Returns false when
    /// it is not a member.
    pub fn remove(self: *ReadyRing, id: usize) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.members[i] != id) continue;
            _ = self.remove_at(i);
            return true;
        }
        return false;
    }

    /// Remove and return the member at `i`, compacting the tail down one
    /// slot. Removal IS the single-owner claim: a task taken out of its
    /// ring cannot be selected by any other core.
    pub fn remove_at(self: *ReadyRing, i: usize) usize {
        std.debug.assert(i < self.count);
        const id = self.members[i];
        var j = i;
        while (j + 1 < self.count) : (j += 1) {
            self.members[j] = self.members[j + 1];
        }
        self.count -= 1;
        return id;
    }
};

pub var ready_rings: [smp.max_cores]ReadyRing = [_]ReadyRing{.{}} ** smp.max_cores;

/// The ring a task's `ready` membership lives on: its pin core when
/// pinned, ring 0 for every core-0-only task (`secondary_ok` off — the
/// kernel tasks and the `exec -c0` / WM-registration pin semantics), else
/// the wake target (M70b #1454: the least-loaded online core — was: always
/// ring 0, the any-core default home).
fn home_ring_of(id: usize) usize {
    if (tasks[id].pin_core != 0) return tasks[id].pin_core;
    if (!tasks[id].secondary_ok) return 0;
    return wake_target_core();
}

/// Ring members that are REAL work: the core-0 ring permanently hosts the
/// idle fallback (slot max_tasks-1, the always-ready reaper), and counting
/// it would bias every wake away from core 0 by one phantom task. The
/// members array is slot-sorted and idle is the largest slot, so it can
/// only ever be the last member of ring 0.
fn ring_work_count(c: usize) usize {
    const ring = &ready_rings[c];
    // Snapshot once: this runs unlocked on every unpinned wake, and a
    // concurrent claim between loads could otherwise drop `count` to 0
    // and underflow the `members[n - 1]` index (M70b review).
    const n = ring.count;
    if (c == 0 and n > 0 and ring.members[n - 1] == idle_id) return n - 1;
    return n;
}

/// M70b #1454 deliverable 2 — wake targeting. The least-loaded ONLINE
/// core, scanned cyclically from the CALLER (ties keep the earlier scan
/// index, so an equal-load wake stays on the caller: no cross-core
/// traffic without a load reason). Load = the target ring's real-work
/// member count (`ring_work_count` — the core-0 idle fallback does not
/// count) plus one for the task the core is currently executing; a parked
/// core with an empty ring is load 0 — the most attractive target, which
/// is the point. The reads are racy BY DESIGN (plain aligned loads, no
/// locks): this is a placement heuristic, not an invariant — a stale
/// count mis-places one wake, it never loses one (the push itself takes
/// the target ring's lock, and the dequeue side still claims over the
/// merged view). Offline cores are skipped, so on a 1- or 2-VCPU boot —
/// and in every host test, where only core 0 is online — every unpinned
/// wake lands on ring 0 exactly as before this card.
pub fn wake_target_core() usize {
    const from: usize = smp.core_id();
    var best: usize = from;
    var best_load: usize = std.math.maxInt(usize);
    var i: usize = 0;
    while (i < smp.max_cores) : (i += 1) {
        const c = (from + i) % smp.max_cores;
        if (!smp.core_online[c]) continue;
        const load = ring_work_count(c) + @intFromBool(current[c] != idle_id);
        if (load < best_load) {
            best_load = load;
            best = c;
        }
    }
    // Core 0 is online from `init` on, so the scan always finds a core.
    return best;
}

/// Drop `id` from whichever ring holds it (cross-ring remove — the
/// exit/reap and pin re-home seams). Returns true when it was a member.
/// Claim 881 slice 3: takes each ring's lock in turn (never two at
/// once — a rotation holding every ring cannot deadlock against this
/// scan: the scan never holds a lock the rotation waits on while holding
/// another). Callers may hold sched_lock / a svclock domain
/// (ring locks are the innermost — the frozen lock-order rule).
fn ring_remove_anywhere(id: usize) bool {
    var c: usize = 0;
    while (c < smp.max_cores) : (c += 1) {
        const daif = ring_locks[c].lock();
        const found = ready_rings[c].remove(id);
        ring_locks[c].unlock(daif);
        if (found) return true;
    }
    return false;
}

/// Claim 881 slice 3 — per-ring IRQ-masking locks. The ring STRUCTURE
/// (members/count) is only ever mutated under its own ring's lock; the
/// rotation (claim/push/flip) holds ring locks ONLY, so one core's long
/// exit teardown or reap can no longer stall another core's rotation
/// (the global sched_lock shrank to TCB/report/cross-ring transitions).
/// IRQ masking matters for the same-core case: a main-context holder
/// (the shell's monitor commands, the idle reaper) must never be
/// preempted mid-push by a tick that then spins forever on the same
/// ring — masking IRQs for the whole hold means a holder always runs to
/// completion (the claim-9498 svclock lesson).
/// Lock-order rules (frozen in the claim): ring locks are the INNERMOST
/// locks — a ring lock may be taken while holding sched_lock or a
/// svclock domain (the wake/scan paths), but NEVER held across taking
/// another lock (the kill conversions release ring locks before their
/// svclock/sched_lock takes). A rotation holds EVERY ring's lock,
/// always acquired in ascending index order, so no cycle is possible.
pub var ring_locks: [smp.max_cores]spinlock.IrqSaveSpinlock = [_]spinlock.IrqSaveSpinlock{.{}} ** smp.max_cores;

pub const RingLockPair = struct { c: usize, saved: [smp.max_cores]u64 };

/// The rotation's ring-lock set: EVERY ring, acquired in ascending index
/// order (consistent order; the frozen no-cycle rule). The generalized
/// steal (issue #857) scans all rings, so scan+remove must be atomic
/// against every ring's claim — removal under a ring's own lock is still
/// the single-owner claim, but the slot-order snapshot needs all locks
/// held, or two cores could claim the same task off two rings' views.
pub fn rotation_lock(c: usize) RingLockPair {
    var saved: [smp.max_cores]u64 = undefined;
    var r: usize = 0;
    while (r < smp.max_cores) : (r += 1) {
        saved[r] = ring_locks[r].lock();
    }
    return .{ .c = c, .saved = saved };
}

pub fn rotation_unlock(lk: RingLockPair) void {
    var r: usize = smp.max_cores;
    while (r > 0) {
        r -= 1;
        ring_locks[r].unlock(lk.saved[r]);
    }
}

/// Push `id` onto its home ring under that ring's lock (the wake/scan
/// paths — callers hold sched_lock; ring locks are the innermost).
/// Pub for the host tests; production callers are the wake/scan paths.
pub fn push_home_locked(id: usize) void {
    const caller = smp.core_id();
    const home = home_ring_of(id);
    const daif = ring_locks[home].lock();
    ready_rings[home].push(id);
    defer_frame_nudge(id, home);
    ring_locks[home].unlock(daif);
    // This is the blocked->ready funnel, not the preempted task's direct
    // push in switch_context. Publish after the ring unlock and before the
    // SGI: the target must not discharge a request we have yet to set.
    request_resched_on(home);
    // M70b #1454: the wake lands on the least-loaded online core. A
    // remote PARKED target is nudged with the RESCHEDULE SGI — its
    // handler runs the same seam as tick's parked branch (capture the
    // WFE frame, claim, apply), so the woken task starts immediately
    // instead of waiting up to the 1 Hz PPI. #1965 also nudges a demo
    // worker when EL0 work becomes ready; other busy tasks keep their
    // pre-targeting cadence. send_ipi is a no-op on the
    // host and pre-SMP boots; the counters feed the `smp:` report as
    // observed data.
    if (home != caller) {
        wake_remote +%= 1;
        const parked = home != 0 and current[home] == idle_id;
        const worker_wake = tasks[current[home]].demo_worker and
            (tasks[id].spsr & 0xf) == spsr_el0t_irqs;
        if (smp.core_online[home] and (parked or worker_wake)) {
            wake_nudges +%= 1;
            smp.send_ipi(@intCast(home), smp.SGI_IPI_RESCHEDULE);
        }
    } else {
        wake_local +%= 1;
    }
    // #1278: this is the wake funnel, so it is where a dying boot's trace shows
    // whether the task that matters ever became runnable. `note` is a per-core
    // counter and one BSS slot when recording is off it returns on its first
    // byte, and it never prints — this runs in SVC/IRQ/lock-held contexts and
    // must stay allocation- and console-free.
    forensics.note(.wake, id);
}

/// The ready-membership invariant, asserted by the host tests after every
/// seam (and valid at every live seam since slice 2 — the rotation and
/// wake paths keep membership exact). Rules:
///   1. every member of every ring is a `.ready` task, on no other ring,
///      and not its own core's `current` (executing tasks are off-ring;
///      parked secondary cores legitimately hold `current = idle_id`);
///   2. every `.ready` task is on exactly one ring, unless it is a core's
///      `current` (executing off-ring — the boot shell / a
///      rollback-resumed task);
///   3. the idle reaper sits on ring 0 exactly (core-0-owned);
///   4. no non-`.ready` task is on any ring.
pub fn check_ready_membership() void {
    var c: usize = 0;
    while (c < smp.max_cores) : (c += 1) {
        const ring = &ready_rings[c];
        var i: usize = 0;
        while (i < ring.len()) : (i += 1) {
            const m = ring.get(i);
            std.debug.assert(m < max_tasks);
            std.debug.assert(tasks[m].state == .ready);
            var other: usize = 0;
            while (other < smp.max_cores) : (other += 1) {
                if (other == c) continue;
                std.debug.assert(!ready_rings[other].contains(m));
            }
            // A core never executes a task that sits on ITS OWN ring (the
            // double-run guard). Cross-core equality is legal: parked
            // secondary cores hold `current = idle_id` while the idle
            // reaper is ring 0's member.
            std.debug.assert(current[c] != m);
        }
    }
    var id: usize = 0;
    while (id < max_tasks) : (id += 1) {
        if (tasks[id].state == .ready) {
            var on: usize = 0;
            var ring_c: usize = 0;
            while (ring_c < smp.max_cores) : (ring_c += 1) {
                if (ready_rings[ring_c].contains(id)) on += 1;
            }
            std.debug.assert(on <= 1);
            if (on == 1) continue;
            var is_current: bool = false;
            var cur_c: usize = 0;
            while (cur_c < smp.max_cores) : (cur_c += 1) {
                if (current[cur_c] == id) is_current = true;
            }
            if (is_current) continue; // executing off-ring
            // The boot shell runs BEFORE the scheduler starts: it is
            // `.ready`, off-ring, and not any core's `current` until its
            // first real preemption joins it to ring 0 (`sp` is written by
            // that first save).
            std.debug.assert(id == 0 and tasks[0].sp == 0);
        } else {
            var ring_c: usize = 0;
            while (ring_c < smp.max_cores) : (ring_c += 1) {
                std.debug.assert(!ready_rings[ring_c].contains(id));
            }
        }
    }
    // The idle reaper is core-0-owned: `.ready` => ring 0 exactly (it may
    // ALSO be the parked `current` of secondary cores — legal); claimed by
    // core 0 and executing => off every ring.
    if (tasks[idle_id].state == .ready) {
        std.debug.assert(ready_rings[0].contains(idle_id));
        var ring_c: usize = 1;
        while (ring_c < smp.max_cores) : (ring_c += 1) {
            std.debug.assert(!ready_rings[ring_c].contains(idle_id));
        }
    } else {
        var ring_c: usize = 0;
        while (ring_c < smp.max_cores) : (ring_c += 1) {
            std.debug.assert(!ready_rings[ring_c].contains(idle_id));
        }
    }
}

pub var task_count: usize = 0;
/// The running task per core. Core 0 owns the task ring today
/// (irq_dispatch gates tick to PE 0 — claim 7339); cores 1-3 sit in
/// `idle_id` until the tick gate, ring locking, and task migration land.
/// The old `current_by_core` vestige folded into this array.
pub var current: [smp.max_cores]usize = [_]usize{ 0, idle_id, idle_id, idle_id };
/// Claim 881 slice 3: sched_lock SHRANK to the TCB/report/cross-ring
/// transitions — the zombie mark + exit report, the wake scans, the
/// reaper's check/reset, spawn/kill/pin TCB writes, and on_tick's
/// timekeeping beat. The rotation (claim/push/flip) holds only the
/// per-ring locks; the exit teardown and the page release hold only the
/// service-domain locks. Every hold is brief, so a tick's try_lock skip
/// (below) is a rare cadence loss, not a stall.
pub var sched_lock = spinlock.Spinlock.init();
/// The core that currently holds `sched_lock` (smp.max_cores = nobody).
/// Lets ring callbacks (the events.push hook) detect same-core reentry —
/// `on_tick` holds the lock when app_timers fires events, and the hook
/// wakes waiters by mutating the same ring.
var sched_lock_holder: usize = smp.max_cores;

/// M70b (#1454) measurement, landed BEFORE any placement change: how hot
/// the wake/TCB `sched_lock` actually runs on real cores. `acquires`
/// sizes the traffic (every spawn/wake/exit holds it), `contended` how
/// often the first cmpxchg found it held, `spins` the wasted attempts.
/// Plain BSS counters (`+%=`): two cores racing lose an increment now
/// and then — the signal this card needs is orders of magnitude above
/// that noise. Printed by the monitor `smp` command as observed data;
/// never a pass/fail threshold.
pub var sched_lock_acquires: u64 = 0;
pub var sched_lock_contended: u64 = 0;
pub var sched_lock_spins: u64 = 0;

fn sched_lock_acquire() void {
    if (!sched_lock.try_lock()) {
        sched_lock_contended +%= 1;
        while (true) {
            if (sched_lock.try_lock()) break;
            sched_lock_spins +%= 1;
            if (comptime builtin.cpu.arch == .aarch64) asm volatile ("yield");
        }
    }
    sched_lock_acquires +%= 1;
    sched_lock_holder = smp.core_id();
}

fn sched_lock_release() void {
    sched_lock_holder = smp.max_cores;
    sched_lock.unlock();
}
var enabled_flag: bool = false;
pub var switches: u64 = 0;
var cooperative_yields: u64 = 0;
pub var exits: u64 = 0;
/// SMP lift (claim 8477 follow-up) evidence: how many times a secondary
/// core staged a real task (WFE->task jump or secondary preemption).
/// Printed once per change from the shell idle loop (main context).
var secondary_runs: u64 = 0;
var secondary_runs_printed: u64 = 0;
/// The names of the most recent tasks a secondary core staged (the
/// evidence line's `task=`; a process name when one exists), one ring
/// slot per run so the drain can print EVERY run — a worker run between
/// two user runs would otherwise mask the user name (the drain only sees
/// the latest value).
var secondary_last_task: []const u8 = "";
const secondary_run_name_cap = 16;
var secondary_run_names: [secondary_run_name_cap][]const u8 = undefined;
var secondary_run_names_count: usize = 0;
/// Cross-core migration evidence (issue #857): how many times a rotation
/// claimed a task off ANOTHER core's ring (the generalized steal — core 0
/// pulling ring-1..3 work, or a secondary pulling from ring 0 or a
/// sibling secondary). Own-ring claims are not counted. Printed once per
/// change from the shell idle loop (main context), with the task name and
/// the source ring — the live proof that migration happened.
var steal_runs: u64 = 0;
var steal_runs_printed: u64 = 0;
var steal_last_task: []const u8 = "";
var steal_last_from: usize = 0;
const steal_run_name_cap = 16;
var steal_run_names: [steal_run_name_cap][]const u8 = undefined;
var steal_run_froms: [steal_run_name_cap]usize = undefined;
var steal_run_names_count: usize = 0;
/// Secondary-core WFE-park capture (claim 2369): the location of the WFE
/// loop's saved frame on the secondary stack + its ELR/SPSR, captured by
/// `tick` the moment it starts a task from the parked state. A running
/// task uses its OWN kstack (the eret into it moved SP_EL1 there), so
/// the WFE frame bytes stay pristine on the secondary stack; a core-1
/// task that exits with no eligible successor erets back to them instead
/// of rolling the exit back (the old core-0-only orelse).
var park_sp: [smp.max_cores]u64 = [_]u64{ 0, 0, 0, 0 };
var park_elr: [smp.max_cores]u64 = [_]u64{ 0, 0, 0, 0 };
var park_spsr: [smp.max_cores]u64 = [_]u64{ 0, 0, 0, 0 };
/// Claim 0635: scheduler tick counter — advanced once per timer tick by
/// `tick`/`on_tick`; the clock `sys_sleep` deadlines are measured against.
/// Distinct from `timer.ticks` (timer deliveries, including polls) because
/// the scheduler may be inactive or the timer path may change; the sleep
/// contract is in SCHEDULER ticks.
pub var tick_count: u64 = 0;

/// Restored-context staging, PER-CORE: written by `switch_context`/
/// `stage_selected` (rotation context) and applied by `apply_pending`
/// (IRQ context) on the SAME core — staging and apply never cross cores,
/// so indexing both by the running core keeps a switch atomic against that
/// core's own ticks. Cores 1-3 hold idle staging until they run tasks.
pub var pending_sp: [smp.max_cores]u64 = [_]u64{0} ** smp.max_cores;
pub var pending_elr: [smp.max_cores]u64 = [_]u64{0} ** smp.max_cores;
pub var pending_spsr: [smp.max_cores]u64 = [_]u64{0} ** smp.max_cores;
pub var pending_sp_el0: [smp.max_cores]u64 = [_]u64{0} ** smp.max_cores;
pub var pending_tls: [smp.max_cores]u64 = [_]u64{0} ** smp.max_cores;
var pending_ttbr0: [smp.max_cores]u64 = [_]u64{0} ** smp.max_cores;

/// Task reports (main-context console discipline, claim 9187): a task
/// marks ITS OWN report slot pending (claim 6729: one slot per pool entry,
/// so the worker's constant requests cannot starve another task's report);
/// the shell idle loop prints every pending slot via `maybe_report`.
var report_pending: [max_tasks]bool = [_]bool{false} ** max_tasks;
var report_advances: [max_tasks]u64 = [_]u64{0} ** max_tasks;
/// Card 3d (claim 1014): the task exit + reap reports are bounded FIFOs,
/// not single first-wins flags — N exits (or reaps) in one idle-loop
/// window print N lines IN ORDER instead of collapsing to one. Task names
/// are static string literals, so the name POINTER is a safe snapshot.
/// Overflow (a full ring) drops the OLDEST entry (documented + host-tested).
/// depth of the TASK-level exit-report ring (`tasks <name> exited status=`).
/// 8 (was 4, issue #1020): five sequential wasm execs now exit inside one
/// idle-loop drain window (the interpreter outgrew the old pacing), and a
/// full ring DROPS THE OLDEST — floatapp's exit-590 line was lost that way.
pub const exit_report_max: usize = 8;
const ExitEntry = struct { name: []const u8, status: u64 };
const ReapEntry = struct { name: []const u8 };
var exit_reports: [exit_report_max]ExitEntry = [_]ExitEntry{.{ .name = "", .status = 0 }} ** exit_report_max;
var exit_report_head: usize = 0;
var exit_report_count: usize = 0;
var reap_reports: [exit_report_max]ReapEntry = [_]ReapEntry{.{ .name = "" }} ** exit_report_max;
var reap_report_head: usize = 0;
var reap_report_count: usize = 0;
/// Milestone sixteen C2 (claim 8403): the EL0 fault reports are a bounded
/// FIFO like the exit reports — a faulting process's name + FAR_EL1 +
/// ESR_EL1 EC are snapshotted in exception context, then the shell idle
/// loop prints `fault: <name> far=0x... ec=0x...` IN ORDER. The name
/// pointer is a safe snapshot (task names are static string literals).
/// 8 (was 4, #1020 rot-class audit 2026-09-06): same drop-oldest discipline
/// as the exit-report rings — a busy drain window could silently lose the
/// oldest `fault:` line while `live-exceptions` asserts specific ones.
pub const fault_report_max: usize = 8;
const FaultEntry = struct { name: []const u8, far: u64, ec: u64, pc: u64 = 0, esr: u64 = 0 };
var fault_reports: [fault_report_max]FaultEntry = [_]FaultEntry{.{ .name = "", .far = 0, .ec = 0 }} ** fault_report_max;
var fault_report_head: usize = 0;
var fault_report_count: usize = 0;
/// Sleep report (claim 0635): `sys_sleep` marks it (exception context, like
/// exit); the shell idle loop prints it — the deterministic "this task is
/// now blocked for N ticks" transition line the live gate asserts.
var sleep_report_pending: bool = false;
var sleep_report_name: []const u8 = "";
var sleep_report_ticks: u64 = 0;

/// The demo worker's static stack.
pub var worker_stack: [task_stack_size]u8 align(16) = undefined;
/// EL1 exception stack used while the EL0 task is in an SVC or timer vector.
pub var user_kernel_stack: [task_stack_size]u8 align(16) = undefined;
/// Stack visible to the EL0 task itself through SP_EL0. Its dedicated linker
/// section is page-aligned so the MMU can grant this page range EL0 RW+XN
/// without exposing adjacent kernel BSS.
pub var user_stack: [task_stack_size]u8 align(4096) linksection(user_stack_section) = undefined;
/// EL0-visible, scheduler-written witness. The initial user frame receives its
/// address in x9; the payload waits for a non-zero value before invoking
/// sys_yield. It lives in the already-mapped user BSS aperture and exposes no
/// privileged state beyond the fact that this task was preempted by a tick.
pub var user_timer_preemptions: u64 align(8) linksection(user_stack_section) = 0;

// ---------------------------------------------------------------------------
// The reschedule request (WMP card 3 demand, #1274)
// ---------------------------------------------------------------------------
//
// WMP card 1 (#1247) measured what the ABSENCE of prompt preemption costs: the
// WM's pointer response was 786-1216 ms typical and 3004 ms worst, while a
// frame's own transfer+flush is ~0.3 ms. The scheduler only evaluates
// preemption at the 1 Hz period tick, so a task that becomes runnable just
// after a tick waits a uniformly distributed 0-1 s to execute.
//
// This block lands the MEASUREMENT of that demand and nothing else. The wake
// funnel records that a rotation is owed; every core-0 rotation records that it
// serviced one. No comparator is moved, no rotation is added, and no scheduling
// behaviour changes — with the request bookkeeping in place and no
// `timer.nudge()` behind it, a boot is exactly as schedulable as before. That
// is the `timer.nudge() disabled entirely -> PASS 2/2` probe from #1261's
// bisection, made permanent and observable.
//
// The nudge that would consume these counters (the comparator pull,
// `nudge_target`, the `period_tick` threading) is parked on draft PR #1255
// because it kills the SMP boot — `live-wnd5-gate2-policy` PASS -> FAIL, ending
// in a silent `VZVirtualMachine.State.error`. See #1252 and #1261. Landing the
// demand now means that when that defect is fixed, the win can be attributed to
// a measured number of owed rotations rather than asserted.

/// M70b #1454 wake-placement evidence (lossy BSS counters, drained by the
/// monitor `smp` command as observed data): `wake_local` — the target was
/// the calling core; `wake_remote` — a remote ring took the task; of
/// those, `wake_nudges` went to a parked (WFE) target that got the
/// RESCHEDULE SGI.
pub var wake_local: u64 = 0;
pub var wake_remote: u64 = 0;
pub var wake_nudges: u64 = 0;

/// A task became runnable while another is executing, so a rotation is OWED
/// on the core whose ring took it.
///
/// The flag is the coalescing rule: at most one request is outstanding per
/// core between rotations, so a burst of wakes costs one extra preemption
/// rather than one per wake. Cleared by every rotation on the core that owns
/// it (the tail of `tick`). M70b #1454 made this PER-CORE — before it, a wake
/// anywhere raised a core-0-only request, because every wake landed on ring 0;
/// with wake targeting the request belongs to the core whose ring received
/// the task.
pub var resched_requested: [smp.max_cores]bool = [_]bool{false} ** smp.max_cores;
/// Requests that owed a rotation (one per wake that found none already owed).
pub var resched_requests: u64 = 0;
/// Requests that arrived while one was already owed — the coalesced surplus.
/// This is the number that says whether coalescing is load-bearing or the wake
/// rate is simply too low to matter.
pub var resched_coalesced: u64 = 0;
/// Rotations that discharged a request.
pub var resched_discharged: u64 = 0;

/// A task just became runnable onto core `core`'s ring: record that a
/// rotation is owed there. Called from the wake funnel (`push_home_locked`),
/// so it covers every blocked->ready transition — event pushes
/// (`sys_wait_event`), process-exit waiters, futex wakes, spawn, and the
/// app-timer/WM-pacing fires inside `on_tick`.
///
/// Pure BSS writes: safe in the SVC, IRQ and lock-held contexts those paths run
/// in. No console, no allocation, no lock — and, load-bearing for this split, no
/// comparator write, so it cannot interrupt anything.
///
/// Deliberately narrow: a no-op until preemption is armed (`start`), so
/// boot-time wakes do not count against a shell loop that is not running yet.
pub fn request_resched_on(core: usize) void {
    if (!enabled_flag) return;
    if (resched_requested[core]) {
        resched_coalesced +%= 1;
        return;
    }
    resched_requested[core] = true;
    resched_requests +%= 1;
}

/// A rotation ran on core `c`: any request it was serving is discharged.
///
/// Split out of `tick` (rather than inlined at its tail) because `tick`'s body
/// is aarch64-only — it reads ELR_EL1/SPSR_EL1, which fault at EL0 — so a host
/// test cannot call it, while the coalescing rule is precisely what a host test
/// must be able to pin.
///
/// Per-core (M70b #1454): a core only ever clears its own outstanding request —
/// a secondary's rotation cannot swallow core 0's, and core 0 cannot swallow a
/// secondary's.
pub fn discharge_resched(c: usize) void {
    if (resched_requested[c]) {
        resched_requested[c] = false;
        resched_discharged +%= 1;
    }
}

/// M70b #1454 — the scheduler half of the RESCHEDULE SGI (the wake-target
/// nudge). Called from main.zig's irq_dispatch right after `smp.handle_sgi`,
/// so smp.zig keeps no scheduler dependency. A PARKED secondary (current ==
/// idle, interrupted out of its WFE loop) runs exactly the seam tick's parked
/// branch runs: capture the WFE frame, claim a successor over the rings, and
/// apply it — the vector stub then erets straight into the woken task, which
/// is the whole point of the nudge (sub-tick wake latency instead of up to
/// the 1 Hz PPI). #1965 also preempts a demo worker with eligible ready EL0
/// work, on any core. Other running tasks only record the request. No console,
/// no allocation, no unbounded spinning.
pub fn ipi_reschedule() void {
    if (!scheduling_active()) return;
    const c = smp.core_id();
    request_resched_on(c);
    if (irq_exit_reschedule()) return;
    if (c == 0 or current[c] != idle_id) {
        return;
    }
    const pc = current_exception_pc();
    park_sp[c] = exceptions.resume_frame[c];
    park_elr[c] = pc.elr;
    park_spsr[c] = pc.spsr;
    if (claim_and_stage(c, idle_id)) apply_pending();
}

/// #1965: serve a wake at IRQ exit without changing the tick or preempting
/// any other EL1 task. Called after device handling and from the RESCHEDULE
/// SGI. The interrupted worker owns the vector frame; all handler locks must
/// be released before this seam. Host tests exercise the same save/restore.
pub fn irq_exit_reschedule() bool {
    if (!scheduling_active()) return false;
    const c = smp.core_id();
    if (!resched_requested[c] or !tasks[current[c]].demo_worker) return false;
    const lk = rotation_lock(c);
    const user_ready = ready_user_for(c);
    rotation_unlock(lk);
    if (!user_ready) return false;
    const pc = current_exception_pc();
    switch_context(exceptions.resume_frame[c], pc.elr, pc.spsr, exceptions.resume_sp_el0[c]);
    apply_pending();
    discharge_resched(c);
    return true;
}
/// The idle task's static stack (BSS, like every other kernel global).
var idle_stack: [task_stack_size]u8 align(16) = undefined;
/// The monitor `spawn` command's dedicated demo stack; one spawn only, so
/// the demo task never shares a stack with another live task.
var spawn_demo_stack: [task_stack_size]u8 align(16) = undefined;
var spawn_demo_armed: bool = false;

// ---------------------------------------------------------------------------
// Registration (kernel seam, before the shell loop starts)
// ---------------------------------------------------------------------------

/// Register the boot/main task (the shell). Its context is empty until the
/// first tick preempts it. Also registers the scheduler-owned idle task at
/// the LAST slot (claim 6729). Resets the module so tests are deterministic.
/// Returns the task id (0).
pub fn init() usize {
    task_count = 0;
    current[0] = 0; // the shell boots on core 0
    switches = 0;
    cooperative_yields = 0;
    exits = 0;
    enabled_flag = false;
    // M70b (#1454): the counters are BSS-zero (monotonic) on a live boot,
    // but the host test binary runs every test in one process — reset with
    // the rest so no test inherits another's wake/contention history.
    sched_lock_acquires = 0;
    sched_lock_contended = 0;
    sched_lock_spins = 0;
    wake_local = 0;
    wake_remote = 0;
    wake_nudges = 0;
    resched_requests = 0;
    resched_coalesced = 0;
    resched_discharged = 0;
    for (&resched_requested) |*r| r.* = false;
    @memset(&report_pending, false);
    exit_report_head = 0;
    exit_report_count = 0;
    reap_report_head = 0;
    reap_report_count = 0;
    fault_report_head = 0;
    fault_report_count = 0;
    sleep_report_pending = false;
    spawn_demo_armed = false;
    steal_runs = 0;
    steal_runs_printed = 0;
    steal_run_names_count = 0;
    user_timer_preemptions = 0;
    tick_count = 0;
    process_exit_tick = @splat(null);
    exit_kill_report_head = 0;
    exit_kill_report_count = 0;
    next_join_token = max_tasks;
    pending_tls = @splat(0);
    for (&tasks) |*task| task.* = .{};
    exception_owner = @splat(null);
    for (&futex_table) |*e| e.* = .{};
    // Claim 3848: every pool reset also clears the process layer (the
    // boot path initializes both here; host tests get isolation). Card 3f
    // (claim 5965): the IPC mailbox rings reset with it. Card E1 (claim 7670):
    // event queues reset with it.
    process.init();
    mailbox.init();
    events.init();
    events.on_event_pushed = wake_event_waiters;
    app_timers.init();
    wm_server.init();
    tasks[0] = .{ .name = "shell", .state = .ready, .spsr = spsr_el1h_irqs, .ttbr0 = mmu.kernel_root_phys() };
    tasks[idle_id] = .{
        .name = "idle",
        .state = .ready,
        .sp = build_initial_frame(&idle_stack, @intFromPtr(&idle_entry)),
        .elr = @intFromPtr(&idle_entry),
        .spsr = spsr_el1h_irqs,
        .ttbr0 = mmu.kernel_root_phys(),
    };
    // Claim 881 slice 1: every test reset also clears the per-core ready
    // rings, then the always-ready idle reaper takes its ring-0 seat (the
    // shell is `current[0]` and executing — off-ring until its first real
    // preemption joins it to ring 0 in the slice-2 rotation wiring).
    // Slice 3: the per-ring locks reset with the rings (test isolation).
    for (&ready_rings) |*r| r.* = .{};
    for (&ring_locks) |*l| l.* = .{};
    ready_rings[0].push(idle_id);
    task_count = 2;
    return 0;
}

/// Claim 6729: allocate the first free pool slot for a new task and build
/// its synthetic initial frame on `stack`. Explicit, bounded allocation:
/// returns null when the fixed pool is full (every slot registered). The
/// caller supplies the name, runtime entry address, SPSR mode, TTBR0 root,
/// and SP_EL0 (0 for EL1h tasks). The new task starts `ready`.
pub fn spawn(name: []const u8, entry: u64, spsr: u64, stack: []u8, ttbr0: u64, sp_el0: u64) ?usize {
    sched_lock_acquire();
    defer sched_lock_release();
    const id = alloc_task_locked(name, entry, spsr, stack, ttbr0, sp_el0) orelse return null;
    tasks[id].state = .ready;
    // Claim 881 slice 1: the new task joins its home ring (ring 0 for the
    // any-core default; `pin_task` re-homes it when `exec -c<core>` pins).
    // Slice 3: the push takes the home ring's lock (we hold sched_lock).
    push_home_locked(id);
    return id;
}

/// `spawn` internals: claim the first free pool slot and build the
/// synthetic frame, leaving the task OFF the ready rings in `.blocked` so
/// a caller with more TCB fields to set (the ADR 0027 thread path) can
/// finish before any core can select it. `spawn` publishes immediately;
/// `spawn_thread` publishes after its process bind. Caller holds
/// sched_lock (which also keeps `wake_expired` from touching the not-yet-
/// published `.blocked` slot: every tick path takes sched_lock).
fn alloc_task_locked(name: []const u8, entry: u64, spsr: u64, stack: []u8, ttbr0: u64, sp_el0: u64) ?usize {
    var id: usize = 0;
    while (id < max_tasks) : (id += 1) {
        if (tasks[id].state == .free) break;
    }
    if (id >= max_tasks) return null;
    // #2079: record spawn provenance while the spawner is still observable.
    // `find_by_task` answers null when the allocation runs on a kernel task
    // (boot, monitor exec, autostart) — that is the kernel-spawned class the
    // WM seat gate trusts unconditionally. A bound process task whose OWN
    // `spawned_by` is null is a kernel-spawned process (INIT): its direct
    // children form the launcher class the seat gate name-checks.
    const spawner = process.find_by_task(current[smp.core_id()]);
    tasks[id] = .{
        .name = name,
        .sp = build_initial_frame(stack, entry),
        .elr = entry,
        .spsr = spsr,
        .sp_el0 = sp_el0,
        .ttbr0 = ttbr0,
        .state = .blocked,
        .spawned_by = spawner,
        .launcher_spawned = spawner != null and tasks[current[smp.core_id()]].spawned_by == null,
    };
    task_count += 1;
    return id;
}

/// Register the claim-5275 demo worker (an EL1h task that bumps its advance
/// counter each quantum). `entry` is a runtime-computed function address
/// (the caller takes `@intFromPtr(&task_fn)`).
pub fn register_worker(entry: u64) ?usize {
    sched_lock_acquire();
    defer sched_lock_release();
    const id = alloc_task_locked("worker", entry, spsr_el1h_irqs, &worker_stack, mmu.kernel_root_phys(), 0) orelse return null;
    // The worker is console-free (note_advance + request_report + spin),
    // so it is the one task safe on a secondary core (the polled virtio
    // TX has no lock — anything that prints must stay on core 0). Claim
    // 907 regression lesson (sb4): with the worker core-0-only, a
    // secondary core's empty-ring claim picks a floating USER task
    // instead, and a yield-looping user task on an AP floods the shell's
    // unbounded secondary-runs drain, starving heartbeat/dui. The worker
    // on an AP spins quietly (EL1h lone-task rule: no successor, no
    // preemption churn), and any pinned task on that core preempts it at
    // the next tick (successor exists), so the claim-907 starve hazard
    // does not materialize.
    tasks[id].secondary_ok = true;
    tasks[id].demo_worker = true;
    tasks[id].state = .ready;
    push_home_locked(id);
    return id;
}

/// Register the first real lower-privilege task. Its saved register frame
/// lives on a private EL1 exception stack; its code executes with EL0t at a
/// USER VA (claim 5804: `entry` is the kernel-side address of the payload
/// and `image_base` the loader base — both are converted to user VAs here)
/// under the task's own TTBR0 user root, with a separate SP_EL0 user stack
/// and the timer-preemption witness at its user VA (the payload dereferences
/// it through x9 at EL0).
///
/// Claim 6783 + claim 0826: register the ESP-loaded user program (exec) as
/// an EL0t task. The caller (`exec.zig`) has already built the process's
/// OWN user root and allocated its OWN user stack + EL1 exception stack, so
/// every parameter is per-process: `entry_va` (user VA), `root_phys` (the
/// process's TTBR0 root — NOT the shared global), `text_len`/`stack_va`/
/// `stack_len` (the process's apertures, recorded in the TCB so the syscall
/// layer arms the right bounds at SVC entry), and `kstack` (the process's
/// EL1 exception stack — two live user tasks cannot share the static one:
/// a second task's exception frame would clobber the first's saved vector
/// frame). The pool's spare slot (the claim-6729 `spawn_demo` pattern) is
/// the second live user slot; `spawn` returning null is the capacity gate.
pub fn register_exec_user(
    entry_va: u64,
    root_phys: u64,
    text_len: u64,
    stack_va: u64,
    stack_len: u64,
    kstack: []u8,
    argc: u64,
    argv_va: u64,
) ?usize {
    const id = register_exec_user_pinned(entry_va, root_phys, text_len, stack_va, stack_len, kstack, argc, argv_va, 0, null) orelse return null;
    publish_task(id);
    return id;
}

pub fn register_exec_user_auxv(
    entry_va: u64,
    root_phys: u64,
    text_len: u64,
    stack_va: u64,
    stack_len: u64,
    kstack: []u8,
    argc: u64,
    argv_va: u64,
    auxv_va: u64,
) ?usize {
    const id = register_exec_user_pinned(entry_va, root_phys, text_len, stack_va, stack_len, kstack, argc, argv_va, auxv_va, null) orelse return null;
    publish_task(id);
    return id;
}

/// The exec registration, pin-aware and publish-safe (M70b #1454). The
/// whole TCB build happens with the task `.blocked` OFF the rings, and
/// every field that affects placement (pin_core / secondary_ok) is FINAL
/// before the caller publishes it with `publish_task`. With wake targeting
/// a parked remote core can claim the task the moment it lands on a ring
/// (the SGI nudge makes that immediate), so a pin applied after publish
/// loses the race — observed live as `exec -c0 SMPEV.BIN` being claimed by
/// a parked secondary mid-exec and then stuck on that core (its own
/// preemption returns it to that core's ring, and pinned tasks are never
/// stolen). The spawn_thread path (ADR 0027) already builds under one
/// sched_lock hold for exactly this reason; this is the same discipline
/// for the exec seam.
///
/// Pin semantics = `pin_task`'s: `null`/any-core — `secondary_ok` on;
/// `p > 0` — pinned to that secondary (`secondary_ok` on); `p == 0` —
/// pinned to CORE 0 only (`secondary_ok` off; the claim-907 console rule).
/// The task stays `.blocked` and must be published by the CALLER (after
/// the process bind), or torn down on failure.
pub fn register_exec_user_pinned(
    entry_va: u64,
    root_phys: u64,
    text_len: u64,
    stack_va: u64,
    stack_len: u64,
    kstack: []u8,
    argc: u64,
    argv_va: u64,
    auxv_va: u64,
    pin: ?usize,
) ?usize {
    const sp_el0 = stack_va + stack_len;
    sched_lock_acquire();
    defer sched_lock_release();
    const id = alloc_task_locked("user-exec", entry_va, spsr_el0t_irqs, kstack, root_phys, sp_el0) orelse return null;
    // M70b review blocker: a fresh slot's `wakeup_tick` defaults to 0, and
    // `wake_expired` reads any blocked non-waiter with `tick_count >=
    // wakeup_tick` as an expired sleep — exec builds across TWO sched_lock
    // holds with a lock-free gap (regions/bind happen between them), and
    // IRQ masking is per-core, so on an AP exec core 0's tick could fire in
    // that gap and publish the half-built task (post-M70b the SGI nudge
    // hands it to a parked AP before the build completes). Sentinel it
    // "wait forever" until `publish_task` makes the task visible; the
    // single-hold builders (spawn, spawn_thread) never expose a gap.
    tasks[id].wakeup_tick = std.math.maxInt(u64);
    if (pin) |p| {
        tasks[id].pin_core = p;
        tasks[id].secondary_ok = (p != 0);
    } else {
        // Claim 9498: unpinned user tasks may run on ANY core (the console TX
        // is locked — claim 2369 — and the userspace-service gate serializes
        // their syscalls). `exec -c<core>` / the WM registration pin via the
        // `pin` argument instead of a post-publish `pin_task`.
        tasks[id].secondary_ok = true;
    }
    tasks[id].regions = .{
        .text = .{ .base = userspace.text_va, .len = text_len },
        .stack = .{ .base = stack_va, .len = stack_len },
    };
    // Card 3e (claim 4636): the entry-contract extension — the exec'd
    // program's `_start` receives argc in x0 and the argv block VA in x1.
    // Dynamic linking (claim 7921): interpreter receives auxv_va in x2.
    const frame: *exceptions.VectorFrame = @ptrFromInt(tasks[id].sp);
    _ = exceptions.frame_write(frame, 0, argc);
    _ = exceptions.frame_write(frame, 1, argv_va);
    _ = exceptions.frame_write(frame, 2, auxv_va);
    return id;
}

/// Publish a task registered `.blocked` (register_exec_user_pinned, or any
/// alloc_task_locked build): flip to ready and push to its home ring. The
/// placement fields must already be final — this is the point of no
/// return (a remote parked core can claim the task the instant it lands).
/// The wake-funnel side effects (per-core resched request + parked-target
/// SGI nudge) fire from push_home_locked exactly as for spawn. The
/// registration's "wait forever" `wakeup_tick` sentinel is cleared here:
/// from this point the task is the wake_expired clock's to manage (a
/// later `sys_sleep`/futex deadline overwrites it).
pub fn publish_task(id: usize) void {
    sched_lock_acquire();
    defer sched_lock_release();
    if (id >= max_tasks or tasks[id].state != .blocked) return;
    tasks[id].wakeup_tick = 0;
    tasks[id].state = .ready;
    push_home_locked(id);
}

/// Restrict task `id` to a single core (claim 9498: a RESTRICTION over
/// the any-core default every user task now spawns with). `core > 0`
/// pins to that secondary core (secondary_ok on, so that core's pick can
/// take it); `core = 0` pins to CORE 0 only (secondary_ok off) — used by
/// the registered WM, whose COMPOSITE_TICK pacing is core-0-tick-driven.
/// Used by `exec -c<core>` and the WM registration; must be called right
/// after the task is spawned (before it can be picked).
pub fn pin_task(id: usize, core: usize) bool {
    // Brief sched_lock: the TCB write + re-home (the re-home's ring ops
    // take the ring locks themselves — innermost).
    sched_lock_acquire();
    defer sched_lock_release();
    if (id >= max_tasks or tasks[id].state == .free) return false;
    tasks[id].pin_core = core;
    tasks[id].secondary_ok = (core != 0);
    // Claim 881 slice 1: a still-`ready` task re-homes to its pin ring so
    // the membership invariant holds (a task pinned after spawn must leave
    // ring 0; a task pinned back to 0 returns home). A task that is
    // already running/blocked/zombie is off-ring by construction — its
    // fields are set and the next preemption/wake places it per the pin.
    if (tasks[id].state == .ready) {
        _ = ring_remove_anywhere(id);
        push_home_locked(id);
    }
    return true;
}

/// Issue #1163 (GOOS=virelai phase 0a): the gap-layout ELF loader maps
/// text at the image's DECLARED base (not userspace.text_va), so it
/// re-points the freshly registered task's text region after
/// `register_exec_user`. Caller must own the just-spawned task (pre-run).
pub fn set_task_text_region(id: usize, base: u64, len: u64) void {
    if (id < max_tasks) {
        tasks[id].regions.text = .{ .base = base, .len = len };
    }
}

/// Register an extra READ region on the task's TCB. Returns false (LOUD —
/// callers must fail the operation honestly) when the task is out of
/// slots; silent drops made mmap'd memory invisible to copy_in.
pub fn add_task_read_region(id: usize, reg: userspace.Region) bool {
    if (id < max_tasks and tasks[id].regions.extra_read_count < tasks[id].regions.extra_reads.len) {
        tasks[id].regions.extra_reads[tasks[id].regions.extra_read_count] = reg;
        tasks[id].regions.extra_read_count += 1;
        return true;
    }
    return false;
}

/// Register an extra WRITE region on the task's TCB (see add_task_read_region).
pub fn add_task_write_region(id: usize, reg: userspace.Region) bool {
    if (id < max_tasks and tasks[id].regions.extra_write_count < tasks[id].regions.extra_writes.len) {
        tasks[id].regions.extra_writes[tasks[id].regions.extra_write_count] = reg;
        tasks[id].regions.extra_write_count += 1;
        return true;
    }
    return false;
}

/// Claim 0826: the pool has at least one free slot (the exec gate — a new
/// program may load and run while another is alive; only the fixed pool
/// bounds how many). The exec path checks this BEFORE allocating pages or
/// tables, so a full pool fails cheaply with `pool_full` and never leaks.
pub fn has_free_slot() bool {
    for (tasks[0..max_tasks]) |task| {
        if (task.state == .free) return true;
    }
    return false;
}

/// Card 3c (claim 7786): the result of arming a task for termination.
/// `request_kill` only ARMS — the actual exit happens at the task's next
/// ring selection (`claim_and_stage`/`switch_context` convert the
/// existing exit path). The refusals are clean and exact (the `kill`
/// monitor command host-tests every string).
pub const KillResult = enum {
    /// The target is armed; it will exit with `reserved_kill_status` at
    /// its next scheduled quantum (or yield/sleep wake).
    ok,
    /// No task occupies that slot (never registered or already reaped).
    not_found,
    /// The target is already a zombie (it exited and awaits the reap).
    already_exited,
    /// The shell or the scheduler-owned idle task: the console must
    /// survive (killing the shell would end the session).
    refused,
};

/// Arm pool slot `id` for termination (card 3c). The kill takes effect
/// at the target's next ring selection: the claim site sees
/// `kill_pending` and calls the existing `exit_current(reserved_kill_status)`
/// instead of resuming the task — the full exit → zombie → idle-reap →
/// page-return lifecycle runs, with the reserved status reported. Pure
/// TCB write, safe from the monitor's main context. Returns the exact
/// refusal for unknown/already-exited/scheduler-owned targets.
pub fn request_kill(id: usize) KillResult {
    sched_lock_acquire();
    defer sched_lock_release();
    if (id >= max_tasks or tasks[id].state == .free) return .not_found;
    if (tasks[id].state == .zombie) return .already_exited;
    // The shell (id 0) owns the console and the idle task is
    // scheduler-owned (never exits — exit_current refuses it anyway);
    // neither may be force-terminated.
    if (id == idle_id or id == 0) return .refused;
    tasks[id].kill_pending = true;
    return .ok;
}

/// Milestone sixteen C2 (claim 8403): an EL0 synchronous fault reached the
/// exception dispatcher (registered as `exceptions.set_fault_dispatcher`).
/// Snapshot the faulting task's name + FAR_EL1 + ESR_EL1 EC into the bounded
/// fault FIFO, then terminate the process through the existing exit path
/// with `reserved_fault_status` — the full exit → zombie → idle-reap →
/// page-return lifecycle runs, the ring stages the next task, and the shell
/// survives. Pure BSS writes, safe in the exception context the dispatcher
/// runs in (no console, no allocation).
pub fn fault_current(esr: u64, far: u64, pc: u64) void {
    if (task_count == 0) return;
    const c = smp.core_id(); // per-core current
    // Prefer the PROCESS name (e.g. "GUARD.BIN") over the generic task name
    // ("user-exec") — the process name is a stable name_buf slice, so the
    // pointer is a safe FIFO snapshot (same rule as the exit reports).
    const name: []const u8 = if (process.find_by_task(current[c])) |pid|
        process.info(pid).?.name
    else
        tasks[current[c]].name;
    const ec = (esr >> 26) & 0x3f;
    if (fault_report_count == fault_report_max) {
        fault_report_head = (fault_report_head + 1) % fault_report_max;
        fault_report_count -= 1;
    }
    const idx = (fault_report_head + fault_report_count) % fault_report_max;
    fault_reports[idx] = .{ .name = name, .far = far, .ec = ec, .pc = pc, .esr = esr };
    fault_report_count += 1;
    // Arc5 issue #246: if the process has a memory limit and it's exceeded,
    // use status 140 (mem_limit) instead of 139 (guard page). #2115: a
    // charge REFUSED at the ceiling names the same verdict — the refusal
    // leaves usage == limit, which `check_mem_limit`'s `>` cannot see.
    const fault_status = if (process.find_by_task(current[c])) |pid|
        if (process.check_mem_limit(pid) or process.mem_limit_refused(pid)) reserved_mem_limit_status else reserved_fault_status
    else
        reserved_fault_status;
    _ = exit_current(fault_status);
}

/// The user apertures of the CURRENT task (the EL0t task about to SVC —
/// zero for EL1h tasks). The syscall layer arms these into uaccess at SVC
/// entry so `sys_write` bounds always follow the task that issued the call.
pub fn current_user_regions() UserRegions {
    return tasks[current[smp.core_id()]].regions;
}

pub fn register_user(entry: u64, image_base: u64) ?usize {
    // Claim 5804: this runs POST-jump, so the incoming `entry` and these
    // `@intFromPtr` values are KVA addresses — the user-VA conversion
    // helpers expect the pre-jump PHYSICAL (identity) addresses (their
    // formula is `user_va + (kernel_addr - image_base) - section_start`,
    // which only holds in the identity world). to_phys is the identity on
    // host tests and pre-jump, so the conversion is safe everywhere.
    const entry_va = userspace.image_user_va(image_base, mmu.to_phys(entry));
    const sp_el0 = userspace.bss_user_va(image_base, mmu.to_phys(@intFromPtr(&user_stack))) + user_stack.len;
    const witness_va = userspace.bss_user_va(image_base, mmu.to_phys(@intFromPtr(&user_timer_preemptions)));
    const text = userspace.text_va_region();
    const stack = userspace.stack_va_region();
    const id = spawn("user-el0", entry_va, spsr_el0t_irqs, &user_kernel_stack, mmu.user_root_phys(), sp_el0) orelse return null;
    tasks[id].secondary_ok = true; // claim 9498: user tasks may run on any core
    // Claim 0826: the boot payload carries its static apertures in the TCB
    // so the syscall layer can arm them at SVC entry like any user task.
    tasks[id].regions = .{ .text = text, .stack = stack };
    // Claim 3848: the boot-time static EL0 payload is a PROCESS too — the
    // one table shows both its lifecycle and the exec'd programs'. Its
    // image is the static payload (no file name) and its address space is
    // the current user root at the fixed stack placement. Best effort: a
    // full registry (impossible at boot) must not fail the payload.
    if (process.create("user-el0", .{ .entry_va = entry_va, .content_len = text.len }, .{
        .root_phys = mmu.user_root_phys(),
        .text_va = text.base,
        .text_len = text.len,
        .stack_va = stack.base,
        .stack_len = stack.len,
    }, .{})) |proc_id| {
        // Card 3f (claim 5965): the payload's process id starts with a
        // clean IPC ring (same reset the exec path applies).
        mailbox.reset(proc_id);
        events.reset(proc_id);
        file_table.reset_process(proc_id);
        app_timers.reset(proc_id);
        _ = process.bind(proc_id, id);
    }
    const frame: *exceptions.VectorFrame = @ptrFromInt(tasks[id].sp);
    _ = exceptions.frame_write(frame, 9, witness_va);
    return id;
}

/// Start preempting on ticks. Called only once the shell loop is the
/// running context, so boot-time printing is never preempted.
pub fn start() void {
    enabled_flag = true;
}

pub fn enabled() bool {
    return enabled_flag;
}

/// True once the scheduler would actually switch on a tick (enabled AND at
/// least two runnable tasks). The tick() guard; hoisted so host tests can pin
/// it. The idle task counts, so a booted pool is always active.
pub fn scheduling_active() bool {
    if (!enabled_flag) return false;
    var runnable: usize = 0;
    for (tasks[0..max_tasks]) |task| {
        if (task.state == .ready or task.state == .running) runnable += 1;
    }
    return runnable >= 2;
}

/// Build the synthetic claim-9746 vector frame at the top of `stack` and
/// return its base pointer (the SP the stub restores from). Layout matches
/// the stub's save order exactly: x30 sits at the top (popped first), then
/// x16/x17 ... x0/x1 at the bottom; every slot zeroed except x30. The
/// FP/SIMD block (q0..q31, `exceptions.fp_save_bytes`) that the shared
/// `exc_fp_common` pushes below the GPR frame at every exception is
/// reserved and zeroed beneath it, so the restore macro's `sub sp, x0,
/// #fp_save_bytes` + FP pops land in valid zeros when a fresh task is
/// first scheduled.
pub fn build_initial_frame(stack: []u8, entry: u64) u64 {
    _ = entry; // ELR carries the entry; the frame only needs x30 = park
    const frame = stack[stack.len - frame_bytes ..];
    @memset(frame, 0);
    const park_addr = @intFromPtr(&park);
    std.mem.writeInt(u64, frame[0..8], park_addr, .little);
    const fp_block = stack[stack.len - frame_bytes - @as(usize, exceptions.fp_save_bytes) .. stack.len - frame_bytes];
    @memset(fp_block, 0);
    return @intFromPtr(frame.ptr);
}

/// What a task's entry `ret`s to if it ever returns: park forever. Also
/// the x30 slot of every synthetic initial frame (belt and suspenders —
/// the worker never returns). WFE on aarch64, nop elsewhere (host tests).
pub fn park() noreturn {
    while (true) {
        if (comptime builtin.cpu.arch == .aarch64) {
            asm volatile ("wfe");
        } else {
            asm volatile ("nop");
        }
    }
}

// ---------------------------------------------------------------------------
// The switch (IRQ context — no console, no allocation)
// ---------------------------------------------------------------------------

/// Pure context-switch core (host-testable): save the preempted task's
/// frame pointer + ELR/SPSR into its TCB, advance round-robin, and stage
/// the next task's frame pointer + ELR/SPSR for `tick` to apply. No asm,
/// no SP manipulation: the actual register restore happens in the
/// claim-9746 stub (`mov sp, x0` + pop + `eret`) using the staged frame.
/// Pick the next runnable task after `after` on behalf of core `cid`.
/// Core 0 may pick any ready task on its own ring and any steal-eligible
/// task parked on another ring (issue #857); secondary cores may pick
/// only `secondary_ok` tasks off foreign rings — never
/// the shell (console owner) and never the shared idle slot (core 0's
/// reaper — one frame, one owner).
/// May core `c` pull `cand` off a FOREIGN ring (another core's parked
/// work)? The same filters the old shared scan applied for `cid != 0` on
/// ring 0: never the shell or the core-0 idle reaper, only
/// `secondary_ok` tasks, and never a task pinned to another core.
fn steal_eligible(c: usize, cand: usize) bool {
    if (cand == 0 or cand == idle_id) return false;
    if (!tasks[cand].secondary_ok) return false;
    if (tasks[cand].pin_core != 0 and tasks[cand].pin_core != c) return false;
    return true;
}

fn frame_claimable(c: usize, id: usize) bool {
    return (@atomicLoad(u64, &tasks[id].exception_guard, .acquire) & 1) == 0 or exception_owner[c] == id;
}

const MergedPick = struct { id: usize, from: usize };

/// Caller holds all rotation locks. Eligibility is exactly the existing
/// own-ring/steal rule; a pinned or running foreign task cannot suppress the
/// worker on this core.
fn ready_user_for(c: usize) bool {
    for (&ready_rings, 0..) |*ring, r| {
        for (ring.members[0..ring.count]) |id| {
            if (r != c and !steal_eligible(c, id)) continue;
            if (!frame_claimable(c, id)) continue;
            if ((tasks[id].spsr & 0xf) == spsr_el0t_irqs) return true;
        }
    }
    return false;
}

/// The successor after slot `after` on core `c`, over the SLOT-MERGED
/// view of EVERY core's ring. Every `.ready` task the old shared scan
/// could see lives on exactly one ring, so merging all rings in slot
/// order reproduces the pre-ring round-robin exactly (the host tests pin
/// that order — e.g. a pinned task at slot 2 sits between a worker at
/// slot 1 and the idle fallback at slot 10, whichever ring holds it).
/// Own-ring (`from == c`) members are eligible for core `c` by
/// construction; FOREIGN-ring members pass `steal_eligible` — never the
/// shell or the core-0 idle reaper, only `secondary_ok` tasks, never a
/// task pinned to another core. That filter is what makes the migration
/// safe: core 0 can now pull a task preempted onto ring 1..3, and a
/// secondary can pull from another secondary's ring, while pinned tasks
/// never leave their ring (issue #857). The scan is cyclic: members at
/// or before `after` are reached only at the wrap (the old scan's
/// re-pick of the preempted task itself).
fn merged_next(c: usize, after: usize) ?MergedPick {
    const user_ready = ready_user_for(c);
    // All rings, n <= max_cores * max_tasks: collect + insertion sort by
    // slot. Rings of offline cores are always empty, so they contribute
    // nothing — no online-gating needed.
    var merged: [smp.max_cores * max_tasks]MergedPick = undefined;
    var n: usize = 0;
    var r: usize = 0;
    while (r < smp.max_cores) : (r += 1) {
        const ring = &ready_rings[r];
        var j: usize = 0;
        while (j < ring.count) : (j += 1) {
            merged[n] = .{ .id = ring.members[j], .from = r };
            n += 1;
        }
    }
    if (n == 0) return null;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const key = merged[i];
        var k = i;
        while (k > 0 and merged[k - 1].id > key.id) : (k -= 1) merged[k] = merged[k - 1];
        merged[k] = key;
    }
    var begin: usize = 0;
    while (begin < n and merged[begin].id <= after) begin += 1;
    var s: usize = 0;
    while (s < n) : (s += 1) {
        const cand = merged[(begin + s) % n];
        if (cand.from != c and !steal_eligible(c, cand.id)) continue;
        if (!frame_claimable(c, cand.id)) continue;
        if (user_ready and tasks[cand.id].demo_worker) continue;
        return cand;
    }
    return null;
}

/// The rotation pick on core `c` (claim): the slot-merged successor,
/// REMOVED from its source ring. Removal IS the claim — the task leaves
/// its ring, so no other core can ever select it. After a preemption
/// push the merged view is never empty (the preempted task itself is
/// reached at the wrap, preserving the old lone-task self-rotation).
pub fn ring_claim(c: usize, after: usize) ?usize {
    const p = merged_next(c, after) orelse return null;
    _ = ready_rings[p.from].remove(p.id);
    if (p.from != c) {
        // Issue #857 evidence: core c migrated a ready task off another
        // core's ring. BSS counters only (IRQ/svc safe — the same
        // discipline as `secondary_runs` in stage_selected); the shell
        // idle loop drains the lines in maybe_report.
        steal_runs +%= 1;
        const name = if (process.find_by_task(p.id)) |pid| process.info(pid).?.name else tasks[p.id].name;
        steal_last_task = name;
        steal_last_from = p.from;
        if (steal_run_names_count < steal_run_names.len) {
            steal_run_names[steal_run_names_count] = name;
            steal_run_froms[steal_run_names_count] = p.from;
            steal_run_names_count += 1;
        } else {
            std.mem.copyForwards([]const u8, steal_run_names[0 .. steal_run_names.len - 1], steal_run_names[1..]);
            steal_run_names[steal_run_names.len - 1] = name;
            std.mem.copyForwards(usize, steal_run_froms[0 .. steal_run_froms.len - 1], steal_run_froms[1..]);
            steal_run_froms[steal_run_froms.len - 1] = p.from;
        }
    }
    return p.id;
}

/// The test-facing / pre-check probe: what would `ring_claim` pick on
/// core `cid` after slot `after`, WITHOUT claiming it.
pub fn next_runnable_for(after: usize, cid: usize) ?usize {
    if (task_count == 0) return null;
    const p = merged_next(cid, after) orelse return null;
    return p.id;
}

/// Stage the claimed task `next` for core `c` (claim 6729): the
/// per-core pending_* restore image + the ready->running flip + the
/// counters. `current[c]` must already name `next`, and the caller must
/// hold the rotation ring locks (the flip completes the single-owner
/// claim — the task is off every ring, so only this core can observe
/// it, and the ring-lock acquire orders the prior owner's TCB writes).
/// Claim 881 slice 3: the kill conversion moved OUT of this function to
/// the claim sites (claim_and_stage / switch_context) — it runs the
/// full exit teardown, which must not happen under a ring lock (the
/// frozen lock-order rule).
fn stage_selected(c: usize, next: usize) void {
    pending_sp[c] = tasks[next].sp;
    pending_elr[c] = tasks[next].elr;
    pending_spsr[c] = tasks[next].spsr;
    pending_sp_el0[c] = tasks[next].sp_el0;
    pending_tls[c] = tasks[next].tls;
    pending_ttbr0[c] = tasks[next].ttbr0;
    // Claim 6729: the selected task is now the one that will execute.
    tasks[next].state = .running;
    tasks[next].resumes += 1;
    switches += 1;
    if (c != 0) {
        secondary_runs +%= 1; // SMP lift evidence: a secondary core took a task
        // Remember WHICH task for the evidence line (the process name when
        // there is one — the exec'd file name — else the task name). A
        // bounded ring keeps the name for every unprinted run (the drain
        // prints each one; a full ring drops the oldest — runs are per
        // tick, so 16 covers any real drain gap).
        if (process.find_by_task(next)) |pid|
            secondary_last_task = process.info(pid).?.name
        else
            secondary_last_task = tasks[next].name;
        if (secondary_run_names_count < secondary_run_names.len) {
            secondary_run_names[secondary_run_names_count] = secondary_last_task;
            secondary_run_names_count += 1;
        } else {
            std.mem.copyForwards([]const u8, secondary_run_names[0 .. secondary_run_names.len - 1], secondary_run_names[1..]);
            secondary_run_names[secondary_run_names.len - 1] = secondary_last_task;
        }
    }
}

/// The rotation's claim on core `c`: claim the successor after slot
/// `after` under the ring locks and stage it; a kill_pending selection
/// converts into the exit path (card 3c). Returns true when a successor
/// was staged or the conversion ran (the exit staged its own
/// successor); false when no successor exists (the caller parks or
/// rolls back).
fn claim_and_stage(c: usize, after: usize) bool {
    const lk = rotation_lock(c);
    const claimed = ring_claim(c, after);
    if (claimed == null) {
        rotation_unlock(lk);
        return false;
    }
    const next = claimed.?;
    current[c] = next;
    audit.slot(next, .tick);
    if (tasks[next].kill_pending) {
        convert_kill(c, lk, next);
        return true;
    }
    stage_selected(c, next);
    rotation_unlock(lk);
    return true;
}

/// Convert a kill_pending selection into the exit path (card 3c, claim
/// 7786): release the caller's ring locks, then exit the claimed task
/// with its reserved status — the full exit -> zombie -> idle-reap ->
/// page-return lifecycle runs and the exit path stages its own
/// successor, so the killed task never executes again. The teardown
/// needs EVERY service domain: try_take, never spin — a contended gate
/// defers the conversion one quantum (the task runs with kill_pending
/// still set and the next selection converts; the pre-slice-3
/// semantic). The caller must hold the rotation locks and have set
/// `current[c]` to the claimed task WITHOUT staging it.
fn convert_kill(c: usize, lk: RingLockPair, next: usize) void {
    // Ring locks come off FIRST (the frozen order: never a ring lock
    // across a svclock/sched_lock take).
    rotation_unlock(lk);
    if (!convert_pending_kill()) {
        // One more quantum: stage the task (it resumes with kill_pending
        // still set; the next selection converts).
        stage_selected(c, next);
    }
}

/// Shared selection/secondary-tick seam. No ring or scheduler lock may be
/// held. A non-prefix outer syscall hold defers rather than taking an earlier
/// service domain out of order; the next IRQ runs after that hold is released.
/// exit_current_locked consumes the request only at its validated zombie mark.
pub fn convert_pending_kill() bool {
    const id = current[smp.core_id()];
    if (!tasks[id].kill_pending) return false;
    if (!svclock.file.held() and (svclock.net.held() or svclock.win.held() or svclock.ev.held() or svclock.kernel.held())) return false;
    if (!svclock.net.held() and (svclock.win.held() or svclock.ev.held() or svclock.kernel.held())) return false;
    if (!svclock.win.held() and (svclock.ev.held() or svclock.kernel.held())) return false;
    if (!svclock.ev.held() and svclock.kernel.held()) return false;
    const taken = svclock.try_take(svclock.all_bits) orelse return false;
    defer svclock.release_set(taken);
    return exit_current_locked(tasks[id].kill_pending_status, true);
}

pub fn switch_context(frame_sp: u64, elr: u64, spsr: u64, sp_el0: u64) void {
    if (task_count == 0) return;
    const c = smp.core_id(); // per-core current
    // Claim 881 slice 3: the rotation holds ONLY the ring locks (all of
    // them, ascending — the issue-857 generalized steal scans every
    // ring). No sched_lock — a core-1 exit teardown or reap on another
    // core can never stall this save/pick/stage (the claim-9498 live
    // flake this slice fixes).
    const lk = rotation_lock(c);
    tasks[current[c]].sp = frame_sp;
    tasks[current[c]].elr = elr;
    tasks[current[c]].spsr = spsr;
    tasks[current[c]].sp_el0 = sp_el0;
    save_tls(current[c]);
    tasks[current[c]].saves += 1;
    // Claim 881 slice 2: the preempted task returns to its own core's
    // ring. Executing tasks are off-ring; joining here is the transition
    // back to runnable. The boot shell executes while `.ready` (off-ring)
    // — its first real preemption joins it like any other task.
    if (tasks[current[c]].state == .running) tasks[current[c]].state = .ready;
    ready_rings[c].push(current[c]);
    // Pick the successor over the slot-merged view of every ring (the
    // issue-857 steal: foreign-ring work migrates here). After the push
    // the own ring is never empty — the preempted task itself is reached
    // at the wrap, preserving the old lone-task self-rotation (saves /
    // resumes / switches all advance, `secondary_runs` included).
    const next = ring_claim(c, current[c]) orelse {
        rotation_unlock(lk); // defensive — the push makes this unreachable
        return;
    };
    current[c] = next;
    // Claim 9094 (#810): validate the slot BEFORE the kill_pending read
    // (Task+0x178 — the exact byte read that faulted in run-11 boot 2).
    audit.slot(next, .tick);
    if (tasks[next].kill_pending) {
        // Card 3c (claim 7786): a selected task with a pending kill is NOT
        // resumed — the selection converts into the exit path with the
        // reserved status. `convert_kill` drops the ring locks first (the
        // frozen lock-order rule: never a ring lock across a svclock /
        // sched_lock take).
        convert_kill(c, lk, next);
        return;
    }
    stage_selected(c, next);
    rotation_unlock(lk);
}

fn apply_pending() void {
    const c = smp.core_id(); // per-core staging: the core that staged it
    exceptions.resume_frame[c] = pending_sp[c];
    exceptions.resume_sp_el0[c] = pending_sp_el0[c];
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    // Claim 5804: install the selected task's TTBR0 (with a full TLB
    // invalidation) before restoring its ELR/SPSR, so the eret to EL0 (or
    // the resumed EL1h instruction stream) sees the task's own user space.
    mmu.set_ttbr0(pending_ttbr0[c]);
    asm volatile ("msr tpidr_el0, %[v]"
        :
        : [v] "r" (pending_tls[c]),
        : .{ .memory = true });
    asm volatile ("msr elr_el1, %[v]"
        :
        : [v] "r" (pending_elr[c]),
    );
    asm volatile ("msr spsr_el1, %[v]"
        :
        : [v] "r" (pending_spsr[c]),
    );
    asm volatile ("isb");
}

fn current_exception_pc() struct { elr: u64, spsr: u64 } {
    const c = smp.core_id(); // per-core current
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) {
        return .{ .elr = tasks[current[c]].elr, .spsr = tasks[current[c]].spsr };
    }
    var elr: u64 = 0;
    var spsr: u64 = 0;
    asm volatile ("mrs %[v], elr_el1"
        : [v] "=r" (elr),
    );
    asm volatile ("mrs %[v], spsr_el1"
        : [v] "=r" (spsr),
    );
    return .{ .elr = elr, .spsr = spsr };
}

/// Cooperative syscall yield. The interrupted SVC frame is saved exactly as
/// an IRQ frame would be, then another runnable task is staged for `eret`.
pub fn yield_current() bool {
    if (!scheduling_active()) return false;
    const c = smp.core_id(); // per-core current
    const pc = current_exception_pc();
    // Claim 881 slice 3: the rotation takes the ring locks itself inside
    // switch_context — no sched_lock here.
    switch_context(exceptions.resume_frame[c], pc.elr, pc.spsr, exceptions.resume_sp_el0[c]);
    cooperative_yields +%= 1;
    apply_pending();
    return true;
}

/// Claim 0635: block the calling task until `ticks` scheduler ticks have
/// passed, then stage its successor. The saved SVC frame stays on the
/// task's kernel stack while blocked; `wake_expired` flips the task back to
/// `ready` and the round-robin resumes it from that same frame, so the
/// syscall return (x0 = 0) lands when it wakes — the identical resume path
/// as `sys_yield`. `ticks == 0` is clamped to 1 (the minimum sleep is one
/// tick, matching the 1 s timer period). Returns false (EINVAL) for the
/// idle task or an inactive/rolled-back pool.
pub fn sleep_current(ticks: u64) bool {
    const c = smp.core_id(); // per-core current
    if (!scheduling_active() or task_count == 0 or current[c] == idle_id) return false;
    const duration = if (ticks == 0) 1 else ticks;
    const deadline = std.math.add(u64, tick_count, duration) catch return false;
    const sleeping = current[c];
    const name = tasks[sleeping].name;
    // Brief sched_lock: the TCB block-write (state + wakeup_tick) must be
    // atomic against wake_expired's scan. Released before the successor
    // rotation — the claim holds only the ring locks (claim 881 slice 3).
    sched_lock_acquire();
    if (tasks[sleeping].state != .ready and tasks[sleeping].state != .running) {
        sched_lock_release();
        return false;
    }
    // Save the calling task's context (frame SP + ELR/SPSR + SP_EL0), the
    // same seam yield_current uses — the task MUST find its saved SVC frame
    // intact when wake_expired flips it back to ready and the ring resumes
    // it. Unlike exit_current, which never resumes the saved context.
    const pc = current_exception_pc();
    tasks[sleeping].sp = exceptions.resume_frame[c];
    tasks[sleeping].elr = pc.elr;
    tasks[sleeping].spsr = pc.spsr;
    tasks[sleeping].sp_el0 = exceptions.resume_sp_el0[c];
    save_tls(sleeping);
    tasks[sleeping].saves += 1;
    // Claim 881 slice 2: blocking drops the task's ring membership (it is
    // current and off-ring by construction — the remove is defensive for
    // the manual-`current` host-test paths). It wakes onto its home ring.
    _ = ring_remove_anywhere(sleeping);
    tasks[sleeping].state = .blocked;
    tasks[sleeping].wakeup_tick = deadline;
    sched_lock_release();
    if (!claim_and_stage(c, sleeping)) {
        // A secondary core with no eligible successor parks on its WFE
        // loop; the sleeping task stays blocked for core 0's tick to wake.
        if (stage_secondary_park(c)) return true;
        // No successor: roll back (the always-ready idle task makes this
        // unreachable in a normal boot; kept as a defensive bound).
        sched_lock_acquire();
        tasks[sleeping].state = .ready;
        tasks[sleeping].wakeup_tick = 0;
        tasks[sleeping].saves -%= 1;
        sched_lock_release();
        return false;
    }
    sleep_report_pending = true;
    sleep_report_name = name;
    sleep_report_ticks = duration;
    apply_pending();
    return true;
}

/// Card 4c (claim 9946): block the calling task until the PROCESS with id
/// `target_pid` exits, then stage its successor. The same seam as
/// `sleep_current` — the caller's saved SVC frame stays on its kernel
/// stack while blocked, and `wake_waiters` flips the task back to `ready`
/// the moment the target exits (the round-robin then resumes it from that
/// same frame). The exit status is unknowable at block time, so the wake
/// patches it into the saved frame's x0; the syscall return lands with the
/// status when the caller resumes. Returns false (EINVAL) for the idle
/// task or an inactive/rolled-back pool.
pub fn wait_current(target_pid: usize) bool {
    const c = smp.core_id(); // per-core current
    if (!scheduling_active() or task_count == 0 or current[c] == idle_id) return false;
    const waiting = current[c];
    // Brief sched_lock: the TCB block-write must be atomic against the
    // wake scans; released before the successor rotation (claim 881
    // slice 3).
    sched_lock_acquire();
    if (tasks[waiting].state != .ready and tasks[waiting].state != .running) {
        sched_lock_release();
        return false;
    }
    const pc = current_exception_pc();
    // Save the calling task's context (frame SP + ELR/SPSR + SP_EL0), the
    // same seam yield_current/sleep_current use — the task MUST find its
    // saved SVC frame intact when the target exits and the ring resumes it.
    tasks[waiting].sp = exceptions.resume_frame[c];
    tasks[waiting].elr = pc.elr;
    tasks[waiting].spsr = pc.spsr;
    tasks[waiting].sp_el0 = exceptions.resume_sp_el0[c];
    save_tls(waiting);
    tasks[waiting].saves += 1;
    _ = ring_remove_anywhere(waiting); // defensive (current is off-ring)
    tasks[waiting].state = .blocked;
    tasks[waiting].wait_pid = target_pid;
    sched_lock_release();
    if (!claim_and_stage(c, waiting)) {
        // A secondary core with no eligible successor parks on its WFE
        // loop; the waiting task stays blocked until the target exits.
        if (stage_secondary_park(c)) return true;
        // No successor: roll back (the always-ready idle task makes this
        // unreachable in a normal boot; kept as a defensive bound).
        sched_lock_acquire();
        tasks[waiting].state = .ready;
        tasks[waiting].wait_pid = null;
        tasks[waiting].saves -%= 1;
        sched_lock_release();
        return false;
    }
    apply_pending();
    return true;
}

/// ADR 0027 D3 (issue #1214 round 2): create a THREAD task of the CALLER's
/// process — `sys_thread` op 0. The new task shares the caller's process
/// (same TTBR0 root, principal, mailbox), starts with pc=`entry`, x0=`arg`,
/// SP_EL0=`stack_hi` (a caller-provided EL0 stack — Go passes
/// `mp.g0.stack.hi`), and a COPY of the caller's uaccess TCB regions (new
/// Ms syscall — sys_write/mmap/futex — and must see the same regions).
/// Unpinned: SMP placement follows the unpinned exec rule (claim 9498).
/// The task NAME is the process name so the monitor `smp` report and fault
/// lines attribute threads to their program. Returns the new kernel tid
/// (Go stores it in `m.procid`); null when the pool or thread bound is
/// exhausted or the kstack allocation fails.
pub fn spawn_thread(
    caller_task: usize,
    entry: u64,
    stack_hi: u64,
    arg: u64,
) ?usize {
    return spawn_thread_context(caller_task, entry, stack_hi, arg, 0);
}

pub fn spawn_tls_thread(caller: usize, entry: u64, stack: u64, arg: u64, tls: u64) ?u64 {
    const id = spawn_thread_context(caller, entry, stack, arg, tls) orelse return null;
    return tasks[id].join_token;
}

fn spawn_thread_context(caller_task: usize, entry: u64, stack_hi: u64, arg: u64, tls: u64) ?usize {
    if (caller_task >= max_tasks) return null;
    const pid = process.find_by_task(caller_task) orelse return null;
    const pinfo = process.info(pid) orelse return null;
    if (pinfo.state != .running) return null;
    if (!process.has_thread_capacity(pid)) return null;
    if (stack_hi == 0 or (stack_hi & 0xf) != 0) return null;
    const kstack_pages: u64 = (task_stack_size + alloc.page_size - 1) / alloc.page_size;
    const kstack_phys = alloc.alloc_pages(kstack_pages) orelse return null;
    const kstack: []u8 = @as([*]u8, @ptrFromInt(kstack_phys))[0..task_stack_size];
    const name = pinfo.name;
    // The whole build is one sched_lock hold: the task stays off-ring
    // (`.blocked`, unpublished) until its TCB fields, region copy, and
    // process bind are all in place — no core can select a half-built
    // thread, and the undo path mutates the pool under the same lock.
    sched_lock_acquire();
    // The allocation can race an arming scan. Check at publication, under
    // that same lock, even when the original requesting task was reaped.
    if (process_exit_tick[pid] != null or process.find_by_task(caller_task) != pid or
        (tasks[caller_task].state != .ready and tasks[caller_task].state != .running))
    {
        sched_lock_release();
        _ = alloc.free_pages(kstack_phys, kstack_pages);
        return null;
    }
    var charged: usize = 0;
    for (tasks, 0..) |task, tid| {
        if ((task.join_token != 0 and task.join_pid == pid) or
            (task.is_thread and process.find_by_task(tid) == pid)) charged += 1;
    }
    if (charged >= process.max_threads or (tls != 0 and next_join_token == std.math.maxInt(i64))) {
        sched_lock_release();
        _ = alloc.free_pages(kstack_phys, kstack_pages);
        return null;
    }
    const id = alloc_task_locked(name, entry, spsr_el0t_irqs, kstack, pinfo.root_phys, stack_hi) orelse {
        sched_lock_release();
        _ = alloc.free_pages(kstack_phys, kstack_pages);
        return null;
    };
    _ = exceptions.frame_write(@ptrFromInt(tasks[id].sp), 0, arg);
    // Native join/reap runs on core 0: its idle reaper cannot reclaim a
    // child's exception stack while that child's exit stub still uses it.
    // Legacy detached Go threads keep their existing any-core placement.
    tasks[id].secondary_ok = tls == 0;
    tasks[id].is_thread = true;
    tasks[id].thread_kstack_phys = kstack_phys;
    tasks[id].thread_kstack_pages = kstack_pages;
    tasks[id].tls = tls;
    // Exec shapes only; process-scope mmap regions are merged at arm time
    // (ADR 0027 review finding 2).
    tasks[id].regions = tasks[caller_task].regions;
    if (!process.bind_thread(pid, id)) {
        // The descriptor bound is full or racing: undo under the lock.
        tasks[id] = .{};
        task_count -%= 1;
        sched_lock_release();
        _ = alloc.free_pages(kstack_phys, kstack_pages);
        return null;
    }
    if (tls != 0) {
        tasks[id].join_pid = pid;
        tasks[id].join_token = next_join_token;
        next_join_token += 1;
    }
    tasks[id].state = .ready;
    push_home_locked(id);
    sched_lock_release();
    return id;
}

/// One joiner, same process, no detach or cycles. Completion is published
/// only after exit teardown. The token is consumed exactly once.
pub fn join_thread(pid: usize, token: u64) ?u64 {
    const c = smp.core_id();
    const caller = current[c];
    if (!scheduling_active() or caller == idle_id) return null;
    sched_lock_acquire();
    var target: ?usize = null;
    for (tasks, 0..) |task, id| {
        if (token >= max_tasks and task.join_token == token and task.join_pid == pid) target = id;
    }
    const id = target orelse {
        sched_lock_release();
        return null;
    };
    if (id == caller or tasks[id].joiner != null or tasks[caller].wait_thread or tasks[caller].joiner != null) {
        sched_lock_release();
        return null;
    }
    if (tasks[id].state == .zombie and !tasks[id].teardown_pending) {
        const status = tasks[id].exit_status;
        tasks[id].join_token = 0;
        sched_lock_release();
        return status;
    }
    // Joining a joiner would create an unsupported dependency chain.
    if (tasks[id].wait_thread) {
        sched_lock_release();
        return null;
    }
    const pc = current_exception_pc();
    tasks[caller].sp = exceptions.resume_frame[c];
    tasks[caller].elr = pc.elr;
    tasks[caller].spsr = pc.spsr;
    tasks[caller].sp_el0 = exceptions.resume_sp_el0[c];
    save_tls(caller);
    tasks[caller].wait_thread = true;
    tasks[caller].state = .blocked;
    tasks[id].joiner = caller;
    _ = ring_remove_anywhere(caller);
    sched_lock_release();
    if (!claim_and_stage(c, caller)) {
        if (stage_secondary_park(c)) return 0;
        sched_lock_acquire();
        tasks[id].joiner = null;
        tasks[caller].wait_thread = false;
        tasks[caller].state = .running;
        sched_lock_release();
        return null;
    }
    apply_pending();
    return exceptions.frame_read(@ptrFromInt(tasks[caller].sp), 0);
}

/// ADR 0027 D4 + review finding 1: block the calling task in `sys_futex`
/// op 0. The syscall layer runs a fast-path compare under the caller's
/// uaccess window, but the authoritative re-check runs HERE — after the
/// `(pid, uaddr)` seat is visible and still under sched_lock — closing the
/// lost-wake window where a peer's store + wake lands between the fast
/// compare and the seat insertion (the wake would find no waiter and
/// `semasleep(-1)` would park forever). `word_matches` reads the 4-byte
/// word through the same uaccess window; the callback keeps uaccess out of
/// the scheduler. Returns `.blocked` on a real park (the waker/timeout
/// patches the saved frame's x0), `.word_changed` when the re-check failed
/// (the caller returns EAGAIN), and `.unavailable` for an inactive
/// scheduler, a bad task state, a full seat table, or no successor (also
/// EAGAIN — transient; the caller re-reads).
pub const FutexWaitOutcome = enum { blocked, word_changed, unavailable };

pub fn futex_wait_current(
    pid: usize,
    uaddr: u64,
    val: u32,
    deadline_tick: u64,
    word_matches: *const fn (uaddr: u64, val: u32) bool,
) FutexWaitOutcome {
    const c = smp.core_id();
    if (!scheduling_active() or task_count == 0 or current[c] == idle_id) return .unavailable;
    const waiting = current[c];
    // Seat the (pid, uaddr) entry BEFORE blocking — a waker on another core
    // (or the tick, for a deadline already in the past) must find it.
    sched_lock_acquire();
    var seat: ?*FutexEntry = null;
    for (&futex_table) |*e| {
        if (!e.used) {
            seat = e;
            break;
        }
    }
    const entry = seat orelse {
        sched_lock_release();
        return .unavailable;
    };
    if (tasks[waiting].state != .ready and tasks[waiting].state != .running) {
        sched_lock_release();
        return .unavailable;
    }
    entry.* = .{ .used = true, .pid = pid, .uaddr = uaddr, .task = waiting };
    tasks[waiting].futex_waiting = true;
    // Finding 1: re-check AFTER the seat is visible, under the same lock
    // the waker takes. A peer that stored the word and called wake before
    // this point either found the seat (and will wake us) or its store is
    // visible to this read (and we bail to the caller's re-read).
    if (!word_matches(uaddr, val)) {
        futex_entry_clear(entry);
        sched_lock_release();
        return .word_changed;
    }
    const pc = current_exception_pc();
    tasks[waiting].sp = exceptions.resume_frame[c];
    tasks[waiting].elr = pc.elr;
    tasks[waiting].spsr = pc.spsr;
    tasks[waiting].sp_el0 = exceptions.resume_sp_el0[c];
    save_tls(waiting);
    tasks[waiting].saves += 1;
    _ = ring_remove_anywhere(waiting);
    tasks[waiting].state = .blocked;
    tasks[waiting].wakeup_tick = deadline_tick;
    sched_lock_release();
    if (!claim_and_stage(c, waiting)) {
        if (stage_secondary_park(c)) return .blocked;
        // No successor: roll back (the always-ready idle task makes this
        // unreachable in a normal boot; kept as a defensive bound).
        sched_lock_acquire();
        tasks[waiting].state = .ready;
        tasks[waiting].futex_waiting = false;
        tasks[waiting].wakeup_tick = 0;
        tasks[waiting].saves -%= 1;
        futex_entry_clear(entry);
        sched_lock_release();
        return .unavailable;
    }
    apply_pending();
    return .blocked;
}

/// ADR 0027 D4: `sys_futex` op 1 — wake up to `n` waiters of THIS process
/// keyed (pid, uaddr). Returns the number woken.
pub fn futex_wake(pid: usize, uaddr: u64, n: usize) usize {
    sched_lock_acquire();
    defer sched_lock_release();
    return futex_wake_locked(pid, uaddr, n, 0);
}

/// Milestone 9 (claim 1016): block the calling task until an application event
/// arrives for process `pid`, then stage its successor. Rewinds ELR by 4
/// so when the task wakes up, it re-executes `svc #0` under its own context.
pub fn wait_event_current(pid: usize) bool {
    const c = smp.core_id(); // per-core current
    if (!scheduling_active() or task_count == 0 or current[c] == idle_id) return false;
    const waiting = current[c];
    // Brief sched_lock: the TCB block-write must be atomic against the
    // wake scans; released before the successor rotation (claim 881
    // slice 3).
    sched_lock_acquire();
    if (tasks[waiting].state != .ready and tasks[waiting].state != .running) {
        sched_lock_release();
        return false;
    }
    const pc = current_exception_pc();
    tasks[waiting].sp = exceptions.resume_frame[c];
    tasks[waiting].elr = if (pc.elr >= 4) pc.elr - 4 else pc.elr;
    tasks[waiting].spsr = pc.spsr;
    tasks[waiting].sp_el0 = exceptions.resume_sp_el0[c];
    tasks[waiting].saves += 1;
    save_tls(waiting);
    _ = ring_remove_anywhere(waiting); // defensive (current is off-ring)
    tasks[waiting].state = .blocked;
    tasks[waiting].wait_event_pid = pid;
    // Claim 6359 (wait_event fix): stash the re-executed svc's first
    // argument (the event-buffer address) BEFORE the syscall layer writes
    // the blocking result (0) into the saved frame's x0 — the elr-4
    // re-execution must see the original x0, or the wake's copy_out
    // targets address 0 (EFAULT) and every blocking GUI event loop dies.
    const saved_frame: *const exceptions.VectorFrame = @ptrFromInt(exceptions.resume_frame[c]);
    tasks[waiting].wait_event_buf = exceptions.frame_read(saved_frame, 0);
    sched_lock_release();
    if (!claim_and_stage(c, waiting)) {
        // A secondary core with no eligible successor parks on its WFE
        // loop; the waiting task stays blocked until the event arrives.
        if (stage_secondary_park(c)) return true;
        sched_lock_acquire();
        tasks[waiting].state = .ready;
        tasks[waiting].wait_event_pid = null;
        tasks[waiting].wait_event_buf = 0;
        tasks[waiting].saves -%= 1;
        sched_lock_release();
        return false;
    }
    apply_pending();
    return true;
}

/// Milestone 9 (claim 1016): wake any task blocked in `sys_wait_event` for `pid`.
pub fn wake_event_waiters(pid: usize) void {
    // The events.push hook fires from SVC contexts AND from inside
    // sched_lock-held teardown (exit_current's close_owner pushes
    // WIN_CLOSE events) — same-core reentry must not re-lock.
    const already_held = sched_lock_holder == smp.core_id();
    if (!already_held) sched_lock_acquire();
    defer if (!already_held) sched_lock_release();
    var i: usize = 0;
    while (i < max_tasks) : (i += 1) {
        if (tasks[i].state != .blocked) continue;
        if (tasks[i].wait_event_pid != pid) continue;
        // Claim 6359 (wait_event fix): restore the re-executed svc's x0
        // (the event-buffer address) into the saved frame — the blocking
        // result write clobbered it with 0 at block time.
        const frame: *exceptions.VectorFrame = @ptrFromInt(tasks[i].sp);
        _ = exceptions.frame_write(frame, 0, tasks[i].wait_event_buf);
        tasks[i].wait_event_buf = 0;
        tasks[i].state = .ready;
        tasks[i].wait_event_pid = null;
        // Claim 881 slice 2: the woken task joins its home ring (ring 0
        // unless pinned). Slice 3: the push takes the home ring's lock
        // (ring locks are the innermost — we hold sched_lock here).
        push_home_locked(i);
    }
}

/// Card 4c (claim 9946): the target process just exited with `status` —
/// every task blocked in `sys_wait` on pid `pid` returns to `ready` and
/// its saved SVC frame's x0 is patched with the observed status (the
/// syscall result `handle_wait` could not know at block time). Called from
/// the EXIT path (`exit_current`, right after the registry records the
/// exit) — pure TCB + saved-frame writes, safe in the exception context
/// (no console, no allocation). Multiple waiters on one pid all wake with
/// the same status; a blocked waiter can never outlive its target (a
/// process is only reaped AFTER it exits, which wakes the waiter first).
fn wake_waiters(pid: usize, status: u64) void {
    // Claim 881 slice 3: called from the exit TEARDOWN, which no longer
    // holds sched_lock (the teardown runs under the service-domain locks
    // only) — take the brief scan lock here. Ring pushes take the home
    // ring's lock (innermost).
    sched_lock_acquire();
    defer sched_lock_release();
    var i: usize = 0;
    while (i < max_tasks) : (i += 1) {
        if (tasks[i].state != .blocked) continue;
        if (tasks[i].wait_pid != pid) continue;
        tasks[i].state = .ready;
        tasks[i].wait_pid = null;
        const frame: *exceptions.VectorFrame = @ptrFromInt(tasks[i].sp);
        _ = exceptions.frame_write(frame, 0, status);
        push_home_locked(i);
    }
}

/// Claim 0635: timer-driven wakeups. Called once per tick (IRQ context,
/// console-free — claim 9187) AFTER the tick counter advanced: every
/// `blocked` task whose deadline has passed returns to `ready` and is
/// picked up by the ring on the next round. A no-op when nothing sleeps.
fn wake_expired() void {
    var i: usize = 0;
    while (i < max_tasks) : (i += 1) {
        if (tasks[i].state != .blocked) continue;
        // #1978: an armed task can block after the sibling scan, including
        // after a contended conversion resumed it. Kill takes precedence
        // over EVERY wait shape, not just deadlines. One timekeeping beat
        // restores ring eligibility; selection converts before EL0 resumes
        // when service locks are free. Never return an error to an infinite
        // waiter and leave it executing/re-blocking off-ring.
        if (tasks[i].kill_pending) {
            wake_killed_task_locked(i);
            continue;
        }
        // Card 4c / Card E5: event-blocked tasks (`sys_wait` / `sys_wait_event` —
        // no deadline) are woken by their event hooks, never by the tick clock.
        if (tasks[i].wait_pid != null or tasks[i].wait_event_pid != null or tasks[i].wait_thread) continue;
        if (tasks[i].futex_waiting and tasks[i].wakeup_tick == 0) continue; // wait forever
        if (tick_count < tasks[i].wakeup_tick) continue;
        // ADR 0027 D4: an expired FUTEX deadline is a TIMED-OUT wait — the
        // syscall returns -ETIMEDOUT (a distinct negative from a real wake,
        // which futex_wake_locked patches as 0) and the seat clears.
        if (tasks[i].futex_waiting) {
            for (&futex_table) |*e| {
                if (e.used and e.task == i) {
                    const tid = e.task;
                    futex_entry_clear(e);
                    if (tid < max_tasks and tasks[tid].state == .blocked) {
                        tasks[tid].state = .ready;
                        const frame: *exceptions.VectorFrame = @ptrFromInt(tasks[tid].sp);
                        _ = exceptions.frame_write(frame, 0, futex_timed_out_result);
                        push_home_locked(tid);
                    }
                    break;
                }
            }
            continue;
        }
        tasks[i].state = .ready;
        tasks[i].wakeup_tick = 0;
        // Claim 881 slice 2: the woken task joins its home ring (ring 0
        // unless pinned; a pin ring's task is picked by that core's own
        // tick or its WFE steal). Slice 3: the push takes the home ring's
        // lock (we hold sched_lock via on_tick's caller).
        push_home_locked(i);
    }
}

fn wake_killed_task_locked(id: usize) void {
    _ = futex_clear_for(id);
    tasks[id].futex_waiting = false;
    tasks[id].wakeup_tick = 0;
    tasks[id].wait_pid = null;
    tasks[id].wait_event_pid = null;
    tasks[id].wait_event_buf = 0;
    tasks[id].wait_thread = false;
    for (&tasks) |*task| {
        if (task.joiner == id) task.joiner = null;
    }
    tasks[id].state = .ready;
    push_home_locked(id);
}

/// Snapshot under sched_lock; ring locks are innermost and released before
/// any service work. IRQ code only queues, maybe_report prints in main context.
fn diagnose_exit_requests_locked() void {
    for (&tasks, 0..) |*task, id| {
        if (task.state != .ready and task.state != .running and task.state != .blocked) continue;
        if (task.exit_kill_reported) continue;
        const pid = process.find_by_task(id) orelse continue;
        const since = process_exit_tick[pid] orelse continue;
        const age = tick_count -% since;
        if (age <= exit_kill_diagnostic_ticks) continue;
        var rings: u8 = 0;
        const lk = rotation_lock(smp.core_id());
        for (&ready_rings, 0..) |*ring, c| {
            if (ring.contains(id)) rings |= @as(u8, 1) << @intCast(c);
        }
        rotation_unlock(lk);
        if (exit_kill_report_count == max_tasks) {
            exit_kill_report_head = (exit_kill_report_head + 1) % max_tasks;
            exit_kill_report_count -= 1;
        }
        const tail = (exit_kill_report_head + exit_kill_report_count) % max_tasks;
        exit_kill_reports[tail] = .{
            .pid = pid,
            .task = id,
            .state = task.state,
            .kill_pending = task.kill_pending,
            .futex_waiting = task.futex_waiting,
            .wakeup_tick = task.wakeup_tick,
            .rings = rings,
            .age = age,
        };
        exit_kill_report_count += 1;
        task.exit_kill_reported = true;
    }
}

/// The ETIMEDOUT errno (ADR 0007 amendment) a futex wait reports on expiry —
/// the D4 contract: a timed-out wait is distinct from a real wake.
pub const futex_timed_out_result: u64 = @bitCast(@as(i64, -12));

/// Host-testable tick seam (mirrors `timer.on_tick`): advance the tick
/// counter and run the timer-driven wakeups. Called by the real `tick`
/// before preemption; host tests call it directly to drive sleepers.
pub fn on_tick() void {
    const c = smp.core_id(); // per-core current
    tick_count +%= 1;
    diagnose_exit_requests_locked();
    wake_expired();
    // Milestone 14 (claim 7323): count every armed app timer down and fire
    // the due ones (one TIMER event per process into its ADR 0009 queue,
    // which wakes a blocked sys_wait_event caller via on_event_pushed).
    app_timers.on_tick();
    // M32 WMS2 (issue #622): while a WM is registered, deliver one
    // COMPOSITE_TICK (kind 18) to the registrant's process queue — the
    // composite pacing moves OFF the shell idle to this tick path. A no-op
    // when no WM is registered (zero-regression: shim mode unchanged).
    wm_server.on_tick();
    // Arc5 issue #246: per-process CPU limit enforcement. Increment the
    // current process's tick counter; if the limit is exceeded, arm the
    // ring's kill conversion with status 141 (distinct from guard-page
    // 139). Claim 9498 follow-on: on_tick holds only the EV + kernel
    // subset, while the exit teardown needs the FULL domain set — exiting
    // synchronously here would require acquiring file/net/win out of
    // canonical order (a deadlock risk against a teardown holding them),
    // so the task converts at its next ring selection instead, one
    // quantum later.
    if (current[c] != idle_id and tasks[current[c]].state == .running) {
        if (process.find_by_task(current[c])) |pid| {
            if (process.inc_cpu_ticks(pid)) {
                tasks[current[c]].kill_pending = true;
                tasks[current[c]].kill_pending_status = reserved_cpu_limit_status;
            }
        }
    }
}

/// Remove the calling task from the runnable ring and stage its successor.
/// The SVC exception return consumes the staged frame, so the terminated task
/// never resumes after `sys_exit`. Claim 6729: the exiting task becomes a
/// ZOMBIE (its status is preserved for `terminated_status`); the idle task
/// reaps it later. The idle task itself can never be exited.
/// Ring-exit entry (sys_exit / fault / kill): lock, then exit the calling
/// task. Exception context is IRQ-masked, so spinning on `sched_lock` is
/// safe — a main-context holder (the idle reaper) is never starved because
/// its own preempting ticks `try_lock` and skip.
pub fn exit_current(status: u64) bool {
    // Service-domain locks (claim 9498 follow-on): the teardown below
    // (window close, shared-surface revoke, file/event/timer reset)
    // touches EVERY service domain — take the full set in canonical
    // order, FIRST, before any scheduler lock, everywhere. The sys_exit
    // dispatch already holds the full set (acquire_missing returns
    // nothing); the fault path does not.
    const taken = svclock.acquire_missing(svclock.all_bits);
    defer svclock.release_set(taken);
    return exit_current_locked(status, true);
}

/// ADR 0027 D2 (issue #1214 round 2): exit the calling task WITHOUT
/// requesting the process's death — `sys_thread` op 1. The process dies
/// only when its LAST task exits (via on_task_exit's live-task count);
/// every OTHER exit shape (sys_exit, fault, kill) requests the whole
/// process. Futex wake-on-thread-death applies to both shapes (D4).
pub fn exit_thread_current() bool {
    return exit_thread_status(0);
}

pub fn exit_thread_status(status: u64) bool {
    const taken = svclock.acquire_missing(svclock.all_bits);
    defer svclock.release_set(taken);
    return exit_current_locked(status, false);
}

/// Arm the kill conversion on every LIVE sibling task of `pid` (the
/// process-exit request path). Blocked siblings are force-woken to ready so
/// the conversion can happen at their next selection instead of parking
/// forever on a dead process. Caller holds `sched_lock`.
fn arm_sibling_kills_locked(pid: usize, except_task: usize) void {
    if (process_exit_tick[pid] == null) process_exit_tick[pid] = tick_count;
    var i: usize = 0;
    while (i < max_tasks) : (i += 1) {
        if (tasks[i].join_token != 0 and tasks[i].join_pid == pid) {
            tasks[i].join_token = 0;
            tasks[i].joiner = null;
        }
        if (i == except_task or i == idle_id) continue;
        if (process.find_by_task(i) != pid) continue;
        switch (tasks[i].state) {
            .ready, .running => {
                tasks[i].kill_pending = true;
            },
            .blocked => {
                // Review minor: clear the futex seat, not just the flag —
                // a leaked seat can fill the bounded table across several
                // sibling deaths and fail a later wait. No wake: every
                // same-process peer is being killed here anyway.
                tasks[i].kill_pending = true;
                wake_killed_task_locked(i);
            },
            else => {},
        }
    }
}

/// Ring-exit core: mark the calling task zombie, run the teardown under
/// the service-domain locks ONLY, and stage the successor under the ring
/// locks. sched_lock spans just the zombie mark + the exit report (brief)
/// and the teardown-complete gate — the long work (tombstone write,
/// window/surface/file/event/timer reset, wake scans) never holds it, so
/// a core-1 exit can no longer stall core-0's rotation (the claim-9498
/// live flake this slice fixes). Callers hold every service-domain bit
/// (exit_current's acquire_missing; the kill conversions' try_take) and
/// NO sched_lock. `process_exit` selects the ADR 0027 D2 shape: true
/// (sys_exit/fault/kill) requests the WHOLE process and arms sibling
/// kills; false (sys_thread op 1) tears down only this task.
fn exit_current_locked(status: u64, process_exit: bool) bool {
    const c = smp.core_id(); // per-core current
    // Brief sched_lock: validate, the zombie mark, and the exit report.
    // The mark must be atomic against the idle reaper's scan, and
    // `teardown_pending` gates the slot against the reaper until the
    // teardown below completes.
    sched_lock_acquire();
    if (task_count == 0 or current[c] == idle_id) {
        sched_lock_release();
        return false;
    }
    if (tasks[current[c]].state != .ready and tasks[current[c]].state != .running) {
        sched_lock_release();
        return false;
    }
    const exiting = current[c];
    const name = tasks[exiting].name;
    const pending_kill = tasks[exiting].kill_pending;
    const pending_status = tasks[exiting].kill_pending_status;
    // Claim 881 slice 2: the exiting task leaves its ring (it is current
    // and off-ring by construction — the remove is defensive for the
    // manual-`current` host-test paths; the pre-ring world left a zombie
    // sitting in the pool until the reap).
    _ = ring_remove_anywhere(exiting);
    tasks[exiting].state = .zombie;
    tasks[exiting].kill_pending = false;
    tasks[exiting].kill_pending_status = reserved_kill_status;
    tasks[exiting].exit_status = status;
    tasks[exiting].teardown_pending = true;
    queue_exit_report(name, status);
    exits +%= 1;
    // ADR 0027 D4: a dying task leaves its futex seat with one wake on the
    // (pid, uaddr) — Go's exitThread contract expects the woken peer to
    // re-check the user word, which the wake enables.
    if (futex_clear_for(exiting)) |seat| {
        _ = futex_wake_locked(seat.pid, seat.uaddr, 1, 0);
    }
    // ADR 0027 D2: a process-exit request arms the live siblings' kill
    // conversion (and force-wakes blocked ones) so the process's tasks all
    // terminate instead of lingering on a dying address space.
    if (process_exit) {
        if (process.request_process_exit(exiting, status)) |pid| {
            arm_sibling_kills_locked(pid, exiting);
        }
    }
    sched_lock_release();
    // Arc5 issue #243: record a tombstone for fault exits (status 139)
    // or any non-zero unexpected exit. The tombstone is written to /data/crash/
    // on the DATA partition. Pure BSS writes, safe in this exception context.
    if (process_exit and (status == reserved_fault_status or (status != 0 and status != reserved_kill_status))) {
        // Get fault address + PC from the most recent fault report if
        // status is 139. M22 D3 (issue #326): the PC rides along so the
        // tombstone can resolve CODE symbols for BRK-style faults whose
        // FAR is meaningless.
        var fault_addr: u64 = 0;
        var fault_pc: u64 = 0;
        if (status == reserved_fault_status and fault_report_count > 0) {
            const last_fault_idx = (fault_report_head + fault_report_count - 1) % fault_report_max;
            fault_addr = fault_reports[last_fault_idx].far;
            fault_pc = fault_reports[last_fault_idx].pc;
        }
        // Use the process name if available, otherwise the task name
        const proc_name = if (process.find_by_task(exiting)) |pid|
            process.info(pid).?.name
        else
            name;
        const pid_val = if (process.find_by_task(exiting)) |pid| @as(u64, pid) else @as(u64, 0);
        // Capture the last 512 bytes of serial output for the tombstone.
        var serial_buf: [512]u8 = undefined;
        const serial_n = serial_ring.snapshot(&serial_buf);
        tombstone.record(proc_name, pid_val, status, fault_addr, fault_pc, serial_buf[0..serial_n], serial_n);
        // Arc5 issue #243: persist the tombstone to crash/ on the host
        // share. The write is a polled exchange on the file channel (no
        // allocation, no interrupt, no global-state conflict with the
        // exception context). M34 HF6 (issue #740): the DATA partition /
        // virtio-blk path is gone.
        if (virtio_file.available()) {
            _ = tombstone.write_to_disk(tombstone.get(tombstone.count() - 1).?);
        }
    }
    // Claim 3848: the exiting task's PROCESS (if any) becomes exited and
    // snapshots the status — the process-level exit report and `procs`
    // keep it after the slot is reaped. Pure registry writes, safe in the
    // exception context this runs in (no console, no allocation). Card 4c
    // (claim 9946): the returned pid wakes every task blocked in `sys_wait`
    // on this process — their saved frames get the observed status patched
    // into x0, so the syscall return lands when the ring resumes them.
    if (process.on_task_exit(exiting, status)) |pid| {
        // No live process remains to join retained completions.
        sched_lock_acquire();
        process_exit_tick[pid] = null;
        for (&tasks) |*task| {
            if (task.join_token != 0 and task.join_pid == pid) {
                task.join_token = 0;
                task.joiner = null;
            }
        }
        sched_lock_release();
        // M52 card 1 (#1238): EXIT-PATH INVENTORY — the pinned client-death
        // teardown order. This comment IS the inventory; the seam-level host
        // tests in kernel/tests/syscall_test.zig drive `exit_current` and pin
        // every entry. The order is load-bearing:
        //   1. wake_waiters(pid, status)         — sys_wait waiters observe the exit
        //   2. driving_award.close_owner(pid)    — no zombie window; focus falls
        //                                          back; the WM gets ONE released
        //                                          mirror so it drops the target
        //   3. shared_mmap.revoke_owner(pid)     — D2: owned regions revoke their
        //                                          peer RO seat BEFORE the reap
        //                                          unrefs the owner's pages (no
        //                                          peer aliasing freed physical PA)
        //   4. shared_mmap.revoke_peer_role(pid) — its own peer seats detach; the
        //                                          owner's surface survives (D1)
        //   5. file_table.reset_process(pid)
        //   6. tcp.close_owner(pid)
        //   7. app_timers.reset(pid)             — no stale fire at a recycled pid
        //   8. wm_server.unregister(pid)         — the WM seat, the scanout grant
        //                                          and the input handoff return to
        //                                          the shim (a client's death does
        //                                          NOT unregister the WM)
        // Audited in #1238 — deliberately NOT in the inventory:
        //   `events`/`mailbox` are not reset here. A task blocked in
        //   sys_wait_event always waits on its OWN pid (handle_wait_event
        //   derives the pid from the caller), so no live waiter can outlive
        //   its queue, and every creation path (exec_file_impl + the boot
        //   payload) resets both before a recycled pid can run again. The
        //   dying pid's queue may hold the WIN_CLOSE that step 2 pushes at it;
        //   nothing can read it. No `on_event_pushed` wake is owed either:
        //   that hook fires on `events.push`, and the exit path pushes no
        //   event any other process is blocked on.
        wake_waiters(pid, status);
        // Per-process window ownership: the exiting process's user windows
        // are released NOW (the real teardown semantic — no window leaks
        // until reboot). Pure BSS writes (registry compaction + dirty
        // marks), safe in this exception context.
        _ = driving_award.close_owner(pid);
        // M33 SB2 (claim 8878): the exiting process's shared surfaces die
        // with it. Regions it OWNED are revoked NOW — every peer RO leaf
        // unmapped and the descriptors dropped BEFORE the reap unrefs the
        // owner's pages, so a peer can never retain access into freed
        // physical memory (ADR 0016 D2 revocation-on-teardown). Regions it
        // PEER-mapped (the WM role) are detached — unmap + unref 2->1 — and
        // the owner's surface survives. Pure BSS + leaf writes, safe in this
        // exception context.
        _ = shared_mmap.revoke_owner(pid);
        _ = shared_mmap.revoke_peer_role(pid);
        file_table.reset_process(pid);
        tcp.close_owner(pid);
        @import("socket_native.zig").closeOwner(pid);
        virtio_snd.snd_stream_owner_death(pid);
        // Milestone 14 (claim 7323): a dead process's app timer is disarmed
        // now — no stale fire can ever reach a recycled pid.
        app_timers.reset(pid);
        // M32 WMS2 (issue #622): if the exited process was the registered
        // WM, unregister it NOW — pacing falls back to the shell idle shim
        // (the desktop survives a crashed WM, mirroring the close_owner
        // window-teardown semantic right above). Pure BSS write; the shell
        // idle loop drains the `wm: unregistered, shim resumed` report.
        _ = wm_server.unregister(pid);
    }
    // Teardown complete: open the slot to the idle reaper (it may now
    // free the zombie — the code below never touches the slot again).
    sched_lock_acquire();
    tasks[exiting].teardown_pending = false;
    if (tasks[exiting].joiner) |joiner| {
        if (tasks[joiner].state == .blocked and tasks[joiner].wait_thread) {
            tasks[joiner].wait_thread = false;
            tasks[joiner].state = .ready;
            _ = exceptions.frame_write(@ptrFromInt(tasks[joiner].sp), 0, status);
            push_home_locked(joiner);
            tasks[exiting].join_token = 0;
        }
        tasks[exiting].joiner = null;
    }
    sched_lock_release();
    // Successor rotation under the ring locks only (claim 881 slice 3);
    // a kill_pending successor converts inside claim_and_stage. The
    // staged successor MUST be applied here (apply_pending) — without
    // it the SVC return erets the EXITING task's own frame and the
    // zombie keeps running while `current` names the staged successor
    // (the slice-3 smp1 crash: the next tick then saved the zombie's
    // live frame into the successor's TCB).
    if (claim_and_stage(c, exiting)) {
        apply_pending();
        return true;
    }
    // No successor. Core 0 is unreachable here (the always-ready idle
    // task); a SECONDARY core parks back on its WFE loop instead of
    // rolling the exit back — the exiting task stays a zombie for core
    // 0's reaper (claim 2369).
    if (stage_secondary_park(c)) return true;
    // No successor (defensive rollback — the always-ready idle task
    // makes this unreachable in a normal boot; kept as a bound).
    sched_lock_acquire();
    tasks[exiting].state = .ready;
    tasks[exiting].exit_status = 0;
    tasks[exiting].kill_pending = pending_kill;
    tasks[exiting].kill_pending_status = pending_status;
    push_home_locked(exiting);
    sched_lock_release();
    return false;
}

/// Card 3d (claim 1014): EVERY exit is queued (a full ring drops the
/// oldest) — N exits in one window print N lines in order. Callers hold
/// `sched_lock`.
/// Secondary-core park (claim 2369): stage the WFE frame captured when
/// this core started its task, so an SVC that must give up the CPU
/// (sleep/wait/wait_event/exit) with no eligible successor returns the
/// core to its WFE loop instead of rolling back. The parked task stays in
/// its new state (blocked/zombie) for core 0's tick/reaper to service;
/// a later tick picks it up again when it is ready (pin_core routes it
/// back to this core). Callers hold `sched_lock` and run on core `c`.
fn stage_secondary_park(c: usize) bool {
    if (c == 0 or park_sp[c] == 0) return false;
    current[c] = idle_id;
    pending_sp[c] = park_sp[c];
    pending_elr[c] = park_elr[c];
    pending_spsr[c] = park_spsr[c];
    pending_sp_el0[c] = 0;
    pending_tls[c] = 0;
    pending_ttbr0[c] = mmu.kernel_root_phys();
    apply_pending();
    return true;
}

fn queue_exit_report(name: []const u8, status: u64) void {
    if (exit_report_count == exit_report_max) {
        exit_report_head = (exit_report_head + 1) % exit_report_max;
        exit_report_count -= 1;
    }
    const report_index = (exit_report_head + exit_report_count) % exit_report_max;
    exit_reports[report_index] = .{ .name = name, .status = status };
    exit_report_count += 1;
}

/// Claim 6729: reap a zombie — free its pool slot. Only a zombie may be
/// reaped, and the reaped slot becomes spawnable again. Returns false for a
/// non-zombie slot. Claim 4613: the exited process that last ran on this
/// slot has its allocator-backed pages (text/user-stack/EL1-exception-
/// stack) returned to the physical allocator at the same reap — the
/// exited descriptor (name, status, stack VA) stays in the `procs` table
/// for the claim-3848 exit record, but the memory is recycled immediately.
pub fn reap(id: usize) bool {
    // Kernel lock first (claim 9498 follow-on): release_pages_on_reap
    // zeroes the exited process's registry rows, which sys_procs and the
    // registry syscalls read under the kernel lock.
    const gated = !svclock.kernel.held();
    if (gated) svclock.kernel.acquire();
    defer if (gated) svclock.kernel.release();
    // Brief sched_lock: the state/teardown check, the ring drop, and the
    // slot reset (the reset under the lock is the double-reap guard). The
    // page release runs AFTER, under the kernel gate only (claim 881
    // slice 3: a long reap must not stall another core's rotation).
    sched_lock_acquire();
    if (id >= max_tasks or tasks[id].state != .zombie or tasks[id].teardown_pending or (@atomicLoad(u64, &tasks[id].exception_guard, .acquire) & 1) != 0 or tasks[id].join_token != 0) {
        sched_lock_release();
        return false;
    }
    // ADR 0027 D3: a thread task's EL1 exception stack is its OWN allocation
    // (not the process descriptor's) — record it before the slot reset.
    const thread_kstack_phys = tasks[id].thread_kstack_phys;
    const thread_kstack_pages = tasks[id].thread_kstack_pages;
    // Claim 881: the freed slot leaves its ring BEFORE the reset (the
    // exit path already dropped it — this remove is the defensive net).
    _ = ring_remove_anywhere(id);
    tasks[id] = .{};
    task_count -%= 1;
    sched_lock_release();
    _ = process.release_pages_on_reap(id);
    if (thread_kstack_phys != 0 and thread_kstack_pages > 0) {
        _ = alloc.free_pages(thread_kstack_phys, thread_kstack_pages);
    }
    return true;
}

/// The idle task's reaper: free ONE zombie per iteration so the pool drains
/// without starving other tasks, and snapshot the reap report (the freed
/// slot's name is zeroed by the reset). Claim 4613: `reap` also frees the
/// exited process's allocator-backed pages, so a permanent occupant
/// (COUNTER.BIN) coexists with a steady exec → exit → reap → re-exec
/// cycle without leaking.
pub fn reap_one_zombie() void {
    var i: usize = 0;
    while (i < max_tasks) : (i += 1) {
        // Claim 9094 (#810): validate the slot BEFORE reading its state —
        // the idle reaper is where run-11 boots 2/3 faulted on wildly
        // corrupted fields; the audit records the evidence first.
        audit.slot(i, .reap);
        if (tasks[i].state != .zombie) continue;
        const name = tasks[i].name;
        if (!reap(i)) continue;
        // Card 3d (claim 1014): EVERY reap is queued (a full ring drops
        // the oldest) — two reaps in one idle-loop window print two lines
        // in order instead of collapsing.
        if (reap_report_count == exit_report_max) {
            reap_report_head = (reap_report_head + 1) % exit_report_max;
            reap_report_count -= 1;
        }
        const report_index = (reap_report_head + reap_report_count) % exit_report_max;
        reap_reports[report_index] = .{ .name = name };
        reap_report_count += 1;
        return;
    }
}

/// Claim 1747: the console-free background hook, run once per idle pass.
///
/// WHY THIS EXISTS. The custom-virtio INPUT channel (queue 3) was pumped
/// only from `M15Console.readByteFn` — i.e. only when the SHELL idle loop
/// happened to poll for a byte. That made input liveness depend on the
/// shell making progress: with the serial-attached terminal and a
/// shell-side synchronous GPU wait, the loop is not guaranteed to run, the
/// completions are never scanned, and injected chords never reach the
/// guest. OBSERVED on go-dogfood boot 04: the host enqueued every chord
/// message and reported `sequence complete`, yet no `gotabwm: key` /
/// `charmhello: key` / resize followed, while scheduler and WM output
/// continued — the shell heartbeat alone had stopped.
///
/// The fix is to give the drain a home that does not depend on the shell.
/// The idle task is the right one: scheduler-owned, core-0, always ready,
/// MAIN context (never IRQ), and it already runs a bounded pass per
/// iteration. `main.zig` registers the queue-3 pump here and the pump is
/// REMOVED from the console reader, so the ring has exactly one owner.
///
/// Contract for a registrant: bounded and non-blocking. It runs on core-0
/// in main context with IRQs enabled, between the reap and the spin, with
/// NO scheduler lock held (`reap_one_zombie` has returned). Anything that
/// can block does not belong here.
pub var on_idle_pass: ?*const fn () void = null;

/// One bounded idle pass: reap a zombie, then run the console-free hook.
/// `idle_entry` calls this every iteration; host tests call it directly,
/// because the entry loop itself never returns.
pub fn idle_pass() void {
    reap_one_zombie();
    if (on_idle_pass) |f| f();
}

/// The scheduler-owned idle task (claim 6729): always ready and the
/// lifecycle reaper — it reaps one zombie per iteration. It parks with a
/// BOUNDED nop delay (not WFE): the shell's idle wait documents that a WFE
/// in a main-context loop sleeps until the next interrupt and can stall the
/// polled-RX loop on VZ (claim 6684), so the idle task uses the same
/// proven bounded delay between reap passes.
pub fn idle_entry() void {
    while (true) {
        idle_pass();
        if (comptime builtin.cpu.arch == .aarch64) {
            var spins: usize = 0;
            while (spins < 100_000) : (spins += 1) asm volatile ("nop");
        } else {
            asm volatile ("nop");
        }
    }
}

/// The monitor `spawn` command (claim 6729): spawn the lifecycle demo task
/// on its dedicated stack. Explicitly bounded — one demo spawn per boot
/// (the pool has exactly one spare slot while the EL0 task is alive).
pub fn spawn_demo() ?usize {
    if (spawn_demo_armed) return null;
    spawn_demo_armed = true;
    return spawn("spawn-demo", @intFromPtr(&spawn_demo_entry), spsr_el1h_irqs, &spawn_demo_stack, mmu.kernel_root_phys(), 0);
}

/// The lifecycle demo task: bumps its advance counter and asks the shell
/// loop to report it, proving a runtime-spawned task entered the ring and
/// receives quanta. Never exits; the EL0 task exercises the exit/reap half
/// of the lifecycle.
fn spawn_demo_entry() void {
    var local: u64 = 0;
    while (true) {
        local += 1;
        note_advance();
        if (local % 16 == 0) request_report();
        var spins: usize = 0;
        while (spins < 2_000_000) : (spins += 1) asm volatile ("nop");
    }
}

/// IRQ-context tick (called from the kernel's irq_dispatch right after
/// timer.handle re-armed the comparator): preempt the current task and
/// round-robin to the next. The interrupted task's vector frame is on the
/// stack (`exceptions.resume_frame[c]`); ELR_EL1/SPSR_EL1 still hold the
/// interrupted PC/PSTATE. The switch itself only programs ELR/SPSR and the
/// stub's restore frame — the stub does the register pop and eret.
pub fn tick() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (!scheduling_active()) return;
    const c = smp.core_id(); // per-core staging
    smp.core_ticks[c] +%= 1;
    // Service-domain locks (claim 9498 follow-on): on_tick's registry
    // work (app timers, WM pacing, CPU-limit arming) mutates EV + kernel
    // state — its canonical subset. try_take NEVER spins (a same-core
    // main-context holder can be preempted mid-section): a same-domain
    // syscall elsewhere defers only this work while the rotation below
    // proceeds (the claim-9498 ring-progress fix). try_take also skips
    // bits this core already holds — but svclock holders mask IRQs, so
    // no tick can ever preempt a same-core hold.
    const evk = svclock.dom_bit(.ev) | svclock.dom_bit(.kernel);
    const evk_taken = svclock.try_take(evk);
    // Core-0 timekeeping authority (tick_count, wake_expired, app timers,
    // WM pacing, CPU limits) under a brief sched_lock TRY: the idle
    // reaper / monitor may hold sched_lock from main context with IRQs
    // unmasked, so a tick that preempted such a holder must never spin
    // here — skipped => one 1 s cadence loss (the pre-existing skip
    // semantic; claim 9498). Claim 881 slice 3: sched_lock no longer
    // spans the rotation below — only this timekeeping beat.
    if (c == 0 and evk_taken != null) {
        if (sched_lock.try_lock()) {
            sched_lock_holder = smp.core_id();
            sched_lock_acquires +%= 1; // M70b: the tick's try-acquire is traffic too
            on_tick();
            sched_lock_release();
        } else {
            // M70b review: a failed try IS a contention observation —
            // without this, `contended=0` could hide exactly the cadence
            // losses the skip semantic exists for.
            sched_lock_contended +%= 1;
        }
    }
    // Conversion needs FILE first. Drop the timekeeping subset before
    // any selection/secondary conversion, preserving canonical lock order.
    if (evk_taken) |t| svclock.release_set(t);
    var elr: u64 = 0;
    var spsr: u64 = 0;
    asm volatile ("mrs %[v], elr_el1"
        : [v] "=r" (elr),
    );
    asm volatile ("mrs %[v], spsr_el1"
        : [v] "=r" (spsr),
    );
    if (c != 0 and current[c] == idle_id) {
        // The secondary core's WFE loop owns no ring slot — jump straight
        // to an eligible task (nothing to save). If none is runnable, the
        // stub restores the WFE frame and the core keeps spinning.
        // Capture the WFE frame FIRST (claim 2369): `resume_frame[c]` is
        // the tick IRQ frame on the secondary stack, and `elr`/`spsr` the
        // interrupted loop's — a task staged from here runs on its own
        // kstack, so these bytes survive intact until the task exits, when
        // exit_current erets back to them (park) if no successor exists.
        park_sp[c] = exceptions.resume_frame[c];
        park_elr[c] = elr;
        park_spsr[c] = spsr;
        // Claim 881 slice 2/3, generalized by issue #857: claim the
        // successor over every ring — a parked core pulls any eligible
        // foreign-ring work (a woken pin-core task on its own ring is
        // reached the same way) — under the ring locks only, inside
        // claim_and_stage.
        if (claim_and_stage(c, idle_id)) apply_pending();
        return;
    }
    // A lone secondary-eligible task keeps running (the shared idle
    // fallback is core 0's, so there is no always-ready successor here).
    // A kill_pending must still convert even without a successor to
    // switch to — request_kill on a lone core-1 task would otherwise
    // stall until it blocks (claim 9498). The conversion runs the exit
    // teardown — EVERY service domain — so it try-takes the full set
    // in canonical order. When any is
    // contended the task runs one more quantum and the next beat
    // converts it.
    if (c != 0 and current[c] != idle_id and convert_pending_kill()) return;
    // A lone task on a secondary core keeps running with no successor
    // (claim 9498: no always-ready idle fallback there, so parking would
    // stall it). But an EL0 USER task must still witness each timer
    // quantum: core 0 always preempts (its idle fallback) while a lone
    // EL0t task on a secondary core would otherwise run forever with NO
    // preemption at all — the boot payload's EL0-visible timer-preemption
    // witness (claim 8215, spun on at `userspace.entry` 4:) only fires on
    // a REAL preemption, so on multi-AP boots the payload can hang before
    // its exit (the #810 family, near-deterministic once 2+ APs can each
    // claim a ring-0 member and leave the payload alone on another core).
    // Fall through to switch_context for EL0t: its wrap self-rotation
    // (push + re-claim at the ring wrap) preempts the task once per
    // quantum — witness included — at the cost of one save/restore per
    // second. EL1h kernel tasks (the worker) keep the no-churn bail-out.
    if (c != 0 and next_runnable_for(current[c], c) == null and (spsr & 0xf) != spsr_el0t_irqs) return;
    // #1278: record the rotation and the task it preempts. A boot that dies
    // silently inside a switch is exactly the shape #1261 could not see, and
    // `arg` is the task id being switched AWAY from — the half that a "which
    // task is current" dump taken after the fact can never recover.
    forensics.note(.rotate, current[c]);
    timer_switch_context(exceptions.resume_frame[c], elr, spsr, exceptions.resume_sp_el0[c]);
    apply_pending();
    // A rotation just ran, so any reschedule request it was serving is
    // discharged. Clearing here rather than at entry is what makes a wake raised
    // inside this same beat's `on_tick` (app timers, WM pacing, `wake_expired`)
    // land on a request served by the rotation already happening, rather than
    // arming a second one. Nothing can wake between the rotation and this call,
    // because the IRQ handler is masked throughout.
    discharge_resched(c);
}

/// Tick-only wrapper around the pure switch core. Keeping the source of the
/// switch explicit prevents a cooperative yield from masquerading as the
/// timer-preemption witness inherited from claim 8215.
pub fn timer_switch_context(frame_sp: u64, elr: u64, spsr: u64, sp_el0: u64) void {
    if ((spsr & 0xf) == spsr_el0t_irqs) user_timer_preemptions +%= 1;
    switch_context(frame_sp, elr, spsr, sp_el0);
}

pub fn user_timer_preemption_count() u64 {
    return user_timer_preemptions;
}

// ---------------------------------------------------------------------------
// Claim 9094 (#810 writer hunt): task-ring + process-registry audit
// ---------------------------------------------------------------------------

/// Instrumentation ONLY — no behavior change. The #810 corruption family
/// (wild Task/Process field values in the vf-output era: 0xfcab6000, −1,
/// 0x80000000-based pointers) always violates a field invariant BEFORE the
/// faulting read, so the audit prints the slot/field/value that binds the
/// corruption to its window. Windows: (a) EVERY virtio_file queue-5
/// exchange arms at entry / checks at exit (`.vf`); (b) `reap_one_zombie`
/// validates the slot it is about to read (`.reap`); (c) the tick's ring
/// select validates `current` before the `kill_pending` read — the +0x178
/// byte read that faulted in run-11 boots — (`.tick`, record-only: no
/// console in IRQ context, claim 9187); (d) the shell idle loop drains
/// recorded violations via `drain` (main context, inside `maybe_report`).
///
/// Bounds are strict supersets of observed LEGAL values: kernel pointers
/// (image, BSS stacks, allocator frames) sit in [0x1000, 0x80000000) — the
/// top of the guest's 2 GiB RAM @ 0 (the same ceiling as
/// exceptions.deep_dump; the SEA at 0x80000178 proves nothing maps at or
/// above it in this class). User-space VAs (sp_el0, the randomized user
/// stack) are LEGAL as task fields and deliberately not validated. Task
/// names are kernel string literals ("worker", "user-exec", …); process
/// names are copied into BSS name buffers — all kernel memory.
pub const audit = struct {
    pub const ram_ceiling: u64 = 0x8000_0000;
    pub const Tag = enum { vf, reap, tick, drain };
    pub const Field = enum(u8) { state, name_ptr, name_len, sp, elr, ttbr0, p_state, p_name_len, p_task_id, p_kstack, p_text, p_stack };
    const max_violations: usize = 8;
    const Violation = struct {
        tag: Tag = .drain,
        field: Field = .state,
        slot: usize = 0,
        value: u64 = 0,
        tick: u64 = 0,
    };

    /// Nested-arm depth (an exchange nested inside an exchange keeps ONE
    /// armed window).
    pub var depth: u32 = 0;
    pub var arms: u64 = 0;
    pub var checks: u64 = 0;
    /// Scheduler tick at which the current window was armed.
    pub var armed_tick: u64 = 0;
    /// One "audit armed" evidence line per boot (proves the seam runs;
    /// nothing else prints on healthy boots).
    var boot_line: bool = false;
    /// The last (slot, field) pair DRAINED this boot — repeating
    /// violations (the reap pass re-validates the same corrupted slot
    /// every idle iteration) print once, so one corruption = one line.
    var last_slot: usize = 0;
    var last_field: Field = .state;
    var have_last: bool = false;

    var viol: [max_violations]Violation = [_]Violation{.{}} ** max_violations;
    var viol_head: usize = 0;
    var viol_count: usize = 0;

    /// Legal kernel pointer: 0 or a RAM-class address.
    fn valid_ptr(v: u64) bool {
        return v == 0 or (v >= 0x1000 and v < ram_ceiling);
    }

    /// Legal physical root/table pointer: page-aligned RAM-class or 0.
    fn valid_aligned(v: u64) bool {
        return v == 0 or ((v & 0xfff) == 0 and v >= 0x1000 and v < ram_ceiling);
    }

    /// NOTE: saved PSTATE is deliberately NOT validated — observed legal
    /// spsr values span PAN/UAO/condition bits up to 0x60000000 and even
    /// 0x80000005 (the #810 frames), so no shape check separates corrupt
    /// from legit. Run-12 boot 1 proved it: a too-tight spsr rule fired
    /// on every reap pass and flooded the serial with 38 false-positive
    /// lines. Excluded; the remaining fields still catch every observed
    /// corruption value (−1, 0xfcab6000, string bytes, dead-space VAs).
    /// Raw storage read of the state enum — the TYPED load of a rogue
    /// byte as an enum is UB in safe builds; the audit must not fault
    /// itself.
    fn enum_raw(ptr: *const anyopaque) u64 {
        var raw: u64 = 0;
        const bytes: [*]const u8 = @ptrCast(ptr);
        var i: usize = 0;
        while (i < @sizeOf(State)) : (i += 1) raw |= @as(u64, bytes[i]) << @intCast(i * 8);
        return raw;
    }

    /// Arm a window (nested arms keep one open window).
    pub fn arm(tag: Tag) void {
        _ = tag;
        if (depth == 0) armed_tick = tick_count;
        depth +%= 1;
        arms +%= 1;
    }

    /// Close the window and validate the whole ring + registry.
    pub fn check(tag: Tag) void {
        checks +%= 1;
        if (depth > 0) depth -%= 1;
        sweep(tag);
    }

    /// Validate ONE task slot (the reap/tick read seams).
    pub fn slot(id: usize, tag: Tag) void {
        if (id < max_tasks) check_task(id, tag);
    }

    fn sweep(tag: Tag) void {
        if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
        var i: usize = 0;
        while (i < max_tasks) : (i += 1) check_task(i, tag);
        var p: usize = 0;
        while (p < process.max_processes) : (p += 1) check_proc(p, tag);
    }

    fn check_task(id: usize, tag: Tag) void {
        const t = &tasks[id];
        const st = enum_raw(&t.state);
        if (st > @intFromEnum(State.zombie)) record(tag, .state, id, st);
        const nptr = @intFromPtr(t.name.ptr);
        if (!valid_ptr(nptr)) record(tag, .name_ptr, id, nptr);
        if (t.name.len > 64) record(tag, .name_len, id, t.name.len);
        if (!valid_ptr(t.sp)) record(tag, .sp, id, t.sp);
        if (!valid_ptr(t.elr)) record(tag, .elr, id, t.elr);
        if (!valid_aligned(t.ttbr0)) record(tag, .ttbr0, id, t.ttbr0);
    }

    fn check_proc(id: usize, tag: Tag) void {
        const c = process.audit_proc(id);
        if (c.state > @intFromEnum(process.State.exited)) record(tag, .p_state, id, c.state);
        if (c.name_len > process.name_max) record(tag, .p_name_len, id, c.name_len);
        if (c.task_id) |tid| {
            if (tid >= max_tasks) record(tag, .p_task_id, id, tid);
        }
        if (!valid_aligned(c.kstack_phys)) record(tag, .p_kstack, id, c.kstack_phys);
        if (!valid_aligned(c.text_phys)) record(tag, .p_text, id, c.text_phys);
        if (!valid_aligned(c.stack_phys)) record(tag, .p_stack, id, c.stack_phys);
    }

    fn record(tag: Tag, field: Field, row: usize, value: u64) void {
        const idx = (viol_head + viol_count) % max_violations;
        if (viol_count == max_violations) {
            viol_head = (viol_head + 1) % max_violations;
        } else {
            viol_count += 1;
        }
        viol[idx] = .{ .tag = tag, .field = field, .slot = row, .value = value, .tick = tick_count };
    }

    fn field_name(f: Field) []const u8 {
        return switch (f) {
            .state => "state",
            .name_ptr => "name_ptr",
            .name_len => "name_len",
            .sp => "sp",
            .elr => "elr",
            .ttbr0 => "ttbr0",
            .p_state => "procs.state",
            .p_name_len => "procs.name_len",
            .p_task_id => "procs.task_id",
            .p_kstack => "procs.kstack",
            .p_text => "procs.text",
            .p_stack => "procs.stack",
        };
    }

    fn tag_name(t: Tag) []const u8 {
        return switch (t) {
            .vf => "vf",
            .reap => "reap",
            .tick => "tick",
            .drain => "drain",
        };
    }

    /// Print the one-per-boot armed line and drain any recorded
    /// violations (main context only — called from `maybe_report`).
    pub fn drain(con: *console.Console) void {
        if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
        if (!boot_line) {
            boot_line = true;
            con.puts("[AUDIT] task-ring+procs audit armed slots=");
            con.print_u64(max_tasks);
            con.puts(" procs=");
            con.print_u64(process.max_processes);
            con.puts("\n");
        }
        while (viol_count > 0) {
            const v = viol[viol_head];
            viol_head = (viol_head + 1) % max_violations;
            viol_count -= 1;
            // Repeat-suppression: the same (slot, field) re-recorded by a
            // later window (e.g. the next reap pass) is a repeat of the
            // SAME corruption — one line per boot per corruption.
            if (have_last and v.slot == last_slot and v.field == last_field) continue;
            have_last = true;
            last_slot = v.slot;
            last_field = v.field;
            const is_task = @intFromEnum(v.field) < @intFromEnum(Field.p_state);
            con.puts("[AUDIT] ");
            con.puts(if (is_task) "tasks slot=" else "procs id=");
            con.print_u64(v.slot);
            con.puts(" field=");
            con.puts(field_name(v.field));
            con.puts(" value=");
            con.print_hex(v.value);
            con.puts(" tag=");
            con.puts(tag_name(v.tag));
            con.puts(" tick=");
            con.print_u64(v.tick);
            con.puts("\n");
        }
    }
};

// ---------------------------------------------------------------------------
// Worker progress (main context only — never from the IRQ tick)
// ---------------------------------------------------------------------------

/// Task-side: bump the current task's advance counter (the worker calls
/// this in its main-context loop).
pub fn note_advance() void {
    if (task_count == 0) return;
    const c = smp.core_id(); // per-core current
    tasks[current[c]].advances += 1;
}

/// Task-side: ask the shell idle loop to print the current task's advance
/// counter. Keeps the FIRST snapshot per task while that task's slot is
/// pending (no backlog). Console output stays in main context (claim 9187
/// — never print from IRQ). Claim 6729: per-task slots, so one task's
/// reports cannot starve another's (the worker requests every 64
/// iterations; the spawn-demo task every 16).
pub fn request_report() void {
    const c = smp.core_id(); // per-core current
    if (task_count == 0 or report_pending[current[c]]) return;
    report_pending[current[c]] = true;
    report_advances[current[c]] = tasks[current[c]].advances;
}

/// Shell-side (main context, next to timer.maybe_heartbeat): print every
/// pending report line, then the exit/reap reports.
pub fn maybe_report(con: *console.Console) void {
    // One bounded pass even if other cores enqueue new process exits.
    for (0..max_tasks) |_| {
        sched_lock_acquire();
        if (exit_kill_report_count == 0) {
            sched_lock_release();
            break;
        }
        const entry = exit_kill_reports[exit_kill_report_head];
        exit_kill_report_head = (exit_kill_report_head + 1) % max_tasks;
        exit_kill_report_count -= 1;
        sched_lock_release();
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "tasks exit-kill outstanding pid={d} task={d} state={s} kill_pending={} futex_waiting={} wakeup_tick={d} rings=0x{x} age={d}\n", .{
            entry.pid, entry.task, state_name(entry.state), entry.kill_pending, entry.futex_waiting, entry.wakeup_tick, entry.rings, entry.age,
        }) catch continue;
        con.puts(line);
    }
    // B7: bounded PCM completions/deadlines and deferred owner-death cleanup.
    // No audio control exchange runs from the IRQ scheduler.
    virtio_snd.snd_stream_poll();
    // Claim 9094 (#810): the idle-loop drain point for the task-ring/
    // process audit — main context, console-safe (claim 9187). Nothing
    // prints on healthy boots beyond the one-per-boot armed line.
    audit.drain(con);
    // SMP lift evidence (claim 8477 follow-up): one line per secondary
    // RUN retained in the bounded name buffer, from main context. #1965:
    // self-rotations can run at yield cadence, not tick cadence. Snapshot
    // once and skip overwritten names rather than reconstructing millions
    // of discarded reports and starving monitor handback forever.
    const secondary_end = secondary_runs;
    const secondary_first = secondary_end - @min(secondary_end, secondary_run_names_count);
    secondary_runs_printed = @max(secondary_runs_printed, secondary_first);
    while (secondary_runs_printed < secondary_end) {
        const index = secondary_runs_printed - secondary_first;
        secondary_runs_printed += 1;
        const name = secondary_run_names[index];
        // ONE write per line (claim 881 slice 4): a secondary-core
        // sys_write can land between the vtable writes of a multi-put
        // line, splitting it (observed: `smp: secondary runs=` / `111` /
        // ` task=SCHEDRING.BIN` around a core-1 write) and breaking the
        // live gates' byte-exact greps. Every drain line below is built
        // into one buffer and written once.
        var buf: [160]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "smp: secondary runs={d} task={s}\n", .{ secondary_runs_printed, name }) catch continue;
        con.puts(line);
    }
    // The migration buffer has the same drop-oldest, bounded-drain rule.
    const steal_end = steal_runs;
    const steal_first = steal_end - @min(steal_end, steal_run_names_count);
    steal_runs_printed = @max(steal_runs_printed, steal_first);
    while (steal_runs_printed < steal_end) {
        const index = steal_runs_printed - steal_first;
        steal_runs_printed += 1;
        const sname = steal_run_names[index];
        const sfrom = steal_run_froms[index];
        var buf: [160]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "smp: steal runs={d} task={s} from={d}\n", .{ steal_runs_printed, sname, sfrom }) catch continue;
        con.puts(line);
    }
    var i: usize = 0;
    while (i < max_tasks) : (i += 1) {
        if (!report_pending[i]) continue;
        report_pending[i] = false;
        var buf: [160]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "tasks {s} advances={d}\n", .{ tasks[i].name, report_advances[i] }) catch continue;
        con.puts(line);
    }
    // Milestone sixteen C2 (claim 8403): drain the EL0 fault FIFO IN ORDER
    // before the exit reports, so a `fault:` line precedes its
    // `exited status=139` consequence in the serial log. Issue #1214: the
    // line carries the faulting PC + raw ESR too — the tombstone's anchor
    // facts surfaced on serial (the crash/ file needs the host file
    // channel, which class-B gate boots don't attach), plus the symbol
    // note when the exec'd image's symtab names the PC (M22 D3).
    while (fault_report_count > 0) {
        const entry = fault_reports[fault_report_head];
        fault_report_head = (fault_report_head + 1) % fault_report_max;
        fault_report_count -= 1;
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "fault: {s} far=0x{x:0>16} ec=0x{x} pc=0x{x:0>16} esr=0x{x:0>16}", .{ entry.name, entry.far, entry.ec, entry.pc, entry.esr }) catch continue;
        con.puts(line);
        const hit = if (entry.pc != 0) symbol.lookup(entry.pc) else null;
        if (hit) |m| {
            var nbuf: [96]u8 = undefined;
            const note = std.fmt.bufPrint(&nbuf, " (in {s}+0x{x})\n", .{ m.name, m.offset }) catch "\n";
            con.puts(note);
        } else {
            con.puts("\n");
        }
    }
    // Card 3d (claim 1014): drain the task exit report FIFO IN ORDER — N
    // exits in one window print N `tasks <name> exited status=<n>` lines.
    while (exit_report_count > 0) {
        const entry = exit_reports[exit_report_head];
        exit_report_head = (exit_report_head + 1) % exit_report_max;
        exit_report_count -= 1;
        var buf: [160]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "tasks {s} exited status={d}\n", .{ entry.name, entry.status }) catch continue;
        con.puts(line);
    }
    // Claim 3848: the process-level exit reports — printed from the same
    // shell idle loop, one per process exit IN ORDER, so the host sees
    // every program's exit status even after the task slots are reaped.
    while (process.take_exit_report()) |r| {
        var buf: [160]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "procs {s} exited status={d}\n", .{ r.name, r.status }) catch continue;
        con.puts(line);
    }
    // Claim 6729: the idle task reaped zombies; the names were snapshotted
    // at reap time because the freed slots' own names are zeroed. Card 3d:
    // drained IN ORDER (every reap prints).
    while (reap_report_count > 0) {
        const entry = reap_reports[reap_report_head];
        reap_report_head = (reap_report_head + 1) % exit_report_max;
        reap_report_count -= 1;
        var buf: [160]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "tasks {s} reaped\n", .{entry.name}) catch continue;
        con.puts(line);
    }
    // Claim 0635: a task blocked itself with sys_sleep; the name + duration
    // were snapshotted at block time (the task is not running now, but the
    // report is the shell's window into the transition).
    if (sleep_report_pending) {
        sleep_report_pending = false;
        var buf: [160]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "tasks {s} sleeping {d} ticks\n", .{ sleep_report_name, sleep_report_ticks }) catch return;
        con.puts(line);
    }
}

test "scheduler: self-rotation report backlogs drain only retained names (#1965)" {
    _ = init();
    secondary_runs = 1_000_000;
    secondary_runs_printed = 0;
    secondary_run_names_count = secondary_run_name_cap;
    secondary_run_names = @splat("user-el0");
    steal_runs = 1_000_000;
    steal_runs_printed = 0;
    steal_run_names_count = steal_run_name_cap;
    steal_run_names = @splat("user-el0");
    steal_run_froms = @splat(1);
    defer {
        secondary_runs = 0;
        secondary_runs_printed = 0;
        secondary_run_names_count = 0;
        steal_runs = 0;
        steal_runs_printed = 0;
        steal_run_names_count = 0;
    }
    var mock = console.MockConsole(8192){};
    var con = mock.console();
    maybe_report(&con);
    try std.testing.expectEqual(secondary_run_name_cap, std.mem.count(u8, mock.contents(), "smp: secondary runs="));
    try std.testing.expectEqual(steal_run_name_cap, std.mem.count(u8, mock.contents(), "smp: steal runs="));
    try std.testing.expectEqual(secondary_runs, secondary_runs_printed);
    try std.testing.expectEqual(steal_runs, steal_runs_printed);
    mock.reset();
    maybe_report(&con);
    try std.testing.expectEqual(@as(usize, 0), mock.contents().len);
}

// ---------------------------------------------------------------------------
// Monitor-facing stats
// ---------------------------------------------------------------------------

pub const TaskInfo = struct {
    name: []const u8,
    state: State,
    saves: u64,
    resumes: u64,
    advances: u64,
    /// SMP user tasks (claim 2369): the only core this task may run on
    /// (0 = any core). Set by `pin_task` via `exec -c<core>`.
    pin_core: usize,
    /// May a secondary core steal this task off ring 0 (claim 9498)? False
    /// for a task pinned to CORE 0 (`exec -c0`, claim 907) and the shell.
    secondary_ok: bool,
};

pub const Stats = struct {
    enabled: bool,
    current: usize,
    switches: u64,
    /// Registered (non-free) slots — the lifecycle's live pool count.
    count: usize,
    /// Zombie slots awaiting the idle task's reap.
    zombies: usize,
};

pub fn stats() Stats {
    var zombies: usize = 0;
    for (tasks[0..max_tasks]) |task| {
        if (task.state == .zombie) zombies += 1;
    }
    return .{
        .enabled = enabled_flag,
        .current = current[smp.core_id()],
        .switches = switches,
        .count = task_count,
        .zombies = zombies,
    };
}

pub fn task_info(id: usize) ?TaskInfo {
    if (id >= max_tasks or tasks[id].state == .free) return null;
    return .{
        .name = tasks[id].name,
        .state = tasks[id].state,
        .saves = tasks[id].saves,
        .resumes = tasks[id].resumes,
        .advances = tasks[id].advances,
        .pin_core = tasks[id].pin_core,
        .secondary_ok = tasks[id].secondary_ok,
    };
}

/// ADR 0027 D4: the current tick counter (the futex deadline arithmetic
/// lives in the syscall layer, which owns the ns unit).
pub fn current_tick() u64 {
    return tick_count;
}

pub fn current_id() usize {
    return current[smp.core_id()];
}

pub fn current_task_for_core(cid: usize) usize {
    if (cid < smp.max_cores) return current[cid];
    return 0;
}

/// The TTBR0 root (physical) a task runs under (claim 5804; the
/// `addrspaces` diagnostic prints it).
pub fn task_ttbr0(id: usize) u64 {
    if (id >= max_tasks or tasks[id].state == .free) return 0;
    return tasks[id].ttbr0;
}

/// #2079 (M97g seat gate): the spawn provenance recorded at task
/// allocation. `parent` is the pid of the process whose task built this
/// task — null for a kernel-context spawn (boot, monitor `exec`,
/// autostart). `launcher` is true when that parent process was itself
/// kernel-spawned (the INIT service-spawn shape). A freed/out-of-range
/// slot reports `valid = false` so callers can fail closed.
pub const SpawnProvenance = struct {
    valid: bool,
    parent: ?usize,
    launcher: bool,
};

pub fn spawn_provenance(id: usize) SpawnProvenance {
    if (id >= max_tasks or tasks[id].state == .free) return .{ .valid = false, .parent = null, .launcher = false };
    return .{ .valid = true, .parent = tasks[id].spawned_by, .launcher = tasks[id].launcher_spawned };
}

pub fn cooperative_yield_count() u64 {
    return cooperative_yields;
}

pub fn exit_count() u64 {
    return exits;
}

pub fn is_terminated(id: usize) bool {
    return id < max_tasks and tasks[id].state == .zombie;
}

/// Claim 0635: true when the slot holds a task blocked by `sys_sleep`.
pub fn is_blocked(id: usize) bool {
    return id < max_tasks and tasks[id].state == .blocked;
}

pub fn terminated_status(id: usize) ?u64 {
    if (!is_terminated(id)) return null;
    return tasks[id].exit_status;
}
