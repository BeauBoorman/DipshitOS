---
title: Repository layout
parent: development
status: published
tags: [development, layout]
---

# Repository layout

```text
virelaios/
├── AGENTS.md                  project rules (read first)
├── README.md                  concise landing surface → this site
├── build.zig / build.zig.zon  root build system (Zig 0.17)
├── justfile                   command aliases
├── .zigversion                pinned Zig version (0.17.0)
├── boot/src/main.zig          the AArch64 UEFI boot loader (handoff v2)
├── kernel/src/*.zig           the freestanding kernel + all subsystems
├── user/src/*.zig             the EL0 demo programs (built to .BIN images)
├── user/go/                   the Go userland (apps + sh, GOOS=virelai)
├── host/vm-runner/            the Swift Virtualization.framework launcher
├── image/                     the pure-Python GPT+FAT32 image builder
├── tools/                     gate specs + fleet, elf2bin, mkdyn-elf, status indexes
├── site/                      THIS public documentation corpus (compiled by Boris)
├── themes/virelaios/          the site theme
├── docs/                      the engineering warehouse (claims/decisions/status/…)
└── artifacts/                 build evidence (gitignored)
```

## Kernel subsystem map

| Module | Subsystem |
|--------|-----------|
| `mmu.zig`, `memmap.zig`, `handoff.zig` | MMU takeover, memory map, handoff contract |
| `alloc.zig` (allocator), `pages` | physical allocation |
| `exceptions.zig`, `gic.zig`, `timer.zig` | vectors, GICv3, the timer PPI |
| `scheduler.zig`, `process.zig`, `mailbox.zig` | tasks, processes, IPC |
| `syscall.zig`, `uaccess.zig` | the frozen syscall ABI + fault-safe copies |
| `fat32_ro.zig`, `virtio_file.zig`, `file_table.zig`, `usb_msc.zig` | read-only FAT, the host-share channel, the file ABI, USB mass storage |
| `virtio_entropy.zig`, `csprng.zig` | entropy + ChaCha20 |
| `virtio_net.zig`, `arp.zig`, `ipv4.zig`, `udp.zig`, `dhcp.zig`, `tcp.zig` | the network tower |
| `virtio_gpu.zig`, `text.zig`, `road_pops.zig`, `driving_award.zig` | graphics + window manager |
| `xhci.zig`, `input.zig`, `usb_msc.zig` | USB XHCI + HID + MSC + event FIFO |
| `console.zig`, `lineedit.zig`, `tokenizer.zig`, `shell.zig`, `monitor.zig` | the interactive monitor |

The README's own layout block is the most current enumeration; this table is
the subsystem map.

## Site + theme

- `site/` — Boris-authored Markdown (trunks and satellites, wiki-linked).
- `themes/virelaios/` — the Boris theme (layout, CSS, footer).
- `.github/boris-pin.json` — the single pinned Boris toolchain revision.
- `.github/workflows/` — the docs gate and the Pages publish workflow.

See [[development]] for how the public site and the warehouse relate.
