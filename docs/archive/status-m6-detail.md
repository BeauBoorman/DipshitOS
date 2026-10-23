# Milestone 6 — Six — graphics: Driving Award + Road Pops — archived detail

> **Archived from `docs/status.md` on 2026-08-21 (issue #262).**
> The canonical one-line summary now lives in `docs/status.md` Current position table.
> This file preserves the full narrative that was previously inline in `docs/status.md`
> so the live tracker can stay ~150–200 lines. See also [`docs/march-m6.md`](march-m6.md) and the claim files cited below.

## One-line summary (now in `docs/status.md`)

| Six — graphics: Driving Award + Road Pops | Virtio-gpu framebuffer, text rendering, Road Pops terminal, Driving Award WM, draw syscall | ✅ done 2026-08-13 (claim 0487, cards G1–G6) |

- **Close date:** 2026-08-13
- **Claim:** 0487
- **March tracker:** [`docs/march-m6.md`](march-m6.md)

## Full narrative as it appeared in `docs/status.md` (pre-compression)

The following is the verbatim Current position table row for M6, previously at `docs/status.md:40`.

```text
| Six — graphics: Driving Award + Road Pops | Boot to a **graphical interface**: a virtio-gpu framebuffer (G1), framebuffer text rendering (G2), the boot terminal re-targeted to the screen as **Road Pops** (G3), and the **Driving Award** window manager compositing multiple windows (G5), and a draw/window syscall seam for EL0 programs (G6). Keyboard/pointer input (the original G4) was split into **milestone seven** (USB XHCI + HID) | ✅ **done 2026-08-13 (cards G1–G6 live)** — card G1 (**claim 6053**, branch `agent/buffy/m6-gpu`) **LIVE 2026-08-12 — the FIRST NON-BLANK GUEST FRAMEBUFFER on VZ**: the runner's `--display`/`--screenshot` mode attaches `VZVirtioGraphicsDeviceConfiguration` (1280×720 scanout; OFF by default — the default VM byte-identical); `kernel/src/virtio_gpu.zig` discovers the modern virtio-pci gpu (**DID 0x1050 observed**, class 0x038000, dev 7; config layout common@+0x0000 / ISR@+0x1000 / notify@+0x4000 / devcfg@+0x8000 — claim-0013's decoded shape), negotiates **VER1-only** (device offers RING_PACKED\|RING_EVENT_IDX\|RING_INDIRECT_DESC\|VERSION_1), arms controlq (queue 0) + cursorq (queue 1), re-arms post-exit (**VZ RESETS the gpu at ExitBootServices — `pre-rearm st=00`, like blk/entropy, unlike net's `st=0f`**), and drives the spec 2D path GET_DISPLAY_INFO → CREATE_2D (B8G8R8X8) → ATTACH_BACKING (4K-aligned BSS framebuffer) → SET_SCANOUT → TRANSFER → FLUSH. **Claim-time findings** (hardware-contract + claim doc): virtio-gpu **1.2** wire shapes (the 24-byte `display_one`; the pre-1.2 20-byte shape wedged the device with DEVICE_NEEDS_RESET), the tail descriptor's `next` must be 0 (VZ walks it), command/framebuffer cache cleans are mandatory (MMU-on, not caches-off), and the scanout composites with **alpha** — an X/A byte of 0 renders fully transparent (the final black-screen fix; fills write X=0xff). `screen` / `screen fill <rrggbb>` / `screen peek` monitor commands (registry 34→35). New class-B gate `bash tools/verify-live-screen.sh` **PASS 1/1** — the transport report + guest-side fill bytes + the DECODED capture: 14400/14400 sampled pixels are the fill green (0x00ff00 → ~(117,251,76) through the color-managed pipeline; evidence `artifacts/live-screen-*`, `artifacts/gpu-screen-*s`). Full class A green; the **35-gate `verify-vz` aggregate re-ran green** (`artifacts/m6-gpu-vz-sweep.log`). **Card G2 (claim 3194, branch `agent/buffy/m6-text`) LIVE 2026-08-12 — the machine boots to WORDS on the screen**: `kernel/src/text.zig` (the public-domain 8x8 bitmap font — ASCII 0x20–0x7e, fixed BSS glyph table; putc/puts, cursor, line wrap, a bounded 128-line scrollback ring, `clear`; the pure renderer is host-tested against an injectable mock canvas — 21 tests incl. golden glyphs, wrap/scroll/clear, bounds, cursor, composition) paints the SAME banner + prompt the serial log carries over G1's framebuffer (fg 0x00ff00 on bg 0x101418) and pushes it through G1's transfer/flush unchanged (`text: boot banner presented`); `text` / `text put <string>` / `text clear` monitor commands (registry 35→36). New class-B gate `bash tools/verify-live-text.sh` **PASS 1/1** — the DECODED capture shows real glyphs: the banner region samples fg=0.255 (green family) over bg=0.745 (the dark 0x101418) — the screen is no longer monochrome — with the region below all background (evidence `artifacts/live-text-*`, `artifacts/gpu-screen-*s`); the live-pixel bound is "text visible with the expected color family" (color-managed + retina-scaled; byte-exact glyphs live in the class A mock — the G1 gate's precedent). Full class A green; the **36-gate `verify-vz` aggregate re-ran green 36/36** (`artifacts/m6-text-vz-sweep.log`). **Card G3 (claim 1574, branch `agent/buffy/m6-roadpops`) LIVE 2026-08-12 — ROAD POPS: the boot terminal is on the screen**: `kernel/src/road_pops.zig` is a TEE console — every byte still reaches serial FIRST (the shared seam; the transcript gates keep passing byte-identical) AND G2's text layer paints the same banner + prompt + every reply on the framebuffer, drained ONE full-frame present per output batch by the shell idle loop. The G2 one-shot boot paint is replaced by the tee rendering the shell's OWN banner (its first present emits the G2 `text: boot banner presented` evidence on serial). **Claim-time fix (claim-0015 redux, observed live):** a `road_pops.Target` struct literal with all-constant fields was folded into `.rodata`, whose `&fn` entries hold LINK-TIME absolute addresses — the tee's first write jumped to the link-time `rp_text_put_bytes` and faulted (`esr=0x02000000 elr=0x14260`); the Target is now built in RAM like `ensure_vtable` so every `&fn` resolves PC-relatively. `roadpops` monitor command (registry 36→37: armed/dirty/presents). New class-B gate `bash tools/verify-live-roadpops.sh` **PASS 1/1** — the DECODED capture shows the boot banner (fg=0.255) AND the LIVE SESSION glyphs below it (fg=0.124 — the echoed `echo ROADPOPS`/`uname` commands + replies rendered; the screen is a working terminal, not a one-shot splash), with the serial transcript still carrying the whole session (evidence `artifacts/live-roadpops-*`, `artifacts/gpu-screen-*s`). G1/G2 gates updated honestly for the Road Pops reality: the terminal's drain-presents render over the raw fill, so G1's pixel phase now asserts the non-blank terminal frame (the fill is proven guest-side — `fill=…ff00 transfer=ok flush=ok` + `peek p1=0xff`; its `cmds=` is now session-dynamic), and the `text` report's cur/lines are session-dynamic (its own output feeds the ring). Full class A green; the **37-gate `verify-vz` aggregate re-ran green 37/37** (`artifacts/m6-roadpops-vz-sweep.log`) — the default VM stayed byte-identical. **Card G5 (claim 1543) LIVE 2026-08-13 — Driving Award, the window manager**: `kernel/src/driving_award.zig` (bounded BSS registry, z-order, focus, hit-test, dirty-rect compositor) makes Road Pops window 0 and a 1 Hz clock overlay window 1; the I3 keyboard read source is gated on the terminal's focus. `win`/`win focus <n>`/`win raise <n>`/`win hit <x> <y>` (registry 39→40). New class-B gate `bash tools/verify-live-win.sh` **PASS 1/1** — the serial session (windows=2, hit-test focusing the clock then the terminal) + a KEYBOARD-typed `uname` landing in the focused terminal (`DipshitOS aarch64`), and the DECODED capture shows two overlapping windows with the right z-order (the clock's amber title bar + navy body over the terminal, the terminal's green glyphs beside it). Full class A green; the default VM stayed byte-identical. **Card G6 (claim 0487) LIVE 2026-08-13 — the draw/window syscall seam**: the ADR 0007 amendment slots 12/13/14 (`sys_win_open`/`sys_win_fill`/`sys_win_present`, implemented 12 → 15, then a teardown follow-on adds slot 15 `sys_win_close` + `dui close` → 16) expose the G5 window manager's user-window surface to EL0 — `sys_win_open` opens a bounded kernel-owned window (id 2..3, fixed BSS back-buffer ≤ 256×192 B8G8R8X8), `sys_win_fill` fills rects, `sys_win_present` marks it dirty for the compositor (no uaccess — plain numbers; the kernel owns the buffers; the window persists after the caller exits, the honest bound). WIN.BIN (`user/src/win.zig`, the first graphics user program, loaded by `exec`) drives it end to end: `win: open id=2` → `win: fill ok` (dark-blue background + red/cyan/white blocks) → `win: present ok` → `sys_exit(87)`. New class-B gate `bash tools/verify-live-win-syscall.sh` **PASS 1/1** — the observation phase on the SAME kernel state (`win: windows=3 focused=2` + `win[2]: user user rect=64,64,256,192` z=2; `syscalls` implemented=16 with open=1/fill=4/present=1 + slot 15 `sys_win_close` registered) and the DECODED capture shows the window's own content over the terminal (no terminal foreground showing through — z-order). Full class A green; the default VM stayed byte-identical (sys_win_open returns EINVAL when the manager is unarmed). **Teardown follow-on (this branch):** `dui close <n>` (monitor) + `sys_win_close` (slot 15) release a user window so the id (2..3) can be re-opened instead of leaking until reboot — both call `driving_award.user_close`; open → fill → present → close → re-open is host-tested in `driving_award` + `syscall`, and a SEVENTH image WINCLOSE.BIN proves it LIVE from EL0: the class-B gate `tools/verify-live-win-close.sh` **PASS 1/1** — WINCLOSE.BIN opens/fills/presents/CLOSES (slot 15) and exits 88, twice; `win` shows `windows=2` after the close (no `win[2]:` row) and the re-exec re-opens id 2 (the freed slot reused, never id 3). **Ownership follow-on (this branch):** windows are OWNED by the opening process and AUTO-CLOSE when it exits (the scheduler's `exit_current` calls `driving_award.close_owner(pid)` — the real teardown semantic); `sys_win_fill`/`present`/`close` are owner-restricted (host-tested cross-process refusals); an EIGHTH image WINLOOP.BIN keeps its window alive so the restructured `tools/verify-live-win-syscall.sh` still pixel-proves EL0 rendering (WIN.BIN's window now vanishes on exit — `windows=2`, `sys_win_close calls=0`). **Move/raise follow-on (this branch):** slots 16/17 (`sys_win_move`/`sys_win_raise`, implemented 16 → 18) reposition + restack the caller's window from EL0 (move clamps on-scanout, raise reorders the z-order, both owner-restricted); the monitor's `win move <n> <x> <y>` is the EL1h half; a NINTH image WINMOVE.BIN drives it live and `tools/verify-live-win-move.sh` **PASS 1/1** shows the clamped rect (`win[2]: user user rect=1024,528,256,192`) + the counters (move=2/raise=1) + the decoded capture with the window's colors at the NEW position. **Read-back follow-on (this branch):** slot 18 (`sys_win_get`, implemented 18 → 19) copies the caller's window rect (four u32 LE words) OUT through uaccess — the ONE pointer-taking win slot — so an EL0 program reads its clamped position back after `sys_win_move`; WINMOVE.BIN now prints `winmove: get 1024,528,256,192` (the gate's get=1 + implemented=19 assertions). **Full-state query follow-on (this branch):** slot 19 (`sys_win_query`, implemented 19 → 20) copies the caller's window FULL state (eight u32 LE words: x, y, w, h, z, focused, visible, dirty) OUT through uaccess — so an EL0 program introspects z-order rank + focus + visible/dirty, not just the rect; WINMOVE.BIN now prints `winmove: query 1024,528,256,192 z=2 focused=1 visible=1 dirty=1` (the gate's query=1 + implemented=20 assertions). **Visibility follow-on (this branch):** slot 20 (`sys_win_set_visible`, implemented 20 → 21) HIDES (`visible` 0) or SHOWS (`visible` 1) the caller's window from EL0 (`driving_award.user_set_visible`, owner-restricted; the fixed terminal + clock are refused, a non-0/1 flag is EINVAL) — hiding marks the terminal dirty so the next composite repaints over the hidden window, showing marks the window dirty so it reappears; the back-buffer + z-order rank are untouched. WINMOVE.BIN now hides its window, sleeps 2 ticks, shows it again, and prints `winmove: hide ok` / `winmove: show ok`; `tools/verify-live-win-move.sh` asserts hide=1/show=1/set_visible=2 + implemented=21 and gained a marker-driven capture (`--screenshot-after "winmove: hide ok"`, a new VMRunner flag) proving the PIXEL DISAPPEARS (no red/cyan/white blocks at the clamped spot while hidden) and RETURNS (the LATEST capture shows them back). Milestone six closed — G1–G6 all live. |
```

### Readable paragraph form

**Milestone:** Six — graphics: Driving Award + Road Pops

**What it proved / is:** Boot to a **graphical interface**: a virtio-gpu framebuffer (G1), framebuffer text rendering (G2), the boot terminal re-targeted to the screen as **Road Pops** (G3), and the **Driving Award** window manager compositing multiple windows (G5), and a draw/window syscall seam for EL0 programs (G6). Keyboard/pointer input (the original G4) was split into **milestone seven** (USB XHCI + HID)

**Status:** ✅ **done 2026-08-13 (cards G1–G6 live)** — card G1 (**claim 6053**, branch `agent/buffy/m6-gpu`) **LIVE 2026-08-12 — the FIRST NON-BLANK GUEST FRAMEBUFFER on VZ**: the runner's `--display`/`--screenshot` mode attaches `VZVirtioGraphicsDeviceConfiguration` (1280×720 scanout; OFF by default — the default VM byte-identical); `kernel/src/virtio_gpu.zig` discovers the modern virtio-pci gpu (**DID 0x1050 observed**, class 0x038000, dev 7; config layout common@+0x0000 / ISR@+0x1000 / notify@+0x4000 / devcfg@+0x8000 — claim-0013's decoded shape), negotiates **VER1-only** (device offers RING_PACKED\

### Archived `## What comes immediately afterward` entries for M6

The `## What comes immediately afterward` section in pre-compression `docs/status.md` (lines 357–580)
contained 1 numbered entries that detailed M6's cards.
The entries have been removed from the live tracker; their substance lives in the march file and claims.
For historical fidelity, the original bullets that referenced M6 are excerpted below (see git history `docs/status.md` @ `aa4f111` for full section):

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

Primary claim: **0487** (see `docs/claims/0487-*.md` if present).
Full gate inventory: [`docs/gate-inventory.md`](../gate-inventory.md)
Hardware contract: [`docs/hardware-contract.md`](../hardware-contract.md)

---
_Generated by compression of `docs/status.md` (issue #262, 2026-08-21). Do not edit the one-line summary in `docs/status.md` without updating this archive if the narrative is still relevant._