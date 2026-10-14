// Command demo is a small live adopter of the appkit dialog. Its only surface
// is an owned Seam-B window buffer; the chrome is painted by Dialog.Draw, not
// a second gate-only rasterizer. Below the dialog it is also the M104d (#2271)
// showcase: the four controls — scrollbar, toggle, slider, dropdown — painted
// through the same draw.BufferCanvas path their consumers will use.
package main

import (
	"virelai/appkit"
	"virelai/draw"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

// Leave the kernel's argv/envp tail out of the runtime's first sbrk page.
var argvHeadroom [0x1000]byte

func main() {
	const w, h = 512, 448
	id, rc := vi.WinOpen(56, 56, w, h)
	if rc < 0 {
		vi.ConsoleLine("godialog: open failed")
		vi.Exit(1)
	}
	c, err := draw.WindowCanvas(id, w, h)
	if err != nil {
		vi.ConsoleLine("godialog: surface failed")
		vi.WinClose(id)
		vi.Exit(2)
	}
	// A tab attachment keeps the requested native geometry: the window's
	// bound surface must not be resized independently of its mapped bytes.
	_ = vi.WmMailRequest(vi.WmRpcKindAttachTab, uint32(id), 0, 0, 0, 0, "Dialog", "GODIALOG.ELF")
	d := appkit.NewPrompt("Open file", "Enter a path to open")
	d.Input = "notes.txt"
	d.UIFace, err = draw.ReadFont("/host/INTER.TTF", 500000)
	if err != nil {
		vi.ConsoleLine("godialog: fonts missing")
		vi.WinClose(id)
		vi.Exit(3)
	}
	d.IconFace, err = draw.ReadFont("/host/CHROME.TTF", 8192)
	if err != nil {
		vi.ConsoleLine("godialog: fonts missing")
		vi.WinClose(id)
		vi.Exit(3)
	}

	// The M104d showcase. Each control sits where its forcing consumer
	// would put it: a scrolled list with its scrollbar (logview), on/off
	// toggles (goset), a value slider (sound), and an open vocab dropdown
	// (goset's multi-valued rows) — the popover is the FillShadow+PushClip
	// surface.
	list := &widgets.List{
		R:     widgets.Rect{X: 8, Y: 72, W: 64, H: 156},
		Items: []string{"boot", "seat", "wm", "net", "fs", "gpu", "hid", "snd"},
		RowH:  24, Sel: 3, ScrollTop: 2,
		Fg: theme.Current.Text, Bg: theme.Current.ChromeBg, Face: d.UIFace,
	}
	bar := &widgets.Scrollbar{
		R:     widgets.Rect{X: 76, Y: 72, W: widgets.ScrollbarW, H: 156},
		Total: len(list.Items), Viewport: list.VisibleRows(), Offset: list.ScrollTop,
	}
	togs := []*widgets.Toggle{
		{R: widgets.Rect{X: 424, Y: 92, W: widgets.ToggleW, H: widgets.ToggleH}, On: true},
		{R: widgets.Rect{X: 424, Y: 136, W: widgets.ToggleW, H: widgets.ToggleH}},
		{R: widgets.Rect{X: 424, Y: 180, W: widgets.ToggleW, H: widgets.ToggleH}, On: true, Disabled: true},
	}
	togLabels := []*widgets.Text{
		{R: widgets.Rect{X: 424, Y: 74, W: 80, H: 16}, Label: "shadow", Fg: theme.Current.Muted, Bg: theme.Current.Bg, Face: d.UIFace},
		{R: widgets.Rect{X: 424, Y: 118, W: 80, H: 16}, Label: "dnd", Fg: theme.Current.Muted, Bg: theme.Current.Bg, Face: d.UIFace},
		{R: widgets.Rect{X: 424, Y: 162, W: 80, H: 16}, Label: "init", Fg: theme.Current.Muted, Bg: theme.Current.Bg, Face: d.UIFace},
	}
	slider := &widgets.Slider{
		R: widgets.Rect{X: 168, Y: 252, W: 200, H: 20}, Max: 100, Value: 40,
	}
	sliderLabel := &widgets.Text{
		R: widgets.Rect{X: 96, Y: 252, W: 64, H: 20}, Label: "volume",
		Fg: theme.Current.Muted, Bg: theme.Current.Bg, Face: d.UIFace,
	}
	sliderValue := &widgets.Text{
		R: widgets.Rect{X: 376, Y: 252, W: 36, H: 20}, Label: "40",
		Fg: theme.Current.Text, Bg: theme.Current.Bg, Face: d.UIFace,
	}
	dd := &appkit.Dropdown{
		R:        widgets.Rect{X: 168, Y: 288, W: 180, H: 24},
		Items:    []string{"tabbed", "floating", "grid", "stack", "monocle"},
		Sel:      1,
		Open:     true,
		MaxRows:  4,
		UIFace:   d.UIFace,
		IconFace: d.IconFace,
	}
	ddLabel := &widgets.Text{
		R: widgets.Rect{X: 96, Y: 292, W: 68, H: 20}, Label: "wm",
		Fg: theme.Current.Muted, Bg: theme.Current.Bg, Face: d.UIFace,
	}

	for ticks := 0; ticks < 30 && d.Open; ticks++ {
		draw.FillRect(c, widgets.Rect{W: w, H: h}, draw.Opaque(theme.Current.Bg))
		d.Draw(c)
		list.Draw(c)
		bar.Draw(c)
		for i, t := range togs {
			togLabels[i].Draw(c)
			t.Draw(c)
		}
		sliderLabel.Draw(c)
		slider.Draw(c)
		sliderValue.Draw(c)
		ddLabel.Draw(c)
		dd.Draw(c)
		if vi.WinPresent(id) < 0 {
			vi.ConsoleLine("godialog: present failed")
			vi.WinClose(id)
			vi.Exit(4)
		}
		if ticks == 0 {
			vi.ConsoleLine("godialog: painted")
		}
		if ev, ok := vi.PollEvent(); ok {
			if ev.Kind == vi.EvWinClose {
				break
			}
			d.HandleKey(ev)
			d.HandleMouse(int(ev.Arg0), int(ev.Arg1), ev.Kind == vi.EvMouseDown)
			if ev.Kind == vi.EvMouseDown {
				x, y := int(ev.Arg0), int(ev.Arg1)
				switch {
				case dd.HitTest(x, y):
					dd.OnClick(x, y)
				case slider.HitTest(x, y):
					slider.Value = slider.ValueAt(x)
				case bar.HitTest(x, y):
					list.ScrollTop += bar.PageAt(x, y) * list.VisibleRows()
					if list.ScrollTop < 0 {
						list.ScrollTop = 0
					}
					bar.Offset = list.ScrollTop
				default:
					for _, t := range togs {
						if t.HitTest(x, y) && !t.Disabled {
							t.On = !t.On
						}
					}
				}
			}
		}
		vi.Sleep(1)
	}
	vi.WinClose(id)
	vi.ConsoleLine("godialog: done")
}
