package webrender

import (
	"strings"
	"testing"

	"virelai/find"
)

// The find-in-page index: text runs in paint order, same line joined,
// line break = '\n'. Matches map back to the rects the bar highlights.
func TestFindIndexText(t *testing.T) {
	doc := ParseHTML([]byte(`<p>one <b>two</b> one</p><p>two one</p>`))
	lay := LayoutDocument(doc, 400, nil)
	f := NewFindIndex(lay)
	if !strings.Contains(f.Text, "one two one") {
		t.Fatalf("styled runs must join on one line; text=%q", f.Text)
	}
	if !strings.Contains(f.Text, "\n") {
		t.Fatalf("a block break must separate lines; text=%q", f.Text)
	}
	if strings.Contains(f.Text, "one\n\ntwo") {
		t.Fatalf("no doubled separators expected; text=%q", f.Text)
	}
}

// The gap between word items is a rendered space: a pattern containing it
// matches across items, and the pieces bridge the gap so the highlight
// stays contiguous.
func TestFindIndexWordGap(t *testing.T) {
	doc := ParseHTML([]byte(`<p>one two</p>`))
	lay := LayoutDocument(doc, 400, nil)
	f := NewFindIndex(lay)
	if f.Text != "one two" {
		t.Fatalf("word-gap join = %q want %q", f.Text, "one two")
	}
	matches := find.All([]byte(f.Text), []byte("e t"))
	if len(matches) != 1 {
		t.Fatalf("cross-gap match = %v want 1", matches)
	}
	pieces := f.Pieces(lay, matches[0], matches[0]+3)
	if len(pieces) != 2 {
		t.Fatalf("cross-gap pieces = %d want 2", len(pieces))
	}
	// The first piece's rect extends across the space to reach the second:
	// "e " is 2 cells (16 px) at bitmap metrics, not the one cell "e" owns.
	if pieces[0].Rect.X+pieces[0].Rect.W != pieces[1].Rect.X {
		t.Fatalf("gap piece not bridged: %+v vs %+v", pieces[0].Rect, pieces[1].Rect)
	}
	if pieces[0].Rect.W != 16 {
		t.Fatalf("bridged piece w=%d want 16", pieces[0].Rect.W)
	}
}

// Pieces: a match inside one run produces one rect measured with the
// layout's engine; the bitmap engine is 8px cells, so the geometry is
// pinned exactly.
func TestFindPieces(t *testing.T) {
	doc := ParseHTML([]byte(`<p>one two one</p>`))
	lay := LayoutDocument(doc, 400, nil)
	f := NewFindIndex(lay)
	matches := find.All([]byte(f.Text), []byte("one"))
	if len(matches) != 2 {
		t.Fatalf("matches = %v want 2", matches)
	}
	first := f.Pieces(lay, matches[0], matches[0]+3)
	if len(first) != 1 {
		t.Fatalf("one piece want, got %d", len(first))
	}
	if first[0].Rect.X != 0 || first[0].Rect.W != 3*8 {
		t.Fatalf("first rect = %+v want x=0 w=24 (bitmap cells)", first[0].Rect)
	}
	second := f.Pieces(lay, matches[1], matches[1]+3)
	if len(second) != 1 || second[0].Rect.X != 8*8 {
		t.Fatalf("second rect = %+v want x=64 w=24", second)
	}
	// Same line => both pieces share the item's Y.
	if first[0].Rect.Y != second[0].Rect.Y {
		t.Fatalf("same-line pieces at different Y: %v vs %v", first[0].Rect.Y, second[0].Rect.Y)
	}
}

// A match across a styled run on one line produces one piece per item it
// intersects — the highlight reads continuous, the same rule Chrome paints.
func TestFindPiecesCrossRun(t *testing.T) {
	doc := ParseHTML([]byte(`<p>ab<b>cd</b></p>`))
	lay := LayoutDocument(doc, 400, nil)
	f := NewFindIndex(lay)
	if f.Text != "abcd" {
		t.Fatalf("styled-run join = %q want %q", f.Text, "abcd")
	}
	matches := find.All([]byte(f.Text), []byte("bc"))
	if len(matches) != 1 {
		t.Fatalf("cross-run match = %v want 1", matches)
	}
	pieces := f.Pieces(lay, matches[0], matches[0]+2)
	if len(pieces) != 2 {
		t.Fatalf("cross-run pieces = %d want 2", len(pieces))
	}
	if pieces[0].Rect.W != 8 || pieces[1].Rect.W != 8 {
		t.Fatalf("piece widths = %d,%d want 8,8", pieces[0].Rect.W, pieces[1].Rect.W)
	}
	if pieces[0].Rect.X+pieces[0].Rect.W != pieces[1].Rect.X {
		t.Fatalf("pieces must abut: %+v vs %+v", pieces[0].Rect, pieces[1].Rect)
	}
	if pieces[0].Item == pieces[1].Item {
		t.Fatal("cross-run pieces must name different items")
	}
}

// Line-separated text cannot produce a cross-line match: the '\n' between
// items is not in any pattern the bar can hold.
func TestFindNoCrossLine(t *testing.T) {
	doc := ParseHTML([]byte(`<p>ab</p><p>cd</p>`))
	lay := LayoutDocument(doc, 400, nil)
	f := NewFindIndex(lay)
	if f.Text != "ab\ncd" {
		t.Fatalf("page text = %q want %q", f.Text, "ab\\ncd")
	}
	if got := find.All([]byte(f.Text), []byte("bc")); len(got) != 0 {
		t.Fatalf("cross-line 'bc' must not match, got %v", got)
	}
}

// Edge cases: nil layout, bad ranges.
func TestFindPiecesEdges(t *testing.T) {
	f := NewFindIndex(nil)
	if f.Text != "" {
		t.Fatalf("nil layout text = %q", f.Text)
	}
	doc := ParseHTML([]byte(`<p>ab</p>`))
	lay := LayoutDocument(doc, 400, nil)
	f = NewFindIndex(lay)
	if p := f.Pieces(lay, 5, 3); p != nil {
		t.Fatalf("reversed range = %v", p)
	}
	if p := f.Pieces(lay, -1, 1); p != nil {
		t.Fatalf("negative range = %v", p)
	}
	if p := f.Pieces(lay, 0, len(f.Text)+1); p != nil {
		t.Fatalf("overrun range = %v", p)
	}
	if p := f.Pieces(nil, 0, 1); p != nil {
		t.Fatalf("nil layout pieces = %v", p)
	}
}
