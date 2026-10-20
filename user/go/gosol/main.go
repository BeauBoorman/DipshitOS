// Command gosol is GOSOL.ELF — M145b (issue #2797): Klondike solitaire,
// the M145 games arc's second app. Draw-1 or draw-3, a seeded deal, an
// in-surface pointer drag that validates its drop and snaps back when the
// move is illegal, a double-click that sends a card to its foundation, a
// 32-step undo, a vi.Notify on the win, and a save_state blob that keeps
// the full table.
//
// Argv (the M145c scripted legs drive these): --seed=N fixes the deal,
// --draw=3 starts in draw-3. Inside, 'n' reseals a fresh deal, 'd' toggles
// the draw mode, 'u' is the undo key alongside the seat's ctrl+z route.
//
// Marker discipline is the fleet's: every `gosol:` line is printed only
// after the frame it describes is presented, so a spec that waits on one
// can never race the paint.
package main

import (
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
)

const (
	appName  = "GOSOL.ELF"
	appTitle = "Solitaire"
	natW     = 512
	natH     = 384
)

// Marker vocabulary. `gosol: ready` is the paint barrier the scripted legs
// release input on; the move/drop/dbl lines name what the state machine
// decided.
const (
	markerOpen        = "gosol: open id="
	markerTabAware    = "gosol: tab-aware (full-viewport)"
	markerNotTabAware = "gosol: not-tab-aware (shim or WND desktop)"
	markerOpenErr     = "gosol: error open "
	markerDeal        = "gosol: deal seed="
	markerRestored    = "gosol: restored moves="
	markerRestoreRef  = "gosol: restore refused "
	markerReady       = "gosol: ready"
	markerUndo        = "gosol: undo depth="
	markerDrawMode    = "gosol: draw-mode "
	markerWin         = "gosol: win moves="
	markerNotify      = "gosol: notify win"
	markerNotifyNo    = "gosol: notify-refused win"
	markerStateSave   = "gosol: state save len="
	markerResize      = "gosol: resize relayout"
	markerClose       = "gosol: win_close"
	markerExiting     = "gosol: exiting "
)

// app is the running session: the tab shell, the board (game + pointer
// machine), and the frame counter the close path reports.
type app struct {
	ta       *tabapp.TabApp
	b        board
	presents int
}

// parseArgv reads --seed=N and --draw=1|3. An absent seed asks the kernel
// CSPRNG — the deal is still recorded and named, just not reproducible.
func parseArgv() (seed uint64, drawN int) {
	drawN = 1
	args := vi.Args()
	for _, a := range args {
		if len(a) > 7 && a[:7] == "--seed=" {
			seed = atou64(a[7:])
		}
		if len(a) > 7 && a[:7] == "--draw=" {
			if v := atoi(a[7:]); v == 1 || v == 3 {
				drawN = v
			}
		}
	}
	return seed, drawN
}

// freshSeed answers a new deal seed: eight CSPRNG bytes when the kernel
// offers them, the previous seed stepped once when it does not (the host
// test path) — a fresh deal either way, never a silent repeat.
func freshSeed(prev uint64) uint64 {
	var p [8]byte
	if n, err := vi.Random(p[:]); err == nil && n == 8 {
		return getU64(p[:])
	}
	return prev + 1
}

// atoi/atou64 are the package's small decimal readers — no strconv for the
// same image-budget reason the rest of the fleet gives.
func atoi(s string) int {
	v, _ := atoi2(s)
	return v
}

func atou64(s string) uint64 {
	_, u := atoi2(s)
	return u
}

func atoi2(s string) (int, uint64) {
	var u uint64
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			break
		}
		u = u*10 + uint64(s[i]-'0')
	}
	return int(u), u
}

// paint draws and presents one frame, counting it for the close report.
func (a *app) paint() {
	if a.ta == nil {
		return
	}
	w, h := int(a.ta.W), int(a.ta.H)
	if w <= 0 || h <= 0 {
		w, h = natW, natH
	}
	a.b.draw(a.ta.Canvas(), w, h)
	a.ta.Present()
	a.presents++
}

// applyEff is the post-paint barrier for one pointer/key outcome: the
// frame lands first, then the marker names what the frame shows. A win
// rides the same barrier — the toast is raised after the table that shows
// it exists.
func (a *app) applyEff(e eff) {
	if e.dirty {
		a.paint()
	}
	if e.win {
		vi.ConsoleLine(markerWin + itoa(a.b.g.moves))
		if a.ta.Notify("Solitaire: you win!") {
			vi.ConsoleLine(markerNotify)
		} else {
			vi.ConsoleLine(markerNotifyNo)
		}
	}
	if e.note != "" {
		vi.ConsoleLine("gosol: " + e.note)
	}
}

// deal replaces the table and clears the pointer machine's gesture state —
// a new deal mid-drag cannot keep flying cards from a game that no longer
// exists.
func (a *app) deal(seed uint64, drawN int) {
	a.b = board{g: newGame(seed, drawN)}
	vi.ConsoleLine(markerDeal + uitoa(seed) + " draw=" + itoa(drawN))
}

// undo answers both the seat's ctrl+z route (tabapp.ActionUndo) and the
// app's own 'u' key — one method, one marker.
func (a *app) undo() {
	if a.b.g.Undo() {
		// The restored snapshot carries its own won bit; winSent follows it
		// so an undo past the win lets a re-won table toast again, while an
		// undo landing on a won table keeps it quiet.
		a.b.winSent = a.b.g.won
		// A gesture armed against the pre-undo table is dead — the source
		// index may not even exist in the restored pile.
		a.b.on, a.b.arm = false, false
		a.paint()
		vi.ConsoleLine(markerUndo + itoa(a.b.g.undoDepth()))
	}
}

// key handles one key event. Only 'n', 'd' and 'u' are this app's; every
// other key belongs to the seat.
func (a *app) key(ev vi.Event) {
	switch ev.Arg1 {
	case 'n':
		seed := freshSeed(a.b.g.seed)
		a.deal(seed, a.b.g.draw)
		a.paint()
	case 'd':
		d := 1
		if a.b.g.draw == 1 {
			d = 3
		}
		a.b.g.draw = d
		a.paint()
		vi.ConsoleLine(markerDrawMode + itoa(d))
	case 'u':
		a.undo()
	}
}

// pointer routes one mouse event into the board's state machine and lands
// its outcome through the paint barrier.
func (a *app) pointer(ev vi.Event) {
	x, y := int(ev.Arg0), int(ev.Arg1)
	var e eff
	switch ev.Kind {
	case vi.EvMouseDown:
		if ev.Flags&vi.BtnLeft == 0 {
			return
		}
		e = a.b.down(x, y)
	case vi.EvMouseMove:
		e = a.b.movePtr(x, y)
	case vi.EvMouseUp:
		if ev.Flags&vi.BtnLeft == 0 {
			return
		}
		e = a.b.up(x, y)
	default:
		return
	}
	a.applyEff(e)
}

func loadGuestTheme() {
	b, r := vi.ReadFileAll("/host/SETTINGS.TXT", 2048)
	if r < 0 || b == nil {
		return
	}
	_ = theme.ApplySettings(b)
}

func main() {
	loadGuestTheme()
	seed, drawN := parseArgv()
	if seed == 0 {
		seed = freshSeed(0)
	}

	a := &app{}
	var restored *Game
	restoredOK := false
	ta := tabapp.Init(tabapp.Config{
		Name: appName, Title: appTitle, X: 32, Y: 32, W: natW, H: natH,
		StateVersion: stateFmtVer,
		SaveState:    func() []byte { return a.b.g.encodeState() },
		RestoreState: func(b []byte) {
			restored, restoredOK = decodeState(b)
		},
		HandleUndo: func() bool {
			a.undo()
			return true
		},
	})
	if ta == nil {
		vi.ConsoleLine(markerOpenErr + "-1")
		vi.Exit(1)
	}
	a.ta = ta
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerTabAware)
	} else {
		vi.ConsoleLine(markerNotTabAware)
	}

	// A stored table beats a fresh deal: the blob carries its own seed and
	// draw mode, so the restore applies as-is and the deal marker is only
	// printed for a genuinely new table.
	if ta.Restored && ta.RestoredVersion == stateFmtVer && restoredOK {
		a.b.g = restored
		vi.ConsoleLine(markerRestored + itoa(restored.moves))
	} else {
		if ta.Restored {
			vi.ConsoleLine(markerRestoreRef + "ver=" +
				vi.Itoa64(int64(ta.RestoredVersion)))
		}
		a.deal(seed, drawN)
	}

	a.paint()
	vi.ConsoleLine(markerReady)

	for {
		// The seat's save ask is mailbox traffic, not an input event —
		// answer it once per pass, marker on the acked handoff only.
		if ta.PollStateAsk() {
			vi.ConsoleLine(markerStateSave + itoa(len(a.b.g.encodeState())))
		}
		ev, r, ok := vi.PollEventRaw()
		if !ok {
			if r < 0 {
				break
			}
			vi.Sleep(1)
			continue
		}
		switch ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			vi.ConsoleLine(markerClose)
			vi.ConsoleLine("gosol: presents n=" + itoa(a.presents))
			vi.ConsoleLine(markerExiting + vi.Itoa64(0))
			ta.CloseAndExit(0)
		case tabapp.ActionResized:
			a.paint()
			vi.ConsoleLine(markerResize)
		case tabapp.ActionUndo:
			a.undo()
		case tabapp.ActionNone:
			switch ev.Kind {
			case vi.EvMouseDown, vi.EvMouseMove, vi.EvMouseUp:
				a.pointer(ev)
			case vi.EvKeyDown:
				a.key(ev)
			}
		}
	}
	ta.CloseAndExit(0)
}
