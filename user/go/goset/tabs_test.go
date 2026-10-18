package main

import (
	"strings"
	"testing"

	"virelai/settings"
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

	// Services is cell 1 of 4 over a 544px strip — the click focuses the
	// strip and opens the pane; the marker names the view that landed.
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

	// Shortcuts is the last cell; Settings is cell 0 and takes the pane back.
	click(500, 10)
	if !a.showChords || a.activeTab() != tabShortcuts {
		t.Fatal("shortcuts tab click did not open the registry view")
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
	for _, want := range []int{tabServices, tabGrants, tabShortcuts, tabSettings} {
		if !a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyRight}) {
			t.Fatalf("Right did not step the strip to %d", want)
		}
		if a.activeTab() != want {
			t.Fatalf("after Right: active tab %d, want %d", a.activeTab(), want)
		}
	}
	if !a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyLeft}) || a.activeTab() != tabShortcuts {
		t.Fatal("Left did not wrap back to the shortcuts pane")
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
