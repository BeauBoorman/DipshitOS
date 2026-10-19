package main

import (
	"testing"

	"virelai/chords"
	"virelai/draw"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
)

// The card's bar: exactly five gestures and the four named launchers.
func TestTourTables(t *testing.T) {
	gs := gestures()
	if len(gs) != 5 {
		t.Fatalf("gestures = %d, want 5", len(gs))
	}
	for i, g := range gs {
		if g.keys == "" || g.text == "" {
			t.Fatalf("gesture %d has an empty side: %+v", i, g)
		}
	}
	// The chord chips are spelled from the seat's own registry — pin the
	// spellings the tour teaches so a re-homed chord is a deliberate edit,
	// not drift.
	wantKeys := []string{"CLICK", "CTRL+SPACE", "CTRL+TAB", "DRAG", "CTRL+SHIFT+P"}
	for i, want := range wantKeys {
		if gs[i].keys != want {
			t.Fatalf("gesture %d chip = %q, want %q", i, gs[i].keys, want)
		}
	}
	// And the spellings still resolve against the live registry: a seat row
	// losing its binding would empty the chip rather than lie.
	for _, want := range []struct {
		action string
		chord  chords.Chord
	}{
		{"launcher", chords.Chord{Mods: chords.ModCtrl, Usage: chords.UsageSpace}},
		{"cycle-focus", chords.Chord{Mods: chords.ModCtrl, Usage: chords.UsageTab}},
		{"palette", chords.Chord{Mods: chords.ModCtrl | chords.ModShift, Usage: chords.UsageP}},
	} {
		if seatChord(want.action, want.chord) == "" {
			t.Fatalf("seatChord(%q) resolved empty — the registry lost the row", want.action)
		}
	}

	if len(launchers) != 4 {
		t.Fatalf("launchers = %d, want 4", len(launchers))
	}
	wantBins := []string{"GOSET.ELF", "GOFILES.ELF", "GOSTORE.ELF", "GOTERM.ELF"}
	wantLabels := []string{"Settings", "Files", "Store", "Terminal"}
	for i := range launchers {
		if launchers[i].bin != wantBins[i] || launchers[i].label != wantLabels[i] {
			t.Fatalf("launcher %d = %+v, want %s %s", i, launchers[i], wantLabels[i], wantBins[i])
		}
	}
}

func TestDigitLaunch(t *testing.T) {
	for ch := uint32('1'); ch <= '4'; ch++ {
		if got := digitLaunch(ch); got != int(ch-'1') {
			t.Fatalf("digitLaunch(%c) = %d", ch, got)
		}
	}
	for _, ch := range []uint32{'0', '5', 'a', ' '} {
		if digitLaunch(ch) != -1 {
			t.Fatalf("digitLaunch(%c) did not refuse", ch)
		}
	}
}

func TestFootText(t *testing.T) {
	m := newTour()
	if got := m.footText(); got != "1-4 launch · esc closes · reopen from the launcher" {
		t.Fatalf("idle foot = %q", got)
	}
	m.launched = "GOTERM.ELF"
	if got := m.footText(); got != "started GOTERM.ELF — find its tab on the rail" {
		t.Fatalf("launched foot = %q", got)
	}
	m.launched, m.failed = "", "GOSET.ELF"
	if got := m.footText(); got != "could not start GOSET.ELF" {
		t.Fatalf("failed foot = %q", got)
	}
}

// Click routes: a point inside button i fires launcher i; outside fires
// nothing. The rects come from the same layout the paint used — no
// duplicated geometry.
func TestLauncherHitTest(t *testing.T) {
	a := &app{ta: &tabapp.TabApp{W: natW, H: natH}, m: newTour()}
	a.layout()
	rects := a.launchRects()
	if len(rects) != 4 {
		t.Fatalf("launchRects = %d", len(rects))
	}
	for i, r := range rects {
		if got := a.m.launcherAt(rects, r.X+r.W/2, r.Y+r.H/2); got != i {
			t.Fatalf("centre of button %d hit %d", i, got)
		}
	}
	if got := a.m.launcherAt(rects, 4, 4); got != -1 {
		t.Fatalf("outside point hit launcher %d", got)
	}
	// The gap between two adjacent buttons is dead space.
	mid := rects[0]
	if got := a.m.launcherAt(rects, mid.X+mid.W+1, mid.Y+mid.H/2); got != -1 {
		t.Fatalf("gap point hit launcher %d", got)
	}
}

// The click path end to end: a left-down inside a button execs its bin via
// the seam; hover alone fires nothing.
func TestPointerLaunchesThroughExecSeam(t *testing.T) {
	var execs []string
	old := execBin
	execBin = func(name string, args ...string) (int64, error) {
		execs = append(execs, name)
		return 42, nil
	}
	defer func() { execBin = old }()

	a := &app{ta: &tabapp.TabApp{W: natW, H: natH}, m: newTour()}
	a.layout()
	r := a.launchRects()[3] // Terminal
	// Hover first: no exec, but the hover state repaints.
	if !a.pointer(vi.Event{Kind: vi.EvMouseMove, Arg0: uint32(r.X + r.W/2), Arg1: uint32(r.Y + r.H/2)}) {
		t.Fatal("hover over a launcher did not repaint")
	}
	if len(execs) != 0 {
		t.Fatalf("hover exec'd %v", execs)
	}
	a.pointer(vi.Event{Kind: vi.EvMouseDown, Flags: vi.BtnLeft, Arg0: uint32(r.X + r.W/2), Arg1: uint32(r.Y + r.H/2)})
	if len(execs) != 1 || execs[0] != "GOTERM.ELF" {
		t.Fatalf("click exec'd %v, want GOTERM.ELF", execs)
	}
	if a.m.launched != "GOTERM.ELF" {
		t.Fatalf("launched = %q", a.m.launched)
	}
	// A click in the dead zone launches nothing.
	a.pointer(vi.Event{Kind: vi.EvMouseDown, Flags: vi.BtnLeft, Arg0: 4, Arg1: 4})
	if len(execs) != 1 {
		t.Fatalf("dead-zone click exec'd %v", execs)
	}
}

func TestKeyLaunchAndQuit(t *testing.T) {
	var execs []string
	old := execBin
	execBin = func(name string, args ...string) (int64, error) {
		execs = append(execs, name)
		return 7, nil
	}
	defer func() { execBin = old }()

	a := &app{ta: &tabapp.TabApp{W: natW, H: natH}, m: newTour()}
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg1: '2'})
	if len(execs) != 1 || execs[0] != "GOFILES.ELF" {
		t.Fatalf("'2' exec'd %v, want GOFILES.ELF", execs)
	}
	// A ctrl-modified digit is the seat's chord space, not the tour's.
	a.key(vi.Event{Kind: vi.EvKeyDown, Flags: vi.ModCtrl, Arg1: '3'})
	if len(execs) != 1 {
		t.Fatalf("ctrl+digit leaked a launch: %v", execs)
	}
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyEscape})
	if !a.m.quit {
		t.Fatal("escape did not latch quit")
	}
}

// The render leg: the frame's plates land where layout put them, in the
// theme's own colours, and glyph runs paint ink inside them.
func TestWelcomeFramePaints(t *testing.T) {
	a := &app{ta: &tabapp.TabApp{W: natW, H: natH}, m: newTour()}
	c := &draw.BufferCanvas{Pix: make([]uint32, natW*natH), W: natW, H: natH}
	a.paintCanvas(c)

	px := func(x, y int) uint32 { return c.Pix[y*c.W+x] }

	if got := px(1, natH-2); got != op(theme.Current.Bg) {
		t.Fatalf("backdrop = %#x, want opaque Bg %#x", got, op(theme.Current.Bg))
	}
	// A gesture chip carries the accent plate.
	chip := a.chips[0].R
	if got := px(chip.X+chip.W/2, chip.Y+chip.H/2); got != op(theme.Current.Accent) {
		t.Fatalf("gesture chip = %#x, want accent %#x", got, op(theme.Current.Accent))
	}
	// A description row carries the surface plate.
	desc := a.descs[0].R
	if got := px(desc.X+desc.W-4, desc.Y+4); got != op(theme.Current.Surface) {
		t.Fatalf("desc plate = %#x, want surface %#x", got, op(theme.Current.Surface))
	}
	// A launcher button: border around an idle face.
	btn := a.buttons[0].R
	if got := px(btn.X+4, btn.Y+4); got != op(theme.Current.BtnIdle) {
		t.Fatalf("button face = %#x, want idle %#x", got, op(theme.Current.BtnIdle))
	}
	// Text ran: something inside the canvas is the label ink.
	ink := 0
	for _, p := range c.Pix {
		if p == op(theme.Current.Text) || p == op(theme.Current.OnAccent) || p == op(theme.Current.Muted) {
			ink++
		}
	}
	if ink < 200 {
		t.Fatalf("only %d label-ink pixels — the tour's text did not paint", ink)
	}
}

// Hover repaints the button face — the pointer feedback a one-click
// launcher owes the user.
func TestHoverRepaintsButton(t *testing.T) {
	a := &app{ta: &tabapp.TabApp{W: natW, H: natH}, m: newTour()}
	c := &draw.BufferCanvas{Pix: make([]uint32, natW*natH), W: natW, H: natH}
	a.paintCanvas(c)

	r := a.launchRects()[0]
	a.pointer(vi.Event{Kind: vi.EvMouseMove, Arg0: uint32(r.X + r.W/2), Arg1: uint32(r.Y + r.H/2)})
	a.paintCanvas(c)
	if got := c.Pix[(r.Y+4)*c.W+r.X+4]; got != op(theme.Current.BtnHover) {
		t.Fatalf("hovered face = %#x, want hover %#x", got, op(theme.Current.BtnHover))
	}
}

func op(rgb uint32) uint32 { return rgb | 0xff000000 }
