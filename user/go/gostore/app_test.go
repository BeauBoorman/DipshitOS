package main

import (
	"strings"
	"testing"

	"virelai/store"
	"virelai/vi"
)

type fakeRepaint struct{ n int }

// testApp wires a model with recorded seams.
func testApp(t *testing.T) (*app, *[]string) {
	t.Helper()
	lines := []string{}
	prevConsole, prevSleep := consoleFn, sleepFn
	consoleFn = func(s string) { lines = append(lines, s) }
	sleepFn = func(uint64) {}
	t.Cleanup(func() { consoleFn, sleepFn = prevConsole, prevSleep })
	a := &app{remote: "10.0.0.2:4750", channel: "/host/DROP"}
	return a, &lines
}

func rowsFixture() []store.CatalogRow {
	return []store.CatalogRow{
		{Stream: "main", Status: "no-release"},
		{Stream: "rel", Status: "release", Entry: &store.CatalogEntry{
			Stream: "rel", Head: "h1", Publisher: "ab", PubState: "trusted", PubLabel: "sync-seed",
			Rel: &store.Release{Name: "GOHELLO", Version: "1.0.0", Category: "demo",
				Summary: "hi", ManifestRow: "GOHELLO.ELF | Go Hello | g | dock=false"},
		}},
		{Stream: "badkey", Status: "sync-failed"},
		{Stream: "revkey", Status: "sync-failed"},
	}
}

func TestRefreshPopulatesRowsAndSelectsFirstActionable(t *testing.T) {
	a, lines := testApp(t)
	loadFn = func(store.FS, string, string, string, string, string) ([]store.CatalogRow, error) {
		return rowsFixture(), nil
	}
	a.refresh()
	if len(a.rows) != 4 {
		t.Fatalf("rows=%d want 4", len(a.rows))
	}
	if a.sel != 1 {
		t.Fatalf("sel=%d want 1 (rel, first actionable)", a.sel)
	}
	var listDone, rowRel, rowBadkey bool
	for _, l := range *lines {
		listDone = listDone || l == "gostore: list rows=4"
		rowRel = rowRel || l == "gostore: stream rel release"
		rowBadkey = rowBadkey || l == "gostore: stream badkey sync-failed"
	}
	if !listDone || !rowRel || !rowBadkey {
		t.Fatalf("missing markers in %v", *lines)
	}
}

func TestRefreshRefusalShownByName(t *testing.T) {
	a, lines := testApp(t)
	loadFn = func(store.FS, string, string, string, string, string) ([]store.CatalogRow, error) {
		return nil, &store.RefuseError{Code: "keyring_missing"}
	}
	a.refresh()
	var got bool
	for _, l := range *lines {
		got = got || l == "gostore: refuse keyring_missing"
	}
	if !got {
		t.Fatalf("refusal not shown by name in %v", *lines)
	}
}

func TestSearchInputAppliesOnEnter(t *testing.T) {
	a, _ := testApp(t)
	var gotSearch string
	loadFn = func(fs store.FS, root, remote, channel, search, category string) ([]store.CatalogRow, error) {
		gotSearch = search
		return rowsFixture(), nil
	}
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: '/', Arg1: '/'})
	if !a.inputOn {
		t.Fatal("/ did not open the search input")
	}
	for _, ch := range "gohello" {
		a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: 4, Arg1: uint32(ch)})
	}
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyEnter, Arg1: '\n'})
	if a.inputOn {
		t.Fatal("enter did not close the search input")
	}
	if gotSearch != "gohello" {
		t.Fatalf("search=%q want gohello", gotSearch)
	}
}

func TestInstallDrivesSelectedStream(t *testing.T) {
	a, lines := testApp(t)
	loadFn = func(store.FS, string, string, string, string, string) ([]store.CatalogRow, error) {
		return rowsFixture(), nil
	}
	a.refresh()
	var gotStream, gotRemote, gotChannel string
	installFn = func(fs store.FS, root, stream, remote, channel string) int {
		gotStream, gotRemote, gotChannel = stream, remote, channel
		return 0
	}
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: 'i' - 0x60, Arg1: 'i'})
	if gotStream != "rel" || gotRemote != a.remote || gotChannel != a.channel {
		t.Fatalf("install(%q,%q,%q)", gotStream, gotRemote, gotChannel)
	}
	var start, done bool
	for _, l := range *lines {
		start = start || l == "gostore: install rel"
		done = done || l == "gostore: install rc=0"
	}
	if !start || !done {
		t.Fatalf("op markers missing in %v", *lines)
	}
	if !a.rows[1].Installed {
		t.Fatal("install rc=0 did not set the installed badge")
	}
}

func TestInstallOnSyncFailedStreamStillRuns(t *testing.T) {
	a, _ := testApp(t)
	loadFn = func(store.FS, string, string, string, string, string) ([]store.CatalogRow, error) {
		return rowsFixture(), nil
	}
	a.refresh()
	a.sel = 2 // badkey
	var gotStream string
	installFn = func(fs store.FS, root, stream, remote, channel string) int {
		gotStream = stream
		return 1
	}
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg1: 'i'})
	if gotStream != "badkey" {
		t.Fatalf("install stream=%q want badkey", gotStream)
	}
	if a.rows[2].Installed {
		t.Fatal("rc=1 op must not set the installed badge")
	}
}

func TestUpdateTargetsReleaseName(t *testing.T) {
	a, _ := testApp(t)
	loadFn = func(store.FS, string, string, string, string, string) ([]store.CatalogRow, error) {
		return rowsFixture(), nil
	}
	a.refresh()
	var gotName string
	updateFn = func(fs store.FS, root, name, remote, channel string) int {
		gotName = name
		return 0
	}
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg1: 'u'})
	if gotName != "GOHELLO" {
		t.Fatalf("update target=%q want GOHELLO (the release name)", gotName)
	}
}

func TestTeeMirrorsRefusalIntoGostoreNamespace(t *testing.T) {
	a, lines := testApp(t)
	a.tee("store: refuse elf_mismatch GOHELLO.ELF")
	var got bool
	for _, l := range *lines {
		got = got || l == "gostore: refuse elf_mismatch GOHELLO.ELF"
	}
	if !got {
		t.Fatalf("tee did not emit the gostore: refusal in %v", *lines)
	}
}

func TestLegMarkerAndKillAtPause(t *testing.T) {
	a, lines := testApp(t)
	a.killAt = "prev"
	slept := 0
	sleepFn = func(uint64) {
		slept++
		if slept > 1 {
			panic("pause-held")
		}
	}
	func() {
		defer func() {
			if r := recover(); r != "pause-held" {
				t.Fatalf("pause did not hold: %v", r)
			}
		}()
		a.onLeg("prev")
	}()
	var leg, pause bool
	for _, l := range *lines {
		leg = leg || l == "gostore: leg prev"
		pause = pause || l == "gostore: pause prev"
	}
	if !leg || !pause {
		t.Fatalf("leg/pause markers missing in %v", *lines)
	}
}

func TestEscDetailThenQuit(t *testing.T) {
	a, _ := testApp(t)
	loadFn = func(store.FS, string, string, string, string, string) ([]store.CatalogRow, error) {
		return rowsFixture(), nil
	}
	a.refresh()
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyEnter, Arg1: '\n'})
	if !a.detail {
		t.Fatal("enter did not open the detail card")
	}
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyEscape})
	if a.detail {
		t.Fatal("esc did not close the detail card")
	}
	if a.quit {
		t.Fatal("esc quit while a detail card was open")
	}
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyEscape})
	if !a.quit {
		t.Fatal("esc on the list did not request quit")
	}
}

func TestRowLineRendersStatuses(t *testing.T) {
	fix := rowsFixture()
	if !strings.Contains(rowLine(&fix[1]), "GOHELLO") ||
		!strings.Contains(rowLine(&fix[1]), "trusted") {
		t.Fatalf("release row: %q", rowLine(&fix[1]))
	}
	if rowLine(&fix[2]) != "badkey   sync-failed" {
		t.Fatalf("sync-failed row: %q", rowLine(&fix[2]))
	}
	fix[1].Status = "catalog-invalid"
	fix[1].Refusal = "release_mismatch"
	if !strings.Contains(rowLine(&fix[1]), "release_mismatch") {
		t.Fatalf("invalid row: %q", rowLine(&fix[1]))
	}
}

func TestDetailLinesRenderCardFields(t *testing.T) {
	fix := rowsFixture()
	fix[1].Installed = true
	lines := detailLines(&fix[1])
	joined := strings.Join(lines, "\n")
	for _, want := range []string{
		"name GOHELLO", "version 1.0.0", "category demo",
		"publisher_name=sync-seed", "publisher_state=trusted",
		"installed yes", "row GOHELLO.ELF | Go Hello | g | dock=false",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("detail card missing %q in\n%s", want, joined)
		}
	}
}
