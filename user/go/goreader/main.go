// Command goreader is GOREADER.ELF — the M143a (issue #2792) document
// reader: the Document mime's registered handler (image/apps.txt `opens=
// document`, mime.go's Register(Document, "GOREADER.ELF", "Reader")). It
// opens a PDF off the share, renders pages through the bounded ADR 0040
// engine (user/go/pdf — read-only), and adds the product surface the
// engine never had: page nav, zoom, find, save_state.
//
// The engine renders exactly one 96 dpi page bitmap per call and re-checks
// the whole document each time — that IS the "cache holds only the visible
// page" rule: this app keeps one Page (inside the arena) plus one blended
// display copy, and nothing else.
//
// Every marker below prints AFTER the syscall it reports returned, so the
// go-reader gate's asserts only pass if the app actually ran.
package main

import (
	"virelai/appkit"
	"virelai/draw"
	"virelai/find"
	"virelai/pdf"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/webrender"
	"virelai/widgets"
)

const (
	appName  = "GOREADER.ELF"
	appTitle = "Reader"

	markerOpen        = "goreader: open id="
	markerTabAware    = "goreader: tab-aware (full-viewport)"
	markerNotTabAware = "goreader: not-tab-aware (shim or WND desktop)"
	markerOpenFailed  = "goreader: failed to open window"
	markerEmpty       = "goreader: empty (no document)"
	markerLoaded      = "goreader: loaded "
	markerRefuse      = "goreader: refuse "
	markerReadErr     = "goreader: read err"
	markerPage        = "goreader: page "
	markerZoom        = "goreader: zoom z="
	markerFit         = "goreader: fit z="
	markerFind        = "goreader: find '"
	markerFindMiss    = "goreader: find miss '"
	markerFindBar     = "goreader: find bar"
	markerStateSaved  = "goreader: state saved n="
	markerStateStale  = "goreader: state stale"
	markerRestored    = "goreader: restored "
	markerPos         = "goreader: pos "
	markerPosSaved    = "goreader: pos saved n="
	markerPosErr      = "goreader: pos rc="
	markerBookmark    = "goreader: bookmark "
	markerSave        = "goreader: save "
	markerPresent     = "goreader: present"
	markerReady       = "goreader: ready"
	markerQuit        = "goreader: quit"
	markerWinClose    = "goreader: win_close"
	markerOK          = "goreader OK"
)

// exitQuit is this app's clean-close status, matching the GOVIEW family's
// convention for an interactive viewer.
const exitQuit = 0

// Highlight colors for find hits: every hit on the page in a warm band,
// the current hit in the accent. Blended onto the display copy only.
const (
	hitRGB     = 0xE8C832
	hitPct     = 45
	hitCurRGB  = 0x3B82F6
	hitCurPct  = 55
	pageMargin = 8 // px of viewport margin around a jumped-to hit
)

// loadState is which step of open→read→render ended the document.
type loadState int

const (
	loadNone loadState = iota
	loadFailedOpen
	loadFailedRead
	loadTooLarge
	loadRefused // the engine refused: refuse names the ADR 0040 code
	loadOkay
)

// memSource is the app's pdf.Source: the whole document is already in
// memory (bounded by pdf.MaxSource at read time), so reads charge the
// ledger and copy — the engine's own 64 KiB window does the caching.
type memSource struct{ data []byte }

func (s *memSource) Length() int64 { return int64(len(s.data)) }

func (s *memSource) ReadAt(dst []byte, offset int64, l *pdf.Ledger) (int, pdf.Code) {
	if offset < 0 || int64(len(dst)) > s.Length()-offset {
		return 0, pdf.ReadFailed
	}
	if c := l.Read(uint64(len(dst))); c != pdf.OK {
		return 0, c
	}
	copy(dst, s.data[offset:offset+int64(len(dst))])
	return len(dst), pdf.OK
}

// hitRef is one find result: a byte range in one page's extracted text.
type hitRef struct {
	page, start, end int
}

type app struct {
	ta   *tabapp.TabApp
	path string
	name string
	st   loadState

	data  []byte
	src   *memSource
	arena []byte

	pg         pager
	pw, ph     int      // page size at 96 dpi
	page_      pdf.Page // current rendered page (arena-owned)
	disp       []uint32 // display copy: page pixels + blended hits
	refuse     string   // ADR 0040 code name when st == loadRefused
	zoomIdx    int
	fit        bool
	ox, oy     uint32
	texts      []pageText
	hits       []hitRef
	hitIdx     int
	find       appkit.Find       // the shared Ctrl+F overlay (M191c #3244)
	pick       appkit.FilePicker // save-a-copy modal; .Open gates key routing
	bmk        []int             // sorted bookmarked page indexes (≤16)
	pend       *pendState        // decoded save_state blob, applied post-load
	pendBad    bool
	pendingLog []string // markers flushed after the repaint they report

	// Position memory: key is this document's (path,size,sha8) identity,
	// posEnt the GOREADER.POS row it matched at open (nil on a miss), and
	// posDirty/posAt the debounce: a page/zoom/bookmark change is written
	// after posDebounceNs of quiet and unconditionally on close.
	key      posEntry
	posEnt   *posEntry
	posDirty bool
	posAt    uint64
}

// pendState is the decoded save_state blob waiting for the load it
// describes — the seat's RestoreState hook runs inside Init, before the
// document exists.
type pendState struct {
	path string
	page int
	zoom int
	fit  bool
	bmk  []int
}

func now() uint64 { return uint64(vi.Nanos()) }

// renderPage runs the engine for one page index into the shared arena. A
// refusal switches the app to its refused state and names the code.
func (a *app) renderPage(i int) bool {
	l := &pdf.Ledger{Max: pdf.MaxWork}
	start := now()
	l.Now, l.Deadline = now, start+pdf.MaxNanos
	p, stats, f := pdf.Render(a.src, i, a.arena, l)
	if f.Code != pdf.OK {
		a.st = loadRefused
		a.refuse = f.Error()
		return false
	}
	a.page_, a.pw, a.ph = p, int(p.Width), int(p.Height)
	a.pg.pages = int(stats.Pages)
	a.rebuildDisp()
	return true
}

// rebuildDisp refreshes the display copy for the current page + hit set.
func (a *app) rebuildDisp() {
	need := a.pw * a.ph
	if len(a.disp) != need {
		a.disp = make([]uint32, need)
	}
	copy(a.disp, a.page_.Pix[:need])
	for i, h := range a.hits {
		if h.page != a.pg.page {
			continue
		}
		var gs []glyphPos
		if h.page < len(a.texts) {
			gs = a.texts[h.page].glyphs
		}
		for _, r := range mergeHitRects(gs, h.start, h.end) {
			rgb, pct := uint32(hitRGB), uint32(hitPct)
			if i == a.hitIdx {
				rgb, pct = hitCurRGB, hitCurPct
			}
			blendRect(a.disp, a.pw, a.pw, a.ph, r, rgb, pct)
		}
	}
}

// load opens and reads the document, then renders page 0. The engine's
// refusal — not a parse guess — names what the window shows.
func (a *app) load(path string) {
	if len(path) == 0 || len(path) > vi.ExecArgMax {
		a.st = loadFailedOpen
		return
	}
	data, st := readDoc(path)
	if st != loadOkay {
		a.st = st
		if st == loadTooLarge {
			a.st = loadRefused
			a.refuse = "SourceLimit"
		}
		return
	}
	a.data = data
	a.src = &memSource{data: data}
	if !a.renderPage(0) {
		return
	}
	a.pg.page = 0
	a.texts = extractPages(data)
	a.st = loadOkay
	// Position memory: the document's identity is known only now that its
	// bytes are. The POS row it matches (if any) waits for applyPos — a
	// seat-restore blob still wins over the file.
	a.key = posKey(a.path, data)
	a.posEnt = posLookup(a.key)
	vi.ConsoleLine(markerLoaded + a.name + " pages=" + vi.Itoa64(int64(a.pg.pages)) +
		" " + vi.Itoa64(int64(a.pw)) + "x" + vi.Itoa64(int64(a.ph)) +
		" bytes=" + vi.Itoa64(int64(len(data))))
}

// readDoc reads at most pdf.MaxSource bytes — the engine's own admission
// ceiling. A larger file is the SourceLimit refusal by name, never a
// truncated parse.
func readDoc(path string) ([]byte, loadState) {
	h, r := vi.FileOpen(path, vi.ModeRead)
	if r < 0 {
		return nil, loadFailedOpen
	}
	defer vi.FileClose(uint32(h))
	out := make([]byte, 0, 65536)
	buf := make([]byte, 4096)
	for len(out) < pdf.MaxSource {
		n, rr := vi.FileRead(uint32(h), buf)
		if rr < 0 {
			return out, loadFailedRead
		}
		if n == 0 {
			break
		}
		out = append(out, buf[:n]...)
	}
	if len(out) == pdf.MaxSource {
		if n, rr := vi.FileRead(uint32(h), buf[:1]); rr >= 0 && n > 0 {
			return out, loadTooLarge // the engine's own SourceLimit
		}
	}
	return out, loadOkay
}

func (a *app) zoom() uint32 {
	if a.fit {
		vp := viewportRect(a.ta.W, a.ta.H, a.find.Open)
		return fitWidthZoom(vp.W, uint32(a.pw))
	}
	return zoomTable[a.zoomIdx]
}

func (a *app) maxOY() uint32 {
	vp := viewportRect(a.ta.W, a.ta.H, a.find.Open)
	_, dh := displayedSize(uint32(a.pw), uint32(a.ph), a.zoom())
	return panMax(uint32(a.ph), dh, vp.H)
}

// goPage renders and announces a page-model move.
func (a *app) goPage(i int) {
	if a.st != loadOkay || !a.pg.goTo(i) {
		return
	}
	a.ox, a.oy = 0, 0
	if a.renderPage(a.pg.page) {
		a.pendingLog = append(a.pendingLog,
			markerPage+vi.Itoa64(int64(a.pg.page+1))+"/"+vi.Itoa64(int64(a.pg.pages)))
		a.markPos()
	}
}

func (a *app) setZoom(idx int, fit bool) {
	if a.st != loadOkay {
		return
	}
	z := a.zoom()
	a.fit = fit
	if fit {
		a.zoomIdx = zoomDefaultIdx
	} else {
		a.zoomIdx = idx
	}
	if a.zoom() != z {
		vp := viewportRect(a.ta.W, a.ta.H, a.find.Open)
		dw, _ := displayedSize(uint32(a.pw), uint32(a.ph), a.zoom())
		a.ox = clampU32(a.ox, panMax(uint32(a.pw), dw, vp.W))
		a.oy = clampU32(a.oy, a.maxOY())
		a.markPos()
		if fit {
			a.pendingLog = append(a.pendingLog, markerFit+u32s(a.zoom())+"%")
		} else {
			a.pendingLog = append(a.pendingLog, markerZoom+u32s(a.zoom())+"%")
		}
	}
}

// ---------------------------------------------------------------------------
// Find
// ---------------------------------------------------------------------------

// findScan is the overlay's corpus seam: it scans every page's extracted
// text for pat and reports the hit count. The overlay calls it on every
// pattern edit and before every step.
func (a *app) findScan(pat string) int {
	a.hits = a.hits[:0]
	for p, pt := range a.texts {
		for _, off := range find.All(pt.text, []byte(pat)) {
			a.hits = append(a.hits, hitRef{p, off, off + len(pat)})
		}
	}
	return len(a.hits)
}

// jumpHit makes hit i current: page jump, then scroll so the hit's first
// glyph band sits inside the viewport's top quarter.
func (a *app) jumpHit(i int) {
	if len(a.hits) == 0 {
		return
	}
	n := len(a.hits)
	a.hitIdx = ((i % n) + n) % n
	h := a.hits[a.hitIdx]
	if h.page != a.pg.page {
		a.pg.page = h.page
		a.ox, a.oy = 0, 0
		a.renderPage(h.page)
		a.markPos()
	}
	if h.page < len(a.texts) {
		rs := mergeHitRects(a.texts[h.page].glyphs, h.start, h.end)
		if len(rs) > 0 {
			vp := viewportRect(a.ta.W, a.ta.H, a.find.Open)
			z := a.zoom()
			dw, _ := displayedSize(uint32(a.pw), uint32(a.ph), z)
			// The hit's top in page px, less a margin, is the new origin.
			target := rs[0].Y0 - int(pageMargin*100/z)
			if target < 0 {
				target = 0
			}
			a.oy = clampU32(uint32(target), a.maxOY())
			xt := rs[0].X0 - int(pageMargin*100/z)
			if xt < 0 {
				xt = 0
			}
			a.ox = clampU32(uint32(xt), panMax(uint32(a.pw), dw, vp.W))
		}
	}
	a.rebuildDisp()
}

// findShow is the overlay's hit callback: hit i becomes current (jumpHit
// does the page jump and the scroll), then the marker reports where the
// cycling landed — the `goreader: find '<pat>' hit=N/M page=P` shape the
// M143a bar printed, preserved verbatim.
func (a *app) findShow(i int) {
	a.jumpHit(i)
	a.pendingLog = append(a.pendingLog,
		markerFind+a.find.Pattern()+"' hit="+vi.Itoa64(int64(a.hitIdx+1))+"/"+
			vi.Itoa64(int64(len(a.hits)))+" page="+vi.Itoa64(int64(a.pg.page+1)))
}

// findMiss is the overlay's no-hits callback — the M143a miss marker.
func (a *app) findMiss() {
	a.pendingLog = append(a.pendingLog, markerFindMiss+a.find.Pattern()+"'")
}

// ---------------------------------------------------------------------------
// save_state (M125a protocol): the blob is `ver | path | page | zoom | fit`
// ---------------------------------------------------------------------------

func (a *app) saveState() []byte {
	b := encodeState(a.path, a.pg.page, int(a.zoom()), a.fit, a.bmk)
	vi.ConsoleLine(markerStateSaved + vi.Itoa64(int64(len(b))))
	return b
}

// noteState is the RestoreState hook, run inside Init before the document
// loads: it only decodes and stashes; the blob's path wins over argv (a
// session re-exec runs the bare bin).
func (a *app) noteState(b []byte) {
	path, page, zoom, fit, bmk, ok := decodeState(b)
	if !ok {
		a.pendBad = true
		return
	}
	a.pend = &pendState{path: path, page: page, zoom: zoom, fit: fit, bmk: bmk}
	if path != "" {
		a.path = path
		a.name = basename(path)
	}
}

// applyRestored runs right after load: page, zoom and bookmarks land on the
// document the blob described, clamped to what actually opened.
func (a *app) applyRestored() {
	if a.pendBad {
		vi.ConsoleLine(markerStateStale)
	}
	if a.pend == nil || a.st != loadOkay {
		return
	}
	z := a.pend.zoom
	a.fit = a.pend.fit
	idx := zoomDefaultIdx
	if !a.fit {
		// Nearest table stop to the saved percent keeps the table's bounds.
		best := 1 << 30
		for i, t := range zoomTable {
			d := int(t) - z
			if d < 0 {
				d = -d
			}
			if d < best {
				best, idx = d, i
			}
		}
	}
	a.zoomIdx = idx
	a.bmk = append(a.bmk, a.pend.bmk...)
	if a.pend.page > 0 {
		a.goPage(a.pend.page)
	}
	a.markPos()
	vi.ConsoleLine(markerRestored + "page=" + vi.Itoa64(int64(a.pg.page+1)) +
		" z=" + vi.Itoa64(int64(a.zoom())) +
		" bm=" + bmList(a.bmk))
}

// ---------------------------------------------------------------------------
// Position memory + bookmarks + save a copy (M153c, issue #2923)
// ---------------------------------------------------------------------------

// markPos arms the debounce: the position file is written on close and
// after posDebounceNs without a position-affecting change.
func (a *app) markPos() {
	if a.st != loadOkay {
		return
	}
	a.posDirty = true
	a.posAt = now()
}

// posLookup reads /host/GOREADER.POS and returns the row this document's
// key matches — nil on a miss, a corrupt row set, or an absent file.
func posLookup(key posEntry) *posEntry {
	b, rc := vi.ReadFileAll(posPath, posFileMax)
	if rc < 0 {
		return nil
	}
	ents := decodePosFile(b)
	if i := posFind(ents, key); i >= 0 {
		e := ents[i]
		return &e
	}
	return nil
}

// applyPos runs after load when no seat blob claimed the restore: the POS
// row's page (nearest-table zoom, fit) and bookmarks land on the document.
func (a *app) applyPos() {
	if a.pend != nil || a.st != loadOkay || a.posEnt == nil {
		return
	}
	e := a.posEnt
	a.fit = e.fit
	idx := zoomDefaultIdx
	if !e.fit {
		best := 1 << 30
		for i, t := range zoomTable {
			d := int(t) - e.zoom
			if d < 0 {
				d = -d
			}
			if d < best {
				best, idx = d, i
			}
		}
	}
	a.zoomIdx = idx
	a.bmk = append(a.bmk, e.bmk...)
	if e.page > 0 {
		a.goPage(e.page)
	}
	a.markPos()
	vi.ConsoleLine(markerPos + "page=" + vi.Itoa64(int64(a.pg.page+1)) +
		" z=" + vi.Itoa64(int64(a.zoom())) + " bm=" + bmList(a.bmk))
}

// flushPos rewrites the position file with this document's row most-recent
// first, LRU-evicting past posMaxEntries. WriteFileSafe's temp+rename keeps
// a crash between open and publish from leaving a torn file.
func (a *app) flushPos() {
	if a.st != loadOkay || !a.posDirty {
		return
	}
	a.posDirty = false
	var ents []posEntry
	if b, rc := vi.ReadFileAll(posPath, posFileMax); rc >= 0 {
		ents = decodePosFile(b)
	}
	e := a.key
	e.page, e.zoom, e.fit, e.bmk = a.pg.page, int(a.zoom()), a.fit, a.bmk
	merged := posUpsert(ents, e)
	if rc := vi.WriteFileSafe(posPath, encodePosFile(merged)); rc < 0 {
		a.posDirty = true // stay armed; the next quiet pass retries
		vi.ConsoleLine(markerPosErr + vi.Itoa64(rc))
		return
	}
	vi.ConsoleLine(markerPosSaved + vi.Itoa64(int64(len(merged))))
}

// toggleBookmark adds or clears the current page's mark — a full set
// refuses the add by name.
func (a *app) toggleBookmark() {
	if a.st != loadOkay {
		return
	}
	ns, marked, changed := bmToggle(a.bmk, a.pg.page)
	if !changed {
		a.pendingLog = append(a.pendingLog,
			markerBookmark+"full n="+u32s(uint32(len(a.bmk))))
		return
	}
	a.bmk = ns
	verb := "off"
	if marked {
		verb = "on"
	}
	a.pendingLog = append(a.pendingLog,
		markerBookmark+verb+" page="+u32s(uint32(a.pg.page+1))+
			" n="+u32s(uint32(len(a.bmk))))
	a.markPos()
}

// jumpBookmark lands on the next (dir>0) or previous (dir<0) marked page,
// wrapping at the ends of the set.
func (a *app) jumpBookmark(dir int) bool {
	if a.st != loadOkay {
		return false
	}
	t, ok := bmNext(a.bmk, a.pg.page)
	if dir < 0 {
		t, ok = bmPrev(a.bmk, a.pg.page)
	}
	if !ok {
		a.pendingLog = append(a.pendingLog, markerBookmark+"none")
		return true
	}
	a.pendingLog = append(a.pendingLog,
		markerBookmark+"jump page="+u32s(uint32(t+1)))
	a.goPage(t)
	return true
}

// openSaveCopy raises the shared save picker seeded with the document's
// -COPY name; the result writes a byte copy of the open PDF.
func (a *app) openSaveCopy() {
	if a.st != loadOkay {
		return
	}
	a.pick = appkit.NewFilePicker(appkit.PickSave, dirname(a.path))
	a.pick.Input = copyName(a.name)
	a.pendingLog = append(a.pendingLog, markerSave+"pick")
}

// finishPick consumes the picker's result: a path publishes a byte copy of
// the document (crash-safe temp+rename like every app save); "cancel" or an
// empty result is the modal's own receipt.
func (a *app) finishPick() {
	res := a.pick.Result
	if res == "" || res == "cancel" {
		vi.ConsoleLine(markerSave + "cancel")
		return
	}
	if rc := vi.WriteFileSafe(res, a.data); rc < 0 {
		vi.ConsoleLine(markerSave + "rc=" + vi.Itoa64(rc))
		return
	}
	vi.ConsoleLine(markerSave + res + " bytes=" + vi.Itoa64(int64(len(a.data))))
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

// findKey feeds the open find bar; it reports whether the frame changed.
// The appkit overlay owns the keyboard while it is up — Escape dismisses,
// Enter steps (Shift-Enter back), the rest is the pattern field.
func (a *app) findKey(ev vi.Event) bool {
	k, ok := appkit.NormalizeKey(ev)
	if !ok {
		return false
	}
	return a.find.OnKey(k)
}

func (a *app) scrollTick(down bool) {
	if a.st != loadOkay {
		return
	}
	vp := viewportRect(a.ta.W, a.ta.H, a.find.Open)
	step := scrollStep(vp.H, a.zoom())
	var np int
	var noy uint32
	var turned, moved bool
	if down {
		np, noy, turned, moved = scrollDown(a.pg, a.oy, a.maxOY(), step)
	} else {
		np, noy, turned, moved = scrollUp(a.pg, a.oy, a.maxOY(), step)
	}
	if !moved {
		return
	}
	if turned {
		a.pg.page = np
		a.ox, a.oy = 0, noy
		if a.renderPage(np) {
			a.oy = clampU32(a.oy, a.maxOY())
			a.pendingLog = append(a.pendingLog,
				markerPage+vi.Itoa64(int64(np+1))+"/"+vi.Itoa64(int64(a.pg.pages)))
			a.markPos()
		}
		return
	}
	a.oy = noy
}

// handle returns whether the screen needs repainting.
func (a *app) handle(ev vi.Event) bool {
	switch ev.Kind {
	case vi.EvKeyDown:
		if a.pick.Open {
			// The save picker is modal — every key is its own until it
			// closes; done means Result is ready (path or "cancel").
			if _, done := a.pick.HandleKey(ev); done {
				a.finishPick()
			}
			return true
		}
		if a.find.Open {
			return a.findKey(ev)
		}
		ctrl := ev.Flags&vi.ModCtrl != 0
		switch ev.Arg0 {
		case keyFit:
			if ctrl {
				a.find.Present()
				a.pendingLog = append(a.pendingLog, markerFindBar)
				return true
			}
			a.setZoom(a.zoomIdx, !a.fit)
			return true
		case keyZoomIn:
			a.setZoom(stepZoom(a.zoomIdx, 1), false)
			return true
		case keyZoomOut:
			a.setZoom(stepZoom(a.zoomIdx, -1), false)
			return true
		case keyReset:
			a.setZoom(zoomDefaultIdx, false)
			return true
		case keyFindN:
			if a.find.Pattern() != "" {
				dir := 1
				if ev.Flags&vi.ModShift != 0 || ev.Arg1 == 'N' {
					dir = -1
				}
				a.find.Step(dir)
				return true
			}
			return false
		case keyHome:
			a.goPage(0)
			return true
		case keyEnd:
			a.goPage(a.pg.pages - 1)
			return true
		case keyPgDn, keyPgUp:
			// The scroll twin does the work — consumed below.
			return false
		case keyUp:
			a.scrollTick(false)
			return true
		case keyDown:
			a.scrollTick(true)
			return true
		case keyLeft, keyRight:
			if a.st != loadOkay {
				return false
			}
			vp := viewportRect(a.ta.W, a.ta.H, a.find.Open)
			z := a.zoom()
			dw, _ := displayedSize(uint32(a.pw), uint32(a.ph), z)
			step := scrollStep(vp.W, z)
			mx := panMax(uint32(a.pw), dw, vp.W)
			nx := a.ox
			if ev.Arg0 == keyLeft {
				if a.ox > step {
					nx = a.ox - step
				} else {
					nx = 0
				}
			} else {
				nx = minU32(mx, a.ox+step)
			}
			if nx == a.ox {
				return false
			}
			a.ox = nx
			return true
		case keyMark:
			a.toggleBookmark()
			return true
		case keyBmPrev:
			return a.jumpBookmark(-1)
		case keyBmNext:
			return a.jumpBookmark(1)
		case keySaveAs:
			a.openSaveCopy()
			return true
		case keyQuitQ, keyEscape:
			vi.ConsoleLine(markerQuit)
			a.flushPos()
			a.ta.CloseAndExit(exitQuit)
		}
	case evScroll:
		if ev.Arg0&0x4000 != 0 {
			return false // horizontal ticks are not this reader's axis
		}
		a.scrollTick(ev.Arg0&0x8000 != 0)
		return true
	}
	return false
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

// canvasSurface adapts the bound window canvas to webrender.Surface — the
// same shape GOVIEW uses.
type canvasSurface struct{ cv widgets.Canvas }

func (s *canvasSurface) Fill(x, y, w, h int, rgb uint32) {
	if w <= 0 || h <= 0 || x < 0 || y < 0 {
		return
	}
	s.cv.FillRect(widgets.Rect{X: x, Y: y, W: w, H: h}, draw.Opaque(rgb))
}

// FillRect makes the adapter a widgets.RectCanvas — the find overlay's
// whole paint contract. The 24-bit theme token still goes out opaque.
func (s *canvasSurface) FillRect(r widgets.Rect, rgb uint32) {
	s.Fill(r.X, r.Y, r.W, r.H, rgb)
}

const docBg = 0x3a4048 // the "desk" tone behind a smaller-than-viewport page

func (a *app) draw() {
	cv := a.ta.Canvas()
	winW, winH := int(a.ta.W), int(a.ta.H)
	cv.FillRect(widgets.Rect{W: winW, H: winH}, draw.Opaque(theme.Current.Bg))
	surf := &canvasSurface{cv: cv}
	vp := viewportRect(a.ta.W, a.ta.H, a.find.Open)
	switch a.st {
	case loadOkay:
		a.blit(surf, vp)
	case loadRefused:
		a.drawRefuse(surf, vp)
	case loadFailedOpen, loadFailedRead:
		a.drawFailed(surf, vp)
	default:
		a.drawEmpty(surf, vp)
	}
	a.drawStatus(surf)
	if a.find.Open {
		a.find.R = widgets.Rect{Y: winH - findBarH, W: winW, H: findBarH}
		a.find.Draw(surf)
	}
	if a.pick.Open {
		a.pick.Draw(cv)
	}
}

// blit scales the display copy into the viewport, nearest-neighbour with
// same-colour run fills — the GOVIEW blit's shape, minus alpha (PDF pages
// are opaque by contract).
func (a *app) blit(s *canvasSurface, vp viewport) {
	cv := a.ta.Canvas()
	cv.FillRect(widgets.Rect{X: int(vp.X), Y: int(vp.Y), W: int(vp.W), H: int(vp.H)},
		draw.Opaque(docBg))
	z := a.zoom()
	dw, dh := displayedSize(uint32(a.pw), uint32(a.ph), z)
	dx, dy := pageLayout(vp, dw, dh)
	limW := minU32(dw, vp.W)
	limH := minU32(dh, vp.H)
	for sy := uint32(0); sy < limH; sy++ {
		py := a.oy + sy*uint32(a.ph)/dh
		if py >= uint32(a.ph) {
			break
		}
		row := int(py) * a.pw
		for sx := uint32(0); sx < limW; {
			px := a.ox + sx*uint32(a.pw)/dw
			if px >= uint32(a.pw) {
				break
			}
			rgb := a.disp[row+int(px)] & 0x00ffffff
			start := sx
			sx++
			for sx < limW {
				px2 := a.ox + sx*uint32(a.pw)/dw
				if px2 >= uint32(a.pw) || a.disp[row+int(px2)]&0x00ffffff != rgb {
					break
				}
				sx++
			}
			s.Fill(int(dx+start), int(dy+sy), int(sx-start), 1, rgb)
		}
	}
}

func (a *app) drawStatus(s *canvasSurface) {
	y := int(a.ta.H) - statusH
	if a.find.Open {
		y -= findBarH
	}
	cv := a.ta.Canvas()
	cv.FillRect(widgets.Rect{Y: y, W: int(a.ta.W), H: statusH}, draw.Opaque(theme.Current.Surface))
	var text string
	switch a.st {
	case loadOkay:
		text = "PAGE " + u32s(uint32(a.pg.page+1)) + "/" + u32s(uint32(a.pg.pages)) +
			"   " + u32s(a.zoom()) + "%"
		if a.fit {
			text += " FIT"
		}
		if len(a.hits) > 0 {
			text += "   HIT " + u32s(uint32(a.hitIdx+1)) + "/" + u32s(uint32(len(a.hits)))
		}
		if len(a.bmk) > 0 {
			text += "   BMK " + u32s(uint32(len(a.bmk)))
			if bmHas(a.bmk, a.pg.page) {
				text += "*"
			}
		}
		text += "   ^F FIND  N/N HIT  F FIT  +/- ZOOM  B MARK  S SAVE  Q QUIT"
	case loadRefused:
		text = "REFUSED: " + a.refuse
	case loadFailedOpen:
		text = "CANNOT OPEN " + a.name
	case loadFailedRead:
		text = "READ FAILED " + a.name
	default:
		text = "NO DOCUMENT — EXEC GOREADER.ELF /HOST/FILE.PDF"
	}
	clip := webrender.Clip{X: 0, Y: y, W: int(a.ta.W), H: statusH}
	webrender.DrawText(s, 4, y+2, webrender.UpperASCII(text), 1, false, theme.Current.Muted, clip)
}

// drawRefuse is the card's named refusal: the ADR 0040 code in the window,
// large enough to read, with the file that asked for it.
func (a *app) drawRefuse(s *canvasSurface, vp viewport) {
	cv := a.ta.Canvas()
	cv.FillRect(widgets.Rect{X: int(vp.X), Y: int(vp.Y), W: int(vp.W), H: int(vp.H)},
		draw.Opaque(docBg))
	cy := int(vp.Y) + int(vp.H)/3
	clip := webrender.Clip{X: 0, Y: 0, W: int(a.ta.W), H: int(a.ta.H)}
	msg := webrender.UpperASCII("refused: " + a.refuse)
	w := len(msg) * 8 * 2
	webrender.DrawText(s, max(0, int(vp.W)/2-w/2), cy, msg, 2, false, theme.Current.Danger, clip)
	sub := webrender.UpperASCII(a.name)
	webrender.DrawText(s, max(0, int(vp.W)/2-len(sub)*8/2), cy+28, sub, 1, false, theme.Current.Muted, clip)
	hint := "THE ENGINE DECLINED THIS DOCUMENT"
	webrender.DrawText(s, max(0, int(vp.W)/2-len(hint)*8/2), cy+44, hint, 1, false, theme.Current.Muted, clip)
}

// drawFailed is the transport-failure window — open/read errors are not
// engine refusals, so they name the step, not a code.
func (a *app) drawFailed(s *canvasSurface, vp viewport) {
	cv := a.ta.Canvas()
	cv.FillRect(widgets.Rect{X: int(vp.X), Y: int(vp.Y), W: int(vp.W), H: int(vp.H)},
		draw.Opaque(docBg))
	cy := int(vp.Y) + int(vp.H)/3
	clip := webrender.Clip{X: 0, Y: 0, W: int(a.ta.W), H: int(a.ta.H)}
	msg := "CANNOT OPEN"
	if a.st == loadFailedRead {
		msg = "READ FAILED"
	}
	webrender.DrawText(s, max(0, int(vp.W)/2-len(msg)*8), cy,
		webrender.UpperASCII(msg), 2, false, theme.Current.Danger, clip)
	sub := webrender.UpperASCII(a.name)
	webrender.DrawText(s, max(0, int(vp.W)/2-len(sub)*8/2), cy+28, sub, 1, false, theme.Current.Muted, clip)
}

func (a *app) drawEmpty(s *canvasSurface, vp viewport) {
	cv := a.ta.Canvas()
	cv.FillRect(widgets.Rect{X: int(vp.X), Y: int(vp.Y), W: int(vp.W), H: int(vp.H)},
		draw.Opaque(docBg))
	cy := int(vp.Y) + int(vp.H)/3
	clip := webrender.Clip{X: 0, Y: 0, W: int(a.ta.W), H: int(a.ta.H)}
	for i, line := range []string{appName + " — READER", "NO DOCUMENT", "EXEC GOREADER.ELF /HOST/FILE.PDF"} {
		w := len(line) * 8
		webrender.DrawText(s, max(0, int(vp.W)/2-w/2), cy+i*14, webrender.UpperASCII(line), 1, false, theme.Current.Muted, clip)
	}
}

// flushLogs prints pending markers — after the frame that earned them is
// on the scanout, so the gate never asserts ahead of the paint.
func (a *app) flushLogs() {
	for _, m := range a.pendingLog {
		vi.ConsoleLine(m)
	}
	a.pendingLog = a.pendingLog[:0]
}

func (a *app) repaint() {
	a.draw()
	a.ta.Present()
	a.flushLogs()
}

func (a *app) eventLoop() {
	for {
		// The seat's save_state ask is mailbox traffic, not an input event:
		// answer it inside this slice before the window can go away.
		a.ta.PollStateAsk()
		ev, r, ok := vi.PollEventRaw()
		if !ok {
			if r < 0 {
				a.flushPos()
				vi.ConsoleLine(markerWinClose)
				vi.ConsoleLine(markerOK)
				a.ta.CloseAndExit(exitQuit)
			}
			vi.Sleep(1)
			// Debounced position write: quiet for posDebounceNs after the
			// last page/zoom/bookmark change.
			if a.posDirty && now()-a.posAt >= posDebounceNs {
				a.flushPos()
			}
			continue
		}
		switch a.ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			a.flushPos()
			vi.ConsoleLine(markerWinClose)
			vi.ConsoleLine(markerOK)
			a.ta.CloseAndExit(exitQuit)
		case tabapp.ActionResized:
			a.oy = clampU32(a.oy, a.maxOY())
			a.repaint()
		case tabapp.ActionNone:
			if a.handle(ev) {
				a.repaint()
			}
		}
	}
}

func main() {
	path := ""
	if args := vi.Args(); len(args) >= 2 {
		path = args[1]
	}

	a := &app{path: path, name: basename(path), zoomIdx: zoomDefaultIdx, hitIdx: -1}
	a.find = appkit.NewFind()
	a.find.Scan = a.findScan
	a.find.Show = a.findShow
	a.find.Miss = a.findMiss
	ta := tabapp.Init(tabapp.Config{
		Name:         appName,
		Title:        appTitle,
		X:            windowX,
		Y:            windowY,
		W:            windowW,
		H:            windowH,
		StateVersion: stateVersion,
		SaveState:    a.saveState,
		RestoreState: a.noteState,
	})
	if ta == nil {
		vi.ConsoleLine(markerOpenFailed)
		vi.Exit(1)
	}
	a.ta = ta
	if ta.TabAware {
		vi.ConsoleLine(markerTabAware)
	} else {
		vi.ConsoleLine(markerNotTabAware)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)) + " " +
		vi.Itoa64(int64(ta.W)) + "x" + vi.Itoa64(int64(ta.H)))

	// The render arena: the engine's fixed 9 MiB POD partition, caller
	// owned and disjoint from the source — a plain heap slice (large Go
	// allocs are page-aligned, so the engine's 8-byte rule holds) avoids
	// a second 9 MiB populated mmap competing with the window surface
	// under the process memory limit.
	a.arena = make([]byte, pdf.ArenaBytes)

	// ADR 0040 A4: DCTDecode image streams decode through webrender's owned
	// baseline JPEG decoder, staged and charged inside the page arena.
	pdf.SetImageDecoder(func(data []byte) (w, h int, pix []uint32, err error) {
		im, err := webrender.DecodeImage(data)
		if err != nil {
			return 0, 0, nil, err
		}
		return im.Width, im.Height, im.Pix, nil
	})

	if a.path == "" && !ta.Restored {
		vi.ConsoleLine(markerEmpty)
	} else {
		a.load(a.path)
		if a.st == loadFailedOpen {
			vi.ConsoleLine(markerRefuse + "ReadFailed")
		} else if a.st == loadFailedRead {
			vi.ConsoleLine(markerReadErr)
		} else if a.st == loadRefused {
			vi.ConsoleLine(markerRefuse + a.refuse)
		}
	}
	a.applyPos()
	a.applyRestored()
	a.pushTitle()
	a.repaint()
	vi.ConsoleLine(markerPresent)
	vi.ConsoleLine(markerReady)
	a.eventLoop()
}

// pushTitle keeps the window title on the document + page + zoom, like
// the seat's tab title and the kernel's title band both read it.
func (a *app) pushTitle() {
	title := appTitle
	if a.name != "" {
		title = a.name
		if a.st == loadOkay {
			title += "  " + u32s(uint32(a.pg.page+1)) + "/" + u32s(uint32(a.pg.pages)) +
				"  " + u32s(a.zoom()) + "%"
		} else if a.st == loadRefused {
			title += "  REFUSED " + a.refuse
		}
	}
	_ = vi.WinSetTitle(a.ta.Win, title)
}
