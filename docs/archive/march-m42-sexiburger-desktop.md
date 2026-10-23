> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone forty-two march — the Sexiburger desktop (living tracker)

> [`docs/status.md`](../status.md) is the canonical milestone-level source. This
> file holds M42's per-card detail, order, and gate notes. A card's row flips
> to ✅ only with real observed evidence.
> Umbrella issue: **#981** (M42: The Sexiburger Desktop).
> GitHub milestone: **29 — M42: The Sexiburger Desktop**.

## Where we are

M39 shipped the tabbed desktop scaffold (`TABWM.BIN`, left sidebar, tab
lifecycle, centered viewport presentation) with a hand-drawn mini mascot.
M42 makes the Sexiburger **the** desktop: the proper 🐙+🍔 emoji artwork
everywhere the mascot appears, every app working **full screen** in its tab
(opt-in, via a real app-notification seam and a small app library), and the
remaining fleet rollout + primary-manager completion tracked as cards.

Three promises, in the user's words:
1. "i'd like the sexiburger to be the proper emoji symbol" — the actual
   artwork (an octopus holding the six-layer burger; the canonical export is
   `assets/sexiburger.png` 534x534), not an approximation.
2. "get it nice enough to be the main manager with all the apps we've made
   working in it full screen" — TABWM primary, apps full-viewport.
3. "if we need to work on a library or something to make apps interface
   build easier i would like to make issues to do that and work through
   them" — `lib/tabapp.zig` is that library, tracked card by card.

## The cards, in order

> **SX1 emblem → SX2 full-screen seam → SX3 app library → SX4 fleet rollout → SX5 primary manager.**

| Card | Issue | Phase | Depends on | Status | Touches | Notes |
|:-----|:------|:------|:-----------|:-------|:--------|:------|
| **SX1** | [#982](https://github.com/drawmeanelephant/DipshitOS/issues/982) **Proper mascot emblem** | asset | — | ✅ done 2026-09-04 (claim #987) | `assets/sexiburger.png`, `user/src/lib/fixtures/qoi/mascot_{28x28,24x24,64x64}.qoi`, `user/src/lib/ui/draw.zig`, `user/src/lib/ui.zig`, `user/src/tabwm.zig`, `user/src/sexiburger.zig`, `user/src/wnd.zig` (fixture refresh), `tools/verify-unit-tests.sh` | The repo's old `assets/mascot.png` was UNRELATED art (a guillotine) — the attached emoji export is the canonical source, added as `assets/sexiburger.png`. Premultiplied-alpha Lanczos downscale to 28/24/64, encoded with `tools/png2qoi.py`. `ui.draw_image_buf` is the scanout-buffer source-over blit (the WM-server seam where `draw_image`'s window-backing path does not apply). TABWM's sidebar button blits the real raster (rect-drawn mini mascot kept as decode-failure fallback); God Menu header fixture refreshed; SEXIBURG.BIN renders 24x24 top-bar + 64x64 splash with the text column moved right of it. Unit: fixture decode pins + buffer-blit correctness/clipping + draw_sidebar raster smoke (tabwm 52/52, sexiburger 55/55, ui suite green). |
| **SX2** | [#983](https://github.com/drawmeanelephant/DipshitOS/issues/983) **Full-screen viewport seam** | kernel | — | ✅ done 2026-09-04 (claim #987) | `kernel/src/driving_award.zig`, `kernel/src/wnd_core.zig`, `user/src/lib/ui/abi.zig`, `user/src/lib/ui.zig`, `user/src/tabwm.zig` | The gap: `wm_apply_rect` (the WM's SET_WINDOW path) never told the app its canvas changed. Now it pushes `WIN_RESIZE` (w,h payload, `user_resize` parity) to the owner when the clamped layout changes the size; pure moves and idempotent re-applies emit nothing. Additive `wm_rpc_kind_declare_fullscreen` (kind 8, wnd_core + toolkit mirror, drift-guard pinned in wmrpc.zig) — WND.BIN treats it as unknown and refuses (zero regression). TABWM: `Tab.tab_aware` + `applied_vp`; `compute_tab_viewport` gives tab-aware apps the full 1100x720; activation proposes SET_WINDOW only when the rect changed (no repeat WIN_RESIZE); the declare RPC applies immediately when active, defers when inactive. Kernel tests (driving_award 59/59) + tabwm tests (52/52). |
| **SX3** | [#984](https://github.com/drawmeanelephant/DipshitOS/issues/984) **`lib/tabapp.zig`** | library | SX2 | ✅ done 2026-09-04 (claim #987) | `user/src/lib/tabapp.zig`, `user/src/lib/ui/abi.zig` | `TabApp.init` (theme sync + win_open + best-effort declare), `dispatch` (WIN_CLOSE/WIN_RESIZE canvas tracking), `present`/`close_and_exit`, and `scale` (the fixed-layout mapping; identity at the native canvas = the zero-regression fixed point). Toolkit WM discovery resolves EITHER seat (`is_wm_name` — WND.BIN or TABWM.BIN; one seat exists, acks route by pid). Doc header shows the ~40-line app shape. tabapp 34/34. |
| **SX4** | [#985](https://github.com/drawmeanelephant/DipshitOS/issues/985) **Fleet rollout** | apps | SX3 | ✅ fleet landed (class A green; live gate open) | `user/src/notepad.zig`, `user/src/edit.zig`, `user/src/file_browser.zig`, `user/src/settings_panel.zig`, `user/src/sysmon.zig`, `user/src/top.zig`, `user/src/view.zig`, `user/src/devcons.zig` | **CALC ported end-to-end** (the exemplar): per-state `LayoutRects` + `canvas_w/h`; `layout()` maps the 7 area rects and all 54 native button rects proportionally (integer math, rounding top-left so grids never spill); draw AND hit-test helpers (`cfg_row_at`/`history_row_at` now take the state) read the same per-state rects so scaled geometry and scaled hit tests cannot drift; `gui_main` rides TabApp (declare → WIN_RESIZE → relayout → redraw). Native-size rendering is byte-identical (identity mapping pinned by tests). CALC 142/142. **Fleet (all eight) ported on the same pattern**: NOTEPAD (`relayout` — the `layout` name is the TextLayout viewport; scaled editor surface + toolbar), EDIT (14 native rects, edit/console panes grow, keyboard-only so no hit-test path), FILE (list/details/buttons/dialogs/progress scale; rows 18→33, preview cols 30→66 at 1100x720), SETTINGS (widget rects scale), SYSMON/TOP (content areas + graphs stretch; row caps storage-bound), VIEW (viewport-parameterized already — WIN_RESIZE recenters/scales), DEVCONS (prompt row 250→600, pane stretches). Each: `layout(rect)` from NATIVE consts via `tabapp.scale`, TabApp open/declare/dispatch in both event loops, identity + full-viewport + hit-test-agreement unit tests. Per-app host suites green (devcons 43, sysmon 44, top 60, settings 44, view 54, notepad 64, file 91, edit 120) + `zig build` + `zig build test` 126/126 (2269/2269). Open: the SX5 live gate launching ≥3 of these from the Sexiburger to prove full-viewport rendering on VZ. |
| **SX5** | [#986](https://github.com/drawmeanelephant/DipshitOS/issues/986) **Primary-manager completion** | manager | SX1–SX4 | 🔄 overlay + default seam + gate landed 2026-09-04 (claim #996); human-session default flip stays open | `user/src/tabwm.zig`, `kernel/src/shell.zig`, `tools/verify-live-tabwm-fullscreen.sh` | **The Sexiburger overlay**: Ctrl+Space or the sidebar button summons the command palette ON THE SCANOUT (dim + panel + the real 🐙🍔 emblem); the APPS.TXT catalog loads at server start; type-to-filter, arrows, Enter launches into a NEW TAB (sys_exec → the WM_WINDOW stream → the tab manager), Esc dismisses; TABWM.BIN filtered out. **The default seam**: `settings set wm tabwm` boots TABWM once per session from the shell idle — the DEFAULT VM stays shim-only (unit-tested: once-flag, silence without the key, non-tabwm refused). **`verify-live-tabwm-fullscreen.sh` PASS 2/2 on VZ**: boot A (settings-seeded autostart → CALC declares → full 1100x720 via the WIN_RESIZE seam → relayout), boot B (`tabwm start` → ctrl-space → typed filter "64-bit" → Enter launches CALC into a tab → full viewport). Open: flipping the documented human-session default after the fleet lands. |

## Live gate evidence (tranche 2, 2026-09-04, this worktree)

- `tools/verify-live-tabwm-fullscreen.sh` — **PASS 2/2** (the SX5 capstone):
  boot A proves the default-manager seam (settings-seeded autostart, the
  tab-aware declaration accepted, the full 1100x720 viewport applied
  through the kernel's WIN_RESIZE seam, CALC's relayout marker); boot B
  proves the overlay (ctrl-space summon, typed filter "64-bit", Enter
  launches CALC into a NEW TAB, same full-viewport chain). Gate-
  engineering lessons recorded: the runner's script stages must wait for
  the app's settle sleep (the relayout marker is the LAST link — earlier
  expects killed the VM mid-sleep); typed filters that name shell commands
  double-launch (use a label like "64-bit"); the share persists across a
  gate's boots (boot B resets SETTINGS.TXT).

## Live gate evidence (tranche 1, 2026-09-04, this worktree)

- `tools/verify-live-tabwm.sh` — **PASS 1/1** on the SX1+SX2 build: the
  full TABWM lifecycle (register slot 65, sidebar render, present cadence,
  WINLOOP window tracking, tab switch) with the emblem + viewport seam in
  the binary.
- `tools/verify-live-godmenu-summon.sh` — **PASS**: the God Menu (refreshed
  24x24 mascot fixture) summon/filter/exec/dismiss live on VZ.
- `tools/verify-live-sexiburger-actions.sh` — **PASS 2/2** after one
  #843-shaped attach flake (WM-side attach lines present, app-side ack
  missing once; re-runs green — the documented flake family).
- **Pre-existing failures observed on BASELINE main @2762e68 on this host**
  (identical signature on the stashed tree — NOT M42 regressions, honestly
  recorded): `verify-live-calc-depth.sh` (0/1; the first 13 chords of the
  sweep are silent in both trees — stats/date/cfg markers missing, rest
  green; the #843/#768 stall family), `verify-live-calc-prog.sh` (0/1;
  `prog-on` never observed, echo still responsive), and
  `verify-live-tabstrip.sh` (0/1). Follow-up belongs on #843/#768 triage.

## Asset pipeline (SX1)

```bash
# the canonical source
assets/sexiburger.png          # the 🐙+🍔 emoji export, 534x534 RGBA palette PNG
# regenerate the fixtures with a premultiplied-alpha Lanczos pass, then
python3 tools/png2qoi.py /tmp/scaled-<size>.png user/src/lib/fixtures/qoi/mascot_<size>x<size>.qoi
```

Premultiply → resize → unpremultiply (the straight-alpha Lanczos halo
killer); QOI is lossless so the embedded fixtures are pixel-exact to the
host-side scaling. Sizes: 28 (TABWM sidebar button), 24 (God Menu header),
64 (SEXIBURG.BIN splash).

## Invariants & design principles

1. **Zero-Regression**: WND.BIN untouched (the kind-8 RPC is refused by it);
   non-tab-aware apps keep the M39 TWM3 centered presentation; the default
   VM stays shim-only.
2. **Identity is the fixed point**: `tabapp.scale` at the native canvas
   maps every rect to itself — no resize means byte-identical rendering.
3. **Scaled draw == scaled hit tests**: apps read one per-state rect set
   for both (the CALC lesson).
4. **Zero heap** in the WM server render path and the library (BSS/stack
   only, the M39 rule).
5. **One event per real change**: the kernel answers a size-changing
   SET_WINDOW with exactly one WIN_RESIZE; TABWM never repeats a proposal.

## UX hardening (2026-09-05)

A four-fix user-friendliness tranche on the TABWM area (claim issue #1008;
ADR 0018 documents the ABI seam):

1. **Real tab-close semantics** (`user/src/tabwm.zig` + `kernel/src/`):
   `close_tab` now closes the window through the kernel's own release
   primitive via the new slot-65 `WMCTL_WIN_CLOSE` (cmd 13, WM-seat-only,
   ADR 0018 D2) — the kernel applies `user_close`, which pushes the REAL
   `WIN_CLOSE` event to the owning process (lib/tabapp.zig dispatches it
   to a clean exit) and fans the released mirror back (fix 2). An EL0
   process cannot write another process's event queue and the IPC
   mailbox is a separate FIFO no tabapp drains, so the WM-owned close
   MUST ride the kernel. A refused seam falls back to hide-only, marked
   honestly in the marker line (`tabwm: win-close id=N closed=0|1`).
2. **Released-window mirror** (`kernel/src/driving_award.zig` +
   `kernel/src/wm_server.zig`): `wm_window_hook`/`fan_window` gained an
   additive `released: bool` parameter, encoded as kind-20 flags **bit 13**
   (every existing bit unchanged; WND.BIN's decoder reads only bits
   8/9/10-11/12). `remove_user_at` — the shared release primitive behind
   `user_close` and the exit path's `close_owner` — fans ONE
   `visible=false, released=true` mirror from the already-copied
   `removed_win` state; the pre-removal fan in `user_close` is deleted, so
   every release path informs the WM exactly once. `user/src/wnd.zig` is
   untouched.
3. **Mirror-synced tab lifecycle** (`user/src/tabwm.zig`): the inline
   `wm_window_kind` handler in `main()` is extracted into the testable
   `handle_window_mirror` — released removes the tab (no WIN_CLOSE echo,
   no set_state of our own; the next tab activates if the removed one was
   active), plain hides are ignored (the tab list is ours), visible upserts
   geometry, and a 17th window is ignored instead of hijacking tab 0.
4. **Discoverability**: a "+ New tab" pill renders directly below the last
   tab (and in the empty state), clickable with hover, firing the new
   pinned `tabwm: new-tab` marker and summoning the Sexiburger launcher;
   Ctrl+T (HID 0x17) fires the same path. The pill is hit-tested BEFORE the
   generic tab-row mapping. The overlay now distinguishes "no apps
   installed" (empty manifest) from "no matching apps" (filter with no
   hits), and the sidebar empty state names both Ctrl+Space and '+'.

Class-A evidence: `zig build`, `zig build test`, and
`bash tools/verify-unit-tests.sh` all green (exit 0), including 8 new
tabwm "M42 UX" tests and the wm_server/driving_award released-mirror
tests (`artifacts/2026-09-05-tabwm-ux-hardening/`).

Class-B evidence (2026-09-05, this worktree): NEW gate
`tools/gate/specs/live-tabwm-close.spec` — **PASS 1/1** on VZ. One
headless boot: TABWM start → CALC.BIN (tab-aware full viewport) → an
injected pointer click on the active tab's close box →
`tabwm: win-close id=2 closed=1` (the KERNEL applied the close) →
`calc: win_close` + `calc: exiting 43` (the app received the real
WIN_CLOSE and exited) → `dui: windows=4` with no user-kind row (the
kernel registry released the window). Live regressions on the same
tree: `live-tabwm` PASS 1/1, `live-tabwm-fullscreen` PASS 2/2.

The default-manager flip (`settings set wm tabwm`) remains opt-in —
the documented human decision.

## UX hardening round 2 (2026-09-05)

A three-feature honesty tranche on the TABWM area (claim issue #1011;
ADR 0018 addendum documents the design). NO new kernel surface — the
slot-65 DIALOG (cmd 11) actions 3–6, the slot-65 ALT_TAB (cmd 5)
commit, and the kind-20 mirror's unsaved bit (flags bit 12) are all
reused; `wnd.zig`/`tabapp.zig`/kernel files untouched:

1. **Unsaved-state honesty** (`user/src/tabwm.zig`): TABWM decodes the
   kernel's unsaved bit into a per-tab dirty flag (both mirror upsert
   paths) and renders a 4x4 accent dot on dirty tab pills (active,
   hover, and inactive branches). EVERY close entry point — the
   close-'x' click, Ctrl+W, the detach RPC — routes through one
   decision function (`request_close_tab`): clean tabs close exactly as
   in round 1; dirty tabs open the unsaved-changes dialog (DIALOG
   action 3, target = the tab's window id) instead. The dialog is
   modal: clicks hit-test the shared `wnd_core.unsaved_dialog_choice_at`
   rects first and are consumed, Escape = cancel / Enter = save, other
   keys are swallowed, and the Sexiburger overlay refuses to summon
   over it. TABWM self-paints the dialog (its full-scanout compose
   overdraws the kernel's own blit) with the kernel's exact 200x100
   geometry + palette. The save/discard paths are deliberately
   asymmetric (ADR 0018 addendum): save closes the tab via
   WMCTL_WIN_CLOSE after DIALOG 4 (observed owner behavior: NOTEPAD
   treats WIN_UNSAVED as save-and-exit, so cmd 13 lands while the
   window is still registered and the WIN_CLOSE push goes unconsumed);
   discard relies on the kernel's `user_close` inside
   DIALOG 5 and lets the released mirror echo remove the tab.
2. **Close-feedback flash** (`user/src/tabwm.zig`): `close_tab` records
   the closed tab's ROW SLOT + an 18-composite-tick countdown;
   `draw_sidebar` overlays an accent band on that slot while live
   (muted when the kernel refused the close — the `closed=0` case).
   Pure helper `close_flash_active` is unit-tested without a
   framebuffer.
3. **Alt-Tab parity** (`user/src/tabwm.zig`): Alt+Tab / Alt+Shift+Tab
   (kind-21 raw chords, MOD_ALT + Tab) propose the target via the pure
   `alt_tab_next` policy helper — the SAME helper Ctrl+Tab /
   Ctrl+Shift+Tab now route through — and commit through the kernel's
   ALT_TAB seam (focus + raise; focus auto-show re-reveals the hidden
   target). Additive marker `tabwm: alt-tab id=N`.

Class-A evidence (2026-09-05, this worktree): `zig build` exit 0
(TABWM.BIN builds with the new wnd_core import);
`zig build test --summary all` exit 0;
`zig test --dep wnd_core -Mroot=user/src/tabwm.zig
-Mwnd_core=kernel/src/wnd_core.zig` exit 0 — **75/75 tests passed**
(11 new `M42 UX r2` tests: bit-12 mirror set/clear/release, dirty-close
dialog intercept, save/cancel/discard choice semantics incl. the
discard mirror echo, wnd_core button hit-test parity, alt_tab_next
policy, Alt+Tab chord handling, close_flash_active, dialog modal keys,
dialog modal pointer, overlay-summon modal guard, marker pins);
`bash tools/verify-unit-tests.sh` exit 0;
`zig fmt --check user/src/tabwm.zig` PASS. Full log:
`artifacts/2026-09-05-tabwm-unsaved-alttab/`.

Class-B evidence (2026-09-05, live VZ, this worktree): NEW gates
`tools/gate/specs/live-tabwm-unsaved.spec` — **PASS 2/2** (save boot +
discard boot: `dui unsaved 2 1` dirties NOTEPAD headless; the injected
close-box click is INTERCEPTED — `tabwm: unsaved-dialog id=2`, no
close; the Save click drives `tabwm: unsaved-save` → `notepad: saved
ok` → `tabwm: win-close id=2 closed=1` → `notepad: win_unsaved` →
`notepad: exiting 43` — observed save-path semantics: NOTEPAD treats
WIN_UNSAVED as save-and-exit, so the kernel's WIN_CLOSE push goes
unconsumed and `notepad: win_close` belongs to the discard path; the
Don't Save click drives `tabwm: unsaved-discard` → `notepad: win_close`
→ `notepad: exiting 43` with `dui: windows=4` (registry released) and
NO save marker) and `tools/gate/specs/live-tabwm-alttab.spec` —
**PASS 1/1** (one boot, CALC+NOTEPAD tabs, one real `alt-tab` chord →
`tabwm: alt-tab id=2`, kernel ` alt_tab=` counter moved, `dui:
windows=6 focused=2` — CALC holds kernel focus after the commit;
`notepad: open id=3` is asserted via the kernel's `open: id=3
owner=3` + TABWM's `tabwm: tab-switch idx=1 id=3` because NOTEPAD's
own open marker hardcodes id=2). Class A 75/75; logs:
`artifacts/2026-09-05-tabwm-unsaved-alttab/` + `artifacts/live-tabwm-{unsaved,alttab}-*`.

## M48 — browser-style tab depth (rail-native) continuation

The post-M42 browser-tab arc (goal #1064) landed as M48 (umbrella #1120),
still on the LEFT RAIL: reopen/duplicate, drag + keyboard reorder, pinned
tabs / APPS.TXT groups, a rail-native START surface on Ctrl+T (Ctrl+Space
keeps the Sexiburger palette), per-tab back/forward over app-declared
navigation, and hover preview / status badge / tab search. The full card
table and the observed class-A + class-B (VZ) evidence live in
`docs/march-m39-tabbed-desktop.md` § "M48 — browser-style tab depth,
rail-native"; the app-facing navigation seam is
`user/src/lib/tabapp.zig` (`declare_nav` / `poll_nav`).
