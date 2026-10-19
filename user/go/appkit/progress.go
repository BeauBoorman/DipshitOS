package appkit

import (
	"virelai/draw"
	"virelai/theme"
	"virelai/ttf"
	"virelai/vi"
	"virelai/widgets"
)

// Progress is a determinate-or-indeterminate progress bar (M123c, #2577).
// It is a pure widget like the kit's other controls: Set/Advance/Tick
// mutate state, Draw paints through the RectCanvas/Canvas contract, and
// Bounds/HitTest read the same R. No syscall dependency — host tests pin
// the state machine and the fill geometry without a window.
//
// The seat half: Op names the notification-center row this widget reports
// to (vi kind 22). Report() posts the widget's current state; a zero Op
// means a widget-only bar that never reaches the seat. The user's cancel
// comes back on vi.PollProgressCancel — the app polls it once per loop
// pass and routes the returned op to the matching Progress, which is why
// the op is the app's own handle rather than the widget's index.
//
// Face is the §3.4 optional TrueType label face — nil keeps the 8x8
// bitmap face. Disabled drops the fill to the §2.3 50%-toward-Surface
// blend and the label to Muted.
type Progress struct {
	R   widgets.Rect
	Max int // whole-operation total; <1 in NewProgress becomes 100
	Value int
	// Indeterminate paints the sweeping segment for an operation with no
	// measurable total; Phase is the sweep's step — Tick advances it once
	// per repaint cadence (a heartbeat timer or the event loop's tick).
	Indeterminate bool
	Phase         int
	Label         string
	ShowValue     bool // paint the "42%" readout right-aligned in the bar
	Disabled      bool
	Op            uint8 // seat-visible operation id; 0 = widget only
	Face          *ttf.Face
}

// progressBarInset is the track margin inside the plate: the border plus
// one pixel of breathing room, so the fill never sits on the stroke.
const progressBarInset = 2

// progressSweepDenominator divides the track into the sweeping segment's
// width — a quarter of the bar, like the seat's indeterminate row.
const progressSweepDenominator = 4

// NewProgress returns a bar in r for an operation of max units. max < 1
// means "percent-style": the caller then speaks 0..100 directly.
func NewProgress(r widgets.Rect, max int) Progress {
	if max < 1 {
		max = 100
	}
	return Progress{R: r, Max: max}
}

// Bounds is the plate — the ONE rect Draw and HitTest both read.
func (p *Progress) Bounds() widgets.Rect { return p.R }

// HitTest agrees with Bounds by construction.
func (p *Progress) HitTest(x, y int) bool { return p.R.Contains(x, y) }

// Set moves the bar to v, clamped to 0..Max, and reports whether the
// painted fraction changed. A Set on a completed bar is a no-op read.
func (p *Progress) Set(v int) bool {
	if v < 0 {
		v = 0
	}
	if p.Max > 0 && v > p.Max {
		v = p.Max
	}
	if v == p.Value {
		return false
	}
	p.Value = v
	return true
}

// Advance adds d to the value — the common "one more unit done" update.
func (p *Progress) Advance(d int) bool { return p.Set(p.Value + d) }

// Complete reports whether the operation reached its total.
func (p *Progress) Complete() bool { return p.Max > 0 && p.Value >= p.Max }

// Percent is the bar's fill as a whole percent (0..100). The readout and
// the seat report share it, so the row and the widget can never disagree.
func (p *Progress) Percent() int {
	if p.Max <= 0 {
		return 0
	}
	v := p.Value
	if v < 0 {
		v = 0
	}
	if v > p.Max {
		v = p.Max
	}
	return v * 100 / p.Max
}

// Tick advances the indeterminate sweep one step. A determinate bar
// ignores it — the phase drives nothing while a fraction is known.
func (p *Progress) Tick() {
	if p.Indeterminate {
		p.Phase++
	}
}

// inner is the drawable track: the plate minus its border margin.
func (p *Progress) inner() widgets.Rect { return p.R.Inset(progressBarInset) }

// fillRect is the one geometry source Draw and the tests share: the
// determinate fraction of the track, or the indeterminate sweep segment —
// a quarter-track block riding a triangle wave so it slides
// left→right→left, one step per Tick.
func (p *Progress) fillRect() widgets.Rect {
	inner := p.inner()
	if inner.Empty() {
		return widgets.Rect{}
	}
	if p.Indeterminate {
		seg := inner.W / progressSweepDenominator
		if seg < 1 {
			seg = 1
		}
		travel := inner.W - seg
		if travel <= 0 {
			return widgets.Rect{X: inner.X, Y: inner.Y, W: seg, H: inner.H}
		}
		ph := p.Phase % (2 * travel)
		if ph < 0 {
			ph = -ph
		}
		if ph > travel {
			ph = 2*travel - ph
		}
		return widgets.Rect{X: inner.X + ph, Y: inner.Y, W: seg, H: inner.H}
	}
	w := 0
	if p.Max > 0 {
		w = inner.W * p.Value / p.Max
	}
	return widgets.Rect{X: inner.X, Y: inner.Y, W: w, H: inner.H}
}

// valueText is the painted readout: the percent for a determinate bar,
// the ellipsis for one still measuring.
func (p *Progress) valueText() string {
	if p.Indeterminate {
		return "…"
	}
	return vi.Itoa64(int64(p.Percent())) + "%"
}

// textWidth measures a run for alignment — the face's own advance when
// Face is set, the 8px cell count when the bitmap degrade will paint it.
func (p *Progress) textWidth(s string) int {
	if p.Face == nil {
		w := 0
		for range s {
			w += glyphW
		}
		return w
	}
	w := 0
	for _, r := range s {
		w += p.Face.AdvancePx(r, labelPx)
	}
	return w
}

// Draw paints the recessed track, the fill, the optional label and the
// value readout. A full Canvas gets the §2.2 rounded plate and border;
// a RectCanvas-only surface keeps the flat form — the same contract the
// kit's other controls hold (§3.4: a fill-only recorder sees the
// byte-identical FillRect stream).
func (p *Progress) Draw(c widgets.RectCanvas) {
	if p.R.Empty() {
		return
	}
	th := theme.Current
	track := th.ChromeBg
	fill := th.Accent
	fg := th.Text
	if p.Disabled {
		fill = blendHalf(fill, th.Surface)
		fg = th.Muted
	}
	if fc, ok := c.(widgets.Canvas); ok {
		fc.FillRoundedRect(p.R, radiusControl, draw.Opaque(track))
		fc.StrokeRoundedRect(p.R, radiusControl, th.BorderW, draw.Opaque(th.Border))
	} else {
		c.FillRect(p.R, track)
	}
	bar := p.fillRect()
	if !bar.Empty() {
		if fc, ok := c.(widgets.Canvas); ok {
			radius := bar.H / 2
			if radius > radiusControl {
				radius = radiusControl
			}
			fc.FillRoundedRect(bar, radius, draw.Opaque(fill))
		} else {
			c.FillRect(bar, fill)
		}
	}
	inner := p.inner()
	if inner.Empty() {
		return
	}
	// The label rides the track's left edge; the value readout is
	// right-aligned so a growing "42%" never shifts its right edge.
	if p.Label != "" {
		p.text(c, inner, p.Label, fg, false)
	}
	if p.ShowValue {
		p.text(c, inner, p.valueText(), fg, true)
	}
}

// text paints one run inside the track through Canvas.Text (nil face
// degrades to the bitmap face, §3.4) or the bitmap path on a fill-only
// surface. right=true right-aligns the run against the track's edge.
func (p *Progress) text(c widgets.RectCanvas, r widgets.Rect, s string, rgb uint32, right bool) {
	if fc, ok := c.(widgets.Canvas); ok {
		x := r.X + theme.Current.PadXS
		y := 0
		if p.Face != nil {
			asc, desc, _ := p.Face.LineMetrics(labelPx)
			y = r.Y + (r.H-asc-desc)/2 + asc
		}
		if right {
			if w := p.textWidth(s); w < r.W-2*theme.Current.PadXS {
				x = r.Right() - theme.Current.PadXS - w
			}
		}
		fc.Text(p.Face, r, x, y, labelPx, s, draw.Opaque(rgb))
		return
	}
	plate := r
	if right {
		plate.X = r.Right() - p.textWidth(s) - 2
		plate.W = r.Right() - plate.X
	}
	widgets.DrawText(c, plate, s, draw.Opaque(rgb))
}

// The seat-reporting seam: a var so a host test sees the exact wire call
// without a guest mailbox, the same seam shape loop.go keeps for settings.
var notifyProgressReport = vi.NotifyProgress

// Report posts the widget's state to the seat's notification center
// (kind 22): Op is the row's operation id, Percent (or the indeterminate
// mark) its fraction, Label its second line. A widget with Op == 0 is
// display-only and refuses — a report with no operation id has no row to
// land on. Call it after each state change the user should see; the seat
// updates the row in place, so a report per Set is an update, not a new
// row.
func (p *Progress) Report(winID uint32, selfName string) bool {
	if p == nil || p.Op == 0 {
		return false
	}
	pct := p.Percent()
	if p.Indeterminate {
		pct = vi.ProgressIndeterminate
	}
	return notifyProgressReport(winID, p.Op, pct, p.Label, selfName)
}
