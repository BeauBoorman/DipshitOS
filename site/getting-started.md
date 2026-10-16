---
title: Getting started
status: published
tags: [guides]
---

# Getting started

VirelaiOS is built and run on **Apple silicon** with **macOS 27 or newer**.
There is no cross-compilation-to-QEMU escape hatch and no Linux host path —
that is a deliberate constraint, not a bug.

The short version:

```bash
git clone https://github.com/drawmeanelephant/VirelaiOS.git
cd VirelaiOS
zig build            # compile the AArch64 UEFI application
zig build image      # build the GPT+FAT32 disk image
zig build run        # boot it under Virtualization.framework
```

`zig build run` boots the whole thing and writes the kernel's serial output to
`artifacts/vm-serial.log`. You have booted an operating system that ends UEFI
Boot Services and drives the hardware itself.

## What you need

- **Apple silicon** Mac (any Apple-silicon generation the macOS floor supports).
- **macOS 27 or newer** — the launcher enforces this floor at runtime.
- **Zig 0.17.0** — pinned in the repo's `.zigversion`.
- **Swift + Xcode command line tools** — for the Virtualization.framework launcher.
- **Python 3** and **bash** — for the disk-image tooling and gate scripts.

No root privileges, no `mtools`, no third-party disk tooling. The GPT + FAT32
image is built by a small pure-Python builder.

## Two ways to look at it

- [[build|Building]] — every build target and what each one produces.
- [[run|Running the VM]] — the `virelai>` console, the graphical display, and the flag-gated device modes.

## Verifying your work

The project separates **two classes of evidence** — this matters if you change
anything and want to know whether you broke it:

<Aside kind="tip">

**LIVE-GATED vs DETERMINISTIC.** **Class A** checks are deterministic and run
in CI on every push — formatting, unit tests, a byte-identical console
transcript, the build/image pipeline. **Class B** gates boot a real
Virtualization.framework VM on Apple silicon and assert on what the kernel
actually reports. CI cannot run class B; a developer host can.

</Aside>

- `just verify-portable` runs the full class A set locally.
- `just verify-vz` runs the Apple-silicon live gates.
- The [[evidence]] page explains the claims-and-gates philosophy in detail.

<Aside kind="warning">

**LIMITATION.** Building and `zig build run` are not, by themselves, hardware
evidence of correctness — the transcript and unit tests prove the code paths,
but only the class B live gates observe the kernel running under real firmware.

</Aside>
