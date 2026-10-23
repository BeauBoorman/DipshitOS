// Command logview is LOGVIEW.ELF — the live app-log tail: it polls the
// bounded per-app ring files under /host/APPLOG (vi.AppLogNames +
// vi.ReadLog; each producer owns its own ring) and shows what apps are
// logging now, in
// first-observed order, with level/tag/grep/app filters, a follow-tail
// window, and a bounded /host/LOGEXPORT snapshot on E.
//
// Why I'm separate (the #3189 diagnostics census, docs/diagnostics.md):
// this is the only surface over the LIVE ring data — crashview reads
// frozen post-mortem receipt files, GOTOP reads point-in-time kernel
// snapshots, observe arms a session on one target. The question it
// answers is "what did app X just log", not "what died" or "what is
// running".
package main

import (
	"strings"
	"time"

	"virelai/appkit"
	"virelai/draw"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

func main() {
	args := vi.Args()
	if len(args) > 0 {
		args = args[1:]
	}
	o, ok := parseOptions(args)
	if !ok {
		vi.ConsoleLine(usage)
		vi.Exit(2)
	}
	v := newViewer(o.filter)
	if o.text {
		runText(v, o)
		return
	}
	runWindow(v, o)
}

func pollRings(v *viewer) (bool, int64) {
	apps := v.filter.apps
	if len(apps) == 0 {
		var rc int64
		apps, rc = vi.AppLogNames()
		if rc < 0 && rc != vi.ErrFileNotFound {
			return false, rc
		}
	}
	dirty := false
	for _, app := range apps {
		body, rc := vi.ReadLog(app)
		if rc == vi.ErrFileNotFound {
			continue // a producer has not published its first row yet
		}
		if rc < 0 {
			return dirty, rc
		}
		for _, e := range v.observe(app, body) {
			dirty = true
			if e.lost != 0 {
				vi.ConsoleLine(e.text())
			} else {
				vi.ConsoleLine("logview: " + e.text())
			}
		}
	}
	return dirty, 0
}

func exportFiles(v *viewer) int64 {
	h, rc := vi.FileOpen(exportDir, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
	if rc < 0 && rc != vi.ErrFileExists {
		return rc
	}
	if rc == 0 {
		vi.FileClose(uint32(h))
	}
	paths, rc := v.exportView(func(path string) (bool, int64) {
		h, rc := vi.FileOpen(path, vi.ModeRead)
		if rc == vi.ErrFileNotFound {
			return false, 0
		}
		if rc < 0 {
			return false, rc
		}
		vi.FileClose(uint32(h))
		return true, 0
	}, vi.WriteFileSafe)
	for _, path := range paths {
		vi.ConsoleLine("logview: export " + path)
	}
	return rc
}

func fail(rc int64) {
	vi.ConsoleLine("logview: error rc=" + vi.Itoa64(rc))
	vi.Exit(1)
}

func runText(v *viewer, o options) {
	for polls := 1; ; polls++ {
		if _, rc := pollRings(v); rc < 0 {
			fail(rc)
		}
		if polls == 1 {
			vi.ConsoleLine("logview: ready text")
		}
		if !o.follow || (o.polls > 0 && polls >= o.polls) {
			break
		}
		time.Sleep(time.Second)
	}
	if o.export {
		if rc := exportFiles(v); rc < 0 {
			fail(rc)
		}
	}
	vi.ConsoleLine("logview: done")
}

func runWindow(v *viewer, o options) {
	ta := tabapp.Init(tabapp.Config{Name: "LOGVIEW.ELF", Title: "App logs",
		X: 32, Y: 32, W: 800, H: 480})
	if ta == nil {
		fail(-1)
	}
	vi.ConsoleLine("logview: open id=" + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine("logview: declare accepted")
	}
	status := "Live app logs | E: export | arrows scroll | Esc: close"
	polls := 0
	exported := false
	next := int64(0)
	quit := false
	// top is the first painted row; -1 is follow-tail (the pre-scrollbar
	// behaviour — the newest rows stay visible as the rings grow). Any
	// explicit scroll drops follow; End re-arms it.
	top := -1
	drag := false
	var bar widgets.Scrollbar // the §5.2 log-list chrome, rebuilt per frame
	loop := appkit.NewLoop(ta, func() {
		c := ta.Canvas()
		c.FillRect(widgets.Rect{W: int(ta.W), H: int(ta.H)}, draw.Opaque(theme.Current.Bg))
		header := widgets.Text{R: widgets.Rect{X: 12, Y: 12, W: int(ta.W) - 24, H: 24},
			Label: status, Fg: theme.Current.Text, Bg: theme.Current.Bg}
		header.Draw(c)
		rows := v.visible()
		n := (int(ta.H) - 48) / 16
		if n < 1 {
			n = 1
		}
		maxTop := len(rows) - n
		if maxTop < 0 {
			maxTop = 0
		}
		start := top
		if start < 0 || start > maxTop {
			start = maxTop
		}
		rowW := int(ta.W) - 24
		if maxTop > 0 {
			bar = widgets.Scrollbar{
				R:        widgets.Rect{X: int(ta.W) - 12 - widgets.ScrollbarW, Y: 44, W: widgets.ScrollbarW, H: n * 16},
				Total:    len(rows),
				Viewport: n,
				Offset:   start,
				Pressed:  drag,
			}
			rowW = bar.R.X - theme.Current.PadXS - 12
		} else {
			bar = widgets.Scrollbar{}
		}
		if bc, ok := c.(*draw.BufferCanvas); ok {
			bc.PushClip(widgets.Rect{X: 12, Y: 44, W: rowW, H: n * 16})
		}
		end := start + n
		if end > len(rows) {
			end = len(rows)
		}
		for i, e := range rows[start:end] {
			row := widgets.Text{R: widgets.Rect{X: 12, Y: 44 + i*16, W: rowW, H: 16},
				Label: strings.ReplaceAll(e.text(), "\t", " "), Fg: theme.Current.Text,
				Bg: theme.Current.Bg}
			row.Draw(c)
		}
		if bc, ok := c.(*draw.BufferCanvas); ok {
			bc.PopClip()
		}
		bar.Draw(c)
	}, func(ev vi.Event) bool {
		rows := len(v.visible())
		n := (int(ta.H) - 48) / 16
		if n < 1 {
			n = 1
		}
		maxTop := rows - n
		if maxTop < 0 {
			maxTop = 0
		}
		switch ev.Kind {
		case vi.EvMouseDown:
			if ev.Flags&vi.BtnLeft == 0 || !bar.HitTest(int(ev.Arg0), int(ev.Arg1)) {
				return false
			}
			switch bar.PageAt(int(ev.Arg0), int(ev.Arg1)) {
			case 0:
				drag = true
			case -1:
				if top < 0 {
					top = maxTop
				}
				top -= n
				if top < 0 {
					top = 0
				}
			case 1:
				if top < 0 {
					top = maxTop
				}
				top += n
				if top > maxTop {
					top = maxTop
				}
			}
			return true
		case vi.EvMouseMove:
			if !drag {
				return false
			}
			top = bar.OffsetAt(int(ev.Arg1))
			return true
		case vi.EvMouseUp:
			if !drag {
				return false
			}
			drag = false
			return true
		}
		if ev.Kind != vi.EvKeyDown {
			return false
		}
		step := func(d int) {
			if top < 0 {
				top = maxTop
			}
			top += d
			if top < 0 {
				top = 0
			}
			if top > maxTop {
				top = maxTop
			}
		}
		switch ev.Arg0 {
		case 0x29: // Escape
			quit = true
		case 0x08: // E
			rc := exportFiles(v)
			if rc < 0 {
				status = "Export failed rc=" + vi.Itoa64(rc)
			} else {
				status = "Exported filtered view to /host/LOGEXPORT"
			}
			return true
		case 0x52: // Up
			step(-1)
			return true
		case 0x51: // Down
			step(1)
			return true
		case 0x4b: // Page Up
			step(-n)
			return true
		case 0x4e: // Page Down
			step(n)
			return true
		case 0x4a: // Home
			top = 0
			return true
		case 0x4d: // End — re-arm follow-tail
			top = -1
			return true
		}
		return false
	})
	loop.OnInitialPresent = func() { vi.ConsoleLine("logview: present") }
	loop.OnExit = func(status int) {
		vi.ConsoleLine("logview: close")
		ta.CloseAndExit(status)
	}
	loop.ShouldQuit = func() (int, bool) { return 0, quit }
	// appkit owns lifecycle/input/presentation. Polling is injected into its
	// event source rather than adding a goroutine (and another task).
	if _, rc := pollRings(v); rc < 0 {
		fail(rc)
	}
	vi.ConsoleLine("logview: ready window")
	loop.RunWith(func() (vi.Event, int64, bool) {
		now := vi.Nanos()
		if next == 0 || (o.follow && now >= next && (o.polls == 0 || polls < o.polls)) {
			dirty, rc := pollRings(v)
			if rc < 0 {
				status = "Read failed rc=" + vi.Itoa64(rc)
				dirty = true
			}
			polls++
			next = now + 1_000_000_000
			if o.export && !exported && (!o.follow || (o.polls > 0 && polls >= o.polls)) {
				rc := exportFiles(v)
				status = "Exported filtered view to /host/LOGEXPORT"
				if rc < 0 {
					status = "Export failed rc=" + vi.Itoa64(rc)
				}
				exported = true
				dirty = true
			}
			if dirty {
				loop.Present()
				vi.ConsoleLine("logview: present")
			}
		}
		return vi.PollEventRaw()
	}, func(uint64) { time.Sleep(time.Second) })
}
