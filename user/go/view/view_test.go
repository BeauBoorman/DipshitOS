package main

import (
	"os"
	"testing"
)

// The fixtures the live-image-viewer gate stages into the share. The viewer's
// window sizing is asserted through them, so the tests read the same bytes.
const (
	qoiFixture  = "../../../tests/fixtures/qoi/viewer_160x120.qoi"
	pngFixture  = "../../../tests/fixtures/png/viewer_160x120.png"
	jpegFixture = "../webrender/testdata/jpeg/viewer_160x120.jpg"
)

func readFixture(t *testing.T, path string) []byte {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("fixture %s is required by this package's tests: %v", path, err)
	}
	return b
}

func TestFormatFromPath(t *testing.T) {
	cases := []struct {
		path string
		want format
	}{
		{"/host/TEST.QOI", fmtQOI},
		{"/host/TEST.qoi", fmtQOI},
		{"/host/TEST.PNG", fmtPNG},
		{"/host/tEST.pNg", fmtPNG},
		{"/host/TEST.JPG", fmtJPEG},
		{"/host/test.jpeg", fmtJPEG},
		{"/host/TEST.GIF", fmtUnknown},
		{"/host/no-extension", fmtUnknown},
		{".hidden", fmtUnknown},
	}
	for _, c := range cases {
		if got := formatFromPath(c.path); got != c.want {
			t.Errorf("formatFromPath(%q) = %v, want %v", c.path, got.tag(), c.want.tag())
		}
	}
}

func TestBasename(t *testing.T) {
	cases := map[string]string{
		"/host/TEST.QOI":  "TEST.QOI",
		"TEST.QOI":        "TEST.QOI",
		"/host/sub/a.PNG": "a.PNG",
		"":                "",
	}
	for in, want := range cases {
		if got := basename(in); got != want {
			t.Errorf("basename(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestChooseWindowSize pins the value the live gate asserts: a 160x120 image
// gets a 328x264 window (2x the image plus the 8px side and 24px vertical
// padding) — the same number Zig VIEW.BIN printed, which is what makes the
// retargeted `gview: open id=N 328x264` assert a continuity proof rather than a
// new expectation.
func TestChooseWindowSize(t *testing.T) {
	cases := []struct {
		iw, ih uint32
		wantW  uint32
		wantH  uint32
		why    string
	}{
		{160, 120, 328, 264, "the live fixture: 2x image + padding"},
		{0, 0, 240, 160, "no geometry yet"},
		{1, 1, 96, 72, "a 1px image still gets the minimum window"},
		// The cap is on the CONTENT area (win_max minus the padding), so a
		// 4:3 image lands on the 492-wide content box and its height follows
		// the aspect: 369+24 = 393, still inside the 408 window cap.
		{4000, 3000, 500, 393, "past the cap: the content box is as wide as it may be"},
		// Portrait: height-capped first (384), then the 2x-image clamp pulls the
		// width to 240 while the height stays 320.
		{120, 160, 248, 344, "portrait image: aspect preserved, still inside 2x"},
	}
	for _, c := range cases {
		got := chooseWindowSize(c.iw, c.ih)
		if got.W != c.wantW || got.H != c.wantH {
			t.Errorf("chooseWindowSize(%d,%d) = %dx%d, want %dx%d (%s)",
				c.iw, c.ih, got.W, got.H, c.wantW, c.wantH, c.why)
		}
	}
}

func TestViewportRect(t *testing.T) {
	vp := viewportRect(328, 264)
	if vp != (viewport{0, titleBandH, 328, 236}) {
		t.Fatalf("viewportRect(328,264) = %+v, want {0,16,328,236}", vp)
	}
	// A window shorter than the chrome has no viewport at all rather than a
	// negative height (uint arithmetic would wrap).
	if got := viewportRect(300, 20); got.W != 0 || got.H != 0 {
		t.Errorf("viewportRect(300,20) = %+v, want the empty viewport", got)
	}
}

func TestDisplayedSizeAndZoomTable(t *testing.T) {
	if got := displayedSize(160, 120, 100); got != (winSize{160, 120}) {
		t.Errorf("displayedSize 100%% = %+v, want 160x120", got)
	}
	if got := displayedSize(160, 120, 800); got != (winSize{1280, 960}) {
		t.Errorf("displayedSize 800%% = %+v, want 1280x960", got)
	}
	// Never zero: a 1px image at 25% still occupies a pixel.
	if got := displayedSize(1, 1, 25); got.W != 1 || got.H != 1 {
		t.Errorf("displayedSize(1,1,25) = %+v, want 1x1", got)
	}
	if zoomTable[zoomDefaultIdx] != 100 {
		t.Fatalf("zoom table default index %d is %d%%, want 100%%",
			zoomDefaultIdx, zoomTable[zoomDefaultIdx])
	}
	if len(zoomTable) != 11 {
		t.Errorf("zoom table has %d entries, want 11 (VIEW.BIN's table)", len(zoomTable))
	}
}

func TestStepZoomClampsAtBothEnds(t *testing.T) {
	if got := stepZoom(zoomDefaultIdx, zoomIn); got != 5 {
		t.Errorf("zoom in from default = index %d, want 5 (150%%)", got)
	}
	if got := stepZoom(len(zoomTable)-1, zoomIn); got != len(zoomTable)-1 {
		t.Errorf("zoom in at the top = index %d, want it pinned", got)
	}
	if got := stepZoom(0, zoomOut); got != 0 {
		t.Errorf("zoom out at the bottom = index %d, want it pinned", got)
	}
	if got := stepZoom(9, zoomReset); got != zoomDefaultIdx {
		t.Errorf("reset = index %d, want the default", got)
	}
}

func TestDestLayoutCentersThenClips(t *testing.T) {
	vp := viewport{0, 16, 328, 236}
	if got := destLayout(vp, 160, 120); got != (dest{84, 74, 160, 120}) {
		t.Errorf("fits: destLayout = %+v, want {84,74,160,120}", got)
	}
	// Wider and taller than the viewport: pinned top-left, clipped to it.
	if got := destLayout(vp, 640, 480); got != (dest{0, 16, 328, 236}) {
		t.Errorf("overflows: destLayout = %+v, want {0,16,328,236}", got)
	}
}

func TestPanClamp(t *testing.T) {
	// Whole image visible: only the origin is legal.
	if got := panMax(160, 160, 328); got != 0 {
		t.Errorf("panMax with the image fitting = %d, want 0", got)
	}
	if got := clampOrigin(50, 160, 160, 328); got != 0 {
		t.Errorf("clampOrigin with the image fitting = %d, want 0", got)
	}
	// At 800% the image is 1280 wide in a 1100 viewport: the origin can reach
	// img - (vp*img/disp) = 160 - 137 = 23.
	if got := panMax(160, 1280, 1100); got != 23 {
		t.Errorf("panMax(160,1280,1100) = %d, want 23", got)
	}
	if got := clampOrigin(999, 160, 1280, 1100); got != 23 {
		t.Errorf("clampOrigin(999,...) = %d, want the clamp at 23", got)
	}
}

func TestApplyDeltaClampsSignedSteps(t *testing.T) {
	cases := []struct {
		cur   uint32
		delta int32
		max   uint32
		want  uint32
	}{
		{0, -5, 20, 0},
		{10, -4, 20, 6},
		{18, 9, 20, 20},
		{23, 1, 23, 23},
	}
	for _, c := range cases {
		if got := applyDelta(c.cur, c.delta, c.max); got != c.want {
			t.Errorf("applyDelta(%d,%d,%d) = %d, want %d", c.cur, c.delta, c.max, got, c.want)
		}
	}
}

// TestHeaderSizeFromRealFixtures is the measurement the retarget rests on: both
// fixtures declare 160x120 in their headers, so both boots of the gate can
// assert the SAME window size — including the PNG boot, which this viewer
// cannot decode on the guest.
func TestHeaderSizeFromRealFixtures(t *testing.T) {
	for _, path := range []string{qoiFixture, pngFixture, jpegFixture} {
		data := readFixture(t, path)
		head := data
		if len(head) > headMax {
			head = head[:headMax]
		}
		iw, ih, ok := headerDims(head)
		if !ok {
			t.Fatalf("%s: header sniff failed", path)
		}
		if iw != 160 || ih != 120 {
			t.Errorf("%s: header dims = %dx%d, want 160x120", path, iw, ih)
		}
		if got := headerSize(head); got != (winSize{328, 264}) {
			t.Errorf("%s: headerSize = %+v, want 328x264", path, got)
		}
	}
	if got := headerSize([]byte("not an image at all....")); got != defaultWinSize {
		t.Errorf("garbage header = %+v, want the default window", got)
	}
	if got := headerSize(nil); got != defaultWinSize {
		t.Errorf("no header = %+v, want the default window", got)
	}
}

func TestFormatOfHeaderIgnoresExtension(t *testing.T) {
	if got := formatOfHeader(readFixture(t, qoiFixture)); got != fmtQOI {
		t.Errorf("QOI fixture sniffed as %s", got.tag())
	}
	if got := formatOfHeader(readFixture(t, pngFixture)); got != fmtPNG {
		t.Errorf("PNG fixture sniffed as %s", got.tag())
	}
	if got := formatOfHeader(readFixture(t, jpegFixture)); got != fmtJPEG {
		t.Errorf("JPEG fixture sniffed as %s", got.tag())
	}
	if got := formatOfHeader([]byte("qoif")); got != fmtQOI {
		t.Errorf("short QOI magic sniffed as %s", got.tag())
	}
	if got := formatOfHeader([]byte{0x89, 'P', 'N'}); got != fmtUnknown {
		t.Errorf("truncated magic sniffed as %s", got.tag())
	}
}

// TestJPEGHeaderDims walks a hand-built segment chain the way the gate's
// progressive leg needs: APPn and table segments are skipped on their
// lengths, the first SOF's dims answer the sniff — whatever SOF marker
// carries them — and a scan start or a truncated chain yields no dims.
func TestJPEGHeaderDims(t *testing.T) {
	var b []byte
	seg := func(m byte, body []byte) {
		b = append(b, 0xff, m, byte((len(body)+2)>>8), byte(len(body)+2))
		b = append(b, body...)
	}
	sof := func(m byte, w, h int) {
		seg(m, []byte{8, byte(h >> 8), byte(h), byte(w >> 8), byte(w), 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1})
	}
	mk := func(build func()) []byte {
		b = []byte{0xff, 0xd8}
		build()
		return b
	}

	good := mk(func() {
		seg(0xe0, []byte("JFIF\x00\x01\x02\x00\x01")) // APP0
		seg(0xdb, make([]byte, 65))                   // DQT
		seg(0xfe, []byte("a comment"))                // COM
		sof(0xc0, 160, 120)                           // SOF0
	})
	if w, h, ok := jpegHeaderDims(good); !ok || w != 160 || h != 120 {
		t.Fatalf("jpegHeaderDims = %dx%d %v, want 160x120", w, h, ok)
	}
	// A progressive frame (SOF2) still sizes the window.
	prog := mk(func() { sof(0xc2, 640, 480) })
	if w, h, ok := jpegHeaderDims(prog); !ok || w != 640 || h != 480 {
		t.Fatalf("SOF2 dims = %dx%d %v, want 640x480", w, h, ok)
	}
	// SOS before any SOF yields no dims.
	if _, _, ok := jpegHeaderDims(mk(func() { seg(0xda, []byte{1, 1, 0, 0, 63, 0}) })); ok {
		t.Fatal("SOS-first chain must not size")
	}
	// A chain truncated inside the SOF dims yields no dims (a tail
	// truncation past them still answers — the sniff is best-effort).
	if _, _, ok := jpegHeaderDims(good[:len(good)-12]); ok {
		t.Fatal("truncated SOF dims must not size")
	}
	// The viewer's real fixture.
	data := readFixture(t, jpegFixture)
	if w, h, ok := jpegHeaderDims(data); !ok || w != 160 || h != 120 {
		t.Fatalf("fixture dims = %dx%d %v, want 160x120", w, h, ok)
	}
}

func TestComposeTitle(t *testing.T) {
	if got := composeTitle("TEST.QOI", 160, 120, fmtQOI, 100); got != "TEST.QOI 160x120 QOI 100%" {
		t.Errorf("composeTitle = %q", got)
	}
	if got := composeTitle("", 0, 0, fmtUnknown, 100); got != "(no image)" {
		t.Errorf("composeTitle with no file = %q, want the empty-state title", got)
	}
}
