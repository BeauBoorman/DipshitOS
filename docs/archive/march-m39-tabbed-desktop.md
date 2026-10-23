> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone thirty-nine march — the tabbed desktop & modular UI (living tracker)

> [`docs/status.md`](../status.md) is the canonical milestone-level source. This
> file holds M39's per-card detail, order, and gate notes. A card's row flips
> to ✅ only with real observed evidence.
> Umbrella issue: **#925** (M39: The Tabbed Desktop & Modular UI).
> GitHub milestone: **26 — M39 Tabbed Desktop & Modular UI**.

## Where we are

M37 established the desktop quality foundation (Sexiburger overlay, tab
strips, snap guides, and design tokens). M38 connected the freestanding
TrueType vector typography engine (Inter UI + Fira Code) with anti-aliased
surface alpha-blending across the system.

M39 transforms the desktop experience from a 1990s overlapping floating window
model into a modern, browser-like environment with full tabs, zero floating window
clutter, and maximized vertical real estate:
1. **Modular UI Toolkit**: The 4,994-line monolithic `user/src/lib/ui.zig` is
   decomposed into clean submodules under `user/src/lib/ui/` (`abi`, `theme`,
   `draw`, `widgets/`) behind a 100% backward-compatible facade.
2. **High-Fidelity Visual Primitives**: Anti-aliased rounded rectangles and
   smooth pill highlights bring modern macOS/Arc-level visual polish.
3. **Dedicated Tabbed Window Manager (`TABWM.BIN`)**: Built from scratch in
   `user/src/tabwm.zig` as an EL0 userland WM server over `sys_wmctl`. It
   preserves full vertical screen height with a unified Left Sidebar (Sexiburger
   at top, vertical tab stack with pill highlights, and clock/tray at bottom).
   All existing floating window gates stay intact and green because `WND.BIN`
   remains untouched.

## The cards, in order

> **UI1 modular ui.zig → UI2 pill primitives & tokens → TWM1 server & sidebar → TWM2 tab lifecycle → TWM3 desktop integration.**

| Card | Issue | Phase | Depends on | Status | Touches | Notes |
|:-----|:------|:------|:-----------|:-------|:--------|:------|
| **UI1** | [#926](https://github.com/drawmeanelephant/DipshitOS/issues/926) **Modularize `ui.zig` with Facade Pattern** | cleanup | — | ✅ done 2026-09-04 | `user/src/lib/ui.zig`, `user/src/lib/ui/*` | Split 5k-line `ui.zig` into `abi.zig`, `theme.zig`, `draw.zig`, `widgets.zig`. Root facade preserves all 321 public symbols. 94/94 tests pass, live typography gate PASS on VZ. |
| **UI2** | [#927](https://github.com/drawmeanelephant/DipshitOS/issues/927) **Anti-Aliased Rounded Rectangles & Sidebar Tokens** | visual | UI1 (#926) | ✅ done 2026-09-04 | `user/src/lib/ui/draw.zig`, `user/src/lib/ui/theme.zig`, `user/src/lib/ui.zig` | `fill_rounded_rect` / `fill_pill` with 4-way subpixel quarter-circle anti-aliasing. Sidebar tokens (`sidebar_w=180`, `tab_row_h=38`, active/hover pill colors). Sized typography helpers. 99/99 tests pass. |

| **TWM1** | [#928](https://github.com/drawmeanelephant/DipshitOS/issues/928) **`TABWM.BIN` Server Scaffold & Left Sidebar Renderer** | server | UI2 (#927) | ✅ done 2026-09-04 | `user/src/tabwm.zig`, `build.zig`, `kernel/src/monitor.zig`, `kernel/src/shell.zig` | New EL0 WM server in `user/src/tabwm.zig`. Registers via `sys_wmctl(1)`. Renders Left Sidebar: Sexiburger button at top, vertical tabs in middle, clock/tray at bottom. Shell `tabwm start`. |
| **TWM2** | [#929](https://github.com/drawmeanelephant/DipshitOS/issues/929) **Tab Navigation, Viewport Allocation & Shortcuts** | interaction | TWM1 (#928) | ✅ done 2026-09-04 | `user/src/tabwm.zig` | Apps mapped into tabs. Active app gets full viewport (`x=sidebar_w..1280, y=0..720`). Inactive apps hidden via `set_state`. Mouse click switches/closes tabs. Shortcuts: `Ctrl+Tab`, `Ctrl+W`, `Ctrl+1..9`, `Ctrl+Space`. |
| **TWM3** | [#930](https://github.com/drawmeanelephant/DipshitOS/issues/930) **App Viewport Presentation & Desktop Integration** | polish | TWM2 (#929) | ✅ done 2026-09-04 | `user/src/tabwm.zig`, `image/apps.txt`, `tools/verify-live-tabwm.sh` | Centering/fill for fixed & resizable apps. Smooth launch from Sexiburger. Dedicated Class-B headless VZ gate proving tabbed desktop lifecycle end-to-end (`verify-live-tabwm.sh` PASS). |

## Invariants & Design Principles

1. **Zero-Regression Contract**: The existing floating window manager (`WND.BIN`)
   is untouched. All 20+ legacy floating WM Class-B gates and tests remain 100%
   green.
2. **Backward Compatibility**: `user/src/lib/ui.zig` remains the single import
   point for all existing applications. No caller code changes required.
3. **Zero Heap Allocation**: All sidebar layouts, tab tracking, and drawing
   primitives operate strictly within static BSS and stack allocations.
4. **Vertical Real Estate Priority**: The entire desktop interface (Sexiburger,
   tabs, clock, indicators) lives in the Left Sidebar. The content area achieves
   unbroken, full vertical scanout height (720px) with zero taskbar or titlebar
   encroachment.

## M48 — browser-style tab depth, rail-native (umbrella #1120)

The 2026-09-10 decision is **final: keep the LEFT RAIL, no top strip**. M48 is
behavioural only. Six cards land in `user/src/tabwm.zig`, with the app-facing
navigation seam in `user/src/lib/tabapp.zig`; every card carries a class-A
host test, and the new class-B gate `tools/gate/specs/live-tabwm-bt.spec`
proves the additive markers on real VZ hardware.

| Card | Issue | What landed | Class-A test |
|:-----|:------|:------------|:-------------|
| **BT1** | [#1121](https://github.com/drawmeanelephant/DipshitOS/issues/1121) reopen/duplicate | the existing reopen LIFO (Ctrl+Shift+T) plus **duplicate** (Ctrl+Shift+D) which re-execs the WM-launched bin via the same `pending_launch_bin` handshake | `M48/BT1` |
| **BT2** | [#1122](https://github.com/drawmeanelephant/DipshitOS/issues/1122) reorder | `TabManager.move_tab` + pointer **drag-to-reorder** (press/release edge detection) and keyboard move (Ctrl+Shift+PgUp/PgDn, alongside Left/Right); the new order persists to `.tabs` | `M48/BT2` ×2 |
| **BT3** | [#1123](https://github.com/drawmeanelephant/DipshitOS/issues/1123) pinned/groups | `pinned` + `group` on `Tab`, stable pre-partitioning so pinned tabs are always first; `dock=true` seeds the pin and `group=NAME` the label from APPS.TXT | `M48/BT3` ×2 |
| **BT4** | [#1124](https://github.com/drawmeanelephant/DipshitOS/issues/1124) start surface | Ctrl+T and the `+ New tab` pill open a rail-native **START** apps grid (`tabwm: start-surface`) instead of the command palette; Ctrl+Space keeps the Sexiburger palette | `M48/BT4` |
| **BT5** | [#1125](https://github.com/drawmeanelephant/DipshitOS/issues/1125) per-tab history | a bounded (`hist_max=8`) per-tab navigation history: apps declare via `tabapp.declare_nav` (WM_RPC kind 9) and back/forward (Ctrl+Shift+[ / ]) step the cursor and queue the target, drained by `tabapp.poll_nav` (kind 10) | `M48/BT5` ×2 |
| **BT6** | [#1126](https://github.com/drawmeanelephant/DipshitOS/issues/1126) preview/badge/search | hover-preview dwell card, a frozen status badge (Ctrl+Shift+F), and a **tab search** overlay (Ctrl+Shift+A) with case-insensitive substring matching | `M48/BT6` |

**Observed evidence (2026-09-11, this worktree, branch `t3code/m48-tab-ux`).**
Class A: `zig build test` rc=0 and `tools/verify-unit-tests.sh` rc=0 —
`zig test user/src/tabwm.zig` **100/100 tests passed** (10 new M48 tests) and
`zig test user/src/lib/tabapp.zig` **35/35**; `just verify-portable` rc=0;
`zig fmt --check user/src/tabwm.zig user/src/lib/tabapp.zig` clean;
`bash tools/inventory-gates.sh --check` OK. Class B (live VZ): `live-tabwm`
PASS 1/1, `live-tabwm-fullscreen` PASS 2/2, and the NEW `live-tabwm-bt`
PASS 1/1 (one boot: CALC tab id=2; `tabwm: tab-pin 2 on`,
`tabwm: tab-freeze 2 on`, `tabwm: tab-search`, `tabwm: start-surface`,
`tabwm: new-tab`; no `[EXC]`). Logs under `artifacts/live-tabwm-bt-*` and
`artifacts/live-tabwm-{gate,report,serial}-*`.
