package main

import (
	"strconv"
	"strings"
	"testing"

	"virelai/settings"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

// M122e (#2574): the tab strip is the view picker — click a cell or step it
// with Left/Right while the strip is focused, and both land on showTab.
// Cell geometry is the test's contract with layout(): a click inside a
// cell's rect must hit that cell and no other.
func newStripPanel() *panel {
	a := newPanel(nil)
	a.tabs.R = widgets.Rect{X: 0, Y: 0, W: 544, H: 20}
	return a
}

func TestTabStripClickSwitchesViews(t *testing.T) {
	events, restore := captureConsole(t)
	defer restore()
	a := newStripPanel()
	f := &fakeServices{body: servicesFixture()}
	a.services = f.view(t)

	click := func(x, y int) {
		t.Helper()
		if !a.handle(vi.Event{Kind: vi.EvMouseDown, Flags: vi.BtnLeft, Arg0: uint32(x), Arg1: uint32(y)}) {
			t.Fatalf("click at %d,%d was not consumed", x, y)
		}
	}

	// Services is cell 1 of 6 over a 544px strip (~90px cells) — the click
	// focuses the strip and opens the pane; the marker names the view
	// that landed.
	click(140, 10)
	if !a.showServices || a.activeTab() != tabServices {
		t.Fatal("services tab click did not open the pane")
	}
	if current, _ := a.focus.Current(); current != &a.tabs {
		t.Fatal("the strip click did not take focus")
	}
	found := false
	for _, e := range *events {
		if e == markerTab+"services" {
			found = true
		}
	}
	if !found {
		t.Fatalf("no %q in %v", markerTab+"services", *events)
	}

	// Shortcuts is cell 3; the M128d profile view is cell 4 — its click
	// lands a refused session on the host (no vsock slot), which is still
	// a view landing. M165b's access view is the last cell (cell 5).
	click(310, 10)
	if !a.showChords || a.activeTab() != tabShortcuts {
		t.Fatal("shortcuts tab click did not open the registry view")
	}
	click(410, 10)
	if !a.showProfile || a.activeTab() != tabProfile {
		t.Fatal("profile tab click did not open the summary view")
	}
	click(60, 10)
	if a.activeTab() != tabSettings {
		t.Fatal("settings tab click did not return the pane")
	}
	// A click between the cells' labels is still inside a cell — the strip
	// owns its whole rect; a click outside it is nobody's.
	if a.tabs.tabAt(4, 30) != -1 {
		t.Fatal("tabAt hit below the strip")
	}
}

func TestTabStripKeyboardStepsViews(t *testing.T) {
	a := newStripPanel()
	f := &fakeServices{body: servicesFixture()}
	a.services = f.view(t)
	g := &fakeGrants{apps: []grantApp{{Name: "PEND.ELF", SHA256: "aa", Caps: "file"}}}
	defer g.install(t)()

	a.focus.Focus(0) // the strip
	for _, want := range []int{tabServices, tabGrants, tabShortcuts, tabProfile, tabAccess, tabSettings} {
		if !a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyRight}) {
			t.Fatalf("Right did not step the strip to %d", want)
		}
		if a.activeTab() != want {
			t.Fatalf("after Right: active tab %d, want %d", a.activeTab(), want)
		}
	}
	if !a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyLeft}) || a.activeTab() != tabAccess {
		t.Fatal("Left did not wrap back to the access pane")
	}
}

// A left-click on a settings row is the row's gesture: two-value rows
// toggle, vocabulary rows cycle forward, and a free-form key is selected
// with its typed path named — never a guessed value.
func TestRowClickCyclesAndToggles(t *testing.T) {
	a := newStripPanel()
	a.list = widgets.List{
		R:     widgets.Rect{X: 0, Y: 50, W: 544, H: 184},
		RowH:  18,
		Items: a.labels(),
	}

	clickRow := func(i int) {
		t.Helper()
		y := 50 + i*18 + 9 // row i's vertical middle below the strip
		if !a.handle(vi.Event{Kind: vi.EvMouseDown, Flags: vi.BtnLeft, Arg0: 100, Arg1: uint32(y)}) {
			t.Fatalf("row %d click was not consumed", i)
		}
	}

	// theme is a 4-value dropdown row: the click takes one step forward.
	clickRow(rowOf(t, a, "theme"))
	if v, _ := settings.Get(a.disp, "theme"); v != "light" {
		t.Fatalf("theme after row click = %q, want light", v)
	}
	if a.sel != rowOf(t, a, "theme") || a.list.Sel != a.sel {
		t.Fatal("the click did not select the row it cycled")
	}
	// shadow is an on|off toggle row: one click flips it.
	clickRow(rowOf(t, a, "shadow"))
	if v, _ := settings.Get(a.disp, "shadow"); v != "on" {
		t.Fatalf("shadow after row click = %q, want on", v)
	}
	// hostname is free text: click selects it and names the typed path —
	// the value is untouched because the panel does not guess a vocabulary.
	before, _ := settings.Get(a.disp, "hostname")
	clickRow(rowOf(t, a, "hostname"))
	if v, _ := settings.Get(a.disp, "hostname"); v != before {
		t.Fatalf("hostname changed to %q", v)
	}
	if !strings.Contains(a.status, "key=value") {
		t.Fatalf("free-form row click status = %q", a.status)
	}
	// A click on the tab strip never reaches the rows.
	if got := a.tabs.tabAt(60, 10); got != tabSettings {
		t.Fatalf("strip cell at (60,10) = %d", got)
	}
}

// The affordance glyphs still win their rect: a toggle row's control click
// is the same toggle the row-body click performs — one gesture, one write.
func TestRowAffordanceStillWinsItsRect(t *testing.T) {
	a := newStripPanel()
	a.list = widgets.List{
		R:     widgets.Rect{X: 0, Y: 50, W: 544, H: 184},
		RowH:  18,
		Items: a.labels(),
	}
	i := rowOf(t, a, "shadow")
	rr, ok := a.rowRect(i)
	if !ok {
		t.Fatal("shadow row not laid out")
	}
	tr := toggleRect(rr)
	x, y := tr.X+tr.W/2, tr.Y+tr.H/2
	if !a.handle(vi.Event{Kind: vi.EvMouseDown, Flags: vi.BtnLeft, Arg0: uint32(x), Arg1: uint32(y)}) {
		t.Fatal("toggle-glyph click was not consumed")
	}
	if v, _ := settings.Get(a.disp, "shadow"); v != "on" {
		t.Fatalf("shadow after toggle-glyph click = %q, want on", v)
	}
}

// Services rows toggle enabled on click — the click is the pane's gesture,
// same as Right on a selected service.
func TestServicesRowClickToggles(t *testing.T) {
	f := &fakeServices{body: servicesFixture()}
	a := newStripPanel()
	a.services = f.view(t)
	a.showTab(tabServices)
	a.list = widgets.List{
		R:     widgets.Rect{X: 0, Y: 50, W: 544, H: 184},
		RowH:  18,
		Items: a.labels(),
	}
	// probe sits at index 1, enabled=false in the fixture.
	y := 50 + 1*18 + 9
	if !a.handle(vi.Event{Kind: vi.EvMouseDown, Flags: vi.BtnLeft, Arg0: 100, Arg1: uint32(y)}) {
		t.Fatal("services row click was not consumed")
	}
	if a.sel != 1 || !a.services.manifest.Services[1].Enabled {
		t.Fatalf("services click: sel=%d enabled=%v", a.sel, a.services.manifest.Services[1].Enabled)
	}
	if f.writes != 0 {
		t.Fatal("a click toggles the in-memory manifest; Enter still publishes")
	}
}

// Grants rows land their consent gesture on click — the pane's per-gesture
// write is the click itself, same as Right on a selected entry.
func TestGrantsRowClickGrants(t *testing.T) {
	g := &fakeGrants{
		apps: []grantApp{{Name: "PEND.ELF", SHA256: "aa", Caps: "file,net"}},
	}
	defer g.install(t)()
	a := newStripPanel()
	a.showTab(tabGrants)
	a.list = widgets.List{
		R:     widgets.Rect{X: 0, Y: 50, W: 544, H: 184},
		RowH:  18,
		Items: a.labels(),
	}
	if !a.handle(vi.Event{Kind: vi.EvMouseDown, Flags: vi.BtnLeft, Arg0: 100, Arg1: 59}) {
		t.Fatal("grants row click was not consumed")
	}
	if len(g.writes) != 1 || !strings.Contains(g.writes[0], "PEND.ELF") {
		t.Fatalf("grants click writes = %v", g.writes)
	}
	// And the guard fixup: no settings affordance may answer a click while
	// a foreign pane is up — rowControlClick must refuse before the list.
	if a.rowControlClick(530, 59) {
		t.Fatal("a settings row control answered inside the grants pane")
	}
}

// Esc backs out one level: a sub-view pops to the Settings tab; on Settings
// it quits. An open popover eats Esc first (any key closes it — the M104f
// contract), and the panel neither pops nor quits on that stroke.
func TestEscapePopsSubViewThenQuits(t *testing.T) {
	a := newStripPanel()
	f := &fakeServices{body: servicesFixture()}
	a.services = f.view(t)

	a.showTab(tabServices)
	if !a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyEscape}) {
		t.Fatal("Esc on a sub-view was not consumed")
	}
	if a.exitRequested || a.activeTab() != tabSettings {
		t.Fatal("Esc must pop to the Settings tab, not quit")
	}
	if !a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyEscape}) || !a.exitRequested {
		t.Fatal("Esc on the Settings tab must quit")
	}

	// The popover's any-key-close runs before Esc's pop: a popover Esc is
	// a close, never a back-out.
	b := newStripPanel()
	b.dropdown.open = true
	if !b.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyEscape}) {
		t.Fatal("Esc on an open popover was not consumed")
	}
	if b.dropdown.open || b.exitRequested {
		t.Fatal("popover Esc must close the popover, not quit")
	}
}

// M128d (#2608): the profile view is read-only — the ctl seam's answer
// lands as rows and the marker, a refusal names its code as a row, and
// neither Enter nor Left/Right writes anything.
func TestProfileViewIsReadOnlySummary(t *testing.T) {
	events, restore := captureConsole(t)
	defer restore()
	old := ctlProfile
	defer func() { ctlProfile = old }()
	ctlProfile = func(verb, name string, code []byte) int64 {
		if verb != "profile-info" || name != "" {
			t.Fatalf("ctl call verb=%q name=%q", verb, name)
		}
		copy(code, `{"profile":"work","base":"disk.img","rollback":true,"snapshots":2}`)
		return 0
	}

	a := newStripPanel()
	a.showTab(tabProfile)
	wantRows := []string{"name = work", "base = disk.img", "rollback = yes", "snapshots = 2"}
	got := a.profileLabels()
	for i, w := range wantRows {
		if i >= len(got) || got[i] != w {
			t.Fatalf("profileLabels[%d] = %v, want %v", i, got, wantRows)
		}
	}
	found := false
	for _, e := range *events {
		if e == markerProfile+"name=work base=disk.img rollback=yes snaps=2" {
			found = true
		}
	}
	if !found {
		t.Fatalf("no profile marker in %v", *events)
	}
	// Enter is refused — a bare keypress on this surface writes nothing
	// and names the read-only verdict.
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg1: '\n'})
	if !strings.Contains(a.status, "read-only") {
		t.Fatalf("profile-tab Enter status = %q", a.status)
	}
	// A row click selects but never cycles.
	a.rowActivate(0)
	if !strings.Contains(a.status, "read-only") {
		t.Fatalf("profile row click status = %q", a.status)
	}

	// The typed `profile` line is the same switch as the strip cell.
	a.input.SetValue("profile")
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg1: '\n'})
	if a.activeTab() != tabProfile {
		t.Fatal("typed `profile` did not open the view")
	}

	// A refused session is still a row — the guest reads the code.
	ctlProfile = func(_, _ string, code []byte) int64 {
		return int64(copy(code, "no_credential"))
	}
	a.showTab(tabProfile)
	if got := a.profileLabels(); len(got) != 1 || got[0] != "profile-info refused no_credential" {
		t.Fatalf("refused profileLabels = %v", got)
	}
}

// Every view-switch surface lands the same marker and the same state —
// typed `services`, a strip click, and Esc's pop are one path.
func TestViewSwitchMarkerIsUniform(t *testing.T) {
	events, restore := captureConsole(t)
	defer restore()
	a := newStripPanel()
	f := &fakeServices{body: servicesFixture()}
	a.services = f.view(t)

	a.input.SetValue("services")
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg1: '\n'})
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyEscape})
	want := []string{markerTab + "services", markerTab + "settings"}
	for _, w := range want {
		found := false
		for _, e := range *events {
			if e == w {
				found = true
			}
		}
		if !found {
			t.Fatalf("no %q in %v", w, *events)
		}
	}
}

// M183a (#3171): a file past the old 24-row cap is one table to GOSET —
// the union plus the overflow rows all render (the unknown rows kept, not
// offered), the summary counts them, and the save path is bounded by the
// codec's cap, not by 24.
func TestOverflowTableListsEveryRowAndSavesWhole(t *testing.T) {
	a := newStripPanel()
	var rows []settings.Setting
	for _, k := range settings.KnownKeys {
		rows = append(rows, settings.Setting{Key: k.Name, Val: k.Default})
	}
	for _, group := range [][]settings.Key{
		settings.PaletteKeys, settings.FontKeys, settings.KeyboardLayoutKeys,
		settings.IdleKeys, settings.NotifyKeys, settings.NotifySoundKeys,
		settings.VolumeKeys, settings.TimezoneKeys, settings.DataRootKeys,
		settings.A11yKeys,
	} {
		for _, k := range group {
			rows = append(rows, settings.Setting{Key: k.Name, Val: k.Default})
		}
	}
	// The kernel accepts term_restart; the codec does not know it — a real
	// file can carry it, so the union does.
	rows = append(rows, settings.Setting{Key: "term_restart", Val: "stay"})
	if len(rows) != 24 {
		t.Fatalf("the known union is %d rows, want the pinned wave-5 census of 24", len(rows))
	}
	for i := 0; i < 8; i++ {
		rows = append(rows, settings.Setting{Key: "overflow" + strconv.Itoa(i), Val: "zz"})
	}
	a.disp = (settings.File{Rows: rows, State: settings.StateOK}).Display()
	if len(a.disp) != 32 {
		t.Fatalf("display = %d rows, want the whole 32-row table", len(a.disp))
	}
	if got := len(a.labels()); got != 32 {
		t.Fatalf("labels = %d, want one per row", got)
	}
	if got := a.summary(); got != "keys=32 wm=gotabwm theme=dark" {
		t.Fatalf("summary = %q", got)
	}
	// The unknown overflow rows render as kept — preserved, not editable.
	if lab := a.labels()[31]; !strings.Contains(lab, "overflow7") || !strings.Contains(lab, "(kept)") {
		t.Fatalf("overflow row label = %q", lab)
	}
	// A 32-row save is NOT refused at either the old or the new row cap: the
	// publish attempt runs and fails on the host's syscall seam — the status
	// names the attempt's rc, never the "settings full" refusal.
	a.save()
	if !strings.HasPrefix(a.status, "save failed rc=") {
		t.Fatalf("32-row save status = %q — the panel must not refuse at the cap", a.status)
	}
	// Past MaxKeys the codec's own named refusal stands.
	full := append([]settings.Setting(nil), a.disp...)
	for len(full) < settings.MaxKeys+1 {
		full = append(full, settings.Setting{Key: "pad" + strconv.Itoa(len(full)), Val: "v"})
	}
	a.disp = full
	a.save()
	if a.status != "settings full: the kernel cannot load this table whole" {
		t.Fatalf("over-cap save status = %q", a.status)
	}
}

// M165b (#2983): the access tab is the a11y surface — three rows with the
// file's value or the compiled default, a toggle, a toggle and a
// dropdown, and edits that land in the settings table like every other
// row. The text-scale row names its own reach.
func TestAccessTabShowsAndEditsTheA11yRows(t *testing.T) {
	events, restore := captureConsole(t)
	defer restore()
	a := newStripPanel()
	// The preview check needs a known base: pin dark + off, restore after.
	theme.Set("dark")
	theme.SetContrast(false)
	defer theme.SetContrast(false)

	a.showTab(tabAccess)
	if !a.showAccess || a.activeTab() != tabAccess {
		t.Fatal("access tab did not open")
	}
	found := false
	for _, e := range *events {
		if e == markerTab+"access" {
			found = true
		}
	}
	if !found {
		t.Fatalf("no %q in %v", markerTab+"access", *events)
	}

	// Three rows, effective defaults while the file carries none.
	if len(a.accessRows) != 3 || len(a.labels()) != 3 {
		t.Fatalf("access rows = %d labels = %d, want 3", len(a.accessRows), len(a.labels()))
	}
	for i, want := range []string{"a11y.contrast = off", "a11y.reduce_motion = off"} {
		if a.labels()[i] != want {
			t.Fatalf("label[%d] = %q, want %q", i, a.labels()[i], want)
		}
	}
	if a.labels()[2] != "a11y.text_scale = 100  (honoured by WEB)" {
		t.Fatalf("text-scale label = %q", a.labels()[2])
	}

	// The affordance per row: a toggle, a toggle and a dropdown.
	if rowControl(a.accessRows[0]) != ctlToggle {
		t.Fatal("a11y.contrast is not a toggle")
	}
	if rowControl(a.accessRows[1]) != ctlToggle {
		t.Fatal("a11y.reduce_motion is not a toggle")
	}
	if rowControl(a.accessRows[2]) != ctlDropdown {
		t.Fatal("a11y.text_scale is not a dropdown")
	}

	// Cycling row 0 writes the real settings row and mirrors it back.
	a.sel = 0
	if !a.cycle(1) {
		t.Fatal("contrast cycle refused")
	}
	if v, ok := settings.Get(a.disp, "a11y.contrast"); !ok || v != "high" {
		t.Fatalf("disp a11y.contrast = %q ok=%v, want high", v, ok)
	}
	if a.accessRows[0].Val != "high" {
		t.Fatalf("access mirror = %q, want high", a.accessRows[0].Val)
	}
	if theme.Current.Bg != theme.DarkHC.Bg {
		t.Fatal("the contrast write did not preview the high-contrast table")
	}

	// The dropdown row cycles its reserved rungs through the same path.
	a.sel = 2
	if !a.cycle(1) || a.accessRows[2].Val != "125" {
		t.Fatalf("text scale cycle -> %q, want 125", a.accessRows[2].Val)
	}
	if v, _ := settings.Get(a.disp, "a11y.text_scale"); v != "125" {
		t.Fatalf("disp a11y.text_scale = %q, want 125", v)
	}

	// A file row beats the default when the tab opens.
	a.showTab(tabSettings)
	a.disp = settings.Set(a.disp, "a11y.reduce_motion", "on")
	a.showTab(tabAccess)
	if a.accessRows[1].Val != "on" {
		t.Fatalf("reopen mirror = %q, want on", a.accessRows[1].Val)
	}

	// Esc pops to the Settings tab, the same as every other sub-view.
	if !a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyEscape}) || a.activeTab() != tabSettings {
		t.Fatal("Esc did not pop the access tab to Settings")
	}

	// The typed line is the same switch.
	a.input.SetValue("access")
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg1: '\n'})
	if a.activeTab() != tabAccess {
		t.Fatal("typed `access` did not open the tab")
	}
	// And a mistyped value is refused before it reaches the table.
	a.input.SetValue("a11y.contrast=ludicrous")
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg1: '\n'})
	if v, _ := settings.Get(a.disp, "a11y.contrast"); v == "ludicrous" {
		t.Fatal("a refused contrast value reached the table")
	}
}
