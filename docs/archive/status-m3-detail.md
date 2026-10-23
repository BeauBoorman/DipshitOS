# Milestone 3 — Three — allocator, interrupts, tasks — archived detail

> **Archived from `docs/status.md` on 2026-08-21 (issue #262).**
> The canonical one-line summary now lives in `docs/status.md` Current position table.
> This file preserves the full narrative that was previously inline in `docs/status.md`
> so the live tracker can stay ~150–200 lines. See also [`docs/march-m3.md`](march-m3.md) and the claim files cited below.

## One-line summary (now in `docs/status.md`)

| Three — allocator, interrupts, tasks | Physical allocator, GIC + timer, tasks, EL0, and syscalls | ✅ done 2026-08-10 (claim 0707, tag `m3-userspace`) |

- **Close date:** 2026-08-10
- **Claim:** 0707
- **Tag:** `m3-userspace`
- **March tracker:** [`docs/march-m3.md`](march-m3.md)

## Full narrative as it appeared in `docs/status.md` (pre-compression)

The following is the verbatim Current position table row for M3, previously at `docs/status.md:37`.

```text
| Three — allocator, interrupts, tasks | Physical allocator, GIC + timer, tasks, EL0, and syscalls | 🚧 **active** — allocator, IRQ/timer, and round-robin tasks are done (claims 3972/5162/9187/5275); the first EL0t task + SVC boundary landed in claim 8215; the frozen 64-slot syscall ABI and slots 0–3 (`ping`/`write`/`yield`/`exit`) pass their live VZ gate (claim 3594); the fault-safe uaccess layer (claim 6120), the per-task address spaces card (claim 5804 — per-task TTBR0 with an EL1-only kernel overlay, VZ TTBR1 fallback), the user task lifecycle card (claim 6729 — explicit states, bounded spawn, exit→zombie, idle-task reaper, plus the callee-saved vector-frame fix that made preemption of compiled tasks safe), and the **ESP exec card (claim 6783 — a real user program, `USER.BIN`, is loaded from the ESP through the claim-6420 FAT path by the `exec` monitor command, the EL0 user root is rebuilt around its page, and the program runs at EL0, writing via sys_write, round-tripping pings, and exiting through the lifecycle)**, and the **blocking-syscalls card (claim 3200 — `sys_sleep` slot 4 blocks the caller for N scheduler ticks with timer-driven wakeup, the ESP program sleeps 2 ticks and wakes, and the worker keeps advancing during the sleep window)** all landed and pass their live VZ gates. **Milestone three is CLOSED 2026-08-10 (claim 0707): the full class A + class B gate set re-ran green at the candidate and the milestone is tagged `m3-userspace`** (see the march tracker [`docs/march-m3.md`](march-m3.md) row 8). |
```

### Readable paragraph form

**Milestone:** Three — allocator, interrupts, tasks

**What it proved / is:** Physical allocator, GIC + timer, tasks, EL0, and syscalls

**Status:** 🚧 **active** — allocator, IRQ/timer, and round-robin tasks are done (claims 3972/5162/9187/5275); the first EL0t task + SVC boundary landed in claim 8215; the frozen 64-slot syscall ABI and slots 0–3 (`ping`/`write`/`yield`/`exit`) pass their live VZ gate (claim 3594); the fault-safe uaccess layer (claim 6120), the per-task address spaces card (claim 5804 — per-task TTBR0 with an EL1-only kernel overlay, VZ TTBR1 fallback), the user task lifecycle card (claim 6729 — explicit states, bounded spawn, exit→zombie, idle-task reaper, plus the callee-saved vector-frame fix that made preemption of compiled tasks safe), and the **ESP exec card (claim 6783 — a real user program, `USER.BIN`, is loaded from the ESP through the claim-6420 FAT path by the `exec` monitor command, the EL0 user root is rebuilt around its page, and the program runs at EL0, writing via sys_write, round-tripping pings, and exiting through the lifecycle)**, and the **blocking-syscalls card (claim 3200 — `sys_sleep` slot 4 blocks the caller for N scheduler ticks with timer-driven wakeup, the ESP program sleeps 2 ticks and wakes, and the worker keeps advancing during the sleep window)** all landed and pass their live VZ gates. **Milestone three is CLOSED 2026-08-10 (claim 0707): the full class A + class B gate set re-ran green at the candidate and the milestone is tagged `m3-userspace`** (see the march tracker [`docs/march-m3.md`](march-m3.md) row 8).

### Archived `## What comes immediately afterward` entries for M3

The `## What comes immediately afterward` section in pre-compression `docs/status.md` (lines 357–580)
contained 11 numbered entries (items 4–14) that detailed M3's cards.
The entries have been removed from the live tracker; their substance lives in the march file and claims.
For historical fidelity, the original bullets that referenced M3 are excerpted below (see git history `docs/status.md` @ `aa4f111` for full section):

> **Bullet 4:**
> 4. ~~**A physical page allocator over the captured EFI map.**~~ **DONE 2026-08-08 (claim 3972)** — first-fit bitmap allocator over the captured map's ConventionalMemory (fixed 128 KiB BSS bitmap over the 4 GiB identity-map span), wired post-exit in `kernel_main`; `pages`/`pages selftest` monitor commands; 18 unit tests; live-observed on VZ (`total=0xee2b` pages across 7 regions; selftest allocates the largest contiguous run and restores the pool). **Extended 2026-08-09 (claim 5162):** the pool now also covers loader + boot-services regions, with exclusion ranges protecting the live kernel image, stack, handoff page, and captured-map buffer — `pages` reports `excluded=…`; 25 alloc/memmap unit tests; full class-A set green at HEAD `19ad92c` (`artifacts/verify-portable-5162.txt`).

> **Bullet 5:**
> 5. ~~**Exception vectors** (first half of item 5).~~ **DONE 2026-08-08 (claim 9746)** — VBAR_EL1 vector table + basic synchronous/IRQ handlers installed post-MMU (kernel owns EL1; a pre-exit VBAR write was measured catastrophic on VZ — see the claim), `dipshit> fault` triggers a real `udf` that is reported and resumed live (class B gate `tools/verify-live-exceptions.sh`, 2/2).

> **Bullet 6:**
> 6. ~~**GIC + timer interrupts (second half of item 5).**~~ **DONE 2026-08-09 (claim 9187; supersedes claim 7948's blocker conclusion).** The spec-corrected GICv3 driver uses MADT types 0x0B/0x0C/0x0E, targets SGI/PPI registers in the redistributor's `+0x10000` SGI frame, selects the boot CPU frame, and programs the GTDT trigger mode. On real VZ, periodic CNTP PPI 30 enters the claim-9746 EL1 IRQ vector, is acknowledged, handled, EOI’d, and re-armed; `bash tools/verify-live-timer.sh`  requires five IRQ ticks and zero poll ticks and passes **3/3** while the shell remains responsive. The old idle-loop timer poll is no longer used in production.

> **Bullet 7:**
> 7. ~~**Tasks: tick-driven round-robin scheduler.**~~ **DONE 2026-08-09 (claim 5275)** — the first milestone-three tasks card: two kernel tasks (the shell/main task + a demo worker on its own static BSS stack) preempt at every timer PPI, round-robin, with a minimal save/restore (vector-frame pointer + ELR/SPSR only — the claim-9746 stubs already keep the register file on the stack). `dipshit> tasks` reports per-task saves/resumes/advances; the worker reports its progress from the shell idle loop (`tasks worker advances=N`); host tests cover frame construction, round-robin round-trips, and the report machinery. **Live gate `bash tools/verify-live-tasks.sh` PASS 3/3** (worker report line after >= 2 real context switches + responsive shell), and the strict live-timer gate still passes **3/3** under preemption (heartbeat/report lines now snapshot their counters at the event). Live regressions all green: live-exceptions, live-transcript, live-reboot, live-fs. Class-A green. No userspace, no MMU changes — a later card adds userspace.

> **Bullet 8:**
> 8. ~~**First EL0t task + SVC boundary.**~~ **DONE 2026-08-09 (claim 8215, PR #60)** — a statically linked EL0 task, page-local user text/stack apertures, x8-selected `svc #0`, SP_EL0-preserving scheduling, and a strict live userspace gate.

> **Bullet 9:**
> 9. ~~**Frozen syscall ABI + dispatch table.**~~ **DONE 2026-08-10 (claim 3594)** — ADR 0007 freezes x8 number, x0–x5 arguments, x0 result, slots 0–3 implemented and 4–63 reserved. The runtime-built table, bounded user-aperture `sys_write`, cooperative yield, non-returning exit, deterministic counters, and corrected one-shot live SVC gate pass.

> **Bullet 10:**
> 10. ~~**uaccess: fault-safe copy-in/copy-out.**~~ **DONE 2026-08-10 (claim 6120)** — `kernel/src/uaccess.zig` adds bounded `copy_in`/`copy_out` over the kernel-known EL0 apertures (user text read-only, user stack read-write) with the ADR 0007 `EFAULT` (`-3`) contract enforced (out-of-region, overflow, unmapped, permission), plus a masked fault-recovery window: a real EL1 data abort during a copy is latched, ELR advanced past the 4-byte faulting instruction, and the copy returns EFAULT instead of crashing the kernel (an optimizer-reordering hazard that parked on the first live run was fixed with volatile window state). `sys_write` migrated onto uaccess; the `uaccess` monitor command proves `valid=1 fault=1 recovered=1` on VZ; the EL0 payload passes an unmapped bad pointer, observes `-3`, and survives to write its marker. New class-B gate `bash tools/verify-live-uaccess.sh` passes 1/1; `verify-live-svc` updated to the payload's three writes (`calls=3`).

> **Bullet 11:**
> 11. ~~**Per-task user address spaces.**~~ **DONE 2026-08-10 (claim 5804)** — every task gets its own TTBR0 root; the EL0 task's root is a clone of the kernel identity tree with its text+stack leaves overlaid at their user VAs, so EL0 can reach ONLY those leaves (kernel RAM, firmware, and MMIO are EL1-only AP=0b00 → permission faults), with UXN/PXN (W^X) on every user leaf. **VZ TTBR1 fallback:** the original kernel-in-TTBR1 KVA-shadow design was measured incompatible on VZ (TTBR1 walks fault at the first descent with 4 KiB tables — the signature of 64 KiB table-address masking — and Normal-WB TTBR1 data accesses abort even with 64 KiB-aligned tables; see ADR 0007 + `hardware-contract.md`), so the kernel stays identity-mapped in TTBR0 with TTBR1=0 and per-task isolation comes from switching TTBR0 between roots that all carry the EL1-only kernel overlay. The scheduler switches TTBR0 per task; the `addrspaces` monitor command reports TTBR1=0, T0SZ=16, per-task TTBR0 roots, and the user root's leaf inventory (`el0=4`, `el0_device=0` on VZ). New class-B gate `bash tools/verify-live-addrspaces.sh` **PASS 1/1**, all live regressions green (uaccess/svc/userspace/tasks/timer/exceptions/transcript).

> **Bullet 12:**
> 12. ~~**User task lifecycle.**~~ **DONE 2026-08-10 (claim 6729)** — the scheduler pool gains an explicit lifecycle: `State` per slot (free→ready→running→zombie→free), bounded `spawn` (first free slot, null when full), `exit_current` → zombie, and the **scheduler-owned idle task** (always-ready ring fallback; reaps one zombie per iteration so the pool drains without a parent/child relationship). The `spawn` monitor command exercises a runtime spawn on a dedicated demo stack; `tasks` reports per-row `state=` + pool/zombie header; reports are per-task slots so the worker cannot starve the demo's. **Load-bearing fix (measured on VZ):** the claim-9746 vector frame saved only x0..x17+x30, so a context switch resumed the next task with the *preempting* task's live callee-saved registers — the shell's `mon` in x19 was clobbered by the worker's loop counter (≈0x872) and the shell's next console write faulted (`esr=0x96000021`, `far=0x872`; a VM-level error when idle was registered). The frame is now 32 slots (x19..x28+x29 saved; shared `exc_restore_tail`; stubs stay inside their 128-byte slots), making preemption of compiled tasks safe. The `addrspaces` command also prints `user root=` directly (the reaper removes the exited user's task row before the gate's post-exit script runs). New class-B gate `bash tools/verify-live-lifecycle.sh` **PASS 1/1**; all live regressions green (addrspaces/uaccess/svc/userspace/tasks/timer/exceptions/transcript/fs/reboot).

> **Bullet 13:**
> 13. ~~**Load and exec a real user program from the ESP.**~~ **DONE 2026-08-10 (claim 6783)** — a separate EL0 program (`user/src/main.zig`, naked asm on the fixed syscall ABI) is built into a flat `USER.BIN` (elf2bin DSK1) and embedded on the ESP by the image builder (`mkfat32.py` + `make-image.sh` + `zig build user`). The new `exec [<file>]` monitor command reads it through the claim-6420 FAT path into a fixed 4 KiB BSS page, strips the 24-byte header, rebuilds the EL0 user root around the loaded page with claim 5804's `build_user_root` (proven to work **post-install** because the kernel stays identity-mapped — `@intFromPtr` is still physical), and spawns it as an EL0t task — **gated on the previous user task being gone** (one user program at a time; the lifecycle's closed loop). The loaded program executes at EL0 from the ESP-loaded page: its `sys_write` markers land in the serial log directly, two sequenced pings prove SVC round-trips from a loaded image, and `sys_exit` (status 42) + the idle reap close the lifecycle. Two live-measured fixes: the user linker script must **discard `.eh_frame`** (the orphan sections landed at VMA 0, so the flat image's entry pointed at CFI bytes), and exec must **strip the DSK1 header in place** (the user-root leaf masks phys to page granularity, so mapping `program+24` mapped the header page — the EL0 task fetched "DSK1" and faulted on the zero pad). New class-B gate `bash tools/verify-live-exec.sh` **PASS 1/1**; all shared-seam regressions green (lifecycle/addrspaces/uaccess/svc/userspace/tasks/timer).

> **Bullet 14:**
> 14. ~~**Blocking syscalls: sleep/yield/wakeup in the tick scheduler.**~~ **DONE 2026-08-10 (claim 3200)** — a new `sys_sleep(ticks)` row (slot 4, ADR 0007 amendment) blocks the calling task for N scheduler ticks; the scheduler gains an explicit `blocked` state with per-task wakeup deadline, a tick counter advancing on every timer PPI, and a timer-driven `wake_expired` (IRQ context, console-free) that moves expired sleepers back to `ready` — the same resume path as `sys_yield`. The ESP-loaded user program is extended with a cooperative yield, a 2-tick sleep (asserting the 0 return), and a post-wake marker before exiting with status 43. The worker's advance lines during the sleep window prove other runnable tasks keep progressing. `user_root_in_use` now counts `blocked` tasks too — a sleeping user program still owns the user root. New class-B gate `bash tools/verify-live-sleep.sh`; all shared-seam regressions green.

### Gates and claims

Primary claim: **0707** (see `docs/claims/0707-*.md` if present).
Full gate inventory: [`docs/gate-inventory.md`](../gate-inventory.md)
Hardware contract: [`docs/hardware-contract.md`](../hardware-contract.md)

---
_Generated by compression of `docs/status.md` (issue #262, 2026-08-21). Do not edit the one-line summary in `docs/status.md` without updating this archive if the narrative is still relevant._