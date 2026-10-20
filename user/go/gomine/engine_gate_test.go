package main

import "testing"

// The go-games.spec class-B leg drives THIS exact move sequence over
// synthetic pointer input: seed 1, beginner board. If the engine ever
// changes the move results, both this test and the gate's serial asserts
// fail together — the two are pinned to the same truth.
func TestGateScriptedPath(t *testing.T) {
	b := NewBoard(0, 1)

	n, boom := b.Reveal(4, 4)
	if boom || n != 52 {
		t.Fatalf("reveal 4,4: n=%d boom=%v, want n=52", n, boom)
	}
	for _, f := range [][2]int{{3, 0}, {3, 1}} {
		if _, on := b.ToggleFlag(f[0], f[1]); !on {
			t.Fatalf("flag %v did not set", f)
		}
	}
	if n, _ := b.Reveal(4, 0); n != 1 {
		t.Fatalf("reveal 4,0: n=%d, want 1", n)
	}
	if n, boom := b.Chord(4, 0); boom || n != 14 {
		t.Fatalf("chord 4,0: n=%d boom=%v, want n=14", n, boom)
	}
	for _, c := range [][2]int{{8, 4}, {7, 5}, {8, 6}, {0, 7}} {
		if n, boom := b.Reveal(c[0], c[1]); boom || n != 1 {
			t.Fatalf("reveal %v: n=%d boom=%v, want n=1", c, n, boom)
		}
	}
	if !b.Won() {
		t.Fatalf("scripted path did not win: state=%d rev=%d", b.State(), b.RevealedN())
	}
	if b.MineLeft() != 0 {
		t.Fatalf("win left %d mines unflagged", b.MineLeft())
	}
}

// The loss leg's move sequence: same seed, reveal the centre flood then
// step on (2,5), a mine.
func TestGateLossPath(t *testing.T) {
	b := NewBoard(0, 1)
	b.Reveal(4, 4)
	if !b.Mine(2, 5) {
		t.Fatal("(2,5) is not a mine on seed 1 — spec script is stale")
	}
	if _, boom := b.Reveal(2, 5); !boom || !b.Dead() {
		t.Fatalf("loss path: boom=%v state=%d", boom, b.State())
	}
}
