package main

import (
	"strings"

	"virelai/store"
	"virelai/tabapp"
	"virelai/vi"
)

// The GOSTORE model: one catalog list, one detail card, one log pane.
// Every store call is a seam so the model is host-testable — the guest
// wiring is vi.Exec/FLINT.ELF children inside package store, and the
// child's console lines reach serial verbatim from there too.
var (
	loadFn     = store.LoadCatalog
	installFn  = store.Install
	updateFn   = store.Update
	rollbackFn = store.Rollback
	removeFn   = store.Remove
	consoleFn  = vi.ConsoleLine
	sleepFn    = vi.Sleep
	logLimit   = 96
)

// app is the panel state. Detail, search, and the op log are pure state;
// the only guest-coupled pieces are frame (the draw+present barrier) and
// the store seams above.
type app struct {
	ta    *tabapp.TabApp
	frame func()
	fs    store.FS

	remote  string
	channel string
	killAt  string

	rows    []store.CatalogRow
	sel     int
	detail  bool
	search  string
	input   string
	inputOn bool
	log     []string
	status  string
	busy    bool
	quit    bool
}

func itoa(n int) string { return vi.Itoa64(int64(n)) }

// logLine appends a console line to the log pane, bounded.
func (a *app) logLine(s string) {
	a.log = append(a.log, s)
	if len(a.log) > logLimit {
		copy(a.log, a.log[len(a.log)-logLimit:])
		a.log = a.log[:logLimit]
	}
}

// tee mirrors package store's console into the pane: the serial line
// stays byte-identical (the gate's evidence), the GUI sees the same text.
// A `store: refuse <code>` additionally surfaces as `gostore: refuse
// <code>` — the refusal is shown by name in the app's own namespace.
func (a *app) tee(s string) {
	a.logLine(s)
	if strings.HasPrefix(s, "store: refuse ") {
		a.status = s
		consoleFn("gostore: refuse " + s[len("store: refuse "):])
	}
	a.repaint()
}

func (a *app) repaint() {
	if a.frame != nil {
		a.frame()
	}
}

// selRow returns the selected row, or nil when the list is empty.
func (a *app) selRow() *store.CatalogRow {
	if a.sel < 0 || a.sel >= len(a.rows) {
		return nil
	}
	return &a.rows[a.sel]
}

// firstActionable is the row the next op names: release rows carry the
// signed card, everything else still names its stream (install on a
// sync-failed stream is a live, named refusal — the keyring negatives).
// With a search active the fold already dropped non-matching release
// rows but keeps the nameless statuses, so the pick prefers a row whose
// stream-or-app name matches the search before falling back to the
// first actionable row.
func (a *app) firstActionable() int {
	want := strings.ToLower(a.search)
	fallback := -1
	for i, r := range a.rows {
		if r.Status == "no-release" {
			continue
		}
		name := strings.ToLower(r.Stream)
		if r.Entry != nil {
			name = strings.ToLower(r.Entry.Rel.Name)
		}
		if want == "" || strings.Contains(name, want) {
			return i
		}
		if fallback < 0 {
			fallback = i
		}
	}
	if fallback >= 0 {
		return fallback
	}
	return 0
}

// target is the op argument for the selected row: a release's installed
// name when the card exists, else the stream name — store.Update/
// Rollback/Remove normalize or refuse it by name either way.
func (a *app) target() string {
	r := a.selRow()
	if r == nil {
		return ""
	}
	if r.Entry != nil {
		return r.Entry.Rel.Name
	}
	return r.Stream
}

// refresh runs the catalog fold — the same `store ls` path STORE.ELF
// prints — and turns the rows into the browse list. A refusal comes back
// as an error and is shown by name.
func (a *app) refresh() {
	a.busy = true
	a.status = "listing " + a.search
	consoleFn("gostore: list")
	a.repaint()
	rows, err := loadFn(a.fs, store.DefaultStoreRoot, a.remote, a.channel, a.search, "")
	if err != nil {
		a.busy = false
		a.status = err.Error()
		a.logLine(a.status)
		code := "error"
		if re, ok := err.(*store.RefuseError); ok {
			code = re.Code
		}
		consoleFn("gostore: refuse " + code)
		a.repaint()
		return
	}
	a.rows = rows
	a.sel = a.firstActionable()
	a.busy = false
	a.status = ""
	for _, r := range rows {
		line := "gostore: stream " + r.Stream + " " + r.Status
		if r.Refusal != "" {
			line += " " + r.Refusal
		}
		consoleFn(line)
	}
	consoleFn("gostore: list rows=" + itoa(len(rows)))
	a.repaint()
}

// runOp drives one mutating verb — the full signed pipeline inside this
// process, with LegFn narrating each leg into the pane and onto serial.
// The verb's own `store:` lines (its refusals by name included) arrive
// through the tee.
func (a *app) runOp(verb, target string, op func() int) {
	if target == "" {
		a.status = "nothing selected"
		return
	}
	a.busy = true
	a.status = verb + " " + target
	consoleFn("gostore: " + verb + " " + target)
	a.repaint()
	rc := op()
	a.busy = false
	consoleFn("gostore: " + verb + " rc=" + itoa(rc))
	a.status = verb + " rc=" + itoa(rc)
	// Only install/remove move the installed badge; flip it locally on
	// success instead of re-paying a wire session for a re-list. A
	// refused op changes nothing — the badge stays honest.
	if rc == 0 {
		if r := a.selRow(); r != nil {
			switch verb {
			case "install":
				r.Installed = true
			case "remove":
				r.Installed = false
			}
		}
	}
	a.repaint()
}

// onLeg is package store's LegFn: each signed-pipeline leg boundary,
// narrated and painted. --kill-at=<leg> makes the named leg a pause
// point: the marker prints, then the app holds — the go-gostore gate
// kills it mid-publish and the torn shape is what the next boot checks.
func (a *app) onLeg(leg string) {
	consoleFn("gostore: leg " + leg)
	a.status = "leg " + leg
	a.repaint()
	if a.killAt != "" && leg == a.killAt {
		consoleFn("gostore: pause " + leg)
		a.status = "paused at " + leg
		a.repaint()
		for {
			sleepFn(600)
		}
	}
}

// move clamps the selection to the list and reports the row it lands on.
func (a *app) move(d int) {
	if len(a.rows) == 0 {
		return
	}
	a.sel += d
	if a.sel < 0 {
		a.sel = 0
	}
	if a.sel >= len(a.rows) {
		a.sel = len(a.rows) - 1
	}
	a.detail = false
}

const (
	keyEnter     = 0x28
	keyEscape    = 0x29
	keyBackspace = 0x2a
	keyUp        = 0x52
	keyDown      = 0x51
)

// key applies one EvKeyDown. Arg0 is the HID usage, Arg1 the decoded
// rune — the same pair GOSET reads.
func (a *app) key(ev vi.Event) {
	if a.inputOn {
		switch ev.Arg0 {
		case keyEnter:
			a.inputOn = false
			a.search = a.input
			a.refresh()
		case keyEscape:
			a.inputOn = false
			a.input = a.search
			a.status = "search cancelled"
		case keyBackspace:
			if len(a.input) > 0 {
				a.input = a.input[:len(a.input)-1]
			}
		default:
			if r := ev.Arg1; r >= 0x20 && r < 0x7f && len(a.input) < 48 {
				a.input += string(rune(r))
			}
		}
		return
	}
	switch ev.Arg0 {
	case keyUp:
		a.move(-1)
	case keyDown:
		a.move(1)
	case keyEnter:
		if r := a.selRow(); r != nil {
			a.detail = !a.detail
			state := "closed"
			if a.detail {
				state = "open"
			}
			consoleFn("gostore: detail " + r.Stream + " " + state)
		}
	case keyEscape:
		if a.detail {
			a.detail = false
		} else {
			a.quit = true
		}
		return
	}
	if ev.Arg1 == 0 {
		return
	}
	switch rune(ev.Arg1) {
	case 'j':
		a.move(1)
	case 'k':
		a.move(-1)
	case 'l':
		a.refresh()
	case '/':
		a.inputOn = true
		a.input = a.search
	case 'i':
		if r := a.selRow(); r != nil {
			stream := r.Stream
			a.runOp("install", stream, func() int {
				return installFn(a.fs, store.DefaultStoreRoot, stream, a.remote, a.channel)
			})
		}
	case 'u':
		target := a.target()
		a.runOp("update", target, func() int {
			return updateFn(a.fs, store.DefaultStoreRoot, target, a.remote, a.channel)
		})
	case 'r':
		target := a.target()
		a.runOp("rollback", target, func() int {
			return rollbackFn(a.fs, target)
		})
	case 'd':
		target := a.target()
		a.runOp("remove", target, func() int {
			return removeFn(a.fs, target)
		})
	case 'q':
		a.quit = true
	}
}
