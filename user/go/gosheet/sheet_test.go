package main

import "testing"

// setAt is the test shorthand for one commit.
func setAt(t *testing.T, s *Sheet, addr, raw string) {
	t.Helper()
	r, ok := parseRef(addr)
	if !ok {
		t.Fatalf("bad test address %q", addr)
	}
	if _, ok := s.set(r, raw); !ok {
		t.Fatalf("set(%q, %q) refused", addr, raw)
	}
}

func disp(t *testing.T, s *Sheet, addr string) string {
	t.Helper()
	r, _ := parseRef(addr)
	return s.display(r)
}

func wantDisp(t *testing.T, s *Sheet, addr, want string) {
	t.Helper()
	if got := disp(t, s, addr); got != want {
		t.Errorf("display(%s) = %q, want %q", addr, got, want)
	}
}

// The card's core leg: values plus a SUM, an edited input, and a
// recalculated dependent.
func TestRecalcOnEdit(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "2")
	setAt(t, s, "A2", "3")
	setAt(t, s, "B1", "=SUM(A1:A2)")
	wantDisp(t, s, "A1", "2")
	wantDisp(t, s, "A2", "3")
	wantDisp(t, s, "B1", "5")
	setAt(t, s, "A1", "10")
	wantDisp(t, s, "B1", "13")
	// Removing the input recalculates through the range (A1 empty = skipped).
	setAt(t, s, "A1", "")
	wantDisp(t, s, "B1", "3")
	if s.filled() != 2 {
		t.Errorf("filled() = %d, want 2", s.filled())
	}
}

// A change ripples through a chain of dependents.
func TestRecalcChain(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "4")
	setAt(t, s, "B1", "=A1*2")
	setAt(t, s, "C1", "=B1+1")
	wantDisp(t, s, "C1", "9")
	setAt(t, s, "A1", "0")
	wantDisp(t, s, "B1", "0")
	wantDisp(t, s, "C1", "1")
}

func TestArithmetic(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "8")
	setAt(t, s, "A2", "2")
	setAt(t, s, "B1", "=A1+A2*3") // precedence
	setAt(t, s, "B2", "=(A1+A2)*3")
	setAt(t, s, "B3", "=A1/A2")
	setAt(t, s, "B4", "=-A1")
	setAt(t, s, "B5", "=10/4")
	wantDisp(t, s, "B1", "14")
	wantDisp(t, s, "B2", "30")
	wantDisp(t, s, "B3", "4")
	wantDisp(t, s, "B4", "-8")
	wantDisp(t, s, "B5", "2.5")
}

func TestFunctions(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "1")
	setAt(t, s, "A2", "2")
	setAt(t, s, "A3", "3")
	setAt(t, s, "A4", "skip me") // text: ignored by the aggregates
	// A5 stays empty: ignored by the aggregates.
	setAt(t, s, "B1", "=SUM(A1:A5)")
	setAt(t, s, "B2", "=AVG(A1:A5)")
	setAt(t, s, "B3", "=MIN(A1:A5)")
	setAt(t, s, "B4", "=MAX(A1:A5)")
	setAt(t, s, "B5", "=COUNT(A1:A5)")
	setAt(t, s, "B6", "=ABS(-7)")
	setAt(t, s, "B7", "=ROUND(2.567,2)")
	setAt(t, s, "B8", "=ROUND(2.5)")  // half away from zero
	setAt(t, s, "B9", "=ROUND(-2.5)") // half away from zero
	setAt(t, s, "C1", "=SUM(A1:A3,10)")
	wantDisp(t, s, "B1", "6")
	wantDisp(t, s, "B2", "2")
	wantDisp(t, s, "B3", "1")
	wantDisp(t, s, "B4", "3")
	wantDisp(t, s, "B5", "3")
	wantDisp(t, s, "B6", "7")
	wantDisp(t, s, "B7", "2.57")
	wantDisp(t, s, "B8", "3")
	wantDisp(t, s, "B9", "-3")
	wantDisp(t, s, "C1", "16")
	// Reversed endpoints read the same cells.
	setAt(t, s, "C2", "=SUM(A3:A1)")
	wantDisp(t, s, "C2", "6")
}

// AVG with no numeric inputs is the division-by-zero case of the family.
func TestAvgEmpty(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "not a number")
	setAt(t, s, "B1", "=AVG(A1:A3)")
	wantDisp(t, s, "B1", "#DIV/0")
	// MIN/MAX over an empty range answer 0 rather than an error.
	setAt(t, s, "B2", "=MIN(A2:A3)")
	wantDisp(t, s, "B2", "0")
}

func TestErrors(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "=1/0")
	setAt(t, s, "A2", "=B9/0") // a ref's 0 is still 0
	setAt(t, s, "B1", "=ZZ1")  // column outside DX
	setAt(t, s, "B2", "=A65")  // row outside 64
	setAt(t, s, "B3", "=A0")
	setAt(t, s, "C1", "=foo")   // unknown function/bare name
	setAt(t, s, "C2", "=1+")    // truncated expression
	setAt(t, s, "C3", "=A1:B2") // a range is not a cell value
	wantDisp(t, s, "A1", "#DIV/0")
	wantDisp(t, s, "A2", "#DIV/0")
	wantDisp(t, s, "B1", "#REF")
	wantDisp(t, s, "B2", "#REF")
	wantDisp(t, s, "B3", "#REF")
	wantDisp(t, s, "C1", "#PARSE")
	wantDisp(t, s, "C2", "#PARSE")
	wantDisp(t, s, "C3", "#PARSE")
}

// Errors are values: a formula over an error cell shows that error.
func TestErrorPropagation(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "=1/0")
	setAt(t, s, "B1", "=A1+1")
	setAt(t, s, "C1", "=SUM(A1:B1)")
	wantDisp(t, s, "B1", "#DIV/0")
	wantDisp(t, s, "C1", "#DIV/0")
}

// A text cell passes its text through a bare reference and coerces to 0
// in arithmetic.
func TestText(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "hi")
	setAt(t, s, "B1", "=A1")
	setAt(t, s, "C1", "=A1+1")
	wantDisp(t, s, "B1", "hi")
	wantDisp(t, s, "C1", "1")
}

func TestCycles(t *testing.T) {
	s := newSheet()
	// A1 waits on B1 while B1 is empty: a ref to nothing is 0, not a cycle.
	setAt(t, s, "A1", "=B1")
	wantDisp(t, s, "A1", "0")
	// Closing the loop: both cells on the cycle show #CYCLE.
	setAt(t, s, "B1", "=A1")
	wantDisp(t, s, "A1", "#CYCLE")
	wantDisp(t, s, "B1", "#CYCLE")
	// A dependent of the cycle shows the propagated error.
	setAt(t, s, "C1", "=A1+1")
	wantDisp(t, s, "C1", "#CYCLE")
	// cycleRefs names exactly the members.
	cyc := s.cycleRefs()
	if len(cyc) != 2 || cyc[0] != (cellRef{0, 0}) || cyc[1] != (cellRef{1, 0}) {
		t.Errorf("cycleRefs = %v, want [A1 B1]", cyc)
	}
	// Breaking the cycle recovers both cells on the next commit.
	setAt(t, s, "B1", "7")
	wantDisp(t, s, "A1", "7")
	wantDisp(t, s, "C1", "8")
	if n := len(s.cycleRefs()); n != 0 {
		t.Errorf("cycleRefs after break = %d, want 0", n)
	}
}

func TestSelfCycle(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "=A1")
	wantDisp(t, s, "A1", "#CYCLE")
}

// A cycle through a range: B1 aggregates a range containing A1, A1 reads
// B1 — the walk must still refuse by name instead of recursing.
func TestRangeCycle(t *testing.T) {
	s := newSheet()
	setAt(t, s, "B1", "=SUM(A1:A2)")
	setAt(t, s, "A1", "=B1")
	wantDisp(t, s, "A1", "#CYCLE")
	wantDisp(t, s, "B1", "#CYCLE")
	setAt(t, s, "A2", "5")
	wantDisp(t, s, "A2", "5") // A2 is on no cycle
}

// The store cap: at most MaxCells filled cells. The row-major fill covers
// rows 0..15 (2048 = 128*16), so DX64 is the never-touched address that
// must be refused; editing an existing cell and clearing are never refused.
func TestCellCap(t *testing.T) {
	s := newSheet()
	for row := 0; row < NumRows; row++ {
		for col := 0; col < NumCols; col++ {
			if s.filled() >= MaxCells {
				break
			}
			if _, ok := s.set(refAt(col, row), "1"); !ok {
				t.Fatalf("set(%s) refused before the cap", refAt(col, row))
			}
		}
	}
	if s.filled() != MaxCells {
		t.Fatalf("filled() = %d, want %d", s.filled(), MaxCells)
	}
	if _, ok := s.set(refAt(NumCols-1, NumRows-1), "2"); ok {
		t.Fatal("the 2049th distinct cell was accepted")
	}
	if s.filled() != MaxCells {
		t.Fatalf("a refused set still grew the store: %d", s.filled())
	}
	if _, ok := s.set(refAt(0, 0), "9"); !ok {
		t.Fatal("editing an existing cell at the cap was refused")
	}
	if _, ok := s.set(refAt(0, 0), ""); !ok {
		t.Fatal("clearing a cell at the cap was refused")
	}
	if _, ok := s.set(refAt(NumCols-1, NumRows-1), "2"); !ok {
		t.Fatal("refilling after a clear was refused")
	}
}

func TestOutOfBoundsSet(t *testing.T) {
	s := newSheet()
	if _, ok := s.set(cellRef{col: 200, row: 0}, "1"); ok {
		t.Error("set outside the grid accepted")
	}
	if _, ok := s.set(cellRef{col: 0, row: 99}, "1"); ok {
		t.Error("set outside the grid accepted")
	}
}

// The changed-ref contract: set reports every other cell that repainted.
func TestChangedList(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "1")
	setAt(t, s, "B1", "=A1")
	setAt(t, s, "C1", "=B1")
	changed, _ := s.set(cellRef{0, 0}, "5")
	// B1 and C1 changed; A1 is reported too (the edited cell).
	if len(changed) != 3 {
		t.Fatalf("changed = %v, want 3 refs", changed)
	}
	if changed[0] != (cellRef{0, 0}) || changed[1] != (cellRef{1, 0}) || changed[2] != (cellRef{2, 0}) {
		t.Errorf("changed = %v, want [A1 B1 C1] row-major", changed)
	}
	// A no-op commit changes nothing.
	changed, _ = s.set(cellRef{0, 0}, "5")
	if len(changed) != 0 {
		t.Errorf("re-set changed = %v, want none", changed)
	}
}

// The gate's own spelling: lowercase + bracket parens.
func TestGateSpellings(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "2")
	setAt(t, s, "A2", "3")
	setAt(t, s, "B1", "=sum[a1:a2]")
	wantDisp(t, s, "B1", "5")
	setAt(t, s, "B2", "=[a1+a2]*2")
	wantDisp(t, s, "B2", "10")
}
