package main

import (
	"strconv"
	"strings"
	"testing"
	"virelai/settings"
)

// rows_test.go — the display table's pins: edits, the typed line's
// validation, and the crash-safe save.

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
