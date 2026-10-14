// Command demo is the M56d (issue #1315) demo Go app: one Go tab, full
// viewport inside Zig TABWM. It opens a window, best-effort declares itself
// tab-aware, draws three widgets (scaled into whatever canvas it is given),
// presents, relayouts on every WIN_RESIZE with a redraw, and closes cleanly.
//
// Every marker below is printed only AFTER its syscall returned, so the
// go-tabapp VZ gate's asserts can only pass if the app actually ran.
package main

import (
	uidraw "virelai/draw"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

const (
	appName  = "GOTABAPP.ELF"
	appTitle = "GoTabApp"
	natW     = 512
	natH     = 340
)

func main() {
	ta := tabapp.Init(tabapp.Config{Name: appName, Title: appTitle, X: 32, Y: 32, W: natW, H: natH})
	if ta == nil {
		vi.ConsoleLine("gotabapp: error open -1")
		vi.Exit(1)
	}
	vi.ConsoleLine("gotabapp: open id=" + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine("gotabapp: declare accepted")
	} else {
		vi.ConsoleLine("gotabapp: declare refused")
	}
	draw(ta)
	vi.ConsoleLine("gotabapp: draw")
	ta.Present()
	vi.ConsoleLine("gotabapp: present")

	for {
		ev, r, ok := vi.PollEventRaw()
		if !ok {
			if r < 0 {
				// Kernel refusal: no point spinning.
				break
			}
			vi.Sleep(1)
			continue
		}
		switch ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			vi.ConsoleLine("gotabapp: close")
			vi.ConsoleLine("gotabapp OK")
			ta.CloseAndExit(0)
		case tabapp.ActionResized:
			vi.ConsoleLine("gotabapp: resize " + vi.Itoa64(int64(ta.W)) + "x" + vi.Itoa64(int64(ta.H)))
			draw(ta)
			ta.Present()
		case tabapp.ActionNone:
		}
	}
}

// draw paints a full-viewport frame using the three widgets, mapping a fixed
// native layout (natW x natH) into the app's CURRENT canvas via tabapp.Scale.
func draw(ta *tabapp.TabApp) {
	cv := ta.Canvas()
	// Clear the whole canvas.
	tok := theme.Current
	cv.FillRect(widgets.Rect{W: int(ta.W), H: int(ta.H)}, uidraw.Opaque(tabapp.FillRGB()))
	title := &widgets.Text{
		R:     scaleR(ta, widgets.Rect{X: tok.PadMD, Y: tok.PadMD, W: int(natW) - 2*tok.PadMD, H: 20}),
		Label: appTitle,
		Fg:    tok.Text,
		Bg:    tok.Surface,
	}
	title.Draw(cv)

	btn := &widgets.Button{
		R:     scaleR(ta, widgets.Rect{X: tok.PadMD, Y: int(natH) - 44, W: 96, H: 28}),
		Label: "Close",
	}
	btn.Draw(cv)

	list := &widgets.List{
		R:     scaleR(ta, widgets.Rect{X: tok.PadMD, Y: 36, W: int(natW) - 2*tok.PadMD, H: int(natH) - 88}),
		Items: []string{"alpha", "beta", "gamma"},
		RowH:  22,
		Sel:   0,
		Fg:    tok.Ink,
		Bg:    tok.ChromeBg,
		SelBg: tok.Selection,
	}
	list.Draw(cv)
}

// scaleR maps a native-canvas widget rect into the app's current canvas.
func scaleR(ta *tabapp.TabApp, r widgets.Rect) widgets.Rect {
	s := ta.Layout(tabapp.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}, natW, natH)
	return widgets.Rect{X: s.X, Y: s.Y, W: s.W, H: s.H}
}
