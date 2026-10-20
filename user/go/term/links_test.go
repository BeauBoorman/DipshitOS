package main

import (
	"strings"
	"testing"
)

func feed(t *linkTracker, s string) string {
	return string(t.filter([]byte(s)))
}

func TestOSC8UnderlinesAndTracks(t *testing.T) {
	lt := newLinkTracker()
	out := feed(lt, "\x1b]8;;https://10.0.0.2/\x1b\\docs link\x1b]8;;\x1b\\\r\n")
	if !strings.Contains(out, "\x1b]8;;https://10.0.0.2/\x1b\\\x1b[4m") {
		t.Fatalf("no underline injection at open: %q", out)
	}
	if !strings.Contains(out, "\x1b]8;;\x1b\\\x1b[24m") {
		t.Fatalf("no underline reset at close: %q", out)
	}
	// "docs link" occupies row 0 cols 0..8 (1-based report cells).
	uri, ok := lt.linkAt(5, 1, 24)
	if !ok || uri != "https://10.0.0.2/" {
		t.Fatalf("linkAt(5,1) = %q,%v", uri, ok)
	}
	for col := 1; col <= 9; col++ {
		if _, ok := lt.linkAt(col, 1, 24); !ok {
			t.Fatalf("linkAt(%d,1) missed the link cell", col)
		}
	}
	if _, ok := lt.linkAt(10, 1, 24); ok {
		t.Fatal("linkAt(10,1) resolved outside the link span")
	}
	if _, ok := lt.linkAt(1, 2, 24); ok {
		t.Fatal("linkAt(1,2) resolved on the next line")
	}
}

func TestOSC8BELAndCRLF(t *testing.T) {
	lt := newLinkTracker()
	feed(lt, "pre \x1b]8;;http://10.0.0.1:8000/x\x07go!\x1b]8;;\x07\r\n")
	uri, ok := lt.linkAt(6, 1, 24)
	if !ok || uri != "http://10.0.0.1:8000/x" {
		t.Fatalf("BEL-terminated link = %q,%v", uri, ok)
	}
	if _, ok := lt.linkAt(8, 1, 24); ok {
		t.Fatal("cell past close still resolves")
	}
}

func TestOSC8RefusesBadForms(t *testing.T) {
	lt := newLinkTracker()
	out := feed(lt, "\x1b]8;id=x;https://a/\x1b\\AB\x1b]8;;\x1b\\")
	// id= params are accepted; A,B at cols 0-1.
	if _, ok := lt.linkAt(2, 1, 24); !ok {
		t.Fatal("params-carrying link did not track")
	}
	_ = out
	// A non-8 OSC passes through with no injection and no link.
	lt2 := newLinkTracker()
	out2 := feed(lt2, "\x1b]0;title\x07\x1b]52;c;AAAA\x07text")
	if strings.Contains(out2, "\x1b[4m") {
		t.Fatalf("non-8 OSC injected underline: %q", out2)
	}
	if _, ok := lt2.linkAt(1, 1, 24); ok {
		t.Fatal("non-8 OSC tracked a link")
	}
}

func TestMirrorScrollAndHistory(t *testing.T) {
	lt := newLinkTracker()
	lt.cols = 10
	// 130 lines of output: 128 grid rows + 2 into history.
	var b strings.Builder
	for i := 0; i < 130; i++ {
		b.WriteString("line\r\n")
	}
	feed(lt, b.String())
	if lt.histN != 3 || lt.used != mirrorRows {
		t.Fatalf("hist=%d used=%d want 3/%d", lt.histN, lt.used, mirrorRows)
	}
	// Print a link — it lands at the tail (last visible row).
	feed(lt, "\x1b]8;;https://tail/\x1b\\tail\x1b]8;;\x1b\\")
	uri, ok := lt.linkAt(2, 24, 24)
	if !ok || uri != "https://tail/" {
		t.Fatalf("tail link = %q,%v (lineCount=%d)", uri, ok, lt.lineCount())
	}
}

func TestMirrorCursorMovesAndClears(t *testing.T) {
	lt := newLinkTracker()
	feed(lt, "\x1b]8;;https://a/\x1b\\abcd\x1b]8;;\x1b\\")
	feed(lt, "\x1b[2K") // EL2 clears the row's marks
	if _, ok := lt.linkAt(1, 1, 24); ok {
		t.Fatal("EL2 left link marks")
	}
	feed(lt, "\x1b]8;;https://b/\x1b\\xy\x1b]8;;\x1b\\")
	feed(lt, "\x1b[H") // home
	feed(lt, "\x1b[K") // EL0 to end of row
	if _, ok := lt.linkAt(1, 1, 24); ok {
		t.Fatal("EL0 left link marks")
	}
}

func TestMouseFilterExtract(t *testing.T) {
	m := newMouseFilter()
	in := "ab\x1b[<0;5;2Mcd\x1b[<32;5;2m"
	clean, reps := m.extract([]byte(in))
	if string(clean) != "abcd" {
		t.Fatalf("clean = %q want abcd", clean)
	}
	if len(reps) != 2 || reps[0].btn != 0 || reps[0].col != 5 || reps[0].row != 2 ||
		reps[0].release || !reps[1].release {
		t.Fatalf("reps = %+v", reps)
	}
	// click = press+release same cell.
	if c, r, ok := m.clickCell(reps[0]); ok || c != 0 || r != 0 {
		t.Fatal("press alone clicked")
	}
	if c, r, ok := m.clickCell(reps[1]); !ok || c != 5 || r != 2 {
		t.Fatalf("release = %d,%d,%v want 5,2,true", c, r, ok)
	}
}

func TestMouseFilterPartialAndPassThrough(t *testing.T) {
	m := newMouseFilter()
	clean, reps := m.extract([]byte("\x1b[<0;5;"))
	if len(clean) != 0 || len(reps) != 0 {
		t.Fatalf("partial leaked: %q %+v", clean, reps)
	}
	clean, reps = m.extract([]byte("2Mx"))
	if len(reps) != 1 || reps[0].col != 5 {
		t.Fatalf("split report = %+v clean=%q", reps, clean)
	}
	if string(clean) != "x" {
		t.Fatalf("clean = %q", clean)
	}
	// Arrows pass through byte-identically.
	m2 := newMouseFilter()
	clean, reps = m2.extract([]byte("\x1b[A\x1b[B"))
	if string(clean) != "\x1b[A\x1b[B" || len(reps) != 0 {
		t.Fatalf("arrows = %q %+v", clean, reps)
	}
}

func TestClickCellDragDoesNotOpen(t *testing.T) {
	m := newMouseFilter()
	press := mouseRep{btn: 0, col: 5, row: 2}
	if _, _, ok := m.clickCell(press); ok {
		t.Fatal("press clicked")
	}
	rel := mouseRep{btn: 32, col: 9, row: 2, release: true}
	if _, _, ok := m.clickCell(rel); ok {
		t.Fatal("drag released as click")
	}
}

func TestWebArgvSplits(t *testing.T) {
	short, ok := webArgv("https://a/b")
	if !ok || len(short) != 1 || short[0] != "https://a/b" {
		t.Fatalf("short = %v", short)
	}
	long := "https://" + strings.Repeat("x", 600)
	args, ok := webArgv(long)
	if !ok || len(args) != 3 {
		t.Fatalf("long = %d args", len(args))
	}
	if got := args[0] + args[1] + args[2]; got != long {
		t.Fatal("argv join lost bytes")
	}
	if _, ok := webArgv("https://" + strings.Repeat("x", 3000)); ok {
		t.Fatal("over-limit target accepted")
	}
}

func TestSchemeName(t *testing.T) {
	for in, want := range map[string]string{
		"https://a/": "https",
		"HTTP://a/":  "http",
		"ftp://a/":   "ftp",
		"nosch":      "",
		"file:///x":  "file",
		"a b://x":    "",
	} {
		if got := linkURIScheme(in); got != want {
			t.Errorf("scheme(%q) = %q want %q", in, got, want)
		}
	}
}
