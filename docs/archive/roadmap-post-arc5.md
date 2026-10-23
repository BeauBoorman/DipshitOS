# VirelaiOS roadmap: the experience layer (M18–M27)

> **Status:** DRAFT — maintainer review needed.
>
> M0–M16 built the infrastructure: boot, kernel, processes, networking,
> graphics, input, a full desktop, a widget toolkit, 20+ apps, audio,
> clipboard, timers, and all the window management and interaction features
> through Arc5. What remains is the *experience layer* — making what exists
> genuinely good rather than merely complete.
>
> The prior roadmap (`docs/roadmap.md`) covers M0–M16 and the Arc1–5 cards.
> This file extends it with 10 forward milestones. Each milestone is a
> thematic arc with 4–6 cards; no card touches the kernel beyond what its
> milestone scope requires. Zero-heap / fixed-BSS discipline holds everywhere.
>
> **ABI budget:** 56/64 syscall slots used, event kinds 0–17 consumed. Eight
> slots remain (56–63). Every card below respects this budget — cards that
> need new slots name them explicitly; cards that can be pure userland are
> preferred.

---

## M18 — Terminal & shell depth

> Full card detail: [`docs/march-m18.md`](march-m18.md).

The shell is the most-used interface in VirelaiOS. This milestone makes it
actually comfortable to work in.

| Card | What | ABI? | Notes |
|------|------|------|-------|
| **T1 Scrollback.** Ring buffer in `shell.zig` that preserves the last 200 lines of output. Shift+Up/Down or PageUp/PageDown to scroll. Visible cursor indicator. | — | Pure `shell.zig` BSS ring. No new syscall. |
| **T2 Text selection & clipboard.** Click-drag to select text in the terminal. Shift+click to extend selection. Ctrl+C copies, Ctrl+V pastes. Visual highlight. | — | Reuses M14 clipboard syscalls (slots 38/39). Pure userland. |
| **T3 Command search.** Ctrl+R opens reverse-i-search on the scrollback buffer. Type to search, Enter to accept, Esc to cancel. | — | Pure `shell.zig` state + scrollback scan. |
| **T4 Shell improvements.** Up/Down history recall. Tab completion for built-in commands. Persistent history (last 50 commands survive reboot via FAT write). Clear screen (Ctrl+L). | — | `shell.zig` + FAT write for persistence. |
| **T5 Terminal colors.** ANSI-style colored prompt (user@host, green for success, red for error). `ls`-style output differentiation. `color` command to toggle on/off. | — | `shell.zig` + `drive_award.zig` paint. |

**Gate shape:** Class-B `verify-live-terminal-depth.sh` — scrollback, selection,
search, and persistent history observed through the VZ serial gate.

**Scope exclusions:** No font size changes (M20). No Unicode rendering (M20).
No new kernel syscalls.

---

## M19 — Shell as programming environment

> Full card detail: [`docs/march-m19.md`](march-m19.md).

The shell should be a *tool*, not just a command-line echo chamber.

| Card | What | ABI? | Notes |
|------|------|------|-------|
| **P1 Pipes.** `cmd1 | cmd2` — stdout of cmd1 feeds stdin of cmd2. Bounded: one pipe at a time, max 4 KiB buffer. `ls | grep FOO` works. | Slot 56 `sys_pipe_read` / slot 57 `sys_pipe_write` | New BSS pipe buffer in kernel. Two slots. |
| **P2 Redirection.** `cmd > file` writes stdout to a file. `cmd < file` reads stdin from a file. `cmd >> file` appends. Reuses existing file syscalls. | — | Pure `shell.zig` argument parsing + existing file table syscalls. |
| **P3 Environment variables.** `set VAR=val`, `$VAR` expansion. Bounded: 16 vars × 64 chars. Persisted to FAT. | — | `shell.zig` BSS array + FAT write. |
| **P4 Shell functions.** `fn name() { commands }` — user-defined multi-command sequences. Bounded: 8 functions × 4 commands each. | — | `shell.zig` BSS table. |
| **P5 Script mode.** `script.BIN` — a file of shell commands executed line-by-line. `sh script.BIN`. Bounded: 64 lines max. | — | Reads from FAT, feeds through `shell.zig` parser. |

**Gate shape:** Class-B `verify-live-shell-programming.sh` — pipe `echo | type`,
redirection to file + read-back, env var set/expand, function definition + call,
script execution.

**ABI impact:** 2 new slots for pipe (56/57). The pipe buffer is fixed BSS
(max 4 KiB). No heap.

---

## M20 — Text rendering & Unicode

> Full card detail: [`docs/march-m20.md`](march-m20.md).

The framebuffer text layer should handle more than ASCII.

| Card | What | ABI? | Notes |
|------|------|------|-------|
| **U1 Multiple font sizes.** 8×8 (current), 16×16, and 24×24 bitmap fonts. `font` command or `sys_font_size` syscall to switch per-window. | Slot 58 `sys_font_size(id, size)` | Kernel font tables in ROM/BSS. One slot. |
| **U2 Unicode glyph table.** Extend `text.zig` to render Latin-1 Supplement (U+0080–U+00FF) and Latin Extended-A (U+0100–U+017F). Compose sequences (ADR 0014) now actually display. | — | `text.zig` glyph lookup expansion. No ABI. |
| **U3 Text search in apps.** Ctrl+F in NOTEPAD searches the buffer and highlights matches (extend C6's find-bar with framebuffer highlight). FILE.BIN preview highlights filename matches. | — | Pure userland app changes. |
| **U4 Improved window chrome.** 2-pixel border, 16px title bar, close button hit area, drag-from-title-bar (extend current grab). Consistent across all apps. | — | `driving_award.zig` paint changes only. |
| **U5 Monospace rendering.** Proper tab-stop alignment (8-char tabs) in the terminal and text apps. Fix the current proportional-width artifacts. | — | `text.zig` tab handling. |

**Gate shape:** Class-B `verify-live-font-rendering.sh` — font size switch
observed, Unicode compose character rendered in NOTEPAD, tab alignment verified.

**Scope exclusions:** No anti-aliasing (bitmap fonts stay crisp). No
variable-width fonts (monospace only for now). No CJK/Latin/Beyond.

---

## M21 — Window management depth

> Full card detail: [`docs/march-m21.md`](march-m21.md).

The window manager should feel *intentional*, not just functional.

| Card | What | ABI? | Notes |
|------|------|------|-------|
| **W1 Tiling mode.** Ctrl+T toggles the focused window between floating and tiled. Tiled windows split the screen space (master-stack: left half / right split). | — | `driving_award.zig` geometry math only. |
| **W2 Master-detail layout.** When two windows are tiled, the left is master (2/3 width) and the right is detail (1/3). Ctrl+M cycles which is master. | — | Extension of W1 geometry. |
| **W3 Window minimize.** Ctrl+N minimizes to the dock (iconic). Click dock icon restores. Minimized windows don't paint. | — | `driving_award.zig` + `desktop.zig` dock integration. |
| **W4 Workspace-aware alt-tab.** Alt+Tab only shows windows on the current workspace (extend Arc2 C2). Alt+` cycles workspaces. | — | `driving_award.zig` + `input.zig` Alt+` binding. |
| **W5 Notification center.** Right edge pull-out showing last 10 notifications. Click to dismiss, "clear all" button. Extends Arc4's notification toast to a persistent panel. | — | `driving_award.zig` notification history BSS. |

**Gate shape:** Class-B `verify-live-window-depth.sh` — tiling layout
observed (two windows split), minimize/restore via dock, workspace-only alt-tab.

**Scope exclusions:** No drag-and-drop between tiled windows (already done
in Arc4). No multi-monitor (single display only).

---

## M22 — Developer tools

> Full card detail: [`docs/march-m22.md`](march-m22.md).

A "weird little computer" needs tools to build things *on* it.

| Card | What | ABI? | Notes |
|------|------|------|-------|
| **D1 ELF loader.** Load ELF32/ELF64 AArch64 executables from FAT. Parse program headers, map into EL0 address space. `exec app.elf` works alongside the flat-image `exec APP.BIN`. | Slot 59 `sys_elf_load(path)` | New kernel loader path. One slot. Pure BSS scratch for ELF header parse. |
| **D2 Tiny assembler.** `asm source.txt output.bin` — a minimal AArch64 assembler for ~20 common instructions (MOV, ADD, SUB, LDR, STR, BLR, RET, SVC, NOP, CMP, B, BEQ/BNE, etc.). Enough to write a test program from the shell. | — | Pure userland ELF app. Reads source from FAT, writes ELF to FAT. |
| **D3 Symbol table.** `sym` command shows loaded symbols. Tombstone crash reports (M15 #243) include symbol names. | — | `tombstone.zig` symbol lookup. BSS symbol table. |
| **D4 Disassembler.** `disas binary.bin` — hex dump + disassembly of raw bytes. Useful for debugging tombstones. | — | Pure userland app. |
| **D5 System call tracer.** `strace cmd` — wraps exec, logs every syscall invocation with args and return values. | Slot 60 `sys_strace_enable(pid)` | Kernel trace hook (one slot). BSS trace buffer. |

**Gate shape:** Class-B `verify-live-dev-tools.sh` — ELF load + execute,
assembler output run, tombstone shows symbol name, strace output observed.

**Scope exclusions:** No compiler (too large). No linker (flat images suffice
for now). No debugger (tombstones + strace cover the basics).

---

## M23 — The text editor

> Full card detail: [`docs/march-m23.md`](march-m23.md).

NOTEPAD exists. A *text editor* does not. This milestone builds one that
a developer could actually use for small files.

| Card | What | ABI? | Notes |
|------|------|------|-------|
| **E1 EDIT.BIN — the text editor.** Full-screen editor with line numbers, cursor movement (arrows, Home/End, PgUp/PgDn), insert/overwrite mode toggle (Insert key), status bar (line:col, file name, modified). | — | New userland app in `user/src/edit.zig`. Reuses ui.zig toolkit. |
| **E2 Undo/redo.** Bounded undo stack (last 50 operations). Ctrl+Z undo, Ctrl+Y redo. Each operation is a small BSS delta record. | — | `edit.zig` BSS undo ring. |
| **E3 Goto line.** Ctrl+G opens a prompt, Enter jumps to that line. Shows "Line X of Y" in status. | — | `edit.zig` state. |
| **E4 Multi-file tabs.** Ctrl+T opens a new file tab. Ctrl+W closes a tab. Ctrl+Tab switches. Bounded: 4 open files. | — | `edit.zig` tab BSS (4 × filename + dirty flag). |
| **E5 Syntax coloring (minimal).** Zig keywords highlighted in a different color. `.zig` files get basic syntax awareness. Other files are plain. | — | `edit.zig` keyword scanner. Comptime keyword table. |
| **E6 Console integration.** Ctrl+` splits the editor — bottom half shows the shell. Run commands without leaving the editor. | — | `edit.zig` + shell pipe to a window. |

**Gate shape:** Class-B `verify-live-editor.sh` — EDIT.BIN opens, cursor moves,
undo/redo round-trips, goto-line jumps, multi-file tabs open/close, syntax
highlighting observed for `.zig` file.

**Scope exclusions:** No syntax tree / LSP. No regex search. No split-screen
vertical (horizontal only). No collaborative editing. This is a *small* editor
for a *small* OS.

---

## M24 — CALC grows up

> Full card detail: [`docs/march-m24.md`](march-m24.md).

The calculator should actually be useful.

| Card | What | ABI? | Notes |
|------|------|------|-------|
| **K1 Programmer mode.** Hex/octal/decimal display. AND/OR/XOR/NOT/shift operators. Register view (R0–R7). | — | `calc.zig` mode state + operator dispatch. |
| **K2 Memory store.** MS/MR/M+/M- with 4 memory slots. Memory indicator in the display. | — | `calc.zig` BSS memory slots. |
| **K3 Unit conversion.** `temp`, `length`, `weight` categories. C/F/K, m/ft/in, kg/lb. Keyboard shortcut (Ctrl+U) opens conversion bar. | — | `calc.zig` conversion table (comptime). |
| **K4 Constant calculator.** Mathematical constants (π, e, √2, φ) available as buttons. | — | `calc.zig` comptime constants. |
| **K5 History persistence.** Last 20 calculations survive reboot (FAT write). `calc history` command shows them. | — | `calc.zig` + FAT write. |

**Gate shape:** Class-B `verify-live-calc-depth.sh` — programmer mode toggles,
hex display, memory store/recall, unit conversion, history persistence.

**Scope exclusions:** No graphing. No symbolic algebra. No equation solver.
This is a pocket calculator, not Mathematica.

---

## M25 — File manager depth

> Full card detail: [`docs/march-m25.md`](march-m25.md).

FILE.BIN is a file browser. This milestone makes it a file *manager*.

| Card | What | ABI? | Notes |
|------|------|------|-------|
| **F1 Bulk operations.** Select multiple files (Ctrl+click), batch delete, batch move to a target directory. Progress indicator (ProgressBar widget). | — | `file_browser.zig` selection state + batch loop. |
| **F2 File properties.** Right-click → Properties shows size, modified date, type. Info panel in the preview pane. | — | `file_browser.zig` metadata read + preview widget. |
| **F3 Create directory.** Ctrl+Shift+N creates a new directory. Prompts for name. | — | `file_browser.zig` + existing FAT create syscall. |
| **F4 Disk usage.** `du` command shows per-directory size. FILE.BIN preview shows directory size in the breadcrumb bar. | — | `file_browser.zig` recursive size scan. |
| **F5 Recent files.** "Recent" virtual directory showing last 10 opened/created files. BSS ring. | — | `file_browser.zig` recent ring + FAT read. |

**Gate shape:** Class-B `verify-live-filemanager.sh` — multi-select + delete,
properties panel, directory creation, du output, recent files list.

**Scope exclusions:** No archive/compression (tar, zip). No file permissions
model. No file content search (use EDIT.BIN or Ctrl+F).

---

## M26 — Network experience

> Full card detail: [`docs/march-m26.md`](march-m26.md).

The network stack exists (M5). This milestone makes it *visible* and *useful*.

| Card | What | ABI? | Notes |
|------|------|------|-------|
| **N1 PING.BIN.** `ping 10.0.0.1` — sends ICMP echo, displays round-trip time, packet loss stats, continuous mode. | — | New userland app. Reuses ICMP syscalls. |
| **N2 NETSTAT.BIN.** `netstat` — shows active TCP connections, UDP listeners, ARP table, DHCP state, IP/MAC/gateway info. | — | New userland app. Reuses existing `net` monitor commands as syscalls. |
| **N3 HTTP fetch display.** `fetch http://site/path` — displays response body in a scrollable terminal window. Extends FETCH.BIN with terminal output mode. | — | `fetch.zig` terminal output path. |
| **N4 Bandwidth display.** TOP.BIN network tab showing bytes sent/received, packets, errors. Updated at 1 Hz. | — | `top.zig` new tab + net stats query. |
| **N5 Connection manager.** `net connect` / `net disconnect` — manage TCP connections interactively from the shell. | — | `shell.zig` commands wrapping TCP syscalls. |

**Gate shape:** Class-B `verify-live-network-apps.sh` — ping round-trip observed,
netstat output, fetch HTTP response, TOP network tab, connection lifecycle.

**Scope exclusions:** No HTTPS (no TLS stack). No HTTP server. No WebSocket.
No network file system. This is diagnostics, not infrastructure.

---

## M27 — Desktop polish & completeness

> Full card detail: [`docs/march-m27.md`](march-m27.md).

The final milestone in this arc. Not new capabilities — making everything
*feel right*.

| Card | What | ABI? | Notes |
|------|------|------|-------|
| **G1 Boot experience.** Boot splash screen (VirelaiOS logo, version, loading indicator). First-boot wizard (language, theme, timezone). | — | `boot.zig` splash + `settings_panel.zig` wizard. |
| **G2 About dialog.** Ctrl+Shift+A shows a polished About window: OS name, version, kernel build date, credits, license. | — | `driving_award.zig` + new widget. |
| **G3 Window previews.** Alt+Tab shows a live mini-preview of each window (current: just icons). Renders each window's buffer scaled down. | — | `driving_award.zig` composite preview. |
| **G4 Sound design.** Audio feedback for common actions: notification ping, error beep, window open/close, copy/paste. Reuses M15 audio syscalls. | — | `driving_award.zig` + `chime.zig` + sys_audio. |
| **G5 System monitor dashboard.** `sysmon` — a full-screen dashboard showing CPU usage, memory, disk, network, running processes, uptime. Auto-refresh at 1 Hz. | — | New userland app. Reuses TOP/sysinfo/net syscalls. |
| **G6 Tooltip system.** Hover over UI elements for 1s shows a tooltip with description. Bounded: 32-char string per tooltip. | — | `driving_award.zig` tooltip timer + text. |

**Gate shape:** Class-B `verify-live-desktop-polish.sh` — boot splash observed,
about dialog opens, alt-tab shows previews, sound feedback, sysmon dashboard,
tooltip appears on hover.

**Scope exclusions:** No accessibility (screen reader, high contrast beyond
theme). No localization (English only). No remote desktop. This is polish,
not a platform rewrite.

---

## Dependency graph

```
M18 Terminal ──→ M19 Shell ──→ M22 Dev Tools
                                   ↓
M20 Unicode ──→ M21 Window Mgmt ──→ M27 Polish
                   ↓
M23 Editor ←──── M22 (ELF loader for EDIT.BIN?)
M24 CALC depth (independent)
M25 File manager (depends on M20 for better rendering)
M26 Network apps (independent)
```

M18 → M19 is sequential (shell improvements build on scrollback/selection).
M20 → M21 is sequential (window chrome needs fonts first). M22–M26 are
largely parallelizable after their dependencies land. M27 is the capstone.

---

## ABI budget

| Milestone | Slots consumed | Cumulative |
|-----------|----------------|------------|
| Current (through Arc5) | 56 | 56/64 |
| M19 — Pipes | 2 (56/57) | 58/64 |
| M20 — Font size | 1 (58) | 59/64 |
| M22 — ELF loader + strace | 2 (59/60) | 61/64 |
| Remaining | — | 3/64 |

After M22, three slots remain. This is intentional — the kernel surface is
nearly complete. Future milestones must be predominantly userland.

---

## What this roadmap does NOT cover

These are "distant mountains" from the original wishlist — visible but not
climbed:

- **SMP / multi-core.** Apple Silicon has performance cores we don't use.
  Not urgent until single-core is saturated.
- **Dynamic linking.** The flat-image model works for small apps. ELF
  loading (M22 D1) is the bridge.
- **Virtual memory depth.** COW, mmap, demand paging. Guard pages exist
  (M16). More only when apps need it.
- **POSIX / Linux compat.** Not VirelaiOS's identity.
- **Browser / HTTP server.** A TCP client exists. A full HTTP stack is a
  different project.
- **USB-everything.** HID works. Mass storage, serial, etc. are future work.
- **GPU acceleration.** virtio-gpu is framebuffer-only. 3D is a mountain.

---

## Meta-requirement (carried from original roadmap)

Every major infrastructure card names the small program or experience that
consumes it next. Every milestone ends with a composition test that a human
can see or use. This holds for M18–M27.
