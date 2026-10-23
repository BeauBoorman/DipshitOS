# Roadmap archive — Milestone three — allocator, interrupts, tasks, EL0/SVC, syscalls, uaccess, userspace

> **Archived 2026-08-21** from `docs/roadmap.md` (issue #264, claim 2860):
> the milestone is complete; this file preserves its roadmap plan/detail
> verbatim as history, not an active work order. Canonical status:
> [`docs/status.md`](../status.md).

---

## Milestone three — allocator, interrupts, tasks, EL0/SVC, syscalls, uaccess, and userspace (**CLOSED 2026-08-10, tagged `m3-userspace`**)

> The milestone-three plan, in canonical order (mirroring
> `docs/status.md`'s "What comes immediately afterward" and the per-card
> tracker [`docs/march-m3.md`](march-m3.md)): physical allocator →
> exception vectors → GIC + timer → kernel tasks → EL0/SVC boundary →
> syscall ABI → uaccess → per-task address spaces → user lifecycle → ESP
> exec → blocking syscalls. **All cards are done** (claims 3972/5162/9746/
> 9187/5275/8215/3594/6120/5804/6729/6783/3200; see the tracker for
> per-card evidence), the full class A + class B gate set re-ran green at
> the candidate (claim 0707), and the milestone is **tagged
> `m3-userspace`** (2026-08-10).

- ~~A physical page allocator over the captured EFI map.~~ **First step
  DONE 2026-08-08 (claim 3972):** first-fit bitmap allocator over the
  captured map's ConventionalMemory (fixed 128 KiB BSS bitmap over the
  4 GiB identity-map span), wired post-exit; `pages`/`pages selftest`
  monitor commands; 18 unit tests; live-observed on VZ. **Loader/boot-
  services pooling DONE 2026-08-09 (claim 5162):** the pool now covers
  conventional + loader + boot-services RAM, with explicit exclusion
  ranges protecting the live kernel image, stack, handoff page, and
  captured-map buffer (25 unit tests, class-A green, `pages` reports
  `excluded=`). The boot-time map walk is already served by
  `memmap.MapView` + `mem`/`pages`.
- ~~Exception vectors (VBAR_EL1 + basic synchronous/IRQ handlers).~~
  **DONE 2026-08-08 (claim 9746)** — a real vector table + sync/IRQ
  handlers installed post-MMU; `dipshit> fault` triggers a synchronous
  exception that is reported and resumed live on VZ (class B gate
  `tools/verify-live-exceptions.sh`).
- ~~Interrupt setup (GIC) and a timer.~~ **DONE 2026-08-09 (claim 9187,
  superseding claim 7948's blocker conclusion):** corrected ACPI MADT GIC
  type IDs, GICv3 redistributor SGI-frame offsets, and ICFGR trigger-bit
  programming. A real periodic CNTP PPI 30 now enters the claim-9746 EL1
  IRQ vector on VZ, is acknowledged/EOI’d and re-armed; the strict live
  gate requires `ticks=5 irq=5 poll=0` and passes 3/3 boots.
- ~~Tasks (kernel tasks first).~~ **DONE 2026-08-09 (claim 5275)** — a
  tick-driven round-robin scheduler between two kernel tasks: the
  shell/main task and a demo worker on its own static BSS stack preempt
  at every timer PPI, with a minimal save/restore (the claim-9746 stubs
  already keep the register file on the stack, so the scheduler only
  saves the vector-frame pointer + ELR/SPSR per task). `dipshit> tasks`
  reports per-task saves/resumes/advances; host tests cover the switch
  logic; the class-B live gate `tools/verify-live-tasks.sh` proves both
  tasks advance across ticks on VZ (worker report line after ≥ 2 real
  context switches + a responsive shell), and the strict live-timer gate
  still passes under preemption. No userspace, no MMU changes — a later
  card adds userspace.
- ~~First EL0t task + SVC kernel boundary.~~ **DONE 2026-08-09 (claim
  8215, PR #60)** — a statically linked EL0 task with page-local user
  text/stack apertures, x8-selected `svc #0`, SP_EL0-preserving
  scheduling, and the strict live gate `tools/verify-live-userspace.sh`
  (two sequenced pings prove return to EL0 under timer preemption).
- ~~Frozen syscall ABI + runtime dispatch table.~~ **DONE 2026-08-10
  (claim 3594, PR #64)** — ADR 0007
  ([`docs/decisions/0007-syscall-abi.md`](../decisions/0007-syscall-abi.md))
  freezes x8 number, x0–x5 arguments, x0 result; the runtime-built
  64-slot table implements slots 0–4 (`ping`/`write`/`yield`/`exit`/`sleep`) and
  returns `ENOSYS` for reserved 5–63; `sys_write` is bounded to the
  kernel-known EL0 apertures and the low-4-GiB identity blanket;
  scheduler yield/exit/sleep hooks and deterministic `syscalls` counters land
  with the live gate `tools/verify-live-svc.sh` passing 1/1 (evidence:
  `artifacts/syscall-abi-3594/verification-summary.txt`).
- ~~**uaccess: fault-safe copy-in/copy-out.**~~ **DONE 2026-08-10 (claim
  6120)** — `kernel/src/uaccess.zig` adds bounded `copy_in`/`copy_out`
  over the EL0 text (read) + stack (read/write) apertures with the
  ADR-0007 `EFAULT` (`-3`) contract (out-of-region, overflow, unmapped,
  permission), and a masked fault-recovery window: a real EL1 data abort
  during a copy is latched and ELR advanced past the faulting instruction,
  so the copy returns EFAULT instead of crashing EL1 (an
  optimizer-reordering hazard that parked on the first live run was
  root-caused and fixed with volatile window state). `sys_write` migrates
  onto uaccess; the `uaccess` monitor command and the EL0 payload prove
  the contract and the recovery live on VZ (gate
  `tools/verify-live-uaccess.sh`, 1/1: `valid=1 fault=1 recovered=1`,
  `uaccess: efault ok n=8`, no `[EXC] parking`).
