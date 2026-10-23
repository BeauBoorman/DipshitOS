# Roadmap archive — Milestone six — graphics: Driving Award + Road Pops

> **Archived 2026-08-21** from `docs/roadmap.md` (issue #264, claim 2860):
> the milestone is complete; this file preserves its roadmap plan/detail
> verbatim as history, not an active work order. Canonical status:
> [`docs/status.md`](../status.md).

---

## Milestone six — graphics: Driving Award + Road Pops (**IMPLEMENTED 2026-08-13 — G1–G6 all live, milestone closed**)

> **Scope sketch (2026-08-12) — implemented below.** The last open virtio
> surface row (Graphics) became a real milestone: the machine boots to a
> **graphical interface**. The boot terminal that had been the M1.5
> "Dipshit Monitor" over the virtio serial console became **Road Pops**, a
> graphical terminal window, running under **Driving Award**, the window
> manager. Every card below kept the project's honest bounds (fixed BSS,
> no heap, one-request-at-a-time device access, gates with real observed
> evidence) and recorded new hardware assumptions in
> `docs/hardware-contract.md`. The runner's `--screenshot` channel already
> attaches the device (`VZVirtioGraphicsDeviceConfiguration`, 1280×720
> scanout); the milestone's evidence path was that channel's raw pixels,
> byte-asserted like the net captures. All cards landed — see the ladder
> below and `docs/status.md`.

Card ladder (canonical order; per-card tracker
[`docs/march-m6.md`](march-m6.md)):

- **G1 — virtio-gpu transport + framebuffer** (`kernel/src/virtio_gpu.zig`).
  ~~Discover the virtio-gpu device (spec DID 0x1050 — **[inferred]** until
  observed on VZ, like every DID before it), negotiate features, set up
  the scanout + resources, and give the kernel a writable framebuffer
  (virtio-gpu 2D command path / resource mapping — the exact exposure
  mode is a claim-time observation). Post-exit re-arm per the claim-6420
  lesson (whether VZ resets the gpu device at ExitBootServices is
  observed, not assumed). `screen` monitor command (scanout/framebuffer
  report) + a solid-fill test. **Gate:** the host `--screenshot` capture
  shows real guest pixels (a known color marker) — the first non-blank
  framebuffer.~~ **✅ DONE 2026-08-12 (claim 6053)** — DID 0x1050
  observed (class 0x038000), VER1-only accepted, the spec 2D command
  path to a writable BSS framebuffer (B8G8R8X8, opaque alpha), the
  post-exit re-arm (VZ resets the gpu at ExitBootServices — `st=00`),
  `screen`/`screen fill`/`screen peek` (registry 34→35), and
  `tools/verify-live-screen.sh` PASS 1/1: the decoded capture is the
  fill green (first non-blank framebuffer; evidence
  `artifacts/live-screen-*`, `artifacts/gpu-screen-*s`).
- **G2 — framebuffer text rendering** ✅ **done 2026-08-12 (claim 3194, branch `agent/buffy/m6-text`)** — `kernel/src/text.zig` (a built-in 8x8 bitmap font, fixed BSS glyph data, putc/puts, cursor, line wrap, a bounded 128-line scrollback ring, `clear`; pure logic host-tested against an injectable mock canvas — 21 tests including golden glyphs); the kernel paints its banner + `dipshit>` prompt on G1's framebuffer (fg 0x00ff00 / bg 0x101418) and pushes it through G1's transfer/flush unchanged; `text`/`text put`/`text clear` monitor commands (registry 35→36). **Live gate `tools/verify-live-text.sh` PASS 1/1**: the decoded capture shows real glyphs (green fg over the dark bg in the banner region — fg=0.255/bg=0.745 sampled; the G1-gate precedent: live pixels are color-managed, byte-exact glyphs live in the class A mock); the 36-gate `verify-vz` aggregate re-ran **36/36 PASS** (`artifacts/m6-text-vz-sweep.log`).
- **G3 — Road Pops: the boot terminal goes graphical** ✅ **done
  2026-08-12 (claim 1574, branch `agent/buffy/m6-roadpops`)** —
  `kernel/src/road_pops.zig`: a TEE console (serial shared seam FIRST +
  G2's text layer), drained one full-frame present per output batch by
  the shell idle loop; the G2 one-shot boot paint is replaced by the tee
  rendering the shell's OWN banner. Claim-time fix: the `Target` struct
  literal was folded into `.rodata` with link-time `&fn` addresses
  (claim-0015 redux, faulted live) — built in RAM now. `roadpops`
  command (registry 36→37). **Live gate `tools/verify-live-roadpops.sh`
  PASS 1/1**: the decoded capture shows the banner AND the live session
  glyphs below it (echoed commands + replies rendered — a working
  terminal on screen; serial shared seam intact). G1/G2 gates updated
  honestly (the terminal renders over the raw fill; the `text` report's
  cur/lines are session-dynamic); the **37-gate `verify-vz` aggregate
  re-ran 37/37 PASS** (`artifacts/m6-roadpops-vz-sweep.log`). Post-G3
  hardening (the SCK switch): the pixel gates enforce the composited-
  window evidence, and introduced the `tools/verify-live-glyphs.sh`
  mirror-tripwire gate. **Issue #125 / claim 8742 corrected that first
  gate's false oracle on 2026-08-14:** the font source is LSB-left, while
  both renderers and the decoder had repeated an MSB-left interpretation.
  The terminal and Driving Award clock now share the corrected source-bit
  helper; an independent asymmetric `C` golden pins the decoder's
  normalization. The targeted VZ rerun passed: terminal forward 0/604
  unknown glyphs versus 549/595 mirrored; clock title `clock` and body
  `DRIVING AWARD` exact versus 4/5 and 10/13 unknowns mirrored. The
  historical 38/38 aggregate predates this correction; see
  `docs/status.md` and `artifacts/live-glyphs-gate.txt` for the superseding
  evidence.
- **G4 — input: keyboard + pointer — MOVED to milestone seven.**
  **[observed]** 2026-08-13 (claim 3868): VZ exposes keyboard/pointer
  (`VZUSBKeyboardConfiguration` + `VZUSBScreenCoordinatePointingDeviceConfiguration`)
  as an **Apple XHCI USB host controller** (`VID=0x106b DID=0x1a06`
  `CLS=0x0c0330`) with USB HID devices behind it — there is no virtio-input
  device (DID 0x1052) in the framework. Screen-side input is therefore a
  full USB XHCI + HID stack, split into its own milestone — see
  [**Milestone seven**](roadmap-m7.md)
  and [`docs/march-m7.md`](march-m7.md).
- **G5 — Driving Award: the window manager.** ✅ **DONE 2026-08-13
  (claim 1543)** — `kernel/src/driving_award.zig`: a bounded fixed-BSS
  window registry (max 8) with z-order = array order, focus tracked by
  id, topmost-window hit-testing, and a dirty-rect compositor that
  repaints from the LOWEST dirty window up (the overlay-preserving
  order) and pushes one transfer + flush per dirty batch. Road Pops is
  window 0 (the full-screen terminal); a 1 Hz clock overlay (960,16
  304×192, amber title bar / navy body, own BSS back-buffer) is window
  1, redrawn from `timer.ticks` by the shell idle loop. The G3 tee's
  present now routes through the compositor, `text put`/`clear`
  composite too, and the I3 keyboard read source is gated on
  `terminal_focused()` — screen-side input lands in the focused window.
  `dui`/`dui focus <n>`/`dui raise <n>`/`dui hit <x> <y>` (registry
  39→40); 9 host tests pin the hit-test/raise/focus/repaint/blit
  contracts. **Live gate `tools/verify-live-win.sh` PASS 1/1**: the
  serial session (`dui: windows=2 focused=0`, `dui[]` rows,
  `dui hit 1000,100 -> 1` focusing the clock, `dui hit 100,400 -> 0`
  re-focusing the terminal) + a KEYBOARD-typed `uname` landing in the
  focused terminal, and the decoded capture shows two overlapping
  windows with the right z-order (the clock's amber title bar + navy
  body over the terminal, the terminal's green glyphs beside it). Full
  class A green; the default VM stayed byte-identical.
- **G6 — a draw/window syscall seam for user programs.** ✅ **DONE
  2026-08-13 (claim 0487)** — the ADR 0007 amendment slots 12/13/14
  (`sys_win_open` / `sys_win_fill` / `sys_win_present`, implemented 12 →
  15; a teardown follow-on adds slot 15 `sys_win_close` + the `dui close`
  command → 16) expose the G5 user-window surface to EL0: open a bounded
  kernel-owned window (id 2..3, fixed BSS back-buffer ≤ 256×192
  B8G8R8X8), fill rects in its back-buffer, and present it (mark dirty
  for the compositor) — no uaccess, no per-process ownership (the window
  persists after exit, the honest bound). WIN.BIN (a new
  `user/src/win.zig` program) proves EL0 graphics end to end: open → fill
  (dark-blue background + red/cyan/white blocks) → present → exit 87.
  **Live gate `tools/verify-live-win-syscall.sh` PASS 1/1**: the program's
  markers + `dui: windows=3 focused=2` / `dui[2]: user user
  rect=64,64,256,192` + `syscalls` implemented=16 (open=1/fill=4/
  present=1, slot 15 `sys_win_close` registered), and the decoded capture
  shows the window's own content over the terminal. **Teardown follow-on:**
  `dui close <n>` + `sys_win_close` (slot 15) release a user window so the
  id can be re-opened instead of leaking until reboot (open → close →
  re-open host-tested in `driving_award` + `syscall`, and proven LIVE by
  the seventh image WINCLOSE.BIN — the class-B gate
  `tools/verify-live-win-close.sh` shows the window gone (`windows=2`) and
  a re-exec re-opening id 2).
**Ownership follow-on:** windows are OWNED by the opening process and
  AUTO-CLOSE when it exits (`close_owner` from the scheduler's exit path —
  the real teardown semantic); fill/present/close are owner-restricted
  (host-tested cross-process refusals), WIN.BIN's window now vanishes on
  exit (`windows=2`, `sys_win_close calls=0`), and an eighth image
  WINLOOP.BIN keeps its window alive for the live gate's decoded-capture
  pixel proof. **Move/raise follow-on:** slots 16/17 (`sys_win_move`/
  `sys_win_raise`, implemented 16 → 18) reposition and restack the
  caller's window from EL0 — move clamps on-scanout, raise reorders the
  z-order, both owner-restricted; the monitor's `dui move <n> <x> <y>` is
  the EL1h half. A ninth image WINMOVE.BIN drives it live (open → fill →
  present → move → move-clamp → raise → yield-forever), and the class-B
  gate `tools/verify-live-win-move.sh` PASS 1/1 shows the clamped rect
  (`dui[2]: user user rect=1024,528,256,192`) + the counters (move=2/
  raise=1) + the decoded capture with the window's colors at the NEW
  position. **Read-back follow-on:** slot 18 (`sys_win_get`, implemented
  18 → 19) copies the caller's window rect (four u32 LE words) OUT through
  uaccess — the ONE pointer-taking win slot — so an EL0 program reads its
  clamped position back after `sys_win_move` (the move is silent);
  WINMOVE.BIN now prints `winmove: get 1024,528,256,192` (the gate's
  get=1 assertion). **Full-state query follow-on:** slot 19
  (`sys_win_query`, implemented 19 → 20) copies the caller's window FULL
  state (eight u32 LE words: x, y, w, h, z, focused, visible, dirty) OUT
  through uaccess — so an EL0 program introspects z-order rank + focus +
  visible/dirty, not just the rect; WINMOVE.BIN now prints
  `winmove: query 1024,528,256,192 z=2 focused=1 visible=1 dirty=1` (the
  gate's query=1 assertion). **Visibility follow-on:** slot 20
  (`sys_win_set_visible`, implemented 20 → 21) HIDES (`visible` 0) or
  SHOWS (`visible` 1) the caller's window from EL0
  (`driving_award.user_set_visible`, owner-restricted; the fixed terminal +
  clock are refused, a non-0/1 flag is EINVAL) — hiding marks the terminal
  dirty so the next composite repaints over the hidden window, showing
  marks the window dirty so it reappears; the back-buffer + z-order rank
  are untouched. WINMOVE.BIN now hides its window, sleeps 2 ticks, shows
  it again, and prints `winmove: hide ok` / `winmove: show ok`; the gate
  asserts hide=1/show=1/set_visible=2 + implemented=21 and gained a
  marker-driven capture (`--screenshot-after "winmove: hide ok"`, a new
  VMRunner flag) proving the PIXEL DISAPPEARS (no red/cyan/white blocks
  at the clamped spot while hidden) and RETURNS (the LATEST capture shows
  them back) — the hide/show round trip, not just a registry flip.
  Milestone six closed — G1–G6 all live; the default VM stayed
  byte-identical.

**Non-goals (for now):** the balloon device stays unattached; no
accelerated / 3D paths (virtio-gpu 2D blits only); no SMP; the window
manager is single-display (one 1280×720 scanout).
