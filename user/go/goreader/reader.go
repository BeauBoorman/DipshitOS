// reader.go is the PURE half of GOREADER.ELF: the page model, the zoom
// table and fit-width arithmetic, the scroll-and-flip rule, find-hit
// geometry, the highlight blend, and the save_state blob codec. Nothing
// here touches the kernel — main.go owns every syscall, so the host
// `go test ./goreader/...` run exercises all of it with no guest.
package main

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
// | u8 fit`. The seat stores it verbatim; the app owns the format, so a
// stale serialization is refused here by version, never misread.
const stateVersion = 1

func encodeState(path string, page, zoom int, fit bool) []byte {
	n := len(path)
	if n > 4096 {
		n = 4096
	}
	out := make([]byte, 0, 12+n)
	out = append(out, stateVersion, byte(n>>8), byte(n))
	out = append(out, path[:n]...)
	var tail [9]byte
	putU32(tail[0:], uint32(page))
	putU32(tail[4:], uint32(zoom))
	if fit {
		tail[8] = 1
	}
	return append(out, tail[:]...)
}

func decodeState(b []byte) (path string, page, zoom int, fit, ok bool) {
	if len(b) < 12 || b[0] != stateVersion {
		return "", 0, 0, false, false
	}
	n := int(b[1])<<8 | int(b[2])
	if n > len(b)-12 {
		return "", 0, 0, false, false
	}
	path = string(b[3 : 3+n])
	rest := b[3+n:]
	page = int(getU32(rest[0:]))
	zoom = int(getU32(rest[4:]))
	fit = rest[8] == 1
	if page < 0 || zoom < 0 {
		return "", 0, 0, false, false
	}
	return path, page, zoom, fit, true
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
