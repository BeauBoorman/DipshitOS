// Command welcome is GOWELCOME.ELF: the M122b (issue #2571) first-boot
// welcome tour — five core gestures and one-click launchers on a tabapp
// canvas. The seat execs it beside GOSH.ELF on a LIVE first boot (the demo
// choreography owns the strip and would eat it as a second tab; a restored
// session replays the strip the user left, never adds to it). After first
// boot the launcher catalogue keeps it reachable.
//
// tour.go is the pure model: the gesture and launcher tables, the click /
// key -> launcher mapping and the status text. It touches no vi calls, so
// the host tests pin the frame's content and every launch route; main.go
// owns the tabapp shell, the exec seam and the serial markers.
package main

import (
	"strings"

	"virelai/chords"
)

// gesture is one taught row: the spelling painted on the key chip and a
// one-line description of what the move does.
type gesture struct {
	keys string
	text string
}

// seatChord pulls the seat's OWN spelling of a bound action out of the
// global registry (virelai/chords is the normative table hid.go dispatches
// from), matched on the full chord — an action with several spellings
// (cycle-focus rides alt+tab AND ctrl+tab) names the one the tour teaches.
// A re-homed chord then updates the tour for free instead of stranding it
// on a dead spelling — and a missing row yields "", which the tests
// refuse, so a registry edit can never silently empty a chip.
func seatChord(action string, want chords.Chord) string {
	for _, r := range chords.Global {
		if r.Scope == chords.ScopeSeat && r.Action == action && r.Chord == want {
			return strings.ToUpper(r.Chord.String())
		}
	}
	return ""
}

// gestures is the first hour's five moves. The two pointer moves have no
// chord to borrow; the three bound rows spell theirs from the registry.
func gestures() []gesture {
	return []gesture{
		{"CLICK", "focus a tab — the rail up top lists open windows"},
		{seatChord("launcher", chords.Chord{Mods: chords.ModCtrl, Usage: chords.UsageSpace}), "summon the launcher — the whole app catalogue"},
		{seatChord("cycle-focus", chords.Chord{Mods: chords.ModCtrl, Usage: chords.UsageTab}), "cycle the open tabs · +shift steps back"},
		{"DRAG", "drag a rail tab to reorder it"},
		{seatChord("palette", chords.Chord{Mods: chords.ModCtrl | chords.ModShift, Usage: chords.UsageP}), "command palette — find anything"},
	}
}

// launcher is a one-click app start: the button label and the ELF it
// execs. These are the four daily apps the tour hands a newcomer —
// Settings, Files, Store and Terminal are all dock-side catalogue rows.
type launcher struct {
	label string
	bin   string
}

var launchers = []launcher{
	{"Settings", "GOSET.ELF"},
	{"Files", "GOFILES.ELF"},
	{"Store", "GOSTORE.ELF"},
	{"Terminal", "GOTERM.ELF"},
}

// tour is the frame's state: the launcher hover/press for the pointer, the
// quit latch for Esc/q, and the last launch outcome the status line echoes.
type tour struct {
	hover    int    // launcher index under the pointer; -1 when none
	pressed  int    // launcher index held on a left press; -1 when none
	launched string // last bin the tour successfully started
	failed   string // last bin the exec refused
	quit     bool
}

func newTour() tour {
	return tour{hover: -1, pressed: -1}
}

// launcherAt maps a canvas point to a launcher index over the laid-out
// button rects, or -1. Kept on the model so the click path and the tests
// share one mapping — a rect drift cannot split the two.
func (t *tour) launcherAt(rects []rect, x, y int) int {
	for i := range launchers {
		if i < len(rects) && rects[i].contains(x, y) {
			return i
		}
	}
	return -1
}

// digitLaunch maps the keyboard spelling of a launch: '1'..'4' fire the
// same exec as a click on that button. Out-of-range is no launch.
func digitLaunch(ch uint32) int {
	if ch >= '1' && ch < '1'+uint32(len(launchers)) {
		return int(ch - '1')
	}
	return -1
}

// footText is the status line: the launch outcome when one ran, else the
// hint strip.
func (t *tour) footText() string {
	if t.failed != "" {
		return "could not start " + t.failed
	}
	if t.launched != "" {
		return "started " + t.launched + " — find its tab on the rail"
	}
	return "1-4 launch · esc closes · reopen from the launcher"
}

// rect is a canvas-space box; contains is the hit test the pointer path
// and the tests share.
type rect struct{ X, Y, W, H int }

func (r rect) contains(x, y int) bool {
	return x >= r.X && x < r.X+r.W && y >= r.Y && y < r.Y+r.H
}
