package main

import (
	"testing"

	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/webrender/font"
)

// folds_test.go pins M166b (#2987): brace-pair discovery through the
// classifyGo span filter (and the raw rule on non-Go buffers), the toggle
// and clear chords through the live key path, the caret-never-hidden rule
// on every landing, offsets across splices, Up/Down stepping a fold as one
// line, and the painted frame's visible-line map.

// goEditor builds a doc whose path ends in .go so the classifyGo scan
// applies, like the gate's FOLD.GO leg.
func goEditor(text string) *editor {
	e := usEditor(text)
	e.path = "buf.go"
	return e
}

func ctrlKey(letter byte) vi.Event {
	return usDown(letter-'a'+0x04, modCtrl, uint32(letter))
}

// foldSrc is the drill buffer most of these tests share:
//
//	func f() {     line 1, '{' at 9
//	AAAA           line 2, [11,15)
//	BBBB           line 3, [16,20)
//	}              line 4, '}' at 21
//	tail           line 5
//
// The fold is {9,21} and its hidden span is [11,21) — two lines.
const foldSrc = "func f() {\nAAAA\nBBBB\n}\ntail\n"

// TestFoldBracePairs: the pair enumerator — same-kind nesting, the .go
// span skip (a `{` inside a string, rune literal or comment is not a
// candidate), and the raw rule a non-Go buffer follows.
func TestFoldBracePairs(t *testing.T) {
	src := "a {\nb {\n}\n}\ns := \"{\"\nc := '}'\n// {\n/* { */\n"
	pairs := bracePairs([]byte(src), true)
	if len(pairs) != 2 {
		t.Fatalf("go buffer pairs = %d want 2 (string/rune/comment braces "+
			"must not pair): %+v", len(pairs), pairs)
	}
	if pairs[0].open != 2 || pairs[0].close != 10 {
		t.Fatalf("outer pair = %+v", pairs[0])
	}
	if pairs[1].open != 6 || pairs[1].close != 8 {
		t.Fatalf("inner pair = %+v", pairs[1])
	}
	// Unmatched opens carry no pair.
	if n := len(bracePairs([]byte("a {\nb"), true)); n != 0 {
		t.Fatalf("unmatched open gave %d pairs", n)
	}
	// A non-Go buffer scans raw: the "comment" brace counts here.
	raw := bracePairs([]byte("// {\n}\n"), false)
	if len(raw) != 1 || raw[0].open != 3 || raw[0].close != 5 {
		t.Fatalf("non-Go raw scan = %+v want [{3,5}]", raw)
	}
}

// TestFoldToggleCollapse: Ctrl-K folds the enclosing block, moving a caret
// it would hide onto the `{`, and Ctrl-K on the open line toggles it back.
func TestFoldToggleCollapse(t *testing.T) {
	e := goEditor(foldSrc)
	e.cur = 20 // inside the block
	if !e.key(ctrlKey('k')) {
		t.Fatal("ctrl-k must redraw")
	}
	if len(e.folds) != 1 {
		t.Fatalf("folds = %d want 1", len(e.folds))
	}
	f := e.folds[0]
	if f.open != 9 || f.close != 21 {
		t.Fatalf("fold = %+v want {9,21}", f)
	}
	if e.cur != 9 {
		t.Fatalf("caret inside a new fold must move to the brace: cur=%d", e.cur)
	}
	if n := e.foldHiddenLines(f); n != 2 {
		t.Fatalf("hidden lines = %d want 2", n)
	}
	if hs, he := e.foldSpan(f); hs != 11 || he != 21 {
		t.Fatalf("hidden span = [%d,%d) want [11,21)", hs, he)
	}
	// Ctrl-K on the open line toggles it back off.
	e.key(ctrlKey('k'))
	if len(e.folds) != 0 {
		t.Fatalf("unfold failed: folds=%d", len(e.folds))
	}
	// A caret with no block refuses: `fold none`, nothing changes.
	e.cur = len(e.buf)
	e.key(ctrlKey('k'))
	if len(e.folds) != 0 {
		t.Fatal("fold none must not create a fold")
	}
	// Ctrl-U clears every fold.
	e.cur = 20
	e.key(ctrlKey('k'))
	e.cur = 0
	e.key(ctrlKey('u'))
	if len(e.folds) != 0 {
		t.Fatalf("ctrl-u left %d folds", len(e.folds))
	}
}

// TestFoldTargetShapes: the candidate rules — opens on the caret's line,
// encloses the caret, innermost wins, single-line blocks are refused.
func TestFoldTargetShapes(t *testing.T) {
	//      "o {\ni {\nx\n}\n}\nz\n" — pairs {2,12} and {6,10}.
	e := goEditor("o {\ni {\nx\n}\n}\nz\n")
	f, ok := e.foldTarget(0)
	if !ok || f.open != 2 {
		t.Fatalf("caret on the open line: %+v ok=%v", f, ok)
	}
	f, ok = e.foldTarget(8)
	if !ok || f.open != 6 {
		t.Fatalf("caret inside nested block must pick the inner: %+v", f)
	}
	f, ok = e.foldTarget(12)
	if !ok || f.open != 2 {
		t.Fatalf("caret on the close brace: %+v ok=%v", f, ok)
	}
	if _, ok = e.foldTarget(15); ok {
		t.Fatal("caret outside all blocks must find no target")
	}
	// A brace pair on one line is not a fold.
	e2 := usEditor("x { y } z")
	if _, ok = e2.foldTarget(4); ok {
		t.Fatal("same-line brace pair must not be a fold target")
	}
}

// TestFoldGoVsRaw: the .go classifier gate — a string-brace opening a
// multi-line span is not a fold target on a .go path but is on a .txt one.
func TestFoldGoVsRaw(t *testing.T) {
	src := "s := \"{\"\nmore\n}\nx\n" // raw pairs {6,14}; go classifies 6 as str
	e := goEditor(src)
	if _, ok := e.foldTarget(10); ok {
		t.Fatal("a brace inside a Go string must not fold")
	}
	e2 := usEditor(src) // no .go path: the raw rule counts it
	if _, ok := e2.foldTarget(10); !ok {
		t.Fatal("the same brace must fold on a non-Go buffer")
	}
}

// TestFoldCaretLandings: every landing path that can arrive inside a fold
// unfolds it — goto, find, replace, minimap, undo and plain moves — while
// a landing that stays visible (the bracket jump to `}`) keeps it.
func TestFoldCaretLandings(t *testing.T) {
	newFold := func() *editor {
		e := goEditor(foldSrc)
		e.cur = 20 // inside the block
		e.toggleFold()
		if len(e.folds) != 1 || e.cur != 9 {
			t.Fatalf("setup fold failed: folds=%v cur=%d", e.folds, e.cur)
		}
		return e
	}

	// goto lands on hidden line 3.
	e := newFold()
	e.bar = []byte("3")
	e.mode = modeGoto
	e.runGoto()
	if len(e.folds) != 0 || e.cur != 16 {
		t.Fatalf("goto into a fold must unfold: folds=%v cur=%d want 16",
			e.folds, e.cur)
	}

	// find lands the caret on a match inside the fold.
	e = newFold()
	e.bar = []byte("BBBB")
	e.mode = modeFind
	e.runFind()
	if len(e.folds) != 0 || e.cur != 16 {
		t.Fatalf("find into a fold must unfold: folds=%v cur=%d want 16",
			e.folds, e.cur)
	}

	// replace: the match inside the fold is spliced and the caret lands
	// after the replacement — the fold must open.
	e = newFold()
	e.bar = []byte("AAAA")
	e.bar2 = []byte("ZZ")
	e.mode = modeReplace
	e.runReplace()
	if len(e.folds) != 0 {
		t.Fatalf("replace inside a fold must unfold: folds=%v", e.folds)
	}

	// bracket jump: '{' -> '}' lands on the visible close line, so the
	// fold stays — pin that asymmetry.
	e = newFold()
	e.cur = 9
	e.jumpMatch()
	if len(e.folds) != 1 {
		t.Fatal("jump to the visible close brace must keep the fold")
	}

	// minimap jump onto a hidden line.
	e = newFold()
	e.minimapJump(3)
	if len(e.folds) != 0 || e.cur != 16 {
		t.Fatalf("minimap into a fold must unfold: folds=%v cur=%d want 16",
			e.folds, e.cur)
	}

	// diagnostics jump onto a hidden line.
	e = newFold()
	e.diags = []diagRow{{file: e.path, line: 3, col: 1}}
	e.jumpDiag(0)
	if len(e.folds) != 0 || e.cur != 16 {
		t.Fatalf("diags jump into a fold must unfold: folds=%v cur=%d",
			e.folds, e.cur)
	}

	// undo landing inside a fold: fold over the edited block, then undo
	// the insert — the caret returns into the hidden span.
	e = newFold()
	e.folds = nil
	e.cur = 18
	e.applyOp(editOp{kind: opInsRun, sp: []splice{{pos: 18, ins: []byte("Z")}}}, 19)
	e.cur = 20
	e.toggleFold() // {9,22} over the edited block
	e.undo()       // caret lands at 18 — inside the fold
	if len(e.folds) != 0 {
		t.Fatalf("undo landing inside a fold must unfold: folds=%v", e.folds)
	}

	// redo the same shape: park the fold, undo a delete whose redo lands
	// inside it.
	e = newFold()
	e.folds = nil
	e.cur = 18
	e.applyOp(editOp{kind: opDelRun, sp: []splice{{pos: 18, old: []byte("B")}}}, 18)
	e.cur = 20
	e.toggleFold() // {9,21} — the close offset walked back with the delete
	e.undo()
	e.folds = nil
	e.cur = 20
	e.toggleFold()
	e.redo() // caret lands at 18+0=18 inside the fold
	if len(e.folds) != 0 {
		t.Fatalf("redo landing inside a fold must unfold: folds=%v", e.folds)
	}

	// a plain move that steps into hidden text unfolds too: the caret sits
	// on the open line's newline, Right lands on the first hidden byte.
	e = newFold()
	e.moveCaret(10, false, "move") // the newline ending "func f() {"
	if len(e.folds) != 1 {
		t.Fatal("landing on the open line's newline must keep the fold")
	}
	e.moveCaret(moveRight(e.buf, e.cur), false, "move")
	if len(e.folds) != 0 {
		t.Fatalf("a move landing inside a fold must unfold: folds=%v", e.folds)
	}
}

// TestFoldSpliceShift: inserts and deletes before, inside and after a fold
// shift its offsets; deleting its brace drops it.
func TestFoldSpliceShift(t *testing.T) {
	e := goEditor(foldSrc)
	e.cur = 20
	e.toggleFold()
	f := e.folds[0] // {9,21}

	// Insert before the fold: both offsets move by the inserted length.
	e.cur = 0
	e.applyOp(editOp{kind: opInsRun, sp: []splice{{pos: 0, ins: []byte("XX\n")}}}, 3)
	if len(e.folds) != 1 || e.folds[0].open != f.open+3 || e.folds[0].close != f.close+3 {
		t.Fatalf("insert before: folds=%+v want +3 shift", e.folds)
	}
	// Insert inside the hidden span: open stays, close follows the text.
	e.applyOp(editOp{kind: opInsRun,
		sp: []splice{{pos: e.folds[0].open + 7, ins: []byte("QQ")}}}, 0)
	if len(e.folds) != 1 || e.folds[0].open != f.open+3 || e.folds[0].close != f.close+5 {
		t.Fatalf("insert inside: folds=%+v want open +3 close +5", e.folds)
	}
	// Insert after the fold: nothing moves.
	g := e.folds[0]
	e.applyOp(editOp{kind: opInsRun, sp: []splice{{pos: len(e.buf), ins: []byte("!")}}}, len(e.buf))
	if e.folds[0] != g {
		t.Fatalf("insert after must not move the fold: %+v -> %+v", g, e.folds[0])
	}
	// Delete the opening brace: the fold is gone.
	e.applyOp(editOp{kind: opDelRun,
		sp: []splice{{pos: e.folds[0].open, old: []byte("{")}}}, e.folds[0].open)
	if len(e.folds) != 0 {
		t.Fatalf("deleting the opening brace must drop the fold: %+v", e.folds)
	}
}

// TestFoldUndoAcross: undoing the insert that a fold's offsets shifted
// across walks them back — the fold still brackets the same block.
func TestFoldUndoAcross(t *testing.T) {
	e := goEditor(foldSrc)
	e.cur = 20
	e.toggleFold()
	f := e.folds[0]
	e.cur = 0
	e.applyOp(editOp{kind: opInsRun, sp: []splice{{pos: 0, ins: []byte("XX\n")}}}, 3)
	e.undo() // caret lands at 0 — before the fold, visible
	if len(e.folds) != 1 || e.folds[0] != f {
		t.Fatalf("undo must restore the fold's offsets: %+v want %+v",
			e.folds, f)
	}
	e.redo()
	if len(e.folds) != 1 || e.folds[0].open != f.open+3 {
		t.Fatalf("redo must re-shift the fold: %+v", e.folds)
	}
}

// TestFoldUpDownStep: Up/Down treat the hidden block as one line — Down
// from the open line lands on the close line, Up from it lands back.
func TestFoldUpDownStep(t *testing.T) {
	e := goEditor(foldSrc)
	e.cur = 20
	e.toggleFold()
	// Caret on the open line at col 4 (offset 3, 'c').
	dn := e.moveLineVis(3, 1)
	// The close line '}' is one char: col clamps to its end (offset 22).
	if dn != 22 {
		t.Fatalf("down over a fold = %d want 22 (close line, col clamped)", dn)
	}
	// Up again: col was clamped to 1, so the landing is col 2 — offset 1.
	if up := e.moveLineVis(dn, -1); up != 1 {
		t.Fatalf("up back over the fold = %d want 1", up)
	}
	// Down from the close line continues to 'tail', same clamped col.
	if dn2 := e.moveLineVis(dn, 1); dn2 != 24 {
		t.Fatalf("down past the close line = %d want 24", dn2)
	}
	// With no folds the visual walk IS moveLine.
	e2 := usEditor("a\nb\nc\n")
	if e2.moveLineVis(2, -1) != moveLine(e2.buf, 2, -1) {
		t.Fatal("foldless moveLineVis must equal moveLine")
	}
	// And the key path drives it: Down from the open line lands past the
	// hidden span.
	e.cur = 3
	e.key(usDown(usageDown, 0, 0))
	if e.cur != 22 {
		t.Fatalf("Down key over a fold: cur=%d want 22", e.cur)
	}
}

// TestFoldPaintedFrame: the recorded frame shows only visible rows — the
// open line carries the muted `{...}` tail, the hidden lines paint
// nothing, and the close line takes the row right under the open line.
func TestFoldPaintedFrame(t *testing.T) {
	e := goEditor("func f() {\nWWWWWWWWWWWWWWWWWWWW\n}\ntail\n")
	e.ta = &tabapp.TabApp{Win: 1, W: natW, H: natH}
	e.cur = 22 // inside the fold's span
	e.toggleFold()
	if len(e.folds) != 1 {
		t.Fatalf("setup: folds=%v", e.folds)
	}
	s := record(e)
	e.draw()
	rowY := chromeH + 4
	// The `{...}` tail: muted glyphs a cell past "func f() {" — cell 11,
	// x = textOrigin + 11*8.
	adv := font.Advance(1)
	tailX := textOrigin + 11*adv
	if n := s.count(theme.Dark.InkMuted, tailX, tailX+5*adv, rowY, rowY+8); n == 0 {
		t.Fatalf("no muted {...} tail at x>=%d row %d", tailX, rowY)
	}
	// The row under the open line paints the close line's '}': ink exists
	// in the first cell and nothing wide follows it — the hidden 20-char
	// line would ink out past x=textOrigin+20*8.
	y1 := rowY + lineH
	if n := s.count(theme.Dark.Ink, textOrigin, textOrigin+adv, y1, y1+8); n == 0 {
		t.Fatal("the close line did not paint on the row under the fold")
	}
	if n := s.count(theme.Dark.Ink, textOrigin+3*adv, natW, y1, y1+8); n != 0 {
		t.Fatalf("hidden line ink leaked onto the close row (%d rects)", n)
	}
	// The caret sits on the open brace: its amber cell is on row 0 at
	// col 9, x = textOrigin + 9*8.
	if !s.has(textOrigin+9*adv, rowY, caretW, 8, colCaret) {
		t.Fatal("the caret cell is not on the fold's open brace")
	}
	// The status line carries the live fold count.
	if got := e.statusText(); got != "line=1/5 col=10 fold=1" {
		t.Fatalf("status = %q want fold=1 appended", got)
	}
}
