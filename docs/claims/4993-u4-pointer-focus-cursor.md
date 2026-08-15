# Claim: milestone eight, card U4 — pointer focus + cursor

- **Owner:** zcode (`agent/zcode/m8-u4-u5-windows`)
- **Prompt / plan:** user request 2026-08-14 — "lets do them" (U4+U5 as the
  one-owner pair the march-m8 agent split prescribes). Normative contract:
  ADR 0008 D4 (click = focus + raise; visible focus).
- **Scope:** the pointer reports (port 10, parsed since I2 but unconsumed)
  become input: `kernel/src/input.zig` exposes the latest pointer state +
  click edges; `kernel/src/driving_award.zig` consumes them in the idle
  drain — a click hit-tests the topmost window and focuses + raises it, and
  the compositor renders a cursor at the pointer position. The runner gains
  a pointer-synthesis seam (`--pointer` moves/clicks as synthesized
  NSEvent.mouseEvents into the VZVirtualMachineView — the I3 keyboard
  seam's analogue; VZ has no programmatic pointer API).
- **Depends on:** U0 (✅), U5's indicator work (claim 0935, same branch),
  I2/I3 input (✅).
- **Status:** ⛔ blocked at the LIVE seam (2026-08-14) — kernel + runner landed and host-tested; the live pointer proof is blocked (see Notes)

## Notes

The claim-time unknown (highest-risk card): whether a synthesized mouse
NSEvent dispatched to the VZ view produces a pointer REPORT the guest can
observe (the `input` command's ptr-x/y/buttons fields). The first probe
answers it; the hardware contract records the observation either way.

## Verified

- ✅ class A: the guest side is complete and host-tested —
  `driving_award.pointer_tick` (click = focus + raise via the existing
  hit-test; the magenta cursor follows mapped motion; the 0..32767 axis
  mapping), `input.zig` (pointer validity, the click edge, Alt+Tab), the
  shell wiring (the serial `win: pointer focus=` / `win: cycle focused=`
  evidence lines), the runner `--pointer`/`--pointer-after`/
  `--pointer-route` seam. All module tests + builds green.
- ⛔ class B: BLOCKED — five synthesized pointer delivery routes
  (direct view calls, window sendEvent, NSApp.postEvent, CGEventPost
  without Accessibility trust, a mouseEntered preamble) each dispatched
  with runner evidence and each produced `ptr-reports=0` in the guest
  (`artifacts/u45-probe*`; hardware contract). Unlike the keyboard
  seam, VZ's view does not translate synthesized mouse events.
  Follow-ups recorded: (a) observe a REAL mouse over a --display window
  (proves the guest stack live), (b) re-try the CG route with
  Accessibility granted to the terminal.
- ✅ `bash tools/verify-coordination.sh`
