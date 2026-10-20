// view.go — the M122c (#2572) windowed half of GOINFER.ELF: what a bare
// launch (the launcher's "LLM Infer" row) opens.
//
// The window runs the same journeys the console form does — 's'/Stub runs
// jStub, 'm'/Model runs jModel on the staged VIW — and mirrors every
// goinfer: console line into an on-window log through the viewHost seam
// wrapper, so the licence receipt, the named refusals and the answer are
// visible where the click happened, not only on serial.
//
// The one-session bound is stated, not hidden: OpenCompute maps a fixed-VA
// window a process gets exactly once, so after a journey that opened the
// session the buttons report spent and say to relaunch — a second press
// is refused on the window rather than answered with a kernel EBUSY.
//
// On a window-less boot the bare launch falls back to naming the journeys
// and exits nonzero — the honest headless answer.
package main

import (
	"io"

	uidraw "virelai/draw"
	"virelai/infer"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

const (
	viewTitle = "LLM Infer"
	viewW     = 560
	viewH     = 340

	// viewLogMax bounds the on-window log; older lines scroll off.
	viewLogMax = 12
)

var (
	openViewWindow = tabapp.Init    // seam var, the host-test convention
	viewConsole    = vi.ConsoleLine // the window path's own serial writes
)

// viewHost mirrors the journey's console output into the view's log and
// notes when the process's one compute session has been taken. Every
// other call passes through to the real host unchanged.
type viewHost struct {
	inner  host
	v      *inferView
	opened bool
}

func (w *viewHost) ConsoleLine(s string) {
	w.inner.ConsoleLine(s)
	w.v.say(s)
	w.v.repaint()
}

func (w *viewHost) MkdirShare(p string) error               { return w.inner.MkdirShare(p) }
func (w *viewHost) WriteShareFile(p string, b []byte) error { return w.inner.WriteShareFile(p, b) }
func (w *viewHost) FileExists(p string) bool                { return w.inner.FileExists(p) }
func (w *viewHost) OpenRead(p string) (io.ReadCloser, error) {
	return w.inner.OpenRead(p)
}
func (w *viewHost) OpenComp() (infer.Dev, error) {
	d, err := w.inner.OpenComp()
	if err == nil {
		w.opened = true
	}
	return d, err
}
func (w *viewHost) Nanos() int64         { return w.inner.Nanos() }
func (w *viewHost) SelfMemBytes() uint64 { return w.inner.SelfMemBytes() }

// inferView is the window's state.
type inferView struct {
	ta    *tabapp.TabApp
	h     *viewHost
	lines []string
	busy  bool
}

func newInferView(ta *tabapp.TabApp, inner host) *inferView {
	v := &inferView{ta: ta}
	v.h = &viewHost{inner: inner, v: v}
	v.say("goinfer: window open")
	v.say("goinfer: 's' Stub run (no weights needed) · 'm' Model run (" + modelPath + ")")
	v.say("goinfer: one compute session per process — a run spends it")
	return v
}

// say appends a line to the bounded on-window log.
func (v *inferView) say(s string) {
	v.lines = append(v.lines, s)
	if len(v.lines) > viewLogMax {
		v.lines = v.lines[len(v.lines)-viewLogMax:]
	}
}

// journey runs the named journey through the view's mirrored host. A run
// that consumed the compute session is the last one this process can do —
// the window says so instead of letting the next press die on the kernel's
// refusal.
func (v *inferView) journey(name string) {
	if v.busy {
		return
	}
	if v.h.opened {
		v.say("goinfer: session spent — close and relaunch GOINFER.ELF to run again")
		v.repaint()
		return
	}
	v.busy = true
	_ = run(v.h, []string{name})
	v.busy = false
	if v.h.opened {
		v.say("goinfer: session spent — close and relaunch GOINFER.ELF to run again")
	}
	v.repaint()
}

// key applies one key event; returns whether the window should close.
func (v *inferView) key(ev vi.Event) bool {
	if ev.Arg0 == 0x29 || ev.Arg1 == 0x1b {
		return true
	}
	switch ev.Arg1 {
	case 's', 'S':
		v.journey("stub")
	case 'm', 'M':
		v.journey("model")
	}
	return false
}

// click applies a mouse-down point; a hit on a journey button runs it.
func (v *inferView) click(x, y int) {
	if b := v.stubBtn(); b.HitTest(x, y) {
		v.journey("stub")
	}
	if b := v.modelBtn(); b.HitTest(x, y) {
		v.journey("model")
	}
}

func (v *inferView) stubBtn() widgets.Button {
	return widgets.Button{R: v.scale(widgets.Rect{X: 8, Y: 44, W: 96, H: 24}), Label: "Run stub"}
}

func (v *inferView) modelBtn() widgets.Button {
	return widgets.Button{R: v.scale(widgets.Rect{X: 112, Y: 44, W: 110, H: 24}), Label: "Run model"}
}

// scale maps a native rect into the live canvas, the demo's pattern.
func (v *inferView) scale(r widgets.Rect) widgets.Rect {
	s := v.ta.Layout(tabapp.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}, viewW, viewH)
	return widgets.Rect{X: s.X, Y: s.Y, W: s.W, H: s.H}
}

func (v *inferView) draw() {
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
		Label: "GPU compute journeys — receipts land in " + receiptTSV,
		Fg:    tok.Muted,
		Bg:    tok.Surface,
	}).Draw(cv)
	sb, mb := v.stubBtn(), v.modelBtn()
	sb.Disabled, mb.Disabled = v.busy || v.h.opened, v.busy || v.h.opened
	sb.Draw(cv)
	mb.Draw(cv)
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

// repaint redraws and presents — called from the ConsoleLine mirror so a
// running journey narrates itself live.
func (v *inferView) repaint() {
	v.draw()
	v.ta.Present()
}

// runView is the bare-launch presentation: open, paint, then the event
// loop — keys/buttons run journeys, Esc/WIN_CLOSE exits. Ends on the same
// `goinfer: done` anchor the console journeys print.
func runView() int {
	defer viewConsole("goinfer: done")
	ta := openViewWindow(tabapp.Config{Name: appName, Title: viewTitle, X: 48, Y: 40, W: viewW, H: viewH})
	if ta == nil {
		viewConsole("goinfer: window refused — journeys: GOINFER.ELF stub | model [path]")
		return 1
	}
	viewConsole("goinfer: view open id=" + vi.Itoa64(int64(ta.Win)))
	v := newInferView(ta, guestHost{})
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
			v.repaint()
		case tabapp.ActionNone:
			switch ev.Kind {
			case vi.EvKeyDown:
				if v.key(ev) {
					ta.Close()
					return 0
				}
			case vi.EvMouseDown:
				if ev.Flags&vi.BtnLeft != 0 {
					v.click(int(ev.Arg0), int(ev.Arg1))
				}
			}
		}
	}
}
