> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone twenty-eight march — symmetric multi-processing (SMP) (living tracker)

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts. This file holds M28's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

With Virtualization.framework provisioning 2 CPU cores (`config.cpuCount = 2`),
Milestone 28 brings up the secondary CPU core and enables multi-core scheduling,
shared memory synchronization, and inter-processor communication.

All five cards are implemented, unit tested, and verified on live Apple Silicon Virtualization.framework hardware.

## The cards

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| C1 | **PSCI core bringup.** Bring secondary CPU core online via `PSCI CPU_ON`, per-core stack, identity mapping, and GIC/timer initialization. | ✅ | `kernel/src/psci.zig`, `kernel/src/smp.zig`, `kernel/src/mmu.zig`, `kernel/src/gic.zig` (claim 6438) | Boot secondary core via HVC, report online state. |
| C2 | **Per-core scheduler state.** Per-core idle task, per-core current task pointer, and load distribution. | ✅ | `kernel/src/scheduler.zig` `current_by_core`, `current_task_for_core` (claim 6438) | Core 0 runs shell, Core 1 executes ready tasks. |
| C3 | **Spinlock synchronization primitives.** Lock-free atomic spinlock using `ldaxr`/`stlxr` and acquire/release semantics. | ✅ | `kernel/src/spinlock.zig` `Spinlock`, `IrqSaveSpinlock` (claim 6438) | Native AArch64 atomics with IRQ mask preservation. |
| C4 | **Cross-core IPI.** GICv3 Software Generated Interrupts (SGI) via `ICC_SGI1R_EL1` for reschedule and TLB shootdown. | ✅ | `kernel/src/smp.zig` `send_ipi`, `handle_sgi` (claim 6438) | SGI 0/1 cross-core signalling. |
| C5 | **Multi-core live hardware gate.** Class-B live hardware verification gate on Apple Silicon. | ✅ | `tools/verify-live-smp.sh` (claim 6438) | `smp: cores=2 online=2`, `core 0: bsp mpidr=0x0000000080000000 state=online`, `core 1: ap mpidr=0x0000000080000001 state=online`. |

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **buffy** | `kernel/src/spinlock.zig`, `kernel/src/psci.zig`, `kernel/src/smp.zig`, `kernel/src/gic.zig`, `kernel/src/timer.zig`, `kernel/src/scheduler.zig`, `kernel/src/main.zig`, `kernel/src/monitor.zig`, `tools/verify-live-smp.sh` | Clean M29/M30/M31 baseline. |
