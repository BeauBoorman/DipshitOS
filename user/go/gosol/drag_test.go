// Class-A coverage for the in-surface pointer machine: synthetic
// press/move/release sequences against controlled tables — legal drops
// land, illegal drops snap back, runs carry, double-click sends to the
// foundation, and a click without motion stays a click.
package main

import "testing"

// fakeClock is the double-click window's scripted time source.
var fakeNs int64

func useFakeClock(t *testing.T) {
	t.Helper()
	fakeNs = 0
	old := nowNanos
	nowNanos = func() int64 { return fakeNs }
	t.Cleanup(func() { nowNanos = old })
}

// cardPt is the center of pile l's frame — a press point for single-card
// piles (stock, waste top, foundation top).
func pilePt(l loc) (int, int) {
	switch l.kind {
	case locStock:
		r := stockRect()
		return r.X + cardW/2, r.Y + cardH/2
	case locWaste:
		r := wasteRect()
		return r.X + cardW/2, r.Y + cardH/2
	case locFound:
		r := foundRect(l.pile)
		return r.X + cardW/2, r.Y + cardH/2
	}
	r := tabRect(l.pile)
	return r.X + cardW/2, r.Y + cardH/2
}

// tabPt is a point inside tableau pile p's card idx's hit strip.
func tabPt(b *board, p, idx int) (int, int) {
	r := tabRect(p)
	ys := b.g.tabFan(p)
	lo := ys[idx]
	hi := lo + 4
	if idx+1 < len(b.g.tab[p]) {
		hi = ys[idx+1] - 2
	}
	return r.X + cardW/2, (lo + hi) / 2
}

func TestStockClickDraws(t *testing.T) {
	g := newGame(5, 1)
	b := &board{g: g}
	x, y := pilePt(loc{kind: locStock})
	e := b.down(x, y)
	if !e.dirty || e.note == "" {
		t.Fatalf("stock press: %+v", e)
	}
	if len(g.waste) != 1 || len(g.stock) != 23 {
		t.Fatalf("after stock click: waste=%d stock=%d", len(g.waste), len(g.stock))
	}
	// The press is consumed: the release is a plain up, no drag state.
	e = b.up(x, y)
	if e.note != "" || b.on || b.arm {
		t.Fatalf("release after stock draw: %+v on=%v arm=%v", e, b.on, b.arm)
	}
}

func TestLegalDropLands(t *testing.T) {
	var found [4][]Card
	var tab [7][]Card
	tab[0] = []Card{up(7, 1)} // 7H
	tab[1] = []Card{up(8, 0)} // 8S
	b := &board{g: table(nil, nil, found, tab)}

	sx, sy := tabPt(b, 0, 0)
	b.down(sx, sy)
	if e := b.movePtr(sx+5, sy+5); !e.dirty || !b.on {
		t.Fatalf("first held move did not arm the drag: %+v on=%v", e, b.on)
	}
	// Mid-flight the run is still in its source pile (the table is never
	// half-moved) but reports itself under the pointer.
	if run := b.dragRun(); len(run) != 1 || run[0].Rank != 7 {
		t.Fatalf("dragRun=%v", run)
	}
	dx, dy := pilePt(loc{kind: locTab, pile: 1})
	b.movePtr(dx, dy)
	e := b.up(dx, dy)
	if e.note == "" || len(b.g.tab[1]) != 2 || b.g.tab[1][1].Rank != 7 {
		t.Fatalf("legal drop: note=%q tab1=%v", e.note, b.g.tab[1])
	}
	if len(b.g.tab[0]) != 0 {
		t.Fatalf("source not emptied: %v", b.g.tab[0])
	}
	if b.on || b.arm {
		t.Fatal("drag state left armed after the drop")
	}
}

func TestIllegalDropSnapsBack(t *testing.T) {
	var found [4][]Card
	var tab [7][]Card
	tab[0] = []Card{up(9, 1)} // 9H cannot build on 8S
	tab[1] = []Card{up(8, 0)}
	b := &board{g: table(nil, nil, found, tab)}

	sx, sy := tabPt(b, 0, 0)
	b.down(sx, sy)
	dx, dy := pilePt(loc{kind: locTab, pile: 1})
	b.movePtr(dx, dy)
	e := b.up(dx, dy)
	if e.note == "" {
		t.Fatal("illegal drop produced no refusal note")
	}
	if len(b.g.tab[0]) != 1 || len(b.g.tab[1]) != 1 {
		t.Fatalf("snap-back changed the table: tab0=%v tab1=%v", b.g.tab[0], b.g.tab[1])
	}
	if b.g.moves != 0 {
		t.Fatalf("illegal drop counted a move: %d", b.g.moves)
	}
}

func TestRunDragCarriesAll(t *testing.T) {
	var found [4][]Card
	var tab [7][]Card
	tab[0] = []Card{up(7, 1), up(6, 0)} // 7H, 6S — a legal run rooted at 0
	tab[1] = []Card{up(8, 0)}
	b := &board{g: table(nil, nil, found, tab)}

	sx, sy := tabPt(b, 0, 0) // grab the run's root
	b.down(sx, sy)
	b.movePtr(sx+1, sy+1)
	if run := b.dragRun(); len(run) != 2 {
		t.Fatalf("run=%v, want 2 cards", run)
	}
	dx, dy := pilePt(loc{kind: locTab, pile: 1})
	b.up(dx, dy)
	if len(b.g.tab[1]) != 3 || len(b.g.tab[0]) != 0 {
		t.Fatalf("run drop: tab0=%v tab1=%v", b.g.tab[0], b.g.tab[1])
	}
}

func TestDropOffTableSnapsBack(t *testing.T) {
	var found [4][]Card
	var tab [7][]Card
	tab[0] = []Card{up(1, 0)}
	b := &board{g: table(nil, nil, found, tab)}
	sx, sy := tabPt(b, 0, 0)
	b.down(sx, sy)
	// Bare felt: not a pile, not a column — the release is refused.
	b.movePtr(300, 55)
	e := b.up(300, 55)
	if e.note == "" || len(b.g.tab[0]) != 1 {
		t.Fatalf("off-table drop: note=%q tab0=%v", e.note, b.g.tab[0])
	}
}

func TestDoubleClickFoundation(t *testing.T) {
	useFakeClock(t)
	var found [4][]Card
	var tab [7][]Card
	tab[0] = []Card{up(1, 0)} // AS top
	b := &board{g: table(nil, nil, found, tab)}

	x, y := tabPt(b, 0, 0)
	// First click: down/up with no motion — a click, nothing moves.
	e := b.down(x, y)
	if e.note != "" {
		t.Fatalf("plain press: %+v", e)
	}
	b.up(x, y)
	if len(b.g.tab[0]) != 1 {
		t.Fatal("plain click moved a card")
	}
	// Second press inside the window on the same card: the foundation hop.
	fakeNs += dblClickNs / 2
	e = b.down(x, y)
	if e.note == "" || len(b.g.found[0]) != 1 || len(b.g.tab[0]) != 0 {
		t.Fatalf("double-click: note=%q found0=%v tab0=%v", e.note, b.g.found[0], b.g.tab[0])
	}
	b.up(x, y)
}

func TestDoubleClickOutsideWindowIsAClick(t *testing.T) {
	useFakeClock(t)
	var found [4][]Card
	var tab [7][]Card
	tab[0] = []Card{up(1, 0)}
	b := &board{g: table(nil, nil, found, tab)}
	x, y := tabPt(b, 0, 0)
	b.down(x, y)
	b.up(x, y)
	fakeNs += 2 * dblClickNs // stale
	b.down(x, y)
	if len(b.g.found[0]) != 0 {
		t.Fatal("stale second press was read as a double-click")
	}
	b.up(x, y)
}

func TestDraggedCardsStayInTable(t *testing.T) {
	var found [4][]Card
	var tab [7][]Card
	tab[0] = []Card{up(7, 1), up(6, 0)}
	b := &board{g: table(nil, nil, found, tab)}
	before := dealShape(b.g)
	sx, sy := tabPt(b, 0, 0)
	b.down(sx, sy)
	b.movePtr(sx+20, sy+20)
	if !b.on {
		t.Fatal("drag not live")
	}
	after := dealShape(b.g)
	for i := range before {
		if before[i] != after[i] {
			t.Fatalf("table moved mid-drag at %d", i)
		}
	}
	b.up(0, 0)
}
