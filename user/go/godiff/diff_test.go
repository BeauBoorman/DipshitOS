package main

import (
	"strings"
	"testing"
)

func TestIdentical(t *testing.T) {
	text, differ, _ := Diff("a\nb\n", "a\nb\n", 3)
	if differ || text != "" {
		t.Fatalf("identical inputs produced %q", text)
	}
}

func TestChange(t *testing.T) {
	text, differ, _ := Diff("a\nb\nc\n", "a\nB\nc\n", 3)
	if !differ {
		t.Fatal("expected a diff")
	}
	want := "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"
	if text != want {
		t.Fatalf("got %q want %q", text, want)
	}
}

func TestInsertAndDelete(t *testing.T) {
	text, _, _ := Diff("a\nc\n", "a\nb\nc\n", 1)
	want := "@@ -1,2 +1,3 @@\n a\n+b\n c\n"
	if text != want {
		t.Fatalf("insert got %q want %q", text, want)
	}
	text, _, _ = Diff("a\nb\nc\n", "a\nc\n", 1)
	want = "@@ -1,3 +1,2 @@\n a\n-b\n c\n"
	if text != want {
		t.Fatalf("delete got %q want %q", text, want)
	}
}

func TestEmptySides(t *testing.T) {
	text, _, _ := Diff("", "x\n", 3)
	want := "@@ -0,0 +1 @@\n+x\n"
	if text != want {
		t.Fatalf("empty-a got %q want %q", text, want)
	}
	text, _, _ = Diff("x\n", "", 3)
	want = "@@ -1 +0,0 @@\n-x\n"
	if text != want {
		t.Fatalf("empty-b got %q want %q", text, want)
	}
}

func TestNoFinalNewline(t *testing.T) {
	text, differ, _ := Diff("x\n", "x", 3)
	if !differ {
		t.Fatal("x\\n vs x should differ")
	}
	want := "@@ -1 +1 @@\n-x\n+x\n\\ No newline at end of file\n"
	if text != want {
		t.Fatalf("got %q want %q", text, want)
	}
}

func TestHunkMergeGap(t *testing.T) {
	a := "1\n2\n3\n4\n5\n6\n7\n8\n"
	b := "1\n2\nX\n4\n5\n6\nY\n8\n"
	// changes at lines 3 and 7: gap 3 > 2*1 -> two hunks at ctx=1.
	_, d1, _ := Diff(a, b, 1)
	if !d1 {
		t.Fatal("expected diff")
	}
	t1, _, _ := Diff(a, b, 1)
	if n := countHunks(t1); n != 2 {
		t.Fatalf("ctx=1 hunks=%d want 2: %q", n, t1)
	}
	t3, _, _ := Diff(a, b, 3)
	if n := countHunks(t3); n != 1 {
		t.Fatalf("ctx=3 hunks=%d want 1: %q", n, t3)
	}
}

func countHunks(text string) int {
	n := 0
	for _, ln := range splitLines(text) {
		if len(ln.text) >= 2 && ln.text[:2] == "@@" {
			n++
		}
	}
	return n
}

func TestTooLarge(t *testing.T) {
	var big string
	for i := 0; i < maxLines+1; i++ {
		big += "x\n"
	}
	_, _, tooBig := Diff(big, "", 3)
	if !tooBig {
		t.Fatal("expected tooLarge")
	}
}

func TestCliArgs(t *testing.T) {
	if got := cliArgs([]string{"GODIFF.ELF", "a", "b"}); len(got) != 2 || got[0] != "a" {
		t.Fatalf("argv0 not dropped: %v", got)
	}
	if got := cliArgs([]string{"a", "b"}); len(got) != 2 {
		t.Fatalf("bare args mangled: %v", got)
	}
}

func stripANSI(s string) string {
	var b []byte
	for i := 0; i < len(s); i++ {
		if s[i] == 0x1b {
			for i < len(s) && s[i] != 'm' && s[i] != 'H' && s[i] != 'J' && s[i] != 'l' && s[i] != 'h' {
				i++
			}
			continue
		}
		b = append(b, s[i])
	}
	return string(b)
}

func TestRenderUnifiedColors(t *testing.T) {
	a := splitLines("alpha\nbeta\ngamma\n")
	b := splitLines("alpha\nBETA\ngamma\n")
	hs := hunks(lcsOps(a, b), 3)
	f := renderUnified("A", "B", a, b, hs, 0, 24)
	if !strings.Contains(f, colHunk+"@@ -1,3 +1,3 @@") {
		t.Fatalf("missing blue hunk header: %q", f)
	}
	if !strings.Contains(f, colMinus+"-beta") || !strings.Contains(f, colPlus+"+BETA") {
		t.Fatalf("missing colored change lines: %q", f)
	}
	if !strings.Contains(f, framePrologue) || !strings.Contains(f, "GODIFF A | B") {
		t.Fatalf("missing prologue/header: %q", f)
	}
}

func TestRenderSideBySideAligns(t *testing.T) {
	a := splitLines("alpha\nbeta\ngamma\n")
	b := splitLines("alpha\nBETA\nGAMMA\n")
	hs := hunks(lcsOps(a, b), 3)
	f := renderSideBySide("A", "B", a, b, hs, 0, 24, 80)
	rows := strings.Split(stripANSI(f), "\n")
	var pair string
	for _, r := range rows {
		if strings.Contains(r, "beta") {
			pair = r
		}
	}
	if pair == "" {
		t.Fatalf("no paired row: %q", f)
	}
	if !strings.Contains(pair, "BETA") || !strings.Contains(pair, " | ") {
		t.Fatalf("paired row not aligned: %q", pair)
	}
	if !strings.Contains(f, colMinus+"beta") || !strings.Contains(f, colPlus+"BETA") {
		t.Fatalf("paired colors missing: %q", f)
	}
	// Unequal run: left cell must blank-pad, not shift the separator.
	a2 := splitLines("x\n1\n2\ny\n")
	b2 := splitLines("x\nZ\ny\n")
	hs2 := hunks(lcsOps(a2, b2), 1)
	f2 := renderSideBySide("A", "B", a2, b2, hs2, 0, 24, 40)
	plain := stripANSI(f2)
	var sepCols []int
	for _, r := range strings.Split(plain, "\n") {
		if strings.HasPrefix(r, " GODIFF ") {
			continue
		}
		if i := strings.Index(r, " | "); i >= 0 {
			sepCols = append(sepCols, i)
		}
	}
	for _, c := range sepCols[1:] {
		if c != sepCols[0] {
			t.Fatalf("unaligned separators %v: %q", sepCols, plain)
		}
	}
	if !strings.Contains(f2, "1") && !strings.Contains(f2, "2") {
		t.Fatalf("deleted rows missing: %q", f2)
	}
}

func TestFitCell(t *testing.T) {
	if got := fitCell("abcdef", 4); got != "abc…" {
		t.Fatalf("clip: %q", got)
	}
	if got := fitCell("ab", 5); got != "ab   " {
		t.Fatalf("pad: %q", got)
	}
	if got := fitCell("ab€cd", 4); got != "ab€…" {
		t.Fatalf("rune clip: %q", got)
	}
}
