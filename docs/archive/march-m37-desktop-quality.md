> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone thirty-seven march — desktop quality pass (living tracker)

> [`docs/status.md`](../status.md) is the canonical milestone-level source. This
> file holds M37's per-card detail, order, and gate notes. A card's row flips
> to ✅ only with real observed evidence.
> Binding: **[desktop-quality scoping](desktop-quality-scoping.md)** (DRAFT,
> claim 8459) — split of umbrella issue **#821** (Phase 1: claim 7154).
> Proposed GitHub milestone: **24 — M37 Desktop quality pass**
> (created 2026-09-03: DQ1 #836, DQ2 #840, DQ3 #839, DQ4 #838, DQ5 #837).

## Where we are

M19 landed the Sexiburger mechanics + tab model; M32 moved WM policy to
`WND.BIN`; M34 gave us `/host/APPS.TXT`; M36 gave us the raster engine +
wallpaper. Phase 1 of #821 (claim 7154, `1d80f50`) put the `SexiburgerMenu`
overlay into `WND.BIN` with hardcoded sections. Four completions remain, and
the tab/visual/snap halves have pure-rule foundations in
`kernel/src/wnd_core.zig` with no WND.BIN callers yet.

## The cards, in order

> **DQ1 close-out → DQ2 render → DQ3 interact → DQ4 tokens → DQ5 preview.**

| DQ# | Card | Phase | Depends on | Status | Touches | Notes |
|----:|------|:------|------------|--------|---------|-------|
| DQ1 | **God Menu completion** (#836) — dynamic APPS.TXT, live active-app actions, real theme/exec, full win/tab entries | close-out | — | ✅ claim 5514 | `user/src/wnd.zig` god-menu fns, `user/src/lib/sexiburger.zig` | **DONE 2026-09-03: unit wnd 103/103 + sexiburger 86/86; new Class-B `verify-live-godmenu-summon.sh` PASS 2/2** (`apps=16`, open, `exec verb=calc` → CALC `id=2` ready, close); M19 gate 8/8 once, flaky after (issue #843, incl. baseline-tree stall). Runner `ctrl-space` token added (additive). Umbrella #821 §1. |
| DQ2 | **Tab-bar chrome render** (#840) — WM strip, truncation, active/hover/× | render | DQ1-stable | ✅ gate green 2026-09-03 (code claim 6562 PR #847; verified claim 6392) | `kernel/src/wnd_core.zig`, `kernel/src/driving_award.zig`, `kernel/src/syscall.zig`, WND policy bit, `user/src/tabhold.zig`, `tools/verify-live-tabstrip.sh` | Design: kernel-blits-WM-decided (tooltip precedent), kind bit only, no new slot. **Live PASS:** `verify-live-tabstrip.sh` rc=0 — `tab-attach child=3 parent=2`, `STRIP_OK` (dividers=11, underline=118, close_red=19). Card #840 ready to close. |
| DQ3 | **Tab mouse interaction** (#839) — click switch, × close, drag-detach | interact | DQ2 | ✅ gate green 2026-09-03 (code claim 8605 PR #854; isolation claim 6392) | `user/src/wnd.zig` only + `tools/verify-live-tabclick.sh` | Pure hit-test + press/drag state + pointer wiring; unit 105/105. **Live PASS:** `verify-live-tabclick.sh` 3/3 rc=0 — A click→`tab-activate id=3`, B ×→`tab-detach child=3` no drag, C drag→`tab-drag`+detach. Prior red root-caused: M21 W11 `WINDOWS.SAV` restore across shared-share boots (fixed by per-boot `gate_reset_share_state`). Card #839 ready to close. |
| DQ4 | **Design tokens & cohesion** (#838) — ui.zig metrics, borders/shadows, cursors, 6-app rollout | polish | DQ2 | ✅ gate green 2026-09-03 (tokens claim 877) | `user/src/lib/ui.zig` + per-app sites + `tools/verify-live-tokens.sh` | Token table (metrics/chrome/cursor/sync) + 11 pinning tests; Button/Label/TextInput resolve legacy COLOR_* live (dark identical); compositor shadow flag-gated (`settings shadow`, default off); NOTEPAD/CALC/EDIT/FILE/SYSMON/DEVCONS one commit each + SYSMON 512-fit + settled markers. **Live PASS:** `verify-live-tokens.sh` — 12/12 boots, 12/12 exact-hex tokens markers, 12/12 pixel groups (dark+light chrome, shadow bands). Regressions: sexiburger-actions PASS, tabclick 3/3 PASS, tabstrip PASS on re-run (one attach flake, #843 family). Card #838 ready to close. |
| DQ5 | **Snap guides** (#837) — drag preview outline, release commits | preview | DQ2 | ✅ gate green 2026-09-03 (claim #888) | `user/src/wnd.zig` WND drag path + `tools/verify-live-snap-guides.sh` | Preview-only outline in the WND drag path from `wnd_core.snap_zone_for_point`/`snap_zone_bounds` (20px, corners first); release commits through unchanged WMS5 `snap_window_to`. Styling: DQ4 `focus_w`+`theme_accent`. **Live PASS:** `verify-live-snap-guides.sh` 3/3 — A edge-hold `wnd: snap-preview zone=left x=0 y=0 w=640 h=700` + accent outline pixels, B release `wnd: snap` + `rect=64,138,512,`, C center-hold clean. Hard-won: snapshot-after-drag races the move's SET_WINDOW repaint — gate snapshots after `wnd: snap-settled` (8 tick-restores). Regressions: wnd5-geometry, sexiburger-actions, tabclick 3/3, bss budget green. Card #837 ready to close. |

### Dependency phases (why this order)

```text
DQ1 close-out ──────────────────────────────┐ free wnd.zig god-menu fns
DQ2 render ─────────────────────────────────┼─ strip + hit-test first
DQ3 interact (after DQ2) ───────────────────┘  click what is drawn
DQ4 tokens (after DQ2) ─────────────────────── look settled, then unify
DQ5 preview (after DQ2) ────────────────────── rect math settled, then outline
```

## Notes

1. **Out of scope:** new syscall slots by default (DQ2 chrome bits only if
   justified); kernel policy growth; full theme engine; touch/multi-mon.
2. **Zero-regression contract:** hardcoded Phase-1 menu keeps working until
   DQ1 replaces each section; unmigrated apps keep frozen slots; every card
   re-runs `verify-live-sexiburger-actions.sh` green.
3. **BSS watch:** god-menu registry + mascot pixels + per-app token growth —
   every card re-runs `verify-bss-budget.sh`.

_Created by claim 8459 (2026-09-03), splitting issue #821's umbrella into
gated cards. Per-card GitHub issues to be filed under milestone 24; bodies
in the scoping doc's card table + the five drafts below._
