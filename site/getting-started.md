---
title: Getting started
status: published
tags: [guides]
---

# Getting started

VirelaiOS is a from-scratch AArch64 operating system: a freestanding Zig
guest that boots under real UEFI firmware inside Apple's
Virtualization.framework, launched by a Swift host app. There is no Linux,
no POSIX, no libc, and no emulator anywhere in the boot path — and there is
no QEMU or Linux-host escape hatch, by design. Everything on this page
assumes you are sitting at an **Apple silicon Mac running macOS 27 or
newer**; the launcher enforces that floor at runtime and refuses to start
anywhere else.

## What you need

The toolchain is deliberately pinned, and the repo checks it for you:

- **Apple silicon + macOS 27 or newer.** The VM is hosted by
  Virtualization.framework; Intel Macs, Linux, and Windows are out of scope.
- **Zig 0.17.0**, pinned in
  [`.zigversion`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/.zigversion).
  You do not need to install it by hand: `tools/zig/lock.json` carries the
  pinned archive URLs and sha256s, and `tools/zig/sdk.py` materializes the
  SDK into `.build/zig-guest` (offline by default; only `sdk.py fetch`
  touches the network). A shadowing `zig` elsewhere on PATH — for example an
  unpinned Homebrew build — has genuinely broken gates before, so let the
  pin win.
- **`just`**, the command runner the whole workflow is aliased through.
- **Swift + the Xcode command-line tools**, for `host/vm-runner`, the
  Virtualization.framework launcher.
- **Python 3** (stdlib only) for the disk-image builder and host test suites.
- **Modern Homebrew tools**: `bash`, `gnu-sed`, `jq`, `yq`. This matters
  more than it sounds — macOS still ships 2007-era bash 3.2 and BSD sed,
  and the gate scripts misbehave quietly under them.

The first thing to run in any fresh checkout or session is the environment
check:

```bash
source tools/env-check.sh        # or: just check-env
```

It re-prepends the Homebrew bin dir to `PATH` (plus the keg-only GNU sed
dir), verifies that `bash`/`sed`/`jq`/`yq` resolve to the modern builds,
checks the Go toolchain fork for stale overlay state, and prints a very
loud red complaint — returning non-zero — when the system tools win. If it
complains: `brew install bash gnu-sed jq yq`, fix `PATH` as it instructs,
and re-source. It is safe and idempotent.

## The supported first boot

From a clean clone, the front door is one command:

```bash
git clone https://github.com/drawmeanelephant/VirelaiOS.git
cd VirelaiOS
source tools/env-check.sh
just session
```

`just session` builds the guest, the disk image, and the runner; seeds a
persistent host share at `artifacts/session-share`; and launches a per-run,
ad-hoc-signed `VirelaiOS.app`. It is not an installer and nothing is
installed — close the window, choose **Quit VirelaiOS** (Cmd-Q), or Ctrl-C
the launching terminal and the VM stops and its temporary state is cleaned
up. Rerun the same command to relaunch: guest RAM does not survive, but
documents and settings on the share do. Guest serial output lands in
`artifacts/session-serial.log`.

The Go userland needs the `GOOS=virelai` toolchain fork, provisioned once
with `bash tools/go/apply.sh` (a patched copy of the stock Go distribution
in a sibling directory) — the session script builds the seat and its staged
apps through it. Without it, a fresh share falls back to the Zig seat
instead of failing.

## What you will see

A 1280×720 window opens; the title bar reads **Starting VM** and then
**VirelaiOS** once the machine is up. Click the window if macOS leaves
another app active. Inside the guest, the boot default is the **Go seat**,
`GOTABWM.ELF`: a tabbed desktop with a left rail of apps, window chrome,
and — on a first boot with no saved session — a shell workspace running
`GOSH.ELF`, the Go shell. The first-boot tour, `GOWELCOME.ELF`, walks the
seat's tabs, chords, and apps; pressing `?` in the seat shows the
keyboard-hints overlay. The classic Zig seat stays reachable as a persisted
fallback (`settings set wm tabwm`), but the Go seat is what a default boot
seats you in.

<Aside kind="info">

**LIVE-GATED.** The default-boot contract — Go seat up, shell workspace
seated, Zig fallback still bootable — is pinned on real hardware by the
class-B spec `go-wm-default` (`just gate go-wm-default`).

</Aside>

## The serial path

If you want the kernel itself rather than the desktop, the lower-level
route is:

```bash
zig build            # compile the AArch64 UEFI loader + freestanding kernel
zig build image      # build the GPT+FAT32 boot image -> artifacts/disk.img
zig build run        # boot it; serial output -> artifacts/vm-serial.log
zig build console    # boot an interactive virelai> console instead
```

A successful boot ends with the kernel's monitor banner and a `virelai>`
prompt — an operating system that has exited UEFI Boot Services and is
driving the hardware itself. [[run|Running the VM]] covers the monitor and
the flag-gated device modes.

## Where to go next

- [[run|Running the VM]] — the `virelai>` monitor, serial takeover, and the
  runner's device flags.
- [[desktop|The desktop]] — the Go seat, tabs, and window management.
- [[apps|The app fleet]] — what ships on the share and how apps are
  installed.
- [[build|Building]] — every build target, the Go toolchain fork, and the
  justfile recipe map.
- [[devloop|The dev loop]] — the guest builds, tests, and commits itself.

<Aside kind="warning">

**LIMITATION.** This is a research/hobby operating system on exactly one
vendor's VM stack: Apple silicon, macOS 27+, Virtualization.framework. It
is not a daily driver, not portable, and not trying to be either — the
interesting part is that the whole thing, firmware handoff to window
manager, is built from scratch and gated on real hardware.

</Aside>
