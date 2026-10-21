// M145b (issue #2797): the in-surface pointer machine. It is a small state
// machine over press/move/release, deliberately free of vi so the class-A
// suite feeds it synthetic pointer sequences:
//
//	idle --down on stock--> (draw or recycle, stays idle)
//	idle --down on a draggable card--> armed   (grab offset recorded)
//	armed --move--> dragging                 (run follows the pointer)
//	armed --up--> idle                       (a click, no move)
//	dragging --up--> drop resolved           (legal: move; illegal: snap back)
//
// The dragged cards stay IN their source pile for the whole gesture — the
// table is never in a half-moved state, so a save_state ask landing
// mid-drag still serializes the full table, and an illegal drop is a
// no-op, not a repair. The renderer skips the dragged run at home and
// paints it under the pointer.
package main

import (
	"virelai/vi"
	"virelai/widgets"
)

// dblClickNs is the double-click window: two presses on the same card
// inside this span send it to the foundation.
const dblClickNs = 450 * 1000 * 1000

// nowNanos is the clock seam — vi.Nanos on the guest and host, a stub in
// tests so the double-click window is driven by script, not wall time.
var nowNanos = vi.Nanos

// board is the game's interactive half: the pointer machine's state plus
// the double-click bookkeeping. It owns no rendering — render.go reads it.
type board struct {
	g *Game

	// held reports a button is down; armed records the press's card (when
	// one was under the pointer) so a move can promote the gesture to a
	// drag. on is the drag itself.
	held bool
	arm  bool
	on   bool

	src    loc // where the dragged run came from
	idx    int // the run root's index inside src
	px, py int // the pointer's last position
	gx, gy int // grab offset: pointer minus the run root's frame

	// The last completed click's identity — a press on the same card
	// inside dblClickNs is the foundation gesture.
	lastLoc  loc
	lastIdx  int
	lastNs   int64
	haveLast bool

	// winSent latches the notify edge: the toast is raised once, on the
	// move that wins — a legal move over an already-won table (dragging a
	// king back out, say) does not toast again.
	winSent bool
}

// eff is one outcome of a pointer step — the strings are the app-level
// marker bodies main.go prints. Keeping the vocabulary here, one const per
// outcome, is what lets the class-A suite assert state-machine transitions
// without scraping serial lines.
type eff struct {
	dirty bool   // the frame changed
	note  string // a `gosol:` marker body, "" for none
	win   bool   // this step latched the win — main.go raises the notify
}

// down handles a left press. Stock resolves immediately (draw or recycle —
// the click IS the gesture, there is nothing to drag). A draggable card
// arms the machine; a press on the same card as the last completed click
// inside the window tries autoFound first — a successful double-click
// consumes the gesture and never arms.
func (b *board) down(x, y int) eff {
	b.held = true
	b.arm = false
	l, ok := b.hitLoc(x, y)
	if ok && l.kind == locStock {
		n, recycled := b.g.drawStock()
		switch {
		case recycled:
			return eff{dirty: true, note: "recycle n=" + itoa(len(b.g.stock))}
		case n > 0:
			return eff{dirty: true, note: "draw n=" + itoa(n)}
		}
		return eff{}
	}
	l, idx, ok := b.hitCard(x, y)
	if !ok || !b.g.draggable(l, idx) {
		return eff{}
	}
	// The double-click check reads the armed card's identity — the same
	// card in the same pile inside the window. Index equality keeps a
	// rebuilt pile honest (the "same" card at a new depth is a new click).
	if b.haveLast && b.lastLoc == l && b.lastIdx == idx &&
		nowNanos()-b.lastNs < dblClickNs {
		b.haveLast = false
		if b.g.autoFound(l, idx) {
			e := eff{dirty: true, note: "dbl " + pileName(l) + "[" + itoa(idx) +
				"] -> found moves=" + itoa(b.g.moves)}
			// The latch transitions here — e.win is only set on the edge,
			// never on a later move over an already-won table.
			e.win = b.g.won && !b.winSent
			b.winSent = b.winSent || b.g.won
			return e
		}
	}
	b.arm = true
	b.src = l
	b.idx = idx
	b.px, b.py = x, y
	r := b.cardRect(l, idx)
	b.gx, b.gy = x-r.X, y-r.Y
	return eff{}
}

// movePtr tracks the pointer while held. An armed press becomes a drag on
// the first held move — the card's "shows it under the pointer" without a
// threshold dead-zone, so a slow pull still lifts immediately.
func (b *board) movePtr(x, y int) eff {
	if !b.held {
		return eff{}
	}
	b.px, b.py = x, y
	if b.arm && !b.on {
		b.on = true
	}
	if b.on {
		return eff{dirty: true}
	}
	return eff{}
}

// auto is the 'a' key's outcome as a pointer-step-shaped eff: one greedy
// move (game.autoMove picks it), the win edge latched exactly the way the
// drag path latches it, so a key-won table toasts, scores and chimes
// identically to a pointer-won one.
func (b *board) auto() eff {
	note := b.g.autoMove()
	if note == "" {
		return eff{}
	}
	e := eff{dirty: true, note: note}
	e.win = b.g.won && !b.winSent
	b.winSent = b.winSent || b.g.won
	return e
}

// up completes the gesture. A live drag resolves its drop: the destination
// pile under the pointer is validated through canDrop, a legal drop lands
// as one move, anything else snaps back with the refusal named. A bare
// click only records the card for the double-click window.
func (b *board) up(x, y int) eff {
	b.held = false
	b.px, b.py = x, y
	if b.on {
		b.on = false
		b.arm = false
		dst, ok := b.dropTarget(x, y)
		if ok && b.g.canDrop(b.src, b.idx, dst) {
			src, idx := b.src, b.idx
			n := b.g.runLen(src, idx)
			b.g.move(src, idx, dst)
			e := eff{dirty: true,
				note: "move " + pileName(src) + "->" + pileName(dst) +
					" n=" + itoa(n) + " moves=" + itoa(b.g.moves)}
			e.win = b.g.won && !b.winSent
			b.winSent = b.winSent || b.g.won
			return e
		}
		return eff{dirty: true, note: "drop bad " + pileName(b.src)}
	}
	if b.arm {
		// A completed click: record the card for the double window. A drag
		// is deliberately NOT recorded — the gesture ended elsewhere and
		// must not prime a foundation hop for the next unrelated press.
		b.lastLoc, b.lastIdx = b.src, b.idx
		b.lastNs = nowNanos()
		b.haveLast = true
		b.arm = false
	}
	return eff{}
}

// dropTarget resolves a release point to the pile the run lands on.
// Foundation frames are exact (the card must come home to its slot); a
// tableau column accepts any point below the top row inside its x-span —
// dropping low in a fanned pile still means that pile.
func (b *board) dropTarget(x, y int) (loc, bool) {
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

// cardRect is the frame of one card in its home pile — where the pointer
// grabbed it. It answers the same question the renderer asks, so the run
// lifts from exactly the pixels it was painted on.
func (b *board) cardRect(l loc, idx int) widgets.Rect {
	switch l.kind {
	case locWaste:
		r := wasteRect()
		n := len(b.g.waste)
		shown := n
		if shown > fanWaste {
			shown = fanWaste
		}
		r.X += (shown - 1) * fanStep
		return r
	case locFound:
		return foundRect(l.pile)
	case locTab:
		r := tabRect(l.pile)
		r.Y = b.g.tabFan(l.pile)[idx]
		return r
	}
	return widgets.Rect{}
}

// dragRun returns the cards mid-flight — the source run b.src[b.idx:] —
// for the renderer, which suppresses them at home and paints them at the
// pointer.
func (b *board) dragRun() []Card {
	if !b.on {
		return nil
	}
	p := b.g.pileCards(b.src)
	if b.idx < 0 || b.idx >= len(p) {
		return nil
	}
	return p[b.idx:]
}

// dragPos is where the run's root card draws — the pointer minus the grab
// offset the press recorded.
func (b *board) dragPos() (int, int) { return b.px - b.gx, b.py - b.gy }

// pileName is the marker spelling of a pile.
func pileName(l loc) string {
	switch l.kind {
	case locStock:
		return "stock"
	case locWaste:
		return "waste"
	case locFound:
		return "found" + string(rune('0'+l.pile))
	case locTab:
		return "tab" + string(rune('0'+l.pile))
	}
	return "?"
}

// itoa is the package's small int spelling (the markers avoid strconv for
// the same image-budget reason the other apps do).
func itoa(v int) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	if neg {
		v = -v
	}
	var buf [20]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
