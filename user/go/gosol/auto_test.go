// Class-A coverage for the 'a' key's auto-move: the priority order, the
// win it reaches on the pinned seed, the stats the win scores, and the
// chime's byte bounds.
package main

import (
	"testing"

	"virelai/vi"
)

// runAuto presses the auto key until the game is won or stuck, returning
// the presses (-1 on stuck/overrun). The bound keeps a regression loop
// honest.
func runAuto(g *Game, bound int) int {
	for i := 0; i < bound; i++ {
		if g.won {
			return i
		}
		if g.autoMove() == "" {
			return -1
		}
	}
	return -1
}

// Seed 59 (draw-1) is the spec's pinned winnable deal: the go-games
// run-06 leg types this same key into this same table, so the model must
// reach the win here first. 126 presses is today's count; the bound is
// generous so a legal-move-order change fails loudly, not silently.
func TestAutoSeed59Wins(t *testing.T) {
	g := newGame(59, 1)
	n := runAuto(g, 200)
	if n < 0 || !g.won {
		t.Fatalf("seed 59 did not win on the auto key (presses=%v)", n)
	}
	if g.moves != 126 {
		t.Fatalf("seed 59 won in %d moves, want 126 — the greedy order moved",
			g.moves)
	}
	if g.stats.won != 1 || !g.winCounted {
		t.Fatalf("win not scored: stats=%+v counted=%v", g.stats, g.winCounted)
	}
}

// The auto key never invents a move: a won table is a no-op, and a
// table with no legal move answers "" rather than mutating.
func TestAutoMoveHonestRefusal(t *testing.T) {
	// A latched win is a no-op — drive a real win so won is set.
	var found [4][]Card
	var tab [7][]Card
	for s := uint8(0); s < 3; s++ {
		for r := uint8(1); r <= 13; r++ {
			found[s] = append(found[s], up(r, s))
		}
	}
	for r := uint8(1); r <= 12; r++ {
		found[3] = append(found[3], up(r, 3))
	}
	tab[0] = []Card{up(13, 3)}
	g := table(nil, nil, found, tab)
	g.move(loc{kind: locTab, pile: 0}, 0, loc{kind: locFound, pile: 3})
	if !g.won {
		t.Fatal("setup: not won")
	}
	if g.autoMove() != "" {
		t.Fatal("auto-move acted on a won table")
	}
	// A stuck table: 3S can't found (A,2 missing) or build (needs a 4),
	// 5H can't found or build (needs a 6 of the other color); nothing
	// face-down to expose, no stock to pass.
	found = [4][]Card{}
	tab = [7][]Card{{down(9, 2), up(3, 0)}, {up(5, 1)}}
	g = table(nil, nil, found, tab)
	if g.autoMove() != "" {
		t.Fatal("auto-move invented a move on a stuck table")
	}
}

// The stats record: deal-scoring semantics through the model alone.
func TestStatsRecord(t *testing.T) {
	// A win scores once — undo past the win and re-win must not
	// double-count the deal.
	var found [4][]Card
	var tab [7][]Card
	for s := uint8(0); s < 3; s++ {
		for r := uint8(1); r <= 13; r++ {
			found[s] = append(found[s], up(r, s))
		}
	}
	for r := uint8(1); r <= 12; r++ {
		found[3] = append(found[3], up(r, 3))
	}
	tab[0] = []Card{up(13, 3)}
	g := table(nil, nil, found, tab)
	g.stats = gameStats{played: 1}
	g.elapsed = 45
	g.move(loc{kind: locTab, pile: 0}, 0, loc{kind: locFound, pile: 3})
	if !g.won || g.stats.won != 1 || g.stats.streak != 1 || g.stats.best != 45 {
		t.Fatalf("win mis-scored: %+v", g.stats)
	}
	// Undo back into play, re-win: still won=1.
	if !g.Undo() {
		t.Fatal("undo refused")
	}
	g.move(loc{kind: locTab, pile: 0}, 0, loc{kind: locFound, pile: 3})
	if g.stats.won != 1 || g.stats.streak != 1 {
		t.Fatalf("re-win double-counted: %+v", g.stats)
	}
	// A slower re-win never regresses the best time.
	if g.stats.best != 45 {
		t.Fatalf("best regressed: %+v", g.stats)
	}
	// inherit: abandoning an unwon game clears the streak, dealing over
	// a won one keeps it, every deal counts played.
	s := g.stats.inherit(false)
	if s.streak != 0 || s.played != g.stats.played+1 {
		t.Fatalf("inherit(unwon): %+v", s)
	}
	s = g.stats.inherit(true)
	if s.streak != g.stats.streak || s.played != g.stats.played+1 {
		t.Fatalf("inherit(won): %+v", s)
	}
}

// The chime's byte bound: at most 0.5 s of PCM at every negotiated
// rate, frame-aligned, non-silent, in the right format.
func TestChimeBounds(t *testing.T) {
	for _, rate := range []uint8{1, 3, 4, 5, 6, 7} {
		for _, format := range []uint8{vi.AudioFmtS16, vi.AudioFmtS32, vi.AudioFmtFloat} {
			for _, ch := range []uint8{1, 2} {
				info := vi.AudioInfo{Rate: rate, Format: format, Channels: ch}
				pcm := synthChime(info)
				fb, _ := chimeFrameBytes(format, ch)
				hz := chimeRateHz(rate)
				want := int(uint64(hz) * chimeMS / 1000) * fb
				if len(pcm) != want {
					t.Fatalf("rate=%d fmt=%d ch=%d: len %d, want %d",
						rate, format, ch, len(pcm), want)
				}
				// The 0.5 s bound: frames*1000 <= 500*hz.
				if int64(len(pcm))*1000 > int64(fb)*500*int64(hz) {
					t.Fatalf("chime over 0.5s: rate=%d len=%d", rate, len(pcm))
				}
				nonzero := false
				for _, b := range pcm {
					if b != 0 {
						nonzero = true
						break
					}
				}
				if !nonzero {
					t.Fatal("chime is all zeros")
				}
			}
		}
	}
	// Unencodable tuples refuse nil, not silence.
	if pcm := synthChime(vi.AudioInfo{Rate: 9, Format: vi.AudioFmtS16, Channels: 2}); pcm != nil {
		t.Fatal("bad rate synthesized")
	}
	if pcm := synthChime(vi.AudioInfo{Rate: 7, Format: 99, Channels: 2}); pcm != nil {
		t.Fatal("bad format synthesized")
	}
	if pcm := synthChime(vi.AudioInfo{Rate: 7, Format: vi.AudioFmtS16, Channels: 0}); pcm != nil {
		t.Fatal("zero channels synthesized")
	}
}

// settingsVolume: the muted row parses, and only as a real row.
func TestSettingsVolume(t *testing.T) {
	for _, tc := range []struct {
		blob string
		v    int
		ok   bool
	}{
		{"theme=dark\naudio_volume=0\n", 0, true},
		{"audio_volume=40", 40, true},
		{"x=1\naudio_volume=100\ny=2", 100, true},
		{"theme=dark\n", 0, false},
		{"audio_volume=\n", 0, false},
		{"my_audio_volume=0", 0, false},
	} {
		v, ok := settingsVolume([]byte(tc.blob))
		if v != tc.v || ok != tc.ok {
			t.Fatalf("%q: got %d,%v want %d,%v", tc.blob, v, ok, tc.v, tc.ok)
		}
	}
}
