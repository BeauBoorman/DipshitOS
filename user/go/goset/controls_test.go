package main

import (
	"testing"
	"unicode/utf8"

	"virelai/appkit"
	"virelai/settings"
	"virelai/vi"
	"virelai/widgets"
)

func TestBoundedFieldMatchesExistingPlainEditor(t *testing.T) {
	original := appkit.NewTextField(widgets.Rect{}, 8)
	field := textField{Max: 8}
	for _, ev := range []vi.Event{
		{Kind: vi.EvKeyDown, Arg1: 'a'}, {Kind: vi.EvKeyDown, Arg1: 'é'},
		{Kind: vi.EvKeyDown, Arg1: '界'}, {Kind: vi.EvKeyDown, Arg0: keyLeft},
		{Kind: vi.EvKeyDown, Arg1: 'x'}, {Kind: vi.EvKeyDown, Arg0: keyBackspace},
		{Kind: vi.EvKeyDown, Arg0: keyDelete}, {Kind: vi.EvKeyDown, Arg0: keyEnd},
		{Kind: vi.EvKeyDown, Arg1: '😀'}, {Kind: vi.EvKeyDown, Arg0: keyHome},
		{Kind: vi.EvKeyDown, Arg1: 'Q', Flags: vi.ModCtrl},
		{Kind: vi.EvKeyDown, Arg1: 'Q', Flags: vi.ModAlt},
	} {
		key, _ := normalizeKey(ev)
		oldKey, _ := appkit.NormalizeKey(ev)
		field.OnKey(key)
		original.OnKey(oldKey)
		if field.Value() != original.Value() || field.CaretPosition() != original.CaretPosition() ||
			!utf8.ValidString(field.Value()) {
			t.Fatal(ev, field.Value(), field.CaretPosition(), original.Value(), original.CaretPosition())
		}
	}
	field.SetValue("1234567界")
	original.SetValue("1234567界")
	if field.Value() != original.Value() || field.Value() != "1234567" {
		t.Fatal("SetValue split a scalar", field.Value())
	}
	field.Clear()
	if field.Value() != "" || field.CaretPosition() != 0 {
		t.Fatal("clear")
	}
}

func TestBoundedControlsKeepFocusAndScrollContract(t *testing.T) {
	a := newPanel(nil)
	a.list = widgets.List{R: widgets.Rect{W: 20, H: 20}, RowH: 10,
		Items: []string{"one", "two", "three"}}
	a.focus.Focus(0)
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyEnd})
	if a.sel != 2 || a.list.ScrollTop != 1 {
		t.Fatal(a.sel, a.list.ScrollTop)
	}
	a.focus.Focus(1)
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyTab, Flags: vi.ModShift})
	if _, i := a.focus.Current(); i != 0 || !a.list.Focused || a.input.Focused {
		t.Fatal("shift-tab focus")
	}
	a.key(vi.Event{Kind: vi.EvKeyDown, Arg0: keyTab, Flags: vi.ModShift})
	if _, i := a.focus.Current(); i != 3 || !a.quitBtn.Focused {
		t.Fatal("focus wrap")
	}
}

// M99d (#2182): the audio_volume row is the panel's 0–100 control on slot
// 44. The panel's own surfaces are the bounded field and the list's
// vocabulary cycle, so the control is exercised the way the gate drives it:
// typed `audio_volume=N` + Enter, then Left/Right on the materialized row —
// and every accepted write lands on slot 44 through settings.Set's apply
// hook, observed here through the exported seam.
func TestVolumeRowTypesCyclesAndAppliesToSlot44(t *testing.T) {
	savedApply := settings.AudioVolumeApply
	defer func() { settings.AudioVolumeApply = savedApply }()
	var applied []int
	settings.AudioVolumeApply = func(vol int) (int, error) {
		applied = append(applied, vol)
		return vol, nil
	}

	a := newPanel(nil)
	// A default table carries no volume row: it is accepted-but-unseeded,
	// materializing on the first set like the font and layout rows before it.
	if _, ok := settings.Get(a.disp, "audio_volume"); ok {
		t.Fatal("a default table already carries audio_volume")
	}
	a.input.SetValue("audio_volume=40")
	if !a.applyInput() {
		t.Fatal("typed audio_volume=40 was not applied")
	}
	if got, _ := settings.Get(a.disp, "audio_volume"); got != "40" {
		t.Fatalf("audio_volume row = %q, want 40", got)
	}
	if len(applied) != 1 || applied[0] != 40 {
		t.Fatalf("slot-44 applies = %v, want [40]", applied)
	}

	// The materialized row is a cyclable control: Left/Right step the
	// decade ladder and every step applies live.
	a.sel = rowOf(t, a, "audio_volume")
	a.cycle(1)
	if got, _ := settings.Get(a.disp, "audio_volume"); got != "50" {
		t.Fatalf("cycle up = %q, want 50", got)
	}
	a.cycle(-1)
	a.cycle(-1)
	if got, _ := settings.Get(a.disp, "audio_volume"); got != "30" {
		t.Fatalf("two cycles down = %q, want 30", got)
	}
	if len(applied) != 4 || applied[1] != 50 || applied[2] != 40 || applied[3] != 30 {
		t.Fatalf("cycle applies = %v, want [40 50 40 30]", applied)
	}
	// The ladder wraps at the ends like every vocabulary row.
	for i := 0; i < 8; i++ {
		a.cycle(1) // 30 -> 100 -> 0
	}
	if got, _ := settings.Get(a.disp, "audio_volume"); got != "0" {
		t.Fatalf("ladder wrap landed on %q, want 0", got)
	}

	// A value slot 44 refuses is still written verbatim — the vocabulary is
	// the panel's help, not a gate — but it applies nothing: the kernel's
	// own reader is the authority on what it will ignore.
	for _, val := range []string{"101", "loud"} {
		a.input.SetValue("audio_volume=" + val)
		a.applyInput()
		if got, _ := settings.Get(a.disp, "audio_volume"); got != val {
			t.Fatalf("%q did not reach the row verbatim: %q", val, got)
		}
	}
	if len(applied) != 12 {
		t.Fatalf("out-of-range applied: %v", applied)
	}

	// The chime's own switch is the same accepted row — the gate toggles it
	// through the same typed line.
	a.input.SetValue("notify_sound=off")
	a.applyInput()
	if got, _ := settings.Get(a.disp, "notify_sound"); got != "off" {
		t.Fatalf("notify_sound row = %q, want off", got)
	}
}
