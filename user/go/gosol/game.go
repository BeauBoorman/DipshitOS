// M145b (issue #2797): the Klondike table. The model is pure — no vi, no
// canvas — so the class-A suite can drive it directly: deal determinism,
// the legality tables, and the win check. Every mutating call pushes one
// undo snapshot first, so "undo holds 32 steps" is a property of the model,
// not of the pointer layer.
package main

// Pile identities shared by the model, the drag machine and the codec.
// locTab carries a pile index; locFound a suit index.
const (
	locStock uint8 = iota
	locWaste
	locFound
	locTab
)

// loc names a card's home: a pile kind plus its index (tableau pile 0..6,
// foundation slot 0..3). idx is only meaningful for the two multi-slot kinds.
type loc struct {
	kind uint8
	pile int
}

// Game is one Klondike table: the draw-1/draw-3 mode, the seed the deck was
// shuffled under, and the four pile sets.
type Game struct {
	stock []Card    // face down; the top is the LAST element
	waste []Card    // face up; the top is the last element
	found [4][]Card // one pile per suit, ace at the bottom
	tab   [7][]Card

	draw  int    // 1 or 3 — cards per stock pass
	seed  uint64 // the deal's shuffle seed, kept for save_state
	moves int    // committed moves, reported in the win marker
	won   bool   // latched when all four foundations reach the king

	// hist is the undo stack: one pre-move snapshot per committed move,
	// capped at undoCap. It lives on the game so a fresh deal or a state
	// restore starts with empty history by construction.
	hist []snapshot
}

// newGame deals a fresh table. draw must be 1 or 3; anything else is read
// as 1 — argv and save_state both validate before here, so this is the
// belt, not the door.
func newGame(seed uint64, draw int) *Game {
	if draw != 3 {
		draw = 1
	}
	g := &Game{draw: draw, seed: seed}
	d := deck()
	shuffle(&d, seed)
	at := 0
	for p := 0; p < 7; p++ {
		for i := 0; i <= p; i++ {
			g.tab[p] = append(g.tab[p], d[at])
			at++
		}
		g.tab[p][p].Up = true
	}
	for ; at < 52; at++ {
		g.stock = append(g.stock, d[at])
	}
	return g
}

// top returns a pile's last card and ok=false on an empty pile — the one
// shape every legality check opens with.
func top(p []Card) (Card, bool) {
	if len(p) == 0 {
		return Card{}, false
	}
	return p[len(p)-1], true
}

// canFound reports whether c may land on its suit's foundation pile: the
// ace opens an empty pile, anything else climbs the same suit one rank.
func (g *Game) canFound(c Card) bool {
	if c.Suit > SuitClubs || !c.Up {
		return false
	}
	p := g.found[c.Suit]
	t, ok := top(p)
	if !ok {
		return c.Rank == 1
	}
	return t.Rank+1 == c.Rank
}

// canTableau reports whether the run whose top card is c may land on
// tableau pile p: a king opens an empty pile, anything else builds down
// onto the opposite color.
func (g *Game) canTableau(c Card, p int) bool {
	if p < 0 || p > 6 || !c.Up {
		return false
	}
	t, ok := top(g.tab[p])
	if !ok {
		return c.Rank == 13
	}
	return t.Up && t.Red() != c.Red() && t.Rank == c.Rank+1
}

// sourceTop returns the card a single-card drag off src would carry, and
// whether the grab is legal: waste and foundation tops and any face-up
// tableau card are draggable. For a tableau pile the "card" is the run
// root at idx; the run itself is tab[pile][idx:].
func (g *Game) draggable(l loc, idx int) bool {
	switch l.kind {
	case locWaste:
		return len(g.waste) > 0 && idx == len(g.waste)-1
	case locFound:
		return l.pile >= 0 && l.pile < 4 && len(g.found[l.pile]) > 0 &&
			idx == len(g.found[l.pile])-1
	case locTab:
		return l.pile >= 0 && l.pile < 7 && idx >= 0 &&
			idx < len(g.tab[l.pile]) && g.tab[l.pile][idx].Up
	}
	return false
}

// runLen is how many cards a drag off (locTab, idx) carries — everything
// from idx to the pile's top. The other sources always move one card.
func (g *Game) runLen(l loc, idx int) int {
	if l.kind == locTab && l.pile >= 0 && l.pile < 7 &&
		idx >= 0 && idx < len(g.tab[l.pile]) {
		return len(g.tab[l.pile]) - idx
	}
	return 1
}

// drawStock passes cards from the stock to the waste — g.draw cards, or the
// whole stock when fewer remain. An empty stock recycles: the waste turns
// back over face down in one piece, preserving order (the waste's bottom
// becomes the stock's top). Both directions are one undoable move.
// Returns a description of what happened for the marker line.
func (g *Game) drawStock() (n int, recycled bool) {
	if len(g.stock) == 0 {
		if len(g.waste) == 0 {
			return 0, false
		}
		g.pushUndo()
		for i := len(g.waste) - 1; i >= 0; i-- {
			c := g.waste[i]
			c.Up = false
			g.stock = append(g.stock, c)
		}
		g.waste = g.waste[:0]
		g.moves++
		return 0, true
	}
	g.pushUndo()
	n = g.draw
	if n > len(g.stock) {
		n = len(g.stock)
	}
	for i := 0; i < n; i++ {
		c := g.stock[len(g.stock)-1]
		g.stock = g.stock[:len(g.stock)-1]
		c.Up = true
		g.waste = append(g.waste, c)
	}
	g.moves++
	return n, false
}

// move lifts the run at (src, idx) onto dst after the caller has validated
// the drop (canDrop); it flips the source pile's newly-exposed top face up,
// counts the move, and latches the win. It is the only path that mutates
// piles on a drop, so the undo push lives here too.
func (g *Game) move(src loc, idx int, dst loc) {
	g.pushUndo()
	var run []Card
	switch src.kind {
	case locWaste:
		run = g.waste[idx:]
		g.waste = g.waste[:idx]
	case locFound:
		run = g.found[src.pile][idx:]
		g.found[src.pile] = g.found[src.pile][:idx]
	case locTab:
		run = g.tab[src.pile][idx:]
		g.tab[src.pile] = g.tab[src.pile][:idx]
		g.flipTab(src.pile)
	}
	switch dst.kind {
	case locFound:
		g.found[dst.pile] = append(g.found[dst.pile], run...)
	case locTab:
		g.tab[dst.pile] = append(g.tab[dst.pile], run...)
	}
	g.moves++
	g.checkWin()
}

// flipTab turns a tableau pile's newly exposed top face up — the flip is
// part of the move that exposed it, so it lives inside the move's undo
// snapshot rather than becoming its own step.
func (g *Game) flipTab(p int) {
	if n := len(g.tab[p]); n > 0 && !g.tab[p][n-1].Up {
		g.tab[p][n-1].Up = true
	}
}

// canDrop validates a run of n cards rooted at (src,idx) landing on dst.
// Single cards may take either destination; a run (n>1) may only build on
// a tableau. A drop back onto its own pile is refused, as is a drop onto a
// pile the run already touches.
func (g *Game) canDrop(src loc, idx int, dst loc) bool {
	if !g.draggable(src, idx) {
		return false
	}
	var c Card
	switch src.kind {
	case locWaste:
		c = g.waste[idx]
	case locFound:
		c = g.found[src.pile][idx]
	case locTab:
		c = g.tab[src.pile][idx]
	default:
		return false
	}
	switch dst.kind {
	case locFound:
		// Foundations take exactly one card — the source's own suit pile
		// is where it already is.
		if g.runLen(src, idx) != 1 || dst.pile != int(c.Suit) {
			return false
		}
		if src.kind == locFound && src.pile == dst.pile {
			return false
		}
		return g.canFound(c)
	case locTab:
		if src.kind == locTab && src.pile == dst.pile {
			return false
		}
		return g.canTableau(c, dst.pile)
	}
	return false
}

// autoFound sends a single card to its foundation — the double-click
// gesture. It is only ever called on a card canFound already cleared, so
// the move is one straight application.
func (g *Game) autoFound(src loc, idx int) bool {
	var c Card
	switch src.kind {
	case locWaste:
		if idx != len(g.waste)-1 {
			return false
		}
		c = g.waste[idx]
	case locTab:
		if idx != len(g.tab[src.pile])-1 {
			return false
		}
		c = g.tab[src.pile][idx]
	default:
		return false
	}
	if !g.canFound(c) {
		return false
	}
	g.move(src, idx, loc{kind: locFound, pile: int(c.Suit)})
	return true
}

// checkWin latches the win the first time every foundation holds a king.
// It runs at the end of move(), so a won table can still be undone back
// into play — the latch only gates the notify, not the rules.
func (g *Game) checkWin() {
	if g.won {
		return
	}
	for s := uint8(0); s < 4; s++ {
		t, ok := top(g.found[s])
		if !ok || t.Rank != 13 {
			return
		}
	}
	g.won = true
}

// pileCards exposes one pile's slice for the codec and the renderer —
// read-only by convention; mutation goes through the methods above.
func (g *Game) pileCards(l loc) []Card {
	switch l.kind {
	case locStock:
		return g.stock
	case locWaste:
		return g.waste
	case locFound:
		if l.pile >= 0 && l.pile < 4 {
			return g.found[l.pile]
		}
	case locTab:
		if l.pile >= 0 && l.pile < 7 {
			return g.tab[l.pile]
		}
	}
	return nil
}
