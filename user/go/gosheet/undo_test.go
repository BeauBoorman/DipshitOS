package main

import (
	"testing"

	"virelai/appkit"
	"virelai/widgets"
)

// newTestApp wires the minimal app shell the gesture paths touch: the
// sheet under test, an initialized formula bar, and the selection table
// (mark/cursor drive selSpan). The vi console sink is a no-op on host.
func newTestApp(s *Sheet) *app {
	return &app{
		sheet: s,
		field: appkit.NewTextField(widgets.Rect{}, fieldMax),
		table: &widgets.Table{
			Cols: make([]widgets.TableColumn, NumCols),
			Rows: NumRows, RowH: rowH, HeaderH: headerH,
		},
	}
}

// selectSpan parks the mark/cursor so selSpan covers lo..hi.
func selectSpan(a *app, lo, hi cellRef) {
	a.mark, a.markOn = lo, true
	a.table.Col, a.table.Row = hi.col, hi.row
}

// The card's bound: the ring holds exactly 32 steps and drops the oldest.
func TestUndoRingBound(t *testing.T) {
	u := &undoRing{}
	for i := 0; i < undoDepth+5; i++ {
		u.push(undoStep{cells: []cellDiff{{r: refAt(i % NumCols, i/NumCols), raw: "x"}}})
	}
	if u.depth() != undoDepth {
		t.Fatalf("depth = %d, want %d", u.depth(), undoDepth)
	}
	// The oldest five fell off: popping walks back from the newest.
	for i := undoDepth + 4; i >= 5; i-- {
		s, ok := u.pop()
		if !ok || s.cells[0].r != refAt(i%NumCols, i/NumCols) {
			t.Fatalf("pop = %v %v, want step %d", s, ok, i)
		}
	}
	if _, ok := u.pop(); ok {
		t.Fatal("ring held a 33rd step")
	}
	// An empty step never grows the ring.
	u.push(undoStep{})
	if u.depth() != 0 {
		t.Fatal("an empty step pushed")
	}
}

// Edit-undo: one commit is one step; replaying restores the prior raw.
func TestUndoRestoresEdit(t *testing.T) {
	a := newTestApp(newSheet())
	sel := refAt(0, 0)
	before := a.sheet.raw(sel)
	a.sheet.set(sel, "5")
	a.commitUndo([]cellDiff{{r: sel, raw: before}}, nil)
	if a.ring.depth() != 1 {
		t.Fatalf("depth = %d, want 1", a.ring.depth())
	}
	if !a.undo() {
		t.Fatal("undo refused a live step")
	}
	if got := a.sheet.raw(sel); got != "" {
		t.Errorf("A1 = %q after undo, want empty", got)
	}
	if a.undo() {
		t.Fatal("a second undo found a step that was not there")
	}
}

// A same-raw commit records nothing.
func TestUndoNoopCommit(t *testing.T) {
	a := newTestApp(newSheet())
	a.sheet.set(refAt(0, 0), "5")
	before := a.sheet.raw(refAt(0, 0))
	a.sheet.set(refAt(0, 0), "5")
	a.commitUndo([]cellDiff{{r: refAt(0, 0), raw: before}}, nil)
	if a.ring.depth() != 0 {
		t.Fatal("a no-op edit pushed a step")
	}
}

// The card's leg: fill a series, take it back — the seeds stay, the
// filled cells empty again.
func TestUndoRestoresFill(t *testing.T) {
	a := newTestApp(newSheet())
	a.sheet.set(refAt(0, 0), "1")
	a.sheet.set(refAt(0, 1), "2")
	selectSpan(a, refAt(0, 0), refAt(0, 9))
	a.fill(fillSeries)
	if got := a.sheet.raw(refAt(0, 9)); got != "10" {
		t.Fatalf("A10 = %q after fill, want 10", got)
	}
	if a.ring.depth() != 1 {
		t.Fatalf("fill pushed %d steps, want 1", a.ring.depth())
	}
	if !a.undo() {
		t.Fatal("undo refused the fill step")
	}
	wantRaws(t, a.sheet, map[string]string{"A1": "1", "A2": "2"})
	for r := 2; r <= 9; r++ {
		if got := a.sheet.raw(refAt(0, r)); got != "" {
			t.Errorf("A%d = %q after undo, want empty", r+1, got)
		}
	}
}

// Undo replays formats too: a percent apply is one step and reverts.
func TestUndoRestoresFormat(t *testing.T) {
	a := newTestApp(newSheet())
	selectSpan(a, refAt(1, 0), refAt(1, 0))
	a.formatCols(fmtPct)
	if a.sheet.cfmt[1] != fmtPct {
		t.Fatal("percent did not apply")
	}
	if !a.undo() {
		t.Fatal("undo refused the format step")
	}
	if a.sheet.cfmt[1] != fmtGeneral {
		t.Error("column B stayed percent after undo")
	}
	// A same-format apply records nothing.
	a.formatCols(fmtGeneral)
	if a.ring.depth() != 0 {
		t.Fatal("a no-op format pushed a step")
	}
}

// Two edits undo newest-first, each step independent.
func TestUndoOrder(t *testing.T) {
	a := newTestApp(newSheet())
	sel := refAt(0, 0)
	for _, raw := range []string{"1", "2", "3"} {
		before := a.sheet.raw(sel)
		a.sheet.set(sel, raw)
		a.commitUndo([]cellDiff{{r: sel, raw: before}}, nil)
	}
	for _, want := range []string{"2", "1", ""} {
		if !a.undo() {
			t.Fatalf("undo refused, want %q", want)
		}
		if got := a.sheet.raw(sel); got != want {
			t.Fatalf("A1 = %q after undo, want %q", got, want)
		}
	}
}

// Dependents recompute through the undo's single recalc.
func TestUndoRecalcs(t *testing.T) {
	a := newTestApp(newSheet())
	a.sheet.set(refAt(0, 0), "2")
	a.sheet.set(refAt(1, 0), "=A1*3")
	before := a.sheet.raw(refAt(0, 0))
	a.sheet.set(refAt(0, 0), "5")
	a.commitUndo([]cellDiff{{r: refAt(0, 0), raw: before}}, nil)
	if got := a.sheet.display(refAt(1, 0)); got != "15" {
		t.Fatalf("B1 = %q before undo, want 15", got)
	}
	a.undo()
	wantDisp(t, a.sheet, "B1", "6")
}
