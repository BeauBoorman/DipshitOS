---
title: Memory
parent: architecture
status: published
tags: [architecture, memory]
---

# Memory

VirelaiOS builds its allocator from the memory map captured before UEFI Boot
Services end. The kernel keeps an identity-mapped view for EL1; each process
has a separate user address space with EL0 permissions granted only to its
own mappings. The relevant implementations are
[`alloc.zig`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/kernel/src/alloc.zig),
[`mmu.zig`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/kernel/src/mmu.zig),
[`process.zig`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/kernel/src/process.zig),
and
[`exceptions.zig`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/kernel/src/exceptions.zig).

## Address spaces and paging

- The MMU uses 4 KiB pages and an identity map covering the low 4 GiB. Kernel
  mappings are EL1-only; each process root adds that process's user mappings.
- Anonymous `mmap` reserves user virtual ranges. On the supported EL0 data
  faults, the kernel can allocate a zero-filled page on demand. Writes to
  copy-on-write mappings either make an unshared page writable or copy a
  shared page before resuming the process (M29).
- The process registry bounds anonymous mappings to 16 regions and records
  up to 4,096 dynamically allocated pages per process. These are implementation
  limits, not promises that every process can use that much memory.
- There is no swap or memory-balloon reclaim path. A failed page allocation
  does not imply that the kernel can evict a process's pages.

## Fixed structures and bounds

| Structure | Bound |
|---|---|
| Physical allocator bitmap | 128 KiB BSS; tracks a 4 GiB span at 4 KiB per page |
| Page-table storage | 512 pages (2 MiB) of fixed BSS |
| Scheduler task pool | 16 task slots total |
| Anonymous mappings | 16 regions per process |
| Dynamic page records | 4,096 per process |

The allocator pools whole pages from eligible captured-map regions and
protects the kernel image, handoff data, stack, and captured-map buffer with
exclusions. Reserved ranges and gaps remain unavailable. The live machine's
usable-page total is derived from the EFI map; it is not a constant inferred
from the VM's configured RAM size.

## Syscall table

The runtime-built syscall table has 128 slots, of which 88 are registered
(0–87). Anonymous `mmap` and `munmap` are slots 63 and 64; wall-clock setting
and filesystem metadata are slots 78 and 79. See [[userspace|Userspace & syscalls]]
for the complete interface.

<Aside kind="warning">

**LIMITATION.** Demand-zero paging and copy-on-write are implemented, but
VirelaiOS has no swap or memory reclaim. Page allocation and page-table
capacity remain bounded by the captured memory map and fixed kernel pools.

</Aside>
