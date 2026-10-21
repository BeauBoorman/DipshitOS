package main

import "testing"

// A v1 blob — the M142b layout, no trailer — still decodes; every column
// comes out general.
func TestStateV1Decodes(t *testing.T) {
	blob := []byte{
		1,    // ver
		2, 3, // cursor col, row
		5, 0, // scrollTop (little-endian)
		7, 0, // scrollX
		1, 0, // ncells
		1, 4, 3, 0, '4', '2', 'x', // cell B5 = "42x"
	}
	st, ok := decodeState(blob)
	if !ok {
		t.Fatal("v1 blob refused")
	}
	if st.cur != refAt(2, 3) || st.top != 5 || st.sx != 7 {
		t.Errorf("view = %v %d %d, want C4/5/7", st.cur, st.top, st.sx)
	}
	if st.raws[refAt(1, 4)] != "42x" {
		t.Errorf("B5 = %q, want 42x", st.raws[refAt(1, 4)])
	}
	for c, f := range st.fmts {
		if f != fmtGeneral {
			t.Errorf("col %d fmt = %d, want general from a v1 blob", c, f)
		}
	}
}

// v2 round-trips cells, view and formats through encode/decode.
func TestStateV2RoundTrip(t *testing.T) {
	a := newTestApp(newSheet())
	a.sheet.set(refAt(0, 0), "1")
	a.sheet.set(refAt(0, 1), "2")
	a.sheet.set(refAt(1, 0), "=A1+A2")
	a.sheet.cfmt[1] = fmtPct
	a.sheet.cfmt[3] = fmtInt
	a.table.Col, a.table.Row = 1, 0
	a.table.ScrollTop, a.table.ScrollX = 4, 12
	blob := a.encodeState()
	if blob == nil || blob[0] != stateFmtVer {
		t.Fatal("encode did not produce a v2 blob")
	}
	st, ok := decodeState(blob)
	if !ok {
		t.Fatal("v2 blob refused")
	}
	if st.cur != refAt(1, 0) || st.top != 4 || st.sx != 12 {
		t.Errorf("view = %v %d %d", st.cur, st.top, st.sx)
	}
	if st.raws[refAt(1, 0)] != "=A1+A2" {
		t.Errorf("B1 raw = %q", st.raws[refAt(1, 0)])
	}
	if st.fmts[1] != fmtPct || st.fmts[3] != fmtInt || st.fmts[0] != fmtGeneral {
		t.Errorf("fmts = %v, want B=percent D=integer", st.fmts[:4])
	}
	// A v2 blob applied restores the formats.
	b := newTestApp(newSheet())
	b.noteState(blob)
	b.applyRestored()
	if b.sheet.cfmt[1] != fmtPct {
		t.Error("restore lost the percent column")
	}
	if got := b.sheet.show(refAt(1, 0)); got != "300%" {
		t.Errorf("restored B1 shows %q, want 300%%", got)
	}
}

// The v2 trailer refuses the same way the v1 body does: short, trailing,
// duplicated, out-of-grid or unknown.
func TestStateV2Refusals(t *testing.T) {
	base := []byte{
		2,    // ver
		0, 0, // cursor
		0, 0, 0, 0, // scroll
		0, 0, // ncells
	}
	good := append(append([]byte{}, base...), 1, 5, 3) // one fmt: F=percent
	if _, ok := decodeState(good); !ok {
		t.Fatal("a minimal v2 blob refused")
	}
	bad := [][]byte{
		append(append([]byte{}, base...), 1, 5),          // truncated entry
		append(append([]byte{}, base...), 1, 5, 3, 9),    // trailing byte
		append(append([]byte{}, base...), 1, 5, 4),       // unknown fmt code
		append(append([]byte{}, base...), 1, 200, 1),     // col off the grid
		append(append([]byte{}, base...), 2, 5, 3, 5, 1), // duplicated col
		{3, 0, 0, 0, 0, 0, 0, 0, 0},                      // ver 3 unknown
	}
	for i, b := range bad {
		if _, ok := decodeState(b); ok {
			t.Errorf("bad blob %d decoded", i)
		}
	}
	// And a v1 blob carrying a stray trailer is refused too.
	v1trail := []byte{1, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	if _, ok := decodeState(v1trail); ok {
		t.Error("v1 blob with a trailer decoded")
	}
}
