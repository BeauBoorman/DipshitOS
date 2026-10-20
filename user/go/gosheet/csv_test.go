package main

import (
	"testing"

	"virelai/widgets"
)

// fields is the test shorthand for one CSV row.
func fields(s ...string) []string { return s }

func eqRows(t *testing.T, got, want [][]string, what string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("%s: rows=%d, want %d (%v)", what, len(got), len(want), got)
	}
	for i := range want {
		if len(got[i]) != len(want[i]) {
			t.Fatalf("%s row %d: cols=%d, want %d (%v)", what, i, len(got[i]), len(want[i]), got[i])
		}
		for j := range want[i] {
			if got[i][j] != want[i][j] {
				t.Fatalf("%s row %d col %d: %q, want %q", what, i, j, got[i][j], want[i][j])
			}
		}
	}
}

// The card's acceptance leg: quoted fields, embedded commas and embedded
// newlines survive a write->parse round trip.
func TestCSVRoundTripVectors(t *testing.T) {
	cases := []struct {
		name string
		rows [][]string
	}{
		{"plain", [][]string{fields("1", "2"), fields("3", "4")}},
		{"comma", [][]string{fields("a,b", "c"), fields("d", "e,f,g")}},
		{"newline", [][]string{fields("x\ny", "2"), fields("3", "p\r\nq")}},
		{"quote", [][]string{fields(`say "hi"`, `""`), fields(`a"b`, "")}},
		{"mixed", [][]string{fields("7", "e,f"), fields("\"q\nu\"", "9")}},
		{"empty-fields", [][]string{fields("", "", "x"), fields("y", "")}},
		{"single", [][]string{fields("only")}},
	}
	for _, tc := range cases {
		got := parseCSV(writeCSV(tc.rows))
		eqRows(t, got, tc.rows, tc.name)
	}
}

// The writer only quotes when the field body needs it, doubles embedded
// quotes, and terminates each record with CRLF.
func TestCSVWriteSpellings(t *testing.T) {
	got := string(writeCSV([][]string{
		fields("7", "e,f", `say "hi"`),
		fields("1\n2", "", "z"),
	}))
	want := "7,\"e,f\",\"say \"\"hi\"\"\"\r\n\"1\n2\",,z\r\n"
	if got != want {
		t.Fatalf("writeCSV = %q, want %q", got, want)
	}
}

// Tolerant reads: CRLF/LF/CR all split records; a quote followed by non-
// delimiter text is literal; an unclosed quote runs to end of record; a
// mid-field quote is literal text.
func TestCSVParseSpellings(t *testing.T) {
	eqRows(t, parseCSV([]byte("a,b\nc,d")), [][]string{fields("a", "b"), fields("c", "d")}, "LF")
	eqRows(t, parseCSV([]byte("a,b\rc,d")), [][]string{fields("a", "b"), fields("c", "d")}, "CR")
	eqRows(t, parseCSV([]byte("a,b\r\nc,d\r\n")), [][]string{fields("a", "b"), fields("c", "d")}, "CRLF")
	eqRows(t, parseCSV([]byte(`"unclosed`)), [][]string{fields("unclosed")}, "unclosed-quote")
	eqRows(t, parseCSV([]byte(`a"b,c`)), [][]string{fields(`a"b`, "c")}, "mid-field-quote")
	eqRows(t, parseCSV([]byte(`"a"x,b`)), [][]string{fields("ax", "b")}, "quote-then-text")
	eqRows(t, parseCSV([]byte("")), [][]string{fields("")}, "empty")
	eqRows(t, parseCSV([]byte("a,")), [][]string{fields("a", "")}, "trailing-comma")
}

// Formula cells export the evaluated display, not the '=…' raw text.
func TestCSVRangeExportsValues(t *testing.T) {
	s := newSheet()
	setAt(t, s, "A1", "2")
	setAt(t, s, "A2", "3")
	setAt(t, s, "B1", "=SUM(A1:A2)")
	setAt(t, s, "C1", "x,y")
	lo, _ := parseRef("A1")
	hi, _ := parseRef("C2")
	got := string(writeCSV(s.csvRows(lo, hi)))
	// Row 1: 2,5,"x,y"; row 2: 3,,(C2 empty).
	want := "2,5,\"x,y\"\r\n3,,\r\n"
	if got != want {
		t.Fatalf("export = %q, want %q", got, want)
	}
	// And the export re-imports as literals — the values travel.
	s2 := newSheet()
	for r, row := range parseCSV(writeCSV(s.csvRows(lo, hi))) {
		for c, f := range row {
			s2.setQuiet(refAt(lo.col+c, lo.row+r), f)
		}
	}
	s2.recalc()
	wantDisp(t, s2, "B1", "5")
	wantDisp(t, s2, "C1", "x,y")
}

// usedBBox frames the filled cells, nothing more.
func TestUsedBBox(t *testing.T) {
	s := newSheet()
	if _, _, ok := s.usedBBox(); ok {
		t.Fatal("empty sheet has no bbox")
	}
	setAt(t, s, "B2", "1")
	setAt(t, s, "D5", "2")
	lo, hi, ok := s.usedBBox()
	if !ok || lo.String() != "B2" || hi.String() != "D5" {
		t.Fatalf("bbox = %v:%v ok=%v, want B2:D5", lo, hi, ok)
	}
}

// --- state blob ----------------------------------------------------------

// The card's state leg: sheet + cursor + scroll survive an encode/decode
// round trip, formulas keep their raw text.
func TestStateRoundTrip(t *testing.T) {
	a := &app{sheet: newSheet()}
	setAt(t, a.sheet, "A1", "5")
	setAt(t, a.sheet, "B1", "=A1*2")
	setAt(t, a.sheet, "DX64", "edge")
	a.table = &widgets.Table{Col: 127, Row: 63, ScrollTop: 40, ScrollX: 8128}
	b := a.encodeState()
	if b == nil || len(b) == 0 {
		t.Fatal("encodeState returned nothing")
	}
	st, ok := decodeState(b)
	if !ok {
		t.Fatal("decodeState refused a freshly encoded blob")
	}
	if st.cur.col != 127 || st.cur.row != 63 || st.top != 40 || st.sx != 8128 {
		t.Fatalf("view = %v top=%d sx=%d, want DX64 40 8128", st.cur, st.top, st.sx)
	}
	if len(st.raws) != 3 || st.raws[refAt(1, 0)] != "=A1*2" || st.raws[refAt(127, 63)] != "edge" {
		t.Fatalf("raws = %v", st.raws)
	}
}

// Malformed blobs refuse wholesale: bad version, short, trailing bytes,
// duplicate cells, out-of-bounds addresses, over-cap cell count.
func TestStateDecodeRefusals(t *testing.T) {
	a := &app{sheet: newSheet()}
	setAt(t, a.sheet, "A1", "1")
	a.table = &widgets.Table{}
	good := a.encodeState()

	if _, ok := decodeState(nil); ok {
		t.Error("nil blob decoded")
	}
	if _, ok := decodeState([]byte{0, 0, 0, 0, 0, 0, 0, 0, 0}); ok {
		t.Error("wrong-version blob decoded")
	}
	if _, ok := decodeState(good[:len(good)-1]); ok {
		t.Error("truncated blob decoded")
	}
	if _, ok := decodeState(append(append([]byte{}, good...), 0)); ok {
		t.Error("trailing-bytes blob decoded")
	}
	// Duplicate cell: patch the blob to carry A1 twice — refused.
	dup := make([]byte, 0, len(good)*2)
	dup = append(dup, good[:7]...)
	dup = putU16(dup, 2)
	dup = append(dup, good[9:]...)
	dup = append(dup, good[9:]...)
	if _, ok := decodeState(dup); ok {
		t.Error("duplicate-cell blob decoded")
	}
	// Out-of-bounds address: col 200 is outside 0..127.
	oob := []byte{stateFmtVer, 0, 0, 0, 0, 0, 0, 1, 0, 200, 0, 1, 0, 'x'}
	if _, ok := decodeState(oob); ok {
		t.Error("out-of-bounds cell decoded")
	}
}
