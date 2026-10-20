package main

import "testing"

func revealAll(t *testing.T, b *Board) {
	t.Helper()
	for y := 0; y < b.Rows; y++ {
		for x := 0; x < b.Cols; x++ {
			if !b.Mine(x, y) && !b.Revealed(x, y) {
				b.Reveal(x, y)
			}
		}
	}
}

func TestPlaceMinesCountAndFirstClickSafe(t *testing.T) {
	for s := 0; s < 3; s++ {
		b := NewBoard(s, 12345)
		// First click dead-centre: the cell and all neighbours must be clear.
		x, y := b.Cols/2, b.Rows/2
		b.Reveal(x, y)
		mines := 0
		for i := 0; i < b.Cols*b.Rows; i++ {
			if b.mine[i] {
				mines++
			}
		}
		if mines != b.Mines {
			t.Fatalf("size %d: placed %d mines, want %d", s, mines, b.Mines)
		}
		for dy := -1; dy <= 1; dy++ {
			for dx := -1; dx <= 1; dx++ {
				nx, ny := x+dx, y+dy
				if b.inside(nx, ny) && b.Mine(nx, ny) {
					t.Fatalf("size %d: mine at first-click neighbour (%d,%d)", s, nx, ny)
				}
			}
		}
	}
}

func TestSeededBoardDeterministic(t *testing.T) {
	a, c := NewBoard(0, 777), NewBoard(0, 777)
	d := NewBoard(0, 778)
	for _, b := range []*Board{a, c, d} {
		b.Reveal(0, 0)
	}
	for i := range a.mine {
		if a.mine[i] != c.mine[i] {
			t.Fatalf("same seed, different board at cell %d", i)
		}
	}
	diff := false
	for i := range a.mine {
		if a.mine[i] != d.mine[i] {
			diff = true
			break
		}
	}
	if !diff {
		t.Fatal("different seeds produced identical boards (suspicious)")
	}
}

func TestFloodFillOpensRegion(t *testing.T) {
	// Sweep seeds until a first click opens more than the clicked cell —
	// a beginner board has open regions for most seeds.
	for seed := int64(1); seed < 200; seed++ {
		b := NewBoard(0, seed)
		n, boom := b.Reveal(4, 4)
		if boom {
			t.Fatalf("seed %d: first click hit a mine", seed)
		}
		if n > 1 {
			return // region opened: flood fill verified
		}
		if n == 0 {
			t.Fatalf("seed %d: first reveal revealed nothing", seed)
		}
	}
	t.Fatal("no seed in 1..199 produced a flood-fill opening")
}

func TestFlagToggleAndRevealGuard(t *testing.T) {
	b := NewBoard(0, 42)
	b.Reveal(0, 0)
	var hx, hy = -1, -1
	for y := 0; y < b.Rows && hx < 0; y++ {
		for x := 0; x < b.Cols; x++ {
			if !b.Revealed(x, y) {
				hx, hy = x, y
				break
			}
		}
	}
	if hx < 0 {
		t.Skip("board fully revealed")
	}
	n, on := b.ToggleFlag(hx, hy)
	if !on || n != 1 {
		t.Fatalf("flag on: n=%d on=%v", n, on)
	}
	if got, _ := b.Reveal(hx, hy); got != 0 {
		t.Fatal("reveal opened a flagged cell")
	}
	n, on = b.ToggleFlag(hx, hy)
	if on || n != 0 {
		t.Fatalf("flag off: n=%d on=%v", n, on)
	}
}

func TestWinTable(t *testing.T) {
	b := NewBoard(0, 9)
	b.Reveal(0, 0)
	revealAll(t, b)
	if !b.Won() {
		t.Fatalf("all safe cells revealed but state=%d", b.State())
	}
	if b.MineLeft() != 0 {
		t.Fatalf("win did not auto-flag mines: left=%d", b.MineLeft())
	}
	// A won board refuses further reveals.
	if n, _ := b.Reveal(b.Cols-1, b.Rows-1); n != 0 {
		t.Fatal("won board accepted a reveal")
	}
}

func TestLossTable(t *testing.T) {
	b := NewBoard(0, 9)
	b.Reveal(0, 0)
	var mx, my = -1, -1
	for i, m := range b.mine {
		if m {
			mx, my = i%b.Cols, i/b.Cols
			break
		}
	}
	if mx < 0 {
		t.Fatal("no mines placed")
	}
	if _, boom := b.Reveal(mx, my); !boom || !b.Dead() {
		t.Fatalf("mine reveal: boom=%v state=%d", boom, b.State())
	}
}

func TestChordRevealsNeighbours(t *testing.T) {
	// Find a seed where some revealed cell is a satisfied number:
	// flag all its mined neighbours, chord, expect new reveals.
	for seed := int64(1); seed < 500; seed++ {
		b := NewBoard(0, seed)
		b.Reveal(4, 4)
		done := false
		for y := 0; y < b.Rows && !done; y++ {
			for x := 0; x < b.Cols; x++ {
				if !b.Revealed(x, y) || b.Adj(x, y) == 0 {
					continue
				}
				flags := 0
				hidden := 0
				for dy := -1; dy <= 1; dy++ {
					for dx := -1; dx <= 1; dx++ {
						nx, ny := x+dx, y+dy
						if !b.inside(nx, ny) || b.Revealed(nx, ny) {
							continue
						}
						hidden++
						if b.Mine(nx, ny) {
							if !b.Flagged(nx, ny) {
								b.ToggleFlag(nx, ny)
							}
							flags++
						}
					}
				}
				if flags != b.Adj(x, y) || flags == 0 || hidden == flags {
					continue
				}
				n, boom := b.Chord(x, y)
				if boom {
					t.Fatalf("seed %d: correct chord hit a mine", seed)
				}
				if n == 0 {
					t.Fatalf("seed %d: satisfied chord revealed nothing", seed)
				}
				return
			}
		}
	}
	t.Fatal("no seed produced a chordable cell")
}

func TestChordUnsatisfiedIsNoop(t *testing.T) {
	b := NewBoard(0, 9)
	b.Reveal(4, 4)
	for y := 0; y < b.Rows; y++ {
		for x := 0; x < b.Cols; x++ {
			if !b.Revealed(x, y) || b.Adj(x, y) == 0 {
				continue
			}
			if b.flagsAround(x, y) == b.Adj(x, y) {
				continue
			}
			if n, _ := b.Chord(x, y); n != 0 {
				t.Fatalf("unsatisfied chord at (%d,%d) revealed %d cells", x, y, n)
			}
			return
		}
	}
	t.Skip("no unsatisfied number cell on this board")
}

func TestSaveRoundTrip(t *testing.T) {
	b := NewBoard(1, 2026)
	b.Reveal(2, 3)
	b.ToggleFlag(0, 0)
	b.SetElapsed(95)
	blob := b.Save()
	if len(blob) == 0 {
		t.Fatal("empty save")
	}
	r, ok := LoadSave(blob)
	if !ok {
		t.Fatal("LoadSave refused a fresh save")
	}
	if r.Cols != b.Cols || r.Rows != b.Rows || r.Mines != b.Mines {
		t.Fatal("dims lost")
	}
	if r.Seed() != b.Seed() || r.Elapsed() != 95 {
		t.Fatalf("seed/elapsed lost: %d %d", r.Seed(), r.Elapsed())
	}
	if r.RevealedN() != b.RevealedN() || r.FlaggedN() != b.FlaggedN() {
		t.Fatal("counts lost")
	}
	for i := 0; i < b.Cols*b.Rows; i++ {
		x, y := i%b.Cols, i/b.Cols
		if r.Mine(x, y) != b.Mine(x, y) || r.Revealed(x, y) != b.Revealed(x, y) || r.Flagged(x, y) != b.Flagged(x, y) {
			t.Fatalf("cell (%d,%d) diverged after round-trip", x, y)
		}
		if r.Adj(x, y) != b.Adj(x, y) {
			t.Fatalf("adjacency rebuild wrong at (%d,%d)", x, y)
		}
	}
}

func TestSaveRoundTripWonBoard(t *testing.T) {
	b := NewBoard(0, 9)
	b.Reveal(0, 0)
	revealAll(t, b)
	if !b.Won() {
		t.Skip("not won")
	}
	r, ok := LoadSave(b.Save())
	if !ok || !r.Won() {
		t.Fatalf("won save: ok=%v state=%d", ok, r.State())
	}
}

func TestLoadSaveRefusesGarbage(t *testing.T) {
	if _, ok := LoadSave(nil); ok {
		t.Fatal("nil accepted")
	}
	if _, ok := LoadSave([]byte("junk")); ok {
		t.Fatal("short blob accepted")
	}
	b := NewBoard(0, 1)
	b.Reveal(0, 0)
	blob := b.Save()
	bad := append([]byte(nil), blob...)
	bad[4] = 9 // wrong version
	if _, ok := LoadSave(bad); ok {
		t.Fatal("bad version accepted")
	}
	trunc := blob[:len(blob)-2]
	if _, ok := LoadSave(trunc); ok {
		t.Fatal("truncated blob accepted")
	}
}

func TestFirstClickNeverAMineAcrossSeeds(t *testing.T) {
	// The acceptance rule as a table: every seed's first click is safe.
	for seed := int64(0); seed < 64; seed++ {
		for s := 0; s < 3; s++ {
			b := NewBoard(s, seed)
			if _, boom := b.Reveal(b.Cols/2, b.Rows/2); boom {
				t.Fatalf("seed %d size %d: first click hit a mine", seed, s)
			}
		}
	}
}
