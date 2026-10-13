package webrender

import "virelai/ttf"

// The renderer's text seam.
//
// Layout measures text and Paint draws it. If those two used different metrics
// the page would wrap to one width and paint at another, so they share ONE
// engine: Layout carries the engine it was laid out with, and Paint uses that.
//
// Two engines exist. Fonts wraps real TrueType faces (proportional advances,
// coverage anti-aliasing); Bitmap is the built-in 8x8 face scaled by integer
// factors. Bitmap is not a test double — it is the documented fallback: a
// missing, unreadable, or rejected font must cost typography, never the page.
// ADR 0028's consequence note says exactly this: "a silent fallback to the 8x8
// bitmap would change metrics", which is why the fallback is visible, logged by
// the app, and asserted by a gate rather than assumed.

// TextEngine measures and paints text for one renderer.
type TextEngine interface {
	// Measure is the pixel width of a run at the style's face and size.
	Measure(text string, st Style) int
	// Advance is the per-character cell width for the style (monospace layout
	// and tab stops).
	Advance(st Style) int
	// LineHeight is the height of one line box at the style's size.
	LineHeight(st Style) int
	// Paint draws text with the line box's TOP at (x, top) and returns the
	// advance consumed.
	Paint(s Surface, x, top int, text string, st Style, rgb uint32, c Clip) int
	// Proportional reports whether the engine has real per-glyph advances.
	Proportional() bool
	// Name describes the engine, for the app's serial markers.
	Name() string
}

// MaskSink is implemented by surfaces that can blend an 8-bit coverage mask —
// that is, surfaces that can show real anti-aliasing. A Surface that does not
// implement it still gets the text: the engine falls back to thresholded
// one-pixel-high spans, which is legible without being smooth.
type MaskSink interface {
	// BlitMask composites a glyph mask with its top-left corner at (x, y).
	// Implementations clip to their own bounds.
	BlitMask(x, y int, m *ttf.Mask, rgb uint32)
}

// TrueType pixel sizes per logical size unit. The bitmap face is 8px per unit;
// the TrueType faces are given a larger size for the same unit so body text
// matches the physical scale the Zig desktop's own TrueType rendering uses
// (Inter 14px, Fira Code 13px).
const (
	ttfBodyPx = 13
	ttfMonoPx = 12
	bitmapPx  = 8
)

// Fonts is the TrueType-backed engine. The zero value has no faces and behaves
// exactly like Bitmap, so a renderer that failed to load anything still paints.
//
// Bold and Italic are optional. When they are present, Style.Bold / Style.Italic
// select them; when they are absent, Bold falls back to a 1-px second strike
// and Italic falls back to the UI face (ADR 0028 D4, amended M69d #1531).
type Fonts struct {
	UI     *ttf.Face // Inter Regular (proportional)
	Mono   *ttf.Face // Fira Code (monospace)
	Bold   *ttf.Face // Inter Bold; optional
	Italic *ttf.Face // Inter Italic; optional

	// Reg, when set, is the manifest's registry (M99l): each rune resolves
	// through a chain — the style's primary, then the role's other faces in
	// order, then the symbol faces — so a rune the primary lacks paints the
	// covering face's glyph instead of .notdef. The named faces above are
	// the primaries the registry resolved, and stay the truth the markers
	// report.
	Reg *ttf.Registry
}

// FontFiles is the byte source for LoadFonts. Any field may be empty or
// unparseable; the corresponding face is then simply absent.
type FontFiles struct {
	UI, Mono, Bold, Italic []byte
}

func parseOptionalFace(b []byte) *ttf.Face {
	if len(b) == 0 {
		return nil
	}
	face, err := ttf.Parse(b)
	if err != nil {
		return nil
	}
	return face
}

// NewFonts parses the two original faces. Prefer LoadFonts when Bold/Italic
// bytes are available; this wrapper stays so existing call sites keep compiling.
func NewFonts(ui, mono []byte) Fonts {
	return LoadFonts(FontFiles{UI: ui, Mono: mono})
}

// LoadFonts parses each optional face. A face that fails to parse is simply
// absent — the caller reports it, the renderer falls back, and nothing panics.
func LoadFonts(files FontFiles) Fonts {
	return Fonts{
		UI:     parseOptionalFace(files.UI),
		Mono:   parseOptionalFace(files.Mono),
		Bold:   parseOptionalFace(files.Bold),
		Italic: parseOptionalFace(files.Italic),
	}
}

// RegistryFonts builds the engine over a manifest registry: the named faces
// are the registry's resolved primaries (loaded eagerly, as the hard-coded
// path always did), and Reg carries the cascade so a rune a primary lacks
// falls through to a covering face. A nil registry yields the zero engine —
// the caller's bitmap fallback, same as a manifest-less boot.
func RegistryFonts(reg *ttf.Registry) Fonts {
	if reg == nil {
		return Fonts{}
	}
	return Fonts{
		UI:     reg.Primary(ttf.Query{Role: "ui"}),
		Mono:   reg.Primary(ttf.Query{Role: "mono"}),
		Bold:   reg.Primary(ttf.Query{Role: "ui", Bold: true}),
		Italic: reg.Primary(ttf.Query{Role: "ui", Italic: true}),
		Reg:    reg,
	}
}

// Loaded reports whether any TrueType face is available.
func (f Fonts) Loaded() bool {
	return f.UI != nil || f.Mono != nil || f.Bold != nil || f.Italic != nil
}

func glyphCover(face *ttf.Face, r rune, px int) int {
	if face == nil {
		return 0
	}
	m, _, err := face.Glyph(face.GlyphIndex(r), px)
	if err != nil || m.Empty() {
		return 0
	}
	n := 0
	for _, a := range m.Alpha {
		n += int(a)
	}
	return n
}

// BoldHeavier reports whether Inter Bold's stems cover more than Regular at
// body size. Inter matches advances across weights, so Measure cannot tell
// Bold from Regular; a 1-px synthetic strike cannot raise coverage this way.
func (f Fonts) BoldHeavier() bool {
	if f.UI == nil || f.Bold == nil {
		return false
	}
	px := f.px(Style{Size: 1})
	return glyphCover(f.Bold, 'n', px) > glyphCover(f.UI, 'n', px)
}

// Proportional reports whether the engine has real per-glyph advances.
func (f Fonts) Proportional() bool { return f.UI != nil }

// Name describes the engine for the app's serial markers.
func (f Fonts) Name() string {
	switch {
	case f.UI != nil && f.Mono != nil:
		return "truetype(inter+firacode)"
	case f.UI != nil:
		return "truetype(inter)"
	case f.Mono != nil:
		return "truetype(firacode)"
	}
	return "bitmap8x8"
}

// face is the face a style renders with: the monospace face for a mono style
// that has one, otherwise Bold/Italic when requested and loaded, otherwise the
// UI face. nil means "no TrueType face for this style" and the caller falls
// back to the bitmap. There is no Bold-Italic face; Bold wins if both are set.
func (f Fonts) face(st Style) *ttf.Face {
	if st.Mono && f.Mono != nil {
		return f.Mono
	}
	if st.Bold && f.Bold != nil {
		return f.Bold
	}
	if st.Italic && f.Italic != nil {
		return f.Italic
	}
	return f.UI
}

// chain resolves the cascade for a style when the engine was built from a
// manifest. The query mirrors face()'s precedence — mono only when a mono
// primary loaded, bold ahead of italic — so the chain picks the same primary
// the face table would, then falls back per rune. nil means no registry, a
// role the manifest does not list, or a primary that would not load: the
// caller then uses today's single-face/bitmap path.
func (f Fonts) chain(st Style) *ttf.Chain {
	if f.Reg == nil {
		return nil
	}
	q := ttf.Query{Role: "ui"}
	if st.Mono && f.Mono != nil {
		q.Role = "mono"
	}
	if st.Bold && f.Bold != nil {
		q.Bold = true
	} else if st.Italic && f.Italic != nil {
		q.Italic = true
	}
	return f.Reg.Chain(q)
}

// px is the pixel size for a style. Style.Size is a logical scale (1 = body).
func (f Fonts) px(st Style) int {
	if st.FontPx > 0 {
		return st.FontPx
	}
	n := st.Size
	if n < 1 {
		n = 1
	}
	if st.Mono && f.Mono != nil {
		return ttfMonoPx * n
	}
	return ttfBodyPx * n
}

// Measure implements TextEngine.
func (f Fonts) Measure(text string, st Style) int {
	if ch := f.chain(st); ch != nil {
		return ch.Measure(text, f.px(st))
	}
	face := f.face(st)
	if face == nil {
		return Bitmap{}.Measure(text, st)
	}
	return face.Measure(text, f.px(st))
}

// Advance implements TextEngine. The cell is the advance of a wide reference
// rune, so a monospace style keeps its columns lined up.
func (f Fonts) Advance(st Style) int {
	face := f.face(st)
	if face == nil {
		return Bitmap{}.Advance(st)
	}
	return face.AdvancePx('M', f.px(st))
}

// LineHeight implements TextEngine: the face's own ascent+descent+gap, plus a
// pixel of leading so adjacent lines do not touch. For a manifested engine
// this is the PRIMARY face's metrics — the card's rule is that fallback
// glyphs sit on the primary baseline and never move the line box.
func (f Fonts) LineHeight(st Style) int {
	if st.LineHeightPx > 0 {
		return st.LineHeightPx
	}
	if st.FontPx > 0 {
		return (st.FontPx*18 + 12) / 13
	}
	face := f.face(st)
	if face == nil {
		return Bitmap{}.LineHeight(st)
	}
	asc, desc, gap := face.LineMetrics(f.px(st))
	return asc + desc + gap + 2
}

// Paint implements TextEngine. Text is anchored on the LINE BOX TOP the layout
// produced; the engine converts that to the baseline it needs.
func (f Fonts) Paint(s Surface, x, top int, text string, st Style, rgb uint32, c Clip) int {
	if ch := f.chain(st); ch != nil {
		return f.paintChain(s, x, top, text, st, rgb, c, ch)
	}
	face := f.face(st)
	if face == nil {
		return Bitmap{}.Paint(s, x, top, text, st, rgb, c)
	}
	px := f.px(st)
	asc, _, _ := face.LineMetrics(px)
	baseline := top + asc
	pen := x
	tabStep := face.AdvancePx('M', px) * 4
	for _, r := range text {
		if r == '\t' {
			pen += tabStep
			continue
		}
		m, adv, err := face.Glyph(face.GlyphIndex(r), px)
		if err != nil {
			// A glyph the font cannot decode still occupies its width, so one
			// bad glyph does not reflow the rest of the line.
			pen += face.AdvancePx(r, px)
			continue
		}
		if !m.Empty() {
			blitMask(s, c, pen+m.BearingX, baseline-m.BearingY, m, rgb)
			if st.Bold && f.Bold == nil {
				// No bold face loaded: keep the 1-px second strike. Dead
				// when INTERB.TTF parsed (M69d #1531).
				blitMask(s, c, pen+m.BearingX+1, baseline-m.BearingY, m, rgb)
			}
		}
		pen += adv
	}
	return pen - x
}

// paintChain is Paint for a manifested engine: the chain splits the run at
// face boundaries and each piece paints with its own face on the PRIMARY
// face's baseline, so a fallback glyph sits in the line the primary set.
// Measure walks the same Split, so the two can never disagree about a
// rune's width — the rule the comparator gates on.
func (f Fonts) paintChain(s Surface, x, top int, text string, st Style, rgb uint32, c Clip, ch *ttf.Chain) int {
	px := f.px(st)
	primary := ch.Primary()
	if primary == nil {
		return Bitmap{}.Paint(s, x, top, text, st, rgb, c)
	}
	asc, _, _ := primary.LineMetrics(px)
	baseline := top + asc
	pen := x
	tabStep := primary.AdvancePx('M', px) * 4
	for _, piece := range ch.Split(text) {
		face := piece.Face
		if face == nil {
			continue
		}
		for _, r := range piece.Text {
			if r == '\t' {
				pen += tabStep
				continue
			}
			m, adv, err := face.Glyph(face.GlyphIndex(r), px)
			if err != nil {
				pen += face.AdvancePx(r, px)
				continue
			}
			if !m.Empty() {
				blitMask(s, c, pen+m.BearingX, baseline-m.BearingY, m, rgb)
				if st.Bold && f.Bold == nil {
					blitMask(s, c, pen+m.BearingX+1, baseline-m.BearingY, m, rgb)
				}
			}
			pen += adv
		}
	}
	return pen - x
}

// blitMask composites a mask, using the surface's own blender when it has one
// and thresholded spans when it does not.
func blitMask(s Surface, c Clip, x, y int, m *ttf.Mask, rgb uint32) {
	if m.Empty() {
		return
	}
	if ms, ok := s.(MaskSink); ok {
		r := c.Intersect(Clip{X: x, Y: y, W: m.Width, H: m.Height})
		if r.W <= 0 || r.H <= 0 {
			return
		}
		if r.X == x && r.Y == y && r.W == m.Width && r.H == m.Height {
			ms.BlitMask(x, y, m, rgb)
			return
		}
		cropped := &ttf.Mask{Width: r.W, Height: r.H, Alpha: make([]byte, r.W*r.H)}
		for row := 0; row < r.H; row++ {
			from := (r.Y-y+row)*m.Width + r.X - x
			copy(cropped.Alpha[row*r.W:(row+1)*r.W], m.Alpha[from:from+r.W])
		}
		ms.BlitMask(r.X, r.Y, cropped, rgb)
		return
	}
	BlitMaskSpans(s, c, x, y, m, rgb)
}

// BlitMaskSpans is the no-mask-capable-surface fallback, exported so a Surface
// that DOES claim MaskSink can still delegate the plain-fill case (the guest's
// window has a direct back-buffer only when the kernel grants one).
//
// It keeps the pixels the glyph covers at least ~38% of, as one-pixel-high
// spans. That is the same threshold the Zig userland's own fallback uses
// (user/src/lib/ui/draw.zig draw_alpha_mask), and it is why text is never
// invisible on a rect-only surface.
func BlitMaskSpans(s Surface, c Clip, x, y int, m *ttf.Mask, rgb uint32) {
	if m.Empty() {
		return
	}
	const cover = 96
	for row := 0; row < m.Height; row++ {
		py := y + row
		if py < c.Y || py >= c.Y+c.H {
			continue
		}
		col := 0
		for col < m.Width {
			for col < m.Width && m.Alpha[row*m.Width+col] < cover {
				col++
			}
			start := col
			for col < m.Width && m.Alpha[row*m.Width+col] >= cover {
				col++
			}
			if col == start {
				continue
			}
			px, w := x+start, col-start
			if px < c.X {
				w -= c.X - px
				px = c.X
			}
			if px+w > c.X+c.W {
				w = c.X + c.W - px
			}
			if w > 0 {
				s.Fill(px, py, w, 1, rgb)
			}
		}
	}
}

// Bitmap is the built-in 8x8 face scaled by integer factors. It needs no file
// and is always available: this is what the renderer degrades to, and it is why
// a missing font never produces a blank page.
type Bitmap struct{}

func bitmapScale(st Style) int {
	if st.FontPx > 0 {
		return max(1, (st.FontPx+4)/bitmapPx)
	}
	s := st.Size
	if s < 1 {
		s = 1
	}
	return s
}

// Measure implements TextEngine.
func (Bitmap) Measure(text string, st Style) int {
	n := 0
	for range text {
		n++
	}
	return n * bitmapPx * bitmapScale(st)
}

// Advance implements TextEngine.
func (Bitmap) Advance(st Style) int { return bitmapPx * bitmapScale(st) }

// LineHeight implements TextEngine.
func (Bitmap) LineHeight(st Style) int {
	if st.LineHeightPx > 0 {
		return st.LineHeightPx
	}
	if st.FontPx > 0 {
		return (st.FontPx*18 + 12) / 13
	}
	return bitmapPx*bitmapScale(st) + 2
}

// Paint implements TextEngine, emitting glyph rows as spans.
func (Bitmap) Paint(s Surface, x, top int, text string, st Style, rgb uint32, c Clip) int {
	size := bitmapScale(st)
	adv := bitmapPx * size
	// The bitmap face only has ASCII; anything else degrades to '?' so the
	// character stays visible instead of leaving a hole (ADR 0028 D5).
	text = UpperASCII(text)
	cx := x
	for i := 0; i < len(text); i++ {
		ch := rune(text[i])
		if ch == '\t' {
			cx += adv * 4
			continue
		}
		rows := bitmapGlyph(ch)
		bitmapGlyphRows(s, cx, top, rows, size, rgb, c)
		if st.Bold {
			bitmapGlyphRows(s, cx+1, top, rows, size, rgb, c)
		}
		cx += adv
	}
	return cx - x
}

// Proportional implements TextEngine.
func (Bitmap) Proportional() bool { return false }

// Name implements TextEngine.
func (Bitmap) Name() string { return "bitmap8x8" }
