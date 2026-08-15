# DipshitOS hardware contract

This file records every hardware and firmware assumption the project makes.
Anything listed here is a commitment: code in later milestones must either
honor it or update this file first. Entries are tagged **[observed]** when we
have log/command evidence on a real machine and **[inferred]** when the
assumption comes from documentation or reasoning only.

## Instruction set

- **AArch64 (ARMv8 / ARMv9-A)**. All guest code compiles for
  `aarch64-uefi`. **[observed]** — the EFI binary is AArch64 PE/COFF (see
  `zig build inspect` output).

## Firmware interface

- **UEFI 2.x**. The guest uses only the EFI System Table: the
  `SimpleTextOutput` protocol (`ConOut`) and, implicitly, the standard
  "return from entry point" exit convention.
- The standard removable-media ARM64 boot path is used:
  `\EFI\BOOT\BOOTAA64.EFI` on a FAT volume.
- **[inferred]** Firmware scans removable media for `BOOTAA64.EFI` when no
  explicit boot entry exists (both edk2 and Apple Virtualization implement
  this part of the UEFI spec).

## Hosts and their devices

### Apple Virtualization.framework (macOS, Apple silicon)

- UEFI firmware: Apple's Virtualization EFI. Vendor and revision are
  unknown/undocumented by Apple. **[inferred]**
- Disk: virtio block device (`VZVirtioBlockDeviceConfiguration`), attached
  read-write so the guest can write its evidence file. **Discovered by
  claim 6420**: the guest sees the disk on bus 0 as `VID=0x1af4
  DID=0x1042 class=0x018000` — **the spec's modern virtio-blk DID** (the
  transitional PCI scheme maps Virtio Device IDs to DIDs as `ID + 0x1040`:
  net 0x1041, blk 0x1042, console 0x1043, entropy 0x1044 — so VZ's
  standard devices all match the standard table; only the custom device's
  0x1082 is vendor-assigned, claim 5844). The device also **resets at
  ExitBootServices**: its status register reads 0 post-exit and the queue
  is dead, so the driver re-arms
  the queue post-MMU (common-config MMIO writes to the BAR window work
  post-exit; PCI config-space reads must stay pre-exit, claim 0013).
  **Disk layout (claim 3678, milestone four card 2):** the image
  (`image/mkfat32.py`) is 128 MiB with TWO FAT32 partitions — the ESP
  (type GUID `C12A7328-…`, LBA 2048, 186335 sectors) and a 36 MiB DATA
  partition (Linux-FS type GUID `0FC63DAF-…`, LBA 188383, 73728 sectors)
  — both discovered by scanning the GPT entries for the type GUID
  (`fat.mount` / `fat.mount_data`); nothing outside the GPT constrains a
  volume's offset.
- Console: virtio console serial port
  (`VZVirtioConsoleDeviceSerialPortConfiguration`). **Observed**: on
  macOS 27 / Apple silicon, Apple's EFI firmware does NOT route UEFI
  `ConOut` to this port; the captured log stays empty.
- Framebuffer: virtio-gpu with a 1280x720 scanout shown in a
  `VZVirtualMachineView`. **Observed**: the firmware renders nothing to it;
  captured PNGs are blank/gray. UEFI text is therefore NOT visible on the
  VZ framebuffer either. **G1 driven + first pixels 2026-08-12 (claim
  6053, milestone six card 1) — the driver's assumptions are now
  [observed] with saved VZ logs (`artifacts/m6-gpu-*`, `live-screen-*`):**
  the device is the modern virtio-pci gpu **`VID=0x1af4 DID=0x1050`
  (class 0x038000, bus 0 dev 7)** — the spec DID confirmed, found via
  the ECAM walk like every virtio device before it; its virtio-pci
  capability layout is claim-0013's decoded shape (common cfg @ BAR0+
  `0x0000`, ISR @ `+0x1000`, notify @ `+0x4000` multiplier 4, device cfg
  @ `+0x8000`); it **offers** `RING_PACKED|RING_EVENT_IDX|
  RING_INDIRECT_DESC|VERSION_1` (`devfeat=0x30000000/0x5` — the same
  word as the console) and accepts **VIRTIO_F_VERSION_1 alone**
  (`feat=0x0/0x1`; split rings, classic 16-bit notify with the queue
  index as the value); the framebuffer exposure is the **spec 2D command
  path** (GET_DISPLAY_INFO → RESOURCE_CREATE_2D →
  RESOURCE_ATTACH_BACKING → SET_SCANOUT → TRANSFER_TO_HOST_2D →
  RESOURCE_FLUSH — no resource mapping / BAR window needed); the scanout
  resource is **B8G8R8X8_UNORM (format 2)** with an OPAQUE alpha byte
  (an X/A of 0 renders fully transparent — the final black-screen bug);
  the device is **virtio-gpu 1.2** (the 24-byte `display_one` — the
  pre-1.2 20-byte shape made GET_DISPLAY_INFO's response 344 vs the 408
  the device writes and wedged the queue with DEVICE_NEEDS_RESET 0x40);
  the tail descriptor's `next` must be 0 (VZ walks it without the NEXT
  flag — 0xffff wedged the queue); and **VZ RESETS the gpu device at
  ExitBootServices — `gpu: pre-rearm st=00` observed** (like
  blk/entropy's `st=00`, unlike net's `st=0f`; the post-exit re-arm is
  required). Both queues are armed (controlq 0 + cursorq 1, size 4 — the
  Linux driver configures both). The input devices for G4 were **[observed]
  2026-08-13 (claim 3868)**: they are NOT virtio-input. VZ's
  `VZUSBKeyboardConfiguration` + `VZUSBScreenCoordinatePointingDeviceConfiguration`
  present as an **Apple XHCI USB host controller**
  (`VID=0x106b DID=0x1a06 CLS=0x0c0330`, two MMIO BARs `0x50001000` +
  `0x50000000`) with the keyboard/pointer as USB HID devices behind it — no
  0x1052 device exists on the bus. Screen-side input therefore needs a USB
  XHCI + HID stack, not a virtio-input transport (evidence under
  `artifacts/g4-discovery/`). **G5 (claim 1543, 2026-08-13):** the
  guest-side compositor (Driving Award) blits two windows into the ONE
  scanout resource — the terminal (window 0) and a clock overlay (window
  1) — so the host's color-managed pipeline carries the clock's amber
  title bar (0xb58900 → ~(174,139,45)) and navy body (0x0a1a2e →
  ~(14,26,44)) through the SAME transform as the G1 fill green; the
  decoded capture proves the overlay sits on top (no terminal foreground
  inside the clock rect). **G6 (claim 0487, 2026-08-13):** a THIRD window
  — a kernel-owned user window (256×192) rendered entirely from EL0 via
  the draw/window syscall seam — carries its own colors (dark-blue
  0x1a2b3c → ~(30,43,59), red 0xff0000 → ~(234,51,35), cyan 0x00ffff →
  ~(117,251,253), white 0xffffff → ~(255,255,255)) through the SAME
  color-managed pipeline, blitted over the terminal (no terminal
  foreground shows through its rect).
- USB/XHCI: Apple XHCI USB host controller (the device VZ's `--input`
  attaches — `VZUSBKeyboardConfiguration` +
  `VZUSBScreenCoordinatePointingDeviceConfiguration`, milestone seven).
  **Transport driven 2026-08-13 (claim 4272, milestone seven card I1):**
  the guest discovers it pre-exit on bus 0 **dev 8** as `VID=0x106b
  DID=0x1a06 CLS=0x0c0330` with two MMIO BARs — **BAR0 `0x50001000` holds
  the capability registers, BAR1 is `0x50000000`** (both below the 4 GiB
  identity-map blanket). The register map: CAPLENGTH=0x20, HCIVERSION=0x110,
  DBOFF=0x940, RTSOFF=0x520, HCSPARAMS1=0x10002010 (MaxSlots=16,
  MaxIntrs=32, MaxPorts=16). **The interrupter register set i lives at
  RTSOFF+0x20+(0x20×i)** — the MFINDEX register occupies RTSOFF+0x00, and
  writing ERSTSZ into that reserved region wedges the emulation (the I1
  fix, recorded for I2). **VZ does NOT reset/run the controller at
  ExitBootServices** — pre-reset USBSTS=0x9 (HCHalted + Port Change Detect)
  and USBCMD=0x0 read post-EBS before HCRST (the XHCI answer to the
  gpu/blk/entropy `st=00` vs net `st=0f` question). After HCRST + RS the
  controller runs (USBSTS=0x0) and a NO-OP command completes with CC=1
  (Success) — the command/event-ring transport proven end to end.
  **Ports 9 and 10 report CCS=1 (connected)** — exactly the two attached
  HID devices (keyboard + pointer); ports 1-8 and 11-16 report CCS=0.
  All **[observed]** — every `verify-live-xhci` boot's `usb` report and
  the saved discovery logs under `artifacts/xhci-discovery-*`.
- USB HID devices (behind the XHCI controller): **enumerated 2026-08-13
  (claim 4116, milestone seven card I2).** Port reset → Enable Slot →
  Address Device → device + config descriptors over the control endpoint →
  Set Configuration 1 → interrupt-IN endpoint armed. Both devices are FULL
  speed (PORTSC PS=1):
  - **Keyboard — port 9, slot 1:** VID `0x05ac` (Apple) PID `0x8105`,
    `bDeviceClass` 0 (class lives in the interface descriptor), HID
    boot-protocol KEYBOARD (`bInterfaceProtocol` 1), interrupt-IN EP1
    `maxpkt=8`, `bInterval=8`, `Set_Protocol(boot)` ACCEPTED (`boot=1`).
  - **Pointing device — port 10, slot 2:** VID `0x05ac` PID `0x8106`,
    `bInterfaceProtocol` 0 (NOT a boot-protocol mouse — the absolute
    screen-coordinate pointer), interrupt-IN EP1 `maxpkt=10`,
    `bInterval=8`, `Set_Protocol(boot)` **REFUSED** (`boot=0` — recorded
    honestly; the raw report is the ground truth).
  - **Report shape (observed byte-exact):** a synthesized host keyDown
    (macOS keyCode 0 = 'a') produces the 8-byte keyboard boot report
    `00 00 04 00 00 00 00 00` — modifier byte 0, HID usage `0x04` in byte
    2. **VZ has NO programmatic keyboard API** — `VZUSBKeyboardConfiguration`
    is driven only by a `VZVirtualMachineView` forwarding host key events,
    so the runner dispatches one synthesized `NSEvent` keyDown into the
    view (its `--input-key <mac-keycode>` + `--input-key-after <marker>`
    seam, OFF without `--input`).
  - **Report delivery cadence (observed 2026-08-13, claim 6050, card I3):**
    VZ's keyboard delivers roughly ONE interrupt-IN report per Road Pops
    present cadence — a full-frame virtio-gpu present per output batch is
    the slow step, and typing faster than ~2 s per keyDown/keyUp drops
    reports (the endpoint holds a single pending report). **Single-TRB
    arming is the correct shape** (arm one report TRB, re-arm on every
    completion); a multi-TRB depth experiment wrapped the transfer ring at
    the 8th report and dropped everything after. The input drain must run
    BEFORE the Road Pops present in the shell idle loop so a report is
    never starved behind a slow full-frame present. The runner's scripted
    surface (`--input-string <text>` + `--input-string-after <marker>`)
    therefore types at 2 s per keystroke. **[observed]** —
    `tools/verify-live-input.sh` (PASS 8/8): the keyboard typed `input\n`
    and the guest's own `input` report showed `events=6` (i,n,p,u,t,Enter)
    with `dropped=0`, `kb-usage=0x28 kb-byte=0xa` (Enter); evidence under
    `artifacts/live-input-*`.
  - **Editing-key synthesis (observed 2026-08-14, claim 6233, card U2):**
    the runner's `--input-string` gains editing-key tokens
    (`<up>/<down>/<left>/<right>/<home>/<end>/<delete>/<enter>/<tab>`) and
    `^a`..`^z` Ctrl chords; the seam's honest bounds, each observed in the
    guest's own per-report debug stream (`kb: rep` lines, printed under
    `--input`):
    - **The editing usages ARE delivered when the NSEvents carry AUTHENTIC
      Cocoa characters** — the function-key unicodes (U+F700-Up … U+F72B,
      Delete U+F728), `"\t"` for Tab, `"\r"` for Return. Observed usages:
      Up=0x52, Left=0x50, Home=0x4a, Delete=0x4c, Tab=0x2b, Enter=0x28.
      Made-up ASCII `characters` strings ("left", "tab") make VZ's event
      translation misbehave — phantom keystrokes and lost keys.
    - **Synthesized Ctrl modifiers do NOT reach the HID report.** Three
      routes observed failing: `modifierFlags` on a synthesized keyDown
      (arrives as the plain letter), `NSEvent.otherEvent`/`NSEvent(cgEvent:)`
      for `.flagsChanged` (AppKit rejects the type —
      NSInternalInconsistencyException), and a `keyEvent`-factory
      flagsChanged pair (accepted by AppKit, ignored by VZ's report
      composition). The chords are therefore gate-proven over the SERIAL
      byte path (raw 0x01..0x1a — byte-identical to the HID decode's
      output); a real keyboard's flagsChanged events are unaffected.
    - **VZ re-delivers the session's FIRST usage once as a phantom
      keystroke mid-session** (5/5 observed runs: first key 'a' ⇒ a stray
      'a' ~30-60 s in; 'e' ⇒ 'e'). The gate's session starts with a
      sacrificial `<left>` (on an empty line: a refused bell) so the
      phantom is harmless; recall (wholesale line replace) wipes any
      phantom that lands in a draft.
    - **Reports still coalesce at the present cadence** (the I3 bound): a
      busy output window can drop a report between drains — the gate
      types after `tasks user-el0 reaped` (the quiet machine) at 3 s per
      keystroke (`--input-string-interval`), and its assertions target
      atomic guest-emitted output lines, never multi-keystroke typed
      echoes.
    **[observed]** — `tools/verify-live-lineedit.sh` (PASS 13/13) and the
    report streams under `artifacts/u2-probe*`; the I3 gate re-ran green
    after the input.zig changes (`verify-live-input.sh` PASS).
  - **Synthesized POINTER events do not reach the pointing device
    (observed 2026-08-14, claim 4993, card U4):** FIVE delivery routes
    were dispatched with the runner's own PTR-EVT evidence and every one
    produced `ptr-reports=0` in the guest's `input` report — (1) direct
    `view.mouseMoved/mouseDown(with:)`, (2) `window.sendEvent(e)`, (3)
    `NSApp.postEvent` into the application queue, (4) `CGEventPost` at
    the HID tap (silently dropped without Accessibility trust for the
    posting process), and (5) a leading synthesized `mouseEntered`
    (enterExitEvent) preamble. This is unlike the KEYBOARD, where
    synthesized `view.keyDown(with:)` translates to HID reports
    immediately (the I2/I3 seam). Open follow-ups: whether a REAL mouse
    over the `--display` window produces reports (untested knowingly),
    and whether the CG route works once the terminal holds Accessibility
    trust. The runner keeps the seam (`--pointer`, `--pointer-after`,
    `--pointer-route window|app|cg`) for that follow-up.
    **[observed]** — the probe runs under `artifacts/u45-probe*`; the
    guest-side consumption (click = focus + raise, cursor render,
    Alt+Tab decode) is host-tested in `driving_award.zig`/`input.zig`.
  All **[observed]** — `tools/verify-live-usb.sh` (PASS 11/11) and the saved
  logs under `artifacts/usb-discovery-*` + `artifacts/live-usb-*`.
- Entropy: virtio entropy device (`VZVirtioEntropyDeviceConfiguration`).
  **Driven + seeded 2026-08-10 (claim 2665, milestone four card 1):** the
  guest sees it on bus 0 as `VID=0x1af4 DID=0x1044` (virtio device ID 4;
  `pci` lists it beside the console 0x1043 / block 0x1042 devices), and a
  driver now reads REAL random bytes from it: `kernel/src/virtio_entropy.zig`
  discovers the modern virtio-pci transport pre-exit (BAR + common/notify
  caps, VIRTIO_F_VERSION_1, queue 0, DRIVER_OK) and re-arms it post-MMU
  before the first read. **The claim-6420 lesson is confirmed for entropy
  too: VZ resets the device at ExitBootServices — its device_status reads
  0 post-exit (`entropy: pre-rearm st=00` observed in `vm-serial.log`)
  and the re-arm restores DRIVER_OK before the 64-byte boot seed is
  read (`entropy: seeded n=64`).** **[observed]** — every live-entropy
  gate boot's serial log (`artifacts/live-entropy-*`) shows the pre-rearm
  status, the seed line, `random: n=32 hex=` (64 hex chars), and an exec
  reply with a CSPRNG-randomized `stack=0x…`; two boots produce different
  `random` sequences and different stack placements, proving the device
  delivers genuine non-deterministic entropy to the CSPRNG (the seed path
  is `[observed]`; the driver's transport behavior follows the same
  claim-6420/0013 rules as the block/console devices).
- Network: virtio net device (`VZVirtioNetworkDeviceConfiguration` under
  the runner's flag-gated `--net <capture-file>` mode; `config.networkDevices
  = []` without the flag — the default VM is untouched). **Driven +
  TX-proven 2026-08-11 (claim 1373, milestone five card N1):** the guest
  sees it on bus 0 at device 1 as `VID=0x1af4 DID=0x1041 class=0x020000`
  (network controller — **the spec's modern virtio-net DID, confirming the
  2026-08-11 DID correction**), with a 64-bit BAR0 at `0x100020000` and a
  32-bit BAR2 at `0x50003000`. The driver (`kernel/src/virtio_net.zig`)
  negotiates features with a candidate ladder because the device REJECTS
  VER1-only and VER1|MAC masks (status readback 0x03 — FEATURES_OK
  cleared) and **requires `VIRTIO_NET_F_MTU` to be accepted**: the landed
  mask is `feat=0x28/0x1` (VER1|MTU|MAC, observed in every live-net-tx
  serial log). **The host-set MAC is exposed via the feature path:** the
  runner fixes `macAddress` 02:00:00:00:00:01 on the host config and the
  guest reads exactly that from device-config offset 0 with the
  `VIRTIO_NET_F_MAC` feature negotiated (`net: mac=02:00:00:00:00:01
  source=feature`, matching the raw `net: cfgmac=02:00:00:00:00:01`
  bytes). Queues 0 (RX) + 1 (TX) arm at size 4 (split rings), DRIVER_OK
  holds through the post-exit re-arm, and — **differing from blk/entropy —
  the net device does NOT reset at ExitBootServices**: `net: pre-rearm
  st=0f` (status 0xf = DRIVER_OK intact) observed on every net-tx boot
  (the blk/entropy devices read `st=00` post-exit). **TX consumes a
  12-byte virtio_net_hdr on EVERY buffer, even with no offload feature
  negotiated:** the first live gate stripped exactly 12 bytes (our
  dst+src MACs became the "header", ethertype+payload arrived), so the
  driver prepends a ZEROED virtio_net_hdr and the host capture carries the
  RAW Ethernet frame byte-exactly. **[observed]** — every `verify-live-net-tx`
  boot's serial log (`artifacts/live-net-tx-serial-*.log`) shows the
  did/class/mac/feat/queues/status lines above, and the runner's capture
  files (`artifacts/live-net-tx-cap-*.bin`) hold the exact frames the
  guest submitted. **RX proven 2026-08-11 (claim 6076, milestone five
  card N2):** queue 0 is supplied with ONE fixed BSS buffer (post-re-arm,
  `net: rx-armed`) and the host injects a datagram into the SAME
  attachment's socket end via the runner's `--net-inject <file>` flag (a
  serial trigger — the guest's rx-armed marker — not a sleep), VZ
  delivers it into the buffer, the guest drains the used ring POLLED (the
  N1/blk shape; **the net device's used-buffer IRQ line is NOT yet
  observed on this platform — recorded in claim 6076, not assumed**), and
  `net recv` prints the frame. **The device WRITES a 12-byte
  virtio_net_hdr into RX buffers** (the claim-time RX-header question —
  answered by observation): the first received frame's device-written
  length was 72 for a 60-byte frame and the first 16 bytes were
  `00 00 00 00 00 00 00 00 00 00 01 00 ff ff ff ff` — flags/gso fields
  zero (no offloads) and `num_buffers=1` at bytes 10-11, so `rx_hdr_len
  = 12` (the same 12 the device consumes on TX). **The device REFUSES an
  RX buffer smaller than 1530 bytes:** with `rx_buf_len=1526/1528/1529`
  the delivery attempt wedged the whole device (no frame written, used
  ring never advanced, and subsequent TX completions stalled until the
  buffer was enlarged; 1530 works) — the production buffer is 4096
  (page-rounded headroom). The MAC filter accepts own + broadcast and
  drops the rest with a counter (`net: rx=… filtered=N`), and a dropped
  frame still leaves the rx-obs record (a drop is distinguishable from a
  failed delivery). **[observed]** — every `verify-live-net-rx` boot's
  serial log (`artifacts/live-net-rx-serial-*.log`) shows `net: rx-armed`
  + `net: rx-obs len=…` + the rx counters, and the phase-1 capture
  (`artifacts/live-net-rx-cap-1.bin`) is byte-exactly the injected
  fixture (the guest re-sent it). **ARP frames are delivered and
  transmitted UNPADDED:** a 42-byte ARP frame (below the Ethernet
  60-byte minimum) arrives as exactly 42 bytes (device-written length 54
  = 12-byte header + 42) and the guest's 42-byte reply is captured
  byte-exact — the file-handle attachment does not pad either direction.
  **[observed]** — every `verify-live-net-arp` boot's serial log
  (`artifacts/live-net-arp-serial-*.log`) shows the byte-exact `net recv`
  hex of the injected 42-byte request (device len 54) and the captures
  (`artifacts/live-net-arp-cap-*.bin`) hold the exact 42-byte frames
  (the phase-1 reply byte-identical to the fixture; the phase-2 request
  byte-identical). **The same holds for the 46-byte IPv4/ICMP frames
  (claim 0148):** the injected 46-byte echo request arrives as exactly 46
  bytes (device-written length 58 = 12-byte header + 46) and the guest's
  46-byte reply is captured byte-exact — the file-handle attachment does
  not pad sub-60-byte frames on either direction. **[observed]** — every
  `verify-live-net-icmp` boot's serial log
  (`artifacts/live-net-icmp-serial-*.log`) shows the byte-exact `net recv`
  hex of the injected 46-byte request (device len 58) and the captures
  (`artifacts/live-net-icmp-cap-*.bin`) hold the exact 46-byte frames
  (the phase-1 reply and the phase-2 request both byte-identical to the
  fixtures). No new device behavior was otherwise observed on the
  ARP/ICMP exchanges — the N1/N2 contract above is unchanged.
  **NAT attachment observed 2026-08-12 (claim 4678, milestone five card
  N7):** the runner's `--net-nat` flag attaches the SAME
  `VZVirtioNetworkDeviceConfiguration` shape with a
  `VZNATNetworkDeviceAttachment` instead of the file-handle attachment.
  (1) **The NAT attachment HONORS the configured locally-administered
  MAC** — the guest's `VIRTIO_NET_F_MAC` read reports
  `net: mac=02:00:00:00:00:01 source=feature` (identical to the
  file-handle path). (2) **VZ exposes no NAT prefix API** — the subnet
  was observed on the first live run: 192.168.64.0/24 with gateway
  192.168.64.1 (the guest was statically addressed 192.168.64.5).
  (3) **The NAT gateway answers ARP for its gateway IP** (the guest
  learns the gateway MAC — `net arp: 192.168.64.1 is at …`, `learn=1`)
  **and answers ICMP echo** (`net ping 192.168.64.1` → `pong=1` with
  `seq=1`) — the deterministic gateway round trip needs NO internet.
  (4) **The NAT router's MAC is NOT the host bridge interface MAC and
  VARIES per boot** (observed `ae:07:75:20:da:64` vs the host bridge0
  interface's `36:27:ce:a2:21:40`) — gates must assert the learned-line
  prefix, never a hardcoded MAC. (5) **The NAT router SENDS IPv6
  multicast to the guest at boot** (router-advertisement-shaped frames:
  the guest's first rx-obs shows dst `33:33:00:00…`); the N2 MAC filter
  (own + broadcast only) drops them (`filtered=3`) and the ARP-layer
  drop counter moves once (`drop=1`) — recorded, not a regression.
  (6) **The NAT attachment does NOT proxy-ARP off-subnet addresses:** a
  guest `net arp 8.8.8.8` broadcast goes unanswered (`learn=0`) and the
  guest's `net ping 8.8.8.8` honestly refuses (`peer not in ARP table`
  — the guest has no routing rung; outbound proof stays at the
  gateway). (7) **No capture file under NAT** — the host translates the
  frames (that is the point), so NAT-path evidence is GUEST-OBSERVED
  COUNTERS, never capture bytes. **[observed]** — every
  `verify-live-net-nat` boot's serial log (`artifacts/live-net-nat-serial-*.log`)
  shows the ip-set / arp-learn / pong lines above, the report's `mac=`
  line, and the runner output shows `net-nat: ENABLED`; the exploratory
  evidence is saved under `artifacts/live-net-nat-explore/` (including
  the off-subnet 8.8.8.8 refusal and the host bridge capture).
  **DHCP observed 2026-08-12 (claim 0351, milestone five card N8):**
  the guest's RFC 2131 client (the `net dhcp` monitor subcommand, src
  68 → dst 67, broadcast dst) completes the full four-message handshake
  against the runner's deterministic `--net-dhcp-respond <lease-ip>`
  server on the file-handle attachment: DISCOVER (286 B, byte-exact in
  the capture) → OFFER → REQUEST (298 B, the same xid, byte-exact) →
  ACK → BOUND with the fixed lease {ip 10.0.0.2, mask 255.255.255.0,
  gateway 10.0.0.1, server id = the lease IP, lease 3600s}, and the
  report shows `discover=1,offer=1,request=1,ack=1,nack=0,timeout=0,
  mal=0`. **CLAIM-TIME OBSERVATION — the VZ NAT attachment serves NO
  DHCP server** (macOS 27 arm64, the whole phase-2 observation window):
  under `--net-nat` the guest's DISCOVER broadcast goes out
  (`discover=1`) and NO OFFER ever arrives (`offer=0, mal=0`) — the
  NAT router answers ARP for its gateway (N7) but not DHCP, so the
  NAT-path lease never materializes and phase 2 is honestly BLOCKED
  with the observation recorded (never faked): the guest falls back to
  the static address and still reaches the gateway (`pong=1 seq=1`).
  If a future host's NAT DOES serve DHCP, the phase-2 gate flips to
  the BOUND path (this observation updated with the new saved log).
  **[observed]** — every `verify-live-net-dhcp` phase-1 boot's serial
  log (`artifacts/live-net-dhcp-p1-serial.log`) shows the bound lease
  + counters, the capture (`live-net-dhcp-p1-cap.bin`) holds the two
  client frames byte-exact, and the runner output shows the NET-DHCP
  OFFER/ACK lines; the phase-2 boot's serial log
  (`artifacts/live-net-dhcp-p2-serial.log`) shows the honest
  offer=0/mal=0 report + the gateway ping; the exploratory evidence is
  saved under `artifacts/live-net-dhcp-nat-explore/`.
  **Lease lifecycle observed 2026-08-12 (claim 9489, milestone five
  card N9):** the client ENFORCES the lease it recorded — the RFC 2131
  §4.4.5 rungs, driven by the monitor on the 1 Hz generic timer
  (`timer.ticks` — integer seconds): at **T1 = lease/2** the client
  RENEWs with a UNICAST REQUEST to the server's IP + the MAC the guest
  resolved (`net arp <server>` — the seam resolves nothing; an
  unresolvable server keeps the client BOUND until T2, RFC-compliant
  degradation); at **T2 = lease*7/8** it REBINDs with a BROADCAST
  REQUEST; at **expiry** it releases the address (arp.own_ip cleared —
  the report shows ip=0.0.0.0 — and the lease record zeroed) and
  re-DISCOVERs. The renewal ACK restarts the lease (bound_ticks
  re-stamped). The renewal REQUESTs carry `ciaddr` = the leased IP
  (RFC 2131 §4.4.5). **[observed]** — every `verify-live-net-dhcp-renew`
  Run-A boot's serial log (`artifacts/live-net-dhcp-renew-a-serial.log`)
  shows the renewing (T1) + rebinding (T2) lines and the counters
  `renew=1,rebind=1,renewed=2,expired=0`, and the capture
  (`live-net-dhcp-renew-a-cap.bin`, 1222 B) holds the RENEWING REQUEST
  byte-exact UNICAST (dst 02:00:00:00:00:02, src/dst IP 10.0.0.2,
  ciaddr 10.0.0.2) vs the REBINDING REQUEST broadcast; the Run-B boot
  (`live-net-dhcp-renew-b-serial.log`) shows the lease-expired line,
  the released report (`dhcp=idle,ip=0.0.0.0,…,expired=1`) and the
  recovery (a second DISCOVER → BOUND again); the exploratory evidence
  is saved under `artifacts/live-net-dhcp-renew-explore/`. The runner's
  lease knob (`--net-dhcp-respond <ip>:<lease-secs>`, default 3600) and
  the script delays (`--script2-delay` / `--script3-delay`, default
  0.5) are flag-gated — every pre-N9 gate is byte-identical.
  **TCP observed 2026-08-12 (claim 7026, milestone five card N10):**
  the guest's bounded RFC 793 client (the `net tcp` monitor subcommand,
  src port 8000, a bare 20-byte header — NO options, window 4096)
  completes the full lifecycle against the runner's deterministic
  `--net-tcp-respond <host-ip>:<host-port>` server on the file-handle
  attachment: SYN (54 B, byte-exact in the capture) → SYN-ACK (the
  FIXED server ISN 0x12345678) → ACK → ESTABLISHED → data (5 B) → the
  payload ECHOED byte-exact (the RX buffer prints `01 02 03 04 05`) →
  FIN → FIN-ACK → final ACK → CLOSED, then a second connect + `net tcp
  reset` (a real RST) — the report shows `syn=2,synack=2,ack=4,
  data_s=1,data_r=1,fin=1,finack=1,rst_s=1,rst_r=0,timedout=0,mal=0`.
  The client's ACK numbers are DETERMINISTIC (0x12345679 / 0x1234567e
  / 0x1234567f — the fixed server ISN). **The bounded connect timeout
  observed** (file-handle, ARP-responder-only — the host never answers
  TCP, a deterministic black hole): after 30 guest seconds the client
  refuses honestly — `connect refused (no SYN-ACK after 30s)`,
  `timedout=1`, the connection state released (peer 0.0.0.0:0).
  **CLAIM-TIME OBSERVATION — the VZ NAT gateway answers a TCP SYN with
  a RST** (macOS 27 arm64, `--net-nat`, connect to 192.168.64.1:9999):
  the gateway (MAC ae:07:75:20:da:64, learned via the N7-proven ARP
  path) actively refuses the connection — no TCP listener on the test
  port — so the client's RST-RX path fires (`rst_r=1`, `tcp=closed`,
  the drive returns it to idle). The VZ NAT does not silently drop; it
  refuses closed ports with a real RST. If a future host's NAT gateway
  instead drops the SYN silently, the honest timeout path fires
  (`timedout=1` — proven by Run B; the Run-C assertion set documents
  where to flip). **[observed]** — every `verify-live-net-tcp` Run-A
  boot's serial log (`artifacts/live-net-tcp-a-serial.log`) shows the
  lifecycle lines + counters, the capture (`live-net-tcp-a-cap.bin`, 533
  B) holds the NINE guest-TX frames byte-exact (the gate's python walk
  verifies the seq/ack chain + every TCP checksum); the Run-B serial log
  (`live-net-tcp-b-serial.log`) shows the timeout refusal, the Run-C
  serial log (`live-net-tcp-c-serial.log`) shows the NAT RST; the
  exploratory evidence is saved under
  `artifacts/live-net-tcp-explore/`. The runner's `--net-tcp-respond`
  is flag-gated — every pre-N10 gate is byte-identical.
  **TCP retransmission observed 2026-08-12 (claim 5357, milestone five
  card N11):** the client's bounded retransmission machinery works live
  on the file-handle attachment — the fixed 3 s RTO (guest seconds, the
  1 Hz generic timer) retransmits a pending unacknowledged segment
  AUTONOMOUSLY (the shell idle loop polls it — `net tcp: syn
  retransmitted (n/10)`), byte-IDENTICAL in the capture (the same seq,
  flags, payload, checksum); an ACK covering `snd_una` clears the
  pending state (no retransmission — `retx=0` despite a wait past the
  RTO); and at the bound (10 retransmissions, 33 s) the connection
  ABORTS honestly (`retransmission limit reached (10) — connection
  aborted`, the state released — no RST, no TX, `retx=10,abort=1`).
  The 30 s connect timeout remains the SYN's outer bound (the abort at
  33 s never beats it — the N10 refusal is unchanged). The runner's
  `--net-tcp-respond` gained the optional `:handshake` mode (claim
  5357) — SYN-ACK yes, data/FIN silent, the gate's deterministic data
  black hole; flag-gated — every pre-N11 gate is byte-identical.
  **[observed]** — every `verify-live-net-tcp-rto` Run-A serial log
  (`artifacts/live-net-tcp-rto-a-serial.log`) shows the autonomous
  `syn retransmitted (n/10)` lines + the capture
  (`live-net-tcp-rto-a-cap.bin`) holds the byte-identical SYN frames;
  the Run-B serial log (`live-net-tcp-rto-b-serial.log`) shows `retx=0`
  with the handshake completing (the capture has exactly ONE SYN); the
  Run-C serial log (`live-net-tcp-rto-c-serial.log`) shows the ten
  `data retransmitted (n/10)` lines + the abort + the released report,
  and the capture (`live-net-tcp-rto-c-cap.bin`) holds the ELEVEN
  byte-identical data frames; the exploratory evidence is saved under
  `artifacts/live-net-tcp-rto-explore/`.
- Custom virtio device (`VZCustomVirtioDeviceConfiguration`, the
  `--custom-virtio` runner flag / `zig build spike-virtio`): the guest sees
  a vendor-defined device on bus 0 as `VID=0x1af4 DID=0x1082`.
  **Discovered by claims 5844/0828** — the device is enumerable, its
  transport BAR0 sits at `0x100020000`, a real SPI 69 IRQ fires on
  used-ring advances, and the firmware boots it with the PCI command
  register disabled (see the dedicated section below). **[observed]**
- Execution evidence: the guest also writes its message to `\BOOTED.TXT` on
  the ESP via the UEFI Simple File System protocol. **Observed**: after a
  VZ boot, the file exists on the image with the exact expected content.
  This is the primary, host-observable proof of guest execution on Apple
  silicon.
- EFI variable store: file-backed (`VZEFIVariableStore`), persisted at
  `artifacts/efi-vars.bin`. Creating one requires
  `init(creatingVariableStoreAt:options:)` on first boot; `init(url:)` only
  opens an existing store.
- **EFI runtime services survive `ExitBootServices` on VZ**: the kernel's
  post-exit `SetVariable` calls are persisted into the file-backed store.
  **[observed]** — after every VZ run, `artifacts/efi-vars.bin` holds the
  `DipshitM2` variable whose final instance names the kernel's last takeover
  stage (`artifacts/m2-marker-gate.txt`, claim 0009, 2026-08-07).
- **Guest RAM is NOT mapped into the host runner process.**
  **[observed]** — a full submap-aware walk of the VMRunner process's own
  address space finds no 256 MiB region and every `M2_*` constant hit is
  the runner's own rodata/heap array (claim 0009). The ADR 0004 D4
  memory-dump fallback is therefore impossible on VZ; the NVRAM ladder is
  the working form.
- Config used: 256 MiB RAM, 2 vCPUs, optional virtio-gpu for observation,
  no networking.

The project targets Apple silicon / Virtualization.framework only; there is
no QEMU path.

## Milestone one: kernel handoff (2026-08-05, branch `m1-kernel-handoff`)

- **Kernel image on the ESP**: `\KERNEL.BIN` is read from the same FAT
  volume via the UEFI Simple File System protocol. **[observed]** — the
  loader reads the file; `LOADER.TXT` records the size it read and the
  first 16 bytes that landed in RAM.
- **Kernel image allocation**: `AllocatePages` with type `EfiLoaderCode`.
  The loader may place the image at any free 4K-aligned address (observed
  at 0x7e55f000 and at 0x7f328000 in different runs); the kernel must be
  position-independent. **[observed]** — `MEMMAP.TXT` shows the allocation
  in ordinary cacheable RAM (`xp=0 wb=1`).
- **Cache maintenance before the jump**: the loader cleans the D-cache and
  invalidates the I-cache over the image (`dc cvau` / `ic ivau` / `dsb` /
  `isb`) before transferring control. **[observed]** — without correct
  handling the kernel never executes (RC.TXT absent); with it the kernel
  runs and returns.
- **The kernel runs without `ExitBootServices`**: it keeps using UEFI Boot
  Services and the Simple File System protocol (its evidence write), on the
  loader's stack. Until a later milestone records an ExitBootServices
  design here, no guest code may touch MMU, interrupts, timers, or device
  MMIO directly. **[inferred]** — we rely on the firmware keeping these
  services available, per the UEFI spec. **Superseded for the kernel
  proper by milestone two**: ADR 0004 records the ExitBootServices design;
  from milestone two on, the boot stub never exits (it keeps this
  constraint forever) while the kernel proper may touch MMU and device
  MMIO under the assumptions in the next section.
- **Resolved quirk (observed)**: the milestone-one `KERNEL.TXT` corruption
  — the kernel's *own* file writes landing as shifted slices of its
  `.rodata` while the loader's identical writes landed byte-perfect — is
  fixed. The loader parses the 24-byte DSK1 header but does **not** load it
  into RAM: the image content sits at `base+0`, so ELF VMA `V` is at RAM
  `base+V`. This is the addressing invariant the kernel's PC-relative
  references depend on — `adr` rides the content offset inside the PC,
  while `adrp`+`add` computes `(PC page) + VMA offset` and only resolves
  correctly with the content at `base+0`. **[observed]** — `KERNEL.TXT` is
  byte-perfect and byte-identical across repeated boots (ADR 0002,
  `artifacts/m1-fix-run{1,2,3}.txt`).

## Milestone two: the kernel proper (implemented, ADR 0004 — MMU/serial findings are **[observed]** per claims 0010/0013/0020/0021/1517/6684; the remaining items below stay **[inferred]**)

Milestone two is implemented in the guest; the MMU and serial findings
below are **[observed]** (claims 0010/0013/0020/0021/1517/6684 on a real Apple M4 /
macOS 27 VZ host), and the remaining items stay **[inferred]** until a
console is actually driven and serial output proves them. Code/build
success alone is not hardware evidence. The concrete numbers are
deliberately isolated so one observed probe can correct them without
redesign.

### MMU

- The kernel runs at EL1 with the MMU **enabled** and the firmware's
  identity map in effect at kernel entry; the firmware does not disable
  the MMU when jumping. **[inferred]** — standard UEFI AArch64 behavior;
  consistent with milestone-one runs but not directly observed.
- **The MMU takeover completes on VZ (fixed 2026-08-07, claim 0010).** The
  kernel's own identity map installs and the first post-switch runtime call
  succeeds; the NVRAM marker ladder runs `M2_MAPD! → M2_MMUP! → M2_SERIA`
  (`artifacts/m2-marker-gate.txt`, claim 0009). The prior claim-0009
  finding (kernel dies in the MMU-takeover window, ladder ending at
  `M2_MAPD!`) is superseded: three ladder-gated experiments discriminated
  the death site, and the fix has three parts — (a) a pre-switch register
  capture proved the guest implements the ARMv8.1+ TCR_EL1 layout (TG0 at
  bits [15:14] = 0b00 = 4 KB granule, 36-bit IPS; re-captured by claim
  0021, `artifacts/fw-mmu-capture-lines.txt` — the claim-0010 raw
  artifact `m2-firmware-regs.txt` is not in this checkout); (b) the
  identity map now covers the low 4 GiB with declared RAM as Normal
  Write-Back and **every other address (including undeclared firmware MMIO
  such as the NVRAM controller)** as Device nGnRnE, so no post-switch
  access can fault on an unmapped address or hang on a cacheable access to
  an emulated device; (c) **the `tlbi vmalle1` is dropped at the switch**
  — see the TLBI bullets below. The D-cache over the 512 KiB table
  carve-out is cleaned before the switch (architectural hardening;
  independently verified not the fix).
- **The TLBI at the switch is now executed with a corrected start level.
  **[observed]** (claims 6460/7896/1517, supersedes claim 0010)** — the
  claim-0010 finding (a TLBI-forced re-walk faults; omitting it survives)
  was the start-level mismatch in disguise: production T0SZ=25/W=39 started
  the 4 KiB stage-1 walk at level 1 over the L0-rooted tables, so every
  fresh walk faulted, and the no-TLBI crutch only survived by riding stale
  firmware TLB entries (ADR 0006). Claims 6460/7896 separated the two on
  real VZ hardware (4-cell matrix: empty-TLB T0SZ=25 dies deterministically
  at the first re-walk; empty-TLB T0SZ=16 completes the whole console path
  9/9), and  claim 1517 landed the production fix: T0SZ=16 + `tlbi vmalle1`
  at the switch. The ADR-0006 no-TLBI validity window is closed; the
  invalidation list for later re-mapping milestones remains binding (see
  **ADR 0006**).
- **Post-switch MMIO access to the virtio-pci BAR window hangs on VZ.
  **[observed, superseded by claim 1517]** (claim 0020, transition matrix)**
  — under the legacy start level (T0SZ=25) the same flush works pre-EBS
  (phase A) and post-EBS on the firmware translation (phase B), and hangs
  at the first common-cfg read immediately after the DipshitOS identity-map
  install (phases C/D); `vm-serial.log` stayed 0 B. The transition that
  destroyed access was the MMU switch — because the first post-switch read
  of the BAR window was the first access whose firmware TLB entry was
  evicted, and its fresh walk faulted (claims 0018/0020/6460/7896).  With the claim-1517 production fix (T0SZ=16 + TLBI at the switch) the
  post-MMU virtio TX completes: the exact banner + memory-map print +
  terminal state land in `vm-serial.log` (`zig build run` gate passes;
  claim 1517).
- **Firmware translation state at the switch. **[observed]** (claim 0021,
  `artifacts/fw-mmu-capture-lines.txt`)** — `SCTLR_EL1.M=1` (MMU on),
  `TCR_EL1=0x18080351c` (T0SZ=28 → 2^36 VA space, TG0 bits [15:14]=0b00 =
  4 KB granule, 36-bit IPS), `MAIR_EL1=0xffbb4400` (Attr0=0x00
  Device-nGnRnE, Attr3=0xff Normal WB), `TTBR1_EL1=0` (no high-half
  tables). The firmware maps the virtio BAR0 window (VA `0x100010000`) as a
  **1 GiB identity block at L1, Device-nGnRnE, XN=1, AF=1, non-shareable**
  and RAM as L3 pages **Normal WB (0xff), inner-shareable** — memory
  attributes byte-identical to the kernel's choices (Device 0x00 / Normal
  0xff), so the post-switch hang is not an attribute mismatch; the
  structural differences are granularity (1 GiB block vs 4 K pages),
  XN/PXN, T0SZ, and MAIR index numbering.
- The kernel builds its own translation tables (never firmware tables):
  TTBR0_EL1, 4K granule, identity map (VA == PA) for RAM, the kernel
  image, and the MMIO windows the drivers need. **[inferred]** — this is a
  design choice, not a hardware fact; it is recorded here because later
  milestones depend on the address space being under kernel control.
- **TTBR1 translation is incompatible with this kernel's tables on VZ
  [measured, claim 5804].** The kernel therefore stays identity-mapped in
  TTBR0 (T0SZ=16, TTBR1=0) and every task gets a per-task TTBR0 root that
  carries an EL1-only overlay of the kernel identity map plus its own EL0
  leaves (the EL0 task's root = a clone of the identity tree with
  text+stack leaves overlaid). Measured failure modes in order: (1) with
  4 KiB-aligned tables the TTBR1 walker faults at the FIRST descent level
  in every configuration — shared L0 root (level-1 fault), dedicated 48-bit
  L0 root (level-1), dedicated 39-bit L1-rooted mirror with T1SZ=25
  (level-2) — despite provably-valid descriptor chains, the signature of a
  walker masking table addresses to 64 KiB; (2) with 64 KiB-aligned tables
  the walk resolves (block and page leaves) but a Normal-WB data access
  through TTBR1 aborts (TLB conflict abort, then synchronous external
  abort DFSC=0x21 after extra invalidations) while Device leaves were
  readable — so a kernel executing from a KVA shadow cannot work on VZ.
  EL0 isolation is enforced by AP bits: every non-user leaf is EL1-only
  (AP=0b00), so an EL0 access to kernel RAM, firmware, or MMIO takes a
  permission fault; UXN/PXN enforce W^X on the user leaves. Recorded so
  later milestones never re-adopt a TTBR1 KVA shadow without re-validating
  it live.
- MAIR_EL1 uses two attributes: Device `nGnRnE` for MMIO and Normal
  Write-Back for RAM. **[inferred]** — standard ARMv8 attribute set.
- IPS (physical address size) is read from `ID_AA64MMFR0_EL1` at runtime.
  **[inferred]** — standard CPU register; the exact value reported by VZ
  is unobserved.

### MMIO / serial console (UART)

- **The declared MMIO windows are not the console (decoded, claim 0013,
  2026-08-07).** **[observed]** — `0x01000000..0x01010000` is Apple's EFI
  variable-store region (raw bytes spell `efivars\0`; post-exit reads hang
  on the efivars controller); `0x20050000..0x20051000` is a PL011-family
  PrimeCell UART (CID0-3 `0x0d 0xf0 0x05 0xb1`, PID1=0x10, PID2=0x04,
  PID3=0x00, PID0=0x31) — but writing DR after full PL011 init yields zero
  bytes in `vm-serial.log`, so it is Apple's internal EFI debug UART, not
  the guest console. Evidence in `artifacts/efi-vars.bin` (probe-dump
  variables `DipshitP*`) and claim 0013.
- **The VZ serial attachment is a modern virtio-pci console.** **[observed]**
  — bus 0 device 5, `VID=0x1af4 DID=0x1043 class=0x078000` (virtio
  communications controller), discovered by pre-exit PCI enumeration over
  ECAM `0x40000000` (MCFG). BAR0 is a 64-bit BAR firmware-assigned at
  `0x100010000` — *above* the 4 GiB identity-map blanket; the assignment
  varies across boots and the device moves with the BAR, which is why the
  old fixed-window probe never saw it.
- **Transport layout decoded via aligned-u32 config reads** (VZ returns
  garbage for byte reads of config space; unaligned reads alignment-fault):
  common cfg @ BAR0+`0x0000` (len 0x38), ISR @ `+0x1000`, notify @ `+0x4000`
  (multiplier 4), device cfg @ `+0x8000`. Pre-exit the transport arms fully
  (features `0x30000000`/`0x5`, queues 0 + 1 configured, DRIVER_OK).
- **Both virtio-console queues are driven and observed (claim 6684):**
  queue 1 (transmit) and **queue 0 (receive)**. The receive queue's
  register path (queue_select/size/enable/notify_off, the ring GPA
  registers written as 32-bit halves, the 16-bit notify with the queue
  index as the value) is **[observed]** — host input bytes written into the
  guest's 256-byte RX buffer arrive at the kernel's polled `readByte` end
  to end, and the shell's echo proves the exact bytes (`vm-serial.log`,
  claim 6684, 3/3 boots).
- **Post-exit access to the transport hangs on VZ. **[observed, superseded
  by claim 1517]** (claim 0013; refined by claims 0018/0020)** — under the
  legacy start level the first banner TX died somewhere in the first flush;
  `vm-serial.log` stayed 0 B. Claim 0018 bisected the death to the first
  post-switch BAR/common-config read (`M2_TXBR!` written, `M2_TXAR!`
  absent, 10/12 boots), and claim 0020 attributed it to the MMU switch
  (the start-level mismatch making the first fresh walk fault, claims
  6460/7896). Rebasing the BAR below the blanket was tried and abandoned:
  the BAR write *does* move the transport, but to an address the firmware
  never mapped pre-exit, and post-exit config writes aren't reliable — so
  the firmware-assigned base is mapped in place. **With the claim-1517 fix
  (T0SZ=16 + TLBI at the switch) post-exit TX works end-to-end on real VZ
  hardware**: banner + memory-map + `dipshit>` prompt observed in
  `vm-serial.log` (claim 1517). The NVRAM channel (runtime `SetVariable`,
  claim 0015) remains the fallback channel for nvram-console builds.
- ACPI names no console: no SPCR/DBG2 in the XSDT (FACP/GTDT/APIC/MCFG
  only); DSDT (Apple's own, `Apple Vz`) declares only `PCI0` + `efivars`.
  **[observed]**

### Interrupts (delivered 2026-08-09, claim 9187)

- A **GICv3** (Generic Interrupt Controller, ARM GIC architecture) is
  present: distributor `GICD` @ `0x10000000` and redistributor `GICR` @
  `0x10010000`; the boot CPU's selected active frame is also
  `0x10010000`. `GICD_CTLR=0x50` (ARE_NS set → v3) and `GICD_TYPER` is
  sane. **[observed]** — live MMIO read-backs (claim 7948), plus the
  claim-9187 serial state line on each of three boots. VZ's MADT does not
  yield a usable distributor/redistributor tuple, so the driver uses the
  live-probed fixed-layout fallback (`fallback=1`, observed 3/3). The GTDT
  supplies EL1 physical-timer GSIV **30** with level-triggered flags
  (`edge=0`).
- **A real timer interrupt is delivered into the guest on VZ.** Periodic
  CNTP PPI 30 enters the EL1 IRQ vector, returns INTID 30 from
  `ICC_IAR1_EL1`, increments the IRQ-only counter, is EOI’d through
  `ICC_EOIR1_EL1`, and re-arms. **[observed]** — `tools/verify-live-timer.sh`
  passes 3/3; every saved serial log contains
  `timer irq delivered ppi=0x1e irq_ticks=1` followed by
  `timer heartbeat ticks=5 irq=5 poll=0`, and the scripted shell reply is
  present. The production idle loop no longer polls the comparator.
- Claim 7948's negative delivery result was a guest-driver artifact, not a
  VZ platform wall. The delivery-blocking bug was that SGI/PPI accesses
  used RD-frame offsets
  such as `GICR+0x80` instead of SGI-frame offsets such as
  `GICR+0x10080`, so PPI 30 was never enabled. The audit also found a
  shifted MADT type mapping (`0x0B` is GICC, `0x0C` GICD, `0x0E` GICR)
  and an ICFGR write to the RES0 bit; those were specification errors, but
  VZ's fixed-layout fallback and the timer's level-triggered mode kept them
  from being the observed delivery blocker. Apple's Xcode 27
  Hypervisor.framework header independently
  names `GICR_IGROUPR0=0x10080`, `ISENABLER0=0x10100`, and
  `ICFGR1=0x10c04`. **[observed from the installed public SDK and corrected
  live guest, claim 9187]**
- Xcode 27's public **Virtualization.framework** SDK still exposes no
  `VZGICConfiguration` or host interrupt-injection API; the separate
  **Hypervisor.framework** exposes `hv_gic_create`, `hv_gic_set_spi`, and
  `hv_gic_send_msi`. **[observed]** — read-only SDK audit saved as
  `artifacts/vz-irq-api-audit.txt`. No host injection or runner change is
  needed for the working timer PPI path.
- The ARM generic timer (CNTP) runs at `CNTFRQ_EL0=24 MHz`; the kernel
  programs `CNTP_CVAL_EL0`/`CNTP_CTL_EL0` for a one-second period.
  **[observed]** — five consecutive IRQ-serviced periods in each live gate
  boot.
- Interrupts are masked at kernel entry (firmware behavior) and explicitly
  unmasked only after vectors, GIC, dispatcher, and timer are armed.
- The one-second timer PPI is now also the kernel's preemption clock: the
  tick-driven round-robin scheduler (claim 5275) switches the shell task
  and a worker task on every PPI, using the claim-9746 IRQ stub's existing
  register save/restore plus a saved frame pointer / ELR / SPSR per task.
  **[observed]** — `tools/verify-live-tasks.sh` PASS: the worker reports
  `tasks worker advances=N` after ≥ 2 real context switches and the shell
  stays responsive (`rx-tasks-ok`).
  **[inferred at entry; observed working after the explicit unmask].**

## Custom virtio device (macOS 27+ spike, claims 5844/0828/4374/9492/9737/4837)

A `VZCustomVirtioDeviceConfiguration` attaches an arbitrary virtio-class
function to the VM; the guest sees a vendor-defined device rather than one
of the standard virtio DID assignments. All findings below are
**[observed]** from `zig build spike-virtio` boots on a real Apple M4 /
macOS 27 VZ host (claims 5844/0828, then the one-boot quad
4374/9492/9737/4837; live gate `tools/verify-custom-virtio.sh`; serial and
host-runner evidence under `artifacts/live-cvspike-*` / `artifacts/vm-spike-*`).

- **Identity: bus 0, `VID=0x1af4 DID=0x1082`, class 0x00/0x00, one
  queue.** **[observed]** — the live `pci` command lists it beside the
  standard VZ devices (console 0x1043, block 0x1042, entropy 0x1044, Apple
  bridge). 0x1082 is **not** in the standard virtio DID table; VZ assigns
  it to the custom configuration.
- **Transport BAR: BAR0 (64-bit) at `0x100020000`** — above the 4 GiB
  identity-map blanket, like the console's BAR0 `0x100010000`. Claim 5844's
  earlier "0x50001000 BAR" note was BAR2; the transport is BAR0. **[observed]**
- **VZ's firmware never enables the PCI command register for the custom
  device** — it boots at `0x10` (memory space off), so BAR0 is inert and
  every access external-aborts until the guest driver writes
  `command=0x16` (the console's exact value) in `init()`. The standard VZ
  virtio devices do not need this. **[observed]** (claim 0828)
- **Config-space access follows the same rules as the console** —
  aligned-u32 reads only (VZ returns garbage for byte reads; unaligned
  reads alignment-fault); the split-ring transport's common cfg, ISR,
  notify, and device cfg live in BAR0. **[observed]**
- **Feature negotiation (claim 9737):** VZ offers `feat=0x530000000` —
  `VIRTIO_F_VERSION_1` plus `RING_PACKED`/`RING_EVENT_IDX`/
  `RING_INDIRECT_DESC` — but **not** `ANY_LAYOUT` or `NOTIFICATION_DATA`;
  the driver accepts only `VERSION_1` (`acc=0x100000000`, `nd=0 al=0`,
  notify is 16-bit), so classic kicks carry everything. **[observed]**
- **Used-buffer IRQ: a real SPI — INTID 0x45 (SPI 69)** enters the
  claim-9746 EL1 IRQ vector, the same SPI Linux's virtio1 uses on this VZ
  surface. **[observed]** — the driver drains the used ring on IRQ and
  re-kicks.
- **VZ coalesces used-buffer IRQs per burst:** four exchanges in one boot
  produced exactly **1 IRQ** (`irq=1`); the IRQ is a notification, not a
  per-element ack — the driver must drain the whole used ring, and all
  replies still arrived reliably. **[observed]** (claim 0828)
- **Two armed split-ring queues (claims 4374/4837):** queue 0 carries
  bidirectional data exchanges (descriptor chains pairing a device-read
  payload with a device-write reply buffer; the used-ring length drives
  reply reads) and queue 1 carries a guest log transport (`cvlog_puts`,
  host echo per line). Multi-descriptor scatter payloads well over 4 KiB
  work end to end — a 12,340-byte three-descriptor payload is reassembled
  and echoed by the host (claim 9492). **[observed]**

## What milestone zero does NOT assume (and does not touch)

- No direct MMIO. No UART programming. No DMA. No interrupts. No GIC.
- No memory map assumptions beyond what the firmware provides.
- No timer services. (The "wait" in the boot application is a plain busy
  loop with no hardware access.)
- No platform clock, no RTC, no power management.
