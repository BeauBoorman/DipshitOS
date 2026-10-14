package appkit

import (
	"testing"

	"virelai/draw"
	"virelai/theme"
	"virelai/widgets"
)

// The dropdown is the contract's Focusable control: the compile-time check
// lives with the geometry tests so an interface regression fails here.
var _ Focusable = &Dropdown{}

func dd(items ...string) *Dropdown {
	return &Dropdown{
		R:     widgets.Rect{X: 20, Y: 20, W: 120, H: 24},
		Items: items, Sel: 1, MaxRows: 4,
	}
}

// PopoverRect, RowRect and ItemAt are one geometry: a point inside
// RowRect(i) maps back to i, and the popover hangs PadXS below the button.
func TestDropdownRowRectMatchesItemAt(t *testing.T) {
	d := dd("alpha", "bravo", "charlie", "delta")
	d.Open = true
	pop := d.PopoverRect()
	wantY := d.R.Bottom() + theme.Current.PadXS
	if pop.Y != wantY || pop.X != d.R.X || pop.W != d.R.W {
		t.Fatalf("popover = %+v", pop)
	}
	if pop.H != 4*dropdownRowH+2*theme.Current.BorderW {
		t.Fatalf("popover h = %d", pop.H)
	}
	for i := range d.Items {
		rr := d.RowRect(i)
		if got := d.ItemAt(rr.X+1, rr.Y+1); got != i {
			t.Fatalf("ItemAt inside RowRect(%d) = %d", i, got)
		}
		if got := d.ItemAt(rr.Right()-1, rr.Bottom()-1); got != i {
			t.Fatalf("ItemAt at RowRect(%d) br = %d", i, got)
		}
	}
	if d.ItemAt(pop.X-1, pop.Y) != -1 || d.ItemAt(pop.X, pop.Bottom()) != -1 {
		t.Fatal("out-of-popover points must be -1")
	}
	// Closed: no row hits at all.
	d.Open = false
	if d.ItemAt(d.RowRect(0).X+1, d.RowRect(0).Y+1) != -1 {
		t.Fatal("a closed dropdown must not hit rows")
	}
}

// HitTest covers the button always and the popover only while open — the
// same regions Draw paints.
func TestDropdownHitTestCoversButtonAndOpenPopover(t *testing.T) {
	d := dd("alpha", "bravo")
	if !d.HitTest(d.R.X+1, d.R.Y+1) {
		t.Fatal("button must hit")
	}
	pop := d.PopoverRect()
	if d.HitTest(pop.X+1, pop.Y+1) {
		t.Fatal("closed popover region must not hit")
	}
	d.Open = true
	if !d.HitTest(pop.X+1, pop.Y+1) {
		t.Fatal("open popover must hit")
	}
	// Upward flips the popover above the button; HitTest follows.
	d.Upward = true
	up := d.PopoverRect()
	if up.Bottom() != d.R.Y-theme.Current.PadXS {
		t.Fatalf("upward popover = %+v", up)
	}
	if !d.HitTest(up.X+1, up.Y+1) {
		t.Fatal("upward popover must hit")
	}
}

// Click toggles, row click commits, a stray click dismisses; the keyboard
// path opens, highlights, and commits the same way.
func TestDropdownStateMachine(t *testing.T) {
	d := dd("alpha", "bravo", "charlie")
	if !d.OnClick(d.R.X+1, d.R.Y+1) || !d.Open {
		t.Fatal("button click must open")
	}
	if got := d.ItemAt(d.RowRect(2).X+1, d.RowRect(2).Y+1); got != 2 {
		t.Fatalf("ItemAt = %d", got)
	}
	if !d.OnClick(d.RowRect(2).X+1, d.RowRect(2).Y+1) {
		t.Fatal("row click must consume")
	}
	if d.Sel != 2 || d.Open {
		t.Fatalf("row click: sel=%d open=%v", d.Sel, d.Open)
	}
	// A click outside while open dismisses without touching Sel.
	d.SetOpen(true)
	if !d.OnClick(300, 300) || d.Open || d.Sel != 2 {
		t.Fatalf("outside click: sel=%d open=%v", d.Sel, d.Open)
	}
	// Keys: Down opens, the next Down highlights the row after Sel, Enter
	// commits it, Escape dismisses.
	d.Sel, d.HoverRow = 1, -1
	if !d.OnKey(Key{Usage: 0x51}) || !d.Open {
		t.Fatal("down must open")
	}
	if !d.OnKey(Key{Usage: 0x51}) || d.HoverRow != 2 {
		t.Fatalf("down hover = %d, want 2", d.HoverRow)
	}
	if !d.OnKey(Key{Usage: 0x28}) || d.Sel != 2 || d.Open {
		t.Fatalf("enter commit: sel=%d open=%v", d.Sel, d.Open)
	}
	d.SetOpen(true)
	if !d.OnKey(Key{Usage: 0x29}) || d.Open {
		t.Fatal("escape must dismiss")
	}
}

// A disabled dropdown eats everything and never opens.
func TestDropdownDisabledIsInert(t *testing.T) {
	d := dd("alpha", "bravo")
	d.Disabled = true
	if d.OnClick(d.R.X+1, d.R.Y+1) || d.Open {
		t.Fatal("disabled dropdown must not open")
	}
	if d.OnKey(Key{Usage: 0x28}) || d.OnKey(Key{Usage: 0x51}) {
		t.Fatal("disabled dropdown must eat no keys")
	}
	d.SetOpen(true)
	if d.Open {
		t.Fatal("SetOpen must refuse while disabled")
	}
}

// Overflow: MaxRows caps the window, the selection scrolls into view, and
// the popover paints a scrollbar only while items overflow.
func TestDropdownOverflowScrolls(t *testing.T) {
	d := dd("a", "b", "c", "d", "e", "f")
	if d.visible() != 4 {
		t.Fatalf("visible = %d, want 4", d.visible())
	}
	d.Sel = 5
	d.SetOpen(true)
	if d.ScrollTop != 2 {
		t.Fatalf("scroll-into-view top = %d, want 2", d.ScrollTop)
	}
	if got := d.ItemAt(d.RowRect(5).X+1, d.RowRect(5).Y+1); got != 5 {
		t.Fatalf("scrolled ItemAt = %d", got)
	}
	// RowRect(0) is scrolled out — its point maps to a visible row or -1.
	if got := d.ItemAt(d.RowRect(0).X+1, d.RowRect(0).Y+1); got == 0 {
		t.Fatal("scrolled-out row must not hit")
	}
	d.ScrollTop = 99
	if d.clampTop() != 2 {
		t.Fatalf("clampTop = %d, want 2", d.clampTop())
	}
}

// On a *draw.BufferCanvas the popover is the §5.2 consumer: the §2.5
// shadow lands below the plate, row ink is clip-guarded (the stack returns
// to depth 0), and the selected row carries the 3px Accent marker.
func TestDropdownPopoverShadowClipAndMarker(t *testing.T) {
	th := theme.Current
	d := dd("alpha", "bravo", "charlie", "delta", "echo")
	d.Sel = 2
	d.Open = true
	const w, h = 240, 240
	c := &draw.BufferCanvas{Pix: make([]uint32, w*h), W: w, H: h}
	draw.FillRect(c, widgets.Rect{W: w, H: h}, draw.Opaque(th.Bg))
	before := c.Clip()
	d.Draw(c)
	if got := c.Clip(); got != before {
		t.Fatalf("clip stack leaked: clip = %+v, want %+v", got, before)
	}
	pop := d.PopoverRect()
	px := func(x, y int) uint32 { return c.Pix[y*w+x] }
	// The shadow falls straight down: a pixel under the plate's bottom
	// edge inside the blur reach is no longer the flat background.
	if px(pop.X+pop.W/2, pop.Bottom()+4) == draw.Opaque(th.Bg) {
		t.Fatal("popover cast no shadow")
	}
	// The plate is a rounded Surface plate with a border stroke.
	if px(pop.X+pop.W/2, pop.Y) != draw.Opaque(th.Border) {
		t.Fatal("popover border missing")
	}
	if px(pop.X+pop.W/2, pop.Y+pop.H/2) == draw.Opaque(th.Bg) {
		t.Fatal("popover plate missing")
	}
	// Selected row 2: Selection fill with the 3px Accent left-edge marker.
	rr := d.RowRect(2)
	markX := rr.X + theme.Current.PadXS + 1
	if px(markX, rr.Y+2) != draw.Opaque(th.Accent) {
		t.Fatalf("selected marker missing at (%d,%d): %#x", markX, rr.Y+2, px(markX, rr.Y+2))
	}
	if px(markX+4, rr.Y+2) != draw.Opaque(th.Selection) {
		t.Fatal("selected fill missing")
	}
	// Five items under MaxRows 4: the popover paints the widget scrollbar —
	// the thumb (BtnIdle) at the top of the track, ChromeBg below it.
	trackX := pop.X + pop.W - theme.Current.BorderW - widgets.ScrollbarW + 2
	if px(trackX, pop.Y+8) != draw.Opaque(th.BtnIdle) {
		t.Fatalf("popover scrollbar thumb missing: %#x", px(trackX, pop.Y+8))
	}
	if px(trackX, pop.Y+pop.H-4) != draw.Opaque(th.ChromeBg) {
		t.Fatalf("popover scrollbar track missing: %#x", px(trackX, pop.Y+pop.H-4))
	}
}

// On a RectCanvas-only surface the popover degrades to the flat v1 look:
// a Border plate, a Surface inset, and §2.3 marker fills — no crash, no
// blank rows.
func TestDropdownFlatDegrade(t *testing.T) {
	th := theme.Current
	d := dd("alpha", "bravo", "charlie")
	d.Sel = 1
	d.Open = true
	c := &fillRecorder{}
	d.Draw(c)
	pop := d.PopoverRect()
	inner := pop.Inset(th.BorderW)
	var plate, inset bool
	for _, r := range c.fills {
		if r == pop {
			plate = true
		}
		if r == inner {
			inset = true
		}
	}
	if !plate || !inset {
		t.Fatalf("flat popover plate missing: %+v", c.fills)
	}
	rr := d.RowRect(1)
	selFill := widgets.Rect{X: rr.X + th.PadXS, Y: rr.Y, W: inner.W - 2*th.PadXS, H: rr.H}
	var sel, mark bool
	for _, r := range c.fills {
		if r == selFill {
			sel = true
		}
		if r.W == 3 && r.X == rr.X+th.PadXS {
			mark = true
		}
	}
	if !sel || !mark {
		t.Fatalf("flat selected row missing: sel=%v mark=%v", sel, mark)
	}
}

type fillRecorder struct{ fills []widgets.Rect }

func (r *fillRecorder) FillRect(rc widgets.Rect, _ uint32) {
	r.fills = append(r.fills, rc)
}
