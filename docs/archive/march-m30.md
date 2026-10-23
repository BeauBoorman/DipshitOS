> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone thirty march — dynamic linking & shared libraries (living tracker)

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts. This file holds M30's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

VirelaiOS userland has evolved into a rich graphical, multitasking environment
with windowing, widgets, networking, audio, and shell commands. However, all
applications historically statically compiled duplicate UI routines, font
tables, and syscall wrappers, consuming redundant memory and ESP disk space.
Milestone 30 introduces freestanding dynamic ELF linking and shared library
support (`LD.SO`, `LIBUI.SO`, `LIBFONT.SO`) with zero libc/POSIX dependencies,
strict W^X multi-aperture virtual memory isolation, and a live hardware gate.

**Zero new syscall slots.** All dynamic linking and symbol resolution takes
place purely in user space via the auxiliary vector protocol (`AT_PHDR`,
`AT_ENTRY`, `AT_BASE`, `AT_PAGESZ`) and the runtime linker `LD.SO`.

## The cards

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| D1 | **Kernel Dynamic ELF Loader & Multi-Aperture Subsystem.** Support 64-bit dynamic ELFs with `PT_DYNAMIC`, `PT_INTERP`, Aux Vector encoding, and multi-aperture root construction. | ✅ | claim 7921: `kernel/src/elf.zig`, `kernel/src/exec.zig`, `kernel/src/mmu.zig`; `zig test kernel/src/elf.zig` (11 tests pass) | Enhances ELF parser with 64-bit ELF data structures, dynamic tags (`DT_NEEDED`, `DT_STRTAB`, `DT_SYMTAB`, `DT_RELA`, `DT_JMPREL`), Aux Vector (`AT_PHDR`, `AT_ENTRY`, `AT_BASE`, `AT_PAGESZ`), and sets up multi-aperture TTBR0 roots enforcing W^X isolation. |
| D2 | **Freestanding Runtime Dynamic Linker (`LD.SO`).** Zero-libc, zero-POSIX dynamic runtime linker in user space. | ✅ | claim 7921: `user/src/ld.zig`, `user/ld.ld`; `verify-live-dynamic-linking.sh` PASS (2026-08-27) | Implements freestanding dynamic linker that inspects `PT_DYNAMIC`, searches pre-staged shared libraries in the library aperture (`0x01000000`), resolves imported function symbols, relocates the GOT table (`R_AARCH64_JUMP_SLOT`, `R_AARCH64_GLOB_DAT`, `R_AARCH64_RELATIVE`), and jumps to `AT_ENTRY`. |
| D3 | **Core Shared Libraries (`LIBUI.SO`, `LIBFONT.SO`).** Position-independent shared libraries exporting userland UI and font rendering APIs. | ✅ | claim 7921: `user/src/libui_so.zig`, `user/src/libfont_so.zig`, `user/so.ld`, `build.zig` | Exports core windowing/UI routines (`ui_write`, `ui_win_open`, `ui_win_fill`, `ui_win_present`, `ui_win_close`, `ui_exit`) and font metrics (`font_glyph_width`, `font_glyph_height`, `font_draw_char`). |
| D4 | **Dynamic Executable & Class-B Live Hardware Gate.** End-to-end dynamic application execution under real hardware/VZ VM. | ✅ | claim 7921: `user/src/dynapp.zig`, `tools/verify-live-dynamic-linking.sh` PASS 1/1 boots (2026-08-27) | `DYNAPP.ELF` links against `LIBUI.SO` and `LIBFONT.SO`, successfully launches via `LD.SO`, opens/fills/presents/closes windows, and cleanly exits (status 0). Live gate asserts banner, loader, linker output, app execution, clean exit, and zero faults (`fatal=0`). |

## Notes

1. **Memory Isolation (W^X):**
   - Executable text: `0x00400000` (R-X)
   - Executable data/bss: `0x00401000` (RW-)
   - Interpreter text: `0x00800000` (R-X)
   - Interpreter data/bss: `0x00801000` (RW-)
   - Shared library aperture: `0x01000000` (R-X)
   - User stack: Random ASLR VA (RW-)
2. **Auxiliary Vector ABI:**
   The kernel passes the aux vector at `x2` / stack pointer offset, providing `AT_PHDR`, `AT_PHENT`, `AT_PHNUM`, `AT_PAGESZ`, `AT_BASE`, `AT_ENTRY`, and `AT_NULL`.
