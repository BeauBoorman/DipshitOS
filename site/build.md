---
title: Building
parent: getting-started
status: published
tags: [guides, build]
---

# Building

The root build system is written in Zig 0.17.0. Everything is orchestrated by
`zig build` plus a small set of shell/Python helpers for the disk image.

## Build targets

```bash
zig build                # compile the AArch64 UEFI application -> zig-out/bin/BOOTAA64.EFI
zig build image          # build the GPT+FAT32 boot image -> artifacts/disk.img
zig build inspect        # inspect the EFI binary and the disk image
zig build context        # regenerate artifacts/context.md (deterministic project snapshot)
zig build test-console   # byte-identical transcript test (mock console, no VM)
zig build console        # boot an interactive virelai> console (Apple silicon)
zig build run            # boot with Swift + Virtualization.framework (Apple silicon)
```

`just` aliases exist for the same commands (`just build`, `just image`,
`just run`, …).

## What each stage produces

| Target | Product |
|--------|---------|
| `zig build` | `zig-out/bin/BOOTAA64.EFI` — a `PE32+ executable (EFI application) Aarch64` |
| `zig build image` | `artifacts/disk.img` — a GPT + FAT32 image with `EFI/BOOT/BOOTAA64.EFI` and `KERNEL.BIN` |
| `zig build inspect` | EFI binary section/disassembly inspection + GPT header + volume checks |
| `zig build test-console` | a deterministic mock-console transcript fixture |

The kernel is built separately as a freestanding flat image (`KERNEL.BIN`,
format v1) converted from ELF by `tools/elf2bin.py`. User programs (`.BIN`
files such as `USER.BIN`, `COUNTER.BIN`, `PEER.BIN`, `UDP.BIN`) are
built the same way and seeded onto the host share so `exec` can load them. Since
M30/M31 the pipeline also produces dynamic ELF executables (`.ELF`) and
shared libraries (`LD.SO`, `LIBUI.SO`, `LIBFONT.SO`) — regenerated as gate
fixtures by `tools/mkdyn-elf.py` — that the guest's own
runtime linker resolves — no host toolchain beyond Zig and `elf2bin.py`.

## The two executables

- `boot/src/main.zig` — a UEFI application (now a boot **loader**): loads
  `KERNEL.BIN` from the ESP, allocates pages, maintains caches, and jumps to
  the kernel entry with a versioned handoff contract.
- `kernel/src/main.zig` — the freestanding kernel: validates the handoff,
  captures the EFI memory map, exits Boot Services, installs identity-map page
  tables, and drives the console and every subsystem above it.

## Pinned toolchain

Zig **0.17.0** is pinned in `.zigversion`. The host launcher builds with Swift
(`swift build --package-path host/vm-runner`) against the macOS 27
Virtualization.framework.

<Aside kind="note">

**PLANNED / NOT APPLICABLE.** There is no QEMU target, no `make`, no CMake for
the OS itself, and no libc. If a build instruction tells you to install a
Linux toolchain, it is describing a different project.

</Aside>
