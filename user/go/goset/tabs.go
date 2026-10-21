package main

import (
	"virelai/draw"
	"virelai/theme"
	"virelai/widgets"
)

// M122e (#2574): the tab header strip — Settings / Services / Grants /
// Shortcuts / Profile / Access as clickable cells over the pane. The
// active tab IS the view
// (there is no separate highlight to apply): a click activates the cell's
// view through OnActivate, and Left/Right while the strip is focused steps
// the view the same way — pointer and keyboard reach the same switch.
//
// The strip is a bounded focus-ring control exactly like the M104f row
// affordances: geometry over the shared canvas, one source for draw and
// hit-test, and no appkit import (its shlib builtin table stays out of the
// image — the same reason the bounded textField lives in controls.go).
type tabStrip struct {
	R       widgets.Rect
	Focused bool
	// Active is the paint mirror; layout() refreshes it from Current, the
	// panel's truth — OnKey steps off Current so a key never needs a paint.
	Active     int
	Current    func() int
	OnActivate func(int) bool
}

// tabCount is the strip's cell count; tabNames mirrors the views in
// switch order — the `goset: tab <name>` marker is grep-anchored on it.
const (
	tabSettings = iota
	tabServices
	tabGrants
	tabShortcuts
	tabProfile
	tabAccess
	tabCount
)

var tabNames = [tabCount]string{"settings", "services", "grants", "shortcuts", "profile", "access"}

// cellRect is tab i's slice of the strip — the one geometry source Draw and
// the hit test share (the widget Bounds() pattern).
func (s *tabStrip) cellRect(i int) widgets.Rect {
	w := s.R.W / tabCount
	return widgets.Rect{X: s.R.X + i*w, Y: s.R.Y, W: w, H: s.R.H}
}

// tabAt is the cell under (x,y), or -1 outside the strip.
func (s *tabStrip) tabAt(x, y int) int {
	if !s.R.Contains(x, y) {
		return -1
	}
	for i := 0; i < tabCount; i++ {
		if s.cellRect(i).Contains(x, y) {
			return i
		}
	}
	return -1
}

func (s *tabStrip) HitTest(x, y int) bool { return s.R.Contains(x, y) }
func (s *tabStrip) SetFocused(v bool)     { s.Focused = v }

func (s *tabStrip) OnClick(x, y int) bool {
	i := s.tabAt(x, y)
	if i < 0 {
		return false
	}
	return s.OnActivate(i)
}

// OnKey steps the active view: Right -> next tab, Left -> previous (both
// wrap). The strip's cells name the panes, so the keys the list uses for
// row vocab mean tab-switch here.
func (s *tabStrip) OnKey(k panelKey) bool {
	cur := s.Active
	if s.Current != nil {
		cur = s.Current()
	}
	switch k.Named() {
	case keyLeft:
		return s.OnActivate((cur + tabCount - 1) % tabCount)
	case keyRight:
		return s.OnActivate((cur + 1) % tabCount)
	}
	return false
}

// Draw paints one cell per view: the active cell on the Selection plate,
// the rest on Surface, labels centered. A focused strip gets the Accent
// underline under the active cell — the same affordance the seat's rail
// carries, kept flat so a RectCanvas-only surface draws identically.
func (s *tabStrip) Draw(c widgets.RectCanvas) {
	if s.R.Empty() {
		return
	}
	th := theme.Current
	c.FillRect(s.R, draw.Opaque(th.Border))
	for i := 0; i < tabCount; i++ {
		cr := s.cellRect(i)
		face := th.Surface
		if i == s.Active {
			face = th.Selection
		}
		c.FillRect(cr.Inset(1), draw.Opaque(face))
		widgets.DrawText(c, cr.Inset(4), tabNames[i], draw.Opaque(th.Text))
		if i == s.Active && s.Focused {
			c.FillRect(widgets.Rect{X: cr.X + 2, Y: cr.Bottom() - 3, W: cr.W - 4, H: 2},
				draw.Opaque(th.Accent))
		}
	}
}
