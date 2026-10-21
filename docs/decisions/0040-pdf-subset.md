# ADR 0040: A bounded Go PDF subset producing page bitmaps

- Status: **PROPOSED for owner review; acceptance takes effect on landing.**
- Date: 2026-10-03 · Design card: M89a / #1920 · Index: #1916
- Amended: 2026-10-04 (A1 / #1916 — oracle rulings and stream-boundary
  tokens; owner approval [recorded](https://github.com/drawmeanelephant/VirelaiOS/issues/1916#issuecomment-5981057608))
- Amended: 2026-10-04 (A2 / #1916 — no GPL-family tools; CoreGraphics
  replaces Poppler as the outside reference; owner decision
  [recorded](https://github.com/drawmeanelephant/VirelaiOS/pull/1970))
- Amended: 2026-10-21 (A3 / #2921 — the bounded `user/go/pdfwrite`
  writer; owner decision recorded on card #2921)
- Related: [ADR 0030](0030-go-is-el0.md) D2/D3,
  [ADR 0041](0041-svg-raster.md) §§4–7, ADRs 0007/0024/0026.

## 1. Decision and evidence boundary

Select an **owned, pure-Go subset engine under `user/go/pdf/*`**, producing
one opaque, packed page bitmap at **96 dpi**. It consumes the exported
`virelai/vector.Rasterize` API in the same static Go ELF. ADR 0030 D2
already permits this; D3 forbids embedding C/Zig or introducing FFI.
No amendment to 0030, 0039 or 0041 is needed or authorized.

The first subset is intentionally narrower than a general PDF reader:
classic cross-reference tables, solid filled paths, **uncolored,
outline-only Type 3 fonts**, and streamed 8-bit DeviceGray/DeviceRGB
images. There are no strokes, ordinary system/embedded TrueType fonts,
arbitrary clipping, transparency or image codecs beyond raw/Flate.
These are explicit refusals, not a promise to approximate normal PDFs.
Type 3 provides real encoded text placement with document-supplied
outlines without font substitution or an unbudgeted font engine.
Text extraction/search has no justified consumer here and is excluded.

No viewer, editor, forms, generator, print pipeline, WEB integration,
kernel/SDK/runtime change, host renderer fallback, libc/POSIX dependency
or boot-default change is part of M89. The implementation cards below
are complete deliverables, not permission to grow this subset.

**Observed baseline:** `origin/main`
`038844d88b4c0a0c125c1a2311b8aabf83f4a0c6`, fetched 2026-10-03;
the complete #1920 and #1916 bodies and empty comment lists were read.
The index's PNG-only/no-vector-prior-art statement is not adopted:
QOI/PNG paths, bounded Go drawing and glyph coverage code already exist.
ADR 0041 defines the forthcoming general vector API, not a PDF parser.

**Observed diagnostics:** source/license inspections in §2; host Go
1.27.1 `go -C user/go test ./ttf ./draw` passed. Installed Poppler
26.09.0 rendered an authored 1,147 B classic-xref smoke PDF containing a
solid fill, Type 3 d1 glyph and Flate RGB image to a 64×64 PPM, exit 0.
This establishes a usable **host reference tool**, not guest rendering,
pixel comparison, engine size, runtime sufficiency or budget acceptance.
Sources and diagnostic records stay ignored under `artifacts/m89-r1/*`.
Every ceiling below is a design requirement, not a measured guest result.

## 2. Actual-source route survey and maintenance

| Route | Observed dependency surface, weight and license | Decision |
|---|---|---|
| Embed MuPDF | Inspected Artifex MuPDF `d0f5d7f37cd0dceabc88c6bd8b9080a5cb951530`. README and COPYING declare AGPL-3.0-or-later; README offers commercial Artifex licensing. `source/pdf/pdf-xref.c` is 145,117 B, `pdf-interpret.c` 53,391 B, `source/fitz/context.c` 9,241 B: **207,749 B for only three inspected files**, not the engine. Allocation hooks do not remove the hosted surface: `context.c` calls `abort`/`fprintf`; `memory.c` uses errno/stdio and scavenging allocation; `stream-open.c` uses fopen/fread/fseeko/fclose/strerror. Makelists and submodules include FreeType, HarfBuzz, JPEG, OpenJPEG, JBIG2, LCMS and zlib; JS, UI, OCR and other tools are additional optional surfaces, not all mandatory PDF dependencies. | **License-blocked** for this proprietary repository unless the owner records a suitable commercial license or a different license decision. No such record was supplied. Independently, pruning codecs, platform/error paths and allocation is a substantial maintained native port, and Go cannot link it under D3. “Small/lightweight” is not binary or memory evidence. No MuPDF build or submodule closure was attempted. |
| Port a minimal Go parser | Inspected `rsc/pdf` `c47d69cf462f804ff58ca63c61a8fb2aed76587e`: six root Go files total **271,294 B**, including a 208,496 B encoding-name table; BSD-3-Clause LICENSE is compatible with retained notices. `read.go` imports compress/zlib, crypto, fmt, io/ioutil and os; NewReader accepts ReaderAt, but `/Size` drives `make([]xref, size)`. Value accessors silently return zero for wrong kinds; parser/filter errors panic, and the package explicitly documents incomplete error reporting/no efficiency attempt. `lex.go` makes dictionaries; `ps.go` grows operand/dictionary stacks with append. Page/text helpers extract information, not general page bitmaps. | Reject an as-is port: no C/libc dependency is the right language fit, but panic recovery does not establish bounded traversal, allocation, inflation or semantic refusal. Replacing its value model, error propagation, stacks, filters and adding a renderer would be a large local fork rather than a shortcut. No claim that this source fails a guest compile, or that its source size predicts a guest ELF. |
| Owned Go subset | In-tree `ttf/outline.go` 10,742 B, `ttf/raster.go` 7,351 B and `draw/draw.go` 11,582 B total **29,675 B of prior art** under the repository license. They demonstrate curve/coverage concepts, not a public PDF outline interface or a general parser. The private TTF contour path allocates slices; copying it would not establish bounded glyph handling. ADR 0041 supplies the separately owned fill rasterizer. | **Select.** Implement strict token/xref/page interpretation, a work-instrumented streaming Flate decoder, Type 3 outline expansion and row image placement. No imported PDF/font/image engine, Go module addition or copied M90/private TTF state. The cost is owning a deliberately finite parser and its complete adversarial tests, not “supporting PDF” generally. |

The selected engine has **no new third-party guest dependency to pin**.
The offline build uses the repository's Go **1.27.1** distribution-based
fork/overlays read-only, `GOOS=virelai`, `GOARCH=arm64`, `CGO_ENABLED=0`,
`GOTOOLCHAIN=local`, `GOPROXY=off`, `GOSUMDB=off`, `-trimpath`,
`-ldflags="-s -w"` and ordinary optimized compilation. M89b records the
exact fork revision, overlay/source hashes, compiler identity and flags
in its engine lock; M89c verifies the same lock. Missing/drifting inputs
fail `MissingToolchain`/`SourceDrift`, never trigger acquisition, bootstrap
or a stock-toolchain fallback during a build/gate.

An isolated builder is necessary: `tools/go/build-go.sh` automatically
prepares a missing fork and must not be invoked as an offline guarantee.
The engine's dependency audit rejects cgo, FFI, networking, `os` file
shadows and implicit module downloads. Native file transport uses `vi`,
not a POSIX compatibility layer. Go runtime/upstream notices remain.
Any subsequently copied BSD decoder code requires an explicit source pin,
license/notice review and revised lock before adoption, not an implicit
dependency authorized by this ADR.

The project owner maintains the subset and approves pin/feature/budget
changes. Upgrades require the dependency audit, empty/full size comparison,
all host and VZ tests and reference-provenance review. Hold a failing pin
or suspend the renderer; do not widen a limit or silently accept new syntax.

## 3. Exact byte-to-page subset

All lists are **closed**, including unused resources, glyphs and pages.
Validate every in-use object and every page before returning a bitmap.
Resource dictionaries do not confer file/network/command authority.
Only bounded non-rendering metadata below may be ignored.

### 3.1 File structure, values and dictionaries

Accept `%PDF-1.3` or `%PDF-1.4` at byte zero, CR/LF/CRLF, PDF whitespace
and comments (including a binary marker comment). One final classic
`xref`, one subsection `0 N`, one trailer, `startxref` pointing exactly
to that table, then `%%EOF` and whitespace only. Object 0 is the normal
free sentinel, generation 65,535; entries 1 through N−1 are all in-use,
generation zero. Objects occur once, in ascending object-number/offset
order between header and xref, with no overlap, repair scan or junk
between definitions other than whitespace/comments. `/Size` equals N.
Cross-check every xref offset against its `n 0 obj ... endobj`; unknown
or duplicate definitions, bad lengths/offsets and dangling references are
`Malformed`. All in-use objects must belong to the declared catalog,
page/resource or optional Info graph; orphan objects are
`UnsupportedStructure`, not an avenue for unchecked data.

Accept null/booleans/integers/reals, names, byte strings, arrays,
dictionaries and generation-zero indirect references in the roles below.
PDF decimal numbers have optional sign and decimal point, at least one
digit, **no exponent**, at most 32 B/token, at most six fractional digits,
and must be finite. Integers use checked conversion; geometry and composed
matrices must satisfy §4's bounds. Names decode `#hh` once; require
nonempty ASCII names ≤64 B. Strings accept PDF literal escaping,
octal escapes, escaped line breaks and bounded balanced parentheses;
hex strings accept whitespace and pad an odd last nibble with zero.
String data is bytes, never an inferred Unicode encoding.
Dictionary keys must be unique; arrays/dictionaries are type-checked,
not accessed through success-shaped zero defaults.

Streams are indirect objects with a direct nonnegative `/Length`.
Consume exactly that many bytes after the required stream line ending;
then require the legal delimiter/`endstream`/`endobj`. Never scan binary
data for terminators. Accept no `/Filter`, or exactly `/FlateDecode`
as a name or a one-element filter array. `/DecodeParms` is absent, null,
or the corresponding one-element array containing null or
`<< /Predictor 1 >>`; no other keys. Validate zlib header, DEFLATE
stored/fixed/dynamic blocks, distances, end-of-stream and Adler-32.
Reject preset dictionaries, invalid/truncated blocks/checksums and trailing
compressed data as `MalformedStream`. No concatenated streams or fallback
to raw DEFLATE. Expanded bytes are streamed and cumulatively charged.

The following keys, plus stream Length/Filter/DecodeParms where applicable,
are the complete role-specific allowlist:

| Role | Accepted keys and exact behavior | Test category |
|---|---|---|
| Trailer | Required `Size`, `Root`; optional `Info` and `ID` (two byte strings ≤32 B each, ignored). Root/Info are indirect references. | `structure` |
| Catalog | `Type=Catalog`, `Pages` only. | `catalog` |
| Pages node | `Type=Pages`, `Kids` (nonempty ordered references), correct `Count`; `Parent` except on the root; optional inherited `MediaBox`, `CropBox`, `Rotate`, `Resources`. Leaves ≤256/document. | `page-tree` |
| Page | `Type=Page`, correct `Parent`; local overrides of those four inherited properties; `Contents` absent/null, one stream reference, or ordered array of ≤16 stream references. An absent content stream is a white page. Parent back-links are checked, not recursively followed; all other graph cycles are malformed. | `page-box`, `content-array` |
| Resources | `Font` and `XObject` name-to-reference dictionaries, each ≤64 entries, optionally empty; nearest page-tree value replaces, not merges, an inherited Resources dictionary. | `resources` |
| Info | Only `Title`, `Author`, `Subject`, `Keywords`, `Creator`, `Producer`, `CreationDate`, `ModDate`, `Trapped` (name True/False/Unknown). Bounded validated ignore; aggregate decoded metadata ≤16,384 B/document. No date interpretation or text extraction. | `metadata` |
| Font, encoding and CharProcs | Exactly §3.3; role-specific direct or indirect dictionaries/arrays are legal, except values explicitly required direct. | `type3` |
| Image XObject | Exactly §3.4. | `image` |

Page boxes contain four direct decimal numbers in points. Effective box
is CropBox (default MediaBox) intersected with MediaBox; require ordered,
nonempty boxes. `Rotate` is absent or integer zero; `UserUnit` is absent.
At 96 dpi, require effective width/height times **4/3** to be positive
integral pixel counts ≤1,024 and ≤1,536. Check integrality exactly using
checked millionth-point arithmetic, not a float epsilon or silent
rounding. Thus maximum extents are 768×1,152 pt, and 768×1,086 pt gives
the required 1,024×1,448 workload. Fractional pixel page extents are
`UnsupportedPageGeometry`; zero/reversed boxes are `Malformed`.
No fit-to-window scaling, rotation, tiling or lower-resolution success.

### 3.2 Content operators and graphics state

Concatenate a page's decoded Contents logically in array order **without
inventing separators**. Operands and current path/text/graphics state may
cross a stream boundary; a token may not (A1.1). Reject wrong operand
type/count, trailing unused operands, unterminated BT or unbalanced q/Q
as `MalformedContent`.
An empty stream is legal. All operators below have standard PDF operand
order; no implicit repair or unknown-operator skipping.

| Operators | Accepted meaning / restriction | Test category |
|---|---|---|
| `q Q cm` | Save/restore CTM, colors, clip and text-state parameters; concatenate affine CTM in PDF order. Current path is **not** saved by q. Maximum 16 saved graphics frames. Q underflow is malformed. | `graphics-state`, `affine` |
| `m l c v y h re` | Move, line, cubic, PDF shorthand cubics, close and rectangle. Preserve compound contours; expand v/y to Cubic and re to Move/Line/Close. Open contours close for filling. | `path`, `cubic` |
| `f F f* n` | Nonzero fill (f/F), even-odd fill, or end path without painting; clear current path afterward. Empty/degenerate paths paint nothing but still validate and charge work. | `fill-rules`, `empty` |
| `W W*` | Only a current path consisting of **one re**, followed by n/f/F/f*. Use re's construction-time mapped rectangle; require axis-aligned, integral target-pixel edges. At path end, paint with the previous clip if requested, then intersect the saved clip with the new rectangle. A clip cannot be enlarged. Other paths, fractional edges or sheared/rotated rectangles refuse `UnsupportedClip`, never rounded approximations. | `integer-clip` |
| `g rg` | DeviceGray/DeviceRGB **fill** color only, components in [0,1], default black. Convert component to byte by nearest rounding, halves upward; all fills opaque. | `color` |
| `BT ET Tf Tm Td TD T*` | Text objects, Type 3 font/size selection, text matrix, line positioning and leading. Standard independent text and line matrices; nested BT/ET misuse is malformed. Font size in [0,256] pt. | `text-position` |
| `Tc Tw Tz TL Ts Tr` | Character/word spacing, horizontal scale, leading, rise and rendering mode. Tz in (0,256] percent; Tr **0 only**, fill. Other finite spacing values obey coordinate bounds. Parameters persist per PDF graphics-state semantics; BT resets text/line matrices, not parameters. | `text-state` |
| `Tj TJ ' "` | Show byte-string glyphs, numeric TJ displacements in thousandths of text space, and standard next-line/spacing shorthands. TJ has ≤512 entries and ≤4,096 aggregate string bytes/show; no kerning/shaping substitution. Tw applies to single-byte code 32. | `text-show` |
| `Do` | Named image XObject only, outside BT/ET, under §3.4's placement restrictions. Missing resource is `MissingResource`. | `image-placement` |
| `d1` | Only the first operator in a Type 3 CharProc, six direct numeric operands; §3.3. Never a page operator. | `glyph-metrics` |

No strokes are accepted; a stroked document must be reauthored with
filled outlines. There is no M90 stroke assumption or uncharged expansion.
No text operation without a selected font; unused invalid glyphs/resources
still fail whole-document validation.
Text position/show operators require BT/ET; text-state setters may occur
inside or outside it. Page path/clip/paint operators and Do are outside
BT/ET only; a CharProc is a separate permitted outline context.

### 3.3 Fonts and text: uncolored Type 3 outlines only

Accept `/Type /Font /Subtype /Type3` with exactly `FontBBox`, `FontMatrix`,
`CharProcs`, `Encoding`, `FirstChar`, `LastChar`, `Widths`, optional
`Resources` (empty dictionary only) and optional `Name` (ignored bounded
name), in addition to Type/Subtype. Required boxes/matrix are finite,
well-formed and obey coordinate/affine bounds. FirstChar/LastChar are
ordered integers in [0,255]; Widths has exactly LastChar−FirstChar+1
finite nonnegative horizontal advances. Encoding is a dictionary with
optional `Type=Encoding` and required `Differences`: integer code followed
by one or more glyph names, no BaseEncoding, duplicate assignments,
overflow or implied system encoding. Every referenced glyph name must
exist in CharProcs. At most **16 fonts/page**, **256 CharProcs/font**.

Each CharProc is a stream starting with **d1**; horizontal wx agrees
with every Widths entry mapped to that glyph, wy=0 and bbox is ordered.
The remaining program permits only q/Q/cm and the path/fill/n operators
in §3.2. No colors, clipping operators, text, Do, resource lookup, d0,
hint program or nested glyph execution. Empty outlines after d1 are
legal (e.g. a space); d1's bbox is cache metadata, not an implicit clip.
Require every constructed glyph-space control/end point inside both
d1's bbox and FontBBox (a conservative closed-subset rule); otherwise
`UnsupportedGlyph`. Boxes do not replace validation of actual coordinates.

M89 interprets glyph operators into **filled Command/Paint outlines**
using the text rendering matrix, FontMatrix and inherited fill/clip;
the glyph has an isolated current path/graphics stack and cannot change
page state. Apply glyph advance and spacing with PDF text-space rules.
Reusing a glyph re-expands and re-charges it; there is no hidden bitmap
or outline cache. All glyphs, including unused ones, are validated.
Codes without an explicit encoding/width/glyph fail `MissingGlyph`;
no `.notdef`, Inter, Fira Code or other fallback. Text is single-byte,
horizontal, unshaped; no Unicode mapping/extraction/search API.

This does not reuse the allocating private `ttf` contour implementation.
Ordinary Type 1/base-14, TrueType, Type 0/CID/CFF and embedded font programs
are expressly outside this first subset. Adding them requires a new
design/measurement, not permission to borrow M90 text machinery.

### 3.4 Image XObjects and streaming

Accept indirect `/Type /XObject /Subtype /Image` streams with required
direct integer `Width` (1..1,024), `Height` (1..1,536),
`BitsPerComponent=8`, and `ColorSpace=/DeviceGray` or `/DeviceRGB`.
Optional `Decode` is only the default [0 1] or [0 1 0 1 0 1];
optional `Interpolate=false`, `ImageMask=false`; other keys refuse.
Require exactly width×height×channels decoded bytes with checked products.
Raw or the Flate subset above only, no predictor except 1.

Placement maps the unit image square through CTM and page conversion.
Require nonzero diagonal axes, no shear/rotation, and integral target
origin/extents. Axis reflections are supported. Source row zero is the
PDF image's **top** (local y=1), not its bottom. Clip to the current
integer rectangle and page bounds. Use nearest-neighbor pixel-center
sampling, with half-open cells/ties toward the higher source index,
and no edge alpha/interpolation. Emit opaque gray/RGB pixels directly
in document order between vector fill batches.

Decode one source row at a time, including rows clipped away, reusing
the image's Flate window and row buffers. A suspended compressed content
stream keeps its own decoder state while a glyph or image is decoded;
at most two decoder frames are live, since glyphs cannot invoke either.
Maximum RGB row is **3,072 B**.
For reflection, write that row to its computed destination rows; for
scaling, retain one row until all destination samples needing it are
written. No full decoded image, full-page mask or second output.
A full 1,024×1,536 RGB image expands to **4,718,592 B** but need not
be resident: compressed input may fit the file cap and rows fit scratch.
Each Do decodes again and charges expanded bytes/work again.
Image geometry exceeding these placement rules is `UnsupportedImage`,
not an automatically downsampled or silently skipped image.

### 3.5 Exclusions, bounded errors and cleanup

Every exclusion has an assigned policy and test category, including
unused resource/glyph or otherwise invisible content:

| Excluded/malformed case | Error policy | Test category |
|---|---|---|
| Encryption/Encrypt, password or security-handler dictionaries | `Encrypted`; no password attempt or decrypt | `encrypted-refusal` |
| PDF versions other than 1.3/1.4, incremental Prev/XRefStm, xref/object streams, linearization, nonzero generations, alternate xref layouts, orphan objects | `UnsupportedStructure`; no repair, prior-revision fallback or partial interpretation | `structure-refusal` |
| Rotate other than zero, UserUnit, nonintegral pixel page extents, additional page/view boxes | `UnsupportedPageGeometry`; no guessed size/rotation | `page-refusal` |
| S/s/B/B*/b/b*, stroke-state w/J/j/M/d/G/RG, any stroke | `UnsupportedStroke`; no centerline-as-fill | `stroke-refusal` |
| Nonrectangular/fractional/transformed-nonaxis W/W*, glyph clips, text clipping or Tr other than 0 | `UnsupportedClip` (W), `UnsupportedGlyph` (CharProc) or `UnsupportedText` (Tr); no clipped-away bypass | `clip-refusal`, `glyph-refusal`, `text-refusal` |
| Type 1/base-14, TrueType, Type 0/CID/CFF, embedded font files, named/system encodings, BaseEncoding, vertical text, ToUnicode/shaping | `UnsupportedFont`; no substitution/font-file load | `font-refusal` |
| Colored d0 Type 3, CharProc colors/images/text/resources, missing encoded glyph/width | `UnsupportedGlyph` or `MissingGlyph`; no blank-glyph success | `glyph-refusal` |
| Inline BI/ID/EI, DCT/JPEG, JPX, JBIG2, CCITT, LZW, ASCII filters, filter chains, non-1 predictors | `UnsupportedImage` (inline) or `UnsupportedFilter`; no codec fallback | `image-refusal`, `filter-refusal` |
| Other bit depths/colorspaces, Indexed/CMYK/ICC, masks/SMask, interpolation, nondefault Decode, arbitrary image affine placement | `UnsupportedImage`; no color/mask approximation | `image-refusal` |
| Form/PostScript XObjects, ExtGState/gs, alpha/blend groups, soft masks, shadings/sh, patterns, color operators cs/CS/sc/SC/scn/SCN/k/K, rendering intent ri and flatness i | `UnsupportedFeature`; no recursive form or paint omission | `paint-refusal` |
| Annotations, AcroForm/XFA, actions, JavaScript, embedded files, multimedia, optional content, marked content BMC/BDC/EMC/MP/DP, BX/EX compatibility sections | `UnsupportedFeature`; no action execution, optional layer selection or unknown-operator skipping | `interactive-refusal`, `marked-refusal` |
| External stream F/FFilter/FDecodeParms, file specs, URI/remote references or other resource-bearing keys | `ExternalResource`; no resolver, network, file or process authority | `resource-refusal` |
| Catalog/page navigation, outlines, page labels, metadata XML, tags/structure, signatures and all other unlisted keys/operators/types | `UnsupportedFeature`, naming only a fixed construct code; no blanket unknown-key ignore | `unknown-refusal` |
| Text extraction/search, generation/editing, form filling, printing or viewer operations requested at the adapter boundary | `UnsupportedOperation`; no stub-success API | `operation-refusal` |
| Allowed Info/ID/font Name, comments and whitespace | Bounded validated ignore only; pixels must be invariant | `metadata` |
| Bad tokens/types, duplicate keys, inconsistent xref/parent/Count/widths, graph cycles, offsets/products, string escapes, operator arity/state | `Malformed`/`MalformedContent`, with bounded location | `malformed` |
| Bad zlib/DEFLATE, truncated/excess decoded image length, checksum/trailing compressed bytes | `MalformedStream`; no valid-prefix image | `malformed-stream` |
| Source/count/depth/expansion/geometry/work/storage/time limits | Specific §5 limit error; no truncated success | `limits` |

Engine errors are returned **by value**: fixed Code plus byte offset,
object number and page index (unavailable fields −1), static text ≤128 B.
No panic/recover interface, stack trace, source echo, content in diagnostics
or allocation-dependent error formatting. Adapter diagnostics ≤256 B/run
are fixed codes/counters. Admission limits precede parsing; thereafter
structure/object validation is physical object order, pages are page-tree
order, content is token order. Resource-bearing keys take ExternalResource
precedence over generic unknown-key errors.

**No partial publication.** A successful Render returns a complete
borrowed page slice. On any failure its output/scene prefixes are invalid,
even if earlier vector batches or image rows were written; return no page.
Vector's unchanged-destination preflight guarantee covers each call,
not an entire PDF transaction. Reinitialize background and reset all
page counters/state on reuse; preserve charged work already performed
within the failed call. Release input/output handles on every path,
retain the one arena for reuse, and let process teardown reclaim it.
Do not continue from a corrupted parser/glyph/decoder state.

The proof adapter renders fully before opening its bitmap output, writes
confirmed counts through native vi, and syncs/closes before its completion
marker. The artifact is a 16 B header (`PDF1`, then little-endian uint32
width, height, stride=width) followed by packed BGRA words: at most
**6,291,472 B/file**, streamed from the borrowed page with no output copy.
Output cap+1 is `OutputLimit`; write/no-progress/sync failures are
`WriteFailed`. Receipts contain fixed codes and numeric counters only.
`vi.FileClose` returns no status: closing is required, but this SDK does
not establish a separately detected close-error guarantee.
No old published artifact is overwritten. A newly created output
whose write/sync fails may be partial, is marked failed and never counts
as a page; no crash-atomic publication promise. Proof outputs use fresh,
gate-owned paths; an existing destination is `OutputExists`, not an
instruction to truncate it. This is not a concurrent publication service.
Application/resource/unsupported/I/O failures exit nonzero.
Harness timeout, panic, OOM,
kernel exception or silent process death is **failed acceptance**, not a
bounded refusal. Source bytes are immutable during Render; the adapter
checks complete source length/hash before publishing, failing
`SourceChanged` on drift, without promising safety against concurrent
mutation of borrowed buffers.

## 4. M90 boundary and page composition

M89 imports only ADR 0041's **version-1 exported Go types/API**:
`Command`, `Paint`, `Scene`, `Target`, `Workspace`, cumulative `Budget`
and `Rasterize`. It uses solid NonZero/EvenOdd fills, cubic curves
(quadratics are available but not required by this PDF subset), affine
mapping and per-paint integer Rect clips. Pixel format is packed,
top-down, straight-alpha **0xAARRGGBB**, little-endian BGRA; initialize
white `0xFFFFFFFF`. PDF itself introduces no translucent paints.
M89b verifies and maps every vector failure without lossy generic success.

For effective page box `(x0,y0,x1,y1)`, page mapping is
`{A:4/3, B:0, C:0, D:-4/3, E:-4*x0/3, F:4*y1/3}`.
Compose this on the **left** of the PDF CTM and glyph/text transforms.
M89 owns y-up point conversion, text metrics, CharProc expansion,
graphics-stack flattening into independent Paint records and integer
clip construction; all charge its ledger. Freeze each path endpoint/control
under the CTM **when its construction operator executes**: later cm/Q
must not move an already built path. Emit page-space Commands with an
identity Paint.Transform; vector then flattens curves in output space.
Glyph expansion applies text/FontMatrix/CharProc transforms at that same
construction boundary. PDF matrices and composed coefficients are finite
and within ±32,768; local/transformed points and offsets are within
±32,768 pt/px respectively. This allows a full-page image's unit-square
scale above 256 without passing that matrix to vector. Every emitted
vector affine still obeys ADR 0041's a/b/c/d≤256, e/f≤32,768 bounds
(identity satisfies them). Exceeding a numeric cap is `CoordinateLimit`.
Integral image/clip edges are checked after the specified float64 mapping
without epsilon snapping; nonintegral results are the explicit subset
refusal, not rounding to a different clip.
Never pass stack state, font objects, PDF operators or SVG syntax to M90.

ADR 0041 Target permits **1,024×1,536**; use Stride=Width, not padded
1,040-word rows, so maximum backing is **6,291,456 B**. No tiling,
extra page buffer or vector-contract change is needed.
Flush complete filled-path batches before each image Do, write image rows,
then resume fills. One path/glyph fill cannot be split across calls.
Page-wide command/paint/contour/edge caps and the shared vector Budget
never reset at batch, glyph, image or content-stream boundaries.

**M89b is blocked until M90b (#1935) lands** with this full API, target
size, error/preflight and memory/work semantics. No copied implementation,
second rasterizer, host rendering or silent alternative unblocks it.
M90c owns the independent vector consumer proof; M89c proves **PDF**
translation/composition, not another vector-only consumer.
M90 has no dependency on M89. M89 does not edit any M90 files or shared
draw/font/SDK/runtime code.

M89b's complete consumer boundary is `Render(source, pageIndex, arena,
ledger)` returning a borrowed Page, numeric Stats and by-value Failure.
Source supplies an immutable checked length and bounded read-at into
caller storage, no resolver; transport charges cache misses/discard/
rewind work and bytes to that **same ledger**. The caller supplies the
single aligned §5.1 arena; Render retains no source or Go pointers after
return. PageIndex is zero-based and out of range is `PageRange`; success
Page owns no memory and is valid only until arena reuse. Ledger starts
once per page transaction and includes source recheck before publication;
the implementation must not hide/reset adapter or vector counters.
M89b owns this engine contract/tests; M89c supplies native Source and
bitmap serialization read-only against it. The concrete exported Go
types are finalized within M89b, without changing this ownership/budget
contract or requiring M89c to edit engine files.

## 5. Final numeric budgets and boundary behavior

All limits are **inclusive**. Check before the allocation, push, expansion
or operation that would exceed them; return the named failure, invalidate
the page and clean up. Count capacities and page-rounded backing, not
only populated prefixes. Individually legal dimensions/source size do
not promise that every maximum-complexity combination fits all budgets.
No limit below is TBD or an observed runtime measurement.

| #1920 budget | Final ceiling and units | Accounting rule and boundary |
|---|---:|---|
| Engine/parser bytes added | **2,097,152 B** | Complete stripped static guest ELF delta against an equivalent empty adapter, identical pinned toolchain/flags/transport/writer/fixed buffers. Includes PDF parser, Flate, glyph/image adapter **and linked vector dependency**, with no subtraction for M90's ownership. Also require initialized PT_LOAD filesz delta ≤2,097,152 B; report full file/segment sizes and mapped memsz. Over limit is `EngineSizeLimit` acceptance failure; no source/object proxy. |
| Per-page parse/decode/raster time | **5,000 ms/page** at **1,024×1,448 px** | Includes whole-document validation for the requested page, all parse/decode, source reopen/discard/rechecks, glyph/state conversion, background initialization, vector preflight/replay, image rows and GC interruptions. Excludes initial input admission transport, VM/process launch, one-time arena setup and output serialization. Same 5,000 ms ceiling applies to every corpus page and maximum 1,024×1,536 page. Over limit discards result as `TimeLimit`; no slow successful bitmap. |
| Peak per-page memory | **12,582,912 B** | Entire retained engine arena plus resident document/cache/decoder/image/state/scene/output data **and Go runtime headroom**, partitioned below. Includes unused capacity, alignment, metadata, heap free spans and collector/stacks. No uncharged source/decoded copy. Exceeding any admitted partition or total is `MemoryLimit`; unprovable runtime backing blocks acceptance. |
| Raster dimensions | **1,024×1,536 px**, **32 bpp** | Positive packed dimensions derived at exactly 96 dpi; max output 6,291,456 B. Test both axes separately. Zero/reversed geometry is malformed; over dimension is `CanvasLimit`, fractional pixel extent UnsupportedPageGeometry, never scaling/truncation. |
| Input file | **4,194,304 B/document** | All bytes including comments, metadata and compressed streams, measured by a complete sequential admission scan with cap+1 probe. Not retained whole. Larger is `SourceLimit` before parse; short read/I/O/changed source is an explicit failure. |
| Parsed indirect objects | **8,192 objects/document** | Distinct in-use definitions, including streams and unused resources, not only selected-page objects. Object zero is not parsed; xref has ≤8,193 slots including sentinel. Reparse/reuse charges work, not a new distinct-object allowance. Reject `/Size`/definitions above cap as `ObjectLimit` before table writes. |
| Object/reference traversal | **32 frames** | Container nesting and forward reference traversal each use an explicit checked stack, root depth 1. Page-tree descent counts; repeated references on an active traversal path detect cycles. Parent links are checked back-links, not traversal edges. Push 33 is `DepthLimit`; no recursion overflow. |
| Content/graphics nesting | **16 frames** | q frames plus an entered CharProc share a page-wide active-depth counter; initial page context depth 0, CharProc adds 1. Literal-string nesting separately ≤32. No forms/nested text/recursive glyph execution. Enter 17 is `GraphicsDepthLimit`; underflow/unbalanced end is malformed. |
| Expanded stream bytes | **16,777,216 B/page call** | Cumulative bytes produced by all content/glyph/image/other accepted streams decoded during whole-document validation **and rendering**, including repeated/unused/clipped streams and each decode pass. Raw streams count too. Charge before emitting a byte; byte 16,777,217 is `ExpansionLimit`. Never permission to retain 16 MiB. |
| Work | **256,000,000 units/page call** | Entire §5.2 ledger, never reset inside Render. Replaces draft 1,000,000: background alone has 1,572,864 pixels/6,291,456 B at maximum page, before parsing, AA or images. Next unit over cap is `WorkLimit`. Vector subledger separately ≤64,000,000 units under ADR 0041. |

Additional hard bounds: **256 pages/document**, **256 dictionary keys**
(resource name tables ≤64),
**512 array entries** (page Kids may use ≤256), **32 B numeric token**,
**64 B name**, **4,096 B decoded string/show**, **16,384 B ignored
metadata/document**, **16 Contents streams/page**, **64 Font and 64
XObject resource entries/dictionary**, **16 fonts/page**, **256 glyphs/font**,
**16 operand values**, **8,192 normalized commands/page call**,
**1,024 paints**, **1,024 contours**, **8,192 expanded edges**,
**12 curve-subdivision levels** (ADR 0041), **32 source rewinds/page call**,
**134,217,728 source bytes read/discarded/page call**, **2 native open
file handles**, **2 live decoder frames**, **256 B diagnostics/run**,
**16,384 B proof receipt/run**.
Glyphs/images repeated in validation/render charge the same page ledger;
record capacities are separate from executed outline counts. Vector
counts/work use its published planning/replay rules. `TokenLimit`,
`ContainerLimit`, `PageLimit`, `FontLimit`, `SceneLimit`, `SegmentLimit`,
`ReadLimit`, `HandleLimit`, `DecoderLimit` or `ReceiptLimit` names the
exceeded bound.
All products, offsets and counters use checked arithmetic.

### 5.1 Resident-data and runtime plan

Reserve one populated, reusable **9,437,184 B (9 MiB) private anonymous
arena**, with pointer-free aligned records. No Go strings/maps/interfaces
or managed pointers stored in mapped POD memory:

| Partition | Maximum reserved capacity | Contents |
|---|---:|---|
| Packed page output | 6,291,456 B | One maximum page; no copy for publish |
| Vector scene storage | 1,048,576 B | Commands/Paints; prefixes reused only after completed batches |
| Vector Workspace | 524,288 B | ADR 0041 row/subdivision scratch |
| Resident document and source cache | 262,144 B | 8,193×16 B xref records = 131,088 B; 65,536 B source window; remaining 65,520 B for document/page/resource descriptors |
| Streaming decode/image scratch | 262,144 B | Two decoder frames ≤65,536 B each (each includes 32,768 B DEFLATE history plus bounded Huffman/block state), staging, ≤3,072 B image row and sample indices; no decoded stream cache |
| PDF graphics/glyph/parse/I/O state | 524,288 B | Bounded stacks/tokens/temporary outlines, native ≤2,048 B file staging, output/receipt/hash buffers |
| Alignment/unassigned arena margin | 524,288 B | Still charged, not an implicit second allocator |
| **Total engine arena** | **9,437,184 B** | **2,304 pages** |
| **Runtime/collector/wrapper headroom** | **3,145,728 B** | **768 pages**, outside arena but inside page ceiling |
| **Total per-page ceiling** | **12,582,912 B** | **3,072 pages** |

The 4 MiB **file is not a 4 MiB resident allocation**. Kernel/native `vi`
handles are sequential; the std syscall overlay's Seek/Pread emulation
retains a growing shadow (`fs_virelai.go:94-143`, up to 16 MiB), so using
`os.File.ReadAt` would defeat this plan. M89c implements the engine's
bounded read-at source using **vi.FileOpen/FileRead/FileClose**, a 64 KiB
window, forward discard and close/reopen from byte zero for a backwards
miss. At most one source handle; at most two total with output/receipt.
Rewinds and discarded bytes charge work/time/read caps. Initial admission
records length/hash; before publication a complete sequential source
recheck also charges the Render ledger. Never spill a decoded document
or use a host random-access service as an unclaimed guest dependency.
Buffer exhaustion refuses; it does not allocate a larger cache.

Render revalidates the whole file per page; there is no document-level
unbounded AST or cache surviving between pages. Arena buffers, source
window, xref and every unused partition remain charged on small pages.
Reuse one mapping for **100 success/refusal cycles**, not one mapping/
heap per page. Engine parsing/decoding/outline/raster loops allocate no
heap after setup and spawn no goroutines; ordinary Go headers, runtime
startup, GC metadata/retained free spans and stack growth still cost the
runtime allowance. No `fmt`, general DOM or unchecked append growth.

`process.zig` caps recorded demand-backed pages at **4,096 = 16,777,216 B**
and mmap regions at **16**. This plan leaves **1,024 pages =
4,194,304 B** below that dynamic-page cap, not extra engine permission.
Require **≤12 occupied mmap regions**, one arena plus at most eleven
runtime/other, leaving four spare. Statically loaded ELF segments also
need loader validation and separately reported page-rounded mapped bytes;
ELF datapages/VM RAM are not a runtime dynamic-page measurement.

**Runtime sufficiency is not observed.** M89b/c must prove ≤3 MiB
runtime headroom and the total/region bounds with a conservative ledger
from the pinned runtime mapping/touch paths plus allocation receipts,
including GC and failed-input reuse. HeapAlloc alone misses free spans,
metadata and stack/mmap growth. Mapping extents can conservatively charge
demand-backed backing, but virtual reservations alone cannot prove touched
pages. `vi.ProcRow` does not expose the required counters.
If existing diagnostics cannot prove this without kernel/runtime edits,
block acceptance and request a separately owned diagnostic. Do not claim
that 256 MiB guest RAM makes it fit. A larger ceiling would require an
owner-reviewed revision backed by the failed ledger/measurements; no
increase is authorized here.

### 5.2 Work and time accounting

Charge before each source-byte examination/copy/zero/hash (including
rescans/discards), token/operand/object/reference/stack/record operation,
point/matrix transform, glyph expansion, DEFLATE input-bit examination,
Huffman table entry/comparison, block iteration and output/backreference
byte, checksum byte, image sample/write and output background byte.
Arithmetic within one named operation is bounded; a bulk routine does
not become one unit. Offscreen/empty/unused data and failed attempts count.
Source I/O syscall attempts each add a unit; source bytes also count.
No data-dependent recursion or unchecked sort/decoder loop.

Vector owns its precise preflight/replay ledger; pass one cumulative
Budget across all calls, Max≤64,000,000. Add each call's Used delta
(Stats.Work, including on failure) to PDF work **once**, not again for
its individual internal operations. Before a call, lower vector Max to
the remaining PDF allowance plus existing vector Used, capped at its hard
limit; reject if no room. PDF preprocessing/background/image work remains
separate. Exact counter tests cover every category and batch/glyph/decode
reuse; optimizations retain conservative charges.

Reference hardware: **Apple M4, 16 GiB host RAM, macOS 27.2, Apple VZ,
2 vCPUs, 256 MiB guest RAM**. Read existing `vi.Nanos` (monotonic guest
nanoseconds), record counter frequency/resolution, toolchain/build mode,
host load and VM settings. Pass/fail uses integer ns ≤5,000,000,000,
not rounded milliseconds/whole-second wall time. For every accepted
page take one first render and 20 repeats after arena setup; report
the **maximum**, including the first, not a mean or discarded slow sample.
No pre-parsed/pre-decoded page in the timed path.

Check the monotonic deadline at entry/exit and at least every **1,024**
charged PDF operations; bounded cleanup must complete within the page
ceiling on the reference host. Check before/after each vector call.
Vector cannot be interrupted mid-call: its work bound/preflight makes it
finite, and a result finishing after the deadline is discarded as TimeLimit.
No hard-real-time claim under host descheduling; unbounded native I/O or
an externally killed process blocks acceptance, not a successful timeout.
Every corpus negative must produce its named bounded refusal within
5,000 ms too.

## 6. Corpus, independent reference provenance and comparison

Name the corpus **M89-PDF1**. M89b owns small authored engine fixtures in
`tests/fixtures/pdf/engine/*`; M89c owns independently reviewed acceptance
fixtures/manifest in `tests/fixtures/pdf/acceptance/*`. No third-party
document corpus, hidden fonts, downloads or private user documents.
Commit small PDF byte vectors/provenance/feature references, not large
bitmaps, logs or timing narratives.

The finite accepted corpus has **16 authored pages**, each ≤16,384 B:

| IDs | Required coverage |
|---|---|
| `empty`, `gray-rect`, `rgb-order`, `open-lines` | White/empty, g/re/f/F, rg paint order, m/l/h/open closure/n |
| `cubic`, `nonzero`, `evenodd`, `affine` | c/v/y, compound/reversed holes, f* intersection, cm/reflection/singular no-paint |
| `save-restore`, `rect-clip`, `split-streams`, `flate-content` | q/Q incl. text state, W/W* and old-clip paint order, operands/state across Contents (A1.1), stored/fixed/dynamic Flate |
| `type3-position`, `type3-spacing`, `gray-image`, `rgb-image` | All text position/state/show operators, explicit glyph/space/d1 metrics, both colorspaces, raw/Flate, clipping/scaling/reflections and fill/image order |

Parameterized engine/acceptance cases cover **every** allowlisted key,
default, placement, operator, string/number spelling and filter form,
all three DEFLATE block kinds, stream boundary cuts, glyph encoding
and inherited properties. The 16 pages are readable anchors, not an
excuse to omit the rest of §3. Manifest coverage maps every declared
feature and every exclusion row to a test category/fixture.

Additional generated maxima: 768×1,086 pt →1,024×1,448 full fill/text/image
page (the time workload); 768×1,152 pt →1,024×1,536 with a bottom-row
feature; a full-page Flate RGB image; a 4 MiB admitted source with bounded
metadata-free comments; and low-work capacity cases for each independent
numeric boundary. Large sources/reference PPMs are generated offline from
small pinned recipes/hashes into ignored artifacts, not committed.

**Independent oracle: host-only Poppler `pdftoppm` 26.09.0.**
The inspected installed binary SHA-256 is
`9a44364d0fa42a43c3efdb2cbab47d275973c4a5856c1109f6bf4513def6bb54`.
Its installed COPYING/COPYING3 are GPL license notices; this tool is
separate host test apparatus, not linked/vendored into the proprietary
guest. Retain version/license/build/dependency provenance with the
reference recipe. A version string alone is not a reproducibility pin:
M89c freezes its exact acquired build and font/color libraries/checksums,
PDF/recipe hashes and invocation in the acceptance manifest. Other host
builds must be explicitly revalidated, never silently substituted.

Run accepted, self-contained fixtures offline with:
`pdftoppm -r 96 -f N -l N -singlefile -aa yes -aaVector yes INPUT OUTPUT`.
PPM RGB is converted to packed opaque BGRA; record exact effective box,
dimensions, backgrounds and oracle/reference hashes. For an accepted
CropBox override use the pinned `-cropbox` invocation. No system text
fonts are used: outlines are inside the PDF, and images have only device
gray/RGB/default Decode. The observed 64×64 smoke input/output hashes are
`d247ce42d12d1221a6c4a8f34a9e9c60e3eb18e3a8b013a632e7fc60fc3858bf` /
`d80bc85e1773bc56ae881b787c06afba8a2db357fed5da2523dddafda2f7be7a`.
These are diagnostic identities, **not frozen acceptance goldens**.
Do not send hostile/out-of-subset negatives through the oracle.

Require exact dimensions, opaque alpha, flat-color interiors, integer
clip/image boundaries, image samples and analytic empty/state/metadata
invariance. For **vector/glyph edge pixels only**, allow max channel
difference **64/255**, whole-image mean channel difference **1/255**,
and no discrepancy outside a **one-pixel Chebyshev dilation** of the
independent oracle edge mask. Derive the mask only from the oracle's
adjacent differing/non-flat pixels; never from tested output. Text uses
the same edge rule, not an OCR/content-only comparison. No tolerance for
missing glyphs, wrong color/order/spacing/clip/image orientation.
For image fixtures choose unambiguous integer sample geometry and assert
analytic nearest-neighbor pixels; mismatched oracle sampling must be
resolved explicitly, not granted a broad image tolerance.
A1.2 and A1.3 define those analytic references, move the vector/glyph
edge mask and tolerances onto them, and fix the oracle's remaining role.
Identical input/toolchain algorithm host/guest Go pages are bit-identical.
A renderer checksum compared with itself is not independent evidence.

Malformed/out-of-subset corpus has a fixture for **every §3.5 row**,
including unused fonts/images, unpainted paths and pages not selected.
For each numeric bound test limit and limit+1 (nearest representable
value for real bounds), integer overflow, all truncation positions in
small fixtures, dangling/cyclic refs, malformed zlib blocks/distances,
bombs, trailing bytes, malformed strings, cleanup and next good render.
A within-one-limit input may hit another explicit limit, never a
fabricated success; provide separate low-work fixtures demonstrating
each supported capacity. Repeat success/refusal/recovery 100 times and
prove no retained-buffer/handle/region growth plus post-exit reclamation.

## 7. Final M89b/M89c split and gate ownership

These are the complete final shapes, **not newly filed issues**.
Landing this design records owner acceptance; no additional pre-merge
approval-state gate is required. Implementation claims follow landing.

| Card | Gate-syntax Touches (complete, comma-separated) | Complete deliverable / verification |
|---|---|---|
| **M89b — complete bounded PDF engine**, after M89a and **M90b #1935** | `user/go/pdf/*, tools/pdf-engine/*, tests/fixtures/pdf/engine/*` | All §3 parsing/whole-document validation, work-instrumented raw/Flate decode, page/text/glyph/image translation, ordered vector/image composition, exact errors/cleanup/limits and borrowed caller-buffer Render contract. Offline full/empty engine adapters and lock/dependency/ELF/delta checks; host feature/malformed/boundary/golden/counter/allocation/reuse tests and conservative runtime-ledger recipe. Run `go -C user/go test ./pdf/...`, owned tool tests/build inspections and `git diff --check`. Cross-build complete engine, not a parser-only milestone. M90 files remain read-only. |
| **M89c — PDF source/bitmap proof and VZ acceptance**, after M89b | `user/go/pdfproof/*, tools/pdf-proof/*, tests/fixtures/pdf/acceptance/*, tools/gate/specs/live-pdf-raster.spec` | Native vi source-window/reopen adapter, no-UI page producer/receipts, full M89-PDF1 coverage/provenance/oracle/comparator, offline product builder, VZ pixels/refusals/time/size/memory/work/cleanup receipts. Run host adapter/comparator/manifest tests, `just gate live-pdf-raster`, `bash tools/inventory-gates.sh --check`, `bash tools/status/verify-issue-coordination.sh`, `git diff --check`. Engine files read-only; no vector-only consumer duplicated. |

Reservations are exact files or terminal `dir/*` prefix globs, including
descendants. They are disjoint from each other and ADR 0041 §7's M90b
`user/go/svg/*, user/go/vector/*, tools/svg-engine/*, tests/fixtures/svg/engine/*`
and M90c
`user/go/svgproof/*, user/go/vectorconsumer/*, tools/svg-proof/*, tests/fixtures/svg/acceptance/*, tools/gate/specs/live-svg-raster.spec`.
Shared draw/font/SDK/runtime, root build/module/manifests, kernel input,
other ADRs and status files are outside both M89 scopes. Any necessary
shared-file change blocks that step pending owner sequencing/revised
Touches; it is not an unclaimed fix or reason to touch active M88/M90/M91
lanes. No implementation cards are filed by R1.

**Gate: one new declarative `live-pdf-raster` spec**, following
`tools/gate/SPEC.md`. `live-image-viewer` is GOVIEW's QOI/window/PNG-refusal
proof, not a PDF bitmap producer; `live-svg-raster` is independently owned.
Keep both unchanged. No verify shell gate or generated fleet-inventory
commit. Discovery registers the new spec.

M89c stages prebuilt proof ELF/fixtures and verified reference inputs
with vgate_setup_python; missing artifact, oracle/pin or counter receipt
fails, not skips. One invocation per boot, separate boots for accepted
pages, refusals/recovery, maxima and runtime/reclamation proof. End on
the **program's** completion marker after writes/sync/close, not a script
echo. Independent vgate Python assertions compare shared bitmaps and
receipts, preserving asserted outputs before share teardown.
Require named refusals, zero unexpected exits/no `[EXC] parking:`,
all maximum timing/work/memory values and independently justified backing/
handle reclamation. Standard logs use ignored gate artifacts; detailed
receipts/reference products remain ignored acceptance artifacts.

## 8. R1 acceptance and precise blocked diagnostics

The six #1920 answers map to **§3 (exact subset/errors), §2 (survey),
§5 (all budgets), §4 (M90 API/dependency/size), §§6–7 (corpus/split/gate),
and §§1–2/4 (Go language boundary)**. The six index answers map to
§3, §2, §5, §§3.5/5, §4 and §7. Owner review on landing covers all of
these, including the deliberately limited Type 3 font/image choices.
R1 changes only this ADR; run `git diff --check` and
`bash tools/status/verify-issue-coordination.sh`.

**Blocked/unperformed, not survey results:** the worktree-default Go fork
executable was absent when checked. Offline guest cross-build needs an
explicit existing `GO_FORK_DIR` with the repository's prepared pinned
fork; no build failure or automatic preparation was attempted here.
The PDF engine and M90b API implementation have not been supplied by this
design card. Guest ELF delta, pixels, per-page timing, runtime headroom/
region proof and cleanup therefore remain M89b/c evidence owed.
The host oracle smoke ran; the full frozen oracle dependency environment,
M89-PDF1 references and acceptance comparisons remain M89c work, not
already passed diagnostics. MuPDF's commercial-license approval and
freestanding dependency closure were not obtained, and it is rejected.

This design leaves **#1916 open**. The owner accepts that index only
after every declared corpus PDF produces independently correct guest
bitmaps within all budgets, every malformed/out-of-subset case refuses
boundedly, and both implementation cards land with their complete evidence.

## Amendment (A1 / #1916, 2026-10-04) — oracle rulings and stream-boundary tokens

The M89c and M89d evidence (#1950, #1959; draft PRs #1954, #1960) left
eight accepted cases where the engine matches an analytic expectation
but not pinned Poppler: vector/glyph edges in `nonzero`, `evenodd` and
`type3-spacing`; integer clip/image edges in `rect-clip`, `gray-image`,
`rgb-image` and the time page's image column; and `split-streams`, whose
`rg` token is cut across two Contents streams. The owner ruled on all
three classes. A1 replaces only the rules named below; every other §3,
§5 and §6 rule, limit, tolerance value and pin is unchanged.

### A1.1 — A Contents stream boundary is a token boundary

Replaces §3.2's former "tokenizer ... may cross a stream boundary".
Operands, the current path, an open text object and graphics state still
carry across streams in array order; a token does not. Refuse
`MalformedContent`, located at the later stream's first byte, when:

- a literal or hexadecimal string is still open at a stream's end; or
- the last byte of one non-empty stream and the first byte of the next
  non-empty stream are both regular characters (neither white-space nor
  a delimiter, ISO 32000-1 §7.2.2).

Empty streams are skipped when finding neighbors, and a comment ends at
its stream's end. ISO 32000-1 §7.8.2 already allows a split only between
tokens. The subset is deliberately stricter: it also refuses an abutting
pair such as `Q`|`q`, so it never chooses between one token and two.

- **M89d (#1959)** implements the rule under `user/go/pdf/*` and
  `tests/fixtures/pdf/engine/*`. §6's stream-boundary cuts now mean: a
  cut inside a string refuses; a cut between two regular characters
  refuses; a cut inside a comment ends the comment there; every other
  cut renders identically to the uncut stream.
- **M89c (#1950)** re-authors `split-streams` so every boundary falls
  between tokens while operands, path, text and graphics state still
  cross, and keeps the current token-cut bytes as a named negative that
  expects `MalformedContent`. Negatives still never go through the oracle.

### A1.2 — Integer clip and image edges: the analytic reference wins

Refines §6's exact clip/image rule. For W/W* clips (§3.2) and image
placement (§3.4) the comparator computes an analytic reference from the
fixture's authored recipe: half-open integral device extents, clip
intersection and old-clip paint order, reflections, and nearest-neighbor
pixel-center sampling with ties toward the higher source index, using
the image's own samples. The engine must match it on every pixel.
Poppler must match it on every pixel more than one pixel (Chebyshev)
from an analytic clip or image boundary. Inside that band the analytic
reference wins: `tests/fixtures/pdf/acceptance/oracle.json` records each
case's Poppler disagreement count and the SHA-256 of its sorted
coordinate list, and any change to either fails until reviewed. No clip
or image tolerance is introduced.

### A1.3 — Vector and glyph edges: an analytic coverage reference

Refines §6's vector/glyph edge rule. The comparator (`tools/pdf-proof/*`)
derives device-space geometry from each fixture's authored recipe
(paths, CTM, text and line matrices, spacing, Type 3 metrics and
outlines, curves flattened to at most 1/64 px error) and rasterizes it
with ADR 0041 §3.2's specified sampler: four vertical samples at
y+1/8, 3/8, 5/8 and 7/8, exact horizontal span overlap, nonzero or
even-odd winding and 8-bit rounding, composing paints in document order.
It imports no `user/go/pdf` or `user/go/vector` code and never reads
tested output.

- **Engine against the analytic reference:** flat interiors are exact.
  Edge pixels keep the §6 values: maximum channel difference 64/255,
  whole-image mean channel difference 1/255, and no discrepancy outside
  a one-pixel Chebyshev dilation of the analytic edge mask
  (partial-coverage pixels plus adjacent pixels whose analytic color
  differs).
- **Poppler as the independent geometry check:** it must match the
  analytic reference exactly outside a one-pixel Chebyshev dilation of
  the union of both edge masks, and its edge mask (§6 derivation) and
  the analytic edge mask must each lie within the other's one-pixel
  Chebyshev dilation. Its edge-pixel values are recorded as diagnostics,
  not held to the 64/255 or mean bounds.
- A failed cross-check is an oracle disagreement for owner review, never
  a pass, a widened tolerance or a re-derived mask.

### A1.4 — Ownership and acceptance

A1 changes no limit, budget, threshold, pin or card split. M89d owns the
A1.1 engine rule and its engine tests; M89c owns the re-authored corpus,
recipes, analytic references, comparator and `oracle.json` records.
Neither card edits this ADR. §8's acceptance condition for #1916 is
unchanged, with "independently correct" judged by A1.2 and A1.3.

## Amendment (A2 / #1916, 2026-10-04) — CoreGraphics replaces Poppler

The owner ruled that VirelaiOS never contains GPL-family code, and that
new host tools and test references are not GPL-family either (AGENTS.md
scope rules). Poppler is GPL-2.0-only OR GPL-3.0-only, so A2 removes it
from M89's verification chain. A2 replaces only the outside reference.
Every §3 and §5 rule, every §6 rule other than the outside reference
itself, A1.1–A1.3's comparison rules, and every limit, budget, threshold
and analytic reference are unchanged.

### A2.1 — The outside reference is Apple CoreGraphics

Replaces §6's "Independent oracle: host-only Poppler `pdftoppm` 26.09.0"
paragraph and its invocation. The outside reference is the macOS
CoreGraphics PDF renderer (`CGPDFDocument` and `CGContext.drawPDFPage`),
driven by a small host-only Swift tool under `tools/pdf-proof/`. It is
part of the operating system on every supported host (`AGENTS.md`): there
is nothing to download, vendor, link into the guest or ship. The tool
renders:

- the §3.1 effective page box at 96/72 scale, so a 48 pt page is 64 px;
- into an 8-bit DeviceRGB bitmap context, filled opaque white first;
- with antialiasing on and image interpolation off;
- to the comparator's packed opaque BGRA, rows top to bottom.

`oracle.json` provenance pins the macOS product and build versions, the
Swift compiler version and the tool source's SHA-256, plus the existing
PDF, recipe and invocation hashes. An OS update counts as reference drift:
references are re-frozen only after review, never silently. Negatives
still never go through the outside reference.

### A2.2 — Comparison rules are unchanged

A1.2 and A1.3 apply as written, with "Poppler" read as "the outside
reference": the same edge masks, one-pixel Chebyshev dilations,
exact-match regions, diagnostics-only edge values, and the frozen per-case
disagreement count and coordinate SHA-256 in `oracle.json`. A failed
cross-check is still an oracle disagreement for owner review.

The `affine` disagreement in #1950 was a Poppler observation and does not
carry over. CoreGraphics output is judged afresh.

### A2.3 — Diagnostic evidence (observed, not acceptance)

A host spike on macOS 27.2 (build 26B5091g) with Swift 6.4 and the
A2.1 contract cross-checked all 39 accepted rows (the 16 authored pages
plus the generated maxima and capacity cases) against the current
analytic references, using the existing comparator. It found no geometry
failure and no disagreement outside the edge bands. Flat colors and
nearest-neighbor image samples matched exactly, and `affine`'s singular
square painted nothing. Five blank capacity pages omit the optional
`/Contents` key: CoreGraphics logs a diagnostic for them and renders the
correct blank page. The spike's tool and outputs are not committed; the
owning card re-derives and freezes them.

### A2.4 — Ownership

A follow-up M89 card under #1916 owns the swap within M89c's former
paths (`tools/pdf-proof/*`, `tests/fixtures/pdf/acceptance/*`,
`tools/gate/specs/live-pdf-raster.spec`). It removes every Poppler
invocation, pin and record, freezes the CoreGraphics references, and
runs the full gate. No engine file changes. Earlier Poppler records stay
in git history only. §8's acceptance condition for #1916 is unchanged.

## Amendment (A3 / #2921, 2026-10-21) — the bounded writer

§1's "no ... generator" exclusion is lifted for exactly one package:
`user/go/pdfwrite` writes documents inside this same closed subset, so
the OS's own reader is the writer's verifier. Everything the writer
emits is producible only within the §3 allowlist; anything else is a
named refusal, never a silent approximation. Every §3, §5 and §6 rule
is unchanged; the writer is a producer of the subset, not a widening of it.

### A3.1 — The written subset

- US Letter pages only (`[0 0 612 792]`, 816×1,056 px at 96 dpi), at
  most 64 per document, under the reader's 256.
- `%PDF-1.4`, a classic `0 N` xref table, trailer `Root`/`Info`, and an
  Info dictionary carrying Title, Producer and a guest-clock
  CreationDate.
- One uncolored Type 3 font whose CharProcs are font8x8 glyph
  rectangles (`re`, fill only), subset to the codes actually shown;
  bytes outside 0x20–0x7E draw as `?`.
- DeviceRGB and DeviceGray 8-bit image XObjects.
- Content and image streams are FlateDecode streams produced by the
  writer's own fixed-Huffman plus bounded-LZ77 deflate encoder inside
  `pdfwrite`; `user/go/flate` remains read-only.
- Document bounds are the reader's own ceilings: ≤4 MiB output,
  ≤16 MiB expanded streams, and the 8,192 normalized-command page
  budget accounted before any bytes are returned. Refusals are named:
  `page_too_large`, `too_many_pages`, `output_over_budget`,
  `bad_raster`.

### A3.2 — Still out

A viewer, an editor, forms/annotations, a print pipeline, font
embedding of any kind (base-14, TrueType, CID), strokes, transparency,
PDF/A, encryption, A4 and non-ASCII text all stay out. The writer does
not change the reader, the engine lock, or any consumer; the consumers
are separately claimed cards.
