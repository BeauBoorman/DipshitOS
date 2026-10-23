> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone twenty-seven march — desktop polish & completeness (living tracker)

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts. This file holds M27's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.
>
> **Renumbered 2026-08-26**: this tracker previously compressed M27 into
> six cards (G1–G6). It now uses the canonical issue numbering — GitHub
> issues #444–#473, cards G1–G30. The active claim 4402
> (`agent/buffy/m21-compositor`, old "G1–G7": splash, about, previews,
> sound, sysmon, tooltips) maps onto new G1, G3–G7 (#444, #446–#450);
> new-G2 (first-boot wizard, #445) was folded into old-G1 there and is
> unaffected. Six audit-shaped cards (G9, G11–G13, G22, G23) were
> rewritten on their issues the same day for single-file ownership —
> read the issue body before starting any of them.

## Where we are

The desktop is feature-complete: windowing, widgets, apps, networking,
audio, clipboard, timers, tiling, workspaces, notifications, and developer
tools. But it doesn't *feel* finished. No boot splash, no about dialog,
no window previews in alt-tab, no sound feedback, no system monitor, and
no tooltips. M27 is the "make it feel right" milestone — not new
capabilities, but polish that turns a collection of features into an OS.

**Zero new syscall slots.** All cards are pure compositor paint, app
development, or audio reuse.

## The cards

Issue bodies are the authoritative spec; this table holds owning file +
coordination state only.

| # | Card | Issue | Status | Notes |
|---:|------|-------|--------|-------|
| G1 | Boot splash screen | [#444](https://github.com/drawmeanelephant/DipshitOS/issues/444) | 🔄 claim 4402 | `kernel/src/main.zig`. |
| G2 | First-boot wizard | [#445](https://github.com/drawmeanelephant/DipshitOS/issues/445) | ⬜ | `user/src/settings_panel.zig`. |
| G3 | About dialog (Ctrl+Shift+A) | [#446](https://github.com/drawmeanelephant/DipshitOS/issues/446) | 🔄 claim 4402 | New `user/src/about.zig` + overlay. |
| G4 | Window previews in alt-tab | [#447](https://github.com/drawmeanelephant/DipshitOS/issues/447) | 🔄 claim 4402 | `driving_award.zig`, ~12 KiB BSS; mind the blit clamp lesson (claim 8777). |
| G5 | Sound design | [#448](https://github.com/drawmeanelephant/DipshitOS/issues/448) | 🔄 claim 4402 | `driving_award.zig` + `user/src/chime.zig`; gate asserts serial audio-play log. |
| G6 | System monitor dashboard | [#449](https://github.com/drawmeanelephant/DipshitOS/issues/449) | 🔄 claim 4402 | New `user/src/sysmon.zig`. |
| G7 | Tooltip system | [#450](https://github.com/drawmeanelephant/DipshitOS/issues/450) | 🔄 claim 4402 | `driving_award.zig` hover timer. |
| G8 | Consistent keyboard shortcuts | [#451](https://github.com/drawmeanelephant/DipshitOS/issues/451) | ⬜ blocked | Merge candidate with G29 — one canonical table (#472 displays it). Reconcile before claiming either. |
| G9 | Consistent menu structure | [#452](https://github.com/drawmeanelephant/DipshitOS/issues/452) | ⬜ rewritten | `ui.zig` ONLY (`menu_build()`); app adoption split out. |
| G10 | Consistent dialog style | [#453](https://github.com/drawmeanelephant/DipshitOS/issues/453) | ⬜ | `ui.zig` (`show_dialog()`). |
| G11 | Clipboard consistency everywhere | [#454](https://github.com/drawmeanelephant/DipshitOS/issues/454) | ⬜ rewritten | Phase 1 = read-only 4×4 matrix as issue comment (no claim); phase 2 = one PR per broken cell. |
| G12 | Drag/drop consistency | [#455](https://github.com/drawmeanelephant/DipshitOS/issues/455) | ⬜ rewritten | Cursor feedback during existing drags only; `driving_award.zig`. |
| G13 | Focus behavior polish | [#456](https://github.com/drawmeanelephant/DipshitOS/issues/456) | ⬜ rewritten | Focus-follows-mouse setting + dialog-close restore; `driving_award.zig` + `settings.zig`. |
| G14 | Button states | [#457](https://github.com/drawmeanelephant/DipshitOS/issues/457) | ⬜ | `ui.zig` widget state enum. |
| G15 | Confirmation dialogs for dangerous actions | [#458](https://github.com/drawmeanelephant/DipshitOS/issues/458) | ⬜ blocked | Overlaps M21 W13 (#429). Reconcile scope before claiming. |
| G16 | Settings persistence & reset | [#459](https://github.com/drawmeanelephant/DipshitOS/issues/459) | ⬜ | `kernel/src/settings.zig`. |
| G17 | Startup behavior | [#460](https://github.com/drawmeanelephant/DipshitOS/issues/460) | ⬜ blocked | Integration sequencing — waits on G1+G2, T14 (.virelairc), M21 W11 persistence. |
| G18 | Shutdown/restart polish | [#461](https://github.com/drawmeanelephant/DipshitOS/issues/461) | ⬜ blocked | `monitor.zig`; save hooks depend on W11's format — sequence after it merges. |
| G19 | Crash recovery for apps | [#462](https://github.com/drawmeanelephant/DipshitOS/issues/462) | ⬜ | `tombstone.zig` + orphan cleanup (pairs with M21 W14 #430). |
| G20 | Theme consistency | [#463](https://github.com/drawmeanelephant/DipshitOS/issues/463) | ⬜ | `settings.zig` owns theme_id; app reads are follow-ups. |
| G21 | Font consistency | [#464](https://github.com/drawmeanelephant/DipshitOS/issues/464) | ⬜ | `text.zig` + settings.font_size (M20 U1). |
| G22 | Polished empty states | [#465](https://github.com/drawmeanelephant/DipshitOS/issues/465) | ⬜ rewritten | `draw_empty_state()` in ui.zig + three named surfaces. |
| G23 | Polished error states | [#466](https://github.com/drawmeanelephant/DipshitOS/issues/466) | ⬜ rewritten | `format_error()` in ui.zig + two adoptions (FILE.BIN, EDIT.BIN). |
| G24 | Performance pass | [#467](https://github.com/drawmeanelephant/DipshitOS/issues/467) | ⬜ | Measure-first: baselines under `artifacts/` before optimizing. Levers: glyph cache (U13), dirty regions. |
| G25 | Memory leak audit | [#468](https://github.com/drawmeanelephant/DipshitOS/issues/468) | ⬜ | Cross-kernel audit; unit tests per leak check. |
| G26 | Keyboard-only navigation pass | [#469](https://github.com/drawmeanelephant/DipshitOS/issues/469) | ⬜ | `driving_award.zig` traversal + `ui.zig` widget keyboard handling; large scope, sequence late. |
| G27 | Screenshot capability | [#470](https://github.com/drawmeanelephant/DipshitOS/issues/470) | ⬜ recommended-first | `monitor.zig`, BMP to FAT. Pull early — upgrades evidence tooling for every other G gate. |
| G28 | Help system | [#471](https://github.com/drawmeanelephant/DipshitOS/issues/471) | ⬜ | `monitor.zig`; extends M8 U1 grouping. |
| G29 | Keyboard shortcut reference | [#472](https://github.com/drawmeanelephant/DipshitOS/issues/472) | ⬜ blocked | Display half of the G8 merge — wait for the canonical table decision. |
| G30 | Dogfood development session | [#473](https://github.com/drawmeanelephant/DipshitOS/issues/473) | ⬜ last | Meta-card, no code. Output: bug-list doc under `docs/`. Always final card of the milestone. |

## Suggested order

1. **G27 screenshots** first — every later class-B gate gets easier.
2. Buffy's open claim 4402 (G1, G3–G7), then G2.
3. Single-file helper cards: G10, G14, G9, G22, G23 (all `ui.zig` —
   strictly sequential between agents), plus G16, G12, G13, G5-adjacent
   kernel work as lanes free up.
4. Blocked/blocked-on-decision cards: G8+G29 merge, G15 vs W13, then
   integration cards G17/G18 once their dependencies land.
5. Audits and capstones: G11 matrix, G24, G25, G26.
6. **G30 dogfood** dead last; its output feeds the next milestone.

## Notes

1. **ABI budget:** Zero new syscall slots.
2. **BSS budget:** unchanged from prior estimate (~12.4 KiB dominant
   term is G4 preview buffers).
3. **Gate shapes:** per-card gates named in each issue body;
   convention stays `tools/verify-live-m27-<card>.sh`.
4. **Scope exclusions:** No accessibility beyond theme, no localization,
   no remote desktop, no tray extensions, no lock screen. Polish, not a
   platform rewrite.
