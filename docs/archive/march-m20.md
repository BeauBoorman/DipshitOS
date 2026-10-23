> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone twenty march — text rendering & Unicode (living tracker)

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts. This file holds M20's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

M18–M19 gave us a powerful terminal and shell. But the text rendering is
still stuck at 8×8 ASCII — one font size, one character set. The compose
sequences from ADR 0014 produce Unicode codepoints that can't be *displayed*
because `text.zig` only knows about glyphs 0x00–0x7F. Window chrome is
functional but inconsistent. M20 fixes all of this.

**One new syscall slot** for font size (58). The rest is pure userland.

> **CLOSED 2026-08-25** (claim 5127 code via PR #500; claim 8961 live-gate
> closure on `agent/oxalpha/m20-text-unicode`): all five cards live-gated ✅
> on real Apple silicon VZ at HEAD. U3's Ctrl+G goto-line landed in the
> closure pass; U5's red-on-main tabs gate was rewritten onto claim-0680
> raw scanouts after the fleet log handed its decoder bug to the text
> owners — root cause corrected there: the "missing leading glyphs" are
> real occlusion by the M21/M27 dock (x=0..23), not decoder misalignment,
> and the Lane C putraw `\t` escape is dead since the M19 P5 tokenizer
> unescape (gates pass a real tab through double quotes instead).

## The cards, in order

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| U1 | **Multiple font sizes.** Three bitmap font sizes: 8×8 (current default), 16×16 (2×), and 24×24 (3×). `font small/medium/large` command switches. Per-window font size via slot 58 `sys_font_size(id, size)`. All three sizes are comptime-generated from the existing 8×8 glyphs (nearest-neighbor scaling). | ✅ | `bash tools/verify-live-font-sizes.sh` **PASS 1/1** 2026-08-25 (`cell=8x8→16x16→24x24` observed over serial, artifacts `live-font-sizes-*`) | Kernel: slot 58 `sys_font_size(id, size)`. `text.zig` gains three font tables (comptime generated). The `font` shell command and the syscall both call the same setter. Font size affects line spacing and character width for that window. |
| U2 | **Unicode glyph table.** Extend `text.zig` to render Latin-1 Supplement (U+0080–U+00FF) and Latin Extended-A (U+0100–U+017F). Compose sequences (ADR 0014) now display their output. Glyphs are comptime-generated bitmap tables at 8×8, 16×16, and 24×24. | ✅ | `bash tools/verify-live-unicode.sh` **PASS 1/1** 2026-08-25 (café decodes through the live UTF-8 path missing=0; 中文 double-wide fallback counted, last=U+6587; artifacts `live-unicode-*`) | `text.zig` comptime Unicode lookup (~190 glyphs × 3 sizes, `font_unicode.zig`). ASCII range unchanged; missing-glyph fallback + `text fontdebug` counters. |
| U3 | **Text search in apps.** Ctrl+F in NOTEPAD opens the find bar (extend M17 C6). Ctrl+G goes to a specific line. FILE.BIN preview highlights the searched filename. The find bar works on the visible buffer and the scrollback. | ✅ | `bash tools/verify-live-text-search.sh` **PASS 2/2 boots** 2026-08-25: NOTEPAD walk types a document then finds `wor` (`notepad: find 'wor' hit=1/1`) and jumps via **Ctrl+G** (`notepad: goto line=2 offset=6`); FILE.BIN `Ctrl+F`+`txt` narrows live (`file: filter 'txt' shown=2 total=2`); artifacts `live-text-search-*` | Find bar + case toggle were M15 C5/C6 + Lane C; the closure pass (claim 8961) added the missing **Ctrl+G goto-line** bar, find/goto/filter serial marker seams, and the FILE.BIN matched-substring row highlight. Gate drives REAL ctrl-chords through the custom-virtio INPUT queue (HID mods byte) — modifier chords reach the focused window headlessly, no activation wall. |
| U4 | **Improved window chrome.** 2-pixel border (up from 1px), 16px title bar (up from 8px), 8×8 close button glyph in the title bar, drag-from-title-bar to move (extend current pointer grab). Consistent look across all windows. | ✅ | `bash tools/verify-live-chrome.sh` **PASS 3/3 boots** 2026-08-25, chrome measured from byte-exact guest scanouts (`--cvc-snap` raw): focused boot = accent ring + label ink + close glyph; unfocused boot = border exactly 2px (incl. negative probe at col+2), 16px title band, client bg; boot C clicks the close glyph → `notepad: win_close`; artifacts `live-chrome-*` | Paint landed in `draw_chrome` (claim 5127); closure pass gated it. Focus ring styling is M21 W9's accent variant — asserted as-current. Drag-from-title predates M20 (Step 5/Arc gates); title strip behavior additionally proven live by the click-close differential. |
| U5 | **Monospace rendering.** Proper tab-stop alignment (8-char tabs) in the terminal and text apps. Fix the current proportional-width artifacts where some characters take different widths. All characters are guaranteed 8px wide at 8×8. | ✅ | `bash tools/verify-live-tabs.sh` **PASS 2/2 boots** 2026-08-25 — was RED-on-main; rewritten onto claim-0680 raw scanouts decoded at the fixed grid: probe row reads exactly `AAAA|B|8 tab-fill cells|Z@stop16`, control adjacent; `fwd_unknowns=0`; artifacts `live-tabs-screen-{A,B}.raw` | wcwidth/tab materialization landed (Lane C). Closure findings recorded: (1) leading-glyph "decode loss" = real dock occlusion x=0..23 (decoder docstring corrected); (2) putraw `\t` escape dead since M19 P5 tokenizer unescape — gates pass real tabs via `"…\t…"`. monitor.zig seam repair handed to the 8777 holder. |

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Font & Unicode** | `kernel/src/text.zig` for U1 (font sizes) + U2 (Unicode glyphs) + U5 (monospace). These are deeply intertwined in the same rendering path. | M18 done. |
| **B — App improvements** | `user/src/notepad.zig` + `user/src/file_browser.zig` for U3 (text search). `kernel/src/driving_award.zig` for U4 (window chrome). | U1 (font sizes affect chrome dimensions). |

## Notes

1. **ABI budget:** 1 new syscall slot (58) for `sys_font_size`.
   Cumulative: 59/64 after M20.
2. **BSS budget:** Three font tables at 3 sizes. 8×8 = existing. 16×16:
   256 bytes × 190 glyphs = ~48.6 KiB. 24×24: 72 bytes × 190 glyphs =
   ~13.7 KiB. Unicode lookup: ~380 bytes (190 × 2 bytes codepoint mapping).
   Total M20 BSS delta: ~62.7 KiB. This is the largest single-milestone
   BSS add — review against the 11 MiB budget.
3. **Gate shape:** U1: `verify-live-font-sizes.sh` — font switch observed in
   terminal output. U2: `verify-live-unicode.sh` — compose character rendered.
   U3: `verify-live-text-search.sh` — NOTEPAD find highlights match. U4:
   `verify-live-chrome.sh` — title bar dimensions verified. U5:
   `verify-live-tabs.sh` — tab alignment verified.
4. **Glyph generation:** The 8×8 base glyphs exist in `text.zig`. The 16×16
   and 24×24 versions are generated at comptime by 2× and 3× nearest-neighbor
   scaling of the 8×8 source. This keeps the font data in a single source
   of truth.
5. **Scope exclusions:** No anti-aliasing (bitmap fonts stay crisp). No
   variable-width fonts (monospace only). No CJK, Cyrillic, or Arabic —
   Latin only for now. No font file loading (all comptime).
