package widgets

import (
	"strings"
	"unicode/utf8"

	"virelai/theme"
	"virelai/ttf"
	"virelai/webrender/font"
)

// --- EmptyState -------------------------------------------------------------
//
// EmptyState is the M123b (#2576) blank-surface presenter — the Go port of
// dialog.zig's draw_empty_state / draw_empty_state_icon pair (M27 G22 #465):
// a Surface plate ringed in Border carrying an optional icon row, a headline
// and one or more chord-hint lines, every row centred in R. The four blank
// surfaces (GOFILES' empty list, WEB's start viewport, GOEDIT's empty
// buffer, the launcher's zero-match list) share this one copy model, so a
// user never meets a bare rect.
//
// Canvas apps Draw it. A VT app renders the same content through Lines —
// GOFILES' truecolour grid is text, not a Canvas, so the widget exports the
// rows instead of the pixels for it.
type EmptyState struct {
	R        Rect
	Icon     string // one row above the headline; "" suppresses it
	Headline string
	Hints    []string  // one centred line each, in order
	Face     *ttf.Face // optional label face; nil → the 8x8 bitmap face
}

// The stack's band heights are logical, identical on both paint paths, so
// the bitmap degrade and the TrueType face agree on one geometry. The icon
// paints at 2x — the bitmap face's 16px cell or the face's 26px.
const (
	emptyIconPx = 2 * labelPx
	emptyHintPx = 11

	emptyIconH = 22
	emptyHeadH = 18
	emptyHintH = 16
	emptyGap   = 8 // between stack sections
)

// Bounds is the plate — Draw and HitTest both read it.
func (e *EmptyState) Bounds() Rect { return e.R }

// HitTest agrees with Bounds by construction. The panel is informational:
// it owns no targets of its own.
func (e *EmptyState) HitTest(x, y int) bool { return e.R.Contains(x, y) }

// stackH is the content column's pixel height.
func (e *EmptyState) stackH() int {
	h := 0
	add := func(rh int) {
		if h > 0 {
			h += emptyGap
		}
		h += rh
	}
	if e.Icon != "" {
		add(emptyIconH)
	}
	if e.Headline != "" {
		add(emptyHeadH)
	}
	for _, s := range e.Hints {
		if s != "" {
			add(emptyHintH)
		}
	}
	return h
}

// Draw paints the plate and the centred stack. A full Canvas gets the §2.2
// rounded plate and border, labels through Canvas.Text when Face resolves;
// a fill-only RectCanvas keeps the flat form — fill, border bands, and the
// 8x8 run at exact centred positions.
func (e *EmptyState) Draw(c RectCanvas) {
	if e.R.Empty() {
		return
	}
	th := theme.Current
	fc, full := c.(Canvas)
	if full {
		fc.FillRoundedRect(e.R, radiusControl, opaque(th.Surface))
		fc.StrokeRoundedRect(e.R, radiusControl, th.BorderW, opaque(th.Border))
	} else {
		c.FillRect(e.R, th.Surface)
		bw := th.BorderW
		if bw < 1 {
			bw = 1
		}
		c.FillRect(Rect{X: e.R.X, Y: e.R.Y, W: e.R.W, H: bw}, th.Border)
		c.FillRect(Rect{X: e.R.X, Y: e.R.Bottom() - bw, W: e.R.W, H: bw}, th.Border)
		c.FillRect(Rect{X: e.R.X, Y: e.R.Y + bw, W: bw, H: e.R.H - 2*bw}, th.Border)
		c.FillRect(Rect{X: e.R.Right() - bw, Y: e.R.Y + bw, W: bw, H: e.R.H - 2*bw}, th.Border)
	}
	inner := e.R.Inset(th.BorderW + th.PadMD)
	if inner.Empty() {
		return
	}
	// On a full Canvas the fills are 0xAARRGGBB — the raster engine skips
	// alpha-zero colours, so the text inks go through opaque() here (the
	// fill-only path keeps 24-bit tokens; virender's write masks anyway).
	text, muted := th.Text, th.Muted
	if full {
		text, muted = opaque(text), opaque(muted)
	}
	y := inner.Y + (inner.H-e.stackH())/2
	if y < inner.Y {
		y = inner.Y
	}
	if e.Icon != "" {
		e.line(c, inner, y, emptyIconH, e.Icon, emptyIconPx, 2, muted)
		y += emptyIconH + emptyGap
	}
	if e.Headline != "" {
		e.line(c, inner, y, emptyHeadH, e.Headline, labelPx, 1, text)
		y += emptyHeadH + emptyGap
	}
	for _, s := range e.Hints {
		if s == "" {
			continue
		}
		e.line(c, inner, y, emptyHintH, s, emptyHintPx, 1, muted)
		y += emptyHintH + emptyGap/2
	}
}

// line paints one row centred in its band. The face's own measure places
// the TrueType run; the bitmap path places the 8x8 run itself, because the
// Canvas.Text degrade anchors at a plate's left edge — an empty state's
// whole point is the centre.
func (e *EmptyState) line(c RectCanvas, clip Rect, y, h int, s string, px, scale int, rgb uint32) {
	if s == "" {
		return
	}
	if fc, ok := c.(Canvas); ok && e.Face != nil {
		w := e.Face.Measure(s, px)
		x := clip.X + (clip.W-w)/2
		if x < clip.X {
			x = clip.X
		}
		asc, desc, _ := e.Face.LineMetrics(px)
		fc.Text(e.Face, clip, x, y+(h-asc-desc)/2+asc, px, s, opaque(rgb))
		return
	}
	cw := font.Advance(1) * scale
	w := utf8.RuneCountInString(s) * cw
	x := clip.X + (clip.W-w)/2
	if x < clip.X {
		x = clip.X
	}
	gy := y + (h-8*scale)/2
	if gy < clip.Y {
		gy = clip.Y
	}
	drawRunAt(c, clip, x, gy, scale, s, rgb)
}

// drawRunAt paints s at the exact (x, y) with the 8x8 face at scale — lit
// cells become scale×scale fills, clipped to clip. It is the centred-line
// primitive drawGlyphRun cannot express (it anchors at its plate's left
// edge and centres vertically inside it).
func drawRunAt(c RectCanvas, clip Rect, x, y, scale int, s string, rgb uint32) {
	cw := font.Advance(1) * scale
	cx := x
	for _, ch := range s {
		if cx >= clip.Right() {
			break
		}
		g := font.Glyph8(ch)
		for row := 0; row < 8; row++ {
			py := y + row*scale
			if py >= clip.Bottom() {
				break
			}
			bits := g[row]
			for col := 0; col < 8; {
				if bits&(1<<uint(col)) == 0 {
					col++
					continue
				}
				run := 1
				for col+run < 8 && bits&(1<<uint(col+run)) != 0 {
					run++
				}
				r := Rect{X: cx + col*scale, Y: py, W: run * scale, H: scale}
				if r.X < clip.X {
					r.W -= clip.X - r.X
					r.X = clip.X
				}
				if r.Y < clip.Y {
					r.H -= clip.Y - r.Y
					r.Y = clip.Y
				}
				if r.Right() > clip.Right() {
					r.W = clip.Right() - r.X
				}
				if r.Bottom() > clip.Bottom() {
					r.H = clip.Bottom() - r.Y
				}
				if !r.Empty() {
					c.FillRect(r, rgb)
				}
				col += run
			}
		}
		cx += cw
	}
}

// Lines renders the same content as text rows for a VT grid: h rows of w
// cells, the [icon,] headline, one blank spacer and the hint lines centred
// in both axes, blank rows elsewhere. It is the only empty-state surface a
// non-Canvas app can show.
func (e EmptyState) Lines(w, h int) []string {
	if w <= 0 || h <= 0 {
		return nil
	}
	var rows []string
	if e.Icon != "" {
		rows = append(rows, e.Icon)
	}
	if e.Headline != "" {
		rows = append(rows, e.Headline)
	}
	var hints []string
	for _, s := range e.Hints {
		if s != "" {
			hints = append(hints, s)
		}
	}
	if len(hints) > 0 && len(rows) > 0 {
		rows = append(rows, "")
	}
	rows = append(rows, hints...)
	out := make([]string, h)
	blank := strings.Repeat(" ", w)
	for i := range out {
		out[i] = blank
	}
	top := (h - len(rows)) / 2
	if top < 0 {
		top = 0
	}
	for i, s := range rows {
		if top+i >= h {
			break
		}
		rs := []rune(s)
		if len(rs) > w {
			rs = rs[:w]
		}
		pad := (w - len(rs)) / 2
		out[top+i] = strings.Repeat(" ", pad) + string(rs) + strings.Repeat(" ", w-pad-len(rs))
	}
	return out
}

// DrawEmptyState is the one-call form the four M123b surfaces use when the
// bitmap face is the label path.
func DrawEmptyState(c RectCanvas, r Rect, icon, headline string, hints ...string) {
	(&EmptyState{R: r, Icon: icon, Headline: headline, Hints: hints}).Draw(c)
}
