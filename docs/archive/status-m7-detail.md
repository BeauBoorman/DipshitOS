# Milestone 7 — Seven — input: USB XHCI + HID — archived detail

> **Archived from `docs/status.md` on 2026-08-21 (issue #262).**
> The canonical one-line summary now lives in `docs/status.md` Current position table.
> This file preserves the full narrative that was previously inline in `docs/status.md`
> so the live tracker can stay ~150–200 lines. See also [`docs/march-m7.md`](march-m7.md) and the claim files cited below.

## One-line summary (now in `docs/status.md`)

| Seven — input: USB XHCI + HID | XHCI transport, USB enumeration + HID parsing, event FIFO + keycode decode | ✅ done 2026-08-13 (claim 6050, cards I1–I3) |

- **Close date:** 2026-08-13
- **Claim:** 6050
- **March tracker:** [`docs/march-m7.md`](march-m7.md)

## Full narrative as it appeared in `docs/status.md` (pre-compression)

The following is the verbatim Current position table row for M7, previously at `docs/status.md:41`.

```text
| Seven — input: USB XHCI + HID (keyboard + pointer) | Give Road Pops its FIRST screen-side keystrokes: an XHCI host-controller transport (I1 — MMIO + command/event rings + port status), USB enumeration + HID boot-protocol parsing (I2 — the keyboard + pointing devices behind the XHCI controller), and a bounded event FIFO + keycode decode feeding the line editor (I3). **Premise corrected 2026-08-13 (claim 3868):** VZ's `VZUSBKeyboardConfiguration` + `VZUSBScreenCoordinatePointingDeviceConfiguration` present as an **Apple XHCI USB controller** (`VID=0x106b DID=0x1a06 CLS=0x0c0330`, two MMIO BARs `0x50001000` + `0x50000000`) with the keyboard/pointer as USB HID devices behind it — the hypothesized virtio-input (DID 0x1052) does not exist in the framework. | ✅ **done 2026-08-13 (cards I1–I3 live)** — card **I1 (claim 4272) LIVE 2026-08-13 — the XHCI host-controller transport works on VZ**: `kernel/src/xhci.zig` discovers the Apple XHCI controller pre-exit (bus 0 dev 8, DID 0x1a06 CLS 0x0c0330), maps its MMIO register space post-MMU (BAR0=0x50001000 cap regs / BAR1=0x50000000; CAPLENGTH=0x20, HCIVERSION=0x110, DBOFF=0x940, RTSOFF=0x520, HCSPARAMS1=0x10002010 = 16 slots/32 intrs/16 ports), sets up the command ring + event ring + ERST + primary interrupter, drives a NO-OP command TRB to CC=1 (the ring machinery proven), and reads the port status. **Claim-time observations** (hardware-contract + claim doc): the interrupter register set i lives at RTSOFF+0x20+(0x20×i) (writing ERSTSZ into the MFINDEX region wedged the emulation — the fix); **VZ does NOT reset the controller at ExitBootServices** (pre-reset USBSTS=0x9/USBCMD=0x0 — the XHCI answer to the `st=00` vs `st=0f` question); after HCRST+RS USBSTS=0x0; **ports 9 and 10 report CCS=1** — exactly the two attached HID devices (keyboard + pointer), the I2 handoff. `usb` monitor command (registry 37→38). New class-B gate `bash tools/verify-live-xhci.sh` **PASS 1/1** (14/14 assertions; the gate asserts the guest's own `usb` report — the card's gate-shape change: byte-exact host capture does not apply to a memory-mapped controller). Full class A green; the default VM is byte-identical (no XHCI lines in the default serial log; the `--input` mode is flag-gated OFF). **Card I2 (claim 4116) LIVE 2026-08-13 — USB enumeration + HID works on VZ**: `kernel/src/xhci.zig` now enumerates BOTH devices end to end (port reset → Enable Slot → Address Device → device + config descriptors over the control endpoint → Set Configuration 1 → interrupt-IN endpoint armed) and parses the HID boot-protocol reports — the **keyboard (port 9, slot 1, VID 0x05ac PID 0x8105, boot protocol=1, EP1-IN maxpkt 8, boot=1)** and the **absolute pointer (port 10, slot 2, VID 0x05ac PID 0x8106, protocol=0 — NOT a boot mouse — EP1-IN maxpkt 10, Set_Protocol(boot) honestly REFUSED boot=0)**. A synthesized host keyDown (macOS keyCode 0, dispatched by the runner's new minimal `--input-key`/`--input-key-after` seam — VZ has NO programmatic keyboard API) produced the observed 8-byte report `00 00 04 00 00 00 00 00` (mod 0, HID usage 0x04 = 'a'). `usb` gained `usb devices`/`usb report` (registry 38 stays). New class-B gate `bash tools/verify-live-usb.sh` **PASS 1/1** (11/11 assertions; the gate asserts the guest's own `usb devices` + `usb report` lines — no host-side byte-exact capture applies to a memory-mapped controller). **Card I3 (claim 6050) LIVE 2026-08-13 — keystrokes drive Road Pops on VZ**: `kernel/src/input.zig` is a bounded pure-BSS event FIFO + HID-usage → ASCII keymap + the shell-idle drain (the card-3d pattern, next to net RX): the XHCI interrupt-IN reports decode to ASCII bytes that the Road Pops tee's read path hands to the line editor. **Claim-time observations** (hardware-contract + claim doc): VZ delivers ~one report per Road Pops present cadence, so the runner's scripted key surface types at 2 s per keystroke (faster drops reports); single-TRB arming (re-armed per completion) is the correct shape — a multi-TRB depth experiment wrapped the transfer ring at the 8th report and dropped everything after; the input drain runs BEFORE the Road Pops present so a report is never starved behind a slow full-frame present. The runner's `--input-string`/`--input-string-after` synthesizes one NSEvent per keyDown/keyUp into the VZVirtualMachineView (VZ has NO programmatic keyboard API). `input` monitor command (registry 38→39: armed/fifo/drop count/last keyboard + pointer events). New class-B gate `bash tools/verify-live-input.sh` **PASS 1/1** (8/8 assertions): the keyboard typed `input\n` and the guest's own `input` report showed `events=6` (i,n,p,u,t,Enter) with `dropped=0` and `kb-usage=0x28 kb-byte=0xa` (Enter) — the typed command ran end to end. Full class A green; the default VM is byte-identical (no xhci/input/usb lines in the default serial log; the `--input` mode is flag-gated OFF). Milestone seven closed — I1/I2/I3 are all live,handing Road Pops its first screen-side keystrokes. (G5 — Driving Award
```

### Readable paragraph form

**Milestone:** Seven — input: USB XHCI + HID (keyboard + pointer)

**What it proved / is:** Give Road Pops its FIRST screen-side keystrokes: an XHCI host-controller transport (I1 — MMIO + command/event rings + port status), USB enumeration + HID boot-protocol parsing (I2 — the keyboard + pointing devices behind the XHCI controller), and a bounded event FIFO + keycode decode feeding the line editor (I3). **Premise corrected 2026-08-13 (claim 3868):** VZ's `VZUSBKeyboardConfiguration` + `VZUSBScreenCoordinatePointingDeviceConfiguration` present as an **Apple XHCI USB controller** (`VID=0x106b DID=0x1a06 CLS=0x0c0330`, two MMIO BARs `0x50001000` + `0x50000000`) with the keyboard/pointer as USB HID devices behind it — the hypothesized virtio-input (DID 0x1052) does not exist in the framework.

**Status:** ✅ **done 2026-08-13 (cards I1–I3 live)** — card **I1 (claim 4272) LIVE 2026-08-13 — the XHCI host-controller transport works on VZ**: `kernel/src/xhci.zig` discovers the Apple XHCI controller pre-exit (bus 0 dev 8, DID 0x1a06 CLS 0x0c0330), maps its MMIO register space post-MMU (BAR0=0x50001000 cap regs / BAR1=0x50000000; CAPLENGTH=0x20, HCIVERSION=0x110, DBOFF=0x940, RTSOFF=0x520, HCSPARAMS1=0x10002010 = 16 slots/32 intrs/16 ports), sets up the command ring + event ring + ERST + primary interrupter, drives a NO-OP command TRB to CC=1 (the ring machinery proven), and reads the port status. **Claim-time observations** (hardware-contract + claim doc): the interrupter register set i lives at RTSOFF+0x20+(0x20×i) (writing ERSTSZ into the MFINDEX region wedged the emulation — the fix); **VZ does NOT reset the controller at ExitBootServices** (pre-reset USBSTS=0x9/USBCMD=0x0 — the XHCI answer to the `st=00` vs `st=0f` question); after HCRST+RS USBSTS=0x0; **ports 9 and 10 report CCS=1** — exactly the two attached HID devices (keyboard + pointer), the I2 handoff. `usb` monitor command (registry 37→38). New class-B gate `bash tools/verify-live-xhci.sh` **PASS 1/1** (14/14 assertions; the gate asserts the guest's own `usb` report — the card's gate-shape change: byte-exact host capture does not apply to a memory-mapped controller). Full class A green; the default VM is byte-identical (no XHCI lines in the default serial log; the `--input` mode is flag-gated OFF). **Card I2 (claim 4116) LIVE 2026-08-13 — USB enumeration + HID works on VZ**: `kernel/src/xhci.zig` now enumerates BOTH devices end to end (port reset → Enable Slot → Address Device → device + config descriptors over the control endpoint → Set Configuration 1 → interrupt-IN endpoint armed) and parses the HID boot-protocol reports — the **keyboard (port 9, slot 1, VID 0x05ac PID 0x8105, boot protocol=1, EP1-IN maxpkt 8, boot=1)** and the **absolute pointer (port 10, slot 2, VID 0x05ac PID 0x8106, protocol=0 — NOT a boot mouse — EP1-IN maxpkt 10, Set_Protocol(boot) honestly REFUSED boot=0)**. A synthesized host keyDown (macOS keyCode 0, dispatched by the runner's new minimal `--input-key`/`--input-key-after` seam — VZ has NO programmatic keyboard API) produced the observed 8-byte report `00 00 04 00 00 00 00 00` (mod 0, HID usage 0x04 = 'a'). `usb` gained `usb devices`/`usb report` (registry 38 stays). New class-B gate `bash tools/verify-live-usb.sh` **PASS 1/1** (11/11 assertions; the gate asserts the guest's own `usb devices` + `usb report` lines — no host-side byte-exact capture applies to a memory-mapped controller). **Card I3 (claim 6050) LIVE 2026-08-13 — keystrokes drive Road Pops on VZ**: `kernel/src/input.zig` is a bounded pure-BSS event FIFO + HID-usage → ASCII keymap + the shell-idle drain (the card-3d pattern, next to net RX): the XHCI interrupt-IN reports decode to ASCII bytes that the Road Pops tee's read path hands to the line editor. **Claim-time observations** (hardware-contract + claim doc): VZ delivers ~one report per Road Pops present cadence, so the runner's scripted key surface types at 2 s per keystroke (faster drops reports); single-TRB arming (re-armed per completion) is the correct shape — a multi-TRB depth experiment wrapped the transfer ring at the 8th report and dropped everything after; the input drain runs BEFORE the Road Pops present so a report is never starved behind a slow full-frame present. The runner's `--input-string`/`--input-string-after` synthesizes one NSEvent per keyDown/keyUp into the VZVirtualMachineView (VZ has NO programmatic keyboard API). `input` monitor command (registry 38→39: armed/fifo/drop count/last keyboard + pointer events). New class-B gate `bash tools/verify-live-input.sh` **PASS 1/1** (8/8 assertions): the keyboard typed `input\n` and the guest's own `input` report showed `events=6` (i,n,p,u,t,Enter) with `dropped=0` and `kb-usage=0x28 kb-byte=0xa` (Enter) — the typed command ran end to end. Full class A green; the default VM is byte-identical (no xhci/input/usb lines in the default serial log; the `--input` mode is flag-gated OFF). Milestone seven closed — I1/I2/I3 are all live,handing Road Pops its first screen-side keystrokes. (G5 — Driving Award

### Archived `## What comes immediately afterward` entries for M7

The `## What comes immediately afterward` section in pre-compression `docs/status.md` (lines 357–580)
contained 1 numbered entries that detailed M7's cards.
The entries have been removed from the live tracker; their substance lives in the march file and claims.
For historical fidelity, the original bullets that referenced M7 are excerpted below (see git history `docs/status.md` @ `aa4f111` for full section):

> **Bullet 17:**
> 17. **Milestone six, card G1 — virtio-gpu transport + framebuffer (DONE
>     2026-08-12, claim 6053; prompt `docs/m6-gpu-prompt.md`).** The FIRST
>     NON-BLANK GUEST FRAMEBUFFER is live on VZ: `--display` runner mode,
>     `kernel/src/virtio_gpu.zig`, `screen`/`screen fill`/`screen peek`
>     (registry 34→35), gate `tools/verify-live-screen.sh` PASS 1/1, and
>     the claim-time observations (DID 0x1050, VER1-only, reset at
>     ExitBootServices, B8G8R8X8 + opaque alpha, virtio-gpu 1.2 wire
>     shapes). The full 35-gate `verify-vz` aggregate re-ran green.
>     ~~**What's next: card G2 — framebuffer text rendering.**~~ **DONE
>     2026-08-12 (claim 3194):** `text.zig` (the built-in 8x8 bitmap font,
>     putc/puts/cursor/scrollback/clear; 21 host tests against a mock
>     canvas) paints the banner + `dipshit>` prompt on G1's framebuffer;
>     `text`/`text put`/`text clear` (registry 35→36); gate
>     `tools/verify-live-text.sh` PASS 1/1 (the decoded capture shows
>     glyphs — green fg over the dark bg, screen no longer monochrome); the
>     full 36-gate `verify-vz` aggregate re-ran green 36/36.
>     ~~**What's next: card G3 — Road Pops, the boot terminal goes
>     graphical.**~~ **DONE 2026-08-12 (claim 1574):** `road_pops.zig`
>     tees the console — serial shared seam + G2's text layer, drained one
>     present per output batch by the shell idle loop; the boot banner is
>     the shell's own, rendered by the tee; `roadpops` command (registry
>     36→37); gate `tools/verify-live-roadpops.sh` PASS 1/1 (the decoded
>     capture shows banner + live session glyphs below it); the 37-gate
>     `verify-vz` aggregate re-ran green 37/37. **Post-G3 hardening (the
>     SCK switch, 2026-08-12)**: the pixel gates now REQUIRE the
>     ScreenCaptureKit composited-window evidence (any cacheDisplay
>     fallback fails), and introduced the `tools/verify-live-glyphs.sh`
>     mirror-tripwire gate. **Issue #125 correction (claim 8742,
>     2026-08-14):** the imported font rows are LSB-left, but BOTH kernel
>     rasters read bit 7 as the left pixel; the first decoder repeated that
>     same wrong convention, so its historical PASS was self-consistent,
>     not independent proof of orientation. `font8x8.row_pixel` now owns
>     the LSB-left contract for the terminal and Driving Award renderers,
>     while the decoder normalizes source rows to screen order and pins the
>     convention with a hard-coded asymmetric `C` golden. **[observed]** The
>     repaired gate passed on VZ/ScreenCaptureKit: the terminal decoded
>     forward with 0 unknowns / 604 ink versus 549/595 mirrored; the clock
>     decoded exactly as title `clock` and body `DRIVING AWARD`, versus 4/5
>     and 10/13 unknown glyphs mirrored. The earlier 38/38 aggregate remains
>     historical; its glyph-orientation result is superseded by this claim's
>     targeted live rerun (`artifacts/live-glyphs-gate.txt`,
>     `artifacts/gpu-screen-15s`).
>     **What's next: milestone seven — input (keyboard + pointer)** so
>     keystrokes come from the screen side. **[observed]** 2026-08-13
>     (claim 3868): VZ exposes keyboard/pointer as an **Apple XHCI USB
>     controller** (`VID=0x106b DID=0x1a06 CLS=0x0c0330`) with USB HID
>     devices behind it — NOT the hypothesized virtio-input (DID 0x1052),
>     which does not exist in the framework. The G4 card was split into its
>     own milestone (I1 XHCI transport → I2 USB enumeration + HID → I3 event
>     FIFO + keycode decode); then G5 **Driving Award** back in milestone
>     six. **Card I1 (claim 4272) DONE 2026-08-13** — the XHCI host-controller
>     transport (MMIO + command/event rings + NO-OP + port status) is live
>     on VZ. **Card I2 (claim 4116) DONE 2026-08-13** — USB enumeration + HID
>     is live on VZ: BOTH devices enumerate end to end (port reset → Enable
>     Slot → Address Device → config descriptors → Set Configuration →
>     interrupt-IN armed) — the keyboard (port 9, PID 0x8105, boot protocol,
>     8-byte reports) and the absolute pointer (port 10, PID 0x8106,
>     non-boot, 10-byte reports); a synthesized host keyDown produced the
>     observed 8-byte report `00 00 04 00 00 00 00 00` (mod 0, HID usage
>     0x04 = 'a'). **Card I3 (claim 6050) DONE 2026-08-13** — the bounded BSS
>     event FIFO + keycode decode feeds Road Pops' line editor: the runner's
>     new `--input-string` seam (one synthesized NSEvent per keyDown/keyUp;
>     VZ has no keyboard API) typed `input\n` and the guest's own `input`
>     command reported `events=6` (i,n,p,u,t,Enter) with `dropped=0` — the
>     first screen-side keystrokes reach the terminal end to end. Plan
>     [`docs/march-m7.md`](march-m7.md).
>     **Card G5 (claim 1543) DONE 2026-08-13 — Driving Award, the window
>     manager**: `kernel/src/driving_award.zig` (bounded BSS registry,
>     z-order, focus, hit-test, dirty-rect compositor) makes Road Pops
>     window 0 and a 1 Hz clock overlay window 1;`dui`/`dui focus`/`dui raise`/`dui hit` (registry 39→40); gate `tools/verify-live-win.sh`
>     PASS 1/1 (two overlapping windows with the right z-order — the
>     decoded capture shows the clock's amber title bar + navy body over
>     the terminal — and a keyboard-typed `uname` landing in the focused
>     terminal). The 42-gate `verify-vz` aggregate now includes
>     `live-win`; the default VM stayed byte-identical.
>     **Card G6 (claim 0487) DONE 2026-08-13 — the draw/window syscall
>     seam**: the ADR 0007 slots 12/13/14 (`sys_win_open`/`sys_win_fill`/
>     `sys_win_present`, implemented 12 → 15, then a teardown follow-on
>     adds slot 15 `sys_win_close` + `dui close` → 16) expose the G5
>     user-window surface to EL0; WIN.BIN opens a bounded kernel-owned
>     window (id 2..3,
>     fixed BSS back-buffer ≤ 256×192 B8G8R8X8), fills it (dark-blue
>     background + red/cyan/white blocks), presents it, and exits 87; gate
>     `tools/verify-live-win-syscall.sh` PASS 1/1 (`dui: windows=3
>     focused=2` + `dui[2]: user user rect=64,64,256,192` z=2, `syscalls`
>     implemented=16 with open=1/fill=4/present=1 + slot 15
>     `sys_win_close` registered, and the decoded capture shows the window's
>     own content over the terminal).    **Teardown follow-on:** `dui close <n>`
>     + `sys_win_close` (slot 15) release a user window so the id can be
>     re-opened instead of leaking until reboot (open → close → re-open
>     host-tested in `driving_award` + `syscall`, and proven LIVE by
>     WINCLOSE.BIN — the gate `tools/verify-live-win-close.sh` PASS 1/1:
>     the window gone (`windows=2`) and the freed slot re-opened as id 2).
>     **Ownership follow-on:** windows are OWNED by the opening process and
>     AUTO-CLOSE when it exits (`close_owner` from the scheduler's exit
>     path); fill/present/close are owner-restricted (host-tested
>     cross-process refusals); WIN.BIN's window now vanishes on exit
>     (`windows=2`, `sys_win_close calls=0`) and WINLOOP.BIN keeps a window
>     alive for the decoded-capture pixel proof.
>     Milestone six closed — G1–G6 all live; the default VM stayed
>     byte-identical.

### Gates and claims

Primary claim: **6050** (see `docs/claims/6050-*.md` if present).
Full gate inventory: [`docs/gate-inventory.md`](../gate-inventory.md)
Hardware contract: [`docs/hardware-contract.md`](../hardware-contract.md)

---
_Generated by compression of `docs/status.md` (issue #262, 2026-08-21). Do not edit the one-line summary in `docs/status.md` without updating this archive if the narrative is still relevant._