package appkit

// The M137b (#2772) menu bar: a top strip of titled menus with mnemonics,
// each dropping a popover that shares the dropdown's §2.5 shadow + clip
// surface. F10 or a bare Alt press engages menu mode; an open menu owns the
// keyboard until Escape backs out one level, and items call back through
// Action — fired inside OnKey/OnClick, so the app's existing Loop sees the
// dirty bit and repaints.
//
// It lives in appkit rather than widgets for the same reason Dropdown does:
// the popover's shadow and clip stack only exist on *draw.BufferCanvas. On a
// fill-only canvas it degrades to flat plates and bitmap labels (§1).

import (
	"unicode/utf8"

	"virelai/draw"
	"virelai/theme"
	"virelai/ttf"
	"virelai/widgets"
)

// HID usages menu mode answers to beyond the Named vocabulary: F10 (0x43,
// mapped to NamedF10) and the bare Alt modifiers — pressing Alt alone is the
// platform's second spell for "focus the menu bar".
const (
	usageAltL = 0xe2
	usageAltR = 0xe6
)

// menuRowH is the popover row height — the §2.4 default the dropdown uses.
const menuRowH = 24

// MenuItem is one row in an open menu. Label may carry one '&' mnemonic
// marker ("&Quit"): the following rune is underlined while the bar is Active
// and fires the item when typed in the open menu. Shortcut is a right-aligned
// hint string painted in Muted (display only — the keys themselves are the
// app's chord layer). Action runs on choose; its bool reports whether the
// app state changed, mirroring SettingHandler — the popover closing counts
// as a change either way.
type MenuItem struct {
	Label    string
	Shortcut string
	Disabled bool
	Action   func() bool
}

// Menu is one titled drop-down on the bar.
type Menu struct {
	Title string // "&File" — '&' marks the mnemonic
	Items []MenuItem
}

// MenuBar is the Focusable menu strip. R is the bar plate (typically the
// window's full width, one row tall). Menus are the model; Active/Bar/Open/
// Hover are the interaction state a caller may read but should only write
// through Activate/OpenMenu/Close.
type MenuBar struct {
	R       widgets.Rect
	Menus   []Menu
	Active  bool // menu mode engaged (F10, Alt, click, or ring Enter)
	Open    bool // a popover is dropped; the open menu is Menus[Bar]
	Bar     int  // highlighted (or open) title while Active
	Hover   int  // highlighted item in the open menu; -1 → none
	Focused bool
	// UIFace is the §3.4 optional TrueType label face — nil keeps the 8x8
	// bitmap face.
	UIFace *ttf.Face
}

// Bounds is the bar plate.
func (b *MenuBar) Bounds() widgets.Rect { return b.R }

// HitTest covers the bar always and the open popover while one is up — the
// same regions Draw paints.
func (b *MenuBar) HitTest(x, y int) bool {
	if b.R.Contains(x, y) {
		return true
	}
	return b.Open && b.Bar >= 0 && b.Bar < len(b.Menus) && b.PopoverRect(b.Bar).Contains(x, y)
}

// SetFocused is the FocusRing hook. Note it is distinct from Active: a ring
// can focus the bar without engaging menu mode.
func (b *MenuBar) SetFocused(v bool) { b.Focused = v }

// mnemonic splits a label at its first '&' marker: text is the display
// string without it, mark the byte offset of the mnemonic rune inside text
// (-1 when absent), mn the mnemonic itself folded to ASCII lowercase.
func mnemonic(s string) (text string, mark int, mn rune) {
	for i := 0; i < len(s); i++ {
		if s[i] != '&' {
			continue
		}
		text = s[:i] + s[i+1:]
		if i >= len(text) {
			return text, -1, 0 // trailing '&' marks nothing
		}
		r, _ := utf8.DecodeRuneInString(text[i:])
		return text, i, foldASCII(r)
	}
	return s, -1, 0
}

// textW measures a label in the active face — UIFace advances at chrome size,
// or 8px bitmap cells when the degrade face is painting.
func (b *MenuBar) textW(s string) int {
	if b.UIFace == nil {
		return utf8.RuneCountInString(s) * glyphW
	}
	w := 0
	for _, r := range s {
		w += b.UIFace.AdvancePx(r, labelPx)
	}
	return w
}

// TitleRect is menu i's clickable plate on the bar — the one geometry source
// Draw and TitleAt share.
func (b *MenuBar) TitleRect(i int) widgets.Rect {
	th := theme.Current
	x := b.R.X + th.PadXS
	for j := 0; j < i && j < len(b.Menus); j++ {
		title, _, _ := mnemonic(b.Menus[j].Title)
		x += b.textW(title) + 2*th.PadMD
	}
	title, _, _ := mnemonic(b.Menus[i].Title)
	return widgets.Rect{X: x, Y: b.R.Y, W: b.textW(title) + 2*th.PadMD, H: b.R.H}
}

// TitleAt is TitleRect's inverse: the menu a bar-space point hits, or -1.
func (b *MenuBar) TitleAt(x, y int) int {
	if !b.R.Contains(x, y) {
		return -1
	}
	for i := range b.Menus {
		if b.TitleRect(i).Contains(x, y) {
			return i
		}
	}
	return -1
}

// PopoverRect is menu i's drop-down plate: flush under the bar, wide enough
// for the longest label-plus-shortcut row, clamped inside the bar's own
// span when the bar gives it room.
func (b *MenuBar) PopoverRect(i int) widgets.Rect {
	th := theme.Current
	w := 0
	for _, it := range b.Menus[i].Items {
		label, _, _ := mnemonic(it.Label)
		iw := 2*th.PadMD + b.textW(label)
		if it.Shortcut != "" {
			iw += th.PadLG + b.textW(it.Shortcut)
		}
		if iw > w {
			w = iw
		}
	}
	if w < 96 {
		w = 96
	}
	h := len(b.Menus[i].Items)*menuRowH + 2*th.BorderW
	x := b.TitleRect(i).X
	if b.R.W > w && x+w > b.R.Right()-th.PadXS {
		x = b.R.Right() - th.PadXS - w
	}
	if x < b.R.X {
		x = b.R.X
	}
	return widgets.Rect{X: x, Y: b.R.Bottom(), W: w, H: h}
}

// ItemRect is item j's row inside menu i's open popover.
func (b *MenuBar) ItemRect(i, j int) widgets.Rect {
	pop := b.PopoverRect(i)
	bw := theme.Current.BorderW
	return widgets.Rect{
		X: pop.X + bw,
		Y: pop.Y + bw + j*menuRowH,
		W: pop.W - 2*bw,
		H: menuRowH,
	}
}

// ItemAt is ItemRect's inverse over the open menu: the item a point hits,
// or -1 (also when nothing is open).
func (b *MenuBar) ItemAt(x, y int) int {
	if !b.Open || b.Bar < 0 || b.Bar >= len(b.Menus) {
		return -1
	}
	pop := b.PopoverRect(b.Bar)
	if !pop.Contains(x, y) {
		return -1
	}
	bw := theme.Current.BorderW
	j := (y - pop.Y - bw) / menuRowH
	if j < 0 || j >= len(b.Menus[b.Bar].Items) {
		return -1
	}
	return j
}

// Activate engages menu mode on title i without opening its menu — the F10
// and bare-Alt entry.
func (b *MenuBar) Activate(i int) bool {
	if len(b.Menus) == 0 {
		return false
	}
	if i < 0 {
		i = 0
	}
	if i >= len(b.Menus) {
		i = len(b.Menus) - 1
	}
	changed := !b.Active || b.Bar != i || b.Open
	b.Active, b.Bar, b.Open, b.Hover = true, i, false, -1
	return changed
}

// OpenMenu engages menu mode and drops menu i, highlighting its first
// enabled item.
func (b *MenuBar) OpenMenu(i int) bool {
	if i < 0 || i >= len(b.Menus) {
		return false
	}
	b.Active, b.Open, b.Bar = true, true, i
	b.Hover = b.firstEnabled(i)
	return true
}

// Close disengages menu mode entirely.
func (b *MenuBar) Close() bool {
	if !b.Active && !b.Open {
		return false
	}
	b.Active, b.Open, b.Hover = false, false, -1
	return true
}

// firstEnabled is menu i's first non-disabled item index, or -1.
func (b *MenuBar) firstEnabled(i int) int {
	for j := range b.Menus[i].Items {
		if !b.Menus[i].Items[j].Disabled {
			return j
		}
	}
	return -1
}

// lastEnabled is menu i's last non-disabled item index, or -1.
func (b *MenuBar) lastEnabled(i int) int {
	for j := len(b.Menus[i].Items) - 1; j >= 0; j-- {
		if !b.Menus[i].Items[j].Disabled {
			return j
		}
	}
	return -1
}

// moveHover steps the open menu's highlight by delta, wrapping and skipping
// disabled rows.
func (b *MenuBar) moveHover(delta int) bool {
	m := &b.Menus[b.Bar]
	n := len(m.Items)
	if n == 0 {
		return false
	}
	j := b.Hover
	for step := 0; step < n; step++ {
		j += delta
		if j < 0 {
			j = n - 1
		}
		if j >= n {
			j = 0
		}
		if !m.Items[j].Disabled {
			b.Hover = j
			return true
		}
	}
	return false
}

// fire runs the hovered item's Action and disengages. Disabled items refuse:
// the menu stays open.
func (b *MenuBar) fire() bool {
	if !b.Open || b.Hover < 0 {
		return true
	}
	it := &b.Menus[b.Bar].Items[b.Hover]
	if it.Disabled {
		return true
	}
	b.Open, b.Hover = false, -1
	b.Active = false
	if it.Action != nil {
		it.Action()
	}
	return true
}

// titleMatch is the first menu whose title mnemonic equals folded rune r,
// or -1.
func (b *MenuBar) titleMatch(r rune) int {
	for i := range b.Menus {
		_, _, mn := mnemonic(b.Menus[i].Title)
		if mn != 0 && mn == r {
			return i
		}
	}
	return -1
}

// itemMatchRune finds menu i's enabled item whose mnemonic equals rune r.
func (b *MenuBar) itemMatchRune(i int, r rune) int {
	for j := range b.Menus[i].Items {
		_, _, mn := mnemonic(b.Menus[i].Items[j].Label)
		if mn != 0 && mn == r && !b.Menus[i].Items[j].Disabled {
			return j
		}
	}
	return -1
}

// itemPrefix circularly scans menu i's enabled items from Hover+1 for a
// label starting with rune r — the single-letter hop.
func (b *MenuBar) itemPrefix(i int, r rune) int {
	m := &b.Menus[i]
	n := len(m.Items)
	for step := 1; step <= n; step++ {
		j := (b.Hover + step) % n
		if j < 0 {
			j += n
		}
		if m.Items[j].Disabled {
			continue
		}
		label, _, _ := mnemonic(m.Items[j].Label)
		if lr, _ := utf8.DecodeRuneInString(label); lr != 0 && foldASCII(lr) == r {
			return j
		}
	}
	return -1
}

// OnKey is the Focusable key path and the whole menu-mode state machine.
// Inactive, it answers F10, bare Alt, Alt+mnemonic, and Enter while focused
// — everything else falls through to the rest of the app. Active, the bar
// owns the keyboard: arrows drive titles and items, Enter opens or fires,
// Escape backs out one level, and unmatched keys are swallowed until menu
// mode is disengaged.
func (b *MenuBar) OnKey(k Key) bool {
	if len(b.Menus) == 0 {
		return false
	}
	altKey := k.Usage == usageAltL || k.Usage == usageAltR
	if !b.Active {
		switch {
		case k.Named() == NamedF10 || altKey:
			return b.Activate(0)
		case k.Named() == NamedEnter && b.Focused:
			return b.Activate(0)
		case k.Alt && k.Rune != 0:
			if i := b.titleMatch(foldASCII(k.Rune)); i >= 0 {
				return b.OpenMenu(i)
			}
		}
		return false
	}
	// Menu mode owns the keyboard until it is disengaged.
	switch k.Named() {
	case NamedF10:
		return b.Close()
	case NamedEscape:
		if b.Open {
			b.Open, b.Hover = false, -1
			return true
		}
		return b.Close()
	}
	if altKey {
		return b.Close()
	}
	if k.Alt && k.Rune != 0 {
		if i := b.titleMatch(foldASCII(k.Rune)); i >= 0 {
			return b.OpenMenu(i)
		}
		return true
	}
	if !b.Open {
		switch k.Named() {
		case NamedLeft:
			b.Bar = (b.Bar - 1 + len(b.Menus)) % len(b.Menus)
			return true
		case NamedRight:
			b.Bar = (b.Bar + 1) % len(b.Menus)
			return true
		case NamedDown, NamedEnter:
			return b.OpenMenu(b.Bar)
		}
		if k.Rune != 0 && !k.Ctrl {
			if i := b.titleMatch(foldASCII(k.Rune)); i >= 0 {
				return b.OpenMenu(i)
			}
		}
		return true
	}
	switch k.Named() {
	case NamedLeft:
		return b.OpenMenu((b.Bar - 1 + len(b.Menus)) % len(b.Menus))
	case NamedRight:
		return b.OpenMenu((b.Bar + 1) % len(b.Menus))
	case NamedUp:
		b.moveHover(-1)
		return true
	case NamedDown:
		b.moveHover(1)
		return true
	case NamedHome:
		b.Hover = b.firstEnabled(b.Bar)
		return true
	case NamedEnd:
		b.Hover = b.lastEnabled(b.Bar)
		return true
	case NamedEnter:
		return b.fire()
	}
	if k.Rune != 0 && !k.Ctrl {
		r := foldASCII(k.Rune)
		if j := b.itemMatchRune(b.Bar, r); j >= 0 {
			b.Hover = j
			return b.fire()
		}
		if j := b.itemPrefix(b.Bar, r); j >= 0 {
			b.Hover = j
		}
	}
	return true
}

// OnClick is the Focusable pointer path: a title opens (or closes) its menu,
// an item fires, and anywhere else disengages an active bar.
func (b *MenuBar) OnClick(x, y int) bool {
	if i := b.TitleAt(x, y); i >= 0 {
		if b.Open && b.Bar == i {
			b.Open, b.Hover = false, -1
			return true
		}
		return b.OpenMenu(i)
	}
	if j := b.ItemAt(x, y); j >= 0 {
		b.Hover = j
		return b.fire()
	}
	return b.Close()
}

// runText paints one clipped run with the pen at x — through Canvas.Text on
// a full canvas (nil face degrades inside it), or the bitmap painter on a
// fill-only surface.
func (b *MenuBar) runText(c widgets.RectCanvas, clip widgets.Rect, x int, s string, rgb uint32) {
	if s == "" || clip.Empty() {
		return
	}
	if fc, ok := c.(widgets.Canvas); ok {
		y := 0
		if b.UIFace != nil {
			asc, desc, _ := b.UIFace.LineMetrics(labelPx)
			y = clip.Y + (clip.H-asc-desc)/2 + asc
		}
		fc.Text(b.UIFace, clip, x, y, labelPx, s, draw.Opaque(rgb))
		return
	}
	// drawGlyphRun anchors at the plate's own inset — shift the clip so the
	// run lands at x.
	shift := widgets.Rect{X: x - 2, Y: clip.Y, W: clip.Right() - x + 2, H: clip.H}
	widgets.DrawText(c, shift, s, rgb)
}

// underlineMnemonic paints the 1px mnemonic underline inside a plate whose
// label starts at x: the folded-rune's advance span at the label's baseline
// area, the same cue the bitmap degrade paints.
func (b *MenuBar) underlineMnemonic(c widgets.RectCanvas, plate widgets.Rect, x, mark int, text string, rgb uint32) {
	if mark < 0 || mark >= len(text) {
		return
	}
	_, size := utf8.DecodeRuneInString(text[mark:])
	x0 := x + b.textW(text[:mark])
	w := b.textW(text[mark : mark+size])
	y := plate.Bottom() - theme.Current.PadSM - 1
	c.FillRect(widgets.Rect{X: x0, Y: y, W: w, H: 1}, rgb)
}

// Draw paints the bar, the title plates with their state ramps and mnemonic
// underlines, and the open menu's popover — the §2.5 shadow + clip consumer
// on *draw.BufferCanvas, flat plates elsewhere.
func (b *MenuBar) Draw(c widgets.RectCanvas) {
	if b.R.Empty() || len(b.Menus) == 0 {
		return
	}
	th := theme.Current
	fc, full := c.(widgets.Canvas)
	if full {
		fc.FillRect(b.R, draw.Opaque(th.ChromeBg))
	} else {
		c.FillRect(b.R, th.ChromeBg)
	}
	c.FillRect(widgets.Rect{X: b.R.X, Y: b.R.Bottom() - 1, W: b.R.W, H: 1}, th.Rule)
	for i := range b.Menus {
		tr := b.TitleRect(i)
		title, mark, _ := mnemonic(b.Menus[i].Title)
		face := uint32(0)
		switch {
		case b.Open && i == b.Bar:
			face = th.BtnPressed
		case b.Active && i == b.Bar:
			face = th.BtnHover
		}
		if face != 0 {
			if full {
				fc.FillRect(tr, draw.Opaque(face))
			} else {
				c.FillRect(tr, face)
			}
		}
		x := tr.X + th.PadMD
		b.runText(c, tr, x, title, th.Text)
		if b.Active {
			b.underlineMnemonic(c, tr, x, mark, title, th.Text)
		}
	}
	if b.Focused && !b.Active {
		if full {
			fc.StrokeRoundedRect(b.R, radiusControl, th.FocusW, draw.Opaque(th.Accent))
		} else {
			fw := th.FocusW
			if fw < 1 {
				fw = 1
			}
			c.FillRect(widgets.Rect{X: b.R.X, Y: b.R.Y, W: b.R.W, H: fw}, th.Accent)
			c.FillRect(widgets.Rect{X: b.R.X, Y: b.R.Bottom() - fw, W: b.R.W, H: fw}, th.Accent)
			c.FillRect(widgets.Rect{X: b.R.X, Y: b.R.Y, W: fw, H: b.R.H}, th.Accent)
			c.FillRect(widgets.Rect{X: b.R.Right() - fw, Y: b.R.Y, W: fw, H: b.R.H}, th.Accent)
		}
	}
	if b.Open && b.Bar >= 0 && b.Bar < len(b.Menus) {
		b.drawMenu(c, fc, full)
	}
}

// drawMenu paints the open popover — the dropdown's §5.2 contract verbatim:
// one shared §2.5 shadow under the plate, row fills and labels guarded by
// the clip stack on *draw.BufferCanvas, flat plates on other canvases.
func (b *MenuBar) drawMenu(c widgets.RectCanvas, fc widgets.Canvas, full bool) {
	m := &b.Menus[b.Bar]
	if len(m.Items) == 0 {
		return
	}
	th := theme.Current
	pop := b.PopoverRect(b.Bar)
	inner := pop.Inset(th.BorderW)
	bc, buf := c.(*draw.BufferCanvas)
	if buf {
		draw.FillShadow(bc, pop, radiusWindow, th.PadLG, th.PadSM,
			th.Shadow&0xffffff|0x40000000)
	}
	if full {
		fc.FillRoundedRect(pop, radiusWindow, draw.Opaque(th.Surface))
		fc.StrokeRoundedRect(pop, radiusWindow, th.BorderW, draw.Opaque(th.Border))
		if buf {
			bc.PushClip(inner)
			defer bc.PopClip()
		}
	} else {
		c.FillRect(pop, th.Border)
		if !inner.Empty() {
			c.FillRect(inner, th.Surface)
		}
	}
	for j := range m.Items {
		it := &m.Items[j]
		rr := b.ItemRect(b.Bar, j)
		fg := th.Text
		if it.Disabled {
			fg = th.Muted
		}
		if j == b.Hover && !it.Disabled {
			fill := widgets.Rect{X: rr.X + th.PadXS, Y: rr.Y, W: rr.W - 2*th.PadXS, H: rr.H}
			if full {
				fc.FillRect(fill, draw.Opaque(th.BtnHover))
			} else {
				c.FillRect(fill, th.BtnHover)
			}
		}
		label, mark, _ := mnemonic(it.Label)
		lx := rr.X + th.PadMD
		b.runText(c, rr, lx, label, fg)
		if it.Shortcut != "" {
			sw := b.textW(it.Shortcut)
			b.runText(c, rr, rr.Right()-th.PadMD-sw, it.Shortcut, th.Muted)
		}
		if b.Active {
			b.underlineMnemonic(c, rr, lx, mark, label, fg)
		}
	}
}
