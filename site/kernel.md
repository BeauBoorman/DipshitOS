---
title: Kernel
parent: architecture
status: published
tags: [architecture, kernel]
---

# Kernel

Freestanding AArch64 kernel written in Zig. **No libc, no POSIX, and no
existing guest OS in the boot path.**

## Boot

The AArch64 UEFI application loads `KERNEL.BIN`, passes the captured EFI
memory map and handoff data, and transfers control to the kernel. The kernel
exits UEFI Boot Services, installs its exception vectors and identity-mapped
page tables, then initializes the devices it uses directly. The boot volume
contains `EFI/BOOT/BOOTAA64.EFI` and `KERNEL.BIN`; applications and writable
files are supplied through the host share.

<Aside kind="info">

**VERIFIED.** Every boot step up to the shell handoff is pinned by the
class-A `boot-kernel` spec, replayed against the runner.

</Aside>

## The core

 - **Address translation:** the kernel and its EL1-only identity map stay
   reachable under task roots; each process receives its own EL0 mappings.
 - **Exceptions:** `VBAR_EL1` points to the AArch64 vector table. Entry saves
   the general-purpose and FP/SIMD register state before dispatch, then
   restores the selected task's frame.
 - **Scheduling:** a fixed pool of 16 task slots, with per-core ready rings;
   allocation is bounded and does not grow the pool dynamically.

<Aside kind="info">

**VERIFIED.** The current exception and address-translation paths are
implemented in `kernel/src/exceptions.zig` and `kernel/src/mmu.zig`; see
[[evidence]] for how source checks differ from live hardware observations.

</Aside>

## Syscall seam

The syscall ABI is an append-only 128-slot table with **88 registered
entries, slots 0–87**. It covers process control and IPC, windows and events,
files and networking, time, threads, anonymous mappings, filesystem
metadata, native sockets, and the observability/pid surface. Reserved table
entries return `ENOSYS`.

See [[userspace|Userspace & syscalls]] for the current numbered interface and
[`kernel/src/syscall.zig`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/kernel/src/syscall.zig)
for the implementation.

<Aside kind="info">

**LIVE-GATED.** The table row-by-row pin set is `live-user-fs`,
`live-concurrent`, `live-wait`, `live-ipc`, `live-net-udp-syscall`,
`live-net-tcp-syscall`, `live-events`, `live-sys-kill`, `live-desktop`,
`live-exit`, and `live-roadpops`.

</Aside>

## Identity & drivers

- **virtio-gpu** (`virtio_gpu.zig`): spec 2D path — `GET_DISPLAY_INFO` →
  `CREATE_2D` → `ATTACH_BACKING` → `SET_SCANOUT` → `TRANSFER` → `FLUSH`
  (4 KiB-aligned BSS framebuffer).
- **virtio-net** (`virtio_net.zig`): RX → ARP/ICMP/UDP/TCP (SYN..FIN,
  sliding window), TCP feature path on `--net-tcp`; UDP/TCP direct path.
- **Host files:** the same `/host` file API uses either the custom-virtio
  queue-5 channel (`--cvc-file`) or explicitly selected standard VirtioFS/FUSE
  (`--virtio-fs`). VirtioFS is opt-in; it does not change the boot default.
- **virtio-input** (`virtio_input.zig`): IRQ + snapshot ring → fixed-point
  pointer motion (the CG class gates).
- **virtio-rng** (`virtio_rng.zig`): the stack's only entropy source.
- **Virtio-console** (`virtio_console.zig`): `--console-tcp <port>` serves a
  real TCP listener at EL0; `live-devcons` boots 2 VMs and connects both
  directions.
- **USB xHCI** (`xhci.zig`): a bounded xHCI driver with a slot/context
  array, 32 doorbells, scratchpad allocator, transfer ring, and the
  `LLGT` low-level common-setup entry point (L4), with a
  class/subclass/protocol match table. Two class paths are live: **HID boot
  protocol** (`input.zig` — the keyboard/pointer behind `--input`; two known
  devices, no hubs, no full report-descriptor parser; gates `live-usb`,
  `live-input`) and **mass storage** (`usb_msc.zig` — Bulk-Only Transport +
  minimal SCSI over `--usb-msd`, raw sector write/read-back; gate
  `live-usb-msc`), with `fat32_ro.zig` providing the read-only FAT view.
- **Storage today** is the host share through the `/host` API — see
  [storage](storage.md) for both transports and their limits.

<Aside kind="warning">

**LIMITATION.** `screen` is the shared cross-platform screen path (running
headless, dumped to disk after boot) — it is not the Apple Virtualization
frame-capture path (see `docs/testing.md`).

</Aside>
