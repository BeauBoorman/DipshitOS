package main

import (
	"testing"

	"virelai/find"
)

// buffer_test.go pins the pure layer (#2199): splices round-trip, runs merge
// or break on the rules the doc comment states, the ring is bounded, and
// replace-all's splice list matches find's count. These are the same rules
// the live gate drives through keystrokes — the class-A side of the card.

// TestSpliceApplyRevert is the model itself: apply then undo returns the
// original document byte-for-byte.
func TestSpliceApplyRevert(t *testing.T) {
	doc := []byte("hello world")
	op := editOp{kind: opEdit, sp: []splice{
		{pos: 0, old: []byte("hello"), ins: []byte("bye")},
		{pos: 6, old: []byte("world"), ins: []byte("earth")},
	}}
	next := applySplices(doc, op.sp, false)
	if string(next) != "bye earth" {
		t.Fatalf("apply = %q want %q", next, "bye earth")
	}
	if back := applySplices(next, op.sp, true); string(back) != "hello world" {
		t.Fatalf("revert = %q want %q", back, "hello world")
	}
	if got := splicedLen(len(doc), op.sp, false); got != len("bye earth") {
		t.Fatalf("splicedLen = %d want %d", got, len("bye earth"))
	}
}

// TestInsertRunMerges: contiguous typing collapses into one op — the
// merged-typing model the card asks for — until a newline breaks it.
func TestInsertRunMerges(t *testing.T) {
	var h history
	push := func(pos int, s string) {
		h.push(editOp{kind: opInsRun, sp: []splice{{pos: pos, ins: []byte(s)}}})
	}
	push(0, "h")
	push(1, "i")
	push(2, "!")
	if len(h.undo) != 1 {
		t.Fatalf("typing run = %d ops want 1", len(h.undo))
	}
	if got := string(h.undo[0].sp[0].ins); got != "hi!" {
		t.Fatalf("merged run = %q want %q", got, "hi!")
	}
	// A newline does not merge into the run — Return commits a line.
	push(3, "\n")
	if len(h.undo) != 2 {
		t.Fatalf("newline must start a new op: %d", len(h.undo))
	}
	// Nor does the run continue after it.
	push(4, "x")
	if len(h.undo) != 3 {
		t.Fatalf("typing after the newline = %d ops want 3", len(h.undo))
	}
	// A non-contiguous insert (caret moved) breaks the run too.
	h.breakRun()
	push(0, "q")
	if len(h.undo) != 4 {
		t.Fatalf("post-break insert = %d ops want 4", len(h.undo))
	}
}

// TestDeleteRunMergesBothDirections: backspace grows the run backward and Del
// grows it forward; either way the merged splice is the one contiguous region
// the keystrokes removed.
func TestDeleteRunMergesBothDirections(t *testing.T) {
	var h history
	// "abc", caret at 3: two backspaces then a home and two forward deletes
	// would be a breakRun — keep it one direction pair here.
	h.push(editOp{kind: opDelRun, sp: []splice{{pos: 2, old: []byte("c")}}})
	h.push(editOp{kind: opDelRun, sp: []splice{{pos: 1, old: []byte("b")}}})
	if len(h.undo) != 1 {
		t.Fatalf("backspace run = %d ops want 1", len(h.undo))
	}
	s := h.undo[0].sp[0]
	if s.pos != 1 || string(s.old) != "bc" {
		t.Fatalf("merged backspace splice = {pos:%d old:%q} want {1,\"bc\"}", s.pos, s.old)
	}
	// Reverting restores the region in place.
	if got := string(applySplices([]byte("a"), h.undo[0].sp, true)); got != "abc" {
		t.Fatalf("revert = %q want %q", got, "abc")
	}
	// A forward delete from the same position merges too.
	var h2 history
	h2.push(editOp{kind: opDelRun, sp: []splice{{pos: 0, old: []byte("a")}}})
	h2.push(editOp{kind: opDelRun, sp: []splice{{pos: 0, old: []byte("b")}}})
	if len(h2.undo) != 1 || string(h2.undo[0].sp[0].old) != "ab" {
		t.Fatalf("forward delete run = %+v", h2.undo)
	}
}

// TestHistoryRingIsBounded is the card's cap: a full ring drops the OLDEST
// op and keeps histCap entries — an unbounded history is the failure mode
// this pins against.
func TestHistoryRingIsBounded(t *testing.T) {
	var h history
	for i := 0; i < histCap+20; i++ {
		h.push(editOp{kind: opEdit, sp: []splice{{pos: i, ins: []byte{byte(i)}}}})
	}
	if len(h.undo) != histCap {
		t.Fatalf("ring = %d ops want %d", len(h.undo), histCap)
	}
	// The oldest entries fell off: the front of the ring is op 20, not op 0.
	if h.undo[0].sp[0].pos != 20 {
		t.Fatalf("oldest kept op = pos %d want 20", h.undo[0].sp[0].pos)
	}
	// Undo walks all of them; a new edit clears redo as it must.
	for i := 0; i < histCap; i++ {
		if _, ok := h.popUndo(); !ok {
			t.Fatalf("popUndo %d of %d failed", i, histCap)
		}
	}
	if _, ok := h.popUndo(); ok {
		t.Fatal("popUndo on a drained ring must fail")
	}
	if len(h.redo) != histCap {
		t.Fatalf("redo = %d ops want %d", len(h.redo), histCap)
	}
	h.push(editOp{kind: opEdit, sp: []splice{{pos: 0, ins: []byte("x")}}})
	if len(h.redo) != 0 {
		t.Fatalf("a new edit must clear redo, got %d", len(h.redo))
	}
}

// TestUndoRedoRoundTrip: the op sequence revert/reapply walk the document
// back and forth exactly.
func TestUndoRedoRoundTrip(t *testing.T) {
	var h history
	doc := []byte("ab")
	ins := editOp{kind: opInsRun, sp: []splice{{pos: 2, ins: []byte("cd")}}}
	h.push(ins)
	doc = applySplices(doc, ins.sp, false)
	if string(doc) != "abcd" {
		t.Fatalf("apply = %q", doc)
	}
	o, ok := h.popUndo()
	if !ok {
		t.Fatal("popUndo failed")
	}
	doc = applySplices(doc, o.sp, true)
	if string(doc) != "ab" {
		t.Fatalf("undo = %q want %q", doc, "ab")
	}
	o, ok = h.popRedo()
	if !ok {
		t.Fatal("popRedo failed")
	}
	doc = applySplices(doc, o.sp, false)
	if string(doc) != "abcd" {
		t.Fatalf("redo = %q want %q", doc, "abcd")
	}
}

// TestReplaceAllMatchesFindTotal: the splices replace every non-overlapping
// match find would count — the card's `n == M` rule — and a replacement that
// contains the pattern cannot re-match, because positions are computed
// against the original buffer.
func TestReplaceAllMatchesFindTotal(t *testing.T) {
	doc := []byte("one two one\ntwo one")
	pat, repl := []byte("one"), []byte("X")
	sp := replaceAllSplices(doc, pat, repl)
	if total, _, _ := find.From(doc, pat, 0); total != len(sp) {
		t.Fatalf("replaceAll = %d splices, find total %d", len(sp), total)
	}
	got := applySplices(doc, sp, false)
	if string(got) != "X two X\ntwo X" {
		t.Fatalf("replaced = %q", got)
	}
	// Self-containing replacement: one splice per original match, done.
	doc2 := []byte("aa")
	sp2 := replaceAllSplices(doc2, []byte("a"), []byte("aa"))
	if len(sp2) != 2 || string(applySplices(doc2, sp2, false)) != "aaaa" {
		t.Fatalf("a->aa = %d splices, %q", len(sp2), applySplices(doc2, sp2, false))
	}
	if sp := replaceAllSplices(doc, []byte("zzz"), repl); len(sp) != 0 {
		t.Fatalf("no-match replaceAll = %d splices want 0", len(sp))
	}
	if sp := replaceAllSplices(doc, nil, repl); sp != nil {
		t.Fatal("empty pattern must produce nil")
	}
	// Undo of a replace-all is the same splice walk in reverse.
	if back := applySplices(applySplices(doc, sp, false), sp, true); string(back) != string(doc) {
		t.Fatal("replace-all must revert to the original document")
	}
}

// TestCaretMoves pins the nav keys' pure rules, unicode-aware where the
// document is.
func TestCaretMoves(t *testing.T) {
	doc := []byte("ab\ncd\nöf")
	// left/right step scalars, not bytes.
	if got := moveLeft(doc, len(doc)); got != len(doc)-1 {
		t.Fatalf("moveLeft at end = %d want %d", got, len(doc)-1)
	}
	if got := moveLeft(doc, len(doc)-1); got != len(doc)-3 { // 'ö' is 2 bytes at 6..7
		t.Fatalf("moveLeft over ö = %d want %d", got, len(doc)-3)
	}
	if got := moveRight(doc, 6); got != 8 { // 'ö' at 6..7
		t.Fatalf("moveRight over ö = %d want 8", got)
	}
	// home/end bound the caret's line.
	if got := moveHome(doc, 8); got != 6 {
		t.Fatalf("moveHome = %d want 6", got)
	}
	if got := moveEnd(doc, 0); got != 2 {
		t.Fatalf("moveEnd = %d want 2", got)
	}
	// up/down keep the rune column, clamping to a shorter line.
	if got := moveLine(doc, 8, -1); got != 4 { // col 1 of line 2 -> col 1 of line 1
		t.Fatalf("moveLine up = %d want 4", got)
	}
	if got := moveLine(doc, 1, 1); got != 4 { // col 1 down
		t.Fatalf("moveLine down = %d want 4", got)
	}
	if got := moveLine(doc, len(doc), -2); got != 0 { // clamp to line 1 start+col
		if got < 0 || got > 2 {
			t.Fatalf("moveLine up 2 = %d, want within line 1", got)
		}
	}
}

// TestCaretLineCol pins the status line's L/T and column.
func TestCaretLineCol(t *testing.T) {
	doc := []byte("ab\ncde\nf")
	if l, c := caretLineCol(doc, 0); l != 1 || c != 1 {
		t.Fatalf("caretLineCol(0) = %d,%d want 1,1", l, c)
	}
	if l, c := caretLineCol(doc, 5); l != 2 || c != 3 { // 'd'
		t.Fatalf("caretLineCol(5) = %d,%d want 2,3", l, c)
	}
	if l, c := caretLineCol(doc, len(doc)); l != 3 || c != 2 {
		t.Fatalf("caretLineCol(end) = %d,%d want 3,2", l, c)
	}
}
