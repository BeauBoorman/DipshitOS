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

- [[networking|Networking]] — raw Ethernet up through ARP, IPv4/ICMP, UDP,
  DHCP, DNS, and TCP (client + passive-open server; `GOHTTPD.ELF` serves
  HTTPS too), plus IPv6 (SLAAC/NDP, `ping6`, v6 transports), TLS 1.3 in both
  directions, and bridged/vmnet transports beside the hermetic NAT.
- [[graphics|Graphics]] — the virtio-gpu scanout, the composited seat,
  TrueType typography, and the opt-in custom-virtio Metal path for bounded
  3D and GPU compute.
- [[input|Input]] — USB XHCI, HID enumeration, keyboard layouts + dead keys,
  and pointer/click events routed to focused applications.
- [[storage|Storage & filesystem]] — the `/host` share over the
  custom-virtio channel or opt-in standard VirtioFS, a journaled VLFS volume
  on virtio-blk behind `--data-disk`, a read-only FAT32 path for USB images
  (`--usb-msd`), and a userland file syscall ABI.
- [[processes|Processes & IPC]] — concurrent EL0 programs, mailboxes, wait,
  kill, `sys_exec`/`sys_kill`, and Go threads over futex slots.
- [[desktop|The desktop]] — the `GOTABWM.ELF` seat, the WM_RPC contract,
  appkit, spaces, split panes, the chord registry, and session fidelity.
- [[apps|The app fleet]] — what ships on the image: editors, shell, browser,
  sheets, paint, IRC, games, and the signed-store installs.
- [[components|Components]] — the per-component version surfaces behind the
  fleet, rendered from the canonical registry so it cannot lag.
- [[media|Media & typography]] — bounded PDF, SVG raster, JPEG/GIF/PNG/QOI
  decode, sixel terminal graphics, and the font stack.
- [[programs|Runtimes & demos]] — the WASM interpreter, QuickJS, the
  Bubble Tea seam, Gostalgia, and the bounded native-Zig portfolio.
- **SMP & memory depth** — a 64-task pool, SMP scheduling, spinlocks and
  GICv3 IPIs; anonymous `mmap` with demand-zero faults and copy-on-write,
  with no swap.
- **Dynamic linking** — a freestanding `LD.SO` runtime linker,
  `LIBUI.SO`/`LIBFONT.SO` shared libraries, and `dlopen`/`dlsym` plugin
  loading.
- **Shared services & sound** — a machine-global clipboard, per-process app
  timers that post `TIMER` events, a virtio-snd audio pipeline from the
  device up to EL0 apps (playback *and* bounded capture), and the opt-in
  bidirectional host clipboard over HMAC-signed share files
  (`--host-clipboard`, M108b).
- **In-guest development** — the guest's own `cmd/compile`/`cmd/link` build
  and run Go programs (`live-selfhost-go`), `GOBUILD.ELF` drives them across
  the fleet (`live-dev-loop`), and `FLINT.ELF` — the agent-native SCM —
  signs and merges Streams and speaks FLINT-SYNC/1 against a host `flintd`
  (gate `go-flint`). Software installs signed through `STORE.ELF`/`GOSTORE`.
- **The machine keeps state** — `.virelaivm` profiles, guest-initiated
  suspend/resume, consent-gated snapshots, and staged self-update with
  rollback; see [[machine]].
- **Reachable surfaces** — a hardened TCP console, an in-guest SSH server,
  an opt-in RFB/VNC framebuffer, and the HMAC-challenged `AGENTD.ELF`
  control channel; see [[remote]] and [[host-int]].

## The headline capability: a real machine

Taken together, the live gates cover the system's end-to-end paths. This list
describes capabilities across those runs, not one default boot: device modes
such as display, network, and USB input are flag-gated as described in
[[run|Running the VM]].

1. Firmware hands a UEFI app a machine; the kernel takes it over.
2. `INIT.ELF` brings services up in dependency order and supervises them.
3. The Go seat `GOTABWM.ELF` composites a tabbed desktop; `GOSH.ELF`,
   `GOEDIT.ELF`, `GOFILES.ELF`, `WEB.ELF` and friends run as real EL0
   processes with windows, events, files, and sockets.
4. The machine talks Ethernet — ARP, ICMP, UDP, DHCP, DNS, TCP, TLS, IPv6 —
   and types from a real USB keyboard.
5. State survives: settings on the share, journaled writes on a VLFS disk,
   snapshots, suspend/resume, and a signed self-update with rollback.
6. Software arrives signed — cloned, verified against a pinned keyring, and
   installed with install-time consent and a rollback target.
7. An agent can drive it — through `AGENTD.ELF`'s challenged verbs or a VNC
   viewer — and every surface names what it refuses.

<Aside kind="tip">

**LIVE-GATED.** `just verify-vz` runs the discovered class-B gate fleet,
rechecking the live seams across the system on Apple silicon. See
[[live-gates]].

</Aside>

## Not there yet

- Multi-display and the balloon device; accelerated 3D exists only as the
  opt-in custom-virtio Metal device, not in the default desktop.
- TCP has no adaptive RTO estimation; the passive listener is bounded with
  named saturation refusals.
- DNS is shipped, but the resolver is bounded (A records only, no caching).
- The browser is a deliberately scoped subset — no JavaScript.

Those are honest gaps, not secrets — the [[roadmap]] page and the repository's
`docs/status.md` track them.
