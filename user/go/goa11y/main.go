// Command goa11y is GOA11Y.ELF — the M177b (issue #3143) accessibility
// outline reader. It opens a tab, asks the seat's WINDOWS_QUERY (kind 16)
// every 500 ms which window holds the focus, reads that window's
// published outline at /host/A11Y.<win>, and paints it as an indented
// list. Every change prints `goa11y: focus win=<id> nodes=<n>` plus one
// `goa11y: node <i> <role> <state> <name>` line per node; a focused
// window with no published outline prints `goa11y: no outline win=<id>`,
// and a file that is not the v1 grammar prints `goa11y: bad outline
// win=<id>` — a missing or malformed file is a named state, never a
// crash.
package main

import (
	"virelai/appkit"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/vsys"
	"virelai/widgets"
)

const (
	appName  = "GOA11Y.ELF"
	appTitle = "A11y"
	natW     = 512
	natH     = 384

	// pollNs is the card's focus cadence: kind 16 is a request/response,
	// not a subscription, so the reader re-asks on a timer rather than
	// learning focus changes for free.
	pollNs = 500_000_000

	markerOpen      = "goa11y: open id="
	markerDeclare   = "goa11y: declare accepted"
	markerRefused   = "goa11y: declare refused"
	markerPresent   = "goa11y: present"
	markerFocus     = "goa11y: focus win="
	markerNode      = "goa11y: node "
	markerNoOutline = "goa11y: no outline win="
	markerBadFile   = "goa11y: bad outline win="
	markerNoFocus   = "goa11y: no focus"
	markerQueryFail = "goa11y: query "
	markerClose     = "goa11y: done"
)

// The syscall seams a host test swaps out — the wmstate.go / playArm
// pattern: the guest hits the real slots, the host watches the calls.
var (
	wmWindows  = vi.WmWindows
	readFile   = vi.ReadFileAll
	armTimerNs = vsys.TimerSetNs
	console    = vi.ConsoleLine
)

// view is the reader's reportable state — the named outcomes a poll can
// land on, in the order the paint and the markers share.
type view int

const (
	viewIdle       = iota // nothing reported yet
	viewQueryFail         // kind 16 refused or went silent
	viewNoFocus           // query answered, no focused row
	viewNoOutline         // focused window, no A11Y file
	viewBadOutline        // file present, not the v1 grammar
	viewOutline           // decoded outline
)

type app struct {
	ta   *tabapp.TabApp
	self uint32 // own window id — the bound-window kind 16 needs

	state view
	win   uint32
	nodes []appkit.Node

	// Dedup: the last reported outcome's identity — focused window plus
	// the file bytes it was read from — so the 500 ms poll stays silent
	// until the outline actually moves.
	lastWin  uint32
	lastBody []byte
	reported bool
}

// focusedWin answers the seat query and returns the focused window's id,
// or false when the seat gave no focused row.
func focusedWin(win uint32, self string) (uint32, view, bool) {
	rows, err := wmWindows(win, self)
	if err != nil {
		return 0, viewQueryFail, false
	}
	for _, r := range rows {
		if r.Focused {
			return r.ID, viewIdle, true
		}
	}
	return 0, viewNoFocus, false
}

// poll runs one query/read cycle and reports only on change. It returns
// whether the painted state moved.
func (a *app) poll() bool {
	win, st, ok := focusedWin(a.self, appName)
	if !ok {
		return a.report(st, 0, nil)
	}
	body, r := readFile(appkit.A11yPath(win), appkit.A11yMaxBytes)
	if r < 0 {
		return a.report(viewNoOutline, win, nil)
	}
	nodes, dok := appkit.DecodeOutline(body)
	if !dok {
		return a.report(viewBadOutline, win, body)
	}
	return a.report(viewOutline, win, body, nodes...)
}

// report applies the dedup rule: identical outcome — same window, same
// body bytes, same state — is not reported twice. The node list is part
// of the identity through the body bytes.
func (a *app) report(st view, win uint32, body []byte, nodes ...appkit.Node) bool {
	same := a.reported && a.state == st && a.lastWin == win &&
		bytesEq(a.lastBody, body)
	if same {
		return false
	}
	a.reported = true
	a.state, a.win = st, win
	a.lastWin = win
	a.lastBody = append(a.lastBody[:0], body...)
	a.nodes = append(a.nodes[:0], nodes...)
	a.print()
	return true
}

// print emits the marker set for the current state. Markers go out only
// after the state is committed, so a gate reading serial sees the truth.
func (a *app) print() {
	switch a.state {
	case viewOutline:
		console(markerFocus + vi.Itoa64(int64(a.win)) +
			" nodes=" + vi.Itoa64(int64(len(a.nodes))))
		for i, n := range a.nodes {
			console(nodeLine(i, n))
		}
	case viewNoOutline:
		console(markerNoOutline + vi.Itoa64(int64(a.win)))
	case viewBadOutline:
		console(markerBadFile + vi.Itoa64(int64(a.win)))
	case viewNoFocus:
		console(markerNoFocus)
	case viewQueryFail:
		console(markerQueryFail + "refused")
	}
}

// nodeLine is the per-node marker grammar: index, role, state, name —
// the fields a journey audit reads back in order.
func nodeLine(i int, n appkit.Node) string {
	return markerNode + vi.Itoa64(int64(i)) + " " + n.Role.String() +
		" " + n.State.String() + " " + n.Name
}

func bytesEq(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// statusLine is the painted one-line state for the non-outline outcomes —
// the same named states the serial markers carry.
func (a *app) statusLine() string {
	switch a.state {
	case viewIdle:
		return "waiting for the first poll"
	case viewQueryFail:
		return "windows_query refused — no Go seat answers"
	case viewNoFocus:
		return "no focused window"
	case viewNoOutline:
		return "focused window publishes no outline"
	case viewBadOutline:
		return "outline file is malformed"
	}
	return ""
}

const (
	rowH    = 14
	indentW = 14
)

// draw paints the header, the status line for the named states, or the
// outline as an indented list — role in muted ink, the name beside it.
func (a *app) draw() {
	c := a.ta.Canvas()
	th := theme.Current
	c.FillRect(widgets.Rect{W: int(a.ta.W), H: int(a.ta.H)}, th.Bg)
	widgets.DrawText(c, widgets.Rect{X: 8, Y: 6, W: int(a.ta.W) - 16, H: rowH},
		"goa11y — focused window outline", th.Accent)
	if a.state != viewOutline {
		widgets.DrawText(c, widgets.Rect{X: 8, Y: 28, W: int(a.ta.W) - 16, H: rowH},
			a.statusLine(), th.Muted)
		return
	}
	y := 28
	for _, n := range a.nodes {
		if y+rowH > int(a.ta.H) {
			break
		}
		x := 8 + n.Depth*indentW
		label := n.Role.String() + " " + n.State.String() + " " + n.Name
		widgets.DrawText(c,
			widgets.Rect{X: x, Y: y, W: int(a.ta.W) - x - 8, H: rowH},
			label, th.Text)
		y += rowH
	}
}

// handle answers the two events the reader cares about: the poll timer
// (re-armed every fire — the kernel timer is one-shot) and plain input,
// which is ignored by contract — the reader is a mirror, not a driver.
func (a *app) handle(ev vi.Event) bool {
	if ev.Kind == vi.EvTimer {
		dirty := a.poll()
		_ = armTimerNs(pollNs)
		return dirty
	}
	return false
}

func main() {
	ta := tabapp.Init(tabapp.Config{
		Name: appName, Title: appTitle, X: 96, Y: 72, W: natW, H: natH,
	})
	if ta == nil {
		vi.ConsoleLine("goa11y: open failed")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
	} else {
		vi.ConsoleLine(markerRefused)
	}
	a := &app{ta: ta, self: uint32(ta.Win)}
	// The first poll runs before the first frame so the initial paint is
	// a real state, then the 500 ms timer owns the cadence.
	_ = a.poll()
	_ = armTimerNs(pollNs)

	loop := appkit.NewLoop(ta, a.draw, a.handle)
	loop.OnInitialPresent = func() { vi.ConsoleLine(markerPresent) }
	loop.OnExit = func(status int) {
		vi.ConsoleLine(markerClose)
		ta.CloseAndExit(status)
	}
	// A whole-tick idle sleep would stretch the 500 ms poll to ~1 s on
	// VZ; 50 ms keeps the timer the cadence owner instead.
	_ = loop.RunWith(vi.PollEventRaw, func(uint64) { vi.SleepNs(50_000_000) })
}
