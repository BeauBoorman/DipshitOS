package main

import (
	"crypto/sha256"
	"fmt"
	"os"
	"testing"

	"virelai/webrender/qoi"
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

// storeGesture replays the run-04 store-leg draw on the pure doc core —
// the gesture set the signed-install boot scripts: color 9, a two-segment
// brush L, one line, one rect. The spec's commit n=/sum= and the saved
// file's sha256 pin to these values, so a drift in either half fails
// class-A before the gate ever boots.
func storeGesture(t *testing.T) *doc {
	t.Helper()
	d := newDoc(640, 480)

	// brush, color 9, size 4: L-stroke (40,40)->(160,40)->(160,140), the
	// down/move/up events the pointer sequence delivers.
	tx := d.begin()
	tx.segment(pt{40, 40}, pt{40, 40}, 2, palette[9])
	tx.segment(pt{40, 40}, pt{160, 40}, 2, palette[9])
	tx.segment(pt{160, 40}, pt{160, 140}, 2, palette[9])
	tx.segment(pt{160, 140}, pt{160, 140}, 2, palette[9])
	d.commit(tx)
	if tx.touches() != 1110 || fnv16(d.sum()) != "2403da426d2b6a71" {
		t.Fatalf("commit brush n=%d sum=%s", tx.touches(), fnv16(d.sum()))
	}

	// line: (240,40)->(320,120)
	tx = d.begin()
	tx.segment(pt{240, 40}, pt{320, 120}, 2, palette[9])
	d.commit(tx)
	if tx.touches() != 413 || fnv16(d.sum()) != "a6b92d65c02c3d9b" {
		t.Fatalf("commit line n=%d sum=%s", tx.touches(), fnv16(d.sum()))
	}

	// rect: (300,200)->(460,320) outline, weight 1
	tx = d.begin()
	tx.rectOutline(rectFrom(pt{300, 200}, pt{460, 320}), 1, palette[9])
	d.commit(tx)
	if tx.touches() != 560 || fnv16(d.sum()) != "e9449dcb31e7c11b" {
		t.Fatalf("commit rect n=%d sum=%s", tx.touches(), fnv16(d.sum()))
	}
	return d
}

// TestStoreVectors pins the M141b round-trip: the run-04 draw's per-commit
// digests, the saved PSTORE.QOI bytes, then the run-05 reopen+edit — the
// reopened doc decodes to the same canvas sum, the color-11 fill inside the
// rect lands its own count and digest, and the re-saved file hashes its
// edited bytes.
func TestStoreVectors(t *testing.T) {
	d := storeGesture(t)
	const v1Sum = "e9449dcb31e7c11b"
	if got := fnv16(d.sum()); got != v1Sum {
		t.Fatalf("run-04 canvas sum = %s, want %s", got, v1Sum)
	}
	enc := EncodeQOI(d.pix, d.w, d.h)
	sum := fmt.Sprintf("%x", sha256.Sum256(enc))
	if sum != "66cbfbcefc44ef6bd9c2ecdc00d3f50e6895503df260761cc60862a80d98744a" {
		t.Fatalf("PSTORE.QOI sha256 = %s", sum)
	}
	if len(enc) != 6190 {
		t.Fatalf("PSTORE.QOI n=%d, want 6190", len(enc))
	}

	// Run 05: the reopened file decodes to the same canvas, then a
	// color-11 fill inside the rect at (380,240) edits it.
	w, h, pix, err := qoi.Decode(enc, docMaxW, docMaxPx)
	if err != nil {
		t.Fatal(err)
	}
	if w != 640 || h != 480 {
		t.Fatalf("reopen dims %dx%d", w, h)
	}
	d2 := docFrom(w, h, pix)
	if got := fnv16(d2.sum()); got != v1Sum {
		t.Fatalf("reopened canvas sum = %s, want %s", got, v1Sum)
	}
	tx := d2.begin()
	if n := tx.fill(380, 240, palette[11]); n != 18921 {
		t.Fatalf("run-05 fill n=%d, want 18921", n)
	}
	d2.commit(tx)
	const v2Sum = "c80c07f96fb2d329"
	if got := fnv16(d2.sum()); got != v2Sum {
		t.Fatalf("run-05 canvas sum = %s, want %s", got, v2Sum)
	}
	enc2 := EncodeQOI(d2.pix, d2.w, d2.h)
	sum2 := fmt.Sprintf("%x", sha256.Sum256(enc2))
	if sum2 != "416c5327f2456c708b4aeb8cc37b9c7dc567c7721aab0a4d9fb397bebc7fbefc" {
		t.Fatalf("PSTORE.QOI (edited) sha256 = %s", sum2)
	}
	if len(enc2) != 6193 {
		t.Fatalf("PSTORE.QOI (edited) n=%d, want 6193", len(enc2))
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
