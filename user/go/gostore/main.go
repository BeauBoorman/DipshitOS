// Command gostore is GOSTORE.ELF — M110c (#2405): the store's human path.
// Browse, search, detail, install, update, remove, rollback and pin as a
// tab on the default seat — every action driving the SAME signed legs
// STORE.ELF runs (verify → fetch → sha → publish → .prev) through
// package virelai/store linked in-process. STORE stays the scriptable
// path and the only implementation: GOSTORE never execs STORE.ELF —
// seat + GOSTORE + STORE + FLINT would be four concurrent Go runtimes
// (16 > 13 user task slots; the seat's proven envelope is three).
//
// Keys: j/k or arrows move, Enter toggles the detail card, / searches,
// l reloads the catalog, i/u/r/d act on the selected row, p pins the
// prior signed head (M188c #3188), q quits.
// argv: --remote=<flintd addr> --channel=<dir|http://...> --kill-at=<leg>
// (the gate's mid-publish kill point; never set in real use).
package main

import (
	"strings"

	"virelai/store"
	"virelai/tabapp"
	"virelai/vi"
)

const (
	appName  = "GOSTORE.ELF"
	appTitle = "Store"
	natW     = 640
	natH     = 480
)

func cliArgs(raw []string) []string {
	if len(raw) == 0 {
		return nil
	}
	first := strings.ToUpper(raw[0])
	if strings.HasSuffix(first, ".ELF") || strings.HasSuffix(first, ".BIN") || first == "GOSTORE" {
		return raw[1:]
	}
	return raw
}

func parseArgs(args []string) (remote, channel, killAt, tear string) {
	channel = store.DefaultChannel
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--remote="):
			remote = a[len("--remote="):]
		case strings.HasPrefix(a, "--channel="):
			channel = a[len("--channel="):]
		case strings.HasPrefix(a, "--kill-at="):
			killAt = a[len("--kill-at="):]
		case strings.HasPrefix(a, "--tear="):
			tear = a[len("--tear="):]
		}
	}
	return remote, channel, killAt, tear
}

func main() {
	remote, channel, killAt, tear := parseArgs(cliArgs(vi.Args()))
	if tear != "" {
		// The gate's torn-state legs: diverge the named file's bytes
		// before any store op runs, so the update/rollback sha fences
		// fire on the next verb.
		if r := vi.WriteFilePublish(tear, []byte("x"), true); r < 0 {
			vi.ConsoleLine("gostore: tear " + tear + " failed " + vi.Itoa64(r))
		} else {
			vi.ConsoleLine("gostore: tear " + tear)
		}
	}

	ta := tabapp.Init(tabapp.Config{Name: appName, Title: appTitle, X: 48, Y: 48, W: natW, H: natH})
	if ta == nil {
		vi.ConsoleLine("gostore: error open -1")
		vi.Exit(1)
	}
	vi.ConsoleLine("gostore: open id=" + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine("gostore: declare accepted")
	} else {
		vi.ConsoleLine("gostore: declare refused")
	}

	a := &app{
		ta:      ta,
		fs:      store.GuestFS{},
		remote:  remote,
		channel: channel,
		killAt:  killAt,
	}
	a.frame = func() {
		a.draw()
		ta.Present()
	}
	// The tee: every `store:` line keeps reaching serial verbatim AND
	// lands in the log pane — the legs are the same lines the scriptable
	// path prints.
	store.ConsoleFn = func(s string) {
		vi.ConsoleLine(s)
		a.tee(s)
	}
	store.LegFn = a.onLeg

	a.repaint()
	vi.ConsoleLine("gostore: ready")

	for {
		ev, rc, ok := vi.PollEventRaw()
		if ok {
			switch a.ta.Dispatch(ev) {
			case tabapp.ActionClosed:
				a.quit = true
			case tabapp.ActionResized:
				a.repaint()
			case tabapp.ActionNone:
				if ev.Kind == vi.EvKeyDown {
					a.key(ev)
				}
			}
		} else if rc < 0 {
			return
		}
		if a.quit {
			vi.ConsoleLine("gostore: close")
			vi.ConsoleLine("gostore OK")
			a.ta.CloseAndExit(0)
			return
		}
		if !ok {
			vi.Sleep(1)
		}
	}
}
