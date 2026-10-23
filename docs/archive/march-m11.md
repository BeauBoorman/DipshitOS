> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone eleven march — desktop platform & GUI apps (living tracker)

> **SHIPPED 2026-08-16** — cards A0–A5 all landed; the capstone live gate
> `tools/verify-live-desktop.sh` PASSes on VZ (CALC/NOTEPAD/TOP/DESKTOP all
> OK) and the milestone is closed. Post-ship polish: CALC checked
> arithmetic/memory keys (claim 7869), the EL0 process-control seam
> (`sys_exec` slot 28 claim 6359, `sys_kill` slot 29 claim 7604 — DESKTOP
> launches apps and TOP's Kill button is real), and NOTEPAD's scrollable
> viewport (claim 1771). Milestone twelve (userland network apps) is now in
> progress — see [`march-m12.md`](march-m12.md) and issue #148.

## Where we are

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts, current gates, and what comes next. This file holds only
> milestone-eleven's per-card detail and collision-free agent split, following
> the [`march-m6.md`](march-m6.md), [`march-m7.md`](march-m7.md),
> [`march-m8.md`](march-m8.md), [`march-m9.md`](march-m9.md), and
> [`march-m10.md`](march-m10.md) pattern.
> A card's row flips to ✅ only with real observed class-B evidence, never
> code-complete alone.

Milestones zero through ten delivered a complete, usable machine: an AArch64
kernel with preemptive scheduling, per-process address spaces, FAT32 kernel
and user storage, virtio-net networking, virtio-gpu windows (Driving Award),
USB xHCI input, human interface tooling, and interactive EL0 events.

Milestone eleven combines windows (Milestone 6), interactive events (Milestone 9),
and userland persistent storage (Milestone 10) into a recognizable
**graphical desktop platform with dedicated consumer applications and a desktop launcher**.

The cards, in order:

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| A0 | **Architecture & UI contract (ADR 0011).** Normative specification for userland GUI applications: window-local coordinate conventions, event loop dispatch state machine, zero-allocation micro-widget state models (`Button`, `Label`, `TextInput`, `ListView`), theme palette tokens, drawing rasterization contracts, and desktop launcher lifecycle. Docs only — no code. | ✅ done (claim 0664) | `docs/decisions/0011-desktop-platform-and-gui-apps.md` | Gate: ADR 0011 accepted. |
| A1 | **Micro-widget toolkit & runtime (`user/src/lib/ui.zig`).** Reusable, lightweight GUI primitives: buttons (with idle/hover/pressed states), text labels, single-line text entry fields with cursor, list views with row selection, 8×8 bitmap text rasterization, and `App` event loop runtime, with 0 heap allocation and pure static BSS. | ✅ done (claim 8155) | `user/src/lib/ui.zig`, `user/src/lib/font8x8.zig` | Gate: class A unit tests covering layout arithmetic, hit-testing, widget state transitions, text buffer manipulation, and boundary checks. |
| A2 | **`CALC.BIN` (Interactive Graphical Calculator).** Clickable button grid (digits `0–9`, operators `+`, `-`, `*`, `/`, controls `=`, `C`, `+/-`), keyboard numeric input support, 64-bit integer arithmetic engine with divide-by-zero protection, and display screen. | ✅ done (claim 8401) | `user/src/calc.zig` | Gate: class A calculation engine tests + class B live gate running calculations via mouse and keyboard input. |
| A3 | **`NOTEPAD.BIN` (Graphical Text Editor).** Interactive text editing window supporting multi-line typing, cursor navigation, Backspace, Enter line breaking, and persistent load/save from `/data/notes.txt` using the Milestone 10 storage ABI (`sys_file_open`, `sys_file_read`, `sys_file_write`, `sys_file_close`). | ✅ done (claim 3234) | `user/src/notepad.zig` | Gate: class A editor buffer tests + class B live gate testing typing, saving to `/data/notes.txt`, and verifying persistence across reboot. |
| A4 | **`TOP.BIN` (Graphical Task Manager & Process Monitor).** Introspects process table via `sys_procs` (slot 7), renders live process tables and system statistics, provides interactive row selection and click-to-kill process termination. | ✅ done (claim 0680) | `user/src/top.zig` | Gate: class A process table parsing tests + class B live gate verifying live process table rendering and row selection. |
| A5 | **`DESKTOP.BIN` (Desktop Launcher & Environment).** **[Capstone Gate]** Top status bar with live clock and system diagnostics + clickable application menu to launch EL0 programs (`CALC.BIN`, `NOTEPAD.BIN`, `TOP.BIN`, `KEYTEST.BIN`). Verified end-to-end on live VZ hardware. | ✅ done (claim 2427) | `user/src/desktop.zig`, `artifacts/live-desktop-gate.txt`, `tools/verify-live-desktop.sh` | Gate: `tools/verify-live-desktop.sh` — **PASS** on VZ hardware: CALC.BIN OK, NOTEPAD.BIN OK, TOP.BIN OK, DESKTOP.BIN OK. |

## Agent split / collision rules

- **A0** (future claim): owns `docs/decisions/0011-desktop-platform-and-gui-apps.md`
  and UI architecture specification. Docs only.
- **A1** (future claim): owns `user/src/lib/ui.zig` and `user/src/lib/font8x8.zig`.
- **A2** (future claim): owns `user/src/calc.zig`, build integration, and calculator test gates.
- **A3** (future claim): owns `user/src/notepad.zig`, build integration, and editor test gates.
- **A4** (future claim): owns `user/src/top.zig`, build integration, and process monitor test gates.
- **A5** (future claim): owns `user/src/desktop.zig`, build integration, and capstone gate `tools/verify-live-desktop.sh`.
- Cross-cutting docs (`status.md`, `gate-inventory.md`) are updated per card
  at claim close-out.
