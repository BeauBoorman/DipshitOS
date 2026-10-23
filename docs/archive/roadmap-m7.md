# Roadmap archive — Milestone seven — input: USB XHCI + HID (keyboard + pointer)

> **Archived 2026-08-21** from `docs/roadmap.md` (issue #264, claim 2860):
> the milestone is complete; this file preserves its roadmap plan/detail
> verbatim as history, not an active work order. Canonical status:
> [`docs/status.md`](../status.md).
>
> Also archived here: the cross-milestone **virtio device surface table**
> that lived under this section in `docs/roadmap.md` (it was stale by
> archive time — see `docs/hardware-contract.md` for the live contract).

---

## Milestone seven — input: USB XHCI + HID (keyboard + pointer) (**IMPLEMENTED 2026-08-13 — I1–I3 all live, milestone closed**)

> **Scope sketch (2026-08-13) — implemented below.** Milestone six's G4
> input card was split
> into its own milestone after the claim-3868 observation: VZ's only
> keyboard/pointer surface is a USB HID stack behind an **Apple XHCI USB
> host controller** (`VID=0x106b DID=0x1a06 CLS=0x0c0330`, two MMIO BARs
> `0x50001000` + `0x50000000`), not the hypothesized virtio-input device
> (DID 0x1052 — which does not exist in the framework). The three rungs,
> in order: **I1 XHCI host-controller transport** (MMIO + command/event
> rings + port status, NO HID), **I2 USB enumeration + HID** (port reset,
> address assignment, config descriptors, interrupt-IN endpoints, HID
> boot-protocol parsing), **I3 event FIFO + keycode decode** (bounded BSS
> FIFO feeding Road Pops' line editor + pointer). Per-card tracker
> [`docs/march-m7.md`](march-m7.md); the runner's flag-gated `--input`
> mode (claim 3868) already attaches the configs (OFF by default).

Card ladder (canonical order; per-card tracker
[`docs/march-m7.md`](march-m7.md)):

- **I1 — XHCI host-controller transport (NO HID yet).** ✅ **DONE
  2026-08-13 (claim 4272).**
  `kernel/src/xhci.zig`: discover the observed XHCI device, map the two
  MMIO BARs (capability/operational/doorbell/RT), parse
  HCSPARAMS/HCSPARAMS1/HCSPARAMS2, set up the command + event rings +
  the primary interrupter, drive a NO-OP command TRB to completion, and
  read port status (USBSTS/PORTSC — how many ports, which connected).
  `usb` monitor command (device/DID/BARs, HCSPARAMS, rings, ports).
  Honest bounds: no enumeration, no transfer rings, polled event-ring
  drain (the claim-6076 net lesson — the XHCI event IRQ is observed, not
  assumed); whether VZ resets the device at ExitBootServices is observed
  at claim time. **LIVE:** `verify-live-xhci.sh` PASS 1/1 (14/14) — bus 0
  dev 8, DID 0x1a06 CLS 0x0c0330, BAR0=0x50001000/BAR1=0x50000000,
  CAPLENGTH 0x20/VER 0x110/DBOFF 0x940/RTSOFF 0x520, HCSPARAMS1=0x10002010
  (16 slots/32 intrs/16 ports), NO-OP completed CC=1 (USBSTS=0x0), VZ does
  NOT reset at EBS (pre-reset USBSTS=0x9/USBCMD=0x0), ports 9+10 connected
  (CCS=1 — the two HID devices, the I2 handoff).
- **I2 — USB enumeration + HID.** ✅ **DONE 2026-08-13 (claim 4116).**
  Port reset, Enable Slot + Address Device, read device/config
  descriptors over the control endpoint (Setup/Data/Status TRBs), select
  configuration 1, arm the interrupt-IN endpoints for the keyboard +
  pointing devices, and parse the HID boot-protocol reports (8-byte
  keyboard report + absolute pointer report — observed byte-exact at
  claim time). `usb devices` + `usb report` subcommands. Honest bounds:
  boot protocol only, the two known devices, no
  hubs/mass-storage/isochronous. **LIVE:** `verify-live-usb.sh` PASS 1/1
  (11/11) — BOTH devices enumerated: the keyboard (port 9, slot 1, VID
  0x05ac PID 0x8105, boot protocol, EP1-IN maxpkt 8, boot=1) and the
  absolute pointer (port 10, slot 2, VID 0x05ac PID 0x8106, protocol 0 —
  NOT a boot mouse — EP1-IN maxpkt 10, Set_Protocol(boot) honestly
  REFUSED boot=0); a synthesized host keyDown (macOS keyCode 0) produced
  the observed 8-byte report `00 00 04 00 00 00 00 00` (mod 0, HID usage
  0x04 = 'a'), read back by `usb report`. The runner gained the minimal
  synthesized-key seam (`--input-key`/`--input-key-after`); the full
  scripted key-sequence surface stays I3.
- **I3 — event FIFO + keycode decode → Road Pops.** ✅ **DONE
  2026-08-13 (claim 6050).** `kernel/src/input.zig` (a bounded pure-BSS
  event FIFO + HID-usage → ASCII keymap + the shell-idle drain, the
  card-3d pattern) decodes the XHCI interrupt-IN reports into bytes that
  feed the Road Pops tee's read path; the `input` monitor command reports
  armed/FIFO occupancy/drop count/last keyboard + pointer events. The
  runner's `--input-string` synthesizes one NSEvent per keyDown/keyUp
  into the VZVirtualMachineView (VZ has NO keyboard API) at 2 s per
  keystroke (VZ delivers ~one report per Road Pops present cadence;
  single-TRB arming re-armed per completion is the correct shape — a
  multi-TRB depth experiment wrapped the transfer ring at the 8th
  report). **Gate:** `tools/verify-live-input.sh` PASS 1/1 — the keyboard
  typed `input\n` and the guest's own `input` report showed `events=6`
  (i,n,p,u,t,Enter) with `dropped=0` and `kb-usage=0x28 kb-byte=0xa`
  (Enter) — the typed command ran end to end. This is what makes the
  graphical terminal a real machine, and G5 (Driving Award) depends on it.

**Non-goals (for now):** no hubs, no mass storage over USB, no
isochronous endpoints, no full HID report-descriptor parser (boot
protocol only), no USB 3.0 SuperSpeed transfer scheduling (the two HID
devices are the only consumers).

**The virtio device surface — where the OS meets the host.** Every virtio
device VZ can attach maps to a host configuration class in
`host/vm-runner/Sources/VMRunner/main.swift` and, where driven, a guest
driver under `kernel/src/`. Five of the seven are done and live-gated; the
remaining two (graphics, balloon) are the open milestones.

| Device (guest-observed DID) | VZ host surface | Guest driver | Status | Claims / evidence |
|---|---|---|---|---|
| Console (0x1043) | `VZVirtioConsoleDeviceSerialPortConfiguration` (serial attachment) | `virtio_console.zig` — queue 1 TX + queue 0 RX | ✅ done | 0013 (device identity), 1517 (post-MMU TX), 6684 (live RX transcript) |
| Block (0x1042) | `VZVirtioBlockDeviceConfiguration` (disk image attachment) | `virtio_blk.zig` — modern virtio-blk, post-exit re-arm | ✅ done | 6420 (FAT32 storage driver), 3678 (general non-ESP FS on top) |
| Entropy (0x1044) | `VZVirtioEntropyDeviceConfiguration` | `virtio_entropy.zig` (boot-time 64-byte seed) + `csprng.zig` (ChaCha20, RFC 7539) | ✅ done | 2665 (driver + CSPRNG + `random`), 3693 (EL0 stack ASLR consumer) |
| Custom virtio (0x1082, macOS 27) | `VZCustomVirtioDeviceConfiguration` (`--custom-virtio` / `zig build spike-virtio`) | `virtio_custom.zig` — queue transport + used-ring IRQ | ✅ done | 5844 (host spike + `pci` command), 0828 (bidirectional queue + SPI IRQ), 4374 (ring allocator / multi-queue), 9492 (multi-descriptor payloads), 9737 (feature negotiation), 4837 (log transport) |
| Network (0x1041) | `VZVirtioNetworkDeviceConfiguration` + `VZFileHandleNetworkDeviceAttachment` (`--net <capture-file>`, `--net-inject <file>`, `--net-arp-respond <host-ip>`, `--net-icmp-respond <host-ip>`, `--net-udp-respond <host-ip>:<host-port>`, flag-gated; fixed host MAC) | `virtio_net.zig` — TX + RX + ARP + ICMP + UDP (N1 + N2 + N3 + N4 + N5); `arp.zig`; `ipv4.zig`; `udp.zig`; `syscall.zig` slots 9/10/11 (N6 — the UDP syscall seam) | ✅ TX + RX + ARP + ICMP + UDP + the UDP syscall seam (claims 1373/6076/7293/0148/8552/1384) | 1373 (transport + TX live — DID 0x1041, VER1\|MTU\|MAC, feature-path MAC, queues 0/1, 12-byte TX-hdr contract, byte-exact host capture; `verify-live-net-tx.sh` PASS 2/2); 6076 (RX live — queue-0 buffer supply, polled used-ring drain, bounded FIFO, MAC filter, `net recv`; host→guest injection + the round trip; 12-byte RX-hdr observed, min RX buffer 1530 observed; `verify-live-net-rx.sh` PASS 3/3 + 29-gate aggregate green); 7293 (ARP live — static IP, answer/resolve over the RX seam, bounded table, `--net-arp-respond`; 42-byte frames unpadded observed; `verify-live-net-arp.sh` PASS 3/3 + 31-gate aggregate green); 0148 (IPv4/ICMP live — RFC 1071 checksums, echo answer/observe over the RX seam, `net ping`, `--net-icmp-respond`; the 46-byte frames travel unpadded, consistent with the N3 observation; `verify-live-net-icmp.sh` PASS 3/3 + 32-gate aggregate green); 8552 (UDP live — RFC 768 + the pseudo-header checksum over the N4 seam, bounded listen table + datagram buffers, the LOOPBACK path, `net udp`, `--net-udp-respond`; the 46-byte datagrams travel unpadded, consistent with the N3/N4 observation; `verify-live-net-udp.sh` PASS 4/4 + 33-gate aggregate green); 1384 (UDP syscall seam live — ADR 0007 slots 9/10/11 from EL0 via UDP.BIN: listen, loopback, the peer round trip, the EINVAL error mapping, exit 17; the polled-drain recv contract; `verify-live-net-udp-syscall.sh` PASS 4/4 + 34-gate aggregate green) |
| Graphics | `VZVirtioGraphicsDeviceConfiguration` — attached only for screenshots (`--screenshot`); milestone six's `--display` mode always attaches it | `kernel/src/virtio_gpu.zig` (G1 — claim 6053); `kernel/src/text.zig` (G2 — claim 3194); `kernel/src/road_pops.zig` (G3 — claim 1574); `driving_award.zig` planned (G5) | 🚧 G1 live 2026-08-12 (claim 6053) — first non-blank framebuffer; **G2 live 2026-08-12 (claim 3194) — the machine boots to words on the screen**; **G3 live 2026-08-12 (claim 1574) — Road Pops, the boot terminal is ON the screen** (`verify-live-screen.sh` + `verify-live-text.sh` + `verify-live-roadpops.sh` PASS 1/1 each; 37-gate aggregate green; the SCK switch then enforced the composited-window evidence in the pixel gates and added the mirror-tripwire gate `verify-live-glyphs.sh` PASS 1/1 — the 38-gate aggregate re-ran 38/38 PASS); G5 next ([`docs/march-m6.md`](march-m6.md)); the G4 input card was re-scoped into **milestone seven** ([`docs/march-m7.md`](march-m7.md)) | — |
| Balloon | `VZMemoryBalloonDeviceConfiguration` — nothing attached | none | ⬜ not started — low priority (fixed 256 MiB guest, no demand paging) | — |

Each milestone must state what was **observed** versus **inferred** and must
record new hardware assumptions in `docs/hardware-contract.md`.
