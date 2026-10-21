// M152d (issue #2918): the session stats line. Played/won/streak/best is
// a per-SESSION record, not a per-deal one — deal() carries it across
// fresh deals and encodeState carries it through the blob, so it survives
// snapshot/restore but not a fresh launch (GOSOL has no `file` grant;
// that is the card's named limitation, not a bug).
//
//	played — every fresh deal counts, the first included; a restore is
//	         not a new play and does not increment it.
//	won    — deals that latched the win, once each (winCounted).
//	streak — consecutive wins; a deal that replaces an unwon game — an
//	         abandonment — resets it. Dealing over a won game keeps it.
//	best   — shortest elapsed seconds at the win latch; 0 = no win yet.
package main

// gameStats is the four-counter record that rides the blob.
type gameStats struct {
	played uint32
	won    uint32
	streak uint32
	best   uint64 // seconds; 0 = none
}

// line is the marker body after `gosol: stats ` — best prints '-' until
// a first win lands, so an all-zero line is honest rather than "best=0".
func (s gameStats) line() string {
	b := "-"
	if s.best > 0 {
		b = uitoa(s.best)
	}
	return "played=" + uitoa(uint64(s.played)) +
		" won=" + uitoa(uint64(s.won)) +
		" streak=" + uitoa(uint64(s.streak)) +
		" best=" + b
}

// inherit moves the record onto a fresh deal: the counters carry, the
// streak dies with an abandoned (unwon) game, and the new deal counts as
// played. A restore does NOT go through here — the blob's stats load
// verbatim instead.
func (s gameStats) inherit(prevWon bool) gameStats {
	if !prevWon {
		s.streak = 0
	}
	s.played++
	return s
}
