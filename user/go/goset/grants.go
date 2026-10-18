package main

import (
	"errors"
	"fmt"
	"sort"
	"strings"

	"virelai/vi"
)

// M113d (#2420, ADR 0054 Part II D10): the grants pane — the consent half
// of "the publisher declares, the user decides." STORE proposes a
// `(name, sha256, words)` row from a signed ReleaseCaps; this pane shows
// declared-vs-granted per installed binary, and the typed `grant <BIN>`
// gesture lands the row through slot 89 `sys_grant_admin` — the ONE
// in-guest write path, gated by the kernel to the registered WM seat or
// a CAP_PROC_ADMIN principal, and never the app the row names (a pane
// cannot widen itself). `refuse <BIN>` is the refusal gesture: no write,
// the app stays on whatever it had — baseline for a first-time ask.
//
// The pane's "granted" column reads the same admin slot (op 0), so a
// caller without the seat or the cap shows `granted=?` — refused reads
// are named, never rendered as an empty table. When the pane can read,
// it also performs the non-widening keep itself: an update moves the
// measured sha256, so a hash-bound row goes stale; a row whose words
// still cover the declared ask is re-pinned to the installed image (the
// consent already given for those words — never a widening write).
//
// Markers (each printed only after the step it names):
//
//	goset: grants n=<count>                  pane opened/refreshed
//	goset: grant keep name=<BIN> words=<w>   stale row re-pinned (same words)
//	goset: grant written name=<BIN> words=<w> consent landed a row
//	goset: grant declined name=<BIN>          refusal gesture — no write
//	goset: grant refuse name=<BIN> <reason>   a gesture could not land

// grantApp is the declared half of one pane row — the fields the pane
// needs out of STORE.TXT's line grammar (documented in
// user/go/store/state.go): the installed image hash a consent write
// binds, and the signed ReleaseCaps the release asked for.
type grantApp struct {
	Name   string // installed binary, e.g. GOHELLO.ELF — the row name
	SHA256 string // installed ELF sha256 — the digest a hash-bound row pins
	Caps   string // declared ReleaseCaps, canonical csv; "" = no ask
}

// grantStatePath mirrors store's statePath — the pane reads the file,
// STORE remains its only writer.
const (
	grantStatePath = "/host/STORE.TXT"
	grantStateMax  = 64 * 1024
)

// loadGrantApps reads STORE.TXT into the pane's app list. An absent
// file is an empty list, not an error (nothing installed yet).
func loadGrantApps() ([]grantApp, error) {
	body, rc := vi.ReadFileAll(grantStatePath, grantStateMax)
	if rc < 0 {
		if rc == -vi.ErrENOENT {
			return nil, nil
		}
		return nil, fmt.Errorf("state-rc%d", rc)
	}
	return parseGrantApps(body)
}

// parseGrantApps decodes the STORE.TXT line grammar (documented in
// user/go/store/state.go). It scrapes only the fields it names
// (name=/sha256=/caps=): the grammar is additive, so unknown keys pass
// through; '#' lines are the file's own header. A data line without
// name= or sha256= is malformed, not a row to guess at.
func parseGrantApps(body []byte) ([]grantApp, error) {
	var out []grantApp
	for _, line := range strings.Split(string(body), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		var app grantApp
		for _, f := range strings.Split(line, " ") {
			if k, v, ok := strings.Cut(f, "="); ok {
				if k == "prev_row" {
					break // grammar-last: the row text itself is freeform
				}
				switch k {
				case "name":
					app.Name = v
				case "sha256":
					app.SHA256 = v
				case "caps":
					if v != "-" {
						app.Caps = v
					}
				}
			}
		}
		if app.Name == "" || app.SHA256 == "" {
			return nil, errors.New("state-malformed")
		}
		out = append(out, app)
	}
	return out, nil
}

// The data seams — host tests substitute all three; the guest defaults
// read STORE.TXT and GRANTS.TXT through the admin slot.
var (
	grantInstalledFn = loadGrantApps
	grantRowsFn      = func() ([]vi.GrantRow, int64) { return vi.GrantRows() }
	grantWriteFn     = func(line string) int64 { return vi.GrantWriteLine(line) }
)

// grantEntry is one pane row: an installed app's declared ask beside the
// grant row it has (or lacks). Row-less entries are the baseline; rows
// without a store entry are grants on binaries STORE does not track.
type grantEntry struct {
	Name     string       // row name — the exec-recorded image
	SHA256   string       // installed image hash; "" when untracked
	Declared []string     // signed ReleaseCaps (nil = no ask)
	Row      *vi.GrantRow // the GRANTS.TXT row, nil when absent
	ReadErr  int64        // slot-89 read errno that hid the table; 0 = read
}

// state is the pane's one-word verdict for the row.
func (e grantEntry) state() string {
	if e.ReadErr != 0 {
		return "unreadable"
	}
	if e.Row == nil {
		if len(e.Declared) > 0 {
			return "pending"
		}
		return "baseline"
	}
	// A hash-bound row pinned to bytes that are not the installed image
	// applies to nothing — stale outranks every other verdict.
	if e.Row.SHA != "*" && e.SHA256 != "" && e.Row.SHA != e.SHA256 {
		return "stale"
	}
	if len(e.Declared) > 0 && !vi.GrantWordsSubset(e.Declared, splitCSV(e.Row.Words)) {
		return "widening"
	}
	return "granted"
}

func splitCSV(s string) []string {
	if s == "" || s == "-" {
		return nil
	}
	return strings.Split(s, ",")
}

// grantsView is the pane's model: the union of STORE-tracked installs
// and GRANTS.TXT row names, refreshed whole like servicesView.
type grantsView struct {
	entries  []grantEntry
	stateErr error
	readErr  int64
}

// Refresh reloads both halves and runs the non-widening keep: a stale
// row whose consented words still cover the app's declared ask is
// re-pinned to the installed image (the user consented those words;
// only the binding moved). Returns whether the view changed — the
// services-view contract.
func (v *grantsView) Refresh() bool {
	apps, serr := grantInstalledFn()
	rows, rc := grantRowsFn()
	changed := serr != v.stateErr || rc != v.readErr
	v.stateErr, v.readErr = serr, rc
	byName := map[string]*vi.GrantRow{}
	for i := range rows {
		byName[rows[i].Name] = &rows[i]
	}
	var names []string
	declared := map[string][]string{}
	sha := map[string]string{}
	for _, a := range apps {
		names = append(names, a.Name)
		declared[a.Name] = splitCSV(a.Caps)
		sha[a.Name] = a.SHA256
	}
	for n := range byName {
		if _, ok := declared[n]; !ok {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	next := make([]grantEntry, 0, len(names))
	for _, n := range names {
		next = append(next, grantEntry{
			Name:     n,
			SHA256:   sha[n],
			Declared: declared[n],
			Row:      byName[n],
			ReadErr:  rc,
		})
	}
	if len(next) != len(v.entries) {
		changed = true
	} else {
		for i := range next {
			o, nn := v.entries[i], next[i]
			if o.Name != nn.Name || o.SHA256 != nn.SHA256 ||
				strings.Join(o.Declared, ",") != strings.Join(nn.Declared, ",") ||
				(o.Row == nil) != (nn.Row == nil) {
				changed = true
				break
			}
			if o.Row != nil && (o.Row.SHA != nn.Row.SHA || o.Row.Words != nn.Row.Words) {
				changed = true
				break
			}
		}
	}
	v.entries = next
	// The keep: a stale row the declared ask still fits re-pins to the
	// installed image with its consented words verbatim.
	if rc == 0 {
		for i := range v.entries {
			e := &v.entries[i]
			if e.Row == nil || e.SHA256 == "" || e.Row.SHA == "*" || e.Row.SHA == e.SHA256 {
				continue
			}
			if !vi.GrantWordsSubset(e.Declared, splitCSV(e.Row.Words)) {
				continue
			}
			keep := vi.GrantLine(vi.GrantRow{Name: e.Name, SHA: e.SHA256, Words: e.Row.Words})
			if wrc := grantWriteFn(keep); wrc < 0 {
				consoleLine("goset: grant keep failed " + e.Name + " rc=" + vi.Itoa64(wrc))
			} else {
				consoleLine("goset: grant keep name=" + e.Name + " words=" + e.Row.Words)
				e.Row.SHA = e.SHA256
				changed = true
			}
		}
	}
	return changed
}

// Labels renders one line per entry, state word last.
func (v *grantsView) Labels() []string {
	var out []string
	for _, e := range v.entries {
		granted := "-"
		if e.ReadErr != 0 {
			granted = "?"
		} else if e.Row != nil {
			granted = e.Row.Words
		}
		out = append(out, e.Name+
			"  declared="+vi.GrantWordsCanonical(e.Declared)+
			"  granted="+granted+
			"  state="+e.state())
	}
	return out
}

// find resolves a typed bin selector (GOHELLO.ELF or GOHELLO) to an
// entry; the store entry is what supplies the consent's sha binding.
func (v *grantsView) find(name string) *grantEntry {
	up := strings.ToUpper(strings.TrimSpace(name))
	if !strings.HasSuffix(up, ".ELF") && !strings.HasSuffix(up, ".BIN") {
		up += ".ELF"
	}
	for i := range v.entries {
		if v.entries[i].Name == up {
			return &v.entries[i]
		}
	}
	return nil
}

// grantErr maps a slot-89 negative errno to its marker token.
func grantErr(rc int64) string {
	switch rc {
	case -vi.ErrEACCES:
		return "eacces"
	case -vi.ErrEINVAL:
		return "einval"
	case -vi.ErrENOSPC:
		return "enospc"
	case -vi.ErrENXIO:
		return "enxio"
	case -vi.ErrENOENT:
		return "enoent"
	default:
		return "rc" + vi.Itoa64(rc)
	}
}

// Grant writes the consent row for name: (bin, installed sha, declared
// words). A bin with no declared ask has nothing to consent — a row the
// user never asked the publisher for is not a grant, it is a narrowing
// nobody proposed.
func (v *grantsView) Grant(name string) error {
	if v.readErr != 0 {
		consoleLine("goset: grant refuse name=" + name + " " + grantErr(v.readErr))
		return errors.New(grantErr(v.readErr))
	}
	e := v.find(name)
	if e == nil {
		consoleLine("goset: grant refuse name=" + name + " unknown")
		return errors.New("unknown")
	}
	if len(e.Declared) == 0 {
		consoleLine("goset: grant refuse name=" + e.Name + " no-ask")
		return errors.New("no-ask")
	}
	line := vi.GrantLine(vi.GrantRow{
		Name:  e.Name,
		SHA:   e.SHA256,
		Words: vi.GrantWordsCanonical(e.Declared),
	})
	if rc := grantWriteFn(line); rc < 0 {
		consoleLine("goset: grant refuse name=" + e.Name + " " + grantErr(rc))
		return errors.New(grantErr(rc))
	}
	consoleLine("goset: grant written name=" + e.Name + " words=" + vi.GrantWordsCanonical(e.Declared))
	v.Refresh()
	return nil
}

// Decline is the refusal gesture: named, printed, and nothing written —
// the app keeps whatever it had (baseline for a first-time ask, the
// prior consent for a widening one).
func (v *grantsView) Decline(name string) {
	e := v.find(name)
	bin := name
	if e != nil {
		bin = e.Name
	}
	consoleLine("goset: grant declined name=" + bin)
}

// --- panel wiring ------------------------------------------------------------
//
// M122e (#2574): the open moved into panel.showTab — the tab-strip cell,
// the typed `grants` line and Esc's pop all land the same switch.

func (a *panel) grantStatus() {
	if a.grants.stateErr != nil {
		a.status = "grants refused: state-unreadable (read-only)"
		consoleLine("goset: grants refuse state-unreadable")
		return
	}
	if a.grants.readErr != 0 {
		a.status = "grant table unreadable (" + grantErr(a.grants.readErr) + ") — declared shown, consent needs the admin slot"
		return
	}
	a.status = "grant|refuse <BIN> + Enter, or click a row to grant; Esc returns"
}

// grantInput consumes the grants pane's typed line: `grant <BIN>`,
// `refuse <BIN>`, or `settings` to return. Anything else is named and
// dropped, mirroring serviceInput.
func (a *panel) grantInput() {
	line := strings.TrimSpace(a.input.Value())
	a.input.Clear()
	if line == "settings" {
		a.showTab(tabSettings)
		return
	}
	verb, arg, found := strings.Cut(line, " ")
	if !found || strings.TrimSpace(arg) == "" {
		a.status = "grants: grant <BIN> or refuse <BIN>"
		return
	}
	switch strings.ToLower(strings.TrimSpace(verb)) {
	case "grant":
		if err := a.grants.Grant(arg); err != nil {
			a.status = "grant refused: " + err.Error()
			return
		}
		a.status = "grant written"
	case "refuse":
		a.grants.Decline(arg)
		a.status = "consent declined"
	default:
		a.status = "grants: grant <BIN> or refuse <BIN>"
	}
}
