> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone twenty-one march — window management depth (living tracker)

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts. This file holds M21's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

M17–Arc5 built a full floating window manager with drag, resize, snap zones,
context menus, alt-tab, workspaces, a system tray, and a dock. But every
window floats — there's no tiling, no master-detail layout, no minimize-to-
dock, and the notification toasts disappear forever. M21 makes the window
manager feel *intentional*.

**Zero new syscall slots.** Every card is pure compositor geometry or paint.

## The cards, in order

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| W1 | **Tiling mode.** Ctrl+T toggles the focused window between floating and tiled. Tiled windows split the screen: master-stack model (left half / right half). Max 2 tiled windows per workspace. Third window reverts to floating. | ✅ **live 2026-08-26 (claim 1306)** | `bash tools/verify-live-m21-tile-master.sh` run A — PASS | Geometry math + layout in `driving_award.zig` (`toggle_tiling`, `apply_tile_layout`, tile state BSS). The gate drives it through the EL1h `dui tile <n>` half. Registry-asserted AND pixel-asserted: master-left rect=24,0,837,700 / detail-right rect=861,0,419,700 (667:333 per mille of the 1256 px usable width), with each window's own colors decoded at its tiled origin. Tiled blit source clamp prevents OOB. |
| W2 | **Master-detail layout.** When two windows are tiled, the left is master (2/3 width) and the right is detail (1/3 width). Ctrl+M cycles which window is master. Dragging a tiled window detaches it (back to floating). | ✅ **live 2026-08-26 (claim 1306)** | `bash tools/verify-live-m21-tile-master.sh` run B — PASS | `swap_master` + `tile_master_side`. Gate run B: after `dui master`, side=right and BOTH rects move (A → detail-left 24,0,419,700; B → master-right 443,0,837,700), with B's cyan block observed at the NEW origin and gone from the old spot. |
| W3 | **Window minimize.** Ctrl+N minimizes the focused window to the dock (shows as icon). Click the dock icon to restore to previous position and size. Minimized windows don't paint and don't receive events. Alt+Tab skips minimized windows. | ✅ **live 2026-08-26 (claim 1306)** | `bash tools/verify-live-m21-minimize-ws.sh` — PASS | `minimize_window` and `restore_from_dock` in `driving_award.zig`. Gate asserts `minimized=1`, `visible=0`, and pre-minimize rect restore to `64,64,512,384` with pixel scanout verification. |
| W4 | **Workspace-aware alt-tab.** Alt+Tab only shows windows on the current workspace. Alt+` (backtick) cycles workspaces directly without the overlay. The overlay shows workspace name ("WS 0", "WS 1", "WS 2"). | ✅ **live 2026-08-26 (claim 1306)** | `bash tools/verify-live-m21-minimize-ws.sh` — PASS | `switch_workspace` and `cycle_workspace` in `driving_award.zig`. Gate asserts workspace switching (0 -> 1 -> 2 -> 0), workspace filtering, and overlay header rendering. |
| W5 | **Notification center.** Right edge pull-out panel showing the last 10 notifications. Click to dismiss one. "Clear all" button. Opens on the system tray clock click. Notification text stored in a BSS ring. | ✅ **live 2026-08-26 (claim 1306)** | `bash tools/verify-live-m21-notif-dialog-transient.sh` — PASS | `notify_push`, `notif_center_toggle`, `notif_center_dismiss`, `notif_center_clear_all` in `driving_award.zig`. Gate asserts toast pushes, panel opening, single dismiss, and clear all. |
| W6 | **Maximize / restore.** Maximize expands window to full workspace area (24,0,1256,700), saving pre-max rect. Toggle restores original bounds. | ✅ **live 2026-08-26 (claim 1306)** | `bash tools/verify-live-m21-max-fullscreen-aot.sh` — PASS | `toggle_maximize` in `driving_award.zig`. Gate asserts expansion to `24,0,1256,700` (`maximized=1`) and clean restoration to `64,64,512,384`. |
| W7 | **Fullscreen mode (F11).** F11 expands window to cover entire 1280x720 display, hiding dock and taskbar. Exit unhides dock/taskbar and restores geometry. | ✅ **live 2026-08-26 (claim 1306)** | `bash tools/verify-live-m21-max-fullscreen-aot.sh` — PASS | `toggle_fullscreen` in `driving_award.zig`. Gate asserts rect `0,0,1280,720`, taskbar/dock hiding, and exit restoration. |
| W8 | **Always-on-top (Ctrl+Shift+T).** Pinned windows stay atop normal user windows regardless of focus or raise order. Title bar draws pin glyph. | ✅ **live 2026-08-26 (claim 1306)** | `bash tools/verify-live-m21-max-fullscreen-aot.sh` — PASS | `toggle_always_on_top` in `driving_award.zig`, pin glyph `*` rendered in `draw_chrome()`. Gate asserts `aot=1` priority. |
| W9 | **Focus rings & visual focus indicator.** 2px accent ring on focused window; unfocused windows carry subtle border. Full-screen terminal excluded. | ✅ **live 2026-08-25 (claim 2621)** | Merged in `1a8dedf` | `focus_ring()` rendered in `draw_chrome()`. Excludes terminal and off-workspace windows. |
| W10 | **Keyboard window movement & resizing.** Alt+arrows move focused window by 16px (1px with shift). Alt+Ctrl+arrows resize window. | ✅ **live 2026-08-26 (claim 1306)** | `bash tools/verify-live-m21-max-fullscreen-aot.sh` — PASS | `move_window_keyboard` and `resize_window_keyboard` in `driving_award.zig`. Gate asserts movement from `(64,64)` to `(80,96)` and resize to `544x400`. |
| W11 | **Window persistence across sessions.** Window geometries and state serialize to `WINDOWS.SAV` on FAT ESP and restore on boot. | ✅ **live 2026-08-26 (claim 1306)** | `bash tools/verify-live-m21-persist-title-orphan.sh` — PASS | `serialize_state` and `restore_state` in `driving_award.zig`. 32-byte records per window persisted on ESP. |
| W12 | **Window title updates.** Syscall slot 61 (`sys_win_set_title`) and `dui title` dynamically update title buffer in registry, title bar, and alt-tab. | ✅ **live 2026-08-26 (claim 1306)** | `bash tools/verify-live-m21-persist-title-orphan.sh` — PASS | `set_window_title` in `driving_award.zig` and `sys_win_set_title` in `syscall.zig`. Gate asserts registry and title bar updates. |
| W13 | **Close confirmation dialog.** Intercept close on unsaved windows; centered modal dialog with Save / Don't Save / Cancel. | ✅ **live 2026-08-26 (claim 1306)** | `bash tools/verify-live-m21-notif-dialog-transient.sh` — PASS | `unsaved_dialog_show` and `unsaved_dialog_click` in `driving_award.zig`. Gate asserts modal dialog appearance and button resolution. |
| W14 | **Orphan window cleanup.** When process exits, all owned windows are reaped automatically via `close_owner(pid)`. | ✅ **live 2026-08-26 (claim 1306)** | `bash tools/verify-live-m21-persist-title-orphan.sh` — PASS | `close_owner(pid)` called on process exit/reap in `scheduler.zig:1006`. Gate asserts cleanup on user-el0 process exit. |
| W15 | **Modal windows.** Modal flag captures input, blocking clicks to underlying parent windows, with dimmed overlay. | ✅ **live 2026-08-26 (claim 1306)** | `bash tools/verify-live-m21-notif-dialog-transient.sh` — PASS | `set_modal` in `driving_award.zig`. Gate asserts `modal=1` flag and input isolation. |
| W16 | **Transient window behavior.** Transient windows auto-dismiss after configured timeout ticks or click outside. | ✅ **live 2026-08-26 (claim 1306)** | `bash tools/verify-live-m21-notif-dialog-transient.sh` — PASS | `set_transient` and `transient_advance_tick` in `driving_award.zig`. Gate asserts `transient=1` flag and timeout handling. |

## Notes

1. **ABI budget:** Zero new syscall slots outside the already-landed slot 61 for `sys_win_set_title`. All compositor geometry and paint.
2. **BSS budget:** Pure in-memory compositor structures.
3. **Live Gate Suite (5 Gates):**
   - `tools/verify-live-m21-tile-master.sh`: W1 + W2
   - `tools/verify-live-m21-minimize-ws.sh`: W3 + W4
   - `tools/verify-live-m21-max-fullscreen-aot.sh`: W6 + W7 + W8 + W10
   - `tools/verify-live-m21-notif-dialog-transient.sh`: W5 + W13 + W15 + W16
   - `tools/verify-live-m21-persist-title-orphan.sh`: W11 + W12 + W14
