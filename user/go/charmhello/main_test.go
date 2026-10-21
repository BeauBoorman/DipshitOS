//go:build virelai || charmhello

package main

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"

	"virelai/tabapp"
)

func TestModelTogglesFromTeaKeyPress(t *testing.T) {
	next, _ := (model{}).Update(tea.KeyPressMsg(tea.Key{Text: " "}))
	got := next.(model)
	if !got.paused {
		t.Fatal("space did not toggle the Bubble Tea model")
	}
	if !strings.Contains(got.View().Content, "PAUSED") {
		t.Fatal("paused model view did not render the paused state")
	}
}

func TestModelQuitsFromTeaKeyPress(t *testing.T) {
	next, cmd := (model{}).Update(tea.KeyPressMsg(tea.Key{Text: "q"}))
	if !next.(model).quit {
		t.Fatal("q did not request model shutdown")
	}
	if cmd == nil || cmd() != (tea.QuitMsg{}) {
		t.Fatal("q did not return tea.Quit — the Program must end itself")
	}
}

func TestViewCarriesBoundedAnsiSurface(t *testing.T) {
	v := (model{}).View()
	for _, want := range []string{"\x1b[1;95m", "bound /dev/tty"} {
		if !strings.Contains(v.Content, want) {
			t.Fatalf("view missing %q", want)
		}
	}
	// The renderer owns the modes now: alt-screen and ?1002/?1006 mouse
	// reporting are View fields, not literal escapes in Content.
	if !v.AltScreen {
		t.Fatal("view does not request the alt screen")
	}
	if v.MouseMode != tea.MouseModeCellMotion {
		t.Fatal("view does not request cell-motion mouse reporting")
	}
}

// TestSizeMsgPinsKernelCellMath is M73j's (#1636) deliverable-4 agreement
// pin, moved to its M168a (#2957) owner: teatty answers term.GetSize and
// WIN_RESIZE through tabapp.CellGrid — cols = clamp(w/cellW, 8, 80)
// (terminal.zig syncWindowCols -> setCols:975) and rows = (h-16)/cellH
// (driving_award.zig rows_visible:439, title_bar_h=16). M73l (#1661):
// cellW=8, cellH=16 — FiraCode's advance at pixel size 13. M80i (#1725):
// the pin runs at EVERY rung of the zoom ladder (7x13 / 8x16 / 10x21).
func TestSizeMsgPinsKernelCellMath(t *testing.T) {
	rects := []struct{ w, h uint32 }{
		{640, 400},  // charmhello's own rect: 640/8, (400-16)/16
		{512, 384},  // the 512px tab: 512/8, (384-16)/16
		{128, 64},   // the resize clamp floor: 128/8, (64-16)/16
		{1024, 720}, // cols clamp: 1024/8=128 -> 80 (setCols)
		{48, 40},    // cols clamp low: 48/8=6 -> 8 (setCols)
		{64, 16},    // no client area: kernel's `else 1` branch
	}
	rungs := []struct {
		name         string
		cellW, cellH uint32
		want         [][2]int // cols, rows per rect
	}{
		{"small 7x13", 7, 13, [][2]int{
			{80, 29}, {73, 28}, {18, 3}, {80, 54}, {8, 1}, {9, 1},
		}},
		{"medium 8x16 (the boot look)", 8, 16, [][2]int{
			{80, 24}, {64, 23}, {16, 3}, {80, 44}, {8, 1}, {8, 1},
		}},
		{"large 10x21", 10, 21, [][2]int{
			{64, 18}, {51, 17}, {12, 2}, {80, 33}, {8, 1}, {8, 1},
		}},
	}
	for _, r := range rungs {
		for i, rc := range rects {
			c, rows := tabapp.CellGrid(rc.w, rc.h, r.cellW, r.cellH)
			if c != r.want[i][0] || rows != r.want[i][1] {
				t.Errorf("CellGrid(%d,%d,%d,%d) = %dx%d, want %dx%d (kernel formulas, %s)",
					rc.w, rc.h, r.cellW, r.cellH, c, rows, r.want[i][0], r.want[i][1], r.name)
			}
		}
	}
}

// TestUpdateHandlesWindowSize: the message shape Update consumes — stored
// on the model and rendered in the View, so the serial marker and the
// scanout both carry it. The Program's own initial-size path sends it.
func TestUpdateHandlesWindowSize(t *testing.T) {
	next, _ := (model{}).Update(tea.WindowSizeMsg{Width: 80, Height: 48})
	got := next.(model)
	if got.cols != 80 || got.rows != 48 {
		t.Fatalf("size stored = %dx%d, want 80x48", got.cols, got.rows)
	}
	if !strings.Contains(got.View().Content, "80x48") {
		t.Fatal("view does not render the size line")
	}
}

// TestResizeConvergesToLatest is the consumer half of deliverable 1's
// coalesce measure: the kernel queue is 16-slot drop-oldest (events.zig
// push), so under a rapid drag the app may see a pruned subsequence —
// pass-all application in arrival order must end at the LAST size.
func TestResizeConvergesToLatest(t *testing.T) {
	m := model{}
	m.sized = true // as the Program's initial size already landed
	for _, ws := range []tea.WindowSizeMsg{
		{Width: 80, Height: 24},
		{Width: 88, Height: 27},
		{Width: 96, Height: 30},
	} {
		next, _ := m.Update(ws)
		m = next.(model)
	}
	if m.cols != 96 || m.rows != 30 {
		t.Fatalf("converged size = %dx%d, want 96x30 (the latest)", m.cols, m.rows)
	}
}

// TestMouseMarkersReconstructSGR pins the marker field math: the kernel
// sends press as ESC[<b;x;yM and release/drag as ESC[<32+b;x;ym
// (terminal.zig encodeMouse — bit 5 is the legacy Cb+32 convention),
// while tea's Mouse carries X11 codes (left=1) and 0-based cells.
func TestMouseMarkersReconstructSGR(t *testing.T) {
	if got := mouseLine(0, 4, 2); got != "charmhello: mouse b=0 x=4 y=2" {
		t.Fatalf("press marker = %q", got)
	}
	if got := mouseLine(32, 4, 2); got != "charmhello: mouse b=32 x=4 y=2" {
		t.Fatalf("release marker = %q", got)
	}
	// Update must map Click(left, cell 3,1 0-based) -> b=0 x=4 y=2 and
	// the motion-decoded release -> b=32 (ultraviolet reads the kernel's
	// +32 as the motion bit; see Update's MouseMotionMsg case).
	for _, msg := range []tea.Msg{
		tea.MouseClickMsg(tea.Mouse{X: 3, Y: 1, Button: tea.MouseLeft}),
		tea.MouseMotionMsg(tea.Mouse{X: 3, Y: 1, Button: tea.MouseLeft}),
		tea.MouseReleaseMsg(tea.Mouse{X: 3, Y: 1, Button: tea.MouseLeft}),
	} {
		if _, cmd := (model{}).Update(msg); cmd != nil {
			t.Fatalf("mouse msg %T returned a cmd — markers are synchronous", msg)
		}
	}
}
