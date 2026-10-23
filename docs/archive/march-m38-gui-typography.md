> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone thirty-eight march — desktop typography & high-fidelity GUI (living tracker)

> [`docs/status.md`](../status.md) is the canonical milestone-level source. This
> file holds M38's per-card detail, order, and gate notes. A card's row flips
> to ✅ only with real observed evidence.
> Umbrella issue: **#821** (Phase 2: TrueType typography & UI polish).
> Claim: **#905** (`agent/antigravity/m38-gui-typography`).
> GitHub milestone: **25 — M38 High-Fidelity Desktop & Vector Typography**.

## Where we are

M37 delivered the desktop quality foundation (Sexiburger overlay, tab strips,
snap guides, design tokens). PR #891 introduced the freestanding TrueType font
engine (`font_ttf.zig`) for Inter (proportional UI) and Fira Code (monospace
code/terminal). M38 connects this engine to the living desktop: auto-initializing
fonts on window creation, enabling anti-aliased alpha blending directly into
window backing surfaces, adapting widget layouts to proportional metrics, and
rolling out TrueType typography across core applications.

## The cards, in order

> **TT1 font lifecycle & blending → TT2 proportional widgets → TT3 God Menu & chrome → TT4 app rollout → TT5 live gates.**

| TT# | Card | Phase | Depends on | Status | Touches | Notes |
|----:|------|:------|------------|--------|---------|-------|
| TT1 | **Font lifecycle & surface blending** — auto-init fonts in `win_open()`; anti-aliased BGRA blending in `draw_alpha_mask()` for backing buffers | lifecycle | — | ✅ gate green 2026-09-03 | `user/src/lib/ui.zig`, `user/src/lib/font_ttf.zig` | Direct BGRA glyph alpha-blending via `blend_glyph_bgra` when backing buffer is present; fallback to batched spans when absent. Eager `MAP_POPULATE` allocation on user mmap. |
| TT2 | **Widget proportional metrics & text input cursor** — dynamic width measuring in Button, Label, TextInput, Dialog; proportional caret positioning | widgets | TT1 | ✅ gate green 2026-09-03 | `user/src/lib/ui.zig` | Caret X pos and mouse click placement calculated with `measure_text(text[0..cursor_pos])`; unit tests 94/94 PASS. |
| TT3 | **God Menu & desktop chrome typography** — Sexiburger sections, commands, shortcuts in Inter; window decorations & tab strip metrics | chrome | TT2 | ✅ gate green 2026-09-03 | `user/src/lib/sexiburger.zig` | Crisp typography and proportional spacing for command palette search cursor, category headers, shortcuts, and footer; unit tests 108/108 PASS. |
| TT4 | **Core desktop application typography rollout** — NOTEPAD, EDIT, CALC, DEVCONS | apps | TT2 | ✅ gate green 2026-09-03 | `user/src/notepad.zig`, `user/src/edit.zig`, `user/src/calc.zig`, `user/src/devcons.zig` | Inter for proportional UI; Fira Code for code editor syntax & terminal/dev console logs (`draw_text_mono()`); CALC digital display right-aligned via `measure_text()`. |
| TT5 | **Verification suite & live VZ gates** — unit tests, `verify-live-typography.sh`, doc updates | verification | TT1–TT4 | ✅ PASS 2026-09-03 | `tools/verify-live-typography.sh`, `docs/status.md` | Proves live TTF loading over virtio queue 5, glyph rasterization with zero stack overflow, and UI rendering on real VZ VM. Evidence in `artifacts/live-typography-*`. |

## Notes

1. **Zero-regression contract**: If font files are absent on `/host`, the toolkit falls back gracefully to `font8x8` bitmap rendering.
2. **BSS & Memory budget**: Font buffers are allocated via anonymous private `mmap`; zero static BSS overhead added for font tables.
