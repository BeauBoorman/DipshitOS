# Claim: milestone eight, card U5 — window HIG (Driving Award chrome)

- **Owner:** zcode (`agent/zcode/m8-u4-u5-windows`)
- **Prompt / plan:** user request 2026-08-14 — "lets do them" (U4+U5 as the
  one-owner pair the march-m8 agent split prescribes). Normative contract:
  ADR 0008 D4.
- **Scope:** `kernel/src/driving_award.zig` — a focus ring/border treatment
  on the FOCUSED window (visible focus, D4's headline), title bars (name +
  owning pid) on USER windows, focus cycling (one chord + the `win cycle`
  monitor command), click = focus + raise already half-exists (`win hit`);
  host tests for the chrome rendering contracts. Pairs with U4 (claim 4993,
  same branch/owner).
- **Depends on:** U0 (✅), G5 Driving Award (✅), U1–U3 (✅ locally).
- **Status:** ✅ done (2026-08-14)

## Notes

ADR 0008 D4: focus is ALWAYS visible (a rendered title-bar/border treatment
marks the focused window); click = focus + raise (topmost hit-test); one
keyboard chord cycles focus; the terminal is window 0 and never closes;
user windows draw a title bar carrying a name and the owning pid.

Chord decision (claim-time): the HID path decodes Alt+Tab (modifier 0x04 +
usage 0x2b) into a cycle-focus signal — real keyboards work — but
synthesized modifiers never reach VZ's HID report (the U2 hardware-contract
observation), so the LIVE gate drives cycling via the `win cycle` monitor
command over serial; the chord decode is host-tested (the U2 chords
precedent).

## Verified

- ✅ class A: fmt pass; unit tests green (driving_award 62 incl. the
  chrome/cycle/cursor/click contracts; monitor 367 incl. `win cycle`;
  input 29 incl. Alt+Tab; shell 406; syscall binary 234); the transcript
  stays byte-identical; all builds.
- ✅ class B: `bash tools/verify-live-win-hig.sh` **PASS 8/8 on VZ** —
  the ring on the focused window (it follows WINLOOP's open-focus), the
  terminal edge not ringed, the title bar strip — decoded from the
  composited capture with scale-aware sampling.
- ✅ found + fixed en route: a latent out-of-bounds write in text.zig's
  render (the tiny-canvas host test scribbled past its buffer for its
  whole life; new BSS neighbors turned it into a bus error) — render is
  now canvas-bounded.
- ✅ `bash tools/verify-coordination.sh`
