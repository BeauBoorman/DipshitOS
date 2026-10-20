// Command gomine is GOMINE.ELF — the M145a (#2796) minesweeper for the
// Go fleet. Three seeded board sizes, first click always safe, left
// reveal (explicit-stack flood fill in engine.go), right flag, chord by
// right-clicking a satisfied number or pressing the second button while
// holding the first. A win raises vi.Notify; save_state keeps the board,
// the elapsed seconds and the seed through tabapp's M125a hooks.
//
// Every marker is printed only AFTER the action it names, so the
// go-games gate's asserts can only pass if the move really happened.
package main

import (
	"virelai/appkit"
	"virelai/draw"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/webrender/font"
	"virelai/widgets"
)

const (
	appName  = "GOMINE.ELF"
	appTitle = "Mines"
	natW     = 720
	natH     = 560
	headerH  = 44

	markerOpen     = "gomine: open id="
	markerDeclare  = "gomine: declare accepted"
	markerRefused  = "gomine: declare refused"
	markerPresent  = "gomine: present"
	markerSeed     = "gomine: seed "
	markerReveal   = "gomine: reveal "
	markerBoom     = "gomine: boom "
	markerFlag     = "gomine: flag "
	markerChord    = "gomine: chord "
	markerWin      = "gomine: win "
	markerNotify   = "gomine: notify "
	markerSaved    = "gomine: state saved len="
	markerRestored = "gomine: state restored "
	markerClose    = "gomine: close"
	markerOK       = "gomine OK"
	markerOpenErr  = "gomine: error open "

	saveVersion = 1
)

// Classic minesweeper number colours on the Surface plate.
var numRGB = [9]uint32{
	0, 0x3b82f6, 0x22c55e, 0xef4444, 0x818cf8,
	0xb91c1c, 0x14b8a6, 0x1f2937, 0x64748b,
}

const (
	cellFace = 0x2d3748 // hidden plate
	cellMine = 0xef4444 // detonated cell
	flagRGB  = 0xf59e0b // flag glyph
)

type app struct {
	ta        *tabapp.TabApp
	board     *Board
	size      int
	cell      int // cell pitch px
	gridX     int // grid origin
	gridY     int
	startedAt int64 // vi.Time() at first reveal; 0 = not started
	now       int64 // last painted elapsed
	headBtns  [4]widgets.Button
}

func loadGuestTheme() {
	b, r := vi.ReadFileAll("/host/SETTINGS.TXT", 2048)
	if r < 0 || b == nil {
		return
	}
	_ = theme.ApplySettings(b)
}

// atoi reads a non-negative decimal from s; ok=false on any junk — an
// arg the gate passes must parse or the app falls back honestly.
func atoi(s string) (int64, bool) {
	if s == "" {
		return 0, false
	}
	var v int64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v*10 + int64(c-'0')
	}
	return v, true
}

func main() {
	loadGuestTheme()
	seed := vi.Time()
	size := 0
	if args := vi.Args(); len(args) > 1 {
		if v, ok := atoi(args[1]); ok {
			seed = v
		}
		if len(args) > 2 {
			if v, ok := atoi(args[2]); ok && v <= 2 {
				size = int(v)
			}
		}
	}

	a := &app{size: size}
	ta := tabapp.Init(tabapp.Config{
		Name:         appName,
		Title:        appTitle,
		X:            32,
		Y:            32,
		W:            natW,
		H:            natH,
		SaveState:    a.saveState,
		RestoreState: a.restoreState,
		StateVersion: saveVersion,
	})
	if ta == nil {
		vi.ConsoleLine(markerOpenErr + "-1")
		vi.Exit(1)
	}
	a.ta = ta
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
	} else {
		vi.ConsoleLine(markerRefused)
	}

	// A restored blob already populated a.board inside Init; only a fresh
	// boot deals a new seeded game.
	if a.board == nil {
		a.newGame(size, seed)
	}

	loop := appkit.NewLoop(a.ta, a.draw, a.handle)
	loop.SubscribeSetting("theme", func(value string) bool {
		return theme.Set(value)
	})
	loop.OnInitialPresent = func() { vi.ConsoleLine(markerPresent) }
	loop.OnExit = func(status int) {
		vi.ConsoleLine(markerClose)
		vi.ConsoleLine(markerOK)
		a.ta.CloseAndExit(status)
	}
	// The save_state ask is mailbox traffic, not an input event: answer it
	// once per pass; the elapsed clock repaints on each new second.
	loop.RunWith(func() (vi.Event, int64, bool) {
		if a.ta.PollStateAsk() {
			vi.ConsoleLine(markerSaved + vi.Itoa64(int64(len(a.saveState()))))
		}
		if a.tickElapsed() {
			loop.Present()
		}
		return vi.PollEventRaw()
	}, vi.Sleep)
}

func (a *app) newGame(size int, seed int64) {
	a.size = size
	a.board = NewBoard(size, seed)
	a.startedAt = 0
	a.now = 0
	vi.ConsoleLine(markerSeed + vi.Itoa64(seed) + " size=" + a.board.Name)
}

// tickElapsed advances the header clock once the first reveal landed.
// Returns true when the painted value changed (the caller repaints).
func (a *app) tickElapsed() bool {
	if a.startedAt == 0 {
		return false
	}
	e := vi.Time() - a.startedAt
	if e < 0 {
		e = 0
	}
	a.board.SetElapsed(e)
	if e == a.now {
		return false
	}
	a.now = e
	return true
}

// The kernel delivers right-button presses as their own ADR 0013 kinds —
// vi names only through EvWinResize, so the constants live here.
const (
	evMouseRightDown uint16 = 11 // events.MOUSE_RIGHT_DOWN
	evMouseRightUp   uint16 = 13 // events.MOUSE_RIGHT_UP
)

func (a *app) handle(ev vi.Event) bool {
	switch ev.Kind {
	case vi.EvKeyDown:
		return a.key(ev)
	case vi.EvMouseDown, evMouseRightDown:
		return a.pointerDown(ev)
	case vi.EvMouseMove, vi.EvMouseUp, evMouseRightUp:
		return false
	}
	return false
}

// cellAt maps a window-local point to a board cell, -1,-1 outside.
func (a *app) cellAt(x, y int) (int, int) {
	b := a.board
	cx := (x - a.gridX) / a.cell
	cy := (y - a.gridY) / a.cell
	if !b.inside(cx, cy) {
		return -1, -1
	}
	return cx, cy
}

func (a *app) pointerDown(ev vi.Event) bool {
	x, y := int(ev.Arg0), int(ev.Arg1)
	left := ev.Kind == vi.EvMouseDown && ev.Flags&vi.BtnLeft != 0
	right := ev.Kind == evMouseRightDown || ev.Flags&vi.BtnRight != 0

	// Header buttons first (they live above the grid).
	if left && a.headerHit(x, y) {
		return true
	}
	cx, cy := a.cellAt(x, y)
	if cx < 0 {
		return false
	}
	b := a.board
	switch {
	case left && right:
		// The true both-buttons chord: the second press arrives with
		// the first button still held in the flags bitmask.
		return a.doChord(cx, cy)
	case right:
		if b.Revealed(cx, cy) {
			// Right-click on a satisfied number is the chord shortcut —
			// the gate's `rc` step reaches the same code path as the
			// both-buttons gesture.
			return a.doChord(cx, cy)
		}
		return a.doFlag(cx, cy)
	case left:
		return a.doReveal(cx, cy)
	}
	return false
}

func (a *app) headerHit(x, y int) bool {
	for i := range a.headBtns {
		b := &a.headBtns[i]
		if b.R.Empty() || !b.HitTest(x, y) {
			continue
		}
		switch i {
		case 3: // New
			a.newGame(a.size, vi.Time())
			return true
		default:
			a.newGame(i, vi.Time())
			return true
		}
	}
	return false
}

func (a *app) key(ev vi.Event) bool {
	if ev.Flags&vi.ModCtrl != 0 {
		return false
	}
	switch ev.Arg1 {
	case 'n', 'N':
		a.newGame(a.size, vi.Time())
		return true
	case '1':
		a.newGame(0, vi.Time())
		return true
	case '2':
		a.newGame(1, vi.Time())
		return true
	case '3':
		a.newGame(2, vi.Time())
		return true
	}
	return false
}

func (a *app) doReveal(x, y int) bool {
	b := a.board
	n, boom := b.Reveal(x, y)
	if n == 0 && !boom {
		return false
	}
	if a.startedAt == 0 && b.Started() {
		a.startedAt = vi.Time()
	}
	vi.ConsoleLine(markerReveal + vi.Itoa64(int64(x)) + "," + vi.Itoa64(int64(y)) +
		" n=" + vi.Itoa64(int64(n)))
	if boom {
		vi.ConsoleLine(markerBoom + vi.Itoa64(int64(x)) + "," + vi.Itoa64(int64(y)))
		return true
	}
	if b.Won() {
		a.onWin()
	}
	return true
}

func (a *app) doFlag(x, y int) bool {
	_, on := a.board.ToggleFlag(x, y)
	state := " off"
	if on {
		state = " on"
	}
	vi.ConsoleLine(markerFlag + vi.Itoa64(int64(x)) + "," + vi.Itoa64(int64(y)) + state)
	return true
}

func (a *app) doChord(x, y int) bool {
	n, boom := a.board.Chord(x, y)
	if n == 0 && !boom {
		return false
	}
	vi.ConsoleLine(markerChord + vi.Itoa64(int64(x)) + "," + vi.Itoa64(int64(y)) +
		" n=" + vi.Itoa64(int64(n)))
	if boom {
		vi.ConsoleLine(markerBoom + vi.Itoa64(int64(x)) + "," + vi.Itoa64(int64(y)))
		return true
	}
	if a.board.Won() {
		a.onWin()
	}
	return true
}

func (a *app) onWin() {
	vi.ConsoleLine(markerWin + "t=" + vi.Itoa64(a.board.Elapsed()))
	if a.ta.Notify("Mines cleared") {
		vi.ConsoleLine(markerNotify + "ok")
	} else {
		vi.ConsoleLine(markerNotify + "refused")
	}
}

// --- save_state ------------------------------------------------------------

func (a *app) saveState() []byte { return a.board.Save() }

func (a *app) restoreState(blob []byte) {
	b, ok := LoadSave(blob)
	if !ok {
		return
	}
	a.board = b
	a.size = b.sizeIndex()
	if b.State() == statePlaying || b.State() == stateWon || b.State() == stateDead {
		a.startedAt = vi.Time() - b.Elapsed()
	}
	a.now = -1
	vi.ConsoleLine(markerRestored + "size=" + b.Name +
		" rev=" + vi.Itoa64(int64(b.RevealedN())))
}

// --- draw -----------------------------------------------------------------

func (a *app) draw() {
	cv := a.ta.Canvas()
	if cv == nil {
		return
	}
	tok := theme.Current
	b := a.board

	cv.FillRect(widgets.Rect{W: int(a.ta.W), H: int(a.ta.H)}, draw.Opaque(tabapp.FillRGB()))

	// Header: mine counter | size buttons + New | elapsed.
	cv.FillRect(widgets.Rect{X: 0, Y: 0, W: int(a.ta.W), H: headerH}, draw.Opaque(tok.Surface))
	counter := "M " + vi.Itoa64(int64(b.MineLeft()))
	if b.Dead() {
		counter += " X"
	} else if b.Won() {
		counter += " W"
	}
	drawText(cv, widgets.Rect{X: tok.PadMD, Y: 8, W: 150, H: 28}, counter, tok.Ink)
	drawText(cv, widgets.Rect{X: int(a.ta.W) - 150 - tok.PadMD, Y: 8, W: 150, H: 28},
		"T "+vi.Itoa64(a.board.Elapsed()), tok.Ink)

	labels := [4]string{"9x9", "16x16", "30x16", "New"}
	bx := 190
	for i := range a.headBtns {
		w := 52
		if i == 3 {
			w = 60
		}
		a.headBtns[i] = widgets.Button{
			R:     widgets.Rect{X: bx, Y: 8, W: w, H: 28},
			Label: labels[i],
		}
		a.headBtns[i].Draw(cv)
		bx += w + tok.PadSM
	}

	// Grid geometry: cells sized to the window, centred.
	availW := int(a.ta.W) - 2*tok.PadMD
	availH := int(a.ta.H) - headerH - 2*tok.PadMD
	cs := availW / b.Cols
	if h := availH / b.Rows; h < cs {
		cs = h
	}
	if cs > 28 {
		cs = 28
	}
	if cs < 8 {
		cs = 8
	}
	a.cell = cs
	a.gridX = (int(a.ta.W) - b.Cols*cs) / 2
	a.gridY = headerH + (availH-b.Rows*cs)/2 + tok.PadMD

	for y := 0; y < b.Rows; y++ {
		for x := 0; x < b.Cols; x++ {
			a.drawCell(cv, x, y)
		}
	}
}

func (a *app) drawCell(cv widgets.Canvas, x, y int) {
	b := a.board
	tok := theme.Current
	r := widgets.Rect{X: a.gridX + x*a.cell + 1, Y: a.gridY + y*a.cell + 1, W: a.cell - 2, H: a.cell - 2}
	switch {
	case b.Revealed(x, y) && b.Mine(x, y):
		cv.FillRect(r, draw.Opaque(cellMine))
		a.cellGlyph(cv, r, "*", 0x111827)
	case b.Revealed(x, y):
		cv.FillRect(r, draw.Opaque(tok.Surface))
		if n := b.Adj(x, y); n > 0 {
			a.cellGlyph(cv, r, string('0'+byte(n)), numRGB[n])
		}
	case b.Dead() && b.Mine(x, y):
		// A lost board shows every mine.
		cv.FillRect(r, draw.Opaque(cellFace))
		a.cellGlyph(cv, r, "*", flagRGB)
	case b.Flagged(x, y):
		cv.FillRect(r, draw.Opaque(cellFace))
		a.cellGlyph(cv, r, "F", flagRGB)
	default:
		cv.FillRect(r, draw.Opaque(cellFace))
		cv.FillRect(widgets.Rect{X: r.X, Y: r.Y, W: r.W, H: 2}, draw.Opaque(tok.Border))
	}
}

// cellGlyph paints one centred 8x8 bitmap glyph in r.
func (a *app) cellGlyph(cv widgets.Canvas, r widgets.Rect, s string, rgb uint32) {
	g := font.Glyph8([]rune(s)[0])
	gw := 8
	x := r.X + (r.W-gw)/2
	y := r.Y + (r.H-8)/2
	for row := 0; row < 8; row++ {
		bits := g[row]
		for col := 0; col < 8; col++ {
			if bits&(1<<uint(col)) != 0 {
				cv.FillRect(widgets.Rect{X: x + col, Y: y + row, W: 1, H: 1}, draw.Opaque(rgb))
			}
		}
	}
}

// drawText paints a left-anchored bitmap line inside r.
func drawText(cv widgets.Canvas, r widgets.Rect, s string, rgb uint32) {
	widgets.DrawText(cv, r, s, draw.Opaque(rgb))
}
