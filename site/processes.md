---
title: Processes & IPC
parent: capabilities
status: published
tags: [capabilities, processes, ipc]
---

# Processes & IPC

VirelaiOS splits the idea of "a running program" into two objects with
different owners. The **task** is the scheduler's executor — a register
frame, a kernel exception stack, a slot in a per-core ready ring. The
**process** is the unit that owns the program: the loaded image, the
address space (`TTBR0` root), the exit status, the mailbox, the file
handles, the principal. One process can carry several tasks — that is how
threads work here — and a task always belongs to at most one process.
The dependency is one-way: the scheduler knows about processes; the
process registry knows nothing about scheduling.

Both sides are fixed-size BSS structures. The task pool and the process
registry both hold **64** entries — raised together so a live task can
never orphan its process record — and a full registry recycles the oldest
*exited* descriptor, never a live one. Each descriptor costs about
33.5 KiB of BSS, dominated by its inline page-ownership table.

## Lifecycle

A process moves `free → created → running → exited → free`:

- `exec` creates the descriptor (`created`), loads the image, binds it to
  a fresh task, and the task entering a ring makes it `running`.
- `sys_exit` (slot 3) or a fault ends the task; the process goes to
  `exited` and **keeps its status** — the exit code is snapshotted onto
  the descriptor at exit time precisely so it survives the task slot's
  reuse.
- The scheduler's idle task — the always-ready WFE-parked occupant of the
  last pool slot — reaps one zombie task per iteration, returning its
  pages, its kernel stack, and its page-table subtree. The exited
  descriptor stays visible in `procs` output until the registry needs the
  slot, which is why `procs` can still tell you why a program died.

`kill <pid|name>` in the monitor, or `sys_kill` (slot 29) from EL0, does
not touch the target directly: it *arms* the process's executor task, and
the next time the scheduler selects that task it runs the ordinary exit
path with the reserved status **137**. Lifetime belongs to the kernel,
not the program — there is no signal model and no unkillable state. Other
reserved statuses mark other ends: **139** is the fault reap (an EL0 data
abort the demand-pager cannot resolve, a guard-page hit, an execution
from data), **140** is a memory-limit reap, **141** a CPU-limit reap.

The M52 teardown work is what makes "the kernel owns lifetime" honest end
to end. When a process dies — by exit, kill, or fault — the exit path
auto-closes the windows it owned, revokes its shared-anonymous mappings
out of survivors' address spaces, releases a held pointer capture,
relinquishes the WM registration if it held one, drains its TCP
connection and file handles, and unbinds the terminal front-end it
attached. A client dying mid-drag, mid-commit, or holding focus leaves
no zombie window, no stale mapping, and no stuck capture; those shapes
are pinned live rather than asserted in prose. A fault or an unexpected
nonzero exit also writes a crash tombstone — a bounded record with the
serial tail — that [[services|the observability stack]] surfaces to the
user.

## Exec and argv

`exec <file> [args…]` (and syscall slot 28, which shares the loader)
resolves the image on the host share, runs the [[kernel|bounded loader]],
and returns the new process's pid. Arguments are a fixed block — eight
256-byte slots — packed into the image; `_start` receives argc in x0 and
the block's user VA in x1. An over-long argument or a ninth argument is a
named refusal, never a silent chop. Slot 28 preserves the caller's
principal — there is no setuid — and an optional stdio-binding request
can ride in the call's high argc bit. Since the caller-survival card
(#1333), an EL0 `exec` leaves its parent's address space described by a
small value-type spec rather than touched in place, so spawning a child
cannot corrupt the caller; `live-el0-exec` proves both the `ENOENT` and
the happy path from inside a live EL0 program.

## IPC and blocking

- **Mailbox.** `sys_ipc_send` (slot 5) copies up to 64 bytes into the
  target process's bounded FIFO ring — 32 slots of 64 bytes each, per
  process id — and returns `ENOSPC` before copying anything when the ring
  is full: a message is refused, never half-delivered. `sys_ipc_recv`
  (slot 6) reads the caller's *own* ring as peek → copy → drop, so a bad
  user buffer faults out without consuming the message. Send names the
  target's pid; receive resolves the caller's own ring server-side, so no
  self-pid ever crosses the wire.
- **Wait.** `sys_wait` (slot 8) blocks the caller's task until a target
  process exits and returns its status — event-driven, not a poll, and
  not POSIX `wait` (no parent-child requirement; any process may wait on
  any pid it can name).
- **Pipes.** Slots 56/57 give the shell a bounded 4 KiB sequential pipe —
  one per process from a fixed table — enough for `a | b` without
  pretending to be a general pipe subsystem.
- **Threads and futexes.** `sys_thread` (slot 73) creates an extra task
  inside the caller's own process — same address space, same principal,
  own kernel stack and register frame — which is how a Go runtime gets
  real Ms. `sys_futex` (slot 74) is the matching wait/wake primitive on a
  user word: a bounded per-task wait table keyed `(pid, uaddr)`, an
  authoritative re-check under the scheduler lock so a store that races
  the wait is not lost, `ETIMEDOUT` distinct from a real wake, `EAGAIN`
  on transient full-table or rotation refusals, and a wake-on-exit sweep
  so a dying waiter never strands its peer. This pair is ADR 0027 and the
  whole basis of `GOOS=virelai`'s scheduler; [[go-runtime]] covers the Go
  side.

## Identity

Every process carries a **principal** — a `{uid, caps}` pair assigned at
creation and preserved across `exec`. There is no setuid bit and no
privilege-raising syscall, so a spawned program can never exceed the
authority of whoever launched it. Three uids exist today: `uid_system`
(the kernel and the monitor), `uid_user` (every ordinary EL0 program),
and `uid_agent` — which the kernel binds automatically to a program whose
recorded image name is `AGENTD.ELF`, and which children of agent
processes inherit. Capability bits do the fine-grained work:
`CAP_PROC_ADMIN` permits acting on another principal's processes,
`CAP_FS_ANY` bypasses the file-trust checks, `CAP_CLIPBOARD` gates the
programmatic clipboard slots. `sys_principal` (slot 68) lets a process
read back its own principal; [[trust]] and [[capabilities]] cover the
model in depth. A process's *name* is just its binary's file name —
kernel-derived, deliberately not unique, which is exactly why the pid
surface below had to become authoritative.

## Watching the table

EL0 observes the process world through two pids-worth of honest surface:

- `sys_procs` (slot 7) emits a snapshot of the registry. The original
  40-byte row (pid, state, exit status, 16-byte name) is byte-frozen —
  every existing reader is untouched — and a version tag in the `max`
  argument's top byte opts into the **v2 row**: 80 self-describing bytes
  adding per-process CPU ticks, a resident-memory figure, and the machine
  denominators (total ticks, core count, total pool pages) a reader needs
  to turn counts into percentages without a second call. This is ADR
  0047; GOTOP is its flagship reader.
- `sys_getpid` (slot 87) answers "who am I" from the kernel's own
  task→process mapping rather than a name scan — a real fix, not a
  nicety: two copies of the same app share a name, and the old
  first-name-match scan silently misrouted window-server replies to the
  wrong instance (ADR 0048).

The monitor side has `procs` (the registry), `tasks` (the pool — state,
saves, resumes, per-task tick attribution), and `resources` (occupancy of
every bounded table at once).

<Aside kind="info">

**LIVE-GATED.** `live-concurrent` shows two live processes;
`live-long-lived` keeps one running across another's exit, reap, and
re-exec; `live-ipc` is the byte-exact mailbox round trip; `live-wait`
proves the blocked-then-status handoff; `live-procs-syscall` the EL0-side
snapshot; `live-sys-kill` the armed-kill path; `live-lifecycle` and
`live-tasks` the zombie/reap machinery; `live-scale` the pool at depth;
`go-goroutines` the thread/futex pair doing real work; `live-el0-exec`
the caller-survival contract. The M52 teardown shapes are pinned inside
`live-wnd-server`, `live-sb3-surface-handoff`, and `live-sb6-perf-payoff`.

</Aside>
