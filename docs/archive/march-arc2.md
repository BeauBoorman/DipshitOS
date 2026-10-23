> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Arc2 march — window management depth (living tracker)

> [`docs/status.md`](../status.md) is the canonical source for milestone-level facts. This file holds Arc2's per-card detail and collision-free agent split, following the [`docs/march-m14.md`](march-m14.md) pattern.
> A card's row flips to ✅ only with real observed class-B or class-A proof (per card's gate shape), never code-complete alone.
> ADR 0013 (`docs/decisions/0013-post-m14-abi-amendment.md`) reserves slots 47–54 + kinds 10–17 for post-M14 cards — Arc2 consumes slot 47/kind 10 and kinds 11/13.

## Where we are

M17 desktop completeness (C1–C10) shipped 2026-08-21 (main ff19197 `m17 desktop completeness` + arc1 widget depth claims 0819/2418/0835/1872/6437). Arc1 was pure `user/src/lib/ui.zig` widget work with zero ABI. Arc2 is the **window-management** arc deferred past M17 (issues #224, #228, #226) — the compositor + widget layer that needs ABI slots/kinds. The default VM stays byte-identical without flags; every card keeps zero-heap / fixed-BSS discipline.

## The cards, in order

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---|------|--------|----------|-------|
| W1 | **Drag-to-resize (GH #224).** 6×6 bottom-right hit, `resize_id`/`resize_origin` like `drag_id`, clamp 128×64..512×384, chrome repaint, `sys_win_resize` slot 47 + `WIN_RESIZE` kind 10 (ADR 0013 D1/D2). | ✅ done 2026-08-21 — claim 3589 merged 44ca7d2 (`events kind 10` + `syscall slot 47→48`, 4 host tests, BSS 9788088/11534336 PASS) | `verify-unit-tests` 132/132 `driving_award`, `verify-bss-budget` PASS | Groomed 2026-08-20 Arc2 deferred. Owns `driving_award.zig` resize geometry + `syscall.zig:47` + `events.zig:10`. |

| W2 | **Right-click context menus (GH #228).** `MOUSE_RIGHT_DOWN` kind 11 + `MOUSE_RIGHT_UP` kind 13 (kind 12 is `MOUSE_SCROLL`), `ui.zig` ContextMenu widget (items, show(x,y), outside-dismiss, z-order above windows), NOTEPAD/FILE.BIN/TOP integration. | ✅ done 2026-08-21 — claim 1757 landed on `main` (`events 11/13` + `ui ContextMenu` 3 tests, `driving_award` right-button split, `verify-bss-budget` PASS 9788088/11534336, `zig test` ui 32/32) | `verify-bss-budget` PASS, `zig test` 32/32 `ui` 132/132 `driving_award` | Groomed 2026-08-20 Arc2 needs ABI. Owns `ui.zig` ContextMenu + `events.zig:11/13`. |
| W3 | **System tray (GH #226).** `Kind.taskbar` id 255 20px @ y=700 right 80px: HH:MM (tick), theme D/L/A, clipboard rect; migrates `Kind.clock` id 1 (no duplicate). Compositor-only, no ABI. | ✅ done 2026-08-21 — claim 1264 (commit 4521ff1) `driving_award.zig` tray `format_hhmm`/theme/clipboard in right 80px, `Kind.clock` migration (arm 4 windows), `drain`/`composite` tick without timer, host tests 140/140 + `verify-bss-budget` PASS 9788088/11534336 | `verify-unit-tests` 140/140 `driving_award`, `verify-bss-budget` PASS, `verify-coordination` PASS | Groomed 2026-08-20 Arc2 deferred, no ABI. Owns `driving_award.zig` tray. Depends on clipboard+theme live (✅). |

## Best agent split

> **Constraint:** one editor per file at a time (AGENTS.md). Two agents may share a tree if they touch disjoint files.

| Agent | Owns | Depends on | Branch |
|-------|------|------------|--------|
| **A — Resize** | `kernel/src/driving_award.zig` resize geometry + `kernel/src/syscall.zig` slot 47 + `kernel/src/events.zig` kind 10 | M17 done, ADR 0013 | `agent/buffy/arc2-resize` |
| **B — Context menus** | `user/src/lib/ui.zig` ContextMenu + `kernel/src/events.zig` kinds 11/13 + app wiring | M17 done, ADR 0013 | `agent/buffy/arc2-context-menu` |
| **C — Tray** | `kernel/src/driving_award.zig` tray (taskbar right 80px, clock/theme/clipboard) + `Kind.clock` deprecation | M17 done, clipboard/theme live | `agent/buffy/arc2-tray` |

**Contention note:** A and C both touch `driving_award.zig`, B and A both touch `events.zig`. The claim files reserve the ABI rows (slot 47, kinds 10/11/13) per ADR 0013 D1/D2 so no slot collision; the file contention is resolved by **branch isolation** — each lane branches from `main` and edits in its own branch, merging through the integration branch sequentially (AGENTS.md "One editor per file at a time" = per-branch, not per-repo). The tray card (C) is compositor-only and can land independently; the resize (A) and context-menu (B) ABI amendments are independent kinds/slots and can be developed in parallel, with the `events.zig` merges rebased in kind order 10→11→13.

## Notes

- Arc2 is **purely** window-management depth; no new pools, no SMP, no POSIX.
- Kind 12 `MOUSE_SCROLL` belongs to Arc4 #236 and is **not** in Arc2 — do not claim it here.
- All cards keep zero heap / fixed BSS (tray adds ~32 B BSS, resize adds no BSS, context menu adds widget BSS only).
- When Arc2 closes, file follow-on Arc4 (rich interactions: #236 wheel, #237 drag-drop, #238 lower-back, #239 animations, #240 notifications, #241 workspaces) — see groomed issues — and Arc5 (system polish).

## Next action

Each lane's agent claims its card, verifies `syscall.zig:78 implemented_count=47` and `events.zig:33 next free=10` at claim time (per groomed issue source-of-truth), implements with host tests + `verify-bss-budget` PASS, and lands via PR against `main`.
