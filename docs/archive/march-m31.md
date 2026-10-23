> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone thirty-one march — dynamic linking ecosystem & userland migration (living tracker)

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts. This file holds M31's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

With Milestone 30 establishing the core dynamic linking foundation (freestanding
`LD.SO`, `LIBUI.SO`, `LIBFONT.SO`, multi-aperture W^X isolation, and AuxV
protocol), Milestone 31 expands dynamic linking across the entire userland
ecosystem. This milestone focuses on migrating existing desktop and CLI applications
from static binary compilation to dynamic linking, reducing binary disk footprints,
enabling runtime plugin loading (`dlopen`/`dlsym`), and optimizing library startup.

## The cards

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| E1 | **Dynamic CALC (`CALC.ELF`).** Migrate calculator application to dynamic linking against `LIBUI.SO` and `LIBFONT.SO`. | ✅ | `artifacts/live-m31-CALC.ELF-serial-1.log` (claim 4001) | Reduces binary size down to lightweight dynamic executable with plugin math routines. |
| E2 | **Dynamic NOTEPAD (`NOTEPAD.ELF`).** Migrate text editor to dynamic linking. | ✅ | `artifacts/live-m31-NOTEPAD.ELF-serial-1.log` (claim 4001) | Tests multi-window and clipboard interaction over dynamically linked symbols. |
| E3 | **Dynamic FILE Manager (`FILE.ELF`).** Migrate file manager to dynamic linking. | ✅ | `artifacts/live-m31-FILE.ELF-serial-1.log` (claim 4001) | Exercises file table / UI routines alongside shared widgets. |
| E4 | **Dynamic DESKTOP Shell (`DESKTOP.ELF`).** Migrate window manager / desktop composition shell to dynamic linking. | ✅ | `artifacts/live-m31-DESKTOP.ELF-serial-1.log` (claim 4001) | Validates dynamic desktop session running purely dynamic binaries. |
| E5 | **Userland Dynamic Plugin Loading (`dlopen` / `dlsym`).** Expose dynamic symbol resolution interface for runtime loadable modules (`PLUGIN.SO`). | ✅ | `artifacts/live-m31-CALC.ELF-serial-1.log` (claim 4001) | Enables runtime loadable modules, skins, and plugin extensions via `LD.SO`. |
| E6 | **Multi-App Dynamic Session & Class-B Live Hardware Gate.** Live hardware verification across all dynamic executables. | ✅ | `artifacts/m31-dynamic-ecosystem-live.txt` (claim 4001) | Live verification script `tools/verify-live-dynamic-ecosystem.sh` (ALL 1 boot passed 5/5 apps). |

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Application Migration & Extensions** | `tools/mkdyn-elf.py`, `user/src/ld.zig`, `user/src/libui_so.zig`, `user/src/libfont_so.zig` | M30 done (`LD.SO`, `LIBUI.SO`, `LIBFONT.SO`). |
