> ARCHIVED 2026-10-23 — design card fixed by ADR 0028; the shipped EL0
> consumer is `WEB.ELF`. Not an active plan.

# In-guest HTML renderer — scoping (M-web)

- Status: **S3–S6 implementation** (stacked on S2) — img, click-nav, fetch, publish behind `live-doc-web`.
- **Historical as of M71i #1568 (2026-09-21):** this document is the design
  card that ADR 0028 fixes, and the app it describes (`DOC.BIN`,
  `user/src/lib/html/`, the `live-doc*` specs) is deleted — the EL0 HTML
  consumer is `WEB.ELF` over `user/go/webrender`. Read the design decisions
  here; read ADR 0028 Amendment C for what shipped and where each rung's
  probe lives now. The paths named below are the record, not the tree.
- **M93a #1993 (2026-10-05):** [ADR 0028 Amendment D](../decisions/0028-html-renderer.md#amendment-d--m93a-1993-declared-css-subset-and-frozen-contract)
  proposes a declared CSS subset and block/flex layout for WEB.ELF.
  It awaits owner approval. The metrics, paths and UA-only restrictions
  below describe the historical slices, not an additional current contract.
- Claim: #1200 · Umbrella: #1201 · Slices: #1202 / #1203 / #1204 / #1205 / #1206 / #1207
- Related: ADR 0010 (userland storage), ADR 0011 (desktop platform),
  ADR 0016 (pixel ownership), ADR 0009 (app events), `tools/gate/SPEC.md`

## Why

Oliver already emits real HTML in-guest, byte-exactly pinned
(`tests/oliver-spike/expect.html`, 754 B, produced by Markdown → oliver and
verified against the host CLI's own output in #1191). Nothing in the OS can
show it. This card starts the other half of that pipeline:

```
Markdown --(oliver, in guest)--> HTML --(DOC.BIN, in guest)--> pixels
```

That is the first honest slice of browser-class UI, and it is deliberately the
smallest one: **a document viewer that renders what we already produce**, not a
browser. Getting this right means the markdown toolchain has an output path,
and every later slice (images, links, fetch) has a place to land.

## Non-goals for the whole arc (hard lines)

- **No JavaScript.** Not an interpreter, not a subset, not "later".
- **CSS policy:** historically one fixed UA table with no author styling.
  M93's proposed UA < author cascade is limited to Amendment D's closed
  subset, diagnostics and budgets. It takes effect only after owner approval;
  no unrestricted CSS engine is authorized.
- **No network until S5.** Fetching is S5 over the existing FETCH/HTTP
  seam, and only after the local render path is honest.
- **No kernel changes, no new syscalls.** The renderer is a userland app; the
  kernel never parses HTML. `kernel/src/**` stays untouched.
- **No layout engine beyond block + inline + a fixed table grid.** No floats,
  no flex, no positioning. S2 earns `table`/`thead`/`tbody`/`tr`/`th`/`td`
  as equal-width columns (cell padding, header rule) plus `dl`/`dt`/`dd`
  and `h4`–`h6`.

## What already exists (reuse, do not reinvent)

| need | existing seam | note |
|---|---|---|
| app skeleton, window, nav | `user/src/lib/tabapp.zig` — `init`/`dispatch`/`present`/`declare_nav`/`poll_nav`/`close_and_exit` | full-viewport TabApp app |
| argv + entry | `_start(argc, argv)` (`user/src/view.zig:714`); 32-byte argv slots | `exec DOC.BIN /host/PAGE.HTML` |
| file read | `ui.file_read(handle, buf)` in a loop, plus the ADR 0010 table | same path `view.zig` uses |
| text draw (UI font) | `ui.draw_text_sized(win, text, x, y, size, color)` | Inter, arbitrary size, per-glyph alpha |
| text measure (UI font) | `ui.draw_text_sized`'s twin `ui.measure_text_sized(text, size)` | the wrap input |
| mono text | `ui.draw_text_mono(win, text, x, y, color)` | **Fira Code, fixed size 13** |
| mono measure | `ui.measure_text_mono(text)` | matches the above |
| colors / tokens | `user/src/lib/ui/theme.zig` — `theme_bg`/`theme_surface`/`theme_text_primary`/`theme_accent`, `font_size_tab_title` (14) / `font_size_badge` (11) | light+dark both resolve |
| fills / rules | `ui.draw_rect`, `ui.win_fill_batched` | hr, blockquote bar, backgrounds |
| **word wrap** | **`notepad.zig` `TextLayout`** (claim 1771): `last_space(buf, start, limit)` break finding, `cols`/`visible_rows`, offsets→display rows, with tests | the wrap *rule* we adopt |
| error degradation | `view.zig`: missing/bad input renders an on-screen error, window stays open, nothing panics, exit status 43 | the behaviour we copy |

Two honest caveats found while writing this card:

- **EDIT is not the precedent.** `edit.zig` has a `word_wrap` *toggle* whose
  chunking is inline in its paint loop (`@min(llen - chunk_off, max_c)`), not a
  reusable function. NOTEPAD's `TextLayout` is the tested, offsets-to-rows
  rule; slice 1 implements that rule as a pure function so EDIT can adopt it
  later if anyone wants to.
- **There is no bold or italic face.** `ui.init_fonts` loads exactly
  `/host/INTER.TTF` (UI) and `/host/FIRACODE.TTF` (mono, size 13). So the UA
  stylesheet cannot map `<strong>`/`<em>` onto real faces (ADR 0028 D4 records
  the choice): `<strong>` is **synthetic bold** (a second 1-px-offset strike)
  and `<em>` takes the accent color. Both are revisitable the day a bold or
  italic face is vendored.

## Layout model

Deliberately the smallest model that renders `expect.html` well:

```
page width  -> content box  = window width  - 2*page_margin          (page_margin 10)
block box   -> stack top-to-bottom; each box contributes
               margin_before + content height + margin_after
inline run  -> glyphs measured with measure_text_sized(text, size)
               wrapped at the last space (TextLayout's rule) into line boxes
               line_h = size + leading (per-tag)
```

Per-tag UA style table (slice 1) — the whole "stylesheet":

| tag | size | before/after | indent | notes |
|---|---|---|---|---|
| `h1` | 24 | 12 / 8 | 0 | |
| `h2` | 18 | 10 / 6 | 0 | |
| `h3` | 15 | 8 / 4 | 0 | |
| `h4` | 14 | 8 / 4 | 0 | |
| `h5` | 13 | 6 / 3 | 0 | |
| `h6` | 12 | 6 / 3 | 0 | |
| `p` | 14 | 0 / 8 | 0 | |
| `ul`/`ol` | 14 | 4 / 4 | +16 (nested +16) | `li` marker drawn in the gutter |
| `dl` | 14 | 4 / 4 | 0 | `dt` synthetic bold; `dd` indent +16 |
| `blockquote` | 14 | 6 / 6 | +12 | 2 px accent bar in the gutter |
| `pre` | 13 (mono) | 8 / 8 | +8 | surface background, **not** wrapped |
| `code` (inline) | 13 (mono) | — | — | surface background per run |
| `hr` | — | 8 / 8 | 0 | 1 px border rule |
| `table` | 13 | 8 / 8 | 0 | equal-width cols from the first row; extra cells dropped |
| `th`/`td` | 13 | 0 / 0 | 0 | cell pad 4; `th` surface fill + header rule + synthetic bold |
| `a` | 14 | — | — | accent color, no underline affordance yet (not clickable) |
| `br` | — | — | — | forces a line break inside the run |

Inline styling composes inside a run: `strong` (synthetic bold), `em`
(accent), `code` (mono segment), `a` (accent + recorded link target).

**Unknown or unsupported elements degrade to their text content** — never
dropped, never a crash. Slice 1 applied this to the oliver fixture's
`<table>`; slice 2 lays that table out as a grid. Remaining unknown tags
(including `<img>` until S3) still flatten to document-order text.

### Whitespace (pinned)

HTML whitespace is a layout input, not an accident of the source file. Slice 1
pins the following and the parser tests lock it:

- **Normal flow** (everything except `pre` and `code`): any run of ASCII
  whitespace (`SP` / `HT` / `LF` / `CR`) collapses to a single `SP`. Leading
  and trailing space at a block boundary (`h1`–`h3`, `p`, `li`, `blockquote`,
  `ul`/`ol`, `pre`, `hr`, and the document root) is dropped. A `<br>` is a
  forced break, not a space.
- **`pre` and `code`:** whitespace is preserved. `CR` and `CRLF` become `LF`;
  nothing is collapsed. `pre` does not wrap (S1 clips horizontal overflow).
- **Entities** decode before whitespace collapsing (`&nbsp;` is `0xA0` and
  does not collapse). Numeric entities above U+00FF (the draw path is a `u8`
  glyph index) become `?` — an em dash (`&#8212;`) therefore renders as `?`
  until the paint path grows a UTF-8/U+ codepoint seam. S1 records that
  substitution rather than pretending Inter's em-dash glyph is reachable.

## Seams: parse → layout → paint

Three modules, two of them pure and host-testable with no framebuffer:

1. `user/src/lib/html/parse.zig` — tokenizer + tree builder.
   `parse(bytes, arena) -> Document`. Output is a flat node array with
   parent/child/sibling indices (no pointers, no allocator in the tree).
   Handles: start/end/self-closing tags, attribute extraction (`href`), raw
   text in `pre`/`code`, named + numeric entities (`&amp;` `&#8212;` `&#x2014;`),
   and implicit paragraph/list-item grouping.
2. `user/src/lib/html/layout.zig` — `layout(doc, style, width) -> Layout`
   (block boxes with a line-box list, each line carrying byte ranges + style
   flags). Pure: the measure function is injected, so tests use a stub
   measure (8 px/char) instead of a real face.
3. `user/src/doc.zig` — the app: argv, file read, `TabApp`, paint from
   `Layout` via `ui`, keyboard scroll, status line, error degradation, and
   the serial markers. Paint is the only part that touches the framebuffer.

Static limits, no heap: the file bytes come from an anonymous mmap region
(M29 slot 63, the `view.zig` pattern), the node array and line array are
fixed-capacity (`max_nodes`, `max_lines`) with a documented overflow rule
(truncate + a marker line, never a panic).

## Slice ladder

| slice | scope | issue |
|---|---|---|
| **S1** | the tags above minus the S2 grid, local file, keyboard scroll, error path, `live-doc` | #1202 |
| **S2** | tables (`table`/`thead`/`tbody`/`tr`/`th`/`td`), `dl`/`dt`/`dd`, `h4`–`h6`, nested-list polish, `live-doc-tables` | #1203 |
| **S3–S6** (this) | `<img>` (png/qoi), click-nav, `DOC.BIN <url>` fetch, oliver-publish + HTTPD png/qoi MIME, `live-doc-web` | #1204–#1207 |

## Gate shape (class B, declarative spec only)

`tools/gate/specs/live-doc.spec` (S1), `live-doc-tables.spec` (S2), and
`live-doc-web.spec` (S3–S6: img, click-nav, fetch, publish — four boots).

- **staging**: `vgate_setup_python` copies `tests/oliver-spike/expect.html`
  (the pinned oliver output, 754 B) and `zig-out/bin/DOC.BIN` into the share.
- **one invocation per boot** (the #1197 lesson: `exec` returns immediately, so
  a second invocation in the same script races the first). Each boot ends on a
  marker the **program** prints, never on a script echo.
- **boots**: 01 renders the pinned page (the main proof); 02 takes a *missing*
  file and must show the on-screen error; 03 renders a second fixture that is
  explicitly a truncated/corrupt page to keep the degradation path honest.
- **assertions**: serial markers for the parse/layout counts and the settle
  point, plus `snapshot` pixel probes in the framebuffer capture —
  page background, dark text ink inside the `h1` band, the blockquote indent
  bar, a mono (Fira) block region, and the `hr` rule.
- **S2 staging**: copies `tests/oliver-spike/tables.html` (short: h4 + 2×2
  table + dl) so th surface, header rule, both columns, and dd indent are
  on-screen. Oliver's own table stays below the fold and is not the S2
  pixel fixture.
- **assertions**: serial `doc: probe2 table=/h4=/dt=` plus snapshot probes —
  page background, h4 ink, th `theme_surface` fill, left+right column ink,
  header-rule border, dt/dd ink.

## Risks and open questions

- **Inter at heading sizes is unverifiable until probed.** `draw_text_sized`
  falls back to the 8x8 bitmap per glyph if a face/glyph is missing; a font
  that failed to load would silently change every metric. The gate's glyph
  probes must distinguish "Inter rendered" from "fallback rendered" — the
  `live-typography` markers plus the h1 ink probe are the guard.
- **Mono has exactly one size (13).** If a slice wants sized code text, that is
  a `draw.zig` change plus its own tests, not a layout decision.
- **Vertical scroll only.** Horizontal overflow in a `pre` is clipped in S1 and
  is the first thing to fix if the fixture ever needs it.
- **No font fallbacks for non-ASCII.** Entities like `&#8212;` (em dash) map to
  a glyph only if the loaded face has it; otherwise the fallback path draws the
  bitmap glyph or nothing. S1 asserts an em dash renders *something* and
  records which.
- **Where the UA stylesheet lives** is deliberately a compiled-in table, not a
  data file: it keeps the app read-only over the file channel and makes the
  gate's pixel expectations stable.
