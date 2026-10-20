package widgets

import (
	"testing"

	"virelai/theme"
)

var treeRows = []TreeRow{
	{Label: "system", Depth: 0, HasKids: true, Expanded: true},
	{Label: "kernel", Depth: 1},
	{Label: "apps", Depth: 0, HasKids: true},
	{Label: "docs", Depth: 0},
}

// RowRect, ItemAt and ChevronRect are one geometry: a point inside a
// visible row maps back to it, and the chevron cell steps with Depth.
func TestTreeGeometryAgreement(t *testing.T) {
	tr := &Tree{R: Rect{X: 10, Y: 10, W: 200, H: 96}, Rows: treeRows, RowH: 24}
	if got := tr.VisibleRows(); got != 4 {
		t.Fatalf("VisibleRows = %d, want 4", got)
	}
	for i := range tr.Rows {
		rr := tr.RowRect(i)
		if got := tr.ItemAt(rr.X+1, rr.Y+1); got != i {
			t.Fatalf("ItemAt inside RowRect(%d) = %d", i, got)
		}
		if got := tr.ItemAt(rr.Right()-1, rr.Bottom()-1); got != i {
			t.Fatalf("ItemAt at RowRect(%d) br = %d", i, got)
		}
	}
	if tr.ItemAt(tr.R.X-1, tr.R.Y) != -1 || tr.ItemAt(tr.R.X, tr.R.Bottom()) != -1 {
		t.Fatal("out-of-plate points must be -1")
	}
	// Depth indents the chevron cell; siblings share it.
	c0, c1, c2 := tr.ChevronRect(0), tr.ChevronRect(1), tr.ChevronRect(2)
	if c1.X-c0.X != tr.indent() {
		t.Fatalf("depth-1 chevron off by %d, want %d", c1.X-c0.X, tr.indent())
	}
	if c2.X != c0.X || c2.Y != c0.Y+2*tr.rowH() {
		t.Fatalf("sibling chevron = %+v, want same x, +2 rows", c2)
	}
	// Scrolled-out rows must not hit.
	tr.ScrollTop = 2
	if got := tr.ItemAt(tr.RowRect(0).X+1, tr.RowRect(0).Y+1); got == 0 {
		t.Fatal("scrolled-out row hit")
	}
}

// A chevron click is a hit on the row AND inside ChevronRect — the
// controller's toggle path depends on both reading the same cell.
func TestTreeChevronInsideRow(t *testing.T) {
	tr := &Tree{R: Rect{X: 0, Y: 0, W: 200, H: 96}, Rows: treeRows, RowH: 24}
	c := tr.ChevronRect(0)
	if !tr.RowRect(0).Contains(c.X+1, c.Y+1) {
		t.Fatal("chevron must sit inside its row band")
	}
	if tr.ItemAt(c.X+1, c.Y+1) != 0 {
		t.Fatal("chevron point must map to its row")
	}
}

// The degrade form: plate fill, the selected row's fill plus 3px Accent
// marker, and a scrollbar track when rows overflow — all flat FillRects.
func TestTreeFlatDegrade(t *testing.T) {
	th := theme.Current
	rows := append([]TreeRow{}, treeRows...)
	rows = append(rows, treeRows...) // 8 rows over a 4-row viewport
	tr := &Tree{R: Rect{X: 0, Y: 0, W: 160, H: 96}, Rows: rows, RowH: 24, Sel: 1, Bg: th.Surface, SelBg: th.Selection}
	rc := &recordingCanvas{}
	tr.Draw(rc)
	var plate, selFill, mark, barTrack bool
	rr := tr.RowRect(1)
	for _, f := range rc.fills {
		if f.r == tr.R && f.rgb == th.Surface {
			plate = true
		}
		if f.r == (Rect{X: rr.X + th.PadXS, Y: rr.Y, W: tr.R.Right() - ScrollbarW - 2*th.PadXS - rr.X, H: rr.H}) && f.rgb == th.Selection {
			selFill = true
		}
		if f.r.W == 3 && f.rgb == th.Accent {
			mark = true
		}
		if f.r.W == ScrollbarW && f.rgb == th.ChromeBg {
			barTrack = true
		}
	}
	if !plate || !selFill || !mark || !barTrack {
		t.Fatalf("degrade missing: plate=%v sel=%v mark=%v bar=%v", plate, selFill, mark, barTrack)
	}
}

// No overflow, no scrollbar; and the plate is the whole fill story when the
// model is empty.
func TestTreeNoOverflowNoBar(t *testing.T) {
	tr := &Tree{R: Rect{X: 0, Y: 0, W: 160, H: 96}, Rows: treeRows, RowH: 24}
	rc := &recordingCanvas{}
	tr.Draw(rc)
	for _, f := range rc.fills {
		if f.r.W == ScrollbarW {
			t.Fatal("scrollbar painted on a fitting outline")
		}
	}
}
