---
title: Live VZ gates
parent: evidence
status: published
tags: [evidence, class-b, vz]
---

# Live VZ gates (class B)

Class B gates boot a real Virtualization.framework VM on Apple silicon and
assert on what the kernel actually reports. CI cannot run them; a developer
host can (`just verify-vz`).

## Why they exist

The class A floor proves the code paths. The class B gates prove the machine:
that the MMU switch completes under real firmware, that the virtio device
answers, that a typed key reaches the terminal, that a written file survives a
reboot, that a captured Ethernet frame is byte-exact.

## The shape of a gate

Each gate is a declarative spec under `tools/gate/specs/`, run with
`just gate <id>` (the fleet is discovered by `tools/gate/fleet.sh`), and it:

1. boots the VM with the right flag-gated device mode;
2. drives a deterministic scripted session (marker-triggered, not sleep-based);
3. asserts on the guest's own serial reports — and, for pixel and network
   gates, decodes the captured PNG or frame bytes;
4. exits 0 only on full evidence.

## A sample of the set

- **Serial / machine** — `live-transcript`, `live-reboot`, `live-timer`, `live-tasks`, `live-exceptions`
- **Userspace** — `live-userspace`, `live-svc`, `live-uaccess`, `live-addrspaces`, `live-lifecycle`, `live-exec`, `live-sleep`
- **Processes** — `live-procs`, `live-concurrent`, `live-long-lived`, `live-kill`, `live-ipc`, `live-scale`, `live-wait`, `live-procs-syscall`
- **Storage / entropy / files** — `live-fs`, `live-gfs`, `live-entropy`, `live-user-fs` (the userland file ABI), `live-vlfs-blk` (the virtio-blk data disk: attach, GET_ID naming, sector write + negotiated FLUSH + readback + restore), `live-vlfs-write` (the M100d journaled write path: commit ordering, the fsync barrier, byte-exact remount persistence, and the named `txn_too_large`/`no_space` refusals)
- **Network** — `live-net-tx`, `-rx`, `-arp`, `-icmp`, `-udp`, `-udp-syscall`, `-nat`, `-dhcp`, `-dhcp-renew`, `-tcp`, `-tcp-rto`, `-tcp-syscall`, `-dns`, `-fetch`
- **Graphics / input** — `live-screen`, `live-text`, `live-roadpops`, `live-glyphs`, `live-win`, `live-win-syscall`, `live-win-move`, `live-win-close`, `live-win-hig`, `live-xhci`, `live-usb`, `live-input`
- **Usability / HIG** — `live-help`, `live-editing`, `live-settings`, plus the pointer seams: `pointer-manual` (class C, a human at the mouse), `live-pointer-cg` (class B, self-gating on Accessibility trust), and `live-pointer-virtio` (class B-headless — custom-virtio pointer injection, issue #151)
- **Events / desktop / apps** — `live-events`, `live-sys-kill`, `live-desktop`, `go-fileman`
- **Shared services** — `live-clipboard`, `live-timers`, `live-m14-composition`, `live-hardening`, `live-host-clipboard` (the bidirectional host lane over signed share files, plus the flags-off byte-silent posture), `live-host-drop` (host→guest file drop into `/host/INBOX`: temp+rename landing, collision suffixes, the four named refusals, flags-off byte-silent), `live-host-notify` (seat toasts cross the glass as signed NOTIFY_OUT records the runner drains; `no_credential` arms fail closed and `no_bundle` is the honest bare-runner answer)
- **Go userland / dev loop** — `live-selfhost-go` (the guest's own `cmd/compile`+`cmd/link` build and run a program), `live-gobuild` (`GOBUILD.ELF` builds a six-package program in-guest and the product runs, plus the named-refusal legs), `go-flint` (FLINT SCM ops, merge, sign/verify, and the FLINT-SYNC/1 remote verbs against a host `flintd`), `live-flint-loop` (the M107d versioned loop: init → edit → add → diff → commit → push round-trip, host-side `flint verify --all` + byte-compare), `live-godiff-loop` (the M107e capstone: `GODIFF.ELF` authored through real GOEDIT sessions, compiled by the guest's own toolchain, and pushed to `flintd` — every source byte entered in-guest), `go-godiff` (the fleet-behavior gate for the diff tool itself)
- **Sound** — `live-sound-device`, `live-sound-playback`, `live-sound-app`, `live-sound-control`, `live-m15-composition`
- **Window depth / desktop (M21–M27)** — the `live-m21-*` set (tile-master, minimize-ws, max-fullscreen-aot, notif-dialog-transient, persist-title-orphan), `live-httpd` (TCP passive open), and the file-manager sweeps (`live-filemanager-du`, `live-ls-l`, `go-fileman`)
- **Hardware depth (M28–M31)** — `live-smp` (2 cores), `live-vm-depth` (mmap / fault frames / rlimit), `live-dynamic-linking` and `live-dynamic-ecosystem` (LD.SO, .ELF apps)
- **Custom-virtio control plane** — `live-pointer-virtio` and `live-virtio-e2e` (input + structured console + raw scanout in one headless boot)

The aggregate `verify-vz` sweep re-checks the shared seam across every
subsystem in one run — the standing regression proof that a new subsystem did
not break the ones before it. The count is not written here on purpose: run
`bash tools/gate/fleet.sh count` for the current number (the fleet is
discovered from `tools/gate/specs/`, plus four legacy class-B scripts, so a
hard-coded number here would rot on the next spec).

<Aside kind="tip">

**LIVE-GATED.** The strongest single artifact is the byte-exact network
capture: `live-net-udp` and `live-net-tcp` walk the captured frames with a
Python script that verifies every checksum and the sequence/acknowledgment
chain.

</Aside>

<Aside kind="warning">

**LIMITATION.** These gates are hardware-specific and host-specific. A flake is
recorded and re-run rather than hidden — the claim docs name flakes when they
happen.

</Aside>
