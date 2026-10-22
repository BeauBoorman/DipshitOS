---
title: Input
parent: capabilities
status: published
tags: [capabilities, input, usb]
---

# Input

Screen-side input is a real USB stack, because Virtualization.framework
has no virtio-input device. The keyboard and pointing device appear behind
an **Apple XHCI USB host controller**, so VirelaiOS enumerates them
itself — and because VZ offers no programmatic keyboard or pointer API,
the test fleet needed a second, synthetic path into the same decoders.
Both paths end in the same place: decoded bytes in a bounded FIFO, and
routed events in the seat's queue.

## The USB path

`--input` attaches `VZUSBKeyboardConfiguration` and
`VZUSBScreenCoordinatePointingDeviceConfiguration`. To the guest that is a
`0x106b:0x1a06` XHCI controller (see [[drivers]] for the register/ring
machinery) plus two HID devices:

- **Keyboard** — port 9, `05ac:8105`, full speed, accepts the HID boot
  protocol, interrupt-IN EP1 at maxpkt 8. Every report is the classic
  8-byte boot packet: modifier byte, reserved byte, six usage IDs.
- **Pointer** — port 10, `05ac:8106`, an **absolute** screen-coordinate
  pointer (interface protocol 0 — not a boot mouse). Its native report
  starts with report ID 1, then a buttons byte and little-endian X/Y in
  `0..32767`; wheel and pan fields that follow are ignored. The guest
  maps the 0..32767 logical range onto the framebuffer axes.

Enumeration runs port reset → Enable Slot → Address Device → descriptor
reads over EP0 → Set Configuration → Set_Protocol(boot) where the
interface offers it, and the interrupt-IN endpoint is armed. Reports
arrive roughly once per present cadence, so the driver arms a single TRB
at a time and re-arms on each completion — a shape the deeper input gates
stress deliberately. Completed reports are stashed in a bounded pending
table so an interrupt report can never be lost behind a control or bulk
wait, then decoded in completion order.

`input.zig`'s `drain()` — called from the shell idle loop, *before* the
framebuffer present so a keystroke is never starved behind a slow
full-frame flush — hands keyboard reports to `decode_keyboard_report`
and pointer reports to `decode_pointer_report`. Decoded bytes land in a
64-entry BSS FIFO; a full FIFO drops the newest byte and counts it.

## From report to event

The keymap is a pure usage→codepoint table. Letters shift to capitals,
Ctrl chords produce the ADR 0008 editing bytes `0x01..0x1a`, digits shift
to symbols, and the nav cluster (arrows, Home, End, Delete, the function
row) emits `ESC [` sequences so the line editor stays byte-driven.
Anything outside the printable subset is honestly refused — no byte is
invented.

Downstream, the kernel routes on two levels:

- **The terminal and focused apps** get cooked events. When the Road
  Pops terminal owns focus the FIFO feeds its line editor directly; when
  a window owns focus, KEY_DOWN/KEY_UP/MOUSE_* events land in that
  process's per-process event queue (64 events deep), drained by
  `sys_poll_event`/`sys_wait_event`.
- **The seat** gets the raw stream. Kinds 19 (`WM_POINTER`) and 21
  (`WM_KEY`) are routing-restricted: they are pushed only to the
  registered window-manager seat, which is how the Go seat `GOTABWM.ELF`
  does its own pointer hit-testing, chords, and focus policy while hosted
  apps still see ordinary events. The seat drains both kinds and decides
  which hosted window hears each one — pin, Alt+Tab, rail clicks, typing
  into `GOEDIT.ELF` all ride this seam (gate `go-wm-hid`).

The **translated-key contract** (ADR 0014, refined by the M83 arc):
KEY_DOWN/KEY_UP events carry the decoded Unicode codepoint in `arg1`
while kind-21 remains raw usage+flags — so an app that wants text reads
arg1 and an app that wants keys reads the raw form, and neither has to
reimplement the other's interpretation. GOEDIT's consumption of that
contract is pinned in-tree.

## Layouts, dead keys, and compose

A persisted `keyboard_layout` settings key selects the kernel keymap at
decode time — currently `us` (the compiled default) and `de`, the German
QWERTZ table with its swapped Y/Z, its own punctuation row (`ü/ö/ä/ß`),
and the ISO angle-bracket key. Unknown or absent values keep the US table
without adding a row to `SETTINGS.TXT`.

Compose is an OS-level two-key sequence, not an app feature: holding Alt
and striking two keys in succession looks the pair up in a compile-time
compose table (~27 pairs covering the common accented characters) and
emits the resulting Unicode codepoint — `Alt` `e` `'` style sequences
produce é-class glyphs. The compose state resets on Alt release or a
focus change, so a half-typed sequence can never leak into another
window's text, and the `compose` monitor command lists the live table.
The layout tables deliberately keep the dead-acute positions unmapped on
`de` — compose covers that ground instead of per-layout state machines.

<Aside kind="note">

**PLANNED.** More layouts are a table-entry exercise — the LayoutTable
shape (letters row, shifted-digit row, punctuation rows, an ISO-flag)
generalizes — but the fleet ships exactly the two tables it gates.

</Aside>

## The headless injection channel

VZ has no programmatic input API: `VZUSBKeyboardConfiguration` is driven
only by a view forwarding host `NSEvent`s, and macOS only delivers those
to the VM's key window — the "activation wall" that makes synthesized
keys (and especially modifiers and pointer motion) unreliable for
unattended gates. So the second path bypasses the view entirely: **queue
3 of the custom-virtio device**, armed whenever `--via-virtio` or any
deeper flag (`--cvc-snap`, `--cvc-file`) is set.

The guest pre-arms a pool of eight device-write buffers; the host
dequeues one per message, writes a fixed 16-byte envelope
(`[kind][flags][len][payload]`), and returns it. Kind 1 is a raw 8-byte
HID keyboard boot report; kind 2 is the canonical 5-byte absolute-pointer
payload `[buttons, x_lo, x_hi, y_lo, y_hi]` — the same logical-coordinate
convention the USB tablet uses. Injected payloads go through the *same*
`decode_keyboard_report`/`decode_pointer_report` functions as native USB
reports, so an injected key is an ordinary key everywhere downstream:
FIFO, compose, focus routing, the `input` counters. Delivery is strictly
ordered at a 0.25 s keyboard / 2.5 s pointer cadence — pressing is
edge-detected once per idle pass, so faster bursts would collapse a click
into nothing; the host retries on an empty pool and never reorders.

The runner surface on top of both paths:

| Flag | What it does |
|------|--------------|
| `--input` | Attach the two USB HID devices on XHCI |
| `--input-key <keycode>` | One keyDown (view path, or the HID-mapped cv path under via-virtio) after `--input-key-after`'s marker |
| `--input-string <ascii>` | Type a literal string — keyDown+keyUp per char — after `--input-string-after` |
| `--input-chords <csv>` / `--input-chords2` | Named chord sequences (return, arrows, ctrl-*, alt-tab, …) — the `macChord`/`hidChord` vocabulary — after `-after` markers |
| `--input-chords-delay <s>` | Per-stroke spacing on the view path (cv-input paces at a fixed 0.25 s) |
| `--chords-view` | Force the slow NSEvent view path even when the cv-input queue is armed — needed for launch-then-focus handoffs |
| `--pointer <x,y[,c];…>` / `--pointer-virtio` | Scripted pointer steps through the view or the cv-input queue |
| `--pointer-route` / `--pointer-request-trust` | Pointer delivery route (window/app/cg) and the Accessibility-trust prompt the CG route needs |
| `--host-capture-keys` / `--capture-keys` | Host-app key capture for a fullscreen `--host-session` |

Two adjacent host-side conveniences live outside the runner proper:
`tools/rfb-tape.sh --type-password` answers macOS Screen Sharing's own
password sheet through System Events during remote-framebuffer tapes, and
the seat's own chord surface (palette, tab chords, `?` hints) is exercised
through the same injection vocabulary.

## Focus and honesty rules

Injected input lands wherever focus currently sits — at a headless boot
the terminal is the sink by definition, until a user window opens and
takes it, so gates type before opening windows or refocus first. Pointer
press edges are latched (`take_press`/`take_click`) so a whole injected
drag drained in one pass still produces a click; the WM's `pointer_tick`
edge logic consumes them exactly as it would USB reports.

<Aside kind="info">

**LIVE-GATED.** `live-xhci`, `live-usb`, `live-input`, and
`live-input-depth` cover the controller, enumeration, and the end-to-end
keystroke surface; `live-pointer-cg` drives a real CG mouse through
press/drag/window-selection against scanout pixels; `live-pointer-virtio`
pins the headless injection path; `go-wm-hid` and `live-desktop-typing`
prove the seat's kind-19/21 drain into hosted apps.

</Aside>

<Aside kind="warning">

**LIMITATION.** Boot-protocol HID only — two known devices, no hubs, no
full report-descriptor parser, and no programmatic *host-side* input:
synthesized NSEvent keys depend on window activation, modifier injection
through that route historically failed, and the pointer's view routes are
probes, not proofs. The cv-input channel exists precisely because those
routes are unreliable; a physical keyboard and trackpad remain the
human-session path.
</Aside>
