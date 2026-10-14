// GOTABWM.ELF — M71c (#1562): the seat's own clock and status chrome.
//
// Zig TABWM painted a bottom status tray (a clock plus theme badges). The Go
// seat painted a blank fill and, with tabs, a rail band — so sitting in the
// default desktop there was no time and no identity anywhere on the scanout.
// This file is that chrome: a bounded panel in the bottom-right, painted by
// the seat itself on every COMPOSITE_TICK and repainted after whatever
// desktop layer the tick painted, so it sits above a hosted client (a tab's
// window covers the whole scanout).
//
// D1 (this card): chrome is the SEAT, not a hosted app — nothing is exec'd.
// D2: no RTC. VZ exposes none and the kernel has no time-of-day source of
// its own, so the honest sources are, in order:
//
//	kernel  slot 66 (sys_time): the boot EFI GetTime epoch advanced by 1 Hz
//	        uptime — the authoritative wall clock. The kernel answers
//	        ENOSYS when the firmware gave no epoch.
//	host    /host/.clock: the session launcher's seconds-since-local-
//	        midnight (tools/session.sh). The same file, and the same
//	        fallback order, Zig TABWM used.
//	uptime  the seat's own tick counter — honest, and named as uptime
//	        rather than dressed up as wall time.
//
// The one-shot `gotabwm: clock-source <name>` line says which source won, so
// a gate never has to guess, and `gotabwm: clock HH:MM:SS` carries the face.
//
// M104e (#2272): every painter in this file now runs through
// draw.BytesCanvas over the scanout — the shared FillRect/
// FillRoundedRect/FillShadow/Text/Glyph primitives in seatpaint.go —
// with registry fonts when the share stages them and the engine's bitmap
// degrade when it does not.
package main

import (
	"virelai/draw"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

// The chrome marker lines the class-B gate greps. Exported constants so
// chrome_test.go pins the exact shapes (the repo pins gate grep targets this
// way in user/src/tabwm.zig and user/go/gotabwm/tabs.go).
const (
	MarkerClock       = "gotabwm: clock "
	MarkerClockSource = "gotabwm: clock-source "
	// M71e (#1564): the empty-strip start surface, painted by the seat (D2:
	// seat chrome, never DESKTOP.BIN).
	MarkerStartSurface = "gotabwm: start-surface"
)

// clockEpochPath is the session launcher's wall-time file: the host's LOCAL
// time at boot, as seconds since midnight. Absent in a gate boot (no session
// launcher), which is exactly the uptime fallback.
const (
	clockEpochPath = "/host/.clock"
	clockMaxBytes  = 64
)

// Chrome geometry: a bottom-right panel, inset from the scanout edge so its
// pixels never collide with a capture's own edge frame (observed in M71b:
// the PNG carries a 6px border at full capture scale).
const (
	ChromeH     = 20 // panel height: the 8px face plus chromePad above and below
	ChromeW     = 148
	chromeInset = 8
	chromePad   = 6
)

// statusText is the seat's one-line identity in the panel (D1: the seat names
// itself; nothing is exec'd to draw it).
const statusText = "GOTABWM"

// clockFace is what the panel shows for a tick, plus the source name the
// one-shot marker reports.
type clockFace struct {
	h, m, s int
	source  string
}

// chromeLogged guards the one-shot clock markers (the gate greps the
// transition, not a per-tick flood).
var chromeLogged bool

// chromeTick repaints the panel for this tick and emits the clock markers
// once, after the first successful paint. Painting and logging live together
// so a caller cannot print the marker without having painted the panel.
func chromeTick(scan []byte, ticks uint64) {
	face := clockNow(ticks)
	text := formatClock(face.h, face.m, face.s)
	_ = paintChrome(scan, vi.ScanoutWidth, vi.ScanoutHeight, text)
	_ = paintGodMenuButton(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	if chromeLogged {
		return
	}
	chromeLogged = true
	vi.ConsoleLine(MarkerClockSource + face.source)
	vi.ConsoleLine(MarkerClock + text)
}

// Reserved bottom chrome, between the toast column and the clock. Neither
// the rail cells nor pane geometry move when the tab count changes.
const godMenuW = 96

func godMenuRect(width, height int) (x, y, w, h int) {
	x, y, w, h = notifyInset+NotifyW+chromeInset, height-chromeInset-ChromeH, godMenuW, ChromeH
	cx, _, _, _ := chromeRect(width, height)
	if y < RailHeight || x+w+chromeInset > cx {
		return 0, 0, 0, 0
	}
	return
}

func godMenuHit(px, py uint32, width, height int) bool {
	x, y, w, h := godMenuRect(width, height)
	return w > 0 && int(px) >= x && int(px) < x+w && int(py) >= y && int(py) < y+h
}

func paintGodMenuButton(scan []byte, width, height int) int {
	x, y, w, h := godMenuRect(width, height)
	if w == 0 || width <= 0 || len(scan)/4/width < y+h {
		return 0
	}
	c := seatCanvas(scan, width, height)
	if c == nil {
		return 0
	}
	tok := theme.Current
	plate := widgets.Rect{X: x, Y: y, W: w, H: h}
	// §2.3: the button's face rides the hover ramp; the plate carries the
	// seat's left accent rule.
	face := tok.ChromeBg
	if godButtonHover {
		face = tok.BtnHover
	}
	n := seatPlate(c, plate, radiusControl, tok.Accent, face)
	// #2054: the button's icon is the sexiburger itself — the same raster
	// the launcher strip carries, so the click target and the chord name
	// the same front door. 16px on the 20px plate, through BlitScaled.
	tx := x + chromePad
	if icon := emblemCanvas(); icon != nil {
		dst := widgets.Rect{X: x + 4, Y: y + 2, W: 16, H: 16}
		draw.BlitScaled(c, icon, dst)
		n += seatArea(c, dst)
		tx = x + 24
	}
	// A failed open shows the same label in Danger — the icon leaves no
	// room for the old "Apps error" tail.
	ink := tok.Ink
	if launch.err != "" && !launch.open {
		ink = tok.Danger
	}
	seatText(c, plate.Inset(1), tx, y+chromePad, seatTextPx, "Apps", ink)
	return n
}

// clockNow resolves the face from the honest sources in D2's order.
func clockNow(ticks uint64) clockFace {
	if ep, ok := kernelEpoch(); ok {
		h, m, s := clockHMS(0, ep, true)
		return clockFace{h: h, m: m, s: s, source: "kernel"}
	}
	if ep, ok := hostEpoch(); ok {
		h, m, s := clockHMS(ticks, ep, true)
		return clockFace{h: h, m: m, s: s, source: "host"}
	}
	h, m, s := clockHMS(ticks, 0, false)
	return clockFace{h: h, m: m, s: s, source: "uptime"}
}

// kernelEpoch is sys_time (slot 66): Unix wall-clock seconds, already
// advanced by 1 Hz uptime, or no epoch at all. Folded to
// seconds-since-midnight for the face.
func kernelEpoch() (uint32, bool) {
	v := vi.Time()
	if v <= 0 {
		return 0, false
	}
	return uint32(v % 86400), true
}

// hostEpoch is /host/.clock, seconds since local midnight.
func hostEpoch() (uint32, bool) {
	b, r := vi.ReadFileAll(clockEpochPath, clockMaxBytes)
	if r < 0 || b == nil {
		return 0, false
	}
	return parseClockEpoch(b)
}

// parseClockEpoch parses a decimal seconds-since-midnight value (0..86399)
// from a `.clock` body. Surrounding whitespace is tolerated; junk, an empty
// value, and anything at or past 24h are refused. Pure — host-testable, and
// the same contract tabwm.zig's parse_clock_epoch states.
func parseClockEpoch(b []byte) (uint32, bool) {
	i, n := 0, len(b)
	for i < n && isClockWS(b[i]) {
		i++
	}
	var val uint32
	digits := 0
	for i < n && b[i] >= '0' && b[i] <= '9' {
		if digits >= 6 {
			return 0, false // more than 999999 is not a valid value
		}
		val = val*10 + uint32(b[i]-'0')
		digits++
		i++
	}
	if digits == 0 {
		return 0, false
	}
	for ; i < n; i++ {
		if !isClockWS(b[i]) {
			return 0, false
		}
	}
	if val >= 86400 {
		return 0, false
	}
	return val, true
}

func isClockWS(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

// clockHMS is the face at elapsed seconds: time-of-day when an epoch
// (seconds since local midnight) is known, wrapping at 24h; uptime from
// 00:00 when it is not, with hours counting past 24. Pure — the same rule
// tabwm.zig's clock_hms uses, so the two seats agree on one clock contract.
func clockHMS(elapsed uint64, epoch uint32, haveEpoch bool) (h, m, s int) {
	total := elapsed
	if haveEpoch {
		total = (uint64(epoch) + elapsed) % 86400
		h = int((total / 3600) % 24)
	} else {
		h = int(total / 3600)
	}
	return h, int((total / 60) % 60), int(total % 60)
}

// formatClock is "HH:MM:SS", zero-padded. Guest-safe: no fmt.
func formatClock(h, m, s int) string {
	var b [8]byte
	put2 := func(at, v int) {
		if v < 0 {
			v = 0
		}
		if v > 99 {
			v = 99
		}
		b[at] = byte('0' + v/10)
		b[at+1] = byte('0' + v%10)
	}
	put2(0, h)
	b[2] = ':'
	put2(3, m)
	b[5] = ':'
	put2(6, s)
	return string(b[:])
}

// chromeRect is the panel's rect on a width x height scanout: bottom-right,
// chromeInset from each edge so it sits inside any capture frame. Pure. A
// scanout too small for the inset shrinks the panel; one too small even for
// that returns the zero rect (the caller paints nothing).
func chromeRect(width, height int) (x, y, w, h int) {
	w, h = ChromeW, ChromeH
	if width < w+2*chromeInset {
		w = width - 2*chromeInset
	}
	if height < h+2*chromeInset {
		h = height - 2*chromeInset
	}
	if w <= 0 || h <= 0 || width <= 0 || height <= 0 {
		return 0, 0, 0, 0
	}
	return width - chromeInset - w, height - chromeInset - h, w, h
}

// chromeTextOrigin is the top-left of the clock glyph grid inside the panel:
// past the 2px accent rule and its gap.
func chromeTextOrigin(x, y int) (int, int) { return x + 6, y + chromePad }

// paintChrome paints the seat's clock/status panel and returns the pixel
// count written. Tokens only (M69c) — no hex lives here. Pure: it edits the
// caller's scanout slice and touches nothing else, which is what the host
// test pins.
func paintChrome(scan []byte, width, height int, clock string) int {
	x, y, w, h := chromeRect(width, height)
	if w <= 0 || h <= 0 {
		return 0
	}
	c := seatCanvas(scan, width, height)
	if c == nil {
		return 0
	}
	tok := theme.Current
	plate := widgets.Rect{X: x, Y: y, W: w, H: h}
	// The 2px accent rule on the panel's left edge is the seat's identity
	// mark; it is also the pixel probe's blue anchor: the desktop fill and
	// the terminal's green text are neither accent-blue nor ink-white. The
	// 1px Rule stroke is the §2.2 plate border.
	written := seatPlate(c, plate, radiusWindow, tok.Accent, tok.ChromeBg)
	draw.StrokeRoundedRect(c, plate, radiusWindow, tok.BorderW, draw.Opaque(tok.Rule))
	tx, ty := chromeTextOrigin(x, y)
	clip := plate.Inset(tok.BorderW)
	seatText(c, clip, tx, ty, seatTextPx, clock, tok.Ink)
	seatText(c, clip, tx+seatTextWidth(clock, seatTextPx)+8, ty, seatSmallPx, chromeStatusText(), tok.Muted)
	return written
}

// chromeStatusText makes the clock panel's notification-center affordance
// discoverable without changing its geometry: pending history replaces the
// seat label with a short prompt, and clicking this same panel opens it.
func chromeStatusText() string {
	if len(notifyCenter) > 0 {
		return "NOTIFY!"
	}
	return statusText
}

// --- M71e (#1564): the empty-strip start surface ---------------------------
//
// An empty strip used to leave nothing on the canvas but the blank desktop
// fill, so a seat with no tabs had no home affordance at all. This paints one
// bounded panel over the blank fill, from M69c tokens, and is the click/
// Enter target that summons the M69c2 launcher.
//
// Deliberately NOT a port of Zig's BT4 grid. Zig's `draw_start_surface`
// (user/src/tabwm.zig:3441) is a rail-native apps GRID summoned by Ctrl+T /
// the `+ New tab` pill; it is not an empty-strip state, and GOTABWM has no
// Ctrl+T binding. The card asked for the empty-strip reading, so this is seat
// chrome that names the seat and points at the launcher GOTABWM already owns.
const (
	StartW       = 336
	StartH       = 76
	startPad     = 12
	startLineGap = 14
)

// startHint points at the real affordance. The launcher chord is a fact of
// this seat (hid.go / launcher.go), not a label invented here.
const startHint = "Ctrl+Space: apps"

// startSurfaceLogged guards the one-shot marker, exactly like chromeLogged.
var startSurfaceLogged bool

// startSurfaceRect is the panel's rect: centred, inset from every edge so it
// clears a capture's own ~6px frame (the M71b/M71c lesson). Pure. A scanout
// too small shrinks the panel and then gives up with the zero rect.
func startSurfaceRect(width, height int) (x, y, w, h int) {
	w, h = StartW, StartH
	if width < w+2*chromeInset {
		w = width - 2*chromeInset
	}
	if height < h+2*chromeInset {
		h = height - 2*chromeInset
	}
	if w <= 0 || h <= 0 || width <= 0 || height <= 0 {
		return 0, 0, 0, 0
	}
	return (width - w) / 2, (height - h) / 2, w, h
}

// paintStartSurface paints the panel and returns the pixel count written.
// Tokens only (M69c) — no hex lives here. Pure: it edits the caller's
// scanout slice and touches nothing else, which is what the host test pins.
func paintStartSurface(scan []byte, width, height int) int {
	x, y, w, h := startSurfaceRect(width, height)
	if w <= 0 || h <= 0 {
		return 0
	}
	c := seatCanvas(scan, width, height)
	if c == nil {
		return 0
	}
	tok := theme.Current
	plate := widgets.Rect{X: x, Y: y, W: w, H: h}
	// The panel is a floating plate: the §2.5 shadow, the §2.2 radius,
	// and the same 2px accent rule the clock panel carries — one seat.
	seatShadow(c, plate, radiusWindow)
	written := seatPlate(c, plate, radiusWindow, tok.Accent, tok.Surface)
	draw.StrokeRoundedRect(c, plate, radiusWindow, tok.BorderW, draw.Opaque(tok.Border))
	tx, ty := x+startPad, y+startPad
	// #2054: the avatar is the front door here too — the start surface is
	// the launcher's pointer affordance, so it carries the same emblem.
	if icon := emblemCanvas(); icon != nil {
		dst := widgets.Rect{X: tx, Y: ty + 4, W: 32, H: 32}
		draw.BlitScaled(c, icon, dst)
		written += seatArea(c, dst)
		tx += 40
	}
	clip := plate.Inset(tok.BorderW)
	seatText(c, clip, tx, ty, seatTextPx, statusText, tok.Ink)
	seatText(c, clip, tx, ty+startLineGap, seatSmallPx, startHint, tok.InkMuted)
	return written
}

// startSurfaceTick paints the start surface for this tick and emits the
// one-shot marker only after a paint actually wrote pixels — the chromeTick
// discipline, so the marker can never outrun the paint.
func startSurfaceTick(scan []byte) {
	if paintStartSurface(scan, vi.ScanoutWidth, vi.ScanoutHeight) == 0 {
		return
	}
	if startSurfaceLogged {
		return
	}
	startSurfaceLogged = true
	vi.ConsoleLine(MarkerStartSurface)
}

// startSurfaceHit reports whether a scanout point falls inside the start
// surface panel — the click target that opens the launcher.
func startSurfaceHit(px, py uint32) bool {
	x, y, w, h := startSurfaceRect(vi.ScanoutWidth, vi.ScanoutHeight)
	if w <= 0 || h <= 0 {
		return false
	}
	return int(px) >= x && int(px) < x+w && int(py) >= y && int(py) < y+h
}

// M83f (#1779): virtio-gpu has no observed backlight control. "Dim" is a
// software-blended, opaque BGRX frame: half of each colour channel remains
// visible, but the scanout's X byte stays 0xff so VZ displays the pixels.
// One FillRect of straight-alpha 0x80000000 is that same 50% blend.
func paintIdleDim(scan []byte, width, height int) int {
	if width <= 0 || height <= 0 || len(scan) < 4 {
		return 0
	}
	c := seatCanvas(scan, width, height)
	if c == nil {
		return 0
	}
	n := len(scan) / 4
	if width*height < n {
		n = width * height
	}
	draw.FillRect(c, widgets.Rect{X: 0, Y: 0, W: width, H: c.H}, 0x80000000)
	return n
}

const (
	curtainW = 256
	curtainH = 64
)

// This is a seat-painted visual curtain, NOT a password prompt, an
// authenticated lock, or a boundary against an app receiving input.
func paintIdleCurtain(scan []byte, width, height int) int {
	if width <= 0 || height <= 0 || len(scan) < 4 {
		return 0
	}
	c := seatCanvas(scan, width, height)
	if c == nil {
		return 0
	}
	tok := theme.Current
	written := seatFill(c, widgets.Rect{X: 0, Y: 0, W: width, H: height}, tok.ChromeBg)
	w, h := curtainW, curtainH
	if w > width-2*chromeInset {
		w = width - 2*chromeInset
	}
	if h > height-2*chromeInset {
		h = height - 2*chromeInset
	}
	if w <= 0 || h <= 0 {
		return written
	}
	x, y := (width-w)/2, (height-h)/2
	plate := widgets.Rect{X: x, Y: y, W: w, H: h}
	written += seatPlate(c, plate, radiusWindow, tok.Accent, tok.Surface)
	clip := plate.Inset(seatRuleW)
	seatText(c, clip, x+10, y+8, seatTextPx, "VISUAL CURTAIN", tok.Ink)
	seatText(c, clip, x+10, y+25, seatTextPx, "NOT AUTHENTICATION", tok.Ink)
	seatText(c, clip, x+10, y+42, seatTextPx, "ANY INPUT WAKES", tok.InkMuted)
	return written
}
