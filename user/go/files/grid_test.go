package main

import (
	"strings"
	"testing"

	"virelai/rss/keys"
	"virelai/vi"
	"virelai/webrender"
)

// countingBacker points the readHead seam at a fixture table and counts
// the reads per path — the decode-budget and no-retry proofs need the
// call count, not just the bytes.
func countingBacker(t *testing.T, files map[string][]byte) map[string]*int {
	t.Helper()
	counts := map[string]*int{}
	prev := readHead
	readHead = func(path string, cap int) ([]byte, int64) {
		c := counts[path]
		if c == nil {
			c = new(int)
			counts[path] = c
		}
		*c++
		if b, ok := files[path]; ok {
			return b, int64(len(b))
		}
		return nil, -2 // ENOENT
	}
	t.Cleanup(func() { readHead = prev })
	return counts
}

// statBacker pins the statTimes seam to a per-path table (absent = no
// stamp), so the cache key's mtime half is testable on the host.
func statBacker(t *testing.T, stamps map[string]int64) {
	t.Helper()
	prev := statTimes
	statTimes = func(p string) (int64, int64, bool, bool) {
		if v, ok := stamps[p]; ok {
			return v, 0, true, false
		}
		return 0, 0, false, false
	}
	t.Cleanup(func() { statTimes = prev })
}

func rgb(r, g, b uint32) uint32 { return 0xff000000 | r<<16 | g<<8 | b }

// The mosaic's cell colours are exact: a raster sized to the tile lands
// its pixels verbatim; a downsample averages each cell's source region;
// a transparent pixel contributes the blank stand-in, not its channels.
func TestMosaicExactCellColours(t *testing.T) {
	// 10x5 into 10x5 — every cell is exactly its source pixel.
	im := &webrender.Image{Width: tileW, Height: tileH, Pix: make([]uint32, tileW*tileH)}
	for i := range im.Pix {
		im.Pix[i] = rgb(uint32(i*3%256), uint32(i*5%256), uint32(i*7%256))
	}
	var cells [tileW * tileH]uint32
	mosaic(im, &cells)
	for i := range cells {
		if cells[i] != im.Pix[i]&0xffffff {
			t.Fatalf("identity cell %d = %#x, want %#x", i, cells[i], im.Pix[i]&0xffffff)
		}
	}

	// 20x10: each cell is a 2x2 source block. Uniform blocks land
	// verbatim; a mixed block is the rounded mean of its four pixels.
	big := &webrender.Image{Width: 2 * tileW, Height: 2 * tileH, Pix: make([]uint32, 4*tileW*tileH)}
	for i := range big.Pix {
		big.Pix[i] = rgb(10, 20, 30)
	}
	// Cell (0,0) covers source (0,0),(1,0),(0,1),(1,1): red, green,
	// blue, white -> (128,128,128).
	big.Pix[0] = rgb(255, 0, 0)
	big.Pix[1] = rgb(0, 255, 0)
	big.Pix[2*tileW] = rgb(0, 0, 255)
	big.Pix[2*tileW+1] = rgb(255, 255, 255)
	// Cell (1,0) covers (2,0),(3,0),(2,1),(3,1): three transparent
	// pixels + one red -> the blank stand-in on three, red on one.
	big.Pix[2] = 0x00000000
	big.Pix[3] = 0x00408080
	big.Pix[2*tileW+2] = 0x00000000
	big.Pix[2*tileW+3] = rgb(255, 0, 0)
	mosaic(big, &cells)
	if cells[0] != 0x808080 {
		t.Fatalf("mixed cell = %#x, want 0x808080", cells[0])
	}
	// (0x14*3+255+2)/4 = 79, (0x18*3+2)/4 = 18, (0x1d*3+2)/4 = 22.
	if cells[1] != 0x4f1216 {
		t.Fatalf("transparent-mixed cell = %#x, want 0x4f1216", cells[1])
	}
	if cells[2] != 0x0a141e {
		t.Fatalf("uniform cell = %#x, want 0x0a141e", cells[2])
	}
}

// The layout is fixed by the frame: tile columns fit the list pane's
// (tileW+1) pitches, tile rows the body's (tileH+1).
func TestGridLayoutForWidths(t *testing.T) {
	m := testModel()
	cases := []struct {
		cols, rows, gc, gr int
	}{
		{64, 23, 2, 3},  // lw=28 -> 2 pitches; body=19 -> 3 rows
		{80, 23, 3, 3},  // lw=36 -> 3
		{200, 40, 8, 6}, // lw=90 -> 8; body=36 -> 6
		{16, 8, 1, 1},   // lw=12 -> 1; body=4 -> clamps to 1
		{32, 12, 1, 1},  // lw=14 -> 1; body=8 -> 1
	}
	for _, c := range cases {
		m.setSize(c.cols, c.rows)
		if got := m.gridCols(); got != c.gc {
			t.Errorf("gridCols at %dx%d = %d, want %d", c.cols, c.rows, got, c.gc)
		}
		if got := m.gridRows(); got != c.gr {
			t.Errorf("gridRows at %dx%d = %d, want %d", c.cols, c.rows, got, c.gr)
		}
	}
}

// The decode budget is two tiles per pass, placeholders until done; the
// focus decode is the eager half (one read serves the mosaic AND the
// sixel). The stats marker fires once, when the queue drains.
func TestGridDecodeBudgetPerPassAndMarkers(t *testing.T) {
	files := map[string][]byte{
		"/host/FM/A.TXT": []byte("plain text\n"),
		"/host/FM/B.QOI": qoi(4, 4, 255, 0, 0),
		"/host/FM/C.QOI": qoi(4, 4, 0, 255, 0),
		"/host/FM/D.QOI": qoi(4, 4, 0, 0, 255),
		"/host/FM/E.QOI": qoi(4, 4, 255, 255, 0),
	}
	counts := countingBacker(t, files)
	statBacker(t, map[string]int64{})
	m := testModel(entry("A.TXT", false), entry("B.QOI", false),
		entry("C.QOI", false), entry("D.QOI", false), entry("E.QOI", false))
	m.handleKey(runeKey('t'))
	if m.view != viewGrid {
		t.Fatalf("t must enter the grid: view=%d", m.view)
	}
	got := pendingJoined(&m)
	if !strings.Contains(got, markerGridOn+"cols=2 rows=3") {
		t.Fatalf("grid-on marker missing: %q", got)
	}
	// sel=0 is A.TXT: the focus decode resolves it to a word tile —
	// thumb=0x0, and its one read is spent.
	if !strings.Contains(got, markerGridFocus+"A.TXT thumb=0x0") {
		t.Fatalf("focus marker missing: %q", got)
	}
	if *counts["/host/FM/A.TXT"] != 1 {
		t.Fatalf("focus read A.TXT %d times, want 1", *counts["/host/FM/A.TXT"])
	}
	// The queue holds the four unresolved images only.
	if len(m.gridQueue) != 4 {
		t.Fatalf("queue = %v, want 4 pending tiles", m.gridQueue)
	}
	if strings.Contains(got, markerGridTiles) {
		t.Fatalf("stats marker fired before the drain: %q", got)
	}
	// Pass 1: at most two decodes. The two placeholders that remain are
	// the honest "still arriving" face.
	m.gridStep()
	if *counts["/host/FM/B.QOI"] != 1 || *counts["/host/FM/C.QOI"] != 1 {
		t.Fatalf("pass 1 must resolve B and C exactly once: %v", counts)
	}
	if c := counts["/host/FM/D.QOI"]; c != nil && *c > 0 {
		t.Fatalf("pass 1 read D %d times — the budget is 2", *c)
	}
	if m.gridTileAt(3) != pendingTile {
		t.Fatal("D's tile must still be the placeholder after pass 1")
	}
	// Pass 2 drains the queue and prints the accounting once.
	m.gridStep()
	if m.gridPending() {
		t.Fatal("queue did not drain on the second pass")
	}
	got = pendingJoined(&m)
	if !strings.Contains(got, markerGridTiles+"decoded=4 failed=0") {
		t.Fatalf("stats marker missing or wrong: %q", got)
	}
	// Every image tile now shows its mosaic, the text file its word.
	for i := 1; i <= 4; i++ {
		if m.gridTileAt(i).kind != tileImage {
			t.Fatalf("tile %d kind=%d, want image", i, m.gridTileAt(i).kind)
		}
	}
	if m.gridTileAt(0).kind != tileWord || m.gridTileAt(0).word != "text" {
		t.Fatalf("A.TXT tile = %+v, want word text", m.gridTileAt(0))
	}
	// The marker is once per drain — a further step repeats nothing.
	m.gridStep()
	if strings.Contains(pendingJoined(&m), markerGridTiles) {
		t.Fatal("stats marker emitted twice")
	}
}

// The cache keys on path+size+mtime: a failed decode keeps its
// placeholder and is never retried while the key stands; a new mtime is
// a new key and earns one retry.
func TestGridCacheKeyingAndNoRetry(t *testing.T) {
	files := map[string][]byte{
		"/host/FM/BAD.QOI": []byte("not-an-image-bytes"),
		"/host/FM/OK.QOI":  qoi(4, 4, 0, 255, 0),
	}
	counts := countingBacker(t, files)
	stamps := map[string]int64{"/host/FM/BAD.QOI": 42e9, "/host/FM/OK.QOI": 42e9}
	statBacker(t, stamps)
	m := testModel(entry("BAD.QOI", false), entry("OK.QOI", false))
	m.handleKey(runeKey('t'))
	// sel=0 is BAD.QOI: the focus decode fails, caches the failure, and
	// reports thumb=0x0.
	if got := pendingJoined(&m); !strings.Contains(got, markerGridFocus+"BAD.QOI thumb=0x0") {
		t.Fatalf("failed-focus marker missing: %q", got)
	}
	if *counts["/host/FM/BAD.QOI"] != 1 {
		t.Fatalf("BAD.QOI read %d times, want 1", *counts["/host/FM/BAD.QOI"])
	}
	if len(m.gridFSixel) != 0 {
		t.Fatal("a failed focus must not leave a sixel armed")
	}
	// Drain the queue: OK decodes, BAD is already settled.
	m.gridStep()
	if m.gridTileAt(0).kind != tileFailed {
		t.Fatalf("BAD.QOI tile kind=%d, want failed", m.gridTileAt(0).kind)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerGridTiles+"decoded=1 failed=1") {
		t.Fatalf("stats marker wrong: %q", got)
	}
	// Focus OK then BAD again: the cached failure stands — no re-read.
	m.handleKey(runeKey('l'))
	m.handleKey(runeKey('h'))
	if *counts["/host/FM/BAD.QOI"] != 1 {
		t.Fatalf("failed tile retried while its key stands: %d reads",
			*counts["/host/FM/BAD.QOI"])
	}
	// A new mtime is a new key — the retry the card promises.
	stamps["/host/FM/BAD.QOI"] = 43e9
	m.gridSync() // as a refresh would
	m.handleKey(runeKey('l'))
	m.handleKey(runeKey('h'))
	if *counts["/host/FM/BAD.QOI"] != 2 {
		t.Fatalf("a changed file must retry once: %d reads", *counts["/host/FM/BAD.QOI"])
	}
}

// h/j/k/l and the arrows move by tile; the listing order is the tile
// order, clamped at every edge; scrolling is by tile row.
func TestGridNavEdges(t *testing.T) {
	m := testModel(entry("D1", true), entry("D2", true), entry("D3", true),
		entry("D4", true), entry("D5", true), entry("D6", true), entry("D7", true))
	m.handleKey(runeKey('t'))
	step := func(name string, ev keys.Event, want int) {
		t.Helper()
		m.handleKey(ev)
		if m.sel != want {
			t.Fatalf("%s: sel=%d, want %d", name, m.sel, want)
		}
	}
	// gc=2: rows are {D1,D2} {D3,D4} {D5,D6} {D7}.
	step("h at left edge", runeKey('h'), 0)
	step("l", runeKey('l'), 1)
	step("l wraps the row", runeKey('l'), 2)
	step("j a tile row", runeKey('j'), 4)
	step("j", runeKey('j'), 6)
	step("j clamps at the last tile", runeKey('j'), 6)
	step("k", runeKey('k'), 4)
	step("h", runeKey('h'), 3)
	step("down", keys.Event{Key: keys.KeyDown}, 5)
	step("up", keys.Event{Key: keys.KeyUp}, 3)
	step("left", keys.Event{Key: keys.KeyLeft}, 2)
	step("right", keys.Event{Key: keys.KeyRight}, 3)
	step("home", keys.Event{Key: keys.KeyHome}, 0)
	step("end", keys.Event{Key: keys.KeyEnd}, 6)

	// The scroll window is tile rows: sel 15 of 16 -> top = first entry
	// of tile row 5 (gridRows=3, last tile row 7).
	var entries []vi.DirEntry
	for i := 0; i < vi.MaxDirEntries; i++ {
		entries = append(entries, entry("T"+string(rune('A'+i)), true))
	}
	m2 := testModel(entries...)
	m2.handleKey(runeKey('t'))
	m2.moveTo(15)
	if m2.top != 10 {
		t.Fatalf("grid scroll: top=%d, want 10 (tile row 5)", m2.top)
	}
	m2.moveTo(0)
	if m2.top != 0 {
		t.Fatalf("top=%d after cursor home, want 0", m2.top)
	}
}

// Space, i, Enter and the marks act on the focused tile exactly as on a
// row — the tile is the selection.
func TestGridMarksSpaceAndOpenOnTile(t *testing.T) {
	fileBacker(t, map[string][]byte{
		"/host/FM/LOOK.QOI":  qoi(16, 16, 255, 0, 0),
		"/host/FM/WORDS.TXT": []byte("words\n"),
	})
	m := testModel(entry("LOOK.QOI", false), entry("WORDS.TXT", false))
	m.handleKey(runeKey('t'))
	// The focused tile's sixel is armed through QuickLook's bounds.
	if len(m.gridFSixel) == 0 || m.gridFTW != 64 || m.gridFTH != 64 {
		t.Fatalf("focus thumb = %dx%d sixel=%dB, want 64x64 armed",
			m.gridFTW, m.gridFTH, len(m.gridFSixel))
	}
	// m marks the tile: the receipt and the gutter glyph are the row's.
	m.handleKey(runeKey('m'))
	if !m.isMarked("LOOK.QOI") {
		t.Fatal("m must mark the focused tile")
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerMark+"LOOK.QOI n=1") {
		t.Fatalf("mark marker missing: %q", got)
	}
	if row := m.tileNameRow(0); !strings.Contains(row, ">*") {
		t.Fatalf("marked+focused name row must carry \">*\": %q", row)
	}
	// Space opens the QuickLook pane on the tile's file.
	m.handleKey(runeKey(' '))
	if m.mode != modeQuickLook || m.ql.kind != qlImage {
		t.Fatalf("space on the tile must open the image arm: mode=%d kind=%d",
			m.mode, m.ql.kind)
	}
	m.handleKey(runeKey(' '))
	if m.mode != modeNormal {
		t.Fatal("space did not hand the frame back")
	}
	// i opens the properties card on the tile.
	m.handleKey(runeKey('i'))
	if m.mode != modeProps {
		t.Fatalf("i on the tile must open props: mode=%d", m.mode)
	}
	m.handleKey(keys.Event{Key: keys.KeyEsc})
	// Enter on a file dispatches the mime open decision, same as a row.
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	if got := pendingJoined(&m); !strings.Contains(got, markerOpenFile+"LOOK.QOI type=image") {
		t.Fatalf("enter on the tile must dispatch its open: %q", got)
	}
}

// `t` toggles back to the pane view it was opened from; Tab from the
// grid steps out to the OTHER pane view.
func TestGridToggleRestoresView(t *testing.T) {
	m := testModel(entry("A.TXT", false))
	fileBacker(t, map[string][]byte{"/host/FM/A.TXT": []byte("a\n")})
	m.handleKey(runeKey('t'))
	if m.view != viewGrid || m.viewUnder != viewSplit {
		t.Fatalf("grid entry from split: view=%d under=%d", m.view, m.viewUnder)
	}
	m.handleKey(runeKey('t'))
	if m.view != viewSplit {
		t.Fatalf("second t must return to split: view=%d", m.view)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerGridOff) {
		t.Fatalf("grid-off marker missing: %q", got)
	}
	// From the full list: t grids, t returns to the full list.
	m.handleKey(keys.Event{Key: keys.KeyTab})
	m.handleKey(runeKey('t'))
	if m.view != viewGrid || m.viewUnder != viewList {
		t.Fatalf("grid entry from list: view=%d under=%d", m.view, m.viewUnder)
	}
	// Tab inside the grid steps out to the other pane view (split).
	m.handleKey(keys.Event{Key: keys.KeyTab})
	if m.view != viewSplit {
		t.Fatalf("tab from grid-under-list must land on split: view=%d", m.view)
	}
}

// The frame paints truecolour mosaic cells, the focused tile's name row
// in the selection style, the folder tile's word, and the sixel behind
// a CUP into the preview pane — with the covered rows blanked.
func TestGridRenderShape(t *testing.T) {
	fileBacker(t, map[string][]byte{
		"/host/FM/LOOK.QOI":  qoi(16, 16, 255, 0, 0),
		"/host/FM/WORDS.TXT": []byte("words\n"),
	})
	m := testModel(entry("SUB", true), entry("LOOK.QOI", false), entry("WORDS.TXT", false))
	// Sorted: SUB/ first, then LOOK.QOI, WORDS.TXT — focus the image.
	m.moveTo(1)
	m.handleKey(runeKey('t'))
	m.gridStep() // drain: resolves LOOK.QOI (cached via focus) + WORDS.TXT
	frame := m.render()
	if !strings.Contains(frame, "48;2;255;0;0m") {
		t.Fatal("the red mosaic cells are missing from the frame")
	}
	if !strings.Contains(frame, "\x1bPq\"1;1;64;64") {
		t.Fatal("the focus sixel's raster declaration is missing")
	}
	if !strings.Contains(frame, "> LOOK.QOI") {
		t.Fatal("the focused tile's name row is missing")
	}
	lines := visibleLines(frame)
	if len(lines) != m.rows {
		t.Fatalf("grid frame has %d lines, want %d", len(lines), m.rows)
	}
	// The folder tile's word sits inside the SUB tile's mosaic rows.
	found := false
	for _, ln := range lines[2:7] {
		if strings.Contains(ln, "dir") {
			found = true
		}
	}
	if !found {
		t.Fatal("the folder tile's word is missing")
	}
	// The sixel's cell span sits inside the preview pane and its rows
	// are blanked there — the covered preview text is gone.
	r0, c0, tw, th := m.gridSixelSpan()
	if c0 < m.listCols()+1 || c0+tw > m.cols || r0 < 2 || r0+th > m.rows-2 {
		t.Fatalf("sixel span (%d,%d %dx%d) escapes the preview pane", r0, c0, tw, th)
	}
	for i := r0 - 2; i < r0-2+th; i++ {
		if strings.TrimSpace(lines[i+2]) != "" && !strings.Contains(lines[i+2], "│") {
			t.Fatalf("preview row %d under the sixel is not blanked: %q", i+2, lines[i+2])
		}
	}
}

// A press on a tile selects it (the tile pitch owns its name row and its
// gutter); the press-on-selected pends the open to the release edge, the
// same contract the list rows hold.
func TestGridClickSelectsTile(t *testing.T) {
	m := testModel(entry("D1", true), entry("D2", true), entry("D3", true))
	m.handleKey(runeKey('t'))
	// SGR coords are 1-based: tile 1's mosaic sits at cells col 11..20
	// (0-based), rows 2..6 — click its middle.
	m.handleClick(16, 5) // col 15, row 4 -> tile row 0, tile col 1
	if m.sel != 1 {
		t.Fatalf("tile click selected %d, want 1", m.sel)
	}
	// The name row belongs to the tile above it — a press there selects
	// tile 0, not tile 1.
	m.handleClick(5, 8) // col 4, row 7 -> name row of tile 0
	if m.sel != 0 || m.pressRow != 0 {
		t.Fatalf("name-row click must hit the tile above: sel=%d press=%d", m.sel, m.pressRow)
	}
	m.releaseClick()
	// A press on the selected tile pends its open to the release edge,
	// the same contract the list rows hold: press, release, navigate.
	m.handleClick(5, 4) // tile 0, already selected -> pends the open
	m.releaseClick()
	if m.path != "/host/FM/D1" {
		t.Fatalf("press+release on the tile must open it: path=%q", m.path)
	}
}

// The session blob's view byte gains the grid value: a grid session
// round-trips into the grid, and the stale-value clamp still defaults.
func TestStateGridRoundTrip(t *testing.T) {
	m := stateModel("/host/FM", 1, 0, viewGrid, sortDirs)
	st, ok := decodeState(m.encodeState())
	if !ok {
		t.Fatal("a grid blob must decode")
	}
	if st.view != viewGrid {
		t.Fatalf("round trip lost the grid view: %#v", st)
	}
	// An out-of-range byte still clamps to the default.
	b := stateModel("/host/FM", 0, 0, viewMode(9), sortDirs).encodeState()
	if st, ok = decodeState(b); !ok || st.view != viewSplit {
		t.Fatalf("unknown view byte must clamp to split: %#v ok=%v", st, ok)
	}
	// applyState reopens in the grid: the tile queue is rebuilt and the
	// focus decodes against the restored listing.
	m2 := testModel(entry("A.TXT", false))
	fileBacker(t, map[string][]byte{"/host/FM/A.TXT": []byte("a\n")})
	m2.applyState(filesState{path: m2.path, view: viewGrid})
	if m2.view != viewGrid || m2.viewUnder != viewSplit {
		t.Fatalf("restored grid: view=%d under=%d", m2.view, m2.viewUnder)
	}
	if len(m2.gridRef) != m2.n {
		t.Fatal("a restored grid did not rebuild its tile table")
	}
	if len(m2.gridFSixel) != 0 && m2.gridTileAt(0) == nil {
		t.Fatal("restored focus armed a sixel without a tile")
	}
}

// Leaving the grid and re-entering re-emits the focus marker, and a
// re-sorted listing rebuilds the tile table without re-reading cached
// tiles.
func TestGridReentryAndResort(t *testing.T) {
	files := map[string][]byte{
		"/host/FM/A.QOI": qoi(4, 4, 255, 0, 0),
		"/host/FM/B.TXT": []byte("b\n"),
	}
	counts := countingBacker(t, files)
	m := testModel(entry("A.QOI", false), entry("B.TXT", false))
	m.handleKey(runeKey('t'))
	m.handleKey(runeKey('t')) // off
	m.handleKey(runeKey('t')) // on again — focus marker re-emits
	got := pendingJoined(&m)
	if strings.Count(got, markerGridFocus+"A.QOI thumb=64x64") != 2 {
		t.Fatalf("re-entry must re-emit the focus marker: %q", got)
	}
	// The cache survives the toggle: A.QOI was read exactly once.
	if *counts["/host/FM/A.QOI"] != 1 {
		t.Fatalf("cache did not hold across the toggle: %d reads", *counts["/host/FM/A.QOI"])
	}
	// A re-sort rebuilds the tile table and re-points the queue at the
	// unresolved entries — the cached ones still do not re-read.
	m.handleKey(runeKey('s'))
	if m.gridPending() {
		m.gridStep()
	}
	if *counts["/host/FM/A.QOI"] != 1 {
		t.Fatalf("a re-sort must not re-read cached tiles: %d reads", *counts["/host/FM/A.QOI"])
	}
}
