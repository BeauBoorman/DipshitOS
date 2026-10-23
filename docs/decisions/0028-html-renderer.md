# ADR 0028: In-guest HTML rendering (M-web slice 1)

- Status: ACCEPTED (slice 1 design); amended M70d #1456 2026-09-19; amended M69d #1531 2026-09-20; amended M71i #1568 2026-09-21 (the EL0 consumer is WEB.ELF). Amendment D: **PROPOSED, awaiting Timothy's owner review** (#1993); no approval has been recorded.
- Date: 2026-09-12
- Issue: #1200 (design card + slice 1), umbrella #1201
- Related: ADR 0009 (app events), ADR 0010 (userland storage), ADR 0011
  (desktop platform), ADR 0016 (pixel ownership), ADR 0013 D3.1 (.bss budget),
  ADR 0026 (Go runtime port — numbering note below), M40 GF6 (gate rules),
  `docs/archive/html-renderer-scoping.md` (the design card this ADR fixes),
  M70d #1456 (JS-in-WASM measurement), `docs/wasm-import-contract.md`

## Context

Oliver (a real Zig CLI tool) runs in-guest on the native ELF path and emits
HTML byte-exactly — `tests/oliver-spike/expect.html` is pinned, and #1191
verified it against the host CLI's own output. Nothing in VirelaiOS can display
that output. The project wants the other half of the pipeline in-guest:
Markdown → oliver → HTML → pixels, with no host round trip.

The temptation is to aim at "a browser". That would import two enormous,
unbounded pieces of scope (a JS engine and a CSS cascade) into an OS whose
userland has no allocator-heavy services, no threads-to-spare, and a 512×424
user back-buffer. The project's own history is the counter-argument: every
subsystem that landed cleanly (text editor, terminal, WM, layout engine) did so
as a bounded slice with a declarative gate.

ADR numbering: **0027 is claimed by #1194** (GOOS=virelai 0b, threads/futex).
This ADR takes 0028 rather than racing it; if a future card wants a number,
check `docs/decisions/` and the open claims at push time.

## Decision

**D1 — The renderer is userland.** `DOC.BIN` (`user/src/doc.zig`) is an
ordinary EL0 app over `lib/tabapp.zig`. No new syscalls, no kernel changes;
the kernel never parses HTML. It stays inside the app's existing privileges
(file channel, window back-buffer, events).
**Amended M71i #1568 (2026-09-21):** the EL0 consumer is **`WEB.ELF`**
(`user/go/browser` + `user/go/webrender`, a Go app on the host-share ELF path).
`DOC.BIN` and `user/src/doc.zig` are **deleted** — two HTML painters was the
dual toolkit ADR 0030 forbids, and the Go path already owned the features this
ADR's ladder named (S1 render, S2 tables/dl, S3 images, S4 links, S5 fetch, S6
publish). D1's *shape* is unchanged: still an ordinary EL0 app over the tab
seam, no new syscalls, no kernel HTML.

**D2 — No JavaScript, and no CSS cascade.** Styling is a single compiled-in UA
style table (per-tag size/margins/indent/mono flags). A page cannot change its
own presentation. This is a permanent property of the arc, not a slice-1
shortcut: if pages later need styling, the answer is a rendering *hint* in the
source (as Markdown tooling already produces), not a cascade in the guest.
**Amended M70d #1456 (2026-09-19):** scripting also does not land as a
`wasm32-freestanding` guest under `WASM.BIN`. The measurement is Amendment A
below; raising interpreter caps (`max_module_size`, `max_frames`, wasm EH) to
admit an engine is a **new ADR**, not a silent follow-on.
**Proposed M93a #1993 (2026-10-05):** Amendment D replaces the CSS half of
D2 only after owner approval. The UA-only text above records the accepted
pre-M93 rule; it is not an authorization to implement CSS before that approval.
**No JavaScript** remains word for word. D1 and D3–D7 are not reversed.

**D3 — parse → layout → paint are separate modules, two of them pure.**
`lib/html/parse.zig` (bytes → flat node array) and `lib/html/layout.zig`
(nodes + style + width → line boxes) are framebuffer-free and host-tested under
`zig build test`; `layout` takes the text measurement as an injected function
so tests use a stub metric. Only `doc.zig` touches `ui` drawing. This is the
same shape as the repo's other testable subsystems, and it is what makes the
renderer's behaviour assertable without a VM.
**Amended M71i #1568 (2026-09-21):** `user/src/lib/html/` is **deleted** with
its consumer, and so is its `zig build test` registration (21 host tests). The
rule survives the language: `user/go/webrender` keeps parse
(`htmlparse.go`), layout (`layout.go`) and paint (`paint.go`) as separate
packages/files with their own host suites (`htmlparse_test.go`,
`layout_test.go`, `text_test.go`, `url_test.go`, `golden_test.go` over the
pinned corpus), so the renderer is still assertable without a VM. Nothing was
left half-deleted: no orphaned module, no test with no runner.

**D4 — Emphasis uses real faces when they are staged, and synthesizes only as fallback.**
Share names (frozen M69d #1531 D1): `/host/INTER.TTF` Regular, `/host/INTERB.TTF`
Bold, `/host/FIRACODE.TTF` mono, optional `/host/INTERI.TTF` Italic.
**Amended M69d #1531 (2026-09-20):** Go WEB selects Inter Bold for `<strong>` /
headings when `INTERB.TTF` parsed; the 1-px second strike is dead on that path
and remains only when Bold is absent. Inter-4.1 extras ships `Inter-Italic.ttf`,
staged as `/host/INTERI.TTF`; `<em>` selects it (accent colour stays). Zig
`ui.init_fonts` and DOC.BIN consume the same four names as of M69d2 (#1536),
which is also where the 1-px strike became a fallback on that tree. Amendment B
records the observed files and both trees' measurements.

**D5 — Unknown elements degrade to their text content.** Unsupported tags
(and malformed markup) are flattened into the enclosing block in document
order — never dropped, never fatal. This is a deliberate consequence: the
pinned oliver fixture contains a `<table>`, which slice 1 does not lay out, so
the cells must still appear as readable text. "Renders nothing and looks fine"
is the failure mode this rule forbids.

**D6 — Static caps, no heap; overflow is visible.** File bytes live in an
anonymous mmap region (M29 slot 63, the `view.zig` pattern); the node and line
arrays are fixed-capacity with a documented truncation marker. A page that
exceeds a cap renders a visible truncation notice rather than panicking or
silently cutting text.

**D7 — The arc is a ladder, and each rung earns its own gate.**
S1 the tag whitelist above (local file, keyboard scroll, error path);
S2 tables and definition lists; S3 `<img>` via `lib/png.zig`/`lib/qoi.zig`;
S4 links + navigation through TabApp's nav seam; S5 `DOC.BIN <url>` over the
existing FETCH/HTTP seam — the first network rung, explicitly last among the
render features; S6 the publish workflow (batch oliver → share → DOC/HTTPD).
Each rung is a declarative `tools/gate/specs/live-doc*.spec`; no renderer
behaviour lands without a pixel probe.
**Amended M71i #1568 (2026-09-21):** those three specs are retired with the
app. The ladder is unchanged and every rung still has a pixel probe — it now
lives on the surviving renderer: `live-web` boots 01–04/14 and `live-web-ttf`
boots 01–04 (Amendment C carries the rung-by-rung map).

## Consequences

- The markdown toolchain gains an output path in-guest, and the "my Zig runs
  on VirelaiOS" story gains a visible end product.
- Renderer quality is bounded by the UA table, so a page's look is a project
  decision rather than an authoring one. That is accepted (D2) and is why the
  table lives in one reviewable place.
- Layout correctness is testable without a VM, so regressions in wrapping or
  block stacking show up in `zig build test`, not only in a live gate.
- The gate's pixel probes depend on the fonts actually loading; a silent
  fallback to the 8×8 bitmap would change metrics. The spec asserts the
  typography markers alongside the pixel probes for that reason.
- Network, JS, and cascade stay out by rule (D2, D7), so the "browser" framing
  cannot be used to smuggle unbounded scope into a slice. M70d measured the
  "JS as a WASM module" escape hatch and closed it under the frozen caps
  (Amendment A).
- EDIT's inline wrap chunking remains a local implementation; NOTEPAD's tested
  `TextLayout` rule is the shared reference. Unifying them is a cleanup card,
  not a prerequisite.

## Amendment A — M70d #1456: JS does not fit the sandbox

Date: 2026-09-19. Card: #1456 deliverables 2–3 (a bounded JS subset as a
`wasm32-freestanding` module under `WASM.BIN`, measured before promising).
A negative result closes the card. Host: `zig` 0.16.0 (Homebrew), macOS 27.2
arm64, VZ `hv_vm_create -> HV_SUCCESS`.

The frozen interpreter caps (not re-decided here):

- module ≤ 64 KiB (`user/src/wasm.zig` `max_module_size`)
- linear memory ≤ 32 pages / 2 MiB (contract §2 D2)
- frozen `env.*` only, no WASI, no wasm exception handling
- call depth `max_frames = 32`

Bounded subset under test: eval a few-byte script (`1+2*3`), console
round-trip, no timers, no DOM, no network. No engine written from scratch.
Harness: `tests/js-wasm-measure/` (not a fleet gate). Inspector:
`tests/wasm-spike/wasm-inspect.py`.

### Observed compiles

| Engine | Ref | License | What was observed |
|---|---|---|---|
| Elk | `cesanta/elk` `71a86fa` | AGPL | `zig cc -target wasm32-freestanding -nostdlib -Os`: **22763 B** module, `env.write`+`env.exit` only, memory min=2 / max=32. Inspector **PASS**. |
| MicroQuickJS | `bellard/mquickjs` `203d5bb` | MIT | Native `gcc -Os` `mquickjs.o` **666384 B**. `wasm32-wasi` compile refused (`setjmp.h` requires wasm EH). |
| Duktape | 2.7.0 tarball | MIT | Native `cc -Os` `duktape.o` **428992 B**. `wasm32-wasi` refused on the same wasm-EH `setjmp`. |
| MuJS | `ccxvii/mujs` `8a32c39` | ISC | Native `cc -Os` amalgam `.o` **359184 B**. `wasm32-wasi` refused on wasm-EH `setjmp`. GitHub clone is README-only (migrated to Codeberg). |
| QuickJS | `bellard/quickjs` `04be246` | MIT | `quickjs.c` is 2033048 B of C; freestanding compile dies on libc headers (`inttypes.h` `include_next`). |
| mjs | `cesanta/mjs` `cf375c4` | GPL-2 | `#error CS_PLATFORM` / POSIX headers; not freestanding. |
| TinyJS | `gfwilliams/tiny-js` `8214477` | MIT | C++ (`std::string`/`vector`) plus exceptions; `-fno-exceptions` does not compile. |

Elk is the only engine that produced a contract-clean module under the three
byte caps.

### Observed guest run (Elk)

`VGATE_NO_BUILD=1 bash tools/gate/vgate.sh tests/js-wasm-measure/run-under-wasm.spec`
**PASS 1/1** on VZ, asserting the trap (not a successful eval):

- VF-FILE read of `ELK.WASM` size=22763, full read
- no `wasm: module too large` / parse / validate / instantiate trap
- serial: `wasm: trap during exec kind=stack_overflow module=ELK.WASM offset=0x1980`
- `tasks user-exec exited status=3` (the interpreter's trap-during-exec exit)

At measurement time the guest did not print a trap class, so **inferred:**
Elk's recursive C eval exceeds `max_frames = 32`. Inspect-clean is not
execute-clean.

### A1 — M70d #1518, same day: the class, observed

The exec-trap path now prints `kind=`, `module=`, and the module byte offset
(card #1518; spec `tools/gate/specs/live-wasm-trap.spec`). The inference is
**corrected, not confirmed**: the class is `stack_overflow`, not `call_depth`.
Re-running the same pinned module through the interpreter's host capture seam
(`-OReleaseFast`) records the state at the trap: `frame_len=16`
(`max_frames = 32` never reached), `ctl_len=64` (`max_ctl = 64` full), `sp=3`
(the operand stack is nearly empty). The binding cap is the **control stack**;
offset `0x1980` is a `block` opcode. Whether `max_frames` would also bind
after any `max_ctl` raise is unmeasured — do not carry the old
`max_frames = 32` cause forward as fact.

### Control: 64 KiB C stack (not a frozen cap)

The original link line used `-Wl,-z,stack-size=8192`. That is a wasm-ld
layout flag inside the 2 MiB linear-memory allowance, not an interpreter
cap, so stack exhaustion was an unfalsified alternative to `max_frames`.

Same compile 2026-09-19 with `-Wl,-z,stack-size=65536`:

- module still **22763 B**, inspector PASS, `env.write`+`env.exit`, memory 2/32
- binaries differ: global 0 `i32.const` **8192** vs **65536** (`__stack_pointer`)
- `VGATE_NO_BUILD=1 bash tools/gate/vgate.sh tests/js-wasm-measure/run-stack64k.spec`
  **PASS 1/1** on VZ, asserting the same named trap:
  `wasm: trap during exec kind=stack_overflow module=ELK.WASM offset=0x1980` /
  `tasks user-exec exited status=3` (A1)

The 8 KiB C stack is **falsified** as the cause. The remaining inference was
`max_frames = 32`; A1 observed the control-stack cap instead (`ctl_len = 64`
with 16 live frames), so `max_frames` is not the cap that fired for this
module either. A 64 KiB stack would have been a free fix; it is not.

### What this does not change

- The renderer is unchanged. No cascade. No renderer-side JS.
- No additive `env.*` names. Elk needed only `write` and `exit`, already frozen.
- No `live-browser-js.spec` in the fleet: that spec is for a module that runs.
  The measurement spec lives next to the harness and is not discovered by
  `fleet.sh`.
- Elk is AGPL; this tree is proprietary (`LICENSE`). It is not vendored. Even
  a future ADR that deepens `max_frames` would still have to pick an engine
  this license can carry.

Raising `max_module_size`, `max_frames`, or adding wasm EH/WASI to admit
MicroQuickJS/Duktape/MuJS is a new interpreter ADR. This card does not do it.

## Amendment B — M69d #1531: Inter Bold (and Italic) are real faces

Date: 2026-09-20. Card: #1531. Host: Inter 4.1 extras TTF (`rsms/inter` v4.1),
SIL OFL 1.1 (`image/fonts/OFL-Inter.txt`). Regular already in-tree at
`image/fonts/Inter-Regular.ttf` byte-matches `extras/ttf/Inter-Regular.ttf`
(411,640 bytes).

### Observed files

| Face | Source (Inter-4.1 extras) | In-tree | Share name | Bytes |
|---|---|---|---|---|
| Regular | `extras/ttf/Inter-Regular.ttf` | `image/fonts/Inter-Regular.ttf` | `/host/INTER.TTF` | 411,640 |
| Bold | `extras/ttf/Inter-Bold.ttf` | `image/fonts/Inter-Bold.ttf` | `/host/INTERB.TTF` | 420,428 |
| Italic | `extras/ttf/Inter-Italic.ttf` | `image/fonts/Inter-Italic.ttf` | `/host/INTERI.TTF` | 417,388 |
| Mono | Fira Code, SIL OFL 1.1 (`image/fonts/OFL-FiraCode.txt`) | `image/fonts/FiraCode-Regular.ttf` | `/host/FIRACODE.TTF` | 289,624 |

Italic **was** in the same extras tree Regular already used, so D2 of the card
requires it. No other family's italic was fetched. Fira Code Bold was not
vendored.

Inter keeps glyph **advances** matched across Regular and Bold (observed:
`Measure("MMMMMMMM")` is 96px for both at body size). The discriminator is
stem coverage / ink, not width: Regular M×8 paints 440 ink px, Bold 592, a
Regular+1px strike 664. `Fonts.BoldHeavier()` and `live-web-ttf` boot 02 pin
that.

### The Zig consumer (M69d2, #1536)

Same share names, same shape — `ui.init_fonts` loads four faces through one
helper (`loadFace`) and every face gets its own `GlyphCache`, because the cache
keys an entry by **codepoint alone** (`font_ttf.zig: ascii_entries`); two faces
sharing one cache would paint whichever was rendered first. `DOC.BIN` paints a
bold run with Inter Bold and an `<em>` run with Inter Italic (the accent colour
stays, and Bold still wins where both apply — there is no Bold-Italic face, the
same rule Go WEB uses). The 1-px second strike survives only as the fallback for
a missing Bold face, which is what `typography: Inter Italic absent, em keeps
accent` reports for Italic.

Measured in-guest by that app's own probe (`typography: ink`, painted pixels at
the painter's 96/255 coverage cut; `diff` = pixels where the Bold mask disagrees
with the strike that doubles Regular), `live-doc` runs 01 vs 04. (Both that app
and those runs are gone as of M71i #1568 — the table below is kept as the
record of the Zig tree, and the Go tree's own numbers are in the section above
it.)

| size | Regular | Bold (real) | 1-px strike | Bold vs strike (`diff`) |
|---|---|---|---|---|
| 14 px (body) | 21 | 38 | 36 | 2 |
| 24 px (heading) | 64 | 111 | 89 | 26 |
| 14 px, `INTERB.TTF` removed | 21 | 36 (=strike) | 36 | 0 |

Two things this records that the Go row's numbers do not say:

- The metric differs: Go's row counts ink on a RENDERED surface at body size
  (440/592/664 for `M`×8), while the Zig probe counts mask pixels at the
  painter's own cut. At the same nominal body size, Zig measures the real Bold
  face as **heavier** than the strike (38 vs 36), the opposite relation to the
  Go row — which is why `live-doc` asserts `bold > regular` at body size and
  `bold > strike` at 24 px, rather than the one direction that happened to hold
  on the other tree.
- At 14 px the real face and the synthetic strike are within **2 px** of each
  other, so the old behaviour was nearly invisible at body size and only became
  a design question at heading sizes. Card D2 (a missing Bold face is a failed
  card, not a silent fallback) is what keeps the difference honest.

### What this does not change

- No font system, no variable axes, no user-installable faces, no new syscall
  (card D3).
- No cache redesign: `GlyphCache` still keys by codepoint alone, so one cache
  still serves one size. DOC's probe therefore rasterizes each measured size
  into a local cache rather than reading the size through the app's own.
- `<em>` keeps the accent colour; the Italic face supplies the slant.
- Bitmap 8×8 fallback still synthesizes bold with a 1-px strike, because that
  face has no Bold counterpart. The TrueType path does not.

## Amendment C — M71i #1568: one renderer (DOC.BIN retires into WEB.ELF)

**Decision.** The in-guest HTML consumer is `WEB.ELF`. Zig `DOC.BIN`,
`user/src/doc.zig`, `user/src/lib/html/`, the `DOC.BIN` build step, its
`image/apps.txt` row and its three specs (`live-doc`, `live-doc-tables`,
`live-doc-web`) are deleted. D2 (no JS, no cascade) stands unchanged; D1 and D3
are amended above for the consumer's language, not for the design.

**Why this is not a capability loss.** The Go path already pinned every rung of
D7's ladder, and the retired specs' probes moved onto it rather than
vanishing. The map is the record — each row names the surviving probe:

| Rung | Survivor |
|---|---|
| S1 local page + pixels | `live-web` boot 01; `live-web-ttf` boot 01 |
| S1 typography / faces | `live-web-ttf` 01 (real faces) vs 03 (grid fallback) |
| S1 missing / malformed page | `live-web` boots 04/06/07 (missing, dns, url) |
| S2 tables + header rule | `live-web-ttf` boot 02 |
| S2 `dl`/`dt`/`dd` | `live-web-ttf` boot 04 (vacant at HEAD; moved here) |
| S3 `<img>` decode | `live-web-ttf` boot 02 (SWATCH quadrant colours) |
| S3 missing-`src` placeholder | `live-web-ttf` boot 04 (vacant at HEAD; moved here) |
| S4 click-nav | `live-web` boot 02 |
| S5 `WEB.ELF <url>` | `live-web` boot 03 |
| S6 oliver-publish page | `live-web` boot 01 + `go-dogfood` boot 02 |
| M70d #1456 corpus page | `live-web` boot 14 (vacant at HEAD; moved here) |

The two "vacant at HEAD" rows are the honest ones: `dl/dt/dd` and the
in-guest corpus page were pinned by the retired specs ALONE, so they were
re-pinned on WEB rather than noted as covered. The corpus additionally keeps
its host-side golden suites (`user/go/webrender/golden_test.go`, nine pages).

**Evidence.** `live-web` 14/14 and `live-web-ttf` 4/4 on VZ after the deletion,
with `DOC.BIN` absent from the image and the manifest; `zig build` and
`zig build test` green with the `lib/html` registration removed.

**Consequences accepted.** The Zig host suites for parse/layout (21 tests) are
deleted, not ported — the Go suites are the surviving assertion of the same
modules. A future Zig HTML consumer would need a new ADR: this one now says the
EL0 renderer is the Go one.

## Amendment D — M93a #1993: declared CSS subset and frozen contract

- Status: **PROPOSED, awaits Timothy's owner review; not approved.**
- Date: 2026-10-05. Index: #1992. Contract version: **1**.
- Approval record: none. The landing PR and #1993 must carry the owner's
  verbatim verdict before this amendment counts as landed. Merge is not
  delegated to the agent. M93c/d start only after that approved merge.

**Evidence labels apply to every claim below:** **Observed** means inspected
source or an actual command result. **Inferred (decision)** means a proposed,
normative policy, including every number, mapping, API and expected rectangle.
Neither the numerical ceilings nor the mock establish implementation
performance, live-site compatibility, or host/guest pixel determinism.
Sections 1–10 are **Inferred (decision)** unless explicitly marked Observed.

**Observed baseline:** `origin/main` `0a222095`, fetched 2026-10-05; #1993 and
#1992 have no dependencies/approval comments. `ParseHTML` keeps pointer-linked
nodes, capped at 20,000/depth 256; `LayoutDocument` emits at most 24,000 paint
items. `style.go` still declares UA-only styling. `wnd_core.zig` limits a raw
back-buffer to 512×424; WEB opens 512×384. `tabapp` already provides
declare-fullscreen, resize and nav RPCs. Thus a 1280×720 **CSS layout** is not
a claim that a raw guest window accepts 1280×720 pixels. `process.zig` provides
4,096 **inline ownership records**, with allocator-backed overflow, and a hard
16 mmap-region limit. Contrary to the card's survey shorthand, 4,096 is not
a hard working-set cap. The independent 3,072-page WEB ceiling below is
unchanged and stays below even that inline capacity. No kernel, seat or syscall change is
part of M93. PNG's guest stub refuses it; gitread's zlib inflater is private.
`tls/trust.go` trusts only AutoClaw's fixture CA with capacity 64.

### 1. Decision sheet for sitting 1

| Owner decision | Proposed choice | Acceptance owner |
|---|---|---|
| D2 CSS reversal | Closed CSS 2.1-derived subset plus explicitly listed Flexbox Level 1 properties; UA < author, inline style, `!important`; unsupported constructs diagnose and do not apply | M93c #1995 |
| Scripting | **No JavaScript.** No interpreter, event-attribute execution, DOM scripting, plugins or embedded frame browsing; Amendment A remains unchanged | M93b #1994 / M93f #1998 |
| Pipeline | Frozen `webstyle` leaf; CSS depends on DOM, layout never depends on CSS; bounded parse → cascade → box tree → layout → paint | M93c/d/e |
| Viewport | Fixed 1280×720 CSS px, full-viewport eligible tab, uniformly downscaled/letterboxed when necessary, CSS-px vertical scrolling | M93f #1998 |
| Trust | 16 explicitly named Mozilla/NSS server-auth roots; capacity remains 64; fixture CA only in separately tagged gate binaries, never in shipped binaries | M93f #1998 |
| Images | Owned bounded PNG, existing QOI, ADR 0041 SVG; JPEG remains an alt-text placeholder | M93e #1997 |
| Comparison | Exact RGB SHA-256 at native and declared presentation sizes; zero tolerance, no browser engine oracle | M93e/g |

**Observed staging:** the reference files are original project-authored
stand-ins with `SOURCES.txt`, not downloaded site snapshots. The one-page
sheet is this section, the licensing table is §8, and the pre-CSS mock is
`artifacts/m93a/wikipedia-ua-mock.png`. That mock uses the **existing UA
renderer**: it is a discussion aid, not proposed CSS pixels or an acceptance
golden. M93e later supplies actual CSS renders for sitting 2.

### 2. Closed subset and deterministic outcomes

Every property/selector not explicitly admitted below is **ignored with a
diagnostic**, including unknown names. No inferred layout from an excluded
construct. CSS identifiers are ASCII case-insensitive for property/type names,
case-sensitive for class/id names; strings preserve case. CSS escapes follow
§4 tokenization. Invalid UTF-8, malformed declarations, bad values or exceeded
token limits diagnose without panics. Recover declarations at the next
unquoted, unnested `;`/`}`, rules at the matching `}`, and unknown at-rules
through their `;` or balanced block. Unsupported rules do not fetch resources.
An invalid declaration is omitted, leaving the previous valid cascade winner,
then inheritance/initial value if there is none, not erasing a lower rule.

| Construct | Status and precise outcome | Tests / fixture |
|---|---|---|
| Type, `*`, `.class`, `#id`; compound `tag.class#id`, repeated classes | **Supported**; universal adds zero specificity; ASCII HTML type matching | M93c / `selectors` |
| Whitespace descendant combinator; comma grouping | **Supported**; specificity tuple `(inline,id,class,type)` lexicographic; group members separate | M93c / `selectors` |
| `>`, `+`, `~`, attribute selectors, namespace selectors | **Ignored with `unsupported-selector`**; drop the entire rule, including all grouped members, never reinterpret as descendants | M93c / `degradation` |
| All pseudo-classes/elements (`:hover`, `:root`, `::before`, etc.) | **Ignored with `unsupported-selector`**; drop the entire grouped rule, no generated content | M93c / `degradation` |
| UA < author; specificity; source order; inline `style` | **Supported**; linked and embedded sheets in DOM order regardless of fetch completion; declarations in source order; inline parsed as declarations, not selectors | M93c/f / `selectors` |
| `!important` | **Supported** for UA and author; low→high: UA normal, author normal, author important, UA important; inline outranks selector specificity only within its author importance tier | M93c / `selectors` |
| `inherit`, `initial` on every admitted longhand | **Supported**; `inherit` takes the parent's computed value even on non-inherited properties; root uses initial; shorthand expands first | M93c / `selectors`, `box-model` |
| Automatic inheritance | **Supported** only for color, font family/size/weight/style, line-height, text-align, white-space; all other properties use initials, not the parent's boxes | M93c / `selectors`, `fonts` |
| `display:block`, `inline`, `none`, `flex`, `list-item` | **Supported**; none prunes subtree and hit regions; inline dimensions ignored per inline formatting; list-item retains UA decimal/disc markers | M93c/d / `display-tables`, `flex` |
| `display:table`, `table-row-group`, `table-header-group`, `table-footer-group`, `table-row`, `table-cell`, `table-caption` | **Supported bounded legacy table mode**, not general CSS table layout; equal columns, document-order groups, caption above, no spans, separate borders with zero spacing; column count from first row as today | M93c/d / `display-tables` |
| Other display values, `table-column*`, `inline-block`, `inline-flex` | **Ignored with `unsupported-value`**, retain the lower/UA display | M93c / `display-tables` negative cases |
| `width`, `height`, `min-width/height`, `max-width/height` | **Supported** content-box integer px, width percent, auto width/height; `none` on max maps to auto/unbounded. Height percent, intrinsic keywords, viewport/font/physical units ignored with `unsupported-value`; min wins over contradictory max | M93c/d / `box-model`, `boxes-block` |
| `margin`, four physical longhands | **Supported** 1–4 px/%/auto values; negative px allowed, percent 0–100%; percentages use containing width, including vertical sides; horizontal auto shares available width, vertical auto is 0 | M93c/d / `box-model`, `boxes-collapse` |
| `padding`, four physical longhands | **Supported** 1–4 nonnegative px/% values, percent uses containing width; auto/negative rejected with `invalid-value` | M93c/d / `box-model` |
| `border`, `border-{top,right,bottom,left}`, `border-width/style/color`, all physical width/style/color longhands | **Supported** none/solid only, integer px width 0–32, thin/medium/thick = 1/3/5 px; 1–4 values on width/style/color; omission resets shorthand components to initials. Other styles invalidate the entire declaration (`unsupported-value`), never become solid | M93c/e / `borders` |
| Font family | **Supported** comma lists; Inter/sans-serif/serif map to Inter, Fira Code/monospace map to Fira Code; unfamiliar names emit `font-family-fallback` and are skipped, use first known entry; with none, omit the declaration and inherit (Inter only at initial); no downloaded fonts | M93c/e / `fonts` |
| `font-size`, `font-weight`, `font-style` | **Supported** integral 8–48 px; normal/400 and bold/700 (100–500 map normal, 600–900 bold); normal/italic only. Relative sizes, bolder/lighter, oblique, `font` shorthand diagnose/ignore. Real Bold wins over Italic when both requested, as D4 | M93c/e / `fonts` |
| `line-height`, `white-space` | **Supported** normal or integral 1–128 px; normal = ceil(size×18/13). white-space normal/pre/pre-wrap; normal collapses ASCII spaces, pre preserves/no wrap, pre-wrap preserves/wraps. Other modes/unitless line-height diagnose/ignore | M93c/d/e / `fonts` |
| `color`, `background-color`, border colors | **Supported** `#RGB`, `#RRGGBB`, integer `rgb(r,g,b)` 0–255, transparent, currentColor, CSS 2.1's 16 named colors. No rgba/hsl/percent rgb. Foreground currentColor means inherited color; background/border currentColor uses final foreground | M93c/e / `colors`, `borders` |
| `text-align` | **Supported** left/center/right; justify/start/end diagnose/ignore | M93c/d / `fonts` |
| `flex-direction`, `flex-wrap` | **Supported** row/column; nowrap/wrap; reverse directions/wrap-reverse diagnose/ignore, retaining initial/lower values | M93c/d / `boxes-flex`, `flex` |
| `justify-content`, `align-items` | **Supported** flex-start/flex-end/center/space-between/space-around/space-evenly; align-items stretch/flex-start/flex-end/center. Baseline/safe/unsafe/align-self/align-content diagnose/ignore; wrapped lines pack at cross-start | M93c/d / `flex` |
| `flex-grow`, `flex-shrink`, `flex-basis`, `gap`, `row-gap`, `column-gap` | **Supported** integer grow/shrink 0–16, basis auto/nonnegative px/0–100% of definite main size; gap 1–2 nonnegative integer px. Flex shorthand/order/percent gaps diagnose/ignore; DOM order stays fixed | M93c/d / `boxes-flex`, `flex` |
| Floats, clear, positioning/insets/z-index | **Ignored with `unsupported-property`**; normal-flow boxes stack (the article infobox does not float), no overlay | M93c/d / `degradation`, `wikipedia` |
| Grid, transforms, animation/transition, opacity, background images, overflow, visibility, border radius/collapse/spacing, list-style, content | **Ignored with `unsupported-property`**; normal boxes, solid backgrounds, UA markers, legacy table rules; no invisible-content shortcut | M93c/d/e / `degradation` |
| `@import`, `@font-face`, `@supports`, keyframes, every other at-rule | **Ignored with `unsupported-at-rule`**; skip whole construct, no imports/fonts/animation | M93c / `degradation` |
| Every `@media`, including `@media screen` | **Ignored with `unsupported-at-rule`**; skip block, no pass-through. A fixed viewport is not permission to guess responsive breakpoints | M93c / `degradation` |
| CSS custom properties/var/calc/functions beyond admitted rgb | **Ignored with `unsupported-property/value`**, no substitution | M93c / `degradation` |

All lengths accept unitless **zero only**, in addition to admitted units.
Nonzero px lengths are integers; magnitude ≤32,768 before narrower property
bounds. Negative dimensions/padding/borders/gaps are invalid. No clamping bad
declarations into acceptance. CSS numbers outside these subsets diagnose.
Margins may be negative; accumulated used coordinates/document height have
magnitude ≤1,048,576 px; beyond that is `layout-coordinate-limit`.

Block width resolution follows CSS 2.1 §10.3.3 (LTR); auto width fills the
remaining content width, overconstrained specified widths resolve the right
margin. Vertical margins collapse per §8.3.1: largest positive plus most
negative, including parent/first and parent/last child and empty blocks;
root, border/padding, inline content and flex boundaries prevent the relevant
collapse. Flex items never collapse margins. Flex sizing follows Level 1 §9
with auto basis from width/height or measured intrinsic content, zero automatic
minimum for flex items, and declared min/max constraints. This zero-auto-min
is a named subset simplification, not a claim to full Flexbox conformance.
Unsupported `align-content` uses cross-start rather than full-spec stretch.
Use rational intermediate space distribution, floor final nonnegative sizes,
then distribute residual pixels to unfrozen eligible items in DOM order;
positions derive from those sizes. Negative free space shrinks by
`shrink × base-size`, iterating freezes at min/max. Integer rectangles and
tie-breaking are part of the contract, not host floating-point accidents.

**HTML hardening list, M93b:** case-insensitive raw end tags for script/style,
RCDATA for textarea/title; implied head/body; close p before every admitted
block start; table section/row/cell closes on next section/row/cell or table
end; insert tbody for direct tr and tr for direct td/th; close option before
option/optgroup and optgroup before optgroup/select end. No full foster-parenting
algorithm: text stays in document order. `noscript` renders. script/style/head
metadata never paints. frame/frameset/iframe/object/embed/applet flatten to
fallback text (D5), never load or execute; event attributes are inert. Unknown
elements preserve text, not arbitrary replaced content. M93b tests each rule;
M93f extracts style/link metadata before layout skips it.

### 3. Frozen Go contract and acyclic APIs

`user/go/webstyle/style.go` is normative version 1: exported types/constants,
no imports, functions, globals, parser or renderer. `style_test.go` pins every
zero field, explicit-zero distinctions, no production imports/functions and
the reference inventory. **After the approved merge, any change is a
stop-and-ask on #1993 for every M93 lane.** Consumers do not add parallel
enums or work around a missing field.

`LengthInitial=0`, auto, px and percent are distinct. Percent Value=25 is 25%,
not a fractional pixel. Initial widths/heights/basis are auto; min dimensions
are 0 and max dimensions unbounded; margin/padding/gaps are 0; font size 13px;
normal line-height ceil(size×18/13); border width 3px but none means no used
border. Explicit margin auto remains distinguishable from the initial zero
margin. ColorInitial resolves to black foreground, transparent background,
current foreground border; ColorRGBA is straight `0xAARRGGBB`, including zero
transparent, and ColorCurrent is distinct. Enum initials are inline, Inter,
normal weight/style, left, normal whitespace, row, nowrap, start justification
and stretch alignment. `FlexFactor{Set:false}` means grow 0/shrink 1;
`Set:true,Value:0` means explicit zero even for shrink.

Cascade returns inherited/resolved font and color values, not an
inherit/unset token; only initial/auto/percent used-length resolution remains
for layout. It does not mutate the DOM. Diagnostics have the frozen fields
`Kind, Line, Col, Text`; kinds unsupported/invalid/limit/resource, source
locations 1-based byte columns, synthetic positions 0/0. Text begins with the
named outcome from §2/§5–7 and names the offending construct, capped at
160 UTF-8 bytes. Retain at most 127 ordinary diagnostics plus one final
`diagnostics-truncated` limit notice. Aggregate the same 128 cap per page,
not 128 per sheet/node. Every unsupported occurrence diagnoses until that
visible summary limit; the UI exposes a diagnostic count and bounded list.

The following signatures are normative declarations **for downstream
implementation**, not functions implemented by R1:

```go
// package css (M93c); Stylesheet and Styles are css-owned, opaque to layout.
func Parse(src []byte) (*Stylesheet, []webstyle.Diagnostic)
func Cascade(doc *webrender.Document, sheets []*Stylesheet) (*Styles, []webstyle.Diagnostic)
func (s *Styles) ForNode(n *webrender.Node) webstyle.ComputedStyle
// sheets are ordered author sheets. Cascade inserts its compiled UA sheet
// and parses the DOM's style attributes; ForNode works for text and elements.

// package webrender (M93d); BoxTree and its rectangles are webrender-owned.
func BuildBoxTree(doc *Document, style func(*Node) webstyle.ComputedStyle) (*BoxTree, []webstyle.Diagnostic)
func LayoutBoxes(tree *BoxTree, viewport webstyle.Viewport, t TextEngine, images ...ImageResolver) (*Layout, []webstyle.Diagnostic)
// M93f: css.Cascade -> BuildBoxTree(doc, styles.ForNode) -> LayoutBoxes.
```

Nil documents/callbacks or invalid viewport produce `invalid-input`, not a
panic. Partial parse/tree/layout on a limit carries a terminal limit diagnostic
and visible truncation; no successful-looking silent partial result.
BoxTree owns anonymous boxes and style copies, counts them toward MaxBoxes,
and exposes content/padding/border/margin rectangles for M93d's exact tests.
Layout retains its BoxTree alongside the flat items so M93e can paint borders.
Existing `Paint`, `Surface.Fill` and `LayoutDocument` callers keep compiling.
M93d alone owns compatibility UA styles and the legacy-width adapter:
`LayoutDocument` preserves its requested width and 512×384 goldens/gates until
M93f switches to the fixed viewport. It must not import css to obtain UA data.
The css UA sheet and compatibility styles derive from today's same tag table;
M93f's handoff replaces compatibility styles, not a second concurrent cascade.
M93e may add an **optional** MaskSink capability and sized text; Fill-only
surfaces still paint, and the 13px Inter metric markers retain their values.
To let d/e work without editing each other's files, M93d adds `FontPx int`
and `LineHeightPx int` to its owned `Style` and `Item` types: positive values
are used CSS px, zero selects the existing logical-size compatibility path.
M93e honors them in text/paint; M93d's injected measurement tests honor them
before M93e lands. CSS style copies remain in BoxTree, so borders/transparent
foregrounds do not rely on legacy uint32 zero meaning "default color".

Import graph: css → webrender → webstyle; css → webstyle;
browser → css + webrender + webstyle. webrender **never** imports css or browser.
No shared globals, CSS pointers in boxes, kernel HTML/CSS, or new dependency.

### 4. CSS viewport, seat presentation and scrolling

The new pipeline always lays out at **1280×720 CSS px**. Vertical document
content can extend below 720; scroll `s` is integral CSS px in
`[0,max(0,documentHeight-720)]`. Wheel/arrow step is 40px; PageUp/PageDown
680px; Home/End reach limits. Anchor navigation scrolls to the clamped target.
Horizontal overflow clips to the 1280px viewport, with `horizontal-clipped`
when present (pre retains its established clipping behavior).

M93f adopts existing tabapp fullscreen declaration, retaining the raw
**512×384** shim fallback. It uses the actual resized canvas from events, not
the host scanout dimensions. Reserve existing 16px window title, then a 32px
browser URL/nav band and a 16px status band: available document area is
`AW = client width`, `AH = frame height-64`. Let
`PW=min(1280,AW,floor(AH*1280/720))` and
`PH=floor(PW*720/1280)`; center that rectangle with floor-rounded offsets.
This uniformly scales down, never up, and letterboxes unused space.
If PW/PH are zero, show `viewport-too-small` without division.

Paint a bounded native **1280×720** frame at CSS scroll s, then sample the
frame to PW×PH using nearest-neighbor pixel centers:
`sx=floor((2*u+1)*1280/(2*PW))`,
`sy=floor((2*v+1)*720/(2*PH))`. Keep exactly one native frame
(3,686,400 bytes); no whole-document pixel buffer. Decode/rasterize images
within their separate caps. Pointer inverse mapping uses the same center
formula, adds s to CSS y, and ignores letterbox clicks. Thus links/forms share
layout coordinates rather than independently rounding hit regions.

Example raw fallback: frame 512×384 → AW=512, AH=320 → **512×288** content,
centered horizontally and 16px below the URL band. This is a mapping decision,
not an observed VZ result. Fullscreen tab eligibility does not imply the kernel
allocates a larger raw back-buffer; the mapping handles either returned canvas.

M93f retargets `tools/gate/specs/live-web.spec`'s origin/crop at baseline
line 251 and all click/pixel coordinates, plus `live-web-ttf.spec`'s pinned
geometry. Preserve existing color-count/tolerance thresholds: retarget probe
regions in declared coordinates; do not weaken thresholds to absorb scaling.
A threshold that cannot remain satisfied is a stop-and-ask, not a free change.
Geometry/scroll markers include CSS size, scanout content X/Y/PW/PH and s.
M93g reads those markers and checks bounds before cropping (§9).
Font probe measurements are native CSS metrics, never downscaled glyph counts.

### 5. Numeric budgets and overflow

All ceilings below are **Inferred (decision), not measured results**.
Retain draft page/rule/box/time/demand ceilings; add token/work/resource bounds
so those large caps are not promises to allocate every maximum simultaneously.
Only small references are committed. Maximum demand use includes Go runtime,
fonts, native frame, mappings, parser/style/box/item storage and decoded images.

| Budget | Ceiling | Enforcement / acceptance |
|---|---:|---|
| HTML source | 1,048,576 bytes/page | M93b/f: truncate prefix visibly, `html-byte-limit`, parser Truncated |
| DOM nodes / depth / attributes per node / attribute bytes | 20,000 / 256 / 64 / 4,096 | M93b: existing caps, terminal visible notice |
| Author stylesheets / combined author CSS including inline attrs | 8 / 262,144 bytes | M93c/f: stop at source boundary, `css-sheet-limit` / `css-byte-limit`; no half declaration applied |
| Author rules / selectors per rule / compound descendant parts | 4,096 / 16 / 16 | M93c: `css-rule-limit` / `css-selector-limit`, skip overflowing rule; UA separate, ≤128 rules |
| Declarations per rule / token bytes / nesting | 64 / 4,096 / 16 | M93c: bounded recovery, `css-declaration/token/nesting-limit` |
| Selector matching work | 8,000,000 compound-node comparisons/page | M93c: stop author matching, preserve completed styles, visible `css-work-limit`; no N×rules unbounded loop |
| Diagnostics / each text | 128 / 160 bytes | all lanes: shared final summary slot |
| Boxes including anonymous / depth / flat paint items | 20,000 / 256 / 24,000 | M93d: `box-limit` / `layout-depth-limit` / `paint-item-limit` |
| Used document coordinate/height magnitude | 1,048,576 px | M93d: checked arithmetic, `layout-coordinate-limit` |
| Reference file, every type | 16,384 bytes | M93a test; each file listed in SOURCES |
| Committed PNG golden / full uncommitted PNG | 65,536 / 4,194,304 bytes | M93e: larger PNG stays artifacts; small hashes still commit |
| Native frame | 1 × 1280×720×4 = 3,686,400 bytes | M93f: reusable viewport only |
| Images / source bytes per image / aggregate decoded pixels bytes | 16 / 262,144 / 2,097,152 | M93e/f: sequential resource resolver; overflows placeholders |
| Image dimension / total pixels / decoded bytes per image | 1,024 / 262,144 / 1,048,576 | M93e: validate before multiplication/allocation |
| PNG inflated scanlines | 1,049,600 bytes/image | M93e: width×4+filter-byte, bounded inflate and checked output size |
| Layout + paint of each reference on the reference host | 500 ms, cold first render, excludes file/net/font load | M93d/e/f: largest page benchmark and guest markers, each phase sum ≤500 |
| Peak WEB demand pages / mmap regions | 3,072 (=12,582,912 bytes) / 12 | M93f: sampled peak on largest reference, includes runtime; below 4,096 inline records / 16 region slots; no kernel changes |
| Page load deadline / concurrent external resource fetches | 30 s / 1 | M93f: total budget, cancellation between bounded reads |

Budget exhaustion is a visible terminal notice/placeholder plus diagnostic,
never panic, hang or silent text disappearance (D5/D6). Parser/layout buffers
are capacity-bounded, reused on navigation; no unbounded append cache.
Preflight allocation arithmetic against a per-page ledger and retain headroom
for the runtime. Caps on node/rule count do not authorize a reservation whose
combined demand exceeds the page ceiling. Measure the largest reference, not
sum of hypothetical full arrays. If a required reference exceeds a ceiling,
report and ask; do not raise it here or stub successful timing/memory receipts.

### 6. Image policy

**PNG:** owned in-tree decoder in webrender; reuse the private
`user/go/git/gitread/flate.go` by an attributed **copy** of its bounded
zlib/DEFLATE implementation into `webrender/png_inflate.go`. Do not export or
edit gitread, import its object reader, or duplicate PDF's engine-dependent
decoder. Origin is the project's own Zig→Go flate port under repository LICENSE;
M93e records the exact source revision in the copy's header. No new dependency.
Support non-interlaced PNG color types 0/2/3/4/6 at **8 bits only**, all five
row filters, PLTE and tRNS where PNG permits them, CRC/Adler validation.
Adam7, other bit depths/APNG/acTL are `image-unsupported` placeholders.
Unknown ancillary chunks validate CRC then skip; unknown critical chunks refuse.
Bound compressed input, chunk count 256, scanline output and dimensions before
allocation. Require one complete zlib stream; no trailing compressed stream.
Pixels match std image/png after conversion to straight 8-bit RGBA; no
gamma/profile color correction. Host stdlib is a BSD-3-Clause test reference,
not guest decoder. M93e supplies its small owned PNG/malformed corpus.

**QOI:** keep the existing decoder and alpha behavior within §5 caps.
**SVG img:** call `virelai/svg` and `virelai/vector` without altering ADR 0041's
subset/caps. Source bytes use the smaller of SVG's existing cap and §5;
decoded raster uses §5 pixel caps. Every SVG refusal, including text/stroke/
resources/style, maps to `image-svg-<original-kind>` and the same alt box,
not an approximate partial image. No inline SVG DOM or SVG stylesheet bridge.
**JPEG, GIF, WebP and all other formats:** `image-unsupported`; no decoder.
Missing/bad/over-budget image: `image-missing/invalid/limit` respectively.

Placeholder: outlined 1px gray content box, specified legal dimensions if
present, otherwise **160×48 CSS px**, clipped to the viewport; original alt
text, at most 256 UTF-8 bytes, or `[image unavailable]`, drawn/wrapped inside
4px padding. Preserve a wrapping link's hit region. Errors identify format/
reason in diagnostics; no invisible blank, network retry or executable asset.
M93e tests all image paths and supplies a real guest PNG pixel probe.

### 7. Network, trust and GET policy (M93f)

Hostnames use `vi.ResolveDNS` (IPv4 only); SNI is the normalized DNS hostname,
never fixed `leaf.example.com`. IP literals omit SNI but retain SAN IP checks;
all HTTPS chains validate hostname, signature, expiry and trust as today.
No TOFU, clock bypass, certificate error override or HTTP downgrade.

Choose **HTTP/1.0 plus Host and Connection: close**, not chunked/HTTP2.
Host includes a nondefault port; request path/query are origin-form.
Bound header section 16,384 bytes, each line 4,096 bytes, 128 header fields;
reject conflicting Content-Length, invalid length, Transfer-Encoding
(including chunked), unsupported Content-Encoding (no gzip) and premature EOF.
Identity body uses exact Content-Length or EOF framing, bounded by the
resource's source cap. Requests advertise `Accept-Encoding: identity`.
A peer insisting on chunked/compression gets `http-framing-unsupported`,
not misparsed body content or an inferred successful live run.

Timeouts: DNS 5s, connect 5s, TLS handshake 10s, header 5s, each stalled body
read 5s, **30s total page including resources and redirects**; earlier overall
deadline wins. Maximum **5 redirect hops**, statuses 301/302/303/307/308 for
GET, reject missing/bad Location/loops with named `redirect-*` errors.
Resolve relative locations with existing URL normalization; no HTTPS→HTTP
redirect, cross-origin redirect allowed only after fresh DNS/SNI/validation.
At most **25 network requests** per page (1 initial + 8 sheets + 16 images),
including redirects; redirects consume this common count. Failed sheets
leave UA/other author styles with `css-resource`, failed images use alt boxes.
No @import resources, scripts, data/javascript/file URLs,
POST, authentication dialog, IPv6 or new network slot.
Cookies are a bounded subset (M97f F1+F2, #2105 — amends the earlier
"cookies expansion" exclusion, which the M53 store never conformed to):
host-only persistence — a `Domain` attribute must name the request host
exactly (one leading dot ignored) and is refused otherwise; `Path` scopes
the row, defaulting to `/`; every field is size-capped and must be
ledger-field-safe (no tab/CR/LF bytes) or the cookie is refused at the
parser; the ledger holds at most 512 rows with oldest-first eviction; sends
match the stored host exactly — no suffix matching, so a stored row can
never attach to a different origin, and a scope-blanked row is inert.
Local `/host` resources remain on existing normalized file-open semantics.

**Production trust source:** Mozilla NSS `lib/ckfw/builtins/certdata.txt`,
MPL-2.0, server-auth records only. **Observed license source:** that primary
file's header explicitly states MPL-2.0; Mozilla's CA Program governs inclusion:
<https://wiki.mozilla.org/CA>. M93f pins the fetched NSS revision, complete
source SHA-256, each extracted DER SHA-256, trust flags/distrust-after metadata,
generation procedure and MPL notice in `tls/ROOTS-SOURCES.txt`. No NSS executable
code is adopted. Do not include email/code-sign-only or server-auth-distrusted
anchors. Current distrust dates are enforced, not discarded during extraction.
The source read stays outside the repo; commit only reviewed generated DER
inputs/notices. A missing/withdrawn named anchor is a stop-and-ask, no substitute.

Freeze this **16-anchor allowlist**, capacity still **64**:
ISRG Root X1; ISRG Root X2; GTS Root R1; GTS Root R2; GTS Root R3; GTS Root R4;
DigiCert Global Root G2; DigiCert Global Root G3;
DigiCert TLS RSA4096 Root G5; DigiCert TLS ECC P384 Root G5;
Sectigo Public Server Authentication Root R46;
Sectigo Public Server Authentication Root E46;
Amazon Root CA 1; Amazon Root CA 2; Amazon Root CA 3; Amazon Root CA 4.
DER input total ≤65,536 bytes. This is a bounded web subset, **not** a claim
that these issuers cover every site or that the existing TLS algorithm subset
can validate every chain. Unsupported chain algorithms continue to fail closed.

**Fixture CA must not remain trusted in a shipped build.** Generated
`trust_root_gen.go` is selected by `!virelai_gate_roots`; separate
`trust_gate_gen.go` by `virelai_gate_roots`. Both expose the same private
root-list/version names to trust.go. The gate list contains **only** AutoClaw's
pinned root, not the production list; default contains **only** the 16 roots,
not AutoClaw. No runtime `/host` anchor injection, environment flag or test
hostname exception. M93f's build helpers produce separately named gate WEB/
GOFETCH/GOTGIT artifacts with the tag and stage them only in hermetic specs.
The normal build remains production. `go-fetch-https` and `go-git` must use
the corresponding gate artifacts too, not require that production trust
retain the test CA. Untagged tests pin test-root rejection; tagged tests pin
fixture acceptance; serial trust version reports which set is in use.
Host test-store injection remains explicit and cannot change defaultStore.

URL focus chord **Ctrl+L**, scoped to focused WEB, never registered as a global
seat action; click focuses too. Enter loads, Escape cancels URL editing.
URL/edit buffer ≤2,048 UTF-8 bytes; submitted GET URL ≤4,096 bytes.
GET controls: named enabled text/search/hidden inputs, selects (one selected
option, first option if none), checked checkboxes, activated submit button.
Missing checkbox value is `on`; exclude unnamed/disabled/unchecked controls.
No password/radio/file/multiple-select/textarea submission in v1: show
`form-control-unsupported`, do not pretend successful values. Form control
count ≤64 and each name/value ≤256 bytes. Preserve DOM order, standard
application/x-www-form-urlencoded bytes (space→+, other non-unreserved UTF-8
bytes percent-encoded). Replace the action's query per GET semantics; same
navigation/history rules as links. POST/other methods show `form-method-unsupported`.

Fixed class-C targets: `https://en.wikipedia.org/wiki/Harbor`,
`https://github.com/mattn/go-runewidth` (MIT repo; page chrome not adopted),
`https://developer.mozilla.org/en-US/docs/Web/CSS/display`.
Runtime fetching is not a license to commit page assets or engine code.
M93f records unsupported framing/chain/layout results honestly; a defined
degradation does not prove index acceptance that all three are navigable.

### 8. References, provenance and licensing

**Observed:** primary-source notices consulted, not code/assets downloaded:

| Input | Source / license evidence | Adoption |
|---|---|---|
| Every reference HTML and SOURCES file | Original project authorship, repository LICENSE v1.0; `tests/fixtures/web/reference/SOURCES.txt` inventory | Yes, all original, each ≤16,384 bytes |
| Existing in-tree inflate, QOI, svg/vector | Inspected source; repository LICENSE; upstream notices remain as already recorded | Reuse only, no new external decoder |
| Inter / Fira Code | Existing `image/fonts/OFL-Inter.txt` / `OFL-FiraCode.txt`, SIL OFL 1.1 (Amendment B) | Existing four font files only |
| Mozilla CA metadata/certificates | Primary certdata header MPL-2.0; <https://wiki.mozilla.org/CA>, <https://www.mozilla.org/MPL/2.0/> | M93f generated allowlist with exact source/DER hashes and notices |
| Go standard image/png | Existing Go distribution LICENSE, BSD-3-Clause | M93e host byte-equality reference only |
| CSS 2.1 / Flexbox text | <https://www.w3.org/TR/CSS21/box.html>, <https://www.w3.org/TR/CSS21/visudet.html>, <https://www.w3.org/TR/css-flexbox-1/#layout-algorithm> | Specification arithmetic only, no engine code or copied implementation |
| MediaWiki / skins | <https://www.mediawiki.org/wiki/Copyright>, <https://www.mediawiki.org/wiki/Category:GPL_licensed_skins>; GPL-2.0-or-later project / GPL skins | **Not adopted**, no skin CSS/JS/bytes |
| Wikipedia article text | <https://en.wikipedia.org/wiki/Wikipedia:Copyrights>; CC BY-SA 4.0 with site-specific terms | **Not adopted**, invented article text instead |
| MDN content | Primary MDN attribution page: <https://developer.mozilla.org/en-US/docs/MDN/Writing_guidelines/Attrib_copyright_license>; open content licenses | **Not adopted**, no reliance on a site's mixed content/code licensing |
| GitHub page chrome | No permissive notice established | **Not adopted**, entirely original repo stand-in |
| WebKit | <https://webkit.org/licensing-webkit/> explicitly identifies LGPL and BSD portions | **Not adopted**, never engine or oracle |

The no-GPL rule is not relaxed by public accessibility or using a test oracle.
No external skin/page screenshot, stylesheet, JS, logo or prose ships here.
The three stand-ins test structural roles: nav, flex header, file table,
sidebar, code and GET search; they do not promise to reproduce a real site's
appearance. Each feature page is identified in SOURCES; synthetic box headers
show exact arithmetic. M93b parses all 15 without Truncated; M93c tests
ignored-construct deletion equivalence; M93d tests the hand-derived rectangles.

### 9. Comparator policy (M93e/g)

Choose **exact SHA-256, zero tolerance**, following `go-r3d.spec`.
No host/guest nondeterminism has been established; none is presumed.
M93e renders each reference at native 1280×720, fixed scroll=0, fixed
Inter/Inter Bold/Inter Italic/Fira Code bytes, normal 13px body size, no clock/
caret animation in compared content. Hash **row-major RGB8 bytes** only
(3 bytes/pixel), not PNG container/compression bytes or BGRX's padding byte.
Record width/height/scroll and font SHA-256 alongside each hash. Font selection,
initial background and presentation sampling are identical on both paths.

M93e also generates the **512×288** raw-fallback presentation crop using §4's
exact integer sampling from the native render, with separate RGB hash and
owner-reviewed small PNG when ≤65,536 bytes. Both full native/presentation
PNGs go to artifacts. M93g fixes its reference boots to that presentation
size; geometry comes from WEB's marker and must match the manifest size,
not an arbitrary screenshot-dependent scale. Crop scanout, convert BGRX→RGB8,
compare the manifest SHA-256. Native host tests still compare the native hash;
the guest gate compares the matching presentation hash, never attempts to
reconstruct native pixels by enlarging a downscaled screenshot.

Wrong size/offset/hash or a single changed pixel fails. Write an actual PNG,
diff PNG and exact mismatched-pixel count to artifacts on mismatch. Golden
approval includes both native and presentation images; no re-blessing from a
guest capture. Comparator stdlib-only self-tests cover identity, one pixel,
wrong size and one-pixel crop shift. M93g runs **K=3** consecutive complete
live-web passes on main, no re-roll to conceal a mismatch.
Any later tolerance, different sampler/font bytes/crop, or changed threshold
requires owner review; never widen it to pass. **No browser engine as oracle.**

### 10. Final file split and acceptance handoff

These are the complete coordination-gate Touches lists for downstream claims.
Sequential dependencies explicitly serialize shared golden/spec paths.
Only M93b/c/d can be concurrently active; their lists are disjoint.
M93e follows d, f follows b/c/e, g follows f; no overlap is bypassed by
narrowing a live claim. Generated fleet inventory and docs/status are excluded.

| Lane | Depends | Final Touches (comma-separated coordination syntax) |
|---|---|---|
| M93b #1994 | code none; reference acceptance after a | `user/go/webrender/htmlparse.go, user/go/webrender/htmlparse_test.go, user/go/webrender/testdata/fuzz/FuzzHTML/*` |
| M93c #1995 | a approved merge | `user/go/css/*` |
| M93d #1996 | a approved merge | `user/go/webrender/layout.go, user/go/webrender/layout_test.go, user/go/webrender/style.go, user/go/webrender/box.go, user/go/webrender/box_test.go, user/go/webrender/golden_test.go, user/go/webrender/testdata/golden/*, user/go/webrender/testdata/boxes/*` |
| M93e #1997 | d merged | `user/go/webrender/paint.go, user/go/webrender/surface.go, user/go/webrender/text.go, user/go/webrender/text_test.go, user/go/webrender/image.go, user/go/webrender/image_png_guest.go, user/go/webrender/image_png_host.go, user/go/webrender/png.go, user/go/webrender/png_inflate.go, user/go/webrender/png_test.go, user/go/webrender/image_test.go, user/go/webrender/golden_test.go, user/go/webrender/testdata/golden/*, user/go/webrender/testdata/png/*, tools/gate/specs/live-web-ttf.spec` |
| M93f #1998 | b/c/e merged | `user/go/browser/*, user/go/tls/trust.go, user/go/tls/trust_root_gen.go, user/go/tls/trust_gate_gen.go, user/go/tls/trust_test.go, user/go/tls/ROOTS-SOURCES.txt, user/go/tls/LICENSE.MPL-2.0, tools/go/build-web.sh, tools/go/build-git.sh, tools/gate/specs/live-web.spec, tools/gate/specs/live-web-ttf.spec, tools/gate/specs/go-fetch-https.spec, tools/gate/specs/go-git.spec` |
| M93g #1999 | f merged | `tools/gate/specs/live-web.spec, tools/web-proof/*` |

M93a edits only its claimed ADR/scoping/types/reference files; the added
downstream paths above assign PNG corpus/inflate attribution and gate-only
trust-artifact staging to the lanes that implement them, not R1 product code.
Gate scripts with space-separated arguments require preserving the quoted
Touches string through just; comma-separated paths without spaces express
the identical scope if the recipe strips quoting.

R1 acceptance: contract negative before package creation, positive after;
host baseline webrender/browser plus live-web; full `go test ./...`,
coordination and `git diff --check`. No renderer implementation beyond types.
Every supported/ignored row has a testing lane in §2. Numerical budget
measurements, new CSS pixels, production-chain coverage and class-C navigation
belong to the named later cards, not inferred R1 successes.
**Owner approval remains outstanding at this PR.** No verdict is fabricated.

