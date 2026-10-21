package main

import (
	"testing"

	"virelai/settings"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
)

// minimap_test.go pins the M149c (#2808) surface: the new markers' literal
// shapes (the gate greps them), the column's press->line mapping, the jump's
// caret landing, the frame geometry the pixel probe reads, and the
// settings-bus theme poll.

// TestMarkerShapes149c pins the M149c markers the go-edit gate greps — a
// drift here fails on the host before it can fail live.
func TestMarkerShapes149c(t *testing.T) {
	cases := []struct{ got, want string }{
		{markerThemeSub, "goedit: settings subscribed key=theme"},
		{markerThemeRepaint, "goedit: settings repaint "},
		{markerMiniOn, "goedit: minimap on"},
		{markerMinimap, "goedit: minimap line="},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}

func miniEditor(text string) *editor {
	e := usEditor(text)
	e.minimap = true
	e.ta = &tabapp.TabApp{Win: 1, W: natW, H: natH}
	return e
}

// TestMinimapHitMapsPressToLine: one pixel row per line from chromeH down,
// clamped at the buffer's last line; outside the column or above the
// document band is a refusal.
func TestMinimapHitMapsPressToLine(t *testing.T) {
	e := miniEditor("l1\nl2\nl3\nl4\nl5")
	if line, ok := e.minimapHit(natW-miniW, chromeH); !ok || line != 1 {
		t.Fatalf("column top hit = (%d,%v) want (1,true)", line, ok)
	}
	if line, ok := e.minimapHit(natW-1, chromeH+2); !ok || line != 3 {
		t.Fatalf("row 2 press = (%d,%v) want (3,true)", line, ok)
	}
	// A press below the buffer clamps to the last line, not a refusal.
	if line, ok := e.minimapHit(natW-8, natH-1); !ok || line != 5 {
		t.Fatalf("bottom press = (%d,%v) want (5,true) clamped", line, ok)
	}
	if _, ok := e.minimapHit(natW-miniW-1, chromeH+10); ok {
		t.Fatal("press one pixel left of the column must refuse")
	}
	if _, ok := e.minimapHit(natW-8, chromeH-1); ok {
		t.Fatal("press in the chrome row must refuse")
	}
	if _, ok := e.minimapHit(natW-8, natH); ok {
		t.Fatal("press below the window must refuse")
	}
	// A nil TabApp falls back to the natural geometry (the host-test shape).
	e2 := usEditor("only\n")
	e2.minimap = true
	if line, ok := e2.minimapHit(natW-1, chromeH); !ok || line != 1 {
		t.Fatalf("nil-ta hit = (%d,%v) want (1,true)", line, ok)
	}
}

// TestMinimapJumpLandsCaret: a column press parks the caret at the line's
// start and drops any selection — the goto bar's landing through the
// document's only mouse input.
func TestMinimapJumpLandsCaret(t *testing.T) {
	e := miniEditor("one\ntwo\nthree\n")
	e.sel, e.selSet = 0, true
	if !e.handle(vi.Event{Kind: vi.EvMouseDown, Arg0: uint32(natW - 8), Arg1: chromeH + 1}) {
		t.Fatal("a press inside the column must repaint")
	}
	if e.cur != 4 {
		t.Fatalf("caret = %d want 4 (start of line 2)", e.cur)
	}
	if e.selSet {
		t.Fatal("the jump must drop the selection")
	}
	// A press outside the column is not the minimap's — the document takes
	// no mouse input, so nothing moves and nothing repaints.
	e = miniEditor("one\ntwo\nthree\n")
	if e.handle(vi.Event{Kind: vi.EvMouseDown, Arg0: uint32(natW - miniW - 1), Arg1: chromeH + 1}) {
		t.Fatal("a press outside the column must not repaint")
	}
	if e.cur != len(e.buf) {
		t.Fatalf("caret moved to %d on an outside press", e.cur)
	}
	// With the flag off the same press is inert.
	e = usEditor("one\ntwo\nthree\n")
	e.ta = &tabapp.TabApp{Win: 1, W: natW, H: natH}
	if e.handle(vi.Event{Kind: vi.EvMouseDown, Arg0: uint32(natW - 8), Arg1: chromeH + 1}) {
		t.Fatal("a press must not repaint with -minimap off")
	}
	if e.cur != len(e.buf) {
		t.Fatalf("caret moved to %d with -minimap off", e.cur)
	}
}

// TestDrawMinimapGeometry: the Gutter band fills the column, each line's row
// is one pixel tall and scales to the widest line, and the caret's line
// carries the constant amber accent.
func TestDrawMinimapGeometry(t *testing.T) {
	e := miniEditor("abc\nabcdefghijkl\nabcdef\n")
	// Caret on line 2 (the widest) so its row is the amber accent.
	e.cur = 4
	s := record(e)
	e.draw()
	x := natW - miniW
	if !s.has(x, chromeH, miniW, natH-chromeH, theme.Dark.Gutter) {
		t.Fatalf("no gutter band down the column: %+v", s.fills)
	}
	// maxRunes=12: rows are 4, 16 and 8 px wide — the buffer's silhouette.
	if !s.has(x, chromeH, 4, 1, theme.Dark.Muted) {
		t.Fatal("line 1's row is not 3/12 of the column")
	}
	if !s.has(x, chromeH+2, 8, 1, theme.Dark.Muted) {
		t.Fatal("line 3's row is not 6/12 of the column")
	}
	if !s.has(x, chromeH+1, miniW, 1, colCaret) {
		t.Fatal("the widest line's row must fill the column in amber (caret line)")
	}
	// Exactly one amber row inside the column: the caret's.
	if n := s.count(colCaret, x, natW, chromeH, natH); n != 1 {
		t.Fatalf("%d caret-coloured minimap rects, want 1", n)
	}
}

// TestPollThemeChange: a delivered theme notice applies the new table and
// reports itself; a non-theme key or a refused value leaves Current and
// reports nothing.
func TestPollThemeChange(t *testing.T) {
	defer func() {
		pollChange = settings.PollChange
		theme.Current = theme.Dark
	}()
	theme.Current = theme.Dark
	stub := func(k, v string, ok bool) {
		pollChange = func(uint32) (string, string, bool) { return k, v, ok }
	}
	e := usEditor("x\n")
	stub("theme", "light", true)
	key, value, applied := e.pollThemeChange()
	if !applied || key != "theme" || value != "light" {
		t.Fatalf("pollThemeChange = (%q,%q,%v) want (theme,light,true)", key, value, applied)
	}
	if theme.Current != theme.Light {
		t.Fatal("theme.Current did not follow the notice")
	}
	stub("theme", "light", true) // the same notice again still applies
	if _, _, applied := e.pollThemeChange(); !applied {
		t.Fatal("a repeated notice must still report the applied frame")
	}
	stub("theme", "amber", true) // a refused vocabulary value applies nothing
	if _, _, applied := e.pollThemeChange(); applied {
		t.Fatal("amber must not report an applied repaint")
	}
	if theme.Current != theme.Light {
		t.Fatal("a refused value must leave theme.Current standing")
	}
	stub("idle_minutes", "5", true) // not this app's key
	if _, _, applied := e.pollThemeChange(); applied {
		t.Fatal("a non-theme notice must not repaint")
	}
	stub("", "", false) // an empty mailbox
	if _, _, applied := e.pollThemeChange(); applied {
		t.Fatal("an empty poll must not repaint")
	}
}

