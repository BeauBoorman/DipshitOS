// reader.go is the PURE half of GOREADER.ELF: the page model, the zoom
// table and fit-width arithmetic, the scroll-and-flip rule, find-hit
// geometry, the highlight blend, the save_state blob codec, and the
// bookmark + position-file model. Nothing here touches the kernel —
// main.go owns every syscall, so the host `go test ./goreader/...` run
// exercises all of it with no guest.
package main

import (
	"strconv"
	"strings"

	"virelai/sshlib"
)

// Zoom stops (percent). The card's range is 50–400; the default is 100.
var zoomTable = [...]uint32{50, 66, 100, 150, 200, 300, 400}

const (
	zoomDefaultIdx = 2
	zoomMinPct     = 50
	zoomMaxPct     = 400
)

// HID usages (the view/edit convention; PgUp/PgDn also arrive as their
// MOUSE_SCROLL twin — see scrollDown/scrollUp).
const (
	keyEscape  = 0x29
	keyReturn  = 0x28
	keyBacksp  = 0x2A
	keyZoomIn  = 0x2E // `=` / `+`
	keyZoomOut = 0x2D // `-` / `_`
	keyReset   = 0x27 // `0`
	keyFit     = 0x09 // `f` — fit-width (ctrl-f opens find)
	keyFindN   = 0x11 // `n` — next hit (shift+n previous)
	keyQuitQ   = 0x14 // `q`
	keyMark    = 0x05 // `b` — toggle a bookmark on the current page
	keySaveAs  = 0x16 // `s` — save a byte copy through the picker
	keyBmPrev  = 0x2F // `[` — jump to the previous bookmark
	keyBmNext  = 0x30 // `]` — jump to the next bookmark
	keyHome    = 0x4A
	keyPgUp    = 0x4B
	keyEnd     = 0x4D
	keyPgDn    = 0x4E
	keyRight   = 0x4F
	keyLeft    = 0x50
	keyDown    = 0x51
	keyUp      = 0x52
)

// evScroll is kernel event kind 12 (events.zig MOUSE_SCROLL): arg0 packs
// bits 0–13 magnitude, bit 14 horizontal, bit 15 sign (1 = down). PageUp/
// PageDown key presses generate their KEY_DOWN plus one of these — the
// reader consumes the scroll half so the wheel path and the keys agree.
const evScroll uint16 = 12

// Layout geometry inside the window: the kernel's own 16px title band
// covers canvas rows 0–15 on the degrade path, the status bar sits at the
// bottom, and the page viewport is everything between.
const (
	chromeTopH = 16
	statusH    = 13
	findBarH   = 14

	windowX = 40
	windowY = 24
	windowW = 760
	windowH = 560
)

// viewport is the page-drawing rect in canvas coordinates.
type viewport struct{ X, Y, W, H uint32 }

func viewportRect(winW, winH uint32, findOpen bool) viewport {
	bottom := statusH
	if findOpen {
		bottom += findBarH
	}
	if winH <= chromeTopH+uint32(bottom) || winW == 0 {
		return viewport{}
	}
	return viewport{0, chromeTopH, winW, winH - chromeTopH - uint32(bottom)}
}

// stepZoom moves within the table, clamped at both ends.
func stepZoom(idx int, dir int) int {
	switch {
	case dir > 0:
		if idx+1 > len(zoomTable)-1 {
			return len(zoomTable) - 1
		}
		return idx + 1
	case dir < 0:
		if idx < 1 {
			return 0
		}
		return idx - 1
	}
	return zoomDefaultIdx
}

// fitWidthZoom is the zoom percent that makes the page exactly the
// viewport's width, clamped to the card's 50–400 range.
func fitWidthZoom(vpW, pageW uint32) uint32 {
	if pageW == 0 || vpW == 0 {
		return 100
	}
	z := vpW * 100 / pageW
	if z < zoomMinPct {
		return zoomMinPct
	}
	if z > zoomMaxPct {
		return zoomMaxPct
	}
	return z
}

// displayedSize is the rendered page scaled by z percent.
func displayedSize(pw, ph, z uint32) (uint32, uint32) {
	return maxU32(1, pw*z/100), maxU32(1, ph*z/100)
}

// pageLayout places the displayed page inside the viewport: centered
// horizontally when it fits, top-aligned always, clipped otherwise.
func pageLayout(vp viewport, dw, dh uint32) (dx, dy uint32) {
	dy = vp.Y
	if dw < vp.W {
		dx = vp.X + (vp.W-dw)/2
	} else {
		dx = vp.X
	}
	return dx, dy
}

// panMax is the largest legal top-left page-pixel origin on one axis.
func panMax(pageLen, dispLen, vpLen uint32) uint32 {
	if dispLen == 0 || dispLen <= vpLen {
		return 0
	}
	span := maxU32(1, vpLen*pageLen/dispLen)
	return pageLen - minU32(pageLen, span)
}

func clampU32(v, hi uint32) uint32 {
	if v > hi {
		return hi
	}
	return v
}

// ---------------------------------------------------------------------------
// Page model + scroll-and-flip
// ---------------------------------------------------------------------------

// pager is the card's page model: current index, total count, and the
// bounded nav ops the keys map to.
type pager struct {
	page, pages int
}

// goTo lands on page i clamped to [0, pages); it reports movement.
func (p *pager) goTo(i int) bool {
	if p.pages <= 0 {
		return false
	}
	if i < 0 {
		i = 0
	}
	if i >= p.pages {
		i = p.pages - 1
	}
	if i == p.page {
		return false
	}
	p.page = i
	return true
}

func (p *pager) next() bool { return p.goTo(p.page + 1) }
func (p *pager) prev() bool { return p.goTo(p.page - 1) }
func (p *pager) home() bool { return p.goTo(0) }
func (p *pager) end() bool  { return p.goTo(p.pages - 1) }

// scrollStep is one wheel/PgDn tick in page pixels: half a viewport of
// display distance converted back through the zoom.
func scrollStep(vpLen, z uint32) uint32 {
	return maxU32(1, vpLen*100/maxU32(1, z)/2)
}

// scrollDown is the shared "read on" rule for wheel-down and PgDn: pan
// while page remains below, flip to the next page at the bottom edge.
// It reports (newPage, newOY, turned, moved).
func scrollDown(pg pager, oy, maxOy, step uint32) (int, uint32, bool, bool) {
	if oy < maxOy {
		return pg.page, minU32(maxOy, oy+step), false, true
	}
	if pg.page+1 < pg.pages {
		return pg.page + 1, 0, true, true
	}
	return pg.page, oy, false, false
}

// scrollUp mirrors it: pan while page remains above, flip to the previous
// page's bottom edge at the top.
func scrollUp(pg pager, oy, maxOy, step uint32) (int, uint32, bool, bool) {
	if oy > 0 {
		if oy < step {
			return pg.page, 0, false, true
		}
		return pg.page, oy - step, false, true
	}
	if pg.page > 0 {
		return pg.page - 1, maxOy, true, true
	}
	return pg.page, oy, false, false
}

// ---------------------------------------------------------------------------
// Find-hit geometry
// ---------------------------------------------------------------------------

// hitRect is one highlight band in page-pixel coordinates.
type hitRect struct{ X0, Y0, X1, Y1 int }

// maxHitRects bounds the overlay work per page.
const maxHitRects = 64

// mergeHitRects collects the glyph bands covering text range [s,e) and
// merges consecutive same-line bands into one rect per visual line.
func mergeHitRects(glyphs []glyphPos, s, e int) []hitRect {
	var out []hitRect
	for _, g := range glyphs {
		if g.off < s || g.off >= e {
			continue
		}
		r := hitRect{int(g.x0), int(g.y0), int(g.x1), int(g.y1)}
		if r.X1 <= r.X0 {
			r.X1 = r.X0 + 1
		}
		if r.Y1 <= r.Y0 {
			r.Y1 = r.Y0 + 1
		}
		if n := len(out); n > 0 {
			prev := &out[n-1]
			// Same line: overlapping vertical extents and a small gap.
			gap := r.X0 - prev.X1
			if r.Y0 <= prev.Y1 && r.Y1 >= prev.Y0 && gap >= -2 && gap <= 8 {
				if r.X1 > prev.X1 {
					prev.X1 = r.X1
				}
				if r.Y0 < prev.Y0 {
					prev.Y0 = r.Y0
				}
				if r.Y1 > prev.Y1 {
					prev.Y1 = r.Y1
				}
				continue
			}
		}
		if len(out) == maxHitRects {
			break
		}
		out = append(out, r)
	}
	return out
}

// ---------------------------------------------------------------------------
// Highlight blend + state codec
// ---------------------------------------------------------------------------

// blendRect lerps every pixel of pix inside r toward rgb by pct percent.
// It is applied to the display copy only — the rendered page in the arena
// is never mutated, so a re-render or hit change starts clean.
func blendRect(pix []uint32, stride, w, h int, r hitRect, rgb uint32, pct uint32) {
	x0 := max(0, r.X0)
	y0 := max(0, r.Y0)
	x1 := min(w, r.X1)
	y1 := min(h, r.Y1)
	tr := (rgb >> 16) & 0xff
	tg := (rgb >> 8) & 0xff
	tb := rgb & 0xff
	for y := y0; y < y1; y++ {
		row := y * stride
		for x := x0; x < x1; x++ {
			px := pix[row+x]
			pr := (px >> 16) & 0xff
			pg := (px >> 8) & 0xff
			pb := px & 0xff
			nr := (pr*(100-pct) + tr*pct) / 100
			ng := (pg*(100-pct) + tg*pct) / 100
			nb := (pb*(100-pct) + tb*pct) / 100
			pix[row+x] = 0xff000000 | nr<<16 | ng<<8 | nb
		}
	}
}

// save_state blob: `u8 ver | u16 pathlen | path | u32 page | u32 zoomPct
// | u8 fit | u8 nbookmarks | u32 page x nbookmarks` (v2 — the blob carries
// the open document's bookmarks so a seat snapshot restores the marks it
// was taken with). The seat stores it verbatim; the app owns the format,
// so a stale serialization is refused here by version, never misread.
const stateVersion = 2

func encodeState(path string, page, zoom int, fit bool, bmk []int) []byte {
	n := len(path)
	if n > 4096 {
		n = 4096
	}
	out := make([]byte, 0, 13+n+4*len(bmk))
	out = append(out, stateVersion, byte(n>>8), byte(n))
	out = append(out, path[:n]...)
	var tail [10]byte
	putU32(tail[0:], uint32(page))
	putU32(tail[4:], uint32(zoom))
	if fit {
		tail[8] = 1
	}
	nb := len(bmk)
	if nb > posMaxBookmarks {
		nb = posMaxBookmarks
	}
	tail[9] = byte(nb)
	out = append(out, tail[:]...)
	var bm [4]byte
	for _, p := range bmk[:nb] {
		putU32(bm[:], uint32(p))
		out = append(out, bm[:]...)
	}
	return out
}

func decodeState(b []byte) (path string, page, zoom int, fit bool, bmk []int, ok bool) {
	if len(b) < 13 || b[0] != stateVersion {
		return "", 0, 0, false, nil, false
	}
	n := int(b[1])<<8 | int(b[2])
	if n > len(b)-13 {
		return "", 0, 0, false, nil, false
	}
	path = string(b[3 : 3+n])
	rest := b[3+n:]
	page = int(getU32(rest[0:]))
	zoom = int(getU32(rest[4:]))
	fit = rest[8] == 1
	nb := int(rest[9])
	if page < 0 || zoom < 0 || nb > posMaxBookmarks || len(rest) < 10+4*nb {
		return "", 0, 0, false, nil, false
	}
	for i := 0; i < nb; i++ {
		bmk = append(bmk, int(getU32(rest[10+4*i:])))
	}
	return path, page, zoom, fit, bmk, true
}

func putU32(b []byte, v uint32) {
	b[0] = byte(v >> 24)
	b[1] = byte(v >> 16)
	b[2] = byte(v >> 8)
	b[3] = byte(v)
}

func getU32(b []byte) uint32 {
	return uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])
}

func minU32(a, b uint32) uint32 {
	if a < b {
		return a
	}
	return b
}

func maxU32(a, b uint32) uint32 {
	if a > b {
		return a
	}
	return b
}

// u32s formats a number for markers and status text — local, like view's,
// so this file stays free of the vi import the host tests cannot run.
func u32s(v uint32) string {
	if v == 0 {
		return "0"
	}
	var buf [10]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[i:])
}

// basename is the same after-last-slash rule VIEW.BIN and GOVIEW use.
func basename(path string) string {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' {
			return path[i+1:]
		}
	}
	return path
}

// ---------------------------------------------------------------------------
// Bookmarks + per-document position memory (M153c, issue #2923)
// ---------------------------------------------------------------------------

// posMaxBookmarks bounds a document's marks; the set stays sorted.
const posMaxBookmarks = 16

// bmFind locates page in the sorted set (or its insertion index).
func bmFind(s []int, page int) (int, bool) {
	i := 0
	for i < len(s) && s[i] < page {
		i++
	}
	return i, i < len(s) && s[i] == page
}

func bmHas(s []int, page int) bool { _, ok := bmFind(s, page); return ok }

// bmToggle adds or removes page, reporting (newSet, marked, changed): a
// removal is marked=false changed=true; changed=false on an add means the
// full set refused it.
func bmToggle(s []int, page int) ([]int, bool, bool) {
	i, found := bmFind(s, page)
	if found {
		return append(s[:i], s[i+1:]...), false, true
	}
	if len(s) >= posMaxBookmarks {
		return s, false, false
	}
	out := append(s, 0)
	copy(out[i+1:], out[i:])
	out[i] = page
	return out, true, true
}

// bmList renders the set for markers: 1-based pages, "-" when empty.
func bmList(s []int) string {
	if len(s) == 0 {
		return "-"
	}
	var out string
	for i, p := range s {
		if i > 0 {
			out += ","
		}
		out += u32s(uint32(p + 1))
	}
	return out
}

// bmNext is the first bookmark strictly after cur, wrapping to the first.
// bmPrev mirrors. ok=false means the set is empty.
func bmNext(s []int, cur int) (int, bool) {
	if len(s) == 0 {
		return 0, false
	}
	for _, p := range s {
		if p > cur {
			return p, true
		}
	}
	return s[0], true
}

func bmPrev(s []int, cur int) (int, bool) {
	if len(s) == 0 {
		return 0, false
	}
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] < cur {
			return s[i], true
		}
	}
	return s[len(s)-1], true
}

// /host/GOREADER.POS — last position + bookmarks per document. One
// tab-separated row per document, most-recent first; the path rides the row
// hex-encoded so no byte in it can bend the columns. A row's key is
// path + byte size + the first 8 bytes of SHA-256 over the head of the
// file, so a document replaced in place reads as a different document and
// its stale row is superseded on the next write. Pages are stored 0-based,
// like the blob.
const (
	posPath       = "/host/GOREADER.POS"
	posMaxEntries = 64
	posHeadBytes  = 4096
	posFileMax    = 32 * 1024
	// posDebounceNs is the quiet interval before a mid-read page change is
	// written out — the crash window between turns, not a live-editor save.
	posDebounceNs = 300 * 1000 * 1000
	posSchema     = "# virelai-goreader-pos v1 (size<TAB>sha8<TAB>page<TAB>zoom<TAB>fit<TAB>bookmarks<TAB>hex(path); most-recent first)"
)

// posEntry is one document row: path/size/sha are the lookup key; the rest
// is what a reopen restores.
type posEntry struct {
	path string
	size uint64
	sha  [8]byte
	page int
	zoom int
	fit  bool
	bmk  []int
}

// posKey derives a document's lookup key from its bytes.
func posKey(path string, data []byte) posEntry {
	head := data
	if len(head) > posHeadBytes {
		head = head[:posHeadBytes]
	}
	sum := sshlib.SHA256Sum(head)
	var sha [8]byte
	copy(sha[:], sum[:8])
	return posEntry{path: path, size: uint64(len(data)), sha: sha}
}

// posFind returns the row index matching key's (path,size,sha), or -1.
func posFind(entries []posEntry, key posEntry) int {
	for i, e := range entries {
		if e.path == key.path && e.size == key.size && e.sha == key.sha {
			return i
		}
	}
	return -1
}

// posUpsert moves e to the front (most-recent), drops the stale row(s) for
// the same path, and caps the file at posMaxEntries — the tail is the LRU.
func posUpsert(entries []posEntry, e posEntry) []posEntry {
	out := make([]posEntry, 0, posMaxEntries)
	out = append(out, e)
	for _, o := range entries {
		if o.path == e.path {
			continue
		}
		if len(out) == posMaxEntries {
			break
		}
		out = append(out, o)
	}
	return out
}

func encodePosFile(entries []posEntry) []byte {
	var b []byte
	b = append(b, posSchema...)
	b = append(b, '\n')
	for _, e := range entries {
		b = strconv.AppendUint(b, e.size, 10)
		b = append(b, '\t')
		b = hexAppend(b, e.sha[:])
		b = append(b, '\t')
		b = strconv.AppendInt(b, int64(e.page), 10)
		b = append(b, '\t')
		b = strconv.AppendInt(b, int64(e.zoom), 10)
		b = append(b, '\t')
		c := byte('0')
		if e.fit {
			c = '1'
		}
		b = append(b, c, '\t')
		for i, p := range e.bmk {
			if i > 0 {
				b = append(b, ',')
			}
			b = strconv.AppendInt(b, int64(p), 10)
		}
		b = append(b, '\t')
		b = hexAppend(b, []byte(e.path))
		b = append(b, '\n')
	}
	return b
}

// decodePosFile parses the store: comment/blank/malformed rows are dropped,
// and the file's own most-recent-first order is the recency order.
func decodePosFile(b []byte) []posEntry {
	var out []posEntry
	for _, ln := range strings.Split(string(b), "\n") {
		ln = strings.TrimRight(ln, "\r")
		if ln == "" || ln[0] == '#' {
			continue
		}
		f := strings.Split(ln, "\t")
		if len(f) != 7 {
			continue
		}
		size, err := strconv.ParseUint(f[0], 10, 64)
		if err != nil {
			continue
		}
		sha, ok := hexDecode(f[1])
		if !ok || len(sha) != 8 {
			continue
		}
		page, err := strconv.Atoi(f[2])
		if err != nil || page < 0 {
			continue
		}
		zoom, err := strconv.Atoi(f[3])
		if err != nil || zoom < 0 {
			continue
		}
		if f[4] != "0" && f[4] != "1" {
			continue
		}
		var bmk []int
		bad := false
		if f[5] != "" {
			for _, s := range strings.Split(f[5], ",") {
				p, err := strconv.Atoi(s)
				if err != nil || p < 0 {
					bad = true
					break
				}
				bmk = append(bmk, p)
			}
			if bad || len(bmk) > posMaxBookmarks {
				continue
			}
		}
		path, ok := hexDecode(f[6])
		if !ok || len(path) == 0 {
			continue
		}
		var sh [8]byte
		copy(sh[:], sha)
		out = append(out, posEntry{
			path: string(path), size: size, sha: sh,
			page: page, zoom: zoom, fit: f[4] == "1", bmk: bmk,
		})
		if len(out) == posMaxEntries {
			break
		}
	}
	return out
}

// copyName seeds the save picker's name field — PAGES.PDF becomes
// PAGES-COPY.PDF, so a copy never lands on the source by default.
func copyName(name string) string {
	if strings.HasSuffix(strings.ToLower(name), ".pdf") {
		return name[:len(name)-4] + "-COPY.PDF"
	}
	return name + "-COPY"
}

// dirname is the picker's starting directory — the open file's parent.
func dirname(path string) string {
	if i := strings.LastIndexByte(path, '/'); i > 0 {
		return path[:i]
	}
	return "/host"
}

// hexAppend/hexDecode are the lowercase-hex pair the POS rows use — the
// same field-encoding convention the recent log keeps (no encoding/hex).
func hexAppend(b, src []byte) []byte {
	const digits = "0123456789abcdef"
	for _, c := range src {
		b = append(b, digits[c>>4], digits[c&0xf])
	}
	return b
}

func hexDecode(s string) ([]byte, bool) {
	if len(s)%2 != 0 {
		return nil, false
	}
	out := make([]byte, len(s)/2)
	for i := range out {
		hi, ok1 := posNib(s[2*i])
		lo, ok2 := posNib(s[2*i+1])
		if !ok1 || !ok2 {
			return nil, false
		}
		out[i] = hi<<4 | lo
	}
	return out, true
}

func posNib(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}
