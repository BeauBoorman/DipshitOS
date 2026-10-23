package main

import (
	"virelai/tabapp"
	"virelai/vi"
)

// crashfixMode is the argv-selected behaviour: the original panic path,
// plus M161b's (#2974) watchdog fixtures — `wedge <secs>` answers the
// seat's state asks for <secs> then stops polling them entirely, and
// `idle` answers for as long as it lives. Both open a tabapp window so
// the seat hosts them like any other app.
func crashfixMode(args []string) (mode string, secs int64) {
	mode = "panic"
	if len(args) < 2 {
		return mode, 0
	}
	switch args[1] {
	case "wedge", "idle":
		mode = args[1]
		if mode == "wedge" && len(args) > 2 {
			if n, ok := itoa(args[2]); ok && n > 0 {
				secs = n
			}
		}
	}
	return mode, secs
}

// itoa parses a non-negative decimal — the fixture needs no strconv.
func itoa(s string) (int64, bool) {
	if s == "" {
		return 0, false
	}
	var n int64
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		n = n*10 + int64(s[i]-'0')
	}
	return n, true
}

// openWatchWindow declares a hosted window for the watchdog fixtures.
func openWatchWindow() *tabapp.TabApp {
	return tabapp.Init(tabapp.Config{
		Name: "CRASHFIX.ELF", Title: "crashfix",
		X: 64, Y: 64, W: 640, H: 400,
	})
}

// runIdle answers the seat's state asks until its window is closed — the
// watchdog's never-wedged control. WIN_CLOSE still lands on the event
// queue, so Dispatch sees it and the app exits on the ordinary close path.
func runIdle() {
	ta := openWatchWindow()
	if ta == nil {
		vi.ConsoleLine("crashfix: open failed")
		vi.Exit(1)
	}
	vi.ConsoleLine("crashfix: idle")
	// The gate's proof of life: one line per minute of uninterrupted
	// answering — `alive=60` is the anchor the no-wedge run waits on.
	start := vi.Nanos()
	marked := false
	for {
		ta.PollStateAsk()
		if ev, r, ok := vi.PollEventRaw(); ok {
			if ta.Dispatch(ev) == tabapp.ActionClosed {
				vi.ConsoleLine("crashfix: closed")
				vi.Exit(0)
			}
			continue
		} else if r < 0 {
			vi.Sleep(1)
		}
		if !marked && vi.Nanos()-start >= 60_000_000_000 {
			marked = true
			vi.ConsoleLine("crashfix: idle alive=60")
		}
	}
}

// runWedge answers asks for secs, then parks on Sleep without ever polling
// the state-ask mailbox again — the wedged-app shape the watchdog exists
// to name. The sleep loop still watches for its window's death (WinQuery
// is the owner-only read): the banner's Close tears the window down
// kernel-side, the next wake sees it gone, and the process exits — which
// is exactly what "Close" means for an app that cannot hear WIN_CLOSE.
func runWedge(secs int64) {
	ta := openWatchWindow()
	if ta == nil {
		vi.ConsoleLine("crashfix: open failed")
		vi.Exit(1)
	}
	vi.ConsoleLine("crashfix: wedge secs=" + vi.Itoa64(secs))
	deadline := vi.Nanos() + secs*1_000_000_000
	for vi.Nanos() < deadline {
		ta.PollStateAsk()
		if ev, r, ok := vi.PollEventRaw(); ok {
			if ta.Dispatch(ev) == tabapp.ActionClosed {
				vi.ConsoleLine("crashfix: closed")
				vi.Exit(0)
			}
			continue
		} else if r < 0 {
			vi.Sleep(1)
		}
	}
	vi.ConsoleLine("crashfix: wedged")
	for {
		vi.Sleep(4)
		if _, r := vi.WinQuery(ta.Win); r < 0 {
			vi.ConsoleLine("crashfix: window gone")
			vi.Exit(0)
		}
	}
}

func main() {
	defer vi.CrashGuard("CRASHFIX.ELF")
	mode, secs := crashfixMode(vi.Args())
	if mode == "idle" {
		runIdle()
		return
	}
	if mode == "wedge" {
		runWedge(secs)
		return
	}
	token := "first"
	if args := vi.Args(); len(args) > 1 {
		token = args[1]
	}
	vi.ConsoleLine("crashfix: t0=" + vi.Itoa64(vi.Nanos()) + " token=" + token)
	first(token)
}

// Keep distinct real frames even when the host linker optimizes this fixture.
//
//go:noinline
func first(token string) { second(token) }

//go:noinline
func second(token string) { third(token) }

//go:noinline
func third(token string) { panic(token) }
