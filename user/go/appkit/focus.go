package appkit

import (
	"virelai/vi"
	"virelai/widgets"
)

// Key is the normalized keyboard shape consumed by appkit controls. The
// kernel event carries the HID usage in Arg0 and the decoded symbol in Arg1;
// controls should not need to know which apps historically read which field.
type Key struct {
	Usage uint32
	Rune  rune
	Ctrl  bool
	Shift bool
	Alt   bool
}

// Named reports the canonical HID usage for a key. The values are the USB HID
// usages used by the guest input path, not byte values from a tty stream.
func (k Key) Named() NamedKey {
	switch k.Usage {
	case 0x28:
		return NamedEnter
	case 0x29:
		return NamedEscape
	case 0x2a:
		return NamedBackspace
	case 0x2b:
		return NamedTab
	case 0x4c:
		return NamedDelete
	case 0x4a:
		return NamedHome
	case 0x4d:
		return NamedEnd
	case 0x4f:
		return NamedRight
	case 0x50:
		return NamedLeft
	case 0x51:
		return NamedDown
	case 0x52:
		return NamedUp
	case 0x4b:
		return NamedPageUp
	case 0x4e:
		return NamedPageDown
	case 0x43:
		return NamedF10
	}
	return NamedNone
}

// NamedKey is the appkit vocabulary for non-printable keyboard actions.
type NamedKey uint8

const (
	NamedNone NamedKey = iota
	NamedEnter
	NamedEscape
	NamedBackspace
	NamedTab
	NamedDelete
	NamedHome
	NamedEnd
	NamedRight
	NamedLeft
	NamedDown
	NamedUp
	NamedPageUp
	NamedPageDown
	NamedF10
)

// NormalizeKey converts one guest key event. Arg0 remains the source of HID
// usage, while Arg1 supplies printable text and the control-code spellings
// used by existing apps. A control code is not turned into a printable rune.
func NormalizeKey(ev vi.Event) (Key, bool) {
	if ev.Kind != vi.EvKeyDown {
		return Key{}, false
	}
	k := Key{
		Usage: ev.Arg0,
		Ctrl:  ev.Flags&vi.ModCtrl != 0,
		Shift: ev.Flags&vi.ModShift != 0,
		Alt:   ev.Flags&vi.ModAlt != 0,
	}
	if (ev.Arg1 >= 0x20 && ev.Arg1 < 0x7f || ev.Arg1 >= 0xa0) &&
		ev.Arg1 <= 0x10ffff &&
		(ev.Arg1 < 0xd800 || ev.Arg1 > 0xdfff) && !k.Ctrl {
		k.Rune = rune(ev.Arg1)
	}
	// Keep the existing control-code spellings useful to a normalized caller.
	// HID usages still win for named actions, so this is only a fallback when
	// an event source has no usage for the key.
	if k.Usage == 0 {
		switch ev.Arg1 {
		case '\r', '\n':
			k.Usage = 0x28
		case 0x1b:
			k.Usage = 0x29
		case 0x08, 0x7f:
			k.Usage = 0x2a
		case '\t':
			k.Usage = 0x2b
		}
	}
	return k, true
}

// Focusable is the small interaction contract shared by controls. Bounds and
// HitTest are inherited from widgets.Widget; OnKey returns whether the control
// consumed the key, and OnClick returns whether the click changed app state.
type Focusable interface {
	widgets.Widget
	OnKey(Key) bool
	OnClick(x, y int) bool
}

// FocusRing owns an ordered set of controls and the currently focused index.
// Tab and Shift-Tab wrap in both directions. A nil/disabled control is skipped
// when a caller supplies only active controls; this type itself does not
// invent policy for enabled state.
type FocusRing struct {
	items []Focusable
	index int
}

func NewFocusRing(items ...Focusable) *FocusRing {
	return &FocusRing{items: items, index: -1}
}

func (r *FocusRing) Len() int { return len(r.items) }

func (r *FocusRing) Current() (Focusable, int) {
	if r.index < 0 || r.index >= len(r.items) {
		return nil, -1
	}
	return r.items[r.index], r.index
}

func (r *FocusRing) Focus(i int) bool {
	if len(r.items) == 0 {
		return false
	}
	if i < 0 {
		i = len(r.items) - 1
	}
	if i >= len(r.items) {
		i = 0
	}
	changed := i != r.index
	if r.index >= 0 {
		if old, ok := r.items[r.index].(interface{ SetFocused(bool) }); ok {
			old.SetFocused(false)
		}
	}
	r.index = i
	if focused, ok := r.items[i].(interface{ SetFocused(bool) }); ok {
		focused.SetFocused(true)
	}
	return changed
}

func (r *FocusRing) FocusWidget(w Focusable) bool {
	for i, item := range r.items {
		if item == w {
			return r.Focus(i)
		}
	}
	return false
}

func (r *FocusRing) Next() bool {
	if len(r.items) == 0 {
		return false
	}
	if r.index < 0 {
		return r.Focus(0)
	}
	return r.Focus((r.index + 1) % len(r.items))
}

func (r *FocusRing) Prev() bool {
	if len(r.items) == 0 {
		return false
	}
	if r.index < 0 {
		return r.Focus(len(r.items) - 1)
	}
	return r.Focus((r.index - 1 + len(r.items)) % len(r.items))
}

// HandleKey routes Tab navigation to the ring and all other keys to the
// focused control. An unhandled printable key is not a ring-level event.
func (r *FocusRing) HandleKey(k Key) bool {
	if k.Named() == NamedTab {
		if k.Shift {
			return r.Prev()
		}
		return r.Next()
	}
	item, _ := r.Current()
	return item != nil && item.OnKey(k)
}

// ActionButton adapts the existing widgets.Button to Focusable without
// putting appkit event policy into the pixel-only widget package.
type ActionButton struct {
	Button     *widgets.Button
	OnActivate func() bool
}

func (b *ActionButton) Bounds() widgets.Rect      { return b.Button.Bounds() }
func (b *ActionButton) HitTest(x, y int) bool     { return b.Button.HitTest(x, y) }
func (b *ActionButton) Draw(c widgets.RectCanvas) { b.Button.Draw(c) }
func (b *ActionButton) SetFocused(v bool)         { b.Button.Focused = v }
func (b *ActionButton) OnKey(k Key) bool {
	if k.Named() != NamedEnter || b.OnActivate == nil {
		return false
	}
	return b.OnActivate()
}
func (b *ActionButton) OnClick(x, y int) bool {
	if !b.HitTest(x, y) || b.OnActivate == nil {
		return false
	}
	return b.OnActivate()
}

// HandleClick focuses the first matching control and then lets it consume the
// click. Later controls can overlap a button's label, so registration order is
// the documented z-order for this small primitive.
func (r *FocusRing) HandleClick(x, y int) bool {
	for i, item := range r.items {
		if item != nil && item.HitTest(x, y) {
			r.Focus(i)
			return item.OnClick(x, y)
		}
	}
	return false
}
