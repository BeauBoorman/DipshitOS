// Class-A coverage for the save_state codec: a full-table round trip and
// the refusal table — a torn, stale or non-deck blob is refused wholesale.
package main

import "testing"

func TestStateRoundTrip(t *testing.T) {
	g := newGame(77, 3)
	// Move the table off its fresh-deal shape so the round trip has
	// something to carry: draws, a recycle, a couple of moves.
	for i := 0; i < 5; i++ {
		g.drawStock()
	}
	// Find a legal waste->foundation or tab move if one exists; at minimum
	// the draws already count as moves.
	blob := g.encodeState()
	d, ok := decodeState(blob)
	if !ok {
		t.Fatal("round trip refused its own encode")
	}
	if d.draw != 3 || d.seed != 77 || d.moves != g.moves || d.won != g.won {
		t.Fatalf("scalars: draw=%d seed=%d moves=%d won=%v",
			d.draw, d.seed, d.moves, d.won)
	}
	got, want := dealShape(d), dealShape(g)
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("card %d: %+v vs %+v", i, got[i], want[i])
		}
	}
	// v2: the undo stack rides the blob — the five draws left five
	// snapshots, and the restored table undoes them in order.
	if d.undoDepth() != 5 {
		t.Fatalf("restored undo depth %d, want 5", d.undoDepth())
	}
	if !d.Undo() || d.undoDepth() != 4 {
		t.Fatalf("undo on the restored table failed: depth=%d", d.undoDepth())
	}
	g.Undo()
	got = dealShape(d)
	want = dealShape(g)
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("post-undo card %d: %+v vs %+v", i, got[i], want[i])
		}
	}
}

// A v1 blob — the M145b format, nothing after the pile runs — still
// decodes under the v2 codec: the tail fields default to a fresh record.
func TestStateV1BlobDecodes(t *testing.T) {
	g := newGame(41, 1)
	for i := 0; i < 3; i++ {
		g.drawStock()
	}
	v2 := g.encodeState()
	// v1's length: the header plus each pile's (1+n) run.
	v1Len := stateHdr
	for _, p := range [][]Card{g.stock, g.waste, g.found[0], g.found[1],
		g.found[2], g.found[3], g.tab[0], g.tab[1], g.tab[2], g.tab[3],
		g.tab[4], g.tab[5], g.tab[6]} {
		v1Len += 1 + len(p)
	}
	v1 := append([]byte{}, v2[:v1Len]...)
	v1[0] = 1
	d, ok := decodeState(v1)
	if !ok {
		t.Fatal("v1 blob refused")
	}
	if d.moves != g.moves || d.undoDepth() != 0 || d.stats != (gameStats{}) ||
		d.elapsed != 0 || d.winCounted {
		t.Fatalf("v1 decode carried v2 state: moves=%d depth=%d stats=%+v",
			d.moves, d.undoDepth(), d.stats)
	}
	got, want := dealShape(d), dealShape(g)
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("v1 card %d: %+v vs %+v", i, got[i], want[i])
		}
	}
}

// The stats line and the clock ride the blob verbatim.
func TestStateStatsRoundTrip(t *testing.T) {
	g := newGame(5, 1)
	g.elapsed = 93
	g.stats = gameStats{played: 4, won: 2, streak: 2, best: 61}
	g.winCounted = true
	d, ok := decodeState(g.encodeState())
	if !ok {
		t.Fatal("stats blob refused")
	}
	if d.elapsed != 93 || d.stats != g.stats || !d.winCounted {
		t.Fatalf("stats: elapsed=%d stats=%+v counted=%v",
			d.elapsed, d.stats, d.winCounted)
	}
}

// The undo history's own tables are held to the same deck check: a torn
// card inside a serialized snapshot refuses the whole blob.
func TestStateTornUndoStep(t *testing.T) {
	g := newGame(8, 1)
	for i := 0; i < 3; i++ {
		g.drawStock()
	}
	blob := g.encodeState()
	// Flip a rank bit in the blob's last byte — a card byte inside the
	// final undo step's last pile run. Every rank+suit pair in a valid
	// table appears exactly once, so any changed rank either leaves the
	// 1..13 band (decCard refuses) or duplicates another card (the deck
	// check refuses).
	bad := append([]byte{}, blob...)
	bad[len(bad)-1] ^= 0x01
	if _, ok := decodeState(bad); ok {
		t.Fatal("torn last undo step accepted")
	}
}

func TestStateRoundTripMidGame(t *testing.T) {
	var found [4][]Card
	var tab [7][]Card
	found[1] = []Card{up(1, 1), up(2, 1)}
	tab[0] = []Card{down(9, 2), up(7, 1)}
	tab[3] = []Card{up(13, 0)}
	// Fill the remaining 49 cards so the deck check passes.
	var rest []Card
	used := map[Card]bool{}
	for _, c := range append(append(append([]Card{}, found[1]...), tab[0]...), tab[3]...) {
		used[Card{Rank: c.Rank, Suit: c.Suit}] = true
	}
	var tab2 [7][]Card
	copy(tab2[:], tab[:])
	dk := deck()
	for _, c := range dk {
		if !used[Card{Rank: c.Rank, Suit: c.Suit}] {
			rest = append(rest, c)
		}
	}
	g := table(rest, nil, found, tab2)
	g.moves = 9
	blob := g.encodeState()
	d, ok := decodeState(blob)
	if !ok {
		t.Fatal("mid-game encode refused")
	}
	if d.moves != 9 || len(d.stock) != 47 || len(d.found[1]) != 2 {
		t.Fatalf("mid-game scalars: moves=%d stock=%d found1=%d",
			d.moves, len(d.stock), len(d.found[1]))
	}
	got, want := dealShape(d), dealShape(g)
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("card %d: %+v vs %+v", i, got[i], want[i])
		}
	}
}

func TestStateRefusals(t *testing.T) {
	g := newGame(4, 1)
	good := g.encodeState()

	cases := []struct {
		name string
		blob []byte
	}{
		{"empty", nil},
		{"short", good[:10]},
		{"bad version", mut(good, 0, 9)},
		{"bad draw", mut(good, 1, 2)},
		{"trailing byte", append(append([]byte{}, good...), 0)},
		{"bad rank", mut(good, stateHdr+1, 0x80|0)},  // stock[0] rank 0
		{"bad rank hi", mut(good, stateHdr+1, 0x8e)}, // rank 14
	}
	for _, tc := range cases {
		if _, ok := decodeState(tc.blob); ok {
			t.Fatalf("%s: accepted", tc.name)
		}
	}

	// A duplicated card: overwrite stock[1]'s byte with stock[0]'s.
	dup := append([]byte{}, good...)
	dup[stateHdr+2] = dup[stateHdr+1]
	if _, ok := decodeState(dup); ok {
		t.Fatal("duplicated card accepted")
	}

	// A missing card: drop tab6's last card byte and shrink its length
	// byte to match — the blob stays structurally consistent but is a
	// 51-card table, which the deck permutation check must refuse.
	short := append([]byte{}, good[:len(good)-1]...)
	short[len(short)-7]-- // tab6's length byte (7 cards -> 6)
	if _, ok := decodeState(short); ok {
		t.Fatal("51-card table accepted")
	}
}

// mut returns a copy of b with position i set to v.
func mut(b []byte, i int, v byte) []byte {
	out := append([]byte{}, b...)
	out[i] = v
	return out
}
