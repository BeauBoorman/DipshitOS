---
title: Kernel
parent: architecture
status: published
tags: [architecture, kernel]
---

# Kernel

VirelaiOS runs a freestanding AArch64 kernel written in Zig: **no libc, no
POSIX, and no existing guest OS in the boot path.** The kernel is a flat,
relocation-free image — linked at zero, loaded at a runtime-chosen physical
base, and kept correct at any load address by construction (position-
independent code plus a standing rule against const pointer tables). That
shape is what lets a small UEFI loader bring it up without an ELF parser or
a relocation pass, and it shapes several kernel internals described below.

## The boot pipeline

Boot is a two-image handoff kept deliberately auditable. The boot volume's
`EFI/BOOT/BOOTAA64.EFI` is a Zig UEFI application; the kernel proper is
`KERNEL.BIN`, a flat image in the DSK1 format — a 24-byte header (magic,
flags, entry offset, image size) followed by the loadable content, produced
from the linked freestanding ELF by `tools/elf2bin.py` (ADR 0002). The
loader places the content — not the header — at the load base, so
PC-relative addressing in the image stays exact, then validates the image
and jumps to its entry point.

The contract between loader and kernel is the *handoff v2* record: a
4 KiB-aligned page allocated as `EfiLoaderData`, handed to the kernel in
register x3. It carries the `DSK2` magic and a version field (v4 today),
the kernel's base and size, the EFI System Table pointer, the loader's own
image handle, a 16 KiB stack the kernel moves onto, a wall-clock epoch
captured from EFI runtime services (or a sentinel when the firmware offers
no honest time), and — since the measured-boot work — the loader's SHA-256
digests of its own BOOTAA64.EFI image and of the KERNEL.BIN it verified
before jumping. The kernel re-validates every field on entry and refuses a
malformed record by name.

After validation, the takeover sequence is strictly ordered (ADR 0004):

1. Switch to the kernel-owned stack the loader provided.
2. Capture the EFI memory map — the sole authority on memory layout,
   because there is no `GetMemoryMap` after exit.
3. Call `ExitBootServices` itself, with the loader's image handle. The
   kernel — never the loader — makes this call, so a kernel that fails
   before exit leaves the loader free to keep writing evidence and to
   return control to the firmware. The call retries on a stale map key
   and gives up loudly after eight attempts.
4. Install the exception vector table into `VBAR_EL1` and build + install
   the identity-mapped `TTBR0_EL1` page tables.
5. Initialize the devices the kernel drives directly, print
   `VirelaiOS kernel has seized control.` over the serial console, and
   drop into the `virelai>` monitor.

One VZ quirk shaped the ordering: Virtualization.framework resets virtio
devices at `ExitBootServices` (observed, not assumed). Each transport
therefore discovers and probes pre-exit, then re-arms its queues and
feature state after the MMU switch — and prints the pre-re-arm status so
the host can see exactly what the reset touched.

## The `virelai>` monitor

The monitor is the kernel's own interactive command interpreter — an EL1
task reading the serial console (and, when armed, the remote console
channel). It is not a userspace shell: it runs inside the kernel with the
system principal's authority, and it is how every gate pokes the machine.
Its surface is grouped by `help`: filesystem browsing over the host share,
`exec`/`kill`/`spawn` for program control, the inspection commands that
power the evidence model (`procs`, `tasks`, `pages`, `resources`, `smp`,
`syscalls`, `addrspaces`, `uaccess`), settings and `reboot`/`shutdown`.

From this seat the boot default hands control to [[services|INIT.ELF]],
which reads its service manifest and supervises the desktop; `settings set
init off` (or any init refusal) falls back to the direct `wm=` autostart
path, and `settings set wm none` keeps the bare monitor for gate runs. The
seat-facing shell itself — GOSH.ELF — is a userspace program; the monitor
remains underneath as the always-present administrative console.

## Exceptions and syscall entry

`VBAR_EL1` points at a 2048-byte vector table: sixteen self-contained
128-byte stubs, four exception types (synchronous, IRQ, FIQ, SError) times
the four architectural source modes. The kernel runs at EL1h, so the
EL1h slots carry the live entries. Every stub is position-independent —
no cross-region branch, no absolute address — because the flat image
applies no relocations.

Entry pushes a 256-byte general-purpose frame (x0–x17, x30, and the
callee-saved x19–x29 extension) onto the interrupted task's stack, plus a
512-byte FP/SIMD block holding q0–q31 — the kernel may use NEON freely
without corrupting EL0 state live across an exception. The shared
dispatcher receives the frame, `ESR_EL1`, `FAR_EL1`, `ELR_EL1`, `SPSR_EL1`,
and the vector kind. A synchronous `svc #0` from EL0 routes to the syscall
table — and only from EL0: an `svc` issued at EL1 stays on the
report-and-park path, because kernel code calls functions directly rather
than trapping. An IRQ runs the GIC acknowledge → timer handle → scheduler
tick → EOI chain and returns through the selected task's frame. An EL0
fault the demand-pager cannot resolve tears the faulting process down with
the reserved status 139 instead of parking the machine. A kernel fault
still reports `[EXC]` and parks — the class-B gate suite greps for exactly
that line as a failure signature.

Context switch is small by construction: because the stubs already save
the full frame, the scheduler only swaps the frame pointer, `ELR_EL1`,
`SPSR_EL1`, `SP_EL0`, and `TTBR0_EL1` to land in the next task exactly as
if it had been interrupted. The [[userspace|syscall ABI]] and
[[memory|the address-space model]] pages cover the two halves in detail.

## The scheduler

The scheduler is a tick-driven, preemptive round-robin over a fixed BSS
task pool — no dynamic task allocation, ever. The pool has grown by
measurement, not taste: 7 slots at bring-up, 11 when the first concurrent
programs exhausted it, 13, then 16 once Go runtimes arrived (each runtime
is several tasks: primary M plus sysmon and friends). It now stands at
**64 slots** — the M129 raise — after a boot that seats a service graph
plus a restored session proved the 16-slot pool was the sole concurrency
bound: a Go runtime's `newosproc` was refusing on `-EAGAIN` while physical
memory sat mostly free.

Each live task costs a 192 KiB (48-page) kernel exception stack allocated
at spawn plus roughly a kilobyte of BSS bookkeeping; sixty-one user slots
of worst-case stacks are about 2.3% of the ~494 MiB observed free at the
512 MiB default boot. The pool is deliberately *not* the exec wall — an
exec'd process also needs a page-table root out of a fixed carve-out, and
that bound bites first; the pool saturates only through `sys_thread`
children, which share their process's address space.

Selection works over per-core ready rings with cross-core steal, and a
scheduler-owned idle task — pinned at the last pool slot, always ready,
WFE-parked — is both the ring's fallback and the reaper that frees one
zombie per pass. Since M133 the scheduler ages tasks: a task preempted
after burning its whole slice accrues a decay penalty capped at five
skipped claims (`age_max`), so an always-running hog on a contended core
wins only about every sixth pick instead of every other one; a task that
commits to a real block — sleep, wait, futex — recovers its priority
immediately. Per-task tick attribution runs on every core, which is what
`tasks`, `resources`, and the `sys_procs` v2 CPU columns report.

Capacity refusals are named, never silent: an over-cap `sys_thread`
spawn returns `EAGAIN`, an over-cap exec reports `no free scheduler pool
slot`, and the spawn-storm proof is a class-B fixture that seats twelve
Go storm runtimes of slot-73 children until `resources` reads
`tasks=64/64` — with the seat still answering a probe.

<Aside kind="info">

**LIVE-GATED.** `live-lifecycle` and `live-tasks` pin the
spawn/exit/reap cycle and the idle reaper; `live-sched-ring` the ring
behavior; `live-scale` runs ten programs inside the pool; the `go-stress`
spawn-storm leg and `live-vm-depth` run 02 hold the 64-slot ceiling under
simultaneous CPU and memory pressure.

</Aside>

## SMP

Secondary cores come up over PSCI: `boot_secondary_cores` issues
`CPU_ON` for each Aff0 target until the virtual PSCI answers
`PSCI_NOT_PRESENT`, so a one-VCPU VM stays uniprocessor and a four-VCPU
VM runs all four — `smp.max_cores` is 4. A waking secondary arrives at a
naked assembly entry with the MMU off, picks its per-core 32 KiB BSS
stack by core id, then runs the same bring-up the boot core did:
exception vectors, the secondary-core MMU path, its GIC CPU interface
and redistributor, and its own timer — then parks in WFE until the
scheduler's rings reach it.

Cross-core work rides GICv3 software-generated interrupts written
through `ICC_SGI1R_EL1`: reschedule (SGI 0), TLB shootdown (SGI 1, which
broadcasts `tlbi vmalle1is`), and a counted ping (SGI 2). Sharing is
disciplined by domain: per-service locks rank the file, net, window,
event, and kernel domains in a fixed order, brief scheduler and
ring locks sit innermost, and IRQ-context code never takes a lock that
can sleep it.

<Aside kind="info">

**LIVE-GATED.** `live-smp` and `live-smp1` prove a second core comes up
and runs a task; `live-smp-stress` runs the four-core four-domain stress
shape; `live-smp-scale` keeps the pressure honest at the current pool
size; `go-goroutines` asserts a Go runtime's Ms actually run on a
secondary core.

</Aside>

## The exec path and ELF loader

`exec <file> [args…]` — the monitor command and syscall slot 28 share the
same loader — resolves a program on the host share and builds a real
process around it. The reader is capacity-first: the pool slot is checked
before any page is allocated (`pool_full`), then the page-table carve-out
(`table_full`), the process registry (`process_full`), and only then the
physical allocator (`out_of_memory`, reported to an EL0 caller as
`ENOMEM`). Nothing is allocated for a spawn that a capacity bound will
refuse.

The image formats all carry the same idea — bound everything, name every
refusal:

- **DSK1 flat** images and the segmented **DSK3** variant still transit a
  fixed 2 MiB staging buffer; a file larger than it is `staging_too_large`.
- A **contiguous-layout ELF** stages the same way; a **gap-layout ELF** —
  every `GOOS=virelai` Go binary — is parsed from a 16 KiB header window
  and has each `PT_LOAD` segment *streamed* straight from the share into
  the pages it will be mapped into, never staged whole. That path is what
  carries multi-megabyte Go payloads: a ~9.6 MiB file mapping ~51.5 MiB
  has been observed loading and running.
- A **PT_INTERP** image hands off to `LD.SO`, the freestanding runtime
  linker, which resolves imports against a pre-staged shared-library
  aperture (eight 64 KiB slots — the same bound `LD.SO` enforces, so the
  two halves cannot disagree) and jumps to `AT_ENTRY`.

The M72a bound split is the part worth remembering, because it is the
difference between file size and memory cost. `load_max` (32 MiB) bounds
**Σ filesz** — initialized bytes the file must contain; `map_max`
(64 MiB) bounds **Σ memsz** — the bytes the loader actually maps. Every
mapped page is eagerly allocated and zero-filled before EL0 runs, so
`map_max` is a RAM budget, not a format nicety. A Go image carrying a
huge zero-initialized `.noptrbss` costs almost no file bytes; under the
old single bound it was refused `segment_too_large` anyway. Today the
names split cleanly: `segment_too_large` for the file side,
`map_too_large` for the mapping side, `image_too_large` for a file past
the 32 MiB acceptance bound on any shape, `image_truncated` for a file
that ends before its headers promise. The table is in
[`exec.zig`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/kernel/src/exec.zig)
and [`elf.zig`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/kernel/src/elf.zig).

Arguments are a bounded block — eight 256-byte slots (255 usable bytes
plus NUL), `too_many_args`/`arg_too_long` refusing by name rather than
chopping — packed into the image along with a bounded 16×128-byte envp
block on the gap path; `_start` receives argc in x0 and the block address
in x1. Since the caller-survival fix (#1333), an EL0 `sys_exec` leaves
its *caller* intact: the parent describes its own address space as a
small scalar `AddrSpaceSpec` — pass-by-value on a bounded kernel stack —
instead of letting the loader touch its live structures. The gate for
that contract is `live-el0-exec`: a missing name returns `ENOENT` to an
untouched parent, a real child inherits argv, and the parent waits on it.

Every refusable outcome has a name — that is a deliberate policy. The
M133 work made it total: physical-page exhaustion reports `ENOMEM`
distinct from `pool_full`/`table_full`/`process_full`, a process that
exceeds its memory rlimit is reaped under the reserved status 140, and
the class-B evidence holds all of the names while the machine stays up.

<Aside kind="info">

**LIVE-GATED.** `live-exec`, `live-elf`, and `live-args` pin the loader
and argv contract; `live-el0-exec` pins caller survival; `go-hello`
carries the streamed multi-MiB payload proof; `live-dynamic-linking` and
`live-dynamic-ecosystem` cover `LD.SO`; `live-vm-depth` run 02 is the
named-refusal exhaustion journey.

</Aside>

## W^X and the aperture model

Every leaf an EL0 task can touch is a named *aperture* with a permission
pair — text is read+execute, data and stack are read+write, and UXN/PXN
are enforced on every user leaf, so no user page is ever both writable
and executable. The multi-aperture model grew with the dynamic linker:
instead of one text window, a process may hold its image segments, a
pre-staged shared-library aperture, mmap regions, and the stack, each
with its own bounds, and the uaccess layer validates every user pointer
against the caller's own aperture list armed at SVC entry. [[memory]] has
the paging side of the same story.

## Devices

The kernel drives its virtio devices directly — gpu, net, entropy, snd,
console, input, block — plus a bounded xHCI/USB path and the custom-virtio
channels to the host. The full catalog, including which transports are
boot defaults and which are opt-in, lives on [[drivers]]; the boot-order
invariant is the re-arm discipline described above.

<Aside kind="warning">

**LIMITATION.** The kernel has no kernel heap beyond fixed BSS pools and
no swap or memory-balloon reclaim. Every bound named on this page — the
64-slot pool, the 512-page table carve-out, the loader limits — is a real
wall a workload can hit, and the honesty rule means hitting one reports a
name, not a hang. What it never does today is *reclaim*: pages return to
the allocator at process reap, not under pressure.

</Aside>
