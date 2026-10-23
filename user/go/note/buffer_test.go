package main

import "testing"

func text(b *Buffer) string { return string(b.Bytes()) }

// Typing, then backspacing across a line break: the two lines join and the
// caret lands at the end of the joined line. This is the single most common
// editing action, so it is the first thing pinned.
func TestInsertBackspaceJoin(t *testing.T) {
	b := NewBuffer()
	b.InsertText("ab")
	if !b.Newline() {
		t.Fatal("Newline refused")
	}
	b.InsertText("cd")
	if got := text(b); got != "ab\ncd" {
		t.Fatalf("text = %q want %q", got, "ab\ncd")
	}
	if b.Line() != 2 || b.Col() != 2 {
		t.Fatalf("caret line/col = %d/%d want 2/2", b.Line(), b.Col())
	}
	if !b.Backspace() || !b.Backspace() {
		t.Fatal("Backspace refused inside the line")
	}
	if b.Line() != 2 || b.Col() != 0 {
		t.Fatalf("after emptying line 2: line/col = %d/%d want 2/0", b.Line(), b.Col())
	}
	if !b.Backspace() {
		t.Fatal("Backspace refused at the start of a line")
	}
	if got := text(b); got != "ab" {
		t.Fatalf("joined text = %q want %q", got, "ab")
	}
	if b.Line() != 1 || b.Col() != 2 {
		t.Fatalf("after the join: line/col = %d/%d want 1/2", b.Line(), b.Col())
	}
	// At the very start there is nothing to remove and nothing may change.
	b.Home()
	if b.Backspace() || len(b.Bytes()) != 2 || b.Cursor() != 0 {
		t.Fatalf("Backspace at offset 0 changed the buffer: %q cursor=%d", text(b), b.Cursor())
	}
}

// Insert in the middle, not only at the end: the splice is the operation the
// caret makes common, and an off-by-one there corrupts every later edit.
func TestInsertInMiddle(t *testing.T) {
	b := NewBuffer()
	b.InsertText("ac")
	b.SetCursor(1)
	b.Insert('b')
	if got := text(b); got != "abc" {
		t.Fatalf("text = %q want abc", got)
	}
	if b.Cursor() != 2 {
		t.Fatalf("cursor = %d want 2 (after the inserted byte)", b.Cursor())
	}
	// Delete removes at the caret; the caret stays put.
	if !b.Delete() {
		t.Fatal("Delete refused")
	}
	if got := text(b); got != "ab" || b.Cursor() != 2 {
		t.Fatalf("after Delete: %q cursor=%d want ab cursor=2", got, b.Cursor())
	}
	if b.Delete() {
		t.Fatal("Delete at the end of the text must refuse")
	}
}

func TestUTF8CaretEditsWholeRunes(t *testing.T) {
	b := NewBuffer()
	b.InsertText("a")
	if !b.InsertRune('ö') {
		t.Fatal("InsertRune refused")
	}
	b.InsertText("b")
	if got := text(b); got != "aöb" || b.Col() != 3 {
		t.Fatalf("UTF-8 text/column = %q/%d want aöb/3", got, b.Col())
	}
	if !b.Left() || b.Cursor() != len("aö") {
		t.Fatalf("Left split a rune: cursor=%d", b.Cursor())
	}
	b.SetCursor(2)
	if b.Cursor() != 1 {
		t.Fatalf("SetCursor into a continuation byte yielded %d, want rune boundary 1", b.Cursor())
	}
	b.SetCursor(len("aö"))
	if !b.Backspace() || text(b) != "ab" || b.Cursor() != 1 {
		t.Fatalf("Backspace split a rune: text=%q cursor=%d", text(b), b.Cursor())
	}
}

// A host editor's line endings: CRLF becomes LF, a bare CR becomes LF, a NUL is
// dropped. Otherwise the file opens with carriage returns drawn as glyphs and
// the line structure the user sees is not the one the frame counted.
func TestLoadNormalizes(t *testing.T) {
	b := NewBuffer()
	n := b.Load([]byte("a\r\nb\rc\x00d"))
	if got := text(b); got != "a\nb\ncd" {
		t.Fatalf("loaded %q want %q", got, "a\nb\ncd")
	}
	if n != len(b.Bytes()) {
		t.Fatalf("Load reported %d accepted bytes for a %d-byte buffer", n, len(b.Bytes()))
	}
	if b.Cursor() != 0 {
		t.Fatalf("caret after load = %d want 0", b.Cursor())
	}
	if b.LineCount() != 3 {
		t.Fatalf("LineCount = %d want 3", b.LineCount())
	}
}

// The bound is reported, not hidden: Load returns exactly MaxBytes when the
// file was longer, and Insert refuses rather than growing past it.
func TestBoundsAreReported(t *testing.T) {
	big := make([]byte, MaxBytes+17)
	for i := range big {
		big[i] = 'x'
	}
	b := NewBuffer()
	if n := b.Load(big); n != MaxBytes {
		t.Fatalf("Load of %d bytes reported %d want %d", len(big), n, MaxBytes)
	}
	if b.Len() != MaxBytes {
		t.Fatalf("buffer holds %d want %d", b.Len(), MaxBytes)
	}
	if b.Insert('y') {
		t.Fatal("Insert past MaxBytes was accepted")
	}
	if b.Newline() {
		t.Fatal("Newline past MaxBytes was accepted")
	}
	// A full buffer still deletes: refusing the edit must not wedge the app.
	// (Load leaves the caret at the start, so put it at the end first — a
	// backspace at offset 0 correctly refuses.)
	b.SetCursor(b.Len())
	if !b.Backspace() {
		t.Fatal("Backspace refused on a full buffer")
	}
	if !b.Insert('y') {
		t.Fatalf("Insert after one byte was freed still refused (len=%d)", b.Len())
	}
}

// InsertText is the paste path: it stops at the bound and says how much went
// in, so the app can report the truncation instead of claiming success.
func TestInsertTextStopsAtBound(t *testing.T) {
	b := NewBuffer()
	filler := make([]byte, MaxBytes)
	for i := range filler {
		filler[i] = 'a'
	}
	b.Load(filler)
	n := b.InsertText("xyz")
	if n != 0 {
		t.Fatalf("InsertText into a full buffer inserted %d want 0", n)
	}
	// Free two bytes at the end, then a three-byte paste must land two and say
	// so: the short count is the truncation report, not a silent success.
	b.SetCursor(b.Len())
	b.Backspace()
	b.Backspace()
	if n := b.InsertText("xyz"); n != 2 {
		t.Fatalf("InsertText inserted %d want 2 (the room available)", n)
	}
	if b.Len() != MaxBytes {
		t.Fatalf("buffer is %d bytes after a full paste want %d", b.Len(), MaxBytes)
	}
	if got := b.InsertText("q"); got != 0 {
		t.Fatalf("InsertText inserted %d into a full buffer want 0", got)
	}
}

// Columns are remembered across a vertical move and clamped on a short line —
// the caret never wraps to the next line, which is the classic way a notepad's
// Down key starts eating the text below.
func TestVerticalMovesClampColumns(t *testing.T) {
	b := NewBuffer()
	b.Load([]byte("long line here\nab\nlonger still"))
	// Put the caret at column 10 of line 1, then move down onto the 2-byte line.
	b.SetCursor(10)
	if !b.Down() {
		t.Fatal("Down refused")
	}
	if b.Line() != 2 || b.Col() != 2 {
		t.Fatalf("down onto a short line: %d/%d want 2/2", b.Line(), b.Col())
	}
	if !b.Down() {
		t.Fatal("Down refused to line 3")
	}
	if b.Line() != 3 || b.Col() != 2 {
		t.Fatalf("down from a clamped column: %d/%d want 3/2 (the clamped column, not 10)", b.Line(), b.Col())
	}
	if !b.Up() {
		t.Fatal("Up from line 3 refused")
	}
	if b.Line() != 2 {
		t.Fatalf("Up landed on line %d want 2", b.Line())
	}
	if !b.Up() || b.Line() != 1 {
		t.Fatalf("Up to the first line = %d want 1", b.Line())
	}
	if b.Up() {
		t.Fatal("Up at the first line must refuse")
	}
	// Idempotent at the ends.
	b.SetCursor(b.Len())
	if b.Down() {
		t.Fatal("Down at the last line must refuse")
	}
}

func TestHomeEndAndHorizontals(t *testing.T) {
	b := NewBuffer()
	b.Load([]byte("one\ntwo"))
	b.SetCursor(6) // end of "two"
	if !b.Home() || b.Col() != 0 || b.Line() != 2 {
		t.Fatalf("Home = %d/%d want line 2 col 0", b.Line(), b.Col())
	}
	if b.Home() {
		t.Fatal("Home at the line start must refuse")
	}
	if !b.End() || b.Col() != 3 {
		t.Fatalf("End col = %d want 3", b.Col())
	}
	if b.End() {
		t.Fatal("End at the line end must refuse")
	}
	b.SetCursor(0)
	if b.Left() {
		t.Fatal("Left at the start must refuse")
	}
	if !b.Right() || b.Cursor() != 1 {
		t.Fatal("Right did not advance")
	}
	b.SetCursor(b.Len())
	if b.Right() {
		t.Fatal("Right at the end must refuse")
	}
}

// A trailing newline opens a last line the caret can sit on and type into.
func TestTrailingNewlineOpensALine(t *testing.T) {
	b := NewBuffer()
	b.Load([]byte("a\n"))
	if b.LineCount() != 2 {
		t.Fatalf("LineCount = %d want 2", b.LineCount())
	}
	b.SetCursor(b.Len())
	if b.Line() != 2 || b.Col() != 0 {
		t.Fatalf("caret at the end = %d/%d want line 2 col 0", b.Line(), b.Col())
	}
	b.Insert('b')
	if got := text(b); got != "a\nb" {
		t.Fatalf("text = %q want %q", got, "a\nb")
	}
}

// The scroll rule, including the resize cases: a viewport that shrinks under a
// caret near the bottom must move the window, and one that grows must not lose
// it either. top is a 1-based line number.
func TestFollowKeepsTheCaretVisible(t *testing.T) {
	b := NewBuffer()
	b.Load([]byte("1\n2\n3\n4\n5\n6\n7\n8\n9\n10"))
	b.SetCursor(0) // line 1
	cases := []struct {
		name      string
		top, rows int
		want      int
	}{
		{"already visible", 1, 4, 1},
		{"scrolled past the caret", 5, 4, 1},
		{"at the bottom edge", 1, 3, 1},
	}
	for _, c := range cases {
		if got := b.Follow(c.top, c.rows); got != c.want {
			t.Fatalf("%s: Follow(%d,%d) = %d want %d", c.name, c.top, c.rows, got, c.want)
		}
	}
	// Caret on line 10 with a 4-row viewport: the window is lines 7..10.
	b.SetCursor(b.Len())
	if got := b.Follow(1, 4); got != 7 {
		t.Fatalf("Follow for the last line = %d want 7", got)
	}
	// Already showing the last line: unchanged.
	if got := b.Follow(7, 4); got != 7 {
		t.Fatalf("Follow of a visible window = %d want 7", got)
	}
	// A resize that grows the viewport keeps the top (the caret is still in).
	if got := b.Follow(7, 9); got != 7 {
		t.Fatalf("Follow after growing = %d want 7", got)
	}
	// Degenerate viewports must not produce a nonsense top.
	if got := b.Follow(3, 0); got != 0 {
		t.Fatalf("Follow with no rows = %d want 0", got)
	}
	if got := b.Follow(-4, 4); got != 7 {
		t.Fatalf("Follow with a negative top = %d want 7", got)
	}
}

// The view model: the window, the clip, and where the caret is reported.
func TestViewWindowClipAndCaret(t *testing.T) {
	b := NewBuffer()
	b.Load([]byte("alpha\nbeta\ngamma\ndelta"))
	rows := b.View(1, 2, 80)
	if len(rows) != 2 {
		t.Fatalf("View returned %d rows want 2", len(rows))
	}
	if rows[0].Text != "alpha" || rows[0].Line != 1 || rows[1].Text != "beta" || rows[1].Line != 2 {
		t.Fatalf("window = %+v", rows)
	}
	// The caret is on line 1, so only row 0 carries a column; the others say -1.
	if rows[0].Col != 0 || rows[1].Col != -1 {
		t.Fatalf("caret columns = %d/%d want 0/-1", rows[0].Col, rows[1].Col)
	}
	b.SetCursor(11) // line 3, column 0
	rows = b.View(1, 3, 80)
	if rows[2].Line != 3 || rows[2].Col != 0 {
		t.Fatalf("caret row = %+v want line 3 col 0", rows[2])
	}
	if rows[0].Col != -1 || rows[1].Col != -1 {
		t.Fatal("a row without the caret must report -1")
	}
	// A long line is clipped, and the caret still reports its absolute column.
	b.Load([]byte("0123456789abcdefghij"))
	b.SetCursor(15)
	rows = b.View(1, 1, 8)
	if rows[0].Text != "01234567" {
		t.Fatalf("clipped text = %q want %q", rows[0].Text, "01234567")
	}
	if rows[0].Col != 15 {
		t.Fatalf("caret column = %d want 15 (absolute, not the clipped one)", rows[0].Col)
	}
	// Asking for a window past the end returns nothing rather than panicking.
	if got := b.View(9, 2, 8); len(got) != 0 {
		t.Fatalf("View past the end returned %d rows", len(got))
	}
	if got := b.View(1, 0, 8); got != nil {
		t.Fatalf("View with no rows = %v want nil", got)
	}
}

// A save/reload round-trip is byte-stable for text this app wrote: the load
// normalisation must not rewrite anything the editor can produce.
func TestLoadRoundTrip(t *testing.T) {
	src := "first\n\nthird line\n"
	b := NewBuffer()
	b.Load([]byte(src))
	if got := text(b); got != src {
		t.Fatalf("round-trip = %q want %q", got, src)
	}
	b.SetCursor(b.Len())
	b.InsertText("fourth")
	saved := string(b.Bytes())
	b2 := NewBuffer()
	b2.Load([]byte(saved))
	if got := text(b2); got != saved {
		t.Fatalf("second round-trip = %q want %q", got, saved)
	}
}

// SetCursor clamps rather than refuses, so a relayout with a stale offset
// cannot strand the caret outside the text.
func TestSetCursorClamps(t *testing.T) {
	b := NewBuffer()
	b.Load([]byte("abc"))
	b.SetCursor(-5)
	if b.Cursor() != 0 {
		t.Fatalf("cursor = %d want 0", b.Cursor())
	}
	b.SetCursor(99)
	if b.Cursor() != 3 {
		t.Fatalf("cursor = %d want 3", b.Cursor())
	}
}

// Delete at the end of a line takes the '\n' the caret sits on, so the next
// line joins upward. It is the mirror of Backspace at the start of a line
// (covered above) and it was the untested half: Delete-at-EOL is the deletion
// that changes the line count, and the caret must NOT move -- the byte after it
// slid into its place.
func TestDeleteAtEndOfLineJoins(t *testing.T) {
	b := NewBuffer()
	b.Load([]byte("ab\ncd\n"))
	b.SetCursor(2) // the '\n' after "ab"
	if !b.Delete() {
		t.Fatal("Delete refused at the end of a line")
	}
	if got := text(b); got != "abcd\n" {
		t.Fatalf("after deleting the newline: %q want %q", got, "abcd\n")
	}
	if b.Line() != 1 || b.Col() != 2 {
		t.Fatalf("caret = %d/%d want 1/2 (Delete never moves it)", b.Line(), b.Col())
	}
	// At the very end there is no byte to take, and nothing may change. The
	// buffer now ends with the newline the join left behind, so the caret's
	// home at offset 5 is the start of an empty second line.
	b.SetCursor(b.Len())
	if b.Delete() {
		t.Fatal("Delete at the end of the buffer reported a change")
	}
	if b.Line() != 2 || b.Col() != 0 {
		t.Fatalf("caret after the join = %d/%d want 2/0", b.Line(), b.Col())
	}
	if got := text(b); got != "abcd\n" {
		t.Fatalf("Delete at the end changed the buffer: %q", got)
	}
}

// The status line's word count (M192b #3247): whitespace-separated runs,
// where the whitespace set is what this text can actually carry (' ', '\t',
// '\n' — load strips '\r' and the key path never inserts a tab). Multibyte
// runes are word text; the count is byte-local so a continuation byte is
// never mistaken for a space.
func TestWords(t *testing.T) {
	cases := []struct {
		name string
		text string
		want int
	}{
		{"empty", "", 0},
		{"one word", "hello", 1},
		{"spaces inside", "hello world", 2},
		{"leading/trailing whitespace", "  hello  \n", 1},
		{"lines and a tab", "a b\nc\td\n", 4},
		{"only whitespace", " \n ", 0},
		{"multibyte is word text", "aöb é", 2},
		{"punctuation does not split", "well,that", 1},
	}
	for _, c := range cases {
		b := NewBuffer()
		b.Load([]byte(c.text))
		if got := b.Words(); got != c.want {
			t.Fatalf("%s: Words(%q) = %d want %d", c.name, c.text, got, c.want)
		}
	}
}

// The buffer counts UTF-8 bytes for file limits and offsets, but the caret
// moves by whole Unicode scalars.
func TestUTF8CaretMovesByRune(t *testing.T) {
	b := NewBuffer()
	b.Load([]byte("é"))
	if b.Len() != 2 {
		t.Fatalf("Len = %d want 2: é is two bytes and the engine counts bytes", b.Len())
	}
	b.SetCursor(0)
	if !b.Right() || b.Cursor() != 2 || b.Col() != 1 {
		t.Fatalf("Right = %d/%d want byte offset 2, rune column 1", b.Cursor(), b.Col())
	}
	if got := text(b); got != "é" {
		t.Fatalf("the rune-aware caret re-joined the two bytes as %q want %q", got, "é")
	}
}
