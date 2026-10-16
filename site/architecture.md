---
title: Architecture
status: published
tags: [architecture, overview]
---

# Architecture

VirelaiOS is a layered, freestanding kernel with no libc and no heap in the
boot-critical paths — bounded fixed-BSS storage is the norm. This page is the
map; the satellites below carry the detail.

## The stack, top to bottom

```text
┌───────────────────────────────────────────────┐
│  EL0 user programs + desktop apps (GOCALC.ELF, │
│  GOTABWM.ELF, GO* Go apps, …)                 │
│  runtime linker LD.SO + LIBUI.SO/LIBFONT.SO   │
│  syscalls: 80 implemented slots (of 128):     │
│  IPC/window/events/files/net/time/memory …    │
├───────────────────────────────────────────────┤
│  Monitor + shell (virelai>)                   │
│  Road Pops terminal · Driving Award compositor │
├───────────────────────────────────────────────┤
│  SMP scheduler (round-robin, 2 cores)         │
│  EFI-map allocator · MMU (per-process roots,  │
│  demand-zero paging + copy-on-write; no swap) │
├───────────────────────────────────────────────┤
│  Drivers: virtio console/entropy/gpu/net/snd/  │
│  custom + USB XHCI (HID + MSC) · GICv3 · timer │
├───────────────────────────────────────────────┤
│  UEFI boot loader (BOOTAA64.EFI)              │
└───────────────────────────────────────────────┘
```

## What owns what

- [[kernel|Kernel overview]] — boot, `ExitBootServices`, exception vectors, the monitor and command registry.
- [[memory|Memory model]] — the physical allocator, identity-map page tables, per-task address spaces.
- [[userspace|Userspace & syscalls]] — EL0, the frozen syscall ABI, fault-safe uaccess, exec and processes.
- [[drivers|Device drivers]] — the virtio surface, the XHCI USB controller, and the MMIO contracts.

## Design discipline

Three rules show up everywhere:

1. **Bounded static storage.** Rings, FIFOs, window tables, and frame buffers
   use fixed-capacity storage. There is no general heap in the device paths;
   full queues refuse work or apply their documented overflow policy rather
   than growing.
2. **Per-device contracts.** Queue capacity, request concurrency, and
   completion handling vary by device. Hardware behavior is observed rather
   than generalized, then recorded in
   [`docs/hardware-contract.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/hardware-contract.md).
3. **Evidence over assertion.** Every subsystem has host tests (deterministic)
   and, where hardware is involved, a live Virtualization.framework gate. See
   [[evidence]].

## Subsystem boundaries in one line each

| Subsystem | What it does |
|-----------|--------------|
| Boot loader | loads `KERNEL.BIN`, writes `BOOTED.TXT`/`RC.TXT` evidence, jumps to the kernel |
| MMU | identity-map TTBR0_EL1 tables (T0SZ=16), per-process user roots, EL1-only kernel overlay, demand-zero `mmap` pages and copy-on-write (M29) — no swap |
| Allocator | first-fit bitmap over the captured EFI map, with exclusion ranges |
| Scheduler | fixed 16-task pool, tick-driven scheduling, SMP support and per-core ready rings |
| Processes | bounded registry, lifecycle states, exit-status propagation, IPC mailboxes |
| SMP | PSCI `CPU_ON` core bringup, per-core schedulers, spinlocks, GICv3 SGI IPIs (M28) |
| Syscalls | ADR 0007: 128-slot table, 88 registered slots (0–87), deterministic counters |
| Networking | virtio-net → ARP → IPv4/ICMP → UDP → DHCP → DNS → TCP (client + `GOHTTPD.ELF` passive-open server), plus a NAT mode and the EL0 TCP seam |
| Graphics | virtio-gpu framebuffer → text → Road Pops → Driving Award compositor |
| Audio | virtio-snd → PCM playback → `beep` → the EL0 audio seam (slots 42–45) |
| Input | XHCI host controller → USB enumeration → HID boot protocol → event FIFO → per-process event queues |
| Events | keyboard/pointer/window events routed to focused EL0 apps (`sys_poll_event`/`sys_wait_event`), plus `TIMER` events from the app-timer facility |
| Shared services | the machine-global clipboard (slots 38/39) + per-process app timers (slots 40/41) |
| Dynamic linking | freestanding `LD.SO` runtime linker, `LIBUI.SO`/`LIBFONT.SO`, W^X multi-aperture userland (M30/M31) |
| Desktop | the zero-heap `ui.zig` widget toolkit + the Go seat (`GOTABWM.ELF`) and hosted clients (`GOCALC.ELF`, `NOTE.ELF`, `GOTOP.ELF`, `GOFILES.ELF`) |

<Aside kind="note">

**SMP IS SHIPPED.** The architecture was single-CPU until M28; it now boots
two cores (PSCI `CPU_ON`, per-core schedulers, spinlocks, GICv3 IPIs) but
stays single-display and 2D-blit-only. Multi-display and accelerated/3D
paths remain explicit non-goals for now.

</Aside>
