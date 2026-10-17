package main

import (
	"strings"
	"testing"

	"virelai/vi"
)

// fakeGrants scripts the pane's three data seams for one test.
type fakeGrants struct {
	apps    []grantApp
	appsErr error
	rows    []vi.GrantRow
	readRC  int64
	writeRC int64
	writes  []string
}

func (f *fakeGrants) install(t *testing.T) func() {
	t.Helper()
	oldI, oldR, oldW := grantInstalledFn, grantRowsFn, grantWriteFn
	grantInstalledFn = func() ([]grantApp, error) { return f.apps, f.appsErr }
	grantRowsFn = func() ([]vi.GrantRow, int64) {
		out := make([]vi.GrantRow, len(f.rows))
		copy(out, f.rows)
		return out, f.readRC
	}
	grantWriteFn = func(line string) int64 {
		if f.writeRC < 0 {
			return f.writeRC
		}
		f.writes = append(f.writes, line)
		// Mirror the kernel: a landed write is readable on the next walk.
		r, ok := vi.ParseGrantLine(line)
		if ok {
			found := false
			for i := range f.rows {
				if f.rows[i].Name == r.Name {
					f.rows[i] = r
					found = true
				}
			}
			if !found {
				f.rows = append(f.rows, r)
			}
		}
		return 0
	}
	return func() { grantInstalledFn, grantRowsFn, grantWriteFn = oldI, oldR, oldW }
}

func captureConsole(t *testing.T) (*[]string, func()) {
	t.Helper()
	var events []string
	old := consoleLine
	consoleLine = func(s string) { events = append(events, s) }
	return &events, func() { consoleLine = old }
}

// TestParseGrantApps pins the STORE.TXT scrape: the #v1 header skips,
// unknown and freeform tail fields pass through, and a data line
// missing name=/sha256= refuses.
func TestParseGrantApps(t *testing.T) {
	body := []byte("#v1\n" +
		"name=GOHELLO.ELF stream=caprel head=h1 sha256=aa caps=file,net " +
		"prev_head=h0 prev_sha256=bb prev_caps=file prev_row=GOHELLO.ELF | Go Hello | g | dock=false\n" +
		"name=BASE.ELF stream=s head=h sha256=cc caps=- prev_head=- prev_sha256=- prev_caps=- prev_row=-\n")
	apps, err := parseGrantApps(body)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(apps) != 2 || apps[0].Name != "GOHELLO.ELF" ||
		apps[0].SHA256 != "aa" || apps[0].Caps != "file,net" ||
		apps[1].Caps != "" {
		t.Fatalf("apps %+v", apps)
	}
	if _, err := parseGrantApps([]byte("name=A.ELF stream=s head=h caps=-\n")); err == nil {
		t.Fatal("sha256-less line parsed")
	}
}

// TestGrantsViewStates pins the declared-vs-granted state words: pending,
// granted, baseline, stale, widening, unreadable.
func TestGrantsViewStates(t *testing.T) {
	f := &fakeGrants{
		apps: []grantApp{
			{Name: "PEND.ELF", SHA256: "aa", Caps: "file,net"},
			{Name: "DONE.ELF", SHA256: "bb", Caps: "file"},
			{Name: "BASE.ELF", SHA256: "cc"},
			{Name: "OLD.ELF", SHA256: "new", Caps: "file,debug"},
			{Name: "WIDE.ELF", SHA256: "dd", Caps: "file,net"},
		},
		rows: []vi.GrantRow{
			{Name: "DONE.ELF", SHA: "bb", Words: "file,net"},
			{Name: "OLD.ELF", SHA: "old", Words: "file"},
			{Name: "WIDE.ELF", SHA: "dd", Words: "file"},
			{Name: "LOOSE.BIN", SHA: "*", Words: "file"},
		},
	}
	defer f.install(t)()
	v := grantsView{}
	v.Refresh()
	states := map[string]string{}
	for _, e := range v.entries {
		states[e.Name] = e.state()
	}
	want := map[string]string{
		"PEND.ELF":  "pending",
		"DONE.ELF":  "granted",
		"BASE.ELF":  "baseline",
		"OLD.ELF":   "stale",
		"WIDE.ELF":  "widening",
		"LOOSE.BIN": "granted", // wildcard row on an untracked name
	}
	for name, w := range want {
		if states[name] != w {
			t.Fatalf("%s state %q, want %q", name, states[name], w)
		}
	}
	labels := strings.Join(v.Labels(), "\n")
	if !strings.Contains(labels, "PEND.ELF  declared=file,net  granted=-  state=pending") {
		t.Fatalf("labels:\n%s", labels)
	}
}

// TestGrantsKeepRepinsStale: a stale row whose consented words still
// cover the ask is re-pinned to the installed image on refresh — the
// non-widening keep, silent because consent already covered the words.
func TestGrantsKeepRepinsStale(t *testing.T) {
	f := &fakeGrants{
		apps: []grantApp{{Name: "OLD.ELF", SHA256: "new", Caps: "file"}},
		rows: []vi.GrantRow{{Name: "OLD.ELF", SHA: "old", Words: "file,net"}},
	}
	defer f.install(t)()
	events, restore := captureConsole(t)
	defer restore()

	v := grantsView{}
	v.Refresh()
	if len(f.writes) != 1 || f.writes[0] != "OLD.ELF\tnew\tfile,net" {
		t.Fatalf("keep writes %v", f.writes)
	}
	joined := strings.Join(*events, "\n")
	if !strings.Contains(joined, "goset: grant keep name=OLD.ELF words=file,net") {
		t.Fatalf("keep marker missing: %v", *events)
	}
	if v.entries[0].state() != "granted" {
		t.Fatalf("post-keep state %q", v.entries[0].state())
	}
}

// TestGrantsKeepSkipsWidening: a stale row whose words the new ask
// exceeds is NOT re-pinned — widening is a fresh consent, and the stale
// row stands (fail closed).
func TestGrantsKeepSkipsWidening(t *testing.T) {
	f := &fakeGrants{
		apps: []grantApp{{Name: "WIDE.ELF", SHA256: "new", Caps: "file,net,debug"}},
		rows: []vi.GrantRow{{Name: "WIDE.ELF", SHA: "old", Words: "file"}},
	}
	defer f.install(t)()
	v := grantsView{}
	v.Refresh()
	if len(f.writes) != 0 {
		t.Fatalf("widening auto-kept: %v", f.writes)
	}
	if v.entries[0].state() != "stale" {
		t.Fatalf("state %q", v.entries[0].state())
	}
}

// TestGrantsConsentWritesRow: `grant <BIN>` lands (bin, installed sha,
// declared words) through the slot and prints the written marker.
func TestGrantsConsentWritesRow(t *testing.T) {
	f := &fakeGrants{
		apps: []grantApp{{Name: "PEND.ELF", SHA256: "aa", Caps: "file,net"}},
	}
	defer f.install(t)()
	events, restore := captureConsole(t)
	defer restore()

	v := grantsView{}
	v.Refresh()
	if err := v.Grant("pend"); err != nil {
		t.Fatalf("grant: %v", err)
	}
	if len(f.writes) != 1 || f.writes[0] != "PEND.ELF\taa\tfile,net" {
		t.Fatalf("writes %v", f.writes)
	}
	joined := strings.Join(*events, "\n")
	if !strings.Contains(joined, "goset: grant written name=PEND.ELF words=file,net") {
		t.Fatalf("written marker missing: %v", *events)
	}
	if v.entries[0].state() != "granted" {
		t.Fatalf("post-consent state %q", v.entries[0].state())
	}
}

// TestGrantsRefusals: unknown bin, no declared ask, and a refused write
// all name themselves — none writes.
func TestGrantsRefusals(t *testing.T) {
	f := &fakeGrants{
		apps:    []grantApp{{Name: "BASE.ELF", SHA256: "cc"}},
		writeRC: -vi.ErrEACCES,
	}
	defer f.install(t)()
	events, restore := captureConsole(t)
	defer restore()
	v := grantsView{}
	v.Refresh()

	if err := v.Grant("MISSING.ELF"); err == nil {
		t.Fatal("unknown bin granted")
	}
	if err := v.Grant("BASE.ELF"); err == nil {
		t.Fatal("no-ask granted")
	}
	joined := strings.Join(*events, "\n")
	if !strings.Contains(joined, "goset: grant refuse name=MISSING.ELF unknown") ||
		!strings.Contains(joined, "goset: grant refuse name=BASE.ELF no-ask") {
		t.Fatalf("refusals: %v", *events)
	}

	// A declared ask against a refused write names the errno.
	f.apps[0].Caps = "file"
	v.Refresh()
	if err := v.Grant("BASE.ELF"); err == nil {
		t.Fatal("eacces write succeeded")
	}
	joined = strings.Join(*events, "\n")
	if !strings.Contains(joined, "goset: grant refuse name=BASE.ELF eacces") {
		t.Fatalf("eacces refusal: %v", *events)
	}
	if len(f.writes) != 0 {
		t.Fatalf("refusals wrote: %v", f.writes)
	}
}

// TestGrantsDeclineLeavesBaseline: the refusal gesture prints and writes
// nothing — a first-time ask leaves the app at baseline.
func TestGrantsDeclineLeavesBaseline(t *testing.T) {
	f := &fakeGrants{
		apps: []grantApp{{Name: "PEND.ELF", SHA256: "aa", Caps: "file,net"}},
	}
	defer f.install(t)()
	events, restore := captureConsole(t)
	defer restore()
	v := grantsView{}
	v.Refresh()
	v.Decline("PEND.ELF")
	joined := strings.Join(*events, "\n")
	if !strings.Contains(joined, "goset: grant declined name=PEND.ELF") {
		t.Fatalf("decline marker: %v", *events)
	}
	if len(f.writes) != 0 || f.rows != nil {
		t.Fatalf("decline wrote: %v rows=%v", f.writes, f.rows)
	}
	if v.entries[0].state() != "pending" {
		t.Fatalf("post-decline state %q", v.entries[0].state())
	}
}

// TestGrantsUnreadableTable: -EACCES on the read renders "granted=?" and
// refuses gestures by name — never an empty table dressed as baseline.
func TestGrantsUnreadableTable(t *testing.T) {
	f := &fakeGrants{
		apps:   []grantApp{{Name: "PEND.ELF", SHA256: "aa", Caps: "file"}},
		readRC: -vi.ErrEACCES,
	}
	defer f.install(t)()
	events, restore := captureConsole(t)
	defer restore()
	v := grantsView{}
	v.Refresh()
	labels := strings.Join(v.Labels(), "\n")
	if !strings.Contains(labels, "granted=?") {
		t.Fatalf("labels: %s", labels)
	}
	if err := v.Grant("PEND.ELF"); err == nil {
		t.Fatal("gesture landed on an unreadable table")
	}
	joined := strings.Join(*events, "\n")
	if !strings.Contains(joined, "goset: grant refuse name=PEND.ELF eacces") {
		t.Fatalf("eacces gesture: %v", *events)
	}
}
