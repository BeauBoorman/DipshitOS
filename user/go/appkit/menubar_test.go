package appkit

import (
	"os"
	"testing"

	"virelai/draw"
	"virelai/theme"
	"virelai/ttf"
	"virelai/widgets"
)

// loadTestFace reads the Inter UI face the guest apps stage as INTER.TTF.
func loadTestFace() (*ttf.Face, error) {
	data, err := os.ReadFile("../../../image/fonts/Inter-Regular.ttf")
	if err != nil {
		return nil, err
	}
	return ttf.Parse(data)
}

var _ Focusable = &MenuBar{}

func demoMenus(quit *int, exp *int) []Menu {
	return []Menu{
		{Title: "&File", Items: []MenuItem{
			{Label: "&Open…", Shortcut: "F10"},
			{Label: "&Quit", Action: func() bool { *quit++; return true }},
		}},
		{Title: "&Edit", Items: []MenuItem{
			{Label: "Cu&t", Disabled: true},
			{Label: "&Copy"},
		}},
		{Title: "&View", Items: []MenuItem{
			{Label: "&Expand All", Action: func() bool { *exp++; return true }},
			{Label: "&Collapse All"},
		}},
	}
}

// F10 engages the bar (first title highlighted, nothing open); arrows move the
// highlight; Down or Enter opens; Left/Right roam between open menus; Escape
// backs out one level at a time.
func TestMenuBarKeyboardDrive(t *testing.T) {
	quit, exp := 0, 0
	mb := &MenuBar{R: widgets.Rect{W: 240, H: 24}, Menus: demoMenus(&quit, &exp)}

	if !mb.OnKey(Key{Usage: 0x43}) { // F10
		t.Fatal("F10 must engage the bar")
	}
	if !mb.Active || mb.Open || mb.Bar != 0 {
		t.Fatalf("F10 state: Active=%v Open=%v Bar=%d", mb.Active, mb.Open, mb.Bar)
	}
	if !mb.OnKey(Key{Usage: 0x4f}) || mb.Bar != 1 { // right
		t.Fatalf("right -> Bar=%d", mb.Bar)
	}
	if !mb.OnKey(Key{Usage: 0x51}) || !mb.Open { // down opens
		t.Fatal("down must open the highlighted menu")
	}
	if mb.Bar != 1 || mb.Hover != 1 { // Edit: item 0 disabled, first enabled is 1
		t.Fatalf("open Edit: Bar=%d Hover=%d", mb.Bar, mb.Hover)
	}
	if !mb.OnKey(Key{Usage: 0x4f}) || mb.Bar != 2 || !mb.Open { // roams to View
		t.Fatalf("right roams: Bar=%d Open=%v", mb.Bar, mb.Open)
	}
	// Escape closes the popover but keeps the bar; second Escape disengages.
	if !mb.OnKey(Key{Usage: 0x29}) || mb.Open || !mb.Active {
		t.Fatal("esc must close the menu, keep the bar")
	}
	if !mb.OnKey(Key{Usage: 0x29}) || mb.Active {
		t.Fatal("second esc must disengage")
	}
	_ = quit
	_ = exp
}

// A bare Alt keypress engages the bar, and Alt+letter opens the menu whose
// title mnemonic matches.
func TestMenuBarAltEntry(t *testing.T) {
	quit, exp := 0, 0
	mb := &MenuBar{R: widgets.Rect{W: 240, H: 24}, Menus: demoMenus(&quit, &exp)}
	if !mb.OnKey(Key{Usage: 0xe2, Alt: true}) || !mb.Active { // left Alt
		t.Fatal("bare Alt must engage")
	}
	mb.Close()
	if !mb.OnKey(Key{Usage: 0x21, Rune: 'f', Alt: true}) || !mb.Open || mb.Bar != 0 {
		t.Fatal("alt-f must open File")
	}
}

// While a menu is open, arrows move the highlight (skipping disabled),
// Home/End pin the ends, and Enter fires the item's Action — the callback
// rides the same dirty-bit the app's Loop already checks.
func TestMenuBarItemFireAndDisabled(t *testing.T) {
	quit, exp := 0, 0
	mb := &MenuBar{R: widgets.Rect{W: 240, H: 24}, Menus: demoMenus(&quit, &exp)}
	mb.OpenMenu(0)
	if !mb.OnKey(Key{Usage: 0x51}) || mb.Hover != 1 {
		t.Fatalf("down hover=%d", mb.Hover)
	}
	if !mb.OnKey(Key{Usage: 0x28}) || quit != 1 { // Enter fires Quit
		t.Fatal("enter must fire Quit")
	}
	if mb.Active || mb.Open {
		t.Fatal("firing must disengage")
	}
	// Disabled rows are skipped by arrows and refused on fire.
	mb.OpenMenu(1)
	if mb.Hover != 1 { // Cut disabled
		t.Fatalf("firstEnabled=%d", mb.Hover)
	}
	if !mb.OnKey(Key{Usage: 0x52}) || mb.Hover != 1 { // up wraps, still skips 0
		t.Fatalf("wrap hover=%d", mb.Hover)
	}
	if !mb.OnKey(Key{Usage: 0x4a}) || mb.Hover != 1 { // Home -> first enabled
		t.Fatalf("home hover=%d", mb.Hover)
	}
	// A mnemonic typed in the open menu fires directly.
	mb.OpenMenu(2)
	if !mb.OnKey(Key{Rune: 'e'}) || exp != 1 {
		t.Fatal("'e' must fire Expand All")
	}
}

// Pointer: title clicks toggle, item clicks fire, outside clicks dismiss.
func TestMenuBarClickPaths(t *testing.T) {
	quit, _ := 0, 0
	mb := &MenuBar{R: widgets.Rect{W: 240, H: 24}, Menus: demoMenus(&quit, nil)}
	tr := mb.TitleRect(0)
	if !mb.OnClick(tr.X+2, tr.Y+2) || !mb.Open {
		t.Fatal("title click must open")
	}
	if !mb.OnClick(tr.X+2, tr.Y+2) || mb.Open {
		t.Fatal("second title click must close")
	}
	mb.OpenMenu(0)
	rr := mb.ItemRect(0, 1)
	if !mb.OnClick(rr.X+2, rr.Y+2) || quit != 1 || mb.Open {
		t.Fatal("item click must fire and close")
	}
	// HitTest covers the popover only while open.
	mb.OpenMenu(0)
	pop := mb.PopoverRect(0)
	if !mb.HitTest(pop.X+2, pop.Y+2) {
		t.Fatal("open popover must hit")
	}
	if !mb.OnClick(400, 400) || mb.Active || mb.Open {
		t.Fatal("outside click must disengage")
	}
	if mb.HitTest(pop.X+2, pop.Y+2) {
		t.Fatal("closed popover must not hit")
	}
}

// TitleRect/TitleAt and ItemRect/ItemAt agree — the widgets hit==paint rule
// on the menu geometry.
func TestMenuBarGeometryAgrees(t *testing.T) {
	quit := 0
	mb := &MenuBar{R: widgets.Rect{W: 240, H: 24}, Menus: demoMenus(&quit, &quit)}
	for i := range mb.Menus {
		tr := mb.TitleRect(i)
		if mb.TitleAt(tr.X+1, tr.Y+1) != i {
			t.Fatalf("TitleAt(TitleRect(%d)) != %d", i, i)
		}
	}
	mb.OpenMenu(2)
	for j := range mb.Menus[2].Items {
		rr := mb.ItemRect(2, j)
		if mb.ItemAt(rr.X+1, rr.Y+1) != j {
			t.Fatalf("ItemAt(ItemRect(2,%d)) != %d", j, j)
		}
	}
}

// The golden: idle bar, active-with-underlines bar, and an open menu with a
// disabled row, a hover, and a shortcut — over the §2.5 shadow.
func TestMenuBarGolden(t *testing.T) {
	th := theme.Current
	ui, err := loadTestFace()
	if err != nil {
		t.Fatal(err)
	}
	const w, h = 240, 220
	c := &draw.BufferCanvas{Pix: make([]uint32, w*h), W: w, H: h}
	draw.FillRect(c, widgets.Rect{W: w, H: h}, draw.Opaque(th.Bg))
	quit, exp := 0, 0
	idle := &MenuBar{R: widgets.Rect{X: 4, Y: 4, W: 232, H: 24}, Menus: demoMenus(&quit, &exp), UIFace: ui}
	idle.Draw(c)
	armed := &MenuBar{R: widgets.Rect{X: 4, Y: 36, W: 232, H: 24}, Menus: demoMenus(&quit, &exp), UIFace: ui}
	armed.Activate(1)
	armed.Draw(c)
	open := &MenuBar{R: widgets.Rect{X: 4, Y: 68, W: 232, H: 24}, Menus: demoMenus(&quit, &exp), UIFace: ui}
	open.OpenMenu(1)
	open.Draw(c)
	bare := &MenuBar{R: widgets.Rect{X: 4, Y: 192, W: 232, H: 24}, Menus: demoMenus(&quit, &exp)}
	bare.Draw(c)
	checkCompositeGolden(t, "appkit-menubar", c)
}
