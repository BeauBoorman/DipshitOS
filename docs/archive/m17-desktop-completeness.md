> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone fifteen march — desktop completeness & UX depth (living tracker)

> **PROPOSAL — needs ack.** This file drafts the next milestone after
> M14 close, in the style of [`docs/march-m14.md`](march-m14.md). M14's
> cards (S1–S4 — clipboard / timers / composition capstone / hardening)
> are expected to close before any M15 card starts. Edits to the
> canonical milestone list flow through [`docs/status.md`](../status.md);
> this file holds only M15's per-card detail and best-agent split.

## Scope: what M15 is and is not

**M15 is "depth into the static window model."** Every M15 card is
either pure `user/src/lib/ui.zig` widget work, a compositor-layer
addition in `driving_award.zig`, an app-upgrade in
`user/src/<app>.zig`, or a one-line manifest row. **No new kernel
syscalls**, no new event kinds, no new uaccess paths. Where the issue
text proposes new ABI slots, M15 defers them — they belong to a later
M16 / M17 milestone.

This is the "attainable" slice of issues #223–#247, picked out by
looking for cards that:

1. Don't depend on M14 S1 clipboard or M14 S2 timers being live.
2. Don't add `sys_*` slots beyond what ADR 0007 ships after M14 S1/S2
   (`implemented_count = 42`).
3. Don't add event kinds beyond what M9 landed (`kernel/src/events.zig`).
4. Don't touch the fault dispatcher, scheduler tick counter, or
   address-space layout.

The remaining issues — `#224 drag-to-resize`, `#236 mouse wheel`,
`#237 drag-and-drop`, `#238 z-order`, `#239 animations`, `#240
notifications`, `#241 workspaces`, `#242 unsaved-state`, `#243
tombstones`, `#244 graceful shutdown`, `#245 compose`, `#246 resource
limits`, `#247 settings migration` — all live behind ABI amendments,
M14 dependencies, or wishlist items that won't fit a "depth-of-existing"
milestone.

## The cards, in order

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| C1 | **DropDown widget.** Pure `ui.zig` widget: button + floating overlay; click-outside dismisses; first consumer is the SETTINGS.BIN theme selector. Discipline questions per-issue #223: topmost-z layering rule across menus / notifications / dialogs, keyboard nav (Up/Down/Enter/Esc) on the open list, scroll story for long option lists. | ✅ | PR #250 `4d81bb7` — `ui.zig:996` DropDown + `settings_panel.zig:124` theme `["dark","light","amber"]`, 3 host tests PASS, BSS `9.78/11.0` MiB | Arc 1 — Widget Toolkit Depth. Issue #223. |
| C2 | **Alt+Tab cycling UI.** Pure visual layer over the M8 U4 decode (claim 4993 — focus-rotate already lands, hidden). Hold-Alt+Tab shows centered overlay of window previews, Tab / Shift+Tab cycles, release-Alt raises. Discipline questions per-issue #225: right-click (#228) dismissal semantics, per-workspace visibility for future #241 integration. | ✅ | claim 2873 — `driving_award.zig:168` overlay BSS + `input.zig:86` Alt+Shift latch + `shell.zig:191` hold-Alt commit, host tests `driving_award` 125/125 PASS, BSS `9787576/11534336` | Arc 2 — Window Management. Issue #225. Deps: existing Alt+Tab decode (✅ landed). |
| C3 | **Window snap zones.** Pure compositor geometry: drag near edges snaps to halves / quadrants. Restore-original-size on drag-out. Discipline questions per-issue #227: snap-vs-resize precedence (no #224 in this milestone, so this card is unblocked), six-zone overlap precedence `last_drag_zone`, per-window `last_user_rect` BSS field. | ✅ | claim 2762 — `driving_award.zig:178` snap BSS + `snap_window`/`snap_restore` + `pointer_tick` preview/snap-on-release, host tests `snap_zone`/`snap_window`/`preview` PASS, BSS `9787576/11534336` | Arc 2 — Window Management. Issue #227. Deps: drag-to-move (✅ landed). |
| C4 | **Desktop quick-launch dock.** `Kind.dock` (id 253) layer, 24 px wide, topmost-layer in MC. Click launches via existing `sys_exec` slot 28 (claim 6359) or raises the existing window. Discipline questions per-issue #229: dock-as-row-of-APPS.TXT (`dock=true` flag — extension to M13 B2 manifest, see notes 4–5), workspaces-visibility contract locked for #241, hit-test vs right-click wallpaper at `x >= 24`. | ✅ | claim 9697 — `driving_award.zig:107` `Kind.dock` + `dock_*` BSS + `arm` dock window id 253 + `paint` dock bar + `pointer_tick` dock launch/raise + `image/apps.txt` `dock=true` + `desktop.zig:27` manifest `dock` parse, host tests `arm`/`hit_test`/`user_open` update, BSS `9788k/11534k` | Arc 2 — Window Management. Issue #229. Deps: APPS.TXT manifest (✅ M13 B2, claim 8877), `sys_exec` (✅ slot 28). |
| C5 | **NOTEPAD multi-line + word wrap.** Pure ui.zig + bounded buffer. Soft-wrap at last space; left gutter line numbers; Up/Down/Page-Up/Page-Down; status `Line X of Y`. Discipline questions per-issue #230: buffer growth on text-exceeds-window boundary, CR/LF preservation against soft-wrap loss, match-highlight contract with C6. | ✅ | claim 5227 — `notepad.zig` soft-wrap (`last_space`, `position_at`/`row_bounds`/`total_rows`), gutter, `Line X of Y`, host tests `soft-wrap` PASS | Arc 3 — App Upgrades. Issue #230. Deps: NOTEPAD BSS (✅ M11 A3, claim 3234), ui.zig toolkit (✅ M11 A1). |
| C6 | **NOTEPAD find/replace.** Pure ui.zig. Ctrl+F bottom bar, Enter = next match, Ctrl+H adds replace, Replace-All. Discipline questions per-issue #231: `editor.case_sensitive` toggle reserved in v1 schema (#247 — deferred, but C6 ships with a compile-time constant in this milestone), match-highlight contract with C5 (substring, not whole wrapped line), dirty-flag set on Replace via existing `@MEMORY_DIRTY` convention. | ✅ | claim 5227 — `notepad.zig` find bar (`find_active`/`find_buf`/`replace_buf`), `find_next`/`replace`/`replace_all` case-insensitive, highlight substring, `Ctrl+F`/`Ctrl+H`/`Enter`/`Esc`, host tests `find` PASS | Arc 3 — App Upgrades. Issue #231. Deps: C5 (must ship first or both ship in lockstep). |
| C7 | **FILE.BIN preview pane + path breadcrumbs.** Pure ui.zig. 60/40 split, left = existing list, right = first-20-lines preview, top breadcrumb bar. Discipline questions per-issue #232: printable-byte sniff for binary-TXT content, paned-window width given 512×384 user-buffer (a horizontal scroll seam may need a small widget — `HScroll` slice 16 rows tall, NOT issue #222 / ScrollView dependency), breadcrumb persistence (session-only in this milestone; v1 settings schema deferred to #247). | ✅ | claim 2336 — `file_browser.zig` inline preview (auto-load on select, `is_binary_content` sniff, `first 15 lines @30 cols`, `(binary)`/`(directory)` placeholders) + breadcrumbs (`breadcrumb_rect` muted, `format`/`hit_test`/`truncate`, `current_path`, `enter_directory`/`navigate_to_segment`), host tests 25/25 PASS, `verify-bss-budget` PASS | Arc 3 — App Upgrades. Issue #232. Deps: FILE.BIN (✅ M13 B3, claim 4742). |
| C8 | **TOP.BIN sortable columns + filter.** Pure ui.zig. Column-header click sorts (toggle ↑/↓), text input filters by name, refresh at 1 Hz floor (not per-tick). Discipline questions per-issue #233: stable-sort algorithm documented (PID / Name / Memory axes — pick one), state-loss-on-shutdown is acceptable. | ✅ | claim 0265 — `top.zig` sortable PID/Name/State/Exit (stable insertion, ↑/↓ accent) + TextInput filter case-insensitive + sort+filter + timer preserve, host tests 23/23 PASS, `verify-bss-budget` PASS | Arc 3 — App Upgrades. Issue #233. Deps: TOP.BIN (✅ M11 A4, claim 0680), `sys_procs` (✅ slot 7). |
| C9 | **CALC.BIN keyboard + history.** Pure ui.zig. 0–9 / `+−×÷` / Enter / Backspace / Esc / `.` direct keyboard, last-10 scrollable history above display. Discipline questions per-issue #235: ASCII `/` is input, rendered formula is `÷` (U+00F7); operator precedence = BODMAS (calculator convention); bounded 10-row scrolling is inside CALC's `AppState`, NOT pulled from #218 ScrollView. | ✅ | claim 9091 — `calc.zig` history `10×32B` ring `60px` (`Up`/`Down` cycle, `6` visible, `^`/`v`) + keyboard `0-9` `+-*/%` `.` `Enter` `Backspace` `Esc` `m` MR, `display_rect 8,72`, buttons y+64, host tests `22/22` PASS, `verify-bss-budget` PASS | Arc 3 — App Upgrades. Issue #235. Deps: CALC.BIN (✅ M11 A2, claim 8401, + memory-and-repeat patch claim 7869). |
| C10 | **SETTINGS.BIN live preview.** Userland-only with one tiny EL1 hook: theme dropdown → `ui.set_theme()` + a `theme_set` monitor command (registry 39→40) that mutates `driving_award.theme_id`. NO new syscall. Reset reverts to in-memory `last_saved_theme`. Discipline questions per-issue #234: live-update-by-dropdown → monitor-command path (instead of syscall slot), C1 dependency for the DropDown widget itself. | ✅ | PR #250 `4d81bb7` — theme DropDown consumes `ui.set_theme()` local preview; EL1 `theme_set` monitor hook deferred (filed as follow-on, not blocking) | Arc 3 — App Upgrades. Issue #234. Deps: C1 (DropDown), SETTINGS schema (✅ M8 U8 / v0 in MEMORY_DIRTY), `dui`/`win` monitor (✅ M13 win→dui rename, claim 2223). |

## Best agent split

> **Constraint:** one editor per file at a time (AGENTS.md).
> Two agents may share a tree if they touch disjoint files; the
> kernel/uaccess/exception paths are off-limits this milestone because
> no card touches them. The split below keeps `user/src/lib/ui.zig`
> contention to a single owner until cards C1–C1o land and unlock.

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Widget depth** | `user/src/lib/ui.zig` additions for **C1 DropDown** + the toolkit-only seams **C3 snap-zone hit-test** consumes (e.g. `pointer_zone_hint`) + **C7 pane** widgets + **C9 history scroll**. | C1 first; C5/C6 are app-specific. |
| **B — Window-managed depth** | `kernel/src/driving_award.zig` + `user/src/desktop.zig` for **C2 Alt+Tab overlay**, **C4 dock**, and the **C10 EL1 `theme_set` monitor command** (single 3-line zig change to the existing registry). | C1 (C10 depends on DropDown). |
| **C — App-upgrade depth** | `user/src/notepad.zig`, `user/src/file_browser.zig`, `user/src/top.zig`, `user/src/calc.zig` for **C5–C9**. C5/C6 in lockstep to keep the find/wrap contract honest. | Toolkit ready (agent A). |

Agent A's `ui.zig` card lands before B's C2 inherits the DropDown layer
model and C10's `theme_set` monitor command. Agent B's C4 lands after
agent A's C1, because the dock may want a long-options view per
#226-style scroll. Agent C lands C5/C6 together (wrap + find), then
the rest independently.

## Notes

1. **Predicate.** Every M15 card assumes M14 S1 (clipboard) and M14 S2
   (timers) are landed. C9 / C10 specifically do not use them; M15
   only assumes M14 closed.
2. **No new kernel ABI.** A single ADR-0007 amendment is NOT in M15
   scope. Cards that need slots 47–54 (per #224, #237, #238, #240,
   #241, #242, #246) belong to a follow-on milestone whose tracker is
   not this file.
3. **No new event kinds.** M9 (claim 7670 + 7206 + 9228 + 1016) ships
   kinds 0–9 in `kernel/src/events.zig`. C2 reuses MOUSE_DOWN/UP
   (kinds 6/7) for the overlay hover; no new kinds.
4. **Manifest extension for C4.** M13 B2 ships `APPS.TXT` as
   `NAME.BIN | Display Name | icon-char`. C4 needs a `dock=true` flag
   on the same row. M15 amends the manifest under the existing
   amendment pattern — aligned to M13 B2 (claim 8877) and shipped in
   the same PR as C4.
5. **Setting schema.** C10 wants `last_saved_theme` and a "live preview
   on/off" toggle. M15 ships C10 with these baked into v0 of
   `SETTINGS.TXT` (the existing M8/U8 schema); #247's v0→v1 migration
   later promotes these to a versioned schema.
6. **Per-issue scope drift.** Each M15 card has its issue body cleared
   with the discipline questions above BEFORE claiming begins. The
   cross-issue collisions I flagged in the per-issue comments
   (kind-12 right-click vs scroll #228/#236, drag-payload preview #237,
   etc.) are NOT in this milestone — they belong to M16+.
7. **Gate shape.** Every M15 card lands with a class-A host unit test
   (per ADR 0011 D3's zero-heap widget discipline) AND a class-B
   `verify-live-<card>.sh` on VZ. The class-C real-mouse gate (claim
   9015) covers the drag-interaction cards (C3, C4, C7-cursor) where
   the VC synthesized-pointer seam (issue #4769 / claim 4769) cannot
   deliver.
8. **`hall of shame`.** Things the milestone EXCLUDES on purpose: any
   syscall ABI additions, fault dispatcher depth, scheduler tick
   counter (claim-side issue #246 dep), notifications FIFO (kernel-side
   issue #240 dep), pointer-route work (claim 4769 — open thread).
   These all live in successor milestones / M16+.

## Open questions for the user — resolved 2026-08-20

- C1 through C10 is a 10-card milestone. **Split?** → **Keep C1-C10 together** (user ack 2026-08-20).
- C5/C6 land in lockstep. → **Lockstep** (user ack 2026-08-20).
- C4 dock manifest amendment — is the `dock=true` flag on
  `APPS.TXT` lines the right shape, or do we want a separate
  `DOCK.TXT`? → **`dock=true` flag on APPS.TXT** (user ack 2026-08-20).

These choices, plus the issue-by-issue comment threads, were the open
inputs before any agent claimed M15 work — now locked.
