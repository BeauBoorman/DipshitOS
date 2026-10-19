package main

import (
	"strings"
	"testing"

	"virelai/tabapp"
	"virelai/webrender"
)

// TestMarkersAreAllGViewPrefixed pins the vocabulary the retargeted gate
// asserts, and records the one trap in it: every marker here contains the
// substring "view: ", so a spec must never assert the bare Zig prefix
// `serial-contains 'view: '` — it would match these lines too. The gate uses
// `gview: ` for that reason.
func TestMarkersAreAllGViewPrefixed(t *testing.T) {
	markers := map[string]string{
		"open":        markerOpen,
		"tab-aware":   markerTabAware,
		"not-tab":     markerNotTabAware,
		"empty":       markerEmpty,
		"loaded":      markerLoaded,
		"title":       markerTitleSet,
		"present":     markerPresent,
		"ready":       markerReady,
		"zoom":        markerZoom,
		"pan":         markerPan,
		"quit":        markerQuit,
		"win_close":   markerWinClose,
		"resize":      markerResize,
		"exiting":     markerExiting,
		"open err":    markerOpenErr,
		"read err":    markerReadErr,
		"too large":   markerTooLarge,
		"decode err":  markerDecodeErr,
		"unsupported": markerUnsupported,
		"drop":        markerDrop,
	}
	for what, m := range markers {
		if !strings.HasPrefix(m, "gview: ") {
			t.Errorf("%s marker %q does not carry the gview: prefix", what, m)
		}
		if !strings.Contains(m, "view: ") {
			t.Errorf("%s marker %q lost the view: substring the Zig vocabulary moved by", what, m)
		}
	}
}

// TestLoadSummaryNamesEveryFailure keeps the on-screen reason honest: a state
// with no string would render the empty page for a failure.
func TestLoadSummaryNamesEveryFailure(t *testing.T) {
	for _, st := range []loadState{loadFailedOpen, loadFailedRead, loadTooLarge, loadFailedDecode, loadUnsupported} {
		if got := loadSummary(st, "TEST.QOI"); !strings.Contains(got, "TEST.QOI") {
			t.Errorf("loadSummary(%v) = %q: the failing file must be named", st, got)
		}
	}
	if got := loadSummary(loadOkay, "TEST.QOI"); got != "TEST.QOI" {
		t.Errorf("loadSummary(loadOkay) = %q, want the bare name", got)
	}
}

// TestDecodeReusesTheRendererDecoder is the D1 check: GOVIEW must not carry a
// second QOI decoder, so the fixture has to decode through webrender.
func TestDecodeReusesTheRendererDecoder(t *testing.T) {
	im, err := webrender.DecodeImage(readFixture(t, qoiFixture))
	if err != nil {
		t.Fatalf("webrender.DecodeImage refused the QOI fixture: %v", err)
	}
	if im.Width != 160 || im.Height != 120 {
		t.Errorf("decoded %dx%d, want 160x120", im.Width, im.Height)
	}
	if len(im.Pix) != 160*120 {
		t.Errorf("decoded %d pixels, want %d", len(im.Pix), 160*120)
	}
}

// TestGarbageAndTruncationAreDecodeFailures: the app's contract is that a file
// it cannot decode lands on loadFailedDecode (or loadUnsupported), never on a
// panic and never on "loaded".
func TestGarbageAndTruncationAreDecodeFailures(t *testing.T) {
	for _, c := range []struct {
		what string
		data []byte
	}{
		{"empty", nil},
		{"garbage", []byte("this is definitely not an image, but it is long enough")},
		{"truncated qoi", readFixture(t, qoiFixture)[:20]},
	} {
		if im, err := webrender.DecodeImage(c.data); err == nil {
			t.Errorf("%s: DecodeImage returned %dx%d and no error", c.what, im.Width, im.Height)
		}
	}
}

// TestDropDecodesThroughTheRendererPath is the M124a-2 (#2677) D1 check: a
// delivered drag payload lands through the same DecodeImage as a file load,
// replaces the shown image and resets the view state — refused shapes name
// themselves and leave the image alone.
func TestDropDecodesThroughTheRendererPath(t *testing.T) {
	a := &app{zoomIdx: 2, ox: 9, oy: 7, st: loadFailedOpen}
	if !a.applyDrop(tabapp.DragOffer{Mime: "image/png", Blob: readFixture(t, pngFixture)}) {
		t.Fatal("the PNG fixture drop must apply")
	}
	if a.st != loadOkay || a.iw != 160 || a.ih != 120 {
		t.Fatalf("drop state = (st=%v %dx%d), want okay 160x120", a.st, a.iw, a.ih)
	}
	if a.fm != fmtPNG || a.name != "drop:image/png" {
		t.Fatalf("drop identity = (%v %q)", a.fm, a.name)
	}
	if a.zoomIdx != zoomDefaultIdx || a.ox != 0 || a.oy != 0 {
		t.Fatal("a new image must reset zoom and pan")
	}
	// The refused shapes never replace.
	img := a.img
	if a.applyDrop(tabapp.DragOffer{Mime: "image/png"}) || a.img != img {
		t.Fatal("a nil payload must not replace the image")
	}
	if a.applyDrop(tabapp.DragOffer{Mime: "text/plain", Blob: []byte("not an image at all, really")}) || a.img != img {
		t.Fatal("undecodable bytes must not replace the image")
	}
}

// TestFileCapBeatsTheSharedReaderCap records why readImage does its own loop:
// vi.ReadFileAll clamps every read to vi.MaxFileBytes, so reusing it would make
// this viewer's 512 KiB cap unreachable and turn "too large" into a decode
// error on a truncated file.
func TestFileCapBeatsTheSharedReaderCap(t *testing.T) {
	if fileMax <= 0 {
		t.Fatal("the viewer's file cap must be positive")
	}
	if uint32(fileMax) != 512*1024 {
		t.Errorf("fileMax = %d, want VIEW.BIN's 512 KiB", fileMax)
	}
	if pixelsMax != 131072 {
		t.Errorf("pixelsMax = %d, want VIEW.BIN's 131072-pixel cap", pixelsMax)
	}
}
