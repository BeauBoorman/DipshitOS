package main

import "testing"

// The format vocabulary: numbers render per format; text, empty and
// error cells ignore it.
func TestDisplayFmt(t *testing.T) {
	cases := []struct {
		v    value
		f    colFmt
		want string
	}{
		{numVal(0.5), fmtGeneral, "0.5"},
		{numVal(0.5), fmtPct, "50%"},
		{numVal(0.42), fmtPct, "42%"},
		{numVal(-0.25), fmtPct, "-25%"},
		{numVal(42.567), fmtFixed2, "42.57"},
		{numVal(0.5), fmtFixed2, "0.50"},
		{numVal(2), fmtFixed2, "2.00"},
		{numVal(2.5), fmtInt, "2"},  // FormatFloat 'f' rounds half-even
		{numVal(3.5), fmtInt, "4"},
		{numVal(-2.7), fmtInt, "-3"},
		{textVal("hi"), fmtPct, "hi"},
		{errVal(errRef), fmtPct, "#REF"},
		{emptyVal(), fmtPct, ""},
		{numVal(7), fmtGeneral, "7"},
	}
	for _, c := range cases {
		if got := displayFmt(c.v, c.f); got != c.want {
			t.Errorf("displayFmt(%v, %d) = %q, want %q", c.v, c.f, got, c.want)
		}
	}
}

// show() is the column-formatted face of a cell; display() stays raw.
func TestSheetShow(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "0.5")
	setAt(t, s, "B1", "=A1")
	s.cfmt[0] = fmtPct
	s.cfmt[1] = fmtFixed2
	if got := s.show(refAt(0, 0)); got != "50%" {
		t.Errorf("show(A1) = %q, want 50%%", got)
	}
	if got := s.show(refAt(1, 0)); got != "0.50" {
		t.Errorf("show(B1) = %q, want 0.50", got)
	}
	if got := s.display(refAt(0, 0)); got != "0.5" {
		t.Errorf("display(A1) = %q, want 0.5 (raw)", got)
	}
	// An empty cell shows empty under any format.
	if got := s.show(refAt(2, 0)); got != "" {
		t.Errorf("show(C1) = %q, want empty", got)
	}
}

// The card's precision rule: CSV export writes raw values, so a
// percent-formatted column round-trips without loss.
func TestCSVExportRawNotFormatted(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "0.5")
	s.cfmt[0] = fmtPct
	rows := s.csvRows(refAt(0, 0), refAt(0, 0))
	if len(rows) != 1 || len(rows[0]) != 1 || rows[0][0] != "0.5" {
		t.Fatalf("csvRows = %v, want [[0.5]]", rows)
	}
}

// fmtCount backs the restored marker's fmts= field.
func TestFmtCount(t *testing.T) {
	s := newSheet()
	if s.fmtCount() != 0 {
		t.Fatal("fresh sheet counts formats")
	}
	s.cfmt[3] = fmtInt
	s.cfmt[7] = fmtPct
	if s.fmtCount() != 2 {
		t.Fatalf("fmtCount = %d, want 2", s.fmtCount())
	}
}
