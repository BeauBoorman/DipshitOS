# Log — milestone eight cards U4+U5: pointer focus/cursor + window HIG (zcode)

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-14** — **Claim (zcode, `agent/zcode/m8-u4-u5-windows`):** claimed
  the U4+U5 pair as one owner per the march-m8 split (both cards share the
  Driving Award compositor). Claims: `docs/claims/0935-u5-window-hig.md` +
  `docs/claims/4993-u4-pointer-focus-cursor.md`. U5 first (U4 depends on its
  indicator work). Chord decision recorded: HID Alt+Tab decode host-tested;
  the live gate cycles via `win cycle` over serial (the U2 synthesized-
  modifier limitation, already in the hardware contract). Branched from the
  U3 branch. 🔄 in progress — no code written yet.
- **2026-08-14** — **U5 done + U4 blocked (zcode,
  `agent/zcode/m8-u4-u5-windows`):** U5 (claim 0935) — the D4 chrome:
  the white 3-px focus ring on the focused window (focus()/cycle/raise
  now repaint), user-window title bars (name + owning pid) drawn in the
  compositor's chrome pass (EL0 back-buffers untouched), `win cycle` +
  the host-tested Alt+Tab HID decode for keyboard cycling. Gate
  `tools/verify-live-win-hig.sh` PASS 8/8 on VZ (scale-aware pixel
  proof; the capture arrived at 1x this session — the sampler detects
  it). U4 (claim 4993) — the guest side (click=focus+raise, the magenta
  cursor, the axis mapping, Alt+Tab) is host-tested and the runner
  pointer seam landed, but the LIVE proof is blocked: five synthesized
  delivery routes all produced ptr-reports=0 (hardware contract; the
  keyboard seam does translate — the asymmetry is recorded). En-route
  fix: a latent OOB write in text.zig's render (tiny-canvas host test)
  found via a bus error after BSS layout shifts — render is now
  canvas-bounded (pre-existing on main; worth an upstream note).
