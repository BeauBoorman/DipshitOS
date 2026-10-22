---
title: Repository layout
parent: development
status: published
tags: [development, layout]
---

# Repository layout

The tree divides into five zones: the **guest** (`boot/`, `kernel/`,
`user/`), the **host** (`host/vm-runner/`), the **image and tooling**
(`image/`, `tools/`), the **documents** (`docs/`, `site/`, `cards/`), and
the **evidence** (`artifacts/`, `.build/` — both gitignored).

```text
virelaios/
├── AGENTS.md                  project rules — read first
├── README.md                  landing surface → this site
├── LICENSE                    source-available, not open source
├── build.zig / build.zig.zon  the root build (Zig 0.17.0)
├── justfile                   every recipe a contributor runs
├── .zigversion                the pinned Zig version
├── boot/src/                  the AArch64 UEFI boot loader
├── kernel/                    the freestanding kernel (src/, linker.ld)
├── user/                      EL0 programs — see below
├── host/vm-runner/            the Swift Virtualization.framework package
├── image/                     the disk-image builder + app manifest
├── tools/                     gates, status tooling, toolchain pins
├── test/ tests/               host-side mocks and fixtures
├── docs/                      the engineering warehouse
├── cards/                     card drafts (filed issues are canonical)
├── site/                      THIS corpus — compiled by Boris
├── themes/virelaios/          the site theme
├── assets/                    mascot/wallpaper rasters
├── artifacts/                 gate + build evidence (gitignored)
├── .build/                    materialized SDKs, Go ELFs (gitignored)
└── .github/                   workflows + the Boris toolchain pin
```

## The guest

`boot/src/main.zig` is a UEFI application — a boot *loader*, not the
kernel. It loads `KERNEL.BIN` from the ESP, verifies its pinned SHA-256,
allocates pages, and transfers control under a versioned handoff contract.

`kernel/src/` is the whole freestanding kernel: boot sequence and init
order (`main.zig`), the MMU takeover and memory map (`mmu.zig`,
`memmap.zig`, `handoff.zig`), exceptions and interrupts (`exceptions.zig`,
`gic.zig`, `timer.zig`), scheduling and processes (`scheduler.zig`,
`process.zig`, `mailbox.zig`), the append-only syscall table
(`syscall.zig`, `uaccess.zig`), the virtio drivers (`virtio_*.zig` — gpu,
net, snd, blk, console, file, fs, custom, vsock, entropy) plus
`xhci.zig` with USB HID/MSC (`input.zig`, `usb_msc.zig`), the filesystems
(`fat32_ro.zig`, the `vlfs/` journaled volume), and the interactive
`virelai>` monitor (`console.zig`, `lineedit.zig`, `shell.zig`,
`monitor.zig`). [[kernel]] and [[drivers]] walk the subsystems.

`user/` is three populations sharing one ABI:

- `user/src/` — the surviving freestanding **Zig EL0 programs**, each
  built by `elf2bin.py` into a flat `.BIN` image (or a segmented/`.ELF`
  layout) and seeded onto the host share: the retained `TABWM.BIN`
  fallback seat, the WASM interpreter, the assembler/disassembler/dev
  tools, and the gate fixture fleet. ADR 0030 froze this set — new
  userland is Go.
- `user/go/` — the **Go EL0 fleet**: ~80 packages compiled for
  `GOOS=virelai` — the seat (`gotabwm`), the shell engine (`shlib`,
  `sh`), the SDK (`vi`, `tabapp`, `draw`, `widgets`, `appkit`), and the
  apps (files, edit/note, term, web, calc, store, flint, …).
- `user/zig/` — the bounded **native Zig portfolio** (ADR 0038): a small
  approved set of in-guest Zig compile targets and libraries, not blanket
  authorization for new apps.
- plus the linker scripts (`linker.ld`, `linker-segmented.ld`, `dyn.ld`,
  `ld.ld`, `so.ld`) and `user/tests/`.

## The host

`host/vm-runner/` is one SwiftPM package. The `VMRunner` executable is
the gate entrypoint (serial takeover, device flags, scripted input);
`VMAppKit` is the windowed front end `tools/session.sh` bundles into the
per-run `VirelaiOS.app`. Most targets are deliberately free of
Virtualization.framework imports — `VFWire`, `VSSH`, `VSNTP`,
`VMPostmortem`, `VMDiskImage`, `VMProfile`, `VMTcp`, `VSCtl`, `VMGPU3D` —
so `swift test` pins the wire codecs and state machines without a VM.
`SoundInProbe` is a standalone audio-capture probe executable;
`Tests/VMRunnerTests` is the host suite. [[machine]] covers the host side.

## Image and tooling

`image/` builds the boot volume: `make-image.sh` + `mkfat32.py` (a
pure-Python GPT+FAT32 writer — no `mtools`), `apps.txt` (the versioned
app-manifest schema), `fleet-grants.txt` (per-app capability rows), the
font set, and `WALLPAPER.QOI`.

`tools/` is where the project keeps its seriousness:

- `tools/gate/` — the **declarative gate fleet**: `SPEC.md` (the frozen
  spec format), `specs/` (every class-B spec — discovered, not listed),
  `vgate.sh` (the executor), `fleet.sh` (discovery + runner),
  `bench/` (the benchmark corpus + budgets).
- `tools/status/` — the claims surface: `new-claim.sh`, `claim-card.sh`,
  `verify-issue-coordination.sh`, `test-coordination.sh`, the staleness
  sweep and unlabel rehearsal.
- `tools/go/` — the `GOOS=virelai` fork machinery: `apply.sh` +
  `overlay/`, and one `build-*.sh` per shipped Go ELF.
- `tools/zig/` — the pinned Zig SDK: `lock.json` + `sdk.py`.
- `tools/lib/` — shared gate helpers (`gate-run.sh`, `vgate-client.py`);
  `tools/tests/` — host-side Python suites; `tools/flint/`, `tools/fonts/`,
  `tools/context/`, and the utility scripts (`elf2bin.py`,
  `mkdyn-elf.py`, `inspect.sh`, `env-check.sh`, `session.sh`,
  `remote-terminal.sh`, `inventory-gates.sh`, `lint-workflows.sh`).

`test/` holds the Zig unit-test mocks and helpers; `tests/` holds the
checked-in fixtures — the `virelai>` transcript golden, the RFB wire
captures, the WASM/virelai-probe contract tests.

## Documents

`docs/` is the unpublished warehouse: `status.md` (the canonical ledger —
a compact table, not a changelog), `testing.md` (policy + classes),
`hardware-contract.md` (observed vs inferred), `gate-inventory.md` +
the generated `gate-fleet-inventory.md`, `decisions/` (the ADR set —
sixty-one and counting), `TEAMS.md` (ownership convention), `app-authoring.md`
(the empty-app-to-staged-ELF path), the retired `march-m*.md` trackers,
and `archive/` (closed-milestone detail, frozen designs).

`cards/` holds card drafts — SUMMARY plus per-card shapes. Filed GitHub
issues are canonical; the drafts are planning ground truth only.

`site/` + `themes/virelaios/` are this documentation corpus and its Boris
theme; `.github/boris-pin.json` pins the compiler revision the docs gate
and Pages workflow share. `site/index.assets/` carries content-local
assets.

`artifacts/` and `.build/` are gitignored output: `disk.img`, serial logs,
gate reports and receipts under `artifacts/`; the materialized Zig SDK and
`.build/go/*.ELF` under `.build/`. Evidence lives there or in CI — never
committed as logs.

See [[development]] for how the site and the warehouse relate, and
[[contributing]] for the gate-fleet rules.
