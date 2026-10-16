---
title: Current capabilities
status: published
tags: [capabilities, overview]
---

# Current capabilities

What is implemented and how it is verified, subsystem by subsystem. This is a
curated overview, not the live status ledger; `docs/status.md` remains
canonical. Where a capability is partial or hardware-specific, the page says
so.

- [[networking|Networking]] — raw Ethernet up through ARP, IPv4/ICMP, UDP, DHCP, DNS, and TCP (client + passive-open server, `GOHTTPD.ELF`; Zig `HTTPD.BIN` retired in M71l), plus the TCP syscall seam.
- [[graphics|Graphics]] — the framebuffer, the Road Pops terminal, and the Driving Award window manager with a window syscall seam.
- [[input|Input]] — USB XHCI, HID enumeration, keyboard events, and pointer/click events routed to focused applications.
- [[storage|Storage & filesystem]] — the `/host` share over the custom-virtio channel or opt-in standard VirtioFS, a read-only FAT32 path for USB images (`--usb-msd`), a read/write virtio-blk driver behind the opt-in `--data-disk` with the kernel's VLFS volume mounted read-only at `/disk`, and a userland file syscall ABI.
- [[processes|Processes & IPC]] — concurrent EL0 programs, mailboxes, wait, kill, `sys_exec`/`sys_kill`.
- [[programs|User programs & demos]] — retained Zig seam proofs, current Go desktop apps, and dynamic `.ELF` executables. The programs page distinguishes historical payloads from current build outputs.
- **SMP & memory depth** — a 16-task pool, SMP scheduling, spinlocks and GICv3 IPIs; anonymous `mmap` with demand-zero faults and copy-on-write (M29), with no swap.
- **Dynamic linking** — a freestanding `LD.SO` runtime linker, `LIBUI.SO`/`LIBFONT.SO` shared libraries, and `dlopen`/`dlsym` plugin loading.
- **Shared services & sound** — a machine-global clipboard, per-process app timers that post `TIMER` events, a virtio-snd audio pipeline from the device up to EL0 melody apps, and the opt-in bidirectional host clipboard over HMAC-signed share files (`--host-clipboard`, M108b).
- **In-guest development** — the guest's own `cmd/compile`/`cmd/link` build and run Go programs (`live-selfhost-go`), and `GOBUILD.ELF` drives them across a multi-package import graph with a bounded, named-refusal dependency closure (`live-gobuild`). `FLINT.ELF`, the agent-native SCM, signs and merges Streams and speaks FLINT-SYNC/1 (`clone`/`pull`/`push`/`ls-remote`) against a host `flintd` (gate `go-flint`).

## The headline capability: a real machine

Taken together, the live gates cover the system's end-to-end paths. This list
describes capabilities across those runs, not one default boot: device modes
such as display, network, and USB input are flag-gated as described in
[[run|Running the VM]].

1. Firmware hands a UEFI app a machine; the kernel takes it over.
2. A serial `virelai>` shell answers commands with deterministic replies.
3. The screen shows a working graphical terminal (**Road Pops**) composited by
   a window manager (**Driving Award**).
4. User programs run at EL0 as processes, with syscalls, IPC, and exit statuses.
5. The machine talks Ethernet — ARP, ICMP, UDP, DHCP, DNS, TCP — and types
   from a real USB keyboard.
6. A desktop launcher starts real applications — calculator, editor, process
   monitor, file browser — that paint windows, receive events, and talk to
   the network.
7. Text moves between apps through a shared clipboard, apps wake on timers
   instead of spinning, and the machine makes sound: a boot chime, a `beep`,
   and EL0 melody apps over a virtio-snd device.

<Aside kind="tip">

**LIVE-GATED.** `just verify-vz` runs the discovered class-B gate fleet,
rechecking the live seams across the system on Apple silicon. See
[[live-gates]].

</Aside>

## Not there yet

- Multi-display and the balloon device; accelerated 3D exists only as the
  opt-in M102 custom-virtio Metal device, not in the default desktop.
- Routing beyond the NAT gateway, any IPv6 stack, and TCP beyond the
  singleton client + bounded passive listener (two simultaneous children).
- DNS is shipped, but the resolver is bounded (A records only, no caching).

Those are honest gaps, not secrets — the [[roadmap]] page and the repository's
`docs/status.md` track them.
