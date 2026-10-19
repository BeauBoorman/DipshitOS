package widgets

import (
	"strings"
	"testing"

	"virelai/theme"
)

func TestEmptyStateHitTestAgreement(t *testing.T) {
	e := &EmptyState{R: Rect{4, 4, 120, 80}, Icon: "?", Headline: "empty"}
	gridAgreement(t, e, 0, 0, 128, 88)
}

// The flat path (the browser's fill-only surface, the kit's RectCanvas
// degrade) paints plate, the four border bands, then the centred glyph
// runs — in theme tokens, Surface plate over Border ring.
func TestEmptyStateFlatStream(t *testing.T) {
	th := theme.Current
	r := Rect{X: 8, Y: 8, W: 120, H: 80}
	e := &EmptyState{R: r, Icon: "?", Headline: "nothing", Hints: []string{"esc clears"}}
	c := &recordingCanvas{}
	e.Draw(c)
	if len(c.fills) < 5 {
		t.Fatalf("flat stream has %d fills, want plate + 4 borders + text", len(c.fills))
	}
	if c.fills[0].r != r || c.fills[0].rgb != th.Surface {
		t.Fatalf("plate = %+v, want surface fill of %+v", c.fills[0], r)
	}
	// The four border bands follow the plate, Border-coloured, at the
	// rect's own edges.
	bw := th.BorderW
	want := []Rect{
		{X: r.X, Y: r.Y, W: r.W, H: bw},
		{X: r.X, Y: r.Bottom() - bw, W: r.W, H: bw},
		{X: r.X, Y: r.Y + bw, W: bw, H: r.H - 2*bw},
		{X: r.Right() - bw, Y: r.Y + bw, W: bw, H: r.H - 2*bw},
	}
	for i, w := range want {
		if c.fills[1+i].r != w || c.fills[1+i].rgb != th.Border {
			t.Fatalf("border[%d] = %+v #%06x, want %+v border", i, c.fills[1+i].r, c.fills[1+i].rgb, w)
		}
	}
	// Every glyph fill stays inside the plate and carries a text ink.
	for _, f := range c.fills[5:] {
		if f.rgb != th.Text && f.rgb != th.Muted {
			t.Fatalf("glyph fill colour %#x — not a text token", f.rgb)
		}
		if !r.Contains(f.r.X, f.r.Y) || !r.Contains(f.r.Right()-1, f.r.Bottom()-1) {
			t.Fatalf("glyph fill %+v escapes the plate %+v", f.r, r)
		}
	}
}

// Lines is the VT form: h rows of w cells, content centred in both axes,
// a blank spacer between headline and hints.
func TestEmptyStateLines(t *testing.T) {
	e := EmptyState{Icon: "?", Headline: "empty", Hints: []string{"a b", "c d"}}
	rows := e.Lines(20, 9)
	if len(rows) != 9 {
		t.Fatalf("Lines h = %d want 9", len(rows))
	}
	for i, s := range rows {
		if len([]rune(s)) != 20 {
			t.Fatalf("row %d width %d want 20", i, len([]rune(s)))
		}
	}
	// Stack is icon, headline, spacer, hint, hint = 5 rows centred in 9:
	// rows 2..6.
	want := []string{"", "", "?", "empty", "", "a b", "c d", "", ""}
	for i, w := range want {
		if strings.TrimSpace(rows[i]) != w {
			t.Fatalf("row %d = %q want content %q", i, strings.TrimSpace(rows[i]), w)
		}
	}
}

// A hint longer than the grid clips, never overflows the cell width.
func TestEmptyStateLinesClip(t *testing.T) {
	e := EmptyState{Headline: "this headline is far too wide"}
	rows := e.Lines(8, 4)
	for i, s := range rows {
		if len([]rune(s)) != 8 {
			t.Fatalf("row %d width %d want 8", i, len([]rune(s)))
		}
	}
	if rows[1] != "this hea" {
		t.Fatalf("clipped headline = %q", rows[1])
	}
}

func TestEmptyStateDegenerateRects(t *testing.T) {
	c := &recordingCanvas{}
	(&EmptyState{Headline: "x"}).Draw(c) // zero rect
	(&EmptyState{R: Rect{W: 4}}).Draw(c) // no height
	if len(c.fills) != 0 {
		t.Fatalf("degenerate rects painted %d fills", len(c.fills))
	}
	if (EmptyState{}).Lines(0, 4) != nil || (EmptyState{}).Lines(4, 0) != nil {
		t.Fatal("Lines on a degenerate grid must be nil")
	}
}
