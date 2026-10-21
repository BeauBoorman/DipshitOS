// M145b (issue #2797): the table painter. Everything draws through the
// bound widgets.Canvas — FillRoundedRect degrades to flat fills on the
// FillerCanvas path, and the rank text and suit pips are the project's own
// 8x8 face plus four 7x7 bitmaps, so no TrueType face is required.
//
// Z-order is the contract: felt, slots, piles, then the dragged run LAST
// and at the pointer — the run is suppressed at home while it flies, which
// is what "shows it under the pointer" means in pixels.
package main

import (
	"virelai/draw"
	"virelai/theme"
	"virelai/webrender/font"
	"virelai/widgets"
)

// The table's own palette. The felt and slots ride theme.Current so the
// app follows the desktop; card faces and inks are fixed — a playing card
// is white with red or black ink in every theme.
const (
	cardFace = 0xf6f3ec
	cardEdge = 0x2a3138
	inkBlack = 0x232a31
	inkRed   = 0xb3322c
	statusCl = 0x9fb4c0
)

// suitBmp is one 7x7 suit glyph — bit 0 is the leftmost pixel, the same
// convention the 8x8 face uses.
var suitBmp = [4][7]byte{
	{0x08, 0x1c, 0x3e, 0x7f, 0x3e, 0x08, 0x1c}, // spade
	{0x36, 0x7f, 0x7f, 0x3e, 0x1c, 0x08, 0x00}, // heart
	{0x08, 0x1c, 0x3e, 0x7f, 0x3e, 0x1c, 0x08}, // diamond
	{0x1c, 0x3e, 0x6b, 0x7f, 0x3e, 0x08, 0x1c}, // club
}

// fill is the one paint entry point: a clamped rect on the bound canvas.
// The palette is 24-bit theme-token style; the bound BufferCanvas is an
// ARGB compositor, so every colour goes out Opaque (the M145c fix — a
// 0x00RRGGBB token blended nothing: the whole table stayed the surface's
// zero pages, observed black in the go-games VM legs).
func (b *board) fill(c widgets.Canvas, r widgets.Rect, rgb uint32) {
	if r.Empty() || r.X < 0 || r.Y < 0 {
		return
	}
	c.FillRect(r, draw.Opaque(rgb))
}

// text paints a string in the 8x8 face at scale 1 — the same glyph-run
// fill discipline NOTE uses, so status text works on both canvas paths.
func (b *board) text(c widgets.Canvas, x, y int, s string, rgb uint32) {
	cx := x
	for _, ch := range s {
		g := font.Glyph8(ch)
		for row := 0; row < 8; row++ {
			bits := g[row]
			for col := 0; col < 8; {
				if bits&(1<<uint(col)) == 0 {
					col++
					continue
				}
				run := 1
				for col+run < 8 && bits&(1<<uint(col+run)) != 0 {
					run++
				}
				b.fill(c, widgets.Rect{X: cx + col, Y: y + row, W: run, H: 1}, rgb)
				col += run
			}
		}
		cx += font.Advance(1)
	}
}

// suit paints a card's suit pip at (x, y).
func (b *board) suit(cvs widgets.Canvas, x, y int, suit uint8, rgb uint32) {
	if suit > SuitClubs {
		return
	}
	bm := suitBmp[suit]
	for row := 0; row < 7; row++ {
		for col := 0; col < 7; {
			if bm[row]&(1<<uint(col)) == 0 {
				col++
				continue
			}
			run := 1
			for col+run < 7 && bm[row]&(1<<uint(col+run)) != 0 {
				run++
			}
			b.fill(cvs, widgets.Rect{X: x + col, Y: y + row, W: run, H: 1}, rgb)
			col += run
		}
	}
}

// cardInk is the face ink by color — red suits and black suits.
func cardInk(c Card) uint32 {
	if c.Red() {
		return inkRed
	}
	return inkBlack
}

// card paints one card face up at (x, y): rounded white face, a border,
// the rank in the top corner and its suit pip below. The corner pair is
// how a fanned run stays readable — only the strip shows, and the strip
// carries the card's name.
func (b *board) card(cvs widgets.Canvas, c Card, x, y int) {
	r := widgets.Rect{X: x, Y: y, W: cardW, H: cardH}
	cvs.FillRoundedRect(r, 5, draw.Opaque(cardFace))
	cvs.StrokeRoundedRect(r, 5, 1, draw.Opaque(cardEdge))
	ink := cardInk(c)
	b.text(cvs, x+4, y+3, c.rankText(), ink)
	b.suit(cvs, x+4, y+13, c.Suit, ink)
	// The corner pair repeats bottom-right, small, so a card covered to
	// its last strip still names itself.
	b.suit(cvs, x+cardW-11, y+cardH-11, c.Suit, ink)
}

// back paints a face-down card — the theme accent with an inner rule, the
// table's one themed card surface.
func (b *board) back(cvs widgets.Canvas, x, y int) {
	r := widgets.Rect{X: x, Y: y, W: cardW, H: cardH}
	tok := theme.Current
	cvs.FillRoundedRect(r, 5, draw.Opaque(tok.Accent))
	cvs.StrokeRoundedRect(r, 5, 1, draw.Opaque(cardEdge))
	cvs.StrokeRoundedRect(r.Inset(4), 3, 1, draw.Opaque(tok.OnAccent))
}

// slot paints an empty pile's outline — a frame on the felt, nothing more.
func (b *board) slot(cvs widgets.Canvas, r widgets.Rect) {
	tok := theme.Current
	cvs.FillRoundedRect(r, 5, draw.Opaque(tok.Surface))
	cvs.StrokeRoundedRect(r, 5, 1, draw.Opaque(tok.Border))
}

// skip reports whether (l, idx) is inside the dragged run — those cards
// are suppressed at home because they are painted at the pointer.
func (b *board) skip(l loc, idx int) bool {
	return b.on && b.src == l && idx >= b.idx
}

// draw paints the whole frame. The dragged run goes last, on top.
func (b *board) draw(cvs widgets.Canvas, w, h int) {
	tok := theme.Current
	b.fill(cvs, widgets.Rect{X: 0, Y: 0, W: w, H: h}, tok.Bg)

	// The top row: stock, waste, foundations.
	if len(b.g.stock) == 0 {
		b.slot(cvs, stockRect())
	} else {
		b.back(cvs, stockRect().X, stockRect().Y)
	}
	wr := wasteRect()
	wn := len(b.g.waste)
	if wn == 0 {
		b.slot(cvs, wr)
	} else {
		shown := wn
		if shown > fanWaste {
			shown = fanWaste
		}
		for k := 0; k < shown; k++ {
			idx := wn - shown + k
			if b.skip(loc{kind: locWaste}, idx) {
				continue
			}
			b.card(cvs, b.g.waste[idx], wr.X+k*fanStep, wr.Y)
		}
	}
	for s := 0; s < 4; s++ {
		fr := foundRect(s)
		p := b.g.found[s]
		if len(p) == 0 || b.skip(loc{kind: locFound, pile: s}, len(p)-1) {
			b.slot(cvs, fr)
		} else {
			b.card(cvs, p[len(p)-1], fr.X, fr.Y)
		}
	}

	// The seven tableaus, fanned down.
	for p := 0; p < 7; p++ {
		tr := tabRect(p)
		pile := b.g.tab[p]
		if len(pile) == 0 {
			b.slot(cvs, tr)
			continue
		}
		ys := b.g.tabFan(p)
		for i, c := range pile {
			if b.skip(loc{kind: locTab, pile: p}, i) {
				continue
			}
			if c.Up {
				b.card(cvs, c, tr.X, ys[i])
			} else {
				b.back(cvs, tr.X, ys[i])
			}
		}
	}

	// The dragged run, at the pointer — last, so nothing paints over it.
	if run := b.dragRun(); len(run) > 0 {
		dx, dy := b.dragPos()
		for i, c := range run {
			b.card(cvs, c, dx, dy+i*upOff)
		}
	}

	// The status line: seed, mode and the two chords a gate can name.
	b.fill(cvs, widgets.Rect{X: 0, Y: h - statusH, W: w, H: statusH}, tok.Surface)
	b.text(cvs, marginX, h-statusH+3,
		"seed "+uitoa(b.g.seed)+"  draw-"+itoa(b.g.draw)+
			"  moves "+itoa(b.g.moves)+"  [n]ew [d]raw [u]ndo", statusCl)
}

// uitoa is itoa's u64 sibling for the seed field.
func uitoa(v uint64) string {
	if v == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[i:])
}
