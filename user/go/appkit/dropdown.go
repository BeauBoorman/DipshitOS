package appkit

import (
	"virelai/draw"
	"virelai/icons"
	"virelai/theme"
	"virelai/ttf"
	"virelai/widgets"
)

// radiusControl and radiusWindow are the §2.2 corner radii for control
// plates and floating plates (dialogs, popovers). widgets keeps its own
// radiusControl unexported; appkit names them where it composes plates.
const (
	radiusControl = 4
	radiusWindow  = 8
)

// dropdownRowH is the §2.4 default row height.
const dropdownRowH = 24

// Dropdown is the §5.2 select control — goset's multi-valued vocab rows
// (theme, font_size, keyboard_layout, wm, shell) are the forcing
// consumers. The closed control is a radiusControl button carrying the
// current value and a chevron-down affordance; open, its list is a
// radiusWindow popover plate — the contract's FillShadow + PushClip
// consumer — whose rows take the §2.3 selected marker.
//
// It lives in appkit rather than widgets because the popover's shadow and
// clip stack only exist on *draw.BufferCanvas, and the import direction is
// fixed (draw imports widgets, never the reverse). On any other canvas the
// popover degrades to the flat v1 look: plate, border, bitmap labels — the
// §1 FillerCanvas rule.
type Dropdown struct {
	R         widgets.Rect // the closed button plate
	Items     []string
	Sel       int // committed selection; <0 → none
	RowH      int // row height; <=0 → dropdownRowH
	MaxRows   int // visible-row cap; <=0 → every row
	ScrollTop int // first visible item when the list overflows MaxRows
	Open      bool
	Upward    bool // popover opens above the button (bottom-of-window rows)
	Hovered   bool // button hover
	Pressed   bool // button press
	Focused   bool
	Disabled  bool
	HoverRow  int // hovered popover item; <0 → none
	// UIFace is the §3.4 optional TrueType label face — nil keeps the 8x8
	// bitmap face. IconFace carries the chevron-down glyph (E009); nil
	// degrades to a text "v" until M104g's batch-2 glyph lands.
	UIFace   *ttf.Face
	IconFace *ttf.Face
}

// Bounds is the button plate — the popover is transient chrome, so HitTest
// covers it separately while the list is open.
func (d *Dropdown) Bounds() widgets.Rect { return d.R }

// HitTest covers the button plate always and the popover while open — the
// same regions Draw paints.
func (d *Dropdown) HitTest(x, y int) bool {
	if d.R.Contains(x, y) {
		return true
	}
	return d.Open && len(d.Items) > 0 && d.PopoverRect().Contains(x, y)
}

// rowH is the effective row height.
func (d *Dropdown) rowH() int {
	if d.RowH > 0 {
		return d.RowH
	}
	return dropdownRowH
}

// visible is how many rows the popover shows at once.
func (d *Dropdown) visible() int {
	n := len(d.Items)
	if d.MaxRows > 0 && n > d.MaxRows {
		n = d.MaxRows
	}
	return n
}

// clampTop is ScrollTop bounded to the legal window.
func (d *Dropdown) clampTop() int {
	top := d.ScrollTop
	if m := len(d.Items) - d.visible(); top > m {
		top = m
	}
	if top < 0 {
		top = 0
	}
	return top
}

// PopoverRect is the open list's plate — the one geometry source Draw,
// ItemAt and RowRect all read. It hangs PadXS below the button, or above
// it when Upward is set.
func (d *Dropdown) PopoverRect() widgets.Rect {
	h := d.visible()*d.rowH() + 2*theme.Current.BorderW
	y := d.R.Bottom() + theme.Current.PadXS
	if d.Upward {
		y = d.R.Y - theme.Current.PadXS - h
	}
	return widgets.Rect{X: d.R.X, Y: y, W: d.R.W, H: h}
}

// RowRect is item i's rect inside the popover — valid only for items in
// the visible window [clampTop, clampTop+visible).
func (d *Dropdown) RowRect(i int) widgets.Rect {
	pop := d.PopoverRect()
	return widgets.Rect{
		X: pop.X + theme.Current.BorderW,
		Y: pop.Y + theme.Current.BorderW + (i-d.clampTop())*d.rowH(),
		W: pop.W - 2*theme.Current.BorderW,
		H: d.rowH(),
	}
}

// ItemAt is RowRect's inverse: the item a point hits, or -1. It reads the
// same arithmetic, so a point inside RowRect(i) always maps to i.
func (d *Dropdown) ItemAt(x, y int) int {
	if !d.Open {
		return -1
	}
	pop := d.PopoverRect()
	if !pop.Contains(x, y) {
		return -1
	}
	row := (y - pop.Y - theme.Current.BorderW) / d.rowH()
	top := d.clampTop()
	if i := top + row; row >= 0 && i < len(d.Items) && i < top+d.visible() {
		return i
	}
	return -1
}

// SetFocused is the FocusRing hook.
func (d *Dropdown) SetFocused(v bool) { d.Focused = v }

// SetOpen opens or dismisses the popover; a disabled control stays shut.
// Opening clamps ScrollTop and scrolls the selection into view.
func (d *Dropdown) SetOpen(v bool) {
	if v && d.Disabled {
		return
	}
	d.Open = v
	if v {
		d.ScrollTop = d.clampTop()
		d.ensureVisible(d.Sel)
	}
}

// Choose commits item i and dismisses the popover.
func (d *Dropdown) Choose(i int) bool {
	if i < 0 || i >= len(d.Items) {
		return false
	}
	changed := i != d.Sel || d.Open
	d.Sel, d.Open = i, false
	return changed
}

// ensureVisible scrolls item i inside the popover window.
func (d *Dropdown) ensureVisible(i int) {
	if vis := d.visible(); vis > 0 {
		if i < d.ScrollTop {
			d.ScrollTop = i
		}
		if i >= d.ScrollTop+vis {
			d.ScrollTop = i - vis + 1
		}
	}
	d.ScrollTop = d.clampTop()
}

// moveHover steps the hover highlight and keeps it visible — the keyboard
// path's highlight, distinct from the committed Sel until Enter lands.
func (d *Dropdown) moveHover(delta int) bool {
	if len(d.Items) == 0 {
		return false
	}
	i := d.HoverRow
	if i < 0 {
		i = d.Sel
	}
	i += delta
	if i < 0 {
		i = 0
	}
	if i >= len(d.Items) {
		i = len(d.Items) - 1
	}
	changed := i != d.HoverRow
	d.HoverRow = i
	d.ensureVisible(i)
	return changed
}

// OnKey is the Focusable key path. Enter opens a closed control and
// commits the hovered row in an open one; Escape dismisses; Up/Down move
// the highlight (Down opens first, the platform convention).
func (d *Dropdown) OnKey(k Key) bool {
	if d.Disabled {
		return false
	}
	switch k.Named() {
	case NamedEnter:
		if !d.Open {
			d.SetOpen(true)
			return true
		}
		if d.HoverRow >= 0 {
			return d.Choose(d.HoverRow)
		}
		if d.Sel >= 0 {
			d.Open = false
			return true
		}
		return false
	case NamedEscape:
		if d.Open {
			d.Open = false
			return true
		}
		return false
	case NamedDown:
		if !d.Open {
			d.SetOpen(true)
			return true
		}
		return d.moveHover(1)
	case NamedUp:
		if !d.Open {
			return false
		}
		return d.moveHover(-1)
	}
	return false
}

// OnClick is the Focusable pointer path: the button toggles the popover, a
// row click commits, and a click anywhere else dismisses an open list.
func (d *Dropdown) OnClick(x, y int) bool {
	if d.Disabled {
		return false
	}
	if d.R.Contains(x, y) {
		d.SetOpen(!d.Open)
		return true
	}
	if !d.Open {
		return false
	}
	if i := d.ItemAt(x, y); i >= 0 {
		return d.Choose(i)
	}
	d.Open = false
	return true
}

// chevRect is the chevron affordance cell — right-aligned, 16×16.
func (d *Dropdown) chevRect() widgets.Rect {
	return widgets.Rect{
		X: d.R.Right() - theme.Current.PadSM - icons.NominalPx,
		Y: d.R.Y + (d.R.H-icons.NominalPx)/2,
		W: icons.NominalPx, H: icons.NominalPx,
	}
}

// Draw paints the button and, while open, the popover. The full-Canvas
// path is the §2.2/§2.3 form; on a *draw.BufferCanvas the popover also
// casts the §2.5 shadow and clips its rows through the clip stack.
func (d *Dropdown) Draw(c widgets.RectCanvas) {
	if d.R.Empty() {
		return
	}
	th := theme.Current
	fc, full := c.(widgets.Canvas)
	face, label := th.BtnIdle, th.Text
	switch {
	case d.Disabled:
		face, label = blendHalf(th.BtnIdle, th.Surface), th.Muted
	case d.Pressed || d.Open:
		face = th.BtnPressed
	case d.Hovered:
		face = th.BtnHover
	}
	if full {
		fc.FillRoundedRect(d.R, radiusControl, draw.Opaque(face))
		fc.StrokeRoundedRect(d.R, radiusControl, th.BorderW, draw.Opaque(th.Border))
		if d.Focused && !d.Disabled {
			fc.StrokeRoundedRect(d.R, radiusControl, th.FocusW, draw.Opaque(th.Accent))
		}
	} else {
		c.FillRect(d.R, th.Border)
		if inner := d.R.Inset(th.BorderW); !inner.Empty() {
			c.FillRect(inner, face)
		}
	}
	chev := d.chevRect()
	value := ""
	if d.Sel >= 0 && d.Sel < len(d.Items) {
		value = d.Items[d.Sel]
	}
	labR := widgets.Rect{X: d.R.X + th.BorderW, Y: d.R.Y + th.BorderW,
		W: chev.X - d.R.X - 2*th.BorderW, H: d.R.H - 2*th.BorderW}
	if full {
		x, y := labR.X+th.PadXS, 0
		if d.UIFace != nil {
			asc, desc, _ := d.UIFace.LineMetrics(labelPx)
			y = labR.Y + (labR.H-asc-desc)/2 + asc
		}
		fc.Text(d.UIFace, labR, x, y, labelPx, value, draw.Opaque(label))
	} else {
		widgets.DrawText(c, labR, value, label)
	}
	// The chevron-down affordance (E009). A missing icon face degrades to
	// text, never a blank — the batch-1 glyph is already in CHROME.TTF.
	if full && d.IconFace != nil {
		if cp, ok := icons.Codepoint("chevron-down"); ok {
			asc, desc, _ := d.IconFace.LineMetrics(icons.NominalPx)
			draw.Glyph(fc, d.IconFace, chev, chev.X, chev.Y+(chev.H-asc-desc)/2+asc,
				icons.NominalPx, cp, draw.Opaque(label))
		}
	} else {
		widgets.DrawText(c, chev, "v", label)
	}
	if d.Open {
		d.drawPopover(c, fc, full)
	}
}

// drawPopover paints the open list. On *draw.BufferCanvas it is the §5.2
// consumer: the §2.5 shadow under the plate and PushClip guarding the row
// fills and labels inside the border. Other canvases paint the flat form
// — rows are clipped by construction (RowRect lives inside the plate).
func (d *Dropdown) drawPopover(c widgets.RectCanvas, fc widgets.Canvas, full bool) {
	if len(d.Items) == 0 || d.visible() == 0 {
		return
	}
	th := theme.Current
	pop := d.PopoverRect()
	inner := pop.Inset(th.BorderW)
	bc, buf := c.(*draw.BufferCanvas)
	if buf {
		// §2.5: one shared shadow — dy 4, blur 16, peak alpha 0x40.
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
	bar := len(d.Items) > d.visible()
	rowsW := inner.W
	if bar {
		rowsW -= widgets.ScrollbarW + th.PadXS
	}
	top := d.clampTop()
	fg := th.Text
	if d.Disabled {
		fg = th.Muted
	}
	for i := top; i < len(d.Items) && i < top+d.visible(); i++ {
		rr := d.RowRect(i)
		// The row highlight is inset PadXS off the plate edge — the
		// popover's rounded corners stay clean and the marker keeps the
		// §2.3 3px Accent left-edge vocabulary.
		fill := widgets.Rect{X: rr.X + th.PadXS, Y: rr.Y, W: rowsW - 2*th.PadXS, H: rr.H}
		label := widgets.Rect{X: fill.X + th.PadXS, Y: rr.Y, W: fill.W - 2*th.PadXS, H: rr.H}
		switch i {
		case d.Sel:
			if full {
				fc.FillRect(fill, draw.Opaque(th.Selection))
				mark := widgets.Rect{X: fill.X, Y: fill.Y + 1, W: 3, H: fill.H - 2}
				fc.FillRect(mark, draw.Opaque(th.Accent))
			} else {
				c.FillRect(fill, th.Selection)
				c.FillRect(widgets.Rect{X: fill.X, Y: fill.Y + 1, W: 3, H: fill.H - 2}, th.Accent)
			}
			label.X += 3 + th.PadXS
			label.W -= 3 + th.PadXS
		case d.HoverRow:
			if full {
				fc.FillRect(fill, draw.Opaque(th.BtnHover))
			} else {
				c.FillRect(fill, th.BtnHover)
			}
		}
		if full {
			x, y := label.X, 0
			if d.UIFace != nil {
				asc, desc, _ := d.UIFace.LineMetrics(labelPx)
				y = label.Y + (label.H-asc-desc)/2 + asc
			}
			fc.Text(d.UIFace, label, x, y, labelPx, d.Items[i], draw.Opaque(fg))
		} else {
			widgets.DrawText(c, label, d.Items[i], fg)
		}
	}
	if bar {
		(&widgets.Scrollbar{
			R:        widgets.Rect{X: inner.Right() - widgets.ScrollbarW, Y: inner.Y, W: widgets.ScrollbarW, H: inner.H},
			Total:    len(d.Items),
			Viewport: d.visible(),
			Offset:   top,
		}).Draw(c)
	}
}
