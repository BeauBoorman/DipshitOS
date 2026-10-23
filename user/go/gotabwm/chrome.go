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
	"virelai/clockfmt"
	"virelai/draw"
	"virelai/settings"
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
	// M121d (#2567): the focus indicator's transition line, printed once
	// per badge-state change after the frame carrying it was presented.
	MarkerFocus = "gotabwm: focus "
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
	// M121d (#2567): the focus indicator repaints on the same cadence —
	// every focus change, blur and tab close lands on this tick's frame.
	_ = paintFocusBadge(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	_ = paintGodMenuButton(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	// M115d (#2463): the PWR button sits on the same band, right of Apps.
	_ = paintPowerButton(scan, vi.ScanoutWidth, vi.ScanoutHeight)
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

// clockZoneLoad is the seat clock's seam for the `timezone` row — real
// settings.Load on the guest, stubbed in host tests (the notify.go
// settings.Load discipline). M178c (#3146): the row applies to the kernel
// source, the same epoch `date` formats, so the seat's face agrees with
// the shell's. The host .clock is already the host's local face and
// uptime has no epoch, so neither carries the row.
var clockZoneLoad = func() clockfmt.Zone { return settings.Load().Timezone() }

// clockZone caches the row between minute rollovers: the read is one
// bounded file decode and a settings change lands within a minute, the
// same re-read pattern refreshReduceMotion (notify.go) uses — no
// settings-bus subscription needed.
var clockZoneMin int64 = -1
var clockZoneVal clockfmt.Zone

// clockZoneFor returns the row in force for the displayed minute, re-
// reading the file when the minute rolls over (and once at boot, when the
// -1 sentinel misses).
func clockZoneFor(minute int64) clockfmt.Zone {
	if minute != clockZoneMin {
		clockZoneVal = clockZoneLoad()
		clockZoneMin = minute
	}
	return clockZoneVal
}

// clockNow resolves the face from the honest sources in D2's order.
func clockNow(ticks uint64) clockFace {
	if ep, ok := kernelEpoch(); ok {
		c := clockfmt.At(ep, clockZoneFor(ep/60))
		return clockFace{h: c.Hour, m: c.Minute, s: c.Second, source: "kernel"}
	}
	if ep, ok := hostEpoch(); ok {
		h, m, s := clockHMS(ticks, ep, true)
		return clockFace{h: h, m: m, s: s, source: "host"}
	}
	h, m, s := clockHMS(ticks, 0, false)
	return clockFace{h: h, m: m, s: s, source: "uptime"}
}

// kernelTime is the slot-66 read behind kernelEpoch — a var so a host test
// can drive the face without the guest syscall.
var kernelTime = vi.Time

// kernelEpoch is sys_time (slot 66): Unix wall-clock seconds, already
// advanced by 1 Hz uptime, or no epoch at all. The FULL epoch travels —
// a named zone's offset depends on the date, not just the time of day.
func kernelEpoch() (int64, bool) {
	v := kernelTime()
	if v <= 0 {
		return 0, false
	}
	return v, true
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
	// M108b (#2325, ADR 0051 D3): the clipboard state badge — M97g's
	// seat-visibility rule carried across the glass. While the last buffer
	// write was host-sourced it shows the distinct host-marked state.
	// M109e (#2401): the badge row packs right-to-left — CLIP holds the
	// right edge and the agent indicator sits beside it.
	bx := x + w - chromePad
	if tag, rgb, ok := hostClipBadge(); ok {
		tw := seatTextWidth(tag, seatSmallPx)
		bx -= tw
		seatText(c, clip, bx, ty, seatSmallPx, tag, rgb)
		bx -= 6
	}
	if tag, rgb, ok := agentBadge(); ok {
		tw := seatTextWidth(tag, seatSmallPx)
		bx -= tw
		seatText(c, clip, bx, ty, seatSmallPx, tag, rgb)
	}
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

// --- M121d (#2567): the focus indicator ------------------------------------
//
// The chrome's answer to "where do keystrokes go": a second panel on the
// same bottom band, flush left of the clock, carrying the focused tab's
// title and a chord-scope chip. The scope is the chords registry's
// dispatch-point class the tab declares: an app tab's own KEY_DOWN scope
// ("app"), a tty-bound front-end whose kernel chrome chords answer on its
// window ("term", the kernel-terminal scope), or the seat's own chords
// when no tab is focused or a seat modal (launcher/palette, power menu)
// holds the input sink ("seat"). The panel repaints on the same tick
// cadence as the clock, so focus changes, blurs and tab closes land on
// the next presented frame; the transition marker prints only after a
// frame carrying the new state was presented (the notify discipline).
const (
	FocusW   = 216
	focusGap = 4 // seam between the indicator and the clock plate
)

// focusBadgeView is what the panel currently claims: the focused tab's
// title and the scope chip beside it.
type focusBadgeView struct {
	title string
	scope string
}

// badgeReported is the last state the transition line named — the marker
// prints once per change, at the moment the seat's focus state moved, the
// same discipline `gotabwm: tab focus id=` follows (the next tick's paint
// then carries it; a switch that never survives to a presented frame
// still names the transition it caused).
var badgeReported focusBadgeView

// focusRect is the indicator's rect: the clock panel's band, against its
// left edge with a focusGap seam. It gives up (the zero rect) when the
// band cannot hold it — reaching under the power button, past the left
// inset, or up into the rail — the same give-up rule godMenuRect obeys.
func focusRect(width, height int) (x, y, w, h int) {
	cx, cy, cw, _ := chromeRect(width, height)
	if cw == 0 {
		return 0, 0, 0, 0
	}
	x, y, w, h = cx-focusGap-FocusW, cy, FocusW, ChromeH
	if y < RailHeight {
		return 0, 0, 0, 0
	}
	// The left bound is the left chrome row's nominal span — notify
	// column, Apps, PWR — whether or not each button itself fit on this
	// scanout: a crowded band refuses the panel rather than painting it
	// under a slot a button gave up on.
	if x < notifyInset+NotifyW+chromeInset+godMenuW+powerBtnGap+powerBtnW+focusGap {
		return 0, 0, 0, 0
	}
	return
}

// asciiUpperEq reports whether s, uppercased as ASCII, equals want —
// strings.ToUpper pulls the unicode case tables into the guest image
// (apps.go's asciiContainsFold documents the wall), so the fold is by
// hand over bytes the caller already knows are 7-bit names.
func asciiUpperEq(s, want string) bool {
	if len(s) != len(want) {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'a' && c <= 'z' {
			c -= 'a' - 'A'
		}
		if c != want[i] {
			return false
		}
	}
	return true
}

// terminalFrontEndBin reports whether bin names an executable that
// attaches its window as a tty front-end — the class the registry calls
// kernel-terminal, whose chrome chords the KERNEL serves while the
// window is focused. The seat has no query for a window's tty binding
// (win_query carries no kind field), so the class rides the recorded
// executable name: the bins observed calling vi.TtyAttachWindow (2026-10
// grep: term, files, sh, help, gitui, rss, imgcat, btmath, charmhello,
// pulse; gsport's ABI for GOSTALGIA). Compare on the stem so a bare
// declared title ("imgcat", the guessBin default arm) classifies like
// the canonical "IMGCAT.ELF".
func terminalFrontEndBin(bin string) bool {
	stem := bin
	if n := len(stem); n > 4 && asciiUpperEq(stem[n-4:], ".ELF") {
		stem = stem[:n-4]
	}
	for _, t := range [...]string{
		"GOTERM", "GOFILES", "GOSH", "GOHELP", "GOGITUI", "RSS",
		"IMGCAT", "BTMATH", "CHARMHELLO", "PULSE", "GOSTALGIA",
	} {
		if asciiUpperEq(stem, t) {
			return true
		}
	}
	return false
}

// seatModalFocus reports whether a seat-owned modal currently holds the
// input sink — the launcher/palette strip or the power menu. While one
// does, keystrokes dispatch at seat scope no matter which tab the rail
// calls focused.
func seatModalFocus() bool {
	return (launch.open && launch.sink != 0) ||
		(powerMenuOpen && powerSink != 0)
}

// focusBadgeState is the indicator's current claim, read from live state:
// the focused tab's title plus its scope class; the seat's own scope when
// a modal holds the sink or no tab is focused. Pure over package state —
// host tests pin every branch without a guest.
func focusBadgeState() focusBadgeView {
	if seatModalFocus() {
		return focusBadgeView{scope: "seat"}
	}
	id, ok := tabs.Focused()
	if !ok {
		return focusBadgeView{scope: "seat"}
	}
	t := tabs.At(tabs.index(id))
	scope := "app"
	if terminalFrontEndBin(t.Bin) {
		scope = "term"
	}
	return focusBadgeView{title: t.Title, scope: scope}
}

// focusChipText is the scope chip's painted label.
func focusChipText(scope string) string {
	switch scope {
	case "term":
		return "TERM"
	case "seat":
		return "SEAT"
	}
	return "APP"
}

// focusBadgeLine is the serial line one transition prints: the scope plus
// the tab's title — absent on the seat scope, which has no tab to name.
func focusBadgeLine(v focusBadgeView) string {
	if v.scope == "seat" {
		return MarkerFocus + "scope=seat"
	}
	return MarkerFocus + "scope=" + v.scope + " title=" + v.title
}

// noteBadgeTransition is the indicator's transition reporter: when the
// badge's claim changed since the last line, print the new one. Called
// wherever the seat's focus state can move — after an input event (the
// chords, rail clicks), after an RPC pass (declares/attaches take focus),
// and once per composite tick (choreography, session restores, sink
// releases) — so rapid focus cycles name every switch, not only the ones
// that outlived a whole tick.
func noteBadgeTransition() {
	v := focusBadgeState()
	if v == badgeReported {
		return
	}
	badgeReported = v
	vi.ConsoleLine(focusBadgeLine(v))
}

// paintFocusBadge paints the indicator panel and returns the pixel count
// written. Pure over the caller's scanout — the host test pins the
// tokens, the chip and the title run.
func paintFocusBadge(scan []byte, width, height int) int {
	x, y, w, h := focusRect(width, height)
	if w <= 0 || h <= 0 || len(scan)/4/width < y+h {
		return 0
	}
	c := seatCanvas(scan, width, height)
	if c == nil {
		return 0
	}
	v := focusBadgeState()
	tok := theme.Current
	plate := widgets.Rect{X: x, Y: y, W: w, H: h}
	written := seatPlate(c, plate, radiusControl, tok.Accent, tok.ChromeBg)
	draw.StrokeRoundedRect(c, plate, radiusControl, tok.BorderW, draw.Opaque(tok.Rule))
	clip := plate.Inset(tok.BorderW)
	// The scope chip anchors right: an Accent plate with the panel's own
	// bg as its ink, sized to the label the state names.
	chip := focusChipText(v.scope)
	cw := seatTextWidth(chip, seatSmallPx) + 8
	chipR := widgets.Rect{X: x + w - chromePad - cw, Y: y + 3, W: cw, H: h - 6}
	draw.FillRoundedRect(c, chipR, radiusControl, draw.Opaque(tok.Accent))
	seatText(c, clip, chipR.X+4, y+chromePad, seatSmallPx, chip, tok.ChromeBg)
	// The title's clip stops short of the chip so a long title truncates
	// at the seam instead of under the badge.
	label := v.title
	if v.scope == "seat" {
		label = statusText
	}
	titleClip := widgets.Rect{X: clip.X, Y: clip.Y, W: chipR.X - chromePad - clip.X, H: clip.H}
	tx, ty := chromeTextOrigin(x, y)
	seatText(c, titleClip, tx, ty, seatTextPx, label, tok.Ink)
	return written
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
