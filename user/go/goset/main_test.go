package main

import (
	"strings"
	"testing"

	"virelai/chords"
	"virelai/settings"
	"virelai/vi"
	"virelai/widgets"
)

// The panel's markers are gate grep targets: pin the exact shapes so a drift is
// a host-test failure instead of a silent live miss.
func TestPanelMarkerShapes(t *testing.T) {
	want := map[string]string{
		markerOpen:     "goset: open id=",
		markerDeclare:  "goset: declare accepted",
		markerBad:      "goset: settings bad",
		markerReady:    "goset: ready ",
		markerSet:      "goset: set ",
		markerDiscard:  "goset: discard ",
		markerSaved:    "goset: saved ",
		markerNotified: "goset: settings notified key=",
		markerRefused:  "goset: save refused",
		markerSaveFail: "goset: save failed rc=",
		markerPresent:  "goset: present",
		markerClose:    "goset: close",
		markerOK:       "goset OK",
	}
	for got, expect := range want {
		if got != expect {
			t.Fatalf("marker %q, want %q", got, expect)
		}
	}
}

func TestChangedSettingKeysIgnoresMaterializedDefaults(t *testing.T) {
	before := settings.File{State: settings.StateMissing}
	after := settings.File{
		State: settings.StateOK,
		Rows:  settings.File{State: settings.StateMissing}.Display(),
	}
	if got := changedSettingKeys(before, after); len(got) != 0 {
		t.Fatalf("materialized defaults reported changed keys: %v", got)
	}
	after.Rows = settings.Set(after.Rows, "theme", "light")
	got := changedSettingKeys(before, after)
	if len(got) != 1 || got[0] != "theme" {
		t.Fatalf("changed keys = %v, want [theme]", got)
	}
}

// A panel on a share with no settings file starts from the table IN FORCE: the
// compiled defaults, so `wm` is visible and settable (card D2) even though the
// file has never carried it.
func TestPanelStartsWithTheTableInForce(t *testing.T) {
	a := newPanel(nil)
	if a.file.State != settings.StateMissing {
		t.Fatalf("host decode state = %d, want StateMissing (no file on the host)", a.file.State)
	}
	if v, ok := settings.Get(a.disp, "wm"); !ok || v != "gotabwm" {
		t.Fatalf("wm = %q ok=%v, want the compiled default", v, ok)
	}
	if a.mode() != "rw" {
		t.Fatalf("mode = %q, want rw", a.mode())
	}
	if got := a.summary(); got != "keys=13 wm=gotabwm theme=dark" {
		t.Fatalf("summary = %q", got)
	}
	if v, ok := settings.Get(a.disp, "keyboard_layout"); !ok || v != "us" {
		t.Fatalf("keyboard_layout = %q ok=%v, want the compiled default", v, ok)
	}
	if v, ok := settings.Get(a.disp, "idle_minutes"); !ok || v != "5" {
		t.Fatalf("idle_minutes = %q ok=%v, want the compiled default", v, ok)
	}
	if v, ok := settings.Get(a.disp, "notify_dnd"); !ok || v != "off" {
		t.Fatalf("notify_dnd = %q ok=%v, want the compiled default", v, ok)
	}
	if v, ok := settings.Get(a.disp, "timezone"); !ok || v != "UTC" {
		t.Fatalf("timezone = %q ok=%v, want the compiled default", v, ok)
	}
	if len(a.labels()) != len(a.disp) {
		t.Fatalf("labels = %d, rows = %d", len(a.labels()), len(a.disp))
	}
}

// M82d2 (#1785): the do-not-disturb row is a first-class, cyclable on|off row
// and a typed value outside that vocabulary never reaches the table, because
// the seat would read it as off while the panel showed something else.
func TestNotifyDNDRowCyclesAndValidatesBeforeSave(t *testing.T) {
	a := newPanel(nil)
	i := rowOf(t, a, "notify_dnd")
	if strings.Contains(a.labels()[i], "(kept)") {
		t.Fatalf("notify_dnd row is not editable: %q", a.labels()[i])
	}
	a.sel = i
	a.cycle(1)
	if got, _ := settings.Get(a.disp, "notify_dnd"); got != "on" {
		t.Fatalf("cycling off gave notify_dnd = %q, want on", got)
	}
	a.cycle(1)
	if got, _ := settings.Get(a.disp, "notify_dnd"); got != "off" {
		t.Fatalf("second cycle = %q, want off", got)
	}
	for _, val := range []string{"true", "1", "ON", "", "yes"} {
		a.input.SetValue("notify_dnd=" + val)
		a.applyInput()
		if got, _ := settings.Get(a.disp, "notify_dnd"); got != "off" {
			t.Fatalf("invalid %q changed notify_dnd to %q", val, got)
		}
	}
	a.input.SetValue("notify_dnd=on")
	a.applyInput()
	if got, _ := settings.Get(a.disp, "notify_dnd"); got != "on" {
		t.Fatalf("typed notify_dnd = %q, want on", got)
	}
	if got := changedSettingKeys(settings.File{State: settings.StateMissing}, settings.File{Rows: a.disp, State: settings.StateOK}); len(got) != 1 || got[0] != "notify_dnd" {
		t.Fatalf("change notification keys = %v, want notify_dnd", got)
	}
}

// The typed line is the path the gate drives. Only a key the kernel table
// knows is applied; anything else is dropped and never reaches the table.
func TestPanelAppliesATypedRowOnlyForKnownKeys(t *testing.T) {
	a := newPanel(nil)
	a.input.SetValue("wm=tabwm")
	if !a.applyInput() {
		t.Fatal("applyInput reported no change")
	}
	if a.input.Value() != "" {
		t.Fatalf("input not consumed: %q", a.input.Value())
	}
	if v, _ := settings.Get(a.disp, "wm"); v != "tabwm" {
		t.Fatalf("wm = %q, want tabwm", v)
	}
	if got := a.summary(); got != "keys=13 wm=tabwm theme=dark" {
		t.Fatalf("summary = %q", got)
	}

	// An unknown key: named and dropped, table untouched.
	before := len(a.disp)
	a.input.SetValue("not_a_key=1")
	a.applyInput()
	if len(a.disp) != before {
		t.Fatalf("unknown key was written: %+v", a.disp)
	}
	if _, ok := settings.Get(a.disp, "not_a_key"); ok {
		t.Fatal("unknown key landed in the table")
	}

	// A line with no '=' is dropped too, and the input is still consumed.
	a.input.SetValue("tabwm")
	a.applyInput()
	if v, _ := settings.Get(a.disp, "wm"); v != "tabwm" {
		t.Fatalf("a bare word changed wm to %q", v)
	}
	if a.input.Value() != "" {
		t.Fatalf("bare-word input not consumed: %q", a.input.Value())
	}
}

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
func TestPanelRefusesCorruptWrites(t *testing.T) {
	a := &panel{
		file: settings.File{State: settings.StateCorrupt},
		disp: settings.File{State: settings.StateMissing}.Display(),
	}
	if a.mode() != "ro" {
		t.Fatalf("mode = %q, want ro", a.mode())
	}
	if a.set("wm", "tabwm") {
		t.Fatal("a corrupt file accepted an edit")
	}
	if v, _ := settings.Get(a.disp, "wm"); v != "gotabwm" {
		t.Fatalf("wm = %q after a refused edit", v)
	}
	// save() must take the refusal path: StateCorrupt makes the codec refuse
	// (settings.SaveRefused) so nothing is ever written.
	if rc := (settings.File{State: settings.StateCorrupt}).Save(); rc != settings.SaveRefused {
		t.Fatalf("codec rc = %d, want SaveRefused", rc)
	}
	a.save()
}

// rowOf is the display index of a key (the tests select rows by name, not by
// a hardcoded ordinal that a table reorder would silently invalidate).
func rowOf(t *testing.T, a *panel, key string) int {
	t.Helper()
	for i, s := range a.disp {
		if s.Key == key {
			return i
		}
	}
	t.Fatalf("no row for %q in %+v", key, a.disp)
	return -1
}

// M73m (#1662): the palette surface. A default panel has the eight kernel
// rows plus keyboard_layout, idle_minutes, notify_dnd and timezone; choosing
// `custom` reveals three colour rows with the compiled dark defaults, they
// are typed-editable as six hex digits, and a malformed value never reaches
// the table.
func TestPaletteSurfaceRevealsTheColoursOnCustom(t *testing.T) {
	a := newPanel(nil)
	want := len(settings.KnownKeys) + len(settings.KeyboardLayoutKeys) + len(settings.IdleKeys) +
		len(settings.NotifyKeys) + len(settings.TimezoneKeys)
	if len(a.disp) != want {
		t.Fatalf("default rows = %d, want %d kernel+layout+idle+notify+timezone rows (palette rows are NOT default rows)",
			len(a.disp), want)
	}
	for _, k := range settings.PaletteKeys {
		if _, ok := settings.Get(a.disp, k.Name); ok {
			t.Fatalf("%s shown while theme is a preset", k.Name)
		}
	}
	// Choose custom: the three rows appear, holding the compiled defaults.
	a.set("theme", "custom")
	for _, k := range settings.PaletteKeys {
		v, ok := settings.Get(a.disp, k.Name)
		if !ok || v != k.Default {
			t.Fatalf("%s row = %q ok=%v, want the default %q", k.Name, v, ok, k.Default)
		}
	}
	if got := a.summary(); got != "keys=16 wm=gotabwm theme=custom" {
		t.Fatalf("summary = %q", got)
	}
	// The palette rows are first-class: never the "(kept)" marker (that is
	// the label for a key the kernel table does not carry).
	for _, l := range a.labels() {
		if strings.Contains(l, "palette_") && strings.Contains(l, "(kept)") {
			t.Fatalf("palette row marked not-editable: %q", l)
		}
	}
	// Typed edit: six hex digits apply...
	a.input.SetValue("palette_fg=20ff9e")
	a.applyInput()
	if v, _ := settings.Get(a.disp, "palette_fg"); v != "20ff9e" {
		t.Fatalf("palette_fg = %q, want 20ff9e", v)
	}
	// ...anything else is named and dropped, table untouched.
	for _, bad := range []string{"palette_fg=zzz", "palette_bg=0x112233", "palette_accent=12345"} {
		a.input.SetValue(bad)
		a.applyInput()
		if a.input.Value() != "" {
			t.Fatalf("input not consumed: %q", a.input.Value())
		}
	}
	if v, _ := settings.Get(a.disp, "palette_fg"); v != "20ff9e" {
		t.Fatalf("a refused colour changed palette_fg to %q", v)
	}
	if v, _ := settings.Get(a.disp, "palette_bg"); v != settings.PaletteKeys[1].Default {
		t.Fatalf("palette_bg = %q, want the untouched default", v)
	}
	// And an unknown key is still dropped (the card-D1 rule holds).
	a.input.SetValue("not_a_key=1")
	a.applyInput()
	if _, ok := settings.Get(a.disp, "not_a_key"); ok {
		t.Fatal("unknown key landed in the table")
	}
}

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

func TestIdleMinutesRowValidatesBeforeSave(t *testing.T) {
	a := newPanel(nil)
	i := rowOf(t, a, "idle_minutes")
	if a.disp[i].Val != "5" {
		t.Fatalf("initial idle minutes = %q", a.disp[i].Val)
	}
	if strings.Contains(a.labels()[i], "(kept)") {
		t.Fatalf("idle row is not editable: %q", a.labels()[i])
	}
	for _, val := range []string{"0", "121", "1.5"} {
		a.input.SetValue("idle_minutes=" + val)
		a.applyInput()
		if got, _ := settings.Get(a.disp, "idle_minutes"); got != "5" {
			t.Fatalf("invalid %q changed idle_minutes to %q", val, got)
		}
	}
	a.input.SetValue("idle_minutes=7")
	a.applyInput()
	if got, _ := settings.Get(a.disp, "idle_minutes"); got != "7" {
		t.Fatalf("typed idle_minutes = %q, want 7", got)
	}
	if got := changedSettingKeys(settings.File{State: settings.StateMissing}, settings.File{Rows: a.disp, State: settings.StateOK}); len(got) != 1 || got[0] != "idle_minutes" {
		t.Fatalf("change notification keys = %v, want idle_minutes", got)
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
func TestKeyboardLayoutSurfaceCyclesAndValidates(t *testing.T) {
	a := newPanel(nil)
	i := rowOf(t, a, "keyboard_layout")
	if a.disp[i].Val != "us" {
		t.Fatalf("initial layout = %q, want us", a.disp[i].Val)
	}
	for _, label := range a.labels() {
		if strings.HasPrefix(label, "keyboard_layout") && strings.Contains(label, "(kept)") {
			t.Fatalf("layout row marked not-editable: %q", label)
		}
	}
	a.sel = i
	a.cycle(1)
	if got, _ := settings.Get(a.disp, "keyboard_layout"); got != "de" {
		t.Fatalf("keyboard_layout after cycle = %q, want de", got)
	}
	a.cycle(1)
	if got, _ := settings.Get(a.disp, "keyboard_layout"); got != "us" {
		t.Fatalf("keyboard_layout after wrap = %q, want us", got)
	}
	a.input.SetValue("keyboard_layout=de")
	a.applyInput()
	if got, _ := settings.Get(a.disp, "keyboard_layout"); got != "de" {
		t.Fatalf("typed keyboard_layout = %q, want de", got)
	}
	a.input.SetValue("keyboard_layout=fr")
	a.applyInput()
	if got, _ := settings.Get(a.disp, "keyboard_layout"); got != "de" {
		t.Fatalf("unsupported layout changed keyboard_layout to %q", got)
	}
}

// M83c (#1776): the timezone row is a visible, cyclable fixed-offset row,
// and a typed value that does not parse is dropped before it can reach the
// file — a typo must not quietly relabel every clock UTC.
func TestTimezoneRowCyclesAndValidatesBeforeSave(t *testing.T) {
	a := newPanel(nil)
	i := rowOf(t, a, "timezone")
	if a.disp[i].Val != "UTC" {
		t.Fatalf("initial timezone = %q, want UTC", a.disp[i].Val)
	}
	if strings.Contains(a.labels()[i], "(kept)") {
		t.Fatalf("timezone row is not editable: %q", a.labels()[i])
	}
	a.sel = i
	a.cycle(1)
	if got, _ := settings.Get(a.disp, "timezone"); got != "UTC+01:00" {
		t.Fatalf("timezone after cycle = %q, want the next curated offset (UTC+01:00)", got)
	}
	a.cycle(1)
	if got, _ := settings.Get(a.disp, "timezone"); got != "UTC+02:00" {
		t.Fatalf("timezone after second cycle = %q, want UTC+02:00", got)
	}
	a.input.SetValue("timezone=UTC+05:30")
	a.applyInput()
	if got, _ := settings.Get(a.disp, "timezone"); got != "UTC+05:30" {
		t.Fatalf("typed timezone = %q, want UTC+05:30", got)
	}
	for _, val := range []string{"utc", "Europe/Nowhere", "UTC+5:30", "UTC+15:00", ""} {
		a.input.SetValue("timezone=" + val)
		a.applyInput()
		if got, _ := settings.Get(a.disp, "timezone"); got != "UTC+05:30" {
			t.Fatalf("invalid %q changed timezone to %q", val, got)
		}
	}
	if got := changedSettingKeys(settings.File{State: settings.StateMissing}, settings.File{Rows: a.disp, State: settings.StateOK}); len(got) != 1 || got[0] != "timezone" {
		t.Fatalf("change notification keys = %v, want timezone", got)
	}
}

// M100f (#2311): the data-root row is accepted-but-unseeded and never a
// default display row (a default GOSET save stays byte-identical). Typed
// input validates host|disk before the row materializes, and a materialized
// row cycles like every vocabulary row.
func TestDataRootRowValidatesAndMaterializes(t *testing.T) {
	a := newPanel(nil)
	if _, ok := settings.Get(a.disp, "data_root"); ok {
		t.Fatal("a default panel materialized data_root")
	}
	for _, val := range []string{"", "usb", "DISK", "/disk", "on"} {
		a.input.SetValue("data_root=" + val)
		a.applyInput()
		if _, ok := settings.Get(a.disp, "data_root"); ok {
			t.Fatalf("invalid %q materialized data_root", val)
		}
	}
	a.input.SetValue("data_root=disk")
	a.applyInput()
	if v, ok := settings.Get(a.disp, "data_root"); !ok || v != "disk" {
		t.Fatalf("typed data_root = %q ok=%v, want disk", v, ok)
	}
	a.sel = rowOf(t, a, "data_root")
	a.cycle(1)
	if got, _ := settings.Get(a.disp, "data_root"); got != "host" {
		t.Fatalf("cycling disk gave %q, want host", got)
	}
}
