package widgets

import (
	"testing"

	"virelai/theme"
)

// --- Scrollbar (logview's consumer, §5.2) ---------------------------------

// An absent scrollbar — content fits the viewport — neither draws nor
// hits: the contract's "absent, not disabled" rule.
func TestScrollbarAbsentWhenContentFits(t *testing.T) {
	for _, sb := range []*Scrollbar{
		{R: Rect{0, 0, ScrollbarW, 100}, Total: 4, Viewport: 4},
		{R: Rect{0, 0, ScrollbarW, 100}, Total: 3, Viewport: 4},
		{R: Rect{0, 0, ScrollbarW, 100}, Total: 10, Viewport: 0},
	} {
		if sb.Present() {
			t.Fatalf("Present() on fitting content %+v", sb)
		}
		if sb.HitTest(6, 50) {
			t.Fatal("absent scrollbar must not hit")
		}
		c := &recordingCanvas{}
		sb.Draw(c)
		if len(c.fills) != 0 {
			t.Fatalf("absent scrollbar painted %d fills", len(c.fills))
		}
	}
}

func TestScrollbarHitTestAgreement(t *testing.T) {
	sb := &Scrollbar{R: Rect{10, 10, ScrollbarW, 100}, Total: 20, Viewport: 5}
	gridAgreement(t, sb, 5, 5, 25, 115)
}

// ThumbRect is proportional, never below the 24px minimum, and travels
// with the offset — the geometry Draw and drags share.
func TestScrollbarThumbGeometry(t *testing.T) {
	sb := &Scrollbar{R: Rect{0, 0, ScrollbarW, 104}, Total: 40, Viewport: 10}
	th := theme.Current
	inner := sb.R.Inset(th.PadXS)
	thumb := sb.ThumbRect()
	// 104 - 4 = 100 usable, 10/40 → 25px thumb.
	if thumb.X != inner.X || thumb.W != inner.W {
		t.Fatalf("thumb x/w = %+v, want inner %+v", thumb, inner)
	}
	if thumb.H != 25 || thumb.Y != inner.Y {
		t.Fatalf("thumb = %+v, want h=25 at y=%d", thumb, inner.Y)
	}
	// Min thumb: tiny viewport share still yields 24px.
	sb.Viewport = 2
	if got := sb.ThumbRect().H; got != scrollbarMinThumb {
		t.Fatalf("min thumb = %d, want %d", got, scrollbarMinThumb)
	}
	// Full travel at the bottom.
	sb.Viewport, sb.Offset = 10, 30
	if got := sb.ThumbRect().Bottom(); got != inner.Bottom() {
		t.Fatalf("bottom thumb ends %d, want %d", got, inner.Bottom())
	}
	// Offsets clamp rather than escape.
	sb.Offset = 999
	if got := sb.ThumbRect().Bottom(); got != inner.Bottom() {
		t.Fatalf("clamped thumb ends %d, want %d", got, inner.Bottom())
	}
	sb.Offset = -5
	if got := sb.ThumbRect().Y; got != inner.Y {
		t.Fatalf("negative thumb starts %d, want %d", got, inner.Y)
	}
}

// OffsetAt inverts ThumbRect, and PageAt paged above/on/below the thumb.
func TestScrollbarOffsetAndPaging(t *testing.T) {
	sb := &Scrollbar{R: Rect{0, 0, ScrollbarW, 104}, Total: 40, Viewport: 10, Offset: 15}
	if got := sb.OffsetAt(sb.ThumbRect().Y); got != 15 {
		t.Fatalf("OffsetAt(thumb top) = %d, want 15", got)
	}
	if got := sb.OffsetAt(-100); got != 0 {
		t.Fatalf("OffsetAt above = %d, want 0", got)
	}
	if got := sb.OffsetAt(1000); got != 30 {
		t.Fatalf("OffsetAt bottom = %d, want 30", got)
	}
	if got := sb.PageAt(6, sb.ThumbRect().Y-1); got != -1 {
		t.Fatalf("PageAt above = %d, want -1", got)
	}
	if got := sb.PageAt(6, sb.ThumbRect().Y+1); got != 0 {
		t.Fatalf("PageAt on thumb = %d, want 0", got)
	}
	if got := sb.PageAt(6, sb.ThumbRect().Bottom()+1); got != 1 {
		t.Fatalf("PageAt below = %d, want 1", got)
	}
	if got := sb.PageAt(-10, 50); got != 0 {
		t.Fatalf("PageAt outside = %d, want 0", got)
	}
}

// Draw paints the track and the ThumbRect on the §2.3 ramp.
func TestScrollbarDrawUsesThumbRect(t *testing.T) {
	sb := &Scrollbar{R: Rect{0, 0, ScrollbarW, 104}, Total: 40, Viewport: 10}
	c := &recordingCanvas{}
	sb.Draw(c)
	if len(c.fills) != 2 || c.fills[0].r != sb.R || c.fills[1].r != sb.ThumbRect() {
		t.Fatalf("fills = %+v, want track %+v then thumb %+v", c.fills, sb.R, sb.ThumbRect())
	}
	if c.fills[1].rgb != theme.Current.BtnIdle {
		t.Fatalf("idle thumb %#x, want BtnIdle", c.fills[1].rgb)
	}
	sb.Hovered = true
	c = &recordingCanvas{}
	sb.Draw(c)
	if c.fills[1].rgb != theme.Current.BtnHover {
		t.Fatalf("hover thumb %#x, want BtnHover", c.fills[1].rgb)
	}
	sb.Pressed = true
	c = &recordingCanvas{}
	sb.Draw(c)
	if c.fills[1].rgb != theme.Current.BtnPressed {
		t.Fatalf("dragged thumb %#x, want BtnPressed", c.fills[1].rgb)
	}
}

// --- Toggle (goset's on/off rows, §5.2) ------------------------------------

func TestToggleHitTestAgreement(t *testing.T) {
	tg := &Toggle{R: Rect{10, 10, ToggleW, ToggleH}}
	gridAgreement(t, tg, 5, 5, 50, 35)
}

// The knob parks left when off and right when on — the state readout is
// geometry, not just colour.
func TestToggleKnobParks(t *testing.T) {
	tg := &Toggle{R: Rect{0, 0, ToggleW, ToggleH}}
	kr := tg.KnobRect()
	if kr.X != theme.Current.PadXS || kr.W != ToggleH-2*theme.Current.PadXS {
		t.Fatalf("off knob = %+v", kr)
	}
	tg.On = true
	kr = tg.KnobRect()
	if kr.Right() != ToggleW-theme.Current.PadXS {
		t.Fatalf("on knob = %+v", kr)
	}
}

// On is the §2.3 selected vocabulary: an Accent track. Hover and press
// tint the accent rather than leaving it, disabled blends toward Surface.
func TestToggleStateRamp(t *testing.T) {
	tg := &Toggle{R: Rect{0, 0, ToggleW, ToggleH}}
	if track, _ := tg.colors(); track != theme.Current.BtnIdle {
		t.Fatalf("idle track %#x", track)
	}
	tg.Hovered = true
	if track, _ := tg.colors(); track != theme.Current.BtnHover {
		t.Fatalf("hover track %#x", track)
	}
	tg.Pressed = true
	if track, _ := tg.colors(); track != theme.Current.BtnPressed {
		t.Fatalf("pressed track %#x", track)
	}
	tg.Hovered, tg.Pressed, tg.On = false, false, true
	if track, _ := tg.colors(); track != theme.Current.Accent {
		t.Fatalf("on track %#x, want Accent", track)
	}
	if _, knob := tg.colors(); knob != theme.Current.OnAccent {
		t.Fatalf("knob %#x, want OnAccent", knob)
	}
	tg.Disabled = true
	if track, _ := tg.colors(); track != blendHalf(theme.Current.Accent, theme.Current.Surface) {
		t.Fatalf("disabled on track %#x", track)
	}
	if _, knob := tg.colors(); knob != theme.Current.Muted {
		t.Fatalf("disabled knob %#x, want Muted", knob)
	}
}

// Draw paints the plate and the KnobRect, and a focused toggle rings its
// bounds — OnAccent when the track is pure accent so the ring stays
// visible (ADR 0008 D4).
func TestToggleDrawPaintsTrackKnobRing(t *testing.T) {
	tg := &Toggle{R: Rect{0, 0, ToggleW, ToggleH}, Focused: true}
	c := &recordingCanvas{}
	tg.Draw(c)
	var ring bool
	for _, f := range c.fills {
		if f.rgb == theme.Current.Accent && (f.r.W == tg.R.W || f.r.H == tg.R.H) {
			ring = true
		}
	}
	if !ring {
		t.Fatalf("focused off-toggle painted no accent ring: %+v", c.fills)
	}
	tg.On = true
	c = &recordingCanvas{}
	tg.Draw(c)
	ring = false
	for _, f := range c.fills {
		if f.rgb == theme.Current.OnAccent && (f.r.W == tg.R.W || f.r.H == tg.R.H) {
			ring = true
		}
	}
	if !ring {
		t.Fatal("focused on-toggle must ring OnAccent — an accent ring on an accent track is invisible")
	}
	// Disabled suppresses the ring.
	tg.Disabled = true
	c = &recordingCanvas{}
	tg.Draw(c)
	for _, f := range c.fills {
		if f.rgb == theme.Current.OnAccent {
			t.Fatal("disabled toggle must not paint the OnAccent ring")
		}
	}
}

// --- Slider (sound's consumer, §5.2) ---------------------------------------

func TestSliderHitTestAgreement(t *testing.T) {
	sl := &Slider{R: Rect{10, 10, 120, 20}, Max: 100, Value: 40}
	gridAgreement(t, sl, 5, 5, 135, 35)
}

// KnobCenter walks the span in proportion to the value and ValueAt
// inverts it — the drag contract Draw and the pointer path share.
func TestSliderValueGeometry(t *testing.T) {
	sl := &Slider{R: Rect{0, 0, 114, 20}, Max: 100}
	x0, x1 := sl.span()
	if x0 != SliderKnobD/2 || x1 != 114-SliderKnobD/2 {
		t.Fatalf("span = %d..%d", x0, x1)
	}
	if got := sl.KnobCenter(); got != x0 {
		t.Fatalf("min knob = %d, want %d", got, x0)
	}
	sl.Value = 100
	if got := sl.KnobCenter(); got != x1 {
		t.Fatalf("max knob = %d, want %d", got, x1)
	}
	sl.Value = 50
	if got := sl.ValueAt(sl.KnobCenter()); got != 50 {
		t.Fatalf("ValueAt(knob) = %d, want 50", got)
	}
	if got := sl.ValueAt(-50); got != 0 {
		t.Fatalf("ValueAt left = %d, want 0", got)
	}
	if got := sl.ValueAt(500); got != 100 {
		t.Fatalf("ValueAt right = %d, want 100", got)
	}
	// A degenerate range pins the knob at the start, never divides by 0.
	flat := &Slider{R: Rect{0, 0, 100, 20}}
	if flat.KnobCenter() != flat.R.X+SliderKnobD/2 || flat.ValueAt(50) != 0 {
		t.Fatal("degenerate range must pin the knob")
	}
}

// The track is the 4px centred band; the fill runs to the knob.
func TestSliderTrackAndFill(t *testing.T) {
	sl := &Slider{R: Rect{0, 0, 114, 20}, Max: 100, Value: 50}
	tr := sl.TrackRect()
	if tr.H != SliderTrackH || tr.Y != 8 || tr.X != SliderKnobD/2 || tr.W != 100 {
		t.Fatalf("track = %+v", tr)
	}
	c := &recordingCanvas{}
	sl.Draw(c)
	// Flat path: track, fill, knob.
	if len(c.fills) != 3 {
		t.Fatalf("flat slider fills = %+v", c.fills)
	}
	if c.fills[0].r != tr || c.fills[0].rgb != theme.Current.ChromeBg {
		t.Fatalf("track fill = %+v", c.fills[0])
	}
	if c.fills[1].rgb != theme.Current.Accent || c.fills[1].r.Right() != sl.KnobCenter() {
		t.Fatalf("accent fill = %+v, want to knob %d", c.fills[1], sl.KnobCenter())
	}
	if c.fills[2].r != sl.KnobRect() {
		t.Fatalf("knob fill = %+v, want %+v", c.fills[2].r, sl.KnobRect())
	}
	// Disabled: the accent fill blends toward Surface, never brighter.
	sl.Disabled = true
	c = &recordingCanvas{}
	sl.Draw(c)
	if c.fills[1].rgb != blendHalf(theme.Current.Accent, theme.Current.Surface) {
		t.Fatalf("disabled fill %#x", c.fills[1].rgb)
	}
}
