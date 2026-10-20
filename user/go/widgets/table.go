package widgets

// The M137b (#2772) grid control: a fixed-geometry virtualized table with a
// column-header band. The model is a row count plus a Cell callback — the
// widget never materializes rows it does not paint, so a 128×64 sheet costs
// the visible window only. Draw, CellAt and HeaderAt all read the SAME
// column/row arithmetic (the kit's hit==paint rule), and the keyboard/focus
// state machine lives in appkit.TableController.

import (
	"virelai/theme"
	"virelai/ttf"
)

// §5.2-adjacent defaults when the fields are unset.
const (
	TableRowH    = 24 // body row height
	TableHeaderH = 26 // header band height
	TableColW    = 72 // column width
)

// TableColumn is one header entry and its pixel width. W<=0 takes TableColW.
type TableColumn struct {
	Title string
	W     int
}

// Table is a columned, virtualized grid. Rows is the model's total row count
// and Cell answers one cell's label — only cells inside the visible window
// (plus a clipped edge row) are ever asked for, so the model can stay sparse
// or computed. Row/Col are the focused cell — the selection — with -1 for
// none. ScrollTop is the first visible row; ScrollX the horizontal pixel
// scroll across ContentW. Face is the §3.4 optional TrueType label face.
// Disabled drops all ink to Muted (§2.3).
type Table struct {
	R         Rect
	Cols      []TableColumn
	Rows      int
	Cell      func(row, col int) string // nil → blank grid
	RowH      int                       // <=0 → TableRowH
	HeaderH   int                       // <=0 → TableHeaderH
	ScrollTop int
	ScrollX   int
	Row, Col  int // focused cell; either <0 → none
	Focused   bool
	Disabled  bool
	Face      *ttf.Face
	Fg, Bg    uint32
	HeaderBg  uint32 // 0 → theme.ChromeBg
	Grid      uint32 // 0 → theme.Rule
	SelBg     uint32 // 0 → theme.Selection
}

// Bounds is the table's full plate, header included.
func (t *Table) Bounds() Rect { return t.R }

// HitTest agrees with Bounds by construction.
func (t *Table) HitTest(x, y int) bool { return t.R.Contains(x, y) }

func (t *Table) rowH() int {
	if t.RowH > 0 {
		return t.RowH
	}
	return TableRowH
}

func (t *Table) headerH() int {
	if t.HeaderH > 0 {
		return t.HeaderH
	}
	return TableHeaderH
}

// ColW is column c's pixel width (the TableColW default when unset or out of
// range).
func (t *Table) ColW(c int) int {
	if c >= 0 && c < len(t.Cols) && t.Cols[c].W > 0 {
		return t.Cols[c].W
	}
	return TableColW
}

func (t *Table) colW(c int) int { return t.ColW(c) }

// ColX is column c's unscrolled x offset from the body's left edge — the
// prefix sum every geometry path shares.
func (t *Table) ColX(c int) int {
	x := 0
	for i := 0; i < c && i < len(t.Cols); i++ {
		x += t.colW(i)
	}
	return x
}

// ContentW is the full scrolled width of all columns.
func (t *Table) ContentW() int { return t.ColX(len(t.Cols)) }

// BodyRect is the data region inside the plate border, under the header
// band. It is the one rect CellAt, RowRect and Draw all read.
func (t *Table) BodyRect() Rect {
	bw := theme.Current.BorderW
	h := t.R.H - t.headerH() - bw
	if h < 0 {
		h = 0
	}
	return Rect{X: t.R.X + bw, Y: t.R.Y + t.headerH(), W: t.R.W - 2*bw, H: h}
}

// headerRect is the header band inside the top border edge.
func (t *Table) headerRect() Rect {
	bw := theme.Current.BorderW
	h := t.headerH() - bw
	if h < 0 {
		h = 0
	}
	return Rect{X: t.R.X + bw, Y: t.R.Y + bw, W: t.R.W - 2*bw, H: h}
}

// scrollBar reports whether the model overflows the visible row window.
func (t *Table) scrollBar() bool { return t.Rows > t.VisibleRows() && t.VisibleRows() > 0 }

// ClipRect is the body minus the scrollbar strip — the region cell fills,
// gridlines and labels are bounded to.
func (t *Table) ClipRect() Rect {
	b := t.BodyRect()
	if t.scrollBar() {
		b.W -= ScrollbarW + theme.Current.PadXS
		if b.W < 0 {
			b.W = 0
		}
	}
	return b
}

// VisibleRows is how many whole body rows fit.
func (t *Table) VisibleRows() int {
	h := t.rowH()
	if h <= 0 {
		return 1
	}
	return t.BodyRect().H / h
}

// ClampTop is ScrollTop bounded to the legal window.
func (t *Table) ClampTop() int {
	top := t.ScrollTop
	if m := t.Rows - t.VisibleRows(); top > m {
		top = m
	}
	if top < 0 {
		top = 0
	}
	return top
}

// ClampX is ScrollX bounded to the legal window.
func (t *Table) ClampX() int {
	x := t.ScrollX
	if m := t.ContentW() - t.ClipRect().W; x > m {
		x = m
	}
	if x < 0 {
		x = 0
	}
	return x
}

// HeaderCellRect is column c's header plate, scrolled by ScrollX.
func (t *Table) HeaderCellRect(c int) Rect {
	h := t.headerRect()
	return Rect{X: h.X + t.ColX(c) - t.ScrollX, Y: h.Y, W: t.colW(c), H: h.H}
}

// RowRect is data row r's visible band — full body width.
func (t *Table) RowRect(r int) Rect {
	b := t.BodyRect()
	return Rect{X: b.X, Y: b.Y + (r-t.ScrollTop)*t.rowH(), W: b.W, H: t.rowH()}
}

// CellRect is cell (r, c)'s visible rect — HeaderCellRect's x with RowRect's
// y. It is the one source Draw and CellAt share.
func (t *Table) CellRect(r, c int) Rect {
	b := t.BodyRect()
	return Rect{X: b.X + t.ColX(c) - t.ScrollX, Y: b.Y + (r-t.ScrollTop)*t.rowH(), W: t.colW(c), H: t.rowH()}
}

// colAt maps an x inside the body to a column index through the same
// ColX/ScrollX arithmetic the paint path uses, or -1 past the last column.
func (t *Table) colAt(x int) int {
	rel := x - t.BodyRect().X + t.ScrollX
	if rel < 0 {
		return -1
	}
	x0 := 0
	for c := 0; c < len(t.Cols); c++ {
		x0 += t.colW(c)
		if rel < x0 {
			return c
		}
	}
	return -1
}

// CellAt maps a point to a data cell: (row, col) or (-1, -1) outside the
// body region or past the model. A point inside CellRect(r, c) maps to
// (r, c) while the cell is visible.
func (t *Table) CellAt(x, y int) (row, col int) {
	b := t.ClipRect()
	if !b.Contains(x, y) {
		return -1, -1
	}
	r := t.ScrollTop + (y-b.Y)/t.rowH()
	if r < 0 || r >= t.Rows {
		return -1, -1
	}
	if c := t.colAt(x); c >= 0 {
		return r, c
	}
	return -1, -1
}

// HeaderAt maps a point to a header cell's column, or -1.
func (t *Table) HeaderAt(x, y int) int {
	if !t.headerRect().Contains(x, y) {
		return -1
	}
	return t.colAt(x)
}

// Draw paints the plate, the header band with its titles and rule, the
// visible row window's cells and gridlines, the focused cell's accent frame,
// an overflow scrollbar, and the focus ring. Only rows in
// [ScrollTop, ScrollTop+visible+1] touch the canvas or the Cell callback.
func (t *Table) Draw(c RectCanvas) {
	if t.R.Empty() {
		return
	}
	th := theme.Current
	fc, full := c.(Canvas)
	bw := th.BorderW
	fg := t.Fg
	if fg == 0 {
		fg = th.Text
	}
	if t.Disabled {
		fg = th.Muted
	}
	bg := t.Bg
	if bg == 0 {
		bg = th.Surface
	}
	grid := t.Grid
	if grid == 0 {
		grid = th.Rule
	}
	headerBg := t.HeaderBg
	if headerBg == 0 {
		headerBg = th.ChromeBg
	}
	if full {
		fc.FillRoundedRect(t.R, radiusControl, opaque(bg))
		fc.StrokeRoundedRect(t.R, radiusControl, bw, opaque(th.Border))
	} else {
		c.FillRect(t.R, bg)
	}
	clip := t.ClipRect()
	// Header band, its rule, and one clipped title per column.
	if len(t.Cols) > 0 {
		hr := t.headerRect()
		if full {
			fc.FillRect(hr, opaque(headerBg))
		} else {
			c.FillRect(hr, headerBg)
		}
		for i := range t.Cols {
			cell := t.HeaderCellRect(i).Intersect(clip)
			if cell.Empty() {
				continue
			}
			if t.Cols[i].Title != "" {
				if full {
					drawLabel(fc, t.Face, cell, t.Cols[i].Title, fg, false)
				} else {
					drawGlyphRun(c, cell, t.Cols[i].Title, fg)
				}
			}
		}
		c.FillRect(Rect{X: clip.X, Y: clip.Y - 1, W: clip.W, H: 1}, grid)
	}
	body := t.BodyRect()
	rh := t.rowH()
	top := t.ScrollTop
	if top < 0 {
		top = 0
	}
	// The window: whole visible rows plus the clipped edge row — never more.
	last := top + body.H/rh + 1
	if last > t.Rows {
		last = t.Rows
	}
	sel := t.SelBg
	if sel == 0 {
		sel = th.Selection
	}
	for r := top; r < last; r++ {
		band := t.RowRect(r)
		for i := range t.Cols {
			cell := t.CellRect(r, i).Intersect(clip)
			if cell.Empty() {
				continue
			}
			if r == t.Row && i == t.Col {
				if full {
					fc.FillRect(cell, opaque(sel))
				} else {
					c.FillRect(cell, sel)
				}
			}
			if t.Cell != nil {
				if s := t.Cell(r, i); s != "" {
					if full {
						drawLabel(fc, t.Face, cell, s, fg, false)
					} else {
						drawGlyphRun(c, cell, s, fg)
					}
				}
			}
		}
		if y := band.Y + rh - 1; y < clip.Bottom() && band.Y < clip.Bottom() {
			c.FillRect(Rect{X: clip.X, Y: y, W: clip.W, H: 1}, grid)
		}
	}
	// Column separators span the header and the painted body.
	for i := 1; i < len(t.Cols); i++ {
		x := body.X + t.ColX(i) - t.ScrollX
		if x < clip.X || x >= clip.Right() {
			continue
		}
		y0 := t.headerRect().Y
		bot := clip.Y + (last-top)*rh
		if bot > clip.Bottom() {
			bot = clip.Bottom()
		}
		if bot > y0 {
			c.FillRect(Rect{X: x, Y: y0, W: 1, H: bot - y0}, grid)
		}
	}
	// The focused cell gets the §2.3 accent frame — flat FocusW edges on
	// every canvas so the flat and full forms read identically.
	if t.Row >= 0 && t.Col >= 0 && t.Focused {
		cell := t.CellRect(t.Row, t.Col).Intersect(clip)
		if !cell.Empty() {
			fw := th.FocusW
			if fw < 1 {
				fw = 1
			}
			c.FillRect(Rect{X: cell.X, Y: cell.Y, W: cell.W, H: fw}, th.Accent)
			c.FillRect(Rect{X: cell.X, Y: cell.Bottom() - fw, W: cell.W, H: fw}, th.Accent)
			c.FillRect(Rect{X: cell.X, Y: cell.Y, W: fw, H: cell.H}, th.Accent)
			c.FillRect(Rect{X: cell.Right() - fw, Y: cell.Y, W: fw, H: cell.H}, th.Accent)
		}
	}
	if t.scrollBar() {
		(&Scrollbar{
			R:        Rect{X: body.Right() - ScrollbarW, Y: body.Y, W: ScrollbarW, H: body.H},
			Total:    t.Rows,
			Viewport: t.VisibleRows(),
			Offset:   t.ClampTop(),
		}).Draw(c)
	}
	if t.Focused {
		fw := th.FocusW
		if fw < 1 {
			fw = 1
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
