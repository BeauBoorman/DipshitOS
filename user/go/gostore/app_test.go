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

// ---- M116c (#2469): install-time consent prompt ------------------------

// capsRow is a catalog row whose release declares ReleaseCaps — the
// install-time prompt's input.
func capsRow() store.CatalogRow {
	return store.CatalogRow{Stream: "caprel", Status: "release",
		Entry: &store.CatalogEntry{
			Stream: "caprel", Head: "h1", Publisher: "ab", PubState: "trusted",
			Rel: &store.Release{Name: "GRANTME", Version: "1.0.0",
				ELFSHA256:    strings.Repeat("ab", 32),
				Caps:         []string{"file", "memory", "process", "debug", "net"},
				ManifestRow: "GRANTME.ELF | Grant Me | g | dock=false"},
		}}
}

func installCapsRow(t *testing.T, a *app) {
	t.Helper()
	loadFn = func(store.FS, string, string, string, string, string) ([]store.CatalogRow, error) {
		return []store.CatalogRow{capsRow()}, nil
	}
	a.refresh()
	installFn = func(store.FS, string, string, string, string) int { return 0 }
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg1: 'i'})
}

func TestInstallCapsReleaseStandsPrompt(t *testing.T) {
	a, lines := testApp(t)
	installCapsRow(t, a)
	if a.pending == nil {
		t.Fatal("install of a caps release left no consent prompt")
	}
	if a.pending.bin != "GRANTME.ELF" ||
		a.pending.words != "file,memory,process,debug,net" {
		t.Fatalf("pending %+v", a.pending)
	}
	var got bool
	for _, l := range *lines {
		got = got || l == "gostore: consent name=GRANTME.ELF words=file,memory,process,debug,net"
	}
	if !got {
		t.Fatalf("consent marker missing in %v", *lines)
	}
}

func TestInstallNoCapsLeavesNoPrompt(t *testing.T) {
	a, _ := testApp(t)
	loadFn = func(store.FS, string, string, string, string, string) ([]store.CatalogRow, error) {
		return rowsFixture(), nil
	}
	a.refresh()
	installFn = func(store.FS, string, string, string, string) int { return 0 }
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg1: 'i'})
	if a.pending != nil {
		t.Fatalf("capless install left a prompt: %+v", a.pending)
	}
}

func TestConsentGrantWritesRow(t *testing.T) {
	a, lines := testApp(t)
	installCapsRow(t, a)
	var writes []string
	prev := grantWriteFn
	grantWriteFn = func(line string) int64 { writes = append(writes, line); return 0 }
	defer func() { grantWriteFn = prev }()

	a.key(vi.Event{Kind: vi.EvKeyDown, Arg1: 'g'})
	if a.pending != nil {
		t.Fatal("'g' did not answer the prompt")
	}
	want := "GRANTME.ELF\t" + strings.Repeat("ab", 32) + "\tfile,memory,process,debug,net"
	if len(writes) != 1 || writes[0] != want {
		t.Fatalf("writes=%v want [%q]", writes, want)
	}
	var got bool
	for _, l := range *lines {
		got = got || l == "gostore: grant written name=GRANTME.ELF words=file,memory,process,debug,net"
	}
	if !got {
		t.Fatalf("written marker missing in %v", *lines)
	}
}

func TestConsentGrantRefusedIsNamed(t *testing.T) {
	a, lines := testApp(t)
	installCapsRow(t, a)
	prev := grantWriteFn
	grantWriteFn = func(string) int64 { return -vi.ErrEACCES }
	defer func() { grantWriteFn = prev }()

	a.key(vi.Event{Kind: vi.EvKeyDown, Arg1: 'g'})
	var got bool
	for _, l := range *lines {
		got = got || l == "gostore: grant refuse name=GRANTME.ELF eacces"
	}
	if !got {
		t.Fatalf("refuse marker missing in %v", *lines)
	}
}

func TestConsentDenyWritesNothing(t *testing.T) {
	a, lines := testApp(t)
	installCapsRow(t, a)
	var writes int
	prev := grantWriteFn
	grantWriteFn = func(string) int64 { writes++; return 0 }
	defer func() { grantWriteFn = prev }()

	a.key(vi.Event{Kind: vi.EvKeyDown, Arg1: 'd'})
	if a.pending != nil {
		t.Fatal("'d' did not answer the prompt")
	}
	if writes != 0 {
		t.Fatalf("denial wrote %d rows", writes)
	}
	var got bool
	for _, l := range *lines {
		got = got || l == "gostore: grant declined name=GRANTME.ELF"
	}
	if !got {
		t.Fatalf("declined marker missing in %v", *lines)
	}
}

func TestConsentEscapeDeclines(t *testing.T) {
	a, lines := testApp(t)
	installCapsRow(t, a)
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyEscape})
	if a.pending != nil {
		t.Fatal("escape did not answer the prompt")
	}
	if a.quit {
		t.Fatal("escape answered consent AND quit — the prompt must swallow it")
	}
	var got bool
	for _, l := range *lines {
		got = got || l == "gostore: grant declined name=GRANTME.ELF"
	}
	if !got {
		t.Fatalf("declined marker missing in %v", *lines)
	}
}

func TestConsentPromptIsModal(t *testing.T) {
	a, _ := testApp(t)
	installCapsRow(t, a)
	// 'q' while the prompt stands must not quit — the ask is answered
	// or it stands.
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg1: 'q'})
	if a.quit {
		t.Fatal("prompt did not swallow 'q'")
	}
	if a.pending == nil {
		t.Fatal("'q' answered the prompt")
	}
}

// M188c (#3188): 'p' drives store.Pin on the selected row's release name
// with an empty selector — the verb picks the prior signed head itself.
func TestPinTargetsReleaseName(t *testing.T) {
	a, lines := testApp(t)
	loadFn = func(store.FS, string, string, string, string, string) ([]store.CatalogRow, error) {
		return rowsFixture(), nil
	}
	a.refresh()
	var gotName, gotSel, gotRemote, gotChannel string
	pinFn = func(fs store.FS, root, name, sel, remote, channel string) int {
		gotName, gotSel, gotRemote, gotChannel = name, sel, remote, channel
		return 0
	}
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg1: 'p'})
	if gotName != "GOHELLO" || gotSel != "" || gotRemote != a.remote || gotChannel != a.channel {
		t.Fatalf("pin(%q,%q,%q,%q)", gotName, gotSel, gotRemote, gotChannel)
	}
	var start, done bool
	for _, l := range *lines {
		start = start || l == "gostore: pin GOHELLO"
		done = done || l == "gostore: pin rc=0"
	}
	if !start || !done {
		t.Fatalf("pin op markers missing in %v", *lines)
	}
}
