package widgets

// The M137b (#2772) outline control: a flat visible-row projection of a node
// model, painted like List plus a per-depth chevron column. The model,
// expand/collapse state and keyboard navigation live in
// appkit.TreeController — the widget stays pure geometry and paint, so Draw
// and ItemAt read the SAME RowRect arithmetic and a fill-only recorder still
// sees the degrade form.

import (
	"virelai/icons"
	"virelai/theme"
	"virelai/ttf"
)

// TreeRowH is the §2.4 row height the outline shares with dropdown rows.
const TreeRowH = 24

// treeIndent is the per-depth step when IndentW is unset.
const treeIndent = 16

// TreeRow is one visible outline row — already flattened in display order by
// whoever owns the model (appkit.TreeController). HasKids paints the
// expand/collapse affordance; Expanded picks its direction.
type TreeRow struct {
	Label    string
	Depth    int  // indent level; roots are 0
	HasKids  bool // chevron affordance painted when true
	Expanded bool // chevron-down when true, chevron-right when false
}

// Tree is the outline widget. Rows is the flattened window the controller
// maintains; Sel and ScrollTop have List's meaning. Face is the §3.4
// optional TrueType label face — nil keeps the 8x8 bitmap face. IconFace
// carries the chevron glyphs (E007/E009); nil degrades to ">" / "v" text.
// Disabled drops labels to the Muted role (§2.3).
type Tree struct {
	R         Rect
	Rows      []TreeRow
	RowH      int // <=0 → TreeRowH
	Sel       int // selected row; <0 → none
	ScrollTop int // first visible row
	IndentW   int // per-depth indent; <=0 → treeIndent
	Focused   bool
	Disabled  bool
	Face      *ttf.Face
	IconFace  *ttf.Face
	Fg, Bg    uint32
	SelBg     uint32
}

// Bounds is the outline's full rect.
func (t *Tree) Bounds() Rect { return t.R }

// HitTest agrees with Bounds by construction.
func (t *Tree) HitTest(x, y int) bool { return t.R.Contains(x, y) }

func (t *Tree) rowH() int {
	if t.RowH > 0 {
		return t.RowH
	}
	return TreeRowH
}

func (t *Tree) indent() int {
	if t.IndentW > 0 {
		return t.IndentW
	}
	return treeIndent
}

// RowRect is row i's band — the single geometry source for Draw, ItemAt and
// ChevronRect. Only rows in the visible window land inside R.
func (t *Tree) RowRect(i int) Rect {
	return Rect{t.R.X, t.R.Y + (i-t.ScrollTop)*t.rowH(), t.R.W, t.rowH()}
}

// VisibleRows is how many whole rows fit between the top and bottom edges.
func (t *Tree) VisibleRows() int {
	if t.R.H <= 0 {
		return 0
	}
	return t.R.H / t.rowH()
}

// ItemAt returns the row index a point hits, or -1 — the same arithmetic as
// RowRect, so a point inside RowRect(i) always maps to i.
func (t *Tree) ItemAt(x, y int) int {
	if !t.R.Contains(x, y) {
		return -1
	}
	row := (y - t.R.Y) / t.rowH()
	i := row + t.ScrollTop
	if row < 0 || i < 0 || i >= len(t.Rows) {
		return -1
	}
	return i
}

// ChevronRect is row i's affordance cell — the 16×16 box the expand/collapse
// glyph sits in and the click path hit-tests. It is valid geometry for any
// row; only rows with HasKids paint it.
func (t *Tree) ChevronRect(i int) Rect {
	d := t.Rows[i].Depth
	if d < 0 {
		d = 0
	}
	r := t.RowRect(i)
	s := icons.NominalPx
	return Rect{
		X: t.R.X + theme.Current.PadXS + d*t.indent(),
		Y: r.Y + (r.H-s)/2,
		W: s, H: s,
	}
}

// labelRect is the text plate for row i: chevron-slot width reserved whether
// or not the row is a branch, so leaf labels line up with branch labels.
func (t *Tree) labelRect(i int) Rect {
	r := t.RowRect(i)
	x := t.R.X + theme.Current.PadXS + t.Rows[i].Depth*t.indent() + icons.NominalPx + theme.Current.PadXS
	return Rect{X: x, Y: r.Y, W: t.R.Right() - x, H: r.H}
}

// Draw paints the plate, the selected row, each visible row's chevron and
// label, an overflow scrollbar, and the focus ring — the same §2.2/§2.3
// vocabulary as List. A full Canvas gets the rounded plate, the 3px Accent
// selected marker and TrueType labels; a RectCanvas-only surface keeps the
// flat v1 form.
func (t *Tree) Draw(c RectCanvas) {
	if t.R.Empty() {
		return
	}
	th := theme.Current
	fc, full := c.(Canvas)
	fg := t.Fg
	if t.Disabled {
		fg = th.Muted
	}
	if full {
		fc.FillRoundedRect(t.R, radiusControl, opaque(t.Bg))
		fc.StrokeRoundedRect(t.R, radiusControl, th.BorderW, opaque(th.Border))
	} else {
		c.FillRect(t.R, t.Bg)
	}
	start := t.ScrollTop
	if start < 0 {
		start = 0
	}
	if start > len(t.Rows) {
		start = len(t.Rows)
	}
	clipR := t.R
	if len(t.Rows) > t.VisibleRows() {
		clipR.W -= ScrollbarW + th.PadXS
	}
	for i := start; i < len(t.Rows); i++ {
		rr := t.RowRect(i)
		if rr.Y >= t.R.Bottom() {
			break
		}
		clip := rr
		if clip.Bottom() > t.R.Bottom() {
			clip.H = t.R.Bottom() - clip.Y
		}
		if clip.H <= 0 {
			break
		}
		label := t.labelRect(i)
		if i == t.Sel {
			sel := t.SelBg
			if sel == 0 {
				sel = th.Selection
			}
			fill := clip.Intersect(Rect{X: clip.X + th.PadXS, Y: clip.Y, W: clipR.Right() - clip.X - th.PadXS, H: clip.H})
			if full {
				fc.FillRect(fill, opaque(sel))
				mark := fill
				mark.W = 3
				if mark.H > 2 {
					mark.Y++
					mark.H -= 2
				}
				fc.FillRect(mark, opaque(th.Accent))
			} else {
				c.FillRect(fill, sel)
				c.FillRect(Rect{X: fill.X, Y: fill.Y + 1, W: 3, H: fill.H - 2}, th.Accent)
			}
		}
		row := t.Rows[i]
		if row.HasKids {
			t.chevron(c, fc, full, i, fg)
		}
		if full {
			drawLabel(fc, t.Face, label.Intersect(clipR), row.Label, fg, false)
		} else {
			drawGlyphRun(c, label.Intersect(clipR), row.Label, fg)
		}
	}
	if len(t.Rows) > t.VisibleRows() && t.VisibleRows() > 0 {
		(&Scrollbar{
			R:        Rect{X: t.R.Right() - ScrollbarW - th.BorderW, Y: t.R.Y + th.BorderW, W: ScrollbarW, H: t.R.H - 2*th.BorderW},
			Total:    len(t.Rows),
			Viewport: t.VisibleRows(),
			Offset:   t.ScrollTop,
		}).Draw(c)
	}
	if t.Focused {
		fw := th.FocusW
		if fw < 1 {
			fw = 1
		}
		if fw > t.R.W {
			fw = t.R.W
		}
		if fw > t.R.H {
			fw = t.R.H
		}
		if full {
			fc.StrokeRoundedRect(t.R, radiusControl, fw, opaque(th.Accent))
		} else {
			c.FillRect(Rect{X: t.R.X, Y: t.R.Y, W: t.R.W, H: fw}, th.Accent)
			c.FillRect(Rect{X: t.R.X, Y: t.R.Bottom() - fw, W: t.R.W, H: fw}, th.Accent)
			c.FillRect(Rect{X: t.R.X, Y: t.R.Y, W: fw, H: t.R.H}, th.Accent)
			c.FillRect(Rect{X: t.R.Right() - fw, Y: t.R.Y, W: fw, H: t.R.H}, th.Accent)
		}
	}
}

// chevron paints row i's affordance: the E007/E009 glyph on a full Canvas
// with an IconFace, else the ASCII degrade — ">" collapsed, "v" expanded.
func (t *Tree) chevron(c RectCanvas, fc Canvas, full bool, i int, fg uint32) {
	chev := t.ChevronRect(i)
	name := "chevron-right"
	bare := ">"
	if t.Rows[i].Expanded {
		name = "chevron-down"
		bare = "v"
	}
	if full && t.IconFace != nil {
		if cp, ok := icons.Codepoint(name); ok {
			asc, desc, _ := t.IconFace.LineMetrics(icons.NominalPx)
			y := chev.Y + (chev.H-asc-desc)/2 + asc
			fc.Text(t.IconFace, chev, chev.X, y, icons.NominalPx, string(cp), opaque(fg))
			return
		}
	}
	drawGlyphRun(c, chev, bare, fg)
}
