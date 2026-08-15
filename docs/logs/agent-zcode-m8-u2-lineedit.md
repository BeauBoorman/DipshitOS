# Log — milestone eight card U2: shell editing & history (zcode)

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-14** — **Claim (zcode, `agent/zcode/m8-u2-lineedit`):** claimed
  the milestone-eight card U2 row (shell editing & history — ADR 0008 D2).
  Claim file: `docs/claims/6233-u2-shell-editing-history.md`. Scope per the
  march-m8.md agent split: `kernel/src/lineedit.zig` + the editing half of
  `kernel/src/input.zig` + the runner's editing-key seam; the shell wiring
  (completer/prompt/BSS storage) touches `kernel/src/shell.zig` minimally.
  Design: HID arrow/Home/End/Delete usages map to the same ANSI escape
  sequences a serial terminal sends (one parser covers both input paths);
  Ctrl+letter maps to the raw control bytes; the history ring + recall draft
  are fixed editor state and the kernel-path Shell moves to BSS (the 16 KiB
  boot stack, ADR 0004 D5, must not carry ~4.3 KiB of ring); tab completion
  is an injected completer (registry verbs + bounded sub-verb table). The
  class-A transcript feed (plain ASCII + LF + one Ctrl-C) exercises only
  unchanged paths, so it stays byte-identical. 🔄 in progress — no code
  written yet.
- **2026-08-14** — **Claim-time VZ observations (zcode,
  `agent/zcode/m8-u2-lineedit`):** driving the editing keys through the
  runner's `--input-string` seam surfaced four host-side behaviors, each
  observed in the guest's own report stream (`kb: rep` debug lines, a new
  per-report diagnostic wired under `--input`):
  1. **VZ ignores `modifierFlags` on synthesized keyDowns** — a Ctrl-A
     chord arrived as a plain 'a' (mods=0 in the report). Chords must be
     delivered as a flagsChanged pair around the keyDown, the way a real
     keyboard does.
  2. **`NSEvent.otherEvent` rejects `.flagsChanged`** —
     NSInternalInconsistencyException ("Invalid parameter not satisfying:
     _NSEventMask64FromType(type) & WeirdMask"); the flagsChanged halves
     are built via CGEvent (`CGEvent(source:).type = .flagsChanged`).
  3. **A function-key keyUp emits a PHANTOM usage** — Home's keyUp
     delivered HID usage 0x08 ('e') with no key pressed (report stream:
     0x4a → 0x08 → next key). Letter keyUps deliver a clean empty report,
     so each token's release is sent as an anonymous letter keyUp ('q',
     whose keyDown never happens) — the clean release also clears the
     guest's held set so repeated tokens re-fire.
  4. **The editing usages ARE delivered with authentic Cocoa characters**
     (the function-key unicodes, "\t", "\r"): Up=0x52, Left=0x50,
     Home=0x4a, Tab=0x2b, Enter=0x28 observed; made-up ASCII characters
     strings ("left", "tab") made VZ's translation misbehave (phantom
     bytes, lost keys). Also: `text.zig` now interprets the editing bytes
     (`\b`, `\r`, `ESC [ 2 J`/`ESC [ H`) as cursor motion instead of
     blank cells — mid-line edits and `clear` previously rendered as junk
     cells on the Road Pops screen (host-tested; scope addition: the
     on-screen half of the editing experience, ADR 0008 D2).
  These go into `docs/hardware-contract.md` at close-out.
- **2026-08-14** — **Card U2 done (zcode, `agent/zcode/m8-u2-lineedit`):**
  the editing surface is live. Kernel: `lineedit.zig` (history ring 16×256
  + draft, cursor left/right/Home/End, Ctrl-A/E/K/U/L/C, forward Delete,
  escape-sequence parser, tab completion via the injected completer;
  byte seam preserved — backspace-at-end is still `\b \b`, submit `\r\n`,
  cancel `^C\r\n`), `input.zig` (arrow/Home/End/Delete usages → ANSI
  sequences, Ctrl+letter → control bytes, per-report `kb: rep` debug under
  `--input`), `monitor.zig` (`complete_line`: registry verbs + a
  runtime-built sub-verb table, unique-prefix rule, bell on ambiguity),
  `shell.zig` (completer + prompt wiring; the kernel-path Shell moved to
  BSS — the history ring must not ride the 16 KiB boot stack), `text.zig`
  (`\b`/`\r`/`ESC[2J`/`ESC[H` render as cursor motion — scope addition:
  the on-screen half of D2). Runner: authentic function-key characters,
  own-keyUp tokens, `^a`..`^z` chord synthesis (flagsChanged via the
  keyEvent factory), `--input-string-interval`. Gate
  `tools/verify-live-lineedit.sh` **PASS 13/13 on VZ** after shaping the
  session to the observed VZ seam envelope (sacrificial first `<left>`
  against the phantom first-usage re-delivery; recall-shielded phases;
  atomic output assertions; chords + Tab over the serial byte path —
  synthesized USB modifiers never reach the HID report). Class A green
  incl. the byte-identical transcript; `verify-live-input.sh` re-ran
  green; the glyph decode reads forward at the exact tripwire baseline
  (the SCK-gated glyphs tripwire itself is blocked here — Screen
  Recording permission missing for this terminal; noted in the claim).
  Docs updated: status.md, roadmap.md, march-m8.md, gate-inventory.md,
  hardware-contract.md (the editing-key synthesis bounds), justfile
  (verify-vz + the gate target).
- **2026-08-14** — **Glyphs tripwire resolved (zcode):** after the
  terminal's Screen Recording permission grant + restart,
  `bash tools/verify-live-glyphs.sh` **PASS** on this branch — the SCK
  composited-window capture decodes forward at the exact baseline
  (fwd 0/604, mirrored 549/595, clock window forward), closing the one
  blocked step in the U2 close-out. The claim's blocked note is updated
  to the observed PASS.
