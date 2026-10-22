// view.go — the M122c (#2572) windowed half of GOREC.ELF: what a bare
// launch (the launcher's "Recorder" row) opens.
//
// The view is the same recorder, honestly presented: the capture tuple the
// kernel answered, a Record button (or 'r') that runs the shared record()
// pipeline for viewSeconds into viewPath, and a log carrying the same
// gorec: lines the headless form prints — the console tee means the window
// shows every word serial gets, including the named refusals (ENXIO no
// capture source, ETIMEDOUT mic-denied, the write refusals). A record that
// cannot happen is shown, never faked.
//
// On a window-less boot (win_open refused: no seat, serial console) the
// bare launch falls back to the usage line and status 2 — a headless
// caller gets the honest text the CLI form expects.
package main

import (
	uidraw "virelai/draw"
	"virelai/pcm"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

const (
	viewTitle = "Recorder"
	viewW     = 480
	viewH     = 320

	// viewSeconds is the fixed clip the Record gesture takes — short
	// enough that the window is only briefly busy, long enough to be a
	// real recording. The CLI form still takes any 1..pcm.MaxRecordSeconds.
	viewSeconds = 5

	// viewPath is the fixed clip path the gesture publishes (overwritten
	// per record — WriteFileSafe, never an in-place truncate). The CLI
	// form keeps the caller's path.
	viewPath = "/host/GOREC/CLIP.WAV"

	// viewLogMax bounds the on-window log; older lines scroll off.
	viewLogMax = 10
)

var openViewWindow = tabapp.Init // seam, the seam-var convention this file's package already uses

// view is the window's state: the bound tab, the capability line, the log
// and the in-flight record flag (the capture loop blocks, so a second
// gesture while one runs is refused on the window itself).
type view struct {
	ta      *tabapp.TabApp
	capLine string
	lines   []string
	busy    bool
}

func newView(ta *tabapp.TabApp) *view {
	v := &view{ta: ta}
	info, err := capQuery()
	if err != nil {
		v.capLine = "capture query refused: " + err.Error()
	} else {
		v.capLine = "capture ready=" + vi.Itoa64(int64(info.Ready)) +
			" fmt=" + vi.Itoa64(int64(info.Format)) +
			" rate=" + vi.Itoa64(int64(info.Rate)) +
			" ch=" + vi.Itoa64(int64(info.Channels)) +
			" ring=" + vi.Itoa64(int64(info.RingBytes))
	}
	v.say("gorec: window open")
	v.say("gorec: 'r' or Record captures " + vi.Itoa64(viewSeconds) + " s to " + viewPath)
	return v
}

// say appends a line to the bounded on-window log.
func (v *view) say(s string) {
	v.lines = append(v.lines, s)
	if len(v.lines) > viewLogMax {
		v.lines = v.lines[len(v.lines)-viewLogMax:]
	}
}

// record runs the shared pipeline with the console tee'd into the log: a
// repaint per line keeps the window live while the bounded ring loop
// blocks between calls.
func (v *view) record() {
	if v.busy {
		return
	}
	v.busy = true
	old := console
	console = func(s string) {
		old(s)
		v.say(s)
		v.draw()
		v.ta.Present()
	}
	rc := record(viewSeconds, viewPath)
	console = old
	v.busy = false
	if rc == 0 {
		v.say("gorec: clip ready — play it back with Sound")
	}
}

// key applies one key event; 'r'/'R' records, Esc (usage 0x29 / char
// 0x1b, the appkit code) asks to close. Returns whether the close was
// requested.
func (v *view) key(ev vi.Event) bool {
	if ev.Arg0 == 0x29 || ev.Arg1 == 0x1b {
		return true
	}
	if ev.Arg1 == 'r' || ev.Arg1 == 'R' {
		v.record()
	}
	return false
}

// click applies a mouse-down point; a hit on the Record button records.
func (v *view) click(x, y int) {
	if b := v.recordBtn(); b.HitTest(x, y) {
		v.record()
	}
}

// recordBtn is the button's rect in the CURRENT canvas (the layout is
// native-sized and scaled, so the hit test and the draw agree).
func (v *view) recordBtn() widgets.Button {
	return widgets.Button{R: v.scale(widgets.Rect{X: 8, Y: 44, W: 96, H: 24}), Label: "Record"}
}

// scale maps a native rect into the live canvas, the demo's pattern.
func (v *view) scale(r widgets.Rect) widgets.Rect {
	s := v.ta.Layout(tabapp.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}, viewW, viewH)
	return widgets.Rect{X: s.X, Y: s.Y, W: s.W, H: s.H}
}

func (v *view) draw() {
	cv := v.ta.Canvas()
	tok := theme.Current
	cv.FillRect(widgets.Rect{W: int(v.ta.W), H: int(v.ta.H)}, uidraw.Opaque(tabapp.FillRGB()))
	(&widgets.Text{
		R:     v.scale(widgets.Rect{X: 8, Y: 8, W: viewW - 16, H: 18}),
		Label: viewTitle,
		Fg:    tok.Text,
		Bg:    tok.Surface,
	}).Draw(cv)
	(&widgets.Text{
		R:     v.scale(widgets.Rect{X: 8, Y: 26, W: viewW - 16, H: 14}),
		Label: v.capLine,
		Fg:    tok.Muted,
		Bg:    tok.Surface,
	}).Draw(cv)
	btn := v.recordBtn()
	btn.Disabled = v.busy
	btn.Draw(cv)
	(&widgets.List{
		R:     v.scale(widgets.Rect{X: 8, Y: 76, W: viewW - 16, H: viewH - 84}),
		Items: v.lines,
		RowH:  18,
		Sel:   -1,
		Fg:    tok.Ink,
		Bg:    tok.ChromeBg,
		SelBg: tok.Selection,
	}).Draw(cv)
}

// runView is the bare-launch presentation: open, paint, then the event
// loop — 'r'/button records, Esc/WIN_CLOSE exits. Ends on `gorec: done`,
// the same terminal anchor the headless form prints.
func runView() int {
	defer console("gorec: done")
	ta := openViewWindow(tabapp.Config{Name: "GOREC.ELF", Title: viewTitle, X: 48, Y: 40, W: viewW, H: viewH})
	if ta == nil {
		console("gorec: window refused — headless use: GOREC.ELF <seconds 1.." +
			vi.Itoa64(int64(pcm.MaxRecordSeconds)) + "> <out.wav under /host or /disk>")
		return 2
	}
	console("gorec: view open id=" + vi.Itoa64(int64(ta.Win)))
	v := newView(ta)
	v.draw()
	ta.Present()
	for {
		ev, r, ok := vi.PollEventRaw()
		if !ok {
			if r < 0 {
				return 0
			}
			vi.Sleep(1)
			continue
		}
		switch ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			ta.Close()
			return 0
		case tabapp.ActionResized:
			v.draw()
			ta.Present()
		case tabapp.ActionNone:
			repaint := false
			switch ev.Kind {
			case vi.EvKeyDown:
				if v.key(ev) {
					ta.Close()
					return 0
				}
				repaint = true
			case vi.EvMouseDown:
				if ev.Flags&vi.BtnLeft != 0 {
					v.click(int(ev.Arg0), int(ev.Arg1))
					repaint = true
				}
			}
			if repaint && !v.busy {
				v.draw()
				ta.Present()
			}
		}
	}
}
