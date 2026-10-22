---
title: Media: text, images, documents
parent: capabilities
status: published
tags: [capabilities, media, fonts]
---

# Media: text, images, documents

VirelaiOS renders real type, decodes real image formats, and reads a
bounded slice of PDF — all of it in owned Go code at EL0, with no
third-party decoder in the guest and no GPL-family code anywhere. The
theme is the same everywhere: **bounded subsets with named refusals**,
so a hostile or exotic file fails by name instead of hanging a decoder.

## Typography

The desktop speaks TrueType, not bitmaps — though the bitmap face
survives as the honest degrade path. The Go engine is
[`user/go/ttf`](https://github.com/drawmeanelephant/VirelaiOS/tree/main/user/go/ttf):
it parses `glyf` outlines, rasterizes coverage at sub-row resolution,
and blends glyph masks onto BGRA in **linear light** (one shared
`CoverageBlend` helper), with proportional metrics and GPOS pair
kerning inside the Latin shaper. Everything else — shapes, images,
gradients — composites straight-alpha in encoded sRGB, so thin glyph
edges stay perceptually faithful while decorative ramps stay cheap.

Faces are staged on the share and registered by
[`image/fonts/fonts.txt`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/image/fonts/fonts.txt)
(staged as `/host/FONTS.TXT`), a role manifest in the APPS.TXT v2
shape: `role=ui` resolves to Inter Regular/Bold/Italic/Bold-Italic plus
Noto Serif as a cascade member, `role=mono` to Fira Code, `role=serif`
to Noto Serif, and `role=symbol` to the Virelai Chrome icon face plus
**NOTOCJK** — a Noto Sans JP glyf build (kana + kyōiku kanji) that
carries CJK fallback at the tail of every cascade. Coverage is never
declared in the manifest: the engine reads each face's `cmap`, a rune
the primary lacks falls through the cascade, and one nothing covers
paints `.notdef` and is counted (`fonts: notdef`), never silently
dropped. Scripts needing complex shaping or bidi — Arabic, Hebrew,
Indic, Thai — are excluded by name.

The `font_size` setting (small/medium/large) moves **two ladders at
once**: the UI text ladder and the bound terminal's rasterized grid
(11/13/17 px faces on cells of 7×13 / 8×16 / 10×21), re-flowing bound
screens and notifying owners through `WIN_RESIZE`. GOSET cycles it; it
is also a GOTERM profile key.

There are two engines on purpose, and the split is frozen (ADR 0034,
amendment A): the Go engine is the only one that grows typography;
the Zig `font_ttf.zig` behind the fallback seat and the Zig app
portfolio is frozen at bug-fix level — no GPOS kerning, no GSUB
ligatures, BMP only — with a generated parity fixture pinning that the
two engines measure the shared faces to the same widths.

## PDF: a bounded engine, not a viewer port

[`user/go/pdf`](https://github.com/drawmeanelephant/VirelaiOS/tree/main/user/go/pdf)
is an owned, pure-Go PDF **subset** (ADR 0040) that produces one opaque
96-dpi page bitmap per call through `virelai/vector.Rasterize`. The
admitted surface is deliberately narrow and *closed*: `%PDF-1.3`/1.4
classic cross-reference tables, path fills (nonzero and even-odd), one
`re`-rectangle integer clip, DeviceGray/DeviceRGB fill colors,
uncolored outline-only **Type 3** fonts, and raw/FlateDecode 8-bit
image XObjects — plus baseline `DCTDecode` admitted through an
adapter-installed decoder hook so JPEG-in-PDF renders without a second
codec path. A bounded `user/go/pdfwrite` writer produces the same
subset for in-guest document export.

Everything outside the allowlist — strokes, embedded TrueType,
transparency, xref streams, JavaScript — is a named refusal
(`UnsupportedStructure`, `Malformed`, `UnsupportedClip`, …), and all
lists are closed: an unused invalid object still fails whole-document
validation. No strokes are approximated; a stroked document must be
reauthored.

<Aside kind="warning">

**LIMITATION.** This is not a general PDF reader — no text extraction,
no forms, no TrueType/Type0 fonts. The outside reference is
CoreGraphics (chosen after AGPL MuPDF was license-rejected and the
`rsc/pdf` port was rejected on bounds); LGPL CairoSVG appears only as
an external test tool. GOREADER.ELF is the user-facing surface: it
renders one page at a time with nav, zoom and find.

</Aside>

## SVG and the vector contract

ADR 0041 made the same bet for vectors: an owned pure-Go subset under
`user/go/svg` + `user/go/vector` that turns SVG bytes into a bounded
command/paint scene and rasterizes it without parsing XML twice. The
first subset is **solid filled shapes** — paths, basic shapes, both
fill rules, affine transforms. Stroke offsetting, arcs, gradients,
clipping and text are refused, not approximated, and refusal is
whole-document and bounded: nothing half-paints. The vector package
doubles as the PDF engine's raster target, which is why the two share
one work budget (`vector.MaxWork`). The gate `live-svg-raster` pins it:
five consecutive full passes, 20/20 boots.

## Image decode

One decoder entry point — `webrender.DecodeImage` — serves WEB's
`<img>`, GOVIEW, the file manager's QuickLook, and IMGCAT:

| Format | Engine | Notes |
|--------|--------|-------|
| PNG | in-tree, over the shared `user/go/flate` inflater | the same DEFLATE the PDF engine charges against |
| JPEG | bounded **baseline** decoder | progressive refused by name |
| GIF | first-frame decode plus `DecodeGIFFrames` | full GCE disposal/transparency/delay compositing and NETSCAPE loop counts; corrupt input refuses, never resyncs |
| QOI | in-tree | also the terminal-graphics path (IMGCAT.ELF) |
| SVG | the ADR 0041 subset above | rasterized through `virelai/vector` |

Two budgets bound every decode — `maxImageBytes` and `maxImagePixels` —
and every refusal names itself (`image-limit:`, `image-invalid:`,
`image-gif-unsupported-…`), so a viewer falls back to a placeholder
box rather than rendering nothing or hanging.

**GOVIEW.ELF** is the multi-format viewer on top: zoom, pan, a `.`/`,`
frame stepper, and real GIF playback — each frame armed on the
nanosecond app timer (slot 95) at its own GCE delay, with `space`
toggling play/pause so a paused loop's elapsed time stays honest.

## Sixel: graphics inside the terminal

The bound window tty also speaks **sixel**. The kernel-side decoder
(`kernel/src/term_image.zig`) streams byte-by-byte — no capture buffer
to overflow — into a page-pool pixel bank bounded at **96×64 px**, one
committed image per terminal plus a staging buffer, so a refused image
never clobbers the one on screen. Images are **cell-native**: placing
one writes image cells that scroll, erase, reflow, and get overwritten
exactly like text cells; VT340 color-register semantics apply (a
mid-image redefinition recolours the pixels already drawn), unset
pixels stay transparent, and an oversized raster refuses whole. The
client side is `IMGCAT.ELF`, which decodes a share QOI and writes the
sixel stream into its own bound tty. `live-term-graphics` pins the
scanout pixels end to end.

<Aside kind="info">

**LIVE-GATED.** `live-image-viewer` runs five formats through one
viewer; `live-term-graphics` asserts sixel pixels on a real scanout;
`live-web-ttf` pins serif resolution, CJK through NOTOCJK and the
`.notdef` counter; `live-svg-raster` and the PDF corpus gates pin the
document engines.

</Aside>

## See also

- [[desktop]] — the seat that paints this media.
- [[apps]] — GOVIEW, GOREADER, GOSOUND and the rest of the fleet.
- [[programs]] — the runtimes; the media engines are ordinary Go packages.
- [[graphics]] — the kernel framebuffer and the Seam-B buffer model.
