// Command welcome is GOWELCOME.ELF: the M122b (issue #2571) first-boot
// welcome tour — five core gestures and one-click launchers on a tabapp
// canvas. main.go owns the shell: tabapp lifecycle, the exec seam the
// launcher buttons ride, the event loop and the serial markers. tour.go
// holds the pure model the host tests pin.
//
// Every marker below is printed only AFTER its syscall returned, so the
// go-wm-default seat legs' asserts can only pass if the app actually ran.
package main

import (
	"virelai/appkit"
	"virelai/draw"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

const (
	appName  = "GOWELCOME.ELF"
	appTitle = "Welcome"
	natW     = 512
	natH     = 384

	markerOpen       = "gowelcome: open id="
	markerDeclare    = "gowelcome: declare accepted"
	markerRefused    = "gowelcome: declare refused"
	markerPresent    = "gowelcome: present"
	markerReady      = "gowelcome: ready"
	markerLaunch     = "gowelcome: launch "
	markerLaunchFail = "gowelcome: launch fail "
	markerResized    = "gowelcome: resized "
	markerClose      = "gowelcome: close"
	markerOK         = "gowelcome OK"
	markerOpenErr    = "gowelcome: error open "

	keyEscape = 0x29
)

// execBin is the launch seam — vi.Exec in the guest, a stub in host tests
// (the execApp pattern in gotabwm's hid.go: bypassing vi's syscall hook
// keeps the click -> pid route observable).
var execBin = vi.Exec

type app struct {
	ta      *tabapp.TabApp
	m       tour
	title   widgets.Text
	sub     widgets.Text
	chips   []widgets.Text
	descs   []widgets.Text
	head    widgets.Text
	buttons []widgets.Button
	foot    widgets.Text
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

	ta := tabapp.Init(tabapp.Config{Name: appName, Title: appTitle, X: 32, Y: 32, W: natW, H: natH})
	if ta == nil {
		vi.ConsoleLine(markerOpenErr + "-1")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
	} else {
		vi.ConsoleLine(markerRefused)
	}

	a := &app{ta: ta, m: newTour()}
	loop := appkit.NewLoop(a.ta, a.draw, a.handle)
	loop.SubscribeSetting("theme", func(value string) bool {
		return theme.Set(value)
	})
	loop.ShouldQuit = func() (int, bool) { return 0, a.m.quit }
	loop.OnInitialPresent = func() {
		vi.ConsoleLine(markerPresent)
		vi.ConsoleLine(markerReady)
	}
	loop.OnExit = func(status int) {
		vi.ConsoleLine(markerClose)
		vi.ConsoleLine(markerOK)
		a.ta.CloseAndExit(status)
	}
	loop.Run()
}

func (a *app) handle(ev vi.Event) bool {
	switch ev.Kind {
	case vi.EvKeyDown:
		return a.key(ev)
	case vi.EvMouseMove, vi.EvMouseUp, vi.EvMouseDown:
		return a.pointer(ev)
	}
	return false
}

// pointer runs the launcher row: hover tracking on every motion, a left
// press lights the button and fires the one-click launch — there is no
// separate confirm step.
func (a *app) pointer(ev vi.Event) bool {
	x, y := int(ev.Arg0), int(ev.Arg1)
	down := ev.Kind == vi.EvMouseDown && ev.Flags&vi.BtnLeft != 0
	changed := false
	hit := a.m.launcherAt(a.launchRects(), x, y)
	for i := range a.buttons {
		if a.buttons[i].Hovered != (i == hit) {
			a.buttons[i].Hovered = i == hit
			changed = true
		}
		p := down && i == hit
		if a.buttons[i].Pressed != p {
			a.buttons[i].Pressed = p
			changed = true
		}
	}
	if down && hit >= 0 {
		return a.launch(hit) || true
	}
	return changed
}

// key: digits 1-4 fire the matching launcher; Escape or q closes the tour.
// A chord the seat owns (ctrl-*) never reaches here — the mod guard keeps
// the routing honest anyway.
func (a *app) key(ev vi.Event) bool {
	if ev.Kind != vi.EvKeyDown {
		return false
	}
	if ev.Flags&vi.ModCtrl != 0 {
		return false
	}
	if ev.Arg0 == keyEscape {
		a.m.quit = true
		return false
	}
	if i := digitLaunch(ev.Arg1); i >= 0 {
		return a.launch(i)
	}
	if ev.Arg1 == 'q' || ev.Arg1 == 'Q' {
		a.m.quit = true
	}
	return false
}

// launch execs one launcher's bin and records the outcome for the status
// line. The marker prints only after the syscall answered — a refused exec
// is its own honest line, never a silent no-op.
func (a *app) launch(i int) bool {
	if i < 0 || i >= len(launchers) {
		return false
	}
	l := launchers[i]
	pid, err := execBin(l.bin)
	if err != nil || pid <= 0 {
		a.m.failed = l.bin
		a.m.launched = ""
		vi.ConsoleLine(markerLaunchFail + l.bin)
		return true
	}
	a.m.launched = l.bin
	a.m.failed = ""
	vi.ConsoleLine(markerLaunch + l.bin)
	return true
}

// launchRects is the launchers' live-canvas geometry — the click path's
// copy of what layout() last painted.
func (a *app) launchRects() []rect {
	out := make([]rect, len(a.buttons))
	for i := range a.buttons {
		r := a.buttons[i].R
		out[i] = rect{X: r.X, Y: r.Y, W: r.W, H: r.H}
	}
	return out
}

func (a *app) layout() {
	ta := a.ta
	tok := theme.Current
	sc := func(r widgets.Rect) widgets.Rect {
		s := ta.Layout(tabapp.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}, natW, natH)
		return widgets.Rect{X: s.X, Y: s.Y, W: s.W, H: s.H}
	}

	pad := 12
	full := natW - 2*pad
	a.title = widgets.Text{
		R:     sc(widgets.Rect{X: pad, Y: 10, W: full, H: 24}),
		Label: "Welcome to VirelaiOS",
		Fg:    tok.Text, Bg: tok.Surface,
	}
	a.sub = widgets.Text{
		R:     sc(widgets.Rect{X: pad, Y: 38, W: full, H: 16}),
		Label: "Five gestures for the first hour",
		Fg:    tok.Muted, Bg: tok.Surface,
	}

	rows := gestures()
	if len(a.chips) != len(rows) {
		a.chips = make([]widgets.Text, len(rows))
		a.descs = make([]widgets.Text, len(rows))
	}
	const chipW = 118
	for i, g := range rows {
		y := 66 + i*44
		a.chips[i] = widgets.Text{
			R:     sc(widgets.Rect{X: pad, Y: y, W: chipW, H: 38}),
			Label: g.keys,
			Fg:    tok.OnAccent, Bg: tok.Accent,
		}
		a.descs[i] = widgets.Text{
			R:     sc(widgets.Rect{X: pad + chipW + 8, Y: y, W: full - chipW - 8, H: 38}),
			Label: g.text,
			Fg:    tok.Text, Bg: tok.Surface,
		}
	}

	a.head = widgets.Text{
		R:     sc(widgets.Rect{X: pad, Y: 288, W: full, H: 16}),
		Label: "Get started — one click opens it:",
		Fg:    tok.Muted, Bg: tok.Surface,
	}

	if len(a.buttons) != len(launchers) {
		a.buttons = make([]widgets.Button, len(launchers))
	}
	const gap = 8
	btnW := (full - (len(launchers)-1)*gap) / len(launchers)
	for i, l := range launchers {
		a.buttons[i] = widgets.Button{
			R:       sc(widgets.Rect{X: pad + i*(btnW+gap), Y: 308, W: btnW, H: 48}),
			Label:   l.label,
			Hovered: a.buttons[i].Hovered,
			Pressed: a.buttons[i].Pressed,
		}
	}

	a.foot = widgets.Text{
		R:     sc(widgets.Rect{X: pad, Y: 362, W: full, H: 16}),
		Label: a.m.footText(),
		Fg:    tok.Muted, Bg: tok.Surface,
	}
}

func (a *app) draw() {
	a.paintCanvas(a.ta.Canvas())
}

// paintCanvas renders the laid-out tour onto cv — split from draw so the
// host tests can pin the painted surface on a BufferCanvas without a bound
// window (the calc golden's pattern: Canvas() on the host is the
// FillerCanvas degrade, not the chrome this app paints in the guest).
func (a *app) paintCanvas(cv widgets.Canvas) {
	if cv == nil {
		return
	}
	a.layout()
	cv.FillRect(widgets.Rect{W: int(a.ta.W), H: int(a.ta.H)}, draw.Opaque(tabapp.FillRGB()))
	a.title.Draw(cv)
	a.sub.Draw(cv)
	for i := range a.chips {
		a.chips[i].Draw(cv)
		a.descs[i].Draw(cv)
	}
	a.head.Draw(cv)
	for i := range a.buttons {
		a.buttons[i].Draw(cv)
	}
	a.foot.Draw(cv)
}
