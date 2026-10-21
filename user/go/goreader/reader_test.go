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
	b := encodeState("/host/READER/PAGES.PDF", 1, 150, true, []int{0, 2})
	path, page, zoom, fit, bmk, ok := decodeState(b)
	if !ok || path != "/host/READER/PAGES.PDF" || page != 1 || zoom != 150 || !fit {
		t.Fatalf("roundtrip = %q %d %d %v %v", path, page, zoom, fit, ok)
	}
	if len(bmk) != 2 || bmk[0] != 0 || bmk[1] != 2 {
		t.Fatalf("blob bookmarks = %v", bmk)
	}
	// A blob from a different appver is refused, never misread — including
	// v1, which has no bookmark tail and is one byte short anyway.
	b[0] = 9
	if _, _, _, _, _, ok = decodeState(b); ok {
		t.Fatal("stale version accepted")
	}
	if _, _, _, _, _, ok = decodeState([]byte{1, 0}); ok {
		t.Fatal("truncated blob accepted")
	}
	// A bookmark count past the tail's real bytes is refused, not overrun.
	b = encodeState("/host/A.PDF", 0, 100, false, nil)
	b[len(b)-1] = 4
	if _, _, _, _, _, ok = decodeState(b); ok {
		t.Fatal("overclaimed bookmark tail accepted")
	}
}

func TestBookmarkSet(t *testing.T) {
	var s []int
	var marked, changed bool
	// Adds land sorted; a second toggle on the same page removes it.
	s, marked, changed = bmToggle(s, 4)
	if !marked || !changed || len(s) != 1 || s[0] != 4 {
		t.Fatal("first add")
	}
	s, marked, changed = bmToggle(s, 1)
	if !marked || !changed || s[0] != 1 || s[1] != 4 {
		t.Fatalf("sorted insert = %v", s)
	}
	s, marked, changed = bmToggle(s, 4)
	if marked || !changed || len(s) != 1 || s[0] != 1 {
		t.Fatal("toggle off")
	}
	// The 16-mark bound refuses the seventeenth add, by name.
	s = nil
	for i := 0; i < posMaxBookmarks; i++ {
		s, marked, changed = bmToggle(s, i)
		if !marked || !changed {
			t.Fatalf("add %d refused early", i)
		}
	}
	if _, _, changed = bmToggle(s, 99); changed {
		t.Fatal("full set accepted an add")
	}
	// ...but a removal from the full set still lands.
	s, marked, changed = bmToggle(s, 3)
	if marked || !changed || len(s) != posMaxBookmarks-1 {
		t.Fatal("full set refused a removal")
	}
}

func TestBookmarkJump(t *testing.T) {
	s := []int{2, 5, 9}
	// Next steps forward through the set and wraps at the tail.
	for cur, want := range map[int]int{0: 2, 2: 5, 8: 9, 9: 2, 20: 2} {
		if got, ok := bmNext(s, cur); !ok || got != want {
			t.Fatalf("bmNext(%d) = %d,%v want %d", cur, got, ok, want)
		}
	}
	for cur, want := range map[int]int{0: 9, 2: 9, 6: 5, 9: 5} {
		if got, ok := bmPrev(s, cur); !ok || got != want {
			t.Fatalf("bmPrev(%d) = %d,%v want %d", cur, got, ok, want)
		}
	}
	if _, ok := bmNext(nil, 0); ok {
		t.Fatal("empty set jumped")
	}
	if bmList(s) != "3,6,10" || bmList(nil) != "-" {
		t.Fatalf("bmList = %q", bmList(s))
	}
}

func TestPosCodec(t *testing.T) {
	mk := func(path string, data string) posEntry {
		return posKey(path, []byte(data))
	}
	a := mk("/host/A.PDF", "aaaa")
	c := mk("/host/C.PDF", "cccc")
	a.page, a.zoom, a.fit, a.bmk = 2, 150, false, []int{0, 2}
	c.page, c.zoom, c.fit = 0, 100, true

	ents := decodePosFile(encodePosFile([]posEntry{a, c}))
	if len(ents) != 2 {
		t.Fatalf("roundtrip = %d entries", len(ents))
	}
	got := ents[0]
	if got.path != a.path || got.size != a.size || got.sha != a.sha ||
		got.page != 2 || got.zoom != 150 || got.fit ||
		len(got.bmk) != 2 || got.bmk[1] != 2 {
		t.Fatalf("row = %+v", got)
	}
	if !ents[1].fit {
		t.Fatal("fit flag lost")
	}

	// The key is path+size+head-sha: same path, different bytes misses.
	moved := mk("/host/A.PDF", "different-bytes!")
	if posFind(ents, moved) >= 0 {
		t.Fatal("changed content matched the old key")
	}
	grown := mk("/host/A.PDF", "aaaa+")
	if posFind(ents, grown) >= 0 {
		t.Fatal("changed size matched the old key")
	}
	if posFind(ents, a) < 0 {
		t.Fatal("same document missed its key")
	}
}

func TestPosEvictionAndUpsert(t *testing.T) {
	var ents []posEntry
	for i := 0; i < posMaxEntries+3; i++ {
		name := "/host/D" + string(rune('A'+i/26)) + string(rune('A'+i%26)) + ".PDF"
		e := posKey(name, []byte(name))
		e.page = i
		ents = posUpsert(ents, e)
	}
	if len(ents) != posMaxEntries {
		t.Fatalf("cap = %d", len(ents))
	}
	// Most-recent first: the last three writes lead, the oldest are gone.
	if ents[0].page != posMaxEntries+2 || ents[1].page != posMaxEntries+1 {
		t.Fatalf("front = %d,%d", ents[0].page, ents[1].page)
	}
	// Re-touching a middle row moves it to the front and drops its twin.
	k := posKey(ents[10].path, []byte(ents[10].path))
	moved := ents[10]
	moved.page = 7
	ents = posUpsert(ents, moved)
	if ents[0].page != 7 || posFind(ents, k) != 0 {
		t.Fatal("re-touch did not move to front")
	}
	seen := 0
	for _, e := range ents {
		if e.path == moved.path {
			seen++
		}
	}
	if seen != 1 {
		t.Fatal("stale same-path row survived")
	}
}

func TestPosFileRobust(t *testing.T) {
	good := encodePosFile([]posEntry{posKey("/host/A.PDF", []byte("a"))})
	var bad []byte
	bad = append(bad, "# comment\n\n"...)
	bad = append(bad, "1\t2\t3\n"...)                // short row
	bad = append(bad, "x\ty\tz\tz\tz\tz\tz\n"...)    // unparsable
	bad = append(bad, "9\tzz\t0\t100\t0\t\tzz\n"...) // bad hex fields
	bad = append(bad, good...)
	if ents := decodePosFile(bad); len(ents) != 1 {
		t.Fatalf("malformed rows survived = %d", len(ents))
	}
	if got := decodePosFile(nil); len(got) != 0 {
		t.Fatal("empty file produced rows")
	}
}

func TestCopyName(t *testing.T) {
	if got := copyName("PAGES.PDF"); got != "PAGES-COPY.PDF" {
		t.Fatalf("copyName = %q", got)
	}
	if got := copyName("notes.pdf"); got != "notes-COPY.PDF" {
		t.Fatalf("copyName lower = %q", got)
	}
	if got := copyName("PLAIN"); got != "PLAIN-COPY" {
		t.Fatalf("copyName bare = %q", got)
	}
	if got := dirname("/host/READER/PAGES.PDF"); got != "/host/READER" {
		t.Fatalf("dirname = %q", got)
	}
	if got := dirname("BARE.PDF"); got != "/host" {
		t.Fatalf("dirname bare = %q", got)
	}
}
