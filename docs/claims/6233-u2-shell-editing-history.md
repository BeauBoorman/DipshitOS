# Claim: milestone eight, card U2 — shell editing & history

- **Owner:** zcode (`agent/zcode/m8-u2-lineedit`)
- **Prompt / plan:** user request 2026-08-14 — "pick up the next milestone-eight
  card" (the march-m8.md ladder names U2 as next after U0/U1). Normative
  contract: ADR 0008 D2
  ([`docs/decisions/0008-human-interface-guidelines.md`](../decisions/0008-human-interface-guidelines.md)).
- **Scope:** `kernel/src/lineedit.zig` (bounded history ring, cursor
  left/right + Home/End, Ctrl-A/E/K/U/L, Ctrl-C, Delete, bounded tab
  completion) and the editing half of `kernel/src/input.zig` (arrow usages,
  Ctrl-chord modifier handling, Delete/Home/End usages → the editor's escape
  byte seam), plus `kernel/src/shell.zig`'s editor wiring (completer + prompt
  redraw, BSS-backed shell storage) and the runner's editing-key seam
  (`--input-string` tokens for arrows/Home/End/Delete/Ctrl in
  `host/vm-runner/Sources/VMRunner/main.swift`). New live gate
  `tools/verify-live-lineedit.sh`.
- **Depends on:** U0 (ADR 0008, ✅) and the I3 input path (✅ claim 6050).
- **Status:** ✅ done (2026-08-14)

## Notes

The M1.5 line editor is a fixed buffer with backspace + Ctrl-C only. ADR 0008
D2 requires, as bounded fixed-BSS behavior: recall (up/down over a bounded
session-scoped history ring), cursor movement (left/right/Home/End), editing
chords (Ctrl-A/E/K/U/L + the existing Ctrl-C), forward Delete, and bounded
tab completion of verbs + sub-verbs (bell on ambiguity/no match — no
alternative listing). The byte seam is preserved: backspace at end still
emits `\b \b`, submit `\r\n`, cancel `^C\r\n`; the class-A transcript gate
must keep passing byte-identically (its scripted feed uses only plain ASCII
+ LF + one Ctrl-C, all unchanged paths).

Design: arrow/Home/End/Delete arrive from BOTH input paths as the same bytes
the serial path would see — the HID keymap maps the arrow/Home/End/Delete
usages to the classic ANSI sequences (`ESC [ A/B/C/D/H/F`, `ESC [ 3 ~`) and
Ctrl+letter to the raw control bytes (0x01..0x1a), so `lineedit.zig`'s small
escape parser covers the USB-HID path and a real serial terminal alike.
Mid-line edits re-echo the tail + backspaces (no forward cursor movement is
emitted, keeping the dumb-terminal-safe property); Ctrl-L reuses the
`clear` command's `ESC [ 2J ESC [ H` sequence and redraws prompt + line.
The history ring (16 × 256 B) and the recall draft live in the editor; the
kernel-path Shell moves to fixed BSS so the 16 KiB boot stack (ADR 0004 D5)
does not carry it. Tab completion is injected as a `?Completer` field the
shell wires to a monitor-side lookup (registry verbs + a bounded static
sub-verb table for the multi-verb commands); `lineedit.zig` stays
host-testable with a mock console.

The gate (`tools/verify-live-lineedit.sh`, the verify-live-input.sh pattern):
ONE `--input --display` run where the keyboard types a full editing session —
`ec` + Tab → `echo `, `hi`, Enter; Up recall; Home; Delete × 6; `he` + Tab →
`help `, Enter; Up recall + Ctrl-U + typing + Ctrl-C; and a final
cursor/chord exercise (`abcd`, Left, Ctrl-E, Ctrl-A, Ctrl-K, Ctrl-L, Ctrl-C)
— asserting the echoed edited lines in `vm-serial.log`. The runner's
`--input-string` gains `<up>/<down>/<left>/<right>/<home>/<end>/<delete>`
tokens and `^a`..`^z` Ctrl chords (synthesized NSEvents with the right macOS
keyCodes + modifier flags; VZ maps them to HID usages — observed at claim
time and recorded in `docs/hardware-contract.md`).

## Verified

- ✅ class A: `zig fmt --check` pass; `bash tools/verify-unit-tests.sh` —
  all present modules pass (lineedit 33, input 29, monitor 361, shell 396,
  text 24 — including the new editing/history/completion/rendering
  tests); `zig build test-console` — **transcript byte-identical**;
  `zig build` / `image` / `inspect` / `context` pass;
  `swift build --package-path host/vm-runner` (debug + release) pass.
- ✅ class B: `bash tools/verify-live-lineedit.sh` **PASS 13/13 on VZ**
  (USB keyboard: submit / recall+Home+delete-sweep / recall+Left+delete;
  serial bytes: Tab completion + Ctrl-A/A+E/K/U/L, exactly one ^C —
  atomic output-line assertions; evidence `artifacts/live-lineedit-*`).
- ✅ regression: `bash tools/verify-live-input.sh` PASS (the I3 surface
  after the input.zig changes).
- ✅ mirror check: the glyph decode of this branch's captures reads
  FORWARD with the exact tripwire baseline numbers (fwd 0/604, mirrored
  549/595; clock title+body forward) — no orientation regression from the
  text.zig change. The SCK-gated `verify-live-glyphs.sh` itself is
  **blocked in this environment** (Screen Recording permission missing
  for the terminal — the gate's phase-0 refuses the cacheDisplay
  fallback captures); the decode above was run manually on those
  captures (`tools/decode-screen-glyphs.py`).
- ✅ `bash tools/verify-coordination.sh`
