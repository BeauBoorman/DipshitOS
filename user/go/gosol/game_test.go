// Class-A coverage for the model: deal determinism, the move-legality
// tables, stock draw/recycle, and the win latch.
package main

import "testing"

// dealShape is a fingerprint of the dealt table: every pile's cards in
// order, up flags included.
func dealShape(g *Game) []Card {
	var out []Card
	out = append(out, g.stock...)
	out = append(out, g.waste...)
	for i := 0; i < 4; i++ {
		out = append(out, g.found[i]...)
	}
	for i := 0; i < 7; i++ {
		out = append(out, g.tab[i]...)
	}
	return out
}

func TestDealDeterministic(t *testing.T) {
	a := newGame(42, 1)
	b := newGame(42, 1)
	sa, sb := dealShape(a), dealShape(b)
	if len(sa) != 52 || len(sb) != 52 {
		t.Fatalf("deal size %d/%d, want 52", len(sa), len(sb))
	}
	for i := range sa {
		if sa[i] != sb[i] {
			t.Fatalf("card %d differs: %+v vs %+v", i, sa[i], sb[i])
		}
	}
	c := newGame(43, 1)
	sc := dealShape(c)
	same := true
	for i := range sa {
		if sa[i] != sc[i] {
			same = false
		}
	}
	if same {
		t.Fatal("seeds 42 and 43 dealt identical tables")
	}
}

func TestDealShape(t *testing.T) {
	g := newGame(7, 1)
	if len(g.stock) != 24 {
		t.Fatalf("stock %d, want 24", len(g.stock))
	}
	for p := 0; p < 7; p++ {
		if len(g.tab[p]) != p+1 {
			t.Fatalf("tab%d %d cards, want %d", p, len(g.tab[p]), p+1)
		}
		for i, c := range g.tab[p] {
			if c.Up != (i == p) {
				t.Fatalf("tab%d card %d up=%v, want %v", p, i, c.Up, i == p)
			}
		}
	}
	// The table is a permutation of the deck.
	var seen [52]bool
	for _, c := range dealShape(g) {
		idx := int(c.Suit)*13 + int(c.Rank) - 1
		if seen[idx] {
			t.Fatalf("duplicate card %+v", c)
		}
		seen[idx] = true
	}
}

func TestDrawOneAndThree(t *testing.T) {
	g := newGame(11, 1)
	n, rec := g.drawStock()
	if rec || n != 1 || len(g.waste) != 1 || len(g.stock) != 23 {
		t.Fatalf("draw-1: n=%d rec=%v stock=%d waste=%d", n, rec, len(g.stock), len(g.waste))
	}
	if !g.waste[0].Up {
		t.Fatal("waste card not face up")
	}
	g3 := newGame(11, 3)
	n, _ = g3.drawStock()
	if n != 3 || len(g3.waste) != 3 || len(g3.stock) != 21 {
		t.Fatalf("draw-3: n=%d stock=%d waste=%d", n, len(g3.stock), len(g3.waste))
	}
	// Eight draw-3 passes clear the stock (8*3=24); the ninth recycles.
	for i := 0; i < 7; i++ {
		g3.drawStock()
	}
	if len(g3.stock) != 0 || len(g3.waste) != 24 {
		t.Fatalf("post-draws stock=%d waste=%d", len(g3.stock), len(g3.waste))
	}
	wasteBefore := append([]Card(nil), g3.waste...)
	n, rec = g3.drawStock()
	if !rec || n != 0 || len(g3.stock) != 24 || len(g3.waste) != 0 {
		t.Fatalf("recycle: n=%d rec=%v stock=%d waste=%d", n, rec, len(g3.stock), len(g3.waste))
	}
	for _, c := range g3.stock {
		if c.Up {
			t.Fatal("recycled stock card left face up")
		}
	}
	n, _ = g3.drawStock()
	if n != 3 || g3.waste[0].Up != true {
		t.Fatalf("post-recycle draw n=%d", n)
	}
	// The recycle preserved order: the new waste's first three cards are
	// the OLD waste's bottom three — the deal's original draw order.
	for i := 0; i < 3; i++ {
		if g3.waste[i] != wasteBefore[i] {
			t.Fatalf("recycled order: waste[%d]=%+v want %+v", i, g3.waste[i], wasteBefore[i])
		}
	}
}

// table builds a game with explicit piles for the legality tables.
func table(stock, waste []Card, found [4][]Card, tab [7][]Card) *Game {
	return &Game{draw: 1, seed: 1, stock: stock, waste: waste, found: found, tab: tab}
}

func up(rank, suit uint8) Card   { return Card{Rank: rank, Suit: suit, Up: true} }
func down(rank, suit uint8) Card { return Card{Rank: rank, Suit: suit} }

func TestCanFound(t *testing.T) {
	var found [4][]Card
	var tab [7][]Card
	g := table(nil, nil, found, tab)
	cases := []struct {
		c    Card
		want bool
	}{
		{up(1, 0), true},    // ace opens
		{up(2, 0), false},   // no base
		{up(13, 0), false},  // king on empty
		{up(1, 4), false},   // bad suit byte
		{down(1, 0), false}, // face down never moves
	}
	for i, tc := range cases {
		if got := g.canFound(tc.c); got != tc.want {
			t.Fatalf("case %d canFound(%+v)=%v want %v", i, tc.c, got, tc.want)
		}
	}
	g.found[0] = []Card{up(1, 0), up(2, 0)}
	if !g.canFound(up(3, 0)) {
		t.Fatal("3S onto 2S refused")
	}
	if g.canFound(up(3, 1)) || g.canFound(up(4, 0)) || g.canFound(up(1, 0)) {
		t.Fatal("wrong-suit/wrong-rank foundation accepted")
	}
}

func TestCanTableau(t *testing.T) {
	var found [4][]Card
	var tab [7][]Card
	tab[0] = []Card{up(7, 1)} // 7H (red)
	g := table(nil, nil, found, tab)
	cases := []struct {
		c    Card
		p    int
		want bool
	}{
		{up(6, 0), 0, true},  // 6S black onto 7H red
		{up(6, 3), 0, true},  // 6C black onto 7H red
		{up(6, 1), 0, false}, // red on red
		{up(5, 0), 0, false}, // wrong rank
		{up(8, 0), 0, false},
		{up(13, 0), 1, true},  // king opens empty pile
		{up(12, 0), 1, false}, // non-king on empty
		{up(6, 0), 9, false},  // bad pile
		{down(6, 0), 0, false},
	}
	for i, tc := range cases {
		if got := g.canTableau(tc.c, tc.p); got != tc.want {
			t.Fatalf("case %d canTableau(%+v,%d)=%v want %v", i, tc.c, tc.p, got, tc.want)
		}
	}
	// A face-down destination top refuses even a legal build.
	var tab2 [7][]Card
	tab2[0] = []Card{down(7, 1)}
	g2 := table(nil, nil, found, tab2)
	if g2.canTableau(up(6, 0), 0) {
		t.Fatal("build onto face-down card accepted")
	}
}

func TestMoveFlipsExposed(t *testing.T) {
	var found [4][]Card
	var tab [7][]Card
	tab[0] = []Card{down(9, 2), up(7, 1)}
	tab[1] = []Card{up(8, 0)}
	g := table(nil, nil, found, tab)
	g.move(loc{kind: locTab, pile: 0}, 1, loc{kind: locTab, pile: 1})
	if len(g.tab[0]) != 1 || !g.tab[0][0].Up {
		t.Fatalf("exposed card not flipped: %+v", g.tab[0])
	}
	if len(g.tab[1]) != 2 || g.tab[1][1].Rank != 7 {
		t.Fatalf("run did not land: %+v", g.tab[1])
	}
	if g.moves != 1 {
		t.Fatalf("moves=%d, want 1", g.moves)
	}
}

func TestWinLatch(t *testing.T) {
	var found [4][]Card
	var tab [7][]Card
	// Suits 0-2 complete, clubs an ace short of the king — the last K moves.
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
		t.Fatal("all kings home but won=false")
	}
}
