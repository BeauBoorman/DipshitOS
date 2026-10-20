// M145b (issue #2797): GOSOL.ELF's deck. A Card is three facts — rank 1..13
// (ace..king), suit, and whether it is face up — small enough to ride a
// save_state blob as one byte.
package main

// Suit order is the pack order: spades, hearts, diamonds, clubs. Red() is
// the only property Klondike legality reads off a suit.
const (
	SuitSpades   uint8 = 0
	SuitHearts   uint8 = 1
	SuitDiamonds uint8 = 2
	SuitClubs    uint8 = 3
)

// Card is one playing card. Rank 1 is the ace, 13 the king.
type Card struct {
	Rank uint8
	Suit uint8
	Up   bool
}

// Red reports the card's color: hearts and diamonds are red, the other two
// suits black. Klondike tableau builds alternate color.
func (c Card) Red() bool { return c.Suit == SuitHearts || c.Suit == SuitDiamonds }

// rankText is the face spelling: A, 2..10, J, Q, K.
func (c Card) rankText() string {
	switch c.Rank {
	case 1:
		return "A"
	case 11:
		return "J"
	case 12:
		return "Q"
	case 13:
		return "K"
	}
	if c.Rank == 10 {
		return "10"
	}
	if c.Rank >= 2 && c.Rank <= 9 {
		return string(rune('0' + c.Rank))
	}
	return "?"
}

// suitText is the suit's letter spelling — the 8x8 face covers ASCII only,
// so the glyph row is drawn from the small bitmap table in render.go and
// this letter is the serial/test spelling.
func (c Card) suitText() string {
	switch c.Suit {
	case SuitSpades:
		return "S"
	case SuitHearts:
		return "H"
	case SuitDiamonds:
		return "D"
	case SuitClubs:
		return "C"
	}
	return "?"
}

// String is the card's serial spelling — "AS", "10H", "KD" — used by the
// move markers and the tests. A face-down card is spelled "--" because its
// identity is not table information.
func (c Card) String() string {
	if !c.Up {
		return "--"
	}
	return c.rankText() + c.suitText()
}

// label is the face-up spelling regardless of Up — the state codec and the
// drag marker need the real identity, not the masked one.
func (c Card) label() string { return c.rankText() + c.suitText() }

// deck is a fresh 52-card pack in pack order, all face down. deal() shuffles
// it; nothing else constructs cards.
func deck() [52]Card {
	var d [52]Card
	for i := range d {
		d[i] = Card{Rank: uint8(i%13) + 1, Suit: uint8(i / 13)}
	}
	return d
}

// rng is the deal's deterministic source — a xorshift64* so a seeded deal is
// reproducible across host tests and guest runs without importing math/rand.
type rng struct{ s uint64 }

func newRng(seed uint64) rng {
	if seed == 0 {
		seed = 0x9e3779b97f4a7c15
	}
	return rng{s: seed}
}

func (r *rng) next() uint64 {
	r.s ^= r.s << 13
	r.s ^= r.s >> 7
	r.s ^= r.s << 17
	return r.s * 2685821657736338717
}

// shuffle is Fisher-Yates over the pack: 51 draws, each swapping position i
// with a uniform j >= i. Same seed, same deal — the card's promise.
func shuffle(d *[52]Card, seed uint64) {
	r := newRng(seed)
	for i := len(d) - 1; i > 0; i-- {
		j := int(r.next() % uint64(i+1))
		d[i], d[j] = d[j], d[i]
	}
}
