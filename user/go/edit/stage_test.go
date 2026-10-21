package main

import (
	"testing"

	"virelai/layout"
	"virelai/settings"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
)

// Usages under the DE layout, where the kernel delivers the dead acute key as
// usage 0x2e with no symbol.
const (
	usageE     = 0x08
	usageX     = 0x1b
	usageAcute = 0x2e
	usageCirc  = 0x35
	usageEnter = 0x28
	usageBksp  = 0x2a
)

// deDown is the KEY_DOWN the kernel posts for a physical key under DE: the
// usage in arg0 and the translated codepoint (0 for a dead key) in arg1.
func deDown(usage uint8, shift bool) vi.Event {
	ev := vi.Event{Kind: vi.EvKeyDown, Arg0: uint32(usage)}
	if r, ok := layout.Translate(layout.DE, usage, shift); ok {
		ev.Arg1 = uint32(r)
	}
	if shift {
		ev.Flags = vi.ModShift
	}
	return ev
}

func deEditor(text string) *editor {
	e := &editor{buf: []byte(text), cur: len(text)}
	e.stage.SetLayout(layout.DE)
	return e
}

// screen keeps every rect a draw filled, in order. It hangs off the editor's
// rec seam: vi.Filler.Flush calls the kernel directly, so the syscall hook
// cannot see fills.
type screen struct {
	fills []fillRect
}

type fillRect struct {
	x, y, w, h int
	rgb        uint32
}

func record(e *editor) *screen {
	s := &screen{}
	e.rec = func(x, y, w, h int, rgb uint32) {
		s.fills = append(s.fills, fillRect{x, y, w, h, rgb})
	}
	return s
}

func (s *screen) has(x, y, w, h int, rgb uint32) bool {
	for _, f := range s.fills {
		if f == (fillRect{x, y, w, h, rgb}) {
			return true
		}
	}
	return false
}

// count is how many rects of one colour start inside [x0,x1) x [y0,y1).
func (s *screen) count(rgb uint32, x0, x1, y0, y1 int) int {
	n := 0
	for _, f := range s.fills {
		if f.rgb == rgb && f.x >= x0 && f.x < x1 && f.y >= y0 && f.y < y1 {
			n++
		}
	}
	return n
}

func TestDeadKeyComposesIntoTheDocument(t *testing.T) {
	e := deEditor("seed")
	if !e.key(deDown(usageAcute, false)) {
		t.Fatal("staging an accent changes the frame, so it must ask for a repaint")
	}
	if string(e.buf) != "seed" || e.dirty || e.stage.Preedit() != "'" {
		t.Fatalf("buf=%q dirty=%v preedit=%q, want the document untouched and the accent pending", e.buf, e.dirty, e.stage.Preedit())
	}
	if !e.key(deDown(usageE, false)) {
		t.Fatal("composing must repaint")
	}
	if string(e.buf) != "seedé" || e.cur != len("seedé") || !e.dirty || e.stage.Preedit() != "" {
		t.Fatalf("buf=%q cur=%d dirty=%v", e.buf, e.cur, e.dirty)
	}
	// Shift on the dead key is the grave, and the circumflex key is dead even
	// though the kernel translated it to a literal '^'.
	e.key(deDown(usageAcute, true))
	e.key(deDown(usageE, true))
	e.key(deDown(usageCirc, false))
	e.key(deDown(0x12, false))
	if string(e.buf) != "seedéÈô" {
		t.Fatalf("buf = %q", e.buf)
	}
}

func TestStrayCombinationTypesBothCharacters(t *testing.T) {
	e := deEditor("")
	e.key(deDown(usageAcute, false))
	e.key(deDown(usageX, false))
	e.key(deDown(usageAcute, false))
	e.key(deDown(0x2c, false)) // space: the bare accent
	if string(e.buf) != "´x´" {
		t.Fatalf("buf = %q, want the stray typed as literals", e.buf)
	}
}

func TestKeysThatEndASequenceStillDoTheirJob(t *testing.T) {

	// Return: the accent, then the newline.
	e := deEditor("a")
	e.key(deDown(usageAcute, false))
	e.key(vi.Event{Kind: vi.EvKeyDown, Arg0: usageEnter, Arg1: '\n'})
	if string(e.buf) != "a´\n" {
		t.Fatalf("after Return buf = %q", e.buf)
	}

	// Backspace drops the staged accent and leaves the text alone; the next
	// one is an ordinary Backspace.
	e = deEditor("ab")
	e.key(deDown(usageAcute, false))
	if !e.key(deDown(usageBksp, false)) || string(e.buf) != "ab" || e.stage.Preedit() != "" {
		t.Fatalf("Backspace over a staged accent: buf=%q preedit=%q", e.buf, e.stage.Preedit())
	}
	e.key(deDown(usageBksp, false))
	if string(e.buf) != "a" {
		t.Fatalf("second Backspace: buf = %q", e.buf)
	}

	// A chord types the accent first, then runs: Ctrl-F opens the find bar
	// with the accent already in the document.
	e = deEditor("a")
	e.key(deDown(usageAcute, false))
	e.key(vi.Event{Kind: vi.EvKeyDown, Flags: vi.ModCtrl, Arg0: 0x09, Arg1: keyF})
	if string(e.buf) != "a´" || e.mode != modeFind {
		t.Fatalf("Ctrl-F over a staged accent: buf=%q mode=%d", e.buf, e.mode)
	}
}

func TestSaveNeverLosesAStagedAccent(t *testing.T) {
	const target = "/host/EDIT/SEED.TXT"
	k := installEditKernel(t, 1000)
	e := deEditor("XYZ")
	e.path = target
	e.key(deDown(usageAcute, false))
	e.key(vi.Event{Kind: vi.EvKeyDown, Flags: vi.ModCtrl, Arg0: 0x16, Arg1: keyCtrlS})
	if got := string(k.files[target]); got != "XYZ´" {
		t.Fatalf("Ctrl-S published %q, want the pending accent saved as its literal", got)
	}
}

func TestStagedAccentBelongsToTheBarInBarMode(t *testing.T) {
	e := deEditor("body")
	e.key(vi.Event{Kind: vi.EvKeyDown, Flags: vi.ModCtrl, Arg0: 0x09, Arg1: keyF})
	e.key(deDown(usageAcute, false))
	e.key(deDown(usageE, false))
	e.key(deDown(usageAcute, false))
	e.key(deDown(usageX, false))
	if string(e.bar) != "é´x" || string(e.buf) != "body" {
		t.Fatalf("bar=%q buf=%q, want the bar to take the composed and literal text and the document to stay put", e.bar, e.buf)
	}
	// Return with an accent pending runs the search with it included.
	e.key(deDown(usageAcute, false))
	e.key(vi.Event{Kind: vi.EvKeyDown, Arg0: usageEnter, Arg1: '\n'})
	if e.mode != modeEdit || len(e.bar) != 0 {
		t.Fatalf("Return must close the bar: mode=%d bar=%q", e.mode, e.bar)
	}
}

func TestLosingFocusTypesAStagedAccent(t *testing.T) {
	e := deEditor("a")
	e.key(deDown(usageAcute, false))
	if !e.handle(vi.Event{Kind: vi.EvWinBlur}) {
		t.Fatal("typing the accent on blur must repaint")
	}
	if string(e.buf) != "a´" || e.stage.Preedit() != "" {
		t.Fatalf("buf=%q preedit=%q", e.buf, e.stage.Preedit())
	}
	if e.handle(vi.Event{Kind: vi.EvWinBlur}) {
		t.Fatal("blur with nothing staged is not a change")
	}
}

func TestUnstagedLayoutsKeepEveryKeyAsItWas(t *testing.T) {
	for _, id := range []layout.ID{"", layout.US} {
		e := &editor{}
		e.stage.SetLayout(id)
		// Under US the same physical key is '='.
		e.key(vi.Event{Kind: vi.EvKeyDown, Arg0: usageAcute, Arg1: '='})
		e.key(vi.Event{Kind: vi.EvKeyDown, Arg0: usageE, Arg1: 'e'})
		if string(e.buf) != "=e" || e.stage.Preedit() != "" {
			t.Errorf("layout %q: buf=%q preedit=%q", id, e.buf, e.stage.Preedit())
		}
	}
	// A dead key with no layout in force is ignored, exactly as before.
	e := &editor{}
	if e.key(vi.Event{Kind: vi.EvKeyDown, Arg0: usageAcute}) || len(e.buf) != 0 {
		t.Fatal("an unmapped key with no layout must stay a no-op")
	}
}

func TestLayoutForReadsTheSettingsTheKernelReads(t *testing.T) {
	file := func(rows ...settings.Setting) settings.File {
		return settings.File{Rows: rows, State: settings.StateOK}
	}
	cases := []struct {
		name string
		f    settings.File
		want layout.ID
	}{
		{"de", file(settings.Setting{Key: "keyboard_layout", Val: "de"}), layout.DE},
		{"us", file(settings.Setting{Key: "keyboard_layout", Val: "us"}), layout.US},
		{"absent row", file(settings.Setting{Key: "wm", Val: "none"}), layout.US},
		{"missing file", settings.File{State: settings.StateMissing}, layout.US},
		{"corrupt file", settings.File{State: settings.StateCorrupt}, layout.US},
		{"unknown value", file(settings.Setting{Key: "keyboard_layout", Val: "fr"}), layout.US},
	}
	for _, tc := range cases {
		if got := layoutFor(tc.f); got != tc.want {
			t.Errorf("%s: layoutFor = %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestStageMarkerIsAnEdgePrintedForEachPendingAccent(t *testing.T) {
	e := deEditor("")
	if m := e.stageMarker(); m != "" {
		t.Fatalf("nothing staged, yet marker %q", m)
	}
	e.key(deDown(usageAcute, false))
	if m := e.stageMarker(); m != markerStage+"acute" {
		t.Fatalf("marker = %q, want the stage marker for the pending acute", m)
	}
	if m := e.stageMarker(); m != "" {
		t.Fatalf("the same pending accent announced twice: %q", m)
	}
	// A different dead key commits the first accent and stages the second.
	e.key(deDown(usageAcute, true))
	if m := e.stageMarker(); m != markerStage+"grave" {
		t.Fatalf("marker = %q, want grave after the swap", m)
	}
	// Composing clears the mark, so the same accent is announced again.
	e.key(deDown(usageE, false))
	if m := e.stageMarker(); m != "" {
		t.Fatalf("marker = %q after composing, want none", m)
	}
	e.key(deDown(usageAcute, true))
	if m := e.stageMarker(); m != markerStage+"grave" {
		t.Fatalf("marker = %q, want grave announced again", m)
	}
}

func TestDrawPaintsThePendingAccentAtTheCaret(t *testing.T) {
	newEd := func() (*editor, *screen) {
		e := deEditor("ab")
		e.cur = 1
		e.ta = &tabapp.TabApp{Win: 1, W: natW, H: natH}
		return e, record(e)
	}
	row := chromeH + 4 // the first text row's y

	// Nothing staged: the caret sits after the "a", one cell in.
	e, s := newEd()
	e.draw()
	if !s.has(textOrigin+8, row, caretW, 8, colCaret) {
		t.Fatalf("caret not in cell 1: %+v", s.fills)
	}
	if n := s.count(colCaret, 0, natW, 0, natH); n != 1 {
		t.Fatalf("%d caret-coloured rects with nothing pending, want only the caret", n)
	}

	e, s = newEd()
	e.key(deDown(usageAcute, false))
	e.draw()
	// Cell 1 holds the mark, underlined in the spare row under the glyph.
	if s.count(colCaret, textOrigin+8, textOrigin+16, row, row+8) == 0 {
		t.Fatal("no glyph pixels for the pending accent in cell 1")
	}
	if !s.has(textOrigin+8, row+8, 8, 1, colCaret) {
		t.Fatalf("no underline under the pending cell: %+v", s.fills)
	}
	// "a" stays in cell 0, "b" has moved to cell 2, and cell 1 is the mark's.
	if s.count(theme.Dark.Ink, textOrigin, textOrigin+8, row, row+8) == 0 ||
		s.count(theme.Dark.Ink, textOrigin+16, textOrigin+24, row, row+8) == 0 {
		t.Fatal("text either side of the pending accent is missing")
	}
	if s.count(theme.Dark.Ink, textOrigin+8, textOrigin+16, row, row+8) != 0 {
		t.Fatal("text painted over the pending cell")
	}
	// The caret follows the mark.
	if !s.has(textOrigin+16, row, caretW, 8, colCaret) {
		t.Fatalf("caret did not move past the pending accent: %+v", s.fills)
	}
}

func TestDrawPaintsThePendingAccentInTheBar(t *testing.T) {
	e := deEditor("body")
	e.ta = &tabapp.TabApp{Win: 1, W: natW, H: natH}
	s := record(e)
	e.key(vi.Event{Kind: vi.EvKeyDown, Flags: vi.ModCtrl, Arg0: 0x09, Arg1: keyF})
	e.key(deDown(usageX, false))
	e.key(deDown(usageAcute, false))
	e.draw()
	barY := natH - lineH - 2
	col := len("Find: ") + 1 // the label and the typed "x"
	if !s.has(textOrigin+col*8, barY+8, 8, 1, colCaret) {
		t.Fatalf("no underline for the pending accent in the bar: %+v", s.fills)
	}
	// The document's caret keeps its own cell: the accent is not in the text.
	if !s.has(textOrigin+len("body")*8, chromeH+4, caretW, 8, colCaret) {
		t.Fatalf("document caret moved for an accent that belongs to the bar: %+v", s.fills)
	}
}
