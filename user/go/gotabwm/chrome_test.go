// chrome_test.go — M71c (#1562): host tests for the seat chrome's pure half.
//
// These run on the host (`go test ./gotabwm`), so they may not call any `vi`
// guest syscall: parseClockEpoch, clockHMS, formatClock, chromeRect and
// paintChrome all operate on plain Go values and a caller's scanout slice,
// which is the whole point of keeping them out of the seat loop. M104e
// (#2272): the painters now run through draw.BytesCanvas, and the tests pin
// the engine's bitmap degrade on a font-less host.
package main

import (
	"testing"
	"unsafe"

	"virelai/clockfmt"
	"virelai/draw"
	"virelai/theme"
	"virelai/vi"
	"virelai/webrender/font"
	"virelai/widgets"
)

func TestGodMenuButtonPaintAndHitAgree(t *testing.T) {
	defer saveSeatState()()
	for _, n := range []int{0, 1, 4} {
		tabs = TabStrip{}
		// #2545: the button paints "Apps" in Danger when launch.err is
		// set — a state earlier host tests legitimately leave behind
		// (compositeTick's syncSeatChrome WinOpen cannot succeed off-guest).
		// The test asserts the no-error face, so it must own that input.
		launch = launcherState{}
		for i := 0; i < n; i++ {
			tabs.OpenTab(uint32(i+3), "App")
		}
		scan := launcherScan()
		if paintGodMenuButton(scan, vi.ScanoutWidth, vi.ScanoutHeight) == 0 {
			t.Fatalf("%d tabs: button disappeared", n)
		}
		x, y, w, h := godMenuRect(vi.ScanoutWidth, vi.ScanoutHeight)
		for py := y - 1; py <= y+h; py++ {
			for px := x - 1; px <= x+w; px++ {
				want := px >= x && px < x+w && py >= y && py < y+h
				if godMenuHit(uint32(px), uint32(py), vi.ScanoutWidth, vi.ScanoutHeight) != want {
					t.Fatalf("%d tabs: paint/hit mismatch %d,%d", n, px, py)
				}
			}
		}
		if countLaunchInk(scan, x+chromePad, y+chromePad, 32, 8, theme.Current.Ink) < 10 {
			t.Fatal("Apps button has no glyph pixels")
		}
		cx, cy, cw, ch := chromeRect(vi.ScanoutWidth, vi.ScanoutHeight)
		overlap := func(rx, ry, rw, rh int) bool {
			return x < rx+rw && rx < x+w && y < ry+rh && ry < y+h
		}
		if overlap(cx, cy, cw, ch) || y < RailHeight {
			t.Fatal("button overlaps clock or rail")
		}
		for i := 0; i < NotifyMax; i++ {
			nx, ny, nw, nh := notifyRect(vi.ScanoutWidth, vi.ScanoutHeight, i, NotifyMax)
			if overlap(nx, ny, nw, nh) {
				t.Fatal("button overlaps notification target")
			}
		}
	}
}

func TestParseClockEpoch(t *testing.T) {
	ok := []struct {
		in   string
		want uint32
	}{
		{"0", 0},
		{"0\n", 0},
		{"3600", 3600},
		{"86399", 86399},
		{" 12345\t", 12345},
		{"\r\n45000\n", 45000},
	}
	for _, c := range ok {
		got, have := parseClockEpoch([]byte(c.in))
		if !have || got != c.want {
			t.Errorf("parseClockEpoch(%q) = %d,%v want %d,true", c.in, got, have, c.want)
		}
	}
	bad := []string{"", " ", "\n", "abc", "12abc", "1.5", "-1", "86400", "999999", "12 34", "9999999"}
	for _, in := range bad {
		if got, have := parseClockEpoch([]byte(in)); have {
			t.Errorf("parseClockEpoch(%q) = %d,true want refusal", in, got)
		}
	}
}

// The clock contract is shared with Zig TABWM (tabwm.zig clock_hms): an epoch
// makes it time-of-day wrapping at 24h, no epoch makes it uptime past 24.
func TestClockHMS(t *testing.T) {
	cases := []struct {
		elapsed   uint64
		epoch     uint32
		haveEpoch bool
		h, m, s   int
	}{
		{0, 0, true, 0, 0, 0},
		{30, 86370, true, 0, 0, 0},   // 86370 + 30 = 86400 wraps to midnight
		{0, 86399, true, 23, 59, 59}, // last second of the day
		{3600, 0, true, 1, 0, 0},     // an hour past midnight
		{0, 0, false, 0, 0, 0},       // uptime from 00:00
		{3661, 0, false, 1, 1, 1},    // uptime advances the same way
		{90000, 0, false, 25, 0, 0},  // uptime is NOT wrapped at 24h
		{90000, 100, true, 1, 1, 40}, // epoch + elapsed still wraps
	}
	for _, c := range cases {
		h, m, s := clockHMS(c.elapsed, c.epoch, c.haveEpoch)
		if h != c.h || m != c.m || s != c.s {
			t.Errorf("clockHMS(%d,%d,%v) = %02d:%02d:%02d want %02d:%02d:%02d",
				c.elapsed, c.epoch, c.haveEpoch, h, m, s, c.h, c.m, c.s)
		}
	}
}

func TestFormatClock(t *testing.T) {
	cases := []struct {
		h, m, s int
		want    string
	}{
		{0, 0, 0, "00:00:00"},
		{9, 5, 3, "09:05:03"},
		{23, 59, 59, "23:59:59"},
		{25, 0, 0, "25:00:00"},  // uptime may name an hour past 24
		{0, 60, 60, "00:60:60"}, // formatting never invents a carry
	}
	for _, c := range cases {
		if got := formatClock(c.h, c.m, c.s); got != c.want {
			t.Errorf("formatClock(%d,%d,%d) = %q want %q", c.h, c.m, c.s, got, c.want)
		}
	}
	if n := len(formatClock(0, 0, 0)); n != 8 {
		t.Errorf("formatClock width = %d want 8", n)
	}
}

func TestChromeRect(t *testing.T) {
	x, y, w, h := chromeRect(1280, 720)
	if w != ChromeW || h != ChromeH {
		t.Fatalf("chromeRect size = %dx%d want %dx%d", w, h, ChromeW, ChromeH)
	}
	if x != 1280-chromeInset-ChromeW || y != 720-chromeInset-ChromeH {
		t.Fatalf("chromeRect origin = %d,%d not inset from the bottom-right", x, y)
	}
	if x < 0 || y < 0 || x+w > 1280 || y+h > 720 {
		t.Fatalf("chromeRect %d,%d %dx%d escapes the scanout", x, y, w, h)
	}
	// A scanout too small for the inset shrinks the panel rather than
	// painting off-frame, and one too small even for that paints nothing.
	if _, _, w, h := chromeRect(100, 30); w != 100-2*chromeInset || h != 30-2*chromeInset {
		t.Errorf("small scanout panel = %dx%d want shrunk", w, h)
	}
	if x, y, w, h := chromeRect(10, 10); w != 0 || h != 0 || x != 0 || y != 0 {
		t.Errorf("tiny scanout chromeRect = %d,%d %dx%d want zero", x, y, w, h)
	}
}

// M104e (#2272): with no ui face resolved — the host has no staged
// /host/FONTS.TXT — seatText repaints the run through the engine's bitmap
// degrade, byte-identical to the drawText8 it replaced: same 8x8 face,
// same origin, same advance. This is the never-blank rule pinned locally.
func TestSeatTextDegradeRepaintsTheBitmapFace(t *testing.T) {
	const w, h = 1280, 720
	scan := make([]byte, w*h*4)
	c, err := draw.BytesCanvas(scan, w, h)
	if err != nil {
		t.Fatalf("BytesCanvas: %v", err)
	}
	if f := seatFaceUI(); f != nil {
		t.Skip("a ui face resolved on this host — the degrade path is unpinned")
	}
	seatText(c, widgets.Rect{X: 0, Y: 0, W: w, H: h}, 4, 4, seatTextPx, "ABC", theme.Dark.Ink)
	pix := asUint32(scan)
	// Every lit bit of the 8x8 face lands at (4+i*8+col, 4+row), and no
	// pixel outside the run's own mask is ink — the run-coalesced degrade
	// paints exactly what drawText8 did.
	for i, ch := range "ABC" {
		g := font.Glyph8(ch)
		for row := 0; row < 8; row++ {
			for col := 0; col < 8; col++ {
				lit := g[row]&(1<<uint(col)) != 0
				v := pix[(4+row)*w+4+i*8+col]
				if lit && v&0xffffff != theme.Dark.Ink {
					t.Fatalf("glyph %d bit %d,%d not painted (%#x)", i, col, row, v)
				}
				if !lit && v != 0 {
					t.Fatalf("glyph %d wrote a dark cell at %d,%d", i, col, row)
				}
			}
		}
	}
	// The third glyph's columns live at 16..23, so a run of 24-wide
	// advance means nothing is painted past x 4+24.
	for row := 0; row < 12; row++ {
		for col := 4 + 24; col < w; col++ {
			if pix[row*w+col] != 0 {
				t.Fatalf("the degrade path wrote past its advance at %d,%d", col, row)
			}
		}
	}
}

// paintChrome is the frame-level half: it must write a bounded panel in the
// token chrome colour, an accent rule, and ink/muted glyphs — and nothing
// outside the rect.
func TestPaintChromeStaysInsideTheRectAndUsesTokens(t *testing.T) {
	const w, h = 1280, 720
	scan := make([]byte, w*h*4)
	tok := theme.Current
	// Pre-fill with a colour the chrome never uses, so "outside" is provable.
	for i := 0; i < len(scan)/4; i++ {
		asUint32(scan)[i] = theme.Light.Success
	}
	if paintChrome(scan, w, h, "12:34:56") == 0 {
		t.Fatal("paintChrome painted nothing")
	}
	pix := asUint32(scan)
	x, y, pw, ph := chromeRect(w, h)
	var panel, accent, ink, muted int
	for row := 0; row < h; row++ {
		for col := 0; col < w; col++ {
			v := pix[row*w+col]
			inRect := col >= x && col < x+pw && row >= y && row < y+ph
			if !inRect {
				if v != theme.Light.Success {
					t.Fatalf("paintChrome wrote outside the panel at %d,%d", col, row)
				}
				continue
			}
			// The engine's Opaque fill forces the scanout's X byte 0xff
			// (M71c #1562), so the stored word is the token with 0xff in
			// the top byte.
			switch v & 0xffffff {
			case tok.ChromeBg:
				panel++
			case tok.Accent:
				accent++
			case tok.Ink:
				ink++
			case tok.Muted:
				muted++
			}
		}
	}
	if panel == 0 {
		t.Fatal("panel is not ChromeBg")
	}
	// The plate is rounded now (§2.2): the accent rule follows the curved
	// corner, so it paints fewer than the square plate's 2xH — and the
	// 1px Rule stroke takes the silhouette's outermost column, so the
	// rule's mid-height exact band is the second column in.
	if accent == 0 || accent >= 2*ph {
		t.Fatalf("rounded accent rule = %d pixels, want between 0 and %d", accent, 2*ph)
	}
	if pix[(y+ph/2)*w+x+1]&0xffffff != tok.Accent {
		t.Fatal("the accent rule's mid-height band is missing")
	}
	if pix[(y+ph/2)*w+x]&0xffffff != tok.Rule {
		t.Fatal("the plate's left-edge border stroke is missing")
	}
	if ink == 0 {
		t.Fatal("clock face has no Ink pixels")
	}
	if muted == 0 {
		t.Fatal("status line has no Muted pixels")
	}
}

// M71e (#1564): the empty-strip start surface. Pure half: geometry, tokens,
// and the click target — no guest call.
func TestStartSurfaceRectAndHit(t *testing.T) {
	if MarkerStartSurface != "gotabwm: start-surface" {
		t.Fatalf("MarkerStartSurface = %q", MarkerStartSurface)
	}
	x, y, w, h := startSurfaceRect(1280, 720)
	if w != StartW || h != StartH {
		t.Fatalf("startSurfaceRect size = %dx%d want %dx%d", w, h, StartW, StartH)
	}
	if x != (1280-w)/2 || y != (720-h)/2 {
		t.Fatalf("startSurfaceRect origin = %d,%d not centred", x, y)
	}
	if w+2*chromeInset > 1280 || h+2*chromeInset > 720 {
		t.Fatalf("panel %dx%d leaves no edge inset", w, h)
	}
	// A scanout too small shrinks the panel, then gives up with the zero rect.
	if _, _, w, h := startSurfaceRect(200, 40); w != 200-2*chromeInset || h != 40-2*chromeInset {
		t.Errorf("small scanout panel = %dx%d want shrunk", w, h)
	}
	if x, y, w, h := startSurfaceRect(10, 10); w != 0 || h != 0 || x != 0 || y != 0 {
		t.Errorf("tiny scanout rect = %d,%d %dx%d want zero", x, y, w, h)
	}

	// The click target is exactly the panel, excluding its far edge.
	vx, vy, vw, vh := startSurfaceRect(vi.ScanoutWidth, vi.ScanoutHeight)
	if !startSurfaceHit(uint32(vx), uint32(vy)) {
		t.Fatal("top-left of the panel must hit")
	}
	if !startSurfaceHit(uint32(vx+vw-1), uint32(vy+vh-1)) {
		t.Fatal("bottom-right inside the panel must hit")
	}
	if startSurfaceHit(uint32(vx+vw), uint32(vy)) || startSurfaceHit(uint32(vx), uint32(vy+vh)) {
		t.Fatal("the far edges are outside the panel")
	}
	if startSurfaceHit(0, 0) && vx != 0 {
		t.Fatal("0,0 must miss a centred panel")
	}
}

func TestPaintStartSurfaceUsesTokens(t *testing.T) {
	defer saveSeatState()() // the start surface lazily decodes the emblem now
	const w, h = 1280, 720
	scan := make([]byte, w*h*4)
	tok := theme.Current
	for i := 0; i < len(scan)/4; i++ {
		asUint32(scan)[i] = theme.Light.Success
	}
	if paintStartSurface(scan, w, h) == 0 {
		t.Fatal("paintStartSurface painted nothing")
	}
	pix := asUint32(scan)
	x, y, pw, ph := startSurfaceRect(w, h)
	var panel, accent, ink, muted int
	for row := 0; row < h; row++ {
		for col := 0; col < w; col++ {
			v := pix[row*w+col]
			inRect := col >= x && col < x+pw && row >= y && row < y+ph
			if !inRect {
				// The §2.5 shadow legitimately darkens a falloff band
				// around the plate (blur 16, dy 4) — bound it, then hold
				// the rest of the scanout to the sentinel.
				inShadow := col >= x-16 && col < x+pw+16 && row >= y-16 && row < y+ph+20
				if !inShadow && v != theme.Light.Success {
					t.Fatalf("paintStartSurface wrote outside the panel and its shadow at %d,%d", col, row)
				}
				continue
			}
			switch v & 0xffffff {
			case tok.Surface:
				panel++
			case tok.Accent:
				accent++
			case tok.Ink:
				ink++
			case tok.InkMuted:
				muted++
			}
		}
	}
	if panel == 0 {
		t.Fatal("start panel is not Surface")
	}
	if accent == 0 || accent >= 2*ph {
		t.Fatalf("rounded accent rule = %d pixels, want between 0 and %d", accent, 2*ph)
	}
	if ink == 0 {
		t.Fatal("start surface title has no Ink pixels")
	}
	if muted == 0 {
		t.Fatal("start surface hint has no InkMuted pixels")
	}
	if n := paintStartSurface(nil, 0, 0); n != 0 {
		t.Errorf("degenerate scanout painted %d pixels", n)
	}
}

func TestIdleDimBlendsEveryPixelAndKeepsScanoutOpaque(t *testing.T) {
	const w, h = 3, 2
	scan := make([]byte, w*h*4)
	pix := asUint32(scan)
	for i := range pix {
		pix[i] = 0xffabcdef
	}
	if got := paintIdleDim(scan, w, h); got != w*h {
		t.Fatalf("dim pixels = %d, want %d", got, w*h)
	}
	for i, v := range pix {
		if v != 0xff556677 {
			t.Fatalf("dim pixel %d = %#x, want opaque half-brightness", i, v)
		}
	}
	if got := paintIdleDim(scan, 0, h); got != 0 {
		t.Fatalf("zero-width dim wrote %d pixels", got)
	}
}

func TestIdleCurtainCoversScanoutAndNamesNoAuthentication(t *testing.T) {
	const w, h = 320, 160
	scan := make([]byte, w*h*4)
	if got := paintIdleCurtain(scan, w, h); got < w*h {
		t.Fatalf("curtain wrote %d pixels, want a full scanout", got)
	}
	pix := asUint32(scan)
	tok := theme.Current
	if pix[0] != 0xff000000|tok.ChromeBg || pix[len(pix)-1] != 0xff000000|tok.ChromeBg {
		t.Fatal("curtain did not cover both corners")
	}
	x, y := (w-curtainW)/2, (h-curtainH)/2
	// The plate is rounded (§2.2): probe the mid-height band — the accent
	// rule's straight section and the surface deep inside the plate —
	// where no anti-aliased corner blends the tokens.
	if pix[(y+curtainH/2)*w+x] != 0xff000000|tok.Accent ||
		pix[(y+curtainH/2)*w+x+1] != 0xff000000|tok.Accent ||
		pix[(y+curtainH/2)*w+x+curtainW/2] != 0xff000000|tok.Surface {
		t.Fatal("curtain panel lacks its accent rule or surface")
	}
	var ink, muted int
	for _, v := range pix {
		switch v & 0xffffff {
		case tok.Ink:
			ink++
		case tok.InkMuted:
			muted++
		}
	}
	if ink < 20 || muted < 20 {
		t.Fatalf("curtain text absent: ink=%d muted=%d", ink, muted)
	}
	if got := paintIdleCurtain(make([]byte, 3), w, h); got != 0 {
		t.Fatalf("sub-pixel curtain wrote %d pixels", got)
	}
}

func TestPaintChromeRefusesDegenerateScanouts(t *testing.T) {
	if n := paintChrome(nil, 0, 0, "00:00:00"); n != 0 {
		t.Errorf("nil scanout painted %d pixels", n)
	}
	if n := paintChrome([]byte{0, 0, 0, 0}, 0, 0, "00:00:00"); n != 0 {
		t.Errorf("zero-size scanout painted %d pixels", n)
	}
}

// asUint32 views a scanout byte slice as the words the draw engine writes.
// It must ALIAS the caller's buffer, not copy it: BytesCanvas borrows the
// same bytes, so its writes have to land in the slice the test then reads.
func asUint32(scan []byte) []uint32 {
	return unsafe.Slice((*uint32)(unsafe.Pointer(&scan[0])), len(scan)/4)
}

// --- M121d (#2567): the focus indicator ------------------------------------

// saveBadgeState restores the badge's transition latch — the tests move
// the reported state deliberately.
func saveBadgeState() func() {
	b := badgeReported
	return func() { badgeReported = b }
}

func TestFocusRect(t *testing.T) {
	x, y, w, h := focusRect(1280, 720)
	cx, cy, _, _ := chromeRect(1280, 720)
	if w != FocusW || h != ChromeH {
		t.Fatalf("focusRect size = %dx%d want %dx%d", w, h, FocusW, ChromeH)
	}
	if x+w+focusGap != cx || y != cy {
		t.Fatalf("focusRect %d,%d %dx%d not flush-left of the clock at %d,%d", x, y, w, h, cx, cy)
	}
	if x < 0 || y < 0 || x+w > 1280 || y+h > 720 {
		t.Fatalf("focusRect %d,%d %dx%d escapes the scanout", x, y, w, h)
	}
	px, _, pw, _ := powerBtnRect(1280, 720)
	if x < px+pw {
		t.Fatalf("focusRect x=%d reaches into the power button (ends %d)", x, px+pw)
	}
	// The panel still fits when the band has room between the power
	// button and the clock; on a crowded or tiny band it gives up.
	if x, y, w, h := focusRect(800, 200); w != FocusW || h != ChromeH || x+w+focusGap != 644 {
		t.Errorf("800x200 focusRect = %d,%d %dx%d want 424,192 %dx%d", x, y, w, h, FocusW, ChromeH)
	}
	if x, y, w, h := focusRect(500, 100); w != 0 || h != 0 || x != 0 || y != 0 {
		t.Errorf("crowded band focusRect = %d,%d %dx%d want zero", x, y, w, h)
	}
	if x, y, w, h := focusRect(10, 10); w != 0 || h != 0 || x != 0 || y != 0 {
		t.Errorf("tiny scanout focusRect = %d,%d %dx%d want zero", x, y, w, h)
	}
}

// terminalFrontEndBin is the seat's only window-tty knowledge: the table
// names the bins observed calling vi.TtyAttachWindow, on the stem so a
// bare declared title classifies like the canonical ELF name.
func TestTerminalFrontEndBin(t *testing.T) {
	term := []string{
		"GOTERM.ELF", "GOFILES.ELF", "GOSH.ELF", "GOHELP.ELF", "GOGITUI.ELF",
		"RSS.ELF", "IMGCAT.ELF", "imgcat", "BTMATH.ELF", "CHARMHELLO.ELF",
		"PULSE.ELF", "GOSTALGIA.ELF",
	}
	for _, b := range term {
		if !terminalFrontEndBin(b) {
			t.Errorf("terminalFrontEndBin(%q) = false, want term", b)
		}
	}
	app := []string{"GOEDIT.ELF", "WEB.ELF", "GOCALC.ELF", "NOTE.ELF", "GOVIEW.ELF", "Edit", "", "GOTABWM.ELF"}
	for _, b := range app {
		if terminalFrontEndBin(b) {
			t.Errorf("terminalFrontEndBin(%q) = true, want app", b)
		}
	}
}

func TestFocusBadgeStateTransitions(t *testing.T) {
	defer saveSeatState()()
	// Empty strip: the seat's own chords answer.
	tabs = TabStrip{}
	if v := focusBadgeState(); v.scope != "seat" || v.title != "" {
		t.Fatalf("empty strip = %+v want scope=seat", v)
	}
	// An app tab: its own KEY_DOWN scope answers.
	if !tabs.OpenTab(10, "Edit") {
		t.Fatal("OpenTab Edit")
	}
	if v := focusBadgeState(); v.scope != "app" || v.title != "Edit" {
		t.Fatalf("Edit focused = %+v want app/Edit", v)
	}
	// A tty-bound tab: the kernel's terminal chrome chords answer too.
	if !tabs.OpenTab(11, "Term") || !tabs.FocusTab(11) {
		t.Fatal("OpenTab/FocusTab Term")
	}
	if v := focusBadgeState(); v.scope != "term" || v.title != "Term" {
		t.Fatalf("Term focused = %+v want term/Term", v)
	}
	// A seat modal holding the input sink overrides the rail's focus.
	launch.open, launch.sink = true, 42
	if v := focusBadgeState(); v.scope != "seat" {
		t.Fatalf("launcher sink = %+v want seat", v)
	}
	launch.open, launch.sink = false, 0
	powerMenuOpen, powerSink = true, 43
	if v := focusBadgeState(); v.scope != "seat" {
		t.Fatalf("power sink = %+v want seat", v)
	}
	powerMenuOpen, powerSink = false, 0
	// Back to the focused tab, then closing it re-focuses the neighbour.
	if v := focusBadgeState(); v.scope != "term" || v.title != "Term" {
		t.Fatalf("sink released = %+v want term/Term", v)
	}
	if !tabs.CloseTab(11) {
		t.Fatal("CloseTab Term")
	}
	if v := focusBadgeState(); v.scope != "app" || v.title != "Edit" {
		t.Fatalf("after close = %+v want app/Edit", v)
	}
	if !tabs.CloseTab(10) {
		t.Fatal("CloseTab Edit")
	}
	if v := focusBadgeState(); v.scope != "seat" {
		t.Fatalf("last close = %+v want seat", v)
	}
}

func TestFocusBadgeMarkerTransitions(t *testing.T) {
	defer saveSeatState()()
	defer saveBadgeState()()
	badgeReported = focusBadgeView{}
	if MarkerFocus != "gotabwm: focus " {
		t.Fatalf("MarkerFocus = %q", MarkerFocus)
	}
	if l := focusBadgeLine(focusBadgeView{scope: "seat"}); l != "gotabwm: focus scope=seat" {
		t.Fatalf("seat line = %q", l)
	}
	if l := focusBadgeLine(focusBadgeView{title: "Edit", scope: "app"}); l != "gotabwm: focus scope=app title=Edit" {
		t.Fatalf("app line = %q", l)
	}
	// The transition reports at the state change, deduped on the last
	// reported claim — rapid cycles each earn a line even when no paint
	// ran between them. The reported latch is what the serial line names.
	tabs = TabStrip{}
	if !tabs.OpenTab(10, "Edit") {
		t.Fatal("OpenTab")
	}
	noteBadgeTransition()
	if badgeReported != (focusBadgeView{title: "Edit", scope: "app"}) {
		t.Fatalf("first transition = %+v", badgeReported)
	}
	if !tabs.OpenTab(11, "Term") || !tabs.FocusTab(11) {
		t.Fatal("FocusTab Term")
	}
	noteBadgeTransition()
	if badgeReported != (focusBadgeView{title: "Term", scope: "term"}) {
		t.Fatalf("term transition = %+v", badgeReported)
	}
	noteBadgeTransition()
	if badgeReported != (focusBadgeView{title: "Term", scope: "term"}) {
		t.Fatal("steady state reprinted")
	}
	if !tabs.CloseTab(11) || !tabs.CloseTab(10) {
		t.Fatal("CloseTab")
	}
	noteBadgeTransition()
	if badgeReported != (focusBadgeView{scope: "seat"}) {
		t.Fatalf("close-to-seat = %+v", badgeReported)
	}
}

func TestPaintFocusBadgeUsesTokens(t *testing.T) {
	defer saveSeatState()()
	defer saveBadgeState()()
	const w, h = 1280, 720
	scan := make([]byte, w*h*4)
	tok := theme.Current
	for i := 0; i < len(scan)/4; i++ {
		asUint32(scan)[i] = theme.Light.Success
	}
	tabs = TabStrip{}
	if !tabs.OpenTab(10, "Edit") {
		t.Fatal("OpenTab")
	}
	if paintFocusBadge(scan, w, h) == 0 {
		t.Fatal("paintFocusBadge painted nothing")
	}
	pix := asUint32(scan)
	x, y, pw, ph := focusRect(w, h)
	var panel, accent, ink int
	for row := 0; row < h; row++ {
		for col := 0; col < w; col++ {
			v := pix[row*w+col]
			inRect := col >= x && col < x+pw && row >= y && row < y+ph
			if !inRect {
				if v != theme.Light.Success {
					t.Fatalf("paintFocusBadge wrote outside the panel at %d,%d", col, row)
				}
				continue
			}
			switch v & 0xffffff {
			case tok.ChromeBg:
				panel++
			case tok.Accent:
				accent++
			case tok.Ink:
				ink++
			}
		}
	}
	if panel == 0 {
		t.Fatal("panel is not ChromeBg")
	}
	// The accent carries both the 2px seat rule and the scope chip — far
	// more than the rule alone paints on a 20px plate.
	if accent <= 2*ph {
		t.Fatalf("accent pixels = %d, want the chip plus the rule", accent)
	}
	if ink == 0 {
		t.Fatal("title has no Ink pixels")
	}
	if n := paintFocusBadge(nil, 0, 0); n != 0 {
		t.Errorf("degenerate scanout painted %d pixels", n)
	}
}

// The raster pin: the badge on the fonted registry carrying an app tab,
// and on the bitmap degrade carrying a tty-bound tab — one golden per
// text path and scope class.
func paintGoldenBadge(t *testing.T) []byte {
	t.Helper()
	scan := make([]byte, vi.ScanoutWidth*vi.ScanoutHeight*4)
	if paintFocusBadge(scan, vi.ScanoutWidth, vi.ScanoutHeight) == 0 {
		t.Fatal("paintFocusBadge wrote nothing")
	}
	x, y, w, h := focusRect(vi.ScanoutWidth, vi.ScanoutHeight)
	out := make([]byte, w*h*4)
	for row := 0; row < h; row++ {
		src := ((y + row) * vi.ScanoutWidth + x) * 4
		copy(out[row*w*4:], scan[src:src+w*4])
	}
	return out
}

func TestFocusBadgeGolden(t *testing.T) {
	defer saveSeatState()()
	defer saveBadgeState()()
	tok := theme.Current
	theme.Current = theme.Dark
	t.Cleanup(func() { theme.Current = tok })
	stubSeatRegistry(t, seatRegistryFromRepo(t))
	tabs = TabStrip{}
	if !tabs.OpenTab(10, "Edit") {
		t.Fatal("OpenTab")
	}
	checkSeatGolden(t, "seat-focus-badge", paintGoldenBadge(t), FocusW, ChromeH)
}

func TestFocusBadgeGoldenDegrade(t *testing.T) {
	defer saveSeatState()()
	defer saveBadgeState()()
	tok := theme.Current
	theme.Current = theme.Dark
	t.Cleanup(func() { theme.Current = tok })
	stubSeatRegistry(t, nil)
	tabs = TabStrip{}
	if !tabs.OpenTab(10, "Term") {
		t.Fatal("OpenTab")
	}
	checkSeatGolden(t, "seat-focus-badge-degrade", paintGoldenBadge(t), FocusW, ChromeH)
}

// --- M178c (#3146): the seat clock applies the timezone row ---------------

// saveClockSeam restores the seat clock's epoch/zone seams and cache —
// the tests below drive clockNow without a guest.
func saveClockSeam() func() {
	kt, zl, zm, zv := kernelTime, clockZoneLoad, clockZoneMin, clockZoneVal
	return func() {
		kernelTime, clockZoneLoad = kt, zl
		clockZoneMin, clockZoneVal = zm, zv
	}
}

// TestClockNowAppliesTheTimezoneRow pins the card's seat-clock leg: the
// kernel epoch formats under the `timezone` row in force — a named zone's
// offset at that instant — so the seat face agrees with `date`. Epoch
// 1792497600 is 2026-10-20 12:00:00 UTC; Berlin is still CEST (+02:00).
func TestClockNowAppliesTheTimezoneRow(t *testing.T) {
	defer saveClockSeam()()
	kernelTime = func() int64 { return 1792497600 }
	berlin, ok := clockfmt.Parse("Europe/Berlin")
	if !ok {
		t.Fatal("Europe/Berlin must parse")
	}
	clockZoneLoad = func() clockfmt.Zone { return berlin }
	clockZoneMin = -1
	face := clockNow(0)
	if face.source != "kernel" || face.h != 14 || face.m != 0 || face.s != 0 {
		t.Fatalf("Berlin face = %+v, want 14:00:00 kernel", face)
	}
	// The same epoch under the UTC default keeps the old face.
	clockZoneLoad = func() clockfmt.Zone { return clockfmt.UTC }
	clockZoneMin = -1
	if face := clockNow(0); face.h != 12 || face.m != 0 || face.s != 0 {
		t.Fatalf("UTC face = %+v, want 12:00:00", face)
	}
	// A fixed-offset row shifts the face by exactly its offset.
	clockZoneLoad = func() clockfmt.Zone { return 5*3600 + 30*60 }
	clockZoneMin = -1
	if face := clockNow(0); face.h != 17 || face.m != 30 {
		t.Fatalf("+05:30 face = %+v, want 17:30:00", face)
	}
}

// TestClockZoneRereadsOnMinuteRollover pins the cache discipline: the row
// is read once per displayed minute — a `settings set` lands within a
// minute without a settings-bus subscription — and never twice inside one.
func TestClockZoneRereadsOnMinuteRollover(t *testing.T) {
	defer saveClockSeam()()
	loads := 0
	clockZoneLoad = func() clockfmt.Zone { loads++; return clockfmt.UTC }
	clockZoneMin = -1
	clockZoneFor(100)
	clockZoneFor(100)
	if loads != 1 {
		t.Fatalf("two reads inside one minute: %d", loads)
	}
	clockZoneFor(101)
	if loads != 2 {
		t.Fatalf("minute rollover did not re-read: %d", loads)
	}
}
