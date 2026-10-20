package main

import "testing"

func TestPagerBounds(t *testing.T) {
	p := pager{page: 0, pages: 3}
	if !p.next() || p.page != 1 {
		t.Fatal("next")
	}
	if !p.next() || p.page != 2 {
		t.Fatal("next to last")
	}
	if p.next() {
		t.Fatal("next past end")
	}
	if !p.prev() || p.page != 1 {
		t.Fatal("prev")
	}
	if !p.end() || p.page != 2 {
		t.Fatal("end")
	}
	if !p.home() || p.page != 0 {
		t.Fatal("home")
	}
	if p.prev() {
		t.Fatal("prev past start")
	}
	// goTo clamps out-of-range targets onto the edges.
	if !p.goTo(9) || p.page != 2 {
		t.Fatal("goTo clamp high")
	}
	if !p.goTo(-4) || p.page != 0 {
		t.Fatal("goTo clamp low")
	}
	var empty pager
	if empty.next() || empty.goTo(0) {
		t.Fatal("empty doc must not move")
	}
}

func TestZoomTableAndFit(t *testing.T) {
	if zoomTable[zoomDefaultIdx] != 100 {
		t.Fatal("default zoom must be 100")
	}
	if stepZoom(0, -1) != 0 || stepZoom(len(zoomTable)-1, 1) != len(zoomTable)-1 {
		t.Fatal("zoom clamps at both ends")
	}
	if stepZoom(zoomDefaultIdx, 1) != zoomDefaultIdx+1 {
		t.Fatal("zoom in")
	}
	// Fit-width: viewport 300 over a 100px page is 300%.
	if z := fitWidthZoom(300, 100); z != 300 {
		t.Fatalf("fitWidthZoom = %d want 300", z)
	}
	// Clamped to the card's 50–400 range.
	if z := fitWidthZoom(10, 100); z != zoomMinPct {
		t.Fatalf("fitWidthZoom low = %d want %d", z, zoomMinPct)
	}
	if z := fitWidthZoom(10000, 100); z != zoomMaxPct {
		t.Fatalf("fitWidthZoom high = %d want %d", z, zoomMaxPct)
	}
	if w, h := displayedSize(64, 96, 150); w != 96 || h != 144 {
		t.Fatalf("displayedSize = %dx%d want 96x144", w, h)
	}
}

func TestScrollFlip(t *testing.T) {
	pg := pager{page: 0, pages: 3}
	// Mid-page: pan down, no turn.
	np, noy, turned, moved := scrollDown(pg, 0, 100, 30)
	if !moved || turned || np != 0 || noy != 30 {
		t.Fatal("mid-page scroll")
	}
	// At the bottom edge: flip to the next page, origin top.
	np, noy, turned, moved = scrollDown(pg, 100, 100, 30)
	if !moved || !turned || np != 1 || noy != 0 {
		t.Fatal("flip down")
	}
	// Last page bottom: nowhere to go.
	pg.page = 2
	if _, _, _, moved = scrollDown(pg, 100, 100, 30); moved {
		t.Fatal("scroll past last page")
	}
	// Top of a later page: flip up and land on the previous bottom.
	pg.page = 1
	np, noy, turned, moved = scrollUp(pg, 0, 100, 30)
	if !moved || !turned || np != 0 || noy != 100 {
		t.Fatal("flip up")
	}
	np, noy, turned, moved = scrollUp(pg, 10, 100, 30)
	if turned || np != 1 || noy != 0 {
		t.Fatal("scroll up clamps at zero")
	}
}

func TestPanMax(t *testing.T) {
	// Whole page visible: only origin 0 is legal.
	if m := panMax(64, 64, 200); m != 0 {
		t.Fatalf("panMax fit = %d", m)
	}
	// 64px page at 400% = 256 displayed in a 100px viewport:
	// span = 100*64/256 = 25 page px visible; max origin 39.
	if m := panMax(64, 256, 100); m != 39 {
		t.Fatalf("panMax zoomed = %d want 39", m)
	}
}

func TestMergeHitRects(t *testing.T) {
	// Two glyphs on one line merge; a third on the next line is its own band.
	gs := []glyphPos{
		{off: 0, x0: 10, y0: 20, x1: 16, y1: 28},
		{off: 1, x0: 16, y0: 20, x1: 22, y1: 28},
		{off: 2, x0: 10, y0: 40, x1: 16, y1: 48},
	}
	rs := mergeHitRects(gs, 0, 3)
	if len(rs) != 2 {
		t.Fatalf("mergeHitRects = %d rects want 2", len(rs))
	}
	if rs[0].X0 != 10 || rs[0].X1 != 22 || rs[0].Y0 != 20 || rs[0].Y1 != 28 {
		t.Fatalf("line band = %+v", rs[0])
	}
	// A range inside the word merges only its own glyphs.
	rs = mergeHitRects(gs, 1, 2)
	if len(rs) != 1 || rs[0].X0 != 16 {
		t.Fatalf("partial range = %+v", rs)
	}
}

func TestBlendRect(t *testing.T) {
	pix := make([]uint32, 64*64)
	for i := range pix {
		pix[i] = 0xffffffff
	}
	blendRect(pix, 64, 64, 64, hitRect{4, 4, 20, 20}, 0xE8C832, 45)
	got := pix[4*64+4]
	// White toward 0xE8C832 at 45%: r=(255*55+232*45)/100=244,
	// g=230, b=162.
	if got != 0xfff4e6a2 {
		t.Fatalf("blend = %08x want fff4e6a2", got)
	}
	if pix[3*64+3] != 0xffffffff {
		t.Fatal("blend leaked outside the rect")
	}
}

func TestStateCodec(t *testing.T) {
	b := encodeState("/host/READER/PAGES.PDF", 1, 150, true)
	path, page, zoom, fit, ok := decodeState(b)
	if !ok || path != "/host/READER/PAGES.PDF" || page != 1 || zoom != 150 || !fit {
		t.Fatalf("roundtrip = %q %d %d %v %v", path, page, zoom, fit, ok)
	}
	// A blob from a different appver is refused, never misread.
	b[0] = 9
	if _, _, _, _, ok = decodeState(b); ok {
		t.Fatal("stale version accepted")
	}
	if _, _, _, _, ok = decodeState([]byte{1, 0}); ok {
		t.Fatal("truncated blob accepted")
	}
}
