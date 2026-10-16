---
title: Drivers
parent: architecture
status: published
tags: [architecture, drivers]
---

# Drivers

VirelaiOS initializes the devices it uses directly after leaving UEFI Boot
Services. There is no generic guest driver manager or shared `DriverCfg`
registration interface; the kernel's device modules own their initialization,
bounded state, and hardware-specific limits.

## What's implemented

- **VirtIO devices.** The kernel includes virtio-console, entropy, GPU,
  network, sound, and file modules. Their queue sizes and feature negotiation
  differ by device; for example, virtio-net uses size-4 RX/TX queues, while
  the retained custom-virtio file channel uses size-32 queues. The network
  implementation provides bounded Ethernet RX/TX over queues 0 and 1; it does
  not implement RSS or multi-queue pair selection.
- **Host files.** The guest-facing `/host` API can use the retained
  custom-virtio file channel or the explicitly selected standard VirtioFS/FUSE
  backend (`--virtio-fs`).
- **Block.** `virtio_blk.zig` (M100b) is a read/write virtio-blk driver for a
  second DID-0x1042 function attached with `--data-disk`: pre-exit PCI
  collection, post-MMU re-arm, `GET_ID` naming (`virelai-vlfs`), and a
  negotiated FLUSH barrier (gate `live-vlfs-blk`). The kernel's VLFS reader
  mounts a `mkfs.vlfs`-formatted image read-only at `/disk`. The boot volume
  itself stays firmware-read — no guest code touches it post-exit.
- **USB.** `xhci.zig` provides a bounded XHCI host controller and
  class/subclass/protocol matching. HID boot-protocol devices provide
  keyboard and pointer input; USB mass storage uses Bulk-Only Transport and
  minimal SCSI through `usb_msc.zig`. The USB FAT32 reader is read-only.
- **AHCI / ATA.** No guest AHCI or ATA driver is present.

See [[storage|Storage & filesystem]] for the host-file and USB storage
boundaries, and [[input|Input]] for HID support and its device limits.

## Verification

Each device seam has its own deterministic tests and, where applicable, a
named live gate in the discovered gate fleet. `just gate-list` lists the
current fleet; the relevant specs under `tools/gate/specs/` describe the
acceptance checks.

## Timing

The architectural timer runs at EL1 and supplies the kernel's tick-based
deadlines. The wall clock is separate: firmware may supply a boot-time epoch,
which advances with the ticks; the SNTP path can set it through syscall slot
78. Without a firmware epoch or a successful set, wall-clock reads report no
available time. There is no separate RTC device.

<Aside kind="warning">

**LIMITATION.** Drivers are device-specific and bounded, not instances of a
generic framework. USB HID supports boot-protocol devices only: two known
devices, no hubs, and no full report-descriptor parser. USB FAT access is
read-only; there is no guest-side writable FAT filesystem.

</Aside>
