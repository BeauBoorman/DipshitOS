package main

import (
	"strconv"
	"strings"
	"testing"

	"virelai/appkit"
	"virelai/vi"
	"virelai/webrender"
	"virelai/webrender/qoi"
)

// The golden vector helpers pin the tool rasterizers against hand-computed
// pixels — the same functions the class-B gate's scripted strokes exercise
// through real pointer events.

func TestNewDocPaper(t *testing.T) {
	d := newDoc(16, 8)
	if d.w != 16 || d.h != 8 {
		t.Fatalf("doc dims = %dx%d", d.w, d.h)
	}
	for i, p := range d.pix {
		if p != palette[paperIdx] {
			t.Fatalf("pix[%d]=%#x want paper %#x", i, p, palette[paperIdx])
		}
	}
}

func TestBrushStampGolden(t *testing.T) {
	d := newDoc(32, 32)
	tx := d.begin()
	tx.segment(pt{4, 4}, pt{4, 4}, 2, palette[0])
	d.commit(tx)
	// r=2 disk centered at (4,4): 13 pixels in the diamond-ish stamp.
	if got := tx.touches(); got != 13 {
		t.Fatalf("single stamp touches = %d, want 13", got)
	}
	if d.at(4, 4) != palette[0] || d.at(2, 4) != palette[0] || d.at(4, 6) != palette[0] {
		t.Fatal("stamp center/edges wrong")
	}
	if d.at(4, 7) != palette[paperIdx] || d.at(0, 0) != palette[paperIdx] {
		t.Fatal("stamp wrote outside its radius")
	}
}

func TestSegmentDiagonalGolden(t *testing.T) {
	d := newDoc(32, 32)
	tx := d.begin()
	tx.segment(pt{0, 0}, pt{10, 10}, 0, palette[8])
	d.commit(tx)
	for k := 0; k <= 10; k++ {
		if d.at(k, k) != palette[8] {
			t.Fatalf("diagonal pixel (%d,%d) not painted", k, k)
		}
	}
	if d.at(1, 0) != palette[paperIdx] {
		t.Fatal("r=0 segment wrote off the centerline")
	}
}

func TestRectOutlineGolden(t *testing.T) {
	d := newDoc(16, 16)
	tx := d.begin()
	tx.rectOutline(rect{2, 2, 8, 6}, 1, palette[3])
	d.commit(tx)
	// outline of 8x6 at weight 1: 8*2 + 4*2 = 24 pixels
	if tx.touches() != 24 {
		t.Fatalf("outline touches = %d, want 24", tx.touches())
	}
	if d.at(2, 2) != palette[3] || d.at(9, 7) != palette[3] || d.at(5, 5) == palette[3] {
		t.Fatal("rect outline shape wrong")
	}
}

func TestEraseRestoresPaper(t *testing.T) {
	d := newDoc(16, 16)
	tx := d.begin()
	tx.segment(pt{2, 2}, pt{10, 2}, 1, palette[9])
	d.commit(tx)
	tx = d.begin()
	tx.segment(pt{2, 2}, pt{10, 2}, 1, palette[paperIdx])
	d.commit(tx)
	for x := 0; x < 16; x++ {
		if d.at(x, 2) != palette[paperIdx] {
			t.Fatalf("erase left non-paper at x=%d", x)
		}
	}
}

func TestFillBoundAndSpread(t *testing.T) {
	// A 64x48 canvas, one closed rect, fill inside: the fill may push at
	// most w*h stack entries (the visited set makes repeats impossible)
	// and must stop at the outline.
	d := newDoc(64, 48)
	tx := d.begin()
	tx.rectOutline(rect{4, 4, 20, 16}, 1, palette[0])
	d.commit(tx)

	tx = d.begin()
	n := tx.fill(10, 10, palette[11])
	d.commit(tx)
	interior := (20 - 2) * (16 - 2)
	if n != interior {
		t.Fatalf("fill touched %d, want interior %d", n, interior)
	}
	if d.at(10, 10) != palette[11] || d.at(0, 0) != palette[paperIdx] {
		t.Fatal("fill leaked outside the outline or missed the interior")
	}

	// A free fill on empty space takes the whole remaining paper region —
	// bounded by w*h pushes even on the unbounded-looking spread.
	d2 := newDoc(8, 8)
	tx = d2.begin()
	if n := tx.fill(0, 0, palette[0]); n != 64 {
		t.Fatalf("open fill touched %d, want 64", n)
	}
	// Same-color fill is a no-op.
	tx = d2.begin()
	if n := tx.fill(0, 0, palette[0]); n != 0 {
		t.Fatalf("same-color fill touched %d, want 0", n)
	}
}

func TestUndoRing(t *testing.T) {
	// 20 ops on distinct pixels: the ring holds the newest 16, so ops 0-3
	// are evicted and their writes survive a full drain.
	d := newDoc(24, 16)
	for i := 0; i < histSteps+4; i++ {
		tx := d.begin()
		tx.segment(pt{i, 0}, pt{i, 0}, 0, palette[i%16])
		d.commit(tx)
	}
	if d.hist.depth() != histSteps {
		t.Fatalf("depth = %d, want %d", d.hist.depth(), histSteps)
	}
	// Undo twice: the two newest ops revert.
	for i := 0; i < 2; i++ {
		if !d.hist.undo(d) {
			t.Fatalf("undo %d failed", i)
		}
	}
	if d.hist.depth() != histSteps-2 {
		t.Fatalf("depth after undos = %d", d.hist.depth())
	}
	if d.at(19, 0) != palette[paperIdx] || d.at(18, 0) != palette[paperIdx] {
		t.Fatal("undid pixels are not paper")
	}
	// Drain: ops 4..19 revert; the evicted 0..3 keep their colors.
	for d.hist.undo(d) {
	}
	for x := 4; x < 20; x++ {
		if d.at(x, 0) != palette[paperIdx] {
			t.Fatalf("undrained revert left %d painted", x)
		}
	}
	for x := 0; x < 4; x++ {
		if d.at(x, 0) != palette[x] {
			t.Fatalf("evicted op %d reverted anyway", x)
		}
	}
}

func TestUndoSparseRevert(t *testing.T) {
	d := newDoc(16, 16)
	tx := d.begin()
	tx.segment(pt{0, 0}, pt{5, 0}, 0, palette[8])
	d.commit(tx)
	before := d.sum()
	tx = d.begin()
	tx.rectOutline(rect{4, 4, 6, 6}, 1, palette[9])
	d.commit(tx)
	if d.sum() == before {
		t.Fatal("rect op did not change the canvas")
	}
	if !d.hist.undo(d) || d.sum() != before {
		t.Fatal("undo did not restore the post-stroke canvas")
	}
}

func TestQOIRoundTrip(t *testing.T) {
	d := newDoc(24, 16)
	tx := d.begin()
	tx.segment(pt{2, 2}, pt{20, 12}, 2, palette[9])
	tx.rectOutline(rect{1, 1, 22, 14}, 1, palette[0])
	tx.fill(12, 8, palette[12])
	d.commit(tx)

	enc := qoi.Encode(d.pix, d.w, d.h)
	if len(enc) < 14 || string(enc[:4]) != "qoif" {
		t.Fatal("encoder did not emit a qoif header")
	}
	w, h, pix, err := qoi.Decode(enc, docMaxW, docMaxPx)
	if err != nil {
		t.Fatalf("qoi.Decode: %v", err)
	}
	if w != d.w || h != d.h {
		t.Fatalf("decoded dims %dx%d", w, h)
	}
	for i := range pix {
		if pix[i] != d.pix[i] {
			t.Fatalf("round-trip mismatch at %d: %#x != %#x", i, pix[i], d.pix[i])
		}
	}
}

func TestQOIEncodeDeterministic(t *testing.T) {
	d := newDoc(8, 8)
	a := qoi.Encode(d.pix, d.w, d.h)
	b := qoi.Encode(d.pix, d.w, d.h)
	if len(a) != len(b) {
		t.Fatal("encode not deterministic in length")
	}
	for i := range a {
		if a[i] != b[i] {
			t.Fatalf("encode byte %d differs", i)
		}
	}
	// A flat paper canvas is almost all runs: 14 header + runs + 8 tail.
	if len(a) > 200 {
		t.Fatalf("flat 8x8 encoded to %d bytes — run op broken", len(a))
	}
}

func TestStateRoundTrip(t *testing.T) {
	s := paintState{path: "/host/X.QOI", tool: toolRect, size: 1, color: 9, dirty: true}
	got, ok := decodeState(s.encode())
	if !ok || got != s {
		t.Fatalf("state round trip = %+v ok=%v", got, ok)
	}
	// Stale blobs refuse by decode, never by crash.
	for _, bad := range [][]byte{
		nil, {0}, {stateFmtVer}, {stateFmtVer, flagDirty, 99, 0, 0, 0},
		{stateFmtVer, flagDirty, 0, 0, 0, 3, 'a', 'b'},
	} {
		if _, ok := decodeState(bad); ok {
			t.Fatalf("decodeState(%v) = ok", bad)
		}
	}
}

// The export path rules: the PNG twin keeps the directory and the stem,
// swapping the extension with its case preserved.
func TestExportPath(t *testing.T) {
	for path, want := range map[string]string{
		"/host/PAINT1.QOI":      "/host/PAINT1.PNG",
		"/host/DROP/seed.qoi":   "/host/DROP/seed.png",
		"/host/noext":           "/host/noext.png",
		"X.GIF":                 "X.PNG",
		"/host/ART.BMP":         "/host/ART.PNG",
		"/host/mixed.Case.qoi2": "/host/mixed.Case.png",
	} {
		if got := exportPath(path); got != want {
			t.Fatalf("exportPath(%q) = %q, want %q", path, got, want)
		}
	}
}

// stubWrite captures the safe-write payload and the console markers the
// export flow emits, so the class-B spec's strings are pinned here.
func stubWrite(t *testing.T) (wrote *struct {
	path string
	data []byte
}, lines *[]string) {
	t.Helper()
	wrote = &struct {
		path string
		data []byte
	}{}
	lines = &[]string{}
	oldW, oldC := writeSafe, conLine
	writeSafe = func(path string, b []byte) int64 {
		wrote.path, wrote.data = path, b
		return 0
	}
	conLine = func(s string) { *lines = append(*lines, s) }
	t.Cleanup(func() { writeSafe, conLine = oldW, oldC })
	return wrote, lines
}

// 'x' on a document with a file association exports the derived PNG path
// without raising the picker; the bytes decode back to the same canvas.
func TestExportPNGQuickPath(t *testing.T) {
	d := newDoc(16, 12)
	tx := d.begin()
	tx.segment(pt{2, 2}, pt{12, 8}, 1, palette[9])
	d.commit(tx)
	d.path = "/host/PAINT1.QOI"
	d.dirty = false

	wrote, lines := stubWrite(t)
	a := &app{d: d}
	if !a.export() {
		t.Fatal("export refused")
	}
	if wrote.path != "/host/PAINT1.PNG" {
		t.Fatalf("export wrote %q", wrote.path)
	}
	im, err := webrender.DecodePNG(wrote.data)
	if err != nil {
		t.Fatalf("export is not a PNG: %v", err)
	}
	for i := range d.pix {
		if im.Pix[i] != d.pix[i] {
			t.Fatalf("exported pixel %d %#08x != canvas %#08x", i, im.Pix[i], d.pix[i])
		}
	}
	want := "gopaint: exported /host/PAINT1.PNG fmt=png n=" +
		strconv.Itoa(len(wrote.data)) + " sum=" + fnv16(d.sum())
	if len(*lines) != 1 || (*lines)[0] != want {
		t.Fatalf("markers %v, want %q", *lines, want)
	}
	// The export is a copy: the QOI association and dirty state stay.
	if a.d.path != "/host/PAINT1.QOI" || a.d.dirty {
		t.Fatal("export moved the document's save state")
	}
}

// A document that never named a file raises the picker in export mode;
// the typed name routes to exportPNG, not save.
func TestExportPNGPickerFallback(t *testing.T) {
	d := newDoc(8, 8)
	wrote, lines := stubWrite(t)
	a := &app{d: d}
	if !a.export() {
		t.Fatal("export refused")
	}
	if a.mode != modePicker || !a.pickExport || a.pick.Kind != appkit.PickSave {
		t.Fatal("export did not raise the save picker in export mode")
	}
	if a.pick.Title != "Export PNG" {
		t.Fatalf("picker title %q", a.pick.Title)
	}
	a.pick.Input = "FRESH.PNG"
	a.pickerKey(vi.Event{Kind: vi.EvKeyDown, Arg0: 0x28, Arg1: '\r'})
	if wrote.path != "/host/FRESH.PNG" {
		t.Fatalf("picker export wrote %q", wrote.path)
	}
	var raised, done bool
	for _, l := range *lines {
		raised = raised || l == "gopaint: pick export"
		done = done || strings.HasPrefix(l, "gopaint: exported /host/FRESH.PNG fmt=png n=")
	}
	if !raised || !done {
		t.Fatalf("markers %v", *lines)
	}
}

func TestPaletteHitMatchesDraw(t *testing.T) {
	// The hit/paint agreement rule: a point inside cell i returns i.
	for i := range palette {
		x := paletteOrgX + (i%paletteCols)*paletteStep + paletteCell/2
		y := paletteOrgY + (i/paletteCols)*paletteStep + paletteCell/2
		got, ok := paletteHit(x, y)
		if !ok || got != i {
			t.Fatalf("paletteHit cell %d -> %d,%v", i, got, ok)
		}
	}
	// The gap between cells is not a hit.
	if _, ok := paletteHit(paletteOrgX+paletteCell, paletteOrgY); ok {
		t.Fatal("palette gap hit")
	}
}
