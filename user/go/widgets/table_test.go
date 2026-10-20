package widgets

import (
	"testing"

	"virelai/theme"
)

func tb(cols int, rows int) *Table {
	cs := make([]TableColumn, cols)
	for i := range cs {
		cs[i] = TableColumn{Title: "C", W: 40}
	}
	return &Table{
		R:    Rect{X: 0, Y: 0, W: 200, H: 123},
		Cols: cs, Rows: rows, RowH: 24, HeaderH: 26,
	}
}

// CellRect, CellAt and HeaderAt are one geometry: a point inside a visible
// cell maps back to it, header points name their column, and scrolled-out
// cells never hit.
func TestTableGeometryAgreement(t *testing.T) {
	tb := tb(4, 10)
	if got := tb.VisibleRows(); got != 4 {
		t.Fatalf("VisibleRows = %d, want 4", got)
	}
	for r := 0; r < 4; r++ {
		for c := 0; c < 4; c++ {
			cr := tb.CellRect(r, c).Intersect(tb.ClipRect())
			if cr.Empty() {
				continue
			}
			rr, cc := tb.CellAt(cr.X+1, cr.Y+1)
			if rr != r || cc != c {
				t.Fatalf("CellAt inside CellRect(%d,%d) = (%d,%d)", r, c, rr, cc)
			}
		}
	}
	for c := 0; c < 4; c++ {
		hr := tb.HeaderCellRect(c)
		if got := tb.HeaderAt(hr.X+1, hr.Y+1); got != c {
			t.Fatalf("HeaderAt inside HeaderCellRect(%d) = %d", c, got)
		}
	}
	// Below the model, above the header, and outside the plate all miss.
	tb.ScrollTop = 9 // park on the last row so the body bottom is past the model
	if r, _ := tb.CellAt(tb.R.X+1, tb.BodyRect().Bottom()-1); r != -1 {
		t.Fatalf("row under the model hit: %d", r)
	}
	if _, c := tb.CellAt(tb.R.X+1, tb.headerRect().Y+1); c != -1 {
		t.Fatal("header point hit the body")
	}
	if tb.HeaderAt(tb.R.X+1, tb.BodyRect().Y+1) != -1 {
		t.Fatal("body point hit the header")
	}
}

// Horizontal scroll shifts every cell the same distance, and CellAt follows.
func TestTableScrollXMovesCells(t *testing.T) {
	tb := tb(6, 4) // 240px of columns over a ~198px body
	before := tb.CellRect(0, 2)
	tb.ScrollX = 40
	after := tb.CellRect(0, 2)
	if after.X != before.X-40 || after.Y != before.Y || after.W != before.W {
		t.Fatalf("ScrollX 40: %+v -> %+v", before, after)
	}
	// The point now under the scrolled cell maps back to it.
	cr := after.Intersect(tb.ClipRect())
	if r, c := tb.CellAt(cr.X+1, cr.Y+1); r != 0 || c != 2 {
		t.Fatalf("scrolled CellAt = (%d,%d), want (0,2)", r, c)
	}
	// Column 0 is fully scrolled out (40px of scroll over a 40px column):
	// the left edge of the body now shows col 1, a point left of the plate
	// misses.
	if _, c := tb.CellAt(tb.BodyRect().X+1, tb.BodyRect().Y+1); c != 1 {
		t.Fatalf("scrolled left column = %d, want 1", c)
	}
	if _, c := tb.CellAt(tb.BodyRect().X-1, tb.BodyRect().Y+1); c != -1 {
		t.Fatal("left-of-plate point hit")
	}
}

// Virtualization is the contract: a 128x64 sheet (GOSHEET's bound) draws
// only the visible window — Cell is never asked for a row outside it.
func TestTableVirtualizesRows(t *testing.T) {
	th := tb(128, 64)
	th.R = Rect{W: 200, H: 122}
	th.Cols[0].W = 72
	seen := map[int]bool{}
	th.Cell = func(r, c int) string {
		seen[r] = true
		return "x"
	}
	rc := &recordingCanvas{}
	th.Draw(rc)
	vis := th.VisibleRows()
	for r := range seen {
		if r < 0 || r > vis {
			t.Fatalf("Cell asked for off-window row %d (visible %d)", r, vis)
		}
	}
	if len(seen) > vis+1 {
		t.Fatalf("Cell saw %d rows, want <= %d", len(seen), vis+1)
	}
	th.ScrollTop = 60
	seen = map[int]bool{}
	th.Draw(rc)
	for r := range seen {
		if r < 60 {
			t.Fatalf("scrolled draw touched row %d", r)
		}
	}
}

// The 128x64 bound end-to-end: the far corner cell has real geometry and
// the scroll window clamps to it.
func TestTableSheetScaleGeometry(t *testing.T) {
	th := tb(128, 64)
	cr := th.CellRect(63, 127)
	if cr.W != 40 || cr.X != th.BodyRect().X+127*40 {
		t.Fatalf("far cell = %+v", cr)
	}
	th.ScrollTop = 63
	th.ScrollX = 127 * 40
	if got := th.ClampTop(); got != 64-th.VisibleRows() {
		t.Fatalf("ClampTop = %d", got)
	}
	if th.ClampX() > th.ContentW() {
		t.Fatal("ClampX exceeds content")
	}
	// With max scroll, the last column's right edge sits inside the clip.
	last := th.CellRect(0, 127)
	if last.Right() > th.ClipRect().Right() {
		t.Fatalf("clamped ScrollX leaves col 127 hanging at x=%d clip=%+v", last.Right(), th.ClipRect())
	}
}

// Overflow paints a scrollbar; a fitting model does not.
func TestTableScrollbarOnlyOnOverflow(t *testing.T) {
	th := theme.Current
	fit := tb(4, 4)
	rc := &recordingCanvas{}
	fit.Draw(rc)
	for _, f := range rc.fills {
		if f.r.W == ScrollbarW && f.rgb == th.ChromeBg {
			t.Fatal("scrollbar painted on a fitting table")
		}
	}
	fit.Rows = 40
	rc.fills = nil
	fit.Draw(rc)
	var track bool
	for _, f := range rc.fills {
		if f.r.W == ScrollbarW && f.rgb == th.ChromeBg {
			track = true
		}
	}
	if !track {
		t.Fatal("overflowing table painted no scrollbar track")
	}
}

// The focused cell's accent frame and selection fill are flat FillRects on
// every canvas — the degrade asserts them.
func TestTableFlatDegradeFocusFrame(t *testing.T) {
	th := theme.Current
	tb := tb(3, 6)
	tb.Bg = th.Surface
	tb.Row, tb.Col, tb.Focused = 1, 1, true
	rc := &recordingCanvas{}
	tb.Draw(rc)
	cell := tb.CellRect(1, 1).Intersect(tb.ClipRect())
	var sel, top, left bool
	for _, f := range rc.fills {
		if f.r == cell && f.rgb == th.Selection {
			sel = true
		}
		if f.r == (Rect{X: cell.X, Y: cell.Y, W: cell.W, H: th.FocusW}) && f.rgb == th.Accent {
			top = true
		}
		if f.r == (Rect{X: cell.X, Y: cell.Y, W: th.FocusW, H: cell.H}) && f.rgb == th.Accent {
			left = true
		}
	}
	if !sel || !top || !left {
		t.Fatalf("focus cell paint missing: sel=%v top=%v left=%v", sel, top, left)
	}
}
