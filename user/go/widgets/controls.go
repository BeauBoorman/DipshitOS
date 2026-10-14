package widgets

// The M104d (#2271) controls — Scrollbar, Toggle, Slider — the §5.2
// inventory entries whose consumers are pure paint+geometry (the dropdown's
// popover rides FillShadow and the clip stack, so the contract places it in
// appkit where *draw.BufferCanvas is reachable). Each control keeps the
// kit's invariants: Bounds/HitTest read the same rect, the §2.3 ramp
// supplies every state colour, Draw type-asserts to Canvas and degrades to
// the flat v1 form on a RectCanvas-only surface — never a blank control.

import "virelai/theme"

// Intersect returns a ∩ b — the shared clip geometry the degrade paths
// use. Right and bottom stay exclusive, clamped at empty.
func (r Rect) Intersect(b Rect) Rect {
	x := max(r.X, b.X)
	y := max(r.Y, b.Y)
	right := min(r.Right(), b.Right())
	bottom := min(r.Bottom(), b.Bottom())
	if right < x {
		right = x
	}
	if bottom < y {
		bottom = y
	}
	return Rect{X: x, Y: y, W: right - x, H: bottom - y}
}

// --- Scrollbar ---------------------------------------------------------------

// ScrollbarW is the §5.2 track width.
const ScrollbarW = 12

// scrollbarMinThumb is the §5.2 minimum thumb length.
const scrollbarMinThumb = 24

// Scrollbar is the §5.2 scroll chrome — logview's log list is the forcing
// consumer (top's proc list and crashview's receipt list follow). The track
// is a ChromeBg pill and the thumb a radiusPill capsule on the §2.3 Btn
// ramp. Total, Viewport and Offset share one unit — rows, pixels, lines —
// chosen by the caller.
//
// When the content fits the viewport the control is absent, not disabled
// (§5.2): Draw paints nothing and HitTest is false.
type Scrollbar struct {
	R        Rect // the track plate
	Total    int  // content extent
	Viewport int  // visible extent
	Offset   int  // scroll position in [0, Total-Viewport], clamped
	Hovered  bool
	Pressed  bool // the §2.3 dragged state
}

// Present reports whether the control has chrome at all: content must
// overflow the viewport. An absent scrollbar neither draws nor hits.
func (s *Scrollbar) Present() bool { return s.Total > s.Viewport && s.Viewport > 0 }

// Bounds is the track plate.
func (s *Scrollbar) Bounds() Rect { return s.R }

// HitTest agrees with Bounds — and only while the control is present.
func (s *Scrollbar) HitTest(x, y int) bool {
	return s.Present() && s.R.Contains(x, y)
}

// maxOffset is the largest legal Offset.
func (s *Scrollbar) maxOffset() int {
	if m := s.Total - s.Viewport; m > 0 {
		return m
	}
	return 0
}

// ThumbRect is the thumb's rect — the one geometry source Draw and the
// drag path both read. The thumb is inset PadXS inside the track, is at
// least scrollbarMinThumb long, and travels in proportion to Offset.
func (s *Scrollbar) ThumbRect() Rect {
	if !s.Present() {
		return Rect{}
	}
	inner := s.R.Inset(theme.Current.PadXS)
	thumb := inner.H * s.Viewport / s.Total
	if thumb < scrollbarMinThumb {
		thumb = scrollbarMinThumb
	}
	if thumb > inner.H {
		thumb = inner.H
	}
	travel := inner.H - thumb
	off := s.Offset
	if m := s.maxOffset(); off > m {
		off = m
	}
	if off < 0 {
		off = 0
	}
	y := inner.Y
	if travel > 0 {
		y += travel * off / s.maxOffset()
	}
	return Rect{X: inner.X, Y: y, W: inner.W, H: thumb}
}

// OffsetAt is ThumbRect's inverse: the offset whose thumb top sits at y —
// the drag mapping. The result is clamped to [0, maxOffset].
func (s *Scrollbar) OffsetAt(y int) int {
	if !s.Present() {
		return 0
	}
	inner := s.R.Inset(theme.Current.PadXS)
	thumb := inner.H * s.Viewport / s.Total
	if thumb < scrollbarMinThumb {
		thumb = scrollbarMinThumb
	}
	if thumb > inner.H {
		thumb = inner.H
	}
	travel := inner.H - thumb
	if travel <= 0 {
		return 0
	}
	off := ((y-inner.Y)*s.maxOffset() + travel/2) / travel
	if m := s.maxOffset(); off > m {
		off = m
	}
	if off < 0 {
		off = 0
	}
	return off
}

// PageAt reports where a point falls relative to the thumb: -1 above, +1
// below, 0 on the thumb — the track-click paging answer.
func (s *Scrollbar) PageAt(x, y int) int {
	if !s.HitTest(x, y) {
		return 0
	}
	t := s.ThumbRect()
	switch {
	case y < t.Y:
		return -1
	case y >= t.Bottom():
		return 1
	}
	return 0
}

// Draw paints the track and thumb. A full Canvas gets the §2.2 pill forms;
// a RectCanvas-only surface keeps the flat v1 fills.
func (s *Scrollbar) Draw(c RectCanvas) {
	if !s.Present() || s.R.Empty() {
		return
	}
	th := theme.Current
	face := th.BtnIdle
	switch {
	case s.Pressed:
		face = th.BtnPressed
	case s.Hovered:
		face = th.BtnHover
	}
	thumb := s.ThumbRect()
	if fc, ok := c.(Canvas); ok {
		fc.FillRoundedRect(s.R, s.R.W/2, opaque(th.ChromeBg))
		fc.FillRoundedRect(thumb, thumb.W/2, opaque(face))
		return
	}
	c.FillRect(s.R, th.ChromeBg)
	c.FillRect(thumb, face)
}

// --- Toggle ------------------------------------------------------------------

// ToggleW and ToggleH are the §5.2 plate size.
const (
	ToggleW = 32
	ToggleH = 18
)

// Toggle is the §5.2 on/off control — goset's on/off vocab rows (shadow,
// focus_follows_mouse, notify_dnd, notify_sound, init) are the forcing
// consumers. The track is a radiusPill capsule: the §2.3 ramp when off,
// the Accent "selected" vocabulary when on — hover and press blend the
// accent toward the ramp roles so feedback survives the combination. The
// contract's checkbox is a geometry variant of this state machine, spec'd
// but unscheduled until a form-style consumer exists.
type Toggle struct {
	R        Rect // the 32×18 plate
	On       bool
	Hovered  bool
	Pressed  bool
	Focused  bool
	Disabled bool
}

// Bounds is the track plate.
func (t *Toggle) Bounds() Rect { return t.R }

// HitTest agrees with Bounds by construction.
func (t *Toggle) HitTest(x, y int) bool { return t.R.Contains(x, y) }

// KnobRect is the knob's rect — parked left when off, right when on; the
// one geometry source Draw and a future drag path both read.
func (t *Toggle) KnobRect() Rect {
	side := t.R.H - 2*theme.Current.PadXS
	if side < 0 {
		side = 0
	}
	x := t.R.X + theme.Current.PadXS
	if t.On {
		x = t.R.Right() - theme.Current.PadXS - side
	}
	return Rect{X: x, Y: t.R.Y + theme.Current.PadXS, W: side, H: side}
}

// colors resolves the track and knob faces from the §2.3 ramp. On is the
// selected vocabulary: the accent track stays accent under hover/press,
// tinted toward the ramp roles so feedback is still visible.
func (t *Toggle) colors() (track, knob uint32) {
	th := theme.Current
	switch {
	case t.On && t.Disabled:
		track = blendHalf(th.Accent, th.Surface)
	case t.On && t.Pressed:
		track = blendHalf(th.Accent, th.BtnPressed)
	case t.On && t.Hovered:
		track = blendHalf(th.Accent, th.BtnHover)
	case t.On:
		track = th.Accent
	case t.Disabled:
		track = blendHalf(th.BtnIdle, th.Surface)
	case t.Pressed:
		track = th.BtnPressed
	case t.Hovered:
		track = th.BtnHover
	default:
		track = th.BtnIdle
	}
	knob = th.OnAccent
	if t.Disabled {
		knob = th.Muted
	}
	return track, knob
}

// Draw paints the track and the knob. A full Canvas gets the radiusPill
// forms and the inside FocusW ring — in OnAccent when the track itself is
// pure accent, so focus stays visible (ADR 0008 D4); a RectCanvas-only
// surface keeps the flat v1 form.
func (t *Toggle) Draw(c RectCanvas) {
	if t.R.Empty() {
		return
	}
	th := theme.Current
	track, knob := t.colors()
	kr := t.KnobRect()
	if fc, ok := c.(Canvas); ok {
		fc.FillRoundedRect(t.R, t.R.H/2, opaque(track))
		if t.Focused && !t.Disabled {
			ring := th.Accent
			if t.On && !t.Hovered && !t.Pressed {
				ring = th.OnAccent
			}
			fc.StrokeRoundedRect(t.R, t.R.H/2, th.FocusW, opaque(ring))
		}
		fc.FillRoundedRect(kr, kr.W/2, opaque(knob))
		return
	}
	c.FillRect(t.R, track)
	c.FillRect(kr, knob)
	if t.Focused && !t.Disabled {
		fw := th.FocusW
		if fw < 1 {
			fw = 1
		}
		ring := th.Accent
		if t.On && !t.Hovered && !t.Pressed {
			ring = th.OnAccent
		}
		c.FillRect(Rect{X: t.R.X, Y: t.R.Y, W: t.R.W, H: fw}, ring)
		c.FillRect(Rect{X: t.R.X, Y: t.R.Bottom() - fw, W: t.R.W, H: fw}, ring)
		c.FillRect(Rect{X: t.R.X, Y: t.R.Y, W: fw, H: t.R.H}, ring)
		c.FillRect(Rect{X: t.R.Right() - fw, Y: t.R.Y, W: fw, H: t.R.H}, ring)
	}
}

// --- Slider ------------------------------------------------------------------

// SliderKnobD and SliderTrackH are the §5.2 anatomy: a 14px knob over a
// 4px track band.
const (
	SliderKnobD  = 14
	SliderTrackH = 4
)

// Slider is the §2.3/§5.2 value control — sound's position/volume readout
// is the forcing consumer (secondary: goset's audio_volume 0–100 step-10
// row). The track is a 4px ChromeBg band with an Accent fill to the
// value; the knob is a 14px circle riding the §2.3 ramp — pressed is the
// dragged state.
type Slider struct {
	R        Rect // the control plate; the track band is centred in it
	Min      int
	Max      int // <= Min degenerates to a pinned knob
	Value    int
	Hovered  bool
	Pressed  bool // the §2.3 dragged state
	Focused  bool
	Disabled bool
}

// Bounds is the control plate.
func (s *Slider) Bounds() Rect { return s.R }

// HitTest agrees with Bounds by construction.
func (s *Slider) HitTest(x, y int) bool { return s.R.Contains(x, y) }

// clampValue is Value bounded to [Min, Max].
func (s *Slider) clampValue() int {
	v := s.Value
	if v < s.Min {
		v = s.Min
	}
	if v > s.Max {
		v = s.Max
	}
	return v
}

// span is the knob-centre travel interval [x0, x1]: the knob's 14px circle
// stays inside the plate at both ends.
func (s *Slider) span() (x0, x1 int) {
	return s.R.X + SliderKnobD/2, s.R.Right() - SliderKnobD/2
}

// TrackRect is the 4px band, centred vertically and spanning the knob's
// travel — the one geometry source Draw reads.
func (s *Slider) TrackRect() Rect {
	x0, x1 := s.span()
	y := s.R.Y + (s.R.H-SliderTrackH)/2
	return Rect{X: x0, Y: y, W: x1 - x0, H: SliderTrackH}
}

// KnobCenter is the knob's x for the current value — Max <= Min pins it at
// the span start.
func (s *Slider) KnobCenter() int {
	x0, x1 := s.span()
	if s.Max <= s.Min || x1 <= x0 {
		return x0
	}
	return x0 + (s.clampValue()-s.Min)*(x1-x0)/(s.Max-s.Min)
}

// KnobRect is the 14px knob, centred vertically on the track.
func (s *Slider) KnobRect() Rect {
	return Rect{
		X: s.KnobCenter() - SliderKnobD/2,
		Y: s.R.Y + (s.R.H-SliderKnobD)/2,
		W: SliderKnobD, H: SliderKnobD,
	}
}

// ValueAt is KnobCenter's inverse — the drag mapping, clamped to the
// [Min, Max] range.
func (s *Slider) ValueAt(x int) int {
	x0, x1 := s.span()
	if s.Max <= s.Min || x1 <= x0 {
		return s.Min
	}
	v := s.Min + ((x-x0)*(s.Max-s.Min)+(x1-x0)/2)/(x1-x0)
	if v < s.Min {
		v = s.Min
	}
	if v > s.Max {
		v = s.Max
	}
	return v
}

// Draw paints the track, the accent fill to the value, and the knob. A
// full Canvas gets the §2.2 pill band, the circular knob with a 1px border
// and the inside FocusW ring; a RectCanvas-only surface keeps the flat v1
// fills.
func (s *Slider) Draw(c RectCanvas) {
	if s.R.Empty() {
		return
	}
	th := theme.Current
	track := s.TrackRect()
	fill := th.Accent
	knob := th.BtnIdle
	switch {
	case s.Disabled:
		fill = blendHalf(th.Accent, th.Surface)
		knob = blendHalf(th.BtnIdle, th.Surface)
	case s.Pressed:
		knob = th.BtnPressed
	case s.Hovered:
		knob = th.BtnHover
	}
	fr := track
	fr.W = s.KnobCenter() - track.X
	if fr.W < 0 {
		fr.W = 0
	}
	kr := s.KnobRect()
	if fc, ok := c.(Canvas); ok {
		fc.FillRoundedRect(track, SliderTrackH/2, opaque(th.ChromeBg))
		fc.FillRoundedRect(fr, SliderTrackH/2, opaque(fill))
		fc.FillRoundedRect(kr, SliderKnobD/2, opaque(knob))
		fc.StrokeRoundedRect(kr, SliderKnobD/2, th.BorderW, opaque(th.Border))
		if s.Focused && !s.Disabled {
			fc.StrokeRoundedRect(s.R, radiusControl, th.FocusW, opaque(th.Accent))
		}
		return
	}
	c.FillRect(track, th.ChromeBg)
	c.FillRect(fr, fill)
	c.FillRect(kr, knob)
	if s.Focused && !s.Disabled {
		fw := th.FocusW
		if fw < 1 {
			fw = 1
		}
		c.FillRect(Rect{X: s.R.X, Y: s.R.Y, W: s.R.W, H: fw}, th.Accent)
		c.FillRect(Rect{X: s.R.X, Y: s.R.Bottom() - fw, W: s.R.W, H: fw}, th.Accent)
		c.FillRect(Rect{X: s.R.X, Y: s.R.Y, W: fw, H: s.R.H}, th.Accent)
		c.FillRect(Rect{X: s.R.Right() - fw, Y: s.R.Y, W: fw, H: s.R.H}, th.Accent)
	}
}
