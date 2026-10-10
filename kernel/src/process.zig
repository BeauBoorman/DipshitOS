//! VirelaiOS process abstraction (milestone four, card 3 — claim 3848).
//!
//! The task pool (scheduler.zig) is the EXECUTOR: context, TTBR0 switch,
//! quantum bookkeeping, zombie/reap. This module is the unit that owns the
//! PROGRAM — the loaded image, the address space it runs in, its lifecycle
//! state, and its exit status. A fixed BSS registry:
//! `max_processes` descriptors recycle like the pool slots do.
//!
//! What the process adds over the task:
//!   * The image descriptor (entry VA + content length) and the address
//!     space (root phys, text/stack VAs) travel WITH the process instead of
//!     living in exec's module globals.
//!   * The exit status is snapshotted at exit time and survives the task
//!     slot's reap — `procs` (and the exit report) can still show why a
//!     program died after the idle task freed its executor.
//!   * Per-process identity: every `exec` creates a NEW process descriptor,
//!     so `loaded()` and the table never hold a stale "last program".
//!   * The boot-time static EL0 payload registers as a process too, so one
//!     table shows both the payload's and the exec'd program's lifecycles.
//!
//! Lifecycle: free -> created (loaded, not yet bound) -> running (bound to
//! a live task) -> exited (the bound task became a zombie; status kept) ->
//! free (reaped). `create` takes the first free slot; when the registry is
//! full it recycles the OLDEST exited process (never a created/running
//! one). The scheduler's `exit_current` notifies this module (pure writes,
//! exception-context safe — the same report-pending pattern as the task
//! exit report); the shell idle loop drains the report via
//! `take_exit_report`.
//!
//! No libc, no POSIX, no scheduler import (the dependency
//! is one-way: scheduler -> process).

const std = @import("std");
const alloc = @import("alloc.zig"); // claim 0826: the process owns its pages (text/stack/kernel-stack) from the physical allocator
const memmap = @import("memmap.zig"); // host-test fixture view (page-ownership tests arm the allocator)
const mmu = @import("mmu.zig"); // #2116: the per-root page-table tree dies with the process
const svclock = @import("svclock.zig");

/// Bounded process registry size (fixed BSS array). Milestone sixteen C3
/// (claim 0339): grew 8 -> 16 — at the new 8-program concurrency the
/// registry saturated at 8/8 (the boot payload's exited slot recycled, no
/// headroom), and "8+ apps on the desktop" (desktop launcher + 8 apps)
/// needs room for nine live processes plus exited history before the
/// oldest exited descriptor is recycled.
pub const max_processes: usize = 16;
/// Process-name buffer bound (the FAT 8.3 file name or a task-style name
/// like "user-el0").
pub const name_max: usize = 16;

// ---------------------------------------------------------------------------
// M50 TS1 (issue #1135, ADR 0024 D1/D2/D5): the process principal.
// Identity lives on the Process record, is assigned at `create`, is preserved
// by `exec`, and is NEVER persisted and NEVER settable by a syscall. Two
// principals exist today: `uid_system` (the kernel's authority) and
// `uid_user` (every EL0 process). A second uid becomes reachable only through
// an explicit kernel/monitor spawn (`create_as`), never from EL0.
// ---------------------------------------------------------------------------

/// ADR 0024 D1: the kernel's authority — the EL1h monitor and kernel-internal
/// consumers act as it.
pub const uid_system: u32 = 0;
/// ADR 0024 D1: every EL0 process spawned today.
pub const uid_user: u32 = 1000;

/// ADR 0024 D5: the spawn-time capability mask (no elevation syscall exists).
/// `CAP_FS_ANY` bypasses the D3/D4 file checks; `CAP_PROC_ADMIN` permits
/// acting on another principal's processes (`sys_kill`, future admin).
pub const cap_fs_any: u32 = 1 << 0;
pub const cap_proc_admin: u32 = 1 << 1;
/// M97g (#2082): `CAP_CLIPBOARD` permits the programmatic clipboard slots
/// (38/39). The machine-global buffer is otherwise an unmediated
/// read/write channel every `uid_user` app could silently harvest or
/// swap; the user-gesture paths (the chrome copy/paste chords and the
/// monitor `clip` command) are kernel-internal and need no cap.
pub const cap_clipboard: u32 = 1 << 2;
/// Kernel-internal actors (including the EL1h monitor) hold all caps.
pub const kernel_caps: u32 = cap_fs_any | cap_proc_admin | cap_clipboard;

/// A process principal: a single uid plus the capability mask, assigned at
/// `process.create`. `exec` preserves it; there is no setuid bit and no
/// syscall that can raise either.
pub const Principal = struct {
    uid: u32 = uid_user,
    caps: u32 = 0,

    /// M50 TS3 (#1137, ADR 0024 D5/D10): does this principal hold `cap`?
    /// READ-ONLY — the mask is assigned once at `create_as` and never
    /// mutated; this is the only capability predicate the syscall gate
    /// table consumes. `uid_system` is NOT special-cased here: a
    /// monitor-spawned system principal carries `kernel_caps` explicitly.
    pub fn has(self: Principal, cap: u32) bool {
        return (self.caps & cap) != 0;
    }
};

/// The default spawn principal (ADR 0024 D5): every EL0-initiated spawn is
/// `uid_user` with no caps. A kernel/monitor spawn may override explicitly.
pub const default_principal = Principal{};

/// Explicit process lifecycle state (claim 3848 — the process-level mirror
/// of scheduler.State). A descriptor's state is the ONLY ownership signal:
/// `created` is loaded-but-unbound, `running` is bound to a live task slot,
/// `exited` keeps its status until reaped or recycled.
pub const State = enum {
    free,
    created,
    running,
    exited,
};

/// Human-readable state label for `procs` / tests.
pub fn state_name(state: State) []const u8 {
    return switch (state) {
        .free => "free",
        .created => "created",
        .running => "running",
        .exited => "exited",
    };
}

/// The loaded program's image descriptor (the part of the DSK1 file that
/// executes at EL0).
pub const Image = struct {
    /// User VA the process enters at.
    entry_va: u64 = 0,
    /// Content bytes (image minus the DSK1 header).
    content_len: u64 = 0,
};

/// The address space a process runs in (what its TTBR0 user root maps).
/// Claim 0826: the process OWNS the backing pages for exec'd programs —
/// Issue #1163 (GOOS=virelai phase 0a): raised 8 → 16 mmap regions and
/// 128 → 4096 recorded demand pages (~16 MiB). The gc Go runtime's sbrk
/// heap grows as sys_mmap regions (one per grow) and its working set
/// exceeds the old 128-page (~512 KiB) recording cap within milliseconds
/// of mallocinit.
pub const max_mmap_regions: usize = 16;
pub const max_dynamic_pages: usize = 4096;

/// The inline record capacity is not a working-set limit. Overflow records
/// use allocator pages, each holding 509 backing addresses, until physical
/// memory runs out. Callers must unwind a false record result before mapping.
const DynamicPageBlock = struct {
    next: ?*DynamicPageBlock,
    prev: ?*DynamicPageBlock,
    count: usize,
    pages: [509]u64,
};

comptime {
    std.debug.assert(@sizeOf(DynamicPageBlock) == alloc.page_size);
}
/// Default anonymous-mmap bump pointer (issue #1163). Restored explicitly
/// after an in-place BSS zero — `@memset` would leave this 0.
pub const mmap_default_va: u64 = 0x0000_0000_1000_0000;

/// ADR 0027 D1/D3: ONE process may carry several live tasks (the Go M:N
/// mapping — every M is a kernel task bound to the SAME descriptor). The
/// primary task is `task_id` (the exec'd creator); `thread_tasks` holds the
/// extra slots created via `sys_thread` op 0. Bounded by the descriptor
/// (the task pool bounds it further: `scheduler.max_tasks` slots total,
/// 16 after M65d / #1442). A GOMAXPROCS=2 runtime is 4 Ms (1 primary +
/// 3 extra); 6 extra seats leave headroom for syscall-spawned Ms. Not a
/// new per-process cap — ADR 0027 D1: the global pool is the bound.
pub const max_threads: usize = 6;

pub const MmapRegion = struct {
    base_va: u64 = 0,
    len: u64 = 0,
    prot: u64 = 0,
    flags: u64 = 0,
};

/// The address space a process runs in (what its TTBR0 user root maps).
/// Claim 0826: the process OWNS the backing pages for exec'd programs —
/// the allocator-backed text/user-stack phys + page counts (0 counts = the
/// backing is static, e.g. the boot payload's `.usertext`/`.userbss`,
/// which is never freed).
pub const AddrSpace = struct {
    /// Physical root of the task's user TTBR0 tables.
    root_phys: u64 = 0,
    /// User VA + length of the mapped text (W^X, EL0-executable).
    text_va: u64 = 0,
    text_len: u64 = 0,
    /// Physical text pages the process owns (allocator-backed; 0 = static).
    text_phys: u64 = 0,
    text_pages: u64 = 0,
    /// User VA + length of the mapped DATA region (EL0 RW, non-executable
    /// — the segmented image's `.data` + zeroed `.bss`, claim 3805).
    data_va: u64 = 0,
    data_len: u64 = 0,
    /// Physical data+bss pages the process owns (allocator-backed;
    /// 0 = no data segment / static).
    data_phys: u64 = 0,
    data_pages: u64 = 0,
    /// User VA + length of the mapped stack (EL0 RW, non-executable).
    stack_va: u64 = 0,
    stack_len: u64 = 0,
    /// Physical user-stack pages the process owns (allocator-backed;
    /// 0 = static `.userbss`).
    stack_phys: u64 = 0,
    stack_pages: u64 = 0,
    /// Physical interpreter pages (PT_INTERP / LD.SO, claim 7921).
    interp_phys: u64 = 0,
    interp_pages: u64 = 0,
    /// Physical read-only RODATA pages of a gap-layout ELF image (issue
    /// #1163, GOOS=virelai phase 0a): the middle [R] PT_LOAD mapped at its
    /// declared vaddr; 0 = none.
    ro_phys: u64 = 0,
    ro_pages: u64 = 0,
    /// User VA of the gap-layout rodata segment (issue #1214): recorded so
    /// `mmap_collides` can protect it like text/data/stack. 0 = none.
    ro_va: u64 = 0,
    /// User VA one-past the gap layout's packed argv+envp region in the
    /// writable segment's reserved tail page (issue #1214 review / #1226;
    /// 0 = no block). `mmap_collides` protects the data aperture through
    /// this end: when the data segment's `mem_size` is exactly page-aligned
    /// the argv/envp blocks start ON the otherwise-excluded headroom page,
    /// and the sbrk heap must not swallow them.
    argv_end_va: u64 = 0,
    /// Physical shared library staging/heap pages (claim 7921).
    lib_phys: u64 = 0,
    lib_pages: u64 = 0,
    /// M29 VM Depth: Anonymous mmap regions and dynamic page allocations
    mmap_regions: [max_mmap_regions]MmapRegion = [_]MmapRegion{.{}} ** max_mmap_regions,
    mmap_region_count: usize = 0,
    mmap_next_va: u64 = mmap_default_va,
    dynamic_pages: [max_dynamic_pages]u64 = [_]u64{0} ** max_dynamic_pages,
    dynamic_page_count: usize = 0,
    dynamic_head: ?*DynamicPageBlock = null,
    dynamic_tail: ?*DynamicPageBlock = null,
};

/// Scalar snapshot of an address space at create time (issue #1333).
/// `AddrSpace` carries `dynamic_pages: [4096]u64` (~32 KiB) plus the mmap
/// table; passing that by value (AAPCS64 large-struct copy) materializes a
/// temporary on the caller's 32 KiB EL0 kstack and overflows into the
/// adjacent user stack. `create`/`create_as` take this small spec and write
/// fields in place after an in-BSS `@memset`.
pub const AddrSpaceSpec = struct {
    root_phys: u64 = 0,
    text_va: u64 = 0,
    text_len: u64 = 0,
    text_phys: u64 = 0,
    text_pages: u64 = 0,
    data_va: u64 = 0,
    data_len: u64 = 0,
    data_phys: u64 = 0,
    data_pages: u64 = 0,
    stack_va: u64 = 0,
    stack_len: u64 = 0,
    stack_phys: u64 = 0,
    stack_pages: u64 = 0,
    interp_phys: u64 = 0,
    interp_pages: u64 = 0,
    ro_phys: u64 = 0,
    ro_pages: u64 = 0,
    ro_va: u64 = 0,
    argv_end_va: u64 = 0,
    lib_phys: u64 = 0,
    lib_pages: u64 = 0,
};

comptime {
    // Must stay pass-by-value-safe on the 32 KiB EL0 kstack (#1333).
    if (@sizeOf(AddrSpaceSpec) > 256) {
        @compileError("AddrSpaceSpec grew past 256 bytes; pass-by-value would overflow the EL0 kstack");
    }
}

/// Kernel-side resources the process owns with its program (freed at
/// reap/recycle like the address-space pages): the executor task's EL1
/// exception stack. Claim 0826: two live EL0t tasks cannot share ONE
/// static `user_kernel_stack` — a second task's exception frame would
/// clobber the first task's saved vector frame — so every exec'd process
/// allocates its own 8 KiB EL1 stack. 0 pages = the static boot stack.
pub const KernelStack = struct {
    phys: u64 = 0,
    pages: u64 = 0,
};

/// Kernel-only live/final diagnostic (M90d/M89e): recorded demand backing and occupied
/// mmap slots, not virtual reservation sizes or Go heap statistics. Static
/// segment pages are rounded individually; stacks, argv headroom, interpreter
/// and library backing are excluded. Kept through task resource release,
/// cleared only with the descriptor at reap/recycle. No syscall row changes.
pub const RuntimeReceipt = struct {
    /// High-water of live ownership records, including overflow storage.
    peak_pages: usize = 0,
    peak_regions: usize = 0,
    static_pages: u64 = 0,
    /// Cumulative accepted backing allocations; unmap does not lower this.
    total_pages: usize = 0,
    /// Overflow storage exhaustion. Callers roll back, never keep an
    /// unrecorded mapping. The printed page_cap is the INLINE capacity.
    record_failures: usize = 0,
};

const Process = struct {
    /// Owned copy of the program's name (the FAT file name for exec'd
    /// programs, "user-el0" for the boot static payload) — the caller's
    /// slice (e.g. the monitor's token buffer) does not outlive the call.
    name_buf: [name_max]u8 = [_]u8{0} ** name_max,
    name_len: usize = 0,
    state: State = .free,
    image: Image = .{},
    addr_space: AddrSpace = .{},
    runtime_usage: RuntimeReceipt = .{},
    /// M50 TS1 (#1135, ADR 0024 D2): the process principal — assigned at
    /// create, preserved by exec, never persisted, never settable by a
    /// syscall. The `sys_procs` snapshot row deliberately omits it.
    uid: u32 = uid_user,
    caps: u32 = 0,
    /// Claim 0826: the executor's EL1 exception stack (allocator-backed
    /// for exec'd programs, the static boot stack for the payload).
    kernel_stack: KernelStack = .{},
    /// The pool slot currently executing this process; null once exited
    /// AND the executor slot has been reaped (the lifecycle reap reads it
    /// to free the exited process's owned pages, claim 4613). Before the
    /// reap, an exited process still names its last executor slot — the
    /// `procs` command prints `task=reaped` for exited rows regardless.
    task_id: ?usize = null,
    /// ADR 0027 D1/D3: the EXTRA live tasks bound to this process (created
    /// via `sys_thread` op 0). Null = free seat. Thread exit clears its
    /// seat; the descriptor's task_id stays the ORIGINAL creator until the
    /// process transitions to exited, at which point it names the LAST
    /// exiting task (the slot whose reap frees the process pages,
    /// `release_pages_on_reap`).
    thread_tasks: [max_threads]?usize = [_]?usize{null} ** max_threads,
    /// Live tasks on this process (primary + threads). The process dies
    /// when this reaches 0 — `sys_exit`/fault request the exit and kill the
    /// siblings; thread exit just decrements.
    live_tasks: usize = 0,
    /// ADR 0027 D2: a process exit REQUESTED via sys_exit/kill/fault while
    /// sibling threads still run. The first request wins and snapshots the
    /// status the process reports when the LAST task exits.
    exit_requested: bool = false,
    exit_status_snapshot: u64 = 0,
    /// Exit status, snapshotted at exit so it survives the task reap.
    exit_status: u64 = 0,
    /// M97g (#2085): the pid of the process that spawned this one, recorded
    /// at bind from the task's spawn provenance (null = kernel-context
    /// spawn: boot, monitor `exec`, autostart). Kept after exit — the
    /// APPLOG/CRASH label binding lets a supervisor maintain a dead
    /// child's diagnostics, and the receipt lands post-mortem. Never set
    /// from EL0.
    spawner: ?usize = null,
    /// Issue #1228 (phase 0c): the EL0 fault-handler PC a process
    /// registered via slot 75 `sys_exnotify` op 0. 0 = none (the reap path).
    /// Process-scope like the text aperture: inherited by every
    /// `sys_thread` task, cleared at create and at exec (a new image must
    /// re-register — the old PC is meaningless under the new text).
    exnotify_handler: u64 = 0,
    /// Arc5 issue #246: per-process resource limits.
    /// mem_limit: max pages (0 = unlimited). cpu_limit: max ticks (0 = unlimited).
    /// mem_usage: current page count (charged dynamic pages — #2115).
    /// cpu_usage: tick counter. mem_refused: a charge was denied by the
    /// limit since the last setrlimit — the fault path reads it to name the
    /// kill 140 instead of a generic 139.
    mem_limit: u64 = 0,
    cpu_limit: u64 = 0,
    mem_usage: u64 = 0,
    cpu_usage: u64 = 0,
    mem_refused: bool = false,
};

var processes: [max_processes]Process = [_]Process{.{}} ** max_processes;
var registry_count: usize = 0;
/// The most recently created process (the "current" program — what
/// `exec.loaded()` reports).
var current_id: ?usize = null;
/// Card 3d (claim 1014): the process exit reports are a bounded FIFO, not
/// a single first-wins flag — N exits in one idle-loop window produce N
/// `procs <name> exited status=N` lines IN ORDER instead of collapsing to
/// one. The name is snapshotted at exit (the descriptor may be recycled
/// before the shell prints it). Overflow (a full ring) drops the OLDEST
/// entry to admit the newest — documented and host-tested.
/// depth of the PROCESS-level exit-report ring (`procs <name> exited
/// status=`) — kept in lockstep with the scheduler's task-level ring (8,
/// was 4, issue #1020): five wasm execs exit inside one drain window and a
/// full ring drops the oldest (floatapp's 590 was lost).
pub const exit_report_max: usize = 8;
var exit_report_names: [exit_report_max][name_max]u8 = [_][name_max]u8{[_]u8{0} ** name_max} ** exit_report_max;
var exit_report_lens: [exit_report_max]usize = [_]usize{0} ** exit_report_max;
var exit_report_statuses: [exit_report_max]u64 = [_]u64{0} ** exit_report_max;
var exit_report_head: usize = 0;
var exit_report_count: usize = 0;

// ---------------------------------------------------------------------------
// Claim 9094 (#810 writer hunt): audit cells for the scheduler's task-ring
// audit (the Process struct stays module-private — primitives only, no
// pointers escape this module). The scheduler validates the invariants;
// every read happens here, so a rogue byte in the registry can never fault
// the audit itself.
// ---------------------------------------------------------------------------

pub const ProcAuditCell = struct {
    name_len: usize = 0,
    /// Raw state byte (0..3 = free/created/running/exited).
    state: u8 = 0,
    /// The live executor slot, or null (free / exited-and-reaped).
    task_id: ?usize = null,
    kstack_phys: u64 = 0,
    text_phys: u64 = 0,
    stack_phys: u64 = 0,
};

/// One audit cell per registry row. Raw byte read for the state enum
/// (the typed load of a rogue byte as an enum is UB in safe builds).
pub fn audit_proc(id: usize) ProcAuditCell {
    if (id >= max_processes) return .{};
    const p = &processes[id];
    const raw_state: u8 = @as(*const u8, @ptrCast(&p.state)).*;
    return .{
        .name_len = p.name_len,
        .state = raw_state,
        .task_id = p.task_id,
        .kstack_phys = p.kernel_stack.phys,
        .text_phys = p.addr_space.text_phys,
        .stack_phys = p.addr_space.stack_phys,
    };
}

/// Zero a registry slot in place (issue #1333). `p.* = .{}` and
/// `processes[id] = .{}` copy a full `Process` (~34 KiB, dominated by
/// `AddrSpace.dynamic_pages`) onto the caller's stack — the same overflow
/// as passing `AddrSpace` by value. `@memset` writes the BSS slot directly.
fn reset_process(p: *Process) void {
    @memset(std.mem.asBytes(p), 0);
    p.addr_space.mmap_next_va = mmap_default_va;
    p.uid = uid_user;
    p.task_id = null;
    p.thread_tasks = [_]?usize{null} ** max_threads;
}

fn apply_spec(space: *AddrSpace, spec: AddrSpaceSpec) void {
    space.root_phys = spec.root_phys;
    space.text_va = spec.text_va;
    space.text_len = spec.text_len;
    space.text_phys = spec.text_phys;
    space.text_pages = spec.text_pages;
    space.data_va = spec.data_va;
    space.data_len = spec.data_len;
    space.data_phys = spec.data_phys;
    space.data_pages = spec.data_pages;
    space.stack_va = spec.stack_va;
    space.stack_len = spec.stack_len;
    space.stack_phys = spec.stack_phys;
    space.stack_pages = spec.stack_pages;
    space.interp_phys = spec.interp_phys;
    space.interp_pages = spec.interp_pages;
    space.ro_phys = spec.ro_phys;
    space.ro_pages = spec.ro_pages;
    space.ro_va = spec.ro_va;
    space.argv_end_va = spec.argv_end_va;
    space.lib_phys = spec.lib_phys;
    space.lib_pages = spec.lib_pages;
}

/// Reset the registry (boot + host tests; called by `scheduler.init` so
/// every pool reset also clears the process layer).
pub fn init() void {
    for (&processes) |*p| reset_process(p);
    registry_count = 0;
    current_id = null;
    exit_report_head = 0;
    exit_report_count = 0;
}

/// Free the allocator-backed pages a process's address space + kernel
/// stack own (no-op for the static boot payload's pages and when the
/// allocator is unarmed — host tests). Only ever called for a non-live
/// process (reap / recycle of `exited`/`created`), so a running program's
/// pages are never freed under it. Claim 4613: also called at the task-
/// level reap (`release_pages_on_reap`) — the freed page fields are
/// zeroed there so a later `release_resources` is a no-op.
fn release_resources(p: *Process) void {
    if (p.addr_space.text_pages > 0) _ = alloc.free_pages(p.addr_space.text_phys, p.addr_space.text_pages);
    if (p.addr_space.data_pages > 0) _ = alloc.free_pages(p.addr_space.data_phys, p.addr_space.data_pages);
    if (p.addr_space.interp_pages > 0) _ = alloc.free_pages(p.addr_space.interp_phys, p.addr_space.interp_pages);
    if (p.addr_space.lib_pages > 0) _ = alloc.free_pages(p.addr_space.lib_phys, p.addr_space.lib_pages);
    if (p.addr_space.ro_pages > 0) _ = alloc.free_pages(p.addr_space.ro_phys, p.addr_space.ro_pages);
    if (p.addr_space.stack_pages > 0) _ = alloc.free_pages(p.addr_space.stack_phys, p.addr_space.stack_pages);
    if (p.kernel_stack.pages > 0) _ = alloc.free_pages(p.kernel_stack.phys, p.kernel_stack.pages);
    // M29 VM Depth: unref/free all dynamically faulted and mmap'd pages
    var i: usize = 0;
    while (i < @min(p.addr_space.dynamic_page_count, max_dynamic_pages)) : (i += 1) {
        const pa = p.addr_space.dynamic_pages[i];
        if (pa != 0) _ = alloc.unref_page(pa);
    }
    var block = p.addr_space.dynamic_head;
    while (block) |b| {
        for (b.pages[0..b.count]) |pa| {
            if (pa != 0) _ = alloc.unref_page(pa);
        }
        block = b.next;
        _ = alloc.free_pages(@intFromPtr(b), 1);
    }
    p.addr_space.dynamic_head = null;
    p.addr_space.dynamic_tail = null;
    p.addr_space.dynamic_page_count = 0;
    p.addr_space.mmap_region_count = 0;
    @memset(&p.addr_space.mmap_regions, MmapRegion{});
    p.mem_usage = 0;
    // #2116: the process's page-table tree dies with it — every table the
    // root reaches is a per-root allocation (the identity clone copies, it
    // never shares), so the whole subtree returns to the carve-out free
    // list. Zeroed so the registry-level release_resources is a no-op
    // (same idiom as the page fields above).
    if (p.addr_space.root_phys != 0) _ = mmu.free_table_tree(p.addr_space.root_phys);
    p.addr_space.root_phys = 0;
}

pub fn add_mmap_region(pid: usize, va: u64, len: u64, prot: u64, flags: u64) bool {
    const taken = svclock.acquire_missing(svclock.dom_bit(.kernel));
    defer svclock.release_set(taken);
    if (pid >= max_processes or processes[pid].state == .free) return false;
    var space = &processes[pid].addr_space;
    if (space.mmap_region_count >= max_mmap_regions) return false;
    for (&space.mmap_regions) |*r| {
        if (r.len == 0) {
            r.* = .{ .base_va = va, .len = len, .prot = prot, .flags = flags };
            space.mmap_region_count += 1;
            processes[pid].runtime_usage.peak_regions = @max(processes[pid].runtime_usage.peak_regions, space.mmap_region_count);
            return true;
        }
    }
    return false;
}

pub fn remove_mmap_region(pid: usize, va: u64, len: u64) bool {
    const taken = svclock.acquire_missing(svclock.dom_bit(.kernel));
    defer svclock.release_set(taken);
    if (pid >= max_processes or processes[pid].state == .free) return false;
    var space = &processes[pid].addr_space;
    for (&space.mmap_regions) |*r| {
        if (r.base_va == va and (len == 0 or r.len == len)) {
            r.* = .{};
            space.mmap_region_count -%= 1;
            return true;
        }
    }
    return false;
}

pub fn find_mmap_region(pid: usize, va: u64) ?*const MmapRegion {
    if (pid >= max_processes or processes[pid].state == .free) return null;
    const space = &processes[pid].addr_space;
    for (&space.mmap_regions) |*r| {
        if (r.len > 0 and va >= r.base_va and va < r.base_va + r.len) {
            return r;
        }
    }
    return null;
}

/// The `index`-th live mmap region of `pid`, or null. ADR 0027 review
/// (finding 2): `arm_task_regions` merges these PROCESS-scope regions into
/// every task's uaccess view, so a mapping is visible to all of the
/// process's tasks regardless of which M created it or when.
pub fn mmap_region_at(pid: usize, index: usize) ?MmapRegion {
    if (pid >= max_processes or processes[pid].state == .free) return null;
    if (index >= max_mmap_regions) return null;
    const r = processes[pid].addr_space.mmap_regions[index];
    if (r.len == 0) return null;
    return r;
}

/// Issue #1214: does [va, va+len) overlap ANY region the process already
/// owns — the exec apertures (text, rodata, data, stack) or a previously
/// registered mmap region? handle_mmap refuses such mappings with EINVAL
/// instead of aliasing them: the GOOS=virelai sbrk heap once swallowed the
/// randomized stack aperture (its reservation spanned ~1.2 GiB upward from
/// the image end), and the runtime's arena trims then memclr'd the live
/// EL0 stack — the go-args boot flake. Both ranges are page-granular, so a
/// plain end-of-one/start-of-next adjacency is NOT a collision.
/// The mapped byte span of an exec aperture for `mmap_collides`: the
/// page-rounded image length. The gap path's extra argv-headroom page (the
/// data segment's `+1` page) is deliberately EXCLUDED — the GOOS=virelai
/// sbrk heap starts at `memRound(firstmoduledata.end)`, which lands on that
/// page by design, and nothing else the image needs lives in it. The packed
/// argv+envp region is the exception: `mmap_collides` extends the data
/// aperture through `argv_end_va` precisely because an exactly page-aligned
/// `mem_size` puts the block ON the excluded page (issue #1214 review / #1226).
fn aperture_span(base: u64, byte_len: u64) u64 {
    if (base == 0) return 0;
    return (byte_len + 4095) & ~@as(u64, 4095);
}

pub fn mmap_collides(pid: usize, va: u64, len: u64) bool {
    if (pid >= max_processes or processes[pid].state == .free) return true;
    const space = &processes[pid].addr_space;
    const start = va;
    // #2092: compute the end wrap-safely — a hint near 2^64 wraps `end`
    // below `start` and every overlap test below then passes trivially,
    // letting the range alias whatever it wants. Refuse the wrap itself.
    const end = va +% len;
    if (len != 0 and end <= start) return true;
    // Protect the data aperture through the packed argv+envp region, not
    // just to the page-rounded image end: on an exactly page-aligned
    // `mem_size` the block starts at the headroom page and the sbrk break
    // would otherwise swallow it.
    var data_len = aperture_span(space.data_va, space.data_len);
    if (space.argv_end_va > space.data_va) data_len = @max(data_len, space.argv_end_va - space.data_va);
    const apertures = [_]struct { base: u64, len: u64 }{
        .{ .base = space.text_va, .len = aperture_span(space.text_va, space.text_len) },
        .{ .base = space.ro_va, .len = space.ro_pages * 4096 },
        .{ .base = space.data_va, .len = data_len },
        .{ .base = space.stack_va, .len = aperture_span(space.stack_va, space.stack_len) },
    };
    for (apertures) |ap| {
        if (ap.len == 0) continue;
        if (start < ap.base + ap.len and end > ap.base) return true;
    }
    for (&space.mmap_regions) |*r| {
        if (r.len == 0) continue;
        if (start < r.base_va + r.len and end > r.base_va) return true;
    }
    return false;
}

/// Counter/ownership mutations share the existing kernel-domain lock with
/// live receipt reads. The fault/populate path already holds it: nested
/// helpers take/release nothing, so there is no new fault-path lock.
pub fn record_dynamic_page(pid: usize, pa: u64) bool {
    const taken = svclock.acquire_missing(svclock.dom_bit(.kernel));
    defer svclock.release_set(taken);
    if (pid >= max_processes or processes[pid].state == .free) return false;
    // #2115: the memory rlimit finally bites — the single charge point
    // every allocation funnels through (demand populate, COW promotion,
    // MAP_POPULATE, shared-surface create). A process AT its page ceiling
    // is refused loudly: mem_refused names the 140 verdict on the fault
    // path that delivers it.
    if (processes[pid].mem_limit != 0 and processes[pid].mem_usage >= processes[pid].mem_limit) {
        processes[pid].mem_refused = true;
        processes[pid].runtime_usage.record_failures += 1;
        return false;
    }
    var space = &processes[pid].addr_space;
    if (space.dynamic_page_count < max_dynamic_pages) {
        space.dynamic_pages[space.dynamic_page_count] = pa;
    } else {
        if (space.dynamic_tail == null or space.dynamic_tail.?.count == space.dynamic_tail.?.pages.len) {
            const block_pa = alloc.alloc_pages(1) orelse {
                processes[pid].runtime_usage.record_failures += 1;
                return false;
            };
            const block: *DynamicPageBlock = @ptrFromInt(block_pa);
            block.next = null;
            block.prev = space.dynamic_tail;
            block.count = 0;
            if (space.dynamic_tail) |tail| tail.next = block else space.dynamic_head = block;
            space.dynamic_tail = block;
        }
        const tail = space.dynamic_tail.?;
        tail.pages[tail.count] = pa;
        tail.count += 1;
    }
    space.dynamic_page_count += 1;
    update_mem_usage(pid, 1);
    processes[pid].runtime_usage.total_pages += 1;
    processes[pid].runtime_usage.peak_pages = @max(processes[pid].runtime_usage.peak_pages, space.dynamic_page_count);
    return true;
}

fn dynamic_page_entry(pid: usize, pa: u64) ?*u64 {
    if (pid >= max_processes or processes[pid].state == .free) return null;
    const space = &processes[pid].addr_space;
    for (space.dynamic_pages[0..@min(space.dynamic_page_count, max_dynamic_pages)]) |*entry| {
        if (entry.* == pa) return entry;
    }
    var block = space.dynamic_head;
    while (block) |b| {
        for (b.pages[0..b.count]) |*entry| {
            if (entry.* == pa) return entry;
        }
        block = b.next;
    }
    return null;
}

/// Remove ownership BEFORE unref/reallocation. Compact with the last record,
/// returning empty overflow blocks immediately; no stale address survives.
pub fn forget_dynamic_page(pid: usize, pa: u64) bool {
    const taken = svclock.acquire_missing(svclock.dom_bit(.kernel));
    defer svclock.release_set(taken);
    const entry = dynamic_page_entry(pid, pa) orelse return false;
    const space = &processes[pid].addr_space;
    if (space.dynamic_tail) |tail| {
        entry.* = tail.pages[tail.count - 1];
        tail.count -= 1;
        if (tail.count == 0) {
            space.dynamic_tail = tail.prev;
            if (tail.prev) |prev| prev.next = null else space.dynamic_head = null;
            _ = alloc.free_pages(@intFromPtr(tail), 1);
        }
    } else {
        entry.* = space.dynamic_pages[space.dynamic_page_count - 1];
        space.dynamic_pages[space.dynamic_page_count - 1] = 0;
    }
    space.dynamic_page_count -= 1;
    update_mem_usage(pid, -1);
    return true;
}

/// COW replaces an owned record in place, without requiring an extra slot.
/// A borrowed peer page has no record: its new private copy needs one.
pub fn replace_dynamic_page(pid: usize, old_pa: u64, new_pa: u64) bool {
    const taken = svclock.acquire_missing(svclock.dom_bit(.kernel));
    defer svclock.release_set(taken);
    if (dynamic_page_entry(pid, old_pa)) |entry| {
        entry.* = new_pa;
        processes[pid].runtime_usage.total_pages += 1;
        return true;
    }
    return record_dynamic_page(pid, new_pa);
}

pub fn owns_dynamic_page(pid: usize, pa: u64) bool {
    return dynamic_page_entry(pid, pa) != null;
}

/// Shared peer teardown is keyed by its root, not the currently running task.
pub fn forget_dynamic_page_in_root(root: u64, pa: u64) void {
    for (&processes, 0..) |*p, pid| {
        if (p.state != .free and p.addr_space.root_phys == root) {
            _ = forget_dynamic_page(pid, pa);
            return;
        }
    }
}

pub fn next_mmap_va(pid: usize, len: u64) u64 {
    if (pid >= max_processes) return mmap_default_va;
    var space = &processes[pid].addr_space;
    const aligned_len = (len + 4095) & ~@as(u64, 4095);
    const va = space.mmap_next_va;
    space.mmap_next_va += aligned_len;
    return va;
}

/// Create a process for a loaded program with the DEFAULT principal
/// (`uid_user`, no caps — ADR 0024 D5). See `create_as`.
pub fn create(
    name: []const u8,
    image: Image,
    addr_space: AddrSpaceSpec,
    kernel_stack: KernelStack,
) ?usize {
    return create_as(name, image, addr_space, kernel_stack, default_principal);
}

/// Create a process with an explicit principal. `name` is copied into the
/// descriptor (the caller's slice need not outlive the call); `addr_space`
/// is a small scalar spec (issue #1333 — never a full `AddrSpace`) and
/// `kernel_stack` records the pages the process owns. Takes the first
/// free slot; when the registry is full, recycles the OLDEST exited
/// process (never a created/running one) and frees its owned pages.
/// Returns null only when every slot holds a live (created/running)
/// process. M50 TS1 (#1135): `actor` is stored on the descriptor;
/// `exec` preserves it, and no syscall can change it.
pub fn create_as(
    name: []const u8,
    image: Image,
    addr_space: AddrSpaceSpec,
    kernel_stack: KernelStack,
    actor: Principal,
) ?usize {
    const taken = svclock.acquire_missing(svclock.dom_bit(.kernel));
    defer svclock.release_set(taken);
    var id: usize = 0;
    var oldest_exited: ?usize = null;
    while (id < max_processes) : (id += 1) {
        if (processes[id].state == .free) break;
        if (processes[id].state == .exited and oldest_exited == null) oldest_exited = id;
    }
    if (id >= max_processes) {
        // Registry full: recycle the oldest exited descriptor (never a
        // live process — a live one still owns its program). Its
        // allocator-backed pages are freed with it.
        const recycled = oldest_exited orelse return null;
        release_resources(&processes[recycled]);
        reset_process(&processes[recycled]);
        registry_count -%= 1;
        id = recycled;
    }
    const take = @min(name.len, name_max);
    @memcpy(processes[id].name_buf[0..take], name[0..take]);
    processes[id].name_len = take;
    processes[id].image = image;
    apply_spec(&processes[id].addr_space, addr_space);
    // RW backing may include an extra argv page. Count the segment's memsz,
    // not that loader headroom; ro_pages is already the rounded R segment.
    processes[id].runtime_usage.static_pages = segment_pages(addr_space.text_len) +
        addr_space.ro_pages + segment_pages(addr_space.data_len);
    processes[id].kernel_stack = kernel_stack;
    processes[id].uid = actor.uid;
    processes[id].caps = actor.caps;
    processes[id].state = .created;
    // Issue #1228: a fresh (or recycled) descriptor carries no fault
    // handler — the new image registers its own via slot 75.
    processes[id].exnotify_handler = 0;
    registry_count +%= 1;
    current_id = id;
    return id;
}

fn segment_pages(byte_len: u64) u64 {
    return byte_len / 4096 + @intFromBool(byte_len % 4096 != 0);
}

/// A running or exited process's non-consuming receipt. Copy under the same
/// kernel-domain lock as backing/region updates, exit and resource release:
/// total_pages and peak_pages cannot come from different updates. Saturation
/// is derived from that copied peak, never from the current ownership count.
/// Callers reading identity/reaped state also hold the lock across `info` and
/// this copy. Created/invalid/free rows have no receipt. Task reap preserves
/// the counters; registry reap/recycle discards them without delaying release.
pub fn runtime_receipt(id: usize) ?RuntimeReceipt {
    const taken = svclock.acquire_missing(svclock.dom_bit(.kernel));
    defer svclock.release_set(taken);
    if (id >= max_processes) return null;
    if (processes[id].state != .running and processes[id].state != .exited) return null;
    return processes[id].runtime_usage;
}

/// One small, coherent read-only memory/identity snapshot. Never copy the
/// ownership array or clamp its extensible count to the inline capacity.
pub fn memory_snapshot(id: usize) ?struct {
    actor: Principal,
    exited: bool,
    receipt: RuntimeReceipt,
    live_pages: u64 = 0,
    live_regions: u64 = 0,
    text_bytes: u64 = 0,
    ro_bytes: u64 = 0,
    data_bytes: u64 = 0,
    stack_bytes: u64 = 0,
    region_sizes: [max_mmap_regions]u64 = [_]u64{0} ** max_mmap_regions,
} {
    const taken = svclock.acquire_missing(svclock.dom_bit(.kernel));
    defer svclock.release_set(taken);
    if (id >= max_processes or processes[id].state == .free) return null;
    const p = &processes[id];
    var result: @typeInfo(@typeInfo(@TypeOf(memory_snapshot)).@"fn".return_type.?).optional.child = .{
        .actor = .{ .uid = p.uid, .caps = p.caps },
        .exited = p.state == .exited,
        .receipt = p.runtime_usage,
    };
    if (result.exited) return result;
    const space = &p.addr_space;
    result.live_pages = space.dynamic_page_count;
    result.live_regions = space.mmap_region_count;
    result.text_bytes = aperture_span(space.text_va, space.text_len);
    result.ro_bytes = space.ro_pages * 4096;
    result.data_bytes = aperture_span(space.data_va, space.data_len);
    if (space.argv_end_va > space.data_va) result.data_bytes = @max(result.data_bytes, space.argv_end_va - space.data_va);
    result.stack_bytes = aperture_span(space.stack_va, space.stack_len);
    var index: usize = 0;
    for (space.mmap_regions) |region| {
        if (region.len == 0) continue;
        result.region_sizes[index] = region.len;
        index += 1;
    }
    return result;
}

/// The principal a process was created with (ADR 0024 D2). Returns null for
/// an invalid or free id. This is the ONLY principal accessor — there is no
/// setter, because no syscall may change uid/caps.
pub fn principal(id: usize) ?Principal {
    if (id >= max_processes or processes[id].state == .free) return null;
    return .{ .uid = processes[id].uid, .caps = processes[id].caps };
}

/// Bind a created process to its executor task slot (state -> running).
/// Returns false for an invalid id or a process that is not `created`.
pub fn bind(id: usize, task_id: usize) bool {
    if (id >= max_processes or processes[id].state != .created) return false;
    // Claim 9498 follow-on: publish the task_id BEFORE the .running state
    // bit — a concurrent reader on another core (find_by_task under a
    // syscall) keys off .running and must never observe a stale task_id
    // (a torn read that would route its work at the wrong process).
    processes[id].task_id = task_id;
    processes[id].state = .running;
    processes[id].live_tasks = 1;
    return true;
}

/// M97g (#2085): record the spawning pid on a fresh process descriptor.
/// The caller (exec) derives it from the task's spawn provenance; null
/// marks a kernel-context spawn. Called once, at bind — before publish.
pub fn set_spawner(id: usize, pid: ?usize) void {
    if (id >= max_processes or processes[id].state == .free) return;
    processes[id].spawner = pid;
}

/// M97g (#2085): an APPLOG/CRASH label binds to a process name modulo a
/// trailing ".ELF" — the receipt/log label is the service name while the
/// recorded process name is the image's file name ("GSCHK" vs
/// "GSCHK.ELF"; selftest uses the full "GOSELF.ELF" either way).
pub fn label_stem(name_or_label: []const u8) []const u8 {
    const suffix = ".ELF";
    if (name_or_label.len > suffix.len and
        std.ascii.eqlIgnoreCase(name_or_label[name_or_label.len - suffix.len ..], suffix))
        return name_or_label[0 .. name_or_label.len - suffix.len];
    return name_or_label;
}

/// M97g (#2085): does the registry hold a process row whose name binds to
/// `label` AND which `pid` spawned? Exited rows count — a supervisor
/// writes the child's receipt after the child died. The kernel-spawned
/// class (spawner null) can never match an EL0 caller.
pub fn spawned_label(label: []const u8, pid: usize) bool {
    if (label.len == 0) return false;
    const stem = label_stem(label);
    var id: usize = 0;
    while (id < max_processes) : (id += 1) {
        const p = &processes[id];
        if (p.state == .free or p.spawner != pid) continue;
        if (std.ascii.eqlIgnoreCase(label_stem(p.name_buf[0..p.name_len]), stem)) return true;
    }
    return false;
}

/// ADR 0027 D3: bind ONE MORE task to a RUNNING process (a thread created
/// via `sys_thread` op 0). The thread inherits the process's principal and
/// address space; the descriptor bounds the count (`max_threads`) and the
/// task pool bounds it further. Returns false for an invalid/stopped
/// process, a full thread list, or a task already bound.
pub fn bind_thread(id: usize, task_id: usize) bool {
    if (id >= max_processes or processes[id].state != .running) return false;
    if (processes[id].task_id == task_id) return false;
    for (&processes[id].thread_tasks) |*t| {
        if (t.* == task_id) return false;
    }
    for (&processes[id].thread_tasks) |*t| {
        if (t.* == null) {
            t.* = task_id;
            processes[id].live_tasks += 1;
            return true;
        }
    }
    return false;
}

/// The primary task slot of a running process (its creator task), if any.
pub fn primary_task(id: usize) ?usize {
    if (id >= max_processes or processes[id].state != .running) return null;
    return processes[id].task_id;
}

/// ADR 0027 D3: does the running process have a free thread seat?
pub fn has_thread_capacity(id: usize) bool {
    if (id >= max_processes or processes[id].state != .running) return false;
    for (&processes[id].thread_tasks) |*t| {
        if (t.* == null) return true;
    }
    return false;
}

/// Issue #1228 (phase 0c): the registered EL0 fault-handler PC (0 =
/// none). Read by the exception path to decide delivery vs reap.
pub fn exnotify_handler(id: usize) ?u64 {
    if (id >= max_processes or processes[id].state == .free) return null;
    return processes[id].exnotify_handler;
}

/// Issue #1228 (phase 0c): install (or, with 0, clear) the process's EL0
/// fault-handler PC. Returns false for an invalid id or a free/exited
/// descriptor — a dead process registers nothing.
pub fn set_exnotify_handler(id: usize, handler: u64) bool {
    if (id >= max_processes or processes[id].state == .free) return false;
    if (processes[id].state == .exited) return false;
    processes[id].exnotify_handler = handler;
    return true;
}

/// Free a process descriptor. Only a non-running process may be reaped:
/// `created` (the exec rollback path — spawn failed after create) or
/// `exited` (the lifecycle reap / registry recycle). Returns false for an
/// invalid id or a live (running) process. The process's allocator-backed
/// pages (text/stack/kernel-stack) are freed with it.
pub fn reap(id: usize) bool {
    const taken = svclock.acquire_missing(svclock.dom_bit(.kernel));
    defer svclock.release_set(taken);
    if (id >= max_processes) return false;
    if (processes[id].state == .free or processes[id].state == .running) return false;
    if (current_id == id) current_id = null;
    release_resources(&processes[id]);
    reset_process(&processes[id]);
    registry_count -%= 1;
    return true;
}

/// Notify the registry that the task in slot `task_id` exited with
/// `status` (called from the scheduler's `exit_current` — exception
/// context, so this must stay console-free and allocation-free).
/// ADR 0027 D1/D2 (issue #1214 round): a process may carry several live
/// tasks. This call decrements the live count; the process transitions to
/// `exited` only when the LAST task leaves. `request_process_exit`
/// snapshots the status the process will report (the first sys_exit /
/// fault / kill wins) — the last task out uses it, so a dying process's
/// waiters observe the REQUESTED status, not some sibling's. The process
/// keeps the exiting slot in `task_id` for the lifecycle reap to free the
/// owned pages. Returns the pid on the process-exit transition (so the
/// scheduler wakes `sys_wait` waiters), null otherwise. No-op for a task
/// bound to no live process.
pub fn on_task_exit(task_id: usize, status: u64) ?usize {
    const taken = svclock.acquire_missing(svclock.dom_bit(.kernel));
    defer svclock.release_set(taken);
    var id: usize = 0;
    while (id < max_processes) : (id += 1) {
        if (processes[id].state != .running) continue;
        const is_primary = processes[id].task_id == task_id;
        var is_thread = false;
        for (&processes[id].thread_tasks) |*t| {
            if (t.* == task_id) {
                t.* = null;
                is_thread = true;
                break;
            }
        }
        if (!is_primary and !is_thread) continue;
        processes[id].live_tasks -= 1;
        if (processes[id].live_tasks > 0) {
            // A thread (or the primary with threads still alive) left. If
            // the PRIMARY left, clear its slot so `find_by_task` never
            // matches a dead primary while the descriptor stays running.
            if (is_primary) processes[id].task_id = null;
            return null;
        }
        // LAST task out: the process dies. The exit status is the FIRST
        // requested exit status (sys_exit/fault/kill snapshot) when one was
        // requested, else this task's own status (a pure thread-model exit
        // of the last task).
        const final_status: u64 = if (processes[id].exit_requested)
            processes[id].exit_status_snapshot
        else
            status;
        processes[id].state = .exited;
        processes[id].exit_status = final_status;
        // Claim 4613: the lifecycle reap keys the page release on the LAST
        // exiting task's slot.
        processes[id].task_id = task_id;
        // Card 3d (claim 1014): EVERY exit is queued — two exits in one
        // idle-loop window print as two lines in order (the old
        // first-wins-while-undrained flag collapsed them). A full ring
        // drops the oldest to admit the newest.
        push_exit_report(processes[id].name_buf[0..processes[id].name_len], final_status);
        return id;
    }
    return null;
}

/// ADR 0027 D2: request the WHOLE process to die (a `sys_exit`, fault, or
/// kill on any task of a multi-task process). The first request wins and
/// snapshots the status; the scheduler arms the sibling tasks' kills (its
/// responsibility — it owns the task states). Single-task processes set
/// the same state and exit with their own status immediately, so this is
/// behavior-neutral for every pre-thread shape.
pub fn request_process_exit(task_id: usize, status: u64) ?usize {
    const id = find_by_task(task_id) orelse return null;
    if (!processes[id].exit_requested) {
        processes[id].exit_requested = true;
        processes[id].exit_status_snapshot = status;
    }
    return id;
}

/// Free the allocator-backed pages of the exited process that last ran on
/// executor slot `task_id` — called by the scheduler's idle-task reap
/// (claim 4613): the program is dead and its executor slot is being
/// recycled, so its text/stack/exception-stack pages return to the
/// physical allocator NOW, while the exited descriptor (name, status,
/// stack VA) STAYS in the `procs` table for the claim-3848 exit record.
/// The page fields are zeroed so a later registry recycle's
/// `release_resources` is a no-op. Returns false when no exited process
/// is bound to that slot (already reaped, or the descriptor was recycled
/// by `create`).
pub fn release_pages_on_reap(task_id: usize) bool {
    const taken = svclock.acquire_missing(svclock.dom_bit(.kernel));
    defer svclock.release_set(taken);
    var id: usize = 0;
    while (id < max_processes) : (id += 1) {
        if (processes[id].state != .exited) continue;
        if (processes[id].task_id != task_id) continue;
        release_resources(&processes[id]);
        processes[id].addr_space.text_phys = 0;
        processes[id].addr_space.text_pages = 0;
        processes[id].addr_space.data_phys = 0;
        processes[id].addr_space.data_pages = 0;
        processes[id].addr_space.interp_phys = 0;
        processes[id].addr_space.interp_pages = 0;
        processes[id].addr_space.lib_phys = 0;
        processes[id].addr_space.lib_pages = 0;
        processes[id].addr_space.ro_phys = 0;
        processes[id].addr_space.ro_pages = 0;
        processes[id].addr_space.stack_phys = 0;
        processes[id].addr_space.stack_pages = 0;
        processes[id].kernel_stack = .{};
        processes[id].task_id = null;
        return true;
    }
    return false;
}

/// The most recently created process id (what `exec.loaded()` reports);
/// null before any process exists.
pub fn current() ?usize {
    return current_id;
}

/// The process currently bound to pool slot `task_id`, if any — the
/// PRIMARY executor slot or one of its ADR 0027 thread slots.
pub fn find_by_task(task_id: usize) ?usize {
    var id: usize = 0;
    while (id < max_processes) : (id += 1) {
        if (processes[id].state != .running) continue;
        if (processes[id].task_id == task_id) return id;
        for (&processes[id].thread_tasks) |*t| {
            if (t.* == task_id) return id;
        }
    }
    return null;
}

/// Non-free descriptor count.
pub fn count() usize {
    return registry_count;
}

/// A copy of a process descriptor's public view (the name slice points at
/// the registry's owned buffer and stays valid until the process is
/// reaped).
pub const ProcessInfo = struct {
    id: usize,
    name: []const u8,
    /// M50 TS1 (#1135): the process principal (uid + caps). Reported by the
    /// monitor; NOT part of the 40-byte `sys_procs` snapshot row. The uid
    /// default matches `Process.uid` (`uid_user`), never `uid_system`.
    uid: u32 = uid_user,
    caps: u32 = 0,
    state: State,
    task_id: ?usize,
    entry_va: u64,
    content_len: u64,
    root_phys: u64,
    text_phys: u64,
    text_pages: u64,
    /// ADR 0027 D3 (issue #1214 round 2): the executable aperture's user VA
    /// span — sys_thread create validates the child PC against it.
    text_va: u64 = 0,
    text_len: u64 = 0,
    data_va: u64,
    data_len: u64,
    data_phys: u64,
    data_pages: u64,
    stack_va: u64,
    stack_len: u64,
    stack_phys: u64,
    stack_pages: u64,
    kernel_stack_phys: u64,
    kernel_stack_pages: u64,
    exit_status: u64,
    /// Arc5 #246 usage counter (scheduler tick increments; M22 D6 exposes
    /// it in the ps table's CPU column).
    cpu_usage: u64 = 0,
};

// ---------------------------------------------------------------------------
// Card 4a (claim 5799): the bounded EL0-readable process snapshot
// ---------------------------------------------------------------------------

/// Fixed width of one snapshot row (40 bytes): `u64 pid` (LE) at 0, `u64`
/// state code at 8 (the `State` enum value: 1=created, 2=running,
/// 3=exited), `u64 exit_status` at 16 (0 unless exited), `name` (16 bytes,
/// NUL-padded — the `name_max` bound) at 24. Fixed width is what makes
/// `sys_procs`'s `max`-byte truncation honest: `max` floors to WHOLE rows.
pub const snapshot_row_bytes: usize = 40;
/// The name field's width inside a row (the registry's `name_max`).
pub const snapshot_name_bytes: usize = name_max;

/// Marshal every NON-FREE descriptor (created/running/exited — free rows
/// are skipped) into `dst` as fixed-width rows, in id order. Returns the
/// row count. The caller (the syscall layer) passes a fixed BSS scratch of
/// at least `max_processes * snapshot_row_bytes` bytes — no allocation
/// anywhere. The exit status column is only meaningful for exited rows
/// (the status is snapshotted at exit and survives the reap — claim
/// 3848), so an EL0 reader can tell a live peer from a dead one.
pub fn snapshot(dst: []u8) usize {
    var rows: usize = 0;
    var id: usize = 0;
    while (id < max_processes) : (id += 1) {
        if (processes[id].state == .free) continue;
        const row = dst[rows * snapshot_row_bytes ..][0..snapshot_row_bytes];
        std.mem.writeInt(u64, row[0..8], id, .little);
        std.mem.writeInt(u64, row[8..16], @intFromEnum(processes[id].state), .little);
        std.mem.writeInt(u64, row[16..24], processes[id].exit_status, .little);
        @memset(row[24..snapshot_row_bytes], 0);
        const take = @min(processes[id].name_len, snapshot_name_bytes);
        const name_start: usize = 24;
        const name_end: usize = name_start + take;
        @memcpy(row[name_start..name_end], processes[id].name_buf[0..take]);
        rows += 1;
    }
    return rows;
}

pub fn info(id: usize) ?ProcessInfo {
    if (id >= max_processes or processes[id].state == .free) return null;
    const p = &processes[id];
    return .{
        .id = id,
        .name = p.name_buf[0..p.name_len],
        .uid = p.uid,
        .caps = p.caps,
        .state = p.state,
        .task_id = p.task_id,
        .entry_va = p.image.entry_va,
        .content_len = p.image.content_len,
        .root_phys = p.addr_space.root_phys,
        .text_phys = p.addr_space.text_phys,
        .text_pages = p.addr_space.text_pages,
        .text_va = p.addr_space.text_va,
        .text_len = p.addr_space.text_len,
        .data_va = p.addr_space.data_va,
        .data_len = p.addr_space.data_len,
        .data_phys = p.addr_space.data_phys,
        .data_pages = p.addr_space.data_pages,
        .stack_va = p.addr_space.stack_va,
        .stack_len = p.addr_space.stack_len,
        .stack_phys = p.addr_space.stack_phys,
        .stack_pages = p.addr_space.stack_pages,
        .kernel_stack_phys = p.kernel_stack.phys,
        .kernel_stack_pages = p.kernel_stack.pages,
        .exit_status = p.exit_status,
        .cpu_usage = p.cpu_usage,
    };
}

/// The pending process exit reports, drained IN ORDER by the shell idle
/// loop (which prints `procs <name> exited status=<n>` per entry). Returns
/// null when nothing is pending.
pub const ExitReport = struct {
    name: []const u8,
    status: u64,
};

/// Queue one exit report (exception/idle context — pure BSS writes).
/// Overflow drops the OLDEST entry (documented + host-tested).
fn push_exit_report(name: []const u8, status: u64) void {
    if (exit_report_count == exit_report_max) {
        exit_report_head = (exit_report_head + 1) % exit_report_max;
        exit_report_count -= 1;
    }
    const index = (exit_report_head + exit_report_count) % exit_report_max;
    const take = @min(name.len, name_max);
    @memcpy(exit_report_names[index][0..take], name[0..take]);
    exit_report_lens[index] = take;
    exit_report_statuses[index] = status;
    exit_report_count += 1;
}

pub fn take_exit_report() ?ExitReport {
    if (exit_report_count == 0) return null;
    const index = exit_report_head;
    exit_report_head = (exit_report_head + 1) % exit_report_max;
    exit_report_count -= 1;
    return .{
        .name = exit_report_names[index][0..exit_report_lens[index]],
        .status = exit_report_statuses[index],
    };
}

// ---------------------------------------------------------------------------
// Arc5 issue #246: per-process resource limits
// ---------------------------------------------------------------------------

/// Set a per-process resource limit. type 0 = memory pages, type 1 = CPU ticks.
/// Returns true on success, false on invalid type or process not found.
pub fn setrlimit(id: usize, rtype: u64, value: u64) bool {
    if (id >= max_processes or processes[id].state == .free) return false;
    const p = &processes[id];
    switch (rtype) {
        0 => {
            p.mem_limit = value;
            p.mem_refused = false; // a fresh limit re-arms the 140 verdict
        },
        1 => p.cpu_limit = value,
        else => return false,
    }
    return true;
}

/// Get current resource usage for a process. Returns total pages and cpu ticks.
pub fn getrusage(id: usize) ?struct { mem_usage: u64, cpu_usage: u64, mem_limit: u64, cpu_limit: u64 } {
    if (id >= max_processes or processes[id].state == .free) return null;
    const p = &processes[id];
    return .{
        .mem_usage = p.mem_usage,
        .cpu_usage = p.cpu_usage,
        .mem_limit = p.mem_limit,
        .cpu_limit = p.cpu_limit,
    };
}

/// Update memory usage for a process (called when pages are mapped/unmapped).
/// #2115: wired — record_dynamic_page charges +1, forget_dynamic_page -1.
/// Shared surfaces charge the OWNER (the peer seat holds a page ref, not a
/// charge — ADR 0016).
pub fn update_mem_usage(id: usize, delta: i64) void {
    if (id >= max_processes or processes[id].state == .free) return;
    if (delta > 0) {
        processes[id].mem_usage +%= @intCast(delta);
    } else {
        const abs: u64 = @intCast(-delta);
        if (abs >= processes[id].mem_usage) {
            processes[id].mem_usage = 0;
        } else {
            processes[id].mem_usage -= abs;
        }
    }
}

/// Increment CPU tick counter for a process. Returns true if the limit is exceeded.
pub fn inc_cpu_ticks(id: usize) bool {
    if (id >= max_processes or processes[id].state == .free) return false;
    const p = &processes[id];
    p.cpu_usage += 1;
    if (p.cpu_limit != 0 and p.cpu_usage > p.cpu_limit) return true;
    return false;
}

/// Check if a process exceeds its memory limit. Returns true if exceeded.
pub fn check_mem_limit(id: usize) bool {
    if (id >= max_processes or processes[id].state == .free) return false;
    const p = &processes[id];
    if (p.mem_limit != 0 and p.mem_usage > p.mem_limit) return true;
    return false;
}

/// #2115: was a page charge REFUSED by the memory limit since the last
/// setrlimit? The fault path reads this to name the kill
/// `reserved_mem_limit_status` (140) — `check_mem_limit`'s `>` alone cannot
/// see it (a refused charge leaves usage == limit, not over).
pub fn mem_limit_refused(id: usize) bool {
    if (id >= max_processes or processes[id].state == .free) return false;
    return processes[id].mem_refused;
}

// ---------------------------------------------------------------------------
// Tests (host-side; the live lifecycle is proven on real VZ hardware by
// tools/verify-live-procs.sh, class B)
// ---------------------------------------------------------------------------

test "process: init starts empty and create binds a full descriptor" {
    init();
    try std.testing.expectEqual(@as(usize, 0), count());
    try std.testing.expect(current() == null);
    const id = create("USER.BIN", .{ .entry_va = 0x400000, .content_len = 0xea }, .{
        .root_phys = 0x1234_0000,
        .text_va = 0x400000,
        .text_len = 0xea,
        .stack_va = 0x1a400000,
        .stack_len = 8192,
    }, .{}).?;
    try std.testing.expectEqual(@as(usize, 0), id);
    try std.testing.expectEqual(@as(usize, 1), count());
    try std.testing.expectEqual(@as(?usize, 0), current());
    const info0 = info(id).?;
    try std.testing.expectEqualStrings("USER.BIN", info0.name);
    try std.testing.expectEqual(State.created, info0.state);
    try std.testing.expectEqual(@as(u64, 0x400000), info0.entry_va);
    try std.testing.expectEqual(@as(u64, 0xea), info0.content_len);
    try std.testing.expectEqual(@as(u64, 0x1234_0000), info0.root_phys);
    try std.testing.expectEqual(@as(u64, 0x1a400000), info0.stack_va);
    try std.testing.expect(info0.task_id == null);
    try std.testing.expectEqual(@as(u64, 0), info0.exit_status);
    // The name is OWNED: a caller slice does not outlive the call.
    const short = "A";
    _ = create(short, .{}, .{}, .{});
    try std.testing.expectEqualStrings("A", info(1).?.name);
}

test "process: lifecycle created -> running -> exited -> reaped" {
    init();
    const id = create("USER.BIN", .{ .entry_va = 0x400000, .content_len = 0xea }, .{}, .{}).?;
    // A created process cannot be reaped from running (no binding yet)...
    // bind it to executor slot 2 and run.
    try std.testing.expect(bind(id, 2));
    try std.testing.expectEqual(State.running, info(id).?.state);
    try std.testing.expectEqual(@as(?usize, 2), info(id).?.task_id);
    // bind again is rejected (not created anymore).
    try std.testing.expect(!bind(id, 3));
    // A running process cannot be reaped.
    try std.testing.expect(!reap(id));
    // The executor task exits with status 43: the process snapshots it.
    _ = on_task_exit(2, 43);
    try std.testing.expectEqual(State.exited, info(id).?.state);
    try std.testing.expectEqual(@as(u64, 43), info(id).?.exit_status);
    // Claim 4613: the exited process keeps its executor slot until the
    // lifecycle reap frees its pages (the procs row prints task=reaped).
    try std.testing.expectEqual(@as(?usize, 2), info(id).?.task_id);
    // The report is pending and drains exactly once.
    const r = take_exit_report().?;
    try std.testing.expectEqualStrings("USER.BIN", r.name);
    try std.testing.expectEqual(@as(u64, 43), r.status);
    try std.testing.expect(take_exit_report() == null);
    // Reap frees the exited descriptor.
    try std.testing.expect(reap(id));
    try std.testing.expect(info(id) == null);
    try std.testing.expectEqual(@as(usize, 0), count());
}

test "process: exit status survives the executor task's reuse" {
    init();
    const p0 = create("BOOTED", .{ .entry_va = 0x400000, .content_len = 1 }, .{}, .{}).?;
    _ = bind(p0, 2);
    // The executor exits (status 7) and its slot is REUSED by another
    // task — but the process keeps the status.
    _ = on_task_exit(2, 7);
    _ = take_exit_report();
    try std.testing.expectEqual(@as(u64, 7), info(p0).?.exit_status);
    try std.testing.expectEqual(State.exited, info(p0).?.state);
    // A second exec creates a NEW process (per-process identity), not a
    // mutated "last program".
    const p1 = create("USER.BIN", .{ .entry_va = 0x400000, .content_len = 0xea }, .{}, .{}).?;
    try std.testing.expectEqual(@as(usize, 1), p1);
    try std.testing.expectEqualStrings("USER.BIN", info(p1).?.name);
    // The old process still reports its own exit status.
    try std.testing.expectEqual(@as(u64, 7), info(p0).?.exit_status);
    try std.testing.expectEqual(@as(?usize, 1), current());
}

test "process: bounded registry recycles the oldest exited, never a live one" {
    init();
    // Fill the registry: 8 created processes.
    var ids: [max_processes]usize = undefined;
    var i: usize = 0;
    while (i < max_processes) : (i += 1) {
        ids[i] = create("P", .{ .entry_va = @intCast(i), .content_len = 1 }, .{}, .{}).?;
    }
    try std.testing.expectEqual(@as(usize, max_processes), count());
    // All live (created) -> the 9th create fails.
    try std.testing.expect(create("FULL", .{}, .{}, .{}) == null);
    // Exit the OLDEST (id 0): now the next create recycles it.
    _ = bind(ids[0], 9);
    _ = on_task_exit(9, 1);
    _ = take_exit_report();
    const recycled = create("NEW", .{}, .{}, .{}).?;
    try std.testing.expectEqual(@as(usize, 0), recycled); // the oldest exited
    try std.testing.expectEqualStrings("NEW", info(0).?.name);
    try std.testing.expectEqual(@as(usize, max_processes), count());
    // A running process is never recycled.
    _ = bind(ids[1], 10);
    _ = create("RUNNING-KEPT", .{}, .{}, .{});
    try std.testing.expectEqualStrings("P", info(ids[1]).?.name);
}

test "process: on_task_exit is a no-op for unbound slots and find_by_task" {
    init();
    try std.testing.expect(find_by_task(2) == null);
    _ = on_task_exit(2, 9); // no process bound -> no report, no crash
    try std.testing.expect(take_exit_report() == null);
    const id = create("USER.BIN", .{}, .{}, .{}).?;
    try std.testing.expect(find_by_task(2) == null); // not yet bound
    _ = bind(id, 5);
    try std.testing.expectEqual(@as(?usize, id), find_by_task(5));
    try std.testing.expect(find_by_task(6) == null);
    _ = on_task_exit(6, 1); // wrong slot -> no-op
    try std.testing.expectEqual(State.running, info(id).?.state);
    _ = on_task_exit(5, 42);
    try std.testing.expectEqual(State.exited, info(id).?.state);
}

test "process: reap guards and name truncation" {
    init();
    // Over-long names are truncated to the owned buffer.
    const id = create("A VERY LONG PROGRAM NAME", .{}, .{}, .{}).?;
    try std.testing.expect(info(id).?.name.len <= name_max);
    // reaping an invalid id / a running process fails.
    try std.testing.expect(!reap(max_processes));
    _ = bind(id, 1);
    try std.testing.expect(!reap(id));
    // reaping a created (unbound) process is allowed (exec's rollback).
    const id2 = create("ROLLBACK", .{}, .{}, .{}).?;
    try std.testing.expectEqual(State.created, info(id2).?.state);
    try std.testing.expect(reap(id2));
    try std.testing.expect(info(id2) == null);
}

test "process: allocator-backed resources are freed at reap and recycle" {
    // Arm the module allocator with a small fixture map so page ownership
    // is real on the host (the exec path arms it the same way).
    const descriptors = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 512, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&descriptors), @sizeOf(memmap.MemoryDescriptor), descriptors.len);
    try std.testing.expect(alloc.init(view, &.{}));
    const free_before = alloc.stats().free_pages;
    init();
    // An exec'd process owns its text + user-stack + kernel-stack pages.
    const text_phys = alloc.alloc_pages(1).?;
    const stack_phys = alloc.alloc_pages(2).?;
    const kstack_phys = alloc.alloc_pages(2).?;
    const id = create("USER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = 0x1234_0000,
        .text_va = 0x400000,
        .text_len = 64,
        .text_phys = text_phys,
        .text_pages = 1,
        .stack_va = 0x1a400000,
        .stack_len = 8192,
        .stack_phys = stack_phys,
        .stack_pages = 2,
    }, .{ .phys = kstack_phys, .pages = 2 }).?;
    const pinfo = info(id).?;
    try std.testing.expectEqual(text_phys, pinfo.text_phys);
    try std.testing.expectEqual(@as(u64, 1), pinfo.text_pages);
    try std.testing.expectEqual(stack_phys, pinfo.stack_phys);
    try std.testing.expectEqual(@as(u64, 2), pinfo.stack_pages);
    try std.testing.expectEqual(kstack_phys, pinfo.kernel_stack_phys);
    try std.testing.expectEqual(@as(u64, 2), pinfo.kernel_stack_pages);
    // Exit then reap: the owned pages return to the pool.
    _ = bind(id, 1);
    _ = on_task_exit(1, 3);
    _ = take_exit_report();
    try std.testing.expect(reap(id));
    try std.testing.expectEqual(free_before, alloc.stats().free_pages);
    // The create-recycle path frees the recycled process's pages too. The
    // registry must be FULL (only then does create recycle the oldest
    // exited), so fill all 8 slots with page-owning processes.
    init();
    var ids: [max_processes]usize = undefined;
    for (0..max_processes) |i| {
        ids[i] = create("P", .{}, .{ .text_phys = alloc.alloc_pages(1).?, .text_pages = 1 }, .{}).?;
    }
    // All live (created) -> no free slot and nothing exited: create fails.
    try std.testing.expect(create("FULL", .{}, .{}, .{}) == null);
    // Exit the OLDEST (id 0): its page stays allocated (exited, not yet
    // recycled). The next create recycles it and frees the page.
    _ = bind(ids[0], 9);
    _ = on_task_exit(9, 1);
    _ = take_exit_report();
    const free_after_exit = alloc.stats().free_pages;
    const recycled = create("NEW", .{}, .{}, .{}).?;
    try std.testing.expectEqual(@as(usize, 0), recycled); // the oldest exited
    try std.testing.expectEqual(free_after_exit + 1, alloc.stats().free_pages); // its page came back
    // A live (created) slot is never recycled.
    _ = bind(ids[1], 10);
    try std.testing.expectEqualStrings("P", info(ids[1]).?.name);
}

test "process: exited pages return at the lifecycle reap; the procs row stays" {
    // Arm the module allocator with a small fixture map so page ownership
    // is real on the host (the exec path arms it the same way).
    const descriptors = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 512, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&descriptors), @sizeOf(memmap.MemoryDescriptor), descriptors.len);
    try std.testing.expect(alloc.init(view, &.{}));
    const free_before = alloc.stats().free_pages;
    init();
    // An exec'd program owns 5 pages (1 text + 2 user stack + 2 EL1 stack).
    const id = create("USER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = 0x1234_0000,
        .text_va = 0x400000,
        .text_len = 64,
        .text_phys = alloc.alloc_pages(1).?,
        .text_pages = 1,
        .stack_va = 0x1a400000,
        .stack_len = 8192,
        .stack_phys = alloc.alloc_pages(2).?,
        .stack_pages = 2,
    }, .{ .phys = alloc.alloc_pages(2).?, .pages = 2 }).?;
    _ = bind(id, 3);
    // The task exits (status 43): the process becomes exited and STILL
    // names its executor slot (claim 4613 — the lifecycle reap must be
    // able to find it to free the pages).
    _ = on_task_exit(3, 43);
    _ = take_exit_report();
    try std.testing.expectEqual(State.exited, info(id).?.state);
    try std.testing.expectEqual(@as(?usize, 3), info(id).?.task_id);
    // No page is freed yet: the exited process holds its memory until the
    // scheduler's reap releases it (the procs row keeps the exit record).
    try std.testing.expectEqual(free_before - 5, alloc.stats().free_pages);
    // The lifecycle reap (scheduler.reap -> release_pages_on_reap) frees
    // the exited process's pages NOW, while the descriptor stays.
    try std.testing.expect(release_pages_on_reap(3));
    try std.testing.expectEqual(free_before, alloc.stats().free_pages);
    const pinfo = info(id).?;
    try std.testing.expectEqual(State.exited, pinfo.state);
    try std.testing.expectEqual(@as(u64, 43), pinfo.exit_status);
    try std.testing.expectEqual(@as(u64, 0x1a400000), pinfo.stack_va); // kept
    try std.testing.expectEqual(@as(u64, 0), pinfo.text_pages);
    try std.testing.expectEqual(@as(u64, 0), pinfo.stack_pages);
    try std.testing.expectEqual(@as(u64, 0), pinfo.kernel_stack_pages);
    try std.testing.expect(pinfo.task_id == null);
    // A second release is a no-op (the slot was already reaped): no
    // double free can inflate the free count.
    try std.testing.expect(!release_pages_on_reap(3));
    try std.testing.expectEqual(free_before, alloc.stats().free_pages);
}

test "process: exit reports are a FIFO — two exits print two lines in order" {
    // Card 3d (claim 1014): N exits in one idle-loop window produce N
    // `procs <name> exited status=<n>` reports IN ORDER (the old single
    // first-wins flag collapsed them).
    init();
    const a = create("USER.BIN", .{}, .{}, .{}).?;
    const b = create("COUNTER.BIN", .{}, .{}, .{}).?;
    _ = bind(a, 2);
    _ = bind(b, 3);
    // Two exits in one window, never drained in between.
    _ = on_task_exit(2, 43);
    _ = on_task_exit(3, 137);
    const r1 = take_exit_report().?;
    try std.testing.expectEqualStrings("USER.BIN", r1.name);
    try std.testing.expectEqual(@as(u64, 43), r1.status);
    const r2 = take_exit_report().?;
    try std.testing.expectEqualStrings("COUNTER.BIN", r2.name);
    try std.testing.expectEqual(@as(u64, 137), r2.status);
    try std.testing.expect(take_exit_report() == null);
}

test "process: exit report FIFO overflow drops the OLDEST" {
    // Card 3d: a full 4-slot ring evicts the oldest entry (honestly
    // reported) — the four newest exits drain, in order.
    init();
    var ids: [exit_report_max + 1]usize = undefined;
    for (0..exit_report_max + 1) |i| {
        var name: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&name, "P{d}", .{i});
        ids[i] = create(s, .{}, .{}, .{}).?;
        _ = bind(ids[i], i + 1);
        _ = on_task_exit(i + 1, @intCast(i));
    }
    // The oldest (P0, status 0) was dropped; the four newest drain in order.
    for (1..exit_report_max + 1) |i| {
        const r = take_exit_report().?;
        var name: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&name, "P{d}", .{i});
        try std.testing.expectEqualStrings(s, r.name);
        try std.testing.expectEqual(@as(u64, @intCast(i)), r.status);
    }
    try std.testing.expect(take_exit_report() == null);
}

test "process: the static boot payload owns no allocator pages" {
    init();
    const id = create("user-el0", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = 0x1234_0000,
        .text_va = 0x400000,
        .text_len = 64,
        .stack_va = 0x80000000,
        .stack_len = 8192,
    }, .{}).?; // zero pages everywhere: static backing, never freed
    const pinfo = info(id).?;
    try std.testing.expectEqual(@as(u64, 0), pinfo.text_pages);
    try std.testing.expectEqual(@as(u64, 0), pinfo.stack_pages);
    try std.testing.expectEqual(@as(u64, 0), pinfo.kernel_stack_pages);
}

test "process: snapshot marshals non-free rows in id order with the fixed 40-byte shape" {
    // Card 4a (claim 5799): the `sys_procs` snapshot — free descriptors
    // are skipped, every other row carries pid / state code / exit status
    // / NUL-padded name at the documented offsets.
    init();
    var scratch: [max_processes * snapshot_row_bytes]u8 = [_]u8{0xaa} ** (max_processes * snapshot_row_bytes);
    // Empty registry: zero rows.
    try std.testing.expectEqual(@as(usize, 0), snapshot(&scratch));

    const boot = create("user-el0", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    _ = bind(boot, 2);
    _ = on_task_exit(2, 7); // exited with status 7
    _ = take_exit_report();
    const peer = create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    _ = bind(peer, 3);

    try std.testing.expectEqual(@as(usize, 2), snapshot(&scratch));
    // Row 0 (pid 0, user-el0, exited): pid at 0, state code at 8, the
    // snapshotted status at 16, the NUL-padded name at 24.
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, scratch[0..8], .little));
    try std.testing.expectEqual(@as(u64, @intFromEnum(State.exited)), std.mem.readInt(u64, scratch[8..16], .little));
    try std.testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, scratch[16..24], .little));
    try std.testing.expectEqualStrings("user-el0", scratch[24 .. 24 + 8]);
    for (scratch[24 + 8 .. 40]) |byte| try std.testing.expectEqual(@as(u8, 0), byte); // NUL-padded
    // Row 1 (pid 1, PEER.BIN, running): a full row is exactly 40 bytes.
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, scratch[40..48], .little));
    try std.testing.expectEqual(@as(u64, @intFromEnum(State.running)), std.mem.readInt(u64, scratch[48..56], .little));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, scratch[56..64], .little)); // running: no status
    try std.testing.expectEqualStrings("PEER.BIN", scratch[64 .. 64 + 8]);

    // A recycled (reaped) descriptor leaves the snapshot (the row count
    // drops) and a NEW process takes the freed slot — the snapshot always
    // reflects the live registry.
    try std.testing.expect(reap(boot));
    try std.testing.expectEqual(@as(usize, 1), snapshot(&scratch));
    const third = create("COUNTER.BIN", .{}, .{}, .{}).?;
    try std.testing.expectEqual(@as(usize, 2), snapshot(&scratch));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, scratch[0..8], .little)); // COUNTER reuses pid 0
    try std.testing.expectEqualStrings("COUNTER.BIN", scratch[24 .. 24 + 11]);
    // The recycled slot is pid 0 again (the freed descriptor's id is
    // reused), so `third` is 0 — the snapshot reflects the live registry.
    try std.testing.expectEqual(@as(usize, 0), third);
}

test "process: mmap regions and dynamic page tracking" {
    init();
    const pid = create("VMAPP.ELF", .{}, .{}, .{}).?;
    _ = bind(pid, 2);

    const mmap_va = next_mmap_va(pid, 8192);
    try std.testing.expectEqual(@as(u64, 0x1000_0000), mmap_va);
    try std.testing.expect(add_mmap_region(pid, mmap_va, 8192, 3, 0x22));

    // Find region
    const found = find_mmap_region(pid, mmap_va + 100).?;
    try std.testing.expectEqual(@as(u64, 8192), found.len);
    try std.testing.expectEqual(@as(u64, 3), found.prot);

    // Record dynamic page allocations
    try std.testing.expect(record_dynamic_page(pid, 0x200000));
    try std.testing.expect(record_dynamic_page(pid, 0x201000));

    // Remove region
    try std.testing.expect(remove_mmap_region(pid, mmap_va, 8192));
    try std.testing.expect(find_mmap_region(pid, mmap_va) == null);

    // Reap frees all dynamic pages
    _ = on_task_exit(2, 0);
    try std.testing.expect(reap(pid));
}

test "process: mmap_collides pins the M71m argv-block geometry for any image alignment (issue #1214 review, #1648)" {
    init();
    // M71m (#1572): the packed argv+envp block is 8x256 + 16x128 = 4096
    // bytes (this fixture pinned the pre-M71m 256-B assumption until #1648
    // called it out). exec.zig places the block at align8(mem_size) and
    // sizes the segment to cover it; the data aperture extends through
    // argv_end_va (mmap_collides below); the GOOS=virelai runtime floors
    // its sbrk break at memRound(argv_va + 4096) (tools/go/overlay/
    // runtime/os_virelai.go initBlocFloor). The rule #1648 burned a
    // session on: for EITHER image alignment that floor is >= argv_end_va
    // -- the heap opens at or past the protected span, never inside it.
    // The asserts pin both halves: protection runs exactly through
    // argv_end_va, and the floor page is always free.
    const data_va: u64 = 0x50_0000;
    // r = 0: image ends page-aligned; block ON the headroom page;
    // argv_end page-aligned; the runtime floor == argv_end.
    const pid = create_as("ARGV.BIN", .{}, .{
        .data_va = data_va,
        .data_len = 0x2000, // exactly page-aligned: block starts ON the headroom page
        .argv_end_va = data_va + 0x2000 + 4096,
    }, .{}, .{}).?;
    // The headroom page carrying the argv block is a collision...
    try std.testing.expect(mmap_collides(pid, data_va + 0x2000, 4096));
    // ...and the runtime's floor (== argv_end here) opens the heap exactly
    // where the protection ends.
    try std.testing.expect(!mmap_collides(pid, data_va + 0x2000 + 4096, 4096));
    // r > 0: image ends mid-page; the block reaches past the page-rounded
    // image end and the aperture with it; the floor (memRound(argv_end))
    // is the NEXT page. This is the alignment where a stale sub-page
    // mirror of the block size put the floor INSIDE the span and killed
    // mallocinit (observed #1648).
    const pid_r = create_as("ARGVX.BIN", .{}, .{
        .data_va = data_va,
        .data_len = 0x2100, // r = 0x100: block at align8(mem_size) spills a page
        .argv_end_va = data_va + 0x2100 + 4096, // = data + 0x3100
    }, .{}, .{}).?;
    // Protection runs through argv_end_va -- including the spill page's
    // first 0x100 bytes...
    try std.testing.expect(mmap_collides(pid_r, data_va + 0x2100, 4096));
    try std.testing.expect(mmap_collides(pid_r, data_va + 0x3000, 4096));
    // ...and the runtime's floor page (memRound(argv_end) = data+0x4000)
    // is never inside the span: the heap can open there.
    const heap_floor = (data_va + 0x3100 + 4095) & ~@as(u64, 4095);
    try std.testing.expectEqual(@as(u64, data_va + 0x4000), heap_floor);
    try std.testing.expect(!mmap_collides(pid_r, heap_floor, 4096));
    // ...and without a block the rounded image span is the whole bound.
    const pid2 = create_as("NOARGV.BIN", .{}, .{
        .data_va = data_va,
        .data_len = 0x2000,
    }, .{}, .{}).?;
    try std.testing.expect(!mmap_collides(pid2, data_va + 0x2000, 4096));
    // The index accessor backs arm_task_regions' process-scope merge.
    try std.testing.expect(add_mmap_region(pid, 0x6000_0000, 4096, 3, 0x22));
    const r = mmap_region_at(pid, 0).?;
    try std.testing.expectEqual(@as(u64, 0x6000_0000), r.base_va);
    try std.testing.expectEqual(@as(u64, 3), r.prot);
    try std.testing.expect(mmap_region_at(pid, max_mmap_regions) == null);
}

// ---------------------------------------------------------------------------
// M50 TS1 (issue #1135, ADR 0024 D1/D2/D5): principals
// ---------------------------------------------------------------------------

test "process: principal defaults to uid_user/no caps and create_as assigns explicitly" {
    init();
    const p0 = create("USER.BIN", .{}, .{}, .{}).?;
    const pr0 = principal(p0).?;
    try std.testing.expectEqual(uid_user, pr0.uid);
    try std.testing.expectEqual(@as(u32, 0), pr0.caps);
    try std.testing.expectEqual(uid_user, info(p0).?.uid);
    try std.testing.expectEqual(@as(u32, 0), info(p0).?.caps);
    // The explicit kernel principal is reachable only through create_as.
    const p1 = create_as("SYS.BIN", .{}, .{}, .{}, .{ .uid = uid_system, .caps = kernel_caps }).?;
    const pr1 = principal(p1).?;
    try std.testing.expectEqual(uid_system, pr1.uid);
    try std.testing.expectEqual(kernel_caps, pr1.caps);
    try std.testing.expectEqual(uid_system, info(p1).?.uid);
    try std.testing.expectEqual(kernel_caps, info(p1).?.caps);
    // Invalid / free ids have no principal.
    try std.testing.expect(principal(max_processes) == null);
    try std.testing.expect(principal(99) == null);
}

test "process: sys_procs snapshot row is byte-frozen across principals" {
    // ADR 0024 D2: identity is additive — the 40-byte sys_procs row never
    // gains a uid/caps field. Two processes identical but for their
    // principal must marshal byte-for-byte identical rows.
    init();
    var a: [max_processes * snapshot_row_bytes]u8 = [_]u8{0xaa} ** (max_processes * snapshot_row_bytes);
    var b: [max_processes * snapshot_row_bytes]u8 = [_]u8{0xaa} ** (max_processes * snapshot_row_bytes);
    _ = create("SAME.BIN", .{ .entry_va = 0x400000, .content_len = 8 }, .{}, .{}).?;
    const rows_a = snapshot(&a);
    init();
    _ = create_as("SAME.BIN", .{ .entry_va = 0x400000, .content_len = 8 }, .{}, .{}, .{ .uid = uid_system, .caps = kernel_caps }).?;
    const rows_b = snapshot(&b);
    try std.testing.expectEqual(rows_a, rows_b);
    try std.testing.expectEqualSlices(
        u8,
        a[0 .. rows_a * snapshot_row_bytes],
        b[0 .. rows_b * snapshot_row_bytes],
    );
    // And the row width itself is unchanged.
    try std.testing.expectEqual(@as(usize, 40), snapshot_row_bytes);
}

test "process: AddrSpaceSpec fits the EL0 kstack; AddrSpace does not (issue #1333)" {
    try std.testing.expect(@sizeOf(AddrSpaceSpec) <= 256);
    try std.testing.expect(@sizeOf(AddrSpace) > 32 * 1024);
    try std.testing.expect(@sizeOf(Process) > 32 * 1024);
}

test "process: create_as leaves an existing running process untouched (issue #1333)" {
    init();
    const caller = create("CALLER.BIN", .{}, .{}, .{}).?;
    _ = bind(caller, 2);
    try std.testing.expectEqual(State.running, info(caller).?.state);
    const child = create("CHILD.BIN", .{}, .{ .text_va = 0x400000, .text_len = 64 }, .{}).?;
    try std.testing.expectEqual(State.running, info(caller).?.state);
    try std.testing.expectEqual(@as(?usize, 2), info(caller).?.task_id);
    try std.testing.expectEqual(State.created, info(child).?.state);
    try std.testing.expectEqual(@as(u64, 0x400000), info(child).?.text_va);
    try std.testing.expectEqual(@as(?usize, child), current());
    try std.testing.expectEqual(mmap_default_va, next_mmap_va(child, 4096));
}

test "process: last live task exit dies the process (ADR 0027 D2/D3)" {
    // Thread exit decrements live_tasks; the descriptor stays running until
    // the last bound task leaves. No request_process_exit — the last task's
    // own status is the process status (sys_exit snapshots are a different path).
    init();
    const id = create("T.BIN", .{}, .{}, .{}).?;
    try std.testing.expect(bind(id, 2));
    try std.testing.expect(bind_thread(id, 5));
    try std.testing.expect(has_thread_capacity(id)); // max_threads = 6; one seat used
    try std.testing.expectEqual(@as(?usize, id), find_by_task(2));
    try std.testing.expectEqual(@as(?usize, id), find_by_task(5));
    try std.testing.expectEqual(State.running, info(id).?.state);

    try std.testing.expect(on_task_exit(5, 0) == null);
    try std.testing.expectEqual(State.running, info(id).?.state);
    try std.testing.expect(find_by_task(5) == null);
    try std.testing.expectEqual(@as(?usize, id), find_by_task(2));

    try std.testing.expectEqual(@as(?usize, id), on_task_exit(2, 11));
    try std.testing.expectEqual(State.exited, info(id).?.state);
    try std.testing.expectEqual(@as(u64, 11), info(id).?.exit_status);
    _ = take_exit_report();
}

test "process: three GOMAXPROCS=2 runtimes bind 4 tasks each (M65d, #1442)" {
    // Seat + two hosted ELFs. Each runtime: primary + 3 extra (2 Ps +
    // sysmon + template). max_threads = 6 extra still has headroom — not
    // a new per-process cap; the global pool is the bound (ADR 0027 D1).
    init();
    var r: usize = 0;
    while (r < 3) : (r += 1) {
        const id = create("GO.ELF", .{}, .{}, .{}).?;
        const primary: usize = 20 + r * 10;
        try std.testing.expect(bind(id, primary));
        var extra: usize = 1;
        while (extra < 4) : (extra += 1) {
            try std.testing.expect(bind_thread(id, primary + extra));
            try std.testing.expectEqual(@as(?usize, id), find_by_task(primary + extra));
        }
        try std.testing.expectEqual(@as(?usize, id), find_by_task(primary));
        try std.testing.expectEqual(State.running, info(id).?.state);
        try std.testing.expect(has_thread_capacity(id));
    }
}

test "process: memory snapshot is a read-only coherent live/exited value" {
    init();
    defer init();
    try std.testing.expect(memory_snapshot(0) == null);
    const id = create("heap", .{}, .{}, .{}).?;
    try std.testing.expect(bind(id, 2));
    try std.testing.expect(add_mmap_region(id, mmap_default_va, 8192, 3, 0));
    try std.testing.expect(record_dynamic_page(id, 0));
    const before = runtime_receipt(id).?;
    const value = memory_snapshot(id).?;
    try std.testing.expectEqual(@as(u64, 1), value.live_pages);
    try std.testing.expectEqual(@as(u64, 1), value.live_regions);
    try std.testing.expectEqual(@as(u64, 8192), value.region_sizes[0]);
    try std.testing.expectEqualDeep(before, value.receipt);
    try std.testing.expectEqualDeep(value, memory_snapshot(id).?);
    svclock.kernel.acquire();
    const locked = memory_snapshot(id).?;
    try std.testing.expect(svclock.kernel.held());
    svclock.kernel.release();
    try std.testing.expectEqualDeep(value, locked);
    try std.testing.expect(forget_dynamic_page(id, 0));
    try std.testing.expect(remove_mmap_region(id, mmap_default_va, 8192));
    try std.testing.expectEqual(@as(u64, 0), memory_snapshot(id).?.live_pages);
    _ = on_task_exit(2, 0);
    const exited = memory_snapshot(id).?;
    try std.testing.expect(exited.exited);
    try std.testing.expectEqual(@as(u64, 0), exited.live_regions);
    try std.testing.expectEqualDeep(before, exited.receipt);
    try std.testing.expect(reap(id));
    try std.testing.expect(memory_snapshot(id) == null);
}

test "process: runtime receipt records page high-water and preserves refusal" {
    var backing: [4096]u8 align(4096) = undefined;
    const descriptors = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = @intFromPtr(&backing), .virtual_start = 0, .number_of_pages = 1, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&descriptors), @sizeOf(memmap.MemoryDescriptor), descriptors.len);
    try std.testing.expect(alloc.init(view, &.{}));
    const metadata = alloc.alloc_pages(1).?; // no overflow storage available
    defer _ = alloc.free_pages(metadata, 1);
    init();
    const id = create("PAGES.ELF", .{}, .{}, .{}).?;
    try std.testing.expect(bind(id, 2));
    try std.testing.expect(bind_thread(id, 3));
    try std.testing.expectEqualDeep(RuntimeReceipt{}, runtime_receipt(id).?);
    for (0..max_dynamic_pages) |i| {
        // Zero backing is a recorder-only fixture, not an allocator page.
        try std.testing.expect(record_dynamic_page(id, 0));
        try std.testing.expectEqual(i + 1, processes[id].runtime_usage.peak_pages);
    }
    try std.testing.expect(!record_dynamic_page(id, 0));
    try std.testing.expectEqual(@as(usize, 1), processes[id].runtime_usage.record_failures);
    try std.testing.expectEqual(max_dynamic_pages, processes[id].addr_space.dynamic_page_count);
    const live = runtime_receipt(id).?;
    try std.testing.expectEqual(max_dynamic_pages, live.peak_pages);
    try std.testing.expectEqual(max_dynamic_pages, live.total_pages);
    // A primary exit leaves a live receipt while a sibling still runs.
    try std.testing.expect(on_task_exit(2, 0) == null);
    try std.testing.expectEqual(State.running, info(id).?.state);
    try std.testing.expectEqualDeep(live, runtime_receipt(id).?);
    try std.testing.expectEqual(@as(?usize, id), on_task_exit(3, 0));
    try std.testing.expectEqual(max_dynamic_pages, runtime_receipt(id).?.peak_pages);
    try std.testing.expectEqual(max_dynamic_pages, processes[id].addr_space.dynamic_page_count);
    try std.testing.expect(release_pages_on_reap(3));
    try std.testing.expectEqual(@as(usize, 0), processes[id].addr_space.dynamic_page_count);
    try std.testing.expectEqual(max_dynamic_pages, runtime_receipt(id).?.peak_pages);
    try std.testing.expectEqual(max_dynamic_pages, runtime_receipt(id).?.peak_pages); // non-consuming
    try std.testing.expect(reap(id));
    try std.testing.expect(runtime_receipt(id) == null);
    const fresh = create("FRESH.ELF", .{}, .{}, .{}).?;
    try std.testing.expectEqual(id, fresh);
    try std.testing.expectEqualDeep(RuntimeReceipt{}, processes[fresh].runtime_usage);
    try std.testing.expect(runtime_receipt(max_processes) == null);
    try std.testing.expect(!record_dynamic_page(max_processes, 0));
}

test "process: live receipt mutations preserve an outer kernel lock and monotonic peaks" {
    init();
    const id = create("LIVE.ELF", .{}, .{}, .{}).?;
    try std.testing.expect(runtime_receipt(id) == null); // created, not running
    try std.testing.expect(bind(id, 2));
    svclock.kernel.acquire();
    defer svclock.kernel.release();
    try std.testing.expect(record_dynamic_page(id, 0));
    try std.testing.expect(record_dynamic_page(id, 0));
    try std.testing.expect(add_mmap_region(id, mmap_default_va, 4096, 3, 0));
    const live = runtime_receipt(id).?;
    try std.testing.expect(svclock.kernel.held());
    try std.testing.expect(live.peak_pages > 0 and live.peak_pages <= live.total_pages);
    try std.testing.expect(forget_dynamic_page(id, 0));
    try std.testing.expect(replace_dynamic_page(id, 0, 0)); // COW raises total, not peak
    try std.testing.expect(remove_mmap_region(id, mmap_default_va, 4096));
    try std.testing.expect(add_mmap_region(id, mmap_default_va + 4096, 4096, 3, 0));
    const after = runtime_receipt(id).?;
    try std.testing.expectEqual(live.peak_pages, after.peak_pages);
    try std.testing.expectEqual(live.peak_regions, after.peak_regions);
    try std.testing.expectEqual(live.total_pages + 1, after.total_pages);
    try std.testing.expectEqual(@as(?usize, id), on_task_exit(2, 0));
    try std.testing.expectEqualDeep(after, runtime_receipt(id).?);
    try std.testing.expect(release_pages_on_reap(2));
    try std.testing.expectEqualDeep(after, runtime_receipt(id).?);
    try std.testing.expect(reap(id));
    try std.testing.expect(runtime_receipt(id) == null);
    try std.testing.expect(svclock.kernel.held()); // no nested helper released it
}

test "process: overflow records compact and free metadata through repeated reap" {
    var backing: [3 * 4096]u8 align(4096) = undefined;
    const descriptors = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = @intFromPtr(&backing), .virtual_start = 0, .number_of_pages = 3, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&descriptors), @sizeOf(memmap.MemoryDescriptor), descriptors.len);
    try std.testing.expect(alloc.init(view, &.{}));
    init();
    const id = create("OVERFLOW", .{}, .{}, .{}).?;
    try std.testing.expect(bind(id, 2));
    // Synthetic addresses exercise the record shape without a huge fixture.
    for (0..max_dynamic_pages + 510) |i| try std.testing.expect(record_dynamic_page(id, 0x100000 + i * 4096));
    try std.testing.expectEqual(@as(u64, 1), alloc.stats().free_pages);
    try std.testing.expect(forget_dynamic_page(id, 0x100000)); // inline <- tail; last block freed
    try std.testing.expectEqual(@as(u64, 2), alloc.stats().free_pages);
    try std.testing.expect(!owns_dynamic_page(id, 0x100000));
    try std.testing.expect(owns_dynamic_page(id, 0x100000 + (max_dynamic_pages + 509) * 4096));
    try std.testing.expect(forget_dynamic_page(id, 0x100000 + max_dynamic_pages * 4096));
    try std.testing.expect(replace_dynamic_page(id, 0x101000, 0x90000000));
    try std.testing.expect(!owns_dynamic_page(id, 0x101000));
    try std.testing.expect(owns_dynamic_page(id, 0x90000000));
    _ = on_task_exit(2, 0);
    try std.testing.expectEqual(max_dynamic_pages + 510, runtime_receipt(id).?.peak_pages);
    try std.testing.expect(release_pages_on_reap(2));
    try std.testing.expectEqual(@as(u64, 3), alloc.stats().free_pages);
    const other = alloc.alloc_pages(3).?;
    try std.testing.expect(!release_pages_on_reap(2));
    try std.testing.expect(reap(id));
    try std.testing.expectEqual(@as(u64, 0), alloc.stats().free_pages);
    try std.testing.expect(alloc.free_pages(other, 3));
}

test "process: region high-water counts occupied slots across map unmap remap" {
    init();
    const id = create("REGIONS.ELF", .{}, .{}, .{}).?;
    try std.testing.expect(bind(id, 2));
    for (0..3) |i| try std.testing.expect(add_mmap_region(id, mmap_default_va + i * 4096, 4096, 3, 0));
    try std.testing.expectEqual(@as(usize, 3), processes[id].runtime_usage.peak_regions);
    try std.testing.expect(remove_mmap_region(id, mmap_default_va + 4096, 4096));
    try std.testing.expectEqual(@as(usize, 2), processes[id].addr_space.mmap_region_count);
    try std.testing.expectEqual(@as(usize, 3), processes[id].runtime_usage.peak_regions);
    try std.testing.expect(!remove_mmap_region(id, mmap_default_va + 4096, 4096));
    try std.testing.expect(add_mmap_region(id, mmap_default_va + 3 * 4096, 4096, 3, 0));
    try std.testing.expectEqual(@as(usize, 3), processes[id].runtime_usage.peak_regions);
    for (4..max_mmap_regions + 1) |i| try std.testing.expect(add_mmap_region(id, mmap_default_va + i * 4096, 4096, 3, 0));
    try std.testing.expect(!add_mmap_region(id, mmap_default_va + 100 * 4096, 4096, 3, 0));
    try std.testing.expectEqual(max_mmap_regions, processes[id].runtime_usage.peak_regions);
    for (0..max_mmap_regions + 1) |i| {
        if (i == 1) continue;
        try std.testing.expect(remove_mmap_region(id, mmap_default_va + i * 4096, 4096));
    }
    try std.testing.expectEqual(@as(usize, 0), processes[id].addr_space.mmap_region_count);
    _ = on_task_exit(2, 0);
    try std.testing.expectEqual(max_mmap_regions, runtime_receipt(id).?.peak_regions);
    try std.testing.expect(release_pages_on_reap(2));
    try std.testing.expectEqual(max_mmap_regions, runtime_receipt(id).?.peak_regions);
    try std.testing.expect(reap(id));
    try std.testing.expectEqualDeep(RuntimeReceipt{}, processes[id].runtime_usage);
}

test "process: static segment receipt survives real backing release and recycle" {
    const descriptors = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 512, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&descriptors), @sizeOf(memmap.MemoryDescriptor), descriptors.len);
    try std.testing.expect(alloc.init(view, &.{}));
    const free_before = alloc.stats().free_pages;
    init();
    const id = create("STATIC.ELF", .{}, .{
        .text_len = 4097,
        .text_phys = alloc.alloc_pages(2).?,
        .text_pages = 2,
        .ro_phys = alloc.alloc_pages(3).?,
        .ro_pages = 3,
        .data_len = 4096,
        .data_phys = alloc.alloc_pages(2).?,
        .data_pages = 2, // one segment page plus argv headroom
        .stack_phys = alloc.alloc_pages(2).?,
        .stack_pages = 2,
        .interp_phys = alloc.alloc_pages(1).?,
        .interp_pages = 1,
        .lib_phys = alloc.alloc_pages(1).?,
        .lib_pages = 1,
    }, .{ .phys = alloc.alloc_pages(2).?, .pages = 2 }).?;
    try std.testing.expect(bind(id, 2));
    try std.testing.expect(record_dynamic_page(id, alloc.alloc_pages(1).?));
    try std.testing.expect(record_dynamic_page(id, alloc.alloc_pages(1).?));
    _ = on_task_exit(2, 0);
    const receipt = runtime_receipt(id).?;
    try std.testing.expectEqual(@as(u64, 6), receipt.static_pages); // ceil(text) + R + ceil(RW)
    try std.testing.expectEqual(@as(usize, 2), receipt.peak_pages);
    try std.testing.expectEqual(free_before - 15, alloc.stats().free_pages);
    try std.testing.expect(release_pages_on_reap(2));
    try std.testing.expectEqual(free_before, alloc.stats().free_pages);
    try std.testing.expectEqualDeep(receipt, runtime_receipt(id).?);
    try std.testing.expectEqual(@as(u64, 0), info(id).?.text_pages);
    try std.testing.expectEqual(@as(u64, 0), info(id).?.data_pages);
    for (1..max_processes) |_| _ = create("LIVE.ELF", .{}, .{}, .{}).?;
    const recycled = create("NEW.ELF", .{}, .{}, .{}).?;
    try std.testing.expectEqual(id, recycled);
    try std.testing.expectEqualDeep(RuntimeReceipt{}, processes[recycled].runtime_usage);
    try std.testing.expect(runtime_receipt(recycled) == null);
}
