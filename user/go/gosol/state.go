// M145b (issue #2797): the save_state blob — the full table in one versioned
// envelope, following the files/session.go contract (the app owns the format,
// the seat stores it verbatim, decode is total and refuses wholesale).
//
//	u8  ver        — stateFmtVer; also Config.StateVersion
//	u8  draw       — 1 or 3
//	u64 seed LE    — the deal's shuffle seed
//	u32 moves LE
//	u8  won        — the latched flag, so a saved win still says so
//	13 pile runs in fixed order — stock, waste, found[0..3], tab[0..6]:
//	  u8 n | n card bytes
//	card byte: up<<7 | suit<<4 | rank (rank 1..13, so bits 6..5 are free
//	and a byte is always one card)
//
// Every card keeps its real rank+suit even face down — "keeps the full
// table" means the table, not the visible subset. ~68 bytes total, far
// under the seat's 64 KiB cap.
package main

// stateFmtVer is the blob's format version — both the envelope's appver tag
// and the payload's first byte.
const stateFmtVer = 1

// stateHdr is the fixed run before the piles: ver + draw + seed + moves +
// won.
const stateHdr = 1 + 1 + 8 + 4 + 1

// statePiles is the fixed pile order: stock, waste, the four foundations,
// the seven tableaus.
const statePiles = 13

func putU32(b []byte, v uint32) {
	b[0], b[1], b[2], b[3] = byte(v), byte(v>>8), byte(v>>16), byte(v>>24)
}

func getU32(b []byte) uint32 {
	return uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
}

func putU64(b []byte, v uint64) {
	for i := 0; i < 8; i++ {
		b[i] = byte(v >> (8 * uint(i)))
	}
}

func getU64(b []byte) uint64 {
	var v uint64
	for i := 7; i >= 0; i-- {
		v = v<<8 | uint64(b[i])
	}
	return v
}

// encCard packs one card into its byte. Rank is 4 bits; a zero byte can
// only come from a torn blob, so decode need not special-case it.
func encCard(c Card) byte {
	u := byte(0)
	if c.Up {
		u = 0x80
	}
	return u | c.Suit<<4 | c.Rank
}

// decCard is encCard's inverse with the card-validity check: rank 1..13,
// suit 0..3.
func decCard(b byte) (Card, bool) {
	c := Card{Rank: b & 0x0f, Suit: (b >> 4) & 0x03, Up: b&0x80 != 0}
	if c.Rank < 1 || c.Rank > 13 {
		return Card{}, false
	}
	return c, true
}

// encodeState serializes the table. Bounded by construction: 15 header
// bytes, 13 pile runs of (u8 n | n card bytes) — 80 bytes worst case.
func (g *Game) encodeState() []byte {
	out := make([]byte, stateHdr, stateHdr+statePiles+52)
	out[0] = stateFmtVer
	out[1] = byte(g.draw)
	putU64(out[2:], g.seed)
	putU32(out[10:], uint32(g.moves))
	if g.won {
		out[14] = 1
	}
	emit := func(p []Card) {
		out = append(out, byte(len(p)))
		for _, c := range p {
			out = append(out, encCard(c))
		}
	}
	emit(g.stock)
	emit(g.waste)
	for i := 0; i < 4; i++ {
		emit(g.found[i])
	}
	for i := 0; i < 7; i++ {
		emit(g.tab[i])
	}
	return out
}

// decodeState is encodeState's total inverse. ok=false refuses the whole
// blob: a wrong version or draw mode, a truncated or trailing pile run, an
// invalid card, or a table that is not a permutation of the 52-card deck —
// the strongest honest check "the full table" admits, and it catches every
// torn write a version bump does not.
func decodeState(b []byte) (*Game, bool) {
	if len(b) < stateHdr+statePiles || b[0] != stateFmtVer {
		return nil, false
	}
	if b[1] != 1 && b[1] != 3 {
		return nil, false
	}
	g := &Game{draw: int(b[1]), seed: getU64(b[2:]), moves: int(getU32(b[10:]))}
	g.won = b[14] != 0
	o := stateHdr
	var seen [52]bool
	read := func(dst *[]Card) bool {
		n := int(b[o])
		o++
		if len(b)-o < n {
			return false
		}
		p := make([]Card, n)
		for i := range p {
			c, ok := decCard(b[o+i])
			if !ok {
				return false
			}
			idx := int(c.Suit)*13 + int(c.Rank) - 1
			if seen[idx] {
				return false // a duplicated card is a torn blob, not a table
			}
			seen[idx] = true
			p[i] = c
		}
		o += n
		*dst = p
		return true
	}
	if !read(&g.stock) || !read(&g.waste) {
		return nil, false
	}
	for i := 0; i < 4; i++ {
		if !read(&g.found[i]) {
			return nil, false
		}
	}
	for i := 0; i < 7; i++ {
		if !read(&g.tab[i]) {
			return nil, false
		}
	}
	if o != len(b) {
		return nil, false
	}
	for i := range seen {
		if !seen[i] {
			return nil, false // a missing card is a torn blob too
		}
	}
	return g, true
}
