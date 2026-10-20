# `user/go/draw` — UI primitives contract (chrome design language + API)

Status: **contract v2** · Date: 2026-10-14 · Owner: M104a (issue #2268) ·
implemented: M104b–h (#2269–#2275) ·
v1: 2026-09-27, M86a (#1817) — v1's frozen names are unchanged ·
Source of truth for: M86b (#1818, glyph batch 1), M86c (#1819, shape
renderer), M86d (#1820, published API + adoption), and the M104 depth +
adoption arc (cards b–h) ·
Arc index: M86 (#1816) · M104 (#2267)

> A fresh author can implement or call every primitive from this document
> alone. §3 is the API — M86c implemented the v1 block and M104b implements
> the v2 block; neither renegotiates it. §2 is the taste — chrome drawn to
> any other geometry is off-contract. §4 is the glyph inventory — M86b
> shipped batch 1, M104g draws batch 2. §5 is the consumer map: a control
> or primitive exists only where a pixel-painting caller forces it.
> Values are tagged **(observed)** when measured from existing code and
> **(decision)** when this doc lands the choice.

This is the visual-design spec ADR 0008 deliberately deferred ("Colors,
spacing, and exact glyphs stay in the theme/Driving Award implementation;
this ADR fixes *behavior and discoverability*, not pixels"). ADR 0008 D4
("focus is always visible") stays binding on everything here.

**v2 in one paragraph.** M86 shipped the engine and the desktop never
adopted it: the Go seat hand-rolls `drawText8` over raw scanout
(`gotabwm/chrome.go:278`), the widget kit paints fill-only rects through
the pre-M86 `RectCanvas`, and every pixel-painting app but `appkit/demo`
writes through `vi.Filler`. v2 adds the depth block to §3.1 (drop shadow,
vertical gradient, scaled blit, arc pair, clip stack), records the M99o
linear-light blending revision in §3.3.2, gives widgets a `*ttf.Face`
label path in §3.4 that keeps `widgets → draw` impossible, extends §4
with batch-2 glyphs, and lands §5's controls inventory + adoption audit.
Everything here is Go-side: the kernel and the Zig seat are untouched.

## 0. What this is — and is not

- **Is:** the chrome design language (§2), the primitive API contract (§3),
  and the chrome glyph inventory (§4). Primitives, not a framework.
- **Is not:** a widget toolkit (the kit is `Text`, `Button`, `List`,
  `TextInput` plus M104d's four controls), a layout engine, SVG (explicit
  non-goal), a retained-mode scene graph, a theme editor, or an ADR. The
  roadmap's standing guardrail applies: "someone lovingly architects
  GTKvirelai before anyone has clicked a button" — nothing in this contract
  grows without a named consumer.

## 1. Where primitives live — the buffer model

- **Package `user/go/draw`, userland only.** Pixel ownership is Seam B (M33):
  apps own their buffers and paint their own pixels; the seat composes. The
  engine is a pure raster library over a caller-owned pixel buffer — **zero
  kernel change**, no draw-slot work (ADR 0030/0034: the code is Go).
- **Pixel format (decision, matching observed reality):** colors are
  `uint32` **0xAARRGGBB** (alpha in the top byte; little-endian memory order
  B,G,R,A — the scanout's B8G8R8X8 and `user/go/ttf`'s blending format).
  Two hard rules: alpha `0x00` renders **transparent** (the scanout treats
  X/A=0 as transparent — hardware contract), and drawing with `rgb` alpha 0
  is a **no-op**, never an eraser.
- **`widgets.Canvas` widens, `FillRect` never changes.** §3.2 widened the
  interface to four methods in v1 and adds a fifth (`Text`) in v2;
  `FillRect`'s signature is frozen so the widgets and every recording test
  stay green (the zero-regression fixed point).
- **Canvas implementations:**
  - `draw.BufferCanvas{Pix []u32, W, H int}` — the real one; every §3.3
    guarantee holds, and the whole v2 depth block lives here.
  - `draw.FillerCanvas` — the legacy `vi.Filler` adapter: `FillRect` batches
    as today; every other method degrades deterministically (hard-edged
    rects; `Text` repaints through the bitmap face — §3.4).
  - `draw.BytesCanvas` / `draw.WindowCanvas` (**observed**, `canvas.go`) —
    view a caller-owned BGRA buffer or mmap a Seam-B window surface. The
    v1 "where an app gets `[]u32`" gap is **closed**; `appkit/demo` binds
    `WindowCanvas` today.
- **Named gap (v2) — resolved (M104f, #2273):** `WindowCanvas` mmaps
  once at bind — at scanout size — and `tabapp.Dispatch`'s `WIN_RESIZE`
  arm re-views the same pages at the new tight stride (reflow-style
  overlap copy), never remaps. The resize path is shipped.
- **`FillerCanvas` sunset policy (v2 decision):** **kept** — it is the
  documented degrade path, the zero-regression adapter for surfaces that
  cannot mmap, and ~40 lines. It is *not* deprecated: removal would be a
  §6 revision whose precondition is zero remaining callers, and this
  contract does not schedule it. The design-language consequence: a
  FillerCanvas surface renders the flat v1 look — borders, ramps, and
  bitmap labels intact; shadows/gradients/AA text simply do not appear.

## 2. The chrome design language

### 2.1 Color roles — mapped onto `user/go/theme`

Roles come from `theme.Tokens` (**observed**: the M69c #1530 table; dark is
byte-identical to Zig `THEME_DARK`/`CHROME_DARK`). Apps carry no hex
(`theme.go`: "Tokens are data, not a framework"). v2 adds the three
depth/adoption roles — Go-only columns; no Zig table carries them.

| Role | Token | Notes |
|------|-------|-------|
| Window / app background | `Bg` | |
| Chrome plate (title bars, toolbars) | `Surface` | |
| Recessed panels (inputs, code, gutters) | `ChromeBg`, `Gutter` | |
| Borders / rules | `Border`, `Rule` | 1px |
| Text / secondary text | `Text`, `Muted`, `InkMuted` | |
| Accent (selection, active, caret) | `Accent`, `Caret`, `Selection` | |
| Text on accent | `OnAccent` | |
| Button faces | `BtnIdle` → `BtnHover` → `BtnPressed` | the state ramp |
| Status | `Success`/`Ok`, `Danger`, `Warning` | |
| Focus ring | `Accent` at `FocusW` | ADR 0008 D4 |
| Drop-shadow ink **(v2)** | `Shadow` | §2.5 supplies offset/blur/alpha |
| Seat desktop gradient **(v2)** | `WallpaperTop`, `WallpaperBot` | kernel `wallpaper_top/bot` values |

**Resolution order (decision):** `theme=custom` resolves
`palette_bg→Bg`, `palette_fg→Text`, `palette_accent→Accent` (+`OnAccent`
for contrast) **at paint** (the M73m rule); `theme=dark|light` selects the
table; the boot default is `dark`. `theme.Set` refuses unknown names — a
typo never invents a third palette.

### 2.2 Geometry

- **Spacing scale (observed):** `PadXS=2`, `PadSM=4`, `PadMD=8`, `PadLG=16`
  (`theme.Tokens`). All chrome insets come from this scale; a composed value
  may sum two adjacent steps (e.g. `12 = PadMD + PadSM`). Legacy chrome that
  predates the scale keeps its measured value until its M104f migration
  redraws it (e.g. `appkit/dialog.go`'s `Inset(12)`, `gotabwm/chrome.go`'s
  `chromePad=6`).
- **Corner radii (decision):** `radiusControl = 4` (buttons, inputs, list
  plates), `radiusWindow = 8` (dialogs, panels, popovers), `radiusPill =
  r.h/2` (capsules — the tab-pill rule; also the M104d toggle track).
  Radius clamps to `min(w,h)/2`.
- **Strokes (observed):** `BorderW = 1` for every border; `FocusW = 2` for
  focus rings, drawn **inside** the bounds (no layout shift).
- **Title bar (decision, clarified v2):** height **28** (a 16px face + 6px
  above and below — `gotabwm/chrome.go`'s face+`chromePad` composition,
  measured at the 8px face where `ChromeH=20`), title left-aligned at
  `PadMD` inset, window controls right-aligned in the order minimize ·
  maximize · close (close rightmost), 16×16 each with `PadSM` gaps.
  **Where it applies (v2 answer, observed):** the 28px bar is the Go
  design language's floating-chrome spec — `appkit`'s dialog title row
  already implements it, and any future Go-drawn floating window uses it.
  Under the Go seat (`gotabwm`, the default boot) windows are
  full-viewport tabs: **no per-window title bar exists at all** — the
  seat's rail is the tab identity, not a title bar. The kernel's 16px
  `wnd_core.title_bar_h` band is a different artifact: the `wnd` path's
  own chrome, pinned by `live-chrome`, and it stays
  the kernel's business — while a registered seat owns the user layer the
  kernel skips its blit entirely (`driving_award.zig:4839-4893`,
  `wm_owns_user_layer`). This arc needs no kernel work; restyling the
  `wnd` band would be a separate kernel card, out of M104.
- **Type:** UI text rides `user/go/ttf`; chrome labels at 13px (**observed**
  parity with the terminal's 13px FiraCode face); icons per §4.

### 2.3 States

Interactive chrome (buttons, list rows, tabs — and, v2, the M104d
controls) has exactly these states:

1. **default** — face `BtnIdle` (or `Surface`), border `BorderW`/`Border`.
2. **hover** — face `BtnHover`.
3. **pressed** — face `BtnPressed`. For drag-driven controls (scrollbar
   thumb, slider knob) this is the *dragged* state.
4. **disabled** — label `Muted`, face `BtnIdle` blended 50% toward `Surface`
   (integer blend, deterministic); never brighter than default.
5. **focused-visible** — the 2px `Accent` focus ring, inside bounds. Focus
   is always visible (ADR 0008 D4) and never color-only.
6. **selected** (lists, tabs, dropdown rows, toggles) — fill `Selection`
   plus the **3px `Accent` left-edge marker** (**observed**: the Zig tab
   chrome's `3×22` accent bar). A toggle's on-state uses the same
   vocabulary: `Accent` track, not a fourth hue.

### 2.4 Chrome anatomy

- **Title bar:** plate `Surface`, 1px `Border` bottom rule, title `Text`,
  controls per §2.2. Hovering **close** tints its glyph `Danger`; hover on
  the others tints `Muted`→`Text`.
- **Buttons:** `radiusControl` plate, `BorderW` border, the §2.3 ramp, label
  `Text` centered at `PadSM` horizontal padding; the default button in a
  dialog draws its `Accent` border + `OnAccent` label.
- **Dialogs:** `radiusWindow` plate (`Surface`), `BorderW` border, the §2.5
  shadow, content inset `PadMD + PadSM`, title row, message, button row
  right-aligned with `PadSM` gaps.
- **Lists/rows:** row height 24 (**observed**: `appkit`'s input row
  `H: 24`), selection + hover per §2.3.

### 2.5 Depth (v2)

Depth is five primitives, not a renderer. The taste rules:

- **Shadow (decision):** floating plates — dialogs, dropdown/popover
  lists, the launcher surface, toasts, the god menu — cast one shared
  shadow: `dy = 4` (`PadSM`, straight down), `blur = 16` (`PadLG`), ink
  `Shadow` at peak alpha `0x40` (25%). Content, controls, and list rows
  cast none: elevation is for floating chrome only, and one shadow
  geometry keeps the desktop coherent.
- **Gradient (decision):** the seat desktop is the gradient's one
  sanctioned surface — vertical `WallpaperTop`→`WallpaperBot`, the
  kernel's `wallpaper_top`/`wallpaper_bot` values
  (`driving_award.zig:1041-1057`), so a Go-seat desktop and the kernel's
  fixed layer read identically. Control faces never gradient: flat face +
  `Border` is the design language.
- **Rings:** `StrokeArc` paints progress/volume affordances (GOSOUND's
  transport readout is the first consumer); `FillArc` covers wedge
  gauges. A ring is `Accent` on a `ChromeBg` track — the §2.3 accent
  vocabulary, not a new color.
- **Clip:** scrolled content (list rows, dropdown popups) clips through
  the §3.1 clip stack; chrome chrome never overlaps a plate edge.

## 3. The primitive API contract

### 3.1 Types and engine functions (M86c implemented the v1 block; M104b implements the v2 block — exactly these)

```go
package draw

type Point struct{ X, Y int }

// BufferCanvas is a caller-owned pixel buffer. Pix has len W*H, row-major,
// stride W, pixels 0xAARRGGBB.
type BufferCanvas struct {
	Pix []uint32
	W, H int
	// v2: plus an unexported fixed clip stack (ClipDepth entries); the
	// zero value clips to the whole canvas.
}

// Geometry — all clip to the canvas, all allocate nothing (except the two
// polygon calls: bounded scratch, documented below).
func FillRect(c *BufferCanvas, r widgets.Rect, rgb uint32)
func FillRoundedRect(c *BufferCanvas, r widgets.Rect, radius int, rgb uint32)
func StrokeRoundedRect(c *BufferCanvas, r widgets.Rect, radius, weight int, rgb uint32)
func FillEllipse(c *BufferCanvas, r widgets.Rect, rgb uint32)
func StrokeEllipse(c *BufferCanvas, r widgets.Rect, weight int, rgb uint32)
func FillPolygon(c *BufferCanvas, pts []Point, rgb uint32)      // bounded scratch
func StrokePolyline(c *BufferCanvas, pts []Point, weight int, rgb uint32) // bounded scratch
func StrokeLine(c *BufferCanvas, x0, y0, x1, y1, weight int, rgb uint32)

// Compositing — the glyph/image path.
func BlendPixel(c *BufferCanvas, x, y int, rgb uint32)          // one AA pixel
func BlitTinted(c *BufferCanvas, src *BufferCanvas, x, y int, rgb uint32) // tint by src alpha

// ---- v2 depth block (M104b) --------------------------------------------

// FillShadow paints the drop shadow of the rounded-rect silhouette r
// translated (0, dy): coverage is a linear ramp of signed distance from
// the silhouette edge, falling to zero blur px outward; rgb's own alpha
// sets the peak (§2.5). blur == 0 paints the translated silhouette — a
// legal hard offset plate. Distances are eighth-pixel integers; corner
// distance uses integer isqrt. There is no blur buffer and no dx:
// drop shadows fall straight down in this design language.
func FillShadow(c *BufferCanvas, r widgets.Rect, radius, blur, dy int, rgb uint32)

// FillLinearGradient fills r top-to-bottom, rgbTop -> rgbBot, one integer
// channel-lerp per row in encoded sRGB (§3.3.2). Vertical only — a
// horizontal or diagonal variant waits for a consumer (§6).
func FillLinearGradient(c *BufferCanvas, r widgets.Rect, rgbTop, rgbBot uint32)

// BlitScaled paints src into dst at an arbitrary integer ratio — the
// upscale/downscale path for images and icons (GOVIEW and the seat's
// emblem are the consumers; gotabwm already hand-rolls a premultiplied
// box filter in launcher.go:167). Bilinear, 16.16 fixed-point weights,
// channels lerped premultiplied then composited by the §3.3.2 shape
// rule. An empty dst or invalid src is a no-op.
func BlitScaled(c *BufferCanvas, src *BufferCanvas, dst widgets.Rect)

// FillArc fills the elliptical wedge inscribed in r from startDeg through
// sweepDeg; StrokeArc strokes it as a weight-px annular band (progress
// and volume rings). Angles are integer degrees, 0 at 12 o'clock,
// positive clockwise (screen space, y down). startDeg normalizes mod
// 360; sweepDeg clamps to [0,360]; 0 paints nothing. Boundary directions
// are 16.16 fixed-point unit vectors; the wedge test is two cross-product
// sign checks per sample on the same 4x4 subpixel grid.
func FillArc(c *BufferCanvas, r widgets.Rect, startDeg, sweepDeg int, rgb uint32)
func StrokeArc(c *BufferCanvas, r widgets.Rect, weight, startDeg, sweepDeg int, rgb uint32)

// Clip stack — the canvas, not the call, owns the clip. PushClip
// intersects r with the active clip; PopClip restores the previous one;
// Clip reports the active clip for damage/early-out callers. The stack
// is a fixed array: a push past ClipDepth and a pop at depth 0 are
// deterministic no-ops (the §3.3.6 clamp rule, applied to state).
// Every §3.1 primitive, v1 and v2, clips to
// intersect(active clip, canvas bounds); at depth 0 that is the canvas,
// so every v1 caller is already correct.
const ClipDepth = 8
func (c *BufferCanvas) PushClip(r widgets.Rect)
func (c *BufferCanvas) PopClip()
func (c *BufferCanvas) Clip() widgets.Rect
```

`widgets.Rect` (right/bottom exclusive — **observed** `widgets.go:25`) is
the one rectangle type; `draw` does not define a second. Dependency
direction is fixed: **`draw` imports `widgets`; `widgets` never imports
`draw`** — §3.2 takes raw sprite pixels precisely so the cycle cannot
form, and §3.4 keeps the same wall for text.

**Refused (v2 — recorded per §6):**

- `StrokeShadow` — no pixel consumer: nothing paints an outlined floating
  plate, and its annular distance ramp doubles per-pixel cost over the
  filled silhouette. A consumer can reopen it by revision.
- Horizontal/diagonal gradients — no consumer; the seat desktop and every
  plausible plate gradient are vertical.
- Clip fields/parameters on individual calls — a per-call clip duplicates
  `clip`-carrying entry points (`Text` already takes one) and invites
  divergent semantics; the stack is the one clip mechanism.

### 3.2 The widened `widgets.Canvas` (M86d published four methods; v2 adds one)

```go
type Canvas interface {
	FillRect(r Rect, rgb uint32)                                  // frozen, unchanged
	FillRoundedRect(r Rect, radius int, rgb uint32)
	StrokeRoundedRect(r Rect, radius, weight int, rgb uint32)
	BlitTinted(src []uint32, srcW, srcH, x, y int, rgb uint32)     // raw sprite pixels; icon + image path
	// v2: the widget label path (§3.4). A nil face must degrade,
	// never blank the label.
	Text(face *ttf.Face, clip Rect, x, y, size int, s string, rgb uint32)
}
```

Exactly five methods. The v2 depth block stays **off** the interface —
no widget paints a shadow, gradient, scaled blit, arc, or clip stack, and
every consumer of those (appkit plates, the seat, GOVIEW) reaches
`*draw.BufferCanvas` directly. The rule is unchanged: the interface grows
only when a widget makes the call, and M104c's widget labels are that
call. Recorders implement `Text` as record-and-continue, same as the v1
widening.

`Text`'s implementations (**decision**): `*BufferCanvas` forwards to
`draw.Text` — the shared mask path, linear light, identical edges to app
text. `*FillerCanvas` repaints the run through `widgets.DrawText` with
`clip` as the plate — the 8×8 bitmap face — so a filler surface keeps
legible labels instead of glyph bounding boxes (legal:
`draw → widgets` is the existing direction).

### 3.3 AA guarantees (normative — goldens pin every one)

1. **Coverage-based anti-aliasing.** Edge pixels blend in proportion to
   coverage (≥16-sample-equivalent for curves). **Integer/fixed-point math
   only** — the engine contains no floating point (guest determinism; the
   same rule `widgets.Scale` follows). v2 additions honour this: shadow
   falloff and gradient stops are integer ramps, `BlitScaled` weights are
   16.16, arc boundaries are fixed-point vectors.
2. **Blending is two rules, one per substrate (revised v2 — records M99o,
   #2192):** glyph-mask coverage composites in **linear light** through
   `ttf.CoverageBlend` (`ttf/raster.go`, the one shared helper — used by
   `draw.Text`'s BufferCanvas path, `ttf.Blend`, and MaskSink
   implementations); every **shape and image** composite stays
   straight-alpha source-over in **encoded sRGB**, no gamma correction.
   **v2 decision:** the depth block interpolates in sRGB — shadow falloff
   alpha ramps, gradient channel lerps, and `BlitScaled`'s filter — because
   linear light exists to keep thin glyph edges perceptually faithful over
   arbitrary backgrounds, and a decorative ramp has no high-contrast edge
   to protect; keeping shapes in sRGB also means `blend` stays the single
   shape compositor.
3. **Determinism:** identical inputs produce bit-identical output on any
   host. No map iteration order, no goroutine races in the engine.
4. **Clipping (revised v2):** every primitive clips to
   `intersect(active clip stack, [0,W)×[0,H))`; the §3.1 stack's depth-0
   clip is the whole canvas, so v1 callers are unchanged. Out-of-bounds
   draw calls are dropped, never panicked; empty rects (`W<=0 || H<=0`)
   are no-ops.
5. **Strokes** render **inside** the given bounds/path (matching `FocusW`'s
   inside rule); `weight` is in pixels and symmetric about the path.
   `StrokeArc` follows the same rule: the band lives inside `r`.
6. **Radii** clamp to `[0, min(w,h)/2]`; `weight` clamps to `[0, min(w,h)]`
   and `weight 0` draws nothing; `sweepDeg` clamps to `[0,360]` and a push
   past `ClipDepth` or a pop at depth 0 is a no-op. A bad argument is
   clamped deterministically (and refused loudly in tests) — never a
   guest crash.
7. **Hot-path allocation:** rect/rounded-rect/ellipse/line calls allocate
   nothing; `FillPolygon`/`StrokePolyline` use bounded scratch (≤ one
   scanline buffer per call). The v2 block adds nothing to the heap:
   shadow falloff is analytic, gradient rows are per-row lerps, arc tests
   are per-sample sign checks, `BlitScaled` is per-pixel, and the clip
   stack is a fixed array on the canvas.

**Behavior reference (observed prior art):** the Zig
`user/src/lib/ui/draw.zig:1019` `fill_rounded_rect_buf` — 4-way subpixel
quarter-circle AA, 99/99 geometry tests. Where §3.3 and that behavior
disagree, §3.3 wins, but the divergence is recorded in the goldens.

### 3.4 Widgets and TrueType faces (v2)

**The decision:** widgets import `virelai/ttf` directly and paint labels
through `Canvas.Text` (§3.2). The import is acyclic — `ttf` imports only
`virelai/icons` — so `widgets → draw` remains impossible and the existing
`draw → widgets` direction is unchanged. This fixes M104c's whole shape:
`Widget.Draw(c RectCanvas)` type-asserts to `Canvas`, which is the
zero-regression mechanism the card already plans.

- **The field.** `Text`, `Button`, `List`, `TextInput` (and appkit's
  `TextField`) gain `Face *ttf.Face` — optional, default nil. **The app
  owns the face's lifecycle**: it loads via `draw.LoadRegistry` /
  `draw.ReadFont` (or hands down the face `appkit.Dialog` already takes)
  and assigns. `theme` deliberately does not carry the face: a
  `theme → ttf` edge would drag the rasterizer into every `theme`
  importer — all the `tabapp` apps and the seat — for a dependency most
  never dereference, and a face is a resource with a failure mode, not
  palette data. Widget labels take a single face, not a `ttf.Chain` —
  chrome strings are ASCII; the cascade stays an app-level tool
  (browser).
- **The paint path.** With `Face != nil` and a full `Canvas`, a label
  runs through `Canvas.Text` at §2.2's 13px, vertically centered by
  `face.LineMetrics` — `y = plate.Y + (plate.H-asc-desc)/2 + asc`, the
  formula `appkit`'s `dialogText` already uses. On `*BufferCanvas` that
  is the linear-light `draw.Text` path: widget labels and app text get
  identical edges.
- **The bitmap fallback rule (normative):** `Face == nil` — never set,
  or a failed font load leaves it nil — or a canvas that satisfies only
  `RectCanvas` → `drawGlyphRun` unchanged: the 8×8 bitmap face that
  paints today. On `FillerCanvas`, `Canvas.Text` itself degrades to the
  bitmap face (§3.2), so filler surfaces keep legible labels rather than
  glyph bounding boxes. Every case collapses to two rules: **no face →
  bitmap; no full canvas → bitmap** — and a failed load is just the nil
  face, so the boot never blanks a label.
- **Rejected:** masks through `Canvas.BlitTinted` with no `Text` method
  (splits widget text into the sRGB blend — exactly the defect M99o
  fixed — duplicates `draw/text.go`'s mask plumbing inside widgets, and
  leaves `FillerCanvas` painting per-glyph bounding boxes); faces
  appkit-only (leaves the kit on the bitmap face — M104c's reason to
  exist); a theme-carried face (above).

## 4. Glyph inventory

**Rendering rule:** glyphs are font glyphs drawn through `user/go/ttf`
(outline font ⇒ any size), **tinted** via `BlitTinted`/`BlendPixel` with a
§2.1 role color. A glyph is never baked in a color. Style (**decision**):
geometric, single-weight, filled silhouettes over hairlines (they must read
at 12px), rounded terminals.

**Codepoints:** Private Use Area. Batch 1 (M86b shipped) is
`U+E000`–`U+E013`; batch 2 (v2, M104g draws) continues `U+E014`–`U+E01D`.
Both live in **VirelaiChrome** — never Virelai Sans, whose own `U+E001`
is the sexiburger mark; the fonts are separate files with separate cmap
ranges. The tables are normative; the asset ships as `user/go/icons` +
`image/fonts/` (with its license file — the Inter/Fira pattern).

### Batch 1 (frozen — M86b shipped exactly these twenty)

| CP | Name | Shape | Primary use |
|----|------|-------|-------------|
| `U+E000` | `window-close` | ✕ | title bar close |
| `U+E001` | `window-minimize` | – | title bar minimize |
| `U+E002` | `window-maximize` | □ | title bar maximize |
| `U+E003` | `window-restore` | overlapping squares | restore from maximize |
| `U+E004` | `window-pin` | pin | always-on-top on |
| `U+E005` | `window-unpin` | open pin | always-on-top off |
| `U+E006` | `chevron-left` | ‹ | back / collapse |
| `U+E007` | `chevron-right` | › | forward / expand |
| `U+E008` | `chevron-up` | ^ | sort up / scroll |
| `U+E009` | `chevron-down` | v | sort down / dropdown |
| `U+E00A` | `check` | ✓ | confirm / selected |
| `U+E00B` | `plus` | + | new tab / add |
| `U+E00C` | `search` | magnifier | find |
| `U+E00D` | `settings-gear` | gear | settings |
| `U+E00E` | `folder` | folder | file manager |
| `U+E00F` | `file` | page | file manager |
| `U+E010` | `warning-triangle` | ⚠ | warnings |
| `U+E011` | `error-circle` | ✕ in circle | errors |
| `U+E012` | `info-circle` | i in circle | notices |
| `U+E013` | `lock` | padlock | trust / locked state |

### Batch 2 (v2 — M104g draws exactly these ten)

Each line names the consumer that forces it — controls (M104d) and the
seat (M104e); the 16px-em/readable-at-12px style rule is unchanged.

| CP | Name | Shape | Consumer |
|----|------|-------|----------|
| `U+E014` | `menu` | three horizontal bars | seat "Apps"/god-menu affordance (today a text label) |
| `U+E015` | `kebab` | three vertical dots | row-overflow affordance — notify-center rows, dropdown buttons |
| `U+E016` | `media-play` | ▶ | GOSOUND transport row (today a `p/space` key legend) |
| `U+E017` | `media-pause` | ‖ | GOSOUND transport row |
| `U+E018` | `media-stop` | ■ | GOSOUND transport row (`s` key) |
| `U+E019` | `bell` | bell | seat clock/notify affordance + notify center |
| `U+E01A` | `bell-dnd` | slashed bell | seat DND state (`notify_dnd` settings row) |
| `U+E01B` | `volume` | speaker | GOSOUND + goset `audio_volume` row |
| `U+E01C` | `volume-mute` | slashed speaker | `audio_volume=0` / muted state |
| `U+E01D` | `resize-grip` | diagonal grip marks | the floating-surface resize affordance class — no painter exists yet; allocated now so future chrome does not reopen §4 |

**Sizes (decision):** designed on a **16px em grid**; rendered at 12, 16
(nominal), or 20 px. **Every shape must read at 12px** — the golden QA bar.

Deferred until a pixel consumer names them: `media-prev`/`media-next`
(GOSOUND has no track skip), `power`, a network status set.

## 5. Consumers and sequencing

### 5.1 The M104 cards

| Card | Consumes | Delivers |
|------|----------|----------|
| M104b (#2269) | §3.1 v2 block, §3.3 | the depth engine + per-primitive goldens + a 1280×720 composite benchmark |
| M104c (#2270) | §3.2 `Text`, §3.4 | widget faces on the kit, the §2.3 ramp on all four widgets — recording tests stay green |
| M104d (#2271) | §2.3, §5.2 | the four controls below + `appkit/demo` showcase |
| M104e (#2272) | §2.5, §3.1, §4 | every `gotabwm` painter on `BytesCanvas` + `draw.Text` + PUA glyphs; `drawText8`, `blitImage`, `emblemBoxScale` deleted; a missing font degrades, never blanks the boot |
| M104f (#2273) | §1 named gap, §5.3 | `tabapp` canvas binding + rebind-on-resize, then the audit order |
| M104g (#2274) | §4 batch 2 | the ten glyphs + per-glyph goldens |
| M104h (#2275) | all of it | acceptance goldens — dialog, seat rail, one migrated flagship |

### 5.2 The controls inventory (v2 — M104d builds exactly these)

Every control names a **pixel-painting** forcing consumer (files, rss,
pulse and the other Bubble Tea apps render through the window tty and can
never consume one) and its §2.3 coverage. Anything without a consumer is
deferred, not spec'd.

| Control | Forcing consumer | Anatomy (primitives it rides) | §2.3 coverage |
|---------|------------------|-------------------------------|----------------|
| **Scrollbar** | `logview` (the scrolling log list; `start := len(rows)-n` paging in `main.go`) | 12px `ChromeBg` track, `radiusPill` thumb on the Btn ramp, min thumb 24px; content viewport uses `PushClip`/`PopClip` | default, hover, pressed(drag); when content fits the control is **absent**, not disabled |
| **Toggle** | `goset` (the on/off vocab rows — `shadow`, `focus_follows_mouse`, `notify_dnd`, `notify_sound`, `init` — plus service enable/disable) | 32×18 `radiusPill` track + `FillEllipse` knob; on = `Accent` track (the §2.3 "selected" vocabulary), off = `BtnIdle` | default, hover, pressed, disabled, focused-visible, selected(on) |
| **Slider** | `sound` (position/volume; secondary: goset's `audio_volume` 0–100 step-10 row) | 4px `ChromeBg` track with `Accent` fill to value, 14px `FillEllipse` knob | default, hover, pressed(drag), disabled, focused-visible |
| **Dropdown** | `goset` (multi-valued vocab rows — `theme`, `font_size`, `keyboard_layout`, `wm`, `shell`) | `radiusControl` button + `chevron-down` (E009); the open list is a `radiusWindow` popover plate — **the `FillShadow` + `PushClip` consumer** — rows take the §2.3 selected marker | default, hover, pressed, open, disabled, focused-visible; rows: hover/selected |

**Checkbox** rides the Toggle's state machine as a `radiusControl` square
with the `check` glyph (E00A) — a geometry variant, spec'd here but
unscheduled: no form-style consumer exists yet.

Deferred (no pixel consumer today): radio groups, tab strips in-window
(the seat owns tabs), menus (the `kebab`/`menu` glyphs are the
affordance; the surface arrives with a consumer), tooltips.

### 5.3 The adoption audit (v2 — M104f's order)

Every `user/go/*/main.go` that opens a window — via `tabapp.Init` **or** a
direct `vi.WinOpen` — classified by paint path (**observed** by
import/call, not run). Order is blast radius, lowest first; NOTE.ELF is
the fleet's test client (the M104 index counts 34 specs naming it) and
its `0x101418` page fill is pixel-pinned in eight specs — it goes last
with **client fill unchanged** as the explicit constraint.

| # | App | Opens via | Paints today | Class / M104f step | Controls consumed | Pinning specs |
|---|-----|-----------|--------------|--------------------|-------------------|---------------|
| 0 | `appkit/demo` (GODIALOG) | `vi.WinOpen` | `draw.WindowCanvas` — AA today | **reference** — already on the engine; M104d's control showcase | all four (showcase) | `live-chrome`, appkit composite goldens |
| 1 | `calc` | `tabapp.Init` | `draw.FillerCanvas` + widgets | swap binding → `WindowCanvas` | — | `go-calc` |
| 2 | `top` | `tabapp.Init` | `draw.FillerCanvas` + widgets | swap binding | scrollbar (proc list) | `go-top`, `live-tabstrip`, `live-wm4-paint`, `live-tokens` |
| 3 | `fetch` | `tabapp.Init` | `draw.FillerCanvas` + widgets | swap binding | — | `go-fetch-https`, `live-fetch` |
| 4 | `crashview` | `tabapp.Init` | `draw.FillerCanvas` + widgets | swap binding | scrollbar (receipt list) | `live-crash-viewer` |
| 5 | `logview` | `tabapp.Init` | `draw.FillerCanvas` + widgets | swap binding | **scrollbar** (forcing) | `go-selftest` |
| 6 | `netstat` | `vi.WinOpen` | `draw.FillerCanvas` + widgets | swap binding | — | `live-netstat`, `go-net` |
| 7 | `tabapp/demo` | `tabapp.Init` | `draw.FillerCanvas` + widgets | swap binding | — | `go-tabapp` |
| 8 | `goset` | `tabapp.Init` | hand-rolled filler `RectCanvas` + widgets | bind buffer, drop `widgetCanvas` | **toggle + dropdown** (forcing) | `go-wm-seat`, `go-wm-hid`, `go-wm-default`, `live-supervise` |
| 9 | `sound` | `tabapp.Init` | hand-rolled `fillSurf` + `webrender.DrawText` | bind buffer | **slider** (forcing) + media glyphs | `live-sound-playback` |
| 10 | `view` | `tabapp.Init` | hand-rolled `fillerSurface`, per-row spans | bind buffer; image path → `BlitScaled` | — | `live-image-viewer`, `go-fileman`, `go-wm-seat`, `go-wm-hid` |
| 11 | `selftest` | `tabapp.Init` | raw `vi.Filler` + 8×8 face | bind buffer | — | `go-selftest`, `go-wm-tabs` |
| 12 | `edit` | `tabapp.Init` | raw `vi.Filler` + 8×8 face | bind buffer; **document text stays the bitmap face** (editor density is monospace's reason to exist); chrome adopts | — | `go-edit`, `live-typography`, `live-editing`, + ~30 live specs |
| 13 | `note` | `tabapp.Init` | raw `vi.Filler` + 8×8 face | **LAST — client fill `0x101418` byte-unchanged**; machinery may move, the fill may not | — | `0x101418` pixel-pinned in `live-chrome`, `live-win`, `live-wm4-paint`, `go-wm-seat`, `go-wm-hid`, `live-text`, `live-roadpops`, `go-rss`; named in ~34 |
| — | `r3d` | `tabapp.Init` | own 3D rasterizer via `vi.Filler` | **deferred** — its pixels are a framebuffer, not chrome | — | `go-r3d` |
| — | `gputriangle` | `vi.WinOpen` | `gpu3d` pipeline | **deferred** — GPU triangle demo, no 2D chrome | — | `live-gpu3d` |
| — | `wmrpcprobe` | `vi.WinOpen` | none (diagnostic) | **deferred** — an RPC probe window, no chrome worth migrating | — | `go-wm-tabs` |
| — | `browser` (WEB.ELF) | `vi.WinOpen` | own `webrender`/`ttf` pipeline | **deferred** — it owns a renderer; its chrome may adopt widgets in a later arc | — | `live-web`, `live-web-ttf` |
| — | `files`, `rss`, `gitui`, `pulse`, `help`, `charmhello`, `imgcat`, `term`, `sh` | `tabapp.Init` | window **tty**, not pixels | **TTY-stays** — Bubble Tea/CSI apps never bind a canvas | none ever | `go-fileman`, `go-rss`, `go-gitui`, `go-charmhello`, `go-term`, `go-sh`, `go-help` (tty-text asserts) |
| — | `gotabwm` | seat (scanout mmap) | raw scanout stores + `drawText8` | **seat — M104e's card**, not f's | consumes the whole depth block | `go-wm-seat`, `go-wm-tabs`, `go-wm-default`, `go-wm-hid` |

`gsport/tty` and `vi` also reference `tabapp.Init` — a library harness and
a comment respectively, not `main.go` apps; they are not fleet entries.

## 6. Enforcement and revision

- **Class A:** `cd user/go && go test ./...` — §3.3's guarantees and §2's
  composite surfaces are golden-pinned; widget regression tests are the
  fixed point.
- **Class B:** the seat specs (`go-wm-seat`, `go-wm-tabs`,
  `go-wm-default`, `go-wm-hid` — extended in place, never a new script)
  plus each migrated app's existing live spec; M104h adds one composite
  golden per design-language surface.
- **This file is the contract.** A change to §3's signatures or §4's
  codepoints is a **contract revision**: bump the status line and record
  the change here (the `wasm-import-contract.md` discipline). §2 taste
  values may be tuned by the same revision — chrome drawn outside the
  revision is off-contract drift.

## Revision history

- **v2** (2026-10-14, M104a #2268): the depth + adoption revision —
  §1 closed the `[]u32` gap (`WindowCanvas` landed), named the
  resize-rebind gap, and set the FillerCanvas keep-forever policy;
  §2.1 added `Shadow`/`WallpaperTop`/`WallpaperBot` (Go-only tokens);
  §2.2 clarified where the 28px bar applies and confirmed the kernel's
  16px `wnd` band is kernel-owned (no kernel work this arc); §2.5 is
  new (depth taste); §3.1 added `FillShadow`, `FillLinearGradient`,
  `BlitScaled`, `FillArc`, `StrokeArc`, and the `PushClip`/`PopClip`/
  `Clip` stack, and recorded the `StrokeShadow`/horizontal-gradient
  refusals; §3.2 added `Text` (the one interface growth) and ruled the
  depth block out of the interface; §3.3.2 recorded M99o's linear-light
  glyph blending and kept shapes in sRGB; §3.3.4 gained the clip stack;
  §3.4 is new (widget `*ttf.Face` via `Canvas.Text`, `widgets → ttf`,
  bitmap fallback rules); §4 added batch 2 (`U+E014`–`U+E01D`); §5 gained
  the controls inventory and the adoption audit.
- **v1** (2026-09-27, M86a #1817): initial contract — buffer model,
  widened `widgets.Canvas`, AA guarantees, chrome design language, twenty
  glyphs.
