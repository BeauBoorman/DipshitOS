// Class-A coverage for the undo stack: reversal fidelity, the 32-step cap,
// and history that survives the draw/recycle moves too.
package main

import "testing"

func TestUndoRestoresTable(t *testing.T) {
	var found [4][]Card
	var tab [7][]Card
	tab[0] = []Card{down(9, 2), up(7, 1)}
	tab[1] = []Card{up(8, 0)}
	g := table(nil, nil, found, tab)
	before := dealShape(g)

	g.move(loc{kind: locTab, pile: 0}, 1, loc{kind: locTab, pile: 1})
	if !g.Undo() {
		t.Fatal("undo refused")
	}
	after := dealShape(g)
	for i := range before {
		if before[i] != after[i] {
			t.Fatalf("undo mismatch at %d: %+v vs %+v", i, before[i], after[i])
		}
	}
	// The flip is inside the move's snapshot: the exposed card is face
	// down again after the undo.
	if g.tab[0][0].Up {
		t.Fatal("undo left the flipped card face up")
	}
	if g.moves != 0 {
		t.Fatalf("moves=%d after undo, want 0", g.moves)
	}
}

func TestUndoCap32(t *testing.T) {
	g := newGame(3, 1)
	// Draw through the stock: 24 draw-1 passes + 1 recycle = 25 moves, then
	// keep going — each pass over the stock is a move, so 40 draws total
	// exceeds the cap on their own.
	for i := 0; i < 40; i++ {
		g.drawStock()
	}
	if d := g.undoDepth(); d != undoCap {
		t.Fatalf("undo depth %d, want cap %d", d, undoCap)
	}
	// Undo all 32; the 33rd must refuse — the oldest steps were dropped,
	// not the newest.
	n := 0
	for g.Undo() {
		n++
	}
	if n != undoCap {
		t.Fatalf("undid %d steps, want %d", n, undoCap)
	}
}

func TestUndoReversesLastMoveFirst(t *testing.T) {
	var found [4][]Card
	var tab [7][]Card
	tab[0] = []Card{up(2, 0), up(1, 0)} // 2S under AS
	g := table(nil, nil, found, tab)
	g.autoFound(loc{kind: locTab, pile: 0}, 1) // AS home
	g.autoFound(loc{kind: locTab, pile: 0}, 0) // 2S home
	if len(g.found[0]) != 2 || len(g.tab[0]) != 0 {
		t.Fatalf("setup: found=%v", g.found)
	}
	if !g.Undo() {
		t.Fatal("undo 1 refused")
	}
	if len(g.found[0]) != 1 || len(g.tab[0]) != 1 {
		t.Fatalf("undo 1 restored wrong step: found=%v tab0=%v", g.found, g.tab[0])
	}
	if !g.Undo() {
		t.Fatal("undo 2 refused")
	}
	if len(g.found[0]) != 0 || len(g.tab[0]) != 2 {
		t.Fatalf("undo 2: found=%v tab0=%v", g.found, g.tab[0])
	}
}

func TestUndoEmptyAndNewDeal(t *testing.T) {
	g := newGame(9, 1)
	if g.Undo() {
		t.Fatal("empty history undid")
	}
	g.drawStock()
	fresh := newGame(9, 1)
	if fresh.undoDepth() != 0 {
		t.Fatal("a fresh deal carried history")
	}
}

func TestUndoClearsWinLatch(t *testing.T) {
	var found [4][]Card
	var tab [7][]Card
	for s := uint8(0); s < 3; s++ {
		for r := uint8(1); r <= 13; r++ {
			found[s] = append(found[s], up(r, s))
		}
	}
	for r := uint8(1); r <= 12; r++ {
		found[3] = append(found[3], up(r, 3))
	}
	tab[0] = []Card{up(13, 3)}
	g := table(nil, nil, found, tab)
	g.move(loc{kind: locTab, pile: 0}, 0, loc{kind: locFound, pile: 3})
	if !g.won {
		t.Fatal("setup: not won")
	}
	if !g.Undo() || g.won {
		t.Fatalf("undo did not restore the pre-win table: won=%v", g.won)
	}
}
