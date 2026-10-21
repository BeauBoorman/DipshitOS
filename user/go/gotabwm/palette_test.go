package main

import (
	"testing"

	"virelai/chords"
	"virelai/settings"
	"virelai/vi"
)

// stubPaletteSources empties the host-only sources the guest would read
// (the recent log's share file, the docs bundle) so a test controls the
// catalog's contents exactly.
func stubPaletteSources(t *testing.T, recents string, docs []vi.DirEntry) {
	t.Helper()
	oldRead, oldDir, oldSet := readAppsFile, paletteDirList, paletteSettings
	readAppsFile = func(path string, max int) ([]byte, int64) {
		switch path {
		case vi.RecentLogPath:
			if recents == "" {
				return nil, -vi.ErrENOENT
			}
			return []byte(recents), 0
		case appsPath:
			return []byte("GOCALC.ELF | Calc | c\n"), 0
		}
		return nil, -vi.ErrENOENT
	}
	paletteDirList = func(path string, buf []vi.DirEntry) (int, int64) {
		copy(buf, docs)
		return len(docs), 0
	}
	paletteSettings = func() settings.File {
		return settings.File{State: settings.StateMissing}
	}
	t.Cleanup(func() {
		readAppsFile, paletteDirList, paletteSettings = oldRead, oldDir, oldSet
	})
}

func paletteKey(usage uint8) vi.Event {
	return vi.Event{Kind: vi.EvWmKey, Arg0: uint32(usage)}
}

func paletteChord() vi.Event {
	return vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl | vi.ModShift, Arg0: uint32(hidUsageP)}
}

// TestPaletteSummonsFromTheRegistryChord: ctrl+shift+p dispatches through
// the table's "palette" row — the same walk every other seat chord takes.
func TestPaletteSummonsFromTheRegistryChord(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	stubPaletteSources(t, "", nil)
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}
	tabs.OpenTab(3, "Calc")

	launch = launcherState{}
	handleWmKey(paletteChord())
	if !launch.open || !launch.palette {
		t.Fatal("ctrl+shift+p did not open the palette")
	}
	var tabsN, settingsN, chordsN int
	for _, e := range launch.results {
		switch e.kind {
		case palTab:
			tabsN++
		case palSetting:
			settingsN++
		case palChord:
			chordsN++
		}
	}
	if tabsN != 1 || settingsN == 0 || chordsN != len(chords.Global) {
		t.Fatalf("sources: tabs=%d settings=%d chords=%d", tabsN, settingsN, chordsN)
	}
}

// TestPaletteRankSettAndEdit is the card's go-wm-seat leg: 'sett' must
// reach a Settings row (whose Enter launches GOSET) and 'edit' must reach
// an open Edit tab (whose Enter focuses it).
func TestPaletteRankSettAndEdit(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	stubPaletteSources(t, "", nil)
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}
	tabs.OpenTab(3, "Calc")
	tabs.OpenTab(4, "Edit")

	launch = launcherState{}
	openPalette()
	launch.filter = "sett"
	launch.refresh()
	e, ok := launch.selectedPalette()
	if !ok || e.kind != palSetting {
		t.Fatalf("'sett' selected %+v ok=%v, want a Settings row", e, ok)
	}
	launch.filter = "edit"
	launch.refresh()
	e, ok = launch.selectedPalette()
	if !ok || e.kind != palTab || e.id != 4 || e.label != "Edit" {
		t.Fatalf("'edit' selected %+v ok=%v, want the Edit tab", e, ok)
	}
}

// TestPaletteEnterExecsTheSettingsPanel: Enter on a Settings row launches
// GOSET.ELF through the same exec seam the launcher uses, and closes.
func TestPaletteEnterExecsTheSettingsPanel(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	stubPaletteSources(t, "", nil)
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}

	launch = launcherState{}
	openPalette()
	launch.filter = "sett"
	launch.refresh()
	var got []string
	oldExec := execApp
	execApp = func(bin string, args ...string) (int64, error) {
		got = append(got, bin)
		return 42, nil
	}
	defer func() { execApp = oldExec }()
	paletteExecSelected()
	if launch.open {
		t.Fatal("a successful palette exec must close the strip")
	}
	if len(got) != 1 || got[0] != "GOSET.ELF" {
		t.Fatalf("execs = %v, want [GOSET.ELF]", got)
	}
}

// TestPaletteEnterFocusesTheTab: Enter on a tab row focuses it through the
// focusHosted seam — the palette's 'edit' leg.
func TestPaletteEnterFocusesTheTab(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	stubPaletteSources(t, "", nil)
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}
	tabs.OpenTab(3, "Calc")
	tabs.OpenTab(4, "Edit")

	oldFocus := paletteFocus
	var focused uint32
	paletteFocus = func(id uint32) bool { focused = id; return true }
	defer func() { paletteFocus = oldFocus }()

	launch = launcherState{}
	openPalette()
	launch.filter = "edit"
	launch.refresh()
	paletteExecSelected()
	if launch.open {
		t.Fatal("a tab pick must close the strip")
	}
	if focused != 4 {
		t.Fatalf("focused = %d, want the Edit tab's id 4", focused)
	}
}

// TestPaletteRecentFileOpensInTheEditor: the vi recent log's newest row is
// a result, and Enter carries its path to GOEDIT's argv.
func TestPaletteRecentFileOpensInTheEditor(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	// 1|delete|<16-hex id>|hex("/host/EDIT/SEED.TXT")
	hexPath := ""
	for _, c := range "/host/EDIT/SEED.TXT" {
		const hexd = "0123456789abcdef"
		hexPath += string([]byte{hexd[c>>4], hexd[c&0xf]})
	}
	stubPaletteSources(t, "100|delete|0123456789abcdef|"+hexPath+"\n", nil)
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}

	launch = launcherState{}
	openPalette()
	launch.filter = "seed"
	launch.refresh()
	e, ok := launch.selectedPalette()
	if !ok || e.kind != palRecent || e.arg != "/host/EDIT/SEED.TXT" {
		t.Fatalf("'seed' selected %+v ok=%v, want the recent file", e, ok)
	}
	var gotBin, gotArg string
	oldExec := execApp
	execApp = func(bin string, args ...string) (int64, error) {
		gotBin = bin
		if len(args) > 0 {
			gotArg = args[0]
		}
		return 42, nil
	}
	defer func() { execApp = oldExec }()
	paletteExecSelected()
	if gotBin != "GOEDIT.ELF" || gotArg != "/host/EDIT/SEED.TXT" {
		t.Fatalf("exec = %s %q, want GOEDIT.ELF /host/EDIT/SEED.TXT", gotBin, gotArg)
	}
}

// TestPaletteChordRowRunsTheSeatAction: a seat chord row Enter runs the
// row's action — "pin" here, with the palette already closed so the
// action acts on the desktop's focused tab.
func TestPaletteChordRowRunsTheSeatAction(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	stubPaletteSources(t, "", nil)
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}
	tabs.OpenTab(3, "Calc")
	tabs.FocusTab(3)

	launch = launcherState{}
	openPalette()
	launch.filter = "pin the focused"
	launch.refresh()
	e, ok := launch.selectedPalette()
	if !ok || e.kind != palChord || e.action != "pin" {
		t.Fatalf("selected %+v ok=%v, want the pin chord row", e, ok)
	}
	paletteExecSelected()
	if launch.open {
		t.Fatal("a chord pick must close the strip")
	}
	if !tabs.At(0).Pinned {
		t.Fatal("the pin action did not run against the focused tab")
	}
}

// TestPaletteNonSeatChordOpensThePanel: a kernel/app chord row is not
// dispatchable by the seat — Enter opens GOSET's shortcuts view instead.
func TestPaletteNonSeatChordOpensThePanel(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	stubPaletteSources(t, "", nil)
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}

	launch = launcherState{}
	openPalette()
	launch.filter = "soft reset the terminal"
	launch.refresh()
	e, ok := launch.selectedPalette()
	if !ok || e.kind != palChord || e.action != "" {
		t.Fatalf("selected %+v ok=%v, want a non-seat chord row", e, ok)
	}
	var got string
	oldExec := execApp
	execApp = func(bin string, args ...string) (int64, error) {
		got = bin
		return 42, nil
	}
	defer func() { execApp = oldExec }()
	paletteExecSelected()
	if got != "GOSET.ELF" {
		t.Fatalf("exec = %q, want GOSET.ELF (the registry viewer)", got)
	}
}

// TestPaletteChordTogglesDismiss: the summon chord is a toggle in both
// directions — open while closed, dismiss while open.
func TestPaletteChordTogglesDismiss(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	stubPaletteSources(t, "", nil)
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}

	launch = launcherState{}
	handleWmKey(paletteChord())
	if !launch.open || !launch.palette {
		t.Fatal("summon failed")
	}
	handleWmKey(paletteChord())
	if launch.open {
		t.Fatal("ctrl+shift+p while open must dismiss")
	}
}

// TestPaletteCrossesFromTheLauncher: ctrl+shift+p over an open launcher
// swaps the strip's contents to the palette without dropping the sink.
func TestPaletteCrossesFromTheLauncher(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	stubPaletteSources(t, "", nil)
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}

	launch = launcherState{}
	openLauncher()
	if !launch.open || launch.palette || launch.sink == 0 {
		t.Fatal("launcher open failed")
	}
	sink := launch.sink
	handleWmKey(paletteChord())
	if !launch.open || !launch.palette || launch.sink != sink {
		t.Fatal("cross-over must keep the modal sink and swap the catalog")
	}
	// And back: ctrl+space over the palette restores the launcher face.
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: uint32(hidUsageSpace)})
	if !launch.open || launch.palette || launch.sink != sink {
		t.Fatal("ctrl+space over the palette must swap back to the launcher")
	}
}

// TestPaletteEscapeTwoStep: the launcher's Esc discipline applies —
// non-empty filter clears first, empty filter dismisses.
func TestPaletteEscapeTwoStep(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	resetNotify(t)
	stubPaletteSources(t, "", nil)
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}

	launch = launcherState{}
	openPalette()
	launch.filter = "sett"
	launch.refresh()
	handleWmKey(paletteKey(hidUsageEscape))
	if !launch.open || launch.filter != "" {
		t.Fatal("first Esc must clear the filter, not dismiss")
	}
	handleWmKey(paletteKey(hidUsageEscape))
	if launch.open {
		t.Fatal("second Esc must dismiss")
	}
}

// TestPaletteRpcKindSummons: the WM_RPC kind-19 request opens the palette
// — the additive kind the card adds for app-side summons.
func TestPaletteRpcKindSummons(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	stubPaletteSources(t, "", nil)
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}

	launch = launcherState{}
	req := vi.WmRpc{Kind: wmKindPalette, ID: 4}
	if !applyRPC(req) {
		t.Fatal("kind-19 request must apply")
	}
	if !launch.open || !launch.palette {
		t.Fatal("kind-19 did not open the palette")
	}
}

// TestPaletteHexDecode pins the recent-log path column's decode.
func TestPaletteHexDecode(t *testing.T) {
	got, ok := paletteHexDecode("2f686f73742f454449542e545854")
	if !ok || got != "/host/EDIT.TXT" {
		t.Fatalf("hex decode = %q ok=%v", got, ok)
	}
	for _, bad := range []string{"", "0", "zz", "2f6"} {
		if _, ok := paletteHexDecode(bad); ok {
			t.Fatalf("bad hex %q must be refused", bad)
		}
	}
}

// M151b (#2913): "Switch to space N" rows sit beside the move rows — one
// per dormant space, none for the live one, and none needing a focused
// tab. Enter on one runs spaceSwitchTo with the palette already closed.
func TestPaletteSwitchSpaceRows(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	stubPaletteSources(t, "", nil)
	resetSpaces()
	tabs = TabStrip{}
	tabs.OpenTab(3, "Calc")
	tabs.FocusTab(3)
	spaceEnsure("2")
	spaceEnsure("3")
	_, restoreVis := visRecorder()
	defer restoreVis()

	launch = launcherState{}
	openPalette()
	var switches, moves int
	for _, e := range launch.results {
		switch e.kind {
		case palSwitch:
			switches++
			if e.label != "Switch to space "+e.arg {
				t.Fatalf("row label %q arg %q", e.label, e.arg)
			}
		case palSpace:
			moves++
		}
	}
	// The two dormant spaces get a switch row each; the live space has
	// none. The move rows are untouched: 2 dormant + the next-slot
	// "Move ... to new space 4" create row.
	if switches != 2 || moves != 3 {
		t.Fatalf("catalog: switches=%d moves=%d want 2/3", switches, moves)
	}
	launch.filter = "switch to space 3"
	launch.refresh()
	e, ok := launch.selectedPalette()
	if !ok || e.kind != palSwitch || e.arg != "3" {
		t.Fatalf("'switch to space 3' selected %+v ok=%v", e, ok)
	}
	paletteExecSelected()
	if launch.open {
		t.Fatal("a switch pick must close the palette")
	}
	if spaceCur != 2 {
		t.Fatalf("switch landed cur=%d want 2 (space %q)", spaceCur, spaces[2].Name)
	}
	if tabs.Count() != 0 {
		t.Fatal("space 3's strip must be the empty live strip")
	}
	if spaces[0].Strip.Count() != 1 || spaces[0].Strip.At(0).ID != 3 {
		t.Fatal("space 1's strip did not park")
	}
}

// M151b (#2913): the switch rows exist on an EMPTY strip too — a switch
// needs no focused tab, so the rows are the keyboard's only jump while
// the live space holds nothing to move.
func TestPaletteSwitchRowsOnEmptyStrip(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	stubPaletteSources(t, "", nil)
	resetSpaces()
	tabs = TabStrip{}
	spaceEnsure("2")

	launch = launcherState{}
	openPalette()
	var switches, moves int
	for _, e := range launch.results {
		switch e.kind {
		case palSwitch:
			switches++
		case palSpace:
			moves++
		}
	}
	if switches != 1 || moves != 0 {
		t.Fatalf("empty strip: switches=%d moves=%d want 1/0", switches, moves)
	}
}
