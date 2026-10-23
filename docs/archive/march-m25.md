> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone twenty-five march — file manager depth (living tracker)

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts. This file holds M25's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

FILE.BIN (M13 B3, M17 C7) is a file browser with inline preview and
breadcrumbs. It can open, create, delete, rename, and truncate files.
But it has no bulk operations, no file properties, no directory creation,
and no disk usage information. M25 turns the file browser into a file
*manager*.

**Zero new syscall slots.** All changes use existing file and window syscalls.

## The cards, in order

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| F1 | **Bulk operations.** Ctrl+click to select multiple files. Ctrl+A selects all. Selected files have a highlight. Batch delete: Del key deletes all selected files (confirmation dialog). Batch move: Ctrl+M moves selected files to a target directory (prompted). Progress indicator using the ProgressBar widget. | ✅ | `tools/verify-live-filemanager-bulk.sh` (claim 0434) | Selection bitmap (row-indexed; claim 4379's merged groundwork + the index fix), Ctrl+A/Del-dialog/Return walk live on VZ with one serial marker per batch unit (`file: del i/n NAME`) and slot-34 `calls=2` in the syscalls report. ProgressBar advances across frames via stepwise batch units (single-threaded loop: one unit per pass, no synchronous overdraw). |
| F2 | **File properties.** Right-click → "Properties" shows a panel with: file size (bytes), type (text/binary/directory), last modified timestamp (if available), full path. Displayed in the preview pane. | ✅ | `tools/verify-live-filemanager-props.sh` (claim 0434) | Ctrl+I / 'p' toggles the inspector live (`file: props on/off`); right-click context menu (ui.ContextMenu) drives the same actions, pinned by host unit tests — synthesized RIGHT clicks hit the claim-4769 activation wall, so the menu's live proof stays keyboard-mediated. Timestamps "N/A" per FAT32 short-name limitation. |
| F3 | **Create directory.** Ctrl+Shift+N prompts for a directory name and creates it. Uses existing `sys_file_create` (slot 25). The new directory appears immediately in the listing. Invalid characters rejected with an error message. | ✅ | `tools/verify-live-filemanager-mkdir.sh` (claim 2539) | Correction to the card text: there was NO directory-create seam (issue #383's premise was wrong) — kernel-side FAT32 `create_dir` landed (cluster alloc + zeroed cluster + `.` / `..` dot entries + ATTR_DIRECTORY parent slot) by extending slot 23's flag contract with `MODE_DIR`; EL0 seam is `ui.file_mkdir`. Live gate drives FSTEST.BIN headlessly: mkdir ok → dir lists empty → second mkdir refuses -9. Dot-entry bytes pinned by fat.zig host tests. The card's literal Ctrl+Shift+N chord walk is deferred: M21 W3's global Ctrl+N minimize intercept fires on the Shift combo too (focus steal); the one-line input.zig shift-guard is held by ACTIVE claim 8777. |
| F4 | **Disk usage.** `du` command from the shell shows per-directory size (recursive). FILE.BIN shows directory size in the breadcrumb bar (e.g., "DATA (128 KB)"). Non-blocking: scans the FAT allocation table for the target directory. | ✅ | `tools/verify-live-filemanager-du.sh` (claim 4379) | Kernel monitor `du` command (wiring `fat.dir_size_recursive`) + `FILE.BIN` breadcrumb total (`du=` marker) verified live on VZ (1/1 boot). |
| F5 | **Recent files.** "Recent" virtual directory showing the last 10 opened/created files. Shown as the first entry in the root listing. Click to navigate to that file. BSS ring of filenames. | ✅ | `tools/verify-live-filemanager-recent.sh` (claim 2539) | Ring persists to `/data/RECENT.SAV` (plain 8.3 — leading-dot names are not representable in FAT short names) via slots 23/25 on every open; loaded at startup. Virtual RECENT entry injected + PINNED at row 0 of the root listing; opens a read-only pseudo-listing of stored full paths (destructive verbs consumed as no-ops there). Dedup moves re-opened paths to front. |
| F6 | **Trash & restore.** Delete moves to `/data/.trash/` instead of permanent delete; restore command / verb moves back from trash. Bounded: 32 files in trash with auto-purge. | 🔶 | `user/src/file_browser.zig` (claim 4379) | `trash_selected`, `restore_trash` (`u`), bounded 32-entry staging, host unit-tested (79/79 suite). |
| F7 | **Batch rename.** `Ctrl+Shift+R` opens batch rename for selected files with prefix/pattern preview before execution. | 🔶 | `user/src/file_browser.zig` (claim 4379) | `batch_rename_prompt`, `perform_batch_rename`, `batch_rename_prefix`, host unit-tested. |
| F8 | **Split panes.** `Ctrl+\` toggles dual directory views; `Tab` switches active pane. | 🔶 | `user/src/file_browser.zig` (claim 4379) | `toggle_split_pane`, `switch_active_pane`, 50/50 split layout, host unit-tested. |
| F9 | **Favorites/bookmarks.** `Ctrl+D` bookmarks current directory; `Ctrl+B` shows bookmark list. Bounded: 16 bookmarks. | 🔶 | `user/src/file_browser.zig` (claim 4379) | `toggle_bookmarks`, `add_bookmark`, `jump_bookmark`, overlay UI, host unit-tested. |
| F10 | **File search.** Recursive / live filename search with real-time filter bar. | 🔶 | `user/src/file_browser.zig` (claim 4379) | `toggle_filter`, `apply_filter`, `find_substring_ci`, host unit-tested. |
| F11 | **Sorting options.** Cycle sort modes (Name, Size, Type) with ascending/descending toggle on header click. | ✅ | PR #512 (claim 5127) | `compare_entries`, column header click hit-test, host unit-tested. |
| F12 | **Hidden files toggle.** `Ctrl+H` toggles dotfile visibility. | 🔶 | PR #512 (claim 5127) | `toggle_hidden`, `is_hidden_file`, host unit-tested. |
| F13 | **File associations & open with.** Extension mapping (.BIN -> EXEC, .TXT -> NOTEPAD, .ZIG -> EDIT). | 🔶 | `user/src/file_browser.zig` (claim 4379) | `get_associated_app`, ContextMenu integration, host unit-tested. |
| F14 | **Terminal here.** Opens shell with working directory set to current file browser path. | 🔶 | `user/src/file_browser.zig` (claim 4379) | `terminal_here`, serial marker `file: terminal here`, host unit-tested. |
| F15 | **Editor here.** `Ctrl+E` opens editor in current directory or for selected file. | 🔶 | `user/src/file_browser.zig` (claim 4379) | `editor_here`, serial marker `file: editor here`, host unit-tested. |
| F16 | **Path copy.** `Ctrl+Shift+C` copies full path of selected file to clipboard. | 🔶 | PR #512 (claim 5127) | `copy_path`, sys_clipboard_set (slot 38), host unit-tested. |
| F17 | **Overwrite & conflict resolution.** Conflict check before directory create/move. | 🔶 | `user/src/file_browser.zig` (claim 4379) | `check_collision`, modal error message, host unit-tested. |
| F18 | **Transactional delete UX.** Confirmation dialog ("Delete selected files?") with progress bar. | 🔶 | `user/src/file_browser.zig` (claim 4379) | `delete_prompt`, `delete_dialog`, stepwise batching, host unit-tested. |

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Selection & bulk** | `user/src/file_browser.zig` for F1 (bulk ops), F2 (properties). | M17 C7 (file browser base). |
| **B — Directory & metadata** | `user/src/file_browser.zig` for F3 (create dir), F4 (disk usage), F5 (recent). `kernel/src/monitor.zig` for `du` builtin. | F1 (selection state must exist for bulk operations on new directories). |

## Notes

1. **ABI budget:** Zero new syscall slots. F3 extends slot 23's
   (`sys_file_open`) flag contract with `MODE_DIR` (0x10) instead of
   minting a slot; the EL0 convenience seam is `ui.file_mkdir`.
2. **Stack reality (observed, claim 0434/2539):** FILE.BIN's AppState is
   ~7.3 KiB of the EL0 task stack; the batch + deferred-listing chains
   overflowed the old 16 KiB budget (live guard-page status=139). EL0
   `task_stack_size` doubled to 32 KiB (scheduler.zig) — BSS cost ~80 KiB,
   inside the verify-bss-budget headroom. App-side discipline unchanged:
   post-op re-listings are deferred to event-loop depth
   (`pending_refresh`), never stacked under input handlers.
3. **Gate shape:** F1: `verify-live-filemanager-bulk.sh` — multi-select +
   delete. F2: `verify-live-filemanager-props.sh` — properties panel.
   F3: `verify-live-filemanager-mkdir.sh` — directory creation (headless
   FSTEST walk; see the card's W3-collision note for the chord walk).
   F4: `verify-live-filemanager-du.sh` — kernel monitor `du` command live on VZ.
   F5: `verify-live-filemanager-recent.sh` — persist + virtual entry.
   All gates assert serial MARKERS plus volume ground truth via the
   monitor (`mount data` + `ls`), never total entry counts — background
   writers (M21 W11 persistence) legitimately touch the DATA volume.
4. **File properties limitation:** FAT32 doesn't store modification timestamps
   in the short-name directory entry. The properties panel shows "N/A" for
   timestamps. If extended attributes (VFAT long names) are added later,
   timestamps can be extracted from there.
5. **Scope exclusions:** No archive/compression (tar, zip). No file
   permissions model. No file content search (use Ctrl+F in EDIT.BIN).
   No file size sorting (deferred to a future polish pass).

