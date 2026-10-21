// M152d (issue #2918): the 'a' key — one auto-move per press. Under the
// seat an app sees keys only (#2878's fix delivers content pointer, but
// the scripted legs still drive the keyboard), so a win the gate can
// reach needs a card-moving key. The priority order is a player's
// autopilot: foundation first (never a mistake), then waste to tableau,
// then a tableau move that exposes a face-down card — never a lateral
// shuffle that just moves a problem — and a stock pass only when nothing
// else moves. Each press goes through move()/drawStock(), so an auto
// game builds undo history and scores stats exactly like a dragged one.
//
// The order is a contract with the class-A suite: seed 59 (draw-1) is
// pinned as winnable by this alphabet alone, and the go-games spec's
// run-06 leg types the same key into the same table. The greedy order
// must never drift apart from that pin.
package main

// autoMove applies one greedy move and returns the `gosol:` marker body
// for it ("" when nothing legal remains). On a won table it is an honest
// no-op — the game is over, not stalled.
func (g *Game) autoMove() string {
	if g.won {
		return ""
	}
	// 1. Foundations: waste top first, then each tableau top.
	if len(g.waste) > 0 && g.autoFound(loc{kind: locWaste}, len(g.waste)-1) {
		return "auto waste->found"
	}
	for p := 0; p < 7; p++ {
		if n := len(g.tab[p]); n > 0 && g.autoFound(loc{kind: locTab, pile: p}, n-1) {
			return "auto " + pileName(loc{kind: locTab, pile: p}) + "->found"
		}
	}
	// 2. Waste top onto any legal tableau pile.
	if len(g.waste) > 0 {
		c := g.waste[len(g.waste)-1]
		for p := 0; p < 7; p++ {
			if g.canTableau(c, p) {
				g.move(loc{kind: locWaste}, len(g.waste)-1,
					loc{kind: locTab, pile: p})
				return "auto waste->" + pileName(loc{kind: locTab, pile: p})
			}
		}
	}
	// 3. A tableau run that exposes a face-down card. Iterating every
	// face-up root (not just the shallowest) keeps the search total:
	// when the deepest run cannot land, a covered sub-run still might.
	for s := 0; s < 7; s++ {
		p := g.tab[s]
		for idx := 0; idx < len(p); idx++ {
			if !p[idx].Up {
				continue
			}
			if idx == 0 {
				break // fully face-up pile: nothing here to expose
			}
			for d := 0; d < 7; d++ {
				if d != s && g.canDrop(loc{kind: locTab, pile: s}, idx,
					loc{kind: locTab, pile: d}) {
					g.move(loc{kind: locTab, pile: s}, idx,
						loc{kind: locTab, pile: d})
					return "auto " + pileName(loc{kind: locTab, pile: s}) +
						"->" + pileName(loc{kind: locTab, pile: d})
				}
			}
		}
	}
	// 4. Nothing moves: pass the stock (a draw or a recycle — both are
	// moves). Only a truly empty stock+waste means the game is stuck.
	if len(g.stock)+len(g.waste) > 0 {
		if _, recycled := g.drawStock(); recycled {
			return "auto recycle"
		}
		return "auto draw"
	}
	return ""
}
