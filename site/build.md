---
title: Building
parent: getting-started
status: published
tags: [guides, build]
---

# Building

Everything in the guest is orchestrated by one root
[`build.zig`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/build.zig)
written against Zig 0.17.0 (pinned in `.zigversion`), with small
shell/Python helpers for the disk image, the Go userland, and the Swift
host launcher. There is no `make`, no CMake, no QEMU target — and no libc
anywhere in the guest.

## The Zig pipeline

`zig build` produces two artifacts. The first is `BOOTAA64.EFI`, a
`PE32+` UEFI application compiled from `boot/src/main.zig` — the boot
loader that finds `KERNEL.BIN` on the ESP, allocates pages, applies the
handoff contract, and jumps to the kernel entry. The second is the kernel
itself: `kernel/src/main.zig` compiles to a freestanding AArch64 ELF
(always `ReleaseSmall` — the kernel must stay position-independent), which
`tools/elf2bin.py` then converts into `zig-out/bin/KERNEL.BIN`, a flat
"KRN2" image carrying its own absolute-relocation table so the loader can
place it anywhere. The kernel image's SHA-256 is then compiled back into
the loader itself — the measured-boot pin (ADR 0054) that makes
`BOOTAA64.EFI` refuse a tampered `KERNEL.BIN`.

The rest of `build.zig` is a long roster of per-program steps — one per
EL0 program in `user/src/` — each producing a `.BIN` flat image or a
dynamic `.ELF` under `zig-out/bin/` by the same `elf2bin`/linker path.
`zig build test` runs the host-side unit suites in parallel (per-module
`zig test` runs plus the Python suites in `tools/tests/`); a few app roots
with noisy stderr run as direct `zig test` invocations from
`tools/verify-unit-tests.sh` instead.

| Step | What it produces |
|------|------------------|
| `zig build` | `zig-out/bin/BOOTAA64.EFI` + the kernel/user binaries |
| `zig build kernel` | `zig-out/bin/KERNEL.BIN` (the flat image only) |
| `zig build image` | `artifacts/disk.img` — GPT + FAT32 boot volume |
| `zig build inspect` | EFI section/disassembly dump + GPT/volume checks (`tools/inspect.sh`) |
| `zig build test` | parallel host unit-test suites |
| `zig build test-console` | the deterministic `virelai>` transcript diff |
| `zig build context` | `artifacts/context.md`, a deterministic project snapshot |

`zig build image` runs `image/make-image.sh` over `image/mkfat32.py`, a
pure-Python FAT32 builder — no `mtools`, no root. Since the host file
channel landed, the image is a **boot volume only**: `EFI/BOOT/BOOTAA64.EFI`
and `KERNEL.BIN`. Applications and writable files are no longer embedded;
they are staged onto the host share that gates and sessions seed.

`zig build test-console` replays the monitor against a mock console and
diffs the captured bytes against the checked-in fixture
`tests/transcript-console.txt` — a byte-identical transcript gate that
needs no VM. The boot/run steps sit on top of the image — see
[[run|Running the VM]] for what they do at runtime: `zig build run`
(serial takeover, the class-B entry gate), `zig build console` (interactive
`virelai>`, class C), and `zig build session` (the windowed desktop, class
C). A handful of `-D`-flagged diagnostic builds (`-Dnvram-console`,
`-Dpreexit-tx`, `-Dtx-diag`, `-Dbad-handoff`, …) exist purely as gate
mechanisms; default builds stay byte-identical.

## The Go EL0 fleet

The product userland — the seat, the shell, the apps — is Go, compiled for
`GOOS=virelai` from the packages under `user/go/`. The toolchain is a
**forked copy** of the stock Go distribution, not a vendored tree:
`bash tools/go/apply.sh` copies a stock GOROOT into a sibling directory
(`../go-virelai` by default, `GO_FORK_DIR` to override), overlays
`tools/go/overlay/`, applies the small runtime patches, and commits the
delta for reviewability. It is idempotent — and `tools/env-check.sh`
diffs the fork against the overlay on every session start, because a stale
fork silently builds every Go ELF against an old runtime.

Per-app build scripts under `tools/go/` (`build-gosh.sh`,
`build-gotabwm.sh`, `build-gowelcome.sh`, one per shipped ELF) produce
`.build/go/*.ELF`; `just go-toolchain` runs the batch that builds the
class-B gate fixture fleet (`GOHELLO.ELF`, `GOARGS.ELF`, `GOWIN.ELF`, and
friends) plus the in-guest self-host driver. The first run takes several
minutes — a full `make.bash` pass. Gates and sessions then **stage** the
ELFs onto a host share directory (`tools/lib/gate-run.sh`'s
`gate_seed_share`, or `tools/session.sh`'s incremental stager, which skips
re-copying files whose share copy already matches `.build/go/`). Class-B
specs that need Go binaries refuse honestly, by name, when the fixture has
not been built on this machine.

<Aside kind="note">

**PLANNED.** `GOOS=virelai` work is gated: the Go unit tests
(`go -C user/go test ./...`) run everywhere, but the class-B fleet
(`go-hello`, `go-wm-default`, and friends) only runs where the fork and
fixtures are provisioned. `just verify-vz` says exactly which prerequisite
is missing rather than guessing.

</Aside>

## The Swift host launcher

`host/vm-runner` is a SwiftPM package. The `VMRunner` executable is the
gate entrypoint — a CLI that boots `artifacts/disk.img` under
`VZEFIBootLoader`, wires serial/devices/share attachments, and records the
log. `VMAppKit` is the windowed front end `tools/session.sh` wraps into
the per-run `VirelaiOS.app`. Most of the package is deliberately
**Virtualization-free** — `VFWire` (the host-file wire codec), `VSSH`,
`VSNTP`, `VMPostmortem`, `VMDiskImage`, `VMProfile`, `VMTcp`, `VSCtl`,
`VMGPU3D` — so `swift test` pins the wire formats and state machines on a
host that never boots a VM:

```bash
swift build --package-path host/vm-runner
swift test  --package-path host/vm-runner
```

A second executable, `SoundInProbe`, is a minimal boot for the audio-input
probe, kept out of `VMRunner` so it carries no flag-loop cost. Gate builds
add `-Xswiftc -DSPIKE` where a spec asks for it (`vgate_runner_flags`).

## The justfile map

The [`justfile`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/justfile)
is the recipe surface every contributor actually uses. The gate fleet is
**discovered, not listed**: every spec in `tools/gate/specs/` plus four
legacy scripts run through `tools/gate/fleet.sh`, so adding a spec file
registers it everywhere with zero list edits.

| Recipe | What it does |
|--------|--------------|
| `just build` / `image` / `run` / `console` / `session` | thin aliases over the `zig build` steps |
| `just verify-portable` | the full **class A** set — fmt, unit tests, transcript, build+image+inspect, swift build+test, Go tests, context, coordination, inventory, linters. Mirrors CI. |
| `just verify-vz` | the **class B** fleet — boots real VZ VMs; Apple silicon only, never CI (see [[live-gates]]) |
| `just gate <id>` | run one fleet member by exact id or unique prefix (`just gate go-wm-default`) |
| `just gates <pattern>` | run every member whose id contains the substring |
| `just gate-list` | print the discovered fleet (kind + id) |
| `just go-toolchain` (+ `go-gosh`, `go-ssh`, …) | build the Go fixture ELFs the class-B specs need |
| `just check-env` | the toolchain sanity check (`tools/env-check.sh`) |
| `just test` / `test-console` / `context` / `inspect` | class-A verify pieces |
| `just verify-coordination` / `test-coordination` | the claim/Touches gate and its offline fixtures |
| `just claim` / `claim-card` | file an ad-hoc claim, or claim an existing card issue in place |
| `just new-agent` / `resume-agent` / `drop-agent` / `list-agents` | per-agent worktree lifecycle |
| `just inventory-gates` | regenerate/`--check` the gate-tooling inventory report |

<Aside kind="warning">

**LIMITATION.** There is no QEMU target, no Linux host path, and no
`make`. If a build instruction tells you to install a Linux toolchain or
run an emulator, it is describing a different project.

</Aside>
