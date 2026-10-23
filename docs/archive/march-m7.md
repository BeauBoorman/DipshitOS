> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone seven march — input: USB XHCI + HID (keyboard + pointer) (living tracker)

## Where we are

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts, current gates, and what comes next. This file holds only
> milestone-seven's per-card detail and collision-free agent split, following
> the [`march-m5.md`](march-m5.md) / [`march-m6.md`](march-m6.md) pattern.
> It was created 2026-08-13 when milestone six's G4 input card was re-scoped
> into its own milestone (the claim-3868 observation — see below). A card's
> row flips to ✅ only with real observed class-B evidence, never
> code-complete alone.

Milestone seven is the **input** milestone: the graphical Road Pops terminal
(G3) gets its FIRST screen-side keystrokes. Milestone six's G4 card
hypothesized a virtio-input device (spec DID 0x1052); **claim 3868 observed
that hypothesis is wrong** — VZ exposes `VZUSBKeyboardConfiguration` +
`VZUSBScreenCoordinatePointingDeviceConfiguration` as an **Apple XHCI USB
host controller** (`VID=0x106b DID=0x1a06 CLS=0x0c0330`, two MMIO BARs
`0x50001000` + `0x50000000`) with the keyboard/pointer as USB HID devices
behind it, and the framework has NO virtio-input device config at all.
Screen-side input therefore needs a real USB stack, which is a milestone's
worth of work, not one card. The rungs, in order: **I1 XHCI host-controller
transport** (MMIO + command/event rings + port status, NO HID yet) → **I2 USB
enumeration + HID** (port reset, address assignment, config descriptors,
interrupt-IN endpoints, HID boot-protocol report parsing) → **I3 the event
FIFO + keycode decode** (bounded BSS FIFO feeding Road Pops' line editor +
pointer). The runner's flag-gated `--input` mode (claim 3868, OFF by default)
already attaches the configs; the full milestone sketch with non-goals is
archived at
[`docs/archive/roadmap-m7.md`](roadmap-m7.md).

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| I1 | **XHCI host-controller transport (NO HID yet).** `kernel/src/xhci.zig`: discover the Apple XHCI device (`VID=0x106b DID=0x1a06 CLS=0x0c0330` — **[observed]** claim 3868), map its two MMIO BARs (capability/operational/doorbell/RT regs), parse HCSPARAMS/HCSPARAMS1/HCSPARAMS2, set up the command ring + event ring + the primary interrupter, and drive a NO-OP command TRB to completion (the ring machinery proven). `usb` monitor command: device/DID/BARs, HCSPARAMS, ring state, port status (USBSTS/PORTSC — how many ports, which are connected/disabled). Honest bounds: NO port reset, NO device enumeration, NO transfer rings yet (I2); NO interrupt-driven event drain — polled, like the claim-6076 net lesson (the XHCI event IRQ is observed, not assumed, at claim time). Post-exit re-arm: does VZ reset the XHCI device at ExitBootServices? — **observed, not assumed** (the gpu/blk/entropy `st=00` vs net `st=0f` question has no XHCI answer yet). | ✅ done (claim 4272) | Live `usb` report: DID 0x1a06/CLS 0x0c0330 on bus 0 dev 8, BAR0=0x50001000 (cap regs)/BAR1=0x50000000, CAPLENGTH=0x20/VER=0x110/DBOFF=0x940/RTSOFF=0x520, HCSPARAMS1=0x10002010 (16 slots/32 intrs/16 ports), pre-reset USBSTS=0x9/USBCMD=0x0 (VZ does NOT reset at EBS), NO-OP completed CC=1 with USBSTS=0x0, ports 9+10 connected (CCS=1 — the two HID devices) and ports 1-8/11-16 unconnected. `tools/verify-live-xhci.sh` PASS. | Gate: live boot prints the full `usb` report — the DID/class/BARs, the HCSPARAMS fields, the ring heads/tails, and a NO-OP command that completes (event-ring TRB observed) — plus the port count + connected-port state. This is the "rings work" hurdle; I2 is where the devices actually speak. |
| I2 | **USB enumeration + HID.** Port reset, address assignment (Enable Slot + Address Device commands), read the device + config descriptors over the control endpoint (Setup/Data/Status transfer TRBs), select configuration 1, and arm the interrupt-IN endpoints for the keyboard + pointing devices. HID boot-protocol report parsing: the 8-byte keyboard boot report (modifier byte + keycode) and the absolute-coordinate pointer report, observed byte-exact at claim time. `usb` gains `usb devices` (the enumerated table: address/VID/PID/class + descriptor summary) and `usb report` (last raw report bytes + decode). Honest bounds: boot protocol only (no full HID report-descriptor parser), the two known devices (keyboard + pointing), no hubs, no mass storage, no isochronous. | ✅ done (claim 4116) | Live `usb devices`: BOTH devices enumerated — port 9/slot 1 = keyboard (VID 0x05ac PID 0x8105, HID boot protocol=1, EP1-IN maxpkt 8, boot=1), port 10/slot 2 = absolute pointer (VID 0x05ac PID 0x8106, protocol=0 — NOT a boot mouse — EP1-IN maxpkt 10, Set_Protocol(boot) honestly REFUSED boot=0). A synthesized host keyDown (macOS keyCode 0) produced the observed 8-byte report `00 00 04 00 00 00 00 00` (mod 0, HID usage 0x04 = 'a') read back by `usb report`. `tools/verify-live-usb.sh` PASS (11/11 assertions). | Gate: live boot enumerates BOTH devices (address assigned, VID/PID/class read, config selected) and a scripted host key event produces the observed raw HID report printed by `usb report`. Depends on I1. The runner gained the minimal synthesized-key seam (`--input-key <mac-keycode>` + `--input-key-after <marker>`) because VZ has no programmatic keyboard API; the full scripted key-sequence surface that types into Road Pops stays I3. |
| I3 | **Event FIFO + keycode decode → Road Pops.** A bounded BSS event FIFO (pure BSS, the card-3d pattern): interrupt-IN reports land as keyboard/pointer events (pushed from the drain site, consumed by the shell idle loop), keycode → ASCII decode (modifiers, shift, the usable ASCII subset) feeding Road Pops' line editor, pointer motion/buttons recorded. `input` monitor command (device state + FIFO occupancy + last events). The runner gains a scripted host key-injection surface for the live gate. | ✅ done (claim 6050) | Live: the runner's `--input-string "input\n"` synthesized one NSEvent per keyDown/keyUp into the VZVirtualMachineView (VZ has no keyboard API) after the boot self-test settled, and the guest's own `input` command reported `events=6` (i,n,p,u,t,Enter) with `dropped=0`, `kb-usage=0x28 kb-byte=0xa` (Enter) — the typed command ran end to end. `tools/verify-live-input.sh` PASS (8/8 assertions). Claim-time: VZ delivers ~one report per Road Pops present cadence, so the seam types at 2 s per keystroke; single-TRB arming (re-armed per completion) is the correct shape — the earlier multi-TRB depth wrapped the transfer ring at the 8th report and dropped everything after. The input drain runs BEFORE the Road Pops present in the idle loop so a report is never starved behind a slow full-frame present. | Gate: live keystrokes drive Road Pops end to end — scripted host key events type a command that is echoed/answered on the screen AND on serial (serial stays the evidence channel). Depends on I2; this is what makes the graphical terminal a real machine, and G5 (Driving Award, back in milestone six) depends on it. |

## Agent split / collision rules

- **I1** (claim 4272, ✅ done): owns `kernel/src/xhci.zig` (the MMIO map +
  HCSPARAMS + command/event rings + NO-OP + port status), the `usb` monitor
  command's controller report, the hardware-contract XHCI entries (BAR
  layout, HCSPARAMS, port count, reset-at-EBS — all claim-time
  observations), and `tools/verify-live-xhci.sh`. No HID, no transfer rings,
  no enumeration.
- **I2** (claim 4116, ✅ done): owns the enumeration path in
  `kernel/src/xhci.zig` (port reset, Enable Slot, Address Device, control
  transfers, Set Configuration, interrupt-IN arming), the HID boot protocol
  parser, the `usb devices`/`usb report` subcommands, the hardware-contract
  HID entries (report shapes, endpoint config, the boot/refused-boot
  negotiation), the runner's minimal synthesized-key seam
  (`--input-key`/`--input-key-after`), and `tools/verify-live-usb.sh`.
- **I3** (claim 6050, ✅ done): owns the bounded event FIFO, the keycode →
  ASCII keymap, the Road Pops line-editor feed (the G3-owned `road_pops.zig`
  gains an INPUT hook — I3 claims it), the `input` monitor command, the
  runner's scripted key-injection mode (`--input-string`/`--input-string-after`),
  and `tools/verify-live-input.sh`.
- **G5** (future claim, milestone six): owns `kernel/src/driving_award.zig`
  and consumes the I3 input path — it claims only after I3 lands on merged
  main, per the repo workflow.
- Cross-cutting docs (`status.md`, `gate-inventory.md`, `hardware-contract.md`)
  are updated per card at claim close-out, never during implementation.
