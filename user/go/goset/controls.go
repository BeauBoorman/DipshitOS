package main

import (
	"unicode/utf8"

	"virelai/draw"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

// GOSET only needs a single-line field, list and two buttons. Keeping this
// bounded input surface here avoids appkit -> shlib's shell builtin init
// table. HID/control-code behavior matches appkit; no shell parser is used.
const (
	keyEnter     = 0x28
	keyEscape    = 0x29
	keyBackspace = 0x2a
	keyTab       = 0x2b
	keyHome      = 0x4a
	keyDelete    = 0x4c
	keyEnd       = 0x4d
	keyRight     = 0x4f
	keyLeft      = 0x50
	keyDown      = 0x51
	keyUp        = 0x52
)

type panelKey struct {
	Usage            uint32
	Rune             rune
	Ctrl, Shift, Alt bool
}

func (k panelKey) Named() uint32 { return k.Usage }

func normalizeKey(ev vi.Event) (panelKey, bool) {
	if ev.Kind != vi.EvKeyDown {
		return panelKey{}, false
	}
	k := panelKey{Usage: ev.Arg0, Ctrl: ev.Flags&vi.ModCtrl != 0,
		Shift: ev.Flags&vi.ModShift != 0, Alt: ev.Flags&vi.ModAlt != 0}
	if (ev.Arg1 >= 0x20 && ev.Arg1 < 0x7f || ev.Arg1 >= 0xa0) &&
		ev.Arg1 <= utf8.MaxRune && utf8.ValidRune(rune(ev.Arg1)) && !k.Ctrl {
		k.Rune = rune(ev.Arg1)
	}
	if k.Usage == 0 {
		switch ev.Arg1 {
		case '\n', '\r':
			k.Usage = keyEnter
		case 0x1b:
			k.Usage = keyEscape
		case 0x08, 0x7f:
			k.Usage = keyBackspace
		case '\t':
			k.Usage = keyTab
		}
	}
	return k, true
}

type control interface {
	HitTest(int, int) bool
	SetFocused(bool)
	OnClick(int, int) bool
	OnKey(panelKey) bool
}

type focusRing struct {
	items []control
	index int
}

func (f *focusRing) Current() (control, int) {
	if f.index < 0 || f.index >= len(f.items) {
		return nil, -1
	}
	return f.items[f.index], f.index
}

func (f *focusRing) Focus(i int) bool {
	if len(f.items) == 0 {
		return false
	}
	if i < 0 {
		i = len(f.items) - 1
	}
	if i >= len(f.items) {
		i = 0
	}
	if old, _ := f.Current(); old != nil {
		old.SetFocused(false)
	}
	changed := f.index != i
	f.index = i
	f.items[i].SetFocused(true)
	return changed
}

func (f *focusRing) HandleKey(k panelKey) bool {
	if k.Named() == keyTab {
		delta := 1
		if k.Shift {
			delta = -1
		}
		return f.Focus(f.index + delta)
	}
	c, _ := f.Current()
	return c != nil && c.OnKey(k)
}

func (f *focusRing) HandleClick(x, y int) bool {
	for i, c := range f.items {
		if c.HitTest(x, y) {
			f.Focus(i)
			return c.OnClick(x, y)
		}
	}
	return false
}

type actionButton struct {
	Button     *widgets.Button
	OnActivate func() bool
}

func (b *actionButton) HitTest(x, y int) bool { return b.Button.HitTest(x, y) }
func (b *actionButton) SetFocused(v bool)     { b.Button.Focused = v }
func (b *actionButton) OnClick(x, y int) bool { return b.HitTest(x, y) && b.OnActivate() }
func (b *actionButton) OnKey(k panelKey) bool { return k.Named() == keyEnter && b.OnActivate() }

type listController struct{ List *widgets.List }

func (c *listController) HitTest(x, y int) bool { return c.List.HitTest(x, y) }
func (c *listController) SetFocused(v bool)     { c.List.Focused = v }
func (c *listController) OnClick(x, y int) bool {
	i := c.List.ItemAt(x, y)
	if i < 0 {
		return false
	}
	c.List.Sel = i
	c.ensureVisible()
	return true
}
func (c *listController) OnKey(k panelKey) bool { return c.HandleKey(k) }
func (c *listController) HandleKey(k panelKey) bool {
	if len(c.List.Items) == 0 {
		return false
	}
	before := c.List.Sel
	switch k.Named() {
	case keyUp:
		c.List.Sel--
	case keyDown:
		c.List.Sel++
	case keyHome:
		c.List.Sel = 0
	case keyEnd:
		c.List.Sel = len(c.List.Items) - 1
	default:
		return false
	}
	c.List.Sel = max(0, min(c.List.Sel, len(c.List.Items)-1))
	c.ensureVisible()
	return before != c.List.Sel
}
func (c *listController) ensureVisible() {
	visible := c.List.VisibleRows()
	if visible < 1 {
		return
	}
	top := min(c.List.ScrollTop, max(0, len(c.List.Items)-visible))
	if c.List.Sel < top {
		top = c.List.Sel
	}
	if c.List.Sel >= top+visible {
		top = c.List.Sel - visible + 1
	}
	c.List.ScrollTop = max(0, top)
}

type textField struct {
	R                   widgets.Rect
	Fg, Bg, Caret       uint32
	Focused             bool
	Max                 int
	Prefix, Placeholder string
	value               string
	caret               int
}

func (f *textField) Value() string      { return f.value }
func (f *textField) CaretPosition() int { return f.caret }
func (f *textField) SetValue(s string) {
	if len(s) > f.Max {
		cut := f.Max
		for cut > 0 && !utf8.RuneStart(s[cut]) {
			cut--
		}
		s = s[:cut]
	}
	f.value, f.caret = s, len(s)
}
func (f *textField) Clear()                { f.value, f.caret = "", 0 }
func (f *textField) SetFocused(v bool)     { f.Focused = v }
func (f *textField) HitTest(x, y int) bool { return f.R.Contains(x, y) }
func (f *textField) OnClick(x, y int) bool { return f.HitTest(x, y) }
func (f *textField) OnKey(k panelKey) bool {
	before := f.caret
	prev, next := f.caret, f.caret
	if prev > 0 {
		_, n := utf8.DecodeLastRuneInString(f.value[:prev])
		prev -= n
	}
	if next < len(f.value) {
		_, n := utf8.DecodeRuneInString(f.value[next:])
		next += n
	}
	switch k.Named() {
	case keyLeft:
		f.caret = prev
	case keyRight:
		f.caret = next
	case keyHome:
		f.caret = 0
	case keyEnd:
		f.caret = len(f.value)
	case keyBackspace:
		if prev == f.caret {
			return false
		}
		f.value = f.value[:prev] + f.value[f.caret:]
		f.caret = prev
		return true
	case keyDelete:
		if next == f.caret {
			return false
		}
		f.value = f.value[:f.caret] + f.value[next:]
		return true
	default:
		if k.Rune == 0 || k.Ctrl || k.Alt {
			return false
		}
		s := string(k.Rune)
		if len(f.value)+len(s) > f.Max {
			return false
		}
		f.value = f.value[:f.caret] + s + f.value[f.caret:]
		f.caret += len(s)
	}
	return before != f.caret
}
func (f *textField) Draw(c widgets.RectCanvas) {
	if f.R.Empty() {
		return
	}
	// Opaque at the canvas boundary: the raster path honours alpha where the
	// kernel fill batcher always forced X=ff.
	c.FillRect(f.R, draw.Opaque(f.Bg))
	text := f.Prefix + f.value
	if text == "" {
		text = f.Placeholder
	}
	widgets.DrawText(c, f.R, text, draw.Opaque(f.Fg))
	if f.Focused {
		col := utf8.RuneCountInString(f.Prefix + f.value[:f.caret])
		x := max(f.R.X+2, min(f.R.X+2+col*8, f.R.Right()-3))
		c.FillRect(widgets.Rect{X: x, Y: f.R.Y + 2, W: 2, H: f.R.H - 4}, draw.Opaque(f.Caret))
	}
}

// dropdownCtl is GOSET's vocabulary popover — the dropdown adoption (M104d's
// control) without appkit.Dropdown, which would drag shlib's builtin table
// past the image budget (the same reason the bounded textField lives here).
// The anchor row's own vocabulary is the option list; the kernel reader
// stays the authority on what a saved value means.
type dropdownCtl struct {
	open  bool
	key   string
	r     widgets.Rect // the popover plate
	rowH  int
	vocab []string
}

// openAt parks the popover under the anchor row, flipping above it when the
// options would run off the window's bottom edge.
func (d *dropdownCtl) openAt(key string, vocab []string, anchor widgets.Rect, winH int) {
	d.key, d.vocab, d.rowH = key, vocab, 18
	d.r = widgets.Rect{X: anchor.Right() - 148, Y: anchor.Y + anchor.H,
		W: 140, H: len(vocab) * d.rowH}
	if d.r.Bottom() > winH {
		d.r.Y = anchor.Y - d.r.H
	}
	d.open = true
}

// optionAt is the popover row under (x,y), or -1 outside it.
func (d *dropdownCtl) optionAt(x, y int) int {
	if !d.r.Contains(x, y) || d.rowH <= 0 {
		return -1
	}
	i := (y - d.r.Y) / d.rowH
	if i < 0 || i >= len(d.vocab) {
		return -1
	}
	return i
}

// Draw paints the plate: a surface plate with the border, then one option
// row per vocabulary entry with the current value highlighted.
func (d *dropdownCtl) Draw(c widgets.RectCanvas, cur string) {
	if d.r.Empty() {
		return
	}
	th := theme.Current
	c.FillRect(d.r, draw.Opaque(th.Border))
	c.FillRect(d.r.Inset(1), draw.Opaque(th.Surface))
	for i, v := range d.vocab {
		rr := widgets.Rect{X: d.r.X + 1, Y: d.r.Y + i*d.rowH, W: d.r.W - 2, H: d.rowH}
		fg := th.Text
		if v == cur {
			c.FillRect(rr, draw.Opaque(th.Selection))
		}
		widgets.DrawText(c, rr.Inset(4), v, draw.Opaque(fg))
	}
}
