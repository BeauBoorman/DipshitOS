package appkit

import (
	"testing"

	"virelai/widgets"
)

var _ Focusable = &TableController{}

func testTable() (*TableController, *widgets.Table) {
	cols := make([]widgets.TableColumn, 16)
	for i := range cols {
		cols[i] = widgets.TableColumn{Title: "C", W: 40}
	}
	tb := &widgets.Table{
		R:    widgets.Rect{X: 0, Y: 0, W: 200, H: 123},
		Cols: cols, Rows: 40, RowH: 24, HeaderH: 26,
	}
	c := NewTableController(tb)
	c.FocusCell(0, 0)
	return c, tb
}

// Arrows move the focused cell, clamped at the model's edges.
func TestTableArrowMoveAndClamp(t *testing.T) {
	c, tb := testTable()
	if !c.OnKey(Key{Usage: 0x51}) || tb.Row != 1 {
		t.Fatalf("down row = %d", tb.Row)
	}
	if !c.OnKey(Key{Usage: 0x4f}) || tb.Col != 1 {
		t.Fatalf("right col = %d", tb.Col)
	}
	c.OnKey(Key{Usage: 0x52})
	c.OnKey(Key{Usage: 0x50})
	if tb.Row != 0 || tb.Col != 0 {
		t.Fatalf("back to origin: (%d,%d)", tb.Row, tb.Col)
	}
	// Clamps: up/left at the origin are no-change no-ops.
	if c.OnKey(Key{Usage: 0x52}) || c.OnKey(Key{Usage: 0x50}) {
		t.Fatal("clamped moves must report no change")
	}
	if tb.Row != 0 || tb.Col != 0 {
		t.Fatal("clamped move drifted")
	}
}

// Home/End are column ends; Ctrl reaches the model corners — the sheet
// contract.
func TestTableHomeEndCorners(t *testing.T) {
	c, tb := testTable()
	c.FocusCell(5, 5)
	if !c.OnKey(Key{Usage: 0x4d}) || tb.Col != 15 || tb.Row != 5 {
		t.Fatalf("End = (%d,%d)", tb.Row, tb.Col)
	}
	if !c.OnKey(Key{Usage: 0x4a}) || tb.Col != 0 || tb.Row != 5 {
		t.Fatalf("Home = (%d,%d)", tb.Row, tb.Col)
	}
	if !c.OnKey(Key{Usage: 0x4d, Ctrl: true}) || tb.Row != 39 || tb.Col != 15 {
		t.Fatalf("Ctrl-End = (%d,%d)", tb.Row, tb.Col)
	}
	if !c.OnKey(Key{Usage: 0x4a, Ctrl: true}) || tb.Row != 0 || tb.Col != 0 {
		t.Fatalf("Ctrl-Home = (%d,%d)", tb.Row, tb.Col)
	}
}

// Paging and scroll-into-view on both axes: the focused cell is never left
// outside the window.
func TestTableScrollIntoView(t *testing.T) {
	c, tb := testTable()
	vis := tb.VisibleRows()                          // 4 rows, ~4.9 columns of window
	if !c.OnKey(Key{Usage: 0x4e}) || tb.Row != vis { // PageDown
		t.Fatalf("pagedown row = %d, want %d", tb.Row, vis)
	}
	if tb.ScrollTop == 0 {
		t.Fatal("paging must scroll")
	}
	c.OnKey(Key{Usage: 0x4b}) // PageUp
	if tb.Row != 0 || tb.ScrollTop != 0 {
		t.Fatalf("pageup row=%d top=%d", tb.Row, tb.ScrollTop)
	}
	// Right to a column past the window scrolls horizontally.
	for i := 0; i < 8; i++ {
		c.OnKey(Key{Usage: 0x4f})
	}
	if tb.Col != 8 {
		t.Fatalf("col = %d", tb.Col)
	}
	if tb.ScrollX <= 0 {
		t.Fatal("horizontal focus must scroll")
	}
	if cr := tb.CellRect(tb.Row, tb.Col).Intersect(tb.BodyRect()); cr.W <= 0 {
		t.Fatalf("focused cell off-view: %+v", tb.CellRect(tb.Row, tb.Col))
	}
	// Walking all the way back left returns the window to x=0.
	for i := 0; i < 8; i++ {
		c.OnKey(Key{Usage: 0x50})
	}
	if tb.Col != 0 || tb.ScrollX != 0 {
		t.Fatalf("back to col 0: col=%d scrollX=%d", tb.Col, tb.ScrollX)
	}
}

// Enter activates through OnActivate; a click focuses its cell; a header
// click selects that column on the focused row.
func TestTableActivateAndClick(t *testing.T) {
	c, tb := testTable()
	var fired [2]int
	c.OnActivate = func(r, col int) bool { fired = [2]int{r, col}; return true }
	c.FocusCell(2, 3)
	if !c.OnKey(Key{Usage: 0x28}) || fired != [2]int{2, 3} {
		t.Fatalf("activate = %v", fired)
	}
	cr := tb.CellRect(1, 2).Intersect(tb.BodyRect())
	if !c.OnClick(cr.X+2, cr.Y+2) || tb.Row != 1 || tb.Col != 2 {
		t.Fatalf("cell click = (%d,%d)", tb.Row, tb.Col)
	}
	hr := tb.HeaderCellRect(3)
	if !c.OnClick(hr.X+2, hr.Y+2) || tb.Col != 3 || tb.Row != 1 {
		t.Fatalf("header click = (%d,%d)", tb.Row, tb.Col)
	}
	if c.OnClick(500, 500) {
		t.Fatal("outside click consumed")
	}
}

// The sheet bound: 128 columns by 64 rows navigates to the far corner.
func TestTableSheetScaleNav(t *testing.T) {
	cols := make([]widgets.TableColumn, 128)
	for i := range cols {
		cols[i] = widgets.TableColumn{Title: "C"}
	}
	tb := &widgets.Table{
		R:    widgets.Rect{X: 0, Y: 0, W: 300, H: 200},
		Cols: cols, Rows: 64,
	}
	c := NewTableController(tb)
	c.FocusCell(0, 0)
	c.OnKey(Key{Usage: 0x4d, Ctrl: true})
	if tb.Row != 63 || tb.Col != 127 {
		t.Fatalf("ctrl-end = (%d,%d)", tb.Row, tb.Col)
	}
	if tb.ScrollTop == 0 || tb.ScrollX == 0 {
		t.Fatal("far corner must scroll both axes")
	}
	// The focused cell must actually be fully inside the clip.
	cell := tb.CellRect(63, 127).Intersect(tb.ClipRect())
	if cell.W != tb.ColW(127) || cell.H != widgets.TableRowH {
		t.Fatalf("far cell not fully visible: %+v", cell)
	}
}
