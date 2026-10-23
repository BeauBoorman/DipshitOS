package main

// M190b (#3237): the chord → banded read → PNG → publish chain is
// observable off-guest through the shot* seams, so every leg of the
// card's verification — chord → SHOT-*.png on the share decoding to the
// scanout's pixel shape, and each named refusal — is pinned here before
// the go-dogfood shot leg re-proves the chord end-to-end.

import (
	"bytes"
	"image/png" // the host-only test reference (the pngenc_test.go rule)
	"strings"
	"testing"

	"virelai/chords"
	"virelai/vi"
	"virelai/webrender"
)

// shotEnv is the shot seams' recorder. The fake framebuffer answers a
// deterministic BGRX ramp per (x, y) pixel, so the banded read's
// geometry AND the BGRX→0xFFRRGGBB conversion are checked byte-for-byte
// against the coordinate the call named.
type shotEnv struct {
	reads  []shotReadCall
	writes map[string][]byte
	mkdirs []string
	logs   []string
	mount  bool
	now    int64
	rdErr  int64
	wrErr  int64
	mkErr  int64
}

type shotReadCall struct{ x, y, w, h uint32 }

// shotPixel is the fake framebuffer's BGRX ramp for device pixel (x, y)
// — three different per-axis strides so a transpose, a dropped channel,
// or a band seam all show.
func shotPixel(x, y uint32) (b, g, r, a byte) {
	return byte(x + y), byte(3*x + 5*y), byte(7*x + 11*y), 0xff
}

// swapShotEnv installs e's seams and returns the restore. notifyDND,
// the toast queue and the center ride along — a test's toasts must not
// leak into the next one.
func (e *shotEnv) swapShotEnv(t *testing.T) func() {
	t.Helper()
	if e.writes == nil {
		e.writes = map[string][]byte{}
	}
	pr, pl, pw, pn, pm, plog := shotRead, shotList, shotWrite, shotNow, shotMkdir, shotLog
	pq, pc, pd, pdrop := notifyQueue, notifyCenter, notifyDND, notifyDropped
	notifyQueue, notifyCenter, notifyDND, notifyDropped = nil, nil, false, 0
	shotList = func(path string, buf []vi.DirEntry) (int, int64) {
		if !e.mount {
			return -1, -vi.ErrENXIO
		}
		return 0, 0
	}
	shotRead = func(x, y, w, h uint32, buf []byte) int64 {
		e.reads = append(e.reads, shotReadCall{x, y, w, h})
		if e.rdErr != 0 {
			return e.rdErr
		}
		for i := 0; i < int(w)*int(h); i++ {
			b, g, r, a := shotPixel(x+uint32(i)%w, y+uint32(i)/w)
			buf[i*4], buf[i*4+1], buf[i*4+2], buf[i*4+3] = b, g, r, a
		}
		return int64(len(buf))
	}
	shotWrite = func(path string, b []byte) int64 {
		if e.wrErr != 0 {
			return e.wrErr
		}
		cp := make([]byte, len(b))
		copy(cp, b)
		e.writes[path] = cp
		return 0
	}
	shotNow = func() int64 { return e.now }
	shotMkdir = func(path string) int64 {
		e.mkdirs = append(e.mkdirs, path)
		if e.mkErr != 0 {
			return e.mkErr
		}
		return vi.ErrFileExists // the steady state: SHOTS already exists
	}
	shotLog = func(s string) { e.logs = append(e.logs, s) }
	return func() {
		shotRead, shotList, shotWrite, shotNow, shotMkdir, shotLog = pr, pl, pw, pn, pm, plog
		notifyQueue, notifyCenter, notifyDND, notifyDropped = pq, pc, pd, pdrop
	}
}

func (e *shotEnv) hasLog(sub string) bool {
	for _, l := range e.logs {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

// TestShotBandRows pins the band arithmetic against ScanoutReadMax: a
// full-width rect bands at the agentd card's own 12 rows (720 is a
// multiple of it), a window rect on its own row width.
func TestShotBandRows(t *testing.T) {
	if got := shotBandRows(1280); got != 12 {
		t.Fatalf("shotBandRows(1280) = %d want 12 (61,440 B under the 64 KiB cap)", got)
	}
	if got := shotBandRows(640); got != 25 {
		t.Fatalf("shotBandRows(640) = %d want 25", got)
	}
	if got := shotBandRows(0); got != 0 {
		t.Fatalf("shotBandRows(0) = %d want 0", got)
	}
}

// TestShotCaptureBandsAndConverts: a window-sized rect reads in one
// band and every word is the opaque BGRX→ARGB conversion of the pixel
// the coordinate named.
func TestShotCaptureBandsAndConverts(t *testing.T) {
	e := &shotEnv{}
	defer e.swapShotEnv(t)()
	pix, why := shotCapture(10, 20, 40, 30)
	if why != "" || len(pix) != 40*30 {
		t.Fatalf("shotCapture = (%d px, %q)", len(pix), why)
	}
	if len(e.reads) != 1 || e.reads[0] != (shotReadCall{10, 20, 40, 30}) {
		t.Fatalf("one band expected, reads = %+v", e.reads)
	}
	for i, p := range pix {
		b, g, r, _ := shotPixel(10+uint32(i)%40, 20+uint32(i)/40)
		want := uint32(0xff)<<24 | uint32(r)<<16 | uint32(g)<<8 | uint32(b)
		if p != want {
			t.Fatalf("pix[%d] = %#08x want %#08x", i, p, want)
		}
	}
}

// TestShotCaptureFullFrameBanding pins the agentd pattern: the whole
// 1280x720 frame lands in exactly 60 twelve-row bands and every word
// converts — the ~3.6 MB buffer the card names its memory bound.
func TestShotCaptureFullFrameBanding(t *testing.T) {
	e := &shotEnv{}
	defer e.swapShotEnv(t)()
	pix, why := shotCapture(0, 0, vi.ScanoutWidth, vi.ScanoutHeight)
	if why != "" || len(pix) != vi.ScanoutWidth*vi.ScanoutHeight {
		t.Fatalf("shotCapture = (%d px, %q)", len(pix), why)
	}
	if len(e.reads) != 60 {
		t.Fatalf("full frame = %d reads, want 60 bands of 12 rows", len(e.reads))
	}
	for i, c := range e.reads {
		if c.x != 0 || c.y != uint32(i*12) || c.w != vi.ScanoutWidth || c.h != 12 {
			t.Fatalf("band %d = %+v want (0, %d, 1280, 12)", i, c, i*12)
		}
	}
	for _, i := range []int{0, 1280*12 - 1, 1280 * 12, 1280*360 + 640, 1280*720 - 1} {
		b, g, r, _ := shotPixel(uint32(i)%1280, uint32(i)/1280)
		want := uint32(0xff)<<24 | uint32(r)<<16 | uint32(g)<<8 | uint32(b)
		if pix[i] != want {
			t.Fatalf("pix[%d] = %#08x want %#08x — band seam dropped", i, pix[i], want)
		}
	}
}

// TestShotCaptureRefusals: a rect the scanout cannot frame and a read
// the kernel refused are named, never silently dropped.
func TestShotCaptureRefusals(t *testing.T) {
	e := &shotEnv{}
	defer e.swapShotEnv(t)()
	for _, r := range [][4]uint32{{0, 0, 0, 10}, {0, 0, 10, 0}, {0, 0, 1281, 1}, {0, 720, 1, 1}} {
		if pix, why := shotCapture(r[0], r[1], r[2], r[3]); pix != nil || why != "bad_rect" {
			t.Fatalf("rect %v = (%v, %q) want (nil, bad_rect)", r, pix != nil, why)
		}
	}
	e.rdErr = -vi.ErrENXIO
	if pix, why := shotCapture(0, 0, 40, 30); pix != nil || why != "io_enxio" {
		t.Fatalf("refused read = (%v, %q) want (nil, io_enxio)", pix != nil, why)
	}
}

// TestShotFullChordPublishes is the card's leg on the host: the chord
// lands a SHOT-<unix>.png on the share whose IHDR is the scanout's
// shape, the marker carries path+mode+geometry, and the toast names the
// file.
func TestShotFullChordPublishes(t *testing.T) {
	e := &shotEnv{mount: true, now: 1761234567}
	defer e.swapShotEnv(t)()
	shotChord(false)
	want := "/host/SHOTS/SHOT-1761234567.png"
	png, ok := e.writes[want]
	if !ok || len(e.writes) != 1 {
		t.Fatalf("writes = %v, want exactly %q", writePaths(e.writes), want)
	}
	if string(png[:8]) != "\x89PNG\r\n\x1a\n" {
		t.Fatal("published body is not a PNG")
	}
	// IHDR: width, height, depth 8, colour type 2 (RGB — the opaque
	// conversion pins it), compression/filter/interlace 0.
	if be := uint32(png[16])<<24 | uint32(png[17])<<16 | uint32(png[18])<<8 | uint32(png[19]); be != 1280 {
		t.Fatalf("IHDR w = %d want 1280", be)
	}
	if be := uint32(png[20])<<24 | uint32(png[21])<<16 | uint32(png[22])<<8 | uint32(png[23]); be != 720 {
		t.Fatalf("IHDR h = %d want 720", be)
	}
	if png[24] != 8 || png[25] != 2 || png[26] != 0 || png[27] != 0 || png[28] != 0 {
		t.Fatalf("IHDR tail = %v want depth=8 ctype=2 rest 0", png[24:29])
	}
	if !e.hasLog(MarkerShotSaved + want + " mode=full w=1280 h=720 bytes=") {
		t.Fatalf("saved marker missing or wrong: %v", e.logs)
	}
	if !e.hasLog(MarkerNotify + "0 shot SHOT-1761234567.png") {
		t.Fatalf("toast missing or unnamed: %v", e.logs)
	}
	if notifyCount() != 1 {
		t.Fatalf("toasts = %d want 1", notifyCount())
	}
	// The published PNG decodes to the same words the capture wrote —
	// the pixel-shape leg before the gate does it against live hardware.
	im, err := decodePNGForTest(png)
	if err != nil {
		t.Fatalf("published PNG does not decode: %v", err)
	}
	if im.Width != 1280 || im.Height != 720 {
		t.Fatalf("decoded shape %dx%d want 1280x720", im.Width, im.Height)
	}
	for _, i := range []int{0, 640, 1280*360 + 640, 1280*720 - 1} {
		b, g, r, _ := shotPixel(uint32(i)%1280, uint32(i)/1280)
		want := uint32(0xff)<<24 | uint32(r)<<16 | uint32(g)<<8 | uint32(b)
		if im.Pix[i] != want {
			t.Fatalf("decoded pix[%d] = %#08x want %#08x", i, im.Pix[i], want)
		}
	}
}

// decodePNGForTest decodes a published PNG for shape/pixel comparison.
// webrender.DecodePNG refuses bodies over the browser's image bound
// (MaxImageBytes), which a live scanout can exceed, so the fallback is
// the host-only stdlib reference — the same split pngenc_test.go makes.
func decodePNGForTest(data []byte) (*webrender.Image, error) {
	im, err := webrender.DecodePNG(data)
	if err == nil {
		return im, nil
	}
	return stdPNGDecode(data)
}

// stdPNGDecode is the host-only reference decode, to webrender's own
// 0xAARRGGBB word layout.
func stdPNGDecode(data []byte) (*webrender.Image, error) {
	src, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	b := src.Bounds()
	im := &webrender.Image{Width: b.Dx(), Height: b.Dy(),
		Pix: make([]uint32, b.Dx()*b.Dy())}
	for y := 0; y < b.Dy(); y++ {
		for x := 0; x < b.Dx(); x++ {
			r, g, bl, a := src.At(x, y).RGBA()
			im.Pix[y*b.Dx()+x] = (a>>8)<<24 | (r>>8)<<16 | (g>>8)<<8 | bl>>8
		}
	}
	return im, nil
}

// TestShotWindowChordUsesFocusedRect: the window chord reads the
// focused tab's applied rect — here a real split pane, so the read
// coordinates and the PNG shape are the pane's, not the frame's.
func TestShotWindowChordUsesFocusedRect(t *testing.T) {
	defer saveSeatState()()
	e := &shotEnv{mount: true, now: 42}
	defer e.swapShotEnv(t)()
	openTwoTabs(t)
	_, restore := rectRecorder()
	defer restore()
	if !applySplit(SplitVert) {
		t.Fatal("applySplit")
	}
	if !tabs.FocusTab(4) {
		t.Fatal("FocusTab")
	}
	want, ok := paneRectOf(4)
	if !ok {
		t.Fatal("tab 4 has no pane after the split")
	}
	shotChord(true)
	if len(e.reads) == 0 {
		t.Fatal("window chord read nothing")
	}
	// The banded walk covers the pane rect exactly: every call is the
	// pane's own column (x, w), the rows partition its height.
	var rows, y uint32
	for _, c := range e.reads {
		if c.x != want.X || c.w != want.W || c.y != want.Y+y {
			t.Fatalf("band = %+v off the pane rect %+v", c, want)
		}
		y += c.h
		rows++
	}
	if y != want.H || rows > uint32((want.H+shotBandRows(want.W)-1)/shotBandRows(want.W)) {
		t.Fatalf("bands covered h=%d in %d calls, want %d", y, rows, want.H)
	}
	var got []byte
	for path, b := range e.writes {
		if path != "/host/SHOTS/SHOT-42.png" {
			t.Fatalf("write path = %q", path)
		}
		got = b
	}
	if got == nil {
		t.Fatal("window chord published nothing")
	}
	if w := uint32(got[16])<<24 | uint32(got[17])<<16 | uint32(got[18])<<8 | uint32(got[19]); w != want.W {
		t.Fatalf("PNG w = %d want %d (the pane's width)", w, want.W)
	}
	if !e.hasLog(" mode=win w=" + vi.Itoa64(int64(want.W)) + " h=" + vi.Itoa64(int64(want.H))) {
		t.Fatalf("win marker missing: %v", e.logs)
	}
}

// paneRectOf resolves one tab's applied pane rect through the same
// PaneRectsAll the layout dump prints.
func paneRectOf(id uint32) (Rect, bool) {
	for _, p := range tabs.PaneRectsAll(vi.ScanoutWidth, vi.ScanoutHeight) {
		if p.id == id {
			return p.rect, true
		}
	}
	return Rect{}, false
}

// TestShotWindowChordRefusesUnfocusedStrip: the window chord on an
// empty strip names no_window — and publishes nothing.
func TestShotWindowChordRefusesUnfocusedStrip(t *testing.T) {
	defer saveSeatState()()
	e := &shotEnv{mount: true, now: 7}
	defer e.swapShotEnv(t)()
	tabs = TabStrip{}
	shotChord(true)
	if len(e.writes) != 0 || len(e.reads) != 0 {
		t.Fatalf("no-window refusal still wrote: writes=%v reads=%v", e.writes, e.reads)
	}
	if !e.hasLog(MarkerShotRefused+"no_window") || !e.hasLog("shot refused no_window") {
		t.Fatalf("no_window refusal missing: %v", e.logs)
	}
}

// TestShotRefusalsAreNamed walks the named-refusal table: each cause
// reports its own name on the marker AND the toast, and nothing is
// ever published on a refusal.
func TestShotRefusalsAreNamed(t *testing.T) {
	for _, c := range []struct {
		name  string
		mount bool
		rdErr int64
		now   int64
		mkErr int64
		wrErr int64
		want  string
	}{
		{"no share mounted", false, 0, 9, 0, 0, "no_host"},
		{"read refused", true, -vi.ErrENXIO, 9, 0, 0, "io_enxio"},
		{"no epoch", true, 0, -vi.ErrENOSYS, 0, 0, "no_clock"},
		{"mkdir refused", true, 0, 9, -vi.ErrEACCES, 0, "io_eacces"},
		{"publish refused", true, 0, 9, 0, -vi.ErrENOSPC, "io_enospc"},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := &shotEnv{mount: c.mount, now: c.now, rdErr: c.rdErr, mkErr: c.mkErr, wrErr: c.wrErr}
			defer e.swapShotEnv(t)()
			shotChord(false)
			if len(e.writes) != 0 {
				t.Fatalf("refused shot still wrote: %v", writePaths(e.writes))
			}
			if !e.hasLog(MarkerShotRefused + c.want) {
				t.Fatalf("marker %q missing: %v", MarkerShotRefused+c.want, e.logs)
			}
			if !e.hasLog("shot refused " + c.want) {
				t.Fatalf("toast naming %q missing: %v", c.want, e.logs)
			}
		})
	}
}

// TestShotChordDispatchesFromRegistry: the table row IS the dispatch —
// a ctrl+shift+3 WM_KEY reaches shotChord through handleWmKey's
// registry walk, the end-to-end the gate re-runs live.
func TestShotChordDispatchesFromRegistry(t *testing.T) {
	defer saveSeatState()()
	e := &shotEnv{mount: true, now: 5}
	defer e.swapShotEnv(t)()
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl | vi.ModShift,
		Arg0: uint32(chords.UsageDigit1 + 2)})
	if _, ok := e.writes["/host/SHOTS/SHOT-5.png"]; !ok {
		t.Fatalf("ctrl+shift+3 did not publish: writes=%v logs=%v", writePaths(e.writes), e.logs)
	}
}

func writePaths(m map[string][]byte) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
