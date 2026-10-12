package widgets

import (
	"testing"

	"virelai/theme"
)

// recordingCanvas captures every fill so a test can prove Draw read the same
// rects HitTest uses.
type recordingCanvas struct {
	fills []struct {
		r   Rect
		rgb uint32
	}
}

func (c *recordingCanvas) FillRect(r Rect, rgb uint32) {
	c.fills = append(c.fills, struct {
		r   Rect
		rgb uint32
	}{r, rgb})
}

func (c *recordingCanvas) FillRoundedRect(r Rect, _ int, rgb uint32) {
	c.FillRect(r, rgb)
}

func (c *recordingCanvas) StrokeRoundedRect(r Rect, _, _ int, rgb uint32) {
	c.FillRect(r, rgb)
}

func (c *recordingCanvas) BlitTinted(_ []uint32, _, _, _, _ int, _ uint32) {}

// gridAgreement asserts HitTest(x,y) == Bounds().Contains(x,y) over a grid
// that brackets the widget, for every widget kind.
func gridAgreement(t *testing.T, w Widget, loX, loY, hiX, hiY int) {
	t.Helper()
	b := w.Bounds()
	for y := loY; y <= hiY; y++ {
		for x := loX; x <= hiX; x++ {
			if got, want := w.HitTest(x, y), b.Contains(x, y); got != want {
				t.Fatalf("HitTest(%d,%d)=%v want %v (bounds %+v)", x, y, got, want, b)
			}
		}
	}
}

func TestThreeWidgetsSatisfyInterface(t *testing.T) {
	var ws []Widget = []Widget{
		&Text{R: Rect{4, 4, 60, 16}, Label: "hi"},
		&Button{R: Rect{4, 40, 80, 24}, Label: "OK"},
		&List{R: Rect{4, 80, 120, 90}, Items: []string{"a", "b", "c"}, RowH: 30},
	}
	if len(ws) != 3 {
		t.Fatalf("expected exactly three widgets, got %d", len(ws))
	}
}

func TestTextHitTestAgreement(t *testing.T) {
	w := &Text{R: Rect{10, 10, 40, 12}, Label: "hi", Fg: 0xffffff, Bg: 0x101010}
	gridAgreement(t, w, 5, 5, 55, 30)
}

func TestButtonHitTestAgreement(t *testing.T) {
	w := &Button{R: Rect{20, 30, 60, 20}, Label: "OK", Face: 0x222222, Border: 0x888888}
	gridAgreement(t, w, 15, 25, 85, 55)
	// The border row is grabbable (HitTest is the OUTER rect).
	if !w.HitTest(20, 30) || !w.HitTest(79, 49) {
		t.Fatal("button corners should hit")
	}
	if w.HitTest(80, 30) {
		t.Fatal("right edge is exclusive")
	}
}

func TestButtonThemeStates(t *testing.T) {
	w := &Button{R: Rect{0, 0, 40, 16}, Label: "OK"}
	idleF, idleB, _ := w.colors()
	if idleF != theme.Current.BtnIdle || idleB != theme.Current.Border {
		t.Fatalf("idle face/border %#x/%#x", idleF, idleB)
	}
	w.Hovered = true
	_, hoverB, _ := w.colors()
	if hoverB != theme.Current.Accent {
		t.Fatalf("hover border %#x want accent", hoverB)
	}
	w.Pressed = true
	pressF, pressB, _ := w.colors()
	if pressF != theme.Current.BtnPressed || pressB != theme.Current.Accent {
		t.Fatalf("press %#x/%#x", pressF, pressB)
	}
	c := &recordingCanvas{}
	w.Draw(c)
	if len(c.fills) == 0 || c.fills[0].rgb != theme.Current.Accent {
		t.Fatalf("press draw border fill = %+v", c.fills)
	}
}

func TestButtonIdleOverrideKeepsHex(t *testing.T) {
	w := &Button{R: Rect{0, 0, 20, 10}, Face: 0x222222, Border: 0x888888, LabelRGB: 0xffffff}
	face, border, label := w.colors()
	if face != 0x222222 || border != 0x888888 || label != 0xffffff {
		t.Fatalf("idle override lost: %#x %#x %#x", face, border, label)
	}
}

func TestListHitTestAgreement(t *testing.T) {
	w := &List{R: Rect{0, 0, 100, 90}, Items: []string{"a", "b", "c"}, RowH: 30}
	gridAgreement(t, w, -2, -2, 102, 92)
}

// A point inside RowRect(i) must map to row i, and Draw must use the same
// rects — the CALC-drift guarantee.
func TestListRowRectMatchesItemAt(t *testing.T) {
	l := &List{R: Rect{5, 5, 100, 90}, Items: []string{"a", "b", "c"}, RowH: 30, Fg: 0xffffff, Bg: 0, SelBg: 0x333333}
	for i := range l.Items {
		rr := l.RowRect(i)
		// sample a point inside each row
		x, y := rr.X+1, rr.Y+1
		if got := l.ItemAt(x, y); got != i {
			t.Fatalf("ItemAt(%d,%d)=%d want %d (row rect %+v)", x, y, got, i, rr)
		}
		// the bottom-right interior point too
		x, y = rr.Right()-1, rr.Bottom()-1
		if got := l.ItemAt(x, y); got != i {
			t.Fatalf("ItemAt(%d,%d)=%d want %d", x, y, got, i)
		}
	}
	// Outside the list, and below the item count, is -1.
	if l.ItemAt(-1, 5) != -1 || l.ItemAt(5, 5+l.RowH*len(l.Items)) != -1 {
		t.Fatal("out-of-range points must be -1")
	}
}

// Draw must paint at least one fill whose rect is inside Bounds, and the
// selection row must be drawn using RowRect(Sel).
func TestListDrawUsesRowRects(t *testing.T) {
	l := &List{R: Rect{0, 0, 60, 60}, Items: []string{"a", "b"}, RowH: 30, Sel: 1, Bg: 0x000000, SelBg: 0xababab}
	c := &recordingCanvas{}
	l.Draw(c)
	if len(c.fills) == 0 {
		t.Fatal("list drew nothing")
	}
	selRect := l.RowRect(1)
	found := false
	for _, f := range c.fills {
		if f.r == selRect && f.rgb == l.SelBg {
			found = true
		}
	}
	if !found {
		t.Fatalf("selection row rect not drawn: want %+v", selRect)
	}
}

func TestVisibleRows(t *testing.T) {
	l := &List{R: Rect{0, 0, 10, 90}, RowH: 30}
	if got := l.VisibleRows(); got != 3 {
		t.Fatalf("VisibleRows = %d want 3", got)
	}
}

// Scale is the identity at the native canvas — the zero-regression fixed
// point — and maps proportionally otherwise.
func TestScaleIdentityAndMapping(t *testing.T) {
	r := Rect{8, 104, 56, 20}
	if got := Scale(r, 512, 340, 512, 340); got != r {
		t.Fatalf("identity scale changed %+v -> %+v", r, got)
	}
	got := Scale(r, 512, 340, 1024, 680)
	if got != (Rect{16, 208, 112, 40}) {
		t.Fatalf("scaled = %+v", got)
	}
	// Content never spills the target canvas.
	if got.X+got.W > 1024 || got.Y+got.H > 680 {
		t.Fatalf("scaled rect spills: %+v", got)
	}
	// A zero source is a no-op (guarded).
	if got := Scale(r, 0, 0, 100, 100); got != r {
		t.Fatalf("zero source should be a no-op: %+v", got)
	}
}

func TestLayoutHelpers(t *testing.T) {
	row := Row(0, 0, 10, 4, 2, 3)
	if len(row) != 3 || row[0] != (Rect{0, 0, 10, 4}) || row[2] != (Rect{24, 0, 10, 4}) {
		t.Fatalf("Row = %+v", row)
	}
	col := Column(0, 0, 10, 4, 2, 3)
	if len(col) != 3 || col[1] != (Rect{0, 6, 10, 4}) {
		t.Fatalf("Column = %+v", col)
	}
	if Row(0, 0, 1, 1, 0, 0) != nil {
		t.Fatal("zero-count Row should be nil")
	}
}

// 'H' is two stems and a crossbar (font8x8 0x33 / 0x3f). A solid cell per
// rune — the old placeholder — paints one tall rectangle and has no gap, so
// this fails if text goes back to being a horizontal bar.
func TestGlyphRunPaintsLettersNotBars(t *testing.T) {
	w := &Text{R: Rect{0, 0, 80, 24}, Label: "H", Fg: 0xffffff, Bg: 0x101010}
	c := &recordingCanvas{}
	w.Draw(c)
	var glyph []Rect
	for _, f := range c.fills {
		if f.rgb != w.Fg {
			continue
		}
		if f.r.H != 1 {
			t.Fatalf("glyph fill is %dpx tall: a bar, not a scanline %+v", f.r.H, f.r)
		}
		glyph = append(glyph, f.r)
	}
	if len(glyph) == 0 {
		t.Fatal("'H' painted no ink")
	}
	// First ink row of 'H' is 0x33: two stems, a gap between them.
	y0 := glyph[0].Y
	var runs int
	var prevRight int
	for _, r := range glyph {
		if r.Y != y0 {
			break
		}
		if runs > 0 && r.X < prevRight {
			t.Fatalf("row fills overlap: %+v", glyph)
		}
		runs++
		prevRight = r.X + r.W
	}
	if runs != 2 {
		t.Fatalf("'H' top row has %d run(s), want the two stems", runs)
	}
}

// --- TextInput (issue #2197) -------------------------------------------------

// An unfocused field eats nothing — the app owns focus.
func TestTextInputIgnoresKeysUntilFocused(t *testing.T) {
	in := &TextInput{R: Rect{0, 0, 80, 20}}
	if in.HandleKey(0, 'a') || in.HandleKey(keyLeft, 0) || in.HandleKey(keyBackspace, 0) {
		t.Fatal("an unfocused field must ignore every key")
	}
	in.Focused = true
	if !in.HandleKey(0, 'a') {
		t.Fatal("a focused field must accept printable input")
	}
	if in.Value() != "a" || in.Caret() != 1 {
		t.Fatalf("value=%q caret=%d, want a/1", in.Value(), in.Caret())
	}
}

// Insert lands at the caret, not the end — the state machine's core move.
func TestTextInputInsertsAtCaret(t *testing.T) {
	in := &TextInput{Focused: true}
	in.HandleKey(0, 'a')
	in.HandleKey(0, 'c')
	in.HandleKey(keyLeft, 0)
	if !in.HandleKey(0, 'b') {
		t.Fatal("insert at caret refused")
	}
	if in.Value() != "abc" || in.Caret() != 2 {
		t.Fatalf("value=%q caret=%d, want abc/2", in.Value(), in.Caret())
	}
}

// Backspace removes before the caret, Delete removes under it, and both clamp
// at the ends without lying about a change.
func TestTextInputBackspaceAndDelete(t *testing.T) {
	in := &TextInput{Focused: true}
	in.SetValue("abc")
	in.HandleKey(keyLeft, 0) // caret 2
	if !in.HandleKey(keyBackspace, 0) {
		t.Fatal("backspace refused")
	}
	if in.Value() != "ac" || in.Caret() != 1 {
		t.Fatalf("after backspace value=%q caret=%d", in.Value(), in.Caret())
	}
	in.HandleKey(keyHome, 0)
	if !in.HandleKey(keyDelete, 0) {
		t.Fatal("forward delete refused")
	}
	if in.Value() != "c" || in.Caret() != 0 {
		t.Fatalf("after delete value=%q caret=%d", in.Value(), in.Caret())
	}
	if in.HandleKey(keyBackspace, 0) {
		t.Fatal("backspace at offset 0 must report no change")
	}
	if in.HandleKey(keyEnd, 0) && in.Value() != "c" {
		t.Fatal("end must not edit")
	}
	if in.HandleKey(keyDelete, 0) {
		t.Fatal("delete at end of buffer must report no change")
	}
	// The 0x08 character fallback behaves like the backspace usage.
	in.HandleKey(0, 'x')
	if !in.HandleKey(0, 0x08) {
		t.Fatal("0x08 must backspace")
	}
	if in.Value() != "c" {
		t.Fatalf("value=%q after char backspace, want c", in.Value())
	}
}

// Navigation clamps at both ends and reports no-change honestly.
func TestTextInputNavigationClamps(t *testing.T) {
	in := &TextInput{Focused: true}
	in.SetValue("ab")
	if !in.HandleKey(keyHome, 0) || in.Caret() != 0 {
		t.Fatal("home must move to 0")
	}
	if in.HandleKey(keyLeft, 0) || in.HandleKey(keyHome, 0) {
		t.Fatal("left/home at 0 must report no change")
	}
	if !in.HandleKey(keyEnd, 0) || in.Caret() != 2 {
		t.Fatal("end must move past the last byte")
	}
	if in.HandleKey(keyRight, 0) || in.HandleKey(keyEnd, 0) {
		t.Fatal("right/end at len must report no change")
	}
}

// The buffer is bounded: inserts past Max are refused, and SetValue clamps.
func TestTextInputBoundsBuffer(t *testing.T) {
	in := &TextInput{Focused: true, Max: 3}
	in.HandleKey(0, 'a')
	in.HandleKey(0, 'b')
	in.HandleKey(0, 'c')
	if in.HandleKey(0, 'd') {
		t.Fatal("a full buffer must refuse the insert")
	}
	if in.Value() != "abc" {
		t.Fatalf("value=%q, want abc", in.Value())
	}
	in.SetValue("012345")
	if in.Value() != "012" || in.Caret() != 3 {
		t.Fatalf("SetValue clamp = %q caret=%d", in.Value(), in.Caret())
	}
}

// Printable ASCII only: control codes and high bytes are not text.
func TestTextInputPrintableASCIIOnly(t *testing.T) {
	in := &TextInput{Focused: true}
	for _, ch := range []byte{0x00, 0x01, 0x1f, '\t', 0x7f, 0x80, 0xff} {
		if in.HandleKey(0, ch) {
			t.Fatalf("byte %#x must be rejected", ch)
		}
	}
	if in.Value() != "" {
		t.Fatalf("non-printables leaked into the buffer: %q", in.Value())
	}
	if !in.HandleKey(0, ' ') || !in.HandleKey(0, '~') {
		t.Fatal("space and tilde are printable and must insert")
	}
	if in.Value() != " ~" {
		t.Fatalf("value=%q, want \" ~\"", in.Value())
	}
}

// Enter fires OnSubmit with the text; Escape fires OnCancel. Both usages and
// both byte encodings work, and a nil callback makes the key inert.
func TestTextInputSubmitAndCancel(t *testing.T) {
	var got string
	submitted, cancelled := false, false
	in := &TextInput{Focused: true}
	in.SetValue("needle")
	in.OnSubmit = func(s string) { submitted, got = true, s }
	in.OnCancel = func() { cancelled = true }
	if !in.HandleKey(keyEnter, 0) || !submitted || got != "needle" {
		t.Fatalf("submit=%v got=%q", submitted, got)
	}
	if !in.HandleKey(keyEscape, 0) || !cancelled {
		t.Fatal("escape must fire OnCancel")
	}
	// '\n' and 0x1b encodings fire the same callbacks.
	submitted, cancelled = false, false
	in.HandleKey(0, '\n')
	in.HandleKey(0, 0x1b)
	if !submitted || !cancelled {
		t.Fatal("byte encodings of Enter/Escape must fire the callbacks")
	}
	// Nil callbacks: the key is inert, not a fake state change.
	bare := &TextInput{Focused: true}
	if bare.HandleKey(keyEnter, 0) || bare.HandleKey(keyEscape, 0) {
		t.Fatal("Enter/Escape with no callback must report no change")
	}
}

func TestTextInputHitTestAgreement(t *testing.T) {
	in := &TextInput{R: Rect{10, 10, 80, 20}}
	gridAgreement(t, in, 5, 5, 95, 35)
}

// Draw paints the plate and, when focused, a caret bar inside it at the
// caret's glyph cell — the same inset drawGlyphRun uses.
func TestTextInputDrawPaintsPlateAndCaret(t *testing.T) {
	in := &TextInput{R: Rect{0, 0, 80, 20}, Focused: true}
	in.SetValue("ab")
	c := &recordingCanvas{}
	in.Draw(c)
	if len(c.fills) == 0 || c.fills[0].r != in.R {
		t.Fatalf("first fill must be the border plate %+v", c.fills)
	}
	var caret *Rect
	for i := range c.fills {
		if c.fills[i].rgb == theme.Current.Caret {
			rr := c.fills[i].r
			caret = &rr
		}
	}
	if caret == nil {
		t.Fatal("a focused field must paint a caret")
	}
	// caret = inner.X + 2 + 2 glyphs * 8px; inner is the plate inset BorderW.
	wantX := in.R.X + theme.Current.BorderW + 2 + 2*8
	if caret.X != wantX || caret.W != 2 {
		t.Fatalf("caret rect = %+v, want x=%d w=2", caret, wantX)
	}
	// Unfocused: no caret ink.
	in.Focused = false
	c = &recordingCanvas{}
	in.Draw(c)
	for _, f := range c.fills {
		if f.rgb == theme.Current.Caret {
			t.Fatal("an unfocused field must not paint a caret")
		}
	}
}

func TestRectHelpers(t *testing.T) {
	r := Rect{10, 10, 20, 20}
	if !r.Contains(10, 10) || r.Contains(30, 10) || r.Contains(10, 30) {
		t.Fatal("Contains edges wrong")
	}
	if r.Right() != 30 || r.Bottom() != 30 {
		t.Fatal("edges wrong")
	}
	if got := r.Inset(2); got != (Rect{12, 12, 16, 16}) {
		t.Fatalf("Inset = %+v", got)
	}
	if !(Rect{}).Empty() {
		t.Fatal("zero rect should be empty")
	}
}
