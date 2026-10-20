// M145b (issue #2797): the table's geometry. Every pixel rule lives here
// once — the renderer paints from these rects and the pointer machine
// hit-tests against them, so a card is always grabbed where it was drawn
// (the widgets package's load-bearing rule, applied to a table instead of
// a control).
package main

import "virelai/widgets"

const (
	cardW = 56
	cardH = 80

	marginX  = 16
	topY     = 12
	pileGap  = 16
	tabY0    = topY + cardH + pileGap // 108
	statusH  = 14
	fanWaste = 3 // waste shows up to this many cards, fanned right
	fanStep  = 12

	downOff = 8  // a face-down card's exposed strip
	upOff   = 18 // a face-up card's exposed strip, before the area squeeze
	upOffLo = 8  // the squeeze's floor — below this a pile just overflows
)

// stockRect, wasteRect, foundRect, tabRect are the pile frames at the
// native 512x384 canvas. The layout is fixed-size: on a resized window the
// table sits top-left, the same fixed-point discipline the other apps keep
// (rects are cheap enough that scale would only blur the pixel probes).
func stockRect() widgets.Rect { return widgets.Rect{X: marginX, Y: topY, W: cardW, H: cardH} }
func wasteRect() widgets.Rect {
	return widgets.Rect{X: marginX + cardW + pileGap, Y: topY, W: cardW, H: cardH}
}

// foundRect slots the four foundations right-aligned, suit order left to
// right (spades, hearts, diamonds, clubs).
func foundRect(suit int) widgets.Rect {
	x0 := 512 - marginX - 4*cardW - 3*pileGap
	return widgets.Rect{X: x0 + suit*(cardW+pileGap), Y: topY, W: cardW, H: cardH}
}

// tabRect is tableau pile p's frame. The seven columns are centered in the
// canvas: 7 cards + 6 gaps = 476 px, leaving an 18 px left edge.
func tabRect(p int) widgets.Rect {
	x0 := (512 - (7*cardW + 6*14)) / 2
	return widgets.Rect{X: x0 + p*(cardW+14), Y: tabY0, W: cardW, H: cardH}
}

// tabAreaH is the vertical room a tableau pile may fan into before the
// status line.
func tabAreaH() int { return 384 - tabY0 - statusH - 4 }

// tabFan computes pile p's card tops: face-down cards get downOff, face-up
// cards get an offset that squeezes toward upOffLo when the pile would
// overflow the tableau area. Returns one y per card.
func (g *Game) tabFan(p int) []int {
	pile := g.tab[p]
	n := len(pile)
	ys := make([]int, n)
	if n == 0 {
		return ys
	}
	// Up cards are contiguous at the top of the pile by the rules of the
	// game, but count rather than assume — a restored table must render
	// whatever it was handed.
	up := 0
	for _, c := range pile {
		if c.Up {
			up++
		}
	}
	off := upOff
	if up > 0 {
		room := tabAreaH() - cardH - (n-up)*downOff
		if room/up < off {
			off = room / up
			if off < upOffLo {
				off = upOffLo
			}
		}
	}
	y := tabY0
	for i := range pile {
		ys[i] = y
		if pile[i].Up {
			y += off
		} else {
			y += downOff
		}
	}
	return ys
}

// hitLoc resolves a point to a pile — the coarse half of the pointer
// machine: press uses hitCard for the exact card; drop uses this to name
// the destination pile.
func (b *board) hitLoc(x, y int) (loc, bool) {
	if stockRect().Contains(x, y) {
		return loc{kind: locStock}, true
	}
	// The waste's hit frame is widened for the fan: the top card sits up
	// to (fanWaste-1)*fanStep right of the pile frame, and a press on the
	// visible part must still find it.
	wr := wasteRect()
	wr.W += (fanWaste - 1) * fanStep
	if wr.Contains(x, y) {
		return loc{kind: locWaste}, true
	}
	for s := 0; s < 4; s++ {
		if foundRect(s).Contains(x, y) {
			return loc{kind: locFound, pile: s}, true
		}
	}
	if y >= tabY0 {
		for p := 0; p < 7; p++ {
			r := tabRect(p)
			if x >= r.X && x < r.Right() {
				return loc{kind: locTab, pile: p}, true
			}
		}
	}
	return loc{}, false
}

// hitCard resolves a point to an exact card: (loc, idx) where idx is the
// index inside its pile. A point can sit on a pile without sitting on a
// card (an empty slot, felt below the pile's bottom, a fanned-under waste
// card) — those report ok=false, which is how a press on empty felt stays
// dead while a drop on the pile's floor still lands.
func (b *board) hitCard(x, y int) (loc, int, bool) {
	l, ok := b.hitLoc(x, y)
	if !ok {
		return loc{}, 0, false
	}
	switch l.kind {
	case locWaste:
		// The waste fans its last cards right; only the top card carries.
		n := len(b.g.waste)
		if n == 0 {
			return l, 0, false
		}
		r := wasteRect()
		top := n - 1
		shown := n
		if shown > fanWaste {
			shown = fanWaste
		}
		tx := r.X + (shown-1)*fanStep
		if x >= tx && x < tx+cardW && y >= r.Y && y < r.Y+cardH {
			return l, top, true
		}
		return l, 0, false
	case locFound:
		if len(b.g.found[l.pile]) == 0 {
			return l, 0, false
		}
		return l, len(b.g.found[l.pile]) - 1, true
	case locTab:
		pile := b.g.tab[l.pile]
		if len(pile) == 0 {
			return l, 0, false
		}
		ys := b.g.tabFan(l.pile)
		for i := len(pile) - 1; i >= 0; i-- {
			// Card i's hit strip runs from its own top to the next card's
			// top — the covered part belongs to the card above. The pile's
			// top card owns its full height.
			lo := ys[i]
			hi := lo + cardH
			if i+1 < len(pile) {
				hi = ys[i+1]
			}
			if y >= lo && y < hi {
				return l, i, true
			}
		}
		return l, 0, false
	}
	return l, 0, false
}
