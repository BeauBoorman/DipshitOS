package main

import (
	"strings"
	"testing"
	"virelai/settings"
	"virelai/vi"
	"virelai/widgets"
)

// layout_test.go — the row affordance geometry and the palette band.

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
