package main

import (
	"testing"

	"virelai/appkit"
	"virelai/widgets"
)

// The model half of the app: pick text per tab, the stay-open/query state
// round-trip, selection bounds, and the tag format. Everything here is
// host-pure — the guest half is the go-emoji VZ leg.

func newApp() *app {
	a := &app{}
	a.field = appkit.NewTextField(widgets.Rect{}, queryMax)
	a.refilter()
	return a
}

func TestUhex(t *testing.T) {
	for cp, want := range map[rune]string{
		0x2764: "U+2764", 0x1F525: "U+1F525", 0xe1: "U+00E1", 0x2b50: "U+2B50",
	} {
		if got := uhex(cp); got != want {
			t.Errorf("uhex(%U) = %q, want %q", cp, got, want)
		}
	}
}

func TestPickText(t *testing.T) {
	a := newApp()
	a.field.SetValue("fire")
	a.refilter()
	text, desc, ok := a.pickText()
	if !ok || text != "\U0001F525" {
		t.Fatalf("pickText = %q %q — want the fire rune", text, desc)
	}
	if desc != "U+1F525 fire" {
		t.Fatalf("desc = %q, want the tag+name line", desc)
	}
}

func TestPickTextTabs(t *testing.T) {
	a := newApp()
	a.setTab(tabCompose)
	text, _, ok := a.pickText()
	if !ok || text != "á" {
		t.Fatalf("compose pick = %q, want á", text)
	}
	a.setTab(tabKaomoji)
	text, _, ok = a.pickText()
	if !ok || text != kaomoji[0].Text {
		t.Fatalf("kaomoji pick = %q, want %q", text, kaomoji[0].Text)
	}
}

func TestPickEmptyRefuses(t *testing.T) {
	a := newApp()
	a.field.SetValue("zzzzzz")
	a.refilter()
	if _, _, ok := a.pickText(); ok {
		t.Fatal("pick with no matches must refuse")
	}
}

func TestNavDelta(t *testing.T) {
	if navDelta(tabEmoji, appkit.NamedRight) != 1 || navDelta(tabEmoji, appkit.NamedLeft) != -1 {
		t.Fatal("grid left/right must step one cell")
	}
	if navDelta(tabEmoji, appkit.NamedDown) != gridCols || navDelta(tabEmoji, appkit.NamedUp) != -gridCols {
		t.Fatal("grid up/down must step one row")
	}
	if navDelta(tabKaomoji, appkit.NamedDown) != 1 {
		t.Fatal("list tabs step one row")
	}
}

func TestMoveSelClamps(t *testing.T) {
	a := newApp()
	if !a.moveSel(1) || a.sel != 1 {
		t.Fatal("moveSel(+1) from 0 must select 1")
	}
	a.moveSel(-99)
	if a.sel != 0 {
		t.Fatal("moveSel past the top must clamp to 0")
	}
	a.moveSel(999)
	if a.sel != len(a.matches)-1 {
		t.Fatal("moveSel past the end must clamp to the last row")
	}
}

func TestStateRoundTrip(t *testing.T) {
	a := newApp()
	a.tab = tabKaomoji
	a.stay = true
	a.field.SetValue("fire")
	b := a.saveState()

	c := newApp()
	c.restoreState(b, stateVerShelf)
	if c.tab != tabKaomoji || !c.stay || c.field.Value() != "fire" {
		t.Fatalf("restore = tab %d stay %v q %q", c.tab, c.stay, c.field.Value())
	}
	// The restored query re-ranks on the restored tab: "fire" filters
	// the kaomoji names to nothing, so the pick must honestly refuse.
	if _, _, ok := c.pickText(); ok {
		t.Fatal("a restored query with no matches must refuse the pick")
	}
	c.setTab(tabEmoji)
	text, _, ok := c.pickText()
	if !ok || text != "\U0001F525" {
		t.Fatalf("restored pick = %q, want the fire rune", text)
	}
}

func TestRestoreGarbage(t *testing.T) {
	c := newApp()
	c.restoreState(nil, stateVerShelf)
	c.restoreState([]byte{9}, stateVerShelf)
	c.restoreState([]byte{'x', 'y', 'z'}, stateVerShelf)
	if c.tab != tabEmoji || c.stay {
		t.Fatalf("garbage state changed the defaults: tab %d stay %v", c.tab, c.stay)
	}
}
