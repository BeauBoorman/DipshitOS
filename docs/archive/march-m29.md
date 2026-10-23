> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone twenty-nine march — VM depth: demand paging, COW, and anonymous mmap (living tracker)

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts. This file holds M29's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

Milestone 29 introduces virtual memory depth to VirelaiOS (Issue #598):
demand-paged zero-fill translation faults, Copy-on-Write (COW) page sharing,
anonymous userland `sys_mmap` / `sys_munmap` syscalls, dynamic process memory
tracking, and leak-free resource reclamation on process exit.

## The cards

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| V1 | **Demand Paging (Zero-Fill Faults).** Catch Data Abort translation & unmapped permission faults, dynamically allocate zeroed physical pages, install EL0 leaves, and resume execution. | ✅ | `artifacts/live-vm-depth-gate.txt` (claim 8247) | `kernel/src/exceptions.zig`, `kernel/src/mmu.zig`, `kernel/src/alloc.zig` |
| V2 | **Copy-on-Write (COW) Page Sharing.** Share physical pages across processes read-only; handle permission faults on write (DFSC 0xc..0xf) by allocating private page copies. | ✅ | `artifacts/live-vm-depth-gate.txt` (claim 8247) | `kernel/src/exceptions.zig`, `kernel/src/mmu.zig`, `kernel/src/alloc.zig` |
| V3 | **Anonymous `sys_mmap` & `sys_munmap` Syscalls.** ABI slots 63 and 64 for on-demand userland anonymous memory allocation and teardown. | ✅ | `artifacts/live-vm-depth-gate.txt` (claim 8247) | `kernel/src/syscall.zig`, `kernel/src/uaccess.zig`, `kernel/src/process.zig` |
| V4 | **Live Hardware Gate & Zero-Leak Teardown.** `VMTEST.BIN` exercising demand faults, COW splits, mmap/munmap, clean exit, and zero memory leaks. | ✅ | `artifacts/live-vm-depth-gate.txt` (claim 8247) | `user/src/vmtest.zig`, `tools/verify-live-vm-depth.sh` |
