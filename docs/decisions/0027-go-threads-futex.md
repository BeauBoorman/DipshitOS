# ADR 0027: GOOS=virelai threads and futex (phase 0b kernel model)

- Status: ACCEPTED (2026-09-12 — review calls 1-3 below; thread kernel code is the next claim)
- Date: 2026-09-12
- Issue: #1194 (round claim; successor of #1163 / ADR 0026)
- Related: ADR 0007 (syscall ABI), ADR 0026 (Go runtime port, D5 lists the
  five single-M deltas this ADR retires)

## Context

Phase 0a (ADR 0026) runs Go single-threaded behind five `proc.go` fork
deltas: sysmon off, template thread skipped, spare-M handoffs dropped,
`dolock/dounlockOSThread` bookkeeping-only, `stopm` yields instead of
parking. Bring-up proved these are not optional polish — `gcenable`
wedged the single M the moment the main goroutine parked on a channel
while bgsweep/bgscavenge sat in its P's runq. Usable Go (GOMAXPROCS > 1,
sysmon, timers, netpoll pacing) needs the runtime's M:N machinery on real
kernel threads.

The scheduler already has everything the mapping needs: per-process
address spaces (`process.AddrSpace`, one TTBR0 root), a bounded task pool
(`max_tasks = 11`, per-core ready rings, preemption via the timer PPI),
and the claim-0826 rule that every live EL0 task owns its own EL1
exception stack. What does not exist yet: two tasks sharing ONE process,
a thread-exit path, and any wait/wake primitive on user memory.

## Decision

D1 — **M ↔ task mapping: one process, many tasks, one TTBR0 root.**
A Go M maps 1:1 onto a kernel task bound to the SAME process descriptor
(`process.bind`). The address space (root, mmap regions, file table,
principal, mailbox/events) belongs to the process and is shared; the per
task state that is already per-task stays per-task (EL1 kstack, register
frame, uaccess TCB regions — armed per task at SVC entry, which is exactly
what Go's M-local state wants). `max_tasks = 11` bounds Ms per boot; a Go
program's Ms count against the global pool like every other task.

D2 — **Process lifecycle stays process-scoped (no POSIX).** Thread exit
(slot 73 op) tears down the task and frees its EL1 kstack; the process
dies when its LAST task exits (`exit_group` semantics — `sys_exit` stays
"exit the process", a new `sys_thread_exit` or an op flag exits the
thread only). No zombies, no join: the existing `sys_wait(pid)` keeps
waiting on process exit only; a Go program joins threads via channels,
which is the runtime's own model anyway. Reap/recycle keeps freeing
process-owned pages exactly once (the phase-0a I1 alias guard already
fixed the only double-free shape).

D3 — **ACCEPTED as one op-based slot: slot 73 is `sys_thread(op, ...)`.**
Op 0 = create — arguments `entry, stack_hi, arg, tls` (`entry`: EL0 PC,
validated inside the process's executable aperture like `exec`; `stack_hi`:
the TOP of a CALLER-PROVIDED EL0 stack — Go passes `mp.g0.stack.hi`; `arg`:
x0 for the child, the `m` pointer; `tls`: reserved 0 — pure-Go arm64 keeps
g in R28). Op 1 = exit (thread-only, no args). `sys_exit` (slot 3) stays
process-exit; the process dies when its LAST task exits; no join (Go joins
via channels). The kernel: allocates a task, binds it to the caller's
process, arms the initial frame at `stack_hi` with `x0 = arg, pc = entry`
(the same frame machinery `register_exec_user` uses), marks it running on
the caller's core ring (no pin unless the caller pins — SMP placement
follows the unpinned exec rule, claim 9498). Returns the new kernel tid
(Go stores it in `m.procid`). Principal, uid/caps inherit from the process
(no new privilege surface; not capability-gated — it can only create work
inside the caller's own address space). implemented_count 73 → 75.

D4 — **ACCEPTED as one op-based slot: `sys_futex(op, uaddr, val,
timeout_ns)` — op 0 = wait, op 1 = wake(n).** The ADR 0007 amendment must
table the ops, the per-op errors, and state the timeout unit explicitly
(nanoseconds), with ETIMEDOUT distinct from a real wake. Two slots buy
nothing at 11 tasks; the repo already uses op selectors (sys_wmctl cmd,
sys_tty_net_auth op, sys_tty_attach selectors). Bounded
wait/wake on a user word. Op 0 = wait (sleep the task while
`*uaddr == val`, kernel-verified under the mmu read of the user word —
no copy, a direct read of the 4-byte user word via the existing uaccess
window), op 1 = wake n (default 1). Backing: a bounded BSS wait-table
keyed `(pid, uaddr)` in the scheduler — the same shape as the pipe/event
seams (ADR 0009's queue machinery, no new subsystem). Timeout rides the
existing per-task timer (`sleep` seam): a timed wait returns `-ETIMEDOUT`
(a distinct negative from a real wake). Thread death while waiting: the
exit path removes the task from the wait table and (for wake-on-exit
correctness) performs one `wake(1)` on any futex the dying task was
waiting on — Go's `exitThread` contract expects the woken peer to
re-check the user word, which the wake enables. Contention scale is
bounded by `max_tasks`; the table is `max_tasks` entries, flat-scan (no
hash table at 11 slots).

D5 — **Go side: the five deltas die.** `patch_proc.py` is deleted:
`haveSysmon` restores to `GOARCH != "wasm"`, `canCreateM` goes away,
`newosproc` = slot 73 (`clone`-shaped: child runs `mstart` on
`mp.g0.stack.hi` with `mp` in x0), `dolock/dounlockOSThread` restore the
upstream bodies, `stopm` restores `mPark`. `lock_sema.go`'s
spinning-semaphore notes stay (the futex slot backs `semasleep/
semawakeup` instead of the yield-spin — a one-file swap, `lock_virelai.go`
keeping the futex file shape). Async preemption stays OFF
(`preemptMSupported = false` — signals are phase 0c; STW remains
cooperative, the known tight-loop caveat).

D6 — **ACCEPTED: `numCPUStartup = 2` in 0b as the REAL runtime setting**
(not a gate-only boot hack), and the gate asserts the strong proof:
`go-goroutines` (class B) — the fixture prints a serial-ordered
completion proof: N goroutines (N > GOMAXPROCS) increment an atomic
counter and send on a buffered channel; main drains N completions and
prints `go-goroutines done n=<N> counter=<K>` with K == N. Asserts:
the done line, the strace signature of slot 73 (`sys_thread` op 0
called ≥ 2 times), AND the cross-core scheduling proof in the monitor
`smp` report — `task=<GOROUT>.ELF` on a secondary core during a held
window, exactly the pattern live-smp1/live-smp-stress assert
(`smp: secondary runs=`). Slot-73 tasks carry the PROCESS name so the
assert holds. Pool cost recorded: 2 Ps + sysmon + template ≈ 4 of
max_tasks = 11. If sampling proves unreliable during implementation,
fall back to the narrow scope honestly — but the strong proof is tried
first.

## Consequences

- Retires every `proc.go` delta — the fork's scheduler surface returns to
  stock; only GOOS files remain.
- Unblocks 0c (fault delivery) and phase 2 (netpoll needs wakeable Ms;
  sysmon needs a thread — both assume this ADR).
- The task pool (11) bounds GOMAXPROCS: a Go program's Ms + every other
  process's task share the pool. **Issue #1226 (envp half):** the kernel
  shell `set`/`export` table is packed onto the gap-path exec as a bounded
  envp block, so `GOMAXPROCS=N` in the environment now overrides the
  default at `schedinit`. `numCPUStartup` stays **2** in `osinit`
  (D6 — two vCPUs); there is no osinit default bump. Multi-P stress
  (`GOMAXPROCS=1` serial, `GOMAXPROCS=2` default, higher N within the
  task-pool bound) is an env choice, not a rebuild.
- Slots 73/74 land as ADR 0007 amendments (append-only; 72 is taken by
  #1166's getrandom, implemented_count 73 → 75).

## Implementation amendments (2026-09-13, PR #1221 review)

- **D1 correction — mmap regions are PROCESS-scope, not per-task.**
  D1's "uaccess TCB regions are exactly what Go's M-local state wants"
  holds for the TASK extras (the exec shapes), but the Go sbrk heap is
  reserved by one M and read/written by every M, so a mapping made after
  a thread was created was invisible to that thread's TCB snapshot.
  `sys_mmap` now registers only on the process
  (`process.add_mmap_region`), and `arm_task_regions` merges the process
  registry into every task's uaccess view at each SVC entry. The task
  extras keep the exec/rodata/dynamic apertures; the per-core 26-slot
  lists still bound the union (2 base + ≤ 5 exec + 16 mmap).
- **D4 correction — the wait word is re-checked AFTER the seat is
  visible.** The syscall layer's compare is a fast path only; the
  authoritative check runs inside `futex_wait_current` under `sched_lock`
  once the `(pid, uaddr)` seat and `futex_waiting` are set. Without it a
  peer's store + wake landing between the compare and the seat would find
  no waiter and `semasleep(-1)` would park forever. A failed re-check
  clears the seat and returns `-EAGAIN`; a full seat table or a rotation
  refusal is also transient `-EAGAIN`.
- **Thread spawn is published last.** `spawn_thread` builds the task
  off-ring (`.blocked`) and finishes TCB fields, the region copy, and the
  process bind under one `sched_lock` hold; only then does it become
  `.ready` and join a ring. The capacity-failure undo runs under the same
  lock.
- **Kernel boot-payload hang (unrelated latent bug surfaced by the
  review's gate sweep).** The `.userbss` symbol order is linker-defined:
  when `user_timer_preemptions` precedes `user_stack`, boot's
  `rebuild_user_root` mapping from `&user_stack` was one page off, and —
  worse — an aperture ABOVE the 4 GiB identity blanket had no source slot
  for the user-root clone to descend, so the witness page was silently
  unmapped and EL0 demand-zero reads spun forever. Fixed by mapping the
  `.userbss` SECTION base and by having the root builder construct
  missing tables for aperture slots (`mmu.zig` host regression test).
  `live-addrspaces`/`live-args`/`live-entropy`/`live-zc` now catch it.

## Implementation amendments (M129b, #2611 — task-pool raise)

- **`max_tasks` 16 → 64; the process registry 16 → 64 alongside.** The
  M65d sizing (3 kernel + 3 runtimes × 4 Ms + 1 spare) was correct at 256
  MiB: the guest RAM bound masked the pool. At the 512 MiB compiled
  default (M129a) the pool is the sole concurrency bound — the
  service-graph boot seats ~14 tasks, and a restored session re-execs
  enough runtimes to exhaust all 13 user slots, where the runtime's
  `newosproc` throws on `-EAGAIN` (the M120b crash observed under
  session re-exec, #2577 evidence). Semantics unchanged: D1's 1:1
  M↔task mapping, D2's last-task-exit lifecycle, D3's slot-73 refusal —
  an over-cap spawn still refuses `EAGAIN` by name, and an over-cap exec
  still returns `pool_full` (`error: no free scheduler pool slot`).
  Only the bound moved.
- **N = 64 chosen from measured per-task cost at 512 MiB.** A live task
  costs a 48-page (192 KiB) EL1 kernel stack allocated at spawn plus a
  ~1 KiB fixed-BSS slot (`@sizeOf(Task)` = 1064 B). 61 user slots → a
  worst-case ~11.4 MiB of kstacks, ~2.3% of the ~494 MiB observed free
  at the 512 MiB boot. The exec-side binder is not the pool: each exec'd
  root consumes ~20 pages of the 512-page mmu table carve-out, so exec
  refuses `.table_full` at ~24 concurrent roots — the pool can only be
  saturated by `sys_thread` tasks, which share their process's root.
  61 user slots ≈ 15 compiled-GOMAXPROCS=2 runtimes (4 Ms each) —
  roughly 4× the seated-runtime pressure that crashed #2577.
- **Registry parity, not headroom.** Every live task needs a live
  process descriptor, so a 32-slot registry would silently re-cap the
  pool at ~32. Each descriptor costs ~33.5 KiB BSS (the inline
  `dynamic_pages` table dominates); 64 descriptors ≈ 2.2 MiB — which
  pushed the KRN2 image past the loader's 16 MiB sanity cap, so
  `kernel_max_size` grew to 32 MiB (loader allocates from any free UEFI
  region; the cap is a check, not a layout bound).
- **`max_threads` 6 → 16 alongside.** The per-process bound is a
  different knob — it caps extra task seats per descriptor, not the
  global count — but the storm leg showed 6 was too tight to leave a
  seated runtime any lazy-M headroom: a program at ~4 runtime tasks plus
  a few `sys_thread` children hit the descriptor bound, and its next
  `newosproc` threw `fatal error: newosproc` on EAGAIN while the pool
  still had slots (`tasks=61/64` observed). The refusal was by name but
  the wrong bound refused — 16 extra seats restore the intended order:
  a program's own Ms stop binding first at ~17 tasks/proc, and the
  pool still bounds the total.
- **`futex_max` tracks `max_tasks`** (D4 seat table is one entry per
  task), so wait capacity scales automatically.
- **The monitor's refusal names are unchanged.** `sys_thread` reports
  `EAGAIN`; `sys_exec` reports the monitor line by name. The
  spawn-storm leg in `go-stress.spec` asserts both: N concurrent Go
  tasks survive at `tasks=64/64`, and the over-cap exec refuses with
  the named pool-full error.
