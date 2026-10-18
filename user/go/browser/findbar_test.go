package main

import (
	"testing"

	"virelai/vi"
	"virelai/webrender"
)

// The find bar walks the shared matcher's offsets over the laid-out page
// text: Ctrl+F opens, typing recomputes, Enter / Shift+Enter step with
// wrap, Escape closes.

func findApp(t *testing.T, html string) *app {
	t.Helper()
	a := &app{hist: newHistory(), text: webrender.Bitmap{}}
	a.loadBody([]byte(html), "/host/T.HTML")
	if a.lay == nil {
		t.Fatal("fixture did not lay out")
	}
	return a
}

func typeFindKeys(a *app, keys ...rune) {
	for _, r := range keys {
		usage := uint32(r-'a') + 0x04
		a.keyEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: usage, Arg1: uint32(r)})
	}
}

func TestFindBarMatchCountAndStep(t *testing.T) {
	a := findApp(t, `<p>one two one</p><p>two one</p>`)
	a.keyEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: keyF, Flags: vi.ModCtrl})
	if !a.findOpen {
		t.Fatal("Ctrl+F did not open the bar")
	}
	typeFindKeys(a, 'o', 'n', 'e')
	if len(a.findMatches) != 3 || a.findCur != 0 {
		t.Fatalf("matches=%v cur=%d want 3,0", a.findMatches, a.findCur)
	}
	// Enter steps forward and wraps at the end — the shared matcher's
	// wrap-around rule the GOEDIT bar has always kept.
	a.keyEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: keyReturn})
	if a.findCur != 1 {
		t.Fatalf("step cur=%d want 1", a.findCur)
	}
	a.keyEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: keyReturn})
	a.keyEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: keyReturn})
	if a.findCur != 0 {
		t.Fatalf("wrapped step cur=%d want 0", a.findCur)
	}
	// Shift+Enter steps back through the same wrap.
	a.keyEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: keyReturn, Flags: vi.ModShift})
	if a.findCur != 2 {
		t.Fatalf("shift-step cur=%d want 2", a.findCur)
	}
	a.keyEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: keyEscape})
	if a.findOpen || len(a.findMatches) != 0 {
		t.Fatal("Escape did not close the bar and clear the search")
	}
}

// An edit narrows the live result: each keystroke reruns the scan and
// re-lands on the first match.
func TestFindBarIncrementalNarrowing(t *testing.T) {
	a := findApp(t, `<p>the thing then</p>`)
	a.openFindBar()
	typeFindKeys(a, 't', 'h', 'e')
	if len(a.findMatches) != 2 {
		t.Fatalf("'the' matches=%d want 2", len(a.findMatches))
	}
	typeFindKeys(a, 'n')
	if len(a.findMatches) != 1 {
		t.Fatalf("'then' matches=%d want 1", len(a.findMatches))
	}
	// Backspace widens again — the same recompute path.
	a.keyEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: keyBacksp})
	if len(a.findMatches) != 2 {
		t.Fatalf("widened matches=%d want 2", len(a.findMatches))
	}
}

// A miss is a real result: no current match, no step, no crash.
func TestFindBarMiss(t *testing.T) {
	a := findApp(t, `<p>hello</p>`)
	a.openFindBar()
	typeFindKeys(a, 'z')
	if len(a.findMatches) != 0 || a.findCur != -1 {
		t.Fatalf("miss state matches=%v cur=%d", a.findMatches, a.findCur)
	}
	a.findStep(1)
	if a.findCur != -1 {
		t.Fatal("stepping a miss moved the current match")
	}
}

// The bar owns the keyboard while open: a bare letter goes to the field,
// not to the app's page bindings (h would open history, q would quit).
func TestFindBarOwnsKeyboard(t *testing.T) {
	a := findApp(t, `<p>hq</p>`)
	a.openFindBar()
	typeFindKeys(a, 'h', 'q')
	if a.findEdit.text != "hq" || a.histOpen || a.quit {
		t.Fatalf("keys escaped the bar: pat=%q hist=%v quit=%v", a.findEdit.text, a.histOpen, a.quit)
	}
	// Ctrl+L retires the bar (the chrome inputs are mutually exclusive).
	a.keyEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: 0x0f, Flags: vi.ModCtrl})
	if a.findOpen || !a.urlEditing {
		t.Fatal("Ctrl+L did not swap the find bar for the URL field")
	}
}

// scrollToFind brings an off-screen match into view: the scrolled-to
// piece sits a quarter-viewport down, clamped at both ends.
func TestFindBarScrollsToMatch(t *testing.T) {
	a := findApp(t, `<p style="height:800px">top</p><p>needle</p><p style="height:800px">tail</p>`)
	a.openFindBar()
	typeFindKeys(a, 'n', 'e', 'e', 'd', 'l', 'e')
	if len(a.findMatches) != 1 {
		t.Fatalf("matches=%d want 1", len(a.findMatches))
	}
	if a.scroll <= 0 {
		t.Fatalf("no scroll to the off-screen match: s=%d", a.scroll)
	}
	pieces := a.findIdx.Pieces(a.lay, a.findMatches[0], a.findMatches[0]+6)
	if len(pieces) != 1 {
		t.Fatalf("pieces=%d want 1", len(pieces))
	}
	if a.scroll != pieces[0].Rect.Y-contentH/4 {
		t.Fatalf("scroll=%d want piece.Y-pad=%d", a.scroll, pieces[0].Rect.Y-contentH/4)
	}
}

// The highlight lands on the native surface: amber under every match,
// orange under the current one — the exact inks the live gate counts.
func TestFindBarHighlightPixels(t *testing.T) {
	a := findApp(t, `<p>one two one one</p>`)
	a.openFindBar()
	typeFindKeys(a, 'o', 'n', 'e')
	if len(a.findMatches) != 3 {
		t.Fatalf("matches=%d want 3", len(a.findMatches))
	}
	native := a.nativeSurface()
	native.Fill(0, 0, contentW, contentH, webrender.ColorPageBg)
	webrender.Paint(a.lay, native, 0, 0, contentW, contentH, a.scroll)
	a.paintFindHighlights(native)
	amber, orange := 0, 0
	for _, p := range a.nativePix {
		switch p & 0xffffff {
		case colorFindMatch:
			amber++
		case colorFindCurrent:
			orange++
		}
	}
	if amber == 0 || orange == 0 {
		t.Fatalf("highlight pixels amber=%d orange=%d — expected both", amber, orange)
	}
	if orange >= amber {
		t.Fatalf("the current match is one of three: orange=%d must be < amber=%d", orange, amber)
	}
}

// A navigation keeps the bar and re-searches the new page silently —
// matches exist again, the count moved, no marker ordering was disturbed.
func TestFindBarSurvivesNavigation(t *testing.T) {
	a := findApp(t, `<p>one</p>`)
	a.openFindBar()
	typeFindKeys(a, 't', 'w', 'o')
	if len(a.findMatches) != 0 {
		t.Fatal("precondition: miss on the first page")
	}
	a.loadBody([]byte(`<p>two two</p>`), "/host/U.HTML")
	if !a.findOpen || len(a.findMatches) != 2 || a.findCur != 0 {
		t.Fatalf("post-nav state open=%v matches=%v cur=%d", a.findOpen, a.findMatches, a.findCur)
	}
}

// An error page retires the bar: no layout, no matches, no strip.
func TestFindBarDismissedOnError(t *testing.T) {
	a := findApp(t, `<p>one</p>`)
	a.openFindBar()
	a.setError("file", "/host/NOPE.HTML")
	if a.findOpen || len(a.findMatches) != 0 || a.findIdx != nil {
		t.Fatal("the error page kept a live search")
	}
}
