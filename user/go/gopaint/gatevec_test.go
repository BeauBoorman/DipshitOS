package main

import (
	"crypto/sha256"
	"fmt"
	"os"
	"testing"
)

// gateGesture replays the go-paint spec's run-01 scripted pointer set on the
// pure doc core and asserts every value the class-B spec pins — a drift in
// either half fails class-A before the gate ever boots.
func gateGesture(t *testing.T) *doc {
	t.Helper()
	d := newDoc(640, 480)

	// brush, color 9, size 4: L-stroke (40,40)->(120,40)->(120,100)
	tx := d.begin()
	tx.segment(pt{40, 40}, pt{40, 40}, 2, palette[9])
	tx.segment(pt{40, 40}, pt{120, 40}, 2, palette[9])
	tx.segment(pt{120, 40}, pt{120, 100}, 2, palette[9])
	d.commit(tx)

	// line: (240,40)->(300,140)
	tx = d.begin()
	tx.segment(pt{240, 40}, pt{300, 140}, 2, palette[9])
	d.commit(tx)

	// rect: (100,80)->(220,180) outline, weight 1
	tx = d.begin()
	tx.rectOutline(rectFrom(pt{100, 80}, pt{220, 180}), 1, palette[9])
	d.commit(tx)

	// fill color 11 inside the rect at (160,120)
	tx = d.begin()
	if n := tx.fill(160, 120, palette[11]); n != 11677 {
		t.Fatalf("fill n=%d, want 11677", n)
	}
	d.commit(tx)

	// erase: (220,90)->(320,90) r=2 — cuts the diagonal line
	tx = d.begin()
	tx.segment(pt{220, 90}, pt{320, 90}, 2, palette[paperIdx])
	d.commit(tx)
	return d
}

func TestGateVectors(t *testing.T) {
	d := gateGesture(t)
	steps := []struct {
		sum   string
		probe string
	}{
		{"1736b82007e7fe87", "0xff00e436"}, // after erase
		{"5b5a7eeede3e7cdb", "0xff00e436"}, // undo 1 (erase reverted)
		{"84b28dfa95fb6f29", "0xfffff1e8"}, // undo 2 (fill reverted)
	}
	if got := fnv16(d.sum()); got != steps[0].sum {
		t.Fatalf("post-gesture sum = %s, want %s", got, steps[0].sum)
	}
	for i, want := range steps[1:] {
		if !d.hist.undo(d) {
			t.Fatalf("undo %d empty", i+1)
		}
		if got := fnv16(d.sum()); got != want.sum {
			t.Fatalf("undo %d sum = %s, want %s", i+1, got, want.sum)
		}
		if got := probeText(d); got != want.probe {
			t.Fatalf("undo %d probe = %s, want %s", i+1, got, want.probe)
		}
	}
	enc := EncodeQOI(d.pix, d.w, d.h)
	sum := fmt.Sprintf("%x", sha256.Sum256(enc))
	if sum != "7a49b337e2f459a9aabe99ee927f353c3634afa42c8ce0ab136178e19b98c3bd" {
		t.Fatalf("saved sha256 = %s", sum)
	}
	if len(enc) != 6042 {
		t.Fatalf("saved n=%d, want 6042", len(enc))
	}
}

// The run-02 drop fixture's canvas sum — pinned the same way.
func TestDropVector(t *testing.T) {
	b, err := os.ReadFile("../../../tests/fixtures/qoi/viewer_160x120.qoi")
	if err != nil {
		t.Fatal(err)
	}
	w, h, pix, err := decodeImage(b)
	if err != nil {
		t.Fatal(err)
	}
	d := docFrom(w, h, pix)
	if w != 160 || h != 120 {
		t.Fatalf("fixture dims %dx%d", w, h)
	}
	if got := fnv16(d.sum()); got != "9ea88033bfdfe325" {
		t.Fatalf("drop canvas sum = %s", got)
	}
}
