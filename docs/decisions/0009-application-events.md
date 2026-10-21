# ADR 0009: Interactive EL0 application events and syscalls

Status: **accepted** · Date: 2026-08-15 · Milestone: nine (interactive application platform)

## Context

Milestones zero through eight delivered a fully functional operating system on Apple silicon:
preemptive multitasking, per-process address spaces, FAT32 storage, virtio-net, virtio-gpu
windows (the Driving Award window manager), USB xHCI / HID input, and a human-interface shell.

However, EL0 user programs remain **output-only or batch-driven**: user processes can open
windows, render pixels, and present frames, but cannot receive interactive keystrokes,
pointer clicks/motion, or window lifecycle events. Keystrokes currently route only to the
terminal line editor, while mouse reports update the cursor and window focus inside the kernel.

Milestone nine turns DipshitOS into an **interactive application platform** by routing user
input and window lifecycle transitions into per-process bounded event queues and exposing
standard event polling and blocking syscalls to EL0.

This ADR establishes the normative event wire format, event kind enumeration, modifier/button
bitmasks, coordinate mapping contract, and the ADR 0007 syscall ABI amendments (slots 21 and 22).

---

## Decisions

### D1. Normative 16-byte event wire layout

All events share a compact, fixed 16-byte C-ABI extern layout (`Event`), identical across
kernel and userspace:

```zig
pub const Event = extern struct {
    /// Event category / discriminator (1..8).
    kind: u16,
    /// Modifier bitmask (keyboard) or button bitmask (mouse).
    flags: u16,
    /// Monotonic per-process sequence counter (starts at 1).
    seq: u32,
    /// Event-specific primary argument (e.g. keycode, window-local X, window ID).
    arg0: u32,
    /// Event-specific secondary argument (e.g. ASCII byte, window-local Y, previous focus).
    arg1: u32,
};
```

- Total size is exactly 16 bytes: `2 + 2 + 4 + 4 + 4 = 16`.
- Wire format is little-endian, natural AArch64 alignment (4-byte aligned).
- Pure data structure: no pointers, no heap allocations, no dynamically sized payloads.

---

### D2. Event kinds and argument encoding

The `kind` field identifies the event type (0 is reserved/invalid; kinds
1–8 below are this ADR's core set, kinds 9–17 are addended in ADR 0013 D2,
and kind 18 `COMPOSITE_TICK` is the first routing-restricted kind, added by
milestone 32's WMS1):

| Value | Constant | Description | `arg0` | `arg1` | `flags` |
|:-----:|:---------|:------------|:-------|:-------|:--------|
| 1 | `KEY_DOWN` | Key pressed | HID usage / keycode | Decoded ASCII / symbol (or 0) | Modifier mask |
| 2 | `KEY_UP` | Key released | HID usage / keycode | Decoded ASCII / symbol (or 0) | Modifier mask |
| 3 | `MOUSE_DOWN` | Mouse button pressed | Window-local X (`0..w-1`) | Window-local Y (`0..h-1`) | Button mask \| Modifier mask |
| 4 | `MOUSE_UP` | Mouse button released | Window-local X (`0..w-1`) | Window-local Y (`0..h-1`) | Button mask \| Modifier mask |
| 5 | `MOUSE_MOVE` | Mouse motion | Window-local X (`0..w-1`) | Window-local Y (`0..h-1`) | Button mask \| Modifier mask |
| 6 | `WIN_FOCUS` | Window gained focus | Window ID (`2..3`) | Previous focused window ID | 0 |
| 7 | `WIN_BLUR` | Window lost focus | Window ID (`2..3`) | Newly focused window ID | 0 |
| 8 | `WIN_CLOSE` | Close requested | Window ID (`2..3`) | 0 | 0 |
| 18 | `COMPOSITE_TICK` | Composite/present cadence tick, delivered ONLY to the registered WM server's process queue (ADR 0015 D3). | Present sequence (monotonic, wraps at 2³²) | 0 (reserved) | 0 |
| 19 | `WM_POINTER` | Raw absolute-pointer sample, delivered ONLY to the registered WM server (M32 WMS5, issue #625). | X \| (Y << 16) in framebuffer pixels (top-left origin) | Raw HID keyboard modifier byte live at the sample's decode (#2896; was reserved 0 — the capture-time snapshot the seat echoes back on the WMCTL cmd-15 forward) | Low byte = the raw HID button byte (0x01 left, 0x02 right, 0x04 middle) |
| 20 | `WM_WINDOW` | Window-registry mirror — one kernel window row fanned out so the registered WM can hit-test (M32 WMS5, issue #625). | X \| (Y << 16) | W \| (H << 16) | Low byte = window id; bit 8 = visible; bit 9 = focused; bits 10–11 = workspace |
| 21 | `WM_KEY` | Raw keyboard sample, delivered ONLY to the registered WM server on key-DOWN edges (M32 WMS5 Gate 2, issue #625, claim 4278). | HID usage (or decoded key byte) | 0 (reserved) | ADR 0009 modifier bits (`MOD_SHIFT`/`MOD_CTRL`/`MOD_ALT`) |

> **Routing restriction (kinds 18–21).** Kind 18 was the first kind with a
> ROUTING RESTRICTION: every kind 1–17 fans out to the owning/focused
> process per its own contract; kinds 18–21 are delivered exclusively to
> the process that registered via `sys_wmctl REGISTER` (slot 65). When no
> WM is registered, they are never generated. Routing lives in
> `events.push`'s caller (the WMS2/WMS5 kernel paths); the wire format is
> unchanged. Kinds 19/20 form the M32 WMS5 input seam: while a WM is
> registered the kernel stops consuming pointer GEOMETRY (drag/resize/
> snap/focus-at are gated off behind `wm_owns_input`; the cursor stays a
> kernel blit surface) and instead fans the raw stream + registry mirrors
> out, so the WM — not the kernel — decides geometry and hit-tests.
> Kind 21 completes the seam's keyboard half: the raw key stream fans out
> on key-DOWN edges and the kernel's own keyboard geometry consumers
> (Ctrl+T tile, Ctrl+M master-swap, Ctrl+N minimize, Ctrl+Shift+M
> maximize, F11 fullscreen, Ctrl+Shift+T always-on-top, Ctrl+F1-3
> workspace, Alt+` cycle, Alt+arrow move) gate behind `!wm_owns_input`,
> so the WM — not the kernel — decides geometry from chords, issuing
> SET_WINDOW rects (slot 65 cmd 2) and SET_STATE (slot 65 cmd 4).
> Kind 18 adopted by M32 WMS1 (claim 1484); kinds 19/20 by M32 WMS5
> (claim 9849); kind 21 by M32 WMS5 Gate 2 (claim 4278).

---

### D3. Modifier and button bitmasks

The `flags` field contains bitmasks for keyboard modifiers and mouse button state:

#### Keyboard Modifiers (bits 0–7)
- `MOD_SHIFT = 0x0001` (Shift key held)
- `MOD_CTRL  = 0x0002` (Control key held)
- `MOD_ALT   = 0x0004` (Alt / Option key held)
- `MOD_CMD   = 0x0008` (Command / Meta / GUI key held)

#### Mouse Buttons (bits 8–11)
- `BTN_LEFT   = 0x0100` (Left button pressed)
- `BTN_RIGHT  = 0x0200` (Right button pressed)
- `BTN_MIDDLE = 0x0400` (Middle button pressed)

For convenience in user programs, low-byte button aliases (`BTN_LEFT_BIT = 0x01`, `BTN_RIGHT_BIT = 0x02`, `BTN_MIDDLE_BIT = 0x04`) are provided when checking button-only reports.

---

### D4. Window-local coordinate translation

Pointer events (`MOUSE_DOWN`, `MOUSE_UP`, `MOUSE_MOVE`) delivered to a process are always
translated into **window-local coordinates**:

$$\text{arg0} = \text{clamp}(X_{\text{scanout}} - X_{\text{win}}, 0, W_{\text{win}} - 1)$$
$$\text{arg1} = \text{clamp}(Y_{\text{scanout}} - Y_{\text{win}}, 0, H_{\text{win}} - 1)$$

User programs never need to query the window manager for window position to handle local
pointer coordinates.

---

### D5. Syscall ABI amendments (ADR 0007 slots 21 & 22)

Milestone 9 allocates slots 21 and 22 in the frozen ADR 0007 syscall table:

| Slot | Name | Signature | Semantics |
|:----:|:-----|:----------|:----------|
| 21 | `sys_poll_event` | `poll_event(buf) -> i64` | Non-blocking event poll. If an event is queued for the calling process, pops it, copies the 16-byte `Event` structure to `buf` via `uaccess.copy_out`, and returns `1`. If the queue is empty, returns `0`. Returns `-3` (`EFAULT`) for an invalid user buffer, `-1` (`EINVAL`) if the calling task is not a registered process. |
| 22 | `sys_wait_event` | `wait_event(buf) -> i64` | Blocking event wait. If an event is queued, immediately pops it, copies 16 bytes to `buf`, and returns `1`. If the queue is empty, blocks the calling task in the scheduler (`scheduler.wait_event_current`) without consuming CPU. When an event is pushed, the process wakes immediately, restarts the syscall at `svc #0`, copies the event, and returns `1`. Returns `-3` (`EFAULT`) or `-1` (`EINVAL`). |

- `implemented_count` in `kernel/src/syscall.zig` becomes **23** (slots 0..22).
- Both syscalls strictly adhere to the ADR 0007 uaccess fault-safe contract.

---

### D6. Queue geometry and lifecycle discipline

- **Queue Capacity:** 64 events per process slot (`events.max_events = 64`;
  raised from 16 by #2260 — the cv input pump can dispatch a full
  32-completion used-ring pass in one idle turn, and a 16-deep target queue
  dropped the head of every burst that out-grew it under scheduling load).
- **Memory Discipline:** Statically allocated in kernel BSS (`[process.max_processes]EventQueue`). No heap allocation.
- **Overflow Policy:** Drop-oldest FIFO. When full, pushing an event drops the oldest unconsumed event and increments `dropped_count`.
- **Lifecycle Reset:** `events.reset(pid)` is called during process creation (`process.allocate`) and process termination (`process.free`).

---

### D7. Enforceability and verification gates

| Subsystem | Requirement | Gate |
|:----------|:------------|:-----|
| Contract | Wire layout, enum values, size = 16B | Class A unit tests (`kernel/src/events.zig`) |
| Keyboard routing | Keypresses to focused user window | Class A + live keyboard routing proof |
| Pointer routing | Window-local translated clicks | Class A + hit-test dispatch proof |
| Lifecycle events | Focus and blur synthetic events | Class A state machine tests |
| Syscall seam | `sys_poll_event` & `sys_wait_event` | Class B live wait/wake gate |
| Interactive app | `KEYTEST.BIN` interactive graphics | Class B capstone gate (`tools/verify-live-events.sh`) |

---

## Consequences

- Applications can implement real-time interactive loops using `sys_wait_event` without polling or spinning.
- The window manager gains bidirectional event flow between host input and guest user processes.
- Syscall dispatch table grows to 23 implemented slots (0..22).

---

### Amendment (2026-09-15, phase 2 — socket readiness is NOT an event kind)

**Append-only.** The decision record above is unchanged; this records the
negative decision and its reason, so the next reader does not "helpfully" add
a readiness event.

Phase 2 (`syscall`/`os`/`net` for GOOS=virelai) needed a way to wake a task
that is blocked on TCP readiness. The obvious shape — push an event, let the
runtime's netpoll drain the queue — is **rejected**, for three reasons:

1. **The queue belongs to the application.** Kinds 1–21 are the input and
   window stream the GUI loop consumes (`sys_poll_event` / `sys_wait_event`).
   A runtime poller draining readiness from the same FIFO would consume the
   application's keyboard and window events.
2. **Drop-oldest would lose readiness.** The queue is a bounded 64-event FIFO
   with a drop-oldest overflow policy. Readiness is not a notification that
   tolerates loss; dropping it wedges a reader until an unrelated event
   happens to arrive.
3. **Edge vs level.** An event kind is edge-shaped; socket readiness is
   level-shaped, and a level-triggered query cannot lose an edge that
   arrived while nobody waited.

The chosen mechanism is therefore **slot 76 `sys_sock_ready(op, want,
timeout_ns)`** (ADR 0007, appended the same day): a level-triggered readiness
mask. Level-triggering is the point — the caller may poll it as often as it
likes, so no edge can be lost even if a poll lands between two readiness
changes. It is the "or equivalent" the phase-2 brief
allows, and it keeps ADR 0009's queue semantics exactly as specified.

Consequences for this document: no new event kind is defined, `Event` stays
16 bytes with kinds 1–21, and `sys_poll_event` / `sys_wait_event` are
untouched. ADR 0009's "Syscall seam" row (D7) is unaffected.
