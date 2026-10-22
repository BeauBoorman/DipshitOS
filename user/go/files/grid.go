// M167a (issue #2989): the `t` thumbnail grid. A folder of pictures is
// recognisable at a glance inside the one-image terminal: each entry is a
// tile — a tileW x tileH mosaic of terminal cells painted with truecolour
// backgrounds, the name on the row below. The kernel commits at most one
// sixel per terminal (term_image.slots = 1), so a grid of sixels is
// impossible by construction; the cell mosaic is the honest shape, and the
// ONE image the kernel can hold goes to the focused tile — emitted as a
// real sixel thumbnail in the preview pane through QuickLook's encoder
// and bounds. Moving the cursor replaces it, which is exactly the
// kernel's eviction rule.
//
// Decode budget: tiles resolve lazily — at most gridDecodePerPass per
// loop pass (main steps it like a batch), placeholders until done. A
// cache of at most gridCacheMax tiles keyed by path+size+mtime holds the
// cell colours only, never a decoded raster. A file that fails to decode
// keeps its placeholder and is not retried while its key stands.
//
// The grid keeps the two-pane frame: the tile field takes the list
// pane's cells, the preview pane keeps the selection preview with the
// focus sixel centred inside it (the covered rows blanked, the same rule
// the QuickLook image arm paints by).
package main

import (
	"strings"

	"virelai/mime"
	"virelai/vi"
	"virelai/webrender"
)

const (
	// tileW/tileH are the mosaic's footprint in cells, fixed by the
	// layout (the card's "about 10x5"). The name strip rides one row
	// under the mosaic and one gutter column follows each tile, so the
	// tile pitch is (tileW+1) x (tileH+1).
	tileW = 10
	tileH = 5
	// gridDecodePerPass is the card's lazy-decode budget: at most two
	// unresolved tiles per loop pass.
	gridDecodePerPass = 2
	// gridCacheMax bounds the tile cache (the card's 64).
	gridCacheMax = 64
)

// The tile palette: muted shades the kind words sit on. The pending
// placeholder is a step darker than a decided tile so a half-painted row
// reads as "still arriving"; failed decodes go warm so a dead image never
// reads as a resolved non-image; directories carry a folder-amber.
const (
	tilePendingRGB uint32 = 0x1b2129
	tileWordRGB    uint32 = 0x222a38 // the colMenu plate's ink
	tileFailedRGB  uint32 = 0x382228
	tileDirRGB     uint32 = 0x3a3220
	tileBlankRGB   uint32 = 0x14181d // a transparent pixel's stand-in
	tileWordFg     uint32 = 0x788290 // the colDim ink
)

type tileKind uint8

const (
	tilePending tileKind = iota
	tileImage            // mosaic decoded — cells hold the cell colours
	tileFailed           // decode refused — placeholder while the key stands
	tileWord             // non-image — muted tile carrying the mime word
	tileDir              // a directory or mount-table dir — the folder tile
)

// gridTile is one resolved tile. The cache holds cell colours only (the
// card's rule: no decoded rasters) — cells is populated for tileImage,
// word for the muted kinds.
type gridTile struct {
	kind  tileKind
	cells [tileW * tileH]uint32
	word  string
}

// The shared immutable tiles: directory rows, non-dir mount-table rows,
// unresolved (pending) tiles, and paths that can never resolve.
var (
	pendingTile = &gridTile{kind: tilePending}
	dirTile     = &gridTile{kind: tileDir, word: "dir"}
	volTile     = &gridTile{kind: tileWord, word: "vol"}
	badTile     = &gridTile{kind: tileFailed, word: "err"}
)

// gridKey is the tile cache key — path, size and mtime (the card's
// keying). A file whose bytes changed moves to a new key; a failed tile
// is retried only then. The mtime comes off the same statTimes seam the
// QuickLook card uses; a path the stat wire cannot serve keys on
// path+size alone.
type gridKey struct {
	path string
	size int64
	mt   int64
	mtOK bool
}

// gridCols is the tile columns the field holds — the list pane's width
// cut into (tileW+1) pitches.
func (m model) gridCols() int {
	c := listWidth(m.cols) / (tileW + 1)
	if c < 1 {
		c = 1
	}
	return c
}

// gridRows is the tile rows the body band holds — each pitch is the
// mosaic plus its name row.
func (m model) gridRows() int {
	r := m.bodyRows() / (tileH + 1)
	if r < 1 {
		r = 1
	}
	return r
}

// gridKeyOf derives the cache key for listing index i. ok=false means the
// path is unjoinable — the tile can never resolve and stays a placeholder
// without a cache entry.
func (m *model) gridKeyOf(i int) (gridKey, bool) {
	p, ok := joinPath(m.path, m.entries[i].NameString())
	if !ok {
		return gridKey{}, false
	}
	k := gridKey{path: p, size: int64(m.entries[i].Size)}
	if ns, _, ok, _ := statTimes(p); ok {
		k.mt, k.mtOK = ns, true
	}
	return k, true
}

// gridPut stores a resolved tile under its key, evicting oldest-first
// once the cache is full. A repeat put refreshes in place — the entry
// keeps its eviction slot.
func (m *model) gridPut(k gridKey, t gridTile) {
	if m.gridTiles == nil {
		m.gridTiles = make(map[gridKey]*gridTile)
	}
	if p, ok := m.gridTiles[k]; ok {
		*p = t
		return
	}
	if len(m.gridOrder) >= gridCacheMax {
		delete(m.gridTiles, m.gridOrder[0])
		m.gridOrder = m.gridOrder[1:]
	}
	cp := t
	m.gridTiles[k] = &cp
	m.gridOrder = append(m.gridOrder, k)
}

// gridSync rebuilds the per-listing tile table: cached entries resolve to
// their cached tile, the rest queue for the lazy pass. Called when the
// grid opens and on every listing mutation while it stands (refresh,
// re-sort). The decoded/failed marker is emitted once per sync when the
// queue is already drained — an all-resolved listing still gets its
// receipt.
func (m *model) gridSync() {
	m.gridRef = make([]*gridTile, m.n)
	m.gridQueue = m.gridQueue[:0]
	m.gridTilesEmitted = false
	if m.path != volsPath {
		for i := 0; i < m.n; i++ {
			if m.entries[i].Dir() {
				continue
			}
			k, ok := m.gridKeyOf(i)
			if !ok {
				continue
			}
			if t := m.gridTiles[k]; t != nil {
				m.gridRef[i] = t
				continue
			}
			m.gridQueue = append(m.gridQueue, i)
		}
	}
	m.gridEmitStats()
}

// gridPending reports whether the lazy decode has queued work.
func (m *model) gridPending() bool { return len(m.gridQueue) > 0 }

// gridStep is one lazy-decode pass: resolve at most gridDecodePerPass
// queued tiles. Cached hits (a focus decode may resolve an entry ahead of
// the pass) are skipped without spending the budget — only real decodes
// count against it. The decoded/failed marker fires once, when the queue
// first drains.
func (m *model) gridStep() {
	did := 0
	for len(m.gridQueue) > 0 && did < gridDecodePerPass {
		i := m.gridQueue[0]
		m.gridQueue = m.gridQueue[1:]
		if i >= m.n || m.entries[i].Dir() {
			continue
		}
		k, ok := m.gridKeyOf(i)
		if !ok {
			continue
		}
		if _, done := m.gridTiles[k]; done {
			continue
		}
		m.gridResolve(k, i)
		did++
	}
	m.gridEmitStats()
}

// gridEmitStats prints the tile accounting once the queue stands empty —
// decoded/failed count the CURRENT listing's tile states, so the marker
// describes the screen whether the tiles came from the pass or the cache.
func (m *model) gridEmitStats() {
	if len(m.gridQueue) > 0 || m.gridTilesEmitted {
		return
	}
	m.gridTilesEmitted = true
	dec, fail := 0, 0
	for i := 0; i < m.n && i < len(m.gridRef); i++ {
		if t := m.gridRef[i]; t != nil {
			switch t.kind {
			case tileImage:
				dec++
			case tileFailed:
				fail++
			}
		}
	}
	m.emit(markerGridTiles + "decoded=" + vi.Itoa64(int64(dec)) +
		" failed=" + vi.Itoa64(int64(fail)))
}

// gridDecode is the one read+decode path behind every tile resolution:
// the read bound is the QuickLook arm's (one read serves the sniff and
// the decode), the sniff picks the arm, and a decodable image downsamples
// to the cell mosaic. It returns the resolved tile and the decoded
// raster (nil for non-images) so the focus arm can reuse the decode for
// its sixel without a second read.
func (m *model) gridDecode(k gridKey, name string) (gridTile, *webrender.Image) {
	data, rc := readHead(k.path, maxQuickBytes)
	if rc < 0 {
		return gridTile{kind: tileFailed, word: "err"}, nil
	}
	id := mime.Sniff(name, data)
	if id != mime.Image {
		return gridTile{kind: tileWord, word: id.String()}, nil
	}
	im, err := decodeImage(data)
	if err != nil || im == nil || im.Width < 1 || im.Height < 1 ||
		len(im.Pix) != im.Width*im.Height {
		return gridTile{kind: tileFailed, word: "image"}, nil
	}
	t := gridTile{kind: tileImage}
	mosaic(im, &t.cells)
	return t, im
}

// gridResolve runs the lazy pass's per-entry decode and lands it under
// the key — a failed decode is cached as failed, so it is never retried
// while the key stands.
func (m *model) gridResolve(k gridKey, i int) {
	t, _ := m.gridDecode(k, m.entries[i].NameString())
	m.gridPut(k, t)
	if i < len(m.gridRef) {
		m.gridRef[i] = m.gridTiles[k]
	}
}

// gridTileAt is the render half of the resolution: directory rows paint
// the folder tile, non-dir mount-table rows the volume tile, resolved
// entries their cached tile, and everything else the pending placeholder.
func (m *model) gridTileAt(i int) *gridTile {
	e := m.entries[i]
	if e.Dir() {
		return dirTile
	}
	if m.path == volsPath {
		return volTile
	}
	if i < len(m.gridRef) && m.gridRef[i] != nil {
		return m.gridRef[i]
	}
	return pendingTile
}

// toggleGrid is the `t` chord: the grid view over the listing, and back
// to the pane view it was opened from. Entering emits the layout marker
// (the tile columns and rows the frame holds) and arms the focus decode;
// the tile queue drains on the loop's lazy passes.
func (m *model) toggleGrid() {
	if m.tar != nil {
		// M167c: tiles key on real path+size+mtime — archive rows carry
		// none of those.
		m.tarReadOnly("grid")
		return
	}
	if m.view == viewGrid {
		m.view = m.viewUnder
		m.gridFName = "" // re-entry re-emits the focus marker
		m.emit(markerGridOff)
		m.status = "view " + viewNameOf(m.view)
		m.ensureSelVisible()
		return
	}
	m.viewUnder = m.view
	m.view = viewGrid
	m.emit(markerGridOn + "cols=" + vi.Itoa64(int64(m.gridCols())) +
		" rows=" + vi.Itoa64(int64(m.gridRows())))
	m.status = "view grid"
	m.gridFocus()
	m.gridSync()
	m.ensureSelVisible()
}

// gridMove is the grid's tile-step: j/k and the verticals step a tile
// ROW, h/l and the horizontals a tile column, linearly over the listing
// and clamped at every edge. The selection is the focus — the preview
// load behind it also re-arms the sixel.
func (m *model) gridMove(dr, dc int) {
	if m.n == 0 {
		return
	}
	sel := m.sel + dr*m.gridCols() + dc
	if sel < 0 {
		sel = 0
	}
	if sel >= m.n {
		sel = m.n - 1
	}
	m.sel = sel
	m.ensureSelVisible()
	m.loadPreview()
}

// gridRune is the grid's non-nav rune table — every binding the list has
// except the four nav letters, which move by tile instead. Space, `i`,
// Enter and the M155b marks act on the focused tile exactly as they do on
// a row.
func (m *model) gridRune(r rune) {
	switch r {
	case 't':
		m.toggleGrid()
	case 'g':
		m.moveTo(0)
	case 'G':
		m.moveTo(m.n - 1)
	case 'q':
		m.quit = true
	case 'v':
		m.showVolumes()
	case 'f':
		// M167b (#2992): the favorites pseudo-listing — its rows are all
		// dirs, so the grid shows plain dir tiles for them.
		m.showFavs()
	case 'b':
		m.toggleFav()
	case 's':
		m.cycleSort()
	case 'r':
		m.startRename()
	case 'd':
		m.startDelete()
	case 'u':
		m.restoreLatest()
	case 'c':
		m.yankClip(false)
	case 'x':
		m.yankClip(true)
	case 'p':
		m.pasteClip()
	case ' ':
		m.openQuickLook()
	case 'i':
		m.openProps()
	case 'm':
		m.toggleMark()
	case 'M':
		m.clearMarks()
	case '/':
		m.startSearch()
	case 'o':
		m.startOpenWith()
	case 'e':
		m.exportSel()
	case '?':
		m.openHints()
	}
}

// entryIdxAt maps a 0-based client cell onto the entry under it in the
// active view — a list row in the list views, a tile in the grid (the
// name row and the gutter belong to the tile on their left).
func (m model) entryIdxAt(col, row int) int {
	if m.view == viewGrid {
		if col < 0 || row < 2 {
			return -1
		}
		gc := m.gridCols()
		tc := col / (tileW + 1)
		if tc >= gc {
			return -1
		}
		return m.top + ((row-2)/(tileH+1))*gc + tc
	}
	return m.top + row - 2
}

// gridFocus is the focus half of every selection change in the grid:
// decode the focused image (once per key — the memo stands while it does)
// into the preview pane's sixel, and name the focus on the serial line.
// The marker rides pending like every other frame marker; a non-image or
// a failed tile reports thumb=0x0, never a painted lie.
func (m *model) gridFocus() {
	name := ""
	tw, th := 0, 0
	if e, ok := m.selEntry(); ok {
		name = e.NameString()
		tw, th = m.armFocus(e)
	} else {
		m.clearFocusThumb()
	}
	if name != m.gridFName {
		m.gridFName = name
		if name != "" {
			m.emit(markerGridFocus + name + " thumb=" +
				vi.Itoa64(int64(tw)) + "x" + vi.Itoa64(int64(th)))
		}
	}
}

// clearFocusThumb drops the armed sixel — a focus on anything that is
// not a decoded image leaves the pane's image slot empty, never the
// previous tile's ghost.
func (m *model) clearFocusThumb() {
	m.gridFSixel = nil
	m.gridFTW, m.gridFTH = 0, 0
}

// armFocus produces the focused tile's sixel: the decode is shared with
// the tile mosaic (one read serves both), the thumbnail is scaled inside
// QuickLook's bank bound, and a cached failure is never retried — the
// no-retry rule the tile cache promises applies to the focus decode too.
// The memo (gridFKey) makes a repeat visit free while the key stands.
func (m *model) armFocus(e vi.DirEntry) (int, int) {
	if e.Dir() || m.path == volsPath {
		m.gridFKey = gridKey{}
		m.clearFocusThumb()
		return 0, 0
	}
	k, ok := m.gridKeyOf(m.sel)
	if !ok {
		m.gridFKey = gridKey{}
		m.clearFocusThumb()
		return 0, 0
	}
	if t := m.gridTiles[k]; t != nil && t.kind == tileFailed {
		m.gridFKey = k
		m.clearFocusThumb()
		return 0, 0
	}
	if k == m.gridFKey {
		return m.gridFTW, m.gridFTH // memo hit — sixel fields still stand
	}
	m.gridFKey = k
	m.clearFocusThumb()
	t, im := m.gridDecode(k, e.NameString())
	m.gridPut(k, t)
	if m.sel < len(m.gridRef) {
		m.gridRef[m.sel] = m.gridTiles[k]
	}
	if t.kind != tileImage || im == nil {
		return 0, 0
	}
	th := thumbnail(im, qlImageMaxW, qlImageMaxH)
	seq, err := sixelEncode(th)
	if err != nil {
		return 0, 0 // the tile decoded; only the sixel refused (palette bound)
	}
	m.gridFSixel = seq
	m.gridFTW, m.gridFTH = th.Width, th.Height
	m.gridFCW, m.gridFCH = termCell()
	return th.Width, th.Height
}

// gridSixelSpan is the focus sixel's cell rect on the rung it was encoded
// under: centred inside the preview pane, clamped so the placement's IND
// steps can never reach the scroll bottom (the same rule qlOrigin holds).
func (m model) gridSixelSpan() (row, col, tw, th int) {
	cw, ch := int(m.gridFCW), int(m.gridFCH)
	if cw < 1 {
		cw = 8
	}
	if ch < 1 {
		ch = 16
	}
	tw = (m.gridFTW + cw - 1) / cw
	th = (m.gridFTH + ch - 1) / ch
	lw := m.listCols()
	pw := m.cols - lw - 1
	col = lw + 1 + (pw-tw)/2
	if col < lw+1 {
		col = lw + 1
	}
	if col+tw > m.cols {
		col = m.cols - tw
		if col < lw+1 {
			col = lw + 1
		}
	}
	row = 2 + (m.bodyRows()-th)/2
	if row < 2 {
		row = 2
	}
	if row+th > m.rows-2 {
		row = m.rows - 2 - th
		if row < 2 {
			row = 2
		}
	}
	return row, col, tw, th
}

// mosaic downsamples a decoded raster to the tile's cell colours: each
// cell is the rounded mean of the source pixels its region covers (a
// region of zero source pixels — an upscale — samples its single nearest
// pixel). Transparent pixels (alpha < 128, the sixel transparency rule)
// contribute the blank stand-in rather than their channels.
func mosaic(im *webrender.Image, out *[tileW * tileH]uint32) {
	for cy := 0; cy < tileH; cy++ {
		y0 := cy * im.Height / tileH
		y1 := (cy + 1) * im.Height / tileH
		if y1 <= y0 {
			y1 = y0 + 1
		}
		if y1 > im.Height {
			y1 = im.Height
		}
		for cx := 0; cx < tileW; cx++ {
			x0 := cx * im.Width / tileW
			x1 := (cx + 1) * im.Width / tileW
			if x1 <= x0 {
				x1 = x0 + 1
			}
			if x1 > im.Width {
				x1 = im.Width
			}
			var rs, gs, bs, n uint32
			for y := y0; y < y1; y++ {
				for x := x0; x < x1; x++ {
					px := im.Pix[y*im.Width+x]
					if px>>24 < 128 {
						px = tileBlankRGB
					}
					rs += px >> 16 & 0xff
					gs += px >> 8 & 0xff
					bs += px & 0xff
					n++
				}
			}
			out[cy*tileW+cx] = ((rs+n/2)/n)<<16 | ((gs+n/2)/n)<<8 | (bs+n/2)/n
		}
	}
}

// --- the frame ---------------------------------------------------------

// gridPaneRow paints one tile-field body line: tile row tr = i/pitch,
// mosaic or name by the sub-row, one gutter column per tile, and the
// field padded to the pane width. An empty listing gets the shared
// empty-state panel, the same presenter the list view uses.
func (m model) gridPaneRow(i, w int) string {
	if m.n == 0 && m.path != volsPath && m.path != favsView {
		rows := m.emptyListRows(w, m.bodyRows())
		if i >= len(rows) {
			return strings.Repeat(" ", w)
		}
		if strings.TrimSpace(rows[i]) == "" {
			return rows[i]
		}
		return colDim + rows[i] + colReset
	}
	tr, sub := i/(tileH+1), i%(tileH+1)
	if tr >= m.gridRows() {
		return strings.Repeat(" ", w)
	}
	var b strings.Builder
	gc := m.gridCols()
	for tc := 0; tc < gc; tc++ {
		idx := m.top + tr*gc + tc
		if idx >= m.n {
			b.WriteString(strings.Repeat(" ", tileW+1))
			continue
		}
		if sub < tileH {
			b.WriteString(m.tileMosaicRow(idx, sub))
		} else {
			b.WriteString(m.tileNameRow(idx))
		}
		b.WriteByte(' ')
	}
	if used := gc * (tileW + 1); used < w {
		b.WriteString(strings.Repeat(" ", w-used))
	}
	return b.String()
}

// tileMosaicRow is one mosaic row of a tile: decoded cells painted with
// their truecolour backgrounds (runs of equal colour share one SGR), and
// every other kind its flat shade — the word row carries the tile's word
// in the dim ink.
func (m model) tileMosaicRow(idx, sub int) string {
	t := m.gridTileAt(idx)
	var b strings.Builder
	if t.kind == tileImage {
		var last uint32
		for x := 0; x < tileW; x++ {
			rgb := t.cells[sub*tileW+x]
			if x == 0 || rgb != last {
				sgrBG(&b, rgb)
				last = rgb
			}
			b.WriteByte(' ')
		}
		b.WriteString(colReset)
		return b.String()
	}
	sgrBG(&b, tileBG(t.kind))
	if sub == tileH/2 && t.word != "" {
		word := t.word
		if len(word) > tileW {
			word = word[:tileW]
		}
		left := (tileW - len(word)) / 2
		sgrFG(&b, tileWordFg)
		b.WriteString(strings.Repeat(" ", left))
		b.WriteString(word)
		b.WriteString(strings.Repeat(" ", tileW-left-len(word)))
	} else {
		b.WriteString(strings.Repeat(" ", tileW))
	}
	b.WriteString(colReset)
	return b.String()
}

// tileNameRow is the name strip under a tile's mosaic — the same "> " /
// " *" gutter the list rows carry, the focused tile in colSel.
func (m model) tileNameRow(idx int) string {
	e := m.entries[idx]
	pre := "  "
	if m.isMarked(e.NameString()) {
		pre = " *"
	}
	if idx == m.sel {
		if pre == " *" {
			pre = ">*"
		} else {
			pre = "> "
		}
		label := clipVis(entryLabel(e), tileW-2)
		return colSel + pre + label +
			strings.Repeat(" ", tileW-2-visLen(label)) + colReset
	}
	label := clipVis(pre+entryLabel(e), tileW)
	style := colFile
	if e.Dir() {
		style = colDir
	}
	return style + label + colReset + strings.Repeat(" ", tileW-visLen(label))
}

// gridPreviewRow is the preview pane's line inside the grid frame — the
// rows the focus sixel covers are blanked, because the kernel's image
// cells replace them (the QuickLook image arm's rule, smaller pane).
func (m model) gridPreviewRow(i int, plines []string, w int) string {
	if len(m.gridFSixel) > 0 {
		r0, _, _, th := m.gridSixelSpan()
		if i+2 >= r0 && i+2 < r0+th {
			return strings.Repeat(" ", w)
		}
	}
	return m.previewRow(i, plines, w)
}

// tileBG is the flat shade a non-mosaic tile paints.
func tileBG(k tileKind) uint32 {
	switch k {
	case tileFailed:
		return tileFailedRGB
	case tileDir:
		return tileDirRGB
	case tileWord:
		return tileWordRGB
	default:
		return tilePendingRGB
	}
}

// sgrBG emits the truecolour cell-background SGR for one 0xRRGGBB.
func sgrBG(b *strings.Builder, rgb uint32) {
	b.WriteString("\x1b[48;2;")
	b.WriteString(vi.Itoa64(int64(rgb>>16) & 0xff))
	b.WriteByte(';')
	b.WriteString(vi.Itoa64(int64(rgb>>8) & 0xff))
	b.WriteByte(';')
	b.WriteString(vi.Itoa64(int64(rgb & 0xff)))
	b.WriteByte('m')
}

// sgrFG emits the truecolour foreground SGR for one 0xRRGGBB.
func sgrFG(b *strings.Builder, rgb uint32) {
	b.WriteString("\x1b[38;2;")
	b.WriteString(vi.Itoa64(int64(rgb>>16) & 0xff))
	b.WriteByte(';')
	b.WriteString(vi.Itoa64(int64(rgb>>8) & 0xff))
	b.WriteByte(';')
	b.WriteString(vi.Itoa64(int64(rgb & 0xff)))
	b.WriteByte('m')
}
