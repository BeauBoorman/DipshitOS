package main

import (
	"strings"
	"testing"

	"virelai/tabapp"
	"virelai/theme"
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
		"pick":        markerPick,
		"saved":       markerSaved,
		"save-refuse": markerSaveRefuse,
		"play":        markerPlay,
		"video":       markerVideo,
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

// gifAnimFixture is the live gate's animated GIF: three distinct 160x120
// frames at 10 cs each.
const gifAnimFixture = "../webrender/testdata/gif/anim3_160x120.gif"

// TestDecodeForViewRoutesGIF is the M162a entry point's own check: a GIF
// decodes through DecodeGIFFrames so the stepper has every composited frame
// (shown frame 1, screen-sized), while the other formats still go through
// DecodeImage with no animation attached.
func TestDecodeForViewRoutesGIF(t *testing.T) {
	im, anim, err := decodeForView(readFixture(t, gifAnimFixture))
	if err != nil {
		t.Fatal(err)
	}
	if anim == nil || len(anim.frames) != 3 {
		t.Fatalf("anim = %v frames, want 3", anim)
	}
	if im.Width != anim.w || im.Height != anim.h || im.Frames != 3 {
		t.Fatalf("shown = %dx%d frames=%d, want %dx%d x3", im.Width, im.Height, im.Frames, anim.w, anim.h)
	}
	sums := map[uint64]int{}
	for i := range anim.frames {
		sums[frameSum(anim.frames[i].pix)] = i
		if anim.frames[i].delayNs != 100_000_000 {
			t.Fatalf("frame %d delay = %d ns, want 100ms (10cs)", i+1, anim.frames[i].delayNs)
		}
	}
	if len(sums) != 3 {
		t.Fatal("anim3_160x120 must composite to three distinct frames")
	}
	im, anim, err = decodeForView(readFixture(t, qoiFixture))
	if err != nil || anim != nil {
		t.Fatalf("QOI: im=%v anim=%v err=%v, want decoded/no-anim", im, anim, err)
	}
}

// TestStepFrameIdxWraps pins the stepper's wrap both ways.
func TestStepFrameIdxWraps(t *testing.T) {
	for _, c := range []struct{ cur, dir, n, want int }{
		{0, 1, 3, 1}, {1, 1, 3, 2}, {2, 1, 3, 0},
		{0, -1, 3, 2}, {2, -1, 3, 1},
		{0, 1, 1, 0}, {0, -1, 1, 0},
		{5, 1, 0, 0},
	} {
		if got := stepFrameIdx(c.cur, c.dir, c.n); got != c.want {
			t.Errorf("stepFrameIdx(%d,%d,%d) = %d, want %d", c.cur, c.dir, c.n, got, c.want)
		}
	}
}

// TestStepFrameShowsTheCompositedFrame: stepping replaces the shown image
// with the frame's own screen-sized composite, wrapping both directions,
// and the keys are inert without an animation.
func TestStepFrameShowsTheCompositedFrame(t *testing.T) {
	im, anim, err := decodeForView(readFixture(t, gifAnimFixture))
	if err != nil {
		t.Fatal(err)
	}
	a := &app{img: im, anim: anim}
	if !a.stepFrame(1) || a.frame != 1 || len(a.img.Pix) != 160*120 {
		t.Fatal("'.' did not land on frame 2")
	}
	if &a.img.Pix[0] != &a.anim.frames[1].pix[0] {
		t.Fatal("the shown image must BE frame 2's composite")
	}
	if !a.stepFrame(1) || a.frame != 2 {
		t.Fatal("'.' did not land on frame 3")
	}
	if !a.stepFrame(1) || a.frame != 0 {
		t.Fatal("'.' at the last frame must wrap to frame 1")
	}
	if !a.stepFrame(-1) || a.frame != 2 {
		t.Fatal("',' at frame 1 must wrap to the last frame")
	}
	a.anim = nil
	if a.stepFrame(1) {
		t.Fatal("a still image must not step")
	}
}

// play10Fixture is the live gate's playback GIF: ten distinct 160x120
// frames at 5 cs each — one 500 ms loop.
const play10Fixture = "testdata/play10_160x120.gif"

// TestPlayDelayNsSchedule pins the arm-time table: the GCE centisecond
// delay verbatim in ns, and the browser convention's 100 ms for a
// zero-delay frame.
func TestPlayDelayNsSchedule(t *testing.T) {
	for _, c := range []struct {
		cs   int
		want uint64
	}{
		{0, 100_000_000}, {5, 50_000_000}, {10, 100_000_000}, {1, 10_000_000},
		{250, 2_500_000_000}, {-3, 100_000_000},
	} {
		if got := playDelayNs(c.cs); got != c.want {
			t.Errorf("playDelayNs(%d) = %d, want %d", c.cs, got, c.want)
		}
	}
}

// TestPlayFixtureIsTenFramesAt50ms keeps the committed play fixture honest:
// the class-B leg's elapsed window (400–1500 ms for one loop) only holds
// while the file stays ten frames at 5 cs.
func TestPlayFixtureIsTenFramesAt50ms(t *testing.T) {
	_, anim, err := decodeForView(readFixture(t, play10Fixture))
	if err != nil {
		t.Fatal(err)
	}
	if anim == nil || len(anim.frames) != 10 {
		t.Fatalf("play fixture = %v frames, want 10", anim)
	}
	sums := map[uint64]int{}
	for i := range anim.frames {
		sums[frameSum(anim.frames[i].pix)] = i
		if anim.frames[i].delayNs != 50_000_000 {
			t.Fatalf("frame %d delay = %d ns, want 50ms (5cs)", i+1, anim.frames[i].delayNs)
		}
	}
	if len(sums) != 10 {
		t.Fatal("play10_160x120 must composite to ten distinct frames")
	}
	if anim.loops != 0 {
		t.Fatalf("play fixture loops = %d, want 0 (loop forever)", anim.loops)
	}
}

// TestPlayTicksDriveTheDelaySchedule is the card's delay-schedule test:
// an injected timer and clock prove each TIMER event advances one frame
// and re-arms that frame's delay, one loop prints the elapsed receipt,
// and a pause cancels the arm and banks its stretch out of the clock.
func TestPlayTicksDriveTheDelaySchedule(t *testing.T) {
	var arms []uint64
	var cancels, clock int64
	oldArm, oldCancel, oldNow := playArm, playCancel, playNow
	playArm = func(ns uint64) int64 { arms = append(arms, ns); return 0 }
	playCancel = func() int64 { cancels++; return 1 }
	playNow = func() int64 { return clock }
	defer func() { playArm, playCancel, playNow = oldArm, oldCancel, oldNow }()

	fire := func() { clock += int64(arms[len(arms)-1]) }

	mkAnim := func(delays ...int) *frameSrc {
		a := &webrender.GIFAnimation{Width: 2, Height: 2}
		for _, d := range delays {
			a.Frames = append(a.Frames, webrender.GIFFrame{Pix: make([]uint32, 4), Delay: d})
		}
		return gifSource(a)
	}

	a := &app{anim: mkAnim(10, 20, 30)} // 100/200/300 ms
	if !a.togglePlay() || !a.playing {
		t.Fatal("togglePlay must start playback on a multi-frame GIF")
	}
	if len(arms) != 1 || arms[0] != 100_000_000 {
		t.Fatalf("first arm = %v, want [100ms]", arms)
	}

	fire()
	if !a.playTick() || a.frame != 1 || arms[len(arms)-1] != 200_000_000 {
		t.Fatalf("tick 1: frame=%d arms=%v", a.frame, arms)
	}
	fire()
	if !a.playTick() || a.frame != 2 || arms[len(arms)-1] != 300_000_000 {
		t.Fatalf("tick 2: frame=%d arms=%v", a.frame, arms)
	}
	// Wrap closes the loop: elapsed is the three delays summed, and the
	// re-arm is frame 1's delay again.
	fire()
	if !a.playTick() || a.frame != 0 {
		t.Fatalf("tick 3 did not wrap: frame=%d", a.frame)
	}
	if a.playLastElapsed != 600_000_000 {
		t.Fatalf("loop elapsed = %d ns, want 600ms", a.playLastElapsed)
	}
	if len(arms) != 4 || arms[3] != 100_000_000 {
		t.Fatalf("post-loop arm = %v, want […, 100ms]", arms)
	}

	// Pause mid-loop: the arm is cancelled, the stretch banks out of the
	// clock, and a stale TIMER event is swallowed without advancing.
	fire()
	a.pausePlay()
	if a.playing || cancels != 1 {
		t.Fatalf("pause: playing=%v cancels=%d", a.playing, cancels)
	}
	banked := a.playAccum
	if a.playTick() || a.frame != 0 {
		t.Fatal("a TIMER event while paused must not advance")
	}
	if len(arms) != 4 {
		t.Fatalf("a stray tick must not re-arm: arms=%v", arms)
	}

	// Resume continues the loop clock — a pause's own stretch does not
	// count toward it. Jump the fake clock seven seconds while paused,
	// then play out the remaining three frames: the loop's elapsed is
	// the banked stretch plus the three delays, the pause invisible.
	clock += 7_000_000_000
	if !a.togglePlay() || !a.playing {
		t.Fatal("space must resume a paused animation")
	}
	if len(arms) != 5 || arms[4] != 100_000_000 {
		t.Fatalf("resume re-arm = %v, want frame 1's 100ms", arms)
	}
	for i := 0; i < 3; i++ {
		fire()
		a.playTick()
	}
	if a.playLastElapsed != banked+600_000_000 {
		t.Fatalf("second loop elapsed = %d ns, want banked+600ms", a.playLastElapsed)
	}
}

// TestTogglePlayIsInertWithoutAnimation: space must do nothing on a still
// image or a single-frame GIF — the same inert-key rule the stepper has.
func TestTogglePlayIsInertWithoutAnimation(t *testing.T) {
	a := &app{}
	if a.togglePlay() {
		t.Fatal("space on a still image must not toggle")
	}
	a.anim = gifSource(&webrender.GIFAnimation{Width: 1, Height: 1,
		Frames: []webrender.GIFFrame{{Pix: make([]uint32, 1), Delay: 5}}})
	if a.togglePlay() {
		t.Fatal("space on a one-frame GIF must not toggle")
	}
}

// TestRequestPlayHonoursReduceMotion is the M177a (#3142) gate: `-play` is
// playback the app starts on its own, so a11y.reduce_motion parks the
// animation on frame 1 — while a pressed space, the user's own request,
// still starts it.
func TestRequestPlayHonoursReduceMotion(t *testing.T) {
	var arms []uint64
	oldArm := playArm
	playArm = func(ns uint64) int64 { arms = append(arms, ns); return 0 }
	defer func() { playArm = oldArm }()

	mkAnim := func() *frameSrc {
		return gifSource(&webrender.GIFAnimation{Width: 2, Height: 2, Frames: []webrender.GIFFrame{
			{Pix: make([]uint32, 4), Delay: 5},
			{Pix: make([]uint32, 4), Delay: 5},
		}})
	}

	// reduce_motion on + -play: parked, nothing armed.
	a := &app{anim: mkAnim(), reduceMotion: true}
	a.requestPlay()
	if a.playing || len(arms) != 0 {
		t.Fatalf("reduce_motion -play: playing=%v arms=%v", a.playing, arms)
	}
	// Space is the user's own request — the gate never applies to it.
	if !a.togglePlay() || !a.playing {
		t.Fatal("space must still start playback under reduce_motion")
	}
	a.pausePlay()

	// reduce_motion off: -play arms like today.
	b := &app{anim: mkAnim()}
	b.requestPlay()
	if !b.playing || len(arms) != 2 {
		t.Fatalf("plain -play: playing=%v arms=%v", b.playing, arms)
	}

	// reduce_motion on a still image: nothing to gate, nothing armed.
	c := &app{reduceMotion: true}
	c.requestPlay()
	if c.playing || len(arms) != 2 {
		t.Fatalf("still image -play: playing=%v arms=%v", c.playing, arms)
	}
}

// TestSettingsApplyKeys pins the three keys GOVIEW subscribes to (M177a
// #3142): theme and a11y.contrast report a repaint through theme.Current,
// a11y.reduce_motion flips only the -play gate, and a foreign or malformed
// notice changes nothing.
func TestSettingsApplyKeys(t *testing.T) {
	savedTheme, savedContrast := theme.Current, theme.Contrast()
	t.Cleanup(func() {
		theme.SetContrast(false)
		theme.Set("dark")
		theme.Current = savedTheme
		theme.SetContrast(savedContrast == "high")
	})
	theme.SetContrast(false)
	theme.Set("dark")

	a := &app{}
	if !a.settingsApply("theme", "light") || theme.Name() != "light" {
		t.Fatal("theme notice did not select light")
	}
	if a.settingsApply("theme", "bogus") || theme.Name() != "light" {
		t.Fatal("an unknown theme name moved the base")
	}
	if !a.settingsApply("a11y.contrast", "high") ||
		theme.Contrast() != "high" || theme.Current != theme.LightHC {
		t.Fatal("contrast notice did not select the HC light table")
	}
	if a.settingsApply("a11y.contrast", "high") {
		t.Fatal("a same-value contrast notice reported a repaint")
	}
	if a.settingsApply("a11y.contrast", "garbage") || theme.Contrast() != "high" {
		t.Fatal("an unparseable contrast notice moved the switch")
	}
	if a.settingsApply("a11y.reduce_motion", "on") || !a.reduceMotion {
		t.Fatal("reduce_motion notice did not arm the gate")
	}
	if a.settingsApply("a11y.reduce_motion", "bogus") || !a.reduceMotion {
		t.Fatal("an unparseable reduce_motion notice moved the gate")
	}
	if a.settingsApply("font_size", "large") {
		t.Fatal("a foreign key reported a repaint")
	}
}
