package main

import (
	"strings"
	"testing"
	"virelai/chords"
	"virelai/settings"
	"virelai/vi"
	"virelai/widgets"
)

// input_test.go — the event-dispatch half's pins: key/click handling,
// row cycling, the view switch and the shortcuts chord.

// Left/Right cycle the vocabularies the kernel declares; a free-text key is
// left alone rather than guessed at.
func TestPanelKeyboardUsesBoundedTextField(t *testing.T) {
	a := newPanel(nil)
	a.focus.Focus(2)
	for _, r := range []rune{'w', 'm', '=', 't'} {
		if !a.handle(vi.Event{Kind: vi.EvKeyDown, Arg1: uint32(r)}) {
			t.Fatalf("key %c was not accepted", r)
		}
	}
	if a.input.Value() != "wm=t" {
		t.Fatalf("field value = %q", a.input.Value())
	}
	if !a.handle(vi.Event{Kind: vi.EvKeyDown, Arg0: 0x50}) || a.input.CaretPosition() != 3 {
		t.Fatalf("left caret = %d", a.input.CaretPosition())
	}
	if !a.handle(vi.Event{Kind: vi.EvKeyDown, Arg1: 'a'}) || a.input.Value() != "wm=at" {
		t.Fatalf("mid insert = %q", a.input.Value())
	}
}

func TestPanelClickFocusesAndSelectsListRow(t *testing.T) {
	a := newPanel(nil)
	a.list = widgets.List{
		R:     widgets.Rect{X: 0, Y: 0, W: 100, H: 20},
		Items: []string{"one", "two"},
		RowH:  10,
	}
	if !a.handle(vi.Event{Kind: vi.EvMouseDown, Flags: vi.BtnLeft, Arg0: 1, Arg1: 11}) {
		t.Fatal("list click was not consumed")
	}
	if a.sel != 1 || a.list.Sel != 1 {
		t.Fatalf("click selected row %d (list %d), want 1", a.sel, a.list.Sel)
	}
}

func TestPanelCyclesOnlyKnownVocabularies(t *testing.T) {
	a := newPanel(nil)
	a.sel = rowOf(t, a, "wm")
	if !a.cycle(1) {
		t.Fatal("cycle(wm) reported no change")
	}
	if v, _ := settings.Get(a.disp, "wm"); v != "tabwm" {
		t.Fatalf("wm = %q after one step", v)
	}
	a.cycle(-1)
	if v, _ := settings.Get(a.disp, "wm"); v != "gotabwm" {
		t.Fatalf("wm = %q after the step back", v)
	}
	// M73m (#1662): the theme cycle is the PRESET chooser — the three
	// built-ins plus `custom`, four steps back to where it started.
	a.sel = rowOf(t, a, "theme")
	want := []string{"light", "amber", "custom", "dark"}
	for _, w := range want {
		a.cycle(1)
		if v, _ := settings.Get(a.disp, "theme"); v != w {
			t.Fatalf("theme cycle step: got %q, want %q", v, w)
		}
	}
	// hostname is free text: no vocabulary, no invented value.
	a.sel = rowOf(t, a, "hostname")
	before, _ := settings.Get(a.disp, "hostname")
	if !a.cycle(1) {
		t.Fatal("cycle(hostname) reported no change (the frame should repaint)")
	}
	if v, _ := settings.Get(a.disp, "hostname"); v != before {
		t.Fatalf("hostname changed to %q", v)
	}
}

// A corrupt file is refused wholesale: the panel names it, shows the compiled
// defaults that are therefore in force, and refuses every write.

// M80i (#1725): the font_size surface. A default panel has the kernel's
// eight rows plus keyboard_layout, idle_minutes, notify_dnd and timezone;
// font_size is typed input at any time and cycles small -> medium -> large
// once the row exists. The panel never fabricates the row: an ABSENT key is
// the boot look (text small + grid medium), which no single stored value can
// represent.
func TestFontSurfaceCyclesWithoutMovingKeys(t *testing.T) {
	a := newPanel(nil)
	want := len(settings.KnownKeys) + len(settings.KeyboardLayoutKeys) + len(settings.IdleKeys) +
		len(settings.NotifyKeys) + len(settings.TimezoneKeys)
	if len(a.disp) != want {
		t.Fatalf("default rows = %d, want %d (font_size is NOT a default row)", len(a.disp), want)
	}
	// Typed input applies (the accepted-not-seeded pattern)...
	a.input.SetValue("font_size=large")
	if !a.applyInput() {
		t.Fatal("applyInput reported no change")
	}
	if v, _ := settings.Get(a.disp, "font_size"); v != "large" {
		t.Fatalf("font_size = %q, want large", v)
	}
	if got := a.summary(); got != "keys=14 wm=gotabwm theme=dark" {
		t.Fatalf("summary = %q (the typed row is real, so the count grew)", got)
	}
	// ...the row is first-class (no "(kept)") and cyclable.
	for _, l := range a.labels() {
		if strings.HasPrefix(l, "font_size") && strings.Contains(l, "(kept)") {
			t.Fatalf("font_size row marked not-editable: %q", l)
		}
	}
	a.sel = rowOf(t, a, "font_size")
	a.cycle(1) // large wraps to small (the ladder's top)
	if v, _ := settings.Get(a.disp, "font_size"); v != "small" {
		t.Fatalf("font_size = %q after one step, want small (the wrap)", v)
	}
	a.cycle(1)
	if v, _ := settings.Get(a.disp, "font_size"); v != "medium" {
		t.Fatalf("font_size = %q after two steps, want medium", v)
	}
	// A value outside the vocabulary is still written verbatim (the
	// kernel's reader is the authority); cycling from it restarts at the
	// top rather than inventing a step.
	a.set("font_size", "bogus")
	a.cycle(1)
	if v, _ := settings.Get(a.disp, "font_size"); v != "small" {
		t.Fatalf("font_size = %q from outside the vocabulary, want small (the top)", v)
	}
}

// M82c (#1770): the panel's registered chord (ctrl+shift+h — a GOSET.ELF
// row in the global shortcuts registry; re-bound from ctrl+shift+s when
// M81g's snapshot arm claimed that chord first) flips between the settings
// table and the read-only shortcuts view, printing the view's marker after
// the table is in hand.
func TestShortcutsChordTogglesTheRegistryView(t *testing.T) {
	a := newPanel(nil)
	if a.showChords {
		t.Fatal("the panel starts on the settings table")
	}
	if !isShortcutsChord(vi.Event{Kind: vi.EvKeyDown,
		Flags: vi.ModCtrl | vi.ModShift, Arg0: uint32(chords.UsageH), Arg1: 0x08}) {
		t.Fatal("the ctrl+shift+h control-code spelling must be the chord")
	}
	if isShortcutsChord(vi.Event{Kind: vi.EvKeyDown, Flags: vi.ModCtrl, Arg1: 0x13}) {
		t.Fatal("plain ctrl+s (GOEDIT's save chord, another registry row) must not toggle the view")
	}
	if isShortcutsChord(vi.Event{Kind: vi.EvKeyDown, Flags: vi.ModCtrl | vi.ModShift, Arg0: uint32(chords.UsageS), Arg1: 0x13}) {
		t.Fatal("ctrl+shift+s is the seat's snapshot chord now — it must not toggle the view")
	}
	if !a.toggleShortcuts() {
		t.Fatal("toggleShortcuts consumed the chord")
	}
	if !a.showChords {
		t.Fatal("the view did not open")
	}
	if got := a.labels(); len(got) != len(chords.Global) {
		t.Fatalf("shortcuts view rows = %d, registry rows = %d", len(got), len(chords.Global))
	}
	if !a.toggleShortcuts() || a.showChords {
		t.Fatal("the view did not close")
	}
	if len(a.labels()) != len(a.disp) {
		t.Fatal("closing the view lost the settings rows")
	}
}

// M82c (#1770): the shortcuts view renders the registry, not the settings:
// the frozen kernel chrome, the seat's own rows and the app rows are all
// visible, and nothing in the view is editable or saveable.

// M82c (#1770): the shortcuts view renders the registry, not the settings:
// the frozen kernel chrome, the seat's own rows and the app rows are all
// visible, and nothing in the view is editable or saveable.
func TestShortcutsViewShowsTheRegistry(t *testing.T) {
	a := newPanel(nil)
	a.toggleShortcuts()
	labels := a.labels()
	find := func(prefix string) bool {
		for _, l := range labels {
			if strings.HasPrefix(l, prefix) {
				return true
			}
		}
		return false
	}
	for _, want := range []string{
		"ctrl+shift+k  kernel  ",    // frozen kernel chrome (M80k)
		"ctrl+shift+f  seat  ",      // the seat's freeze badge
		"ctrl+2  seat  ",            // the digit rows
		"ctrl+s  GOEDIT.ELF  ",      // an app row
		"ctrl+shift+h  GOSET.ELF  ", // this panel's own row (re-bound from ctrl+shift+s at the M81g rebase)
	} {
		if !find(want) {
			t.Errorf("shortcuts view missing a row starting %q", want)
		}
	}
	if a.headLabel() != "Shortcuts  n="+vi.Itoa64(int64(len(chords.Global)))+"  (one owner per chord)" {
		t.Fatalf("head label = %q", a.headLabel())
	}
	// Read-only: Enter and Save are refused by name in this view.
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg1: 0x0a}) // Enter (appkit maps it below; the guard sits before it)
	if a.showChords && !strings.Contains(a.status, "compiled in") {
		t.Fatalf("enter in the shortcuts view must name the read-only guard, got %q", a.status)
	}
	a.save()
	if !strings.Contains(a.status, "returns to Settings") {
		t.Fatalf("save in the shortcuts view must name the read-only guard, got %q", a.status)
	}
	if a.file.State != settings.StateMissing {
		t.Fatal("the view must not touch the settings file")
	}
}

// M83d2 (#1786): GOSET exposes the kernel's table selector, cycles US ↔ DE,
// accepts only shipped identifiers, and keeps the row editable on disk.

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
