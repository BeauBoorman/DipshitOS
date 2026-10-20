package tabapp

import (
	"errors"
	"testing"

	"virelai/draw"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

// On the host every vi call degrades, so Init reports the honest failure
// rather than fabricating a window.
func TestFillRGBIsThemeBg(t *testing.T) {
	if FillRGB() != theme.Current.Bg {
		t.Fatalf("FillRGB %#x want %#x", FillRGB(), theme.Current.Bg)
	}
}

func TestInitHostFails(t *testing.T) {
	if ta := Init(Config{Name: "T.ELF", Title: "T", W: 100, H: 100}); ta != nil {
		t.Fatalf("host Init = %+v want nil", ta)
	}
}

func TestDispatchTracksCanvas(t *testing.T) {
	ta := &TabApp{Win: 4, W: 512, H: 340}
	if a := ta.Dispatch(vi.Event{Kind: vi.EvMouseDown}); a != ActionNone {
		t.Fatalf("mouse action = %v", a)
	}
	if a := ta.Dispatch(vi.Event{Kind: vi.EvWinResize, Arg0: 1100, Arg1: 720}); a != ActionResized {
		t.Fatalf("resize action = %v", a)
	}
	if ta.W != 1100 || ta.H != 720 {
		t.Fatalf("canvas not tracked: %d x %d", ta.W, ta.H)
	}
	if a := ta.Dispatch(vi.Event{Kind: vi.EvWinClose}); a != ActionClosed {
		t.Fatalf("close action = %v", a)
	}
}

func TestSetTabTitleHostRefuses(t *testing.T) {
	ta := &TabApp{Win: 4, Name: "NOTE.ELF"}
	if ta.SetTabTitle("notes.txt") {
		t.Fatal("host tab title request must refuse without a WM seat")
	}
}

// M79k (#1720): Notify is the same best-effort contract as SetTabTitle —
// no seat, no request, no ack, so false. An app that cannot tell the
// difference between "the user was told" and "nobody heard" would print a
// marker claiming a toast that is not on the screen.
func TestNotifyHostRefuses(t *testing.T) {
	ta := &TabApp{Win: 4, Name: "NOTE.ELF"}
	if ta.Notify("copied notes.txt") {
		t.Fatal("host notify must refuse without a WM seat")
	}
	if ta.Notify("") {
		t.Fatal("an empty notify must refuse before the mailbox")
	}
}

// Scale is the identity at the native canvas — the zero-regression fixed point.
func TestScaleIdentity(t *testing.T) {
	r := Rect{8, 104, 56, 20}
	if got := Scale(r, 512, 340, 512, 340); got != r {
		t.Fatalf("identity scale changed %+v -> %+v", r, got)
	}
}

func TestScaleMapsProportionally(t *testing.T) {
	r := Rect{8, 104, 56, 20}
	got := Scale(r, 512, 340, 1100, 720)
	if got.X != 8*1100/512 || got.Y != 104*720/340 || got.W != 56*1100/512 || got.H != 20*720/340 {
		t.Fatalf("scale = %+v", got)
	}
	if got.X+got.W > 1100 || got.Y+got.H > 720 {
		t.Fatalf("content spills the canvas: %+v", got)
	}
	// Never zero-size.
	tiny := Scale(Rect{0, 0, 1, 1}, 512, 340, 1100, 720)
	if tiny.W < 1 || tiny.H < 1 {
		t.Fatalf("zero-size scaled rect: %+v", tiny)
	}
}

func TestLayoutTracksCanvas(t *testing.T) {
	ta := &TabApp{W: 1100, H: 720}
	got := ta.Layout(Rect{8, 104, 56, 20}, 512, 340)
	if got.X+got.W > 1100 || got.Y+got.H > 720 {
		t.Fatalf("layout spills: %+v", got)
	}
}

// stubSurface replaces the kernel bind for one test and returns the shared
// page slice every call records against.
func stubSurface(t *testing.T, fail bool) (*[][2]int, []byte) {
	t.Helper()
	calls := new([][2]int)
	surf := make([]byte, vi.ScanoutFbBytes)
	orig := mmapWindowSurface
	mmapWindowSurface = func(win, size int) ([]byte, error) {
		*calls = append(*calls, [2]int{win, size})
		if fail {
			return nil, errors.New("ENOSYS")
		}
		return surf, nil
	}
	t.Cleanup(func() { mmapWindowSurface = orig })
	return calls, surf
}

// Attach performs the same one-time bind Init does — observable on the host
// because Attach does not gate on WinOpen.
func TestAttachBindsScanoutSurfaceOnce(t *testing.T) {
	calls, _ := stubSurface(t, false)
	ta := Attach(7, "T.ELF", 320, 200)
	if len(*calls) != 1 || (*calls)[0] != [2]int{7, vi.ScanoutFbBytes} {
		t.Fatalf("bind calls = %v want one scanout bind on win 7", *calls)
	}
	bc, ok := ta.Canvas().(*draw.BufferCanvas)
	if !ok || bc.W != 320 || bc.H != 200 {
		t.Fatalf("canvas = %#v want *draw.BufferCanvas 320x200", ta.Canvas())
	}
	// One bind is the lifetime contract: WIN_RESIZE re-views, never re-mmaps.
	if a := ta.Dispatch(vi.Event{Kind: vi.EvWinResize, Arg0: 640, Arg1: 400}); a != ActionResized {
		t.Fatalf("resize action = %v", a)
	}
	if len(*calls) != 1 {
		t.Fatalf("resize re-mmapped the surface: %v calls", *calls)
	}
	bc, ok = ta.Canvas().(*draw.BufferCanvas)
	if !ok || bc.W != 640 || bc.H != 400 {
		t.Fatalf("post-resize canvas = %#v want 640x400 BufferCanvas", ta.Canvas())
	}
}

// The review half of reflow's reframe contract: a resize keeps each
// surviving row's bytes at the new stride. Grow relocates bottom-up, shrink
// top-down — either way the top-left overlap is identical before repaint.
func TestReviewPreservesOverlap(t *testing.T) {
	_, _ = stubSurface(t, false)
	ta := Attach(7, "T.ELF", 2, 2)
	for i := 0; i < 2*2*4; i++ {
		ta.surf[i] = byte(i + 1)
	}
	// Grow 2x2 -> 4x2: each row moves to the 16-byte stride.
	ta.Dispatch(vi.Event{Kind: vi.EvWinResize, Arg0: 4, Arg1: 2})
	for i := 0; i < 8; i++ {
		if ta.surf[i] != byte(i+1) || ta.surf[16+i] != byte(i+9) {
			t.Fatalf("grow clobbered overlap: %v", ta.surf[:24])
		}
	}
	// Rebind determinism: repeat the pattern under the wider view, then
	// shrink 4x2 -> 2x2 — the left half of each row survives.
	for i := 0; i < 4*2*4; i++ {
		ta.surf[i] = byte(i + 1)
	}
	ta.Dispatch(vi.Event{Kind: vi.EvWinResize, Arg0: 2, Arg1: 2})
	for i := 0; i < 8; i++ {
		if ta.surf[i] != byte(i+1) || ta.surf[8+i] != byte(i+17) {
			t.Fatalf("shrink clobbered overlap: %v", ta.surf[:16])
		}
	}
}

// The degrade contract: a refused bind (and a hand-built TabApp, what the
// app host tests construct) paints through FillerCanvas, never panics.
func TestCanvasDegradesWhenBindRefused(t *testing.T) {
	_, _ = stubSurface(t, true)
	ta := Attach(7, "T.ELF", 320, 200)
	fc, ok := ta.Canvas().(*draw.FillerCanvas)
	if !ok || fc.WindowID != 7 {
		t.Fatalf("degrade canvas = %#v want *draw.FillerCanvas win 7", ta.Canvas())
	}
	ta.Canvas().FillRect(widgets.Rect{W: 10, H: 10}, 0xFF112233)
	ta.Present()

	manual := &TabApp{Win: 4, W: 512, H: 340}
	if _, ok := manual.Canvas().(*draw.FillerCanvas); !ok {
		t.Fatalf("manual TabApp canvas = %#v want FillerCanvas degrade", manual.Canvas())
	}
}

// M121e (#2568): Dispatch classifies plain ctrl+z as ActionUndo — the
// seat's chord routed to this tab — while shifted/alted spellings stay
// the app's own keys (ctrl-shift-z is redo territory).
func TestDispatchUndoChord(t *testing.T) {
	ta := &TabApp{Win: 1, W: 100, H: 100}
	if a := ta.Dispatch(vi.Event{Kind: vi.EvKeyDown, Flags: vi.ModCtrl, Arg0: 0x1d}); a != ActionUndo {
		t.Fatalf("ctrl+z dispatch = %v want ActionUndo", a)
	}
	for _, f := range []uint16{vi.ModCtrl | vi.ModShift, vi.ModCtrl | vi.ModAlt, 0, vi.ModShift} {
		if a := ta.Dispatch(vi.Event{Kind: vi.EvKeyDown, Flags: f, Arg0: 0x1d}); a != ActionNone {
			t.Fatalf("z with flags %#x dispatch = %v want ActionNone", f, a)
		}
	}
	// The hook is the no-op default: a consumed chord, nothing reverted.
	if ta.Undo() {
		t.Fatal("nil HandleUndo must no-op")
	}
	ran := 0
	ta.HandleUndo = func() bool { ran++; return true }
	if !ta.Undo() || ran != 1 {
		t.Fatalf("HandleUndo must run once and report, ran=%d", ran)
	}
}
