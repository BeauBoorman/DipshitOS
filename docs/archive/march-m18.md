> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone eighteen march — terminal & shell depth (living tracker)

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts. This file holds M18's per-card detail and agent split, following
> the [`docs/march-arc2.md`](march-arc2.md) pattern.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

M17 desktop completeness and all Arc1–5 work are done. The desktop has a
full widget toolkit, 20+ apps, window management, context menus, workspaces,
notifications, clipboard, timers, compose sequences, and audio. The shell
(`shell.zig`) has a line editor, history (up/down), basic builtins, and
lives on the serial console.

M18 makes the terminal *comfortable* — the place you actually want to spend
time. Scrollback so you can see what happened, text selection so you can
copy things, command search so you can find past output, persistent history
so you don't lose commands on reboot, and colored output so you can tell
what's going on at a glance.

**No new kernel syscalls.** Every card is pure `shell.zig` or
`driving_award.zig` paint. The only kernel interaction is the existing
clipboard syscalls (slots 38/39) for T2.

## The cards, in order

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| T1 | **Scrollback.** Ring buffer in `shell.zig` that preserves the last 200 lines of terminal output. Shift+Up/Down or PageUp/PageDown scrolls the view. Visible cursor indicator showing current scroll position. | ✅ | claim 9867 — `verify-live-scrollback.sh` PASS on VZ | PR #480, commit `804fdc0`. |
| T2 | **Text selection & clipboard.** Click-drag to start a selection in the terminal. Shift+click extends the selection. Ctrl+C copies selected text to the M14 clipboard. Ctrl+V pastes clipboard contents at the prompt. Visual highlight (inverted colors) on the selected region. | ✅ | claim 7675 — `verify-live-selection.sh` PASS on VZ | PR #480, commit `22506ca`. |
| T3 | **Command search (reverse-i-search).** Ctrl+R opens a search bar at the bottom of the terminal. Type to search backward through the scrollback buffer and history. Enter accepts the match and puts it at the prompt. Esc cancels. First match highlighted. | ✅ | claim 8879 — `verify-live-search.sh` PASS on VZ | PR #480, commit `9532909`. |
| T4 | **Shell improvements.** Up/Down arrow cycles through command history (already works). Tab completion for built-in commands (`help`, `echo`, `exec`, `mem`, `tasks`, etc.). Persistent history: last 50 commands saved to FAT on every command entry, restored on boot. Ctrl+L clears the screen. | ✅ | claim 3679 — persistent history verified across reboot | PR #480, commit `f7ae9e3`. |
| T5 | **Terminal colors.** ANSI-style colored prompt: green for success (last command exit 0), red for error (non-zero). `ls`-style output: directories in bold, files in normal weight. `color` command toggles color on/off. Color state persisted in SETTINGS.TXT. | ✅ | claim 0163 — `verify-live-colors.sh` PASS on VZ | PR #480, commit `ff9a7c9`. |
| T6 | **Bracketed paste mode.** Terminal enters/exits bracketed paste mode to distinguish typed input from pasted content. | ✅ | commit `3e50339` | |
| T7–T11 | **ANSI/VT compatibility pass.** Basic ANSI escape sequence handling, cursor movement, screen clearing, alternate screen buffer, bell/visual bell, cursor shape & style. | ✅ | commit `0165d0a` | |
| T12–T15 | **Shell environment & configuration.** Environment variables, shell aliases, startup files (`.virelairc`), prompt customization (PS1). | ✅ | PR #481, commit `4265ea3` | |
| T16 | **Basic scripting mode.** `sh script.BIN` — reads a file of shell commands from FAT and executes them line-by-line. | 🔄 | — | In progress on `agent/buffy/m18-t16-scripting`. |

## Agent split

> **Constraint:** one editor per file at a time (AGENTS.md).
> T1–T4 all touch `shell.zig` — they should be done sequentially or by
> a single agent. T5 touches `shell.zig` + `driving_award.zig` and should
> follow T4.

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Shell core** | `shell.zig` for T1 (scrollback), T2 (selection), T3 (search), T4 (improvements). Sequential: T1 → T2 → T3 → T4. | None |
| **B — Colors** | `shell.zig` (color output) + `driving_award.zig` (color paint) + `settings.zig` (persist flag) for T5. | T4 (shell improvements land first) |

## Notes

1. **ABI budget:** Zero new syscall slots. T2 uses existing clipboard slots
   38/39. Everything else is pure userland.
2. **BSS budget:** T1 adds ~25.6 KiB for the scrollback ring. T2 adds
   ~200 bytes for selection state. T3 adds ~256 bytes for search state.
   Total M18 BSS delta: ~26 KiB.
3. **Gate shape:** Every card lands with a class-A host unit test AND a
   class-B `verify-live-*.sh` on VZ. T1's gate asserts scrollback lines
   survive after output exceeds one screen. T2's gate asserts copy/paste
   round-trip through the clipboard. T3's gate asserts search finds a
   known string. T4's gate asserts persistent history across reboot.
   T5's gate asserts color output in the serial log.
4. **Known limitation:** Text selection (T2) in the terminal is
   character-grid based (monospace 8×8). Selection across wrapped lines
   is deferred to M20 (font/rendering improvements).
5. **Scope exclusions:** No font size changes (M20). No Unicode rendering
   (M20). No new kernel syscalls. No filesystem path completion (M19).
