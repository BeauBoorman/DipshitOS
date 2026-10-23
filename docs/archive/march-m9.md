> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone nine march — interactive EL0 application events (living tracker)

## Where we are

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts, current gates, and what comes next. This file holds only
> milestone-nine's per-card detail and collision-free agent split, following
> the [`march-m6.md`](march-m6.md), [`march-m7.md`](march-m7.md), and
> [`march-m8.md`](march-m8.md) pattern. A card's row flips to ✅ only with
> real observed class-B evidence, never code-complete alone.

Milestones zero through eight delivered a complete, usable machine: an AArch64
kernel with preemptive scheduling, processes, virtual memory, FAT32 storage,
virtio-net networking, virtio-gpu windows (Driving Award), USB xHCI input,
and a polished human interface.

However, EL0 user programs are currently **output-only or batch-driven**:
user processes can open windows and write pixels, but cannot receive
interactive keystrokes, pointer clicks, or window lifecycle events from the
user. Milestone nine turns VirelaiOS from "a kernel with graphical demos" into
**an interactive application platform** by routing user events into per-process
event queues and providing event syscalls.

The cards, in order:

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| E0 | **Event contract & ADR 0009.** Normative 16-byte event wire format (`kind`, `flags`, `seq`, `arg0`, `arg1`), event kind constants (`KEY_DOWN=1`, `KEY_UP=2`, `MOUSE_DOWN=3`, `MOUSE_UP=4`, `MOUSE_MOVE=5`, `WIN_FOCUS=6`, `WIN_BLUR=7`, `WIN_CLOSE=8`), modifier bitmasks, and ADR 0007 syscall slots (`sys_poll_event` = slot 21, `sys_wait_event` = slot 22). Docs only — no code. | ✅ done | `docs/decisions/0009-application-events.md` | Gate: ADR 0009 accepted in `docs/decisions/0009-application-events.md`. Claim 7463. |
| E1 | **Kernel per-process event queue (`kernel/src/events.zig`).** Bounded in-memory event FIFO (16 events per process slot, pure BSS, no heap allocation), push/pop/peek mechanics, drop-oldest overflow tracking, and process lifecycle reset. | ✅ done | `kernel/src/events.zig` | Gate: class A unit test suite in `kernel/src/events.zig` covering FIFO wrap, bounds, drop counting, and process isolation. Claim 7670. |
| E2 | **Keyboard event routing.** When a user window is focused, decoded keystrokes and modifier chords from USB xHCI / input FIFO are converted into `KEY_DOWN` / `KEY_UP` events and pushed to the owning process's event queue. Terminal shell retains focus routing when window 0 is focused. | ✅ done | `kernel/src/input.zig` | Gate: class A unit tests in `kernel/src/input.zig` proving keystrokes and chords delivered to target process queue. Claim 7206. |
| E3 | **Pointer & click event routing.** Absolute pointer motion and button clicks within a user window are converted to window-local coordinates `(x - win.x, y - win.y)` and queued as `MOUSE_DOWN`, `MOUSE_UP`, and `MOUSE_MOVE` events to the focused/hit-tested window's owner. | ✅ done | `kernel/src/driving_award.zig` | Gate: class A coordinate translation tests + hit-test event dispatch proof. Claim 9228. |
| E4 | **Window lifecycle events.** When window focus changes or a window close request is initiated, synthetic `WIN_FOCUS`, `WIN_BLUR`, and `WIN_CLOSE` events are delivered to the process descriptor. | ✅ done | `kernel/src/driving_award.zig` | Gate: class A focus transition event sequence tests. Claim 0293. |
| E5 | **Event syscall seam (`sys_poll_event` & `sys_wait_event`).** Implement non-blocking `sys_poll_event` (slot 21) and blocking `sys_wait_event` (slot 22) across the uaccess boundary, with event-driven scheduler sleep/wake (`wake_event_waiters`). | ✅ done | `kernel/src/syscall.zig` | Gate: class A unit test suite in `kernel/src/syscall.zig` and `kernel/src/scheduler.zig`. Claim 1016. |
| E6 | **First interactive EL0 application (`KEYTEST.BIN`).** **[Capstone Gate]** A standalone user program loaded from ESP that opens a Driving Award window, reads interactive keyboard and mouse events via `sys_wait_event`, and renders real-time graphical feedback inside its window. | ✅ done | `artifacts/live-events-gate.txt`, `tools/verify-live-events.sh` | Gate: `tools/verify-live-events.sh` — PASS on VZ hardware: scripted keystrokes drive EL0 application events and verify resulting window pixels. Claim 9328. |

## Agent split / collision rules

- **E0** (claim 7463): owns `docs/decisions/0009-application-events.md` and
  ADR 0007 syscall table amendments. Docs only.
- **E1** (future claim): owns `kernel/src/events.zig` and integration with
  `kernel/src/process.zig` (allocating per-process event FIFO descriptors).
- **E2 + E3** (future claims): own the dispatch seam in `kernel/src/input.zig`,
  `kernel/src/xhci.zig`, and `kernel/src/driving_award.zig` (coordinate mapping).
- **E4** (future claim): owns focus/blur/close event generation in
  `kernel/src/driving_award.zig`.
- **E5** (future claim): owns `kernel/src/syscall.zig` (slots 21/22) and
  `kernel/src/scheduler.zig` (event waiter state & wakeup mechanism).
- **E6** (future claim): owns `user/src/keytest.zig` (or `user/src/draw.zig`),
  build image embedding, and the capstone gate `tools/verify-live-events.sh`.
- Cross-cutting docs (`status.md`, `gate-inventory.md`) are updated per card
  at claim close-out.
