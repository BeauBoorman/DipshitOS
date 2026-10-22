---
title: Memory
parent: architecture
status: published
tags: [architecture, memory]
---

# Memory

VirelaiOS memory management starts from a fact about its platform: once
`ExitBootServices` returns, the EFI memory map captured just before the
call is the *only* authority on what RAM exists. There is no
`GetMemoryMap` afterward, no device tree to re-derive regions from, and
no second chance. Everything on this page — the allocator pool, the page
tables, the per-process maps — is built once from that captured map and
then run within fixed, compiled-in bounds.

## The physical allocator

The allocator is a page-granularity bitmap over the low 4 GiB of physical
space — the same span the kernel's identity map blankets. One bit per
4 KiB page, 128 KiB of fixed BSS total; there is no heap, and no
allocation happens during construction. `init` starts with every bit in
the span set (allocated), then clears exactly the pages the captured map
declares poolable: conventional RAM, loader code/data, and boot-services
code/data regions. Pages the map does not declare — reserved ranges,
ACPI, MMIO windows, the gaps between regions — simply never get cleared,
so they can never be handed out. Whole pages of conventional memory above
the 4 GiB blanket are honest loss: untracked, visible in the stats.

Pooling loader and boot-services regions means some live data sits inside
the pool, so `init` also takes an *exclusion* list: the kernel image
itself, the handoff page, the kernel stack, and the captured-map buffer
are all re-marked allocated. `free_pages` only clears bits it was given —
the contract is caller-disciplined, and freeing an excluded page would
unprotect it. The monitor's `pages` command prints the armed pool's
totals; the free count is derived from the real map, not inferred from
the VM's configured RAM.

At the current compiled default the runner arms the guest with 512 MiB —
raised from 256 MiB when the measurement showed the image, tables, and a
modest session fit but a service-graph boot plus a restored session did
not. Roughly 494 MiB is observed free at boot.

## Address spaces: one kernel world, many user worlds

The kernel runs identity-mapped in `TTBR0_EL1`: the low 4 GiB is mapped
one-for-one, declared RAM as Normal write-back (2 MiB blocks where
aligned, 4 KiB pages at the edges) and everything else — declared MMIO
windows plus every undeclared gap — as Device nGnRnE. Every leaf in that
map is EL1-only; there is no EL0 permission anywhere in it.

Per-task address spaces arrived via a measured fallback. The original
design put the kernel at a `TTBR1` high-half alias so `TTBR0` could swap
per task; on real VZ hardware the TTBR1 walker faulted at the first
descent level in every configuration tried, and once coaxed into
resolving, a Normal access through it still aborted. The design that
shipped instead keeps the kernel identity-mapped in `TTBR0` (T0SZ=16,
a 48-bit space, walk from level 0) and gives **each task its own TTBR0
root**: a clone of the identity tree — kernel leaves re-published as
EL1-only — overlaid with that task's user leaves at their user virtual
addresses. The kernel is therefore reachable under every root, the
scheduler switches `TTBR0` on every context switch, and an EL0 access to
kernel RAM, firmware, or a device window is a permission fault, never a
device access. UXN/PXN are set on every user leaf, which is where the
system's W^X discipline actually lives.

User VAs are fixed by convention: text at 4 MiB (`0x0040_0000` — ELF
images link against it, so no relocation pass runs), the stack randomized
per exec inside the 4–8 GiB band from the seeded CSPRNG, and anonymous
mmaps bump-allocated upward from `0x1000_0000`. The default stack
placement moved to 6 GiB for a reason worth knowing: VZ anchors guest
RAM at `0x7000_0000` and grows it upward, so the old 2 GiB default landed
on kernel-live RAM the moment a guest exceeded 256 MiB — and the
user-root builder refused the overlay, which was the >256 MiB boot fix in
M129.

## Page-table storage

Page tables come from their own fixed pool: a 512-page (2 MiB) BSS
carve-out, allocated by bump, with a free list so a reaped process's root
returns its whole subtree for reuse. Because every user root clones the
identity tree, a root costs around twenty table pages — which makes the
carve-out, not the task pool, the binding limit on *concurrent exec'd
processes*: about two dozen live roots exhaust it, and the exec path
names the refusal `table_full` (`page-table carve-out exhausted` on the
console). Thread tasks share their process's root, so they do not spend
the carve-out.

## Demand paging and copy-on-write

Anonymous memory is managed, not naive. `sys_mmap` (slot 63) registers a
region on the caller's process — bounded at sixteen regions per process —
and `sys_munmap` (slot 64) releases one. A region may be armed eager or
demand; on a translation fault inside a demand region the kernel's fault
resolver allocates and zero-fills the page into that process's own root,
then resumes it. Demand coverage extends to the zero-fill tails of gap-ELF
image segments (a `p_memsz > p_filesz` tail is registered as a demand
region rather than copied), so a multi-megabyte `.bss` never costs file
bytes *or* eager pages — it costs pages only where it is actually
touched. A fault at an address the process does not own is not populated;
it goes to the kill path.

Copy-on-write backs the shared-anonymous mappings that Seam B uses for
window buffers. A shared page is mapped read-only under a software COW
bit; a write fault against it either promotes the leaf in place (when the
writer is the page's only remaining owner) or copies the page and maps
the private writable twin. Exit revokes shared mappings cleanly, so a
dead peer's buffers cannot linger in a survivor's address space.

Stacks are guarded: the page below the user stack is deliberately left
unmapped, so a program that steps off its stack takes a real EL0 data
abort and the kernel reaps it with the fault status — the named-behaved
version of a stack overflow rather than silent corruption of whatever sat
below. The user stack itself is 192 KiB, a bound measured from the
largest observed real consumer (the in-guest TLS handshake).

Images are multi-segment: a gap-layout ELF is up to three `PT_LOAD`
segments (text R+X, an optional read-only middle, data R+W), each mapped
at its declared `p_vaddr` under the aperture permissions it declares.

## The measured pools

The kernel's resource story is a table of compiled bounds, each one
charged and reported rather than assumed:

| Structure | Bound | What saturates it |
|---|---|---|
| Physical allocator bitmap | 128 KiB BSS; the low 4 GiB at 4 KiB/page | RAM above 4 GiB is untracked |
| Page-table carve-out | 512 pages (2 MiB); ~20 tables per live user root | ~24 concurrent exec'd roots → `table_full` |
| Scheduler task pool | 64 slots; a live task costs a 192 KiB kernel stack + ~1 KiB BSS | `sys_thread` children; exec refuses `pool_full` first |
| Process registry | 64 descriptors, ~33.5 KiB BSS each | Registry parity with the pool — never the first wall |
| Anonymous mmap regions | 16 per process | `sys_mmap` calls |
| Demand/dynamic page records | 4,096 inline per process, then overflow blocks of 509 addresses | Working set, honestly |
| Kernel futex wait table | 64 seats (one per task) | Contended waits |

`resources` in the monitor prints the occupancy of all of these, which is
how the capacity-table gate asserts them on real hardware rather than
reading constants out of the source.

<Aside kind="info">

**LIVE-GATED.** `live-vm-depth` proves the demand-zero populate, munmap,
and eager-mmap round trips and, in run 02, holds named `ENOMEM` refusals
under deliberate exhaustion. `live-m16-guards` proves the guard-page kill
path and per-segment permissions; `live-m16-image` the multi-segment
image; `live-m16-resources` the carve-out refusal; `live-addrspaces` the
per-task roots; `live-sb2-shared-anon` the COW/shared-anon revoke
semantics.

</Aside>

<Aside kind="warning">

**LIMITATION.** There is no swap and no memory-balloon device — the
balloon is deliberately left unattached, so nothing reclaims memory under
pressure. Demand paging decides *when* pages are allocated, not how they
come back; pages return at process reap or explicit `munmap`, and that is
the whole reclaim story. A workload that cannot fit inside the captured
map plus the compiled bounds is refused by name — `out_of_memory`,
`ENOMEM`, status 140 at the rlimit reap — not compressed, evicted, or
swapped.

</Aside>
