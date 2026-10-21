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
// M152d (issue #2918): format 2 keeps the v1 section byte-identical and
// appends, in order:
//
//	u64 elapsed LE — the game's seconds; a restore resumes the clock
//	u32 played | u32 won | u32 streak | u64 best — the stats line
//	u8  winCounted — the deal's win already scored (undo+re-win cannot
//	               double-count)
//	u8  undoN, then undoN undo steps oldest→newest, each:
//	  u32 moves | u8 won | 13 pile runs (a complete 52-card table —
//	  every snapshot is checked against the deck permutation too)
//
// Every card keeps its real rank+suit even face down — "keeps the full
// table" means the table, not the visible subset. ~68 bytes for the bare
// table plus ~70 per undo step (~2.3 KB at the 32-step cap), far under
// the seat's 64 KiB cap. A v1 blob still decodes: the v1 section ends
// exactly where v1 did, and the extras default to a fresh record.
package main

// stateFmtVer is the blob's format version — both the envelope's appver tag
// and the payload's first byte. Decode accepts every version up to it.
const stateFmtVer = 2

// stateHdr is the fixed run before the piles: ver + draw + seed + moves +
// won.
const stateHdr = 1 + 1 + 8 + 4 + 1

// statePiles is the fixed pile order: stock, waste, the four foundations,
// the seven tableaus.
const statePiles = 13

// stateStatsLen is the v2 stats block: elapsed, the four counters, and
// the winCounted flag.
const stateStatsLen = 8 + 4 + 4 + 4 + 8 + 1

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
// bytes, 13 pile runs of (u8 n | n card bytes), the v2 stats block, and
// the undo stack — 15 + 29 + 32*(5+65) ≈ 2.3 KB worst case.
func (g *Game) encodeState() []byte {
	out := make([]byte, stateHdr, stateHdr+statePiles+52+stateStatsLen+1)
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
	emitPiles := func(s *snapshot) {
		emit(s.stock)
		emit(s.waste)
		for i := 0; i < 4; i++ {
			emit(s.found[i])
		}
		for i := 0; i < 7; i++ {
			emit(s.tab[i])
		}
	}
	// The live table serializes through the same run shape an undo step
	// uses, so v2's trailing section is one shape throughout.
	emitPiles(&snapshot{stock: g.stock, waste: g.waste, found: g.found, tab: g.tab})

	// v2 tail: the clock, the stats record, then the undo stack
	// oldest→newest so the restored game undoes its most recent move.
	tail := len(out)
	out = append(out, make([]byte, stateStatsLen+1)...)
	putU64(out[tail:], uint64(g.elapsed))
	putU32(out[tail+8:], g.stats.played)
	putU32(out[tail+12:], g.stats.won)
	putU32(out[tail+16:], g.stats.streak)
	putU64(out[tail+20:], g.stats.best)
	if g.winCounted {
		out[tail+28] = 1
	}
	out[tail+29] = byte(len(g.hist))
	for i := range g.hist {
		s := &g.hist[i]
		hdr := len(out)
		out = append(out, make([]byte, 5)...)
		putU32(out[hdr:], uint32(s.moves))
		if s.won {
			out[hdr+4] = 1
		}
		emitPiles(s)
	}
	return out
}

// decodeState is encodeState's total inverse. ok=false refuses the whole
// blob: a wrong version or draw mode, a truncated or trailing pile run, an
// invalid card, or a table that is not a permutation of the 52-card deck —
// the strongest honest check "the full table" admits, and it catches every
// torn write a version bump does not. Version 1 blobs end after the pile
// runs; version 2 continues into the stats + undo tail, each undo step
// held to the same full-deck check as the live table.
func decodeState(b []byte) (*Game, bool) {
	if len(b) < stateHdr+statePiles || b[0] == 0 || b[0] > stateFmtVer {
		return nil, false
	}
	ver := b[0]
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
	readPiles := func(s *snapshot) bool {
		seen = [52]bool{}
		if !read(&s.stock) || !read(&s.waste) {
			return false
		}
		for i := 0; i < 4; i++ {
			if !read(&s.found[i]) {
				return false
			}
		}
		for i := 0; i < 7; i++ {
			if !read(&s.tab[i]) {
				return false
			}
		}
		for i := range seen {
			if !seen[i] {
				return false // a missing card is a torn blob too
			}
		}
		return true
	}
	var s snapshot
	if !readPiles(&s) {
		return nil, false
	}
	g.stock, g.waste, g.found, g.tab = s.stock, s.waste, s.found, s.tab
	if ver == 1 {
		// A v1 blob ends here by contract; stats and history default to
		// a fresh record.
		return g, o == len(b)
	}
	// v2 tail: stats block, then undoN steps.
	if len(b)-o < stateStatsLen+1 {
		return nil, false
	}
	g.elapsed = int64(getU64(b[o:]))
	g.stats = gameStats{
		played: getU32(b[o+8:]),
		won:    getU32(b[o+12:]),
		streak: getU32(b[o+16:]),
		best:   getU64(b[o+20:]),
	}
	g.winCounted = b[o+28] != 0
	undoN := int(b[o+29])
	if undoN > undoCap {
		return nil, false
	}
	o += stateStatsLen + 1
	for i := 0; i < undoN; i++ {
		if len(b)-o < 5+statePiles {
			return nil, false
		}
		var st snapshot
		st.moves = int(getU32(b[o:]))
		st.won = b[o+4] != 0
		o += 5
		if !readPiles(&st) {
			return nil, false
		}
		g.hist = append(g.hist, st)
	}
	return g, o == len(b)
}
