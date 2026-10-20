// M145b (issue #2797): the undo ring. The card's contract is "undo holds
// 32 steps": every mutating move snapshots the four pile sets first, and
// the 33rd step pushes the oldest off the bottom. Snapshots are slices
// copied at push time — the table is 52 cards, so a copy is cheaper than
// any encoding and an undo is a plain field swap.
package main

// undoCap is the card's bound: the stack never holds more than 32 steps.
const undoCap = 32

// snapshot is one table state: the same four pile sets Game carries, each
// an owned copy so a later move cannot reach back and edit history. The
// mode fields ride along so undo restores the whole contract, not just the
// card positions (a draw-mode toggle mid-game is not a move and stays put —
// see board.toggleDraw — but moves/won restore honestly).
type snapshot struct {
	stock []Card
	waste []Card
	found [4][]Card
	tab   [7][]Card
	moves int
	won   bool
}

// snap copies the table's pile slices. copyCards keeps each pile's backing
// array private: append() after an undo must never write through into a
// still-queued snapshot.
func (g *Game) snap() snapshot {
	var s snapshot
	s.stock = copyCards(g.stock)
	s.waste = copyCards(g.waste)
	for i := 0; i < 4; i++ {
		s.found[i] = copyCards(g.found[i])
	}
	for i := 0; i < 7; i++ {
		s.tab[i] = copyCards(g.tab[i])
	}
	s.moves = g.moves
	s.won = g.won
	return s
}

func copyCards(p []Card) []Card {
	if len(p) == 0 {
		return nil
	}
	out := make([]Card, len(p))
	copy(out, p)
	return out
}

// pushUndo records the pre-move table. It is called by every mutating move
// before the first pile changes — draw, recycle, drop, auto-foundation.
// The cap drops the OLDEST step when full: the user loses the far end of
// their history, never the move they just made.
func (g *Game) pushUndo() {
	g.hist = append(g.hist, g.snap())
	if len(g.hist) > undoCap {
		copy(g.hist, g.hist[1:])
		g.hist = g.hist[:undoCap]
	}
}

// Undo pops the newest snapshot back onto the table. False means the stack
// was empty — the caller prints nothing rather than claiming a revert.
func (g *Game) Undo() bool {
	if len(g.hist) == 0 {
		return false
	}
	s := g.hist[len(g.hist)-1]
	g.hist = g.hist[:len(g.hist)-1]
	g.stock = s.stock
	g.waste = s.waste
	g.found = s.found
	g.tab = s.tab
	g.moves = s.moves
	g.won = s.won
	return true
}

// undoDepth reports the live stack depth for markers and tests.
func (g *Game) undoDepth() int { return len(g.hist) }
