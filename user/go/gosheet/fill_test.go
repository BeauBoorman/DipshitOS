package main

import "testing"

// shiftRaw goldens: relative axes move, anchored axes hold, a shifted-off
// ref becomes the #REF literal, and the canonical emitter only spends
// parens where precedence needs them.
func TestShiftRaw(t *testing.T) {
	cases := []struct {
		raw    string
		dc, dr int
		want   string
	}{
		{"=a1+b2", 1, 0, "=B1+C2"},
		{"=a1+b2", 0, 1, "=A2+B3"},
		{"=a1+b2", -1, -1, "=#REF+A1"},
		{"=$a$1+b$2+$c3", 1, 1, "=$A$1+C$2+$C4"},
		{"=sum[a1:b2]", 0, 1, "=SUM(A2:B3)"},
		{"=sum($a1:b$2)", 1, 1, "=SUM($A2:C$2)"},
		{"=(a1+b1)*c1", 0, 1, "=(A2+B2)*C2"},
		{"=a1+b1*c1", 0, 1, "=A2+B2*C2"},
		{"=a1-(b1-c1)", 0, 1, "=A2-(B2-C2)"},
		{"=-(a1+b1)", 0, 1, "=-(A2+B2)"},
		{"=a64", 0, 1, "=#REF"},
		{"=dx1", 1, 0, "=#REF"},
		{"=a1+#ref", 1, 0, "=B1+#REF"},
		{"=a1/0+#div/0", 0, 1, "=A2/0+#DIV/0"},
		{"hello", 1, 1, "hello"},
		{"1.50", 0, 1, "1.50"}, // literal text keeps its own spelling
		{"", 1, 1, ""},
		{"=a1+", 1, 0, "=a1+"}, // unparsable copies verbatim
		{"=$", 1, 0, "=$"},     // a '$' that is not a ref copies verbatim too
	}
	for _, c := range cases {
		if got := shiftRaw(c.raw, c.dc, c.dr); got != c.want {
			t.Errorf("shiftRaw(%q, %d, %d) = %q, want %q", c.raw, c.dc, c.dr, got, c.want)
		}
	}
}

// Anchored references parse and evaluate like bare ones — the '$' is fill
// metadata, not a different value.
func TestAbsoluteRefsEval(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "7")
	setAt(t, s, "B1", "=$A$1+A$1+$A1")
	wantDisp(t, s, "B1", "21")
	setAt(t, s, "B2", "=#REF+1")
	wantDisp(t, s, "B2", "#REF")
	// Anchor spellings that are not refs refuse by name.
	setAt(t, s, "C1", "=$A")
	setAt(t, s, "C2", "=A$")
	setAt(t, s, "C3", "=$1")
	wantDisp(t, s, "C1", "#PARSE")
	wantDisp(t, s, "C2", "#PARSE")
	wantDisp(t, s, "C3", "#PARSE")
}

func raws(t *testing.T, s *Sheet, addrs ...string) []string {
	t.Helper()
	out := make([]string, len(addrs))
	for i, a := range addrs {
		r, ok := parseRef(a)
		if !ok {
			t.Fatalf("bad test address %q", a)
		}
		out[i] = s.raw(r)
	}
	return out
}

func wantRaws(t *testing.T, s *Sheet, want map[string]string) {
	t.Helper()
	for addr, w := range want {
		r, _ := parseRef(addr)
		if got := s.raw(r); got != w {
			t.Errorf("raw(%s) = %q, want %q", addr, got, w)
		}
	}
}

// The card's leg: 1, 2 down a column fills the arithmetic series to 10.
func TestFillSeriesDown(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "1")
	setAt(t, s, "A2", "2")
	written, clipped := fillRange(s, refAt(0, 0), refAt(0, 9), fillSeries)
	if clipped != 0 || len(written) != 8 {
		t.Fatalf("fillSeries wrote %d clipped %d, want 8/0", len(written), clipped)
	}
	wantRaws(t, s, map[string]string{
		"A3": "3", "A4": "4", "A5": "5", "A6": "6", "A7": "7",
		"A8": "8", "A9": "9", "A10": "10",
	})
}

// The series reads the first two cells of EACH fill line — a horizontal
// selection continues per row.
func TestFillSeriesRight(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "10")
	setAt(t, s, "B1", "7")
	written, _ := fillRange(s, refAt(0, 0), refAt(4, 0), fillSeries)
	if len(written) != 3 {
		t.Fatalf("fillSeries right wrote %d, want 3", len(written))
	}
	wantRaws(t, s, map[string]string{"C1": "4", "D1": "1", "E1": "-2"})
}

// Seeds that evaluate to numbers through a formula count as numbers.
func TestFillSeriesFormulaSeeds(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "2")
	setAt(t, s, "A2", "=A1+2") // displays 4: the series step is 2
	if _, cl := fillRange(s, refAt(0, 0), refAt(0, 4), fillSeries); cl != 0 {
		t.Fatal("clipped on an empty sheet")
	}
	wantRaws(t, s, map[string]string{"A3": "6", "A4": "8", "A5": "10"})
}

// Without two numeric seeds the series degrades to the copy — the seed
// cell covers the rest of the line, verbatim.
func TestFillSeriesDegradesToCopy(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "1")
	setAt(t, s, "A2", "text")
	fillRange(s, refAt(0, 0), refAt(0, 4), fillSeries)
	wantRaws(t, s, map[string]string{
		"A2": "1", "A3": "1", "A4": "1", "A5": "1",
	})
}

// A 2-D block series-fills per line on the dominant axis: column A runs
// its own step, column B falls back to copy.
func TestFillSeriesBlock(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "1")
	setAt(t, s, "A2", "3")
	setAt(t, s, "B1", "x")
	setAt(t, s, "B2", "y")
	fillRange(s, refAt(0, 0), refAt(1, 4), fillSeries)
	wantRaws(t, s, map[string]string{
		"A3": "5", "A4": "7", "A5": "9",
		"B3": "x", "B4": "x", "B5": "x",
	})
}

// A wider-than-tall selection fills right instead of down: each row is
// its own line, so row 1 runs the series while row 2 — no numeric pair —
// copies its empty seed and stays empty.
func TestFillSeriesWideBlock(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "1")
	setAt(t, s, "B1", "2")
	fillRange(s, refAt(0, 0), refAt(3, 1), fillSeries)
	wantRaws(t, s, map[string]string{"C1": "3", "D1": "4"})
	if got := s.raw(refAt(2, 1)); got != "" {
		t.Errorf("C2 = %q, want empty (copied empty seed)", got)
	}
	if got := s.raw(refAt(3, 1)); got != "" {
		t.Errorf("D2 = %q, want empty (copied empty seed)", got)
	}
}

func TestFillDownCopies(t *testing.T) {
	s := newSheet()
	setAt(t, s, "B2", "hi")
	setAt(t, s, "C2", "=B2*2")
	written, _ := fillRange(s, refAt(1, 1), refAt(2, 4), fillDown)
	if len(written) != 6 {
		t.Fatalf("fillDown wrote %d cells, want 6", len(written))
	}
	wantRaws(t, s, map[string]string{
		"B3": "hi", "B4": "hi", "B5": "hi",
		"C3": "=B3*2", "C4": "=B4*2", "C5": "=B5*2",
	})
	s.recalc()
	wantDisp(t, s, "C3", "0") // B3 is text: coerces to 0, so 0*2
}

func TestFillRightCopies(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "=$A$1+B1")
	written, _ := fillRange(s, refAt(0, 0), refAt(2, 0), fillRight)
	if len(written) != 2 {
		t.Fatalf("fillRight wrote %d, want 2", len(written))
	}
	wantRaws(t, s, map[string]string{
		"B1": "=$A$1+C1",
		"C1": "=$A$1+D1",
	})
}

// A shifted-off reference fills as the #REF error, not a dead address.
func TestFillRefOffGrid(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A63", "1")
	setAt(t, s, "B1", "=A64")
	fillRange(s, refAt(1, 0), refAt(1, 2), fillDown)
	wantRaws(t, s, map[string]string{"B2": "=#REF", "B3": "=#REF"})
	s.recalc()
	wantDisp(t, s, "B2", "#REF")
}

// The selection is the bound: a one-cell fill writes nothing.
func TestFillSingleCell(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "1")
	for _, k := range []fillKind{fillDown, fillRight, fillSeries} {
		if w, cl := fillRange(s, refAt(0, 0), refAt(0, 0), k); len(w) != 0 || cl != 0 {
			t.Errorf("fill %v on one cell wrote %d clipped %d", k, len(w), cl)
		}
	}
}

// Writes that hit the store cap count clipped — the fill never
// half-writes past it. The seeded store covers rows 0..15, so a fill
// down column A into row 17+ is the refused write.
func TestFillClippedAtCap(t *testing.T) {
	s := newSheet()
	for s.filled() < MaxCells {
		if !s.setQuiet(refAt(s.filled()%NumCols, s.filled()/NumCols), "1") {
			t.Fatal("cap seeding refused early")
		}
	}
	w, cl := fillRange(s, refAt(0, 15), refAt(0, 17), fillDown)
	if len(w) != 0 || cl != 2 {
		t.Errorf("fill at cap wrote %d clipped %d, want 0/2", len(w), cl)
	}
}
