package main

import (
	"testing"

	"virelai/tabapp"
	"virelai/vi"
)

// heat_test.go pins M166c (#2991): the .folded parser (escaped and hex
// frames, the malformed-line refusal), closure folding, the declaration
// scanner's method/function naming including same-named methods on two
// receivers, the other-package no-map rule, the four bucket thresholds,
// the too-large refusal, and the gutter's painted strip.

// installHeatRead swaps the profile-read seam for the test — the same
// pattern installClip uses for the clipboard slots.
func installHeatRead(t *testing.T, b []byte, rc int64) {
	t.Helper()
	prev := heatRead
	heatRead = func(string) ([]byte, int64) { return b, rc }
	t.Cleanup(func() { heatRead = prev })
}

// heatBuf is the mapping drill's document:
//
//	package main            line 1
//	                        line 2
//	func f() {              line 3
//		x := 1              line 4
//	}                       line 5
//	                        line 6
//	func (t *T) hot() {     line 7
//	}                       line 8
//	func (t T) cold() {     line 9
//	}                       line 10
//
// and a same-named method on a second receiver:
//
//	func (u *U) hot() {     line 11
//	}                       line 12
const heatBuf = "package main\n\nfunc f() {\n\tx := 1\n}\n\n" +
	"func (t *T) hot() {\n}\nfunc (t T) cold() {\n}\nfunc (u *U) hot() {\n}\n"

// heatData is the parse outcome the drills share.
func parseOrDie(t *testing.T, text string) *heatData {
	t.Helper()
	h, bad := parseFolded([]byte(text))
	if h == nil {
		t.Fatalf("parseFolded refused line %d of %q", bad, text)
	}
	return h
}

// TestFoldedParser: the WriteFolded shape — leaf frames carry the self
// samples, deeper stacks share a leaf's count, an escaped frame (the
// symbolizer rewrites ';', space and CR/LF to '_') is just a name, a hex
// leaf is unmapped, and the malformed lines refuse with their number.
func TestFoldedParser(t *testing.T) {
	h := parseOrDie(t, "main.main;main.f 60\n"+
		"main.init;main.main;main.f 15\n"+ // same leaf, deeper stack
		"main.main;main.g 8\n"+
		"main.main;0x100042f8c 12\n"+ // unresolved PC
		"main.main;main.f_x 5\n") // an escaped frame is a plain name
	if h.samples != 100 {
		t.Fatalf("samples = %d want 100", h.samples)
	}
	if got := h.fns["main.f"]; got != 75 {
		t.Fatalf("main.f self = %d want 75 (both stacks' leaves)", got)
	}
	if len(h.fns) != 3 {
		t.Fatalf("fns = %d want 3 (f, g, f_x — the hex leaf maps nothing)", len(h.fns))
	}
	if h.top != "main.f" || h.topN != 75 {
		t.Fatalf("top = %q/%d want main.f/75", h.top, h.topN)
	}

	// The refusals: no count, a non-numeric count, an empty stack.
	for ln, text := range []string{
		"main.f\n",            // no count field at all
		"main.f x\n",          // non-numeric count
		"main.f 1\n 5\n",      // empty stack on line 2
		"main.f 1\nmain.g;\n", // trailing ';' empties the leaf
	} {
		if h, bad := parseFolded([]byte(text)); h != nil {
			t.Fatalf("case %d %q parsed, want refused", ln, text)
		} else if want := 2; ln >= 2 && bad != want {
			t.Fatalf("case %d bad line = %d want %d", ln, bad, want)
		}
	}
	// A blank line is the file's trailing newline, not malformed.
	if _, bad := parseFolded([]byte("main.f 1\n\n")); bad != 0 {
		t.Fatalf("trailing blank line refused at %d", bad)
	}
}

// TestClosureFolding: the `funcN` suffix rules — a closure folds to its
// enclosing function, nested suffixes too, a package-level funcN keeps
// its name, and a `.func` that is not digits-then-end is an identifier.
func TestClosureFolding(t *testing.T) {
	cases := []struct{ in, want string }{
		{"main.main.func1", "main.main"},
		{"main.f.func1", "main.f"},
		{"main.f.func1.2", "main.f"},
		{"main.(*T).m.func1", "main.(*T).m"},
		{"main.func1", "main.func1"}, // a real top-level func named func1
		{"main.f.funcabc", "main.f.funcabc"},
		{"main.f.func1x", "main.f.func1x"},
		{"main.f", "main.f"},
		{"runtime.goexit", "runtime.goexit"},
	}
	for _, c := range cases {
		if got := heatParent(c.in); got != c.want {
			t.Fatalf("heatParent(%q) = %q want %q", c.in, got, c.want)
		}
	}
	// And through the parser: the closure's count lands on the parent.
	h := parseOrDie(t, "main.main;main.f.func1 20\nmain.main;main.f 60\n")
	if got := h.fns["main.f"]; got != 80 {
		t.Fatalf("main.f after closure fold = %d want 80", got)
	}
	if _, ok := h.fns["main.f.func1"]; ok {
		t.Fatal("the closure name must not survive the fold")
	}
}

// TestHeatBucketThresholds pins the four-bucket cut points.
func TestHeatBucketThresholds(t *testing.T) {
	cases := []struct {
		self, total uint64
		want        int
	}{
		{80, 100, 3}, {50, 100, 3}, {49, 100, 2},
		{25, 100, 2}, {24, 100, 1}, {5, 100, 1}, {4, 100, 0},
		{1, 100, 0}, {0, 0, 0},
	}
	for _, c := range cases {
		if got := heatBucket(c.self, c.total); got != c.want {
			t.Fatalf("heatBucket(%d,%d) = %d want %d", c.self, c.total, got, c.want)
		}
	}
}

// TestScanGoDecls: functions and methods name the way the symbolizer
// does — `pkg.f`, `pkg.T.m`, `pkg.(*T).m` — and each span runs the decl
// line through the close-brace's line.
func TestScanGoDecls(t *testing.T) {
	cls := classifyGo([]byte(heatBuf))
	decls := scanGoDecls([]byte(heatBuf), cls)
	want := []struct {
		name   string
		lo, hi int // 1-based lines for readability of the pin
	}{
		{"main.f", 3, 5},
		{"main.(*T).hot", 7, 8},
		{"main.T.cold", 9, 10},
		{"main.(*U).hot", 11, 12},
	}
	if len(decls) != len(want) {
		t.Fatalf("decls = %+v want %d entries", decls, len(want))
	}
	for i, w := range want {
		if decls[i].name != w.name {
			t.Fatalf("decl %d name = %q want %q", i, decls[i].name, w.name)
		}
		l, _ := caretLineCol([]byte(heatBuf), decls[i].lo)
		hc, _ := caretLineCol([]byte(heatBuf), decls[i].hi)
		if l != w.lo || hc != w.hi {
			t.Fatalf("decl %d %q span lines = %d..%d want %d..%d",
				i, decls[i].name, l, hc, w.lo, w.hi)
		}
	}
}

// TestScanGoDeclsShapes: the scanner's refusal and edge shapes — a brace
// inside a string or comment is not a block, a func literal and a
// struct-field func type are not decls, a struct/interface result literal
// is not the body, and a bodiless decl maps nothing.
func TestScanGoDeclsShapes(t *testing.T) {
	src := "package main\n" +
		"var s = \"func fake() {\"\n" + // braces in a string: nothing
		"// func c() { commented }\n" +
		"var g = func() int {\n\treturn 1\n}\n" + // a top-level literal
		"type W struct{ run func() int }\n" + // a func type field
		"func real() struct{ x int } {\n\treturn struct{ x int }{}\n}\n" +
		"func stub()\n" + // no body — an assembly stub
		"func last() {\n}\n"
	cls := classifyGo([]byte(src))
	decls := scanGoDecls([]byte(src), cls)
	var names []string
	for _, d := range decls {
		names = append(names, d.name)
	}
	if len(names) != 2 || names[0] != "main.real" || names[1] != "main.last" {
		t.Fatalf("decls = %v want [main.real main.last]", names)
	}
	// `real`'s span runs its decl line through the final close brace —
	// the struct literal's braces did not end it early.
	lo, _ := caretLineCol([]byte(src), decls[0].lo)
	hi, _ := caretLineCol([]byte(src), decls[0].hi)
	if lo != 8 || hi != 10 {
		t.Fatalf("main.real span lines = %d..%d want 8..10", lo, hi)
	}
}

// TestMapHeatCounts: the profile lands on the buffer's decls — same-named
// methods on two receivers stay distinct, a hex leaf counts as unmapped
// samples, and a buffer from another package maps nothing.
func TestMapHeatCounts(t *testing.T) {
	h := parseOrDie(t, "main.main;main.f 60\n"+
		"main.main;main.f.func1 20\n"+
		"main.init;main.(*T).hot 8\n"+
		"main.main;main.(*U).hot 4\n"+
		"main.main;0x100042f8c 8\n")
	if h.samples != 100 {
		t.Fatalf("samples = %d want 100", h.samples)
	}
	spans, mapped := mapHeat([]byte(heatBuf), "buf.go", h)
	if mapped != 3 {
		t.Fatalf("mapped = %d want 3 (f, (*T).hot, (*U).hot)", mapped)
	}
	if len(spans) != 3 {
		t.Fatalf("spans = %+v want 3", spans)
	}
	// Buckets: f 80% -> 3, (*T).hot 8% -> 1, (*U).hot 4% -> 0.
	want := map[string]int{"main.f": 3, "main.(*T).hot": 1, "main.(*U).hot": 0}
	for i, s := range spans {
		l, _ := caretLineCol([]byte(heatBuf), s.lo)
		switch l {
		case 3:
			if s.bucket != want["main.f"] {
				t.Fatalf("f bucket = %d want %d", s.bucket, want["main.f"])
			}
		case 7:
			if s.bucket != want["main.(*T).hot"] {
				t.Fatalf("(*T).hot bucket = %d want %d", s.bucket, want["main.(*T).hot"])
			}
		case 11:
			if s.bucket != want["main.(*U).hot"] {
				t.Fatalf("(*U).hot bucket = %d want %d", s.bucket, want["main.(*U).hot"])
			}
		default:
			t.Fatalf("span %d starts on unexpected line %d", i, l)
		}
	}
	// Another package's buffer: the names exist but nothing maps.
	other := []byte("package other\nfunc f() {\n}\n")
	if spans, mapped = mapHeat(other, "o.go", h); mapped != 0 || len(spans) != 0 {
		t.Fatalf("other package mapped = %d spans=%v want 0", mapped, spans)
	}
	// A non-.go buffer and a nil profile paint nothing either.
	if spans, mapped = mapHeat([]byte(heatBuf), "buf.txt", h); mapped != 0 || len(spans) != 0 {
		t.Fatalf("non-.go mapped = %d want 0", mapped)
	}
	if spans, _ = mapHeat([]byte(heatBuf), "buf.go", nil); spans != nil {
		t.Fatal("no profile must mean no spans")
	}
}

// TestLoadHeatRefusals: the open-time read's named refusals leave the
// profile unset — the read error, the 256 KiB bound, and the malformed
// line. The marker text itself is pinned through heatMarker.
func TestLoadHeatRefusals(t *testing.T) {
	// Read failure.
	installHeatRead(t, nil, -vi.ErrENOENT)
	e := usEditor("")
	e.loadHeat("/host/EDIT/X.FOLDED")
	if e.heat != nil {
		t.Fatal("a refused read must leave the profile unset")
	}
	// At the cap the file is too large.
	installHeatRead(t, make([]byte, vi.MaxFileBytes), int64(vi.MaxFileBytes))
	e.loadHeat("/host/EDIT/X.FOLDED")
	if e.heat != nil {
		t.Fatal("a cap-sized read must refuse as too-large")
	}
	// A malformed line refuses the whole file.
	installHeatRead(t, []byte("main.f 1\nnope\n"), 14)
	e.loadHeat("/host/EDIT/X.FOLDED")
	if e.heat != nil {
		t.Fatal("a malformed line must refuse the file")
	}
	// A clean read loads.
	installHeatRead(t, []byte("main.main;main.f 80\n"), 20)
	e.loadHeat("/host/EDIT/X.FOLDED")
	if e.heat == nil || e.heat.fns["main.f"] != 80 || e.heat.samples != 80 {
		t.Fatalf("loaded heat = %+v", e.heat)
	}
	// The marker's exact text — the string the gate greps.
	if got, want := heatMarker(e.heat, 1),
		"goedit: heat fns=1 mapped=1 samples=80 top=main.f pct=100"; got != want {
		t.Fatalf("heatMarker = %q want %q", got, want)
	}
	empty := &heatData{fns: map[string]uint64{}}
	if got, want := heatMarker(empty, 0),
		"goedit: heat fns=0 mapped=0 samples=0 top=- pct=0"; got != want {
		t.Fatalf("empty heatMarker = %q want %q", got, want)
	}
}

// TestHeatGutterPaint: the recorded frame carries the 4-px strip on every
// painted line of a matched span, in the line's bucket colour — and only
// there.
func TestHeatGutterPaint(t *testing.T) {
	h := parseOrDie(t, "main.main;main.f 80\nmain.main;main.g 8\n")
	e := goEditor(heatBuf2)
	e.heat = h
	e.ta = &tabapp.TabApp{Win: 1, W: natW, H: natH}
	s := record(e)
	e.draw()
	row := chromeH + 4
	// f's span is lines 3-6 of heatBuf2 — rows 2-5 carry the hottest
	// bucket's strip at the frame's left edge; g's lines 8-9 — rows 7-8
	// — carry the middle bucket; the package, blank and tail rows carry
	// nothing.
	for i := 2; i <= 5; i++ {
		if !s.has(heatX, row+i*lineH, heatW, 8, colHeat[3]) {
			t.Fatalf("row %d of f's span lacks the hot strip", i)
		}
	}
	for i := 7; i <= 8; i++ {
		if !s.has(heatX, row+i*lineH, heatW, 8, colHeat[1]) {
			t.Fatalf("row %d of g's span lacks the warm strip", i)
		}
	}
	if n := s.count(colHeat[3], 0, natW, row+6*lineH, natH); n != 0 {
		t.Fatalf("hot strip outside f's span (%d rects)", n)
	}
	if s.has(heatX, row+6*lineH, heatW, 8, colHeat[0]) ||
		s.has(heatX, row+10*lineH, heatW, 8, colHeat[1]) {
		t.Fatal("the blank separator or the tail row painted a strip")
	}
	// A buffer with no profile paints no gutter at all.
	e2 := goEditor(heatBuf2)
	e2.ta = &tabapp.TabApp{Win: 1, W: natW, H: natH}
	s2 := record(e2)
	e2.draw()
	for _, c := range colHeat {
		if n := s2.count(c, 0, natW, 0, natH); n != 0 {
			t.Fatalf("gutter colour %#x painted without a profile (%d)", c, n)
		}
	}
}

// heatBuf2 is the paint drill's document: package on line 1, f's span on
// lines 3-6 (rows 2-5), a blank separator on row 6, g's span on lines
// 8-9 (rows 7-8) and a tail line on row 10.
const heatBuf2 = "package main\n\nfunc f() {\n\ta\n\tb\n}\n\nfunc g() {\n\tx\n}\ntail\n"
