package main

import (
	"testing"

	"virelai/layout"
	"virelai/tabapp"
	"virelai/vi"
)

// main_test.go pins the #2199 wiring the buffer layer plugs into: the new
// markers' literal shapes (the gate greps them), the chord spellings the
// live seat injects, selection state, clipboard flow through the slot
// seam, and the bar-driven replace paths.

// usDown is the KEY_DOWN the kernel posts for a physical key under US:
// usage in arg0, translated codepoint (or a control code for a chord) in
// arg1, modifiers in flags.
func usDown(usage uint8, flags uint16, arg1 uint32) vi.Event {
	return vi.Event{Kind: vi.EvKeyDown, Flags: flags, Arg0: uint32(usage), Arg1: arg1}
}

func usEditor(text string) *editor {
	e := &editor{doc: doc{buf: []byte(text), cur: len(text)}}
	e.stage.SetLayout(layout.US)
	return e
}

// TestMarkerShapes2199 pins the second-pass markers the go-edit gate greps —
// a drift here fails on the host before it can fail live.
func TestMarkerShapes2199(t *testing.T) {
	cases := []struct{ got, want string }{
		{markerStatus, "goedit: status "},
		{markerUndo, "goedit: undo "},
		{markerRedo, "goedit: redo "},
		{markerMark, "goedit: mark "},
		{markerCopy, "goedit: copy "},
		{markerCut, "goedit: cut "},
		{markerPaste, "goedit: paste "},
		{markerRepl, "goedit: replace '"},
		{markerReplAll, "goedit: replace-all '"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}

// TestChordSpellings: the usage column is what the kernel reliably delivers,
// but the arg1 letter and control-code spellings count too — and shift is
// part of the chord, so ctrl-shift-z is never ctrl-z.
func TestChordSpellings(t *testing.T) {
	ctrl, ctrlShift := uint16(modCtrl), uint16(modCtrl|vi.ModShift)
	if !chord(usDown(0x1d, ctrl, 'z'), 'z', false) {
		t.Fatal("ctrl-z via usage must fire")
	}
	if !chord(vi.Event{Kind: vi.EvKeyDown, Flags: ctrl, Arg1: 'z'}, 'z', false) {
		t.Fatal("ctrl-z via arg1 letter must fire")
	}
	if !chord(vi.Event{Kind: vi.EvKeyDown, Flags: ctrl, Arg1: 0x1a}, 'z', false) {
		t.Fatal("ctrl-z via control code must fire")
	}
	if chord(usDown(0x1d, ctrlShift, 'Z'), 'z', false) {
		t.Fatal("ctrl-shift-z must not be ctrl-z")
	}
	if !chord(usDown(0x1d, ctrlShift, 'Z'), 'z', true) {
		t.Fatal("ctrl-shift-z must fire with shift required")
	}
	if chord(usDown(0x1d, 0, 'z'), 'z', false) {
		t.Fatal("a bare z is not a chord")
	}
	if chord(vi.Event{Kind: vi.EvKeyUp, Flags: ctrl, Arg1: 'z'}, 'z', false) {
		t.Fatal("key-up is not a chord")
	}
}

// TestUndoRedoThroughKeys drives the live path: typed runs merge, a delete
// run merges, undo walks ops newest-first, redo reapplies them.
func TestUndoRedoThroughKeys(t *testing.T) {
	e := usEditor("ab\n")
	typeRune := func(r uint32, usage uint8) {
		e.key(usDown(usage, 0, r))
	}
	typeRune('X', 0x1b) // X
	e.key(vi.Event{Kind: vi.EvKeyDown, Arg0: 0x28, Arg1: '\n'})
	typeRune('Y', 0x1c) // Y
	if string(e.buf) != "ab\nX\nY" {
		t.Fatalf("buf = %q", e.buf)
	}
	// Backspace deletes Y and merges nothing else — one del run op.
	e.key(usDown(0x2a, 0, codeBackspace))
	if string(e.buf) != "ab\nX\n" {
		t.Fatalf("backspace = %q", e.buf)
	}
	// Four ops: X, \n, Y, del-Y. Undo walks them in reverse.
	e.undo() // restore Y
	if string(e.buf) != "ab\nX\nY" {
		t.Fatalf("undo del = %q", e.buf)
	}
	e.undo() // remove Y
	e.undo() // remove \n
	if string(e.buf) != "ab\nX" {
		t.Fatalf("undo x2 = %q", e.buf)
	}
	e.undo() // remove X
	if string(e.buf) != "ab\n" {
		t.Fatalf("undo X = %q", e.buf)
	}
	if len(e.hist.undo) != 0 || len(e.hist.redo) != 4 {
		t.Fatalf("hist = u%d r%d want u0 r4", len(e.hist.undo), len(e.hist.redo))
	}
	e.redo() // reinsert X
	e.redo() // reinsert \n
	if string(e.buf) != "ab\nX\n" {
		t.Fatalf("redo x2 = %q", e.buf)
	}
}

// TestTypedRunIsOneUndo is the merged-typing model at editor level: three
// keystrokes, one undo.
func TestTypedRunIsOneUndo(t *testing.T) {
	e := usEditor("")
	for _, c := range "abc" {
		e.insert(rune(c))
	}
	if len(e.hist.undo) != 1 {
		t.Fatalf("typing = %d ops want 1 (merged)", len(e.hist.undo))
	}
	e.undo()
	if string(e.buf) != "" {
		t.Fatalf("one undo must drop the whole run, buf = %q", e.buf)
	}
	e.redo()
	if string(e.buf) != "abc" {
		t.Fatalf("redo = %q", e.buf)
	}
}

// TestSelectionOverCaret: shift-arrow extends from the anchor, a plain nav
// collapses, and the mark stands in for shift at the gate.
func TestSelectionOverCaret(t *testing.T) {
	e := usEditor("clipme\n")
	// shift+left twice selects the trailing "e\n"... but the runner cannot
	// spell shift+arrow live, so pin the mark path too.
	e.key(usDown(usageLeft, vi.ModShift, 0))
	e.key(usDown(usageLeft, vi.ModShift, 0))
	lo, hi, ok := e.selRange()
	if !ok || lo != 5 || hi != 7 {
		t.Fatalf("shift-left x2 sel = (%d,%d,%v) want (5,7,true)", lo, hi, ok)
	}
	if _, _, ok := e.selRange(); !ok {
		t.Fatal("selection must be pinned")
	}
	// A plain arrow collapses it.
	e.key(usDown(usageLeft, 0, 0))
	if _, _, ok := e.selRange(); ok {
		t.Fatal("plain arrow must collapse the selection")
	}
	// The mark: ctrl-shift-m, then plain arrows extend.
	e.key(usDown(0x10, modCtrl|vi.ModShift, 'M')) // ctrl-shift-m
	e.key(usDown(usageLeft, 0, 0))
	e.key(usDown(usageLeft, 0, 0))
	lo, hi, ok = e.selRange()
	if !ok || lo != 2 || hi != 4 {
		t.Fatalf("marked sel = (%d,%d,%v) want (2,4,true)", lo, hi, ok)
	}
	// ctrl-a selects all.
	e.key(usDown(0x04, modCtrl, 'a'))
	lo, hi, ok = e.selRange()
	if !ok || lo != 0 || hi != 7 {
		t.Fatalf("ctrl-a sel = (%d,%d,%v)", lo, hi, ok)
	}
}

// TestTypeOverSelectionIsOneOp: typing over a selection replaces it, and one
// undo restores both the selection's bytes and the typed rune.
func TestTypeOverSelectionIsOneOp(t *testing.T) {
	e := usEditor("abcdef")
	e.sel, e.selSet = 1, true // anchor
	e.cur = 4                 // caret — sel is "bcd"
	if !e.insert('X') {
		t.Fatal("insert over selection")
	}
	if string(e.buf) != "aXef" || e.cur != 2 {
		t.Fatalf("type-over = (%q,cur=%d) want (\"aXef\",2)", e.buf, e.cur)
	}
	if _, _, ok := e.selRange(); ok {
		t.Fatal("an edit must collapse the selection")
	}
	e.undo()
	if string(e.buf) != "abcdef" {
		t.Fatalf("one undo must restore the region, buf = %q", e.buf)
	}
}

// fakeClip is the host stand-in for slots 38/39: a bytes cell with a
// programmable refusal, mirroring the kernel's machine-global buffer.
type fakeClip struct {
	data []byte
	rc   int64
}

func (f *fakeClip) write(p []byte) (int, int64) {
	if f.rc < 0 {
		return 0, f.rc
	}
	f.data = append([]byte{}, p...)
	return len(p), 0
}

func (f *fakeClip) read() ([]byte, int64) {
	if f.rc < 0 {
		return nil, f.rc
	}
	return append([]byte{}, f.data...), 0
}

// installClip swaps the slot wrappers for the test.
func installClip(t *testing.T, f *fakeClip) {
	t.Helper()
	ow, or := clipWrite, clipRead
	clipWrite, clipRead = f.write, f.read
	t.Cleanup(func() { clipWrite, clipRead = ow, or })
}

// TestCutCopyPasteThroughTheSlot: copy leaves the buffer, cut splices it,
// paste lands at the caret — all through the slot seam, which the live gate
// backs with the kernel's real slots 38/39.
func TestCutCopyPasteThroughTheSlot(t *testing.T) {
	f := &fakeClip{}
	installClip(t, f)
	e := usEditor("clipthis")
	e.selectAll()
	e.copy()
	if string(f.data) != "clipthis" {
		t.Fatalf("clipboard = %q want %q", f.data, "clipthis")
	}
	if string(e.buf) != "clipthis" {
		t.Fatalf("copy must not touch the buffer: %q", e.buf)
	}
	// Cut a prefix, then paste it back at the same caret.
	e.sel, e.selSet, e.cur = 0, true, 4
	e.cut()
	if string(e.buf) != "this" || e.cur != 0 {
		t.Fatalf("cut = (%q,cur=%d)", e.buf, e.cur)
	}
	if string(f.data) != "clip" {
		t.Fatalf("clipboard after cut = %q", f.data)
	}
	e.paste()
	if string(e.buf) != "clipthis" || e.cur != 4 {
		t.Fatalf("paste = (%q,cur=%d)", e.buf, e.cur)
	}
	// Paste-over-selection is one op.
	e.sel, e.selSet, e.cur = 0, true, 4
	e.paste()
	if string(e.buf) != "clipthis" {
		t.Fatalf("paste-over = %q", e.buf)
	}
	e.undo()
	if string(e.buf) != "clipthis" {
		t.Fatalf("undo paste-over = %q", e.buf)
	}
}

// TestDropSplicesLikePaste: M124a-2 (#2677) — a delivered drag payload is
// a paste at the caret without the clipboard slot: over-selection is one
// undoable op, an absent or empty payload leaves the buffer alone, and the
// seat-declared mime lands on the marker.
func TestDropSplicesLikePaste(t *testing.T) {
	e := usEditor("clipthis")
	e.drop(tabapp.DragOffer{Mime: "text/plain", Blob: []byte("drop")})
	if string(e.buf) != "clipthisdrop" || e.cur != len("clipthisdrop") {
		t.Fatalf("drop = (%q,cur=%d)", e.buf, e.cur)
	}
	// Over a selection it replaces — one op, one undo.
	e.sel, e.selSet, e.cur = 0, true, 4
	e.drop(tabapp.DragOffer{Mime: "text/plain", Blob: []byte("clip")})
	if string(e.buf) != "clipthisdrop" || e.cur != 4 {
		t.Fatalf("drop-over = (%q,cur=%d)", e.buf, e.cur)
	}
	// The refused shapes never splice.
	e.drop(tabapp.DragOffer{Mime: "text/plain"})
	e.drop(tabapp.DragOffer{Mime: "text/plain", Blob: []byte{}})
	if string(e.buf) != "clipthisdrop" {
		t.Fatalf("empty/nil drops must not splice: %q", e.buf)
	}
}

// TestClipboardRefusalLeavesTheBuffer: M97g-F4 refuses the slots for an
// unprivileged app — the op reports rc and the buffer does not move.
func TestClipboardRefusalLeavesTheBuffer(t *testing.T) {
	f := &fakeClip{rc: -7}
	installClip(t, f)
	e := usEditor("keepme")
	e.selectAll()
	e.cut()
	if string(e.buf) != "keepme" {
		t.Fatalf("a refused cut must not splice: %q", e.buf)
	}
	e.paste()
	if string(e.buf) != "keepme" {
		t.Fatalf("a refused paste must not splice: %q", e.buf)
	}
}

// TestReplaceCurrentAndAll: the bar's two actions, through the fields the
// gate types into.
func TestReplaceCurrentAndAll(t *testing.T) {
	e := usEditor("one two one\ntwo one")
	e.cur = 0
	e.mode = modeReplace
	e.bar, e.bar2 = []byte("one"), []byte("X")
	e.runReplace()
	if string(e.buf) != "X two one\ntwo one" {
		t.Fatalf("replace-current = %q", e.buf)
	}
	if e.mode != modeEdit {
		t.Fatal("replace must close the bar")
	}
	// One undo restores the match.
	e.undo()
	if string(e.buf) != "one two one\ntwo one" {
		t.Fatalf("undo replace = %q", e.buf)
	}
	// Replace-all: n equals the find total for the pattern.
	e.mode = modeReplace
	e.bar, e.bar2 = []byte("one"), []byte("X")
	e.runReplaceAll()
	if string(e.buf) != "X two X\ntwo X" {
		t.Fatalf("replace-all = %q", e.buf)
	}
	if len(e.hist.undo) != 1 {
		t.Fatalf("replace-all must be ONE op, got %d", len(e.hist.undo))
	}
	e.undo()
	if string(e.buf) != "one two one\ntwo one" {
		t.Fatalf("one undo must revert the whole pass: %q", e.buf)
	}
}

// TestReplaceBarKeys drives the two-field bar the way the seat does:
// pattern, Tab, replacement, Return / Ctrl-A.
func TestReplaceBarKeys(t *testing.T) {
	e := usEditor("cat cat")
	e.cur = 0
	e.key(usDown(0x15, modCtrl, keyCtrlR)) // ctrl-r opens the bar
	if e.mode != modeReplace {
		t.Fatalf("ctrl-r mode = %d", e.mode)
	}
	for _, c := range "cat" {
		e.key(usDown(uint8(c)-'a'+0x04, 0, uint32(c)))
	}
	if string(e.bar) != "cat" {
		t.Fatalf("pattern = %q", e.bar)
	}
	e.key(usDown(usageTab, 0, '\t')) // focus the replacement field
	if !e.bar2At {
		t.Fatal("tab must focus the second field")
	}
	e.key(usDown(0x1b, 0, 'x'))
	if string(e.bar2) != "x" {
		t.Fatalf("replacement = %q", e.bar2)
	}
	e.key(vi.Event{Kind: vi.EvKeyDown, Arg0: 0x28, Arg1: '\n'}) // return
	if string(e.buf) != "x cat" {
		t.Fatalf("replace-current = %q", e.buf)
	}
	// And ctrl-a inside the bar is replace-all.
	e.mode = modeReplace
	e.bar, e.bar2 = []byte("cat"), []byte("y")
	e.replaceBarKey(usDown(0x04, modCtrl, 'a'))
	if string(e.buf) != "x y" {
		t.Fatalf("replace-all from the bar = %q", e.buf)
	}
}

// TestStatusLineText pins the status line's shape: line/total, column,
// selection size, dirty.
func TestStatusLineText(t *testing.T) {
	e := usEditor("ab\ncde")
	e.cur = 5 // 'd' on line 2
	if got, want := e.statusText(), "line=2/2 col=3"; got != want {
		t.Fatalf("status = %q want %q", got, want)
	}
	e.dirty = true
	if got, want := e.statusText(), "line=2/2 col=3 *"; got != want {
		t.Fatalf("dirty status = %q want %q", got, want)
	}
	e.sel, e.selSet = 3, true // sel [3,5) = "cd"
	if got, want := e.statusText(), "line=2/2 col=3 sel=2 *"; got != want {
		t.Fatalf("sel status = %q want %q", got, want)
	}
}

// TestFindLandsSelected: the find bar's match arrives selected, so the gate
// can copy or cut a found region without a second gesture.
func TestFindLandsSelected(t *testing.T) {
	e := usEditor("hello world")
	e.cur = 0
	e.mode = modeFind
	e.bar = []byte("wor")
	e.runFind()
	lo, hi, ok := e.selRange()
	if !ok || lo != 6 || hi != 9 || e.cur != 6 {
		t.Fatalf("find sel = (%d,%d,%v) cur=%d want (6,9,true) cur=6", lo, hi, ok, e.cur)
	}
}

// TestNavKeysMoveTheCaret: the document takes arrows/home/end even in the
// Zig seat — the app event arrives, the WM keeps its sidebar gesture.
func TestNavKeysMoveTheCaret(t *testing.T) {
	e := usEditor("ab\ncde")
	e.cur = len(e.buf)
	e.key(usDown(usageHome, 0, 0))
	if e.cur != 3 {
		t.Fatalf("home cur = %d want 3", e.cur)
	}
	e.key(usDown(usageUp, 0, 0))
	if e.cur != 0 {
		t.Fatalf("up cur = %d want 0", e.cur)
	}
	e.key(usDown(usageRight, 0, 0))
	if e.cur != 1 {
		t.Fatalf("right cur = %d want 1", e.cur)
	}
	e.key(usDown(usageEnd, 0, 0))
	if e.cur != 2 {
		t.Fatalf("end cur = %d want 2", e.cur)
	}
	// Forward delete removes the scalar at the caret — the newline here.
	e.key(usDown(usageFwdDel, 0, codeDelete))
	if string(e.buf) != "abcde" {
		t.Fatalf("fwd del = %q", e.buf)
	}
}
