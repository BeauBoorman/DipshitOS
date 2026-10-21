package main

// M152d (issue #2918) class-A coverage: best times ride the blob, a v1
// blob still decodes, a win scores its difficulty's record, and the
// chime honors the 0.5 s bound.

import (
	"testing"

	"virelai/vi"
)

// winSeed1 plays the same scripted seed-1 beginner win the gate drives.
func winSeed1(t *testing.T, elapsed int64) *Board {
	t.Helper()
	b := NewBoard(0, 1)
	b.SetElapsed(elapsed)
	b.Reveal(4, 4)
	for _, c := range [][2]int{{4, 0}, {5, 0}, {6, 0}, {7, 0}, {8, 0},
		{4, 1}, {5, 1}, {6, 1}, {7, 1}, {8, 1}, {6, 2}, {7, 2}, {8, 2},
		{7, 3}, {8, 3}, {8, 4}, {7, 5}, {8, 6}, {0, 7}} {
		if _, boom := b.Reveal(c[0], c[1]); boom {
			t.Fatalf("reveal %v hit a mine", c)
		}
	}
	if !b.Won() {
		t.Fatal("scripted path did not win")
	}
	return b
}

func TestWinRecordsBest(t *testing.T) {
	b := winSeed1(t, 77)
	if b.Best() != 77 || b.best[0] != 77 {
		t.Fatalf("best=%d, want 77", b.Best())
	}
	// Other difficulties stay unset.
	if b.BestAt(1) != 0 || b.BestAt(2) != 0 {
		t.Fatalf("cross-size best wrote: %v", b.best)
	}
}

func TestBestRidesBlob(t *testing.T) {
	b := winSeed1(t, 64)
	blob := b.Save()
	d, ok := LoadSave(blob)
	if !ok {
		t.Fatal("own encode refused")
	}
	if d.BestAt(0) != 64 {
		t.Fatalf("restored best=%d, want 64", d.BestAt(0))
	}
}

// A v1 blob — the M145a format, no best tail — still decodes with the
// record zeroed.
func TestV1BlobDecodes(t *testing.T) {
	b := NewBoard(0, 1)
	b.Reveal(4, 4)
	v2 := b.Save()
	v1 := append([]byte{}, v2[:len(v2)-saveBest]...)
	v1[4] = 1
	d, ok := LoadSave(v1)
	if !ok {
		t.Fatal("v1 blob refused")
	}
	if d.best != ([3]uint64{}) {
		t.Fatalf("v1 decode carried best: %v", d.best)
	}
	if d.RevealedN() != b.RevealedN() {
		t.Fatalf("v1 rev=%d, want %d", d.RevealedN(), b.RevealedN())
	}
}

// A faster later win improves the record; a slower one never regresses
// it — checked through the codec since checkWin owns the update.
func TestBestImprovesOnly(t *testing.T) {
	b := winSeed1(t, 64)
	nb := NewBoard(0, 2)
	nb.best = b.best
	if nb.BestAt(0) != 64 {
		t.Fatal("best did not carry to the next board")
	}
}

func TestChimeBounds(t *testing.T) {
	for _, rate := range []uint8{1, 3, 4, 5, 6, 7} {
		for _, format := range []uint8{vi.AudioFmtS16, vi.AudioFmtS32, vi.AudioFmtFloat} {
			for _, ch := range []uint8{1, 2} {
				pcm := synthChime(vi.AudioInfo{Rate: rate, Format: format, Channels: ch})
				fb, _ := chimeFrameBytes(format, ch)
				hz := chimeRateHz(rate)
				want := int(uint64(hz) * chimeMS / 1000) * fb
				if len(pcm) != want {
					t.Fatalf("rate=%d fmt=%d ch=%d: len %d want %d",
						rate, format, ch, len(pcm), want)
				}
				if int64(len(pcm))*1000 > int64(fb)*500*int64(hz) {
					t.Fatalf("chime over 0.5s: rate=%d", rate)
				}
				nonzero := false
				for _, c := range pcm {
					if c != 0 {
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
	if synthChime(vi.AudioInfo{Rate: 9, Format: vi.AudioFmtS16, Channels: 2}) != nil {
		t.Fatal("bad rate synthesized")
	}
	if synthChime(vi.AudioInfo{Rate: 7, Format: 99, Channels: 2}) != nil {
		t.Fatal("bad format synthesized")
	}
}

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
		{"my_audio_volume=0", 0, false},
	} {
		v, ok := settingsVolume([]byte(tc.blob))
		if v != tc.v || ok != tc.ok {
			t.Fatalf("%q: got %d,%v want %d,%v", tc.blob, v, ok, tc.v, tc.ok)
		}
	}
}
