package appkit

import (
	"strings"
	"testing"

	"virelai/chords"
	"virelai/vi"
	"virelai/widgets"
)

// TestChordHintsContent pins the registry filter: GOEDIT sees its three
// app rows plus every seat row; a binary with no registered app scope gets
// the honest note; the kernel-terminal section only appears when the
// caller names it.
func TestChordHintsContent(t *testing.T) {
	wantSeat := len(chords.Global.SeatRows())
	wantApp := 0
	for _, r := range chords.Global {
		if r.Scope == chords.AppScope("GOEDIT.ELF") {
			wantApp++
		}
	}
	if wantApp == 0 {
		t.Fatal("registry lost its GOEDIT rows — the overlay would prove nothing")
	}

	h := NewChordHints("GOEDIT.ELF")
	if !h.Open {
		t.Fatal("fresh overlay is not open")
	}
	if got := h.ChordRows(); got != wantApp+wantSeat {
		t.Fatalf("GOEDIT ChordRows=%d want %d (app=%d seat=%d)", got, wantApp+wantSeat, wantApp, wantSeat)
	}
	// No kernel-terminal section for a canvas app.
	for _, r := range h.Rows {
		if r.Head == string(chords.ScopeKernelTerminal)+" chords" {
			t.Fatal("kernel-terminal section appeared unasked")
		}
	}
	// The first section is the app's own, headed by its binary name.
	if h.Rows[0].Head != "this app — GOEDIT.ELF" {
		t.Fatalf("first section head = %q", h.Rows[0].Head)
	}
	// Row lines carry the registry's own spelling + label.
	found := false
	for _, l := range h.RowLines() {
		if l == "ctrl+s publish the buffer (save)" {
			found = true
		}
	}
	if !found {
		t.Fatalf("GOEDIT's ctrl+s row missing from RowLines: %v", h.RowLines())
	}
}

// TestChordHintsScopes proves the extra-scope path a tty-bound app takes:
// the kernel chrome rows appear only when ScopeKernelTerminal is named,
// and the seat section is never duplicated.
func TestChordHintsScopes(t *testing.T) {
	h := NewChordHints("GOTERM.ELF", chords.ScopeKernelTerminal)
	kernel := 0
	for _, r := range chords.Global {
		if r.Scope == chords.ScopeKernelTerminal {
			kernel++
		}
	}
	if kernel == 0 {
		t.Fatal("registry lost its kernel-terminal rows")
	}
	if got := h.ChordRows(); got != kernel+len(chords.Global.SeatRows()) {
		t.Fatalf("GOTERM ChordRows=%d want %d", got, kernel+len(chords.Global.SeatRows()))
	}
	heads := 0
	for _, r := range h.Rows {
		if r.Head == "global chords" {
			heads++
		}
	}
	if heads != 1 {
		t.Fatalf("global chords section count=%d want 1", heads)
	}
	// Asking for the seat scope again must not re-list it.
	dup := NewChordHints("X.ELF", chords.ScopeSeat, chords.ScopeSeat)
	dups := 0
	for _, r := range dup.Rows {
		if r.Head == "global chords" {
			dups++
		}
	}
	if dups != 1 {
		t.Fatalf("duplicate seat sections: %d", dups)
	}
}

// TestChordHintsKeys pins the open/close/scroll contract the card names:
// Esc closes, a second '?' also closes, and the nav keys move the scroll.
func TestChordHintsKeys(t *testing.T) {
	key := func(usage uint32, ch rune) vi.Event {
		return vi.Event{Kind: vi.EvKeyDown, Arg0: usage, Arg1: uint32(ch)}
	}
	h := NewChordHints("GOEDIT.ELF")
	if len(h.Rows) <= h.VisibleRows() {
		t.Fatal("fixture too short to scroll — registry shrank")
	}
	if _, done := h.HandleKey(key(0x51, 0)); !h.Open || done || h.Scroll != 1 {
		t.Fatalf("down: open=%v done=%v scroll=%d", h.Open, done, h.Scroll)
	}
	h.HandleKey(key(0x4d, 0)) // end
	if h.Scroll != h.maxScroll() {
		t.Fatalf("end: scroll=%d want %d", h.Scroll, h.maxScroll())
	}
	if changed, _ := h.HandleKey(key(0x4b, 0)); !changed || h.Scroll == h.maxScroll() {
		t.Fatal("pageup did not move the scroll")
	}
	changed, done := h.HandleKey(key(0x29, 0x1b))
	if !changed || !done || h.Open {
		t.Fatalf("esc: changed=%v done=%v open=%v", changed, done, h.Open)
	}
	// '?' toggles its own overlay closed the same way.
	h = NewChordHints("GOEDIT.ELF")
	if _, done := h.HandleKey(key(0, '?')); !done || h.Open {
		t.Fatal("'?' did not close the overlay")
	}
	// A closed overlay consumes nothing.
	if c, d := h.HandleKey(key(0x29, 0x1b)); c || d {
		t.Fatal("closed overlay still consuming keys")
	}
}

// TestChordHintsLines pins the VT form: title, sections, chord rows in
// registry spelling, and the footer — the exact strings a tty-bound app
// paints.
func TestChordHintsLines(t *testing.T) {
	h := NewChordHints("GOCALC.ELF", chords.ScopeKernelTerminal)
	lines := h.Lines(80)
	if lines[0] != "chord hints — GOCALC.ELF" {
		t.Fatalf("title line = %q", lines[0])
	}
	var sawHead, sawNote, sawKernelRow bool
	for _, l := range lines {
		switch {
		case l == "this app — GOCALC.ELF":
			sawHead = true
		case l == "    (none registered)":
			sawNote = true
		case strings.HasPrefix(l, "  ctrl+shift+c"):
			sawKernelRow = true
		}
	}
	if !sawHead || !sawNote {
		t.Fatalf("app section or its note missing: %v", lines[:6])
	}
	if !sawKernelRow {
		t.Fatal("kernel-terminal chord row missing from Lines")
	}
	if lines[len(lines)-1] != "esc close · arrows scroll" {
		t.Fatalf("footer = %q", lines[len(lines)-1])
	}
	for _, l := range lines {
		if len([]rune(l)) > 80 {
			t.Fatalf("line over w=80: %q", l)
		}
	}
}

// TestChordHintsDrawFlat proves the RectCanvas degrade paints the plate
// without a full Canvas — WEB's fill-only virender path.
func TestChordHintsDrawFlat(t *testing.T) {
	var c recCanvas
	h := NewChordHints("GOEDIT.ELF")
	h.Draw(&c)
	if len(c.fills) == 0 {
		t.Fatal("flat Draw painted nothing")
	}
	h.Open = false
	before := len(c.fills)
	h.Draw(&c)
	if len(c.fills) != before {
		t.Fatal("closed overlay painted")
	}
}

var _ = widgets.Rect{} // keep the import honest when tests shift
